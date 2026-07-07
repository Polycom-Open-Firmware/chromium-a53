#!/bin/bash
# inner-build.sh — runs INSIDE the bookworm chroot (invoked by build.sh).
# Unpacks the pinned source, installs cross build-deps, applies the
# recipe patch, stamps a +op local version and cross-builds for arm64
# with Debian's "cross" build profile (QEMU-assisted, see
# debian/patches/debianization/cross-build.patch in the source).

set -euxo pipefail

JOBS="${JOBS:-10}"
cd /build

SRC_DIR=$(ls -d chromium-*/ 2>/dev/null | head -1 || true)
if [ -z "$SRC_DIR" ]; then
    dpkg-source -x chromium_*.dsc
    SRC_DIR=$(ls -d chromium-*/ | head -1)
fi
cd "$SRC_DIR"

# Cross build-deps: arm64 (host-arch) library stacks via multiarch,
# :native tools for amd64, cross-exe-wrapper:arm64 from the pinned
# local repo. Idempotent — the generated chromium-cross-build-deps
# metapackage stays installed.
if ! dpkg -s chromium-cross-build-deps >/dev/null 2>&1; then
    mk-build-deps -i -r \
        -t 'apt-get -y --no-install-recommends' \
        --host-arch arm64 -Pcross \
        debian/control
fi

# Recipe patch (A53 tuning + pinned accel args + cross esbuild fix);
# marker-guarded so a tree patched by an OLDER recipe fails loudly here
# (wipe the tree and re-extract rather than mixing patch generations).
if ! grep -q 'chromium-a53 recipe v2' debian/rules; then
    patch -p1 < /build/patches/op-a53-debian.patch
fi

# Local version suffix so our build sorts above stock Debian and is
# identifiable in the wild: 150.x-1~deb12u1 -> 150.x-1~deb12u1+op1
if ! dpkg-parsechangelog -S Version | grep -q '+op'; then
    DEBFULLNAME="Polycom Open Firmware" DEBEMAIL="noreply@github.com/Polycom-Open-Firmware" \
        dch --local +op --distribution bookworm \
        "Cross-build for Polycom TC8 (cortex-a53 tuning + V4L2/HEVC pins; see Polycom-Open-Firmware/chromium-a53)."
fi

# terse: one ninja status line per target instead of full command lines
# (full -v logging would produce a multi-GB log).
# nocheck: no test suites on this multi-hour build.
export DEB_BUILD_OPTIONS="parallel=${JOBS} nocheck terse"

dpkg-buildpackage -b --host-arch arm64 -Pcross -us -uc

echo "inner build complete"
ls -la /build/*.deb
