# RedOS Autoupdater

A systemd timer + self-healing shell script for unattended `dnf update -y` on
RED OS (and, generically, any RHEL-family distro). Built to be safe to leave
running on a machine nobody is watching.

## What it does

- Runs once right after the package is installed, 5 minutes after every boot,
  and every 3 days after that.
- A machine that was powered off at the scheduled time catches up through
  the boot run. The 3-day interval counts uptime (monotonic clock), not
  calendar days.
- If `dnf update -y` fails, escalates through `--allowerasing`, then
  `--setopt=best=False`, then `--skip-broken`.
- Separately handles RPM **file conflicts**, which no dnf flag fixes (they are
  caught during the rpm transaction check, not dependency resolution). The
  packages involved are downloaded first, so nothing is erased while the
  network or repos might fail. A conflict between two packages is fixed with
  `rpm -U --replacefiles` of the new package -- nothing is removed. A path
  that changes type within one package (a directory becoming a symlink) needs
  the old copy erased: `rpm -e --nodeps`, then `dnf install` of the local file,
  and the old version is put back if that fails. If a package still ends up
  missing, the run stops instead of escalating to `--allowerasing`, which
  could erase whatever depended on it.
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
last update in February 2025). The 7.3 script installs `redos-kernels6-release`
once; from then on the regular `dnf update` brings the 6.1 kernel. It never
reboots: the new kernel is used after the next reboot by the user. Turn this
off with `KERNEL6_SWITCH=no` in `/etc/sysconfig/dnf-auto-update`.

## Install

Grab the `.rpm` for your release from [`dist/`](dist/) and:

```sh
dnf install ./dnf-auto-update-1.2-1.el7.noarch.rpm     # RED OS 7.3
dnf install ./dnf-auto-update-1.2-1.red80.noarch.rpm   # RED OS 8
```

On first install the package enables the timer and starts one update run
right away (it waits for the installing dnf to finish) -- no reboot needed.
Check it with:

```sh
systemctl list-timers dnf-auto-update.timer
journalctl -u dnf-auto-update.service
```

## Build from source

On a RED OS host (as root, or with rpm-build already installed):

```sh
./build-rpm.sh        # -> dist/*.noarch.rpm, dist/*.src.rpm
```

CI (`.github/workflows/build-rpm.yml`) builds the package in the official
RED OS 7.3 and 8 containers (`registry.red-soft.ru/ubi7/ubi`, `ubi8/ubi`),
installs it and does one real update run there (`ci/smoke-test.sh`). Ready
packages for both releases are kept in [`dist/`](dist/).

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
