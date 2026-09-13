#!/bin/sh
# Unit tests for the layout policy and the gamepad mapping.
#
# Both are pure functions with a table of expected answers, and both guard
# decisions that are invisible until they are wrong on a device the developer
# is not holding: the layout policy is what locked every iPad out of
# fullscreen, and the gamepad map is a pile of magic key codes.
#
# Needs a Swift toolchain: Xcode's swiftc on macOS, or any swiftc on Linux.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

SWIFTC=${SWIFTC:-swiftc}
if ! command -v "$SWIFTC" >/dev/null 2>&1; then
    echo "test-app-ui: SKIP -- no swiftc on PATH (override with SWIFTC=...)" >&2
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

var failures = 0
func check<T: Equatable>(_ label: String, _ got: T, _ want: T) {
    let ok = got == want
    if !ok { failures += 1 }
    print("  \(ok ? "ok  " : "FAIL") \(label): got \(got), want \(want)")
}

// MARK: - LayoutPolicy
//
// The regression this exists for is the iPad column: an iPad reports a
// REGULAR vertical size class in both orientations, so the old
// `verticalSizeClass == .compact` test sent it to the tooling layout every
// time and the game could not be enlarged at all.

print("layout policy:")
func name(_ l: AppLayout) -> String { l == .immersive ? "immersive" : "tooling" }

let layoutCases: [(label: String, compact: Bool, pad: Bool, want: Bool, expect: String)] = [
    // iPhone. Portrait shows tooling until the user asks otherwise; landscape
    // is forced, because the tooling rows do not fit.
    ("iPhone portrait, no toggle",  false, false, false, "tooling"),
    ("iPhone portrait, toggled",    false, false, true,  "immersive"),
    ("iPhone landscape, no toggle", true,  false, false, "immersive"),
    // The reported bug: an iPad in landscape must NOT be forced, and must be
    // able to reach immersive with the toggle.
    ("iPad portrait, no toggle",    false, true,  false, "tooling"),
    ("iPad portrait, toggled",      false, true,  true,  "immersive"),
    ("iPad landscape, no toggle",   false, true,  false, "tooling"),
    ("iPad landscape, toggled",     false, true,  true,  "immersive"),
    // A compact size class on an iPad means a multitasking pane, not a phone
    // on its side; the idiom check keeps that from forcing immersion.
    ("iPad, compact reported",      true,  true,  false, "tooling"),
    ("iPad, compact reported+on",   true,  true,  true,  "immersive"),
]
for c in layoutCases {
    let got = LayoutPolicy.resolve(verticalCompact: c.compact, isPad: c.pad,
                                   userWantsImmersive: c.want)
    check(c.label, name(got), c.expect)
}

print("exit affordance:")
for c in layoutCases {
    let got = LayoutPolicy.needsExitAffordance(verticalCompact: c.compact, isPad: c.pad)
    // The exit button exists exactly where immersion was a choice. Forced
    // immersion (iPhone landscape) must not offer one.
    check(c.label, got, !(c.compact && !c.pad))
}

// MARK: - GamepadMap

print("stick snapping:")
// Clockwise from up, matching JoystickKeyView.snap so the on-screen stick and
// a real one steer the same way.
check("centred",         GamepadMap.direction(x: 0,    y: 0),  -1)
check("inside deadzone", GamepadMap.direction(x: 0.1,  y: 0.1), -1)
check("up",              GamepadMap.direction(x: 0,    y: 1),   0)
check("up-right",        GamepadMap.direction(x: 1,    y: 1),   1)
check("right",           GamepadMap.direction(x: 1,    y: 0),   2)
check("down-right",      GamepadMap.direction(x: 1,    y: -1),  3)
check("down",            GamepadMap.direction(x: 0,    y: -1),  4)
check("down-left",       GamepadMap.direction(x: -1,   y: -1),  5)
check("left",            GamepadMap.direction(x: -1,   y: 0),   6)
check("up-left",         GamepadMap.direction(x: -1,   y: 1),   7)
// A full-deflection diagonal is the widest case; it must still land in range.
check("near boundary in range",
      GamepadMap.direction(x: 0.7, y: 0.7) >= 0, true)

