#!/usr/bin/env bash
set -Eeuo pipefail

if ! declare -F init >/dev/null 2>&1; then
    _PACSTRAP_MODULE_DIR=${BASH_SOURCE[0]%/*}
    [[ $_PACSTRAP_MODULE_DIR != "${BASH_SOURCE[0]}" ]] || _PACSTRAP_MODULE_DIR=.
    # shellcheck source=lib/common.sh
    source "$_PACSTRAP_MODULE_DIR/lib/common.sh"
    unset _PACSTRAP_MODULE_DIR
fi

declare -g PACSTRAP_CPU_VENDOR=''
declare -g PACSTRAP_MICROCODE_PACKAGE=''
# Base packages shared by the install and the DRY_RUN plan, so they cannot drift.
readonly -a PACSTRAP_BASE_PACKAGES=(
    base
    base-devel
    linux-lts
    linux-firmware
    efibootmgr
    zram-generator
    networkmanager
    openssh
    sudo
    neovim
    mkinitcpio
    cryptsetup
    btrfs-progs
)

pacstrap_validate_state() {
    state_load

    local architecture
    architecture=$(uname -m) ||
        die 10 'cannot determine system architecture; verify the Arch ISO environment and rerun preflight'
    [[ $architecture == x86_64 ]] ||
        die 10 "unsupported architecture '$architecture'; boot the x86_64 Arch Linux installation medium"

    [[ ${BOOT_MODE:-} == uefi && -d /sys/firmware/efi ]] ||
        die 12 'verified UEFI boot state is missing; boot the ISO in UEFI mode and rerun preflight'

    [[ ${FS:-} == btrfs && ${ENCRYPTION:-} == luks2 ]] ||
        die 64 'installation state must specify FS=btrfs and ENCRYPTION=luks2; rerun 02-config'

    [[ ${DISK:-} == /dev/* && -b ${DISK:-} &&
       ${ROOT_PART:-} == /dev/* && -b ${ROOT_PART:-} &&
       ${ROOT_DEV:-} == /dev/* && -b ${ROOT_DEV:-} &&
       ${ESP_PART:-} == /dev/* && -b ${ESP_PART:-} ]] ||
        die 64 'disk, root, encrypted-device, or ESP state is invalid; rerun 02-config and 03-partition'

    [[ -n ${MOUNT_OPTIONS:-} && -n ${ESP_UUID:-} && -n ${LUKS_UUID:-} ]] ||
        die 64 'required partition state is incomplete; rerun 03-partition'

    [[ -d /mnt && ! -L /mnt ]] ||
        die 22 'target root /mnt is missing or is a symlink; rerun 03-partition'

    require_mount /mnt
    require_mount /mnt/home
    require_mount /mnt/boot

    local root_fstype
    local home_fstype
    local boot_fstype
    local root_source
    local home_source
    local boot_source

    root_fstype=$(findmnt --noheadings --raw --output FSTYPE --mountpoint /mnt) ||
        die 22 'cannot identify the target root filesystem; inspect mounts and rerun 03-partition'
    home_fstype=$(findmnt --noheadings --raw --output FSTYPE --mountpoint /mnt/home) ||
        die 22 'cannot identify the target home filesystem; inspect mounts and rerun 03-partition'
    boot_fstype=$(findmnt --noheadings --raw --output FSTYPE --mountpoint /mnt/boot) ||
        die 22 'cannot identify the target EFI filesystem; inspect mounts and rerun 03-partition'

    [[ $root_fstype == btrfs && $home_fstype == btrfs && $boot_fstype == vfat ]] ||
        die 22 'target mounts must be Btrfs at /mnt and /mnt/home, and vfat at /mnt/boot; rerun 03-partition'

    root_source=$(findmnt --noheadings --raw --output SOURCE --mountpoint /mnt) ||
        die 22 'cannot identify the target root device; inspect mounts and rerun 03-partition'
    home_source=$(findmnt --noheadings --raw --output SOURCE --mountpoint /mnt/home) ||
        die 22 'cannot identify the target home device; inspect mounts and rerun 03-partition'
    boot_source=$(findmnt --noheadings --raw --output SOURCE --mountpoint /mnt/boot) ||
        die 22 'cannot identify the target EFI device; inspect mounts and rerun 03-partition'

    root_source=${root_source%%\[*}
    home_source=${home_source%%\[*}
    boot_source=${boot_source%%\[*}

    [[ $root_source == "$ROOT_DEV" && $home_source == "$ROOT_DEV" ]] ||
        die 22 'Btrfs root and home mounts do not use the configured encrypted root device; rerun 03-partition'
    [[ $boot_source == "$ESP_PART" ]] ||
        die 22 'EFI mount does not use the configured ESP; rerun 03-partition'

    [[ ! -e /var/lib/pacman/db.lck ]] ||
        die 30 'pacman database lock exists; wait for package activity to finish before installing the target system'
}

pacstrap_detect_cpu_vendor() {
    local line
    local vendor_id
    local detected_vendor=''
    local vendor_count=0

    [[ -r /proc/cpuinfo ]] ||
        die 20 'cannot read /proc/cpuinfo; CPU vendor is required to select exactly one microcode package'

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ ^[[:space:]]*vendor_id[[:space:]]*:[[:space:]]*(.+)$ ]]; then
            vendor_id=${BASH_REMATCH[1]}
            vendor_id=${vendor_id//[[:space:]]/}

            [[ -n $vendor_id ]] ||
                die 20 'CPU vendor field is empty; refusing to guess a microcode package'

            if (( vendor_count == 0 )); then
                detected_vendor=$vendor_id
            elif [[ $vendor_id != "$detected_vendor" ]]; then
                die 20 'multiple CPU vendors were detected; refusing to select an ambiguous microcode package'
            fi

            vendor_count=$((vendor_count + 1))
        fi
    done < /proc/cpuinfo

    (( vendor_count > 0 )) ||
        die 20 'CPU vendor was not found in /proc/cpuinfo; refusing to guess a microcode package'

    case $detected_vendor in
        GenuineIntel)
            PACSTRAP_CPU_VENDOR=intel
            PACSTRAP_MICROCODE_PACKAGE=intel-ucode
            ;;
        AuthenticAMD)
            PACSTRAP_CPU_VENDOR=amd
            PACSTRAP_MICROCODE_PACKAGE=amd-ucode
            ;;
        *)
            die 20 "unsupported CPU vendor '$detected_vendor'; select a supported x86_64 CPU before continuing"
            ;;
    esac
}

pacstrap_install_base() {
    local -a packages=("${PACSTRAP_BASE_PACKAGES[@]}")

    packages+=("$PACSTRAP_MICROCODE_PACKAGE")

    if ! retry --retryable --idempotent --mutating --timeout 900 \
        pacstrap -K /mnt "${packages[@]}"; then
        die 30 'pacstrap failed after three bounded attempts; verify network, mirrors, package availability, and the pacman database before rerunning'
    fi

    log "base system installed; CPU vendor=$PACSTRAP_CPU_VENDOR microcode=$PACSTRAP_MICROCODE_PACKAGE"
}

pacstrap_atomic_write() {
    (( $# == 3 )) || die 64 'pacstrap_atomic_write requires path, content, and mode'

    local destination=$1
    local content=$2
    local mode=$3
    local directory=${destination%/*}
    local filename=${destination##*/}
    local temporary

    [[ -d $directory && ! -L $destination ]] ||
        die 50 "target configuration directory is missing or destination is a symlink: $destination"
    [[ ! -e $destination || -f $destination ]] ||
        die 50 "target configuration path is not a regular file: $destination"

    temporary=$(run --mutating mktemp --tmpdir="$directory" ".${filename}.XXXXXX") ||
        die 50 "cannot create temporary configuration file for: $destination"

    if ! printf '%s\n' "$content" | run --mutating tee -- "$temporary" >/dev/null; then
        run --mutating rm -f -- "$temporary" || true
        die 50 "cannot write temporary configuration file for: $destination"
    fi

    run --mutating chmod "$mode" -- "$temporary" ||
        die 50 "cannot set permissions on temporary configuration file for: $destination"
    run --mutating mv -f -- "$temporary" "$destination" ||
        die 50 "cannot atomically replace target configuration file: $destination"
}

