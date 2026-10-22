#!/bin/bash
set -euo pipefail
if [[ "${1:-}" != --isolated ]]; then exec unshare --net bash "$0" --isolated; fi
source "$(dirname "$0")/../scripts/lib/firewall.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ip link add eth0 type dummy
ip link set eth0 up
declare -A CONFIG=([mode]=nat [pool]=10.66.0.10-10.66.0.20 [lan]='')
iptables -A INPUT -s 203.0.113.1 -j ACCEPT
iptables -A INPUT -s 10.65.0.0/24 -j ACCEPT # Unmarked historical rule must not be deleted.
iptables -t nat -A POSTROUTING -s 10.99.0.0/24 -j MASQUERADE
original_filter="$(iptables -S)"
original_nat="$(iptables -t nat -S)"
firewall_apply CONFIG eth0
firewall_apply CONFIG eth0
iptables -C IKEV2_INPUT -p udp -m multiport --dports 500,4500 -j ACCEPT || fail 'IKE/NAT-T ports not allowed'
[[ "$(iptables -S INPUT | grep -c -- '-j IKEV2_INPUT')" == 1 ]] || fail 'duplicate hooks'
iptables -t nat -S IKEV2_POSTROUTING | grep -q -- '--src-range 10.66.0.10-10.66.0.20' || fail 'range matching'
iptables -S IKEV2_INPUT | grep -q -- '--pol ipsec' || fail 'unprotected source acceptance'
CONFIG[pool]=10.67.0.0/24
firewall_apply CONFIG eth0
if iptables -t nat -S IKEV2_POSTROUTING | grep -q 10.66; then fail 'old pool persisted'; fi
CONFIG[mode]=proxyarp
CONFIG[pool]=192.168.0.201-192.168.0.210
CONFIG[lan]=192.168.0.0/24
firewall_apply CONFIG eth0
if iptables -t nat -S IKEV2_POSTROUTING | grep -q MASQUERADE; then fail 'NAT persisted after mode switch'; fi
firewall_cleanup
firewall_cleanup
[[ "$(iptables -S)" == "$original_filter" && "$(iptables -t nat -S)" == "$original_nat" ]] || fail 'changed unrelated rules'

# A foreign chain with the reserved name must be left intact.
iptables -N IKEV2_INPUT
iptables -A IKEV2_INPUT -s 203.0.113.2 -j DROP
before="$(iptables -S)"
if firewall_apply CONFIG eth0; then fail 'accepted chain collision'; fi
[[ "$(iptables -S)" == "$before" ]] || fail 'changed foreign chain'
iptables -F IKEV2_INPUT
iptables -X IKEV2_INPUT

# Fail halfway through a real kernel ruleset, then verify complete rollback.
if (
    firewall_iptables() {
        if [[ "$*" == *'-I IKEV2_FORWARD 1'* ]]; then return 1; fi
        command iptables -w 5 "$@"
    }
    firewall_apply CONFIG eth0
); then fail 'injected failure succeeded'; fi
[[ "$(iptables -S)" == "$original_filter" && "$(iptables -t nat -S)" == "$original_nat" ]] || fail 'partial rules left behind'

# Do not empty a managed chain if an unrelated service references its contents.
firewall_apply CONFIG eth0
iptables -N ADMIN_CHAIN
iptables -A ADMIN_CHAIN -j IKEV2_INPUT
if firewall_cleanup; then fail 'ignored foreign reference'; fi
iptables -S IKEV2_INPUT | grep -q -- '--pol ipsec' || fail 'emptied referenced chain'
iptables -F ADMIN_CHAIN
iptables -X ADMIN_CHAIN
firewall_cleanup
[[ "$(iptables -S)" == "$original_filter" ]] || fail 'cleanup after foreign reference'
echo 'PASS: owned firewall chains, mode/pool changes, collisions and rollback'
