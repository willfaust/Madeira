# DXVK: Direct3D 10/11 on Vulkan (opt-in route)

Status 2026-10-13: **built, not device-tested.** DXMT (Direct3D 9/10/11 on Metal) stays
the default. `d3d11 = dxvk` gives an x64 program DXVK's Direct3D 10/11 and DXGI on
Vulkan instead, through Wine's winevulkan and the Vulkan driver chosen with `vulkan`
(MoltenVK or KosmicKrisp). It mirrors the vkd3d-proton route for Direct3D 12
(docs/BUILDING.md step 6c).

## What is in the bundle

`app/Madeira/vulkan/arm64ec-windows/` (git-ignored build products, `build/dxvk/build.sh`):

| File | Size | sha256 |
|---|---|---|
| `dxvk-d3d11.dll` | 8,253,440 B | `cb0537e284ffbe4538bda2403cb2f7e5dead526987f2445c4aa951edf7a84187` |
| `dxvk-dxgi.dll` | 5,402,624 B | `e5fd77fc7a57d6f18f512a7102faded6680e96b8aa9393c4f653919e34339b1f` |
| `dxvk-d3d10core.dll` | 438,272 B | `5bf8b780eb67fbf0f1e6549e1ba8abf009878aa30dca178c7f3eee0c340edeec` |

- DXVK **v3.1.1** (`b1a1c99ab52b687cf950d62c88bc2fa316b41663`, 2026-09-15) with
  submodules (dxbc-spirv, libdisplay-info, Vulkan/SPIR-V headers) and one Madeira patch
  (`build/dxvk/patches`, see `PATCHES.md` there).
- ARM64EC (machine 0xA641), meson cross build with llvm-mingw, C++ runtime linked
  statically, `--strip-debug`. D3D8/D3D9 are not built: Vulkan is x64-only here (no i386
  winevulkan) and most D3D9 programs are 32-bit.
- Each DLL has 5 to 10 `ldr xN, [x18, #imm]` TEB reads (the toolchain's
  `NtCurrentTeb` and implicit TLS); all are forms the loader's x18 patcher rewrites.
