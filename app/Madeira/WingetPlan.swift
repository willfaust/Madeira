// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// How a winget package installs under Wine: which of its installers to use, with what arguments,
// and how to tell afterwards that something was installed. Foundation only (tests/host/check-winget.py).

/// What happens to the downloaded file.
indirect enum WingetStep: Equatable {
    /// The file runs with these arguments.
    case installer(arguments: String)
    /// msiexec /i <file> <arguments>.
    case msi(arguments: String)
    /// The file is the program: nothing is installed.
    case portable
    /// An archive: unpacked, then `nested` (a path inside it) takes `then`.
    case archive(nested: String, then: WingetStep)
}

enum WingetRefusal: Error, Equatable {
    case noInstaller
    /// Every installer is for ARM; Madeira runs x64 and x86 programs.
    case onlyArm
    /// msix, appx, pwa, font: Windows' own app model, not Wine's.
    case packaged(String)
    /// A bare .exe with no silent switch in its manifest would open a window nobody can use.
    case needsSilentSwitch
    case noNestedFile
}

enum WingetPlan {
    /// The installer to use and what to do with it, or why none can be.
    static func choose(_ installers: [WingetInstaller]) -> Result<(installer: WingetInstaller, step: WingetStep), WingetRefusal> {
        guard !installers.isEmpty else { return .failure(.noInstaller) }
        let usable = installers.filter { ["x64", "x86", "neutral", ""].contains($0.architecture.lowercased()) }
        guard !usable.isEmpty else { return .failure(.onlyArm) }
        var good: [(installer: WingetInstaller, step: WingetStep)] = []
        var refusal = WingetRefusal.noInstaller
        for i in usable {
            switch step(type: i.type, nestedType: i.nestedType, nested: i.nestedFiles.first, switches: i.switches) {
            case .success(let s): good.append((i, s))
            case .failure(let r): refusal = r
            }
        }
        guard let best = good.min(by: { rank($0.installer, $0.step).lexicographicallyPrecedes(rank($1.installer, $1.step)) }) else { return .failure(refusal) }
        return .success(best)
    }

    /// Lower is better: x64 over neutral over x86, a user-scope install over a machine-wide one, then by type.
    private static func rank(_ i: WingetInstaller, _ step: WingetStep) -> [Int] {
        let arch = ["x64": 0, "neutral": 1, "": 1, "x86": 2][i.architecture.lowercased()] ?? 3
        let scope = i.scope == "user" ? 0 : 1
        func type(_ s: WingetStep) -> Int {
            switch s {
            case .portable: return 0
            case .archive(_, let inner): return 1 + type(inner)
            case .installer(let args): return i.type == "burn" ? 5 : i.type == "exe" ? 4 : args.isEmpty ? 4 : 1
            case .msi: return 3
            }
        }
        return [arch, scope, type(step)]
    }

    static func step(type: String, nestedType: String?, nested: String?, switches: [String: String]) -> Result<WingetStep, WingetRefusal> {
        let custom = switches["Custom"].map { " " + $0 } ?? ""
        func silent(_ fallback: String) -> String { (switches["Silent"] ?? fallback) + custom }
        switch type.lowercased() {
        case "inno": return .success(.installer(arguments: silent("/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART")))
        case "nullsoft": return .success(.installer(arguments: silent("/S")))
        case "msi", "wix": return .success(.msi(arguments: silent("/quiet /norestart")))
        case "burn": return .success(.installer(arguments: silent("/quiet /norestart")))
        case "exe":
            guard let s = switches["Silent"] ?? switches["SilentWithProgress"] else { return .failure(.needsSilentSwitch) }
            return .success(.installer(arguments: s + custom))
        case "portable": return .success(.portable)
        case "zip":
            guard let nested, let nestedType else { return .failure(.noNestedFile) }
            return step(type: nestedType, nestedType: nil, nested: nil, switches: switches).map { .archive(nested: nested, then: $0) }
        default: return .failure(.packaged(type))
        }
    }

