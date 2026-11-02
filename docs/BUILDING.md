# Building Madeira from a clean checkout (reproducibility record, 2026-09-16)

This is the "scripts to control compilation and installation" record the
LGPL relink obligation depends on (docs/LICENSING.md). Each step says
whether it has been re-executed from a clean checkout. A fresh recursive
clone of the repository at commit 8a8cabe was tested on 2026-09-16 (with
the submodule URLs redirected to the local forks, since nothing is pushed):
the app target does NOT build from the clone alone, because the inputs
marked "not in the repository" below are absent. Two further findings:
`app/Madeira/x86_64-vcruntime` is required by the project but ignored, and
the submodule commits (FEX, its nested rpmalloc fork, wine branch
`madeira-lgpl`, dxmt) exist only locally: the forks named in `.gitmodules`
(all under github.com/willfaust) do not yet carry them, so a recipient's
recursive clone fails at the first submodule until every fork is pushed. This document is the
remediation; steps marked UNVERIFIED have not yet been re-run from scratch.
A build without `app/Madeira/x86_64-vcruntime` still gets the Visual C++ runtime
on the device: setup and Settings take the DLLs out of Microsoft's own installers
there, for 64-bit and 32-bit games (`app/Madeira/VCRedist.swift`, docs/LIBRARY.md).

## Inputs that are not in the repository

| Input | Why absent | How to obtain | Verified from clean |
|---|---|---|---|
| `toolchains/llvm-mingw-20260421-ucrt-macos-universal/` | 122 MB third-party toolchain | `llvm-mingw-20260421-ucrt-macos-universal.tar.xz` from https://github.com/mstorsjo/llvm-mingw/releases/tag/20260421, SHA-256 `bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7`, extracted under `toolchains/` | tarball hash recorded; download UNVERIFIED |
| `toolchains/llvm-project/` + `toolchains/llvm-ios-build/` + `toolchains/llvm-host-build/` | LLVM built for iOS | upstream llvm-project at commit `8dfdcc7b7`; configure `llvm-ios-build` with `-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_MACOSX_BUNDLE=OFF -DCMAKE_BUILD_TYPE=Release -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 -DLLVM_TARGET_ARCH=host -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= -DLLVM_BUILD_TOOLS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_TABLEGEN=<absolute path to llvm-host-build/bin/llvm-tblgen>`. First build the host `llvm-tblgen` target; then build iOS targets `LLVMPasses LLVMBitWriter`. | these targets built with Xcode 26.6 on 2026-10-17 |
| `research/GPTK/Metal Shader Converter 4.0 beta 2.pkg` | Apple installer, 30 MB, licence-bound | Apple developer downloads; SHA-256 `1acc33c87ea663933df89721a998d066106685473020bcbe007cee7a16155734` (pinned in `build/madeira-d3d12/deps.sh`). Only needed to REBUILD the converter fetch; the library itself is tracked | n/a |
| `app/Madeira/x86_64-vcruntime/` | Microsoft Visual C++ 2015-2022 x64 runtime DLLs (concrt140, msvcp140*, vcamp140, vccorlib140, vcruntime140*), redistributable under Microsoft's terms, not under this repository's licence | extract from Microsoft's `vc_redist.x64.exe` (or copy from `C:\Windows\System32` of a licensed Windows install) into that folder | UNVERIFIED |
| `build/wine-mono/wine-mono-11.0.0/` (optional) | Wine Mono, the .NET Framework runtime Wine's mscoree loads (not Microsoft code; licences in `build/wine-mono/COPYING` and `THIRD-PARTY-NOTICES.md`), 41.6 MB download, 228 MB unpacked | `bash build/wine-mono/fetch.sh` downloads `wine-mono-11.0.0-x86.tar.xz` from https://dl.winehq.org/wine/wine-mono/11.0.0/ and checks its SHA-256; `--source` also fetches the matching source tarball. Version and hashes are pinned in `build/wine-mono/pin.sh`, which does not follow `WINE_MONO_VERSION` in `wine/dlls/mscoree/mscoree_private.h`. The Xcode phase "Bundle Wine Mono" runs `build/wine-mono/bundle.sh`, which copies it into `Madeira.app/wine-mono` without the `lib/mono/*-api` reference assemblies and patches the bundled `mscorlib.dll`: **a dirty hack** (4 IL bytes: `GC.Collect` with `GCCollectionMode.Optimized` returns, for Terraria), pinned to the exact file by SHA-256 so the build stops on any other mscorlib; TODO: replace it with a Wine Mono built from source or an upstream fix (see the TODO in `bundle.sh`). Without the folder the app builds without Mono, and .NET Framework programs fail with "Wine Mono is not installed". **Release builds leave Wine Mono out** (2026-10-06): the packaging step deletes `Madeira.app/wine-mono`, and the app downloads it from WineHQ on first use (setup or Settings › .NET Framework, `app/Madeira/WineMono.swift`) | fetch + bundle run on the development machine 2026-10-05; not from a clean checkout |
| `toolchains/mesa-d3d12/` (OpenGL, optional) | Mesa 26.2.4 source, the DirectXShaderCompiler release for `dxil.dll`, and zlib for Meson | downloaded by `build/mesa-d3d12/build.sh` and checked against the SHA-256 values in it: `mesa-26.2.4.tar.xz` `bce5f7fb…832e9` from archive.mesa3d.org, `dxc_2026_09_29.zip` `ad31b1fc…7e7f1` (DirectXShaderCompiler v1.9.2609), zlib 1.3.1 and its wrap patch; DirectX-Headers at commit `9e393d6d` (v1.619.1) | Verified 2026-10-06 |
| A free Apple ID; StikDebug or a pairing file plus LocalDevVPN | signing and JIT runtime requirements | see `docs/JIT.md` | n/a |

