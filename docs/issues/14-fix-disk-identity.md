Title: Verify the selected disk's identity between stage 02 and stage 03

## Problem
Stage 02 persists only `DISK=/dev/sda`. Between stages 02 and 03, `/dev/sda`
can become a different physical device — USB unplug/replug, SATA hot-swap,
driver reset, or the user swapping cables. Stage 03's typed confirmation
mitigates this, but only partially: it is the same string either way, so the
user's consent was given about one disk and stage 03 may erase another at the
same path.

## Why
Picking or erasing the wrong disk is the most expensive mistake this installer
can cause. The typed confirmation is the last line of defense today; a device
identity check is the second-to-last, and it is the one that catches a swap the
user did not notice. It is also the cheapest remaining win on the "wrong disk"
failure mode: no UI change, no new prompt, one state key and one comparison.

## Scope
- **Identifier chain.** `ID_SERIAL` → `ID_WWN` → `ID_PATH`. First non-empty
  wins. `ID_PATH` is the most universally available (present on anything PCI-
  attached, including virtio-blk and loop); `ID_SERIAL` and `ID_WWN` are
  stricter but sparse in VMs.
- **Storage.** Two new state keys: `DISK_ID_KIND` (`serial` | `wwn` | `path` |
  `none`) and `DISK_ID_VALUE`. Both added to `_COMMON_STATE_KEYS` in
  `lib/common.sh` so hex-encoding applies uniformly.
- **Capture point.** In `02-config.sh`'s `config_main`, after
  `config_select_disk` returns and immediately before `config_persist`. Not
  inside `persist` itself.
- **Verify point.** In `03-partition.sh`'s `partition_validate_state`, before
  any destructive call. Re-look-up **only the captured kind**, not all three:
  if stage 02 captured `serial=XYZ` and stage 03 only has `ID_PATH` set, the
  correct behavior is to compare XYZ to the same-kind lookup, not to compare a
  serial to a path.
- **Mismatch.** Hard-fail `die 21` — "disk identity changed since stage 02;
  re-run stage 02 and re-confirm the target disk". No typed override, no
  confirm-and-continue. A legitimate swap requires re-running stage 02, which
  re-checks busy/mounted/read-only as a bonus.
- **`kind == none`.** One `warn` line — "no stable disk identifier available;
  skipping identity check" — then proceed. Needed for virtio-blk VMs where
  none of the three identifiers may be exposed.
- **Missing keys (old state file).** `[[ -n ${DISK_ID_KIND:-} ]] || { warn …;
  return 0; }`. Graceful skip; only runs started after this change get the
  check.
- **Stage 03 only.** Stages 04–06 already prove the mapper-to-partition chain
  via `slaves` and `blkid` UUID matching. Disk identity adds nothing there.
- **README.** Add `21` to the exit-code table.
- **CHANGELOG.** Under `[0.1.1]`, with the two known limitations below.

## Acceptance test
Unit:
- `test_disk_identity_kind_chain` — mock `lsblk -o SERIAL,WWN,PATH` output and
  assert `serial > wwn > path > none` priority.
- `test_disk_identity_missing_state_key` — old state file → `warn` + `return 0`.

VM:
- Install through stage 02, then edit `state.env` between stages 02 and 03 to
  set `DISK_ID_VALUE=deadbeef` → stage 03 fails `die 21`, no disk modified.
- Edit `state.env` to set `DISK_ID_KIND=none` → stage 03 warns and proceeds.
- Virtio-blk without serial → `warn` fires, install completes.

## Known limitations (document in CHANGELOG)
- `ID_PATH` fallback misses "USB enclosure swapped for another in the same
  port" when neither disk exposes a serial.
- Old state files created before this change skip the check entirely.

## Rejected alternatives
- Warn + `ui_confirm "Continue?"` on mismatch. Wrong tone: the object of
  consent changed, not just an FYI.
- `ID_SERIAL`-only or `ID_WWN`-only. Breaks virtio-blk and loop.
- Capture all three and intersect. The "which side had it" edge case has no
  clean answer.
- Verify in 04–06. Defense theater; no new attack surface after the
  destructive gate.
- Reject old state files. Breaks mid-install resume.

## Out of scope
Binding the check to a cryptographic identity (e.g. an HMAC over the disk's
partition table). That is a roadmap item for the threat model, not a patch
release.

---
Patch-release fix for 0.1.1. Not a roadmap item.
