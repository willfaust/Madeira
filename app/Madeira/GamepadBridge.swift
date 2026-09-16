import Foundation
import GameController
import CoreHaptics

/// Feeds GameController.framework pads to Wine's XInput.
///
/// There is no HID stack under Wine on iOS, so xinput1_3 runs in "host
/// mode" and reads the pad table in xinput_host_ios.c. This class fills that
/// table: every connected GCExtendedGamepad (DualSense, DualShock 4, Xbox,
/// MFi — iOS normalises them all to Xbox-positional names) gets an XInput
/// slot, and the touch overlay's pad buttons are merged into slot 0.
///
/// Everything runs on the main queue: GC handlers, touch gestures and the
/// rumble poll timer.
final class GamepadBridge {
    static let shared = GamepadBridge()

    static let slotCount = 4

    // XINPUT_GAMEPAD_* bits.
    private enum Bit {
        static let dpadUp: UInt16 = 0x0001, dpadDown: UInt16 = 0x0002
        static let dpadLeft: UInt16 = 0x0004, dpadRight: UInt16 = 0x0008
        static let start: UInt16 = 0x0010, back: UInt16 = 0x0020
        static let leftThumb: UInt16 = 0x0040, rightThumb: UInt16 = 0x0080
        static let leftShoulder: UInt16 = 0x0100, rightShoulder: UInt16 = 0x0200
        static let guide: UInt16 = 0x0400
        static let a: UInt16 = 0x1000, b: UInt16 = 0x2000
        static let x: UInt16 = 0x4000, y: UInt16 = 0x8000
    }

    /// What the game sees for VID/PID. Always an Xbox 360 pad: XInput devices
    /// are Xbox devices on Windows, and some titles (and SDL) branch on this.
    private static let vendorID: Int32 = 0x045E
    private static let productID: Int32 = 0x028E

    private struct PadState: Equatable {
        var buttons: UInt16 = 0
        var lt: UInt8 = 0, rt: UInt8 = 0
        var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0
    }

    private var slots = [GCController?](repeating: nil, count: slotCount)
    private var physical = [PadState](repeating: PadState(), count: slotCount)
    private var rumble = [PadRumble?](repeating: nil, count: slotCount)
    private var rumbleSerial = [Int32](repeating: 0, count: slotCount)
    private var rumbleTimer: Timer?

