#!/bin/bash
# Pure IPv4 parsing shared by validation, routing and firewall modules.
ipv4_number() {
    local ip="$1" a b c d octet
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    for octet in "$a" "$b" "$c" "$d"; do
        [[ ${#octet} -le 3 && ( "$octet" == 0 || "$octet" != 0* ) ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
    echo "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

ipv4_text() {
    local n="$1"
    printf '%d.%d.%d.%d' "$((n >> 24 & 255))" "$((n >> 16 & 255))" \
        "$((n >> 8 & 255))" "$((n & 255))"
}

# Output inclusive endpoints. CIDR addresses must be aligned to the prefix.
ipv4_pool_bounds() {
    local pool="$1" first last prefix mask
    if [[ "$pool" == */* ]]; then
        first="$(ipv4_number "${pool%/*}")" || return 1
        prefix="${pool##*/}"
        [[ "$prefix" =~ ^(0|[1-9]|[12][0-9]|3[0-2])$ ]] || return 1
        mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
        (( (first & mask) == first )) || return 1
        last=$(( first | (0xffffffff ^ mask) ))
    elif [[ "$pool" == *-* ]]; then
        first="$(ipv4_number "${pool%-*}")" || return 1
        last="$(ipv4_number "${pool#*-}")" || return 1
        (( first <= last )) || return 1
    else
        return 1
    fi
    echo "$first $last"
}

# Cover a range with the fewest exact CIDRs, without matching adjacent LAN hosts.
ipv4_pool_prefixes() {
    local bounds first last size prefix
    bounds="$(ipv4_pool_bounds "$1")" || return 1
    read -r first last <<< "$bounds"
    while (( first <= last )); do
        size=1
        prefix=32
        while (( prefix > 0 && first % (size * 2) == 0 && first + size * 2 - 1 <= last )); do
            size=$((size * 2))
            prefix=$((prefix - 1))
        done
        printf '%s/%d\n' "$(ipv4_text "$first")" "$prefix"
        first=$((first + size))
    done
}
