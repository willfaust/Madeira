import SwiftUI
import UIKit

/// Live state for the on-screen pad.
///
/// This exists because the pad cannot be a SwiftUI child of the game view: the
/// game surface is a window-level `UIView` inserted ABOVE the whole SwiftUI
/// hierarchy (see `MetalHostView`), so anything drawn underneath it is simply
/// covered. The pad is therefore hosted in its own window — which also means it
/// cannot read `ContentView`'s state, and needs somewhere shared to live.
///
/// Three readers, one object: the overlay draws from it,
/// `VirtualPadTouchView` assigns fingers from it, and `VirtualPadWindow`
/// decides whether a touch belongs to the pad or to the game with it. The
/// drawn button and the claimed touch region therefore cannot drift apart.
final class VirtualPadState: ObservableObject {
    static let shared = VirtualPadState()

    /// Is the pad up? Written by the overlay, read by the window's hit test.
    @Published private(set) var visible = false
    /// Set once the overlay window exists, so "always" has somewhere to draw.
    @Published private(set) var attached = false
    /// 0.2...1. Mirrored from settings for the same reason as `visible`.
    @Published var opacity = VirtualPadLayout.defaultOpacity
    /// What the last frame drew: knob positions and held-button highlights.
    @Published private(set) var axes: [PadStick: PadAxis] = [:]
    @Published private(set) var held: Set<GamepadButton> = []

    /// The window the pad draws in, published by the touch layer.
    ///
    /// One source for the geometry, deliberately: the drawing, the window's
    /// pass-through decision and the touch layer's hit test all read this rect,
    /// so a button can never be drawn somewhere other than where a thumb has to
    /// press. Two independent sources (this view's bounds and a SwiftUI
    /// GeometryReader's) can differ by a safe-area inset, and that difference is
    /// exactly the report "the pad is drawn but nothing happens".
    @Published private(set) var bounds: CGSize = .zero

    func setBounds(_ next: CGSize) {
        guard next != bounds, next.width > 0, next.height > 0 else { return }
        bounds = next
    }

    /// The layout for the current bounds. Derived, never stored, so it cannot
    /// go stale against `bounds` or the immersive chrome inset.
    var controls: [PadControl] {
        VirtualPadLayout.controls(for: bounds, topInset: GameChromeState.shared.topInset)
    }

    /// The control a hit names, so the touch layer can measure a stick from
    /// its own centre without re-deriving the table.
    func control(for hit: PadHit) -> PadControl? {
        controls.first { $0.hit == hit }
    }

    private var touches = VirtualPadTouchState()

    private init() {}

    func markAttached() { attached = true }

    func setVisible(_ next: Bool) {
        guard next != visible else { return }
        visible = next
        // Hiding is the one case where nothing else will lift a held key: the
        // touch that would have ended is gone with the view.
        if !next { releaseAll() }
        fputs("[pad] on-screen pad \(next ? "shown" : "hidden")\n", stderr)
    }

    /// Does the pad own this window point? Read by both windows so the pad's
    /// region and the game's cannot overlap, and by the touch layer for the same
    /// reason.
    ///
    /// `fallback` is the caller's own bounds and is used only until the touch
    /// layer has laid out. After that the touch layer's rect wins for every
    /// caller, which is what keeps the drawn pad and the touching thumb on the
    /// same geometry.
    func claims(_ point: CGPoint, in fallback: CGRect) -> Bool {
        guard visible else { return false }
        let size = bounds == .zero ? fallback.size : bounds
        let controls = VirtualPadLayout.controls(for: size,
                                                 topInset: GameChromeState.shared.topInset)
        if VirtualPadLayout.hit(point, in: size, controls: controls) != nil { return true }
        return Self.hitsHideDisc(point, in: size)
    }

    /// The hide disc is not a gamepad button, so it is not in the hit table —
    /// but it does have to take touches, or it is decoration.
    static func hitsHideDisc(_ point: CGPoint, in size: CGSize) -> Bool {
        let disc = VirtualPadLayout.hideDisc(for: size,
                                            topInset: GameChromeState.shared.topInset)
        let dx = Double(point.x - disc.centre.x), dy = Double(point.y - disc.centre.y)
        return (dx * dx + dy * dy).squareRoot() <= disc.radius + VirtualPadLayout.hitSlop
    }

