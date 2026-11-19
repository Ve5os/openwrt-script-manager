#!/bin/sh
set -u
SCRIPT_DIR="/etc/my_scripts"
BUILD_VERSION="2026.11.19.10"
REPO_BASE="https://raw.githubusercontent.com/Ve5os/openwrt-script-manager/main"
CRONTAB="/etc/crontabs/root"
TMP="/tmp/script-manager.$$"
cleanup(){ rm -f "$TMP"* 2>/dev/null || true; }
trap cleanup EXIT INT TERM

respond(){ printf 'Status: %s\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store, no-cache, must-revalidate, max-age=0\r\nPragma: no-cache\r\n\r\n%s\n' "$1" "$2"; exit 0; }
esc(){ awk 'BEGIN{ORS=""}{if(NR>1)printf "\\n";gsub(/\\/,"\\\\");gsub(/"/,"\\\"");gsub(/\r/,"\\r");gsub(/\t/,"\\t");printf "%s",$0}'; }
err(){ m="$(printf '%s' "$2"|esc)";respond "$1" "{\"error\":\"$m\"}"; }
valid(){ printf '%s\n' "$1"|grep -Eq '^[a-zA-Z0-9_-]+\.sh$'; }
path(){ valid "$1"||return 1;case "$1" in *..*|*/*|*\*)return 1;;esac;printf '%s/%s' "$SCRIPT_DIR" "$1"; }
body(){ n="${CONTENT_LENGTH:-0}";case "$n" in ''|*[!0-9]*)n=0;;esac;if [ "$n" -gt 0 ];then dd bs=1 count="$n" 2>/dev/null;else cat;fi; }
BODY='';[ "${REQUEST_METHOD:-GET}" = POST ]&&BODY="$(body)"

json(){ k="$1";d="${2-}";if command -v jsonfilter >/dev/null 2>&1;then v="$(printf '%s' "$BODY"|jsonfilter -q -e "@.$k" 2>/dev/null||true)";[ -n "$v" ]&&printf '%s' "$v"||printf '%s' "$d";return;fi
printf '%s' "$BODY"|awk -v k="$k" 'BEGIN{RS="\001"}{pat="\\"" k "\\"[[:space:]]*:[[:space:]]*";if(!match($0,pat))exit;s=substr($0,RSTART+RLENGTH);if(s~/^"/){s=substr(s,2);o="";e=0;for(i=1;i<=length(s);i++){c=substr(s,i,1);if(e){if(c=="n")o=o "\n";else if(c=="r")o=o "\r";else if(c=="t")o=o "\t";else o=o c;e=0}else if(c=="\\")e=1;else if(c=="\"")break;else o=o c}printf "%s",o}else if(s~/^true/)printf "true";else if(s~/^false/)printf "false"}'
}
qget(){ key="$1";old="$IFS";IFS='&';for pair in ${QUERY_STRING:-};do k="${pair%%=*}";v="${pair#*=}";[ "$k" = "$key" ]&&{ IFS="$old";printf '%s' "$v"|sed 's/+/ /g;s/%2F/\//g;s/%2f/\//g;s/%25/%/g';return;};done;IFS="$old";return 1; }

ensure(){ mkdir -p /etc/crontabs;touch "$CRONTAB"; }
sched(){ ensure;awk -v p="$SCRIPT_DIR/$1" '$0!~/^[[:space:]]*#/&&index($0,p){if($1=="@reboot")print "@reboot";else if(NF>=5)print $1" "$2" "$3" "$4" "$5;exit}' "$CRONTAB"; }
enabled(){ ensure;awk -v p="$SCRIPT_DIR/$1" '$0!~/^[[:space:]]*#/&&index($0,p){f=1;exit}END{exit(f?0:1)}' "$CRONTAB"; }
updatecron(){ n="$1";mode="$2";s="${3-}";p="$SCRIPT_DIR/$n";ensure;t="$TMP.cron";awk -v p="$p" -v m="$mode" -v s="$s" '{line=$0;if(index(line,p)){found=1;if(m=="disable"){if(line~/^[[:space:]]*#/)print line;else print "# " line;next}if(m=="enable"){if(line~/^[[:space:]]*#/)sub(/^[[:space:]]*#[[:space:]]?/,"",line);print line;next}if(m=="replace"){print s" "p;next}}print line}END{if(!found&&(m=="enable"||m=="replace"))print s" "p}' "$CRONTAB" >"$t";mv "$t" "$CRONTAB";/etc/init.d/cron reload >/dev/null 2>&1||/etc/init.d/cron restart >/dev/null 2>&1||true; }
rmcron(){ ensure;t="$TMP.del";awk -v p="$SCRIPT_DIR/$1" 'index($0,p)==0{print}' "$CRONTAB">"$t";mv "$t" "$CRONTAB";/etc/init.d/cron reload >/dev/null 2>&1||/etc/init.d/cron restart >/dev/null 2>&1||true; }

fetch(){ o="$1";u="$2";if wget -q -O "$o" "$u";then return 0;fi;if command -v uclient-fetch >/dev/null 2>&1&&uclient-fetch -qO "$o" "$u";then return 0;fi;if command -v curl >/dev/null 2>&1&&curl -fsSL -o "$o" "$u";then return 0;fi;return 1; }
vgt(){ awk -v a="$1" -v b="$2" 'BEGIN{na=split(a,A,".");nb=split(b,B,".");n=na>nb?na:nb;for(i=1;i<=n;i++){x=A[i]+0;y=B[i]+0;if(y>x)exit 0;if(y<x)exit 1}exit 1}'; }
getremote(){ f="$1";v="$(tr -d '\r\n ' <"$f" 2>/dev/null||true)";case "$v" in ''|*[!0-9.]*|.*|*.)v='';;esac;printf '%s' "$v"; }

action='';if [ "${REQUEST_METHOD:-GET}" = GET ];then action="$(qget action 2>/dev/null||true)";else action="$(json action '')";fi
case "$action" in
version_check)
  stamp="$(date +%s)-$$";f="$TMP.version";latest=''
  if fetch "$f" "$REPO_BASE/version?_=$stamp";then latest="$(getremote "$f")";fi
  if [ -z "$latest" ];then
    # Fallback for old repositories without the standalone version file.
    f="$TMP.install"
    if fetch "$f" "$REPO_BASE/install.sh?_=$stamp";then latest="$(sed -n 's/^BUILD_VERSION="\([0-9.]*\)".*/\1/p' "$f"|head -n1)";fi
  fi
  [ -n "$latest" ]||err 503 'Не удалось определить версию на GitHub'
  if vgt "$latest" "$BUILD_VERSION";then respond 200 "{\"current_version\":\"$BUILD_VERSION\",\"latest_version\":\"$latest\",\"update_available\":true}";fi
  respond 200 "{\"current_version\":\"$BUILD_VERSION\",\"latest_version\":\"$latest\",\"update_available\":false}"
  ;;
update)
  [ "${REQUEST_METHOD:-GET}" = POST ]||err 400 'update доступен только через POST'
  requested="$(json version '')";f="$TMP.install";stamp="$(date +%s)-$$"
  fetch "$f" "$REPO_BASE/install.sh?_=$stamp"||err 503 'Не удалось скачать install.sh с GitHub'
  remote="$(sed -n 's/^BUILD_VERSION="\([0-9.]*\)".*/\1/p' "$f"|head -n1)"
  [ -n "$remote" ]||err 500 'Не удалось определить версию установщика'
  [ "$requested" = "$remote" ]||err 409 'Версия обновления изменилась. Повторите проверку.'
  vgt "$remote" "$BUILD_VERSION"||err 409 'Новой версии нет'
  cp "$f" /tmp/openwrt-script-manager-update.sh;chmod 755 /tmp/openwrt-script-manager-update.sh
  (sleep 2;exec /bin/sh /tmp/openwrt-script-manager-update.sh) >/tmp/openwrt-script-manager-update.log 2>&1 </dev/null &
  respond 200 "{\"ok\":true,\"version\":\"$remote\"}"
  ;;
