#!/bin/sh
# Padavan Cloudflare DDNS (final)
# compatible with Advanced_cloudflare.asp

BIN="/usr/bin/cloudflare.sh"
LOG="/tmp/cloudflare.log"
PID="/var/run/cloudflare.pid"

UA="Padavan-Cloudflare-DDNS"

log() {
	echo "[$(date '+%F %T')] $*" >> $LOG
}

nv() { nvram get "$1"; }

get_ip4() {
	curl -s --max-time 5 https://ipv4.icanhazip.com | tr -d '\n'
}

get_ip6() {
	ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | head -n1
}

cf_auth() {
	if [ -n "$(nv cloudflare_token)" ]; then
		echo "-H Authorization: Bearer $(nv cloudflare_token)"
	else
		echo "-H X-Auth-Email: $(nv cloudflare_Email) -H X-Auth-Key: $(nv cloudflare_Key)"
	fi
}

cf_api() {
	curl -s -X "$1" "https://api.cloudflare.com/client/v4$2" \
		-H "Content-Type: application/json" \
		$(cf_auth) \
		${3:+--data "$3"}
}

get_zone_id() {
	DOMAIN="$1"
	cf_api GET "/zones?name=$DOMAIN" | sed -n 's/.*"id":"\([^"]*\)".*"name":"'"$DOMAIN"'".*/\1/p'
}

get_record_id() {
	ZONE="$1"; TYPE="$2"; NAME="$3"
	cf_api GET "/zones/$ZONE/dns_records?type=$TYPE&name=$NAME" \
	| sed -n 's/.*"id":"\([^"]*\)".*/\1/p'
}

update_record() {
	TYPE="$1"; HOST="$2"; DOMAIN="$3"; IP="$4"
	FQDN="$HOST.$DOMAIN"

	ZONE_ID=$(get_zone_id "$DOMAIN")
	[ -z "$ZONE_ID" ] && log "Zone not found: $DOMAIN" && return 1

	RECORD_ID=$(get_record_id "$ZONE_ID" "$TYPE" "$FQDN")

	DATA="{\"type\":\"$TYPE\",\"name\":\"$FQDN\",\"content\":\"$IP\",\"ttl\":120,\"proxied\":false}"

	if [ -z "$RECORD_ID" ]; then
		log "Creating $TYPE $FQDN -> $IP"
		cf_api POST "/zones/$ZONE_ID/dns_records" "$DATA" >> $LOG
	else
		log "Updating $TYPE $FQDN -> $IP"
		cf_api PUT "/zones/$ZONE_ID/dns_records/$RECORD_ID" "$DATA" >> $LOG
	fi
}

ddns_update() {
	[ "$(nv cloudflare_enable)" != "1" ] && return

	IP4=$(get_ip4)
	[ -n "$(nv cloudflare_domian)" ] && [ -n "$(nv cloudflare_host)" ] && \
		update_record A "$(nv cloudflare_host)" "$(nv cloudflare_domian)" "$IP4"

	if [ -n "$(nv cloudflare_domian6)" ] && [ -n "$(nv cloudflare_host6)" ]; then
		IP6=$(get_ip6)
		[ -n "$IP6" ] && update_record AAAA "$(nv cloudflare_host6)" "$(nv cloudflare_domian6)" "$IP6"
	fi

	nvram set cloudflare_last_ip="$IP4"
	nvram set cloudflare_last_update="$(date '+%F %T')"
}

daemon() {
	echo $$ > $PID
	log "Cloudflare DDNS daemon started"

	while [ "$(nv cloudflare_enable)" = "1" ]; do
		ddns_update
		sleep "$(nv cloudflare_interval 2>/dev/null || echo 600)"
	done

	log "Cloudflare DDNS daemon stopped"
	rm -f $PID
}

case "$1" in
	start)
		[ -f $PID ] && exit 0
		$BIN daemon &
		;;
	stop)
		[ -f $PID ] && kill "$(cat $PID)" && rm -f $PID
		;;
	restart)
		$BIN stop
		sleep 1
		$BIN start
		;;
	update)
		ddns_update
		;;
	daemon)
		daemon
		;;
	*)
		echo "Usage: $BIN {start|stop|restart|update}"
		;;
esac