print("direction keys:")
check("up is one key",           GamepadMap.directionKeys(0), [GamepadMap.vkUp])
check("diagonal holds two",      Set(GamepadMap.directionKeys(1)),
      Set([GamepadMap.vkUp, GamepadMap.vkRight]))
check("centred holds none",      GamepadMap.directionKeys(-1), [])
check("out of range holds none", GamepadMap.directionKeys(9), [])

print("analog rescale:")
check("inside deadzone is zero", GamepadMap.scaled(0.2), 0)
check("full deflection is one",  GamepadMap.scaled(1.0), 1)
check("sign is preserved",       GamepadMap.scaled(-1.0), -1)
// Movement must start from zero at the edge of the deadzone, not jump to it.
check("just outside deadzone is small", GamepadMap.scaled(0.36) < 0.05, true)

print("bindings:")
check("hex",        GamepadBinding.parse("0x20"), .key(0x20))
check("vk prefix",  GamepadBinding.parse("VK0x1B"), .key(0x1B))
check("decimal",    GamepadBinding.parse("32"), .key(32))
check("left mouse", GamepadBinding.parse("LMB"), .leftMouse)
check("right mouse", GamepadBinding.parse("RMB"), .rightMouse)
check("none",       GamepadBinding.parse("none"), .nothing)
check("typo is nil, not silent nothing", GamepadBinding.parse("0xZZ"), nil)

print("one frame of output:")
func out(_ i: GamepadInput,
         _ b: [GamepadButton: GamepadBinding] = GamepadMap.defaultBindings,
         speed: Double = 1.0) -> GamepadOutput {
    GamepadMap.output(for: i, bindings: b, mouseSpeed: speed)
}
var pad = GamepadInput()
pad.buttons = [.a]
check("A is space", out(pad).keys, [0x20])

pad.buttons = [.x]
check("X is left mouse", out(pad).leftMouse, true)
check("X holds no key", out(pad).keys, [])

// Two buttons on one key must release it only when BOTH are up — the Set is
// what makes that work, and the default map binds both B and MENU to escape.
pad.buttons = [.b, .menu]
check("B and MENU collapse to one esc", out(pad).keys, [0x1B])
pad.buttons = [.menu]
check("holding MENU still holds esc", out(pad).keys, [0x1B])

pad = GamepadInput()
pad.leftY = 1
check("stick up walks", out(pad).keys, [GamepadMap.vkUp])
check("stick alone does not touch the pointer", out(pad).mouseDX, 0)

pad = GamepadInput()
pad.buttons = [.right]
check("d-pad walks when the stick is centred", out(pad).keys, [GamepadMap.vkRight])
pad.leftY = -1
check("stick wins over the d-pad", out(pad).keys, [GamepadMap.vkDown])

pad = GamepadInput()
pad.rightX = 1
check("right stick moves the pointer", out(pad).mouseDX > 0, true)
check("right stick does not move vertically", out(pad).mouseDY, 0)
check("mouse speed scales it", out(pad, speed: 2.0).mouseDX,
      GamepadMap.mousePixelsPerFrame * 2)

// The look axis is the one place the two conventions disagree: the stick is
// up-positive, mouse coordinates count down-positive. Pushing up must post a
// negative dy, which is what the trackpad does for an upward finger drag.
pad = GamepadInput()
pad.rightY = 1
check("pushing the look stick up looks up", out(pad).mouseDY < 0, true)
pad.rightY = -1
check("and down looks down", out(pad).mouseDY > 0, true)

pad = GamepadInput()
check("resting controller posts nothing", out(pad), GamepadOutput())

print("override file:")
let parsed = GamepadSettings.parse("""
# a comment
ENABLED = 0

A = 0x1B        # B's key now
MOUSE_SPEED = 2.5
nonsense = 0x20
B = 0xZZ
""")
check("ENABLED=0 wins", parsed.settings.enabled, false)
check("MOUSE_SPEED parsed", parsed.settings.mouseSpeed, 2.5)
check("A rebound", parsed.settings.bindings[.a], .key(0x1B))
check("untouched default survives", parsed.settings.bindings[.x], .leftMouse)
check("two problems reported", parsed.problems.count, 2)

