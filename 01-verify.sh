#!/usr/bin/env bash
set -Eeuo pipefail

if ! declare -F init >/dev/null 2>&1; then
    _VERIFY_MODULE_DIR=${BASH_SOURCE[0]%/*}
    [[ $_VERIFY_MODULE_DIR != "${BASH_SOURCE[0]}" ]] || _VERIFY_MODULE_DIR=.
    # shellcheck source=lib/common.sh
    source "$_VERIFY_MODULE_DIR/lib/common.sh"
    unset _VERIFY_MODULE_DIR
fi

verify_arch_iso() {
    local os_release_line
    local image_id_found=0

    [[ -d /run/archiso/bootmnt && -f /version && -r /etc/os-release ]] ||
        die 11 'official Arch ISO markers are missing; boot the official Arch installation media and rerun preflight'

    while IFS= read -r os_release_line || [[ -n $os_release_line ]]; do
        if [[ $os_release_line == 'IMAGE_ID=archlinux' ]]; then
            image_id_found=1
            break
        fi
    done < /etc/os-release

    (( image_id_found == 1 )) ||
        die 11 'Arch ISO IMAGE_ID marker is missing; boot the official Arch installation media and rerun preflight'
}

verify_architecture() {
    local architecture

    if ! architecture=$(uname -m); then
        die 10 'cannot determine system architecture; verify the Arch ISO environment and rerun preflight'
    fi

    [[ $architecture == x86_64 ]] ||
        die 10 "unsupported architecture: $architecture; boot an x86_64 Arch Linux installation medium"
}

verify_uefi() {
    [[ -d /sys/firmware/efi ]] ||
        die 12 'UEFI firmware mode is required; reboot the installer media in UEFI mode before continuing'
}

verify_live_tools() {
    require_cmd uname curl timedatectl pacstrap genfstab sgdisk mkfs.fat
}

verify_pacman_available() {
    local process_comm
    local process_name

    [[ ! -e /var/lib/pacman/db.lck ]] ||
        die 30 'pacman database lock exists; verify no pacman process is running and investigate the lock without deleting it automatically'

    for process_comm in /proc/[0-9]*/comm; do
        [[ -r $process_comm ]] || continue
        process_name=''
        IFS= read -r process_name < "$process_comm" || true

        [[ $process_name != pacman ]] ||
            die 30 'pacman process is running; wait for it to finish before continuing'
    done
}

verify_network() {
    if ! retry --retryable --idempotent --timeout 20 \
        curl --fail --silent --show-error --output /dev/null \
        --connect-timeout 5 --max-time 15 \
        https://geo.mirror.pkgbuild.com/; then
        die 13 'network probe failed after three attempts; verify connectivity and DNS, then rerun preflight'
    fi
}

verify_clock() {
    local ntp_synchronized

    if ! ntp_synchronized=$(timedatectl show --property=NTPSynchronized --value); then
        die 15 'cannot query clock synchronization; verify system time synchronization and rerun preflight'
    fi

    [[ $ntp_synchronized == yes ]] ||
        die 15 'clock is not synchronized; establish time synchronization and rerun preflight'
}

verify_preflight() {
    (( $# == 0 )) || die 64 'verify_preflight takes no arguments'

    init

    verify_arch_iso
    verify_live_tools
    verify_architecture
    verify_uefi
    verify_pacman_available
    verify_network
    verify_clock

    state_set BOOT_MODE uefi
    log '01-verify preflight passed: Arch ISO, x86_64, UEFI, live tools, pacman, network, and clock verified'
    printf '%s\n' 'Preflight passed.'
}

main() {
    verify_preflight "$@"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