pacstrap_enable_multilib() {
    local config=/mnt/etc/pacman.conf
    local config_mode
    local temporary

    [[ -f $config && ! -L $config ]] ||
        die 50 'target /etc/pacman.conf is missing or is not a regular file; inspect pacstrap output'

    config_mode=$(stat -c '%a' -- "$config") ||
        die 50 'cannot inspect target pacman.conf permissions'
    [[ $config_mode =~ ^[0-7]{3,4}$ ]] ||
        die 50 'target pacman.conf has invalid permissions; inspect the target filesystem'

    temporary=$(run --mutating mktemp --tmpdir=/mnt/etc .pacman.conf.XXXXXX) ||
        die 50 'cannot create temporary pacman.conf file'

    if ! awk '
        BEGIN {
            in_multilib = 0
            section_count = 0
            include_count = 0
            invalid_include = 0
        }
        /^[[:space:]]*#?[[:space:]]*\[multilib\][[:space:]]*$/ {
            section_count++
            in_multilib = 1
            print "[multilib]"
            next
        }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            in_multilib = 0
            print
            next
        }
        in_multilib && /^[[:space:]]*#?[[:space:]]*Include[[:space:]]*=/ {
            line = $0
            sub(/^[[:space:]]*#[[:space:]]*/, "", line)
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)

            if (line != "Include = /etc/pacman.d/mirrorlist") {
                invalid_include = 1
                print
                next
            }

            include_count++
            print "Include = /etc/pacman.d/mirrorlist"
            next
        }
        { print }
        END {
            if (section_count != 1 || include_count != 1 || invalid_include != 0) {
                exit 42
            }
        }
    ' "$config" | run --mutating tee -- "$temporary" >/dev/null; then
        run --mutating rm -f -- "$temporary" || true
        die 50 'target pacman.conf has a missing, duplicate, or unsupported multilib block; refusing to guess its configuration'
    fi

    run --mutating chmod "$config_mode" -- "$temporary" ||
        die 50 'cannot preserve target pacman.conf permissions'
    run --mutating mv -f -- "$temporary" "$config" ||
        die 50 'cannot atomically enable multilib in target pacman.conf'

    log 'enabled the existing multilib repository block in target pacman.conf'
}

