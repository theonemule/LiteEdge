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
  local title path sites_active="" owasp_active="" server_active=""
  title="$(html_escape "${1:-LiteEdge}")"
  path="${PATH_INFO:-/}"
  case "$path" in
    /admin/owasp*) owasp_active=active ;;
    /admin/server*) server_active=active ;;
    *) sites_active=active ;;
  esac
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
  <style>
    dialog.liteedge-dialog { width:min(760px,calc(100vw - 2rem)); border:0; border-radius:.75rem; padding:0; box-shadow:0 1rem 3rem rgba(0,0,0,.25); }
    dialog.liteedge-dialog::backdrop { background:rgba(0,0,0,.45); }
    .sidebar-nav { min-height:calc(100vh - 56px); }
    .sidebar-nav .nav-link { color:var(--bs-body-color); border-radius:.375rem; }
    .sidebar-nav .nav-link.active { background:var(--bs-primary); color:#fff; }
  </style>
</head>
<body class="bg-body-tertiary">
<nav class="navbar bg-dark navbar-dark">
  <div class="container-fluid px-4">
    <a class="navbar-brand fw-semibold" href="/">LiteEdge</a>
    <span class="navbar-text">Lightweight NGINX control plane</span>
  </div>
</nav>
<div class="container-fluid"><div class="row">
<aside class="col-md-3 col-lg-2 bg-body border-end p-3 sidebar-nav">
  <nav class="nav nav-pills flex-column gap-1">
    <a class="nav-link $sites_active" href="/">Sites</a>
    <a class="nav-link $owasp_active" href="/admin/owasp">OWASP</a>
    <a class="nav-link $server_active" href="/admin/server">Server Settings</a>
  </nav>
</aside>
<main class="col-md-9 col-lg-10 px-md-4 py-4">
HTML
}

