import SwiftUI
import UIKit
import QuartzCore

/// Frame-rate intent for the ProMotion panel. CAMetalLayer presents alone
/// don't express one: iOS parks the display at 60Hz and only promotes on
/// touch (observed 2026-07-05: MAX mode ran 60 except ~119 bursts while
/// touching). An active CADisplayLink with a preferredFrameRateRange is the
/// documented way for present-driven Metal apps to hold the panel higher.
/// The tick itself does nothing.
///
/// Default (as on main): armed only outside the 60 and 30 caps, i.e. for
/// MAX and RAW, where the game is meant to run above 60, and for the 40 cap,
/// whose 25ms spacing needs the 120Hz grid (at 60Hz it would land on 33.3ms).
///
/// Opt-in `env.MADEIRA_PROMOTE = 1` (Settings > Display > Hold the display
/// at its maximum rate) also arms it in the 60 cap. The panel rate is the
/// grid a present snaps to: the 60 cap is a minimum spacing between
/// presentations (afterMinimumDuration), and a drawable becomes visible at
/// a vblank, never between two. With the panel parked at 60Hz a frame
/// ready at 17-25ms waits for the 33.3ms vblank, so a 20ms pipeline reports
/// 30 FPS; at 120Hz the same frame lands at 25ms (40 FPS). The cap itself is
/// unchanged, but the panel runs at 120Hz for the whole session, which
/// costs power, so it is not the default. The 30 cap keeps a 60Hz intent
/// (33.3ms is an exact multiple of 16.67ms).
final class ProMotionIntent {
    static let shared = ProMotionIntent()
    private var link: CADisplayLink?
    private var activeMax: Float = 0

    /// Honest report of what the panel can do, for the native `[frame]` line.
    static var panelMaxFPS: Int { UIScreen.main.maximumFramesPerSecond }

    /// The opt-in above; read when a session's pacing is applied.
    static var holdMaximum: Bool { MadeiraConfig.flag("MADEIRA_PROMOTE", fallback: false) }

    /// ml2020: hold the panel at 60 Hz under the 60 and 30 caps too. Without any
    /// display link a ProMotion iPhone lets the panel idle once nothing drives
    /// it: a 32-bit title under the 60 cap presented at a steady 9.9 FPS with
    /// the GPU 1% busy, every frame parked 80 ms in nextDrawable (the compositor
    /// handing drawables back at the idle rate), 43 FPS while the user's touches
    /// kept the panel up (device logs 2026-10-25, `[gpu-perf] ml1254`). A 60 Hz
    /// range is the smallest intent that keeps the compositor at the cap's own
    /// grid. `env.MADEIRA_PANEL_IDLE = 1` restores the old behaviour (no link
    /// under the 60 and 30 caps).
    static var panelFloor: Bool { !MadeiraConfig.flag("MADEIRA_PANEL_IDLE", fallback: false) }

    /// Whether DXMT has the 30 FPS cap (vsync mode 3) and the display-rate
    /// hook. Both arrive with willfaust/dxmt#1; without it mode 3 would run
    /// uncapped, so the 30 choice is offered only when this is true.
    static var has30Cap: Bool = {
        madeira_set_display_max_fps(Int32(panelMaxFPS), 0)
        return madeira_dxmt_has_display_pacing() != 0
    }()

    /// Whether the 40 FPS cap (vsync mode 4) is offered: DXMT must have it
    /// (madeira_dxmt_has_40_cap; without it mode 4 would present uncapped) and
    /// the panel must reach 120 Hz, because 25 ms is three refreshes at 120 Hz
    /// but rounds to 33 ms at 60 Hz. maxHz(for:) holds the panel at its maximum
    /// while it runs.
    static var has40Cap: Bool { madeira_dxmt_has_40_cap() != 0 && panelMaxFPS >= 120 }

    /// The pacing mode a saved FPS limit runs as: 30 and 40 run as 60 when
    /// they are not offered.
    static func supportedMode(_ mode: Int) -> Int32 {
        if mode == 3 && !has30Cap { return 1 }
        if mode == 4 && !has40Cap { return 1 }
        return Int32(mode)
    }

