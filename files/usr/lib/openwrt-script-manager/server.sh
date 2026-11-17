#!/bin/sh
set -eu

BASE="/etc/openwrt-script-manager"
LIB="/usr/lib/openwrt-script-manager"
WEB="/www/openwrt-script-manager"

. "$BASE/config"

PORT="${PORT:-9696}"
BIND="${BIND:-0.0.0.0}"
DOCROOT="$WEB"
PIDFILE="$BASE/httpd.pid"

# BusyBox httpd provides CGI execution and static files. The CGI endpoint below
# is generated dynamically as a small shell program.
CGI="$WEB/cgi-bin"
mkdir -p "$CGI"

cat > "$CGI/api" <<'CGI'
#!/bin/sh
set -eu

BASE="/etc/openwrt-script-manager"
LIB="/usr/lib/openwrt-script-manager"
SCRIPTS="$BASE/scripts"
WEB="/www/openwrt-script-manager"

. "$BASE/config"

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g; s/\r/\\r/g; s/\n/\\n/g'
}

get_param() {
    key="$1"
    data="${QUERY_STRING:-}"
    oldIFS="$IFS"
    IFS='&'
    for pair in $data; do
        k="${pair%%=*}"
        v="${pair#*=}"
        [ "$k" = "$key" ] || continue
        printf '%s' "$v" | sed 's/+/ /g; s/%20/ /g; s/%2F/\//g; s/%3A/:/g; s/%2E/./g; s/%5F/_/g; s/%2D/-/g'
        IFS="$oldIFS"
        return
    done
    IFS="$oldIFS"
}

# Simple session cookie. Session tokens are random and stored in root-only files.
cookie_session() {
    printf '%s' "${HTTP_COOKIE:-}" | sed -n 's/.*osm_session=\([^;]*\).*/\1/p'
}

session_ok() {
    s="$(cookie_session)"
    [ -n "$s" ] && [ -f "$BASE/sessions/$s" ]
}

send_json() {
    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    printf '%s\n' "$1"
}

mkdir -p "$BASE/sessions"
chmod 700 "$BASE/sessions"

action="$(get_param action || true)"

if [ "$action" = "login" ]; then
    pw="$(get_param password || true)"
    stored="${PASSWORD_HASH:-}"
    if [ -n "$stored" ] && "$LIB/auth.sh" verify "$stored" "$pw"; then
        token="$(hexdump -n 24 -e '24/1 "%02x"' /dev/urandom 2>/dev/null || date +%s)"
        : > "$BASE/sessions/$token"
        chmod 600 "$BASE/sessions/$token"
        printf 'Content-Type: application/json\r\nSet-Cookie: osm_session=%s; HttpOnly; SameSite=Strict; Path=/\r\nCache-Control: no-store\r\n\r\n' "$token"
        printf '{"ok":true}\n'
    else
        send_json '{"ok":false,"error":"Неверный пароль"}'
    fi
    exit 0
fi

if [ "$action" = "logout" ]; then
    s="$(cookie_session)"
    [ -n "$s" ] && rm -f "$BASE/sessions/$s"
    printf 'Content-Type: application/json\r\nSet-Cookie: osm_session=; Max-Age=0; HttpOnly; SameSite=Strict; Path=/\r\nCache-Control: no-store\r\n\r\n'
    printf '{"ok":true}\n'
    exit 0
fi

if ! session_ok; then
    send_json '{"ok":false,"auth":false}'
    exit 0
fi

