#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /opt/litewaf/bin/common.sh

stage="$(mktemp -d /etc/nginx/litewaf-sites.stage.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
shopt -s nullglob

emit_proxy_headers() {
  cat <<'CONF'
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
CONF
}

emit_websocket_headers() {
  cat <<'CONF'
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 3600s;
CONF
}

emit_route() {
  local route="$1"
  local match path target websocket location id
  match="$(kv_get "$route" MATCH)"
  path="$(kv_get "$route" PATH)"
  target="$(kv_get "$route" TARGET)"
  websocket="$(kv_get "$route" WEBSOCKET)"
  id="$(kv_get "$route" ID)"

  case "$match" in
    exact) location="location = $path" ;;
    regex) location="location ~ $path" ;;
    *) location="location ^~ $path" ;;
  esac

  printf '    %s {\n' "$location"
  printf '        set $litewaf_route_%s "%s";\n' "$id" "$target"
  printf '        proxy_pass $litewaf_route_%s;\n' "$id"
  emit_proxy_headers
  [[ "$websocket" == 1 ]] && emit_websocket_headers
  echo "    }"
}

emit_routes() {
  local host="$1" route
  for route in "$(route_dir "$host")"/*.route; do
    [[ -e "$route" ]] || continue
    emit_route "$route"
  done
}

emit_app() {
  local host="$1" mode="$2" upstream="$3" root="$4" websocket="$5"

  emit_routes "$host"

  case "$mode" in
    static)
      cat <<CONF
    location / {
        root $root;
        try_files \$uri \$uri/ =404;
    }
CONF
      ;;

    wordpress)
      cat <<'CONF'
    location ~ /\. {
        deny all;
    }

    location = /wp-config.php {
        deny all;
    }

    location = /readme.html {
        deny all;
    }

    location = /license.txt {
        deny all;
    }

    location ~* ^/(?:wp-content/)?uploads/.*\.php$ {
        deny all;
    }
CONF
      cat <<CONF
    location / {
        set \$litewaf_default_upstream "$upstream";
        proxy_pass \$litewaf_default_upstream;
CONF
      emit_proxy_headers
      [[ "$websocket" == 1 ]] && emit_websocket_headers
      echo "    }"
      ;;

    proxy)
      cat <<CONF
    location / {
        set \$litewaf_default_upstream "$upstream";
        proxy_pass \$litewaf_default_upstream;
CONF
      emit_proxy_headers
      [[ "$websocket" == 1 ]] && emit_websocket_headers
      echo "    }"
      ;;
  esac
}

for file in "$SITE_DIR"/*.site; do
  host="$(kv_get "$file" HOST)"
  mode="$(kv_get "$file" MODE)"
  upstream="$(kv_get "$file" UPSTREAM)"
  root="$(kv_get "$file" ROOT)"
  aliases="$(kv_get "$file" ALIASES)"
  force_https="$(kv_get "$file" FORCE_HTTPS)"
  waf="$(kv_get "$file" WAF)"
  websocket="$(kv_get "$file" WEBSOCKET)"
  slug="$(slug_for_host "$host")"
  out="$stage/$slug.conf"
  cdir="$(cert_dir "$host")"
  cert="$cdir/fullchain.pem"
  key="$cdir/privkey.pem"

  {
    echo "server {"
    echo "    listen 80;"
    echo "    server_name $host $aliases;"
    echo "    include /etc/nginx/snippets/litewaf-security.conf;"
    if [[ "$waf" == 1 ]]; then
      echo "    modsecurity on;"
      if [[ "$mode" == wordpress ]]; then
        echo "    modsecurity_rules_file /etc/nginx/modsec/wordpress.conf;"
      else
        echo "    modsecurity_rules_file /etc/nginx/modsec/main.conf;"
      fi
    fi
    cat <<'CONF'
    location ^~ /.well-known/acme-challenge/ {
        root /data/acme/challenges;
        auth_basic off;
        try_files $uri =404;
    }
CONF
    if [[ "$force_https" == 1 && -s "$cert" && -s "$key" ]]; then
      cat <<'CONF'
    location / {
        return 301 https://$host$request_uri;
    }
CONF
    else
      emit_app "$host" "$mode" "$upstream" "$root" "$websocket"
    fi
    echo "}"

    if [[ -s "$cert" && -s "$key" ]]; then
      echo
      echo "server {"
      echo "    listen 443 ssl;"
      echo "    http2 on;"
      echo "    server_name $host $aliases;"
      echo "    ssl_certificate $cert;"
      echo "    ssl_certificate_key $key;"
      echo "    ssl_protocols TLSv1.2 TLSv1.3;"
      echo "    ssl_session_cache shared:SSL:10m;"
      echo "    ssl_session_timeout 10m;"
      echo '    add_header Strict-Transport-Security "max-age=31536000" always;'
      echo "    include /etc/nginx/snippets/litewaf-security.conf;"
      if [[ "$waf" == 1 ]]; then
        echo "    modsecurity on;"
        if [[ "$mode" == wordpress ]]; then
          echo "    modsecurity_rules_file /etc/nginx/modsec/wordpress.conf;"
        else
          echo "    modsecurity_rules_file /etc/nginx/modsec/main.conf;"
        fi
      fi
      emit_app "$host" "$mode" "$upstream" "$root" "$websocket"
      echo "}"
    fi
  } > "$out"
done

backup="${NGINX_SITE_DIR}.backup"
rm -rf "$backup"
if [[ -d "$NGINX_SITE_DIR" ]]; then
  mv "$NGINX_SITE_DIR" "$backup"
fi
mv "$stage" "$NGINX_SITE_DIR"
trap - EXIT

if [[ "${SKIP_NGINX_TEST:-0}" != 1 ]] && ! nginx -t; then
  rm -rf "$NGINX_SITE_DIR"
  [[ -d "$backup" ]] && mv "$backup" "$NGINX_SITE_DIR"
  echo "Generated NGINX configuration failed validation; previous configuration restored." >&2
  exit 1
fi

rm -rf "$backup"
