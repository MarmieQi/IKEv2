#!/bin/bash
set -euo pipefail

VPN_MODE="${VPN_MODE:-nat}"
VPN_DOMAIN="${VPN_DOMAIN:?缺少 VPN_DOMAIN}"
VPN_USERS_FILE="${VPN_USERS_FILE:-/etc/ikev2/users.txt}"
VPN_CERT_FILE="${VPN_CERT_FILE:-server.crt}"
VPN_KEY_FILE="${VPN_KEY_FILE:-server.key}"
VPN_CERT_PATH="/ssl/$VPN_CERT_FILE"
VPN_KEY_PATH="/ssl/$VPN_KEY_FILE"

# 从 IPv4/CIDR 或 IPv4 范围取第一个 IP。
# 例如：192.168.0.240/28 -> 192.168.0.240
# 例如：192.168.0.180-192.168.0.200 -> 192.168.0.180
pool_first_ip() {
    local pool="$1"
    pool="${pool%%/*}"
    pool="${pool%%-*}"
    echo "$pool"
}

# 从 IPv4/CIDR 或 IPv4 范围自动推导 /24 局域网。
# 例如：192.168.0.240/28 -> 192.168.0.0/24
# 例如：192.168.0.180-192.168.0.200 -> 192.168.0.0/24
derive_ipv4_lan24() {
    local ip
    ip="$(pool_first_ip "$1")"
    IFS='.' read -r a b c d <<EOF
$ip
EOF
    if [ -z "${a:-}" ] || [ -z "${b:-}" ] || [ -z "${c:-}" ] || [ -z "${d:-}" ]; then
        return 1
    fi
    echo "$a.$b.$c.0/24"
}

# 从 IPv4/CIDR 或 IPv4 范围自动推导网关 DNS。
# 例如：192.168.0.240/28 -> 192.168.0.1
# 例如：192.168.0.180-192.168.0.200 -> 192.168.0.1
derive_ipv4_gateway() {
    local ip
    ip="$(pool_first_ip "$1")"
    IFS='.' read -r a b c d <<EOF
$ip
EOF
    if [ -z "${a:-}" ] || [ -z "${b:-}" ] || [ -z "${c:-}" ] || [ -z "${d:-}" ]; then
        return 1
    fi
    echo "$a.$b.$c.1"
}

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

escape_swanctl_secret() {
    # swanctl.conf 使用双引号包裹 secret，这里只转义反斜杠和双引号。
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

generate_eap_secrets() {
    if [ ! -f "$VPN_USERS_FILE" ]; then
        echo "错误: 找不到账号文件 $VPN_USERS_FILE" >&2
        echo "请检查默认的 config/users.txt 是否正确挂载" >&2
        exit 1
    fi

    local tmp_file count line user pass escaped_pass
    tmp_file="$(mktemp)"
    count=0

    {
        echo ""
        echo "secrets {"
    } > "$tmp_file"

    while IFS= read -r line || [ -n "$line" ]; do
        # 跳过空行和注释行。
        case "$line" in
            ''|'#'*) continue ;;
        esac

        if ! echo "$line" | grep -q ':'; then
            echo "错误: 账号文件存在无效行，必须使用 用户名:密码 格式：$line" >&2
            rm -f "$tmp_file"
            exit 1
        fi

        user="${line%%:*}"
        pass="${line#*:}"

        if [ -z "$user" ] || [ -z "$pass" ]; then
            echo "错误: 账号文件存在空用户名或空密码：$line" >&2
            rm -f "$tmp_file"
            exit 1
        fi

        count=$((count + 1))
        escaped_pass="$(escape_swanctl_secret "$pass")"

        {
            echo "    eap-user-$count {"
            echo "        id = $user"
            echo "        secret = \"$escaped_pass\""
            echo "    }"
            echo ""
        } >> "$tmp_file"
    done < "$VPN_USERS_FILE"

    if [ "$count" -eq 0 ]; then
        echo "错误: 账号文件 $VPN_USERS_FILE 没有有效账号" >&2
        rm -f "$tmp_file"
        exit 1
    fi

    echo "}" >> "$tmp_file"
    cat "$tmp_file"
    rm -f "$tmp_file"

    echo "已加载 EAP 账号数量: $count" >&2
}

