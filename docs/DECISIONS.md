# Opinionated decisions

This installer makes choices for you. This file records each one: what the
installer does, why I chose it, what it costs you, and whether you can change it.
Every decision here matches the code. If the code changes, this file must change
with it. The CONTRIBUTING guide requires that.

The short version: a modern, encrypted, snapshot-ready Arch system on UEFI, with
conservative kernel and boot choices and as little installed as possible.

## At a glance

| Area | Choice | Changeable? |
| --- | --- | --- |
| Firmware | UEFI only | No |
| CPU | x86_64 only | No |
| Install media | Official Arch ISO only | No |
| Disk layout | One disk, whole disk erased, GPT | No (single disk only) |
| Filesystem | Btrfs, with `@` and `@home` subvolumes | No |
| Encryption | LUKS2 on the root partition | No |
| Bootloader | systemd-boot | No |
| Kernel | `linux-lts` | Edit the package list |
| Swap | zram in RAM, no swap partition | Edit the zram config |
| Network | NetworkManager | No |
| Time sync | systemd-timesyncd | No |
| Remote access | OpenSSH server, enabled on first boot | Edit the service list |
| Root account | Locked | No |
| Desktop | None | Install one afterwards |
| Editor | Neovim | Edit the package list |
| Interface | Styled, with `--no-ui` for plain output | Yes |

## Firmware: UEFI only

**Choice.** The installer requires UEFI. Stage 01 refuses to run in BIOS mode.

**Why.** systemd-boot, the bootloader I chose, only runs on UEFI. Supporting BIOS
would mean a second boot path with GRUB or syslinux, which doubles the code that
has to be tested and keeps the most fragile part of the install on the least
common firmware.

**Trade-off.** Machines that only support legacy BIOS cannot use this installer.
Almost all x86_64 hardware sold in the last decade supports UEFI.

**Change?** No.

## CPU: x86_64 only

**Choice.** Stage 01 checks the architecture and stops on anything else.

**Why.** The package set, microcode selection, and mount options are written for
x86_64. Supporting ARM would mean a different package set and a different test
matrix.

**Change?** No.

## Install media: the official Arch ISO only

**Choice.** Stage 01 checks the ISO markers and refuses other live media.

**Why.** The installer relies on the ISO's tools, its pacman configuration, and its
boot layout. Other live systems differ in ways I cannot test.

**Change?** No. Use the official ISO from archlinux.org.

## Disk layout: one disk, erased, GPT

**Choice.** The installer uses one disk and erases all of it. It creates two GPT
partitions:

- **EFI system partition**, 1 GiB, FAT32, type `EF00`, labelled `EFIBOOT`.
- **Root partition**, the rest of the disk, type `8300`, labelled `ROOT`, holding
  the LUKS2 container.

**Why.** One disk keeps the partition logic simple and the destructive step easy to
reason about. A fresh install uses about 48 MiB of the 1 GiB EFI partition (measured on a test VM),
so there is ample headroom for a second kernel or unified kernel images later.

**Trade-off.** Dual-boot, multi-disk, and RAID layouts are not supported. The
installer refuses any disk that hosts the running ISO or is busy.

**Change?** No.

## Filesystem: Btrfs, with `@` and `@home` subvolumes

**Choice.** The root filesystem is Btrfs. It has two subvolumes:

- `@` mounted at `/`
- `@home` mounted at `/home`

**Why.** Btrfs gives copy-on-write, checksums on data and metadata, and
transparent compression. The split into `@` and `@home` means the system and user
data can be snapshotted and rolled back independently. The installer does not
configure snapshots yet. The layout is there so you can add them without
repartitioning.

**Trade-offs.**

- Btrfs is more complex than ext4. If something goes wrong with the filesystem, you
  need `btrfs` tools to recover it.
- Copy-on-write can fragment large files that are rewritten in place, such as
  database files and virtual machine images. For those workloads, consider marking
  a directory `nodatacow`.
- Btrfs has no built-in swapfile support for hibernation. This installer does not
  configure hibernation either.

**Change?** No.

## Mount options: compression and a two-minute commit interval

**Choice.** The installer chooses mount options from the disk's type, which it reads
from sysfs:

