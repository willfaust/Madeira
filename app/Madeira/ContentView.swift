import SwiftUI
import UIKit
import QuartzCore
import Metal
import os.log

// 2026-07-03 window-hosted Metal layer.
//
// The presenting CAMetalLayer must NOT be a SwiftUI-hosted view's backing
// layer: on iOS 26/27, SwiftUI's hosting intermittently routes such layers
// through an indirect/snapshot path where direct Metal presentations are
// silently dropped — presented drawables complete with presentedTime==0
// (measured), the screen freezes on stale content, and only full-tree
// re-renders (screenshots) reveal new frames. Which path a given run gets
// appeared random — the "sometimes rendering starts at present #9,
// sometimes never" lottery.
//
// So the layer now lives in MetalHostView, a raw UIView added directly to
// the UIWindow (classic game setup, no SwiftUI management). The SwiftUI-
// hosted MetalBackedView remains as a transparent layout placeholder that
// tracks geometry and handles touch input. The host view sits on top of
// the window but has interaction disabled, so touches fall through to the
// SwiftUI hierarchy (and thus to the placeholder's touch handlers).

/// Raw window-level host for the presenting CAMetalLayer.
final class MetalHostView: UIView {
    // Process-lifetime singleton. The CAMetalLayer is registered with DXMT's
    // swapchain exactly once; if the host were recreated on view teardown
    // (rotation, re-attach) DXMT would keep presenting to the DEAD layer —
    // black surface both ways (2026-07-05 landscape regression). One host,
    // one layer, forever; only its FRAME is re-parented/resized.
    static let shared = MetalHostView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

    override class var layerClass: AnyClass { return CAMetalLayer.self }
    var metalLayer: CAMetalLayer { return layer as! CAMetalLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        GamepadEventClaim.install(on: self)
        isUserInteractionEnabled = false   // touches fall through to SwiftUI
        backgroundColor = .black
        contentScaleFactor = UIScreen.main.scale
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // 2026-07-03 MeloNX trick: displaySyncEnabled is macOS-public but
        // exists as PRIVATE API on iOS. Disabling it takes our presents out
        // of the display-sync scheduling machinery — the thing that has been
        // silently dropping them (presentedTime==0 on all but occasional
        // frames) at our sub-1Hz game present cadence. MeloNX (shipping
        // Switch emulator) sets exactly this pair on its layer.
        let syncSel = NSSelectorFromString("setDisplaySyncEnabled:")
        if metalLayer.responds(to: syncSel) {
            metalLayer.perform(syncSel, with: NSNumber(value: false))
            LogStore.shared.log("MetalLayer: displaySyncEnabled=false (private API, MeloNX pattern)")
        }
        /* ml651: was hardcoded 60, which contradicted everything around it —
         * FPSOverlay asks the display link for CAFrameRateRange(preferred: 120)
         * while this declared the surface a 60Hz one. Track the screen instead.
         *
         * ⚠️ HYPOTHESIS, NOT A DIAGNOSIS. displaySyncEnabled=false directly above
         * takes our presents out of display-sync scheduling, so this nominal
         * value may well be inert. It is one line and it removes a genuine
         * contradiction; if the A/B shows nothing, the cap is elsewhere and we
         * have eliminated it rather than argued about it. */
        let fpsSel = NSSelectorFromString("setNominalFramesPerSecond:")
        if metalLayer.responds(to: fpsSel) {
            let hz = UIScreen.main.maximumFramesPerSecond
            metalLayer.perform(fpsSel, with: hz as NSNumber)
            LogStore.shared.log("MetalLayer: ml651 nominalFPS=\(hz) (was hardcoded 60; "
                                + "display link asks preferred=120)")
        }
        UIApplication.shared.isIdleTimerDisabled = true
        // Set once so DXMT's swapchain setup never blocks on a zero-sized
        // layer. After this, DXMT's setProps is the ONLY drawableSize
        // writer — per-layout rewrites from the app were a second writer
        // fighting it (pool churn on every SwiftUI layout pass).
        metalLayer.drawableSize = CGSize(width: 800, height: 600)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Touches on the game view outside the on-screen controls reach the program as
/// a mouse. Some games (Dark Souls Remastered) switch to keyboard and mouse
/// prompts on any mouse event and then ignore the controller, so a stray tap
/// next to a touch button costs the player the controller. MADEIRA_TOUCH_MOUSE
/// (madeira.cfg `env.NAME`, else the process environment): "1" always sends
/// them (the previous behaviour), "0" never does, and by default they are not
/// sent while the landscape overlay shows at least one controller mapping,
/// unless touch is set to work as a trackpad. A hardware mouse or trackpad is
/// not affected.
@MainActor enum TouchMouseGate {
    enum Mode: String { case auto, on, off }
    static let mode: Mode = {
        let v = MadeiraConfig.get("env.MADEIRA_TOUCH_MOUSE")  // 1: touches always reach the program as a mouse, 0: never; default: not while touch controller mappings are shown
            ?? ProcessInfo.processInfo.environment["MADEIRA_TOUCH_MOUSE"]
        let m: Mode = v == "1" ? .on : (v == "0" ? .off : .auto)
        LogStore.shared.log("[touch-mouse] mode=\(m.rawValue)")
        return m
    }()
    /// Set by TouchControlsOverlay.configureGamepad: the landscape overlay is
    /// visible, not editing, and has at least one controller mapping.
    static var padOverlay = false
    static func suppressing(touchpad: Bool) -> Bool {
        switch mode {
        case .on: return false
        case .off: return true
        case .auto: return padOverlay && !touchpad
        }
    }
}

// SwiftUI-hosted placeholder: geometry + touch input only.
final class MetalBackedView: UIView {
    private static var layerRegistered = false

    // Hardware keyboard bridge: the view becomes first responder so the iOS
    // software keyboard appears, and each typed character is forwarded to
    // Wine as a virtual-key sequence (winios_post_key → send_hardware_message
    // → WM_KEYDOWN/WM_CHAR). Lets the user type into Windows dialogs (e.g.
    // Run) directly instead of relying on the browse list.
    static weak var keyboardTarget: MetalBackedView?
    override var canBecomeFirstResponder: Bool { true }
    static func toggleKeyboard() {
        guard let v = keyboardTarget else { return }
        if v.isFirstResponder { v.resignFirstResponder() }
        else { v.becomeFirstResponder() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        GamepadEventClaim.install(on: self)
        // Multi-touch REQUIRED: with it off, a fast double-tap's second
        // touch (landing before the first lift is processed) is silently
        // swallowed — drag-arm never fired (2026-07-06). Two-finger
        // scroll/right-click need it too.
        self.isMultipleTouchEnabled = true
        self.isUserInteractionEnabled = true
        self.backgroundColor = .clear
        // Hardware mouse/trackpad: hide the system pointer over the surface and
        // carry indirect-pointer motion (HardwareInput.swift). No-op with
        // MADEIRA_HWINPUT=0.
        PointerFallback.install(on: self)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        GamepadEventClaim.install(on: self)
        PointerFallback.install(on: self)
    }

    // Visibility-stall postmortem (2026-07-03): the intermittent "presents
    // count but the screen stays black until a bg/fg or screenshot" state
    // was probed exhaustively — drawable leaks, present pacing, panel idle,
    // SwiftUI hosting, display-sync, CADisplayLink, transaction nudges and
    // view re-attach kicks were all eliminated (none changed it; only true
    // scene-level lifecycle events land pending frames, ~1-2 each). The one
    // robust correlate is present cadence: 60 FPS content always displays,
    // ~1 FPS content mostly doesn't. Resolution path: raise game FPS (perf
    // work), with a steady-rate re-present in DXMT as fallback insurance.

    /// The guest surface's size in guest pixels: the virtual monitor win32u
    /// reports right now (GuestDisplay.swift). A game's ChangeDisplaySettings
    /// really resizes it, so it is read back on every use rather than taken
    /// from MADEIRA_SCREEN_W/H once; a mode change re-lays-out through
    /// `observeModeChanges`. It is 1024x768 unless a session chose otherwise.
    private func guestSize() -> CGSize {
        Self.observeModeChanges()
        var w: Int32 = 0, h: Int32 = 0
        winios_screen_size(&w, &h)
        guard w > 0, h > 0 else { return CGSize(width: 1024, height: 768) }
        return CGSize(width: CGFloat(w), height: CGFloat(h))
    }

    /// The layout used for the presented layer and for touch mapping: a
    /// library session's Aspect & scaling choice (LibraryModel.displayMode);
    /// Fit everywhere else, which is what the developer interface always did.
    private func effectiveDisplayMode() -> DisplayMode {
        let library = LibraryModel.shared
        return library.current != nil ? library.displayMode : .fit
    }

    /// The presented drawable's size, or `.zero` until this session has
    /// presented into it (before that it is the 800x600 seed or the last
    /// session's size, and Aspect would letterbox against the wrong shape).
    private func drawableAspect() -> CGSize {
        guard madeira_get_present_count() != Self.presentCountAtLaunch else { return .zero }
        let d = MetalHostView.shared.metalLayer.drawableSize
        return (d.width > 0 && d.height > 0) ? d : .zero
    }

    /// The present counter when the current library session started (see
    /// drawableAspect); LibraryModel.begin sets it.
    static var presentCountAtLaunch: UInt64 = 0

    /// The rect (view-local points) the guest surface occupies. The
    /// window-level host view gets THIS frame, not our full bounds, and touch
    /// mapping uses the same rect, so letterboxing, cropping and stretching
    /// never skew input.
    private func gameRect() -> CGRect {
        let r = GameSurfaceLayout.rect(guest: guestSize(), aspect: drawableAspect(),
                                       bounds: bounds, mode: effectiveDisplayMode())
        return CGRect(x: r.minX, y: r.minY, width: max(r.width, 1), height: max(r.height, 1))
    }

    private static var drawableObservation: NSKeyValueObservation?
    private static var pendingSettle: DispatchWorkItem?
    private static var lastApplied = ""

    /// Sizes the presented layer's host view to gameRect(). `[display] apply`
    /// is logged when the result changes.
    private func applyDisplayMode(reason: String) {
        guard let w = window else { return }
        let r = gameRect()
        MetalHostView.shared.frame = convert(r, to: w)
        // The desktop compositor lays the guest display out in the same rect,
        // so Aspect / Fill / Stretch / Fit apply to desktop sessions as well.
        winios_set_desktop_rect(r.minX - bounds.minX, r.minY - bounds.minY, r.width, r.height, 1)
        let guest = guestSize(), mode = effectiveDisplayMode()
        let line = String(format: "mode=%@ guest=%.0fx%.0f bounds=%.0fx%.0f -> rect=(%.0f,%.0f %.0fx%.0f)",
                          mode.rawValue, guest.width, guest.height, bounds.width, bounds.height,
                          r.minX, r.minY, r.width, r.height)
        if line != Self.lastApplied {
            Self.lastApplied = line
            fputs("[display] apply reason=\(reason) \(line)\n", stderr)
        }
    }

    /// Re-applies the layout to the live view now and once more ~0.3 s later:
    /// UIKit reports pre-rotation bounds while a rotation is still animating,
    /// and DXMT may not have published the new drawable size yet. A burst of
    /// triggers collapses into one trailing re-apply.
    static func refreshDisplayMode(reason: String = "refresh") {
        keyboardTarget?.applyDisplayMode(reason: reason)
        pendingSettle?.cancel()
        let item = DispatchWorkItem { keyboardTarget?.applyDisplayMode(reason: "settle:\(reason)") }
        pendingSettle = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Guest mode changes (IOSDisplayShim posts them on the main queue) and
    /// device rotation re-lay-out the surface. Idempotent, app lifetime.
    private static let observers: [NSObjectProtocol] = [
        NotificationCenter.default.addObserver(forName: .MadeiraDisplayModeChanged, object: nil, queue: .main) { _ in
            MetalBackedView.refreshDisplayMode(reason: "mode-changed")
        },
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { _ in
            MetalBackedView.refreshDisplayMode(reason: "orientation")
        },
    ]
    static func observeModeChanges() { _ = observers }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let w = window else { return }   // detach: leave the host be
        MetalBackedView.keyboardTarget = self  // keyboard button targets the live view
        // SwiftUI ancestors attach gesture recognizers that can delay or
        // cancel raw touch delivery (double-tap timing is exactly what
        // they punish). Defuse them for our subtree.
        var v: UIView? = self
        while let s = v {
            s.gestureRecognizers?.forEach {
                $0.cancelsTouchesInView = false
                $0.delaysTouchesBegan = false
                $0.delaysTouchesEnded = false
            }
            v = s.superview
        }
        let host = MetalHostView.shared
        if host.superview !== w {
            host.removeFromSuperview()
            w.addSubview(host)
        }
        applyDisplayMode(reason: "attach")
        // S2 desktop mode: the winios compositor renders the wine virtual
        // desktop aspect-fit inside THIS placeholder's area, exactly like
        // the games' Metal layer — never over the whole phone screen.
        let full = convert(bounds, to: w)
        winios_set_compositor_frame(full.minX, full.minY, full.width, full.height)
        if !Self.layerRegistered {
            Self.layerRegistered = true
            madeira_display_set_layer(host.metalLayer)
            // DXMT writes drawableSize off the main thread; Aspect and Fill
            // height follow it, so a change re-lays-out on the main queue.
            Self.drawableObservation = host.metalLayer.observe(\.drawableSize, options: [.new]) { _, _ in
                DispatchQueue.main.async { MetalBackedView.refreshDisplayMode(reason: "drawable") }
            }
            LogStore.shared.log("MetalLayer registered with DXMT shim (window-hosted singleton)", level: .success)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let w = window {
            applyDisplayMode(reason: "layout")
            let full = convert(bounds, to: w)
            winios_set_compositor_frame(full.minX, full.minY, full.width, full.height)
        }
    }

    // Map a touch in view-local points to guest pixels through the same
    // GameSurfaceLayout math that sizes the presented layer, then post to
    // winios.drv. Off-surface touches (letterbox, Fill's cropped margin)
    // clamp to the nearest edge.
    private func mapTouch(_ touch: UITouch) -> (Int32, Int32) {
        mapPoint(touch.location(in: self))
    }

    /// Same mapping for any point (a multi-finger midpoint, a touch's down
    /// point). In a desktop session the compositor letterboxes the desktop in
    /// its own frame, so it does the mapping.
    private func mapPoint(_ p: CGPoint) -> (Int32, Int32) {
        if desktopMode {
            let w = convert(p, to: nil)
            var px: Int32 = 0, py: Int32 = 0
            _ = winios_desktop_point_from_window(Double(w.x), Double(w.y), &px, &py)
            Self.cursor = CGPoint(x: CGFloat(px), y: CGFloat(py))   // keep the trackpad cursor in step
            return (px, py)
        }
        let g = GameSurfaceLayout.map(point: p, guest: guestSize(), aspect: drawableAspect(),
                                      bounds: bounds, mode: effectiveDisplayMode())
        return (Int32(g.x), Int32(g.y))
    }

    // ==================================================================
    // Touch pointer mode (InputSettings.touchMode), in direct and desktop
    // sessions alike:
    //   one-finger tap        — left click where the finger is
    //   hold (0.25 s) or move — left button down at the touch point, drag, lift
    //   two / three-finger tap — right / middle click at the fingers' midpoint
    //   two-finger drag       — scroll wheel
    // The drawn cursor jumps to the finger at once; nothing is posted until
    // the gesture resolves, so a multi-finger tap never leaves a stray click.
    // ==================================================================
    private var tmDownPoints: [ObjectIdentifier: CGPoint] = [:]
    private var tmGestureDownPoint = CGPoint.zero
    private var tmPeak = 0
    private var tmResolved = false
    private var tmDragTouch: UITouch?
    private var tmSlopBroken = false
    private var tmGeneration = 0
    private var tmTwoFingerLastY: CGFloat = 0
    private var tmScrollAccum: CGFloat = 0
    private static let tmHoldDelay: TimeInterval = 0.25
    private static let tmSlop: CGFloat = 10
    private let F_MDOWN: UInt32 = 0x20, F_MUP: UInt32 = 0x40

    private var touchPointerMode: Bool { InputSettings.shared.touchMode }

    private func tmResetGesture() {
        tmDownPoints.removeAll()
        tmGestureDownPoint = .zero
        tmPeak = 0
        tmResolved = false
        tmDragTouch = nil
        tmSlopBroken = false
        tmGeneration += 1
        tmTwoFingerLastY = 0
        tmScrollAccum = 0
    }

    /// Midpoint of every finger's down point this gesture.
    private func tmMidpoint() -> CGPoint {
        guard !tmDownPoints.isEmpty else { return tmGestureDownPoint }
        let pts = Array(tmDownPoints.values)
        let n = CGFloat(pts.count)
        return CGPoint(x: pts.reduce(0) { $0 + $1.x } / n, y: pts.reduce(0) { $0 + $1.y } / n)
    }

    private func tmCommitDrag(_ t: UITouch) {
        guard !tmResolved else { return }
        tmResolved = true
        tmDragTouch = t
        let (x, y) = mapPoint(tmGestureDownPoint)
        winios_post_touch_down(x, y)
    }

    /// Right/middle click at a guest position: winios_post_touch_* are
    /// left-button only, so these go through winios_pointer with ABSOLUTE.
    private func tmAbsoluteClick(down: UInt32, up: UInt32, at p: CGPoint) {
        let (x, y) = mapPoint(p)
        winios_pointer(x, y, down | F_ABS, 0)
        winios_pointer(x, y, up | F_ABS, 0)
    }

    private func touchModeBegan(_ touches: Set<UITouch>) {
        guard !tmResolved else { return }   // a finger joining mid-drag changes nothing
        for t in touches where tmDownPoints[ObjectIdentifier(t)] == nil {
            tmDownPoints[ObjectIdentifier(t)] = t.location(in: self)
        }
        tmPeak = max(tmPeak, tmDownPoints.count)
        if tmDownPoints.count == 1, let t = touches.first {
            tmGestureDownPoint = t.location(in: self)
            let (x, y) = mapPoint(tmGestureDownPoint)
            winios_cursor_move(x, y)
            tmGeneration += 1
            let gen = tmGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tmHoldDelay) { [weak self, weak t] in
                guard let self, let t, self.tmGeneration == gen, !self.tmResolved,
                      self.tmDownPoints.count == 1 else { return }
                self.tmCommitDrag(t)
            }
        } else {
            // A second or third finger: only a multi-finger tap is possible now.
            tmGeneration += 1
        }
    }

    private func touchModeMoved(_ touches: Set<UITouch>, _ event: UIEvent?) {
        let active = activeTouches(event)
        if !tmResolved, tmDownPoints.count == 2, active.count == 2 {
            let avg = avgPoint(active)
            if tmTwoFingerLastY == 0 { tmTwoFingerLastY = avg.y }
            let dy = avg.y - tmTwoFingerLastY
            if abs(dy) > 2 { tmSlopBroken = true }
            tmTwoFingerLastY = avg.y
            tmScrollAccum += dy
            let (mx, my) = mapPoint(avg)
            while tmScrollAccum <= -14 { tmScrollAccum += 14
                winios_pointer(mx, my, F_WHEEL, UInt32(bitPattern: Int32(-120))) }
            while tmScrollAccum >= 14 { tmScrollAccum -= 14
                winios_pointer(mx, my, F_WHEEL, UInt32(bitPattern: Int32(120))) }
            return
        }
        for t in touches {
            guard let down = tmDownPoints[ObjectIdentifier(t)] else { continue }
            let p = t.location(in: self)
            if tmResolved {
                guard t === tmDragTouch else { continue }
                let (x, y) = mapPoint(p)
                winios_post_touch_move(x, y)
                continue
            }
            guard tmDownPoints.count == 1 else {
                if hypot(p.x - down.x, p.y - down.y) > Self.tmSlop { tmSlopBroken = true }
                continue
            }
            if hypot(p.x - down.x, p.y - down.y) > Self.tmSlop {
                tmSlopBroken = true
                tmCommitDrag(t)                  // button down at the ORIGINAL point
                let (x, y) = mapPoint(p)
                winios_post_touch_move(x, y)
            }
        }
    }

    private func touchModeEnded(_ touches: Set<UITouch>, _ event: UIEvent?) {
        if tmResolved, let d = tmDragTouch, touches.contains(d) {
            let (x, y) = mapPoint(d.location(in: self))
            winios_post_touch_up(x, y)
            tmResetGesture()
            return
        }
        guard !tmResolved else { return }
        guard activeTouches(event).isEmpty else { return }   // wait for every finger
        let peak = tmPeak, mid = tmMidpoint(), brokeSlop = tmSlopBroken
        tmResetGesture()
        guard !brokeSlop else { return }
        switch peak {
        case 1:
            let (x, y) = mapPoint(mid)
            winios_post_touch_down(x, y)
            winios_post_touch_up(x, y)
        case 2: tmAbsoluteClick(down: F_RDOWN, up: F_RUP, at: mid)
        case 3: tmAbsoluteClick(down: F_MDOWN, up: F_MUP, at: mid)
        default: break
        }
    }

    private func touchModeCancelled(_ touches: Set<UITouch>) {
        if tmResolved, let d = tmDragTouch, touches.contains(d) {
            let (x, y) = mapPoint(d.location(in: self))
            winios_post_touch_up(x, y)   // never leave the button held
            tmResetGesture()
            return
        }
        if !tmResolved { tmResetGesture() }
    }

    // ==================================================================
    // S2 desktop mode: trackpad-style pointer.
    //   one finger move       — cursor moves relative (like a laptop pad)
    //   single tap            — left click
    //   double tap            — double click (two rapid clicks)
    //   double tap + hold     — drag (button held while moving), lift = drop
    //   two-finger drag       — scroll wheel
    //   two-finger tap        — right click
    // Cursor position lives here (desktop px); wine + the rendered arrow
    // follow via winios_pointer / winios_cursor_move.
    // ==================================================================
    // Internal, not private: a hardware mouse moves the same desktop cursor
    // (HardwareInput.followDesktopCursor). ml1157: it starts at the centre of
    // whatever desktop size was launched (static, so it is first read at the
    // first use -- after MADEIRA_SCREEN_* are set).
    static var cursor = CGPoint(
        x: CGFloat(getenv("MADEIRA_SCREEN_W").flatMap { Int(String(cString: $0)) } ?? 960) / 2,
        y: CGFloat(getenv("MADEIRA_SCREEN_H").flatMap { Int(String(cString: $0)) } ?? 540) / 2)
    private var lastPanPoint = CGPoint.zero
    private var touchStartPoint = CGPoint.zero
    private var touchStartTime: TimeInterval = 0
    private var movedBeyondSlop = false
    private var dragActive = false
    private var dragTouch: UITouch?          // the finger that owns the drag
    private var touchGeneration = 0          // invalidates pending long-press timers
    private var twoFingerActive = false
    private var twoFingerMoved = false
    private var twoFingerStartTime: TimeInterval = 0
    private var lastTwoFingerY: CGFloat = 0
    private var scrollAccum: CGFloat = 0
    // ml641: relative motion is scaled by a float sensitivity, so the integer
    // delta we hand to wine loses a fraction every event. At low sensitivity
    // that truncation is the whole signal — carry the remainder or slow drags
    // simply do nothing.
    private var relCarryX: CGFloat = 0
    private var relCarryY: CGFloat = 0

    private let F_MOVE: UInt32 = 0x1, F_LDOWN: UInt32 = 0x2, F_LUP: UInt32 = 0x4
    private let F_RDOWN: UInt32 = 0x8, F_RUP: UInt32 = 0x10
    private let F_WHEEL: UInt32 = 0x800, F_ABS: UInt32 = 0x8000

    private var desktopMode: Bool {
        guard let v = getenv("MADEIRA_DESKTOP") else { return false }
        return v.pointee == 49  // '1'
    }
    private func envInt(_ name: String, _ def: Int) -> Int {
        guard let v = getenv(name), let i = Int(String(cString: v)) else { return def }
        return i
    }
    private func postPointer(_ flags: UInt32, data: Int32 = 0) {
        winios_pointer(Int32(Self.cursor.x), Int32(Self.cursor.y), flags, UInt32(bitPattern: data))
    }
    private func avgPoint(_ touches: [UITouch]) -> CGPoint {
        var x: CGFloat = 0, y: CGFloat = 0
        for t in touches { let p = t.location(in: self); x += p.x; y += p.y }
        let n = CGFloat(max(touches.count, 1))
        return CGPoint(x: x / n, y: y / n)
    }
    private func activeTouches(_ event: UIEvent?) -> [UITouch] {
        (event?.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
    }

    // Direct touches that began while TouchMouseGate was suppressing stay
    // swallowed until they lift, so a change of the gate never leaves a button held.
    private var tmgSwallowed: Set<ObjectIdentifier> = []
    /// Returns the touches that should still be handled (nil = nothing left).
    private func tmgFilter(_ touches: Set<UITouch>, _ phase: UITouch.Phase) -> Set<UITouch>? {
        if phase == .began {
            _ = TouchMouseGate.mode   // logs the mode once
            guard TouchMouseGate.suppressing(touchpad: touchPointerMode) else { return touches }
            let direct = touches.filter { $0.type == .direct }
            guard !direct.isEmpty else { return touches }
            for t in direct { tmgSwallowed.insert(ObjectIdentifier(t)) }
            let rest = touches.subtracting(direct)
            return rest.isEmpty ? nil : rest
        }
        guard !tmgSwallowed.isEmpty else { return touches }
        let mine = touches.filter { tmgSwallowed.contains(ObjectIdentifier($0)) }
        guard !mine.isEmpty else { return touches }
        if phase == .ended || phase == .cancelled {
            for t in mine { tmgSwallowed.remove(ObjectIdentifier(t)) }
        }
        let rest = touches.subtracting(mine)
        return rest.isEmpty ? nil : rest
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if HardwareInput.shared.interceptTouches(touches, event, .began) { return }
        guard let touches = tmgFilter(touches, .began) else { return }
        if touchPointerMode { touchModeBegan(touches); return }
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_down(x, y)
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        let active = activeTouches(event)
        touchGeneration += 1
        if active.count >= 2 {
            twoFingerActive = true
            twoFingerMoved = false
            twoFingerStartTime = now
            lastTwoFingerY = avgPoint(active).y
            scrollAccum = 0
            // a drag started by the first finger stays active; harmless
            return
        }
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        touchStartPoint = p
        lastPanPoint = p
        touchStartTime = now
        movedBeyondSlop = false
        relCarryX = 0; relCarryY = 0   // ml641: never carry motion across a lift
        // long-press → drag: hold still for 0.5s, haptic confirms, then move
        // the window; release drops. (Replaced double-tap-hold — it raced
        // Windows' double-click detection: wine saw WM_LBUTTONDBLCLK.)
        let gen = touchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.touchGeneration == gen, !self.dragActive,
                  !self.movedBeyondSlop, !self.twoFingerActive,
                  // ml643: in mouse-look the finger is the CAMERA, not a pointer.
                  // Holding still to line up a shot must not press the mouse.
                  !InputSettings.shared.relative else { return }
            self.dragActive = true
            self.dragTouch = t
            self.postPointer(self.F_LDOWN)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            fputs("[trackpad] long-press drag armed\n", stderr)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if HardwareInput.shared.interceptTouches(touches, event, .moved) { return }
        guard let touches = tmgFilter(touches, .moved) else { return }
        if touchPointerMode { touchModeMoved(touches, event); return }
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_move(x, y)
            return
        }
        let active = activeTouches(event)
        if twoFingerActive {
            guard active.count >= 2 else { return }
            let avg = avgPoint(active)
            let dy = avg.y - lastTwoFingerY
            lastTwoFingerY = avg.y
            if abs(dy) > 2 { twoFingerMoved = true }
            scrollAccum += dy
            // 14pt of finger travel = one wheel notch. ml641 flipped the sign:
            // on a touchscreen the content follows the finger, so dragging UP
            // scrolls DOWN through the document. It was mouse-wheel sense before.
            while scrollAccum <= -14 { scrollAccum += 14; postPointer(F_WHEEL, data: -120) }
            while scrollAccum >= 14 { scrollAccum -= 14; postPointer(F_WHEEL, data: 120) }
            return
        }
        let t: UITouch
        if dragActive, let d = dragTouch {
            guard touches.contains(d) else { return }  // only the old tap finger moved
            t = d
        } else {
            guard let f = touches.first else { return }
            t = f
        }
        let p = t.location(in: self)
        let dx = p.x - lastPanPoint.x, dy = p.y - lastPanPoint.y
        lastPanPoint = p
        if hypot(p.x - touchStartPoint.x, p.y - touchStartPoint.y) > 10 { movedBeyondSlop = true }

        /* ml641 RELATIVE (mouse-look) MODE.
         *
         * Absolute input is what made the camera spin. We post a POSITION; wine
         * turns it into the delta the game reads as
         *     x - desktop_shm->cursor.x            (queue_ios.c:2290)
         * A game that locks the cursor calls ClipCursor, and update_desktop_cursor_pos
         * then CLAMPS desktop_shm->cursor into that rect, pinning it. Our own
         * Self.cursor keeps wandering across the full 1024x768, so the subtraction
         * yields (wandering - pinned): a huge delta that never converges and is
         * re-sent on every event. Spin rate depends on WHERE the finger is, not how
         * fast it moves.
         *
         * Posting device motion instead makes that impossible to reproduce: wine
         * computes cursor.x + dx, so the delta is exactly dx no matter what the
         * game does to the cursor. No F_ABS, and Self.cursor is deliberately not
         * touched — in this mode it has no meaning.
         *
         * Sign follows PUBG/Fortnite: drag right -> view turns right -> the world
         * slides left, so a target to the RIGHT of the crosshair is pulled onto it
         * by dragging RIGHT. That is the same sign as a mouse. Negate both terms
         * for content-drag (finger-follows-world) feel. */
        if InputSettings.shared.relative {
            let sens = CGFloat(InputSettings.shared.sensRel)
            relCarryX += dx * sens
            relCarryY += dy * sens
            let ix = Int32(max(-30000, min(30000, relCarryX)))
            let iy = Int32(max(-30000, min(30000, relCarryY)))
            relCarryX -= CGFloat(ix)
            relCarryY -= CGFloat(iy)
            if ix != 0 || iy != 0 { winios_pointer(ix, iy, F_MOVE, 0) }
            return
        }

        let sens = CGFloat(InputSettings.shared.sensAbs)   // desktop px per view pt
        // The live desktop size: a program's display-mode change resizes it.
        var deskW: Int32 = 0, deskH: Int32 = 0
        winios_screen_size(&deskW, &deskH)
        let maxX = CGFloat(max(Int(deskW), 1) - 1)
        let maxY = CGFloat(max(Int(deskH), 1) - 1)
        Self.cursor.x = min(max(Self.cursor.x + dx * sens, 0), maxX)
        Self.cursor.y = min(max(Self.cursor.y + dy * sens, 0), maxY)
        postPointer(F_MOVE | F_ABS)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if HardwareInput.shared.interceptTouches(touches, event, .ended) { return }
        guard let touches = tmgFilter(touches, .ended) else { return }
        if touchPointerMode { touchModeEnded(touches, event); return }
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_up(x, y)
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        if twoFingerActive {
            if activeTouches(event).isEmpty {
                if !twoFingerMoved && now - twoFingerStartTime < 0.40
                    && !InputSettings.shared.relative {   // ml643: see touchesBegan
                    postPointer(F_RDOWN)
                    postPointer(F_RUP)
                }
                twoFingerActive = false
            }
            return
        }
        touchGeneration += 1   // cancel any pending long-press
        if dragActive {
            if let d = dragTouch, !touches.contains(d) {
                fputs("[trackpad] ended: non-drag finger up (drag continues)\n", stderr)
                return
            }
            fputs("[trackpad] ended: drag drop\n", stderr)
            postPointer(F_LUP)
            dragActive = false
            dragTouch = nil
            return
        }
        // stationary release before the 0.5s drag threshold = click.
        // ml643: NOT in relative mode — every small aim adjustment would fire the
        // weapon. Left/right click are on-screen buttons there instead.
        if !movedBeyondSlop && now - touchStartTime < 0.5 && !InputSettings.shared.relative {
            fputs("[trackpad] ended: click\n", stderr)
            postPointer(F_LDOWN)
            postPointer(F_LUP)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if HardwareInput.shared.interceptTouches(touches, event, .cancelled) { return }
        guard let touches = tmgFilter(touches, .cancelled) else { return }
        if touchPointerMode { touchModeCancelled(touches); return }
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_up(x, y)
            return
        }
        fputs("[trackpad] CANCELLED (dragActive=\(dragActive))\n", stderr)
        touchGeneration += 1
        if dragActive { postPointer(F_LUP); dragActive = false }
        dragTouch = nil
        twoFingerActive = false
    }
}

/// Arrow-key button with press/hold/release semantics. DragGesture with
/// zero minimum distance fires onChanged at touch-down (key down once)
/// and onEnded at lift (key up) — unlike Button, which only taps.
struct HoldKeyView: View {
    let label: String
    let vk: Int32
    var big = false   // landscape D-pad: thumb-sized
    @State private var isDown = false

    var body: some View {
        Text(label)
            .font(.system(size: big ? 22 : 14, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .frame(minWidth: big ? 56 : 34, minHeight: big ? 56 : 30)
            .background(Color.white.opacity(isDown ? 0.35 : 0.15))
            .cornerRadius(big ? 12 : 6)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isDown {
                            isDown = true
                            winios_post_key(vk, 1)
                        }
                    }
                    .onEnded { _ in
                        isDown = false
                        winios_post_key(vk, 0)
                    }
            )
    }
}

/// Shared state for the expanded thumbstick pad. The pad cannot be drawn by
/// SwiftUI in place: the game surface is a raw window-level UIView
/// (MetalHostView.shared) sitting ABOVE the entire SwiftUI hierarchy, so a
/// SwiftUI pad centred on the key row gets sliced off wherever it overlaps —
/// no zIndex can fix that, because zIndex only orders siblings *within*
/// SwiftUI. So the pad is hosted in the window too, added after (and thus
/// above) the Metal view, and driven from the SwiftUI button through this.
final class JoystickPadState: ObservableObject {
    static let shared = JoystickPadState()
    @Published var held = false
    @Published var dir: Int = -1
    @Published var center: CGPoint = .zero      // window coordinates
    /// ml641: driven by the pointer panel. The pad is NOT a sibling of the key
    /// row — it lives in its own UIWindow one level up (that is the whole point
    /// of this class), so the row's .transition(.opacity) cannot reach it and it
    /// stayed visible while every other button faded. It has to fade itself.
    @Published var hidden = false
}

/// Window-level host for the pad. Transparent and non-interactive: the
/// SwiftUI button keeps the gesture, this only draws.
enum JoystickPadHost {
    /// Own UIWindow, one level above the app's. Being a sibling subview of
    /// MetalHostView is NOT enough: that view re-adds itself to the window on
    /// every didMoveToWindow (rotation, re-attach) and DXMT/CoreAnimation can
    /// reorder around it, so any subview ordering we impose is only true until
    /// the next layout. A higher windowLevel cannot be undone by anything
    /// inside the app window, so the pad is unconditionally on top.
    ///
    /// Deliberately NOT solved by changing the game surface: the CAMetalLayer
    /// is window-level precisely because SwiftUI hosting silently dropped
    /// presents on iOS 26/27 (see MetalHostView) — that is a rendering
    /// correctness fix and must not be traded away for z-ordering.
    private static var overlay: PassthroughWindow?

    static func attach(to scene: UIWindowScene) {
        if overlay == nil {
            let w = PassthroughWindow(windowScene: scene)
            w.windowLevel = .normal + 100
            w.backgroundColor = .clear
            w.isHidden = false                 // never becomes key: see PassthroughWindow
            let host = UIHostingController(rootView: JoystickPadOverlay())
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            w.rootViewController = host
            overlay = w
        }
        overlay?.frame = scene.coordinateSpace.bounds
    }
}

/// Transparent, fully click-through window: hitTest always returns nil, so
/// touches fall through to the app window underneath and the pad can never
/// steal input from the game surface or the SwiftUI controls.
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// The expanded pad, drawn in window space at the button's location.
struct JoystickPadOverlay: View {
    @ObservedObject private var s = JoystickPadState.shared

    var body: some View {
        GeometryReader { _ in
            // THE one and only joystick face — idle ring and expanded pad are
            // the same view, never two that swap. That identity is what makes
            // it seamless: the diameter and the knob offset are plain animated
            // properties, so releasing lets the knob spring back to centre and
            // keep wiggling after the ring has already shrunk. Two faces
            // cross-fading (one in the button, one here) cannot do that — the
            // wiggle dies with the copy that gets faded out.
            //
            // Fixed-size box at a CONSTANT offset. Deliberately not
            // .position() + .transition(.scale): .position expands the view to
            // fill the parent (so a .center anchor means mid-screen), and an
            // offset that changes in the same transaction as `held` gets
            // animated too — which is what made the pad fly in from the top.
            // Here the only animatable quantities belong to the face itself.
            JoystickFace(held: s.held, dir: s.dir)
                .frame(width: JoystickFace.padRadius * 2,
                       height: JoystickFace.padRadius * 2)
                .offset(x: s.center.x - JoystickFace.padRadius,
                        y: s.center.y - JoystickFace.padRadius)
                .opacity(s.center == .zero ? 0 : 1)
        }
        // MUST ignore the safe area. s.center comes from the button's .global
        // frame, which is measured from the WINDOW origin; without this the
        // overlay's hosting view is inset by the safe area, the offset above
        // is measured from below the status bar, and the pad lands ~59pt too
        // low — roughly one pad radius, which is exactly why it appeared to
        // sit under the game strip instead of centred on the button.
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(s.hidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.28), value: s.hidden)
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: s.held)
        .animation(.spring(response: 0.22, dampingFraction: 0.58), value: s.dir)
    }
}

/// The joystick face itself, shared by the in-row idle ring and the expanded
/// window-level pad so both look identical and animate the same way.
struct JoystickFace: View {
    var held: Bool
    var dir: Int
    /// ml646: the portrait pad grows out of a key-sized ring when you hold it.
    /// An overlay stick is a PERMANENT control — it must be full size at rest
    /// with only the knob moving, so size is decoupled from press here rather
    /// than faked by passing held:true (which would also kill the knob travel
    /// and the press styling).
    var alwaysExpanded = false
    /// SF Symbol naming what this stick drives (ControlAction.stickGlyph), so a
    /// WASD stick and an arrow-key stick differ at a glance. At rest it is drawn
    /// on the knob in the middle of the ring and travels with it; a ring at idle
    /// size shows the glyph alone, where a knob plus a symbol would be a smudge.
    /// nil (the portrait pad) draws the face exactly as before.
    var glyph: String?
    /// false: the caller puts the glass behind this face itself. The overlay
    /// stick draws the face at pad size and scales it to the control; glass
    /// under that scaleEffect is drawn off-centre from the ring and knob.
    var glass = true
    private var expanded: Bool { held || alwaysExpanded }

