#!/bin/sh
# Padavan Native Cloudflare DDNS
# Final Release Version

BIN="/usr/bin/cloudflare.sh"
LOG="/tmp/cloudflare.log"
PID="/var/run/cloudflare.pid"

# ===== 从 nvram 读取配置 =====
ENABLE="$(nvram get cloudflare_enable)"
INTERVAL="$(nvram get cloudflare_interval)"
CF_TOKEN="$(nvram get cloudflare_token)"
CF_EMAIL="$(nvram get cloudflare_email)"
HOST="$(nvram get cloudflare_host)"
DOMAIN="$(nvram get cloudflare_domain)"

[ -z "$INTERVAL" ] && INTERVAL=600
[ -z "$HOST" ] && HOST="@"

FQDN="$HOST.$DOMAIN"

log() {
    echo "[$(date '+%F %T')] $*" >> "$LOG"
}

get_wan_ip() {
    curl -k -s https://ipv4.icanhazip.com | tr -d '\n'
}

get_zone_id() {
    ZONE_ID=$(curl -k -s \
        -H "Authorization: Bearer $CF_TOKEN" \
        "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        | grep -o '"id":"[^"]*"' | head -n1 | cut -d'"' -f4)

    [ -z "$ZONE_ID" ] && return 1
    return 0
}

get_record_ids() {
    curl -k -s \
        -H "Authorization: Bearer $CF_TOKEN" \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$FQDN" \
        | grep -o '"id":"[^"]*"' | cut -d'"' -f4
}

cleanup_duplicate_records() {
    IDS="$(get_record_ids)"
    COUNT=$(echo "$IDS" | wc -l)

    [ "$COUNT" -le 1 ] && return

    KEEP_ID=$(echo "$IDS" | sed -n '1p')
    echo "$IDS" | sed '1d' | while read rid; do
        curl -k -s -X DELETE \
            -H "Authorization: Bearer $CF_TOKEN" \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$rid" >/dev/null
        log "Deleted duplicate record id=$rid"
    done

    RECORD_ID="$KEEP_ID"
}

create_record() {
    IP="$1"
    log "Creating DNS record $FQDN"

    RES=$(curl -k -s -X POST \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        --data "{\"type\":\"A\",\"name\":\"$FQDN\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":false}")

    echo "$RES" | grep -q '"success":true'
}

update_record() {
    IP="$1"
    IDS="$(get_record_ids)"

    if [ -z "$IDS" ]; then
        create_record "$IP" || return 1
        IDS="$(get_record_ids)"
    fi

    cleanup_duplicate_records
    RECORD_ID="$(get_record_ids | head -n1)"

    RES=$(curl -k -s -X PUT \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        --data "{\"type\":\"A\",\"name\":\"$FQDN\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":false}")

    echo "$RES" | grep -q '"success":true'
}

ddns_loop() {
    log "Cloudflare DDNS daemon started"

    if ! get_zone_id; then
        log "Zone not found: $DOMAIN"
        sleep "$INTERVAL"
        return
    fi

    while true; do
        IP="$(get_wan_ip)"
        [ -z "$IP" ] && sleep "$INTERVAL" && continue

        LAST_IP="$(nvram get cloudflare_last_ip)"

        if [ "$IP" != "$LAST_IP" ]; then
            if update_record "$IP"; then
                nvram set cloudflare_last_ip="$IP"
                nvram set cloudflare_last_time="$(date '+%F %T')"
                nvram commit
                log "Updated $FQDN -> $IP"
            else
                log "Failed to update $FQDN"
            fi
        fi

        sleep "$INTERVAL"
    done
}

start() {
    [ "$ENABLE" != "1" ] && exit 0
    [ -f "$PID" ] && exit 0

    ddns_loop &
    echo $! > "$PID"
}

stop() {
    [ -f "$PID" ] && kill "$(cat $PID)" 2>/dev/null
    rm -f "$PID"
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart)
        stop
        sleep 1
        start
        ;;
    *)
        echo "Usage: $BIN {start|stop|restart}"
        ;;
esac


