FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS manager-build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY manager/go.mod manager/go.sum ./
RUN go mod download
COPY manager/ ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /ikev2-manager .

FROM debian:12-slim AS ext-auth-build
WORKDIR /build
RUN sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends build-essential dpkg-dev pkg-config \
    && apt-get source strongswan \
    && cd strongswan-* \
    && ./configure --disable-defaults --enable-ext-auth \
    && make -C src/libcharon/plugins/ext_auth \
    && cp src/libcharon/plugins/ext_auth/.libs/libstrongswan-ext-auth.so /libstrongswan-ext-auth.so

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
    nftables \
    ca-certificates \
    procps \
    kmod \
    openssl \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY config/strongswan.conf /etc/strongswan.conf
COPY --from=manager-build /ikev2-manager /usr/local/bin/ikev2-manager
COPY --from=ext-auth-build /libstrongswan-ext-auth.so /usr/lib/ipsec/plugins/
COPY scripts/start.sh /start.sh
COPY scripts/lib/ /usr/local/lib/ikev2/
COPY tests/strongswan-config.sh /tmp/ikev2-test-strongswan-config.sh

RUN chmod +x /start.sh \
    && bash -n /start.sh \
    && for module in /usr/local/lib/ikev2/*.sh; do bash -n "$module" || exit 1; done \
    && test -f /usr/lib/ipsec/plugins/libstrongswan-eap-mschapv2.so \
    && test -f /usr/lib/ipsec/plugins/libstrongswan-ext-auth.so \
    && test -f /usr/lib/ipsec/plugins/libstrongswan-farp.so \
    && test -f /usr/lib/ipsec/plugins/libstrongswan-openssl.so \
    && test -f /usr/lib/ipsec/plugins/libstrongswan-gcm.so \
    && bash /tmp/ikev2-test-strongswan-config.sh \
    && rm /tmp/ikev2-test-strongswan-config.sh /etc/swanctl/swanctl.conf

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD test -f /run/ikev2.ready && timeout 3 swanctl --stats >/dev/null 2>&1 || exit 1

CMD ["/start.sh"]
