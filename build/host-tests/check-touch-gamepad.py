#!/usr/bin/env python3
"""Exercise the production touch ownership/arbitration logic without an iOS SDK."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/TouchGamepad.swift').read_text()
pure = source.split('// MARK: - Pure touch state', 1)[1].split('// MARK: - UIKit touch lifetime', 1)[0]
pure = pure[pure.index('struct GamepadSample'):]
tests = r'''
let a = UUID(), b = UUID(), owner1 = UUID(), owner2 = UUID()
var state = TouchGamepadState()
assert(!state.connected)
state.configure([a, b])
assert(state.connected && state.sample == GamepadSample())
state.update(owner: owner1, control: a, value: TouchPadAction.sample("A"))
state.update(owner: owner2, control: b, value: TouchPadAction.sample("A"))
state.update(owner: owner1, control: a, value: nil)
assert(state.sample.buttons == 0x1000) // one release cannot cancel another finger
state.update(owner: owner2, control: b, value: nil)
assert(state.sample.buttons == 0)
state.update(owner: owner1, control: UUID(), value: TouchPadAction.sample("B"))
assert(state.sample.buttons == 0) // stale/removed control cannot create a hold
state.update(owner: owner1, control: a, value: TouchPadAction.sample("LT"))
state.update(owner: owner2, control: b, value: TouchPadAction.sample("RT"))
assert(state.sample.lt == 255 && state.sample.rt == 255)
state.clear() // background/cancel: neutral but virtual pad stays connected
assert(state.connected && state.sample == GamepadSample())
state.update(owner: owner1, control: a, value: TouchPadAction.sample("X"))
state.configure([]) // hidden/editing/portrait/disappeared
assert(!state.connected && state.sample == GamepadSample())
state.update(owner: owner1, control: a, value: TouchPadAction.sample("X"))
assert(state.sample == GamepadSample())
state.configure([a])
state.update(owner: owner1, control: a, value: TouchPadAction.sample("B"))
state.configure([a]) // remap preserving the same ID must release old action
assert(state.sample == GamepadSample())
let left = TouchPadAction.sample("LS", x: -1, y: 0)
let up = TouchPadAction.sample("RS", x: 0, y: 1)
assert(left.lx == -32768 && left.ly == 0)
assert(up.ry == 32767 && up.rx == 0)
let diagonal = TouchPadAction.sample("LS", x: 1, y: 1)
assert(diagonal.lx == 23170 && diagonal.ly == 23170)
assert(TouchPadAction.sample("LS", x: .nan, y: 1) == GamepadSample())
assert(GamepadSample.axis(-2) == -32768 && GamepadSample.axis(2) == 32767)
var physical = GamepadSample(buttons: 0x1000, lt: 37, lx: 1000, ly: 2000)
assert(GamepadSample.merge(physical: physical, touch: GamepadSample()) == physical)
var touch = TouchPadAction.sample("B")
touch.lt = 255; touch.rx = 10000
var combined = GamepadSample.merge(physical: physical, touch: touch)
assert(combined.buttons == 0x3000 && combined.lt == 255 && combined.rx == 10000)
assert(combined.lx == 1000 && combined.ly == 2000)
physical.lx = 20000
combined = GamepadSample.merge(physical: physical, touch: left)
assert(combined.lx == 20000) // deflected physical stick wins arbitration
physical.lx = 0; physical.ly = 0
assert(GamepadSample.merge(physical: physical, touch: left).lx == -32768)
assert(GamepadSample.merge(physical: physical, touch: GamepadSample()).buttons == 0x1000)
for (name, mask) in TouchPadAction.buttons {
    assert(TouchPadAction.supported(name) && TouchPadAction.sample(name).buttons == mask)
}
assert(!TouchPadAction.supported("unknown"))
// Multiple touches on analogue controls aggregate deterministically.
state.configure([a, b])
state.update(owner: owner1, control: a, value: left)
state.update(owner: owner2, control: b, value: TouchPadAction.sample("LS", x: 0.5))
assert(state.sample.lx == -32768)
state.update(owner: owner1, control: a, value: nil)
assert(state.sample.lx == 16384)
// ml1990: a session reservation keeps player 1 connected at rest.
var session = TouchGamepadState()
session.reserved = true
assert(session.connected && session.sample == GamepadSample())
session.configure([a])
session.update(owner: owner1, control: a, value: TouchPadAction.sample("A"))
assert(session.sample.buttons == 0x1000)
session.configure([]) // hidden/editing/portrait: holds released, slot kept
assert(session.connected && session.sample == GamepadSample())
session.update(owner: owner1, control: a, value: TouchPadAction.sample("A"))
assert(session.sample == GamepadSample())
session.clear()
assert(session.connected)
print("PASS: touch mappings, independent holds, lifecycle clearing, analogue ranges, physical merge and session slot")
'''
with tempfile.TemporaryDirectory(prefix='madeira-touch-pad-') as tmp:
    src, exe = Path(tmp) / 'main.swift', Path(tmp) / 'check'
    src.write_text('import Foundation\n' + pure + tests)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
