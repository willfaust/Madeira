import Foundation
// GameController supports background handler queues but lacks Sendable annotations.
@preconcurrency import GameController
import UIKit
import SwiftUI

/// ml1930: physical and touch controller snapshots share the same serial publisher.
/// Slot/profile/timer state belongs exclusively to `queue`. The app lifecycle
/// and observer registration belong to the main actor. Guest readers use the
/// C snapshot lock; no Swift objects cross into Wine.
final class GamepadInput: @unchecked Sendable {
    static let shared = GamepadInput()
    @MainActor static let enabled: Bool = {
        let value = MadeiraConfig.get("env.MADEIRA_XINPUT")
            ?? ProcessInfo.processInfo.environment["MADEIRA_XINPUT"]
        return value != "0"
    }()

    @MainActor static let touchEnabled: Bool = {
        let value = MadeiraConfig.get("env.MADEIRA_TOUCH_XINPUT")
            ?? ProcessInfo.processInfo.environment["MADEIRA_TOUCH_XINPUT"]
        return enabled && value != "0"
    }()

    @MainActor func configureTouch(controls: Set<UUID>, acceptingInput: Bool = true) {
        let allowed = Self.touchEnabled ? controls : []
        queue.async { [self] in
            let wasConnected = touchState.connected, wasAccepting = touchState.acceptingInput
            touchState.configure(allowed, acceptingInput: acceptingInput)
            if wasConnected != touchState.connected || wasAccepting != touchState.acceptingInput {
                LogStore.shared.log("[touch-xinput] connected=\(touchState.connected ? 1 : 0) accepting=\(acceptingInput ? 1 : 0) controls=\(allowed.count)")
            }
            updateTimer()   // touch play with gyro aim or turbo needs the poll (PadAssist)
            sample()
        }
    }

    /// Publish player 1 before the game looks (MADEIRA_PAD_EARLY_SLOT=1; default OFF).
    ///
    /// Some input layers enumerate XInput once at startup and only rescan on a
    /// device-arrival broadcast, which this port does not deliver. Touch slot 0
    /// connects only once the landscape overlay shows its controller mappings,
    /// and a paired controller may not have reported an extended profile yet,
    /// so such a game never sees a pad. When the session will have a controller
    /// source (touch controller mappings shown, or a controller paired), slot 0
    /// is connected at rest from the start; live input takes it over. The
    /// reservation lasts until the process exits (one Wine session per run),
    /// so player 1 then shows as connected for the whole session even while no
    /// controller is in use. That is why it is opt-in: without the switch,
    /// slot 0 connects only when a real source appears, as before.
    @MainActor func reserveSessionSlot(touchControls: Bool) {
        guard Self.enabled, Self.optIn("MADEIRA_PAD_EARLY_SLOT") else { return }
        let touch = touchControls && Self.touchEnabled
        let paired = !GCController.controllers().isEmpty
        guard touch || paired else { return }
        queue.async { [self] in touchState.reserved = true; sample() }
        LogStore.shared.log("[xinput] ml1990 slot=0 reserved for the session touch=\(touch ? 1 : 0) paired=\(paired ? 1 : 0)")
    }

    /// ml2100: how player 1 reaches Windows, `env.MADEIRA_PAD_MODE` from
    /// madeira.cfg, else the process environment. Unset or "xinput": the XInput
    /// path above, unchanged (the default). "hid": player 1 becomes a HID game
    /// controller served by the wineserver (build/wineserver/hidpad_ios.c) -- a
    /// DualSense when the pad is a PlayStation one, a generic HID gamepad
    /// otherwise -- and leaves XInput. "dualsense" / "generic" force that
    /// identity. Read once, at session start (beginPadSession): the device
    /// exists before the game enumerates, so a change applies at the next start.
    /// The game's own lines come first (MadeiraConfig.gameValue), so a game's
    /// config or its recommended settings choose its mode.
    static let padModeKey = "env.MADEIRA_PAD_MODE"
    static func configuredPadMode() -> (value: String, source: String) {
        if let v = MadeiraConfig.gameValue(padModeKey) { return (v.lowercased(), "game") }
        if let v = MadeiraConfig.get(padModeKey), !v.isEmpty { return (v.lowercased(), "cfg") }
        if let v = ProcessInfo.processInfo.environment["MADEIRA_PAD_MODE"], !v.isEmpty { return (v.lowercased(), "env") }
        return ("xinput", "default")
    }

