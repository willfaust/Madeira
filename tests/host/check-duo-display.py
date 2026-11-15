#!/usr/bin/env python3
"""Screen-shaped resolutions on the iPhone Duo's two screens, and no change
on today's iPhones and iPads.

Compiles the production GuestDisplay.swift (GameSurfaceLayout, GuestDisplay,
ResolutionChoices) and DisplayGeometry.swift without UIKit and checks:

- golden: what `groups`, `defaultSize`, `screen720` and `metalFX` return for
  current iPhones and iPads, recorded before the Duo work, so no later change
  can move them;
- Duo: each screen (inner and outer, measured on an iPhone Duo, iPhone19,4,
  iOS 27.2.1), plus a taller 19.5:9 outer screen like other foldables', gets
  choices of its own shape;
- the screen model follows the screen (ResolutionChoices.update): a fold
  changes the default and the picker, a rotation does not;
- the [display-geometry] log line.

`--record` prints the golden table from the current source instead of
checking it (use it only when a change to existing devices is intended).
"""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / "app/Madeira"
display = (app / "GuestDisplay.swift").read_text()
geometry = (app / "DisplayGeometry.swift").read_text()
content = (app / "ContentView.swift").read_text(encoding="utf-8")

# P4: the game layer and the touch controls re-frame on a scene geometry change
# (a fold that keeps the orientation), not only on an orientation change.
assert 'forName: DisplayGeometry.changed, object: nil, queue: .main) { _ in\n            MetalBackedView.refreshDisplayMode(reason: "scene-geometry")' in content, \
    "MetalBackedView re-applies the layout on DisplayGeometry.changed"
assert content.count('.merge(with: NotificationCenter.default.publisher(for: DisplayGeometry.changed))) { _ in\n'
                     '                    TouchControlsHost.attach()') == 2, "both game views re-frame the touch controls on DisplayGeometry.changed"
assert 'NotificationCenter.default.post(name: DisplayGeometry.changed, object: scene)' in geometry
assert 'ResolutionChoices.update(.landscape(points: now.screen, pixels: now.native))' in geometry
print("PASS: fold re-frame hooks: game layer and touch controls follow scene geometry")

# (name, landscape points, native pixels)
GOLDEN_SCREENS = [
    ("iphone-6.1", (852, 393), (2556, 1179)),
    ("iphone-6.3", (874, 402), (2622, 1206)),
    ("iphone-6.9", (956, 440), (2868, 1320)),
    ("ipad-mini", (1133, 744), (2266, 1488)),
    ("ipad-11", (1180, 820), (2360, 1640)),
    ("ipad-pro-11", (1210, 834), (2420, 1668)),
    ("ipad-13", (1366, 1024), (2732, 2048)),
    ("ipad-pro-13", (1376, 1032), (2752, 2064)),
]
# Measured on an iPhone Duo (iPhone19,4, iOS 27.2.1): the inner screen is
# 951x669 pt on a 2670x1878 px panel (native scale 2.807), the outer 678x466 pt
# at @3x. The third is not a Duo screen: a taller outer screen, as on other foldables.
DUO_SCREENS = [
    ("duo-inner", (951, 669), (2670, 1878)),
    ("duo-outer", (678, 466), (2034, 1398)),
    ("foldable-outer-19.5:9", (812, 375), (2340, 1080)),
]

