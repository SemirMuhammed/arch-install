#!/usr/bin/env bash
set -Eeuo pipefail

if ! declare -F init >/dev/null 2>&1; then
    if [[ ${BASH_SOURCE[0]} == */* ]]; then
        _CHROOT_MODULE_DIR=${BASH_SOURCE[0]%/*}
    else
        _CHROOT_MODULE_DIR=.
    fi
    # shellcheck source=lib/common.sh
    source "$_CHROOT_MODULE_DIR/lib/common.sh"
    unset _CHROOT_MODULE_DIR
fi

CHROOT_TARGET='/mnt'
CHROOT_ENV='/mnt/root/.install.env'
CHROOT_PAYLOAD='/mnt/root/chroot-payload.sh'
declare -g CHROOT_ENV_CREATED=0
declare -g CHROOT_PAYLOAD_CREATED=0
# Non-secret values written to the protected environment file. The password hash
# is deliberately absent: it is sent to the payload on stdin instead.
readonly -a CHROOT_ENV_KEYS=(USERNAME HOSTNAME LOCALE TIMEZONE KEYMAP LUKS_UUID CPU_MICROCODE)

die_cleanup() {
    local status=$?
    local cleanup_failed=0
    local path
    local owner
    local mode

    trap - EXIT
    for path in "$CHROOT_ENV" "$CHROOT_PAYLOAD"; do
        if [[ $path == "$CHROOT_ENV" && $CHROOT_ENV_CREATED != 1 ]]; then
            continue
        fi
        if [[ $path == "$CHROOT_PAYLOAD" && $CHROOT_PAYLOAD_CREATED != 1 ]]; then
            continue
        fi
        [[ -e $path || -L $path ]] || continue
        [[ ! -L $path && -f $path ]] || {
            printf 'ERROR: refusing unsafe cleanup path: %s\n' "$path" >&2
            cleanup_failed=1
            continue
        }
        owner=$(stat -c '%u' -- "$path") || owner=unknown
        mode=$(stat -c '%a' -- "$path") || mode=unknown
        if [[ $owner != 0 || ( $path == "$CHROOT_ENV" && $mode != 600 ) || ( $path == "$CHROOT_PAYLOAD" && $mode != 700 ) ]]; then
            printf 'ERROR: refusing cleanup of changed temporary file: %s\n' "$path" >&2
            cleanup_failed=1
            continue
        fi
        if ! run --mutating rm -f -- "$path"; then
            printf 'ERROR: cannot remove temporary chroot file: %s\n' "$path" >&2
            cleanup_failed=1
        fi
    done

    if (( status == 0 && cleanup_failed == 1 )); then
        status=50
    fi
    exit "$status"
}

chroot_validate_state() {
    state_load

    [[ ${BOOT_MODE:-} == uefi && -d /sys/firmware/efi ]] ||
        die 11 '05-chroot requires UEFI mode; reboot the Arch ISO in UEFI mode'
    [[ ${FS:-} == btrfs && ${ENCRYPTION:-} == luks2 ]] ||
        die 64 'state must specify FS=btrfs and ENCRYPTION=luks2; rerun configuration'
    [[ ${ROOT_DEV:-} == /dev/mapper/ROOT && -b ${ROOT_DEV:-} ]] ||
        die 64 'ROOT_DEV must be the active /dev/mapper/ROOT block device; rerun partitioning'
    [[ ${LUKS_UUID:-} =~ ^[[:xdigit:]-]+$ ]] ||
        die 64 'LUKS_UUID is missing or invalid; rerun partitioning'
    [[ ${ESP_PART:-} == /dev/* && -b ${ESP_PART:-} ]] ||
        die 64 'ESP_PART is missing or is not a block device; rerun partitioning'
    [[ ${ESP_UUID:-} =~ ^[[:xdigit:]-]+$ ]] ||
        die 64 'ESP_UUID is missing or invalid; rerun partitioning'
    [[ ${USERNAME:-} != root && ${USERNAME:-} =~ ^[a-z_][a-z0-9_-]{0,30}\$?$ ]] ||
        die 64 'USERNAME is invalid; use a lowercase Linux account name and rerun configuration'
    [[ ${PW_HASH:-} =~ ^\$6\$[A-Za-z0-9./]+\$[A-Za-z0-9./]+$ ]] ||
        die 64 'PW_HASH must be a SHA-512 crypt hash; regenerate it with openssl passwd -6'
    [[ ${HOSTNAME:-} =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] ||
        die 64 'HOSTNAME is invalid; use a hostname of at most 63 characters'
    [[ ${LOCALE:-} =~ ^[A-Za-z0-9_@.-]+$ ]] ||
        die 64 'LOCALE is invalid; correct locale configuration and rerun'
    [[ ${TIMEZONE:-} =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+.-]+)*$ && ${TIMEZONE:-} != *..* ]] ||
        die 64 'TIMEZONE is invalid; use a valid Region/City zoneinfo name'
    [[ ${KEYMAP:-} =~ ^[A-Za-z0-9_-]+$ ]] ||
        die 64 'KEYMAP is invalid; correct console keymap configuration and rerun'
    [[ ${MOUNT_OPTIONS:-} =~ ^[[:alnum:]_:,=.-]+$ ]] ||
        die 64 'MOUNT_OPTIONS is invalid; rerun configuration'
}

chroot_validate_mounts() {
    local root_source
    local esp_source
    local root_real
    local esp_real
    local root_options
    local esp_uuid

    require_mount "$CHROOT_TARGET"
    require_mount "$CHROOT_TARGET/boot"

    [[ $(findmnt -rn -M "$CHROOT_TARGET" -o FSTYPE) == btrfs ]] ||
        die 22 '/mnt is not the expected Btrfs root; mount the @ subvolume and rerun'
    root_source=$(findmnt -rn -M "$CHROOT_TARGET" -o SOURCE) ||
        die 22 'cannot identify /mnt source; verify the root mount'
    root_source=${root_source%%\[*}
    root_real=$(readlink -f -- "$root_source") ||
        die 22 'cannot resolve /mnt source; verify the ROOT mapper mount'
    local expected_root
    expected_root=$(readlink -f -- "$ROOT_DEV") ||
        die 22 'cannot resolve ROOT_DEV; inspect the LUKS mapping'
    [[ $root_real == "$expected_root" ]] ||
        die 22 '/mnt is not mounted from ROOT_DEV; mount the correct Btrfs root'
    root_options=$(findmnt -rn -M "$CHROOT_TARGET" -o OPTIONS) ||
        die 22 'cannot inspect /mnt mount options; verify the @ subvolume mount'
    [[ ,$root_options, == *,subvol=@,* || ,$root_options, == *,subvol=/@,* ]] ||
        die 22 '/mnt is not mounted with subvol=@; remount the correct Btrfs root'

    [[ $(findmnt -rn -M "$CHROOT_TARGET/boot" -o FSTYPE) == vfat ]] ||
        die 22 '/mnt/boot is not a FAT EFI system partition; mount the ESP at /mnt/boot'
    esp_source=$(findmnt -rn -M "$CHROOT_TARGET/boot" -o SOURCE) ||
        die 22 'cannot identify /mnt/boot source; verify the ESP mount'
    esp_source=${esp_source%%\[*}
    esp_real=$(readlink -f -- "$esp_source") ||
        die 22 'cannot resolve /mnt/boot source; verify the ESP device'
    local expected_esp
    expected_esp=$(readlink -f -- "$ESP_PART") ||
        die 22 'cannot resolve ESP_PART; rerun partitioning'
    [[ $esp_real == "$expected_esp" ]] ||
        die 22 '/mnt/boot is not mounted from ESP_PART; mount the correct ESP'
    esp_uuid=$(blkid -s UUID -o value "$ESP_PART") ||
        die 22 'cannot read ESP UUID; inspect the EFI system partition'
    [[ $esp_uuid == "$ESP_UUID" ]] ||
        die 22 'ESP_UUID does not match ESP_PART; rerun partitioning and verify state'
}

chroot_check_packages() {
    local package
    local vendor
    local -a packages=(systemd linux-lts mkinitcpio networkmanager openssh sudo)

    require_cmd pacman arch-chroot findmnt blkid readlink install tee rm awk grep stat chmod
    for package in "${packages[@]}"; do
        pacman --root "$CHROOT_TARGET" -Qq "$package" >/dev/null 2>&1 ||
            die 31 "target package is missing: $package; install it in the package module and rerun"
    done

    vendor=$(awk -F': ' '/^vendor_id[[:space:]]*:/ { print $2; exit }' /proc/cpuinfo)
    case $vendor in
        GenuineIntel)
            pacman --root "$CHROOT_TARGET" -Qq intel-ucode >/dev/null 2>&1 ||
                die 31 'intel-ucode is missing; install it in the package module and rerun'
            CHROOT_MICROCODE=intel
            ;;
        AuthenticAMD)
            pacman --root "$CHROOT_TARGET" -Qq amd-ucode >/dev/null 2>&1 ||
                die 31 'amd-ucode is missing; install it in the package module and rerun'
            CHROOT_MICROCODE=amd
            ;;
        *)
            CHROOT_MICROCODE=none
            warn 'CPU vendor is unknown; no vendor microcode initrd will be configured'
            ;;
    esac
}

chroot_encode_value() {
    local value=$1
    _common_encode_value "$value"
    [[ $_COMMON_STATE_HEX =~ ^([[:xdigit:]]{2})*$ ]] ||
        die 50 'cannot encode protected chroot environment value'
    CHROOT_ENCODED=$_COMMON_STATE_HEX
}

chroot_write_environment() {
    local key
    local value
    local path
    local owner
    local mode
    local -a keys=("${CHROOT_ENV_KEYS[@]}")

    [[ -d /mnt/root && ! -L /mnt/root ]] ||
        die 50 'target /root directory is missing or unsafe; verify the pacstrap target'

    for path in "$CHROOT_ENV" "$CHROOT_PAYLOAD"; do
        [[ -e $path || -L $path ]] || continue
        [[ ! -L $path && -f $path ]] ||
            die 20 "temporary chroot path is not a regular file: $path; inspect it before rerunning"
        owner=$(stat -c '%u' -- "$path") || die 20 "cannot inspect temporary file owner: $path"
        mode=$(stat -c '%a' -- "$path") || die 20 "cannot inspect temporary file mode: $path"
        if [[ $path == "$CHROOT_ENV" ]]; then
            [[ $owner == 0 && $mode == 600 ]] ||
                die 20 "existing environment file is not root-owned mode 600: $path; inspect it before rerunning"
        else
            [[ $owner == 0 && $mode == 700 ]] ||
                die 20 "existing payload file is not root-owned mode 700: $path; inspect it before rerunning"
        fi
        run --mutating rm -f -- "$path" || die 50 "cannot replace prior temporary file: $path"
    done

    CHROOT_ENV_CREATED=1
    run --mutating install -o 0 -g 0 -m 600 /dev/null "$CHROOT_ENV" ||
        die 50 'cannot create protected chroot environment file'
    for key in "${keys[@]}"; do
        case $key in
            CPU_MICROCODE) value=$CHROOT_MICROCODE ;;
            *) value=${!key} ;;
        esac
        chroot_encode_value "$value"
        printf '%s=%s\n' "${key}_HEX" "$CHROOT_ENCODED" |
            run --mutating tee -a -- "$CHROOT_ENV" >/dev/null ||
            die 50 'cannot write protected chroot environment file'
    done
    run --mutating chmod 600 -- "$CHROOT_ENV" ||
        die 50 'cannot secure chroot environment file'
}

chroot_payload_body() {
    cat <<'CHROOT_PAYLOAD_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

die() {
    local code=$1
    shift
    printf 'ERROR [%s]: %s\n' "$code" "$*" >&2
    exit "$code"
}

payload_err_trap() {
    local status=$1
    local line=$2
    printf 'ERROR [50]: chroot command failed at line %s (status %s)\n' "$line" "$status" >&2
    exit 50
}
trap 'payload_err_trap "$?" "${BASH_LINENO[0]:-$LINENO}"' ERR

# The account secret ("USERNAME:HASH") arrives on stdin from the host. Read it
# before any command can consume stdin.
IFS= read -r account_secret || die 64 'account secret was not supplied on stdin'

run() {
    local mutating=0
    if [[ ${1-} == --mutating ]]; then
        mutating=1
        shift
    fi
    (( $# > 0 )) || die 64 'run requires a command'
    if (( mutating == 1 )) && [[ ${DRY_RUN:-0} == 1 ]]; then
        return 0
    fi
    "$@"
}

[[ -f /root/.install.env && ! -L /root/.install.env ]] ||
    die 64 'protected environment file is missing or unsafe; rerun the host module'
[[ $(stat -c '%u:%a' /root/.install.env) == 0:600 ]] ||
    die 64 'protected environment file ownership or mode is unsafe; rerun the host module'

declare -A env_seen=()
while IFS= read -r line || [[ -n ${line:-} ]]; do
    [[ $line =~ ^([A-Z_]+_HEX)=([[:xdigit:]]+)$ ]] ||
        die 64 'environment file contains an invalid assignment; rerun the host module'
    key=${BASH_REMATCH[1]}
    case $key in
        USERNAME_HEX|HOSTNAME_HEX|LOCALE_HEX|TIMEZONE_HEX|KEYMAP_HEX|LUKS_UUID_HEX|CPU_MICROCODE_HEX) ;;
        *) die 64 'environment file contains an unknown key; rerun the host module' ;;
    esac
    [[ ! ${env_seen[$key]+present} ]] ||
        die 64 'environment file contains a duplicate key; rerun the host module'
    env_seen[$key]=1
done < /root/.install.env

for key in USERNAME HOSTNAME LOCALE TIMEZONE KEYMAP LUKS_UUID CPU_MICROCODE; do
    [[ ${env_seen[${key}_HEX]+present} ]] ||
        die 64 "environment is missing $key; rerun the host module"
done
# Only validated fixed-name hex assignments are sourced; values cannot become shell syntax.
# shellcheck source=/dev/null
source /root/.install.env
for key in USERNAME HOSTNAME LOCALE TIMEZONE KEYMAP LUKS_UUID CPU_MICROCODE; do
    hex_name=${key}_HEX
    encoded=${!hex_name}
    escaped=''
    for (( i=0; i<${#encoded}; i+=2 )); do
        escaped+="\\x${encoded:i:2}"
    done
    printf -v "$key" '%b' "$escaped"
done
unset USERNAME_HEX HOSTNAME_HEX LOCALE_HEX TIMEZONE_HEX KEYMAP_HEX LUKS_UUID_HEX CPU_MICROCODE_HEX
unset key hex_name encoded escaped i env_seen line
[[ $USERNAME != root && $USERNAME =~ ^[a-z_][a-z0-9_-]{0,30}\$?$ ]] || die 64 'decoded USERNAME is invalid; correct installer state'
[[ $account_secret == "$USERNAME:"* ]] || die 64 'account secret on stdin does not match USERNAME'
account_hash=${account_secret#"$USERNAME:"}
[[ $account_hash =~ ^\$6\$[./A-Za-z0-9]+\$[./A-Za-z0-9]+$ ]] || die 64 'account secret on stdin is not a SHA-512 crypt hash'
[[ $HOSTNAME =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] || die 64 'decoded HOSTNAME is invalid'
[[ $LOCALE =~ ^[A-Za-z0-9_@.-]+$ ]] || die 64 'decoded LOCALE is invalid'
[[ $TIMEZONE =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+.-]+)*$ && $TIMEZONE != *..* ]] || die 64 'decoded TIMEZONE is invalid'
[[ $KEYMAP =~ ^[A-Za-z0-9_-]+$ ]] || die 64 'decoded KEYMAP is invalid'
[[ $LUKS_UUID =~ ^[[:xdigit:]-]+$ ]] || die 64 'decoded LUKS_UUID is invalid'

[[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die 64 'timezone database entry is missing; correct TIMEZONE and rerun'
[[ -f /etc/locale.gen && -f /etc/mkinitcpio.conf ]] || die 31 'locale.gen or mkinitcpio.conf is missing; verify target packages'
for command_name in mkinitcpio bootctl visudo locale-gen systemctl awk grep sed mktemp install tee id getent useradd usermod chpasswd passwd stat ln rm; do
    command -v -- "$command_name" >/dev/null 2>&1 ||
        die 31 "required target command is missing: $command_name; verify installed packages"
done

# Validate locale exists before changing it.
# Match on fields, not raw text: tolerate leading/trailing whitespace, tabs, and CRLF.
locale_line=$(awk -v locale="$LOCALE" '{ line = $0; gsub(/\r/, "", line); sub(/^[ \t]*#?[ \t]*/, "", line); sub(/[ \t]+$/, "", line); n = split(line, f, /[ \t]+/); if (n == 2 && f[1] == locale && f[2] == "UTF-8") { print; count++ } } END { if (count != 1) exit 1 }' /etc/locale.gen) || {
    # Show the evidence, with hidden characters made visible by cat -A.
    printf 'LOCALE value: %s\n' "${LOCALE@Q}" >&2
    printf 'entries in /etc/locale.gen mentioning %s:\n' "${LOCALE%%.*}" >&2
    { grep -n -F -- "${LOCALE%%.*}" /etc/locale.gen || printf '(none found)\n'; } | cat -A >&2
    die 64 'requested locale must match exactly one UTF-8 entry in locale.gen; see the entries above and correct LOCALE'
}
if [[ $locale_line =~ ^[[:space:]]*# ]]; then
    run --mutating sed -i -E "s|^[[:space:]]*#[[:space:]]*(${LOCALE}[[:space:]]+UTF-8)[[:space:]]*$|\1|" /etc/locale.gen ||
        die 50 'cannot enable requested locale in locale.gen; inspect the file'
fi
run --mutating locale-gen || die 50 'locale-gen failed; inspect locale.gen and rerun'

# Reconcile identity files without host systemd helpers.
locale_tmp=$(run --mutating mktemp /etc/locale.conf.XXXXXX) || die 50 'cannot create locale.conf temporary file'
printf '%s\n' "LANG=$LOCALE" | run --mutating tee "$locale_tmp" >/dev/null || die 50 'cannot stage locale.conf; inspect target filesystem'
run --mutating install -o 0 -g 0 -m 644 "$locale_tmp" /etc/locale.conf ||
    die 50 'cannot write locale.conf; inspect target filesystem'
run --mutating rm -f -- "$locale_tmp" || die 50 'cannot remove locale.conf temporary file'
[[ ! -e /etc/localtime || -L /etc/localtime ]] || die 20 '/etc/localtime is not a symlink; inspect it before replacing'
run --mutating ln -sfn -- "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime ||
    die 50 'cannot configure timezone symlink; inspect zoneinfo and target filesystem'
vconsole_tmp=$(run --mutating mktemp /etc/vconsole.conf.XXXXXX) || die 50 'cannot create vconsole temporary file'
printf '%s\n' "KEYMAP=$KEYMAP" | run --mutating tee "$vconsole_tmp" >/dev/null || die 50 'cannot stage vconsole.conf; inspect target filesystem'
run --mutating install -o 0 -g 0 -m 644 "$vconsole_tmp" /etc/vconsole.conf ||
    die 50 'cannot write vconsole.conf; inspect target filesystem'
run --mutating rm -f -- "$vconsole_tmp" || die 50 'cannot remove vconsole temporary file'
hostname_tmp=$(run --mutating mktemp /etc/hostname.XXXXXX) || die 50 'cannot create hostname temporary file'
printf '%s\n' "$HOSTNAME" | run --mutating tee "$hostname_tmp" >/dev/null || die 50 'cannot stage hostname; inspect target filesystem'
run --mutating install -o 0 -g 0 -m 644 "$hostname_tmp" /etc/hostname ||
    die 50 'cannot write hostname; inspect target filesystem'
run --mutating rm -f -- "$hostname_tmp" || die 50 'cannot remove hostname temporary file'

# Print a HOOKS list with systemd-initramfs tokens replaced by the classic udev chain.
# This installer boots with cryptdevice= and the encrypt hook, which systemd-based
# initramfs hooks cannot use: systemd and sd-vconsole become "base udev" and sd-vconsole
# is dropped. sd-encrypt is refused because it needs a different kernel command line.
normalize_hooks() {
    local -a out=()
    local -a kept=()
    local -a final=()
    local systemd_seen=0
    local seen_keyboard=0
    local seen_keymap=0
    local seen_consolefont=0
    local token

    for token in "$@"; do
        case $token in
            systemd) systemd_seen=1 ;;
            sd-vconsole) systemd_seen=1; out+=(keymap consolefont) ;;
            sd-encrypt) return 1 ;;
            *) out+=("$token") ;;
        esac
    done

    if (( systemd_seen == 0 )); then
        printf '%s\n' "${out[*]}"
        return 0
    fi

    # Keep the first keyboard, keymap, and consolefont; drop base/udev (re-added below).
    for token in "${out[@]}"; do
        case $token in
            base|udev) ;;
            keyboard) if (( seen_keyboard == 0 )); then kept+=(keyboard); seen_keyboard=1; fi ;;
            keymap) if (( seen_keymap == 0 )); then kept+=(keymap); seen_keymap=1; fi ;;
            consolefont) if (( seen_consolefont == 0 )); then kept+=(consolefont); seen_consolefont=1; fi ;;
            *) kept+=("$token") ;;
        esac
    done

    # Keep the usual order (keyboard before keymap) and keep keyboard and keymap before block.
    for token in "${kept[@]}"; do
        if [[ $token == keymap || $token == consolefont ]] && (( seen_keyboard == 0 )); then
            final+=(keyboard); seen_keyboard=1
        fi
        if [[ $token == block ]]; then
            if (( seen_keyboard == 0 )); then final+=(keyboard); seen_keyboard=1; fi
            if (( seen_keymap == 0 )); then final+=(keymap); seen_keymap=1; fi
        fi
        final+=("$token")
    done

    printf '%s\n' "base udev ${final[*]}"
}