    /// ml2106: what of a game's controller output reaches the physical pad
    /// (app/Madeira/PadOutput.m): XInputSetState rumble on any XInput pad, and
    /// the virtual DualSense's output reports (rumble, adaptive triggers,
    /// lightbar, player LEDs) on player 1's pad. `env.MADEIRA_PAD_OUTPUT`:
    /// unset or 1 both, 0 none, hid only the DualSense's, xinput only XInput rumble.
    /// The game's own lines come first, as for the pad mode.
    static func configuredPadOutput() -> (xinput: Bool, hid: Bool, value: String) {
        let value = (MadeiraConfig.gameValue("env.MADEIRA_PAD_OUTPUT")
            ?? MadeiraConfig.get("env.MADEIRA_PAD_OUTPUT")
            ?? ProcessInfo.processInfo.environment["MADEIRA_PAD_OUTPUT"]
            ?? "1").lowercased()
        switch value {
        case "0", "off", "none": return (false, false, value)
        case "hid", "dualsense": return (false, true, value)
        case "xinput": return (true, false, value)
        default: return (true, true, value)
        }
    }

    /// ml2100: decide this session's controller path. Called once, before the
    /// wineserver starts (ContentView.runWineFullSequence): the wineserver and
    /// the first Wine process read MADEIRA_HIDPAD to create the device and its
    /// registry entries. In XInput mode it only unsets that and logs.
    @MainActor func beginPadSession() {
        let mode = Self.configuredPadMode()
        let output = Self.configuredPadOutput()
        unsetenv("MADEIRA_HIDPAD"); unsetenv("MADEIRA_HIDPAD_NAME")
        // An earlier session in this app run may have taken player 1 off XInput.
        queue.async { [self] in hidActive = false; hidKeepsXInput = false }
        guard ["hid", "dualsense", "generic"].contains(mode.value) else {
            LogStore.shared.log("[hid-pad] ml2100 session mode=xinput source=\(mode.source)")
            beginPadOutput(xinput: output.xinput && Self.enabled, hid: false, value: output.value)
            return
        }
        guard Self.enabled else {
            LogStore.shared.log("[hid-pad] ml2100 session mode=\(mode.value) ignored: MADEIRA_XINPUT=0 turns every controller off")
            beginPadOutput(xinput: false, hid: false, value: output.value)
            return
        }
        // Player 1 is the first paired extended gamepad, as refreshControllers assigns slots.
        let first = GCController.controllers().first { $0.extendedGamepad != nil }
        let sony = first?.extendedGamepad is GCDualSenseGamepad || first?.extendedGamepad is GCDualShockGamepad
        // "hid" is there for the DualSense identity. Any other pad became a generic HID
        // gamepad off XInput, which an XInput game sees only if it also enumerates
        // DirectInput (logs 2026-10-26 23:33/23:36: a GameSir pad, no controller in game
        // in two of three runs). Such a pad stays on XInput; "generic" still forces it.
        if mode.value == "hid", first != nil, !sony, !Self.optIn("MADEIRA_HIDPAD_AUTO_GENERIC") {
            LogStore.shared.log("[hid-pad] ml2100 session mode=hid source=\(mode.source) pad=\(first?.productCategory ?? "none") "
                                + "is not a PlayStation pad: XInput (env.MADEIRA_HIDPAD_AUTO_GENERIC=1 makes it a generic HID gamepad)")
            beginPadOutput(xinput: output.xinput, hid: false, value: output.value)
            return
        }
        let kind: String
        switch mode.value {
        case "dualsense", "generic": kind = mode.value
        // No pad yet: a DualSense, the identity this mode exists for.
        default: kind = first == nil || sony ? "dualsense" : "generic"
        }
        setenv("MADEIRA_HIDPAD", kind, 1)
        if kind == "generic", let name = first?.vendorName { setenv("MADEIRA_HIDPAD_NAME", name, 1) }
        let keepXInput = Self.optIn("MADEIRA_HIDPAD_XINPUT")
        queue.async { [self] in hidActive = true; hidKeepsXInput = keepXInput; sample() }
        LogStore.shared.log("[hid-pad] ml2100 session mode=\(mode.value) source=\(mode.source) kind=\(kind) "
                            + "pad=\(first?.productCategory ?? "none") xinput-slot0=\(keepXInput ? "kept" : "off")")
        // Only the DualSense identity has output reports (the generic pad has none).
        beginPadOutput(xinput: output.xinput, hid: output.hid && kind == "dualsense", value: output.value)
    }

    /// ml2106: arm PadOutput.m for this session. Before the wineserver starts,
    /// so XInputGetCapabilities already reports motors when rumble is on.
    @MainActor private func beginPadOutput(xinput: Bool, hid: Bool, value: String) {
        madeira_pad_output_configure(xinput ? 1 : 0, hid ? 1 : 0)
        LogStore.shared.log("[hidpad-out] ml2106 session env.MADEIRA_PAD_OUTPUT=\(value) "
                            + "xinput-rumble=\(xinput ? 1 : 0) dualsense-output=\(hid ? 1 : 0)")
    }

    /// Documents/madeira.cfg `env.NAME`, else the process environment; only "0" disables.
    static func flag(_ name: String) -> Bool {
        (MadeiraConfig.get("env.\(name)") ?? ProcessInfo.processInfo.environment[name]) != "0"
    }

