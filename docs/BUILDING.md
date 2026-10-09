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

## Inputs that are not in the repository

| Input | Why absent | How to obtain | Verified from clean |
|---|---|---|---|
| `toolchains/llvm-mingw-20260421-ucrt-macos-universal/` | 122 MB third-party toolchain | `llvm-mingw-20260421-ucrt-macos-universal.tar.xz` from https://github.com/mstorsjo/llvm-mingw/releases/tag/20260421, SHA-256 `bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7`, extracted under `toolchains/` | tarball hash recorded; download UNVERIFIED |
| `toolchains/llvm-project/` + `toolchains/llvm-ios-build/` + `toolchains/llvm-host-build/` | LLVM built for iOS (hours) | upstream llvm-project at commit `8dfdcc7b7` ("[libc++] Fix memory leaks when throwing inside std::vector constructor"); configure `llvm-ios-build` with `-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_BUILD_TYPE=Release -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 -DLLVM_TARGET_ARCH=host -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= -DLLVM_BUILD_TOOLS=Off -DLLVM_INCLUDE_TESTS=Off -DLLVM_ENABLE_ZLIB=Off` (values read back from the existing CMakeCache); a host build for tablegen lives in `llvm-host-build` | recipe reconstructed; UNVERIFIED |
| `research/GPTK/Metal Shader Converter 4.0 beta 2.pkg` | Apple installer, 30 MB, licence-bound | Apple developer downloads; SHA-256 `1acc33c87ea663933df89721a998d066106685473020bcbe007cee7a16155734` (pinned in `build/madeira-d3d12/deps.sh`). Only needed to REBUILD the converter fetch; the library itself is tracked | n/a |
| `app/Madeira/x86_64-vcruntime/` | Microsoft Visual C++ 2015-2022 x64 runtime DLLs (concrt140, msvcp140*, vcamp140, vccorlib140, vcruntime140*), redistributable under Microsoft's terms, not under this repository's licence | extract from Microsoft's `vc_redist.x64.exe` (or copy from `C:\Windows\System32` of a licensed Windows install) into that folder | UNVERIFIED |
| `build/wine-mono/wine-mono-11.0.0/` (optional) | Wine Mono, the .NET Framework runtime Wine's mscoree loads (not Microsoft code; licences in `build/wine-mono/COPYING` and `THIRD-PARTY-NOTICES.md`), 41.6 MB download, 228 MB unpacked | `bash build/wine-mono/fetch.sh` downloads `wine-mono-11.0.0-x86.tar.xz` from https://dl.winehq.org/wine/wine-mono/11.0.0/ and checks its SHA-256; `--source` also fetches the matching source tarball. Version and hashes are pinned in `build/wine-mono/pin.sh`, which does not follow `WINE_MONO_VERSION` in `wine/dlls/mscoree/mscoree_private.h`. The Xcode phase "Bundle Wine Mono" runs `build/wine-mono/bundle.sh`, which copies it into `Madeira.app/wine-mono` without the `lib/mono/*-api` reference assemblies and patches the bundled `mscorlib.dll`: **a dirty hack** (4 IL bytes: `GC.Collect` with `GCCollectionMode.Optimized` returns, for Terraria), pinned to the exact file by SHA-256 so the build stops on any other mscorlib; TODO: replace it with a Wine Mono built from source or an upstream fix (see the TODO in `bundle.sh`). Without the folder the app builds without Mono, and .NET Framework programs fail with "Wine Mono is not installed". **Release builds leave Wine Mono out** (2026-10-06): the packaging step deletes `Madeira.app/wine-mono`, and the app downloads it from WineHQ on first use (setup or Settings › .NET Framework, `app/Madeira/WineMono.swift`) | fetch + bundle run on the development machine 2026-10-05; not from a clean checkout |
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
   - `FEX/build-arm64ec`: `build/fex-arm64ec/build.sh` (configures with `FEX/Data/CMake/toolchain_mingw.cmake` and the recorded options on first run, builds target `arm64ecfex`, copies `Bin/libarm64ecfex.dll` to `app/Madeira/arm64ec-windows/xtajit64.dll`). The build step was verified this session; the first-run configure in the script is reconstructed from CMakeCache and UNVERIFIED.
