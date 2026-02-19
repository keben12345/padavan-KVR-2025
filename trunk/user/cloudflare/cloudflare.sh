#!/bin/sh
# Cloudflare DDNS Ultimate Stable Edition for Padavan
# PPPoE Safe / WAN Hook Safe / No Missed Updates

BIN="cloudflare.sh"
LOG="/tmp/cloudflare.log"
PID_FILE="/var/run/cloudflare.pid"
ZONE_CACHE="/tmp/cloudflare_zoneid"

CURL_OPT="-k -s --connect-timeout 5 --max-time 15"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
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

# ---------------- IP Detection ----------------
get_ipv4() {
    ip addr show dev ppp0 2>/dev/null \
        | awk '/inet /{print $2}' \
        | cut -d/ -f1
}

get_ipv6() {
    ip -6 addr show dev ppp0 2>/dev/null \
        | awk '/inet6.*scope global/{print $2}' \
        | cut -d/ -f1 | head -n1
}

# ---------------- Cloudflare API ----------------
cf_api() {
    curl $CURL_OPT -H "Authorization: Bearer $TOKEN" "$@"
}

cf_api_json() {
    curl $CURL_OPT \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" "$@"
}

api_success() {
    echo "$1" | grep -q '"success":[[:space:]]*true'
}

get_zone_id() {

    if [ -f "$ZONE_CACHE" ]; then
        cat "$ZONE_CACHE"
        return
    fi

    RESP=$(cf_api "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN")
    api_success "$RESP" || return 1

    ZONE_ID=$(echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*"name":"'"$DOMAIN"'".*/\1/p')
    [ -n "$ZONE_ID" ] && echo "$ZONE_ID" > "$ZONE_CACHE"
    echo "$ZONE_ID"
}

get_record_id() {
    TYPE="$1"
    RESP=$(cf_api \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$TYPE&name=$FQDN")

    api_success "$RESP" || return 1

    echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1
}

update_record() {

    TYPE="$1"
    IP="$2"

    RID=$(get_record_id "$TYPE")

    if [ -n "$RID" ]; then
        RESP=$(cf_api_json -X PUT \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RID" \
            --data "{\"type\":\"$TYPE\",\"name\":\"$FQDN\",\"content\":\"$IP\",\"ttl\":120,\"proxied\":false}")
    else
        RESP=$(cf_api_json -X POST \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
            --data "{\"type\":\"$TYPE\",\"name\":\"$FQDN\",\"content\":\"$IP\",\"ttl\":120,\"proxied\":false}")
    fi

    api_success "$RESP"
}

# ---------------- DDNS Core ----------------
ddns_once() {

    ZONE_ID=$(get_zone_id)
    [ -z "$ZONE_ID" ] && { log "Zone lookup failed"; return; }

    IPV4=$(get_ipv4)
    IPV6=$(get_ipv6)

    # ----- IPv4 -----
    if [ -n "$IPV4" ]; then
        if [ "$IPV4" != "$LAST_IPV4" ]; then
            log "IPv4 changed: $LAST_IPV4 -> $IPV4"
            if update_record "A" "$IPV4"; then
                nvram set cloudflare_last_ip="$IPV4"
                nvram commit
                LAST_IPV4="$IPV4"
                log "Updated A record -> $IPV4"
            else
                log "ERROR: IPv4 update failed"
            fi
        fi
    else
        log "IPv4 not detected"
    fi

    # ----- IPv6 -----
    if [ -n "$IPV6" ]; then
        if [ "$IPV6" != "$LAST_IPV6" ]; then
            log "IPv6 changed: $LAST_IPV6 -> $IPV6"
            if update_record "AAAA" "$IPV6"; then
                nvram set cloudflare_last_ipv6="$IPV6"
                nvram commit
                LAST_IPV6="$IPV6"
                log "Updated AAAA record -> $IPV6"
            else
                log "ERROR: IPv6 update failed"
            fi
        fi
    fi
}

# ---------------- Daemon ----------------
daemon_loop() {
    log "Cloudflare DDNS daemon started (pid $$)"
    while true; do
        ddns_once
        sleep "$INTERVAL"
    done
}

# ---------------- PID ----------------
check_pid() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        kill -0 "$PID" 2>/dev/null && return 0
        rm -f "$PID_FILE"
    fi
    return 1
}

# ---------------- Control ----------------
case "$1" in
    start)
        [ "$ENABLE" != "1" ] && exit 0
        check_pid && exit 0
        daemon_loop &
        echo $! > "$PID_FILE"
        ;;
    stop)
        [ -f "$PID_FILE" ] && kill "$(cat $PID_FILE)" 2>/dev/null
        rm -f "$PID_FILE" "$ZONE_CACHE"
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
    once)
        ddns_once
        ;;
    *)
        echo "Usage: $BIN {start|stop|restart|once}"
        ;;
esac
