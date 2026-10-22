#!/bin/bash
# Account storage: name:password -> name:{NT}NT_HASH, with atomic write-back.
# Contract: users_validate FILE; users_load FILE NAMES_ARRAY HASHES_ARRAY.

users_hash_password() (
    set -o pipefail
    printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE |
        openssl dgst -md4 -provider legacy -provider default -binary |
        od -An -v -tx1 | tr -d ' \n'
)

users_read() {
    local -n _names="$3" _hashes="$4" _lines="$5" _changed="$6"
    local file="$1" convert="$2" line name value hash existing number=0
    _names=()
    _hashes=()
    _lines=()
    _changed=0
    [[ -f "$file" && -r "$file" && ! -L "$file" ]] || {
        echo '错误: 找不到可读取的账号文件 config/users.txt（不支持符号链接）' >&2; return 1;
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        number=$((number + 1))
        line="${line%$'\r'}"
        if (( number == 1 )); then line="${line#$'\xef\xbb\xbf'}"; fi
        if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then
            _lines+=("$line")
            continue
        fi
        name="${line%%:*}"
        value="${line#*:}"
        if [[ ! "$name" =~ ^[a-zA-Z0-9_.@-]+$ || "$line" != *:* || -z "$value" ]]; then
            echo "错误: 账号文件第 $number 行格式无效，请使用 用户名:密码" >&2
            return 1
        fi
        for existing in "${_names[@]}"; do
            [[ "$existing" != "$name" ]] || {
                echo "错误: 账号文件第 $number 行用户名重复" >&2; return 1;
            }
        done
        if [[ "$value" == '{NT}'* ]]; then
            hash="${value:4}"
            [[ "$hash" =~ ^[0-9A-Fa-f]{32}$ ]] || {
                echo "错误: 账号文件第 $number 行的 {NT} 哈希损坏，请将冒号后的内容替换为新密码" >&2; return 1;
            }
            hash="${hash,,}"
        else
            [[ "$value" != *$'\r'* ]] || { echo "错误: 账号文件第 $number 行密码包含回车" >&2; return 1; }
            hash=''
            if [[ "$convert" == yes ]]; then
                hash="$(users_hash_password "$value")" || {
                    echo "错误: 账号文件第 $number 行密码哈希失败，原文件未替换" >&2; return 1;
                }
                [[ "$hash" =~ ^[0-9a-f]{32}$ ]] || { echo '错误: NT 哈希生成结果无效' >&2; return 1; }
            fi
            _changed=1
        fi
        _names+=("$name")
        _hashes+=("$hash")
        _lines+=("$name:{NT}$hash")
    done < "$file"
    (( ${#_names[@]} > 0 )) || {
        echo '错误: 请在 config/users.txt 填写至少一个账号，例如 user1:你的密码' >&2; return 1;
    }
}

users_validate() {
    local -a validated_names=() validated_hashes=() validated_lines=()
    local validated_changed=0
    users_read "$1" no validated_names validated_hashes validated_lines validated_changed
}

users_load_locked() {
    local file="$1" before after temporary changed=0
    local -n loaded_names="$2"
    local -a normalized=()
    before="$(sha256sum -- "$file")" || return 1
    users_read "$file" yes "$2" "$3" normalized changed || return 1
    chmod 600 "$file" || return 1
    if (( changed )); then
        temporary="$(mktemp "${file}.tmp.XXXXXX")" || return 1
        if ! chmod 600 "$temporary" || ! printf '%s\n' "${normalized[@]}" > "$temporary"; then
            rm -f -- "$temporary"
            return 1
        fi
        after="$(sha256sum -- "$file")" || { rm -f -- "$temporary"; return 1; }
        if [[ "$before" != "$after" ]]; then
            rm -f -- "$temporary"
            echo '错误: 账号文件在加载期间被编辑，未覆盖修改，请重新启动' >&2
            return 1
        fi
        if ! mv -- "$temporary" "$file"; then
            rm -f -- "$temporary"
            echo '错误: 无法写回账号哈希，请检查 config 目录可写挂载及权限' >&2
            return 1
        fi
        echo '账号明文密码已转换为 NT 哈希并写回原文件（未生成明文备份）' >&2
    fi
    echo "已加载账号数量: ${#loaded_names[@]}" >&2
}

users_load() {
    local file="$1" lock_fd status=0 old_umask
    old_umask="$(umask)"
    umask 077
    if ! exec {lock_fd}> "${file}.lock"; then
        umask "$old_umask"
        echo '错误: 账号目录不可写，无法锁定并更新账号文件' >&2
        return 1
    fi
    umask "$old_umask"
    if flock -x -w 10 "$lock_fd"; then
        users_load_locked "$file" "$2" "$3" || status=$?
    else
        echo '错误: 账号文件正在使用，请稍后重启' >&2
        status=1
    fi
    exec {lock_fd}>&-
    return "$status"
}

escape_swanctl_secret() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

generate_eap_secrets() {
    local -n account_names="$1" account_hashes="$2"
    local i
    printf '\nsecrets {\n'
    for ((i=0; i<${#account_names[@]}; i++)); do
        [[ "${account_hashes[i]}" =~ ^[0-9a-f]{32}$ ]] || return 1
        printf '    ntlm-user-%d {\n        id = "%s"\n        secret = 0x%s\n    }\n' \
            "$((i + 1))" "$(escape_swanctl_secret "${account_names[i]}")" "${account_hashes[i]}"
    done
    printf '}\n'
}
