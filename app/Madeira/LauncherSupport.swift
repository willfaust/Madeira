// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Windows game-launcher support. The launchers remain the vendors' own
// programs and are downloaded by the user from their official endpoints. This
// file only adds the profiles and prefix repairs needed to run them in Wine.

import Foundation
import SwiftUI

enum LauncherID: String, CaseIterable, Codable, Hashable, Identifiable {
    case ubisoft
    case epic
    case rockstar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ubisoft: return "Ubisoft Connect"
        case .epic: return "Epic Games Launcher"
        case .rockstar: return "Rockstar Games Launcher"
        }
    }

    /// Ordered from the current name to the names used by older releases.
    var executableCandidates: [String] {
        switch self {
        case .ubisoft:
            return [
                "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe",
                "Program Files/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe",
                "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/upc.exe",
                "Program Files/Ubisoft/Ubisoft Game Launcher/upc.exe",
                "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/Uplay.exe",
                "Program Files/Ubisoft/Ubisoft Game Launcher/Uplay.exe",
            ]
        case .epic:
            return [
                "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe",
                "Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe",
            ]
        case .rockstar:
            return [
                "Program Files/Rockstar Games/Launcher/Launcher.exe",
                "Program Files (x86)/Rockstar Games/Launcher/Launcher.exe",
            ]
        }
    }

    var installerURL: URL {
        switch self {
        case .ubisoft:
            return URL(string: "https://ubistatic3-a.akamaihd.net/orbit/launcher_installer/UbisoftConnectInstaller.exe")!
        case .epic:
            return URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!
        case .rockstar:
            return URL(string: "https://gamedownloads.rockstargames.com/public/installer/Rockstar-Games-Launcher.exe")!
        }
    }

    var installerFilename: String {
        switch self {
        case .ubisoft: return "UbisoftConnectInstaller.exe"
        case .epic: return "EpicGamesLauncherInstaller.msi"
        case .rockstar: return "Rockstar-Games-Launcher.exe"
        }
    }

    var installerArguments: String { "" }

    /// Registry values used by installers and by games that launch through a
    /// vendor protocol. Both registry views are written because AC titles are
    /// frequently 32-bit while the current Ubisoft client is 64-bit.
    var registryValues: [(key: String, name: String, value: String)] {
        switch self {
        case .ubisoft:
            return [
                ("Software\\Ubisoft\\Launcher", "InstallDir", "{INSTALL_DIR}"),
                ("Software\\Ubisoft\\Launcher", "InstallLocation", "{INSTALL_DIR}"),
                ("Software\\Ubisoft\\Launcher", "InstallPath", "{INSTALL_DIR}"),
                ("Software\\Ubisoft\\Launcher", "LauncherPath", "{LAUNCHER}"),
                ("Software\\Ubisoft\\Launcher", "UplayPath", "{LAUNCHER}"),
                // Older Assassin's Creed executables use ShellExecute on the
                // uplay:// protocol instead of locating Uplay.exe themselves.
                // HKEY_CLASSES_ROOT is the merged view of HKCU/HKLM classes;
                // RegistryRepair places these entries in HKCU's classes hive.
                ("Software\\Classes\\uplay", "URL Protocol", ""),
                ("Software\\Classes\\uplay\\shell\\open\\command", "@", "\"{LAUNCHER}\" \"%1\""),
                ("Software\\Classes\\ubisoft-connect", "URL Protocol", ""),
                ("Software\\Classes\\ubisoft-connect\\shell\\open\\command", "@", "\"{LAUNCHER}\" \"%1\""),
            ]
        case .epic:
            return [
                ("Software\\Epic Games\\Epic Games Launcher", "AppDataPath", "{APPDATA}"),
                ("Software\\Epic Games\\Epic Games Launcher", "InstallLocation", "{INSTALL_DIR}"),
            ]
        case .rockstar:
            return [
                ("Software\\Rockstar Games\\Launcher", "InstallFolder", "{INSTALL_DIR}"),
                ("Software\\Rockstar Games\\Launcher", "InstallLocation", "{INSTALL_DIR}"),
            ]
        }
    }

    var aliases: [String] {
        switch self {
        case .ubisoft: return ["Uplay.exe", "UbisoftGameLauncher.exe"]
        case .epic, .rockstar: return []
        }
    }
}

