#!/bin/bash
# Read literal VPN settings without executing the mounted file as shell code.
runtime_config_load() {
    local file="$1" line key value number=0
    local -a keys=(
        VPN_MODE VPN_DOMAIN VPN_USERS_FILE VPN_CERT_FILE VPN_KEY_FILE LAN_SUBNET
        NAT_VPN_POOL NAT_DNS1 NAT_DNS2 NAT_LOCAL_TS
        PROXYARP_VPN_POOL PROXYARP_LAN_SUBNET PROXYARP_LOCAL_TS
        PROXYARP_GATEWAY PROXYARP_DNS1 PROXYARP_DNS2
    )
    local -A settings=()
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        echo "错误: 无法读取运行配置 $file" >&2
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        number=$((number + 1))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            echo "错误: $file 第 $number 行必须使用 KEY=VALUE 格式" >&2
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        # Other Compose settings are allowed but never imported into the shell.
        case " ${keys[*]} " in *" $key "*) ;; *) continue ;; esac
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" == \"* ]]; then
            if [[ "$value" =~ ^\"([^\"]*)\"([[:space:]]*\#.*)?$ ]]; then
                value="${BASH_REMATCH[1]}"
            else
                echo "错误: $file 第 $number 行的双引号格式不正确" >&2
                return 1
            fi
        elif [[ "$value" == \'* ]]; then
            if [[ "$value" =~ ^\'([^\']*)\'([[:space:]]*\#.*)?$ ]]; then
                value="${BASH_REMATCH[1]}"
            else
                echo "错误: $file 第 $number 行的单引号格式不正确" >&2
                return 1
            fi
        else
            value="${value%%[[:space:]]\#*}"
            value="${value%"${value##*[![:space:]]}"}"
        fi
        settings["$key"]="$value"
    done < "$file"

    # The file is authoritative. Removing/commenting a setting restores its
    # default, rather than keeping the environment from container creation.
    for key in "${keys[@]}"; do
        unset "$key"
        if [[ -v "settings[$key]" ]]; then
            printf -v "$key" '%s' "${settings[$key]}"
            export "$key"
        fi
    done
    echo "已读取运行配置: $file"
}
