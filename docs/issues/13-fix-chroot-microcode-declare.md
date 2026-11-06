Title: Declare CHROOT_MICROCODE explicitly in 05-chroot.sh

## Problem
`chroot_check_packages` in `05-chroot.sh` assigns `CHROOT_MICROCODE=intel`,
`amd`, or `none`, and `chroot_write_environment` reads it later. It works via
Bash's default global-variable behavior, but every other cross-function
variable in that file — `CHROOT_ENV_CREATED`, `CHROOT_PAYLOAD_CREATED`,
`CHROOT_ENV`, `CHROOT_PAYLOAD` — is explicitly declared with `declare -g` or
`readonly` at the top of the file.

## Why
Consistency. A future maintainer scanning for cross-function state expects to
find declarations in the header block; `CHROOT_MICROCODE` is the one that is
missing, which invites a misreading (is it a leak from the host environment? a
typo?) and a misdirected search.

## Scope
- `05-chroot.sh`, top of file alongside `declare -g CHROOT_ENV_CREATED=0` and
  `declare -g CHROOT_PAYLOAD_CREATED=0` — add `declare -g CHROOT_MICROCODE=''`.

## Acceptance test
- `bash tests/unit.sh` unchanged pass count.
- `shellcheck -x` clean.
- No behavior change: the value is still assigned in `chroot_check_packages`
  and read in `chroot_write_environment`.

## Out of scope
Refactoring `chroot_check_packages` to return the value rather than assign a
global. That would be a larger change for a variable that has worked correctly
in every VM run so far.

---
Patch-release fix for 0.1.1. Not a roadmap item.
