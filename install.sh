#!/bin/sh
set -eu

BASE="/etc/openwrt-script-manager"
WEB="/www/openwrt-script-manager"
LIB="/usr/lib/openwrt-script-manager"
INIT="/etc/init.d/openwrt-script-manager"
HTTPD_CONF="/etc/config/openwrt-script-manager"

[ "$(id -u)" = "0" ] || { echo "Run as root."; exit 1; }

mkdir -p "$BASE/scripts" "$BASE/logs" "$LIB" "$WEB"

cp files/usr/lib/openwrt-script-manager/server.sh "$LIB/server.sh"
cp files/usr/lib/openwrt-script-manager/manager.sh "$LIB/manager.sh"
cp files/usr/lib/openwrt-script-manager/auth.sh "$LIB/auth.sh"
cp files/etc/init.d/openwrt-script-manager "$INIT"
cp files/www/openwrt-script-manager/index.html "$WEB/index.html"
cp files/www/openwrt-script-manager/app.js "$WEB/app.js"
cp files/www/openwrt-script-manager/style.css "$WEB/style.css"

chmod 755 "$LIB/server.sh" "$LIB/manager.sh" "$LIB/auth.sh" "$INIT"
chmod 755 "$WEB/app.js"
chmod 700 "$BASE" "$BASE/scripts" "$BASE/logs"

touch "$BASE/config"
touch "$BASE/users"
chmod 600 "$BASE/config" "$BASE/users"

# Default port and bind address.
if ! grep -q '^PORT=' "$BASE/config" 2>/dev/null; then
    cat > "$BASE/config" <<EOF
PORT=9696
BIND=0.0.0.0
SESSION_MINUTES=30
EOF
fi

# Store an admin password hash derived from the current LuCI/root password.
# We intentionally do not copy the plaintext password.
if ! grep -q '^PASSWORD_HASH=' "$BASE/config" 2>/dev/null; then
    printf "Enter the OpenWrt root/LuCI password to protect Script Manager.\n"
    printf "Password: "
    stty -echo
    IFS= read -r PW
    stty echo
    printf "\n"
    HASH="$(printf '%s' "$PW" | "$LIB/auth.sh" hash)"
    unset PW
    printf 'PASSWORD_HASH=%s\n' "$HASH" >> "$BASE/config"
fi

# Make sure the cron file exists.
mkdir -p /etc/crontabs
touch /etc/crontabs/root
chmod 600 /etc/crontabs/root

# Ensure the service is enabled and started.
"$INIT" enable
"$INIT" restart

echo
echo "OpenWrt Script Manager installed."
echo "Open: http://ROUTER_IP:9696"
echo "Uninstall: sh /usr/lib/openwrt-script-manager/uninstall.sh"