    // MARK: - touch plumbing

    /// `touch` identifies one finger for as long as it is down. The touch layer
    /// assigns it, so it is stable for the whole gesture regardless of how the
    /// view tree is re-rendered underneath it — which a SwiftUI `@State` flag
    /// per control was not.
    func begin(_ hit: PadHit, touch: Int) {
        touches.begin(hit, touch: touch)
        push()
    }

    func move(_ stick: PadStick, to axis: PadAxis) {
        touches.move(stick, to: axis)
        push()
    }

    /// A thumb that slid off one button onto another. Returns false when the
    /// change is not allowed, so the caller does not have to keep a second
    /// copy of the rule. See `PadHit.canReassign`.
    @discardableResult
    func reassign(_ hit: PadHit, touch: Int) -> Bool {
        guard PadHit.canReassign(from: touches.hit(of: touch), to: hit) else { return false }
        touches.begin(hit, touch: touch)
        push()
        return true
    }

    func end(touch: Int) {
        touches.end(touch: touch)
        push()
    }

    func releaseAll() {
        touches.endAll()
        push()
    }

    private func push() {
        GamepadBridge.shared.setVirtual(touches.input)
        traceEdge()
        // Only on the frames that changed, or the whole overlay re-renders at
        // 60Hz for nothing while a single button is held.
        let buttons = touches.buttons
        if buttons != held { held = buttons }
        var next: [PadStick: PadAxis] = [:]
        let input = touches.input
        if input.leftX != 0 || input.leftY != 0 {
            next[.left] = PadAxis(x: input.leftX, y: input.leftY)
        }
        if input.rightX != 0 || input.rightY != 0 {
            next[.right] = PadAxis(x: input.rightX, y: input.rightY)
        }
        if next != axes { axes = next }
    }

    /// One line per gesture, never per frame. This is the whole difference
    /// between "the pad is inert" and "the pad posts and the game ignores it" —
    /// two reports that cost a build to tell apart before, because the pad gave
    /// no sign either way.
    private var wasIdle = true

    private func traceEdge() {
        let idle = touches.isIdle
        guard idle != wasIdle else { return }
        wasIdle = idle
        if idle {
            fputs("[pad] released\n", stderr)
        } else {
            let held = touches.buttons.map(\.rawValue).sorted().joined(separator: ",")
            let l = touches.input, lx = l.leftX, ly = l.leftY, rx = l.rightX, ry = l.rightY
            fputs(String(format: "[pad] input buttons=[%@] left=(%.2f,%.2f) right=(%.2f,%.2f)\n",
                         held, lx, ly, rx, ry), stderr)
        }
    }
}

/// The pad's window, above everything the app draws.
///
/// One level above `TouchControlsHost` (+101), which is itself above the
/// joystick pad (+100). A window level cannot be undone by anything inside the
/// app window, which is what makes this reliable where a subview ordering is
/// not — see `JoystickPadHost`.
///
/// Unlike the joystick pad's window this one has to take input, so it is not
/// click-through: it claims a point only when a control is actually there.
/// Everything else — the whole screen between the buttons — falls through to
/// the game, so mouse-look and the game's own gestures keep working.
final class VirtualPadWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard VirtualPadState.shared.claims(point, in: bounds) else { return nil }
        return super.hitTest(point, with: event)
    }
}

enum VirtualPadHost {
    private static var window: VirtualPadWindow?
    private static var touch: VirtualPadTouchView?

    static func attach() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                        ?? scenes.first else { return }
        if window == nil {
            // Same reason as TouchControlsHost: the orientation notification is
            // not posted unless generation has been switched on, and without it
            // this window keeps a portrait frame after the first rotation.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            let w = VirtualPadWindow(windowScene: scene)
            w.windowLevel = .normal + 102
            w.backgroundColor = .clear
            w.isHidden = false              // deliberately never made key
            let host = UIHostingController(rootView: VirtualPadOverlay())
            host.view.backgroundColor = .clear
            // Drawing only. The touch layer below owns every gesture, so a
            // 60Hz re-render of the pad can never take a touch out from under a
            // thumb that is already holding a button down.
            host.view.isUserInteractionEnabled = false
            w.rootViewController = host
            // Added AFTER the hosting view, so it is the window's topmost
            // subview and every claimed touch lands here first.
            let t = VirtualPadTouchView(frame: w.bounds)
            t.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            w.addSubview(t)
            window = w
            touch = t
            VirtualPadState.shared.markAttached()
        }
        window?.frame = scene.coordinateSpace.bounds
    }
}