# Recorded from fbad4304 (before any Duo change) with --record.
GOLDEN = json.loads(r'''
{
 "ipad-11": {
  "default": "1152x800",
  "groups": [
   {
    "choices": [
     "944x656 944×656 · light",
     "1152x800 1152×800 · default",
     "1728x1200 1728×1200 · ≈1080p",
     "2360x1640 2360×1640 · native"
    ],
    "title": "This screen's shape"
   },
   {
    "choices": [
     "960x540 960×540",
     "1280x720 1280×720",
     "1600x900 1600×900",
     "1920x1080 1920×1080",
     "2560x1440 2560×1440"
    ],
    "title": "16:9 widescreen · bars above and below"
   },
   {
    "choices": [
     "640x480 640×480",
     "800x600 800×600",
     "1024x768 1024×768",
     "1280x960 1280×960"
    ],
    "title": "4:3 classic · bars at the sides"
   }
  ],
  "metalFX": "688x480",
  "screen720": ""
 },
 "ipad-13": {
  "default": "1112x832",
  "groups": [
   {
    "choices": [
     "904x680 904×680 · light",
     "1112x832 1112×832 · default",
     "1664x1248 1664×1248 · ≈1080p",
     "2732x2048 2732×2048 · native"
    ],
    "title": "This screen's shape"
   },
   {
    "choices": [
     "960x540 960×540",
     "1280x720 1280×720",
     "1600x900 1600×900",
     "1920x1080 1920×1080",
     "2560x1440 2560×1440"
    ],
    "title": "16:9 widescreen · bars above and below"
   },
   {
    "choices": [
     "640x480 640×480",
     "800x600 800×600",
     "1024x768 1024×768",
     "1280x960 1280×960"
    ],
    "title": "4:3 classic · fills this screen"
   }
  ],
  "metalFX": "",
  "screen720": ""
 },
 "ipad-mini": {
  "default": "1184x776",
  "groups": [
   {
    "choices": [
     "976x640 976×640 · light",
     "1184x776 1184×776 · default",
     "1776x1168 1776×1168 · ≈1080p",
     "2266x1488 2266×1488 · native"
    ],
    "title": "This screen's shape"
   },
   {
    "choices": [
     "960x540 960×540",
     "1280x720 1280×720",
     "1600x900 1600×900",
     "1920x1080 1920×1080",
     "2560x1440 2560×1440"
    ],
    "title": "16:9 widescreen · bars above and below"
   },
   {
    "choices": [
     "640x480 640×480",
     "800x600 800×600",
     "1024x768 1024×768",
     "1280x960 1280×960"
    ],
    "title": "4:3 classic · bars at the sides"
   }
  ],
  "metalFX": "728x480",
  "screen720": ""
 },
 "ipad-pro-11": {
  "default": "1160x800",
  "groups": [
   {
    "choices": [
     "952x656 952×656 · light",
     "1160x800 1160×800 · default",
     "1728x1192 1728×1192 · ≈1080p",
     "2420x1668 2420×1668 · native"
    ],
    "title": "This screen's shape"
   },
   {
    "choices": [
     "960x540 960×540",
     "1280x720 1280×720",
     "1600x900 1600×900",
     "1920x1080 1920×1080",
     "2560x1440 2560×1440"
    ],
    "title": "16:9 widescreen · bars above and below"
   },
   {
    "choices": [
     "640x480 640×480",
     "800x600 800×600",
     "1024x768 1024×768",
     "1280x960 1280×960"
    ],
    "title": "4:3 classic · bars at the sides"
   }
  ],
  "metalFX": "696x480",
  "screen720": ""
 },
 "ipad-pro-13": {
  "default": "1112x832",
  "groups": [
   {
    "choices": [
     "904x680 904×680 · light",
     "1112x832 1112×832 · default",
     "1664x1248 1664×1248 · ≈1080p",
     "2752x2064 2752×2064 · native"
    ],
    "title": "This screen's shape"
   },
   {
    "choices": [
     "960x540 960×540",
     "1280x720 1280×720",
     "1600x900 1600×900",
     "1920x1080 1920×1080",
     "2560x1440 2560×1440"
    ],
    "title": "16:9 widescreen · bars above and below"
   },
   {
    "choices": [
     "640x480 640×480",
     "800x600 800×600",
     "1024x768 1024×768",
     "1280x960 1280×960"
    ],
    "title": "4:3 classic · fills this screen"
   }
  ],
  "metalFX": "",
  "screen720": ""
 },
 "iphone-6.1": {
  "default": "1424x656",
  "groups": [
   {
    "choices": [
     "1160x536 1160×536 · light",
     "1424x656 1424×656 · default",
     "1560x720 1560×720 · 720 lines",
     "2112x976 2112×976 · ≈1080p",
     "2556x1179 2556×1179 · native"
    ],
    "title": "This screen's shape"
   },
   {
    "choices": [
     "960x540 960×540",
     "1280x720 1280×720",
     "1600x900 1600×900",
     "1920x1080 1920×1080",
     "2560x1440 2560×1440"
    ],
    "title": "16:9 widescreen · bars at the sides"
   },
   {
    "choices": [
     "640x480 640×480",
     "800x600 800×600",
     "1024x768 1024×768",
     "1280x960 1280×960"
    ],
    "title": "4:3 classic · bars at the sides"
   }
  ],
  "metalFX": "1040x480",
  "screen720": "1560x720"
 },
 "iphone-6.3": {
  "default": "1408x648",
  "groups": [
   {
    "choices": [
     "1168x536 1168×536 · light",
     "1408x648 1408×648 · default",
     "1568x720 1568×720 · 720 lines",
     "2120x976 2120×976 · ≈1080p",
     "2622x1206 2622×1206 · native"
    ],
    "title": "This screen's shape"
   },
   {
    "choices": [
     "960x540 960×540",
     "1280x720 1280×720",
     "1600x900 1600×900",
     "1920x1080 1920×1080",
     "2560x1440 2560×1440"
    ],
    "title": "16:9 widescreen · bars at the sides"
   },
   {
    "choices": [
     "640x480 640×480",
     "800x600 800×600",
     "1024x768 1024×768",
     "1280x960 1280×960"
    ],
    "title": "4:3 classic · bars at the sides"
   }
  ],
  "metalFX": "1040x480",
  "screen720": "1568x720"
 },
 "iphone-6.9": {
  "default": "1408x648",
  "groups": [
   {
    "choices": [
     "1168x536 1168×536 · light",
     "1408x648 1408×648 · default",
     "1568x720 1568×720 · 720 lines",
     "2120x976 2120×976 · ≈1080p",
     "2868x1320 2868×1320 · native"
    ],
    "title": "This screen's shape"
   },
   {
    "choices": [
     "960x540 960×540",
     "1280x720 1280×720",
     "1600x900 1600×900",
     "1920x1080 1920×1080",
     "2560x1440 2560×1440"
    ],
    "title": "16:9 widescreen · bars at the sides"
   },
   {
    "choices": [
     "640x480 640×480",
     "800x600 800×600",
     "1024x768 1024×768",
     "1280x960 1280×960"
    ],
    "title": "4:3 classic · bars at the sides"
   }
  ],
  "metalFX": "1040x480",
  "screen720": "1568x720"
 }
}
''')


