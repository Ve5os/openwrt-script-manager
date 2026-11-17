#!/bin/sh
set -eu

BASE="/etc/openwrt-script-manager"
LIB="/usr/lib/openwrt-script-manager"
WEB="/www/openwrt-script-manager"
INIT="/etc/init.d/openwrt-script-manager"

[ "$(id -u)" = "0" ] || { echo "Run as root."; exit 1; }

if [ -f /etc/crontabs/root ]; then
    tmp="/tmp/osm-cron.$$"
    awk '
      /^# BEGIN OPENWRT-SCRIPT-MANAGER$/ { skip=1; next }
      /^# END OPENWRT-SCRIPT-MANAGER$/ { skip=0; next }
      !skip { print }
    ' /etc/crontabs/root > "$tmp"
    cat "$tmp" > /etc/crontabs/root
    rm -f "$tmp"
fi

"$INIT" stop 2>/dev/null || true
"$INIT" disable 2>/dev/null || true
rm -f "$INIT"
rm -rf "$LIB" "$WEB"

# Keep scripts, logs and config. This is intentional.
echo "Service removed. User scripts/configuration remain in $BASE."
