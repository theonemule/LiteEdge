#!/usr/bin/env bash
set -euo pipefail
umask 077

AUTH_DIR="${DATA_DIR:-/data}/auth"
AUTH_FILE="$AUTH_DIR/.htpasswd"
CSRF_FILE="$AUTH_DIR/.csrf-token"
LOCK_DIR="$AUTH_DIR/.password-change.lock"

die() { printf '%s\n' "$*" >&2; exit 1; }

csrf_token() {
  [[ -d "$AUTH_DIR" ]] || die "Authentication storage is unavailable."
  if [[ ! -s "$CSRF_FILE" ]]; then
    local temp
    temp="$(mktemp "$AUTH_DIR/.csrf.XXXXXX")" || die "Cannot prepare the security token."
    if ! openssl rand -hex 32 > "$temp"; then
      rm -f "$temp"
      die "Cannot create the security token."
    fi
    # Atomic creation means concurrent requests cannot replace a displayed token.
    ln "$temp" "$CSRF_FILE" 2>/dev/null || true
    rm -f "$temp"
  fi
  [[ -s "$CSRF_FILE" && -r "$CSRF_FILE" ]] || die "Security token is unavailable."
  cat "$CSRF_FILE"
}

change_password() {
  local token current new username stored_hash algorithm rest salt computed new_hash
  local line existing_user found=0 tmp
  IFS= read -r -d '' token || die "Invalid password change request."
  IFS= read -r -d '' current || die "Invalid password change request."
  IFS= read -r -d '' new || die "Invalid password change request."

  username="${REMOTE_USER:-}"
  [[ "$username" =~ ^[a-zA-Z0-9_.@-]{1,128}$ ]] || die "Authenticated administrator could not be identified."
  [[ -f "$AUTH_FILE" && -r "$AUTH_FILE" && -w "$AUTH_FILE" ]] || die "Authentication storage is unavailable."
  [[ -n "$token" && "$token" == "$(csrf_token)" ]] || die "Security token expired or invalid. Reload Server Settings and try again."
  [[ -n "$current" ]] || die "Enter your current password."
  (( ${#new} >= 12 && ${#new} <= 256 )) || die "New password must be 12 to 256 characters."
  [[ "$new" != *$'\r'* && "$new" != *$'\n'* && "$current" != *$'\r'* && "$current" != *$'\n'* ]] ||
    die "Passwords cannot contain line breaks."
  [[ "$new" != "$current" ]] || die "Choose a new password different from the current one."

  mkdir "$LOCK_DIR" 2>/dev/null || die "Another password change is in progress. Try again."
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

  stored_hash=""
  while IFS=: read -r existing_user line; do
    if [[ "$existing_user" == "$username" ]]; then
      stored_hash="$line"
      found=$((found + 1))
    fi
  done < "$AUTH_FILE"
  (( found == 1 )) || die "Authenticated administrator account was not found."

  case "$stored_hash" in
    '$6$'*) algorithm=-6; rest="${stored_hash#\$6\$}" ;;
    '$5$'*) algorithm=-5; rest="${stored_hash#\$5\$}" ;;
    '$apr1$'*) algorithm=-apr1; rest="${stored_hash#\$apr1\$}" ;;
    '$1$'*) algorithm=-1; rest="${stored_hash#\$1\$}" ;;
    *) die "Existing password hash format is unsupported." ;;
  esac
  salt="${rest%%\$*}"
  [[ "$salt" =~ ^[./A-Za-z0-9]{1,16}$ ]] || die "Existing password hash format is unsupported."
  computed="$(printf '%s\n' "$current" | openssl passwd "$algorithm" -salt "$salt" -stdin)" ||
    die "Unable to verify current password."
  [[ "$computed" == "$stored_hash" ]] || die "Current password is incorrect."

  new_hash="$(printf '%s\n' "$new" | openssl passwd -6 -stdin)" ||
    die "Unable to generate password hash."
  tmp="$(mktemp "$AUTH_DIR/.htpasswd.tmp.XXXXXX")" || die "Unable to update password."
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$username:"* ]]; then
      printf '%s:%s\n' "$username" "$new_hash"
    else
      printf '%s\n' "$line"
    fi
  done < "$AUTH_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$AUTH_FILE" || { rm -f "$tmp"; die "Unable to save password."; }
  printf 'Password updated.\n'
}

case "${1:-}" in
  token) csrf_token ;;
  change) change_password ;;
  *) die "Usage: authctl.sh token|change" ;;
esac
