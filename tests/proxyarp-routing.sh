#!/bin/bash
# Run as root on Linux. All network changes are confined to a fresh namespace.
set -euo pipefail
if [[ "${1:-}" != --isolated ]]; then
    exec unshare --net bash "$0" --isolated
fi
source "$(dirname "$0")/../scripts/lib/proxyarp.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_route() {
    local expected="$1"; shift
    local actual
    actual="$(ip -4 route get "$@")"
    [[ "$actual" == *"$expected"* ]] || fail "expected '$expected' in '$actual'"
}
reject_gateway() {
    # A failing setup must also be safe when aborted partway through startup.
    if (set -e; proxyarp_gateway_apply "$@"); then
        fail "accepted invalid configuration: $*"
    fi
    proxyarp_gateway_cleanup
}

ip link set lo up
ip link add lan0 type dummy
ip link set lan0 up
ip addr add 192.168.0.2/24 dev lan0
ip link add wan0 type dummy
ip link set wan0 up
ip addr add 198.18.0.2/24 dev wan0
ip route add default via 198.18.0.1 dev wan0
sysctl -qw net.ipv4.ip_forward=1
# Model the routes charon owns. The feature must not change or bypass returns.
ip route add table 220 192.168.0.200/32 dev wan0
ip rule add priority 220 table 220
original_main="$(ip -4 route show table main)"
original_220="$(ip -4 route show table 220)"

proxyarp_gateway_cleanup
proxyarp_gateway_apply invalid invalid '' # Unconfigured feature has no side effects.
for pool in 192.168.0.200-192.168.0.210 192.168.0.200/29; do
    proxyarp_gateway_apply "$pool" 192.168.0.0/24 192.168.0.3
    expect_route 'via 192.168.0.3 dev lan0 table 20162' 1.1.1.1 from 192.168.0.200 iif wan0
    expect_route 'via 192.168.0.3 dev lan0 table 20162' 1.1.1.1 from 192.168.0.207 iif wan0
    if [[ "$pool" == *-* ]]; then
        expect_route 'via 192.168.0.3 dev lan0 table 20162' 1.1.1.1 from 192.168.0.208 iif wan0
        expect_route 'via 192.168.0.3 dev lan0 table 20162' 1.1.1.1 from 192.168.0.210 iif wan0
    else
        expect_route 'via 198.18.0.1 dev wan0' 1.1.1.1 from 192.168.0.208 iif lan0
    fi
    expect_route 'dev lan0 table 20162' 192.168.0.50 from 192.168.0.200 iif wan0
    expect_route 'local 192.168.0.2' 192.168.0.2 from 192.168.0.200 iif wan0
    expect_route 'via 198.18.0.1 dev wan0' 1.1.1.1 from 192.168.0.2
    expect_route 'via 198.18.0.1 dev wan0' 1.1.1.1 from 192.168.0.199 iif lan0
    expect_route 'via 198.18.0.1 dev wan0' 1.1.1.1 from 192.168.0.211 iif lan0
    expect_route 'dev wan0 table 220' 192.168.0.200 from 1.1.1.1 iif lan0
    [[ "$(sysctl -n net.ipv4.conf.lan0.send_redirects)" == 0 ]] || fail redirects
    proxyarp_gateway_cleanup
    proxyarp_gateway_cleanup # Idempotent stop/start and recovery from stale state.
    [[ -z "$(ip -4 rule show table 20162)" ]] || fail 'stale rules'
    expect_route 'via 198.18.0.1 dev wan0' 1.1.1.1 from 192.168.0.200 iif wan0
done

