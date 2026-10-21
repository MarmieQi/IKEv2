FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    strongswan \
    strongswan-swanctl \
    libcharon-extra-plugins \
    libcharon-extauth-plugins \
    libstrongswan-extra-plugins \
    iproute2 \
    iptables \
    ca-certificates \
    procps \
    kmod \
    && rm -rf /var/lib/apt/lists/*

COPY config/strongswan.conf /etc/strongswan.conf
COPY scripts/start.sh /start.sh
COPY scripts/lib/ /usr/local/lib/ikev2/
COPY tests/strongswan-config.sh /tmp/ikev2-test-strongswan-config.sh

RUN chmod +x /start.sh \
    && bash -n /start.sh \
    && bash -n /usr/local/lib/ikev2/proxyarp.sh \
    && bash -n /usr/local/lib/ikev2/runtime-config.sh \
    && bash -n /usr/local/lib/ikev2/users.sh \
    && bash -n /usr/local/lib/ikev2/network-config.sh \
    && bash -n /usr/local/lib/ikev2/strongswan.sh \
    && test -f /usr/lib/ipsec/plugins/libstrongswan-eap-mschapv2.so \
    && test -f /usr/lib/ipsec/plugins/libstrongswan-farp.so \
    && bash /tmp/ikev2-test-strongswan-config.sh \
    && rm /tmp/ikev2-test-strongswan-config.sh

CMD ["/start.sh"]
