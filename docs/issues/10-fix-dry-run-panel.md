Title: Fix the dry-run panel when --from is 04 or later

## Problem
The DRY RUN panel in `install.sh` always reads "Stages 01–03 are validated…
dry run ends after stage 03", regardless of the `--from` argument. When the
user runs `--from 04 --dry-run`, stages 04–06 actually execute in dry-run mode
(each stage has a `DRY_RUN=1` path), but the panel tells them otherwise. The
README repeats the same unconditional claim under **Usage**.

## Why
The panel is the last thing the user reads before the run starts. Telling them
stages 04–06 will not run, and then running them in dry-run mode, is a
correctness bug in the only place the installer reports its own plan. A user
who trusts the panel and walks away expecting nothing past stage 03 will
return to stage-04 dry-run output they did not anticipate.

## Scope
- `install.sh`, `main()` — branch the DRY RUN `ui_box` on `10#$from > 3`. When
  true, replace the panel body with: "Dry run starting at stage NN. Stages
  04–06 validate against the currently mounted target at /mnt; if it isn't
  mounted, the first stage will fail."
- `README.md` — add one sentence after the existing dry-run paragraph
  explaining that `--from NN --dry-run` for NN ≥ 04 validates against an
  already-mounted target.
- `tests/unit.sh` — new `test_dry_run_panel_from_04` asserting the panel
  output contains "starting at stage 04" when invoked as
  `install.sh --from 04 --dry-run --no-ui`.

## Acceptance test
- New unit test passes.
- `install.sh --dry-run --no-ui` (default `from=01`) output is unchanged.
- VM: `--from 04 --dry-run` against an unmounted `/mnt` fails at stage 04's
  existing `findmnt` check — this is the existing error path, not a new
  failure mode.

## Rejected alternatives
- Hard-clamp to `die_usage` when `from > 03 && dry_run == 1`. Discards a
  useful capability to validate stages 04–06 against a mounted target.
- Doc-only fix. Leaves the panel lying.

## Out of scope
Changing the dry-run semantics of any stage. Each stage already has its own
`DRY_RUN` path; this fix only makes the top-level panel tell the truth about
which stages will run.

---
Patch-release fix for 0.1.1. Not a roadmap item.
