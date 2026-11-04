#!/usr/bin/env bash
set -Eeuo pipefail

if ! declare -F init >/dev/null 2>&1; then
    if [[ ${BASH_SOURCE[0]} == */* ]]; then
        _PARTITION_MODULE_DIR=${BASH_SOURCE[0]%/*}
    else
        _PARTITION_MODULE_DIR=.
    fi
    # shellcheck source=lib/common.sh
    source "$_PARTITION_MODULE_DIR/lib/common.sh"
    unset _PARTITION_MODULE_DIR
fi

declare -g PARTITION_LSBLK_JSON=''
declare -ga PARTITION_DESCENDANT_PATHS=()

partition_validate_state() {
    (( EUID == 0 )) ||
        die 10 '03-partition requires root; rerun from the Arch ISO as root'

    state_load

    [[ ${BOOT_MODE:-} == uefi && -d /sys/firmware/efi ]] ||
        die 11 'UEFI boot state is missing; boot the ISO in UEFI mode and rerun preflight'

    [[ ${DISK:-} == /dev/* && -b ${DISK:-} ]] ||
        die 64 'DISK must be an existing absolute block-device path; rerun 02-config'

    [[ ${FS:-} == btrfs && ${ENCRYPTION:-} == luks2 ]] ||
        die 64 'partition settings must be FS=btrfs and ENCRYPTION=luks2; rerun 02-config'

    [[ -n ${MOUNT_OPTIONS:-} && ${MOUNT_OPTIONS:-} =~ ^[[:alnum:]_:,=.-]+$ ]] ||
        die 64 'MOUNT_OPTIONS is empty or contains unsupported characters; rerun 02-config'

    if [[ -n ${ESP_PART:-} || -n ${ROOT_PART:-} || -n ${ROOT_DEV:-} ||
          -n ${ESP_UUID:-} || -n ${LUKS_UUID:-} ]]; then
        die 20 'partition state already exists; inspect the previous installation before repartitioning'
    fi
}

partition_check_recovery_marker() {
    local marker=/tmp/arch-install/partition.in-progress

    [[ ! -e $marker && ! -L $marker ]] ||
        die 20 "interrupted partition run detected at '$marker'; inspect disk and mounts, then manually recover before retrying"
}

partition_install_tools() {
    require_cmd pacman timeout
    ensure_live_jq

    [[ ! -e /var/lib/pacman/db.lck ]] ||
        die 30 'pacman database lock exists; wait for package activity to finish before partitioning'

    live_pacman_sync

    if ! retry --retryable --idempotent --mutating --timeout 900 \
        pacman -S --needed --noconfirm \
            gptfdisk btrfs-progs dosfstools cryptsetup; then
        die 31 'temporary partition tools could not be installed; verify network, pacman mirrors, and package database'
    fi
}

partition_refresh_inventory() {
    PARTITION_LSBLK_JSON=$(lsblk --tree --json --paths \
        --output PATH,TYPE,MOUNTPOINTS,RO "$DISK") ||
        die 20 'lsblk target-disk enumeration failed; inspect the device and rerun'

    jq -e '.blockdevices | type == "array" and length == 1' \
        >/dev/null <<< "$PARTITION_LSBLK_JSON" ||
        die 20 'lsblk returned invalid or ambiguous target-disk metadata; refusing disk mutation'

    jq -e --arg disk "$DISK" '
        .blockdevices[0]
        | .path == $disk and .type == "disk" and
          ((.ro // false) == false or .ro == 0)
    ' >/dev/null <<< "$PARTITION_LSBLK_JSON" ||
        die 20 "target '$DISK' is missing, read-only, or not a whole disk; rerun 02-config"
}

partition_live_medium_guard() {
    local boot_source
    local boot_disk

    [[ -d /run/archiso/bootmnt ]] ||
        die 20 'Arch ISO boot mount is missing; refusing to identify a target disk'

    boot_source=$(findmnt --evaluate --noheadings --raw --output SOURCE \
        --target /run/archiso/bootmnt) ||
        die 20 'cannot identify /run/archiso/bootmnt source; refusing disk mutation'

    boot_source=${boot_source%%\[*}
    [[ $boot_source == /dev/* ]] ||
        die 20 'Arch ISO boot source is not a block device; refusing disk mutation'

    # Map the boot partition to its unique top-level physical disk.
    # shellcheck disable=SC2016
    boot_disk=$(lsblk --tree --json --paths --output PATH,TYPE |
        lsblk_root_device_for "$boot_source") ||
        die 20 'cannot map the Arch ISO boot source to one top-level device; refusing disk mutation'

    [[ $boot_disk != "$DISK" ]] ||
        die 20 "target '$DISK' hosts the Arch ISO; select another disk"
}

partition_collect_descendants() {
    local descendant_text
    local descendant_path

    # lsblk JSON tree is used instead of parsing human-readable device output.
    # shellcheck disable=SC2016
    descendant_text=$(jq -er '
        def descendants: ., (.children[]? | descendants);
        [.blockdevices[0] | descendants | .path // empty]
        | if length > 0 then .[] else error("no descendants") end
    ' <<< "$PARTITION_LSBLK_JSON") ||
        die 20 'cannot enumerate target-disk descendants; refusing disk mutation'

    PARTITION_DESCENDANT_PATHS=()
    while IFS= read -r descendant_path; do
        [[ -n $descendant_path ]] &&
            PARTITION_DESCENDANT_PATHS+=("$descendant_path")
    done <<< "$descendant_text"

    (( ${#PARTITION_DESCENDANT_PATHS[@]} > 0 )) ||
        die 20 'target disk has no discoverable block-device descendants; refusing disk mutation'
}

partition_swap_belongs_to_target() {
    local swap_source=$1

    # Compare the active swap path against the selected disk's lsblk tree.
    # shellcheck disable=SC2016
    jq -e --arg swap "$swap_source" '
        def descendants: ., (.children[]? | descendants);
        any(.blockdevices[0] | descendants; .path == $swap)
    ' >/dev/null <<< "$PARTITION_LSBLK_JSON"
}

partition_check_holders() {
    local block_path
    local block_name
    local holder

    for block_path in "${PARTITION_DESCENDANT_PATHS[@]}"; do
        block_name=$(basename -- "$block_path") ||
            die 20 'cannot inspect target-disk holder names; refusing disk mutation'

        for holder in "/sys/class/block/$block_name/holders/"*; do
            [[ -e $holder ]] || continue
            die 20 "target device '$block_path' still has an active holder; close dependent mappings and rerun"
        done
    done
}

partition_cleanup_descendants() {
    local swap_source
    local first_line=1
    local mount_rows
    local mount_depth
    local mountpoint
    local jq_status

    partition_refresh_inventory
    partition_live_medium_guard
    partition_collect_descendants

    [[ -r /proc/swaps ]] ||
        die 20 'cannot inspect active swap devices; refusing disk mutation'

    while IFS=' ' read -r swap_source _; do
        if (( first_line == 1 )); then
            first_line=0
            continue
        fi

        [[ $swap_source == /dev/* ]] || continue

        if partition_swap_belongs_to_target "$swap_source"; then
            run --mutating swapoff -- "$swap_source" ||
                die 20 "cannot disable target-disk swap '$swap_source'; release it and rerun"
        else
            jq_status=$?
            (( jq_status == 1 )) ||
                die 20 'cannot safely map an active swap device to the target disk'
        fi
    done < /proc/swaps

    # Unmount target descendants deepest-first.
    # shellcheck disable=SC2016
    mount_rows=$(jq -r '
        def descendants: ., (.children[]? | descendants);
        .blockdevices[0] | descendants
        | .mountpoints[]? | select(. != null)
        | [(split("/") | length), .] | @tsv
    ' <<< "$PARTITION_LSBLK_JSON") ||
        die 20 'cannot enumerate target-disk mountpoints; refusing disk mutation'

    while IFS=$'\t' read -r mount_depth mountpoint; do
        [[ -n $mountpoint ]] || continue

        [[ $mount_depth =~ ^[0-9]+$ ]] ||
            die 20 'invalid target-disk mount depth from lsblk; refusing disk mutation'

        [[ $mountpoint != / ]] ||
            die 20 'target disk contains the running system root; refusing to unmount it'

        run --mutating umount -- "$mountpoint" ||
            die 20 "cannot unmount target-disk mountpoint '$mountpoint'; release it and rerun"
    done < <(printf '%s\n' "$mount_rows" | sort -rn -k1,1 | cut -f2-)

    partition_refresh_inventory
    partition_collect_descendants
    partition_check_holders

    # Confirm no target descendant remains mounted.
    # shellcheck disable=SC2016
    if jq -e '
        def descendants: ., (.children[]? | descendants);
        any(.blockdevices[0] | descendants;
            any(.mountpoints[]?; . != null))
    ' >/dev/null <<< "$PARTITION_LSBLK_JSON"; then
        die 20 'target-disk mountpoints remain active after cleanup; refusing disk mutation'
    else
        jq_status=$?
        (( jq_status == 1 )) ||
            die 20 'cannot verify target-disk mount cleanup'
    fi

    first_line=1
    while IFS=' ' read -r swap_source _; do
        if (( first_line == 1 )); then
            first_line=0
            continue
        fi

        [[ $swap_source == /dev/* ]] || continue

        if partition_swap_belongs_to_target "$swap_source"; then
            die 20 "target-disk swap '$swap_source' remains active; refusing disk mutation"
        else
            jq_status=$?
            (( jq_status == 1 )) ||
                die 20 'cannot verify target-disk swap cleanup'
        fi
    done < /proc/swaps
}

partition_assert_target_safe() {
    local jq_status
    local first_line=1
    local swap_source

    partition_refresh_inventory
    partition_live_medium_guard
    partition_collect_descendants
    partition_check_holders

    # Recheck mount state immediately before destructive operations.
    # shellcheck disable=SC2016
    if jq -e '
        def descendants: ., (.children[]? | descendants);
        any(.blockdevices[0] | descendants;
            any(.mountpoints[]?; . != null))
    ' >/dev/null <<< "$PARTITION_LSBLK_JSON"; then
        die 20 'target disk became mounted; refusing destructive operation'
    else
        jq_status=$?
        (( jq_status == 1 )) ||
            die 20 'cannot verify target-disk mount state'
    fi

    [[ -r /proc/swaps ]] ||
        die 20 'cannot inspect active swap devices; refusing destructive operation'

    while IFS=' ' read -r swap_source _; do
        if (( first_line == 1 )); then
            first_line=0
            continue
        fi

        [[ $swap_source == /dev/* ]] || continue

        if partition_swap_belongs_to_target "$swap_source"; then
            die 20 "target-disk swap '$swap_source' became active; refusing destructive operation"
        else
            jq_status=$?
            (( jq_status == 1 )) ||
                die 20 'cannot verify target-disk swap state'
        fi
    done < /proc/swaps
}

partition_confirm_target() {
    local expected_name
    local typed_name

    expected_name=$(basename -- "$DISK") ||
        die 64 'cannot determine target device basename; rerun 02-config'

    printf 'This permanently erases %s. Type %s to continue: ' \
        "$DISK" "$expected_name" >&2

    IFS= read -r typed_name ||
        die 64 'disk confirmation input ended; rerun and type the exact device basename'

    [[ $typed_name == "$expected_name" ]] ||
        die 64 'disk confirmation did not match; no target-disk changes were made'
}

partition_create_recovery_marker() {
    local marker=/tmp/arch-install/partition.in-progress
    local marker_dir=/tmp/arch-install
    local device_name
    local owner

    [[ ! -e $marker && ! -L $marker ]] ||
        die 20 "partition recovery marker '$marker' already exists; manually recover before retrying"

    run --mutating install -d -m 700 -- "$marker_dir" ||
        die 50 'cannot create partition state directory; inspect /tmp and rerun'

    [[ -d $marker_dir && ! -L $marker_dir ]] ||
        die 50 'partition state directory is missing or is a symlink; refusing marker creation'

    owner=$(stat -c '%u' -- "$marker_dir") ||
        die 50 'cannot inspect partition state directory owner'

    [[ $owner == 0 ]] ||
        die 50 'partition state directory is not root-owned; refusing marker creation'

    device_name=$(basename -- "$DISK") ||
        die 50 'cannot determine target device name; refusing to create recovery marker'

    run --mutating install -m 600 /dev/null "$marker" ||
        die 50 'cannot create partition recovery marker; no disk cleanup or mutation has started'

    printf '%s\n' "$device_name" |
        run --mutating tee "$marker" >/dev/null ||
        die 50 'cannot write partition recovery marker; inspect marker before retrying'

    run --mutating chmod 600 -- "$marker" ||
        die 50 'cannot secure partition recovery marker; inspect its permissions before proceeding'
}

partition_clear_recovery_marker() {
    local marker=/tmp/arch-install/partition.in-progress
    local recorded_device
    local expected_device

    [[ -f $marker && ! -L $marker ]] ||
        die 50 'partition recovery marker is missing or invalid; inspect installation state'

    recorded_device=$(<"$marker") ||
        die 50 'cannot read partition recovery marker; inspect installation state'

    expected_device=$(basename -- "$DISK") ||
        die 50 'cannot determine target device name while clearing recovery marker'

    [[ $recorded_device == "$expected_device" ]] ||
        die 50 'partition recovery marker belongs to another disk; refusing to clear it'

    run --mutating rm -- "$marker" ||
        die 50 'installation succeeded but recovery marker could not be removed; inspect state before rerunning'
}

partition_device_paths() {
    local disk_name=${DISK##*/}
    local separator=''

    [[ $disk_name =~ [0-9]$ ]] && separator=p

    ESP_PART="${DISK}${separator}1"
    ROOT_PART="${DISK}${separator}2"
}

