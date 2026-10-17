import Foundation
import SwiftUI
import UIKit

// ============================================================================
// ml1530/ml1970 — NAMED TOUCH-CONTROL LAYOUTS.
//
// A layout is the landscape editor's `TouchControlsModel.controls`. The user's
// own layouts ("Custom Layout 1", "Custom Layout 2", ...) are kept app-wide in
// Documents/madeira-control-presets.json, beside madeira-controls.json, so a
// device backup carries them. Built-ins ship in code and can be loaded but
// never changed: there is one, a full XInput layout named "Xbox controller".
//
// madeira-controls.json stays the working copy the overlay draws; it records
// which layout it was loaded from (`TouchControlsModel.layoutID`) so edits made
// in the editor are written back to that custom layout when editing ends.
//
// The layout menu is offered in two places: the landscape overlay's top bar
// (`ControlLayoutMenu`) and, in a library session, where LibraryHUD replaces
// that bar, as a "Controller layout" row of the in-game Session menu (the same
// view, `.row` style). A library game remembers its layout (`LibraryEntry.
// controlLayout`); other games and the overlay outside the library keep the
// one shared working copy.
//
// Switches (Documents/madeira.cfg `env.NAME = value`, or the environment):
//   MADEIRA_CONTROL_PRESETS=0        no layout menu, no write-back (default on)
//   MADEIRA_CONTROLS_XBOX_DEFAULT=1  a user with no controls file gets the
//                                    built-in once (default OFF: otherwise the
//                                    built-in is only applied from the menu)
// ============================================================================

// MARK: - Pure preset state (also compiled by the host regression test)

struct ControlPreset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var controls: [TouchControl]
    /// Gesture zones (GestureZones.swift). Optional, so layouts saved before
    /// zones existed still decode; nil reads as none.
    var zones: [GestureZone]? = nil
}

enum GestureZoneKind: String, Codable, CaseIterable {
    case stick, swipe, look
    var title: String { switch self { case .stick: "Stick"; case .swipe: "Swipe"; case .look: "Look" } }
}

enum SwipeDirections: String, Codable, CaseIterable {
    case four, horizontal, vertical
    var title: String { switch self { case .four: "All"; case .horizontal: "Left/Right"; case .vertical: "Up/Down" } }
}

struct GestureZone: Codable, Identifiable, Equatable {
    static let directionNames = ["up", "down", "left", "right"]

    var id = UUID()
    /// Top-left corner and size, as fractions of the screen.
    var x = 0.04, y = 0.3, w = 0.36, h = 0.62
    var kind: GestureZoneKind = .stick
    /// Stick zones: .pad("LS"), .pad("RS"), .joystickWASD or .joystickArrows.
    var stick: ControlAction = .pad("LS")
    /// Swipe zones: what each direction presses.
    var swipe: [String: ControlAction] = ["up": .pad("D↑"), "down": .pad("D↓"),
                                          "left": .pad("D←"), "right": .pad("D→")]
    var directions: SwipeDirections = .four
    /// Swipe zones: a tap that did not become a swipe.
    var tap: ControlAction = .none
    /// Stick: full deflection distance is 70 pt / sensitivity. Swipe: the swipe
    /// length is 36 pt / sensitivity. Look: mouse counts per point.
    var sensitivity = 1.0
    func contains(_ p: CGPoint, in size: CGSize) -> Bool { rect(in: size).contains(p) }
    /// Locked in place: the editor selects it but will not move or resize it.
    var locked: Bool?

    func rect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: w * size.width, height: h * size.height)
    }
    var feedsPad: Bool {
        switch kind {
        case .stick: return stick.isPad
        case .swipe: return tap.isPad || swipe.values.contains { $0.isPad }
        case .look: return false
        }
    }
}