enum LauncherSupportError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

enum LauncherSupport {
    static let downloadFolder = "madeira-downloads"

    static func applyEnvironment(for raw: String?) {
        unsetenv("MADEIRA_LAUNCHER")
        unsetenv("MADEIRA_LEGACY_UPLAY")
        guard let raw, let id = LauncherID(rawValue: raw) else { return }
        setenv("MADEIRA_LAUNCHER", id.rawValue, 1)
        // Lets the native bridge and diagnostics distinguish an old AC/Uplay
        // route from a normal Ubisoft Connect launch without guessing from an
        // executable name.
        if id == .ubisoft { setenv("MADEIRA_LEGACY_UPLAY", "1", 1) }
    }

    static func resolve(_ id: LauncherID, drive: URL = LibraryModel.drive) -> URL? {
        for relative in id.executableCandidates {
            if let found = DockInstallers.resolve("C:\\" + relative.replacingOccurrences(of: "/", with: "\\"), drive: drive) {
                return found
            }
        }

        // A user may install the launcher in a different library. Search only
        // the two Windows Program Files roots, never the whole prefix.
        let names = Set(id.executableCandidates.map { $0.split(separator: "/").last!.lowercased() })
        let roots = ["Program Files", "Program Files (x86)"].map { drive.appendingPathComponent($0, isDirectory: true) }
        let manager = FileManager.default
        for root in roots where manager.fileExists(atPath: root.path) {
            guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                guard names.contains(url.lastPathComponent.lowercased()),
                      url.pathExtension.caseInsensitiveCompare("exe") == .orderedSame,
                      inside(url, drive: drive) else { continue }
                return url
            }
        }
        return nil
    }

    static func inside(_ url: URL, drive: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(
            drive.resolvingSymlinksInPath().standardizedFileURL.path + "/")
    }

    static func windowsPath(_ url: URL, drive: URL = LibraryModel.drive) -> String? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let root = drive.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else { return nil }
        return "C:\\" + String(resolved.path.dropFirst(root.path.count + 1)).replacingOccurrences(of: "/", with: "\\")
    }

    static func windowsFolder(_ url: URL, drive: URL = LibraryModel.drive) -> String? {
        windowsPath(url.deletingLastPathComponent(), drive: drive)
    }

    /// Registry install roots are not always the executable's directory. Epic
    /// stores its launcher root above Portal/Binaries/Win64; Ubisoft and
    /// Rockstar store the directory containing their launcher executable.
    private static func registryInstallDirectory(for id: LauncherID, executableFolder: URL,
                                                 drive: URL) -> String? {
        guard let path = windowsPath(executableFolder, drive: drive) else { return nil }
        guard id == .epic else { return path }
        let suffix = "\\Portal\\Binaries\\Win64"
        guard path.lowercased().hasSuffix(suffix.lowercased()) else { return path }
        return String(path.dropLast(suffix.count))
    }

    /// The data directory expected by each launcher's own registry contract.
    /// These are Windows paths, not iOS paths; the values are consumed by the
    /// launcher after Wine maps them through the prefix.
    private static func appDataPath(for id: LauncherID) -> String {
        switch id {
        case .ubisoft: return "C:\\ProgramData\\Ubisoft Game Launcher"
        case .epic: return "C:\\ProgramData\\Epic\\EpicGamesLauncher\\Data"
        case .rockstar: return "C:\\Users\\mobile\\AppData\\Local\\Rockstar Games\\Launcher"
        }
    }

    /// Makes a normal library entry for a vendor launcher. It starts in the
    /// Wine desktop because all three clients create helper windows during
    /// login, and services.exe is needed by their IPC/bootstrap code.
    static func entry(for id: LauncherID, executable: URL) throws -> LibraryEntry {
        var entry = try LibraryModel.inspect(executable)
        entry.title = id.title
        entry.launcherID = id.rawValue
        entry.launchMode = "desktop"
        entry.startServices = true
        entry.workingDirectory = windowsFolder(executable)
        entry.arguments = id.installerArguments
        return entry
    }

    /// Repair the installed launcher before it is started. This is deliberately
    /// idempotent and only runs while no Wine session has the registry open.
    static func prepare(_ entry: LibraryEntry) throws {
        if let raw = entry.launcherID, let id = LauncherID(rawValue: raw),
           let executable = LibraryModel.hostURL(ofWindowsPath: entry.launchWindowsPath) {
            try repair(id, executable: executable)
            return
        }
        // AC games are commonly started by Steam or Epic rather than by the
        // Ubisoft library entry. If Ubisoft Connect is installed, repair its
        // legacy Uplay surface before every normal game launch as well.
        try prepareInstalledUbisoftCompatibility()
    }

    /// Applies the Ubisoft compatibility surface when Connect is installed.
    /// This is safe to call for every Steam/Dock launch: it does nothing when
    /// Ubisoft Connect is absent and is idempotent when it is present.
    @discardableResult
    static func prepareInstalledUbisoftCompatibility(drive: URL = LibraryModel.drive) throws -> Int {
        guard let executable = resolve(.ubisoft, drive: drive) else { return 0 }
        return try repair(.ubisoft, executable: executable, drive: drive)
    }

    @discardableResult
    static func repair(_ id: LauncherID, executable: URL, drive: URL = LibraryModel.drive) throws -> Int {
        guard inside(executable, drive: drive) else { throw LauncherSupportError.message("The launcher must be inside drive_c.") }
        let manager = FileManager.default
        let folder = executable.deletingLastPathComponent()
        var aliases = 0
        for alias in id.aliases {
            let destination = folder.appendingPathComponent(alias)
            // A previous install can leave a dangling symlink after the
            // launcher updates its directory. FileManager.fileExists() returns
            // false for that case, while createSymbolicLink still fails with
            // EEXIST; heal only stale links and preserve real user files.
            if manager.fileExists(atPath: destination.path) { continue }
            if let attributes = try? manager.attributesOfItem(atPath: destination.path),
               let type = attributes[.type] as? FileAttributeType,
               type == .typeSymbolicLink {
                try? manager.removeItem(at: destination)
            }
            do {
                try manager.createSymbolicLink(atPath: destination.path, withDestinationPath: executable.path)
                aliases += 1
            } catch {
                throw LauncherSupportError.message("Could not create the launcher compatibility alias \(alias): \(error.localizedDescription)")
            }
        }

        guard let installDir = registryInstallDirectory(for: id, executableFolder: folder, drive: drive),
              let launcher = windowsPath(executable, drive: drive) else {
            throw LauncherSupportError.message("The launcher path is outside drive_c.")
        }
        let values = id.registryValues.map { item in
            (key: item.key, name: item.name,
             value: item.value.replacingOccurrences(of: "{INSTALL_DIR}", with: installDir)
                 .replacingOccurrences(of: "{LAUNCHER}", with: launcher)
                 .replacingOccurrences(of: "{APPDATA}", with: Self.appDataPath(for: id)))
        }
        let registry = try RegistryRepair.write(values: values, prefix: LibraryModel.documents.appendingPathComponent("wine"))
        LogStore.shared.log("[launcher] prepared \(id.rawValue) aliases=\(aliases) registry=\(registry)")
        return aliases + registry
    }
}