list)
  ensure;b="$TMP.list";printf '{"scripts":['>"$b";first=1
  for f in "$SCRIPT_DIR"/*.sh;do [ -f "$f" ]||continue;n="${f##*/}";valid "$n"||continue;e=false;s='@reboot';x="$(sched "$n")";[ -n "$x" ]&&s="$x";enabled "$n"&&e=true;[ "$first" -eq 1 ]||printf ','>>"$b";first=0;printf '{"name":"%s","enabled":%s,"schedule":"%s"}' "$n" "$e" "$(printf '%s' "$s"|esc)">>"$b";done
  printf ']}'>>"$b";respond 200 "$(cat "$b")"
  ;;
get)
  n="$(qget name 2>/dev/null||true)";[ -n "$n" ]||err 400 'Не указано имя скрипта';valid "$n"||err 400 'Некорректное имя';p="$(path "$n")"||err 400 'Некорректное имя';[ -f "$p" ]||err 404 'Скрипт не найден';c="$(cat "$p")";s="$(sched "$n")";[ -n "$s" ]||s='@reboot';e=false;enabled "$n"&&e=true;respond 200 "{\"name\":\"$n\",\"content\":\"$(printf '%s' "$c"|esc)\",\"enabled\":$e,\"schedule\":\"$(printf '%s' "$s"|esc)\"}"
  ;;
save)
  [ "${REQUEST_METHOD:-GET}" = POST ]||err 400 'save доступен только через POST';n="$(json name '')";c="$(json content '')";s="$(json schedule '@reboot')";valid "$n"||err 400 'Некорректное имя';p="$(path "$n")"||err 400 'Некорректное имя'
  if [ "$s" != "@reboot" ];then
    oldifs="$IFS";IFS=" ";set -- $s;IFS="$oldifs"
    [ $# -eq 5 ] || err 400 'Некорректное cron-расписание'
    for field in "$@";do case "$field" in ""|*[!0-9*/,-]*)err 400 "Некорректное cron-расписание";;esac;done
  fi
  printf '%s' "$c">$TMP.script;mv "$TMP.script" "$p";chmod 755 "$p";updatecron "$n" replace "$s";respond 200 '{"ok":true}'
  ;;
run)
  [ "${REQUEST_METHOD:-GET}" = POST ]||err 400 'run доступен только через POST';n="$(json name '')";valid "$n"||err 400 'Некорректное имя';p="$(path "$n")"||err 400 'Некорректное имя';[ -f "$p" ]||err 404 'Скрипт не найден';set +e;o="$("$p" 2>&1)";rc=$?;set -u;respond 200 "{\"ok\":true,\"output\":\"$(printf '%s' "$o"|esc)\",\"exit_code\":$rc}"
  ;;
delete)
  [ "${REQUEST_METHOD:-GET}" = POST ]||err 400 'delete доступен только через POST';n="$(json name '')";valid "$n"||err 400 'Некорректное имя';p="$(path "$n")"||err 400 'Некорректное имя';[ -f "$p" ]||err 404 'Скрипт не найден';rm -f "$p";rmcron "$n";respond 200 '{"ok":true}'
  ;;
*) err 400 'Неизвестное действие';;
esac
