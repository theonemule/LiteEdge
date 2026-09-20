FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8

ARG LITEEDGE_VERSION=v0.1.0
ARG LITEEDGE_REPO=theonemule/LiteEdge

RUN apk add --no-cache \
      bash ca-certificates curl openssl \
      fcgiwrap spawn-fcgi \
      pcre2 libxml2 yajl lmdb libcurl libstdc++ libgcc zlib libmaxminddb \
      coreutils \
    && addgroup -g 10001 -S liteedge \
    && adduser -S -D -H -u 10001 -G liteedge liteedge \
    && mkdir -p /data \
    && chown 10001:10001 /data \
    && arch="$(uname -m)" \
    && case "$arch" in x86_64|aarch64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac \
    && asset="liteedge-linux-musl-${arch}.tar.gz" \
    && base="https://github.com/${LITEEDGE_REPO}/releases/download/${LITEEDGE_VERSION}" \
    && curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "/tmp/$asset" "$base/$asset" \
    && curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "/tmp/$asset.sha256" "$base/$asset.sha256" \
    && (cd /tmp && sha256sum -c "$asset.sha256") \
    && tar -C / -xzf "/tmp/$asset" \
    && rm -f "/tmp/$asset" "/tmp/$asset.sha256" \
    && test -x /opt/liteedge/sbin/nginx \
    && test -x /opt/liteedge/entrypoint.sh \
    && LD_LIBRARY_PATH=/opt/liteedge/lib /opt/liteedge/sbin/nginx -V 2>&1 | grep -q 'ModSecurity-nginx'

ENV DATA_DIR=/data \
    LITEEDGE_RUN_DIR=/tmp/liteedge-run \
    LITEEDGE_HTTP_PORT=8080 \
    LITEEDGE_HTTPS_PORT=8443

USER 10001:10001
VOLUME ["/data"]

EXPOSE 8080 8443

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD test "$(curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/)" = "401"

ENTRYPOINT ["/opt/liteedge/entrypoint.sh"]
