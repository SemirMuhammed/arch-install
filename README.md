# arch-install

Repository: https://github.com/semirmuhammed/arch-install

A scripted installer for Arch Linux on UEFI x86_64 hardware: LUKS2 full-disk
encryption, a Btrfs root with `@` and `@home` subvolumes, systemd-boot, a
`linux-lts` kernel, NetworkManager, and an optional unattended mode.

> **Warning: stage 03 permanently erases the disk you select.** Back up anything
> on it first. The installer is not yet validated on physical hardware (see
> [Status](#status)). Use it at your own risk.

## Requirements

- The **official Arch Linux ISO**, booted in **UEFI** mode.
- An **x86_64** machine with working network access and a synchronized clock.
- A target disk you can erase. The disk that holds the live ISO is refused.
- Run as root from the live environment. Docker containers are not supported.

`jq` is not on the official ISO. The installer installs it into the live
environment when it is first needed. This touches neither the target disk nor
`/mnt`.

## Usage

```sh
# From the Arch ISO, as root:
./install.sh               # run every stage in order
./install.sh --dry-run     # validate stages 01-03; change nothing (stops after 03)
./install.sh --from 04     # resume at a stage; earlier stages must already be done
./install.sh --help
```

A dry run stops after stage 03 because stages 04-06 need a mounted target, which a dry run never creates.

`install.sh` runs each stage as its own process. It stops at the first failure,
names the failing stage, and exits with that stage's exit code.

| Stage | Script | What it does |
| --- | --- | --- |
| 01 | `01-verify.sh` | Checks the Arch ISO, UEFI, x86_64, live tools, pacman lock, network, and clock. |
| 02 | `02-config.sh` | Collects and validates the disk, account, password, keyboard, locale, country, and timezone. |
| 03 | `03-partition.sh` | **Destructive.** Partitions, LUKS2-encrypts, formats, and mounts the target. |
| 04 | `04-pacstrap.sh` | Installs the base system with `pacstrap` and writes the target configuration. |
| 05 | `05-chroot.sh` | Configures the target inside `arch-chroot`: locale, users, bootloader, initramfs. If `mkinitcpio.conf` uses the `systemd` hook, it is rewritten to the classic `base udev` chain, because this installer boots with `cryptdevice=` and the `encrypt` hook. The `sd-encrypt` hook is refused. |
| 06 | `06-post.sh` | Validates the target, cleans up, unmounts, closes the LUKS mapper, and offers a reboot. |

Each stage can also be run on its own (`bash 03-partition.sh`). The entry point
exists so that stages run in order and failures are reported clearly.

## Terminal output

The installer uses colour and boxed panels on an interactive terminal. Stages
show a progress bar, and each prompt is a numbered menu or a single question.

- Menus accept a number or a name. For example, `us` and `3` both pick the
  first matching keyboard layout.
- Yes/no questions take a default. Press Enter to accept it, or type `y` or `n`.
- Destructive steps still require typing the exact device name, and nothing is
  erased until that check passes.

Colour is turned off automatically when output is not a terminal, such as a
pipe or a log file. Set `NO_COLOR=1` to turn it off explicitly. The installer
log at `/var/log/arch-install.log` is always plain text.

## Unattended mode

Create `/root/arch-install.answers` as a root-owned file with mode `600`:

```text
DISK=/dev/sda
CONFIRM_DISK=sda
KEYMAP=us
LOCALE=en_US.UTF-8
USERNAME=alice
HOSTNAME=laptop
PW_HASH=$6$...
# Optional. Unattended runs need both values, either here or via GEO_LOOKUP.
COUNTRY=US
TIMEZONE=America/New_York
# Optional. Set to 1 to let an unattended run look COUNTRY/TIMEZONE up online.
GEO_LOOKUP=0
```

Rules: one `KEY=VALUE` per line, uppercase keys only, no comments and no blank
lines, and no `=` inside values. Generate the hash with `openssl passwd -6`.
Stage 02 rejects any other format rather than guessing.

## Network and third-party lookups

The installer makes these network requests. Nothing else is sent.

- **Mirror probe (stage 01).** One HTTPS request to `geo.mirror.pkgbuild.com`
  to confirm connectivity. This is the official Arch mirror host.
- **Geo-IP lookup (stage 02), only when needed.** If `COUNTRY` or `TIMEZONE` is
  not provided, the installer makes one request to `http://ip-api.com/json/`,
  asking only for the `status`, `countryCode`, and `timezone` fields. The
  service receives your public IP address, as every web request does, and
  returns a country code and timezone. It is a third party, and its own data
  practices apply. Its free tier is limited to plain HTTP, so the request and
  reply are not encrypted. Anyone on the network path can read them, and could
  alter the reply. The reply is validated, and in interactive mode the detected
  values are shown for confirmation before use.
  - **Unattended runs never contact ip-api.com unless `GEO_LOOKUP=1` is set.**
    Without it, a missing `COUNTRY` or `TIMEZONE` exits with code 64. Because
    nobody confirms the values in unattended mode, a forged reply would be
    saved silently, so the lookup is opt-in there.
  - The lookup is skipped entirely when both values are provided.
  - The installer makes a single attempt and does not retry, because a
    rate-limited request cannot succeed immediately.
  - If the lookup fails or is declined, interactive mode asks you to type your
    country code, and the timezone falls back to the live ISO's timezone after
    you confirm it.
  - Set `COUNTRY` and `TIMEZONE` in the answers file to avoid the lookup
    completely.
- **Package installs.** `pacstrap`, `pacman`, and the `jq` install use the
  mirrors configured on the live ISO.

## Secrets handling

| Secret | Where it exists | How it is protected |
| --- | --- | --- |
| Plaintext password (interactive) | Memory only, during stage 02. | Read silently, confirmed, then piped to `openssl passwd -6 -stdin`. It never appears on a command line and is unset afterwards. |
| Password hash (`PW_HASH`) | State file and answers file on the live ISO, plus memory during stage 05. | The hash is passed to the target's `chpasswd` on stdin. It is never an argument and is never written to the target disk. The protected environment file holds only non-secret values. |
| LUKS passphrase | Typed into `cryptsetup`. | Never stored or passed through the scripts. |

The state and answers files live on the live ISO. The official ISO normally
keeps `/tmp` in RAM, so they are not written to a disk. Stage 06 removes the
state file when finalization succeeds. Stage 05 removes the protected
environment file when it finishes, even on failure.

The hash is not the password, but it can still be attacked offline if it leaks,
so use a strong passphrase. The root account is locked, and the user account is
created in the `wheel` group with `sudo` access.

Removal uses plain `rm`, not `shred`. Btrfs is copy-on-write and SSDs remap
blocks, so `shred` cannot guarantee erasure there. The protection comes from
keeping secrets off unencrypted media, and from LUKS encryption at rest.

## Exit codes

Every stage uses these codes. `install.sh` passes them through unchanged.

| Code | Meaning |
| --- | --- |
| 10 | Environment unsupported: not root, not x86_64, or running in a container. |
| 11 | Not the official Arch ISO, or the ISO markers are missing. |
| 12 | Not booted in UEFI mode, or verified boot state is missing. |
| 13 | Network probe failed after retries (stage 01). |
| 14 | A required command is missing, or a required tool could not be installed. |
| 15 | System clock is not synchronized. |
| 20 | Disk or storage safety check failed. If stage 03 reports this after it has started, read the message: the disk may be partly changed. |
| 22 | Mount state is wrong, or a required mount is missing. |
| 30 | pacman database is locked, or a package process is running. |
| 31 | Package database could not be synchronized, or package installation failed. |
| 50 | Unexpected internal or filesystem failure. Read the message and the log. |
| 64 | Invalid input or configuration: answers file, arguments, or state. |
| 130 | Interrupted by Ctrl-C or `SIGTERM`. |

Codes 21, 23, 40, and 41 are reserved and not currently raised. Logs are written
to `/var/log/arch-install.log` on the live ISO and copied to the installed
system at `/var/log/arch-install.log` during stage 06.

## Development

```sh
bash tests/unit.sh                      # unit tests: pure helpers and entry point
shellcheck -x -s bash install.sh lib/*.sh [0-9]*.sh tests/unit.sh
```

The unit tests need no disk, network, or Arch ISO. End-to-end testing requires a
UEFI virtual machine booted from the Arch ISO. That is planned work.

## Status

- Linting: shellcheck reports no findings across all modules.
- Unit tests: 75 passing (`bash tests/unit.sh`).
- End-to-end install: **validated in a UEFI virtual machine** (QEMU/KVM, virtio disk, official Arch ISO). The installed system booted through systemd-boot, unlocked LUKS, accepted the configured user, locked the root account, and mounted `/boot` with private permissions.
- Physical hardware: **not yet tested.**

## License

Copyright (C) 2026 semirmuhammed

This project is licensed under the GNU General Public License v3.0 (GPL-3.0). See [LICENSE](LICENSE) for the full text. You may use, study, modify, and redistribute the software, but derivative works you distribute must also be released under GPL-3.0.
