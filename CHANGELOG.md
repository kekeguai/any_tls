# Changelog

## 2026-11-02

- Added package manager detection and installation support for Debian/Ubuntu (`apt`), CentOS/RHEL/Rocky/AlmaLinux/Fedora (`dnf`, falling back to `yum`), Arch/Manjaro (`pacman`), and Alpine (`apk add --no-cache`).
- Added a service management abstraction for systemd and OpenRC, including enable, start, stop, restart, status, and platform-specific log viewing.
- Added systemd unit and OpenRC init script generation. OpenRC loads credentials through a restricted helper that reads `/etc/anytls/config.env`; credentials are no longer embedded in service definitions.
- Added firewall capability checks for UFW, firewalld, iptables, and nftables, with marker-based cleanup for rules created by the script.
- Updated uninstall to remove the selected init service, OpenRC helper/log/PID files, binary, management command, and configuration.
- Validation on this Windows host: `bash -n` and `git diff --check` passed; a Bash fixture generated and checked the OpenRC init script and config-driven runner successfully. This is a mocked generation check, not a real Alpine/OpenRC service run. Docker/Podman are unavailable and no WSL distribution is installed, so Alpine runtime validation remains outstanding.

## Follow-up: Alpine qrencode repository handling

- Explain that Alpine may not expose `qrencode` when its matching `community` repository is disabled, and show the commands to enable/update the source and install it.
- Track the qrencode install attempt so a failed initial install does not immediately repeat the same failing apk request when rendering the QR code.
- Validation: pending for this follow-up.
