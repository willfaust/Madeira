import Foundation

/// One selectable desktop resolution.
///
/// `width == 0` is the sentinel for "leave the engine's own default alone".
/// Every desktop the app hardcodes (1024x768 for the Steam shell, 960x540 for
/// services) predates every non-A15 device and is load-bearing for window
/// fitting, so the shipped default must remain reachable from a settings screen
/// that otherwise only offers explicit sizes.
struct ResolutionPreset: Identifiable, Equatable {
    let width: Int
    let height: Int

    static let automatic = ResolutionPreset(width: 0, height: 0)

    var id: String { "\(width)x\(height)" }

    var label: String {
        width == 0 ? "Automatic" : "\(width) × \(height)"
    }

    /// The short edge ratio, for a subtitle. Only used for display.
    var aspect: String? {
        guard width > 0, height > 0 else { return nil }
        let pairs: [(Double, String)] = [
            (16.0 / 9.0, "16:9"), (16.0 / 10.0, "16:10"), (4.0 / 3.0, "4:3"),
        ]
        let ratio = Double(width) / Double(height)
        return pairs.first(where: { abs($0.0 - ratio) < 0.02 })?.1
    }
}

/// Bounds on what a user may ask for. Both the presets and the custom fields
/// go through `clamped`, so a stray value cannot request a frame buffer the
/// guest will reject or a pool that would move the VA floor.
enum ResolutionPolicy {
    static let minDimension = 320
    static let maxDimension = 4096

    static let presets: [ResolutionPreset] = [
        .automatic,
        ResolutionPreset(width: 960, height: 540),
        ResolutionPreset(width: 1024, height: 768),
        ResolutionPreset(width: 1280, height: 720),
        ResolutionPreset(width: 1280, height: 800),
        ResolutionPreset(width: 1600, height: 900),
        ResolutionPreset(width: 1920, height: 1080),
    ]

    /// Both dimensions in range, or nil. A zero pair (`automatic`) is nil too:
    /// the result means "an explicit size to write", and the absence of one is
    /// what `overrideFiles` turns into a removed file.
    static func clamped(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width >= minDimension, width <= maxDimension,
              height >= minDimension, height <= maxDimension else { return nil }
        return (width, height)
    }
}

/// The render pacing the engine is asked to hold.
///
/// These values are the ones `madeira_set_vsync_locked()` already takes; the
/// FPS overlay cycles through the same three.
enum FrameRateMode: Int, CaseIterable, Identifiable, Codable, Hashable {
    /// Free-run to the display refresh. 120 on a ProMotion panel.
    case maximum = 0
    /// Paced to exactly 60Hz.
    case sixty = 1
    /// Unthrottled frame-skip mailbox: the readout is raw throughput.
    case unthrottled = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .maximum: return "Maximum"
        case .sixty: return "60 fps"
        case .unthrottled: return "Unlimited"
        }
    }

    var detail: String {
        switch self {
        case .maximum: return "Follows the display; 120Hz on ProMotion"
        case .sixty: return "Locked to 60Hz for a steady frame time"
        case .unthrottled: return "No pacing — highest throughput, most heat"
        }
    }
}

/// A one-tap bundle of the levers that trade image sharpness and diagnostic
/// output for frame time.
///
/// A profile owns exactly four fields and nothing else, and the picker is
/// *derived* from those fields (`MadeiraSettings.matchingProfile`) rather than
/// stored next to them. That is the whole design: there is no second copy of
/// the truth to go stale, applying a profile is just writing the fields, and
/// editing any one of them makes the picker fall back to Custom on its own.
/// A stored profile plus four fields would need a resolution rule for every
/// disagreement between them, and the rule would be wrong for somebody.
struct PerformancePreset: Equatable {
    var width: Int
    var height: Int
    var clampCompressedMips: Bool
    var x87FastMath: Bool
    var disableWineLogging: Bool

    /// The engine's own defaults with no override written: the device's
    /// automatic desktop size, no renderer switch, no translator switch, Wine's
    /// normal logging. Deliberately equal to `MadeiraSettings()` so a user who
    /// has never opened this screen reads as Balanced rather than Custom.
    static let balanced = PerformancePreset(width: 0, height: 0,
                                            clampCompressedMips: false,
                                            x87FastMath: false,
                                            disableWineLogging: false)

