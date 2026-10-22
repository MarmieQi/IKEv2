#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../scripts/lib/certificates.sh"
source "$(dirname "$0")/../scripts/lib/daemon.sh"
test_dir="$(mktemp -d)"
pid=''
trap 'daemon_stop "$pid" 1; rm -rf -- "$test_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=vpn.example.com \
    -addext subjectAltName=DNS:vpn.example.com,IP:192.0.2.1 -addext extendedKeyUsage=serverAuth \
    -keyout "$test_dir/server.key" -out "$test_dir/server.crt" >/dev/null 2>&1
certificates_validate "$test_dir/server.crt" "$test_dir/server.key" vpn.example.com
certificates_validate "$test_dir/server.crt" "$test_dir/server.key" 192.0.2.1
if certificates_validate "$test_dir/server.crt" "$test_dir/server.key" wrong.example.com; then fail 'hostname mismatch accepted'; fi
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$test_dir/wrong.key" >/dev/null 2>&1
if certificates_validate "$test_dir/server.crt" "$test_dir/wrong.key" vpn.example.com; then fail 'key mismatch accepted'; fi
cat "$test_dir/server.crt" "$test_dir/server.crt" > "$test_dir/fullchain.crt"
certificates_prepare "$test_dir/fullchain.crt" "$test_dir/server.key" "$test_dir/output"
[[ -f "$test_dir/output/x509ca/chain-01.pem" ]] || fail 'chain splitting'
touch "$test_dir/output/x509ca/user-ca.pem"
certificates_prepare "$test_dir/server.crt" "$test_dir/server.key" "$test_dir/output"
[[ ! -f "$test_dir/output/x509ca/chain-01.pem" && -f "$test_dir/output/x509ca/user-ca.pem" ]] || fail 'stale/generated CA cleanup'
[[ "$(stat -c %a "$test_dir/output/private/privkey.pem")" == 600 ]] || fail 'private key permissions'

mkdir "$test_dir/bin"
cat > "$test_dir/bin/swanctl" <<EOF
#!/bin/bash
test -f "$test_dir/ready"
EOF
chmod +x "$test_dir/bin/swanctl"
export PATH="$test_dir/bin:$PATH"
sleep 30 & pid=$!
(sleep 1; touch "$test_dir/ready") &
daemon_wait_ready "$pid" 5
daemon_stop "$pid" 1
if daemon_wait_ready "$pid" 1; then fail 'dead child accepted'; fi
pid=''
rm "$test_dir/ready"
sleep 30 & pid=$!
if daemon_wait_ready "$pid" 1; then fail 'readiness timeout ignored'; fi
daemon_stop "$pid" 1
pid=''
echo 'PASS: certificate identity/key checks, chain cleanup and bounded readiness'