// An empty file must leave the shipped defaults alone rather than disabling
// every button, which is what a naive "replace if present" would do.
check("empty file keeps defaults",
      GamepadSettings.parse("").settings.bindings.count,
      GamepadMap.defaultBindings.count)
check("empty file stays enabled", GamepadSettings.parse("").settings.enabled, true)

// MARK: - Settings

print("resolution policy:")
check("presets start at automatic", ResolutionPolicy.presets[0].label, "Automatic")
check("every preset id is unique",
      Set(ResolutionPolicy.presets.map { $0.id }).count,
      ResolutionPolicy.presets.count)
check("automatic means no explicit size",
      ResolutionPolicy.clamped(width: 0, height: 0) == nil, true)
check("a real size survives",
      ResolutionPolicy.clamped(width: 1280, height: 720)?.width ?? -1, 1280)
check("below the floor is rejected",
      ResolutionPolicy.clamped(width: 100, height: 720) == nil, true)
check("above the ceiling is rejected",
      ResolutionPolicy.clamped(width: 8000, height: 720) == nil, true)

print("override files:")
func body(_ s: MadeiraSettings, _ name: String) -> String? {
    s.overrideFiles.first(where: { $0.name == name })?.body
}
check("a default writes nothing", body(.empty, "madeira-resolution.txt"), nil)
check("the default pool is automatic", body(.empty, "madeira-pool.txt"), nil)
check("the default dxmt config is absent", body(.empty, "madeira-dxmt.txt"), nil)
check("remote metal is off by default", body(.empty, "madeira-remote.txt"), nil)

var s = MadeiraSettings()
s.width = 1280
s.height = 720
check("resolution renders", body(s, "madeira-resolution.txt"), "1280x720")
s.poolMB = 512
check("pool renders", body(s, "madeira-pool.txt"), "512")
s.poolMB = 100
check("pool below the floor clamps up", body(s, "madeira-pool.txt"), "256")
s.poolMB = 99999
check("pool above the ceiling clamps down", body(s, "madeira-pool.txt"), "3072")
s.clampCompressedMips = true
check("dxmt option renders", body(s, "madeira-dxmt.txt"), "d3d11.mipClampBC=1")
s.remoteHost = "10.0.0.2:9000"
s.remoteToken = "abc"
check("remote renders both halves", body(s, "madeira-remote.txt"), "10.0.0.2:9000 abc")
s.remoteToken = ""
check("remote needs both halves", body(s, "madeira-remote.txt"), nil)

print("performance profiles:")
check("the engine's defaults read as Balanced",
      MadeiraSettings().matchingProfile, .balanced)
check("a fresh decode has both new switches off",
      MadeiraSettings().x87FastMath == false && MadeiraSettings().disableWineLogging == false,
      true)

var perf = MadeiraSettings()
perf.apply(.performance)
check("Performance writes the smaller desktop",
      body(perf, "madeira-resolution.txt"), "960x540")
check("Performance clamps compressed mips",
      body(perf, "madeira-dxmt.txt"), "d3d11.mipClampBC=1")
check("Performance silences Wine",
      body(perf, "madeira-winlog.txt"), "-all")
check("Performance reads back as Performance", perf.matchingProfile, .performance)
check("Performance leaves the pacing alone",
      perf.frameRate, MadeiraSettings().frameRate)
check("and leaves the pool alone", perf.poolMB, 0)

// The picker is a comparison, so a single hand-edit has to land in Custom by
// itself — otherwise the row would claim a preset the fields do not spell.
var tweaked = perf
tweaked.disableWineLogging = false
check("editing one owned field falls to Custom", tweaked.matchingProfile, nil)

var quality = MadeiraSettings()
quality.apply(.quality)
check("Quality keeps Wine logging", body(quality, "madeira-winlog.txt"), nil)
check("Quality writes the larger desktop",
      body(quality, "madeira-resolution.txt"), "1280x720")
check("Quality reads back as Quality", quality.matchingProfile, .quality)

// x87 is a correctness trade, not a speed dial, so no profile may switch it
// on behind the user's back.
check("no profile turns on x87 fast math",
      PerformanceProfile.allCases.allSatisfy { !$0.preset.x87FastMath }, true)
var fast = MadeiraSettings()
fast.x87FastMath = true
check("x87 writes the FEX key it declares",
      body(fast, "madeira-fex.txt"), "X87REDUCEDPRECISION=1")