    // Touch overlay pad, merged into slot 0.
    private var touch = PadState()
    private var touchActive = false

    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.detach(c) }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery(completionHandler: nil)

        rumbleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pollRumble()
        }
    }

    // MARK: - Physical controllers

    private func attach(_ c: GCController) {
        guard let pad = c.extendedGamepad else {
            NSLog("[pad] ignoring %@ (no extended gamepad profile)", c.vendorName ?? "?")
            return
        }
        guard !slots.contains(where: { $0 === c }),
              let slot = slots.firstIndex(where: { $0 == nil }) else { return }

        slots[slot] = c
        physical[slot] = PadState()
        rumbleSerial[slot] = 0
        c.playerIndex = GCControllerPlayerIndex(rawValue: slot) ?? .indexUnset

        // Let the guide and share/create buttons reach the game as well as
        // the system (Home menu, screenshots).
        if #available(iOS 14.5, *) {
            pad.buttonHome?.preferredSystemGestureState = .alwaysReceive
            pad.buttonOptions?.preferredSystemGestureState = .alwaysReceive
        }

        rumble[slot] = PadRumble(controller: c)
        madeira_pad_set_connected(Int32(slot), 1, Self.vendorID, Self.productID,
                                  rumble[slot] != nil ? 1 : 0)

        pad.valueChangedHandler = { [weak self] gp, _ in
            self?.read(gp, into: slot)
        }
        read(pad, into: slot)

        NSLog("[pad] %@ (%@) -> XInput slot %d, rumble %@",
              c.vendorName ?? "controller", c.productCategory, slot,
              rumble[slot] != nil ? "yes" : "no")
    }

    private func detach(_ c: GCController) {
        guard let slot = slots.firstIndex(where: { $0 === c }) else { return }
        c.extendedGamepad?.valueChangedHandler = nil
        slots[slot] = nil
        physical[slot] = PadState()
        rumble[slot]?.stop()
        rumble[slot] = nil

        if slot == 0 && touchActive {
            // The touch pad keeps slot 0 alive, now without rumble.
            madeira_pad_set_connected(0, 1, Self.vendorID, Self.productID, 0)
            publish(0)
        } else {
            madeira_pad_set_connected(Int32(slot), 0, 0, 0, 0)
        }
        NSLog("[pad] %@ left XInput slot %d", c.vendorName ?? "controller", slot)
    }

    private func read(_ gp: GCExtendedGamepad, into slot: Int) {
        var s = PadState()
        func set(_ on: Bool, _ bit: UInt16) { if on { s.buttons |= bit } }

        set(gp.dpad.up.isPressed, Bit.dpadUp)
        set(gp.dpad.down.isPressed, Bit.dpadDown)
        set(gp.dpad.left.isPressed, Bit.dpadLeft)
        set(gp.dpad.right.isPressed, Bit.dpadRight)
        set(gp.buttonMenu.isPressed, Bit.start)
        set(gp.buttonOptions?.isPressed ?? false, Bit.back)
        set(gp.leftThumbstickButton?.isPressed ?? false, Bit.leftThumb)
        set(gp.rightThumbstickButton?.isPressed ?? false, Bit.rightThumb)
        set(gp.leftShoulder.isPressed, Bit.leftShoulder)
        set(gp.rightShoulder.isPressed, Bit.rightShoulder)
        set(gp.buttonHome?.isPressed ?? false, Bit.guide)
        set(gp.buttonA.isPressed, Bit.a)
        set(gp.buttonB.isPressed, Bit.b)
        set(gp.buttonX.isPressed, Bit.x)
        set(gp.buttonY.isPressed, Bit.y)

        // The PlayStation touchpad click has no XInput equivalent; games
        // mostly put map/scoreboard on Back, so it doubles as that.
        if let ds = gp as? GCDualSenseGamepad { set(ds.touchpadButton.isPressed, Bit.back) }
        if let ds = gp as? GCDualShockGamepad { set(ds.touchpadButton.isPressed, Bit.back) }

        s.lt = Self.trigger(gp.leftTrigger.value)
        s.rt = Self.trigger(gp.rightTrigger.value)
        s.lx = Self.axis(gp.leftThumbstick.xAxis.value)
        s.ly = Self.axis(gp.leftThumbstick.yAxis.value)      // GC and XInput are both +Y up
        s.rx = Self.axis(gp.rightThumbstick.xAxis.value)
        s.ry = Self.axis(gp.rightThumbstick.yAxis.value)

        guard s != physical[slot] else { return }
        physical[slot] = s
        publish(slot)
    }

    // MARK: - Touch overlay (slot 0)

    enum TouchStick { case left, right }

    /// Press/release a touch-overlay pad button by its mapping-panel name.
    func setTouchButton(_ name: String, down: Bool) {
        switch name {
        case "LT": touch.lt = down ? 255 : 0
        case "RT": touch.rt = down ? 255 : 0
        default:
            guard let bit = Self.touchBits[name] else { return }
            if down { touch.buttons |= bit } else { touch.buttons &= ~bit }
        }
        touchChanged()
    }

    /// x, y in -1...1, +Y up.
    func setTouchStick(_ stick: TouchStick, x: Double, y: Double) {
        let ax = Self.axis(Float(x)), ay = Self.axis(Float(y))
        switch stick {
        case .left:  touch.lx = ax; touch.ly = ay
        case .right: touch.rx = ax; touch.ry = ay
        }
        touchChanged()
    }

    static func isTouchStick(_ name: String) -> TouchStick? {
        switch name {
        case "LS": return .left
        case "RS": return .right
        default:   return nil
        }
    }

    private static let touchBits: [String: UInt16] = [
        "A": Bit.a, "B": Bit.b, "X": Bit.x, "Y": Bit.y,
        "D↑": Bit.dpadUp, "D↓": Bit.dpadDown, "D←": Bit.dpadLeft, "D→": Bit.dpadRight,
        "LB": Bit.leftShoulder, "RB": Bit.rightShoulder,
        "L3": Bit.leftThumb, "R3": Bit.rightThumb,
        "Menu": Bit.start, "View": Bit.back, "Guide": Bit.guide,
    ]

    private func touchChanged() {
        if !touchActive {
            // The virtual pad only appears once it is used, so games that
            // switch prompts on "a pad is present" stay on keyboard until then.
            touchActive = true
            if slots[0] == nil {
                madeira_pad_set_connected(0, 1, Self.vendorID, Self.productID, 0)
            }
        }
        publish(0)
    }

    // MARK: - Publishing

    private func publish(_ slot: Int) {
        var s = physical[slot]
        if slot == 0 && touchActive {
            s.buttons |= touch.buttons
            s.lt = max(s.lt, touch.lt)
            s.rt = max(s.rt, touch.rt)
            if touch.lx != 0 || touch.ly != 0 { s.lx = touch.lx; s.ly = touch.ly }
            if touch.rx != 0 || touch.ry != 0 { s.rx = touch.rx; s.ry = touch.ry }
        }
        madeira_pad_update(Int32(slot), Int32(s.buttons), Int32(s.lt), Int32(s.rt),
                           Int32(s.lx), Int32(s.ly), Int32(s.rx), Int32(s.ry))
    }

    private static func trigger(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, (v * 255).rounded())))
    }

    private static func axis(_ v: Float) -> Int16 {
        let c = max(-1, min(1, v))
        return c < 0 ? Int16((c * 32768).rounded()) : Int16((c * 32767).rounded())
    }

    // MARK: - Rumble

    private func pollRumble() {
        for slot in 0..<Self.slotCount {
            guard let r = rumble[slot] else { continue }
            var left: Int32 = 0, right: Int32 = 0
            let serial = madeira_pad_get_vibration(Int32(slot), &left, &right)
            guard serial != rumbleSerial[slot] else { continue }
            rumbleSerial[slot] = serial
            r.set(low: Float(left) / 65535, high: Float(right) / 65535)
        }
    }
}