/// Minimal writer for Wine's text registry format. It updates existing keys
/// in place and keeps a .madeira-bak copy before the first change, matching the
/// safety rule used by Steam's installer support.
enum RegistryRepair {
    static func write(values: [(key: String, name: String, value: String)], prefix: URL) throws -> Int {
        var changes = 0
        // Wine keeps HKLM in system.reg and HKCU in user.reg. Launcher install
        // values are HKLM; protocol classes are deliberately HKCU so the
        // merged HKEY_CLASSES_ROOT view works for both 32-bit AC and 64-bit
        // Ubisoft processes without polluting the machine hive.
        let groups: [(String, [(key: String, name: String, value: String)])] = [
            ("system.reg", values.filter { !$0.key.lowercased().hasPrefix("software\\classes\\") }),
            ("user.reg", values.filter { $0.key.lowercased().hasPrefix("software\\classes\\") }),
        ]
        for (file, selected) in groups where !selected.isEmpty {
            let url = prefix.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            var text = String(decoding: data, as: UTF8.self)
            let changed = update(&text, values: selected)
            guard changed > 0 else { continue }
            let backup = url.appendingPathExtension("madeira-bak")
            if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: url, to: backup) }
            try Data(text.utf8).write(to: url, options: .atomic)
            changes += changed
        }
        return changes
    }

    private static func update(_ text: inout String, values: [(key: String, name: String, value: String)]) -> Int {
        var lines = text.components(separatedBy: "\n")
        var changed = 0
        for value in values {
            // Wine's 32-bit registry view commonly resolves Software through
            // Wow6432Node. Write both explicit sections so a 32-bit AC title
            // and a 64-bit launcher see the same install location.
            var keys = [value.key]
            if value.key.lowercased().hasPrefix("software\\"),
               !value.key.lowercased().hasPrefix("software\\wow6432node\\"),
               !value.key.lowercased().hasPrefix("software\\classes\\") {
                keys.append("Software\\Wow6432Node\\" + String(value.key.dropFirst("Software\\".count)))
            }
            for key in keys {
                let header = "[" + escape(key) + "]"
                let headerIndex = lines.firstIndex { $0.lowercased().hasPrefix(header.lowercased()) }
                // Wine uses an unquoted `@` for a key's default value. A
                // quoted "@" is a different named value and does not satisfy
                // ShellExecute's protocol lookup.
                let valueName = value.name == "@" ? "@" : "\"" + escape(value.name) + "\""
                let line = valueName + "=\"" + escape(value.value) + "\""
                if let start = headerIndex {
                    var end = start + 1
                    while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
                    let prefix = valueName + "="
                    if let existing = (start + 1..<end).first(where: { lines[$0].lowercased().hasPrefix(prefix.lowercased()) }) {
                        if lines[existing] != line { lines[existing] = line; changed += 1 }
                    } else {
                        lines.insert(line, at: end)
                        changed += 1
                    }
                } else {
                    while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { lines.removeLast() }
                    lines += ["", header + " \(Int(Date().timeIntervalSince1970))", line, ""]
                    changed += 1
                }
            }
        }
        text = lines.joined(separator: "\n")
        return changed
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

@MainActor
final class LauncherSupportModel: ObservableObject {
    static let shared = LauncherSupportModel()

    @Published private(set) var detected: [LauncherID: URL] = [:]
    @Published private(set) var downloading: LauncherID?
    @Published private(set) var status = ""
    @Published var error: String?
    private var downloadTask: URLSessionDownloadTask?

    func refresh() {
        var found: [LauncherID: URL] = [:]
        for id in LauncherID.allCases {
            if let url = LauncherSupport.resolve(id) { found[id] = url }
        }
        detected = found
    }

    func add(_ id: LauncherID) {
        guard let executable = detected[id] ?? LauncherSupport.resolve(id) else {
            error = "Install \(id.title) first, or download its installer below."
            return
        }
        do {
            _ = try LauncherSupport.repair(id, executable: executable)
            var entry = try LauncherSupport.entry(for: id, executable: executable)
            if let old = LibraryModel.shared.entries.first(where: { $0.launcherID == id.rawValue }) { entry.id = old.id }
            LibraryModel.shared.save(entry)
            status = "Added \(id.title) to the library."
            refresh()
        } catch { error = error.localizedDescription }
    }

    func repair(_ id: LauncherID) {
        guard let executable = detected[id] ?? LauncherSupport.resolve(id) else {
            error = "\(id.title) is not installed in drive_c."
            return
        }
        do {
            let count = try LauncherSupport.repair(id, executable: executable)
            status = count == 0 ? "\(id.title) is already repaired." : "Repaired \(id.title) (\(count) compatibility changes)."
        } catch { error = error.localizedDescription }
    }

    func download(_ id: LauncherID) {
        guard downloading == nil else { return }
        let directory = LibraryModel.drive.appendingPathComponent(LauncherSupport.downloadFolder, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { error = "Could not create the installer folder: \(error.localizedDescription)"; return }

        downloading = id; error = nil; status = "Downloading \(id.title)…"
        let task = URLSession.shared.downloadTask(with: id.installerURL) { [weak self] temporary, response, failure in
            Task { @MainActor in
                guard let self else { return }
                self.downloadTask = nil
                defer { self.downloading = nil }
                if let failure { self.error = "The \(id.title) download failed: \(failure.localizedDescription)"; return }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    self.error = "The \(id.title) server returned HTTP \(http.statusCode)."; return
                }
                guard let temporary else { self.error = "The \(id.title) download did not produce a file."; return }
                let target = directory.appendingPathComponent(id.installerFilename)
                do {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: temporary, to: target)
                    var entry: LibraryEntry
                    if id.installerFilename.lowercased().hasSuffix(".msi") {
                        let relative = String(target.resolvingSymlinksInPath().path.dropFirst(LibraryModel.drive.path.count + 1))
                        entry = LibraryEntry(title: "Install \(id.title)", relativePath: relative, bits: 0)
                    } else {
                        entry = try LibraryModel.inspect(target)
                        entry.title = "Install \(id.title)"
                    }
                    entry.launchMode = "desktop"
                    entry.workingDirectory = "C:\\" + LauncherSupport.downloadFolder
                    entry.startServices = true
                    if let old = LibraryModel.shared.entries.first(where: { $0.relativePath.caseInsensitiveCompare(entry.relativePath) == .orderedSame }) { entry.id = old.id }
                    LibraryModel.shared.save(entry)
                    self.status = "Downloaded the \(id.title) installer. Open it from the library to install it."
                    LogStore.shared.log("[launcher] downloaded installer id=\(id.rawValue)")
                } catch { self.error = "The \(id.title) installer could not be added: \(error.localizedDescription)" }
            }
        }
        downloadTask = task
        task.resume()
    }
}

