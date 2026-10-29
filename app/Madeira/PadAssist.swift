// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Gyro aim and turbo for player 1. Gyro aim turns the controller's (or the
// device's) rotation into right-stick movement on top of the stick itself;
// turbo repeats chosen buttons while they are held. Both are per game
// (LibraryEntry.padAssist, Game details › Controls, or the Session menu) and
// off until turned on. GamepadInput.sample() applies them to player 1's merged
// sample, so XInput, the HID controller and keyboard-and-mouse mode all see the
// result. docs/CONTROLLERS.md, "Gyro aim and turbo".
import Foundation
@preconcurrency import GameController
import CoreMotion
import SwiftUI
import UIKit

// MARK: - Pure pad assist

/// A game's gyro aim and turbo choices. Every field decodes as optional, so a
/// later field does not break games saved before it.
struct PadAssistSettings: Codable, Equatable, Sendable {
    /// Where rotation comes from: the controller's gyro, the iPhone or iPad's
    /// own, or the controller's when it has one and the device's otherwise.
    enum Source: String, Codable, CaseIterable, Sendable { case auto, controller, device }
    /// When gyro aim moves the stick: always, or only while a button is held
    /// (LT is the usual aim-down-sights trigger).
    enum When: String, Codable, CaseIterable, Sendable { case always, lt = "LT", lb = "LB", rb = "RB" }
    /// What turns the view left and right: twisting the pad flat (yaw) or
    /// tilting it like a wheel (roll).
    enum Turn: String, Codable, CaseIterable, Sendable { case yaw, roll }
    /// What gyro aim moves: the right stick, the mouse, or (automatic) the mouse
    /// when player 1 is not a controller the game reads (no controller and no
    /// touch controller, or keyboard-and-mouse mode) and the right stick otherwise.
    enum Output: String, Codable, CaseIterable, Sendable { case auto, stick, mouse }

    var gyro = false
    var source = Source.auto
    var when = When.always
    var turn = Turn.yaw
    var output = Output.auto
    /// 0.25...4; 1 moves the stick fully at 150 degrees a second, or the mouse
    /// 8 pixels a degree.
    var sensitivity = 1.0
    var invertX = false
    var invertY = false
    /// The least stick deflection a gyro movement gives (0...0.5), so slow aim
    /// passes the game's own dead zone. 0.25 is XInput's standard right-stick
    /// dead zone (8689 / 32767).
    var antiDeadzone = 0.25
    /// Buttons repeated while held (turboMasks names).
    var turbo: [String] = []
    /// Presses a second, 5...30.
    var turboRate = 10.0

    static let turboChoices = ["A", "B", "X", "Y", "LB", "RB", "LT", "RT"]
    static let turboMasks: [String: UInt16] = ["A": 0x1000, "B": 0x2000, "X": 0x4000, "Y": 0x8000, "LB": 0x0100, "RB": 0x0200]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gyro = try c.decodeIfPresent(Bool.self, forKey: .gyro) ?? false
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .auto
        when = (try? c.decodeIfPresent(When.self, forKey: .when)) ?? .always
        turn = (try? c.decodeIfPresent(Turn.self, forKey: .turn)) ?? .yaw
        output = (try? c.decodeIfPresent(Output.self, forKey: .output)) ?? .auto
        sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? 1
        invertX = try c.decodeIfPresent(Bool.self, forKey: .invertX) ?? false
        invertY = try c.decodeIfPresent(Bool.self, forKey: .invertY) ?? false
        antiDeadzone = try c.decodeIfPresent(Double.self, forKey: .antiDeadzone) ?? 0.25
        turbo = try c.decodeIfPresent([String].self, forKey: .turbo) ?? []
        turboRate = try c.decodeIfPresent(Double.self, forKey: .turboRate) ?? 10
    }

    /// Nothing turned on: the sampler skips the game's settings.
    var isOff: Bool { !gyro && turbo.isEmpty }

    var turboMask: UInt16 { turbo.reduce(0) { $0 | (Self.turboMasks[$1] ?? 0) } }
}

/// The part of player 1's sample that gyro aim and turbo read and change.
struct AssistPad: Equatable, Sendable {
    var buttons: UInt16 = 0
    var lt: UInt8 = 0, rt: UInt8 = 0
    var rx: Int16 = 0, ry: Int16 = 0
}

