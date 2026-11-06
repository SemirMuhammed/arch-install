# Contributing

Thanks for considering a contribution. This installer erases disks and handles
passwords, so changes are reviewed carefully. Small, focused pull requests are
easiest to review.

## Before you start

- Read the [README](README.md), especially the data-loss warning.
- For anything larger than a small fix, open an issue first to discuss the approach.
- Pick work from [docs/ROADMAP.md](docs/ROADMAP.md). Its definition of done applies to every change.
- Report security issues privately, as described in [SECURITY.md](SECURITY.md).

## Running the checks

The quickest way is the local check, which runs the same steps as CI:

```sh
tests/check.sh
git config core.hooksPath .githooks   # once: run the secret scan before each commit
```

The step-by-step commands below do the same work by hand.


Every change must pass the same checks that CI runs:

```sh
for f in install.sh lib/*.sh [0-9]*.sh tests/unit.sh; do bash -n "$f"; done
shellcheck -x -s bash install.sh lib/*.sh [0-9]*.sh tests/unit.sh
bash tests/unit.sh
```

The unit tests need no disk, network access, or Arch ISO. Requirements are
`bash` 4.4 or newer, `jq`, `shellcheck`, and optionally `openssl`.

Never run the installer, or any stage script, on a machine you care about. Stage 03
erases the disk you select. Test end-to-end only in a virtual machine booted from the
official Arch ISO in UEFI mode.

## Guidelines

- **Safety first.** Destructive operations need explicit checks and clear error
  messages. Don't weaken an existing check without a written reason in the pull request.
- **Secrets.** Never commit answers files, password hashes, logs, or state files.
  Passwords must never appear on a command line or in a file that outlives the install.
- **Exit codes.** Use an existing code from the table in the README where one fits.
  If you add a new code, update the table.
- **Shell style.** Quote variables, use `[[ ]]`, and keep `shellcheck` clean without
  blanket disables. If a disable is genuinely needed, put it on the line it applies to
  and explain why.
- **Tests.** Add a unit test for any new pure logic or bug fix.
- **User-facing output.** Use the helpers in `lib/ui.sh` (`ui_ok`, `ui_warn_line`,
  `ui_error_line`, `ui_box`, `ui_menu`, `ui_confirm`, `ui_input`) rather than raw `printf`.
  The chroot payload is the one exception, because it runs inside the target with no UI library.
  Keep the wording of error messages stable, since the README documents the exit codes.
- **Opinionated defaults.** A change to any default in `docs/DECISIONS.md` (filesystem,
  kernel, bootloader, mount options, services, accounts, and so on) needs an update to
  that file in the same pull request. The file records the reason and the trade-off, so a
  change without them is incomplete.
- **Both interface modes.** Any new prompt or panel must work in styled and plain mode
  (`ARCH_INSTALL_UI=0`). Use the `ui_*` helpers, which handle both.
- **Live ISO dependencies.** The official ISO doesn't ship every tool. Install
  missing packages on demand with the existing helpers, not by assuming they are present.

## Commits and pull requests

- Keep commits focused, with a short imperative subject line.
- Describe what changed and why, and note any testing you did, including whether it was
  a unit test, a VM run, or both.

## License

By contributing, you agree that your contributions are licensed under the
GNU General Public License v3.0, the same as the project.
