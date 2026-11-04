#!/usr/bin/env bash
# Entry point for the Arch Linux installer.
#
# Runs the numbered stages in order. Each stage is its own process and keeps its
# own safety checks; this script only sequences them, reports which one failed,
# and passes the exit status through unchanged.
#
# Usage:
#   sudo ./install.sh [--dry-run] [--from NN]
#   ./install.sh --help
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly -a STAGES=(
    01-verify.sh
    02-config.sh
    03-partition.sh
    04-pacstrap.sh
    05-chroot.sh
    06-post.sh
)
# A dry run cannot go past stage 03: stages 04-06 require a mounted target,
# which a dry run deliberately never creates.
readonly DRY_RUN_LAST_STAGE=03-partition.sh

usage() {
    cat <<'USAGE'
Usage: install.sh [--dry-run] [--from NN]

Install Arch Linux (UEFI, LUKS2, Btrfs, systemd-boot) from the official Arch ISO.
Run as root from the live environment.

Options:
  -n, --dry-run   Validate stages 01-03 without changing disks or the target.
                  Stages 04-06 need a real target, so a dry run stops after 03.
  -f, --from NN   Start at stage NN (01-06) instead of the first stage.
                  Earlier stages must already have completed in this session.
  -h, --help      Show this help and exit.

Stages:
  01  verify       Check the Arch ISO, UEFI, network, and clock.
  02  config       Collect and validate installation settings.
  03  partition    Partition, encrypt, and mount the target disk. DESTRUCTIVE.
  04  pacstrap     Install the base system and write target configuration.
  05  chroot       Configure the target system inside arch-chroot.
  06  post         Validate, clean up, unmount, and offer to reboot.

Exit codes are those of the failing stage. See README.md for the full table.
USAGE
}

die_usage() {
    printf 'ERROR: %s\n\n' "$1" >&2
    usage >&2
    exit 64
}

# Print the stage files to run, one per line, starting at stage NN.
# Honors dry-run by stopping at DRY_RUN_LAST_STAGE.
# Usage: plan_stages NN DRY_RUN(0|1)
plan_stages() {
    local from=$1
    local dry_run=$2
    local stage
    local started=0

    for stage in "${STAGES[@]}"; do
        if (( started == 0 )); then
            [[ ${stage:0:2} == "$from" ]] || continue
            started=1
        fi
        printf '%s\n' "$stage"
        if [[ $dry_run == 1 && $stage == "$DRY_RUN_LAST_STAGE" ]]; then
            break
        fi
    done
}

main() {
    local dry_run=${DRY_RUN:-0}
    local from=01
    local stage
    local status

    while (( $# > 0 )); do
        case $1 in
            -n|--dry-run)
                dry_run=1
                shift
                ;;
            -f|--from)
                (( $# >= 2 )) || die_usage '--from requires a stage number'
                from=$2
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die_usage "unknown argument: $1"
                ;;
        esac
    done

    [[ $dry_run == 0 || $dry_run == 1 ]] ||
        die_usage 'DRY_RUN must be 0 or 1'

    local -a plan
    mapfile -t plan < <(plan_stages "$from" "$dry_run")
    (( ${#plan[@]} > 0 )) ||
        die_usage "no stage numbered '$from' (use 01-06)"

    if (( EUID != 0 )); then
        printf 'ERROR: install.sh must run as root from the Arch ISO; try: sudo %s\n' "$0" >&2
        exit 10
    fi

    export DRY_RUN=$dry_run

    if [[ $dry_run == 1 ]]; then
        printf '%s\n' 'DRY_RUN mode: stages 01-03 validate only; no disk or target changes.'
    else
        printf '%s\n' 'WARNING: stage 03 will ERASE the disk you select. Read the prompts carefully.'
    fi

    for stage in "${plan[@]}"; do
        printf '\n==> Stage %s\n' "${stage%%-*}"

        # Capture the status without tripping set -e, and keep the stage's own
        # exit code so callers and logs see the real failure reason.
        if bash "$SCRIPT_DIR/$stage"; then
            continue
        else
            status=$?
        fi

        printf 'ERROR: installation stopped at %s (exit %s). Fix the cause above, then rerun: sudo ./install.sh --from %s\n' \
            "$stage" "$status" "${stage%%-*}" >&2
        exit "$status"
    done

    if [[ $dry_run == 1 ]]; then
        printf '\n%s\n' 'Dry run passed for stages 01-03. Run without --dry-run to install.'
    else
        printf '\n%s\n' 'All stages completed.'
    fi
}

# Run main only when executed directly, so tests can source plan_stages.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
