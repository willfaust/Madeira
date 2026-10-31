# Broader Vulkan experiment: complete sources and optional MoltenVK profile

This is a **Draft experiment for review**, not a claim that current main plays
Detroit. It supplies the broader source work behind the contributor's earlier
menu/scene/camera observations, rather than only screenshots. Nothing in the
ordinary app/build path invokes these scripts or applies these patches.

There are two separate entry points:

- **Current main's static Vulkan route + ten-patch MoltenVK profile.** Build the
  explicitly selected archive below. This is a forward build option; it does not
  transplant old Wine adapters over current main.
- **Complete historical source reconstruction.** `historical/madeira.patch`
  contains all 91 source-file changes from base `279fd0f8` to published snapshot
  `509d5453`. The helper restores that entire tree, including the LGPL Wine
  overlay, old adapter/VM/diagnostic code and every original fixture. It verifies
  the exact tree ID `344ca88d8caa3fa4559651baa85ef6a0041f4e64`, all 77 file hashes
  in the original manifest and the Wine overlay hash. This is not a rewritten
  documentation-only summary or a patch that replaces current main.

## What is in the MoltenVK profile

Pinned upstream: `db66022459ffb663aa2b50f6b018bc2e124f5edf` (v1.4.2).
All ten source patches are included and SHA-256 checked, in order:

| Patch | Purpose / limit |
| --- | --- |
| 0001 | Keep vertex-input conversion contexts from contaminating each other |
| 0002 | Restrict integer-blending warnings to enabled blending |
| 0003 | Size pipeline-cache data before direct export (already isolated upstream separately) |
| 0004 | Bound shader-library cache residency; iOS profile default 256, `MADEIRA_VK_SHADER_CACHE_MAX_LIBRARIES=0` disables the bound |
| 0005 | Account for the nonserialized cache hint |
| 0006 | Retain specialization libraries across merged-cache ownership |
| 0007 | Observe actual Metal compiler inputs with `MADEIRA_VK_SHADER_COMPILE_DIAGNOSTICS=1` |
| 0008 | Opt-in zero inputs with `MADEIRA_VK_ZERO_UNBOUND_VERTEX_INPUTS=1` |
| 0009 | Opt-in Metal size optimization with `MADEIRA_VK_METAL_LIBRARY_OPTIMIZATION=size` |
| 0010 | Opt-in integer fragment-output compatibility with `MADEIRA_VK_INTEGER_FRAGMENT_OUTPUTS=1` |

The last policies address undefined/incompatible application inputs; they are
not Vulkan conformance guarantees. Integer output conversion is a compatibility
policy, not proof of correct game colors. Size optimization can reduce execution
performance and has no established iPad compilation-speed improvement here.
Cache bounding is not a total-device-memory cap. The ordinary upstream build
and official MoltenVK archive remain unchanged when this profile is not built.
No capabilities are fabricated, no game IDs/addresses are patched, and no
Steam/DRM/authentication behavior is changed by these patches.

## Build explicitly against current main

First assemble the normal prerequisites in the repository's `BUILDING.md`.
This optional path does not download or build FEX or change any submodule pin.
Use a dedicated MoltenVK checkout: the helper refuses unrelated tracked/staged
changes and only accepts the clean pinned source or the exact full series.

```sh
python3 build/vulkan-ios/experimental/prepare-sources.py check
bash build/vulkan-ios/experimental/build-moltenvk.sh prepare
# Real source build; fetches pinned MoltenVK prerequisites, then cleans/builds.
bash build/vulkan-ios/experimental/build-moltenvk.sh ios
bash build/vulkan-ios/fetch.sh  # pinned Vulkan headers and licence input
MADEIRA_MOLTENVK_LIBRARY="$PWD/toolchains/moltenvk-detroit-experimental/ios-arm64/libMoltenVK.a" \
  bash build/vulkan-ios/build.sh
MADEIRA_MOLTENVK=1 bash build/win32u-unix/build.sh
MADEIRA_MOLTENVK=1 bash build/ntdll-unix/build.sh
bash build/stage-licenses.sh
xcodebuild -project app/Madeira.xcodeproj -scheme Madeira -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/detroit-experimental-app \
  MADEIRA_VULKAN_LDFLAGS=-lmadeira_vulkan CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= build
mkdir -p build/detroit-experimental-ipa/Payload
cp -R build/detroit-experimental-app/Build/Products/Debug-iphoneos/Madeira.app \
  build/detroit-experimental-ipa/Payload/
(cd build/detroit-experimental-ipa && zip -qry -X Madeira-Detroit-experimental.ipa Payload)
```

This is a manual source-build recipe; running the general bootstrap afterwards
can replace native outputs. The Windows DLLs and other native libraries must
match the current main pins. The recipe has not established a whole-app build
or device result for this new combined profile. Real device signing uses the
contributor's actual certificate/profile; none is provided here.

Use `configs/detroit-baseline.cfg` (includes `vulkan = static`) for the first
current-profile reproduction. The separate integer-output config additionally
enables policy 0010; it is not established as fixing the later game assertion.
Preserve existing saves/caches; do not uninstall the app to obtain a fresh test.
A parallel installation requires your signing tool to use an allowed separate
bundle identifier and correctly handle the embedded JIT extension.

## Reconstruct every historical source change