    static let idleDiameter: CGFloat = 22
    static let padRadius: CGFloat = 58
    private var idleDiameter: CGFloat { Self.idleDiameter }
    private var padRadius: CGFloat { Self.padRadius }
    private let knobTravelRatio: CGFloat = 0.30

    private func knobOffset(_ d: CGFloat) -> CGSize {
        guard dir >= 0, expanded else { return .zero }
        let travel = d * knobTravelRatio
        let a = Double(dir) * 45.0 * .pi / 180.0
        return CGSize(width: travel * CGFloat(sin(a)), height: -travel * CGFloat(cos(a)))
    }

    var body: some View {
        let d = expanded ? padRadius * 2 : idleDiameter
        let face = ZStack {
            Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: expanded ? 2 : 1.5)
            if let g = glyph, !expanded {
                Image(systemName: g)
                    .font(.system(size: d * 0.62, weight: .medium))
                    .foregroundColor(.white)
                    .opacity(0.95)
            }
            Circle()
                .fill(Color.white)
                .frame(width: d * 0.42, height: d * 0.42)
                .overlay(
                    // Roundness cue. It reads at key size but turns into a
                    // smudge on the big pad, so it fades out as the ring
                    // springs open rather than scaling up with it.
                    Circle()
                        .trim(from: 0.55, to: 0.70)
                        .stroke(Color.black.opacity(0.38),
                                style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .padding(d * 0.075)
                        .opacity(expanded ? 0 : 1)
                )
                .overlay {
                    // Dark on the white knob, inside its rim: it reads at rest and
                    // follows the knob when the stick is deflected.
                    if let g = glyph, expanded {
                        Image(systemName: g)
                            .font(.system(size: d * 0.22, weight: .semibold))
                            .foregroundColor(.black)
                            .opacity(0.62)
                    }
                }
                .offset(knobOffset(d))
                // A glyph-bearing ring at idle size shows the glyph instead of the knob.
                .opacity(glyph == nil || expanded ? 1 : 0)
        }
        .frame(width: d, height: d)
        // The ring, glyph and knob are the glass's content, not siblings of it:
        // an overlay stick sits in the controls' GlassEffectContainer, which
        // composites every glass over its siblings and blurred the knob.
        if glass {
            face.glassFace(GlassShape(circle: true))
        } else {
            face
        }
    }
}

/// On-screen thumbstick. Idle it is a key-sized ring with a white knob;
/// press and hold and it expands into a pad you can steer. Travel snaps to
/// eight d-pad directions, each mapped to the arrow keys Windows games
/// already understand — diagonals simply hold two keys at once — so this
/// needs no new input path: it posts through the same winios_post_key queue
/// as the key buttons, and key state is edge-triggered (only the keys that
/// actually changed are sent on each snap).
///
/// The pad expands DOWNWARD. It must never grow up into the game strip:
/// that surface is a raw window-level UIView (MetalHostView.shared) drawn
/// over SwiftUI, so anything overlapping it is simply covered.
struct JoystickKeyView: View {
    @State private var held = false
    @State private var dir: Int = -1        // -1 = centred, else 0=up then clockwise
    @State private var center: CGPoint = .zero
    @State private var hosted = false       // overlay window up: it draws the face

    private let deadzone: CGFloat = 14      // pt of travel before a direction registers

    private let vkUp: Int32 = 0x26, vkRight: Int32 = 0x27
    private let vkDown: Int32 = 0x28, vkLeft: Int32 = 0x25

    private func keys(for d: Int) -> [Int32] {
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

    /// Release what is no longer held, press what newly is — never a blanket
    /// release/re-press, which would make a held direction stutter as the
    /// thumb wanders inside one sector.
    private func apply(_ next: Int) {
        guard next != dir else { return }
        let old = Set(keys(for: dir)), new = Set(keys(for: next))
        for vk in old.subtracting(new) { winios_post_key(vk, 0) }
        for vk in new.subtracting(old) { winios_post_key(vk, 1) }
        dir = next
        JoystickPadState.shared.dir = next
    }

    private func snap(_ t: CGSize) -> Int {
        let d = (t.width * t.width + t.height * t.height).squareRoot()
        if d < deadzone { return -1 }
        // Screen y grows downward; measure clockwise from "up".
        var a = atan2(t.width, -t.height) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    var body: some View {
        // The idle ring lives in the row (inset inside the 34x30 button so it
        // has breathing room). The EXPANDED pad is drawn by the window-level
        // host at this same centre — see JoystickPadState — so it springs out
        // of the button in place and is never clipped by the game surface.
        Color.clear
            .frame(width: 34, height: 30)
            .background(Color.white.opacity(held ? 0.30 : 0.15))
            .cornerRadius(6)
            .overlay { if !hosted { JoystickFace(held: false, dir: -1) } }
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        center = CGPoint(x: geo.frame(in: .global).midX,
                                         y: geo.frame(in: .global).midY)
                        JoystickPadState.shared.center = center
                        if let scene = UIApplication.shared.connectedScenes
                            .compactMap({ $0 as? UIWindowScene }).first {
                            JoystickPadHost.attach(to: scene)
                            hosted = true
                        }
                    }
                    .onChange(of: geo.frame(in: .global)) { _, f in
                        center = CGPoint(x: f.midX, y: f.midY)
                        JoystickPadState.shared.center = center
                    }
                }
            )
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: held)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !held {
                            held = true
                            if let scene = UIApplication.shared.connectedScenes
                                .compactMap({ $0 as? UIWindowScene }).first {
                                JoystickPadHost.attach(to: scene)
                            }
                            JoystickPadState.shared.center = center
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                                JoystickPadState.shared.held = true
                            }
                        }
                        apply(snap(g.translation))
                    }
                    .onEnded { _ in
                        apply(-1)                        // releases every held arrow
                        held = false
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                            JoystickPadState.shared.held = false
                        }
                    }
            )
    }
}

// SwiftUI wrapper around the placeholder view.
// iOS software-keyboard → Wine key events. Each character is mapped to a
// US-layout virtual-key (+ shift where needed) and posted as a down/up pair;
// the message queue's ToUnicode then produces the right WM_CHAR. Paths need
// the full symbol set (":" "\" "-" "." "_"), so the table is comprehensive.
extension MetalBackedView: UIKeyInput {
    var hasText: Bool { false }

    // US-keyboard VK + shift for a character. Returns nil for chars we can't map.
    static func vkForChar(_ ch: Character) -> (Int32, Bool)? {
        if ch == "\n" || ch == "\r" { return (0x0D, false) }   // VK_RETURN
        if ch == "\t" { return (0x09, false) }                 // VK_TAB
        if ch == " " { return (0x20, false) }                  // VK_SPACE
        if ch.isLetter, let up = ch.uppercased().first?.asciiValue, up >= 0x41, up <= 0x5A {
            return (Int32(up), ch.isUppercase)                 // VK_A..VK_Z
        }
        if let a = ch.asciiValue, a >= 0x30, a <= 0x39 {
            return (Int32(a), false)                           // VK_0..VK_9 (unshifted)
        }
        let table: [Character: (Int32, Bool)] = [
            "!": (0x31, true), "@": (0x32, true), "#": (0x33, true), "$": (0x34, true),
            "%": (0x35, true), "^": (0x36, true), "&": (0x37, true), "*": (0x38, true),
            "(": (0x39, true), ")": (0x30, true),
            "-": (0xBD, false), "_": (0xBD, true),
            "=": (0xBB, false), "+": (0xBB, true),
            "[": (0xDB, false), "{": (0xDB, true),
            "]": (0xDD, false), "}": (0xDD, true),
            "\\": (0xDC, false), "|": (0xDC, true),
            ";": (0xBA, false), ":": (0xBA, true),
            "'": (0xDE, false), "\"": (0xDE, true),
            ",": (0xBC, false), "<": (0xBC, true),
            ".": (0xBE, false), ">": (0xBE, true),
            "/": (0xBF, false), "?": (0xBF, true),
            "`": (0xC0, false), "~": (0xC0, true),
        ]
        return table[ch]
    }

    func insertText(_ text: String) {
        // A hardware keyboard's presses reach Wine raw (HardwareInput); UIKit
        // also delivers them here as text, which would type every key twice.
        if HardwareInput.shared.handlesTyping { return }
        for ch in text {
            guard let (vk, shift) = MetalBackedView.vkForChar(ch) else { continue }
            if shift { winios_post_key(0x10, 1) }   // VK_SHIFT down
            winios_post_key(vk, 1)
            winios_post_key(vk, 0)
            if shift { winios_post_key(0x10, 0) }    // VK_SHIFT up
        }
    }

    func deleteBackward() {
        if HardwareInput.shared.handlesTyping { return }
        winios_post_key(0x08, 1)   // VK_BACK down
        winios_post_key(0x08, 0)
    }

    // Traits: keep iOS from rewriting path characters.
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
}

/// Pointer settings, persisted to the app container.
///
/// ml641. Two independent sensitivities, because the two modes mean different
/// things and a single slider would fight itself:
///   • absolute  — trackpad gain, desktop px per view pt. This IS the old
///     hardcoded `sens = 2.0`, so the default reproduces today's desktop feel
///     exactly.
///   • relative  — mouse counts per view pt for mouse-look. What the right value
///     is depends on the GAME's own sensitivity and FOV, which we cannot see, so
///     it has to be calibrated by hand once. See the comment in touchesMoved.
///
/// Stored as JSON in Documents/ rather than UserDefaults: that is the container
/// we already know survives reinstall (verified), and it can be pulled and
/// edited with the same devicectl command we use for the log.
final class InputSettings: ObservableObject {
    static let shared = InputSettings()

    @Published var relative: Bool  = false { didSet { save() } }
    @Published var sensAbs:  Double = 2.0  { didSet { save() } }
    @Published var sensRel:  Double = 2.0  { didSet { save() } }
    /// Touch pointer mode (MetalBackedView.touchModeBegan): tap to click where
    /// the finger is, hold or move to drag. Checked before `relative`; the
    /// library's pointer picker keeps the two mutually exclusive.
    @Published var touchMode = false { didSet { save() } }
    /// ml649: heavy diagnostics. Default OFF so the shipped default is the fast
    /// path; flip it on only when a run needs to be explainable.
    @Published var diagnostics = false { didSet { madeira_set_diag_enabled(diagnostics ? 1 : 0); save() } }
    /// Hardware mouse gain (HardwareInput): counts per reported unit. 1.0 passes
    /// the device's deltas through unchanged.
    @Published var sensMouse: Double = 1.0 { didSet { save() } }
    /// Drop AssistiveTouch's synthesised clicks while a hardware mouse is live
    /// (HardwareInput.shouldIgnore). `"ignoreTouchesWithMouse": false` in
    /// madeira-input.json turns the filter off.
    @Published var ignoreTouchesWithMouse = true { didSet { save() } }
    /// "Right stick controls mouse" (HardwareInput.swift, PadStickMouse). Off by
    /// default: a program that reads the controller already gets the stick.
    @Published var padRightStickMouse = false { didSet { save() } }

