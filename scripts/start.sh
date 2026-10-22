#!/bin/bash
set -euo pipefail

for module in runtime-config network-config certificates users strongswan proxyarp firewall daemon; do
    source "/usr/local/lib/ikev2/$module.sh"
done

IPSEC_PID=''
cleanup() {
    local status=$?
    trap - EXIT TERM INT
    rm -f /run/ikev2.ready
    daemon_stop "$IPSEC_PID"
    firewall_cleanup || echo '错误: 项目防火墙清理未完成' >&2
    proxyarp_gateway_cleanup || echo '错误: 项目策略路由清理未完成' >&2
    exit "$status"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
rm -f /run/ikev2.ready

declare -A RAW=() CONFIG=()
declare -a USER_NAMES=() USER_HASHES=()
runtime_config_load "${IKEV2_CONFIG_FILE:-/run/ikev2-config/.env}" RAW
network_config_resolve RAW CONFIG
network_host_validate CONFIG
PUBLIC_IFACE="$(network_public_iface)"
CERT_PATH="/ssl/${CONFIG[cert_file]}"
KEY_PATH="/ssl/${CONFIG[key_file]}"

# Validate all input before writing credentials or changing host network rules.
certificates_validate "$CERT_PATH" "$KEY_PATH" "${CONFIG[domain]}"
users_validate /etc/ikev2/users.txt
firewall_preflight
certificates_prepare "$CERT_PATH" "$KEY_PATH" /etc/swanctl
users_load /etc/ikev2/users.txt USER_NAMES USER_HASHES
generate_swanctl_config /etc/swanctl/swanctl.conf CONFIG USER_NAMES USER_HASHES
proxyarp_configure_farp "${CONFIG[mode]}"

for module in xfrm_user xfrm_interface esp4 esp6 xfrm_algo; do modprobe "$module" || true; done
ip xfrm state >/dev/null
sysctl -w net.ipv4.ip_forward=1

# Recover owned resources from abrupt termination or a changed configuration.
proxyarp_gateway_cleanup
firewall_apply CONFIG "$PUBLIC_IFACE"
if [[ "${CONFIG[mode]}" == proxyarp ]]; then
    proxyarp_gateway_apply "${CONFIG[pool]}" "${CONFIG[lan]}" "${CONFIG[gateway]}"
    if [[ -n "${CONFIG[gateway]}" && "${CONFIG[routes]}" != 0.0.0.0/0 ]]; then
        echo '提示: 网关仅影响已进入 VPN 的流量；全局上网需配置 VPN_ROUTES 和客户端全隧道'
    fi
fi
printf '运行模式: %s\nVPN_POOL: %s\nVPN_DNS: %s\nVPN_LOCAL_TS: %s\n公网网卡: %s\n' \
    "${CONFIG[mode]}" "${CONFIG[pool]}" "${CONFIG[dns]}" "${CONFIG[routes]}" "$PUBLIC_IFACE"

ipsec start --nofork &
IPSEC_PID=$!
daemon_wait_ready "$IPSEC_PID" 30
swanctl --load-all
swanctl --list-conns
touch /run/ikev2.ready
echo 'IKEv2 已就绪'
wait "$IPSEC_PID"
