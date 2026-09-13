import Foundation

/// A physical controller button, in our own vocabulary.
///
/// Deliberately not GameController's types. This file is the part of gamepad
/// support that can be reasoned about and tested without a controller, an iPad
/// or the framework, and it should not need any of the three to compile.
/// `GamepadBridge` is the only thing that speaks GCController.
enum GamepadButton: String, CaseIterable {
    case a, b, x, y
    case up, down, left, right
    case lb, rb, lt, rt
    case ls, rs
    case menu, view
}

/// What a controller button does.
enum GamepadBinding: Equatable {
    /// A Windows virtual-key code — the same vocabulary keyButton and
    /// holdKeyButton already post through `winios_post_key`.
    case key(Int32)
    case leftMouse
    case rightMouse
    case nothing

    /// Parse one binding word. Nil for anything unrecognised, so a typo is
    /// reported instead of silently becoming "this button does nothing" —
    /// which is indistinguishable from a dead controller.
    static func parse(_ raw: String) -> GamepadBinding? {
        switch raw.uppercased() {
        case "LMB", "LEFT", "MOUSELEFT":   return .leftMouse
        case "RMB", "RIGHT", "MOUSERIGHT": return .rightMouse
        case "NONE", "-":                  return .nothing
        default: break
        }
        var t = raw.uppercased()
        if t.hasPrefix("VK") { t = String(t.dropFirst(2)) }
        if t.hasPrefix("0X"), let v = Int32(t.dropFirst(2), radix: 16) { return .key(v) }
        if let v = Int32(t) { return .key(v) }
        return nil
    }
}

/// One frame of controller state, normalised.
struct GamepadInput: Equatable {
    var buttons: Set<GamepadButton> = []
    /// Sticks, -1...1, `y` positive UP — which is what GameController already
    /// reports for a thumbstick, so nothing flips anything on the way in. It is
    /// also the sense JoystickKeyView's snap works in, once its UIKit
    /// translation is negated, so the two steer identically.
    var leftX = 0.0, leftY = 0.0
    var rightX = 0.0, rightY = 0.0
}

extension GamepadInput {
    /// Combine two input sources into one frame.
    ///
    /// The on-screen pad and a paired controller are both live at once, and the
    /// bridge posts through a single differ — two differs would fight over the
    /// same key and whichever ran last would win, so a key held on one source
    /// would flicker. Merging here instead makes "both want space" and "neither
    /// does" the only two states that matter.
    ///
    /// Buttons union, because either source may hold a key. An axis takes
    /// whichever source is pushed further, so a thumb resting on an idle pad
    /// stick cannot cancel a controller stick that is actually being used.
    static func merged(_ a: GamepadInput, _ b: GamepadInput) -> GamepadInput {
        var out = GamepadInput()
        out.buttons = a.buttons.union(b.buttons)
        (out.leftX, out.leftY) = pick(a.leftX, a.leftY, b.leftX, b.leftY)
        (out.rightX, out.rightY) = pick(a.rightX, a.rightY, b.rightX, b.rightY)
        return out
    }

    /// The stronger of two axis pairs, compared by distance from centre.
    private static func pick(_ ax: Double, _ ay: Double,
                             _ bx: Double, _ by: Double) -> (Double, Double) {
        (ax * ax + ay * ay) >= (bx * bx + by * by) ? (ax, ay) : (bx, by)
    }
}


/// Everything the bridge posts for one frame of controller state.
struct GamepadOutput: Equatable {
    /// Held virtual keys, from buttons and from the movement stick. A Set, so
    /// two buttons bound to the same key release it only when BOTH are up.
    var keys: Set<Int32> = []
    var leftMouse = false
    var rightMouse = false
    /// Pointer motion for this frame, in desktop pixels. Fractional on purpose:
    /// at 60fps a gentle stick push is well under one pixel per frame, so the
    /// bridge carries the remainder exactly as the trackpad's relative mode
    /// does — truncating here would make slow mouse-look dead.
    ///
    /// The y sign is the mouse's, not the stick's: mouse coordinates grow
    /// DOWNWARD, so pushing the look stick up produces a NEGATIVE dy. That is
    /// the same sign MetalBackedView posts when a finger drags up.
    var mouseDX = 0.0, mouseDY = 0.0
}

/// Full configuration, parsed from `Documents/madeira-gamepad.txt`.
struct GamepadSettings: Equatable {
    var enabled = true
    var mouseSpeed = 1.0
    var bindings = GamepadMap.defaultBindings

    /// Parse the override file. Follows `DeviceCapabilities.fexConfigEntries`:
    /// pure, tolerant of comments and blank lines, and returns the problems
    /// rather than throwing, because the file is typed on a desktop and pushed
    /// over a cable and a silent no-op costs a debugging session.
    static func parse(_ text: String) -> (settings: GamepadSettings, problems: [String]) {
        var s = GamepadSettings()
        var problems: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(separator: "#", maxSplits: 1,
                                     omittingEmptySubsequences: false)[0]
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[0].isEmpty else { continue }

            switch parts[0].uppercased() {
            case "ENABLED":
                if let v = Int(parts[1]) { s.enabled = v != 0 }
                else { problems.append("ENABLED: '\(parts[1])' is not a number") }
            case "MOUSE_SPEED":
                if let v = Double(parts[1]) { s.mouseSpeed = v }
                else { problems.append("MOUSE_SPEED: '\(parts[1])' is not a number") }
            default:
                guard let b = GamepadButton(rawValue: parts[0].lowercased()) else {
                    problems.append("\(parts[0]): not a button name")
                    continue
                }
                if let bind = GamepadBinding.parse(parts[1]) {
                    s.bindings[b] = bind
                } else {
                    problems.append("\(parts[0]): '\(parts[1])' is not a VK, LMB, RMB or NONE")
                }
            }
        }
        return (s, problems)
    }
}