    /// didSet fires for assignments made in init() because the properties are
    /// already initialised by then; without this the first launch would write
    /// the defaults back over a file it had only half-read.
    private var loading = false

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-input.json")
    }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            relative = j["relative"] as? Bool   ?? false
            sensAbs  = j["sensAbs"]  as? Double ?? 2.0
            sensRel  = j["sensRel"]  as? Double ?? 2.0
            touchMode = j["touchMode"] as? Bool ?? false
            diagnostics = j["diagnostics"] as? Bool ?? false
            sensMouse = j["sensMouse"] as? Double ?? 1.0
            ignoreTouchesWithMouse = j["ignoreTouchesWithMouse"] as? Bool ?? true
            padRightStickMouse = j["padRightStickMouse"] as? Bool ?? false
        }
        loading = false
        madeira_set_diag_enabled(diagnostics ? 1 : 0)   // push the restored value down
    }

    private func save() {
        guard !loading else { return }
        let j: [String: Any] = ["relative": relative, "sensAbs": sensAbs, "sensRel": sensRel, "diagnostics": diagnostics,
                                "sensMouse": sensMouse, "ignoreTouchesWithMouse": ignoreTouchesWithMouse,
                                "padRightStickMouse": padRightStickMouse,
                                "touchMode": touchMode]
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
        try? d.write(to: Self.url, options: .atomic)
    }
}

struct MadeiraMetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MetalBackedView {
        return MetalBackedView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }
    func updateUIView(_ uiView: MetalBackedView, context: Context) {}
}

struct ContentView: View {
    /// iOS 26 and later blur content under the navigation bar themselves.
    private static var systemScrollEdge: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
    @State private var devSheet: SettingsSheet?
    @StateObject private var logStore = LogStore.shared
    @StateObject private var jitCoordinator = JITCoordinator.shared
    @State private var jitStatus: JITStatus = .unknown
    /// Play without JIT: the start that waits for Enable JIT (jitReadyForLaunch).
    @State private var launchAfterJIT: (() -> Void)?
    @State private var entitlements: EntitlementStatus?
    @State private var debuggerAttached = isDebuggerAttached()
    @ObservedObject private var input = InputSettings.shared
    @State private var pointerPanel = false
    @State private var desktopSizeTick = 0   // ml1157: bumps after a Resolution pick
    @Namespace private var pointerNS
    /// The library front end (Library.swift). When it is the chosen interface it
    /// replaces both bodies below, and a running library session gets the
    /// full-screen `sessionBody`.
    @ObservedObject private var library = LibraryModel.shared
    /// "Use New Interface" (actionButtons) applies at the next start.
    @State private var showFrontendRestart = false

    enum JITStatus {
        case unknown
        case testing
        case available
        case mappingOnly
        case unavailable
    }

    var body: some View {
        /* ml658: was NavigationView, which is deprecated and — the reason this
         * matters — defaults to a SPLIT VIEW on iPad. TARGETED_DEVICE_FAMILY is
         * "1,2", so iPad is a shipping target, and the whole UI was being forced
         * into a sidebar/detail arrangement it was never laid out for.
         * NavigationStack is single-column on every device. Safe here: there are
         * no NavigationLinks anywhere in the app, so nothing depended on the
         * two-column selection behaviour. */
        NavigationStack {
            Group {
                if library.enabled && library.current != nil {
                    sessionBody
                        .navigationBarHidden(true)
                } else if library.enabled {
                    LibraryView(play: launchLibraryEntry, enableJIT: enableJIT,
                                startDock: { startDock($0, compactPool: $1) })
                } else {
                    developerBody
                }
            }
            .navigationTitle("Madeira")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.regularMaterial, for: .navigationBar)
            // The library keeps a material bar only before iOS 26. From iOS 26 the
            // system draws its soft scroll edge effect instead: content scrolls
            // under the title, the buttons and the search field behind a
            // progressive blur (as in the App Store), with no hard edge.
            .toolbarBackground(library.enabled && !Self.systemScrollEdge ? .visible : .automatic, for: .navigationBar)
            // A second session cannot start in this process; offer to close Madeira.
            .alert("Restart Madeira", isPresented: Binding(get: { library.restartNotice != nil },
                                                            set: { if !$0 { library.restartNotice = nil } })) {
                Button("Close Madeira") {
                    LogStore.shared.log("[session-once] closed by the user for a restart")
                    exit(0)
                }
                Button("Later", role: .cancel) { library.restartNotice = nil }
            } message: { Text(library.restartNotice ?? "") }
            // CS_DEBUGGED without a debugger (JIT enabled outside Madeira): offer Madeira's own request.
            .alert("Enable JIT", isPresented: Binding(get: { library.jitNotice != nil },
                                                      set: { if !$0 { library.jitNotice = nil } })) {
                Button("Enable JIT") { library.jitNotice = nil; enableJIT() }
                Button("Later", role: .cancel) { library.jitNotice = nil }
            } message: { Text(library.jitNotice ?? "") }
            .sheet(isPresented: $jitCoordinator.showSetup) { JITSetupView() }
            // A Steam game's saves may not be the latest (cloudClear).
            .alert(library.cloudNotice?.title ?? "Steam Cloud", isPresented: Binding(get: { library.cloudNotice != nil },
                                                                                     set: { if !$0 { library.cloudNotice = nil } })) {
                if let notice = library.cloudNotice {
                    switch notice.kind {
                    case .syncing: Button("Wait and sync") { library.cloudNotice = nil; cloudWait(notice.appID) }
                    case .unchecked: Button("Try again") { library.cloudNotice = nil; cloudWait(notice.appID) }
                    case .conflict:
                        Button("Choose") {
                            library.cloudNotice = nil; library.cloudRetry = nil
                            library.showDetail = library.entries.first { $0.steamAppID == notice.appID }?.id
                        }
                    }
                    Button("Launch anyway") {
                        LogStore.shared.log("[steam-cloud] app=\(notice.appID) before-play: launched anyway")
                        library.cloudNotice = nil; library.cloudBypass = notice.appID
                        let retry = library.cloudRetry; library.cloudRetry = nil; retry?()
                    }
                    Button("Cancel", role: .cancel) { library.cloudNotice = nil; library.cloudRetry = nil }
                }
            } message: { Text(library.cloudNotice?.message ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                library.refreshFlag()
                if library.enabled && library.current == nil { MetalHostView.shared.isHidden = true }
            }
            .onAppear {
                jit_install_trap_handler()
                entitlements = EntitlementStatus.check()
                logEntitlementStatus()
                logStore.log("[build] \(BuildStamp.text)")
                DeviceDiagnostics.logStartup()
                DockOffline.begin()
                FrontendChoice.logStartup()
                DeviceLoadDiagnostics.start()
                // Madeira Dock: an unconsumed sign-in transfer from an earlier run goes.
                if wine_process_is_running() == 0 { MadeiraDock.cleanup() }
            }
            .onReceive(NotificationCenter.default.publisher(for: SteamSignIn.didChange)) { _ in
                if !SteamSignIn.isSignedIn { MadeiraDock.cleanup() }
            }
            // A Home Screen shortcut (madeira://play?exe=...) starts its library entry,
            // now or, from a cold start, once the library is up.
            .onReceive(ShortcutRouter.shared.$pendingExe) { _ in launchPendingShortcut() }
            .onChange(of: library.enabled) { _, _ in launchPendingShortcut() }
        }
    }

    /// The developer interface. Orientation comes from the view's own shape, not
    /// verticalSizeClass: iPad is .regular in BOTH orientations, so the size-class
    /// test kept the portrait tooling (badges, buttons, log) on screen after
    /// rotating. On iPad the keyboard is excluded from the measurement, otherwise
    /// raising it in portrait would make the view wider than tall; an iPhone's
    /// keyboard never does, so there the portrait layout still makes room for it.
    private var developerBody: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            Group {
                if landscape {
                    landscapeBody
                } else {
                    portraitBody
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // Rotation destroys/recreates the UIViewRepresentable across
            // this if/else (two SwiftUI identities) — HARMLESS since
            // 2026-07-05: MetalHostView is a process-lifetime singleton;
            // a fresh placeholder only re-parents the same CAMetalLayer.
            .navigationBarHidden(landscape)
            // ml1157: landscape is the desktop, edge to edge -- no status bar
            // over its top rows, and the home indicator fades out.
            .statusBarHidden(landscape)
            .persistentSystemOverlays(landscape ? .hidden : .automatic)
            // The landscape controls window re-frames to the rotated scene.
            .onChange(of: landscape) { _, _ in TouchControlsHost.attach() }
        }
        .ignoresSafeArea(UIDevice.current.userInterfaceIdiom == .pad ? .keyboard : [])
    }

