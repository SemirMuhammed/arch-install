---
name: Bug report
about: Report a problem with the installer
labels: bug
---

**Do not include passwords, password hashes, or your answers file.**

## What happened

A clear description of the problem.

## Where it stopped

- Stage (for example `03-partition.sh`):
- Exit code (the number in `ERROR [NN]`):
- Command you ran (for example `sudo ./install.sh --from 03`):

## Environment

- Install medium: official Arch ISO, release date:
- Boot mode: UEFI / other (run `ls /sys/firmware/efi`)
- Hardware or virtual machine (for example QEMU/KVM, VirtualBox, physical):
- Disk type: SATA / NVMe / virtio / other

## Log

Paste the last 30 lines of `/var/log/arch-install.log` (run `tail -n 30 /var/log/arch-install.log`).
Remove anything sensitive before posting.

## Anything else
