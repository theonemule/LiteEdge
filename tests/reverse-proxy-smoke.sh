#!/usr/bin/env bash
# Disposable end-to-end LiteEdge route, reverse-proxy and admin isolation test.
# Requires Docker, curl and openssl. All state lives in temporary Docker objects.
set -Eeuo pipefail
image="${1:-liteedge:monthly-ci}"
docker image inspect "$image" >/dev/null
suffix="${GITHUB_RUN_ID:-local}-$$"
network="liteedge-ci-net-${suffix}"
backend="liteedge-ci-backend-${suffix}"
edge="liteedge-ci-edge-${suffix}"
volume="liteedge-ci-data-${suffix}"
cleanup() {
  docker logs "$edge" 2>&1 | tail -80 || true
  docker rm -f "$edge" "$backend" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker run -d --name "$backend" --network "$network" nginx:alpine >/dev/null
docker exec "$backend" sh -c "printf 'liteedge-monthly-backend-ok\n' >/usr/share/nginx/html/index.html"
password="$(openssl rand -hex 24)"
docker run -d --name "$edge" --network "$network" \
  -e ADMIN_USER=admin -e "ADMIN_PASSWORD=$password" \
  -v "$volume:/data" \
  -p 127.0.0.1::8080 -p 127.0.0.1::9443 \
  "$image" >/dev/null
port="$(docker port "$edge" 8080/tcp | awk -F: 'NR==1{print $NF}')"
admin_port="$(docker port "$edge" 9443/tcp | awk -F: 'NR==1{print $NF}')"
[[ "$port" =~ ^[0-9]+$ && "$admin_port" =~ ^[0-9]+$ ]]
ready=false
for i in $(seq 1 75); do
  status="$(docker inspect -f '{{.State.Status}}' "$edge")"
  [[ "$status" == running ]] || { echo "LiteEdge container exited: $status" >&2; exit 1; }
  if [[ "$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 2 "https://127.0.0.1:$admin_port/" || true)" == 401 ]]; then
    ready=true
    break
  fi
  sleep 2
done
[[ "$ready" == true ]] || { echo 'LiteEdge admin listener did not become ready' >&2; exit 1; }
# Public and management listeners must remain isolated.
[[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" || true)" != 200 ]]
docker exec "$edge" /opt/liteedge/bin/sitectl.sh save ci.example.test ''
docker exec "$edge" /opt/liteedge/bin/sitectl.sh route-add \
  ci.example.test prefix / "http://$backend:80" 0 60 1 0 1
docker exec "$edge" /opt/liteedge/sbin/nginx -t -c /data/nginx/nginx.conf
success=false
for i in $(seq 1 20); do
  if curl -fsS --max-time 5 -H 'Host: ci.example.test' "http://127.0.0.1:$port/" | grep -Fxq liteedge-monthly-backend-ok; then
    success=true
    break
  fi
  sleep 1
done
[[ "$success" == true ]] || { echo 'Reverse proxy did not reach the upstream backend' >&2; exit 1; }
# Management authentication remains mandatory after route creation.
[[ "$(curl -ksS -o /dev/null -w '%{http_code}' "https://127.0.0.1:$admin_port/" || true)" == 401 ]]
docker exec "$edge" /opt/liteedge/bin/sitectl.sh delete ci.example.test
deleted=false
for i in $(seq 1 20); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: ci.example.test' "http://127.0.0.1:$port/" || true)"
  if [[ "$code" != 200 ]]; then deleted=true; break; fi
  sleep 1
done
[[ "$deleted" == true ]] || { echo 'Deleted route is still proxying requests' >&2; exit 1; }
echo 'PASS: actual NGINX route creation, WAF-enabled upstream proxying, deletion, config check and admin isolation'
