#!/bin/sh
# Padavan Native Cloudflare DDNS (IPv4)
# Mode: daemon + interval loop
# Auth: API Token
# Author: final patched version

BIN_NAME="cloudflare-ddns"
LOG="/tmp/cloudflare.log"
PID="/var/run/cloudflare.pid"

# ===== NVRAM =====
ENABLE="$(nvram get cloudflare_enable)"
INTERVAL="$(nvram get cloudflare_interval)"
TOKEN="$(nvram get cloudflare_token)"
HOST="$(nvram get cloudflare_host)"
DOMAIN="$(nvram get cloudflare_domian)"

[ -z "$INTERVAL" ] && INTERVAL=600
[ -z "$HOST" ] && HOST="@"

FQDN="$HOST.$DOMAIN"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

get_wan_ip() {
    curl -k -s https://ipv4.icanhazip.com | tr -d '\n'
}

api() {
    curl -k -s \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        "$@"
}

get_zone_id() {
    api "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
    | sed -n 's/.*"id":"\([^"]*\)".*"name":"'"$DOMAIN"'".*/\1/p'
}

get_record_id() {
    api "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$FQDN" \
    | sed -n 's/.*"id":"\([^"]*\)".*/\1/p'
}

create_record() {
    log "Creating DNS record $FQDN"
    RESULT=$(curl -k -s -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        --data "{\"type\":\"A\",\"name\":\"$FQDN\",\"content\":\"$WAN_IP\",\"ttl\":1,\"proxied\":false}")

    echo "$RESULT" | grep -q '"success":true'
}

update_record() {
    curl -k -s -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        --data "{\"type\":\"A\",\"name\":\"$FQDN\",\"content\":\"$WAN_IP\",\"ttl\":1,\"proxied\":false}" \
        | grep -q '"success":true'
}

do_update() {
    WAN_IP="$(get_wan_ip)"
    [ -z "$WAN_IP" ] && return

    ZONE_ID="$(get_zone_id)"
    if [ -z "$ZONE_ID" ]; then
        log "Zone not found: $DOMAIN"
        return
    fi

    RECORD_ID="$(get_record_id)"

    if [ -z "$RECORD_ID" ]; then
        create_record || {
            log "Failed to create DNS record"
            return
        }
        RECORD_ID="$(get_record_id)"
    fi

    update_record && {
        nvram set cloudflare_last_ip="$WAN_IP"
        nvram set cloudflare_last_update="$(date '+%Y-%m-%d %H:%M:%S')"
        nvram commit
        log "Updated $FQDN -> $WAN_IP"
    }
}

daemon() {
    log "Cloudflare DDNS daemon started"
    while true; do
        [ "$(nvram get cloudflare_enable)" = "1" ] && do_update
        sleep "$INTERVAL"
    done
}

start() {
    [ "$ENABLE" != "1" ] && exit 0
    [ -f "$PID" ] && exit 0
    daemon &
    echo $! > "$PID"
}

stop() {
    [ -f "$PID" ] && kill "$(cat $PID)" 2>/dev/null
    rm -f "$PID"
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; sleep 1; start ;;
    *) echo "Usage: $0 {start|stop|restart}" ;;
esac