partition_wipe_and_partition() {
    partition_assert_target_safe

    run --mutating wipefs --all --force "$DISK" ||
        die 20 "cannot wipe filesystem signatures from '$DISK'; inspect the device and rerun"

    partition_assert_target_safe

    run --mutating sgdisk --zap-all --clear \
        --new=1:0:+1GiB --typecode=1:EF00 --change-name=1:EFIBOOT \
        --new=2:0:0 --typecode=2:8300 --change-name=2:ROOT \
        "$DISK" ||
        die 20 "GPT partitioning failed on '$DISK'; inspect the disk and rerun recovery"

    run --mutating partprobe "$DISK" ||
        die 20 "partprobe failed for '$DISK'; inspect kernel partition state and rerun"

    run udevadm settle --timeout=30 ||
        die 20 'udevadm did not settle after partitioning; inspect kernel device events and rerun'

    partition_device_paths

    [[ -b $ESP_PART && -b $ROOT_PART ]] ||
        die 20 'expected ESP/root partition devices did not appear; inspect partition table and rerun'
}

partition_format_and_unlock() {
    local mapper_path
    local mapper_name
    local root_partition_name

    partition_assert_target_safe

    run --mutating mkfs.fat -F32 -n EFIBOOT "$ESP_PART" ||
        die 20 "FAT32 formatting failed on '$ESP_PART'; inspect the partition and rerun"

    partition_assert_target_safe

    # cryptsetup prompts twice; the passphrase never enters Bash state or argv.
    run --mutating cryptsetup luksFormat --type luks2 "$ROOT_PART" ||
        die 20 "LUKS2 formatting failed on '$ROOT_PART'; inspect the partition and rerun"

    partition_assert_target_safe

    [[ ! -e /dev/mapper/ROOT ]] ||
        die 20 '/dev/mapper/ROOT already exists; close or rename the existing mapping before continuing'

    run --mutating cryptsetup open "$ROOT_PART" ROOT ||
        die 20 "cannot open LUKS2 device '$ROOT_PART'; verify the passphrase and rerun recovery"

    ROOT_DEV=/dev/mapper/ROOT

    [[ -b $ROOT_DEV ]] ||
        die 20 'cryptsetup did not create /dev/mapper/ROOT; inspect the mapping and rerun recovery'

    partition_live_medium_guard

    mapper_path=$(readlink -f -- "$ROOT_DEV") ||
        die 20 'cannot resolve the ROOT mapper device; inspect cryptsetup state'

    mapper_name=$(basename -- "$mapper_path") ||
        die 20 'cannot determine ROOT mapper sysfs name; inspect cryptsetup state'

    root_partition_name=$(basename -- "$ROOT_PART") ||
        die 20 'cannot determine root partition sysfs name; inspect block-device state'

    [[ -e "/sys/class/block/$mapper_name/slaves/$root_partition_name" ]] ||
        die 20 'ROOT mapper is not backed by the selected root partition; refusing filesystem creation'

    run --mutating mkfs.btrfs "$ROOT_DEV" ||
        die 20 'Btrfs formatting failed on /dev/mapper/ROOT; inspect the mapping and rerun recovery'
}

