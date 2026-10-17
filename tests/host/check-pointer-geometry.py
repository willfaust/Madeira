#!/usr/bin/env python3
"""Exercise the production touch/hardware mapping without UIKit or a device.

Compile GameSurfaceLayout, MetalBackedView.mapPoint, HardwareInput.postAbsolute,
HardwareInput.postRelative and DirectCursorOverlay.render. Only native UI and
Wine boundaries are stubbed.
The old fixed 1024x768 hardware mapping is a negative control for resolutions,
Fill, Stretch and fitted windows.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / "app/Madeira"
content = (app / "ContentView.swift").read_text()
hardware = (app / "HardwareInput.swift").read_text()
display = (app / "GuestDisplay.swift").read_text().split("enum GuestDisplay {", 1)[0]


def function(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


mapping = function(content, "func mapPoint(")
pointer_rect = function(content, "func pointerRect(")
game_rect = function(content, "private func gameRect(")
absolute = function(hardware, "private func postAbsolute(")
relative = function(hardware, "func postRelative(")
overlay = function(hardware, "func render(visible:")
assert "gameView.mapPoint(p)" in absolute
assert "ScreenMap" not in hardware and "DirectCursorOverlay.screenW" not in hardware
assert "p.x.isFinite" in absolute and "p.y.isFinite" in absolute
assert "pointerRect()" in overlay
assert "bounds.width / client.width" in overlay and "bounds.height / client.height" in overlay
assert "* kx" in overlay and "* ky" in overlay

harness = r'''
class UIView {
    var bounds = CGRect(x: 0, y: 0, width: 1180, height: 820)
}
final class MetalBackedView: UIView {
    static var cursor = CGPoint.zero
    static var keyboardTarget: MetalBackedView?
    var desktopMode = false
    var size = CGSize(width: 1280, height: 720)
    var aspect = CGSize.zero
    var mode = DisplayMode.fit
    func guestSize() -> CGSize { size }
    func drawableAspect() -> CGSize { aspect }
    func effectiveDisplayMode() -> DisplayMode { mode }
    POINTER_RECT
    GAME_RECT
    func convert(_ point: CGPoint, to: Any?) -> CGPoint {
        CGPoint(x: point.x + 30, y: point.y + 60)
    }
    MAPPING
}
final class HardwareInput {
    static var desktopMode = false
    static var enabled = true
    static let moveFlag: UInt32 = 1, absoluteFlag: UInt32 = 0x8000
    var lastAbsolute: (x: Int32, y: Int32)?
    var desktopCursorSynced = false
    var motionLock = NSLock()
    var tickDX = 0.0, tickDY = 0.0
    func setMouseInUse(_ on: Bool) {}
    func updateTracking() {}
    func renderCursor() {}
    func bumpTicker() {}
    func followDesktopCursor(_ dx: Int32, _ dy: Int32, sync: Bool) {}
    ABSOLUTE
    RELATIVE
}
var posts: [(Int32, Int32, UInt32, UInt32)] = []
func winios_pointer(_ x: Int32, _ y: Int32, _ flags: UInt32, _ data: UInt32) {
    posts.append((x, y, flags, data))
}
final class CALayer {
    var isHidden = true
    var bounds = CGRect.zero
    var position = CGPoint.zero
}
enum CATransaction {
    static func begin() {}
    static func setDisableActions(_ disabled: Bool) {}
    static func commit() {}
}
final class MetalHostView: UIView { static let shared = MetalHostView() }
struct CursorImage { var w: Int32 = 16, h: Int32 = 24, hot_x: Int32 = 2, hot_y: Int32 = 3 }
final class DirectCursorOverlay {
    var layer: CALayer?
    var image = CursorImage()
    var serial: UInt32 = 1
    static let arrowSize = (w: 14, h: 21)
    func ensureLayer() -> CALayer {
        if let layer { return layer }
        let result = CALayer(); layer = result; return result
    }
    OVERLAY
}
var compositorCalls = 0
var clientRect: CGRect?
func winios_game_client_rect(_ x: inout Int32, _ y: inout Int32, _ w: inout Int32, _ h: inout Int32) -> Int32 {
    if CommandLine.arguments.contains("monitor") { return 0 }
    guard let rect = clientRect else { return 0 }
    x = Int32(rect.minX); y = Int32(rect.minY); w = Int32(rect.width); h = Int32(rect.height)
    return 1
}
func winios_desktop_point_from_window(_ x: Double, _ y: Double, _ px: inout Int32, _ py: inout Int32) -> Int32 {
    compositorCalls += 1
    // A desktop window with a non-zero client origin, fitted 2x onscreen.
    px = Int32((x - 30) / 2 + 10)
    py = Int32((y - 60) / 2 + 20)
    return 1
}
func expect(_ actual: (Int32, Int32), _ expected: (Int32, Int32), _ message: String) {
    guard actual == expected else {
        fatalError("\(message): got \(actual), expected \(expected)")
    }
}
let view = MetalBackedView()
MetalBackedView.keyboardTarget = view
let input = HardwareInput()
let legacy = CommandLine.arguments.contains("legacy")
func point(_ p: CGPoint) -> (Int32, Int32) {
    if !legacy {
        HardwareInput.desktopMode = view.desktopMode
        input.lastAbsolute = nil
        input.postAbsolute(p, in: view)
        let posted = posts.last!
        assert(posted.2 == 0x8001 && posted.3 == 0, "an absolute move in guest pixels")
        expect((posted.0, posted.1), view.mapPoint(p), "touch and hardware agree")
        return (posted.0, posted.1)
    }
    // The old postAbsolute always aspect-fit a fixed 1024x768 screen.
    let scale = min(view.bounds.width / 1024, view.bounds.height / 768)
    let x = (p.x - (view.bounds.width - 1024 * scale) / 2) / scale
    let y = (p.y - (view.bounds.height - 768 * scale) / 2) / scale
    return (Int32(min(max(x, 0), 1023)), Int32(min(max(y, 0), 767)))
}
for size in [CGSize(width: 1280, height: 720), CGSize(width: 1600, height: 1200)] {
    view.size = size
    for mode in DisplayMode.allCases {
        view.mode = mode
        view.aspect = CGSize(width: 1920, height: 1080)
        let frame = GameSurfaceLayout.rect(guest: size, aspect: view.aspect, bounds: view.bounds, mode: mode)
        let maxX = Int32(size.width - 1), maxY = Int32(size.height - 1)
        for (p, expected) in [
            (CGPoint(x: frame.minX, y: frame.minY), (Int32(0), Int32(0))),
            (CGPoint(x: frame.maxX, y: frame.minY), (maxX, Int32(0))),
            (CGPoint(x: frame.minX, y: frame.maxY), (Int32(0), maxY)),
            (CGPoint(x: frame.maxX, y: frame.maxY), (maxX, maxY)),
            (CGPoint(x: frame.midX, y: frame.midY), (Int32(size.width / 2), Int32(size.height / 2)))
        ] { expect(point(p), expected, "\(size) \(mode) \(p)") }
        expect(point(CGPoint(x: frame.minX - 100, y: frame.minY - 100)), (0, 0), "outside top-left clamps")
        expect(point(CGPoint(x: frame.maxX + 100, y: frame.maxY + 100)), (maxX, maxY), "outside bottom-right clamps")
        if mode == .fit {
            expect(point(.zero), (0, 0), "letterbox top-left")
            expect(point(CGPoint(x: view.bounds.maxX, y: view.bounds.maxY)), (maxX, maxY), "letterbox bottom-right")
        }
        if mode == .fill {
            let cropped = point(.zero)
            assert(cropped.0 > 0 || cropped.1 > 0, "Fill's visible corner is inside the cropped surface")
        }
    }
}
// A mode change must affect the next point without restarting input.
view.mode = .stretch
view.size = CGSize(width: 1280, height: 720)
expect(point(CGPoint(x: 590, y: 410)), (640, 360), "1280 centre")
view.size = CGSize(width: 1600, height: 1200)
expect(point(CGPoint(x: 590, y: 410)), (800, 600), "1600 centre after mode change")
// A 480x270 client is displayed across the 1280x720 game surface. Its
// window can have a non-zero screen origin; every edge must hit that HWND.
view.size = CGSize(width: 1280, height: 720)
for origin in [CGPoint.zero, CGPoint(x: 37, y: 51)] {
    clientRect = CGRect(origin: origin, size: CGSize(width: 480, height: 270))
    for mode in DisplayMode.allCases {
        view.mode = mode
        let frame = view.gameRect()
        for (p, expected) in [
            (CGPoint(x: frame.minX, y: frame.minY), (Int32(origin.x), Int32(origin.y))),
            (CGPoint(x: frame.maxX, y: frame.minY), (Int32(origin.x + 479), Int32(origin.y))),
            (CGPoint(x: frame.minX, y: frame.maxY), (Int32(origin.x), Int32(origin.y + 269))),
            (CGPoint(x: frame.maxX, y: frame.maxY), (Int32(origin.x + 479), Int32(origin.y + 269))),
            (CGPoint(x: frame.midX, y: frame.midY), (Int32(origin.x + 240), Int32(origin.y + 135)))
        ] { expect(point(p), expected, "small client at \(origin) in \(mode)") }
    }
}
// Desktop uses its own compositor transform, including fitted client windows.
view.desktopMode = true
expect(point(CGPoint(x: 100, y: 200)), (60, 120), "desktop compositor coordinates")
expect((Int32(MetalBackedView.cursor.x), Int32(MetalBackedView.cursor.y)), (60, 120), "desktop trackpad synced")
assert(compositorCalls == 2)  // one hardware move, one touch comparison
assert(input.desktopCursorSynced)
clientRect = nil
// Relative HID counts retain their units and direction. They are not view
// points and must not be multiplied by the drawable, screen or Retina scale.
HardwareInput.desktopMode = false
input.postRelative(123, -456)
assert(posts.last!.0 == 123 && posts.last!.1 == -456 && posts.last!.2 == 1)
assert(input.tickDX == 123 && input.tickDY == -456)
view.size = CGSize(width: 1280, height: 720)
input.postRelative(-789, 321)
assert(posts.last!.0 == -789 && posts.last!.1 == 321 && posts.last!.2 == 1)
let still = posts.count
input.postRelative(0, 0)
assert(posts.count == still)
// Invalid UIKit positions never reach the native integer conversion.
let count = posts.count
input.postAbsolute(CGPoint(x: Double.nan, y: 1), in: view)
input.postAbsolute(CGPoint(x: 1, y: Double.infinity), in: view)
view.bounds.size = .zero
input.postAbsolute(.zero, in: view)
assert(posts.count == count)
view.bounds = CGRect(x: 0, y: 0, width: 1180, height: 820)
// Cursor rendering is the inverse of the same guest-pixel mapping. Separate
// axes also handle Stretch and Aspect when drawable/monitor shapes differ.
let cursor = DirectCursorOverlay()
view.desktopMode = false
for size in [CGSize(width: 1280, height: 720), CGSize(width: 1600, height: 1200)] {
    view.size = size
    for mode in DisplayMode.allCases {
        view.mode = mode
        let frame = GameSurfaceLayout.rect(guest: size, aspect: view.aspect, bounds: view.bounds, mode: mode)
        MetalHostView.shared.bounds = CGRect(origin: .zero, size: frame.size)
        cursor.render(visible: true, x: Int32(size.width / 2), y: Int32(size.height / 2))
        let layer = cursor.layer!
        let centre = CGPoint(x: layer.position.x + 2 * frame.width / size.width,
                             y: layer.position.y + 3 * frame.height / size.height)
        assert(abs(centre.x - frame.width / 2) < 1e-8 && abs(centre.y - frame.height / 2) < 1e-8)
        assert(abs(layer.bounds.width - 16 * frame.width / size.width) < 1e-8)
        assert(abs(layer.bounds.height - 24 * frame.height / size.height) < 1e-8)
        assert(!layer.isHidden)
    }
}
clientRect = CGRect(x: 37, y: 51, width: 480, height: 270)
view.size = CGSize(width: 1280, height: 720)
MetalHostView.shared.bounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
cursor.render(visible: true, x: 277, y: 186)
assert(abs(cursor.layer!.position.x + 2 * 1280.0 / 480 - 640) < 1e-8)
assert(abs(cursor.layer!.position.y + 3 * 720.0 / 270 - 360) < 1e-8)
clientRect = nil  // destroyed/ended window falls back to the live monitor
assert(view.pointerRect() == CGRect(origin: .zero, size: view.size))
cursor.render(visible: false, x: 0, y: 0)
assert(cursor.layer!.isHidden)
print("PASS: live guest sizes, hardware/touch corners, centre, Fit/Fill/Stretch/Aspect, clamp, desktop and cursor")
'''.replace("MAPPING", mapping).replace("POINTER_RECT", pointer_rect).replace("GAME_RECT", game_rect.replace("private func", "func", 1)).replace("ABSOLUTE", absolute.replace("private func", "func", 1)).replace("RELATIVE", relative).replace("OVERLAY", overlay)

with tempfile.TemporaryDirectory(prefix="madeira-pointer-geometry-") as temp:
    source, binary = Path(temp) / "main.swift", Path(temp) / "check"
    source.write_text("import Foundation\n#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n" + display + harness)
    subprocess.run([os.environ.get("SWIFTC", "swiftc"), str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    negative = subprocess.run([str(binary), "legacy"], capture_output=True)
    assert negative.returncode != 0, "negative control: old fixed mapping unexpectedly passed"
    assert b"expected" in negative.stderr, "negative control failed before reaching a coordinate assertion"
    print("PASS: legacy fixed 1024x768 hardware mapping fails the same geometry assertions")
    negative = subprocess.run([str(binary), "monitor"], capture_output=True)
    assert negative.returncode != 0 and b"small client" in negative.stderr, "monitor-only mapping did not fail the small-client regression"
    print("PASS: monitor-only mapping fails the 480x270 presenting-client regression")
