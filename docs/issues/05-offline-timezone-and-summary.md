Title: Add an offline timezone picker and a pre-erase summary

## Goal
Interactive installs choose the timezone without contacting a third party by default, and show the full plan before anything is erased.

## Why
The live ISO's timezone is UTC (measured), so without a picker everyone who skips the lookup gets UTC. Today the interactive default contacts ip-api.com, with confirmation.

## Scope
- Stage 02 timezone choice: a menu built from `/usr/share/zoneinfo` (region, then zone), with an explicit "detect automatically" choice that states it contacts ip-api.com.
- A summary panel at the end of stage 02: disk, username, hostname, locale, keymap, timezone, country, and the SSH and auto-login choices. It must never show the password or its hash. Ask to confirm, default yes.
- Update `README.md`, `DECISIONS.md` (geo-IP section), `CHANGELOG.md`, and tests.

## Acceptance test
- A unit test with a fake `curl` shows no network call unless auto-detect is chosen.
- A unit test shows the summary never contains the hash or the password.

## Out of scope
Localizing the messages.
