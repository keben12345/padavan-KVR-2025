#!/bin/sh

############################################
# Cloudflare DDNS for Padavan (Fixed Daemon)
############################################

LOG_FILE="/tmp/cloudflare.log"
PID_FILE="/var/run/cloudflare.pid"

INTERVAL="$(nvram get cloudflare_interval)"
[ -z "$INTERVAL" ] && INTERVAL=600

DOMAIN="$(nvram get cloudflare_domain)"
API_TOKEN="$(nvram get cloudflare_token)"
ZONE_ID="$(nvram get cloudflare_zone_id)"
RECORD_ID="$(nvram get cloudflare_record_id)"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

get_wan_ip() {
    curl -s --connect-timeout 10 https://api.ipify.org
}

update_dns() {
    WAN_IP="$(get_wan_ip)"

    if [ -z "$WAN_IP" ]; then
        log "ERROR: Failed to get WAN IP"
        return
    fi

    RESPONSE="$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${DOMAIN}\",\"content\":\"${WAN_IP}\",\"ttl\":120,\"proxied\":false}")"

    echo "$RESPONSE" | grep -q "\"success\":true"
    if [ $? -eq 0 ]; then
        log "Updated ${DOMAIN} -> ${WAN_IP}"
    else
        log "ERROR: Update failed: $RESPONSE"
    fi
}

daemon_loop() {
    echo $$ > "$PID_FILE"
    log "Cloudflare DDNS daemon started (pid $$), interval=${INTERVAL}s"

    while true; do
        update_dns
        sleep "$INTERVAL"
    done
}

start() {
    if [ -f "$PID_FILE" ]; then
        PID="$(cat $PID_FILE)"
        if kill -0 "$PID" 2>/dev/null; then
            echo "Cloudflare already running (pid $PID)"
            exit 0
        fi
    fi

    nohup sh -c "$(realpath $0) daemon" >/dev/null 2>&1 &
    sleep 1
    echo "Cloudflare started."
}

stop() {
    if [ -f "$PID_FILE" ]; then
        PID="$(cat $PID_FILE)"
        kill "$PID" 2>/dev/null
        rm -f "$PID_FILE"
        echo "Cloudflare stopped."
    else
        echo "Cloudflare not running."
    fi
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        stop
        sleep 1
        start
        ;;
    daemon)
        daemon_loop
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        ;;
esac