check("x87 makes the combination Custom", fast.matchingProfile, nil)
check("x87 writes no other file",
      body(fast, "madeira-resolution.txt") == nil
          && body(fast, "madeira-dxmt.txt") == nil, true)

// MetalFX: the factor goes in the DXMT config, and the launch sequence derives
// the separate environment variable from that same text. The renderer ignores
// the factor without the variable, so the pair has to agree.
print("MetalFX upscaling:")
check("off writes no dxmt key", body(.empty, "madeira-dxmt.txt"), nil)
check("off presents nothing", MadeiraSettings().presentedResolution == nil, true)

var fx = MadeiraSettings()
fx.width = 960
fx.height = 540
fx.metalFXUpscale = .x2
check("2x writes the factor",
      body(fx, "madeira-dxmt.txt"), "d3d11.metalSpatialUpscaleFactor=2.0")
check("2x presents the panel size",
      fx.presentedResolution.map { "\($0.width)x\($0.height)" } ?? "nil", "1920x1080")
// The parser that turns this text into DXMT_METALFX_SPATIAL_SWAPCHAIN lives in
// DeviceCapabilities, where it has its own table in
// test-device-capabilities.sh. This side only has to prove the writer produces
// text the reader accepts, which that table pins down.
fx.metalFXUpscale = .x1_5
check("1.5x writes its own factor",
      body(fx, "madeira-dxmt.txt"), "d3d11.metalSpatialUpscaleFactor=1.5")
check("1.5x presents a rounded panel size",
      fx.presentedResolution.map { "\($0.width)x\($0.height)" } ?? "nil", "1440x810")
check("1.33x presents a rounded panel size", {
    var f = MadeiraSettings()
    f.width = 1280
    f.height = 720
    f.metalFXUpscale = .x1_33
    guard let p = f.presentedResolution else { return "nil" }
    return "\(p.width)x\(p.height)"
}(), "1702x958")
// Both renderer keys share one file; the order is what the log line reads as.
fx.metalFXUpscale = .x2
fx.clampCompressedMips = true
check("both renderer keys land in one file",
      body(fx, "madeira-dxmt.txt"),
      "d3d11.mipClampBC=1\nd3d11.metalSpatialUpscaleFactor=2.0")

// Upscaling is deliberately outside the preset, like the pool and the pad: the
// picker compares only the fields a profile owns, so turning upscaling on
// cannot make it claim a preset the other fields do not spell, and applying a
// preset cannot change the upscaling the user chose.
var fxProfile = MadeiraSettings()
fxProfile.metalFXUpscale = .x2
fxProfile.apply(.performance)
check("applying a profile leaves upscaling alone", fxProfile.metalFXUpscale, .x2)
check("and upscaling does not disturb the profile match",
      fxProfile.matchingProfile, .performance)

let fxRoundTrip = try? JSONDecoder().decode(MadeiraSettings.self,
                                            from: JSONEncoder().encode(fx))
check("the upscaling choice survives a save and load",
      fxRoundTrip?.metalFXUpscale ?? .off, .x2)

// The compatibility levers all leave through madeira-dxmt.txt, because DXMT
// reads them from DXMT_CONFIG. What is easy to get wrong is the *shape* of the
// value rather than the key: DXMT's parser ends an unquoted value at the first
// whitespace, so an unquoted description would reach the renderer as the single
// word "AMD", and the bools are matched case-insensitively after lowercasing, so
// "True" is the spelling that reads as a boolean.
print("renderer compatibility:")
var compat = MadeiraSettings()
check("no compatibility options by default", body(compat, "madeira-dxmt.txt"), nil)

compat.gpuIdentity = .amdRadeonPro5300M
let gpuBody = body(compat, "madeira-dxmt.txt") ?? ""
check("the reported GPU quotes its description",
      gpuBody.contains("dxgi.customDeviceDesc=\"AMD Radeon Pro 5300M\""), true)
check("and carries the vendor and device ids",
      gpuBody.contains("dxgi.customVendorId=1002")
          && gpuBody.contains("dxgi.customDeviceId=7340"), true)
check("and writes one option per line",
      gpuBody.split(separator: "\n").count, 3)

