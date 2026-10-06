import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Darwin
import ImageIO
import Combine

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

/// Thermal state, Low Power Mode and screen capture every 10 s while a session
/// runs: the three device conditions that explain a slow run in a log.
/// MADEIRA_DEVICE_STATS=0 turns the line off.
enum DeviceLoadDiagnostics {
    private static var lastReport = 0.0
    private static var timer: Timer?
    /// Opt-in (env.MADEIRA_DEVICE_STATS = 1): a line every 10 s during every
    /// session is a diagnostic, so it is off by default.
    static func start() {
        guard timer == nil, MadeiraConfig.flag("MADEIRA_DEVICE_STATS", fallback: false) else { return }
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
        fputs("[device-load] thermal=\(thermal) low-power=\(process.isLowPowerModeEnabled ? 1 : 0) capture=\(UIScreen.main.isCaptured ? 1 : 0)\n", stderr)
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
/// Y adds a game, a shoulder switches tabs; in a session Back+Start opens the
/// menu. MADEIRA_FRONTEND_CONTROLLER=0 turns navigation off.
final class LibraryController: ObservableObject, @unchecked Sendable {
    static let shared = LibraryController()
    @Published var connected = false
    let commands = PassthroughSubject<String, Never>()
    private let lock = NSLock()
    private var enabled = false
    private var owns = false
    private var last: UInt16 = 0
    private var announced = false
    private let allowed = MadeiraConfig.flag("MADEIRA_FRONTEND_CONTROLLER")
    var ownsInput: Bool { lock.lock(); defer { lock.unlock() }; return enabled && owns }
    func configure(enabled: Bool, ownsInput: Bool) {
        lock.lock(); self.enabled = enabled && allowed; owns = ownsInput; lock.unlock()
    }
    /// One sample of player 1's pad, in XInput button bits and stick units.
    func sample(buttons raw: UInt16, lx: Int16, ly: Int16) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        var buttons = raw
        if owns {
            if lx < -16000 { buttons |= 4 }; if lx > 16000 { buttons |= 8 }
            if ly > 16000 { buttons |= 1 }; if ly < -16000 { buttons |= 2 }
        }
        let pressed = buttons & ~last; last = buttons
        let own = owns, announce = !announced; announced = true
        lock.unlock()
        if announce { DispatchQueue.main.async { self.connected = true; fputs("[frontend-controller] navigation active\n", stderr) } }
        var command: String?
        // Reserve the Back+Start chord in gameplay, leaving ordinary Start intact.
        if !own, buttons & 0x30 == 0x30, pressed & 0x30 != 0 { command = "menu" }
        if own {
            for (mask, name): (UInt16, String) in [(1, "up"), (2, "down"), (4, "left"), (8, "right"), (0x1000, "accept"), (0x2000, "back"), (0x8000, "add"), (0x10, "menu"), (0x100, "tab"), (0x200, "tab")] {
                if pressed & mask != 0 { command = name; break }
            }
        }
        if let command { DispatchQueue.main.async { self.commands.send(command) } }
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
    /// FEX's X87ReducedPrecision for this game. Off by default, as in FEX; only
    /// an explicit choice exports FEX_X87REDUCEDPRECISION=1.
    var reducedX87 = false
    var liveLogs = false
    var performance = false
    var touchControls = false
    var controls: [TouchControl]?
    /// The named layout (TouchControlPresets.swift) `controls` came from, so the
    /// Session menu shows it and an edit is written back to it; nil for controls
    /// no layout holds. Older files have none.
    var controlLayout: String?
    var lastPlayed: Date?
    var graphicsAPI: String?
    var folderBytes: Int64?
    var metadataChecked: Date?
    var metadataRevision: Int?
    var overlayFields: [String]?
    /// The Wine desktop (explorer and services in a virtual desktop).
    var desktop: Bool?
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
    /// Epic's installed app and public art; optional for older library files.
    var epicAppName: String?
    var epicLaunchCommand: String?
    var epicArtworkURL: URL?
    var epicHeroURL: URL?
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

    /// What MadeiraConfig.applyGame writes for this game: the lines its pickers
    /// stand for, then its own config, which wins where both set a key.
    var gameConfigText: String? {
        var lines: [String] = []
        if let metalFXUpscale { lines.append("metalfx-upscale = \(metalFXUpscale)") }
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
    /// else the entry's Launch arguments.
    var programArguments: String { startsSteamGameDirectly ? (steamProgramArguments ?? "") : arguments }
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
        guard usesLaunchOptions, startServices == true else { return nil }
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
        return [
            "@echo off",
            "rem Generated by Madeira (ml1163) for \(batchText(title)); rewritten at every launch.",
            "start \"\" \"C:\\windows\\system32\\services.exe\"",
            "cd /d \(quoted(batchText(launchDirectory)))",
            extra.isEmpty ? run : run + " " + extra,
        ].joined(separator: "\r\n") + "\r\n"
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
    private var launchCommand: (exe: String, args: String) {
        func quoted(_ s: String) -> String { "\"\(s)\"" }
        var path = launchWindowsPath
        var extra = programArguments.trimmingCharacters(in: .whitespaces)
        var batch = isBatch
        if servicesScript != nil { path = servicesScriptPath; extra = ""; batch = true }
        func withExtra(_ s: String) -> String { extra.isEmpty ? s : s + " " + extra }
        if runsInDesktop {
            return ("explorer.exe", "/desktop=shell,\(resolution) " + withExtra(batch ? "cmd /c \(quoted(path))" : quoted(path)))
        }
        if batch { return ("C:\\windows\\system32\\cmd.exe", withExtra("/c \(quoted(path))")) }
        return (path, programArguments)   // upstream's direct launch, arguments verbatim
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
        var quoted = false, inToken = false, tokens = 0
        for character in launchArguments {
            if character == "\"" { quoted.toggle() }
            if !quoted && (character == " " || character == "\t") { inToken = false }
            else if !inToken { tokens += 1; inToken = true }
        }
        // WineProcessBridge takes at most 64 arguments in 4 KB.
        guard launchArguments.utf8.count < 4096 else { throw LibraryError.message("The complete launch command is too long.") }
        guard !quoted, tokens <= 64 else { throw LibraryError.message("Use balanced double quotes and at most 64 launch arguments in total.") }
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
        // Unset unless chosen: FEX's own default then applies, as for any other launch.
        if reducedX87 { setenv("FEX_X87REDUCEDPRECISION", "1", 1) } else { unsetenv("FEX_X87REDUCEDPRECISION") }
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
        unsetenv("MADEIRA_STEAM_APPID"); unsetenv("MADEIRA_STEAM_APPPATH"); unsetenv("MADEIRA_WORKDIR")
        if steamAppID != nil {
            // A Steam game through Madeira Dock: Dock has set what starts (ContentView.startDock);
            // the virtual monitor follows this entry's Resolution, as below. "The game" starts
            // its own program below, like any library game.
            if !startsSteamGameDirectly {
                GuestDisplay.configureSessionDefault(view: CGSize(width: 1280, height: 720), knob: resolution)
                return
            }
        }
        let command = desktop == true ? (exe: "explorer.exe", args: launchArguments) : launchCommand
        setenv("MADEIRA_EXE", command.exe, 1)
        setenv("MADEIRA_ARGS", command.args, 1)
        if desktop == true || runsInDesktop { setenv("MADEIRA_DESKTOP", "1", 1) } else { unsetenv("MADEIRA_DESKTOP") }
        if startsSteamGameDirectly, let steamAppID {
            // The game's own Steam identity (SteamAppId, SteamGameId, SteamAppPath = its install
            // folder) instead of the bridge's fixed one.
            setenv("MADEIRA_STEAM_APPID", String(steamAppID), 1)
            setenv("MADEIRA_STEAM_APPPATH", windowsPath, 1)
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

final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var drive: URL { documents.appendingPathComponent("wine/drive_c", isDirectory: true).resolvingSymlinksInPath() }
    @Published var enabled = false
    @Published var entries: [LibraryEntry] = []
    @Published var current: UUID?
    @Published var activeEntry: LibraryEntry?
    @Published var menu = false
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
    /// The session's touch-control opacity (the entry's Control opacity).
    @Published var opacity = 0.7
    /// The session's Aspect & scaling; MetalBackedView lays the game out with it.
    @Published var displayMode = DisplayMode.fit {
        didSet { if displayMode != oldValue { MetalBackedView.refreshDisplayMode(reason: "mode-toggle") } }
    }
    @Published var error: String?
    @Published var sessionMessage = ""
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
    var blocksGameplayTouch: Bool { current != nil && (menu || launching) }
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
    private var readOnly = false
    private var metadataInFlight = Set<UUID>()
    private var steamMetadataInFlight = Set<Int>()
    private var savedControls: [TouchControl] = []
    private var savedLayout: String?
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
        // A Steam game has one entry: a details page opened before its card first saved
        // one (refreshSteamMetadata) updates that entry.
        if let i = next.firstIndex(where: { $0.id == entry.id }) ??
            next.firstIndex(where: { entry.steamAppID != nil && $0.steamAppID == entry.steamAppID }) ??
            next.firstIndex(where: { entry.epicAppName != nil && $0.epicAppName == entry.epicAppName }) {
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
    @discardableResult
    private func persist(_ next: [LibraryEntry]) -> Bool {
        guard !readOnly else { return false }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Document(version: 1, entries: next)).write(to: file, options: .atomic)
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
        updated.metadataChecked = Date(); updated.metadataRevision = revision; save(updated)
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
    static func executable(_ relative: String) throws -> URL {
        let url = drive.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(drive.path + "/"), programExtensions.contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.message("Choose an executable (.exe, .bat or .cmd) inside drive_c.")
        }
        return url
    }
    static func inspect(_ url: URL) throws -> LibraryEntry {
        guard url.resolvingSymlinksInPath().path.hasPrefix(drive.path + "/") else {
            throw LibraryError.message("The executable must be inside drive_c.")
        }
        if ["bat", "cmd"].contains(url.pathExtension.lowercased()) {
            // ml1163: a batch file has no PE header. Like every entry it starts
            // directly by default, as upstream starts every game; the details page
            // warns that Wine then stops when cmd.exe, its first process, exits.
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(drive.path.count + 1))
            return LibraryEntry(title: url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " "),
                                relativePath: relative, bits: 0)
        }
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        let dos = try h.read(upToCount: 64) ?? Data()
        guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { throw LibraryError.message("This is not a Windows executable.") }
        let offset = (0..<4).reduce(UInt64(0)) { $0 | (UInt64(dos[60 + $1]) << ($1 * 8)) }
        guard offset >= 64, offset < 16 * 1024 * 1024 else { throw LibraryError.message("Invalid executable header.") }
        try h.seek(toOffset: offset)
        let pe = try h.read(upToCount: 6) ?? Data()
        guard pe.count == 6, Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else { throw LibraryError.message("Missing PE header.") }
        let machine = Int(pe[4]) | Int(pe[5]) << 8
        guard machine == 0x14c || machine == 0x8664 else { throw LibraryError.message("Only x86 and x64 executables are supported.") }
        let relative = String(url.resolvingSymlinksInPath().path.dropFirst(drive.path.count + 1))
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
    static let restartMessage = "Restart Madeira to start another game: swipe Madeira away in the app switcher, then open it again."
    @Published var restartNotice: String?
    /// CS_DEBUGGED is set but no debugger is attached (JIT was enabled outside
    /// Madeira): the text of the alert that offers Madeira's own Enable JIT.
    @Published var jitNotice: String?
    /// Play is enabling JIT before starting this entry (ContentView.jitReadyForLaunch):
    /// its Play button reads Starting JIT, with a spinner, until JIT is on or fails.
    @Published var startingJIT: UUID?
    /// A Steam game's saves may not be the latest (SteamOwnedLibrary.cloudHold):
    /// the alert Play shows before starting it.
    struct CloudNotice: Equatable {
        enum Kind { case syncing, unchecked, conflict }
        var appID: Int
        var kind: Kind
        var title: String
        var message: String
    }
    @Published var cloudNotice: CloudNotice?
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
        quitRequested = false
        LibraryController.shared.configure(enabled: enabled, ownsInput: false)
        Self.sessionsThisRun += 1
        launchPresent = madeira_get_present_count(); launchStarted = Date(); launchSlow = false; launchLogs = entry.liveLogs
        launchSurface = winios_surface_present_count()
        MetalBackedView.presentCountAtLaunch = launchPresent; laidOutAfterFirstPresent = false
        launching = true; overlayFields = entry.overlayFields ?? ["FPS", "Frame time", "RAM", "Battery"]
        displayMode = entry.displayMode
        activeEntry = entry; current = entry.id; menu = false; performance = entry.performance; liveLogs = entry.liveLogs
        LogStore.shared.setDisplayActive(entry.liveLogs)
        fpsMode = entry.fpsMode; sessionMessage = "Starting…"
        opacity = min(max(entry.controlOpacity ?? 0.7, 0.15), 1)
        let controls = TouchControlsModel.shared
        savedControls = controls.controls; savedVisible = controls.visible; savedSize = controls.sizeScale
        savedLayout = controls.layoutID
        if let profile = entry.controls {
            controls.controls = profile
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
        MetalHostView.shared.isHidden = false
        ProMotionIntent.apply(mode: entry.effectiveFPSMode)
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
            dockStart.poll(self, rendered: madeira_get_present_count() >= launchPresent + 3)
        }
        if dockStart.holding {
            if launching && !launchSlow && Date().timeIntervalSince(launchStarted) > 30 { launchSlow = true }
        } else if launching {
            if madeira_get_present_count() >= launchPresent + 3 {
                showGameView(reason: "present")
            } else if winios_surface_present_count() > launchSurface {
                showGameView(reason: "surface")
            } else if Date().timeIntervalSince(launchStarted) > 30 { launchSlow = true }
        }
        if wine_process_is_running() != 0 {
            sawProcess = true
            if sessionMessage == "Starting…" { sessionMessage = "" }
        } else if sawProcess && wineserver_is_running() == 0 { finish() }
        // The first frame gives Aspect and Fill height the drawable's shape.
        if current != nil, !laidOutAfterFirstPresent, madeira_get_present_count() != MetalBackedView.presentCountAtLaunch {
            laidOutAfterFirstPresent = true
            MetalBackedView.refreshDisplayMode(reason: "first-present")
        }
    }
    /// `reason`: what stopped the launch, when the caller knows (the JIT pool's failure).
    /// `offerJIT`: the launch failed because no debugger is attached, so the alert
    /// offers Enable JIT instead of only reporting.
    func launchFailed(_ reason: String? = nil, offerJIT: Bool = false) {
        guard current != nil && !sawProcess else { return }
        finish()
        if offerJIT, let reason { jitNotice = reason }
        else { error = reason ?? "The session could not start. Check the diagnostic log and JIT status." }
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
    func requestQuit() {
        LibraryKeyboard.hide()
        quitRequested = true
        // Ask the application to close (Alt+F4) through the normal input queue,
        // so it can save; the surface stays up until the native session ends.
        winios_post_key(0x12, 1); winios_post_key(0x73, 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            winios_post_key(0x73, 0); winios_post_key(0x12, 0)
        }
        sessionMessage = "Close requested. Confirm any in-game exit dialog."
        menu = false
        fputs("[frontend] graceful close requested\n", stderr)
    }
    func saveCurrentProfile() {
        let controls = TouchControlsModel.shared
        if let id = current, var entry = entries.first(where: { $0.id == id }) {
            entry.controls = controls.controls
            if ControlPresetsModel.enabled { entry.controlLayout = controls.layoutID }
            entry.touchControls = controls.visible
            entry.fpsMode = fpsMode; entry.performance = performance
            entry.overlayFields = overlayFields
            entry.controlOpacity = opacity; entry.controlSize = controls.sizeScale
            if GamepadInput.keyboardMouseAvailable { entry.controllerMode = controllerMode }
            if GamepadInput.keyboardMouseAvailable { entry.controllerBinds = controllerBinds.isEmpty ? nil : controllerBinds }
            if GamepadInput.keyboardMouseAvailable { entry.padMouseVertical = padMouseVertical == 1 ? nil : padMouseVertical }
            // The in-game Aspect & scaling choice sticks to the game. MADEIRA_SESSION_TOOLS=0
            // hides that picker and leaves the stored choice alone.
            if MadeiraConfig.flag("MADEIRA_SESSION_TOOLS") { entry.display = displayMode.rawValue }
            save(entry)
        }
    }
    private func finish() {
        if sawProcess, let report = exitReport() { error = report }
        timer?.invalidate(); timer = nil
        saveCurrentProfile()
        controllerMode = nil
        controllerBinds = [:]
        padMouseVertical = 1
        let controls = TouchControlsModel.shared
        controls.editing = false; controls.selected = nil
        controls.controls = savedControls; controls.visible = savedVisible; controls.sizeScale = savedSize
        if ControlPresetsModel.enabled { controls.layoutID = savedLayout }
        current = nil; activeEntry = nil; menu = false; sessionMessage = ""
        displayMode = .fit
        LogStore.shared.setDisplayActive(true)
        launching = false; launchLogs = false; LibraryKeyboard.hide()
        DockStartScreen.shared.finish()
        LibraryController.shared.configure(enabled: enabled, ownsInput: enabled)
        MetalHostView.shared.isHidden = true
        ProMotionIntent.shared.setActive(false)
        fputs("[frontend] returned to library\n", stderr)
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

enum LibraryRendererBadge {
    static let apis = ["D3D12", "D3D11", "D3D10", "D3D9", "D3D8", "Vulkan", "OpenGL", "DirectDraw"]

    /// The badge names an API only when the game's files name exactly one. The
    /// scan finds every renderer a game ships, not the one it runs: an engine
    /// with D3D9 and D3D10 renderers would otherwise be labelled D3D10.
    static func compact(_ detected: String?) -> String? {
        guard let detected else { return nil }
        // "D3D10/D3D9" from the metadata scan, "D3D10 / D3D9" from inspect.
        let values = Set(detected.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) })
        let known = apis.filter(values.contains)
        if known.count == 1 { return known[0] }
        return known.isEmpty && !detected.contains("/") ? detected : nil   // e.g. "Wine desktop"
    }
}

/// "Madeira" as a large title at the leading edge of the navigation bar, on the
/// row of the toolbar buttons (the system large title would sit on a row of its
/// own below them), in the large title font, with no Liquid Glass capsule
/// behind it on iOS 26. LibraryHeaderAlignment lines its first letter up with
/// the search field below.
struct LibraryLargeTitle: ToolbarContent {
    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { LibraryTitleText() }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { LibraryTitleText() }
        }
    }
}

/// The title, then a bolt for JIT: a thin outline in the title's colour until
/// the debugger is attached, then filled in the accent colour (LibraryJITState;
/// the SF Symbols replace effect animates the change).
/// The bolt is as tall as the title's capitals and centred on them: an SF
/// Symbol at the title's own size is nearly twice the height of its M.
struct LibraryTitleText: View {
    @ObservedObject private var alignment = LibraryHeaderAlignment.shared
    @ObservedObject private var jitState = LibraryJITState.shared
    var body: some View {
        let jit = jitState.enabled
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LibraryHeaderAlignment.title).accessibilityAddTraits(.isHeader)
            Image(systemName: jit ? "bolt.fill" : "bolt")
                .font(.system(size: LibraryHeaderAlignment.titleFont().pointSize * 0.53, weight: .thin))
                .foregroundStyle(jit ? Color.accentColor : Color.primary)
                .contentTransition(.symbolEffect(.replace))
                .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + LibraryHeaderAlignment.titleFont().capHeight / 2 }
                .accessibilityLabel(jit ? "JIT enabled" : "JIT not enabled")
        }
        .font(.largeTitle.bold())
        .fixedSize()
        .offset(x: alignment.shift)
        .background(LibraryTitleAnchor())   // after the offset: marks where the text is laid out
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

/// Lines the large title's first letter up with the search field below it. The
/// navigation bar's leading inset differs between iOS versions (the title sat
/// 4 pt inside the field on iOS 26.2 and level with its edge on iOS 27, before
/// the glyph's own side bearing), so the offset is measured: the field's leading
/// edge and the title's frame, both in window coordinates, less the side
/// bearing of the title's first glyph. Checked in the iOS 26.2 and iOS 27
/// simulators: the M starts on the field's edge to the pixel on both.
final class LibraryHeaderAlignment: ObservableObject {
    static let shared = LibraryHeaderAlignment()
    static let title = "Madeira"
    @Published private(set) var shift: CGFloat = 0
    weak var field: UIView?
    weak var anchor: UIView?
    private var pending = false