enum GyroAim {
    /// Rotation slower than this (degrees a second) is sensor noise and hand
    /// tremor: no stick movement, so the anti-dead zone cannot turn it into drift.
    static let noiseFloor = 2.0
    /// Degrees a second for full deflection at sensitivity 1.
    static let fullScale = 150.0
    /// A trigger counts as held past 25 of 255, as the HID controller's L2/R2 bits do.
    static let triggerHeld: UInt8 = 25

    static func held(_ pad: AssistPad, _ when: PadAssistSettings.When) -> Bool {
        switch when {
        case .always: return true
        case .lt: return pad.lt > triggerHeld
        case .lb: return pad.buttons & 0x0100 != 0
        case .rb: return pad.buttons & 0x0200 != 0
        }
    }

    /// The stick deflection (-1...1 each, up and right positive) for a rotation
    /// of `turn` (positive: turning right) and `pitch` (positive: aiming up),
    /// in degrees a second.
    static func stick(turn: Double, pitch: Double, settings s: PadAssistSettings) -> (x: Double, y: Double) {
        guard turn.isFinite, pitch.isFinite, hypot(turn, pitch) >= noiseFloor else { return (0, 0) }
        let scale = max(0.25, min(4, s.sensitivity)) / fullScale
        let x = turn * scale * (s.invertX ? -1 : 1), y = pitch * scale * (s.invertY ? -1 : 1)
        let magnitude = hypot(x, y)
        guard magnitude > 0 else { return (0, 0) }
        let floor = max(0, min(0.5, s.antiDeadzone))
        let out = floor + (1 - floor) * min(1, magnitude)
        return (x / magnitude * out, y / magnitude * out)
    }

    /// Mouse pixels a degree at sensitivity 1.
    static let pixelsPerDegree = 8.0

    /// Mouse motion (pixels, right and down positive) for the rotation over `dt`
    /// seconds. No anti-dead zone: a mouse has none to pass.
    static func mouse(turn: Double, pitch: Double, dt: Double, settings s: PadAssistSettings) -> (dx: Double, dy: Double) {
        guard turn.isFinite, pitch.isFinite, dt.isFinite, dt > 0, hypot(turn, pitch) >= noiseFloor else { return (0, 0) }
        let scale = max(0.25, min(4, s.sensitivity)) * pixelsPerDegree * dt
        return (turn * scale * (s.invertX ? -1 : 1), -pitch * scale * (s.invertY ? -1 : 1))
    }

    /// `axis` moved by `amount` of full deflection, clamped to XInput's range.
    static func add(_ amount: Double, to axis: Int16) -> Int16 {
        let value = Double(axis) / (axis < 0 ? 32768 : 32767) + amount
        let v = max(-1, min(1, value))
        return Int16((v * (v < 0 ? 32768 : 32767)).rounded())
    }

    /// GameController's motion frame: x to the right, y away from the player,
    /// z out of the face. Held flat, twisting is z, tilting the front up is x,
    /// and tilting like a wheel is y. Rates in radians a second.
    static func controllerRates(x: Double, y: Double, z: Double, turn: PadAssistSettings.Turn) -> (turn: Double, pitch: Double) {
        let degrees = 180 / Double.pi
        return (turn == .roll ? y * degrees : -z * degrees, x * degrees)
    }

    /// CoreMotion's device frame (x right and y up in portrait, z out of the
    /// screen) turned into the player's view, for the screen held upright facing
    /// them. `orientation` is UIInterfaceOrientation's raw value: 1 portrait,
    /// 2 upside down, 3 landscape right (home side right), 4 landscape left.
    static func deviceRates(x: Double, y: Double, z: Double, orientation: Int,
                            turn: PadAssistSettings.Turn) -> (turn: Double, pitch: Double) {
        let degrees = 180 / Double.pi
        // Rotation about the screen's vertical (yaw) and horizontal (pitch) axes.
        let vertical: Double, horizontal: Double
        switch orientation {
        case 2: vertical = -y; horizontal = -x
        case 3: vertical = x; horizontal = -y
        case 4: vertical = -x; horizontal = y
        default: vertical = y; horizontal = x
        }
        return ((turn == .roll ? -z : -vertical) * degrees, horizontal * degrees)
    }
}

