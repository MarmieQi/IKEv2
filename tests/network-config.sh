#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../scripts/lib/runtime-config.sh"
source "$(dirname "$0")/../scripts/lib/network-config.sh"
declare -A RAW=() CONFIG=()
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
load_env() { printf "VPN_DOMAIN=vpn.example.com\n" > "$test_dir/.env"; cat >> "$test_dir/.env"; runtime_config_load "$test_dir/.env" RAW; }
load_env <<'EOF'
VPN_MODE=proxyarp
PROXYARP_POOL=192.168.0.201-192.168.0.210
PROXYARP_LAN=192.168.0.0/24
PROXYARP_GATEWAY=192.168.0.4
VPN_DNS=218.6.200.139,61.139.2.69,1.1.1.1
VPN_ROUTES=0.0.0.0/0
EOF
network_config_resolve RAW CONFIG
[[ "${CONFIG[pool]}" == 192.168.0.201-192.168.0.210 && "${CONFIG[lan]}" == 192.168.0.0/24 ]] || fail pool
[[ "${CONFIG[dns]}" == 218.6.200.139,61.139.2.69,1.1.1.1 && "${CONFIG[routes]}" == 0.0.0.0/0 ]] || fail lists
for invalid in 'VPN_DNS=999.1.1.1' 'VPN_DNS=1.1.1.1,' 'VPN_ROUTES=0.0.0.0/33' 'VPN_ROUTES=1.1.1.1'; do
    load_env <<< "$invalid"
    if network_config_resolve RAW CONFIG; then fail 'accepted invalid network list'; fi
done
load_env <<'EOF'
VPN_MODE=proxyarp
EOF
network_config_resolve RAW CONFIG
[[ "${CONFIG[dns]}" == 192.168.0.1,1.1.1.1 && "${CONFIG[routes]}" == 192.168.0.0/24 ]] || fail 'Proxy ARP defaults'
load_env <<'EOF'
VPN_MODE=nat
NAT_POOL=10.67.0.0/24
EOF
network_config_resolve RAW CONFIG
[[ "${CONFIG[pool]}" == 10.67.0.0/24 && "${CONFIG[dns]}" == 1.1.1.1,8.8.8.8 && "${CONFIG[routes]}" == 0.0.0.0/0 ]] || fail 'NAT defaults'

for invalid in 'VPN_MODE=invalid' 'VPN_CERT_FILE=../server.crt' 'VPN_KEY_FILE=/etc/passwd' 'NAT_POOL=10.66.0.1/24'; do
    load_env <<< "$invalid"
    if network_config_resolve RAW CONFIG; then fail 'accepted unsafe configuration'; fi
done
load_env </dev/null
RAW[VPN_DOMAIN]='invalid{domain}'
if network_config_resolve RAW CONFIG; then fail 'accepted unsafe domain'; fi
for invalid in 'PROXYARP_POOL=192.168.0.240/28' 'PROXYARP_GATEWAY=192.168.0.201' 'PROXYARP_GATEWAY=192.168.1.4'; do
    load_env <<EOF
VPN_MODE=proxyarp
$invalid
EOF
    if network_config_resolve RAW CONFIG; then fail 'accepted invalid Proxy ARP pool/gateway'; fi
done
echo 'PASS: canonical network settings, lists and defaults'
