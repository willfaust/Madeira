#!/usr/bin/env python3
"""Exercise the production touch-control layout store without an iOS SDK.

Part A compiles the Foundation-only blocks (ControlAction/TouchControl from
ContentView.swift, the pure touch state from TouchGamepad.swift and the pure
preset state from TouchControlPresets.swift) on the host: the built-in
controller layout on phone and tablet screens, built-ins read-only, "Custom
Layout N" naming, encode/decode and what loading a layout puts on screen.

Part B checks the UI wiring in the same files: kill switches, the write-back
on the end of an edit, the default for new users only, and the session slot.
Set SWIFTC if Swift is not on PATH.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
content = (app / 'ContentView.swift').read_text()
touch = (app / 'TouchGamepad.swift').read_text()
presets = (app / 'TouchControlPresets.swift').read_text()

# ---------------------------------------------------------------- Part A
actions = content[content.index('enum ControlAction: Codable'):content.index('final class TouchControlsModel')]
pure_touch = touch.split('// MARK: - Pure touch state', 1)[1].split('// MARK: - UIKit touch lifetime', 1)[0]
pure_touch = pure_touch[pure_touch.index('struct GamepadSample'):]
pure = presets.split('// MARK: - Pure preset state', 1)[1].split('// MARK: - Persistence', 1)[0]
pure = pure[pure.index('struct ControlPreset'):]
for block in (actions, pure):
    assert 'SwiftUI' not in block and 'UIKit' not in block, 'the layout core stays Foundation-only'

tests = r'''
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}

let screens: [(String, ControlPresetScreen)] = [
    ("6.3in phone", ControlPresetScreen(width: 874, height: 402, left: 59, right: 59, top: 0, bottom: 21)),
    ("6.1in phone", ControlPresetScreen(width: 844, height: 390, left: 47, right: 47, top: 0, bottom: 21)),
    ("6.9in phone", ControlPresetScreen(width: 956, height: 440, left: 62, right: 62, top: 0, bottom: 21)),
    ("4.7in phone", ControlPresetScreen(width: 667, height: 375)),
    ("insets unreported", ControlPresetScreen(width: 874, height: 402)),
    ("11in tablet", ControlPresetScreen(width: 1194, height: 834, top: 24, bottom: 20)),
    ("13in tablet", ControlPresetScreen(width: 1366, height: 1024, top: 24, bottom: 20)),
    ("mini tablet", ControlPresetScreen(width: 1133, height: 744, top: 24, bottom: 20)),
    ("phone, portrait", ControlPresetScreen(width: 402, height: 874, left: 0, right: 0, top: 62, bottom: 34)),
]
let expected = ["LS", "RS", "D↑", "D↓", "D←", "D→", "A", "B", "X", "Y",
                "LB", "RB", "LT", "RT", "View", "Menu", "L3", "R3"]
func find(_ cs: [TouchControl], _ name: String) -> TouchControl { cs.first { $0.action == .pad(name) }! }

// --- Built-in controller layout: complete, mapped, on screen, non-overlapping.
for (label, screen) in screens {
    let s = screen.landscape
    let cs = ControlPresetLayout.xbox(for: screen)
    let names = cs.compactMap { $0.action.padName }
    require(cs.count == expected.count && expected.allSatisfy { n in names.filter { $0 == n }.count == 1 },
            "\(label): sticks, D-pad, ABXY, bumpers, triggers, View/Menu, L3/R3 once each")
    require(names.allSatisfy(TouchPadAction.supported), "\(label): every control is a supported XInput mapping")
    require(cs.allSatisfy { $0.scale >= 0.5 && $0.scale <= 3.0 }, "\(label): scales inside the pinch clamp")
    require(cs.allSatisfy { $0.nx >= 0.03 && $0.nx <= 0.97 && $0.ny >= 0.03 && $0.ny <= 0.97 },
            "\(label): positions inside the editor's drag clamp")
    let m = ControlPresetLayout.margins(s)
    let safe = CGRect(x: m.left, y: m.top, width: s.width - m.left - m.right, height: s.height - m.top - m.bottom)
    let boxes = cs.map { ControlPresetLayout.box($0, screen: s) }
    require(boxes.allSatisfy { safe.contains($0) }, "\(label): every control inside the safe area")
    var overlaps: [String] = []
    for i in cs.indices { for j in cs.indices where j > i {
        let a = boxes[i], b = boxes[j]
        let dx = a.midX - b.midX, dy = a.midY - b.midY
        if (dx * dx + dy * dy).squareRoot() < a.width / 2 + b.width / 2 + 2 {
            overlaps.append("\(cs[i].action.label)/\(cs[j].action.label)")
        }
    } }
    require(overlaps.isEmpty, "\(label): no two controls overlap \(overlaps)")
    let bar = ControlPresetLayout.topBarRect(s)
    require(!boxes.contains { $0.intersects(bar) }, "\(label): the overlay's top buttons stay free")
    let l = find(cs, "LS"), r = find(cs, "RS"), up = find(cs, "D↑"), down = find(cs, "D↓")
    let left = find(cs, "D←"), right = find(cs, "D→")
    let a = find(cs, "A"), b = find(cs, "B"), x = find(cs, "X"), y = find(cs, "Y")
    let lt = find(cs, "LT"), lb = find(cs, "LB"), rt = find(cs, "RT"), rb = find(cs, "RB")
    let view = find(cs, "View"), menu = find(cs, "Menu")
    require(l.nx < 0.3 && l.ny > 0.6 && r.nx > 0.7 && r.ny > 0.6, "\(label): sticks in the bottom corners")
    require(down.ny < l.ny && up.ny < down.ny && left.nx < up.nx && up.nx < right.nx && abs(up.nx - down.nx) < 1e-9,
            "\(label): D-pad cross above the left stick")
    require(y.ny < x.ny && x.ny == b.ny && b.ny < a.ny && x.nx < y.nx && y.nx < b.nx && abs(y.nx - a.nx) < 1e-9
            && a.ny < r.ny && a.nx > 0.5, "\(label): Y top, X left, B right, A bottom, above the right stick")
    require(lt.ny < 0.2 && lt.ny == lb.ny && lt.nx < lb.nx && lb.nx < 0.5 && rb.nx < rt.nx && rb.nx > 0.5,
            "\(label): shoulder rows in the top corners, triggers outermost")
    require(view.nx < 0.5 && menu.nx > 0.5 && abs(view.ny - menu.ny) < 1e-9, "\(label): View left of Menu, centre")
}
let ids = Set(ControlPresetLayout.xbox(for: .referencePhone).map { $0.id })
require(ids.count == expected.count, "built-in controls have distinct ids")

// --- Encode / decode round trip.
var store = ControlPresetStore()
var custom = TouchControl()
custom.nx = 0.2; custom.ny = 0.7; custom.scale = 1.4; custom.action = .key(0x20)
var stick = TouchControl(); stick.action = .pad("LS")
let layout = [custom, stick] + ControlPresetLayout.xbox(for: .referencePhone)
var n = 0
let fixedID: () -> String = { n += 1; return "user-\(n)" }
require(store.save(name: "  Racing  ", controls: layout, newID: fixedID) == .created("user-1"), "save creates")
require(store.save(name: "Shooter", controls: [custom], newID: fixedID) == .created("user-2"), "second layout")
require(store.preset("user-1")?.name == "Racing", "names are trimmed")
let data = try! store.encoded()
let back = try! ControlPresetStore.decoded(data)
require(back == store && back.user.count == 2, "user layouts round-trip through JSON")
require(back.preset("user-1")?.controls == layout, "keyboard and controller actions survive")
let text = String(decoding: data, as: UTF8.self)
require(!text.contains(ControlPresetLayout.xboxID), "built-ins are never written to the file")
let future = #"{"version":2,"presets":[]}"#
require((try? ControlPresetStore.decoded(Data(future.utf8))) == nil, "a newer file version is refused, not misread")
let smuggled = try! ControlPresetStore.decoded(Data(#"{"version":1,"presets":[{"id":"builtin.xbox","name":"X","controls":[]}]}"#.utf8))
require(smuggled.user.isEmpty && smuggled.preset(ControlPresetLayout.xboxID)?.controls.count == expected.count,
        "a file entry cannot shadow a built-in")
let saved = #"{"version":1,"presets":[{"id":"p","name":"Old","controls":[{"id":"6F1B5E2A-1C1D-4B7E-9C84-0A0B0C0D0E0F","nx":0.5,"ny":0.5,"scale":1,"action":{"pad":{"_0":"A"}}}]}]}"#
require((try? ControlPresetStore.decoded(Data(saved.utf8)))?.preset("p")?.controls.first?.action == .pad("A"),
        "a stored controller mapping decodes by name")

// --- Built-ins are read-only; naming.
let xbox = ControlPresetLayout.xboxID
require(ControlPresetStore.isBuiltIn(xbox) && store.all.first?.id == xbox, "the controller layout is built in and listed first")
require(!store.delete(id: xbox) && !store.overwrite(id: xbox, controls: []), "built-in not deletable or writable")
require(store.save(name: "xbox CONTROLLER ", controls: [], newID: fixedID) == .refusedBuiltIn, "a built-in's name is refused")
require(store.save(name: "   ", controls: [], newID: fixedID) == .refusedEmpty, "an empty name is refused")
require(store.save(name: "racing", controls: [custom], newID: fixedID) == .replaced("user-1")
        && store.preset("user-1")?.controls == [custom], "saving under a user layout's name replaces it")
require(store.overwrite(id: "user-2", controls: layout) && store.preset("user-2")?.controls == layout, "overwrite a user layout")
require(store.nextCustomName() == "Custom Layout 1", "first custom name")
_ = store.save(name: "Custom Layout 1", controls: [], newID: fixedID)
_ = store.save(name: "custom layout 3", controls: [], newID: fixedID)
require(store.nextCustomName() == "Custom Layout 2", "the lowest free number, case-insensitive")
_ = store.save(name: "Custom Layout 2", controls: [], newID: fixedID)
require(store.nextCustomName() == "Custom Layout 4", "numbers already taken are skipped")
require(store.delete(id: "user-2") && store.preset("user-2") == nil && !store.delete(id: "user-2"), "delete once")
require(ControlPresetStore.clean(String(repeating: "x", count: 99)).count == ControlPresetStore.maxNameLength, "names are capped")

// --- What loading puts on screen.
var wild = TouchControl(); wild.nx = -1; wild.ny = 5; wild.scale = 9; wild.action = .pad("A")
let loaded = ControlPresetStore.layout(of: ControlPreset(id: "w", name: "W", controls: [wild, wild]), screen: nil)
require(loaded.count == 2 && loaded[0].id != loaded[1].id && loaded[0].id != wild.id, "fresh ids on every load")
require(loaded[0].nx == 0.03 && loaded[0].ny == 0.97 && loaded[0].scale == 3.0, "positions and scale clamped")
let tablet = ControlPresetScreen(width: 1194, height: 834, top: 24, bottom: 20)
let fitted = ControlPresetStore.layout(of: ControlPresetStore.builtIns[0], screen: tablet)
require(fitted.map { $0.action } == ControlPresetLayout.xbox(for: tablet).map { $0.action }
        && fitted.map { $0.scale } == ControlPresetLayout.xbox(for: tablet).map { $0.scale },
        "a built-in is laid out again for the screen it is loaded on")

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("PASS: built-in controller layout, layout store, naming and loading")
'''

with tempfile.TemporaryDirectory(prefix='madeira-presets-') as tmp:
    src, exe = Path(tmp) / 'main.swift', Path(tmp) / 'check'
    src.write_text('import Foundation\n' + actions + pure_touch + pure + tests)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)

# ---------------------------------------------------------------- Part B
def function(source, start):
    i = source.index(start); b = source.index('{', i); depth = 1; k = b + 1
    while depth:
        depth += (source[k] == '{') - (source[k] == '}'); k += 1
    return source[i:k]

gamepad = (app / 'GamepadInput.swift').read_text()
for flag, where in (('MADEIRA_CONTROL_PRESETS', presets), ('MADEIRA_CONTROLS_XBOX_DEFAULT', presets),
                    ('MADEIRA_CONTROLS_EDITOR_DONE', content), ('MADEIRA_PAD_EARLY_SLOT', gamepad)):
    assert f'.flag("{flag}")' in where, flag + ' is a kill switch'
assert '!= "0"' in function(gamepad, 'static func flag('), 'only "0" disables'

model = content[content.index('final class TouchControlsModel'):content.index('/// Click-through EXCEPT')]
assert 'if oldValue && !editing { ControlPresetsModel.shared.editingEnded(baseline: editBaseline) }' in model
assert 'needsDefaultLayout = !FileManager.default.fileExists(atPath: Self.url.path)' in model, 'default only without a file'
assert 'var layout: String?' in model, 'older controls files still decode'
ended = function(presets, 'func editingEnded(baseline: [TouchControl]) {')
assert ended.index('guard Self.enabled else { return }') < ended.index('s.overwrite(id: id'), 'write-back is switchable'
default = function(presets, 'func applyDefaultIfNeeded(screen: ControlPresetScreen) {')
assert 'm.controls.isEmpty' in default and 'm.needsDefaultLayout = false' in default, 'applied once, never over controls'
assert 'Self.touchPad' in function(presets, 'var defaultPending: Bool {'), 'no controller default without touch XInput'
overlay = function(content, 'struct TouchControlsOverlay: View {')
assert 'ControlPresetsModel.enabled && m.visible && !m.editing' in overlay, 'menu only while touch controls are shown'
assert 'if m.editing && Self.editorDone {' in overlay and 'Text("Done")' in overlay
assert 'TouchControlsOverlay.showsLayoutMenu(self) ? 3 : 2' in model, 'the menu button is hit-testable'
window = function(content, 'final class ControlsWindow: UIWindow {')
assert window.index('if m.editing {') < window.index('!hit.isDescendant(of: root)') \
    < window.index('guard m.hitsInteractive('), 'menu and dialog presentations take their touches in play mode'
reserve = function(gamepad, '@MainActor func reserveSessionSlot(touchControls: Bool) {')
assert reserve.index('guard Self.enabled, Self.flag("MADEIRA_PAD_EARLY_SLOT")') < reserve.index('touchState.reserved = true')
run = function(content, 'private func runWineFullSequence() {')
assert run.index('GamepadInput.shared.reserveSessionSlot(') < run.index('DispatchQueue.global'), 'reserved before Wine starts'
print('PASS: switches, edit write-back, new-user default, layout menu and session slot wiring')