    /// 960x540 is 34% fewer pixels than the shipped 1024x768 desktop, and this
    /// is the one cost that does not improve with a newer chip — pixel work was
    /// identical on every device because the size was hardcoded (ml787). Clamped
    /// compressed mips bound the expanded BC textures this GPU cannot sample.
    /// Wine logging goes to `-all`: the launch path already cut it to `err+all`,
    /// but every `ERR` still formats a string and writes it, and on this stack
    /// page commit and SEH are hot paths.
    static let performance = PerformancePreset(width: 960, height: 540,
                                               clampCompressedMips: true,
                                               x87FastMath: false,
                                               disableWineLogging: true)

    /// Sharper than the shipped default, with nothing else changed.
    static let quality = PerformancePreset(width: 1280, height: 720,
                                           clampCompressedMips: false,
                                           x87FastMath: false,
                                           disableWineLogging: false)
}

enum PerformanceProfile: String, CaseIterable, Identifiable, Hashable {
    case balanced
    case performance
    case quality

    var id: String { rawValue }

    var preset: PerformancePreset {
        switch self {
        case .balanced: return .balanced
        case .performance: return .performance
        case .quality: return .quality
        }
    }

    var label: String {
        switch self {
        case .balanced: return "Balanced"
        case .performance: return "Performance"
        case .quality: return "Quality"
        }
    }

    var detail: String {
        switch self {
        case .balanced:
            return "The engine's own defaults: its automatic desktop size and no "
                + "renderer or translator overrides."
        case .performance:
            return "A 960×540 desktop — 34% fewer pixels than the 1024×768 default — "
                + "clamped compressed mips, and Wine's error logging off. The largest "
                + "frame-time win of the three; the engine upscales the smaller "
                + "surface to the panel, so it costs sharpness."
        case .quality:
            return "A 1280×720 desktop and no other overrides. Sharper, and the "
                + "slowest of the three."
        }
    }
}

/// A switch the engine already exposes through a `madeira-*.txt` file.
///
/// The settings screen writes the same files the launch sequence reads, so the
/// engine keeps one source of truth and every switch stays A/B-able from the
/// Files app as well. `on` is the body the file carries when enabled; a switch
/// that is off has its file removed, which is how the engine's own default is
/// restored.
struct EngineSwitch: Identifiable, Equatable {
    enum Group: String, CaseIterable, Identifiable {
        case graphics = "Graphics"
        case performance = "Performance"
        case compatibility = "Compatibility"
        case diagnostics = "Diagnostics"
        var id: String { rawValue }
    }

    let id: String          // the file stem, e.g. "madeira-usd-time"
    let title: String
    let detail: String
    let group: Group
    let on: String
    /// True when the engine's own comments say the switch is not proven, so the
    /// UI can say so instead of implying it is a supported setting.
    let experimental: Bool

    var fileName: String { id + ".txt" }
}

enum EngineSwitches {
    /// The switches that are safe and useful to offer. Deliberately not every
    /// `madeira-*.txt` the engine reads: the probes (wxprobe, shadow,
    /// apicensus) exist to answer one question each and a user toggling them
    /// only burns a run.
    static let all: [EngineSwitch] = [
        EngineSwitch(
            id: "madeira-usd-time",
            title: "Advance the guest clock",
            detail: "Keeps Windows time moving. Managed games pace every transition "
                + "off this clock, and with it frozen they wait forever while the "
                + "renderer keeps drawing.",
            group: .compatibility, on: "1", experimental: false),
        EngineSwitch(
            id: "madeira-wx",
            title: "W^X page demotion",
            detail: "Drops write permission from pages that have finished being "
                + "patched. Set to 0 to A/B a title that faults while patching.",
            group: .compatibility, on: "1", experimental: false),
        EngineSwitch(
            id: "madeira-ctx-frame",
            title: "Syscall-frame thread context",
            detail: "Reports a thread parked in a syscall using its saved Wine frame "
                + "instead of the registers it happens to be running.",
            group: .compatibility, on: "1", experimental: false),
        EngineSwitch(
            id: "madeira-mono-bridge",
            title: "Mono code-patching bridge",
            detail: "Arms FEX's XCHG patch optimisation for wine-mono.",
            group: .compatibility, on: "1", experimental: true),
        EngineSwitch(
            id: "madeira-real-suspend",
            title: "Real thread suspension",
            detail: "A Wine suspend actually stops the Mach thread. Can deadlock: the "
                + "suspended thread shares this process's allocator.",
            group: .performance, on: "1", experimental: true),
        EngineSwitch(
            id: "madeira-fex-arena",
            title: "Reserve the FEX host arena",
            detail: "Makes Wine reserve FEX's arena before any PE loads. Starves FEX "
                + "on hardware that picks its own band.",
            group: .performance, on: "1", experimental: true),
        EngineSwitch(
            id: "madeira-tf-trace",
            title: "Theorafile call tracer",
            detail: "Routes libtheorafile's exports through wrappers that report "
                + "return values. Costs frame time.",
            group: .diagnostics, on: "1", experimental: false),
        EngineSwitch(
            id: "madeira-census",
            title: "Render command census",
            detail: "Counts which wmtcmd_* types a workload emits and how large "
                + "their sidecar data gets.",
            group: .diagnostics, on: "1", experimental: false),
    ]
}

