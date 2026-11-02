// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
// The dependency repository's format and which redistributables are skipped follow
// Playport's GOGDependencies (Playport 412de5f, as carried in willfaust/Madeira #479;
// portions copyright the Playport authors, GPL-3.0-or-later).

import Foundation

// GOG's redistributables ("dependencies", docs/GOG.md): a build names ids such as
// "MSVC2017_x64" or "openAL"; GOG's dependency repository says where each one's files
// are and which installer to run. Madeira downloads their files into the game's
// folder (where GOG's offline installers put __redist), and the game's first start
// runs each installer once in the prefix, from the same batch that starts the game
// (LibraryEntry.servicesScript). A redistributable Madeira already provides, or one
// whose installer cannot run here, is downloaded only when the game needs its files.
// Each installer's exit code is kept in C:\madeira-games\gog-setup\<id>.result, so it
// runs once per prefix, for every game that needs it; Repair runs the game's again.
// Log tag: [gog-setup].

/// One redistributable in GOG's dependency repository.
struct GOGDependency: Codable, Equatable, Sendable {
    /// GOG's id, as a build manifest's `dependencies` names it.
    var id: String
    /// GOG's readable name ("Open AL (2.0.7.0)").
    var name: String
    /// The installer, "/"-separated, relative to the game's folder ("__redist/openAL/oalinst.exe");
    /// empty for files GOG places for the game itself (DOSBox, ScummVM): nothing to run.
    var executable: String
    /// The installer's command line, as GOG gives it.
    var arguments: String
    /// The dependency's depot manifest (a content hash).
    var manifest: String
    var size: Int64

    var isProgram: Bool { executable.lowercased().hasSuffix(".exe") }
    var isPackage: Bool { executable.lowercased().hasSuffix(".msi") }

    /// The repository manifest's depots.
    static func parse(_ json: [String: Any]) -> [GOGDependency] {
        (json["depots"] as? [[String: Any]] ?? []).compactMap { depot in
            guard let id = depot["dependencyId"] as? String, (1...64).contains(id.count),
                  let manifest = depot["manifest"] as? String, GOGAPI.isHash(manifest) else { return nil }
            let executable = depot["executable"] as? [String: Any]
            var path = (executable?["path"] as? String ?? "").replacingOccurrences(of: "\\", with: "/")
            if !path.isEmpty, GOGCodec.components(path) == nil { path = "" }
            return GOGDependency(id: id, name: depot["readableName"] as? String ?? id, executable: path,
                                 arguments: (executable?["arguments"] as? String ?? "").replacingOccurrences(of: "\r", with: " ")
                                     .replacingOccurrences(of: "\n", with: " "),
                                 manifest: manifest.lowercased(), size: (depot["size"] as? NSNumber)?.int64Value ?? 0)
        }
    }
}

/// A redistributable's installer that a GOG game's start runs once in the prefix.
struct GOGSetupProgram: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// Relative to the game's folder, "/" separators.
    var executable: String
    var arguments: String
}

/// What the game's page says about one redistributable.
struct GOGSetupNote: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var note: String
}

enum GOGSetup {
    /// DirectX June 2010's DXSETUP: Madeira's own Direct3D (DXMT, D3D12) and audio libraries cover it.
    static let directX = "DirectX"
    /// The .NET Framework installers do not run in Madeira; Wine's own stands in where a game finds it.
    static let dotNetFramework: Set<String> = ["dotNet35", "dotNet35C", "dotNet4", "dotNet4C", "dotNet45", "dotNet46", "dotNet47", "dotNet472",
                                               "dotNet48"]

    /// Visual C++ 2015 to 2022 (one runtime, msvcp140/vcruntime140): Madeira's builds
    /// carry it, and its installer needs Windows Installer, which they do not.
    static func visualCpp2015Plus(_ id: String) -> Bool {
        let lower = id.lowercased()
        return ["msvc2015", "msvc2017", "msvc2019", "msvc2022"].contains { lower.hasPrefix($0) }
    }

    struct Plan: Equatable {
        /// Downloaded into the game's folder (their files, installer or not).
        var download: [GOGDependency] = []
        /// Installers run once in the prefix, in the build's order.
        var run: [GOGSetupProgram] = []
        /// Left out, with the reason (shown on the game's page).
        var notes: [GOGSetupNote] = []
    }

