#!/bin/sh
# Cloudflare DDNS for Padavan
# Final stable daemon version

BIN_NAME="cloudflare.sh"
LOG_FILE="/tmp/cloudflare.log"
PID_FILE="/var/run/cloudflare.pid"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> $LOG_FILE
}

# ---------- IP ----------
get_ipv4() {
    curl -k -s https://ipv4.icanhazip.com | tr -d '\n'
}

get_ipv6() {
    ip -6 addr show dev ppp0 2>/dev/null \
    | awk '/inet6.*scope global/{print $2}' \
    | cut -d/ -f1 | head -n1
}

# ---------- Cloudflare ----------
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

get_zone_id() {
    RESP=$(cf_api "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN")
    api_success "$RESP" || return 1
    echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*"name":"'"$DOMAIN"'".*/\1/p'
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

    RESP=$(cf_api \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$TYPE&name=$FQDN")
    api_success "$RESP" || return

    IDS=$(echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*"content":"\([^"]*\)".*/\1 \2/p')

    KEEP_ID=$(echo "$IDS" | awk -v ip="$KEEP_IP" '$2==ip{print $1;exit}')
    [ -z "$KEEP_ID" ] && KEEP_ID=$(echo "$IDS" | head -n1 | awk '{print $1}')

    echo "$IDS" | while read ID IP; do
        [ "$ID" = "$KEEP_ID" ] && continue
        curl -k -s -X DELETE \
            -H "Authorization: Bearer $TOKEN" \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$ID" >/dev/null
        log "Deleted duplicate $TYPE record ($IP)"
    done
}

ddns_once() {
    # ---- 每次循环重新读取 nvram ----
    ENABLE=$(nvram get cloudflare_enable)
    INTERVAL=$(nvram get cloudflare_interval)
    TOKEN=$(nvram get cloudflare_token)
    DOMAIN=$(nvram get cloudflare_domain)
    HOST=$(nvram get cloudflare_host)
    LAST_IPV4=$(nvram get cloudflare_last_ip)
    LAST_IPV6=$(nvram get cloudflare_last_ipv6)

    [ "$ENABLE" != "1" ] && return
    [ -z "$INTERVAL" ] && INTERVAL=600

    FQDN="${HOST}.${DOMAIN}"

    ZONE_ID=$(get_zone_id)
    [ -z "$ZONE_ID" ] && { log "Zone not found: $DOMAIN"; return; }

    IPV4=$(get_ipv4)
    IPV6=$(get_ipv6)

    if [ -n "$IPV4" ] && [ "$IPV4" != "$LAST_IPV4" ]; then
        if update_record "A" "$IPV4"; then
            cleanup_duplicates "A" "$IPV4"
            nvram set cloudflare_last_ip="$IPV4"
            nvram commit
            log "Updated $FQDN -> $IPV4"
        fi
    fi

    if [ -n "$IPV6" ] && [ "$IPV6" != "$LAST_IPV6" ]; then
        if update_record "AAAA" "$IPV6"; then
            cleanup_duplicates "AAAA" "$IPV6"
            nvram set cloudflare_last_ipv6="$IPV6"
            nvram commit
            log "Updated $FQDN -> $IPV6"
        fi
    fi
}

daemon_loop() {
    log "Cloudflare DDNS daemon started (pid $$)"
    while true; do
        ddns_once
        sleep "${INTERVAL:-600}"
    done
}

is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat $PID_FILE)" 2>/dev/null
}

start() {
    if is_running; then
        echo "Already running"
        exit 0
    fi

    (
        daemon_loop
    ) </dev/null >/dev/null 2>&1 &

    echo $! > "$PID_FILE"
}

stop() {
    if is_running; then
        kill "$(cat $PID_FILE)" 2>/dev/null
    fi
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
    *)
        echo "Usage: $BIN_NAME {start|stop|restart}"
        ;;
esac





