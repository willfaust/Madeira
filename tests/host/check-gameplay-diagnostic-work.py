#!/usr/bin/env python3
"""Execute production ProMotion tick/refresh and HUD sample gates against host stubs.

No UIKit, game, GPU or device runs. Counts work, not CPU time, temperature or FPS.
Pass --revision REV to check the same expectations against an older source tree.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--revision')
args = parser.parse_args()

def source(path):
    if args.revision:
        return subprocess.check_output(['git', 'show', f'{args.revision}:{path}'], cwd=root, text=True)
    return (root / path).read_text()

def method(text, signature):
    start = text.index(signature)
    end = text.index('\n    }', start) + len('\n    }')
    return text[start:end]

fps = source('app/Madeira/FPSOverlay.swift')
lib = source('app/Madeira/Library.swift')
tick = method(fps, '@objc private func tick(').replace('@objc private ', '')
if 'private func refreshKick(' in fps:
    config = fps[fps.index('    private var kickEnabled ='):fps.index('    /// ml2021: env.MADEIRA_DISPLAY_SYNC')]
    arm = method(fps, '    func setActive(')
    reset = next(line.strip().split('//')[0] for line in arm.splitlines() if 'nextKickCheck = 0' in line)
else:
    config = 'static var kickEnabled: Bool { MadeiraConfig.flag("MADEIRA_PROMOTE_KICK", fallback: false) }'
    reset = ''

# Run the actual RAM/battery sampling block, with task_info and UIDevice stubs.
start = lib.index('                // 0.1% needs more frames:')
start = lib.index('\n', lib.index('if model.overlayFields.contains("Frame time")', start)) + 1
end = lib.index('                let state = ProcessInfo.processInfo.thermalState', start)
sample = lib[start:end]
monitor = 'UIDevice.current.isBatteryMonitoringEnabled = model.overlayFields.contains("Battery") || DeviceLoadDiagnostics.isActive'


harness = r'''
import Foundation
func precondition(_ ok: Bool, _ message: String = "work budget exceeded") {
    if !ok { print("FAIL: \(message)"); exit(1) }
}
typealias CFTimeInterval = Double
class CADisplayLink {
    var timestamp = 0.0
    var targetTimestamp: Double { timestamp + 1 / 120.0 }
}
enum MadeiraConfig {
    static var reads = 0
    static var enabled = false
    static func flag(_ name: String, fallback: Bool) -> Bool { reads += 1; return enabled }
}
class LogStore {
    static let shared = LogStore()
    func log(_ message: String) {}
}
class ProMotionIntent {
    var armedAt = 0.0, tickStart = 0.0, tickLast = 0.0, tickMaxGap = 0.0
    var tickCount = 0, kicks = 0
    func applyDisplaySync(now: Double) {}
    func kick() { kicks += 1 }
''' + config + '\n' + tick + '\n func rearm() { ' + reset + r''' }
}
for hz in [60, 120] {
    let intent = ProMotionIntent(), link = CADisplayLink()
    MadeiraConfig.reads = 0; MadeiraConfig.enabled = false
    for frame in 0..<(hz * 60) {
        link.timestamp = 100 + Double(frame) / Double(hz)
        intent.tick(link)
    }
    print("\(hz) Hz / 60 seconds: \(MadeiraConfig.reads) config reads, \(intent.kicks) kicks")
    precondition(MadeiraConfig.reads <= 60 && intent.kicks == 0)
    // Per-game environment arrives after arming; live file edits use the same refresh.
    MadeiraConfig.enabled = true
    for frame in 0...hz {
        link.timestamp = 160 + Double(frame) / Double(hz)
        intent.tick(link)
    }
    precondition(intent.kicks > 0, "late game config picked up within a second")
    let before = intent.kicks
    for frame in 1...hz {
        link.timestamp = 161 + Double(frame) / Double(hz)
        intent.tick(link)
    }
    precondition(intent.kicks - before == hz, "enabled kick cadence stays one per tick")
    MadeiraConfig.enabled = false
    for frame in 1...(hz + 1) {
        link.timestamp = 162 + Double(frame) / Double(hz)
        intent.tick(link)
    }
    let stopped = intent.kicks
    link.timestamp += 0.001
    intent.tick(link)
    precondition(intent.kicks == stopped, "live disable picked up within a second")
    MadeiraConfig.enabled = true
    intent.rearm()
    link.timestamp += 0.001
    intent.tick(link)
    precondition(intent.kicks == stopped + 1, "rearming discards disabled diagnostic state")
}
var memoryCalls = 0, batteryReads = 0
struct task_vm_info_data_t { var phys_footprint: UInt64 = 1048576 }
typealias mach_msg_type_number_t = UInt32
typealias natural_t = UInt32
typealias integer_t = Int32
typealias task_flavor_t = Int32
let TASK_VM_INFO = 22, KERN_SUCCESS = 0
let mach_task_self_: UInt32 = 1
func task_info(_ task: UInt32, _ flavor: Int32, _ info: UnsafeMutablePointer<Int32>, _ size: inout UInt32) -> Int {
    memoryCalls += 1; return 0
}
enum DeviceLoadDiagnostics { static var isActive = false }
class UIDevice {
    static let current = UIDevice()
    var isBatteryMonitoringEnabled = false
    var batteryLevel: Float { batteryReads += 1; return 0.75 }
}
struct Model { var overlayFields: [String] }
func sampleHUD(_ fields: [String]) -> (Int, Int) {
    let model = Model(overlayFields: fields)
    var memory = 0, battery = -1
''' + sample + r'''
    return (memory, battery)
}
for _ in 0..<120 { _ = sampleHUD(["FPS"]) }
precondition(memoryCalls == 0 && batteryReads == 0, "unused metrics do no sampling")
let shown = sampleHUD(["RAM", "Battery"])
precondition(memoryCalls == 1 && batteryReads == 1 && shown.0 == 1 && shown.1 == 75)
_ = sampleHUD(["FPS"])
precondition(memoryCalls == 1 && batteryReads == 1, "deselecting fields stops sampling")
print("HUD: 120 FPS-only samples: 0 task_info, 0 battery reads; selected fields: 1 each")
''' + '\nfunc applyMonitoring(_ fields: [String]) { let model = Model(overlayFields: fields); ' + monitor + r''' }
for active in [false, true] {
    DeviceLoadDiagnostics.isActive = active
    applyMonitoring([])
    precondition(UIDevice.current.isBatteryMonitoringEnabled == active)
    applyMonitoring(["Battery"])
    precondition(UIDevice.current.isBatteryMonitoringEnabled)
    applyMonitoring([])
    precondition(UIDevice.current.isBatteryMonitoringEnabled == active)
}
print("HUD monitoring: preserves active device diagnostics on appearance/field changes")
'''

# A private task directory also owns compiler caches and subprocess temporaries.
base = Path.home() / 'tmp'
base.mkdir(mode=0o700, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='pi-gameplay-check.', dir=base) as tmp:
    env = dict(os.environ, TMPDIR=tmp, TMP=tmp, TEMP=tmp)
    swift = Path(tmp) / 'main.swift'
    swift.write_text(harness)
    exe = Path(tmp) / 'check'
    subprocess.run(['swiftc', str(swift), '-o', str(exe)], env=env, check=True)
    subprocess.run([str(exe)], env=env, check=True)
assert lib.count(monitor) == 2, 'battery monitoring updates on appear and selection changes'
print('PASS: production gameplay diagnostic work and selected HUD samples')