struct LauncherSupportSettingsSection: View {
    @ObservedObject private var support = LauncherSupportModel.shared

    var body: some View {
        Section {
            Text("Madeira runs the vendors' Windows launchers inside the Wine desktop. Installers are downloaded only when you tap Download, and your account credentials stay inside each vendor's own sign-in window.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(LauncherID.allCases) { id in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(id.title, systemImage: id == .ubisoft ? "shield.lefthalf.filled" : "gamecontroller")
                            .font(.headline)
                        Spacer()
                        if support.detected[id] != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    if support.detected[id] != nil {
                        Text("Installed in drive_c").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Add to library") { support.add(id) }
                            if id == .ubisoft { Button("Repair Uplay") { support.repair(id) } }
                        }.buttonStyle(.bordered)
                    } else {
                        Text("Not detected in drive_c").font(.caption).foregroundStyle(.secondary)
                        Button("Download official installer") { support.download(id) }
                            .buttonStyle(.bordered)
                            .disabled(support.downloading != nil)
                    }
                }.padding(.vertical, 4)
            }
            if let downloading = support.downloading {
                HStack { ProgressView(); Text("Downloading \(downloading.title)…") }
            }
            if !support.status.isEmpty { Text(support.status).font(.caption).foregroundStyle(.secondary) }
            if let error = support.error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("PC game launchers")
        } footer: {
            Text("For Assassin's Creed games, add Ubisoft Connect after installing it. Madeira creates the legacy Uplay.exe alias and both registry views so older AC titles stop reporting that Uplay is missing.")
        }
        .onAppear { support.refresh() }
    }
}
