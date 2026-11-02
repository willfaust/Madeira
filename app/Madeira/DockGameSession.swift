// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// A Dock game session's service manager (ml2020).
///
/// Some games' launchers install an automatic-start Windows service of their own. A Dock
/// session runs no service manager, so every start of such a service failed (RPC 1722) and
/// the launcher never reached the game. The host (madeira-dock `src/launch.c`) starts Wine's
/// service manager before the launch when `MADEIRA_DOCK_GAME_SCM` is `1`, never when `0`,
/// and with it unset only when the prefix's registry lists such a service.
///
/// The app makes the same decision from the prefix's `system.reg` before the session starts,
/// so that it can (1) turn madsync off for that one session: under madsync Wine's
/// services.exe never answered its RPC clients on device (DockInstallers,
/// `MADEIRA_DOCK_INSTALL_SERVER_SYNC`), so a manager the host starts would time out and the
/// launcher's service would still fail; and (2) export an explicit `0`/`1` to the host and
/// log why (`[dock-game-scm]`). The host's own count then agrees with the app's.
enum DockGameSession {
    /// `MADEIRA_DOCK_GAME_SCM`: `0` off, `1` on, anything else or unset: decided from the registry.
    enum Mode: String, Equatable { case off, on, auto }

    static func mode(_ value: String?) -> Mode {
        switch value?.trimmingCharacters(in: .whitespaces) {
        case "0": return .off
        case "1": return .on
        default: return .auto
        }
    }

    /// The configured mode: the game's own config lines first (madeira.cfg syntax, as
    /// GameRecommendations writes them), then madeira.cfg, then the process environment.
    static func configuredMode(gameConfig: String?) -> Mode {
        let key = "env.MADEIRA_DOCK_GAME_SCM"
        let fromGame = gameConfig.flatMap { MadeiraConfig.parse($0)[key] }.flatMap { $0.isEmpty ? nil : $0 }
        let value = fromGame ?? MadeiraConfig.get(key)
            ?? getenv("MADEIRA_DOCK_GAME_SCM").map { String(cString: $0) }   // 1: Wine's service manager in every Dock game session, 0: never; unset: only when the prefix registers an automatic-start service outside Windows
        return mode(value)
    }

    /// A service another program registered in the prefix with automatic start and an image
    /// outside the Windows folder: only a running service manager can start it.
    struct ForeignService: Equatable {
        let name: String
        let image: String
    }

