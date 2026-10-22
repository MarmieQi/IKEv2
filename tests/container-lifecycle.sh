#!/bin/bash
# Run ONLY in a disposable privileged container/rootfs with its own network namespace.
# Exercises the real entrypoint, Debian strongSwan, kernel rules, restart and shutdown.
set -euo pipefail
[[ "${IKEV2_DISPOSABLE_TEST:-}" == yes ]] || { echo 'Disposable environment required' >&2; exit 1; }
pid=''
cleanup() {
    if [[ -n "$pid" ]]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
fail() { cat /tmp/ikev2-start.log >&2 2>/dev/null || true; echo "FAIL: $*" >&2; exit 1; }
mkdir -p /ssl /run/ikev2-config /etc/ikev2
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=vpn.example.com \
    -addext subjectAltName=DNS:vpn.example.com -addext extendedKeyUsage=serverAuth \
    -keyout /ssl/server.key -out /ssl/server.crt >/dev/null 2>&1
printf 'alice:password\nbob:clientPass\n' > /etc/ikev2/users.txt
ip link set lo up
ip link add wan0 type dummy
ip link set wan0 up
ip addr add 198.18.0.2/24 dev wan0
ip route add default via 198.18.0.1 dev wan0
ip link add lan0 type dummy
ip link set lan0 up
ip addr add 192.168.0.2/24 dev lan0
# Host rules must survive every restart and failed startup.
iptables -P INPUT DROP
iptables -A INPUT -s 203.0.113.1 -j ACCEPT
original_filter="$(iptables -S)"
original_nat="$(iptables -t nat -S)"
original_routes="$(ip -4 route show table main)"

write_config() {
    printf 'VPN_DOMAIN=vpn.example.com\nVPN_MODE=%s\nVPN_ROUTES=0.0.0.0/0\nPROXYARP_GATEWAY=%s\n' "$1" "$2" > /run/ikev2-config/.env
}
start_server() {
    bash /start.sh > /tmp/ikev2-start.log 2>&1 & pid=$!
    local attempt
    for attempt in {1..40}; do
        kill -0 "$pid" 2>/dev/null || fail 'entrypoint exited before readiness'
        if [[ -f /run/ikev2.ready ]]; then
            timeout 3 swanctl --stats >/dev/null || fail 'ready without VICI'
            swanctl --list-conns > /tmp/ikev2-conns
            grep -q 'ikev2-mschapv2' /tmp/ikev2-conns || fail 'connection not loaded'
            [[ "$(stat -c %a /etc/swanctl/swanctl.conf)" == 600 ]] || fail 'runtime credentials permissions'
            return 0
        fi
        sleep 1
    done
    fail 'entrypoint readiness timeout'
}
stop_server() {
    kill -TERM "$pid"
    local status=0
    wait "$pid" || status=$?
    pid=''
    [[ "$status" == 143 ]] || fail "unexpected shutdown status: $status"
    [[ ! -e /run/ikev2.ready ]] || fail 'stale readiness marker'
    if pgrep -x charon >/dev/null; then fail 'orphaned charon'; fi
    [[ "$(iptables -S)" == "$original_filter" ]] || fail 'filter cleanup or foreign rules changed'
    [[ "$(iptables -t nat -S)" == "$original_nat" ]] || fail 'NAT cleanup or foreign rules changed'
    [[ -z "$(ip -4 rule show table 20162)" ]] || fail 'stale policy rules'
    [[ -z "$(ip -4 route show table 20162 2>/dev/null)" ]] || fail 'stale gateway routes'
    [[ "$(ip -4 route show table main)" == "$original_routes" ]] || fail 'host routes changed'
}

write_config nat ''
start_server
timeout 3 swanctl --list-algs > /tmp/ikev2-algorithms
grep -q 'AES_GCM_16' /tmp/ikev2-algorithms || fail 'GCM algorithm unavailable'
grep -q 'ECP_256' /tmp/ikev2-algorithms || fail 'ECP256 algorithm unavailable'
ss -lun | grep -Eq ':500[[:space:]]' || fail 'IKE socket not listening'
ss -lun | grep -Eq ':4500[[:space:]]' || fail 'NAT-T socket not listening'
grep -Fxq 'alice:{NT}8846f7eaee8fb117ad06bdd830b7586c' /etc/ikev2/users.txt || fail 'password write-back'
iptables -C IKEV2_INPUT -p udp -m multiport --dports 500,4500 -j ACCEPT || fail 'IKE ports blocked'
iptables -t nat -S IKEV2_POSTROUTING | grep -q MASQUERADE || fail 'NAT missing'
stop_server

for gateway in 192.168.0.3 192.168.0.4 ''; do
    write_config proxyarp "$gateway"
    start_server
    grep -q 'load = yes' /etc/strongswan.d/ikev2-farp.conf || fail 'farp disabled'
    if iptables -t nat -S IKEV2_POSTROUTING | grep -q MASQUERADE; then fail 'NAT in Proxy ARP mode'; fi
    if [[ -n "$gateway" ]]; then
        ip -4 route show table 20162 | grep -q "default via $gateway" || fail 'gateway change ignored'
    else
        [[ -z "$(ip -4 rule show table 20162)" ]] || fail 'disabled gateway still active'
    fi
    stop_server
done

write_config nat ''
start_server
grep -q 'load = no' /etc/strongswan.d/ikev2-farp.conf || fail 'farp persisted after mode switch'
stop_server
printf 'VPN_DOMAIN=vpn.example.com\nVPN_MODE=invalid\n' > /run/ikev2-config/.env
if bash /start.sh > /tmp/ikev2-start.log 2>&1; then fail 'invalid configuration started'; fi
[[ ! -e /run/ikev2.ready && "$(iptables -S)" == "$original_filter" ]] || fail 'failed startup changed host rules'
echo 'PASS: real strongSwan startup, accounts, NAT/Proxy ARP, gateway reload, mode switch and shutdown'
