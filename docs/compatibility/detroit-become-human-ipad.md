# Detroit: Become Human — experimental iPad observations

Contributor: Jelly-RayTian. Device: the contributor's Apple M5 iPad.
The screenshots below were supplied on 2026-10-20. The contributor confirmed
camera control in the in-game scene, and on 2026-10-27 again reported running
the game using the earlier Detroit experimental package.

**Observed milestone: shader compilation, main menu, an in-game scene and camera
input.** This is an experimental-build compatibility report, not verification
of Madeira main, a full playthrough, sustained performance or stable gameplay.

## Visible results

### Main menu

![Detroit main menu rendered on the contributor's iPad](images/detroit-menu.jpg)

### In-game scene

![Detroit in-game scene rendered on the contributor's iPad](images/detroit-scene.jpg)

The contributor's confirmation of camera control is separate from the still
image: a screenshot alone cannot establish input response or frame continuity.
The inherited overlay's `0 FPS` is not a reliable Vulkan presentation count;
no numerical frame-rate claim is derived from these captures.

These are authorized contributor screenshots. JPEG metadata was removed without
changing the visible image. Game visuals remain the property of their respective
rights holders; the screenshots are compatibility observations, not game assets
licensed as Madeira source. No game executables, saves, account files or raw
private logs are included.

## Build provenance and reproduction boundary

The successful observation used a broader local **Debug** experiment based on
Madeira `279fd0f83170425db002fe25d6bd62f6355f497d`, with the Wine Vulkan route,
VM changes and additional MoltenVK compatibility/cache work. Wine was pinned to
`9129e9684daaeae70da9435e7c6060e59392634e`; MoltenVK was based on v1.4.2
`db66022459ffb663aa2b50f6b018bc2e124f5edf`. JIT was enabled on the iPad.

The contributor subsequently published the
[experimental source record](https://github.com/Jelly-RayTian/Madeira-Experimental/blob/509d54532f849d75f27b32c0fb412ee9fa228fd9/docs/EXPERIMENTAL.md)
and its
[file/patch manifest](https://github.com/Jelly-RayTian/Madeira-Experimental/blob/509d54532f849d75f27b32c0fb412ee9fa228fd9/docs/EXPERIMENTAL-SOURCE-MANIFEST.json).
That source snapshot includes changes added after the pictured session. It is
**not an exact source-to-binary reconstruction of the earlier scene build**.
The later archived integer-fragment-output IPA is also not the screenshot build;
its hash must not be used to identify these captures.

The associated successful-scene investigation recorded Default Metal optimization
and the opt-in missing-vertex-input policy, with reduced logging:

```ini
env.WINEDEBUG = err+all,err-virtual,warn+vulkan
env.MADEIRA_VK_METAL_LIBRARY_OPTIMIZATION = default
env.MADEIRA_VK_ZERO_UNBOUND_VERTEX_INPUTS = 1
```

These settings belong to the broader patched experiment. They are not a
standalone recipe for stock Madeira or the official MoltenVK archive. The zero
input policy is an opt-in compatibility choice for missing inputs, not proof that
an application request is conformant. Do not add game IDs, patch game addresses,
spoof features or bypass Steam authentication to reproduce this report.

## What still failed or remains unknown

- Shader compilation/loading was slow, and earlier runs remained black or were
  memory-limited. No cold/warm compilation timing improvement is established.
- A later in-game run displayed a WineVulkan queue-submit assertion. Its nearby
  Metal error reported a float fragment output incompatible with an R32Uint
  attachment; the investigation also saw a null native pipeline bind. Entering
  the scene did not establish stable continued gameplay. Later compatibility
  experiments are not retroactively credited to the earlier screenshots.
- No full chapter, save/reload cycle, long-session stability, audio correctness,
  image correctness audit or cross-device comparison is established here.
- No isolated patch is proven necessary or sufficient for the full observed
  game result. The broad experiment is unsuitable as a drop-in upstream patch.

## Relationship to the upstream work

[#454](https://github.com/willfaust/Madeira/pull/454) retains the reduced Vulkan
route from #400 alongside the other graphics routes.
[#447](https://github.com/willfaust/Madeira/pull/447) retains the scoped
fixed-address allocation contribution originally submitted as #396.
[#456](https://github.com/willfaust/Madeira/pull/456) separately isolates a direct
pipeline-cache export regression. These are separate reviews; the game images
do not validate their integrated builds or prove any one of them runs Detroit.

A future upstream compatibility claim should identify a matching source revision,
build manifest/App UUID and config, then verify the Windows x64 Vulkan fixture
chain and repeat the menu/scene/input observation on that package. Record later
failures as well. Preserve caches and saves; do not ask users to delete them just
to obtain a clean-looking run.

## Complete experimental sources and historical IPA

The [broader experimental source profile](../../build/vulkan-ios/experimental/README.md)
contains all historical source changes, the ten MoltenVK patches, explicit build
entry points, generic regressions and the historical unsigned IPA download and
hash record. Its source helper reconstructs the published snapshot's exact Git
tree without replacing main. The optional current-main MoltenVK profile is a
separate build; neither it nor the historical IPA is retroactively identified
as the earlier screenshot package.
