#!/bin/bash
# Resolve public settings and defaults once; consumers use normalized values.
config_pool_first_ip() {
    local pool="$1"
    pool="${pool%%/*}"
    printf '%s' "${pool%%-*}"
}

network_config_resolve() {
    local first auto_lan auto_dns
    VPN_MODE="${VPN_MODE:-nat}"
    case "$VPN_MODE" in
        nat)
            VPN_POOL="${NAT_POOL:-10.66.0.0/24}"
            VPN_LOCAL_TS="${VPN_ROUTES:-0.0.0.0/0}"
            VPN_DNS="${VPN_DNS:-1.1.1.1,8.8.8.8}"
            LAN_SUBNET=""
            ;;
        proxyarp)
            VPN_POOL="${PROXYARP_POOL:-192.168.0.201-192.168.0.210}"
            first="$(config_pool_first_ip "$VPN_POOL")"
            auto_lan="${first%.*}.0/24"
            auto_dns="${first%.*}.1"
            LAN_SUBNET="${PROXYARP_LAN:-$auto_lan}"
            VPN_LOCAL_TS="${VPN_ROUTES:-$LAN_SUBNET}"
            VPN_DNS="${VPN_DNS:-$auto_dns,1.1.1.1}"
            ;;
        *) echo '错误: VPN_MODE 只能是 nat 或 proxyarp' >&2; return 1 ;;
    esac
    # Reject malformed lists before they are written into strongSwan configuration.
    local item octet a b c d base prefix
    local -a dns_items route_items
    [[ "$VPN_DNS$VPN_LOCAL_TS" != *[[:space:]]* ]] || {
        echo '错误: DNS 和路由列表不能包含空格或换行' >&2; return 1;
    }
    [[ "$VPN_DNS" != ,* && "$VPN_DNS" != *, && "$VPN_DNS" != *,,* &&
       "$VPN_LOCAL_TS" != ,* && "$VPN_LOCAL_TS" != *, && "$VPN_LOCAL_TS" != *,,* ]] || {
        echo '错误: VPN_DNS / VPN_ROUTES 不能包含空列表项' >&2; return 1;
    }
    IFS=, read -r -a dns_items <<< "$VPN_DNS"
    IFS=, read -r -a route_items <<< "$VPN_LOCAL_TS"
    for item in "${dns_items[@]}" "${route_items[@]}"; do
        base="${item%/*}"
        [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
            echo '错误: DNS 或路由范围必须是 IPv4，多个值用逗号分隔且不加空格' >&2; return 1;
        }
        IFS=. read -r a b c d <<< "$base"
        for octet in "$a" "$b" "$c" "$d"; do
            [[ ${#octet} -le 3 && ( "$octet" == 0 || "$octet" != 0* ) ]] && ((10#$octet <= 255)) || {
                echo '错误: DNS 或路由范围包含无效 IPv4 地址' >&2; return 1;
            }
        done
    done
    for item in "${dns_items[@]}"; do
        [[ "$item" != */* ]] || { echo '错误: DNS 只能填写 IPv4 地址' >&2; return 1; }
    done
    for item in "${route_items[@]}"; do
        prefix="${item##*/}"
        [[ "$item" == */* && "$prefix" =~ ^(0|[1-9]|[12][0-9]|3[0-2])$ ]] || {
            echo '错误: 路由范围必须使用 IPv4 CIDR，如 0.0.0.0/0' >&2; return 1;
        }
    done
}
