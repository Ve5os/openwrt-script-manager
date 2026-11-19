#!/bin/sh
# Установщик OpenWrt Script Manager.
# Чисто обновляет файлы менеджера, не удаляя пользовательские скрипты.

set -eu

REPO_BASE="https://raw.githubusercontent.com/Ve5os/openwrt-script-manager/main"
TMP_DIR="/tmp/openwrt-script-manager-install.$$"
WEB_ROOT="/www-script-manager"
SCRIPT_DIR="/etc/my_scripts"

log() { printf '%s\n' "[script-manager] $*"; }
fail() { printf '%s\n' "[script-manager] ERROR: $*" >&2; rm -rf "$TMP_DIR" 2>/dev/null || true; exit 1; }
trap 'rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT INT TERM

command -v uci >/dev/null 2>&1 || fail "uci не найден. Установка рассчитана на OpenWrt."
command -v wget >/dev/null 2>&1 || fail "wget не найден."

log "Создаю временную директорию: $TMP_DIR"
mkdir -p "$TMP_DIR/www" "$TMP_DIR/cgi-bin"

fetch() {
    url="$1"
    out="$2"
    log "Скачиваю $url"
    if wget -q -O "$out" "$url"; then
        return 0
    fi
    if command -v curl >/dev/null 2>&1 && curl -fsSL -o "$out" "$url"; then
        return 0
    fi
    fail "Не удалось скачать $url"
}

fetch "$REPO_BASE/www/index.html" "$TMP_DIR/www/index.html"
fetch "$REPO_BASE/www/style.css" "$TMP_DIR/www/style.css"
fetch "$REPO_BASE/www/app.js" "$TMP_DIR/www/app.js"
fetch "$REPO_BASE/cgi-bin/api.sh" "$TMP_DIR/cgi-bin/api.sh"
fetch "$REPO_BASE/version" "$TMP_DIR/version"
VERSION="$(tr -d '\r\n ' < "$TMP_DIR/version")"
case "$VERSION" in
    ''|*[!0-9.]*|.*|*.) fail "Некорректная версия в $REPO_BASE/version: $VERSION" ;;
esac

# Важно: очищаем только файлы предыдущей установки менеджера.
# /etc/my_scripts не трогаем вообще — пользовательские скрипты должны сохраниться.
if [ -d "$WEB_ROOT" ]; then
    log "Удаляю файлы предыдущей сборки из $WEB_ROOT"
    rm -rf "$WEB_ROOT"
fi

log "Создаю каталоги"
mkdir -p "$WEB_ROOT/cgi-bin" "$SCRIPT_DIR"

log "Устанавливаю файлы интерфейса и CGI"
cp "$TMP_DIR/www/index.html" "$WEB_ROOT/index.html"
cp "$TMP_DIR/www/style.css" "$WEB_ROOT/style.css"
cp "$TMP_DIR/www/app.js" "$WEB_ROOT/app.js"
cp "$TMP_DIR/cgi-bin/api.sh" "$WEB_ROOT/cgi-bin/api.sh"
cp "$TMP_DIR/version" "$WEB_ROOT/version"
chmod 0755 "$WEB_ROOT/cgi-bin/api.sh"

# Сохраняем существующую конфигурацию uhttpd и не создаём дубликаты.
if ! uci -q get uhttpd.script_manager >/dev/null 2>&1; then
    log "Добавляю экземпляр uhttpd на порту 9696"
    sid="$(uci add uhttpd uhttpd)"
    uci rename "uhttpd.$sid=script_manager"
fi
uci set uhttpd.script_manager.listen_http='0.0.0.0:9696'
uci set uhttpd.script_manager.home="$WEB_ROOT"
uci set uhttpd.script_manager.cgi_prefix='/cgi-bin'
uci set uhttpd.script_manager.index_page='index.html'
uci set uhttpd.script_manager.error_page='/index.html'

auth_ref=''
if uci -q get uhttpd.script_manager.httpauth >/dev/null 2>&1; then
    auth_ref="$(uci -q get uhttpd.script_manager.httpauth || true)"
fi
if [ "$auth_ref" != 'script_manager_auth' ]; then
    log "Привязываю httpauth script_manager_auth"
    uci del_list uhttpd.script_manager.httpauth='script_manager_auth' 2>/dev/null || true
    uci add_list uhttpd.script_manager.httpauth='script_manager_auth'
fi

if ! uci -q get uhttpd.script_manager_auth >/dev/null 2>&1; then
    log "Добавляю секцию httpauth"
    aid="$(uci add uhttpd httpauth)"
    uci rename "uhttpd.$aid=script_manager_auth"
fi
uci set uhttpd.script_manager_auth.prefix='/'
uci set uhttpd.script_manager_auth.username='root'
uci set uhttpd.script_manager_auth.password='$p$root'

log "Проверяю jsonfilter"
if ! command -v jsonfilter >/dev/null 2>&1; then
    log "jsonfilter не найден — пытаюсь установить пакет"
    if ! opkg update || ! opkg install jsonfilter; then
        log "WARNING: jsonfilter установить не удалось. CGI использует fallback-парсер."
    fi
fi

log "Сохраняю конфигурацию uhttpd"
uci commit uhttpd

log "Перезапускаю uhttpd"
/etc/init.d/uhttpd restart

log "Перезагружаю cron"
/etc/init.d/cron reload 2>/dev/null || /etc/init.d/cron restart

# Автозапуск uhttpd сохраняем только один раз.
CRONTAB="/etc/crontabs/root"
mkdir -p /etc/crontabs
touch "$CRONTAB"
if ! grep -Fq '# OpenWrt Script Manager autostart' "$CRONTAB"; then
    printf '%s\n' '@reboot /etc/init.d/uhttpd start # OpenWrt Script Manager autostart' >> "$CRONTAB"
    /etc/init.d/cron reload 2>/dev/null || /etc/init.d/cron restart
fi

IP=""
IP="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
if [ -z "$IP" ]; then
    IP="$(hostname -i 2>/dev/null | awk '{print $1}')"
fi
[ -n "$IP" ] || IP="<router_ip>"

log "Установка завершена"
printf '\n========================================\n'
printf ' OpenWrt Script Manager\n'
printf ' Build: %s\n' "$VERSION"
printf ' URL: http://%s:9696\n' "$IP"
printf '========================================\n'