    /// The same sources, for behaviour that is off by default: only "1" enables.
    static func optIn(_ name: String) -> Bool {
        (MadeiraConfig.get("env.\(name)") ?? ProcessInfo.processInfo.environment[name]) == "1"
    }

    @MainActor func touch(owner: UUID, control: UUID, value: GamepadSample?) {
        guard Self.touchEnabled else { return }
        queue.async { [self] in
            guard active || value == nil else { return }
            touchState.update(owner: owner, control: control, value: value)
            sample()
        }
    }

    /// Keyboard-and-mouse mode (PadKeyboardMouse): nil keeps XInput. Set on the
    /// main actor by the library for its session; read on `queue`.
    private var keyboardMouse: PadBindings?

    /// Availability of the mode. 0 removes the per-game choice; the physical pad then always feeds XInput.
    static let keyboardMouseAvailable: Bool = flag("MADEIRA_XINPUT") && flag("MADEIRA_PAD_KBM")

    /// ml2170: XInputGetBatteryInformation and XINPUT_CAPS_WIRELESS from each
    /// pad's GCDeviceBattery (win32u op 4). 0: nothing is published and XInput
    /// reports an unknown battery, as before.
    static let batteryEnabled: Bool = flag("MADEIRA_XINPUT_BATTERY")  // 0: XInput keeps reporting an unknown battery (no GCDeviceBattery level, no wireless flag)

    /// ml2170: GameController's battery as XInput reports one. Charging or full
    /// means a cable is in, which Windows shows as a wired pad (wired, full). On
    /// its battery the level is bucketed at 5/20/70 % (SDL's reverse mapping).
    /// No battery object or an unknown state: type unknown at full, so a game
    /// does not warn about a battery level nobody can read.
    static func xinputBattery(level: Float?, state: GCDeviceBattery.State?) -> (type: UInt8, level: UInt8) {
        switch state {
        case .charging?, .full?:
            return (UInt8(WINIOS_BATTERY_TYPE_WIRED), UInt8(WINIOS_BATTERY_LEVEL_FULL))
        case .discharging?:
            let fraction = level.map { $0.isFinite ? max(0, min(1, $0)) : 1 } ?? 1
            let bucket = fraction <= 0.05 ? WINIOS_BATTERY_LEVEL_EMPTY
                : fraction <= 0.20 ? WINIOS_BATTERY_LEVEL_LOW
                : fraction <= 0.70 ? WINIOS_BATTERY_LEVEL_MEDIUM : WINIOS_BATTERY_LEVEL_FULL
            return (UInt8(WINIOS_BATTERY_TYPE_NIMH), UInt8(bucket))
        default:
            return (UInt8(WINIOS_BATTERY_TYPE_UNKNOWN), UInt8(WINIOS_BATTERY_LEVEL_FULL))
        }
    }

    /// Whether keyboard-and-mouse mode is on. Main thread: PadStickMouse ("Right
    /// stick controls mouse") stands down while it is, since this mode moves the
    /// mouse (or drives keys) with the same stick.
    private(set) var keyboardMouseOn = false

    /// Translate player 1's physical pad into keys and mouse (`bindings`) instead
    /// of publishing it to XInput; nil restores XInput. Touch controls keep
    /// feeding XInput either way. Main thread.
    func setKeyboardMouse(_ bindings: PadBindings?) {
        guard Self.keyboardMouseAvailable else { return }
        keyboardMouseOn = bindings != nil
        queue.async { [self] in
            let was = keyboardMouse != nil
            if keyboardMouse != nil && bindings == nil { PadKeyboardMouse.shared.releaseAll("mode off") }
            keyboardMouse = bindings
            if was != (bindings != nil) {
                LogStore.shared.log("[pad-kbm] physical controller as keyboard and mouse: \(bindings != nil ? "on" : "off")")
            }
            sample()
        }
    }

    /// Gyro aim and turbo for player 1 (PadAssist.swift): the session's game's
    /// choices, nil when off. Main thread (LibraryModel), read on `queue`.
    func setPadAssist(_ settings: PadAssistSettings?) {
        let live = MainActor.assumeIsolated { () -> PadAssistSettings? in
            let live = Self.enabled ? settings.flatMap { $0.isOff ? nil : $0 } : nil
            let gyro = live?.gyro == true
            controllerGyro = gyro && live?.source != .device
            PadAssistSensors.setControllerGyro(controllerGyro)
            PadAssistSensors.shared.setDeviceGyro(gyro && live?.source != .controller)
            return live
        }
        queue.async { [self] in
            if assist != live {
                let gyroText = live.map { $0.gyro ? "\($0.source.rawValue)/\($0.when.rawValue)/\($0.turn.rawValue)/\($0.output.rawValue)" : "off" } ?? "off"
                let turbo = live.map { $0.turbo.joined(separator: "+") } ?? ""
                LogStore.shared.log("[pad-assist] gyro=\(gyroText) sensitivity=\(live?.sensitivity ?? 0) "
                                    + "anti-dead-zone=\(live?.antiDeadzone ?? 0) turbo=\(turbo.isEmpty ? "off" : turbo) rate=\(live?.turboRate ?? 0)")
            }
            assist = live
            turboState.reset()
            updateTimer()
            sample()
        }
    }
    /// Gyro aim reads the controller's gyro: a pad that connects mid-session has its sensors switched on too.
    @MainActor private var controllerGyro = false
    private var assist: PadAssistSettings?
    private var turboState = TurboState()

