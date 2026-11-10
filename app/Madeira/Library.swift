import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Darwin
import ImageIO
import Combine
import Metal

/// A text that is built in code (a note, a picker title, a status or an error) in the
/// device's language, from Localizable.xcstrings; English when the catalog lacks it.
/// Texts written straight into Text("...")/Button("...") are looked up by SwiftUI already.
func L(_ text: String) -> String {
    Bundle.main.localizedString(forKey: text, value: text, table: "Localizable")
}

// ============================================================================
// Library front end.
//
// A game library in front of the existing launch path: entries are Windows
// executables inside the prefix's drive_c, each with its own launch profile
// (arguments, resolution and scaling, frame limit, x87 precision, on-screen
// controls). Play starts the same runWineFullSequence the developer interface
// uses; the session runs full screen with a small in-game menu.
//
// The developer interface stays available: Settings › Interface switches back
// to it (FrontendChoice), and it has a "Use New Interface" button to return.
// Every switch below is read with MadeiraConfig.flag, so `env.NAME = 0` in
// madeira.cfg turns it off.
// ============================================================================

/// Thermal state, Low Power Mode, screen capture, battery and brightness every
/// 10 s while a session runs: the device conditions that explain a slow run in
/// a log (447: the CPU was held at 1.31/1.70 GHz from the start of play with
/// thermal=nominal; charging and screen recording also draw from the power
/// budget). MADEIRA_DEVICE_STATS=0 turns the line off.
enum DeviceLoadDiagnostics {
    private static var lastReport = 0.0
    private static var timer: Timer?
    /// Opt-in (env.MADEIRA_DEVICE_STATS = 1): a line every 10 s during every
    /// session is a diagnostic, so it is off by default.
    static func start() {
        guard timer == nil, MadeiraConfig.flag("MADEIRA_DEVICE_STATS", fallback: false) else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let value = Timer(timeInterval: 10, repeats: true) { _ in report() }
        timer = value
        RunLoop.main.add(value, forMode: .common)
    }
    static func report() {
        guard wine_process_is_running() != 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastReport >= 10 else { return }
        lastReport = now
        let process = ProcessInfo.processInfo
        let thermal = thermalName(process.thermalState)
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }   // the HUD turns it off when it closes
        let level = device.batteryLevel < 0 ? "?" : String(Int((device.batteryLevel * 100).rounded()))
        let battery: String
        switch device.batteryState {
        case .charging: battery = "charging"
        case .full: battery = "full"
        case .unplugged: battery = "unplugged"
        default: battery = "unknown"
        }
        fputs("[device-load] thermal=\(thermal) low-power=\(process.isLowPowerModeEnabled ? 1 : 0) capture=\(UIScreen.main.isCaptured ? 1 : 0) "
              + "battery=\(level)% \(battery) brightness=\(String(format: "%.2f", UIScreen.main.brightness))\n", stderr)
    }
    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// (compat-report) The report format pinned in the Madeira Discord's #game-compatibility forum
/// (Device, iOS version, Madeira version, DRM (yes/no), Results), filled in for one game.
/// Results stays empty for the player. The text is English on purpose: the server is English only.
enum CompatReport {
    /// The Copy Compat Report button on a game's Advanced page (copies the Discord report format). 0 hides it.
    static let enabled = MadeiraConfig.flag("MADEIRA_COMPAT_REPORT")

    /// The model identifier (iPad16,9, iPhone17,1), the same one the logs show.
    static var device: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    /// "Yes (Steam)" for a store with DRM, "No (GOG)" for a DRM-free one, "" when Madeira can't tell.
    static func drm(_ entry: LibraryEntry) -> String {
        if entry.steamAppID != nil { return "Yes (Steam)" }
        if entry.epicAppName != nil { return "Yes (Epic Games)" }
        if entry.eaOfferID != nil { return "Yes (EA app)" }
        if entry.gogProductID != nil { return "No (GOG)" }
        if entry.itchGameID != nil { return "No (itch.io)" }
        return ""
    }

    static func text(for entry: LibraryEntry) -> String {
        format(title: entry.title, device: device,
               system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
               build: BuildStamp.text, drm: drm(entry))
    }

    static func format(title: String, device: String, system: String, build: String, drm: String) -> String {
        """
        \(title)
        - Device: \(device)
        - iOS version: \(system)
        - Madeira version: \(build)
        - DRM (yes/no): \(drm)
        - Results:
        """
    }
}

/// Which build is installed, shown in light grey in the developer interface, and
/// logged once at start ([build]). A build that
/// writes `MadeiraBuild` into Info.plist (a round tag and build time) shows that;
/// other builds show the bundle version. MADEIRA_BUILD_LABEL=0 hides the label
/// (the log line stays).
enum BuildStamp {
    static let text: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        if let stamp = info["MadeiraBuild"] as? String, !stamp.isEmpty { return stamp }
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }()
    static let visible = MadeiraConfig.flag("MADEIRA_BUILD_LABEL")
}

/// Controller navigation of the library, fed by GamepadInput's sampler (player
/// 1's physical pad) so there is no second timer. While the library owns input
/// (no session, or the in-game menu is open) GamepadInput publishes a neutral
/// pad to Windows. D-pad or left stick moves the focus, A opens, B goes back,
/// Y adds a game, a shoulder switches tabs, X plays (the new look's highlight,
/// PadHighlight.swift); in a session Back+Start opens the menu. A held direction
/// repeats (0.35 s, then every 0.1 s); the triggers page up and down and View
/// is search. MADEIRA_FRONTEND_CONTROLLER=0 turns navigation off.
final class LibraryController: ObservableObject, @unchecked Sendable {
    static let shared = LibraryController()
    @Published var connected = false
    let commands = PassthroughSubject<String, Never>()
    private let lock = NSLock()
    private var enabled = false
    private var owns = false
    private var last: UInt32 = 0
    private var announced = false
    /// Controllers already named in the log ("[menu-pad] connected <name>").
    private var named = Set<String>()
    /// The held direction and when it next repeats.
    private var heldDirection: UInt32 = 0
    /// The directions the left stick is pushed in now (with its in/out gap).
    private var stick: UInt32 = 0
    private var repeatAt = Date.distantFuture
    private let allowed = MadeiraConfig.flag("MADEIRA_FRONTEND_CONTROLLER")
    var ownsInput: Bool { lock.lock(); defer { lock.unlock() }; return enabled && owns }
    func configure(enabled: Bool, ownsInput: Bool) {
        lock.lock(); self.enabled = enabled && allowed; owns = ownsInput; lock.unlock()
    }
    /// One sample of player 1's pad, in XInput button bits and stick units.
    /// `lt`/`rt`: the triggers (0-255), page up and down past half way. `name`: the
    /// controller's name, logged once per controller.
    func sample(buttons raw: UInt16, lx: Int16, ly: Int16, lt: UInt8 = 0, rt: UInt8 = 0, name: String? = nil, now: Date = Date()) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        var buttons = UInt32(raw)
        if owns {
            // Stick past half way (the dead zone) counts as the D-pad. Once in, it stays in until
            // the stick is back under a third: a stick resting near half way no longer flickers
            // in and out and moves two or three rows for one push (Cameron, Test 6 log: one down
            // went st-steam -> st-epic -> st-itch in 12 ms).
            let held = stick
            func past(_ value: Int16, _ sign: Int32, _ mask: UInt32) -> Bool {
                Int32(value) * sign > (held & mask != 0 ? 10000 : 16000)
            }
            var pushed: UInt32 = 0
            if past(lx, -1, 4) { pushed |= 4 }; if past(lx, 1, 8) { pushed |= 8 }
            if past(ly, 1, 1) { pushed |= 1 }; if past(ly, -1, 2) { pushed |= 2 }
            stick = pushed
            buttons |= pushed
            if lt > 128 { buttons |= 0x10000 }; if rt > 128 { buttons |= 0x20000 }
        }
        var pressed = buttons & ~last; last = buttons
        // A held direction repeats, so a long row or list is crossed without tapping.
        let direction = buttons & 0xF
        if !owns || direction == 0 || direction.nonzeroBitCount > 1 {
            heldDirection = 0; repeatAt = .distantFuture
        } else if direction != heldDirection || pressed & 0xF != 0 {
            heldDirection = direction; repeatAt = now.addingTimeInterval(0.35)
        } else if now >= repeatAt {
            pressed |= direction; repeatAt = now.addingTimeInterval(0.1)
        }
        let own = owns, announce = !announced; announced = true
        var newName: String?
        if let name, !name.isEmpty, !named.contains(name) { named.insert(name); newName = name }
        lock.unlock()
        if announce { DispatchQueue.main.async { self.connected = true; fputs("[frontend-controller] navigation active\n", stderr) } }
        if let newName { fputs("[menu-pad] connected \(newName)\n", stderr) }
        var command: String?
        // Reserve the Back+Start chord in gameplay, leaving ordinary Start intact.
        if !own, buttons & 0x30 == 0x30, pressed & 0x30 != 0 { command = "menu" }
        if own {
            let names: [(UInt32, String)] = [(1, "up"), (2, "down"), (4, "left"), (8, "right"), (0x1000, "accept"), (0x2000, "back"),
                                             (0x8000, "add"), (0x4000, "play"), (0x10, "menu"), (0x20, "search"), (0x100, "previous"), (0x200, "next"),
                                             (0x10000, "pageUp"), (0x20000, "pageDown")]
            for (mask, name) in names where pressed & mask != 0 { command = name; break }
            if command == nil, pressed != 0 { LogTrail.pressedUnused(pressed) }
        }
        if let command {
            DispatchQueue.main.async {
                // madeira-log-trail: the press, and where the ring was before and after it.
                let before = MainActor.assumeIsolated { LogTrail.ring }
                self.commands.send(command)
                MainActor.assumeIsolated { LogTrail.pressed(command, ownsMenus: own, before: before) }
            }
        }
    }
}

/// Which interface Madeira starts with: the library (the default) or the
/// developer interface. The choice is made in either interface, stored in
/// UserDefaults and read once per run, so a change applies at the next start.
/// Without a stored choice, MADEIRA_FRONTEND=0/1 in madeira.cfg (env.) or in
/// madeira-env.txt decides; MADEIRA_FRONTEND_DEFAULT_NEW=0 makes the developer
/// interface the default.
enum FrontendChoice {
    static let key = "madeiraFrontend"
    static let startup: (useNew: Bool, source: String) = {
        if let stored = UserDefaults.standard.string(forKey: key), ["new", "old"].contains(stored) {
            return (stored == "new", "setting")
        }
        if let configured = MadeiraConfig.get("env.MADEIRA_FRONTEND") { return (configured != "0", "config") }
        if let value = getenv("MADEIRA_FRONTEND").map({ String(cString: $0) }) { return (value != "0", "environment") }
        return (MadeiraConfig.flag("MADEIRA_FRONTEND_DEFAULT_NEW"), "default")
    }()
    /// The interface the next start uses.
    static var preferNew: Bool {
        guard let stored = UserDefaults.standard.string(forKey: key), ["new", "old"].contains(stored) else { return startup.useNew }
        return stored == "new"
    }
    static func choose(new useNew: Bool) {
        UserDefaults.standard.set(useNew ? "new" : "old", forKey: key)
        LogStore.shared.log("[frontend] next-start choice=\(useNew ? "library" : "developer") source=setting")
    }
    private static var logged = false
    static func logStartup() {
        guard !logged else { return }
        logged = true
        LogStore.shared.log("[frontend] choice=\(startup.useNew ? "library" : "developer") source=\(startup.source)")
    }
}

/// One game in the library and its launch profile, stored in
/// Documents/madeira-library.json (version 1). New fields must be optional so
/// older files keep decoding; unknown keys are ignored.
struct LibraryEntry: Codable, Identifiable {
    var id = UUID()
    var title: String
    /// The executable, relative to drive_c ("Games/Foo/foo.exe").
    var relativePath: String
    /// 32 or 64 from the PE header, 0 when unknown.
    var bits: Int
    /// A user-chosen cover in Documents/madeira-art/.
    var coverFile: String?
    /// The Steam store app this game was matched to (Game details › Find on
    /// Steam). Only its public artwork is used: the library cover and the
    /// starting screen's background, when no cover file is chosen.
    var steamID: Int?
    var arguments = ""
    /// The virtual monitor's size ("WxH"): the session default a game renders
    /// for (GuestDisplay.configureSessionDefault), and the Desktop entry's
    /// desktop size. ml1172: new entries default to this screen's shape at
    /// 1280x720's pixel count (ResolutionChoices: 1408x648 on a 19.5:9 iPhone,
    /// as before, and 1152x800 on an 11-inch iPad, where a fixed 1408x648 left bars).
    var resolution = ResolutionChoices.defaultValue
    /// How the monitor is scaled to the screen (DisplayMode raw value; nil = Fit).
    var display: String?
    /// FPS limit: 1 = 60, 3 = 30, 4 = 40, 0 = display maximum, 2 = uncapped (madeira_set_vsync_locked).
    var fpsMode = 1
    /// FEX's X87ReducedPrecision for this game: true exports 1 (reduced, fast).
    /// false leaves the engine's default unless `fullX87` asks for full precision:
    /// the 32-bit (WOW64) module runs reduced by default (ml950: full precision
    /// cost Fallout: New Vegas 20-50 % of its CPU and about half its frame rate),
    /// the 64-bit one full. Saved entries all carry false, so "false" has to mean
    /// the engine's default, not "full": exporting 0 for it (upstream #461) put
    /// every 32-bit game on the slow path.
    var reducedX87 = false
    /// Full 80-bit x87 for this game (exports 0), chosen on the Compatibility page;
    /// nil = the engine's default. Ignored when reducedX87 is on.
    var fullX87: Bool?

    /// The Compatibility page's x87 choice over reducedX87 and fullX87.
    enum X87Precision: String, CaseIterable { case automatic, reduced, full }
    var x87Precision: X87Precision {
        get { reducedX87 ? .reduced : (fullX87 == true ? .full : .automatic) }
        set {
            reducedX87 = newValue == .reduced
            fullX87 = newValue == .full ? true : nil
        }
    }
    var liveLogs = false
    var performance = false
    var touchControls = false
    var controls: [TouchControl]?
    /// The named layout (TouchControlPresets.swift) `controls` came from, so the
    /// Session menu shows it and an edit is written back to it; nil for controls
    /// no layout holds. Older files have none.
    var controlLayout: String?
    /// The game's gesture zones (GestureZones.swift), kept with its controls. Older files have none.
    var zones: [GestureZone]?
    var lastPlayed: Date?
    var graphicsAPI: String?
    var folderBytes: Int64?
    var metadataChecked: Date?
    var metadataRevision: Int?
    var overlayFields: [String]?
    /// The Wine desktop (explorer and services in a virtual desktop).
    var desktop: Bool?
    /// ml2021: Valve's client in Big Picture, inside the Wine desktop (the library's
    /// Big Picture button; C:\big-picture.bat, written at every launch).
    var bigPicture: Bool?
    /// Touch controls' opacity (0.15...1, nil = 0.7) and overall size (0.5...2,
    /// nil = 1) in this game's sessions.
    var controlOpacity: Double?
    var controlSize: Double?
    // ml1163: how a game starts. All optional, so older library files decode and
    // entries that never set them start as before.
    /// "desktop": the program runs inside the Wine desktop, as explorer.exe's
    /// first child (explorer.exe /desktop=shell,<resolution> "<exe>" args), so
    /// every window shows. nil or "direct": the program is Wine's first process,
    /// with no desktop; only its small windows (launchers, message boxes) are
    /// drawn over the game.
    var launchMode: String?
    /// The working directory, a C:\ path (exported as MADEIRA_WORKDIR); nil or
    /// empty = the program's own folder (Steam's for "The game").
    var workingDirectory: String?
    /// Start services.exe (the SCM, and through it rpcss: out-of-process COM,
    /// which Steam-style launchers need) before the program, from a generated
    /// C:\madeira-games\<id>.bat (servicesScript).
    var startServices: Bool?
    /// How a physical controller reaches this game: nil, the game's own support
    /// (XInput, as before); "dinput", XInput and a DirectInput joystick of the same
    /// pad (for games older than XInput; a game reading both APIs sees two
    /// controllers); "keys", keyboard and mouse (PadKeyboardMouse: the pad
    /// presses keys and moves the mouse, the game sees no controller). For games
    /// without controller support. Optional, so older files decode.
    var controllerMode: String?
    /// Keyboard-and-mouse mode: what each controller input does in this game
    /// (PadBindings.buttonNames plus "LS"/"RS" → key, mouse button, key stick or
    /// .none), on top of the layout's bindings and the built-in template. Only
    /// inputs the player changed are stored. Optional, so older files decode.
    var controllerBinds: [String: ControlAction]?
    /// Keyboard-and-mouse mode: vertical speed of the right-stick mouse relative
    /// to horizontal (PadBindings.mouseVertical); nil = 1.
    var padMouseVertical: Double?
    /// Gyro aim and turbo for player 1 (PadAssist.swift); nil = both off.
    /// Optional, so older files decode.
    var padAssist: PadAssistSettings?
    /// Processors reported to Windows code in this game's sessions
    /// (MADEIRA_CPU_COUNT, ntdll); nil = automatic.
    var cpuCount: Int?
    /// D3D9 anisotropic filtering limit (DXMT_D9_ANISO_LIMIT: 1, 2, 4 or 8);
    /// nil = the application's own choice.
    var anisotropyLimit: Int?
    /// "Report an NVIDIA GPU": DXGI names NVIDIA as the vendor (GeForce RTX
    /// 3060, 10DE:2544), DXMT's NVAPI answers, and win32u registers the same
    /// display adapter, for games that refuse a GPU without a known vendor's
    /// driver. nil = off.
    var reportNVIDIA: Bool?
    /// A Steam game (SteamGames.swift): Madeira Dock starts it by this App ID
    /// through Valve's client, with Steam's default launch option.
    /// `relativePath` is then its install folder, relative to drive_c.
    var steamAppID: Int?
    /// How a Steam game starts (Game details › Steam › Start with): nil is Madeira
    /// Dock, the default; "game" is the game's own program in Wine, without Steam
    /// (SteamDirectStart).
    var steamStart: String?
    /// "The game": the program, relative to the install folder ("bin/game.exe"), its
    /// arguments, and its working folder (relative to the install folder; nil: the
    /// program's own folder, "": the install folder), from Steam's launch configuration
    /// for the app ("steam"), the Program picker ("choice") or the folder's only
    /// program ("only").
    var steamProgram: String?
    var steamProgramArguments: String?
    var steamProgramFolder: String?
    var steamProgramSource: String?
    /// The install folder, build and picked program a Steam game's `bits` and
    /// `graphicsAPI` were read for, and whether Steam's launch configuration was
    /// cached (LibraryModel.refreshSteamMetadata); any change reads them again.
    var steamMetadataInstall: String?
    /// A GOG game (GOGLibrary.swift): its product id. `relativePath` is then its
    /// program inside C:\GOG Games, from the build's goggame-<id>.info.
    var gogProductID: String?
    /// An itch.io game (ItchLibrary.swift): its game id. `relativePath` is then its
    /// program inside C:\itch.
    var itchGameID: Int?
    /// An Epic Games game (EpicLibrary.swift): its app name. `relativePath` is then
    /// its program inside C:\Program Files\Epic Games, and each start adds Epic's
    /// sign-in arguments (EpicLibrary.launchArguments) for that launch only.
    var epicAppName: String?
    /// An EA app game (EALibrary.swift): its offer id. `relativePath` is then its
    /// program inside C:\Program Files\EA Games, and each start first gets the game's
    /// licence, the EA app's environment and Madeira's stand-in for the EA app's
    /// local service (EALibrary.prepareLaunch).
    var eaOfferID: String?
    /// An Epic game with an official way to start without anti-cheat
    /// (epicAntiCheatOffProgram): nil or true starts that program.
    /// The anti-cheat cannot run in Wine on iOS, so on is the default.
    var epicAntiCheatOff: Bool?
    /// Games with an official way to start without Easy Anti-Cheat (offline modes
    /// only), as the program to start instead of the one Epic names. Rocket League:
    /// its Launcher.exe with -noeac ("No Easy Anti Cheat") starts RocketLeague.exe
    /// with Epic's arguments and nothing else. Madeira starts that program itself,
    /// which leaves out the launcher's .NET runtime: it crashed in Wine Mono once
    /// the game had quit, so the session never ended cleanly.
    static let epicAntiCheatOffProgram: [String: String] = ["Sugar": "RocketLeague.exe"]
    /// Fastsync's per-game switches, used only while Settings › Sync engine is
    /// Fastsync: "Fast synchronization" (nil = on; off gives this game Wine's
    /// standard sync) and "Fast semaphore waits" (nil = off). Optional, so older
    /// library files decode; the fork's files carry the same keys.
    var fastSync: Bool?
    var semaphoreFastPath: Bool?
    /// This game's own lines in madeira.cfg's syntax (Game details › This game's
    /// config). At launch a key set here wins over madeira.cfg, env.NAME lines are
    /// exported after madeira.cfg's and dxmt options are added to its own
    /// (MadeiraConfig.applyGame). nil: none.
    var config: String?
    /// AVX and AVX2 for this game (FEX's 128-bit AVX emulation, MADEIRA_FEX_AVX);
    /// nil = off, FEX's iOS default.
    var avx: Bool?
    /// Experimental MetalFX frame interpolation between the game's frames
    /// (DXMT's present path, MADEIRA_FRAMEGEN); nil = off.
    var frameGeneration: Bool?
    /// MetalFX spatial upscaling factor (Display › MetalFX upscaling: 1.5 or 2;
    /// nil = off), passed on as this game's `metalfx-upscale` line.
    var metalFXUpscale: Double?
    /// ml1298: a reservation of 64 GB or more that the address space cannot hold
    /// is served with a real 16 GB part (ntdll's ios_oversize_reserve), passed on
    /// as this game's `oversize-reserve` line; nil = off, such a reservation fails.
    var largeReservations: Bool?

    /// What MadeiraConfig.applyGame writes for this game: the lines its pickers
    /// stand for, then its own config, which wins where both set a key.
    var gameConfigText: String? {
        var lines: [String] = []
        if let metalFXUpscale { lines.append("metalfx-upscale = \(metalFXUpscale)") }
        if largeReservations == true { lines.append("oversize-reserve = 1") }
        if let config, !config.isEmpty { lines.append(config) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    var displayMode: DisplayMode { display.flatMap(DisplayMode.init(rawValue:)) ?? .fit }

    var launchArguments: String {
        if desktop == true { return "/desktop=shell,\(resolution) C:\\windows\\system32\\services.exe" }
        return launchCommand.args
    }

    /// ml1163: a .bat or .cmd target runs through cmd.exe. For "The game" (a Steam
    /// game started as its own program) the target is that program.
    var isBatch: Bool {
        let path = launchRelativePath.lowercased()
        return path.hasSuffix(".bat") || path.hasSuffix(".cmd")
    }
    /// ml1163's launch options apply to what the library starts itself: a game you
    /// added, or a Steam game's "The game". A Steam game started through Madeira
    /// Dock has Dock's own desktop and command (ContentView.startDock).
    var usesLaunchOptions: Bool { desktop != true && (steamAppID == nil || startsSteamGameDirectly) }
    /// ml1163: a game (not the Desktop entry) started inside the Wine desktop.
    var runsInDesktop: Bool { usesLaunchOptions && launchMode == "desktop" }
    /// The program's own arguments: Steam's launch configuration for "The game",
    /// else the entry's Launch arguments; an Epic game's sign-in arguments come first
    /// while its launch is being prepared.
    var programArguments: String {
        let own = startsSteamGameDirectly ? (steamProgramArguments ?? "") : arguments
        guard epicAppName != nil, let transient = Self.transientArguments(for: id), !transient.isEmpty else { return own }
        return own.isEmpty ? transient : transient + " " + own
    }
    /// Arguments for the launch being prepared only (an Epic game's one-use sign-in
    /// code): never part of the saved entry. ContentView sets them before the launch;
    /// applyEnvironment clears them once the bridge's command is exported.
    private static let transientLock = NSLock()
    private static var transient: [UUID: String] = [:]
    static func setTransientArguments(_ arguments: String?, for id: UUID) {
        transientLock.lock(); defer { transientLock.unlock() }
        transient[id] = arguments
    }
    static func transientArguments(for id: UUID) -> String? {
        transientLock.lock(); defer { transientLock.unlock() }
        return transient[id]
    }
    /// A GOG game's redistributable installers still to run in this prefix: batch lines
    /// (GOGSetup.batchLines) that the services batch runs before the program. ContentView
    /// sets them (or nil) at every start of a GOG game; never part of the saved entry.
    private static var gogSetup: [UUID: String] = [:]
    static func setGOGSetup(_ lines: String?, for id: UUID) {
        transientLock.lock(); defer { transientLock.unlock() }
        gogSetup[id] = lines
    }
    static func gogSetup(for id: UUID) -> String? {
        transientLock.lock(); defer { transientLock.unlock() }
        return gogSetup[id]
    }
    /// ml1163: the directory the program starts in (MADEIRA_WORKDIR): the chosen
    /// working folder, else Steam's for "The game", else the program's own folder.
    /// A desktop-mode game inherits explorer's directory and a .bat runs as
    /// cmd.exe, whose own folder is system32, so configureLaunch exports it
    /// whenever what starts lives elsewhere.
    var launchDirectory: String {
        let chosen = (workingDirectory ?? "").trimmingCharacters(in: .whitespaces)
        if !chosen.isEmpty { return chosen }
        return steamWorkingWindowsPath ?? Self.folder(of: launchWindowsPath)
    }
    /// C:\a\b\x.exe -> C:\a\b (C:\ for a file in the root).
    static func folder(of windowsPath: String) -> String {
        guard let i = windowsPath.lastIndex(of: "\\") else { return "C:\\" }
        let dir = String(windowsPath[..<i])
        return dir.count <= 2 ? dir + "\\" : dir
    }
    /// drive_c on the host. LibraryModel.drive is the same folder; this struct
    /// stands alone so the host tests can compile it.
    static var hostDrive: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wine/drive_c", isDirectory: true)
    }
    /// C:\a\b -> <prefix>/drive_c/a/b; nil for another drive or a ".." element.
    static func hostURL(ofWindowsPath path: String) -> URL? {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard p.count >= 3, p.prefix(3).uppercased() == "C:\\" else { return nil }
        let parts = p.dropFirst(3).split(separator: "\\").map(String.init)
        guard !parts.contains("..") else { return nil }
        return parts.reduce(hostDrive) { $0.appendingPathComponent($1) }
    }
    /// ml1163: where startServices writes its batch file, one per entry.
    var servicesScriptPath: String { "C:\\madeira-games\\\(id.uuidString).bat" }
    /// ml1163: the services batch, CRLF. services.exe is STARTed; then a .bat is
    /// CALLed so it runs in this console, and an exe is STARTed so cmd exits and
    /// its console closes straight away (the pattern of Steam's batch). nil
    /// unless startServices.
    var servicesScript: String? {
        let setup = (Self.gogSetup(for: id) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard usesLaunchOptions, startServices == true || !setup.isEmpty else { return nil }
        func quoted(_ s: String) -> String { "\"\(s)\"" }
        // Text put into the batch keeps one line each (a line break in the arguments
        // or the title would start another command), and its '%' is doubled once per
        // expansion: cmd expands '%' in a batch file, so C:\Games\100% Juice became
        // C:\Games\100 Juice and "%~" in a title was a syntax error that stopped the
        // whole batch; CALL expands its line a second time.
        func batchText(_ s: String, expansions: Int = 1) -> String {
            var text = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            for _ in 0..<expansions { text = text.replacingOccurrences(of: "%", with: "%%") }
            return text
        }
        let expansions = isBatch ? 2 : 1   // the program's line: CALL for a .bat
        let extra = batchText(programArguments.trimmingCharacters(in: .whitespaces), expansions: expansions)
        let target = quoted(batchText(launchWindowsPath, expansions: expansions))
        let run = isBatch ? "call \(target)" : "start \"\" \(target)"
        let lines: [String] = [
            "@echo off",
            "rem Generated by Madeira (ml1163) for \(batchText(title)); rewritten at every launch.",
            "start \"\" \"C:\\windows\\system32\\services.exe\"",
        ] + (setup.isEmpty ? [] : [setup]) + [   // a GOG game's installers (GOGSetup), already batch text
            "cd /d \(quoted(batchText(launchDirectory)))",
            extra.isEmpty ? run : run + " " + extra,
        ]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// ml1163: what a game starts (the Desktop entry keeps its own command
    /// above). MADEIRA_ARGS goes through
    /// WineProcessBridge's quote-aware tokenizer; Wine re-quotes an argument
    /// with spaces.
    ///   Wine desktop: explorer.exe /desktop=shell,WxH "<exe>" args, or cmd /c "x.bat" args
    ///   direct:       the exe with its arguments, or cmd.exe /c "x.bat" args
    /// With startServices the target is the services batch, which carries the
    /// arguments itself. The exe is launchWindowsPath: "The game"'s program for
    /// a Steam game started as its own program.
    private var launchCommand: (exe: String, args: String) { launchCommand(parent: nil) }
    /// ml2320: with `parent` (a program, never with a batch) the program starts as its child:
    /// "<parent>" "<program>" args, in the Wine desktop or directly.
    private func launchCommand(parent: String?) -> (exe: String, args: String) {
        func quoted(_ s: String) -> String { "\"\(s)\"" }
        var path = launchWindowsPath
        var extra = programArguments.trimmingCharacters(in: .whitespaces)
        var batch = isBatch
        if servicesScript != nil { path = servicesScriptPath; extra = ""; batch = true }
        func withExtra(_ s: String) -> String { extra.isEmpty ? s : s + " " + extra }
        let parent = batch ? nil : parent
        if runsInDesktop {
            let program = parent.map { quoted($0) + " " + quoted(path) } ?? quoted(path)
            return ("explorer.exe", "/desktop=shell,\(resolution) " + withExtra(batch ? "cmd /c \(quoted(path))" : program))
        }
        if batch { return ("C:\\windows\\system32\\cmd.exe", withExtra("/c \(quoted(path))")) }
        if let parent { return (parent, withExtra(quoted(path))) }
        return (path, programArguments)   // upstream's direct launch, arguments verbatim
    }
    /// ml2320: an Epic game's x64 program starts as the child of a process with the Epic client's
    /// name (build/epic-parent), as it does under the Epic client on Windows. A publisher's launcher
    /// that did not find that process treated the Epic copy as not owned and offered it for sale.
    /// nil for any other entry, a batch, a 32-bit program, a build without the program, or with
    /// env.MADEIRA_EPIC_LAUNCHER_PARENT=0.
    var epicParent: String? {
        guard epicAppName != nil, !isBatch, servicesScript == nil,
              MadeiraConfig.get("env.MADEIRA_EPIC_LAUNCHER_PARENT") != "0",
              Bundle.main.url(forResource: "EpicGamesLauncher", withExtension: "exe", subdirectory: "arm64ec-windows") != nil,
              let url = Self.hostURL(ofWindowsPath: launchWindowsPath), Self.peMachine(url) == 0x8664 else { return nil }
        return "C:\\windows\\system32\\EpicGamesLauncher.exe"
    }
    /// The PE machine of an executable (0x14c: 32-bit x86, 0x8664: x64), nil when unreadable.
    static func peMachine(_ url: URL) -> Int? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let dos = try? h.read(upToCount: 64), dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { return nil }
        let offset = (0..<4).reduce(UInt64(0)) { $0 | (UInt64(dos[60 + $1]) << ($1 * 8)) }
        guard offset >= 64, offset < 16 * 1024 * 1024, (try? h.seek(toOffset: offset)) != nil,
              let pe = try? h.read(upToCount: 6), pe.count == 6, Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else { return nil }
        return Int(pe[4]) | Int(pe[5]) << 8
    }
    /// The details page's "command that runs" line: the program's file name and
    /// its arguments, as upstream shows a direct start; ml1163: what starts it
    /// otherwise (explorer.exe or cmd.exe with its whole command), and with the
    /// services batch also what that batch starts.
    var commandPreview: String {
        func name(_ path: String) -> String { path.split(separator: "\\").last.map(String.init) ?? path }
        let command = launchCommand
        let program = ([name(launchWindowsPath)] + (programArguments.isEmpty ? [] : [programArguments])).joined(separator: " ")
        if command.exe == launchWindowsPath { return program }
        let line = name(command.exe) + " " + command.args
        return servicesScript == nil ? line : line + "\n(the batch starts services.exe, then " + program + ")"
    }

    /// A Steam game that starts as its own program ("Start with: The game").
    var startsSteamGameDirectly: Bool { steamAppID != nil && steamStart == "game" }
    /// What a launch starts, relative to drive_c: "The game"'s program inside the
    /// install folder, else `relativePath`.
    var launchRelativePath: String {
        if let app = epicAppName, epicAntiCheatOff != false, let program = Self.epicAntiCheatOffProgram[app] {
            // The program next to the one Epic names (Rocket League: Launcher.exe -> RocketLeague.exe).
            let folder = relativePath.split(separator: "/").dropLast().joined(separator: "/")
            return folder.isEmpty ? program : folder + "/" + program
        }
        guard startsSteamGameDirectly, let program = steamProgram, !program.isEmpty else { return relativePath }
        return relativePath + "/" + program
    }
    var launchWindowsPath: String { "C:\\" + launchRelativePath.replacingOccurrences(of: "/", with: "\\") }
    /// "The game"'s working folder as a Windows path, or nil for the program's own folder.
    var steamWorkingWindowsPath: String? {
        guard startsSteamGameDirectly, let folder = steamProgramFolder else { return nil }
        return "C:\\" + (folder.isEmpty ? relativePath : relativePath + "/" + folder).replacingOccurrences(of: "/", with: "\\")
    }

    static let desktopID = UUID(uuidString: "AF046C35-C32A-497B-92BC-0BBD14F8CB61")!
    static var desktopEntry: LibraryEntry {
        var entry = LibraryEntry(title: "Desktop", relativePath: "windows/system32/explorer.exe", bits: 64)
        entry.id = desktopID; entry.desktop = true; entry.graphicsAPI = "Wine desktop"
        return entry
    }

    // MARK: ml2021 Big Picture

    static let bigPictureID = UUID(uuidString: "5A0B2C44-9C1E-4D0F-8F2A-7B3E6D1C9A10")!
    /// Valve's client in Big Picture (its gamepad UI) inside the Wine desktop, as a
    /// desktop-mode batch: C:\big-picture.bat starts services.exe and then steam.exe
    /// -bigpicture with the Chromium switches the Steam test launch proved
    /// (ContentView.prepareSteamLaunch). Its recommended list (GameRecommendations
    /// .steamBigPicture) carries the launcher-chain memory lines a 64-bit Chromium
    /// host needs and the swap tier with the donor pool.
    static var bigPictureEntry: LibraryEntry {
        var entry = LibraryEntry(title: "Big Picture", relativePath: "big-picture.bat", bits: 64)
        entry.id = bigPictureID; entry.bigPicture = true; entry.graphicsAPI = "Steam"; entry.launchMode = "desktop"
        return entry
    }
    /// Madeira Dock's Steam folder inside the prefix (Windows path, Unix path), when its
    /// steam.exe is there. Its component set is PINNED (SteamRuntime: steamclient64.dll must be
    /// the build the Dock host supports), so the client UI must never run from it: steam.exe
    /// would complete the install from Valve's CDN and replace the pinned build.
    static var dockSteamFolder: (windows: String, unix: String)? {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let prefix = documents.appendingPathComponent("wine").path
        let candidates = [
            ("C:\\Program Files (x86)\\Steam", "\(prefix)/drive_c/Program Files (x86)/Steam"),
            ("C:\\Program Files\\Steam", "\(prefix)/drive_c/Program Files/Steam"),
        ]
        return candidates.first { fm.fileExists(atPath: "\($0.1)/steam.exe") }
    }
    /// Big Picture's own Steam folder: Valve's client completes itself there on the first
    /// run (steam.exe is Valve's bootstrapper: it fetches the client's packages, the web
    /// helper included, from Valve's CDN into its own folder), leaving the Dock's pinned
    /// install alone.
    static var bigPictureFolder: (windows: String, unix: String)? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let prefix = documents.appendingPathComponent("wine").path
        return ("C:\\Program Files\\Steam Big Picture", "\(prefix)/drive_c/Program Files/Steam Big Picture")
    }
    /// Big Picture is unfinished: the button beside Desktop and a Big Picture card in the library
    /// exist only in a build compiled with the Swift condition MADEIRA_BIG_PICTURE_UI (for example
    /// xcodebuild SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) MADEIRA_BIG_PICTURE_UI').
    /// No IPA build sets it, so release IPAs have neither; the launch code is compiled either way.
#if MADEIRA_BIG_PICTURE_UI
    static let bigPictureShown = true
#else
    static let bigPictureShown = false
#endif
    /// Whether the library lists this entry: a Big Picture entry only while Big Picture is shown.
    var listedInLibrary: Bool { bigPicture != true || Self.bigPictureShown }
    /// The button is offered when Big Picture's folder has a client, or the Dock's steam.exe
    /// can seed one.
    static var steamClientInstalled: Bool {
        let fm = FileManager.default
        if let bp = bigPictureFolder, fm.fileExists(atPath: "\(bp.unix)/steam.exe") { return true }
        return dockSteamFolder != nil
    }
    /// Writes C:\big-picture.bat for this launch, seeding Big Picture's folder with the
    /// Dock's steam.exe when it has none yet. False, having logged why, when there is no client.
    @discardableResult
    static func writeBigPictureBatch() -> Bool {
        let fm = FileManager.default
        guard let folder = bigPictureFolder,
              let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        if !fm.fileExists(atPath: "\(folder.unix)/steam.exe") {
            guard let dock = dockSteamFolder else {
                LogStore.shared.log("[big-picture] no Steam client to start from: prepare Madeira Dock's Steam components first", level: .error)
                return false
            }
            do {
                try fm.createDirectory(atPath: folder.unix, withIntermediateDirectories: true)
                try fm.copyItem(atPath: "\(dock.unix)/steam.exe", toPath: "\(folder.unix)/steam.exe")
                LogStore.shared.log("[big-picture] seeded \(folder.windows) with the Dock's steam.exe; Valve's client completes itself there on this first run (a download from Valve's CDN)")
            } catch {
                LogStore.shared.log("[big-picture] could not seed \(folder.windows): \(error.localizedDescription)", level: .error)
                return false
            }
        }
        // ml2210: once the 32-bit client and its web helper (bin/cef/cef.win7) are in place,
        // the bootstrapper neither updates itself nor the client, so a later run cannot move
        // it to the 64-bit client, whose CEF pools do not fit the address space.
        // env.MADEIRA_BIG_PICTURE_PIN = 0 lets it update as before.
        let pinned = MadeiraConfig.flag("MADEIRA_BIG_PICTURE_PIN", fallback: true)
            && fm.fileExists(atPath: "\(folder.unix)/bin/cef/cef.win7/steamwebhelper.exe")
        if pinned { LogStore.shared.log("[big-picture] ml2210 the installed 32-bit client is kept: no bootstrap update this run") }
        // ml2230: env.MADEIRA_BIG_PICTURE_GPU = 1 lets the web helper draw with the GPU (Chromium's
        // ANGLE on the 32-bit D3D11); off by default, software drawing as before.
        let gpu = MadeiraConfig.flag("MADEIRA_BIG_PICTURE_GPU", fallback: false)
        if gpu { LogStore.shared.log("[big-picture] ml2230 the web helper may use the GPU (env.MADEIRA_BIG_PICTURE_GPU = 1)") }
        listMadeiraLibraries(in: folder)
        let bat = [
            "@echo off",
            "rem Generated by Madeira (ml2021) for Big Picture; rewritten at every launch.",
            "start \"\" \"C:\\windows\\system32\\services.exe\"",
            "cd /d \"\(folder.windows)\"",
            "\"\(folder.windows)\\steam.exe\" -bigpicture -no-cef-sandbox" + (gpu ? "" : " -cef-disable-gpu") + " -console -nocrashmonitor"
                + (pinned ? " -nobootstrapperupdate -skipinitialbootstrap" : "")
                + " -cef-disable-features=SegmentationPlatform,OptimizationTargetPrediction,OptimizationHints",
        ].joined(separator: "\r\n") + "\r\n"
        let path = documents.appendingPathComponent("wine/drive_c/big-picture.bat").path
        do {
            try bat.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            LogStore.shared.log("[big-picture] could not write big-picture.bat: \(error.localizedDescription)", level: .error)
            return false
        }
        LogStore.shared.log("[big-picture] steam.exe -bigpicture from \(folder.windows) in the Wine desktop")
        return true
    }

    /// ml2230: Big Picture's client lists the games Madeira installed. Its libraryfolders.vdf
    /// (config/, the one Valve's client reads, and its steamapps/ copy) gets Madeira's Steam
    /// library (the Dock client's folder, where downloads go) and the libraries on connected
    /// drives, added beside the client's own entries, never replacing one. The records there
    /// are the client's own format (AppManifestWriter). env.MADEIRA_BIG_PICTURE_LIBRARIES = 0
    /// leaves the files alone.
    private static func listMadeiraLibraries(in folder: (windows: String, unix: String)) {
        guard MadeiraConfig.flag("MADEIRA_BIG_PICTURE_LIBRARIES", fallback: true) else { return }   // 0: Big Picture's client lists only its own library
        let fm = FileManager.default
        let own = "Program Files/Steam Big Picture"
        // ml2240: every library Madeira's Steam list reads (MadeiraDock.steamLibraries), not
        // only the client's own folder and the external drives: the other C: libraries its
        // libraryfolders.vdf names were left out. MADEIRA_BIG_PICTURE_DOCK_LIBRARIES=0 restores.
        let found = MadeiraConfig.flag("MADEIRA_BIG_PICTURE_DOCK_LIBRARIES", fallback: true)
            ? MadeiraDock.steamLibraries(drive: MadeiraDock.drive)
            : [SteamRuntimeFiles.relativeRoot + "/steamapps"] + ExternalDrives.steamLibraries
        var libraries = [own]
        for library in found.prefix(32) where library.hasSuffix("/steamapps") {
            let root = String(library.dropLast("/steamapps".count))
            guard !libraries.contains(where: { $0.caseInsensitiveCompare(root) == .orderedSame }) else { continue }
            libraries.append(root)
            let manifests = ((try? fm.contentsOfDirectory(atPath: MadeiraDock.drive.appendingPathComponent(library).path)) ?? [])
                .filter { $0.hasPrefix("appmanifest_") && $0.hasSuffix(".acf") }
            LogStore.shared.log("[big-picture] ml2240 library C:\\\(root.replacingOccurrences(of: "/", with: "\\")): \(manifests.count) install record(s)")
        }
        var added = 0
        for sub in ["config", "steamapps"] {
            let vdf = URL(fileURLWithPath: "\(folder.unix)/\(sub)/libraryfolders.vdf")
            do {
                let existing: Data?
                do { existing = try Data(contentsOf: vdf) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { existing = nil }
                let data = try ExternalSteamLibraries.add(paths: libraries, to: existing)
                guard data != existing else { continue }
                try fm.createDirectory(at: vdf.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: vdf, options: .atomic)
                added += 1
            } catch {
                LogStore.shared.log("[big-picture] \(sub)/libraryfolders.vdf was kept: \(error.localizedDescription)")
            }
        }
        LogStore.shared.log("[big-picture] ml2230 Madeira's Steam libraries listed for Big Picture: \(libraries.count - 1) (\(added) file(s) updated)")
    }

    var windowsPath: String { "C:\\" + relativePath.replacingOccurrences(of: "/", with: "\\") }

    /// The vsync mode to apply: a saved 30 or 40 FPS limit runs as 60 when it is
    /// not offered (DXMT without that cap would present uncapped).
    var effectiveFPSMode: Int32 { ProMotionIntent.supportedMode(fpsMode) }

    func validate() throws {
        let size = resolution.split(separator: "x").compactMap { Int($0) }
        guard size.count == 2, (320...4096).contains(size[0]), (240...4096).contains(size[1]),
              (0...4).contains(fpsMode), !arguments.contains("\0"), !windowsPath.contains("\0"),
              !launchArguments.contains("\0"), !launchWindowsPath.contains("\0"),
              launchWindowsPath.utf8.count < 1024, (steamWorkingWindowsPath?.utf8.count ?? 0) < 512 else {
            throw LibraryError.message("The saved launch profile contains invalid display or argument values.")
        }
        guard LaunchArgumentText.valid(launchArguments) else {
            throw LibraryError.message("Use balanced double quotes, no control characters, and at most 64 launch arguments in 4 KB.")
        }
        // build/madeira_cfg.h reads at most 64 KB of a file.
        guard (config?.utf8.count ?? 0) < 60_000, config?.contains("\0") != true else {
            throw LibraryError.message("This game's config is too long.")
        }
        // ml1163: the launch options.
        guard launchMode == nil || launchMode == "desktop" || launchMode == "direct" else {
            throw LibraryError.message("The saved launch profile contains an invalid launch mode.")
        }
        if usesLaunchOptions, let chosen = workingDirectory?.trimmingCharacters(in: .whitespaces), !chosen.isEmpty {
            // WineProcessBridge maps MADEIRA_WORKDIR onto drive_c (C:\ only), and the
            // services batch quotes it, so only an existing C:\ folder without
            // quotes is accepted.
            var isFolder: ObjCBool = false
            guard !chosen.contains("\""), !chosen.contains("\0"), chosen.utf8.count < 500,
                  let url = Self.hostURL(ofWindowsPath: chosen),
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
                throw LibraryError.message("The working folder must be an existing folder on drive C:, such as C:\\Games\\Some Game.")
            }
        }
        // validate() is the last step of a launch that can refuse it
        // (ContentView.launchLibraryEntry), so the services batch is written
        // here: a batch that cannot be written stops the launch with a message.
        if let script = servicesScript {
            guard let url = Self.hostURL(ofWindowsPath: servicesScriptPath) else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try script.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw LibraryError.message("Could not write \(servicesScriptPath): \(error.localizedDescription)")
            }
        }
    }

    /// Runs on the launch worker, before the JIT pool is taken.
    func applyEnvironment() {
        configureLaunch()
        // MADEIRA_ARGS now holds an Epic game's sign-in code; nothing else needs it.
        Self.setTransientArguments(nil, for: id)
        // x87: exported only when chosen. Automatic leaves FEX's own default (reduced
        // for 32-bit games, full for 64-bit) and any madeira.cfg line, and clears a
        // previous game's choice.
        switch x87Precision {
        case .reduced: setenv("FEX_X87REDUCEDPRECISION", "1", 1)
        case .full: setenv("FEX_X87REDUCEDPRECISION", "0", 1)
        case .automatic: unsetenv("FEX_X87REDUCEDPRECISION")   // madeira.cfg's line, if any, comes later (WineProcessBridge per_launch)
        }
        // Exported only when chosen: unset keeps the engine's own default (and any
        // madeira.cfg setting), as before these choices existed.
        // Unset otherwise, so a previous game's choice (a launch that died before the
        // session-end unset) never beats madeira.cfg for this one.
        if let cpuCount, (1..<64).contains(cpuCount) { setenv("MADEIRA_CPU_COUNT", String(cpuCount), 1) }
        else { unsetenv("MADEIRA_CPU_COUNT") }
        // "dinput": the host pad also as a DirectInput joystick (wine/dlls/dinput/joystick_ios.c,
        // off by default because a game reading both APIs would see two controllers).
        // Exported only for that choice, and it wins over madeira.cfg's MADEIRA_DINPUT_PAD
        // (ml1240: in ml1184's per-launch list, unset when the session ends); the cfg's
        // own value still applies to the other choices.
        if GamepadInput.keyboardMouseAvailable, controllerMode == "dinput" { setenv("MADEIRA_DINPUT_PAD", "1", 1) }
        else if MadeiraConfig.get("env.MADEIRA_DINPUT_PAD") == nil { unsetenv("MADEIRA_DINPUT_PAD") }
        if let anisotropyLimit, [1, 2, 4, 8].contains(anisotropyLimit) { setenv("DXMT_D9_ANISO_LIMIT", String(anisotropyLimit), 1) }
        else { unsetenv("DXMT_D9_ANISO_LIMIT") }
        // Set or unset, so a previous session's choice never stays.
        if avx == true { setenv("MADEIRA_FEX_AVX", "1", 1) } else { unsetenv("MADEIRA_FEX_AVX") }
        if frameGeneration == true { setenv("MADEIRA_FRAMEGEN", "1", 1) } else { unsetenv("MADEIRA_FRAMEGEN") }
        // "Report an NVIDIA GPU": DXMT's vendor extension (DXGI vendor 10DE,
        // NVAPI), with DXGI's output carrying user32's monitor and mode list so
        // the game finds its monitor on the adapter. The device id goes into
        // DXMT_CONFIG (ContentView); win32u reads DXMT_ENABLE_NVEXT for the
        // registry adapter. Set or unset, so one game's choice never leaks into
        // the next session; when set, it wins over madeira.cfg's lines for the
        // same keys (ml1184's per-launch list in WineProcessBridge.m).
        if reportNVIDIA == true {
            setenv("DXMT_ENABLE_NVEXT", "1", 1)
            setenv("DXMT_WSI_MONITOR_IDENTITY", "1", 1)
            setenv("DXMT_WSI_MODE_TABLE", "1", 1)
        } else {
            unsetenv("DXMT_ENABLE_NVEXT")
            unsetenv("DXMT_WSI_MONITOR_IDENTITY")
            unsetenv("DXMT_WSI_MODE_TABLE")
        }
        // Fastsync's per-game switches, only when Settings chose Fastsync; with Madsync
        // (the default) or Wine's standard sync nothing is exported here.
        if SyncEngine.current == .fastsync {
            let mode = MadeiraConfig.get("env.MADEIRA_FASTSYNC") ?? "auto"
            setenv("MADEIRA_FASTSYNC", fastSync == false ? "0" : mode, 1)
            // Only a game's own choice; otherwise madeira.cfg's env.MADEIRA_FASTSYNC_SEM applies.
            if let sem = semaphoreFastPath { setenv("MADEIRA_FASTSYNC_SEM", sem ? "1" : "0", 1) }
            else { unsetenv("MADEIRA_FASTSYNC_SEM") }
        }
        madeira_set_vsync_locked(effectiveFPSMode)
        // This game's own lines; a launch without any unsets the previous game's.
        do {
            let pairs = try MadeiraConfig.applyGame(gameConfigText)
            if !pairs.isEmpty {
                LogStore.shared.log("[game-cfg] " + pairs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            }
        } catch {
            LogStore.shared.log("[game-cfg] this game's config could not be written: \(error.localizedDescription)")
        }
        fputs("[frontend] launch profile applied\n", stderr)
        if usesLaunchOptions {
            fputs("[library] ml1163 start=\(runsInDesktop ? "desktop" : "direct") batch=\(isBatch ? 1 : 0) services=\(servicesScript != nil ? 1 : 0) cwd=\(launchDirectory)\n", stderr)
        }
        LogStore.shared.log("[display-shape] resolution=\(resolution) mode=\(displayMode.rawValue)")
    }

    /// What the bridge starts. Set on the main thread before the session begins.
    func configureLaunch() {
        // "The game"'s identity and the launch's working folder, for this launch only
        // (the bridge reads and clears them); every other launch starts without them.
        unsetenv("MADEIRA_STEAM_APPID"); unsetenv("MADEIRA_STEAM_APPPATH"); unsetenv("MADEIRA_WORKDIR"); unsetenv("MADEIRA_NO_STEAM_IDENTITY")
        if steamAppID != nil {
            // A Steam game through Madeira Dock: Dock has set what starts (ContentView.startDock);
            // the virtual monitor follows this entry's Resolution, as below. "The game" starts
            // its own program below, like any library game.
            if !startsSteamGameDirectly {
                GuestDisplay.configureSessionDefault(view: CGSize(width: 1280, height: 720), knob: resolution)
                return
            }
        }
        if bigPicture == true { Self.writeBigPictureBatch() }   // ml2021: the batch the desktop-mode launch runs
        let parent = desktop == true ? nil : epicParent
        let command = desktop == true ? (exe: "explorer.exe", args: launchArguments) : launchCommand(parent: parent)
        if parent != nil { fputs("[epic-parent] ml2320 the game starts as EpicGamesLauncher.exe's child\n", stderr) }
        setenv("MADEIRA_EXE", command.exe, 1)
        setenv("MADEIRA_ARGS", LaunchArgumentText.plain(command.args), 1)
        // Export both choices: unsetting Directly lets a global env.MADEIRA_DESKTOP=1
        // turn the desktop back on when the bridge applies madeira.cfg.
        setenv("MADEIRA_DESKTOP", desktop == true || runsInDesktop ? "1" : "0", 1)
        if startsSteamGameDirectly, let steamAppID {
            // The game's own Steam identity (SteamAppId, SteamGameId, SteamAppPath = its install
            // folder) instead of the bridge's fixed one.
            setenv("MADEIRA_STEAM_APPID", String(steamAppID), 1)
            setenv("MADEIRA_STEAM_APPPATH", windowsPath, 1)
        }
        // ml2310: a game from another store is not a Steam game. With the bridge's fixed Steam
        // identity its launcher took its Steam path and failed; env.MADEIRA_STORE_STEAM_IDENTITY=1
        // publishes it as before.
        if epicAppName != nil, MadeiraConfig.get("env.MADEIRA_STORE_STEAM_IDENTITY") != "1" {
            setenv("MADEIRA_NO_STEAM_IDENTITY", "1", 1)
        }
        // ml1163: a game starts in launchDirectory (a chosen folder, Steam's for "The game",
        // else the program's own). It is exported when the bridge's default, the folder of
        // what it starts, differs: explorer.exe (desktop mode) and cmd.exe (a .bat, the
        // services batch) live elsewhere. The Desktop entry keeps explorer's default.
        if desktop != true, launchDirectory != Self.folder(of: command.exe) {
            setenv("MADEIRA_WORKDIR", launchDirectory, 1)
        }
        // Every session's virtual monitor takes this entry's Resolution
        // (MADEIRA_SCREEN_W/H, source "knob"); for the Desktop entry it is the
        // same size as its /desktop= argument.
        GuestDisplay.configureSessionDefault(view: CGSize(width: 1280, height: 720), knob: resolution)
    }
}

/// Writes madeira-library.json.
enum LibraryFileWriter {
    private struct Document: Codable { var version: Int; var entries: [LibraryEntry] }

    static func encode(_ entries: [LibraryEntry], to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(version: 1, entries: entries)).write(to: file, options: .atomic)
    }
}

final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()
    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    /// drive_c with its symlinks resolved.
    static var drive: URL {
        documents.appendingPathComponent("wine/drive_c", isDirectory: true).resolvingSymlinksInPath()
    }
    @Published var enabled = false
    @Published var entries: [LibraryEntry] = []
    @Published var current: UUID?
    @Published var activeEntry: LibraryEntry?
    @Published var menu = false { didSet { if menu != oldValue { LogTrail.inGameMenu(menu) } } }
    @Published var performance = false
    @Published var liveLogs = false
    @Published var fpsMode = 1
    /// The session's controller mode (LibraryEntry.controllerMode): "keys" or nil.
    @Published var controllerMode: String? {
        didSet { if oldValue != controllerMode { applyControllerMode() } }
    }
    /// The session's binds table (LibraryEntry.controllerBinds); a change rebuilds
    /// the driver's bindings at once, so the binds page is live.
    @Published var controllerBinds: [String: ControlAction] = [:] {
        didSet { if oldValue != controllerBinds { applyControllerMode() } }
    }
    /// The session's right-stick mouse vertical speed (LibraryEntry.padMouseVertical).
    @Published var padMouseVertical: Double = 1 {
        didSet { if oldValue != padMouseVertical { applyControllerMode() } }
    }
    /// The session's gyro aim and turbo (LibraryEntry.padAssist); the pad sampler takes a change at once.
    @Published var padAssist: PadAssistSettings? {
        didSet { if oldValue != padAssist { GamepadInput.shared.setPadAssist(current == nil ? nil : padAssist) } }
    }
    /// The session's touch-control opacity (the entry's Control opacity).
    @Published var opacity = 0.7
    /// The session's Aspect & scaling; MetalBackedView lays the game out with it.
    @Published var displayMode = DisplayMode.fit {
        didSet { if displayMode != oldValue { MetalBackedView.refreshDisplayMode(reason: "mode-toggle") } }
    }
    @Published var error: String? { didSet { if error != nil { preparing = nil } } }
    @Published var sessionMessage = ""
    private var smallPoolNoted = false
    /// The session's JIT pool ran out and was checked (JITPoolAuto); the game whose config got the lines.
    private var poolAutoChecked = false
    private var poolAutoTitle: String?
    /// Quit game was asked for and the program is still running after `forceCloseAfter`
    /// seconds: a frozen program never handles Alt+F4, so the menu offers to close Madeira.
    @Published var forceCloseOffered = false
    static let forceCloseAfter: TimeInterval = 10
    /// A Dock session whose game ended: Madeira Dock shut Valve's client down, and
    /// explorer's desktop is asked to close so the session returns to the library.
    /// Close Madeira is offered if the session is still up `forceCloseAfter` seconds later.
    @Published var dockGameEnded = false
    private var dockGameEndedAt: Date?
    private var quitRequestedAt: Date?
    @Published var launching = false
    @Published var overlayFields = ["FPS", "Frame time", "RAM", "Battery"]
    private var launchPresent: UInt64 = 0
    private var launchSurface: UInt64 = 0
    private var launchStarted = Date()
    /// Read by the starting screen for its elapsed-time line.
    var launchStartedAt: Date { launchStarted }
    @Published var launchSlow = false
    @Published var launchLogs = false
    private var launchDismissLogged = false
    var menuButtonRect = CGRect.zero
    var performanceRect = CGRect.zero
    /// The in-game menu and the starting screen take every touch.
    var blocksGameplayTouch: Bool { preparing != nil || (current != nil && (menu || launching)) }
    private var timer: Timer?
    private var sawProcess = false
    // Why a session ended by itself (not Quit): the program the app launched
    // exited with a Windows error (wine_crash_exit_status, WineProcessBridge.m).
    // MADEIRA_EXIT_REPORT=0 returns to the library without a message.
    private var quitRequested = false
    private func exitReport() -> String? {
        guard !quitRequested, MadeiraConfig.flag("MADEIRA_EXIT_REPORT") else { return nil }
        var status: UInt32 = 0
        guard wine_crash_exit_status(&status) != 0 else { return nil }
        LogStore.shared.log("[exit-report] status=0x\(String(status, radix: 16))")
        let kind = status == 0xC0000005 ? " (memory access violation)" : status == 0xC0000017 ? " (out of memory)" : ""
        return "The game stopped with Windows error 0x\(String(status, radix: 16, uppercase: true))\(kind). Export the diagnostic log to report it."
    }
    /// A game in a Madeira Dock session asked Steam to start another game (steam://run/<App ID>;
    /// ntdll refused steam.exe and reported it, WineProcessBridge.m): the next app run starts that
    /// game (NextSteamApp), since a second session cannot start in this one. Black Ops II's
    /// campaign does this when the player chooses Zombies.
    private func steamRunRequest() -> String? {
        var appID: UInt32 = 0
        guard !quitRequested, wine_steam_run_request(&appID) != 0 else { return nil }
        let id = Int(appID)
        let name = entries.first { $0.steamAppID == id }?.title
            ?? MadeiraDock.games(drive: MadeiraDock.drive).first { $0.id == id }?.name
        LogStore.shared.log("[dock-steam-run] the game asked Steam to start app \(id)\(name == nil ? ", which is not installed" : "")")
        guard let name else { return nil }
        NextSteamApp.set(id)
        return "The game asked to start \(name). Madeira runs one game per app session: close Madeira and open it again, and \(name) starts by itself."
    }
    /// The program the library started ended while a steam.exe it started still ran,
    /// outside a Madeira Dock session: the game only runs when Steam starts it
    /// (SteamAPI_RestartAppIfNecessary). Slay the Spire 2 on "Start with: The game" does
    /// this. env.MADEIRA_STEAM_NEEDED_HINT = 0 leaves the old quiet return to the library.
    private func steamNeededHint() -> SteamNeededHint? {
        guard !quitRequested, MadeiraConfig.flag("MADEIRA_STEAM_NEEDED_HINT"), wine_handed_to_steam() != 0,
              let entry = activeEntry, entry.desktop != true,
              entry.steamAppID == nil || entry.startsSteamGameDirectly else { return nil }
        LogStore.shared.log("[steam-needed] \(entry.title) handed itself to Steam; hint shown")
        if entry.startsSteamGameDirectly {
            return SteamNeededHint(id: entry.id, message: L("This game only runs when Steam starts it. Switch it to Madeira Dock, then start it again."),
                                   canSwitch: true)
        }
        return SteamNeededHint(id: entry.id, message: L("This game only runs when Steam starts it. Start it from your Steam games in the library instead of as its own program."),
                               canSwitch: false)
    }
    /// The alert's "Use Madeira Dock": the Steam game starts through Madeira Dock again.
    func useMadeiraDock(_ id: UUID) {
        guard var entry = entries.first(where: { $0.id == id }), entry.startsSteamGameDirectly else { return }
        entry.steamStart = nil
        save(entry)
        LogStore.shared.log("[steam-needed] \(entry.title): Start with set back to Madeira Dock")
    }
    private var readOnly = false
    private var metadataInFlight = Set<UUID>()
    /// Entries whose scan result waits for the scroll to end (a card that reappears meanwhile does not scan again).
    private var steamMetadataInFlight = Set<Int>()
    private var savedControls: [TouchControl] = []
    private var savedLayout: String?
    private var savedZones: [GestureZone] = []
    private var savedVisible = true
    private var savedSize = 1.0
    /// The session's first frame makes the drawable's shape known (Aspect).
    private var laidOutAfterFirstPresent = false
    private struct Document: Codable { var version: Int; var entries: [LibraryEntry] }
    private var file: URL { Self.documents.appendingPathComponent("madeira-library.json") }

    private init() {
        refreshFlag()
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let doc = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
                guard doc.version == 1 else { throw LibraryError.message("This library uses a newer format.") }
                entries = doc.entries
            } catch {
                readOnly = true
                self.error = "Library could not be opened. The original file was preserved. " + error.localizedDescription
            }
        }
        resetPhoneResolution()
        applyRecommendations()
    }

    /// madeira-bcd: games already in the library get Madeira's recommended settings
    /// when they are due (GameRecommendationsApply.swift); the entries' own fields
    /// are saved here.
    private func applyRecommendations() {
        guard !readOnly else { return }
        var next = entries
        var changed = false
        for i in next.indices {
            if GameRecommendations.prepare(&next[i]) { changed = true }
        }
        if changed { persist(next) }
    }

    /// ml1172: every new entry used to get 1408x648, a 19.5:9 phone's shape.
    /// On a screen of another shape (an iPad: a third of it black in Fit)
    /// those entries are reset once to this device's default. Nothing tells a
    /// deliberate 1408x648 from the old default, so a game set to it on purpose
    /// is reset too; on a 19.5:9 iPhone nothing changes.
    private func resetPhoneResolution() {
        let key = "madeira.ml1172.resolution-reset"
        guard !readOnly, !UserDefaults.standard.bool(forKey: key) else { return }
        let phone = "1408x648"
        let reset = ResolutionChoices.fills(1408, 648) ? 0 : entries.filter { $0.resolution == phone }.count
        if reset > 0 {
            var next = entries
            for i in next.indices where next[i].resolution == phone { next[i].resolution = ResolutionChoices.defaultValue }
            guard persist(next) else { return }   // try again at the next start
        }
        UserDefaults.standard.set(true, forKey: key)
        LogStore.shared.log("[library] ml1172 resolution default \(ResolutionChoices.defaultValue); \(reset) entries reset from \(phone)")
    }

    func refreshFlag() {
        guard current == nil, wine_process_is_running() == 0 else { return }
        // Fixed for the whole run (FrontendChoice); a change applies at the next start.
        let allowed = FrontendChoice.startup.useNew
        if enabled != allowed { fputs("[frontend] library enabled=\(allowed ? 1 : 0)\n", stderr) }
        enabled = allowed
        LibraryController.shared.configure(enabled: allowed, ownsInput: allowed)
    }

    func save(_ entry: LibraryEntry) {
        guard !readOnly else { error = "The library file could not be read. Preserve or repair it before making changes."; return }
        var next = entries
        var entry = entry
        // madeira-bcd: a game seen for the first time gets Madeira's recommended settings
        // (GameRecommendationsApply.swift): a finished Steam download, a new or saved entry.
        let isNew = !next.contains { $0.id == entry.id || (entry.steamAppID != nil && $0.steamAppID == entry.steamAppID) }
        GameRecommendations.prepare(&entry, new: isNew)
        // A Steam game has one entry: a details page opened before its card first saved
        // one (refreshSteamMetadata) updates that entry.
        if let i = next.firstIndex(where: { $0.id == entry.id }) ??
            next.firstIndex(where: { entry.steamAppID != nil && $0.steamAppID == entry.steamAppID }) ??
            next.firstIndex(where: { entry.gogProductID != nil && $0.gogProductID == entry.gogProductID }) ??
            next.firstIndex(where: { entry.itchGameID != nil && $0.itchGameID == entry.itchGameID }) ??
            next.firstIndex(where: { entry.epicAppName != nil && $0.epicAppName == entry.epicAppName }) ??
            next.firstIndex(where: { entry.eaOfferID != nil && $0.eaOfferID == entry.eaOfferID }) {
            // A details sheet may predate an asynchronous metadata refresh.
            if (next[i].metadataChecked ?? .distantPast) > (entry.metadataChecked ?? .distantPast) {
                entry.folderBytes = next[i].folderBytes; entry.graphicsAPI = next[i].graphicsAPI
                entry.bits = next[i].bits; entry.steamMetadataInstall = next[i].steamMetadataInstall
                entry.metadataChecked = next[i].metadataChecked
                entry.metadataRevision = next[i].metadataRevision
            }
            next[i] = entry
        } else { next.append(entry) }
        persist(next)
    }
    func remove(_ id: UUID) {
        persist(entries.filter { $0.id != id })
    }
    /// A Steam game's library entry, which holds its per-game settings
    /// (SteamGames.swift). A game without one gets a new entry made from what
    /// Steam installed; it is saved when its details page closes or it is
    /// played. An existing entry follows the install folder Steam records.
    func steamEntry(_ game: DockGame, title: String? = nil) -> LibraryEntry {
        let folder = game.library + "/common/" + game.installDir
        if var entry = entries.first(where: { $0.steamAppID == game.id }) {
            entry.relativePath = folder
            return entry
        }
        var entry = LibraryEntry(title: title ?? game.name, relativePath: folder, bits: 0)
        entry.steamAppID = game.id
        entry.folderBytes = SteamInstallFiles.sizeOnDisk(appID: game.id, steamApps: Self.drive.appendingPathComponent(game.library, isDirectory: true))
        return entry
    }
    /// A Steam download finished (SteamOwnedLibrary): the game gets its library
    /// entry, or an existing one keeps its title, artwork and settings.
    func upsertSteam(_ game: DockGame, title: String) {
        guard !readOnly else { return }
        var entry = steamEntry(game, title: title)
        entry.folderBytes = SteamInstallFiles.sizeOnDisk(appID: game.id, steamApps: Self.drive.appendingPathComponent(game.library, isDirectory: true)) ?? entry.folderBytes
        save(entry)
    }
    /// A Steam game was uninstalled: its entry goes with its files.
    func removeSteam(appID: Int) {
        guard entries.contains(where: { $0.steamAppID == appID }) else { return }
        persist(entries.filter { $0.steamAppID != appID })
    }
    /// A store's cover art as a JPEG of at most 1200 pixels, or nil.
    static func storeCover(_ url: URL) async -> Data? {
        guard url.scheme == "https", let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                             kCGImageSourceThumbnailMaxPixelSize: 1200,
                                                                             kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85)
    }
    /// A GOG download finished (GOGLibrary): the game gets its library entry, or an
    /// existing one follows the new build's program and keeps its title, artwork and
    /// settings. Arguments and working folder follow GOG's play task unless the player
    /// changed them. A new entry gets GOG's cover art as its cover image.
    @MainActor
    func upsertGOG(_ game: GOGInstalledGame, previous: GOGInstalledGame?, cover: URL?) async {
        guard !readOnly else { return }
        let existing = entries.first { $0.gogProductID == game.productID }
        var entry = existing ?? LibraryEntry(title: game.title, relativePath: game.programPath, bits: 0)
        entry.gogProductID = game.productID
        entry.relativePath = game.programPath
        entry.folderBytes = game.installBytes
        if existing == nil || entry.arguments == (previous?.arguments ?? "") { entry.arguments = game.arguments }
        if existing == nil || entry.workingDirectory == previous?.workingWindowsPath { entry.workingDirectory = game.workingWindowsPath }
        let program = Self.drive.appendingPathComponent(game.programPath)
        if let inspected = await Task.detached(priority: .utility, operation: { try? LibraryModel.inspect(program) }).value {
            entry.bits = inspected.bits
            entry.graphicsAPI = inspected.graphicsAPI ?? entry.graphicsAPI
        }
        if entry.coverFile == nil, let cover, let jpeg = await Self.storeCover(cover) {
            let dir = Self.documents.appendingPathComponent("madeira-art", isDirectory: true)
            let name = entry.id.uuidString + ".jpg"
            if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
               (try? jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil {
                entry.coverFile = name
            }
        }
        entry.metadataChecked = nil
        save(entry)
    }
    /// A GOG game was uninstalled: its entry goes with its files.
    func removeGOG(productID: String) {
        guard entries.contains(where: { $0.gogProductID == productID }) else { return }
        persist(entries.filter { $0.gogProductID != productID })
    }
    /// An itch.io download finished (ItchLibrary): the game gets its library entry, or an
    /// existing one follows the new program and keeps its title, artwork and settings.
    /// A new entry gets itch.io's cover art as its cover image. While its program is an
    /// installer (ItchSetup), the entry starts in the Wine desktop with Windows services
    /// first; once the installer has installed the game, it starts directly again.
    @MainActor
    func upsertItch(_ game: ItchInstalledGame, cover: URL?, setupFinished: Bool = false) async {
        guard !readOnly else { return }
        var entry = entries.first { $0.itchGameID == game.gameID } ?? LibraryEntry(title: game.title, relativePath: game.programPath, bits: 0)
        entry.itchGameID = game.gameID
        entry.relativePath = game.programPath
        if game.setup != nil {
            entry.launchMode = "desktop"; entry.startServices = true
        } else if setupFinished {
            entry.launchMode = nil; entry.startServices = nil
        }
        entry.folderBytes = game.installBytes
        let program = Self.drive.appendingPathComponent(game.programPath)
        if let inspected = await Task.detached(priority: .utility, operation: { try? LibraryModel.inspect(program) }).value {
            entry.bits = inspected.bits
            entry.graphicsAPI = inspected.graphicsAPI ?? entry.graphicsAPI
        }
        if entry.coverFile == nil, let cover, let jpeg = await Self.storeCover(cover) {
            let dir = Self.documents.appendingPathComponent("madeira-art", isDirectory: true)
            let name = entry.id.uuidString + ".jpg"
            if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
               (try? jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil {
                entry.coverFile = name
            }
        }
        entry.metadataChecked = nil
        save(entry)
    }
    /// An itch.io game was uninstalled: its entry goes with its files.
    func removeItch(gameID: Int) {
        guard entries.contains(where: { $0.itchGameID == gameID }) else { return }
        persist(entries.filter { $0.itchGameID != gameID })
    }
    /// An EA download finished (EALibrary): the game gets its library entry, or an
    /// existing one follows the new build's program and keeps its title, artwork and
    /// settings. Arguments follow the build's manifest unless the player changed them.
    /// A new entry gets EA's cover art as its cover image.
    @MainActor
    func upsertEA(_ game: EAInstalledGame, previous: EAInstalledGame?, cover: URL?) async {
        guard !readOnly else { return }
        let existing = entries.first { $0.eaOfferID == game.offerID }
        var entry = existing ?? LibraryEntry(title: game.title, relativePath: game.programPath, bits: 0)
        entry.eaOfferID = game.offerID
        entry.relativePath = game.programPath
        entry.folderBytes = game.installBytes
        if existing == nil || entry.arguments == (previous?.arguments ?? "") { entry.arguments = game.arguments }
        let program = Self.drive.appendingPathComponent(game.programPath)
        if let inspected = await Task.detached(priority: .utility, operation: { try? LibraryModel.inspect(program) }).value {
            entry.bits = inspected.bits
            entry.graphicsAPI = inspected.graphicsAPI ?? entry.graphicsAPI
        }
        if entry.coverFile == nil, let cover, let jpeg = await Self.storeCover(cover) {
            let dir = Self.documents.appendingPathComponent("madeira-art", isDirectory: true)
            let name = entry.id.uuidString + ".jpg"
            if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
               (try? jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil {
                entry.coverFile = name
            }
        }
        entry.metadataChecked = nil
        save(entry)
    }
    /// An EA game was uninstalled: its entry goes with its files.
    func removeEA(offerID: String) {
        guard entries.contains(where: { $0.eaOfferID == offerID }) else { return }
        persist(entries.filter { $0.eaOfferID != offerID })
    }
    /// An Epic download finished (EpicLibrary): the game gets its library entry, or an
    /// existing one follows the new build's program and keeps its title, artwork and
    /// settings. A new entry gets Epic's cover art as its cover image.
    @MainActor
    func upsertEpic(_ game: EpicInstalledGame, cover: URL?) async {
        guard !readOnly else { return }
        var entry = entries.first { $0.epicAppName == game.appName } ?? LibraryEntry(title: game.title, relativePath: game.programPath, bits: 0)
        entry.epicAppName = game.appName
        entry.relativePath = game.programPath
        entry.folderBytes = game.installBytes
        let program = Self.drive.appendingPathComponent(game.programPath)
        if let inspected = await Task.detached(priority: .utility, operation: { try? LibraryModel.inspect(program) }).value {
            entry.bits = inspected.bits
            entry.graphicsAPI = inspected.graphicsAPI ?? entry.graphicsAPI
        }
        if entry.coverFile == nil, let cover, let jpeg = await Self.epicCover(cover) {
            let dir = Self.documents.appendingPathComponent("madeira-art", isDirectory: true)
            let name = entry.id.uuidString + ".jpg"
            if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
               (try? jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil {
                entry.coverFile = name
            }
        }
        entry.metadataChecked = nil
        save(entry)
    }
    /// Epic's cover art as a JPEG of at most 1200 pixels, or nil.
    private static func epicCover(_ url: URL) async -> Data? {
        guard url.scheme == "https", let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                             kCGImageSourceThumbnailMaxPixelSize: 1200,
                                                                             kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85)
    }
    /// An Epic game was uninstalled: its entry goes with its files.
    func removeEpic(appName: String) {
        guard entries.contains(where: { $0.epicAppName == appName }) else { return }
        persist(entries.filter { $0.epicAppName != appName })
    }
    /// Publishes `next` and writes it.
    @discardableResult
    private func persist(_ next: [LibraryEntry]) -> Bool {
        guard !readOnly else { return false }
        do {
            try LibraryFileWriter.encode(next, to: file)
            entries = next
            return true
        } catch { self.error = "Could not save the library: " + error.localizedDescription; return false }
    }

    /// Install size and graphics API, at most once a day per entry.
    @MainActor
    func refreshMetadata(_ id: UUID) async {
        let revision = 12
        guard !metadataInFlight.contains(id), let entry = entries.first(where: { $0.id == id }), entry.desktop != true,
              entry.metadataRevision != revision || Date().timeIntervalSince(entry.metadataChecked ?? .distantPast) > 86400,
              let url = try? Self.executable(entry.relativePath) else { return }
        metadataInFlight.insert(id)
        defer { metadataInFlight.remove(id) }
        let result = await LibraryMetadataScanner.shared.scan(url, drive: Self.drive)
        guard !Task.isCancelled, var updated = entries.first(where: { $0.id == id }) else { return }
        updated.folderBytes = result.bytes
        if let api = result.api { updated.graphicsAPI = api }
        updated.metadataChecked = Date(); updated.metadataRevision = revision
        save(updated)
        fputs("[library-metadata] install scan api=\(updated.graphicsAPI ?? "unknown") bytes=\(result.bytes ?? -1)\n", stderr)
    }

    /// An installed Steam game's library pills (SteamGames.swift): 32-bit or 64-bit and
    /// the graphics API of the program "Start with: The game" would start
    /// (SteamDirectStart.program), and the install size from Steam's install record.
    /// Read off the main thread once per install folder, build and picked program
    /// (again when Steam's launch configuration arrives, or after a day while no
    /// program is known) and kept on the game's entry.
    @MainActor
    func refreshSteamMetadata(_ game: DockGame, title: String) async {
        let revision = 1
        guard !readOnly, game.installed, !steamMetadataInFlight.contains(game.id) else { return }
        steamMetadataInFlight.insert(game.id)
        defer { steamMetadataInFlight.remove(game.id) }
        let drive = Self.drive
        let folder = game.library + "/common/" + game.installDir
        let root = drive.appendingPathComponent(folder, isDirectory: true)
        let steamApps = drive.appendingPathComponent(game.library, isDirectory: true)
        let record = await Task.detached(priority: .utility) {
            (build: SteamInstallFiles.buildID(appID: game.id, steamApps: steamApps),
             size: SteamInstallFiles.sizeOnDisk(appID: game.id, steamApps: steamApps))
        }.value
        let stored = entries.first { $0.steamAppID == game.id }
        let picked = stored?.steamProgramSource == "choice" ? stored?.steamProgram : nil
        let known = SteamOwnedLibrary.shared.game(game.id)?.launches != nil
        let install = "\(folder)#\(record.build ?? 0)#\(picked ?? "")#\(known ? 1 : 0)"
        if let stored, stored.steamMetadataInstall == install, stored.metadataRevision == revision,
           stored.bits != 0 || Date().timeIntervalSince(stored.metadataChecked ?? .distantPast) < 86400 { return }
        // Steam's launch configuration is asked for only when no picked program is installed.
        let kept = await Task.detached(priority: .utility) { picked.flatMap { SteamDirectStart.onDisk($0, in: root, directory: false) } }.value
        let options = kept == nil ? await SteamOwnedLibrary.shared.launchOptions(appID: game.id) : nil
        let program = await Task.detached(priority: .utility) { () -> (url: URL, bits: Int, api: String?)? in
            guard let path = SteamDirectStart.program(picked: kept, options: options, installFolder: root),
                  let inspected = try? LibraryModel.inspect(root.appendingPathComponent(path)) else { return nil }
            return (root.appendingPathComponent(path), inspected.bits, inspected.graphicsAPI)
        }.value
        var api = program?.api
        if let program, let scanned = await LibraryMetadataScanner.shared.scan(program.url, drive: drive, countBytes: false).api { api = scanned }
        guard !Task.isCancelled else { return }
        var updated = entries.first { $0.steamAppID == game.id } ?? LibraryEntry(title: title, relativePath: folder, bits: 0)
        updated.steamAppID = game.id
        updated.relativePath = folder
        updated.bits = program?.bits ?? 0
        updated.graphicsAPI = api
        updated.folderBytes = record.size ?? updated.folderBytes
        updated.steamMetadataInstall = install
        updated.metadataChecked = Date(); updated.metadataRevision = revision
        save(updated)
        LogStore.shared.log("[steam-games] metadata app=\(game.id) bits=\(updated.bits) api=\(api ?? "unknown")")
    }

    /// What an entry can start: an executable, or (ml1163) a batch file run through cmd.exe.
    static let programExtensions: Set<String> = ["exe", "bat", "cmd"]
    /// The path relative to drive_c that reaches `url`, or nil when it is
    /// outside drive_c. Files on an external drive are reached through
    /// drive_c/External/<name> (ExternalDrives.swift).
    static func relativeToDrive(_ url: URL) -> String? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix(drive.path + "/") { return String(path.dropFirst(drive.path.count + 1)) }
        for root in ExternalDrives.shared.roots {
            if path == root.path { return "External/" + root.name }
            if path.hasPrefix(root.path + "/") {
                return "External/" + root.name + "/" + path.dropFirst(root.path.count + 1)
            }
        }
        return nil
    }
    static func executable(_ relative: String) throws -> URL {
        let url = drive.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard relativeToDrive(url) != nil, programExtensions.contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.message(L("Choose an executable (.exe, .bat or .cmd) inside drive_c."))
        }
        return url
    }
    static func inspect(_ url: URL) throws -> LibraryEntry {
        guard let relative = relativeToDrive(url) else {
            throw LibraryError.message(L("The executable must be inside drive_c or an external drive."))
        }
        if ["bat", "cmd"].contains(url.pathExtension.lowercased()) {
            // ml1163: a batch file has no PE header. Like every entry it starts
            // directly by default, as upstream starts every game; the details page
            // warns that Wine then stops when cmd.exe, its first process, exits.
            return LibraryEntry(title: url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " "),
                                relativePath: relative, bits: 0)
        }
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        let dos = try h.read(upToCount: 64) ?? Data()
        guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { throw LibraryError.message(L("This is not a Windows executable.")) }
        let offset = (0..<4).reduce(UInt64(0)) { $0 | (UInt64(dos[60 + $1]) << ($1 * 8)) }
        guard offset >= 64, offset < 16 * 1024 * 1024 else { throw LibraryError.message(L("Invalid executable header.")) }
        try h.seek(toOffset: offset)
        let pe = try h.read(upToCount: 6) ?? Data()
        guard pe.count == 6, Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else { throw LibraryError.message(L("Missing PE header.")) }
        let machine = Int(pe[4]) | Int(pe[5]) << 8
        guard machine == 0x14c || machine == 0x8664 else { throw LibraryError.message(L("Only x86 and x64 executables are supported.")) }
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        var entry = LibraryEntry(title: name, relativePath: relative, bits: machine == 0x14c ? 32 : 64)
        entry.graphicsAPI = graphicsImports(url)
        return entry
    }

    // Read the PE import directory, rather than guessing from the executable's name.
    static func apiNames(_ imports: [String]) -> Set<String> {
        var levels = Set<String>()
        for name in imports {
            switch name {
            case "ddraw.dll": levels.insert("DirectDraw")
            case "d3d8.dll": levels.insert("D3D8")
            case "d3d9.dll": levels.insert("D3D9")
            case "d3d10.dll", "d3d10_1.dll": levels.insert("D3D10")
            case "d3d11.dll": levels.insert("D3D11")
            case "d3d12.dll": levels.insert("D3D12")
            case "opengl32.dll": levels.insert("OpenGL")
            case "vulkan-1.dll": levels.insert("Vulkan")
            default: break
            }
        }
        return levels
    }
    static func graphicsImports(_ url: URL) -> String? {
        let levels = apiNames(importNames(url))
        return levels.isEmpty ? nil : levels.sorted().joined(separator: " / ")
    }
    static func importNames(_ url: URL) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data {
            do { try h.seek(toOffset: offset); return try h.read(upToCount: count) ?? Data() } catch { return Data() }
        }
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { return 0 }
            return (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        let dos = read(0, 64); guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { return [] }
        let base = UInt64(u32(dos, 60)); guard base < 16 * 1024 * 1024 else { return [] }
        let header = read(base, 264); guard header.count == 264, u32(header, 0) == 0x4550 else { return [] }
        let sections = Int(header[6]) | Int(header[7]) << 8
        let optSize = Int(header[20]) | Int(header[21]) << 8
        guard sections <= 96, optSize >= 120 else { return [] }
        let pe64 = header[24] == 0x0b && header[25] == 2
        guard header[24] == 0x0b, header[25] == 1 || pe64 else { return [] }
        let imports = u32(header, pe64 ? 144 : 128)
        let delayed = optSize >= (pe64 ? 224 : 208) ? u32(header, pe64 ? 240 : 224) : 0
        let table = read(base + 24 + UInt64(optSize), sections * 40)
        func fileOffset(_ rva: UInt32) -> UInt64? {
            guard table.count == sections * 40 else { return nil }
            for index in 0..<sections {
                let i = index * 40, va = u32(table, index * 40 + 12), size = u32(table, index * 40 + 16)
                if rva >= va, rva - va < size { return UInt64(u32(table, i + 20)) + UInt64(rva - va) }
            }
            return nil
        }
        var names: [String] = []
        for (rva, stride, nameField) in [(imports, 20, 12), (delayed, 32, 4)] {
            guard rva != 0, let start = fileOffset(rva) else { continue }
            for i in 0..<256 {
                let descriptor = read(start + UInt64(i * stride), stride)
                guard descriptor.count == stride else { break }
                var nameRVA = u32(descriptor, nameField); if nameRVA == 0 { break }
                if stride == 32 && u32(descriptor, 0) & 1 == 0 {
                    let imageBase = u32(header, 52)
                    guard !pe64, nameRVA >= imageBase else { continue }
                    nameRVA -= imageBase
                }
                guard let offset = fileOffset(nameRVA) else { continue }
                let data = read(offset, 128)
                let name = String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self).lowercased()
                names.append(name)
            }
        }
        return names
    }

    // MARK: session

    /// Wine sessions started in this app run. A second one cannot start in the
    /// same process: the wineserver's permanent objects from the first session
    /// are still there and init_registry aborts on "\Registry". Madeira asks for
    /// a restart instead. MADEIRA_ONE_SESSION_PER_RUN=0 lets the launch go ahead.
    static var sessionsThisRun = 0
    static let restartMessage = L("Restart Madeira to start another game: swipe Madeira away in the app switcher, then open it again.")
    @Published var restartNotice: String? { didSet { if restartNotice != nil { preparing = nil } } }
    /// A session of one-time installs (DockInstallers.installsOnly) has ended its batch and
    /// its registry is on disk (MadeiraDockModel.watchReport): the starting screen shows Close
    /// Madeira beside the live log, so the restart it asks for does not depend on the alert.
    @Published var installsRestartReady = false
    /// A Steam game started without Madeira Dock handed itself to Steam and quit
    /// (wine_handed_to_steam, WineProcessBridge.m): the alert says to start it through
    /// Madeira Dock, and offers to switch a Steam game's Start with back to it.
    struct SteamNeededHint: Identifiable, Equatable {
        let id: UUID          // the library entry
        let message: String
        let canSwitch: Bool   // a Steam game on "Start with: The game"
    }
    @Published var steamNeeded: SteamNeededHint? { didSet { if steamNeeded != nil { preparing = nil } } }
    /// The JIT pool ran out while the starting screen was up (JITPoolAuto): the start has
    /// failed, so the starting screen says so in plain words at once and offers Close
    /// Madeira, which keeps the game (NextLibraryGame) so the next app run starts it.
    @Published var poolRestartNote: String?
    private var poolRestartEntry: UUID?
    /// CS_DEBUGGED is set but no debugger is attached (JIT was enabled outside
    /// Madeira): the text of the alert that offers Madeira's own Enable JIT.
    @Published var jitNotice: String? { didSet { if jitNotice != nil { preparing = nil } } }
    /// Play is enabling JIT before starting this entry (ContentView.jitReadyForLaunch):
    /// its Play button reads Starting JIT, with a spinner, until JIT is on or fails.
    @Published var startingJIT: UUID?
    /// A Play still enabling JIT or getting its start ready: the starting screen is up
    /// for it before the session begins (LibraryHUD), so the press goes straight to it.
    @Published var preparing: LibraryEntry?
    private var preparingSince = Date()
    /// The starting screen is up: a session starting, or a Play getting ready.
    var startingScreen: Bool { launching || preparing != nil }
    var startingEntry: LibraryEntry? { launching ? activeEntry : preparing }
    /// When the starting screen went up, for its elapsed-time line.
    var startingSince: Date { launching ? launchStarted : preparingSince }
    /// The game whose Play was held by the one-session rule. The alert's Close Madeira
    /// keeps it (NextLibraryGame), and the next app run starts it by itself, so the
    /// player does not have to find it and press Play again after reopening Madeira.
    /// Set only by holdForRestart; the alert's Later clears it (Close Madeira exits).
    var restartEntry: UUID?
    /// Play was held because a session already ran in this app run: the Restart Madeira
    /// alert, naming the game that starts by itself once Madeira is open again.
    func holdForRestart(_ entry: LibraryEntry?) {
        guard let entry else { restartNotice = Self.restartMessage; return }
        restartNotice = String(format: L("Madeira starts one game each time it is opened. Tap Close Madeira, then open Madeira again: %@ starts by itself."), entry.title)
        restartEntry = entry.id
    }
    func prepare(_ entry: LibraryEntry) {
        guard MadeiraConfig.flag("MADEIRA_LAUNCH_EARLY"), current == nil else { return }   // 0: Play keeps the Game details page up until the session begins
        preparingSince = Date(); preparing = entry
        // The starting screen draws in the controls window (LibraryHUD), which otherwise
        // only comes up with the session's game view.
        TouchControlsHost.attach()
        let id = entry.id
        // A start that neither begins nor reports an error lets the screen go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            if let self, self.preparing?.id == id, self.current == nil { self.preparing = nil }
        }
    }
    /// A Steam game's saves may not be the latest (SteamOwnedLibrary.cloudHold):
    /// the alert Play shows before starting it.
    struct CloudNotice: Equatable {
        enum Kind { case syncing, unchecked, conflict }
        var appID: Int
        var kind: Kind
        var title: String
        var message: String
    }
    @Published var cloudNotice: CloudNotice? { didSet { if cloudNotice != nil { preparing = nil } } }
    /// Starts the game the notice is about again.
    var cloudRetry: (() -> Void)?
    /// The game (App ID) allowed to start once without the check ("Launch anyway").
    var cloudBypass: Int?
    /// The entry whose details page the library should open (the notice's "Choose").
    @Published var showDetail: UUID?

    /// `remember: false` runs a session that is not a library entry (a Madeira
    /// Dock start): it is neither added to the library nor stamped as played.
    /// `dock`: the game a Madeira Dock start launches (DockStartScreen).
    func begin(_ entry: LibraryEntry, remember: Bool = true, dock: DockGame? = nil) {
        wine_exit_status_reset()
        LogTrail.began(entry, dock: dock != nil)
        JITPoolMeter.reset(); smallPoolNoted = false; poolAutoChecked = false; poolAutoTitle = nil; poolRestartNote = nil; poolRestartEntry = nil
        quitRequested = false
 quitRequestedAt = nil; forceCloseOffered = false; dockGameEnded = false; dockGameEndedAt = nil; installsRestartReady = false
        LibraryController.shared.configure(enabled: enabled, ownsInput: false)
        Self.sessionsThisRun += 1
        launchPresent = madeira_frame_count(); launchStarted = Date(); launchSlow = false; launchLogs = entry.liveLogs
        launchSurface = winios_surface_present_count()
        MetalBackedView.presentCountAtLaunch = launchPresent; laidOutAfterFirstPresent = false
        preparing = nil; launching = true; overlayFields = entry.overlayFields ?? ["FPS", "Frame time", "RAM", "Battery"]
        displayMode = entry.displayMode
        activeEntry = entry; current = entry.id; menu = false; performance = entry.performance; liveLogs = entry.liveLogs
        LogStore.shared.setDisplayActive(entry.liveLogs)
        fpsMode = entry.fpsMode; sessionMessage = "Starting…"
        opacity = min(max(entry.controlOpacity ?? 0.7, 0.15), 1)
        let controls = TouchControlsModel.shared
        savedControls = controls.controls; savedVisible = controls.visible; savedSize = controls.sizeScale
        savedLayout = controls.layoutID
        let zones = GestureZonesModel.shared
        savedZones = zones.zones
        if let profile = entry.controls {
            controls.controls = profile
            // A game saved before zones existed takes its layout's zones, if any.
            zones.selected = nil
            zones.zones = entry.zones
                ?? ControlPresetsModel.shared.store.preset(entry.controlLayout ?? "").map(ControlPresetStore.zones(of:))
                ?? []
            // The game's controls come with the layout they were loaded from (if that
            // layout still exists), so a later edit is not written to another game's.
            if ControlPresetsModel.enabled {
                controls.layoutID = ControlPresetsModel.shared.store.resolvedID(entry.controlLayout)
            }
        }
        controls.visible = entry.touchControls
        controls.sizeScale = min(max(entry.controlSize ?? 1, 0.5), 2)
        controllerBinds = GamepadInput.keyboardMouseAvailable ? (entry.controllerBinds ?? [:]) : [:]
        padMouseVertical = GamepadInput.keyboardMouseAvailable ? (entry.padMouseVertical ?? 1) : 1
        controllerMode = GamepadInput.keyboardMouseAvailable ? entry.controllerMode : nil
        applyControllerMode()
        padAssist = entry.padAssist
        GamepadInput.shared.setPadAssist(padAssist)
        MetalHostView.shared.isHidden = false
        ProMotionIntent.apply(mode: entry.effectiveFPSMode)
        ThermalPacing.shared.begin()
        if remember { var played = entry; played.lastPlayed = Date(); save(played) }
        launchDismissLogged = false
        DockStartScreen.shared.begin(dock, at: launchStarted)
        sawProcess = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }
    private func poll() {
        let dockStart = DockStartScreen.shared
        if dockStart.active {
            // A Dock start: the desktop's own frames (explorer, the host's console window)
            // do not end this starting screen; the game's window does (DockStartScreen).
            dockStart.poll(self, rendered: madeira_frame_count() >= launchPresent + 3)
        }
        if dockStart.holding {
            if launching && !launchSlow && Date().timeIntervalSince(launchStarted) > 30 { launchSlow = true }
        } else if launching {
            if madeira_frame_count() >= launchPresent + 3 {
                showGameView(reason: "present")
            } else if winios_surface_present_count() > launchSurface {
                showGameView(reason: "surface")
            } else if Date().timeIntervalSince(launchStarted) > 30 { launchSlow = true }
        }
        // iPadOS gave the JIT pool less room than asked at launch. Without pool-split that is
        // nearly every start (896 MB asked, 560-630 MB given, the main thread's stack splits the
        // band), and most games never need more, so the banner only alarmed players. Off by
        // default: a start that really runs out says "Not enough memory" (poolRestartNote).
        // env.MADEIRA_JIT_SMALL_NOTICE = 1 brings the banner back.
        if !smallPoolNoted, !launching, current != nil, JITPoolMeter.current.shrunk,
           MadeiraConfig.flag("MADEIRA_JIT_SMALL_NOTICE", fallback: false) {
            smallPoolNoted = true
            let words = "JIT memory is small this time (\(JITPoolMeter.current.sizeMB.map { "\($0) MB" } ?? "smaller than usual")). " +
                "Big games may stop loading; closing and reopening Madeira can give more."
            sessionMessage = words
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                if self?.sessionMessage == words { self?.sessionMessage = "" }
            }
        }
        // The JIT pool ran out: a library game gets the bigger-pool lines for its next start.
        if !poolAutoChecked, JITPoolMeter.current.exhausted > 0 {
            poolAutoChecked = true
            if let entry = activeEntry, entry.desktop != true, entries.contains(where: { $0.id == entry.id }) {
                let added = JITPoolAuto.apply(windowsPath: entry.windowsPath, title: entry.title)
                // Still on the starting screen: the game's program or a DLL found no room, so
                // the start has failed. Say so now with Close Madeira, instead of a screen that
                // waits on (Steam's code 45 comes ~10 s later) and an alert only after the session.
                if startingScreen, MadeiraConfig.flag("MADEIRA_JIT_POOL_NOTICE_NOW") {
                    poolRestartEntry = entry.id
                    poolRestartNote = JITPoolAuto.startMessage(entry.title, added: added)
                    LogStore.shared.log("[jit-pool-auto] \(entry.title): the starting screen says so now and offers Close Madeira (\(added ? "lines added" : "no lines added"))")
                } else if added { poolAutoTitle = entry.title }
            }
        }
        if wine_process_is_running() != 0 {
            sawProcess = true
            if sessionMessage == "Starting…" { sessionMessage = "" }
        } else if sawProcess && wineserver_is_running() == 0 { finish() }
        if current != nil, !forceCloseOffered, let asked = quitRequestedAt,
           Date().timeIntervalSince(asked) > Self.forceCloseAfter {
            forceCloseOffered = true
            sessionMessage = L("The game did not close. Open the menu to force-close Madeira.")
            fputs("[frontend] still running \(Int(Self.forceCloseAfter)) s after the close request; force close offered\n", stderr)
        }
        if current != nil, dockGameEndedAt == nil, !launching, DockStartScreen.shared.active,
           MainActor.assumeIsolated({ MadeiraDock.pollReport().result }) == 0 {
            dockGameEndedAt = Date()
            sessionMessage = L("The game has closed. Returning to the library…")
            winios_close_desktop()
            fputs("[frontend] the Dock game ended and Steam shut down; closing the desktop\n", stderr)
        }
        if current != nil, !dockGameEnded, let ended = dockGameEndedAt, Date().timeIntervalSince(ended) > Self.forceCloseAfter {
            dockGameEnded = true; forceCloseOffered = true; menu = true
            sessionMessage = L("The game has closed.")
            fputs("[frontend] the desktop is still up \(Int(Self.forceCloseAfter)) s after the Dock game ended; Close Madeira offered\n", stderr)
        }
        // The first frame gives Aspect and Fill height the drawable's shape.
        if current != nil, !laidOutAfterFirstPresent, madeira_frame_count() != MetalBackedView.presentCountAtLaunch {
            laidOutAfterFirstPresent = true
            MetalBackedView.refreshDisplayMode(reason: "first-present")
        }
    }
    /// `reason`: what stopped the launch, when the caller knows (the JIT pool's failure).
    /// `offerJIT`: the launch failed because no debugger is attached, so the alert
    /// offers Enable JIT instead of only reporting.
    func launchFailed(_ reason: String? = nil, offerJIT: Bool = false) {
        guard current != nil && !sawProcess else { return }
        LogTrail.ending("the start failed" + (reason.map { ": " + LogTrail.clip($0, 100) } ?? ""))
        let entry = activeEntry
        finish()
        if offerJIT, let reason { jitNotice = reason }
        else {
            let words = reason ?? L("The session could not start. Check the diagnostic log and JIT status.")
            if !getHelpInstead(words, entry: entry) { error = words }
        }
    }
    /// (get-help-auto) A launch error opens Get Help by itself (GetHelpView.swift) instead of the
    /// library's OK alert, with the error's words in the report. False when Get Help or its
    /// offer is off, or the game is not known: the alert shows as before.
    private func getHelpInstead(_ words: String, entry: LibraryEntry?) -> Bool {
        guard let entry else { return false }
        return GetHelpCenter.launchError(title: entry.title, windowsPath: entry.windowsPath, error: words, onStartScreen: false)
    }
    /// Both flags change in one transaction without animation: the animated
    /// removal of a scrolling view with live content could leave the starting
    /// screen up (and unresponsive) while the game was already presenting.
    func showGameView(reason: String = "button") {
        if launching && !launchDismissLogged {
            launchDismissLogged = true
            fputs("[launch-view] dismissed reason=\(reason) logs=\(launchLogs ? 1 : 0)\n", stderr)
        }
        LogStore.shared.setDisplayActive(liveLogs)
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { launchLogs = false; launching = false }
    }
    func toggleLaunchLogs() {
        launchLogs.toggle()
        LogStore.shared.setDisplayActive(launching ? launchLogs : liveLogs)
        fputs("[startup-log] visible=\(launchLogs ? 1 : 0)\n", stderr)
    }

    /// Hand the session's mode to the pad sampler. In keyboard-and-mouse mode the
    /// bindings follow the touch layout on screen, so they are rebuilt when the
    /// controls change (TouchControlsModel.controls, observed below).
    func applyControllerMode() {
        guard GamepadInput.keyboardMouseAvailable else { return }
        if current != nil, controllerMode == "keys" {
            GamepadInput.shared.setKeyboardMouse(PadBindings.build(controls: TouchControlsModel.shared.controls, binds: controllerBinds, mouseVertical: padMouseVertical))
            if controlsSink == nil {
                controlsSink = TouchControlsModel.shared.$controls.sink { [weak self] controls in
                    guard let self, self.controllerMode == "keys", self.current != nil else { return }
                    GamepadInput.shared.setKeyboardMouse(PadBindings.build(controls: controls, binds: self.controllerBinds, mouseVertical: self.padMouseVertical))
                }
            }
        } else {
            controlsSink = nil
            GamepadInput.shared.setKeyboardMouse(nil)
        }
    }
    private var controlsSink: AnyCancellable?

    func setFPS(_ mode: Int) {
        fpsMode = mode
        ThermalPacing.shared.userChose()
        let applied = ProMotionIntent.supportedMode(mode)
        madeira_set_vsync_locked(applied)
        ProMotionIntent.apply(mode: applied)
        saveCurrentProfile()
    }
    func showMenu() {
        LibraryKeyboard.hide()
        LibraryController.shared.configure(enabled: enabled, ownsInput: true)
        menu = true
    }
    /// Close Madeira on the starting screen of a finished session of one-time installs: the
    /// same exit as the Restart Madeira alert's Close Madeira (ContentView).
    /// Close Madeira on the starting screen after the JIT pool ran out: the pool is set up
    /// once per app run, so the game's new lines (or a bigger pool) need a fresh run, and
    /// that run starts the game by itself (NextLibraryGame, as the Restart Madeira alert does).
    func closeForPoolRestart() {
        if let id = poolRestartEntry { NextLibraryGame.set(id) }
        LogStore.shared.log("[jit-pool-auto] closed by the user for a restart; the next app run starts the game")
        exit(0)
    }
    func closeForInstallsRestart() {
        LogStore.shared.log("[session-once] closed by the user for a restart (one-time installs finished)")
        exit(0)
    }
    func requestQuit() {
        LibraryKeyboard.hide()
        quitRequested = true
        if quitRequestedAt == nil { quitRequestedAt = Date() }
        // Ask the application to close (Alt+F4) through the normal input queue,
        // so it can save; the surface stays up until the native session ends.
        winios_post_key(0x12, 1); winios_post_key(0x73, 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            winios_post_key(0x73, 0); winios_post_key(0x12, 0)
        }
        sessionMessage = L("Close requested. Confirm any in-game exit dialog.")
        menu = false
        fputs("[frontend] graceful close requested\n", stderr)
    }
    /// Stop on the starting screen, while the start runs or once the Dock stopped: back to
    /// the library at once. The game is asked to close (Alt+F4) and the Wine desktop is
    /// closed, as after a Dock game ends, and the screen does not wait for that: a start
    /// may have no window to take the close, and a second game needs Madeira reopened
    /// anyway (sessionsThisRun), which Play then says.
    func stopStartToLibrary() {
        LogStore.shared.log("[frontend] Stop on the starting screen: closing the game, back to the library")
        LogTrail.ending("Stop on the starting screen")
        requestQuit()
        winios_close_desktop()
        finish()
        // The Wine desktop's view sits on the app window above the library; Wine is still
        // closing, so the ended-session hide (which waits for Wine) would leave it up.
        MainActor.assumeIsolated { EndedSessionSurface.hide(reason: "stopped", whileClosing: true) }   // a button action: main thread
    }
    /// Quit game in the in-game menu: back to the library at once, as Stop does, so the
    /// player never waits on a screen that looks frozen. The game gets the close request
    /// (Alt+F4) and closes behind the library; the desktop closes once a Dock game and
    /// Steam have ended, as before, or `forceCloseAfter` seconds after Quit at the latest.
    func quitToLibrary() {
        LogStore.shared.log("[frontend] Quit game: back to the library; the game closes behind it")
        LogTrail.ending("Quit game")
        let dock = DockStartScreen.shared.active
        requestQuit()
        finish()
        MainActor.assumeIsolated { EndedSessionSurface.hide(reason: "quit", whileClosing: true) }   // a button action: main thread
        let asked = Date()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            MainActor.assumeIsolated {
                if wine_process_is_running() == 0 && wineserver_is_running() == 0 { timer.invalidate(); return }
                let ended = dock && MadeiraDock.pollReport().result == 0
                let late = Date().timeIntervalSince(asked) > Self.forceCloseAfter
                guard ended || late else { return }
                timer.invalidate()
                winios_close_desktop()
                wine_session_quit_asked()   // quit-ends-children
                LogStore.shared.log("[frontend] Quit game: closing the desktop behind the library (\(ended ? "the Dock game ended" : "\(Int(Self.forceCloseAfter)) s after Quit"))")
            }
        }
    }
    func saveCurrentProfile() {
        let controls = TouchControlsModel.shared
        if let id = current, var entry = entries.first(where: { $0.id == id }) {
            entry.controls = controls.controls
            entry.zones = GestureZonesModel.shared.zones
            if ControlPresetsModel.enabled { entry.controlLayout = controls.layoutID }
            entry.touchControls = controls.visible
            entry.fpsMode = fpsMode; entry.performance = performance
            entry.overlayFields = overlayFields
            entry.controlOpacity = opacity; entry.controlSize = controls.sizeScale
            if GamepadInput.keyboardMouseAvailable { entry.controllerMode = controllerMode }
            if GamepadInput.keyboardMouseAvailable { entry.controllerBinds = controllerBinds.isEmpty ? nil : controllerBinds }
            if GamepadInput.keyboardMouseAvailable { entry.padMouseVertical = padMouseVertical == 1 ? nil : padMouseVertical }
            entry.padAssist = padAssist
            // The in-game Aspect & scaling choice sticks to the game. MADEIRA_SESSION_TOOLS=0
            // hides that picker and leaves the stored choice alone.
            if MadeiraConfig.flag("MADEIRA_SESSION_TOOLS") { entry.display = displayMode.rawValue }
            save(entry)
        }
    }
    private func finish() {
        if sawProcess, let next = steamRunRequest() { restartNotice = next }
        else if let title = poolAutoTitle { error = JITPoolAuto.message(title) }
        else if sawProcess, let hint = steamNeededHint() { steamNeeded = hint }
        else if sawProcess, let report = exitReport() { if !getHelpInstead(report, entry: activeEntry) { error = report } }
        poolAutoTitle = nil; poolRestartNote = nil; poolRestartEntry = nil
        timer?.invalidate(); timer = nil
        saveCurrentProfile()
        controllerMode = nil
        controllerBinds = [:]
        padMouseVertical = 1
        padAssist = nil
        GamepadInput.shared.setPadAssist(nil)
        let controls = TouchControlsModel.shared
        controls.editing = false; controls.selected = nil
        controls.controls = savedControls; controls.visible = savedVisible; controls.sizeScale = savedSize
        GestureZonesModel.shared.selected = nil; GestureZonesModel.shared.zones = savedZones
        if ControlPresetsModel.enabled { controls.layoutID = savedLayout }
        current = nil; activeEntry = nil; menu = false; sessionMessage = ""
        quitRequestedAt = nil; forceCloseOffered = false; dockGameEnded = false; dockGameEndedAt = nil
        displayMode = .fit
        LogStore.shared.setDisplayActive(true)
        launching = false; launchLogs = false; LibraryKeyboard.hide()
        DockStartScreen.shared.finish()
        LibraryController.shared.configure(enabled: enabled, ownsInput: enabled)
        MetalHostView.shared.isHidden = true
        ProMotionIntent.shared.setActive(false)
        ThermalPacing.shared.end()
        fputs("[frontend] returned to library\n", stderr)
        // madeira-log-trail: the end line, once Wine is done (LogTrail.swift).
        if Thread.isMainThread { MainActor.assumeIsolated { LogTrail.backInLibrary() } }
        else { DispatchQueue.main.async { MainActor.assumeIsolated { LogTrail.backInLibrary() } } }
        LogSummary.writeLater(from: LogStore.shared.logURL, source: "madeira-log.txt (this session)")
    }
}

enum LibraryError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

// Serialized off the main actor. Cancellation follows the card's SwiftUI task,
// so entering a session stops directory work instead of competing with it.
private actor LibraryMetadataScanner {
    static let shared = LibraryMetadataScanner()
    // Dynamic imports do not appear in the PE import table. Look only for
    // terminated DLL names in bounded reads; these indicate supported APIs,
    // not which backend an application selects at runtime.
    private func dynamicAPIs(_ file: URL, budget: inout Int) -> Set<String> {
        guard budget > 0, let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let signature = try? handle.read(upToCount: 2), signature == Data([0x4d, 0x5a]) else { return [] }
        let length = (try? handle.seekToEnd()) ?? 0
        let window = min(budget, 4 * 1024 * 1024)
        var result = Set<String>()
        let names = ["ddraw.dll", "d3d8.dll", "d3d9.dll", "d3d10.dll", "d3d10_1.dll", "d3d11.dll", "d3d12.dll", "opengl32.dll", "vulkan-1.dll"]
        for offset in [UInt64(0), length > UInt64(window) ? length - UInt64(window) : 0] {
            guard budget > 0, !Task.isCancelled else { break }
            try? handle.seek(toOffset: offset)
            guard let bytes = try? handle.read(upToCount: min(window, budget)) else { break }
            budget -= bytes.count
            let folded = Data(bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 })
            for name in names {
                let ascii = Data((name + "\0").utf8)
                let wide = Data((name + "\0").utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
                if folded.range(of: ascii) != nil || folded.range(of: wide) != nil {
                    result.formUnion(LibraryModel.apiNames([name]))
                }
            }
            if length <= UInt64(window) { break }
        }
        return result
    }
    /// `countBytes: false` skips the size walk (a Steam game's size is its install record's).
    func scan(_ executable: URL, drive: URL, countBytes: Bool = true) -> (bytes: Int64?, api: String?) {
        let folder = executable.deletingLastPathComponent()
        guard folder.path.hasPrefix(drive.path + "/"), !Task.isCancelled else { return (nil, nil) }
        let manager = FileManager.default
        // Executables commonly live below the installation root. Only ascend
        // conventional binary directories, never an arbitrary library parent.
        var installation = folder
        let binaryFolders: Set<String> = ["bin", "binaries", "win32", "win64", "x86", "x64", "release"]
        for _ in 0..<4 {
            guard binaryFolders.contains(installation.lastPathComponent.lowercased()) else { break }
            let parent = installation.deletingLastPathComponent()
            guard parent.path.hasPrefix(drive.path + "/"),
                  !["program files", "program files (x86)", "games", "common", "steamapps"].contains(parent.lastPathComponent.lowercased()) else { break }
            installation = parent
        }
        var complete = true
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let walker = countBytes ? manager.enumerator(at: installation, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in complete = false; return true }) : nil
        var bytes: Int64 = 0
        var files = 0
        while let file = walker?.nextObject() as? URL {
            if Task.isCancelled { return (nil, nil) }
            files += 1
            if files > 200_000 { complete = false; break }
            guard let values = try? file.resourceValues(forKeys: keys) else { complete = false; continue }
            if values.isSymbolicLink == true { walker?.skipDescendants(); continue }
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        // Engines often import graphics through a local DLL. Follow only their
        // actual import graph, case-insensitively, never every DLL in drive_c.
        let siblings = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var local: [String: URL] = [:]
        for file in siblings where file.pathExtension.lowercased() == "dll" {
            if file.resolvingSymlinksInPath().path.hasPrefix(drive.path + "/") { local[file.lastPathComponent.lowercased()] = file }
        }
        var budget = 32 * 1024 * 1024
        var pending = [executable], visited = Set<String>(), apis = Set<String>()
        // A launcher may start a sibling executable rather than import its engine.
        // Restrict fallback to the same installation directory and a small count.
        if LibraryModel.graphicsImports(executable) == nil {
            pending.insert(contentsOf: siblings.filter {
                $0.pathExtension.lowercased() == "exe" && $0 != executable &&
                $0.resolvingSymlinksInPath().path.hasPrefix(drive.path + "/")
            }.sorted { $0.path < $1.path }.prefix(8), at: 0)
        }
        while let file = pending.popLast(), visited.count < 64, !Task.isCancelled {
            if !visited.insert(file.path).inserted { continue }
            let imports = LibraryModel.importNames(file)
            apis.formUnion(LibraryModel.apiNames(imports))
            apis.formUnion(dynamicAPIs(file, budget: &budget))
            for name in imports { if let dependency = local[name], !visited.contains(dependency.path) { pending.append(dependency) } }
        }
        return (complete && walker != nil ? bytes : nil, apis.isEmpty ? nil : apis.sorted().joined(separator: "/"))
    }
}

/// Whether JIT is available (the debugger is attached), checked every 2 s like
/// LibraryStatus. Shared by the title's bolt and the Enable JIT buttons, which
/// are disabled once it is.
final class LibraryJITState: ObservableObject {
    static let shared = LibraryJITState()
    @Published private(set) var enabled = StikJITHelper.ready
    private var timer: Timer?
    private init() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking while a list scrolls
        self.timer = timer
    }
    func refresh() {
        let now = StikJITHelper.ready
        guard now != enabled else { return }
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .default) { enabled = now }
    }
}

struct SteamMatch: Decodable, Identifiable {
    let id: Int
    let name: String
    let tiny_image: String?
}

/// The public Steam store: title search and store artwork for an app ID. No
/// account, credentials, or private library access.
enum SteamCatalog {
    static func search(_ text: String) async throws -> [SteamMatch] {
        var url = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        url.queryItems = [URLQueryItem(name: "term", value: text), URLQueryItem(name: "l", value: "english"), URLQueryItem(name: "cc", value: "US")]
        var request = URLRequest(url: url.url!); request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 2_000_000 else {
            throw LibraryError.message("Steam search is unavailable. You can still edit the title and artwork manually.")
        }
        struct Results: Decodable { var items: [SteamMatch] }
        return Array(try JSONDecoder().decode(Results.self, from: data).items.prefix(30))
    }
    static func cover(_ id: Int) -> URL? { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_600x900.jpg") }
    static func hero(_ id: Int) -> URL? { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_hero.jpg") }
}

struct LibraryArtwork: View {
    let entry: LibraryEntry
    var backdrop = false
    var body: some View {
        // A card's cover from the cache (LibraryCoverCache.swift): the cover file was decoded at full size on the main thread
        // every time the card drew. The backdrop (Game details) stays as it was.
        if !backdrop, LibraryCachedArtwork.enabled, let source = LibraryCoverCache.Source.entry(entry) {
            LibraryCachedArtwork(source: source, glyph: entry.desktop == true ? "desktopcomputer" : "gamecontroller.fill")
        } else {
            plain
        }
    }
    private var plain: some View {
        GeometryReader { geometry in
        ZStack {
            Color(uiColor: .secondarySystemFill)
            Image(systemName: entry.desktop == true ? "desktopcomputer" : "gamecontroller.fill").font(.largeTitle).foregroundStyle(.secondary)
            if let name = entry.coverFile,
               let image = UIImage(contentsOfFile: LibraryModel.documents.appendingPathComponent("madeira-art/" + URL(fileURLWithPath: name).lastPathComponent).path) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center).clipped()
            } else if let id = entry.steamID ?? entry.steamAppID {   // a store match, else the Steam game itself
                AsyncImage(url: backdrop ? SteamCatalog.hero(id) : SteamCatalog.cover(id)) { image in
                    image.resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center).clipped()
                } placeholder: { Color.clear }
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipped().accessibilityHidden(true)
        }
    }
}

/// Whether the app's liquid metal is on: Settings › Appearance › Liquid metal, kept in
/// madeira.cfg as env.MADEIRA_LIQUID_METAL (off, plain Liquid Glass, unless it is 1). It
/// covers the bars' glass (GlassSkin) and applies at once, fading between the two.
@MainActor final class LiquidMetalSetting: ObservableObject {
    static let shared = LiquidMetalSetting()
    @Published var on = MadeiraConfig.flag("MADEIRA_LIQUID_METAL", fallback: false) {
        didSet {
            guard on != oldValue else { return }
            MadeiraConfig.set("env.MADEIRA_LIQUID_METAL", on ? "1" : nil)
            if on { GlassSkin.shared.start(fadeIn: true) } else { GlassSkin.shared.stop() }
        }
    }
}

private struct LibraryCardPressedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Whether the library card this view is in is being pressed (LibraryCardButtonStyle).
    var libraryCardPressed: Bool {
        get { self[LibraryCardPressedKey.self] }
        set { self[LibraryCardPressedKey.self] = newValue }
    }
}

/// The grid cards' button style: no highlight of its own; the card's artwork shows the
/// press (LibraryCardArtworkPress).
struct LibraryCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.libraryCardPressed, configuration.isPressed)
    }
}

extension View {
    /// A library card's button style: a grid card shows its press on its artwork
    /// (LibraryCardButtonStyle); a list row keeps the plain style.
    /// `pad`: the card's id for a controller (PadHighlight.swift).
    @ViewBuilder func libraryCardButtonStyle(grid: Bool, pad: String? = nil) -> some View {
        if let pad, PadHighlight.enabled { buttonStyle(PadCardStyle(id: pad, grid: grid)) }
        else if grid { buttonStyle(LibraryCardButtonStyle()) } else { buttonStyle(.plain) }
    }
}

/// A grid card's artwork: shrinks while its card is pressed and springs back on release.
struct LibraryCardArtworkPress: ViewModifier {
    static let pressedScale: CGFloat = 0.94
    @Environment(\.libraryCardPressed) private var pressed
    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? Self.pressedScale : 1)
            .animation(pressed ? .spring(response: 0.26, dampingFraction: 0.86) : .spring(response: 0.42, dampingFraction: 0.58),
                       value: pressed)
    }
}

struct LibraryBadges: View {
    let entry: LibraryEntry
    /// A state pill after the format pills (a Steam game's "Update").
    var note: String? = nil
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { format; size }
            VStack(alignment: .leading, spacing: 4) { format; size }
        }
    }
    private var format: some View {
        HStack(spacing: 4) {
            ForEach(Self.formatTexts(entry, note: note), id: \.self) { badge($0) }
        }
    }
    @ViewBuilder private var size: some View {
        if let text = Self.sizeText(entry) { badge(text) }
    }
    /// The format pills' texts, in order (also the zoomable grid's measured labels). No bitness or graphics API pills: both were
    /// read from the program before it ran and were often wrong.
    static func formatTexts(_ entry: LibraryEntry, note: String?) -> [String] {
        var texts: [String] = []
        if entry.isBatch { texts.append("Batch") }   // ml1163
        if let note { texts.append(note) }
        // (works-now) A Get Help report from this player that "Does it work now?" has not closed.
        if GetHelp.enabled, let report = GetHelp.reported[entry.windowsPath], !report.asked { texts.append(L("Works now?")) }
        return texts
    }
    static func sizeText(_ entry: LibraryEntry) -> String? {
        entry.folderBytes.map { String(format: $0 < 1_000_000_000 ? "%.2f GB" : "%.1f GB", Double($0) / 1_000_000_000) }
    }
    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 5).padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A section title with a count.
struct LibrarySectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold())
            if let count, count > 0 { Text("\(count)").font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
            trailing
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

struct LibraryCells<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let layout: String
    let width: CGFloat
    @ViewBuilder let cell: (_ item: Item, _ list: Bool, _ dense: Bool) -> Cell
    var body: some View {
        if layout == "list" || layout == "compactList" {
            let dense = layout == "compactList"
            LazyVStack(spacing: dense ? 4 : 8) { ForEach(items) { item in cell(item, true, dense) } }
        } else {
            let compact = layout == "compact"
            let width = max(1, min(self.width, 1100) - 32)
            let count = max(1, Int((width + 12) / (compact ? 110 : 154)))
            let cardWidth = min(compact ? 115.0 : 164.0, (width - CGFloat(count - 1) * 12) / CGFloat(count))
            // The width the cards leave goes into the gaps (up to 34 pt), so the grid
            // nearly spans the margins and each card's ambient light keeps to its own space.
            let gap = count > 1 ? max(12, min(34, (width - CGFloat(count) * cardWidth) / CGFloat(count - 1))) : 12
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: gap, alignment: .top), count: count), alignment: .center, spacing: 18) {
                ForEach(items) { item in cell(item, false, false) }
            }.frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

struct LibraryView: View {
    @ObservedObject private var model = LibraryModel.shared
    @Environment(\.scenePhase) private var scenePhase
    var play: (LibraryEntry) -> Void
    var enableJIT: () -> Void
    /// Madeira Dock's start, for Settings › Steam (Onboarding.swift).
    var startDock: (DockGame, Bool) -> Void = { _, _ in }
    /// First-run setup (Onboarding.swift).
    @ObservedObject private var onboarding = OnboardingModel.shared
    @ObservedObject private var jit = JITCoordinator.shared
    /// The library's error is a JIT connection problem with a fix to offer.
    private var jitProblem: JITCoordinator.ConnectionProblem? {
        jit.connectionProblem.flatMap { model.error == $0.message ? $0 : nil }
    }
    @State private var browser = false
    @State private var selected: LibraryEntry?
    @State private var lookTab: NewLookTab = .library
    /// Each tab's search text (its field is Apple's .searchable, under the title), and whether the
    /// open tab's field has the keyboard (the controller's Y).
    @State private var lookQuery: [NewLookTab: String] = [:]
    @FocusState private var lookField: Bool
    /// Menu on a cover: its options (NewLookOptionsSheet).
    @State private var lookOptions: LibraryEntry?
    /// Each tab's own page stack (Apple's tab bar, one NavigationStack per tab): a store's page
    /// and a Settings page are pushed inside their tab, so Back and the edge swipe work, the tab
    /// bar stays, and every tab keeps its own place (ux-review-0044 #1, #2).
    @State private var libraryPath = NavigationPath()
    @State private var storesPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    /// The games whose pages are pushed in the tabs, by id (a store's game may not be in the
    /// library's list yet: its page is a new entry until it is saved).
    @State private var lookGames: [UUID: LibraryEntry] = [:]
    /// Tapping the open tab: back to its first page, then to the top (each tap counts up).
    @State private var lookTop: [NewLookTab: Int] = [:]
    /// A store's game picked in the Stores search: its sheet opens once the store's page is up (no timer).
    @State private var lookPendingGame: NewLookSearch.StoreGame?
    /// The Stores tab's % badge (the downloads are on that tab).
    @ObservedObject private var lookDownloads = NewLookDownloads.shared

    /// The Display and Memory and sync settings pages.
    static var runtimeSettingsShown: Bool { MadeiraConfig.flag("MADEIRA_RUNTIME_SETTINGS") }

    var body: some View {
        newLookBody
        // On the tab view, not inside one tab's page: an alert attached to one tab's page cannot
        // present while another is showing, so an error raised there (its Enable JIT, for one)
        // waited until that tab came back.
        .alert(jitProblem == nil ? L("Library") : L("Couldn't Enable JIT"),
               isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            if let jitProblem { jitConnectionActions(jitProblem, retry: enableJIT) { model.error = nil } }
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        // Signing that runs out: the refresh, and the offer when it could not run (SigningRefresh.swift).
        .modifier(SigningRefreshOffer())
        // (get-help) After a game stopped by itself: "<game> Stopped. Get Help?" (GetHelpView.swift).
        .modifier(GetHelpOffer(play: play))
        // A setup opened from Files, a chat or a madeira://setup link (GameSetupShare.swift).
        .modifier(GameSetupInboxPresenter())
        .fullScreenCover(isPresented: $onboarding.presented) { OnboardingView() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshFlag() } }
        .onAppear {
            // An ended desktop session's surface never stays over the library.
            EndedSessionSurface.install(); EndedSessionSurface.hide(reason: "library-appeared")
            // First-run setup opens once on a new install.
            onboarding.presentIfNeeded()
        }
        // ml1216: a session replaces the library (ContentView), and the skin's run-loop
        // observer, display link and view walks kept running on the main thread through
        // the whole game. Stop with the library; it starts again when the library returns
        // (start() does nothing while liquid metal is off).
        .onAppear { GlassSkin.shared.start() }
        .onDisappear { GlassSkin.shared.stop() }
    }
}

/// The library's sheet (Add executable), and the game page selection, which
/// clears when a session, an error or a notice takes over.
private struct LibrarySheets: ViewModifier {
    @ObservedObject var model: LibraryModel
    @Binding var browser: Bool
    @Binding var selected: LibraryEntry?
    @ObservedObject var jit: JITCoordinator
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $browser) {
                NavigationStack { ExecutableBrowser(folder: LibraryModel.drive) { entry in
                    // madeira-bcd: the page shows the entry as stored, with its recommended settings.
                    model.save(entry); browser = false; selected = model.entries.first { $0.id == entry.id } ?? entry
                } }
                // A sheet is its own hosting view: without this, iOS 18 lets the controller also move
                // the system's own focus and press buttons on it, besides Madeira's commands.
                .modifier(ClaimGamepadEvents())
                .logScreen("add a game")
            }
            // The game page is pushed inside a tab (LibraryView.lookOpenGame), not shown here.
            .onChange(of: model.current) { _, current in if current != nil { selected = nil } }
            .onChange(of: model.error) { _, error in if error != nil { selected = nil } }
            .onChange(of: model.restartNotice) { _, notice in if notice != nil { selected = nil } }
            .onChange(of: model.jitNotice) { _, notice in if notice != nil { selected = nil } }
            .onChange(of: model.cloudNotice) { _, notice in if notice != nil { selected = nil } }
            .onChange(of: jit.showSetup) { _, show in if show { selected = nil } }
            .onChange(of: model.showDetail) { _, id in
                guard let id else { return }
                model.showDetail = nil
                selected = model.entries.first { $0.id == id }
            }
    }
}

struct ExecutableBrowser: View {
    let folder: URL
    var select: (LibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var error: String?
    var body: some View {
        List {
            // [battle-net] Get or add Battle.net, at the top of drive_c's list.
            if BattleNet.enabled, folder.standardizedFileURL == LibraryModel.drive.standardizedFileURL {
                BattleNetAddRow(select: select)
            }
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(files, id: \.path) { file in
                if file.hasDirectoryPath {
                    NavigationLink { ExecutableBrowser(folder: file, select: select) } label: { Label(file.lastPathComponent, systemImage: "folder") }
                } else {
                    Button { do { select(try LibraryModel.inspect(file)) } catch { self.error = error.localizedDescription } } label: {
                        Label(file.lastPathComponent, systemImage: file.pathExtension.lowercased() == "exe" ? "app.dashed" : "terminal")
                    }
                }
            }
            if files.isEmpty && error == nil { Text("No executables here. Copy files into Madeira/wine/drive_c using Files.").foregroundStyle(.secondary) }
        }.navigationTitle(folder.lastPathComponent)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task {
            do {
                // ml1163: .bat and .cmd files are listed too (they run through cmd.exe).
                files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
                    // External drives are linked in as symlinks: list them as folders.
                    .map { url in
                        let isDir = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        return URL(fileURLWithPath: url.path, isDirectory: isDir == true)
                    }
                    .filter { ($0.hasDirectoryPath || LibraryModel.programExtensions.contains($0.pathExtension.lowercased())) && LibraryModel.relativeToDrive($0) != nil }
                    .sorted { if $0.hasDirectoryPath != $1.hasDirectoryPath { return $0.hasDirectoryPath }; return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct LibraryDetail: View {
    @State internal var entry: LibraryEntry
    var play: (LibraryEntry) -> Void
    /// (new look) The page is pushed inside a tab's page stack, like any iPhone page (ux-review-0044
    /// #1), instead of covering the screen: its own pages are pushed on that stack too. nil: the
    /// page is a sheet or cover with its own stack.
    var stack: LibraryDetailStack? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = LibraryModel.shared
    @State private var importCover = false
    /// madeira-bcd: this game's own switches as the fork stores them (reloadBCD).
    @State private var bcd = BCDGameValues()
    @State private var findCover = false
    @State private var remove = false
    /// madeira-bcd: Madeira's recommended settings for this game, nil for none
    /// (GameRecommendations.swift), and the question before Reset to Recommended.
    @State private var recommended: GameRecommendation?
    @State private var confirmReset = false
    /// (compat-report) "Copied" on the button for 2 s after a tap.
    @State private var compatCopied = false
    /// (debug-logging) "Copied" on Copy debug info for 2 s after a tap (test bundle only).
    @State private var debugCopied = false
    /// (get-help) The Get Help sheet (GetHelpView.swift).
    @State private var getHelp = false
    @State private var leaving = false
    @State private var error: String?
    @State private var copiedLink = false
    /// Share Setup and Apply Shared Setup (GameSetupShare.swift).
    @State private var shareSetup = false
    @State private var askSetupSource = false
    @State private var importSetup = false
    @State private var setupToApply: GameSetupInbox.Pending?
    @State private var setupError: String?
    /// Where Play is on screen: the starting screen grows out of it (LaunchCurtain).
    @State private var playFrame: CGRect = .zero
    /// Settings › Sync engine, read when the details open: the fastsync switches
    /// below only apply while it is Fastsync.
    @State private var syncEngine = SyncEngine.current
    /// madeira-bcd: one storage for a game's own options -- where the fork keeps
    /// them and BCDLaunch exports them at every launch (library, Madeira Dock,
    /// Home Screen shortcuts): AVX, NVIDIA and Wine's C++ runtime in LibraryPrefs,
    /// the game's config lines in its GameProfiles.swift file. This page's
    /// controls read and write them; the entry fields upstream keeps for the
    /// same options (avx, reportNVIDIA, config) are moved into them once.
    /// (debug-logging) The level read from this game's config; setting one rewrites only the lines it manages.
    private var debugLevel: Binding<DebugLogging.Level> {
        Binding(get: { DebugLogging.level(of: bcd.configText) }, set: { level in
            let text = DebugLogging.apply(level, to: bcd.configText)
            bcd.configText = text
            GameProfile(windowsPath: entry.windowsPath).text = text
            LogStore.shared.log("[debug-log] level \(level.title) for \(entry.title)")
        })
    }
    private func reloadBCD() {
        bcd = BCDGameValues(windowsPath: entry.windowsPath)
        bcd.unityIL2CPP = BCDLaunch.isUnityIL2CPP(entry)
    }
    private func migrateEntryOptions() {
        let path = entry.windowsPath
        let file = GameProfile(windowsPath: path)
        var moved: [String] = []
        if entry.avx == true { LibraryPrefs.setAVX(true, for: path); moved.append("avx") }
        if entry.reportNVIDIA == true { LibraryPrefs.setNvidia(true, for: path); moved.append("nvidia") }
        if let config = entry.config, !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The entry's lines first, the file's after: a key both set keeps the file's value.
            let old = file.text
            file.text = config + (config.hasSuffix("\n") ? "" : "\n") + old
            moved.append("config")
        }
        guard !moved.isEmpty else { return }
        entry.avx = nil; entry.reportNVIDIA = nil; entry.config = nil
        model.save(entry)
        LogStore.shared.log("[bcd] \(entry.title): moved \(moved.joined(separator: ",")) into the game's own settings")
    }
    /// madeira-bcd: a game seen for the first time gets Madeira's recommended settings,
    /// which this page then shows (GameRecommendationsApply.swift).
    private func prepareRecommendation() {
        recommended = GameRecommendations.recommendation(for: entry)
        // A copy the library has not stored (a Steam game's first page) is a new entry.
        let isNew = !model.entries.contains { $0.id == entry.id }
        if GameRecommendations.prepare(&entry, new: isNew) { model.save(entry) }
    }
    /// Reset to Recommended: the recommendation's config and switches, written at once.
    private func resetToRecommended() {
        recommended = GameRecommendations.reset(&entry)
        model.save(entry)
        reloadBCD()
    }
    /// Apply Shared Setup: reads the setup, then shows what it holds before applying.
    private func readSetup(_ read: () throws -> GameSetup) {
        do { setupToApply = GameSetupInbox.Pending(setup: try read()) }
        catch { setupError = error.localizedDescription }
    }
    /// "None", or how many keys this game's own config sets.
    static func configSummary(_ config: String?) -> String {
        let count = MadeiraConfig.parse(config ?? "").count
        return count == 0 ? "None" : count == 1 ? "1 setting" : "\(count) settings"
    }
    private func start() {
        guard !leaving else { return }
        // A Steam game starts through Madeira Dock (ContentView.launchLibraryEntry)
        // once its files are complete and Dock can sign in; "The game" once its
        // program is chosen (no client or sign-in involved).
        // A GOG game starts once its files are complete (GOGLibrary).
        if let product = entry.gogProductID {
            if GOGLibrary.shared.downloads[product] != nil {
                error = L("This game's download has not finished. Resume it and wait for it to complete before playing."); return
            }
            if GOGLibrary.shared.installed[product] == nil {
                error = L("This GOG game is no longer installed. Install it again from the GOG section."); return
            }
        }
        // An itch.io game starts once its files are complete (ItchLibrary).
        if let game = entry.itchGameID {
            if ItchLibrary.shared.downloads[game] != nil {
                error = L("This game's download has not finished. Resume it and wait for it to complete before playing."); return
            }
            if ItchLibrary.shared.installed[game] == nil {
                error = L("This itch.io game is no longer installed. Install it again from the itch.io section."); return
            }
        }
        // An EA game starts once its files are complete and the account is signed in
        // (EALibrary.prepareLaunch gets its licence and the EA app's environment).
        if let offer = entry.eaOfferID {
            if EALibrary.shared.downloads[offer] != nil {
                error = "This game's download has not finished. Resume it and wait for it to complete before playing."; return
            }
            if EALibrary.shared.installed[offer] == nil {
                error = "This EA game is no longer installed. Install it again from the EA app section."; return
            }
            if !EALibrary.shared.signedIn {
                error = "Sign in to EA in Settings › EA app first. An EA game needs the sign-in to get its licence and start."; return
            }
        }
        // An Epic game starts once its files are complete (EpicLibrary).
        if let app = entry.epicAppName {
            if EpicLibrary.shared.downloads[app] != nil {
                error = L("This game's download has not finished. Resume it and wait for it to complete before playing."); return
            }
            if EpicLibrary.shared.installed[app] == nil {
                error = L("Epic Games no longer lists this game as installed. Install it again from the Epic Games section."); return
            }
        }
        if let appID = entry.steamAppID {
            if SteamOwnedLibrary.shared.downloads[appID] != nil {
                error = L("This game's update has not finished. Resume it and wait for it to complete before playing."); return
            }
            let installed = SteamGamesModel.shared.games.first { $0.id == appID }?.installed ?? false
            if entry.startsSteamGameDirectly {
                if let blocker = SteamDirectStart.blocker(installed: installed, program: entry.steamProgram) { error = blocker; return }
            } else if let blocker = SteamGamesRules.blocker(installed: installed, client: MadeiraDock.clientInstalled, signedIn: SteamSignIn.isSignedIn) {
                error = blocker; return
            }
        }
        leaving = true
        let steamCover = entry.coverFile == nil ? entry.steamAppID : nil
        LaunchCurtain.shared.begin(from: playFrame, appID: steamCover, artwork: steamCover.flatMap { id in
            SteamGamesRules.artwork(appID: id) { SteamOwnedLibrary.shared.game($0) }.first
        })
        model.prepare(entry)
        let profile = entry
        // Give the pressed state a display turn before saving and handing off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            model.save(profile); play(profile)
        }
    }
    /// A Steam game without a chosen cover shows Steam's store artwork.
    @ViewBuilder private func artwork(backdrop: Bool) -> some View {
        if let appID = entry.steamAppID, entry.coverFile == nil {
            SteamGameArtwork(appID: appID)
        } else {
            LibraryArtwork(entry: entry, backdrop: backdrop)
        }
    }
    /// The pages the details page links to (iOS Settings style), each with its own Form.
    enum Page: Hashable {
        case display, controls, launch, compatibility, steam, cloud, achievements, gog, itch, library, iniFiles, advanced
        var title: String {
            switch self {
            case .display: return "Display"
            case .controls: return "Controls"
            case .launch: return "Launch"
            case .compatibility: return "Compatibility"
            case .steam: return "Steam"
            case .cloud: return "Steam Cloud"
            case .workshop: return "Steam Workshop"
            case .binds: return "Controller binds"
            case .epic: return "Epic Games"
            case .ea: return "EA app"
            case .assist: return "Gyro aim & turbo"
            case .gog: return "GOG"
            case .itch: return "itch.io"
            case .achievements: return "Achievements"
            case .library: return "Library details"
            case .iniFiles: return "Settings files"
            case .mods: return "Mods"
            case .advanced: return "Advanced"
            }
        }
        /// The store a store's page is for (its logo is the row's icon).
        var store: NewLookStore? {
            switch self {
            case .steam: return .steam
            case .gog: return .gog
            case .itch: return .itch
            case .epic: return .epic
            case .ea: return .ea
            default: return nil
            }
        }
        var symbol: String {
            switch self {
            case .display: return "display"
            case .controls: return "gamecontroller"
            case .launch: return "terminal"
            case .compatibility: return "cpu"
            case .steam: return "shippingbox"
            case .cloud: return "icloud"
            case .workshop: return "square.stack.3d.up"
            case .binds: return "keyboard"
            case .epic: return "shippingbox"
            case .ea: return "shippingbox"
            case .assist: return "gyroscope"
            case .gog: return "bag"
            case .itch: return "bag"
            case .achievements: return "trophy"
            case .library: return "info.circle"
            case .iniFiles: return "doc.text"
            case .mods: return "puzzlepiece.extension"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
        /// The new look's second line under the page's row, saying what is in it (the mock-up's
        /// game page; Cameron, Nov 9: follow the mock-up).
        var blurb: String {
            switch self {
            case .display: return L("Resolution, screen shape and upscaling.")
            case .controls: return L("Controller mode, binds and the touch buttons.")
            case .launch: return L("How the game starts.")
            case .compatibility: return L("Fixes for games that crash or won't start.")
            case .steam, .gog, .itch, .epic, .ea: return L("This game in its store.")
            case .cloud: return L("Saves kept in Steam Cloud.")
            case .workshop: return L("Steam Workshop items for this game.")
            case .achievements: return L("Your achievements in this game.")
            case .binds: return L("What each controller button presses.")
            case .assist: return L("Gyro aiming and turbo buttons.")
            case .library: return L("Cover art, and removing it from the library.")
            case .iniFiles: return L("The game's .ini and .cfg files.")
            case .mods: return L("Mods for this game.")
            case .advanced: return L("Logs, sharing its setup, and reset.")
            }
        }
        /// A Steam game's Steam Workshop items (SteamWorkshop.swift).
        case workshop
        /// Controls › Controller binds and Gyro aim & turbo, pages of their own so they open
        /// at once like the others (open(_:)).
        case binds, assist
        /// An Epic or EA game's store page (repair, version, cloud saves, uninstall): on the
        /// details page itself before the rebuild, a page like Steam's, GOG's and itch.io's now.
        case epic, ea
        /// The game's mods (ModsView.swift), above Advanced.
        case mods
    }
    @State private var path: [Page] = []
    /// (new look, pushed) The row to come back to when one of this page's own pages closes.
    @State private var lookReturn: String?
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var steamGames = SteamGamesModel.shared
    @State private var confirmSteamUninstall = false
    /// A Steam game Madeira downloaded and that is not updating: Uninstall shows (as
    /// SteamUninstallSection decides on the store page).
    private var steamUninstallable: DockGame? {
        guard let appID = entry.steamAppID, appID != 0, steam.downloads[appID] == nil,
              let installed = steamGames.games.first(where: { $0.id == appID }),
              SteamInstallPaths.isManaged(library: installed.library) else { return nil }
        return installed
    }
    /// Opens one of the page's own pages.
    private func open(_ page: Page) {
        // Pushed, this page goes off screen under its own page (its layer closes): back, the
        // highlight returns to the row that opened it, not to Play.
        if let stack { lookReturn = "gp-page-\(page)"; stack.push(page); return }
        path.append(page)
    }
    /// A row that opens `page` (open(_:)): its icon, title, summary and a chevron, like a
    /// NavigationLink's row.
    private func pageRow(_ item: Page, icon: Bool = true) -> some View {
        Button { open(item) } label: { pageRowLabel(item, icon: icon) }
    }
    /// A page row's look: icon, title, summary and chevron.
    private func pageRowLabel(_ item: Page, icon: Bool = true) -> some View {
        Group {
            HStack(spacing: 8) {
                Group {
                    if icon {
                        Label { Text(LocalizedStringKey(item.title)).foregroundStyle(.primary) } icon: { Image(systemName: item.symbol).foregroundStyle(Color.accentColor) }
                    } else {
                        Text(LocalizedStringKey(item.title)).foregroundStyle(.primary)
                    }
                }
                Spacer(minLength: 8)
                if let value = summary(item) { Text(value).lineLimit(1).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
    }
    /// A Game details button row's look: a blue icon (red for Uninstall) and its title.
    private func detailLabel(_ title: LocalizedStringKey, _ symbol: String, color: Color = .accentColor) -> some View {
        Label { Text(title).foregroundStyle(color == .red ? Color.red : Color.primary) } icon: { Image(systemName: symbol).foregroundStyle(color) }
    }
    /// The rows of the details page, in groups. The Desktop entry has no launch options
    /// or library details; a Steam game has its Steam pages.
    private var pageGroups: [[Page]] {
        let launch = entry.usesLaunchOptions || entry.desktop != true
        let steam: [Page] = entry.steamAppID == nil ? (entry.gogProductID != nil ? [.gog] : entry.itchGameID != nil ? [.itch]
                                                      : entry.epicAppName != nil ? [.epic] : entry.eaOfferID != nil ? [.ea] : [])
            : (SteamOwnedLibrary.cloudEnabled ? [.steam, .cloud, .achievements] : [.steam, .achievements])
                + (SteamOwnedLibrary.workshopEnabled && Self.showsWorkshop(entry.steamAppID) ? [.workshop] : [])
        let tuning: [Page] = launch ? [.display, .controls, .launch, .compatibility] : [.display, .controls, .compatibility]
        let more: [Page] = entry.desktop == true ? [.advanced] : [.library, .iniFiles, .mods, .advanced]
        return [tuning, steam, more].filter { !$0.isEmpty }
    }
    /// Steam Workshop is offered unless Steam says the game has none
    /// (SteamOwnedGame.workshop; unknown in older caches).
    @MainActor private static func showsWorkshop(_ appID: Int?) -> Bool {
        guard let appID else { return false }
        return SteamOwnedLibrary.shared.game(appID)?.workshop != false
    }
    /// The value a page's row shows, when one setting sums it up.
    private func summary(_ page: Page) -> String? {
        switch page {
        case .display: return entry.metalFXUpscale.map { "\(entry.resolution) · MetalFX \($0 == 2 ? "2" : "1.5")×" } ?? entry.resolution
        case .controls: return entry.controllerMode == "keys" ? "Keyboard and mouse" : entry.controllerMode == "dinput" ? "XInput and DirectInput" : nil
        case .launch: return entry.usesLaunchOptions ? (entry.runsInDesktop ? L("Wine desktop") : L("Directly")) : nil
        case .steam: return entry.startsSteamGameDirectly ? "The game" : "Madeira Dock"
        case .advanced: return Self.configSummary(bcd.configText)   // madeira-bcd: the game's own config file
        case .iniFiles:
            let count = GameIniFiles.files(entry.windowsPath).count
            return count == 0 ? nil : count == 1 ? "1 file" : "\(count) files"
        default: return nil
        }
    }

    @ViewBuilder private func page(_ page: Page) -> some View {
        ScrollViewReader { reader in
        Form {
            switch page {
            case .display: displayPage
            case .controls: controlsPage
            case .launch: launchPage
            case .compatibility: compatibilityPage
            case .steam: steamPage
            case .cloud: if let appID = entry.steamAppID { SteamCloudSection(appID: appID) }
            case .workshop:
                if let appID = entry.steamAppID, appID > 0, appID <= Int(UInt32.max) {
                    SteamWorkshopSections(appID: UInt32(appID), title: entry.title)
                }
            case .gog: GOGEntrySection(entry: $entry) { leaving = true; closePage() }
            case .itch: ItchEntrySection(entry: $entry) { leaving = true; closePage() }
            case .achievements: if let appID = entry.steamAppID { SteamAchievementsSection(appID: appID) }
            case .library: libraryPage
            case .iniFiles: GameIniFilesSection(windowsPath: entry.windowsPath, gameFolder: iniGameFolder)
            case .mods: ModsPage(game: modGame)
            case .advanced: advancedPage
            case .epic:
                if let appName = entry.epicAppName {
                    EpicEntrySection(entry: $entry) { leaving = true; closePage() }
                    EpicCloudSection(appName: appName)
                }
            case .ea: EAEntrySection(entry: $entry) { leaving = true; closePage() }
            case .binds:
                ControllerBindsPage(binds: $entry.controllerBinds, mouseVertical: $entry.padMouseVertical)
                    .toolbar {
                        Button("Reset") { entry.controllerBinds = nil; entry.padMouseVertical = nil }
                            .disabled(entry.controllerBinds == nil && entry.padMouseVertical == nil)
                    }
            case .assist:
                PadAssistPage(settings: $entry.padAssist)
                    .toolbar { Button("Reset") { entry.padAssist = nil }.disabled(entry.padAssist == nil) }
            }
        }
        // (new-look) The page follows the highlight, and is its own layer: the highlight starts on
        // its first row, B goes back to the game page and the highlight returns to that row.
        .padScrollFollow(reader)
        .padLayer("game-\(page)", back: { lookBack() }, page: stack != nil)
        }
        .navigationTitle(LocalizedStringKey(page.title)).navigationBarTitleDisplayMode(.inline)
        .menuPadNoSystemFocus()
    }

    @ViewBuilder private var displayPage: some View {
        Section {
            // The Windows screen the game renders for (and the Desktop's size).
            // ml1172: this device's choices (ResolutionChoices), grouped.
            let groups = ResolutionChoices.groups()
            let metalFX = ResolutionChoices.metalFX(in: groups)
            Picker("Resolution", selection: $entry.resolution) {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.choices, id: \.value) { Text($0.label).tag($0.value) }
                    }
                }
                // The screen's shape at 480 lines, which MetalFX 1.5× brings to 720.
                if let shape = metalFX, entry.metalFXUpscale == 1.5 || entry.resolution == shape.value {
                    Text(shape.label).tag(shape.value)
                }
                // A size none of them has, so the picker never shows a blank choice.
                if entry.resolution != metalFX?.value, let saved = ResolutionChoices.extra(entry.resolution, in: groups, note: "saved") {
                    Text(saved.label).tag(entry.resolution)
                }
            }
            // (new-look) The controller: A steps to the next choice (Cameron, Nov 9: nothing worked in here).
            .padItem("gd-resolution", cornerRadius: 12, inset: -6) { entry.resolution = padNext(groups.flatMap { $0.choices.map(\.value) }, after: entry.resolution) }
            Picker("Aspect & scaling", selection: Binding(get: { entry.displayMode.rawValue }, set: { entry.display = $0 })) {
                ForEach(DisplayMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            .padItem("gd-aspect", cornerRadius: 12, inset: -6) { entry.display = padNext(DisplayMode.allCases.map(\.rawValue), after: entry.displayMode.rawValue) }
            // Every setting here is the Desktop's too: its programs present through
            // the same path, and its launch applies them like a game's
            // (applyEnvironment, gameConfigText). check-frontend holds the parity.
            Picker("MetalFX upscaling", selection: $entry.metalFXUpscale) {
                Text("Off").tag(Double?.none)
                Text("1.5×").tag(Double?.some(1.5))
                Text("2×").tag(Double?.some(2))
            }
            .padItem("gd-metalfx", cornerRadius: 12, inset: -6) { entry.metalFXUpscale = padNext([nil, 1.5, 2] as [Double?], after: entry.metalFXUpscale) }
            Toggle("Frame generation (experimental)", isOn: Binding(get: { entry.frameGeneration ?? false }, set: { entry.frameGeneration = $0 ? true : nil }))
                .padItem("gd-framegen", cornerRadius: 12, inset: -6) { entry.frameGeneration = entry.frameGeneration == true ? nil : true }
            if entry.frameGeneration == true {
                Text("Adds a generated frame between real ones. More latency; the FPS limit is ignored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Display") } footer: {
            Text("MetalFX renders at the resolution above and upscales it (Direct3D 11 and 12).")
        }
    }

    @ViewBuilder private var controlsPage: some View {
        Section("On screen") {
            if GamepadInput.keyboardMouseAvailable {
                ControllerModeChoice(mode: $entry.controllerMode)
                    .padItem("gc-mode", cornerRadius: 12, inset: -6) { entry.controllerMode = padNext([nil, "dinput", "keys"] as [String?], after: entry.controllerMode) }
                if entry.controllerMode == "dinput" {
                    Text("For older games that read the pad through DirectInput.").font(.caption).foregroundStyle(.secondary)
                }
                if entry.controllerMode == "keys" {
                    Text("The pad acts as keyboard and mouse. Change keys in Controller binds.").font(.caption).foregroundStyle(.secondary)
                    pageRow(.binds, icon: false)
                        .padItem("gc-binds", cornerRadius: 12, inset: -6) { open(.binds) }
                }
            }
            if GamepadInput.enabled {
                pageRow(.assist, icon: false)
                    .padItem("gc-assist", cornerRadius: 12, inset: -6) { open(.assist) }
            }
            LabeledContent("Control opacity") {
                Slider(value: Binding(get: { entry.controlOpacity ?? 0.7 }, set: { entry.controlOpacity = $0 }), in: 0.15...1)
            }
            .padItem("gc-opacity", cornerRadius: 12, inset: -6) {
                entry.controlOpacity = padNext([0.25, 0.4, 0.55, 0.7, 0.85, 1.0], after: ((entry.controlOpacity ?? 0.7) * 20).rounded() / 20)
            }
            LabeledContent("Control size") {
                Slider(value: Binding(get: { entry.controlSize ?? 1 }, set: { entry.controlSize = $0 }), in: 0.5...2)
            }
            .padItem("gc-size", cornerRadius: 12, inset: -6) {
                entry.controlSize = padNext([0.75, 1.0, 1.25, 1.5, 2.0], after: ((entry.controlSize ?? 1) * 4).rounded() / 4)
            }
            Text("Edit buttons from the in-game menu.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var launchPage: some View {
        // ml1163: how the program starts. Not for the Desktop entry, nor for a Steam
        // game started through Madeira Dock, whose desktop and command are Dock's:
        // there these choices would do nothing.
        if entry.usesLaunchOptions {
            Section {
                Picker("Start", selection: Binding(get: { entry.runsInDesktop ? "desktop" : "direct" }, set: {
                    entry.launchMode = $0 == "desktop" ? "desktop" : nil
                })) {
                    Text("Directly").tag("direct")
                    Text("In the Wine desktop").tag("desktop")
                }
                .padItem("gl-start", cornerRadius: 12, inset: -6) { entry.launchMode = entry.runsInDesktop ? nil : "desktop" }
                TextField("Working folder (default: the program's folder)", text: Binding(get: { entry.workingDirectory ?? "" }, set: {
                    entry.workingDirectory = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
                })).autocorrectionDisabled().textInputAutocapitalization(.never).font(.body.monospaced())
                Toggle("Start Windows services first", isOn: Binding(get: { entry.startServices == true }, set: {
                    entry.startServices = $0 ? true : nil
                }))
                .padItem("gl-services", cornerRadius: 12, inset: -6) { entry.startServices = entry.startServices == true ? nil : true }
            } header: { Text("Launch") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The working folder is a C:\\ path. Services are for launchers that need them.")
                    if !entry.runsInDesktop && (entry.isBatch || entry.startServices == true) {
                        // Wine stops with its first process (the ml1163 open risk).
                        Text("A batch file that exits closes the game. Start it in the Wine desktop.")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        // A Steam game starts with Steam's own launch option through Madeira Dock.
        if entry.desktop != true {
            Section {
                TextField("Launch arguments", text: $entry.arguments.plainLaunchArguments, axis: .vertical)
                    .font(.body.monospaced()).lineLimit(1...4)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).smartPunctuationOff()
                LaunchFlagChips(arguments: $entry.arguments)
                // [battle-net] Battle.net: one button per Blizzard game.
                if BattleNet.enabled, BattleNet.isBattleNet(entry) { BattleNetGameChips(arguments: $entry.arguments) }
                // What the next start runs (ml1163: in the Wine desktop, a batch file or
                // the services batch, what starts the program).
                Text(entry.commandPreview)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            } header: { Text("Launch arguments") } footer: {
                Text(entry.steamAppID == nil ? L("Passed on every start. Above: the full command.") : L("Steam adds these to the selected launch option on every start."))
            }
        }
    }

    @ViewBuilder private var compatibilityPage: some View {
        Section {
            Picker(selection: $entry.x87Precision) {
                Text("Automatic").tag(LibraryEntry.X87Precision.automatic)
                Text("Reduced (faster)").tag(LibraryEntry.X87Precision.reduced)
                Text("Full (accurate)").tag(LibraryEntry.X87Precision.full)
            } label: {
                compatLabel(L("x87 precision"), L("Automatic is fast for 32-bit games and accurate for 64-bit ones. Full can halve a 32-bit game's frame rate."))
            }
            .padItem("gx-x87", cornerRadius: 12, inset: -6) { entry.x87Precision = padNext(LibraryEntry.X87Precision.allCases, after: entry.x87Precision) }
            Toggle(isOn: Binding(get: { entry.largeReservations ?? false }, set: { entry.largeReservations = $0 ? true : nil })) {
                compatLabel(L("Large memory reservations"), L("For requests of 64 GB or more. Backs up to 16 GB by default."))
            }
            .padItem("gx-large", cornerRadius: 12, inset: -6) { entry.largeReservations = entry.largeReservations == true ? nil : true }
            // madeira-bcd: AVX, NVIDIA and Wine's C++ runtime are LibraryPrefs, which
            // BCDLaunch exports at every launch (reloadBCD / migrateEntryOptions).
            Toggle(isOn: Binding(get: { bcd.avx }, set: { on in bcd.avx = on; LibraryPrefs.setAVX(on, for: entry.windowsPath) })) {
                compatLabel(L("AVX and AVX2"), L("For games that quit with c000001d"))
            }
            .padItem("gx-avx", cornerRadius: 12, inset: -6) { let on = !bcd.avx; bcd.avx = on; LibraryPrefs.setAVX(on, for: entry.windowsPath) }
            // Exported for this game only when chosen (applyEnvironment).
            Picker("CPU cores reported", selection: Binding(get: { entry.cpuCount ?? 0 }, set: { entry.cpuCount = $0 == 0 ? nil : $0 })) {
                Text("Automatic").tag(0)
                ForEach([1, 2, 4, 6], id: \.self) { Text("\($0)").tag($0) }
            }
            .padItem("gx-cpus", cornerRadius: 12, inset: -6) { let n = padNext([0, 1, 2, 4, 6], after: entry.cpuCount ?? 0); entry.cpuCount = n == 0 ? nil : n }
            // Hidden: an old build's switch the D3D9 path no longer needs. A game that has a limit still exports it, and
            // keeps the picker so it can go back to Application default.
            if entry.anisotropyLimit != nil {
                Picker("D3D9 anisotropic filtering", selection: Binding(get: { entry.anisotropyLimit ?? 0 }, set: { entry.anisotropyLimit = $0 == 0 ? nil : $0 })) {
                    Text("Application default").tag(0)
                    ForEach([1, 2, 4, 8], id: \.self) { Text("Up to \($0)×").tag($0) }
                }
                .padItem("gx-aniso", cornerRadius: 12, inset: -6) { let n = padNext([0, 1, 2, 4, 8], after: entry.anisotropyLimit ?? 0); entry.anisotropyLimit = n == 0 ? nil : n }
            }
            // GPUCards.swift: a chosen card replaces the two NVIDIA switches below.
            Picker(selection: Binding(get: { bcd.gpuCard }, set: { id in bcd.gpuCard = id; LibraryPrefs.setGPUCard(id, for: entry.windowsPath) })) {
                Text("Automatic").tag("")
                ForEach(GPUCards.all, id: \.id) { Text($0.title).tag($0.id) }
            } label: {
                compatLabel("Graphics card the game sees", "For games that refuse this GPU or only run on cards they know")
            }
            .padItem("gx-gpu", cornerRadius: 12, inset: -6) {
                let id = padNext([""] + GPUCards.all.map(\.id), after: bcd.gpuCard); bcd.gpuCard = id; LibraryPrefs.setGPUCard(id, for: entry.windowsPath)
            }
            Group {
                Toggle(isOn: Binding(get: { bcd.nvidia }, set: { on in bcd.nvidia = on; LibraryPrefs.setNvidia(on, for: entry.windowsPath) })) {
                    compatLabel("Report an NVIDIA GPU", "For \"no graphics card\" errors")
                }
                .padItem("gx-nvidia", cornerRadius: 12, when: GPUCards.card(bcd.gpuCard) == nil, inset: -6) {
                    let on = !bcd.nvidia; bcd.nvidia = on; LibraryPrefs.setNvidia(on, for: entry.windowsPath)
                }
                Toggle(isOn: Binding(get: { bcd.olderNvidia }, set: { on in bcd.olderNvidia = on; LibraryPrefs.setOlderNvidia(on, for: entry.windowsPath) })) {
                    compatLabel("Older NVIDIA card (Direct3D 9)", "For older games that crash with this GPU, like Fallout 3 and New Vegas")
                }
                .padItem("gx-oldnvidia", cornerRadius: 12, when: GPUCards.card(bcd.gpuCard) == nil, inset: -6) {
                    let on = !bcd.olderNvidia; bcd.olderNvidia = on; LibraryPrefs.setOlderNvidia(on, for: entry.windowsPath)
                }
            }
            .disabled(GPUCards.card(bcd.gpuCard) != nil)
            Toggle(isOn: Binding(get: { bcd.wineVCRT }, set: { on in bcd.wineVCRT = on; LibraryPrefs.setWineVCRT(on, for: entry.windowsPath) })) {
                compatLabel(L("Wine's C++ runtime"), L("Instead of the game's msvcp/vcruntime"))
            }
            .padItem("gx-vcrt", cornerRadius: 12, inset: -6) { let on = !bcd.wineVCRT; bcd.wineVCRT = on; LibraryPrefs.setWineVCRT(on, for: entry.windowsPath) }
            // Japanese locale (LibraryPrefs.japanese, BCDLaunch.applyExtras, WineProcessBridge.m).
            Toggle(isOn: Binding(get: { bcd.japanese }, set: { on in bcd.japanese = on; LibraryPrefs.setJapanese(on, for: entry.windowsPath) })) {
                compatLabel(L("Japanese locale"), L("For Japanese games and visual novels whose text shows as squares or gibberish, or that do not start"))
            }
            .padItem("gx-japanese", cornerRadius: 12, inset: -6) { let on = !bcd.japanese; bcd.japanese = on; LibraryPrefs.setJapanese(on, for: entry.windowsPath) }
            // madeira-bcd: MADEIRA_REAL_SUSPEND for this game (BCDLaunch.realSuspend).
            Picker(selection: Binding(get: { bcd.realSuspend.map { $0 ? 1 : 2 } ?? 0 },
                                      set: { v in bcd.realSuspend = v == 0 ? nil : v == 1; LibraryPrefs.setRealSuspend(bcd.realSuspend, for: entry.windowsPath) })) {
                Text("Automatic").tag(0)
                Text("On").tag(1)
                Text("Off").tag(2)
            } label: {
                compatLabel(L("Pause threads fully"), L("For Unity games that crash while loading, like Megabonk. Can make other games freeze"))
            }
            .padItem("gx-suspend", cornerRadius: 12, inset: -6) {
                let v = padNext([0, 1, 2], after: bcd.realSuspend.map { $0 ? 1 : 2 } ?? 0)
                bcd.realSuspend = v == 0 ? nil : v == 1; LibraryPrefs.setRealSuspend(bcd.realSuspend, for: entry.windowsPath)
            }
            // Fastsync-only switches: shown for every game, usable only while
            // Settings › Sync engine is Fastsync.
            Group {
                Toggle("Fast synchronization", isOn: Binding(get: { entry.fastSync ?? true }, set: { entry.fastSync = $0 }))
                    .padItem("gx-fastsync", cornerRadius: 12, when: syncEngine == .fastsync, inset: -6) { entry.fastSync = !(entry.fastSync ?? true) }
                Toggle("Fast semaphore waits (experimental)",
                       isOn: Binding(get: { entry.semaphoreFastPath ?? false }, set: { entry.semaphoreFastPath = $0 }))
                    .padItem("gx-semaphore", cornerRadius: 12, when: syncEngine == .fastsync, inset: -6) { entry.semaphoreFastPath = !(entry.semaphoreFastPath ?? false) }
            }
            .disabled(syncEngine != .fastsync)
            if syncEngine != .fastsync {
                Text("Choose Fastsync in Settings › Memory & sync to use these.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Compatibility & performance") } footer: {
            Text("Applies at the next launch.")
        }
    }
    private func compatLabel(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var steamPage: some View {
        // A Steam game's start, update, repair and Uninstall (SteamGames.swift).
        if entry.steamAppID != nil {
            SteamEntrySection(entry: $entry) { leaving = true; closePage() }
            Section {
                Text(entry.launchWindowsPath).font(.caption.monospaced()).textSelection(.enabled)
                if entry.startsSteamGameDirectly, !entry.launchArguments.isEmpty {
                    Text(entry.launchArguments).font(.caption.monospaced()).textSelection(.enabled)
                }
            } header: { Text("Executable") }
            if model.entries.contains(where: { $0.id == entry.id }) { GameMoveSection(entry: $entry) }
        }
    }

    @ViewBuilder private var libraryPage: some View {
        if entry.desktop != true { Section("Library details") {
            TextField("Title", text: $entry.title)
            Button("Find on Steam", systemImage: "magnifyingglass") { findCover = true }
                .padItem("gb-find", cornerRadius: 12, inset: -6) { findCover = true }
            Button("Choose cover image", systemImage: "photo") { importCover = true }
                .padItem("gb-cover", cornerRadius: 12, inset: -6) { importCover = true }
            if entry.coverFile != nil {
                Button((entry.steamAppID ?? entry.steamID) != nil ? L("Use Steam artwork") : L("Remove cover image")) { entry.coverFile = nil }
                    .padItem("gb-art", cornerRadius: 12, inset: -6) { entry.coverFile = nil }
            }
        } }
        // A link that starts this game from a Home Screen icon (SavesAndShortcuts.swift).
        if entry.desktop != true {
            Section {
                Button {
                    UIPasteboard.general.string = ShortcutRouter.link(for: entry.windowsPath)
                    copiedLink = true
                } label: {
                    Label(copiedLink ? L("Link copied") : L("Copy Home Screen shortcut link"),
                          systemImage: copiedLink ? "checkmark" : "link")
                }
            } header: { Text("Home Screen") } footer: {
                Text("Shortcuts › Open URLs › paste › Add to Home Screen.")
            }
        }
        if entry.steamAppID == nil && entry.desktop != true {
            Section("Executable") { Text(entry.windowsPath).font(.caption.monospaced()).textSelection(.enabled) }
            if model.entries.contains(where: { $0.id == entry.id }) { GameMoveSection(entry: $entry) }
            Section { Button("Remove from library", role: .destructive) { remove = true }.padItem("gb-remove", cornerRadius: 12, inset: -6) { remove = true } }
        }
        if let error { Section { Text(error).foregroundStyle(.red) } }
    }

    /// The game's folder under drive_c, where Settings files looks for .ini files.
    private var iniGameFolder: String {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: LibraryModel.drive.appendingPathComponent(entry.relativePath).path, isDirectory: &isDirectory)
        return GameIniFiles.gameFolder(relativePath: entry.relativePath, isDirectory: exists && isDirectory.boolValue)
    }

    /// What Mods (ModsView.swift) works on: the game's folder, its program, drive_c (for
    /// plugins.txt and Fallout.ini) and the game's own config (the BepInEx line).
    private var modGame: ModGame {
        let folder = iniGameFolder
        let launch = entry.launchRelativePath
        let program = !folder.isEmpty && launch.hasPrefix(folder + "/") ? String(launch.dropFirst(folder.count + 1)) : nil
        let gameFolder = folder.isEmpty ? LibraryModel.drive : LibraryModel.drive.appendingPathComponent(folder, isDirectory: true)
        let windowsPath = entry.windowsPath
        return ModGame(id: entry.id.uuidString, gameFolder: gameFolder, drive: LibraryModel.drive, program: program,
                       bethesda: BethesdaGame.detect(steamAppID: entry.steamAppID, program: program.map { ($0 as NSString).lastPathComponent },
                                                     gameFolder: gameFolder),
                       readConfig: { GameProfile(windowsPath: windowsPath).text },
                       writeConfig: { GameProfile(windowsPath: windowsPath).text = $0 })
    }

    @ViewBuilder private var advancedPage: some View {
        Section {
            Toggle("Live logs", isOn: $entry.liveLogs)
                .padItem("ga-live", cornerRadius: 12, inset: -6) { entry.liveLogs.toggle() }
            // madeira-bcd: this game's config is its own GameProfiles.swift file
            // (Application Support/GameConfigs/<hash>.cfg), the file every launch of
            // the game exports as MADEIRA_CFG_GAME. Lines an entry saved in upstream's
            // `config` field are moved into it when the page opens (migrateEntryOptions).
            NavigationLink {
                LibraryGameConfigEditor(text: Binding(get: { bcd.configText }, set: { text in
                    bcd.configText = text
                    GameProfile(windowsPath: entry.windowsPath).text = text
                }))
                .onDisappear { reloadBCD() }
            } label: {
                LabeledContent("This game's config", value: Self.configSummary(bcd.configText))
            }
        } header: { Text("Advanced") } footer: {
            Text("Per-game madeira.cfg lines; they override the global file.")
        }
        // (debug-logging) Test bundle only (com.willfaust.madeora.test): a level that writes plain logging lines into
        // this game's own config and takes exactly those lines out again; Copy debug info puts the game, build, level
        // and config on the clipboard. Not shown in a release build. English only, like the other developer rows.
        if DebugLogging.available {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "Debug logging")
                    Picker(selection: debugLevel) {
                        ForEach(DebugLogging.Level.allCases) { Text(verbatim: $0.title).tag($0) }
                    } label: { Text(verbatim: "Debug logging") }
                        .pickerStyle(.segmented).labelsHidden()
                    Text(verbatim: debugLevel.wrappedValue.summary).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    UIPasteboard.general.string = DebugLogging.debugInfo(title: entry.title, windowsPath: entry.windowsPath, recommended: recommended?.fileText)
                    LogStore.shared.log("[debug-log] debug info copied for \(entry.title)")
                    debugCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { debugCopied = false }
                } label: {
                    Label { Text(verbatim: debugCopied ? "Copied" : "Copy debug info") }
                        icon: { Image(systemName: debugCopied ? "checkmark" : "doc.on.clipboard") }
                }
                DebugShareGameLogsButton(entry: entry)
                DebugResetButton(entry: entry) { reloadBCD() }
            } footer: {
                Text(verbatim: "Test build only. A level adds plain env lines to This game's config (never madeira.cfg); changing it or choosing Off removes exactly those lines. Applies at the next start. Copy debug info copies the game, build, level, how this config differs from Madeira's Recommended settings, and the config. Share this game's logs zips only this game's last run and its config. Reset to clean state removes the Debug logging lines and the lines Get Help added.")
            }
        }
        // (get-help) While lines Get Help added are in this game's config (GetHelpView.swift).
        if GetHelp.enabled {
            GetHelpUndoSection(windowsPath: entry.windowsPath, title: entry.title) { reloadBCD() }
            if GetHelp.key != nil { GetHelpWorksSection(entry: entry) }
        }
        // (compat-report) Discord: a one-tap copy of #game-compatibility's report format. Here and not in
        // Game details' last group, which stays short with Uninstall on its own. env.MADEIRA_COMPAT_REPORT = 0 hides it.
        if CompatReport.enabled {
            Section {
                Button {
                    UIPasteboard.general.string = CompatReport.text(for: entry)
                    LogStore.shared.log("[compat-report] copied for \(entry.title)")
                    compatCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { compatCopied = false }
                } label: {
                    if compatCopied {
                        Label("Copied", systemImage: "checkmark")
                    } else {
                        Label("Copy Compat Report", systemImage: "doc.on.clipboard")
                    }
                }
            } footer: {
                Text("Copies this device, iOS version, Madeira version and the game's store in the format the Madeira Discord's game-compatibility posts use. Fill in Results before posting.")
            }
        }
        // (game-actions-advanced) madeira-bcd: the setup, help and reset actions, for every entry, the Desktop too
        // (GameRecommendationsApply.swift). Moved here from Game details with Copy Compat Report, so Game details
        // ends with Uninstall on its own.
        Section {
            Button("Share Setup", systemImage: "square.and.arrow.up") { model.save(entry); shareSetup = true }
                .padItem("ga-share", cornerRadius: 12, inset: -6) { model.save(entry); shareSetup = true }
            Button("Apply Shared Setup", systemImage: "square.and.arrow.down") { askSetupSource = true }
                .padItem("ga-apply", cornerRadius: 12, inset: -6) { askSetupSource = true }
                .confirmationDialog("Apply a shared setup", isPresented: $askSetupSource, titleVisibility: .visible) {
                    Button("Choose a File") { importSetup = true }
                    Button("Paste from Clipboard") { readSetup { try GameSetup(text: UIPasteboard.general.string ?? "") } }
                }
            Button("Copy Settings", systemImage: "doc.on.doc") {
                let configText = entry.config ?? ""
                UIPasteboard.general.string = configText.isEmpty ? "# Default configuration" : configText
            }
            // (get-help) Get Help from Claude is in the Get Help sheet's "Still stuck?" now (GetHelpView.swift),
            // so the game page has one help button (Cameron, Nov 7). Settings › Diagnostics keeps its own.
            // LogsView.swift (get-help-auto): one scrubbed "<game> log.txt", Get Help's short report.
            ShareLogsButton(entry: entry)
            Button("Reset to Recommended", systemImage: "arrow.counterclockwise") { confirmReset = true }
                .padItem("ga-reset", cornerRadius: 12, inset: -6) { confirmReset = true }
                .confirmationDialog(GameRecommendations.question(recommended, desktop: entry.desktop == true),
                                    isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Reset", role: .destructive) { resetToRecommended() }
                }
        } footer: {
            Text(GameRecommendations.note(recommended, desktop: entry.desktop == true))
        }
        .fileImporter(isPresented: $importSetup,
                      allowedContentTypes: [GameSetup.contentType, .json, .plainText, .data]) { result in
            readSetup { try GameSetup.read(file: try result.get()) }
        }
    }

    var body: some View {
        LibraryDetailNavigation(own: stack == nil, path: $path) {
          newLookPage
            .navigationTitle(stack == nil ? L("Game details") : entry.title).navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Page.self) { item in page(item) }
            .toolbarBackground(.regularMaterial, for: .navigationBar)
            .toolbarBackground(stack == nil ? .visible : .automatic, for: .navigationBar)
            .toolbar {
                // A pushed page has the system's Back button instead.
                if stack == nil { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.save(entry); closePage() } } }
            }
            // The full-screen page draws its own back button over the page; pushed, it has the system's.
            .toolbar(stack == nil ? .hidden : .automatic, for: .navigationBar)
            .task {
                if entry.graphicsAPI == nil, entry.desktop != true, let url = try? LibraryModel.executable(entry.relativePath) { entry.graphicsAPI = LibraryModel.graphicsImports(url) }
            }
            // Play's checks read the installed games and Dock's client state, which the
            // Steam page refreshed when it was on this page.
            .onAppear { if entry.steamAppID != nil { MadeiraDockModel.shared.refresh(); SteamGamesModel.shared.refresh() } }
            // madeira-bcd: the game's own switches and config file, and its recommended settings.
            .onAppear {
                migrateEntryOptions()
                prepareRecommendation()
                reloadBCD()
            }
        }
        // The new look's controller: the page is a layer over the library; B goes back a page or
        // closes it, X is Play (PadHighlight.swift).
        .padLayer("game", start: lookReturn ?? "gp-play", back: { lookBack() }, play: { if path.isEmpty { start() } }, page: stack != nil)
        .sheet(isPresented: $shareSetup) { GameSetupShareSheet(entry: entry) }
        // (get-help) Apply writes the game's config: the page reads it again when the sheet goes.
        .getHelpSheet($getHelp, entry: entry) { reloadBCD() }
        .sheet(item: $setupToApply) { pending in
            GameSetupApplySheet(setup: pending.setup, gameTitle: entry.title,
                                otherGame: pending.setup.match(steamAppID: entry.steamAppID, program: GameSetup.programName(entry)) == 0) { controls, ini in
                do {
                    try pending.setup.apply(to: &entry, controls: controls, iniFiles: ini)
                    model.save(entry)
                    reloadBCD()
                } catch {
                    setupError = "This setup could not be applied: \(error.localizedDescription)"
                }
            }
        }
        .alert("Shared setup", isPresented: Binding(get: { setupError != nil }, set: { if !$0 { setupError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(setupError ?? "") }
        .sheet(isPresented: $findCover) { SteamSearchView(query: entry.title) { match in entry.steamID = match.id; entry.title = match.name; entry.coverFile = nil } }
        .fileImporter(isPresented: $importCover, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let attrs = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (attrs.fileSize ?? Int.max) <= 20_000_000 else { throw LibraryError.message(L("Choose an image smaller than 20 MB.")) }
                let data = try Data(contentsOf: url)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1200, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                      let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85) else { throw LibraryError.message(L("This image could not be opened.")) }
                let dir = LibraryModel.documents.appendingPathComponent("madeira-art", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let name = entry.id.uuidString + ".jpg"; try jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)
                LibraryCoverCache.Source.coverFileChanged(named: name); entry.coverFile = name
            } catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("Remove this library entry? Your executable and saves stay in drive_c.", isPresented: $remove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { leaving = true; model.remove(entry.id); closePage() }
        }
        .onDisappear { if !leaving { model.save(entry) } }
    }
}

/// (new look) How a game page pushed inside a tab moves on its tab's page stack (LibraryView.lookRoute).
struct LibraryDetailStack {
    /// One of the game page's own pages (Display, Controls...), pushed over it.
    let push: (LibraryDetail.Page) -> Void
    /// The top page off the stack (Back, B).
    let back: () -> Void
    /// The game page and any of its pages off the stack (uninstalled, removed).
    let close: () -> Void
}

/// The game page's own NavigationStack when it is a sheet or a cover; none when it is pushed
/// inside a tab's stack (a stack inside a stack breaks Back).
private struct LibraryDetailNavigation<Content: View>: View {
    let own: Bool
    @Binding var path: [LibraryDetail.Page]
    @ViewBuilder var content: Content
    var body: some View {
        if own { NavigationStack(path: $path) { content } } else { content }
    }
}

/// madeira-bcd: a game's own options as the fork stores them (LibraryDetail):
/// LibraryPrefs' switches and the GameProfiles.swift file's lines.
struct BCDGameValues {
    var avx = false, nvidia = false, olderNvidia = false, wineVCRT = false, japanese = false
    var gpuCard = ""
    var realSuspend: Bool? = nil, unityIL2CPP = false
    var configText = ""
    init() {}
    init(windowsPath: String) {
        avx = LibraryPrefs.avx(windowsPath)
        nvidia = LibraryPrefs.nvidia(windowsPath)
        olderNvidia = LibraryPrefs.olderNvidia(windowsPath)
        gpuCard = LibraryPrefs.gpuCard(windowsPath) ?? ""
        wineVCRT = LibraryPrefs.wineVCRT(windowsPath)
        japanese = LibraryPrefs.japanese(windowsPath)
        realSuspend = LibraryPrefs.realSuspend(windowsPath)
        configText = GameProfile(windowsPath: windowsPath).text
    }
}

/// Game details › This game's config: the game's own lines in madeira.cfg's
/// syntax, applied at its next start. madeira-bcd: LibraryDetail binds it to the
/// game's GameProfiles.swift file (Application Support/GameConfigs), which every
/// launch exports as MADEIRA_CFG_GAME (BCDLaunch, MadeiraConfig.applyGame).
struct LibraryGameConfigEditor: View {
    @Binding var text: String
    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.caption.monospaced()).frame(minHeight: 260)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } footer: {
                Text("One key = value per line, as in madeira.cfg; lines starting with # are comments. Examples: fence-chain = 6, dxmt = d3d11.mipClampBC=1, env.FEX_MULTIBLOCK = 1.")
            }
        }
        .navigationTitle("This game's config").navigationBarTitleDisplayMode(.inline)
    }
}

/// Game details › Find on Steam: searches the public store by title; choosing
/// a result gives the entry that app's name and store artwork.
struct SteamSearchView: View {
    @State internal var query: String
    var select: (SteamMatch) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var results: [SteamMatch] = []
    @State private var error: String?
    @State private var loading = false
    @State private var submitted = ""
    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView("Searching Steam…") }
                if let error { Text(error).foregroundStyle(.secondary) }
                ForEach(results) { match in
                    Button { select(match); dismiss() } label: {
                        HStack {
                            AsyncImage(url: URL(string: match.tiny_image ?? "")) { $0.resizable().scaledToFit() } placeholder: { Image(systemName: "gamecontroller") }.frame(width: 70, height: 40)
                            Text(match.name).foregroundStyle(.primary)
                        }
                    }
                }
            }.navigationTitle("Find on Steam")
            .searchable(text: $query, prompt: "Title").onSubmit(of: .search) { submitted = query }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { submitted = query }
            .task(id: submitted) {
                guard !submitted.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                loading = true; error = nil
                do { let found = try await SteamCatalog.search(submitted); try Task.checkCancellation(); results = found; if found.isEmpty { error = L("No matches. Try a different title.") } }
                catch is CancellationError { return }
                catch { self.error = error.localizedDescription }
                loading = false
            }
        }
    }
}

/// Keyboard-and-mouse mode: one row per controller input with a menu of what it
/// does, saved to the game. Used as a page of the Session menu (live: the driver
/// takes each change at once) and as a sheet from Game details. Rows the player
/// has not changed show the layout's or the template's action and are not stored.
struct ControllerBindsPage: View {
    @Binding var binds: [String: ControlAction]?
    /// Vertical speed of the right-stick mouse, 1 = as horizontal; nil = 1.
    @Binding var mouseVertical: Double?
    /// The active layout's own bindings, so an unchanged row shows what really
    /// happens in this session; Game details passes none.
    var controls: [TouchControl] = []

    private static let groups: [(String, [String])] = [
        ("Sticks", ["LS", "RS"]),
        ("Face", ["A", "B", "X", "Y"]),
        ("Bumpers & triggers", ["LB", "RB", "LT", "RT"]),
        ("D-pad", ["D↑", "D↓", "D←", "D→"]),
        ("System", ["Menu", "View", "L3", "R3"]),
    ]

    var body: some View {
        ForEach(Self.groups, id: \.0) { group in
            Section(group.0) {
                ForEach(group.1, id: \.self) { name in row(name) }
            }
        }
        if effective("RS").stickKeys == nil {
            Section("Right stick as mouse") {
                LabeledContent("Vertical speed") {
                    HStack {
                        Slider(value: Binding(get: { mouseVertical ?? 1 }, set: { mouseVertical = abs($0 - 1) < 0.01 ? nil : $0 }), in: 0.25...1.5, step: 0.05)
                        Text("\(Int(((mouseVertical ?? 1) * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
                Text("Relative to horizontal. Games scale the camera's pitch and yaw differently from a mouse; lower this if the view climbs faster than it turns.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section {
            Button("Reset all to defaults", role: .destructive) { reset() }
                .disabled(!changed)
            Text("Defaults: left stick WASD, right stick mouse, RT and LT click, D-pad arrows, A Space, B Ctrl, X E, Y R, LB Q, RB F, L3 Shift, R3 C, Start Esc, Select Tab. A touch control's own controller binding (control editor) applies when a row is at its default.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Anything to reset: a bound row or a vertical speed other than 1.
    var changed: Bool { !(binds ?? [:]).isEmpty || mouseVertical != nil }
    func reset() { binds = nil; mouseVertical = nil }

    /// What the input does in this session: the table's entry, else the layout's, else the template's.
    private func effective(_ name: String) -> ControlAction {
        let fromLayout = PadBindings.build(controls: controls)
        return binds?[name] ?? (name == "LS" ? fromLayout.leftStick : name == "RS" ? fromLayout.rightStick : fromLayout.buttons[name] ?? .none)
    }

    private func row(_ name: String) -> some View {
        let effective = effective(name)
        let changed = binds?[name] != nil
        return LabeledContent(PadBindings.displayName(name)) {
            Menu {
                if name == "LS" || name == "RS" {
                    pick(name, name == "RS" ? "Mouse" : "Nothing", .none)
                    pick(name, "WASD", .joystickWASD)
                    pick(name, "Arrow keys", .joystickArrows)
                } else {
                    pick(name, "Left click", .mouseLeft)
                    pick(name, "Right click", .mouseRight)
                    Menu("Letters") { ForEach(0x41...0x5A, id: \.self) { vk in pick(name, String(UnicodeScalar(UInt8(vk))), .key(Int32(vk))) } }
                    Menu("Numbers") { ForEach(0x30...0x39, id: \.self) { vk in pick(name, String(UnicodeScalar(UInt8(vk))), .key(Int32(vk))) } }
                    Menu("Function keys") { ForEach(0...11, id: \.self) { i in pick(name, "F\(i + 1)", .key(Int32(0x70 + i))) } }
                    Menu("Modifiers & editing") {
                        pick(name, "Escape", .key(0x1B)); pick(name, "Tab", .key(0x09)); pick(name, "Shift", .key(0x10))
                        pick(name, "Ctrl", .key(0x11)); pick(name, "Alt", .key(0x12)); pick(name, "Space", .key(0x20))
                        pick(name, "Enter", .key(0x0D)); pick(name, "Backspace", .key(0x08)); pick(name, "Caps Lock", .key(0x14))
                    }
                    Menu("Navigation") {
                        pick(name, "↑", .key(0x26)); pick(name, "↓", .key(0x28)); pick(name, "←", .key(0x25)); pick(name, "→", .key(0x27))
                        pick(name, "Insert", .key(0x2D)); pick(name, "Delete", .key(0x2E)); pick(name, "Home", .key(0x24))
                        pick(name, "End", .key(0x23)); pick(name, "Page Up", .key(0x21)); pick(name, "Page Down", .key(0x22))
                    }
                    Menu("Symbols") {
                        pick(name, "-", .key(0xBD)); pick(name, "=", .key(0xBB)); pick(name, "[", .key(0xDB)); pick(name, "]", .key(0xDD))
                        pick(name, "\\", .key(0xDC)); pick(name, ";", .key(0xBA)); pick(name, "'", .key(0xDE)); pick(name, ",", .key(0xBC))
                        pick(name, ".", .key(0xBE)); pick(name, "/", .key(0xBF)); pick(name, "`", .key(0xC0))
                    }
                    Menu("Numpad") {
                        ForEach(0...9, id: \.self) { i in pick(name, "Numpad \(i)", .key(Int32(0x60 + i))) }
                        pick(name, "Numpad *", .key(0x6A)); pick(name, "Numpad +", .key(0x6B)); pick(name, "Numpad −", .key(0x6D))
                        pick(name, "Numpad .", .key(0x6E)); pick(name, "Numpad /", .key(0x6F))
                    }
                    pick(name, "Show keyboard", .keyboardToggle)
                    pick(name, "Nothing", .none)
                }
                if changed {
                    Divider()
                    Button("Default") { binds?[name] = nil; if binds?.isEmpty == true { binds = nil } }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(Self.describe(effective, input: name))
                        .foregroundStyle(changed ? .primary : .secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pick(_ name: String, _ title: String, _ action: ControlAction) -> some View {
        Button(title) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            var table = binds ?? [:]
            table[name] = action
            binds = table
        }
    }

    /// Row text for an action, in the words the menu uses.
    static func describe(_ action: ControlAction, input: String) -> String {
        switch action {
        case .none:            return input == "RS" ? "Mouse" : "Nothing"
        case .mouseLeft:       return "Left click"
        case .mouseRight:      return "Right click"
        case .joystickWASD:    return "WASD"
        case .joystickArrows:  return "Arrow keys"
        case .keyboardToggle:  return "Show keyboard"
        case .pad(let n):      return n
        case .key(let vk):     return keyName(vk)
        }
    }
    static func keyName(_ vk: Int32) -> String {
        switch vk {
        case 0x20: return "Space"
        case 0x0D: return "Enter"
        case 0x09: return "Tab"
        case 0x1B: return "Escape"
        case 0x10: return "Shift"
        case 0x11: return "Ctrl"
        case 0x12: return "Alt"
        case 0x08: return "Backspace"
        case 0x14: return "Caps Lock"
        case 0x2D: return "Insert"
        case 0x2E: return "Delete"
        case 0x24: return "Home"
        case 0x23: return "End"
        case 0x21: return "Page Up"
        case 0x22: return "Page Down"
        case 0x70...0x7B: return "F\(vk - 0x6F)"
        case 0x60...0x69: return "Numpad \(vk - 0x60)"
        case 0x6A: return "Numpad *"
        case 0x6B: return "Numpad +"
        case 0x6D: return "Numpad −"
        case 0x6E: return "Numpad ."
        case 0x6F: return "Numpad /"
        default:   return ControlAction.keyLabel(vk)
        }
    }
}

/// Game details: whether a Steam game that Valve's client starts (Madeira Dock)
/// can start without a connection (DockOffline.Mark). Steam's offline sign-in
/// belongs to the account: once Valve's client has reported that it can sign the
/// account in offline, every installed game can start that way, and the client
/// answers the license question from the list it cached. Only a game whose
/// per-user program Steam prepares on its first start still needs that one start
/// online. Tapping the line explains it; an offline start is always Steam's
/// decision at that moment.
struct DockOfflineMark: View {
    let appID: Int
    @State private var explain = false
    /// The game's install record lists per-user executables (read once; it scans the library).
    @State private var preparedOnline = false
    var body: some View {
        let mark = DockOffline.mark(appID, preparedOnline: preparedOnline)
        let ready: Bool = { if case .ready = mark { return true } else { return false } }()
        Button { explain = true } label: {
            // Not a Label: inside a Form row a Label takes the list's wide icon column,
            // which leaves the text far from its symbol.
            HStack(spacing: 5) {
                Image(systemName: ready ? "checkmark.circle.fill" : "wifi.exclamationmark")
                Text(Self.line(mark))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(ready ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .task { preparedOnline = MadeiraDock.games(drive: MadeiraDock.drive).first { $0.id == appID }?.customExecutables ?? false }
        .alert(ready ? L("Can be played offline") : L("Not ready for offline play yet"), isPresented: $explain) {
            Button("OK", role: .cancel) {}
        } message: { Text(Self.explanation(mark)) }
    }
    static func line(_ mark: DockOffline.Mark) -> String {
        switch mark {
        case .ready: return L("Can be played offline")
        case .needsFirstStart: return L("Start once online to play offline")
        case .needsOnline: return L("Start a game online to play offline")
        }
    }
    static func explanation(_ mark: DockOffline.Mark) -> String {
        switch mark {
        case .ready(let saved):
            return "Steam signed in online on this device on \(saved.formatted(date: .abbreviated, time: .omitted)) and can now sign this account in without a connection. With no internet, Madeira asks Steam to start the game offline; Steam checks its saved sign-in and its saved list of your licenses each time. Its offline sign-in expires after a while, so start a game online now and then. A game that needs its own servers still needs them."
        case .needsFirstStart:
            return "Steam can sign this account in offline, but it prepares this game's program for your account the first time it starts, and that needs a connection. Start this game once while you are online."
        case .needsOnline:
            return "Steam has not saved an offline sign-in on this device yet. Start any Steam game once while you are online; after that, installed games can start without a connection."
        }
    }
}

/// Game details and the Session menu: how a physical controller reaches the game.
struct ControllerModeChoice: View {
    @Binding var mode: String?
    var body: some View {
        LabeledContent("Controller") {
            Picker("Controller", selection: Binding(get: { mode ?? "" }, set: { mode = $0.isEmpty ? nil : $0 })) {
                Text("Game's own support").tag("")
                Text("XInput and DirectInput").tag("dinput")
                Text("Keyboard and mouse").tag("keys")
            }.pickerStyle(.menu).labelsHidden()
        }
    }
}

/// Game details › Launch arguments: one chip per common flag, highlighted when
/// the arguments contain it; a tap adds or removes it. -dx9 to -dx12 exclude each
/// other, as do -windowed and -fullscreen. Quoted arguments are kept whole.
struct LaunchFlagChips: View {
    @Binding var arguments: String
    static let flags = ["-dx11", "-dx12", "-dx10", "-dx9", "-windowed", "-fullscreen", "-nosplash"]

    /// The arguments split at unquoted spaces and tabs, quotes kept.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = [], current = "", quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            if !quoted && (character == " " || character == "\t") {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
    static func contains(_ text: String, _ flag: String) -> Bool {
        tokens(text).contains { $0.caseInsensitiveCompare(flag) == .orderedSame }
    }
    static func toggled(_ text: String, _ flag: String) -> String {
        var parts = tokens(text)
        if contains(text, flag) {
            parts.removeAll { $0.caseInsensitiveCompare(flag) == .orderedSame }
        } else {
            let renderers = ["-dx9", "-dx10", "-dx11", "-dx12"]
            if renderers.contains(flag) { parts.removeAll { renderers.contains($0.lowercased()) } }
            if flag == "-windowed" { parts.removeAll { $0.lowercased() == "-fullscreen" } }
            if flag == "-fullscreen" { parts.removeAll { $0.lowercased() == "-windowed" } }
            parts.append(flag)
        }
        return parts.joined(separator: " ")
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.flags, id: \.self) { flag in
                    let on = Self.contains(arguments, flag)
                    Button(flag) { arguments = Self.toggled(arguments, flag) }
                        .buttonStyle(.bordered).tint(on ? Color.accentColor : Color.gray)
                        .font(.caption.monospaced())
                        .accessibilityValue(on ? L("On") : L("Off"))
                }
            }
        }
    }
}

struct FPSChoice: View {
    @Binding var mode: Int
    var body: some View {
        HStack { Text("FPS limit"); Spacer(); Picker("FPS limit", selection: $mode) {
            // 30 needs DXMT's 30 FPS cap (ProMotionIntent.has30Cap); a saved 30 stays selectable.
            if ProMotionIntent.has30Cap || mode == 3 { Text("30 FPS").tag(3) }
            // 40 needs DXMT's 40 FPS cap and a 120 Hz panel (ProMotionIntent.has40Cap).
            if ProMotionIntent.has40Cap || mode == 4 { Text("40 FPS").tag(4) }
            Text("60 FPS").tag(1); Text("Display maximum").tag(0); Text("Uncapped").tag(2)
        }.labelsHidden().pickerStyle(.menu) }
    }
    /// The choices in the menu's order; A on the controller steps to the next one (Game details).
    static func order(current: Int) -> [Int] {
        (ProMotionIntent.has30Cap || current == 3 ? [3] : []) + (ProMotionIntent.has40Cap || current == 4 ? [4] : []) + [1, 0, 2]
    }
    static func next(after current: Int) -> Int {
        let choices = order(current: current)
        return choices[((choices.firstIndex(of: current) ?? -1) + 1) % choices.count]
    }
}

/// Holding the display at its maximum refresh rate in the 60 FPS limit
/// (madeira.cfg env.MADEIRA_PROMOTE = 1, off by default; see ProMotionIntent).
/// Applies from the next session start or FPS limit change.
struct DisplayRateSettings: View {
    @State private var hold = ProMotionIntent.holdMaximum

    var body: some View {
        Section {
            Toggle("Hold the display at its maximum rate", isOn: Binding(get: { hold }, set: { on in
                hold = on
                MadeiraConfig.set("env.MADEIRA_PROMOTE", on ? "1" : nil)
                LogStore.shared.log("[runtime-settings] promote=\(on ? 1 : 0)")
            }))
        } header: { Text("Display") } footer: {
            Text("Off by default. On a 120 Hz display, keeps the panel at 120 Hz during a game's 60 FPS limit so a frame that misses one refresh waits 8 ms instead of 17 ms. Uses more power.")
        }
    }
}

/// One row of Settings › Credits: a person, their GitHub account and what they did.
struct MadeiraCredit: View {
    let name: String
    let handle: String
    let role: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(name).font(.body.weight(.semibold))
                if let url = URL(string: "https://github.com/\(handle)") {
                    Link("@\(handle)", destination: url).font(.subheadline)
                }
            }
            Text(role).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Settings › Memory & sync: the JIT pool (madeira.cfg pool), the video memory
/// budget (vram-mb), the file-backed swap tier (swap-mb, off by default, and
/// env.MADEIRA_SWAP_COVERAGE, which allocations it backs) and the in-process sync
/// engine (SyncEngine: fastsync by default, madsync or Wine's own). All are read when Madeira starts,
/// so changes apply after a restart. "All settings" opens every other option.
/// MADEIRA_RUNTIME_SETTINGS=0 hides this section.
/// A sheet opened from Settings; LibraryView presents it from the Form itself.
enum SettingsSheet: String, Identifiable {
    case allSettings, steamSignIn, gogSignIn, epicSignIn, eaSignIn, dock
    var id: String { rawValue }
}

/// The in-process synchronisation engine, one per session. Fastsync is the default:
/// madeira.cfg with neither inproc-sync nor env.MADEIRA_FASTSYNC, for which the app
/// exports MADEIRA_FASTSYNC=auto (WineProcessBridge.m). Madsync is inproc-sync = 1;
/// Wine standard sync is inproc-sync = 0 without a fastsync value, as it was written
/// while madsync was the default. Mirrors madeira_cfg_sync_engine (build/madeira_cfg.h).
/// Wine reads both once per app run, and never runs fastsync while madsync is on.
enum SyncEngine: String, CaseIterable, Identifiable {
    case madsync, fastsync, wine
    var id: String { rawValue }
    var label: String {
        switch self {
        case .madsync: return "Madsync"
        case .fastsync: return L("Fastsync (default)")
        case .wine: return L("Wine standard sync")
        }
    }
    /// The MADEIRA_FASTSYNC values Wine treats as "fastsync on" (sync.c, event.c).
    static let fastsyncValues: Set<String> = ["1", "on", "yes", "auto", "cells"]
    static var current: SyncEngine {
        let inproc = MadeiraConfig.get("inproc-sync")
        if inproc != nil && MadeiraConfig.bool("inproc-sync", default: false) { return .madsync }
        if let fast = MadeiraConfig.get("env.MADEIRA_FASTSYNC") { return fastsyncValues.contains(fast) ? .fastsync : .wine }
        return inproc == nil ? .fastsync : .wine
    }
    static func apply(_ engine: SyncEngine) {
        switch engine {
        case .madsync: MadeiraConfig.set("inproc-sync", "1"); MadeiraConfig.set("env.MADEIRA_FASTSYNC", nil)
        case .fastsync: MadeiraConfig.set("inproc-sync", nil); MadeiraConfig.set("env.MADEIRA_FASTSYNC", nil)
        case .wine: MadeiraConfig.set("inproc-sync", "0"); MadeiraConfig.set("env.MADEIRA_FASTSYNC", nil)
        }
    }
}

/// Runs the extension memory experiment (MemoryHostTest.m): whether memory
/// created by the MadeiraMemoryHost extension stays off Madeira's footprint.
/// Results in Documents/memhost-test.txt and the log.
struct MemoryHostTestRow: View {
    @State private var running = false
    @State private var last = ""
    var body: some View {
        Button {
            running = true
            last = "Starting…"
            MadeiraMemoryHostTest({ line in
                LogStore.shared.log("[memhost] \(line)")
                DispatchQueue.main.async { last = line }
            }, {
                DispatchQueue.main.async { running = false }
            })
        } label: {
            Label(running ? "Testing extension memory…" : "Test extension memory", systemImage: "memorychip")
        }
        .disabled(running)
        if !last.isEmpty {
            Text(last).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RuntimeMemorySyncSettings: View {
    /// Opens a Settings sheet (LibraryView owns the presentation).
    var open: (SettingsSheet) -> Void = { _ in }
    /// Bumped when a Settings sheet closes, so the rows re-read madeira.cfg.
    var refresh = 0
    /// The keys this section and Settings › Display and Graphics own; All settings and the Settings
    /// search leave them out.
    static let featuredKeys: Set<String> = Set(["pool", "vram-mb", "swap-mb", "env.MADEIRA_SWAP_COVERAGE", "donor-pool-mb", "swap-wow64",
                                                "inproc-sync", "env.MADEIRA_FASTSYNC", "eco"]).union(GraphicsSettings.featuredKeys)
    // ml1241: 256 (the launch's lower bound) for the pool, 512 and 1024 for video memory
    // (winemetal accepts vram-mb >= 256), at the user's request.
    static let poolChoices = [0, 256, 512, 640, 768, 1024, 1152]          // 0 = the standard 896 MB
    static let vramChoices = [0, 512, 1024, 1536, 2048, 3072, 4096, 4352, 4608, 5120, 6144]   // 0 = automatic
    static let swapChoices = [0, 1024, 2048, 3072, 4096]
    static let donorPoolChoices = [0, 2048, 4096, 6144]   // ml1150: the donor pool, 512 MB regions
    /// The stored value "" (no key) and "classic" are the same rules, unless
    /// madeira.cfg has swap-mode = 2 (then no key means broad, ml1257).
    static let coverageChoices: [(String, String)] = [
        ("", L("Large allocations (8 MB+)")), ("blocks", L("All allocations of 1 MB+")), ("wide", L("1 MB+ and overflow")),
        ("broad", L("Whole reservations 4 MB+ (broad)")),
    ]
    @State private var poolMB = Self.intKey("pool")
    @State private var vramMB = Self.intKey("vram-mb")
    @State private var swapMB = Self.intKey("swap-mb")
    @State private var donorPoolMB = Self.intKey("donor-pool-mb")
    @State private var coverage = Self.currentCoverage()
    @State private var wow64 = MadeiraConfig.get("swap-wow64") ?? ""
    static let wow64Choices: [(String, String)] = [
        ("", "Donor RAM only"), ("1", "Donor RAM, then the swap file"), ("2", "Never tiered (RAM only)"),
    ]
    @State private var engine = SyncEngine.current
    @State private var eco = MadeiraConfig.bool("eco", default: false)
    @State private var changed = false

    /// The configured value in MB, shown as itself even when it is not one of the choices.
    static func intKey(_ key: String) -> Int { Int(MadeiraConfig.get(key) ?? "") ?? 0 }
    static func currentCoverage() -> String {
        let v = (MadeiraConfig.get("env.MADEIRA_SWAP_COVERAGE") ?? "").lowercased()
        if v.isEmpty { return swapModeBroad ? "broad" : "" }
        return v == "classic" ? "" : v
    }
    /// ml1257: madeira.cfg swap-mode = 2 selects broad coverage when
    /// env.MADEIRA_SWAP_COVERAGE is unset (virtual_ios.c ios_swap_config).
    static var swapModeBroad: Bool { (Int(MadeiraConfig.get("swap-mode") ?? "") ?? 1) >= 2 }
    /// (donor-alone) ml2200: donor-pool-mb without swap-mb starts the donor pool on its own
    /// (WineProcessBridge.m, virtual_ios.c ios_swap_init) unless madeira.cfg has donor-only = 0.
    /// So the Donor pool picker is open with the swap tier off, and the pickers that shape the
    /// tier are open while either stage is on.
    static var donorAlone: Bool { (Int(MadeiraConfig.get("donor-only") ?? "") ?? 1) != 0 }
    private var tierOn: Bool { swapMB > 0 || (donorPoolMB > 0 && Self.donorAlone) }
    static func gb(_ mb: Int) -> String {
        String(format: "%g GB", Double(mb) / 1024)   // 1.5, 4, 4.25 ...
    }

    private func mbPicker(_ title: String, key: String, value: Binding<Int>, choices: [Int],
                          zero: String, label: @escaping (Int) -> String) -> some View {
        Picker(title, selection: Binding(get: { value.wrappedValue }, set: { mb in
            value.wrappedValue = mb; changed = true
            MadeiraConfig.set(key, mb > 0 ? String(mb) : nil)
            LogStore.shared.log("[runtime-settings] \(key)=\(mb)")
        })) {
            ForEach(choices, id: \.self) { mb in Text(mb == 0 ? zero : label(mb)).tag(mb) }
            if !choices.contains(value.wrappedValue) { Text("\(value.wrappedValue) MB").tag(value.wrappedValue) }
        }
    }

    var body: some View {
        Section {
            mbPicker(L("JIT pool"), key: "pool", value: $poolMB, choices: Self.poolChoices,
                     zero: L("Default (896 MB)"), label: { "\($0) MB" })
            mbPicker(L("Video memory"), key: "vram-mb", value: $vramMB, choices: Self.vramChoices,
                     zero: L("Automatic"), label: Self.gb)
            mbPicker(L("Swap tier"), key: "swap-mb", value: $swapMB, choices: Self.swapChoices,
                     zero: L("Off"), label: Self.gb)
            Picker("Swap coverage", selection: Binding(get: { coverage }, set: { mode in
                coverage = mode; changed = true
                // With swap-mode = 2 no key means broad, so classic is written out.
                MadeiraConfig.set("env.MADEIRA_SWAP_COVERAGE", mode.isEmpty ? (Self.swapModeBroad ? "classic" : nil) : mode)
                LogStore.shared.log("[runtime-settings] swap-coverage=\(mode.isEmpty ? "classic" : mode)")
            })) {
                ForEach(Self.coverageChoices, id: \.0) { Text($0.1).tag($0.0) }
                if !Self.coverageChoices.contains(where: { $0.0 == coverage }) { Text(coverage).tag(coverage) }
            }
            .disabled(!tierOn)
            mbPicker("Donor pool", key: "donor-pool-mb", value: $donorPoolMB, choices: Self.donorPoolChoices,
                     zero: "Off", label: Self.gb)
                .disabled(swapMB == 0 && !Self.donorAlone)
            // ml2021: a 32-bit program's memory takes donor RAM but never the swap file unless asked
            // (madeira.cfg swap-wow64, virtual_ios.c ios_swap_wow64_policy).
            Picker("32-bit programs", selection: Binding(get: { wow64 }, set: { choice in
                wow64 = choice; changed = true
                MadeiraConfig.set("swap-wow64", choice.isEmpty ? nil : choice)
                LogStore.shared.log("[runtime-settings] swap-wow64=\(choice.isEmpty ? "donor" : choice)")
            })) {
                ForEach(Self.wow64Choices, id: \.0) { Text($0.1).tag($0.0) }
                if !Self.wow64Choices.contains(where: { $0.0 == wow64 }) { Text(wow64).tag(wow64) }
            }
            .disabled(!tierOn)
            Picker("Sync engine", selection: Binding(get: { engine }, set: { choice in
                engine = choice; changed = true
                SyncEngine.apply(choice)
                LogStore.shared.log("[runtime-settings] sync-engine=\(choice.rawValue)")
            })) {
                ForEach(SyncEngine.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Eco mode", isOn: Binding(get: { eco }, set: { on in
                eco = on; changed = true
                MadeiraConfig.set("eco", on ? "1" : nil)
                LogStore.shared.log("[runtime-settings] eco=\(on ? 1 : 0)")
            }))
            Button { open(.allSettings) } label: {
                Label("All settings (\(ConfigCatalog.generated.count - Self.featuredKeys.count) more)", systemImage: "slider.horizontal.3")
            }
            MemoryHostTestRow()
        } header: { Text("Memory & sync") } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("JIT pool is the memory reserved at launch for translated x86 code (256 to 1152 MB; below 512 MB, large games can run out of room for it).")
                Text("Video memory is how much graphics memory games are told they have. Automatic sizes it from the memory free at launch. Too high can get Madeira closed for using too much memory; too low makes games keep reloading textures.")
                Text("Swap tier moves game data to a file on this device's storage when memory runs short, up to the chosen size, at some speed cost. Coverage decides which allocations it moves: large ones only (8 MB and up, the default), every allocation of 1 MB and up, or those plus allocations that overflow the game's address range. Broad backs every new reservation of 4 MB and up (madeira.cfg swap-min-mb moves the floor) as it is made, so the small commits games make inside it are covered too, and the swap tier size limits the storage it uses. Wider coverage saves more memory but can slow a game down.")
                Text("Donor pool gives the swap tier RAM that does not count against Madeira's memory limit: memory donated by Madeira's helper extension, which creates it, hands it over and exits, used before the swap file while the phone has memory to spare. It stops taking more when iOS reports memory pressure. Experimental. It works without the swap tier too: then no swap file is made, and memory the pool can't cover stays normal app memory.")
                Text("Sync engine: Fastsync (the default) handles events and semaphores in-process; its per-game options are in each game's details. Madsync is the older in-process engine. Wine standard sync uses neither. Only one engine runs at a time.")
                Text("Eco mode starts every game with its threads at a low priority, which saves power but makes games run slower. Off by default. It is meant for loading screens: Eco mode in the in-game menu turns it on and off while a game runs.")
                if changed { Text("Restart Madeira (close it from the app switcher) for these changes to apply.").foregroundStyle(.orange) }
            }
        }
        .onChange(of: refresh) { _, _ in
            poolMB = Self.intKey("pool"); vramMB = Self.intKey("vram-mb"); swapMB = Self.intKey("swap-mb"); donorPoolMB = Self.intKey("donor-pool-mb")
            coverage = Self.currentCoverage(); wow64 = MadeiraConfig.get("swap-wow64") ?? ""; engine = SyncEngine.current
            eco = MadeiraConfig.bool("eco", default: false)
        }
    }
}

struct LibraryPointerSettings: View {
    @ObservedObject private var input = InputSettings.shared
    /// Absolute, Relative or Touch; `touchMode` and `relative` stay mutually exclusive.
    private var mode: Binding<String> {
        Binding(get: { input.touchMode ? "touch" : (input.relative ? "relative" : "absolute") }, set: { value in
            input.touchMode = value == "touch"; input.relative = value == "relative"
            fputs("[frontend-pointer] mode=\(value)\n", stderr)
        })
    }
    var body: some View {
        Picker("Pointer mode", selection: mode) {
            Text("Absolute").tag("absolute"); Text("Relative").tag("relative"); Text("Touch").tag("touch")
        }.pickerStyle(.segmented)
        Text(input.touchMode ? L("Tap the screen to position and click. Hold and move to drag. Two fingers: right click or scroll.")
             : (input.relative ? L("Drag to send relative mouse movement for mouse-look. Tap to click.") : L("Drag the pointer like a trackpad. Tap to click.")))
            .font(.caption).foregroundStyle(.secondary)
        // A Bluetooth or USB mouse does nothing on iPhone until AssistiveTouch
        // is on (iOS routes pointer devices only through it); nothing says so.
        if UIDevice.current.userInterfaceIdiom == .phone {
            Text("Using a mouse? Turn on AssistiveTouch (Settings > Accessibility > Touch), then reopen Madeira.")
                .font(.caption).foregroundStyle(.secondary)
        }
        LabeledContent("Touch sensitivity") {
            Slider(value: input.relative ? $input.sensRel : $input.sensAbs, in: 0.1...8)
        }
    }
}

/// Settings › Display and Graphics: the Direct3D 9, 11 and 12 routes and the Vulkan driver as plain
/// controls for madeira.cfg d3d9, d3d11, d3d12 and vulkan (read at each session start by
/// ContentView.swift and WineProcessBridge.m; docs/BUILDING.md 6b, 6c and 6d). Default
/// removes the key. The rows show the global file only: a game's own config lines
/// still win for that game. While the section is shown All settings leaves these
/// keys out (RuntimeMemorySyncSettings.featuredKeys); MADEIRA_GRAPHICS_SETTINGS=0
/// hides the section and puts them back in All settings.
struct GraphicsSettings: View {
    static let shown = MadeiraConfig.flag("MADEIRA_GRAPHICS_SETTINGS")   // 0: no Settings › Graphics section; d3d9, d3d11, d3d12 and vulkan are back in All settings
    static let keys: Set<String> = ["d3d9", "d3d11", "d3d12", "vulkan"]
    static let glBackendKey = "gl-backend"
    /// The keys All settings and the Settings search leave to this section.
    static var featuredKeys: Set<String> { shown ? keys : [] }
    /// Bumped when a Settings sheet closes, so the rows re-read madeira.cfg.
    var refresh = 0

    static let d3d9Choices: [(String, String)] = [
        ("", L("DXMT (default)")), ("native", L("DXMT native frontend (32-bit)")), ("wined3d", L("Wine wined3d on OpenGL (Zink)")),
    ]
    static let d3d11Choices: [(String, String)] = [("", L("DXMT (default)")), ("dxvk", L("DXVK on Vulkan (experimental)"))]
    static let d3d12Choices: [(String, String)] = [("", L("madeira-d3d12 (default)")), ("vkd3d", "vkd3d-proton on Vulkan")]
    static let vulkanChoices: [(String, String)] = [("", L("Automatic")), ("moltenvk", "MoltenVK"), ("kosmickrisp", "KosmicKrisp")]

    static func bundled(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent(path).path)
    }
    /// gl/libvulkan_kosmickrisp.dylib (docs/KOSMICKRISP.md); without it vulkan = kosmickrisp keeps Vulkan off.
    static let hasKosmicKrisp = bundled("gl/libvulkan_kosmickrisp.dylib")
    /// vkd3d-proton's DLLs are git-ignored build products (build/vkd3d-proton/build.sh).
    static let hasVkd3d = bundled("vulkan/arm64ec-windows/d3d12.dll") && bundled("vulkan/arm64ec-windows/d3d12core.dll")
    /// DXVK's DLLs are git-ignored build products too (build/dxvk/build.sh, docs/DXVK.md).
    static let hasDxvk = ["d3d11", "d3d10core", "dxgi"].allSatisfy { bundled("vulkan/arm64ec-windows/dxvk-\($0).dll") }
    /// The Zink OpenGL backend's library; without it the default backend is OpenGL ES, where wined3d finds no context.
    static let hasZink = bundled("gl/libOSMesa.dylib")
    /// KosmicKrisp takes the first Metal 4 device: iOS 26 with an A14 or newer.
    static let metal4: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOS 26.0, *) { return MTLCreateSystemDefaultDevice()?.supportsFamily(.metal4) ?? false }
        return false
        #endif
    }()

    /// The stored value, trimmed and lowercased, "" when unset; d3d9 "emulated" is the default.
    static func current(_ key: String) -> String {
        let v = (MadeiraConfig.get(key) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return key == "d3d9" && v == "emulated" ? "" : v
    }
    static var anySet: Bool { keys.contains { MadeiraConfig.get($0) != nil } }

    @State private var d3d9 = Self.current("d3d9")
    @State private var d3d11 = Self.current("d3d11")
    @State private var d3d12 = Self.current("d3d12")
    @State private var vulkan = Self.current("vulkan")
    @State private var anySet = Self.anySet

    private func reload() {
        d3d9 = Self.current("d3d9"); d3d11 = Self.current("d3d11"); d3d12 = Self.current("d3d12")
        vulkan = Self.current("vulkan")
        anySet = Self.anySet
    }

    private func write(_ key: String, _ value: String?) {
        MadeiraConfig.set(key, value)
        anySet = Self.anySet
        LogStore.shared.log("[graphics-settings] \(key)=\(value ?? "(default)")")
    }

    /// A menu picker over `choices`; a stored value that is not one of them stays selectable as itself.
    private func choicePicker(_ title: String, key: String, value: Binding<String>, choices: [(String, String)],
                              other: (String) -> String = { "Other (\($0))" }) -> some View {
        Picker(title, selection: Binding(get: { value.wrappedValue }, set: { choice in
            value.wrappedValue = choice
            write(key, choice.isEmpty ? nil : choice)
        })) {
            ForEach(choices, id: \.0) { Text($0.1).tag($0.0) }
            if !choices.contains(where: { $0.0 == value.wrappedValue }) { Text(other(value.wrappedValue)).tag(value.wrappedValue) }
        }
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(.caption).foregroundStyle(warning ? Color.orange : Color.secondary)
    }

    private var d3d9Note: String {
        switch d3d9 {
        case "": return L("DXMT draws Direct3D 9 on Metal; 32-bit games run its frontend through the x86 translator.")
        case "native": return L("32-bit games run DXMT's Direct3D 9 frontend as native ARM64 code; 64-bit games are unchanged.")
        case "wined3d": return L("Experimental: 32- and 64-bit games use Wine's own Direct3D 9 on OpenGL, which needs the Zink OpenGL backend.")
        default: return L("A value Madeira does not know; Direct3D 9 games use DXMT.")
        }
    }
    private var d3d11Note: String {
        switch d3d11 {
        case "": return L("DXMT draws Direct3D 10 and 11 on Metal.")
        case "dxvk": return L("Experimental, 64-bit games only: Direct3D 10/11 and DXGI run through DXVK on Vulkan (MoltenVK unless a Vulkan driver is chosen below). Direct3D 12 then uses vkd3d-proton.")
        default: return L("A value Madeira does not know; Direct3D 10/11 games use DXMT.")
        }
    }
    private var d3d12Note: String {
        switch d3d12 {
        case "" where d3d11 == "dxvk": return L("With DXVK chosen above, Direct3D 12 games use vkd3d-proton on Vulkan: DXVK's DXGI shows only Vulkan devices.")
        case "": return L("Direct3D 12 games run on madeira-d3d12, Madeira's own Direct3D 12 on Metal.")
        case "vkd3d": return L("Experimental, 64-bit games only: Direct3D 12 runs through vkd3d-proton on Vulkan (MoltenVK unless a Vulkan driver is chosen below).")
        default: return L("A developer value; Direct3D 12 games run on madeira-d3d12.")
        }
    }
    private var vulkanNote: String {
        switch vulkan {
        case "": return L("Off, so games find no Vulkan, unless DXVK or vkd3d-proton is chosen above, which turns on MoltenVK.")
        case "moltenvk": return L("64-bit games get Vulkan through MoltenVK, the driver the Zink OpenGL backend also uses.")
        case "kosmickrisp": return L("Experimental: 64-bit games get Vulkan through Mesa's KosmicKrisp driver. Needs iOS 26 and an A14 chip or newer.")
        case "off", "0": return L("Off: games find no Vulkan, and DXVK and vkd3d-proton are not used even when chosen above.")
        default: return L("A Vulkan library named by path in madeira.cfg.")
        }
    }

    var body: some View {
        Section {
            choicePicker(L("Direct3D 9"), key: "d3d9", value: $d3d9, choices: Self.d3d9Choices)
            note(d3d9Note)
            if d3d9 == "wined3d" {
                let backend = (MadeiraConfig.get(Self.glBackendKey) ?? "").lowercased()
                if !Self.hasZink || (!backend.isEmpty && backend != "zink") {
                    note(Self.hasZink ? "madeira.cfg sets gl-backend = \(backend); wined3d needs gl-backend = zink."
                                      : L("This build has no Zink OpenGL backend (gl/ folder), so wined3d cannot start."), warning: true)
                }
            }

            choicePicker(L("Direct3D 10/11"), key: "d3d11", value: $d3d11,
                         choices: Self.hasDxvk || d3d11 == "dxvk" ? Self.d3d11Choices : Array(Self.d3d11Choices.prefix(1)))
            note(d3d11Note)
            if !Self.hasDxvk { note(L("DXVK is not in this build."), warning: d3d11 == "dxvk") }
            if d3d11 == "dxvk" && !d3d12.isEmpty && d3d12 != "vkd3d" {
                note("Direct3D 12 is set to \(d3d12); with DXVK only vkd3d-proton can show Direct3D 12 games.", warning: true)
            }

            choicePicker(L("Direct3D 12"), key: "d3d12", value: $d3d12,
                         choices: Self.hasVkd3d || d3d12 == "vkd3d" ? Self.d3d12Choices : Array(Self.d3d12Choices.prefix(1)))
            note(d3d12Note)
            if !Self.hasVkd3d { note(L("vkd3d-proton is not in this build."), warning: d3d12 == "vkd3d") }

            choicePicker(L("Vulkan driver"), key: "vulkan", value: $vulkan,
                         choices: Self.hasKosmicKrisp || vulkan == "kosmickrisp" ? Self.vulkanChoices : Array(Self.vulkanChoices.prefix(2)),
                         other: { $0 == "off" || $0 == "0" ? L("Off") : L("Custom library") })
            note(vulkanNote)
            if !Self.hasKosmicKrisp {
                note(L("KosmicKrisp is not in this build (no gl/libvulkan_kosmickrisp.dylib)."), warning: vulkan == "kosmickrisp")
            } else if !Self.metal4 {
                note(L("This device has no Metal 4 GPU, so KosmicKrisp cannot start on it."), warning: vulkan == "kosmickrisp")
            }

            Button("Reset to defaults") {
                for key in Self.keys.sorted() { MadeiraConfig.set(key, nil) }
                LogStore.shared.log("[graphics-settings] reset: d3d9, d3d11, d3d12 and vulkan removed")
                reload()
            }
            .disabled(!anySet)
        } header: { Text("Graphics") } footer: {
            Text("These write d3d9 / d3d11 / d3d12 / vulkan into madeira.cfg; changes apply at the next session start. Per-game overrides go in the game's custom config lines (Advanced › This game's config).")
        }
        .onChange(of: refresh) { _, _ in reload() }
    }
}

struct LibraryPillGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency { content.background(Color(uiColor: .secondarySystemBackground), in: Capsule()) }
        else if #available(iOS 26, *) { content.glassEffect(.regular.interactive(), in: Capsule()) }
        else { content.background(.regularMaterial, in: Capsule()) }
    }
}

/// The in-game menu's panel: the system material, so the game shows through it
/// blurred (owner, 2026-10-28: the solid panel). The solid panel as before with
/// Reduce Transparency, or MADEIRA_MENU_BLUR=0.
struct SessionMenuBackground: ViewModifier {
    static let blur = MadeiraConfig.flag("MADEIRA_MENU_BLUR")   // 0: the in-game menu's solid panel, as before 2026-10-28
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28)
        if Self.blur && !reduceTransparency { content.background(.regularMaterial, in: shape) }
        else { content.background(Color(uiColor: .secondarySystemBackground), in: shape) }
    }
}

/// The performance overlay's look (OverlayStyle), under its figures in the in-game menu.
struct OverlayStyleSettings: View {
    @AppStorage(OverlayStyle.layoutKey) private var layout = "grid"
    @AppStorage(OverlayStyle.scaleKey) private var scale = 1.0
    @AppStorage(OverlayStyle.backgroundKey) private var background = "glass"
    @AppStorage(OverlayStyle.opacityKey) private var opacity = 1.0
    @AppStorage(OverlayStyle.labelsKey) private var labels = true
    @AppStorage(OverlayStyle.coloursKey) private var colours = false
    @AppStorage(OverlayStyle.refreshKey) private var refresh = 1.0
    @AppStorage(OverlayStyle.graphSecondsKey) private var graphSeconds = 4.0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overlay style").font(.subheadline.weight(.semibold)).padding(.top, 4)
            Picker("Layout", selection: $layout) {
                ForEach(OverlayStyle.layouts, id: \.id) { Text($0.name).tag($0.id) }
            }.pickerStyle(.segmented)
            LabeledContent("Size") { Slider(value: $scale, in: 0.6...1.8, step: 0.05) }
            LabeledContent("Opacity") { Slider(value: $opacity, in: 0.3...1) }
            LabeledContent("Background") {
                Picker("Background", selection: $background) {
                    ForEach(OverlayStyle.backgrounds, id: \.id) { Text($0.name).tag($0.id) }
                }.pickerStyle(.segmented).frame(maxWidth: 220)
            }
            Toggle("Labels", isOn: $labels)
            Toggle("Colour by frame rate", isOn: $colours)
            LabeledContent("Updates") {
                Picker("Updates", selection: $refresh) {
                    Text("0.5 s").tag(0.5); Text("1 s").tag(1.0); Text("2 s").tag(2.0)
                }.pickerStyle(.segmented).frame(maxWidth: 220)
            }
            LabeledContent("Graph span") {
                Picker("Graph span", selection: $graphSeconds) {
                    Text("2 s").tag(2.0); Text("4 s").tag(4.0); Text("8 s").tag(8.0)
                }.pickerStyle(.segmented).frame(maxWidth: 220)
            }
            Text("1% lows: the frame rate of the slowest 1% of frames in the last ten seconds; 1% highs, the fastest. The graph shows each frame's time, newest on the right; a stall is a plateau as long as the stall.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reset overlay style") {
                layout = "grid"; scale = 1; background = "glass"; opacity = 1; labels = true; colours = false; refresh = 1; graphSeconds = 4
            }.font(.subheadline)
        }.font(.subheadline)
    }
}

// Keep drag state in this small view. Global translation remains stable while
// the view moves; local coordinates feed its own movement back in.
struct LibraryFloatingItem: View {
    let isMenu: Bool
    let viewport: CGSize
    let insets: EdgeInsets
    @ObservedObject private var model = LibraryModel.shared
    @AppStorage private var nx: Double
    @AppStorage private var ny: Double
    @GestureState private var drag = CGSize.zero
    @State private var measured = CGSize(width: 48, height: 48)
    @State private var faded = false
    @State private var touched = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isMenu: Bool, viewport: CGSize, insets: EdgeInsets) {
        self.isMenu = isMenu; self.viewport = viewport; self.insets = insets
        _nx = AppStorage(wrappedValue: isMenu ? 0.92 : 0.25, isMenu ? "madeiraLibraryMenuX" : "madeiraLibraryMetricsX")
        _ny = AppStorage(wrappedValue: isMenu ? 0.12 : 0.08, isMenu ? "madeiraLibraryMenuY" : "madeiraLibraryMetricsY")
    }
    private func position(_ translation: CGSize) -> CGPoint {
        let left = insets.leading + measured.width / 2 + 8
        let top = insets.top + measured.height / 2 + 8
        return CGPoint(x: min(max(left, viewport.width * nx + translation.width), max(left, viewport.width - insets.trailing - measured.width / 2 - 8)),
                       y: min(max(top, viewport.height * ny + translation.height), max(top, viewport.height - insets.bottom - measured.height / 2 - 8)))
    }
    private func record(_ rect: CGRect) {
        if isMenu { model.menuButtonRect = rect } else { model.performanceRect = rect }
    }
    var body: some View {
        let center = position(drag)
        let rect = CGRect(x: center.x - measured.width / 2, y: center.y - measured.height / 2, width: measured.width, height: measured.height)
        Group {
            if isMenu {
                Button { touched += 1; model.showMenu() } label: {
                    Image(systemName: "line.3.horizontal").font(.title3.weight(.semibold)).frame(width: 48, height: 48)
                }.buttonStyle(.plain).modifier(LibraryPillGlass())
                    .opacity(faded && drag == .zero && !model.menu ? 0.3 : 1)
                    .accessibilityLabel(L("Game menu")).accessibilityHint(L("Drag to move"))
            } else { LibraryMetrics().accessibilityHint(L("Drag to move")) }
        }
        // The overlay's cells have fixed widths, so it takes its own size. A frame with a
        // maxWidth takes all the width it is offered: the overlay measured the screen's width,
        // and the drag could only centre it (the Column layout showed it most).
        .frame(maxWidth: isMenu ? 48 : nil)
        .fixedSize(horizontal: !isMenu, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { measured = proxy.size }.onChange(of: proxy.size) { _, size in measured = size }
        })
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .global).updating($drag) { value, state, transaction in
            transaction.animation = nil; state = value.translation
        }.onEnded { value in
            let end = position(value.translation)
            withTransaction(Transaction(animation: nil)) {
                nx = end.x / max(1, viewport.width); ny = end.y / max(1, viewport.height); touched += 1
            }
        })
        .position(center)
        .onAppear { record(rect) }.onChange(of: rect) { _, value in record(value) }
        .onDisappear { record(.zero) }
        .task(id: touched) {
            guard isMenu else { return }
            faded = false
            do { try await Task.sleep(for: .seconds(3)); withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) { faded = true } } catch { }
        }
    }
}

/// Everything the library draws over a running session: the starting screen,
/// the menu button, the performance overlay, live logs and the in-game menu.
/// It lives in TouchControlsOverlay's window, which is above the game surface.
struct LibraryHUD: View {
    /// Top offset for the overlays pinned to the top edge. This HUD ignores the
    /// safe area, and with the game view in portrait its reported top inset can
    /// be zero while the status bar is showing; the larger of the reported inset
    /// and the visible status bar's height is used.
    static func topInset(_ geo: GeometryProxy) -> CGFloat {
        let bar = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.statusBarManager?.statusBarFrame.height ?? 0
        return max(geo.safeAreaInsets.top, bar)
    }
    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var controls = TouchControlsModel.shared
    /// The once-per-game "iPadOS refused the pointer lock" notice.
    @ObservedObject private var hw = HardwareInput.shared
    @AppStorage(TouchControlStyle.key) private var controlStyle = "glass"
    /// A Madeira Dock start: its status, failure and Show desktop (DockStartScreen).
    @ObservedObject private var dockStart = DockStartScreen.shared
    private let sessionTools = MadeiraConfig.flag("MADEIRA_SESSION_TOOLS")
    /// The in-game menu's Diagnostics (frame capture, GPU sync), for testing: off
    /// unless madeira.cfg sets env.MADEIRA_SESSION_DIAGNOSTICS = 1. A capture
    /// writes render-target pixels to Documents/capture, which Files shows.
    private let sessionDiagnostics = MadeiraConfig.flag("MADEIRA_SESSION_DIAGNOSTICS", fallback: false)
    /// The developer overlay's ECO and F pills, which a library session does not
    /// show; read again each time the menu opens.
    @State private var eco = madeira_get_eco() != 0
    @State private var fenceMode = FPSOverlayFenceMode.current
    @State private var launchVisible = false
    /// The starting screen came up under the Play button's flood (LaunchCurtain): the
    /// cover's frame it gathers into, and whether it has landed there.
    @State private var curtained = false
    @State private var coverFrame: CGRect = .zero
    @State private var coverLanded = true
    /// The artwork the launch flood carried (cover and backdrop), shown here as well.
    @ObservedObject private var curtain = LaunchCurtain.shared
    /// The Session menu's Controller binds page (keyboard-and-mouse mode).
    @State private var bindsPage = false
    @State private var assistPage = false
    /// The Session menu's Friends page (Madeira Dock sessions).
    @State private var friendsPage = false
    /// The status shown on the Friends page; Offline never reaches here (friends are off for that session).
    @State private var steamStatus = SteamOnlineStatus.current
    @ObservedObject private var dockFriends = DockFriends.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if model.startingScreen, let entry = model.startingEntry {
                    // An opaque base first, so the desktop never shows through while the
                    // backdrop fades in; the backdrop settles from a slight zoom and the
                    // screen's parts arrive one after another (LaunchEntrance).
                    Color.black.ignoresSafeArea().opacity(curtained || launchVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: launchVisible)
                        .opacity(curtain.hidesStartingScreen ? 0 : 1)
                    // The Madeira island behind the starting screen.
                    NewLookBackground(startScreen: true)
                        .scaleEffect(launchVisible || reduceMotion ? 1 : 1.12)
                        .ignoresSafeArea()
                        .opacity(launchVisible ? 1 : 0)
                        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 1.1), value: launchVisible)
                        .opacity(curtain.hidesStartingScreen ? 0 : 1)
                    // Hidden while the flood is still growing over the details page; drawn
                    // (and measured) all the same.
                    newLookLaunch(entry, geometry: geo)
                    .opacity(curtain.hidesStartingScreen ? 0 : 1)
                }
                if !model.startingScreen && model.performance { LibraryFloatingItem(isMenu: false, viewport: geo.size, insets: geo.safeAreaInsets) }
                if model.liveLogs && !model.startingScreen { LibraryLiveLogs().frame(maxWidth: 550, maxHeight: 140).padding(.top, Self.topInset(geo) + 60).padding(.horizontal, 12).allowsHitTesting(false) }
                if !model.sessionMessage.isEmpty && !model.startingScreen { Text(model.sessionMessage).font(.caption).padding(10).background(.regularMaterial, in: Capsule()).frame(maxWidth: .infinity).padding(.top, Self.topInset(geo) + 12).allowsHitTesting(false) }
                // iPadOS refused the pointer lock (HardwareInput.swift, LockRefusedNotice): once per game.
                if hw.lockRefusedHint && !model.startingScreen && !model.menu {
                    // Two lines at most widths: a rounded box, not a capsule. The text's width is
                    // capped before the box is drawn, so the box wraps it.
                    Text(LockRefusedNotice.text).font(.caption).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: min(480, geo.size.width - 60))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: .infinity)
                        .padding(.top, Self.topInset(geo) + (model.sessionMessage.isEmpty ? 12 : 56))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if !model.startingScreen { LibraryFloatingItem(isMenu: true, viewport: geo.size, insets: geo.safeAreaInsets) }
                if model.menu {
                    Color.black.opacity(SessionMenuBackground.blur ? 0.3 : 0.5).ignoresSafeArea().onTapGesture { model.menu = false }.transition(.opacity)
                    (bindsPage ? AnyView(bindsMenu) : assistPage ? AnyView(assistMenu) : friendsPage ? AnyView(friendsMenu) : AnyView(menu))
                        .frame(width: min(460, geo.size.width - 32), height: min(650, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom - 24))
                        .modifier(SessionMenuBackground())
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.15)))
                        .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.menu)
            .onAppear {
                // Under the Play button's flood (LaunchCurtain): once laid out, hand the
                // cover's frame over and let the flood gather into it. Otherwise the
                // parts arrive in turn (LaunchEntrance).
                if model.startingScreen, LaunchCurtain.shared.covering {
                    curtained = true; coverLanded = false
                    // Drawn at once, without its own entrance: the flood is the entrance,
                    // and it runs on Core Animation while this thread starts the session.
                    var now = Transaction(); now.disablesAnimations = true
                    withTransaction(now) { launchVisible = true }
                    let style = launchWideEnabled && geo.size.width > geo.size.height
                        ? LaunchCurtain.CoverStyle(corner: 20, shadowOpacity: 0.55, shadowRadius: 15, shadowOffset: CGSize(width: 0, height: 14))
                        : LaunchCurtain.CoverStyle(corner: 14, shadowOpacity: 0.33, shadowRadius: 10, shadowOffset: .zero)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(160))
                        LaunchCurtain.shared.handOff(to: coverFrame, style: style, landed: { coverLanded = true })
                    }
                } else {
                    withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.35)) { launchVisible = true }
                }
            }
            .preferredColorScheme(.dark)
        }.ignoresSafeArea()
        .onAppear {
            model.saveCurrentProfile()
            if model.startingScreen, !model.menu {
                LibraryController.shared.configure(enabled: model.enabled, ownsInput: true)
            }
        }
        // (get-help-auto) Get Help over the starting screen: by itself a second after "Madeira Dock
        // stopped", or from its Get Help button; closing it goes back to the library.
        .modifier(GetHelpStartScreen())
        // (new-look) The new look's starting screen takes the controller (Stop, Get Help, the live
        // log) until the game shows; then the pad is the game's again.
        .onChange(of: model.startingScreen) { _, starting in
            guard !model.menu else { return }
            LibraryController.shared.configure(enabled: model.enabled, ownsInput: starting)
            LogStore.shared.log("[pad-highlight] starting screen \(starting ? "takes" : "gives back") the controller")
        }
        .onChange(of: model.menu) { _, open in
            LibraryController.shared.configure(enabled: model.enabled, ownsInput: open || model.startingScreen)
            if !open { bindsPage = false; assistPage = false; friendsPage = false }
            if open { dockFriends.refresh() }
            if !open { model.saveCurrentProfile() }
            if open { eco = madeira_get_eco() != 0; fenceMode = FPSOverlayFenceMode.current }
        }
        .onReceive(LibraryController.shared.commands) { command in
            if command == "menu" { if model.menu { model.menu = false } else { model.showMenu() } }
            else if command == "back", model.menu { model.menu = false }
        }
    }
    /// Landscape: the cover large on the left, the title, status and controls beside it.
    /// MADEIRA_LAUNCH_WIDE=0 keeps the centred column in landscape too.
    private let launchWideEnabled = MadeiraConfig.flag("MADEIRA_LAUNCH_WIDE")   // 0: the starting screen is one centred column in landscape too

    /// The starting screen's cover and backdrop: a Dock start shows the game's
    /// Steam artwork by App ID, any other session its library artwork. A Steam game
    /// without its own cover shows Steam's while it gets ready too, and the cover the
    /// launch flood carried when there is one (the same pixels it lands on).
    private func launchSteamID(_ entry: LibraryEntry) -> Int? {
        dockStart.appID ?? (entry.coverFile == nil ? entry.steamAppID : nil)
    }
    @ViewBuilder private func launchCover(_ entry: LibraryEntry) -> some View {
        if let image = curtain.cover(for: launchSteamID(entry)) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let appID = launchSteamID(entry) { SteamGameArtwork(appID: appID) } else { LibraryArtwork(entry: entry) }
    }
    /// What the start is doing before the Dock reports (or for a game without Dock).
    private var launchIdleStatus: String {
        if let entry = model.preparing { return model.startingJIT == entry.id ? L("Enabling JIT…") : L("Getting ready…") }
        return model.launchSlow ? L("Still starting…") : L("Starting your game…")
    }

    /// What the Dock start is doing (DockStartStatus), read once a second.
    private var dockStatus: String {
        MainActor.assumeIsolated {
            let progress = DockInstallers.poll(drive: MadeiraDock.drive)
            // The host starts at once, or after this start's one-time installs finished.
            let hostDue = DockInstallers.finishedAt ?? model.launchStartedAt
            return DockStartStatus.text(MadeiraDock.pollReport().fields, installers: DockInstallers.script != nil,
                                        installerProgress: progress, installsFinished: DockInstallers.finishedAt != nil,
                                        waited: Date().timeIntervalSince(hostDue),
                                        restartHint: DockInstallers.installsOnly
                                            ? (model.installsRestartReady ? DockInstallers.closeWords : DockInstallers.closingWords) : nil)
        }
    }

    /// Gyro aim and turbo, as a page of the Session menu; each change reaches the
    /// pad at once (model.padAssist) and is saved to the game.
    private var assistMenu: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Session", systemImage: "chevron.left") { assistPage = false }.buttonStyle(.borderless)
                Spacer()
                Text("Gyro aim & turbo").font(.headline)
                Spacer()
                Button("Reset") { model.padAssist = nil; model.saveCurrentProfile() }
                    .buttonStyle(.borderless).disabled(model.padAssist == nil)
                Button("Done") { model.menu = false }.buttonStyle(.bordered)
            }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 8)
            Form {
                PadAssistPage(settings: Binding(get: { model.padAssist }, set: { model.padAssist = $0; model.saveCurrentProfile() }))
            }.scrollContentBackground(.hidden)
        }
    }

    /// Controller binds, as a page of the Session menu: a Form, so the rows read
    /// like Game details; the driver takes each change at once (model.controllerBinds).
    private var bindsMenu: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Session", systemImage: "chevron.left") { bindsPage = false }.buttonStyle(.borderless)
                Spacer()
                Text("Controller binds").font(.headline)
                Spacer()
                Button("Reset") { model.controllerBinds = [:]; model.padMouseVertical = 1; model.saveCurrentProfile() }
                    .buttonStyle(.borderless).disabled(model.controllerBinds.isEmpty && model.padMouseVertical == 1)
                Button("Done") { model.menu = false }.buttonStyle(.bordered)
            }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 8)
            Form {
                ControllerBindsPage(binds: Binding(get: { model.controllerBinds.isEmpty ? nil : model.controllerBinds },
                                                   set: { model.controllerBinds = $0 ?? [:]; model.saveCurrentProfile() }),
                                    mouseVertical: Binding(get: { model.padMouseVertical == 1 ? nil : model.padMouseVertical },
                                                           set: { model.padMouseVertical = $0 ?? 1; model.saveCurrentProfile() }),
                                    controls: controls.controls)
            }.scrollContentBackground(.hidden)
        }
    }

    /// Friends from the running Madeira Dock session: Join a friend's lobby in
    /// this game, or Invite a friend (to this player's lobby when in one).
    private var friendsMenu: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Session", systemImage: "chevron.left") { friendsPage = false }.buttonStyle(.borderless)
                Spacer()
                Text("Friends").font(.headline)
                Spacer()
                Button("Done") { model.menu = false }.buttonStyle(.bordered)
            }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 8)
            Picker("Status", selection: Binding(get: { steamStatus }, set: { steamStatus = $0; dockFriends.setStatus($0) })) {
                ForEach(SteamOnlineStatus.allCases.filter { $0 != .offline }) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal, 22).padding(.bottom, 8)
            .disabled(dockFriends.pending != nil || !dockFriends.available)
            if dockFriends.friends.isEmpty {
                Spacer()
                Group {
                    if dockFriends.available { Text("No friends yet") } else { Text("Friends are available while the game runs") }
                }
                .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(dockFriends.friends, id: \.steamID) { friend in
                    DockFriendRow(friend: friend, model: dockFriends)
                }.scrollContentBackground(.hidden)
            }
        }
        .task {
            while !Task.isCancelled {
                dockFriends.refresh()
                try? await Task.sleep(for: .seconds(dockFriends.pending == nil ? 3 : 0.5))
            }
        }
    }

    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Label("Session", systemImage: "gamecontroller.fill").font(.title2.bold()); Spacer(); Button("Done") { model.menu = false }.buttonStyle(.bordered) }
                // The controls come first, the easiest to reach; the overlay settings last.
                Toggle("Touch controls", isOn: $controls.visible)
                // The named layouts (Xbox controller, custom ones) live here in a session: this
                // menu replaces the overlay's top bar, where the same menu sits outside the library.
                if controls.visible && ControlPresetsModel.enabled {
                    ControlLayoutMenu(style: .row) { openedEditor in
                        model.saveCurrentProfile()
                        if openedEditor { model.menu = false }
                    }
                }
                LabeledContent("Opacity") { Slider(value: $model.opacity, in: 0.15...1) }
                LabeledContent("Size") { Slider(value: $controls.sizeScale, in: 0.5...2) }
                // Glass or an opaque disc (TouchControlStyle); the same choice as Settings › Appearance.
                LabeledContent("Button style") {
                    Picker("Button style", selection: $controlStyle) {
                        ForEach(TouchControlStyle.styles, id: \.id) { Text($0.name).tag($0.id) }
                    }.pickerStyle(.segmented).frame(maxWidth: 220)
                }
                Button("Edit controls", systemImage: "slider.horizontal.3") { controls.visible = true; controls.editing = true; model.menu = false }
                if GamepadInput.keyboardMouseAvailable {
                    ControllerModeChoice(mode: Binding(get: { model.controllerMode }, set: { model.controllerMode = $0; model.saveCurrentProfile() }))
                    if model.controllerMode == "keys" {
                        Button("Controller binds", systemImage: "gamecontroller") { bindsPage = true }
                    } else if model.controllerMode == "dinput" {
                        // ml1240: the DirectInput device exists only from the launch on.
                        Text("XInput and DirectInput applies to the next launch.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if GamepadInput.enabled {
                    Button("Gyro aim & turbo", systemImage: "gyroscope") { assistPage = true }
                }
                Button("Keyboard", systemImage: "keyboard") { model.menu = false; LibraryKeyboard.show() }
                if dockFriends.available {
                    Button("Friends", systemImage: "person.2") { steamStatus = SteamOnlineStatus.current; friendsPage = true }
                }
                Divider()
                FPSChoice(mode: Binding(get: { model.fpsMode }, set: { model.setFPS($0) }))
                // Saved to the game with the rest of the session's profile.
                // MADEIRA_SESSION_TOOLS=0 hides it.
                if sessionTools {
                    LabeledContent("Aspect & scaling") {
                        Picker("Aspect & scaling", selection: $model.displayMode) {
                            ForEach(DisplayMode.allCases, id: \.self) { mode in Label(mode.label, systemImage: mode.symbol).tag(mode) }
                        }.pickerStyle(.menu).labelsHidden()
                    }
                }
                Divider()
                // ml1133's ECO switch, live: the same as the developer overlay's ECO pill.
                Text("CPU").font(.headline)
                Toggle("Eco mode", isOn: Binding(get: { eco }, set: { on in eco = on; madeira_set_eco(on ? 1 : 0) }))
                Text("Runs the game's threads at a low priority, on the efficiency cores: cooler and slower. Use it while a game loads and turn it off to play.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Mouse & pointer").font(.headline)
                LibraryPointerSettings()
                Divider()
                Toggle("Performance overlay", isOn: $model.performance)
                if model.performance {
                    ForEach(OverlayStyle.fields, id: \.self) { field in
                        Toggle(field, isOn: Binding(get: { model.overlayFields.contains(field) }, set: { on in
                            model.overlayFields.removeAll { $0 == field }; if on { model.overlayFields.append(field) }
                        })).font(.subheadline)
                    }
                    OverlayStyleSettings()
                }
                // The developer overlay's CAP and F pills (FPSOverlay), for library
                // sessions: only with MADEIRA_SESSION_DIAGNOSTICS=1 (and not with
                // MADEIRA_SESSION_TOOLS=0).
                if sessionTools && sessionDiagnostics {
                    Divider()
                    Text("Diagnostics").font(.headline)
                    Button("Capture the next frame", systemImage: "camera.viewfinder") {
                        model.menu = false
                        // After the menu has gone, so the frame shows what the player saw.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            madeira_capture_request(1)
                            LogStore.shared.log("[capture] frame capture requested from the in-game menu")
                        }
                    }
                    LabeledContent("GPU sync") {
                        Picker("GPU sync", selection: Binding(get: { fenceMode }, set: { mode in
                            fenceMode = mode; FPSOverlayFenceMode.current = mode
                            madeira_set_fence_mode(Int32(mode == 0 ? 7 : mode))
                        })) {
                            Text("F1").tag(1); Text("F6").tag(6); Text("F5").tag(5); Text("F0").tag(0)
                        }.pickerStyle(.segmented).frame(maxWidth: 220)
                    }
                    Text("Both apply to Direct3D 12 games only. Capture writes the render passes of the next frame to Documents/capture and its draw list to the log. GPU sync: F1 makes every pass wait for the one before (the default), F6 waits only where the game's barriers ask, F5 makes render passes wait at the fragment stage, F0 has no sync at all (expect flicker; for tests).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let appID = model.activeEntry?.steamAppID, SteamOwnedLibrary.cloudQuitEnabled {
                    Divider()
                    SteamCloudQuitRow(appID: appID)
                }
                Divider()
                // Red label and symbol; the menu's .primary style would otherwise win.
                Button(role: .destructive) { model.quitToLibrary() } label: {
                    Label("Quit game", systemImage: "stop.circle").foregroundStyle(.red)
                }.tint(.red)
                Text("Closes the running session. Unsaved progress will be lost.").font(.caption).foregroundStyle(.secondary)
                if model.dockGameEnded {
                    Button {
                        LogStore.shared.log("[frontend] closing Madeira after the Dock game ended")
                        exit(0)
                    } label: {
                        Label("Close Madeira", systemImage: "checkmark.circle")
                    }
                    Text("The game and Steam have closed, and Steam has saved. Madeira runs one game each time it is opened: open it again to play.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.forceCloseOffered {
                    Button(role: .destructive) {
                        LogStore.shared.log("[frontend] force close: the program ignored the close request; closing Madeira", level: .error)
                        exit(0)
                    } label: {
                        Label("Force close Madeira", systemImage: "xmark.octagon").foregroundStyle(.red)
                    }.tint(.red)
                    Text("The game did not respond to Quit game. This closes Madeira at once: unsaved progress, and settings the game changed in this session, are lost.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                .foregroundStyle(.primary)
        }
        .scrollIndicators(.visible)
    }
}

struct LibraryLiveLogs: View {
    @ObservedObject private var logs = LogStore.shared
    var body: some View {
        // Rows are coalesced by signature; insertion order isn't recency.
        // Show the latest updates so a repeating wait still looks live.
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(logs.entries.sorted { $0.lastTimestamp < $1.lastTimestamp }.suffix(200))) {
                        Text($0.lastRaw).font(.system(size: 9, design: .monospaced)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: max(0, geo.size.height - 16), alignment: .topLeading)
            }.defaultScrollAnchor(.bottom).padding(8)
        }.background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
            .accessibilityLabel(L("Live diagnostic log"))
    }
}

/// The performance overlay's look, the same in every game (owner, 2026-10-28): its
/// layout, size, background, opacity, labels, colours and how often the figures
/// change. Which figures it shows stays per game (LibraryEntry.overlayFields).
enum OverlayStyle {
    static let layoutKey = "madeiraOverlayLayout", scaleKey = "madeiraOverlayScale"
    static let backgroundKey = "madeiraOverlayBackground", opacityKey = "madeiraOverlayOpacity"
    static let labelsKey = "madeiraOverlayLabels", coloursKey = "madeiraOverlayColours"
    static let refreshKey = "madeiraOverlayRefresh", graphSecondsKey = "madeiraOverlayGraphSeconds"
    /// "grid": up to five cells a row (as first made); "row": one long row; "column": one figure a line.
    static let layouts: [(id: String, name: String)] = [("grid", "Grid"), ("row", "One row"), ("column", "Column")]
    static let backgrounds: [(id: String, name: String)] = [("glass", "Glass"), ("dark", "Dark"), ("clear", "None")]
    /// The figures the overlay can show, in the order of the menu's switches.
    static let fields = ["FPS", "Frame time", "1% lows", "0.1% lows", "Frame graph", "CPU", "GPU", "RAM", "JIT memory", "Swap & donor", "Battery", "Thermal"]
}

/// Frame times from the present path (madeira_frame_times_us, Winios.m) and the
/// figures made from them: the 1% low is the frame rate of the slowest 1% of
/// frames (their mean frame time), the 1% high that of the fastest 1%.
enum FrameTimes {
    static func read(windowMs: UInt32, max: Int = 2048) -> (intervals: [Double], sinceLast: Double) {
        var buffer = [UInt32](repeating: 0, count: max)
        var since: UInt32 = 0
        let n = Int(madeira_frame_times_us(&buffer, Int32(max), windowMs, &since))
        return (buffer.prefix(n).map { Double($0) / 1000 }, Double(since) / 1000)
    }
    /// (1% low, 1% high) in frames a second, nil without enough frames.
    static func onePercent(_ ms: [Double]) -> (low: Double, high: Double)? {
        guard ms.count >= 10 else { return nil }
        let sorted = ms.sorted(), k = max(1, sorted.count / 100)
        let slow = sorted.suffix(k).reduce(0, +) / Double(k), fast = sorted.prefix(k).reduce(0, +) / Double(k)
        guard slow > 0, fast > 0 else { return nil }
        return (1000 / slow, 1000 / fast)
    }
    /// The 0.1% low in frames a second: the slowest 0.1% of frames (at least the
    /// slowest one), nil without enough frames.
    static func pointOnePercentLow(_ ms: [Double]) -> Double? {
        guard ms.count >= 10 else { return nil }
        let k = max(1, ms.count / 1000), slow = ms.sorted().suffix(k).reduce(0, +) / Double(k)
        return slow > 0 ? 1000 / slow : nil
    }
    /// The frame time to show: the mean of the frames presented in the last
    /// `windowMs`, or the time since the last present when that is longer (a stall
    /// still going on). nil when nothing has presented.
    static func current(windowMs: UInt32) -> Double? {
        let (ms, since) = read(windowMs: windowMs, max: 512)
        let mean = ms.isEmpty ? 0 : ms.reduce(0, +) / Double(ms.count)
        let value = max(mean, since > mean ? since : 0)
        return value > 0 ? value : nil
    }
}

/// The frame-time graph: each frame a step as wide as it lasted and as high as its
/// time, newest on the right, so a stall is a plateau as long as the stall; the
/// frame still being made grows at the right edge. Drawn ten times a second.
struct FrameTimeGraph: View {
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat
    let seconds: Double
    let colours: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let (ms, since) = FrameTimes.read(windowMs: UInt32(seconds * 1000), max: 1024)
            let sorted = ms.sorted()
            let median = sorted.isEmpty ? 16.7 : sorted[sorted.count / 2]
            let p99 = sorted.isEmpty ? 16.7 : sorted[min(sorted.count - 1, sorted.count * 99 / 100)]
            // The frame still being made, once it is clearly late.
            let pending = since > max(50, median * 2) ? since : 0
            let top = [33.3, 50, 66.7, 100, 200, 500, 1000, 2000, 5000].first(where: { $0 >= max(p99, pending) * 1.15 }) ?? 5000
            ZStack(alignment: .topTrailing) {
                Canvas { context, size in
                    let w = size.width, h = size.height
                    func y(_ v: Double) -> CGFloat { h - CGFloat(min(v, top) / top) * (h - 1) }
                    for guide in [16.7, 33.3] where guide < top {
                        var line = Path(); line.move(to: CGPoint(x: 0, y: y(guide))); line.addLine(to: CGPoint(x: w, y: y(guide)))
                        context.stroke(line, with: .color(.primary.opacity(0.18)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    }
                    // Right edge = now; walk back from the newest frame.
                    var steps: [(x0: CGFloat, x1: CGFloat, v: Double)] = []
                    var end = since
                    if pending > 0 { steps.append((w - CGFloat(pending / 1000 / seconds) * w, w, pending)) }
                    for v in ms.reversed() {
                        let x1 = w - CGFloat(end / 1000 / seconds) * w, x0 = w - CGFloat((end + v) / 1000 / seconds) * w
                        if x1 < 0 { break }
                        steps.append((max(0, x0), x1, v)); end += v
                    }
                    guard !steps.isEmpty else { return }
                    var outline = Path(), fill = Path()
                    let ordered = steps.reversed()
                    fill.move(to: CGPoint(x: ordered.first!.x0, y: h))
                    for (i, s) in ordered.enumerated() {
                        if i == 0 { outline.move(to: CGPoint(x: s.x0, y: y(s.v))) } else { outline.addLine(to: CGPoint(x: s.x0, y: y(s.v))) }
                        outline.addLine(to: CGPoint(x: s.x1, y: y(s.v)))
                        fill.addLine(to: CGPoint(x: s.x0, y: y(s.v))); fill.addLine(to: CGPoint(x: s.x1, y: y(s.v)))
                    }
                    fill.addLine(to: CGPoint(x: ordered.last!.x1, y: h)); fill.closeSubpath()
                    context.fill(fill, with: .color(.primary.opacity(0.12)))
                    context.stroke(outline, with: .color(.primary.opacity(0.85)), lineWidth: max(1, scale))
                    // Spikes: frames over twice the median, marked in orange (red over 100 ms) with colours on.
                    if colours {
                        for s in steps where s.v > max(median * 2, 25) {
                            var spike = Path(); spike.move(to: CGPoint(x: s.x0, y: y(s.v))); spike.addLine(to: CGPoint(x: s.x1, y: y(s.v)))
                            spike.move(to: CGPoint(x: s.x0, y: y(s.v))); spike.addLine(to: CGPoint(x: s.x0, y: h))
                            context.stroke(spike, with: .color(s.v > 100 ? .red : .orange), lineWidth: max(1.5, scale * 1.5))
                        }
                    }
                }
                Text(top >= 1000 ? String(format: "%.0f s", top / 1000) : String(format: "%.0f ms", top))
                    .font(.system(size: 8 * scale, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary).padding(.trailing, 2)
            }
            .frame(width: width, height: height)
        }
        .accessibilityHidden(true)
    }
}

struct LibraryMetrics: View {
    @ObservedObject private var model = LibraryModel.shared
    @AppStorage(OverlayStyle.layoutKey) private var layout = "grid"
    @AppStorage(OverlayStyle.scaleKey) private var scale = 1.0
    @AppStorage(OverlayStyle.backgroundKey) private var background = "glass"
    @AppStorage(OverlayStyle.opacityKey) private var opacity = 1.0
    @AppStorage(OverlayStyle.labelsKey) private var labels = true
    @AppStorage(OverlayStyle.coloursKey) private var colours = false
    @AppStorage(OverlayStyle.refreshKey) private var refresh = 1.0
    @AppStorage(OverlayStyle.graphSecondsKey) private var graphSeconds = 4.0
    @State private var lastCount: UInt64 = 0
    @State private var lastTime = Date()
    @State private var tick = 0
    @State private var fps = 0.0
    @State private var onePercent: (low: Double, high: Double)?
    @State private var pointOneLow: Double?
    /// Measured from the present path, like the graph (1000 / FPS hid the slow frames).
    @State private var frameMs: Double?
    @State private var memory = 0
    @State private var battery = -1
    /// iOS lowers clocks from .serious on, so a frame rate that sags after a few
    /// minutes can be told apart from one the game or the runtime caused.
    @State private var thermal = ProcessInfo.processInfo.thermalState
    @State private var cpuMeter = CPUMeter()
    @State private var cpu: (total: Double, top: Double)?
    @State private var lastGPUBusy = 0.0
    @State private var lastGPUBuffers: UInt64 = 0
    @State private var gpu = -1.0
    @State private var gpuFrameMs = 0.0
    /// ml2021: the swap tier's figures (madeira_swap_overlay_stats): MB backed by the
    /// swap file, MB served from the donor pool, the pool's registered size, and the
    /// takes its free-RAM guard refused.
    @State private var swapFileMB = 0
    @State private var donatedMB = 0
    @State private var donorPoolMB = 0
    @State private var donorGuarded = 0
    /// Half-second ticks; the figures change every `refresh` seconds (0.5, 1 or 2).
    private let ticks = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    /// ml2021: one cell per figure. A fixed width per cell (the widest value it can show)
    /// keeps the pill from shifting as digits change; monospaced digits keep the value
    /// still within the cell. Label above, value below, hairlines between cells, the
    /// system material behind: no gradients, no custom colours beyond the thermal dot
    /// (and, with Colours on, the frame-rate figures).
    struct Cell: Identifiable {
        let id: String
        let label: String
        let value: String
        let width: CGFloat
        var dot: Color? = nil
        var tint: Color? = nil
    }
    private var s: CGFloat { CGFloat(min(max(scale, 0.5), 2)) }
    private func speed(_ rate: Double) -> Color? {
        guard colours, rate > 0 else { return nil }
        return rate >= 45 ? .green : rate >= 25 ? .yellow : .red
    }
    private var cells: [Cell] {
        var result: [Cell] = []
        if model.overlayFields.contains("FPS") {
            result.append(Cell(id: "fps", label: "FPS", value: String(format: "%.0f", fps), width: 44, tint: speed(fps)))
        }
        if model.overlayFields.contains("Frame time") {
            result.append(Cell(id: "ms", label: "MS", value: frameMs.map { String(format: $0 >= 100 ? "%.0f" : "%.1f", $0) } ?? "–", width: 52))
        }
        if model.overlayFields.contains("1% lows") {
            result.append(Cell(id: "low", label: "1% LOW", value: onePercent.map { String(format: "%.0f", $0.low) } ?? "–", width: 52,
                               tint: onePercent.flatMap { speed($0.low) }))
            result.append(Cell(id: "high", label: "1% HIGH", value: onePercent.map { String(format: "%.0f", $0.high) } ?? "–", width: 54))
        }
        if model.overlayFields.contains("0.1% lows") {
            result.append(Cell(id: "low01", label: "0.1% LOW", value: pointOneLow.map { String(format: "%.0f", $0) } ?? "–", width: 60,
                               tint: pointOneLow.flatMap { speed($0) }))
        }
        if model.overlayFields.contains("CPU") {
            result.append(Cell(id: "cpu", label: "CPU", value: cpu.map { String(format: "%.0f%%", $0.total) } ?? "–", width: 50))
            result.append(Cell(id: "top", label: "TOP", value: cpu.map { String(format: "%.0f%%", $0.top) } ?? "–", width: 50))
        }
        if model.overlayFields.contains("GPU") {
            result.append(Cell(id: "gpu", label: "GPU", value: gpu < 0 ? "–" : String(format: "%.0f%%", gpu), width: 50))
            result.append(Cell(id: "gpums", label: "GPU MS", value: gpu < 0 || gpuFrameMs <= 0 ? "–" : String(format: "%.1f", gpuFrameMs), width: 56))
        }
        if model.overlayFields.contains("RAM") { result.append(Cell(id: "ram", label: "MB", value: "\(memory)", width: 54)) }
        if model.overlayFields.contains("Swap & donor") {
            if donorPoolMB > 0 { result.append(Cell(id: "donor", label: "DONOR", value: "\(donatedMB)", width: 54)) }
            result.append(Cell(id: "swap", label: "SWAP", value: "\(swapFileMB)", width: 54))
        }
        if model.overlayFields.contains("Battery"), battery >= 0 { result.append(Cell(id: "bat", label: "BAT", value: "\(battery)%", width: 50)) }
        if model.overlayFields.contains("Thermal") {
            let (word, dot): (String, Color) = {
                switch thermal {
                case .nominal: return ("Cool", .green)
                case .fair: return ("Warm", .yellow)
                case .serious: return ("Hot", .orange)
                case .critical: return ("Critical", .red)
                @unknown default: return ("–", .gray)
                }
            }()
            result.append(Cell(id: "temp", label: "TEMP", value: word, width: 62, dot: dot))
        }
        return result
    }
    private func value(_ c: Cell) -> some View {
        HStack(spacing: 4 * s) {
            if let dot = c.dot { Circle().fill(dot).frame(width: 6 * s, height: 6 * s) }
            Text(c.value).font(.system(size: 13 * s, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(c.tint ?? .primary)
        }
    }
    private func label(_ c: Cell) -> some View {
        Text(c.label).font(.system(size: 9 * s, weight: .medium, design: .rounded)).tracking(0.6 * s).foregroundStyle(.secondary)
    }
    private func cell(_ c: Cell) -> some View {
        VStack(spacing: 1 * s) {
            if labels { label(c) }
            value(c)
        }
        .frame(width: c.width * s)
    }
    private func row(_ cells: [Cell]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, c in
                if index > 0 { Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: (labels ? 20 : 14) * s) }
                cell(c)
            }
        }
    }
    /// The width a row of these cells takes (cells and hairlines).
    private func width(_ cells: [Cell]) -> CGFloat {
        cells.reduce(0) { $0 + $1.width * s } + CGFloat(max(0, cells.count - 1))
    }
    private func graph(width: CGFloat, height: CGFloat) -> some View {
        FrameTimeGraph(width: width, height: height, scale: s, seconds: min(max(graphSeconds, 1), 10), colours: colours)
    }
    @ViewBuilder private var content: some View {
        let all = cells
        let showGraph = model.overlayFields.contains("Frame graph")
        switch layout {
        case "row":
            HStack(spacing: 0) {
                row(all)
                if showGraph {
                    if !all.isEmpty { Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: (labels ? 20 : 14) * s).padding(.trailing, 4 * s) }
                    graph(width: 120 * s, height: (labels ? 26 : 18) * s)
                }
            }
        case "column":
            VStack(alignment: .leading, spacing: 3 * s) {
                ForEach(all) { c in
                    HStack(spacing: 8 * s) {
                        if labels { label(c) }
                        Spacer(minLength: 0)
                        value(c)
                    }
                    .frame(width: 112 * s)
                }
                if showGraph { graph(width: 112 * s, height: 34 * s) }
            }
            .padding(.horizontal, 2 * s)
        default:
            // Up to five cells on a row; more wrap onto a second row so the pill stays under the
            // viewport's width instead of truncating.
            let split = all.count > 5 ? (all.count + 1) / 2 : all.count
            let first = Array(all.prefix(split)), second = Array(all.suffix(from: split))
            VStack(spacing: 6 * s) {
                if !first.isEmpty { row(first) }
                if !second.isEmpty { row(second) }
                if showGraph { graph(width: max(width(first), width(second), 150 * s), height: 34 * s) }
            }
        }
    }
    @ViewBuilder private func backdrop<V: View>(_ v: V) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12 * s, style: .continuous)
        switch background {
        case "dark":
            v.background(Color.black.opacity(0.55), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .environment(\.colorScheme, .dark)
        case "clear":
            v.shadow(color: .black.opacity(0.9), radius: 1.5).environment(\.colorScheme, .dark)
        default:
            v.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
    }
    var body: some View {
        backdrop(content.padding(.horizontal, 6 * s).padding(.vertical, 6 * s))
        .opacity(min(max(opacity, 0.2), 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.joined(separator: ", "))
            .onAppear {
                lastCount = madeira_shown_frame_count(); lastTime = Date(); UIDevice.current.isBatteryMonitoringEnabled = true
                applyGPUMeter()
            }
            .onDisappear { UIDevice.current.isBatteryMonitoringEnabled = false; madeira_gpu_meter_enable(0) }
            .onChange(of: model.overlayFields) { _, _ in applyGPUMeter() }
            .onReceive(ticks) { now in
                tick += 1
                guard tick % max(1, Int((refresh / 0.5).rounded())) == 0 else { return }
                let count = madeira_shown_frame_count(); let dt = now.timeIntervalSince(lastTime)
                let frames = count >= lastCount ? count - lastCount : 0
                fps = Double(frames) / max(0.001, dt); lastCount = count; lastTime = now
                // Over the last ten seconds, so a stall stays in the figure for a while.
                if model.overlayFields.contains("1% lows") { onePercent = FrameTimes.onePercent(FrameTimes.read(windowMs: 10_000).intervals) }
                // 0.1% needs more frames: thirty seconds (the ring holds 2048).
                if model.overlayFields.contains("0.1% lows") { pointOneLow = FrameTimes.pointOnePercentLow(FrameTimes.read(windowMs: 30_000).intervals) }
                if model.overlayFields.contains("Frame time") { frameMs = FrameTimes.current(windowMs: UInt32(max(0.5, refresh) * 1000)) }
                var info = task_vm_info_data_t(); var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
                let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) } }
                if result == KERN_SUCCESS { memory = Int(info.phys_footprint / 1048576) }
                battery = UIDevice.current.batteryLevel < 0 ? -1 : Int(UIDevice.current.batteryLevel * 100)
                let state = ProcessInfo.processInfo.thermalState
                if state != thermal {
                    LogStore.shared.log("[thermal] \(DeviceLoadDiagnostics.thermalName(thermal)) -> \(DeviceLoadDiagnostics.thermalName(state)) at \(String(format: "%.0f", fps)) FPS")
                    thermal = state
                }
                if model.overlayFields.contains("CPU") { cpu = cpuMeter.sample() }
                if model.overlayFields.contains("Swap & donor") {
                    var file: UInt64 = 0, donated: UInt64 = 0, pool: UInt64 = 0, guarded: UInt64 = 0
                    madeira_swap_overlay_stats(&file, &donated, &pool, &guarded)
                    swapFileMB = Int(file); donatedMB = Int(donated); donorPoolMB = Int(pool); donorGuarded = Int(guarded)
                }
                if model.overlayFields.contains("GPU") {
                    let busy = madeira_gpu_meter_busy_seconds(), buffers = madeira_gpu_meter_cmdbufs()
                    let used = max(0, busy - lastGPUBusy)
                    gpu = buffers > lastGPUBuffers ? min(100, used / max(0.001, dt) * 100) : -1
                    gpuFrameMs = frames > 0 ? used * 1000 / Double(frames) : 0
                    lastGPUBusy = busy; lastGPUBuffers = buffers
                }
            }
    }
    /// ml1174: command buffers get a GPU-time handler only while GPU is shown.
    private func applyGPUMeter() {
        madeira_gpu_meter_enable(model.overlayFields.contains("GPU") ? 1 : 0)
        lastGPUBusy = madeira_gpu_meter_busy_seconds(); lastGPUBuffers = madeira_gpu_meter_cmdbufs(); gpu = -1
    }
    private var parts: [String] {
        var result: [String] = []
        if model.overlayFields.contains("FPS") { result.append(String(format: "%.0f FPS", fps)) }
        if model.overlayFields.contains("Frame time") { result.append(frameMs.map { String(format: "%.1f ms", $0) } ?? "— ms") }
        if model.overlayFields.contains("1% lows") {
            result.append(onePercent.map { String(format: "1%% low %.0f, 1%% high %.0f FPS", $0.low, $0.high) } ?? "1% lows —")
        }
        if model.overlayFields.contains("0.1% lows") { result.append(pointOneLow.map { String(format: "0.1%% low %.0f FPS", $0) } ?? "0.1% low —") }
        if model.overlayFields.contains("CPU") {
            result.append(cpu.map { String(format: "CPU %.0f%% (top %.0f%%)", $0.total, $0.top) } ?? "CPU —")
        }
        if model.overlayFields.contains("GPU") {
            if gpu < 0 { result.append("GPU —") }
            else if gpuFrameMs > 0 { result.append(String(format: "GPU %.0f%% (%.1f ms)", gpu, gpuFrameMs)) }
            else { result.append(String(format: "GPU %.0f%%", gpu)) }
        }
        if model.overlayFields.contains("RAM") { result.append("\(memory) MB") }
        // The memory games' code runs from; "FULL" once a DLL did not fit (JITPoolMeter).
        if model.overlayFields.contains("JIT memory") { result.append(JITPoolMeter.text(JITPoolMeter.current) ?? "JIT —") }
        if model.overlayFields.contains("Swap & donor") {
            // RAM above is the app's own footprint; donated memory is billed to the
            // extension's ledger, so it is shown beside it rather than added to it.
            if donorPoolMB > 0 {
                result.append(donorGuarded > 0 ? "Donated \(donatedMB)/\(donorPoolMB) MB (\(donorGuarded) guarded)"
                                               : "Donated \(donatedMB)/\(donorPoolMB) MB")
            }
            result.append("Swap \(swapFileMB) MB")
        }
        if model.overlayFields.contains("Battery"), battery >= 0 { result.append("\(battery)%") }
        if model.overlayFields.contains("Thermal") {
            switch thermal {
            case .nominal: result.append("Cool")
            case .fair: result.append("Warm")
            case .serious: result.append("Hot")
            case .critical: result.append("Critical")
            @unknown default: break
            }
        }
        return result
    }
}

/// ml1174: CPU load for the performance overlay, from the process's thread
/// times. `total` is the CPU time since the previous sample as a share of all
/// cores; `top` is the busiest thread's share of one core, which shows a game
/// held back by one thread while the total stays low.
final class CPUMeter {
    private var last: [UInt64: Double] = [:]
    private var lastWall = 0.0
    private let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// nil on the first call, and when the threads cannot be read.
    func sample() -> (total: Double, top: Double)? {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        let wall = CACurrentMediaTime()
        var now: [UInt64: Double] = [:]
        var sum = 0.0, top = 0.0
        for i in 0..<Int(count) {
            let thread = list[i]
            defer { mach_port_deallocate(mach_task_self_, thread) }
            var ident = thread_identifier_info_data_t()
            var identCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
            var basic = thread_basic_info_data_t()
            var basicCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
            let identResult = withUnsafeMutablePointer(to: &ident) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(identCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identCount)
                }
            }
            let basicResult = withUnsafeMutablePointer(to: &basic) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &basicCount)
                }
            }
            guard identResult == KERN_SUCCESS, basicResult == KERN_SUCCESS else { continue }
            let seconds = Double(basic.user_time.seconds + basic.system_time.seconds)
                + Double(basic.user_time.microseconds + basic.system_time.microseconds) / 1e6
            now[ident.thread_id] = seconds
            if let before = last[ident.thread_id] {
                let used = max(0, seconds - before)
                sum += used; top = max(top, used)
            }
        }
        let interval = wall - lastWall
        let first = last.isEmpty
        last = now; lastWall = wall
        guard !first, interval > 0 else { return nil }
        return (min(100, sum / interval / cores * 100), min(100, top / interval * 100))
    }
}

// A key window is required for UIKit text input; the rendering placeholder lives
// beneath separate presentation and control windows and cannot reliably own it.
enum LibraryKeyboard {
    static var window: UIWindow?
    static weak var previous: UIWindow?
    static var input: LibraryKeyInput?
    static func show() {
        // MADEIRA_FRONTEND_KEYBOARD=0: the game view's own keyboard instead.
        if !MadeiraConfig.flag("MADEIRA_FRONTEND_KEYBOARD") { MetalBackedView.toggleKeyboard(); return }
        guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        previous = scene.windows.first(where: { $0.isKeyWindow })
        let w = LibraryKeyboardWindow(windowScene: scene)
        w.windowLevel = .normal + 102; w.backgroundColor = .clear
        let controller = UIViewController(); controller.view.backgroundColor = .clear
        w.rootViewController = controller
        let v = LibraryKeyInput(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        controller.view.addSubview(v); input = v; window = w
        w.makeKeyAndVisible(); v.becomeFirstResponder()
        fputs("[frontend-keyboard] key-window input activated\n", stderr)
    }
    static func hide() {
        HardwareInput.shared.cancelPaste()
        if window != nil { fputs("[frontend-keyboard] key-window input deactivated\n", stderr) }
        input?.releaseModifiers(); input?.resignFirstResponder(); window?.isHidden = true
        window = nil; input = nil; previous?.makeKey(); previous = nil
    }
}
final class LibraryKeyboardWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
final class LibraryKeyInput: UIView, UIKeyInput {
    override var keyCommands: [UIKeyCommand]? {
        let command = UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:)))
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return HardwareInput.shared.canPaste && UIPasteboard.general.hasStrings }
        return super.canPerformAction(action, withSender: sender)
    }
    override func paste(_ sender: Any?) {
        HardwareInput.shared.pasteClipboard()
    }

    var hasText: Bool { true }
    override var canBecomeFirstResponder: Bool { true }
    private var held = Set<Int32>()
    private weak var accessoryRow: UIStackView?
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    private lazy var accessoryBar = makeAccessoryBar()
    override var inputAccessoryView: UIView? { accessoryBar }
    private func makeAccessoryBar() -> UIView {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 650, height: 52)); scroll.backgroundColor = .secondarySystemBackground
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 5
        accessoryRow = row
        for (title, key) in [("Paste", -1), ("Esc", 0x1b), ("Ctrl", 0x11), ("Shift", 0x10), ("Alt", 0x12), ("Tab", 0x09), ("Enter", 0x0d), ("←", 0x25), ("↑", 0x26), ("↓", 0x28), ("→", 0x27), ("Done", 0)] {
            let button = UIButton(type: .system); button.configuration = .tinted(); button.setTitle(title, for: .normal)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self else { return }
                if key == -1 { HardwareInput.shared.pasteClipboard(); return }
                HardwareInput.shared.cancelPaste()
                let vk = Int32(key)
                if key == 0 { LibraryKeyboard.hide() }
                else if [0x10, 0x11, 0x12].contains(key) {
                    if self.held.contains(vk) { self.held.remove(vk); winios_post_key(vk, 0) }
                    else { self.held.insert(vk); winios_post_key(vk, 1) }
                    button?.isSelected = self.held.contains(vk)
                } else { self.press(vk) }
            }, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        scroll.addSubview(row); row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8), row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8), row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4), row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4), row.heightAnchor.constraint(equalToConstant: 44)])
        return scroll
    }
    private func press(_ vk: Int32) { winios_post_key(vk, 1); winios_post_key(vk, 0) }
    func insertText(_ text: String) {
        if HardwareInput.shared.handlesTyping { return }
        HardwareInput.shared.cancelPaste()
        for ch in text {
            guard let (vk, shift) = MetalBackedView.vkForChar(ch) else { continue }
            let temporary = shift && !held.contains(0x10)
            if temporary { winios_post_key(0x10, 1) }; press(vk); if temporary { winios_post_key(0x10, 0) }
        }
    }
    func deleteBackward() {
        if !HardwareInput.shared.handlesTyping { HardwareInput.shared.cancelPaste(); press(0x08) }
    }
    func releaseModifiers() {
        for key in held { winios_post_key(key, 0) }
        held.removeAll()
        for case let button as UIButton in accessoryRow?.arrangedSubviews ?? [] { button.isSelected = false }
    }
}

/// A desktop session (the Desktop entry) draws through Winios's compositor view,
/// a plain UIView the native side adds straight onto the app window, above the
/// SwiftUI root view, and never hides. The game view (MetalHostView) is hidden
/// when a session ends; the compositor was not, so the ended session's frozen
/// desktop covered the library. The library hides that view when the session
/// ends and shows it again when the next one begins. [library-surface] logs
/// both. MADEIRA_LIBRARY_HIDE_ENDED_DESKTOP=0 leaves it alone.
enum EndedSessionSurface {
    private static var watch: AnyCancellable?
    private static var hiddenByUs = false

    @MainActor static func install() {
        guard watch == nil else { return }
        watch = LibraryModel.shared.$current.receive(on: DispatchQueue.main).sink { current in
            MainActor.assumeIsolated {
                if current == nil { hide(reason: "session-ended") } else { show() }
            }
        }
    }

    /// `whileClosing`: Stop or Quit game went back to the library while Wine is still
    /// closing the session behind it, so the desktop is hidden without waiting for Wine.
    @MainActor static func hide(reason: String, whileClosing: Bool = false) {
        guard MadeiraConfig.flag("MADEIRA_LIBRARY_HIDE_ENDED_DESKTOP"), LibraryModel.shared.enabled,
              LibraryModel.shared.current == nil, whileClosing || wine_process_is_running() == 0 else { return }
        guard winios_compositor_set_hidden(1) != 0 else {
            // A session stopped before its desktop drew has no view yet; it may still
            // attach while Wine closes, so look again until Wine has gone.
            if whileClosing, wine_process_is_running() != 0 || wineserver_is_running() != 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated { hide(reason: reason, whileClosing: true) }
                }
            }
            return
        }
        hiddenByUs = true
        LogStore.shared.log("[library-surface] hid ended desktop reason=\(reason)")
    }

    @MainActor static func show() {
        guard hiddenByUs else { return }
        hiddenByUs = false
        _ = winios_compositor_set_hidden(0)
        LogStore.shared.log("[library-surface] desktop shown for the new session")
    }
}

// MARK: - Starting screen motion

/// The starting screen's staged entrance: each part fades in from a small offset
/// and scale, 70 ms after the one before it. Reduce Motion only fades.
struct LaunchEntrance: ViewModifier {
    var visible: Bool
    var step: Int
    var rise = CGSize(width: 0, height: 12)
    var scale: CGFloat = 1
    /// Under the launch flood: in place at once, never moving (the flood measures the
    /// cover's frame and lands on it).
    var still = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        let settled = visible || reduceMotion || still
        content.opacity(visible || still ? 1 : 0)
            .scaleEffect(settled ? 1 : scale)
            .offset(settled ? .zero : rise)
            .animation(still ? nil : reduceMotion ? .easeOut(duration: 0.2)
                                    : .spring(response: 0.62, dampingFraction: 0.84).delay(0.08 + Double(step) * 0.07),
                       value: visible)
    }
}

///
/// The press puts the starting screen up at once (LibraryModel.prepare), fully drawn
/// and without its own entrance, underneath this window. Here the button's colour grows
/// out of the button and fills the screen, darkening at once; then it gathers into the
/// cover's frame with the cover art and the cover's shadow coming in, while the
/// backdrop (the same hero image the starting screen shows) fades in and settles from a
/// slight zoom around it. Once both have landed the window dissolves onto the starting
/// screen, which shows the same pixels, so only its text and buttons fade in. When no
/// start follows the press it shrinks back into the button. MADEIRA_LAUNCH_FLOOD=0
/// turns it off; Reduce Motion skips it.
@MainActor final class LaunchCurtain: ObservableObject {
    static let shared = LaunchCurtain()
    private static let ink = UIColor(white: 0.06, alpha: 1)
    private var window: UIWindow?
    private var holder: UIView?      // the flood's frame and the cover's shadow
    private var flood: UIView?       // its colour, corners and the cover art
    private var spinner: UIActivityIndicatorView?
    private var heroView: UIImageView?
    private var origin: CGRect = .zero
    private var started = Date()
    private var gatherStarted = Date()
    /// The artwork the flood carries, for the starting screen too (the same pixels, so
    /// the hand-over changes nothing and waits for no download).
    @Published private(set) var coverImage: UIImage?
    @Published private(set) var heroImage: UIImage?
    private var imageAppID: Int?
    private var watch: Task<Void, Never>?
    private let enabled = MadeiraConfig.flag("MADEIRA_LAUNCH_FLOOD")   // 0: the starting screen fades in without growing out of the Play button

    /// The flood is up and has not been handed a cover yet.
    private(set) var covering = false
    /// The flood has not filled the screen yet: the starting screen under it stays hidden.
    @Published private(set) var hidesStartingScreen = false
    private var gather: UIViewPropertyAnimator?
    /// Where the starting screen's cover is now: its layout can still move while the
    /// flood gathers (status lines arriving), and the flood lands where it ends up.
    private var latestTarget: CGRect = .zero
    func track(_ frame: CGRect) {
        guard window != nil else { return }
        latestTarget = frame
        // Mid-gather, a move blends into the running animation (UIKit animations of the
        // same property are additive), so the flood bends to the new frame instead of
        // landing and then correcting.
        if let gather, gather.isRunning, let h = holder {
            let left = max(0.15, Double(1 - gather.fractionComplete) * gather.duration)
            UIViewPropertyAnimator(duration: left, dampingRatio: 1) { h.frame = frame }.startAnimation()
        }
    }

    func cover(for appID: Int?) -> UIImage? { appID != nil && appID == imageAppID ? coverImage : nil }
    func hero(for appID: Int?) -> UIImage? { appID != nil && appID == imageAppID ? heroImage : nil }

    private func fetch(_ url: URL?, into keyPath: ReferenceWritableKeyPath<LaunchCurtain, UIImage?>, appID: Int) {
        guard let url else { return }
        Task { [weak self] in
            guard let fetched = try? await URLSession.shared.data(from: url), let img = UIImage(data: fetched.0),
                  let self, self.imageAppID == appID else { return }
            self[keyPath: keyPath] = img
            if keyPath == \LaunchCurtain.heroImage, let hv = self.heroView, hv.image == nil { hv.image = img }
        }
    }

    func begin(from frame: CGRect, appID: Int?, artwork: URL?) {
        guard enabled, !UIAccessibility.isReduceMotionEnabled, window == nil, !frame.isEmpty,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
        let w = UIWindow(windowScene: scene)
        w.frame = scene.coordinateSpace.bounds
        w.windowLevel = .normal + 150; w.backgroundColor = .clear
        let root = UIViewController(); root.view.backgroundColor = .clear
        w.rootViewController = root; w.isHidden = false   // never made key
        let h = UIView(frame: frame)
        h.layer.shadowColor = UIColor.black.cgColor; h.layer.shadowOpacity = 0
        let v = UIView(frame: h.bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.backgroundColor = .tintColor
        v.layer.cornerCurve = .continuous; v.clipsToBounds = true
        h.addSubview(v); root.view.addSubview(h)
        window = w; holder = h; flood = v; origin = frame; started = Date(); covering = true; latestTarget = .zero
        hidesStartingScreen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.hidesStartingScreen = false }
        if let appID, appID != imageAppID {
            imageAppID = appID; coverImage = nil; heroImage = nil
            fetch(artwork, into: \.coverImage, appID: appID)
            fetch(SteamLaunchBackdrop.hero(appID), into: \.heroImage, appID: appID)
        } else if appID == nil {
            imageAppID = nil; coverImage = nil; heroImage = nil
        }
        let full = w.bounds.insetBy(dx: -2, dy: -2)
        let blob = CAKeyframeAnimation(keyPath: "cornerRadius")
        blob.values = [14, 56, 0]; blob.keyTimes = [0, 0.4, 1]; blob.duration = 0.5
        blob.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        v.layer.cornerRadius = 0
        v.layer.add(blob, forKey: "blob")
        UIViewPropertyAnimator(duration: 0.55, dampingRatio: 0.8) { h.frame = full }.startAnimation()
        UIViewPropertyAnimator(duration: 0.2, curve: .easeOut) { v.backgroundColor = Self.ink }.startAnimation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.covering, let root = self.window?.rootViewController?.view else { return }
            let s = UIActivityIndicatorView(style: .medium); s.color = .white
            s.center = CGPoint(x: root.bounds.midX, y: root.bounds.midY); s.alpha = 0
            root.addSubview(s); s.startAnimating(); self.spinner = s
            UIView.animate(withDuration: 0.3) { s.alpha = 1 }
        }
        watch = Task { [weak self] in await self?.watchStart() }
        fputs("[launch-curtain] flood from \(Int(frame.midX)),\(Int(frame.midY))\n", stderr)
    }

    /// How the starting screen draws its cover, for the flood to land looking the same.
    struct CoverStyle {
        var corner: CGFloat
        var shadowOpacity: Float
        var shadowRadius: CGFloat
        var shadowOffset: CGSize
    }

    /// The starting screen is laid out: once the flood has filled the screen, gather into
    /// its cover. `landed` runs when the flood sits on the cover, before the dissolve.
    func handOff(to cover: CGRect, style: CoverStyle, landed: @escaping () -> Void) {
        guard covering, let v = flood, let h = holder, let root = window?.rootViewController?.view else { landed(); return }
        covering = false
        let wait = max(0, 0.55 - Date().timeIntervalSince(started))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.gatherStarted = Date()
            if let s = self.spinner { UIView.animate(withDuration: 0.15) { s.alpha = 0 } }
            // The backdrop, under the flood: black, the hero image settling from a slight
            // zoom, and the starting screen's dimming over it.
            let back = UIView(frame: root.bounds); back.backgroundColor = .black
            let hv = UIImageView(image: self.heroImage)
            hv.frame = back.bounds; hv.contentMode = .scaleAspectFill; hv.clipsToBounds = true
            hv.alpha = 0; hv.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            let dim = UIView(frame: back.bounds); dim.backgroundColor = UIColor.black.withAlphaComponent(0.65)
            back.addSubview(hv); back.addSubview(dim)
            root.insertSubview(back, belowSubview: h)
            self.heroView = hv
            UIView.animate(withDuration: 0.6, delay: 0.05, options: [.curveEaseOut]) { hv.alpha = 1 }
            UIView.animate(withDuration: 1.0, delay: 0, options: [.curveEaseOut]) { hv.transform = .identity }

            let screen = root.bounds
            let target = cover.isEmpty ? CGRect(x: screen.midX - 60, y: screen.midY - 90, width: 120, height: 180) : cover
            var art: UIImageView?
            if let image = self.coverImage {
                let iv = UIImageView(image: image)
                iv.contentMode = .scaleAspectFill; iv.frame = v.bounds; iv.alpha = 0
                iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                v.addSubview(iv); art = iv
            }
            // The cover's shadow comes in as the flood nears the cover.
            h.layer.shadowRadius = style.shadowRadius; h.layer.shadowOffset = style.shadowOffset
            h.layer.shadowOpacity = style.shadowOpacity
            let shadow = CABasicAnimation(keyPath: "shadowOpacity")
            shadow.fromValue = 0; shadow.toValue = style.shadowOpacity
            shadow.beginTime = CACurrentMediaTime() + 0.3; shadow.duration = 0.32
            shadow.fillMode = .backwards
            h.layer.add(shadow, forKey: "shadow")
            let gather = UIViewPropertyAnimator(duration: 0.62, controlPoint1: CGPoint(x: 0.6, y: 0), controlPoint2: CGPoint(x: 0.15, y: 1)) {
                h.frame = target; v.layer.cornerRadius = style.corner
            }
            gather.addCompletion { [weak self] _ in guard let self else { return }; self.gather = nil; self.settle(on: self.latestTarget.isEmpty ? target : self.latestTarget, landed: landed) }
            self.gather = gather
            gather.startAnimation()
            // The art comes in over the second half, once the flood is near the cover's size.
            if let art { UIView.animate(withDuration: 0.22, delay: 0.3, options: [.curveEaseOut]) { art.alpha = 1 } }
        }
    }

    /// The gather reached `target`. If the cover moved meanwhile, follow it; then let the
    /// backdrop finish settling and dissolve onto the starting screen.
    private func settle(on target: CGRect, landed: @escaping () -> Void) {
        guard let h = holder else { landed(); close(); return }
        let now = latestTarget
        let at = h.layer.presentation()?.frame ?? h.frame
        let moved = !now.isEmpty && (abs(now.midX - at.midX) > 1 || abs(now.midY - at.midY) > 1
                                     || abs(now.width - at.width) > 1 || abs(now.height - at.height) > 1)
        if moved {
            let follow = UIViewPropertyAnimator(duration: 0.3, curve: .easeOut) { h.frame = now }
            follow.addCompletion { [weak self] _ in self?.settle(on: now, landed: landed) }
            follow.startAnimation()
            return
        }
        landed()
        let rest = max(0.05, 1.0 - Date().timeIntervalSince(gatherStarted))
        DispatchQueue.main.asyncAfter(deadline: .now() + rest) { [weak self] in
            UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseInOut]) { self?.window?.alpha = 0 }
                completion: { _ in self?.close() }
        }
    }

    private func retract() {
        guard covering, let v = flood, let h = holder else { return }
        covering = false
        if let s = spinner { UIView.animate(withDuration: 0.15) { s.alpha = 0 } }
        let back = UIViewPropertyAnimator(duration: 0.45, dampingRatio: 1) { [origin] in
            h.frame = origin; v.layer.cornerRadius = 14; v.backgroundColor = .tintColor
        }
        back.addCompletion { [weak self] _ in
            UIView.animate(withDuration: 0.15) { self?.window?.alpha = 0 } completion: { _ in self?.close() }
        }
        back.startAnimation()
    }

    private func close() {
        watch?.cancel(); watch = nil
        window?.isHidden = true; window = nil; holder = nil; flood = nil; spinner = nil; heroView = nil; covering = false
        gather = nil; hidesStartingScreen = false
    }

    /// No start after the press: retract. A start whose starting screen never hands over:
    /// gather to the middle and fade.
    private func watchStart() async {
        let model = LibraryModel.shared
        while !Task.isCancelled, covering {
            try? await Task.sleep(for: .milliseconds(200))
            guard covering else { return }
            let t = Date().timeIntervalSince(started)
            if model.cloudNotice != nil || model.error != nil { retract(); return }
            if !model.startingScreen && model.current == nil && model.startingJIT == nil && t > 2.5 { retract(); return }
            if t > 4 { handOff(to: .zero, style: CoverStyle(corner: 14, shadowOpacity: 0, shadowRadius: 0, shadowOffset: .zero), landed: {}); return }
        }
    }
}

// MARK: - Launch arguments are command lines, not prose

/// iOS Smart Punctuation turns `--` into an em dash and straight quotes into
/// curly ones, which breaks flags such as `--rendering-driver opengl3` and
/// quoted paths.
enum LaunchArgumentText {
    static func valid(_ text: String) -> Bool {
        guard text.utf8.count < 4096 else { return false }
        var quoted = false, inToken = false, tokens = 0, slashes = 0
        for byte in text.utf8 {
            if (byte < 32 && byte != 9) || byte == 127 { return false }
            if byte == 34 && slashes % 2 == 0 { quoted.toggle() }
            if !quoted && (byte == 32 || byte == 9) { inToken = false }
            else if !inToken { tokens += 1; inToken = true }
            slashes = byte == 92 ? slashes + 1 : 0
        }
        return !quoted && tokens <= 64
    }

    static func plain(_ s: String) -> String {
        var out = s
        for (from, to) in [("\u{2014}", "--"), ("\u{2013}", "--"), ("\u{2212}", "-"),
                           ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""),
                           ("\u{2018}", "'"), ("\u{2019}", "'")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
    }
}

extension Binding where Value == String {
    var plainLaunchArguments: Binding<String> {
        Binding(get: { LaunchArgumentText.plain(wrappedValue) },
                set: { wrappedValue = LaunchArgumentText.plain($0) })
    }
}

/// Finds the UIKit text view behind a SwiftUI TextField and turns off smart
/// dashes and quotes on it (SwiftUI has no modifier for these traits).
private struct SmartPunctuationOff: UIViewRepresentable {
    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        func apply() {
            var node: UIView? = superview
            for _ in 0..<4 {
                guard let n = node else { break }
                if Self.disable(in: n) { return }
                node = n.superview
            }
        }
        static func disable(in view: UIView) -> Bool {
            if let t = view as? UITextView {
                t.smartDashesType = .no; t.smartQuotesType = .no; t.smartInsertDeleteType = .no
                return true
            }
            if let t = view as? UITextField {
                t.smartDashesType = .no; t.smartQuotesType = .no; t.smartInsertDeleteType = .no
                return true
            }
            return view.subviews.contains { disable(in: $0) }
        }
    }
    func makeUIView(context: Context) -> Probe { let p = Probe(); p.isUserInteractionEnabled = false; return p }
    func updateUIView(_ uiView: Probe, context: Context) { DispatchQueue.main.async { uiView.apply() } }
}

extension View {
    func smartPunctuationOff() -> some View {
        background(SmartPunctuationOff().frame(width: 0, height: 0))
    }
}

// MARK: - New look (NewLook.swift)

extension LibraryView {
    /// The new look: Apple's own tab bar (TabView; Cameron, Nov 9: "Switch to Apple's own tab
    /// bar") with a page stack in every tab. The tab bar floats at the bottom on an iPhone and
    /// at the top on an iPad, as the system places it. Re-tapping a tab goes back to its first page.
    var newLookBody: some View {
        lookTabView
        .modifier(LibrarySheets(model: model, browser: $browser, selected: $selected, jit: jit))
        // A game's page: every way of opening one (a cover, the banner, Search, a store's game,
        // Add a game) sets `selected`; in the new look it is pushed on the open tab instead.
        .onChange(of: selected?.id) { _, id in
            guard id != nil, let entry = selected else { return }
            selected = nil
            lookOpenGame(entry)
        }
        // The new look's own questions (the controller can answer them; Apple's cannot be
        // reached by the pad here): a cover's options, Remove a download, a store's icon.
        .overlay {
            ZStack {
                if let entry = lookOptions {
                    NewLookOptionsSheet(entry: entry,
                                        play: { lookOptions = nil; lookPlay(entry) },
                                        open: { lookOptions = nil; selected = entry },
                                        close: { lookOptions = nil })
                        .transition(.opacity)
                }
                NewLookOverlays()
            }
        }
        .onChange(of: lookTab) { _, new in
            lookOptions = nil
            lookField = false
            PadHighlight.shared.enterPage(String(describing: new))
        }
        .onAppear {
            let pad = PadHighlight.shared
            pad.start()
            pad.tabs = { by in lookPick(lookTab.step(by)) }
            // Y: the open tab's search field takes the keyboard.
            pad.search = { lookField = true }
            pad.enterPage(String(describing: lookTab))
        }
    }

    /// The open tab. A tap on the tab that is open comes here too (the setter runs with the
    /// same tab): back to its first page, then to the top.
    private var lookSelection: Binding<NewLookTab> {
        Binding(get: { lookTab }, set: { new in
            if new == lookTab { lookReselect(new) } else { lookTab = new }
        })
    }

    /// Apple's tab bar.
    @ViewBuilder private var lookTabView: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: lookSelection) {
                Tab(NewLookTab.library.title, systemImage: NewLookTab.library.symbol, value: NewLookTab.library) { lookStack(.library) }
                Tab(NewLookTab.stores.title, systemImage: NewLookTab.stores.symbol, value: NewLookTab.stores) { lookStack(.stores) }
                    .badge(lookDownloads.badge.map { Text(verbatim: $0) })
                Tab(NewLookTab.settings.title, systemImage: NewLookTab.settings.symbol, value: NewLookTab.settings) { lookStack(.settings) }
            }
        } else {
            TabView(selection: lookSelection) {
                ForEach(NewLookTab.allCases, id: \.self) { item in
                    lookStack(item)
                        .tabItem { Label(item.title, systemImage: item.symbol) }
                        .badge(item == .stores ? lookDownloads.badge.map { Text(verbatim: $0) } : nil)
                        .tag(item)
                }
            }
        }
    }

    /// A tab's search text.
    private func lookText(_ item: NewLookTab) -> Binding<String> {
        Binding(get: { lookQuery[item] ?? "" }, set: { lookQuery[item] = $0 })
    }

    private func lookSearching(_ item: NewLookTab) -> Bool {
        !(lookQuery[item] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// One tab: its own page stack, its first page (or its search results, while its field holds
    /// text), and the controller's hints above the bar.
    @ViewBuilder private func lookStack(_ item: NewLookTab) -> some View {
        Group {
            switch item {
            case .library:
                NavigationStack(path: $libraryPath) {
                    NewLookScrollPage(refresh: { await SteamGamesSection.refresh() }, top: lookTop[.library, default: 0]) { width in
                        if lookSearching(.library) {
                            lookResults(.library)
                        } else {
                            NewLookLibraryPage(width: width, enableJIT: enableJIT,
                                               open: { selected = $0 }, play: { lookPlay($0) },
                                               options: { entry in withAnimation(.easeOut(duration: 0.15)) { lookOptions = entry } },
                                               add: { browser = true },
                                               desktop: { big in
                                                   selected = big ? (model.entries.first(where: { $0.bigPicture == true }) ?? .bigPictureEntry)
                                                                  : (model.entries.first(where: { $0.desktop == true }) ?? .desktopEntry)
                                               },
                                               stores: { lookTab = .stores })
                        }
                    }
                    .modifier(NewLookTabRoot(title: item.title))
                    .modifier(NewLookSearchField(text: lookText(.library), prompt: L("Search installed games"), field: $lookField))
                    .navigationDestination(for: NewLookRoute.self) { lookRoute($0) }
                }
            case .stores:
                NavigationStack(path: $storesPath) {
                    NewLookScrollPage(top: lookTop[.stores, default: 0]) { _ in
                        if lookSearching(.stores) {
                            lookResults(.stores)
                        } else {
                            NewLookStoresPage(open: { storesPath.append(NewLookRoute.store($0)) })
                        }
                    }
                    .modifier(NewLookTabRoot(title: item.title))
                    .modifier(NewLookSearchField(text: lookText(.stores), prompt: L("Search games across stores"), field: $lookField))
                    .navigationDestination(for: NewLookRoute.self) { lookRoute($0) }
                }
            case .settings:
                NavigationStack(path: $settingsPath) {
                    NewLookScrollPage(top: lookTop[.settings, default: 0]) { _ in
                        if lookSearching(.settings) {
                            lookResults(.settings)
                        } else {
                            NewLookSettingsList(enableJIT: enableJIT, open: { settingsPath.append(NewLookRoute.settings($0)) })
                        }
                    }
                    .modifier(NewLookTabRoot(title: item.title))
                    .modifier(NewLookSearchField(text: lookText(.settings), prompt: L("Search settings"), field: $lookField))
                    .navigationDestination(for: NewLookRoute.self) { lookRoute($0) }
                }
            }
        }
        .modifier(NewLookTabChrome(tab: item))
    }

    /// A tab's search results; a result opens inside the same tab, and Back returns to the results.
    private func lookResults(_ item: NewLookTab) -> some View {
        NewLookSearchPage(scope: item == .library ? .library : item == .stores ? .stores : .settings,
                          text: lookQuery[item] ?? "",
                          open: { selected = $0 },
                          store: { storesPath.append(NewLookRoute.store($0)) },
                          storeGame: { game in lookPendingGame = game; storesPath.append(NewLookRoute.store(game.store)) },
                          setting: { settingsPath.append(NewLookRoute.settings($0)) })
    }

    /// A tab, from the controller (LB/RB) or a button on a page.
    private func lookPick(_ item: NewLookTab) {
        guard item != lookTab else { return }
        lookTab = item
    }

    /// The open tab tapped again, as on every iPhone app: a pushed page goes back to the tab's
    /// first page; on the first page it scrolls to the top (and empties the tab's search field).
    private func lookReselect(_ item: NewLookTab) {
        let path = lookPath(item)
        if !path.wrappedValue.isEmpty { path.wrappedValue = NavigationPath(); return }
        lookTop[item, default: 0] += 1
        lookQuery[item] = ""
    }

    /// A tab's page stack.
    private func lookPath(_ item: NewLookTab) -> Binding<NavigationPath> {
        switch item {
        case .library: $libraryPath
        case .stores: $storesPath
        case .settings: $settingsPath
        }
    }

    /// A game's page, pushed on the open tab's stack like any iPhone page (ux-review-0044 #1):
    /// Back, the edge swipe and B take it off; the tab bar stays. Opened by X on a cover it comes
    /// without the slide, so Play is in place when the game starts (LibraryDetail.autoPlayIfAsked).
    private func lookOpenGame(_ entry: LibraryEntry) {
        lookGames[entry.id] = entry
        let tab = lookTab
        let path = lookPath(tab)
        let route = NewLookRoute.game(entry.id, tab: tab, depth: path.wrappedValue.count)
        if NewLook.autoPlay == entry.id {
            var instant = Transaction(); instant.disablesAnimations = true
            withTransaction(instant) { path.wrappedValue.append(route) }
        } else {
            path.wrappedValue.append(route)
        }
        LogStore.shared.log("[new-look] game page pushed: \(entry.title) on \(String(describing: tab))")
    }

    /// The moves a pushed game page makes on its own tab's stack (LibraryDetail.stack). The tab
    /// and the depth come with the page (NewLookRoute.game), never from the tab open now.
    private func lookGameStack(tab: NewLookTab, depth: Int) -> LibraryDetailStack {
        LibraryDetailStack(
            push: { page in lookPath(tab).wrappedValue.append(page) },
            back: { let path = lookPath(tab); if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() } },
            close: {
                // The game's page and everything over it.
                let path = lookPath(tab)
                let over = path.wrappedValue.count - depth
                if over > 0 { path.wrappedValue.removeLast(over) }
            })
    }

    /// X on a cover, or Play in its options: its page opens and starts it (all of Play's checks run there).
    private func lookPlay(_ entry: LibraryEntry) {
        NewLook.autoPlay = entry.id
        selected = entry
    }

    /// A page pushed inside a tab.
    @ViewBuilder private func lookRoute(_ route: NewLookRoute) -> some View {
        switch route {
        case .store(let store):
            NewLookScrollPage { width in
                NewLookStorePage(store: store, width: width, open: { selected = $0 }, add: { browser = true },
                                 shown: { lookOpenPending(store) })
            }
            .navigationTitle(store.name)
            .navigationBarTitleDisplayMode(.inline)
        case .settings(let page):
            SettingsPageView(page: page, startDock: startDock)
        case .game(let id, let tab, let depth):
            if let entry = lookGames[id] ?? model.entries.first(where: { $0.id == id }) {
                LibraryDetail(entry: entry, play: { play($0) }, stack: lookGameStack(tab: tab, depth: depth))
                    // MenuPad and PadHighlight own the pad: the system's focus must not also press rows.
                    .modifier(ClaimGamepadEvents())
                    .logScreen("game page: \(entry.title)")
            }
        }
    }

    /// The store game picked in Search: its store's own sheet, now that the store's page is up.
    private func lookOpenPending(_ store: NewLookStore) {
        guard let game = lookPendingGame, game.store == store else { return }
        lookPendingGame = nil
        NewLookSearch.openSheet(game)
    }
}

/// A page pushed inside a new-look tab (each tab has its own NavigationStack).
enum NewLookRoute: Hashable {
    case store(NewLookStore)
    case settings(SettingsPages.Page)
    /// A game's page: the tab it is on and how many pages were under it when it opened.
    case game(UUID, tab: NewLookTab, depth: Int)
}

/// A tab's first page: Apple's large title, which shrinks into the bar as the page scrolls.
struct NewLookTabRoot: ViewModifier {
    let title: String
    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
    }
}

/// A tab's search field: Apple's own, always shown under the title (it hid until you pulled the page
/// down), tied to the controller's Y.
struct NewLookSearchField: ViewModifier {
    let text: Binding<String>
    let prompt: String
    var field: FocusState<Bool>.Binding
    func body(content: Content) -> some View {
        content
            .searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(prompt))
            .modifier(NewLookSearchFocus(field: field))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }
}

/// Every tab's stack: the controller's button hints above the tab bar while the highlight shows.
struct NewLookTabChrome: ViewModifier {
    let tab: NewLookTab
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) { NewLookPadHints(tab: tab) }
    }
}

/// Play's look: on iOS 26 Apple's .glassProminent button in Play's blue (capsule, as the
/// system draws it); before that, and with Reduce Transparency, a solid blue capsule.
struct LookPlayStyle: ViewModifier {
    let leaving: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content.buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(NewLookColor.button)
        } else {
            content.buttonStyle(.plain)
                .background(leaving ? Color(uiColor: .systemGray) : NewLookColor.button, in: Capsule())
        }
    }
}

/// The controller's buttons for the open screen, while the highlight shows.
struct NewLookPadHints: View {
    let tab: NewLookTab
    @ObservedObject private var pad = PadHighlight.shared
    var body: some View {
        if pad.shown {
            NewLookHints(items: pad.layerName == PadLayer.root
                         ? (tab == .library ? [("A", L("Select")), ("X", L("Play")), ("Y", L("Search")), ("LB RB", L("Tabs"))]
                                            : [("A", L("Select")), ("Y", L("Search")), ("LB RB", L("Tabs"))])
                         : [("A", L("Select")), ("B", L("Back"))])
                .padding(.bottom, 8)
        }
    }
}

// MARK: - New look game page

extension LibraryDetail {
    /// B on the game page: back a page, else close it (not while one of its sheets is up).
    fileprivate func lookBack() {
        guard !getHelp, !leaving, !findCover, !importCover, !remove, !confirmReset, !confirmSteamUninstall else { return }
        // Pushed: B takes the top page off the tab's stack (this page, or one of its pages over it).
        if let stack { if path.isEmpty { model.save(entry) }; stack.back(); return }
        if path.isEmpty { model.save(entry); dismiss() }
        else { path.removeLast() }   // slides back (Cameron, Nov 9)
    }

    /// Closes the game page: off the tab's stack with any of its pages over it (pushed), else
    /// the sheet or cover it is in.
    func closePage() {
        if let stack { stack.close() } else { dismiss() }
    }

    /// The new look's game page: the cover, the name and Play at the top; the game's
    /// settings in groups; Get Help; Uninstall last. On a wide screen, two columns.
    var newLookPage: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 820
            let top = geo.size.width > geo.size.height || geo.size.width >= 700
            ZStack(alignment: top ? .top : .bottom) {
                NewLookBackground()
                ScrollViewReader { reader in
                    ScrollView {
                        Group {
                            if wide {
                                HStack(alignment: .top, spacing: 24) {
                                    VStack(alignment: .leading, spacing: 24) { lookHero(wide: true); lookHelp }
                                        .frame(maxWidth: .infinity)
                                    VStack(alignment: .leading, spacing: 24) { lookSettings }
                                        .frame(maxWidth: .infinity)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 24) { lookHero(wide: false); lookSettings; lookHelp }
                            }
                        }
                        .padding(.horizontal, top ? 28 : 16)
                        // Pushed, the system's bar and tab bar hold Back and the hints (NewLookTabChrome).
                        .padding(.top, stack != nil ? 12 : top ? 84 : 64)
                        .padding(.bottom, stack != nil ? 32 : top ? 48 : 150)
                        .frame(maxWidth: 1180).frame(maxWidth: .infinity)
                        // The page's very top: the highlight on Play scrolls up to it, cover and all.
                        .overlay(alignment: .top) { Color.clear.frame(height: 1).id("pad-top") }
                    }
                    .scrollIndicators(.hidden)
                    .padScrollFollow(reader, toTop: ["gp-play"])
                }
                // Back, only on the full-screen page (pushed, it is the system's). (No copy of the
                // tab bar: a page over the whole screen has none in Apple's apps: ux-review-0044 #1.)
                if stack == nil {
                ZStack(alignment: .topLeading) {
                    Button { lookBack() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 19, weight: .semibold))
                            .frame(width: 48, height: 48).contentShape(Circle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.primary)
                    .newLookGlass()
                    .accessibilityLabel(L("Back"))
                    .padItem("gp-back", capsule: true) { lookBack() }
                    .padding(.leading, top ? 24 : 16).padding(.top, top ? 18 : 6)
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                }
                // The controller's buttons, at the bottom while the highlight shows.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    NewLookPadHints(tab: .library).padding(.bottom, top ? 16 : 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                }
            }
        }
        // X on a cover: start once Play is laid out, where it ends up (the starting screen grows
        // out of it). The page opens without the slide then (LibraryView.lookOpenGame), so Play's
        // first place on screen is its last; no timer (ux-review-0044 #4).
        .onAppear { if playFrame != .zero { autoPlayIfAsked() } }
        .onChange(of: playFrame) { old, new in if old == .zero, new != .zero { autoPlayIfAsked() } }
    }

    /// Starts the game when the page was opened by X on its cover (NewLook.autoPlay).
    private func autoPlayIfAsked() {
        guard NewLook.autoPlay == entry.id else { return }
        NewLook.autoPlay = nil
        start()
    }

    /// Cover, name, where it is from and when it was played, and Play (the only filled button).
    private func lookHero(wide: Bool) -> some View {
        let playing = model.startingJIT == entry.id
        let info: String = {
            var parts: [String] = []
            if entry.steamAppID != nil { parts.append("Steam") }
            else if entry.epicAppName != nil { parts.append("Epic Games") }
            else if entry.gogProductID != nil { parts.append("GOG") }
            else if entry.itchGameID != nil { parts.append("itch.io") }
            else if entry.eaOfferID != nil { parts.append("EA app") }
            if let appID = entry.steamAppID, let summary = SteamOwnedLibrary.shared.playtime[appID]?.summary { parts.append(summary) }
            else if let played = entry.lastPlayed { parts.append(String(format: L("Played %@"), played.formatted(.relative(presentation: .named)))) }
            return parts.joined(separator: " · ")
        }()
        let playButton = Button(action: start) {
            HStack(spacing: 12) {
                if playing {
                    ProgressView().tint(.white)
                    Text("Starting JIT").fontWeight(.semibold)
                } else {
                    Image(systemName: "play.fill"); Text("Play").fontWeight(.semibold)
                }
            }
            .font(.body)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white)
            .contentShape(Capsule())
        }
        // Apple's own prominent glass button on iOS 26 (the one filled button on the page), the blue capsule before.
        .modifier(LookPlayStyle(leaving: leaving))
        .disabled(leaving)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { playFrame = $0 }
        .padItem("gp-play", capsule: true) { start() }
        return VStack(alignment: .leading, spacing: 16) {
            if wide {
                HStack(alignment: .bottom, spacing: 16) {
                    artwork(backdrop: false).frame(width: 170, height: 255)
                        .clipShape(RoundedRectangle(cornerRadius: NewLook.coverRadius, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(entry.title).font(.largeTitle.bold()).lineLimit(3).minimumScaleFactor(0.7)
                        if !info.isEmpty { Text(info).font(.subheadline).foregroundStyle(.secondary) }
                        LibraryBadges(entry: entry)
                        playButton
                    }
                }
            } else {
                artwork(backdrop: false).frame(width: 140, height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: NewLook.coverRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                Text(entry.title).font(.largeTitle.bold()).lineLimit(3).minimumScaleFactor(0.7)
                if !info.isEmpty { Text(info).font(.subheadline).foregroundStyle(.secondary) }
                LibraryBadges(entry: entry)
                playButton
            }
            // A game Valve's client starts (Madeira Dock): can it start without a connection?
            if DockOffline.enabled, let appID = entry.steamAppID, !entry.startsSteamGameDirectly {
                DockOfflineMark(appID: appID)
            }
            if let error {
                Text(error).foregroundStyle(NewLookColor.red).padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading).newLookCard()
            }
            // A running update blocks Play: its progress shows here too.
            if let appID = entry.steamAppID, let download = steam.downloads[appID] {
                SteamDownloadStatus(download: download).padding(16).newLookCard()
            }
        }
    }

    /// The settings: the quick switches, then each group of pages.
    @ViewBuilder private var lookSettings: some View {
        NewLookSection(title: L("While playing")) {
            lookRow("gp-fps", press: { entry.fpsMode = FPSChoice.next(after: entry.fpsMode) }) {
                NewLookBadge(symbol: "speedometer")
                FPSChoice(mode: $entry.fpsMode)
            }
            lookRow("gp-overlay", press: { entry.performance.toggle() }) {
                NewLookBadge(symbol: "chart.bar.xaxis")
                Toggle(isOn: $entry.performance) {
                    lookLabel(L("Performance overlay"), L("Frame rate and memory over the game."))
                }
                .tint(NewLookColor.green)
            }
            lookRow("gp-touch", last: true, press: { entry.touchControls.toggle() }) {
                NewLookBadge(symbol: "hand.tap")
                Toggle(isOn: $entry.touchControls) {
                    lookLabel(L("Touch controls"), L("Buttons on the screen while you play."))
                }
                .tint(NewLookColor.green)
            }
        }
        ForEach(Array(pageGroups.enumerated()), id: \.offset) { index, group in
            NewLookSection(title: lookGroupTitle(group)) {
                ForEach(group, id: \.self) { item in
                    lookRow("gp-page-\(item)", last: item == group.last, press: { open(item) }) {
                        NewLookPageIcon(symbol: item.symbol, store: item.store)
                        lookLabel(L(item.title), item.blurb)
                        Spacer(minLength: 8)
                        if let value = summary(item) { Text(value).lineLimit(1).foregroundStyle(.secondary) }
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// Get Help, and Uninstall at the very bottom.
    @ViewBuilder private var lookHelp: some View {
        if GetHelp.enabled {
            NewLookSection(title: L("Help")) {
                lookRow("gp-help", last: true, press: { getHelp = true }) {
                    NewLookBadge(symbol: "lifepreserver")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Get Help").font(.body.weight(.semibold)).foregroundStyle(.primary)
                        Text("Looks at what happened and tells you what to try.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        if steamUninstallable != nil {
            VStack(spacing: 0) {
                lookRow("gp-uninstall", last: true, press: { confirmSteamUninstall = true }) {
                    Text(String(format: L("Uninstall %@"), entry.title)).font(.body.weight(.semibold))
                        .foregroundStyle(NewLookColor.red).lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            .newLookCard()
            .confirmationDialog("Uninstall \(entry.title)? Its downloaded files are deleted from where it is installed. Saves stored elsewhere are kept.",
                                isPresented: $confirmSteamUninstall, titleVisibility: .visible) {
                Button("Uninstall", role: .destructive) {
                    if let installed = steamUninstallable { steam.uninstall(installed) }
                    leaving = true; closePage()
                }
            }
        }
    }

    /// A row's name and, under it, what it does (as Get Help's row).
    private func lookLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
            Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One row of a group: tappable, highlightable, with a line under it unless it is the last.
    private func lookRow<Content: View>(_ id: String, last: Bool = false, press: @escaping () -> Void,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        Button(action: press) {
            HStack(spacing: 12) { content() }
                // Room above and below the words, so the highlight (4 pt inside the row) never
                // crosses a two-line row's text (Cameron, Test 6: Display, Get Help).
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5).padding(.leading, 16 + 30 + 12) }
        }
        .padItem(id, cornerRadius: NewLook.cardRadius, inset: 4, press: press)
    }

    private func lookGroupTitle(_ group: [Page]) -> String? {
        if group.contains(.display) { return L("Display and controls") }
        if group.contains(.advanced) { return L("Game files") }
        switch group.first {
        case .steam?, .cloud?, .achievements?, .workshop?: return "Steam"
        case .gog?: return "GOG"
        case .itch?: return "itch.io"
        case .epic?: return "Epic Games"
        case .ea?: return "EA app"
        default: return nil
        }
    }
}

// MARK: - New look: the starting screen

extension LibraryHUD {
    /// (new-look) The starting screen: the Madeira island behind it (LibraryHUD's body), the
    /// cover and "Starting <game>", one tile per step of the start, and Stop. A start that
    /// stopped says why in a red card with Get Help first. The controller's highlight starts
    /// on Stop (or Get Help once it failed); B only moves it to Stop, A on Stop stops.
    func newLookLaunch(_ entry: LibraryEntry, geometry geo: GeometryProxy) -> some View {
        let available = max(0, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom)
        let wide = geo.size.width > geo.size.height && geo.size.width >= 700
        let failed = dockStart.failure != nil || model.poolRestartNote != nil
        let showLogs = model.launchLogs
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    launchCover(entry).frame(width: wide ? 96 : 72, height: wide ? 144 : 108)
                        .clipShape(RoundedRectangle(cornerRadius: NewLook.coverRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: NewLook.coverRadius, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { coverFrame = $0; LaunchCurtain.shared.track($0) }
                        .opacity(coverLanded ? 1 : 0)
                        .modifier(LaunchEntrance(visible: launchVisible, step: 0, rise: CGSize(width: 0, height: 20), scale: 0.88, still: curtained))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: L("Starting %@"), entry.title)).font(.title2.bold())
                            .lineLimit(2).minimumScaleFactor(0.7)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("\(Int(context.date.timeIntervalSince(model.startingSince)))s")
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .modifier(LaunchEntrance(visible: launchVisible, step: 1, rise: CGSize(width: 0, height: 14), still: curtained))
                    Spacer(minLength: 0)
                }
                // The steps, read again once a second (the Dock's report has no change signal).
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 8) {
                        ForEach(lookSteps(entry)) { NewLookStepTile(step: $0) }
                    }
                }
                .padding(6)   // step tiles (16) 6 pt inside the card (22): concentric
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: NewLook.cardRadius, style: .continuous))
                .modifier(LaunchEntrance(visible: launchVisible, step: 2, still: curtained))
                if failed { lookFailure(entry) } else { lookControls }
                if showLogs {
                    LibraryLiveLogs().frame(height: min(170, available * 0.3))
                        .clipShape(RoundedRectangle(cornerRadius: NewLook.coverRadius, style: .continuous))
                }
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            .frame(minHeight: available)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86), value: failed)
        }
        .frame(width: geo.size.width, height: available)
        .padding(.top, geo.safeAreaInsets.top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padLayer("start", start: failed ? "ln-help" : "ln-stop", back: {
            // B never stops by itself: it shows Stop, and A on it stops (Cameron's "asks first").
            let pad = PadHighlight.shared
            pad.show()
            let stopped = DockStartScreen.shared.failure != nil || LibraryModel.shared.poolRestartNote != nil
            pad.move(toAny: stopped ? ["ln-close", "ln-restart", "ln-help"] : ["ln-stop"])
        })
        .onChange(of: failed) { _, now in
            // The start stopped: the highlight goes to Get Help (or Close when Get Help is off).
            // Its buttons are laid out on the next pass.
            if now { DispatchQueue.main.async { PadHighlight.shared.move(toAny: ["ln-help", "ln-restart", "ln-close"]) } }
        }
    }

    /// Stop, the live log, Show desktop, Close Madeira and Show game view, as the old screen had.
    @ViewBuilder fileprivate var lookControls: some View {
        VStack(spacing: 12) {
            if model.current != nil {
                NewLookSheetButton(id: "ln-stop", title: L("Stop"), symbol: "stop.fill") { model.stopStartToLibrary() }
            }
            if model.installsRestartReady {
                NewLookSheetButton(id: "ln-restart", title: L("Close Madeira"), symbol: "arrow.clockwise", filled: true) {
                    model.closeForInstallsRestart()
                }
            }
            HStack(spacing: 12) {
                NewLookSheetButton(id: "ln-log", title: model.launchLogs ? L("Hide live log") : L("Show live log"),
                                   symbol: "text.alignleft") { model.toggleLaunchLogs() }
                if dockStart.holding {
                    NewLookSheetButton(id: "ln-desktop", title: L("Show desktop"), symbol: "macwindow") { dockStart.showDesktop(model) }
                        .accessibilityHint(L("Shows the Windows desktop"))
                }
            }
            if model.launchSlow && !dockStart.holding {
                NewLookSheetButton(id: "ln-view", title: L("Show game view"), symbol: "eye") { model.showGameView(reason: "button") }
            }
        }
        .modifier(LaunchEntrance(visible: launchVisible, step: 3, still: curtained))
    }

    /// Why the start stopped: the Dock's words or "Not enough memory", then Get Help (filled),
    /// Close Madeira when a fresh run is needed, and Close back to the library.
    fileprivate func lookFailure(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let note = model.poolRestartNote {
                Text(JITPoolAuto.startHeadline).font(.headline)
                Text(note).font(.subheadline).foregroundStyle(.white.opacity(0.88)).fixedSize(horizontal: false, vertical: true)
            } else if let failure = dockStart.failure {
                Text("Madeira Dock stopped").font(.headline)
                Text(failure).font(.subheadline).foregroundStyle(.white.opacity(0.88)).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 12) {
                // (get-help-auto) The sheet also opens by itself a second after the Dock stopped.
                if dockStart.failure != nil && GetHelp.enabled {
                    NewLookSheetButton(id: "ln-help", title: L("Get Help"), symbol: "lifepreserver", filled: true) {
                        GetHelpCenter.shared.openOnStartScreen(entry, error: dockStart.failure)
                    }
                }
                if model.installsRestartReady {
                    NewLookSheetButton(id: "ln-restart", title: L("Close Madeira"), symbol: "arrow.clockwise") { model.closeForInstallsRestart() }
                } else if model.poolRestartNote != nil {
                    NewLookSheetButton(id: "ln-restart", title: L("Close Madeira"), symbol: "arrow.clockwise",
                                       filled: !(dockStart.failure != nil && GetHelp.enabled)) { model.closeForPoolRestart() }
                }
                HStack(spacing: 12) {
                    if model.current != nil {
                        NewLookSheetButton(id: "ln-close", title: L("Close"), symbol: nil) { model.stopStartToLibrary() }
                    }
                    NewLookSheetButton(id: "ln-log", title: model.launchLogs ? L("Hide live log") : L("Show live log"),
                                       symbol: "text.alignleft") { model.toggleLaunchLogs() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(red: 0.32, green: 0.07, blue: 0.08).opacity(0.92)))
    }

    /// The start's steps from what Madeira knows: getting ready (JIT), then for a Madeira Dock
    /// (Steam) start the one-time installs, Steam and the game; for any other game the game.
    /// Steam's step is done once the Dock reports the game's launch accepted (launch-client-error 0).
    fileprivate func lookSteps(_ entry: LibraryEntry) -> [NewLookStep] {
        MainActor.assumeIsolated {
            var steps: [NewLookStep] = []
            let ready = model.current != nil && model.preparing == nil
            steps.append(NewLookStep(id: "ready", title: L("Get ready"), detail: ready ? nil : launchIdleStatus,
                                     symbol: "bolt.fill", state: ready ? .done : .active))
            let open = String(format: L("Open %@"), entry.title)
            if dockStart.active || dockStart.failure != nil {
                let fields = MadeiraDock.pollReport().fields
                let setupDone = DockInstallers.script == nil || DockInstallers.finishedAt != nil
                if DockInstallers.script != nil {
                    steps.append(NewLookStep(id: "setup", title: L("First-time setup"),
                                             detail: ready && !setupDone ? DockInstallers.note : nil, symbol: "wrench.and.screwdriver.fill",
                                             state: setupDone ? .done : ready ? .active : .waiting))
                }
                let launched = fields["launch-client-error"] == "0"
                let steam: NewLookStep.State = dockStart.failure != nil ? .failed : launched ? .done : ready && setupDone ? .active : .waiting
                steps.append(NewLookStep(id: "steam", title: L("Start Steam"), detail: steam == .active ? dockStatus : nil,
                                         symbol: "cloud.fill", state: steam))
                steps.append(NewLookStep(id: "game", title: open, detail: launched && dockStart.failure == nil ? L("Waiting for its window…") : nil,
                                         symbol: "play.fill", state: launched && dockStart.failure == nil ? .active : .waiting))
            } else {
                steps.append(NewLookStep(id: "game", title: open, detail: ready ? launchIdleStatus : nil,
                                         symbol: "play.fill", state: ready ? .active : .waiting))
            }
            // Not enough memory: the step that was running is the one that stopped.
            if model.poolRestartNote != nil, let i = steps.lastIndex(where: { $0.state == .active }) { steps[i].state = .failed }
            return steps
        }
    }
}
