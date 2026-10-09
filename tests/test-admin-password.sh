#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
export DATA_DIR="$sandbox/data" REMOTE_USER=admin
mkdir -p "$DATA_DIR/auth"
initial='InitialTestPassword#567'
replacement='ChangedTestPassword#890'
alt='AltTestPassword#123'
hash="$(printf '%s\n' "$initial" | openssl passwd -6 -stdin)"
alt_hash="$(printf '%s\n' "$alt" | openssl passwd -6 -stdin)"
printf 'admin:%s\nother:%s\n' "$hash" "$alt_hash" > "$DATA_DIR/auth/.htpasswd"
chmod 600 "$DATA_DIR/auth/.htpasswd"
token="$("$root/bin/authctl.sh" token)"
[[ "$token" =~ ^[a-f0-9]{64}$ ]] || { echo 'FAIL: CSRF creation'; exit 1; }
[[ "$("$root/bin/authctl.sh" token)" == "$token" ]] || { echo 'FAIL: CSRF persistence'; exit 1; }
test_change() {
  local csrf="$1" old="$2" next="$3"
  printf '%s\0%s\0%s\0' "$csrf" "$old" "$next" |
    "$root/bin/authctl.sh" change >/dev/null 2>&1
}
reject_change() {
  if test_change "$@"; then echo 'FAIL: invalid password change accepted'; exit 1; fi
}
reject_change bogus "$initial" "$replacement"
reject_change "$token" bad-current "$replacement"
reject_change "$token" "$initial" short
reject_change "$token" "$initial" "$initial"
reject_change "$token" "$initial" $'NewTestPassword\nBad'
[[ "$(cat "$DATA_DIR/auth/.htpasswd")" == "admin:$hash"$'\n'"other:$alt_hash" ]] ||
  { echo 'FAIL: rejected change modified credentials'; exit 1; }
test_change "$token" "$initial" "$replacement"
newhash="$(sed -n 's/^admin://p' "$DATA_DIR/auth/.htpasswd")"
[[ "$newhash" != "$hash" && "$newhash" == '$6$'* ]] || { echo 'FAIL: hash not updated'; exit 1; }
[[ "$(sed -n 's/^other://p' "$DATA_DIR/auth/.htpasswd")" == "$alt_hash" ]] ||
  { echo 'FAIL: changed another account'; exit 1; }
[[ "$(stat -c %a "$DATA_DIR/auth/.htpasswd")" == 600 ]] ||
  { echo 'FAIL: credential file permissions'; exit 1; }
reject_change "$token" "$initial" "$replacement"
test_change "$token" "$replacement" 'FurtherTestPassword#123'
export REMOTE_USER=other
test_change "$token" "$alt" 'OtherAccountPassword#567'
export REMOTE_USER=nonexistent
reject_change "$token" "$replacement" 'ValidTestPassword#123'
echo 'PASS: change, validation, CSRF, account isolation, atomic persisted hash, permissions, and reauthentication'
