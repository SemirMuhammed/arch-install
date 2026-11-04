#!/usr/bin/env bash
set -Eeuo pipefail

if ! declare -F init >/dev/null 2>&1; then
    if [[ ${BASH_SOURCE[0]} == */* ]]; then
        _POST_MODULE_DIR=${BASH_SOURCE[0]%/*}
    else
        _POST_MODULE_DIR=.
    fi
    # shellcheck source=lib/common.sh
    source "$_POST_MODULE_DIR/lib/common.sh"
    unset _POST_MODULE_DIR
fi

readonly POST_MARKER='/tmp/arch-install/06-post.in-progress'
readonly POST_TARGET_LOG='/mnt/var/log/arch-install.log'
readonly POST_MAPPER='ROOT'
readonly POST_MAPPER_DEVICE='/dev/mapper/ROOT'

post_require_commands() {
    local command_name

    for command_name in findmnt grep readlink swapon swapoff install tee \
        cryptsetup sync umount reboot; do
        command -v -- "$command_name" >/dev/null 2>&1 ||
            die 50 "required command is missing: $command_name; boot with the standard Arch ISO tools and rerun"
    done
}

post_validate_state() {
    local key

    state_load

    for key in BOOT_MODE FS ENCRYPTION ROOT_DEV ESP_PART ESP_UUID LUKS_UUID MOUNT_OPTIONS; do
        [[ -n ${!key:-} ]] ||
            die 50 "required installation state '$key' is missing; restore valid installer state before finalization"
    done

    [[ $BOOT_MODE == uefi && -d /sys/firmware/efi ]] ||
        die 50 'target boot mode is not UEFI; boot the Arch ISO in UEFI mode and rerun finalization'
    [[ $FS == btrfs && $ENCRYPTION == luks2 ]] ||
        die 50 'target state must specify FS=btrfs and ENCRYPTION=luks2; correct installer state before finalization'
    [[ $ROOT_DEV == "$POST_MAPPER_DEVICE" && -b $ROOT_DEV ]] ||
        die 50 'expected active LUKS mapper /dev/mapper/ROOT is missing; unlock the installed root and rerun'
    [[ $ESP_PART == /dev/* && -b $ESP_PART ]] ||
        die 50 'ESP_PART is not an existing block device; restore the correct ESP state before finalization'
    # ESP_UUID/LUKS_UUID are exported by state_load; intentionally not local here.
    # shellcheck disable=SC2153
    [[ $ESP_UUID =~ ^[[:xdigit:]-]+$ && $LUKS_UUID =~ ^[[:xdigit:]-]+$ ]] ||
        die 50 'ESP_UUID or LUKS_UUID is malformed; restore valid partition UUID state before finalization'
    [[ $MOUNT_OPTIONS =~ ^[[:alnum:]_:,=.-]+$ ]] ||
        die 50 'MOUNT_OPTIONS is malformed; restore valid mount options before finalization'
}

# Succeed only if vfat mount options make every file root-only: umask=0077, or
# fmask and dmask both 0077. Anything else leaves /loader/random-seed world-readable.
post_vfat_options_private() {
    local options=$1
    [[ ,$options, == *,umask=0077,* ]] && return 0
    [[ ,$options, == *,fmask=0077,* && ,$options, == *,dmask=0077,* ]] && return 0
    return 1
}

post_validate_mounts() {
    local root_info
    local root_fstype
    local root_fsroot
    local esp_info
    local esp_fstype
    local esp_uuid
    local expected_esp_uuid=${ESP_UUID,,}

    root_info=$(findmnt --raw --noheadings --mountpoint /mnt --output FSTYPE,FSROOT) ||
        die 50 'installed root is not mounted exactly at /mnt; mount the target root subvolume @ and rerun'
    read -r root_fstype root_fsroot <<< "$root_info"
    [[ $root_fstype == btrfs && $root_fsroot == /@ ]] ||
        die 50 'mounted /mnt is not the Btrfs root subvolume @; correct the target mount and rerun'

    esp_info=$(findmnt --raw --noheadings --mountpoint /mnt/boot --output FSTYPE,UUID) ||
        die 50 'installed ESP is not mounted exactly at /mnt/boot; mount the target ESP and rerun'
    read -r esp_fstype esp_uuid <<< "$esp_info"
    [[ $esp_fstype == vfat && ${esp_uuid,,} == "$expected_esp_uuid" ]] ||
        die 50 'mounted /mnt/boot does not match the configured FAT ESP UUID; mount the correct ESP and rerun'

    local esp_options
    esp_options=$(findmnt --raw --noheadings --mountpoint /mnt/boot --output OPTIONS) ||
        die 50 'cannot read mount options for /mnt/boot; inspect mount state'
    post_vfat_options_private "$esp_options" ||
        die 50 "EFI partition is mounted with world-readable permissions ($esp_options); remount /mnt/boot with umask=0077 and rerun"

    # The installed system mounts /boot from this fstab, so it must carry the same options.
    local fstab_boot_options
    fstab_boot_options=$(awk '$0 !~ /^[[:space:]]*#/ && NF >= 4 && $2 == "/boot" && $3 == "vfat" { print $4; exit }' /mnt/etc/fstab)
    [[ -n $fstab_boot_options ]] ||
        die 50 'target fstab has no vfat entry for /boot; regenerate it with genfstab -U /mnt'
    post_vfat_options_private "$fstab_boot_options" ||
        die 50 "target fstab /boot entry is world-readable ($fstab_boot_options); set umask=0077 on that entry and rerun"
}

post_require_file() {
    local path=$1

    [[ ! -L $path && -f $path && -r $path ]] ||
        die 50 "required installed-system file is missing, unreadable, or a symlink: $path; repair the target and rerun"
}

post_validate_boot_files() {
    local entry
    local found_entry=0
    local nullglob_was_set=0
    local -a entries=()

    [[ -d /mnt/boot/loader/entries && ! -L /mnt/boot/loader/entries ]] ||
        die 50 'systemd-boot entry directory is missing or unsafe; restore /mnt/boot/loader/entries and rerun'
    [[ -s /mnt/boot/vmlinuz-linux-lts && ! -L /mnt/boot/vmlinuz-linux-lts ]] ||
        die 50 'linux-lts kernel image is missing or unsafe at /mnt/boot/vmlinuz-linux-lts; reinstall the target kernel and rerun'
    [[ -s /mnt/boot/initramfs-linux-lts.img && ! -L /mnt/boot/initramfs-linux-lts.img ]] ||
        die 50 'linux-lts initramfs is missing or unsafe at /mnt/boot/initramfs-linux-lts.img; regenerate the target initramfs and rerun'

    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    entries=(/mnt/boot/loader/entries/*.conf)
    if (( nullglob_was_set == 0 )); then
        shopt -u nullglob
    fi

    (( ${#entries[@]} > 0 )) ||
        die 50 'no systemd-boot entry files were found; create a valid entry under /mnt/boot/loader/entries and rerun'

    for entry in "${entries[@]}"; do
        [[ ! -L $entry && -s $entry ]] ||
            die 50 "systemd-boot entry is empty or a symlink: $entry; repair the entry and rerun"
        if grep -Eq '^[[:space:]]*linux[[:space:]]+/vmlinuz-linux-lts([[:space:]]|$)' "$entry" &&
           grep -Eq '^[[:space:]]*initrd[[:space:]]+/initramfs-linux-lts\.img([[:space:]]|$)' "$entry"; then
            found_entry=1
        fi
        if grep -Eq '^[[:space:]]*initrd[[:space:]]+/initramfs-linux-lts-fallback\.img([[:space:]]|$)' "$entry"; then
            [[ -s /mnt/boot/initramfs-linux-lts-fallback.img && ! -L /mnt/boot/initramfs-linux-lts-fallback.img ]] ||
                die 50 "entry '$entry' references a missing fallback initramfs; regenerate the target fallback image and rerun"
        fi
    done

    (( found_entry == 1 )) ||
        die 50 'no systemd-boot entry references both linux-lts and its initramfs; repair the target boot entry and rerun'
}

post_validate_configuration() {
    local path

    for path in /mnt/etc/fstab /mnt/etc/mkinitcpio.conf /mnt/etc/hostname /mnt/etc/passwd; do
        post_require_file "$path"
    done

    if [[ -e /mnt/etc/crypttab || -L /mnt/etc/crypttab ]]; then
        post_require_file /mnt/etc/crypttab
    fi
}

post_validate_target() {
    post_validate_state
    post_validate_mounts
    post_validate_boot_files
    post_validate_configuration
    log '06-post target validation passed'
}

post_read_marker() {
    POST_MARKER_STAGE=''

    [[ -e $POST_MARKER || -L $POST_MARKER ]] || return 0
    [[ ! -L $POST_MARKER && -f $POST_MARKER ]] ||
        die 50 "finalization recovery marker is not a regular file: $POST_MARKER; inspect and repair it before rerunning"

    IFS= read -r POST_MARKER_STAGE < "$POST_MARKER" ||
        die 50 "cannot read finalization recovery marker: $POST_MARKER; inspect and repair it before rerunning"
    [[ $POST_MARKER_STAGE == CLEANUP || $POST_MARKER_STAGE == READY_TO_UNMOUNT ]] ||
        die 50 "finalization recovery marker has an unknown stage: $POST_MARKER; inspect it before rerunning"
}

post_write_marker() {
    local stage=$1

    if [[ ! -e $POST_MARKER ]]; then
        run --mutating install -m 600 /dev/null "$POST_MARKER" ||
            die 50 "cannot create finalization recovery marker: $POST_MARKER"
    fi
    printf '%s\n' "$stage" | run --mutating tee -- "$POST_MARKER" >/dev/null ||
        die 50 "cannot update finalization recovery marker: $POST_MARKER"
    POST_MARKER_STAGE=$stage
}

post_copy_log() {
    [[ ! -L $LOG_FILE && -f $LOG_FILE && -r $LOG_FILE ]] ||
        die 50 "installer log is missing, unreadable, or a symlink: $LOG_FILE; restore the log before finalization"
    [[ ! -L /mnt/var && ! -L /mnt/var/log ]] ||
        die 50 'target log directory contains a symlink; repair /mnt/var and /mnt/var/log before finalization'

    run --mutating install -D -m 600 -- "$LOG_FILE" "$POST_TARGET_LOG" ||
        die 50 "cannot copy installer log to '$POST_TARGET_LOG'; check target filesystem space and permissions"
}

post_swapoff_target_entries() {
    local fstab_sources
    local active_sources
    local fstab_source
    local active_source
    local resolved_fstab
    local resolved_active
    local matched
    local swap_entry_count
    local -a target_swaps=()
    local -a active_swaps=()

    [[ -f /mnt/etc/fstab && ! -L /mnt/etc/fstab ]] ||
        die 50 'target /mnt/etc/fstab is missing or unsafe; rerun 04-pacstrap'
    # Count swap entries first: findmnt exits non-zero when nothing matches, which is
    # the normal case here (zram-generator provides swap, so fstab has none).
    swap_entry_count=$(awk '$0 !~ /^[[:space:]]*#/ && NF >= 3 && $3 == "swap" { n++ } END { print n + 0 }' /mnt/etc/fstab) ||
        die 50 'cannot read target /mnt/etc/fstab; repair the fstab before finalization'
    if [[ $swap_entry_count == 0 ]]; then
        log 'no swap entries in target fstab; nothing to disable'
        return 0
    fi
    fstab_sources=$(findmnt --fstab --evaluate --tab-file /mnt/etc/fstab \
        --types swap --noheadings --raw --output SOURCE) ||
        die 50 'cannot parse swap entries in target /mnt/etc/fstab; repair the fstab before finalization'
    active_sources=$(swapon --show=NAME --noheadings --raw) ||
        die 50 'cannot enumerate active swap devices; inspect swap state before finalization'

    if [[ -n $fstab_sources ]]; then
        mapfile -t target_swaps <<< "$fstab_sources"
    fi
    if [[ -n $active_sources ]]; then
        mapfile -t active_swaps <<< "$active_sources"
    fi

    for fstab_source in "${target_swaps[@]}"; do
        [[ -n $fstab_source ]] || continue
        resolved_fstab=$(readlink -f -- "$fstab_source") ||
            die 50 "cannot resolve target fstab swap source '$fstab_source'; repair the entry before finalization"
        [[ -b $resolved_fstab ]] ||
            die 50 "target fstab swap source is not a block device: '$fstab_source'; swapfile entries are disabled by this install configuration"

        for active_source in "${active_swaps[@]}"; do
            [[ -n $active_source ]] || continue
            resolved_active=$(readlink -f -- "$active_source") ||
                die 50 "cannot resolve active swap source '$active_source'; inspect active swap state"
            matched=0
            if [[ $resolved_active == "$resolved_fstab" ]]; then
                matched=1
            fi
            if (( matched == 1 )); then
                run --mutating swapoff -- "$active_source" ||
                    die 50 "cannot disable target-associated swap '$active_source'; close its users and rerun finalization"
                log "disabled target-associated swap '$active_source'"
            fi
        done
    done
}

# Plain removal: shred cannot guarantee erasure on Btrfs (copy-on-write) or SSDs,
# so protection comes from never writing secrets to unencrypted media.
post_remove_file() {
    local path=$1

    [[ -e $path || -L $path ]] || return 0
    [[ ! -L $path && -f $path ]] ||
        die 50 "refusing to remove a non-regular or symlink path: $path; inspect it and rerun finalization"
    run --mutating rm -f -- "$path" ||
        die 50 "cannot remove '$path'; inspect the filesystem and rerun finalization"
}

post_unmount_target() {
    local mountpoints

    mountpoints=$(findmnt --raw --noheadings --output TARGET) ||
        die 50 'cannot enumerate mountpoints before target unmount; inspect mount state'

    if grep -Fxq '/mnt' <<< "$mountpoints" || grep -Eq '^/mnt/' <<< "$mountpoints"; then
        run --mutating umount --recursive -- /mnt ||
            die 50 'recursive unmount of /mnt failed; inspect busy processes and remaining mounts, then rerun finalization'
    fi

    mountpoints=$(findmnt --raw --noheadings --output TARGET) ||
        die 50 'cannot verify mountpoints after target unmount; inspect mount state'
    if grep -Fxq '/mnt' <<< "$mountpoints" || grep -Eq '^/mnt/' <<< "$mountpoints"; then
        die 50 'one or more /mnt mounts remain after recursive unmount; inspect findmnt output and rerun finalization'
    fi
}

post_close_mapper() {
    if [[ -e $POST_MAPPER_DEVICE || -L $POST_MAPPER_DEVICE ]]; then
        [[ -b $POST_MAPPER_DEVICE ]] ||
            die 50 "LUKS mapper path is unsafe: $POST_MAPPER_DEVICE; inspect cryptsetup state"
        if cryptsetup status "$POST_MAPPER" >/dev/null 2>&1; then
            run --mutating cryptsetup close "$POST_MAPPER" ||
                die 50 "cannot close LUKS mapper '$POST_MAPPER'; inspect remaining device users and rerun finalization"
        else
            die 50 "LUKS mapper path exists but cryptsetup cannot verify '$POST_MAPPER'; inspect mapper state"
        fi
    fi
}

post_finalize() {
    local dry_run=${DRY_RUN:-0}

    (( EUID == 0 )) || die 50 '06-post requires root; rerun from the official Arch ISO as root'
    [[ $dry_run == 0 || $dry_run == 1 ]] ||
        die 50 'DRY_RUN must be 0 or 1; correct the environment and rerun finalization'

    init
    trap 'die 50 "finalization interrupted by INT; rerun 06-post to resume safely"' INT
    trap 'die 50 "finalization interrupted by TERM; rerun 06-post to resume safely"' TERM
    post_require_commands
    post_read_marker

    if [[ $POST_MARKER_STAGE != READY_TO_UNMOUNT ]]; then
        post_validate_target
    else
        log '06-post resuming after pre-unmount cleanup; target validation was completed before the recovery marker advanced'
    fi

    if [[ $dry_run == 1 ]]; then
        log 'DRY_RUN: would copy installer log, disable target-associated swap, remove cleanup files, recursively unmount /mnt, close ROOT mapper, sync, and request reboot confirmation'
        printf '%s\n' 'DRY_RUN: target validated; no cleanup, unmount, mapper close, or reboot performed.'
        return 0
    fi

    if [[ $POST_MARKER_STAGE != READY_TO_UNMOUNT ]]; then
        post_write_marker CLEANUP
        post_copy_log
        post_swapoff_target_entries
        post_remove_file /mnt/root/.install.env
        post_write_marker READY_TO_UNMOUNT
    fi

    post_remove_file "$STATE_FILE"
    post_unmount_target
    post_close_mapper

    run --mutating sync ||
        die 50 'sync failed after target unmount; inspect storage state and rerun finalization'

    log '06-post finalization succeeded: target validated, cleanup completed, mounts removed, ROOT mapper closed'
    printf '%s\n' 'Installation finalized successfully.'
    printf '%s\n' 'Target mounts removed; encrypted root mapper closed.'

    if confirm 'Reboot the system now?'; then
        log 'reboot confirmed by operator'
        run --mutating reboot ||
            die 50 'reboot command failed; system remains running, inspect the live ISO and reboot manually'
    else
        log 'reboot declined; system remains running'
        printf '%s\n' 'Reboot declined; system remains running.'
    fi
}

main() {
    (( $# == 0 )) || die 50 '06-post takes no arguments; rerun without arguments'
    post_finalize
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
