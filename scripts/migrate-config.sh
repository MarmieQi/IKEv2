#!/bin/bash
# Convert the existing deployment to the annotated single-file format.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_dir/scripts/lib/runtime-config.sh"
source "$project_dir/scripts/lib/users.sh"
source "$project_dir/scripts/lib/network-config.sh"
config_file="${1:-$project_dir/.env}"
legacy_file="${2:-$project_dir/config/users.txt}"
runtime_config_load "$config_file"
users_load "${VPN_USERS_FILE:-$legacy_file}"
network_config_resolve
: "${VPN_DOMAIN:?请先填写 VPN_DOMAIN}"

declare -A values=(
    [VPN_DOMAIN]="$VPN_DOMAIN" [VPN_MODE]="$VPN_MODE"
    [VPN_CERT_FILE]="${VPN_CERT_FILE:-server.crt}"
    [VPN_KEY_FILE]="${VPN_KEY_FILE:-server.key}"
    [VPN_DNS]="$VPN_DNS" [VPN_ROUTES]="$VPN_LOCAL_TS"
    [NAT_POOL]="${NAT_POOL:-${NAT_VPN_POOL:-10.66.0.0/24}}"
    [PROXYARP_POOL]="${PROXYARP_POOL:-${PROXYARP_VPN_POOL:-192.168.0.240/28}}"
    [PROXYARP_GATEWAY]="${PROXYARP_GATEWAY:-}"
)
if [[ "$VPN_MODE" == proxyarp ]]; then
    values[PROXYARP_LAN]="$LAN_SUBNET"
elif [[ -n "${PROXYARP_LAN:-${PROXYARP_LAN_SUBNET:-}}" ]]; then
    values[PROXYARP_LAN]="${PROXYARP_LAN:-$PROXYARP_LAN_SUBNET}"
fi
for ((i=0; i<${#IKEV2_USER_NAMES[@]}; i++)); do
    values[USER_$((i+1))_NAME]="${IKEV2_USER_NAMES[i]}"
    values[USER_$((i+1))_PASSWORD]="${IKEV2_USER_PASSWORDS[i]}"
done

quote_value() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\'/\\\'}"
    # Single quotes also keep Docker Compose from interpolating password dollars.
    printf "'%s'" "$value"
}
umask 077
temporary="$(mktemp "${config_file}.migrate.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT
declare -A emitted=()
while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^(#[[:space:]]*)?([A-Z][A-Z0-9_]*)= ]]; then
        key="${BASH_REMATCH[2]}"
        if [[ -v "values[$key]" ]]; then
            printf '%s=%s\n' "$key" "$(quote_value "${values[$key]}")" >> "$temporary"
            emitted[$key]=yes
            continue
        fi
    fi
    printf '%s\n' "$line" >> "$temporary"
done < "$project_dir/.env.example"
while IFS= read -r key; do
    if [[ ! -v "emitted[$key]" ]]; then
        printf '%s=%s\n' "$key" "$(quote_value "${values[$key]}")" >> "$temporary"
    fi
done < <(printf '%s\n' "${!values[@]}" | sort -V)

# Preserve non-VPN Compose settings (e.g. COMPOSE_PROJECT_NAME) verbatim.
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
        key="${BASH_REMATCH[1]}"
        if ! runtime_config_key_known "$key"; then
            printf '%s\n' "$line" >> "$temporary"
        fi
    fi
done < "$config_file"

# Validate the complete result before touching the user's original file.
runtime_config_load "$temporary"
users_load "$legacy_file"
network_config_resolve
backup="$(mktemp "${config_file}.backup.XXXXXX")"
cp -- "$config_file" "$backup"
chmod 600 "$backup" "$temporary"
mv -- "$temporary" "$config_file"
echo "迁移完成，旧配置备份: $backup"
echo '账号已写入 .env。确认后请清空旧 users.txt 中的有效账号，避免以后恢复旧账号。'
echo '容器升级后，docker compose restart 即可应用。'
