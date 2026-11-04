#!/usr/bin/env bash
# Unit tests for pure, side-effect-free helpers. No disk, network, or root needed
# except where noted. Run from the repository root: bash tests/unit.sh
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$ROOT_DIR"

# Log to a temporary file so the suite never needs root or write access to /var/log.
ARCH_INSTALL_LOG_FILE=$(mktemp)
export ARCH_INSTALL_LOG_FILE
trap 'rm -f -- "$ARCH_INSTALL_LOG_FILE"' EXIT

# Modules define functions only when sourced, so this is safe.
# shellcheck source=lib/common.sh
source ./lib/common.sh
# shellcheck source=02-config.sh
source ./02-config.sh
# shellcheck source=05-chroot.sh
source ./05-chroot.sh

PASS=0
FAIL=0

check() {
    # check "description" <expected-exit> command...
    local description=$1 expected=$2
    shift 2
    local actual=0
    ( "$@" ) >/dev/null 2>&1 || actual=$?
    if [[ $actual == "$expected" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s (expected exit %s, got %s)\n' "$description" "$expected" "$actual" >&2
    fi
}

test_encoding_roundtrip() {
    local sample decoded
    # Single quotes are intentional: these are literal test values, not expansions.
    # shellcheck disable=SC2016
    for sample in 'plain' 'with space' 'key=value' 'dollar$sign' 'héllo ✓' '$6$salt$hash/./x'; do
        _common_encode_value "$sample"
        _common_decode_value "$_COMMON_STATE_HEX" || { FAIL=$((FAIL + 1)); echo "FAIL: decode failed for '$sample'" >&2; continue; }
        decoded=$REPLY
        if [[ $decoded == "$sample" ]]; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            printf 'FAIL: round-trip mismatch: [%s] -> [%s]\n' "$sample" "$decoded" >&2
        fi
    done
}

test_decode_rejects_bad_input() {
    check 'decode rejects odd-length hex'   1 _common_decode_value 'abc'
    check 'decode rejects non-hex'          1 _common_decode_value 'zz'
    check 'decode rejects NUL byte (00)'    1 _common_decode_value '41004142'
}

test_die_exit_codes() {
    check 'die accepts a documented code'       10 bash -c 'source ./lib/common.sh; die 10 x'
    check 'die normalises an undocumented code' 50 bash -c 'source ./lib/common.sh; die 99 x'
}

test_run_dry_run_contract() {
    local marker
    marker=$(mktemp -u)
    # In dry-run, a --mutating command must be skipped (no side effect).
    # DRY_RUN is set inside a subshell on purpose so it cannot leak into later tests.
    # shellcheck disable=SC2030
    ( export DRY_RUN=1; run --mutating touch "$marker" ) >/dev/null 2>&1 || true
    if [[ -e $marker ]]; then
        FAIL=$((FAIL + 1)); echo 'FAIL: dry-run executed a --mutating command' >&2
        rm -f -- "$marker"
    else
        PASS=$((PASS + 1))
    fi
    # Without DRY_RUN the command must run.
    # shellcheck disable=SC2031
    # DRY_RUN is set in a subshell on purpose; see the dry-run case above.
    # shellcheck disable=SC2030,SC2031
    ( export DRY_RUN=0; run --mutating touch "$marker" ) >/dev/null 2>&1
    if [[ -e $marker ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo 'FAIL: live run skipped command' >&2
    fi
    rm -f -- "$marker"
}

test_retry_argument_validation() {
    check 'retry rejects missing --retryable/--idempotent' 64 bash -c 'source ./lib/common.sh; retry --timeout 5 true'
    check 'retry rejects timeout above 3600'               64 bash -c 'source ./lib/common.sh; retry --retryable --idempotent --timeout 3601 true'
    check 'retry rejects non-numeric timeout'              64 bash -c 'source ./lib/common.sh; retry --retryable --idempotent --timeout abc true'
}

test_timezone_validation() {
    check 'timezone rejects path traversal' 1 config_validate_timezone '../etc/passwd'
    check 'timezone rejects embedded ..'    1 config_validate_timezone 'Europe/../Berlin'
    if [[ -f /usr/share/zoneinfo/UTC ]]; then
        check 'timezone accepts UTC' 0 config_validate_timezone 'UTC'
    else
        echo 'SKIP: tzdata not installed; skipped positive timezone check' >&2
    fi
}

test_account_validation() {
    check 'account accepts lowercase user'      0 config_validate_account 'bob' 'host-1'
    check 'account rejects leading digit'       64 config_validate_account '1bob' 'host-1'
    check 'account rejects 33-char username'    64 config_validate_account 'a2345678901234567890123456789012x' 'host-1'
    check 'account rejects hostname underscore' 64 config_validate_account 'bob' 'bad_host'
}

test_password_hash_validation() {
    if ! command -v openssl >/dev/null 2>&1; then
        echo 'SKIP: openssl missing; skipped hash checks' >&2
        return
    fi
    local good
    good=$(openssl passwd -6 -salt abcdefgh 'correct horse')
    check 'accepts SHA-512 crypt hash'   0 config_validate_password_hash "$good"
    # shellcheck disable=SC2016
    check 'rejects MD5 crypt hash'        1 config_validate_password_hash '$1$abc$0123456789012345678901'
    check 'rejects plaintext'             1 config_validate_password_hash 'hunter2'
}

test_stage_plan() {
    local got
    got=$(source ./install.sh; plan_stages 01 1 | tr '\n' ' ')
    if [[ $got == "01-verify.sh 02-config.sh 03-partition.sh " ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "FAIL: dry-run plan was '$got'" >&2
    fi

    got=$(source ./install.sh; plan_stages 01 0 | wc -l)
    if [[ ${got// /} == 6 ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "FAIL: real-run plan has $got stages, expected 6" >&2
    fi

    got=$(source ./install.sh; plan_stages 04 0 | head -1)
    if [[ $got == 04-pacstrap.sh ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "FAIL: --from 04 started at '$got'" >&2
    fi
}

test_entry_point() {
    check 'install.sh --help exits 0'          0  ./install.sh --help
    check 'install.sh rejects unknown option'  64 ./install.sh --bogus
    check 'install.sh rejects unknown stage'   64 ./install.sh --from 09
    check 'install.sh rejects bad --from arg'  64 ./install.sh --from
}

test_secret_never_written_to_environment() {
    local key found=0
    for key in "${CHROOT_ENV_KEYS[@]}"; do
        [[ $key != PW_HASH ]] || found=1
    done
    if (( found == 0 )); then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo 'FAIL: PW_HASH is listed in the protected environment file keys' >&2
    fi
}

test_payload_receives_hash_on_stdin() {
    local payload
    payload=$(chroot_payload_body)

    if printf '%s\n' "$payload" | bash -n; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo 'FAIL: chroot payload has a syntax error' >&2
    fi

    if grep -q 'IFS= read -r account_secret' <<< "$payload"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo 'FAIL: payload does not read the account secret from stdin' >&2
    fi

    if grep -q 'PW_HASH' <<< "$payload"; then
        FAIL=$((FAIL + 1)); echo 'FAIL: payload still references PW_HASH; the hash must arrive only on stdin' >&2
    else
        PASS=$((PASS + 1))
    fi
}

test_payload_is_shellcheck_clean() {
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo 'SKIP: shellcheck missing; skipped payload lint' >&2
        return
    fi
    local tmp
    tmp=$(mktemp)
    chroot_payload_body > "$tmp"
    if shellcheck -s bash "$tmp" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo 'FAIL: chroot payload has shellcheck findings' >&2
    fi
    rm -f -- "$tmp"
}

test_boot_device_mapping() {
    local cdrom usb ambiguous
    cdrom='{"blockdevices":[{"path":"/dev/sr0","type":"rom","children":[]},{"path":"/dev/sda","type":"disk","children":[{"path":"/dev/sda1","type":"part"}]}]}'
    usb='{"blockdevices":[{"path":"/dev/sdb","type":"disk","children":[{"path":"/dev/sdb1","type":"part"}]},{"path":"/dev/vda","type":"disk"}]}'
    ambiguous='{"blockdevices":[{"path":"/dev/sdc","type":"disk","children":[{"path":"/dev/sdc1","type":"part"}]},{"path":"/dev/sdd","type":"disk","children":[{"path":"/dev/sdc1","type":"part"}]}]}'

    local got
    got=$(lsblk_root_device_for /dev/sr0 <<< "$cdrom" 2>/dev/null) || got=''
    if [[ $got == /dev/sr0 ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo 'FAIL: CD-ROM boot medium not mapped to itself' >&2
    fi

    got=$(lsblk_root_device_for /dev/sdb1 <<< "$usb" 2>/dev/null) || got=''
    if [[ $got == /dev/sdb ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo 'FAIL: USB partition not mapped to parent disk' >&2
    fi

    if lsblk_root_device_for /dev/sdx9 <<< "$usb" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1)); echo 'FAIL: unknown boot source was mapped' >&2
    else
        PASS=$((PASS + 1))
    fi

    if lsblk_root_device_for /dev/sdc1 <<< "$ambiguous" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1)); echo 'FAIL: ambiguous boot source was accepted' >&2
    else
        PASS=$((PASS + 1))
    fi
}

test_country_prompt() {
    CONFIG_COUNTRY=''
    # Invalid entries are rejected and re-asked; a valid one is normalized to upper case.
    config_prompt_country <<< $'1\nUSA\nde' >/dev/null 2>&1
    if [[ $CONFIG_COUNTRY == DE ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "FAIL: country prompt returned '$CONFIG_COUNTRY', expected DE" >&2
    fi
}

test_geo_reply_parsing() {
    local got
    local want

    got=$(config_parse_geo_reply '{"status":"success","countryCode":"de","timezone":"Europe/Berlin"}') || got='<failed>'
    want=$(printf 'DE\tEurope/Berlin')
    if [[ $got == "$want" ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: success reply parsed as '$got'" >&2; fi

    if config_parse_geo_reply '{"status":"fail","message":"reserved range"}' >/dev/null 2>&1; then
        FAIL=$((FAIL + 1)); echo 'FAIL: failed status was accepted' >&2
    else
        PASS=$((PASS + 1))
    fi

    if config_parse_geo_reply 'not json at all' >/dev/null 2>&1; then
        FAIL=$((FAIL + 1)); echo 'FAIL: malformed reply was accepted' >&2
    else
        PASS=$((PASS + 1))
    fi

    got=$(config_parse_geo_reply '{"status":"success","countryCode":"DEU","timezone":"Europe/Berlin"}') || got='<failed>'
    want=$(printf '\tEurope/Berlin')
    if [[ $got == "$want" ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: 3-letter country not rejected: '$got'" >&2; fi
}

test_unattended_geo_lookup_is_opt_in() {
    local tmp
    tmp=$(mktemp -d)
    local marker=$tmp/curl-was-called
    printf '#!/bin/sh\ntouch "%s"\nexit 22\n' "$marker" > "$tmp/curl"
    chmod +x "$tmp/curl"

    # Case 1: unattended, TIMEZONE missing, GEO_LOOKUP unset -> no network call, exit 64.
    local status=0
    PATH="$tmp:$PATH" ROOT_DIR="$ROOT_DIR" bash -c '
        cd "$ROOT_DIR"; source ./lib/common.sh; source ./02-config.sh
        declare -gA CONFIG_ANSWERS=([COUNTRY]=US)
        CONFIG_UNATTENDED=1
        config_detect_country_timezone' >/dev/null 2>&1 || status=$?
    if [[ $status == 64 && ! -e $marker ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "FAIL: unattended run without GEO_LOOKUP contacted the network (exit $status)" >&2
    fi

    # Case 2: unattended with GEO_LOOKUP=1 -> the lookup is attempted, exit 64 (fake curl fails).
    rm -f -- "$marker"
    status=0
    PATH="$tmp:$PATH" ROOT_DIR="$ROOT_DIR" bash -c '
        cd "$ROOT_DIR"; source ./lib/common.sh; source ./02-config.sh
        declare -gA CONFIG_ANSWERS=([COUNTRY]=US [GEO_LOOKUP]=1)
        CONFIG_UNATTENDED=1
        config_detect_country_timezone' >/dev/null 2>&1 || status=$?
    if [[ $status == 64 && -e $marker ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "FAIL: GEO_LOOKUP=1 did not trigger the lookup (exit $status)" >&2
    fi

    rm -rf -- "$tmp"
}

test_live_pacman_sync() {
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/bin" "$tmp/empty" "$tmp/synced"
    printf '#!/bin/sh\necho "$*" >> "%s/calls"\nexit 0\n' "$tmp" > "$tmp/bin/pacman"
    chmod +x "$tmp/bin/pacman"
    touch "$tmp/synced/core.db" "$tmp/synced/extra.db"

    # Databases missing: must run pacman -Sy.
    rm -f -- "$tmp/calls"
    # common.sh is already loaded above; re-sourcing would trip its readonly variables.
    # shellcheck disable=SC2030,SC2031
    ( PATH="$tmp/bin:$PATH"; PACMAN_SYNC_DIR="$tmp/empty"; live_pacman_sync ) >/dev/null 2>&1
    if [[ -f $tmp/calls ]] && grep -q -- '-Sy' "$tmp/calls"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo 'FAIL: missing sync databases did not trigger pacman -Sy' >&2
    fi

    # Databases present: must not touch the network.
    rm -f -- "$tmp/calls"
    # shellcheck disable=SC2030,SC2031
    ( PATH="$tmp/bin:$PATH"; PACMAN_SYNC_DIR="$tmp/synced"; live_pacman_sync ) >/dev/null 2>&1
    if [[ ! -e $tmp/calls ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo 'FAIL: pacman ran even though databases were present' >&2
    fi

    rm -rf -- "$tmp"
}

test_locale_matching() {
    local payload awk_cmd sed_cmd f out st
    payload=$(chroot_payload_body)
    awk_cmd=$(grep -o "awk -v locale=.*/etc/locale.gen" <<< "$payload" | head -1)
    sed_cmd=$(grep -o 'sed -i -E .*/etc/locale.gen' <<< "$payload" | head -1)
    if [[ -z $awk_cmd || -z $sed_cmd ]]; then
        FAIL=$((FAIL + 1)); echo 'FAIL: could not extract locale commands from payload' >&2
        return
    fi
    LOCALE=en_US.UTF-8

    # locale_case <label> <content> <match|reject>
    locale_case() {
        local label=$1 content=$2 expect=$3
        f=$(mktemp); printf '%b' "$content" > "$f"
        st=0; eval "${awk_cmd//\/etc\/locale.gen/$f}" >/dev/null 2>&1 || st=$?
        if [[ $expect == reject ]]; then
            if (( st != 0 )); then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $label wrongly accepted" >&2; fi
        elif (( st != 0 )); then
            FAIL=$((FAIL + 1)); echo "FAIL: $label not matched" >&2
        else
            out="$f.out"; cp "$f" "$out"
            eval "${sed_cmd//\/etc\/locale.gen/$out}" >/dev/null 2>&1
            if grep -qE '^en_US\.UTF-8[[:space:]]+UTF-8[[:space:]]*$' "$out"; then
                PASS=$((PASS + 1))
            else
                FAIL=$((FAIL + 1)); echo "FAIL: $label matched but was not enabled" >&2
            fi
            rm -f -- "$out"
        fi
        rm -f -- "$f"
    }

    locale_case 'clean commented entry'    '#en_US.UTF-8 UTF-8\n#en_US ISO-8859-1\n' match
    locale_case 'trailing space'           '#en_US.UTF-8 UTF-8 \n'                   match
    locale_case 'CRLF line ending'         '#en_US.UTF-8 UTF-8\r\n'                  match
    locale_case 'tab separator'            '#en_US.UTF-8\tUTF-8\n'                   match
    locale_case 'leading whitespace'       '  #en_US.UTF-8 UTF-8\n'                  match
    locale_case 'already enabled entry'    'en_US.UTF-8 UTF-8\n'                     match
    locale_case 'absent locale'            '#de_DE.UTF-8 UTF-8\n'                    reject
    locale_case 'duplicate entries'        '#en_US.UTF-8 UTF-8\n#en_US.UTF-8 UTF-8\n' reject
}

test_hooks_normalization() {
    local fn
    fn=$(chroot_payload_body | sed -n '/^normalize_hooks() {/,/^}/p')
    if [[ -z $fn ]]; then
        FAIL=$((FAIL + 1)); echo 'FAIL: normalize_hooks not found in payload' >&2
        return
    fi
    # Each case runs the extracted function in a subshell, so it cannot leak into the suite.
    hooks_case() {
        local label=$1 want=$2 got st=0
        shift 2
        got=$(eval "$fn"; normalize_hooks "$@") || st=$?
        if [[ $st == 0 && $got == "$want" ]]; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1)); echo "FAIL: $label: got '$got' (status $st)" >&2
        fi
    }
    hooks_case 'classic HOOKS unchanged' \
        'base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck' \
        base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck
    hooks_case 'stock systemd HOOKS' \
        'base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck' \
        base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck
    hooks_case 'systemd without keyboard' \
        'base udev autodetect modconf keyboard keymap consolefont block filesystems fsck' \
        base systemd autodetect modconf sd-vconsole block filesystems fsck
    hooks_case 'systemd with existing keymap' \
        'base udev keyboard keymap block filesystems' \
        base systemd keyboard keymap block filesystems
    hooks_case 'no duplicate base or udev' \
        'base udev keyboard keymap block filesystems' \
        base udev systemd keyboard block filesystems

    # sd-encrypt must be refused: it needs a different kernel command line.
    local st=0
    eval "$fn"; normalize_hooks base systemd sd-encrypt block filesystems >/dev/null || st=$?
    if (( st == 1 )); then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo 'FAIL: sd-encrypt was not refused' >&2; fi
}

test_swap_entry_count() {
    local line tmp f got st
    # The single quotes are intentional: this matches literal source text.
    # shellcheck disable=SC2016
    line=$(grep -m1 'swap_entry_count=$(awk' 06-post.sh)
    if [[ -z $line ]]; then
        FAIL=$((FAIL + 1)); echo 'FAIL: swap entry counter not found in 06-post.sh' >&2
        return
    fi
    # Extract the awk program and run it against a fixture fstab.
    local cmd=${line#*=\$(}
    cmd=${cmd%)*}
    tmp=$(mktemp -d)

    count_case() {
        local label=$1 content=$2 want=$3
        printf '%b' "$content" > "$tmp/fstab"
        got=$(eval "${cmd//\/mnt\/etc\/fstab/$tmp/fstab}") && st=0 || st=$?
        if [[ $st == 0 && $got == "$want" ]]; then PASS=$((PASS + 1))
        else FAIL=$((FAIL + 1)); echo "FAIL: $label: got '$got' (status $st)" >&2; fi
    }
    count_case 'no swap (zram)'   'UUID=x / btrfs rw 0 0\nUUID=y /boot vfat umask=0077 0 2\n' 0
    count_case 'commented swap'   '# UUID=z none swap defaults 0 0\nUUID=x / btrfs rw 0 0\n'     0
    count_case 'one swap entry'   'UUID=s none swap defaults 0 0\nUUID=x / btrfs rw 0 0\n'       1
    count_case 'empty fstab'      ''                                                            0
    rm -rf -- "$tmp"
}

test_vfat_private_options() {
    local opts label want
    while IFS='|' read -r label opts want; do
        if bash -c 'cd "$1" && source ./06-post.sh && post_vfat_options_private "$2"' _ "$ROOT_DIR" "$opts" >/dev/null 2>&1; then
            got=private
        else
            got=public
        fi
        if [[ $got == "$want" ]]; then PASS=$((PASS + 1))
        else FAIL=$((FAIL + 1)); echo "FAIL: $label ('$opts') -> $got, expected $want" >&2; fi
    done <<'CASES'
umask=0077 only|rw,relatime,umask=0077,errors=remount-ro|private
fmask and dmask 0077|rw,fmask=0077,dmask=0077|private
default vfat permissions|rw,relatime,fmask=0022,dmask=0022|public
umask 0022|rw,umask=0022|public
partial fmask only|rw,fmask=0077,dmask=0022|public
substring is not a match|rw,xumask=0077|public
CASES
}

test_ui_behaviour() {
    # Output piped to a file is not a terminal, so no colour codes may appear.
    local out
    out=$(bash -c 'source ./lib/ui.sh; ui_banner; ui_ok done; ui_error_line 20 boom' 2>&1)
    if [[ $out == *$'\033'* ]]; then
        FAIL=$((FAIL + 1)); echo 'FAIL: colour codes appeared in non-terminal output' >&2
    else
        PASS=$((PASS + 1))
    fi

    # NO_COLOR must also be respected on a terminal; checked here via the variable.
    local colour
    colour=$(NO_COLOR=1 bash -c 'source ./lib/ui.sh; printf "%s" "[$UI_RED]"')
    if [[ $colour == '[]' ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: NO_COLOR left colour set: $colour" >&2; fi

    # ui_confirm: empty input takes the default, explicit answers win, invalid input is retried.
    ui_yes() { printf '%s\n' "$1" | bash -c "source ./lib/ui.sh; ui_confirm 'q' $2 >/dev/null 2>&1"; }
    if ui_yes '' y; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo 'FAIL: empty answer ignored default y' >&2; fi
    if ui_yes '' n; then FAIL=$((FAIL + 1)); echo 'FAIL: empty answer ignored default n' >&2; else PASS=$((PASS + 1)); fi
    if ui_yes 'yes' n; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo 'FAIL: explicit yes rejected' >&2; fi
    if ui_yes 'NO' y; then FAIL=$((FAIL + 1)); echo 'FAIL: explicit NO accepted' >&2; else PASS=$((PASS + 1)); fi
    if printf 'maybe\ny\n' | bash -c "source ./lib/ui.sh; ui_confirm q n >/dev/null 2>&1"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo 'FAIL: invalid answer was not retried' >&2
    fi

    # ui_menu: a number selects by position, a name selects by value, invalid input is retried.
    local choice
    choice=$(printf '2\n' | bash -c "source ./lib/ui.sh; ui_menu 1 T alpha beta gamma >/dev/null 2>&1; printf '%s|%s' \"\$UI_CHOICE\" \"\$UI_CHOICE_INDEX\"")
    if [[ $choice == 'beta|1' ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: menu number gave '$choice'" >&2; fi
    choice=$(printf 'gamma\n' | bash -c "source ./lib/ui.sh; ui_menu 1 T alpha beta gamma >/dev/null 2>&1; printf '%s' \"\$UI_CHOICE\"")
    if [[ $choice == gamma ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: menu name gave '$choice'" >&2; fi
    choice=$(printf '9\n0\n1\n' | bash -c "source ./lib/ui.sh; ui_menu 1 T alpha beta >/dev/null 2>&1; printf '%s' \"\$UI_CHOICE\"")
    if [[ $choice == alpha ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: out-of-range input was not retried (got '$choice')" >&2; fi

    # ui_input: an empty answer takes the default.
    local value
    value=$(printf '\n' | bash -c "source ./lib/ui.sh; ui_input L fallback >/dev/null 2>&1; printf '%s' \"\$UI_VALUE\"")
    if [[ $value == fallback ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: ui_input default gave '$value'" >&2; fi

    # Input that ends before an answer must fail with exit 64, never hang or continue.
    local st=0
    printf '' | bash -c "source ./lib/ui.sh; ui_confirm q y" >/dev/null 2>&1 || st=$?
    if [[ $st == 64 ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: end of input gave exit $st, expected 64" >&2; fi
}

test_encoding_roundtrip
test_decode_rejects_bad_input
test_die_exit_codes
test_run_dry_run_contract
test_retry_argument_validation
test_timezone_validation
test_account_validation
test_password_hash_validation
test_entry_point
test_ui_behaviour
test_vfat_private_options
test_swap_entry_count
test_hooks_normalization
test_locale_matching
test_live_pacman_sync
test_unattended_geo_lookup_is_opt_in
test_geo_reply_parsing
test_country_prompt
test_stage_plan
test_boot_device_mapping
test_secret_never_written_to_environment
test_payload_receives_hash_on_stdin
test_payload_is_shellcheck_clean

printf 'unit tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
