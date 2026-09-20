#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
SITE_DIR="$DATA_DIR/sites"
CERT_DIR="$DATA_DIR/certs"
ACME_DIR="$DATA_DIR/acme"
NGINX_SITE_DIR="${NGINX_SITE_DIR:-/etc/nginx/litewaf-sites}"

mkdir -p "$SITE_DIR" "$CERT_DIR" "$ACME_DIR/challenges/.well-known/acme-challenge" "$ACME_DIR/certs" "$NGINX_SITE_DIR"

die() {
  echo "$*" >&2
  exit 1
}

slug_for_host() {
  local host="${1,,}"
  printf '%s' "$host" | sed 's/[^a-z0-9.-]/_/g'
}

site_file() {
  printf '%s/%s.site' "$SITE_DIR" "$(slug_for_host "$1")"
}

route_dir() {
  printf '%s/%s.routes' "$SITE_DIR" "$(slug_for_host "$1")"
}

cert_dir() {
  printf '%s/%s' "$CERT_DIR" "$(slug_for_host "$1")"
}

kv_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | head -n1
}

bool_value() {
  case "${1:-}" in
    1|on|true|yes) echo 1 ;;
    *) echo 0 ;;
  esac
}

validate_host() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] ||
    die "Invalid host: $1"
}

validate_aliases() {
  local aliases="${1//,/ }" item
  for item in $aliases; do
    validate_host "$item"
  done
}

validate_mode() {
  case "$1" in
    proxy|wordpress|static) ;;
    *) die "Invalid site mode: $1" ;;
  esac
}

validate_upstream() {
  local re='^https?://[A-Za-z0-9._:-]+(/[A-Za-z0-9._~:/?@!$&()*+,=%-]*)?$'
  [[ "$1" =~ $re ]] ||
    die "Upstream must be an http:// or https:// URL using safe URL characters."
}

validate_root() {
  [[ "$1" =~ ^/(data/www|srv)/[A-Za-z0-9._/-]+$ ]] ||
    die "Static root must be under /data/www or /srv and contain only safe path characters."
}

validate_route_match() {
  case "$1" in
    prefix|exact|regex) ;;
    *) die "Invalid route match type." ;;
  esac
}

validate_route_path() {
  local value="$1"
  [[ "$value" == /* ]] || die "Route must begin with /."
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *[[:space:]]* && "$value" != *'{'* && "$value" != *'}'* && "$value" != *';'* && "$value" != *'"'* && "$value" != *"'"* ]] ||
    die "Unsafe route pattern."
}

reload_nginx() {
  nginx -s reload
}
