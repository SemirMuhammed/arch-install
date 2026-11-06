Title: Hide the boot menu by default (timeout 0)

## Goal
Remove the 3-second wait at every boot.

## Why
With `timeout 0` systemd-boot does not show the menu, but holding a key at startup still shows it (`loader.conf` man page). `systemd-analyze` cannot measure this on the test VM: it reports no loader time, and the passphrase prompt is counted in the "kernel" figure.

## Scope
- Set `timeout 0` in `loader.conf`.
- Document how to reach the menu, which matters once there are two kernel entries.
- Update `DECISIONS.md`, `README.md`, `CHANGELOG.md`.

## Acceptance test (UEFI VM)
- No menu appears on a normal boot.
- Holding a key shows it.
- A stopwatch from power-on to the passphrase prompt shows the saving.

## Depends on
Item 4 (second kernel entry).
