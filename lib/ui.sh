# shellcheck shell=bash
# Presentation layer for the installer: colour, status lines, boxes, menus, prompts.
#
# All output goes to stderr, so stdout stays clean for captured values.
# Colour is used only on an interactive terminal. NO_COLOR=1 turns it off.
# Nothing here writes to the installer log, so the log always stays plain text.
#
# This file defines functions and constants only. It is sourced by lib/common.sh
# and by install.sh.

ARCH_INSTALL_VERSION='0.1.0'

if [[ -t 2 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    UI_RESET=$'\033[0m'
    UI_BOLD=$'\033[1m'
    UI_DIM=$'\033[2m'
    UI_RED=$'\033[31m'
    UI_GREEN=$'\033[32m'
    UI_YELLOW=$'\033[33m'
    UI_MAGENTA=$'\033[35m'
    UI_CYAN=$'\033[36m'
else
    UI_RESET=''
    UI_BOLD=''
    UI_DIM=''
    UI_RED=''
    UI_GREEN=''
    UI_YELLOW=''
    UI_MAGENTA=''
    UI_CYAN=''
fi

# Width of the text area inside a box. A full box is UI_BOX_WIDTH + 4 columns wide.
UI_BOX_WIDTH=60

# Results of the most recent prompt. Read these after the call returns.
UI_VALUE=''
UI_CHOICE=''
UI_CHOICE_INDEX=-1

# Print COUNT copies of CHAR. Used for rules, boxes, and progress bars.
_ui_repeat() {
    local char=$1
    local count=$2

    (( count > 0 )) || return 0
    printf '%*s' "$count" '' | tr ' ' "$char"
}

# Fail the way the caller expects: die (exit 64) when the common library is loaded,
# otherwise print the same message and exit 64 directly.
ui_die_input() {
    local message=$1

    # Start on a fresh line: the input may have ended in the middle of a prompt.
    printf '\n' >&2
    if declare -F die >/dev/null; then
        die 64 "$message"
    fi
    printf 'ERROR [64]: %s\n' "$message" >&2
    exit 64
}

# Print one row of a box. The text is padded to the box width.
_ui_box_row() {
    local colour=$1
    local style=$2
    local text=$3

    printf '  %s|%s %s%-*s%s %s|%s\n' \
        "$colour" "$UI_RESET" "$style" "$UI_BOX_WIDTH" "$text" "$UI_RESET" \
        "$colour" "$UI_RESET" >&2
}

_ui_box_border() {
    local colour=$1

    printf '  %s+%s+%s\n' "$colour" "$(_ui_repeat '-' $((UI_BOX_WIDTH + 2)))" "$UI_RESET" >&2
}

# ui_banner: the title block shown when the installer starts.
ui_banner() {
    local colour=$UI_CYAN

    printf '\n' >&2
    _ui_box_border "$colour"
    _ui_box_row "$colour" "$UI_BOLD" "ARCH INSTALL  v${ARCH_INSTALL_VERSION}"
    _ui_box_row "$colour" "$UI_DIM" "UEFI  |  LUKS2 encryption  |  Btrfs  |  systemd-boot"
    _ui_box_border "$colour"
    printf '\n' >&2
}

# ui_box COLOUR TITLE [LINE...]: a titled box. Long lines wrap inside the box.
ui_box() {
    local colour=$1
    local title=$2
    local line
    local wrapped

    shift 2
    printf '\n' >&2
    _ui_box_border "$colour"
    _ui_box_row "$colour" "$UI_BOLD$colour" "$title"
    for line in "$@"; do
        while IFS= read -r wrapped; do
            _ui_box_row "$colour" '' "$wrapped"
        done < <(printf '%s\n' "$line" | fold -s -w "$UI_BOX_WIDTH")
    done
    _ui_box_border "$colour"
    printf '\n' >&2
}

# ui_stage NUMBER TOTAL TITLE: a stage header with a progress bar.
ui_stage() {
    local number=$1
    local total=$2
    local title=$3
    local width=40
    local filled

    filled=$(( number * width / total ))
    printf '\n  %s%sSTAGE %02d/%02d%s  %s%s%s\n' \
        "$UI_CYAN" "$UI_BOLD" "$number" "$total" "$UI_RESET" "$UI_BOLD" "$title" "$UI_RESET" >&2
    printf '  %s[%s%s%s%s]%s\n' \
        "$UI_DIM" "$UI_CYAN" "$(_ui_repeat '#' "$filled")" "$UI_DIM" \
        "$(_ui_repeat '.' $((width - filled)))" "$UI_RESET" >&2
}

ui_step() {
    printf '  %s>%s %s\n' "$UI_CYAN$UI_BOLD" "$UI_RESET" "$*" >&2
}

ui_ok() {
    printf '  %s[ OK ]%s %s\n' "$UI_GREEN$UI_BOLD" "$UI_RESET" "$*" >&2
}

ui_info() {
    printf '  %s[ .. ]%s %s\n' "$UI_DIM" "$UI_RESET" "$*" >&2
}

ui_warn_line() {
    printf '  %s[ !! ]%s %s\n' "$UI_YELLOW$UI_BOLD" "$UI_RESET" "$*" >&2
}

# ui_error_line CODE MESSAGE: the failure line. Keeps the "ERROR [NN]:" form the docs use.
ui_error_line() {
    printf '  %s[FAIL]%s ERROR [%s]: %s\n' "$UI_RED$UI_BOLD" "$UI_RESET" "$1" "$2" >&2
}

# ui_confirm QUESTION [y|n]: yes/no question. The optional second argument is the
# default, used when the answer is empty. Returns 0 for yes and 1 for no.
ui_confirm() {
    local question=$1
    local default=${2:-n}
    local answer
    local hint

    if [[ $default == y ]]; then
        hint='Y/n'
    else
        hint='y/N'
    fi

    while true; do
        printf '  %s?%s %s %s[%s]%s ' \
            "$UI_MAGENTA$UI_BOLD" "$UI_RESET" "$question" "$UI_DIM" "$hint" "$UI_RESET" >&2
        IFS= read -r answer || ui_die_input "input ended while waiting for: $question"
        answer=${answer,,}
        case $answer in
            '')
                if [[ $default == y ]]; then
                    return 0
                fi
                return 1
                ;;
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) ui_warn_line 'please answer y or n' ;;
        esac
    done
}

