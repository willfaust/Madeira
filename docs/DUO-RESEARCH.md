# iPhone Duo research notes

These notes index the foldable-layout, controller and Vulkan work on the `iphone-duo-support` branch.

## Foldable layout and input

| Area | Finding | Source |
| --- | --- | --- |
| Hinge detection | On iOS 27.1, the hinge angle can cross the layout threshold before the hinge status or division region updates. The layout enters after more than 10° of bend from flat and exits below 5°. It resamples the division after hinge changes and requires at least 120 points of usable height on each side. | [Fold detection](DUO.md#reading-the-fold) |
| Folded session | The game stays above the fold. The lower deck owns touches, including menu and touch controls, so deck input does not leak through as a game mouse event. Connecting a controller presents an alternate deck. | [Game area](DUO.md#the-upper-half-the-game) · [Deck](DUO.md#the-deck) |
| Open portrait | With a controller, an edge swipe can pin a letterboxed game. Without a controller, an adequately sized area at the bottom can hold touch controls. The open-flat Duo can meet that geometry. | [Controller](DUO.md#portrait-with-a-controller) · [Touch controls](DUO.md#portrait-with-touch-controls) |
| Controller assignment | The default reserves player one at launch. The Duo notes trace a DOOM Eternal issue in which the game did not accept the touch controller when the slot was assigned too late. | [Branch history](https://github.com/slushiimusic/Madeira/commits/iphone-duo-support/) |

The simulator’s `-fold` argument exercises the split geometry. Physical hinge events, division timing and controller transitions need hardware checkouts.

## DOOM Eternal and Vulkan

- The branch documents an executable launch route using the iOS MoltenVK build and its opt-in idTech compatibility patches. The Steam launcher is a separate case. Its Chromium allocator requests a highly aligned virtual-address reservation that the documented build does not handle for that launcher. See [Vulkan runtime notes](../app/Madeira/vulkan/README.md).
- The idTech patches report the capabilities the title probes, translate the affected shader’s double-precision constructs to float in generated Metal shader code, and pace MoltenVK presents against the session FPS setting. These are compatibility changes. Precision, visual output and frame pacing still need to be compared in the same scene. See [MoltenVK patch notes](../build/moltenvk-ios/patches/README.md).
- Earlier Vulkan presents were missing from the FPS counter. The updated host wrapper counts successful and suboptimal presents, leaves failed presents out of the count, and holds submissions while the app is inactive. The wrapper regression uses a fake host Vulkan library. See the Vulkan wrapper test in the [branch history](https://github.com/slushiimusic/Madeira/commits/iphone-duo-support/).
- The branch records that diagnostics and their logging caused hitches during DOOM Eternal testing on the Duo. Library launches now use lean diagnostics by default. Future comparisons should record whether diagnostics and the deck glow were enabled. See [branch history](https://github.com/slushiimusic/Madeira/commits/iphone-duo-support/).

### Physical-device results

| Hardware | Observed result | Conditions |
| --- | --- | --- |
| iPhone Duo (iPhone19,4), iOS 27.2 | DOOM Eternal ran at a reported **55–60 FPS** through Madeira Dock. Ultimate Doom and other library titles were also exercised. | Earlier Madeira base `e3a88fd` with the same Vulkan changes and MoltenVK 1.4.3. Folded, flat and upright modes were exercised with touch controls and a Bluetooth controller. |
| M4 iPad Pro | DOOM Eternal ran at a reported **60 FPS**. | Earlier device build with the same Vulkan changes. |

The device runs used a stand-in to start `DOOMEternalx64vk.exe`. The documented in-app Program selection and the rebased branch have not been verified on hardware. The patches applied to pinned MoltenVK 1.4.2, with no device run of that build recorded. A controlled frame-time capture and long-session thermal results are still missing. See [Vulkan runtime notes](../app/Madeira/vulkan/README.md).

## Earlier research for comparison

The September 2026 Madeira audit reviewed [upstream revision `97e2ce2`](https://github.com/willfaust/Madeira/tree/97e2ce26e6dc9e4a38976f3b5deb9272d64558eb). That revision and the Ember and Lucid experiments are historical context for the current branch:

- Ember ran a native Freedoom engine on an iPhone. The local Windows-game runtime was a separate experiment.
- Lucid PC demonstrated Tetris Effect with the debugger-assisted Wine/FEX path. Lucid SE build 86 used an interpreter with no debugger on an iPhone 15 Pro Max. It passed its multicore and graphics/input fixtures, then reached a titled Tetris window that stayed black through a 20-minute observation. No gameplay was observed in that run.

For a new Duo capture, record the exact commit and iOS version, launch entry and Vulkan build, hinge and controller state, resolution and graphics settings, chosen frame limit, frame-time data, and whether the session completed or was stopped. This makes the Duo run comparable across builds and avoids conflating the older interpreter results with the current Vulkan path.