    /// The build's `ids` against GOG's repository. An id named twice counts once.
    static func plan(_ ids: [String], repository: [GOGDependency], hasMsiexec: Bool) -> Plan {
        var plan = Plan()
        var seen = Set<String>()
        for id in ids where seen.insert(id.lowercased()).inserted {
            guard let d = repository.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
                plan.notes.append(GOGSetupNote(id: id, name: id, note: "Not in GOG's list of redistributables"))
                continue
            }
            if d.id.caseInsensitiveCompare(directX) == .orderedSame {
                plan.notes.append(GOGSetupNote(id: d.id, name: d.name, note: "Not needed: Madeira has its own DirectX"))
            } else if visualCpp2015Plus(d.id) {
                plan.notes.append(GOGSetupNote(id: d.id, name: d.name, note: "Not needed: Madeira includes the Visual C++ 2015-2022 runtime"))
            } else if dotNetFramework.contains(d.id) {
                plan.notes.append(GOGSetupNote(id: d.id, name: d.name, note: "Skipped: .NET Framework installers do not run in Madeira"))
            } else if d.executable.isEmpty {
                plan.download.append(d)   // files the game uses from its folder
            } else if d.isProgram || (d.isPackage && hasMsiexec) {
                plan.download.append(d)
                plan.run.append(GOGSetupProgram(id: d.id, name: d.name, executable: d.executable, arguments: d.arguments))
            } else {
                plan.notes.append(GOGSetupNote(id: d.id, name: d.name,
                                               note: d.isPackage ? "Skipped: needs Windows Installer, which this build does not include"
                                                                 : "Skipped: its installer is not a program"))
            }
        }
        return plan
    }

    // MARK: Results in the prefix

    static let resultFolder = "C:\\madeira-games\\gog-setup"

    /// A file name from GOG's id: letters, digits, "-", "_" and "." only.
    static func safeID(_ id: String) -> String {
        String(id.map { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) ? $0 : "_" }).lowercased()
    }

    static func resultPath(_ id: String) -> String { resultFolder + "\\" + safeID(id) + ".result" }

    enum State: Equatable { case pending, done, failed(Int) }

    /// What the result file of `id` says: not run yet, done, or the installer's failing exit code.
    /// 3010 and 1641 (a restart wanted) count as done, as Windows Installer means them.
    static func state(_ id: String, drive: URL) -> State {
        guard let url = hostURL(resultPath(id), drive: drive),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return .pending }
        let code = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        return [0, 3010, 1641].contains(code) ? .done : .failed(code)
    }

    /// Forgets the results of `ids`, so the next start runs those installers again (Repair).
    static func forget(_ ids: [String], drive: URL) {
        for id in ids { if let url = hostURL(resultPath(id), drive: drive) { try? FileManager.default.removeItem(at: url) } }
    }

    static func hostURL(_ windowsPath: String, drive: URL) -> URL? {
        guard windowsPath.uppercased().hasPrefix("C:\\") else { return nil }
        return windowsPath.dropFirst(3).split(separator: "\\").reduce(drive) { $0.appendingPathComponent(String($1)) }
    }

    // MARK: The batch

    /// The batch lines that run the installers not yet run in this prefix, each from
    /// its own folder, recording its exit code; empty when every one has run (or failed:
    /// a failed installer is not retried at every start, only after Repair). The game
    /// starts after them whatever their results. `folder` is the game's folder as a
    /// C:\ path. '%' is doubled because cmd expands it in a batch file.
    static func batchLines(_ programs: [GOGSetupProgram], folder: String, drive: URL) -> [String] {
        func text(_ s: String) -> String {
            s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "%", with: "%%")
        }
        let pending = programs.filter { state($0.id, drive: drive) == .pending && !$0.executable.contains("\"") }
        guard !pending.isEmpty else { return [] }
        var lines = ["if not exist \"\(resultFolder)\" mkdir \"\(resultFolder)\""]
        for (index, program) in pending.enumerated() {
            let exe = folder + "\\" + program.executable.replacingOccurrences(of: "/", with: "\\")
            let dir = LibraryEntry.folder(of: exe)
            let result = resultPath(program.id)
            let label = "gogsetup\(index + 1)"
            lines.append("if exist \"\(result)\" goto \(label)")
            lines.append("echo [gog-setup] running \(text(program.name.replacingOccurrences(of: "\"", with: "")))")
            lines.append("pushd \"\(text(dir))\"")
            let command = exe.lowercased().hasSuffix(".msi")
                ? "C:\\windows\\system32\\msiexec.exe /i \"\(text(exe))\""
                : "\"\(text(exe))\""
            lines.append(program.arguments.isEmpty ? command : command + " " + text(program.arguments))
            // The redirect first: "echo 0> file" would redirect handle 0 instead of writing 0.
            lines.append(">\"\(result)\" echo %ERRORLEVEL%")
            lines.append("popd")
            lines.append(":\(label)")
        }
        return lines
    }
}