/// Two continuous haptic players standing in for XInput's motors: the left
/// (low-frequency, heavy) motor and the right (high-frequency, light) one.
/// Uses the handle localities when the pad has them (DualSense, Xbox), else
/// the whole controller.
private final class PadRumble {
    private final class Motor {
        let engine: CHHapticEngine
        let sharpness: Float
        var player: CHHapticAdvancedPatternPlayer?
        var running = false

        init(engine: CHHapticEngine, sharpness: Float) {
            self.engine = engine
            self.sharpness = sharpness
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak self] in
                self?.player = nil
                self?.running = false
            }
            engine.stoppedHandler = { [weak self] _ in
                self?.player = nil
                self?.running = false
            }
        }

        func set(_ intensity: Float) {
            if intensity <= 0.01 {
                if running { try? player?.stop(atTime: CHHapticTimeImmediate) }
                running = false
                return
            }
            do {
                if player == nil {
                    try engine.start()
                    let event = CHHapticEvent(
                        eventType: .hapticContinuous,
                        parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                        ],
                        relativeTime: 0, duration: 30)
                    let p = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                    p.loopEnabled = true
                    player = p
                }
                try player?.sendParameters(
                    [CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                              value: intensity, relativeTime: 0)],
                    atTime: CHHapticTimeImmediate)
                if !running {
                    try player?.start(atTime: CHHapticTimeImmediate)
                    running = true
                }
            } catch {
                NSLog("[pad] rumble error: %@", error.localizedDescription)
                player = nil
                running = false
            }
        }
    }

    private let low: Motor
    private let high: Motor

    init?(controller: GCController) {
        guard let haptics = controller.haptics else { return nil }
        let localities = haptics.supportedLocalities
        let split = localities.contains(.leftHandle) && localities.contains(.rightHandle)
        guard let l = haptics.createEngine(withLocality: split ? .leftHandle : .default),
              let r = haptics.createEngine(withLocality: split ? .rightHandle : .default)
        else { return nil }
        low = Motor(engine: l, sharpness: 0.15)
        high = Motor(engine: r, sharpness: 0.75)
    }

    func set(low l: Float, high h: Float) {
        low.set(l)
        high.set(h)
    }

    func stop() {
        low.set(0)
        high.set(0)
        low.engine.stop(completionHandler: nil)
        high.engine.stop(completionHandler: nil)
    }
}