reject_gateway 192.168.0.200/29 192.168.0.0/24 192.168.0.200 # Pool overlap.
reject_gateway 192.168.0.200/29 192.168.0.0/24 192.168.0.2   # Host itself.
reject_gateway 192.168.0.200/29 192.168.0.0/24 192.168.1.3   # Outside LAN.
reject_gateway 192.168.0.240/28 192.168.0.0/24 192.168.0.3  # LAN broadcast.
reject_gateway 192.168.0.201/29 192.168.0.0/24 192.168.0.3  # Unaligned CIDR.
reject_gateway 192.168.0.210-192.168.0.200 192.168.0.0/24 192.168.0.3
reject_gateway 192.168.0.200/29 192.168.0.0/24 192.168.0.999
reject_gateway 192.168.0.0/24 192.168.0.0/24 192.168.0.3
reject_gateway 192.168.0.1-192.168.0.10 192.168.0.0/24 192.168.0.20 # Host in pool.
ip route add 192.168.0.3/32 via 192.168.0.1 dev lan0
reject_gateway 192.168.0.200/29 192.168.0.0/24 192.168.0.3 # Indirect gateway.
ip route del 192.168.0.3/32

# Refuse collisions; cleanup must retain resources with another protocol.
ip rule add priority 219 from 198.18.0.10 table main protocol 99
reject_gateway 192.168.0.200/29 192.168.0.0/24 192.168.0.3
[[ "$(ip -4 rule show priority 219)" == *198.18.0.10* ]] || fail 'deleted foreign rule'
ip rule del priority 219
ip rule add priority 300 from 198.18.0.10 table 20162 protocol 99
reject_gateway 192.168.0.200/29 192.168.0.0/24 192.168.0.3
[[ "$(ip -4 rule show table 20162)" == *198.18.0.10* ]] || fail 'deleted foreign table rule'
ip rule del priority 300
ip route add table 20162 203.0.113.0/24 dev wan0 proto 99
reject_gateway 192.168.0.200/29 192.168.0.0/24 192.168.0.3
[[ "$(ip -4 route show table 20162)" == *203.0.113.0/24* ]] || fail 'deleted foreign route'
ip route del table 20162 203.0.113.0/24

# Restart after an interrupted setup, then change gateway and disable feature.
proxyarp_gateway_apply 192.168.0.200/29 192.168.0.0/24 192.168.0.3
proxyarp_gateway_cleanup
proxyarp_gateway_apply 192.168.0.200/29 192.168.0.0/24 192.168.0.4
expect_route 'via 192.168.0.4' 1.1.1.1 from 192.168.0.200 iif wan0
proxyarp_gateway_cleanup
proxyarp_gateway_apply 192.168.0.200/29 192.168.0.0/24 ''
[[ -z "$(ip -4 rule show table 20162)" ]] || fail 'disabled feature still has rules'
[[ "$(ip -4 route show table main)" == "$original_main" ]] || fail 'changed host routes'
[[ "$(ip -4 route show table 220)" == "$original_220" ]] || fail 'changed charon routes'

# An error after routes are created must be recoverable by the EXIT handler.
if bash -e -c '
    source "$1"
    trap proxyarp_gateway_cleanup EXIT
    # Inject a rule-add failure while keeping real kernel route operations.
    ip() {
        if [[ "$*" == "-4 rule add "* ]]; then return 1; fi
        command ip "$@"
    }
    proxyarp_gateway_apply 192.168.0.200/29 192.168.0.0/24 192.168.0.3
' bash "$(dirname "$0")/../scripts/lib/proxyarp.sh"; then
    fail 'injected failure unexpectedly succeeded'
fi
[[ -z "$(ip -4 route show table 20162 2>/dev/null)" ]] || fail 'failed startup left routes'
[[ -z "$(ip -4 rule show table 20162)" ]] || fail 'failed startup left rules'

# VLAN-style interface names must work with sysctl's slash notation.
ip link set lan0 name lan0.10
proxyarp_gateway_apply 192.168.0.200/29 192.168.0.0/24 192.168.0.3
expect_route 'via 192.168.0.3 dev lan0.10' 1.1.1.1 from 192.168.0.200 iif wan0
proxyarp_gateway_cleanup
echo 'PASS: gateway routing, exact pool matching, return routes, validation, collision protection and cleanup'
