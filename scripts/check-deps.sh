#!/usr/bin/env bash
# Fails when anything in an extracted kcap-postgres tree would load a library outside the tree
# or the base OS, or (Linux) needs a newer glibc than the manylinux_2_28 baseline.
set -euo pipefail

root=$(cd "${1:?usage: check-deps.sh <dir>}" && pwd)
failures=0
fail() { echo "check-deps: $*" >&2; failures=$((failures + 1)); }

check_linux() {
    local f=$1 needed runpath glibc
    readelf -h "$f" >/dev/null 2>&1 || return 0
    while read -r needed; do
        [[ $needed =~ ^(libc\.so\.6|libm\.so\.6|libdl\.so\.2|libpthread\.so\.0|librt\.so\.1|libz\.so\.1|ld-linux[^/]*\.so\.[0-9]+|libpq\.so\.5)$ ]] \
            || fail "${f#"$root"/} needs $needed"
    done < <(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
    runpath=$(readelf -d "$f" | sed -n 's/.*(R\(UN\)\{0,1\}PATH).*\[\(.*\)\]/\2/p')
    # shellcheck disable=SC2016 # $ORIGIN is the literal the dynamic loader expands
    [[ -z $runpath || $runpath == '$ORIGIN/../lib' ]] || fail "${f#"$root"/} has runpath $runpath"
    glibc=$(objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1 || true)
    [[ -z $glibc || $(printf '%s\n2.28\n' "$glibc" | sort -V | tail -1) == 2.28 ]] \
        || fail "${f#"$root"/} needs glibc $glibc"
}

check_macos() {
    local f=$1 dep minos
    file -b "$f" | grep -q 'Mach-O' || return 0
    while read -r dep; do
        if [[ $dep =~ ^@loader_path/\.\./lib/([^/]+)$ ]]; then
            [[ -e $root/lib/${BASH_REMATCH[1]} ]] || fail "${f#"$root"/} needs missing $dep"
        elif [[ ! $dep =~ ^/usr/lib/(libSystem\.B|libz\.1)\.dylib$ ]]; then
            fail "${f#"$root"/} needs $dep"
        fi
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
    minos=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}')
    [[ -z $minos || $(printf '%s\n%s\n' "$minos" "$MIN_MACOS" | sort -V | tail -1) == "$MIN_MACOS" ]] \
        || fail "${f#"$root"/} requires macOS $minos"
    codesign -v "$f" 2>/dev/null || fail "${f#"$root"/} has no valid signature"
}

MIN_MACOS=$(sed -n 's/^MACOSX_DEPLOYMENT_TARGET=//p' "$(dirname "$0")/../versions.env")
case "$(uname -s)" in
    Linux) checker=check_linux ;;
    Darwin) checker=check_macos ;;
    *) echo "check-deps: unsupported OS $(uname -s)" >&2; exit 2 ;;
esac
while IFS= read -r -d '' f; do "$checker" "$f"; done < <(find "$root/bin" "$root/lib" -type f -print0)

[[ $failures -eq 0 ]] || { echo "check-deps: $failures violation(s)" >&2; exit 1; }
echo "check-deps: OK"
