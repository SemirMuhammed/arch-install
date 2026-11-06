Title: Enable the Btrfs scrub timer and add an optional sysctl file

## Goal
Find silent corruption early, and apply a small, documented hardening set.

## Why
- `btrfs-scrub@.timer` exists but is disabled on the test VM (measured).
- Measured sysctl values: `kernel.kptr_restrict` 0, `kernel.unprivileged_bpf_disabled` 2, `net.core.bpf_jit_harden` 0, `kernel.dmesg_restrict` 1. A normal user already sees zeros in `/proc/kallsyms`, so the gain is modest.

## Scope
- Enable the scrub timer instance for `/`. Confirm the instance name with `systemd-escape -p /`.
- Add `/etc/sysctl.d/99-hardening.conf`: `kernel.kptr_restrict = 2`, `kernel.unprivileged_bpf_disabled = 1`, `net.core.bpf_jit_harden = 2` (values from a published hardening guide). Document each.
- Update `DECISIONS.md`, `README.md`, `CHANGELOG.md`.

## Acceptance test (UEFI VM)
- `systemctl list-timers` shows the scrub timer after install.
- After reboot, `sysctl` reports the configured values.

## Out of scope
A single-device scrub can detect data corruption but cannot repair it without a second copy. Say so in the docs.