    /// `maxHz` 0 means "tear it down".
    func setActive(_ active: Bool, maxHz: Int = ProMotionIntent.panelMaxFPS) {
        let want = Float(max(maxHz, 0))
        if active && want > 0 {
            if link != nil && activeMax == want { return }
            link?.invalidate()
            let l = CADisplayLink(target: self, selector: #selector(tick))
            // `minimum` must not exceed the panel's own maximum or CoreAnimation
            // clamps the whole range away (a 60Hz device asked for min 60 /
            // max 120 gets nothing useful).
            let lo = Float(min(60, maxHz))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: lo, maximum: want, preferred: want)
            l.add(to: .main, forMode: .common)
            link = l
            activeMax = want
            displaySyncApplied = false; armedAt = 0; tickStart = 0   // ml2021: per arming
            fputs("[promote] display link armed preferred=\(Int(want))Hz panel_max=\(ProMotionIntent.panelMaxFPS)Hz\n", stderr)
            // ml2020: stderr written before Wine starts is not in the exported log; say it there too
            LogStore.shared.log("[promote] display link armed min=\(Int(lo))Hz preferred=\(Int(want))Hz panel_max=\(ProMotionIntent.panelMaxFPS)Hz")
        } else {
            if link != nil { fputs("[promote] display link released\n", stderr) }
            if link != nil { LogStore.shared.log("[promote] display link released") }
            link?.invalidate()
            link = nil
            activeMax = 0
        }
    }

    /// The intent that belongs to a given pacing mode (0 = none). See the type comment.
    static func maxHz(for mode: Int32) -> Int {
        let floor = panelFloor ? min(60, panelMaxFPS) : 0                 // ml2020: see panelFloor
        if mode == 3 { return holdMaximum ? min(60, panelMaxFPS) : floor }   // 30 cap
        if mode == 1 { return holdMaximum ? panelMaxFPS : floor }            // 60 cap
        return panelMaxFPS                                                    // MAX, RAW, 40 cap
    }

    /// Arms or releases the link for `mode` and publishes the rates to DXMT.
    static func apply(mode: Int32) {
        let hz = maxHz(for: mode)
        LogStore.shared.log("[promote] pacing mode \(mode): display intent \(hz) Hz (panel max \(panelMaxFPS), hold-maximum \(holdMaximum), floor \(panelFloor))")
        shared.setActive(hz > 0, maxHz: hz)
        madeira_set_display_max_fps(Int32(panelMaxFPS), Int32(hz))
    }

    /// ml2021: what the link actually runs at. Log 71 ran with the 120 Hz link armed and
    /// the title still parked 80 ms a frame in nextDrawable, so whether the panel follows
    /// the intent at all is the open question; every 10 s the exported log gets the tick
    /// count, the mean interval and the longest one.
    private var tickCount = 0
    private var tickStart: CFTimeInterval = 0
    private var tickLast: CFTimeInterval = 0
    private var tickMaxGap: CFTimeInterval = 0
    /// ml2021 (opt-in, env.MADEIRA_PROMOTE_KICK = 1): a one-pixel layer whose opacity
    /// alternates every tick, so each tick commits a CoreAnimation transaction. The
    /// DXMT note of 2026-07-03 found that this device's compositor completes our
    /// layer's presentations only when something else makes it composite; if the
    /// drawable waits fall with this on, that is what the display link alone does not do.
    private var kickLayer: CALayer?
    private var kickOn = false
    static var kickEnabled: Bool { MadeiraConfig.flag("MADEIRA_PROMOTE_KICK", fallback: false) }

    /// ml2021: env.MADEIRA_DISPLAY_SYNC applied to the game's layer once the session's
    /// environment is exported (the link is armed a few ms BEFORE the game's config lines
    /// are, so log 77's "= 1" run never saw it: the layer kept displaySyncEnabled=false from
    /// app start). Applied from the first tick a second after arming, once per arming.
    private var displaySyncApplied = false
    private var armedAt: CFTimeInterval = 0
    private func applyDisplaySync(now: CFTimeInterval) {
        guard !displaySyncApplied, now - armedAt >= 1 else { return }
        displaySyncApplied = true
        let layer = MetalHostView.shared.metalLayer
        let sel = NSSelectorFromString("setDisplaySyncEnabled:")
        guard layer.responds(to: sel) else { return }
        let on = MadeiraConfig.flag("MADEIRA_DISPLAY_SYNC", fallback: false)
        layer.perform(sel, with: NSNumber(value: on))
        LogStore.shared.log("[promote] game layer displaySyncEnabled=\(on ? "true (env.MADEIRA_DISPLAY_SYNC = 1)" : "false (default; env.MADEIRA_DISPLAY_SYNC = 1 keeps display sync)")")
    }

