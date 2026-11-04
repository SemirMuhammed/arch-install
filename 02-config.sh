#!/usr/bin/env bash
set -Eeuo pipefail

if ! declare -F init >/dev/null 2>&1; then
    if [[ ${BASH_SOURCE[0]} == */* ]]; then
        _CONFIG_MODULE_DIR=${BASH_SOURCE[0]%/*}
    else
        _CONFIG_MODULE_DIR=.
    fi
    # shellcheck source=lib/common.sh
    source "$_CONFIG_MODULE_DIR/lib/common.sh"
    unset _CONFIG_MODULE_DIR
fi

declare -gA CONFIG_ANSWERS=()
declare -ga CONFIG_DISK_PATHS=()
declare -ga CONFIG_DISK_LABELS=()
declare -g CONFIG_UNATTENDED=0
declare -g CONFIG_LSBLK_JSON=''
declare -g CONFIG_BOOT_DISK=''
declare -g CONFIG_DISK=''
declare -g CONFIG_COUNTRY=''
declare -g CONFIG_TIMEZONE=''
declare -g CONFIG_USERNAME=''
declare -g CONFIG_HOSTNAME=''
declare -g CONFIG_PW_HASH=''
declare -g CONFIG_KEYMAP=''
declare -g CONFIG_LOCALE=''
declare -g CONFIG_FS=''
declare -g CONFIG_ENCRYPTION=''
declare -g CONFIG_MOUNT_OPTIONS=''
declare -ga CONFIG_KEYMAPS=(
    us by ca cf cz de dk es et fa 'fi' fr gr hu il it lt lv mk nl no pl ro ru se sg si tr ua uk
)
declare -gA CONFIG_KEYMAP_LOCALES=(
    [us]=en_US.UTF-8 [uk]=en_GB.UTF-8 [ca]=en_CA.UTF-8
    [cf]=fr_CA.UTF-8 [by]=be_BY.UTF-8 [cz]=cs_CZ.UTF-8
    [de]=de_DE.UTF-8 [dk]=da_DK.UTF-8 [es]=es_ES.UTF-8
    [et]=et_EE.UTF-8 [fa]=fa_IR.UTF-8 [fi]=fi_FI.UTF-8
    [fr]=fr_FR.UTF-8 [gr]=el_GR.UTF-8 [hu]=hu_HU.UTF-8
    [il]=he_IL.UTF-8 [it]=it_IT.UTF-8 [lt]=lt_LT.UTF-8
    [lv]=lv_LV.UTF-8 [mk]=mk_MK.UTF-8 [nl]=nl_NL.UTF-8
    [no]=nb_NO.UTF-8 [pl]=pl_PL.UTF-8 [ro]=ro_RO.UTF-8
    [ru]=ru_RU.UTF-8 [se]=sv_SE.UTF-8 [sg]=de_CH.UTF-8
    [si]=sl_SI.UTF-8 [tr]=tr_TR.UTF-8 [ua]=uk_UA.UTF-8
)

config_answer_key_allowed() {
    case $1 in
        DISK|CONFIRM_DISK|COUNTRY|TIMEZONE|GEO_LOOKUP|KEYMAP|LOCALE|USERNAME|HOSTNAME|PW_HASH)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

config_load_answers() {
    local answers_file=/root/arch-install.answers
    local owner
    local mode
    local line
    local key
    local value
    local required_key

    CONFIG_ANSWERS=()
    CONFIG_UNATTENDED=0

    if [[ ! -e $answers_file && ! -L $answers_file ]]; then
        return 0
    fi

    [[ ! -L $answers_file && -f $answers_file ]] ||
        die 64 'answers file must be a regular non-symlink file: /root/arch-install.answers'

    owner=$(stat -c '%u' -- "$answers_file") ||
        die 64 'cannot inspect answers-file owner; secure /root/arch-install.answers and retry'
    mode=$(stat -c '%a' -- "$answers_file") ||
        die 64 'cannot inspect answers-file permissions; secure /root/arch-install.answers and retry'

    [[ $owner == 0 && $mode == 600 ]] ||
        die 64 'answers file must be root-owned with mode 600; run chown root and chmod 600 on /root/arch-install.answers'

    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *=* && $line != *$'\r'* ]] ||
            die 64 'malformed answers-file line; use strict KEY=VALUE records with no comments or blank lines'

        key=${line%%=*}
        value=${line#*=}
        [[ $value != *'='* && -n $value ]] ||
            die 64 "malformed answers-file value for key '$key'; use one non-empty value without '='"
        [[ $key =~ ^[A-Z_]+$ ]] ||
            die 64 'malformed answers-file key; use uppercase KEY=VALUE records'
        config_answer_key_allowed "$key" ||
            die 64 "unknown answers-file key '$key'; remove it and use only documented configuration keys"
        [[ ! ${CONFIG_ANSWERS[$key]+present} ]] ||
            die 64 "duplicate answers-file key '$key'; keep exactly one assignment"

        CONFIG_ANSWERS["$key"]=$value
    done < "$answers_file"

    for required_key in DISK CONFIRM_DISK KEYMAP LOCALE USERNAME HOSTNAME PW_HASH; do
        [[ ${CONFIG_ANSWERS[$required_key]+present} ]] ||
            die 64 "answers file is missing required key '$required_key'; add it and rerun"
    done

    CONFIG_UNATTENDED=1
}

config_validate_timezone() {
    local timezone=$1

    [[ $timezone =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+.-]+)*$ ]] || return 1
    [[ $timezone != *..* ]] || return 1
    [[ -f "/usr/share/zoneinfo/$timezone" ]]
}

# Read an ip-api.com JSON reply on $1 and print "COUNTRY<TAB>TIMEZONE" on success.
# Returns 1 for failed or malformed replies. Values are validated again before use.
config_parse_geo_reply() {
    local reply=$1
    local status
    local country
    local timezone

    status=$(jq -er '.status | strings' <<< "$reply" 2>/dev/null) || return 1
    [[ $status == success ]] || return 1

    country=$(jq -er '.countryCode | strings | select(test("^[A-Za-z]{2}$")) | ascii_upcase' <<< "$reply" 2>/dev/null) || country=''
    timezone=$(jq -er '.timezone | strings | select(length > 0)' <<< "$reply" 2>/dev/null) || timezone=''

    printf '%s\t%s\n' "$country" "$timezone"
}

# Ask for a two-letter ISO 3166-1 country code until a valid one is entered.
config_prompt_country() {
    local answer

    while true; do
        ui_input 'Country code (two letters, e.g. US, DE, GB)'
        answer=${UI_VALUE^^}
        if [[ $answer =~ ^[A-Z]{2}$ ]]; then
            CONFIG_COUNTRY=$answer
            return 0
        fi
        ui_warn_line "'$answer' is not a two-letter ISO country code; try again"
    done
}

config_detect_country_timezone() {
    local LC_ALL=C
    local country_answer=${CONFIG_ANSWERS[COUNTRY]:-}
    local timezone_answer=${CONFIG_ANSWERS[TIMEZONE]:-}
    local geo_json=''
    local geo_fields=''
    local geo_country=''
    local geo_timezone=''
    local iso_timezone=''

    if [[ -n $country_answer ]]; then
        country_answer=${country_answer^^}
        [[ $country_answer =~ ^[A-Z]{2}$ ]] ||
            die 64 'answers-file COUNTRY must be a two-letter ISO country code; correct it and rerun'
        CONFIG_COUNTRY=$country_answer
    else
        CONFIG_COUNTRY=''
    fi

    if [[ -n $timezone_answer ]]; then
        config_validate_timezone "$timezone_answer" ||
            die 64 'answers-file TIMEZONE is invalid; use a zoneinfo name such as Region/City and rerun'
        CONFIG_TIMEZONE=$timezone_answer
    else
        CONFIG_TIMEZONE=''
    fi

    # Unattended runs contact no third party unless GEO_LOOKUP=1 is set explicitly.
    local geo_lookup_answer=${CONFIG_ANSWERS[GEO_LOOKUP]:-0}
    local lookup_allowed=0
    [[ $geo_lookup_answer == 0 || $geo_lookup_answer == 1 ]] ||
        die 64 'answers-file GEO_LOOKUP must be 0 or 1; correct it and rerun'
    if (( CONFIG_UNATTENDED == 0 )) || [[ $geo_lookup_answer == 1 ]]; then
        lookup_allowed=1
    fi

    # One attempt only; a failure falls back to manual entry. The free ip-api.com
    # tier is plain HTTP, so the reply is validated and, interactively, confirmed.
    # Only the three fields used below are requested.
    if (( lookup_allowed == 1 )) && [[ -z $CONFIG_COUNTRY || -z $CONFIG_TIMEZONE ]]; then
        if geo_json=$(curl --fail --silent --show-error --connect-timeout 3 --max-time 5 \
            --output - 'http://ip-api.com/json/?fields=status,countryCode,timezone' 2>/dev/null) &&
           geo_fields=$(config_parse_geo_reply "$geo_json"); then
            geo_country=${geo_fields%%$'\t'*}
            geo_timezone=${geo_fields#*$'\t'}
        else
            warn 'online Geo-IP lookup unavailable or rate-limited; falling back to manual entry'
        fi

        if (( CONFIG_UNATTENDED == 0 )) && [[ -n $geo_country || -n $geo_timezone ]]; then
            if ! ui_confirm "Use detected country '${geo_country:-unknown}' and timezone '${geo_timezone:-unknown}' (ip-api.com)?" y; then
                geo_country=''
                geo_timezone=''
            fi
        fi
    fi

    if [[ -z $CONFIG_COUNTRY ]]; then
        if [[ $geo_country =~ ^[A-Z]{2}$ ]]; then
            CONFIG_COUNTRY=$geo_country
        elif (( CONFIG_UNATTENDED == 1 )); then
            die 64 'COUNTRY is missing; unattended mode needs COUNTRY in /root/arch-install.answers (or GEO_LOOKUP=1 to look it up)'
        else
            config_prompt_country
        fi
    fi

    if [[ -z $CONFIG_TIMEZONE ]]; then
        if config_validate_timezone "$geo_timezone"; then
            CONFIG_TIMEZONE=$geo_timezone
        else
            if (( CONFIG_UNATTENDED == 1 )); then
                die 64 'TIMEZONE is missing; unattended mode needs TIMEZONE in /root/arch-install.answers (or GEO_LOOKUP=1 to look it up)'
            fi

            require_cmd timedatectl
            iso_timezone=$(timedatectl show --property=Timezone --value) ||
                die 64 'cannot inspect the live ISO timezone; verify timedatectl and configure TIMEZONE manually'
            config_validate_timezone "$iso_timezone" ||
                die 64 'live ISO timezone is invalid; configure a valid TIMEZONE and rerun'
            ui_confirm "Geo-IP unavailable; use live ISO timezone '$iso_timezone'?" y ||
                die 64 'live ISO timezone was not confirmed; provide a valid TIMEZONE and rerun'
            CONFIG_TIMEZONE=$iso_timezone
        fi
    fi
}

config_disk_inventory() {
    local boot_source
    local boot_match

    CONFIG_LSBLK_JSON=$(lsblk --json --paths \
        --output PATH,TYPE,PKNAME,SIZE,MOUNTPOINTS,RO,RM) ||
        die 20 'lsblk disk enumeration failed; inspect block devices and rerun'

    jq -e '.blockdevices | type == "array"' >/dev/null <<< "$CONFIG_LSBLK_JSON" ||
        die 20 'lsblk returned invalid JSON; inspect block-device metadata and rerun'

    boot_source=$(findmnt --evaluate --noheadings --raw --output SOURCE \
        --target /run/archiso/bootmnt) ||
        die 20 'cannot identify the Arch ISO boot medium; verify /run/archiso/bootmnt and rerun'
    boot_source=${boot_source%%\[*}
    [[ $boot_source == /dev/* ]] ||
        die 20 'Arch ISO boot source is not a block device; refusing disk selection'

    boot_match=$(lsblk_root_device_for "$boot_source" <<< "$CONFIG_LSBLK_JSON") ||
        die 20 'cannot map the Arch ISO boot source to one top-level device; refusing disk selection'

    CONFIG_BOOT_DISK=$boot_match
}

config_disk_busy() {
    local disk=$1
    local disk_name
    local block_paths
    local block_path
    local block_name
    local holder
    local swap_source
    local first_line=1
    local jq_status

    # Any mounted descendant makes the whole disk unavailable.
    # shellcheck disable=SC2016
    if jq -e --arg disk "$disk" '
        def descendants: ., (.children[]? | descendants);
        any(.blockdevices[]? | select(.path == $disk) | descendants;
            any(.mountpoints[]?; . != null))
    ' >/dev/null <<< "$CONFIG_LSBLK_JSON"; then
        return 0
    else
        jq_status=$?
        (( jq_status == 1 )) || return 2
    fi

    # Check holders on the disk and every descendant partition/device.
    # shellcheck disable=SC2016
    block_paths=$(jq -r --arg disk "$disk" '
        def descendants: ., (.children[]? | descendants);
        .blockdevices[]?
        | select(.path == $disk)
        | descendants
        | .path // empty
    ' <<< "$CONFIG_LSBLK_JSON") || return 2

    while IFS= read -r block_path; do
        [[ -n $block_path ]] || continue
        block_name=$(basename -- "$block_path") || return 2

        for holder in "/sys/class/block/$block_name/holders/"*; do
            [[ -e $holder ]] || continue
            return 0
        done
    done <<< "$block_paths"

    [[ -r /proc/swaps ]] || return 2
    while IFS=' ' read -r swap_source _; do
        if (( first_line == 1 )); then
            first_line=0
            continue
        fi
        [[ $swap_source == /dev/* ]] || continue

        # shellcheck disable=SC2016
        if jq -e --arg disk "$disk" --arg swap "$swap_source" '
            def descendants: ., (.children[]? | descendants);
            any(.blockdevices[]? | select(.path == $disk) | descendants;
                .path == $swap)
        ' >/dev/null <<< "$CONFIG_LSBLK_JSON"; then
            return 0
        else
            jq_status=$?
            (( jq_status == 1 )) || return 2
        fi
    done < /proc/swaps

    return 1
}


config_disk_candidates() {
    local candidate_rows
    local disk_path
    local disk_size
    local busy_status

    CONFIG_DISK_PATHS=()
    CONFIG_DISK_LABELS=()

    # jq variables are supplied with --arg and intentionally remain literal to Bash.
    # shellcheck disable=SC2016
    candidate_rows=$(jq -r --arg boot "$CONFIG_BOOT_DISK" '
        .blockdevices[]? |
        select(.type == "disk" and .path != $boot and (.ro // 0) == 0) |
        select((.path | split("/")[-1] | test("^mmcblk[0-9]+(boot[0-9]+|rpmb)$")) | not) |
        [.path, (.size // "unknown" | tostring)] | @tsv
    ' <<< "$CONFIG_LSBLK_JSON") ||
        die 20 'cannot build a complete disk candidate list; inspect lsblk JSON and rerun'

    while IFS=$'\t' read -r disk_path disk_size; do
        [[ -n $disk_path && -n $disk_size ]] || continue
        if config_disk_busy "$disk_path"; then
            continue
        else
            busy_status=$?
        fi
        (( busy_status == 1 )) ||
            die 20 "cannot safely inspect disk '$disk_path'; check mounts, holders, and swap usage"
        CONFIG_DISK_PATHS+=("$disk_path")
        CONFIG_DISK_LABELS+=("$disk_path ($disk_size)")
    done <<< "$candidate_rows"
}

config_disk_is_candidate() {
    local wanted=$1
    local candidate

    for candidate in "${CONFIG_DISK_PATHS[@]}"; do
        [[ $candidate == "$wanted" ]] && return 0
    done
    return 1
}

config_select_disk() {
    local selected
    local expected_name
    local typed_name

    config_disk_inventory
    config_disk_candidates
    (( ${#CONFIG_DISK_PATHS[@]} > 0 )) ||
        die 20 'no eligible unmounted install disk found; disconnect the live-medium parent disk and release other devices'

    if (( CONFIG_UNATTENDED == 1 )); then
        selected=${CONFIG_ANSWERS[DISK]}
        expected_name=$(basename -- "$selected") ||
            die 64 'cannot parse DISK from answers file; use an absolute /dev device path'
        [[ $selected == /dev/* && $selected == "/dev/$expected_name" ]] ||
            die 64 'answers-file DISK must be an absolute device path under /dev; correct it and rerun'
        [[ ${CONFIG_ANSWERS[CONFIRM_DISK]} == "$expected_name" ]] ||
            die 64 'CONFIRM_DISK does not exactly match the DISK basename; correct the confirmation and rerun'
    else
        ui_menu 1 'Available installation disks' "${CONFIG_DISK_LABELS[@]}"
        selected=${CONFIG_DISK_PATHS[UI_CHOICE_INDEX]}
        expected_name=$(basename -- "$selected") ||
            die 64 'cannot determine selected disk basename; rerun disk selection'
        ui_box "$UI_RED" 'CONFIRM INSTALL TARGET' \
            "Stage 03 will erase every partition on $selected." \
            'Nothing is changed until you confirm. Type the device name exactly as shown.'
        ui_input "Type '$expected_name' to confirm"
        typed_name=$UI_VALUE
        [[ $typed_name == "$expected_name" ]] ||
            die 64 'disk confirmation did not match; no disk was modified, rerun and type the exact basename'
    fi

    config_disk_is_candidate "$selected" ||
        die 20 'selected disk is missing, mounted, busy, read-only, or is the live ISO device; choose another disk'

    CONFIG_DISK=$selected
}

config_validate_account() {
    local username_input=$1
    local hostname_input=$2
    local LC_ALL=C
    local normalized_username=${username_input,,}
    local normalized_hostname=${hostname_input,,}

    [[ $normalized_username =~ ^[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\$)$ ]] ||
        die 64 'username is invalid; use 1-32 lowercase Linux account characters and rerun'
    [[ $normalized_hostname =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
        die 64 'hostname is invalid; use 1-63 letters, digits, or interior hyphens and rerun'

    CONFIG_USERNAME=$normalized_username
    CONFIG_HOSTNAME=$normalized_hostname
}

config_collect_account() {
    local LC_ALL=C
    local username_input
    local hostname_input

    if (( CONFIG_UNATTENDED == 1 )); then
        username_input=${CONFIG_ANSWERS[USERNAME]}
        hostname_input=${CONFIG_ANSWERS[HOSTNAME]}
    else
        while true; do
            ui_input 'Username (lowercase, 1-32 characters)'
            username_input=${UI_VALUE,,}
            if [[ $username_input =~ ^[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\$)$ ]]; then
                break
            fi
            ui_warn_line 'Invalid username: start with a letter or underscore; use lowercase letters, digits, _ or -.'
        done

        while true; do
            ui_input 'Hostname'
            hostname_input=${UI_VALUE,,}
            if [[ $hostname_input =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
                break
            fi
            ui_warn_line 'Invalid hostname: use 1-63 letters, digits, or hyphens between them.'
        done
    fi

    config_validate_account "$username_input" "$hostname_input"
}

config_validate_password_hash() {
    [[ $1 =~ ^\$6\$[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{86}$ ]]
}

config_collect_password() {
    local password_one=''
    local password_two=''
    local password_hash=''

    if (( CONFIG_UNATTENDED == 1 )); then
        password_hash=${CONFIG_ANSWERS[PW_HASH]}
        config_validate_password_hash "$password_hash" ||
            die 64 'answers-file PW_HASH is not a SHA-512 crypt hash; generate one with openssl passwd -6 and rerun'
    else
        while true; do
            password_one=''
            password_two=''
            ui_secret 'Password'
            password_one=$UI_VALUE
            ui_secret 'Confirm password'
            password_two=$UI_VALUE
            if [[ -n $password_one && $password_one == "$password_two" ]]; then
                break
            fi
            unset password_one password_two
            ui_warn_line 'Passwords were empty or did not match; try again.'
        done

        if ! password_hash=$(printf '%s\n' "$password_one" | openssl passwd -6 -stdin); then
            unset password_one password_two password_hash
            die 64 'password hashing failed; verify openssl is available and rerun'
        fi
        unset password_one password_two
        config_validate_password_hash "$password_hash" || {
            unset password_hash
            die 64 'openssl returned an invalid SHA-512 crypt hash; verify openssl and rerun'
        }
    fi

    CONFIG_PW_HASH=$password_hash
    unset password_hash
}

config_collect_keyboard_locale() {
    local LC_ALL=C
    local keymap_input
    local locale_input
    local suggested_locale
    local locale_base

    if (( CONFIG_UNATTENDED == 1 )); then
        keymap_input=${CONFIG_ANSWERS[KEYMAP]}
        locale_input=${CONFIG_ANSWERS[LOCALE]}
    else
        ui_menu 4 'Keyboard layout' "${CONFIG_KEYMAPS[@]}"
        keymap_input=$UI_CHOICE
        suggested_locale=${CONFIG_KEYMAP_LOCALES["$keymap_input"]:-en_US.UTF-8}
        ui_input 'Locale' "$suggested_locale"
        locale_input=$UI_VALUE
    fi

    [[ " ${CONFIG_KEYMAPS[*]} " == *" $keymap_input "* ]] ||
        die 64 "unsupported keymap '$keymap_input'; choose a supported layout and rerun"

    [[ $locale_input =~ ^[a-z]{2,3}_[A-Z]{2,3}\.UTF-8$ ]] ||
        die 64 "invalid locale '$locale_input'; use a locale such as en_US.UTF-8 and rerun"
    locale_base=${locale_input%.*}
    [[ -f "/usr/share/i18n/locales/$locale_base" && \
       ( -f /usr/share/i18n/charmaps/UTF-8.gz || -f /usr/share/i18n/charmaps/UTF-8 ) ]] ||
        die 64 "locale '$locale_input' is not available in the ISO locale definitions; choose an installed locale and rerun"

    CONFIG_KEYMAP=$keymap_input
    CONFIG_LOCALE=$locale_input
}

config_derive_mount_options() {
    local disk_name
    local rotational_file
    local rotational

    disk_name=$(basename -- "$CONFIG_DISK") ||
        die 20 'cannot determine selected disk name; re-enumerate disks and rerun'

    if [[ $disk_name =~ ^mmcblk[0-9]+$ ]]; then
        CONFIG_MOUNT_OPTIONS='noatime,compress=zstd:5,ssd,commit=120'
        return 0
    fi

    rotational_file="/sys/block/$disk_name/queue/rotational"
    if [[ ! -e $rotational_file ]]; then
        CONFIG_MOUNT_OPTIONS='noatime,compress=zstd,ssd,commit=120'
        return 0
    fi

    [[ -r $rotational_file ]] ||
        die 20 "cannot read rotational metadata for '$CONFIG_DISK'; verify device sysfs metadata and rerun"
    IFS= read -r rotational < "$rotational_file" ||
        die 20 "cannot read rotational metadata for '$CONFIG_DISK'; verify device sysfs metadata and rerun"

    case $rotational in
        0) CONFIG_MOUNT_OPTIONS='noatime,compress=zstd,ssd,commit=120' ;;
        1) CONFIG_MOUNT_OPTIONS='noatime,compress=zstd,commit=120' ;;
        *) die 20 "invalid rotational metadata for '$CONFIG_DISK'; expected 0 or 1 and will not guess mount options" ;;
    esac
}

config_persist() {
    [[ $CONFIG_DISK == /dev/* && -n $CONFIG_FS && -n $CONFIG_ENCRYPTION &&
       -n $CONFIG_KEYMAP && -n $CONFIG_LOCALE && -n $CONFIG_TIMEZONE &&
       $CONFIG_COUNTRY =~ ^[A-Z]{2}$ && -n $CONFIG_USERNAME &&
       -n $CONFIG_HOSTNAME && -n $CONFIG_PW_HASH && -n $CONFIG_MOUNT_OPTIONS ]] ||
        die 64 'configuration validation failed before persistence; correct the answers and rerun'

    state_set_many \
        DISK "$CONFIG_DISK" \
        FS "$CONFIG_FS" \
        ENCRYPTION "$CONFIG_ENCRYPTION" \
        KEYMAP "$CONFIG_KEYMAP" \
        LOCALE "$CONFIG_LOCALE" \
        TIMEZONE "$CONFIG_TIMEZONE" \
        COUNTRY "$CONFIG_COUNTRY" \
        USERNAME "$CONFIG_USERNAME" \
        HOSTNAME "$CONFIG_HOSTNAME" \
        PW_HASH "$CONFIG_PW_HASH" \
        MOUNT_OPTIONS "$CONFIG_MOUNT_OPTIONS"
}

config_main() {
    (( $# == 0 )) || die 64 '02-config takes no arguments'

    init
    ensure_live_jq
    require_cmd jq openssl curl lsblk findmnt basename
    state_load
    [[ ${BOOT_MODE:-} == uefi ]] ||
        die 12 'verified UEFI boot state is missing; run module 01 preflight and rerun configuration'

    config_load_answers
    config_detect_country_timezone
    config_select_disk
    CONFIG_FS=btrfs
    CONFIG_ENCRYPTION=luks2
    config_collect_account
    config_collect_password
    config_collect_keyboard_locale

    # Recheck immediately before deriving options and committing state.
    config_disk_inventory
    config_disk_candidates
    config_disk_is_candidate "$CONFIG_DISK" ||
        die 20 "selected disk '$CONFIG_DISK' became mounted, busy, read-only, or unavailable; release it and rerun"
    config_derive_mount_options
    config_persist
    log 'installation configuration validated and persisted atomically'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    config_main "$@"
fi
