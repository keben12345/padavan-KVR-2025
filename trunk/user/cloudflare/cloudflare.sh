#!/bin/sh
#
# Padavan Native Cloudflare DDNS
# Compatible with Advanced_cloudflare.asp (NO ASP MOD REQUIRED)
#

LOGGER="cloudflare-ddns"
API="https://api.cloudflare.com/client/v4"

BIN_NAME="cloudflare.sh"

#################################
# Utils
#################################

log() {
    logger -t "$LOGGER" "$@"
}

get_wan_ipv4() {
    curl -s --connect-timeout 5 https://api.ipify.org
}

get_wan_ipv6() {
    ip -6 addr show scope global 2>/dev/null | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1
}

#################################
# Auth Header
#################################

build_auth() {
    CF_TOKEN="$(nvram get cloudflare_token)"
    CF_EMAIL="$(nvram get cloudflare_Email)"
    CF_KEY="$(nvram get cloudflare_Key)"

    if [ -n "$CF_TOKEN" ]; then
        AUTH_H="-H Authorization:\ Bearer\ $CF_TOKEN"
    elif [ -n "$CF_EMAIL" ] && [ -n "$CF_KEY" ]; then
        AUTH_H="-H X-Auth-Email:\ $CF_EMAIL -H X-Auth-Key:\ $CF_KEY"
    else
        log "No Cloudflare API auth configured"
        return 1
    fi
    return 0
}

#################################
# Zone & Record
#################################

get_zone_id() {
    ZONE="$1"
    eval curl -s $AUTH_H "$API/zones?name=$ZONE" \
        | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1
}

get_record_id() {
    ZONE_ID="$1"
    NAME="$2"
    TYPE="$3"
    eval curl -s $AUTH_H "$API/zones/$ZONE_ID/dns_records?type=$TYPE&name=$NAME" \
        | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1
}

create_record() {
    ZONE_ID="$1"
    NAME="$2"
    TYPE="$3"
    IP="$4"

    log "Creating $TYPE record $NAME -> $IP"

    eval curl -s -X POST $AUTH_H \
        -H Content-Type:\ application/json \
        --data "{\"type\":\"$TYPE\",\"name\":\"$NAME\",\"content\":\"$IP\",\"ttl\":120,\"proxied\":false}" \
        "$API/zones/$ZONE_ID/dns_records" >/dev/null
}

update_record() {
    ZONE_ID="$1"
    RID="$2"
    TYPE="$3"
    NAME="$4"
    IP="$5"

    log "Updating $TYPE record $NAME -> $IP"

    eval curl -s -X PUT $AUTH_H \
        -H Content-Type:\ application/json \
        --data "{\"type\":\"$TYPE\",\"name\":\"$NAME\",\"content\":\"$IP\",\"ttl\":120,\"proxied\":false}" \
        "$API/zones/$ZONE_ID/dns_records/$RID" >/dev/null
}

#################################
# Update Logic
#################################

update_one() {
    HOST="$1"
    DOMAIN="$2"
    TYPE="$3"
    IP="$4"

    [ -z "$HOST" ] || [ -z "$DOMAIN" ] || [ -z "$IP" ] && return

    NAME="$HOST.$DOMAIN"

    ZONE_ID="$(get_zone_id "$DOMAIN")"
    [ -z "$ZONE_ID" ] && log "Zone not found: $DOMAIN" && return

    RID="$(get_record_id "$ZONE_ID" "$NAME" "$TYPE")"

    if [ -z "$RID" ]; then
        create_record "$ZONE_ID" "$NAME" "$TYPE" "$IP"
    else
        update_record "$ZONE_ID" "$RID" "$TYPE" "$NAME" "$IP"
    fi
}

#################################
# Main Loop
#################################

daemon() {
    INTERVAL="$(nvram get cloudflare_interval)"
    [ -z "$INTERVAL" ] && INTERVAL=600

    while [ "$(nvram get cloudflare_enable)" = "1" ]; do
        build_auth || sleep "$INTERVAL"

        IPV4="$(get_wan_ipv4)"
        IPV6="$(get_wan_ipv6)"

        update_one "$(nvram get cloudflare_host)"  "$(nvram get cloudflare_domian)"  "A"    "$IPV4"
        update_one "$(nvram get cloudflare_host2)" "$(nvram get cloudflare_domian2)" "A"    "$IPV4"
        update_one "$(nvram get cloudflare_host6)" "$(nvram get cloudflare_domian6)" "AAAA" "$IPV6"

        [ -n "$IPV4" ] && nvram set cloudflare_last_ip="$IPV4"
        [ -n "$IPV6" ] && nvram set cloudflare_last_ipv6="$IPV6"
        nvram set cloudflare_last_update="$(date '+%Y-%m-%d %H:%M:%S')"
        nvram commit

        sleep "$INTERVAL"
    done
}

#################################
# Control
#################################

case "$1" in
    start)
        killall "$BIN_NAME" 2>/dev/null
        daemon &
        ;;
    stop)
        killall "$BIN_NAME" 2>/dev/null
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        ;;
esac
