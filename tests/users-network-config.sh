#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../scripts/lib/runtime-config.sh"
source "$(dirname "$0")/../scripts/lib/users.sh"
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
USER_2_NAME=user2
USER_2_PASSWORD='p:a # $() `literal`'
USER_9_NAME='quoted"name'
USER_9_PASSWORD="both\"quotes'and\\slash"
EOF
network_config_resolve
[[ "$VPN_POOL" == 192.168.0.201-192.168.0.210 && "$LAN_SUBNET" == 192.168.0.0/24 ]] || fail 'new network settings'
[[ "$VPN_DNS" == 218.6.200.139,61.139.2.69,1.1.1.1 && "$VPN_LOCAL_TS" == 0.0.0.0/0 ]] || fail 'public settings'
printf 'legacy:must-not-merge\n' > "$test_dir/users.txt"
users_load "$test_dir/users.txt"
[[ ${#IKEV2_USER_NAMES[@]} == 2 && "${IKEV2_USER_NAMES[0]}" == user2 ]] || fail 'numbered users/order'
[[ "${IKEV2_USER_PASSWORDS[0]}" == 'p:a # $() `literal`' ]] || fail 'literal password'
[[ "${IKEV2_USER_PASSWORDS[1]}" == 'both"quotes'"'"'and\slash' ]] || fail 'escaped password'
generate_eap_secrets > "$test_dir/secrets"
grep -Fq 'id = "quoted\"name"' "$test_dir/secrets" || fail 'username escaping'
grep -Fq 'and\\slash"' "$test_dir/secrets" || fail 'password escaping'

# Existing deployment remains unchanged until the owner adds new settings.
load_env <<'EOF'
VPN_MODE=proxyarp
PROXYARP_VPN_POOL=192.168.0.201-192.168.0.210
PROXYARP_DNS1=218.6.200.139
PROXYARP_DNS2=61.139.2.69
PROXYARP_LOCAL_TS=0.0.0.0/0
EOF
network_config_resolve
users_load "$test_dir/users.txt"
[[ "$VPN_DNS" == 218.6.200.139,61.139.2.69 && "$VPN_LOCAL_TS" == 0.0.0.0/0 ]] || fail 'legacy network settings'
[[ ${#IKEV2_USER_NAMES[@]} == 1 && "${IKEV2_USER_NAMES[0]}" == legacy ]] || fail 'legacy account fallback'

load_env <<'EOF'
VPN_MODE=nat
NAT_POOL=10.67.0.0/24
NAT_VPN_POOL=10.66.0.0/24
VPN_DNS=192.168.0.4
NAT_DNS1=1.1.1.1
VPN_ROUTES=192.168.0.0/24,10.0.0.0/8
NAT_LOCAL_TS=0.0.0.0/0
EOF
network_config_resolve
[[ "$VPN_POOL" == 10.67.0.0/24 && "$VPN_DNS" == 192.168.0.4 && "$VPN_LOCAL_TS" == 192.168.0.0/24,10.0.0.0/8 ]] || fail 'new settings did not override aliases'

for invalid in 'USER_1_NAME=missing-password' 'USER_1_PASSWORD=missing-name' 'USER_1_NAME=x
USER_1_PASSWORD=' 'USER_1_NAME=x
USER_1_PASSWORD=p
USER_3_NAME=x
USER_3_PASSWORD=q'; do
    load_env <<< "$invalid"
    if users_load "$test_dir/users.txt"; then fail 'invalid users fell back to legacy'; fi
done
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
EOF
network_config_resolve
[[ "$VPN_DNS" == 1.1.1.1,8.8.8.8 && "$VPN_LOCAL_TS" == 0.0.0.0/0 ]] || fail 'NAT defaults'

cat > "$test_dir/old.env" <<'EOF'
VPN_DOMAIN=vpn.example.com
VPN_MODE=proxyarp
PROXYARP_VPN_POOL=192.168.0.201-192.168.0.210
PROXYARP_DNS1=218.6.200.139
PROXYARP_DNS2=61.139.2.69
PROXYARP_LOCAL_TS=0.0.0.0/0
PROXYARP_GATEWAY=192.168.0.4
COMPOSE_PROJECT_NAME=personal-vpn
EOF
cat > "$test_dir/users.txt" <<'EOF'
first:p:a # $"\word
second:other'password
EOF
cp "$test_dir/old.env" "$test_dir/original"
bash "$(dirname "$0")/../scripts/migrate-config.sh" "$test_dir/old.env" "$test_dir/users.txt"
runtime_config_load "$test_dir/old.env"
users_load "$test_dir/users.txt"
network_config_resolve
[[ "$VPN_DNS" == 218.6.200.139,61.139.2.69 && "$PROXYARP_GATEWAY" == 192.168.0.4 ]] || fail 'migration changed network'
[[ ${#IKEV2_USER_NAMES[@]} == 2 && "${IKEV2_USER_PASSWORDS[0]}" == 'p:a # $"\word' ]] || fail 'migration changed passwords'
grep -Fq '# 5. 用户账号' "$test_dir/old.env" || fail 'migration lost template comments'
grep -Fxq 'COMPOSE_PROJECT_NAME=personal-vpn' "$test_dir/old.env" || fail 'migration lost Compose settings'
backup_files=("$test_dir"/old.env.backup.*)
cmp -s "$test_dir/original" "${backup_files[0]}" || fail 'migration did not preserve backup'
[[ "$(stat -c %a "$test_dir/old.env")" == 600 ]] || fail 'migration file permissions'
bash "$(dirname "$0")/../scripts/migrate-config.sh" "$test_dir/old.env" "$test_dir/users.txt"
runtime_config_load "$test_dir/old.env"
[[ "$USER_1_PASSWORD" == 'p:a # $"\word' ]] || fail 'repeat migration changed password'
echo 'PASS: unified accounts, escaping, aliases, lists, defaults and invalid configurations'
