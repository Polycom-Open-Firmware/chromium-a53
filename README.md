# chromium-a53

Recipe (not a fork) for building a hardware-accelerated Chromium for the
**Polycom TC8** panel: Debian's `chromium` source package, cross-built
amd64→arm64, tuned for Cortex-A53 and the TC8's etnaviv GPU + Hantro VPU.
Milestone **M5** of `polycom_dev/PROFILES-PLAN.md`; the runtime side ships
as the `op-app-chromium` deb via the org apt repo.

## Target hardware

| | |
|---|---|
| SoC | NXP i.MX8M Mini, 4× Cortex-A53 @ 1.8 GHz (armv8-a + crc, **no crypto extensions** — NXP did not license them; `/proc/cpuinfo`: `fp asimd evtstrm crc32 cpuid`) |
| RAM | 2 GiB |
| GPU | Vivante GC NanoUltra, mainline **etnaviv** + Mesa (GLES2-class) |
| VPU | **Hantro** G1 (H.264/VP8) + G2 (HEVC/VP9), mainline **V4L2 stateless** (request API) decoders |
| Display | 800×1280 portrait panel, Wayland compositor **cage** |
| OS | Debian 12 bookworm arm64 (sealed rootfs, see tc8-firmware-build) |

## Source lineage: why Debian bookworm-security

We rebuild **Debian's `chromium` source package from bookworm-security**
rather than a depot_tools upstream checkout:

- **Modern and secure.** The Debian security team rebases chromium onto
  every upstream stable. Verified 2026-07-07: bookworm-security ships
  **150.0.7871.46-1~deb12u1** — the *same upstream milestone as sid*
  (150.0.7871.46-1). There is nothing more modern to gain from sid, and
  bookworm-security is guaranteed to keep building against the bookworm
  toolchain our images use (LLVM 19 was backported to bookworm as
  `1:19.1.7-3~deb12u1`, Rust as `rustc-web` 1.85 — exactly for this).
- **Packaging + security lineage for free.** `apt upgrade` semantics,
  the `/usr/bin/chromium` launcher with its `/etc/chromium.d` flag
  mechanism, sandbox setuid handling, system-library unbundling, and a
  version stream we can rebase by bumping three sha256 pins in
  `scripts/fetch-source.sh`.
- **No 100 GB source dance.** ~950 MB orig tarball instead of a
  depot_tools/gclient checkout.
- Debian's arm64 config already carries the two most important choices
  for this device: `use_v4l2_codec=true` and `use_vaapi=false`.

Our builds append a `+op1` local suffix
(`150.0.7871.46-1~deb12u1+op1`), so they sort above stock Debian and are
identifiable in `chrome://version`.

## Cross-build approach

Debian's chromium supports cross builds natively via the **`cross` build
profile** (`debian/patches/debianization/cross-build.patch`, by the
Debian maintainers). It is a *single-configuration* build: every object
is compiled for arm64 with bookworm's multiarch library stack as an
implicit sysroot, and the handful of build-time tools that must execute
(V8 `mksnapshot`, `protoc`, `wayland-scanner`, `bindgen`, brotli, …) run
under **qemu-user** through `aarch64-linux-gnu-cross-exe-wrapper`
(`HOST_EXEC_WRAPPER`). This avoids maintaining two overlapping GN
toolchain configs and — unlike a full qemu-emulated native build — only
pays emulation cost on a few one-shot tools.

Environment: a **debootstrapped bookworm amd64 chroot** (plain chroot,
not sbuild/pbuilder — the chroot is persistent and reused across builds;
build-deps alone are ~10 GB of multiarch packages and re-installing them
per build would dominate iteration time). `cross-exe-wrapper` does not
exist in bookworm, so its arm64 .deb from sid (a tiny arch-qualified
shell script + test binary, pinned by sha256) is served to apt from a
local `file:/` repo inside the chroot.

```
scripts/setup-chroot.sh   # debootstrap + multiarch + qemu-user + wrapper (idempotent)
scripts/fetch-source.sh   # pinned .dsc/.orig/.debian.tar.xz, sha256-verified
scripts/build.sh          # host-side driver: mounts, patch, detachable build
scripts/inner-build.sh    # in-chroot: mk-build-deps -Pcross, dch +op, dpkg-buildpackage
patches/op-a53-debian.patch  # the whole recipe delta (debian/rules)
op-app-chromium/          # arch:all deb with the /etc/chromium.d runtime flags
```

### Running a build

```sh
sudo scripts/setup-chroot.sh /home/alex/chromium-build/chroot   # once
scripts/fetch-source.sh /home/alex/chromium-build/chroot
sudo setsid nohup scripts/build.sh > /home/alex/chromium-build/build.log 2>&1 &
```

Progress: ninja emits `[N/TOTAL]` lines —
`grep -o '\[[0-9]*/[0-9]*\]' build.log | tail -1`. Artifacts land in
`/home/alex/chromium-build/out/`.

## Build configuration (GN) and why

Debian's arm64 baseline already provides (see `debian/rules`):