/// Turbo: each chosen button, while held, is pressed and released `rate` times
/// a second. The first press is immediate; letting go ends it at once.
struct TurboState: Sendable {
    /// When each held button was pressed (uptime ns): the 16 XInput button bits, then LT and RT.
    private var since = [UInt64](repeating: 0, count: 18)

    static func on(elapsed: UInt64, rate: Double) -> Bool {
        let half = 1_000_000_000 / (max(5, min(30, rate)) * 2)
        return Int((Double(elapsed) / half).rounded(.down)) % 2 == 0
    }

    mutating func apply(_ pad: inout AssistPad, mask: UInt16, lt: Bool, rt: Bool, rate: Double, now: UInt64) {
        for bit in 0..<16 where mask & (1 << bit) != 0 {
            let flag = UInt16(1) << UInt16(bit)
            if pad.buttons & flag == 0 { since[bit] = 0; continue }
            if since[bit] == 0 { since[bit] = now }
            if !Self.on(elapsed: now &- since[bit], rate: rate) { pad.buttons &= ~flag }
        }
        if lt { pad.lt = pulse(pad.lt, 16, rate: rate, now: now) }
        if rt { pad.rt = pulse(pad.rt, 17, rate: rate, now: now) }
    }

    private mutating func pulse(_ value: UInt8, _ slot: Int, rate: Double, now: UInt64) -> UInt8 {
        guard value > GyroAim.triggerHeld else { since[slot] = 0; return value }
        if since[slot] == 0 { since[slot] = now }
        return Self.on(elapsed: now &- since[slot], rate: rate) ? value : 0
    }

    mutating func reset() { since = [UInt64](repeating: 0, count: since.count) }
}

/// One sample through gyro aim and turbo. `rates` is the rotation already in
/// the player's view (GyroAim.controllerRates / deviceRates), nil with no gyro.
/// Whether gyro is held is read before turbo pulses the buttons.
func applyPadAssist(_ pad: inout AssistPad, settings s: PadAssistSettings, rates: (turn: Double, pitch: Double)?,
                    turbo: inout TurboState, now: UInt64) {
    if s.gyro, let rates, GyroAim.held(pad, s.when) {
        let move = GyroAim.stick(turn: rates.turn, pitch: rates.pitch, settings: s)
        pad.rx = GyroAim.add(move.x, to: pad.rx)
        pad.ry = GyroAim.add(move.y, to: pad.ry)
    }
    if !s.turbo.isEmpty {
        turbo.apply(&pad, mask: s.turboMask, lt: s.turbo.contains("LT"), rt: s.turbo.contains("RT"),
                    rate: s.turboRate, now: now)
    }
}

// MARK: - Sensors

/// The iPhone or iPad's own gyro for gyro aim's "This device" source, and the
/// screen's orientation to read it in. Started only while a session's gyro
/// aim may use it. Polled from GamepadInput's queue.
final class PadAssistSensors: @unchecked Sendable {
    static let shared = PadAssistSensors()
    private let manager = CMMotionManager()
    private let lock = NSLock()
    private var orientationValue = 3
    private var observer: NSObjectProtocol?

    @MainActor func setDeviceGyro(_ on: Bool) {
        if on {
            guard observer == nil, manager.isDeviceMotionAvailable else { return }
            manager.deviceMotionUpdateInterval = 1.0 / 200
            manager.startDeviceMotionUpdates()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateOrientation()
            observer = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateOrientation() }
            }
            LogStore.shared.log("[pad-assist] device gyro on")
        } else {
            guard let observer else { return }
            manager.stopDeviceMotionUpdates()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
            LogStore.shared.log("[pad-assist] device gyro off")
        }
    }

    @MainActor private func updateOrientation() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let raw = scene?.interfaceOrientation.rawValue ?? 3
        lock.lock(); orientationValue = raw; lock.unlock()
    }

    /// The device's rotation in the player's view, or nil while it is off.
    func rates(turn: PadAssistSettings.Turn) -> (turn: Double, pitch: Double)? {
        guard let rate = manager.deviceMotion?.rotationRate else { return nil }
        lock.lock(); let orientation = orientationValue; lock.unlock()
        return GyroAim.deviceRates(x: rate.x, y: rate.y, z: rate.z, orientation: orientation, turn: turn)
    }

    /// A controller's motion sensors, which some pads (DualSense, DualShock 4)
    /// keep off until asked, as they cost battery.
    @MainActor static func setControllerGyro(_ on: Bool) {
        for controller in GCController.controllers() {
            guard let motion = controller.motion, motion.sensorsRequireManualActivation,
                  motion.sensorsActive != on else { continue }
            motion.sensorsActive = on
            LogStore.shared.log("[pad-assist] \(controller.vendorName ?? "controller") gyro \(on ? "on" : "off")")
        }
    }
}