/// Pure mapping from controller state to guest input.
enum GamepadMap {
    /// A stick has to leave this fraction of its travel before it counts as a
    /// direction. Same idea as JoystickKeyView's 14pt deadzone: without it a
    /// resting stick with a little drift walks you into a wall forever.
    static let deadzone = 0.35

    /// Movement is not remappable, and that is on purpose: it is the contract
    /// every Windows game already has with the arrow keys, and it is the same
    /// eight-way snap JoystickKeyView uses, so anything playable with the
    /// on-screen stick is playable with a real one.
    static let vkUp: Int32 = 0x26, vkDown: Int32 = 0x28
    static let vkLeft: Int32 = 0x25, vkRight: Int32 = 0x27

    /// The shipped bindings. A game that wants something else gets the override
    /// file; these are chosen to be usable on a desktop as well as in a game,
    /// so a controller alone can drive the thing without the touch pad.
    static let defaultBindings: [GamepadButton: GamepadBinding] = [
        .a:    .key(0x20),      // space — jump/confirm in most games
        .b:    .key(0x1B),      // esc  — back/cancel
        .x:    .leftMouse,      // fire, in anything mouse-look driven
        .y:    .rightMouse,
        .lb:   .key(0x09),      // tab
        .rb:   .key(0x52),      // r
        .lt:   .key(0x10),      // shift
        .rt:   .key(0x11),      // ctrl
        .ls:   .nothing,
        .rs:   .nothing,
        .menu: .key(0x1B),      // esc
        .view: .key(0x09),      // tab
        // The d-pad belongs to the movement block below, not to this table: it
        // shares the arrow keys with the left stick so the two can never
        // disagree. They are named here as `nothing` so nobody goes looking for
        // a binding that was never meant to be one.
        .up: .nothing, .down: .nothing, .left: .nothing, .right: .nothing,
    ]

    /// Eight-way snap, clockwise from up (0 = up, 2 = right, 4 = down, 6 =
    /// left). -1 means centred.
    ///
    /// Identical geometry to JoystickKeyView.snap, expressed with y positive up
    /// so it can be tested without a UIKit translation.
    static func direction(x: Double, y: Double,
                          deadzone: Double = GamepadMap.deadzone) -> Int {
        if (x * x + y * y).squareRoot() < deadzone { return -1 }
        var a = atan2(x, y) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    /// Arrow keys for a snapped direction. Diagonals hold two at once.
    static func directionKeys(_ d: Int) -> [Int32] {
        switch d {
        case 0: return [vkUp]
        case 1: return [vkUp, vkRight]
        case 2: return [vkRight]
        case 3: return [vkDown, vkRight]
        case 4: return [vkDown]
        case 5: return [vkDown, vkLeft]
        case 6: return [vkLeft]
        case 7: return [vkUp, vkLeft]
        default: return []
        }
    }

    /// Axis value with the deadzone removed and the remainder rescaled, so
    /// pointer motion starts from zero at the edge of the deadzone instead of
    /// jumping to it. Used for the mouse-look stick, which is continuous and
    /// must NOT be snapped to eight directions.
    static func scaled(_ v: Double, deadzone: Double = GamepadMap.deadzone) -> Double {
        if abs(v) <= deadzone { return 0 }
        let trimmed = abs(v) - deadzone
        return (v < 0 ? -trimmed : trimmed) / (1 - deadzone)
    }

    /// Desktop pixels per frame at full deflection. Tuned to a 60fps tick;
    /// MOUSE_SPEED scales it.
    static let mousePixelsPerFrame = 18.0

    static func output(for input: GamepadInput,
                       bindings: [GamepadButton: GamepadBinding] = GamepadMap.defaultBindings,
                       mouseSpeed: Double = 1.0) -> GamepadOutput {
        var out = GamepadOutput()

        // Movement. The stick wins when it is off centre; the d-pad fills in
        // when it is not, because two things that both mean "walk" must not be
        // able to disagree.
        var movement = Set(directionKeys(direction(x: input.leftX, y: input.leftY)))
        if movement.isEmpty {
            if input.buttons.contains(.up)    { movement.insert(vkUp) }
            if input.buttons.contains(.down)  { movement.insert(vkDown) }
            if input.buttons.contains(.left)  { movement.insert(vkLeft) }
            if input.buttons.contains(.right) { movement.insert(vkRight) }
        }
        out.keys.formUnion(movement)

        for button in GamepadButton.allCases {
            switch bindings[button] ?? .nothing {
            case .key(let vk):
                if input.buttons.contains(button) { out.keys.insert(vk) }
            case .leftMouse:
                if input.buttons.contains(button) { out.leftMouse = true }
            case .rightMouse:
                if input.buttons.contains(button) { out.rightMouse = true }
            case .nothing:
                break
            }
        }

        // Mouse look. Right stick, relative motion, through the same
        // MOUSEEVENTF_MOVE path the S2 trackpad's relative mode uses — posting
        // device motion rather than a position is what stops a game that calls
        // ClipCursor from spinning (see MetalBackedView.touchesMoved).
        //
        // y is negated because the two axes disagree about which way is up:
        // the stick reports +1 for up, mouse coordinates count upward as
        // negative. Without this the look axis is inverted, which reads as a
        // "controller is fine, game is broken" bug.
        out.mouseDX = scaled(input.rightX) * mousePixelsPerFrame * mouseSpeed
        out.mouseDY = -scaled(input.rightY) * mousePixelsPerFrame * mouseSpeed
        return out
    }
}