    /// Gyro aim's rotation in the player's view, from the source the game's choices allow (queue).
    private func gyroRates(_ assist: PadAssistSettings) -> (turn: Double, pitch: Double)? {
        if assist.source != .device, let motion = controllers[0]?.motion, motion.hasRotationRate {
            let r = motion.rotationRate
            return GyroAim.controllerRates(x: r.x, y: r.y, z: r.z, turn: assist.turn)
        }
        return assist.source != .controller ? PadAssistSensors.shared.rates(turn: assist.turn) : nil
    }

    /// Player 1's sample through gyro aim and turbo (queue). `mouse`: gyro aim
    /// moves the mouse instead of the right stick.
    private func applyAssist(_ state: inout winios_gamepad, mouse: Bool) {
        guard let assist else { return }
        var pad = AssistPad(buttons: state.buttons, lt: state.left_trigger, rt: state.right_trigger, rx: state.rx, ry: state.ry)
        if mouse && assist.gyro {
            gyroToMouse(assist, held: GyroAim.held(pad, assist.when))
        }
        var stickOnly = assist
        if mouse { stickOnly.gyro = false }
        let rates = stickOnly.gyro ? gyroRates(assist) : nil
        applyPadAssist(&pad, settings: stickOnly, rates: rates, turbo: &turboState, now: DispatchTime.now().uptimeNanoseconds)
        state.buttons = pad.buttons
        state.left_trigger = pad.lt; state.right_trigger = pad.rt
        state.rx = pad.rx; state.ry = pad.ry
    }

    /// Whether gyro aim moves the mouse for this sample of player 1: chosen, or
    /// automatic while the game sees no controller from the pad.
    private func gyroMouse(physical: Bool, touch: Bool) -> Bool {
        guard let assist, assist.gyro else { return false }
        switch assist.output {
        case .mouse: return true
        case .stick: return false
        case .auto: return keyboardMouse != nil || (!physical && !touch)
        }
    }

    private var gyroMouseCarry = MotionCarry()
    private var gyroMouseAt: UInt64 = 0
    private var gyroMouseMoving = false

    /// Gyro aim as relative mouse motion, by the time since the last sample (queue).
    private func gyroToMouse(_ assist: PadAssistSettings, held: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = gyroMouseAt == 0 ? 0 : min(Double(now &- gyroMouseAt) / 1e9, 1.0 / 15)
        gyroMouseAt = now
        guard held, HardwareInput.shared.baseFocused, !LibraryController.shared.ownsInput,
              let rates = gyroRates(assist) else {
            gyroMouseCarry.reset(); gyroMouseMoving = false
            return
        }
        let m = GyroAim.mouse(turn: rates.turn, pitch: rates.pitch, dt: dt, settings: assist)
        let d = gyroMouseCarry.add(m.dx, m.dy, gain: 1)
        guard d.dx != 0 || d.dy != 0 else { return }
        if !gyroMouseMoving {
            gyroMouseMoving = true
            DispatchQueue.main.async { HardwareInput.shared.stickMoved() }
        }
        HardwareInput.shared.postRelative(d.dx, d.dy)
    }

