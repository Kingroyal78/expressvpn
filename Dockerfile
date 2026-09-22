ARG DISTRIBUTION="trixie-slim"

FROM debian:${DISTRIBUTION} AS microsocks-builder

RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends build-essential git ca-certificates; \
    git clone --depth 1 https://github.com/rofl0r/microsocks.git /tmp/microsocks; \
    make -C /tmp/microsocks; \
    strip /tmp/microsocks/microsocks; \
    mv /tmp/microsocks/microsocks /usr/local/bin/microsocks; \
    apt-get purge -y --auto-remove build-essential git; \
    rm -rf /tmp/microsocks; \
    rm -rf /var/lib/apt/lists/*

FROM debian:${DISTRIBUTION}

ENV CODE="code" \
    SERVER="smart" \
    HEALTHCHECK="" \
    BEARER="" \
    NETWORK="on" \
    ALLOW_LAN="true" \
    LAN_CIDR="" \
    PROTOCOL="lightwayudp" \
    METRICS_PROMETHEUS="off" \
    METRICS_PORT="9797" \
    METRICS_PATH="/metrics.cgi" \
    CONTROL_SERVER="off" \
    CONTROL_IP="0.0.0.0" \
    CONTROL_PORT="8000" \
    AUTH_CONFIG="/expressvpn/config.toml" \
    SOCKS="off" \
    SOCKS_LOGS="true" \
    SOCKS_AUTH_ONCE="false" \
    SOCKS_USER="" \
    SOCKS_PASS="" \
    SOCKS_IP="0.0.0.0" \
    SOCKS_PORT="1080" \
    SOCKS_WHITELIST=""

# The universal .run is multi-arch: it bundles amd64 (x64/) and arm64 (arm64/)
# binaries and its multi_arch_installer.sh picks the right set from `uname -m`,
# so the same URL works for every target platform of a buildx build.
# Keep EXPRESSVPN_VERSION / EXPRESSVPN_SHA256 in sync with expressvpn.env.
ARG EXPRESSVPN_VERSION="14.2.0.13656"
ARG EXPRESSVPN_SHA256="9d770edc6548a17994fd15714c5030a8f5767671b76b2117a884f7d48d93f2cb"
ARG EXPRESSVPN_RUN_URL="https://www.expressvpn.works/clients/linux/expressvpn-linux-universal-${EXPRESSVPN_VERSION}_release.run"

LABEL org.opencontainers.image.title="ExpressVPN container" \
      org.opencontainers.image.version="${EXPRESSVPN_VERSION}" \
      org.opencontainers.image.description="ExpressVPN client container"

COPY files/ /expressvpn/
COPY --from=microsocks-builder /usr/local/bin/microsocks /usr/local/bin/microsocks

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        iproute2 \
        jq \
        iptables \
        iputils-ping \
        procps \
        psmisc \
        libatomic1 \
        libdbus-1-3 \
        libglib2.0-0 \
        busybox \
        socat \
        python3 \
        python3-tomli \
        xz-utils; \
    if [ -z "${EXPRESSVPN_SHA256}" ]; then \
        echo "ERROR: EXPRESSVPN_SHA256 is empty; refusing to run an unverified installer as root" >&2; \
        exit 1; \
    fi; \
    curl -fsSL "${EXPRESSVPN_RUN_URL}" -o /tmp/expressvpn.run; \
    echo "${EXPRESSVPN_SHA256}  /tmp/expressvpn.run" | sha256sum -c -; \
    sh /tmp/expressvpn.run --accept --quiet --noprogress -- --no-gui --sysvinit --force-dependencies; \
    rm -f /tmp/expressvpn.run; \
    curl -fsSL "https://raw.githubusercontent.com/kavehtehrani/cloudflare-speed-cli/main/install.sh" | sh; \
    mv /root/.local/bin/cloudflare-speed-cli /usr/local/bin/cloudflare-speed-cli; \
    rmdir /root/.local/bin 2>/dev/null || true; \
    rm -rf /var/lib/apt/lists/*; \
    rm -rf /var/log/*.log

# Budget: state 3s + DNS 5s + two 5s probes + 5s IP lookup + 5s hc-ping ~= 28s
# worst case, so the timeout must exceed that or a slow check is SIGKILLed,
# which counts as a failure *and* skips the hc-ping /fail report. Raising
# HEALTHCHECK_TIMEOUT/HEALTHCHECK_URLS past this budget needs a matching
# --health-timeout at run time.
#
# start-period must cover start.sh's worst-case boot: wait_for_daemon 120s +
# login 60s + wait_for_smart_location 30s + wait_for_connection 30s = ~240s.
# retries x interval then tolerates a normal supervisor reconnect (up to ~60s)
# without flapping, while still surfacing a dead tunnel in ~2.5 minutes.
HEALTHCHECK --start-period=300s --timeout=30s --interval=30s --retries=5 CMD bash /expressvpn/healthcheck.sh

ENTRYPOINT ["/bin/bash", "/expressvpn/start.sh"]