| Disk | Options |
| --- | --- |
| SSD (non-rotational) | `noatime,compress=zstd,ssd,commit=120` |
| Hard disk (rotational) | `noatime,compress=zstd,commit=120` |
| eMMC (`mmcblk*`) | `noatime,compress=zstd:5,ssd,commit=120` |

`noatime` avoids a write on every read. `compress=zstd` compresses data
transparently. `ssd` tells Btrfs to use flash-friendly allocation. It is set only
for flash.

**Trade-off: `commit=120`.** Btrfs writes its transactions to disk every 120
seconds rather than the default 30. After a sudden power loss you can lose up to
two minutes of recent writes. The filesystem stays consistent because of
copy-on-write, so you won't get corruption, but the most recent changes can be
gone. A longer interval means fewer disk writes and less wear on flash. If you
would rather lose less data on a crash, change the value in
`02-config.sh` (`commit=120`) before installing, and update this file.

**Change?** Edit `CONFIG_MOUNT_OPTIONS` selection in `02-config.sh`. Document the
change here.

## Encryption: LUKS2 on the root partition

**Choice.** The root partition is a LUKS2 container, created with
`cryptsetup luksFormat --type luks2`. The installer uses the cryptsetup defaults for
the cipher and key derivation for your installed version. It does not override
them. For example, on a test VM with about 4 GiB of RAM this produced
`aes-xts-plain64` with a 512-bit key, `argon2id` using about 749 MiB of memory, and a
single keyslot. The key-derivation cost is benchmarked on the machine that formats
the disk, so the numbers vary.

The EFI partition is not encrypted. UEFI firmware must read the bootloader before
any decryption can happen, so the EFI partition cannot be encrypted with this
design. It holds the bootloader, the kernel and initramfs images, the boot entries,
and systemd-boot's random seed file, not your data. The partition is mounted with
`umask=0077` so only root can read it. On the test VM a normal user could not even
list `/boot`.

Because the kernel and initramfs are not encrypted, someone with physical access
could replace them. Secure Boot with signed images would close that gap. This
installer does not set it up yet.

**Why.** Full-disk encryption protects your data if the disk is lost or stolen.

**Trade-offs.**

- You type a passphrase at every boot. There is no automatic unlock via TPM or
  keyfile, so the passphrase is the only key.
- If you forget the passphrase, the data is unrecoverable. There is no escrow.
- The encryption protects data at rest, not a running system.

**Change?** No. The passphrase is set during the install.

## Initramfs: the classic `encrypt` hook

**Choice.** The installer uses the classic mkinitcpio chain: `base udev`, then the
`keyboard`, `keymap`, `block`, and `encrypt` hooks. The kernel command line carries
`cryptdevice=UUID=...:ROOT root=/dev/mapper/ROOT rootflags=subvol=@ rw`.

If the installed system's `mkinitcpio.conf` uses the `systemd` initramfs hook (the
stock layout on some releases), stage 05 rewrites the line to the classic chain.
`systemd` becomes `base udev`, and `sd-vconsole` becomes `keymap consolefont`. The
`sd-encrypt` hook is refused, because it needs a different kernel command line.

**Why.** The classic hook is explicit, well documented, and matches the boot
entry the installer writes. It has fewer moving parts to get wrong.

**Trade-off.** The systemd initramfs is the direction Arch is moving toward, and it
gives better early-boot logging. Staying on the classic chain means a future
migration step.

**Change?** Editing `HOOKS` after install is possible, but you must then update the
kernel command line to match.

## Bootloader: systemd-boot

**Choice.** systemd-boot is installed to the EFI partition, with these settings:

- Default entry: `arch.conf`
- Timeout: 3 seconds
- Console mode: `max`
- Editor: disabled (`editor no`)

**Why.** systemd-boot is small, has no configuration language to get wrong, and
needs no extra tooling to update. It is the simplest bootloader that does the job
on UEFI.

**Trade-offs.**

- No GRUB, so no BIOS support and no GRUB menu features.
- The editor is disabled, so you cannot change the kernel command line at boot.
  That is deliberate: with an editable command line, anyone at the console could
  change how the system starts. The trade-off is that a broken command line needs
  the live ISO to fix.