    /// A library session: the game full screen in either orientation, with the
    /// library's menu button, starting screen and in-game menu drawn above it by
    /// TouchControlsOverlay (LibraryHUD), in the window above the game surface.
    private var sessionBody: some View {
        ZStack {
            Color.black
            MadeiraMetalView()
                .onAppear { TouchControlsHost.attach() }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIDevice.orientationDidChangeNotification)) { _ in
                    TouchControlsHost.attach()   // re-frame to the new bounds
                }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .statusBarHidden(true)
    }

    /// Portrait: classic tooling layout — header, badges, 240pt game strip,
    /// key row, action buttons, log console.
    private var portraitBody: some View {
        VStack(spacing: 0) {
            // Readouts sit ABOVE the game strip, closest to the surface they
            // describe: entitlement indicators, then the present/FPS readout,
            // then the surface itself. (Only the KEY row stays below — it is
            // input, not instrumentation.)
            //
            // NOTE: the surface is a raw window-level view positioned over the
            // placeholder (MetalHostView.shared), so SwiftUI content laid "on
            // top" of the strip is covered — these rows must be siblings above
            // it, never overlays on it.
            if let ents = entitlements {
                entitlementBadges(ents)
            }
            HStack(spacing: 6) {
                FPSOverlay()
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            MadeiraMetalView()
                .frame(height: 240)
                .background(Color.black)
                .onAppear { TouchControlsHost.attach() }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIDevice.orientationDidChangeNotification)) { _ in
                    TouchControlsHost.attach()   // re-frame to the new bounds
                }
            HStack(spacing: 6) {
                if pointerPanel {
                    // The cursor button has slid to the leftmost slot and become
                    // the close control; matchedGeometryEffect animates the slide.
                    pointerToggleButton
                    pointerModeToggle
                    pointerSensSlider
                } else {
                    Group {
                        keyButton("⏎", vk: 0x0D)   // VK_RETURN
                        keyButton("␣", vk: 0x20)   // VK_SPACE
                        keyButton("Esc", vk: 0x1B) // VK_ESCAPE
                        Button { MetalBackedView.toggleKeyboard() } label: {
                            Text("⌨").font(.system(size: 20))
                                .frame(minWidth: 40, minHeight: 32)
                                .background(Color.secondary.opacity(0.25))
                                .cornerRadius(6)
                        }
                        JoystickKeyView()
                    }
                    .transition(.opacity)
                    pointerToggleButton
                    diagToggleButton
                    Spacer()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // The expanded pad overflows this row; without a raised zIndex the
            // later VStack siblings (action buttons, log) would draw over it.
            .zIndex(10)
            // Mouse gain, pointer lock and "Right stick controls mouse" while the
            // pointer panel is open and such a device is attached, plus the
            // iPhone AssistiveTouch hint (HardwareInput.swift).
            HardwareInputSettings(open: pointerPanel)
            Divider()
            actionButtons
            Divider()
            logConsole
        }
    }

    /// Landscape: game mode. Full-height 4:3 surface centered (aspect-fit
    /// happens in MetalBackedView); ALL controls live in the pillarbox
    /// bars left/right of the game — the window-level surface would cover
    /// anything drawn over the game area itself. No header/log/nav chrome.
    private var landscapeBody: some View {
        GeometryReader { geo in
            let gameW = min(geo.size.width, geo.size.height * 4.0 / 3.0)
            let barW = max((geo.size.width - gameW) / 2.0, 44)
            ZStack {
                Color.black
                MadeiraMetalView()
                    // A launch straight into landscape never shows the portrait
                    // layout, which is otherwise what creates the controls window
                    // (its top bar carries the keyboard button here).
                    .onAppear { TouchControlsHost.attach() }
                // Controls removed for now (ml586): game-only landscape.
                // The FPS readout stays, pinned in the right pillarbox bar —
                // the window-level surface covers anything drawn over the
                // game area itself, so it cannot ride on the game view.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack {
                        FPSOverlay(compact: true)
                        Spacer()
                    }
                    .frame(width: barW)
                }
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
    }

    /// Hold-to-press key: VK down on touch, VK up on release — for keys
    /// games treat as held (arrows). Same winios queue as keyButton.
    private func holdKeyButton(_ label: String, vk: Int32, big: Bool = false) -> some View {
        HoldKeyView(label: label, vk: vk, big: big)
    }

    /// Small on-screen key: posts VK down, then up 60ms later, through the
    /// winios input queue (same path as touch→mouse).
    // ml641 pointer panel ------------------------------------------------
    private var pointerToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.28)) { pointerPanel.toggle() }
            // The window-level pad fades itself; see JoystickPadState.hidden.
            JoystickPadState.shared.hidden = pointerPanel
        } label: {
            Image(systemName: pointerPanel ? "xmark" : "cursorarrow")
                .font(.system(size: 17, weight: .medium))
                .frame(minWidth: 40, minHeight: 32)
                .background(Color.secondary.opacity(0.25))
                .cornerRadius(6)
        }
        .matchedGeometryEffect(id: "pointerBtn", in: pointerNS)
    }

    /// ml649: heavy diagnostics on/off, live. Stroke icon, dimmed when quiet —
    /// same visual language as the controls-visibility button.
    private var diagToggleButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            input.diagnostics.toggle()
        } label: {
            Image(systemName: "ladybug")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.white.opacity(input.diagnostics ? 1.0 : 0.35))
                .frame(minWidth: 40, minHeight: 32)
                .background(Color.secondary.opacity(0.25))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private var pointerModeToggle: some View {
        Button {
            // Touch mode is chosen in the library; this button leaves it for Absolute.
            if input.touchMode { input.touchMode = false; input.relative = false }
            else { input.relative.toggle() }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(input.touchMode ? "Touch" : input.relative ? "Relative" : "Absolute")
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 82, minHeight: 32)
                .background((input.relative ? Color.accentColor : Color.secondary).opacity(0.28))
                .cornerRadius(6)
        }
        .transition(.opacity)
    }

    /// One slider bound to whichever mode is live, so the two values are edited
    /// independently and both persist.
    private var pointerSensSlider: some View {
        HStack(spacing: 8) {
            Slider(value: input.relative ? $input.sensRel : $input.sensAbs, in: 0.10...8.0)
            Text(String(format: "%.2f", input.relative ? input.sensRel : input.sensAbs))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    /// ml896: NOT a Button. A Button's press highlight is an implicit animation,
    /// and SwiftUI renders animations on its AsyncRenderer thread, which needs a
    /// CAPresentationModifierGroup, whose shared memory comes from a tagged
    /// purgable vm_allocate that fails once a game is running (three crash
    /// reports, all in commitAsyncValues force-unwrapping that nil). HoldKeyView
    /// changes only a colour with no animation, so it stays on the main-thread
    /// render path the rest of this UI already uses for minutes without harm.
    /// Down at touch, up at lift, which is also the correct key semantics.
    private func keyButton(_ label: String, vk: Int32) -> some View {
        HoldKeyView(label: label, vk: vk)
    }

    private func entitlementBadges(_ ents: EntitlementStatus) -> some View {
        HStack(spacing: 8) {
            // Live debugger/JIT state, not the (macOS-only, never granted on
            // iOS) allow-jit entitlement the old badge checked.
            entitlementBadge("JIT", granted: debuggerAttached)
            entitlementBadge("Memory+", granted: ents.increasedMemory)
            entitlementBadge("64-bit VA", granted: ents.extendedVA)
            Spacer()
            // Device model rides in this row (the old standalone statusHeader
            // row above it spent ~50pt of vertical space on nothing else).
            VStack(alignment: .trailing, spacing: 0) {
                Text("Device")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(deviceInfo)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                // Which build is installed (BuildStamp, Library.swift).
                if BuildStamp.visible {
                    Text(BuildStamp.text)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(.systemGray2))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            debuggerAttached = isDebuggerAttached()
        }
    }

    private func entitlementBadge(_ label: String, granted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(granted ? .green : .orange)
                .font(.caption2)
            Text(label)
                .font(.caption2)
                .foregroundColor(granted ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(granted ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        )
    }

    private func logEntitlementStatus() {
        guard let ents = entitlements else { return }
        logStore.log("Checking entitlements...")
        logStore.log("  allow-jit: \(ents.jitAllowed)", level: ents.jitAllowed ? .success : .error)
        logStore.log("  increased-memory-limit: \(ents.increasedMemory)", level: ents.increasedMemory ? .success : .debug)
        logStore.log("  extended-virtual-addressing: \(ents.extendedVA)", level: ents.extendedVA ? .success : .debug)
        // The memory limit is the entitlement a session needs; the address map may
        // be the standard 63 GB one.
        if !ents.increasedMemory {
            logStore.log("  Tip: Use GetMoreRam to add increased-memory-limit", level: .info)
        }
    }

    private var actionButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if SteamSignIn.isEnabled {
                    Button("Steam sign-in") { devSheet = .steamSignIn }
                        .buttonStyle(.bordered)
                }
                if MadeiraDock.enabled {
                    Button("Madeira Dock") { devSheet = .dock }
                        .buttonStyle(.bordered)
                }
                Button("All settings") { devSheet = .allSettings }
                    .buttonStyle(.bordered)
                Button("Enable JIT") {
                    enableJIT()
                }
                .buttonStyle(.borderedProminent)

                Button("Steam Testing") {
                    // Steam S3 first boot: virtual desktop (Steam needs a
                    // window manager) + services.exe (SCM → rpcss for Steam's
                    // COM, the chain proven in the rpcss milestone) + steam.exe
                    // itself, all launched by C:\steam-launch.bat (pushed to
                    // the prefix). Batch avoids quote-escaping hell; combase's
                    // 5s OpenSCManager retry covers the services-vs-steam race.
                    // Steam install = CrossOver copy at C:\Program Files (x86)\
                    // Steam (all boot binaries verified x86-64; steamwebhelper
                    // /libcef = 209MB → watch pool: first webhelper may fit,
                    // multiples need .text sharing). Flags: -no-cef-sandbox
                    // (sandbox can't work in Wine), -cef-disable-gpu (software
                    // render), -console (Steam's own log → our stderr). Steam
                    // WILL try to self-update through our GnuTLS stack — that
                    // attempt is itself an informative S0 re-test.
                    let deskW = 1024, deskH = 768
                    // ml589: find Steam and (re)write the launch batch. Returns
                    // false — having logged why — when there is nothing to run.
                    guard prepareSteamLaunch() else { return }
                    // ml590 STEP 1 (one-run phase check, NOT a timing measurement):
                    // arm the ml578 sock-wire probe. It answers exactly one
                    // question — does today's ~1s CM failure reach the same TLS
                    // phase ml578 did (ServerHello -> client Finished -> server
                    // encrypted records), or does it die earlier?
                    //
                    // Its numbers are NOT trustworthy as timings: no monotonic
                    // clock, a getpeername() before EVERY send/recv even after the
                    // 12-line budget is spent, and synchronous dprintf() on a path
                    // whose whole ping budget is 1000ms — it perturbs what it
                    // measures, which is why ml579 gated it off. Step 2 replaces it
                    // with a per-socket timeline (cached peer, generation counter,
                    // one line at close) that can be trusted for timing.
                    //
                    // COLD LAUNCH REQUIRED: ios_sock_wire() latches this env into a
                    // static on its FIRST call (socket.c:842), so if any earlier
                    // Wine session in this app process already touched a socket the
                    // flag is stuck off. Force-quit, launch, press this first.
                    // ml591: the phase question is ANSWERED, so the per-event
                    // probe goes back off — it distorts the very budget step 2
                    // measures. [sock-tl] replaces it and needs no env var.
                    unsetenv("MADEIRA_SOCK_WIRE")
                    // ml594 A/B: post-login hang = FEX optimizer NONTERMINATION.
                    // Chrome_InProcRendererThread (wtid 0208) sampled 9x at
                    // 97-100% CPU (cpu=277 -> 918, run=1) inside
                    // DeadFlagCalculationEliminination::ProcessBlock while EVERY
                    // other thread sat at cpu=0 and Steam presented ZERO further
                    // frames. One CompileBlock entered that pass and never came
                    // back, and the thread holds a fexlock read ref, so it can
                    // stall other FEX threads too. NOT a network/cryptnet/wineserver
                    // wait — our new guards never fired.
                    //
                    // FEX_O0 disables the default x87 + dead-flag passes
                    // (FEXCore/Source/Interface/IR/PassManager.cpp:70). Slower, but
                    // if the hang disappears the pass is convicted and the next step
                    // is disabling ONLY CreateDeadFlagCalculationEliminination().
                    // ml596: FEX_O0 has NEVER ACTUALLY BEEN TESTED, and my earlier
                    // comment here blaming it for an execute fault was WRONG.
                    // ml595 died because the JIT pool never existed: all three
                    // placement attempts returned 0x7000000000 (the forbidden guest
                    // 64G window), we logged "continuing without it", and Wine then
                    // ran with `pool not initialised` -- so LdrInitializeThunk stayed
                    // at its PE address 0x71ffd77654 instead of being redirected into
                    // the pool (a healthy run logs `redirected PC 0x71ffd77654 ->
                    // 0x12078f654`). The execute fault was the guaranteed consequence
                    // of launching without the execution substrate, and pool placement
                    // happens HERE in Swift before FEX reads any env var -- FEX_O0
                    // cannot influence it. (Caught by Sol.)
                    //
                    // Convict the dead-flag pass with a targeted FEX build that
                    // disables ONLY CreateDeadFlagCalculationEliminination(); broad O0
                    // also drops the x87 pass and proves less. unsetenv keeps a stale
                    // value from a previous launch out of play.
                    unsetenv("FEX_O0")
                    // ml597 A/B: remove ONLY DeadFlagCalculationEliminination, the pass
                    // the renderer thread was pinned inside during the ml594 hang.
                    // Everything else in the pipeline (incl. x87) stays exactly as in a
                    // known-good run, so a result here implicates or clears this one pass.
                    // The [dfe-guard] bounds ship active in BOTH arms — if the pass is
                    // exonerated and the hang recurs, they still name the failure mode.
                    // ml598 ISOLATION RUN: gate OFF, same rebuilt FEX.
                    // ml597 crashed with c000001d (ILLEGAL INSTRUCTION) after the
                    // desktop came up, but that run changed TWO things at once: my
                    // DFE gate AND ~107 lines of FEX source committed today that had
                    // never been built — the shipped xtajit64.dll dated Aug 6 while
                    // Core.cpp/IosJitAlias.cpp/TSOHandlerConfig.h and a net rewrite of
                    // WinAPI/IO.cpp were newer. Any of those can produce a
                    // miscompilation-shaped fault, so ml597 convicts nothing.
                    //   crashes again -> the REBUILD is at fault, DFE still untested
                    //   runs fine     -> disabling DFE is what breaks it
                    unsetenv("MADEIRA_NO_DFE")
                    // ml599: name the pass that corrupts the IR list.
                    //
                    // ml598 settled the mechanism: FEX hangs walking a block
                    // BACKWARDS because the intrusive Previous chain never reaches
                    // CodeBegin. Two passes make that assumption —
                    // DeadFlagCalculationEliminination::ProcessBlock and
                    // ConstrainedRAPass::Run — and the store-page freeze was the
                    // second one (PC pinned inside libarm64ecfex.dll RVA
                    // 0x100b0c-0x100cdc, all within ConstrainedRAPass::Run, for
                    // minutes at ~100% CPU while frames stayed at 4,114).
                    //
                    // Both now validate the block BEFORE touching it and repair the
                    // Previous chain from the forward chain when that is intact, so
                    // the hang should be gone either way. This var adds the sweep
                    // that reports WHICH pass first breaks the list, so the run also
                    // produces the root cause and not just the containment.
                    // ml601: SWEEP OFF. Two runs checked 118M and 47M blocks and found
                    // corruption exactly once (block 260, ml599b) — the after-every-pass
                    // sweep is not earning its cost, and it taxes every large compile.
                    // The unconditional parts STAY ON regardless of this variable: the
                    // cheap backward check at DFE and RA entry, the repair, and the
                    // bounded-walk guards. Only the attribution sweep is disabled.
                    // Set it again for a run that is specifically hunting the corrupter.
                    unsetenv("MADEIRA_IR_TOPO")
                    // ml623: TARGETED IR/RA CAPTURE for the ULTRAKILL Mono wall.
                    //
                    // FEX miscompiles ONE instruction in Mono's x86-64 emitter:
                    //   mono-2.0-bdwgc.dll+0x4db25b   mov byte ptr [rcx+2], al
                    // With RCX=0x7040140010 (valid, a fresh RWX code buffer) and AL=0x4c,
                    // it emitted `movz w6,#0x44 ; orr x8,x8,x6 ; dmb ish ; strb w8,[x6,xzr]`
                    // -- the address register still held the IMMEDIATE because the
                    // `add x6, x0, #2` that BOTH sibling branches emit was never generated,
                    // so the store landed on 0x44.
                    //
                    // This prints that instruction's IR after the frontend and after every
                    // pass, plus the emitted host bytes. The last stage at which the address
                    // computation still exists names the culprit: frontend/decoder, a named
                    // pass, RA liveness, or the ARM emitter.
                    //
                    // Compile-time only, capped at 4 captures. Unset it for a normal run.
                    setenv("MADEIRA_IRCAP_RVA", "0x4db25b", 1)
                    setenv("MADEIRA_IRCAP_MODULE", "mono-2.0-bdwgc.dll", 1)
                    setenv("MADEIRA_EXE", "explorer.exe", 1)
                    setenv("MADEIRA_ARGS",
                           "/desktop=shell,\(deskW)x\(deskH) cmd /c C:\\steam-launch.bat", 1)
                    setenv("MADEIRA_DESKTOP", "1", 1)
                    setenv("MADEIRA_SCREEN_W", String(deskW), 1)
                    setenv("MADEIRA_SCREEN_H", String(deskH), 1)
                    winios_display_mode_changed(Int32(deskW), Int32(deskH))
                    // ml371: surfdump ground truth — the "frozen desktop"
                    // question (fresh pixels never presented vs nothing
                    // painting upstream) is undecidable from the log alone
                    // because the [winios] present line caps at 12.
                    // ml556: surface PNG dumping also off for the clean baseline —
                    // it encodes a PNG on the present path. Restore "1" to re-enable.
                    unsetenv("MADEIRA_DUMP_SURFACES")
                    // ml493: bursts of N CONSECUTIVE frames per window. The
                    // login window's black regions change every frame, which
                    // the 2s-throttled first/latest dump can never show —
                    // adjacent frames are the only way to measure what moves.
                    setenv("MADEIRA_SURF_SEQ", "10", 1)
                    // ml515: SRCWATCH RE-ENABLED, now hooked in the MACH
                    // exception handler (where guest faults are actually
                    // delivered) instead of segv_handler. It consumes its own
                    // faults BEFORE every other classification and marks them
                    // handled via the canonical thread_set_state path, so a
                    // protection fault can no longer reach the guest as an AV.
                    // ml514 hooked the wrong path: 0 faults, black window 2/2.
                    /* ml530 (#78): srcwatch subject = the assembled steamui JS buffer, not the
                     // render bitmap. "1" would mean the legacy render subject, and the
                     // watch arms only ONCE — so with both call sites live, whichever ran
                     // first would silently win and the other would never arm at all.
                     //
                     // Target: V8 reports `SyntaxError: Invalid or unexpected token` on
                     // steamui JS that our file reads deliver byte-perfect (ml489: 73/73
                     // MATCH, the failing file 100% verified through NtReadFile). That is
                     // the DOMINANT Steam variance — 27 of 45 attempts stall right after
                     // BrowserReady because the UI script never parses — and the same
                     // corrupter family as the render glitch, so it buys both. */
                    /* ml533: back to the RENDER subject — the js subject is structurally
                    // blocked (the failing steamui files are read through a reused 64KB
                    // chunk buffer, so no assembled buffer exists in our view). The render
                    // watch now names the CALLER via the guest return address at [RSP],
                    // which is what the block-granular RIP could never do. */
                    // ml556 CLEAN-BASELINE TEST: srcwatch OFF.
                    //
                    // It write-protects the render bitmap and takes a Mach fault
                    // per page ON THE RENDER HOT PATH, and the correlation across
                    // this session is stark:
                    //     attributions 1824/2370/426/2721 -> run dies at 36-52 s
                    //     attributions 0/0/0              -> run reaches 94-106 s
                    // Runs carrying our instrumentation die in roughly half the
                    // time. Before attributing the crash to Steam or to FEX we owe
                    // ourselves the one-variable control: does it still crash with
                    // the probe off? Re-enable by restoring "render".
                    // ml574: arm the dead-release detector in wineserver.
                    // O(n) walk of object_list on every release_object — slow by
                    // design, diagnostic only. Set to "0" to disarm.
                    // ml579: DISABLED. It walks the global wineserver object list on
                    // EVERY release_object() — O(n) in the single-threaded server. It
                    // already caught the free_async_queue over-release (ml574) and that
                    // fix is shipped; leaving the detector armed just starves the server,
                    // and Steam allows each CM ping only 1000 ms. Set to "1" to re-arm.
                    setenv("MADEIRA_DEAD_RELEASE", "0", 1)
                    setenv("MADEIRA_SRCWATCH", "off", 1)
                    // ml548: restrict srcwatch to the row band where displacement
                    // was actually MEASURED, so the 400-attribution budget is not
                    // spent on the full-frame clear (which touches every page
                    // first and made the content painters invisible in ml517).
                    // Band from ml543 frame 009: the Steam logo core landed at
                    // (96,188) instead of (350,188) — exactly -254 px, one tile
                    // pitch — so rows 150..230 bracket the displaced element.
                    // ml550: was "150,230" — chosen for the SPLASH logo. On a
                    // login-window run that band produced ZERO attributions
                    // (426 on the splash run), because nothing painted there.
                    // Widen to most of the surface so the watch follows whatever
                    // the frame actually draws; the per-page budget still bounds
                    // the fault cost.
                    setenv("MADEIRA_SRCWATCH_ROWS", "0,400", 1)
                    // ml527 (#82 RETEST, ONE VARIABLE): run V8 with its JIT on.
                    //
                    // ml526's phase timeline made the case concrete — of ~39s to
                    // the login window, the single biggest block is 13.0s of
                    // BrowserReady -> GetDesiredSteamUIWindows, i.e. Steam's UI
                    // JavaScript booting, and interpreted V8 costs 5-20x there.
                    //
                    // #82 convicted jitless-off because both trial runs parked
                    // CrBrowserMain shortly after BrowserReady (ml474b +104s,
                    // ml475 +4s). ⚠️ Both ran with StikDebug attached and
                    // spinning, when every trap was a round-trip to a starved
                    // debugger — the overhead that made webhelper bring-up 89s
                    // instead of 9s (b439be6). V8's JIT emits runtime x86, the
                    // heaviest trap/compile workload in the process, so it is
                    // exactly what that overhead punished worst. The verdict may
                    // not survive early detach.
                    //
                    // ⛔ VERDICT (ml527, 2 runs): #82 SURVIVES early detach — jitless
                    // stays ON. Both jitless-off runs died in the SAME window ml474b
                    // and ml475 died in: right after BrowserReady, before
                    // GetDesiredSteamUIWindows was ever reached (13:20:19 and
                    // 13:22:45), so 4/4 across two completely different debugger
                    // regimes. The failure MODE changed — a c0000005 ->
                    // chrome_elf.dll+0xd4153 -> ffff7001 Crashpad termination rather
                    // than #82's park in NtWaitForAlertByThreadId — but the window is
                    // identical, and jitless-ON reaches the login window repeatedly
                    // through that same window.
                    //
                    // No consolation prize either: BrowserReady took 12s and 10s with
                    // the JIT on vs 8-11s (median 9s) with it off, because V8's JIT
                    // emits runtime x86 that FEX must then compile. So the debugger
                    // overhead was NOT what convicted jitless-off, and the 13s of
                    // Steam UI JavaScript stays unmeasured — neither run survived to
                    // reach it.
                    //
                    // Flip to "0" only alongside a fix for the post-BrowserReady death.
                    setenv("MADEIRA_JITLESS", "1", 1)
                    // ml514 note (kept for the record): The ml514 watch
                    // armed correctly (76 pages protected) but logged ZERO
                    // faults and produced an all-black window on two runs: the
                    // hook went in the BSD segv_handler, while guest faults in
                    // this port are handled IN-MACH by the exception server, so
                    // the protection fault was delivered to the guest as an AV
                    // and killed Chromium's paint. A probe must never break the
                    // path it measures. To revive it, hook the Mach exception
                    // server (where ios_emulate_unaligned_guest_access already
                    // runs), not segv_handler, and re-enable this env var.
                    // ml502 sentinel: DELIBERATELY NOT ENABLED. It stamps
                    // magenta into currently-black pixels, and on windows
                    // Chromium does not fully rewrite it SURVIVES and reaches
                    // the screen (console 0x200bc hit untouched=177891 in one
                    // round). It answered its question in ml503/ml504 —
                    // untouched=0 on the login window proved Chromium writes
                    // every pixel — so it must not ship enabled. Re-enable
                    // with MADEIRA_SURF_SENTINEL=1 if the question returns.
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                resolutionPicker

                Button("Wine Virtual Desktop") {
                    // S3-pre R2v2: raw rpcss.exe CANNOT run standalone —
                    // its wmain unconditionally StartServiceCtrlDispatcherW's
                    // (rpcss_main.c:282), which RPCs back to the SCM; without
                    // services.exe it raised + wedged in
                    // service_run_main_thread, and explorer's
                    // CoRegisterClassObject wedged behind it (seq-3680 run).
                    // Proper bootstrap: explorer's cmdline child = services.exe
                    // (SCM host, windows-subsystem = no console). It creates
                    // \pipe\svcctl early, runs auto-start services (MountMgr/
                    // Eventlog/NDIS/nsiproxy/PlugPlay — winedevice/plugplay
                    // are bundled; failures tolerated), and combase's
                    // start_rpcss then demand-starts RpcSs through the SCM
                    // with a 30s start-pending wait → rpcss runs as services'
                    // child (3-deep tree, proven depth) with a proper
                    // dispatcher connection → epmapper up → real COM.
                    // Known risk: if shellwindows_init beats services.exe's
                    // RPC_Init, OpenSCManager fails → watch whether that
                    // fails fast or hits the RaiseException→CS wedge again.
                    // ml1127: `desktop-size = WxH` in madeira.cfg (the Resolution
                    // menu writes it). ml1157/ml1172: otherwise the screen's own
                    // shape (ResolutionChoices), so the desktop fills a landscape
                    // screen with no bars.
                    let (deskW, deskH) = configuredDesktopSize(default: ResolutionChoices.defaultSize())
                    setenv("MADEIRA_EXE", "explorer.exe", 1)
                    setenv("MADEIRA_ARGS",
                           "/desktop=shell,\(deskW)x\(deskH) C:\\windows\\system32\\services.exe", 1)
                    setenv("MADEIRA_DESKTOP", "1", 1)
                    setenv("MADEIRA_SCREEN_W", String(deskW), 1)
                    setenv("MADEIRA_SCREEN_H", String(deskH), 1)
                    winios_display_mode_changed(Int32(deskW), Int32(deskH))
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)

                // ml741: Stray (UE4). Launch the shipping binary DIRECTLY rather
                // than Stray.exe -- the launcher builds its child's command line
                // itself and passed only "Hk_project", so Unreal picked its
                // default RHI. That default is DX12 for this title and we only
                // implement D3D11, which is why the first run sat on an
                // unsignalled event for 97s at startup instead of failing loudly.
                //
                // Args are overridable at runtime from Documents/madeira-args.txt
                // so UE4 flags can be tried without a rebuild; the string below is
                // the default when that file is absent.
                Button("Stray (UE4, -dx11)") {
                    setenv("MADEIRA_EXE",
                           "C:\\Program Files\\Stray\\Hk_project\\Binaries\\Win64\\Stray-Win64-Shipping.exe", 1)
                    var args = "Hk_project -dx11 -windowed"
                    if let txt = MadeiraConfig.get("args") {
                        let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !v.isEmpty { args = v }
                    }
                    setenv("MADEIRA_ARGS", args, 1)
                    unsetenv("MADEIRA_DESKTOP")
                    logStore.log("Stray: args = \(args)")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                // Valley of the Ancient (UE5). Like Stray, the LAUNCHER builds its
                // own child command line and passes only the project name, so any
                // flag we want has to go on the shipping binary directly. Measured
                // from a real run: AncientGame.exe spawns
                //   AncientGame-Win64-Shipping.exe ValleyoftheAncient
                // and nothing else, which is why the launcher is skipped here.
                //
                // Flags come from Documents/madeira-valley-args.txt so a UE switch
                // can be tried without rebuilding and reinstalling. The default
                // carries -ansimalloc because the first two runs both died with
                //   FMallocBinned2 Attempt to free an unrecognized block 885560000
                // at the same address, before any RHI work. Selecting a different
                // allocator says whether that is Binned2's own bookkeeping or a
                // genuine bad free; delete the flag to reproduce the fatal.
                Button("Valley of the Ancient (UE5)") {
                    setenv("MADEIRA_EXE",
                           "C:\\Program Files\\Valley of the Ancient - DX12\\ValleyoftheAncient\\Binaries\\Win64\\AncientGame-Win64-Shipping.exe", 1)
                    var args = "ValleyoftheAncient -windowed -ansimalloc"
                    if let txt = MadeiraConfig.get("valley-args") {
                        let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !v.isEmpty { args = v }
                    }
                    setenv("MADEIRA_ARGS", args, 1)
                    unsetenv("MADEIRA_DESKTOP")
                    logStore.log("Valley: args = \(args)")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)

                Button("Thumper (standalone)") {
                    // Game lives at Documents/wine/drive_c/Program Files/Thumper/
                    // (copied into the prefix by hand during development).
                    setenv("MADEIRA_EXE",
                           "C:\\Program Files\\Thumper\\THUMPER_win10.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    unsetenv("MADEIRA_DESKTOP")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)

                Button("x64 DX11 cube") {
                    setenv("MADEIRA_EXE", "cube-x64.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                // madeira-d3d12 M2: an x86-64 guest driving the ARM64EC D3D12
                // runtime. Creates device/queue/allocator/list/fence, records
                // and closes an empty list, executes it, signals a fence and
                // wakes an event waiter, plus the refusal cases. Prints a build
                // marker naming which architecture it actually reached, which
                // states the loader question as evidence rather than assumption.
                // The visible one: an x86-64 Windows program drawing a rotating
                // cube through our D3D12 interfaces and presenting into the
                // host window. Shaders are still matched fixtures rather than
                // runtime-converted DXIL, which the window title states.
                Button("D3D12 cube") {
                    setenv("MADEIRA_EXE", "d3d12-cube-x64.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)

                Button("D3D12 M2 ABI") {
                    setenv("MADEIRA_EXE", "d3d12-m2-x64.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    unsetenv("MADEIRA_DESKTOP")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)

                // ml731c: one-second check of the Windows clock contract
                // (GetTickCount64 / system time / unbiased interrupt time /
                // QueryPerformanceCounter). Verifying this by hand previously
                // cost a five-minute game run plus a control-log comparison,
                // and the game is too unstable to serve as a measuring tool.
                // Each clock is checked separately so a partial failure names
                // itself: QPC passing alone is the shared-page signature.
                Button("x64 clock test") {
                    setenv("MADEIRA_EXE", "clocktest-x64.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    unsetenv("MADEIRA_DESKTOP")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)

                // ml1131: per-call cost of the imports the game's critical threads
                // live in (GetLastError, QPC, SetEvent, critical sections, heap,
                // event ping-pong, contended sections). Results in the log and in
                // C:\calltest.txt.
                Button("x64 call cost") {
                    setenv("MADEIRA_EXE", "calltest-x64.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    unsetenv("MADEIRA_DESKTOP")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)

                Button("arm64 DX11 cube") {
                    runTriangleTest()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button("Clear Log") {
                    logStore.clear()
                }
                .buttonStyle(.bordered)
                .tint(.red)

                // Back to the library interface (FrontendChoice), at the next start.
                Button("Use New Interface") {
                    FrontendChoice.choose(new: true)
                    showFrontendRestart = true
                }
                .buttonStyle(.bordered)
                .tint(.indigo)
            }
            .padding()
        }
        .alert("Restart Madeira", isPresented: $showFrontendRestart) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Close Madeira from the app switcher and open it again to use the new interface.")
        }
        // One sheet for the strip, not one per button: a sheet attached to a
        // button closed again whenever this often-redrawn screen rebuilt it.
        .sheet(item: $devSheet) { sheet in
            switch sheet {
            case .steamSignIn: SteamSignInView()
            case .dock: MadeiraDockView { startDock($0, compactPool: $1) }
            case .allSettings: AllSettingsView()
            }
        }
    }

    private func runTriangleTest() {
        logStore.log("D3D11 triangle test: full sequence", level: .info)
        // Reuse the existing full Wine sequence but target triangle.exe.
        // WineProcessBridge has the program baked in for now — to flip it
        // requires a signature change. For this iteration we rely on the
        // build's WineProcessBridge.m pointing at triangle.exe.
        runWineFullSequence()
    }

    private var logConsole: some View {
        let entries = logStore.entries.sorted(by: { $0.lastTimestamp > $1.lastTimestamp })
        return List(entries) { entry in
            HStack(alignment: .top, spacing: 8) {
                // Timestamp of LAST occurrence
                Text(timeString(entry.lastTimestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 64, alignment: .leading)
                // Level chip
                Text(entry.level.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(colorForLevel(entry.level))
                    .frame(width: 28, alignment: .leading)
                // Last raw message (the most recent line that matched this signature)
                Text(entry.lastRaw)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                // Count badge (only if count > 1)
                if entry.count > 1 {
                    Text("×\(entry.count)")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                        .foregroundColor(.secondary)
                }
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        }
        .listStyle(.plain)
    }

    // ml540: ONE formatter for the whole app, built once on first use.
    //
    // This used to construct a fresh DateFormatter on every call — once per log
    // row per body evaluation — and each new instance opens ICU underneath
    // (udat_open -> SimpleDateFormat::initialize). That is not just wasteful,
    // it is where ml539 died: after Wine's main thread exited, ICU ran
    // _platform_strcmp on a pointer into that dead thread's stack (x0 sat 0x68C
    // below its recorded tsd_base) and took the whole app down. A single
    // long-lived formatter does the ICU open ONCE, at first log render, long
    // before Wine exists.
    private static let hhmmss: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // Main-thread only (SwiftUI body evaluation) — DateFormatter is not safe to
    // share across threads.
    private func timeString(_ date: Date) -> String {
        ContentView.hhmmss.string(from: date)
    }

    private var statusColor: Color {
        switch jitStatus {
        case .unknown: return .gray
        case .testing: return .yellow
        case .available: return .green
        case .mappingOnly: return .orange
        case .unavailable: return .red
        }
    }

    private var statusText: String {
        switch jitStatus {
        case .unknown: return "Not tested"
        case .testing: return "Testing..."
        case .available: return "Available"
        case .mappingOnly: return "Needs debugger"
        case .unavailable: return "Unavailable"
        }
    }

    private var deviceInfo: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return machine
    }

    private func colorForLevel(_ level: LogStore.LogEntry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .error: return .red
        case .debug: return .gray
        }
    }

    private func runJITTest() {
        jitStatus = .testing
        logStore.log("Starting JIT test...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = jit_test_execute()

            DispatchQueue.main.async {
                switch result {
                case 42:
                    jitStatus = .available
                    logStore.log("JIT is fully functional!", level: .success)
                case -2:
                    jitStatus = .unavailable
                    logStore.log("CS_DEBUGGED not set. Use StikDebug to enable JIT for this app.", level: .error)
                    DispatchQueue.global(qos: .userInitiated).async {
                        let mappingOk = jit_test_mapping()
                        DispatchQueue.main.async {
                            if mappingOk {
                                jitStatus = .mappingOnly
                                logStore.log("Dual mapping works. Enable JIT via StikDebug to unlock execution.", level: .success)
                            }
                        }
                    }
                case -3:
                    jitStatus = .unavailable
                    logStore.log("Fault loop detected — try 'Test JIT (Alt)' for debugger-allocated memory", level: .error)
                default:
                    jitStatus = .unavailable
                    logStore.log("JIT test failed with result: \(result)", level: .error)
                }
            }
        }
    }

    private func runJITTestStrategy2() {
        jitStatus = .testing
        logStore.log("Starting JIT test (Strategy 2: debugger-allocated RX)...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = jit_test_execute_strategy2()

            DispatchQueue.main.async {
                switch result {
                case 42:
                    jitStatus = .available
                    logStore.log("JIT is fully functional (strategy 2)!", level: .success)
                case -2:
                    jitStatus = .unavailable
                    logStore.log("CS_DEBUGGED not set. Use StikDebug to enable JIT.", level: .error)
                case -3:
                    jitStatus = .unavailable
                    logStore.log("Fault loop — debugger-allocated pages also rejected", level: .error)
                default:
                    jitStatus = .unavailable
                    logStore.log("Strategy 2 failed with result: \(result)", level: .error)
                }
            }
        }
    }

    private func runFEXTest() {
        logStore.log("Starting FEX-Emu integration test...")
        jitStatus = .testing

        // Set up FEX log callback
        fex_set_log_callback { msg in
            if let msg = msg {
                let str = String(cString: msg)
                DispatchQueue.main.async {
                    LogStore.shared.log(str, level: .debug)
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = fex_test_execute()

            DispatchQueue.main.async {
                switch result {
                case 42:
                    jitStatus = .available
                    logStore.log("FEX-Emu test PASSED: x86-64 code returned 42!", level: .success)
                case -1:
                    jitStatus = .unavailable
                    logStore.log("FEX-Emu test FAILED (init/setup error)", level: .error)
                default:
                    jitStatus = .unavailable
                    logStore.log("FEX-Emu test returned \(result)", level: .error)
                }
            }
        }
    }

    private func enableJIT() {
        // Explains why JIT cannot be enabled on a copy signed without get-task-allow; 0 opens StikDebug regardless.
        // A debugger can attach only to a process whose signature carries
        // get-task-allow (a development signature). A copy signed with a
        // distribution or enterprise certificate lacks it, StikDebug can never
        // attach, and CS_DEBUGGED never appears however often this is tapped.
        if !SigningStatus.current.debuggable, MadeiraConfig.flag("MADEIRA_JIT_SIGNING_CHECK") {
            jitStatus = .unavailable
            logStore.log(String(format: "[jit-signing] get-task-allow is missing (cs-flags=0x%x): no debugger can attach to this copy, "
                                + "so JIT cannot be enabled. Reinstall Madeira with a development certificate.",
                                SigningStatus.current.flags), level: .error)
            if library.enabled { library.error = SigningStatus.notDebuggableMessage }
            launchAfterJITEnded(started: false)
            return
        }
        jitStatus = .testing
        logStore.log("Requesting JIT with \(jitCoordinator.resolvedMethod.title)...")

        jitCoordinator.enable { result in
            switch result {
            case .success:
                jitStatus = .available
                logStore.log("JIT enabled! Debugger attached.", level: .success)
                launchAfterJITEnded(started: true)
            case .failure(let failure):
                launchAfterJITEnded(started: false)
                if let coordinatorError = failure as? JITCoordinator.CoordinatorError,
                   case .setupRequired = coordinatorError {
                    jitStatus = .unknown
                    return
                }
                jitStatus = .unavailable
                logStore.log("Failed to enable JIT: \(failure.localizedDescription)", level: .error)
                if library.enabled { library.error = failure.localizedDescription }
            }
        }
    }

    /// Enable JIT finished: a Play that waited for it starts its game, only when the
    /// debugger is attached (so the start cannot ask for JIT again) and nothing else
    /// started meanwhile. A failure drops it: a later Enable JIT starts no game.
    private func launchAfterJITEnded(started: Bool) {
        guard let launch = launchAfterJIT else { return }
        launchAfterJIT = nil
        library.startingJIT = nil
        guard started, StikJITHelper.ready, library.current == nil, wine_process_is_running() == 0 else {
            logStore.log("[jit-on-play] JIT did not come on: the game was not started")
            // A failure has its own error; this one closes the details page as well.
            if started, library.current == nil { library.error = "JIT is on, but the game could not start. Tap Play again." }
            return
        }
        logStore.log("[jit-on-play] JIT is on: starting the game")
        launch()
    }

    /// Whether a launch may ask for the JIT pool. In the library, `then` makes Play
    /// enable JIT itself (the same flow as Enable JIT, LocalDevVPN and the Madeira JIT
    /// shortcut included) and start the game once the debugger is attached; that also
    /// covers CS_DEBUGGED set with no debugger attached (JIT enabled from StikDebug's
    /// own list, which attaches and leaves). Without `then`, the library offers
    /// Madeira's Enable JIT instead of starting a launch that cannot get its pool.
    private func jitReadyForLaunch(inLibrary: Bool, entry: UUID? = nil, then launch: (() -> Void)? = nil) -> Bool {
        if StikJITHelper.ready { return true }
        if inLibrary, let launch {
            logStore.log("[jit-on-play] JIT is not on: enabling it, then starting the game")
            launchAfterJIT = launch
            library.startingJIT = entry
            if jitStatus != .testing { enableJIT() }   // a second Play while it runs only replaces the game
            return false
        }
        if StikJITHelper.flaggedWithoutDebugger {
            logStore.log("[jit-debugger] launch held: CS_DEBUGGED is set but no debugger is attached; "
                         + "JIT has to be enabled again from Madeira", level: .error)
            if inLibrary { library.jitNotice = StikJITHelper.noDebuggerMessage }
        } else {
            logStore.log("JIT not enabled. Press 'Enable JIT' first.", level: .error)
            if inLibrary { library.error = "Enable JIT before playing." }
        }
        return false
    }

    /// Whether a Steam game may start as far as its Steam Cloud saves go. If a sync
    /// is running, the last check failed or never ran, or saves wait for a choice,
    /// an alert asks first; `retry` starts the game again from there. A check that
    /// is only old is repeated first, without asking.
    private func cloudClear(_ appID: Int, name: String, retry: @escaping () -> Void) -> Bool {
        guard library.enabled else { return true }
        if library.cloudBypass == appID { library.cloudBypass = nil; return true }
        guard let hold = SteamOwnedLibrary.shared.cloudHold(appID) else { return true }
        library.cloudRetry = retry
        if hold == .stale { cloudWait(appID); return false }
        LogStore.shared.log("[steam-cloud] app=\(appID) before-play: held \(hold)")
        library.cloudNotice = cloudNotice(appID, name: name, hold: hold)
        return false
    }

    private func cloudNotice(_ appID: Int, name: String, hold: SteamOwnedLibrary.CloudHold) -> LibraryModel.CloudNotice {
        switch hold {
        case .syncing, .stale:
            return .init(appID: appID, kind: .syncing, title: "Steam Cloud is still syncing",
                         message: "\(name)'s saves are still being checked or downloaded. Starting now may leave you on older saves.")
        case .unchecked(let why):
            return .init(appID: appID, kind: .unchecked, title: "Steam Cloud could not be checked",
                         message: "Madeira does not know whether \(name)'s saves on this device are the latest."
                            + (why.map { " (\($0))" } ?? "") + " If another device has newer saves, starting now means choosing between them later.")
        case .conflict(let count):
            return .init(appID: appID, kind: .conflict, title: "Saves differ from Steam Cloud",
                         message: "\(count) of \(name)'s save\(count == 1 ? "" : "s") differ\(count == 1 ? "s" : "") between this device and Steam Cloud. Choose which to keep on the game's page, or start with this device's saves.")
        }
    }

    /// Syncs the game's saves, then starts it; if the saves are still not settled, asks again.
    private func cloudWait(_ appID: Int) {
        guard SteamOwnedLibrary.shared.cloudWaitingFor == nil else { return }
        let name = MadeiraDock.games(drive: MadeiraDock.drive).first { $0.id == appID }?.name ?? "This game"
        Task { @MainActor in
            let hold = await SteamOwnedLibrary.shared.settleCloud(appID)
            if let hold {
                library.cloudNotice = cloudNotice(appID, name: name, hold: hold)
            } else {
                let retry = library.cloudRetry; library.cloudRetry = nil; retry?()
            }
        }
    }

    /// A Home Screen shortcut waiting for the library (a link opened at a cold start
    /// arrives before the library is up).
    private func launchPendingShortcut() {
        guard library.enabled, library.current == nil, let exe = ShortcutRouter.shared.pendingExe else { return }
        ShortcutRouter.shared.pendingExe = nil
        launchShortcut(exe)
    }

    /// A Home Screen shortcut starts a game that is in the library, by its Windows
    /// path. A link names any path, so one for a program not in the library starts
    /// nothing: add it to the library first.
    private func launchShortcut(_ exe: String) {
        let key = exe.lowercased()
        if let entry = library.entries.first(where: { $0.desktop != true && $0.windowsPath.lowercased() == key }) {
            launchLibraryEntry(entry); return
        }
        LogStore.shared.log("[shortcut] \(exe) is not in the library: not started", level: .error)
        library.error = "This shortcut's game is not in the library. Add it to the library, then use the shortcut again."
    }

    /// Play in the library (Library.swift): checks that a session can start,
    /// applies the entry's launch profile and runs the same full sequence as the
    /// developer interface's buttons.
    private func launchLibraryEntry(_ entry: LibraryEntry) {
        // A Steam game starts through Madeira Dock with its own launch profile (SteamGames.swift),
        // unless its Game details page chose "The game": then its own program starts below, like
        // any library game (SteamDirectStart).
        if let appID = entry.steamAppID, !entry.startsSteamGameDirectly {
            guard let game = MadeiraDock.games(drive: MadeiraDock.drive).first(where: { $0.id == appID }) else {
                library.error = "Steam no longer lists this game as installed. Refresh the library and try again."; return
            }
            LogStore.shared.log("[steam-games] play app=\(appID)")
            startDock(game, compactPool: MadeiraDockModel.shared.compactPool, profile: entry)
            return
        }
        if let appID = entry.steamAppID {
            guard cloudClear(appID, name: entry.title, retry: { launchLibraryEntry(entry) }) else { return }
            guard entry.steamProgram?.isEmpty == false else {
                library.error = "Choose the program to start in Game details › Steam › Program."; return
            }
            LogStore.shared.log("[steam-start] app=\(appID) direct source=\(entry.steamProgramSource ?? "-") " +
                                "args=\(entry.launchArguments.isEmpty ? 0 : 1) folder=\(entry.steamWorkingWindowsPath == nil ? "program" : "steam")")
        }
        guard wine_process_is_running() == 0, wineserver_is_running() == 0, library.current == nil else {
            library.error = "A session is already running."; return
        }
        // One Wine session per app run (see LibraryModel.sessionsThisRun).
        if LibraryModel.sessionsThisRun > 0, MadeiraConfig.flag("MADEIRA_ONE_SESSION_PER_RUN") {
            LogStore.shared.log("[session-once] launch held: \(LibraryModel.sessionsThisRun) session(s) already ran in this app run")
            library.restartNotice = LibraryModel.restartMessage; return
        }
        // The same precondition runWineFullSequence checks: the JIT pool is
        // taken at launch, through the debugger. Without it, Play enables JIT and
        // continues from here once it is on.
        guard jitReadyForLaunch(inLibrary: true, entry: entry.id, then: { startLibraryEntry(entry) }) else { return }
        startLibraryEntry(entry)
    }

    /// The rest of Play, with JIT on: checks the entry's launch profile and starts it.
    private func startLibraryEntry(_ entry: LibraryEntry) {
        do { if entry.desktop != true { _ = try LibraryModel.executable(entry.launchRelativePath) }; try entry.validate() }
        catch {
            library.error = error.localizedDescription
            logStore.log("[launch-preflight] profile validation failed: \(error.localizedDescription)", level: .error)
            return
        }
        // launchArguments carries the whole ml1163 command (explorer's /desktop=, the quoted
        // program, its arguments); validate() and the bridge's tokenizer take 4 KB.
        guard entry.launchWindowsPath.utf8.count < 1024, entry.launchArguments.utf8.count < 4096 else {
            library.error = "The executable path or launch arguments are too long."; return
        }
        entry.configureLaunch()
        // This run's log under the program's name too (Documents/logs). A Steam game started
        // through Madeira Dock above gets its own from ntdll, once Valve's client starts it.
        let program = entry.desktop == true ? "explorer.exe"
            : entry.launchWindowsPath.split(separator: "\\").last.map(String.init) ?? entry.launchWindowsPath
        LogStore.shared.startSessionLog(program: program)
        library.begin(entry)
        runWineFullSequence(profile: entry)
    }

    /// Full sequence: allocate JIT pool, start wineserver, start Wine.
    /// Debugger stays attached during PE loading so mprotect_exec can use BRK
    /// to prepare code pages. Detach happens after Wine finishes + recovery.
    /// `profile` is a library entry whose launch profile applies to this run.
    private func runWineFullSequence(profile: LibraryEntry? = nil) {
        guard jit_check_debugged() else {
            logStore.log("JIT not enabled. Press 'Enable JIT' first.", level: .error)
            if profile != nil { LibraryModel.shared.launchFailed() }
            return
        }
        // Steam downloads wait for the session, and the app's own Steam connection closes
        // before Valve's client signs in with the same account (SteamOwnedLibrary).
        SteamOwnedLibrary.shared.sessionChanged(active: true)
        /* ml1095: one config file. Written once from any legacy madeira-*.txt. */
        MadeiraConfig.migrateLegacy { self.logStore.log($0) }
        MadeiraConfig.deleteLegacyFiles { self.logStore.log($0) }   /* ml1096: the old files go once the cfg exists */
        /* ml2100: XInput (default) or the HID controller; before the wineserver starts. */
        GamepadInput.shared.beginPadSession()
        /* ml1990: player 1 exists before the game enumerates XInput. */
        GamepadInput.shared.reserveSessionSlot(touchControls: TouchControlsModel.shared.offersControllerInput)
        if MadeiraConfig.present {
            let cfg = MadeiraConfig.all().sorted { $0.key < $1.key }
            logStore.log("madeira.cfg: " + (cfg.isEmpty ? "(empty)" : cfg.map { "\($0.key)=\($0.value)" }.joined(separator: " ")))
        } else {
            logStore.log("madeira.cfg absent: legacy madeira-*.txt files apply")
        }

        logStore.log("Running full Wine sequence...")
        DeviceDiagnostics.logLaunch()

        // Start a main thread heartbeat to diagnose hang
        var heartbeatCount = 0
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            heartbeatCount += 1
            os_log("[HEARTBEAT] main thread alive #%d", heartbeatCount)
        }

        // Pause UI flushing — prevents ALL SwiftUI re-renders during Wine execution,
        // so zero main thread hang time accumulates while debugger is attached
        logStore.uiPaused = true

        // Suppress os_log from wineserver — hundreds of messages/sec cause os_log buffer
        // contention that blocks the main thread RunLoop, triggering iOS hang detection
        ws_log_quiet = 1

        DispatchQueue.global(qos: .userInitiated).async {
            // A library entry's launch profile (executable, arguments, x87
            // precision, frame limit).
            if let profile {
                profile.applyEnvironment()
                logStore.log("[launch-route] library profile applied")
            } else {
                _ = try? MadeiraConfig.applyGame(nil)   // no library game: no game's own lines
            }

            // Step 1: Allocate JIT pool (BRK suspends entire process)
            // 128 MB was enough for cube but Thumper exhausts it (more PE
            // copies + larger FEX block cache). Desktop mode holds the
            // session's aarch64 image set AND every child's x64 set AND the
            // FEX code buffers in ONE pool: Thumper-under-desktop hit 199MB
            // of image copies alone (2026-07-06), leaving the FEX tail carve
            // colliding with the head. 384 MB fits both plus slack; the pool
            // is dual-map + NO_FOOTPRINT so unwritten pages cost nothing.
            //
            // 2026-07-10 (Steam S3): 384 MB is VIRTUAL-exhausted by Steam's
            // pseudo-process fan-out — steam.exe + services + rpcss + cmd +
            // conhost + steamerrorreporter64 each copy their whole DLL set
            // (owner-keyed, no .text sharing yet) → 138 image copies hit
            // ~365 MB and the crash reporter's ntdll can't fit → the load
            // fails and execution BUS-faults on the un-committed image. Since
            // the pool is jetsam-exempt + demand-committed (unwritten pages
            // cost nothing), raising the VIRTUAL cap is a cheap, safe unblock.
            // 640 MB clears the current fan-out with headroom to reach the
            // ole32 delay-load (FEX riprel probe) and beyond. The real fix for
            // the PHYSICAL duplication is .text sharing (deferred project).
            //
            // 2026-07-10 pm (task #34 / CEF): 896 MB — libcef.dll's 212MB
            // pool copy EXHAUSTED 640 (bump 412MB + no contiguous 212MB →
            // libcef load degraded → init CHECK). Pure-x64 skip-copy was
            // trialed and reverted (broke x18-trampoline layout, ml68);
            // until skip-copy or .text sharing lands, buy headroom. Virtual
            // is jetsam-exempt; the copy itself is ~212MB real RSS when
            // written.
            // 2026-08-01 (ml364): 1152 MB — ml363 died at MSM depth on pool
            // EXHAUSTION (bump 858MB, freelist 0, tail-reserve 64MB) when
            // Chrome's in-proc GPU thread requested a doubled 32MB EC code
            // buffer; the fallback landed non-executable in the guest band and
            // FEX scribbled through a garbage CodeBuffer. NOTE the jetsam
            // ledger note above is STALE: the pool was never exempt and
            // arrives FULLY DIRTY from StikDebug's TXM blessing writes, so
            // this +256MB costs +256MB of the 4096MB budget up front. The
            // ml362/ml363 footprint work (peak 3804→3190) is what pays for
            // it. The real fix for both sides is still .text sharing.
            // 2026-08-01 (ml367): back to 896 MB. ml364 needed 1152 because the
            // shipped PE DLLs carried DWARF debug sections (llvm-mingw links
            // -Wl,-debug:dwarf) and the pool copies the ENTIRE image, so 42% of
            // every copy was debug info with no runtime purpose. Stripping them
            // (llvm-strip --strip-debug over the bundle) drops projected peak
            // pool use 894 -> ~653 MB, so 896 restores the ml364-equivalent
            // headroom (~243 MB) while returning 256 MB of footprint — the pool
            // is dirty from birth, so its SIZE is what costs, not its usage.
            // KEEP ios_usable_va_floor PAIRED: 896MB -> 0x7038000000.
            // 2026-08-02 (ml421): 1024 MB. ml420 (post-#69-fix, deepest run yet:
            // cycle 41) refilled the stripped 896 pool anyway — head 768MB of
            // copies + 176MB tail of EC code buffers collided; the doubled 32MB
            // GPU-thread buffer was refused and the ml361/ml363 ClearCache
            // wild-write returned (now also honestly REFUSED unix-side,
            // rev=ml421). +128MB is the depth lever that fits under jetsam:
            // ml420 peaked 3837 phys; 3837+128=3965 < 4096. Tight — if jetsam
            // returns, the durable fix is .text sharing, not more pool.
            // 2026-08-02 (ml423): BACK to 896. Jetsam DID return — ml422 died a
            // silent EXC_RESOURCE kill at 2.5min (peak 3904, log stops mid-line),
            // exactly the predicted cost of the +128MB dirty-at-birth pool.
            // ml421's honest EC_CODE refusal makes pool exhaustion GRACEFUL now
            // (ctor halving, worst case one thread's 0xdead fault) while jetsam
            // kills the whole app — 896 + graceful degradation strictly beats
            // 1024 + jetsam roulette. Durable fix remains .text sharing.
            // KEEP ios_usable_va_floor PAIRED: 896MB -> 0x7038000000.
            // 2026-08-03 (ml458): STAY at 896 — growth is closed for good.
            // jetsam killed 1024 twice (ml422 peak 3904) and the no-footprint
            // exemption is unreachable: all four (entry-flags, owner) variants
            // return kr=4, and the plain ones expose why — the named entry
            // covers 16KB of the 896MB object, i.e. the kernel wants an entry
            // naming the WHOLE object, which we can never build over memory
            // whose object StikDebug created. Pool stays dirty-from-birth and
            // jetsam-counted, so SIZE is the cost and 896 is the ceiling.
            // ⛔ ml457 re-trialed pure-x64 skip-copy (already dead per ml68
            // above) and it failed again for a different reason: x64 guest
            // RIPs ARE pool-copy aliases, so the copy is the execution
            // substrate — steam.exe died in seconds. Do not try a third time.
            // The remaining levers are USE-side: the 276MB of duplicate copies
            // (.text sharing) and the 214MB tail of EC code buffers.
            // ml668: RUNTIME-SELECTABLE. 896 stays the default and the only
            // value proven for Steam/CEF. 384 is the direct-game experiment:
            // the last good Book of the Dead run used ~139MB of head + ~48MB
            // of tail, so 384 leaves ~197MB of observed slack while returning
            // ~512MB of footprint -- and the pool is dirty from birth, so its
            // SIZE is the cost, not its usage. The VA floor is no longer a
            // hand-paired constant (ml668 derives it from the pool actually
            // allocated), so changing this is now a one-line change.
            // Override lives in Documents/madeira-pool.txt (a bare number of MB)
            // so it can be swapped between runs without a rebuild, and deleting
            // the file reverts to the proven default. Clamped to sane values --
            // a typo here would otherwise move the VA floor with it.
            // Madeira Dock: a Dock launch may opt in to a compact pool (only that
            // launch; off by default). madeira.cfg pool below still wins.
            let dockLaunch = MadeiraDock.takeLaunchRequest()
            // A Dock session publishes no fixed Steam game identity to its guests
            // (WineProcessBridge.m): Valve's client runs in the host and gives each
            // game its own. Every other launch clears the flag and is unchanged.
            // env.MADEIRA_DOCK_CLEAR_STEAM_ID = 0 keeps the fixed identity (A/B).
            if dockLaunch.dock && SteamSignIn.flag("MADEIRA_DOCK_CLEAR_STEAM_ID", default: true) {
                setenv("MADEIRA_DOCK_SESSION", "1", 1)
            } else {
                unsetenv("MADEIRA_DOCK_SESSION")
            }
            // A Dock session runs Valve's client headless, with no Chromium, so
            // nothing claims the 8 GB V8 cage holdback (virtual_ios.c). Let ntdll
            // hand it to the allocator when the guest band runs out. madeira.cfg
            // env.MADEIRA_CAGE_RELEASE, exported later, wins.
            if dockLaunch.dock {
                setenv("MADEIRA_CAGE_RELEASE", "1", 1)
            } else {
                unsetenv("MADEIRA_CAGE_RELEASE")
            }
            var poolSizeMB = DockPerformancePolicy.sessionPoolMB(standard: 896, dock: dockLaunch.dock, compact: dockLaunch.compact)
            if poolSizeMB != 896 { logStore.log("[dock-pool] compact JIT pool \(poolSizeMB)MB for this Dock launch") }
            // madeira.cfg pool: the JIT pool size in MB (256 to 1152) for every launch; wins over the size above.
            if let txt = MadeiraConfig.get("pool"),
               let mb = Int(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
               mb >= 256, mb <= 1152 {
                poolSizeMB = mb
                logStore.log("JIT pool overridden to \(mb)MB via madeira.cfg pool")
            }
            // ml694: W^X A/B switch. Documents/madeira-wx.txt containing "0"
            // disables page demotion for the SAME binary, so the on/off
            // comparison needs one rebuild, not two. The previous gate read
            // container paths that can never exist, so it silently forced
            // ENABLED and no A/B was actually possible.
            if let txt = MadeiraConfig.get("wx") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("MADEIRA_WX", v, 1)
                logStore.log("W^X override: MADEIRA_WX=\(v) via madeira.cfg wx")
            }

            // ml727: wine-mono backpatcher bridge A/B. Documents/madeira-mono-bridge.txt
            // == "1" sets MADEIRA_WINEMONO_BRIDGE, which arms FEX's Mono code-patching
            // optimisation for wine-mono (recognised since ml712 but activation left
            // opt-in because the bridge reclassifies an XCHG from a true atomic exchange
            // into an alias-directed plain write).
            //
            // Worth arming here: the dominant fault site emits SWPAL, which is exactly
            // what FEX generates for a guest XCHG, and the patching XCHGs sit inside
            // libmono -- so the bridge's "RIP must lie inside Mono" test should pass.
            if let txt = MadeiraConfig.get("mono-bridge") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_WINEMONO_BRIDGE", v, 1)
                    logStore.log("Mono bridge: MADEIRA_WINEMONO_BRIDGE=\(v) via madeira.cfg mono-bridge")
                }
            }

            // ml716: syscall-frame context A/B. Documents/madeira-ctx-frame.txt == "1"
            // makes ios_fill_thread_context() report a thread parked inside a syscall
            // using its saved Wine syscall frame (TEB+0x378) instead of the Mach-O
            // registers it happens to be executing. Off by default; native code reads
            // only the environment variable.
            if let txt = MadeiraConfig.get("ctx-frame") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_CTX_FRAME", v, 1)
                    logStore.log("Context source: MADEIRA_CTX_FRAME=\(v) via madeira.cfg ctx-frame")
                }
            }

            // ml744: DXMT options passthrough. Documents/madeira-dxmt.txt is copied
            // verbatim into DXMT_CONFIG, which the renderer's config parser reads as
            // inline "key=value" lines, so options can be tried without a rebuild.
            // d3d11.mipClampBC=N is the one that matters for memory: this GPU cannot
            // sample BC, so those textures are expanded to uncompressed and cost 2-8x
            // their shipped size.
            // DXMT splits DXMT_CONFIG on ";" only and a newline is not whitespace to
            // its line parser, so the options are joined with ";" (ml1095: "a=b;c=d"
            // on one line). A library game's own dxmt options come after madeira.cfg's.
            // ml1255: "#" pieces (comments) are dropped; DXMT skips them anyway, but
            // they would count against its length limit below.
            var dxmtOptions: [String] = []
            for (source, txt) in [("madeira.cfg dxmt", MadeiraConfig.get("dxmt")), ("the game's config", MadeiraConfig.gameValue("dxmt"))] {
                let parts = (txt ?? "").split(whereSeparator: { $0 == ";" || $0.isNewline })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
                if !parts.isEmpty {
                    dxmtOptions += parts
                    logStore.log("DXMT config: \(parts.joined(separator: ";")) via \(source) (\(parts.count) option\(parts.count == 1 ? "" : "s"))")
                }
            }
            // MetalFX spatial upscaling (metalfx-upscale; Game details › MetalFX
            // upscaling writes it to the game's own lines). The D3D12 runtime reads
            // the key itself; D3D11 games get DXMT's MetalFX swapchain at the same
            // factor (DXMT takes 1 to 2).
            if let txt = MadeiraConfig.gameValue("metalfx-upscale") ?? MadeiraConfig.get("metalfx-upscale"),
               let factor = Double(txt), factor >= 1.1 {
                setenv("DXMT_METALFX_SPATIAL_SWAPCHAIN", "1", 1)
                dxmtOptions.append("d3d11.metalSpatialUpscaleFactor=\(min(factor, 2))")
                logStore.log("MetalFX upscaling: \(txt)x via metalfx-upscale")
            } else {
                unsetenv("DXMT_METALFX_SPATIAL_SWAPCHAIN")
            }
            // A library entry's "Report an NVIDIA GPU" (LibraryEntry.applyEnvironment):
            // DXGI's device id is the GeForce RTX 3060 win32u registers as the
            // display adapter (sysparams_ios.c), so every API names one GPU.
            if profile?.reportNVIDIA == true {
                dxmtOptions.append("dxgi.customDeviceId=2544")
                logStore.log("DXMT config: dxgi.customDeviceId=2544 via Report an NVIDIA GPU")
            }
            // DXMT's memory census reports from the encode thread several times a second in a
            // 64-bit game (a third of a log, and its scans on the frame path). DXMT throttles
            // it to one report every 10 s by default only in its 32-bit build; turn that on for
            // every session unless madeira.cfg sets env.DXMT_CENSUS_THROTTLE itself.
            if MadeiraConfig.get("env.DXMT_CENSUS_THROTTLE") == nil && getenv("DXMT_CENSUS_THROTTLE") == nil {
                setenv("DXMT_CENSUS_THROTTLE", "1", 0)
            }
            // Unset otherwise, so a previous session's options in this app process do not apply.
            if !dxmtOptions.isEmpty { setenv("DXMT_CONFIG", dxmtOptions.joined(separator: ";"), 1) } else { unsetenv("DXMT_CONFIG") }
            // ml1255: DXMT reads the variable into a MAX_PATH buffer (util_env.cpp
            // getEnvVar); from a longer value it gets nothing, and every option is lost.
            let dxmtLength = dxmtOptions.joined(separator: ";").utf16.count
            if dxmtLength > 259 {
                logStore.log("DXMT config is \(dxmtLength) characters; DXMT reads at most 259 and drops ALL of it -- shorten the dxmt lines of madeira.cfg and the game's config", level: .error)
            }

            // D3D9 frontend for 32-bit programs. The i386 d3d9.dll is DXMT's thin
            // shim; unset (the default) or "emulated", it forwards every export to
            // d3d9-emulated.dll, DXMT's D3D9 frontend built for i386 and translated
            // by FEX like the program. "native" makes the shim bind its unix side
            // and run the frontend as native ARM64 code in libdxmt_combined.a.
            // Only the i386 shim reads MADEIRA_D3D9; 64-bit programs are unaffected.
            if let txt = MadeiraConfig.get("d3d9") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_D3D9", v, 1)
                    logStore.log("D3D9 frontend: MADEIRA_D3D9=\(v) via madeira.cfg d3d9")
                }
            }

            // ml734: Theorafile call tracer. Documents/madeira-tf-trace.txt == "1"
            // redirects libtheorafile's tf_* exports through wrappers in
            // tftrace-x64.dll that call the original and report the RETURN
            // value. The intro decodes and plays, the stream reaches a clean
            // end of file, the decoder stops reading -- and the game never
            // leaves VideoContext. File EOF is not decoder EOS, and a call
            // count cannot tell "tf_eos returns false forever" from "it returns
            // true and the managed side ignores it". Only the return value can.
            if let txt = MadeiraConfig.get("tf-trace") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_TF_TRACE", v, 1)
                    logStore.log("Theorafile tracer: MADEIRA_TF_TRACE=\(v) via madeira.cfg tf-trace")
                }
            }

            // ml731: Windows shared-data clock A/B. Documents/madeira-usd-time.txt == "1"
            // makes wineserver update KUSER_SHARED_DATA's SystemTime, InterruptTime
            // and TickCount again. Without it those stay frozen at their init values,
            // so GetTickCount/Environment.TickCount/DateTime.UtcNow never advance and
            // every time-gated transition in a managed game waits forever while the
            // renderer keeps drawing. Opt-in only because the old code claimed the
            // write faulted; this should become unconditional once proven.
            if let txt = MadeiraConfig.get("usd-time") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_USD_TIME", v, 1)
                    logStore.log("Shared-data clock: MADEIRA_USD_TIME=\(v) via madeira.cfg usd-time")
                }
            }

            // ml730: REAL thread suspension A/B. Documents/madeira-real-suspend.txt == "1"
            // makes a Wine suspend actually stop the Mach thread and keep it stopped
            // until the matching resume, instead of only snapshotting its registers
            // and bumping a counter while the target keeps running.
            //
            // Off by default and reversible on purpose: wineserver is a thread inside
            // this same Mach process and shares the allocator with the guest, so truly
            // freezing a thread that holds the malloc lock or FEX's CodeInvalidationMutex
            // can deadlock whoever suspended it. Windows apps tolerate preemptive suspend
            // because the suspender does not share their heap; here it does.
            if let txt = MadeiraConfig.get("real-suspend") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_REAL_SUSPEND", v, 1)
                    logStore.log("Thread suspension: MADEIRA_REAL_SUSPEND=\(v) via madeira.cfg real-suspend")
                }
            }

            // ml713: Mono suspend-policy A/B. Documents/madeira-mono-suspend.txt
            // containing "preemptive" (or "coop"/"hybrid") sets MONO_THREADS_SUSPEND
            // for wine-mono, so the comparison needs no rebuild.
            //
            // EXPERIMENT, NOT A FIX, and deliberately not a default. Marvel Cosmic
            // Invasion deadlocks with one thread owning a Mono critical section while
            // looping on mono_lls_find/usleep waiting for a thread-info record, and six
            // threads queued behind that section. Preemptive suspend would sidestep the
            // handshake -- but it needs SuspendThread + GetThreadContext to yield a
            // coherent x86-64 context for a guest thread stopped anywhere, including
            // mid-JIT-block, and that path has never been exercised under FEX. It may
            // trade a deadlock for a worse failure. If it does get in-game, that is NOT
            // evidence for any particular theory of the deadlock.
            if let txt = MadeiraConfig.get("mono-suspend") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MONO_THREADS_SUSPEND", v, 1)
                    logStore.log("Mono suspend policy: MONO_THREADS_SUSPEND=\(v) via madeira.cfg mono-suspend")
                }
            }

            winios_phase("pool-alloc-begin")
            logStore.log("Allocating \(poolSizeMB)MB JIT pool (BRK will suspend process)...")
            let t0 = CFAbsoluteTimeGetCurrent()
            let pool = StikJITHelper.allocatePool(poolSize: poolSizeMB * 1024 * 1024)
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            winios_phase("pool-ready")
            logStore.log("BRK suspension lasted \(String(format: "%.2f", elapsed))s")

            // Arena carver self-test. Documents/madeira-arena-test.txt holds
            // "churn:N", "ramp:N" or "random:N". Deliberately a SEPARATE file
            // from madeira-arena.txt: a test that only runs when the feature is
            // enabled cannot be used to decide whether to enable it.
            if let txt = MadeiraConfig.get("arena-test") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_ARENA_TEST", v, 1)
                    logStore.log("arena carver self-test: \(v)", level: .success)
                }
            }

            // ml787: deterministic call-ret allocation failure injection.
            // Documents/madeira-fexfail.txt holds "reserve:N" or "commit:N".
            // The containment path it exercises only occurs naturally when a
            // title exhausts the emulator's address band, and only the reserve
            // half occurs at all -- an untested cleanup path is an assumption,
            // so this makes both reproducible on demand. Absent the file
            // nothing is injected.
            if let txt = MadeiraConfig.get("fexfail") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_FEX_FAIL_CALLRET", v, 1)
                    logStore.log("call-ret failure injection: \(v) via madeira.cfg fexfail", level: .error)
                }
            }

            // ml762: remote Metal backend. Documents/madeira-remote.txt holds
            // "<host-ip> <token>" and routes winemetal to a Metal daemon on that
            // host instead of the local device. The mode is decided ONCE per
            // process: flipping it later would leave handles from two address
            // spaces alive at the same time, which is precisely what the handle
            // tag exists to make impossible.
            if let txt = MadeiraConfig.get("remote") {
                let parts = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                                .split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    setenv("DXMT_REMOTE_METAL", parts[0], 1)
                    setenv("RMETAL_TOKEN", parts[1], 1)
                    logStore.log("remote Metal: host=\(parts[0]) via madeira.cfg remote", level: .success)
                } else if !parts.isEmpty {
                    logStore.log("madeira.cfg remote needs '<host-ip> <token>'", level: .error)
                }
            }

            // madeira-d3d12: M1 shader-converter gate, in-app.
            // Documents/madeira-d3d12.txt == "1" runs the same canary that
            // passes standalone on macOS and over SSH on this device, but from
            // inside Madeira -- which is the only way to test bundling, signing
            // and dlopen under the app's own sandbox. Results go to the log.
            // Reports its decision either way. A gate that stays silent when it
            // declines to run is indistinguishable from one that never executed,
            // which cost a device run to work out.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let raw = MadeiraConfig.get("d3d12")   /* ml1095 */
                let val = raw ?? ""
                if val == "1" {
                    let dir = Bundle.main.bundlePath + "/d3d12"
                    let dylib = dir + "/libmetalirconverter.dylib"
                    let haveDylib = FileManager.default.fileExists(atPath: dylib)
                    let transcript = d.appendingPathComponent("madeira-d3d12-canary.log").path
                    logStore.log("madeira-d3d12: running the M1 canary in-app (dylib present: \(haveDylib))", level: .info)
                    let fails = madeira_d3d12_canary_run_log(
                        dir, dylib, nil, transcript,
                        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?")
                    if fails == 0 {
                        logStore.log("madeira-d3d12: M1 canary PASSED in-app (transcript: madeira-d3d12-canary.log)", level: .success)
                    } else {
                        logStore.log("madeira-d3d12: M1 canary FAILED (\(fails) checks)", level: .error)
                    }
                } else {
                    logStore.log("madeira-d3d12: gate off (madeira.cfg d3d12 \(raw == nil ? "unset" : "= '\(val)'"))", level: .debug)
                }
            }

            // ml821: coalesced remote messages. Documents/madeira-remote-batch.txt
            // == "1" makes the pre-submission flush send many buffer ranges per
            // round trip and drains autorelease pools in one call. It is OPT-IN
            // because the measurement it is meant to improve needs a matched
            // baseline: with the file absent the process behaves exactly as
            // ml820 did. Round-trip COUNT is the cost being attacked -- one
            // gameplay frame spent 369 ms of 524 ms on 2,197 serialized calls.
            if let txt = MadeiraConfig.get("remote-batch"),
               txt.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                setenv("DXMT_REMOTE_BATCH", "1", 1)
                logStore.log("remote Metal: message coalescing ON via madeira.cfg remote-batch", level: .success)
            }

            // ml761: top-level API census. Documents/madeira-apicensus.txt == "1"
            // counts every call across the PE->unix winemetal boundary and
            // classifies each as producer, consumer, lifetime, query, sync,
            // presentation or bulk-memory. Needed because a packed command
            // batch carries GUEST handles -- raw pointer casts, meaningless on
            // another machine -- so every handle producer and consumer has to
            // be redirected together.
            if let txt = MadeiraConfig.get("apicensus") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_API_CENSUS", v, 1)
                logStore.log("API census: DXMT_API_CENSUS=\(v) via madeira.cfg apicensus")
            }

            // ml760: shadow-pack mode. Documents/madeira-shadow.txt == "1" packs
            // and validates every real render batch into the remote wire format,
            // then discards it and renders locally as normal. Exercises the
            // packer against live traffic where being wrong costs nothing. The
            // check that matters is packed counts equalling census counts: a
            // silently skipped command would otherwise surface as a subtly wrong
            // frame on another machine.
            if let txt = MadeiraConfig.get("shadow") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_SHADOW_PACK", v, 1)
                logStore.log("shadow pack: DXMT_SHADOW_PACK=\(v) via madeira.cfg shadow")
            }

            // ml758: wmtcmd census. Documents/madeira-census.txt == "1" counts
            // which of the 59 render/compute/blit command types a workload
            // actually emits, and how large their sidecar data gets. Needed
            // before serialising wmtcmd_* for the remote Metal transport --
            // building a schema for all 59 on speculation would be weeks of
            // work for commands no title may ever issue.
            if let txt = MadeiraConfig.get("census") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_CMD_CENSUS", v, 1)
                logStore.log("wmtcmd census: DXMT_CMD_CENSUS=\(v) via madeira.cfg census")
            }

            // ml757: FEX arena placeholder. Documents/madeira-arena.txt == "1"
            // makes Wine reserve FEX's host arena before any PE loads. OFF by
            // default: FEX still selects its own band, and on hardware that
            // band IS the reservation, so enabling it starves FEX and kills
            // x64 before the first window. Proven correct on the research VM
            // (8GB held, 0 of 123 guest images inside it) -- turn on only once
            // FEX consumes WINE_IOS_FEX_ARENA_BASE/SIZE instead of choosing.
            if let txt = MadeiraConfig.get("arena") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("MADEIRA_FEX_ARENA", v, 1)
                logStore.log("FEX arena placeholder: MADEIRA_FEX_ARENA=\(v) via madeira.cfg arena")
            }

            // ml748: W^X A/B probe. Documents/madeira-wxprobe.txt == "1" runs it.
            // Loading xtajit64.dll faults writing its .rdata on the jailbroken
            // research VM and not on this phone, with CS_DEBUGGED live in both,
            // so attachment is not the variable. Either the VM is stricter than
            // real hardware (its patchVmMapProtect() was removed, and that is
            // what forces W to stick on file-backed pages), or hardware masks a
            // genuine bug and the loader must stop holding RWX over image pages.
            // Reasoning cannot separate those; the SAME build reporting on both
            // machines can. Runs here because it needs the real container, the
            // real sandbox and a live cs_wx_enabled map -- a standalone binary
            // over SSH already answered this wrongly once.
            if let txt = MadeiraConfig.get("wxprobe"),
               txt.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                logStore.log("W^X probe armed via madeira.cfg wxprobe", level: .success)
                jit_wx_probe()
            }

            if let pool = pool {
                logStore.log("JIT pool: RX=\(String(format: "%p", Int(bitPattern: pool.rx))), RW=\(String(format: "%p", Int(bitPattern: pool.rw))), size=\(pool.size / 1024 / 1024)MB", level: .success)
                setenv("WINE_IOS_JIT_RX", String(format: "%lx", Int(bitPattern: pool.rx)), 1)
                setenv("WINE_IOS_JIT_RW", String(format: "%lx", Int(bitPattern: pool.rw)), 1)
                setenv("WINE_IOS_JIT_SIZE", String(format: "%lx", pool.size), 1)
            } else {
                // ml596: ABORT. "Continuing without it" produced ml595 — a run that
                // looked like an ARM64EC/optimizer regression but was only Wine
                // executing with no JIT pool, and it cost a diagnostic cycle plus a
                // wrong conclusion I wrote into the source. A run without the pool can
                // only manufacture misleading secondary crashes, so refuse to start one.
                logStore.log("JIT pool allocation FAILED — not starting Wine.", level: .error)
                // The reason allocatePool recorded (no debugger, placement, alias);
                // the lines above this one in the log carry the detail.
                let reason = StikJITHelper.poolFailure
                logStore.log("  " + (reason ?? "No reason was recorded; see the pool lines above."), level: .info)
                logStore.uiPaused = false
                // A library session that never started returns to the library.
                let offerJIT = reason == StikJITHelper.noDebuggerMessage
                DispatchQueue.main.async { LibraryModel.shared.launchFailed(reason, offerJIT: offerJIT) }
                return
            }

            // Step 1b (ml524, #67): DETACH THE DEBUGGER NOW, while the VM map is small.
            //
            // Every ~54s whole-app stall coincides with StikDebug DEPARTING — clean
            // exit(0) and jetsam-kill alike (12:07:43 exit(0) -> GAP 54.0s at 12:07:49;
            // 12:13:58 cpulimit kill -> GAP 53.8s starting 64ms BEFORE the kill log).
            // Departure is the trigger; the manner of death is irrelevant. StikDebug
            // burns its 48s-CPU-per-60s budget in ~52s every single run, so an
            // UNCONTROLLED departure mid-game is guaranteed. Detaching here pays the
            // cost ONCE, at a moment we choose, before anything is on screen.
            //
            // Why it may also be CHEAPER here: on attach the kernel unnests the DYLD
            // shared region in OUR map ("increases system memory footprint until the
            // target exits"), so teardown plausibly scales with VM-map complexity —
            // and right now the map is a fraction of what it becomes under Steam
            // (91 threads / 2512MB). The [early-detach] timing below tests exactly that.
            //
            // Safe NOW and not before: ml522/ml523 made US the task-level Mach handler
            // for bad-access + bad-instruction + breakpoint, so the fault backstop that
            // used to require a live debugger (madeira-jit.js: "NEVER detach here ... every
            // later escalated fault parks its thread forever", the ml345 wedge) is ours.
            // And all executable memory already comes from the pool granted above —
            // virtual_ios.c copies every PE .text into it rather than mprotecting,
            // because iOS/TXM blocks mprotect(PROT_EXEC) outright.
            //
            // ORDERING MATTERS: our task-port claim installs at wine's first thread
            // setup, which is AFTER this point, so this BRK still reaches StikDebug.
            // Flip to false to A/B against the old attached-for-the-whole-run behaviour.
            let earlyDetach = true
            if earlyDetach, pool != nil {
                let dt0 = CFAbsoluteTimeGetCurrent()
                StikJITHelper.detachDebugger()
                let dms = (CFAbsoluteTimeGetCurrent() - dt0) * 1000.0
                logStore.log(String(format: "[early-detach] rev=ml524 took %.0f ms", dms),
                             level: dms > 5000 ? .error : .success)
            } else if !earlyDetach {
                logStore.log("[early-detach] rev=ml524 DISABLED — debugger stays attached all run")
            }

            winios_phase("detach-done")

            // The Madeira JIT shortcut turned Cellular Data off or connected LocalDevVPN
            // for this JIT (JITNetwork.swift). The pool is mapped and the debugger is
            // gone, so put them back now: running the shortcut leaves Madeira for a
            // moment, which is safe only before Wine starts drawing.
            JITNetworkShortcut.restoreBlocking()

            // Step 2: Start wineserver
            self.startWineserver()
            winios_phase("wineserver-up")

            // Step 3: Start Wine.

            // Wine starts as soon as the wineserver has finished starting up (its registry
            // is loaded), normally within tens of milliseconds, instead of after a fixed
            // 2 s pause. 0 restores the fixed pause.
            if MadeiraConfig.flag("MADEIRA_FAST_SERVER_START") {
                let waitStart = CFAbsoluteTimeGetCurrent()
                while wineserver_is_ready() == 0, wineserver_is_running() != 0, CFAbsoluteTimeGetCurrent() - waitStart < 2.0 {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                logStore.log(String(format: "[launch] wineserver ready after %.0f ms", (CFAbsoluteTimeGetCurrent() - waitStart) * 1000))
            } else {
                Thread.sleep(forTimeInterval: 2.0)
            }
            winios_phase("wine-start")
            self.startWineProcess()

            // Step 4: Wait for Wine to finish instead of fixed timer
            // Poll wine_process_is_running() — it clears when __wine_main returns
            // For real games this never returns (message loop runs forever), so
            // the cap is what matters. After detach, the dual-mapped JIT pool
            // keeps existing blocks executable; only NEW BRK-based compiles
            // fail.
            //
            // 2026-05-13 first-frame: Thumper splash renders at ~50s but JIT is
            // STILL compiling new FMOD blocks 3M log lines later — audio init
            // is huge (~14k unique RIPs in fmod64.dll alone). Bumped to 300s
            // to let FMOD finish init before debugger detach; otherwise main
            // game loop never engages because Present is gated on audio ready.
            logStore.log("Waiting for Wine to finish PE loading...")
            // 2026-07-03 early detach: attached-mode runs the whole guest
            // ~2x slower (measured 1.2s → 0.74s per present at detach) and
            // on iOS 27 presented frames only reliably reach glass after
            // detach. Post-detach is safe now: trap-mode JIT writes go via
            // the Mach emulator (no debugger), pool pages are pre-executable
            // (dual map), page0 runs once on the first thread, and a
            // post-detach compile was observed working (real_compiles
            // 7093→7094, no faults). So: detach once the game is actually
            // presenting (present #2 = first post-splash frame) plus a
            // settle window, instead of waiting out the full 1200s cap.
            let maxWait = 1200.0  // hard safety cap (unchanged)
            // 2026-07-03 second iteration: detach on present #1 (splash shown)
            // instead of #2. The 3-minute splash-hold is the game loading —
            // running it detached should roughly halve it. Riskier than #2
            // (thousands of load-time compiles + worker-thread spawns happen
            // post-detach) but all known dependencies are covered: trap-mode
            // writes, pre-executable pool, page0 once-guard.
            let settleAfterFirstPresent = 20.0
            var presentingSince: CFAbsoluteTime? = nil
            let pollStart = CFAbsoluteTimeGetCurrent()
            var lastHeartbeat = CFAbsoluteTimeGetCurrent()
            while wine_process_is_running() != 0 {
                Thread.sleep(forTimeInterval: 0.25)
                let now = CFAbsoluteTimeGetCurrent()
                // Diagnostic heartbeat: 2026-07-03's detach-at-#1 run never
                // triggered despite presents visibly counting — log what this
                // loop actually observes so that can't happen silently again.
                if now - lastHeartbeat > 30 {
                    lastHeartbeat = now
                    logStore.log("detach-wait: presents=\(madeira_get_present_count()) running=\(wine_process_is_running()) elapsed=\(Int(now - pollStart))s")
                }
                // Task #25: the present heuristic is meaningless in desktop
                // mode — ANY child presenting (cube, a game window) trips it
                // mid-session, and later program launches still need the
                // attached-debugger facilities. Desktop sessions stay
                // attached until the desktop exits (or the safety cap).
                let isDesktopSession = getenv("MADEIRA_DESKTOP").map { $0.pointee == 49 } ?? false
                if !isDesktopSession {
                    if presentingSince == nil && madeira_get_present_count() >= 1 {
                        presentingSince = now
                        logStore.log("Game is presenting (#1, splash) — early detach in \(Int(settleAfterFirstPresent))s")
                    }
                    if let t = presentingSince, now - t > settleAfterFirstPresent {
                        logStore.log("Early detach: game presenting and settled", level: .success)
                        break
                    }
                }
                if now - pollStart > maxWait {
                    logStore.log("Wine still running after \(Int(maxWait))s, proceeding with detach", level: .error)
                    break
                }
            }
            let wineElapsed = CFAbsoluteTimeGetCurrent() - pollStart
            logStore.log("Wine finished after \(String(format: "%.1f", wineElapsed))s")

            // Step 5: Resume UI + os_log, give main thread time to recover before detach
            DispatchQueue.main.async {
                ws_log_quiet = 0
                logStore.uiPaused = false
            }
            Thread.sleep(forTimeInterval: 2.0)

            // Step 6: Detach debugger — main thread should have zero accumulated hang time
            logStore.log("Detaching debugger...")
            StikJITHelper.detachDebugger()

            DispatchQueue.main.async {
                heartbeat.invalidate()
                if wine_process_is_running() == 0 { LibraryModel.shared.launchFailed() }
            }
        }
    }

    /// Madeira Dock: hand the stored sign-in to the host once, point it at the game and
    /// start the normal session with explorer's virtual desktop running dockhost.exe.
    /// Nothing is handed over unless JIT is ready and no session runs.
    /// From the library (Settings › Steam › Madeira Dock) the start is a library
    /// session: the library's one-session-per-run rule applies first, failures
    /// show in the library, and the session gets the full-screen game view.
    /// `profile` is a Steam game's library entry (its Game details page): the
    /// session then takes that entry's display, performance and on-screen settings.
    private func startDock(_ game: DockGame, compactPool: Bool, profile: LibraryEntry? = nil) {
        let inLibrary = library.enabled
        guard jitReadyForLaunch(inLibrary: inLibrary, entry: profile?.id,
                                then: { startDock(game, compactPool: compactPool, profile: profile) }) else { return }
        guard cloudClear(game.id, name: game.name, retry: { startDock(game, compactPool: compactPool, profile: profile) }) else { return }
        guard wine_process_is_running() == 0, wineserver_is_running() == 0, !inLibrary || library.current == nil else {
            logStore.log("[madeira-dock] a session already ran in this app run; restart Madeira first", level: .error)
            if inLibrary { library.error = "A session is already running." }
            return
        }
        if inLibrary, LibraryModel.sessionsThisRun > 0, MadeiraConfig.flag("MADEIRA_ONE_SESSION_PER_RUN") {
            LogStore.shared.log("[session-once] Dock launch held: \(LibraryModel.sessionsThisRun) session(s) already ran in this app run")
            library.restartNotice = LibraryModel.restartMessage
            return
        }
        func fail(_ error: Error) {
            MadeiraDock.cleanup()
            SteamOwnedLibrary.shared.dockEnded()
            MadeiraDockModel.shared.status = error.localizedDescription
            logStore.log("[madeira-dock] not started: \(error.localizedDescription)", level: .error)
            if inLibrary { library.error = error.localizedDescription }
        }
        do {
            try MadeiraDock.validate(game, drive: MadeiraDock.drive)
            try profile?.validate()
            guard SteamSignIn.isSignedIn else { throw DockError.message("Sign in to Steam in Madeira before starting Dock.") }
        } catch { fail(error); return }
        // Only one sign-in of the account may be online: the app's own Steam connection
        // (library, playtime, downloads) logs off and its socket closes before the sign-in
        // is handed to Valve's client, and it stays off until the Dock session has ended
        // (SteamOwnedLibrary.prepareDock / dockEnded, SteamConnectionGate).
        Task { @MainActor in
            // Resolve the original config.launch key before closing the native connection.
            // A filtered launch array can start at 1 (or have gaps); its offset is not the key.
            // Without a choice (no configuration to be had, or no entry whose .exe is on disk:
            // a launcher started through a .bat, say) it is key 0, which every Dock start
            // used before; Dock stops at once if Steam names that entry missing.
            let options = await SteamOwnedLibrary.shared.launchOptions(appID: game.id)
            let installFolder = MadeiraDock.drive.appendingPathComponent(game.library + "/common/" + game.installDir)
            let chosen = options.flatMap { SteamDirectStart.choose($0, installFolder: installFolder)?.launchIndex }
            let launchOption = chosen ?? 0
            LogStore.shared.log("[madeira-dock] launch option \(launchOption)\(chosen == nil ? " (none chosen: the default)" : "")")
            await SteamOwnedLibrary.shared.prepareDock()
            do {
                // The launch state may have changed while the connection closed.
                guard StikJITHelper.ready, wine_process_is_running() == 0, wineserver_is_running() == 0,
                      !inLibrary || library.current == nil else {
                    throw DockError.message("The launch state changed. Enable JIT and try again.")
                }
                guard let signIn = SteamSignIn.credentialsForDock() else {
                    throw DockError.message("Sign in to Steam in Madeira before starting Dock.")
                }
                try MadeiraDock.writeHandoff(account: signIn.accountName, token: signIn.refreshToken, appID: game.id)
            } catch { fail(error); return }
            MadeiraDock.configure(game, launchOption: launchOption)
            // The game's one-time installs (its Steam install script) run first, in the same
            // session. No session runs yet, so the registry files can be read and written.
            DockInstallers.prepare(game, drive: MadeiraDock.drive, prefix: MadeiraDock.prefix)
            // Only a start that runs installers turns madsync off, for its own session
            // (build/madsync/madsync.c reads MADEIRA_MADSYNC_SESSION once, when the server starts).
            if DockInstallers.serverSync {
                setenv("MADEIRA_MADSYNC_SESSION", "0", 1)
                logStore.log("[dock-installers] this session runs one-time installs: madsync off for this session only (MADEIRA_MADSYNC_SESSION=0)")
            } else {
                unsetenv("MADEIRA_MADSYNC_SESSION")
            }
            // A Dock session starts 64-bit (explorer, then the host), but the programs it starts
            // later are often 32-bit: one-time installers and the 32-bit games Valve's client
            // launches. win32u decides once, when the session's first program initialises it,
            // whether the GDI handle table is a section that every 32-bit program can map inside
            // its own guest window (wine dlls/win32u/gdiobj.c, gdi_shared_use_section). Left to
            // that default, a Dock session's table is private host memory, and 32-bit gdi32
            // truncates its address and faults on its first GDI handle. The regular launch path
            // is unchanged; env.MADEIRA_GDI_SHARED_SECTION = 0 in madeira.cfg, exported after
            // this, keeps the default for Dock sessions too.
            setenv("MADEIRA_GDI_SHARED_SECTION", "1", 1)
            // ml1185: without desktop-size or a game's Resolution, this screen's shape
            // (ml1172's default: 1408x648 on a 19.5:9 iPhone, 1152x800 on an 11-inch
            // iPad), as every library entry defaults to; a fixed 1280x720 left bars
            // above and below on an iPad.
            var (width, height) = ResolutionChoices.defaultSize()
            if let txt = MadeiraConfig.get("desktop-size") {
                let p = txt.lowercased().split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if p.count == 2, p[0] >= 640, p[1] >= 360, p[0] <= 3840, p[1] <= 2160 { width = p[0]; height = p[1] }
            }
            // A Steam game's own Resolution (validated above) sizes its Dock desktop.
            if let size = profile?.resolution.split(separator: "x").compactMap({ Int($0) }), size.count == 2 {
                width = size[0]; height = size[1]
            }
            setenv("MADEIRA_EXE", "explorer.exe", 1)
            setenv("MADEIRA_ARGS", MadeiraDock.launchArguments(width: width, height: height, installers: DockInstallers.script), 1)
            setenv("MADEIRA_DESKTOP", "1", 1)
            setenv("MADEIRA_SCREEN_W", String(width), 1)
            setenv("MADEIRA_SCREEN_H", String(height), 1)
            // The compositor and touch mapping read the published size
            // (winios_screen_size), which a program's display-mode change moves;
            // start this session from its own desktop size, not a previous one.
            winios_display_mode_changed(Int32(width), Int32(height))
            MadeiraDock.requestLaunch(compactPool: compactPool)
            logStore.log("[madeira-dock] starting the host for app \(game.id); Valve's client authenticates and authorizes the launch")
            MadeiraDockModel.shared.watchReport()
            if inLibrary {
                if let profile { library.begin(profile, dock: game) }
                else { library.begin(.dockSession(title: game.name, width: width, height: height), remember: false, dock: game) }
            }
            runWineFullSequence(profile: profile)
        }
    }

    /// ml589: locate an installed Steam inside the prefix and (re)generate
    /// C:\steam-launch.bat to match. Returns false, having logged the reason,
    /// when there is nothing runnable.
    ///
    /// Generating the batch here fixes a gap that only showed on FRESH prefixes:
    /// steam-launch.bat was never part of prefix-template.tar.gz, it had only
    /// ever been hand-pushed to the dev device, so a new install ran
    /// `cmd /c C:\steam-launch.bat` against a file that did not exist.
    ///
    /// The generated batch launches steam.exe DIRECTLY rather than through
    /// start.exe. That wrapper's teardown is what killed services.exe's RPC
    /// listener in every broken run (ml579/580/584/585) and took the Start menu
    /// with it; launching directly also keeps cmd+conhost alive for the session.
    private func prepareSteamLaunch() -> Bool {
        let fm = FileManager.default
        let prefix = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("wine").path

        // (windows dir, unix dir) — Steam installs to Program Files (x86) by
        // default, but honour a 64-bit-tree install too.
        let candidates = [
            ("C:\\Program Files (x86)\\Steam", "\(prefix)/drive_c/Program Files (x86)/Steam"),
            ("C:\\Program Files\\Steam",       "\(prefix)/drive_c/Program Files/Steam"),
        ]

        guard let (winDir, _) = candidates.first(where: {
            fm.fileExists(atPath: "\($0.1)/steam.exe")
        }) else {
            logStore.log("Steam is not installed in this prefix.", level: .error)
            logStore.log("  Searched: Program Files (x86)\\Steam and Program Files\\Steam", level: .info)
            logStore.log("  Valve's SteamSetup.exe cannot be used to install it here: the", level: .info)
            logStore.log("  installer AND the Steam.exe it lays down are 32-bit x86, and this", level: .info)
            logStore.log("  build runs x86-64 only (ARM64EC + FEX, no 32-bit emulator).", level: .info)
            logStore.log("  Copy an existing 64-bit Steam folder into the prefix instead.", level: .info)
            return false
        }

        let bat = """
        @echo off\r
        rem Generated by Madeira (ml589) — do not hand-edit; rewritten every launch.\r
        start "" "C:\\windows\\system32\\services.exe"\r
        cd /d "\(winDir)"\r
        "\(winDir)\\steam.exe" -no-cef-sandbox -cef-disable-gpu -console -nocrashmonitor -cef-disable-features=SegmentationPlatform,OptimizationTargetPrediction,OptimizationHints\r
        """

        let batPath = "\(prefix)/drive_c/steam-launch.bat"
        do {
            try bat.write(toFile: batPath, atomically: true, encoding: .utf8)
        } catch {
            logStore.log("Could not write steam-launch.bat: \(error.localizedDescription)", level: .error)
            return false
        }
        logStore.log("Steam found at \(winDir)", level: .success)
        return true
    }

    /// ml1127: `desktop-size = WxH` from madeira.cfg, or `def` when absent or out of range.
    /// ml1157: the desktop resolution menu. Saves `desktop-size` to madeira.cfg;
    /// Wine reads it once per app launch, so while it runs the choice waits for
    /// the next launch (the label says so).
    /// ml1172: the choices are the library's (ResolutionChoices), grouped.
    private var resolutionPicker: some View {
        let _ = desktopSizeTick   // re-read the file after a pick
        let (cw, ch) = configuredDesktopSize(default: ResolutionChoices.defaultSize())
        let groups = ResolutionChoices.groups()
        let custom = ResolutionChoices.extra("\(cw)x\(ch)", in: groups, note: "madeira.cfg")
        let pending = wine_process_is_running() != 0
        let pick = { (p: ResolutionChoices.Choice) in
            Button {
                MadeiraConfig.set("desktop-size", p.value)
                desktopSizeTick += 1
            } label: {
                if p.w == cw && p.h == ch { Label(p.label, systemImage: "checkmark") } else { Text(p.label) }
            }
        }
        return Menu {
            ForEach(groups, id: \.title) { group in
                Section(group.title) { ForEach(group.choices, id: \.value) { pick($0) } }
            }
            if let custom { pick(custom) }
        } label: {
            Label("\(cw)×\(ch)" + (pending ? " · next launch" : ""), systemImage: "rectangle.dashed")
        }
        .buttonStyle(.bordered)
    }

    private func configuredDesktopSize(default def: (Int, Int)) -> (Int, Int) {
        if let txt = MadeiraConfig.get("desktop-size") {
            let p = txt.lowercased().split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if p.count == 2, p[0] >= 640, p[1] >= 360, p[0] <= 3840, p[1] <= 2160 { return (p[0], p[1]) }
        }
        return def
    }

    private func startWineserver() {
        logStore.log("Starting wineserver...")

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let winePrefixPath = documentsPath.appendingPathComponent("wine").path

        logStore.log("Wine prefix: \(winePrefixPath)")

        let result = wineserver_start(winePrefixPath)
        if result == 0 {
            logStore.log("Wineserver thread launched successfully", level: .success)
        } else {
            logStore.log("Failed to start wineserver (error: \(result))", level: .error)
        }
    }

    private func startWineProcess() {
        logStore.log("Starting Wine process...")

        if wineserver_is_running() == 0 {
            logStore.log("Wineserver not running! Start it first.", level: .error)
            return
        }

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let winePrefixPath = documentsPath.appendingPathComponent("wine").path

        // Call synchronously — caller already waited for wineserver to be ready
        let result = wine_process_start(winePrefixPath)
        if result == 0 {
            logStore.log("Wine process thread launched", level: .success)
        } else {
            logStore.log("Failed to start Wine process (error: \(result))", level: .error)
        }
    }

    private func testDualMapping() {
        logStore.log("Testing dual-mapped memory properties...")

        DispatchQueue.global(qos: .userInitiated).async {
            testDualMappingImpl()
        }
    }

    private func testDualMappingImpl() {
        logStore.log("Creating 64KB dual-mapped region...")

        guard let region = jit_region_create(65536) else {
            logStore.log("Failed to create dual-mapped region", level: .error)
            return
        }

        let rwPtr = jit_region_rw_ptr(region)
        let rxPtr = jit_region_rx_ptr(region)
        let size = jit_region_size(region)

        logStore.log("Region created: size=\(size)")
        logStore.log("  RW ptr: \(String(format: "%p", Int(bitPattern: rwPtr)))")
        logStore.log("  RX ptr: \(String(format: "%p", Int(bitPattern: rxPtr)))")

        // Test 1: Write to RW, verify readable from RX
        let testPattern: UInt32 = 0xDEADBEEF
        rwPtr?.assumingMemoryBound(to: UInt32.self).pointee = testPattern
        let readBack = rxPtr?.assumingMemoryBound(to: UInt32.self).pointee

        if readBack == testPattern {
            logStore.log("Dual mapping verified: write to RW visible from RX", level: .success)
        } else {
            logStore.log("Dual mapping FAILED: wrote \(String(format: "0x%X", testPattern)), read \(String(format: "0x%X", readBack ?? 0))", level: .error)
        }

        // Test 2: Verify RW and RX are at different virtual addresses
        if rwPtr != rxPtr {
            logStore.log("Distinct virtual addresses confirmed (RW != RX)", level: .success)
        } else {
            logStore.log("WARNING: RW and RX are at the same address", level: .error)
        }

        jit_region_destroy(region)
        logStore.log("Region destroyed. Dual mapping test complete.")
    }
}

struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {   /* ml658: see the note on the main body */
            List {
                Section("Requirements") {
                    guideRow(
                        icon: "cpu",
                        title: "JIT Compilation",
                        detail: "Required for x86 code translation. On iOS 26, StikDebug must stay attached — assign the 'universal' or 'MeloNX' JIT script to Madeira in StikDebug."
                    )
                    guideRow(
                        icon: "memorychip",
                        title: "Increased Memory Limit",
                        detail: "Raises the Jetsam memory threshold. Included in the app entitlements. If not detected, use GetMoreRam to inject it."
                    )
                    guideRow(
                        icon: "arrow.up.left.and.arrow.down.right",
                        title: "Extended Virtual Addressing",
                        detail: "Expands virtual address space to ~64GB. Required for large games. Must be injected via GetMoreRam (free accounts can't provision this)."
                    )
                }

                Section("Setup Steps") {
                    stepRow(number: 1, text: "Install Madeira via SideStore or Xcode")
                    stepRow(number: 2, text: "Install GetMoreRam and run it to inject memory entitlements into your App ID")
                    stepRow(number: 3, text: "Reinstall Madeira with the same IPA to apply injected entitlements")
                    stepRow(number: 4, text: "In StikDebug, assign the 'universal' JIT script to Madeira and launch it")
                    stepRow(number: 5, text: "Launch Madeira and tap 'Test JIT' to verify")
                }

                Section("About") {
                    Text("Madeira is a proof-of-concept for running x86 Windows games on iOS using FEX-Emu, Wine, and Metal-based graphics translation.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Setup Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func guideRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption).fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}

// ============================================================================
// ml643 — LANDSCAPE TOUCH CONTROLS (pass 1: overlay, editor, persistence)
//
// This is the L2 layer from reference_swiftui_liquid_glass_ux_layers.md: glass
// elements composited over the game canvas, repositionable.
//
// 🔑 Everything here MUST live in its own UIWindow. MetalHostView is a raw
// window-level UIView above the whole SwiftUI hierarchy, so a control drawn in
// the normal content tree gets sliced off wherever it overlaps the game surface
// — and zIndex cannot fix that, because zIndex only orders siblings *within*
// SwiftUI. Same reason JoystickPadHost exists; see its comment.
// ============================================================================

/// What a control does when pressed. Codable with associated values so the
/// whole layout round-trips through JSON.
enum ControlAction: Codable, Equatable, Hashable {
    case none
    case key(Int32)          // Windows virtual-key code
    case mouseLeft
    case mouseRight
    case joystickWASD        // renders as a stick, posts W/A/S/D
    case joystickArrows      // renders as a stick, posts the arrow keys
    case keyboardToggle      // raises the iOS keyboard, as in portrait
    case pad(String)         // ml1930: touch gamepad action, preserving saved layout names.

    /// The four keys a stick drives, up/right/down/left. nil for non-sticks.
    var stickKeys: [Int32]? {
        switch self {
        case .joystickWASD:   return [0x57, 0x44, 0x53, 0x41]   // W D S A
        case .joystickArrows: return [0x26, 0x27, 0x28, 0x25]   // up right down left
        default: return nil
        }
    }
    /// SF Symbol drawn in the middle of a key stick's face. WASD and the arrow
    /// keys share one control (`.dirStick`) and would draw the same ring, so a
    /// user could not tell them apart without pressing one. nil for every other
    /// control, including the controller sticks, which carry their own label.
    var stickGlyph: String? {
        switch self {
        case .joystickWASD:   return "keyboard"
        case .joystickArrows: return "arrow.up.and.down.and.arrow.left.and.right"
        default:              return nil
        }
    }
    var isPad: Bool { if case .pad = self { return true }; return false }
    var padName: String? { if case .pad(let name) = self { return name }; return nil }
    var isPadStick: Bool { padName == "LS" || padName == "RS" }

    // ------------------------------------------------------------------
    // HOW A VIRTUAL CONTROLLER BUTTON IS DRAWN. The shape is part of the
    // button's identity: a wide rounded rectangle says "shoulder", a capsule
    // says "system", a coloured circle says "face", so a layout reads without
    // its labels. Saved layouts keep their names ("Menu", "View", "D↑"); only
    // the drawing changes.
    // ------------------------------------------------------------------
    enum PadFace { case round, wide, capsule, small }

    var padFace: PadFace? {
        guard let n = padName else { return nil }
        switch n {
        case "LB", "RB", "LT", "RT": return .wide
        case "Menu", "View":         return .capsule
        case "L3", "R3":             return .small
        default:                     return .round
        }
    }
    /// SF Symbol drawn instead of a label: the four D-pad directions.
    var padGlyph: String? {
        switch padName {
        case "D↑": return "arrowtriangle.up.fill"
        case "D↓": return "arrowtriangle.down.fill"
        case "D←": return "arrowtriangle.left.fill"
        case "D→": return "arrowtriangle.right.fill"
        default:   return nil
        }
    }
    /// The text drawn on the control. Menu/View are the XInput names the
    /// layout stores; the buttons themselves read START/SELECT.
    var padFaceLabel: String {
        switch padName {
        case "Menu": return "START"
        case "View": return "SELECT"
        default:     return label
        }
    }
    /// Drawn size, given the layout's diameter for a round button. Shoulders
    /// are wide, Start/Select are small pills, stick clicks are small circles.
    func controlSize(diameter d: CGFloat) -> CGSize {
        switch padFace {
        case .wide:    return CGSize(width: d * 1.6, height: d * 0.74)
        case .capsule: return CGSize(width: d * 1.2, height: d * 0.5)
        case .small:   return CGSize(width: d * 0.8, height: d * 0.8)
        default:       return CGSize(width: d, height: d)
        }
    }

    var label: String {
        switch self {
        case .none:            return "—"
        case .mouseLeft:       return "L"
        case .mouseRight:      return "R"
        case .keyboardToggle:  return "⌨"
        case .joystickWASD:    return "WASD"
        case .joystickArrows:  return "↕"
        case .pad(let n):      return n
        case .key(let vk):     return ControlAction.keyLabel(vk)
        }
    }

    /// Minimal for pass 1 — the full VK table arrives with the mapping panel.
    static func keyLabel(_ vk: Int32) -> String {
        switch vk {
        case 0x0D: return "⏎"
        case 0x20: return "␣"
        case 0x1B: return "Esc"
        case 0x09: return "⇥"
        case 0x10: return "⇧"
        case 0x11: return "Ctl"
        case 0x12: return "Alt"
        case 0x25: return "←"
        case 0x26: return "↑"
        case 0x27: return "→"
        case 0x28: return "↓"
        default:
            if vk >= 0x30, vk <= 0x5A, let u = UnicodeScalar(UInt32(vk)) {
                return String(Character(u))
            }
            return String(format: "%02X", vk)
        }
    }
}

/// One on-screen control.
///
/// Position is NORMALISED (0–1 of the screen), never points: the device gets
/// rotated and the logical surface can change size, and a layout stored in
/// absolute coordinates scatters the first time either happens.
struct TouchControl: Codable, Identifiable, Equatable {
    var id = UUID()
    var nx: Double = 0.5
    var ny: Double = 0.5
    var scale: Double = 1.0
    var action: ControlAction = .mouseLeft   // usable the moment it is created
    /// A physical controller input that also performs this control's key or
    /// mouse action when the game runs in keyboard-and-mouse controller mode
    /// (PadKeyboardMouse): "A", "RT", "D↑", ...; "LS"/"RS" for a key stick.
    /// Optional, so layouts saved before it existed still decode.
    var padBinding: String?
}

final class TouchControlsModel: ObservableObject {
    static let shared = TouchControlsModel()
    static let baseDiameter: CGFloat = 64

    @Published var controls: [TouchControl] = [] { didSet { save() } }
    @Published var visible = true               { didSet { save() } }
    @Published var editing = false {            // transient, never persisted
        didSet {
            // ml1970: an ended edit is written back to the custom layout it came from.
            if !oldValue && editing { editBaseline = controls }
            if oldValue && !editing { ControlPresetsModel.shared.editingEnded(baseline: editBaseline) }
        }
    }
    @Published var selected: UUID?              // transient
    /// ml1970: the named layout (TouchControlPresets.swift) these controls were
    /// loaded from; nil for controls no layout holds.
    @Published var layoutID: String?            { didSet { save() } }
    /// ml1970: no controls file existed at launch, so the built-in controller
    /// layout may be applied once (ControlPresetsModel.applyDefaultIfNeeded).
    var needsDefaultLayout = false
    private var editBaseline: [TouchControl] = []

    /// One size for the whole layout (0.5...2), multiplying each control's own
    /// pinch `scale`. A library entry keeps its own (Control size) and sets it
    /// for its session; transient, so the developer interface stays at 1.
    @Published var sizeScale: Double = 1.0

    /// A control's drawn diameter. The view, the hit test and the mapping
    /// panel's placement all use it, so the touch region and the pixels agree.
    static func diameter(_ c: TouchControl) -> CGFloat {
        baseDiameter * CGFloat(c.scale) * CGFloat(shared.sizeScale)
    }
    /// The drawn frame: the diameter for round controls, the pad button's own
    /// shape otherwise (ControlAction.controlSize).
    static func size(_ c: TouchControl) -> CGSize { c.action.controlSize(diameter: diameter(c)) }

    private var loading = false
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-controls.json")
    }

    /// `layout` is optional so files written before it existed still decode.
    private struct Saved: Codable { var controls: [TouchControl]; var visible: Bool; var layout: String? }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            controls = s.controls
            visible  = s.visible
            layoutID = s.layout
        }
        needsDefaultLayout = !FileManager.default.fileExists(atPath: Self.url.path)
        loading = false
    }

    private func save() {
        guard !loading else { return }
        guard let d = try? JSONEncoder().encode(Saved(controls: controls, visible: visible, layout: layoutID))
        else { return }
        try? d.write(to: Self.url, options: .atomic)
    }

    /// ml1990: touch controls will feed player 1 this session (visible
    /// controller mappings, or the built-in a user without controls is about to get with MADEIRA_CONTROLS_XBOX_DEFAULT=1).
    var offersControllerInput: Bool {
        visible && (controls.contains { $0.action.padName.map(TouchPadAction.supported) ?? false }
                    || ControlPresetsModel.shared.defaultPending)
    }

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return controls.firstIndex { $0.id == id }
    }

    /// ml644: does this WINDOW point land on something interactive?
    ///
    /// Hit-test geometrically, never by walking the UIView hierarchy. SwiftUI
    /// does not back each Button with its own UIView — the entire overlay is one
    /// _UIHostingView and taps are routed by SwiftUI's own gesture machinery. So
    /// `super.hitTest` returns that same hosting view for EVERY point, buttons
    /// included, and ml643's "is it the root view?" test therefore rejected every
    /// touch in the window. Nothing responded, and edit mode — whose branch
    /// captured everything — could never be entered to mask it.
    /// `topBar: false` in a library session, where LibraryHUD replaces the bar.
    func hitsInteractive(_ p: CGPoint, in bounds: CGRect, topBar: Bool = true) -> Bool {
        // Top bar: two 44pt buttons 10pt apart in play mode, centred, 10pt down,
        // plus the layout menu while touch controls are on (ml1970), plus the
        // keyboard button.
        // Padded generously; a few points of slop costs nothing and a missed tap
        // costs a build.
        let buttons: CGFloat = (TouchControlsOverlay.showsLayoutMenu(self) ? 3 : 2) + 1
        let barW: CGFloat = buttons * 44 + (buttons - 1) * 10
        if topBar, CGRect(x: bounds.midX - barW / 2 - 10, y: 0,
                          width: barW + 20, height: 68).contains(p) { return true }
        guard visible else { return false }
        for c in controls {
            let r = Self.diameter(c) / 2
            let cx = CGFloat(c.nx) * bounds.width
            let cy = CGFloat(c.ny) * bounds.height
            if hypot(p.x - cx, p.y - cy) <= r { return true }
        }
        return false
    }
}