## Native build chains (all in the repository)

Run in this order after the inputs above are in place. Outputs are
git-ignored and consumed by the app project.

1. `build/gnutls-ios/build.sh`: GMP 6.3.0, Nettle 3.10.1, GnuTLS 3.8.9 from
   the tracked tarballs in `build/gnutls-ios/src` (SHA256SUMS there) ->
   `app/Madeira/lib{gmp,nettle,hogweed,gnutls}.a` (these four outputs are
   also tracked). Verified: built on the development machine; not re-run
   from a clean checkout.
   `build/ffmpeg/build.sh`: FFmpeg 7.1.1 in an LGPL-only configuration (WMA,
   MPEG audio and PCM decoders; mp3/wav/mov demuxers; no H.264/HEVC/AAC),
   built from the tracked, unmodified release tarball in `build/ffmpeg/src`
   after verifying it against `build/ffmpeg/src/SHA256SUMS` -> headers in `toolchains/ffmpeg-ios/include`
   (read by `build/ntdll-unix/build.sh` for winegstreamer's unix side) and
   `app/Madeira/lib{avformat,avcodec,swresample,avutil}.a` (ignored; the app
   target links them together with VideoToolbox, CoreMedia, CoreVideo,
   AudioToolbox and CoreFoundation). The configure arguments are the ones the
   port was built and device-tested with on the WSL toolchain; the macOS form
   of the script is UNVERIFIED.
2. FEX (submodule, branch ios-port-2607):
   - `FEX/build-ios`: `build/fex-ios/build.sh` (same options as the development CMakeCache) -> `FEX/build-ios/FEXCore/Source/lib{FEXCore,FEXCore_Base,JemallocLibs}.a` and the `External/{cephes,fmt,SoftFloat-3e,xxhash}` archives. UNVERIFIED from clean.
   - `FEX/build-arm64ec`: `build/fex-arm64ec/build.sh` (configures with `FEX/Data/CMake/toolchain_mingw.cmake` and the recorded options on first run, builds target `arm64ecfex`, copies `Bin/libarm64ecfex.dll` to `app/Madeira/arm64ec-windows/xtajit64.dll`). The build step was verified this session. The first-run configure uses Ninja, `MINGW_TRIPLE=arm64ec-w64-mingw32`, `TUNE_CPU=cortex-a78`, `FEX_IOS_HOST_BUILD=ON`, `FEX_IOS_HOST=1` for the C, C++ and assembler flags, and LTO off: the options the madeira-bcd fork's macOS CI has built xtajit64.dll with since 2026-09-26 (the module every 64-bit game ran on from its build 231). A tree configured before keeps its cached options and generator (remove `FEX/build-arm64ec` to configure it again).
3. Wine (submodule, branch madeira-lgpl):
   - unix side: `build/ntdll-unix/build.sh`, `build/wineserver/build.sh`,
     `build/win32u-unix/build.sh` -> `app/Madeira/lib{ntdll_unix,wineserver,win32u_unix}.a`. Verified on the development machine.
     The ntdll build probes the selected iPhoneOS SDK for the optional
     `rusage_info_v6.ri_page_wait_time_mach` diagnostic member. When absent,
     `[xp] pgw=-1.0` means unavailable, not zero page-wait time. SDKs that
     expose the member keep the measured delta. This does not remove other
     SDK/toolchain requirements. Run `python3 tests/host/check-rusage-sdk.py`
     to check both header layouts and, on macOS, the installed iPhoneOS SDK.
   - PE side: `build/wine-pe/build-ntdll.sh` (configures `wine/build-arm64ec` with `--enable-archs=arm64ec --without-x --disable-tests --enable-winegstreamer` on first run, builds `dlls/ntdll`, strips, pads to SizeOfImage + 0x50000, copies to the app). Other PE modules: `build/wine-pe/build-modules.sh <name>...` (same tree; it builds each module's DLL target `dlls/<name>/arm64ec-windows/<name>.dll`, strips it with `--strip-debug` like every shipped builtin and installs it into `app/Madeira/arm64ec-windows/`, or into `$DEST`). Building the DLL target rather than `make -C dlls/<name>` is also what winegstreamer needs (enabled by `--enable-winegstreamer` although GStreamer is absent, since its unix side is `build/ntdll-unix/winegstreamer_unixlib_ios.c`). Without arguments the script rebuilds the stock builtins added for games: `cryptsp`, `d3dx11_43`, `faultrep`, `msvcp110`, `msvcr110` and `xaudio2_7`, and the builtins games and their installers import that the farm did not have (`GAME_MODULES` in the script: older VC++ runtimes, D3DX and d3dcompiler versions, XAudio2/X3DAudio/XAPOFX, `d3d10`, `avifil32`, `d2d1`, `wmvcore` with `winegstreamer`, `netprofm`), all committed in `app/Madeira/arm64ec-windows/` like every other builtin. Every module the script builds links its delay imports as plain imports (`UNDELAY=0` keeps them; the script says why), and `tools/check-wine-media-dlls.py` then checks the Windows Media Format reader's exports and imports in the farm. It needs bison 3 for `tools/wrc` (macOS ships 2.3; Homebrew's is used when installed). The strip/pad step was verified this session; the configure step is UNVERIFIED from clean; build-modules.sh reproduced the five default DLLs at their shipped sizes on the development machine (2026-10-03).
   - `app/Madeira/arm64ec-windows/` is the DLL farm: every file in it is linked into the prefix (`system32` for x64 sessions, and `sysx64`), so a Wine module is only available if it was built and copied there. The native D3D12 path needs two stock modules in addition to the existing ones: `dcomp.dll` (`make -C dlls/dcomp`; a 64-bit Godot 4 engine loads it before it creates its D3D12 device, and gives up on D3D12 without it) and `ktmw32.dll` (`make -C dlls/ktmw32`; an optional import the same engine probes).
   - TaskbarList COM: the prefix registers `explorerframe.dll`, which must be in
     the ARM64EC farm. It is in the default module list; rebuild it explicitly
     with `bash build/wine-pe/build-modules.sh explorerframe`. See
     `docs/TASKBARLIST.md` for the package check and Windows x64 COM fixture.
   - Stand-ins for DLLs Wine cannot provide here but games import: `python3 tools/build-stub-dlls.py wine build/stub-dlls toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/arm64ec-w64-mingw32-clang toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/llvm-readobj app/Madeira/arm64ec-windows` builds `vulkan-1.dll` (answers like a PC without a Vulkan driver, so a game falls back to D3D) and, when the farm has no Wine build of them, `d3d10.dll` and `avifil32.dll`; each exports exactly its Wine `.spec`. Crysis Remastered imports all three.
4. DXMT (submodule, branch ios-port):
   - unix side: `build/dxmt-ios/build.sh` (needs `toolchains/llvm-ios-build`) -> `app/Madeira/libdxmt_combined.a` (ignored; the app links it). Verified this session.
   - PE side: `meson setup dxmt/build-arm64ec dxmt -Dbuildtype=release -Dwine_build_path=../../wine/build-arm64ec --cross-file=dxmt/build-arm64ec-win.txt` then `ninja -C dxmt/build-arm64ec src/winemetal/winemetal.dll` (and d3d11.dll) -> copied to `app/Madeira/arm64ec-windows/`. Verified this session (winemetal.dll).
4b. In-app pairing (Built-in StikJIT on iOS 27): `build/rppairing-ios/build.sh`
   (Rust with the `aarch64-apple-ios` target; crates from crates.io at the
   versions in `build/rppairing-ios/Cargo.lock`) -> `app/Madeira/libmadeira_rppairing.a`
   (ignored; the app links it) and the bundled crate notices
   `app/Madeira/legal/LICENSES-rppairing-crates.txt` (tracked). `cargo test`
   in that folder runs its host tests. Verified on the development machine.
5. Native D3D12 runtime: `build/madeira-d3d12/build-pe.sh` -> `d3d12.dll`, `madeira_d3d12.dll` and the test executables in `app/Madeira/arm64ec-windows/` (tracked). Verified this session. `build/madeira-d3d12/fetch-converter.sh` re-verifies the converter library; `build/stage-licenses.sh` refreshes the bundled licence copies (the Xcode build fails if they are stale).
   `faultrep.dll` (Windows Error Reporting stubs; Wine's faultrep lacks `WerReportHang`, and Ghost of Tsushima imports it): `build/faultrep/build.sh` -> `app/Madeira/arm64ec-windows/faultrep.dll` (tracked like the other builtins).
5b. OpenGL (optional): `build/mesa-d3d12/build.sh` builds Mesa's Windows x64
   D3D12 driver from the pinned tarball with `build/mesa-d3d12/patches/` and
   writes `opengl32.dll`, `libgallium_wgl.dll` and the fetched `dxil.dll`
   (with `LICENSE-dxil.txt`) to `app/Madeira/x86_64-opengl/` (ignored). Needs
   bison 3, ninja, and uv or `python3 -m venv` for Meson and Mako. Meson cannot
   download (`--wrap-mode=nodownload`), and two clean builds give the same
   bytes. `tests/host/check-mesa-fence-fallback.py` checks the fence patch
   against the built tree. At session start WineProcessBridge.m links these
   DLLs over Wine's opengl32 stub for x64 games (`env.MADEIRA_OPENGL = 0`
   selects the native WGL route; set env.MADEIRA_OPENGL = 1 for Mesa on D3D12). Without the DLLs nothing changes. Verified on the development
   machine 2026-10-06.
6. App: `xcodebuild -project app/Madeira.xcodeproj -scheme Madeira -destination 'generic/platform=iOS' -allowProvisioningUpdates build` (Debug is the configuration that runs the games; Release builds have crashed the guest), then zip `Payload/Madeira.app` into an IPA and sideload. Verified this session on the development machine.
7. WoW64 (32-bit programs, optional): `build/wine-i386/build.sh` (i386 Wine farm
6. OpenGL and LOVE games:
   - Before step 3, apply the Wine patch: `git -C wine apply ../patches/wine-opengl-winios.patch`. Then rebuild the tracked `opengl32.dll` with `build/wine-pe/build-modules.sh opengl32`.
   - `build/luajit-x64/build.sh` -> `app/Madeira/compat/love/lua51.dll`, needed for LOVE games.
   - `build/moltenvk-ios/build.sh`, then `build/mesa-ios/build.sh` -> `app/Madeira/gl/`, the desktop OpenGL backend. Optional: without it the app uses OpenGL ES. The script applies every file in `build/mesa-ios/patches` once (a `.madeira-applied-*` marker in the Mesa source records it), so an existing Mesa tree picks up a new patch on the next run.
   - 32-bit OpenGL games (id Tech 3: Jedi Academy, Jedi Outcast, Quake III) need all of: the regenerated wow64 thunks in `wine-opengl-winios.patch` (from `dlls/opengl32/make_opengl`; to regenerate, run `perl make_opengl` in `wine/dlls/opengl32`, which downloads the pinned Khronos registry files into `~/.cache/wine`), `build/ntdll-unix` rebuilt, and Mesa patch `0004` (Zink on MoltenVK: fragment inputs Metal can link, and no crash when a pipeline fails). They need the desktop OpenGL (Zink) backend; fixed-function OpenGL does not exist in OpenGL ES. A 32-bit process gets `GL_EXTENSIONS` cut to 3072 bytes, because these engines copy it into a fixed buffer; `env.MADEIRA_GL_EXTENSIONS_MAX` in madeira.cfg sets another limit (0 = none).
   - Each script says what source to download if it is missing. Verified on the development machine.
   `faultrep.dll` (Windows Error Reporting stubs; Wine's faultrep lacks `WerReportHang`, and Ghost of Tsushima imports it): `build/faultrep/build.sh`.
6. OpenGL games:
   - Before step 3, apply the Wine patch: `git -C wine apply ../patches/wine-opengl-winios.patch`. Then rebuild the tracked `opengl32.dll` with `build/wine-pe/build-modules.sh opengl32`.
   - `build/moltenvk-ios/build.sh`, then `build/mesa-ios/build.sh` -> `app/Madeira/gl/`, the desktop OpenGL backend. Optional: without it the app uses OpenGL ES. The script applies every file in `build/mesa-ios/patches` once (a `.madeira-applied-*` marker in the Mesa source records it), so an existing Mesa tree picks up a new patch on the next run.
   - 32-bit OpenGL games (id Tech 3: Jedi Academy, Jedi Outcast, Quake III) need all of: the regenerated wow64 thunks in `wine-opengl-winios.patch` (from `dlls/opengl32/make_opengl`; to regenerate, run `perl make_opengl` in `wine/dlls/opengl32`, which downloads the pinned Khronos registry files into `~/.cache/wine`), `build/ntdll-unix` rebuilt, and Mesa patch `0004` (Zink on MoltenVK: fragment inputs Metal can link, and no crash when a pipeline fails). They need the desktop OpenGL (Zink) backend; fixed-function OpenGL does not exist in OpenGL ES. A 32-bit process gets `GL_EXTENSIONS` cut to 3072 bytes, because these engines copy it into a fixed buffer; `env.MADEIRA_GL_EXTENSIONS_MAX` in madeira.cfg sets another limit (0 = none).
   - Each script says what source to download if it is missing. Verified on the development machine.
6b. wined3d (Direct3D 8/9 and DirectDraw on OpenGL), the second Direct3D 9 route (2026-10-12):
   - Wine's `d3d9.dll`, `wined3d.dll`, `d3d8.dll` and `ddraw.dll` are stock modules built from the same trees as every other builtin, after the OpenGL patch of step 6 (wined3d imports `opengl32.dll` and draws through it, i.e. through the winios WGL driver and Zink on MoltenVK). wined3d has no unix side; nothing else is needed.
   - ARM64EC: `build/wine-pe/build-modules.sh wined3d d3d9-wined3d d3d8 ddraw`, which is `make -C wine/build-arm64ec dlls/<m>/arm64ec-windows/<m>.dll` for the four modules and `arm64ec-w64-mingw32-strip --strip-debug`. The name `d3d9-wined3d` builds `dlls/d3d9` and installs it as `app/Madeira/arm64ec-windows/d3d9-wined3d.dll`, because `d3d9.dll` there is DXMT's frontend (the script refuses `d3d9`). `wined3d.dll`, `d3d8.dll` and `ddraw.dll` go in under their own names (no DXMT or native file uses them; d3d8 and ddraw always drew through wined3d). All four are tracked.
   - i386: `build/wine-i386/build.sh d3d9-wined3d wined3d d3d8 ddraw` (on this PC: `make -C wine/build-i386 dlls/<m>/i386-windows/<m>.dll`, `i686-w64-mingw32-strip --strip-debug`), installing Wine's d3d9 as `app/Madeira/i386-windows/d3d9-wined3d.dll` beside the DXMT shim (`d3d9.dll`) and `d3d9-emulated.dll`. The i386 farm is not tracked.
   - The farms link every file into the prefix as before. `d3d9 = wined3d` in madeira.cfg (or a game's own lines) makes `WineProcessBridge.m` re-point that session's `system32`/`sysx64` (ARM64EC) and `syswow64` (i386) `d3d9.dll` links to `d3d9-wined3d.dll`; the next session without it gets DXMT's again. It needs the desktop OpenGL backend (`gl-backend = zink`, the default when `app/Madeira/gl/` is bundled).
   - Added size: `d3d9-wined3d.dll` 896 KiB (ARM64EC) + 276 KiB (i386); the ARM64EC `wined3d.dll` rebuilt from the current wine tree grew from 3.5 to 4.8 MiB (the previous one dates from 2026-08-25, older than the wine pin that built `d3d8.dll`/`ddraw.dll`, which call into it; the export names match, the structures they pass are only guaranteed to within one tree). Unverified on a device.
6c. winevulkan and vkd3d-proton: Vulkan for x64 programs and the second Direct3D 12 route (2026-10-12, not device-tested):
   - Unix side (linked into the app): `build/ntdll-unix/build.sh` compiles `wine/dlls/winevulkan/vulkan.c` and `vulkan_thunks.c` into `libntdll_unix.a` (table `winevulkan_unix_call_funcs`, bound by export name in `virtual_ios.c`'s `load_builtin_unixlib`; 64-bit callers only, its wow64 thunks lack the 32-bit window base). `build/win32u-unix/build.sh` compiles `vulkan_ios.c` in place of `dlls/win32u/vulkan.c`: upstream's file, with the Vulkan library opened from `$MADEIRA_VULKAN_LIBRARY` (unset = Vulkan off, exactly as before) and the winios Vulkan driver (`VK_KHR_win32_surface` on `VK_EXT_metal_surface`, the window's CAMetalLayer from `madeira_vulkan_layer_for_hwnd` in `IOSDisplayShim.m`); `d3dkmt_ios.c` skips D3DKMT's Vulkan instance on a thread inside Vulkan's own set-up (Apple's `pthread_once` traps on the re-entry). Rebuild both libraries (`rebuild-native.sh ntdll win32u` in the WSL loop).
   - PE side, ARM64EC: `make -C wine/build-arm64ec dlls/winevulkan/arm64ec-windows/winevulkan.dll dlls/vulkan-1/arm64ec-windows/vulkan-1.dll`, `arm64ec-w64-mingw32-strip --strip-debug`, into `app/Madeira/vulkan/arm64ec-windows/` (a bundle folder of its own: the `arm64ec-windows/` farm is linked into every prefix, and a program probing for `vulkan-1.dll` must keep finding none by default). No i386 build.
   - vkd3d-proton: `build/vkd3d-proton/build.sh` (upstream `750061ae2be846d19d6364628eaf5ea4beb8e619` with submodules, cloned into `toolchains/vkd3d-proton` when absent; the three patches in `build/vkd3d-proton/patches`, from another iOS port, see `PATCHES.md` there; meson cross build for `arm64ec-w64-mingw32` with `-static`; strip) -> `app/Madeira/vulkan/arm64ec-windows/d3d12.dll` and `d3d12core.dll` (git-ignored) and three licence texts in `app/Madeira/licenses/`. Host tools: meson, ninja, glslangValidator. On this PC: `VKD3D_SRC=/home/hero/.cache/vkd3d-proton-src VKD3D_WORK=/home/hero/.cache/vkd3d-proton-build LLVM_MINGW=/home/hero/.cache/madeira-tall6/toolchains/llvm-mingw bash build/vkd3d-proton/build.sh` (about a minute). It is built with the toolchain's own `winnt.h`: its `NtCurrentTeb()` and implicit-TLS reads of x18 are rewritten at load time by the same x18 patcher as every other ARM64EC DLL (Madeira's TEB slot is found at run time, so a compile-time slot does not fit); the script lists any x18 instruction the patcher would not rewrite (none in this build: 8 + 31 `ldr xN, [x18, #imm]`).
   - Selection (`WineProcessBridge.m`, `madeira_setup_vulkan`): madeira.cfg `vulkan = moltenvk|kosmickrisp|off|<path>.dylib` picks the library (`gl/libMoltenVK.dylib`, `gl/libvulkan_kosmickrisp.dylib`); `d3d12 = vkd3d` turns Vulkan on (MoltenVK unless `vulkan` says otherwise) and re-points the session's `system32`/`sysx64` `d3d12.dll` and `d3d12core.dll` to vkd3d-proton's. madeira-d3d12 stays the default. Both keys also work from a game's own lines.
   - Presenting: DXMT's `dxgi.dll` (submodule commit 03baeb58, `src/dxgi/dxgi_swapchain_vk.cpp`) wraps vkd3d-proton's swapchain (`IDXGIVkSwapChainFactory`, surfaces through `vkCreateWin32SurfaceKHR` in winevulkan) as an `IDXGISwapChain4`, windowed only; `env.MADEIRA_DXGI_VK_SWAPCHAIN = 0` restores the old "Unsupported device type" refusal. Rebuild: `ninja -C build-pe-arm64ec src/dxgi/dxgi.dll` in the dxmt tree.
   - Added size: 7.7 MiB in the bundle (d3d12core.dll 6.0 MiB, winevulkan.dll 0.9, vulkan-1.dll 0.6, d3d12.dll 0.2), about 2.3 MiB compressed in the IPA, plus the winevulkan thunks in the app binary (an 0.86 MB object); no in-app download needed.
6d. DXVK: Direct3D 10/11 and DXGI on Vulkan for x64 programs, opt-in (2026-10-13, not device-tested; docs/DXVK.md):
   - `build/dxvk/build.sh` (upstream DXVK `v3.1.1`, `b1a1c99ab52b687cf950d62c88bc2fa316b41663`, with submodules, cloned into `toolchains/dxvk-src` when absent; the patch in `build/dxvk/patches`, see `PATCHES.md` there; meson cross build for `arm64ec-w64-mingw32`, D3D8/D3D9 off; strip; the same x18 check as vkd3d-proton's script) -> `app/Madeira/vulkan/arm64ec-windows/dxvk-d3d11.dll`, `dxvk-d3d10core.dll` and `dxvk-dxgi.dll` (git-ignored) and `licenses/DXVK-zlib.txt` + `licenses/libdisplay-info-MIT.txt`. Host tools: meson, ninja, glslangValidator. On this PC: `DXVK_SRC=/home/hero/.cache/dxvk-src DXVK_WORK=/home/hero/.cache/dxvk-build LLVM_MINGW=/home/hero/.cache/madeira-tall6/toolchains/llvm-mingw bash build/dxvk/build.sh` (about 4 minutes).
   - Selection (`WineProcessBridge.m`, `madeira_setup_vulkan`): `d3d11 = dxvk` turns Vulkan on and re-points the session's `system32`/`sysx64` `d3d11.dll`, `d3d10core.dll` and `dxgi.dll` to the `dxvk-*` files; with `d3d12` unset it also implies `d3d12 = vkd3d` (DXVK's DXGI presents only Vulkan devices). DXMT stays the default.
   - Added size: 14.1 MiB in the bundle, about 4.5 MiB compressed in the IPA; no in-app download needed.
7. App: `xcodebuild -project app/Madeira.xcodeproj -scheme Madeira -destination 'generic/platform=iOS' -allowProvisioningUpdates build` (Debug is the configuration that runs the games; Release builds have crashed the guest), then zip `Payload/Madeira.app` into an IPA and sideload. Verified this session on the development machine.
8. WoW64 (32-bit programs, optional): `build/wine-i386/build.sh` (i386 Wine farm
   -> `app/Madeira/i386-windows/`), `build/fex-wow64/build.sh` (FEX WOW64 module
   -> `app/Madeira/aarch64-windows/xtajit.dll`) and the aarch64 `wow64.dll` /
   `wow64win.dll`; see docs/WOW64.md, "Building". UNVERIFIED on macOS.

## Status of the LGPL relink question

### Native app rebuild, 2026-10-17

The app's Debug target linked successfully with Xcode 26.6 (iPhoneOS 26.5 SDK)
after building FEX's native `FEXCore`, `FEXCore_Base` and `JemallocLibs`, the
three Wine unix archives, FreeType, FFmpeg, rppairing and DXMT plus the LLVM
targets above. Wine's macOS configuration needs the llvm-mingw and bison 3
directories on PATH; `make -j6 include/all` generates the IDL headers the unix
builds consume. Clone FreeType as described in `build/freetype-ios/build.sh`.
Run `build/stage-licenses.sh` before the app build.

The scripts now bootstrap the wineserver archive from Wine's unchanged server
sources, generate airconv's three shader headers, and create the combined
DXMT/LLVM archive on first use. FEX explicitly selects arm64 and cortex-a78
instead of probing Linux's `/proc/cpuinfo`. The optional page-wait diagnostic
counter is compile-probed; SDKs without that field report `pgw=-1`.

The clean-build work from PR #261 is combined here. Run
`bash build/wine-macos/configure.sh` to configure the host Wine headers, and
`bash build/llvm-ios/build.sh` to build host llvm-tblgen and the iOS LLVM
archives. The latter disables app bundles, terminfo, zlib, and zstd for the
libraries the app links. FreeType's build script fetches its pinned release
when absent and refuses to replace an existing incomplete source directory.
The FEX build includes the external archives the app links. The wineserver
build selects unchanged sources from Wine's Makefile and excludes this fork's
replacement objects. It does not need a separate fixed-list base builder.

These combined changes have host script checks. A new full native-library or
IPA build has not been run for the consolidation.

This run reused the release's i386 PE farm and the tracked PE resources, with
separately rebuilt ARM64EC ntdll and aarch64 wow64win. It did not rebuild every
PE module or the Windows FEX modules, so it does not establish a complete
clean-machine release build. The Microsoft x64 runtime resources came from
Microsoft's `vc_redist.x64.exe`, as described above. Device installation and
game compatibility are separate checks from successful native compilation.

Development signing also needs a provisioning profile authorizing both
`com.apple.developer.kernel.increased-memory-limit` and
`com.apple.developer.kernel.extended-virtual-addressing`. An existing wildcard
profile without those capabilities can sign an app which installs but cannot
reserve the WoW64 guest window. Use an explicit app identifier and regenerate
its profile through Xcode's normal signing workflow; retain those entitlements
in the app signature. On the tested M1 iPad this changed the observed task map
from 17 GB to 63 GB. This removes that reservation limit; it is not proof that
every 32-bit child process starts successfully.

A recipient of a built package can obtain the complete corresponding
source of every LGPL library (Wine fork, GnuTLS, Nettle, GMP, FFmpeg) from the
repository, and the application source and build scripts above. Whether
they can actually relink depends on assembling the "not in the repository"
inputs and re-executing the UNVERIFIED steps; that end-to-end clean-machine
rebuild, signing and installation has NOT been performed. Until it is,
docs/LICENSING.md keeps the relink capability marked unverified. The
alternative the LGPL offers, shipping the application's object files, is
not currently done.

## Optional experimental Windows x64 Vulkan route

See `build/vulkan-ios/README.md` for the pinned MoltenVK input, explicit
`MADEIRA_MOLTENVK=1` native builds and optional app link flag, Wine DLL builds,
and Windows-side enumerate/readback/presentation fixtures. The normal native
build and app link do not require MoltenVK. Existing prerequisites above still
apply; this route is not a replacement bootstrap or complete Vulkan support.

The combined graphics source selects native WGL with OpenGL ES or Zink by
default. `env.MADEIRA_OPENGL = 1` selects the separate Mesa-on-D3D12 Windows
overlay when its DLLs are built. `vulkan = static` selects the optional static
MoltenVK backend; the app requires that backend to be linked. The dynamic
MoltenVK and KosmicKrisp choices share the same retained-layer surface adapter.

### Complete IPA runtime checks

`tools/build-ipa.sh` builds Dock, the 64-bit Windows runtime, and the optional
OpenGL/Vulkan backends before packaging. Wine Mono still downloads on first use.
The default graphics settings remain unchanged.

CI keeps seven separate runtime caches. Each cache uses its own source recipes,
submodule pins, and the actual SDK/compiler identity. An app-only or validation-only
change reuses those binaries. A failed or missing transfer rebuilds the affected
component. Successful components remain cached if another component fails.

`tools/build/runtime-components.py verify all` checks the staged files before
Xcode builds the app. Packaging then writes `runtime-build.json` with the source
keys and final bundle hashes. `tools/build/runtime-components.py ipa dist/Madeira.ipa`
checks a completed IPA, including Dock, the graphics drivers, and their notices.
Run this command from the matching checkout and build environment. CI calls the
same check before it uploads a fresh or cached IPA.