page_tail() {
  cat <<'HTML'
</main></div></div>
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
  <div><h1 class="h3 mb-1">Sites</h1><p class="text-secondary mb-0">Host names contain one or more reverse-proxy routes.</p></div>
  <div class="d-flex gap-2">
    <button class="btn btn-outline-secondary" type="button" data-dialog-open="importSitesDialog">Import</button>
    <button class="btn btn-outline-secondary" type="button" data-dialog-open="exportSitesDialog">Export</button>
    <a class="btn btn-primary" href="/admin/site">Add Site</a>
  </div>
</div>
<dialog class="liteedge-dialog" id="importSitesDialog">
  <div class="card border-0"><div class="card-header d-flex justify-content-between"><strong>Import LiteEdge configuration</strong><button class="btn-close" type="button" data-dialog-close></button></div><div class="card-body">
    <form class="bundle-import-form border rounded p-3" data-redirect="/">
      <h2 class="h6">Import bundle</h2>
      <p class="small text-secondary">Choose any LiteEdge site bundle. LiteEdge reads the bundle manifest and automatically detects whether it contains one site or the complete site set.</p>
      <input class="form-control mb-3" type="file" accept=".tar.gz,.tgz,application/gzip" required>
      <div class="form-check mb-3"><input class="form-check-input" type="checkbox" name="certificates" value="1" id="import_bundle_certs"><label class="form-check-label" for="import_bundle_certs">Import certificates and private keys when present</label></div>
      <button class="btn btn-primary" type="submit">Import bundle</button>
    </form>
  </div></div>
</dialog>
<dialog class="liteedge-dialog" id="exportSitesDialog">
  <div class="card border-0"><div class="card-header d-flex justify-content-between"><strong>Export LiteEdge configuration</strong><button class="btn-close" type="button" data-dialog-close></button></div><div class="card-body">
    <form method="get" action="/admin/export" class="border rounded p-3 mb-3">
      <input type="hidden" name="scope" value="site"><h2 class="h6">Export one site</h2><label class="form-label">Site</label><select class="form-select mb-3" name="host" required>
HTML
  shopt -s nullglob
  local file host aliases route_count tls
  local files=("$SITE_DIR"/*.site)
  for file in "${files[@]}"; do
    host="$(kv_get "$file" HOST)"
    echo "<option value=\"$(html_escape "$host")\">$(html_escape "$host")</option>"
  done
  cat <<'HTML'
      </select>
      <div class="form-check mb-3"><input class="form-check-input" type="checkbox" name="certificates" value="1" id="export_site_certs"><label class="form-check-label" for="export_site_certs">Include certificate and private key</label></div>
      <button class="btn btn-outline-primary" type="submit">Export site</button>
    </form>
    <div class="border rounded p-3"><h2 class="h6">Export all sites</h2><div class="d-flex gap-2"><a class="btn btn-outline-primary" href="/admin/export?scope=all&amp;certificates=0">Settings only</a><a class="btn btn-outline-warning" href="/admin/export?scope=all&amp;certificates=1">Settings + certificates</a></div></div>
  </div></div>
</dialog>
<div class="card shadow-sm"><div class="table-responsive"><table class="table table-hover align-middle mb-0">
<thead><tr><th>Host</th><th>Aliases</th><th>Routes</th><th>TLS</th><th class="text-end">Actions</th></tr></thead><tbody>
HTML
  if [[ ${#files[@]} -eq 0 ]]; then
    echo '<tr><td colspan="5" class="text-center text-secondary py-5">No sites configured yet.</td></tr>'
  else
    for file in "${files[@]}"; do
      host="$(kv_get "$file" HOST)"; aliases="$(kv_get "$file" ALIASES)"
      route_count="$(find "$(route_dir "$host")" -maxdepth 1 -type f -name '*.route' 2>/dev/null | wc -l | tr -d ' ')"
      if [[ "$route_count" == 0 && -n "$(kv_get "$file" UPSTREAM)" ]]; then route_count=1; fi
      tls="$(cert_mode "$host")"
      cat <<HTML
<tr><td><a class="fw-semibold text-decoration-none" href="/admin/site?host=$(html_escape "$host")">$(html_escape "$host")</a></td><td>$(html_escape "${aliases:-—}")</td><td><span class="badge text-bg-light border">$route_count</span></td><td><span class="badge text-bg-light border">$(html_escape "$tls")</span></td><td class="text-end"><a class="btn btn-sm btn-outline-primary" href="/admin/site?host=$(html_escape "$host")">Manage</a> <form class="d-inline" method="post" action="/admin/site/delete"><input type="hidden" name="host" value="$(html_escape "$host")"><button class="btn btn-sm btn-outline-danger" type="submit">Delete</button></form></td></tr>
HTML
    done
  fi
  echo '</tbody></table></div></div>'
  page_tail
}

site_editor() {
  local host="${PARAM[host]:-}" exists=0 file aliases=""
  if [[ -n "$host" ]]; then
    validate_host "$host" 2>/dev/null || error_page "Invalid host."
    file="$(site_file "$host")"
    if [[ -f "$file" ]]; then exists=1; aliases="$(kv_get "$file" ALIASES)"; fi
  fi
  page_head "$([[ "$exists" == 1 ]] && echo "Manage $host" || echo "Add site")"
  cat <<HTML
<div class="d-flex justify-content-between align-items-center mb-3">
  <div><h1 class="h3 mb-1">$([[ "$exists" == 1 ]] && printf '%s' "$(html_escape "$host")" || echo "Add site")</h1><p class="text-secondary mb-0">A site defines host names. Reverse-proxy behavior belongs to routes.</p></div>
  <a class="btn btn-outline-secondary" href="/">Back to sites</a>
</div>
<form method="post" action="/admin/site/save" class="card shadow-sm mb-4"><div class="card-body"><div class="row g-3">
<div class="col-md-6"><label class="form-label">Host name</label><input class="form-control" name="host" value="$(html_escape "$host")" placeholder="app.example.com" $([[ "$exists" == 1 ]] && echo readonly) required></div>
<div class="col-md-6"><label class="form-label">Aliases</label><input class="form-control" name="aliases" value="$(html_escape "$aliases")" placeholder="www.example.com api.example.com"><div class="form-text">Space- or comma-separated DNS names.</div></div>
</div></div><div class="card-footer text-end"><button class="btn btn-primary" type="submit">Save site</button></div></form>
HTML
  if [[ "$exists" == 1 ]]; then
    routes_panel "$host"
    certificate_panel "$host"
    advanced_nginx_panel "$host"
  else
    echo '<div class="alert alert-info">Save the host first, then add one or more reverse-proxy routes.</div>'
  fi
  page_tail
}

routes_panel() {
  local host="$1" dir route id match path target websocket timeout waf force_https profile default_timeout
  dir="$(route_dir "$host")"; default_timeout="$(server_setting_get DEFAULT_ROUTE_TIMEOUT 60)"
  cat <<HTML
<div class="card shadow-sm mb-4"><div class="card-header d-flex justify-content-between"><strong>Routes</strong><span class="text-secondary small">Each route is an independent reverse proxy.</span></div><div class="card-body">
HTML
  shopt -s nullglob
  local routes=("$dir"/*.route)
  if [[ ${#routes[@]} -eq 0 ]]; then
    echo '<p class="text-secondary">No routes configured. Add a <code>/</code> route for the default backend.</p>'
  else
    for route in "${routes[@]}"; do
      id="$(kv_get "$route" ID)"; match="$(kv_get "$route" MATCH)"; path="$(kv_get "$route" PATH)"; target="$(kv_get "$route" TARGET)"
      websocket="$(kv_get "$route" WEBSOCKET)"; [[ "$websocket" =~ ^[01]$ ]] || websocket=1
      timeout="$(kv_get "$route" TIMEOUT)"; [[ -n "$timeout" ]] || timeout="$default_timeout"
      waf="$(kv_get "$route" WAF)"; [[ "$waf" =~ ^[01]$ ]] || waf=1
      force_https="$(kv_get "$route" FORCE_HTTPS)"; [[ "$force_https" =~ ^[01]$ ]] || force_https=1
      profile="$(kv_get "$route" PROFILE)"; [[ -n "$profile" ]] || profile=generic
      cat <<HTML
<details class="border rounded p-3 mb-3">
<summary class="d-flex flex-wrap gap-2 align-items-center"><code>$(html_escape "$path")</code><span class="text-secondary">→</span><code>$(html_escape "$target")</code><span class="badge text-bg-light border">$(html_escape "$match")</span>$([[ "$waf" == 1 ]] && echo '<span class="badge text-bg-success">OWASP</span>')$([[ "$websocket" == 1 ]] && echo '<span class="badge text-bg-info">WebSocket</span>')$([[ "$force_https" == 1 ]] && echo '<span class="badge text-bg-secondary">HTTPS redirect</span>')</summary>
<form method="post" action="/admin/route/save" class="mt-3"><input type="hidden" name="host" value="$(html_escape "$host")"><input type="hidden" name="id" value="$(html_escape "$id")"><div class="row g-3">
<div class="col-md-2"><label class="form-label">Match</label><select class="form-select" name="match"><option value="prefix" $(selected "$match" prefix)>Prefix</option><option value="exact" $(selected "$match" exact)>Exact</option><option value="regex" $(selected "$match" regex)>Regex</option></select></div>
<div class="col-md-3"><label class="form-label">Path / pattern</label><input class="form-control font-monospace" name="path" value="$(html_escape "$path")" required></div>
<div class="col-md-5"><label class="form-label">Reverse proxy target</label><input class="form-control font-monospace" name="target" value="$(html_escape "$target")" required></div>
<div class="col-md-2"><label class="form-label">Timeout (seconds)</label><input class="form-control" type="number" min="1" max="86400" name="timeout" value="$(html_escape "$timeout")" required></div>
<div class="col-md-4"><label class="form-label">OWASP application profile</label><select class="form-select" name="profile"><option value="generic" $(selected "$profile" generic)>Generic CRS</option><option value="wordpress" $(selected "$profile" wordpress)>WordPress exclusions</option></select></div>
<div class="col-md-8 d-flex flex-wrap gap-4 align-items-end">
<div class="form-check form-switch"><input class="form-check-input" type="checkbox" name="websocket" value="1" id="ws_$id" $(checkbox "$websocket")><label class="form-check-label" for="ws_$id">WebSocket upgrade</label></div>
<div class="form-check form-switch"><input class="form-check-input" type="checkbox" name="waf" value="1" id="waf_$id" $(checkbox "$waf")><label class="form-check-label" for="waf_$id">OWASP CRS</label></div>
<div class="form-check form-switch"><input class="form-check-input" type="checkbox" name="force_https" value="1" id="https_$id" $(checkbox "$force_https")><label class="form-check-label" for="https_$id">HTTP → HTTPS</label></div>
</div></div><button class="btn btn-sm btn-primary mt-3" type="submit">Save route</button></form>
<form method="post" action="/admin/route/delete" class="mt-2"><input type="hidden" name="host" value="$(html_escape "$host")"><input type="hidden" name="id" value="$(html_escape "$id")"><button class="btn btn-sm btn-outline-danger" type="submit">Delete route</button></form>
</details>
HTML
    done
  fi
  cat <<HTML
<hr class="my-4"><h2 class="h6">Add route</h2>
<form method="post" action="/admin/route/add"><input type="hidden" name="host" value="$(html_escape "$host")"><div class="row g-3">
<div class="col-md-2"><label class="form-label">Match</label><select class="form-select" name="match"><option value="prefix">Prefix</option><option value="exact">Exact</option><option value="regex">Regex</option></select></div>
<div class="col-md-3"><label class="form-label">Path / pattern</label><input class="form-control font-monospace" name="path" value="/" required></div>
<div class="col-md-5"><label class="form-label">Reverse proxy target</label><input class="form-control font-monospace" name="target" placeholder="http://app:8080" required></div>
<div class="col-md-2"><label class="form-label">Timeout (seconds)</label><input class="form-control" type="number" min="1" max="86400" name="timeout" value="$(html_escape "$default_timeout")" required></div>
<div class="col-md-4"><label class="form-label">OWASP application profile</label><select class="form-select" name="profile"><option value="generic">Generic CRS</option><option value="wordpress">WordPress exclusions</option></select></div>
<div class="col-md-8 d-flex flex-wrap gap-4 align-items-end">
<div class="form-check form-switch"><input class="form-check-input" type="checkbox" name="websocket" value="1" id="new_ws" checked><label class="form-check-label" for="new_ws">WebSocket upgrade</label></div>
<div class="form-check form-switch"><input class="form-check-input" type="checkbox" name="waf" value="1" id="new_waf" checked><label class="form-check-label" for="new_waf">OWASP CRS</label></div>
<div class="form-check form-switch"><input class="form-check-input" type="checkbox" name="force_https" value="1" id="new_https" checked><label class="form-check-label" for="new_https">HTTP → HTTPS</label></div>
</div></div><button class="btn btn-outline-primary mt-3" type="submit">Add route</button></form>
</div></div>
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

owasp_page() {
  local pl disabled rule_id file name id state text
  pl="$(waf_setting_get PARANOIA_LEVEL 1)"
  page_head "OWASP"
  cat <<HTML
<div class="d-flex justify-content-between align-items-center mb-4">
  <div><h1 class="h3 mb-1">OWASP</h1><p class="text-secondary mb-0">CRS is the foundation. Plugins, application profiles, and custom rules layer around it.</p></div>
  <div class="d-flex gap-2"><a class="btn btn-outline-secondary" href="/admin/owasp/export">Export rules</a><button class="btn btn-outline-secondary" type="button" data-dialog-open="wafImportDialog">Import rules</button></div>
</div>
<dialog class="liteedge-dialog" id="wafImportDialog"><div class="card border-0"><div class="card-header d-flex justify-content-between"><strong>Import OWASP configuration</strong><button class="btn-close" type="button" data-dialog-close></button></div><div class="card-body"><form class="waf-import-form" data-redirect="/admin/owasp"><input class="form-control mb-3" type="file" accept=".tar.gz,.tgz,application/gzip" required><button class="btn btn-primary" type="submit">Import rules</button></form></div></div></dialog>

<div class="row g-4 mb-4">
<div class="col-xl-5"><div class="card shadow-sm h-100"><div class="card-header d-flex justify-content-between"><strong>Core Rule Set</strong><span class="badge text-bg-success">Enabled</span></div><div class="card-body"><h2 class="h5">OWASP CRS 4.x</h2><p class="text-secondary">CRS is LiteEdge's default general-purpose ruleset. A second full ruleset is not stacked on top automatically.</p><div class="small text-secondary">Bundled: CRS 4.29.0</div></div></div></div>
<div class="col-xl-7"><div class="card shadow-sm h-100"><div class="card-header"><strong>Protection level</strong></div><div class="card-body"><form method="post" action="/admin/owasp/pl"><div class="row g-2">
<div class="col-6 col-lg-3"><input class="btn-check" type="radio" name="pl" value="1" id="pl1" $([[ "$pl" == 1 ]] && echo checked)><label class="btn btn-outline-primary w-100" for="pl1"><b>PL1</b><br><small>Normal</small></label></div>
<div class="col-6 col-lg-3"><input class="btn-check" type="radio" name="pl" value="2" id="pl2" $([[ "$pl" == 2 ]] && echo checked)><label class="btn btn-outline-primary w-100" for="pl2"><b>PL2</b><br><small>Enhanced</small></label></div>
<div class="col-6 col-lg-3"><input class="btn-check" type="radio" name="pl" value="3" id="pl3" $([[ "$pl" == 3 ]] && echo checked)><label class="btn btn-outline-primary w-100" for="pl3"><b>PL3</b><br><small>High</small></label></div>
<div class="col-6 col-lg-3"><input class="btn-check" type="radio" name="pl" value="4" id="pl4" $([[ "$pl" == 4 ]] && echo checked)><label class="btn btn-outline-primary w-100" for="pl4"><b>PL4</b><br><small>Extreme</small></label></div>
</div><button class="btn btn-primary mt-3" type="submit">Apply level</button></form></div></div></div>
</div>

<div class="card shadow-sm mb-4"><div class="card-header"><strong>Optional CRS Plugins</strong></div><div class="table-responsive"><table class="table align-middle mb-0"><thead><tr><th>Plugin</th><th>Status</th><th class="text-end">Bundle</th></tr></thead><tbody>
<tr><td>Fake Bot Protection</td><td><span class="badge text-bg-warning">Requires Lua</span></td><td class="text-end"><a class="btn btn-sm btn-outline-primary" href="https://github.com/coreruleset/fake-bot-plugin/archive/refs/heads/main.tar.gz">Download</a></td></tr>
<tr><td>Referer Hardening</td><td><span class="badge text-bg-light border">Official / tested</span></td><td class="text-end"><a class="btn btn-sm btn-outline-primary" href="https://github.com/coreruleset/referer-hardening-plugin/archive/refs/heads/main.tar.gz">Download</a></td></tr>
<tr><td>Auto-Decoding</td><td><span class="badge text-bg-light border">Official / untested</span></td><td class="text-end"><a class="btn btn-sm btn-outline-primary" href="https://github.com/coreruleset/auto-decoding-plugin/archive/refs/heads/main.tar.gz">Download</a></td></tr>
<tr><td>DoS Protection</td><td><span class="badge text-bg-light border">Official / untested</span></td><td class="text-end"><a class="btn btn-sm btn-outline-primary" href="https://github.com/coreruleset/dos-protection-plugin-modsecurity/archive/refs/heads/main.tar.gz">Download</a></td></tr>
<tr><td>Antivirus Integration</td><td><span class="badge text-bg-warning">Requires Lua + AV</span></td><td class="text-end"><a class="btn btn-sm btn-outline-primary" href="https://github.com/coreruleset/antivirus-plugin/archive/refs/heads/main.tar.gz">Download</a></td></tr>
<tr><td>Body Decompression</td><td><span class="badge text-bg-warning">Requires Lua</span></td><td class="text-end"><a class="btn btn-sm btn-outline-primary" href="https://github.com/coreruleset/body-decompress-plugin/archive/refs/heads/main.tar.gz">Download</a></td></tr>
</tbody></table></div><div class="card-footer small text-secondary">Downloads come from the CRS plugin repositories. This LiteEdge build does not include Lua, so Lua-dependent plugins are shown but are not enableable here.</div></div>

<div class="card shadow-sm mb-4"><div class="card-header"><strong>Application Profiles</strong></div><div class="card-body"><p class="text-secondary">Profiles are selected per route. Source bundles can be downloaded directly from their CRS registry repositories.</p><div class="row g-3">
<div class="col-md-6 col-xl"><div class="border rounded p-3 h-100"><b>WordPress</b><div class="mt-2"><span class="badge text-bg-success">LiteEdge profile</span></div><a class="btn btn-sm btn-outline-primary mt-3" href="https://github.com/coreruleset/wordpress-rule-exclusions-plugin/archive/refs/heads/main.tar.gz">Download bundle</a></div></div>
<div class="col-md-6 col-xl"><div class="border rounded p-3 h-100"><b>Nextcloud</b><div class="mt-2"><span class="badge text-bg-light border">Not bundled</span></div><a class="btn btn-sm btn-outline-primary mt-3" href="https://github.com/coreruleset/nextcloud-rule-exclusions-plugin/archive/refs/heads/main.tar.gz">Download bundle</a></div></div>
<div class="col-md-6 col-xl"><div class="border rounded p-3 h-100"><b>Drupal</b><div class="mt-2"><span class="badge text-bg-light border">Not bundled</span></div><a class="btn btn-sm btn-outline-primary mt-3" href="https://github.com/coreruleset/drupal-rule-exclusions-plugin/archive/refs/heads/main.tar.gz">Download bundle</a></div></div>
<div class="col-md-6 col-xl"><div class="border rounded p-3 h-100"><b>phpMyAdmin</b><div class="mt-2"><span class="badge text-bg-light border">Not bundled</span></div><a class="btn btn-sm btn-outline-primary mt-3" href="https://github.com/coreruleset/phpmyadmin-rule-exclusions-plugin/archive/refs/heads/main.tar.gz">Download bundle</a></div></div>
<div class="col-md-6 col-xl"><div class="border rounded p-3 h-100"><b>Roundcube</b><div class="mt-2"><span class="badge text-bg-light border">3rd party / tested</span></div><a class="btn btn-sm btn-outline-primary mt-3" href="https://github.com/EsadCetiner/roundcube-rule-exclusions-plugin/archive/refs/heads/main.tar.gz">Download bundle</a></div></div>
</div></div></div>

<div class="card shadow-sm mb-4"><div class="card-header"><strong>Globally disabled CRS rules</strong></div><div class="card-body">
HTML
  disabled="$(global_disabled_waf_rules)"
  if [[ -z "$disabled" ]]; then
    echo '<p class="text-secondary">No core CRS rule IDs are globally disabled.</p>'
  else
    echo '<div class="d-flex flex-wrap gap-2 mb-3">'
    while IFS= read -r rule_id; do
      [[ -n "$rule_id" ]] || continue
      echo "<form method=\"post\" action=\"/admin/owasp/rule/enable\" class=\"border rounded p-2\"><input type=\"hidden\" name=\"rule_id\" value=\"$(html_escape "$rule_id")\"><code>$(html_escape "$rule_id")</code> <button class=\"btn btn-sm btn-outline-success\" type=\"submit\">Enable</button></form>"
    done <<< "$disabled"
    echo '</div>'
  fi
  cat <<'HTML'
<form method="post" action="/admin/owasp/rule/disable" class="row g-2 align-items-end"><div class="col-sm-4"><label class="form-label">CRS rule ID</label><input class="form-control font-monospace" name="rule_id" pattern="[0-9]{1,9}" required></div><div class="col-auto"><button class="btn btn-outline-danger" type="submit">Disable globally</button></div></form>
</div></div>

<div class="card shadow-sm"><div class="card-header"><strong>Custom Rules</strong></div><div class="card-body">
HTML
  shopt -s nullglob
  local files=("$WAF_CUSTOM_DIR"/*.conf "$WAF_CUSTOM_DIR"/*.conf.disabled)
  if [[ ${#files[@]} -eq 0 ]]; then echo '<p class="text-secondary">No custom rules.</p>'; fi
  for file in "${files[@]}"; do
    name="$(basename "$file")"; id="${name%%.conf*}"; state=enabled; [[ "$name" == *.disabled ]] && state=disabled; text="$(cat "$file")"
    cat <<HTML
<details class="border rounded p-3 mb-3"><summary><code>$(html_escape "$id")</code> <span class="badge $([[ "$state" == enabled ]] && echo text-bg-success || echo text-bg-secondary)">$(html_escape "$state")</span></summary>
<form method="post" action="/admin/owasp/custom/save" class="mt-3"><input type="hidden" name="rule_id" value="$(html_escape "$id")"><textarea class="form-control font-monospace" name="rule_text" rows="5" required>$(html_escape "$text")</textarea><button class="btn btn-sm btn-primary mt-2" type="submit">Save</button></form>
<div class="d-flex gap-2 mt-2">
HTML
    if [[ "$state" == enabled ]]; then
      echo "<form method=\"post\" action=\"/admin/owasp/custom/disable\"><input type=\"hidden\" name=\"rule_id\" value=\"$(html_escape "$id")\"><button class=\"btn btn-sm btn-outline-secondary\">Disable</button></form>"
    else
      echo "<form method=\"post\" action=\"/admin/owasp/custom/enable\"><input type=\"hidden\" name=\"rule_id\" value=\"$(html_escape "$id")\"><button class=\"btn btn-sm btn-outline-success\">Enable</button></form>"
    fi
    echo "<form method=\"post\" action=\"/admin/owasp/custom/delete\"><input type=\"hidden\" name=\"rule_id\" value=\"$(html_escape "$id")\"><button class=\"btn btn-sm btn-outline-danger\">Delete</button></form></div></details>"
  done
  cat <<'HTML'
<hr><h2 class="h6">Add custom rule</h2><form method="post" action="/admin/owasp/custom/save"><div class="row g-3"><div class="col-md-3"><label class="form-label">Rule ID</label><input class="form-control font-monospace" name="rule_id" pattern="[0-9]{1,9}" required></div><div class="col-md-9"><label class="form-label">ModSecurity rule</label><textarea class="form-control font-monospace" name="rule_text" rows="5" required></textarea></div></div><button class="btn btn-primary mt-3">Add custom rule</button></form>
</div></div>
HTML
  page_tail
}

server_page() {
  local worker keepalive header body send route resolver
  worker="$(server_setting_get WORKER_CONNECTIONS 1024)"; keepalive="$(server_setting_get KEEPALIVE_TIMEOUT 65)"
  header="$(server_setting_get CLIENT_HEADER_TIMEOUT 15)"; body="$(server_setting_get CLIENT_BODY_TIMEOUT 15)"
  send="$(server_setting_get SEND_TIMEOUT 30)"; route="$(server_setting_get DEFAULT_ROUTE_TIMEOUT 60)"; resolver="$(server_setting_get RESOLVER "")"
  page_head "Server Settings"
  cat <<HTML
<div class="mb-4"><h1 class="h3 mb-1">Server Settings</h1><p class="text-secondary mb-0">Global NGINX runtime defaults.</p></div>
<form method="post" action="/admin/server/save" class="card shadow-sm"><div class="card-header"><strong>NGINX defaults</strong></div><div class="card-body"><div class="row g-3">
<div class="col-md-4"><label class="form-label">Worker connections</label><input class="form-control" type="number" name="worker_connections" value="$(html_escape "$worker")" required></div>
<div class="col-md-4"><label class="form-label">Keepalive timeout</label><input class="form-control" type="number" name="keepalive_timeout" value="$(html_escape "$keepalive")" required></div>
<div class="col-md-4"><label class="form-label">Default route timeout</label><input class="form-control" type="number" name="route_timeout" value="$(html_escape "$route")" required></div>
<div class="col-md-4"><label class="form-label">Client header timeout</label><input class="form-control" type="number" name="header_timeout" value="$(html_escape "$header")" required></div>
<div class="col-md-4"><label class="form-label">Client body timeout</label><input class="form-control" type="number" name="body_timeout" value="$(html_escape "$body")" required></div>
<div class="col-md-4"><label class="form-label">Send timeout</label><input class="form-control" type="number" name="send_timeout" value="$(html_escape "$send")" required></div>
<div class="col-md-6"><label class="form-label">DNS resolver</label><input class="form-control font-monospace" name="resolver" value="$(html_escape "$resolver")" placeholder="Automatic from /etc/resolv.conf"><div class="form-text">Leave blank for automatic detection.</div></div>
</div></div><div class="card-footer text-end"><button class="btn btn-primary">Save server settings</button></div></form>
HTML
  page_tail
}

handle_owasp_export() {
  local tmp file
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  file="$tmp/liteedge-owasp.tar.gz"
  run_or_error /opt/liteedge/bin/wafctl.sh export "$file"
  printf 'Content-Type: application/gzip\r\n'
  printf 'Content-Disposition: attachment; filename="liteedge-owasp-rules.tar.gz"\r\n'
  printf 'Content-Length: %s\r\n' "$(wc -c < "$file" | tr -d ' ')"
  printf 'Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n'
  cat "$file"; rm -rf "$tmp"; trap - EXIT; exit 0
}

handle_owasp_raw_import() {
  local length tmp output size
  [[ "${REQUEST_METHOD:-GET}" == POST ]] || { printf 'Status: 405 Method Not Allowed\r\nContent-Type: text/plain\r\n\r\nPOST required.\n'; exit 0; }
  length="${CONTENT_LENGTH:-0}"; [[ "$length" =~ ^[0-9]+$ ]] || length=0
  if (( length < 1 || length > 8388608 )); then printf 'Status: 413 Payload Too Large\r\nContent-Type: text/plain\r\n\r\nRules bundle must be between 1 byte and 8 MiB.\n'; exit 0; fi
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  head -c "$length" > "$tmp/rules.tar.gz"
  size="$(wc -c < "$tmp/rules.tar.gz" | tr -d ' ')"
  [[ "$size" == "$length" ]] || { printf 'Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nIncomplete upload.\n'; exit 0; }
  if ! output="$(/opt/liteedge/bin/wafctl.sh import "$tmp/rules.tar.gz" 2>&1)"; then
    printf 'Status: 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n%s\n' "$output"; exit 0
  fi
  printf 'Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\nOWASP rules imported.\n'
  rm -rf "$tmp"; trap - EXIT; exit 0
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
  local certificates length tmp output size
  [[ "${REQUEST_METHOD:-GET}" == POST ]] || {
    printf 'Status: 405 Method Not Allowed\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nPOST required.\n'
    exit 0
  }

  certificates="$(bool_value "${PARAM[certificates]:-0}")"
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

  # Scope and site identity come from the signed-off LiteEdge bundle manifest.
  # Empty expected-scope/host values intentionally enable auto-detection.
  if ! output="$(/opt/liteedge/bin/bundlectl.sh import "$tmp/bundle.tar.gz" "$certificates" "" "" 2>&1)"; then
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
      run_or_error /opt/liteedge/bin/sitectl.sh save "$host" "${PARAM[aliases]:-}"
      redirect "/admin/site?host=$host"
      ;;

    /admin/site/delete)
      host="${PARAM[host]:-}"
      run_or_error /opt/liteedge/bin/sitectl.sh delete "$host"
      redirect "/"
      ;;

    /admin/route/add)
      host="${PARAM[host]:-}"
      run_or_error /opt/liteedge/bin/sitectl.sh route-add "$host" "${PARAM[match]:-prefix}" "${PARAM[path]:-/}" "${PARAM[target]:-}" "${PARAM[websocket]:-0}" "${PARAM[timeout]:-60}" "${PARAM[waf]:-0}" "${PARAM[force_https]:-0}" "${PARAM[profile]:-generic}"
      redirect "/admin/site?host=$host"
      ;;

    /admin/route/save)
      host="${PARAM[host]:-}"
      run_or_error /opt/liteedge/bin/sitectl.sh route-save "${PARAM[id]:-}" "$host" "${PARAM[match]:-prefix}" "${PARAM[path]:-/}" "${PARAM[target]:-}" "${PARAM[websocket]:-0}" "${PARAM[timeout]:-60}" "${PARAM[waf]:-0}" "${PARAM[force_https]:-0}" "${PARAM[profile]:-generic}"
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

    /admin/owasp/pl)
      run_or_error /opt/liteedge/bin/wafctl.sh set-pl "${PARAM[pl]:-1}"
      redirect "/admin/owasp"
      ;;
    /admin/owasp/rule/disable)
      run_or_error /opt/liteedge/bin/wafctl.sh disable "${PARAM[rule_id]:-}"
      redirect "/admin/owasp"
      ;;
    /admin/owasp/rule/enable)
      run_or_error /opt/liteedge/bin/wafctl.sh enable "${PARAM[rule_id]:-}"
      redirect "/admin/owasp"
      ;;
    /admin/owasp/custom/save)
      tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT
      printf '%s\n' "${PARAM[rule_text]:-}" > "$tmpdir/custom.conf"
      run_or_error /opt/liteedge/bin/wafctl.sh custom-save "${PARAM[rule_id]:-}" "$tmpdir/custom.conf"
      rm -rf "$tmpdir"; trap - EXIT
      redirect "/admin/owasp"
      ;;
    /admin/owasp/custom/disable)
      run_or_error /opt/liteedge/bin/wafctl.sh custom-disable "${PARAM[rule_id]:-}"
      redirect "/admin/owasp"
      ;;
    /admin/owasp/custom/enable)
      run_or_error /opt/liteedge/bin/wafctl.sh custom-enable "${PARAM[rule_id]:-}"
      redirect "/admin/owasp"
      ;;
    /admin/owasp/custom/delete)
      run_or_error /opt/liteedge/bin/wafctl.sh custom-delete "${PARAM[rule_id]:-}"
      redirect "/admin/owasp"
      ;;
    /admin/server/save)
      run_or_error /opt/liteedge/bin/serverctl.sh save "${PARAM[worker_connections]:-1024}" "${PARAM[keepalive_timeout]:-65}" "${PARAM[header_timeout]:-15}" "${PARAM[body_timeout]:-15}" "${PARAM[send_timeout]:-30}" "${PARAM[route_timeout]:-60}" "${PARAM[resolver]:-}"
      redirect "/admin/server"
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

if [[ "$path" == /admin/owasp/export ]]; then
  handle_owasp_export
fi
if [[ "$path" == /admin/owasp/import ]]; then
  handle_owasp_raw_import
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
  /|/admin|/admin/) dashboard ;;
  /admin/site) site_editor ;;
  /admin/owasp) owasp_page ;;
  /admin/server) server_page ;;
  /admin/site/save|/admin/site/delete|/admin/route/add|/admin/route/save|/admin/route/delete|/admin/cert/selfsigned|/admin/cert/letsencrypt|/admin/cert/import|/admin/waf/disable|/admin/waf/enable|/admin/owasp/pl|/admin/owasp/rule/disable|/admin/owasp/rule/enable|/admin/owasp/custom/save|/admin/owasp/custom/disable|/admin/owasp/custom/enable|/admin/owasp/custom/delete|/admin/server/save|/admin/config/save|/admin/config/reset)
    handle_post "$path" ;;
  *)
    page_head "Not found"
    echo '<div class="alert alert-warning">Page not found.</div><a class="btn btn-secondary" href="/">Back</a>'
    page_tail ;;
esac
