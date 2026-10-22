#!/bin/bash
# Contract: read an input settings map and publish a validated, normalized map.
# Pure configuration validation; no host network or file mutations.
source "$(dirname "${BASH_SOURCE[0]}")/ipv4.sh"

network_config_resolve() {
    local -n raw="$1" result="$2"
    local -A resolved=()
    local mode pool first bounds pool_first pool_last lan_first lan_last gateway ip item
    local -a dns_items route_items
    mode="${raw[VPN_MODE]:-nat}"
    case "$mode" in
        nat) pool="${raw[NAT_POOL]:-10.66.0.0/24}" ;;
        proxyarp) pool="${raw[PROXYARP_POOL]:-192.168.0.201-192.168.0.210}" ;;
        *) echo '错误: VPN_MODE 只能是 nat 或 proxyarp' >&2; return 1 ;;
    esac
    bounds="$(ipv4_pool_bounds "$pool")" || { echo '错误: 客户端地址池必须为对齐的 IPv4 CIDR 或连续 IP 范围' >&2; return 1; }
    read -r pool_first pool_last <<< "$bounds"
    resolved[mode]="$mode"
    resolved[pool]="$pool"
    resolved[lan]=''
    resolved[gateway]=''
    if [[ "$mode" == nat ]]; then
        resolved[dns]="${raw[VPN_DNS]:-1.1.1.1,8.8.8.8}"
        resolved[routes]="${raw[VPN_ROUTES]:-0.0.0.0/0}"
    else
        first="$(ipv4_text "$pool_first")"
        resolved[lan]="${raw[PROXYARP_LAN]:-${first%.*}.0/24}"
        [[ "${resolved[lan]}" == */* ]] && bounds="$(ipv4_pool_bounds "${resolved[lan]}")" || {
            echo '错误: PROXYARP_LAN 必须为对齐的 IPv4 CIDR' >&2; return 1;
        }
        read -r lan_first lan_last <<< "$bounds"
        (( pool_first > lan_first && pool_last < lan_last )) || {
            echo '错误: 地址池必须在 LAN 内，且不能包含 LAN 网络地址和广播地址' >&2; return 1;
        }
        gateway="${raw[PROXYARP_GATEWAY]:-}"
        if [[ -n "$gateway" ]]; then
            ip="$(ipv4_number "$gateway")" || { echo '错误: 网关必须为 IPv4 地址' >&2; return 1; }
            (( ip > lan_first && ip < lan_last && (ip < pool_first || ip > pool_last) )) || {
                echo '错误: 网关必须在 LAN 内且在客户端地址池外' >&2; return 1;
            }
        fi
        resolved[gateway]="$gateway"
        resolved[dns]="${raw[VPN_DNS]:-${first%.*}.1,1.1.1.1}"
        resolved[routes]="${raw[VPN_ROUTES]:-${resolved[lan]}}"
    fi
    [[ "${resolved[dns]}${resolved[routes]}" != *[[:space:]]* &&
       "${resolved[dns]}" != ,* && "${resolved[dns]}" != *, && "${resolved[dns]}" != *,,* &&
       "${resolved[routes]}" != ,* && "${resolved[routes]}" != *, && "${resolved[routes]}" != *,,* ]] || {
        echo '错误: DNS 和路由列表不能包含空格、换行或空项' >&2; return 1;
    }
    IFS=, read -r -a dns_items <<< "${resolved[dns]}"
    IFS=, read -r -a route_items <<< "${resolved[routes]}"
    for item in "${dns_items[@]}"; do
        ipv4_number "$item" >/dev/null || { echo '错误: VPN_DNS 只能包含 IPv4 地址' >&2; return 1; }
    done
    for item in "${route_items[@]}"; do
        [[ "$item" == */* ]] && ipv4_pool_bounds "$item" >/dev/null || {
            echo '错误: VPN_ROUTES 必须为对齐的 IPv4 CIDR' >&2; return 1;
        }
    done
    # The domain is written into strongSwan syntax; only hostname/IP characters.
    resolved[domain]="${raw[VPN_DOMAIN]:-}"
    [[ "${resolved[domain]}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ &&
       "${resolved[domain]}" != *..* ]] || { echo '错误: VPN_DOMAIN 必须填写有效域名或 IPv4 地址' >&2; return 1; }
    resolved[cert_file]="${raw[VPN_CERT_FILE]:-server.crt}"
    resolved[key_file]="${raw[VPN_KEY_FILE]:-server.key}"
    for item in "${resolved[cert_file]}" "${resolved[key_file]}"; do
        [[ "$item" != . && "$item" != .. && "$item" != */* && "$item" != *\\* && "$item" != *$'\r'* && "$item" != *$'\n'* ]] || {
            echo '错误: 证书及私钥参数只能填写 ssl/ 内的文件名' >&2; return 1;
        }
    done
    result=()
    for item in "${!resolved[@]}"; do result[$item]="${resolved[$item]}"; done
}

# Read-only host checks, performed before credentials or host networking change.
network_host_validate() {
    local -n config="$1"
    local bounds first last addresses address value route
    bounds="$(ipv4_pool_bounds "${config[pool]}")" || return 1
    read -r first last <<< "$bounds"
    addresses="$(ip -o -4 addr show)" || return 1
    while IFS= read -r address; do
        [[ -n "$address" ]] || continue
        value="$(ipv4_number "$address")" || return 1
        (( value < first || value > last )) || { echo "错误: 地址池包含宿主机地址 $address" >&2; return 1; }
    done < <(awk '{split($4,a,"/"); print a[1]}' <<< "$addresses")
    if [[ -n "${config[gateway]}" ]]; then
        route="$(ip -4 route get "${config[gateway]}")" || return 1
        [[ " $route " != *' via '* && " $route " != *' local '* && " $route " != *' broadcast '* ]] || {
            echo '错误: 网关必须直接连接，且不能是宿主机自身' >&2; return 1;
        }
    fi
}

network_public_iface() {
    local route iface
    route="$(ip -4 route get 1.1.1.1)" || return 1
    iface="$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<< "$route")"
    [[ -n "$iface" && "$iface" != lo ]] || { echo '错误: 无法识别公网出口网卡' >&2; return 1; }
    printf '%s\n' "$iface"
}