    /// Called from layout passes; measures once they have finished, when the
    /// search field and the title are both at their final positions.
    func update() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { self.pending = false; self.measure(retries: 0) }
    }
    private func measure(retries: Int) {
        guard let field, let anchor, let window = field.window, anchor.window === window else { return }
        guard field.bounds.width > 0, anchor.bounds.width > 0 else {   // not laid out yet
            if retries < 20 { DispatchQueue.main.async { self.measure(retries: retries + 1) } }
            return
        }
        let fieldX = field.convert(field.bounds, to: nil).minX
        let titleX = anchor.convert(anchor.bounds, to: nil).minX
        let scale = window.screen.scale
        let target = ((fieldX - titleX - Self.inkInset()) * scale).rounded() / scale
        if abs(target - shift) > 0.01 { shift = target }
    }

    /// The title's font: the large title style, bold, at the current text size.
    static func titleFont() -> UIFont {
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .largeTitle)
        return UIFont(descriptor: base.withSymbolicTraits(.traitBold) ?? base, size: 0)
    }

    /// How far the first glyph's ink starts right of the text's origin, in the
    /// title's font.
    static func inkInset() -> CGFloat {
        let font = titleFont() as CTFont
        guard var unit = title.utf16.first else { return 0 }
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1) else { return 0 }
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &rect, 1)
        return rect.minX
    }
}

/// Marks where the title's text is laid out (before its alignment offset).
struct LibraryTitleAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) {}
    final class Anchor: UIView {
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        private func report() {
            guard window != nil else { return }
            LibraryHeaderAlignment.shared.anchor = self
            LibraryHeaderAlignment.shared.update()
        }
    }
}

/// A search controller whose bar reports its layout to LibraryHeaderAlignment.
final class ReportingSearchController: UISearchController {
    private lazy var reportingBar = ReportingSearchBar()
    override var searchBar: UISearchBar { reportingBar }
}
final class ReportingSearchBar: UISearchBar {
    override func layoutSubviews() {
        super.layoutSubviews()
        LibraryHeaderAlignment.shared.field = searchTextField
        LibraryHeaderAlignment.shared.update()
    }
}