/// The screen a built-in layout is placed on, in points, with its safe-area
/// insets. Built-ins are laid out in points from the edges and then normalised
/// to THIS screen, so one layout reads right on a phone and on a tablet.
struct ControlPresetScreen: Equatable {
    var width: Double
    var height: Double
    var left = 0.0, right = 0.0, top = 0.0, bottom = 0.0

    /// The overlay is landscape-only, so a portrait screen is laid out as the
    /// landscape one it rotates to: the top/bottom insets move to the sides.
    var landscape: ControlPresetScreen {
        guard height > width else { return self }
        let side = max(top, bottom)
        return ControlPresetScreen(width: height, height: width, left: side, right: side,
                                   top: 0, bottom: min(bottom, 21))
    }

    /// A 6.3-inch phone in landscape: what the stored copy of a built-in is
    /// laid out for. Loading lays it out again for the real screen.
    static let referencePhone = ControlPresetScreen(width: 874, height: 402,
                                                    left: 59, right: 59, top: 0, bottom: 21)
}

enum ControlPresetLayout {
    static let xboxID = "builtin.xbox"
    static let xboxName = "Xbox controller"
    /// Mirrors `TouchControlsModel.baseDiameter`.
    static let baseDiameter = 64.0

    /// The margins a built-in keeps from each edge, whatever the reported insets.
    static func margins(_ s: ControlPresetScreen) -> (left: Double, right: Double, top: Double, bottom: Double) {
        (max(s.left, 16), max(s.right, 16), max(s.top, 8), max(s.bottom, 8))
    }

    /// The overlay's own buttons, centred at the top (TouchControlsModel.
    /// hitsInteractive claims this band). A built-in leaves it free.
    static func topBarRect(_ s: ControlPresetScreen) -> CGRect {
        CGRect(x: s.width / 2 - 100, y: 0, width: 200, height: 76)
    }

    /// The drawn bounding box, in points: `baseDiameter` × the control's scale
    /// for a round button, the pad button's own shape otherwise (a wide
    /// shoulder, a Start/Select pill), centred on its normalised position.
    static func box(_ c: TouchControl, screen s: ControlPresetScreen) -> CGRect {
        let z = c.action.controlSize(diameter: CGFloat(baseDiameter * c.scale))
        return CGRect(x: c.nx * s.width - Double(z.width) / 2, y: c.ny * s.height - Double(z.height) / 2,
                      width: Double(z.width), height: Double(z.height))
    }

