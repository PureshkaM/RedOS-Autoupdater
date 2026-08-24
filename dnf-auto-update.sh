#!/bin/bash
set -uo pipefail

export LC_ALL=C
export LANG=C

LOCKFILE=/var/run/dnf-auto-update.lock
LOGFILE=/var/log/dnf-auto-update.log
MAX_ITERATIONS=12

exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "$(date -Is) [dnf-auto-update] another instance is already running, exiting" >&2
    exit 0
fi

exec > >(tee -a "$LOGFILE") 2>&1

log() {
    echo "[$(date -Is)] $*"
}

# rpm refuses an in-place upgrade when a path changes type between versions
# (e.g. a directory becomes a symlink), which --allowerasing/--best/--skip-broken
# cannot fix since it happens during the rpm transaction check, not depsolving.
# The only way out is to drop the old copy and let dnf install the new one fresh.
handle_file_conflicts() {
    local out="$1"
    local nevras
    nevras=$(printf '%s\n' "$out" | grep -oP '(?<=conflicts with file from package )\S+' | sort -u)
    [ -z "$nevras" ] && return 1

    local names=()
    local nevra name
    for nevra in $nevras; do
        name=$(rpm -q --qf '%{NAME}\n' "$nevra" 2>/dev/null)
        [ -z "$name" ] && name="$nevra"
        log "File conflict on $nevra -- removing old copy (rpm -e --nodeps) and reinstalling latest"
        rpm -e --nodeps "$nevra"
        names+=("$name")
    done

    local n
    for n in "${names[@]}"; do
        log "dnf install -y $n"
        dnf install -y "$n"
    done
    return 0
}

# Manual file-conflict remediation (rpm -e --nodeps + dnf install) bypasses the
# single atomic dnf transaction that normally orchestrates service restarts via
# package %post/%postun scriptlets (systemd_postun_with_restart and friends).
# On a graphical system this can leave the display manager down after an update
# even though dnf itself reported success -- check for that and try to recover.
check_graphical_session() {
    if [ "$(systemctl get-default 2>/dev/null)" != "graphical.target" ]; then
        return
    fi
    if ! systemctl is-enabled display-manager.service &>/dev/null; then
        return
    fi
    if systemctl is-active --quiet display-manager.service; then
        log "display-manager.service is active, GUI OK"
        return
    fi
    log "display-manager.service is NOT active after update -- attempting to start it"
    if systemctl start display-manager.service && systemctl is-active --quiet display-manager.service; then
        log "display-manager.service recovered"
    else
        log "WARNING: could not bring display-manager.service back up -- GUI is likely down, manual check needed"
    fi
}

log "=== dnf auto-update start ==="

flag_levels=(
    ""
    "--allowerasing"
    "--allowerasing --best=false"
    "--allowerasing --best=false --skip-broken"
)
level=0
success=0

for ((i = 0; i < MAX_ITERATIONS; i++)); do
    flags="${flag_levels[$level]}"
    log "Attempt $((i + 1))/$MAX_ITERATIONS: dnf update -y $flags"

    out=$(dnf update -y $flags 2>&1)
    rc=$?
    printf '%s\n' "$out"

    if [ $rc -eq 0 ]; then
        success=1
        log "Update succeeded (flags: '$flags')"
        break
    fi

    if printf '%s\n' "$out" | grep -q "conflicts with file from package"; then
        handle_file_conflicts "$out"
        continue
    fi

    if [ $level -lt $((${#flag_levels[@]} - 1)) ]; then
        level=$((level + 1))
        log "Escalating to flags: '${flag_levels[$level]}'"
    else
        log "Still failing at the most permissive flag set, retrying in 20s (possibly transient)"
        sleep 20
    fi
done

check_graphical_session

failed_units=$(systemctl --failed --no-legend 2>/dev/null)
if [ -n "$failed_units" ]; then
    log "WARNING: systemd reports failed units after update:"
    printf '%s\n' "$failed_units"
fi

if [ $success -eq 1 ]; then
    log "=== dnf auto-update finished OK ==="
    exit 0
else
    log "=== dnf auto-update FAILED after $MAX_ITERATIONS attempts -- needs manual review, see log above ==="
    exit 1
fi
