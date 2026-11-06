Title: Three small polish nits (--from single digit, .gitignore, test root note)

## Problem
Three unrelated, cheap polish items identified during the 0.1.1 review. Each is
independently shippable; bundled here only because they are each a handful of
lines.

## Scope

### 17a — `--from N` is rejected; only `--from NN` works
`install.sh`'s `main()` passes `from` verbatim to `plan_stages`, which matches
`${stage:0:2}` against `from`. `--from 04` works. `--from 4` fails with "no
stage numbered '4' (use 01-06)". The error is clear, but the doubled-digit form
is what the README shows everywhere, and users will type the single-digit form
sooner or later.
- Fix: `from=$(printf '%02d' "$from")` before `plan_stages`. Usage message
  unchanged.
- Test: `test_from_single_digit` asserts `--from 4` is accepted and behaves
  identically to `--from 04`.

### 17b — `project_bundle.txt` is not in `.gitignore`
A past bundle file was committed alongside the source.
- Fix: add `project_bundle.txt` to the "Installer runtime data: never commit…"
  block in `.gitignore`, before the editor/OS section.
- Test: `git status` shows the file untracked-and-ignored.

### 17c — `tests/unit.sh` can create `/var/log/arch-install.log` if run as root
`test_ui_mode_toggle` shells out to `./install.sh --no-ui --dry-run`. The suite
is documented as non-root, and CI runs as a non-root runner, but a user who
runs `sudo bash tests/unit.sh` will find `/var/log/arch-install.log` created
before stage 01 fails.
- Fix: one-sentence header note in `tests/unit.sh` — "`test_ui_mode_toggle`
  shells out to `./install.sh --no-ui --dry-run`. This creates
  `/var/log/arch-install.log` if run as root. Run the suite as non-root."
- No behavior change.

## Acceptance test
- 17a: new unit test passes; existing `test_entry_point` unchanged.
- 17b: `git status` shows `project_bundle.txt` untracked-and-ignored.
- 17c: `bash tests/unit.sh` unchanged pass count; header reads correctly.

## Rejected alternatives
- Split into three separate issues. They are each a few lines and share no
  files; bundling them keeps the 0.1.1 issue list readable.
- Skip 17c. Documented as a "run as non-root" suite; a one-sentence reminder
  costs nothing and prevents a confusing error for a new contributor.

## Out of scope
Anything more substantial from the review — the `ui_menu` `cell_width` nit and
the `_common_decode_value` NUL-rejection comment are both deferred beyond this
patch release.

---
Patch-release fix for 0.1.1. Not a roadmap item.