    /// The built-in controller layout, using the editor's controller mappings:
    ///
    ///   LT LB  (top left)                              (top right)  RB RT
    ///   D-pad  above the left stick        A/B/X/Y diamond above the right stick
    ///   LS (bottom left)  L3    View  Menu     R3  RS (bottom right)
    ///
    /// Placed in points from the safe-area edges, then normalised. `k` scales
    /// the whole thing up on a tall (tablet) screen, where a phone-sized stick
    /// would be lost; every scale stays inside the editor's 0.5–3.0 pinch clamp.
    static func xbox(for screen: ControlPresetScreen) -> [TouchControl] {
        let s = screen.landscape
        let W = s.width, H = s.height
        guard W > 0, H > 0 else { return [] }
        let k = min(max(H / 400, 1.0), 1.3)
        let (L, R, T, B) = margins(s)
        var out: [TouchControl] = []
        func add(_ name: String, _ scale: Double, _ x: Double, _ y: Double) {
            var c = TouchControl()
            c.action = .pad(name)
            c.scale = scale
            c.nx = x / W
            c.ny = y / H
            out.append(c)
        }
        func d(_ scale: Double) -> Double { baseDiameter * scale }
        let stickScale = 1.45 * k, faceScale = 0.78 * k, dpadScale = 0.7 * k
        let shoulderScale = 0.88 * k, systemScale = 0.75 * k, clickScale = 0.62 * k

        // Sticks: bottom corners, clear of the home indicator.
        let stick = d(stickScale)
        let stickY = H - B - 12 * k - stick / 2
        let lStickX = L + 76 * k, rStickX = W - R - 76 * k
        add("LS", stickScale, lStickX, stickY)
        add("RS", stickScale, rStickX, stickY)
        let stickTop = stickY - stick / 2

        // Shoulders: a column in each top corner, trigger above bumper as on
        // the controller. Drawn 1.6× as wide as they are tall and 0.74 d high
        // (ControlAction.controlSize), so the column is two of those plus a gap.
        let sh = d(shoulderScale), shW = sh * 1.6, shH = sh * 0.74
        let shoulderX = shW / 2 + 6 * k
        let triggerY = T + 6 * k + shH / 2
        let bumperY = triggerY + shH + 8 * k
        add("LT", shoulderScale, L + shoulderX, triggerY)
        add("LB", shoulderScale, L + shoulderX, bumperY)
        add("RB", shoulderScale, W - R - shoulderX, bumperY)
        add("RT", shoulderScale, W - R - shoulderX, triggerY)
        // The columns' bottom and inner edge, for placing the D-pad cross and
        // the face diamond below them (or, on a short screen, inboard of them).
        let rowBottom = bumperY + shH / 2
        let columnInner = shoulderX + shW / 2 + 10 * k

        // D-pad: a tight cross at the left edge, between the shoulder column
        // and the stick, so the middle of the screen stays clear. When the
        // screen is too short for that stack (a phone with a tall column), the
        // cross moves inboard of the column instead and rises beside it.
        let dp = d(dpadScale), arm = dp + 6 * k
        let stacked = rowBottom + 8 * k + 2 * arm + dp <= stickTop - 8 * k
        let dpadX = stacked ? L + 6 * k + arm + dp / 2 : L + columnInner + arm + dp / 2
        let dpadY = stacked ? rowBottom + 8 * k + arm + dp / 2
                            : max(stickTop - 22 * k - arm - dp / 2, T + 6 * k + arm + dp / 2)
        add("D↑", dpadScale, dpadX, dpadY - arm)
        add("D←", dpadScale, dpadX - arm, dpadY)
        add("D→", dpadScale, dpadX + arm, dpadY)
        add("D↓", dpadScale, dpadX, dpadY + arm)

        // A/B/X/Y: a tight diamond at the right edge, mirroring the D-pad.
        // Diagonal neighbours sit o·√2 apart, which clears one face button's
        // diameter.
        let face = d(faceScale)
        let o = face / 2 + 22 * k
        let cx = stacked ? W - R - 6 * k - o - face / 2 : W - R - columnInner - o - face / 2
        let cy = stacked ? rowBottom + 8 * k + o + face / 2
                         : max(stickTop - 22 * k - o - face / 2, T + 6 * k + o + face / 2)
        add("Y", faceScale, cx, cy - o)
        add("X", faceScale, cx - o, cy)
        add("B", faceScale, cx + o, cy)
        add("A", faceScale, cx, cy + o)

        // View / Menu: bottom centre, between the sticks.
        let sys = d(systemScale)
        let sysY = H - B - 20 * k - sys / 2
        add("View", systemScale, W / 2 - 46 * k, sysY)
        add("Menu", systemScale, W / 2 + 46 * k, sysY)

        // L3 / R3: small buttons on the inner side of each stick, level with
        // its bottom edge.
        let click = d(clickScale)
        let clickY = stickY + stick / 2 - click / 2
        add("L3", clickScale, lStickX + stick / 2 + 20 * k + click / 2, clickY)
        add("R3", clickScale, rStickX - stick / 2 - 20 * k - click / 2, clickY)
        return out
    }
}

/// The layout list: built-ins (read-only, in code), then the user's own
/// (persisted). Pure value type; `ControlPresetsModel` owns the file.
struct ControlPresetStore: Equatable {
    static let builtIns: [ControlPreset] = [
        ControlPreset(id: ControlPresetLayout.xboxID, name: ControlPresetLayout.xboxName,
                      controls: ControlPresetLayout.xbox(for: .referencePhone)),
    ]
    static let maxNameLength = 40

