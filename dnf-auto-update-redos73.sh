#!/bin/bash
# RED OS 7.3 variant. Same update/escalation logic as the RED OS 8 script, plus:
#   - moves the machine onto the supported 6.1 kernel branch (kernels6 repo);
#   - installs kernel-module packages (<driver>_<uname -r>) for the newest kernel
#     and keeps booting the current kernel if some module is not available yet.
# Never reboots: the new kernel is picked up whenever the user reboots.
set -uo pipefail

export LC_ALL=C
export LANG=C

LOCKFILE=/var/run/dnf-auto-update.lock
LOGFILE=/var/log/dnf-auto-update.log
STATEDIR=/var/lib/dnf-auto-update
PINFILE=$STATEDIR/pinned-kernel
MAX_ITERATIONS=12

KERNEL6_SWITCH=yes
KMOD_FOLLOW=yes
# shellcheck disable=SC1091
[ -r /etc/sysconfig/dnf-auto-update ] && . /etc/sysconfig/dnf-auto-update

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
# (e.g. a directory becomes a symlink), which --allowerasing/--nobest/--skip-broken
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

# Returns 0 once `dnf update` succeeds, escalating flags on failure.
# --setopt=best=False instead of --best=false: in dnf 4 --best is a bare switch,
# so "--best=false" is rejected by the argument parser before dnf does anything.
run_update() {
    local flag_levels=(
        ""
        "--allowerasing"
        "--allowerasing --setopt=best=False"
        "--allowerasing --setopt=best=False --skip-broken"
    )
    local level=0 i flags out rc

    for ((i = 0; i < MAX_ITERATIONS; i++)); do
        flags="${flag_levels[$level]}"
        log "Attempt $((i + 1))/$MAX_ITERATIONS: dnf update -y $flags"

        out=$(dnf update -y $flags 2>&1)
        rc=$?
        printf '%s\n' "$out"

        if [ $rc -eq 0 ]; then
            log "Update succeeded (flags: '$flags')"
            return 0
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
    return 1
}

# 5.15 and older kernels get no updates on RED OS 7.3 anymore; only 6.1 is fully
# supported. Procedure per the RED OS knowledge base ("Обновление ядра Linux до
# версии 6.1 в РЕД ОС 7.3"): update the system, install redos-kernels6-release,
# makecache, update again.
switch_to_kernel6() {
    [ "$KERNEL6_SWITCH" = yes ] || return 0
    rpm -q redos-kernels6-release &>/dev/null && return 0

    log "Enabling kernels6 repository (Linux 6.1 branch)"
    if ! dnf install -y redos-kernels6-release; then
        log "WARNING: could not install redos-kernels6-release, staying on the current kernel branch"
        return 0
    fi
    dnf makecache
    log "Updating kernel and kernel-dependent packages from kernels6"
    run_update
}

newest_kernel() {
    local d v
    for d in /lib/modules/*/; do
        v=$(basename "$d")
        [ -e "/boot/vmlinuz-$v" ] && echo "$v"
    done | sort -V | tail -n1
}

# Kernel-module packages on RED OS carry the full kernel build in their name
# (nvidia-kmod_6.1.158-1.el7.x86_64), so a new kernel -- even a minor one --
# never gets its drivers through `dnf update`. For every driver installed for
# any kernel, install the same driver for the newest kernel. If one is missing
# from the repo, keep the running kernel as the boot default so the next boot
# does not come up without, say, the GPU driver; lift the pin once it appears.
follow_kmods() {
    [ "$KMOD_FOLLOW" = yes ] || return 0

    local newest running arch
    newest=$(newest_kernel)
    running=$(uname -r)
    arch=$(uname -m)
    [ -z "$newest" ] && return 0

    # Driver names without the "_<kernel build>" suffix, deduplicated across kernels.
    # The build may itself contain "_" (".x86_64"), so cut at "_<digits>.<digits>...-".
    local kre='_[0-9]+\.[0-9]+(\.[0-9]+)?-.*$'
    local bases
    bases=$(rpm -qa --qf '%{NAME}\n' | grep -E "$kre" | sed -E "s/$kre//" | sort -u)

    local missing=() base cand ok
    for base in $bases; do
        ok=0
        for cand in "${base}_${newest}" "${base}_${newest%.$arch}"; do
            if rpm -q "$cand" &>/dev/null; then ok=1; break; fi
        done
        if [ $ok -eq 0 ]; then
            for cand in "${base}_${newest}" "${base}_${newest%.$arch}"; do
                log "Installing kernel module package $cand for kernel $newest"
                if dnf install -y "$cand"; then ok=1; break; fi
            done
        fi
        [ $ok -eq 0 ] && missing+=("$base")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log "WARNING: no kernel module package for $newest: ${missing[*]}"
        if [ "$newest" = "$running" ]; then
            log "WARNING: running kernel already is $newest, nothing to fall back to -- manual check needed"
        elif ! command -v grubby &>/dev/null; then
            log "WARNING: grubby not found, cannot keep $running as boot default -- next boot uses $newest without those modules"
        elif grubby --set-default "/boot/vmlinuz-$running"; then
            mkdir -p "$STATEDIR"
            echo "$newest" > "$PINFILE"
            log "Boot default kept on running kernel $running until modules for $newest are available"
        else
            log "WARNING: grubby --set-default failed -- next boot uses $newest without those modules"
        fi
        return 0
    fi

    if [ -f "$PINFILE" ] && command -v grubby &>/dev/null; then
        if grubby --set-default "/boot/vmlinuz-$newest"; then
            rm -f "$PINFILE"
            log "All kernel modules available for $newest, boot default switched to it"
        fi
    fi
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

log "=== dnf auto-update start (RED OS 7.3) ==="

success=0
if run_update && switch_to_kernel6; then
    success=1
fi
follow_kmods

newest=$(newest_kernel)
if [ -n "$newest" ] && [ "$newest" != "$(uname -r)" ] && [ ! -f "$PINFILE" ]; then
    log "Kernel $newest installed, will be used after the next reboot (running $(uname -r))"
fi

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