```sh
python3 build/vulkan-ios/experimental/prepare-sources.py snapshot \
  --directory "$PWD/toolchains/detroit-historical-source"
cd toolchains/detroit-historical-source
# These are the older experiment's pins, deliberately separate from main.
git submodule update --init --recursive
bash build/experimental/apply-wine-overlay.sh
# Follow this reconstructed tree's docs/EXPERIMENTAL.md and build prerequisites.
```

The helper uses a detached worktree at the old base plus a staged source patch;
it makes no automatic commit and resets no existing checkout. Its reconstructed
tree must equal the published source snapshot before it reports success.
The historical experiment unconditionally linked Vulkan and removed the old
fixed-address relocation fallback more broadly than the accepted scoped fix.
That policy can regress other launchers; it is retained for source completeness,
not enabled by the current-main profile. Do not replace today's VM/Wine adapters
with those files in a production build. There are no FEX/DXMT source changes in
the source snapshot; inherited artifacts require their documented sources/tools.

## Historical unsigned IPA (download, hash and build identity)

The existing authorized Release contains the binary, configs and build manifest:

- [Unsigned Debug IPA, 111,480,832 bytes](https://github.com/Jelly-RayTian/Madeira-Experimental/releases/download/experimental-2026-10-20/Madeira-Experimental-2026-10-20-Debug-unsigned.ipa)
- [BUILD-MANIFEST.json](https://github.com/Jelly-RayTian/Madeira-Experimental/releases/download/experimental-2026-10-20/BUILD-MANIFEST.json)
- [SHA256SUMS.txt](https://github.com/Jelly-RayTian/Madeira-Experimental/releases/download/experimental-2026-10-20/SHA256SUMS.txt)

IPA SHA-256: `c48f9e645badf8fde57c739ad8a787116ab7551625f1166eb676b6b964efcb4e`.
App image UUID: `19C01ED6-159C-3067-AA9D-CFCB96F40DA5`.
Bundle ID: `com.willfaust.madeora` (retaining it during signing may replace an
existing installation; back up saves first). The archive is unsigned and has no
certificate, profile or pairing file. Its Vulkan DLL hashes are in the manifest.
The 111 MB IPA is a Release asset, not a binary added to source Git.

**These identities must not be conflated:** the earlier successful scene
screenshots, the published `509d5453` source snapshot, the historical integer-output
IPA and a new main+profile build are different evidence records. The snapshot
contains later work; it is not an exact reconstruction of the screenshot build.
This PR does not establish a source-matched rebuild of the historical IPA.
Entering a scene and camera input were observed; a later queue-submit/pipeline
failure remained. Stable gameplay, chapter completion, save/reload and frame rate
are not established by this submission.

## Verification

The source helpers verify hashes, exact historical tree reconstruction, full
MoltenVK series application and idempotence. Generic native GPU probes are in
`tests/vulkan/` with Windows-side fixtures in `tests/x64/`; existing newer upstream
fixtures are kept when names overlap. For a macOS build use `build-moltenvk.sh
macos`, then point the runners at its Vulkan headers and macOS libMoltenVK dylib:

```sh
python3 tests/vulkan/check-unbound-vertex-native.py HEADERS LIBMOLTENVK
python3 tests/vulkan/check-integer-output-native.py HEADERS LIBMOLTENVK
python3 tests/vulkan/check-cache-memory-native.py HEADERS LIBMOLTENVK
python3 tests/vulkan/check-metal-library-options-native.py HEADERS LIBMOLTENVK
```

Build the ordinary Windows x64 test executables (the composite programs must
link their component objects, not be compiled as standalone source files):

```sh
python3 tests/x64/build-vulkan-experimental.py \
  --headers toolchains/moltenvk/MoltenVK/include \
  --output build/detroit-windows-tests
```

Source completeness/preparation checks, without a game or account:

```sh
python3 tests/host/check-detroit-experimental.py \
  --moltenvk-source toolchains/moltenvk-detroit-source
```

These test actual native GPU readbacks when run, not Windows/Wine/iPad behavior.
A current-main iPad acceptance run still needs the Windows x64 Vulkan fixture
chain, followed by a source/build-identified menu/scene/input observation.
Do not upload game files, shader dumps, accounts, certificates or private logs.

Validation on the submitted source: the complete source/tree checks and helper
idempotence/rejection tests pass; a fresh macOS MoltenVK parent build with cached
external prerequisites passes; seven native suites pass (zero-input, integer
fragment outputs, cache memory/merge ownership, Metal options, integer-blend
warnings, compiler observer and vertex-cache reflection/reuse). Eight Windows
x64 fixture executables compile/link with warnings treated as errors. This does
not establish a clean-machine build, current-profile iOS app/IPA build or iPad
result. The existing historical IPA was checked for its recorded size/SHA-256,
ZIP integrity and all three recorded Vulkan/FEX DLL hashes.

## Licence and attribution

Madeira-side sources use GPL-3.0-or-later with the Madeira Converter Exception.
The Wine overlay retains LGPL-2.1-or-later and MoltenVK-derived changes retain
Apache-2.0; upstream notices remain in the pinned sources and historical patch.
Apple converter/Microsoft runtime terms are separate. Original source commits,
file hashes, contributor observations and AI assistance are recorded explicitly;
no FEX-generated code is submitted. The profile is not an official game port.