    private(set) var user: [ControlPreset] = []

    init(user: [ControlPreset] = []) { self.user = user.filter { !Self.isBuiltIn($0.id) } }

    var all: [ControlPreset] { Self.builtIns + user }

    static func isBuiltIn(_ id: String) -> Bool { builtIns.contains { $0.id == id } }

    func preset(_ id: String) -> ControlPreset? { all.first { $0.id == id } }

    /// The id if a layout still has it, else nil: a game's remembered layout may
    /// have been deleted since, and controls that no layout holds are unsaved.
    func resolvedID(_ id: String?) -> String? { id.flatMap { preset($0)?.id } }

    static func clean(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
    }

    /// Case-insensitive, whitespace-trimmed: "xbox controller " IS the built-in.
    func named(_ name: String) -> ControlPreset? {
        let n = Self.clean(name).lowercased()
        guard !n.isEmpty else { return nil }
        return all.first { $0.name.lowercased() == n }
    }

    /// "Custom Layout N", the lowest N not taken.
    func nextCustomName() -> String {
        var n = 1
        while named("Custom Layout \(n)") != nil { n += 1 }
        return "Custom Layout \(n)"
    }

    enum SaveResult: Equatable {
        case created(String)      // new user layout, its id
        case replaced(String)     // an existing user layout of that name, its id
        case refusedBuiltIn       // the name is a built-in's: pick another
        case refusedEmpty
    }

    /// Save a layout under a name. A built-in's name is refused (built-ins are
    /// never overwritten); a user layout's name replaces that layout in place.
    mutating func save(name: String, controls: [TouchControl], zones: [GestureZone] = [],
                       newID: () -> String = { UUID().uuidString }) -> SaveResult {
        let n = Self.clean(name)
        guard !n.isEmpty else { return .refusedEmpty }
        if let existing = named(n) {
            if Self.isBuiltIn(existing.id) { return .refusedBuiltIn }
            guard let i = user.firstIndex(where: { $0.id == existing.id }) else { return .refusedEmpty }
            user[i].controls = controls
            user[i].zones = zones.isEmpty ? nil : zones
            return .replaced(existing.id)
        }
        let id = newID()
        user.append(ControlPreset(id: id, name: n, controls: controls, zones: zones.isEmpty ? nil : zones))
        return .created(id)
    }

    /// Overwrite a user layout's controls. false for a built-in or a missing id.
    mutating func overwrite(id: String, controls: [TouchControl], zones: [GestureZone] = []) -> Bool {
        guard let i = user.firstIndex(where: { $0.id == id }) else { return false }
        user[i].controls = controls
        user[i].zones = zones.isEmpty ? nil : zones
        return true
    }

    /// false for a built-in or a missing id.
    mutating func delete(id: String) -> Bool {
        guard let i = user.firstIndex(where: { $0.id == id }) else { return false }
        user.remove(at: i)
        return true
    }

    private struct File: Codable { var version: Int; var presets: [ControlPreset] }

    /// Only the user's layouts are written; built-ins live in code.
    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(File(version: 1, presets: user))
    }

    static func decoded(_ data: Data) throws -> ControlPresetStore {
        let f = try JSONDecoder().decode(File.self, from: data)
        guard f.version == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "preset file version \(f.version)"))
        }
        return ControlPresetStore(user: f.presets)
    }

    /// What loading a layout puts on screen: its controls with FRESH ids (a
    /// control's id keys its touch state, and two loads of one layout must not
    /// share them), positions inside the editor's drag clamp, and scales inside
    /// the pinch clamp. A built-in is laid out again for the screen it is
    /// loaded on.
    static func layout(of p: ControlPreset, screen: ControlPresetScreen?) -> [TouchControl] {
        var controls = p.controls
        if p.id == ControlPresetLayout.xboxID, let screen {
            let fitted = ControlPresetLayout.xbox(for: screen)
            if !fitted.isEmpty { controls = fitted }
        }
        return controls.map { c in
            var c = c
            c.id = UUID()
            c.nx = min(max(c.nx, 0.03), 0.97)
            c.ny = min(max(c.ny, 0.03), 0.97)
            c.scale = min(max(c.scale, 0.5), 3.0)
            return c
        }
    }
}

