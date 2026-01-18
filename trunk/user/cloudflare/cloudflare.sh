#!/bin/sh
# Cloudflare DDNS for Padavan
# Firmware stable edition

BIN="cloudflare.sh"
LOG="/tmp/cloudflare.log"
PID="/var/run/cloudflare.pid"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# ---------- NVRAM ----------
ENABLE="$(nvram get cloudflare_enable)"
INTERVAL="$(nvram get cloudflare_interval)"
TOKEN="$(nvram get cloudflare_token)"
DOMAIN="$(nvram get cloudflare_domain)"
HOST="$(nvram get cloudflare_host)"
LAST4="$(nvram get cloudflare_last_ip)"
LAST6="$(nvram get cloudflare_last_ipv6)"

[ -z "$INTERVAL" ] && INTERVAL=600
FQDN="${HOST}.${DOMAIN}"

# ---------- IP detect ----------
get_ipv4() {
    ip addr show dev ppp0 2>/dev/null \
    | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1
}

get_ipv6() {
    ip -6 addr show dev ppp0 2>/dev/null \
    | awk '/inet6.*scope global/{print $2}' \
    | cut -d/ -f1 | head -n1
}

# ---------- Cloudflare API ----------
cf_api() {
    curl -k -s -H "Authorization: Bearer $TOKEN" "$@"
}

cf_api_json() {
    curl -k -s -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" "$@"
}

api_ok() {
    echo "$1" | grep -q '"success"[[:space:]]*:[[:space:]]*true'
}

get_zone_id() {
    R=$(cf_api "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN")
    api_ok "$R" || return 1
    echo "$R" | sed -n 's/.*"id":"\([^"]*\)".*"name":"'"$DOMAIN"'".*/\1/p'
}

get_record_ids() {
    TYPE="$1"
    cf_api "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$TYPE&name=$FQDN" \
    | sed -n 's/.*"id":"\([^"]*\)".*"content":"\([^"]*\)".*/\1 \2/p'
}

update_record() {
    TYPE="$1"
    IP="$2"

    IDS="$(get_record_ids "$TYPE")"
    RID="$(echo "$IDS" | head -n1 | awk '{print $1}')"

    if [ -n "$RID" ]; then
        R=$(cf_api_json -X PUT \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RID" \
            --data "{\"type\":\"$TYPE\",\"name\":\"$FQDN\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":false}")
        api_ok "$R" && return 0
        return 1
    fi

    log "Creating $TYPE record $FQDN"
    R=$(cf_api_json -X POST \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        --data "{\"type\":\"$TYPE\",\"name\":\"$FQDN\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":false}")
    api_ok "$R"
}

cleanup_duplicates() {
    TYPE="$1"
    KEEP="$2"

    get_record_ids "$TYPE" | while read ID IP; do
        [ "$IP" = "$KEEP" ] && continue
        curl -k -s -X DELETE \
            -H "Authorization: Bearer $TOKEN" \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$ID" >/dev/null
        log "Deleted duplicate $TYPE ($IP)"
    done
}

ddns_once() {
    ZONE_ID="$(get_zone_id)"
    [ -z "$ZONE_ID" ] && { log "ERROR: Zone not found"; return; }

    IPV4="$(get_ipv4)"
    IPV6="$(get_ipv6)"

    [ -z "$IPV4" ] && log "WARN: No IPv4 detected"
    [ -z "$IPV6" ] && log "WARN: No IPv6 detected"

    if [ -n "$IPV4" ] && [ "$IPV4" != "$LAST4" ]; then
        if update_record "A" "$IPV4"; then
            cleanup_duplicates "A" "$IPV4"
            nvram set cloudflare_last_ip="$IPV4"
            nvram commit
            log "Updated A -> $IPV4"
        fi
    fi

    if [ -n "$IPV6" ] && [ "$IPV6" != "$LAST6" ]; then
        if update_record "AAAA" "$IPV6"; then
            cleanup_duplicates "AAAA" "$IPV6"
            nvram set cloudflare_last_ipv6="$IPV6"
            nvram commit
            log "Updated AAAA -> $IPV6"
        fi
    fi
}

daemon() {
    log "Cloudflare DDNS daemon started (pid $$, interval=${INTERVAL}s)"
    while true; do
        ddns_once
        sleep "$INTERVAL"
        log "Heartbeat OK"
    done
}

case "$1" in
    start)
        [ "$ENABLE" != "1" ] && exit 0
        if [ -f "$PID" ] && kill -0 "$(cat $PID)" 2>/dev/null; then
            exit 0
        fi
        daemon &
        echo $! > "$PID"
        ;;
    stop)
        [ -f "$PID" ] && kill "$(cat $PID)" 2>/dev/null
        rm -f "$PID"
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
    *)
        echo "Usage: $BIN {start|stop|restart}"
        ;;
esac