# Ensure the classic encrypt hook follows block and precedes filesystems.
hooks_count=$(grep -c '^HOOKS=' /etc/mkinitcpio.conf) || hooks_count=0
[[ $hooks_count == 1 ]] || die 20 'mkinitcpio.conf must contain exactly one HOOKS assignment; inspect it manually'
hooks_line=$(grep '^HOOKS=' /etc/mkinitcpio.conf) || die 20 'cannot read mkinitcpio HOOKS assignment'
hooks_pattern='^HOOKS=\(([^)]*)\)$'
[[ $hooks_line =~ $hooks_pattern ]] || die 20 'mkinitcpio HOOKS syntax is unsupported; inspect it manually'
hooks_body=${BASH_REMATCH[1]}
read -r -a hooks <<< "$hooks_body"
original_hooks=("${hooks[@]}")
normalized_hooks=$(normalize_hooks "${hooks[@]}") ||
    die 20 'mkinitcpio sd-encrypt hook is incompatible with the cryptdevice= boot configuration; use the classic encrypt hook'
read -r -a hooks <<< "$normalized_hooks"
filesystems_index=-1
block_index=-1
encrypt_index=-1
keyboard_index=-1
keymap_index=-1
filesystems_count=0
block_count=0
encrypt_count=0
for (( index=0; index<${#hooks[@]}; index++ )); do
    [[ ${hooks[index]} =~ ^[A-Za-z0-9_+-]+$ ]] || die 20 'mkinitcpio HOOKS contains an invalid token; inspect it manually'
    case ${hooks[index]} in
        filesystems) filesystems_index=$index; filesystems_count=$((filesystems_count + 1)) ;;
        block) block_index=$index; block_count=$((block_count + 1)) ;;
        encrypt) encrypt_index=$index; encrypt_count=$((encrypt_count + 1)) ;;
        keyboard) keyboard_index=$index ;;
        keymap) keymap_index=$index ;;
    esac
