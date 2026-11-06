#!/usr/bin/env bash
# Local pre-commit check. It runs the same steps as .github/workflows/ci.yml, in the
# same order, plus a scan that stops secrets from being committed.
#
# Usage:
#   tests/check.sh            run every check on the working tree
#   tests/check.sh --staged   scan only staged files for secrets (fast; used by the hook)
#
# Exit status: 0 when every check passes, 1 when a check fails, 2 for missing tools.
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$ROOT_DIR"

MODE=full
if [[ ${1-} == --staged ]]; then
    MODE=staged
elif [[ $# -gt 0 ]]; then
    printf 'usage: %s [--staged]\n' "$0" >&2
    exit 2
fi

FAILED=0

say() {
    printf '\n== %s\n' "$*"
}

pass() {
    printf '   ok\n'
}

fail() {
    printf '   FAILED: %s\n' "$*" >&2
    FAILED=1
}

need() {
    local tool
    for tool in "$@"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            printf 'missing tool: %s\n' "$tool" >&2
            printf 'install it first, for example: sudo pacman -S %s\n' "$tool" "$tool" >&2
            exit 2
        fi
    done
}

# Scan text for material that must never be committed. Prints each match with its
# location, and returns non-zero when anything is found.
scan_text() {
    local label=$1
    local text=$2
    local found=0

    # SHA-512 crypt hashes, which the installer generates for passwords.
    # The single quotes are intentional: these patterns match literal text.
    # shellcheck disable=SC2016
    if grep -nE '\$6\$[A-Za-z0-9./]{8,}\$[A-Za-z0-9./]{20,}' <<< "$text" >/dev/null; then
        # shellcheck disable=SC2016
        grep -nE '\$6\$[A-Za-z0-9./]{8,}\$[A-Za-z0-9./]{20,}' <<< "$text" | sed "s|^|   $label: password hash: |"
        found=1
    fi
    # Private key material.
    if grep -nE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' <<< "$text" >/dev/null; then
        grep -nE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' <<< "$text" | sed "s|^|   $label: private key: |"
        found=1
    fi
    # Real installer answers and logs.
    # A real PW_HASH value looks like a hash; a placeholder such as $6$... does not match.
    # shellcheck disable=SC2016
    if grep -nE '^PW_HASH=\$6\$[A-Za-z0-9./]{8,}' <<< "$text" >/dev/null ||
        grep -nE '^PASSWORD=[^[:space:]]+' <<< "$text" >/dev/null; then
        grep -nE '^(PW_HASH=\$6\$[A-Za-z0-9./]{8,}|PASSWORD=[^[:space:]]+)' <<< "$text" | sed "s|^|   $label: answers value: |"
        found=1
    fi
    return "$found"
}

if [[ $MODE == staged ]]; then
    say 'secret scan (staged files)'
    need git
    staged=$(git diff --cached --name-only --diff-filter=ACM)
    if [[ -z $staged ]]; then
        printf '   nothing staged\n'
        exit 0
    fi
    failed_scan=0
    while IFS= read -r file; do
        # Read the staged content, not the working copy, so the scan matches the commit.
        content=$(git show ":$file" 2>/dev/null || true)
        if ! scan_text "$file" "$content"; then
            failed_scan=1
        fi
    done <<< "$staged"
    if (( failed_scan )); then
        printf '\ncommit blocked: remove the material above, then stage again\n' >&2
        exit 1
    fi
    pass
    exit 0
fi

need bash shellcheck

say 'syntax'
for f in install.sh lib/*.sh [0-9]*.sh tests/*.sh; do
    if bash -n "$f"; then
        :
    else
        fail "bash -n $f"
    fi
done
(( FAILED == 0 )) && pass

say 'lint'
if shellcheck -x -s bash install.sh lib/*.sh [0-9]*.sh tests/*.sh; then
    pass
else
    fail 'shellcheck reported findings'
fi

say 'unit tests'
if bash tests/unit.sh; then
    pass
else
    fail 'unit tests failed'
fi

say 'secret scan (working tree, tracked files)'
tracked=$(git ls-files 2>/dev/null || true)
if [[ -z $tracked ]]; then
    tracked=$(find . -type f -not -path './.git/*' -printf '%P\n')
fi
secret_hits=0
while IFS= read -r file; do
    [[ -f $file ]] || continue
    content=$(cat -- "$file")
    if ! scan_text "$file" "$content"; then
        secret_hits=1
    fi
done <<< "$tracked"
if (( secret_hits )); then
    fail 'secret material found in tracked files'
else
    pass
fi

say 'result'
if (( FAILED )); then
    printf 'checks FAILED; do not commit yet\n' >&2
    exit 1
fi
printf 'all checks passed\n'
