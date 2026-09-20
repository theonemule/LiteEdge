#!/usr/bin/env bash
set -euo pipefail
umask 027

mkdir -p /data/sites /data/certs /data/auth /data/acme/challenges/.well-known/acme-challenge /data/acme/certs /data/logs /data/www /etc/nginx/litewaf-sites /run
chgrp www-data /data/auth
chmod 750 /data/auth
chmod 755 /data/www
ADMIN_USER="${ADMIN_USER:-admin}"

if [[ ! -s /data/auth/.htpasswd ]]; then
  [[ -n "${ADMIN_PASSWORD:-}" ]] || { echo "ADMIN_PASSWORD is required on first start." >&2; exit 1; }
  password_hash="$(openssl passwd -6 "$ADMIN_PASSWORD")"
  printf '%s:%s\n' "$ADMIN_USER" "$password_hash" > /data/auth/.htpasswd
  chgrp www-data /data/auth/.htpasswd
  chmod 640 /data/auth/.htpasswd
fi

if [[ ! -s /data/certs/_admin/fullchain.pem || ! -s /data/certs/_admin/privkey.pem ]]; then
  mkdir -p /data/certs/_admin
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout /data/certs/_admin/privkey.pem \
    -out /data/certs/_admin/fullchain.pem \
    -subj "/CN=litewaf.local" >/dev/null 2>&1
  chmod 600 /data/certs/_admin/privkey.pem
fi

/opt/litewaf/bin/render-nginx.sh

rm -f /run/fcgiwrap.sock
spawn-fcgi -s /run/fcgiwrap.sock -M 660 -U www-data -G www-data -- /usr/sbin/fcgiwrap
chmod 660 /run/fcgiwrap.sock

(
  sleep 60
  while :; do
    /opt/litewaf/bin/renew-certs.sh >>/data/logs/acme-renew.log 2>&1 || true
    sleep 43200
  done
) &

exec nginx -g 'daemon off;'
