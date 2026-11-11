# KosmicKrisp (Mesa's Vulkan on Metal) for iOS

Status 2026-10-12: **builds for iOS.** `libvulkan_kosmickrisp.dylib` (arm64, iOS 26.0 minimum, SDK 26.5)
is built on this PC (Windows + WSL + xtool SDK). It needed two small Mesa fixes. A third patch makes it
usable without a Vulkan loader. **It has not run on a device.** It is not staged in `app/Madeira/gl/`
yet, so the IPA is unchanged.

## What KosmicKrisp is

- KosmicKrisp is a Vulkan 1.4 driver from LunarG and Google, at `src/kosmickrisp` in Mesa. It turns
  SPIR-V into NIR and NIR into MSL source. Metal 4's `MTL4Compiler` compiles that source at run time.
  Its internal OpenCL C kernels (draws, geometry, tessellation, queries) are turned into MSL at build
  time by `kk_clc`.
- It was merged for Mesa 25.3. Newest release used here: **Mesa 26.2.4** (2026-10-01). The tarball's
  sha256 is `bce5f7fbebb934373b86c999a064d52fb5065878dc57f287f95346648ec832e9`. It matches the value in
  docs.mesa3d.org/relnotes/26.2.4.html.
- Upstream requirements (docs.mesa3d.org/drivers/kosmickrisp.html):
  - Metal 4, which means macOS 26.
  - Apple Silicon. The authors considered A14 and newer.
  - The docs say "No iOS support is present as of now."
  - Upstream build: `meson setup -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers=
    -Dopengl=false -Dzstd=disabled`, with meson >= 1.9.1, LLVM >= 20.1.8, libclc,
    SPIRV-LLVM-Translator and SPIRV-Tools.
- Device selection (`bridge/mtl_device.m`): it takes the first device from `MTLCopyAllDevices()` that
  `supportsFamily:MTLGPUFamilyMetal4`. iOS has `MTLCopyAllDevices` from 18.0. Metal 4 means an iOS 26
  device with an A14 or newer.
- It reports vendorID 0x106b, deviceID 100 and conformance version 1.4.3.2.
- Debug switch: `MESA_KK_DEBUG=nir,msl,force_robustness`.

## Building (build/mesa-ios/build-kosmickrisp.sh)

The build has two steps. Every Mesa driver with OpenCL C helper kernels needs three compilers that run
on the build machine:

| Tool | Job |
|------|-----|
| `mesa_clc` | OpenCL C to SPIR-V. Needs clang, SPIRV-LLVM-Translator and SPIRV-Tools. |
| `vtn_bindgen2` | SPIR-V to C bindings. |
| `kk_clc` | SPIR-V to precompiled MSL. |

1. **Native build** (`$KK_WORK/build-native`). It builds only those three tools, with
   `-Dmesa-clc=enabled -Dprecomp-compiler=enabled -Dmesa-clc-bundle-headers=enabled`, and copies them to
   `$KK_WORK/host-tools/bin`. On Linux, KosmicKrisp's Metal bridge compiles from its `stubs/`, so the
   native configure works. Only the three tools are built.
2. **iOS cross build** (`$KK_WORK/build-ios`).
   - Cross file: `build/mesa-ios/kosmickrisp-ios-arm64.cross`, modelled on the OSMesa one, with
     `-miphoneos-version-min=26.0`.
   - Options: `-Dmesa-clc=system -Dprecomp-compiler=system` (the tools come from a native file),
     `-Dplatforms=macos` (this enables the Metal WSI, `VK_EXT_metal_surface`; the code is CAMetalLayer
     code, so it works on iOS too), `-Dllvm=disabled`, no gallium, no GL, no zstd, no xmlconfig, no
     shader cache.
   - The script then copies the dylib out, sets its install name to `@rpath/libvulkan_kosmickrisp.dylib`
     and runs `strip -x`.
   - Output: `$KK_WORK/out/libvulkan_kosmickrisp.dylib`.

