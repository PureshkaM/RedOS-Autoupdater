#!/bin/bash
# Run inside a RED OS container after build-rpm.sh: install the package and
# do one real update run against the RED OS repositories. No systemd, no
# kernel in a container, so the timer, display-manager and kmod parts are
# only exercised as far as they can be there.
set -uo pipefail
cd "$(dirname "$0")/.."

section() { echo; echo "######## $*"; }
fail=0
check() { if "$@" >/dev/null 2>&1; then echo "PASS: $*"; else echo "FAIL: $*"; fail=1; fi; }

section "OS"
cat /etc/os-release
cat /etc/redos-release 2>/dev/null || echo "(no /etc/redos-release)"
bash --version | head -n1
dnf --version | head -n1

section "Package"
# Pick the package built for this release by its dist tag; OUT may hold others.
rpm=$(ls "${OUT:-dist}"/*"$(rpm --eval '%{?dist}')".noarch.rpm | head -n1)
echo "testing $rpm"
rpm -qpi "$rpm"
echo "payload: $(rpm -qp --qf '%{PAYLOADCOMPRESSOR}' "$rpm")"
rpm -qp --requires "$rpm"
dnf install -y "$rpm"
check rpm -q dnf-auto-update
rpm -ql dnf-auto-update

section "Tools the scripts rely on"
check rpm -q dnf-plugins-core
check dnf download --help
# --assumeno exits 1 when there is something to decline, so only look for a parse error.
if dnf update --assumeno --setopt=best=False 2>&1 | grep -qi 'unrecognized\|invalid\|error: argument'; then
    echo 'FAIL: --setopt=best=False rejected'; fail=1
else
    echo 'PASS: --setopt=best=False accepted'
fi
echo 'grep -P:'; check sh -c "echo 'from package foo-1' | grep -oP '(?<=from package )\S+'"
command -v grubby || echo "(grubby not installed in this image)"

section "Dispatcher routing"
. /etc/os-release
case "${VERSION_ID%%.*}" in
    7) expect=redos-7.3 ;;
    8) expect=redos-8 ;;
esac
# Swap the real scripts for markers just to see which one gets exec'd.
for s in /usr/libexec/dnf-auto-update/*; do cp "$s" "$s.real"; printf '#!/bin/sh\necho RAN %s\n' "$(basename "$s")" > "$s"; done
got=$(/usr/sbin/dnf-auto-update)
for s in /usr/libexec/dnf-auto-update/*.real; do mv "$s" "${s%.real}"; done
echo "$got"
check [ "$got" = "RAN $expect" ]

section "Real run: /usr/sbin/dnf-auto-update"
# Newer 7.3 images already ship the kernels6 repo; drop it so the switch path runs.
if [ "$expect" = redos-7.3 ]; then
    rpm -e --nodeps redos-kernels6-release 2>/dev/null && echo "(removed redos-kernels6-release to exercise the switch)"
fi
timeout 1500 /usr/sbin/dnf-auto-update
rc=$?
echo "exit code: $rc"
check [ $rc -eq 0 ]
if [ "$expect" = redos-7.3 ]; then
    check rpm -q redos-kernels6-release
    check grep -q 'Enabling kernels6' /var/log/dnf-auto-update.log
    dnf repolist
fi

section "Result"
[ $fail -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