/// How far the renderer is allowed to upscale before the picture reaches the
/// panel.
///
/// This is the one renderer knob that is about spending the *GPU* rather than
/// saving the CPU. DXMT renders the title at the desktop size and, with this on,
/// runs MetalFX spatial upscaling over the result, so `960x540` can be presented
/// at `1920x1080`. The pixels the title shades stay at 960x540 — that is the
/// saving — while the upscale pass is cheap next to shading another 1.5 million
/// of them, and far sharper than the compositor's own bilinear stretch to the
/// panel. It is a trade, not free speed: the upscale pass costs real GPU time,
/// so it belongs with a smaller desktop rather than on top of a large one.
///
/// Only Apple GPUs that implement MetalFX spatial scaling (A14 and later, all
/// M-series) can do it. DXMT checks that itself and falls back to a plain
/// present on anything older, so this is safe to leave on everywhere.
enum MetalFXUpscale: Int, CaseIterable, Identifiable, Codable, Hashable {
    case off = 0
    case x1_33 = 1
    case x1_5 = 2
    case x2 = 3

    var id: Int { rawValue }

    /// The value written as `d3d11.metalSpatialUpscaleFactor`. DXMT clamps it
    /// with `max(factor, 1.0)`, so 1.0 is exactly the behaviour of `off`.
    var factor: Double {
        switch self {
        case .off: return 1.0
        case .x1_33: return 1.33
        case .x1_5: return 1.5
        case .x2: return 2.0
        }
    }

    var label: String {
        switch self {
        case .off: return "Off"
        case .x1_33: return "1.33×"
        case .x1_5: return "1.5×"
        case .x2: return "2×"
        }
    }
}

/// How the renderer identifies the graphics adapter to the guest.
///
/// Windows games decide what they are allowed to do by asking the adapter who
/// it is. An unrecognised vendor is not a neutral answer: a title may refuse to
/// start, fall back to a software renderer, clamp its settings, or select a
/// shader path that does not exist here. DXMT reports an Apple GPU, which almost
/// nothing shipped for Windows recognises -- which is why DXMT keeps its own
/// table of identity overrides for the titles its authors support (Genshin
/// Impact, YuanShen and Zenless Zone Zero all become an "AMD Radeon Pro 5300M")
/// and why this is a *compatibility* control rather than a speed one.
///
/// Stored as a preset, not free text: `madeira-dxmt.txt` is generated from these
/// fields and rewritten whenever any setting changes, so a hand-typed number
/// would not survive the next toggle.
enum GPUIdentity: String, CaseIterable, Identifiable, Codable, Hashable {
    /// Write nothing and let DXMT report the real GPU.
    case automatic
    /// The identity DXMT substitutes for the titles named above.
    case amdRadeonPro5300M

    var id: String { rawValue }

    /// The `dxgi.` options this preset writes, in file order.
    ///
    /// The description is quoted because DXMT's parser ends an unquoted value at
    /// the first whitespace: bare, "AMD Radeon Pro 5300M" would arrive as the
    /// single word "AMD".
    var options: [(key: String, value: String)] {
        switch self {
        case .automatic:
            return []
        case .amdRadeonPro5300M:
            return [("dxgi.customDeviceDesc", "\"AMD Radeon Pro 5300M\""),
                    ("dxgi.customVendorId", "1002"),
                    ("dxgi.customDeviceId", "7340")]
        }
    }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .amdRadeonPro5300M: return "AMD Radeon Pro 5300M"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Report the real GPU. Correct for most titles; change it only "
                + "for one that refuses to start or picks the wrong settings."
        case .amdRadeonPro5300M:
            return "The identity DXMT itself uses for Genshin Impact, Zenless Zone "
                + "Zero and similar. A guess such a game accepts, not a fact about "
                + "this device."
        }
    }
}

