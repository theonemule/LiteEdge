#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh

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
  /opt/liteedge/bin/render-nginx.sh >/dev/null 2>&1 || true
}

apply_state() {
  if ! /opt/liteedge/bin/render-nginx.sh; then
    conflict_backup="$(mktemp -d)"
    cp -a "$NGINX_CONFLICT_DIR/." "$conflict_backup/" 2>/dev/null || true
    rollback_state
    cp -a "$conflict_backup/." "$NGINX_CONFLICT_DIR/" 2>/dev/null || true
    rm -rf "$conflict_backup" "$STATE_BACKUP"
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

validate_known_site() {
  validate_host "$1"
  [[ -f "$(site_file "$1")" ]] || die "Unknown site."
}

save_effective_config() {
  local host="$1" source="$2" current backup
  validate_known_site "$host"
  [[ -s "$source" ]] || die "NGINX configuration cannot be empty."
  current="$(site_nginx_file "$host")"
  [[ -f "$current" ]] || die "No generated NGINX configuration exists for this site."

  backup="$(mktemp)"
  cp "$current" "$backup"
  cp "$source" "$current"

  if ! "$NGINX_BIN" -t -c "$NGINX_CONF"; then
    cp "$backup" "$current"
    rm -f "$backup"
    die "NGINX rejected the manual configuration. The previous site configuration was restored."
  fi

  if ! reload_nginx; then
    cp "$backup" "$current"
    reload_nginx >/dev/null 2>&1 || true
    rm -f "$backup"
    die "NGINX reload failed. The previous site configuration was restored."
  fi

  rm -f "$backup" "$(site_nginx_conflict "$host")"
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
    [[ -n "$root" ]] || root="$DATA_DIR/www/$slug"

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
    rm -f "$(site_file "$host")" "$(waf_rule_file "$host")"
    rm -rf "$(route_dir "$host")"
    rm -f "$(site_nginx_conflict "$host")"
    apply_state
    ;;

  route-add)
    host="${1:-}"
    match="${2:-prefix}"
    path="${3:-/}"
    target="${4:-}"
    websocket="$(bool_value "${5:-0}")"

    validate_known_site "$host"
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
    validate_known_site "$host"
    [[ "$id" =~ ^[a-f0-9]{16}$ ]] || die "Invalid route id."
    snapshot_state
    rm -f "$(route_dir "$host")/$id.route"
    apply_state
    ;;

  waf-disable)
    host="${1:-}"
    rule_id="${2:-}"
    validate_known_site "$host"
    validate_rule_id "$rule_id"
    snapshot_state
    file="$(waf_rule_file "$host")"
    {
      disabled_waf_rules "$host"
      printf '%s\n' "$rule_id"
    } | sort -n -u > "$file.tmp"
    mv "$file.tmp" "$file"
    apply_state
    ;;

  waf-enable)
    host="${1:-}"
    rule_id="${2:-}"
    validate_known_site "$host"
    validate_rule_id "$rule_id"
    snapshot_state
    file="$(waf_rule_file "$host")"
    if [[ -f "$file" ]]; then
      grep -v -x "$rule_id" "$file" > "$file.tmp" || true
      if [[ -s "$file.tmp" ]]; then
        mv "$file.tmp" "$file"
      else
        rm -f "$file.tmp" "$file"
      fi
    fi
    apply_state
    ;;

  config-save)
    host="${1:-}"
    source="${2:-}"
    [[ -f "$source" ]] || die "A configuration file is required."
    save_effective_config "$host" "$source"
    ;;

  config-reset)
    host="${1:-}"
    validate_known_site "$host"
    baseline="$(site_nginx_baseline "$host")"
    [[ -s "$baseline" ]] || die "No generated baseline exists for this site."
    tmp="$(mktemp)"
    cp "$baseline" "$tmp"
    save_effective_config "$host" "$tmp"
    rm -f "$tmp"
    ;;

  config-diff)
    host="${1:-}"
    validate_known_site "$host"
    baseline="$(site_nginx_baseline "$host")"
    current="$(site_nginx_file "$host")"
    [[ -s "$baseline" && -s "$current" ]] || exit 0
    diff -u --label "generated baseline" --label "effective config" "$baseline" "$current" || true
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
  sitectl.sh waf-disable HOST RULE_ID
  sitectl.sh waf-enable HOST RULE_ID
  sitectl.sh config-save HOST FILE
  sitectl.sh config-reset HOST
  sitectl.sh config-diff HOST
  sitectl.sh list
USAGE
    exit 2
    ;;
esac