generate_swanctl_config() {
    cat > /etc/swanctl/swanctl.conf <<EOF
connections {
    ikev2-mschapv2 {
        version = 2
        local_addrs = %any
        remote_addrs = %any

        send_cert = always
        send_certreq = no
        encap = yes
        fragmentation = yes
        mobike = yes
        unique = never

        pools = vpn-pool

        # Windows requires MODP2048 in the first proposal when the gateway initiates IKE rekeying.
        proposals = aes256-sha256-modp2048,aes256-sha256-modp4096,aes128-sha256-modp2048,aes256-sha256-modp1024,aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024

        local {
            auth = pubkey
            certs = cert.pem
            id = $VPN_DOMAIN
        }

        remote {
            auth = eap-mschapv2
            eap_id = %any
        }

        children {
            net {
                local_ts = $VPN_LOCAL_TS
                esp_proposals = aes256-sha256,aes128-sha256,aes256-sha1,aes128-sha1,3des-sha1
                # Windows clients behind NAT may not answer gateway-initiated CHILD_SA rekeying.
                # Let the client initiate CHILD_SA rekeying instead.
                rekey_time = 0
                dpd_action = clear
                start_action = none
            }
        }
    }
}

pools {
    vpn-pool {
        addrs = $VPN_POOL
        dns = $VPN_DNS1, $VPN_DNS2
    }
}
EOF

    generate_eap_secrets >> /etc/swanctl/swanctl.conf
}

case "$VPN_MODE" in
    nat)
        # NAT 模式独立配置。可以和 Proxy ARP 配置同时存在。
        VPN_POOL="${NAT_VPN_POOL:-10.66.0.0/24}"
        VPN_DNS1="${NAT_DNS1:-1.1.1.1}"
        VPN_DNS2="${NAT_DNS2:-8.8.8.8}"
        VPN_LOCAL_TS="${NAT_LOCAL_TS:-0.0.0.0/0}"
        LAN_SUBNET="${LAN_SUBNET:-}"
        ;;
    proxyarp)
        # Proxy ARP 模式独立配置。通常只需要填写 PROXYARP_VPN_POOL。
        VPN_POOL="${PROXYARP_VPN_POOL:-192.168.0.240/28}"
        AUTO_LAN_SUBNET="$(derive_ipv4_lan24 "$VPN_POOL" || true)"
        AUTO_LAN_DNS="$(derive_ipv4_gateway "$VPN_POOL" || true)"
        LAN_SUBNET="${PROXYARP_LAN_SUBNET:-${LAN_SUBNET:-${AUTO_LAN_SUBNET}}}"
        if [ -z "$LAN_SUBNET" ]; then
            echo "错误: 无法从 PROXYARP_VPN_POOL=$VPN_POOL 自动推导 LAN_SUBNET，请手动设置 PROXYARP_LAN_SUBNET"
            exit 1
        fi
        VPN_LOCAL_TS="${PROXYARP_LOCAL_TS:-$LAN_SUBNET}"
        VPN_DNS1="${PROXYARP_DNS1:-${AUTO_LAN_DNS:-1.1.1.1}}"
        VPN_DNS2="${PROXYARP_DNS2:-1.1.1.1}"
        ;;
    *)
        echo "错误: 不支持的 VPN_MODE=$VPN_MODE，只能是 nat 或 proxyarp"
        exit 1
        ;;
esac

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
echo "VPN_DNS: $VPN_DNS1, $VPN_DNS2"
echo "VPN_LOCAL_TS: $VPN_LOCAL_TS"
echo "VPN_USERS_FILE: $VPN_USERS_FILE"
if [ "$VPN_MODE" = "proxyarp" ]; then
    echo "LAN_SUBNET: $LAN_SUBNET"
fi

echo "证书文件: $VPN_CERT_PATH"
echo "私钥文件: $VPN_KEY_PATH"
echo "证书链数量: $(grep -c 'BEGIN CERTIFICATE' "$VPN_CERT_PATH" || true)"
echo "服务器证书信息:"
openssl x509 -in /etc/swanctl/x509/cert.pem -noout -subject -issuer -dates -ext subjectAltName -ext extendedKeyUsage || true

generate_swanctl_config

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

ipsec start --nofork &
IPSEC_PID=$!

sleep 3

swanctl --load-all
swanctl --list-conns

wait $IPSEC_PID
