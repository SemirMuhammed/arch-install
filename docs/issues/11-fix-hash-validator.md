Title: Unify the password-hash regex across all validation sites

## Problem
`config_validate_password_hash` in `02-config.sh` uses a strict regex
(`^\$6\$[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{86}$`). The same check is
reimplemented with a looser pattern in `05-chroot.sh`'s `chroot_validate_state`
and again in the chroot payload's `account_hash` check. Three copies, two
different strictness levels, one canonical intent.

## Why
Not exploitable today — the state file is root-owned mode 600 and only stage 02
writes `PW_HASH`. But this is the most security-sensitive variable in the
project, and three copies of a regex is three opportunities for future drift.
Any future change to the canonical form (e.g. Argon2 support) must touch three
sites, and there is no test that would catch a missed one.

## Scope
- `lib/common.sh` — extract `config_validate_password_hash` here as the single
  canonical function. `02-config.sh` and `05-chroot.sh` call the shared
  function.
- `05-chroot.sh` — `chroot_payload_body` keeps an **inline copy** of the regex
  (the payload runs inside the target where `lib/` does not exist). String-
  splicing the function into the payload at generation time is rejected as
  brittle heredoc manipulation.
- Tighten the two currently-loose regexes (`^\\$6\\$[A-Za-z0-9./]+\\$[A-Za-z0-9./]+$`)
  to match the canonical `{1,16}` salt / `{86}` hash shape.
- `tests/unit.sh` — new `test_password_hash_regex_consistency` greps
  `lib/common.sh`, `05-chroot.sh`'s validation site, and the output of
  `chroot_payload_body` for the literal regex string and asserts
  byte-identical across all three.

## Acceptance test
- `test_password_hash_regex_consistency` passes.
- Existing `test_password_hash_validation` passes with tightened regexes.
- `bash tests/unit.sh` green.

## Rejected alternatives
- Payload as superset (allowed to be looser than canonical). YAGNI; strict
  everywhere is one line simpler to test.
- Splice the function into the payload at generation time. Brittle heredoc
  manipulation for no benefit.

## Out of scope
Changing the hash algorithm or salt length. This fix only unifies the existing
SHA-512 crypt shape.

---
Patch-release fix for 0.1.1. Not a roadmap item.