/// The pad's input layer: a plain UIKit view, deliberately.
///
/// The pad drew correctly and controlled nothing, and the reason was a layer of
/// indirection too many. A touch had to survive `UIWindow.hitTest` into a
/// `UIHostingController`, then be recognised by a per-control SwiftUI
/// `DragGesture` whose `@State` flag lived in a view re-created on every
/// re-render of the overlay — and the overlay re-renders whenever the pad's own
/// held state changes, i.e. on the first frame of every press. Every one of
/// those steps can drop a touch silently, and none of them says so.
///
/// A `UIView` with `isMultipleTouchEnabled` has none of them: `touchesBegan` /
/// `Moved` / `Ended` arrive directly, one `UITouch` object per finger for the
/// life of the gesture, in exactly the coordinate space `bounds` — the one the
/// drawing uses — is measured in. It is also the pattern the rest of this app
/// already uses for the game surface (`MetalBackedView`).
final class VirtualPadTouchView: UIView {
    /// One finger at a time, keyed by `UITouch` identity. Identity rather than
    /// an index, because two fingers on one button must keep it held until the
    /// LAST one lifts, and a re-render must not lose the association.
    private var assigned: [ObjectIdentifier: PadHit] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        VirtualPadState.shared.setBounds(bounds.size)
    }

    /// The pad takes a touch iff a control is there — the same rule the window
    /// uses to decide whether to keep the touch away from the game.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        VirtualPadState.shared.visible
    }

    private func controlHit(at p: CGPoint) -> PadHit? {
        VirtualPadLayout.hit(p, in: bounds.size, controls: VirtualPadState.shared.controls)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pad = VirtualPadState.shared
        for t in touches {
            let p = t.location(in: self)
            let key = ObjectIdentifier(t)
            guard let hit = controlHit(at: p) else {
                // Claimed by the window, but not a control: the only other
                // thing the pad claims is its own hide disc.
                hide()
                continue
            }
            assigned[key] = hit
            pad.begin(hit, touch: key.hashValue)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pad = VirtualPadState.shared
        for t in touches {
            let key = ObjectIdentifier(t)
            guard let held = assigned[key] else { continue }
            let p = t.location(in: self)
            if case .stick(let s) = held {
                guard let c = pad.control(for: held) else { continue }
                let centre = VirtualPadLayout.centre(c, in: bounds.size)
                pad.move(s, to: VirtualPadLayout.stickVector(
                    centre: centre, travel: VirtualPadLayout.travel(c), at: p))
            } else if let next = controlHit(at: p),
                      pad.reassign(next, touch: key.hashValue) {
                // Sliding across a d-pad is what a d-pad is for.
                assigned[key] = next
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    private func release(_ touches: Set<UITouch>) {
        let pad = VirtualPadState.shared
        for t in touches {
            let key = ObjectIdentifier(t)
            guard assigned.removeValue(forKey: key) != nil else { continue }
            pad.end(touch: key.hashValue)
        }
    }

    private func hide() {
        SettingsStore.shared.settings.virtualPad = .off
        VirtualPadState.shared.setVisible(false)
        fputs("[pad] hidden by its own disc — set to Off in Settings\n", stderr)
    }
}

/// The pad itself: a translucent DualShock laid over the bottom of the screen.
struct VirtualPadOverlay: View {
    @ObservedObject private var pad = VirtualPadState.shared
    @ObservedObject private var chrome = GameChromeState.shared
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var status = RunStatus.shared

    /// `automatic` means "while a session is running" — `RunStatus` tracks
    /// Wine, which is the only honest answer. It used to mean "the layout is
    /// immersive", and an iPhone in landscape is immersive from launch, so the
    /// pad covered the home screen before anything had started.
    private var shouldShow: Bool {
        store.settings.virtualPad.shows(gameOnScreen: status.phase.isBusy)
    }

    var body: some View {
        // No GeometryReader: the size comes from the touch layer, which is the
        // one object that also decides what a point hits. Two sources can
        // disagree by a safe-area inset, and a drawn button that is not where a
        // thumb must press is exactly the bug this replaces.
        let size = pad.bounds
        ZStack(alignment: .topLeading) {
            if size != .zero {
                let controls = VirtualPadLayout.controls(for: size, topInset: chrome.topInset)
                // Behind the buttons: the cross plates and the soft deck. Drawn
                // here rather than by each control because a cross is one shape
                // spanning four hit regions, and four separate plates read as a
                // flower rather than a d-pad.
                decoration(controls: controls, in: size)
                // Indexed rather than enumerated: a Swift 6 closure cannot
                // destructure the `(offset:element:)` tuple.
                ForEach(controls.indices, id: \.self) { index in
                    let control = controls[index]
                    PadControlView(control: control)
                        .position(VirtualPadLayout.centre(control, in: size))
                }
                hideDisc(in: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .opacity(pad.opacity)
        .onAppear { sync() }
        // `attached` as well as `shouldShow`: the first sync can run before
        // the hosting view has been told the touch layer exists, and a pad
        // that decides it is hidden at that moment would never be asked again.
        .onChange(of: pad.attached) { _, _ in sync() }
        .onChange(of: shouldShow) { _, _ in sync() }
        .onChange(of: store.settings.virtualPadOpacity) { _, _ in sync() }
    }

    private func sync() {
        pad.opacity = VirtualPadLayout.opacityClamped(store.settings.virtualPadOpacity)
        pad.setVisible(shouldShow && pad.attached)
    }

    /// The deck and the two d-pad crosses. No hit testing: the controls are what
    /// take the touches.
    private func decoration(controls: [PadControl], in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 46, style: .continuous)
                .fill(Color.black)
                .frame(height: size.height * 0.52)
                .blur(radius: 28)
                .opacity(0.55)
                .offset(y: size.height * 0.48)
            ForEach([true, false], id: \.self) { isLeft in
                if let centre = crossCentre(controls: controls, left: isLeft, in: size) {
                    PadCross()
                        .frame(width: CGFloat(VirtualPadLayout.armPoints * 2.7),
                               height: CGFloat(VirtualPadLayout.armPoints * 2.7))
                        .position(centre)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The pad's own hide control. Drawn here, hit-tested by
    /// `VirtualPadTouchView` — pressing it turns the setting off, which is the
    /// shortest way out of a pad that is in the way.
    private func hideDisc(in size: CGSize) -> some View {
        let disc = VirtualPadLayout.hideDisc(for: size, topInset: chrome.topInset)
        return ZStack {
            Circle().fill(Color.black.opacity(0.45))
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)
            Image(systemName: "xmark")
                .font(.system(size: CGFloat(disc.radius) * 0.8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: CGFloat(disc.radius) * 2, height: CGFloat(disc.radius) * 2)
        .position(disc.centre)
        .accessibilityLabel("Hide the on-screen controller")
    }

    /// The centre of a d-pad cluster, from the four controls that make it up.
    private func crossCentre(controls: [PadControl], left: Bool,
                             in size: CGSize) -> CGPoint? {
        let dpad = controls.filter { c in
            guard case .button(let b) = c.hit else { return false }
            switch b {
            case .up, .down, .left, .right:
                return left ? c.nx < 0.5 : c.nx >= 0.5
            default:
                return false
            }
        }
        guard !dpad.isEmpty else { return nil }
        let points = dpad.map { VirtualPadLayout.centre($0, in: size) }
        let x = points.reduce(0) { $0 + $1.x } / CGFloat(points.count)
        let y = points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
        return CGPoint(x: x, y: y)
    }
}

/// A PlayStation d-pad: two rounded bars crossing.
struct PadCross: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                    .frame(width: w, height: h * 0.34)
                RoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                    .frame(width: w * 0.34, height: h)
            }
            .foregroundStyle(Color.white.opacity(0.13))
            .overlay(
                ZStack {
                    RoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        .frame(width: w, height: h * 0.34)
                    RoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        .frame(width: w * 0.34, height: h)
                }
            )
        }
    }
}

/// One control: a face button, a d-pad arrow, a shoulder, or a stick.
///
/// Draw only. `VirtualPadTouchView` takes the touches, and what it captured is
/// what these views highlight — so the pad's appearance is a readout of the
/// input layer rather than a thing that happens to look pressed. When the two
/// were separate the pad could light up while posting nothing, which is exactly
/// how it was reported.
struct PadControlView: View {
    let control: PadControl

    @ObservedObject private var pad = VirtualPadState.shared

    private var radius: CGFloat { CGFloat(VirtualPadLayout.radius(control)) }

    private var isDown: Bool {
        switch control.hit {
        case .button(let b): return pad.held.contains(b)
        case .stick(let s):  return pad.axes[s] != nil
        }
    }

    var body: some View {
        content
            .frame(width: radius * 2, height: radius * 2)
    }

    /// The deflection is measured by the touch layer from the same centre
    /// this frame is drawn around, so the knob follows the thumb exactly.
    /// There is deliberately no per-control conversion any more: a second
    /// copy of that arithmetic is a second chance for the two to disagree.

    @ViewBuilder
    private var content: some View {
        switch control.hit {
        case .stick(let stick):
            ZStack {
                Circle().fill(Color.white.opacity(0.11))
                Circle().stroke(Color.white.opacity(0.22), lineWidth: 1)
                // Knob offset by the live axis. `y` is negated to get back to
                // screen coordinates, which grow downward.
                let a = pad.axes[stick] ?? PadAxis()
                let travel = CGFloat(VirtualPadLayout.travel(control))
                Circle()
                    .fill(Color.white.opacity(isDown ? 0.75 : 0.55))
                    .frame(width: radius * 0.86, height: radius * 0.86)
                    .offset(x: CGFloat(a.x) * travel, y: -CGFloat(a.y) * travel)
            }

        case .button(let button) where Self.isDPad(button):
            // Just the arrow: the cross plate behind it is drawn once per
            // cluster, in the decoration layer.
            Image(systemName: Self.arrow(for: button))
                .font(.system(size: radius * 0.72, weight: .semibold))
                .foregroundStyle(isDown ? Color.white : Color.white.opacity(0.75))

        case .button(let button):
            ZStack {
                Circle().fill(Color.black.opacity(0.35))
                Circle().stroke(Color.white.opacity(0.20), lineWidth: 1)
                glyph(for: button, size: radius)
            }
            .overlay(
                Circle().fill(Color.white.opacity(isDown ? 0.22 : 0))
            )
        }
    }

    /// PlayStation glyphs and their colours, so the four face buttons are
    /// recognisable without reading anything.
    @ViewBuilder
    private func glyph(for button: GamepadButton, size: CGFloat) -> some View {
        switch button {
        case .y:
            glyphText("△", color: Color(red: 0.36, green: 0.78, blue: 0.55), size: size)
        case .b:
            glyphText("○", color: Color(red: 0.91, green: 0.35, blue: 0.42), size: size)
        case .a:
            glyphText("✕", color: Color(red: 0.42, green: 0.62, blue: 0.95), size: size)
        case .x:
            glyphText("□", color: Color(red: 0.92, green: 0.56, blue: 0.80), size: size)
        case .lb:
            glyphText("L1", color: .white.opacity(0.85), size: size * 0.5)
        case .rb:
            glyphText("R1", color: .white.opacity(0.85), size: size * 0.5)
        case .lt:
            glyphText("L2", color: .white.opacity(0.85), size: size * 0.5)
        case .rt:
            glyphText("R2", color: .white.opacity(0.85), size: size * 0.5)
        case .menu:
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.white.opacity(0.8))
        case .view:
            Image(systemName: "square.on.square")
                .foregroundStyle(.white.opacity(0.8))
        default:
            EmptyView()
        }
    }

    private func glyphText(_ text: String, color: Color, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
    }

    private static func isDPad(_ b: GamepadButton) -> Bool {
        switch b {
        case .up, .down, .left, .right: return true
        default: return false
        }
    }

    private static func arrow(for b: GamepadButton) -> String {
        switch b {
        case .up:    return "arrowtriangle.up.fill"
        case .down:  return "arrowtriangle.down.fill"
        case .left:  return "arrowtriangle.left.fill"
        case .right: return "arrowtriangle.right.fill"
        default:     return "circle"
        }
    }
}
