#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh

cmd="${1:-}"
shift || true

snapshot_waf() {
  WAF_BACKUP="$(mktemp -d)"
  cp -a "$WAF_DIR/." "$WAF_BACKUP/" 2>/dev/null || true
}

restore_waf() {
  rm -rf "$WAF_DIR"
  mkdir -p "$WAF_CUSTOM_DIR" "$WAF_PLUGIN_DIR"
  cp -a "$WAF_BACKUP/." "$WAF_DIR/" 2>/dev/null || true
  /opt/liteedge/bin/render-runtime.sh >/dev/null 2>&1 || true
  /opt/liteedge/bin/render-nginx.sh >/dev/null 2>&1 || true
  reload_nginx >/dev/null 2>&1 || true
}

apply_waf() {
  if ! /opt/liteedge/bin/render-runtime.sh || ! /opt/liteedge/bin/render-nginx.sh || ! "$NGINX_BIN" -t -c "$NGINX_CONF" || ! reload_nginx; then
    restore_waf
    rm -rf "$WAF_BACKUP"
    die "OWASP rule changes were rejected. Previous rules were restored."
  fi
  rm -rf "$WAF_BACKUP"
}

ensure_settings() {
  [[ -f "$WAF_SETTINGS_FILE" ]] || printf 'PARANOIA_LEVEL=1\n' > "$WAF_SETTINGS_FILE"
}

validate_pl() {
  [[ "${1:-}" =~ ^[1-4]$ ]] || die "Protection level must be PL1, PL2, PL3, or PL4."
}

validate_custom_rule() {
  local id="$1" file="$2"
  validate_rule_id "$id"
  [[ -s "$file" ]] || die "Custom rule cannot be empty."
  grep -Eq "id:[[:space:]]*['\"]?$id([^0-9]|$)" "$file" ||
    die "Custom rule text must contain id:$id."
}

custom_enabled_path() { printf '%s/%s.conf' "$WAF_CUSTOM_DIR" "$1"; }
custom_disabled_path() { printf '%s/%s.conf.disabled' "$WAF_CUSTOM_DIR" "$1"; }