/// Click-through EXCEPT where a control actually is.
///
/// PassthroughWindow (the joystick pad's) returns nil unconditionally because it
/// only ever draws. This one has to take input, so it discriminates: a hit that
/// lands on the hosting root view means empty space, and empty space belongs to
/// the game underneath — mouse-look must keep working between the buttons.
final class ControlsWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let m = TouchControlsModel.shared
        // Edit mode owns the whole screen: drags and the scale pinch must not
        // leak through and swing the camera while you are arranging buttons.
        if m.editing { return super.hitTest(point, with: event) }
        // ml1970: the layout menu and its dialogs are UIKit presentations
        // outside the hosting view (an alert's dimming view covers the screen).
        // While one is up it takes the touches it covers; otherwise its buttons
        // would be dead wherever they are not over the top bar or a control.
        if ControlPresetsModel.enabled, let root = rootViewController?.view,
           let hit = super.hitTest(point, with: event), hit !== self, !hit.isDescendant(of: root) { return hit }
        // A library session (Library.swift), in either orientation: its in-game
        // menu and starting screen take every touch; otherwise only its menu
        // button, its performance overlay and the touch controls do.
        let library = LibraryModel.shared
        if library.current != nil {
            if library.menu || library.launching || library.menuButtonRect.contains(point) ||
                (library.performance && library.performanceRect.contains(point)) {
                return super.hitTest(point, with: event)
            }
            guard m.hitsInteractive(point, in: bounds, topBar: false) else { return nil }
            return super.hitTest(point, with: event)
        }
        // Portrait draws nothing here, so it must consume nothing.
        guard bounds.width > bounds.height else { return nil }
        guard m.hitsInteractive(point, in: bounds) else { return nil }
        return super.hitTest(point, with: event)
    }
}

