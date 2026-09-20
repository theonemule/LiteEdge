#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /opt/lazycb/bin/common.sh

cmd="${1:-}"
shift || true
STATE_BACKUP=""

snapshot_state() {
  STATE_BACKUP="$(mktemp -d)"
  cp -a "$SITE_DIR/." "$STATE_BACKUP/" 2>/dev/null || true
}

rollback_state() {
  rm -rf "$SITE_DIR"
  mkdir -p "$SITE_DIR"
  cp -a "$STATE_BACKUP/." "$SITE_DIR/" 2>/dev/null || true
  /opt/lazycb/bin/render-nginx.sh >/dev/null 2>&1 || true
}

apply_state() {
  if ! /opt/lazycb/bin/render-nginx.sh; then
    rollback_state
    rm -rf "$STATE_BACKUP"
    die "Generated NGINX configuration was invalid. The change was rolled back."
  fi

  if ! reload_nginx; then
    rollback_state
    reload_nginx >/dev/null 2>&1 || true
    rm -rf "$STATE_BACKUP"
    die "NGINX reload failed. The change was rolled back."
  fi

  rm -rf "$STATE_BACKUP"
  STATE_BACKUP=""
}

case "$cmd" in
  save)
    host="${1:-}"
    mode="${2:-proxy}"
    upstream="${3:-}"
    root="${4:-}"
    aliases="${5:-}"
    force_https="$(bool_value "${6:-0}")"
    waf="$(bool_value "${7:-1}")"
    websocket="$(bool_value "${8:-0}")"

    validate_host "$host"
    validate_mode "$mode"
    validate_aliases "$aliases"

    slug="$(slug_for_host "$host")"
    [[ -n "$root" ]] || root="/data/www/$slug"

    if [[ "$mode" == static ]]; then
      validate_root "$root"
      mkdir -p "$root"
      chmod 755 "$root"
    else
      validate_upstream "$upstream"
    fi

    snapshot_state

    file="$(site_file "$host")"
    tmp="$(mktemp)"
    {
      printf 'HOST=%s\n' "$host"
      printf 'MODE=%s\n' "$mode"
      printf 'UPSTREAM=%s\n' "$upstream"
      printf 'ROOT=%s\n' "$root"
      printf 'ALIASES=%s\n' "${aliases//,/ }"
      printf 'FORCE_HTTPS=%s\n' "$force_https"
      printf 'WAF=%s\n' "$waf"
      printf 'WEBSOCKET=%s\n' "$websocket"
    } > "$tmp"
    mv "$tmp" "$file"
    mkdir -p "$(route_dir "$host")"

    apply_state
    ;;

  delete)
    host="${1:-}"
    validate_host "$host"

    snapshot_state
    rm -f "$(site_file "$host")"
    rm -rf "$(route_dir "$host")"
    apply_state
    ;;

  route-add)
    host="${1:-}"
    match="${2:-prefix}"
    path="${3:-/}"
    target="${4:-}"
    websocket="$(bool_value "${5:-0}")"

    validate_host "$host"
    [[ -f "$(site_file "$host")" ]] || die "Unknown site."
    validate_route_match "$match"
    validate_route_path "$path"
    validate_upstream "$target"

    snapshot_state

    dir="$(route_dir "$host")"
    mkdir -p "$dir"
    id="$(printf '%s\n%s\n%s' "$match" "$path" "$target" | sha256sum | cut -c1-16)"
    {
      printf 'ID=%s\n' "$id"
      printf 'MATCH=%s\n' "$match"
      printf 'PATH=%s\n' "$path"
      printf 'TARGET=%s\n' "$target"
      printf 'WEBSOCKET=%s\n' "$websocket"
    } > "$dir/$id.route"

    apply_state
    ;;

  route-delete)
    host="${1:-}"
    id="${2:-}"
    validate_host "$host"
    [[ "$id" =~ ^[a-f0-9]{16}$ ]] || die "Invalid route id."

    snapshot_state
    rm -f "$(route_dir "$host")/$id.route"
    apply_state
    ;;

  list)
    shopt -s nullglob
    for file in "$SITE_DIR"/*.site; do
      kv_get "$file" HOST
    done
    ;;

  *)
    cat >&2 <<USAGE
Usage:
  sitectl.sh save HOST MODE UPSTREAM ROOT ALIASES FORCE_HTTPS WAF WEBSOCKET
  sitectl.sh delete HOST
  sitectl.sh route-add HOST MATCH PATH TARGET WEBSOCKET
  sitectl.sh route-delete HOST ROUTE_ID
  sitectl.sh list
USAGE
    exit 2
    ;;
esac
