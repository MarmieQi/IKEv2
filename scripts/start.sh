#!/bin/bash
set -euo pipefail

source /usr/local/lib/ikev2/runtime-config.sh
if [ -n "${IKEV2_CONFIG_FILE:-}" ]; then
    runtime_config_load "$IKEV2_CONFIG_FILE"
fi

source /usr/local/lib/ikev2/proxyarp.sh
source /usr/local/lib/ikev2/network-config.sh
source /usr/local/lib/ikev2/users.sh
source /usr/local/lib/ikev2/strongswan.sh

IPSEC_PID=""
cleanup() {
    local status=$?
    trap - EXIT
    if [ -n "$IPSEC_PID" ]; then
        kill "$IPSEC_PID" 2>/dev/null || true
        wait "$IPSEC_PID" 2>/dev/null || true
    fi
    proxyarp_gateway_cleanup || true
    exit "$status"
}

VPN_MODE="${VPN_MODE:-nat}"
VPN_DOMAIN="${VPN_DOMAIN:?缺少 VPN_DOMAIN}"
VPN_USERS_FILE="${VPN_USERS_FILE:-/etc/ikev2/users.txt}"
VPN_CERT_FILE="${VPN_CERT_FILE:-server.crt}"
VPN_KEY_FILE="${VPN_KEY_FILE:-server.key}"
VPN_CERT_PATH="/ssl/$VPN_CERT_FILE"
VPN_KEY_PATH="/ssl/$VPN_KEY_FILE"

# strongSwan 支持 192.168.0.180-192.168.0.200 地址池，iptables 不支持这种写法。
# 这里把地址池转换为 iptables 能接受的 match 参数。
ipt_src_pool_args() {
    local pool="$1"
    if echo "$pool" | grep -q '-'; then
        echo "-m iprange --src-range $pool"
    else
        echo "-s $pool"
    fi
}

ipt_dst_pool_args() {
    local pool="$1"
    if echo "$pool" | grep -q '-'; then
        echo "-m iprange --dst-range $pool"
    else
        echo "-d $pool"
    fi
}

iptables_rule_ensure() {
    local table=""
    if [ "$1" = "-t" ]; then
        table="-t $2"
        shift 2
    fi

    # shellcheck disable=SC2086
    iptables $table -C "$@" 2>/dev/null || iptables $table -A "$@"
}


network_config_resolve
users_load "$VPN_USERS_FILE"

modprobe xfrm_user || true
modprobe xfrm_interface || true
modprobe esp4 || true
modprobe esp6 || true
modprobe xfrm_algo || true

mkdir -p /etc/swanctl/x509
mkdir -p /etc/swanctl/x509ca
mkdir -p /etc/swanctl/private

