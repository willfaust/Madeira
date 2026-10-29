# Mesa patches

Numbered patches (`0001-...` to `0008-...`) are for the OSMesa + Zink build of Mesa 25.0.7
(`build/mesa-ios/build.sh`). Patches named `kosmickrisp-ios-*` are for the KosmicKrisp Vulkan
driver build of Mesa 26.2.4 (`build/mesa-ios/build-kosmickrisp.sh`, `docs/KOSMICKRISP.md`). Each
script applies only its own set. All patches change Mesa code and are offered under Mesa's
licence (MIT).

- `0008-zink-moltenvk-zero-unwritten-fs-inputs.patch`: Metal refuses a fragment input that the
  vertex shader does not output at the same location, component and type. At program link
  (MoltenVK only), the vertex stage first stores zero into every varying component the fragment
  shader reads, and both stages get one variable per slot with the same shape.
  `MADEIRA_ZINK_LINK_FS_INPUTS=0` turns this off, and `=1` turns it on for other drivers.
- `kosmickrisp-ios-0001-wsi-metal-no-display-sync-on-ios.patch`: the Metal WSI sets
  `CAMetalLayer.displaySyncEnabled`, which iOS does not have. On iOS it is skipped, so an
  immediate-mode swapchain presents with vsync.
- `kosmickrisp-ios-0002-link-system-frameworks.patch`: links Foundation, CoreGraphics and libobjc
  into `libvulkan_kosmickrisp.dylib`. Upstream relies on `-undefined dynamic_lookup` for them. With
  the patch, only the driver's weak, unimplemented entry points are looked up at load time, and
  those resolve to NULL.
- `kosmickrisp-ios-0003-export-get-proc-addr-on-apple.patch`: on Apple platforms the driver also
  exports `vkGetInstanceProcAddr` and `vkGetDeviceProcAddr`. An app can then `dlopen` it and use it
  as its libvulkan without a Vulkan loader, the same way it uses MoltenVK.
- `kosmickrisp-ios-0004-metal4-drawable-sync.patch`: a Metal 4 queue must wait for a
  `CAMetalLayer` drawable (`waitForDrawable:`) before it commits work that writes it, and the
  layer's `residencySet` must be on the queue so the drawable texture is resident. KosmicKrisp
  only signalled and presented the drawable, so on iOS the copy into the drawable was lost and the
  window stayed black while the game ran. The queue now adds each layer's residency set once (up to
  eight, retained) and waits for the drawable before the commit. `MADEIRA_KK_DRAWABLE_SYNC=0`
  turns this off.
- `kosmickrisp-ios-0005-release-presented-drawables.patch`: a command buffer retained its drawable
  when the WSI encoded the present, and the submit dropped the pointer without releasing it. A
  `CAMetalLayer` reuses a drawable only after every reference is gone, so after a few frames
  `nextDrawable` blocked for a second at a time and the swapchain stalled. The submit now releases
  the drawable after presenting it, and re-recording or destroying an unsubmitted command buffer
  releases it too. The commit feedback handler is also added once at queue creation instead of on
  every submit, where it piled up on the shared commit options (`MADEIRA_KK_FEEDBACK_ONCE=0`
  restores the per-submit add).
- `kosmickrisp-ios-0006-present-probe.patch`: diagnostics. On presents 1-3, 10, 30, 120, 600 and
  3000 the queue reads back the last copy's source texture and the drawable through a Metal 3
  queue that waits on a shared event, and logs pixel statistics as `[kk-present]`; the first probe
  of each layer also logs its state. `nextDrawable` time-outs are logged as `[kk-wsi]`.
  `MADEIRA_KK_PRESENT_PROBE=0` turns the readback off.
