#!/bin/sh
# OpenWrt Script Manager — CGI API.
# POSIX sh. Пользовательский ввод никогда не передаётся через eval.

set -u

SCRIPT_DIR="/etc/my_scripts"
CRONTAB="/etc/crontabs/root"
DEFAULT_SCHEDULE='*/1 * * * *'
TMP_BASE="/tmp/script-manager.$$"

cleanup() {
    rm -f "$TMP_BASE" "$TMP_BASE.*" 2>/dev/null || true
}

# Важно: CGI не должен завершаться с ненулевым кодом после выдачи ошибки,
# иначе uhttpd может показать 502 Bad Gateway вместо нашего JSON.
fatal_trap() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        cleanup
        printf 'Status: 500\r\n'
        printf 'Content-Type: application/json; charset=utf-8\r\n'
        printf 'Cache-Control: no-store\r\n\r\n'
        printf '%s\n' '{"error":"Внутренняя ошибка CGI"}'
    fi
    exit 0
}
trap fatal_trap EXIT INT TERM

json_escape() {
    # JSON escaping для строк. awk получает весь stdin целиком.
    # Управляющие символы, кавычки и обратные слеши экранируются.
    awk 'BEGIN { ORS="" }
    {
        if (NR > 1) printf "\\n";
        gsub(/\\/, "\\\\");
        gsub(/"/, "\\\"");
        gsub(/\r/, "\\r");
        gsub(/\t/, "\\t");
        printf "%s", $0;
    }'
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
    escaped="$(printf '%s' "$message" | json_escape)"
    respond "$code" "{\"error\":\"$escaped\"}"
}

valid_name() {
    name="$1"
    # Разрешаем только имена вида example.sh. Точка допустима только
    # перед расширением .sh; путь, слеш и прочие символы не проходят.
    printf '%s\n' "$name" | grep -Eq '^[a-zA-Z0-9_-]+\.sh$'
}

