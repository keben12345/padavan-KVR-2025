#!/bin/sh

if [ "$(nvram get cloudflare_enable)" = "1" ]; then
    logger -t cloudflare-ddns "WAN up detected, force updating DDNS"
    /usr/bin/cloudflare.sh once &
fi