/// The library's search field: the system search bar (Liquid Glass on iOS 26),
/// stacked under the navigation bar at full width, with the Madeira title and
/// the toolbar buttons on the row above it. A UISearchController on the
/// NavigationStack's own navigation item: `.searchable` shows nothing here (the
/// TabView sits inside the NavigationStack). Removed again when the library
/// goes away, so the developer screen has no search bar. Checked in the iOS
/// simulator: the title and the toolbar buttons share a centre line, and the
/// field spans the screen on both tabs.
struct LibraryNavSearch: UIViewControllerRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        host.coordinator = context.coordinator
        return host
    }
    func updateUIViewController(_ host: Host, context: Context) {
        context.coordinator.parent = self
        host.apply()
        // SwiftUI rebuilds the navigation item when the toolbar changes (the
        // library's buttons leave with the Settings tab) and can drop the search
        // controller on the way; put it back once that update has landed.
        DispatchQueue.main.async { host.apply() }
    }
    static func dismantleUIViewController(_ host: Host, coordinator: Coordinator) { host.remove() }

    final class Coordinator: NSObject, UISearchResultsUpdating, UISearchBarDelegate, UIGestureRecognizerDelegate {
        var parent: LibraryNavSearch
        let controller = ReportingSearchController(searchResultsController: nil)
        private var outsideTap: UITapGestureRecognizer?
        var bar: UISearchBar { controller.searchBar }

        init(_ parent: LibraryNavSearch) {
            self.parent = parent
            super.init()
            controller.obscuresBackgroundDuringPresentation = false
            controller.hidesNavigationBarDuringPresentation = false
            controller.searchResultsUpdater = self
            bar.delegate = self
            bar.autocapitalizationType = .none
            bar.autocorrectionType = .no
            bar.returnKeyType = .search
        }
        func updateSearchResults(for searchController: UISearchController) {
            let t = searchController.searchBar.text ?? ""
            if t != parent.text { parent.text = t }
        }
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }

        // While the field is being edited, any tap outside it closes the keyboard.
        // The tap still reaches whatever was tapped (cancelsTouchesInView = false).
        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            guard outsideTap == nil, let window = searchBar.window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tappedOutside))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            outsideTap = tap
        }
        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            if let tap = outsideTap { tap.view?.removeGestureRecognizer(tap) }
            outsideTap = nil
        }
        @objc private func tappedOutside() { bar.resignFirstResponder() }

        /// A tab switch squeezes the field a little and lets it spring back, like
        /// a Liquid Glass control answering a touch (there is no public call that
        /// plays the glass's own touch response). The system spring, on the bar's
        /// layer only, so the navigation bar's layout never sees a transform.
        /// Checked in the iOS 27 simulator (at 4%; now 1.5%): in, a slight overshoot,
        /// settled in about half a second, running alongside the toolbar's glass morph.
        func squeeze() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let layer = bar.layer
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            let squeezed = 0.985, inTime = 0.12
            let back = CASpringAnimation(perceptualDuration: 0.5, bounce: 0.5)
            back.keyPath = "transform.scale"
            back.fromValue = squeezed
            back.toValue = 1
            back.beginTime = now + inTime
            back.duration = back.settlingDuration
            back.fillMode = .backwards   // holds the squeezed size until it starts
            let inward = CABasicAnimation(keyPath: "transform.scale")
            inward.fromValue = 1
            inward.toValue = squeezed
            inward.beginTime = now
            inward.duration = inTime
            inward.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(back, forKey: "madeira.search.squeeze.back")
            layer.add(inward, forKey: "madeira.search.squeeze.in")   // added last: shown over the held spring
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !(touch.view?.isDescendant(of: bar) ?? false)
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    final class Host: UIViewController {
        weak var coordinator: Coordinator?
        private weak var owner: UIViewController?
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); apply() }

        func apply() {
            guard let c = coordinator else { return }
            if c.bar.text != c.parent.text { c.bar.text = c.parent.text }
            if c.bar.placeholder != c.parent.placeholder {
                if c.bar.placeholder != nil {   // a tab switch: crossfade instead of jumping
                    let fade = CATransition(); fade.type = .fade; fade.duration = 0.25
                    c.bar.searchTextField.layer.add(fade, forKey: "madeira.search.fade")
                    c.squeeze()
                }
                c.bar.placeholder = c.parent.placeholder
            }
            // The NavigationStack's own view controller owns the navigation item.
            var vc: UIViewController? = self
            while let v = vc, !(v.parent is UINavigationController) { vc = v.parent }
            guard let target = vc else { return }
            owner = target
            let item = target.navigationItem
            if item.searchController !== c.controller { item.searchController = c.controller }
            if item.preferredSearchBarPlacement != .stacked { item.preferredSearchBarPlacement = .stacked }
            if item.hidesSearchBarWhenScrolling { item.hidesSearchBarWhenScrolling = false }
            // iOS 26 otherwise moves it to the bottom of an iPhone screen, beside the tab bar.
            if #available(iOS 26.0, *), item.searchBarPlacementAllowsToolbarIntegration {
                item.searchBarPlacementAllowsToolbarIntegration = false
            }
        }
        func remove() {
            coordinator?.bar.resignFirstResponder()
            if let owner, owner.navigationItem.searchController === coordinator?.controller { owner.navigationItem.searchController = nil }
        }
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
        GeometryReader { geometry in
        ZStack {
            Color(uiColor: .secondarySystemFill)
            Image(systemName: entry.desktop == true ? "desktopcomputer" : "gamecontroller.fill").font(.largeTitle).foregroundStyle(.secondary)
            if let name = entry.coverFile,
               let image = UIImage(contentsOfFile: LibraryModel.documents.appendingPathComponent("madeira-art/" + URL(fileURLWithPath: name).lastPathComponent).path) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center).clipped()
            } else if let url = backdrop ? (entry.epicHeroURL ?? entry.epicArtworkURL) : entry.epicArtworkURL {
                EpicArtwork(url: url)
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

/// A pseudo-random sequence from a seed (SplitMix64), so each card's "movie" is its own
/// but stays the same for the whole run.
struct AmbientRandom {
    private var state: UInt64
    init(seed: Int) { state = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

/// The light a TV's ambient LED strip throws on the wall as a film plays, for a still
/// piece of artwork, sampled around the ring of light (`samples` points, clockwise).
///
/// - Brightness: arcs of the ring flare up or fall into shadow independently, each at
///   its own place, width and strength, rising (sometimes at once, like a cut),
///   drifting and fading over two to six seconds; six at a time, a third of them
///   shadows, over a moderate base level, so the ring is never lit uniformly.
/// - Colour: the ring's colours travel. Two soft zones sweep around it, one showing
///   the artwork turned half round (its colours from the opposite side), one showing it
///   mirrored (left and right swapped), and at each scene cut they jump and change
///   strength; the whole light also drifts slightly in hue.
struct AmbientMovie {
    static let samples = 36
    struct Frame {
        var hue: Double
        var light: [Double]
        var turned: [Double]
        var mirrored: [Double]
    }
    private struct Scene { var length, level, hue, turned, turnedShift, mirrored, mirroredShift: Double }
    private struct Slot { var period, offset: Double }
    private let seed: Int
    private let scenes: [Scene]
    private let slots: [Slot]
    private let total: Double
    private let phase: Double
    private let turnSpeed: Double
    private let mirrorSpeed: Double

    init(seed: Int) {
        var r = AmbientRandom(seed: seed)
        var scenes: [Scene] = []
        for _ in 0..<12 {
            scenes.append(Scene(length: 3.2 + r.unit() * 5.0, level: 0.45 + r.unit() * 0.3, hue: (r.unit() - 0.5) * 24,
                                turned: 0.1 + r.unit() * 0.5, turnedShift: r.unit() * 2 * .pi,
                                mirrored: 0.1 + r.unit() * 0.45, mirroredShift: r.unit() * 2 * .pi))
        }
        self.scenes = scenes
        slots = (0..<6).map { _ in Slot(period: 2.0 + r.unit() * 4.5, offset: r.unit() * 10) }
        total = scenes.reduce(0) { $0 + $1.length }
        phase = r.unit() * total
        turnSpeed = (r.unit() < 0.5 ? -1 : 1) * (0.12 + r.unit() * 0.23)
        mirrorSpeed = (r.unit() < 0.5 ? -1 : 1) * (0.1 + r.unit() * 0.2)
        self.seed = seed
    }

    /// One flare or shadow on the ring, for one life of its slot.
    private func event(slot: Int, life: Int) -> (center: Double, width: Double, amount: Double, drift: Double, rise: Double) {
        var r = AmbientRandom(seed: seed &* 1_000_003 &+ slot &* 7_919 &+ life)
        let center = r.unit() * 2 * .pi
        let width = 0.25 + r.unit() * 1.5
        let amount = r.unit() < 0.35 ? -(0.2 + r.unit() * 0.3) : 0.3 + r.unit() * 0.5
        return (center, width, amount, (r.unit() - 0.5) * 1.4, 0.04 + r.unit() * 0.3)
    }

    func frame(at time: Double) -> Frame {
        let t = (time + phase).truncatingRemainder(dividingBy: total)
        var start = 0.0, i = 0
        while i < scenes.count - 1 && start + scenes[i].length <= t { start += scenes[i].length; i += 1 }
        let now = scenes[i], before = scenes[(i + scenes.count - 1) % scenes.count]
        let x = min(1, (t - start) / 0.4)            // a scene cut, eased over 0.4 s
        let k = x * x * (3 - 2 * x)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        func mixAngle(_ a: Double, _ b: Double) -> Double { a + remainder(b - a, 2 * .pi) * k }
        let p = phase
        let level = mix(before.level, now.level) + 0.035 * sin(time * 1.7 + p) + 0.025 * sin(time * 3.9 + p * 1.9)
        let hue = mix(before.hue, now.hue) + 3 * sin(time * 0.35 + p)
        let turnedAt = mixAngle(before.turnedShift, now.turnedShift) + turnSpeed * time
        let mirroredAt = mixAngle(before.mirroredShift, now.mirroredShift) + mirrorSpeed * time
        let turnedStrength = mix(before.turned, now.turned), mirroredStrength = mix(before.mirrored, now.mirrored)

        var bumps: [(center: Double, width: Double, amount: Double)] = []
        for (n, slot) in slots.enumerated() {
            let lives = (time + slot.offset) / slot.period
            let f = lives - lives.rounded(.down)
            let e = event(slot: n, life: Int(lives.rounded(.down)))
            let env: Double
            if f < e.rise { let y = f / e.rise; env = y * y * (3 - 2 * y) }
            else { env = pow(1 - (f - e.rise) / (1 - e.rise), 1.6) }
            bumps.append((e.center + e.drift * f, e.width, e.amount * env))
        }

        let n = Self.samples
        var light = [Double](repeating: 0, count: n), turned = light, mirrored = light
        for s in 0..<n {
            let a = Double(s) / Double(n) * 2 * .pi
            var v = level
            for b in bumps {
                let d = remainder(a - b.center, 2 * .pi), sigma = b.width / 2
                v += b.amount * exp(-(d * d) / (2 * sigma * sigma))
            }
            light[s] = max(0.12, min(1, v))
            turned[s] = turnedStrength * pow(0.5 + 0.5 * cos(a - turnedAt), 2)
            mirrored[s] = mirroredStrength * pow(0.5 + 0.5 * cos(2 * (a - mirroredAt)), 2)
        }
        return Frame(hue: hue, light: light, turned: turned, mirrored: mirrored)
    }

    /// Values around the ring as an angular mask, closed at the seam.
    static func mask(_ values: [Double]) -> AngularGradient {
        var stops = values.enumerated().map { Gradient.Stop(color: .black.opacity($1), location: Double($0) / Double(values.count)) }
        stops.append(.init(color: .black.opacity(values[0]), location: 1))
        return AngularGradient(stops: stops, center: .center)
    }
}

/// The faint rays in a card's light: beams fanning out from the artwork's centre,
/// each its own width and brightness (seeded, so a card keeps its own). Subtle on
/// purpose: the gaps between them stay nearly as bright as the beams, and they are
/// softened, so the glow reads as light with a little texture, not as stripes.
struct AmbientRays: View {
    let seed: Int
    /// Degrees the beams are turned by; the glow sways them slowly.
    var turn: Double = 0
    /// The same beams, crisp and contrasty: the light focused down while its card is pressed.
    var sharp = false
    private static let count = 60

    var body: some View {
        let floor = sharp ? 0.1 : 0.72
        var r = AmbientRandom(seed: seed &* 31 &+ 7)
        var stops: [Gradient.Stop] = []
        var at = 0.0
        while at < 1 {
            let width = (0.5 + r.unit()) / Double(Self.count)
            let level = floor + (1 - floor) * pow(r.unit(), 0.7)
            stops.append(.init(color: .black.opacity(level), location: at))
            stops.append(.init(color: .black.opacity(level), location: min(1, at + width * 0.55)))
            at += width
        }
        stops.append(.init(color: stops[0].color, location: 1))
        return AngularGradient(stops: stops, center: .center, angle: .degrees(turn))
            .blur(radius: sharp ? 0.6 : 3)
    }
}

/// Ambient light around a card's artwork, as an LED strip behind a TV lights the wall:
/// the artwork itself, a little larger and blurred, so each edge's colours spill from
/// that edge. Three versions of it are drawn once each (drawingGroup): as it is, turned
/// half round, and mirrored, which have the same outline but the colours in other
/// places; AmbientMovie blends them around the ring and lights arcs of it, and only
/// those masks, a slight hue drift and the rays' sway move, at 30 frames a second.
/// Dark appearance adds the light (plusLighter), as light does on a dark wall; light
/// appearance tints more softly. Reduce Motion holds it still.
struct AmbientGlow: View {
    let image: Image
    let size: CGSize
    let seed: Int
    var dimmed = false
    /// The card is pressed: the light closes like a spotlight's aperture, drawing in
    /// toward the artwork with its rays turning crisp, and goes out behind the shrunken
    /// artwork; on release it opens back up slowly.
    var pressed = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func layer(_ angle: Double, _ mirror: Bool, frame: CGSize) -> some View {
        func art() -> some View {
            image.resizable().scaledToFill()
                .frame(width: size.width, height: size.height).clipped()
                .rotationEffect(.degrees(angle))
                .scaleEffect(x: mirror ? -1 : 1, y: 1)
        }
        // A soft wash on the wall, and the brighter band just past the edge where the
        // strip's light lands first.
        return ZStack {
            art().scaleEffect(1.09).blur(radius: size.width * 0.07)
            art().scaleEffect(1.03).blur(radius: size.width * 0.03).opacity(0.75)
        }
        .frame(width: frame.width, height: frame.height)
        // On a light page the blurred art's mid-tones read as grey: lifted and more
        // vivid there, it reads as coloured light.
        .saturation(dimmed ? 1.15 : (scheme == .dark ? 1.5 : 1.9))
        .brightness(scheme == .dark ? 0 : (dimmed ? 0.04 : 0.12))
        .drawingGroup()
    }

    var body: some View {
        // Kept tight, so neighbouring cards' light stays apart in the gaps between them.
        let spread = size.width * 0.17
        let frame = CGSize(width: size.width + spread * 2, height: size.height + spread * 2)
        let movie = AmbientMovie(seed: seed)
        let dark = scheme == .dark
        // A game that is not installed throws a fainter, less vivid light.
        let strength = (dark ? 0.92 : 0.8) * (dimmed ? 0.3 : 1)
        let plain = layer(0, false, frame: frame), turned = layer(180, false, frame: frame), mirrored = layer(0, true, frame: frame)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let f = movie.frame(at: reduceMotion ? 0 : t)
            ZStack {
                plain
                turned.mask { AmbientMovie.mask(f.turned) }
                mirrored.mask { AmbientMovie.mask(f.mirrored) }
            }
            .compositingGroup()
            .hueRotation(.degrees(f.hue))
            // In the dark the light adds to the page (plusLighter): a very bright artwork's
            // light is brought down at the top (AmbientGlow.metal) so it does not glare.
            // ml1219: off on a light page, where a knee of 0 left every pixel as it was.
            .colorEffect(ShaderLibrary.ambientKnee(.float(0.3)), isEnabled: dark)
            .mask { AmbientMovie.mask(f.light) }
            .mask {
                let turn = reduceMotion ? 0 : 1.2 * sin(t * 0.12 + Double(seed % 97))
                ZStack {
                    AmbientRays(seed: seed, turn: turn).opacity(pressed ? 0 : 1)
                    AmbientRays(seed: seed, turn: turn, sharp: true).opacity(pressed ? 1 : 0)
                }
                // The rays sharpen first, then the light draws in and goes out.
                .animation(pressed ? .easeOut(duration: 0.2) : .easeIn(duration: 0.9), value: pressed)
            }
            // Closed, the light's outer edge sits inside the shrunken artwork.
            .scaleEffect(pressed ? LibraryCardArtworkPress.pressedScale * size.width / frame.width : 1)
            .animation(pressed ? .easeInOut(duration: 0.55) : .easeInOut(duration: 1.6), value: pressed)
            .opacity(strength * (pressed ? 0 : 1))
            .animation(pressed ? .easeIn(duration: 0.6) : .easeOut(duration: 1.3), value: pressed)
            .blendMode(dark ? .plusLighter : .normal)
        }
        .frame(width: frame.width, height: frame.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What a card's glow is made of: the same artwork the card shows.
enum AmbientArt {
    case steam(Int)
    case library(LibraryEntry)
    /// An Epic game's box art (Epic/EpicLibraryViews.swift).
    case epic(URL?)
}

/// A grid card's artwork frame and what its glow is made of, reported up to the
/// library, which draws every glow in one layer behind all the cards
/// (AmbientGlowLayer): a card's own background would be painted over its
/// neighbours by the cards after it.
struct AmbientGlowItem: Identifiable {
    let id: String
    let seed: Int
    let art: AmbientArt
    var dimmed = false
    var pressed = false
    let bounds: Anchor<CGRect>
}

struct AmbientGlowKey: PreferenceKey {
    static let defaultValue: [AmbientGlowItem] = []
    static func reduce(value: inout [AmbientGlowItem], nextValue: () -> [AmbientGlowItem]) { value += nextValue() }
}

/// The library's ambient light: a glow behind every grid card that has reported
/// its frame (only the cards the lazy grids have built). MADEIRA_LIBRARY_AMBIENT=0
/// turns it off.
struct AmbientGlowLayer: View {
    static let enabled = MadeiraConfig.flag("MADEIRA_LIBRARY_AMBIENT")
    let items: [AmbientGlowItem]
    var body: some View {
        if Self.enabled {
            GeometryReader { proxy in
                var seen = Set<String>()
                let unique = items.filter { seen.insert($0.id).inserted }
                ForEach(unique) { item in AmbientGlowCard(item: item, frame: proxy[item.bounds]) }
            }
        }
    }
}

/// One card's glow, once its artwork is loaded.
private struct AmbientGlowCard: View {
    let item: AmbientGlowItem
    let frame: CGRect
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let image = image ?? AmbientArtwork.cached(item.id) {
                AmbientGlow(image: Image(uiImage: image), size: frame.size, seed: item.seed, dimmed: item.dimmed, pressed: item.pressed)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .position(x: frame.midX, y: frame.midY)
        .task(id: item.id) { if image == nil { image = await AmbientArtwork.load(item) } }
    }
}

/// A card's artwork for its glow: loaded once, shrunk (the glow blurs it anyway) and
/// kept, so the glow's three layers share one small bitmap instead of each decoding
/// the full artwork.
@MainActor
enum AmbientArtwork {
    private static let cache = NSCache<NSString, UIImage>()

    static func cached(_ id: String) -> UIImage? { cache.object(forKey: id as NSString) }

    static func load(_ item: AmbientGlowItem) async -> UIImage? {
        if let hit = cached(item.id) { return hit }
        var image: UIImage?
        switch item.art {
        case .steam(let appID):
            for url in SteamGamesRules.artwork(appID: appID, owned: { SteamOwnedLibrary.shared.game($0) }) {
                if let found = await fetch(url) { image = found; break }
            }
        case .library(let entry):
            if let name = entry.coverFile {
                image = UIImage(contentsOfFile: LibraryModel.documents
                    .appendingPathComponent("madeira-art/" + URL(fileURLWithPath: name).lastPathComponent).path)
            } else if let url = entry.epicArtworkURL {
                image = await fetch(url)
            } else if let id = entry.steamID ?? entry.steamAppID, let url = SteamCatalog.cover(id) {
                image = await fetch(url)
            }
        case .epic(let url):
            if let url { image = await fetch(url) }
        }
        guard let image, image.size.width > 0 else { return nil }
        let size = CGSize(width: 96, height: (96 * image.size.height / image.size.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        cache.setObject(small, forKey: item.id as NSString)
        return small
    }

    private static func fetch(_ url: URL) async -> UIImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: data)
    }
}

/// Whether the app's liquid metal is on: Settings › Appearance › Liquid metal, kept in
/// madeira.cfg as env.MADEIRA_LIQUID_METAL (off, plain Liquid Glass, unless it is 1). It
/// covers the Desktop button's fill (LiquidMetalFill) and the bars' glass (GlassSkin), and
/// applies at once, fading between the two.
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

/// A flowing liquid-chrome fill (LiquidMetal.metal, a SwiftUI color shader): white
/// highlights, silver and navy, rainbow dispersion at the highlights' edges and a raised
/// rim, in a capsule (a rounded box of radius half its height). Animated at 60 frames a
/// second; held still with Reduce Motion. Its callers draw their previous fill when liquid
/// metal is off (LiquidMetalSetting).
struct LiquidMetalFill: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
                // Kept small, so the shader's float time stays precise.
                let time = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
                Rectangle()
                    .colorEffect(ShaderLibrary.liquidMetal(.float2(geometry.size), .float(reduceMotion ? 0 : time),
                                                           .float(Float(displayScale)), .float(scheme == .light ? 1 : 0)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
/// press (LibraryCardArtworkPress) and its ambient light closes around it.
struct LibraryCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.libraryCardPressed, configuration.isPressed)
    }
}

extension View {
    /// A library card's button style: a grid card shows its press on its artwork
    /// (LibraryCardButtonStyle); a list row keeps the plain style.
    @ViewBuilder func libraryCardButtonStyle(grid: Bool) -> some View {
        if grid { buttonStyle(LibraryCardButtonStyle()) } else { buttonStyle(.plain) }
    }
}

/// A grid card's artwork: shrinks while its card is pressed and springs back on
/// release, and reports its frame (unscaled) and its press to the library's ambient
/// light (AmbientGlowLayer).
struct LibraryCardArtworkPress: ViewModifier {
    static let pressedScale: CGFloat = 0.94
    @Environment(\.libraryCardPressed) private var pressed
    let glow: (_ pressed: Bool, _ bounds: Anchor<CGRect>) -> AmbientGlowItem
    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? Self.pressedScale : 1)
            .animation(pressed ? .spring(response: 0.26, dampingFraction: 0.86) : .spring(response: 0.42, dampingFraction: 0.58),
                       value: pressed)
            .anchorPreference(key: AmbientGlowKey.self, value: .bounds) { [glow(pressed, $0)] }
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
            if entry.bits == 32 || entry.bits == 64 { badge("\(entry.bits)-bit") }
            if entry.isBatch { badge("Batch") }   // ml1163
            if let api = LibraryRendererBadge.compact(entry.graphicsAPI) { badge(api) }
            if let note { badge(note) }
        }
    }
    @ViewBuilder private var size: some View {
        if let bytes = entry.folderBytes { badge(String(format: bytes < 1_000_000_000 ? "%.2f GB" : "%.1f GB", Double(bytes) / 1_000_000_000)) }
    }
    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 5).padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// JIT and Memory+ at the top of Settings, each with a green check or a red cross (the
/// developer interface's badges), and "Ready to play" beside them once both are there.
/// Checked every 2 s.
struct LibraryStatus: View {
    @State private var jit = false
    @State private var memory = false
    let ticks = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 8) {
            badge("JIT", jit)
            badge("Memory+", memory)
            if jit && memory {
                Text("Ready to play").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
        .onAppear { update() }.onReceive(ticks) { _ in update() }
    }
    private func badge(_ label: String, _ enabled: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(enabled ? Color.green : Color.red)
            Text(label).foregroundStyle(enabled ? .primary : .secondary)
        }
        .font(.footnote)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background((enabled ? Color.green : Color.red).opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore).accessibilityLabel("\(label): \(enabled ? "enabled" : "unavailable")")
    }
    private func update() { jit = StikJITHelper.ready; memory = EntitlementStatus.check().increasedMemory }
}

