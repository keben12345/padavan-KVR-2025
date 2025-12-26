#!/bin/sh
#
# Padavan Native Cloudflare DDNS
#

BIN="/usr/bin/cloudflare.sh"
LOG="/tmp/cloudflare.log"
PID="/var/run/cloudflare.pid"

### ====== NVRAM ======
ENABLE="$(nvram get cloudflare_enable)"
INTERVAL="$(nvram get cloudflare_interval)"
TOKEN="$(nvram get cloudflare_token)"
DOMAIN="$(nvram get cloudflare_domain)"
HOST="$(nvram get cloudflare_host)"

# 兼容历史拼写错误
[ -z "$DOMAIN" ] && DOMAIN="$(nvram get cloudflare_domian)"

[ -z "$INTERVAL" ] && INTERVAL=600
[ -z "$HOST" ] && HOST="@"

RECORD_NAME="$HOST.$DOMAIN"
[ "$HOST" = "@" ] && RECORD_NAME="$DOMAIN"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> $LOG
}

get_wan_ip() {
    curl -k -s https://ipv4.icanhazip.com | tr -d '\n'
}

get_zone_id() {
    curl -k -s -H "Authorization: Bearer $TOKEN" \
        "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
    | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1
}

get_record_id() {
    curl -k -s -H "Authorization: Bearer $TOKEN" \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$RECORD_NAME" \
    | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1
}

create_record() {
    log "Creating DNS record $RECORD_NAME"
    curl -k -s -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        --data "{\"type\":\"A\",\"name\":\"$RECORD_NAME\",\"content\":\"$WAN_IP\",\"ttl\":1,\"proxied\":false}" \
        | grep -q '"success":true'
}

update_record() {
    curl -k -s -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        --data "{\"type\":\"A\",\"name\":\"$RECORD_NAME\",\"content\":\"$WAN_IP\",\"ttl\":1,\"proxied\":false}" \
        | grep -q '"success":true'
}

ddns_update() {
    WAN_IP="$(get_wan_ip)"
    [ -z "$WAN_IP" ] && log "Failed to get WAN IP" && return

    ZONE_ID="$(get_zone_id)"
    [ -z "$ZONE_ID" ] && log "Zone not found: $DOMAIN" && return

    RECORD_ID="$(get_record_id)"
    if [ -z "$RECORD_ID" ]; then
        create_record || { log "Failed to create DNS record"; return; }
        RECORD_ID="$(get_record_id)"
    fi

    update_record && log "Updated $RECORD_NAME -> $WAN_IP"
}

daemon() {
    log "Cloudflare DDNS daemon started"
    while true; do
        ddns_update
        sleep "$INTERVAL"
    done
}

start() {
    [ "$ENABLE" != "1" ] && exit 0
    [ -f "$PID" ] && kill "$(cat $PID)" 2>/dev/null
    daemon &
    echo $! > "$PID"
}

stop() {
    [ -f "$PID" ] && kill "$(cat $PID)" && rm -f "$PID"
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    *) echo "Usage: $BIN {start|stop|restart}" ;;
esac