    @objc private func tick(_ sender: CADisplayLink) {
        let now = sender.timestamp
        if armedAt == 0 { armedAt = now }
        applyDisplaySync(now: now)
        if tickStart == 0 { tickStart = now; tickLast = now; tickCount = 0; tickMaxGap = 0 }
        else {
            tickMaxGap = max(tickMaxGap, now - tickLast)
            tickLast = now
        }
        tickCount += 1
        let span = now - tickStart
        if span >= 10 {
            let hz = Double(tickCount - 1) / span
            LogStore.shared.log(String(format: "[promote] link ran %d ticks in %.1f s = %.1f Hz (mean %.1f ms, longest gap %.1f ms, target %.0f ms)",
                                       tickCount, span, hz, span * 1000 / Double(max(1, tickCount - 1)), tickMaxGap * 1000,
                                       (sender.targetTimestamp - sender.timestamp) * 1000))
            tickStart = now; tickCount = 1; tickMaxGap = 0
        }
        if ProMotionIntent.kickEnabled { kick() }
    }

    private func kick() {
        if kickLayer == nil {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first else { return }
            let l = CALayer()
            l.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            l.backgroundColor = UIColor.black.cgColor
            l.opacity = 0.01
            window.layer.addSublayer(l)
            kickLayer = l
            LogStore.shared.log("[promote] kick layer added (env.MADEIRA_PROMOTE_KICK = 1): a transaction per tick")
        }
        kickOn.toggle()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        kickLayer?.opacity = kickOn ? 0.02 : 0.01
        CATransaction.commit()
    }
}

/// Opt-in `env.MADEIRA_THERMAL_CAP = 1`: when iOS reports the device as
/// serious or critical, a session paced at the 60 cap, MAX or RAW drops to the
/// 40 cap (three refreshes at 120 Hz, so evenly spaced; the 30 cap where 40 is
/// not offered). A hot device clocks its CPU down, and at the 60 cap a frame
/// that misses 16.7 ms waits for the next 60 Hz vblank and shows at 33.3 ms, so
/// an emulated game swings between 60 and the 30s; a steady 40 does less work
/// per second and stays even. The session's own mode comes back once the
/// device is nominal again. A cap chosen during the session (the HUD pill or
/// the in-game menu) wins: it is never replaced or restored. Not saved.
final class ThermalPacing {
    static let shared = ThermalPacing()
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_THERMAL_CAP", fallback: false) }
    private var observer: NSObjectProtocol?
    private var restoreMode: Int32?
    private var ourMode: Int32 = -1

    /// From a session's start, after its pacing is applied.
    func begin() {
        end()
        guard Self.enabled else { return }
        observer = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.evaluate() }
        LogStore.shared.log("[thermal-cap] on: 40 FPS while the device is serious or critical (env.MADEIRA_THERMAL_CAP)")
        evaluate()
    }

    /// From a session's end.
    func end() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil; restoreMode = nil; ourMode = -1
    }

    /// The session's cap was changed by hand: leave it alone from now on.
    func userChose() { restoreMode = nil; ourMode = -1 }

    private func evaluate() {
        let state = ProcessInfo.processInfo.thermalState
        let current = madeira_get_vsync_locked()
        if let restore = restoreMode {
            guard current == ourMode else { userChose(); return }
            guard state == .nominal else { return }
            madeira_set_vsync_locked(restore)
            ProMotionIntent.apply(mode: restore)
            LogStore.shared.log("[thermal-cap] nominal again: back to the session's mode \(restore)")
            restoreMode = nil; ourMode = -1
            return
        }
        guard state == .serious || state == .critical else { return }
        let target: Int32 = ProMotionIntent.has40Cap ? 4 : ProMotionIntent.has30Cap ? 3 : -1
        guard target >= 0, current == 1 || current == 0 || current == 2 else {
            LogStore.shared.log("[thermal-cap] hot, but mode \(current) is kept (no lower cap offered, or already capped)")
            return
        }
        restoreMode = current; ourMode = target
        madeira_set_vsync_locked(target)
        ProMotionIntent.apply(mode: target)
        LogStore.shared.log("[thermal-cap] \(state == .critical ? "critical" : "serious"): mode \(current) -> \(target == 4 ? "40" : "30") FPS cap")
    }
}