done
[[ $filesystems_count == 1 && $block_count == 1 && $encrypt_count -le 1 ]] ||
    die 20 'mkinitcpio HOOKS must include block and filesystems; inspect it manually'
[[ $keyboard_index -ge 0 && $keymap_index -ge 0 && $keyboard_index -lt $block_index && $keymap_index -lt $block_index ]] ||
    die 20 'mkinitcpio HOOKS must include keyboard and keymap before block for encrypted boot; inspect it manually'
if (( encrypt_index >= 0 )); then
    (( encrypt_index > block_index && encrypt_index < filesystems_index )) ||
        die 20 'existing encrypt hook is in an unsafe position; correct HOOKS manually'
    target_hooks=("${hooks[@]}")
else
    target_hooks=()
    for (( index=0; index<${#hooks[@]}; index++ )); do
        target_hooks+=("${hooks[index]}")
        [[ ${hooks[index]} == block ]] && target_hooks+=(encrypt)
    done
fi

if [[ ${target_hooks[*]} != "${original_hooks[*]}" ]]; then
    printf -v hooks_joined '%s ' "${target_hooks[@]}"
    hooks_joined=${hooks_joined% }
    printf 'updating mkinitcpio HOOKS to: %s\n' "$hooks_joined" >&2
    tmp_hooks=$(run --mutating mktemp /etc/mkinitcpio.conf.XXXXXX) || die 50 'cannot create mkinitcpio temporary file'
    awk -v replacement="HOOKS=($hooks_joined)" '/^HOOKS=/ { print replacement; next } { print }' /etc/mkinitcpio.conf |
        run --mutating tee "$tmp_hooks" >/dev/null || die 50 'cannot prepare mkinitcpio configuration; inspect filesystem'
    run --mutating install -o 0 -g 0 -m 644 "$tmp_hooks" /etc/mkinitcpio.conf ||
        die 50 'cannot update mkinitcpio HOOKS; inspect target filesystem'
    run --mutating rm -f -- "$tmp_hooks" || die 50 'cannot remove mkinitcpio temporary file'
fi
run --mutating mkinitcpio -p linux-lts || die 50 'mkinitcpio failed for linux-lts; inspect HOOKS and kernel preset'
[[ -s /boot/vmlinuz-linux-lts && -s /boot/initramfs-linux-lts.img ]] ||
    die 31 'linux-lts kernel or initramfs image is missing from /boot; verify kernel preset'

case $CPU_MICROCODE in
    intel) [[ -s /boot/intel-ucode.img ]] || die 31 'intel-ucode image is missing from /boot; install intel-ucode in the package module' ;;
    amd) [[ -s /boot/amd-ucode.img ]] || die 31 'amd-ucode image is missing from /boot; install amd-ucode in the package module' ;;
    none) ;;
    *) die 64 'CPU_MICROCODE value is invalid; rerun the host module' ;;
