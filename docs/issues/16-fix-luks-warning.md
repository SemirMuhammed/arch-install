Title: Warn that the LUKS passphrase is typed three times before stage 03 begins

## Problem
The passphrase is typed three times total: `cryptsetup luksFormat` (set, then
confirm) and `cryptsetup open` (unlock). If any pair mismatches, the user gets
`ERROR [20]` after the target disk has already been partitioned and the ESP
formatted — recoverable, but ugly. Stage 03 is otherwise non-interactive after
the typed confirmation, so there is no chance to warn the user before the risk.

## Why
The failure is annoying and entirely preventable with a single line of text.
The passphrase is the only thing the user types at the two `cryptsetup` prompts,
and there is no undo for the format if it fails at the third prompt — the disk
is already partitioned. Telling the user upfront that three entries are coming
is the cheapest possible mitigation.

## Scope
- `03-partition.sh`, `partition_confirm_target` — add one line to the existing
  `FINAL CONFIRMATION` `ui_box`: "You will be prompted for the LUKS passphrase
  three times: once to set, once to confirm, once to unlock. All three must
  match."

No new panel, no new prompt. The box already requires the user to read and
type the device name; this fits inside it.

## Acceptance test
- CHANGELOG note only — text-only change in a `ui_box`, verified by the 0.1.1
  VM acceptance run.
- VM: full install reads the new line; passphrase set correctly unlocks on the
  first attempt.

## Rejected alternatives
- New `ui_box` right before `cryptsetup luksFormat`. Breaks the destructive
  flow with a non-standard panel; the existing FINAL CONFIRMATION box is the
  right place.
- `ui_confirm "Have you decided on the LUKS passphrase?"`. Adds a prompt to a
  stage that should not prompt.

## Out of scope
Capturing the passphrase once and reusing it. That would require holding the
plaintext in shell state, which the current design deliberately avoids — the
LUKS passphrase never enters a Bash variable.

---
Patch-release fix for 0.1.1. Not a roadmap item.
