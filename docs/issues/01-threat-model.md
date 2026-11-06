Title: Write the threat model

## Goal
State who this installer defends against, so security choices are made for a reason.

## Why
TRIM, Secure Boot, auto-login, snapshot retention, and SSH each trade security, privacy, or convenience. Their value depends on the threat.

## Scope
Create `docs/THREAT_MODEL.md` covering:
- what is protected (data at rest, boot chain, running system)
- attackers: a stolen powered-off machine, someone tampering with the boot partition, a network attacker, someone at the keyboard after boot
- what is defended and what is explicitly not
- a table mapping each decision in `docs/DECISIONS.md` to the threat it addresses

## Acceptance test
- The file exists and is linked from the README.
- Every security-related decision in `DECISIONS.md` and every "Later" item in the roadmap names the threat it addresses.

## Out of scope
Implementing any of the decisions.