3. Wine (submodule, branch madeira-lgpl):
   - unix side: `build/ntdll-unix/build.sh`, `build/wineserver/build.sh`,
     `build/win32u-unix/build.sh` -> `app/Madeira/lib{ntdll_unix,wineserver,win32u_unix}.a`. Verified on the development machine.
   - PE side: `build/wine-pe/build-ntdll.sh` (configures `wine/build-arm64ec` with `--enable-archs=arm64ec --without-x --disable-tests --enable-winegstreamer` on first run, builds `dlls/ntdll`, strips, pads to SizeOfImage + 0x50000, copies to the app). Other PE modules: `build/wine-pe/build-modules.sh <name>...` (same tree; it builds each module's DLL target `dlls/<name>/arm64ec-windows/<name>.dll`, strips it with `--strip-debug` like every shipped builtin and installs it into `app/Madeira/arm64ec-windows/`, or into `$DEST`). Building the DLL target rather than `make -C dlls/<name>` is also what winegstreamer needs (enabled by `--enable-winegstreamer` although GStreamer is absent, since its unix side is `build/ntdll-unix/winegstreamer_unixlib_ios.c`). Without arguments the script rebuilds the stock builtins added for games: `cryptsp`, `d3dx11_43`, `msvcp110`, `msvcr110` and `xaudio2_7` (committed in `app/Madeira/arm64ec-windows/` like every other builtin). It needs bison 3 for `tools/wrc` (macOS ships 2.3; Homebrew's is used when installed). The strip/pad step was verified this session; the configure step is UNVERIFIED from clean; build-modules.sh reproduced the five default DLLs at their shipped sizes on the development machine (2026-10-03).
   - `app/Madeira/arm64ec-windows/` is the DLL farm: every file in it is linked into the prefix (`system32` for x64 sessions, and `sysx64`), so a Wine module is only available if it was built and copied there. The native D3D12 path needs two stock modules in addition to the existing ones: `dcomp.dll` (`make -C dlls/dcomp`; a 64-bit Godot 4 engine loads it before it creates its D3D12 device, and gives up on D3D12 without it) and `ktmw32.dll` (`make -C dlls/ktmw32`; an optional import the same engine probes).
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
6. App: `xcodebuild -project app/Madeira.xcodeproj -scheme Madeira -destination 'generic/platform=iOS' -allowProvisioningUpdates build` (Debug is the configuration that runs the games; Release builds have crashed the guest), then zip `Payload/Madeira.app` into an IPA and sideload. Verified this session on the development machine.
7. WoW64 (32-bit programs, optional): `build/wine-i386/build.sh` (i386 Wine farm
   -> `app/Madeira/i386-windows/`), `build/fex-wow64/build.sh` (FEX WOW64 module
   -> `app/Madeira/aarch64-windows/xtajit.dll`) and the aarch64 `wow64.dll` /
   `wow64win.dll`; see docs/WOW64.md, "Building". UNVERIFIED on macOS.

## Status of the LGPL relink question

A recipient of a built package can obtain the complete corresponding
source of every LGPL library (Wine fork, GnuTLS, Nettle, GMP, FFmpeg) from the
repository, and the application source and build scripts above. Whether
they can actually relink depends on assembling the "not in the repository"
inputs and re-executing the UNVERIFIED steps; that end-to-end clean-machine
rebuild, signing and installation has NOT been performed. Until it is,
docs/LICENSING.md keeps the relink capability marked unverified. The
alternative the LGPL offers, shipping the application's object files, is
not currently done.

## External storage checks

`python3 tests/host/typecheck-ios.py` type-checks the production Swift sources
with the installed iOS SDK without linking native archives. It is not a complete
app build. The download integration harness supports macOS and Linux; see
[EXTERNAL_STORAGE.md](EXTERNAL_STORAGE.md) for commands and validation limits.

The independent data-access probe under `tests/device/ssd-probe` builds with
XcodeGen and Xcode. Use a separate bundle ID and a dedicated scratch folder.
Windows execution fixtures live under `tests/device/ssd-execution`; they require
llvm-mingw. Neither probe is part of the production app target.

### Native link validation for external storage

On 2026-10-09, the main-based SSD change compiled and linked in Debug with Xcode
27 / iOS 27 SDK, then passed deep/strict code-signature verification as an isolated
app. This validates the native link, not device gameplay. The application and
pinned submodule sources were unchanged by the prerequisite work below. Tracked
Windows DLL farms and the converter remain binary inputs; Microsoft runtime DLLs
were staged from the preserved published app, not rebuilt or committed.

