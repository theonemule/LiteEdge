#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required." >&2
  exit 1
}
docker compose version >/dev/null 2>&1 || {
  echo "Docker Compose v2 is required." >&2
  exit 1
}
command -v openssl >/dev/null 2>&1 || {
  echo "OpenSSL is required by the installer." >&2
  exit 1
}

mkdir -p data
chmod 755 data

if [[ ! -f .env ]]; then
  password="$(openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-')"
  cat > .env <<ENV
ADMIN_USER=admin
ADMIN_PASSWORD=$password
ACME_EMAIL=
TZ=UTC
ENV
  chmod 600 .env
  echo "Created .env"
  echo "Admin user: admin"
  echo "Admin password: $password"
  echo "Set ACME_EMAIL in .env before using Let's Encrypt."
fi

docker compose up -d --build
echo
echo "lazyCB is running on ports 80 and 443."
echo "Open http://<server-ip>/ or https://<server-ip>/"
