#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../scripts/lib/runtime-config.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

export PROXYARP_GATEWAY=192.168.0.99 PROXYARP_DNS1=9.9.9.9 VPN_MODE=nat
cat > "$test_dir/.env" <<'EOF'
  # Comments and blank lines are allowed.

VPN_MODE = proxyarp
VPN_DOMAIN="vpn.example.com" # comment
PROXYARP_GATEWAY=192.168.0.4 # next hop
PROXYARP_DNS1='218.6.200.139'
PROXYARP_DNS2=
VPN_CERT_FILE="certificate #1.crt"
PATH=/must-not-replace-the-process-path
COMPOSE_PROJECT_NAME=ikev2
EOF
original_path="$PATH"
runtime_config_load "$test_dir/.env"
[[ "$VPN_MODE" == proxyarp && "$PROXYARP_GATEWAY" == 192.168.0.4 ]] || fail 'file did not override environment'
[[ "$PROXYARP_DNS1" == 218.6.200.139 && "$PROXYARP_DNS2" == '' ]] || fail 'DNS parsing'
[[ "$VPN_CERT_FILE" == 'certificate #1.crt' && "$VPN_DOMAIN" == vpn.example.com ]] || fail 'quoted values'
[[ "$PATH" == "$original_path" ]] || fail 'imported a non-VPN variable'

# Model another startup after an editor replaces the file, with a deleted key.
printf 'VPN_MODE=proxyarp\r\nPROXYARP_GATEWAY=192.168.0.5\r\n' > "$test_dir/replacement"
mv "$test_dir/replacement" "$test_dir/.env"
runtime_config_load "$test_dir/.env"
[[ "$PROXYARP_GATEWAY" == 192.168.0.5 ]] || fail 'did not read replaced file'
[[ ! -v PROXYARP_DNS1 && ! -v VPN_CERT_FILE ]] || fail 'removed settings kept stale values'
printf '# PROXYARP_GATEWAY=192.168.0.5\nVPN_MODE=proxyarp' > "$test_dir/.env"
runtime_config_load "$test_dir/.env"
[[ ! -v PROXYARP_GATEWAY ]] || fail 'commented gateway did not restore default'

# Neither command substitution nor variable interpolation may execute.
printf 'VPN_DOMAIN=$(touch %s/executed)\nVPN_CERT_FILE=${HOME}\n' "$test_dir" > "$test_dir/.env"
runtime_config_load "$test_dir/.env"
[[ ! -e "$test_dir/executed" && "$VPN_CERT_FILE" == '${HOME}' ]] || fail 'executed config'
[[ "$VPN_DOMAIN" == \$\(touch* ]] || fail 'expanded literal command'
for invalid in 'VPN_MODE' 'VPN_DOMAIN="unterminated' "VPN_DOMAIN='unterminated" 'VPN_DNS=1.1.1.1
VPN_DNS=8.8.8.8' 'PROXYARP_GATWAY=192.168.0.4' 'USER_0_NAME=x'; do
    printf '%s\n' "$invalid" > "$test_dir/.env"
    if runtime_config_load "$test_dir/.env"; then fail 'accepted malformed config'; fi
done
if runtime_config_load "$test_dir/missing"; then fail 'accepted missing config'; fi

# All supported defaults in the shipped template must remain parseable.
runtime_config_load "$(dirname "$0")/../.env.example"
[[ "$VPN_MODE" == nat && "$VPN_DOMAIN" == vpn.example.com ]] || fail 'template parsing'
echo 'PASS: runtime configuration reload, removed keys, quotes, CRLF, literal values and validation'
