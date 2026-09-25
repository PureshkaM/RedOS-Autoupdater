Name:           dnf-auto-update
Version:        1.1
Release:        1%{?dist}
Summary:        Unattended dnf updates every 3 days with automatic conflict resolution

License:        MIT
URL:            https://github.com/PureshkaM/RedOS-Autoupdater
BuildArch:      noarch
# xz instead of the zstd default so a package built on RED OS 8 installs on 7.3.
%global _binary_payload w9.xzdio
%global _source_payload w9.xzdio
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  systemd-rpm-macros
Requires:       dnf
# dnf download: fetch packages before erasing anything on a file conflict.
Requires:       dnf-plugins-core
Requires:       systemd
Requires:       util-linux
%{?systemd_requires}

%description
A systemd timer and a self-healing shell script that keep an RPM-based
system (built for RED OS, works on any RHEL-family distro) up to date
without babysitting.

- Runs 5 minutes after boot and every 3 days after that.
- A machine that was powered off at the scheduled time catches up via the
  boot run; the 3-day interval counts uptime (monotonic clock), not calendar
  of being skipped.
- On failure, escalates dnf update -y through --allowerasing, then
  --setopt=best=False, then --skip-broken.
- Separately handles RPM file conflicts that no dnf flag can fix: packages
  are downloaded first, a conflict between packages is fixed with
  rpm -U --replacefiles, and only a path changing type within one package
  (directory to symlink) erases the old copy, with rollback to the old
  version if the fresh install fails.
- After a successful update, checks that display-manager.service (whatever
  desktop environment is installed -- KDE/sddm, GNOME/gdm, MATE/lightdm, ...)
  is still active and restarts it if the update knocked it down.
- Refuses to run two copies at once (flock).
- Picks a per-release script by /etc/os-release. On RED OS 7.3 it also moves
  the machine to the supported Linux 6.1 kernel branch (kernels6 repo) and
  installs kernel-module packages for the new kernel, keeping the current
  kernel as boot default while a module is missing. It never reboots.

%prep
%setup -q

%install
install -Dm0755 dnf-auto-update-dispatch.sh %{buildroot}%{_sbindir}/dnf-auto-update
install -Dm0755 dnf-auto-update.sh %{buildroot}%{_libexecdir}/dnf-auto-update/redos-8
install -Dm0755 dnf-auto-update-redos73.sh %{buildroot}%{_libexecdir}/dnf-auto-update/redos-7.3
install -Dm0644 dnf-auto-update.sysconfig %{buildroot}%{_sysconfdir}/sysconfig/dnf-auto-update
install -dm0755 %{buildroot}%{_sharedstatedir}/dnf-auto-update
install -Dm0644 dnf-auto-update.service %{buildroot}%{_unitdir}/dnf-auto-update.service
install -Dm0644 dnf-auto-update.timer %{buildroot}%{_unitdir}/dnf-auto-update.timer
install -Dm0644 dnf-auto-update.logrotate %{buildroot}%{_sysconfdir}/logrotate.d/dnf-auto-update

%files
%license LICENSE
%doc README.md
%{_sbindir}/dnf-auto-update
%{_libexecdir}/dnf-auto-update/
%dir %{_sharedstatedir}/dnf-auto-update
%config(noreplace) %{_sysconfdir}/sysconfig/dnf-auto-update
%{_unitdir}/dnf-auto-update.service
%{_unitdir}/dnf-auto-update.timer
%config(noreplace) %{_sysconfdir}/logrotate.d/dnf-auto-update

%post
%systemd_post dnf-auto-update.timer
# Fresh install only: on upgrade this would re-enable a timer the admin disabled.
if [ $1 -eq 1 ]; then
    systemctl enable --now dnf-auto-update.timer >/dev/null 2>&1 || :
fi

%preun
%systemd_preun dnf-auto-update.timer

%postun
%systemd_postun_with_restart dnf-auto-update.timer

%changelog
* Fri Sep 25 2026 Maksim Khripunov <xripmax@gmail.com> - 1.1-1
- Dispatch to a per-release script by /etc/os-release
- RED OS 7.3: switch to the Linux 6.1 kernel branch (redos-kernels6-release)
- RED OS 7.3: install kernel-module packages for the new kernel, keep the
  running kernel as boot default while any of them is missing
- xz payload so the package installs on RED OS 7.3
- Fix: --best=false is invalid in dnf 4, use --setopt=best=False
- File conflicts: download first, --replacefiles for conflicts between
  packages, erase + local install with rollback only for path type changes;
  stop instead of escalating to --allowerasing if a package got lost
- Fix: do not re-enable the timer on package upgrade
- Drop Persistent=true: it only applies to OnCalendar= timers

* Mon Aug 24 2026 Maksim Khripunov <xripmax@gmail.com> - 1.0-1
- Initial release
