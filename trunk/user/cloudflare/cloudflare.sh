#!/bin/sh
# Cloudflare DDNS for Padavan (Optimized Stable Edition)
# Only update when IP changed
# Supports PPPoE / DHCP
# Heartbeat + Lock + Auto recovery

BIN_NAME="cloudflare.sh"
LOG_FILE="/tmp/cloudflare.log"
PID_FILE="/var/run/cloudflare.pid"

ENABLE=$(nvram get cloudflare_enable)
INTERVAL=$(nvram get cloudflare_interval)
TOKEN=$(nvram get cloudflare_token)
DOMAIN=$(nvram get cloudflare_domain)
HOST=$(nvram get cloudflare_host)

[ -z "$INTERVAL" ] && INTERVAL=600

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# -------------------------------
# Get WAN IPv4 (PPPoE first)
# -------------------------------
get_wan_ip() {
    local ip

    ip=$(ifconfig ppp0 2>/dev/null | awk '/inet addr/ {print $2}' | cut -d: -f2)
    [ -n "$ip" ] && echo "$ip" && return 0

    ip=$(nvram get wan_ipaddr)
    [ "$ip" != "0.0.0.0" ] && echo "$ip" && return 0

    return 1
}

# -------------------------------
# Cloudflare API Wrapper
# -------------------------------
cf_api() {
    curl -s -m 15 \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        "$@"
}

# -------------------------------
# Update DNS Record
# -------------------------------
update_record() {
    local TYPE="$1"
    local IP="$2"
    local FQDN="$HOST.$DOMAIN"

    # Get Zone ID
    local ZONE_ID
    ZONE_ID=$(cf_api "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        | grep -o '"id":"[^"]*"' | head -n1 | cut -d'"' -f4)

    [ -z "$ZONE_ID" ] && log "ERROR: Failed to get Zone ID" && return 1

    # Get Record ID
    local RID
    RID=$(cf_api \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$TYPE&name=$FQDN" \
        | grep -o '"id":"[^"]*"' | head -n1 | cut -d'"' -f4)

    if [ -n "$RID" ]; then
        # Update
        cf_api -X PUT \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RID" \
            --data "{\"type\":\"$TYPE\",\"name\":\"$FQDN\",\"content\":\"$IP\",\"ttl\":120,\"proxied\":false}" \
            >/dev/null
    else
        # Create
        cf_api -X POST \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
            --data "{\"type\":\"$TYPE\",\"name\":\"$FQDN\",\"content\":\"$IP\",\"ttl\":120,\"proxied\":false}" \
            >/dev/null
    fi

    log "Updated $TYPE -> $IP"
}

# -------------------------------
# Daemon loop
# -------------------------------
daemon_loop() {
    log "Cloudflare DDNS daemon started (pid $$), interval=${INTERVAL}s"

    LAST_IP=""

    while true; do
        WAN_IP=$(get_wan_ip)

        if [ -z "$WAN_IP" ]; then
            log "ERROR: Failed to get WAN IP"
        else
            if [ "$WAN_IP" != "$LAST_IP" ]; then
                log "IP changed: $LAST_IP -> $WAN_IP"
                update_record "A" "$WAN_IP" && LAST_IP="$WAN_IP"
            else
                log "Heartbeat OK (IP unchanged: $WAN_IP)"
            fi
        fi

        sleep "$INTERVAL"
    done
}

# -------------------------------
# Process Control
# -------------------------------
start() {
    if pidof "$BIN_NAME" >/dev/null; then
        echo "Already running."
        exit 0
    fi

    nohup "$0" daemon >/dev/null 2>&1 &
}

stop() {
    killall "$BIN_NAME" 2>/dev/null
    rm -f "$PID_FILE"
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