    /// Wine's `system.reg`: `[System\\CurrentControlSet\\Services\\<name>] <time>` sections
    /// whose values include `"Start"=dword:00000002` (automatic), a Win32 `"Type"`
    /// (`dword:00000010` own process or `00000020` shared) and an `"ImagePath"` string
    /// (`"..."`, or `str(2):"..."` for REG_EXPAND_SZ), backslashes doubled. Wine's own
    /// services have images under the Windows folder or relative to it; those never count.
    static func foreignAutoStartServices(systemReg text: String) -> [ForeignService] {
        var found: [ForeignService] = []
        var name: String?
        var start: UInt32?, type: UInt32?
        var image: String?
        func flush() {
            defer { name = nil; start = nil; type = nil; image = nil }
            guard let name, let start, let type, let image, isForeignAutoStart(type: type, start: start, image: image) else { return }
            found.append(ForeignService(name: name, image: image))
        }
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                name = serviceName(section: line)
                continue
            }
            guard name != nil, line.hasPrefix("\"") else { continue }
            guard let (key, value) = registryValue(line) else { continue }
            switch key.lowercased() {
            case "start": start = dword(value)
            case "type": type = dword(value)
            case "imagepath": image = registryString(value)
            default: continue
            }
        }
        flush()
        return found
    }

    /// `[System\\CurrentControlSet\\Services\\Foo] 1700000000` → "Foo"; nil for any other section
    /// (a service's sub-key, such as `...\\Foo\\Parameters`, has another backslash).
    static func serviceName(section line: String) -> String? {
        guard let close = line.firstIndex(of: "]") else { return nil }
        let path = String(line[line.index(after: line.startIndex)..<close])
        let prefix = "System\\\\CurrentControlSet\\\\Services\\\\"
        guard path.count > prefix.count, path.prefix(prefix.count).lowercased() == prefix.lowercased() else { return nil }
        let name = String(path.dropFirst(prefix.count))
        guard !name.isEmpty, !name.contains("\\") else { return nil }
        return name
    }

    /// `"Key"=value` → (Key, value); the key is quoted, the value is the rest of the line.
    static func registryValue(_ line: String) -> (String, String)? {
        guard line.hasPrefix("\""), let end = line.dropFirst().firstIndex(of: "\"") else { return nil }
        let key = String(line[line.index(after: line.startIndex)..<end])
        let rest = line[line.index(after: end)...]
        guard rest.hasPrefix("=") else { return nil }
        return (key, String(rest.dropFirst()))
    }

    /// `dword:00000002` → 2.
    static func dword(_ value: String) -> UInt32? {
        guard value.lowercased().hasPrefix("dword:") else { return nil }
        return UInt32(value.dropFirst("dword:".count), radix: 16)
    }

    /// `"C:\\Program Files\\X\\svc.exe"` or `str(2):"%SystemRoot%\\..."` → the string, with Wine's
    /// `\\` → `\` and `\"` → `"` undone; nil for a non-string value.
    static func registryString(_ value: String) -> String? {
        var body = Substring(value)
        if body.hasPrefix("str(") {
            guard let colon = body.firstIndex(of: ":") else { return nil }
            body = body[body.index(after: colon)...]
        }
        guard body.hasPrefix("\""), body.hasSuffix("\""), body.count >= 2 else { return nil }
        body = body.dropFirst().dropLast()
        var out = ""
        var escaped = false
        for c in body {
            if escaped { out.append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else { out.append(c) }
        }
        return out
    }

    /// The same test as the host's `sh_service_is_foreign_autostart` (madeira-dock
    /// `src/validation.c`): a Win32 service with automatic (2) or on-demand (3) start whose
    /// image is not Windows' own. A program starts its demand-start service itself, through
    /// the manager, so it needs one as much as an automatic service does.
    static func isForeignAutoStart(type: UInt32, start: UInt32, image: String) -> Bool {
        guard type & 0x30 != 0, start == 2 || start == 3 else { return false }
        let path = image.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        guard !path.isEmpty else { return false }
        return !isWindowsImage(path)
    }

    /// An image given relative to the Windows folder, or inside it (`X:\windows\...`; Wine's
    /// prefix has one Windows folder, `C:\windows`, but any drive letter counts).
    static func isWindowsImage(_ lowercased: String) -> Bool {
        var path = lowercased
        if path.hasPrefix("\\??\\") { path.removeFirst(4) }
        for prefix in ["%systemroot%", "\\systemroot", "system32\\", "syswow64\\", "%windir%"] where path.hasPrefix(prefix) {
            return true
        }
        let normalized = path.replacingOccurrences(of: "/", with: "\\")
        guard normalized.count > 3, normalized[normalized.index(normalized.startIndex, offsetBy: 1)...].hasPrefix(":\\") else { return false }
        return normalized.dropFirst(3).hasPrefix("windows\\")
    }

    /// What the app decided for this start and why.
    struct Decision: Equatable {
        let mode: Mode
        let services: [ForeignService]
        /// Programs the game's own Steam install script recorded under a registry key that is
        /// not Microsoft's (DockInstallers.thirdPartyInstalls): a publisher's launcher,
        /// runtime or anti-cheat. Such a program registers its service on its own first run,
        /// through the service manager, so the registry cannot show the service before then.
        var installs = 0
        /// Whether the host is asked to start the service manager.
        var on: Bool {
            switch mode {
            case .off: return false
            case .on: return true
            case .auto: return !services.isEmpty || installs > 0
            }
        }
        /// The value exported as MADEIRA_DOCK_GAME_SCM for the host.
        var exported: String { on ? "1" : "0" }
        /// One log line, numbers and service names only (an image path can be personal).
        var logLine: String {
            "[dock-game-scm] mode=\(mode.rawValue) services=\(services.count)"
                + (services.isEmpty ? "" : " (" + services.map(\.name).sorted().joined(separator: ", ") + ")")
                + " third-party-installs=\(installs) service-manager=\(on ? "on" : "off")"
        }
    }

    /// Reads the prefix's system.reg only when the mode needs it. `thirdPartyInstalls` is the
    /// count of the game's recorded non-Microsoft install-script programs (DockInstallers).
    static func decide(prefix: URL, gameConfig: String?, thirdPartyInstalls: Int = 0) -> Decision {
        let mode = configuredMode(gameConfig: gameConfig)
        guard mode == .auto else { return Decision(mode: mode, services: []) }
        let text = (try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)) ?? ""
        return Decision(mode: mode, services: foreignAutoStartServices(systemReg: text), installs: max(0, thirdPartyInstalls))
    }

    /// Whether an install-script record's registry key (under its hive, Wine spelling with
    /// single backslashes) is Microsoft's own: `Software\Microsoft\...`, also through
    /// `Wow6432Node`. Microsoft's redistributables (DirectX, Visual C++, .NET, XNA) never need a
    /// service manager at game time; a publisher's program may.
    static func isMicrosoftKey(_ key: String) -> Bool {
        var parts = key.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map { $0.lowercased() }
        if parts.first == "software" { parts.removeFirst() }
        if parts.first == "wow6432node" { parts.removeFirst() }
        return parts.first == "microsoft"
    }

    // MARK: - A 32-bit program behind a 64-bit launcher

    /// Folder and file names that mark a redistributable or installer rather than a game's
    /// own program: a 32-bit setup in a game's folder must not hold a guest window.
    static let redistributableMarks = ["redist", "installer", "setup", "dxsetup", "vc_", "vcredist", "dotnet", "directx",
                                       "unins", "physx", "_commonredist"]

    static func isRedistributable(_ name: String) -> Bool {
        let lower = name.lowercased()
        return redistributableMarks.contains { lower.contains($0) }
    }

    /// Whether the game's folder holds a 32-bit program of its own (PE machine 0x14c), two
    /// levels deep, redistributables and installers left out. A 64-bit launcher chain that
    /// starts such a program needs a 4 GB guest window late in the session, when the launcher's
    /// browser helper has taken most of the map; the app then has ntdll hold one placeholder at
    /// session start (`MADEIRA_WOW_HOLD_WINDOWS=1`, virtual_ios.c ios_wow_session_start).
    /// `machine` reads a file's PE machine (DockInstallers.machine in production).
    static func has32BitProgram(in folder: URL, machine: (URL) -> UInt16?, limit: Int = 400) -> Bool {
        let fm = FileManager.default
        var queue: [(URL, Int)] = [(folder, 0)]
        var seen = 0
        while let (dir, depth) = queue.first {
            queue.removeFirst()
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                seen += 1
                if seen > limit { return false }
                let name = item.lastPathComponent
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if depth < 1, !isRedistributable(name) { queue.append((item, depth + 1)) }
                    continue
                }
                guard name.lowercased().hasSuffix(".exe"), !isRedistributable(name) else { continue }
                if machine(item) == 0x14c { return true }
            }
        }
        return false
    }

    /// The PE machine of the largest program in the game's folder, by the same walk as
    /// has32BitProgram (redistributables and installers left out), nil without one. As a rule
    /// that is the title itself; the 32-bit programs beside a 64-bit one are helpers (a crash
    /// reporter, a launcher's stub, a COM surrogate it starts). Log 94 (2026-10-28): such a
    /// helper put the 64-bit title's memory on the swap file for the whole session (swap-x64
    /// unset: the file first while a 32-bit program is in the session), and the title stalled
    /// on its page-ins; with donor RAM first (log 86, swap-x64 = 1) it ran 27% faster.
    static func largestProgramMachine(in folder: URL, machine: (URL) -> UInt16?, limit: Int = 400) -> UInt16? {
        let fm = FileManager.default
        var queue: [(URL, Int)] = [(folder, 0)]
        var seen = 0
        var largest: (size: Int, url: URL)?
        while let (dir, depth) = queue.first {
            queue.removeFirst()
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                seen += 1
                if seen > limit { break }
                let name = item.lastPathComponent
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory ?? false {
                    if depth < 1, !isRedistributable(name) { queue.append((item, depth + 1)) }
                    continue
                }
                guard name.lowercased().hasSuffix(".exe"), !isRedistributable(name) else { continue }
                let size = values?.fileSize ?? 0
                if size > (largest?.size ?? -1) { largest = (size, item) }
            }
            if seen > limit { break }
        }
        return largest.flatMap { machine($0.url) }
    }

    /// Whether this session runs under server sync instead of madsync because it starts the
    /// service manager. `MADEIRA_DOCK_GAME_SCM_SERVER_SYNC=0` keeps madsync.
    static func serverSyncOff(_ decision: Decision, madsyncConfigured: Bool) -> Bool {
        decision.on && madsyncConfigured && MadeiraConfig.flag("MADEIRA_DOCK_GAME_SCM_SERVER_SYNC")   // 0: a session that starts the service manager keeps madsync
    }
}
