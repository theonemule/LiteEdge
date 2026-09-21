#!/usr/bin/env bash
set -uo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck disable=SC1091
source /opt/liteedge/bin/common.sh

declare -A PARAM

url_decode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

parse_params() {
  local raw="$1" pair key value
  local IFS='&'
  for pair in $raw; do
    key="${pair%%=*}"
    if [[ "$pair" == *=* ]]; then
      value="${pair#*=}"
    else
      value=""
    fi
    key="$(url_decode "$key")"
    value="$(url_decode "$value")"
    PARAM["$key"]="$value"
  done
}

html_escape() {
  printf '%s' "${1:-}" |
    sed -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&#39;/g"
}

checkbox() {
  [[ "${1:-0}" == 1 ]] && printf 'checked'
}

selected() {
  [[ "${1:-}" == "${2:-}" ]] && printf 'selected'
}

response_headers() {
  printf 'Content-Type: text/html; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n'
  printf 'X-Content-Type-Options: nosniff\r\n'
  printf '\r\n'
}

page_head() {
  local title
  title="$(html_escape "${1:-LiteEdge}")"
  response_headers
  cat <<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$title - LiteEdge</title>
  <link href="/assets/bootstrap.min.css" rel="stylesheet">
  <script src="/assets/admin.js" defer></script>
</head>
<body class="bg-body-tertiary">
<nav class="navbar navbar-expand-lg bg-dark navbar-dark mb-4">
  <div class="container">
    <a class="navbar-brand fw-semibold" href="/">LiteEdge</a>
    <span class="navbar-text">Lightweight NGINX control plane</span>
  </div>
</nav>
<main class="container pb-5">
HTML
}

page_tail() {
  cat <<'HTML'
</main>
</body>
</html>
HTML
}

error_page() {
  local message="$1"
  page_head "Error"
  cat <<HTML
<div class="alert alert-danger">
  <h1 class="h5">Request failed</h1>
  <pre class="mb-0">$(html_escape "$message")</pre>
</div>
<a class="btn btn-secondary" href="/">Back</a>
HTML
  page_tail
  exit 0
}

redirect() {
  local location="$1"
  printf 'Status: 303 See Other\r\n'
  printf 'Location: %s\r\n' "$location"
  printf 'Cache-Control: no-store\r\n\r\n'
  exit 0
}

run_or_error() {
  local output
  if ! output="$("$@" 2>&1)"; then
    error_page "$output"
  fi
}

cert_mode() {
  local host="$1" file
  file="$(cert_dir "$host")/mode"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    printf 'none'
  fi
}

cert_summary() {
  local host="$1" cert
  cert="$(cert_dir "$host")/fullchain.pem"
  if [[ -s "$cert" ]]; then
    openssl x509 -in "$cert" -noout -subject -issuer -enddate 2>/dev/null || true
  fi
}