esac

run --mutating bootctl --esp-path=/boot install || die 50 'systemd-boot installation failed; verify UEFI variables and ESP mount'
run --mutating install -d -o 0 -g 0 -m 755 /boot/loader/entries || die 50 'cannot create systemd-boot entry directory'
loader_tmp=$(run --mutating mktemp /boot/loader/loader.conf.XXXXXX) || die 50 'cannot create loader configuration temporary file'
printf '%s\n' 'default arch.conf' 'timeout 3' 'console-mode max' 'editor no' | run --mutating tee "$loader_tmp" >/dev/null || die 50 'cannot stage loader configuration'
run --mutating install -o 0 -g 0 -m 644 "$loader_tmp" /boot/loader/loader.conf ||
    die 50 'cannot install systemd-boot loader configuration'
run --mutating rm -f -- "$loader_tmp" || die 50 'cannot remove loader configuration temporary file'
entry_tmp=$(run --mutating mktemp /boot/loader/entries/arch.conf.XXXXXX) || die 50 'cannot create boot entry temporary file'
{
    printf '%s\n' 'title Arch Linux (linux-lts)' 'linux /vmlinuz-linux-lts'
    case $CPU_MICROCODE in
        intel) printf '%s\n' 'initrd /intel-ucode.img' ;;
        amd) printf '%s\n' 'initrd /amd-ucode.img' ;;
    esac
    printf '%s\n' 'initrd /initramfs-linux-lts.img'
    printf 'options cryptdevice=UUID=%s:ROOT root=/dev/mapper/ROOT rootflags=subvol=@ rw\n' "$LUKS_UUID"
} | run --mutating tee "$entry_tmp" >/dev/null || die 50 'cannot stage systemd-boot entry'
run --mutating install -o 0 -g 0 -m 644 "$entry_tmp" /boot/loader/entries/arch.conf ||
    die 50 'cannot install systemd-boot Arch entry'