    private let queue = DispatchQueue(label: "madeira.gamepad", qos: .userInteractive)
    private var controllers = [GCController?](repeating: nil, count: 4)
    private var profiles = [GCExtendedGamepad?](repeating: nil, count: 4)
    private var timer: DispatchSourceTimer?
    private var active = false
    /// ml2100: player 1 goes to the HID controller (beginPadSession); queue-owned.
    private var hidActive = false
    /// MADEIRA_HIDPAD_XINPUT=1: player 1 stays an XInput pad as well.
    private var hidKeepsXInput = false
    private var hidBattery: (level: UInt8, charging: UInt8) = (UInt8(WINIOS_HIDPAD_BATTERY_UNKNOWN), 0)
    private var hidBatteryCountdown = 0
    /// ml2170: when each XInput slot's battery is read next (uptime ns); 0 = at once.
    private var batteryNextRead = [UInt64](repeating: 0, count: 4)
    private var batteryLogs = 0
    /// ml2172: uptime (ns) at which each slot's controller joined; 0 = empty.
    private var joinedAt = [UInt64](repeating: 0, count: 4)
    /// ml2172: player 1 back to slot 0 after a reconnect GameController reported
    /// as a new controller before the old one left (see refreshControllers).
    static let slot0Reconnect: Bool = flag("MADEIRA_XINPUT_SLOT0_RECONNECT")  // 0: a reconnected player 1 stays in the slot it landed in (slot 0 left empty)
    /// ml2190: every 2 s (and on each refresh) a controller whose extendedGamepad is no
    /// longer the profile its slot reads gets the live one; the old object can keep
    /// reporting buttons with its axes frozen at rest (device log 107: buttons and
    /// triggers reached the game, the sticks never left zero).
    static let profileCheck: Bool = flag("MADEIRA_XINPUT_PROFILE_CHECK")  // 0: a slot keeps the profile its controller had when it joined
    /// ml2190: the first 8 times each slot's sticks leave rest, with GameController's raw values.
    private static var stickDiagLeft = [8, 8, 8, 8]
    private static var stickDiagLive = [false, false, false, false]
    private var touchState = TouchGamepadState()
    @MainActor private var observers: [NSObjectProtocol] = []
    @MainActor private var started = false
    @MainActor private var profileTimer: Timer?

