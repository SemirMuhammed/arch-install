Title: Make SSH opt-in and key-only

## Goal
A fresh install runs no network login service unless you ask for one, and never one that accepts passwords.

## Why
The installer currently enables `sshd` on first boot with the default configuration (documented in `DECISIONS.md`). Turning off password login without installing a public key would lock you out, so the two changes must ship together.

## Scope
- Stage 02 asks "Enable SSH?", default no. Unattended mode uses new answers keys, for example `SSH_ENABLE` and `SSH_PUBKEY`.
- If enabled, require a public key. Install it with correct ownership and modes, and add an `sshd` drop-in with `PasswordAuthentication no`.
- If not enabled, do not enable `sshd`.
- Update `DECISIONS.md` (the decision I flagged as the first to reconsider), `README.md`, `CHANGELOG.md`, and tests for answers-file validation.

## Acceptance test (UEFI VM)
- Default install: `systemctl is-enabled sshd` reports disabled.
- SSH enabled: password login is refused, key login works, and a second login after reboot still works.

## Out of scope
A firewall. The ruleset the Arch `nftables` package ships is not yet confirmed. See "Measure first" in the roadmap.