/// A section title with a count; with `collapsed` set, tapping the title
/// collapses or expands the section (the state is the caller's, persisted).
struct LibrarySectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    var collapsed: Binding<Bool>? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        if let collapsed {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) { collapsed.wrappedValue.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title).font(.title2.bold())
                        if let count, count > 0 { Text("\(count)").font(.subheadline).foregroundStyle(.secondary) }
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapsed.wrappedValue ? 0 : 90))
                    }.contentShape(Rectangle()).frame(minHeight: 44)
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityValue(collapsed.wrappedValue ? "Collapsed" : "Expanded")
                Spacer()
                trailing
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.bold())
                if let count, count > 0 { Text("\(count)").font(.subheadline).foregroundStyle(.secondary) }
                Spacer()
                trailing
            }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
        }
    }
}

/// A section's cards or rows in the library's layout ("cards", "compact",
/// "list" or "compactList"): every section of the library page uses it.
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

// MARK: - Group by rules (Foundation only; tests/host/check-library-groups.py compiles this part)

/// The library's Group by choice: "platform" is the sections (LibraryView);
/// "played" groups by when a game was last played, "installed" into Installed
/// and Not installed, and "none" is one grid. Those three list the games you
/// added and Steam's games together, each group in the library's Sort by order.
enum LibraryGrouping {
    enum Source: Hashable {
        case entry(UUID), steam(Int)
        var key: String {
            switch self {
            case .entry(let id): return "entry:" + id.uuidString
            case .steam(let appID): return "steam:\(appID)"
            }
        }
    }

    /// One game of any source, as far as the groups and the sort need it.
    struct Game: Identifiable, Equatable {
        let source: Source
        var title: String
        /// On disk; a Steam game being downloaded counts, as under the Steam title.
        var installed: Bool
        var lastPlayed: Date?
        var bytes: Int64?
        /// Its library entry's place in the library file (later is newer); nil without one.
        var position: Int?
        var id: Source { source }
    }

    struct Group: Identifiable, Equatable {
        let id: String
        /// nil: no header (Group by None).
        let title: String?
        var games: [Game]
    }

    /// Sort by ("played", "name", "added" or "size") as the library sorts the games
    /// you added: a game without a library entry sorts as never played, of unknown
    /// size and, for "added", after the games that have one; ties go by name.
    static func sorted(_ games: [Game], by sort: String) -> [Game] {
        games.sorted { a, b in
            switch sort {
            case "played":
                if a.lastPlayed != b.lastPlayed { return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast) }
            case "added":
                if a.position != b.position { return (a.position ?? -1) > (b.position ?? -1) }
            case "size":
                if a.bytes != b.bytes { return (a.bytes ?? -1) > (b.bytes ?? -1) }
            default:
                break
            }
            let order = a.title.localizedStandardCompare(b.title)
            return order == .orderedSame ? a.source.key < b.source.key : order == .orderedAscending
        }
    }

    /// The groups of a Group by choice other than "platform", in page order,
    /// without empty ones. Last played: today, the past 7 and 30 days (counted
    /// from the start of today), earlier, then never played.
    static func groups(_ games: [Game], by grouping: String, sort: String,
                       now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let games = sorted(games, by: sort)
        var groups: [Group]
        switch grouping {
        case "played":
            let today = calendar.startOfDay(for: now)
            let week = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            let month = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            groups = [Group(id: "today", title: "Today", games: []), Group(id: "week", title: "Past 7 days", games: []),
                      Group(id: "month", title: "Past 30 days", games: []), Group(id: "earlier", title: "Earlier", games: []),
                      Group(id: "never", title: "Never played", games: [])]
            for game in games {
                let index: Int
                if let played = game.lastPlayed {
                    index = played >= today ? 0 : played >= week ? 1 : played >= month ? 2 : 3
                } else {
                    index = 4
                }
                groups[index].games.append(game)
            }
        case "installed":
            groups = [Group(id: "installed", title: "Installed", games: games.filter(\.installed)),
                      Group(id: "notInstalled", title: "Not installed", games: games.filter { !$0.installed })]
        default:
            groups = [Group(id: "all", title: nil, games: games)]
        }
        return groups.filter { !$0.games.isEmpty }
    }

    /// The collapsed groups' ids, stored comma-separated ("played.today,installed.notInstalled").
    static func collapsed(_ stored: String) -> Set<String> {
        Set(stored.split(separator: ",").map(String.init))
    }

    static func storing(_ collapsed: Set<String>) -> String { collapsed.sorted().joined(separator: ",") }
}

// MARK: - Group by view

extension LibraryGrouping.Game {
    /// A game you added; `position` is its index in LibraryModel.entries.
    init(entry: LibraryEntry, position: Int) {
        self.init(source: .entry(entry.id), title: entry.title, installed: true,
                  lastPlayed: entry.lastPlayed, bytes: entry.folderBytes, position: position)
    }
}

/// The library page under a Group by other than Platform: the games you added
/// and Steam's games in one set of groups (LibraryGrouping). A card opens as in
/// its own section: a game you added or an installed Steam game its Game details
/// page, any other Steam game its download sheet. Not installed Steam games are
/// listed only while signed in.
struct LibraryGroupedGames<LocalCell: View>: View {
    let grouping: String
    let search: String
    var layout = "cards"
    var sort = "played"
    var width: CGFloat = 390
    /// Opens a game's Game details page (LibraryView's details sheet).
    let open: (LibraryEntry) -> Void
    /// A game you added: LibraryView's own card, with its controller focus.
    @ViewBuilder let localCell: (_ entry: LibraryEntry, _ list: Bool, _ dense: Bool) -> LocalCell
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var steamGames = SteamGamesModel.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("madeiraLibraryCollapsedGroups") private var collapsedGroups = ""
    @State private var steamSheet: SteamSelection?

    private struct SteamSelection: Identifiable { let id: Int }

    private struct Sources {
        var games: [LibraryGrouping.Game] = []
        var entries: [UUID: LibraryEntry] = [:]
        var steam: [Int: SteamGamesRules.Item] = [:]
    }

    private var sources: Sources {
        var result = Sources()
        let query = search.trimmingCharacters(in: .whitespaces)
        var steamEntries: [Int: (position: Int, entry: LibraryEntry)] = [:]
        for (position, entry) in library.entries.enumerated() where entry.desktop != true {
            if let appID = entry.steamAppID { steamEntries[appID] = (position, entry) }
            // Installed Epic games are listed by the Epic Games section (Epic/).
            else if entry.epicAppName == nil, query.isEmpty || entry.title.localizedCaseInsensitiveContains(query) {
                result.entries[entry.id] = entry
                result.games.append(LibraryGrouping.Game(entry: entry, position: position))
            }
        }
        if SteamGamesSection.shown {
            let enabled = SteamOwnedLibrary.enabled
            let downloading = Set(steam.downloads.keys)
            for item in SteamGamesRules.items(installed: steamGames.games, owned: enabled ? steam.owned : [], search: query) {
                let installed = item.installed != nil || downloading.contains(item.id)
                guard installed || (enabled && steam.signedIn) else { continue }
                let recorded = steamEntries[item.id]
                let steamPlayed = steam.playtime[item.id].flatMap {
                    $0.lastPlayed > 0 ? Date(timeIntervalSince1970: TimeInterval($0.lastPlayed)) : nil
                }
                result.steam[item.id] = item
                result.games.append(LibraryGrouping.Game(source: .steam(item.id), title: item.name, installed: installed,
                                                         lastPlayed: [recorded?.entry.lastPlayed, steamPlayed].compactMap { $0 }.max(),
                                                         bytes: recorded?.entry.folderBytes, position: recorded?.position))
            }
        }
        return result
    }

