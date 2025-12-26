#!/bin/sh
# Padavan Cloudflare DDNS (IPv4)
# Path: /usr/bin/cloudflare.sh

LOG="/tmp/cloudflare.log"
PID="/var/run/cloudflare.pid"

# ===== 从 nvram 读取 =====
ENABLE="$(nvram get cloudflare_enable)"
INTERVAL="$(nvram get cloudflare_interval)"
TOKEN="$(nvram get cloudflare_token)"
EMAIL="$(nvram get cloudflare_Email)"
GLOBAL_KEY="$(nvram get cloudflare_Key)"

HOST="$(nvram get cloudflare_host)"
DOMAIN="$(nvram get cloudflare_domian)"

[ -z "$INTERVAL" ] && INTERVAL=600

API="https://api.cloudflare.com/client/v4"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

auth_header() {
    if [ -n "$TOKEN" ]; then
        echo "-H Authorization: Bearer $TOKEN"
    else
        echo "-H X-Auth-Email: $EMAIL -H X-Auth-Key: $GLOBAL_KEY"
    fi
}

get_ipv4() {
    curl -k -s https://ipv4.icanhazip.com | tr -d '\n'
}

get_zone_id() {
    curl -k -s $(auth_header) \
        "$API/zones?name=$DOMAIN" |
        sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1
}

get_record_id() {
    curl -k -s $(auth_header) \
        "$API/zones/$ZONE_ID/dns_records?type=A&name=$FQDN" |
        sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1
}

create_record() {
    curl -k -s -X POST $(auth_header) \
        -H "Content-Type: application/json" \
        "$API/zones/$ZONE_ID/dns_records" \
        --data "{\"type\":\"A\",\"name\":\"$FQDN\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":false}" \
        | grep -q '"success":true'
}

update_record() {
    curl -k -s -X PUT $(auth_header) \
        -H "Content-Type: application/json" \
        "$API/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        --data "{\"type\":\"A\",\"name\":\"$FQDN\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":false}" \
        | grep -q '"success":true'
}

ddns_update() {
    IP="$(get_ipv4)"
    [ -z "$IP" ] && log "Failed to get public IP" && return

    FQDN="$HOST.$DOMAIN"

    ZONE_ID="$(get_zone_id)"
    if [ -z "$ZONE_ID" ]; then
        log "Zone not found: $DOMAIN"
        return
    fi

    RECORD_ID="$(get_record_id)"

    if [ -z "$RECORD_ID" ]; then
        log "Record not found, creating: $FQDN"
        create_record || { log "Create record failed"; return; }
        RECORD_ID="$(get_record_id)"
    fi

    update_record || { log "Update record failed"; return; }

    nvram set cloudflare_last_ip="$IP"
    nvram set cloudflare_last_time="$(date '+%Y-%m-%d %H:%M:%S')"
    nvram commit

    log "Updated $FQDN -> $IP"
}

daemon() {
    log "Cloudflare DDNS daemon started"
    while [ "$ENABLE" = "1" ]; do
        ddns_update
        sleep "$INTERVAL"
        ENABLE="$(nvram get cloudflare_enable)"
    done
    log "Cloudflare DDNS daemon stopped"
}

start() {
    [ "$ENABLE" != "1" ] && exit 0
    [ -f "$PID" ] && kill "$(cat $PID)" 2>/dev/null
    daemon &
    echo $! > "$PID"
}

stop() {
    [ -f "$PID" ] && kill "$(cat $PID)" 2>/dev/null && rm -f "$PID"
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    *) echo "Usage: $0 {start|stop|restart}" ;;
esac
