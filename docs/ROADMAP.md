# Roadmap

Planned work, in priority order. Each item was checked against the code, Arch
documentation, or a measurement on the test VM before it was listed. Anything not yet
confirmed is under [Measure first](#measure-first). Ideas that turned out wrong or
pointless are under [Decided against](#decided-against), so they are not proposed again.

Each planned item has a ready-to-paste issue text in [issues/](issues/). Create the
issue, then add its number to the table.

## Definition of done

Every item must:

1. Pass `bash -n`, `shellcheck -x`, and `bash tests/unit.sh`.
2. Run its acceptance test in a UEFI virtual machine, with the result noted in the pull request.
3. Update `docs/DECISIONS.md`, `README.md`, and `CHANGELOG.md` where behavior changes.
4. Keep plain mode (`--no-ui`) working.

## Done

| Item | Notes |
| --- | --- |
| Per-stage timing | Duration after each stage, a summary panel, and plain log lines. |

## Planned

| # | Item | Depends on | Acceptance test | Issue |
| --- | --- | --- | --- | --- |
| 1 | Threat model | none | `docs/THREAT_MODEL.md` exists, and each security decision cites it | |
| 2 | Snapshot foundation | 1 | Update, roll back, then `uname -r` matches `/usr/lib/modules` and the system boots | |
| 3 | SSH off by default, key-only if enabled | none | Default install runs no `sshd`; with SSH on, password login is refused and key login works | |
| 4 | Second kernel entry | none | Both entries boot and report different `uname -r` | |
| 5 | Offline timezone picker and pre-erase summary | none | No network call unless auto-detect is chosen; the summary never shows the hash | |
| 6 | Scrub timer and optional sysctl file | none | Timer is active after install; sysctl values are set after reboot | |
| 7 | Boot menu timeout 0 | 4 | No menu by default; holding a key shows it | |
| 8 | Recovery guide | 2, 4 | A deliberately broken VM is recovered using only the guide | |

## Later

No issue yet. Each needs the threat model (item 1) first where it is a security choice.

- **Auto-login**, off by default: a getty drop-in on tty1 only.
- **TRIM**, off by default: needs `allow-discards` on the LUKS mapping and leaks which blocks are free.
- **LUKS recovery keyslot and header backup:** the installed volume has a single keyslot. A header backup can restore a revoked passphrase, so store it encrypted and offline.
- **Secure Boot with signed unified kernel images:** enroll keys with the Microsoft option (`sbctl enroll-keys -m`) or risk a machine that will not boot.
- **VM tests in CI:** GitHub-hosted runners can use KVM. Effort is high because the ISO must be driven unattended.
- **Small items:** pin CI actions to commit SHAs, signed release tags with checksums, a troubleshooting page, RAM and disk preflight checks, core dumps off, install presets.

## Measure first

Do not implement until the measurement is in the issue.

- **Mirror ranking:** the ISO's mirror list is static and starts with two `pkgbuild.com` mirrors. Use the stage timing to see whether stage 04 is download-bound.
- **`nosuid,nodev` on `/home`:** confirm per-subvolume behavior on Btrfs.
- **Firewall:** confirm the ruleset the Arch `nftables` package ships. Enabling default-deny without allowing SSH locks you out.
- **DNS-over-TLS and Wi-Fi MAC randomization:** confirm defaults and what breaks on captive portals and MAC-filtered networks.
- **zram tuning and zstd level:** benchmark first. The eMMC branch uses `zstd:5`, so decide whether that is intended.
- **Laptop power profile:** opt-in only.
- **GPU drivers:** only with a future desktop preset. `nvidia-lts` no longer exists; the open variant is `nvidia-open-lts`, for newer GPUs only. Older NVIDIA cards need an AUR driver, which the installer will not pull in.

## Decided against

| Idea | Reason |
| --- | --- |
| Parallel downloads | Already `ParallelDownloads = 5` on the ISO and on the installed system |
| `/tmp` in RAM | Already tmpfs |
| Disable NetworkManager wait-online | Not on the boot critical chain, and not among the slowest units |
| Set argon2id explicitly | Already the LUKS2 default |
| Journal size limit | Already capped by default; the journal used 16 MB |
| `systemd-oomd` | Not enabled by default, and does nothing without extra configuration |
| Snapshot boot via Limine | A different bootloader, not an add-on for systemd-boot |
| Drop the `fsck` hook | Btrfs has no boot-time fsck, so the saving is negligible |
| Trim the installer log | The log does not contain the username, hostname, or timezone |
| Localization | High cost; error messages are documented in English |
| Extra sudo defaults | `use_pty` is already the default |

## Defaults I recommend

| Choice | Default |
| --- | --- |
| TRIM | Off, opt-in |
| SSH | Off, key-only if enabled |
| Auto-login | Off |
| Snapshots | On, with limited retention |
| Second kernel | On |

Snapshots keep deleted files on disk. State that in `docs/DECISIONS.md` when item 2 lands.