    var body: some View {
        let sources = self.sources
        let groups = LibraryGrouping.groups(sources.games, by: grouping, sort: sort)
        let collapsed = LibraryGrouping.collapsed(collapsedGroups)
        VStack(alignment: .leading, spacing: 24) {
            if groups.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("Make yourself at home", systemImage: "gamecontroller", description: Text("Copy a game's folder into Madeira › wine › drive_c with the Files app, then tap + and choose its .exe."))
                } else {
                    Text("No games match your search.").foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { group in
                let key = grouping + "." + group.id
                VStack(alignment: .leading, spacing: 14) {
                    if let title = group.title {
                        LibrarySectionHeader(title: title, count: group.games.count,
                                             collapsed: SteamGamesSection.collapsible ? collapsedBinding(key) : nil) { EmptyView() }
                    }
                    if !(collapsed.contains(key) && SteamGamesSection.collapsible) {
                        LibraryCells(items: group.games, layout: layout, width: width) { game, list, dense in
                            cell(game, sources, list: list, dense: dense)
                        }
                    }
                }
            }
        }
        // As the Steam section does: the library reappears after every session.
        .onAppear {
            steamGames.refresh()
            if SteamOwnedLibrary.enabled { steam.start(); steam.reconcileSession() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { steamGames.refresh(); if SteamOwnedLibrary.enabled { steam.reconcileSession() } }
        }
        .sheet(item: $steamSheet) { selection in
            SteamGameSheet(appID: selection.id) { entry in
                // Let the download sheet finish dismissing before presenting the details page.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open(entry) }
            }
        }
        .alert("Steam", isPresented: Binding(get: { steam.error != nil }, set: { if !$0 { steam.error = nil } })) {
            Button("OK", role: .cancel) { steam.error = nil }
        } message: { Text(steam.error ?? "") }
    }

    private func collapsedBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { LibraryGrouping.collapsed(collapsedGroups).contains(key) }, set: { on in
            var set = LibraryGrouping.collapsed(collapsedGroups)
            if on { set.insert(key) } else { set.remove(key) }
            collapsedGroups = LibraryGrouping.storing(set)
        })
    }

    @ViewBuilder private func cell(_ game: LibraryGrouping.Game, _ sources: Sources, list: Bool, dense: Bool) -> some View {
        switch game.source {
        case .entry(let id):
            if let entry = sources.entries[id] { localCell(entry, list, dense) }
        case .steam(let appID):
            if let item = sources.steam[appID] {
                Button {
                    if let installed = item.installed { open(library.steamEntry(installed, title: item.name)) }
                    else { steamSheet = SteamSelection(id: appID) }
                } label: { SteamGameCell(item: item, list: list, dense: dense) }
                    .libraryCardButtonStyle(grid: !list)
            }
        }
    }
}

struct LibraryView: View {
    @ObservedObject private var model = LibraryModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var liquidMetal = LiquidMetalSetting.shared
    var play: (LibraryEntry) -> Void
    var enableJIT: () -> Void
    @ObservedObject private var jitState = LibraryJITState.shared
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
    @State private var search = ""
    /// The Settings tab's own search text, kept apart from the library's.
    @State private var settingsSearch = ""
    @State private var focused: UUID?
    @ObservedObject private var controller = LibraryController.shared
    @ObservedObject private var input = InputSettings.shared
    @State private var tab = 0
    // The interface the next start uses (FrontendChoice).
    @State private var developerUI = !FrontendChoice.preferNew
    @State private var restartNotice = false
    @State private var settingsSheet: SettingsSheet?
    @State private var settingsRefresh = 0
    @AppStorage("madeiraLibraryLayout") private var layout = "cards"
    @AppStorage("madeiraLibrarySort") private var sort = "played"
    @AppStorage("madeiraLibraryGroup") private var group = "platform"
    @AppStorage("madeiraLibraryCollapsedGroups") private var collapsedGroups = ""
    // Collapsed state of the Other games section (MADEIRA_LIBRARY_COLLAPSE=0: no collapsing).
    @AppStorage("madeiraLibraryHideOthers") private var hideOthers = false
    // The sections follow the Steam section's games and sign-in (SteamGames.swift).
    @ObservedObject private var steamGames = SteamGamesModel.shared
    @ObservedObject private var steamLibrary = SteamOwnedLibrary.shared
    private var entries: [LibraryEntry] {
        // Steam games are listed in their own section (SteamGames.swift).
        let visible = model.entries.filter { $0.desktop != true && $0.steamAppID == nil && $0.epicAppName == nil && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
        if sort == "added" { return visible.reversed() }
        return visible.sorted {
            if sort == "played", $0.lastPlayed != $1.lastPlayed { return ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            if sort == "size", $0.folderBytes != $1.folderBytes { return ($0.folderBytes ?? -1) > ($1.folderBytes ?? -1) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    /// The games you added in the page's order, for the controller's focus. Grouping
    /// and sorting go game by game, so their order among the Steam games is the
    /// order without them.
    private var focusOrder: [LibraryEntry] {
        guard group != "platform" else { return entries }
        // A library file edited by hand (or written by a fork) may repeat an id: keep the first.
        let positions = Dictionary(model.entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let games = entries.map { LibraryGrouping.Game(entry: $0, position: positions[$0.id] ?? 0) }
        let collapsed = SteamGamesSection.collapsible ? LibraryGrouping.collapsed(collapsedGroups) : []
        return LibraryGrouping.groups(games, by: group, sort: sort)
            .filter { !collapsed.contains(group + "." + $0.id) }
            .flatMap(\.games).compactMap { game in
                if case .entry(let id) = game.source { return byID[id] }
                return nil
            }
    }
    var body: some View {
        // The system tab bar: on iOS 26 it is the floating Liquid Glass bar whose
        // glass selection slides between the tabs and follows a drag. Icons only; the
        // names stay for VoiceOver.
        TabView(selection: Binding(get: { tab }, set: { switchTab(to: $0) })) {
            library
                .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
                .tabItem { Image(systemName: "square.grid.2x2.fill").accessibilityLabel("Library") }
                .tag(0)
            settings
                .tabItem { Image(systemName: "gearshape.fill").accessibilityLabel("Settings") }
                .tag(1)
        }
        // The system search field (Liquid Glass on iOS 26) in the title's place, left
        // of the library's buttons, on both tabs; each tab keeps its own text.
        .background(LibraryNavSearch(text: tab == 0 ? $search : $settingsSearch,
                                     placeholder: tab == 0 ? "Search your library" : "Search settings")
            .frame(width: 0, height: 0))
        // Each tab is hosted by the tab bar controller, so a toolbar set inside a tab
        // would not reach the navigation bar: the library's lives here.
        // The title is a large leading toolbar item, level with the library's
        // buttons like an App Store tab title; the bar's centred one is cleared.
        // The trailing glass group changes with the tab (switchTab animates it),
        // which iOS 26 draws as a Liquid Glass morph between the two.
        .navigationTitle("")
        .toolbar {
            LibraryLargeTitle()
            if tab == 0 { libraryToolbar } else { settingsToolbar }
        }
        // On the tab view, not inside one tab's page: an alert attached to the Library
        // page cannot present while Settings is showing, so an error raised there (its
        // Enable JIT, for one) waited until the Library tab came back.
        .alert(jitProblem == nil ? "Library" : "Couldn't Enable JIT",
               isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            if let jitProblem { jitConnectionActions(jitProblem, retry: enableJIT) { model.error = nil } }
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .fullScreenCover(isPresented: $onboarding.presented) { OnboardingView() }
        .onAppear {
            // An ended desktop session's surface never stays over the library.
            EndedSessionSurface.install(); EndedSessionSurface.hide(reason: "library-appeared")
            // First-run setup opens once on a new install.
            onboarding.presentIfNeeded()
        }
        .onAppear {
            LogStore.shared.log("[library-sections] native-steam=\(SteamOwnedLibrary.enabled ? 1 : 0) sections=\(SteamGamesSection.shown ? 1 : 0) collapse=\(SteamGamesSection.collapsible ? 1 : 0)")
        }
        // ml1216: a session replaces the library (ContentView), and the skin's run-loop
        // observer, display link and view walks kept running on the main thread through
        // the whole game. Stop with the library; it starts again when the library returns
        // on either tab (start() does nothing while liquid metal is off).
        .onAppear { GlassSkin.shared.start() }
        .onDisappear { GlassSkin.shared.stop() }
        .onReceive(controller.commands) { command in
            if selected == nil, !browser, !onboarding.presented, command == "tab" { switchTab(to: 1 - tab) }
        }
    }
    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Library layout", selection: $layout) {
                    Label("Cards", systemImage: "square.grid.2x2").tag("cards")
                    Label("Compact cards", systemImage: "square.grid.3x3").tag("compact")
                    Label("List", systemImage: "list.bullet").tag("list")
                    Label("Compact list", systemImage: "list.dash").tag("compactList")
                }
                Picker("Group by", selection: $group) {
                    Label("Last played", systemImage: "clock.arrow.circlepath").tag("played")
                    Label("Installed", systemImage: "arrow.down.circle").tag("installed")
                    Label("Platform", systemImage: "square.stack").tag("platform")
                    Label("None", systemImage: "square.grid.2x2").tag("none")
                }.pickerStyle(.menu)
                Picker("Sort by", selection: $sort) {
                    Label("Last played", systemImage: "clock").tag("played")
                    Label("Name", systemImage: "textformat.abc").tag("name")
                    Label("Recently added", systemImage: "plus").tag("added")
                    Label("Folder size", systemImage: "internaldrive").tag("size")
                }
            } label: { Label("Library options", systemImage: "line.3.horizontal.decrease") }
        }
        ToolbarItem(placement: .topBarTrailing) { Button { browser = true } label: { Label("Add executable", systemImage: "plus") } }
    }
    @ToolbarContentBuilder private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: enableJIT) {
                HStack(spacing: 6) {
                    Text("Enable JIT")
                    Image(systemName: "bolt.fill").accessibilityHidden(true)
                }
            }
            .disabled(jitState.enabled)
        }
    }
    private func switchTab(to newTab: Int) {
        guard newTab != tab else { return }
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .default) { tab = newTab }
    }
    /// Settings search: a section shows when the search is empty or matches one of its words.
    private func settingsShow(_ words: String...) -> Bool {
        let q = settingsSearch.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || words.contains { $0.localizedCaseInsensitiveContains(q) || q.localizedCaseInsensitiveContains($0) }
    }
    private var settings: some View {
        Form {
            // The status sits on the page, not in a card; JIT is enabled from the
            // toolbar's Enable JIT button.
            if settingsShow("ready to play", "JIT", "Memory+", "StikDebug", "status") {
                Section { LibraryStatus().listRowBackground(Color.clear) }
            }
            if settingsShow("JIT", "StikDebug", "built-in", "pairing", "LocalDevVPN") {
                JITSettingsSection()
            }
            if settingsShow("diagnostics", "extended logging", "logging", "log") {
                Section {
                    Toggle("Extended logging", isOn: $input.diagnostics)
                } header: { Text("Diagnostics") }
            }
            if settingsShow("pointer", "mouse", "cursor", "touch", "trackpad", "sensitivity") {
                Section("Pointer") { LibraryPointerSettings() }
            }
            if MadeiraConfig.flag("MADEIRA_RUNTIME_SETTINGS") {
                if settingsShow("display", "refresh", "rate", "ProMotion", "120 Hz") { DisplayRateSettings() }
                if settingsShow("memory", "JIT pool", "pool", "video memory", "VRAM", "swap", "coverage", "madsync", "sync", "eco", "all settings") {
                    RuntimeMemorySyncSettings(open: { settingsSheet = $0 }, refresh: settingsRefresh)
                }
            }
            if SteamSettingsSection.shown, settingsShow("Steam", "Dock", "sign in", "account", "setup") {
                SteamSettingsSection(open: { settingsSheet = $0 })
            }
            if settingsShow(".NET", "Mono", "Wine Mono", "framework", "download") { WineMonoSettingsSection() }
            if settingsShow("Epic", "Epic Games", "sign in", "account") {
                EpicSettingsSection(open: { settingsSheet = $0 })
            }
            if settingsShow("saves", "backup", "restore", "save games") { SavesSection() }
            if settingsShow("appearance", "liquid metal", "metal", "glass") {
                Section {
                    Toggle("Liquid metal", isOn: $liquidMetal.on)
                } header: { Text("Appearance") } footer: {
                    Text("Flowing chrome on the bars and the Desktop button. Off, they use the system's Liquid Glass.")
                }
            }
            if settingsShow("interface", "developer") {
                Section {
                    Toggle("Use developer interface", isOn: Binding(get: { developerUI }, set: { on in
                        developerUI = on; FrontendChoice.choose(new: !on); restartNotice = true
                    }))
                } header: { Text("Interface") } footer: {
                    Text("The developer interface is Madeira's original diagnostic screen. The change applies after Madeira restarts.")
                }
            }
            // Search: the matching options of All settings, editable here.
            if !settingsSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                SettingsSearchResults(query: settingsSearch.trimmingCharacters(in: .whitespaces), refresh: settingsRefresh)
            }
            // Credits, last on the Settings page.
            if settingsShow("credits", "thanks", "Will Faust", "Nick", "125hz", "Jfishin", "Jesse", "JesseLovelace", "Dan Perks", "danperks", "bahacan16", "spitefulowl", "meshoklv", "TheHadesc") {
                Section {
                    MadeiraCredit(name: "Will Faust", handle: "willfaust", role: "Created Madeira")
                    MadeiraCredit(name: "Nick", handle: "125hz", role: "32-bit game support, the game library and Madeira Dock")
                    MadeiraCredit(name: "Jfishin", handle: "Jfishin", role: "The original native Steam sign-in, library and downloads")
                    MadeiraCredit(name: "Jesse", handle: "JesseLovelace", role: "Steam Cloud saves, faster game launches, and fixes that let more games run")
                    MadeiraCredit(name: "Dan Perks", handle: "danperks", role: "In-app JIT without StikDebug, and pairing without a computer")
                    MadeiraCredit(name: "bahacan16", handle: "bahacan16", role: "Direct3D 12 and DXMT fixes, game launcher windows, per-game settings, PlayStation controllers, and save backups")
                    MadeiraCredit(name: "spitefulowl", handle: "spitefulowl", role: "Wine and FEX runtime fixes, DXMT texture and memory fixes, audio, the swap tier, and library launch options")
                    MadeiraCredit(name: "meshoklv", handle: "meshoklv", role: "Controller fixes for games that ship their own XInput or need focus, touch taps that stay off the mouse, and a crash-guard fix")
                    MadeiraCredit(name: "TheHadesc", handle: "TheHadesc", role: "Madeira Dock starts for games whose Steam launch entries do not start at zero, and a touch gamepad that survives the in-game keyboard")
                } header: { Text("Credits") } footer: {
                    Text("Madeira is built on Wine, FEX-Emu, DXMT by Feifan He (3Shain) with the Direct3D 9 frontend by David Acevedo (dacevedo12), rpmalloc by Mattias Jansson, StikDebug, StikJIT and idevice. Thank you to everyone who contributes to these projects.")
                }
            }
        }
        .alert("Restart Madeira", isPresented: $restartNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Close Madeira from the app switcher and open it again to switch interfaces.")
        }
        // The Settings sheets hang off the Form, never off one of its rows: a Form
        // may rebuild its rows while a sheet slides up over it, and a sheet whose
        // owning row is rebuilt closes again at once.
        .sheet(item: $settingsSheet, onDismiss: { settingsRefresh += 1 }) { sheet in
            switch sheet {
            case .allSettings: AllSettingsView()
            case .steamSignIn: SteamSignInView()
            case .epicSignIn: EpicSignInView()
            case .dock: MadeiraDockView(start: startDock)
            }
        }
    }
    private var library: some View {
        GeometryReader { viewport in
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Button { selected = model.entries.first(where: { $0.desktop == true }) ?? .desktopEntry } label: {
                        if liquidMetal.on {
                            // On the chrome's middle band (dark, or light in light mode), with a soft
                            // halo of the other tone for the moments a highlight passes under it.
                            let light = colorScheme == .light
                            Label("Desktop", systemImage: "desktopcomputer")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(light ? .black : .white)
                                .shadow(color: (light ? Color.white : .black).opacity(0.75), radius: 2.5)
                                .padding(.horizontal, 14).frame(minHeight: 44)
                                .background(LiquidMetalFill())
                                // ml1217: the fill does not hit-test, so without this only the
                                // glyphs took a tap (the plain fill's Capsule did).
                                .contentShape(Capsule())
                        } else {
                            Label("Desktop", systemImage: "desktopcomputer")
                                .font(.subheadline.weight(.medium)).padding(.horizontal, 14).frame(minHeight: 44)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                        }
                    }.buttonStyle(.plain)
                        .animation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.4), value: liquidMetal.on)
                        .id(LibraryEntry.desktopID)
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(focused == LibraryEntry.desktopID && controller.connected ? Color.cyan : .clear, lineWidth: 3))
                }
                // The library's sections, as in the fork: Steam (installed and downloading
                // Steam games, then Not installed), then Other games, the games you added.
                // Steam games start through Madeira Dock (SteamGames.swift); an installed one
                // opens its Game details page like any library game. Without the Steam
                // section the games you added are one grid.
                // Installed Steam games first, then the games you added, then the
                // account's Not installed games. With nothing installed (or
                // downloading) the games you added are the top section and the
                // whole Steam section, sign-in included, follows them.
                // Any other Group by choice lists every game in one set of groups.
                if group != "platform" {
                    LibraryGroupedGames(grouping: group, search: search, layout: layout, sort: sort, width: viewport.size.width,
                                        open: { selected = $0 }) { entry, list, dense in
                        libraryItem(entry, list: list, dense: dense)
                    }
                } else {
                let steamFirst = MadeiraDock.enabled && SteamGamesSection.hasInstalled
                if steamFirst {
                    SteamGamesSection(search: search, layout: layout, sort: sort, width: viewport.size.width,
                                      part: .installed, open: { selected = $0 })
                }
                if SteamGamesSection.shown {
                    VStack(alignment: .leading, spacing: 14) {
                        // Games are added with the + in the navigation bar.
                        LibrarySectionHeader(title: "Other games", count: entries.count,
                                             collapsed: SteamGamesSection.collapsible ? $hideOthers : nil) { EmptyView() }
                        if hideOthers && SteamGamesSection.collapsible {
                            EmptyView()
                        } else if entries.isEmpty {
                            Text(search.isEmpty
                                 ? "Copy a game's folder into Madeira › wine › drive_c with the Files app, then tap + and choose its .exe."
                                 : "No other games match your search.")
                                .foregroundStyle(.secondary)
                        } else {
                            cells(entries, width: viewport.size.width)
                        }
                    }
                    if MadeiraDock.enabled {
                        SteamGamesSection(search: search, layout: layout, sort: sort, width: viewport.size.width,
                                          part: steamFirst ? .notInstalled : .all, open: { selected = $0 })
                    }
                } else if model.entries.filter({ $0.desktop != true && $0.steamAppID == nil && $0.epicAppName == nil }).isEmpty {
                    if !EpicGamesSection.shown {
                        ContentUnavailableView("Make yourself at home", systemImage: "gamecontroller", description: Text("Copy a game's folder into Madeira › wine › drive_c with the Files app, then tap + and choose its .exe."))
                    }
                } else {
                    cells(entries, width: viewport.size.width)
                }
                }
                // The account's Epic games, after Steam's and the games you added, under
                // every Group by choice (Epic/).
                EpicGamesSection(search: search, layout: layout, width: viewport.size.width, open: { selected = $0 })
            }
            // Ambient light behind the grid cards, in the content's own space so it scrolls with them.
            .backgroundPreferenceValue(AmbientGlowKey.self) { AmbientGlowLayer(items: $0) }
            .padding(16).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .refreshable { await SteamGamesSection.refresh(); await EpicGamesSection.refresh() }
        .onReceive(controller.commands) { command in
            guard tab == 0, selected == nil, !browser, !onboarding.presented else { return }
            let items = focusOrder
            let ids = [LibraryEntry.desktopID] + items.map(\.id)
            let index = ids.firstIndex(where: { $0 == focused }) ?? 0
            if command == "add" { browser = true }
            else if command == "accept" {
                if index == 0 { selected = model.entries.first(where: { $0.desktop == true }) ?? .desktopEntry }
                else { selected = items[index - 1] }
            }
            else if ["left", "right", "up", "down"].contains(command) {
                let delta = command == "left" || command == "up" ? -1 : 1
                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.18)) { focused = ids[(index + delta + ids.count) % ids.count] }
            }
        }
        .sheet(isPresented: $browser) {
            NavigationStack { ExecutableBrowser(folder: LibraryModel.drive) { entry in
                model.save(entry); browser = false; selected = entry
            } }
        }
        .sheet(item: $selected) { entry in
            // The details page stays up until the session's starting screen takes
            // over (or an error needs the library's alert), instead of showing the
            // library for the moment a start spends preparing.
            LibraryDetail(entry: entry, play: { profile in
                play(profile)
                // Not while Play is still enabling JIT: the session's start, an error, or
                // JIT setup closes the page then.
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    if selected?.id == entry.id, model.startingJIT != entry.id { selected = nil }
                }
            })
        }
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
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshFlag() } }
        .onAppear {
            if focused == nil { focused = LibraryEntry.desktopID }
            GlassSkin.shared.start()   // liquid metal on the navigation bar's glass pills
        }
        .onChange(of: focused) { _, id in
            if let id { withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) { reader.scrollTo(id, anchor: .center) } }
        }
        }
        }
    }
    private func cells(_ items: [LibraryEntry], width viewportWidth: CGFloat) -> some View {
        LibraryCells(items: items, layout: layout, width: viewportWidth) { entry, list, dense in
            libraryItem(entry, list: list, dense: dense)
        }
    }
    private func libraryItem(_ entry: LibraryEntry, list: Bool, dense: Bool = false) -> some View {
        Button { selected = entry } label: {
            Group {
                if list && dense {
                    // One short row per game.
                    HStack(spacing: 10) {
                        LibraryArtwork(entry: entry).frame(width: 28, height: 42).clipShape(RoundedRectangle(cornerRadius: 5))
                        Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        LibraryBadges(entry: entry).foregroundStyle(.secondary).fixedSize()
                    }.padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                } else if list {
                    HStack(spacing: 14) {
                        LibraryArtwork(entry: entry).frame(width: 48, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.title).font(.headline).lineLimit(2); LibraryBadges(entry: entry).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        LibraryArtwork(entry: entry).aspectRatio(2.0 / 3.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                            .modifier(LibraryCardArtworkPress { pressed, bounds in
                                AmbientGlowItem(id: "entry-\(entry.id)", seed: entry.id.hashValue, art: .library(entry), pressed: pressed, bounds: bounds)
                            })
                        Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        LibraryBadges(entry: entry).foregroundStyle(.secondary)
                    }.padding(4)
                }
            }.foregroundStyle(.primary)
        }.libraryCardButtonStyle(grid: !list)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(focused == entry.id && controller.connected ? Color.accentColor : .clear, lineWidth: 2))
            .id(entry.id)
            .task(id: entry.id, priority: .utility) { await model.refreshMetadata(entry.id) }
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
                    .filter { ($0.hasDirectoryPath || LibraryModel.programExtensions.contains($0.pathExtension.lowercased())) && $0.resolvingSymlinksInPath().path.hasPrefix(LibraryModel.drive.path + "/") }
                    .sorted { if $0.hasDirectoryPath != $1.hasDirectoryPath { return $0.hasDirectoryPath }; return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct LibraryPlayStyle: ButtonStyle {
    var pending: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 18).padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(pending || configuration.isPressed ? Color(uiColor: .darkGray) : .accentColor,
                        in: RoundedRectangle(cornerRadius: 14))
    }
}

