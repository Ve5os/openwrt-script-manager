#!/bin/sh
set -eu

# OpenWrt Script Manager - GitHub installer
# Repository: https://github.com/Ve5os/openwrt-script-manager
# Install:
#   sh -c "$(wget -qO- https://raw.githubusercontent.com/Ve5os/openwrt-script-manager/refs/heads/main/install.sh)"

REPO="Ve5os/openwrt-script-manager"
BRANCH="main"

BASE="/etc/openwrt-script-manager"
LIB="/usr/lib/openwrt-script-manager"
WEB="/www/openwrt-script-manager"
INIT="/etc/init.d/openwrt-script-manager"

[ "$(id -u)" = "0" ] || {
    echo "ERROR: run this installer as root."
    exit 1
}

TMP="/tmp/openwrt-script-manager-install.$$"
ARCHIVE="$TMP/repo.tar.gz"
mkdir -p "$TMP"

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

echo "==> Downloading OpenWrt Script Manager from GitHub..."

URL="https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz"

if ! command -v wget >/dev/null 2>&1; then
    echo "ERROR: wget is required."
    exit 1
fi

if ! wget -qO "$ARCHIVE" "$URL"; then
    echo "ERROR: failed to download:"
    echo "       $URL"
    exit 1
fi

mkdir -p "$TMP/src"

if ! tar -xzf "$ARCHIVE" -C "$TMP/src"; then
    echo "ERROR: failed to unpack GitHub archive."
    exit 1
fi

ROOT="$(find "$TMP/src" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

if [ -z "$ROOT" ] || [ ! -d "$ROOT/files" ]; then
    echo "ERROR: repository has an invalid structure."
    exit 1
fi

echo "==> Installing files..."

mkdir -p "$BASE/scripts" "$BASE/logs" "$LIB" "$WEB"

cp "$ROOT/files/usr/lib/openwrt-script-manager/server.sh" "$LIB/server.sh"
cp "$ROOT/files/usr/lib/openwrt-script-manager/manager.sh" "$LIB/manager.sh"
cp "$ROOT/files/usr/lib/openwrt-script-manager/auth.sh" "$LIB/auth.sh"

cp "$ROOT/files/etc/init.d/openwrt-script-manager" "$INIT"

cp "$ROOT/files/www/openwrt-script-manager/index.html" "$WEB/index.html"
cp "$ROOT/files/www/openwrt-script-manager/app.js" "$WEB/app.js"
cp "$ROOT/files/www/openwrt-script-manager/style.css" "$WEB/style.css"

chmod 755 \
    "$LIB/server.sh" \
    "$LIB/manager.sh" \
    "$LIB/auth.sh" \
    "$INIT" \
    "$WEB/app.js"

chmod 700 "$BASE" "$BASE/scripts" "$BASE/logs"

touch "$BASE/config"
chmod 600 "$BASE/config"

if ! grep -q '^PORT=' "$BASE/config" 2>/dev/null; then
    cat > "$BASE/config" <<EOF
PORT=9696
BIND=0.0.0.0
SESSION_MINUTES=30
EOF
fi

mkdir -p /etc/crontabs
touch /etc/crontabs/root
chmod 600 /etc/crontabs/root

if ! grep -q '^PASSWORD_HASH=' "$BASE/config" 2>/dev/null; then
    echo
    echo "=============================================="
    echo "Script Manager administrator password"
    echo "=============================================="
    echo "Use the same password you use for LuCI."
    echo

    printf "Password: "
    stty -echo
    IFS= read -r PW
    stty echo
    printf "\n"

    HASH="$(printf '%s' "$PW" | "$LIB/auth.sh" hash)"
    unset PW

    printf 'PASSWORD_HASH=%s\n' "$HASH" >> "$BASE/config"
else
    echo "==> Existing Script Manager password retained."
fi

echo "==> Enabling service..."

"$INIT" enable
"$INIT" restart

sleep 1

echo
echo "=============================================="
echo " OpenWrt Script Manager installed"
echo "=============================================="
echo
echo " URL:"
echo "   http://ROUTER_IP:9696"
echo
echo " Repository:"
echo "   https://github.com/$REPO"
echo
echo " Uninstall:"
echo "   sh /usr/lib/openwrt-script-manager/uninstall.sh"
echo
