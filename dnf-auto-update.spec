Name:           dnf-auto-update
Version:        1.0
Release:        1%{?dist}
Summary:        Unattended dnf updates every 3 days with automatic conflict resolution

License:        MIT
URL:            https://github.com/PureshkaM/RedOS-Autoupdater
BuildArch:      noarch
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  systemd-rpm-macros
Requires:       dnf
Requires:       systemd
Requires:       util-linux
%{?systemd_requires}

%description
A systemd timer and a self-healing shell script that keep an RPM-based
system (built for RED OS, works on any RHEL-family distro) up to date
without babysitting.

- Runs 5 minutes after boot and every 3 days after that.
- If the machine was powered off at the scheduled time, systemd's
  Persistent=true guarantees the missed run fires once at next boot instead
  of being skipped.
- On failure, escalates dnf update -y through --allowerasing, then
  --best=false, then --skip-broken.
- Separately detects RPM file-type conflicts (a path changing from a
  directory to a symlink between package versions, etc.) that no dnf flag
  can fix because they are caught during the rpm transaction check, not
  dependency resolution -- the script removes the stale copy and reinstalls
  the package cleanly.
- After a successful update, checks that display-manager.service (whatever
  desktop environment is installed -- KDE/sddm, GNOME/gdm, MATE/lightdm, ...)
  is still active and restarts it if the update knocked it down.
- Refuses to run two copies at once (flock).

%prep
%setup -q

%install
install -Dm0755 dnf-auto-update.sh %{buildroot}%{_sbindir}/dnf-auto-update
install -Dm0644 dnf-auto-update.service %{buildroot}%{_unitdir}/dnf-auto-update.service
install -Dm0644 dnf-auto-update.timer %{buildroot}%{_unitdir}/dnf-auto-update.timer
install -Dm0644 dnf-auto-update.logrotate %{buildroot}%{_sysconfdir}/logrotate.d/dnf-auto-update

%files
%license LICENSE
%doc README.md
%{_sbindir}/dnf-auto-update
%{_unitdir}/dnf-auto-update.service
%{_unitdir}/dnf-auto-update.timer
%config(noreplace) %{_sysconfdir}/logrotate.d/dnf-auto-update

%post
%systemd_post dnf-auto-update.timer
systemctl enable --now dnf-auto-update.timer >/dev/null 2>&1 || :

%preun
%systemd_preun dnf-auto-update.timer

%postun
%systemd_postun_with_restart dnf-auto-update.timer

%changelog
* Mon Aug 24 2026 Maksim Khripunov <xripmax@gmail.com> - 1.0-1
- Initial release