partition_mount_btrfs() {
    local subvolume_id
    local boot_uuid
    local luks_uuid
    local existing_content

    if findmnt -rn -M /mnt >/dev/null 2>&1; then
        die 22 '/mnt is already a mountpoint; unmount the existing installation target and rerun'
    fi

    run --mutating mkdir -p -- /mnt ||
        die 22 'cannot create /mnt; verify the live ISO filesystem'

    existing_content=$(find /mnt -mindepth 1 -maxdepth 1 -print -quit) ||
        die 22 'cannot inspect /mnt; verify the installation target directory'

    [[ -z $existing_content ]] ||
        die 22 '/mnt is not empty; move or remove its contents before partitioning'

    run --mutating mount -t btrfs "$ROOT_DEV" /mnt ||
        die 22 'cannot mount the new Btrfs filesystem at /mnt; inspect the LUKS mapping'

    run --mutating btrfs subvolume create /mnt/@ ||
        die 22 'cannot create Btrfs subvolume @; inspect /mnt and recover manually'

    run --mutating btrfs subvolume create /mnt/@home ||
        die 22 'cannot create Btrfs subvolume @home; inspect /mnt and recover manually'

    subvolume_id=$(btrfs inspect-internal rootid /mnt/@) ||
        die 22 'cannot determine the @ subvolume ID; inspect the Btrfs filesystem'

    [[ $subvolume_id =~ ^[0-9]+$ ]] ||
        die 22 'Btrfs returned an invalid @ subvolume ID; inspect the filesystem'

    run --mutating btrfs subvolume set-default "$subvolume_id" /mnt ||
        die 22 'cannot set @ as the Btrfs default subvolume; inspect the filesystem'

    run --mutating umount -- /mnt ||
        die 22 'cannot unmount temporary Btrfs mount at /mnt; inspect active users'

    run --mutating mount -o "${MOUNT_OPTIONS},subvol=@" "$ROOT_DEV" /mnt ||
        die 22 'cannot mount Btrfs subvolume @ at /mnt; inspect mount options and recover manually'

    run --mutating mkdir -p -- /mnt/home /mnt/boot ||
        die 22 'cannot create /mnt/home and /mnt/boot; inspect the mounted root filesystem'

    run --mutating mount -o "${MOUNT_OPTIONS},subvol=@home" "$ROOT_DEV" /mnt/home ||
        die 22 'cannot mount Btrfs subvolume @home at /mnt/home; inspect mount options'

    # umask=0077: the EFI partition holds /loader/random-seed, which must not be world-readable.
    run --mutating mount -o umask=0077 "$ESP_PART" /mnt/boot ||
        die 22 'cannot mount the EFI system partition at /mnt/boot; inspect the ESP'

    require_mount /mnt
    require_mount /mnt/home
    require_mount /mnt/boot

    boot_uuid=$(blkid -s UUID -o value "$ESP_PART") ||
        die 20 "cannot read ESP UUID from '$ESP_PART'; inspect the filesystem signature"

    luks_uuid=$(blkid -s UUID -o value "$ROOT_PART") ||
        die 20 "cannot read LUKS UUID from '$ROOT_PART'; inspect the encrypted partition"

    [[ -n $boot_uuid && -n $luks_uuid ]] ||
        die 20 'ESP or LUKS UUID is empty; inspect the formatted partitions'

    state_set_many \
        ESP_PART "$ESP_PART" \
        ROOT_PART "$ROOT_PART" \
        ROOT_DEV "$ROOT_DEV" \
        ESP_UUID "$boot_uuid" \
        LUKS_UUID "$luks_uuid"
}

partition_main() {
    (( $# == 0 )) || die 64 '03-partition takes no arguments'

    init
    partition_validate_state
    partition_check_recovery_marker
    partition_install_tools

    require_cmd lsblk findmnt wipefs udevadm sgdisk partprobe mkfs.fat \
        cryptsetup mkfs.btrfs btrfs mount umount swapoff swapon blkid \
        basename sort cut find readlink stat install tee rm jq

    partition_refresh_inventory
    partition_live_medium_guard

    if [[ ${DRY_RUN:-0} == 1 ]]; then
        log 'DRY_RUN: target-disk cleanup, partitioning, formatting, and mounts skipped'
        printf '%s\n' 'DRY_RUN: partition plan validated; no target-disk changes made.'
        return 0
    fi

    partition_confirm_target
    partition_create_recovery_marker
    partition_cleanup_descendants
    partition_assert_target_safe
    partition_wipe_and_partition
    partition_format_and_unlock
    partition_mount_btrfs
    partition_clear_recovery_marker

    log "partitioning and mounts completed for '$DISK'"
    printf '%s\n' 'Partitioning and filesystem mounts completed.'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    partition_main "$@"
fi