- Only one kernel entry is created. A kernel update replaces the one entry, so
  there is no fallback kernel. See the next decision.

**Change?** Yes, but it is a manual change after install.

## Kernel: `linux-lts`

**Choice.** The installer installs `linux-lts`, not the default `linux` package,
and creates a boot entry for it only.

**Why.** The LTS kernel gets security and stability fixes for longer, changes less
often, and is less likely to break an update. For a system you want to install once
and keep working, that matters more than the newest features.

**Trade-offs.**

- Newer hardware sometimes needs a newer kernel. If a device does not work, the LTS
  kernel may be the reason.
- Some features arrive in the mainline kernel first.

**Change?** Yes. Replace `linux-lts` in the package list, and update the boot entry
and mkinitcpio preset to match.

## Swap: zram in RAM, no swap partition

**Choice.** The installer installs `zram-generator` and writes a zram device sized
by this formula:

    zram-size = ram / (1 + min(floor(ram / 16384), 1))

In practice, on a machine with less than 16 GiB of RAM, zram is 100% of RAM. At 16
GiB or more, zram is 50% of RAM. There is no swap partition and no swap file.

**Why.** Compressed swap in RAM is fast, needs no disk space, and does not wear
flash storage. Most desktop workloads rarely need more than that.

**Trade-offs.**

- Hibernation is not supported, because hibernation needs a swap area on disk that
  is at least as large as RAM.
- zram is not disk-backed. Under heavy memory pressure, the system can run out of
  memory even though disk space is free.

**Change?** Yes. Edit `/etc/systemd/zram-generator.conf` after install.

## Networking: NetworkManager

**Choice.** NetworkManager is installed and enabled. The installer does not
configure any network interface.

**Why.** NetworkManager handles Wi-Fi, wired connections, and VPNs with one tool, and
it works without manual configuration.

**Change?** Yes. Replace the package and service.

## Time: systemd-timesyncd

**Choice.** systemd-timesyncd is enabled to keep the clock synchronized. The
timezone comes from your answers, from the geo-IP lookup if you enabled it, or from
the live ISO after you confirm it.

**Why.** It is included with systemd, so it needs no extra package, and it is enough
for a workstation.

**Trade-off.** It is a simple SNTP client. It does not provide the features of
chrony, such as precision timing for servers.

**Change?** Yes. Replace the package and service.

## Remote access: OpenSSH enabled on first boot

**Choice.** The installer installs the OpenSSH server and enables `sshd` on the
first boot. It does not change the default `sshd_config`.

**What that means.** Unless you change `sshd_config`, the server accepts password
logins for your user, and it listens on the network from the first boot.

**Why I chose this.** Remote access is useful for a machine you manage over the
network, and enabling it during install saves a step.

**This is the decision I would reconsider first.** A network service that accepts
passwords and starts on first boot widens the attack surface of a fresh install.
Before you connect a new machine to an untrusted network, do one of the following:

- disable the service with `sudo systemctl disable --now sshd`, or
- set `PasswordAuthentication no` in `/etc/ssh/sshd_config` and add your public key
  to `~/.ssh/authorized_keys` before you rely on it.

**Change?** Yes. Edit the service list in `05-chroot.sh`, or the `sshd_config`
after install. Consider changing the installer's default before you publish it.

## Accounts: locked root, one user in `wheel`

**Choice.**

- The root account is locked with `passwd -l root`, so it has no password.
- The user you configure is created with `useradd -m -G wheel -s /bin/bash`.
- Members of `wheel` can run any command with `sudo`, and sudo asks for the user's
  own password. The rule is `%wheel ALL=(ALL:ALL) ALL`, with no `NOPASSWD`.

**Why.** A locked root account means there is no password to guess or leak for
the superuser. The `wheel` rule gives your user administrative access, but
still requires a password for each use.

**Trade-offs.**

- Only one user is created. Add more accounts after the install.
- Anyone who knows your user's password can become root through `sudo`.

**Change?** Yes. Edit the sudoers drop-in and the account setup after install.

## Desktop: none

**Choice.** No desktop environment, display server, or graphical login manager is
installed.

