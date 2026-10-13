#!/usr/bin/env bash
# Runs build.sh inside the manylinux_2_28 image for the target, which pins the glibc baseline.
set -euo pipefail

usage="usage: build-in-container.sh <linux-x64|linux-arm64> <out-dir>"
repo=$(cd "$(dirname "$0")/.." && pwd)
rid=${1:?$usage}
mkdir -p "${2:?$usage}" && out=$(cd "$2" && pwd)
case "$rid" in
    linux-x64) image=quay.io/pypa/manylinux_2_28_x86_64; platform=linux/amd64 ;;
    linux-arm64) image=quay.io/pypa/manylinux_2_28_aarch64; platform=linux/arm64 ;;
    *) echo "$usage" >&2; exit 2 ;;
esac

docker run --rm --platform "$platform" -v "$repo:/repo:ro" -v "$out:/out" "$image" \
    bash -c "bash /repo/scripts/install-build-deps.sh && bash /repo/scripts/build.sh $rid /out"
