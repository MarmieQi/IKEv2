#!/bin/bash
# Run inside the disposable image during build, against its real strongSwan.
# Exercise the same generator and includes used at runtime in both modes.
set -euo pipefail
source /usr/local/lib/ikev2/proxyarp.sh
source /usr/local/lib/ikev2/users.sh
source /usr/local/lib/ikev2/network-config.sh
source /usr/local/lib/ikev2/strongswan.sh
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"; rm -f /etc/strongswan.d/ikev2-farp.conf' EXIT

check_config() {
    local status=0
    swanctl --stats --uri "unix://$test_dir/nonexistent.vici" > "$test_dir/output" 2>&1 || status=$?
    # The isolated socket intentionally has no daemon. Reaching VICI connection
    # proves library initialization parsed the complete strongswan.conf first.
    if [[ "$status" == 0 ]] || \
       grep -Eq 'syntax error|invalid config file|abort initialization' "$test_dir/output" || \
       ! grep -Eq 'connecting to .*failed' "$test_dir/output"; then
        cat "$test_dir/output" >&2
        echo 'FAIL: strongSwan did not successfully parse its runtime settings' >&2
        return 1
    fi
}

# First prove this test detects the regression, rather than accepting any failure.
printf 'charon.plugins.farp.load = yes\n' > /etc/strongswan.d/ikev2-farp.conf
if check_config > "$test_dir/regression-output" 2>&1; then
    echo 'FAIL: parser test accepted the known invalid dotted key' >&2
    exit 1
fi
printf '%s\n' 'test.user:colon:# dollar:$ backslash:\ quote:"' > "$test_dir/users.txt"
declare -a USER_NAMES=() USER_HASHES=()
users_load "$test_dir/users.txt" USER_NAMES USER_HASHES
declare -A RAW=([VPN_DOMAIN]=vpn.example.com) CONFIG=()
for mode in nat proxyarp; do
    proxyarp_configure_farp "$mode"
    check_config
    RAW[VPN_MODE]="$mode"
    network_config_resolve RAW CONFIG
    generate_swanctl_config /etc/swanctl/swanctl.conf CONFIG USER_NAMES USER_HASHES
    STRONGSWAN_CONF=/etc/swanctl/swanctl.conf check_config
done
generate_eap_secrets USER_NAMES USER_HASHES > "$test_dir/accounts.conf"
STRONGSWAN_CONF="$test_dir/accounts.conf" check_config
echo 'PASS: generated NAT, Proxy ARP and NTLM credentials parsed by the image strongSwan'
