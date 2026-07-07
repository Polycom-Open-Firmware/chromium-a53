#!/bin/bash
# build.sh — cross-build Debian chromium for arm64 inside the bookworm
# chroot, producing .debs in OUT_DIR. Run setup-chroot.sh and
# fetch-source.sh first (build.sh re-runs both defensively).
#
# Usage: sudo scripts/build.sh [CHROOT_DIR]
#   JOBS=10   ninja parallelism (default 10 of 12 cores — keeps the box usable)
#   NICENESS=10  CPU niceness for the whole build
#   OUT_DIR=/home/alex/chromium-build/out
#
# Expect several hours. Run detached, e.g.:
#   sudo setsid nohup scripts/build.sh > /home/alex/chromium-build/build.log 2>&1 &
# Progress: ninja prints "[N/TOTAL]" lines; watch with
#   grep -o '\[[0-9]*/[0-9]*\]' /home/alex/chromium-build/build.log | tail -1

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CHROOT="${1:-/home/alex/chromium-build/chroot}"
OUT_DIR="${OUT_DIR:-/home/alex/chromium-build/out}"
JOBS="${JOBS:-10}"
NICENESS="${NICENESS:-10}"

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

"$HERE/setup-chroot.sh" "$CHROOT"
"$HERE/fetch-source.sh" "$CHROOT"

# recipe inputs into the chroot
mkdir -p "$CHROOT/build/patches"
cp "$HERE/../patches/"*.patch "$CHROOT/build/patches/"
cp "$HERE/inner-build.sh" "$CHROOT/build/inner-build.sh"

echo "=== build start: $(date -Is) (jobs=$JOBS nice=$NICENESS)"
chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive JOBS="$JOBS" \
    nice -n "$NICENESS" bash /build/inner-build.sh

mkdir -p "$OUT_DIR"
cp -v "$CHROOT"/build/*.deb "$CHROOT"/build/*.changes "$CHROOT"/build/*.buildinfo "$OUT_DIR/" 2>/dev/null || true
echo "=== build done: $(date -Is)"
ls -la "$OUT_DIR"
