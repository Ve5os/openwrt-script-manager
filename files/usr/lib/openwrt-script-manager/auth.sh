#!/bin/sh
set -eu

# Uses OpenSSL if available. OpenWrt images commonly provide busybox sha256sum,
# so a salted SHA-256 is used as a portable fallback.
cmd="${1:-}"

hash_password() {
    pw="$1"
    salt="$(hexdump -n 8 -e '8/1 "%02x"' /dev/urandom 2>/dev/null || date +%s)"
    digest="$(printf '%s%s' "$salt" "$pw" | sha256sum | cut -d' ' -f1)"
    printf '%s:%s\n' "$salt" "$digest"
}

verify_password() {
    stored="$1"
    pw="$2"
    salt="${stored%%:*}"
    expected="${stored#*:}"
    actual="$(printf '%s%s' "$salt" "$pw" | sha256sum | cut -d' ' -f1)"
    [ "$actual" = "$expected" ]
}

case "$cmd" in
    hash)
        IFS= read -r PW || true
        hash_password "$PW"
        ;;
    verify)
        verify_password "$2" "$3"
        ;;
    *)
        echo "usage: auth.sh hash|verify <hash> <password>" >&2
        exit 2
        ;;
esac
