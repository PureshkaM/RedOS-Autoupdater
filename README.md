# RedOS Autoupdater

A systemd timer + self-healing shell script for unattended `dnf update -y` on
RED OS (and, generically, any RHEL-family distro). Built to be safe to leave
running on a machine nobody is watching.

## What it does

- Runs 5 minutes after boot, then every 3 days after that.
- If the machine was powered off at the scheduled time, `Persistent=true`
  makes systemd run the missed update once at the next boot instead of
  skipping it.
- If `dnf update -y` fails, escalates through `--allowerasing`, then
  `--best=false`, then `--skip-broken`.
- Separately detects RPM **file-type conflicts** -- e.g. a path that was a
  directory in the old package version and becomes a symlink in the new one.
  No dnf flag fixes this (it's caught during the rpm transaction check, not
  dependency resolution); the script removes the stale copy with
  `rpm -e --nodeps` and reinstalls the package cleanly with `dnf install -y`.
- After a successful update, checks that `display-manager.service` (whichever
  desktop is installed -- KDE/sddm, GNOME/gdm, MATE/lightdm, ...) is still
  active, and restarts it if the update knocked it down. Manually removing
  and reinstalling a package outside of dnf's normal atomic transaction
  skips the `%post`/`%postun` service-restart scriptlets a package would
  normally get, so this check exists specifically to cover that gap.
- Refuses to run two copies at once (`flock`).
- Logs to `/var/log/dnf-auto-update.log` (rotated weekly, 8 weeks kept) and
  to `journalctl -u dnf-auto-update.service`.

## Install

Grab a `.rpm` from [Releases](../../releases) and:

```sh
dnf install ./dnf-auto-update-1.0-1.noarch.rpm
```

The package's `%post` scriptlet enables and starts the timer immediately --
no reboot needed. Check it with:

```sh
systemctl list-timers dnf-auto-update.timer
journalctl -u dnf-auto-update.service
```

## Build from source

```sh
tar czf dnf-auto-update-1.0.tar.gz --transform 's,^,dnf-auto-update-1.0/,' \
    dnf-auto-update.sh dnf-auto-update.service dnf-auto-update.timer \
    dnf-auto-update.logrotate README.md LICENSE
rpmbuild -ba dnf-auto-update.spec --define "_sourcedir $(pwd)"
```

Build dependencies: `rpm-build`, `systemd-rpm-macros`.

## Notes / known limitations

- Tested end-to-end on RED OS 8.0 (dnf 4.17.0): real-world file conflict,
  a synthetic file conflict, killed display manager recovery, concurrent-run
  locking, and an actual reboot to confirm the boot trigger and the 3-day
  `Persistent=true` catch-up all work as described.
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
