#!/bin/sh
set -eu

BASE="/etc/openwrt-script-manager"
SCRIPTS="$BASE/scripts"
CRON="/etc/crontabs/root"
BEGIN="# BEGIN OPENWRT-SCRIPT-MANAGER"
END="# END OPENWRT-SCRIPT-MANAGER"

clean_id() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9_-'
}

cron_apply() {
    mkdir -p "$SCRIPTS" /etc/crontabs
    touch "$CRON"
    tmp="/tmp/osm-cron.$$"

    awk -v b="$BEGIN" -v e="$END" '
      $0 == b { skip=1; next }
      $0 == e { skip=0; next }
      !skip { print }
    ' "$CRON" > "$tmp"

    {
        cat "$tmp"
        printf '%s\n' "$BEGIN"
        for meta in "$SCRIPTS"/*.meta; do
            [ -f "$meta" ] || continue
            unset ID PATH MIN HOUR DOM MON DOW ENABLED
            . "$meta"
            [ "${ENABLED:-0}" = "1" ] || continue
            [ -n "${ID:-}" ] || continue
            [ -n "${PATH:-}" ] || continue
            printf '%s %s # script-manager:%s\n' \
                "${MIN:-*} ${HOUR:-*} ${DOM:-*} ${MON:-*} ${DOW:-*}" \
                "$PATH" "$ID"
        done
        printf '%s\n' "$END"
    } > "$CRON"
    rm -f "$tmp"

    /etc/init.d/cron reload 2>/dev/null || /etc/init.d/cron restart 2>/dev/null || true
}

run_script() {
    id="$(clean_id "$1")"
    meta="$SCRIPTS/$id.meta"
    [ -f "$meta" ] || exit 1
    unset ID PATH MIN HOUR DOM MON DOW ENABLED NAME
    . "$meta"
    [ -n "${PATH:-}" ] || exit 1
    logfile="$BASE/logs/$id.log"
    started="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] start\n' "$started" > "$logfile"
    sh "$PATH" >> "$logfile" 2>&1
    code=$?
    printf '[%s] exit=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$code" >> "$logfile"
    printf '%s\n' "$code"
}

case "${1:-}" in
    cron-apply) cron_apply ;;
    run) run_script "${2:-}" ;;
    *) echo "usage: manager.sh cron-apply|run ID" >&2; exit 2 ;;
esac
