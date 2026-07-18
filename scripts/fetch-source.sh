#!/bin/bash
# fetch-source.sh — download the pinned Debian chromium source package
# into the chroot's /build directory and verify checksums.
#
# Usage: scripts/fetch-source.sh [CHROOT_DIR]
#
# Source lineage: bookworm-security. The Debian security team rebases
# chromium onto each upstream stable, so bookworm-security carries the
# SAME upstream version as sid
# while remaining buildable with bookworm's toolchain (llvm-19
# 1:19.1.7-3~deb12u1, rustc-web 1.85). When bumping: update VERSION and
# the three sha256 pins from
#   https://deb.debian.org/debian-security/dists/bookworm-security/main/source/Sources.xz

set -euo pipefail

CHROOT="${1:-/home/alex/chromium-build/chroot}"
DEST="$CHROOT/build"

VERSION="150.0.7871.124"
DEBREV="1~deb12u1"
POOL="https://deb.debian.org/debian-security/pool/updates/main/c/chromium"

declare -A SHA256=(
    ["chromium_${VERSION}-${DEBREV}.dsc"]="409ba2c744b1f61adc80b8f3ec9b58e42fbf51d0dc90f306369309101870e981"
    ["chromium_${VERSION}.orig.tar.xz"]="50f06f405618eda4a1d8b7399ad45985cab4eabf2ee9b5adeb80c0397ceb92c1"
    ["chromium_${VERSION}-${DEBREV}.debian.tar.xz"]="00fe596b8eec531ea805d516f144c0159cd1c6717e5c216f585dc732f9162a8f"
)

mkdir -p "$DEST"
for f in "${!SHA256[@]}"; do
    if ! echo "${SHA256[$f]}  $DEST/$f" | sha256sum -c - 2>/dev/null; then
        echo "fetching $f"
        curl -fL --retry 3 -o "$DEST/$f" "$POOL/$f"
        echo "${SHA256[$f]}  $DEST/$f" | sha256sum -c -
    fi
done

echo "source in place: $DEST"
