# LiteWAF

LiteWAF is a lightweight Docker-hosted NGINX control plane derived from the original
theonemule/docker-waf project. It keeps the hardened NGINX plus ModSecurity and OWASP
Core Rule Set edge, but replaces the fixed demo proxy configuration with a small
Bootstrap management UI.

The management plane is intentionally small:

- Ubuntu 26.04 LTS
- NGINX on ports 80 and 443
- ModSecurity plus OWASP Core Rule Set
- Bash shell scripts only for application logic
- fcgiwrap to expose shell CGI behind NGINX
- HTTP Basic Authentication using an OpenSSL SHA-512 password hash
- Bootstrap 5.3.8 CSS vendored locally
- Flat-file configuration under /data
- No Node.js, Python, PHP, database, or application framework

## Features

Each virtual host can use a Reverse Proxy, WordPress Hardened Proxy, or Local Static
Content profile. Hosts can have aliases, enable or disable the WAF, redirect HTTP to
HTTPS once a certificate exists, and enable WebSocket upgrades on the default
upstream.

A host can override its default backend by path. Routes support prefix, exact, and
regex matches, separate upstream URLs, and per-route WebSocket support.

Each host supports three certificate modes:

- Imported PEM certificate and private key, validated before activation.
- Self-signed certificate generated locally for the host and aliases.
- Let's Encrypt using the shell-based dehydrated ACME client with HTTP-01.

Let's Encrypt certificates are checked twice daily by a small shell renewal loop.
No cron daemon or systemd is required inside the container.

## Install

1. Clone the repository.

    git clone https://github.com/theonemule/LiteWAF.git
    cd LiteWAF

2. Run the installer.

    ./install.sh

On first run the installer creates .env, generates a random admin password, builds
the image, and starts the container.

Open:

    https://SERVER_IP/

Requests to the management listener over HTTP are redirected to HTTPS before Basic
Auth credentials are requested. The initial HTTPS management certificate is self-signed.
Use the Basic Auth credentials printed by install.sh.

To enable Let's Encrypt, edit .env and set:

    ACME_EMAIL=you@example.com

Then restart:

    docker compose up -d

For HTTP-01 issuance, the host name and aliases must resolve to this server and TCP
port 80 must be reachable from the Internet.

## Data layout

All persistent state is under the ./data bind mount:

    data/
      auth/       Basic Auth password file
      sites/      host and route definitions
      certs/      active host certificates
      acme/       ACME account, challenges, and issued certificates
      logs/       certificate renewal logs
      www/        local static site content

The UI never writes NGINX configuration directly. Shell utilities validate submitted
values, render generated virtual-host configuration, run nginx -t, and only keep the
generated configuration if validation succeeds.

## Shell utilities

The UI calls the same scripts that can be used manually inside the container:

    /opt/litewaf/bin/sitectl.sh list

    /opt/litewaf/bin/sitectl.sh save       app.example.com proxy http://app:8080 "" "" 1 1 0

    /opt/litewaf/bin/sitectl.sh route-add       app.example.com prefix /socket/ http://socket:9000 1

    /opt/litewaf/bin/certctl.sh selfsigned app.example.com
    /opt/litewaf/bin/certctl.sh letsencrypt app.example.com

## Security model

The management UI is protected by NGINX HTTP Basic Auth over HTTPS. HTTP requests to
the management listener are redirected before authentication. The UI uses no client-side
application framework and loads its Bootstrap stylesheet
from the local container.

Generated NGINX configuration receives baseline security headers. Site WAF mode uses
ModSecurity with Ubuntu's packaged OWASP Core Rule Set. HTTPS virtual hosts use TLS
1.2 and 1.3 plus HSTS.

The CGI worker performs privileged operations such as writing generated NGINX
configuration and reloading NGINX, so fcgiwrap runs as root. Its Unix socket is only
reachable by the local NGINX process, and the CGI endpoint is only exposed through
the Basic-Auth-protected management server. Values that become NGINX directives are
constrained before rendering.

## Development

Validate all shell files with:

    for f in install.sh entrypoint.sh bin/*.sh cgi/*.sh; do bash -n "$f"; done

A Docker engine is required for an end-to-end image build and runtime test.
