#!/bin/sh
# Cloudflare DDNS for Padavan (PPPoE optimized)
# Final stable build version

BIN_NAME="cloudflare.sh"
LOG_FILE="/tmp/cloudflare.log"
PID_FILE="/var/run/cloudflare.pid"

# ---------------- Log ----------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ---------------- NVRAM ----------------
ENABLE=$(nvram get cloudflare_enable)
INTERVAL=$(nvram get cloudflare_interval)
TOKEN=$(nvram get cloudflare_token)
DOMAIN=$(nvram get cloudflare_domain)
HOST=$(nvram get cloudflare_host)
LAST_IPV4=$(nvram get cloudflare_last_ip)
LAST_IPV6=$(nvram get cloudflare_last_ipv6)

[ -z "$INTERVAL" ] && INTERVAL=600
FQDN="${HOST}.${DOMAIN}"

# ---------------- IP Detect ----------------
# PPPoE IPv4
get_ipv4() {
    ifconfig ppp0 2>/dev/null \
        | awk '/inet addr:/ {print $2}' \
        | cut -d: -f2
}

# PPPoE IPv6
get_ipv6() {
    ip -6 addr show dev ppp0 2>/dev/null \
        | awk '/scope global/ {print $2}' \
        | cut -d/ -f1 | head -n1
}

# ---------------- Cloudflare API ----------------
cf_api() {
    curl -k -s -H "Authorization: Bearer $TOKEN" "$@"
}

cf_api_json() {
    curl -k -s -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" "$@"
}

api_success() {
    echo "$1" | grep -q '"success"[[:space:]]*:[[:space:]]*true'
}

# ---------------- Zone / Record ----------------
get_zone_id() {
    RESP=$(cf_api "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN")
    api_success "$RESP" || return 1
    echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*"name":"'"$DOMAIN"'".*/\1/p'
}

get_record_ids() {
    TYPE="$1"
    RESP=$(cf_api \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$TYPE&name=$FQDN")
    api_success "$RESP" || return 1
    echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*"content":"\([^"]*\)".*/\1 \2/p'
}

update_record() {
    TYPE="$1"
    IP="$2"

    IDS=$(get_record_ids "$TYPE")
    RID=$(echo "$IDS" | head -n1 | awk '{print $1}')

    if [ -n "$RID" ]; then
        RESP=$(cf_api_json -X PUT \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RID" \
            --data "{\"type\":\"$TYPE\",\"name\":\"$FQDN\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":false}")
        api_success "$RESP" && return 0
        return 1
    fi

    log "Creating DNS record $FQDN ($TYPE)"
    RESP=$(cf_api_json -X POST \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        --data "{\"type\":\"$TYPE\",\"name\":\"$FQDN\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":false}")
    api_success "$RESP"
}

cleanup_duplicates() {
    TYPE="$1"
    KEEP_IP="$2"

    IDS=$(get_record_ids "$TYPE")
    [ -z "$IDS" ] && return

    KEEP_ID=$(echo "$IDS" | awk -v ip="$KEEP_IP" '$2==ip {print $1; exit}')

    [ -z "$KEEP_ID" ] && KEEP_ID=$(echo "$IDS" | head -n1 | awk '{print $1}')

    echo "$IDS" | while read ID IP; do
        [ "$ID" = "$KEEP_ID" ] && continue
        curl -k -s -X DELETE \
            -H "Authorization: Bearer $TOKEN" \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$ID" >/dev/null
        log "Deleted duplicate $TYPE record ($IP)"
    done
}

# ---------------- Core ----------------
ddns_once() {
    ZONE_ID=$(get_zone_id)
    [ -z "$ZONE_ID" ] && { log "ERROR: Zone not found: $DOMAIN"; return; }

    IPV4=$(get_ipv4)
    IPV6=$(get_ipv6)

    if [ -z "$IPV4" ]; then
        log "ERROR: Failed to get WAN IPv4"
    fi

    if [ -n "$IPV4" ] && [ "$IPV4" != "$LAST_IPV4" ]; then
        if update_record "A" "$IPV4"; then
            cleanup_duplicates "A" "$IPV4"
            nvram set cloudflare_last_ip="$IPV4"
            nvram commit
            log "Updated A $FQDN -> $IPV4"
        fi
    fi

    if [ -n "$IPV6" ] && [ "$IPV6" != "$LAST_IPV6" ]; then
        if update_record "AAAA" "$IPV6"; then
            cleanup_duplicates "AAAA" "$IPV6"
            nvram set cloudflare_last_ipv6="$IPV6"
            nvram commit
            log "Updated AAAA $FQDN -> $IPV6"
        fi
    fi
}

daemon() {
    log "Cloudflare DDNS daemon started (pid $$), interval=${INTERVAL}s"
    while true; do
        ddns_once
        sleep "$INTERVAL"
    done
}

# ---------------- Service ----------------
case "$1" in
    start)
        [ "$ENABLE" != "1" ] && exit 0

        if [ -f "$PID_FILE" ] && kill -0 "$(cat $PID_FILE)" 2>/dev/null; then
            exit 0
        fi

        daemon &
        echo $! > "$PID_FILE"
        ;;
    stop)
        [ -f "$PID_FILE" ] && kill "$(cat $PID_FILE)" 2>/dev/null
        rm -f "$PID_FILE"
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
    *)
        echo "Usage: $BIN_NAME {start|stop|restart}"
        ;;
esac

