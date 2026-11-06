Title: Correct the unreachable-branch message in partition_collect_descendants

## Problem
`partition_collect_descendants` in `03-partition.sh` has two `die 20` branches.
The first fires when `jq` enumeration fails — message correct. The second fires
when the resulting array is empty — but the `descendants` jq function includes
the disk itself (`. , (.children[]? | descendants)`), so the array can never be
empty unless jq itself errored (already caught by the first branch). The
message — "target disk has no discoverable block-device descendants" — names a
cause that cannot happen.

## Why
If this branch ever fires (e.g. a future change to the jq expression breaks the
invariant), the message would send the reader looking for a missing partition
that cannot exist. Two messages that both begin "cannot enumerate…" are also
ambiguous in logs: a reader cannot tell which branch fired.

## Scope
- `03-partition.sh`, `partition_collect_descendants`, second `die 20` — change
  the message to: "target disk enumeration returned no usable block devices;
  refusing disk mutation".
- Keep the branch. It enforces an invariant that future jq-expression changes
  might break, and deleting it to avoid a message fix trades a cosmetic
  problem for a lost safety net.

## Acceptance test
- `bash -n` and `shellcheck -x` clean.
- Manual review: the two messages no longer share the "cannot enumerate …
  descendants" phrasing, so a log reader can disambiguate.

## Rejected alternatives
- Word-identical to the first branch. Logs would be ambiguous.
- Delete the branch entirely. Removes the invariant guard for a cosmetic gain.

## Out of scope
Refactoring the two branches into one message with a sub-cause field. That is
more code than the problem warrants; two messages with distinct shapes is
enough.

---
Patch-release fix for 0.1.1. Not a roadmap item.
