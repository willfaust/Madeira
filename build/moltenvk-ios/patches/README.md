# MoltenVK patches

`build/moltenvk-ios/build.sh` applies the numbered patches here, in order, to the
MoltenVK checkout (`MOLTENVK_SRC`, default `research/MoltenVK`) before `make ios`.
Each is applied once: a patch whose reverse applies (`git apply --reverse --check`)
is already in the checkout and is skipped. After a patch here changes, reset the
checkout (`git -C "$MOLTENVK_SRC" checkout -- .`) and run the script again. The
patches change MoltenVK code and are offered under its licence (Apache-2.0).

- `0001-idtech7-device-features.patch`: with `MADEIRA_MVK_IDTECH=1`, the device reports
  subgroup operations in vertex, geometry and tessellation evaluation shaders, the
  `geometryShader`, `depthBounds`, `wideLines` and `shaderCullDistance` features, and
  AMD's vendor ID. idTech 7 (DOOM Eternal) stops at device or pipeline creation without
  them. Metal has none of those subgroup stages; this only reports them, as the community
  workaround in KhronosGroup/MoltenVK#2818 does. The variable is read once per process,
  and Zink shares the library, so it belongs in the game's own config.
- `0002-idtech7-double-as-float.patch`: with `MADEIRA_MVK_IDTECH=1`, generated MSL that
  names `double` (to `double4`) is compiled with `float` in its place. Metal has no
  double, and a DOOM Eternal compute shader that rounds with it failed to build, so its
  pass was missing from every frame.
- `0003-fps-limit-present-pacing.patch`: a present with no desired present time waits
  for the session's FPS limit (`presentAfterMinimumDuration`), as DXMT's presents do.
  The limit is the app's `madeira_get_vsync_locked()`, looked up with
  `dlsym(RTLD_DEFAULT)`: 1, 3 and 4 are 60, 30 and 40 FPS; 0 (display maximum), 2
  (uncapped) or a process without the symbol present at once.

The patches were made against MoltenVK 1.4.3 (`5189f8d`), with which DOOM Eternal ran
at 55-60 fps on an iPhone Duo and an M4 iPad. They also apply cleanly, in order, to the
pinned v1.4.2 (`db66022`); a build from it has not been run.

They are not in `vulkan = static` (`build/vulkan-ios`), which links the official v1.4.2
archive or the cache-export build, whose script refuses any other source change; a game
that needs them uses `vulkan = moltenvk` (`app/Madeira/vulkan/README.md`).