extension ControlPresetStore {
    /// A layout's zones as loaded: fresh ids (an id keys the zone's touch
    /// state), rectangles kept on screen.
    static func zones(of p: ControlPreset) -> [GestureZone] {
        (p.zones ?? []).map { z in
            var z = z
            z.id = UUID()
            z.w = min(max(z.w, 0.06), 1); z.h = min(max(z.h, 0.08), 1)
            z.x = min(max(z.x, 0), 1 - z.w); z.y = min(max(z.y, 0), 1 - z.h)
            return z
        }
    }
}

// MARK: - Persistence and overlay actions

/// Owns madeira-control-presets.json and applies layouts to TouchControlsModel.
/// Main thread only, like the overlay that drives it.
final class ControlPresetsModel: ObservableObject {
    static let shared = ControlPresetsModel()
    static let enabled = GamepadInput.flag("MADEIRA_CONTROL_PRESETS")
    /// Opt-in. "No madeira-controls.json" is not a fresh install: the file is
    /// only written once the controls or their visibility change, so an
    /// existing user who never touched them has none either and would get an
    /// 18-button overlay they did not ask for. Nothing on disk tells the two
    /// apart reliably, so the built-in is applied automatically only on request.
    static let xboxDefault = GamepadInput.optIn("MADEIRA_CONTROLS_XBOX_DEFAULT")