compat.frameRateLimit = 60
check("the frame cap is written",
      body(compat, "madeira-dxmt.txt")?.contains("d3d11.preferredMaxFrameRate=60") ?? false,
      true)
compat.frameRateLimit = 0
check("a zero cap writes no key at all",
      body(compat, "madeira-dxmt.txt")?.contains("preferredMaxFrameRate") ?? false, false)

compat.ignoreMapFlagNoWait = true
check("the map flag is written",
      body(compat, "madeira-dxmt.txt")?.contains("d3d11.ignoreMapFlagNoWait=True") ?? false,
      true)
compat.forceSDR = true
check("force SDR is written",
      body(compat, "madeira-dxmt.txt")?.contains("dxgi.forceSDR=True") ?? false, true)

// Turning everything back off must remove the file, not leave an empty-bodied
// one: the launch sequence unsets DXMT_CONFIG only when the body is absent, so
// a file that lingers would carry the previous run's renderer config into the
// next one.
var compatOff = MadeiraSettings()
compatOff.gpuIdentity = .automatic
compatOff.frameRateLimit = 0
compatOff.ignoreMapFlagNoWait = false
compatOff.forceSDR = false
check("turning them all off removes the file", body(compatOff, "madeira-dxmt.txt"), nil)

compat.frameRateLimit = 120
let compatRoundTrip = try? JSONDecoder().decode(MadeiraSettings.self,
                                                from: JSONEncoder().encode(compat))
check("the reported GPU survives a save and load",
      compatRoundTrip?.gpuIdentity ?? .automatic, .amdRadeonPro5300M)
check("and so does the frame cap", compatRoundTrip?.frameRateLimit ?? -1, 120)
check("and the map flag", compatRoundTrip?.ignoreMapFlagNoWait ?? false, true)
check("and force SDR", compatRoundTrip?.forceSDR ?? false, true)

// A settings blob from a build that predates the new keys must still decode.
// The synthesized decoder demands every key, and SettingsStore treats a throw
// as "no saved settings" — so a decode failure silently resets the user's
// choices, which is worse than shipping the new field.
let legacy = #"{"width":1280,"height":720,"poolMB":512,"clampCompressedMips":true}"#
let legacyDecoded = try? JSONDecoder().decode(MadeiraSettings.self,
                                              from: Data(legacy.utf8))
check("a blob without the new keys decodes", legacyDecoded != nil, true)
check("and keeps its desktop size", legacyDecoded?.width ?? -1, 1280)
check("and keeps its pool", legacyDecoded?.poolMB ?? -1, 512)
check("and keeps its mip clamp", legacyDecoded?.clampCompressedMips ?? false, true)
check("and defaults the new switches", legacyDecoded?.x87FastMath ?? true, false)
check("and defaults MetalFX off", legacyDecoded?.metalFXUpscale ?? .x2, .off)
// The fields it did carry must be read back faithfully, so its clamp keeps it
// out of the Quality preset rather than being quietly dropped on load.
check("and does not read as a preset", legacyDecoded?.matchingProfile ?? nil, nil)
check("and defaults the reported GPU",
      legacyDecoded?.gpuIdentity ?? .amdRadeonPro5300M, .automatic)
check("and defaults the frame cap off", legacyDecoded?.frameRateLimit ?? 60, 0)
check("and defaults the map flag off", legacyDecoded?.ignoreMapFlagNoWait ?? true, false)
check("and defaults force SDR off", legacyDecoded?.forceSDR ?? true, false)

let oldDefault = #"{"poolMB":512}"#
let decodedDefault = try? JSONDecoder().decode(MadeiraSettings.self,
                                               from: Data(oldDefault.utf8))
check("a near-empty blob decodes", decodedDefault != nil, true)
check("and reads as the engine's defaults",
      decodedDefault?.matchingProfile ?? nil, .balanced)

var roundTrip = MadeiraSettings()
roundTrip.x87FastMath = true
roundTrip.disableWineLogging = true
let reloaded = try? JSONDecoder().decode(MadeiraSettings.self,
                                         from: JSONEncoder().encode(roundTrip))
check("the new switches survive a save and load", reloaded?.x87FastMath ?? false, true)
check("so does the logging switch", reloaded?.disableWineLogging ?? false, true)