| arg | rationale for the TC8 |
|---|---|
| `use_v4l2_codec=true` | compiles `media/gpu/v4l2`: the V4L2 decode stack incl. the **stateless** backend + H.264/VP8/VP9 delegates. This is the Hantro path. |
| `use_vaapi=false` | no VA-API hardware; also flips the runtime feature default (see below). |
| `is_official_build=true` | full release optimization set. |
| `use_thin_lto=false` | Debian's choice, kept deliberately: ThinLTO on ~90k TUs costs hours of extra build plus multi-GB link-time peaks; not worth it for a kiosk on a 30 GiB builder. Linking uses **lld** (clang default) with GN's RAM-based `concurrent_links` throttle — no gold, no component build. |
| `symbol_level=0` | no debug info; keeps objects and links small (RAM budget at link time). |
| `proprietary_codecs=true` + `ffmpeg_branding="Chrome"` | H.264/AAC/… demux + software fallback. |
| system clang-19 / rustc-web 1.85 / lld / system libs | bookworm toolchain, security-supported. |

Two cross-build environment fixes ride along (both are "tool must RUN at
build time but resolved to the host arch" bugs in the bookworm packaging
that only bite under `-Pcross`; both reduce to the native behavior in a
native build, so both are upstreamable):

- **esbuild**: `debian/control`'s unqualified `esbuild` build-dep
  resolves to arm64, and it is not routed through `HOST_EXEC_WRAPPER`.
  The recipe patches the rules to take the node module from
  `DEB_HOST_MULTIARCH` and pins `ESBUILD_BINARY_PATH=/usr/bin/esbuild`,
  while `setup-chroot.sh` dpkg-diverts `/usr/bin/esbuild` to a
  sha256-pinned, version-matched amd64 binary so bundling runs natively.
- **bindgen**: bookworm's rules vendor a snapshot bindgen deb and
  extract the `DEB_HOST_ARCH` copy; the arm64 binary can't dlopen the
  amd64 `libclang-19.so.1` (control itself says `bindgen:native`). The
  recipe extracts the `DEB_BUILD_ARCH` copy instead.

The build environment additionally benefits from qemu binfmt for the
few host-arch tools Debian doesn't wrap (`rustfmt-web:arm64`, V8
`mksnapshot` etc. go through the wrapper, but check any new tool on a
version bump).

The recipe patch (`patches/op-a53-debian.patch`) adds, arm64-only:

| delta | rationale |
|---|---|
| `CFLAGS/CXXFLAGS += -mcpu=cortex-a53` | schedule for the A53's in-order, dual-issue pipeline (GN has no `arm_cpu` knob for arm64 — only 32-bit arm has one — so it goes in via the unbundle toolchain's env flags). LLVM's `cortex-a53` model is armv8-a+crc+fp+neon **without** aes/sha2, matching i.MX8MM silicon exactly — no illegal-instruction risk, and crypto stays on BoringSSL's runtime-dispatched NEON paths. |
| `enable_hevc_parser_and_hw_decoder=true` | builds the V4L2 **stateless H.265 delegate** for the Hantro G2. This *is* the M150 Linux default (`media/media_options.gni`: `proprietary_codecs && is_linux`), pinned so a future rebase can't silently drop HEVC. |
| `v8_enable_pointer_compression=true` | 32-bit tagged pointers inside a 4 GB heap cage — the single biggest V8 memory lever on a 2 GiB device. Also the 64-bit default, pinned for the same reason. |

Deliberately **not** changed:

- `arm_control_flow_integrity` stays `"standard"` (PAC/BTI are
  hint-space NOPs on v8.0 A53 — free forward-compat).
- Ozone: upstream Linux default already builds both Wayland and X11
  backends; platform choice is a runtime flag. Not worth a source patch
  to strip X11.
- ANGLE/Vulkan/SwiftShader stay at defaults — the GL backend decision is
  runtime-evaluable (below); pruning them buys build time but removes
  the fallbacks we may need on the bench.
- No AV1 hardware decode args: Hantro on i.MX8MM has no AV1; dav1d
  software decode remains for small resolutions.

## Runtime flags (`op-app-chromium` → `/etc/chromium.d/60-op-a53-hwaccel`)

Debian's launcher sources `/etc/chromium.d/*`; the wrapper package bakes
in (full comments in the file itself):

| flag | why |
|---|---|
| `--ozone-platform=wayland` | native Wayland under cage; default is still X11-first selection. |
| `--enable-features=AcceleratedVideoDecoder` | **the** V4L2 switch. Feature string of `media::kAcceleratedVideoDecodeLinux`, which is default-OFF in non-VAAPI Linux builds (`media/base/media_switches.cc`). Everything else in the chain is already default-ON at M150: `AcceleratedVideoDecodeLinuxGL` (allows HW decode with a GL context — we have no Vulkan) and `AcceleratedVideoDecodeLinuxZeroCopyGL` (dmabuf import via `EGL_EXT_image_dma_buf_import`, which etnaviv provides). |
| *(no stateless flag needed)* | Chromium probes the decoder driver: Hantro advertises `*_SLICE`/`*_FRAME` OUTPUT formats, so the stateless `V4L2VideoDecoder` is selected automatically (`IsV4L2DecoderStateful()`, `media/gpu/v4l2/v4l2_utils.cc`); non-ChromeOS Linux scans plain `/dev/video*` (`v4l2_device.cc`). |
| `--ignore-gpu-blocklist` | Vivante/etnaviv is not on Chromium's allowlists. |
| `--enable-gpu-rasterization` | raster on the GPU (Debian default-flags also sets it). |