enum TouchControlsHost {
    private static var window: ControlsWindow?

    static func attach() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                        ?? scenes.first else { return }
        if window == nil {
            // ml644: orientationDidChangeNotification is NOT posted unless
            // generation has been switched on, so without this the overlay would
            // keep a portrait-sized frame after the first rotation.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            let w = ControlsWindow(windowScene: scene)
            // Above the joystick pad's +100. A higher windowLevel is the only
            // ordering nothing inside the app window can undo.
            w.windowLevel = .normal + 101
            w.backgroundColor = .clear
            w.isHidden = false        // deliberately never made key
            let host = UIHostingController(rootView: TouchControlsOverlay())
            host.view.backgroundColor = .clear
            w.rootViewController = host
            window = w
        }
        window?.frame = scene.coordinateSpace.bounds
        fputs("[controls] ml644 overlay attached frame=\(window?.frame ?? .zero) " +
              "controls=\(TouchControlsModel.shared.controls.count)\n", stderr)
    }
}

struct TouchControlsOverlay: View {
    @ObservedObject private var m = TouchControlsModel.shared
    @ObservedObject private var library = LibraryModel.shared
    @State private var pinchBase: Double?

    var body: some View {
        GeometryReader { geo in
            // Landscape only; portrait keeps the existing key row and joystick.
            // A library session is full screen in either orientation, and its
            // HUD (menu button, starting screen, in-game menu) replaces the top
            // bar; the controls hide while its menu or starting screen is up.
            let session = library.current != nil
            let landscape = geo.size.width > geo.size.height || session
            ZStack(alignment: .top) {
                if landscape {
                    if (m.visible || m.editing) && !library.blocksGameplayTouch {
                        controls(geo.size, session: session)
                    }
                    if session && !m.editing { LibraryHUD() } else { topBar }
                    if m.editing, let i = m.index(of: m.selected) {
                        MappingPanel(control: m.controls[i], screen: geo.size)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(scalePinch, including: m.editing ? .all : .subviews)
            .onAppear { applyDefaultLayout(geo); configureGamepad(landscape: landscape) }
            .onChange(of: geo.size) { _, _ in applyDefaultLayout(geo); configureGamepad(landscape: landscape) }
            .onChange(of: m.controls) { _, _ in configureGamepad(landscape: landscape) }
            .onChange(of: m.visible) { _, _ in configureGamepad(landscape: landscape) }
            .onChange(of: m.editing) { _, _ in configureGamepad(landscape: landscape) }
            .onChange(of: library.blocksGameplayTouch) { _, _ in configureGamepad(landscape: landscape) }
            .onDisappear { GamepadInput.shared.configureTouch(controls: []); TouchMouseGate.padOverlay = false }
        }
        .ignoresSafeArea()
    }

    /// Every control in ONE GlassEffectContainer: on iOS 26 the system merges
    /// glass shapes that come within `spacing` of each other, so a D-pad cross
    /// or a face diamond pinched tight reads as one piece of glass and a button
    /// dragged next to another flows into it. 12 pt: the built-in layout's
    /// neighbours sit further apart than that, so nothing merges until it is
    /// moved almost touching. Before 26 the same views stack as plain material.
    @ViewBuilder private func controls(_ screen: CGSize, session: Bool) -> some View {
        let buttons = ForEach(m.controls) { c in
            TouchControlButton(control: c, screen: screen)
                // A library session's Control opacity; full while editing.
                .opacity(session && !m.editing ? library.opacity : 1)
        }
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                ZStack { buttons }
                    .frame(width: screen.width, height: screen.height, alignment: .topLeading)
            }
        } else {
            buttons
        }
    }

    private func configureGamepad(landscape: Bool) {
        let ids = landscape && m.visible
            ? m.controls.filter { $0.action.padName.map(TouchPadAction.supported) ?? false }.map(\.id) : []
        // Menus and the control editor keep the pad connected but take no input (#204);
        // a touch that misses the controls is no mouse only while they do (#150).
        let accepting = !m.editing && !library.blocksGameplayTouch
        GamepadInput.shared.configureTouch(controls: Set(ids), acceptingInput: accepting)
        TouchMouseGate.padOverlay = accepting && !ids.isEmpty
    }

    /// ml1970: with MADEIRA_CONTROLS_XBOX_DEFAULT=1, a user with no controls file gets the built-in controller
    /// layout on the first landscape overlay, laid out for this screen (never over an existing controls file).
    private func applyDefaultLayout(_ geo: GeometryProxy) {
        guard m.needsDefaultLayout, geo.size.width > geo.size.height else { return }
        let i = geo.safeAreaInsets
        ControlPresetsModel.shared.applyDefaultIfNeeded(screen: ControlPresetScreen(
            width: Double(geo.size.width), height: Double(geo.size.height),
            left: Double(i.leading), right: Double(i.trailing),
            top: Double(i.top), bottom: Double(i.bottom)))
    }

    /// ml1970: while editing, a Done button ends the edit (keeping it in the
    /// active custom layout) in place of the checkmark, and the show/hide glyph
    /// is hidden. MADEIRA_CONTROLS_EDITOR_DONE=0 restores the previous bar.
    static let editorDone = GamepadInput.flag("MADEIRA_CONTROLS_EDITOR_DONE")

    /// ml1970: the layout menu, offered only while touch controls are shown.
    static func showsLayoutMenu(_ m: TouchControlsModel) -> Bool {
        ControlPresetsModel.enabled && m.visible && !m.editing
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if m.editing && Self.editorDone {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.22)) {
                        m.selected = nil
                        m.editing = false
                    }
                } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(GlassShape())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Done editing controls")
            } else {
                // The iOS keyboard for the game, as ⌨ in the portrait key row.
                glassButton("keyboard") { MetalBackedView.toggleKeyboard() }
                glassButton("gamecontroller", dim: !m.visible) { m.visible.toggle() }
                if Self.showsLayoutMenu(m) {
                    ControlLayoutMenu()
                        .transition(.opacity.combined(with: .scale))
                }
                glassButton(m.editing ? "checkmark" : "pencil") {
                    m.editing.toggle()
                    if !m.editing { m.selected = nil }
                }
            }
            if m.editing {
                glassButton("plus") {
                    var c = TouchControl()
                    // Stagger, so repeated adds do not stack invisibly.
                    c.nx = 0.5 + Double(m.controls.count % 3) * 0.06
                    c.ny = 0.5 + Double(m.controls.count % 2) * 0.06
                    m.controls.append(c)
                    m.selected = c.id
                }
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.top, 10)
        .animation(.easeInOut(duration: 0.22), value: m.editing)
    }

    /// Pinch anywhere scales the SELECTED control. With nothing selected it does
    /// nothing rather than guessing which one you meant.
    private var scalePinch: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                guard m.editing, let i = m.index(of: m.selected) else { return }
                if pinchBase == nil { pinchBase = m.controls[i].scale }
                m.controls[i].scale = min(max((pinchBase ?? 1) * Double(v), 0.5), 3.0)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func glassButton(_ system: String, dim: Bool = false,
                             _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.22)) { action() }
        } label: {
            // Stroke only — never a .fill variant.
            Image(systemName: system)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(dim ? 0.35 : 1.0))
                .frame(width: 44, height: 44)
                .background(GlassShape(circle: true))
        }
        .buttonStyle(.plain)
    }
}