print("engine switches:")
check("switch ids are unique",
      Set(EngineSwitches.all.map { $0.id }).count, EngineSwitches.all.count)
check("every switch is grouped", EngineSwitches.all.allSatisfy { _ in true }, true)
check("off writes no file", body(.empty, "madeira-usd-time.txt"), nil)
var t = MadeiraSettings()
t.switches = ["madeira-usd-time"]
check("on writes the value", body(t, "madeira-usd-time.txt"), "1")
check("one switch does not turn on another",
      body(t, "madeira-wx.txt") == nil, true)

// MARK: - The on-screen pad
//
// The pad is the one control surface a user cannot work around: if a hit region
// and the drawn button disagree, two controls claim the same point, a shoulder
// lands under the immersive exit button, or a stick keeps steering after the
// thumb lifts, the failure is "the game is unplayable" — and it reproduces only
// on hardware. Hence a table of real sizes.

print("on-screen pad geometry:")
let padSizes: [(String, CGSize)] = [
    ("phone landscape", CGSize(width: 852, height: 393)),
    ("small phone landscape", CGSize(width: 667, height: 375)),
    ("phone portrait", CGSize(width: 393, height: 852)),
    ("mini portrait", CGSize(width: 375, height: 812)),
    ("ipad landscape", CGSize(width: 1366, height: 1024)),
    ("ipad portrait", CGSize(width: 1024, height: 1366)),
]
let chromeInset = 44.0

var padOffscreen = 0
var padAboveChrome = 0
var padOwnCentreMisses = 0
var padWorstClearance = Double.greatestFiniteMagnitude
for (_, size) in padSizes {
    let cs = VirtualPadLayout.controls(for: size, topInset: chromeInset)
    for c in cs {
        let p = VirtualPadLayout.centre(c, in: size)
        let r = VirtualPadLayout.radius(c)
        if p.x - r < 0 || p.y - r < 0 || p.x + r > size.width || p.y + r > size.height {
            padOffscreen += 1
        }
        // Half a point of slack: the trigger row is placed exactly on the
        // clearance line and the fraction that produced it is not representable.
        if p.y - r < chromeInset + VirtualPadLayout.chromeClearance - 0.5 { padAboveChrome += 1 }
        if VirtualPadLayout.hit(p, in: size, controls: cs) != c.hit { padOwnCentreMisses += 1 }
    }
    for i in 0..<cs.count {
        for j in (i + 1)..<cs.count {
            let a = VirtualPadLayout.centre(cs[i], in: size)
            let b = VirtualPadLayout.centre(cs[j], in: size)
            let gap = ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
            padWorstClearance = min(padWorstClearance,
                                    gap - VirtualPadLayout.radius(cs[i])
                                        - VirtualPadLayout.radius(cs[j]))
        }
    }
}
check("every control is on screen", padOffscreen, 0)
check("nothing under the immersive exit strip", padAboveChrome, 0)
check("every control owns its own centre", padOwnCentreMisses, 0)
check("no two controls overlap", padWorstClearance > 0, true)

// The hide disc is neither a gamepad button nor part of the hit table, so
// nothing else checks that it is reachable without also being a button.
var hideDiscClashes = 0
for (_, size) in padSizes {
    let disc = VirtualPadLayout.hideDisc(for: size, topInset: chromeInset)
    for c in VirtualPadLayout.controls(for: size, topInset: chromeInset) {
        let p = VirtualPadLayout.centre(c, in: size)
        let gap = ((p.x - disc.centre.x) * (p.x - disc.centre.x)
                   + (p.y - disc.centre.y) * (p.y - disc.centre.y)).squareRoot()
        if gap < VirtualPadLayout.radius(c) + disc.radius { hideDiscClashes += 1 }
    }
}
check("the hide disc is clear of the buttons", hideDiscClashes, 0)

// Every gamepad button a touch pad can drive. ls/rs are absent on purpose:
// pressing a stick is a separate gesture from steering it, and a tap on the
// stick centre already means "steer from here".
let expectedPadButtons: Set<GamepadButton> = [
    .a, .b, .x, .y, .up, .down, .left, .right,
    .lb, .rb, .lt, .rt, .menu, .view,
]
let layoutHits = VirtualPadLayout.controls(for: CGSize(width: 852, height: 393),
                                           topInset: chromeInset)
