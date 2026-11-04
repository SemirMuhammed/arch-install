#!/usr/bin/env bash
set -Eeuo pipefail

# Shared library for the Arch installer. Sourcing defines functions only.
# Overridable only so the unit tests can log to a temporary file. The installer always
# uses the default path, and the value must be an absolute path.
readonly LOG_FILE=${ARCH_INSTALL_LOG_FILE:-/var/log/arch-install.log}

# Presentation layer: colour, status lines, boxes, menus, and prompts.
# shellcheck source=lib/ui.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/ui.sh"
readonly STATE_FILE='/tmp/arch-install/state.env'
readonly STATE_LOCK="${STATE_FILE}.lock"

_COMMON_INITIALIZED=0
_COMMON_DIE_ACTIVE=0
_COMMON_STATE_TEMP=''
_COMMON_STATE_LOCK_HELD=0
_COMMON_STATE_HEX=''
declare -gA _COMMON_STATE=()

readonly -a _COMMON_STATE_KEYS=(
    BOOT_MODE DISK FS KEYMAP LOCALE TIMEZONE USERNAME HOSTNAME PW_HASH
    MOUNT_OPTIONS ESP_PART ROOT_PART ROOT_DEV ESP_UUID LUKS_UUID
    COUNTRY ENCRYPTION
)

_common_state_key_allowed() {
    local candidate=$1
    local key

    for key in "${_COMMON_STATE_KEYS[@]}"; do
        [[ $candidate == "$key" ]] && return 0
    done

    return 1
}

_common_internal_run() {
    # Internal metadata writes must persist even when DRY_RUN=1.
    run --internal-mutating "$@"
}

_common_write_log() {
    local level=$1
    shift

    local timestamp
    printf -v timestamp '%(%Y-%m-%dT%H:%M:%S%z)T' -1

    printf '[%s] [%s] %s\n' "$timestamp" "$level" "$*" |
        _common_internal_run tee -a -- "$LOG_FILE" >/dev/null
}

log() {
    if ! _common_write_log INFO "$@"; then
        printf 'ERROR: cannot write installer log: %s\n' "$LOG_FILE" >&2
        return 50
    fi
}

warn() {
    if ! _common_write_log WARN "$@"; then
        printf 'ERROR: cannot write installer log: %s\n' "$LOG_FILE" >&2
        return 50
    fi

    ui_warn_line "$*"
}

_common_cleanup_state_update() {
    if [[ -n ${_COMMON_STATE_TEMP:-} ]]; then
        _common_internal_run rm -f -- "$_COMMON_STATE_TEMP" || true
        _COMMON_STATE_TEMP=''
    fi

    if (( ${_COMMON_STATE_LOCK_HELD:-0} == 1 )); then
        _common_internal_run rmdir -- "$STATE_LOCK" 2>/dev/null || true
        _COMMON_STATE_LOCK_HELD=0
    fi
}

die() {
    local code=${1-50}
    shift || true
    local message=$*

    if [[ ! $code =~ ^(10|11|12|13|14|15|20|21|22|23|30|31|40|41|50|64|130)$ ]]; then
        code=50
        message="invalid die exit code; ${message}"
    fi

    _COMMON_DIE_ACTIVE=1
    _common_cleanup_state_update

    if ! _common_write_log ERROR "exit=$code $message"; then
        printf 'ERROR: logging failed; original error: %s\n' "$message" >&2
    fi

    ui_error_line "$code" "$message"
    exit "$code"
}

_common_err_trap() {
    local status=$1
    local line=$2

    (( _COMMON_DIE_ACTIVE == 1 )) && return 0

    _COMMON_DIE_ACTIVE=1
    _common_cleanup_state_update

    if ! _common_write_log ERROR "unhandled command failure: status=$status line=$line"; then
        printf 'ERROR: logging failed\n' >&2
    fi

    ui_error_line 50 "command failed at line $line (status $status)"
    exit 50
}

