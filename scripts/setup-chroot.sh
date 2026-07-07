#!/bin/bash
# setup-chroot.sh — create/refresh the bookworm amd64 chroot used to
# cross-build Debian's chromium for arm64 (Polycom TC8).
#
# Usage: sudo scripts/setup-chroot.sh [CHROOT_DIR]
# Idempotent: safe to re-run; each step checks before acting.
#
# Design: Debian's chromium packaging supports cross builds via the
# "cross" build profile (see debian/patches/debianization/cross-build.patch
# in the chromium source). It is a single-config build: everything is
# compiled FOR arm64, and the few build-time tools that must execute
# (mksnapshot, protoc, wayland-scanner, bindgen, ...) run under
# qemu-user via the $(triplet)-cross-exe-wrapper helper.
#
# cross-exe-wrapper is not in bookworm (it comes from src:architecture-
# properties, sid only), so we pin its tiny arm64 .deb by sha256 and
# serve it from a local file:/ repo inside the chroot so apt/mk-build-deps
# can resolve the <cross>-profile build-dependency.

set -euo pipefail

CHROOT="${1:-/home/alex/chromium-build/chroot}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
SEC_MIRROR="${SEC_MIRROR:-http://deb.debian.org/debian-security}"

# sid's cross-exe-wrapper, pinned. Re-pin when bumping: check
# https://deb.debian.org/debian/pool/main/a/architecture-properties/
CEW_DEB="cross-exe-wrapper_0.2.6+b2_arm64.deb"
CEW_URL="https://deb.debian.org/debian/pool/main/a/architecture-properties/$CEW_DEB"
CEW_SHA256="11e41ce2c3507a74103b4fc10b7eb9efe470c177e4cbfd329d0b87fb3e195b8e"

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

# 1. Base chroot ------------------------------------------------------------
if [ ! -e "$CHROOT/etc/debian_version" ]; then
    debootstrap --arch=amd64 bookworm "$CHROOT" "$MIRROR"
fi

cat > "$CHROOT/etc/apt/sources.list" <<EOF
deb $MIRROR bookworm main
deb $MIRROR bookworm-updates main
deb $SEC_MIRROR bookworm-security main
EOF

# host DNS (WSL2/laptops move around; refresh every run)
cp -L /etc/resolv.conf "$CHROOT/etc/resolv.conf"

# 2. Mounts (left mounted; build.sh reuses them) ----------------------------
mountpoint -q "$CHROOT/proc"    || mount -t proc proc "$CHROOT/proc"
mountpoint -q "$CHROOT/sys"     || mount -t sysfs sys "$CHROOT/sys"
mountpoint -q "$CHROOT/dev"     || mount --bind /dev "$CHROOT/dev"
mountpoint -q "$CHROOT/dev/pts" || mount --bind /dev/pts "$CHROOT/dev/pts"

in_chroot() {
    chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive "$@"
}

# 3. Multiarch + base tools --------------------------------------------------
in_chroot dpkg --add-architecture arm64
in_chroot apt-get update
in_chroot apt-get install -y --no-install-recommends \
    devscripts equivs dpkg-dev fakeroot \
    qemu-user \
    ca-certificates curl xz-utils patch

# 4. cross-exe-wrapper from sid (local pinned repo) --------------------------
mkdir -p "$CHROOT/opt/local-repo"
if [ ! -e "$CHROOT/opt/local-repo/$CEW_DEB" ]; then
    curl -fsSL "$CEW_URL" -o "$CHROOT/opt/local-repo/$CEW_DEB"
fi
echo "$CEW_SHA256  $CHROOT/opt/local-repo/$CEW_DEB" | sha256sum -c -

in_chroot sh -c 'cd /opt/local-repo && dpkg-scanpackages --multiversion . > Packages'
echo 'deb [trusted=yes] file:/opt/local-repo ./' \
    > "$CHROOT/etc/apt/sources.list.d/local.list"
in_chroot apt-get update

# apt resolves libc6:arm64 + qemu-user (M-A: foreign) for us
in_chroot apt-get install -y cross-exe-wrapper:arm64

# sid's wrapper looks for qemu-<debarch> (qemu-arm64, trixie+ naming);
# bookworm's qemu-user 7.2 only ships qemu-<qemuarch> (qemu-aarch64).
ln -sf /usr/bin/qemu-aarch64 "$CHROOT/usr/local/bin/qemu-arm64"

# 5. esbuild divert --------------------------------------------------------
# The `esbuild` build-dep is unqualified in debian/control, so -Pcross
# resolves it to the HOST arch (arm64) — but esbuild must RUN during the
# build (devtools bundling), and unlike protoc/mksnapshot it is not
# invoked through HOST_EXEC_WRAPPER. Divert /usr/bin/esbuild and install
# the version-matched amd64 binary so it executes natively. The recipe
# patch pins ESBUILD_BINARY_PATH=/usr/bin/esbuild to match.
ESB_DEB="esbuild_0.17.0-1+b2_amd64.deb"
ESB_URL="https://deb.debian.org/debian/pool/main/g/golang-github-evanw-esbuild/$ESB_DEB"
ESB_SHA256="8e268f457e822553fd8de26712c459682c9f21c3b529fdc181515647a128b3a8"
if ! in_chroot dpkg-divert --list /usr/bin/esbuild | grep -q esbuild; then
    in_chroot dpkg-divert --local --rename --divert /usr/bin/esbuild.distrib \
        --add /usr/bin/esbuild
fi
if [ ! -x "$CHROOT/usr/bin/esbuild" ] || \
   ! file -b "$CHROOT/usr/bin/esbuild" | grep -q x86-64; then
    curl -fsSL "$ESB_URL" -o "$CHROOT/opt/local-repo/$ESB_DEB"
    echo "$ESB_SHA256  $CHROOT/opt/local-repo/$ESB_DEB" | sha256sum -c -
    staging=$(mktemp -d)
    dpkg-deb -x "$CHROOT/opt/local-repo/$ESB_DEB" "$staging"
    install -m 0755 "$staging/usr/bin/esbuild" "$CHROOT/usr/bin/esbuild"
    rm -rf "$staging"
fi

# smoke test: the wrapper must be able to run an arm64 binary (ld.so
# complains "missing program name" — that complaint IS the success
# signal; ld.so's nonzero exit must not trip pipefail here).
if in_chroot sh -c 'aarch64-linux-gnu-cross-exe-wrapper /usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 2>&1 | grep -q "missing program name"'; then
    echo "cross-exe-wrapper smoke test OK"
else
    echo "cross-exe-wrapper smoke test FAILED (qemu path broken)" >&2
    exit 1
fi

mkdir -p "$CHROOT/build"
echo "chroot ready: $CHROOT"
