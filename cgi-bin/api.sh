#!/bin/sh
# OpenWrt Script Manager — CGI API.
# POSIX sh. Пользовательский ввод никогда не передаётся через eval.

set -u

SCRIPT_DIR="/etc/my_scripts"
WEB_ROOT="/www-script-manager"
VERSION_FILE="$WEB_ROOT/version"
REPO_BASE="https://raw.githubusercontent.com/Ve5os/openwrt-script-manager/main"
REPO_INSTALL="$REPO_BASE/install.sh"
CRONTAB="/etc/crontabs/root"
DEFAULT_SCHEDULE='@reboot'
TMP_BASE="/tmp/script-manager.$$"

cleanup() {
    rm -f "$TMP_BASE" "$TMP_BASE.*" 2>/dev/null || true
}
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
    printf '%s\n' "$name" | grep -Eq '^[a-zA-Z0-9_-]+\.sh$'
}
script_path() {
    name="$1"
    valid_name "$name" || return 1
    case "$name" in
        *..*|*/*|*\*) return 1 ;;
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
    printf '%s' "$BODY" | awk -v k="$key" '
        BEGIN { RS="\001" }
        {
            pat="\\"" k "\"[[:space:]]*:[[:space:]]*"
            if (!match($0, pat)) exit
            s=substr($0, RSTART+RLENGTH)
            if (s ~ /^"/) {
                s=substr(s,2); out=""; esc=0
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
                    else if (c==""") break
                    else out=out c
                }
                printf "%s", out
            } else if (s ~ /^true/) printf "true"
            else if (s ~ /^false/) printf "false"
        }'
}
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
            printf '%s' "$val" | sed                 -e 's/+/ /g'                 -e 's/%2F/\//g' -e 's/%2f/\//g'                 -e 's/%5C/\\/g' -e 's/%5c/\\/g'                 -e 's/%25/%/g'
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
    path="$SCRIPT_DIR/$name"
    awk -v p="$path" '
        {
            line=$0
            # Убираем только начальный комментарий у отключённой записи.
            sub(/^[[:space:]]*#[[:space:]]?/, "", line)
            n=split(line, f, /[[:space:]]+/)
            if (n >= 2 && f[n] == p) {
                if (f[1] == "@reboot") print "@reboot"
                else if (n >= 6) print f[1] " " f[2] " " f[3] " " f[4] " " f[5]
                exit
            }
        }
    ' "$CRONTAB"
}
cron_enabled_for() {
    name="$1"
    ensure_crontab
    path="$SCRIPT_DIR/$name"
    awk -v p="$path" '
        /^[[:space:]]*#/ { next }
        {
            n=split($0, f, /[[:space:]]+/)
            if (n >= 2 && f[n] == p) { found=1; exit }
        }
        END { exit(found ? 0 : 1) }
    ' "$CRONTAB"
}
cron_update() {
    name="$1"; mode="$2"; schedule="${3-}"
    path="$SCRIPT_DIR/$name"
    ensure_crontab
    tmp="$TMP_BASE.cron"

    # Полностью удаляем старые записи этого скрипта, включая старые
    # отключённые варианты. Затем добавляем ровно одну актуальную запись.
    awk -v p="$path" '
        {
            line=$0
            clean=line
            sub(/^[[:space:]]*#[[:space:]]?/, "", clean)
            n=split(clean, f, /[[:space:]]+/)
            if (n >= 2 && f[n] == p) next
            print line
        }
    ' "$CRONTAB" > "$tmp"

    case "$mode" in
        replace|enable)
            printf '%s %s\n' "$schedule" "$path" >> "$tmp"
            ;;
        disable)
            printf '# %s %s\n' "$schedule" "$path" >> "$tmp"
            ;;
        *)
            rm -f "$tmp"
            return 1
            ;;
    esac

    mv "$tmp" "$CRONTAB"
    if /etc/init.d/cron reload >/dev/null 2>&1; then :; else /etc/init.d/cron restart >/dev/null 2>&1 || true; fi
}
cron_remove() {
    name="$1"
    ensure_crontab
    path="$SCRIPT_DIR/$name"
    tmp="$TMP_BASE.cron-delete"
    awk -v p="$path" 'index($0,p) == 0 { print }' "$CRONTAB" > "$tmp"
    mv "$tmp" "$CRONTAB"
    if /etc/init.d/cron reload >/dev/null 2>&1; then :; else /etc/init.d/cron restart >/dev/null 2>&1 || true; fi
}
get_local_version() {
    if [ -r "$VERSION_FILE" ]; then
        tr -d '\r\n ' < "$VERSION_FILE"
        return 0
    fi
    return 1
}
version_gt() {
    old="$1"; new="$2"
    awk -v a="$old" -v b="$new" 'BEGIN {
        na=split(a,A,"."); nb=split(b,B,"."); n=(na>nb?na:nb)
        for(i=1;i<=n;i++) {
            x=(A[i] == "" ? 0 : A[i]+0)
            y=(B[i] == "" ? 0 : B[i]+0)
            if(y>x) exit 0
            if(y<x) exit 1
        }
        exit 1
    }'
}
fetch_remote_install() {
    out="$1"
    cache_key="$(date +%s)-$$"
    url="${REPO_INSTALL}?_=${cache_key}"
    if wget -q -O "$out" "$url"; then return 0; fi
    if command -v curl >/dev/null 2>&1 && curl -fsSL -o "$out" "$url"; then return 0; fi
    return 1
}
remote_version() {
    file="$1"
    awk '
        /^[[:space:]]*BUILD_VERSION[[:space:]]*=/ {
            line=$0
            sub(/^[[:space:]]*BUILD_VERSION[[:space:]]*=[[:space:]]*/, "", line)
            gsub(/^["\047]|["\047][[:space:]]*$/, "", line)
            if (line ~ /^[0-9][0-9.]*$/) { print line; exit }
        }
    ' "$file" | head -n 1
}
fetch_remote_version() {
    out="$1"
    cache_key="$(date +%s)-$$"
    url="${REPO_BASE}/version?_=${cache_key}"
    if wget -q -O "$out" "$url"; then
        tr -d '\r\n ' < "$out"
        return 0
    fi
    if command -v curl >/dev/null 2>&1 && curl -fsSL -o "$out" "$url"; then
        tr -d '\r\n ' < "$out"
        return 0
    fi
    return 1
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
    version_check)
        version_tmp="$TMP_BASE.version-check"
        latest=''
        if latest="$(fetch_remote_version "$version_tmp" 2>/dev/null || true)"; then
            case "$latest" in
                ''|*[!0-9.]*|.*|*.) latest='' ;;
            esac
        fi
        if [ -z "$latest" ]; then
            tmp="$TMP_BASE.install-check"
            if ! fetch_remote_install "$tmp"; then
                error_json 503 'Не удалось связаться с GitHub'
            fi
            latest="$(remote_version "$tmp")"
        fi
        [ -n "$latest" ] || error_json 500 'Не удалось определить версию на GitHub'
        current="$(get_local_version 2>/dev/null || true)"
        case "$current" in
            ''|*[!0-9.]*|.*|*.) error_json 500 'Не удалось определить локальную версию' ;;
        esac
        if version_gt "$latest" "$current"; then
            respond 200 "{\"current_version\":\"$current\",\"latest_version\":\"$latest\",\"update_available\":true}"
        fi
        respond 200 "{\"current_version\":\"$current\",\"latest_version\":\"$latest\",\"update_available\":false}"
        ;;
    update)
        [ "${REQUEST_METHOD:-GET}" = 'POST' ] || error_json 400 'update доступен только через POST'

        # Автообновление намеренно не зависит от version_check и не сравнивает
        # версии. Кнопка выполняет тот же самый официальный install-командный
        # вызов, который пользователь может запустить вручную по SSH.
        update_script="/tmp/openwrt-script-manager-update.sh"
        update_log="/tmp/openwrt-script-manager-update.log"
        cat > "$update_script" <<'EOF_UPDATE'
