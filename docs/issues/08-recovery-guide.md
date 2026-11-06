Title: Write the recovery guide

## Goal
Anyone can repair a system that does not boot, using only this guide and the live ISO.

## Scope
Create `docs/RECOVERY.md`, linked from the README, covering:
- unlocking the LUKS volume from the ISO and mounting `@`, `@home`, `@snapshots`, and the ESP
- entering the system with `arch-chroot`
- rebuilding the initramfs and reinstalling the bootloader
- rolling back a snapshot and restoring `/boot` from its copy
- what to do with a header backup, if one exists

## Acceptance test (UEFI VM)
Break a VM on purpose, for example by deleting the initramfs image, then recover it by following only the guide.

## Depends on
Items 2 and 4.
