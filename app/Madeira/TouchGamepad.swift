import Foundation
import SwiftUI
import UIKit

// MARK: - Pure touch state (also compiled by the host regression test)
struct GamepadSample: Equatable, Sendable {
    var buttons: UInt16 = 0
    var lt: UInt8 = 0, rt: UInt8 = 0
    var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0

    static func axis(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        let v = max(-1, min(1, value))
        return Int16((v * (v < 0 ? 32768 : 32767)).rounded())
    }

    /// Same arbitration as the fork: a physical stick outside its XInput
    /// dead zone wins; otherwise use a deflected touch stick. A resting touch
    /// stick must not erase a small physical deflection.
    static func merge(physical p: Self, touch t: Self) -> Self {
        var result = p
        result.buttons |= t.buttons
        result.lt = max(p.lt, t.lt); result.rt = max(p.rt, t.rt)
        if hypot(Double(p.lx), Double(p.ly)) <= 7849 && (t.lx != 0 || t.ly != 0) {
            result.lx = t.lx; result.ly = t.ly
        }
        if hypot(Double(p.rx), Double(p.ry)) <= 8689 && (t.rx != 0 || t.ry != 0) {
            result.rx = t.rx; result.ry = t.ry
        }
        return result
    }
}

enum TouchPadAction {
    static let buttons: [String: UInt16] = [
        "A": 0x1000, "B": 0x2000, "X": 0x4000, "Y": 0x8000,
        "D↑": 1, "D↓": 2, "D←": 4, "D→": 8,
        "LB": 0x0100, "RB": 0x0200, "L3": 0x0040, "R3": 0x0080,
        "Menu": 0x0010, "View": 0x0020, "Guide": 0x0400
    ]
    static func supported(_ name: String) -> Bool {
        buttons[name] != nil || ["LT", "RT", "LS", "RS"].contains(name)
    }
    static func vector(x: Double, y: Double) -> (Double, Double) {
        guard x.isFinite && y.isFinite else { return (0, 0) }
        let length = max(1, hypot(x, y))
        return (x / length, y / length)
    }
    static func sample(_ name: String, x: Double = 0, y: Double = 0) -> GamepadSample {
        var result = GamepadSample()
        result.buttons = buttons[name] ?? 0
        if name == "LT" { result.lt = 255 }
        if name == "RT" { result.rt = 255 }
        let (x, y) = vector(x: x, y: y)
        if name == "LS" { result.lx = GamepadSample.axis(x); result.ly = GamepadSample.axis(y) }
        if name == "RS" { result.rx = GamepadSample.axis(x); result.ry = GamepadSample.axis(y) }
        return result
    }
}

struct TouchGamepadState {
    private struct Hold { var control: UUID; var value: GamepadSample }
    private var allowed = Set<UUID>()
    private var holds: [UUID: Hold] = [:]
    /// Player 1 stays connected at rest for the whole session, even with no
    /// visible touch control (GamepadInput.reserveSessionSlot). Layout changes
    /// and lifecycle clearing release holds but keep the reservation.
    var reserved = false
    var connected: Bool { reserved || !allowed.isEmpty }

    mutating func configure(_ controls: Set<UUID>) {
        allowed = controls
        // Layout changes invalidate all in-flight gestures, including remaps
        // which preserve the control's ID.
        clear()
    }
    mutating func update(owner: UUID, control: UUID, value: GamepadSample?) {
        guard allowed.contains(control), let value else { holds[owner] = nil; return }
        holds[owner] = Hold(control: control, value: value)
    }
    mutating func clear() { holds.removeAll() }
    var sample: GamepadSample {
        var result = GamepadSample()
        for hold in holds.values {
            let s = hold.value
            result.buttons |= s.buttons
            result.lt = max(result.lt, s.lt); result.rt = max(result.rt, s.rt)
            // Duplicate stick controls choose the stronger vector; lexical
            // tie-breaking makes equal opposite inputs deterministic.
            func stronger(_ x: Int16, _ y: Int16, _ a: Int16, _ b: Int16) -> Bool {
                let n = Int64(x) * Int64(x) + Int64(y) * Int64(y)
                let m = Int64(a) * Int64(a) + Int64(b) * Int64(b)
                return n > m || (n == m && (x > a || (x == a && y > b)))
            }
            if stronger(s.lx, s.ly, result.lx, result.ly) { result.lx = s.lx; result.ly = s.ly }
            if stronger(s.rx, s.ry, result.rx, result.ry) { result.rx = s.rx; result.ry = s.ry }
        }
        return result
    }
}
// MARK: - UIKit touch lifetime

/// UIKit supplies explicit cancellation and independent finger identities;
/// SwiftUI's DragGesture.onEnded alone cannot release every interrupted press.
struct TouchPadSurface: UIViewRepresentable {
    let control: UUID
    let action: String
    let changed: (CGSize, Bool) -> Void
    func makeUIView(context: Context) -> TouchPadView { TouchPadView() }
    func updateUIView(_ view: TouchPadView, context: Context) {
        view.configure(control: control, action: action, changed: changed)
    }
    static func dismantleUIView(_ view: TouchPadView, coordinator: ()) { view.releaseAll() }
}

final class TouchPadView: UIView {
    private struct Finger { var owner: UUID; var start: CGPoint }
    private var fingers: [ObjectIdentifier: Finger] = [:]
    private var control = UUID()
    private var action = ""
    private var changed: ((CGSize, Bool) -> Void)?
    private var previousSize = CGSize.zero

    init() {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
            name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    func configure(control: UUID, action: String, changed: @escaping (CGSize, Bool) -> Void) {
        if self.control != control || self.action != action { releaseAll() }
        self.control = control; self.action = action; self.changed = changed
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != bounds.size { releaseAll(); previousSize = bounds.size }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { releaseAll() } }
    @objc private func interrupted() { releaseAll(); changed?(.zero, false) }
    func releaseAll() {
        for finger in fingers.values {
            GamepadInput.shared.touch(owner: finger.owner, control: control, value: nil)
        }
        fingers.removeAll()
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            fingers[ObjectIdentifier(touch)] = Finger(owner: UUID(), start: touch.location(in: self))
        }
        update(touches)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches) }
    private func update(_ touches: Set<UITouch>) {
        guard UIApplication.shared.applicationState == .active else { interrupted(); return }
        for touch in touches {
            guard let finger = fingers[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self), radius = max(1, bounds.width * 0.35)
            let (x, y) = TouchPadAction.vector(x: Double((point.x - finger.start.x) / radius),
                                              y: Double((finger.start.y - point.y) / radius))
            GamepadInput.shared.touch(owner: finger.owner, control: control,
                value: TouchPadAction.sample(action, x: x, y: y))
            changed?(CGSize(width: x, height: -y), true)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    private func finish(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let finger = fingers.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            GamepadInput.shared.touch(owner: finger.owner, control: control, value: nil)
        }
        if fingers.isEmpty { changed?(.zero, false) }
    }
}
