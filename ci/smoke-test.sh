#!/bin/bash
# Run inside a RED OS container after build-rpm.sh: install the package and
# do one real update run against the RED OS repositories. No systemd, no
# kernel in a container, so the timer, display-manager and kmod parts are
# only exercised as far as they can be there.
set -uo pipefail
cd "$(dirname "$0")/.."

section() { echo; echo "######## $*"; }
fail=0
check() { if "$@"; then echo "PASS: $*"; else echo "FAIL: $*"; fail=1; fi; }

section "OS"
cat /etc/os-release
cat /etc/redos-release 2>/dev/null || echo "(no /etc/redos-release)"
bash --version | head -n1
dnf --version | head -n1

section "Package"
rpm=$(ls dist/*.noarch.rpm | head -n1)
rpm -qpi "$rpm"
echo "payload: $(rpm -qp --qf '%{PAYLOADCOMPRESSOR}' "$rpm")"
rpm -qp --requires "$rpm"
check dnf install -y "$rpm"
rpm -ql dnf-auto-update

section "Tools the scripts rely on"
check rpm -q dnf-plugins-core
check dnf download --help >/dev/null
check dnf update --assumeno --setopt=best=False >/dev/null
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
timeout 1500 /usr/sbin/dnf-auto-update
rc=$?
echo "exit code: $rc"
check [ $rc -eq 0 ]
if [ "$expect" = redos-7.3 ]; then
    check rpm -q redos-kernels6-release
    dnf repolist
fi

section "Result"
[ $fail -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
