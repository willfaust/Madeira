import SwiftUI
import UIKit
import QuartzCore

/// Keeps the ProMotion panel promoted to 120Hz while MAX mode is on.
/// CAMetalLayer presents alone don't express frame-rate intent — iOS
/// parks the display at 60Hz and only promotes on touch (observed
/// 2026-07-05: MAX mode ran 60 except ~119 bursts while touching). An
/// active CADisplayLink with preferredFrameRateRange(120) is the
/// documented way for present-driven Metal apps to hold the panel at
/// 120. The tick itself does nothing.
final class ProMotionIntent {
    static let shared = ProMotionIntent()
    private var link: CADisplayLink?

    func setActive(_ active: Bool) {
        if active {
            guard link == nil else { return }
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            link?.invalidate()
            link = nil
        }
    }

    @objc private func tick(_ sender: CADisplayLink) {}
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
    /// mailbox — game unthrottled, panel shows ≤ display rate).
    @State private var vsyncMode: Int32 = 1
    /// Ring buffer of (timestamp, count) pairs, 100ms cadence, 5s window.
    @State private var samples: [(t: CFAbsoluteTime, c: UInt64)] = []
    private let bufferCapacity = 50  // 5s @ 100ms
    /// ml606: live phys_footprint in MB, refreshed on the 250ms display tick.
    @State private var memMB: Int = 0
    /// ml803: whole-task CPU, as a percentage of one core (so 320% means 3.2
    /// cores busy). Every Windows "process" on this stack is a thread of this
    /// one Mach task, so this is the emulator's total — translator, Wine, DXMT
    /// and CEF together — and it is the number that says whether a title is
    /// CPU-bound or waiting on the GPU. Measured as a delta over the same
    /// 250ms window the footprint uses.
    @State private var cpuPercent: Double = 0
    @State private var lastCPUSeconds: Double? = nil
    @State private var lastCPUWall: CFAbsoluteTime = 0

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

    /// ml803: user+system CPU seconds for the whole Mach task, or nil when the
    /// kernel refuses the query (it does not, on iOS, but a silent zero would
    /// read as "idle" and that is the one lie this readout must not tell).
    private static func processCPUSeconds() -> Double? {
        var info = task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
    }

    /// CPU as a fraction of every core this device has, which is what decides
    /// the colour: at a true frame-rate ceiling one core is rarely the whole
    /// story on a phone, and 300% is healthy on a six-core part.
    private var cpuCores: Double {
        Double(max(ProcessInfo.processInfo.processorCount, 1))
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
                    if cpuPercent > 0 {
                        Text(String(format: "%.0f%%", cpuPercent))
                            .foregroundColor(cpuColor)
                    }
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
                    // ml803: CPU is the other half of the frame budget, and the
                    // only way to tell "the GPU is the wall" from "the translator
                    // is the wall" without a Mac attached.
                    Text("CPU:")
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f%%", cpuPercent))
                        .foregroundColor(cpuColor)
                        .frame(width: 48, alignment: .trailing)
                    Text("|")
                        .foregroundColor(.secondary)
                    Text("FPS:")
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f", fps))
                        .foregroundColor(fpsColor)
                        .frame(width: 40, alignment: .trailing)
                    pacingPill
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

    /// Pacing pill, cycles 60 → MAX(n) → RAW → 60. Shared by the wide
    /// (portrait) and compact (landscape bar) overlay variants.
    ///   60: presents paced to exactly 60Hz.
    ///   MAX(n): free-run to display refresh; n = current cap
    ///     (120 = ProMotion; 60 = thermal/LPM capped).
    ///   RAW: game unthrottled (frame-skip mailbox) — FPS readout =
    ///     raw stack throughput.
    private var pacingPill: some View {
        Text(pillLabel)
            .foregroundColor(pillColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(pillColor, lineWidth: 1))
            .onTapGesture {
                vsyncMode = vsyncMode == 1 ? 0 : (vsyncMode == 0 ? 2 : 1)
                madeira_set_vsync_locked(vsyncMode)
                ProMotionIntent.shared.setActive(vsyncMode != 1)
            }
    }

    private var pillLabel: String {
        switch vsyncMode {
        case 1: return "60"
        case 0: return "MAX(\(UIScreen.main.maximumFramesPerSecond))"
        default: return "RAW"
        }
    }

    private var pillColor: Color {
        switch vsyncMode {
        case 1: return .cyan
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

    /// Saturation of the whole task against the device's core count. Red is not
    /// "a problem" by itself — a heavy title can sit at 4 cores of 6 and still
    /// hold 60fps — but red with a low FPS is the signature of a CPU-bound
    /// frame, which is the case no renderer setting can fix.
    private var cpuColor: Color {
        let load = cpuPercent / (cpuCores * 100)
        if load < 0.5 { return .green }
        if load < 0.75 { return .yellow }
        if load < 0.9 { return .orange }
        return .red
    }

    private func startTimers() {
        stopTimers()
        let now = CFAbsoluteTimeGetCurrent()
        let c = madeira_get_present_count()
        samples = [(now, c)]
        presentCount = c
        vsyncMode = madeira_get_vsync_locked()
        ProMotionIntent.shared.setActive(vsyncMode != 1)

        // 100ms sampling — keeps the buffer fresh
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            let t = CFAbsoluteTimeGetCurrent()
            let cur = madeira_get_present_count()
            samples.append((t, cur))
            if samples.count > bufferCapacity { samples.removeFirst() }
            presentCount = cur
        }

        // 250ms display refresh — computes adaptive-window FPS
        memMB = readFootprintMB()
        lastCPUSeconds = Self.processCPUSeconds()
        lastCPUWall = CFAbsoluteTimeGetCurrent()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            fps = computeAdaptiveFPS()
            // ml606: piggybacks on the existing tick, so it costs one extra
            // task_info per 250ms and no additional SwiftUI invalidation.
            memMB = readFootprintMB()
            // ml803: same tick, same bargain. A delta over a known window is
            // the only CPU number that means anything; the raw counter is
            // monotonic since launch.
            let now = CFAbsoluteTimeGetCurrent()
            if let cpu = Self.processCPUSeconds() {
                if let last = lastCPUSeconds, now - lastCPUWall > 0.05 {
                    cpuPercent = max(0, (cpu - last) / (now - lastCPUWall) * 100)
                }
                lastCPUSeconds = cpu
                lastCPUWall = now
            }
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
