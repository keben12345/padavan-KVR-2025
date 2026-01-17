#!/bin/sh
# Cloudflare DDNS for Padavan
# Ultra Stable Daemon Edition

BIN_NAME="cloudflare.sh"
LOG_FILE="/tmp/cloudflare.log"
PID_FILE="/var/run/cloudflare.pid"

CURL_OPT="-k -s --connect-timeout 5 --max-time 15"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ---------- NVRAM ----------
ENABLE=$(nvram get cloudflare_enable)
INTERVAL=$(nvram get cloudflare_interval)
TOKEN=$(nvram get cloudflare_token)
DOMAIN=$(nvram get cloudflare_domain)
HOST=$(nvram get cloudflare_host)
LAST_IPV4=$(nvram get cloudflare_last_ip)
LAST_IPV6=$(nvram get cloudflare_last_ipv6)

[ -z "$INTERVAL" ] && INTERVAL=600
FQDN="${HOST}.${DOMAIN}"

# ---------- IP ----------
get_ipv4() {
    curl $CURL_OPT https://ipv4.icanhazip.com | tr -d '\n'
}

get_ipv6() {
    ip -6 addr show dev ppp0 2>/dev/null \
        | awk '/inet6.*scope global/{print $2}' \
        | cut -d/ -f1 | head -n1
}

# ---------- Cloudflare API ----------
cf_api() {
    curl $CURL_OPT -H "Authorization: Bearer $TOKEN" "$@"
}

cf_api_json() {
    curl $CURL_OPT -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" "$@"
}

api_success() {
    echo "$1" | grep -q '"success"[[:space:]]*:[[:space:]]*true'
}

get_zone_id() {
    RESP=$(cf_api "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN") || return 1
    api_success "$RESP" || return 1
    echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*"name":"'"$DOMAIN"'".*/\1/p'
}

get_record_ids() {
    TYPE="$1"
    RESP=$(cf_api \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$TYPE&name=$FQDN") || return 1
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

    RESP=$(cf_api_json -X POST \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        --data "{\"type\":\"$TYPE\",\"name\":\"$FQDN\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":false}")
    api_success "$RESP"
}

cleanup_duplicates() {
    TYPE="$1"
    KEEP_IP="$2"

    IDS=$(get_record_ids "$TYPE") || return

    echo "$IDS" | while read ID IP; do
        [ "$IP" != "$KEEP_IP" ] && \
        curl $CURL_OPT -X DELETE \
            -H "Authorization: Bearer $TOKEN" \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$ID" >/dev/null && \
        log "Deleted duplicate $TYPE record ($IP)"
    done
}

ddns_once() {
    ZONE_ID=$(get_zone_id)
    [ -z "$ZONE_ID" ] && return

    IPV4=$(get_ipv4)
    IPV6=$(get_ipv6)

    [ -n "$IPV4" ] && [ "$IPV4" != "$LAST_IPV4" ] && \
    update_record "A" "$IPV4" && \
    cleanup_duplicates "A" "$IPV4" && \
    nvram set cloudflare_last_ip="$IPV4" && \
    LAST_IPV4="$IPV4" && \
    log "Updated $FQDN -> $IPV4"

    [ -n "$IPV6" ] && [ "$IPV6" != "$LAST_IPV6" ] && \
    update_record "AAAA" "$IPV6" && \
    cleanup_duplicates "AAAA" "$IPV6" && \
    nvram set cloudflare_last_ipv6="$IPV6" && \
    LAST_IPV6="$IPV6" && \
    log "Updated $FQDN -> $IPV6"
}

daemon() {
    log "Cloudflare DDNS daemon started (pid $$)"
    while true; do
        ddns_once || true
        log "Heartbeat: daemon alive"
        sleep "$INTERVAL" || sleep 600
    done
}

check_pid() {
    [ -f "$PID_FILE" ] || return 1
    kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

case "$1" in
    start)
        [ "$ENABLE" != "1" ] && exit 0
        check_pid && exit 0
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