/// Shared glass backing, with the pre-26 fallback the codebase already uses.
/// A circle, a capsule or a rounded rectangle; `tint` colours the glass itself
/// (the four face buttons), so the colour is a hue on the material rather than
/// an opaque disc. Inside a GlassEffectContainer these merge when they come
/// close, which is what makes a tight D-pad or face diamond read as one piece.
struct GlassShape: View {
    var circle = false
    var capsule = false
    var cornerRadius: CGFloat = 18
    var tint: Color? = nil
    fileprivate var shape: AnyShape {
        if circle { return AnyShape(Circle()) }
        if capsule { return AnyShape(Capsule()) }
        return AnyShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
    var body: some View {
        Color.clear.glassFace(self)
    }
}

extension View {
    /// Glass BEHIND this view, with the view as the glass's content. Inside a
    /// GlassEffectContainer every glass effect is composited together as one
    /// layer over the container's other children, so a label that is merely a
    /// sibling of its glass ends up blurred underneath it; a label that is the
    /// glass view's own content is drawn on top, as the system's buttons are.
    @ViewBuilder func glassFace(_ g: GlassShape) -> some View {
        if #available(iOS 26.0, *) {
            if let tint = g.tint {
                self.glassEffect(.regular.tint(tint.opacity(0.55)), in: g.shape)
            } else {
                self.glassEffect(.regular, in: g.shape)
            }
        } else {
            self.background {
                g.shape.fill(.ultraThinMaterial)
                if let tint = g.tint { g.shape.fill(tint.opacity(0.35)) }
            }
        }
    }
}

extension ControlAction {
    /// Xbox face colours. Everything else is uncoloured: a wash of tint on every
    /// button would make the four that mean something unreadable.
    var padTint: Color? {
        switch padName {
        case "A": return Color(red: 0.36, green: 0.76, blue: 0.30)
        case "B": return Color(red: 0.88, green: 0.28, blue: 0.24)
        case "X": return Color(red: 0.24, green: 0.53, blue: 0.92)
        case "Y": return Color(red: 0.96, green: 0.76, blue: 0.16)
        default:  return nil
        }
    }
}

struct TouchControlButton: View {
    let control: TouchControl
    let screen: CGSize
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var isDown = false
    @State private var dragBase: CGPoint?
    @State private var stickDir: Int = -1
    @State private var padVector = CGSize.zero

    private var diameter: CGFloat { TouchControlsModel.diameter(control) }
    private var size: CGSize { TouchControlsModel.size(control) }
    private var isStick: Bool { control.action.stickKeys != nil || control.action.isPadStick }
    private var isSelected: Bool { m.editing && m.selected == control.id }

    /// The resting outline and the edit-mode selection ring, in the shape the
    /// control actually has.
    private var outline: AnyShape {
        switch control.action.padFace {
        case .some(.wide):    return AnyShape(RoundedRectangle(cornerRadius: size.height * 0.30))
        case .some(.capsule): return AnyShape(Capsule())
        default:              return AnyShape(Circle())
        }
    }

    /// A controller button: coloured circle (A/B/X/Y), arrow (D-pad), wide
    /// shoulder (LB/RB/LT/RT), START/SELECT pill, small L3/R3.
    @ViewBuilder private var padFace: some View {
        let a = control.action
        switch a.padFace ?? .round {
        case .round:
            Group {
                if let g = a.padGlyph {
                    Image(systemName: g)
                        .font(.system(size: size.height * 0.40, weight: .semibold))
                        .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.88))
                } else {
                    Text(a.padFaceLabel)
                        .font(.system(size: size.height * (a.padFaceLabel.count > 2 ? 0.24 : 0.40), weight: .semibold))
                        .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.92))
                }
            }
            .frame(width: size.width, height: size.height)
            .glassFace(GlassShape(circle: true, tint: a.padTint))
        case .small:
            Text(a.padFaceLabel)
                .font(.system(size: size.height * 0.36, weight: .semibold))
                .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.85))
                .frame(width: size.width, height: size.height)
                .glassFace(GlassShape(circle: true))
        case .wide:
            Text(a.padFaceLabel)
                .font(.system(size: size.height * 0.42, weight: .semibold))
                .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.88))
                .frame(width: size.width, height: size.height)
                .glassFace(GlassShape(cornerRadius: size.height * 0.30))
        case .capsule:
            Text(a.padFaceLabel)
                .font(.system(size: size.height * 0.40, weight: .semibold))
                .kerning(0.6)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.85))
                .frame(width: size.width, height: size.height)
                .glassFace(GlassShape(capsule: true))
        }
    }

    var body: some View {
        ZStack {
            if control.action.isPadStick {
                ZStack {
                    Circle().fill(.white.opacity(isDown ? 0.55 : 0.25))
                        .frame(width: diameter * 0.42, height: diameter * 0.42)
                        .offset(x: padVector.width * diameter * 0.29, y: padVector.height * diameter * 0.29)
                    Text(control.action.label).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                .frame(width: diameter, height: diameter)
                .glassFace(GlassShape(circle: true))
            } else if control.action.stickKeys != nil {
                // Reuse the portrait pad's face so both look and animate the
                // same; scale it to whatever size this control was pinched to.
                // The glass goes on at the control's real size, outside the
                // scaleEffect, so it stays centred on the ring and knob.
                JoystickFace(held: isDown, dir: stickDir, alwaysExpanded: true,
                              glyph: control.action.stickGlyph, glass: false)
                    .frame(width: JoystickFace.padRadius * 2,
                           height: JoystickFace.padRadius * 2)
                    .scaleEffect(diameter / (JoystickFace.padRadius * 2))
                    .frame(width: diameter, height: diameter)
                    .glassFace(GlassShape(circle: true))
            } else if control.action.isPad {
                padFace
            } else {
                // The label is the glass's content (see glassFace), so it is drawn
                // on top of the glass rather than blurred underneath it.
                Text(control.action.label)
                    .font(.system(size: diameter * (control.action.label.count > 2 ? 0.22 : 0.34),
                                  weight: .medium))
                    .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.85))
                    .frame(width: size.width, height: size.height)
                    .glassFace(GlassShape(circle: true))
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(outline.stroke(.white.opacity(isSelected ? 0.95
                                               : (isStick ? 0 : 0.28)),
                                lineWidth: isSelected ? 2 : 1))
        // A stick must not shrink under the thumb; only round buttons do that.
        .scaleEffect(!isStick && isDown ? 0.92 : 1.0)
        // ml890: no press animation. Pressing the on-screen Enter key killed the
        // whole process with a SwiftUI trap on com.apple.SwiftUI.AsyncRenderer
        // (DisplayList.ViewUpdater.ViewCache.commitAsyncValues) while this
        // glass control animated its press; the state change now applies at once.
        // ml646: the springy knob, same curve as the portrait pad overlay.
        .animation(.spring(response: 0.22, dampingFraction: 0.58), value: stickDir)
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    m.controls.removeAll { $0.id == control.id }
                    m.selected = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
            }
        }
        .overlay {
            if let action = control.action.padName, !m.editing {
                TouchPadSurface(control: control.id, action: action) { vector, down in
                    padVector = vector; isDown = down
                }
            }
        }
        .onDisappear { if control.action.isPad { padVector = .zero; isDown = false } }
        .onChange(of: m.editing) { _, _ in if control.action.isPad { padVector = .zero; isDown = false } }
        .onChange(of: screen) { _, _ in if control.action.isPad { padVector = .zero; isDown = false } }
        .onChange(of: control.action) { old, new in
            if old.isPad || new.isPad { padVector = .zero; isDown = false }
        }
        .position(x: CGFloat(control.nx) * screen.width,
                  y: CGFloat(control.ny) * screen.height)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if m.editing {
                        m.selected = control.id
                        guard let i = m.index(of: control.id) else { return }
                        if dragBase == nil { dragBase = CGPoint(x: control.nx, y: control.ny) }
                        let b = dragBase ?? .zero
                        m.controls[i].nx = min(max(b.x + Double(v.translation.width  / screen.width),  0.03), 0.97)
                        m.controls[i].ny = min(max(b.y + Double(v.translation.height / screen.height), 0.03), 0.97)
                    } else if let q = control.action.stickKeys {
                        isDown = true
                        applyStick(snap(v.translation), q)
                    } else if !isDown {
                        isDown = true
                        press(true)
                    }
                }
                .onEnded { _ in
                    dragBase = nil
                    if let q = control.action.stickKeys {
                        applyStick(-1, q)          // release every held direction
                        isDown = false
                    } else if isDown {
                        isDown = false
                        press(false)
                    }
                },
            including: control.action.isPad && !m.editing ? .subviews : .all
        )
    }

    /// 8-way snap. Screen y grows downward, so measure clockwise from "up".
    private func snap(_ t: CGSize) -> Int {
        let d = (t.width * t.width + t.height * t.height).squareRoot()
        if d < diameter * 0.22 { return -1 }        // deadzone scales with the control
        var a = atan2(t.width, -t.height) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    private func stickKeys(_ d: Int, _ q: [Int32]) -> [Int32] {
        switch d {
        case 0: return [q[0]]
        case 1: return [q[0], q[1]]
        case 2: return [q[1]]
        case 3: return [q[2], q[1]]
        case 4: return [q[2]]
        case 5: return [q[2], q[3]]
        case 6: return [q[3]]
        case 7: return [q[0], q[3]]
        default: return []
        }
    }

    /// Release what is no longer held, press what newly is. A blanket
    /// release/re-press would make a held direction stutter as the thumb
    /// wanders inside one sector.
    private func applyStick(_ next: Int, _ q: [Int32]) {
        guard next != stickDir else { return }
        let old = Set(stickKeys(stickDir, q)), new = Set(stickKeys(next, q))
        for vk in old.subtracting(new) { winios_post_key(vk, 0) }
        for vk in new.subtracting(old) { winios_post_key(vk, 1) }
        if stickDir == -1, next != -1 { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        stickDir = next
    }

    /// Haptic on the DOWN edge only — a held movement key would otherwise buzz
    /// continuously for as long as you walk.
    private func press(_ down: Bool) {
        if down { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        switch control.action {
        case .key(let vk):
            winios_post_key(vk, down ? 1 : 0)
        case .mouseLeft:
            winios_pointer(0, 0, down ? 0x0002 : 0x0004, 0)   // LEFTDOWN / LEFTUP
        case .mouseRight:
            winios_pointer(0, 0, down ? 0x0008 : 0x0010, 0)   // RIGHTDOWN / RIGHTUP
        case .keyboardToggle:
            if down { MetalBackedView.toggleKeyboard() }
        case .none, .joystickWASD, .joystickArrows:
            break                                              // sticks drive themselves
        case .pad:
            break     // TouchPadSurface owns pad presses and cancellation.
        }
    }
}

/// ml645 — the mapping panel. Shown for the selected control in edit mode.
struct MappingPanel: View {
    let control: TouchControl
    let screen: CGSize
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var tab = 0                    // 0 keyboard, 1 controller


    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton(0, "keyboard")
                tabButton(1, "gamecontroller")
            }
            Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
            ScrollView {
                (tab == 0 ? AnyView(keyboardTab) : AnyView(controllerTab))
                    .padding(10)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .background(GlassShape())
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 1))
        .position(layout.center)
    }

    private struct Placement { var center: CGPoint; var size: CGSize }

    /// ml646: the panel must NEVER sit under the control it is editing.
    ///
    /// The old version only tried below/above and then clamped, which on a
    /// 390pt-tall landscape phone silently put the panel right on top of any
    /// control near the middle: 240 of panel + 64 of control + gaps does not fit
    /// in 390 either way, so the clamp was the only thing deciding placement.
    ///
    /// Try each side in turn, at shrinking sizes, and take the first that fits
    /// on the screen along the axis it separates on. Clamping the OTHER axis is
    /// then always safe — below/above are separated vertically, so no horizontal
    /// clamp can reintroduce an overlap, and vice versa.
    private var layout: Placement {
        let cx = CGFloat(control.nx) * screen.width
        let cy = CGFloat(control.ny) * screen.height
        let r  = TouchControlsModel.diameter(control) / 2
        let gap: CGFloat = 14, edge: CGFloat = 8

        for size in [CGSize(width: 340, height: 236),
                     CGSize(width: 300, height: 196),
                     CGSize(width: 264, height: 164)] {
            let clampX = min(max(cx, size.width  / 2 + edge), screen.width  - size.width  / 2 - edge)
            let clampY = min(max(cy, size.height / 2 + edge), screen.height - size.height / 2 - edge)
            if cy + r + gap + size.height <= screen.height - edge {
                return Placement(center: CGPoint(x: clampX, y: cy + r + gap + size.height / 2), size: size)
            }
            if cy - r - gap - size.height >= edge {
                return Placement(center: CGPoint(x: clampX, y: cy - r - gap - size.height / 2), size: size)
            }
            if cx + r + gap + size.width <= screen.width - edge {
                return Placement(center: CGPoint(x: cx + r + gap + size.width / 2, y: clampY), size: size)
            }
            if cx - r - gap - size.width >= edge {
                return Placement(center: CGPoint(x: cx - r - gap - size.width / 2, y: clampY), size: size)
            }
        }
        // Nothing fits alongside — smallest panel, corner furthest from the
        // control, so it still cannot cover it.
        let size = CGSize(width: 264, height: 164)
        return Placement(
            center: CGPoint(x: cx < screen.width  / 2 ? screen.width  - size.width  / 2 - edge
                                                      : size.width  / 2 + edge,
                            y: cy < screen.height / 2 ? screen.height - size.height / 2 - edge
                                                      : size.height / 2 + edge),
            size: size)
    }

    private func tabButton(_ i: Int, _ icon: String) -> some View {
        Button { tab = i } label: {
            Image(systemName: icon)                       // stroke, not filled
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(tab == i ? 1.0 : 0.38))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.plain)
    }

    // ---- catalogues ----
    private var letters: [(String, ControlAction)] {
        (0x41...0x5A).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
    }
    private var digits: [(String, ControlAction)] {
        (0x30...0x39).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
    }
    private var fkeys: [(String, ControlAction)] {
        (0...11).map { ("F\($0 + 1)", ControlAction.key(Int32(0x70 + $0))) }
    }
    private var numpad: [(String, ControlAction)] {
        (0...9).map { ("N\($0)", ControlAction.key(Int32(0x60 + $0))) }
        + [("N*", .key(0x6A)), ("N+", .key(0x6B)), ("N−", .key(0x6D)),
           ("N.", .key(0x6E)), ("N/", .key(0x6F))]
    }

    private var keyboardTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if GamepadInput.keyboardMouseAvailable, !control.action.isPad, control.action != .none, control.action != .keyboardToggle {
                bindingSection
            }
            section("Pointer, sticks & special", [
                ("L click", .mouseLeft), ("R click", .mouseRight),
                ("WASD", .joystickWASD), ("Arrows", .joystickArrows),
                ("Keyboard", .keyboardToggle), ("None", .none),
            ])
            section("Letters", letters)
            section("Numbers", digits)
            section("Function", fkeys)
            section("Modifiers & editing", [
                ("Esc", .key(0x1B)), ("Tab", .key(0x09)), ("Caps", .key(0x14)),
                ("Shift", .key(0x10)), ("Ctrl", .key(0x11)), ("Alt", .key(0x12)),
                ("Space", .key(0x20)), ("Enter", .key(0x0D)), ("Bksp", .key(0x08)),
                ("Win", .key(0x5B)),
            ])
            section("Navigation", [
                ("←", .key(0x25)), ("↑", .key(0x26)), ("→", .key(0x27)), ("↓", .key(0x28)),
                ("Ins", .key(0x2D)), ("Del", .key(0x2E)), ("Home", .key(0x24)),
                ("End", .key(0x23)), ("PgUp", .key(0x21)), ("PgDn", .key(0x22)),
            ])
            section("Symbols", [
                ("-", .key(0xBD)), ("=", .key(0xBB)), ("[", .key(0xDB)), ("]", .key(0xDD)),
                ("\\", .key(0xDC)), (";", .key(0xBA)), ("'", .key(0xDE)), (",", .key(0xBC)),
                (".", .key(0xBE)), ("/", .key(0xBF)), ("`", .key(0xC0)),
            ])
            section("Numpad", numpad)
        }
    }

    private var controllerTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Controller controls feed XInput player 1. LS and RS are analogue sticks; "
                 + "LT and RT are full-press triggers. Touch and physical controls can be used together.")
                .font(.system(size: 11))
                .foregroundStyle(.orange.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
            section("Face", [("A", .pad("A")), ("B", .pad("B")), ("X", .pad("X")), ("Y", .pad("Y"))])
            section("D-pad", [("D↑", .pad("D↑")), ("D↓", .pad("D↓")),
                              ("D←", .pad("D←")), ("D→", .pad("D→"))])
            section("Bumpers & triggers", [("LB", .pad("LB")), ("RB", .pad("RB")),
                                           ("LT", .pad("LT")), ("RT", .pad("RT"))])
            section("Sticks", [("LS", .pad("LS")), ("RS", .pad("RS")),
                               ("L3", .pad("L3")), ("R3", .pad("R3"))])
            // Start and Select are XInput's Menu and View; the layout keeps the
            // XInput names, the chips and the buttons read Start/Select.
            section("System", [("Start", .pad("Menu")), ("Select", .pad("View")),
                               ("Guide", .pad("Guide"))])
        }
    }

    /// Keyboard-and-mouse controller mode: which physical input performs this
    /// control's action. A key stick binds to a stick; everything else to a
    /// button or trigger. The chosen chip is highlighted; tapping it again clears.
    private var bindingSection: some View {
        let names = control.action.stickKeys != nil ? PadBindings.stickNames : PadBindings.buttonNames
        return VStack(alignment: .leading, spacing: 6) {
            Text("Controller button for this action (keyboard & mouse mode)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                ForEach(names, id: \.self) { name in
                    let on = control.padBinding == name
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if let i = m.index(of: control.id) { m.controls[i].padBinding = on ? nil : name }
                    } label: {
                        Text(name == "Menu" ? "Start" : name == "View" ? "Select" : name)
                            .font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.55)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor.opacity(0.6) : .white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func section(_ title: String, _ items: [(String, ControlAction)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    chip(it.0, it.1)
                }
            }
        }
    }

    private func chip(_ label: String, _ action: ControlAction) -> some View {
        let on = control.action == action
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if let i = m.index(of: control.id) { m.controls[i].action = action }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundStyle(.white.opacity(action.isPad ? 0.55 : 1.0))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(.white.opacity(on ? 0.36 : 0.12)))
        }
        .buttonStyle(.plain)
    }
}