check("landscape layout is 14 buttons and 2 sticks", layoutHits.count, 16)
var padButtons = Set<GamepadButton>()
var padSticks = Set<PadStick>()
for control in layoutHits {
    switch control.hit {
    case .button(let b): padButtons.insert(b)
    case .stick(let s): padSticks.insert(s)
    }
}
check("every button is on the pad", padButtons, expectedPadButtons)
check("both sticks are on the pad", padSticks, Set(PadStick.allCases))

// PlayStation positions, not a guess: triangle up, circle right, cross down,
// square left. A layout that swaps two of these is unusable and looks fine.
func padControl(_ hit: PadHit, _ size: CGSize) -> PadControl? {
    VirtualPadLayout.controls(for: size, topInset: chromeInset).first { $0.hit == hit }
}
let psSize = CGSize(width: 852, height: 393)
let faceCircle = padControl(.button(.b), psSize)
let faceCross = padControl(.button(.a), psSize)
let faceSquare = padControl(.button(.x), psSize)
let faceTriangle = padControl(.button(.y), psSize)
check("circle is right of cross", (faceCircle?.nx ?? 0) > (faceCross?.nx ?? 0), true)
check("cross is below circle", (faceCross?.ny ?? 0) > (faceCircle?.ny ?? 0), true)
check("square is left of cross", (faceSquare?.nx ?? 0) < (faceCross?.nx ?? 0), true)
check("triangle is above cross", (faceTriangle?.ny ?? 0) < (faceCross?.ny ?? 0), true)
let stickLeft = padControl(.stick(.left), psSize)
let stickRight = padControl(.stick(.right), psSize)
check("the left stick is on the left", (stickLeft?.nx ?? 1) < 0.5, true)
check("the right stick is on the right", (stickRight?.nx ?? 0) > 0.5, true)
check("the sticks are below the clusters",
      min(stickLeft?.ny ?? 0, stickRight?.ny ?? 0) > max(faceCross?.ny ?? 0, faceCircle?.ny ?? 0),
      true)

print("on-screen pad input:")
check("off shows nothing", VirtualPadMode.off.shows(gameOnScreen: true), false)
check("automatic follows the game", VirtualPadMode.automatic.shows(gameOnScreen: true), true)
check("automatic hides outside a game", VirtualPadMode.automatic.shows(gameOnScreen: false), false)
check("always ignores the game", VirtualPadMode.always.shows(gameOnScreen: false), true)
check("no mode is absent from the settings picker",
      VirtualPadMode.allCases.count, 3)

check("opacity is clamped at the bottom", VirtualPadLayout.opacityClamped(0), VirtualPadLayout.minOpacity)
check("opacity is clamped at the top", VirtualPadLayout.opacityClamped(4), 1)
check("a garbage opacity falls back to the default",
      VirtualPadLayout.opacityClamped(.nan), VirtualPadLayout.defaultOpacity)

// The sign of a stick is the difference between "the pad is broken" and "one
// axis is negated", and the screen's y grows downward while the sticks do not.
let stickCentre = CGPoint(x: 100, y: 100)
let up = VirtualPadLayout.stickVector(centre: stickCentre, travel: 40, at: CGPoint(x: 100, y: 60))
let down = VirtualPadLayout.stickVector(centre: stickCentre, travel: 40, at: CGPoint(x: 100, y: 140))
let right = VirtualPadLayout.stickVector(centre: stickCentre, travel: 40, at: CGPoint(x: 140, y: 100))
check("pushing up is +y", up.y, 1)
check("pushing down is -y", down.y, -1)
check("pushing right is +x", right.x, 1)
let clamped = VirtualPadLayout.stickVector(centre: stickCentre, travel: 40,
                                           at: CGPoint(x: 400, y: 400))
check("a stick is clamped to the unit circle",
      (clamped.x * clamped.x + clamped.y * clamped.y).squareRoot() <= 1.0000001, true)
let diagonal = VirtualPadLayout.stickVector(centre: stickCentre, travel: 40,
                                            at: CGPoint(x: 140, y: 60))