    @MainActor func start() {
        guard !started else { return }
        started = true
        LogStore.shared.log("[xinput] ml1920 physical controllers enabled=\(Self.enabled ? 1 : 0)")
        LogStore.shared.log("[touch-xinput] ml1930 enabled=\(Self.touchEnabled ? 1 : 0)")
        guard Self.enabled else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshControllers() }
            })
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setActive(false)
            })
        }
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshControllers() }
            self?.setActive(true)
        })
        refreshControllers()
        setActive(UIApplication.shared.applicationState == .active)
        if Self.profileCheck {
            profileTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshControllers() }
            }
        }
    }

    /// Slot i reads `profile`; its changes sample at once (queue-owned).
    private func attach(_ profile: GCExtendedGamepad, slot i: Int) {
        profiles[i]?.valueChangedHandler = nil
        profiles[i] = profile
        profile.valueChangedHandler = { [weak self] _, _ in
            // Explicit queue hop also serializes callbacks already in flight
            // when a controller is disconnected or the app resigns active.
            self?.queue.async { [weak self] in self?.sample() }
        }
    }

    @MainActor private func refreshControllers() {
        // Capture the live profile on main. Re-fetching extendedGamepad on the
        // polling queue yielded stale axes on devices tested in the fork.
        if controllerGyro { PadAssistSensors.setControllerGyro(true) }
        let live = GCController.controllers().compactMap { controller -> (GCController, GCExtendedGamepad)? in
            guard let profile = controller.extendedGamepad else { return nil }
            controller.handlerQueue = queue
            return (controller, profile)
        }
        queue.async { [self] in
            let now = DispatchTime.now().uptimeNanoseconds
            var slot0Freed = false
            for i in controllers.indices {
                guard let old = controllers[i], !live.contains(where: { $0.0 === old }) else { continue }
                profiles[i]?.valueChangedHandler = nil
                controllers[i] = nil
                profiles[i] = nil
                joinedAt[i] = 0
                if i == 0 { slot0Freed = true }
                // ml2106: a game's "motors off" for a pad that left is dropped (the
                // slot reads disconnected), so the slot's motors end here.
                winios_gamepad_set_vibration(Int32(i), 0, 0)
                clearBattery(i)
                fputs("[xinput] ml1920 slot=\(i) disconnected\n", stderr)
            }
            for (controller, profile) in live {
                if Self.profileCheck, let i = controllers.firstIndex(where: { $0 === controller }) {
                    if profiles[i] !== profile {
                        attach(profile, slot: i)
                        LogStore.shared.log("[xinput] ml2190 slot=\(i) controller has a new input profile: the slot reads the live one")
                    }
                    continue
                }
                guard !controllers.contains(where: { $0 === controller }),
                      let i = controllers.firstIndex(where: { $0 == nil }) else { continue }
                controllers[i] = controller
                joinedAt[i] = now
                // A pad joining a slot starts still, before sample() publishes it,
                // rather than replaying the level the slot had before.
                winios_gamepad_set_vibration(Int32(i), 0, 0)
                batteryNextRead[i] = 0   // ml2170: the new pad's battery at the next sample
                attach(profile, slot: i)
                fputs("[xinput] ml1920 slot=\(i) connected\n", stderr)
            }
            // ml2172: GameController can report a reconnecting pad as a new
            // controller before the old object leaves. The new one then lands in
            // slot 1 while slot 0 is still taken, slot 0 empties a moment later,
            // and a game that reads only player 1 sees nothing. When slot 0 has
            // just emptied and exactly one controller joined another slot in the
            // last 5 s, that controller becomes player 1 again. A second player's
            // pad that has been there longer keeps its slot.
            if slot0Freed, controllers[0] == nil, Self.slot0Reconnect {
                let recent = (1..<controllers.count).filter {
                    controllers[$0] != nil && joinedAt[$0] != 0 && now - joinedAt[$0] < 5_000_000_000
                }
                if recent.count == 1, let j = recent.first {
                    controllers[0] = controllers[j]; profiles[0] = profiles[j]; joinedAt[0] = joinedAt[j]
                    controllers[j] = nil; profiles[j] = nil; joinedAt[j] = 0
                    winios_gamepad_set_vibration(Int32(j), 0, 0)
                    winios_gamepad_set_vibration(0, 0, 0)
                    winios_gamepad_set_state(Int32(j), nil)
                    clearBattery(j)
                    batteryNextRead[0] = 0
                    LogStore.shared.log("[xinput] ml2172 slot=\(j) moved to slot 0: player 1 reconnected as a new controller")
                }
            }
            // ml2106: the pad in each slot is where that slot's rumble plays
            // (and slot 0's the DualSense output); unchanged slots are no-ops.
            for i in controllers.indices { madeira_pad_output_set_slot(Int32(i), controllers[i]) }
            updateTimer()
            sample()
        }
    }

    private func setActive(_ value: Bool) {
        // ml2106: motors stop and adaptive triggers go off while the app is
        // inactive; the game's last state comes back with it.
        madeira_pad_output_set_active(value ? 1 : 0)
        queue.async { [self] in
            active = value
            if !value {
                touchState.clear()
                if keyboardMouse != nil { PadKeyboardMouse.shared.releaseAll("inactive") }
            }
            updateTimer()
            sample()
        }
    }

    private func updateTimer() {
        // Touch play with gyro aim (the device's gyro) or turbo is polled as a pad is.
        // So is gyro aim moving the mouse with no controller at all.
        let mouseGyro = assist.map { $0.gyro && $0.output != .stick } ?? false
        let needed = active && (profiles.contains(where: { $0 != nil }) || (assist != nil && (touchState.connected || mouseGyro)))
        if !needed { timer?.cancel(); timer = nil; return }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.sample() }
        timer = source
        source.resume()
    }

    /// ml2180: per-slot diagnostic budget (first 16 rest/input transitions) and last state.
    private static var diagLeft = [16, 16, 16, 16]
    private static var diagLive = [false, false, false, false]
    // XInput leaves dead zones to the game. Preserve the complete signed range.
    static func axis(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        let clamped = max(-1, min(1, value))
        return Int16((clamped * (clamped < 0 ? 32768 : 32767)).rounded())
    }
    static func trigger(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((max(0, min(1, value)) * 255).rounded())
    }

    private func sample() {
        for i in profiles.indices {
            let pad = profiles[i]
            let touchConnected = i == 0 && touchState.connected
            // Player 1's pad went away mid-press: nothing feeds the driver now, so
            // release the keys and buttons it holds.
            if i == 0, pad == nil, keyboardMouse != nil, PadKeyboardMouse.shared.holding {
                PadKeyboardMouse.shared.releaseAll("controller disconnected")
            }
            let hid = i == 0 && hidActive
            guard pad != nil || touchConnected else {
                // No controller for the game: gyro aim can still move the mouse
                // (with nothing to hold, only "Always" does).
                if i == 0, active, let assist, gyroMouse(physical: false, touch: false) {
                    gyroToMouse(assist, held: assist.when == .always)
                }
                winios_gamepad_set_state(Int32(i), nil)
                clearBattery(i)
                if hid { winios_hidpad_set_state(nil) }
                continue
            }
            var state = winios_gamepad()
            state.connected = 1
            // Gyro aim and turbo apply once to player 1: before the keyboard-and-mouse
            // feed, else after the touch merge; never while the library owns input.
            var assisted = i != 0 || !active
            // ml2100: the pad whose HID-only inputs (touchpad click) this sample
            // carries; nil while the app is inactive or the library owns input.
            var hidLive: GCExtendedGamepad?
            // Keep the connected identity, but release all controls while the
            // app is inactive. A delayed callback cannot republish a held key.
            if active, let pad {
                hidLive = hid ? pad : nil
                let buttons: [(GCControllerButtonInput?, UInt16)] = [
                    (pad.dpad.up, 0x0001), (pad.dpad.down, 0x0002),
                    (pad.dpad.left, 0x0004), (pad.dpad.right, 0x0008),
                    (pad.buttonMenu, 0x0010), (pad.buttonOptions, 0x0020),
                    (pad.leftThumbstickButton, 0x0040), (pad.rightThumbstickButton, 0x0080),
                    (pad.leftShoulder, 0x0100), (pad.rightShoulder, 0x0200),
                    (pad.buttonHome, 0x0400), (pad.buttonA, 0x1000),
                    (pad.buttonB, 0x2000), (pad.buttonX, 0x4000), (pad.buttonY, 0x8000)
                ]
                for (button, mask) in buttons where button?.isPressed == true { state.buttons |= mask }
                state.left_trigger = Self.trigger(pad.leftTrigger.value)
                state.right_trigger = Self.trigger(pad.rightTrigger.value)
                state.lx = Self.axis(pad.leftThumbstick.xAxis.value)
                state.ly = Self.axis(pad.leftThumbstick.yAxis.value)
                state.rx = Self.axis(pad.rightThumbstick.xAxis.value)
                state.ry = Self.axis(pad.rightThumbstick.yAxis.value)
                if Self.stickDiagLeft[i] > 0 {
                    let moved = abs(Int(state.lx)) > 7849 || abs(Int(state.ly)) > 7849
                        || abs(Int(state.rx)) > 8689 || abs(Int(state.ry)) > 8689
                    if moved != Self.stickDiagLive[i] {
                        Self.stickDiagLive[i] = moved
                        if moved {
                            Self.stickDiagLeft[i] -= 1
                            LogStore.shared.log("[xinput] ml2190 app slot=\(i) sticks: left \(pad.leftThumbstick.xAxis.value),\(pad.leftThumbstick.yAxis.value) right \(pad.rightThumbstick.xAxis.value),\(pad.rightThumbstick.yAxis.value)")
                        }
                    }
                }
                // The library front end navigates with player 1's pad (Library.swift).
                // While it owns input (no session, or its menu is open) the game
                // sees a connected pad at rest.
                if i == 0 {
                    let library = LibraryController.shared
                    library.sample(buttons: state.buttons, lx: state.lx, ly: state.ly)
                    if library.ownsInput {
                        state = winios_gamepad()
                        state.connected = 1
                        hidLive = nil
                        assisted = true
                        if keyboardMouse != nil { PadKeyboardMouse.shared.releaseAll("library menu") }
                    } else if let kbm = keyboardMouse {
                        applyAssist(&state, mouse: gyroMouse(physical: true, touch: touchConnected))
                        assisted = true
                        // Keyboard-and-mouse mode: the pad becomes keys and mouse
                        // motion; XInput sees no physical player 1 (touch may still
                        // connect it below). The HID controller, when on, likewise
                        // stays but gets none of the physical pad's input.
                        PadKeyboardMouse.shared.feed(buttons: state.buttons, lt: state.left_trigger, rt: state.right_trigger,
                                                     lx: state.lx, ly: state.ly, rx: state.rx, ry: state.ry,
                                                     bindings: kbm, focused: HardwareInput.shared.baseFocused)
                        hidLive = nil
                        guard touchConnected else {
                            winios_gamepad_set_state(Int32(i), nil)
                            if hid { winios_hidpad_set_state(nil) }
                            continue
                        }
                        state = winios_gamepad()
                        state.connected = 1
                    }
                }
            }
            if active && touchConnected {
                let physical = GamepadSample(buttons: state.buttons,
                    lt: state.left_trigger, rt: state.right_trigger,
                    lx: state.lx, ly: state.ly, rx: state.rx, ry: state.ry)
                let merged = GamepadSample.merge(physical: physical, touch: touchState.sample)
                state.buttons = merged.buttons
                state.left_trigger = merged.lt; state.right_trigger = merged.rt
                state.lx = merged.lx; state.ly = merged.ly; state.rx = merged.rx; state.ry = merged.ry
            }
            if !assisted && !LibraryController.shared.ownsInput {
                applyAssist(&state, mouse: gyroMouse(physical: pad != nil, touch: touchConnected))
            }
            if hid {
                publishHID(state, live: hidLive, pad: pad)
                // One controller, one API: player 1 is not also an XInput pad,
                // as a DualSense on Windows is not (MADEIRA_HIDPAD_XINPUT=1 keeps both).
                if !hidKeepsXInput {
                    winios_gamepad_set_state(Int32(i), nil)
                    continue
                }
            }
            // ml2180: evidence for "the pad is detected but nothing happens": the
            // first transitions between rest and input per slot, as published to
            // win32u (the driver logs what the program reads, ml2180 there).
            if Self.diagLeft[i] > 0 {
                let live = state.buttons != 0 || state.left_trigger != 0 || state.right_trigger != 0
                    || abs(Int(state.lx)) > 7849 || abs(Int(state.ly)) > 7849
                    || abs(Int(state.rx)) > 8689 || abs(Int(state.ry)) > 8689
                if live != Self.diagLive[i] {
                    Self.diagLive[i] = live
                    Self.diagLeft[i] -= 1
                    let kind = live ? "input" : "rest"
                    let owns = i == 0 ? LibraryController.shared.ownsInput : false
                    LogStore.shared.log("[xinput] ml2180 app slot=\(i) \(kind): buttons=0x\(String(state.buttons, radix: 16)) lt=\(state.left_trigger) rt=\(state.right_trigger) lx=\(state.lx) ly=\(state.ly) rx=\(state.rx) ry=\(state.ry) physical=\(pad != nil) active=\(active) libraryOwns=\(owns) kbm=\(keyboardMouse != nil) hid=\(hid)")
                }
            }
            publishBattery(i, pad: pad)
            winios_gamepad_set_state(Int32(i), &state)
        }
    }

    /// ml2170: slot i's XInput battery, read from GameController at most once a
    /// second (queue). A physical pad reports its GCDeviceBattery; the touch
    /// controller alone has no battery to run down and reads as wired and full.
    private func publishBattery(_ i: Int, pad: GCExtendedGamepad?) {
        guard Self.batteryEnabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= batteryNextRead[i] else { return }
        batteryNextRead[i] = now + 1_000_000_000
        var value = winios_gamepad_battery()
        value.valid = 1
        if let pad {
            let battery = pad.controller?.battery
            let mapped = Self.xinputBattery(level: battery?.batteryLevel, state: battery?.batteryState)
            value.type = mapped.type
            value.level = mapped.level
        } else {
            value.type = UInt8(WINIOS_BATTERY_TYPE_WIRED)
            value.level = UInt8(WINIOS_BATTERY_LEVEL_FULL)
        }
        if winios_gamepad_set_battery(Int32(i), &value) != 0 && batteryLogs < 32 {
            batteryLogs += 1
            LogStore.shared.log("[xinput] ml2170 slot=\(i) battery type=\(value.type) level=\(value.level)")
        }
    }

    /// ml2170: the slot has no pad, so its battery is withdrawn (op 4 answers 0).
    private func clearBattery(_ i: Int) {
        guard batteryNextRead[i] != 0 else { return }
        batteryNextRead[i] = 0
        _ = winios_gamepad_set_battery(Int32(i), nil)
    }

    /// ml2100: player 1 as the HID controller reports it: the XInput sample above
    /// (touch merge and library ownership included) plus what only a HID report
    /// carries. L2/R2's digital bits follow the merged analogue value, so touch
    /// triggers set them too. The battery is read once a second.
    private func publishHID(_ state: winios_gamepad, live: GCExtendedGamepad?, pad: GCExtendedGamepad?) {
        var hid = winios_hidpad()
        hid.connected = 1
        hid.buttons = UInt32(state.buttons)
        hid.lx = state.lx; hid.ly = state.ly; hid.rx = state.rx; hid.ry = state.ry
        hid.left_trigger = state.left_trigger; hid.right_trigger = state.right_trigger
        if state.left_trigger > 25 { hid.buttons |= WINIOS_HIDPAD_L2 }
        if state.right_trigger > 25 { hid.buttons |= WINIOS_HIDPAD_R2 }
        if let live {
            let touchpad = (live as? GCDualSenseGamepad)?.touchpadButton ?? (live as? GCDualShockGamepad)?.touchpadButton
            if touchpad?.isPressed == true { hid.buttons |= WINIOS_HIDPAD_TOUCHPAD }
        }
        if hidBatteryCountdown <= 0 {
            hidBatteryCountdown = 250
            if let battery = pad?.controller?.battery {
                let fraction = battery.batteryLevel.isFinite ? battery.batteryLevel : 0
                let level = UInt8(max(0, min(100, (fraction * 100).rounded())))
                let charging: UInt8 = battery.batteryState == .charging ? 1 : battery.batteryState == .full ? 2 : 0
                hidBattery = battery.batteryState == .unknown ? (UInt8(WINIOS_HIDPAD_BATTERY_UNKNOWN), 0) : (level, charging)
            } else {
                hidBattery = (UInt8(WINIOS_HIDPAD_BATTERY_UNKNOWN), 0)
            }
        }
        hidBatteryCountdown -= 1
        hid.battery = hidBattery.level
        hid.charging = hidBattery.charging
        winios_hidpad_set_state(&hid)
    }
}

/// iOS 18 otherwise routes stick input into UIKit/SwiftUI focus navigation.
struct ClaimGamepadEvents: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), GamepadInput.enabled {
            content.handlesGameControllerEvents(matching: .gamepad)
        } else { content }
    }
}

enum GamepadEventClaim {
    @MainActor static func install(on view: UIView) {
        guard GamepadInput.enabled else { return }
        if #available(iOS 18.0, *) {
            guard !view.interactions.contains(where: { $0 is GCEventInteraction }) else { return }
            let interaction = GCEventInteraction()
            interaction.handledEventTypes = .gamepad
            view.addInteraction(interaction)
        }
    }
}