pacstrap_configure_machine_id() {
    local machine_id_file=/mnt/etc/machine-id
    local machine_id=''

    [[ ! -L $machine_id_file ]] ||
        die 50 'target /etc/machine-id is a symlink; inspect it before continuing'

    if [[ -e $machine_id_file ]]; then
        [[ -f $machine_id_file ]] ||
            die 50 'target /etc/machine-id is not a regular file; inspect it before continuing'

        if [[ -s $machine_id_file ]]; then
            IFS= read -r machine_id < "$machine_id_file" || true

            [[ $machine_id =~ ^[[:xdigit:]]{32}$ &&
               $machine_id != 00000000000000000000000000000000 ]] ||
                die 50 'target /etc/machine-id contains an invalid non-empty value; repair it before rerunning'

            log 'target machine-id is already initialized; skipped'
            return 0
        fi
    fi

    run --mutating systemd-machine-id-setup --root=/mnt ||
        die 50 'systemd-machine-id-setup failed for /mnt; inspect target /etc/machine-id'
}

pacstrap_configure_zram() {
    local zram_config

    zram_config=$(printf '%s\n' \
        '[zram0]' \
        'zram-size = ram / (1 + min(floor(ram / 16384), 1))')

    pacstrap_atomic_write /mnt/etc/systemd/zram-generator.conf "$zram_config" 644
    log 'configured ZRAM at 100% of RAM below 16 GiB and 50% at or above 16 GiB'
}

pacstrap_generate_fstab() {
    local fstab=/mnt/etc/fstab
    local temporary

    [[ ! -L $fstab ]] ||
        die 50 'target /etc/fstab is a symlink; refusing to replace it'
    [[ ! -e $fstab || -f $fstab ]] ||
        die 50 'target /etc/fstab is not a regular file; refusing to replace it'

    temporary=$(run --mutating mktemp --tmpdir=/mnt/etc .fstab.XXXXXX) ||
        die 50 'cannot create temporary fstab file'

    if ! genfstab -U /mnt | run --mutating tee -- "$temporary" >/dev/null; then
        run --mutating rm -f -- "$temporary" || true
        die 50 'genfstab failed; inspect target mounts and rerun 03-partition'
    fi

    if ! awk '
        $0 !~ /^[[:space:]]*#/ && NF >= 3 {
            if ($2 == "/") root_count++
            if ($2 == "/home") home_count++
            if ($2 == "/boot") boot_count++
        }
        END {
            if (root_count == 1 && home_count == 1 && boot_count == 1) {
                exit 0
            }
            exit 1
        }
    ' "$temporary"; then
        run --mutating rm -f -- "$temporary" || true
        die 50 'generated fstab is missing unique /, /home, or /boot entries; inspect mounts before rerunning'
    fi

    run --mutating chmod 644 -- "$temporary" ||
        die 50 'cannot set permissions on generated fstab'
    run --mutating mv -f -- "$temporary" "$fstab" ||
        die 50 'cannot atomically replace target /etc/fstab'

    log 'generated and atomically replaced target /etc/fstab'
}

pacstrap_main() {
    (( $# == 0 )) || die 64 '04-pacstrap takes no arguments'

    init
    require_cmd uname pacstrap genfstab findmnt systemd-machine-id-setup timeout \
        awk tee mktemp chmod mv rm stat

    pacstrap_validate_state
    pacstrap_detect_cpu_vendor

    if [[ ${DRY_RUN:-0} == 1 ]]; then
        log "DRY_RUN: validated pacstrap plan; packages=${PACSTRAP_BASE_PACKAGES[*]} $PACSTRAP_MICROCODE_PACKAGE"
        printf '%s\n' "DRY_RUN: pacstrap plan validated; CPU=$PACSTRAP_CPU_VENDOR microcode=$PACSTRAP_MICROCODE_PACKAGE; no target changes made."
        return 0
    fi

    pacstrap_install_base

    [[ -d /mnt/etc && ! -L /mnt/etc ]] ||
        die 50 'pacstrap did not create target /etc; inspect package installation output'

    pacstrap_enable_multilib
    pacstrap_configure_machine_id

    [[ -d /mnt/etc/systemd && ! -L /mnt/etc/systemd ]] ||
        die 50 'target /etc/systemd is missing after base installation; inspect pacstrap output'

    pacstrap_configure_zram
    pacstrap_generate_fstab

    log '04-pacstrap completed successfully'
    printf '%s\n' 'Base system installation and target configuration completed.'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    pacstrap_main "$@"
fi