Run from WSL (the paths are this PC's):

```sh
source "/mnt/c/Users/Nick/Desktop/Code/Madeira fork/Madeira/.xtool/upstream-build/env.sh"
export KK_LLVM_CONFIG=$HOME/.cache/mesa-kk/hostdeps/llvm-21/bin/llvm-config
export KK_HOST_PKG_CONFIG_PATH=$HOME/.cache/mesa-kk/hostdeps/pc
bash "$MAIN/build/mesa-ios/build-kosmickrisp.sh"     # KK_WORK defaults to ~/.cache/mesa-kk
```

**Host dependencies on this PC (no sudo).**
- Ubuntu 26.04 already has `llvm-21-dev`. These packages were fetched with `apt-get download` from the
  Ubuntu archive and unpacked with `dpkg -x` into `~/.cache/mesa-kk/hostdeps/root`:
  - `libclang-21-dev`
  - `libclang-common-21-dev` (the resource dir with `opencl-c.h`)
  - `libclang-cpp21-dev`
  - `libllvmspirvlib-21-dev` and `libllvmspirvlib21.1`
  - `spirv-tools-dev`, `spirv-tools-headers` and `spirv-headers`
- `~/.cache/mesa-kk/hostdeps/llvm-21` is a symlink farm: `/usr/lib/llvm-21` plus the unpacked clang files,
  with a real copy of `llvm-config`, so `llvm-config` reports the farm as its prefix.
- `hostdeps/pc` holds `SPIRV-Tools.pc`, `LLVMSPIRVLib.pc` and `SPIRV-Headers.pc`, with their prefixes
  rewritten to the unpacked tree.
- On a Mac, Homebrew's llvm, spirv-llvm-translator and spirv-tools give the same result.
- A clean build from a fresh tarball takes about 2 minutes once the host tools exist. The result is
  byte-identical to the first build.
- Each run relinks about 40 objects, because `mesa_clc`'s depfile names the bundled OpenCL headers under
  a temporary path. This is upstream behaviour and harmless.

**iOS-specific failures and their fixes.** The Metal bridge itself compiled for iOS unchanged, Metal 4
`MTL4*` API included. Only these needed fixing:
1. `src/vulkan/wsi/wsi_common_metal_layer.m` set `CAMetalLayer.displaySyncEnabled`, and iOS marks that
   unavailable. That was a compile error.
   - Patch: `patches/kosmickrisp-ios-0001-wsi-metal-no-display-sync-on-ios.patch` skips it outside
     `TARGET_OS_OSX`.
   - Effect: an IMMEDIATE-mode swapchain presents with vsync on iOS.
2. Upstream links the driver with `-undefined dynamic_lookup` and names only Metal and QuartzCore. That
   left Foundation classes, CoreGraphics colour spaces and `objc_msgSend` as flat-namespace lookups.
   - Patch: `patches/kosmickrisp-ios-0002-link-system-frameworks.patch` links Foundation, CoreGraphics
     and libobjc.
   - Result: the only flat lookups left are about 2990 *weak imports*: `kk_*`, `vk_common_*`, `wsi_*`
     and `vk_cmd_enqueue_*` entry points that the driver does not implement. dyld binds these to NULL,
     and the runtime's dispatch tables then fall through to the common implementation, as on macOS.
   - Neither `libOSMesa.dylib` nor `libMoltenVK.dylib` exports any of those names, so the lookups cannot
     land in another bundled library.

3. This one is not a build fix. `patches/kosmickrisp-ios-0003-export-get-proc-addr-on-apple.patch`
   exports `vkGetInstanceProcAddr` and `vkGetDeviceProcAddr` on Apple platforms, wrapping
   `kk_GetInstanceProcAddr` and `vk_device_get_proc_addr`. With them, Wine's existing loading code can
   use the driver as its libvulkan unchanged (see below).

`build/mesa-ios/build.sh` (OSMesa) now applies only the numbered patches. `build-kosmickrisp.sh` applies
only `kosmickrisp-ios-*`. Each patch is described in `build/mesa-ios/patches/README.md`.

## The library

| | |
|---|---|
| File | `~/.cache/mesa-kk/out/libvulkan_kosmickrisp.dylib` (WSL) |
| Size | 13,680,992 bytes (13.0 MiB) stripped; about 1.9 MB with gzip -9, so roughly +2 MB in the IPA |
| sha256 | `9884f047911e7753c4222561751a0c8ec25b6d2c2f94b1ad8e6daf83a7e661c5` (a clean rebuild from the tarball is byte-identical) |
| Mach-O | arm64, `LC_BUILD_VERSION` platform ios, minos 26.0, sdk 26.5, chained fixups |
| Install name | `@rpath/libvulkan_kosmickrisp.dylib` |
| Links | Metal, QuartzCore, Foundation, CoreFoundation, CoreGraphics, libobjc, libc++, libSystem |

**IPA budget.** The last IPA was 147.6 MiB. Bundling this library costs about 2 MB compressed and 13 MiB
installed, so it can ship in the bundle under the 200 MB limit. An in-app download is not needed.

**To bundle it:**
1. Copy the library to `app/Madeira/gl/libvulkan_kosmickrisp.dylib`.
2. Add `libvulkan_kosmickrisp.version` (contents: `mesa-26.2.4`).
3. Mesa's licence is already staged at `app/Madeira/licenses/Mesa-license.rst`. KosmicKrisp is MIT, like
   the rest of that file.
4. The app build signs it like the other dylibs in `gl/`.

## Loader note for winevulkan (`vulkan = kosmickrisp`)

**Exports** (`llvm-nm -gU`):

| Symbol | Source |
|--------|--------|
| `vkGetInstanceProcAddr` | patch 0003; same function as `vk_icdGetInstanceProcAddr` |
| `vkGetDeviceProcAddr` | patch 0003; `vk_device_get_proc_addr` |
| `vk_icdGetInstanceProcAddr` | upstream, ICD interface |
| `vk_icdGetPhysicalDeviceProcAddr` | upstream, ICD interface |
| `vk_icdNegotiateLoaderICDInterfaceVersion` | upstream; returns `min(*v, 7)` and keeps no state |

No other `vk*` function is exported. A few internal names (`poly_*`, `libkk_AppleSilicon`) also leak
out. They are harmless.

**No Vulkan loader is needed.** The driver can be used directly as the process's single Vulkan library,
the way we were told NutsEmu uses its `libvulkan.1.dylib`. Wine's `win32u/vulkan.c`
`vulkan_init_once()` does exactly what the driver now supports:
- `dlopen(SONAME_LIBVULKAN)`
- `dlsym` of `vkGetInstanceProcAddr` and `vkGetDeviceProcAddr`
- `vkGetInstanceProcAddr(NULL, "vkCreateInstance")` and `vkEnumerateInstanceExtensionProperties`

So `vulkan = kosmickrisp` only has to make that `dlopen` open
`<bundle>/gl/libvulkan_kosmickrisp.dylib` instead of `libMoltenVK.dylib`. No other loading code is
needed. Details:

1. Calling `vk_icdNegotiateLoaderICDInterfaceVersion` first is allowed but not required.
2. With a NULL instance, `vkGetInstanceProcAddr` returns `vkCreateInstance`,
   `vkEnumerateInstanceExtensionProperties`, `vkEnumerateInstanceVersion` and itself.
   `vkEnumerateInstanceLayerProperties` comes back NULL, because Mesa leaves layers to the loader. A
   caller must treat NULL as "no layers".
3. Dispatchable handles already carry `ICD_LOADER_MAGIC`. Nothing has to patch them.
4. Surfaces: use `VK_EXT_metal_surface`, that is `vkCreateMetalSurfaceEXT` with a `CAMetalLayer`.
   - The driver also lists `VK_MVK_macos_surface`. MoltenVK's `VK_MVK_ios_surface` (UIView) is not
     offered.
   - Instance extensions offered: `KHR_surface`, `EXT_metal_surface`, `EXT_headless_surface`,
     `KHR_get_surface_capabilities2`, `KHR/EXT_surface_maintenance1`, `EXT_swapchain_colorspace`,
     `KHR_get_physical_device_properties2`, the external-* capabilities, `EXT_debug_report` and
     `EXT_debug_utils`.
5. KosmicKrisp is not a portability driver. It lists neither `VK_KHR_portability_enumeration`
   (instance) nor `VK_KHR_portability_subset` (device). Code written for MoltenVK must enable those
   only when they are listed. Requesting an unlisted extension fails with
   `VK_ERROR_EXTENSION_NOT_PRESENT`.
6. Without patch 0003 the same thing works by `dlsym(h, "vk_icdGetInstanceProcAddr")`. Then fetch
   `vkGetDeviceProcAddr` with `gipa(instance, "vkGetDeviceProcAddr")` after the first `vkCreateInstance`.

**When a Khronos loader would be needed.** Only for Vulkan layers (validation) or to put several
drivers behind one `libvulkan.1.dylib`. In that case:
- Build Vulkan-Loader for iOS. It supports Apple platforms, but this was not attempted.
- Build the meson target `kosmickrisp_mesa_icd`. The script does not build it. It produces a manifest
  with `api_version` 1.4; point its `library_path` at the bundled dylib.
- Set `VK_DRIVER_FILES` to the manifest.

## Not known yet (needs a device)

- Whether it runs on iOS 26 at all: `MTLCopyAllDevices`, `newMTL4CommandQueue`, residency sets and
  `MTL4Compiler` in an app sandbox. MoltenVK does the same kind of runtime MSL compilation through the
  out-of-process Metal compiler, so no JIT entitlement should be needed.
- Memory heap sizing. The heap is reported as total system memory and the budget comes from
  `recommendedMaxWorkingSetSize`. iOS jetsam limits are lower than RAM, so the reported heap size may
  need a patch.
- `maxBufferLength` limits on iOS GPUs for large `VkDeviceMemory` allocations.
- Present: CAMetalLayer, FIFO only (see patch 0001).
- No CTS run, no vkd3d-proton or DXVK run.

## Caches, archives, Fossilize and statistics (madeira-duo vk2, 9 Nov 2026)

Upstream KosmicKrisp keeps nothing between launches: it never opens Mesa's disk cache, creates no
implicit pipeline cache (so applications that pass no `VkPipelineCache`, like Path of Exile 2, get
no caching at all), and compiles every Metal pipeline without an archive. vk2 adds:

- `kosmickrisp-ios-0007`: the Mesa disk cache (built with `-Dshader-cache=enabled`) and an implicit
  pipeline cache, as RADV does. Repeat launches skip SPIR-V -> NIR -> MSL.
- `kosmickrisp-ios-0008`: Metal 4 pipeline archives. A `MTL4PipelineDataSetSerializer` collects every
  pipeline built; chunks (`*.mtl4a`) are written every 60 s while new pipelines are built and when
  the compiler is released, loaded at the next start-up and passed as `lookupArchives`. Unreadable
  chunks (e.g. after an iOS update) are deleted. Keys: `MADEIRA_KK_ARCHIVE=0` (off),
  `MADEIRA_KK_ARCHIVE_MB` (cap, default 1024), `MADEIRA_KK_ARCHIVE_FLUSH_S` (default 60),
  `MADEIRA_KK_ARCHIVE_DIR`. Also timing: `[kk-slow]` for library/pipeline builds of 150 ms or more,
  `[kk-compile]` totals with a duration histogram every 30 s (`MADEIRA_KK_COMPILE_STATS=0` off).
- `kosmickrisp-ios-0009`: `[kk-frame]` every 30 s (presents, present intervals with >33/50/100 ms
  counts, CPU time in queue submits, Metal GPU time per frame from commit feedback;
  `MADEIRA_KK_FRAME_STATS=0` off), and each present is reported to Madeira's frame counter
  (`madeira_vulkan_present_mark`, WiniosGL.m) so the FPS overlay and `[frame]` count Vulkan frames.
- WineProcessBridge: with `vulkan = kosmickrisp`, `MESA_SHADER_CACHE_DIR` defaults to
  `<prefix>/madeira-cache/kosmickrisp` (archives in its `kosmickrisp-mtl4/`), max 2G.

Fossilize (`madeira.cfg fossilize = record | replay | on | off`, default off; KosmicKrisp only):

- record: Vulkan goes through the Khronos loader (`gl/libvulkan.1.dylib`, build/vulkan-loader-ios),
  driver manifest `gl/vulkan/icd.d/kosmickrisp_icd.json`, capture layer `VK_LAYER_fossilize`
  (`gl/libVkLayer_fossilize.dylib`, build/fossilize-ios). Output:
  `<prefix>/madeira-cache/fossilize/capture.*.foz`.
- replay: before the session, every `.foz` there and in `import/` is replayed in-process
  (`gl/libfossilize_replay.dylib`, `fossilize_replay_main`) straight through KosmicKrisp, filling its
  disk cache and archives; `replayed.cache` skips what earlier replays built.
  `fossilize-threads` (default 4). The point: driver caches are invalidated by driver rebuilds
  (the disk cache key includes the driver build) and possibly by iOS updates (archives); the
  `.foz` recording survives both and rebuilds them before play.

## Unsupported features at device creation (patch 0010)

KosmicKrisp doesn't support these core features: `geometryShader`, `fillModeNonSolid`, `depthBounds`, `wideLines`,
`pipelineStatisticsQuery`, `shaderStorageImageMultisample`, `shaderFloat64`, `shaderResourceResidency`, sparse
binding and residency, and `variableMultisampleRate`. If an application enables any of them, `vkCreateDevice`
fails with `VK_ERROR_FEATURE_NOT_PRESENT`. Without a debug messenger, Mesa's explanation goes nowhere.

On 9 Nov 2026, PoE2 0.5 hit exactly that on the Duo. Client.txt shows `Failed to start device:
vk::PhysicalDevice::createDeviceUnique: ErrorFeatureNotPresent`, then `Falling back to DirectX11`, and the whole
session ran on DXMT.

Patch 0010 does two things:

- Every enabled core feature that isn't supported is logged as `[kk-features] <struct>.<feature> requested but not
  supported`.
- Mesa's own messages are switched on while the device is created, so failures in Vulkan 1.1+ and extension
  feature structures also name the field. A failed create logs `[kk-features] vkCreateDevice failed: <VkResult>`.

`MADEIRA_KK_RELAX_FEATURES=1` (madeira.cfg `env.`) drops the unsupported core 1.0 features from the request and
logs each one, so device creation can go ahead for applications that enable features they never use. If a dropped
feature is used anyway, the pipelines that need it fail to build. Look for `Failed to create MTL` and the game's
own errors.

## Large timestamp query pools (patch 0011)

Metal caps the number of entries in one `MTL4CounterHeap`. Above the cap, AGX logs `MTLCounterHeap: Invalid heap
size requested`. Upstream KosmicKrisp backs each `VK_QUERY_TYPE_TIMESTAMP` pool with a single heap. So on 9 Nov 2026,
with geometryShader relaxed (0010), PoE2 got past `vkCreateDevice` but failed `vkCreateQueryPool` with
`ErrorOutOfDeviceMemory` and fell back to DirectX 11 again.

Patch 0011 finds the largest heap size Metal accepts by halving the request. It remembers that size for the
process and spreads the pool over as many heaps as needed: query q lives in heap q / n at q % n. A split pool
logs `[kk-query] timestamp pool of N split into H counter heaps of n`.

## Timestamp pools without a counter heap (patch 0012)

On the Duo, Metal refuses *every* timestamp counter heap, even a 2-entry one: install32c logged `[kk-query]
timestamp pool of 2: no counter heap size works`. So 0011's split alone can't help there. Patch 0012 creates the
pool without a heap when that happens. `vkCmdWriteTimestamp2` marks the query available, and its value reads as
the 0 the reset left. This is logged once as `[kk-query] Metal refuses timestamp counter heaps here … timestamp
queries will read 0`. GPU timings the game derives from timestamps read as zero. A real fix would sample through
another Metal counter API that the phone does support.

## Pre-launch compile, progress and live counters (vk3, 10 Nov 2026)

- **Library ▸ any game ▸ Shaders** lists the size of each shader cache in the prefix: the Mesa cache, the Metal
  pipeline archives and the Fossilize recordings, plus the D3D12 caches. **Compile shaders now** replays the
  recorded pipelines through KosmicKrisp on every core before any game starts
  (`madeira_shader_precompile_start`). Progress shows as pipelines done of the total in the recordings, rate and
  time left. It comes from Fossilize patch 0003's `fossilize_replay_progress`. A game started during the compile
  waits for it, and the game-start replay is then skipped for that app run. The game-start replay now uses
  every core too (`fossilize-threads` still overrides; `fossilize-precompile-threads` does the same for the
  button).
- **Overlay ▸ Shader misses** shows totals since the overlay started, so the figures don't drop back to zero
  between bursts. On Vulkan: BUILT (builds that compiled, 2 ms or more), BUILD (builds running now) and SLOW
  (compiles of 150 ms or more since the game started). The source is patch 0013: KosmicKrisp reports every
  library and pipeline build to `madeira_vulkan_compile_mark` (WiniosGL.m). On D3D12: SHADERS (stages
  madeira-d3d12 converted), PSO (pipelines Metal compiled because the pso-archive didn't have them) and WAIT
  (pipelines the game waits on now, including pso-create-block builds inside a create call), provided this
  build's DXMT has `madeira_shader_overlay_stats` (looked up at run time; vk4 pins DXMT duo/overlay-shader).

## Compile-speed levers within the current design (patch 0014)

KosmicKrisp bakes pipeline state into its MSL, so these levers keep one library per stage and make each compile
cheaper or concurrent. Each has a switch, so one run can compare them:

- `MADEIRA_KK_COMPILE_QOS` (default 1): a thread compiling below user-initiated QoS is raised to user-interactive
  for the compile, then set back. Metal's compiler service runs a request at the requester's QoS.
- `MADEIRA_KK_PARALLEL_LIBS` (default 1): a render pipeline's vertex and fragment libraries compile at the same time.
- `MADEIRA_KK_OPT_SIZE` (default 0): `MTLLibraryOptimizationLevelSize`. Apple documents smaller binaries "which may
  also reduce compile time". Shader speed may drop, so measure it.
- `[kk-slow]` logs the compiling thread's QoS and the MSL size. `[kk-frame]` adds `feedback N (M untimed)`, to show
  why GPU time read 0 on the Duo.

## Giant generated shaders (patch 0015)

The install33c live log (11 Nov 2026) showed that 31 libraries with 0.5-1.5 MB of generated MSL took 227 of the 298 s
of library compiles, 4-24 s each. MSL size is what drives the time. `[kk-slow]` now adds `hash <fnv64 of the MSL>`.
The same hash in a later session means Metal's library cache didn't keep that library. Sources of at least
`MADEIRA_KK_DUMP_MSL_KB` (default 250; 0 = off) are written once to
`$MESA_SHADER_CACHE_DIR/msl-dump/<hash>.metal`, at most 64 files, so the generator can be studied. The compile QoS
raise (0014) now also lifts user-initiated threads: PoE2's loader runs at user-initiated, so 0014 left it alone.

Keep Madeira in the foreground while it compiles. In the background, Madeira holds the game under 50% of one core
(`[bg-run]`), and compiles practically stop.
