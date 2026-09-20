FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx \
      libnginx-mod-http-modsecurity \
      modsecurity-crs \
      fcgiwrap \
      spawn-fcgi \
      dehydrated \
      curl \
      ca-certificates \
      openssl \
    && rm -rf /var/lib/apt/lists/*

COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/admin.conf /etc/nginx/conf.d/00-lazycb-admin.conf
COPY nginx/security.conf /etc/nginx/snippets/lazycb-security.conf
COPY nginx/modsecurity.conf /etc/nginx/modsec/main.conf
COPY nginx/modsecurity-wordpress.conf /etc/nginx/modsec/wordpress.conf
COPY bin /opt/lazycb/bin
COPY cgi /opt/lazycb/cgi
COPY ui /opt/lazycb/ui
COPY entrypoint.sh /opt/lazycb/entrypoint.sh

RUN chmod +x /opt/lazycb/entrypoint.sh /opt/lazycb/bin/*.sh /opt/lazycb/cgi/*.sh \
    && mkdir -p /data/sites /data/certs /data/auth /data/acme/challenges/.well-known/acme-challenge /data/acme/certs /data/logs /etc/nginx/lazycb-sites \
    && sed -i 's/^SecRuleEngine .*/SecRuleEngine On/' /etc/nginx/modsecurity.conf

EXPOSE 80 443
VOLUME ["/data"]

ENTRYPOINT ["/opt/lazycb/entrypoint.sh"]