// MARK: - Settings page

/// Gyro aim and turbo, as rows of a Form: Game details › Controls and the
/// Session menu's page. nil is all off; once changed, the choices are kept
/// (sensitivity and the rest survive turning gyro aim off and on).
struct PadAssistPage: View {
    @Binding var settings: PadAssistSettings?

    private func bind<T>(_ path: WritableKeyPath<PadAssistSettings, T>) -> Binding<T> {
        Binding(get: { (settings ?? PadAssistSettings())[keyPath: path] },
                set: { var next = settings ?? PadAssistSettings(); next[keyPath: path] = $0; settings = next })
    }

    var body: some View {
        Section {
            Toggle("Gyro aim", isOn: bind(\.gyro))
            if settings?.gyro == true {
                Picker("Gyro", selection: bind(\.source)) {
                    Text("Automatic").tag(PadAssistSettings.Source.auto)
                    Text("Controller").tag(PadAssistSettings.Source.controller)
                    Text("This device").tag(PadAssistSettings.Source.device)
                }
                Picker("Active", selection: bind(\.when)) {
                    Text("Always").tag(PadAssistSettings.When.always)
                    Text("While holding LT").tag(PadAssistSettings.When.lt)
                    Text("While holding LB").tag(PadAssistSettings.When.lb)
                    Text("While holding RB").tag(PadAssistSettings.When.rb)
                }
                Picker("Moves", selection: bind(\.output)) {
                    Text("Automatic").tag(PadAssistSettings.Output.auto)
                    Text("Right stick").tag(PadAssistSettings.Output.stick)
                    Text("Mouse").tag(PadAssistSettings.Output.mouse)
                }
                Picker("Turn with", selection: bind(\.turn)) {
                    Text("Twist (yaw)").tag(PadAssistSettings.Turn.yaw)
                    Text("Tilt (roll)").tag(PadAssistSettings.Turn.roll)
                }
                LabeledContent("Sensitivity") {
                    HStack {
                        Slider(value: bind(\.sensitivity), in: 0.25...4)
                        Text(String(format: "%.2g×", settings?.sensitivity ?? 1)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Anti-dead zone") {
                    HStack {
                        Slider(value: bind(\.antiDeadzone), in: 0...0.5)
                        Text("\(Int(((settings?.antiDeadzone ?? 0.25) * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Invert up and down", isOn: bind(\.invertY))
                Toggle("Invert left and right", isOn: bind(\.invertX))
            }
        } header: { Text("Gyro aim") } footer: {
            Text("Moving the controller (or this device) aims. Automatic gyro uses the controller's (DualSense, DualShock 4, Switch Pro) and this device's otherwise. Automatic moves the right stick when the game sees a controller and the mouse otherwise. Without a controller, only Always works. Raise the anti-dead zone if slow stick aim does nothing.")
        }
        Section {
            ForEach(PadAssistSettings.turboChoices, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { settings?.turbo.contains(name) == true }, set: { on in
                    var next = settings ?? PadAssistSettings()
                    next.turbo.removeAll { $0 == name }
                    if on { next.turbo.append(name) }
                    settings = next
                }))
            }
            if settings?.turbo.isEmpty == false {
                LabeledContent("Presses a second") {
                    HStack {
                        Slider(value: bind(\.turboRate), in: 5...30, step: 1)
                        Text("\(Int(settings?.turboRate ?? 10))").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
        } header: { Text("Turbo") } footer: {
            Text("A turbo button repeats while you hold it, on the controller and on touch controls.")
        }
    }
}