#!/bin/sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/Ve5os/openwrt-script-manager/main/install.sh)"
EOF_UPDATE
        chmod 0755 "$update_script"
        nohup /bin/sh "$update_script" >"$update_log" 2>&1 </dev/null &
        respond 200 '{"ok":true,"message":"Обновление запущено"}'
        ;;
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
        case "$schedule" in
            @reboot) ;;
            *[!0-9*/,\ @-]*) error_json 400 'Некорректное cron-расписание' ;;
            '') error_json 400 'Некорректное cron-расписание' ;;
        esac
        old="$TMP_BASE.script"
        printf '%s' "$content" > "$old"
        mv "$old" "$path"
        chmod 0755 "$path"
        cron_update "$name" replace "$schedule"
        respond 200 '{"ok":true}'
        ;;
    toggle)
        [ "${REQUEST_METHOD:-GET}" = 'POST' ] || error_json 400 'toggle доступен только через POST'
        name="$(json_get name '')"
        enabled="$(json_get enabled 'false')"
        schedule="$(json_get schedule "$DEFAULT_SCHEDULE")"
        valid_name "$name" || error_json 400 'Некорректное имя скрипта'
        [ -f "$(script_path "$name")" ] || error_json 404 'Скрипт не найден'
        case "$enabled" in
            true|1|yes|on) cron_update "$name" enable "$schedule" ;;
            false|0|no|off) cron_update "$name" disable "$schedule" ;;
            *) error_json 400 'Некорректное значение enabled' ;;
        esac
        respond 200 '{"ok":true}'
        ;;
    run)
        [ "${REQUEST_METHOD:-GET}" = 'POST' ] || error_json 400 'run доступен только через POST'
        name="$(json_get name '')"
        valid_name "$name" || error_json 400 'Некорректное имя скрипта'
        path="$(script_path "$name")" || error_json 400 'Некорректное имя скрипта'
        [ -f "$path" ] || error_json 404 'Скрипт не найден'
        output="$("$path" 2>&1)"
        rc=$?
        escaped="$(printf '%s' "$output" | json_escape)"
        respond 200 "{\"ok\":true,\"output\":\"$escaped\",\"exit_code\":$rc}"
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
    *)
        error_json 400 'Неизвестное действие'
        ;;
esac