/// Everything the settings screen can change.
///
struct MadeiraSettings: Equatable, Codable {
    var width: Int = 0
    var height: Int = 0
    /// nil means "leave the engine's own pacing alone".
    ///
    /// Deliberately optional rather than defaulting to one of the three modes:
    /// the engine picks a pacing itself at startup, and a settings screen that
    /// pushed a value on every launch would silently change the frame behaviour
    /// of a user who never opened it.
    var frameRate: FrameRateMode? = nil
    /// 0 means "derive from the device's jetsam budget".
    var poolMB: Int = 0
    /// Clamp the expanded mip chain for block-compressed textures.
    var clampCompressedMips: Bool = false
    /// MetalFX spatial upscaling of the rendered image. Off by default: it is a
    /// GPU-side trade rather than a saving, and it only pays off alongside a
    /// desktop the panel would otherwise stretch badly.
    var metalFXUpscale: MetalFXUpscale = .off
    /// The on-screen controller. Defaults to on, because it exists to replace
    /// the system keyboard and a user who has to find the switch first has not
    /// been helped.
    var virtualPad: VirtualPadMode = .automatic
    var virtualPadOpacity: Double = VirtualPadLayout.defaultOpacity
    var remoteHost: String = ""
    var remoteToken: String = ""
    var switches: Set<String> = []
    /// Emulate x87 with 64-bit doubles instead of 80-bit extended precision
    /// (FEX_X87REDUCEDPRECISION). A large win for titles compiled to use x87
    /// for their own math, which is most of the 2000s, because FEX otherwise
    /// routes every x87 operation through a software 80-bit path. Off by
    /// default, and deliberately *not* part of any profile: FEX's own
    /// description is "reduces emulation accuracy and may result in rendering
    /// bugs", so a preset must not switch it on silently. Someone who wants it
    /// can have it and will know why the picture changed.
    var x87FastMath: Bool = false
    /// Ask Wine for `WINEDEBUG=-all`. Every enabled channel formats a string and
    /// writes it, and this stack takes access-violation-driven page commits and
    /// SEH on hot paths, so `err` is not free even though it is the quiet
    /// default. The app's own logs are unaffected.
    var disableWineLogging: Bool = false

    /// Identity reported to the guest. See `GPUIdentity`.
    var gpuIdentity: GPUIdentity = .automatic
    /// `d3d11.preferredMaxFrameRate`, or zero to leave it alone.
    ///
    /// DXMT implements this as a Metal/CoreAnimation-paced limiter rather than a
    /// CPU-side sleep, so the frames it does emit are evenly spaced. That is what
    /// makes it worth offering: a title that cannot hold 60 does not become
    /// smoother by being allowed to run at an uneven 40-55, and a cap below what
    /// the device can hold trades unused frames for a frame time that stops
    /// moving. Deliberately off by default -- the game's own vsync is the right
    /// answer until it demonstrably is not.
    var frameRateLimit: Int = 0
    /// `d3d11.ignoreMapFlagNoWait`. A title that passes
    /// `D3D11_MAP_FLAG_DO_NOT_WAIT` and then fails to handle the
    /// `DXGI_ERROR_WAS_STILL_DRAWING` it is allowed to return will stall or read
    /// a resource that is not there. Ignoring the flag makes those calls block
    /// and return real data instead. DXMT's own table switches this on for one
    /// such title; it is off here because blocking can add a stall to a title
    /// that does handle the flag correctly.
    var ignoreMapFlagNoWait: Bool = false
    /// `dxgi.forceSDR`. Reports an SDR display regardless of the panel.
    /// DXMT's own table turns this on for a title that misbehaves in HDR mode.
    var forceSDR: Bool = false

    /// A fresh decode with every field defaulted.
    ///
    /// Declared explicitly because providing `init(from:)` below suppresses the
    /// synthesized default initializer, which the rest of the app and the
    /// off-device tests both use.
    init() {}

    private enum CodingKeys: String, CodingKey {
        case width, height, frameRate, poolMB, clampCompressedMips
        case virtualPad, virtualPadOpacity, remoteHost, remoteToken, switches
        case x87FastMath, disableWineLogging, metalFXUpscale
        case gpuIdentity, frameRateLimit, ignoreMapFlagNoWait, forceSDR
    }

