#!/bin/bash
# A single account model for .env users and the legacy users.txt fallback.
declare -a IKEV2_USER_NAMES=() IKEV2_USER_PASSWORDS=()

users_add() {
    local name="$1" password="$2" existing
    if [[ -z "$name" || -z "$password" || "$name$password" == *$'\n'* || "$name$password" == *$'\r'* ]]; then
        echo '错误: 用户名和密码不能为空或包含换行' >&2
        return 1
    fi
    for existing in "${IKEV2_USER_NAMES[@]}"; do
        if [[ "$existing" == "$name" ]]; then
            echo '错误: 用户名重复，请检查账号配置' >&2
            return 1
        fi
    done
    IKEV2_USER_NAMES+=("$name")
    IKEV2_USER_PASSWORDS+=("$password")
}

users_load() {
    local legacy_file="$1" key index name_key password_key line number=0
    local -a indices=()
    IKEV2_USER_NAMES=()
    IKEV2_USER_PASSWORDS=()
    while IFS= read -r key; do
        if [[ "$key" =~ ^USER_([1-9][0-9]{0,2})_(NAME|PASSWORD)$ ]]; then
            indices+=("${BASH_REMATCH[1]}")
        fi
    done < <(compgen -A variable USER_ || true)
    if (( ${#indices[@]} > 0 )); then
        while IFS= read -r index; do
            name_key="USER_${index}_NAME"
            password_key="USER_${index}_PASSWORD"
            if [[ ! -v "$name_key" || ! -v "$password_key" ]]; then
                echo "错误: USER_$index 必须同时填写 NAME 和 PASSWORD" >&2
                return 1
            fi
            users_add "${!name_key}" "${!password_key}" || return 1
        done < <(printf '%s\n' "${indices[@]}" | sort -nu)
        echo "账号来源: .env (数量: ${#IKEV2_USER_NAMES[@]})" >&2
    elif [[ -f "$legacy_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            number=$((number + 1))
            line="${line%$'\r'}"
            [[ -z "$line" || "$line" == \#* ]] && continue
            if [[ "$line" != *:* ]]; then
                echo "错误: 旧账号文件第 $number 行必须使用 用户名:密码 格式" >&2
                return 1
            fi
            users_add "${line%%:*}" "${line#*:}" || return 1
        done < "$legacy_file"
        echo "账号来源: 旧 users.txt (数量: ${#IKEV2_USER_NAMES[@]})；可迁移到 .env 的 USER_*" >&2
    fi
    if (( ${#IKEV2_USER_NAMES[@]} == 0 )); then
        echo '错误: 请在 .env 填写至少一组 USER_1_NAME 和 USER_1_PASSWORD' >&2
        return 1
    fi
}

escape_swanctl_secret() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

generate_eap_secrets() {
    local i
    printf '\nsecrets {\n'
    for ((i=0; i<${#IKEV2_USER_NAMES[@]}; i++)); do
        printf '    eap-user-%d {\n        id = "%s"\n        secret = "%s"\n    }\n' \
            "$((i + 1))" "$(escape_swanctl_secret "${IKEV2_USER_NAMES[i]}")" \
            "$(escape_swanctl_secret "${IKEV2_USER_PASSWORDS[i]}")"
    done
    printf '}\n'
}
