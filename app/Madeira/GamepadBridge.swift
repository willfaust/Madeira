import Foundation
import Dispatch
import GameController

/// Turns a physical controller into input the guest already understands.
///
/// There is no XInput in this build and there cannot be one from this file:
/// the guest sees a gamepad only if something on the wine side presents a HID
/// device or an XInput stub, and that work lives in the wine submodule and
/// build/, not in this target. The `ControlAction.pad` bindings in the mapping
/// panel stay inert for exactly that reason — do not wire them here.
///
/// What this does instead is the thing that works today. It maps the controller
/// onto virtual keys and pointer motion through `winios_post_key` and
/// `winios_pointer`, the same two calls the key buttons, the on-screen stick and
/// the S2 trackpad already use, so any game that accepts keyboard and mouse
/// accepts the controller — including mouse-look on the right stick. A game that
/// accepts ONLY XInput still will not see it, and no amount of work on this side
/// changes that.
///
/// The on-screen PlayStation-style pad (`VirtualPadView`) is the same kind of
/// source and goes through this same class, not a parallel one: one differ means
/// one opinion about what is held down. See `setVirtual`.
///
/// Opt out, or rebind anything, with `Documents/madeira-gamepad.txt`; see
/// GamepadSettings. A connected controller is taken as intent, so the default
/// is on — a gamepad plugged in and ignored is the more surprising behaviour.
final class GamepadBridge {
    static let shared = GamepadBridge()

    /// Pointer motion goes through the same relative path the trackpad's
    /// mouse-look mode uses, so these are raw MOUSEEVENTF_* flags rather than a
    /// position. Posting a position is what makes a game that calls ClipCursor
    /// spin; see MetalBackedView.touchesMoved.
    private let F_MOVE: UInt32 = 0x1
    private let F_LDOWN: UInt32 = 0x2, F_LUP: UInt32 = 0x4
    private let F_RDOWN: UInt32 = 0x8, F_RUP: UInt32 = 0x10

    /// 60fps: the same cadence the panel refreshes at, and well above the
    /// ~250ms a human notices on a look stick.
    private let tickInterval: TimeInterval = 1.0 / 60.0

    private var settings = GamepadSettings()
    private var timer: Timer?
    private var previous = GamepadOutput()
    /// The on-screen pad's current frame. Empty until a thumb lands on it.
    private var virtual = GamepadInput()
    /// Same reason as MetalBackedView.relCarry: at full tilt a stick moves far
    /// less than a pixel per frame at low mouse speeds, and truncating the
    /// fraction would make gentle mouse-look do nothing at all.
    private var carryX = 0.0, carryY = 0.0

    private init() {}

