#!/bin/bash
# Entry point: picks the update script matching the installed RED OS release.
# Each release gets its own script so a fix for one cannot break the other.
set -uo pipefail

LIBEXEC=/usr/libexec/dnf-auto-update
LOGFILE=/var/log/dnf-auto-update.log

log() {
    echo "[$(date -Is)] [dispatch] $*" | tee -a "$LOGFILE"
}

ID=""
VERSION_ID=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
fi

# /etc/os-release is the primary source; /etc/redos-release ("RED OS release
# MUROM (7.3.4) ...") is a fallback in case VERSION_ID is missing or odd.
major="${VERSION_ID%%.*}"
if [ -z "$major" ] && [ -r /etc/redos-release ]; then
    major=$(grep -oE '\(([0-9]+)' /etc/redos-release | tr -d '(' | head -n1)
fi

if [ ! -e /etc/redos-release ] && [[ "$ID" != *redos* ]]; then
    major=""
fi

case "$major" in
    7) target="$LIBEXEC/redos-7.3" ;;
    8) target="$LIBEXEC/redos-8" ;;
    *)
        # The RED OS 8 script is plain RHEL-family dnf logic, the safest default.
        target="$LIBEXEC/redos-8"
        log "Unrecognized OS (ID='$ID' VERSION_ID='$VERSION_ID'), falling back to $target"
        ;;
esac

exec "$target" "$@"
