# Changelog

## 2026-11-02

- Added package manager detection and installation support for Debian/Ubuntu (`apt`), CentOS/RHEL/Rocky/AlmaLinux/Fedora (`dnf`, falling back to `yum`), Arch/Manjaro (`pacman`), and Alpine (`apk add --no-cache`).
- Added a service management abstraction for systemd and OpenRC, including enable, start, stop, restart, status, and platform-specific log viewing.
- Added systemd unit and OpenRC init script generation. OpenRC loads credentials through a restricted helper that reads `/etc/anytls/config.env`; credentials are no longer embedded in service definitions.
- Added firewall capability checks for UFW, firewalld, iptables, and nftables, with marker-based cleanup for rules created by the script.
- Updated uninstall to remove the selected init service, OpenRC helper/log/PID files, binary, management command, and configuration.
- Validation on this Windows host: `bash -n` and `git diff --check` passed; a Bash fixture generated and checked the OpenRC init script and config-driven runner successfully. This is a mocked generation check, not a real Alpine/OpenRC service run. Docker/Podman are unavailable and no WSL distribution is installed, so Alpine runtime validation remains outstanding.

## Follow-up: QR generation on Alpine

- The Alpine 3.24 community index does not contain the `qrencode` package, so repository selection cannot resolve this package on the affected host.
- Replaced Alpine's package-based QR dependency with a self-contained Python standard-library QR encoder. Alpine installs Python 3 from its standard repositories, and the script generates terminal output and a PNG locally without `qrencode`.
- Validation: generated a valid 246x246 RGB PNG and independently decoded it with ZXing; decoded payload exactly matched the AnyTLS URI. Bash syntax and `git diff --check` passed.

## Follow-up: command lookup on Alpine

- Install the `anytls` command in both `/usr/local/bin` and `/usr/local/sbin`, and remove both copies during uninstall. This makes the command available in Alpine shells whose default `PATH` includes `/usr/local/bin` but omits `/usr/local/sbin`.
- Validation: management command dual-install/cleanup fixture passed; Bash syntax and `git diff --check` passed.
