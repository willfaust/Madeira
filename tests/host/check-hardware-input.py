#!/usr/bin/env python3
"""Hardware keyboard and mouse: compile the production mapping on a POSIX host.

Four parts:
  1. The pure section of app/Madeira/HardwareInput.swift (key map, mouse button
     edges, held-set diffing, motion carry, wheel notches, the AssistiveTouch
     classifier, the desktop cursor clamp, the right-stick velocity, the
     focus gating of held keys, click focus, the
     pointer route and the automatic pointer lock) is compiled with swiftc and
     exercised.
  2. Every HID keyboard usage is taken through the production chain
     HID usage -> virtual key (HardwareInput.swift) -> scan code (Wine's
     NtUserMapVirtualKeyEx(MAPVK_VK_TO_VSC_EX) on its built-in US layout, which
     is what the iOS driver uses) -> extended flag (winios_key_extended_flag,
     compiled from build/win32u-unix/driver_ios.c) and compared with the scan
     code a real PC keyboard sends for that key (USB HID to PS/2 set 1).
     check-nav-keys.py covers the navigation-key flag itself.
  3. app/Madeira/Winios/WiniosCursor.c, the direct-mode cursor state the driver
     reports into, is compiled with cc and exercised, including from threads.
  4. Source checks for the driver's reports, the app wiring and the switches.

Needs python3, swiftc (SWIFTC to override), a C compiler (CC, default cc) and
the Wine source: the `wine` submodule, or WINE_SRC=<path to a Wine tree>.
No iOS SDK, device, keyboard or mouse is needed.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
wine = Path(os.environ.get('WINE_SRC', root / 'wine'))
app = root / 'app/Madeira'
source = (app / 'HardwareInput.swift').read_text()
pure = source.split('// MARK: - Pure input mapping', 1)[1].split('// MARK: - Device glue', 1)[0]
for banned in ('UIKit', 'UITouch', 'winios_', 'GameController'):
    assert banned not in pure.replace('UIKit or Wine', ''), f'pure section uses {banned}'

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)


# ---------------------------------------------------------------- 1. Swift ---
swift_tests = r'''
// Key map: every usage the map knows, dumped for the scan-code comparison.
for u in 0..<256 {
    if let vk = HardwareKeyMap.vk(forHIDUsage: u) { print("MAP \(u) \(vk)") }
}
assert(HardwareKeyMap.vk(forHIDUsage: 0x04) == 0x41)        // a -> VK_A
assert(HardwareKeyMap.vk(forHIDUsage: 0x27) == 0x30)        // 0 -> VK_0
assert(HardwareKeyMap.vk(forHIDUsage: 0x45) == 0x7B)        // F12
assert(HardwareKeyMap.vk(forHIDUsage: 0x73) == 0x87)        // F24
assert(HardwareKeyMap.vk(forHIDUsage: 0xE1) == 0xA0)        // left shift is VK_LSHIFT
for u in [0x00, 0x01, 0x02, 0x03, 0x74, 0x76, 0x78, 0x7E, 0xE8, 0xFF] {
    assert(HardwareKeyMap.vk(forHIDUsage: u) == nil, "usage \(u) must stay unmapped")
}

// Ctrl+Alt+P, either side of each modifier; never P alone or with one modifier.
assert(HardwareKeyMap.isPointerLockChord(0x50, held: [0xA2, 0xA4, 0x50]))
assert(HardwareKeyMap.isPointerLockChord(0x50, held: [0xA3, 0xA5, 0x50]))
assert(!HardwareKeyMap.isPointerLockChord(0x50, held: [0xA2, 0x50]))
assert(!HardwareKeyMap.isPointerLockChord(0x50, held: [0xA4, 0x50]))
assert(!HardwareKeyMap.isPointerLockChord(0x51, held: [0xA2, 0xA4, 0x51]))

// Mouse buttons: MOUSEEVENTF_* pairs, XBUTTON1/2 in mouseData.
assert(MouseButton.left.event(down: true) == (0x0002, 0) && MouseButton.left.event(down: false) == (0x0004, 0))
assert(MouseButton.right.event(down: true) == (0x0008, 0) && MouseButton.right.event(down: false) == (0x0010, 0))
assert(MouseButton.middle.event(down: true) == (0x0020, 0) && MouseButton.middle.event(down: false) == (0x0040, 0))
assert(MouseButton.x1.event(down: true) == (0x0080, 1) && MouseButton.x1.event(down: false) == (0x0100, 1))
assert(MouseButton.x2.event(down: true) == (0x0080, 2) && MouseButton.x2.event(down: false) == (0x0100, 2))

// Held-set diffing: declared sets converge, ups before downs, no duplicates.
var keys = HeldEdges<Int32>()
var e = keys.update([0x57, 0xA0])
assert(e.up.isEmpty && e.down == [0x57, 0xA0])
e = keys.update([0x57, 0xA0])
assert(e.up.isEmpty && e.down.isEmpty)                      // a repeat posts nothing
e = keys.update([0x41])
assert(e.up == [0x57, 0xA0] && e.down == [0x41])
e = keys.update([])
assert(e.up == [0x41] && e.down.isEmpty && keys.down.isEmpty)
var buttons = HeldEdges<MouseButton>()
_ = buttons.update([.left, .x2])
let b = buttons.update([.right])
assert(b.up == [.left, .x2] && b.down == [.right])

// Motion carry: fractions accumulate, truncation toward zero, clamp, NaN.
var carry = MotionCarry()
var sum: Int32 = 0
for _ in 0..<10 { sum += carry.add(0.25, 0, gain: 1).dx }
assert(sum == 2)                                            // 2.5 -> 2, 0.5 carried
assert(carry.add(0.5, 0, gain: 1).dx == 1)
var neg = MotionCarry()
assert(neg.add(-0.6, -1.4, gain: 1) == (0, -1))
assert(neg.add(-0.6, 0, gain: 1).dx == -1)
var big = MotionCarry()
assert(big.add(1e9, -1e9, gain: 1) == (30000, -30000))
var bad = MotionCarry()
assert(bad.add(.nan, 1, gain: 1) == (0, 0) && bad.add(1, 1, gain: .infinity) == (0, 0))
var gained = MotionCarry()
assert(gained.add(3, -3, gain: 2) == (6, -6))

// Wheel: whole notches of 120, remainder kept, bounded bursts, NaN ignored.
var wheel = WheelAccumulator()
assert(wheel.add(0, 0.6).isEmpty)
var n = wheel.add(0, 0.6)
assert(n.count == 1 && n[0].flags == 0x0800 && n[0].delta == 120)
n = wheel.add(0, -2.2)
assert(n.count == 2 && n.allSatisfy { $0.flags == 0x0800 && $0.delta == -120 })
n = wheel.add(1.0, 0)
assert(n.count == 1 && n[0].flags == 0x1000 && n[0].delta == 120)
n = wheel.add(0, 1e12)
assert(n.count == WheelAccumulator.maxNotchesPerEvent)
assert(wheel.add(0, 0.5).isEmpty)                           // the burst did not linger
assert(wheel.add(.nan, .infinity).isEmpty)

// AssistiveTouch classifier: no contact patch, or coincident with a GC button.
assert(SynthesizedTouch.looksSynthesized(direct: true, majorRadius: 0, secondsSinceButton: .infinity))
assert(SynthesizedTouch.looksSynthesized(direct: true, majorRadius: 20, secondsSinceButton: 0.010))
assert(!SynthesizedTouch.looksSynthesized(direct: true, majorRadius: 20, secondsSinceButton: 0.5))
assert(!SynthesizedTouch.looksSynthesized(direct: false, majorRadius: 0, secondsSinceButton: 0))

// Desktop cursor follows relative motion inside the desktop.
assert(DesktopCursor.advance(x: 10, y: 10, dx: -50, dy: 5, width: 1024, height: 768) == (0, 15))
assert(DesktopCursor.advance(x: 1000, y: 760, dx: 100, dy: 100, width: 1024, height: 768) == (1023, 767))
assert(DesktopCursor.advance(x: 5, y: 5, dx: 1, dy: 1, width: 0, height: 0) == (0, 0))

// Right stick as a velocity mouse.
assert(StickVelocity.deflect(0.1, 0.1) == (0, 0))           // inside the deadzone
let full = StickVelocity.deflect(1, 0)
assert(abs(full.x - 1) < 1e-9 && full.y == 0)
let f = StickVelocity.frame(x: 1, y: 1, gain: 1, dt: 1.0 / 60)
assert(f.dx > 0 && f.dy < 0)                                // stick up = mouse up
assert(abs((f.dx * f.dx + f.dy * f.dy).squareRoot() - 6.0) < 1e-9)   // 360/s at 60 Hz
let stalled = StickVelocity.frame(x: 1, y: 0, gain: 1, dt: 5)
assert(abs(stalled.dx - 24.0) < 1e-9)                       // dt clamped to 1/15 s
assert(StickVelocity.frame(x: .nan, y: 0, gain: 1, dt: 0.016) == (0, 0))

// View-to-screen geometry is exercised by check-pointer-geometry.py.

// Focus gate: losing focus hides held keys; a key pressed without focus stays
// hidden until released, even after focus returns.
var gate = FocusGate<Int32>()
gate.press(0x57, focused: true)
assert(gate.wanted(focused: true) == [0x57])
gate.focusLost()
assert(gate.wanted(focused: false).isEmpty && gate.wanted(focused: true).isEmpty)
gate.press(0x41, focused: false)
assert(gate.wanted(focused: true).isEmpty)                  // W and A were not seen going down
gate.release(0x57)
gate.press(0x57, focused: true)
assert(gate.wanted(focused: true) == [0x57])                 // a fresh press counts again
gate.release(0x41)
gate.press(0x50, focused: true); gate.block(0x50)            // the swallowed P of Ctrl+Alt+P
assert(gate.wanted(focused: true) == [0x57])
gate.release(0x50)
gate.press(0x50, focused: true)
assert(gate.wanted(focused: true) == [0x57, 0x50])
gate.reset()
assert(gate.physical.isEmpty && gate.wanted(focused: true).isEmpty)

// Click focus: a press is routed by the tap that carries it, before or after.
var click = ClickFocus()
assert(click.onGame && click.route(buttonAt: 10, now: 10) == nil)   // no tap yet: wait
assert(click.route(buttonAt: 10, now: 10.061) == true)              // none came: current focus
click.touchBegan(onGame: false, at: 20.00)
assert(!click.onGame && click.route(buttonAt: 20.02, now: 20.02) == false)   // tap just before
click.touchBegan(onGame: true, at: 30.03)
assert(click.route(buttonAt: 30.00, now: 30.04) == true)                     // tap just after
assert(click.route(buttonAt: 40.00, now: 40.00) == nil)
assert(click.route(buttonAt: 40.00, now: 40.07) == true)
click.touchBegan(onGame: false, at: 50)
assert(click.route(buttonAt: 60, now: 60.1) == false)
assert(click.route(buttonAt: .nan, now: 1) == false)

// Pointer route: absolute only where the pointer's position is known, the
// program shows a cursor and nothing is locked.
assert(PointerPolicy.route(focused: false, hover: true, locked: false, cursorShown: true, absoluteAllowed: true) == .blocked)
assert(PointerPolicy.route(focused: true, hover: true, locked: false, cursorShown: true, absoluteAllowed: true) == .absolute)
assert(PointerPolicy.route(focused: true, hover: true, locked: true, cursorShown: true, absoluteAllowed: true) == .relative)
assert(PointerPolicy.route(focused: true, hover: true, locked: false, cursorShown: false, absoluteAllowed: true) == .relative)
assert(PointerPolicy.route(focused: true, hover: false, locked: false, cursorShown: true, absoluteAllowed: true) == .relative)
assert(PointerPolicy.route(focused: true, hover: true, locked: false, cursorShown: true, absoluteAllowed: false) == .relative)

// Automatic lock: only for a live program that hides its cursor under the pointer.
func lockAction(locked: Bool = false, byUs: Bool = false, shown: Bool = false, hiddenFor: Double = 1,
                over: Bool = true, focused: Bool = true, sinceReport: Double = 0.1, sinceMotion: Double = 0.1) -> AutoLock.Action {
    AutoLock.decide(locked: locked, lockedByUs: byUs, cursorShown: shown, hiddenFor: hiddenFor, pointerOver: over,
                    focused: focused, sinceReport: sinceReport, sinceMotion: sinceMotion)
}
assert(lockAction() == .lock)
assert(lockAction(shown: true) == .none)
assert(lockAction(hiddenFor: 0.2) == .none)                  // the program may be about to show one
assert(lockAction(over: false) == .none)
assert(lockAction(focused: false) == .none)
assert(lockAction(sinceReport: 5) == .none)                  // no program is draining the mouse
assert(lockAction(sinceMotion: 3) == .none)                  // the mouse is not in use
assert(lockAction(locked: true, byUs: true, shown: true) == .unlock)
assert(lockAction(locked: true, byUs: true, focused: false) == .unlock)
assert(lockAction(locked: true, byUs: true, sinceReport: 3) == .unlock)      // the program went away
assert(lockAction(locked: true, byUs: true, sinceReport: 3, sinceMotion: 3) == .none)
assert(lockAction(locked: true, byUs: true, over: false) == .none)           // locked pointers do not hover
assert(lockAction(locked: true, byUs: false, shown: true) == .none)          // the user's own lock stays
print("SWIFT-OK")
'''

with tempfile.TemporaryDirectory(prefix='madeira-hwinput-') as tmp:
    tmp = Path(tmp)
    src, exe = tmp / 'main.swift', tmp / 'check'
    src.write_text('import Foundation\n' + pure + swift_tests)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), str(src), '-o', str(exe)], check=True)
    out = subprocess.run([str(exe)], check=True, capture_output=True, text=True).stdout
check('SWIFT-OK' in out, 'Swift pure-section checks')
hid_to_vk = {int(u): int(v) for u, v in re.findall(r'^MAP (\d+) (-?\d+)$', out, re.M)}
print(f'PASS: pure mapping ({len(hid_to_vk)} HID usages mapped), button edges, held sets, '
      'carry, wheel, classifier, desktop cursor, stick velocity')

# ---------------------------------------------------- 2. Wine scan codes ---
input_c = wine / 'dlls/win32u/input.c'
if not input_c.exists():
    sys.exit(f'FAIL: Wine source not found at {wine}; check out the wine submodule or set WINE_SRC')

vk_values = {}
for header in ('include/winuser.rh', 'include/winuser.h', 'include/kbd.h'):
    for name, val in re.findall(r'#define\s+VK_(\w+)\s+(?:\(\w+\))?(0x[0-9A-Fa-f]+|\d+)\b',
                                (wine / header).read_text(errors='replace')):
        vk_values.setdefault(name, int(val, 0))
kbd = (wine / 'include/kbd.h').read_text(errors='replace')
kbd_type = 4                                            # kbd.h's default KBD_TYPE
macros = dict(re.findall(r'#define\s+([TXY][0-9A-F]{2})\s+(.+)', kbd))


def macro_vk(token):
    body = macros[token].strip()
    if re.fullmatch(r"'.'", body):
        return ord(body[1])
    m = re.fullmatch(r'_EQ\((\w+)\)', body)
    if m:
        return vk_values.get(m.group(1), -1)
    m = re.fullmatch(r'_NE\(([^)]*)\)', body)
    if m:
        return vk_values.get(m.group(1).split(',')[kbd_type - 1].strip(), -1)
    raise ValueError(f'unparsed kbd.h macro {token} = {body}')


text = input_c.read_text(errors='replace')
main_table = re.search(r'static const USHORT vsc_to_vk\[\] =\s*\{(.*?)\};', text, re.S).group(1)
vsc2vk = {}
for vsc, entry in enumerate(t.strip() for t in main_table.split(',') if t.strip()):
    vk = macro_vk(entry.split('|')[0].strip())
    if vk != vk_values['_none_']:
        vsc2vk[vsc] = vk
for table, base in (('vsc_to_vk_e0', 0x100), ('vsc_to_vk_e1', 0x200)):
    body = re.search(r'static const VSC_VK %s\[\] =\s*\{(.*?)\};' % table, text, re.S).group(1)
    for vsc, entry in re.findall(r'\{\s*(0x[0-9a-fA-F]+)\s*,\s*([TXY][0-9A-F]{2})[^}]*\}', body):
        vk = macro_vk(entry)
        if vk != vk_values['_none_']:
            vsc2vk[base + int(vsc, 16)] = vk

# NtUserMapVirtualKeyEx(code, MAPVK_VK_TO_VSC_EX): the generic modifiers and the
# numpad virtual keys are first replaced, then the lowest scan-table index whose
# virtual key matches wins; an E0/E1 position is returned as 0xe0xx/0xe1xx.
assert 'case VK_NUMPAD8: code = VK_UP; break;' in text, "Wine's VK_TO_VSC remapping changed"
remap = {'SHIFT': 'LSHIFT', 'CONTROL': 'LCONTROL', 'MENU': 'LMENU', 'NUMPAD0': 'INSERT', 'NUMPAD1': 'END',
         'NUMPAD2': 'DOWN', 'NUMPAD3': 'NEXT', 'NUMPAD4': 'LEFT', 'NUMPAD5': 'CLEAR', 'NUMPAD6': 'RIGHT',
         'NUMPAD7': 'HOME', 'NUMPAD8': 'UP', 'NUMPAD9': 'PRIOR', 'DECIMAL': 'DELETE'}
remap = {vk_values[a]: vk_values[b] for a, b in remap.items()}


def vk_to_vsc_ex(vk):
    vk = remap.get(vk, vk)
    for idx in range(0x300):
        if idx in vsc2vk and (vsc2vk[idx] & 0xff) == vk:
            return idx + 0xdf00 if idx >= 0x100 else idx
    return 0


# The driver's extended-flag decision, compiled from the production source.
driver = (root / 'build/win32u-unix/driver_ios.c').read_text()
start = driver.index('static UINT winios_key_extended_flag(')
helper = driver[start:driver.index('/* end winios_key_extended_flag */', start)]
names = ('PRIOR', 'NEXT', 'END', 'HOME', 'LEFT', 'UP', 'RIGHT', 'DOWN', 'INSERT', 'DELETE')
c_src = '#include <stdio.h>\ntypedef unsigned int UINT;\n#define KEYEVENTF_EXTENDEDKEY 0x0001\n'
c_src += ''.join(f'#define VK_{nm} 0x{vk_values[nm]:02x}\n' for nm in names)
c_src += helper + r'''
int main(void)
{
    UINT vk, scan;
    while (scanf("%x %x", &vk, &scan) == 2)
        printf("%x %u %u\n", vk, winios_key_extended_flag(vk, scan, 1), winios_key_extended_flag(vk, scan, 0));
    return 0;
}
'''
queries = {vk: vk_to_vsc_ex(vk) for vk in sorted(set(hid_to_vk.values()))}
with tempfile.TemporaryDirectory(prefix='madeira-hwinput-c-') as tmp:
    csrc, cexe = Path(tmp) / 'flag.c', Path(tmp) / 'flag'
    csrc.write_text(c_src)
    subprocess.run([os.environ.get('CC', 'cc'), '-Wall', '-Werror', str(csrc), '-o', str(cexe)], check=True)
    res = subprocess.run([str(cexe)], input=''.join(f'{vk:x} {sc:x}\n' for vk, sc in queries.items()),
                         check=True, capture_output=True, text=True).stdout
ext_on, ext_off = {}, {}
for line in res.split('\n'):
    if line.strip():
        vk, on, off = line.split()
        ext_on[int(vk, 16)], ext_off[int(vk, 16)] = int(on), int(off)


def sent(usage, nav_e0=True):
    """(scan byte, extended) the driver sends for this HID usage."""
    vk = hid_to_vk[usage]
    ext = (ext_on if nav_e0 else ext_off)[vk]
    return (queries[vk] & 0xff, bool(ext))


# USB HID usage -> PS/2 scan code set 1 (make code, E0/E1 prefix as "extended").
pc = {}
for i, sc in enumerate([0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32,
                        0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C]):
    pc[0x04 + i] = (sc, False)                                             # a-z
for i in range(10):
    pc[0x1E + i] = (0x02 + i, False)                                       # 1-9, 0
pc.update({0x28: (0x1C, False), 0x29: (0x01, False), 0x2A: (0x0E, False), 0x2B: (0x0F, False),
           0x2C: (0x39, False), 0x2D: (0x0C, False), 0x2E: (0x0D, False), 0x2F: (0x1A, False),
           0x30: (0x1B, False), 0x31: (0x2B, False), 0x32: (0x2B, False), 0x33: (0x27, False),
           0x34: (0x28, False), 0x35: (0x29, False), 0x36: (0x33, False), 0x37: (0x34, False),
           0x38: (0x35, False), 0x39: (0x3A, False)})
for i in range(10):
    pc[0x3A + i] = (0x3B + i, False)                                       # F1-F10
pc.update({0x44: (0x57, False), 0x45: (0x58, False),                      # F11, F12
           0x47: (0x46, False), 0x48: (0x1D, True),                        # Scroll Lock, Pause (E1 1D)
           0x49: (0x52, True), 0x4A: (0x47, True), 0x4B: (0x49, True), 0x4C: (0x53, True),
           0x4D: (0x4F, True), 0x4E: (0x51, True), 0x4F: (0x4D, True), 0x50: (0x4B, True),
           0x51: (0x50, True), 0x52: (0x48, True),                         # nav cluster, arrows
           0x53: (0x45, False), 0x54: (0x35, True), 0x55: (0x37, False), 0x56: (0x4A, False),
           0x57: (0x4E, False),
           0x59: (0x4F, False), 0x5A: (0x50, False), 0x5B: (0x51, False), 0x5C: (0x4B, False),
           0x5D: (0x4C, False), 0x5E: (0x4D, False), 0x5F: (0x47, False), 0x60: (0x48, False),
           0x61: (0x49, False), 0x62: (0x52, False), 0x63: (0x53, False),  # numpad
           0x64: (0x56, False), 0x65: (0x5D, True),                        # ISO key, Application
           0x7F: (0x20, True), 0x80: (0x30, True), 0x81: (0x2E, True),     # volume
           0x87: (0x73, False),                                            # JIS ro
           0xE0: (0x1D, False), 0xE1: (0x2A, False), 0xE2: (0x38, False), 0xE3: (0x5B, True),
           0xE4: (0x1D, True), 0xE5: (0x36, False), 0xE6: (0x38, True), 0xE7: (0x5C, True)})
for i, sc in enumerate([0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x76]):
    pc[0x68 + i] = (sc, False)                                             # F13-F24

# Known, documented differences (docs/KEYBOARD_MOUSE.md). Each is pinned to what
# is sent today, so a change in either direction is noticed.
known = {
    0x46: ((0x54, False), 'Print Screen: VK_SNAPSHOT maps to the SysRq position 0x54'),
    0x58: ((0x1C, False), 'numpad Enter: posted as VK_RETURN, so no E0'),
    0x67: ((0x00, False), 'keypad = (VK_OEM_NEC_EQUAL): not in the US layout'),
    0x75: ((0x63, False), 'Help: no PC make code; VK_HELP maps to 0x63'),
    0x77: ((0x00, False), 'Select: not in the US layout'),
    0x85: ((0x00, False), 'keypad comma (VK_SEPARATOR): not in the US layout'),
    0x88: ((0x00, False), 'katakana/hiragana (VK_OEM_COPY): not in the US layout'),
    0x89: ((0x2B, False), 'JIS yen: shares VK_OEM_5 with backslash'),
    0x8A: ((0x00, False), 'convert: not in the US layout'),
    0x8B: ((0x00, False), 'non-convert: not in the US layout'),
    0x90: ((0x00, False), 'Hangul: not in the US layout'),
    0x91: ((0x00, False), 'Hanja: not in the US layout'),
}
check(set(hid_to_vk) == set(pc) | set(known),
      f'mapped usages differ from the reference: extra={sorted(set(hid_to_vk) - set(pc) - set(known))} '
      f'missing={sorted((set(pc) | set(known)) - set(hid_to_vk))}')
for usage, want in sorted(pc.items()):
    if usage in hid_to_vk:
        check(sent(usage) == want, f'HID 0x{usage:02x} vk=0x{hid_to_vk[usage]:02x}: '
                                   f'sent {sent(usage)} want {want}')
for usage, (want, why) in sorted(known.items()):
    if usage in hid_to_vk:
        check(sent(usage) == want, f'known difference changed, HID 0x{usage:02x} ({why}): sent {sent(usage)}')
print(f'PASS: {len(pc)} keys send the PC scan code and E0 flag through Wine\'s US layout '
      f'({len(known)} documented differences pinned)')

# ------------------------------------------------ 3. Direct-mode cursor (C) ---
cursor_test = r'''
#include "WiniosCursor.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static int notified;
static void notify(void) { notified++; }

static void *hammer(void *arg)
{
    int i, base = (int)(long)arg;
    unsigned char px[4 * 4 * 4];
    for (i = 0; i < 20000; i++)
    {
        winios_direct_cursor_pos(base + i % 100, i % 50);
        if (i % 1000 == 0)
        {
            memset(px, i & 0xff, sizeof(px));
            winios_direct_cursor_set(1, 4, 4, 1, 2, px);
            winios_direct_cursor_show(i % 2000 == 0);
        }
    }
    return NULL;
}

int main(void)
{
    struct winios_direct_cursor_state s;
    unsigned char img[3 * 2 * 4], out[WINIOS_CURSOR_MAX * WINIOS_CURSOR_MAX * 4];
    pthread_t th[4];
    int i;

    /* Inert until the app enables it: the driver asks first and does nothing. */
    assert(!winios_direct_cursor_wanted());
    winios_direct_cursor_pos(5, 6);
    winios_direct_cursor_show(1);
    winios_direct_cursor_get(&s);
    assert(s.x == 0 && s.y == 0 && !s.shown && s.reports == 0);

    winios_direct_cursor_enable(notify);
    assert(winios_direct_cursor_wanted());

    /* The first report notifies even untracked; later positions only while tracking. */
    winios_direct_cursor_pos(10, 20);
    assert(notified == 1);
    winios_direct_cursor_pos(11, 21);                 /* not tracking, and a notification is pending */
    winios_direct_cursor_get(&s);
    assert(s.x == 11 && s.y == 21 && s.reports == 1 && !s.shown);
    winios_direct_cursor_pos(12, 22);
    assert(notified == 1);                            /* untracked: stored, no notification */
    winios_direct_cursor_track(1);
    winios_direct_cursor_pos(12, 22);
    assert(notified == 2);                            /* tracked: every report counts, moved or not */
    winios_direct_cursor_pos(13, 23);
    assert(notified == 2);                            /* coalesced until the app takes the state */
    winios_direct_cursor_get(&s);
    assert(s.x == 13 && s.y == 23);
    winios_direct_cursor_track(0);

    /* Visibility notifies on change only. */
    winios_direct_cursor_show(1);
    assert(notified == 3);
    winios_direct_cursor_get(&s);
    assert(s.shown == 1);
    winios_direct_cursor_show(1);
    assert(notified == 3);
    winios_direct_cursor_show(0);
    assert(notified == 4);
    winios_direct_cursor_get(&s);
    assert(s.shown == 0);

    /* Images: copied, serial bumps, oversized or empty ones are refused. */
    for (i = 0; i < (int)sizeof(img); i++) img[i] = (unsigned char)i;
    winios_direct_cursor_set(7, 3, 2, 1, 1, img);
    assert(notified == 5);
    memset(img, 0, sizeof(img));                      /* the caller's buffer is not kept */
    winios_direct_cursor_get(&s);
    assert(s.w == 3 && s.h == 2 && s.hot_x == 1 && s.hot_y == 1 && s.image_serial == 1);
    memset(&s, 0, sizeof(s));
    assert(winios_direct_cursor_copy_image(out, sizeof(out), &s) == 1);
    assert(s.w == 3 && s.h == 2 && s.image_serial == 1);
    for (i = 0; i < 3 * 2 * 4; i++) assert(out[i] == (unsigned char)i);
    assert(winios_direct_cursor_copy_image(out, 3 * 2 * 4 - 1, NULL) == 0);   /* does not fit */
    winios_direct_cursor_set(8, WINIOS_CURSOR_MAX + 1, 1, 0, 0, out);
    winios_direct_cursor_set(8, 0, 1, 0, 0, out);
    winios_direct_cursor_set(8, 1, 1, 0, 0, NULL);
    winios_direct_cursor_get(&s);
    assert(s.image_serial == 1 && s.w == 3);

    /* Reports from several threads while the app reads. */
    winios_direct_cursor_track(1);
    for (i = 0; i < 4; i++) pthread_create(&th[i], NULL, hammer, (void *)(long)(i * 1000));
    for (i = 0; i < 2000; i++)
    {
        winios_direct_cursor_get(&s);
        if (s.image_serial > 1) assert(s.w == 4 && s.h == 4 && s.hot_x == 1 && s.hot_y == 2);
        winios_direct_cursor_copy_image(out, sizeof(out), NULL);
    }
    for (i = 0; i < 4; i++) pthread_join(th[i], NULL);
    winios_direct_cursor_get(&s);
    assert(s.w == 4 && s.image_serial > 1);
    printf("CURSOR-OK %d notifications\n", notified);
    return 0;
}
'''
winios = app / 'Winios'
with tempfile.TemporaryDirectory(prefix='madeira-hwinput-cursor-') as tmp:
    csrc, cexe = Path(tmp) / 'cursor_test.c', Path(tmp) / 'cursor_test'
    csrc.write_text(cursor_test)
    subprocess.run([os.environ.get('CC', 'cc'), '-Wall', '-Wextra', '-Werror', '-pthread', f'-I{winios}',
                    str(csrc), str(winios / 'WiniosCursor.c'), '-o', str(cexe)], check=True)
    out = subprocess.run([str(cexe)], check=True, capture_output=True, text=True).stdout
check('CURSOR-OK' in out, 'WiniosCursor.c checks')
print('PASS: direct-mode cursor state: inert until enabled, first-report and tracked notifications, '
      'coalescing, visibility, image copy and bounds, concurrent reports')

# ------------------------------------------------------- 4. Source wiring ---
# The driver: reports only in direct mode and only once the app asked; the
# desktop compositor path is unchanged; what the program sees is unchanged.
check('if (!winios_desktop_mode() || !winios_cursor_set) return;' not in driver
      and 'cursor_set = winios_direct_cursor_set;' in driver
      and 'if (!winios_direct_cursor_on()) return;' in driver,
      'winios_drv_set_cursor sends direct-mode cursors to WiniosCursor.c, only when wanted')
check('if (winios_desktop_mode())       winios_user_driver.pSetCursor           = winios_drv_set_cursor;' in driver
      and 'else if (winios_direct_cursor_set) winios_user_driver.pSetCursor         = winios_drv_set_cursor;' in driver,
      'pSetCursor: compositor in the desktop session, direct-mode report otherwise')
check('winios_user_driver.pSetCursorPos = winios_drv_set_cursor_pos;' in driver
      and re.search(r'static BOOL winios_drv_set_cursor_pos\( INT x, INT y \)\s*\{\s*'
                    r'if \(winios_direct_cursor_on\(\)\) winios_direct_cursor_pos\( x, y \);\s*return TRUE;\s*\}',
                    driver) is not None,
      'pSetCursorPos reports and succeeds, as nulldrv does')
check('if ((flags & MOUSEEVENTF_MOVE) && winios_direct_cursor_on()) winios_report_cursor_pos();' in driver,
      'every posted move reports where the server put the cursor')
check(re.search(r'static int winios_direct_cursor_on\(void\)\s*\{\s*return !winios_desktop_mode\(\) && '
                r'winios_direct_cursor_wanted && winios_direct_cursor_wanted\(\);', driver) is not None,
      'the reports are gated on direct mode and the app')
for sym in ('winios_direct_cursor_wanted', 'winios_direct_cursor_set', 'winios_direct_cursor_show',
            'winios_direct_cursor_pos'):
    check(re.search(sym + r'\([^;]*\)\s*__attribute__\(\(weak\)\);', driver) is not None, f'{sym} is a weak import')
bridging = (app / 'Madeira-Bridging-Header.h').read_text()
check('#import "Winios/WiniosCursor.h"' in bridging, 'the bridging header imports WiniosCursor.h')

cv = (app / 'ContentView.swift').read_text()
for phase in ('began', 'moved', 'ended', 'cancelled'):
    check(f'HardwareInput.shared.interceptTouches(touches, event, .{phase})' in cv,
          f'MetalBackedView touches{phase.capitalize()} must ask HardwareInput first')
check(cv.count('PointerFallback.install(on: self)') == 2, 'both MetalBackedView initialisers install the pointer fallback')
check(cv.count('if HardwareInput.shared.handlesTyping { return }') == 2, 'text bridge stands aside for a hardware keyboard')
check('HardwareInputSettings(open: pointerPanel)' in cv, 'settings row in the pointer panel')
for key, default in (('sensMouse', '1.0'), ('ignoreTouchesWithMouse', 'true'), ('padRightStickMouse', 'false')):
    check(f'"{key}": {key}' in cv and f'{key} = j["{key}"]' in cv and f'?? {default}' in cv,
          f'InputSettings persists {key}')
check('HardwareInput.shared.start()' in (app / 'MadeiraApp.swift').read_text(), 'MadeiraApp starts HardwareInput')
plist = (app / 'Info.plist').read_text()
check(re.search(r'<key>UIApplicationSupportsIndirectInputEvents</key>\s*<true/>', plist) is not None,
      'Info.plist opts into indirect input events')
pbx = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
check('HardwareInput.swift in Sources */,' in pbx and 'path = HardwareInput.swift;' in pbx, 'HardwareInput.swift is built')
check('Winios/WiniosCursor.c in Sources */,' in pbx and 'path = "Winios/WiniosCursor.c";' in pbx,
      'WiniosCursor.c is built')
switches = ('MADEIRA_HWINPUT', 'MADEIRA_INPUT_FOCUS', 'MADEIRA_DIRECT_CURSOR', 'MADEIRA_POINTER_ABSOLUTE',
            'MADEIRA_POINTER_LOCK', 'MADEIRA_POINTER_AUTOLOCK')
for switch in switches:
    check(f'flag("{switch}", defaultOn: true)' in source, f'{switch} switch, default on')
glue = source.split('// MARK: - Device glue', 1)[1]
# Every path to the program goes through the focus decision.
check('keys.wanted(focused: keyboardFocused)' in glue and 'keys.press(vk, focused: keyboardFocused)' in glue,
      'keys reach the program only with keyboard focus')
check('if r == .relative { postMotion(dx, -dy) }' in glue, 'GCMouse motion is posted only on the relative route')
check('let blocked = route == .blocked' in glue, 'the wheel is gated on focus')
check('let allowed = baseFocused ? want : []' in glue, 'UIKit pointer buttons are gated on focus')
check('guard let p = profile, HardwareInput.shared.baseFocused, !GamepadInput.shared.keyboardMouseOn else { return }' in glue,
      'the right-stick mouse is gated on focus, and stands down in keyboard-and-mouse controller mode')
check('presentedViewController != nil' in glue and 'fr is UIKeyInput' in glue
      and 'UIApplication.shared.applicationState == .active' in glue,
      'focus accounts for presented controllers, other text inputs and the app state')
check('GCController' not in source.split('final class PadStickMouse', 1)[0].split('// MARK: - Device glue', 1)[1]
      .replace('GCControllerButtonInput', '').replace('GCControllerDirectionPad', ''),
      'only PadStickMouse may touch controllers; GamepadInput owns them')
docs = (root / 'docs/KEYBOARD_MOUSE.md').read_text()
for name in switches + ('MADEIRA_NAV_KEYS_E0', 'sensMouse', 'padRightStickMouse', 'ignoreTouchesWithMouse',
                        'Ctrl+Alt+P'):
    check(name in docs, f'docs/KEYBOARD_MOUSE.md mentions {name}')
print('PASS: driver reports, touch interception, focus gating, text-bridge guard, settings, Info.plist, '
      'project, switches and docs wired')

if failures:
    for f in failures:
        print('FAIL:', f)
    sys.exit(1)
