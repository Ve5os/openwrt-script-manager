#!/bin/sh
set -eu

# ============================================================
# OpenWrt Script Manager
# GitHub bootstrap installer
#
# Normal installation from GitHub:
#   sh -c "$(wget -qO- https://raw.githubusercontent.com/OWNER/REPO/main/install.sh)"
#
# The first line below is the only repository setting that must
# be changed once the project is published.
# ============================================================

GITHUB_REPO="${GITHUB_REPO:-OWNER/REPO}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

BASE="/etc/openwrt-script-manager"
LIB="/usr/lib/openwrt-script-manager"
WEB="/www/openwrt-script-manager"
INIT="/etc/init.d/openwrt-script-manager"

[ "$(id -u)" = "0" ] || { echo "Run as root."; exit 1; }

TMP="/tmp/openwrt-script-manager-install.$$"
ARCHIVE="$TMP/repo.tar.gz"
SRC="$TMP/src"

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT

download_repo() {
    mkdir -p "$TMP"
    URL="https://github.com/$GITHUB_REPO/archive/refs/heads/$GITHUB_BRANCH.tar.gz"
    echo "Downloading OpenWrt Script Manager from GitHub..."
    if command -v wget >/dev/null 2>&1; then
        wget -qO "$ARCHIVE" "$URL" || {
            echo "Download failed: $URL"
            exit 1
        }
    else
        echo "wget is required."
        exit 1
    fi
    mkdir -p "$SRC"
    tar -xzf "$ARCHIVE" -C "$SRC"
    ROOT="$(find "$SRC" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [ -n "$ROOT" ] || { echo "Invalid GitHub archive."; exit 1; }
}

install_files() {
    mkdir -p "$BASE/scripts" "$BASE/logs" "$LIB" "$WEB"

    cp "$ROOT/files/usr/lib/openwrt-script-manager/server.sh" "$LIB/server.sh"
    cp "$ROOT/files/usr/lib/openwrt-script-manager/manager.sh" "$LIB/manager.sh"
    cp "$ROOT/files/usr/lib/openwrt-script-manager/auth.sh" "$LIB/auth.sh"
    cp "$ROOT/files/etc/init.d/openwrt-script-manager" "$INIT"
    cp "$ROOT/files/www/openwrt-script-manager/index.html" "$WEB/index.html"
    cp "$ROOT/files/www/openwrt-script-manager/app.js" "$WEB/app.js"
    cp "$ROOT/files/www/openwrt-script-manager/style.css" "$WEB/style.css"

    chmod 755 "$LIB/server.sh" "$LIB/manager.sh" "$LIB/auth.sh" "$INIT" "$WEB/app.js"
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
}

setup_password() {
    if grep -q '^PASSWORD_HASH=' "$BASE/config" 2>/dev/null; then
        echo "Existing Script Manager password retained."
        return
    fi

    printf "Enter the OpenWrt/LuCI admin password for Script Manager.\n"
    printf "Password: "
    stty -echo
    IFS= read -r PW
    stty echo
    printf "\n"

    HASH="$(printf '%s' "$PW" | "$LIB/auth.sh" hash)"
    unset PW
    printf 'PASSWORD_HASH=%s\n' "$HASH" >> "$BASE/config"
}

restart_service() {
    "$INIT" enable
    "$INIT" restart
}

download_repo
install_files
setup_password
restart_service

echo
echo "=============================================="
echo "OpenWrt Script Manager installed successfully"
echo "=============================================="
echo
echo "Open:      http://ROUTER_IP:9696"
echo "Repository: https://github.com/$GITHUB_REPO"
echo "Uninstall: sh /usr/lib/openwrt-script-manager/uninstall.sh"
echo
