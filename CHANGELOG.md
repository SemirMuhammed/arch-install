# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Redesigned terminal output: colour, a stage progress bar, status lines, and
  titled panels for warnings, confirmations, success, and failure.
- Keyboard and disk selection are numbered menus that accept a number or a name.
- Yes/no questions take a default and accept `y`, `yes`, `n`, or `no`.
- Colour turns off automatically outside a terminal, and `NO_COLOR=1` disables it.
- The installer log and the target-side payload output remain plain text.

## [0.1.0] - 2026-11-04

First public release.

### Added

- Six-stage installer: verify, config, partition, pacstrap, chroot, and post.
- Entry point `install.sh` with `--dry-run`, `--from NN`, and `--help`.
- LUKS2 full-disk encryption, a Btrfs root with `@` and `@home` subvolumes,
  and systemd-boot with a `linux-lts` kernel.
- Unattended mode through `/root/arch-install.answers`.
- Opt-in geo-IP lookup for unattended runs (`GEO_LOOKUP=1`), with confirmation in
  interactive mode.
- Unit test suite (`tests/unit.sh`) and CI running syntax checks, shellcheck, and tests.

### Security

- The password hash is sent to the target's `chpasswd` on stdin and never written to the
  target disk.
- The EFI partition is mounted with `umask=0077`, and the installer verifies this in both
  the live mount and the target `fstab`.
- Destructive operations check for the boot medium, mounted filesystems, and holders
  before touching a disk.

### Known limitations

- Tested end-to-end in a UEFI virtual machine only. Not yet tested on physical hardware.
- Requires the official Arch ISO booted in UEFI mode.
- The optional geo-IP lookup uses plain HTTP on the free tier of ip-api.com.