    /// Decode with every field defaulted.
    ///
    /// The synthesized decoder demands every key, so the first time a field was
    /// added here, a settings blob written by the previous build failed to
    /// decode — and `SettingsStore` treats a decode failure as "no saved
    /// settings", silently resetting the user's choices. `decodeIfPresent` makes
    /// adding a field a compatible change instead.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        frameRate = try c.decodeIfPresent(FrameRateMode.self, forKey: .frameRate)
        poolMB = try c.decodeIfPresent(Int.self, forKey: .poolMB) ?? 0
        clampCompressedMips = try c.decodeIfPresent(Bool.self, forKey: .clampCompressedMips) ?? false
        virtualPad = try c.decodeIfPresent(VirtualPadMode.self, forKey: .virtualPad) ?? .automatic
        virtualPadOpacity = try c.decodeIfPresent(Double.self, forKey: .virtualPadOpacity)
            ?? VirtualPadLayout.defaultOpacity
        remoteHost = try c.decodeIfPresent(String.self, forKey: .remoteHost) ?? ""
        remoteToken = try c.decodeIfPresent(String.self, forKey: .remoteToken) ?? ""
        switches = try c.decodeIfPresent(Set<String>.self, forKey: .switches) ?? []
        x87FastMath = try c.decodeIfPresent(Bool.self, forKey: .x87FastMath) ?? false
        disableWineLogging = try c.decodeIfPresent(Bool.self, forKey: .disableWineLogging) ?? false
        metalFXUpscale = try c.decodeIfPresent(MetalFXUpscale.self, forKey: .metalFXUpscale) ?? .off
        gpuIdentity = try c.decodeIfPresent(GPUIdentity.self, forKey: .gpuIdentity) ?? .automatic
        frameRateLimit = try c.decodeIfPresent(Int.self, forKey: .frameRateLimit) ?? 0
        ignoreMapFlagNoWait = try c.decodeIfPresent(Bool.self, forKey: .ignoreMapFlagNoWait) ?? false
        forceSDR = try c.decodeIfPresent(Bool.self, forKey: .forceSDR) ?? false
    }

    static let empty = MadeiraSettings()

    /// The four fields the performance presets own, as a value.
    var performancePreset: PerformancePreset {
        PerformancePreset(width: width, height: height,
                          clampCompressedMips: clampCompressedMips,
                          x87FastMath: x87FastMath,
                          disableWineLogging: disableWineLogging)
    }

    /// The preset these fields currently spell, or nil for a combination no
    /// preset produces. Derived, never stored — see `PerformanceProfile`.
    var matchingProfile: PerformanceProfile? {
        PerformanceProfile.allCases.first { $0.preset == performancePreset }
    }

    /// Write a preset's fields. Everything else — pacing, pool, pad, remote,
    /// advanced switches — is deliberately untouched, because a profile is a
    /// bundle of four knobs and not a configuration reset.
    mutating func apply(_ profile: PerformanceProfile) {
        let p = profile.preset
        width = p.width
        height = p.height
        clampCompressedMips = p.clampCompressedMips
        x87FastMath = p.x87FastMath
        disableWineLogging = p.disableWineLogging
    }

    /// The pool sizes a user may pick. 0 is automatic; the rest are the values
    /// the engine's comments bracket (256 is the allocation floor, 3072 the
    /// documented clamp).
    static let poolChoices: [Int] = [0, 256, 384, 512, 768, 896, 1024, 1536, 2048, 3072]

    /// Caps offered by the renderer frame-rate picker; zero means "off".
    ///
    /// These are factors of a display refresh rate (30/60/120), which is the
    /// shape DXMT asks for: its limiter is paced by Metal against the display, so
    /// a cap that is not a divisor of the refresh rate can be rounded down to one
    /// that is rather than honoured exactly.
    static let frameRateChoices: [Int] = [0, 30, 60, 120]

    static func poolClamped(_ mb: Int) -> Int {
        guard mb > 0 else { return 0 }
        return min(max(mb, 256), 3072)
    }

    /// The resolution to hand the engine, or nil for "its own default".
    var resolution: (width: Int, height: Int)? {
        ResolutionPolicy.clamped(width: width, height: height)
    }

    /// What the panel actually receives when MetalFX is on: the desktop the
    /// title renders at, multiplied by the upscale factor. Nil when there is
    /// nothing to say — no explicit desktop, or no upscaling — so the settings
    /// screen shows a real pair of numbers or none at all.
    var presentedResolution: (width: Int, height: Int)? {
        guard metalFXUpscale != .off, let rendered = resolution else { return nil }
        return (Int((Double(rendered.width) * metalFXUpscale.factor).rounded()),
                Int((Double(rendered.height) * metalFXUpscale.factor).rounded()))
    }

    /// Remote Metal is only meaningful with both halves of the credential.
    var remoteMetalConfigured: Bool {
        !remoteHost.trimmingCharacters(in: .whitespaces).isEmpty
            && !remoteToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The `madeira-*.txt` files this settings value implies. A nil body means
    /// "delete the file", which restores the engine's default for that knob.
    ///
    /// Returned as an ordered array rather than a dictionary because the order
    /// is what makes the behaviour readable in a log line.
    var overrideFiles: [(name: String, body: String?)] {
        var files: [(name: String, body: String?)] = []

        if let r = resolution {
            files.append(("madeira-resolution.txt", "\(r.width)x\(r.height)"))
        } else {
            files.append(("madeira-resolution.txt", nil))
        }

        if poolMB > 0 {
            files.append(("madeira-pool.txt", String(MadeiraSettings.poolClamped(poolMB))))
        } else {
            files.append(("madeira-pool.txt", nil))
        }

        // DXMT reads DXMT_CONFIG as inline "key=value" lines. mipClampBC is the one
        // option worth surfacing: this GPU cannot sample block-compressed textures,
        // so they are expanded at 2-8x their shipped size, and clamping the mip
        // chain is what bounds that cost. The file only exists while it is on.
        //
        // MetalFX goes through the same file, but needs a second half: DXMT gates
        // the scaler on DXMT_METALFX_SPATIAL_SWAPCHAIN and would ignore the factor
        // without it. The launch sequence derives that variable from this text
        // (DeviceCapabilities.dxmtConfigArmsMetalFX) so the two cannot drift.
        var dxmt: [String] = []
        if clampCompressedMips {
            dxmt.append("d3d11.mipClampBC=1")
        }
        if metalFXUpscale != .off {
            dxmt.append("d3d11.metalSpatialUpscaleFactor=\(metalFXUpscale.factor)")
        }
        // The compatibility levers, all of which go through this same file
        // because DXMT reads them from DXMT_CONFIG. Written last only for
        // readability -- each key appears once, so order does not decide
        // anything here.
        //
        // `GPUIdentity` returns quoted text for the description because DXMT's
        // parser ends an unquoted value at the first whitespace, and the bools
        // are spelled `True` because that parser lowercases before matching.
        for (key, value) in gpuIdentity.options {
            dxmt.append("\(key)=\(value)")
        }
        if frameRateLimit > 0 {
            dxmt.append("d3d11.preferredMaxFrameRate=\(frameRateLimit)")
        }
        if ignoreMapFlagNoWait {
            dxmt.append("d3d11.ignoreMapFlagNoWait=True")
        }
        if forceSDR {
            dxmt.append("dxgi.forceSDR=True")
        }
        files.append(("madeira-dxmt.txt", dxmt.isEmpty ? nil : dxmt.joined(separator: "\n")))

        // FEX reads this file as `KEY=VALUE` lines (uppercase key; see
        // FEXSettings in DeviceCapabilities, which validates the same shape).
        var fex: [String] = []
        if x87FastMath {
            fex.append("X87REDUCEDPRECISION=1")
        }
        files.append(("madeira-fex.txt", fex.isEmpty ? nil : fex.joined(separator: "\n")))

        // Wine logging. `-all` is the documented way to switch every channel
        // off; WineProcessBridge writes it into WINEDEBUG at launch.
        files.append(("madeira-winlog.txt", disableWineLogging ? "-all" : nil))

        if remoteMetalConfigured {
            let host = remoteHost.trimmingCharacters(in: .whitespaces)
            let token = remoteToken.trimmingCharacters(in: .whitespaces)
            files.append(("madeira-remote.txt", "\(host) \(token)"))
        } else {
            files.append(("madeira-remote.txt", nil))
        }

        for sw in EngineSwitches.all {
            files.append((sw.fileName, switches.contains(sw.id) ? sw.on : nil))
        }

        return files
    }
}
