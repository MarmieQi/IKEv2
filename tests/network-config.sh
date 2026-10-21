#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../scripts/lib/runtime-config.sh"
source "$(dirname "$0")/../scripts/lib/network-config.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
load_env() { cat > "$test_dir/.env"; runtime_config_load "$test_dir/.env"; }
load_env <<'EOF'
VPN_MODE=proxyarp
PROXYARP_POOL=192.168.0.201-192.168.0.210
PROXYARP_LAN=192.168.0.0/24
PROXYARP_GATEWAY=192.168.0.4
VPN_DNS=218.6.200.139,61.139.2.69,1.1.1.1
VPN_ROUTES=0.0.0.0/0
EOF
network_config_resolve
[[ "$VPN_POOL" == 192.168.0.201-192.168.0.210 && "$LAN_SUBNET" == 192.168.0.0/24 ]] || fail pool
[[ "$VPN_DNS" == 218.6.200.139,61.139.2.69,1.1.1.1 && "$VPN_LOCAL_TS" == 0.0.0.0/0 ]] || fail lists
for invalid in 'VPN_DNS=999.1.1.1' 'VPN_DNS=1.1.1.1,' 'VPN_ROUTES=0.0.0.0/33' 'VPN_ROUTES=1.1.1.1'; do
    load_env <<< "$invalid"
    if network_config_resolve; then fail 'accepted invalid network list'; fi
done
load_env <<'EOF'
VPN_MODE=proxyarp
EOF
network_config_resolve
[[ "$VPN_DNS" == 192.168.0.1,1.1.1.1 && "$VPN_LOCAL_TS" == 192.168.0.0/24 ]] || fail 'Proxy ARP defaults'
load_env <<'EOF'
VPN_MODE=nat
NAT_POOL=10.67.0.0/24
EOF
network_config_resolve
[[ "$VPN_POOL" == 10.67.0.0/24 && "$VPN_DNS" == 1.1.1.1,8.8.8.8 && "$VPN_LOCAL_TS" == 0.0.0.0/0 ]] || fail 'NAT defaults'
echo 'PASS: canonical network settings, lists and defaults'
