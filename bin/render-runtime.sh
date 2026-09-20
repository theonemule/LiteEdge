#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh

HTTP_PORT="${LITEEDGE_HTTP_PORT:-80}"
HTTPS_PORT="${LITEEDGE_HTTPS_PORT:-443}"
RUN_DIR="${LITEEDGE_RUN_DIR:-/tmp/liteedge-run}"
RESOLVER="${LITEEDGE_RESOLVER:-}"

[[ "$HTTP_PORT" =~ ^[0-9]+$ && "$HTTP_PORT" -ge 1 && "$HTTP_PORT" -le 65535 ]] || die "Invalid HTTP port."
[[ "$HTTPS_PORT" =~ ^[0-9]+$ && "$HTTPS_PORT" -ge 1 && "$HTTPS_PORT" -le 65535 ]] || die "Invalid HTTPS port."
[[ "$RUN_DIR" == /* && "$RUN_DIR" != *$'\n'* ]] || die "Invalid runtime directory."

if [[ -z "$RESOLVER" ]]; then
  RESOLVER="$(awk '/^nameserver[[:space:]]+/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
fi
[[ -n "$RESOLVER" && "$RESOLVER" =~ ^[A-Fa-f0-9:.]+$ ]] || RESOLVER="1.1.1.1"

mkdir -p "$NGINX_DIR" "$NGINX_SITE_DIR" "$RUN_DIR" "$RUN_DIR/client_temp" "$RUN_DIR/proxy_temp" "$RUN_DIR/fastcgi_temp" "$RUN_DIR/uwsgi_temp" "$RUN_DIR/scgi_temp"
chmod 700 "$RUN_DIR"

escape_sed() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

data_esc="$(escape_sed "$DATA_DIR")"
run_esc="$(escape_sed "$RUN_DIR")"
resolver_esc="$(escape_sed "$RESOLVER")"

sed \
  -e "s|@DATA_DIR@|$data_esc|g" \
  -e "s|@RUN_DIR@|$run_esc|g" \
  -e "s|@RESOLVER@|$resolver_esc|g" \
  /opt/liteedge/etc/nginx/nginx.conf > "$NGINX_CONF"

sed \
  -e "s|@DATA_DIR@|$data_esc|g" \
  -e "s|@RUN_DIR@|$run_esc|g" \
  -e "s|@HTTP_PORT@|$HTTP_PORT|g" \
  -e "s|@HTTPS_PORT@|$HTTPS_PORT|g" \
  /opt/liteedge/etc/nginx/admin.conf.template > "$NGINX_DIR/admin.conf"

# ModSecurity's writable paths and include root are runtime-specific too.
sed \
  -e "s|@DATA_DIR@|$data_esc|g" \
  -e "s|@RUN_DIR@|$run_esc|g" \
  /opt/liteedge/etc/modsecurity/modsecurity.conf.template > "$NGINX_DIR/modsecurity.conf"

nginx_dir_esc="$(escape_sed "$NGINX_DIR")"
sed -e "s|@NGINX_DIR@|$nginx_dir_esc|g" \
  /opt/liteedge/etc/nginx/modsecurity-main.conf.template > "$NGINX_DIR/modsecurity-main.conf"
sed -e "s|@NGINX_DIR@|$nginx_dir_esc|g" \
  /opt/liteedge/etc/nginx/modsecurity-wordpress.conf.template > "$NGINX_DIR/modsecurity-wordpress.conf"
