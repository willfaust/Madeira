#!/usr/bin/env python3
"""Run the production capture methods with a fixed clock and host input stubs."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/HardwareInput.swift').read_text()
pure = source.split('// MARK: - Pure input mapping', 1)[1].split('// MARK: - Device glue', 1)[0]


def member(declaration):
    start = source.index('    ' + declaration)
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end].replace('private ', '')


fixture = r'''
import Foundation

enum Clock { static var now = 100.0 }
func CACurrentMediaTime() -> Double { Clock.now }
enum DispatchQueue {
    struct Queue { func async(execute: () -> Void) { execute() } }
    static let main = Queue()
}
struct MotionLock { func lock() {} ; func unlock() {} }
enum InputSettings {
    final class Settings { var relative = false }
    static let shared = Settings()
}
enum MetalBackedView { static var cursor = CGPoint(x: 50, y: 50) }
var pointerPackets: [UInt32] = []
var cursorMoves = 0
func winios_pointer(_ x: Int32, _ y: Int32, _ flags: UInt32, _ data: UInt32) {
    pointerPackets.append(flags)
}
func winios_cursor_move(_ x: Int32, _ y: Int32) { cursorMoves += 1 }
final class HardwareInput {
    static var shared = HardwareInput()
    static var mouseRoutingEnabled = true
    static var autoLockEnabled = true
    static var directCursorEnabled = true
    static var pointerLockAvailable = true
    static var desktopMode = false
    static var hiddenCursorAbsolute = false   // MADEIRA_POINTER_HIDDEN_ABSOLUTE, off by default
    var readsMotion = false                   // MouseReader: the program reads mouse motion
    static let moveFlag: UInt32 = 1
    static let absoluteFlag: UInt32 = 0x8000
    static func desktopSize() -> (w: Int, h: Int) { (1024, 768) }
    var directCursorLive: Bool { Self.directCursorEnabled && !Self.desktopMode }
    enum MousePath { case gcmouse, uikit }
    var mousePath = MousePath.gcmouse
    var motionLock = MotionLock()
    var lastGCDeltaAt = Clock.now
    var lastReportAt = 0.0
    var cursorHiddenSince = 0.0
    var cursorState: (reports: UInt32, shown: UInt32) = (0, 1)
    var pointerOver = true
    var baseFocused = true
    var pointerLocked = false
    var lockedByUs = false
    var autoLockSuppressed = false
    func setPointerLocked(_ on: Bool, byUs: Bool, why: String) {
        pointerLocked = on
        lockedByUs = on && byUs
    }
'''

tests = r'''
func reset(relative: Bool = false, desktop: Bool = false) -> HardwareInput {
    Clock.now = 100
    InputSettings.shared.relative = relative
    HardwareInput.mouseRoutingEnabled = true
    HardwareInput.autoLockEnabled = true
    HardwareInput.directCursorEnabled = true
    HardwareInput.pointerLockAvailable = true
    HardwareInput.desktopMode = desktop
    HardwareInput.shared = HardwareInput()
    pointerPackets = []
    cursorMoves = 0
    return HardwareInput.shared
}

// Relative mode must capture without a hidden-cursor report, then stay captured.
for desktop in [false, true] {
    let h = reset(relative: true, desktop: desktop)
    assert(!h.cursorShownForRoute)
    assert(PointerPolicy.route(focused: true, hover: true, locked: false,
                               cursorShown: h.cursorShownForRoute, absoluteAllowed: true) == .relative)
    h.updateAutoLock()
    assert(h.pointerLocked && h.lockedByUs, "relative mode did not capture")
    Clock.now += 10
    h.lastGCDeltaAt = Clock.now
    h.updateAutoLock()
    assert(h.pointerLocked, "relative mode lost capture without cursor reports")
    h.baseFocused = false
    h.updateAutoLock()
    assert(!h.pointerLocked, "focus loss did not release capture")
}

// Explicit release, unsupported paths and idle motion must not be overridden.
for condition in 0..<6 {
    let h = reset(relative: true)
    switch condition {
    case 0: h.autoLockSuppressed = true
    case 1: HardwareInput.pointerLockAvailable = false
    case 2: h.mousePath = .uikit
    case 3: HardwareInput.autoLockEnabled = false
    case 4: HardwareInput.directCursorEnabled = false
    default: h.lastGCDeltaAt = 0
    }
    h.updateAutoLock()
    assert(!h.pointerLocked)
}

// A desktop game can stop issuing cursor reports while it reads raw motion.
let desktop = reset(desktop: true)
desktop.cursorState = (1, 0)
desktop.cursorHiddenSince = 1
desktop.lastReportAt = 1
desktop.updateAutoLock()
assert(desktop.pointerLocked, "desktop capture depended on fresh cursor reports")
desktop.cursorState.shown = 1
desktop.updateAutoLock()
assert(!desktop.pointerLocked)

// Normal direct sessions still release a stale capture and respect shown cursors.
let direct = reset()
direct.cursorState = (1, 0)
direct.cursorHiddenSince = 99
direct.lastReportAt = 99.9
direct.updateAutoLock()
assert(direct.pointerLocked)
direct.lastReportAt = 1
direct.updateAutoLock()
assert(!direct.pointerLocked)
direct.cursorState.shown = 1
direct.updateAutoLock()
assert(!direct.pointerLocked)

// A program that reads motion is captured although its cursor shows (CS2 keeps its arrow in a match),
// and released when it stops reading; HIDDEN_ABSOLUTE keeps it uncaptured.
for desktop in [false, true] {
    let h = reset(desktop: desktop)
    h.cursorState = (1, 1)
    h.lastReportAt = Clock.now
    h.updateAutoLock()
    assert(!h.pointerLocked)
    h.readsMotion = true
    assert(!h.cursorShownForRoute)
    h.updateAutoLock()
    assert(h.pointerLocked && h.lockedByUs, "a motion reader with its cursor up was not captured")
    h.readsMotion = false
    h.updateAutoLock()
    assert(!h.pointerLocked, "capture outlived the motion reader")
    h.readsMotion = true
    HardwareInput.hiddenCursorAbsolute = true
    assert(h.cursorShownForRoute)
    h.updateAutoLock()
    assert(!h.pointerLocked)
    HardwareInput.hiddenCursorAbsolute = false
}

// Hidden mouse-look must not get an absolute desktop cursor move after its delta.
for relative in [false, true] {
    let h = reset(relative: relative, desktop: true)
    h.cursorState = (1, 0)
    h.followDesktopCursor(2, -3, sync: true)
    assert(pointerPackets.isEmpty && cursorMoves == 0)
    h.cursorState.shown = 1
    h.followDesktopCursor(2, -3, sync: true)
    assert(pointerPackets.count == (relative ? 0 : 1))
}

// The rollback preserves the old route and desktop cursor updates.
let legacy = reset(relative: true, desktop: true)
HardwareInput.mouseRoutingEnabled = false
assert(legacy.cursorShownForRoute)
legacy.followDesktopCursor(2, -3, sync: true)
assert(pointerPackets == [0x8001])
legacy.updateAutoLock()
assert(!legacy.pointerLocked)
print("PASS: production capture, cursor route, desktop motion, release and rollback")
'''

with tempfile.TemporaryDirectory(prefix='madeira-capture-') as directory:
    src, exe = Path(directory) / 'main.swift', Path(directory) / 'check'
    methods = '\n'.join(member(declaration) for declaration in (
        'private var cursorShownForRoute: Bool {',
        'private func updateAutoLock() {',
        'private func followDesktopCursor(_ dx: Int32, _ dy: Int32, sync: Bool) {',
    ))
    src.write_text(fixture + methods + '\n}\n' + pure + tests)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)

view = (root / 'app/Madeira/ContentView.swift').read_text()
session = view.split('private var sessionBody:', 1)[1].split('private var portraitBody:', 1)[0]
overlay = view.split('struct TouchControlsOverlay:', 1)[1].split('private func controls(', 1)[0]
assert '.persistentSystemOverlays(.hidden)' in session
assert '.statusBarHidden(library.current != nil)' in overlay
assert '.persistentSystemOverlays(library.current != nil ? .hidden : .automatic)' in overlay
print('PASS: game and overlay roots hide system controls during library play')
