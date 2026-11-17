#!/bin/sh
set -eu

BASE="/etc/openwrt-script-manager"
WEB="/www/openwrt-script-manager"
LIB="/usr/lib/openwrt-script-manager"
INIT="/etc/init.d/openwrt-script-manager"

REPO="Ve5os/openwrt-script-manager"
BRANCH="main"
ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

[ "$(id -u)" = "0" ] || { echo "Run as root."; exit 1; }

TMP="/tmp/openwrt-script-manager-install.$$"
ARCHIVE="$TMP/repo.tar.gz"

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

echo "==> Downloading OpenWrt Script Manager from GitHub..."
mkdir -p "$TMP"

if command -v wget >/dev/null 2>&1; then
    wget -qO "$ARCHIVE" "$ARCHIVE_URL"
elif command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -qO "$ARCHIVE" "$ARCHIVE_URL"
else
    echo "ERROR: wget or uclient-fetch is required."
    exit 1
fi

echo "==> Extracting..."
tar -xzf "$ARCHIVE" -C "$TMP"

ROOT="$(find "$TMP" -maxdepth 2 -type f -name 'README.md' -print 2>/dev/null | head -n 1 | sed 's#/README.md$##')"
[ -n "$ROOT" ] || {
    echo "ERROR: Could not find the extracted repository."
    exit 1
}

[ -f "$ROOT/files/usr/lib/openwrt-script-manager/server.sh" ] || {
    echo "ERROR: Repository contents are incomplete."
    exit 1
}

echo "==> Installing files..."

mkdir -p "$BASE/scripts" "$BASE/logs" "$BASE/sessions" "$LIB" "$WEB"

cp "$ROOT/files/usr/lib/openwrt-script-manager/server.sh" "$LIB/server.sh"
cp "$ROOT/files/usr/lib/openwrt-script-manager/manager.sh" "$LIB/manager.sh"
cp "$ROOT/files/usr/lib/openwrt-script-manager/auth.sh" "$LIB/auth.sh"
cp "$ROOT/files/etc/init.d/openwrt-script-manager" "$INIT"
cp "$ROOT/files/www/openwrt-script-manager/index.html" "$WEB/index.html"
cp "$ROOT/files/www/openwrt-script-manager/app.js" "$WEB/app.js"
cp "$ROOT/files/www/openwrt-script-manager/style.css" "$WEB/style.css"

chmod 755 "$LIB/server.sh" "$LIB/manager.sh" "$LIB/auth.sh" "$INIT"
chmod 644 "$WEB/index.html" "$WEB/app.js" "$WEB/style.css"
chmod 700 "$BASE" "$BASE/scripts" "$BASE/logs" "$BASE/sessions"

# Keep existing configuration on reinstall.
touch "$BASE/config"
touch "$BASE/users"
chmod 600 "$BASE/config" "$BASE/users"

if ! grep -q '^PORT=' "$BASE/config" 2>/dev/null; then
    cat >> "$BASE/config" <<EOF
PORT=9696
BIND=0.0.0.0
SESSION_MINUTES=30
EOF
fi

# Create the manager password only on first installation.
if ! grep -q '^PASSWORD_HASH=' "$BASE/config" 2>/dev/null; then
    echo
    echo "=============================================="
    echo "Script Manager administrator password"
    echo "=============================================="
    echo "Use the same password you use for LuCI."

    # OpenWrt images can be built without the stty applet.
    # In that case BusyBox 'read -s' also cannot hide input.
    if command -v stty >/dev/null 2>&1; then
        printf "Password: "
        stty -echo
        IFS= read -r PW
        stty echo
        printf "\n"
    else
        echo
        echo "NOTE: this OpenWrt image has no 'stty' applet."
        echo "The password will be visible while you type it."
        printf "Password: "
        IFS= read -r PW
        printf "\n"
    fi

    [ -n "${PW:-}" ] || {
        echo "ERROR: Password cannot be empty."
        exit 1
    }

    HASH="$(printf '%s' "$PW" | "$LIB/auth.sh" hash)"
    unset PW

    printf 'PASSWORD_HASH=%s\n' "$HASH" >> "$BASE/config"
fi

mkdir -p /etc/crontabs
touch /etc/crontabs/root
chmod 600 /etc/crontabs/root

echo "==> Enabling service..."
"$INIT" enable

echo "==> Starting service..."
"$INIT" restart

echo
echo "=============================================="
echo "OpenWrt Script Manager installed successfully."
echo "=============================================="
echo "Open:      http://ROUTER_IP:9696"
echo "Repository: https://github.com/${REPO}"
echo "Uninstall:  sh /usr/lib/openwrt-script-manager/uninstall.sh"
