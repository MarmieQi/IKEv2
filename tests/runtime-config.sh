#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../scripts/lib/runtime-config.sh"
declare -A RAW=()
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# Parsing publishes data without modifying the caller's environment.
export PROXYARP_GATEWAY=192.168.0.99
cat > "$test_dir/.env" <<'EOF'
  # Comments and blank lines are allowed.
VPN_MODE = proxyarp
VPN_DOMAIN="vpn.example.com" # comment
PROXYARP_GATEWAY=192.168.0.4 # next hop
VPN_DNS='218.6.200.139'
VPN_ROUTES=
VPN_CERT_FILE="certificate #1.crt"
PATH=/must-not-replace-the-process-path
COMPOSE_PROJECT_NAME=ikev2
EOF
original_path="$PATH"
runtime_config_load "$test_dir/.env" RAW
[[ "${RAW[VPN_MODE]}" == proxyarp && "${RAW[PROXYARP_GATEWAY]}" == 192.168.0.4 ]] || fail 'map parsing'
[[ "$PROXYARP_GATEWAY" == 192.168.0.99 && "$PATH" == "$original_path" ]] || fail 'mutated environment'
[[ "${RAW[VPN_DNS]}" == 218.6.200.139 && "${RAW[VPN_ROUTES]}" == '' ]] || fail 'empty value'
[[ "${RAW[VPN_CERT_FILE]}" == 'certificate #1.crt' ]] || fail quotes
printf 'VPN_MODE=proxyarp\r\nPROXYARP_GATEWAY=192.168.0.5\r\n' > "$test_dir/replacement"
mv "$test_dir/replacement" "$test_dir/.env"
runtime_config_load "$test_dir/.env" RAW
[[ "${RAW[PROXYARP_GATEWAY]}" == 192.168.0.5 && ! -v RAW[VPN_DNS] ]] || fail 'stale values'
printf '# PROXYARP_GATEWAY=192.168.0.5\nVPN_MODE=proxyarp' > "$test_dir/.env"
runtime_config_load "$test_dir/.env" RAW
[[ ! -v RAW[PROXYARP_GATEWAY] ]] || fail 'commented value persisted'
printf 'VPN_DOMAIN=$(touch %s/executed)\nVPN_CERT_FILE=${HOME}\n' "$test_dir" > "$test_dir/.env"
runtime_config_load "$test_dir/.env" RAW
[[ ! -e "$test_dir/executed" && "${RAW[VPN_CERT_FILE]}" == '${HOME}' ]] || fail 'executed config'
for invalid in 'VPN_MODE' 'VPN_DOMAIN="unterminated' "VPN_DOMAIN='unterminated" 'VPN_DNS=1.1.1.1
VPN_DNS=8.8.8.8' 'PROXYARP_GATWAY=192.168.0.4' 'USER_0_NAME=x' 'PROXYARP_VPN_POOL=192.168.0.0/24' 'USER_1_NAME=x'; do
    printf '%s\n' "$invalid" > "$test_dir/.env"
    if runtime_config_load "$test_dir/.env" RAW; then fail 'accepted invalid config'; fi
done
if runtime_config_load "$test_dir/missing" RAW; then fail 'accepted missing config'; fi
runtime_config_load "$(dirname "$0")/../.env.example" RAW
[[ "${RAW[VPN_MODE]}" == nat && "${RAW[VPN_DOMAIN]}" == vpn.example.com ]] || fail template
echo 'PASS: config map, no environment mutation, reload, quotes and errors'