    /// Start watching for controllers. Safe to call more than once.
    func start() {
        loadSettings()
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) {
            [weak self] _ in self?.refresh()
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) {
            [weak self] _ in self?.refresh()
        }
        refresh()
    }

    /// One line for the log and the UI.
    var summary: String {
        let pad = virtualActive ? " + on-screen pad" : ""
        if !settings.enabled && !virtualActive {
            return "controller: off (madeira-gamepad.txt)"
        }
        guard let c = controller else { return "controller: no gamepad connected\(pad)" }
        return "controller: \(c.vendorName ?? "gamepad") → keyboard + pointer\(pad)"
    }

    /// Hand the on-screen pad's current frame to the bridge.
    ///
    /// The same path as a physical controller on purpose: `GamepadMap` turns
    /// this into the same keys and the same pointer motion, so the pad needs no
    /// input path of its own and a game cannot tell the two apart. Called from
    /// the pad's gestures, on the main thread.
    ///
    /// Main-thread only, because it starts and stops a `Timer` on the main run
    /// loop and reads the same `previous` frame `tick` writes.
    func setVirtual(_ input: GamepadInput) {
        dispatchPrecondition(condition: .onQueue(.main))
        virtual = input
        // Starting the tick here is what makes the pad work with no controller
        // paired at all; stopping it is what releases the last held key, since
        // nothing else would.
        refresh()
    }

    /// True while the on-screen pad is asking for input.
    private var virtualActive: Bool {
        !virtual.buttons.isEmpty
            || virtual.leftX != 0 || virtual.leftY != 0
            || virtual.rightX != 0 || virtual.rightY != 0
    }

    // MARK: - plumbing

    /// Only controllers we can actually read. A controller with neither an
    /// extended nor a micro profile would otherwise start a tick that posts
    /// nothing forever.
    private var controller: GCController? {
        GCController.controllers().first {
            $0.extendedGamepad != nil || $0.microGamepad != nil
        }
    }

    private func loadSettings() {
        guard let text = documentsFile("madeira-gamepad.txt") else { return }
        let parsed = GamepadSettings.parse(text)
        settings = parsed.settings
        for problem in parsed.problems {
            // stderr, like every other bridge report in this app, so a typo in
            // a file pushed over a cable explains itself in the log.
            fputs("[gamepad] madeira-gamepad.txt: \(problem)\n", stderr)
        }
    }

    private func refresh() {
        guard physical != nil || virtualActive else {
            stop()
            return
        }
        guard timer == nil else { return }
        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common, or the tick stops while the log list is being scrolled.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        fputs("[gamepad] \(summary)\n", stderr)
    }

    /// The paired controller, when one may be read at all.
    ///
    /// ENABLED=0 in `madeira-gamepad.txt` turns the physical controller off; the
    /// on-screen pad is a separate switch in Settings and keeps working, because
    /// a user who turned off a gamepad they are not holding has not asked for
    /// the touch controls to go away.
    private var physical: GCController? {
        settings.enabled ? controller : nil
    }

    /// Release everything and stop.
    ///
    /// The release is the important half: once the controller is gone there is
    /// no other event that could lift a key it was holding, so a disconnect
    /// mid-run would leave the guest walking into a wall forever.
    private func stop() {
        timer?.invalidate()
        timer = nil
        post(from: previous, to: GamepadOutput())
        previous = GamepadOutput()
        carryX = 0
        carryY = 0
    }

    private func tick() {
        // The tick can outlive its sources: the pad may have been hidden and the
        // controller unplugged between two frames, and there is nothing left to
        // read. `stop()` releases whatever the last frame was holding.
        guard physical != nil || virtualActive else { stop(); return }

        var frame = virtual
        if let c = physical {
            frame = GamepadInput.merged(input(from: c), virtual)
        }
        let next = GamepadMap.output(for: frame,
                                     bindings: settings.bindings,
                                     mouseSpeed: settings.mouseSpeed)
        post(from: previous, to: next)
        previous = next

        // Pointer motion is per-frame, not an edge, so it stays out of the diff.
        carryX += next.mouseDX
        carryY += next.mouseDY
        let dx = Int32(max(-30000, min(30000, carryX)))
        let dy = Int32(max(-30000, min(30000, carryY)))
        carryX -= Double(dx)
        carryY -= Double(dy)
        if dx != 0 || dy != 0 { winios_pointer(dx, dy, F_MOVE, 0) }
    }

    /// Press what newly is, release what no longer is.
    ///
    /// Never a blanket release/re-press: a held direction would stutter as the
    /// stick wanders, and re-pressing a key on every frame is not the same input
    /// as holding it down. Same shape as JoystickKeyView.apply.
    private func post(from old: GamepadOutput, to new: GamepadOutput) {
        for vk in old.keys.subtracting(new.keys) { winios_post_key(vk, 0) }
        for vk in new.keys.subtracting(old.keys) { winios_post_key(vk, 1) }
        if old.leftMouse != new.leftMouse {
            winios_pointer(0, 0, new.leftMouse ? F_LDOWN : F_LUP, 0)
        }
        if old.rightMouse != new.rightMouse {
            winios_pointer(0, 0, new.rightMouse ? F_RDOWN : F_RUP, 0)
        }
    }

    /// Flatten a controller into `GamepadInput`.
    ///
    /// Reads the axes as reported: GameController already gives a thumbstick
    /// +1 for up, which is the sense GamepadMap is written in.
    private func input(from c: GCController) -> GamepadInput {
        var i = GamepadInput()
        if let g = c.extendedGamepad {
            if g.buttonA.isPressed { i.buttons.insert(.a) }
            if g.buttonB.isPressed { i.buttons.insert(.b) }
            if g.buttonX.isPressed { i.buttons.insert(.x) }
            if g.buttonY.isPressed { i.buttons.insert(.y) }
            if g.dpad.up.isPressed    { i.buttons.insert(.up) }
            if g.dpad.down.isPressed  { i.buttons.insert(.down) }
            if g.dpad.left.isPressed  { i.buttons.insert(.left) }
            if g.dpad.right.isPressed { i.buttons.insert(.right) }
            if g.leftShoulder.isPressed  { i.buttons.insert(.lb) }
            if g.rightShoulder.isPressed { i.buttons.insert(.rb) }
            if g.leftTrigger.isPressed   { i.buttons.insert(.lt) }
            if g.rightTrigger.isPressed  { i.buttons.insert(.rt) }
            if g.leftThumbstickButton?.isPressed == true  { i.buttons.insert(.ls) }
            if g.rightThumbstickButton?.isPressed == true { i.buttons.insert(.rs) }
            if g.buttonMenu.isPressed { i.buttons.insert(.menu) }
            if g.buttonOptions?.isPressed == true { i.buttons.insert(.view) }
            i.leftX  = Double(g.leftThumbstick.xAxis.value)
            i.leftY  = Double(g.leftThumbstick.yAxis.value)
            i.rightX = Double(g.rightThumbstick.xAxis.value)
            i.rightY = Double(g.rightThumbstick.yAxis.value)
        } else if let m = c.microGamepad {
            // Siri Remote and MFi pads without sticks: the touch surface is the
            // only direction source, and there is no look axis to read.
            if m.buttonA.isPressed { i.buttons.insert(.a) }
            if m.buttonX.isPressed { i.buttons.insert(.x) }
            if m.dpad.up.isPressed    { i.buttons.insert(.up) }
            if m.dpad.down.isPressed  { i.buttons.insert(.down) }
            if m.dpad.left.isPressed  { i.buttons.insert(.left) }
            if m.dpad.right.isPressed { i.buttons.insert(.right) }
            if m.buttonMenu.isPressed { i.buttons.insert(.menu) }
            i.leftX = Double(m.dpad.xAxis.value)
            i.leftY = Double(m.dpad.yAxis.value)
        }
        return i
    }
}
