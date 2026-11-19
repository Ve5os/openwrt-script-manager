#!/bin/sh
set -eu
REPO="Ve5os/openwrt-script-manager"
BRANCH="main"
ARCHIVE_URL="https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz"
BASE="/etc/openwrt-script-manager"
WEB="/www-script-manager"
[ "$(id -u)" = "0" ] || { echo "Run as root."; exit 1; }
TMP="/tmp/openwrt-script-manager-install.$$"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
mkdir -p "$TMP"
echo "==> Downloading OpenWrt Script Manager from GitHub..."
if command -v wget >/dev/null 2>&1;then wget -qO "$TMP/repo.tar.gz" "$ARCHIVE_URL";elif command -v uclient-fetch >/dev/null 2>&1;then uclient-fetch -qO "$TMP/repo.tar.gz" "$ARCHIVE_URL";else echo "ERROR: wget or uclient-fetch is required.";exit 1;fi
tar -xzf "$TMP/repo.tar.gz" -C "$TMP"
ROOT="$(find "$TMP" -maxdepth 2 -type f -name README.md -print 2>/dev/null|head -n1|sed 's#/README.md$##')"
[ -n "$ROOT" ]||{ echo "ERROR: repository not found.";exit 1; }
for f in www/index.html www/app.js www/style.css cgi-bin/api.sh;do [ -f "$ROOT/$f" ]||{ echo "ERROR: missing $f";exit 1;};done
mkdir -p "$BASE/scripts" "$BASE/logs" "$BASE/sessions" "$WEB/cgi-bin"
cp "$ROOT/www/index.html" "$WEB/index.html"
cp "$ROOT/www/app.js" "$WEB/app.js"
cp "$ROOT/www/style.css" "$WEB/style.css"
cp "$ROOT/cgi-bin/api.sh" "$WEB/cgi-bin/api.sh"
chmod 644 "$WEB/index.html" "$WEB/app.js" "$WEB/style.css"
chmod 755 "$WEB/cgi-bin/api.sh"
touch "$BASE/config" "$BASE/users"
chmod 600 "$BASE/config" "$BASE/users"
mkdir -p /etc/crontabs;touch /etc/crontabs/root;chmod 600 /etc/crontabs/root
if ! uci -q get uhttpd.script_manager >/dev/null 2>&1;then sid="$(uci add uhttpd uhttpd)";uci rename "uhttpd.$sid=script_manager";fi
uci set uhttpd.script_manager.listen_http='0.0.0.0:9696'
uci set uhttpd.script_manager.home="$WEB"
uci set uhttpd.script_manager.cgi_prefix='/cgi-bin'
uci set uhttpd.script_manager.index_page='index.html'
uci set uhttpd.script_manager.error_page='/index.html'
uci commit uhttpd
/etc/init.d/uhttpd restart
echo "=============================================="
echo "OpenWrt Script Manager — build 2026.11.19.09"
echo "Open: http://ROUTER_IP:9696"
echo "=============================================="