def swift_screens(screens):
    return ",\n".join(
        f'    ("{n}", ResolutionChoices.Screen(points: CGSize(width: {p[0]}, height: {p[1]}), '
        f'pixels: CGSize(width: {px[0]}, height: {px[1]})))'
        for n, p, px in screens)


harness = r'''
func winios_display_mode_changed(_ w: Int32, _ h: Int32) {}

let golden: [(String, ResolutionChoices.Screen)] = [
GOLDEN_SCREENS
]
let duo: [(String, ResolutionChoices.Screen)] = [
DUO_SCREENS
]

var failed = false
func expect(_ ok: Bool, _ what: String) {
    if ok { print("PASS: \(what)") } else { failed = true; FileHandle.standardError.write("FAIL: \(what)\n".data(using: .utf8)!) }
}

func table(_ s: ResolutionChoices.Screen) -> [String: Any] {
    let g = ResolutionChoices.groups(for: s)
    let d = ResolutionChoices.defaultSize(for: s)
    return [
        "default": "\(d.w)x\(d.h)",
        "screen720": ResolutionChoices.screen720(for: s).map { "\($0.w)x\($0.h)" } ?? "",
        "metalFX": ResolutionChoices.metalFX(for: s, in: g)?.value ?? "",
        "groups": g.map { ["title": $0.title, "choices": $0.choices.map { "\($0.value) \($0.label)" }] as [String: Any] },
    ]
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "record" {
    var out: [String: Any] = [:]
    for (name, s) in golden { out[name] = table(s) }
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

// Golden values for today's devices, passed in as JSON on stdin.
let goldenJSON = try! JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
for (name, s) in golden {
    let now = try! JSONSerialization.data(withJSONObject: table(s), options: [.sortedKeys])
    let was = try! JSONSerialization.data(withJSONObject: goldenJSON[name]!, options: [.sortedKeys])
    expect(now == was, "golden \(name): groups, default, screen720 and metalFX unchanged")
}

// The Duo's screens: choices of the screen's own shape.
for (name, s) in duo {
    let g = ResolutionChoices.groups(for: s)
    let d = ResolutionChoices.defaultSize(for: s)
    expect(g.first?.title == "This screen's shape", "\(name): the first group is the screen's shape")
    let own = g.first?.choices ?? []
    expect(own.count >= 2 && own.allSatisfy { $0.label.hasSuffix("native") || ResolutionChoices.fills($0.w, $0.h, screen: s) },
           "\(name): every screen-shaped choice fills the screen (\(own.map(\.value)))")
    expect(ResolutionChoices.fills(d.w, d.h, screen: s), "\(name): the default \(d.w)x\(d.h) fills the screen")
    expect(d.w % 8 == 0 && d.h % 8 == 0, "\(name): the default is a multiple of 8")
    let px = d.w * d.h, budget = 1280 * 720
    expect(abs(Double(px - budget)) / Double(budget) < 0.05, "\(name): the default costs about 1280x720's pixels (\(px))")
    if let l = ResolutionChoices.screen720(for: s) {
        expect(ResolutionChoices.fills(l.w, l.h, screen: s) || abs(Double(l.w) / 720 / ResolutionChoices.aspect(s) - 1) < 0.02,
               "\(name): the 720-line choice \(l.w)x\(l.h) has the screen's shape")
    }
    let rect = GameSurfaceLayout.rect(guest: CGSize(width: d.w, height: d.h), aspect: .zero, bounds: CGRect(origin: .zero, size: s.points), mode: .fit)
    expect(abs(rect.width - s.points.width) < 0.02 * s.points.width && abs(rect.height - s.points.height) < 0.02 * s.points.height,
           "\(name): Fit fills the screen at the default (bars under 2%)")
}
// The outer and inner screens differ in shape, so a default chosen on one does not fill the other.
let inner = ResolutionChoices.defaultSize(for: duo[0].1), tall = ResolutionChoices.defaultSize(for: duo[2].1)
expect(!ResolutionChoices.fills(inner.w, inner.h, screen: duo[2].1) && !ResolutionChoices.fills(tall.w, tall.h, screen: duo[0].1),
       "foldable: the inner default does not fill a 19.5:9 outer screen, and the other way round")

// P2: the screen model follows the screen. The first read is the host's
// fallback; update(_:) switches it, posts screenChanged once per change and
// ignores a rotation of the same screen.
var posts = 0
let token = NotificationCenter.default.addObserver(forName: ResolutionChoices.screenChanged, object: nil, queue: nil) { _ in posts += 1 }
let first = ResolutionChoices.screen
expect(!ResolutionChoices.update(first) && posts == 0, "update: the same screen is no change and posts nothing")
let portrait = ResolutionChoices.Screen(points: CGSize(width: first.points.height, height: first.points.width),
                                        pixels: CGSize(width: first.pixels.height, height: first.pixels.width))
expect(!ResolutionChoices.update(portrait) && posts == 0, "update: a rotation of the same screen is no change")
expect(!ResolutionChoices.update(.init(points: .zero, pixels: .zero)) && ResolutionChoices.screen == first, "update: an empty reading is ignored")
let duoInner = duo[0].1, duoOuter = duo[1].1
func values(_ g: [ResolutionChoices.Group]) -> [[String]] { g.map { $0.choices.map(\.value) } }
expect(ResolutionChoices.update(duoInner) && posts == 1, "update: unfolding to the inner screen changes it and posts once")
expect(ResolutionChoices.defaultValue == "1152x808" && values(ResolutionChoices.groups()) == values(ResolutionChoices.groups(for: duoInner)),
       "update: the default and the picker's groups follow the inner screen (\(ResolutionChoices.defaultValue))")
expect(ResolutionChoices.screen720Value == nil, "update: no 720-line choice on the inner screen")
expect(ResolutionChoices.update(duoOuter) && posts == 2 && ResolutionChoices.defaultValue == "1152x792" && ResolutionChoices.screen720Value == nil,
       "update: folding to the outer screen follows it (\(ResolutionChoices.defaultValue), \(ResolutionChoices.screen720Value ?? "-"))")
expect(ResolutionChoices.update(duoInner) && posts == 3 && ResolutionChoices.defaultValue == "1152x808", "update: and back")
for (name, s) in golden {
    ResolutionChoices.update(s)
    let now = try! JSONSerialization.data(withJSONObject: table(ResolutionChoices.screen), options: [.sortedKeys])
    let was = try! JSONSerialization.data(withJSONObject: goldenJSON[name]!, options: [.sortedKeys])
    expect(now == was, "update: \(name) as the current screen gives its golden values")
}
NotificationCenter.default.removeObserver(token)

// P3: the shapes a device has shown, and the token that follows the screen.
let suite = "duo-display-check-\(UUID().uuidString)"
ResolutionChoices.store = UserDefaults(suiteName: suite)!
for (name, s) in golden {
    ResolutionChoices.store.removeObject(forKey: ResolutionChoices.seenKey)
    let rotated = ResolutionChoices.Screen(points: CGSize(width: s.points.height, height: s.points.width), pixels: CGSize(width: s.pixels.height, height: s.pixels.width))
    ResolutionChoices.noteShape(s); ResolutionChoices.noteShape(rotated); ResolutionChoices.noteShape(s)
    ResolutionChoices.update(s)
    expect(!ResolutionChoices.severalScreens && ResolutionChoices.newEntryValue == ResolutionChoices.defaultValue,
           "\(name): one shape however often it is seen; a new entry stores the concrete default (\(ResolutionChoices.newEntryValue))")
    expect(ResolutionChoices.resolve("1280x720", for: s) == "1280x720" && ResolutionChoices.resolve(ResolutionChoices.screenToken, for: s) == "\(ResolutionChoices.defaultSize(for: s).w)x\(ResolutionChoices.defaultSize(for: s).h)",
           "\(name): resolve keeps a size and turns the token into this screen's default")
}
// Display Zoom on a 6.3-inch iPhone (402 pt wide becomes 375): the same shape.
ResolutionChoices.store.removeObject(forKey: ResolutionChoices.seenKey)
ResolutionChoices.noteShape(golden[1].1)
ResolutionChoices.noteShape(.init(points: CGSize(width: 812, height: 375), pixels: CGSize(width: 2622, height: 1206)))
expect(!ResolutionChoices.severalScreens, "Display Zoom on an iPhone is not a second screen shape")
// The Duo: outer then inner.
ResolutionChoices.store.removeObject(forKey: ResolutionChoices.seenKey)
ResolutionChoices.noteShape(duoOuter)
expect(!ResolutionChoices.severalScreens, "duo: folded, one shape seen")
ResolutionChoices.noteShape(duoInner); ResolutionChoices.noteShape(duoInner)
expect(ResolutionChoices.severalScreens && ResolutionChoices.seenScreens.count == 2 && ResolutionChoices.newEntryValue == ResolutionChoices.screenToken,
       "duo: unfolded, two shapes (seeing one again adds none), new entries take the token")
let tokens = ResolutionChoices.followTokens(for: ResolutionChoices.seenScreens)
expect(tokens == ["1152x792": ResolutionChoices.screenToken, "1152x808": ResolutionChoices.screenToken],
       "duo: the one-time conversion maps both defaults; neither screen has a 720-line size (\(tokens))")
expect(ResolutionChoices.resolve(ResolutionChoices.screen720Token, for: duoOuter) == "1152x792" && ResolutionChoices.resolve(ResolutionChoices.screen720Token, for: duoInner) == "1152x808",
       "duo: a 720-line token from another device resolves to each screen's default")
// A taller 19.5:9 outer screen (other foldables): also two shapes, each resolved to its own default.
ResolutionChoices.store.removeObject(forKey: ResolutionChoices.seenKey)
ResolutionChoices.noteShape(duo[2].1); ResolutionChoices.noteShape(duoInner)
expect(ResolutionChoices.severalScreens && ResolutionChoices.resolve(ResolutionChoices.screenToken, for: duo[2].1) == "1424x656",
       "foldable: a 19.5:9 outer screen counts as a second shape; the token gives it its own 1424x656")
UserDefaults.standard.removePersistentDomain(forName: suite)

// P4: folding and unfolding mid-game. The guest mode stays; the layer is laid
// out again for each new bounds and touch maps through the same rect, so the
// corners of the picture always hit the guest's corners.
let guest = CGSize(width: 1336, height: 936)
let steps: [(String, CGSize)] = [("inner", duoInner.points), ("outer", duoOuter.points), ("outer portrait", CGSize(width: 466, height: 678)),
                                 ("inner", duoInner.points), ("19.5:9 outer", duo[2].1.points), ("inner portrait", CGSize(width: 669, height: 951))]
for mode in DisplayMode.allCases {
    var ok = true, inside = true, notes: [String] = []
    for (name, size) in steps {
        let bounds = CGRect(origin: .zero, size: size)
        let r = GameSurfaceLayout.rect(guest: guest, aspect: .zero, bounds: bounds, mode: mode)
        // Fit and Aspect stay inside the screen; Fill covers it; Stretch is the screen.
        switch mode {
        case .fit, .aspect: inside = inside && r.minX >= -0.01 && r.minY >= -0.01 && r.maxX <= size.width + 0.01 && r.maxY <= size.height + 0.01 && (abs(r.width - size.width) < 0.01 || abs(r.height - size.height) < 0.01)
        case .fill: inside = inside && r.minX <= 0.01 && r.minY <= 0.01 && r.maxX >= size.width - 0.01 && r.maxY >= size.height - 0.01
        case .stretch: inside = inside && r == bounds
        }
        func at(_ p: CGPoint) -> CGPoint { GameSurfaceLayout.map(point: p, guest: guest, aspect: .zero, bounds: bounds, mode: mode) }
        let corners = [(CGPoint(x: r.minX, y: r.minY), CGPoint(x: 0, y: 0)), (CGPoint(x: r.maxX, y: r.minY), CGPoint(x: 1335, y: 0)),
                       (CGPoint(x: r.minX, y: r.maxY), CGPoint(x: 0, y: 935)), (CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: 1335, y: 935)),
                       (CGPoint(x: r.midX, y: r.midY), CGPoint(x: 668, y: 468))]
        for (p, want) in corners {
            let got = at(p)
            if abs(got.x - want.x) > 1 || abs(got.y - want.y) > 1 { ok = false; notes.append("\(name) \(p) -> \(got) want \(want)") }
        }
    }
    expect(inside, "fold \(mode): the picture is placed for every screen in the sequence")
    expect(ok, "fold \(mode): touch at the picture's corners and centre hits the guest's after every fold \(notes.prefix(3))")
}
// [display-geometry]: the log line's fields.
// The Duo's inner screen as the device logged it.
let g = DisplayGeometry(scene: CGSize(width: 951, height: 669), screen: CGSize(width: 951, height: 669), native: CGSize(width: 1878, height: 2670),
                        scale: 3, nativeScale: 2.807, orientation: "landscape-left", horizontal: "regular", vertical: "regular", idiom: "phone",
                        safeArea: .init(top: 0, left: 0, bottom: 34, right: 84), screens: 2, maxFPS: 120)
expect(g.line == "scene=951x669pt screen=951x669pt native=1878x2670px scale=3 native-scale=2.807 orientation=landscape-left size-class=regular/regular idiom=phone safe-area=0,0,34,84 screens=2 max-fps=120",
       "display-geometry: the line names every field (\(g.line))")
var h = g; h.safeArea.right = 0
expect(g != h, "display-geometry: a safe-area change is a new reading")

exit(failed ? 1 : 0)
'''.replace("GOLDEN_SCREENS", swift_screens(GOLDEN_SCREENS)).replace("DUO_SCREENS", swift_screens(DUO_SCREENS))