script_path() {
    name="$1"
    valid_name "$name" || return 1
    case "$name" in
        *..*|*/*|*\\*) return 1 ;;
    esac
    printf '%s/%s' "$SCRIPT_DIR" "$name"
}

read_body() {
    len="${CONTENT_LENGTH:-0}"
    case "$len" in
        ''|*[!0-9]*) len=0 ;;
    esac
    if [ "$len" -gt 0 ]; then
        dd bs=1 count="$len" 2>/dev/null
    else
        cat
    fi
}

BODY=''
if [ "${REQUEST_METHOD:-GET}" = 'POST' ]; then
    BODY="$(read_body)"
fi

# Получение JSON-поля. jsonfilter используется, если доступен.
json_get() {
    key="$1"
    default="${2-}"

    if command -v jsonfilter >/dev/null 2>&1; then
        value="$(printf '%s' "$BODY" | jsonfilter -q -e "@.$key" 2>/dev/null || true)"
        if [ -n "$value" ]; then
            printf '%s' "$value"
        else
            printf '%s' "$default"
        fi
        return 0
    fi

    # Минимальный fallback только для строк и boolean. eval не используется.
    printf '%s' "$BODY" | awk -v k="$key" '
        BEGIN { RS="\001" }
        {
            pat="\\\"" k "\\\"[[:space:]]*:[[:space:]]*"
            if (!match($0, pat)) exit
            s=substr($0, RSTART+RLENGTH)
            if (s ~ /^\"/) {
                s=substr(s,2)
                out=""
                esc=0
                for (i=1; i<=length(s); i++) {
                    c=substr(s,i,1)
                    if (esc) {
                        if (c=="n") out=out "\n"
                        else if (c=="r") out=out "\r"
                        else if (c=="t") out=out "\t"
                        else if (c=="b") out=out "\b"
                        else if (c=="f") out=out "\f"
                        else out=out c
                        esc=0
                    } else if (c=="\\") esc=1
                    else if (c=="\"") break
                    else out=out c
                }
                printf "%s", out
            } else if (s ~ /^true/) printf "true"
            else if (s ~ /^false/) printf "false"
        }'
}

# URL-параметр GET. Для имени скрипта достаточно декодировать стандартные
# символы; slash и backslash после этого всё равно блокируются valid_name().
get_query_param() {
    wanted="$1"
    query="${QUERY_STRING:-}"
    old_ifs="$IFS"
    IFS='&'
    for pair in $query; do
        key=${pair%%=*}
        val=${pair#*=}
        if [ "$key" = "$wanted" ]; then
            IFS="$old_ifs"
            printf '%s' "$val" | sed \
                -e 's/+/ /g' \
                -e 's/%2F/\//g' -e 's/%2f/\//g' \
                -e 's/%5C/\\/g' -e 's/%5c/\\/g' \
                -e 's/%25/%/g'
            return 0
        fi
    done
    IFS="$old_ifs"
    return 1
}

ensure_crontab() {
    mkdir -p "$(dirname "$CRONTAB")"
    [ -f "$CRONTAB" ] || : > "$CRONTAB"
}

cron_schedule_for() {
    name="$1"
    ensure_crontab
    awk -v p="$SCRIPT_DIR/$name" '
        $0 !~ /^[[:space:]]*#/ && index($0,p) {
            if (NF >= 5) print $1 " " $2 " " $3 " " $4 " " $5
            exit
        }
    ' "$CRONTAB"
}

cron_enabled_for() {
    name="$1"
    ensure_crontab
    awk -v p="$SCRIPT_DIR/$name" '
        $0 !~ /^[[:space:]]*#/ && index($0,p) { found=1; exit }
        END { exit(found ? 0 : 1) }
    ' "$CRONTAB"
}

cron_update() {
    name="$1"
    mode="$2" # enable | disable | replace
    schedule="${3-}"
    path="$SCRIPT_DIR/$name"
    ensure_crontab

    tmp="$TMP_BASE.cron"
    found=0

    awk -v n="$name" -v p="$path" -v mode="$mode" -v sched="$schedule" '
        {
            line=$0
            hit=(index(line,p) > 0)
            if (hit) {
                found=1
                if (mode == "disable") {
                    if (line ~ /^[[:space:]]*#/) print line
                    else print "# " line
                    next
                }
                if (mode == "enable") {
                    if (line ~ /^[[:space:]]*#/) {
                        sub(/^[[:space:]]*#[[:space:]]?/, "", line)
                        print line
                    } else print line
                    next
                }
                if (mode == "replace") {
                    print sched " " p
                    next
                }
            }
            print line
        }
        END {
            if (!found && (mode == "enable" || mode == "replace"))
                print sched " " p
        }
    ' "$CRONTAB" > "$tmp"

    # Атомарная замена crontab.
    mv "$tmp" "$CRONTAB"

    # В разных версиях OpenWrt init-скрипт cron может не поддерживать reload.
    # Важно не превращать это в 502: если reload не сработал, пробуем restart.
    if /etc/init.d/cron reload >/dev/null 2>&1; then
        :
    else
        /etc/init.d/cron restart >/dev/null 2>&1 || true
    fi
}

cron_remove() {
    name="$1"
    ensure_crontab
    path="$SCRIPT_DIR/$name"
    tmp="$TMP_BASE.cron-delete"
    awk -v p="$path" 'index($0,p) == 0 { print }' "$CRONTAB" > "$tmp"
    mv "$tmp" "$CRONTAB"
    if /etc/init.d/cron reload >/dev/null 2>&1; then
        :
    else
        /etc/init.d/cron restart >/dev/null 2>&1 || true
    fi
}

list_scripts() {
    body="$TMP_BASE.list"
    first=1
    printf '{"scripts":[' > "$body"
    for file in "$SCRIPT_DIR"/*.sh; do
        [ -f "$file" ] || continue
        name="${file##*/}"
        valid_name "$name" || continue

        enabled=false
        schedule="$DEFAULT_SCHEDULE"
        s="$(cron_schedule_for "$name")"
        [ -n "$s" ] && schedule="$s"
        if cron_enabled_for "$name"; then enabled=true; fi

        [ "$first" -eq 1 ] || printf ',' >> "$body"
        first=0
        ename="$(printf '%s' "$name" | json_escape)"
        eschedule="$(printf '%s' "$schedule" | json_escape)"
        printf '{"name":"%s","enabled":%s,"schedule":"%s"}' "$ename" "$enabled" "$eschedule" >> "$body"
    done
    printf ']}\n' >> "$body"
    respond 200 "$(cat "$body")"
}

ACTION=''
if [ "${REQUEST_METHOD:-GET}" = 'GET' ]; then
    ACTION="$(get_query_param action 2>/dev/null || true)"
else
    ACTION="$(json_get action '')"
fi

