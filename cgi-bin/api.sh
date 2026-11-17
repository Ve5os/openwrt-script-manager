#!/bin/sh
# CGI API OpenWrt Script Manager.
# POSIX sh. Пользовательский ввод никогда не передаётся в eval.

set -eu

SCRIPT_DIR="/etc/my_scripts"
CRONTAB="/etc/crontabs/root"
DEFAULT_SCHEDULE='*/1 * * * *'
TMP_BASE="/tmp/script-manager.$$"

HTTP_STATUS=200

cleanup() {
    rm -f "$TMP_BASE" "$TMP_BASE.new" "$TMP_BASE.out" "$TMP_BASE.cron" "$TMP_BASE.body" 2>/dev/null || true
}
on_exit() {
    rc=$?
    cleanup
    if [ "$rc" -ne 0 ]; then
        printf '%s\r\n' 'Status: 500'
        printf '%s\r\n' 'Content-Type: application/json; charset=utf-8'
        printf '%s\r\n' 'Cache-Control: no-store'
        printf '\r\n'
        printf '%s\n' '{"error":"Внутренняя ошибка сервера"}'
    fi
    exit "$rc"
}
trap on_exit EXIT INT TERM

json_escape() {
    # Экранируем только символы, которые могут сломать JSON-строку.
    # Для UTF-8 байты оставляем как есть.
    printf '%s' "$1" | awk 'BEGIN { ORS="" } { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\r/, "\\r"); gsub(/\t/, "\\t"); print }'
}

respond() {
    code="$1"
    body="$2"
    printf 'Status: %s\r\n' "$code"
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n\r\n'
    printf '%s\n' "$body"
    exit 0
}

error_json() {
    code="$1"
    message="$2"
    HTTP_STATUS="$code"
    escaped="$(json_escape "$message")"
    respond "$code" "{\"error\":\"$escaped\"}"
}

url_decode() {
    # Декодирование query-параметра без eval.
    # Сначала заменяем + на пробел, затем %XX.
    value=$(printf '%s' "$1" | sed 's/+/ /g')
    # Несколько проходов позволяют декодировать UTF-8 и остальные %XX.
    i=0
    while [ "$i" -lt 3 ]; do
        value=$(printf '%s' "$value" | sed -e 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')
        # BusyBox sed не во всех сборках интерпретирует \x; fallback ниже.
        case "$value" in
            *'\\x'*)
                value=$(printf '%s' "$1" | sed 's/+/ /g')
                break
                ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$value"
}

get_query_param() {
    wanted="$1"
    old_ifs="$IFS"
    IFS='&'
    for pair in $QUERY_STRING; do
        key=${pair%%=*}
        val=${pair#*=}
        if [ "$key" = "$wanted" ]; then
            IFS="$old_ifs"
            # Имена скриптов ASCII, поэтому достаточно безопасного query decode.
            printf '%s' "$val" | sed 's/+/ /g; s/%2F/\//g; s/%2f/\//g; s/%5C/\\/g; s/%25/%/g'
            return 0
        fi
    done
    IFS="$old_ifs"
    return 1
}

read_body() {
    len="${CONTENT_LENGTH:-0}"
    case "$len" in ''|*[!0-9]*) len=0 ;; esac
    if [ "$len" -gt 0 ]; then
        dd bs=1 count="$len" 2>/dev/null
    else
        cat
    fi
}

BODY=""
if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
    BODY="$(read_body)"
fi

json_get() {
    key="$1"
    default="${2-}"
    if command -v jsonfilter >/dev/null 2>&1; then
        value="$(printf '%s' "$BODY" | jsonfilter -q -e "@.$key" 2>/dev/null || true)"
        [ -n "$value" ] && { printf '%s' "$value"; return 0; }
        printf '%s' "$default"
        return 0
    fi
    # Минимальный fallback для строк/булевых значений. eval не используется.
    case "$key" in
        name) key='name' ;;
        content) key='content' ;;
        schedule) key='schedule' ;;
        enabled) key='enabled' ;;
        action) key='action' ;;
        *) printf '%s' "$default"; return 0 ;;
    esac
    printf '%s' "$BODY" | awk -v k="$key" '
        BEGIN { RS="\0" }
        {
          pat="\\\"" k "\\\"[[:space:]]*:[[:space:]]*"
          if (match($0, pat)) {
            s=substr($0, RSTART+RLENGTH)
            if (s ~ /^\"/) {
              sub(/^\"/, "", s)
              out=""
              esc=0
              for (i=1; i<=length(s); i++) {
                c=substr(s,i,1)
                if (esc) { if (c=="n") out=out "\n"; else if (c=="r") out=out "\r"; else if (c=="t") out=out "\t"; else out=out c; esc=0 }
                else if (c=="\\") esc=1
                else if (c=="\"") break
                else out=out c
              }
              print out
            } else if (s ~ /^true/) print "true"
            else if (s ~ /^false/) print "false"
          }
        }'
}