    /// The downloaded file's name: the URL's last component, with an extension its type implies when it has none.
    static func fileName(for i: WingetInstaller) -> String {
        let last = URL(string: i.url)?.lastPathComponent ?? ""
        let clean = last.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "_")
        let name = clean.isEmpty ? "installer" : clean
        // "Setup-1.2" has the extension "2": only a known one counts.
        guard !(["exe", "msi", "zip", "7z", "msix", "appx"].contains((name as NSString).pathExtension.lowercased())) else { return name }
        switch i.type.lowercased() {
        case "msi", "wix": return name + ".msi"
        case "zip": return name + ".zip"
        default: return name + ".exe"
        }
    }

    /// A package id as a folder name.
    static func folderName(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" }.prefix(80))
    }

    /// "x.y" next to "x.y.z": versions compared by their numeric parts, then as text.
    static func isNewer(_ latest: String, than installed: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split { !$0.isNumber }.compactMap { Int($0) } }
        let a = parts(latest), b = parts(installed)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The streaming SHA-256 of a file, lower-case hex; nil when it cannot be read.
    static func sha256Hex(ofFile url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Uninstall keys in Wine's registry files

/// One program registered under Software\Microsoft\Windows\CurrentVersion\Uninstall.
struct WingetUninstallEntry: Equatable {
    var key: String
    var name = "", version = "", publisher = "", location = "", uninstall = ""
}

enum WingetRegistry {
    /// Reads the Uninstall sections of a system.reg or user.reg (WOW6432Node ones included).
    /// The key is "<hive>|<subkey>" so the same name in the 32- and 64-bit views stays apart.
    static func uninstallEntries(_ text: String) -> [String: WingetUninstallEntry] {
        var out: [String: WingetUninstallEntry] = [:]
        var current: String?
        let marker = "\\microsoft\\windows\\currentversion\\uninstall\\"
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("[") {
                current = nil
                guard let end = line.lastIndex(of: "]") else { continue }
                let header = String(line[line.index(after: line.startIndex)..<end]).replacingOccurrences(of: "\\\\", with: "\\")
                guard let r = header.lowercased().range(of: marker) else { continue }
                let sub = String(header[r.upperBound...])
                guard !sub.isEmpty, !sub.contains("\\") else { continue }
                let view = header.lowercased().contains("wow6432node") ? "32" : "64"
                let key = view + "|" + sub
                current = key
                out[key] = WingetUninstallEntry(key: key)
            } else if let key = current, line.hasPrefix("\"") {
                guard let (name, value) = stringValue(line) else { continue }
                switch name {
                case "DisplayName": out[key]?.name = value
                case "DisplayVersion": out[key]?.version = value
                case "Publisher": out[key]?.publisher = value
                case "InstallLocation": out[key]?.location = value
                case "UninstallString": out[key]?.uninstall = value
                default: break
                }
            }
        }
        return out.filter { !$0.value.name.isEmpty }
    }

    /// `"Name"="value"` with .reg escapes undone; nil for other value kinds.
    private static func stringValue(_ line: String) -> (String, String)? {
        guard let split = line.range(of: "\"=\"") else { return nil }
        let name = String(line[line.index(after: line.startIndex)..<split.lowerBound])
        var value = String(line[split.upperBound...])
        guard value.hasSuffix("\"") else { return nil }
        value.removeLast()
        return (name, value.replacingOccurrences(of: "\\\\", with: "\u{1}").replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\u{1}", with: "\\"))
    }

    /// Entries in `after` that `before` did not have, best match for `name` first.
    static func added(before: Set<String>, after: [String: WingetUninstallEntry], name: String) -> [WingetUninstallEntry] {
        let new = after.filter { !before.contains($0.key) }.map(\.value)
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        func hits(_ e: WingetUninstallEntry) -> Int { words.filter { (e.name + " " + e.publisher).lowercased().contains($0) }.count }
        return new.sorted { hits($0) != hits($1) ? hits($0) > hits($1) : $0.key < $1.key }
    }

    /// "C:\Program Files\X" -> "Program Files/X" inside drive_c; nil for another drive.
    static func driveCRelative(_ windowsPath: String) -> String? {
        let p = windowsPath.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard p.count > 3, p.lowercased().hasPrefix("c:\\") else { return nil }
        return String(p.dropFirst(3)).replacingOccurrences(of: "\\", with: "/")
    }

    /// An UninstallString as (program, arguments): `"C:\\X\\unins000.exe" /SILENT`, `C:\\X\\u.exe /S`, `MsiExec.exe /X{GUID}`.
    static func splitCommand(_ command: String) -> (program: String, arguments: String)? {
        let c = command.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return nil }
        if c.hasPrefix("\""), let end = c.dropFirst().firstIndex(of: "\"") {
            return (String(c[c.index(after: c.startIndex)..<end]), String(c[c.index(after: end)...]).trimmingCharacters(in: .whitespaces))
        }
        if let r = c.lowercased().range(of: ".exe") {
            let offset = c.distance(from: c.startIndex, to: r.upperBound)
            let end = c.index(c.startIndex, offsetBy: offset)
            return (String(c[..<end]), String(c[end...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