run --mutating rm -f -- "$entry_tmp" || die 50 'cannot remove boot entry temporary file'

# Account setup is repeatable. The password hash arrives on stdin from the host
# and is never written to the target filesystem.
getent group wheel >/dev/null || die 31 'wheel group is missing; verify base system and sudo package'
if ! id "$USERNAME" >/dev/null 2>&1; then
    run --mutating useradd -m -G wheel -s /bin/bash "$USERNAME" ||
        die 50 'cannot create requested user; inspect account database'
else
    account_record=$(getent passwd "$USERNAME") || die 20 'existing user is absent from the passwd database; inspect NSS configuration'
    IFS=: read -r account_name _ account_uid _ _ account_home account_shell <<< "$account_record"
    [[ $account_name == "$USERNAME" && $account_home == "/home/$USERNAME" && $account_shell == /bin/bash && -d $account_home && ! -L $account_home ]] ||
        die 20 'existing user home or shell differs from the managed layout; inspect account before rerunning'
    [[ $(stat -c '%u' -- "$account_home") == "$account_uid" ]] ||
        die 20 'existing user home is not owned by that user; repair ownership before rerunning'
    run --mutating usermod -aG wheel "$USERNAME" || die 50 'cannot add existing user to wheel group'
fi
printf '%s\n' "$account_secret" | run --mutating chpasswd -e ||
    die 50 'cannot set requested user password from the supplied hash; verify the installer state'
