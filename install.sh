#!/usr/bin/env bash
# Entry point for the Arch Linux installer.
#
# Runs the numbered stages in order. Each stage is its own process and keeps its
# own safety checks; this script only sequences them, shows progress, reports which
# one failed, and passes the exit status through unchanged.
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

# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"

stage_title() {
    case $1 in
        01) printf '%s' 'Preflight checks' ;;
        02) printf '%s' 'Configuration' ;;
        03) printf '%s' 'Disk preparation (erases the target disk)' ;;
        04) printf '%s' 'Base system installation' ;;
        05) printf '%s' 'System configuration' ;;
        06) printf '%s' 'Finalization' ;;
        *) printf '%s' 'Unknown stage' ;;
    esac
}

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
  01  Preflight checks       Check the Arch ISO, UEFI, network, and clock.
  02  Configuration          Collect and validate installation settings.
  03  Disk preparation       Partition, encrypt, and mount the target. DESTRUCTIVE.
  04  Base system           Install the base system and write target configuration.
  05  System configuration   Configure the target inside arch-chroot.
  06  Finalization           Validate, clean up, unmount, and offer to reboot.

Exit codes are those of the failing stage. See README.md for the full table.

Set NO_COLOR=1 to turn off colour output.
USAGE
}

die_usage() {
    ui_error_line 64 "$1"
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
    local number
    local total=${#STAGES[@]}
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

    ui_banner

    if (( EUID != 0 )); then
        ui_error_line 10 'install.sh must run as root from the Arch ISO'
        ui_step "Try: sudo $0"
        exit 10
    fi

    export DRY_RUN=$dry_run

    if [[ $dry_run == 1 ]]; then
        ui_box "$UI_CYAN" 'DRY RUN' \
            'Stages 01-03 are validated. Nothing on disk or in the target is changed.' \
            'Stages 04-06 need a real target, so the dry run ends after stage 03.'
    else
        ui_box "$UI_YELLOW" 'BEFORE YOU START' \
            'Stage 03 ERASES the disk you select. Read every prompt carefully.' \
            'Stage 02 asks for the disk, your account, and the keyboard layout.'
    fi

    for stage in "${plan[@]}"; do
        number=${stage%%-*}

        ui_stage "$((10#$number))" "$total" "$(stage_title "$number")"

        # Capture the status without tripping set -e, and keep the stage's own
        # exit code so callers and logs see the real failure reason.
        if bash "$SCRIPT_DIR/$stage"; then
            ui_ok "Stage $number complete"
        else
            status=$?
            ui_step "Stage $number exited with code $status"
            ui_box "$UI_RED" 'INSTALLATION STOPPED' \
                "Fix the cause shown above, then resume from this stage." \
                "Resume with: sudo ./install.sh --from $number"
            exit "$status"
        fi
    done

    if [[ $dry_run == 1 ]]; then
        ui_box "$UI_GREEN" 'DRY RUN PASSED' \
            'Stages 01-03 validated. Run without --dry-run to install.'
    fi
}

# Run main only when executed directly, so tests can source plan_stages.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
