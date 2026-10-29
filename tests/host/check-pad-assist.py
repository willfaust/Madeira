#!/usr/bin/env python3
"""Exercise gyro aim and turbo (app/Madeira/PadAssist.swift) without an iOS SDK.

Compiles the production pure section with swiftc: settings decoding, the gyro
to stick mapping (noise floor, sensitivity, anti-dead zone, inversion), the
controller and device axis frames, and turbo's press timing.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/PadAssist.swift').read_text()
pure = source.split('// MARK: - Pure pad assist', 1)[1].split('// MARK: - Sensors', 1)[0]
tests = r'''
func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }
let ms: UInt64 = 1_000_000

// Settings: older or partial files decode with defaults; an unknown choice falls back.
let decoder = JSONDecoder()
let empty = try! decoder.decode(PadAssistSettings.self, from: Data("{}".utf8))
assert(empty == PadAssistSettings() && empty.isOff && empty.sensitivity == 1 && empty.antiDeadzone == 0.25 && empty.turboRate == 10)
let partial = try! decoder.decode(PadAssistSettings.self, from: Data(#"{"gyro":true,"when":"LT","source":"sideways","turbo":["A","RT"]}"#.utf8))
assert(partial.gyro && partial.when == .lt && partial.source == .auto && !partial.isOff)
assert(partial.turboMask == 0x1000)
var full = PadAssistSettings()
full.gyro = true; full.source = .device; full.turn = .roll; full.sensitivity = 2; full.invertY = true; full.turbo = ["X", "LB"]
let again = try! decoder.decode(PadAssistSettings.self, from: try! JSONEncoder().encode(full))
assert(again == full && again.turboMask == 0x4100)

// Gyro to stick.
var s = PadAssistSettings()
s.gyro = true; s.antiDeadzone = 0
let still = GyroAim.stick(turn: 1.5, pitch: 1, settings: s)
assert(still.x == 0 && still.y == 0)                       // under the noise floor
var move = GyroAim.stick(turn: 150, pitch: 0, settings: s)
assert(near(move.x, 1) && near(move.y, 0))                 // full scale at sensitivity 1
move = GyroAim.stick(turn: 75, pitch: 0, settings: s)
assert(near(move.x, 0.5))
move = GyroAim.stick(turn: 600, pitch: 0, settings: s)
assert(near(move.x, 1))                                     // clamped
s.antiDeadzone = 0.25
move = GyroAim.stick(turn: 75, pitch: 0, settings: s)
assert(near(move.x, 0.625))                                 // 0.25 + 0.75 * 0.5
move = GyroAim.stick(turn: 0, pitch: 3, settings: s)
assert(move.y > 0.25 && move.y < 0.27 && move.x == 0)       // slow aim clears the game's dead zone
s.antiDeadzone = 0; s.sensitivity = 2; s.invertX = true; s.invertY = true
move = GyroAim.stick(turn: 30, pitch: -30, settings: s)
assert(near(move.x, -0.4) && near(move.y, 0.4))
s.sensitivity = 100
move = GyroAim.stick(turn: 15, pitch: 0, settings: s)
assert(near(move.x, -0.4))                                  // sensitivity capped at 4
assert(GyroAim.stick(turn: .nan, pitch: 0, settings: s).x == 0)

// Gyro to mouse: 8 pixels a degree at sensitivity 1, down is positive.
var m = PadAssistSettings()
var px = GyroAim.mouse(turn: 100, pitch: 50, dt: 0.01, settings: m)
assert(near(px.dx, 8) && near(px.dy, -4))
let quiet = GyroAim.mouse(turn: 1, pitch: 1, dt: 0.01, settings: m)
assert(quiet.dx == 0 && quiet.dy == 0)                     // under the noise floor
m.sensitivity = 2; m.invertY = true; m.antiDeadzone = 0.5
px = GyroAim.mouse(turn: -100, pitch: 50, dt: 0.01, settings: m)
assert(near(px.dx, -16) && near(px.dy, 8))                 // no anti-dead zone on the mouse
assert(GyroAim.mouse(turn: 100, pitch: 0, dt: 0, settings: m).dx == 0)
let output = try! decoder.decode(PadAssistSettings.self, from: Data(#"{"gyro":true,"output":"mouse"}"#.utf8))
assert(output.output == .mouse && PadAssistSettings().output == .auto)

assert(GyroAim.add(1, to: 0) == 32767 && GyroAim.add(-1, to: 0) == -32768)
assert(GyroAim.add(0.5, to: 32767) == 32767 && GyroAim.add(-2, to: 1000) == -32768)
assert(GyroAim.add(0, to: -12345) == -12345 && GyroAim.add(0, to: 23456) == 23456)
assert(GyroAim.add(0.5, to: -16384) == 0)

// Axis frames, in degrees a second (1 rad/s = 57.2958).
let d = 180 / Double.pi
var r = GyroAim.controllerRates(x: 0, y: 0, z: 1, turn: .yaw)
assert(near(r.turn, -d) && r.pitch == 0)                   // twisting left turns left
r = GyroAim.controllerRates(x: 1, y: 2, z: 3, turn: .roll)
assert(near(r.turn, 2 * d) && near(r.pitch, d))
r = GyroAim.deviceRates(x: 1, y: 0, z: 0, orientation: 1, turn: .yaw)
assert(r.turn == 0 && near(r.pitch, d))                    // portrait: x is the horizontal axis
r = GyroAim.deviceRates(x: 1, y: 0, z: 0, orientation: 3, turn: .yaw)
assert(near(r.turn, -d) && r.pitch == 0)                   // landscape right: x is vertical
r = GyroAim.deviceRates(x: 1, y: 1, z: 0, orientation: 4, turn: .yaw)
assert(near(r.turn, d) && near(r.pitch, d))
r = GyroAim.deviceRates(x: 0, y: 0, z: 1, orientation: 3, turn: .roll)
assert(near(r.turn, -d))

// When gyro is held.
var pad = AssistPad()
assert(GyroAim.held(pad, .always) && !GyroAim.held(pad, .lt))
pad.lt = 26; assert(GyroAim.held(pad, .lt))
pad.buttons = 0x0100; assert(GyroAim.held(pad, .lb) && !GyroAim.held(pad, .rb))

// Turbo at 10 a second: 50 ms pressed, 50 ms released, starting pressed.
assert(TurboState.on(elapsed: 0, rate: 10) && TurboState.on(elapsed: 49 * ms, rate: 10))
assert(!TurboState.on(elapsed: 50 * ms, rate: 10) && TurboState.on(elapsed: 100 * ms, rate: 10))
assert(!TurboState.on(elapsed: 17 * ms, rate: 100))         // capped at 30 a second
var turbo = TurboState()
let t0: UInt64 = 5_000 * ms
pad = AssistPad(buttons: 0x1000 | 0x2000, rt: 255)
var out = pad
turbo.apply(&out, mask: 0x1000, lt: false, rt: true, rate: 10, now: t0)
assert(out.buttons == 0x3000 && out.rt == 255)              // the first press is immediate
out = pad
turbo.apply(&out, mask: 0x1000, lt: false, rt: true, rate: 10, now: t0 + 60 * ms)
assert(out.buttons == 0x2000 && out.rt == 0)                // B is not a turbo button
out = pad
turbo.apply(&out, mask: 0x1000, lt: false, rt: true, rate: 10, now: t0 + 110 * ms)
assert(out.buttons == 0x3000 && out.rt == 255)
out = AssistPad()
turbo.apply(&out, mask: 0x1000, lt: false, rt: true, rate: 10, now: t0 + 160 * ms)
assert(out == AssistPad())                                  // let go
out = pad
turbo.apply(&out, mask: 0x1000, lt: false, rt: true, rate: 10, now: t0 + 175 * ms)
assert(out.buttons == 0x3000 && out.rt == 255)              // a new press starts pressed
out = AssistPad(rt: 20)
turbo.apply(&out, mask: 0, lt: false, rt: true, rate: 10, now: t0 + 230 * ms)
assert(out.rt == 20)                                        // a light touch is not a press

// Together: gyro held on LT keeps moving while LT's turbo pulses it off.
var both = PadAssistSettings()
both.gyro = true; both.when = .lt; both.antiDeadzone = 0; both.turbo = ["LT"]
var state = TurboState()
pad = AssistPad(lt: 255, rx: 0, ry: 0)
out = pad
applyPadAssist(&out, settings: both, rates: (turn: 75, pitch: 0), turbo: &state, now: t0)
assert(out.lt == 255 && out.rx == 16384)
out = pad
applyPadAssist(&out, settings: both, rates: (turn: 75, pitch: 0), turbo: &state, now: t0 + 60 * ms)
assert(out.lt == 0 && out.rx == 16384)
out = AssistPad(ry: 1000)
applyPadAssist(&out, settings: both, rates: (turn: 75, pitch: 0), turbo: &state, now: t0 + 70 * ms)
assert(out.rx == 0 && out.ry == 1000)                       // LT not held: the stick alone
both.gyro = false
out = pad
applyPadAssist(&out, settings: both, rates: (turn: 75, pitch: 0), turbo: &state, now: t0 + 80 * ms)
assert(out.rx == 0)
print("PASS: settings decoding, gyro stick mapping and axis frames, turbo timing, gyro mouse")
'''
with tempfile.TemporaryDirectory(prefix='madeira-pad-assist-') as tmp:
    src, exe = Path(tmp) / 'main.swift', Path(tmp) / 'check'
    src.write_text('import Foundation\n' + pure + tests)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