prelude = r'''import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if os(Windows)
import ucrt
@discardableResult func setenv(_ name: String, _ value: String, _ overwrite: Int32) -> Int32 { _putenv_s(name, value) == 0 ? 0 : -1 }
#endif
'''

with tempfile.TemporaryDirectory(prefix="duo-display-") as temp:
    source, binary = Path(temp) / "main.swift", Path(temp) / "check"
    source.write_text(prelude + display.replace("import Foundation\n", "", 1) + harness)
    (Path(temp) / "DisplayGeometry.swift").write_text(geometry)
    subprocess.run([os.environ.get("SWIFTC", "swiftc"), str(source), str(Path(temp) / "DisplayGeometry.swift"),
                    "-o", str(binary)], check=True)
    if "--record" in sys.argv:
        subprocess.run([str(binary), "record"], check=True)
        sys.exit(0)
    assert GOLDEN is not None, "no golden table recorded yet: run with --record and paste it into GOLDEN"
    r = subprocess.run([str(binary)], input=json.dumps(GOLDEN).encode(), capture_output=True)
    sys.stdout.write(r.stdout.decode())
    sys.stderr.write(r.stderr.decode())
    if r.returncode:
        print("check-duo-display: FAIL")
        sys.exit(1)
    print("check-duo-display: PASS")
