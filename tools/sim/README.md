# Madeira in the iOS Simulator

`tools/sim/setup.sh` builds the app for the simulator, installs it on an iPhone simulator (and an iPad one on request) and
launches it. It is for looking at and testing the app's screens (library, settings, onboarding, game pages),
not for running games.

```sh
tools/build-ipa.sh        # once: the device runtime the simulator build is made from (BUILDING.md)
tools/sim/setup.sh        # or: tools/sim/setup.sh --runtime, which runs build-ipa.sh first
```

The device is the newest iPhone simulator installed; set `SIM_IPHONE` (name or UDID) to choose. `SIM_WITH_IPAD=1` (or `SIM_IPAD`) also installs on an iPad simulator. `SKIP_ONBOARDING=0` keeps first-run setup (the default opens the library). Build output, `build.log`, the device UDIDs and launch screenshots go to `build/sim/`.

## How it works

- `relabel-archives.py` copies the device static archives with the platform in each arm64 object changed from
  iOS to iOS Simulator (one field, same size). No recompiling. The Rust pairing library is built for
  `aarch64-apple-ios-sim` instead.
- `make-sim-project.py` writes `app/MadeiraSim.xcodeproj` (ignored by git): the project with archive paths
  pointing at those copies and MetalFX, which the simulator SDK lacks, dropped.
- `SimStubs.m` supplies what the simulator build leaves out: `FEXBridge.mm` and `WiniosGL.m` are excluded
  (FEX's generated headers, EAGL's IOSurface upload and `presentDrawable:afterMinimumDuration:` are
  device-only), and MetalFX's classes are empty stand-ins.
- The app is signed ad hoc without the device entitlements; with them the simulator refuses to launch it. It carries only an application identifier and a Keychain access group, which the store sign-ins (Steam, itch.io) need to save their tokens.

## Limits

Wine and games do not run here. The archives are device code (no x18 handling for the simulator), there is no
OpenGL presenter, no MetalFX and no JIT. Use a device for anything that touches the runtime.

## Driving the app

With the skills from `.claude/skills/README.md` checked out (`run-simulator`, `ios-simulator-skill`,
`flow-walkthrough`), an agent can map the screen, tap by accessibility label and screenshot, using the UDIDs in
`build/sim/*.udid`. `ios-simulator-skill` needs `idb`:

```sh
brew trust --formula meta/fb/idb-companion && brew install meta/fb/idb-companion   # after: brew tap meta/fb
pip3 install fb-idb
bash .claude/skills/ios-simulator-skill/scripts/sim_health_check.sh                # all green: ready
python3 .claude/skills/ios-simulator-skill/scripts/navigator.py --udid "$(cat build/sim/iphone.udid)" --find-text "Stores" --tap
```

Tap a coordinate with `idb ui tap X Y --udid ...` (points, not pixels: a screenshot's pixels divided by 3).
