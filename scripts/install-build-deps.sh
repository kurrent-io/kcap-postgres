#!/usr/bin/env bash
# Installs what build.sh needs on a manylinux_2_28 image; CI and build-in-container.sh both run it.
set -euo pipefail

dnf install -y -q zlib-devel bison flex perl file >/dev/null
