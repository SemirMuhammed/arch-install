Title: Add a second kernel boot entry

## Goal
A real fallback when a `linux-lts` update misbehaves.

## Why
The fallback initramfs differs from the default only by skipping `autodetect`. It does not help with a bad kernel or a broken hook. A second kernel does. A fresh install uses about 48 MiB of the 1 GiB ESP (measured), so space is not a constraint.

## Scope
- Add the `linux` package next to `linux-lts` in `PACSTRAP_BASE_PACKAGES` (`04-pacstrap.sh`).
- Generate initramfs images for both kernels, and write a second loader entry. Keep `linux-lts` as the default.
- Update the stage 05 and 06 validation, the `DECISIONS.md` kernel section, `README.md`, `CHANGELOG.md`, and tests.

## Acceptance test (UEFI VM)
- Both entries appear in the menu and boot.
- `uname -r` differs between them.
- `df -h /boot` stays well under capacity.

## Out of scope
Secure Boot signing.