rm -f /etc/swanctl/x509/*.pem /etc/swanctl/x509ca/*.pem /etc/swanctl/private/*.pem

if [ ! -f "$VPN_CERT_PATH" ]; then
    echo "错误: 找不到证书 $VPN_CERT_PATH"
    exit 1
fi

if [ ! -f "$VPN_KEY_PATH" ]; then
    echo "错误: 找不到私钥 $VPN_KEY_PATH"
    exit 1
fi

cp "$VPN_KEY_PATH" /etc/swanctl/private/privkey.pem
chmod 600 /etc/swanctl/private/privkey.pem

# The configured certificate file must be a fullchain file. swanctl expects the end-entity/server
# certificate under x509/ and CA/intermediate certificates under x509ca/.
# Split the PEM chain so Android/Windows clients can build the trust chain.
awk '
  /-----BEGIN CERTIFICATE-----/ { n++; file = (n == 1 ? "/etc/swanctl/x509/cert.pem" : sprintf("/etc/swanctl/x509ca/chain-%02d.pem", n - 1)) }
  { if (n > 0) print > file }
' "$VPN_CERT_PATH"

if [ ! -s /etc/swanctl/x509/cert.pem ]; then
    echo "错误: 未能从 $VPN_CERT_PATH 提取服务器证书"
    exit 1
fi

echo "运行模式: $VPN_MODE"
echo "VPN_POOL: $VPN_POOL"
echo "VPN_DNS: $VPN_DNS"
echo "VPN_LOCAL_TS: $VPN_LOCAL_TS"
if [ "$VPN_MODE" = "proxyarp" ]; then
    echo "LAN_SUBNET: $LAN_SUBNET"
fi

echo "证书文件: $VPN_CERT_PATH"
echo "私钥文件: $VPN_KEY_PATH"
echo "证书链数量: $(grep -c 'BEGIN CERTIFICATE' "$VPN_CERT_PATH" || true)"
echo "服务器证书信息:"
openssl x509 -in /etc/swanctl/x509/cert.pem -noout -subject -issuer -dates -ext subjectAltName -ext extendedKeyUsage || true

generate_swanctl_config
proxyarp_configure_farp "$VPN_MODE"

# Also removes owned rules left by an ungraceful previous container exit.
proxyarp_gateway_cleanup
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

echo "关键 swanctl 配置:"
grep -E 'send_cert|send_certreq|mobike|fragmentation|proposals|eap_id|local_ts|rekey_time|dns =|secrets|eap-user-' /etc/swanctl/swanctl.conf || true

sysctl -w net.ipv4.ip_forward=1 || true

PUBLIC_IFACE=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)

if [ -z "$PUBLIC_IFACE" ]; then
    echo "无法识别公网网卡"
    ip route
    exit 1
fi

echo "公网网卡: $PUBLIC_IFACE"

VPN_POOL_SRC_ARGS="$(ipt_src_pool_args "$VPN_POOL")"
VPN_POOL_DST_ARGS="$(ipt_dst_pool_args "$VPN_POOL")"

# 允许 VPN 客户端访问部署 IKEv2 这台机器自己的所有服务。
# 访问宿主机本机服务走 INPUT 链，不走 FORWARD 链；没有这条规则时可能出现
# “能访问局域网其他设备，但不能访问 IKEv2 宿主机服务”的现象。
echo "允许 VPN 客户端访问本机服务: $VPN_POOL"
# shellcheck disable=SC2086
iptables_rule_ensure INPUT $VPN_POOL_SRC_ARGS -j ACCEPT

# shellcheck disable=SC2086
iptables_rule_ensure FORWARD $VPN_POOL_SRC_ARGS -j ACCEPT
# shellcheck disable=SC2086
iptables_rule_ensure FORWARD $VPN_POOL_DST_ARGS -m state --state ESTABLISHED,RELATED -j ACCEPT

if [ "$VPN_MODE" = "nat" ]; then
    echo "应用 NAT 模式防火墙规则: VPN 客户端通过 $PUBLIC_IFACE 做 MASQUERADE 出口"
    # shellcheck disable=SC2086
    iptables_rule_ensure -t nat POSTROUTING $VPN_POOL_SRC_ARGS -o "$PUBLIC_IFACE" -j MASQUERADE
else
    echo "应用 Proxy ARP 模式防火墙规则: 不做 MASQUERADE，保留 VPN 客户端同网段源 IP"
    sysctl -w net.ipv4.conf.all.proxy_arp=1 || true
    sysctl -w "net.ipv4.conf.$PUBLIC_IFACE.proxy_arp=1" || true
    # shellcheck disable=SC2086
    iptables_rule_ensure FORWARD $VPN_POOL_SRC_ARGS -d "$LAN_SUBNET" -j ACCEPT
    # shellcheck disable=SC2086
    iptables_rule_ensure FORWARD -s "$LAN_SUBNET" $VPN_POOL_DST_ARGS -j ACCEPT
fi

if [ "$VPN_MODE" = "proxyarp" ]; then
    proxyarp_gateway_apply "$VPN_POOL" "$LAN_SUBNET" "${PROXYARP_GATEWAY:-}"
    if [ -n "${PROXYARP_GATEWAY:-}" ] && [ "$VPN_LOCAL_TS" != "0.0.0.0/0" ]; then
        echo "提示: 指定网关仅影响已进入 VPN 的流量；需要公网全隧道时设置 VPN_ROUTES=0.0.0.0/0 并配置客户端"
    fi
fi

ipsec start --nofork &
IPSEC_PID=$!

sleep 3

swanctl --load-all
swanctl --list-conns

wait $IPSEC_PID