The clean build required these additions to the recipes above:

- Install Bison 3 and put it before macOS Bison in PATH for Wine configuration.
- Initialize the pinned FEX, Wine and DXMT submodules and their required nested
  dependencies. FEX's iOS configuration also needs
  `-DCMAKE_SYSTEM_PROCESSOR=arm64 -DTUNE_CPU=none`: the default native CPU probe
  reads Linux `/proc/cpuinfo`. Run configuration fresh if the first attempt cached
  an empty processor. Build `JemallocLibs` in addition to `FEXCore` and
  `FEXCore_Base`; the app links all three. No FEX source edits were needed.
- Build FFmpeg, GnuTLS headers/libraries, FreeType 2.13.3 and the locked pairing
  library using their repository scripts. These builds succeeded on macOS.
- Configure `wine/build-macos` with `--enable-win64 --without-x --disable-tests
  --enable-winegstreamer`, `ac_cv_func_pipe2=no`, and llvm-mingw on PATH. The
  host configure probe otherwise enables the newer pipe2 API, unavailable on the
  tested older iPad OS; disabling that feature selects Wine's existing portable
  pipe/fcntl fallback without a source patch. Generate the `include/*.h`
  targets in its Makefile before running the native Wine scripts. The wineserver
  script patches an existing base archive: on a clean checkout, first compile
  the Wine `server/Makefile.in` source list using the same iOS flags and shims in
  `build/wineserver/build.sh`, archive those objects into
  `build/wineserver/obj/libwineserver.a`, then run that script's normal patch and
  symbol-renaming pass. The generic bootstrap recipe used for this validation
  came from commit `f4c9a17` (`build/wineserver/bootstrap-base.sh`); no OpenGL or
  pipe compatibility source changes were imported.
- LLVM source was pinned to `8dfdcc7b7bf66834a761bd8de445840ef68e4d1a`. Build a
  Release host `llvm-tblgen`, then the iOS libraries with that tool. In addition
  to the options above, use `LLVM_NO_DEAD_STRIP=ON` to avoid old AddLLVM selecting
  Linux `--gc-sections` for iOS, disable zstd/terminfo/libedit, and supply
  `CMAKE_POLICY_VERSION_MINIMUM=3.5` for current CMake. No LLVM source edit is
  required. Build the library targets listed by `llvm_deps` in
  `dxmt/src/airconv/meson.build`; unused LLVM tools/backends are unnecessary.
- Generate `air_msad.h`, `air_samplepos.h` and `air_tessellation.h` from the
  corresponding DXMT shaders with its Meson Metal/xxd pipeline. The native build
  script does not generate them or add their output directory to airconv's
  include flags. Use `-std=metal3.1 --target=air64-apple-macos14.0`, then
  `xxd -n <basename> -i <input.air> <output.h>`. Compile `airconv_context.cpp`
  with the generated-header directory on its include path. The newer Metal
  compiler rejected the tessellation intrinsic's argument count; installed Metal
  `32023.883` compiled the unmodified shader successfully.
- Combine the 87 DXMT objects and its 34 declared LLVM archives with
  `xcrun -sdk iphoneos libtool -static` into `libdxmt_combined.a`, and copy it to
  `app/Madeira`. The script only refreshes that combined archive if it exists.
- Build and stage `build/madeira-dock/build.sh --check` before packaging. A
  successful Xcode link does not guarantee this ignored output is present:
  without `arm64ec-windows/dockhost.exe`, the app hides the Steam library.
  Check the final bundle for the executable and `dock-notices.txt`. For 32-bit
  games, also verify `i386-windows/ntdll.dll` and the WoW64 components described
  above; an empty resource directory is insufficient. The full
  `build/wine-i386/build.sh` subsequently built the Wine farm and DXMT PE
  components on macOS with Bison 3, llvm-mingw and Meson available.
- Run `build/stage-licenses.sh` before the app build. Use
  `MTL_LANGUAGE_REVISION=Metal31` for the app's shaders on the tested older iPad OS.
  The app links as iOS 17 while DXMT's existing script targets iOS 18; the linker
  warns about this mismatch. This build does not establish iOS 17 compatibility.

The signing team, bundle identifier and display name were isolated test-build
settings. Native source linking replaces the earlier frontend-only diagnostic
build; device validation still needs to exercise this exact implementation.