**GL/ANGLE decision — deferred to bench.** The file leaves ANGLE's
backend auto-selection in place. On first hardware run, check
`chrome://gpu`; if it reports SwiftShader, evaluate in order
`--use-angle=gles` (ANGLE passthrough on native GLES — etnaviv's native
API, preferred), then `--use-angle=gl` (desktop GL 2.1 compat path).
Risk noted below: ANGLE's GLES backend prefers ES 3.0; GC NanoUltra is
ES2-class, so the winning combination may be `gl`, or GPU compositing
with the video overlay path and no GPU raster. This is exactly the M5
bench-eval question (PROFILES-PLAN: "etnaviv + Chromium = check
ozone/GL path").

## Budget & timings

- Builder: 12-core amd64, 30 GiB RAM + 8 GiB swap. Build runs
  `nice -n 10` with **ninja `-j10`** (leave 2 cores for the box).
- Disk: chroot + build-deps ≈ 10 GB, source tree ≈ 7 GB unpacked,
  out/Release ≈ 40–80 GB. Keep ≥ 150 GB free.
- Wall clock: the arch build is **80,320 ninja targets**; first build
  (2026-07-07, this box) opened at ≈ 8 targets/s in the early phase →
  expect **3–6 h** to the debs (compile skews fast early, the final lld
  links and dh_install skew slow; qemu-emulated one-shot tools add
  minutes, not hours). Link phase peaks ≈ 10 GB RSS per lld link; GN's
  `concurrent_links` auto-throttles by RAM.
- Failed/interrupted builds **resume**: every stage of
  `inner-build.sh` is guarded (source unpack, build-deps, patch, dch)
  and ninja is incremental — re-running `build.sh` continues where it
  stopped. Caveat: the resume goes back through
  `override_dh_auto_configure` (unbundle/shim regeneration), which
  re-stamps large parts of the graph — expect ninja to re-run stamps
  and cheap actions but reuse compiled objects. (Improvement TODO:
  ninja-only fast path for resumes.)
- Transient clang segfaults were observed once under full parallel
  load on WSL2 (single TU, clean when recompiled in isolation) — the
  resume path above is the remedy; if they recur, lower `JOBS`.
- Rebase cost: bump `VERSION` + three sha256 pins in
  `fetch-source.sh`, re-run. The chroot and its build-deps persist.

## Open risks

- **HEVC on the bench**: the stateless H.265 delegate builds and Hantro
  G2 exposes `HEVC_SLICE`, but desktop-Linux V4L2 HEVC is the
  least-exercised combination upstream — treat as "verify on hardware",
  H.264/VP8/VP9 are the well-trodden paths.
- **ANGLE on ES2-class GPU**: see GL/ANGLE decision above; worst case is
  SwiftShader raster with HW video decode still active (decode is
  independent of raster backend, needs only EGL+dmabuf for zero-copy).
- **GPU sandbox vs /dev/video***: the desktop-Linux GPU-process sandbox
  broker allowlists VAAPI render nodes but not necessarily V4L2 decoder
  nodes; if decode fails with EPERM on the bench, verify with
  `--disable-gpu-sandbox`, then carry a small sandbox broker allowlist
  patch (`sandbox/policy/linux/bpf_gpu_policy_linux.cc`) in the next
  recipe rev rather than shipping with the sandbox off.
- **2 GiB RAM**: pointer compression is pinned, but a modern Chromium +
  cage on 2 GiB wants a bench pass over `chrome://memory` /
  `memory.pressure`; candidates if tight: `--renderer-process-limit=2`,
  `--in-process-gpu` (evaluate, don't preempt).
- **Cross profile drift**: the `cross` profile is maintainer-supported
  but not exercised by Debian buildds; a future security rebase could
  break it — the recipe pins exact versions, so breakage never surprises
  us mid-release.
- **`dpkg-buildpackage -b` builds arch:all too** (chromium-l10n needs
  `packed_resources`); if indep-under-cross ever misbehaves, switch to
  `-B` and pull l10n from Debian (it's locale .paks, arch/ABI-neutral —
  but version-locked, so prefer keeping `-b`).

## Publishing

Not wired yet (matches org status): CI is a **manual-dispatch sketch**
for a future self-hosted runner, uploads debs as artifacts only. When
apt-repo publishing goes live, dispatch `Polycom-Open-Firmware/apt`
(single writer) exactly like the `packages` repo does. **Never** attach
an auto-build-on-push trigger to this repo — builds are hours long.
