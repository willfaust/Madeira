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