- Imports: kernel32, user32, gdi32, advapi32, setupapi, version, the api-ms-win-crt
  sets (Wine's apisets), and each other (`d3d10core` → `d3d11` → `dxgi`). Vulkan is
  loaded at run time (`LoadLibrary("winevulkan.dll")`, then `vulkan-1.dll`). Wine's
  `d3d10.dll`/`d3d10_1.dll` in the farm need only `D3D10CoreCreateDevice` and
  `CreateDXGIFactory`, which DXVK exports.
- The names are `dxvk-*` so nothing loads them by name; the session links the real
  names to them.
- Size: +14.1 MiB in the bundle, about 4.5 MiB compressed in the IPA (deflate -9: 2.65 +
  1.91 + 0.11 MB). The IPA stays under 200 MB (vk6 was 174 MB), so no in-app download.

Licences: DXVK zlib (`licenses/DXVK-zlib.txt`), libdisplay-info MIT
(`licenses/libdisplay-info-MIT.txt`), dxbc-spirv MIT (the same text vkd3d-proton
already ships, `licenses/dxbc-spirv-MIT.txt`).

## Building

```sh
# WSL, this PC (about 4 minutes):
DXVK_SRC=/home/hero/.cache/dxvk-src DXVK_WORK=/home/hero/.cache/dxvk-build \
LLVM_MINGW=/home/hero/.cache/madeira-tall6/toolchains/llvm-mingw \
bash build/dxvk/build.sh
```

Defaults: source in `toolchains/dxvk-src` (cloned when absent), work tree in
`toolchains/dxvk-build`, output `app/Madeira/vulkan/arm64ec-windows`, licence texts
`app/Madeira/licenses`. Host tools: meson, ninja, glslangValidator (DXVK compiles its
built-in shaders with `--target-env vulkan1.3`; glslang 16.2 on this PC). The
workspace (`/home/hero/.cache/madeira-tall6`) needs the same git-ignored DLLs and two
licence texts copied in by hand, like vkd3d-proton's.

## Selecting it

madeira.cfg, or a game's own lines (Settings › Graphics › Direct3D 10/11 writes it):

```
d3d11 = dxvk
vulkan = kosmickrisp        # optional; MoltenVK when unset
env.DXVK_LOG_LEVEL = info   # optional; d3d11 = dxvk sets info unless set
env.DXVK_CONFIG = dxgi.maxFrameRate=60     # optional, dxvk.conf options inline
env.DXVK_CONFIG_FILE = C:\users\madeira\dxvk.conf   # optional
```

`WineProcessBridge.m` (`madeira_setup_vulkan`, after the farm passes) then:
- turns Vulkan on (`MADEIRA_VULKAN_LIBRARY`, `vulkan-1.dll` + `winevulkan.dll` links);
- links `system32` (x64 sessions) and `sysx64` `d3d11.dll`, `d3d10core.dll` and
  `dxgi.dll` to the `dxvk-*` files. Every session relinks the farms first, so the next
  session without the key gets DXMT again;
- DXVK's d3d11 only works with its own DXGI, and DXMT's DXGI is then gone, so
  madeira-d3d12 cannot present: with `d3d12` unset, `d3d11 = dxvk` implies
  `d3d12 = vkd3d` (DXVK's DXGI + vkd3d-proton is the usual Proton pairing; DXVK's
  `D3D11On12CreateDevice` also expects a vkd3d-proton device). An explicit other
  `d3d12` value is kept and logged as a warning;
- sets `DXVK_LOG_LEVEL=info` unless set. Under Wine DXVK writes its log through
  `__wine_dbg_output` into the session log and creates no log file unless
  `env.DXVK_LOG_PATH` names a folder.

The loader picks the links up because DXMT's DLLs in the bundle are native PEs, not
Wine builtins: the builtin search finds no builtin `d3d11.dll`/`dxgi.dll` and the
session's `system32` link is loaded (as for vkd3d-proton's `d3d12.dll`).

Side effects for the session: DXMT's `nvapi64.dll` (only used with "Report an NVIDIA
GPU") imports DXGI and will see DXVK's; DXMT's D3D9 does not use DXGI and is unaffected.

## Expected log lines

```
[vulkan] d3d11 = dxvk: DXVK's d3d11.dll, d3d10core.dll and dxgi.dll for this session (links 6 in system32 + sysx64);
  D3D12 = vkd3d-proton (d3d12 unset: d3d11 = dxvk implies d3d12 = vkd3d); DXVK_LOG_LEVEL=info
[vulkan] on: MADEIRA_VULKAN_LIBRARY=<bundle>/gl/libvulkan_kosmickrisp.dylib; 4 Vulkan DLL links in system32 + sysx64;
  D3D12 = vkd3d-proton (4 links); D3D10/11 = DXVK (6 links)
[winios-vk] Vulkan library <path> loaded
[winios-vk] driver ready (VK_EXT_metal_surface surfaces)
info:  Game: <exe>.exe
info:  DXVK: v3.1.1
info:  Build: aarch64 clang ...
info:  Vulkan: Found vkGetInstanceProcAddr in winevulkan.dll @ 0x...
info:  Enabled instance extensions: ...
info:  Found device: <name> (<driver> <version>)  (the Apple GPU and the driver's name)
warn:  Madeira: no geometryShader: D3D11 geometry shaders are not bound, those draws run without them
warn:  Madeira: no fillModeNonSolid: wireframe rasterizer states draw solid             (KosmicKrisp)
warn:  Madeira: no VK_EXT_depth_clip_enable: depth clip off is emulated with depth clamp
info:  Creating device:
info:  <device name>:   Driver : ...                     (DXVK's device and feature dump)
info:  D3D11InternalCreateDevice: Maximum supported feature level: D3D_FEATURE_LEVEL_11_1
info:  D3D11InternalCreateDevice: Using feature level D3D_FEATURE_LEVEL_11_x
```

