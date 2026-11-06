Title: Create a secure, robust, compatible one-liner bootstrap

## Goal
A single command, run from the Arch ISO, downloads a specific release of the installer,
verifies it, and starts it. It must be safe to paste, so it never runs code that was not
checked.

## Why
Users want to start an install without cloning a repository, which the live ISO does
not include. A common pattern is `curl ... | bash`, which runs whatever the server sends
at that moment, with root. That is the wrong default for an installer that erases disks.

## Required design
- **Pinned version.** The one-liner names a release tag, for example `v0.1.0`. It never
  follows `main`, and it never asks GitHub for the "latest" release, since that changes
  without anyone reviewing it.
- **Download, verify, then run.** The steps are separate:
  1. download the release archive and its SHA-256 checksum over HTTPS
  2. verify the checksum before extracting anything
  3. extract into a fresh directory created with `mktemp -d` (mode 700)
  4. run `install.sh` from there, passing any arguments through
- **No `curl | bash`.** Not in the README, not in the issue examples, not in the script.
- **Stronger than a checksum.** A checksum from the same server as the archive only
  detects corruption, not a compromised release. Where possible, also verify a signature
  (`git tag -v` or an `ssh-keygen -Y verify` signature) against a key whose fingerprint
  is written in the README. State in the docs which of the two protections is in force.
- **Robust.** `set -Eeuo pipefail`. A `trap` removes the temporary directory on every
  exit. Check each required command before use. Fail with a clear message on network
  errors. Re-running the one-liner is safe.
- **Compatible.** Use only what the official ISO provides: bash, curl, tar, and
  coreutils (`sha256sum`, `mktemp`). Do not require git. Check the architecture and that
  the process is root before downloading, and let `install.sh` do the full preflight.
- **Secrets stay out.** The bootstrap never reads or writes the answers file, and it never
  echoes arguments that might contain a password.
- **Visible.** It prints each step and the verified checksum, so the user sees what ran.

## Acceptance tests
- A tampered archive (one byte changed) is rejected before extraction, with exit code 64
  or a documented code, and nothing is left in `/tmp`.
- A missing or unreachable checksum file stops the run before any extraction.
- Run on a stock Arch ISO with no extra packages installed: it works, and it installs
  nothing beyond what the installer itself requires.
- Interrupting with Ctrl-C removes the temporary directory.
- Running it twice in a row produces the same result.
- Arguments such as `--dry-run` and `--no-ui` reach `install.sh` unchanged.
- The README contains only the verified two-step form, never a `curl | bash` line.

## Depends on
Release checksums being published with each tag (see "Later" in the roadmap, signed
releases). Without them, only the corruption check is possible, and the docs must say so.

## Out of scope
A web installer, auto-updating the installer, and installing from a branch.
