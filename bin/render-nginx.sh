#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh

mkdir -p "$NGINX_DIR" "$NGINX_BASELINE_DIR" "$NGINX_DIFF_DIR" "$NGINX_CONFLICT_DIR"
stage="$(mktemp -d "$NGINX_DIR/sites.stage.XXXXXX")"
baseline_stage="$(mktemp -d "$NGINX_DIR/baselines.stage.XXXXXX")"
diff_stage="$(mktemp -d "$NGINX_DIR/diffs.stage.XXXXXX")"
trap 'rm -rf "$stage" "$baseline_stage" "$diff_stage"' EXIT
shopt -s nullglob

HTTP_PORT="${LITEEDGE_HTTP_PORT:-80}"
HTTPS_PORT="${LITEEDGE_HTTPS_PORT:-443}"

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

emit_waf_config() {
  local host="$1" mode="$2" rule_id
  echo "    modsecurity on;"
  if [[ "$mode" == wordpress ]]; then
    echo "    modsecurity_rules_file $NGINX_DIR/modsecurity-wordpress.conf;"
  else
    echo "    modsecurity_rules_file $NGINX_DIR/modsecurity-main.conf;"
  fi

  while IFS= read -r rule_id; do
    [[ -n "$rule_id" ]] || continue
    echo "    modsecurity_rules 'SecRuleRemoveById $rule_id';"
  done < <(disabled_waf_rules "$host")
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
  printf '        set $liteedge_route_%s "%s";\n' "$id" "$target"
  printf '        proxy_pass $liteedge_route_%s;\n' "$id"
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
        set \$liteedge_default_upstream "$upstream";
        proxy_pass \$liteedge_default_upstream;
CONF
      emit_proxy_headers
      [[ "$websocket" == 1 ]] && emit_websocket_headers
      echo "    }"
      ;;
    proxy)
      cat <<CONF
    location / {
        set \$liteedge_default_upstream "$upstream";
        proxy_pass \$liteedge_default_upstream;
CONF
      emit_proxy_headers
      [[ "$websocket" == 1 ]] && emit_websocket_headers
      echo "    }"
      ;;
  esac
}

merge_manual_delta() {
  local host="$1" generated="$2" output="$3"
  local current baseline conflict
  current="$(site_nginx_file "$host")"
  baseline="$(site_nginx_baseline "$host")"
  conflict="$(site_nginx_conflict "$host")"
  rm -f "$conflict"

  if [[ -s "$baseline" && -s "$current" ]] && ! cmp -s "$baseline" "$current"; then
    command -v patch >/dev/null 2>&1 ||
      die "Manual NGINX edits exist for $host, but patch is unavailable. Install the Alpine patch package before regenerating this site."

    delta="$(mktemp)"
    merged="$(mktemp)"
    diff -U0 --label "generated baseline" --label "effective config" "$baseline" "$current" > "$delta" || true

    if command -v diff3 >/dev/null 2>&1 && diff3 -m "$current" "$baseline" "$generated" > "$merged"; then
      mv "$merged" "$output"
    else
      cp "$generated" "$output"
      if ! patch --batch --silent --fuzz=0 "$output" < "$delta"; then
        if [[ -s "$merged" ]]; then
          cp "$merged" "$conflict"
        else
          cp "$output" "$conflict"
        fi
        rm -f "$delta" "$merged"
        die "Manual NGINX edits for $host conflict with newly generated settings. Resolve the conflict from Advanced NGINX before retrying."
      fi
      rm -f "$merged"
    fi
    rm -f "$delta"
  elif [[ -s "$current" && ! -s "$baseline" ]]; then
    # Upgrade-safe bootstrap. Preserve any existing site config when baselines
    # are introduced for the first time.
    cp "$current" "$output"
  else
    cp "$generated" "$output"
  fi
}

record_generated_diff() {
  local host="$1" generated="$2" baseline diff_out
  baseline="$(site_nginx_baseline "$host")"
  diff_out="$diff_stage/$(slug_for_host "$host").diff"

  if [[ -s "$baseline" ]] && ! cmp -s "$baseline" "$generated"; then
    diff -u --label "previous generated" --label "new generated" "$baseline" "$generated" > "$diff_out" || true
  elif [[ -s "$(site_nginx_diff "$host")" ]]; then
    cp "$(site_nginx_diff "$host")" "$diff_out"
  fi
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
  generated="$baseline_stage/$slug.conf"
  cdir="$(cert_dir "$host")"
  cert="$cdir/fullchain.pem"
  key="$cdir/privkey.pem"

  {
    echo "server {"
    echo "    listen $HTTP_PORT;"
    echo "    server_name $host $aliases;"
    echo "    include /opt/liteedge/etc/nginx/security.conf;"
    if [[ "$waf" == 1 ]]; then
      emit_waf_config "$host" "$mode"
    fi
    cat <<CONF
    location ^~ /.well-known/acme-challenge/ {
        root $ACME_DIR/challenges;
        auth_basic off;
        try_files \$uri =404;
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
      echo "    listen $HTTPS_PORT ssl;"
      echo "    http2 on;"
      echo "    server_name $host $aliases;"
      echo "    ssl_certificate $cert;"
      echo "    ssl_certificate_key $key;"
      echo "    ssl_protocols TLSv1.2 TLSv1.3;"
      echo "    ssl_session_cache shared:SSL:10m;"
      echo "    ssl_session_timeout 10m;"
      echo "    ssl_session_tickets off;"
      echo '    add_header Strict-Transport-Security "max-age=31536000" always;'
      echo "    include /opt/liteedge/etc/nginx/security.conf;"
      if [[ "$waf" == 1 ]]; then
        emit_waf_config "$host" "$mode"
      fi
      emit_app "$host" "$mode" "$upstream" "$root" "$websocket"
      echo "}"
    fi
  } > "$generated"

  record_generated_diff "$host" "$generated"
  merge_manual_delta "$host" "$generated" "$out"
done

backup="${NGINX_SITE_DIR}.backup"
rm -rf "$backup"
if [[ -d "$NGINX_SITE_DIR" ]]; then
  mv "$NGINX_SITE_DIR" "$backup"
fi
mv "$stage" "$NGINX_SITE_DIR"

if [[ "${SKIP_NGINX_TEST:-0}" != 1 ]] && ! "$NGINX_BIN" -t -c "$NGINX_CONF"; then
  rm -rf "$NGINX_SITE_DIR"
  [[ -d "$backup" ]] && mv "$backup" "$NGINX_SITE_DIR"
  echo "Generated NGINX configuration failed validation; previous configuration restored." >&2
  exit 1
fi

rm -rf "$backup"

baseline_backup="${NGINX_BASELINE_DIR}.backup"
diff_backup="${NGINX_DIFF_DIR}.backup"
rm -rf "$baseline_backup" "$diff_backup"
[[ -d "$NGINX_BASELINE_DIR" ]] && mv "$NGINX_BASELINE_DIR" "$baseline_backup"
[[ -d "$NGINX_DIFF_DIR" ]] && mv "$NGINX_DIFF_DIR" "$diff_backup"
mv "$baseline_stage" "$NGINX_BASELINE_DIR"
mv "$diff_stage" "$NGINX_DIFF_DIR"
rm -rf "$baseline_backup" "$diff_backup"
trap - EXIT