/// Small overlay shown over the Metal render view. Reads DXMT's present
/// counter at 100ms intervals into a 5s rolling buffer, displays current
/// count + smoothed FPS computed over an adaptive window.
///
/// Adaptive display logic:
///   - Backend always samples every 100ms (50 samples in the 5s buffer).
///   - Displayed FPS uses a window long enough to contain ≥ ~3 frame samples,
///     so the readout is stable at any rate. At 60fps the window is ~100ms;
///     at 1fps it's ~3s.
///   - Display value refreshes every 250ms regardless.
///   - Tap to hide.
struct FPSOverlay: View {
    /// Compact = landscape side-bar variant: FPS + pacing pill stacked
    /// vertically, no present counter (fits a ~120pt pillarbox bar).
    var compact: Bool = false
    @State private var presentCount: UInt64 = 0
    @State private var fps: Double = 0
    @State private var visible: Bool = true
    @State private var timer: Timer? = nil
    @State private var displayTimer: Timer? = nil
    /// Mirrors DXMT's g_madeira_vsync_mode (read per present, live-safe).
    /// 1 = locked 60, 0 = display max (120 ProMotion), 2 = raw (frame-skip
    /// mailbox — game unthrottled, panel shows ≤ display rate), 3 = locked 30
    /// (added 2026-09-15, same afterMinimumDuration mechanism as 60 — see
    /// winemetal_unix.c's _MTLCommandBuffer_presentDrawable), 4 = locked 40
    /// (willfaust/dxmt#14; offered on 120Hz panels only).
    @State private var vsyncMode: Int32 = 1
    /// Ring buffer of (timestamp, count) pairs, 100ms cadence, 5s window.
    @State private var samples: [(t: CFAbsoluteTime, c: UInt64)] = []
    private let bufferCapacity = 50  // 5s @ 100ms
    /// ml606: live phys_footprint in MB, refreshed on the 250ms display tick.
    @State private var memMB: Int = 0
    @State private var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    /// iOS jetsams this app at EXACTLY 4096MB of phys_footprint (memory:
    /// "Jetsam = EXACTLY 4096MB"). task_info(TASK_VM_INFO) reports the very
    /// same counter the kernel judges us on, so this is the real number and
    /// not an approximation from resident size.
    private static let jetsamLimitMB = 4096

    private func readFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    /// Headroom-based, because the absolute number means nothing without the
    /// ceiling: green >768MB free, yellow >384MB, orange >128MB, red below.
    private var memColor: Color {
        let free = Self.jetsamLimitMB - memMB
        if memMB == 0 { return .secondary }
        if free > 768 { return .green }
        if free > 384 { return .yellow }
        if free > 128 { return .orange }
        return .red
    }