unset account_secret account_hash
root_status=$(passwd -S root | awk '{ print $2 }') || die 50 'cannot inspect root password status'
if [[ $root_status != L && $root_status != LK ]]; then
    run --mutating passwd -l root || die 50 'cannot lock root account; inspect shadow database'
fi

sudo_dropin=/etc/sudoers.d/10-wheel
grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers.d$' /etc/sudoers ||
    die 20 'sudoers does not include /etc/sudoers.d; configure the include before rerunning'
[[ ! -e $sudo_dropin || -f $sudo_dropin && ! -L $sudo_dropin ]] ||
    die 20 'sudoers drop-in path is unsafe; inspect /etc/sudoers.d/10-wheel'
sudo_tmp=$(run --mutating mktemp /etc/sudoers.d/10-wheel.XXXXXX) || die 50 'cannot create sudoers temporary file'
printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' | run --mutating tee "$sudo_tmp" >/dev/null || die 50 'cannot stage sudo policy'
run --mutating install -o 0 -g 0 -m 440 "$sudo_tmp" "$sudo_dropin" || die 50 'cannot install wheel sudo policy'
run --mutating rm -f -- "$sudo_tmp" || die 50 'cannot remove sudoers temporary file'
run visudo -cf /etc/sudoers >/dev/null || die 20 'sudoers validation failed; inspect sudoers and drop-in files'