dashboard() {
  page_head "Sites"
  cat <<'HTML'
<div class="d-flex justify-content-between align-items-center mb-3">
  <div>
    <h1 class="h3 mb-1">Sites</h1>
    <p class="text-secondary mb-0">NGINX virtual hosts, reverse proxies, routes, WebSockets, WAF, and TLS.</p>
  </div>
  <a class="btn btn-primary" href="/admin/site">Add site</a>
</div>
<div class="card shadow-sm mb-4">
  <div class="card-header"><strong>Import / export all sites</strong></div>
  <div class="card-body">
    <p class="text-secondary">Export every site's settings, routes, WAF overrides, and Advanced NGINX deltas. Certificates and private keys are optional.</p>
    <div class="d-flex flex-wrap gap-2 mb-4">
      <a class="btn btn-outline-primary" href="/admin/export?scope=all&certificates=0">Export all settings</a>
      <a class="btn btn-outline-warning" href="/admin/export?scope=all&certificates=1">Export all + certificates</a>
    </div>
    <form class="bundle-import-form border rounded p-3 mb-3" data-scope="site" data-redirect="/">
      <h2 class="h6">Import one site</h2>
      <p class="small text-secondary">Import a site bundle into this LiteEdge instance. The bundle's host name identifies the site to create or replace.</p>
      <div class="row g-3 align-items-end">
        <div class="col-lg-7">
          <label class="form-label">LiteEdge site bundle</label>
          <input class="form-control" type="file" accept=".tar.gz,.tgz,application/gzip" required>
        </div>
        <div class="col-lg-3">
          <div class="form-check mb-2">
            <input class="form-check-input" type="checkbox" name="certificates" value="1" id="import_one_certs">
            <label class="form-check-label" for="import_one_certs">Import certificate and private key</label>
          </div>
        </div>
        <div class="col-lg-2">
          <button class="btn btn-primary w-100" type="submit">Import site</button>
        </div>
      </div>
    </form>

    <form class="bundle-import-form border rounded p-3" data-scope="all" data-redirect="/">
      <h2 class="h6">Import all sites</h2>
      <p class="small text-secondary">This replaces the full set of site settings with the bundle. Existing site certificates are left alone unless certificate import is enabled.</p>
      <div class="row g-3 align-items-end">
        <div class="col-lg-7">
          <label class="form-label">LiteEdge bundle</label>
          <input class="form-control" type="file" accept=".tar.gz,.tgz,application/gzip" required>
        </div>
        <div class="col-lg-3">
          <div class="form-check mb-2">
            <input class="form-check-input" type="checkbox" name="certificates" value="1" id="import_all_certs">
            <label class="form-check-label" for="import_all_certs">Import certificates and private keys</label>
          </div>
        </div>
        <div class="col-lg-2">
          <button class="btn btn-primary w-100" type="submit">Import all</button>
        </div>
      </div>
    </form>
  </div>
</div>

<div class="card shadow-sm">
  <div class="table-responsive">
    <table class="table table-hover align-middle mb-0">
      <thead>
        <tr>
          <th>Host</th>
          <th>Profile</th>
          <th>Destination</th>
          <th>WAF</th>
          <th>WebSocket</th>
          <th>TLS</th>
          <th class="text-end">Actions</th>
        </tr>
      </thead>
      <tbody>
HTML
  shopt -s nullglob
  local files=("$SITE_DIR"/*.site)
  if [[ ${#files[@]} -eq 0 ]]; then
    cat <<'HTML'
        <tr><td colspan="7" class="text-center text-secondary py-5">No sites configured yet.</td></tr>
HTML
  else
    local file host mode upstream root waf websocket destination tls
    for file in "${files[@]}"; do
      host="$(kv_get "$file" HOST)"
      mode="$(kv_get "$file" MODE)"
      upstream="$(kv_get "$file" UPSTREAM)"
      root="$(kv_get "$file" ROOT)"
      waf="$(kv_get "$file" WAF)"
      websocket="$(kv_get "$file" WEBSOCKET)"
      destination="$upstream"
      [[ "$mode" == static ]] && destination="$root"
      tls="$(cert_mode "$host")"
      cat <<HTML
        <tr>
          <td><a class="fw-semibold text-decoration-none" href="/admin/site?host=$(html_escape "$host")">$(html_escape "$host")</a></td>
          <td><span class="badge text-bg-secondary">$(html_escape "$mode")</span></td>
          <td><code>$(html_escape "$destination")</code></td>
          <td>$([[ "$waf" == 1 ]] && echo On || echo Off)</td>
          <td>$([[ "$websocket" == 1 ]] && echo On || echo Off)</td>
          <td><span class="badge text-bg-light border">$(html_escape "$tls")</span></td>
          <td class="text-end">
            <a class="btn btn-sm btn-outline-primary" href="/admin/site?host=$(html_escape "$host")">Manage</a>
            <form class="d-inline" method="post" action="/admin/site/delete">
              <input type="hidden" name="host" value="$(html_escape "$host")">
              <button class="btn btn-sm btn-outline-danger" type="submit">Delete</button>
            </form>
          </td>
        </tr>
HTML
    done
  fi
  cat <<'HTML'
      </tbody>
    </table>
  </div>
</div>
HTML
  page_tail
}

site_editor() {
  local host="${PARAM[host]:-}"
  local exists=0 file mode=proxy upstream="" root="" aliases="" force_https=0 waf=1 websocket=0
  if [[ -n "$host" ]]; then
    validate_host "$host" 2>/dev/null || error_page "Invalid host."
    file="$(site_file "$host")"
    if [[ -f "$file" ]]; then
      exists=1
      mode="$(kv_get "$file" MODE)"
      upstream="$(kv_get "$file" UPSTREAM)"
      root="$(kv_get "$file" ROOT)"
      aliases="$(kv_get "$file" ALIASES)"
      force_https="$(kv_get "$file" FORCE_HTTPS)"
      waf="$(kv_get "$file" WAF)"
      websocket="$(kv_get "$file" WEBSOCKET)"
    fi
  fi

  page_head "$([[ "$exists" == 1 ]] && echo "Manage $host" || echo "Add site")"
  cat <<HTML
<div class="d-flex justify-content-between align-items-center mb-3">
  <div>
    <h1 class="h3 mb-1">$([[ "$exists" == 1 ]] && printf '%s' "$(html_escape "$host")" || echo "Add site")</h1>
    <p class="text-secondary mb-0">The default upstream can be overridden by path routes below.</p>
  </div>
  <a class="btn btn-outline-secondary" href="/">Back to sites</a>
</div>

<form method="post" action="/admin/site/save" class="card shadow-sm mb-4">
  <div class="card-body">
    <div class="row g-3">
      <div class="col-md-6">
        <label class="form-label">Host name</label>
        <input class="form-control" name="host" value="$(html_escape "$host")" placeholder="app.example.com" $([[ "$exists" == 1 ]] && echo readonly) required>
      </div>
      <div class="col-md-6">
        <label class="form-label">Aliases</label>
        <input class="form-control" name="aliases" value="$(html_escape "$aliases")" placeholder="www.example.com api.example.com">
        <div class="form-text">Space- or comma-separated DNS names.</div>
      </div>
      <div class="col-md-4">
        <label class="form-label">Site profile</label>
        <select class="form-select" name="mode">
          <option value="proxy" $(selected "$mode" proxy)>Reverse proxy</option>
          <option value="wordpress" $(selected "$mode" wordpress)>WordPress hardened proxy</option>
          <option value="static" $(selected "$mode" static)>Local static content</option>
        </select>
      </div>
      <div class="col-md-8">
        <label class="form-label">Default upstream</label>
        <input class="form-control font-monospace" name="upstream" value="$(html_escape "$upstream")" placeholder="http://app:8080">
        <div class="form-text">Used by Reverse proxy and WordPress profiles.</div>
      </div>
      <div class="col-12">
        <label class="form-label">Static document root</label>
        <input class="form-control font-monospace" name="root" value="$(html_escape "$root")" placeholder="/var/lib/liteedge/www/app.example.com">
        <div class="form-text">Used only by Local static content. Roots are restricted to the LiteEdge data www directory or /srv.</div>
      </div>
      <div class="col-12">
        <div class="form-check form-switch mb-2">
          <input class="form-check-input" type="checkbox" role="switch" name="waf" value="1" id="waf" $(checkbox "$waf")>
          <label class="form-check-label" for="waf">Enable ModSecurity + OWASP Core Rule Set</label>
        </div>
        <div class="form-check form-switch mb-2">
          <input class="form-check-input" type="checkbox" role="switch" name="websocket" value="1" id="websocket" $(checkbox "$websocket")>
          <label class="form-check-label" for="websocket">Enable WebSocket upgrade on the default upstream</label>
        </div>
        <div class="form-check form-switch">
          <input class="form-check-input" type="checkbox" role="switch" name="force_https" value="1" id="force_https" $(checkbox "$force_https")>
          <label class="form-check-label" for="force_https">Redirect HTTP to HTTPS once a certificate exists</label>
        </div>
      </div>
    </div>
  </div>
  <div class="card-footer text-end">
    <button class="btn btn-primary" type="submit">Save site</button>
  </div>
</form>
HTML

  if [[ "$exists" == 1 ]]; then
    waf_rules_panel "$host"
    routes_panel "$host"
    certificate_panel "$host"
    transfer_panel "$host"
    advanced_nginx_panel "$host"
  else
    cat <<'HTML'
<div class="alert alert-info">Save the site first, then you can add path routes and configure certificates.</div>
HTML
  fi
  page_tail
}

routes_panel() {
  local host="$1" dir route id match path target websocket
  dir="$(route_dir "$host")"
  cat <<HTML
<div class="card shadow-sm mb-4">
  <div class="card-header"><strong>Path routes</strong></div>
  <div class="card-body">
    <p class="text-secondary">Create exact, prefix, or regex locations that proxy to a different backend. WebSocket handling can be enabled per route.</p>
    <div class="table-responsive mb-4">
      <table class="table table-sm align-middle">
        <thead><tr><th>Match</th><th>Path / pattern</th><th>Target</th><th>WebSocket</th><th></th></tr></thead>
        <tbody>
HTML
  shopt -s nullglob
  local routes=("$dir"/*.route)
  if [[ ${#routes[@]} -eq 0 ]]; then
    echo '<tr><td colspan="5" class="text-secondary">No custom routes.</td></tr>'
  else
    for route in "${routes[@]}"; do
      id="$(kv_get "$route" ID)"
      match="$(kv_get "$route" MATCH)"
      path="$(kv_get "$route" PATH)"
      target="$(kv_get "$route" TARGET)"
      websocket="$(kv_get "$route" WEBSOCKET)"
      cat <<HTML
<tr>
  <td>$(html_escape "$match")</td>
  <td><code>$(html_escape "$path")</code></td>
  <td><code>$(html_escape "$target")</code></td>
  <td>$([[ "$websocket" == 1 ]] && echo On || echo Off)</td>
  <td class="text-end">
    <form method="post" action="/admin/route/delete">
      <input type="hidden" name="host" value="$(html_escape "$host")">
      <input type="hidden" name="id" value="$(html_escape "$id")">
      <button class="btn btn-sm btn-outline-danger" type="submit">Delete</button>
    </form>
  </td>
</tr>
HTML
    done
  fi
  cat <<HTML
        </tbody>
      </table>
    </div>

    <form method="post" action="/admin/route/add" class="row g-2 align-items-end">
      <input type="hidden" name="host" value="$(html_escape "$host")">
      <div class="col-md-2">
        <label class="form-label">Match</label>
        <select class="form-select" name="match">
          <option value="prefix">Prefix</option>
          <option value="exact">Exact</option>
          <option value="regex">Regex</option>
        </select>
      </div>
      <div class="col-md-3">
        <label class="form-label">Path / pattern</label>
        <input class="form-control font-monospace" name="path" placeholder="/api/" required>
      </div>
      <div class="col-md-4">
        <label class="form-label">Target</label>
        <input class="form-control font-monospace" name="target" placeholder="http://api:8080" required>
      </div>
      <div class="col-md-2">
        <div class="form-check mb-2">
          <input class="form-check-input" type="checkbox" name="websocket" value="1" id="route_ws">
          <label class="form-check-label" for="route_ws">WebSocket</label>
        </div>
      </div>
      <div class="col-md-1">
        <button class="btn btn-outline-primary w-100" type="submit">Add</button>
      </div>
    </form>
  </div>
</div>
HTML
}

waf_rules_panel() {
  local host="$1" site waf rule_id disabled
  site="$(site_file "$host")"
  waf="$(kv_get "$site" WAF)"
  disabled="$(disabled_waf_rules "$host")"

  cat <<HTML
<div class="card shadow-sm mb-4">
  <div class="card-header d-flex justify-content-between align-items-center">
    <strong>WAF rule overrides</strong>
    <span class="badge $([[ "$waf" == 1 ]] && echo text-bg-success || echo text-bg-secondary)">$([[ "$waf" == 1 ]] && echo WAF-on || echo WAF-off)</span>
  </div>
  <div class="card-body">
    <p class="text-secondary">OWASP CRS rules are enabled by default. Disable a specific rule ID only for this site; enabling it again removes the site-specific override.</p>
HTML

  if [[ "$waf" != 1 ]]; then
    echo '<div class="alert alert-warning py-2">The WAF is currently disabled for this site. Overrides are retained and will apply if the WAF is enabled later.</div>'
  fi

  if [[ -z "$disabled" ]]; then
    echo '<p class="small text-secondary mb-3">No CRS rules are disabled for this site.</p>'
  else
    cat <<'HTML'
    <div class="table-responsive mb-3">
      <table class="table table-sm align-middle">
        <thead><tr><th>Disabled rule ID</th><th class="text-end">Action</th></tr></thead>
        <tbody>
HTML
    while IFS= read -r rule_id; do
      [[ -n "$rule_id" ]] || continue
      cat <<HTML
<tr>
  <td><code>$(html_escape "$rule_id")</code></td>
  <td class="text-end">
    <form method="post" action="/admin/waf/enable">
      <input type="hidden" name="host" value="$(html_escape "$host")">
      <input type="hidden" name="rule_id" value="$(html_escape "$rule_id")">
      <button class="btn btn-sm btn-outline-success" type="submit">Enable</button>
    </form>
  </td>
</tr>
HTML
    done <<< "$disabled"
    cat <<'HTML'
        </tbody>
      </table>
    </div>
HTML
  fi

  cat <<HTML
    <form method="post" action="/admin/waf/disable" class="row g-2 align-items-end">
      <input type="hidden" name="host" value="$(html_escape "$host")">
      <div class="col-md-5">
        <label class="form-label">CRS rule ID</label>
        <input class="form-control font-monospace" name="rule_id" inputmode="numeric" pattern="[0-9]{1,9}" placeholder="942100" required>
      </div>
      <div class="col-md-auto">
        <button class="btn btn-outline-danger" type="submit">Disable rule</button>
      </div>
    </form>
  </div>
</div>
HTML
}

transfer_panel() {
  local host="$1" slug
  slug="$(slug_for_host "$host")"
  cat <<HTML
<div class="card shadow-sm mb-4">
  <div class="card-header"><strong>Import / export site</strong></div>
  <div class="card-body">
    <p class="text-secondary">Move this site's settings, routes, WAF overrides, and Advanced NGINX delta between LiteEdge instances. Certificate and private-key export is optional.</p>
    <div class="d-flex flex-wrap gap-2 mb-4">
      <a class="btn btn-outline-primary" href="/admin/export?scope=site&amp;host=$(html_escape "$host")&amp;certificates=0">Export settings</a>
      <a class="btn btn-outline-warning" href="/admin/export?scope=site&amp;host=$(html_escape "$host")&amp;certificates=1">Export settings + certificate</a>
    </div>
    <form class="bundle-import-form border rounded p-3" data-scope="site" data-host="$(html_escape "$host")" data-redirect="/admin/site?host=$(html_escape "$host")">
      <h2 class="h6">Import this site</h2>
      <p class="small text-secondary">The selected bundle must be a site bundle for <code>$(html_escape "$host")</code>. Existing certificates remain unless certificate import is enabled.</p>
      <div class="row g-3 align-items-end">
        <div class="col-lg-7">
          <label class="form-label">LiteEdge site bundle</label>
          <input class="form-control" type="file" accept=".tar.gz,.tgz,application/gzip" required>
        </div>
        <div class="col-lg-3">
          <div class="form-check mb-2">
            <input class="form-check-input" type="checkbox" name="certificates" value="1" id="import_site_certs_$slug">
            <label class="form-check-label" for="import_site_certs_$slug">Import certificate and private key</label>
          </div>
        </div>
        <div class="col-lg-2">
          <button class="btn btn-primary w-100" type="submit">Import site</button>
        </div>
      </div>
    </form>
  </div>
</div>
HTML
}

advanced_nginx_panel() {
  local host="$1" current baseline generated_diff conflict effective manual_diff status
  current="$(site_nginx_file "$host")"
  baseline="$(site_nginx_baseline "$host")"
  generated_diff="$(site_nginx_diff "$host")"
  conflict="$(site_nginx_conflict "$host")"

  effective=""
  [[ -f "$current" ]] && effective="$(cat "$current")"

  manual_diff=""
  if [[ -s "$baseline" && -s "$current" ]] && ! cmp -s "$baseline" "$current"; then
    manual_diff="$(diff -u --label 'generated baseline' --label 'effective config' "$baseline" "$current" || true)"
    status="Customized"
  else
    status="Generated"
  fi

  cat <<HTML
<div class="card shadow-sm mb-4">
  <div class="card-header d-flex justify-content-between align-items-center">
    <strong>Advanced NGINX</strong>
    <span class="badge $([[ "$status" == Customized ]] && echo text-bg-warning || echo 'text-bg-light border')">$(html_escape "$status")</span>
  </div>
  <div class="card-body">
    <p class="text-secondary">Edit this site's effective NGINX configuration for settings not exposed elsewhere in the UI. LiteEdge preserves your delta across future UI changes and certificate updates with a three-way merge.</p>
HTML

  if ! command -v diff3 >/dev/null 2>&1 || ! command -v patch >/dev/null 2>&1; then
    echo '<div class="alert alert-warning">Manual edits can be saved now, but automatic delta merging requires the Alpine <code>diffutils</code> and <code>patch</code> packages.</div>'
  fi

  if [[ -s "$conflict" ]]; then
    cat <<HTML
    <div class="alert alert-danger">
      <strong>Merge conflict detected.</strong> A newly generated configuration overlapped a manual edit. The previous active configuration was left in place.
    </div>
    <details class="mb-3">
      <summary class="fw-semibold">Show merge conflict</summary>
      <pre class="small bg-dark text-light border rounded p-3 mt-2 overflow-auto" style="max-height: 24rem;">$(html_escape "$(cat "$conflict")")</pre>
    </details>
HTML
  fi

  if [[ -n "$manual_diff" ]]; then
    cat <<HTML
    <details class="mb-3">
      <summary class="fw-semibold">Manual delta</summary>
      <pre class="small bg-body-tertiary border rounded p-3 mt-2 overflow-auto" style="max-height: 24rem;">$(html_escape "$manual_diff")</pre>
    </details>
HTML
  fi

  if [[ -s "$generated_diff" ]]; then
    cat <<HTML
    <details class="mb-3">
      <summary class="fw-semibold">Last generated change</summary>
      <div class="form-text mb-2">This is the generated baseline delta from the last successful regeneration, such as adding TLS settings after a certificate is issued.</div>
      <pre class="small bg-body-tertiary border rounded p-3 mt-2 overflow-auto" style="max-height: 24rem;">$(html_escape "$(cat "$generated_diff")")</pre>
    </details>
HTML
  fi

  cat <<HTML
    <details>
      <summary class="fw-semibold">Edit effective configuration</summary>
      <form method="post" action="/admin/config/save" class="mt-3">
        <input type="hidden" name="host" value="$(html_escape "$host")">
        <label class="form-label">Effective site configuration</label>
        <textarea class="form-control font-monospace" name="config" rows="26" spellcheck="false" required>$(html_escape "$effective")</textarea>
        <div class="form-text">Save validates the complete NGINX configuration before reload. Invalid edits are rolled back automatically.</div>
        <button class="btn btn-primary mt-3" type="submit">Validate &amp; save config</button>
      </form>
      <form method="post" action="/admin/config/reset" class="mt-2">
        <input type="hidden" name="host" value="$(html_escape "$host")">
        <button class="btn btn-outline-secondary" type="submit">Reset to generated</button>
      </form>
    </details>
  </div>
</div>
HTML
}

certificate_panel() {
  local host="$1" mode summary
  mode="$(cert_mode "$host")"
  summary="$(cert_summary "$host")"
  cat <<HTML
<div class="card shadow-sm mb-4">
  <div class="card-header d-flex justify-content-between">
    <strong>TLS certificate</strong>
    <span class="badge text-bg-light border">$(html_escape "$mode")</span>
  </div>
  <div class="card-body">
HTML
  if [[ -n "$summary" ]]; then
    echo "<pre class=\"small bg-body-tertiary border rounded p-3\">$(html_escape "$summary")</pre>"
  else
    echo '<p class="text-secondary">No host certificate is installed. HTTP works now; HTTPS becomes active after a certificate is added.</p>'
  fi

  cat <<HTML
    <div class="row g-3 mb-4">
      <div class="col-md-6">
        <form method="post" action="/admin/cert/selfsigned" class="border rounded p-3 h-100">
          <input type="hidden" name="host" value="$(html_escape "$host")">
          <h2 class="h6">Self-signed</h2>
          <p class="small text-secondary">Generate a local RSA certificate for the host and all aliases.</p>
          <button class="btn btn-outline-primary" type="submit">Generate self-signed</button>
        </form>
      </div>
      <div class="col-md-6">
        <form method="post" action="/admin/cert/letsencrypt" class="border rounded p-3 h-100">
          <input type="hidden" name="host" value="$(html_escape "$host")">
          <h2 class="h6">Let's Encrypt</h2>
          <p class="small text-secondary">Use shell-only ACME HTTP-01 issuance. DNS must resolve here and port 80 must be reachable.</p>
          <button class="btn btn-outline-success" type="submit">Issue / renew Let's Encrypt</button>
        </form>
      </div>
    </div>

    <form method="post" action="/admin/cert/import" class="border rounded p-3">
      <input type="hidden" name="host" value="$(html_escape "$host")">
      <h2 class="h6">Import PEM certificate</h2>
      <p class="small text-secondary">Paste a full chain and matching private key. The key pair is validated before activation.</p>
      <div class="row g-3">
        <div class="col-lg-6">
          <label class="form-label">Certificate / full chain</label>
          <textarea class="form-control font-monospace" name="certificate" rows="10" required></textarea>
        </div>
        <div class="col-lg-6">
          <label class="form-label">Private key</label>
          <textarea class="form-control font-monospace" name="private_key" rows="10" required></textarea>
        </div>
      </div>
      <button class="btn btn-outline-primary mt-3" type="submit">Import certificate</button>
    </form>
  </div>
</div>
HTML
}

handle_export() {
  local scope="${PARAM[scope]:-}" host="${PARAM[host]:-}" certificates tmp file filename slug
  certificates="$(bool_value "${PARAM[certificates]:-0}")"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  file="$tmp/bundle.tar.gz"

  case "$scope" in
    site)
      validate_host "$host" 2>/dev/null || error_page "Invalid site host."
      slug="$(slug_for_host "$host")"
      run_or_error /opt/liteedge/bin/bundlectl.sh export-site "$host" "$certificates" "$file"
      filename="liteedge-site-${slug}$([[ "$certificates" == 1 ]] && printf '%s' '-with-certs').tar.gz"
      ;;
    all)
      run_or_error /opt/liteedge/bin/bundlectl.sh export-all "$certificates" "$file"
      filename="liteedge-all-sites$([[ "$certificates" == 1 ]] && printf '%s' '-with-certs').tar.gz"
      ;;
    *) error_page "Invalid export scope." ;;
  esac

  printf 'Content-Type: application/gzip\r\n'
  printf 'Content-Disposition: attachment; filename="%s"\r\n' "$filename"
  printf 'Content-Length: %s\r\n' "$(wc -c < "$file" | tr -d ' ')"
  printf 'Cache-Control: no-store\r\n'
  printf 'X-Content-Type-Options: nosniff\r\n\r\n'
  cat "$file"
  rm -rf "$tmp"
  trap - EXIT
  exit 0
}

handle_raw_import() {
  local scope="${PARAM[scope]:-}" host="${PARAM[host]:-}" certificates length tmp output size
  [[ "${REQUEST_METHOD:-GET}" == POST ]] || {
    printf 'Status: 405 Method Not Allowed\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nPOST required.\n'
    exit 0
  }

  certificates="$(bool_value "${PARAM[certificates]:-0}")"
  [[ "$scope" == site || "$scope" == all ]] || {
    printf 'Status: 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nInvalid import scope.\n'
    exit 0
  }
  if [[ "$scope" == site && -n "$host" ]]; then
    validate_host "$host" 2>/dev/null || {
      printf 'Status: 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nInvalid site host.\n'
      exit 0
    }
  elif [[ "$scope" == all ]]; then
    host=""
  fi

  length="${CONTENT_LENGTH:-0}"
  [[ "$length" =~ ^[0-9]+$ ]] || length=0
  if (( length < 1 || length > 33554432 )); then
    printf 'Status: 413 Payload Too Large\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nBundle must be between 1 byte and 32 MiB.\n'
    exit 0
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  head -c "$length" > "$tmp/bundle.tar.gz"
  size="$(wc -c < "$tmp/bundle.tar.gz" | tr -d ' ')"
  if [[ "$size" != "$length" ]]; then
    printf 'Status: 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nUpload ended before the declared request length.\n'
    exit 0
  fi

  if ! output="$(/opt/liteedge/bin/bundlectl.sh import "$tmp/bundle.tar.gz" "$certificates" "$scope" "$host" 2>&1)"; then
    printf 'Status: 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
    printf '%s\n' "$output"
    exit 0
  fi

  printf 'Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
  printf '%s\n' "$output"
  rm -rf "$tmp"
  trap - EXIT
  exit 0
}

handle_post() {
  local path="$1" host output tmpdir
  [[ "${REQUEST_METHOD:-GET}" == POST ]] || error_page "This action requires POST."

  case "$path" in
    /admin/site/save)
      host="${PARAM[host]:-}"
      run_or_error /opt/liteedge/bin/sitectl.sh save \
        "$host" \
        "${PARAM[mode]:-proxy}" \
        "${PARAM[upstream]:-}" \
        "${PARAM[root]:-}" \
        "${PARAM[aliases]:-}" \
        "${PARAM[force_https]:-0}" \
        "${PARAM[waf]:-0}" \
        "${PARAM[websocket]:-0}"
      redirect "/admin/site?host=$host"
      ;;

    /admin/site/delete)
      host="${PARAM[host]:-}"
      run_or_error /opt/liteedge/bin/sitectl.sh delete "$host"
      redirect "/"
      ;;

    /admin/route/add)
      host="${PARAM[host]:-}"
      run_or_error /opt/liteedge/bin/sitectl.sh route-add \
        "$host" \
        "${PARAM[match]:-prefix}" \
        "${PARAM[path]:-/}" \
        "${PARAM[target]:-}" \
        "${PARAM[websocket]:-0}"
      redirect "/admin/site?host=$host"
      ;;

    /admin/route/delete)
      host="${PARAM[host]:-}"
      run_or_error /opt/liteedge/bin/sitectl.sh route-delete "$host" "${PARAM[id]:-}"
      redirect "/admin/site?host=$host"
      ;;

    /admin/cert/selfsigned)
      host="${PARAM[host]:-}"
      run_or_error /opt/liteedge/bin/certctl.sh selfsigned "$host"
      redirect "/admin/site?host=$host"
      ;;

    /admin/cert/letsencrypt)
      host="${PARAM[host]:-}"
      run_or_error /opt/liteedge/bin/certctl.sh letsencrypt "$host"
      redirect "/admin/site?host=$host"
      ;;

    /admin/cert/import)
      host="${PARAM[host]:-}"
      tmpdir="$(mktemp -d)"
      trap 'rm -rf "$tmpdir"' EXIT
      printf '%s\n' "${PARAM[certificate]:-}" > "$tmpdir/fullchain.pem"
      printf '%s\n' "${PARAM[private_key]:-}" > "$tmpdir/privkey.pem"
      run_or_error /opt/liteedge/bin/certctl.sh import "$host" "$tmpdir/fullchain.pem" "$tmpdir/privkey.pem"
      rm -rf "$tmpdir"
      trap - EXIT
      redirect "/admin/site?host=$host"
      ;;

    /admin/waf/disable)
      host="${PARAM[host]:-}"
      run_or_error /opt/liteedge/bin/sitectl.sh waf-disable "$host" "${PARAM[rule_id]:-}"
      redirect "/admin/site?host=$host"
      ;;

    /admin/waf/enable)
      host="${PARAM[host]:-}"
      run_or_error /opt/liteedge/bin/sitectl.sh waf-enable "$host" "${PARAM[rule_id]:-}"
      redirect "/admin/site?host=$host"
      ;;

    /admin/config/save)
      host="${PARAM[host]:-}"
      tmpdir="$(mktemp -d)"
      trap 'rm -rf "$tmpdir"' EXIT
      printf '%s\n' "${PARAM[config]:-}" > "$tmpdir/site.conf"
      run_or_error /opt/liteedge/bin/sitectl.sh config-save "$host" "$tmpdir/site.conf"
      rm -rf "$tmpdir"
      trap - EXIT
      redirect "/admin/site?host=$host"
      ;;

    /admin/config/reset)
      host="${PARAM[host]:-}"
      run_or_error /opt/liteedge/bin/sitectl.sh config-reset "$host"
      redirect "/admin/site?host=$host"
      ;;

    *)
      error_page "Unknown action."
      ;;
  esac
}

path="${PATH_INFO:-/}"
parse_params "${QUERY_STRING:-}"

if [[ "$path" == /admin/export ]]; then
  handle_export
fi
if [[ "$path" == /admin/import ]]; then
  handle_raw_import
fi

if [[ "${REQUEST_METHOD:-GET}" == POST ]]; then
  length="${CONTENT_LENGTH:-0}"
  if [[ "$length" =~ ^[0-9]+$ ]] && (( length > 0 )); then
    body=""
    IFS= read -r -N "$length" body || true
    parse_params "$body"
  fi
fi

case "$path" in
  /|/admin|/admin/)
    dashboard
    ;;
  /admin/site)
    site_editor
    ;;
  /admin/site/save|/admin/site/delete|/admin/route/add|/admin/route/delete|/admin/cert/selfsigned|/admin/cert/letsencrypt|/admin/cert/import|/admin/waf/disable|/admin/waf/enable|/admin/config/save|/admin/config/reset)
    handle_post "$path"
    ;;
  *)
    page_head "Not found"
    echo '<div class="alert alert-warning">Page not found.</div>'
    echo '<a class="btn btn-secondary" href="/">Back</a>'
    page_tail
    ;;
esac
