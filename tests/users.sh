#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../scripts/lib/users.sh"
declare -a IKEV2_USER_NAMES=() IKEV2_USER_HASHES=()
load_users() { users_load "$1" IKEV2_USER_NAMES IKEV2_USER_HASHES; }
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Published NT hash / RFC 2759 test vectors, not hashes computed by this test.
[[ "$(users_hash_password password)" == 8846f7eaee8fb117ad06bdd830b7586c ]] || fail 'NT password vector'
[[ "$(users_hash_password clientPass)" == 44ebba8d5312b8d611474411f56989ae ]] || fail 'RFC 2759 vector'
cat > "$test_dir/users.txt" <<'EOF'
# Keep comments and mixed plaintext/hash entries.
alice:password
bob:{NT}44ebba8d5312b8d611474411f56989ae
special:p:a # $() `literal` "'\ 密码
EOF
before="$(sha256sum "$test_dir/users.txt")"
users_validate "$test_dir/users.txt"
[[ "$(sha256sum "$test_dir/users.txt")" == "$before" ]] || fail 'validation wrote passwords'
load_users "$test_dir/users.txt"
[[ ${#IKEV2_USER_NAMES[@]} == 3 && "${IKEV2_USER_HASHES[0]}" == 8846f7eaee8fb117ad06bdd830b7586c ]] || fail 'accounts/hash'
grep -Fxq 'alice:{NT}8846f7eaee8fb117ad06bdd830b7586c' "$test_dir/users.txt" || fail 'did not write back'
grep -q '^# Keep comments' "$test_dir/users.txt" || fail comments
if grep -Ev '^[[:space:]]*(#.*)?$' "$test_dir/users.txt" | grep -Ev '^[a-zA-Z0-9_.@-]+:\{NT\}[0-9a-f]{32}$' >/dev/null; then
    fail 'plaintext persisted'
fi
[[ "$(stat -c %a "$test_dir/users.txt")" == 600 ]] || fail permissions
[[ "$(stat -c %a "$test_dir/users.txt.lock")" == 600 ]] || fail 'lock permissions'
inode="$(stat -c %i "$test_dir/users.txt")"
before="$(sha256sum "$test_dir/users.txt")"
load_users "$test_dir/users.txt"
[[ "$(sha256sum "$test_dir/users.txt")" == "$before" && "$(stat -c %i "$test_dir/users.txt")" == "$inode" ]] || fail 'rehashed stored NT hash'
generate_eap_secrets IKEV2_USER_NAMES IKEV2_USER_HASHES > "$test_dir/secrets.conf"
grep -q 'ntlm-user-1' "$test_dir/secrets.conf" || fail 'wrong credential type'
grep -q 'secret = 0x8846f7eaee8fb117ad06bdd830b7586c' "$test_dir/secrets.conf" || fail 'wrong binary hash'
if grep -q 'password\|p:a' "$test_dir/secrets.conf"; then fail 'generated plaintext credential'; fi

# Updating one account does not change other hashes.
sed -i 's/^alice:.*/alice:clientPass/' "$test_dir/users.txt"
load_users "$test_dir/users.txt"
[[ "${IKEV2_USER_HASHES[0]}" == 44ebba8d5312b8d611474411f56989ae && "${IKEV2_USER_HASHES[1]}" == 44ebba8d5312b8d611474411f56989ae ]] || fail reset
# Windows editors may save BOM/CRLF; validate normalization and a missing final LF.
printf '\xef\xbb\xbfalice:password\r\nbob:{NT}44EBBA8D5312B8D611474411F56989AE' > "$test_dir/windows"
load_users "$test_dir/windows"
[[ "${IKEV2_USER_NAMES[0]}" == alice && "${IKEV2_USER_HASHES[1]}" == 44ebba8d5312b8d611474411f56989ae ]] || fail 'BOM/CRLF or uppercase hash'
grep -Fxq 'alice:{NT}8846f7eaee8fb117ad06bdd830b7586c' "$test_dir/windows" || fail 'Windows file normalization'
for invalid in 'alice:' 'missing-separator' 'alice:{NT}1234' 'alice:valid
alice:duplicate' 'with space:password'; do
    printf '%s\n' "$invalid" > "$test_dir/invalid"
    before="$(sha256sum "$test_dir/invalid")"
    if load_users "$test_dir/invalid"; then fail 'accepted invalid account file'; fi
    [[ "$(sha256sum "$test_dir/invalid")" == "$before" ]] || fail 'partially overwrote invalid file'
done
# A bad later row must not cause a partially hashed file to be written.
printf 'alice:password\nbob:{NT}broken\n' > "$test_dir/invalid-later"
before="$(sha256sum "$test_dir/invalid-later")"
if load_users "$test_dir/invalid-later"; then fail 'accepted bad later row'; fi
[[ "$(sha256sum "$test_dir/invalid-later")" == "$before" ]] || fail 'partially wrote earlier row'
printf 'alice:password\n' > "$test_dir/hash-failure"
before="$(sha256sum "$test_dir/hash-failure")"
if (users_hash_password() { return 1; }; load_users "$test_dir/hash-failure"); then fail 'ignored hashing failure'; fi
[[ "$(sha256sum "$test_dir/hash-failure")" == "$before" ]] || fail 'hash failure changed file'

# Refuse to overwrite edits made after reading the original account file.
printf 'alice:password\n' > "$test_dir/race"
if (
    users_hash_password() {
        printf '\n# external edit\n' >> "$test_dir/race"
        printf '%s' 8846f7eaee8fb117ad06bdd830b7586c
    }
    load_users "$test_dir/race"
); then fail 'overwrote concurrent edit'; fi
grep -q ':password' "$test_dir/race" || fail 'concurrent edit file replaced'
grep -q '# external edit' "$test_dir/race" || fail 'concurrent edit lost'
if compgen -G "$test_dir/*.tmp.*" >/dev/null; then fail 'temporary files left behind'; fi
echo 'PASS: NT vectors, atomic write-back, restart, reset, validation, hash failure and concurrent edits'
