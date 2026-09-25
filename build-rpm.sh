#!/bin/bash
# Build the binary and source RPM on the current RED OS host into ./dist.
# Needs root only to install missing build dependencies.
set -euo pipefail
cd "$(dirname "$0")"

NAME=dnf-auto-update
VER=$(awk '/^Version:/ {print $2}' $NAME.spec)
SOURCES=(
    dnf-auto-update-dispatch.sh dnf-auto-update.sh dnf-auto-update-redos73.sh
    dnf-auto-update.sysconfig dnf-auto-update.service dnf-auto-update.timer
    dnf-auto-update.logrotate README.md LICENSE
)

if ! command -v rpmbuild &>/dev/null; then
    dnf install -y rpm-build tar gzip
fi
# systemd-rpm-macros is a separate package only on newer releases; elsewhere
# the macros ship with systemd itself.
if ! rpm --eval '%{?systemd_post:ok}' | grep -q ok; then
    dnf install -y systemd-rpm-macros
fi

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}
tar czf "$top/SOURCES/$NAME-$VER.tar.gz" --transform "s,^,$NAME-$VER/," "${SOURCES[@]}"
rpmbuild -ba $NAME.spec --define "_topdir $top"

mkdir -p dist
cp -v "$top"/RPMS/noarch/*.rpm "$top"/SRPMS/*.rpm dist/
