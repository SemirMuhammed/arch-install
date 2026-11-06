Title: Reorder post_finalize so state removal is the last mutating step

## Problem
`post_finalize` in `06-post.sh` removes the state file *before* unmounting
`/mnt`, closing the LUKS mapper, and asking about reboot:

```
post_remove_file "$STATE_FILE"     ← state gone
post_unmount_target                 ← if this fails: no resume possible
post_close_mapper                   ← same
sync                                ← same
ui_box "finalized"
ui_confirm "Reboot?"
```

Two failure modes fall out of this order:

1. Any error between state-removal and the reboot prompt leaves an
   **unresumable system**. A re-run of stage 06 fails `die 50 missing state`
   with no way forward except re-running from stage 02.
2. The decline-reboot branch does not tell the user the state was cleared, so a
   user who declines and reflexively re-runs stage 06 gets a confusing error.

## Why
The whole point of `POST_MARKER` (`CLEANUP` → `READY_TO_UNMOUNT`) is to make
stage 06 resumable. Removing the state file mid-flow defeats that guarantee
for every failure mode that comes after it. This is the deeper bug; the
decline-message wording is the visible symptom.

## Scope
- `06-post.sh`, `post_finalize` — move `post_remove_file "$STATE_FILE"` to the
  end, after `ui_confirm "Reboot?"` returns. Both the yes and no branches call
  it; the new order is:

  ```
  post_write_marker READY_TO_UNMOUNT  (unchanged)
  post_unmount_target
  post_close_mapper
  sync
  ui_box "finalized"
  ui_confirm "Reboot?"
  ├─ yes → post_remove_file $STATE_FILE → reboot
  └─ no  → post_remove_file $STATE_FILE → new decline message
  ```
- New decline message: "Reboot skipped. State cleared, /mnt unmounted, mapper
  closed. Remove the ISO and reboot manually. Do not re-run stage 06 — it
  needs the state file to resume, and it's gone."
- `tests/unit.sh` — new `test_post_finalize_reorder` (structural, grep-based,
  matching `test_swap_entry_count` style) asserts `post_unmount_target` appears
  before `post_remove_file "$STATE_FILE"` in the function body.

## Acceptance test
Unit:
- `test_post_finalize_reorder` passes.

VM:
- Run stage 06 through successful unmount, decline reboot, verify `state.env`
  absent and decline message printed; a re-run of stage 06 fails `die 50` as
  expected (by design).
- Simulate `umount` failure mid-flow → state file remains, re-run of stage 06
  resumes at `READY_TO_UNMOUNT`.

## Notes
`POST_MARKER` protocol is unaffected. It only tracks pre-unmount cleanup
(`CLEANUP` → `READY_TO_UNMOUNT`), becomes dead weight after unmount, and does
not interact with state removal at the end.

## Rejected alternatives
- Text-only decline-message fix. Fixes the symptom, leaves the latent mid-flow
  bug.
- Reorder without message change. A user who declines may reflexively re-run
  and get a misleading `die 50`.

## Out of scope
Reworking the `POST_MARKER` state machine to track individual unmount/mapper
steps. That is more machinery than the two-step marker currently needs and
would expand the surface being tested.

---
Patch-release fix for 0.1.1. Not a roadmap item.
