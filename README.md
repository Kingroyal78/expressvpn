# ExpressVPN

> WARNING: If you are upgrading from an earlier version of this container, read this README carefully, especially the section "Network Lock and LAN Access".

Container based on [polkaned/expressvpn](https://github.com/polkaned/dockerfiles/tree/master/expressvpn) with additional features and automation.

## Table of Contents

- [Features](#features)
- [Quickstart (docker run)](#quickstart-docker-run)
- [Docker Compose](#docker-compose)
- [Configuration](#configuration)
- [Protocols](#protocols)
- [Network Lock and LAN Access](#network-lock-and-lan-access)
- [SOCKS5 Proxy](#socks5-proxy)
- [Control Server API](#control-server-api)
- [Prometheus Metrics](#prometheus-metrics)
- [Healthcheck](#healthcheck)
- [DNS Leak Check](#dns-leak-check)
- [Servers Available](#servers-available)
- [Troubleshooting](#troubleshooting)
- [Building](#building)
- [Download](#download)

## Features

- ExpressVPN 14.x CLI (`expressvpnctl`) with headless activation.
- Automatic activation via `CODE` and background mode enable.
- Protocol selection with validation.
- Network Lock support with optional LAN access and routed subnets.
- SOCKS5 proxy (microsocks) with auth and whitelist support.
- Prometheus metrics exporter with `/metrics` or custom `.cgi` path.
- Optional control server API to query status and control connections.
- Healthcheck that probes real external reachability through the tunnel, with
  optional DDNS/IP leak validation and healthchecks.io support.
- DNS whitelist for custom resolvers.
- Built on `debian:trixie-slim` (amd64) with updated system packages.

## Quickstart (docker run)

```bash
docker run \
  --env=CODE=code \
  --env=SERVER=smart \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_PTRACE \
  --device=/dev/net/tun \
  --detach=true \
  --tty=true \
  --name=expressvpn \
  --publish 1080:1080 \
  --publish 8000:8000 \
  --publish 9797:9797 \
  --env=PROTOCOL=lightwayudp \
  --env=ALLOW_LAN=true \
  --env=LAN_CIDR=192.168.55.0/24 \
  --env=METRICS_PROMETHEUS=on \
  --env=CONTROL_SERVER=on \
  --env=SOCKS=off \
  ghcr.io/kingroyal78/expressvpn \
  /bin/bash
```

Another container using the VPN network:

```bash
docker run \
  --name=example \
  --net=container:expressvpn \
  maintainer/example:version
```

## Docker Compose

```yaml
services:
  example:
    image: maintainer/example:version
    container_name: example
    network_mode: service:expressvpn
    depends_on:
      expressvpn:
        condition: service_healthy

  expressvpn:
    image: ghcr.io/kingroyal78/expressvpn:latest
    container_name: expressvpn
    restart: unless-stopped
    ports:
      - 1080:1080 # socks5 (optional)
      - 8000:8000 # control server (optional)
      - 9797:9797 # metrics (optional)
    environment:
      - CODE=code
      - SERVER=smart
      - PROTOCOL=lightwayudp
      - ALLOW_LAN=true
      - LAN_CIDR=192.168.55.0/24
      - METRICS_PROMETHEUS=on
      - CONTROL_SERVER=on
      - SOCKS=off
      # Optional healthcheck/IP validation
      # - DDNS=yourDdnsDomain
      # - IP=yourStaticIp
      # - BEARER=ipInfoAccessToken
      # - HEALTHCHECK=healthchecks.ioId
      # Optional DNS whitelist
      # - WHITELIST_DNS=192.168.1.1,1.1.1.1
    cap_add:
      - NET_ADMIN
      - SYS_PTRACE
    devices:
      - /dev/net/tun
    stdin_open: true
    tty: true
    command: /bin/bash
```

> **Note:** `start.sh` now begins the supervision loop before honoring an overridden `command`, so any custom wrappers (DNS sync, routing scripts, etc.) can still run while the loop keeps reconnecting the VPN and exposing health failures when the tunnel stays down.

## Configuration

Environment variables (defaults shown):

| ENV | Description | Default |
| :--- | :--- | :---: |
| CODE | ExpressVPN activation code | code |
| SERVER | Region ID or `smart` | smart |
| PROTOCOL | VPN protocol | lightwayudp |
| CONNECTION_CHECK_INTERVAL | Seconds between supervision loop checks | 30 |
| RECONNECT_FAILURE_THRESHOLD | Consecutive reconnect failures before marking unhealthy | 3 |
| NETWORK | Network Lock (`on`/`off`) | on |
| ALLOW_LAN | Allow LAN access while Network Lock is on | true |
| LAN_CIDR | Comma-separated LAN CIDRs for return routes | (empty) |
| WHITELIST_DNS | Comma-separated DNS servers to allow via iptables | (empty) |
| DDNS | Domain whose IPv4 must not equal the public IP (see [Healthcheck](#healthcheck)) | (empty) |
| IP | Static IP that must not equal the public IP | (empty) |
| BEARER | ipinfo.io bearer token (leak check and `/v1/ip`) | (empty) |
| HEALTHCHECK | healthchecks.io UUID | (empty) |
| HEALTHCHECK_URLS | Space-separated external probe URLs | Cloudflare + gstatic `generate_204` |
| HEALTHCHECK_TIMEOUT | Per-probe timeout in seconds | 5 |
| METRICS_PROMETHEUS | Enable metrics exporter (`on`/`off`) | off |
| METRICS_PORT | Metrics port | 9797 |
| METRICS_PATH | Metrics path (absolute, ends with `.cgi`) | /metrics.cgi |
| CONTROL_SERVER | Enable control server (`on`/`off`) | off |
| CONTROL_IP | Control server bind IP | 0.0.0.0 |
| CONTROL_PORT | Control server port | 8000 |
| AUTH_CONFIG | Auth config file path | /expressvpn/config.toml |
| CONTROL_MAX_BODY_BYTES | Max control server request body size | 65536 |
| CLOUDFLARE_SPEED_TIMEOUT | Speed test timeout in seconds (control server) | 120 |
| SOCKS | Enable SOCKS5 proxy (`on`/`off`) | off |
| SOCKS_IP | SOCKS bind IP | 0.0.0.0 |
| SOCKS_PORT | SOCKS port | 1080 |
| SOCKS_USER | SOCKS username (leave empty or omit for no auth; legacy `NONE` is treated as empty) | (empty) |
| SOCKS_PASS | SOCKS password (leave empty or omit for no auth; legacy `NONE` is treated as empty) | (empty) |
| SOCKS_WHITELIST | Comma-separated IPs bypassing auth | (empty) |
| SOCKS_AUTH_ONCE | Cache auth by IP (`true`/`false`) | false |
| SOCKS_LOGS | Enable microsocks logs (`true`/`false`) | true |

### Supervision failure flag

The supervision loop writes `/tmp/expressvpn/reconnect-failure.flag` when
`RECONNECT_FAILURE_THRESHOLD` consecutive reconnect attempts fail. The
built-in healthcheck reads that flag and reports `/fail`, which makes Docker
mark the container as unhealthy until the VPN reconnects and clears the flag.

## Protocols

Supported values for `PROTOCOL`:

- auto
- lightwayudp (default)
- lightwaytcp
- openvpnudp
- openvpntcp
- wireguard

## Network Lock and LAN Access

- Network Lock is enabled by default (`NETWORK=on`).
- If your kernel does not support Network Lock (minimum 4.9), it will be disabled at runtime.
- `ALLOW_LAN=true` lets LAN traffic through while Network Lock is on.
- Set `LAN_CIDR` (comma-separated) to add return routes for your LAN subnets.

## SOCKS5 Proxy

Enable the SOCKS5 proxy with:

- `SOCKS=on`
- Optional auth: set both `SOCKS_USER` and `SOCKS_PASS`
- Optional whitelist: `SOCKS_WHITELIST=ip1,ip2`
- Optional cache: `SOCKS_AUTH_ONCE=true`

## Control Server API

Enable the control API with:

- `CONTROL_SERVER=on`
- `CONTROL_IP=0.0.0.0`
- `CONTROL_PORT=8000`

### Endpoints

| Method | Path | Description |
| :--- | :--- | :--- |
| GET | /v1/status | Connection status, server, IP |
| GET | /v1/vpn/status | VPN status (`running`/`stopped`) |
| GET | /v1/vpn/settings | VPN settings (protocol, region, allow_lan) |
| POST | /v1/vpn/settings | Update VPN settings (protocol, region, allow_lan) |
| GET | /v1/servers | List available regions |
| GET | /v1/ip | Public IP info (uses `BEARER` if set) |
| GET | /v1/publicip/ip | Public IP (`{"public_ip":"x.x.x.x"}`) |
| GET | /v1/dns | Resolver info and `/etc/resolv.conf` |
| GET | /v1/dns/status | DNS status (`running`/`stopped`) |
| GET | /v1/dnsleak | DNS leak test result |
| GET | /v1/speedtest | Cloudflare speed test (`cloudflare-speed-cli --json`) |
| GET | /v1/health | API health check |
| POST | /v1/connect | Connect to server (JSON: `{ "server": "smart" }`) |
| POST | /v1/disconnect | Disconnect from VPN |

The speed test endpoint uses `cloudflare-speed-cli` by kavehtehrani:
https://github.com/kavehtehrani/cloudflare-speed-cli

The DNS leak test script is using:
https://github.com/macvk/dnsleaktest

### Authentication

Mount a TOML file at `/expressvpn/config.toml` (or change `AUTH_CONFIG`). Example file: [`example/config.toml.example`](example/config.toml.example).

```toml
[[roles]]
name = "admin"
routes = ["GET /v1/status", "GET /v1/servers", "GET /v1/dns", "GET /v1/ip", "GET /v1/dnsleak", "GET /v1/speedtest", "POST /v1/connect", "POST /v1/disconnect", "GET /v1/health"]
auth = "basic"
username = "admin"
password = "changeme"

[[roles]]
name = "api_user"
routes = ["GET /v1/status", "POST /v1/connect", "POST /v1/disconnect"]
auth = "apikey"
apikey = "your-secret-api-key"
```

If the config file is missing, a single role can be defined via environment variables:

- `CONTROL_AUTH_TYPE` (`basic`, `api_key`, or `none`)
- `CONTROL_AUTH_NAME`
- `CONTROL_AUTH_USER`
- `CONTROL_AUTH_PASSWORD`
- `CONTROL_API_KEY`
- `CONTROL_AUTH_ROUTES` (comma-separated `METHOD /path`, default `*`)

> **The control server fails closed.** If no roles are configured — no auth
> config file *and* no `CONTROL_AUTH_TYPE` — every request is rejected with
> `503 Service Unavailable`, and a warning is logged at startup. This API can
> connect and disconnect the VPN, and it binds `0.0.0.0` by default, so an
> unconfigured server must not answer anonymous callers.
>
> To allow anonymous access deliberately, set `CONTROL_AUTH_TYPE=none` (or give
> a role `auth = "none"`). Earlier versions allowed anonymous access implicitly
> whenever auth was unconfigured; if you relied on that, set this explicitly.

Request bodies are capped at `CONTROL_MAX_BODY_BYTES` (default 65536). A
malformed `Content-Length` is answered with `400`, an oversized one with `413`.

Example request:

```bash
curl -u admin:changeme http://localhost:8000/v1/status
```

For API key auth, send the key with:

```bash
curl -H "X-API-Key: your-secret-api-key" http://localhost:8000/v1/status
```

### Example usage

Update VPN settings:

```bash
curl -X POST http://localhost:8000/v1/vpn/settings \
  -H "Content-Type: application/json" \
  -u admin:changeme \
  -d '{"protocol":"lightwayudp","region":"smart","allow_lan":true}'
```

Connect to a region:

```bash
curl -X POST http://localhost:8000/v1/connect \
  -H "Content-Type: application/json" \
  -u admin:changeme \
  -d '{"server":"germany-frankfurt-1"}'
```

Disconnect:

```bash
curl -X POST http://localhost:8000/v1/disconnect \
  -u admin:changeme
```

## Prometheus Metrics

Enable metrics with:

- `METRICS_PROMETHEUS=on`
- `METRICS_PORT=9797`
- `METRICS_PATH=/metrics.cgi` (absolute and must end with `.cgi`)

Metrics are served on `/metrics.cgi` (or `/metrics`) at the configured port.
If the embedded `httpd` cannot bind the port, a socat fallback server is started.

### Exported metrics

- `expressvpn_connection_status` (0/1)
- `expressvpn_connection_state{state}`
- `expressvpn_connection_uptime_seconds`
- `expressvpn_last_state_change_timestamp_seconds`
- `expressvpn_state_changes_total`
- `expressvpn_connect_attempts_total`
- `expressvpn_connect_failures_total`
- `expressvpn_connection_info{server,connected_server,protocol,network_lock}`
- `expressvpn_vpn_ip_info{ip}`
- `expressvpn_public_ip_info{ip}`
- `expressvpn_vpn_interface_info{interface}`
- `expressvpn_vpn_interface_up{interface}`
- `expressvpn_vpn_interface_mtu_bytes{interface}`
- `expressvpn_network_rx_bytes_total{interface}`
- `expressvpn_network_tx_bytes_total{interface}`
- `expressvpn_network_rx_packets_total{interface}`
- `expressvpn_network_tx_packets_total{interface}`
- `expressvpn_network_rx_errors_total{interface}`
- `expressvpn_network_tx_errors_total{interface}`
- `expressvpn_network_rx_dropped_total{interface}`
- `expressvpn_network_tx_dropped_total{interface}`

### Prometheus scrape config example

```yaml
scrape_configs:
  - job_name: expressvpn
    metrics_path: /metrics.cgi
    static_configs:
      - targets: ["expressvpn:9797"]
```

### Grafana dashboard

An example Grafana dashboard is provided at [`example/expressvpn-grafana-dashboard.json`](example/expressvpn-grafana-dashboard.json).
Import it in Grafana and select your Prometheus datasource to view all exported metrics.

## Healthcheck

The container healthcheck runs every 30s. Five consecutive failures mark the
container unhealthy, so a dead tunnel surfaces in ~2.5 minutes while a normal
supervisor reconnect does not cause flapping. The 300s start period covers
`start.sh`'s worst-case boot (daemon wait + activation + first connect).

It checks, cheapest first:

1. The supervision loop's failure flag.
2. The client's own connection state (fast-fail only).
3. **External reachability** - an HTTP probe that must succeed *through the
   tunnel*. This is the real check: ExpressVPN can report `Connected` with
   `tun0` present while no traffic actually passes, which a local-only check
   cannot detect.
4. Optional public-IP leak check, when `DDNS` or `IP` is set.

The healthcheck only observes. Reconnecting is the supervision loop's job, so
the healthcheck never disconnects or reconnects the VPN itself.

| ENV | Description | Default |
| :--- | :--- | :---: |
| HEALTHCHECK_URLS | Space-separated probe URLs; the first success wins | `https://cp.cloudflare.com/generate_204 https://connectivitycheck.gstatic.com/generate_204` |
| HEALTHCHECK_TIMEOUT | Per-probe timeout in seconds | 5 |
| HEALTHCHECK_DNS_TIMEOUT | Timeout for resolving `DDNS` | 5 |
| HEALTHCHECK_VPN_IF | VPN interface to bind probes to (auto-detected otherwise) | (auto) |
| DDNS | Domain whose IPv4 must **not** equal the public IP | (empty) |
| IP | Static IP that must **not** equal the public IP | (empty) |
| BEARER | ipinfo.io token for the leak check | (empty) |
| HEALTHCHECK | healthchecks.io UUID to post status to | (empty) |

Notes:

- The probe is bound to the VPN interface (`--interface`), so it fails when the
  tunnel is down even if the container could still reach the internet over its
  default route — for example with `NETWORK=off`, where no network lock blocks
  the leak. Interface detection covers `tun*`/`wg*`; override with
  `HEALTHCHECK_VPN_IF`.
- `DDNS` is compared within one address family: an A record against the public
  IPv4, or an AAAA-only name against the public IPv6. Comparing across families
  can never match and would silently disable the check.
- If the public-IP lookup itself is unreachable, the leak check is skipped with
  a warning instead of failing: reachability already proved the tunnel is alive,
  and a third-party outage should not take the container down.
- A detected leak cannot be fixed by the healthcheck (it only observes), and the
  supervision loop cannot see it either, since the client still reports
  `Connected`. The healthcheck therefore writes
  `/tmp/expressvpn/reconnect-request.flag`, which the supervision loop picks up
  and acts on by rebuilding the tunnel.
- Raising `HEALTHCHECK_TIMEOUT` or adding probe URLs increases the worst-case
  runtime, which must stay under the image's baked-in 30s healthcheck timeout;
  beyond that, pass `--health-timeout` at run time.

## DNS Leak Check

To avoid DNS leaks, update dependent containers to use the `resolv.conf` from this container after connect.

Run the DNS leak test inside the container:

```bash
curl -s https://raw.githubusercontent.com/macvk/dnsleaktest/refs/heads/master/dnsleaktest.sh | docker exec -i expressvpn bash -s
```

## Servers Available

Set `SERVER=smart` or an ExpressVPN region ID.
On startup with `SERVER=smart`, the container waits briefly for the smart location
to refresh before connecting, so the first connection aligns with the latest smart region.
Unnumbered IDs are retried with `-1`, so values like `usa-new-york` can resolve to
`usa-new-york-1`.
List regions from inside the container:

```bash
expressvpnctl get regions
```

## Troubleshooting

### VPN stuck reconnecting on Fedora (missing `tun0`)

On Fedora hosts the container may loop with `VPN down (missing tun0 or not connected)` even though the `/dev/net/tun` device is mapped correctly.
This happens because the host kernel does not automatically create the `tun0` interface.

**Solution:** create a persistent `tun0` on the host before starting the container:

```bash
sudo tunctl -t tun0
```

Install `tunctl` if it is not present (`dnf install tunctl` or the `usermode-tools` / `tun` package for your Fedora version), then re-run the command and start the container.

> See [issue #59](https://github.com/Misioslav/expressvpn/issues/59) for the original report.

## Building

The pinned ExpressVPN client version and its installer SHA256 live in
[`expressvpn.env`](expressvpn.env) as the single source of truth. The universal
`.run` installer is multi-arch (it bundles `amd64` and `arm64` binaries and
picks one at install time), so the same download builds every platform.

### Locally

```bash
# Single-arch (host arch), loads into the local docker with the pinned
# ExpressVPN build number as the default tag:
./expressbuild.sh <repository> [tag]

# Multi-arch build + push to a registry:
./expressbuild.sh <repository> [tag] --platform linux/amd64,linux/arm64 --push
```

Supported platforms: `linux/amd64` and `linux/arm64` (there is no armhf/armv7
build). `expressbuild.sh` reads the version and checksum from `expressvpn.env`.
When `tag` is omitted, the local image uses the full ExpressVPN build number
(for example `14.2.0.13656`) instead of only `latest`.

### CI (GitHub Actions)

- **[`build.yml`](.github/workflows/build.yml)** builds `linux/amd64` (on
  `ubuntu-24.04`) and `linux/arm64` (on native `ubuntu-24.04-arm` runners) in
  parallel and pushes a combined multi-arch manifest to GHCR
  (`ghcr.io/kingroyal78/expressvpn`). It runs on pushes to `master`, on `v*` tags, and
  via **Run workflow**, where you can override the ExpressVPN version + SHA256.
- **[`check-version.yml`](.github/workflows/check-version.yml)** runs daily and
  opens an issue when a newer Linux client is published.

### Bumping the ExpressVPN version

The full build number in the download URL (e.g. `14.2.0.13656`) is only shown
after signing in to **My Account → Set Up ExpressVPN → Linux**, so bumps are
manual:

1. Grab the full build number and download its
   `expressvpn-linux-universal-<build>_release.run`.
2. `sha256sum` that file.
3. Update `EXPRESSVPN_VERSION` and `EXPRESSVPN_SHA256` in `expressvpn.env`
   (and the matching `ARG` defaults in the `Dockerfile`), commit, and push —
   or trigger **Build and push image** manually with both values as inputs.

## Download

```bash
docker pull ghcr.io/kingroyal78/expressvpn:latest
# Pin deployments to a specific client build when desired:
docker pull ghcr.io/kingroyal78/expressvpn:14.2.0.13656
```
