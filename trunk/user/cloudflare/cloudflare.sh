#!/bin/sh
#
# Padavan Native Cloudflare DDNS
# A + AAAA, auto create, auto cleanup duplicates
#

BIN_NAME="cloudflare.sh"
LOG_FILE="/tmp/cloudflare.log"

################################
# Utils
################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

cf_api() {
    METHOD="$1"
    URI="$2"
    DATA="$3"

    if [ -n "$DATA" ]; then
        curl -k -s -X "$METHOD" \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H "Content-Type: application/json" \
            --data "$DATA" \
            "https://api.cloudflare.com/client/v4$URI"
    else
        curl -k -s -X "$METHOD" \
            -H "Authorization: Bearer $CF_TOKEN" \
            "https://api.cloudflare.com/client/v4$URI"
    fi
}

################################
# NVRAM
################################

CF_ENABLE="$(nvram get cloudflare_enable)"
CF_TOKEN="$(nvram get cloudflare_token)"
DOMAIN="$(nvram get cloudflare_domain)"
HOST="$(nvram get cloudflare_host)"
INTERVAL="$(nvram get cloudflare_interval)"

[ -z "$INTERVAL" ] && INTERVAL=600
[ -z "$HOST" ] && HOST="@"

################################
# IP functions
################################

get_ipv4() {
    curl -k -s https://ipv4.icanhazip.com | tr -d '\n'
}

get_ipv6() {
    ip -6 addr show dev ppp0 2>/dev/null \
    | awk '/inet6/{print $2}' \
    | grep -v '^fe80' \
    | head -n1 \
    | cut -d/ -f1
}

################################
# Cloudflare functions
################################

get_zone_id() {
    ZONE_ID="$(cf_api GET "/zones?name=$DOMAIN" \
        | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1)"
}

get_record_ids() {
    TYPE="$1"
    NAME="$HOST.$DOMAIN"
    cf_api GET "/zones/$ZONE_ID/dns_records?type=$TYPE&name=$NAME" \
        | sed -n 's/.*"id":"\([^"]*\)".*/\1/p'
}

cleanup_duplicates() {
    TYPE="$1"
    IDS="$(get_record_ids "$TYPE")"

    KEEP=1
    for ID in $IDS; do
        if [ "$KEEP" = "1" ]; then
            KEEP=0
            continue
        fi
        log "Deleting duplicate $TYPE record ($ID)"
        cf_api DELETE "/zones/$ZONE_ID/dns_records/$ID"
    done
}

create_record() {
    TYPE="$1"
    IP="$2"
    NAME="$HOST.$DOMAIN"

    log "Creating DNS record $NAME ($TYPE)"
    cf_api POST "/zones/$ZONE_ID/dns_records" \
        "{\"type\":\"$TYPE\",\"name\":\"$NAME\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":false}" \
        | grep -q '"success":true'
}

update_record() {
    TYPE="$1"
    IP="$2"

    [ -z "$IP" ] && return

    IDS="$(get_record_ids "$TYPE")"

    if [ -z "$IDS" ]; then
        create_record "$TYPE" "$IP" || log "Failed to create $TYPE record"
        return
    fi

    ID="$(echo "$IDS" | head -n1)"

    RESP="$(cf_api PUT "/zones/$ZONE_ID/dns_records/$ID" \
        "{\"type\":\"$TYPE\",\"name\":\"$HOST.$DOMAIN\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":false}")"

    echo "$RESP" | grep -q '"success":true' && \
        log "Updated $HOST.$DOMAIN ($TYPE) -> $IP"
}

################################
# Main loop
################################

run_ddns() {
    get_zone_id
    [ -z "$ZONE_ID" ] && log "Zone not found: $DOMAIN" && return

    cleanup_duplicates A
    cleanup_duplicates AAAA

    IPV4="$(get_ipv4)"
    IPV6="$(get_ipv6)"

    LAST_IPV4="$(nvram get cloudflare_last_ipv4)"
    LAST_IPV6="$(nvram get cloudflare_last_ipv6)"

    if [ "$IPV4" != "$LAST_IPV4" ]; then
        update_record A "$IPV4"
        nvram set cloudflare_last_ipv4="$IPV4"
    fi

    if [ "$IPV6" != "$LAST_IPV6" ]; then
        update_record AAAA "$IPV6"
        nvram set cloudflare_last_ipv6="$IPV6"
    fi

    nvram set cloudflare_last_update="$(date '+%Y-%m-%d %H:%M:%S')"
    nvram commit
}

daemon() {
    log "Cloudflare DDNS daemon started"
    while true; do
        run_ddns
        sleep "$INTERVAL"
    done
}

################################
# Control
################################

case "$1" in
start)
    [ "$CF_ENABLE" != "1" ] && exit 0
    daemon &
    ;;
stop)
    killall "$BIN_NAME" 2>/dev/null
    ;;
restart)
    killall "$BIN_NAME" 2>/dev/null
    sleep 1
    daemon &
    ;;
*)
    echo "Usage: $BIN_NAME {start|stop|restart}"
    ;;
esac