    @Published private(set) var store = ControlPresetStore()
    /// A file that exists and cannot be read is left untouched: saving is
    /// refused instead of overwriting it.
    private(set) var readOnly = false
    private var logged = 0

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-control-presets.json")
    }

    private init() {
        guard let d = try? Data(contentsOf: Self.url) else { return }
        do {
            store = try ControlPresetStore.decoded(d)
        } catch {
            readOnly = true
            log("unreadable file kept, saving disabled: \(error.localizedDescription)")
        }
    }

    /// The controller built-in needs touch XInput; without it its buttons are inert.
    private static var touchPad: Bool { MainActor.assumeIsolated { GamepadInput.touchEnabled } }

    /// What the layout menu lists.
    var available: [ControlPreset] {
        (Self.touchPad ? ControlPresetStore.builtIns : []) + store.user
    }

    var active: ControlPreset? { TouchControlsModel.shared.layoutID.flatMap { store.preset($0) } }

    /// On-screen controls that no layout holds: switching away would lose them.
    var currentIsUnsaved: Bool {
        let m = TouchControlsModel.shared
        return m.layoutID == nil && (!m.controls.isEmpty || !GestureZonesModel.shared.zones.isEmpty)
    }

    /// With MADEIRA_CONTROLS_XBOX_DEFAULT=1, a user with no madeira-controls.json gets the controller layout the
    /// first time the landscape overlay appears.
    var defaultPending: Bool {
        TouchControlsModel.shared.needsDefaultLayout && Self.enabled && Self.xboxDefault && Self.touchPad
    }

    private func log(_ line: String) {
        guard logged < 64 else { return }
        logged += 1
        fputs("[controls-layout] ml1970 \(line)\n", stderr)
    }

    @discardableResult private func persist() -> Bool {
        guard !readOnly else { return false }
        do {
            try store.encoded().write(to: Self.url, options: .atomic)
            return true
        } catch {
            log("write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The landscape screen the overlay is laid out on.
    static func currentScreen() -> ControlPresetScreen {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        guard let window, window.bounds.width > 0 else { return .referencePhone }
        let i = window.safeAreaInsets
        let s = ControlPresetScreen(width: Double(window.bounds.width), height: Double(window.bounds.height),
                                    left: Double(i.left), right: Double(i.right),
                                    top: Double(i.top), bottom: Double(i.bottom))
        return s.landscape
    }

    /// Never over a layout the user already has: only when no controls file existed.
    func applyDefaultIfNeeded(screen: ControlPresetScreen) {
        let m = TouchControlsModel.shared
        guard m.needsDefaultLayout else { return }
        let apply = defaultPending && m.controls.isEmpty
        m.needsDefaultLayout = false
        guard apply else { return }
        load(ControlPresetLayout.xboxID, screen: screen, reason: "new-user-default")
    }

    /// Replace the on-screen layout with this one.
    func load(_ id: String, screen: ControlPresetScreen, reason: String = "chosen") {
        guard let p = store.preset(id) else { return }
        let m = TouchControlsModel.shared
        let controls = ControlPresetStore.layout(of: p, screen: screen)
        m.selected = nil
        m.controls = controls
        GestureZonesModel.shared.selected = nil
        GestureZonesModel.shared.zones = ControlPresetStore.zones(of: p)
        m.layoutID = p.id
        log("loaded layout=\(ControlPresetStore.isBuiltIn(p.id) ? "xbox" : "custom") controls=\(controls.count) reason=\(reason)")
    }

    /// Keep the unsaved on-screen controls as the next "Custom Layout N".
    @discardableResult func keepCurrent() -> Bool {
        guard !readOnly else { return false }
        let m = TouchControlsModel.shared
        var s = store
        guard case .created(let id) = s.save(name: s.nextCustomName(), controls: m.controls,
                                             zones: GestureZonesModel.shared.zones) else { return false }
        store = s
        m.layoutID = id
        persist()
        log("kept on-screen controls as a custom layout controls=\(m.controls.count)")
        return true
    }

    /// "Create new layout": an empty custom layout, made active, opened in the editor.
    @discardableResult func createLayout() -> Bool {
        guard !readOnly else { return false }
        var s = store
        guard case .created(let id) = s.save(name: s.nextCustomName(), controls: []) else { return false }
        store = s
        persist()
        let m = TouchControlsModel.shared
        m.selected = nil
        m.controls = []
        GestureZonesModel.shared.selected = nil
        GestureZonesModel.shared.zones = []
        m.layoutID = id
        m.visible = true
        m.editing = true
        log("created custom layout")
        return true
    }

    /// Delete a custom layout. The on-screen copy of a deleted active layout
    /// becomes the controller layout, or stays as unsaved controls without it.
    @discardableResult func delete(_ id: String) -> Bool {
        guard !readOnly else { return false }
        var s = store
        guard s.delete(id: id) else { return false }
        store = s
        persist()
        log("deleted custom layout")
        let m = TouchControlsModel.shared
        if m.layoutID == id {
            if Self.touchPad { load(ControlPresetLayout.xboxID, screen: Self.currentScreen(), reason: "deleted") }
            else { m.layoutID = nil }
        }
        return true
    }

    /// An edit session ended. Edits to a custom layout are written back to it;
    /// a built-in stays as shipped, so an edited copy of one becomes unsaved
    /// controls that the menu offers to keep before switching away.
    func editingEnded(baseline: [TouchControl], zoneBaseline: [GestureZone]) {
        guard Self.enabled else { return }
        let m = TouchControlsModel.shared
        guard let id = m.layoutID else { return }
        if ControlPresetStore.isBuiltIn(id) {
            if baseline != m.controls || zoneBaseline != GestureZonesModel.shared.zones {
                m.layoutID = nil
                log("edited built-in kept as unsaved controls=\(m.controls.count)")
            }
            return
        }
        var s = store
        guard !readOnly, s.overwrite(id: id, controls: m.controls, zones: GestureZonesModel.shared.zones) else { return }
        store = s
        persist()
        log("saved custom layout controls=\(m.controls.count)")
    }
}

// MARK: - Layout menu (landscape overlay, library session menu)

/// The layout menu: the controller built-in, the user's custom layouts,
/// "Create new layout" (opens the editor on an empty layout) and deleting the
/// active custom layout. Shown only while touch controls are on. `.glass` is
/// the overlay's round top-bar button; `.row` is a labelled row of the library
/// session's Session menu.
struct ControlLayoutMenu: View {
    enum Style { case glass, row }

    @ObservedObject private var presets = ControlPresetsModel.shared
    @ObservedObject private var m = TouchControlsModel.shared
    private let style: Style
    /// Called after a layout was loaded, created or deleted, with true when the
    /// editor was opened (a library session saves the game's profile, and closes
    /// its menu to show the editor).
    private let didChoose: ((_ openedEditor: Bool) -> Void)?

    init(style: Style = .glass, didChoose: ((_ openedEditor: Bool) -> Void)? = nil) {
        self.style = style
        self.didChoose = didChoose
    }

    private enum Choice: Equatable { case load(String), create }
    @State private var pending: Choice?
    @State private var confirmDelete: ControlPreset?

    var body: some View {
        Group {
            if style == .row {
                LabeledContent("Controller layout") { menu }
            } else {
                menu
            }
        }
        .alert("Keep the current controls?", isPresented: shown($pending)) {
            if !presets.readOnly {
                Button("Keep as \u{201C}\(presets.store.nextCustomName())\u{201D}") {
                    let choice = pending
                    pending = nil
                    presets.keepCurrent()
                    perform(choice)
                }
            }
            Button("Replace", role: .destructive) {
                let choice = pending
                pending = nil
                perform(choice)
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("The controls on screen are not saved in a layout.")
        }
        .alert("Delete \u{201C}\(confirmDelete?.name ?? "")\u{201D}?", isPresented: shown($confirmDelete)) {
            Button("Delete", role: .destructive) {
                if let p = confirmDelete, presets.delete(p.id) { didChoose?(false) }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
    }

    private var menu: some View {
        Menu {
            Section("Controller layout") {
                ForEach(presets.available) { p in
                    Button { request(.load(p.id)) } label: {
                        if m.layoutID == p.id { Label(p.name, systemImage: "checkmark") }
                        else if ControlPresetStore.isBuiltIn(p.id) { Label(p.name, systemImage: "gamecontroller") }
                        else { Text(p.name) }
                    }
                }
            }
            if !presets.readOnly {
                Button("Create new layout", systemImage: "plus") { request(.create) }
            }
            if let a = presets.active, !ControlPresetStore.isBuiltIn(a.id), !presets.readOnly {
                Button("Delete \u{201C}\(a.name)\u{201D}", systemImage: "trash", role: .destructive) {
                    confirmDelete = a
                }
            }
        } label: {
            switch style {
            case .glass:
                // Same look as the overlay's glass buttons; stroke glyph only.
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(GlassShape(circle: true))
            case .row:
                HStack(spacing: 4) {
                    Text(presets.active?.name ?? "Custom")
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
            }
        }
        .accessibilityLabel("Controller layout")
    }

    private func shown<T>(_ b: Binding<T?>) -> Binding<Bool> {
        Binding(get: { b.wrappedValue != nil }, set: { if !$0 { b.wrappedValue = nil } })
    }

    private func request(_ choice: Choice) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if presets.currentIsUnsaved { pending = choice } else { perform(choice) }
    }

    private func perform(_ choice: Choice?) {
        switch choice {
        case .load(let id):
            presets.load(id, screen: ControlPresetsModel.currentScreen())
            didChoose?(false)
        case .create:
            if presets.createLayout() { didChoose?(true) }
        case nil: break
        }
    }
}