**Why.** A desktop is a matter of taste, and it is easy to add afterwards. A minimal
base keeps the system small and the install fast.

**Change?** Install one after the first boot.

## Editor and build tools

**Choice.** `neovim` is installed as the default editor. `base-devel` is also
installed, which provides a compiler toolchain and the common build tools.

**Why.** `base-devel` is needed to build software from the AUR, and `neovim` gives you
a usable editor on a fresh system without choosing one.

**Trade-off.** `base-devel` is large, and a system that never builds software does
not need it. It is included by my choice, not by necessity. Remove it after install
if you do not build software.

**Change?** Yes. Edit the package list.

## Locale and keyboard

**Choice.** The installer accepts only UTF-8 locales, in the form `xx_XX.UTF-8`, and
checks that the locale exists in the live environment. The keyboard layout is
chosen from a list of supported keymaps.

**Why.** UTF-8 is the only encoding that works everywhere, and a locale that does not
exist would break the first boot.

**Change?** Yes. Pick a different locale or keymap during configuration.

## Geo-IP lookup: opt-in for unattended runs

**Choice.** When `COUNTRY` or `TIMEZONE` is missing, the installer can look up your
country and timezone from `ip-api.com`.

- **Interactive:** the lookup runs by default, and you confirm the detected values
  before they are used.
- **Unattended:** the lookup does not run unless the answers file sets
  `GEO_LOOKUP=1`.

**Why.** Looking up a location sends your public IP address to a third party. In
interactive mode you see the result and can decline it. In unattended mode nobody
is there to check the result, so the lookup has to be an explicit choice.

**Trade-off.** The free tier of `ip-api.com` uses plain HTTP, so the request and reply
are not encrypted. The reply is validated, and it can only set a country code and a
timezone.

**Change?** Set `COUNTRY` and `TIMEZONE` in the answers file to skip the lookup.

## Secrets: no shredding, no password on disk

**Choice.**

- The plaintext password is read silently and hashed with `openssl passwd -6`. It
  never appears on a command line.
- The password hash is passed to the target's `chpasswd` on stdin. It is not
  written to the target disk.
- The installer removes its temporary files with plain `rm`, not `shred`.

**Why.** `shred` cannot guarantee erasure on Btrfs, which is copy-on-write, or on
SSDs, which remap blocks. Protection comes from never writing secrets to unencrypted
media, and from LUKS encryption at rest.

**Trade-off.** The state and answers files live in RAM on the live ISO. They are
gone after a reboot. If the ISO's `/tmp` were disk-backed, the hash could persist
there. The official ISO uses RAM.

**Change?** No.

## Destructive steps need typed confirmation

**Choice.** Stage 03 erases the disk only after you type the device name exactly.
Stage 02 asks you to type it when you select the disk, and stage 03 asks again
before the first write.

**Why.** Picking the wrong disk is the most expensive mistake this installer can
cause. Typing the name makes that mistake deliberate.

**Change?** No. This check is part of the safety design.

## Interface: styled by default

**Choice.** The installer shows a logo, panels, a progress bar, and colour on a
terminal. `--no-ui` or `ARCH_INSTALL_UI=0` switches to plain text.

**Why.** Clear progress and clearly marked warnings matter when an install is
long and one wrong answer is costly. Some people prefer plain output, especially in
logs or on a serial console, so the styled interface can be turned off.

**Trade-off.** The styling uses Unicode-free ASCII, so it renders on the Linux
console. Some terminals will not show colour.

**Change?** Yes. Use `--no-ui` or `ARCH_INSTALL_UI=0`. Set `NO_COLOR=1` to keep the
styling and drop only the colour.

## Not included

These are deliberately out of scope:

- Snapshot tooling, such as snapper or timeshift. The subvolume layout is ready for
  them.
- Automatic updates or an update hook.
- Hibernation.
- Secure Boot signing. systemd-boot works with Secure Boot only after you enroll
  keys.
- Dual-boot with another operating system.
- Backups.

## How to change a decision

1. Edit the code and test it. The unit tests and the VM run must still pass.
2. Update this file with the new choice, the reason, and the trade-off.
3. Update the README and the CHANGELOG.