# ui_input LABEL [DEFAULT]: free-text prompt. The answer is in UI_VALUE.
# An empty answer takes DEFAULT, if one was given.
ui_input() {
    local label=$1
    local default=${2-}
    local answer

    if [[ -n $default ]]; then
        printf '  %s?%s %s %s[%s]%s: ' \
            "$UI_MAGENTA$UI_BOLD" "$UI_RESET" "$label" "$UI_DIM" "$default" "$UI_RESET" >&2
    else
        printf '  %s?%s %s: ' "$UI_MAGENTA$UI_BOLD" "$UI_RESET" "$label" >&2
    fi
    IFS= read -r answer || ui_die_input "input ended while waiting for: $label"
    UI_VALUE=${answer:-$default}
}

# ui_secret LABEL: silent prompt, for passwords. The answer is in UI_VALUE.
ui_secret() {
    local label=$1
    local answer

    printf '  %s?%s %s: ' "$UI_MAGENTA$UI_BOLD" "$UI_RESET" "$label" >&2
    if ! IFS= read -r -s answer; then
        printf '\n' >&2
        ui_die_input "input ended while waiting for: $label"
    fi
    printf '\n' >&2
    # Return value: read by the caller after this function returns.
    # shellcheck disable=SC2034
    UI_VALUE=$answer
}

# ui_menu COLUMNS TITLE ITEM...: a numbered menu. The user types a number or a name.
# The choice is in UI_CHOICE, and its zero-based position is in UI_CHOICE_INDEX.
ui_menu() {
    local columns=$1
    local title=$2
    local -a items
    local count
    local answer
    local cell_width=20
    local i

    shift 2
    items=("$@")
    count=${#items[@]}
    if (( count == 0 )); then
        ui_die_input "menu '$title' has no choices"
    fi

    printf '\n  %s%s%s\n' "$UI_BOLD" "$title" "$UI_RESET" >&2
    for (( i = 0; i < count; i++ )); do
        if (( columns == 1 )); then
            printf '    %s%3d)%s %s\n' "$UI_CYAN" $((i + 1)) "$UI_RESET" "${items[i]}" >&2
        else
            printf '    %s%3d)%s %-*s' "$UI_CYAN" $((i + 1)) "$UI_RESET" "$cell_width" "${items[i]}" >&2
            if (( (i + 1) % columns == 0 )); then
                printf '\n' >&2
            fi
        fi
    done
    if (( columns > 1 && count % columns != 0 )); then
        printf '\n' >&2
    fi
    printf '\n' >&2

    while true; do
        printf '  %s?%s Choose a number, or type a name: ' "$UI_MAGENTA$UI_BOLD" "$UI_RESET" >&2
        IFS= read -r answer || ui_die_input "input ended while waiting for a choice in: $title"

        if [[ $answer =~ ^[0-9]+$ ]] && (( 10#$answer >= 1 && 10#$answer <= count )); then
            UI_CHOICE_INDEX=$(( 10#$answer - 1 ))
            # Return values: read by the caller after this function returns.
            # shellcheck disable=SC2034
            UI_CHOICE=${items[UI_CHOICE_INDEX]}
            return 0
        fi

        for (( i = 0; i < count; i++ )); do
            if [[ $answer == "${items[i]}" ]]; then
                UI_CHOICE_INDEX=$i
                # shellcheck disable=SC2034
                UI_CHOICE=${items[i]}
                return 0
            fi
        done

        ui_warn_line "'$answer' is not a listed choice; try again"
    done
}
