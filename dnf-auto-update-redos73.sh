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
TEE_PID=${!:-}
# systemd kills whatever is left in the cgroup once the script exits, so let tee
# drain the pipe first or the final status lines never reach the log file.
trap 'exec >&- 2>&-; [ -n "$TEE_PID" ] && wait "$TEE_PID" 2>/dev/null' EXIT

# Packages removed by handle_file_conflicts that could not be put back.
lost_pkgs=()

log() {
    echo "[$(date -Is)] $*"
}

# rpm reports "file X from install of A conflicts with file from package B"
# during its transaction check, after depsolving, so no dnf flag gets past it.
# Two cases:
#   - A and B are the same package: a path changed type between versions (a
#     directory became a symlink). rpm cannot replace a directory in place, so
#     the old copy has to go. The new package (and the old one, if the repos
#     still have it) is downloaded first, so erasing never waits on the network,
#     and the old version is put back if the fresh install fails.
#   - A and B are different packages claiming one file: A is installed from a
#     local file with --replacefiles; nothing is erased. --nodeps because A may
#     need other updates from the same transaction; the next dnf pass pulls them.
# Returns 0 if at least one conflict was fixed, 1 if nothing could be done.
handle_file_conflicts() {
    local out="$1"
    local pairs
    pairs=$(printf '%s\n' "$out" \
        | grep -oP 'from install of \S+ conflicts with file from package \S+' \
        | awk '{print $4, $NF}' | sort -u)
    [ -z "$pairs" ] && return 1

    local want have wname hname arch dir new old fixed=1
    while read -r want have <&3; do
        hname=$(rpm -q --qf '%{NAME}' "$have" 2>/dev/null) || continue
        arch=$(rpm -q --qf '%{ARCH}' "$have" 2>/dev/null)
        wname=${want%-*-*}
        dir=$(mktemp -d /var/tmp/dnf-auto-update.XXXXXX) || continue
        mkdir -p "$dir/new" "$dir/old"

        log "File conflict: installing $want vs installed $have -- downloading before touching anything"
        dnf download -q --destdir "$dir/new" "$want"
        new=$(ls "$dir"/new/*.rpm 2>/dev/null | head -n1)

        if [ -z "$new" ]; then
            log "WARNING: could not download $want, leaving $have untouched"
        elif [ "$wname" != "$hname" ]; then
            if rpm -Uvh --replacefiles --nodeps "$new"; then
                log "$want installed over files of $have (--replacefiles)"
                fixed=0
            else
                log "WARNING: rpm -U --replacefiles $want failed, nothing was changed"
            fi
        else
            dnf download -q --arch "$arch" --destdir "$dir/old" "$have" &>/dev/null
            old=$(ls "$dir"/old/*.rpm 2>/dev/null | head -n1)
            [ -z "$old" ] && log "WARNING: $have is no longer in the repos, no rollback copy"
            log "Removing $have (rpm -e --nodeps) and installing $want from the local file"
            rpm -e --nodeps "$have"
            if dnf install -y "$new"; then
                fixed=0
            else
                log "WARNING: install of $want failed, restoring $have"
                if [ -n "$old" ] && rpm -ivh --nodeps "$old"; then
                    log "$have restored"
                else
                    log "WARNING: $hname is NOT installed anymore -- manual check needed"
                    lost_pkgs+=("$hname")
                fi
            fi
        fi
        rm -rf "$dir"
    done 3<<< "$pairs"
    return $fixed
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
    local level=0 i flags out rc fixed

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
            fixed=$?
            # Escalating to --allowerasing now could erase whatever depended
            # on a package that is gone, so stop and leave it to a human.
            if [ ${#lost_pkgs[@]} -gt 0 ]; then
                return 1
            fi
            [ $fixed -eq 0 ] && continue
            log "File conflict could not be resolved automatically"
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

installed_kernels() {
    local d v
    for d in /lib/modules/*/; do
        v=$(basename "$d")
        [ -e "/boot/vmlinuz-$v" ] && echo "$v"
    done | sort -V
}

newest_kernel() {
    installed_kernels | tail -n1
}

# Package names a driver may have for kernel $2: with and without ".<arch>".
kmod_candidates() {
    local base=$1 k=$2 short
    echo "${base}_${k}"
    short="${k%.$(uname -m)}"
    [ "$short" != "$k" ] && echo "${base}_${short}"
    return 0
}

# True if every driver in $2 (whitespace list) is installed for kernel $1.
kernel_has_kmods() {
    local k=$1 base cand ok
    for base in $2; do
        ok=0
        for cand in $(kmod_candidates "$base" "$k"); do
            rpm -q "$cand" &>/dev/null && { ok=1; break; }
        done
        [ $ok -eq 1 ] || return 1
    done
    return 0
}

# Kernel-module packages on RED OS carry the full kernel build in their name
# (nvidia-kmod_6.1.158-1.el7.x86_64), so a new kernel -- even a minor one --
# never gets its drivers through `dnf update`. For every driver installed for
# any kernel, install the same driver for the newest kernel. If one is missing
# from the repo, make the newest kernel that has all drivers the boot default so
# the next boot does not come up without, say, the GPU driver; lift the pin once
# the driver appears.
follow_kmods() {
    [ "$KMOD_FOLLOW" = yes ] || return 0

    local newest
    newest=$(newest_kernel)
    [ -z "$newest" ] && return 0

    # Driver names without the "_<kernel build>" suffix, deduplicated across kernels.
    # The build may itself contain "_" (".x86_64"), so cut at "_<digits>.<digits>...-".
    local kre='_[0-9]+\.[0-9]+(\.[0-9]+)?-.*$'
    local bases
    bases=$(rpm -qa --qf '%{NAME}\n' | grep -E "$kre" | sed -E "s/$kre//" | sort -u)

    local missing=() base cand ok
    for base in $bases; do
        kernel_has_kmods "$newest" "$base" && continue
        ok=0
        for cand in $(kmod_candidates "$base" "$newest"); do
            log "Installing kernel module package $cand for kernel $newest"
            if dnf install -y "$cand"; then ok=1; break; fi
        done
        [ $ok -eq 0 ] && missing+=("$base")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log "WARNING: no kernel module package for $newest: ${missing[*]}"
        local k fallback=""
        for k in $(installed_kernels | sort -rV); do
            [ "$k" = "$newest" ] && continue
            if kernel_has_kmods "$k" "$bases"; then fallback=$k; break; fi
        done
        if [ -z "$fallback" ]; then
            log "WARNING: no installed kernel has all of: $(echo $bases) -- boot default left as is, manual check needed"
        elif ! command -v grubby &>/dev/null; then
            log "WARNING: grubby not found, cannot make $fallback the boot default -- next boot may use $newest without those modules"
        elif grubby --set-default "/boot/vmlinuz-$fallback"; then
            mkdir -p "$STATEDIR"
            echo "$newest" > "$PINFILE"
            log "Boot default set to $fallback until modules for $newest are available"
        else
            log "WARNING: grubby --set-default failed -- next boot may use $newest without those modules"
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

if [ ${#lost_pkgs[@]} -gt 0 ]; then
    log "=== dnf auto-update FAILED: packages removed and not restored: ${lost_pkgs[*]} ==="
    exit 1
elif [ $success -eq 1 ]; then
    log "=== dnf auto-update finished OK ==="
    exit 0
else
    log "=== dnf auto-update FAILED after $MAX_ITERATIONS attempts -- needs manual review, see log above ==="
    exit 1
fi
