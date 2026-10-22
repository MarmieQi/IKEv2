#!/bin/bash
# Own only the three dedicated chains and explicitly tagged parent jumps.
# Contract: firewall_apply CONFIG_MAP PUBLIC_IFACE; firewall_cleanup needs no config.
FIREWALL_OWNER=ikev2-managed-v1

firewall_iptables() { iptables -w 5 "$@"; }

firewall_owned() {
    firewall_iptables -t "$1" -C "$2" -m comment --comment "$FIREWALL_OWNER" -j RETURN 2>/dev/null
}

firewall_check_chain() {
    local table="$1" chain="$2"
    if firewall_iptables -t "$table" -S "$chain" >/dev/null 2>&1 && ! firewall_owned "$table" "$chain"; then
        echo "错误: 防火墙链 $chain 已被其他服务占用，未修改" >&2
        return 1
    fi
}

firewall_cleanup_chain() {
    local table="$1" parent="$2" chain="$3"
    firewall_iptables -t "$table" -S "$chain" >/dev/null 2>&1 || return 0
    firewall_owned "$table" "$chain" || { echo "错误: 不清理无归属标记的链 $chain" >&2; return 1; }
    while firewall_iptables -t "$table" -C "$parent" -m comment --comment "$FIREWALL_OWNER" -j "$chain" 2>/dev/null; do
        firewall_iptables -t "$table" -D "$parent" -m comment --comment "$FIREWALL_OWNER" -j "$chain" || return 1
    done
    # Do not flush a chain that another service has started referencing.
    if firewall_iptables -t "$table" -S | grep -Eq -- "(-j|-g) $chain( |$)"; then
        echo "错误: $chain 被其他规则引用，未清空链内容" >&2
        return 1
    fi
    firewall_iptables -t "$table" -F "$chain" || return 1
    firewall_iptables -t "$table" -X "$chain"
}

firewall_cleanup() {
    local status=0
    firewall_cleanup_chain filter INPUT IKEV2_INPUT || status=1
    firewall_cleanup_chain filter FORWARD IKEV2_FORWARD || status=1
    firewall_cleanup_chain nat POSTROUTING IKEV2_POSTROUTING || status=1
    return "$status"
}

firewall_create_chain() {
    firewall_iptables -t "$1" -N "$2" || return 1
    # The marker is also the final RETURN; rules are inserted ahead of it.
    firewall_iptables -t "$1" -A "$2" -m comment --comment "$FIREWALL_OWNER" -j RETURN
}

firewall_build() {
    local -n config="$1"
    local iface="$2" pool="${config[pool]}"
    local -a src dst
    if [[ "$pool" == *-* ]]; then
        src=(-m iprange --src-range "$pool")
        dst=(-m iprange --dst-range "$pool")
    else
        src=(-s "$pool")
        dst=(-d "$pool")
    fi
    firewall_create_chain filter IKEV2_INPUT || return 1
    firewall_create_chain filter IKEV2_FORWARD || return 1
    firewall_create_chain nat IKEV2_POSTROUTING || return 1
    # IKE/NAT-T must work even when the host's INPUT policy is DROP.
    firewall_iptables -t filter -I IKEV2_INPUT 1 -p udp -m multiport --dports 500,4500 -j ACCEPT || return 1
    firewall_iptables -t filter -I IKEV2_INPUT 1 "${src[@]}" -m policy --dir in --pol ipsec -j ACCEPT || return 1
    firewall_iptables -t filter -I IKEV2_FORWARD 1 "${src[@]}" -m policy --dir in --pol ipsec -j ACCEPT || return 1
    firewall_iptables -t filter -I IKEV2_FORWARD 1 "${dst[@]}" -m conntrack --ctstate ESTABLISHED,RELATED \
        -m policy --dir out --pol ipsec -j ACCEPT || return 1
    if [[ "${config[mode]}" == nat ]]; then
        firewall_iptables -t nat -I IKEV2_POSTROUTING 1 "${src[@]}" -o "$iface" -j MASQUERADE || return 1
    else
        firewall_iptables -t filter -I IKEV2_FORWARD 1 -s "${config[lan]}" "${dst[@]}" \
            -m policy --dir out --pol ipsec -j ACCEPT || return 1
        # Preserve the VPN source even if the host has broader NAT rules later.
        firewall_iptables -t nat -I IKEV2_POSTROUTING 1 "${src[@]}" -j ACCEPT || return 1
    fi
    # ACCEPT in the nat chain exempts encrypted traffic from subsequent host NAT.
    firewall_iptables -t nat -I IKEV2_POSTROUTING 1 "${src[@]}" -m policy --dir out --pol ipsec -j ACCEPT || return 1
    firewall_iptables -t nat -I IKEV2_POSTROUTING 1 "${dst[@]}" -m policy --dir out --pol ipsec -j ACCEPT || return 1
    # Publish hooks only after all chains have been built successfully.
    firewall_iptables -t filter -I INPUT 1 -m comment --comment "$FIREWALL_OWNER" -j IKEV2_INPUT || return 1
    firewall_iptables -t filter -I FORWARD 1 -m comment --comment "$FIREWALL_OWNER" -j IKEV2_FORWARD || return 1
    firewall_iptables -t nat -I POSTROUTING 1 -m comment --comment "$FIREWALL_OWNER" -j IKEV2_POSTROUTING
}

firewall_preflight() {
    firewall_check_chain filter IKEV2_INPUT || return 1
    firewall_check_chain filter IKEV2_FORWARD || return 1
    firewall_check_chain nat IKEV2_POSTROUTING
}

firewall_apply() {
    local status
    firewall_preflight || return 1
    firewall_cleanup || return 1
    if firewall_build "$1" "$2"; then
        echo '已应用项目专属防火墙规则'
    else
        status=$?
        firewall_cleanup || echo '错误: 防火墙失败后的清理未完成，请检查日志' >&2
        return "$status"
    fi
}