valid_name() {
    case "$1" in
        ''|*[!a-zA-Z0-9_-]*.sh) return 1 ;;
    esac
    # Проверка именно полного шаблона, без путей и ..
    printf '%s\n' "$1" | grep -Eq '^[a-zA-Z0-9_-]+\.sh$'
}

script_path() {
    name="$1"
    valid_name "$name" || return 1
    case "$name" in *..*|*/*|*\\*) return 1 ;; esac
    printf '%s/%s' "$SCRIPT_DIR" "$name"
}

ensure_crontab() {
    [ -f "$CRONTAB" ] || : > "$CRONTAB"
}

cron_schedule_for() {
    name="$1"
    ensure_crontab
    awk -v p="$SCRIPT_DIR/$name" '
      $0 !~ /^[[:space:]]*#/ && index($0,p) { print $1" "$2" "$3" "$4" "$5; exit }
    ' "$CRONTAB"
}

cron_update() {
    name="$1"
    mode="$2"       # enable|disable|replace
    schedule="${3-}"
    path="$SCRIPT_DIR/$name"
    ensure_crontab

    tmp="$TMP_BASE.cron"
    : > "$tmp"
    found=0

    awk -v n="$name" -v p="$path" -v mode="$mode" -v sched="$schedule" '
      BEGIN { found=0 }
      {
        line=$0
        active=(line !~ /^[[:space:]]*#/)
        hit=(index(line,p)>0)
        if (hit) {
          found=1
          if (mode=="disable") {
            if (active) print "# " line; else print line
            next
          }
          if (mode=="enable" || mode=="replace") {
            if (active) {
              if (mode=="replace") print sched " " p
              else print line
            } else {
              # При включении существующая закомментированная строка становится активной.
              if (mode=="replace") print sched " " p
              else {
                sub(/^[[:space:]]*#[[:space:]]?/, "", line)
                print line
              }
            }
            next
          }
        }
        print line
      }
      END {
        if (!found && (mode=="enable" || mode=="replace")) print sched " " p
      }
    ' "$CRONTAB" > "$tmp"

    mv "$tmp" "$CRONTAB"
    /etc/init.d/cron reload 2>/dev/null || /etc/init.d/cron restart
}

list_scripts() {
    first=1
    printf '{"scripts":['
    for file in "$SCRIPT_DIR"/*.sh; do
        [ -f "$file" ] || continue
        name="${file##*/}"
        valid_name "$name" || continue
        enabled=false
        schedule="$DEFAULT_SCHEDULE"
        if [ -f "$CRONTAB" ] && awk -v p="$SCRIPT_DIR/$name" '$0 !~ /^[[:space:]]*#/ && index($0,p)' "$CRONTAB" | grep -q .; then
            enabled=true
            s="$(cron_schedule_for "$name")"
            [ -n "$s" ] && schedule="$s"
        else
            s="$(cron_schedule_for "$name")"
            [ -n "$s" ] && schedule="$s"
        fi
        [ "$first" -eq 1 ] || printf ','
        first=0
        ename="$(json_escape "$name")"
        eschedule="$(json_escape "$schedule")"
        printf '{"name":"%s","enabled":%s,"schedule":"%s"}' "$ename" "$enabled" "$eschedule"
    done
    printf ']}\n'
    exit 0
}

[ -n "${QUERY_STRING:-}" ] || QUERY_STRING=""
ACTION=""
if [ "${REQUEST_METHOD:-GET}" = "GET" ]; then
    ACTION="$(get_query_param action 2>/dev/null || true)"
else
    ACTION="$(json_get action '')"
fi

