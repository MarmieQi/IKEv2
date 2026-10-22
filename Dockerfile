FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    strongswan \
    strongswan-swanctl \
    libcharon-extra-plugins \
    libcharon-extauth-plugins \
    libstrongswan-extra-plugins \
    libstrongswan-standard-plugins \
    iproute2 \
    iptables \
    ca-certificates \
    procps \
    kmod \
    openssl \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY config/strongswan.conf /etc/strongswan.conf
COPY scripts/start.sh /start.sh
COPY scripts/lib/ /usr/local/lib/ikev2/
COPY tests/strongswan-config.sh /tmp/ikev2-test-strongswan-config.sh

RUN chmod +x /start.sh \
    && bash -n /start.sh \
    && for module in /usr/local/lib/ikev2/*.sh; do bash -n "$module" || exit 1; done \
    && test -f /usr/lib/ipsec/plugins/libstrongswan-eap-mschapv2.so \
    && test -f /usr/lib/ipsec/plugins/libstrongswan-farp.so \
    && test -f /usr/lib/ipsec/plugins/libstrongswan-openssl.so \
    && test -f /usr/lib/ipsec/plugins/libstrongswan-gcm.so \
    && bash /tmp/ikev2-test-strongswan-config.sh \
    && rm /tmp/ikev2-test-strongswan-config.sh /etc/swanctl/swanctl.conf

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD test -f /run/ikev2.ready && timeout 3 swanctl --stats >/dev/null 2>&1 || exit 1

CMD ["/start.sh"]