case "$action" in
    list)
        printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
        printf '{"ok":true,"scripts":['
        first=1
        for meta in "$SCRIPTS"/*.meta; do
            [ -f "$meta" ] || continue
            unset ID PATH MIN HOUR DOM MON DOW ENABLED NAME
            . "$meta"
            [ "$first" = 1 ] || printf ','
            first=0
            content=""
            [ -f "$PATH" ] && content="$(cat "$PATH")"
            printf '{"id":"%s","name":"%s","path":"%s","enabled":%s,"minute":"%s","hour":"%s","dom":"%s","month":"%s","dow":"%s","content":"%s"}' \
                "$(json_escape "${ID:-}")" \
                "$(json_escape "${NAME:-}")" \
                "$(json_escape "${PATH:-}")" \
                "${ENABLED:-0}" \
                "$(json_escape "${MIN:-*}")" \
                "$(json_escape "${HOUR:-*}")" \
                "$(json_escape "${DOM:-*}")" \
                "$(json_escape "${MON:-*}")" \
                "$(json_escape "${DOW:-*}")" \
                "$(json_escape "$content")"
        done
        printf ']}\n'
        ;;

    save)
        id="$(get_param id || true)"
        name="$(get_param name || true)"
        path="$(get_param path || true)"
        minute="$(get_param minute || true)"
        hour="$(get_param hour || true)"
        dom="$(get_param dom || true)"
        month="$(get_param month || true)"
        dow="$(get_param dow || true)"
        enabled="$(get_param enabled || true)"
        content="$(get_param content || true)"

        id="$(printf '%s' "$id" | tr -cd 'A-Za-z0-9_-')"
        case "$path" in
            /usr/bin/*.sh|/etc/openwrt-script-manager/scripts/*.sh) ;;
            *) send_json '{"ok":false,"error":"Разрешены только .sh в /usr/bin или /etc/openwrt-script-manager/scripts"}'; exit 0 ;;
        esac
        [ -n "$id" ] || { send_json '{"ok":false,"error":"Не указан ID"}'; exit 0; }
        [ -n "$name" ] || name="$id"

        meta="$SCRIPTS/$id.meta"
        mkdir -p "$SCRIPTS"
        printf '%s\n' "$content" > "$path"
        chmod 755 "$path"

        {
            printf 'ID=%s\n' "$id"
            printf 'NAME=%s\n' "$(printf '%s' "$name" | sed "s/'/'\\\\''/g")"
            printf 'PATH=%s\n' "$path"
            printf 'MIN=%s\n' "${minute:-*}"
            printf 'HOUR=%s\n' "${hour:-*}"
            printf 'DOM=%s\n' "${dom:-*}"
            printf 'MON=%s\n' "${month:-*}"
            printf 'DOW=%s\n' "${dow:-*}"
            printf 'ENABLED=%s\n' "${enabled:-0}"
        } > "$meta"

        "$LIB/manager.sh" cron-apply
        send_json '{"ok":true}'
        ;;

    toggle)
        id="$(get_param id || true)"
        meta="$SCRIPTS/$id.meta"
        [ -f "$meta" ] || { send_json '{"ok":false,"error":"Скрипт не найден"}'; exit 0; }
        unset ID PATH MIN HOUR DOM MON DOW ENABLED NAME
        . "$meta"
        if [ "${ENABLED:-0}" = "1" ]; then ENABLED=0; else ENABLED=1; fi
        sed -i "s/^ENABLED=.*/ENABLED=$ENABLED/" "$meta"
        "$LIB/manager.sh" cron-apply
        send_json '{"ok":true}'
        ;;

    delete)
        id="$(get_param id || true)"
        rm -f "$SCRIPTS/$id.meta"
        "$LIB/manager.sh" cron-apply
        send_json '{"ok":true}'
        ;;

    run)
        id="$(get_param id || true)"
        if "$LIB/manager.sh" run "$id" >/tmp/osm-run-code.$$ 2>/tmp/osm-run-err.$$; then
            code="$(cat /tmp/osm-run-code.$$)"
        else
            code="$(cat /tmp/osm-run-code.$$ 2>/dev/null || printf '1')"
        fi
        log="$BASE/logs/$id.log"
        output="$(cat "$log" 2>/dev/null || true)"
        rm -f /tmp/osm-run-code.$$ /tmp/osm-run-err.$$
        printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
        printf '{"ok":true,"exit":%s,"output":"%s"}\n' "${code:-1}" "$(json_escape "$output")"
        ;;

    *)
        send_json '{"ok":false,"error":"Неизвестное действие"}'
        ;;
esac
CGI

chmod 755 "$CGI/api"

# Start a BusyBox HTTP server with CGI enabled.
# `-h` serves the panel, `-p` binds the chosen port and `-c` enables CGI.
# We kill only our own PID.
if [ -f "$PIDFILE" ]; then
    old="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$old" ] && kill "$old" 2>/dev/null || true
fi

httpd -f -p "$BIND:$PORT" -h "$DOCROOT" -c /cgi-bin/api >"$BASE/httpd.log" 2>&1 &
echo $! > "$PIDFILE"