case "$ACTION" in
    list)
        [ "${REQUEST_METHOD:-GET}" = "GET" ] || error_json 400 'list доступен только через GET'
        list_scripts
        ;;

    get)
        name="$(get_query_param name 2>/dev/null || true)"
        [ -n "$name" ] || error_json 400 'Не указано имя скрипта'
        valid_name "$name" || error_json 400 'Некорректное имя скрипта'
        path="$(script_path "$name")" || error_json 400 'Некорректное имя скрипта'
        [ -f "$path" ] || error_json 404 'Скрипт не найден'
        content="$(cat "$path")"
        enabled=false
        schedule="$DEFAULT_SCHEDULE"
        s="$(cron_schedule_for "$name")"
        [ -n "$s" ] && schedule="$s"
        if [ -f "$CRONTAB" ] && awk -v p="$SCRIPT_DIR/$name" '$0 !~ /^[[:space:]]*#/ && index($0,p)' "$CRONTAB" | grep -q .; then enabled=true; fi
        ename="$(json_escape "$name")"
        econtent="$(json_escape "$content")"
        eschedule="$(json_escape "$schedule")"
        respond 200 "{\"name\":\"$ename\",\"content\":\"$econtent\",\"enabled\":$enabled,\"schedule\":\"$eschedule\"}"
        ;;

    save)
        [ "${REQUEST_METHOD:-GET}" = "POST" ] || error_json 400 'save доступен только через POST'
        name="$(json_get name '')"
        content="$(json_get content '')"
        schedule="$(json_get schedule "$DEFAULT_SCHEDULE")"
        valid_name "$name" || error_json 400 'Некорректное имя скрипта'
        path="$(script_path "$name")" || error_json 400 'Некорректное имя скрипта'
        [ -n "$schedule" ] || schedule="$DEFAULT_SCHEDULE"
        # Базовая проверка cron: ровно 5 полей.
        field_count="$(printf '%s\n' "$schedule" | awk '{print NF}')"
        [ "$field_count" -eq 5 ] || error_json 400 'Расписание cron должно содержать 5 полей'
        old_enabled=false
        if [ -f "$CRONTAB" ] && awk -v p="$SCRIPT_DIR/$name" '$0 !~ /^[[:space:]]*#/ && index($0,p)' "$CRONTAB" | grep -q .; then old_enabled=true; fi

        tmp="$TMP_BASE"
        printf '%s' "$content" > "$tmp"
        chmod 0755 "$tmp"
        mv "$tmp" "$path"

        if [ "$old_enabled" = true ]; then
            cron_update "$name" replace "$schedule"
        fi
        respond 200 '{"ok":true}'
        ;;

    toggle)
        [ "${REQUEST_METHOD:-GET}" = "POST" ] || error_json 400 'toggle доступен только через POST'
        name="$(json_get name '')"
        enabled="$(json_get enabled '')"
        valid_name "$name" || error_json 400 'Некорректное имя скрипта'
        path="$(script_path "$name")" || error_json 400 'Некорректное имя скрипта'
        [ -f "$path" ] || error_json 404 'Скрипт не найден'
        case "$enabled" in
            true|1|yes) schedule="$(cron_schedule_for "$name")"; [ -n "$schedule" ] || schedule="$DEFAULT_SCHEDULE"; cron_update "$name" enable "$schedule" ;;
            false|0|no) cron_update "$name" disable ;;
            *) error_json 400 'enabled должен быть boolean' ;;
        esac
        respond 200 '{"ok":true}'
        ;;

    delete)
        [ "${REQUEST_METHOD:-GET}" = "POST" ] || error_json 400 'delete доступен только через POST'
        name="$(json_get name '')"
        valid_name "$name" || error_json 400 'Некорректное имя скрипта'
        path="$(script_path "$name")" || error_json 400 'Некорректное имя скрипта'
        [ -f "$path" ] || error_json 404 'Скрипт не найден'
        rm -f "$path"
        cron_update "$name" disable
        respond 200 '{"ok":true}'
        ;;

    run)
        [ "${REQUEST_METHOD:-GET}" = "POST" ] || error_json 400 'run доступен только через POST'
        name="$(json_get name '')"
        valid_name "$name" || error_json 400 'Некорректное имя скрипта'
        path="$(script_path "$name")" || error_json 400 'Некорректное имя скрипта'
        [ -f "$path" ] || error_json 404 'Скрипт не найден'
        out="$TMP_BASE.out"
        : > "$out"
        # Запускаем только абсолютный путь из /etc/my_scripts и без аргументов.
        "$path" >"$out" 2>&1 || rc=$?
        rc="${rc:-0}"
        # Ограничиваем ответ 4 KiB, сохраняя начало stdout/stderr.
        output="$(dd if="$out" bs=4096 count=1 2>/dev/null)"
        eoutput="$(json_escape "$output")"
        respond 200 "{\"ok\":true,\"output\":\"$eoutput\"}"
        ;;

    *)
        error_json 400 'Неизвестное действие'
        ;;
esac