run --mutating systemctl enable NetworkManager.service || die 50 'cannot enable NetworkManager.service'
run --mutating systemctl enable sshd.service || die 50 'cannot enable sshd.service; verify openssh installation'
run --mutating systemctl enable systemd-timesyncd.service || die 50 'cannot enable systemd-timesyncd.service'
CHROOT_PAYLOAD_EOF
}

chroot_write_payload() {
    CHROOT_PAYLOAD_CREATED=1
    run --mutating install -o 0 -g 0 -m 700 /dev/null "$CHROOT_PAYLOAD" ||
        die 50 'cannot create chroot payload file'
    chroot_payload_body | run --mutating tee "$CHROOT_PAYLOAD" >/dev/null ||
        die 50 'cannot write chroot payload file'
    run --mutating chmod 700 -- "$CHROOT_PAYLOAD" ||
        die 50 'cannot secure chroot payload file'
}
chroot_main() {
    (( $# == 0 )) || die 64 '05-chroot takes no arguments'
    init
    trap die_cleanup EXIT
    chroot_validate_state
    chroot_validate_mounts
    chroot_check_packages

    if [[ ${DRY_RUN:-0} == 1 ]]; then
        log 'DRY_RUN: validated 05-chroot; skipped target handoff and configuration'
        return 0
    fi

    chroot_write_environment
    chroot_write_payload
    log 'running target configuration payload'

    # The hash travels on stdin only: never as an argument, never in a file on the target.
    local status=0
    printf '%s\n' "$USERNAME:$PW_HASH" |
        run --mutating arch-chroot "$CHROOT_TARGET" /root/chroot-payload.sh || status=$?
    unset PW_HASH

    if (( status == 0 )); then
        log 'target configuration completed'
    else
        case $status in
            10|11|12|13|14|15|20|21|22|23|30|31|40|41|50|64|130)
                die "$status" "chroot payload failed with status $status; inspect target configuration and rerun"
                ;;
            *) die 50 "chroot payload failed with status $status; inspect target configuration and rerun" ;;
        esac
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    chroot_main "$@"
fi