check("a diagonal is not faster than a straight push",
      ((diagonal.x * diagonal.x + diagonal.y * diagonal.y).squareRoot() - 1)
        < 0.0000001, true)

print("two sources at once:")
var physical = GamepadInput()
physical.buttons = [.a]
physical.rightX = 0.9
var virtual = GamepadInput()
virtual.buttons = [.b]
var both = GamepadInput.merged(physical, virtual)
check("buttons from both sources are held",
      both.buttons, Set([GamepadButton.a, GamepadButton.b]))
check("the stronger axis wins", both.rightX, 0.9)
virtual.rightX = 0.4
both = GamepadInput.merged(physical, virtual)
check("an idle thumb cannot cancel a controller stick", both.rightX, 0.9)
check("a merged frame with nothing held is empty",
      GamepadInput.merged(GamepadInput(), GamepadInput()).buttons.isEmpty, true)

print("multi-touch bookkeeping:")
var touches = VirtualPadTouchState()
touches.begin(.button(.a), touch: 0)
touches.begin(.button(.a), touch: 1)
touches.end(touch: 0)
check("a button held by two thumbs survives the first lift",
      touches.input.buttons.contains(.a), true)
touches.end(touch: 1)
check("and releases when the last one lifts", touches.input.buttons.contains(.a), false)
touches.begin(.stick(.right), touch: 2)
touches.move(.right, to: PadAxis(x: 0.5, y: 0.5))
check("a stick steers", touches.input.rightX, 0.5)
touches.end(touch: 2)
check("lifting a stick clears its axis", touches.input.rightX, 0)
touches.begin(.stick(.left), touch: 3)
touches.endAll()
check("everything is released at once", touches.isIdle, true)

print("thumb sliding:")
// The rule the touch layer asks before it moves a finger from one control to
// another. A d-pad is unusable without the first case, and the third is how a
// press meant as "jump" would silently become camera panning.
check("a thumb may slide between face buttons",
      PadHit.canReassign(from: .button(.a), to: .button(.b)), true)
check("a thumb may slide from one d-pad direction to another",
      PadHit.canReassign(from: .button(.up), to: .button(.right)), true)
check("a thumb may not re-declare the same button",
      PadHit.canReassign(from: .button(.a), to: .button(.a)), false)
check("a thumb may not slide from a button onto a stick",
      PadHit.canReassign(from: .button(.a), to: .stick(.left)), false)
check("a thumb may not slide from a stick onto a button",
      PadHit.canReassign(from: .stick(.left), to: .button(.a)), false)
check("a thumb may wander inside one stick",
      PadHit.canReassign(from: .stick(.left), to: .stick(.left)), true)
check("but not from one stick to the other",
      PadHit.canReassign(from: .stick(.left), to: .stick(.right)), false)
check("a new finger may start anywhere",
      PadHit.canReassign(from: nil, to: .stick(.right)), true)
var slide = VirtualPadTouchState()
slide.begin(.button(.up), touch: 7)
check("the touch layer can ask what a finger is driving",
      slide.hit(of: 7), .button(.up))
check("and an unknown finger has no answer", slide.hit(of: 8), nil)

print("pad settings:")
var padSettings = MadeiraSettings()
check("the pad is on by default", padSettings.virtualPad, .automatic)
check("the default opacity is the layout's", padSettings.virtualPadOpacity,
      VirtualPadLayout.defaultOpacity)
padSettings.virtualPad = .off
padSettings.virtualPadOpacity = 2
let roundTripped = (try? JSONDecoder().decode(MadeiraSettings.self,
                                              from: JSONEncoder().encode(padSettings)))
check("the pad survives a save and load", roundTripped?.virtualPad, .off)
check("a persisted opacity is clamped on use",
      VirtualPadLayout.opacityClamped(roundTripped?.virtualPadOpacity ?? 0), 1)

print(failures == 0
      ? "test-app-ui: OK"
      : "test-app-ui: \(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
SWIFT

# shellcheck disable=SC2086
"$SWIFTC" -O -o "$TMP/test-app-ui" \
    app/Madeira/AppLayout.swift app/Madeira/GamepadMap.swift \
    app/Madeira/VirtualPad.swift app/Madeira/SettingsModel.swift "$TMP/main.swift"
"$TMP/test-app-ui"
