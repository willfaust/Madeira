# vulkan/ — Vulkan for x64 programs, and vkd3d-proton (opt-in)

`arm64ec-windows/` holds ARM64EC DLLs that are linked into a prefix only for a
session that asks for Vulkan (madeira.cfg `vulkan = ...` or `d3d12 = vkd3d`;
`WineProcessBridge.m`, `madeira_setup_vulkan`). They are deliberately outside
`arm64ec-windows/` at the bundle root, whose every file is linked into every
prefix: a program that probes for `vulkan-1.dll` must keep finding none by default.

- `winevulkan.dll`, `vulkan-1.dll`: Wine's Vulkan ICD and loader (tracked), built
  like every other builtin: `make -C wine/build-arm64ec dlls/winevulkan/arm64ec-windows/winevulkan.dll
  dlls/vulkan-1/arm64ec-windows/vulkan-1.dll`, then `arm64ec-w64-mingw32-strip --strip-debug`.
  Their unix side is linked into the app (`build/ntdll-unix/build.sh`, `build/win32u-unix/vulkan_ios.c`)
  and loads the Vulkan library from `gl/` (MoltenVK by default).
- `d3d12.dll`, `d3d12core.dll`: vkd3d-proton, built by `build/vkd3d-proton/build.sh`
  (git-ignored, like `gl/`). Used instead of madeira-d3d12's with `d3d12 = vkd3d`.

Without the vkd3d-proton DLLs the app still builds; `d3d12 = vkd3d` then logs that
madeira-d3d12 stays.

## DOOM Eternal

DOOM Eternal (`DOOMEternalx64vk.exe`) runs on MoltenVK with these lines in its own config
(Game details › This game's config). The same changes on an older Madeira tree ran it at
55-60 fps on an iPhone Duo and an M4 iPad; this tree has not run it on a device yet.

    vulkan = moltenvk
    env.MADEIRA_MVK_IDTECH = 1

- `gl/libMoltenVK.dylib` has to be built with `build/moltenvk-ios/patches`, which
  `build/moltenvk-ios/build.sh` applies (see the README there). `vulkan = static` does
  not have them.
- `MADEIRA_MVK_IDTECH` changes what MoltenVK reports for the whole session, so it goes
  in the game's config, not madeira.cfg.
- Steam's launch entry, `launcher\idTechLauncher.exe`, embeds Chromium, and its
  PartitionAlloc stops with int3: it asks for a reservation on a 32 GB or larger
  boundary, which the app's address map cannot give (`build/ntdll-unix/virtual_ios.c`
  places such pools only for SocialClubHelper.exe). Start `DOOMEternalx64vk.exe`
  instead. The device runs replaced the launcher with a stand-in that starts
  `..\DOOMEternalx64vk.exe` with the same arguments; choosing it under **Program**
  (the game's Steam page, Start with: The game) should do the same, but was not tried.