case "$ACTION" in
    list)
        [ "${REQUEST_METHOD:-GET}" = 'GET' ] || error_json 400 'list доступен только через GET'
        list_scripts
        ;;

    get)
        name="$(get_query_param name 2>/dev/null || true)"
        [ -n "$name" ] || error_json 400 'Не указано имя скрипта'
        valid_name "$name" || error_json 400 'Некорректное имя скрипта'
        path="$(script_path "$name")" || error_json 400 'Некорректное имя скрипта'
        [ -f "$path" ] || error_json 404 'Скрипт не найден'

        content="$(cat "$path")"
        schedule="$DEFAULT_SCHEDULE"
        s="$(cron_schedule_for "$name")"
        [ -n "$s" ] && schedule="$s"
        enabled=false
        if cron_enabled_for "$name"; then enabled=true; fi

        ename="$(printf '%s' "$name" | json_escape)"
        econtent="$(printf '%s' "$content" | json_escape)"
        eschedule="$(printf '%s' "$schedule" | json_escape)"
        respond 200 "{\"name\":\"$ename\",\"content\":\"$econtent\",\"enabled\":$enabled,\"schedule\":\"$eschedule\"}"
        ;;

    save)
        [ "${REQUEST_METHOD:-GET}" = 'POST' ] || error_json 400 'save доступен только через POST'
        name="$(json_get name '')"
        content="$(json_get content '')"
        schedule="$(json_get schedule "$DEFAULT_SCHEDULE")"

        valid_name "$name" || error_json 400 'Некорректное имя скрипта'
        path="$(script_path "$name")" || error_json 400 'Некорректное имя скрипта'
        [ -n "$schedule" ] || schedule="$DEFAULT_SCHEDULE"

        fields="$(printf '%s\n' "$schedule" | awk '{print NF}')"
        [ "$fields" -eq 5 ] || error_json 400 'Расписание cron должно содержать 5 полей'

        was_enabled=false
        if cron_enabled_for "$name"; then was_enabled=true; fi

        tmp="$TMP_BASE.script"
        printf '%s' "$content" > "$tmp"
        chmod 0755 "$tmp"
        mv "$tmp" "$path"

        if [ "$was_enabled" = true ]; then
            cron_update "$name" replace "$schedule"
        fi

        respond 200 '{"ok":true}'
        ;;

    toggle)
        [ "${REQUEST_METHOD:-GET}" = 'POST' ] || error_json 400 'toggle доступен только через POST'
        name="$(json_get name '')"
        enabled="$(json_get enabled '')"
        schedule="$(json_get schedule "$DEFAULT_SCHEDULE")"

        valid_name "$name" || error_json 400 'Некорректное имя скрипта'
        path="$(script_path "$name")" || error_json 400 'Некорректное имя скрипта'
        [ -f "$path" ] || error_json 404 'Скрипт не найден'

        case "$enabled" in
            true|1|yes)
                [ -n "$schedule" ] || schedule="$DEFAULT_SCHEDULE"
                current="$(cron_schedule_for "$name")"
                [ -n "$current" ] && schedule="$current"
                cron_update "$name" enable "$schedule"
                ;;
            false|0|no)
                cron_update "$name" disable
                ;;
            *)
                error_json 400 'enabled должен быть boolean'
                ;;
        esac

        respond 200 '{"ok":true}'
        ;;

    delete)
        [ "${REQUEST_METHOD:-GET}" = 'POST' ] || error_json 400 'delete доступен только через POST'
        name="$(json_get name '')"
        valid_name "$name" || error_json 400 'Некорректное имя скрипта'
        path="$(script_path "$name")" || error_json 400 'Некорректное имя скрипта'
        [ -f "$path" ] || error_json 404 'Скрипт не найден'

        rm -f "$path"
        cron_remove "$name"
        respond 200 '{"ok":true}'
        ;;

    run)
        [ "${REQUEST_METHOD:-GET}" = 'POST' ] || error_json 400 'run доступен только через POST'
        name="$(json_get name '')"
        valid_name "$name" || error_json 400 'Некорректное имя скрипта'
        path="$(script_path "$name")" || error_json 400 'Скрипт не найден'
        [ -f "$path" ] || error_json 404 'Скрипт не найден'

        out="$TMP_BASE.out"
        : > "$out"
        rc=0
        "$path" >"$out" 2>&1 || rc=$?
        output="$(dd if="$out" bs=4096 count=1 2>/dev/null)"
        eoutput="$(printf '%s' "$output" | json_escape)"
        respond 200 "{\"ok\":true,\"exit_code\":$rc,\"output\":\"$eoutput\"}"
        ;;

    *)
        error_json 400 'Неизвестное действие'
        ;;
esac
