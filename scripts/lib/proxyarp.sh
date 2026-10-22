#!/bin/bash
# Proxy ARP configuration and optional next-hop routing. No side effects on source.
source "$(dirname "${BASH_SOURCE[0]}")/ipv4.sh"
# Reserve this table/protocol pair for this module; never flush host routing tables.
PROXYARP_ROUTE_TABLE=20162
PROXYARP_ROUTE_PROTOCOL=186
PROXYARP_RULE_PRIORITY=219

proxyarp_error() {
    echo "错误: Proxy ARP: $*" >&2
    return 1
}

proxyarp_configure_farp() {
    local mode="$1" enabled=no
    if [[ "$mode" == proxyarp ]]; then
        [[ -f /usr/lib/ipsec/plugins/libstrongswan-farp.so ]] || \
            { proxyarp_error '缺少 farp 插件，请重新构建镜像'; return 1; }
        enabled=yes
    fi
    # Included by the existing strongswan.conf after the packaged plugin defaults.
    # Documentation uses dotted option paths, but the file parser requires
    # nested sections (notably the Debian 12 strongSwan 5.9.8 parser).
    cat > /etc/strongswan.d/ikev2-farp.conf <<EOF
charon {
    plugins {
        farp {
            load = $enabled
        }
    }
}
EOF
}

proxyarp_gateway_cleanup() {
    # Both selectors are required: leave unrelated rules and routes untouched.
    ip -4 rule flush table "$PROXYARP_ROUTE_TABLE" protocol "$PROXYARP_ROUTE_PROTOCOL" || return 1
    # An unused table does not exist yet; ip route flush would fail on first boot.
    if [[ -n "$(ip -4 route show table "$PROXYARP_ROUTE_TABLE" proto "$PROXYARP_ROUTE_PROTOCOL" 2>/dev/null)" ]]; then
        ip -4 route flush table "$PROXYARP_ROUTE_TABLE" proto "$PROXYARP_ROUTE_PROTOCOL"
    fi
}

proxyarp_gateway_apply() {
    local pool="$1" lan="$2" gateway="$3"
    local bounds first last lan_first lan_last gateway_number route iface prefix existing local_ip local_number
    [[ -n "$gateway" ]] || return 0

    bounds="$(ipv4_pool_bounds "$pool")" || \
        { proxyarp_error "无效或未对齐的地址池: $pool"; return 1; }
    read -r first last <<< "$bounds"
    [[ "$lan" == */* ]] && bounds="$(ipv4_pool_bounds "$lan")" || \
        { proxyarp_error "LAN 必须是对齐的 IPv4 CIDR: $lan"; return 1; }
    read -r lan_first lan_last <<< "$bounds"
    (( first > lan_first && last < lan_last )) || \
        { proxyarp_error '地址池必须完全位于 LAN 内，且不能包含 LAN 网络地址或广播地址'; return 1; }
    gateway_number="$(ipv4_number "$gateway")" || \
        { proxyarp_error "无效网关: $gateway"; return 1; }
    (( gateway_number > lan_first && gateway_number < lan_last &&
        (gateway_number < first || gateway_number > last) )) || \
        { proxyarp_error '网关必须是同 LAN 的可用地址，且不能位于 VPN 地址池内'; return 1; }

    while IFS= read -r local_ip; do
        local_number="$(ipv4_number "$local_ip")" || return 1
        (( local_number < first || local_number > last )) || \
            { proxyarp_error "地址池包含宿主机地址 $local_ip"; return 1; }
    done < <(ip -o -4 addr show | awk '{split($4, address, "/"); print address[1]}')

    route="$(ip -4 route get "$gateway")" || return 1
    # A directly attached unicast next hop is required. Do not force onlink.
    [[ " $route " != *' via '* && " $route " != *' local '* && " $route " != *' broadcast '* ]] || \
        { proxyarp_error '网关必须直接连接，且不能是宿主机自身地址'; return 1; }
    iface="$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<< "$route")"
    [[ -n "$iface" && "$iface" != lo ]] || \
        { proxyarp_error '无法识别网关所在 LAN 网卡'; return 1; }

    existing="$(ip -4 rule show)" || return 1
    if awk -v priority="$PROXYARP_RULE_PRIORITY:" '$1 == priority {found=1} END {exit !found}' <<< "$existing"; then
        proxyarp_error "规则优先级 $PROXYARP_RULE_PRIORITY 已被占用"
        return 1
    fi
    existing="$(ip -4 rule show table "$PROXYARP_ROUTE_TABLE")" || return 1
    [[ -z "$existing" ]] || { proxyarp_error '专用路由表已被其他规则引用'; return 1; }
    existing="$(ip -4 route show table "$PROXYARP_ROUTE_TABLE" 2>/dev/null || true)"
    [[ -z "$existing" ]] || { proxyarp_error '专用路由表已被其他路由占用'; return 1; }

    # Same-interface forwarding must not teach clients to bypass the VPN gateway.
    sysctl -w net.ipv4.conf.all.send_redirects=0 || return 1
    # Slash notation also supports interface names containing dots (e.g. VLANs).
    sysctl -w "net/ipv4/conf/$iface/send_redirects=0" || return 1

    ip -4 route add table "$PROXYARP_ROUTE_TABLE" "$lan" dev "$iface" scope link proto "$PROXYARP_ROUTE_PROTOCOL" || return 1
    ip -4 route add table "$PROXYARP_ROUTE_TABLE" default via "$gateway" dev "$iface" proto "$PROXYARP_ROUTE_PROTOCOL" || return 1
    # Priority 219 precedes strongSwan's default rule at 220, but local delivery
    # remains first. Source matching leaves host traffic and outer IKE untouched.
    while IFS= read -r prefix; do
        ip -4 rule add priority "$PROXYARP_RULE_PRIORITY" from "$prefix" \
            table "$PROXYARP_ROUTE_TABLE" protocol "$PROXYARP_ROUTE_PROTOCOL" || return 1
    done < <(ipv4_pool_prefixes "$pool")
    echo "Proxy ARP 网关: $gateway (LAN 网卡: $iface, 路由表: $PROXYARP_ROUTE_TABLE)"
}
