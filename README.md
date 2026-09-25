# RedOS Autoupdater

A systemd timer + self-healing shell script for unattended `dnf update -y` on
RED OS (and, generically, any RHEL-family distro). Built to be safe to leave
running on a machine nobody is watching.

## What it does

- Runs 5 minutes after boot, then every 3 days after that.
- A machine that was powered off at the scheduled time catches up through
  the boot run. The 3-day interval counts uptime (monotonic clock), not
  calendar days.
- If `dnf update -y` fails, escalates through `--allowerasing`, then
  `--setopt=best=False`, then `--skip-broken`.
- Separately detects RPM **file-type conflicts** -- e.g. a path that was a
  directory in the old package version and becomes a symlink in the new one.
  No dnf flag fixes this (it's caught during the rpm transaction check, not
  dependency resolution); the script removes the stale copy with
  `rpm -e --nodeps` and reinstalls the package cleanly with `dnf install -y`.
  If that reinstall fails, the old version is put back; if even that fails,
  the run is reported as FAILED with the missing package named.
- After a successful update, checks that `display-manager.service` (whichever
  desktop is installed -- KDE/sddm, GNOME/gdm, MATE/lightdm, ...) is still
  active, and restarts it if the update knocked it down. Manually removing
  and reinstalling a package outside of dnf's normal atomic transaction
  skips the `%post`/`%postun` service-restart scriptlets a package would
  normally get, so this check exists specifically to cover that gap.
- Refuses to run two copies at once (`flock`).
- Detects the RED OS release from `/etc/os-release` and runs the matching
  script from `/usr/libexec/dnf-auto-update/` (`redos-8`, `redos-7.3`;
  anything unrecognized falls back to `redos-8`).
- Logs to `/var/log/dnf-auto-update.log` (rotated weekly, 8 weeks kept) and
  to `journalctl -u dnf-auto-update.service`.

## RED OS 7.3 specifics

On 7.3 only the Linux 6.1 kernel branch is still fully supported (5.15 got its
last update in February 2025). The 7.3 script therefore:

- after a successful `dnf update`, installs `redos-kernels6-release`, runs
  `dnf makecache` and updates again -- the procedure from the RED OS knowledge
  base article "Обновление ядра Linux до версии 6.1 в РЕД ОС 7.3";
- installs kernel-module packages for the newest kernel. On RED OS their name
  carries the kernel build (`nvidia-kmod_$(uname -r)`), so `dnf update` never
  brings them along with a new kernel. If a module for the new kernel is not
  in the repo yet, the running kernel stays the grub default (via `grubby`)
  until it appears; the pin is recorded in `/var/lib/dnf-auto-update/pinned-kernel`;
- never reboots: the new kernel is used after the next reboot by the user.

Both behaviours can be turned off in `/etc/sysconfig/dnf-auto-update`
(`KERNEL6_SWITCH`, `KMOD_FOLLOW`).

## Install

Grab a `.rpm` from [Releases](../../releases) and:

```sh
dnf install ./dnf-auto-update-1.1-1.noarch.rpm
```

The package's `%post` scriptlet enables and starts the timer immediately --
no reboot needed. Check it with:

```sh
systemctl list-timers dnf-auto-update.timer
journalctl -u dnf-auto-update.service
```

## Build from source

```sh
tar czf dnf-auto-update-1.1.tar.gz --transform 's,^,dnf-auto-update-1.1/,' \
    dnf-auto-update-dispatch.sh dnf-auto-update.sh dnf-auto-update-redos73.sh \
    dnf-auto-update.sysconfig dnf-auto-update.service dnf-auto-update.timer \
    dnf-auto-update.logrotate README.md LICENSE
rpmbuild -ba dnf-auto-update.spec --define "_sourcedir $(pwd)"
```

Build dependencies: `rpm-build`, `systemd-rpm-macros`.

## Notes / known limitations

- Tested end-to-end on RED OS 8.0 (dnf 4.17.0): real-world file conflict,
  a synthetic file conflict, killed display manager recovery, concurrent-run
  locking, and an actual reboot to confirm the boot trigger all work as
  described (on 1.0, before the 1.1 fixes).
- The RED OS 7.3 script has not been run on a real 7.3 machine yet.
- The display-manager recovery uses the generic `display-manager.service`
  alias rather than hardcoding sddm, so it should cover GNOME/gdm and
  MATE/lightdm installs too -- but that path has only been verified on a
  KDE/sddm desktop so far, not on a GNOME or MATE machine.
- If the machine is shut down *while* an update is actually running, systemd
  sends SIGTERM to the script and the in-progress dnf transaction is
  interrupted. dnf/rpm are transactional and this has been observed to
  recover cleanly on the next run, but it isn't a hard guarantee -- raise
  `TimeoutStopSec` in the service unit if you need more grace period before
  shutdown kills it.

## License

MIT, see [LICENSE](LICENSE).