safe_rule_archive() {
  local archive="$1" name line type
  [[ -s "$archive" ]] || die "Rules archive is empty."
  tar -tzf "$archive" >/dev/null 2>&1 || die "Rules archive is not a valid .tar.gz file."
  while IFS= read -r name; do
    [[ "$name" == liteedge-waf || "$name" == liteedge-waf/* ]] ||
      die "Rules archive contains an unexpected path."
    [[ "$name" != *"/../"* && "$name" != ../* && "$name" != *"/.." ]] ||
      die "Rules archive contains an unsafe path."
  done < <(tar -tzf "$archive")
  while IFS= read -r line; do
    type="${line:0:1}"
    case "$type" in -|d) ;; *) die "Rules archive contains an unsupported filesystem object." ;; esac
  done < <(tar -tvzf "$archive")
}

case "$cmd" in
  set-pl)
    pl="${1:-}"
    validate_pl "$pl"
    snapshot_waf
    printf 'PARANOIA_LEVEL=%s\n' "$pl" > "$WAF_SETTINGS_FILE"
    apply_waf
    ;;

  disable)
    id="${1:-}"
    validate_rule_id "$id"
    snapshot_waf
    {
      global_disabled_waf_rules
      printf '%s\n' "$id"
    } | sort -n -u > "$WAF_DISABLED_FILE.tmp"
    mv "$WAF_DISABLED_FILE.tmp" "$WAF_DISABLED_FILE"
    apply_waf
    ;;

  enable)
    id="${1:-}"
    validate_rule_id "$id"
    snapshot_waf
    if [[ -f "$WAF_DISABLED_FILE" ]]; then
      grep -v -x "$id" "$WAF_DISABLED_FILE" > "$WAF_DISABLED_FILE.tmp" || true
      if [[ -s "$WAF_DISABLED_FILE.tmp" ]]; then
        mv "$WAF_DISABLED_FILE.tmp" "$WAF_DISABLED_FILE"
      else
        rm -f "$WAF_DISABLED_FILE.tmp" "$WAF_DISABLED_FILE"
      fi
    fi
    apply_waf
    ;;

  custom-save)
    id="${1:-}"
    source="${2:-}"
    [[ -f "$source" ]] || die "Custom rule file is required."
    validate_custom_rule "$id" "$source"
    snapshot_waf
    rm -f "$(custom_disabled_path "$id")"
    install -m 0600 "$source" "$(custom_enabled_path "$id")"
    apply_waf
    ;;

  custom-disable)
    id="${1:-}"
    validate_rule_id "$id"
    enabled="$(custom_enabled_path "$id")"
    disabled="$(custom_disabled_path "$id")"
    [[ -f "$enabled" ]] || die "Enabled custom rule not found."
    snapshot_waf
    mv "$enabled" "$disabled"
    apply_waf
    ;;

  custom-enable)
    id="${1:-}"
    validate_rule_id "$id"
    enabled="$(custom_enabled_path "$id")"
    disabled="$(custom_disabled_path "$id")"
    [[ -f "$disabled" ]] || die "Disabled custom rule not found."
    snapshot_waf
    mv "$disabled" "$enabled"
    apply_waf
    ;;

  custom-delete)
    id="${1:-}"
    validate_rule_id "$id"
    snapshot_waf
    rm -f "$(custom_enabled_path "$id")" "$(custom_disabled_path "$id")"
    apply_waf
    ;;

  export)
    output="${1:-}"
    [[ -n "$output" ]] || die "Output path is required."
    ensure_settings
    /opt/liteedge/bin/wafregistry.sh ensure >/dev/null 2>&1 || true
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    root="$tmp/liteedge-waf"
    mkdir -p "$root/custom" "$root/plugins"
    cat > "$root/manifest" <<'EOF'
FORMAT=liteedge-waf-rules
VERSION=2
EOF
    cp "$WAF_SETTINGS_FILE" "$root/settings.conf"
    [[ -f "$WAF_DISABLED_FILE" ]] && cp "$WAF_DISABLED_FILE" "$root/disabled-rules"
    [[ -f "$WAF_REGISTRY_FILE" ]] && cp "$WAF_REGISTRY_FILE" "$root/registry.tsv"
    cp -a "$WAF_CUSTOM_DIR/." "$root/custom/" 2>/dev/null || true
    cp -a "$WAF_PLUGIN_DIR/." "$root/plugins/" 2>/dev/null || true
    tar -C "$tmp" -czf "$output" liteedge-waf
    chmod 600 "$output"
    ;;

  import)
    archive="${1:-}"
    [[ -f "$archive" ]] || die "Rules archive is required."
    safe_rule_archive "$archive"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    tar -xzf "$archive" -C "$tmp"
    root="$tmp/liteedge-waf"
    version="$(kv_get "$root/manifest" VERSION)"
    [[ "$(kv_get "$root/manifest" FORMAT)" == liteedge-waf-rules ]] || die "Unsupported OWASP rules bundle."
    case "$version" in 1|2) ;; *) die "Unsupported OWASP rules bundle version." ;; esac

    pl="$(kv_get "$root/settings.conf" PARANOIA_LEVEL)"
    [[ -z "$pl" ]] && pl=1
    validate_pl "$pl"

    if [[ -f "$root/disabled-rules" ]]; then
      while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        validate_rule_id "$id"
      done < "$root/disabled-rules"
    fi

    shopt -s nullglob
    for file in "$root/custom"/*.conf "$root/custom"/*.conf.disabled; do
      name="$(basename "$file")"
      id="${name%%.conf*}"
      validate_custom_rule "$id" "$file"
    done

    if [[ -d "$root/plugins" ]]; then
      for file in "$root/plugins"/*; do
        [[ -d "$file" ]] || continue
        name="$(basename "$file")"
        validate_plugin_name "$name"
        [[ -d "$file/plugins" ]] || die "Imported plugin $name is missing its plugins directory."
        find "$file/plugins" -type f -name '*.conf' -print -quit | grep -q . ||
          die "Imported plugin $name contains no ModSecurity configuration."
      done
    fi

    if [[ -f "$root/registry.tsv" ]]; then
      head -n1 "$root/registry.tsv" | grep -qx $'NAME\tREPO\tTYPE\tSTATUS\tCATEGORY' ||
        die "Imported plugin registry is invalid."
    fi

    snapshot_waf
    rm -rf "$WAF_DIR"
    mkdir -p "$WAF_CUSTOM_DIR" "$WAF_PLUGIN_DIR"
    printf 'PARANOIA_LEVEL=%s\n' "$pl" > "$WAF_SETTINGS_FILE"
    [[ -f "$root/disabled-rules" ]] && cp "$root/disabled-rules" "$WAF_DISABLED_FILE"
    [[ -f "$root/registry.tsv" ]] && cp "$root/registry.tsv" "$WAF_REGISTRY_FILE"
    cp -a "$root/custom/." "$WAF_CUSTOM_DIR/" 2>/dev/null || true
    cp -a "$root/plugins/." "$WAF_PLUGIN_DIR/" 2>/dev/null || true
    /opt/liteedge/bin/wafregistry.sh ensure >/dev/null 2>&1 || true
    apply_waf
    rm -rf "$tmp"
    trap - EXIT
    ;;

  *)
    echo "Usage: wafctl.sh set-pl 1|2|3|4 | disable ID | enable ID | custom-save ID FILE | custom-disable ID | custom-enable ID | custom-delete ID | export FILE | import FILE" >&2
    exit 2
    ;;
esac
