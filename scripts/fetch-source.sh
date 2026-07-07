#!/bin/bash
# fetch-source.sh — download the pinned Debian chromium source package
# into the chroot's /build directory and verify checksums.
#
# Usage: scripts/fetch-source.sh [CHROOT_DIR]
#
# Source lineage: bookworm-security. The Debian security team rebases
# chromium onto each upstream stable, so bookworm-security carries the
# SAME upstream version as sid (verified 2026-07-07: both 150.0.7871.46)
# while remaining buildable with bookworm's toolchain (llvm-19
# 1:19.1.7-3~deb12u1, rustc-web 1.85). When bumping: update VERSION and
# the three sha256 pins from
#   https://deb.debian.org/debian-security/dists/bookworm-security/main/source/Sources.xz

set -euo pipefail

CHROOT="${1:-/home/alex/chromium-build/chroot}"
DEST="$CHROOT/build"

VERSION="150.0.7871.46"
DEBREV="1~deb12u1"
POOL="https://deb.debian.org/debian-security/pool/updates/main/c/chromium"

declare -A SHA256=(
    ["chromium_${VERSION}-${DEBREV}.dsc"]="7c05f02b15901afe7d92f0a0706dc7db334226322b4882152608e3b2a4da81a8"
    ["chromium_${VERSION}.orig.tar.xz"]="a3fcaf6dea387ae603ff4228017a13e1ddb4de2ae074bd61a75520ef4c7d7a0a"
    ["chromium_${VERSION}-${DEBREV}.debian.tar.xz"]="3014d36dd55bc35a05064ba6e8db70fc19dffcac3f548d9a857a05af8df6a510"
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