    var body: some View {
        Group {
            if visible && compact {
                VStack(spacing: 4) {
                    Text(String(format: "%.1f", fps))
                        .foregroundColor(fpsColor)
                    pacingPill
                    capturePill
                    ecoPill
                    fencePill
                    thermalPill
                }
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .background(Color.black.opacity(0.55))
                .cornerRadius(6)
            } else if visible {
                HStack(spacing: 8) {
                    // ml606: live phys_footprint — the SAME number jetsam kills on.
                    // ml605 died at 4080MB against a 4096MB limit with no warning
                    // of any kind in the log, so having it on screen turns "it
                    // vanished" into "we watched it climb".
                    Text("\(memMB)MB")
                        .foregroundColor(memColor)
                        .frame(width: 56, alignment: .trailing)
                    Text("|")
                        .foregroundColor(.secondary)
                    Text("Present:")
                        .foregroundColor(.secondary)
                    Text("\(presentCount)")
                        .foregroundColor(.primary)
                    Text("|")
                        .foregroundColor(.secondary)
                    Text("FPS:")
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f", fps))
                        .foregroundColor(fpsColor)
                        .frame(width: 40, alignment: .trailing)
                    pacingPill
                    capturePill
                    ecoPill
                    fencePill
                    thermalPill
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55))
                .cornerRadius(6)
            } else {
                Circle()
                    .fill(Color.black.opacity(0.3))
                    .frame(width: 12, height: 12)
            }
        }
        .onTapGesture { visible.toggle() }
        .onAppear { startTimers() }
        .onDisappear { stopTimers() }
    }

    /// Pacing pill, cycles 60 → MAX(n) → RAW → 30 → 40 → 60. Shared by the wide
    /// (portrait) and compact (landscape bar) overlay variants.
    ///   60: presents paced to exactly 60Hz.
    ///   MAX(n): free-run to display refresh; n = current cap
    ///     (120 = ProMotion; 60 = thermal/LPM capped).
    ///   RAW: game unthrottled (frame-skip mailbox) — FPS readout =
    ///     raw stack throughput.
    ///   30: presents paced to exactly 30Hz — device feedback (2026-09-15)
    ///     asked for a cap below 60 (thermal/battery headroom); appended
    ///     rather than reordering the existing three so a saved/expected
    ///     cycle position never silently changes meaning. Offered only when
    ///     DXMT has the 30 cap (ProMotionIntent.has30Cap); else RAW → 60.
    ///   40: presents paced to 40Hz on a 120Hz panel, offered only when DXMT
    ///     has the 40 cap (ProMotionIntent.has40Cap).
    private var pacingPill: some View {
        Text(pillLabel)
            .foregroundColor(pillColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(pillColor, lineWidth: 1))
            .onTapGesture {
                vsyncMode = Self.nextVsyncMode(vsyncMode)
                fputs("[hud] tap fps-cap -> \(pillLabel(for: vsyncMode))\n", stderr)
                ThermalPacing.shared.userChose()
                madeira_set_vsync_locked(vsyncMode)
                ProMotionIntent.apply(mode: vsyncMode)
            }
    }

    private static func nextVsyncMode(_ mode: Int32) -> Int32 {
        switch mode {
        case 1: return 0    // 60 -> MAX
        case 0: return 2    // MAX -> RAW
        case 2: return ProMotionIntent.has30Cap ? 3 : ProMotionIntent.has40Cap ? 4 : 1   // RAW -> 30, 40 or 60
        case 3: return ProMotionIntent.has40Cap ? 4 : 1   // 30 -> 40 (when offered) or 60
        default: return 1   // 40 -> 60
        }
    }

    /// ml1098: one tap = capture the next frame (every render pass's attachments
    /// to Documents/capture/, plus the full draw-dump in the log). The pill
    /// flashes for a second so a tap is visibly taken.
    @State private var captureFlash = false
    private var capturePill: some View {
        Text("CAP")
            .foregroundColor(captureFlash ? .black : .cyan)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(captureFlash ? Color.cyan : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.cyan, lineWidth: 1))
            .onTapGesture {
                madeira_capture_request(1)
                captureFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { captureFlash = false }
            }
    }

    /// ml1133: ECO. The SoC clamps the CPU clock once ~250 J of CPU energy has
    /// been spent above ~2.3 W, and a loading screen at full clock spends nearly
    /// all of it before gameplay starts. ECO on = guest threads run at a low QoS
    /// class (efficiency cores, lower clocks): loading is slower but keeps the
    /// budget for gameplay. Turn it off once in game. Green = on.
    @State private var ecoOn = madeira_get_eco() != 0
    private var ecoPill: some View {
        Text("ECO")
            .foregroundColor(ecoOn ? .black : .green)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(ecoOn ? Color.green : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.green, lineWidth: 1))
            .onTapGesture {
                ecoOn.toggle()
                madeira_set_eco(ecoOn ? 1 : 0)
            }
    }

    /// ml1136: GPU encoder-sync mode, switchable live for in-place A/B tests.
    /// F1 = every encoder waits for the one before (accurate, default),
    /// F6 = barrier-driven, F5 = render passes wait at the fragment stage,
    /// F0 = no fences at all (diagnostic ceiling; expect flicker).
    // ml1137: the overlay view is recreated on layout changes, which reset a plain
    // @State to the config value (ph-rdr93: taps re-requested F6 three times).
    // The mode lives in a static so it survives, and @State mirrors it for redraws.
    @State private var fenceMode: Int = FPSOverlayFenceMode.current
    private var fencePill: some View {
        let color: Color = fenceMode == 1 ? .white : fenceMode == 6 ? .purple : fenceMode == 5 ? .blue : .red
        return Text("F\(fenceMode)")
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 1))
            .onTapGesture {
                fenceMode = FPSOverlayFenceMode.current
                fenceMode = fenceMode == 1 ? 6 : fenceMode == 6 ? 5 : fenceMode == 5 ? 0 : 1
                FPSOverlayFenceMode.current = fenceMode
                madeira_set_fence_mode(Int32(fenceMode == 0 ? 7 : fenceMode))
            }
    }

    @ViewBuilder
    private var thermalPill: some View {
        if thermalState == .serious || thermalState == .critical {
            let isCritical = thermalState == .critical
            Text(isCritical ? "CRIT" : "HOT")
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(isCritical ? Color.red : Color.orange)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(isCritical ? Color.red : Color.orange, lineWidth: 1))
        }
    }

    private func pillLabel(for mode: Int32) -> String {
        switch mode {
        case 1: return "60"
        case 3: return "30"
        case 4: return "40"
        case 0: return "MAX(\(UIScreen.main.maximumFramesPerSecond))"
        default: return "RAW"
        }
    }

    private var pillLabel: String { pillLabel(for: vsyncMode) }

    private var pillColor: Color {
        switch vsyncMode {
        case 1: return .cyan
        case 3, 4: return .indigo
        case 0: return .pink
        default: return .orange
        }
    }

    private var fpsColor: Color {
        if fps >= 50 { return .green }
        if fps >= 30 { return .yellow }
        if fps >= 1  { return .orange }
        if fps > 0   { return Color(red: 1.0, green: 0.4, blue: 0.2) }
        return .secondary
    }

    private func startTimers() {
        stopTimers()
        let now = CFAbsoluteTimeGetCurrent()
        let c = madeira_shown_frame_count()
        samples = [(now, c)]
        presentCount = c
        vsyncMode = madeira_get_vsync_locked()
        ProMotionIntent.apply(mode: vsyncMode)

        // 100ms sampling — keeps the buffer fresh
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            let t = CFAbsoluteTimeGetCurrent()
            let cur = madeira_shown_frame_count()
            samples.append((t, cur))
            if samples.count > bufferCapacity { samples.removeFirst() }
            presentCount = cur
        }

        // 250ms display refresh — computes adaptive-window FPS
        memMB = readFootprintMB()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            fps = computeAdaptiveFPS()
            // ml606: piggybacks on the existing tick, so it costs one extra
            // task_info per 250ms and no additional SwiftUI invalidation.
            memMB = readFootprintMB()
            thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    private func stopTimers() {
        timer?.invalidate()
        timer = nil
        displayTimer?.invalidate()
        displayTimer = nil
    }

    /// Compute FPS over an adaptive window: starting from the newest sample,
    /// walk backwards until the window holds ≥3 presents AND spans ≥1s (or we
    /// hit buffer start). The 1s minimum matters: with 100ms sampling, a
    /// short window quantizes the readout to presents/0.2s = multiples of
    /// 5.0 — at a true ~19 FPS it displayed a rock-steady "20.0" (4 presents
    /// per 0.2s) with "dips" to 15.0, which read as an artificial frame lock
    /// (2026-07-04, cost a day of pacing-hunt confusion). ≥1s gives 1-FPS
    /// resolution; still responsive for a debug readout.
    private func computeAdaptiveFPS() -> Double {
        guard samples.count >= 2 else { return 0 }
        let latest = samples.last!
        // Walk backwards
        var oldest = samples[0]
        for i in (0..<samples.count).reversed() {
            let candidate = samples[i]
            let delta = latest.c &- candidate.c
            let span = latest.t - candidate.t
            if delta >= 3 && span >= 1.0 {
                oldest = candidate
                break
            }
            oldest = candidate
        }
        let dt = latest.t - oldest.t
        let dc = latest.c &- oldest.c
        guard dt > 0.0001 else { return 0 }
        return Double(dc) / dt
    }
}

/// ml1137: process-wide fence-mode display state for the overlay pill.
enum FPSOverlayFenceMode {
    static var current: Int = Int(MadeiraConfig.gameValue("fence-chain") ?? MadeiraConfig.get("fence-chain") ?? "1") ?? 1
}
