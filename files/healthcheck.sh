#!/bin/bash
set -euo pipefail

# Health model, in order of cost:
#   1. supervisor's failure flag      - free, already decided
#   2. client's own connection state  - cheap local fast-fail
#   3. external reachability probe    - the real check: traffic is sent *out of
#      the VPN interface* and must reach the internet. A tunnel can report
#      "Connected" with the interface present and still pass nothing, so
#      liveness has to be proven end to end. Binding the probe to the interface
#      also stops a torn-down VPN from looking healthy via the default route
#      when network lock is off.
#   4. optional public-IP leak check  - extra credit when DDNS/IP is configured
#
# This script does not reconnect. Reconnecting is the supervision loop's job
# (start.sh); doing it here would race with that loop and can be SIGKILLed
# halfway by the Docker healthcheck timeout, leaving the VPN disconnected.
# When remediation is needed it drops a request flag the supervisor acts on.

FAILURE_FLAG="/tmp/expressvpn/reconnect-failure.flag"
RECONNECT_REQUEST_FLAG="/tmp/expressvpn/reconnect-request.flag"
PROBE_TIMEOUT="${HEALTHCHECK_TIMEOUT:-5}"
DNS_TIMEOUT="${HEALTHCHECK_DNS_TIMEOUT:-5}"
# Tiny endpoints that answer 204 with an empty body, reachable worldwide.
PROBE_URLS="${HEALTHCHECK_URLS:-https://cp.cloudflare.com/generate_204 https://connectivitycheck.gstatic.com/generate_204}"

log() {
    echo "[healthcheck] $*" >&2
}

notify_healthcheck() {
    local suffix="$1"
    [[ -z ${HEALTHCHECK:-} ]] && return 0
    curl -fsS --max-time 5 "https://hc-ping.com/${HEALTHCHECK}${suffix}" >/dev/null 2>&1 || true
}

unhealthy() {
    log "UNHEALTHY: $1"
    notify_healthcheck "/fail"
    exit 1
}

healthy() {
    notify_healthcheck ""
    exit 0
}

# Ask the supervision loop to rebuild the tunnel. Used for faults the supervisor
# cannot see by itself, such as a tunnel that is "Connected" but leaking.
request_reconnect() {
    mkdir -p "$(dirname "$RECONNECT_REQUEST_FLAG")" 2>/dev/null || true
    touch "$RECONNECT_REQUEST_FLAG" 2>/dev/null || true
}

vpn_interface() {
    local iface="${HEALTHCHECK_VPN_IF:-}"
    if [[ -n $iface ]]; then
        [[ -d "/sys/class/net/${iface}" ]] || return 0
        printf '%s' "$iface"
        return
    fi
    if [[ -d /sys/class/net/tun0 ]]; then
        printf 'tun0'
        return
    fi
    ip -o link show 2>/dev/null |
        awk -F': ' '/(tun|wg)[0-9]+/ { split($2, name, "@"); print name[1]; exit }' || true
}

# Resolve the address the public IP must NOT match, and the family to compare
# in. Families must match: an AAAA record can never equal an IPv4 answer, and
# comparing across families silently disables the check.
resolve_check_ip() {
    local resolved
    if [[ -n ${DDNS:-} ]]; then
        resolved=$(timeout "$DNS_TIMEOUT" getent ahostsv4 "$DDNS" 2>/dev/null | awk 'NR==1 { print $1 }') || true
        if [[ -n $resolved ]]; then
            printf '4 %s' "$resolved"
            return
        fi
        resolved=$(timeout "$DNS_TIMEOUT" getent ahostsv6 "$DDNS" 2>/dev/null | awk 'NR==1 { print $1 }') || true
        if [[ -n $resolved ]]; then
            printf '6 %s' "$resolved"
        fi
        return
    fi
    if [[ -n ${IP:-} ]]; then
        if [[ $IP == *:* ]]; then
            printf '6 %s' "$IP"
        else
            printf '4 %s' "$IP"
        fi
    fi
}

public_ip() {
    local family="$1"
    local args=("-${family}" -fsSL --max-time "$PROBE_TIMEOUT")
    [[ -n ${BEARER:-} ]] && args+=(-H "Authorization: Bearer ${BEARER}")
    curl "${args[@]}" "https://ipinfo.io" 2>/dev/null | jq -r '.ip // empty' 2>/dev/null || true
}

check_external_reachability() {
    local iface="$1"
    local -a urls
    read -ra urls <<< "$PROBE_URLS"   # split on whitespace without globbing
    local url
    for url in "${urls[@]}"; do
        if curl -fsS --interface "$iface" --max-time "$PROBE_TIMEOUT" -o /dev/null "$url" 2>/dev/null; then
            return 0
        fi
        log "probe failed via ${iface}: ${url}"
    done
    return 1
}

check_ip_leak() {
    local target family target_ip
    target="$(resolve_check_ip)"

    if [[ -z $target ]]; then
        # DDNS was configured but resolved to nothing: we cannot tell whether
        # traffic is leaking, and broken DNS is itself a symptom.
        [[ -n ${DDNS:-} ]] && unhealthy "DDNS ${DDNS} did not resolve to an address"
        return 0
    fi

    family="${target%% *}"
    target_ip="${target#* }"

    local express_ip
    express_ip="$(public_ip "$family")"
    if [[ -z $express_ip ]]; then
        # Reachability already proved the tunnel is alive, so a third-party
        # lookup being unavailable should not take the container down.
        log "WARNING: could not determine public IPv${family}; skipping leak check"
        return 0
    fi

    if [[ "$target_ip" == "$express_ip" ]]; then
        # The supervisor cannot detect this on its own: the client still reports
        # Connected, so ask it explicitly to rebuild the tunnel.
        request_reconnect
        unhealthy "public IP ${express_ip} matches ${DDNS:-$IP} - traffic is NOT going through the VPN"
    fi
}

main() {
    [[ -f "$FAILURE_FLAG" ]] && unhealthy "supervisor reported repeated reconnect failures"

    local state
    state="$(timeout 3s expressvpnctl get connectionstate 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n $state && $state != "Connected" ]]; then
        unhealthy "connection state is ${state}"
    fi

    local iface
    iface="$(vpn_interface)"
    [[ -n $iface ]] || unhealthy "no VPN interface present"

    check_external_reachability "$iface" \
        || unhealthy "no external connectivity through ${iface} (tried: ${PROBE_URLS})"

    check_ip_leak

    healthy
}

main
