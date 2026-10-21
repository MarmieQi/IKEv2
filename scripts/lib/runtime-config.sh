#!/bin/bash
# Read literal VPN settings without executing the mounted file as shell code.
runtime_config_key_known() {
    case "$1" in
        VPN_MODE|VPN_DOMAIN|VPN_CERT_FILE|VPN_KEY_FILE|VPN_DNS|VPN_ROUTES|\
        NAT_POOL|PROXYARP_POOL|PROXYARP_LAN|PROXYARP_GATEWAY) return 0 ;;
    esac
    return 1
}

# Only escaped quotes/backslashes are decoded; no shell interpolation occurs.
runtime_config_value() {
    local value="$1" quote char next tail result='' i
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    quote="${value:0:1}"
    if [[ "$quote" != \" && "$quote" != \' ]]; then
        value="${value%%[[:space:]]\#*}"
        RUNTIME_CONFIG_VALUE="${value%"${value##*[![:space:]]}"}"
        return 0
    fi
    for ((i=1; i<${#value}; i++)); do
        char="${value:i:1}"
        if [[ "$char" == \\ ]]; then
            next="${value:i+1:1}"
            if [[ "$next" == "$quote" || "$next" == \\ ]]; then
                result+="$next"
                i=$((i + 1))
                continue
            fi
        fi
        if [[ "$char" == "$quote" ]]; then
            tail="${value:i+1}"
            [[ -z "$tail" || "$tail" =~ ^[[:space:]]+(\#.*)?$ ]] || return 1
            RUNTIME_CONFIG_VALUE="$result"
            return 0
        fi
        result+="$char"
    done
    return 1
}

runtime_config_load() {
    local file="$1" line key value number=0
    local -a keys=(
        VPN_MODE VPN_DOMAIN VPN_CERT_FILE VPN_KEY_FILE VPN_DNS VPN_ROUTES
        NAT_POOL PROXYARP_POOL PROXYARP_LAN PROXYARP_GATEWAY
    )
    local -A settings=()
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        echo "错误: 无法读取运行配置 $file" >&2
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        number=$((number + 1))
        line="${line%$'\r'}"
        if (( number == 1 )); then line="${line#$'\xef\xbb\xbf'}"; fi
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            echo "错误: $file 第 $number 行必须使用 KEY=VALUE 格式" >&2
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if ! runtime_config_key_known "$key"; then
            case "$key" in
                VPN_*|NAT_*|PROXYARP_*|USER_*|LAN_SUBNET)
                    echo "错误: $file 第 $number 行配置项不认识: $key" >&2
                    return 1 ;;
                *) continue ;;
            esac
        fi
        if [[ -v "settings[$key]" ]]; then
            echo "错误: $file 第 $number 行配置项重复: $key" >&2
            return 1
        fi
        if ! runtime_config_value "$value"; then
            echo "错误: $file 第 $number 行的引号格式不正确 ($key)" >&2
            return 1
        fi
        settings["$key"]="$RUNTIME_CONFIG_VALUE"
    done < "$file"

    # The file is authoritative. Removing/commenting a setting restores its
    # default, rather than keeping the environment from container creation.
    for key in "${keys[@]}"; do
        unset "$key"
    done
    for key in "${!settings[@]}"; do
        printf -v "$key" '%s' "${settings[$key]}"
        export "$key"
    done
    echo "已读取运行配置: $file"
}