struct LibraryDetail: View {
    @State var entry: LibraryEntry
    var play: (LibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = LibraryModel.shared
    @State private var importCover = false
    @State private var findCover = false
    @State private var remove = false
    @State private var leaving = false
    @State private var error: String?
    @State private var copiedLink = false
    /// Settings › Sync engine, read when the details open: the fastsync switches
    /// below only apply while it is Fastsync.
    @State private var syncEngine = SyncEngine.current
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
        if let appID = entry.steamAppID {
            if SteamOwnedLibrary.shared.downloads[appID] != nil {
                error = "This game's update has not finished. Resume it and wait for it to complete before playing."; return
            }
            let installed = SteamGamesModel.shared.games.first { $0.id == appID }?.installed ?? false
            if entry.startsSteamGameDirectly {
                if let blocker = SteamDirectStart.blocker(installed: installed, program: entry.steamProgram) { error = blocker; return }
            } else if let blocker = SteamGamesRules.blocker(installed: installed, client: MadeiraDock.clientInstalled, signedIn: SteamSignIn.isSignedIn) {
                error = blocker; return
            }
        }
        leaving = true
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
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 20) {
                        artwork(backdrop: false).frame(width: 120, height: 180).clipShape(RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 12) {
                            Text(entry.title).font(.title2.bold())
                            LibraryBadges(entry: entry)
                            if let appID = entry.steamAppID, let summary = SteamOwnedLibrary.shared.playtime[appID]?.summary {
                                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                            } else if let played = entry.lastPlayed {
                                Text("Last played \(played.formatted(.relative(presentation: .named)))").font(.subheadline).foregroundStyle(.secondary)
                            }
                            // A game Valve's client starts (Madeira Dock): can it start without a connection?
                            if DockOffline.enabled, let appID = entry.steamAppID, !entry.startsSteamGameDirectly {
                                DockOfflineMark(appID: appID)
                            }
                            Button(action: start) {
                                HStack(spacing: 10) {
                                    // Enabling JIT can take seconds with nothing else on screen.
                                    if model.startingJIT == entry.id {
                                        ProgressView().tint(.white)
                                        Text("Starting JIT").fontWeight(.semibold)
                                    } else {
                                        Image(systemName: "play.fill"); Text("Play").fontWeight(.semibold)
                                    }
                                }.frame(minWidth: 100, minHeight: 30)
                            }
                            .buttonStyle(LibraryPlayStyle(pending: leaving)).disabled(leaving)
                        }
                    }.padding(.vertical, 24)
                        .listRowBackground(
                            artwork(backdrop: true).blur(radius: 4)
                                .overlay(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.48))
                                .overlay(alignment: .bottom) {
                                    LinearGradient(colors: [.clear, Color(uiColor: .secondarySystemGroupedBackground)], startPoint: .top, endPoint: .bottom).frame(height: 70)
                                }.clipped()
                        )
                }
                if entry.desktop != true { Section("Library details") {
                    TextField("Title", text: $entry.title)
                    Button("Find on Steam", systemImage: "magnifyingglass") { findCover = true }
                    Button("Choose cover image", systemImage: "photo") { importCover = true }
                    if entry.coverFile != nil { Button((entry.steamAppID ?? entry.steamID) != nil ? "Use Steam artwork" : "Remove cover image") { entry.coverFile = nil } }
                } }
                // A Steam game's cloud saves, then how it starts, under its library
                // details (SteamGames.swift).
                if let appID = entry.steamAppID {
                    SteamCloudSection(appID: appID)
                    SteamEntrySection(entry: $entry) { leaving = true; dismiss() }
                }
                // An installed Epic game's version, prerequisites and Uninstall (Epic/).
                if let epic = entry.epicAppName {
                    EpicEntrySection(appName: epic, run: { prerequisite in leaving = true; play(prerequisite) },
                                     leave: { leaving = true; dismiss() })
                }
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
                    Picker("Aspect & scaling", selection: Binding(get: { entry.displayMode.rawValue }, set: { entry.display = $0 })) {
                        ForEach(DisplayMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    // Every setting here is the Desktop's too: its programs present through
                    // the same path, and its launch applies them like a game's
                    // (applyEnvironment, gameConfigText). check-frontend holds the parity.
                    Picker("MetalFX upscaling", selection: $entry.metalFXUpscale) {
                        Text("Off").tag(Double?.none)
                        Text("1.5×").tag(Double?.some(1.5))
                        Text("2×").tag(Double?.some(2))
                    }
                    FPSChoice(mode: $entry.fpsMode)
                    Toggle("Frame generation (experimental)", isOn: Binding(get: { entry.frameGeneration ?? false }, set: { entry.frameGeneration = $0 ? true : nil }))
                    if entry.frameGeneration == true {
                        Text("Shows a MetalFX-generated frame between every two rendered frames: twice the frames on screen, at the cost of GPU time, some latency and artifacts at edges and on the HUD. FPS limits do not apply while it is on.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Display") } footer: {
                    Text("MetalFX upscaling renders at the resolution above and scales the picture up with Apple's MetalFX spatial scaler before it reaches the screen (Direct3D 11 and 12 programs). Use it with a small resolution for frame rate.")
                }
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
                        TextField("Working folder (default: the program's folder)", text: Binding(get: { entry.workingDirectory ?? "" }, set: {
                            entry.workingDirectory = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
                        })).autocorrectionDisabled().textInputAutocapitalization(.never).font(.body.monospaced())
                        Toggle("Start Windows services first", isOn: Binding(get: { entry.startServices == true }, set: {
                            entry.startServices = $0 ? true : nil
                        }))
                    } header: { Text("Launch") } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Directly: the game is Wine's first program, with no desktop; small windows such as launchers and message boxes are drawn over the game, a window drawn without DirectX that fills the screen is not. In the Wine desktop: the game starts inside the Wine desktop at the Resolution above, where every window shows.")
                            Text("The working folder is a C:\\ path, for example C:\\Games\\Some Game. Start Windows services first is for launchers that need them (Steam-style COM); Madeira writes a batch file for it in C:\\madeira-games.")
                            if !entry.runsInDesktop && (entry.isBatch || entry.startServices == true) {
                                // Wine stops with its first process (the ml1163 open risk).
                                Text("Started directly, Wine stops when its first program exits, so a batch file that starts the game and exits closes the game too. Start it in the Wine desktop instead.")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                // A Steam game starts with Steam's own launch option through Madeira Dock.
                if entry.desktop != true && entry.steamAppID == nil && entry.epicAppName == nil {
                    Section {
                        TextField("Launch arguments", text: $entry.arguments, axis: .vertical)
                            .font(.body.monospaced()).lineLimit(1...4)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        LaunchFlagChips(arguments: $entry.arguments)
                        // What the next start runs (ml1163: in the Wine desktop, a batch file or
                        // the services batch, what starts the program).
                        Text(entry.commandPreview)
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    } header: { Text("Launch arguments") } footer: {
                        Text("Passed to the program on every start; the line above is the command that runs. The flags add or remove themselves; the renderer flags exclude each other, as do -windowed and -fullscreen.")
                    }
                }
                Section {
                    Toggle("Reduced-precision x87", isOn: $entry.reducedX87)
                    // Exported for this game only when chosen (applyEnvironment).
                    Toggle("AVX and AVX2", isOn: Binding(get: { entry.avx ?? false }, set: { entry.avx = $0 ? true : nil }))
                    // Exported for this game only when chosen (applyEnvironment).
                    Picker("CPU cores reported", selection: Binding(get: { entry.cpuCount ?? 0 }, set: { entry.cpuCount = $0 == 0 ? nil : $0 })) {
                        Text("Automatic").tag(0)
                        ForEach([1, 2, 4, 6], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("D3D9 anisotropic filtering", selection: Binding(get: { entry.anisotropyLimit ?? 0 }, set: { entry.anisotropyLimit = $0 == 0 ? nil : $0 })) {
                        Text("Application default").tag(0)
                        ForEach([1, 2, 4, 8], id: \.self) { Text("Up to \($0)×").tag($0) }
                    }
                    Toggle("Report an NVIDIA GPU", isOn: Binding(get: { entry.reportNVIDIA ?? false }, set: { entry.reportNVIDIA = $0 ? true : nil }))
                    // Fastsync-only switches: shown for every game, usable only while
                    // Settings › Sync engine is Fastsync.
                    Group {
                        Toggle("Fast synchronization", isOn: Binding(get: { entry.fastSync ?? true }, set: { entry.fastSync = $0 }))
                        Toggle("Fast semaphore waits (experimental)",
                               isOn: Binding(get: { entry.semaphoreFastPath ?? false }, set: { entry.semaphoreFastPath = $0 }))
                    }
                    .disabled(syncEngine != .fastsync)
                    if syncEngine != .fastsync {
                        Text("Fast synchronization and fast semaphore waits are Fastsync options. Choose Fastsync in Settings › Memory & sync to use them.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Compatibility & performance") } footer: {
                    Text("Reduced-precision x87 can make older games faster at some cost in accuracy; it is off by default. Turn on AVX and AVX2 (off by default, 64-bit games) when a game built for AVX processors quits at start with an illegal instruction (c000001d); FEX then emulates AVX, which is slower. Report an NVIDIA GPU is for games that stop with \"no graphics card\" or \"failed to get GPU driver info\". With Fastsync, fast synchronization (on by default) handles events without a server round trip, and fast semaphore waits (off by default) does the same for semaphores. Settings apply to the next launch; a precision change may still require restarting Madeira.")
                }
                Section("On screen") {
                    Toggle("Performance overlay", isOn: $entry.performance)
                    Toggle("Live logs", isOn: $entry.liveLogs)
                    Toggle("Touch controls", isOn: $entry.touchControls)
                    if GamepadInput.keyboardMouseAvailable {
                        ControllerModeChoice(mode: $entry.controllerMode)
                        if entry.controllerMode == "keys" {
                            NavigationLink("Controller binds") {
                                Form { ControllerBindsPage(binds: $entry.controllerBinds, mouseVertical: $entry.padMouseVertical) }
                                    .navigationTitle("Controller binds")
                                    .toolbar {
                                        Button("Reset") { entry.controllerBinds = nil; entry.padMouseVertical = nil }
                                            .disabled(entry.controllerBinds == nil && entry.padMouseVertical == nil)
                                    }
                            }
                        }
                    }
                    LabeledContent("Control opacity") {
                        Slider(value: Binding(get: { entry.controlOpacity ?? 0.7 }, set: { entry.controlOpacity = $0 }), in: 0.15...1)
                    }
                    LabeledContent("Control size") {
                        Slider(value: Binding(get: { entry.controlSize ?? 1 }, set: { entry.controlSize = $0 }), in: 0.5...2)
                    }
                    Text("Arrange buttons and choose XInput, mouse, or keyboard actions from the in-game menu.").font(.caption).foregroundStyle(.secondary)
                    if GamepadInput.keyboardMouseAvailable {
                        Text("XInput and DirectInput: for games older than XInput, which read the pad through DirectInput. The same pad is offered through both APIs, so a game that reads both may list two controllers. Applies to the next launch.").font(.caption).foregroundStyle(.secondary)
                        Text("Keyboard and mouse: for games without controller support. The controller presses keys and moves the mouse (left stick WASD, right stick mouse, triggers click, D-pad arrows, Start Esc, Select Tab) and the game sees no controller. Change what each button does under Controller binds, here or in the in-game menu.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    NavigationLink {
                        LibraryGameConfigEditor(text: Binding(get: { entry.config ?? "" }, set: { entry.config = $0.isEmpty ? nil : $0 }))
                    } label: {
                        LabeledContent("This game's config", value: Self.configSummary(entry.config))
                    }
                } header: { Text("Advanced") } footer: {
                    Text("Lines in madeira.cfg's format for this game only. A key set here wins over madeira.cfg wherever the runtime reads it, env.NAME lines are exported after madeira.cfg's, and dxmt options are added to madeira.cfg's. Applies from the next start.")
                }
                // A link that starts this game from a Home Screen icon (SavesAndShortcuts.swift).
                if entry.desktop != true {
                    Section {
                        Button {
                            UIPasteboard.general.string = ShortcutRouter.link(for: entry.windowsPath)
                            copiedLink = true
                        } label: {
                            Label(copiedLink ? "Link copied" : "Copy Home Screen shortcut link",
                                  systemImage: copiedLink ? "checkmark" : "link")
                        }
                    } header: { Text("Home Screen") } footer: {
                        Text("In the Shortcuts app: new shortcut, Open URLs, paste the link, then Share › Add to Home Screen.")
                    }
                }
                if entry.steamAppID != nil {
                    Section {
                        Text(entry.launchWindowsPath).font(.caption.monospaced()).textSelection(.enabled)
                        if entry.startsSteamGameDirectly, !entry.launchArguments.isEmpty {
                            Text(entry.launchArguments).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    } header: { Text("Executable") } footer: {
                        Text(entry.startsSteamGameDirectly
                             ? "The game starts this program directly, without Steam."
                             : "Valve's client starts the game's default Steam launch option from this folder.")
                    }
                } else if entry.desktop != true {
                    Section("Executable") { Text(entry.windowsPath).font(.caption.monospaced()).textSelection(.enabled) }
                    Section { Button("Remove from library", role: .destructive) { remove = true } }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Game details").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.regularMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.save(entry); dismiss() } } }
            .sheet(isPresented: $findCover) { SteamSearchView(query: entry.title) { match in entry.steamID = match.id; entry.title = match.name; entry.coverFile = nil } }
            .fileImporter(isPresented: $importCover, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let attrs = try url.resourceValues(forKeys: [.fileSizeKey])
                    guard (attrs.fileSize ?? Int.max) <= 20_000_000 else { throw LibraryError.message("Choose an image smaller than 20 MB.") }
                    let data = try Data(contentsOf: url)
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1200, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                          let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85) else { throw LibraryError.message("This image could not be opened.") }
                    let dir = LibraryModel.documents.appendingPathComponent("madeira-art", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let name = entry.id.uuidString + ".jpg"; try jpeg.write(to: dir.appendingPathComponent(name), options: .atomic); entry.coverFile = name
                } catch { self.error = error.localizedDescription }
            }
            .confirmationDialog("Remove this library entry? Your executable and saves stay in drive_c.", isPresented: $remove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { leaving = true; model.remove(entry.id); dismiss() }
            }
            .task {
                if entry.graphicsAPI == nil, entry.desktop != true, let url = try? LibraryModel.executable(entry.relativePath) { entry.graphicsAPI = LibraryModel.graphicsImports(url) }
            }
            .onDisappear { if !leaving { model.save(entry) } }
            .onReceive(LibraryController.shared.commands) { command in
                guard !leaving, !findCover, !importCover, !remove else { return }
                if command == "back" { model.save(entry); dismiss() }
                if command == "accept" { start() }
            }
        }
    }
}

/// Game details › This game's config: the game's own lines in madeira.cfg's
/// syntax, saved with the entry and applied at its next start
/// (LibraryEntry.config, MadeiraConfig.applyGame).
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
    @State var query: String
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
                do { let found = try await SteamCatalog.search(submitted); try Task.checkCancellation(); results = found; if found.isEmpty { error = "No matches. Try a different title." } }
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
        .alert(ready ? "Can be played offline" : "Not ready for offline play yet", isPresented: $explain) {
            Button("OK", role: .cancel) {}
        } message: { Text(Self.explanation(mark)) }
    }
    static func line(_ mark: DockOffline.Mark) -> String {
        switch mark {
        case .ready: return "Can be played offline"
        case .needsFirstStart: return "Start once online to play offline"
        case .needsOnline: return "Start a game online to play offline"
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
                        .accessibilityValue(on ? "On" : "Off")
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
    case allSettings, steamSignIn, epicSignIn, dock
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
        case .fastsync: return "Fastsync (default)"
        case .wine: return "Wine standard sync"
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

struct RuntimeMemorySyncSettings: View {
    /// Opens a Settings sheet (LibraryView owns the presentation).
    var open: (SettingsSheet) -> Void = { _ in }
    /// Bumped when a Settings sheet closes, so the rows re-read madeira.cfg.
    var refresh = 0
    /// The keys this section owns; All settings leaves them out.
    static let featuredKeys: Set<String> = ["pool", "vram-mb", "swap-mb", "env.MADEIRA_SWAP_COVERAGE", "inproc-sync",
                                            "env.MADEIRA_FASTSYNC", "eco"]
    // ml1241: 256 (the launch's lower bound) for the pool, 512 and 1024 for video memory
    // (winemetal accepts vram-mb >= 256), at the user's request.
    static let poolChoices = [0, 256, 512, 640, 768, 1024, 1152]          // 0 = the standard 896 MB
    static let vramChoices = [0, 512, 1024, 1536, 2048, 3072, 4096, 4352, 4608, 5120, 6144]   // 0 = automatic
    static let swapChoices = [0, 1024, 2048, 3072, 4096]
    /// The stored value "" (no key) and "classic" are the same rules, unless
    /// madeira.cfg has swap-mode = 2 (then no key means broad, ml1257).
    static let coverageChoices: [(String, String)] = [
        ("", "Large allocations (8 MB+)"), ("blocks", "All allocations of 1 MB+"), ("wide", "1 MB+ and overflow"),
        ("broad", "Whole reservations 4 MB+ (broad)"),
    ]
    @State private var poolMB = Self.intKey("pool")
    @State private var vramMB = Self.intKey("vram-mb")
    @State private var swapMB = Self.intKey("swap-mb")
    @State private var coverage = Self.currentCoverage()
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
            mbPicker("JIT pool", key: "pool", value: $poolMB, choices: Self.poolChoices,
                     zero: "Default (896 MB)", label: { "\($0) MB" })
            mbPicker("Video memory", key: "vram-mb", value: $vramMB, choices: Self.vramChoices,
                     zero: "Automatic", label: Self.gb)
            mbPicker("Swap tier", key: "swap-mb", value: $swapMB, choices: Self.swapChoices,
                     zero: "Off", label: Self.gb)
            Picker("Swap coverage", selection: Binding(get: { coverage }, set: { mode in
                coverage = mode; changed = true
                // With swap-mode = 2 no key means broad, so classic is written out.
                MadeiraConfig.set("env.MADEIRA_SWAP_COVERAGE", mode.isEmpty ? (Self.swapModeBroad ? "classic" : nil) : mode)
                LogStore.shared.log("[runtime-settings] swap-coverage=\(mode.isEmpty ? "classic" : mode)")
            })) {
                ForEach(Self.coverageChoices, id: \.0) { Text($0.1).tag($0.0) }
                if !Self.coverageChoices.contains(where: { $0.0 == coverage }) { Text(coverage).tag(coverage) }
            }
            .disabled(swapMB == 0)
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
        } header: { Text("Memory & sync") } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("JIT pool is the memory reserved at launch for translated x86 code (256 to 1152 MB; below 512 MB, large games can run out of room for it).")
                Text("Video memory is how much graphics memory games are told they have. Automatic sizes it from the memory free at launch. Too high can get Madeira closed for using too much memory; too low makes games keep reloading textures.")
                Text("Swap tier moves game data to a file on this device's storage when memory runs short, up to the chosen size, at some speed cost. Coverage decides which allocations it moves: large ones only (8 MB and up, the default), every allocation of 1 MB and up, or those plus allocations that overflow the game's address range. Broad backs every new reservation of 4 MB and up (madeira.cfg swap-min-mb moves the floor) as it is made, so the small commits games make inside it are covered too, and the swap tier size limits the storage it uses. Wider coverage saves more memory but can slow a game down.")
                Text("Sync engine: Fastsync (the default) handles events and semaphores in-process; its per-game options are in each game's details. Madsync is the older in-process engine. Wine standard sync uses neither. Only one engine runs at a time.")
                Text("Eco mode starts every game with its threads at a low priority, which saves power but makes games run slower. Off by default. It is meant for loading screens: Eco mode in the in-game menu turns it on and off while a game runs.")
                if changed { Text("Restart Madeira (close it from the app switcher) for these changes to apply.").foregroundStyle(.orange) }
            }
        }
        .onChange(of: refresh) { _, _ in
            poolMB = Self.intKey("pool"); vramMB = Self.intKey("vram-mb"); swapMB = Self.intKey("swap-mb")
            coverage = Self.currentCoverage(); engine = SyncEngine.current
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
        Text(input.touchMode ? "Tap the screen to position and click. Hold and move to drag. Two fingers: right click or scroll."
             : (input.relative ? "Drag to send relative mouse movement for mouse-look. Tap to click." : "Drag the pointer like a trackpad. Tap to click."))
            .font(.caption).foregroundStyle(.secondary)
        LabeledContent("Touch sensitivity") {
            Slider(value: input.relative ? $input.sensRel : $input.sensAbs, in: 0.1...8)
        }
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
                    .accessibilityLabel("Game menu").accessibilityHint("Drag to move")
            } else { LibraryMetrics().accessibilityHint("Drag to move") }
        }
        .frame(maxWidth: isMenu ? 48 : max(48, min(390, viewport.width - insets.leading - insets.trailing - 16)))
        .fixedSize(horizontal: false, vertical: true)
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
    /// The Session menu's Controller binds page (keyboard-and-mouse mode).
    @State private var bindsPage = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if model.launching, let entry = model.activeEntry {
                    launchBackdrop(entry).overlay(.black.opacity(0.65)).ignoresSafeArea()
                        .opacity(launchVisible ? 1 : 0)
                    launchView(entry, geometry: geo)
                        .opacity(launchVisible ? 1 : 0)
                        .scaleEffect(launchVisible || reduceMotion ? 1 : 0.96)
                }
                if !model.launching && model.performance { LibraryFloatingItem(isMenu: false, viewport: geo.size, insets: geo.safeAreaInsets) }
                if model.liveLogs && !model.launching { LibraryLiveLogs().frame(maxWidth: 550, maxHeight: 140).padding(.top, Self.topInset(geo) + 60).padding(.horizontal, 12).allowsHitTesting(false) }
                if !model.sessionMessage.isEmpty { Text(model.sessionMessage).font(.caption).padding(10).background(.regularMaterial, in: Capsule()).frame(maxWidth: .infinity).padding(.top, Self.topInset(geo) + 12).allowsHitTesting(false) }
                if !model.launching { LibraryFloatingItem(isMenu: true, viewport: geo.size, insets: geo.safeAreaInsets) }
                if model.menu {
                    Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { model.menu = false }.transition(.opacity)
                    (bindsPage ? AnyView(bindsMenu) : AnyView(menu))
                        .frame(width: min(460, geo.size.width - 32), height: min(650, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom - 24))
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28))
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.15)))
                        .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.menu)
            .onAppear {
                withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.35)) { launchVisible = true }
            }
            .preferredColorScheme(.dark)
        }.ignoresSafeArea()
        .onAppear { model.saveCurrentProfile() }
        .onChange(of: model.menu) { _, open in
            LibraryController.shared.configure(enabled: model.enabled, ownsInput: open)
            if !open { bindsPage = false }
            if !open { model.saveCurrentProfile() }
            if open { eco = madeira_get_eco() != 0; fenceMode = FPSOverlayFenceMode.current }
        }
        .onReceive(LibraryController.shared.commands) { command in
            if command == "menu" { if model.menu { model.menu = false } else { model.showMenu() } }
            else if command == "back", model.menu { model.menu = false }
        }
    }
    private func launchView(_ entry: LibraryEntry, geometry geo: GeometryProxy) -> some View {
        let compact = geo.size.height < 500
        let available = max(0, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom)
        // A landscape phone would have the live log below the fold; it goes
        // beside the status there instead.
        let showLogs = model.launchLogs
        let sideLogs = showLogs && compact && geo.size.width > geo.size.height
        return HStack(spacing: 12) {
        VStack(spacing: 0) {
        ScrollView {
            VStack(spacing: compact ? 10 : 18) {
                launchCover(entry).frame(width: compact ? 90 : 120, height: compact ? 135 : 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14)).shadow(radius: 20)
                Text(entry.title).font(.title2.bold()).multilineTextAlignment(.center)
                if dockStart.failure == nil { ProgressView().tint(.white) }
                if let failure = dockStart.failure {
                    Text("Madeira Dock stopped").font(.headline)
                    Text(failure).font(.caption).multilineTextAlignment(.center).frame(maxWidth: 360)
                } else if dockStart.active {
                    // What the Dock start is waiting for, from the host's report, and what it
                    // does with the game's one-time installs.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 8) {
                            Text(dockStatus).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                            if let note = DockInstallers.note {
                                Text(note).font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).frame(maxWidth: 360)
                            }
                            Text("\(Int(context.date.timeIntervalSince(model.launchStartedAt)))s")
                                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 8) {
                            Text(model.launchSlow ? "Still starting…" : "Starting your game…").foregroundStyle(.white.opacity(0.7))
                            Text("\(Int(context.date.timeIntervalSince(model.launchStartedAt)))s")
                                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                // The starting screen's controls are one row of glyph-only buttons, so a
                // short screen does not push them below the fold. The words stay as
                // VoiceOver labels. A stopped Dock start can be closed; while a Dock start
                // holds the desktop back, Show desktop reveals it.
                HStack(spacing: 14) {
                    if dockStart.failure != nil {
                        launchGlyph("Close session", "stop.circle") { model.requestQuit() }
                    }
                    launchGlyph(showLogs ? "Hide live log" : "Show live log", "text.alignleft", on: showLogs) {
                        model.toggleLaunchLogs()
                    }
                    if dockStart.holding {
                        launchGlyph("Show desktop", "macwindow") { dockStart.showDesktop(model) }
                            .accessibilityHint("Shows the Windows desktop")
                    }
                }
                if model.launchSlow && !dockStart.holding {
                    Button("Show game view") { model.showGameView(reason: "button") }.frame(minHeight: 44)
                }
                if showLogs && !sideLogs {
                    LibraryLiveLogs().frame(maxWidth: 550).frame(height: compact ? 90 : 120).clipped()
                }
            }.padding(16).frame(maxWidth: .infinity).frame(minHeight: available)
        }
        }.frame(maxWidth: .infinity)
        if sideLogs {
            LibraryLiveLogs().frame(width: min(420, geo.size.width * 0.45)).frame(height: max(0, available - 32)).clipped()
                .padding(.trailing, 16 + geo.safeAreaInsets.trailing)
        }
        }
        .frame(width: geo.size.width, height: available)
        .padding(.top, geo.safeAreaInsets.top).foregroundStyle(.white).transition(.opacity)
    }
    /// A round glyph button for the starting screen's control row.
    private func launchGlyph(_ label: String, _ symbol: String, on: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.white.opacity(on ? 0.32 : 0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .accessibilityLabel(label)
    }

    /// The starting screen's cover and backdrop: a Dock start shows the game's
    /// Steam artwork by App ID, any other session its library artwork.
    @ViewBuilder private func launchCover(_ entry: LibraryEntry) -> some View {
        if let appID = dockStart.appID { SteamGameArtwork(appID: appID) } else { LibraryArtwork(entry: entry) }
    }
    @ViewBuilder private func launchBackdrop(_ entry: LibraryEntry) -> some View {
        if let appID = dockStart.appID { SteamLaunchBackdrop(appID: appID) } else { LibraryArtwork(entry: entry, backdrop: true) }
    }

    /// What the Dock start is doing (DockStartStatus), read once a second.
    private var dockStatus: String {
        MainActor.assumeIsolated {
            let progress = DockInstallers.poll(drive: MadeiraDock.drive)
            // The host starts at once, or after this start's one-time installs finished.
            let hostDue = DockInstallers.finishedAt ?? model.launchStartedAt
            return DockStartStatus.text(MadeiraDock.pollReport().fields, installers: DockInstallers.script != nil,
                                        installerProgress: progress, installsFinished: DockInstallers.finishedAt != nil,
                                        waited: Date().timeIntervalSince(hostDue))
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
                Button("Keyboard", systemImage: "keyboard") { model.menu = false; LibraryKeyboard.show() }
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
                    ForEach(["FPS", "Frame time", "CPU", "GPU", "RAM", "Battery", "Thermal"], id: \.self) { field in
                        Toggle(field, isOn: Binding(get: { model.overlayFields.contains(field) }, set: { on in
                            model.overlayFields.removeAll { $0 == field }; if on { model.overlayFields.append(field) }
                        })).font(.subheadline)
                    }
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
                Button(role: .destructive) { model.requestQuit() } label: {
                    Label("Quit game", systemImage: "stop.circle").foregroundStyle(.red)
                }.tint(.red)
                Text("Closes the running session. Unsaved progress will be lost.").font(.caption).foregroundStyle(.secondary)
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
            .accessibilityLabel("Live diagnostic log")
    }
}

struct LibraryMetrics: View {
    @ObservedObject private var model = LibraryModel.shared
    @State private var lastCount: UInt64 = 0
    @State private var lastTime = Date()
    @State private var fps = 0.0
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
    private let ticks = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        Text(parts.joined(separator: "  ·  "))
            .font(.caption.monospacedDigit().weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
            .background(.black.opacity(0.8), in: Capsule()).foregroundStyle(.white)
            .onAppear {
                lastCount = madeira_get_present_count(); lastTime = Date(); UIDevice.current.isBatteryMonitoringEnabled = true
                applyGPUMeter()
            }
            .onDisappear { UIDevice.current.isBatteryMonitoringEnabled = false; madeira_gpu_meter_enable(0) }
            .onChange(of: model.overlayFields) { _, _ in applyGPUMeter() }
            .onReceive(ticks) { now in
                let count = madeira_get_present_count(); let dt = now.timeIntervalSince(lastTime)
                let frames = count >= lastCount ? count - lastCount : 0
                fps = Double(frames) / max(0.001, dt); lastCount = count; lastTime = now
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
        if model.overlayFields.contains("Frame time") { result.append(fps > 0 ? String(format: "%.1f ms avg", 1000 / fps) : "— ms") }
        if model.overlayFields.contains("CPU") {
            result.append(cpu.map { String(format: "CPU %.0f%% (top %.0f%%)", $0.total, $0.top) } ?? "CPU —")
        }
        if model.overlayFields.contains("GPU") {
            if gpu < 0 { result.append("GPU —") }
            else if gpuFrameMs > 0 { result.append(String(format: "GPU %.0f%% (%.1f ms)", gpu, gpuFrameMs)) }
            else { result.append(String(format: "GPU %.0f%%", gpu)) }
        }
        if model.overlayFields.contains("RAM") { result.append("\(memory) MB") }
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
        if window != nil { fputs("[frontend-keyboard] key-window input deactivated\n", stderr) }
        input?.releaseModifiers(); input?.resignFirstResponder(); window?.isHidden = true
        window = nil; input = nil; previous?.makeKey(); previous = nil
    }
}
final class LibraryKeyboardWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
final class LibraryKeyInput: UIView, UIKeyInput {
    var hasText: Bool { true }
    override var canBecomeFirstResponder: Bool { true }
    private var held = Set<Int32>()
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    override var inputAccessoryView: UIView? {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 650, height: 52)); scroll.backgroundColor = .secondarySystemBackground
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 5
        for (title, key) in [("Esc", 0x1b), ("Ctrl", 0x11), ("Shift", 0x10), ("Alt", 0x12), ("Tab", 0x09), ("Enter", 0x0d), ("←", 0x25), ("↑", 0x26), ("↓", 0x28), ("→", 0x27), ("Done", 0)] {
            let button = UIButton(type: .system); button.configuration = .tinted(); button.setTitle(title, for: .normal)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self else { return }
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
        for ch in text {
            guard let (vk, shift) = MetalBackedView.vkForChar(ch) else { continue }
            let temporary = shift && !held.contains(0x10)
            if temporary { winios_post_key(0x10, 1) }; press(vk); if temporary { winios_post_key(0x10, 0) }
        }
    }
    func deleteBackward() { press(0x08) }
    func releaseModifiers() { for key in held { winios_post_key(key, 0) }; held.removeAll() }
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

    @MainActor static func hide(reason: String) {
        guard MadeiraConfig.flag("MADEIRA_LIBRARY_HIDE_ENDED_DESKTOP"), LibraryModel.shared.enabled,
              LibraryModel.shared.current == nil, wine_process_is_running() == 0 else { return }
        guard winios_compositor_set_hidden(1) != 0 else { return }
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
