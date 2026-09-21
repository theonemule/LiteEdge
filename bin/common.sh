#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/liteedge/bin:/opt/liteedge/sbin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
export LD_LIBRARY_PATH="/opt/liteedge/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

DATA_DIR="${DATA_DIR:-/data}"
SITE_DIR="$DATA_DIR/sites"
CERT_DIR="$DATA_DIR/certs"
ACME_DIR="$DATA_DIR/acme"
NGINX_DIR="$DATA_DIR/nginx"
NGINX_SITE_DIR="${NGINX_SITE_DIR:-$NGINX_DIR/sites}"
NGINX_BASELINE_DIR="${NGINX_BASELINE_DIR:-$NGINX_DIR/baselines}"
NGINX_DIFF_DIR="${NGINX_DIFF_DIR:-$NGINX_DIR/diffs}"
NGINX_CONFLICT_DIR="${NGINX_CONFLICT_DIR:-$NGINX_DIR/conflicts}"
NGINX_CONF="${NGINX_CONF:-$NGINX_DIR/nginx.conf}"
NGINX_BIN="${NGINX_BIN:-/opt/liteedge/sbin/nginx}"

mkdir -p   "$SITE_DIR" "$CERT_DIR"   "$ACME_DIR/challenges/.well-known/acme-challenge" "$ACME_DIR/certs"   "$NGINX_SITE_DIR" "$NGINX_BASELINE_DIR" "$NGINX_DIFF_DIR" "$NGINX_CONFLICT_DIR"

die() {
  echo "$*" >&2
  exit 1
}

slug_for_host() {
  local host="${1,,}"
  printf '%s' "$host" | sed 's/[^a-z0-9.-]/_/g'
}

site_file() { printf '%s/%s.site' "$SITE_DIR" "$(slug_for_host "$1")"; }
route_dir() { printf '%s/%s.routes' "$SITE_DIR" "$(slug_for_host "$1")"; }
cert_dir() { printf '%s/%s' "$CERT_DIR" "$(slug_for_host "$1")"; }
waf_rule_file() { printf '%s/%s.waf-disabled' "$SITE_DIR" "$(slug_for_host "$1")"; }
site_nginx_file() { printf '%s/%s.conf' "$NGINX_SITE_DIR" "$(slug_for_host "$1")"; }
site_nginx_baseline() { printf '%s/%s.conf' "$NGINX_BASELINE_DIR" "$(slug_for_host "$1")"; }
site_nginx_diff() { printf '%s/%s.diff' "$NGINX_DIFF_DIR" "$(slug_for_host "$1")"; }
site_nginx_conflict() { printf '%s/%s.conflict' "$NGINX_CONFLICT_DIR" "$(slug_for_host "$1")"; }

kv_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | head -n1
}

bool_value() {
  case "${1:-}" in 1|on|true|yes) echo 1 ;; *) echo 0 ;; esac
}

validate_host() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] ||
    die "Invalid host: $1"
}

validate_aliases() {
  local aliases="${1//,/ }" item
  for item in $aliases; do validate_host "$item"; done
}

validate_mode() {
  case "$1" in proxy|wordpress|static) ;; *) die "Invalid site mode: $1" ;; esac
}

validate_upstream() {
  local re='^https?://[A-Za-z0-9._:-]+(/[A-Za-z0-9._~:/?@!$&()*+,=%-]*)?$'
  [[ "$1" =~ $re ]] || die "Upstream must be an http:// or https:// URL using safe URL characters."
}

validate_root() {
  local value="$1"
  [[ "$value" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Unsafe static root."
  case "$value" in
    "$DATA_DIR"/www/*|/srv/*) ;;
    *) die "Static root must be under $DATA_DIR/www or /srv." ;;
  esac
}

validate_route_match() {
  case "$1" in prefix|exact|regex) ;; *) die "Invalid route match type." ;; esac
}

validate_route_path() {
  local value="$1"
  [[ "$value" == /* ]] || die "Route must begin with /."
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *[[:space:]]* && "$value" != *'{'* && "$value" != *'}'* && "$value" != *';'* && "$value" != *'"'* && "$value" != *"'"* ]] ||
    die "Unsafe route pattern."
}


validate_rule_id() {
  [[ "${1:-}" =~ ^[0-9]{1,9}$ ]] || die "ModSecurity rule ID must contain digits only."
}

disabled_waf_rules() {
  local file
  file="$(waf_rule_file "$1")"
  [[ -f "$file" ]] || return 0
  grep -E '^[0-9]{1,9}$' "$file" | sort -n -u
}

reload_nginx() {
  "$NGINX_BIN" -s reload -c "$NGINX_CONF"
}