Failure shapes:
- `info:  Skipping: Device does not support required feature '<name>' (extension: ...)`
  then `D3D11CreateDevice: No default adapter available`: the driver lacks a hard
  requirement the patch does not relax (see below). `Device does not support Vulkan 1.3`:
  an old driver.
- `err:   Failed to create Vulkan device: VK_ERROR_...`: vkCreateDevice itself failed.
- `err:   Vulkan: vkGetInstanceProcAddr not found` / `Failed to load vulkan-1 library.`:
  the session has no Vulkan links (Vulkan off or library missing; see the `[vulkan]` lines).
- `[vulkan] d3d11 = dxvk, but the bundle has no vulkan/arm64ec-windows/dxvk-d3d11.dll ...`:
  a build without these DLLs; DXMT stays. `[vulkan] d3d11 = dxvk with vulkan = off`: same.
- `warn:  Madeira: device has no geometry shaders; D3D11 geometry shaders are not bound`:
  the first time a program binds one (expected on both drivers; such draws are wrong).

## Driver requirements (DXVK 3.1.1)

Hard requirements (`src/dxvk/dxvk_device_info.cpp`): Vulkan 1.3; core
depthBiasClamp, depthClamp, dualSrcBlend, fillModeNonSolid, fragmentStoresAndAtomics,
fullDrawIndexUint32, geometryShader, imageCubeArray, independentBlend,
multiDrawIndirect, multiViewport, occlusionQueryPrecise, robustBufferAccess,
sampleRateShading, samplerAnisotropy, shaderClipDistance, shaderCullDistance,
shaderImageGatherExtended, shaderInt16, shaderInt64,
shaderSampledImageArrayDynamicIndexing, textureCompressionBC; Vulkan 1.1
shaderDrawParameters, storageBuffer16BitAccess; 1.2 bufferDeviceAddress,
descriptorIndexing (+ sampled-image update-after-bind, update-unused-while-pending,
partially bound, runtime arrays), hostQueryReset, samplerMirrorClampToEdge,
scalarBlockLayout, shaderInt8, storageBuffer8BitAccess, timelineSemaphore,
uniformBufferStandardLayout, vulkanMemoryModel; 1.3 computeFullSubgroups,
dynamicRendering, inlineUniformBlock, maintenance4, shaderDemoteToHelperInvocation,
shaderZeroInitializeWorkgroupMemory, subgroupSizeControl, synchronization2; extensions
VK_EXT_depth_clip_enable, VK_EXT_robustness2 (robustBufferAccess2, nullDescriptor),
VK_KHR_load_store_op_none, VK_KHR_maintenance5, VK_KHR_maintenance6, VK_KHR_swapchain;
256 bytes of push constants (unless VK_EXT_descriptor_heap).

| | KosmicKrisp (Mesa 26.2.4) | MoltenVK 1.4.2 |
|---|---|---|
| geometryShader | missing (patched: optional) | missing (patched: optional) |
| fillModeNonSolid | missing (patched: optional) | not verified (patched: optional either way) |
| VK_EXT_depth_clip_enable | missing, has depth_clip_control (patched) | missing (patched) |
| shaderCullDistance | yes | missing (patched: optional) |
| robustness2, maintenance5/6, load_store_op_none | yes | extension names present in the dylib |
| everything else above | yes (checked against kk_physical_device.c) | not verified (no source here) |
| transform feedback (optional) | no: D3D11 stream output fails | no |
| feature level after the patch | 11_1 expected (tessellation, logicOp, vertex stores present; no sparse → not 12_0) | unknown |

KosmicKrisp is the realistic target (it needs iOS 26 and an A14 or newer, Metal 4).
On MoltenVK, if a further required feature is missing, DXVK's `Skipping:` line names it.

## Not done / limits

- x64 programs only; no 32-bit DXVK (no i386 winevulkan).
- Games that depend on geometry shaders or stream output draw wrongly or fail on both
  drivers.
- No dxvk.conf is shipped; DXVK's built-in per-application profiles apply as usual.
