Title: Add snapshot foundation (@snapshots, /boot sync hook, snap-pac)

## Goal
Make rollback work, so a bad update can be undone without a kernel and module mismatch.

## Why
- The ESP is mounted at `/boot`, so the kernel and initramfs sit on FAT, outside every snapshot. After a rollback, the modules in `@` can mismatch the kernel on the ESP (Arch wiki, Snapper; forum discussion of the `/boot` hook).
- The wiki's suggested snapper layout uses a separate `@snapshots` subvolume mounted at `/.snapshots`. This installer creates only `@` and `@home`.
- `snapper` 0.13.2 and `snap-pac` 3.0.1 are available in the repositories (checked on the test VM).

## Scope
- Create `@snapshots` in stage 03, mount it at `/.snapshots`, and keep the stage 06 mount validation in sync.
- Install snapper and snap-pac. Create the root config without leaving a nested `.snapshots` subvolume.
- Add a pacman hook that copies `/boot` into the root subvolume before snap-pac's pre-snapshot, so each snapshot holds the kernel that matches its modules. The exact ordering is confirmed by the acceptance test.
- Set limited retention by default.
- Update `DECISIONS.md` (layout, and the privacy cost: snapshots keep deleted files on disk), `README.md`, `CHANGELOG.md`, and tests.

## Acceptance test (UEFI VM)
1. Install, then upgrade a package so snap-pac creates a pre and post pair.
2. Upgrade the kernel, then roll back to the earlier snapshot and restore `/boot` from its copy.
3. Reboot. `uname -r` matches a directory in `/usr/lib/modules`, and the system boots.

## Depends on
Item 1 (retention and privacy decision).

## Out of scope
Booting snapshots from the menu. No systemd-boot tool for this has been verified. Rollback is done from the live ISO and described in the recovery guide.