_common_signal_trap() {
    local signal=$1

    _COMMON_DIE_ACTIVE=1
    _common_cleanup_state_update

    if ! _common_write_log ERROR "interrupted by signal $signal"; then
        printf 'ERROR: logging failed during interruption\n' >&2
    fi

    ui_error_line 130 "interrupted by signal $signal"
    exit 130
}

init() {
    (( EUID == 0 )) || die 10 'init requires root; rerun from the Arch ISO as root'

    [[ ${DRY_RUN:-0} == 0 || ${DRY_RUN:-0} == 1 ]] ||
        die 64 'DRY_RUN must be 0 or 1'

    if (( _COMMON_INITIALIZED == 1 )); then
        return 0
    fi

    local log_dir
    local dir_owner
    local dir_mode
    local log_owner

    log_dir=$(dirname -- "$LOG_FILE")
    [[ ! -L $log_dir ]] ||
        die 50 "log directory must not be a symlink: $log_dir"

    _common_internal_run mkdir -p -- "$log_dir" ||
        die 50 "cannot create log directory: $log_dir"

    [[ -d $log_dir ]] ||
        die 50 "log path parent is not a directory: $log_dir"

    dir_owner=$(stat -c '%u' -- "$log_dir") ||
        die 50 "cannot inspect log-directory owner: $log_dir"
    dir_mode=$(stat -c '%a' -- "$log_dir") ||
        die 50 "cannot inspect log-directory permissions: $log_dir"

    [[ $dir_owner == 0 ]] ||
        die 50 "log directory must be root-owned: $log_dir"

    if [[ ! $dir_mode =~ ^[0-7]{3,4}$ ]]; then
        die 50 "cannot validate log-directory permissions: $log_dir"
    fi
    if (( (8#$dir_mode & 0022) != 0 )); then
        die 50 "log directory must not be group/world writable: $log_dir"
    fi

    [[ ! -L $LOG_FILE ]] ||
        die 50 "log file must not be a symlink: $LOG_FILE"

    if [[ ! -e $LOG_FILE ]]; then
        _common_internal_run install -m 600 /dev/null "$LOG_FILE" ||
            die 50 "cannot create log file: $LOG_FILE"
    fi

    [[ -f $LOG_FILE ]] ||
        die 50 "log path is not a regular file: $LOG_FILE"

    log_owner=$(stat -c '%u' -- "$LOG_FILE") ||
        die 50 "cannot inspect log-file owner: $LOG_FILE"

    [[ $log_owner == 0 ]] ||
        die 50 "log file must be root-owned: $LOG_FILE"

    _common_internal_run chmod 600 -- "$LOG_FILE" ||
        die 50 "cannot secure log file: $LOG_FILE"

    trap '_common_err_trap "$?" "${BASH_LINENO[0]:-$LINENO}"' ERR
    trap '_common_signal_trap INT' INT
    trap '_common_signal_trap TERM' TERM

    _COMMON_INITIALIZED=1
    log 'common library initialized'
}

# The live ISO ships without synchronized package databases, so "pacman -S" fails
# with "database file does not exist". Sync core and extra once per session before
# installing anything. Only the databases are refreshed, not installed packages.
# This does not touch the target disk, so it is allowed during DRY_RUN.
PACMAN_SYNC_DIR=${PACMAN_SYNC_DIR:-/var/lib/pacman/sync}

live_pacman_sync() {
    [[ -f $PACMAN_SYNC_DIR/core.db && -f $PACMAN_SYNC_DIR/extra.db ]] && return 0

    retry --retryable --idempotent --timeout 300 \
        pacman -Sy --noconfirm ||
        die 31 'cannot synchronize pacman package databases; verify network and mirrors and rerun'
}

# jq is not part of the official Arch ISO. Install it on demand into the live
# environment only; this touches neither the target disk nor /mnt, so it is
# deliberately allowed during DRY_RUN.
ensure_live_jq() {
    command -v jq >/dev/null 2>&1 && return 0

    live_pacman_sync
    retry --retryable --idempotent --timeout 300 \
        pacman -S --needed --noconfirm jq ||
        die 14 'jq is required and could not be installed into the live environment; verify network and mirrors and rerun'

    command -v jq >/dev/null 2>&1 ||
        die 14 'jq install reported success but jq is still missing; inspect the live environment'
}

# Read lsblk JSON on stdin and print the single top-level block device that
# contains the device named by $1 (the Arch ISO boot source). The root may be
# any type: a virtual or physical CD-ROM (rom), a USB disk (disk), or a loop device.
lsblk_root_device_for() {
    local source=$1

    # jq variables are supplied with --arg and intentionally remain literal to Bash.
    # shellcheck disable=SC2016
    jq -er --arg source "$source" '
        [.blockdevices[]? | select(any(.. | objects; .path == $source))] as $roots
        | if ($roots | length) != 1 then
            error("boot source must map to exactly one top-level block device")
          else
            $roots[0].path
          end
    '
}

run() {
    local mutating=0
    local internal_mutation=0

    while [[ ${1-} == --mutating || ${1-} == --internal-mutating ]]; do
        case $1 in
            --mutating) mutating=1 ;;
            --internal-mutating) internal_mutation=1 ;;
        esac
        shift
    done

    (( $# > 0 )) || die 64 'run requires a command and arguments'

    (( mutating == 0 || internal_mutation == 0 )) ||
        die 64 'run cannot combine --mutating and --internal-mutating'

    if (( internal_mutation == 0 )); then
        [[ ${DRY_RUN:-0} == 0 || ${DRY_RUN:-0} == 1 ]] ||
            die 64 'DRY_RUN must be 0 or 1'
    fi

    if (( mutating == 1 )) && [[ ${DRY_RUN:-0} == 1 ]]; then
        log "DRY_RUN: skipped mutating command: $1"
        return 0
    fi

    "$@"
}

retry() {
    local retryable=0
    local idempotent=0
    local mutating=0
    local timeout_seconds=''
    local attempt
    local status=1

    while (( $# > 0 )); do
        case $1 in
            --retryable) retryable=1; shift ;;
            --idempotent) idempotent=1; shift ;;
            --mutating) mutating=1; shift ;;
            --timeout)
                (( $# >= 2 )) || die 64 'retry --timeout requires seconds'
                timeout_seconds=$2
                shift 2
                ;;
            *) break ;;
        esac
    done

    (( retryable == 1 && idempotent == 1 )) ||
        die 64 'retry requires --retryable and --idempotent'

    [[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] ||
        die 64 'retry requires a positive integer --timeout'

    if (( ${#timeout_seconds} > 4 )); then
        die 64 'retry timeout must not exceed 3600 seconds'
    fi
    if (( timeout_seconds > 3600 )); then
        die 64 'retry timeout must not exceed 3600 seconds'
    fi

    (( $# > 0 )) || die 64 'retry requires a command and arguments'

    command -v timeout >/dev/null 2>&1 ||
        die 14 'required command is missing: timeout; boot with the standard Arch ISO tools'

    for attempt in 1 2 3; do
        if (( mutating == 1 )); then
            if run --mutating timeout --signal=TERM --kill-after=5 \
                "$timeout_seconds" "$@"; then
                return 0
            else
                status=$?
            fi
        else
            if run timeout --signal=TERM --kill-after=5 \
                "$timeout_seconds" "$@"; then
                return 0
            else
                status=$?
            fi
        fi

        if (( attempt < 3 )); then
            warn "retryable command failed (attempt $attempt/3, status $status): $1"
            sleep 2
        else
            warn "retryable command failed after 3 attempts (status $status): $1"
            return "$status"
        fi
    done

    return "$status"
}

require_cmd() {
    (( $# > 0 )) || die 64 'require_cmd needs at least one command'

    local command_name
    for command_name in "$@"; do
        command -v -- "$command_name" >/dev/null 2>&1 ||
            die 14 "required command is missing: $command_name; install or boot with the required Arch ISO tools"
    done
}

require_mount() {
    (( $# == 1 )) || die 64 'require_mount requires exactly one mountpoint'

    command -v findmnt >/dev/null 2>&1 ||
        die 14 'required command is missing: findmnt; boot with the standard Arch ISO tools'

    findmnt -rn -M "$1" >/dev/null 2>&1 ||
        die 22 "required mountpoint is not mounted: $1"
}

_common_encode_value() {
    local value=$1
    local character
    local byte
    local piece
    local encoded=''
    local index
    local LC_ALL=C

    for (( index = 0; index < ${#value}; index++ )); do
        character=${value:index:1}
        printf -v byte '%d' "'$character"
        printf -v piece '%02x' "$byte"
        encoded+=$piece
    done

    _COMMON_STATE_HEX=$encoded
}

_common_decode_value() {
    local encoded=$1
    local decoded=''
    local pair
    local index

    [[ $encoded =~ ^([[:xdigit:]]{2})*$ ]] || return 1

    for (( index = 0; index < ${#encoded}; index += 2 )); do
        pair=${encoded:index:2}
        [[ $pair != 00 ]] || return 1
        printf -v decoded '%s%b' "$decoded" "\\x$pair"
    done

    REPLY=$decoded
}

_common_prepare_state_dir() {
    local state_dir
    local owner

    state_dir=$(dirname -- "$STATE_FILE")
    [[ ! -L $state_dir ]] ||
        die 64 "state directory must not be a symlink: $state_dir"

    _common_internal_run mkdir -m 700 -p -- "$state_dir" ||
        die 50 "cannot create state directory: $state_dir"

    [[ -d $state_dir ]] ||
        die 64 "state path parent is not a directory: $state_dir"

    owner=$(stat -c '%u' -- "$state_dir") ||
        die 50 "cannot inspect state-directory owner: $state_dir"

    [[ $owner == 0 ]] ||
        die 64 "state directory must be root-owned: $state_dir"

    _common_internal_run chmod 700 -- "$state_dir" ||
        die 50 "cannot secure state directory: $state_dir"
}

_common_read_state() {
    local line
    local key
    local encoded
    local state_owner
    local state_mode

    _common_prepare_state_dir
    _COMMON_STATE=()

    [[ -e $STATE_FILE || -L $STATE_FILE ]] || return 0

    [[ ! -L $STATE_FILE && -f $STATE_FILE ]] ||
        die 64 "state path is not a regular non-symlink file: $STATE_FILE"

    state_owner=$(stat -c '%u' -- "$STATE_FILE") ||
        die 64 "cannot inspect state-file owner: $STATE_FILE"
    state_mode=$(stat -c '%a' -- "$STATE_FILE") ||
        die 64 "cannot inspect state-file permissions: $STATE_FILE"

    [[ $state_owner == 0 && $state_mode == 600 ]] ||
        die 64 "state file must be root-owned with mode 600: $STATE_FILE"

    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *=* ]] ||
            die 64 'malformed state-file line; expected KEY=HEX'

        key=${line%%=*}
        encoded=${line#*=}

        _common_state_key_allowed "$key" ||
            die 64 "unknown state key: $key"

        [[ ! ${_COMMON_STATE[$key]+present} ]] ||
            die 64 "duplicate state key: $key"

        _common_decode_value "$encoded" ||
            die 64 "invalid hex encoding for state key: $key"

        _COMMON_STATE["$key"]=$REPLY
    done < "$STATE_FILE"
}

state_load() {
    local key

    _common_read_state

    for key in "${!_COMMON_STATE[@]}"; do
        export "$key=${_COMMON_STATE[$key]}"
    done
}

state_set() {
    (( $# == 2 )) || die 64 'state_set requires KEY VALUE'
    state_set_many "$@"
}

state_set_many() {
    (( $# >= 2 && $# % 2 == 0 )) ||
        die 64 'state_set_many requires one or more KEY VALUE pairs'

    local key
    local value
    local attempt
    local existing_key
    local temp_owner
    local -A updates=()
    local -A encoded_updates=()

    # Validate every key, reject duplicates, and verify every value round-trips
    # through the existing hex encoding before acquiring the lock or writing.
    while (( $# > 0 )); do
        key=$1
        value=$2
        shift 2

        _common_state_key_allowed "$key" ||
            die 64 "state_set_many rejected unknown key: $key"

        [[ ! ${updates[$key]+present} ]] ||
            die 64 "state_set_many received duplicate key: $key"

        updates["$key"]=$value

        _common_encode_value "$value"
        [[ $_COMMON_STATE_HEX =~ ^([[:xdigit:]]{2})*$ ]] ||
            die 64 "state_set_many could not encode value for key: $key"

        _common_decode_value "$_COMMON_STATE_HEX" ||
            die 64 "state_set_many could not validate value for key: $key"

        [[ $REPLY == "$value" ]] ||
            die 64 "state_set_many value failed encoding round-trip for key: $key"

        encoded_updates["$key"]=$_COMMON_STATE_HEX
    done

    _common_prepare_state_dir

    [[ ! -L $STATE_LOCK ]] ||
        die 50 "state lock path must not be a symlink: $STATE_LOCK"

    # Acquire the shared state lock once for the complete batch.
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if _common_internal_run mkdir -m 700 -- "$STATE_LOCK" 2>/dev/null; then
            _COMMON_STATE_LOCK_HELD=1
            break
        fi
        sleep 1
    done

    (( _COMMON_STATE_LOCK_HELD == 1 )) ||
        die 50 "cannot acquire state lock after 10 seconds: $STATE_LOCK"

    # Existing state is fully validated before any replacement is attempted.
    _common_read_state

    for key in "${!updates[@]}"; do
        _COMMON_STATE["$key"]=${updates[$key]}
    done

    _COMMON_STATE_TEMP=$(_common_internal_run mktemp \
        "${STATE_FILE}.tmp.XXXXXXXX") ||
        die 50 'cannot create temporary state file'

    temp_owner=$(stat -c '%u' -- "$_COMMON_STATE_TEMP") ||
        die 50 'cannot inspect temporary state-file owner'

    [[ $temp_owner == 0 ]] ||
        die 50 'temporary state file is not root-owned'

    _common_internal_run chown 0:0 -- "$_COMMON_STATE_TEMP" ||
        die 50 'cannot set temporary state-file ownership'

    _common_internal_run chmod 600 -- "$_COMMON_STATE_TEMP" ||
        die 50 'cannot secure temporary state file'

    # Write the complete merged state once, retaining unrelated keys.
    for existing_key in "${_COMMON_STATE_KEYS[@]}"; do
        if [[ ${_COMMON_STATE[$existing_key]+present} ]]; then
            if [[ ${encoded_updates[$existing_key]+present} ]]; then
                _COMMON_STATE_HEX=${encoded_updates[$existing_key]}
            else
                _common_encode_value "${_COMMON_STATE[$existing_key]}"
            fi

            printf '%s=%s\n' "$existing_key" "$_COMMON_STATE_HEX" |
                _common_internal_run tee -a -- "$_COMMON_STATE_TEMP" >/dev/null ||
                die 50 'cannot write temporary state file'
        fi
    done

    _common_internal_run chmod 600 -- "$_COMMON_STATE_TEMP" ||
        die 50 'cannot secure completed temporary state file'

    # Same-directory rename is the single commit point.
    _common_internal_run mv -f -- "$_COMMON_STATE_TEMP" "$STATE_FILE" ||
        die 50 "cannot atomically replace state file: $STATE_FILE"

    _COMMON_STATE_TEMP=''

    # Commit has succeeded; lock cleanup failure must not report the committed
    # update as failed. Leave the held flag set so trap cleanup can retry.
    if _common_internal_run rmdir -- "$STATE_LOCK"; then
        _COMMON_STATE_LOCK_HELD=0
    else
        ui_warn_line "state updated, but lock cleanup failed: $STATE_LOCK"
    fi
}
