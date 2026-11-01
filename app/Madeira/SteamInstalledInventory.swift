// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Read-only evidence for install-count changes. This never supplies missing
/// games, repairs manifests, changes discovery policy, or establishes ownership.
enum SteamInstalledInventory {
    struct Observation: Sendable {
        let fingerprint: String
        let lines: [String]
    }

    static func observe(drive: URL, previous: [DockGame], current: [DockGame], rememberedCS2: DockGame?) -> Observation {
        let before = Set(previous.map(\.id)), after = Set(current.map(\.id))
        let removedSet = before.subtracting(after)
        let removed = removedSet.sorted(), added = after.subtracting(before).sorted()
        var lines = ["delta added=\(added.prefix(8).map(String.init).joined(separator: ",")) removed=\(removed.prefix(8).map(String.init).joined(separator: ",")) before=\(before.count) after=\(after.count) source=local-manifests ownership=unverified"]
        var candidates = current.filter { $0.id == 730 } + previous.filter { $0.id == 730 }
        if let rememberedCS2 { candidates.append(rememberedCS2) }
        candidates += previous.lazy.filter { removedSet.contains($0.id) }.prefix(4)
        var seen: Set<String> = [], fingerprints: [String] = []
        for candidate in candidates {
            let identity = String(candidate.id) + ":" + candidate.library
            guard seen.insert(identity).inserted else { continue }
            let item = probe(drive: drive, appID: candidate.id, library: candidate.library,
                             recordedDirectory: candidate.installDir, visible: current.contains { $0.id == candidate.id && $0.library.caseInsensitiveCompare(candidate.library) == .orderedSame })
            lines.append(item.line); fingerprints.append(item.fingerprint)
        }
        // Even a cache-free start with no discoverable CS2 record reports the
        // default client manifest, without guessing a game directory.
        if !candidates.contains(where: { $0.id == 730 }) {
            let item = probe(drive: drive, appID: 730, library: SteamRuntimeFiles.relativeRoot + "/steamapps",
                             recordedDirectory: nil, visible: false)
            lines.append(item.line); fingerprints.append(item.fingerprint)
        }
        return Observation(fingerprint: fingerprints.joined(separator: "|"), lines: Array(lines.prefix(7)))
    }

    private static func libraryToken(_ library: String) -> String {
        // A correlation label, not a security hash. Never print volume or
        // account-like path components from secondary/external libraries.
        var value: UInt64 = 14695981039346656037
        for byte in library.lowercased().utf8 { value = (value ^ UInt64(byte)) &* 1099511628211 }
        return String(value, radix: 16)
    }

    private static func manifestBytes(_ file: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: (1 << 20) + 1)
    }

    private static func listed(_ library: String, drive: URL) -> Bool {
        let fm = FileManager.default
        guard let root = [SteamRuntimeFiles.relativeRoot, "Program Files/Steam"].first(where: {
            fm.fileExists(atPath: drive.appendingPathComponent($0 + "/steam.exe").path)
        }) else { return false }
        if library.caseInsensitiveCompare(root + "/steamapps") == .orderedSame { return true }
        let file = drive.appendingPathComponent(root + "/steamapps/libraryfolders.vdf")
        guard let bytes = manifestBytes(file), bytes.count <= 1 << 20,
              var parser = try? SteamKeyValues(bytes), let value = try? parser.read() else { return false }
        return (value["libraryfolders"]?.fields ?? [:]).values.contains { entry in
            guard let path = entry["path"]?.string ?? entry.string,
                  let relative = MadeiraDock.libraryRelative(path) else { return false }
            return relative.caseInsensitiveCompare(library) == .orderedSame
        }
    }

    private static func probe(drive: URL, appID: Int, library: String, recordedDirectory: String?, visible: Bool) -> (line: String, fingerprint: String) {
        let fm = FileManager.default, token = libraryToken(library)
        let components = library.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.count <= 20, components.allSatisfy(MadeiraDock.validFolderName) else {
            return ("app=\(appID) manifest=invalid-library-record library-id=\(token)", "invalid:" + token)
        }
        let manifest = drive.appendingPathComponent(library).appendingPathComponent("appmanifest_\(appID).acf")
        let attributes = try? fm.attributesOfItem(atPath: manifest.path)
        let bytes = manifestBytes(manifest)
        let game = bytes.flatMap { MadeiraDock.game(manifest: $0, library: library) }
        let state: String
        if !fm.fileExists(atPath: manifest.path) { state = "missing" }
        else if bytes == nil { state = "unreadable" }
        else if (bytes?.count ?? 0) > 1 << 20 { state = "oversized" }
        else if let game { state = game.id == appID ? (game.installed ? "ready" : "not-ready") : "appid-mismatch" }
        else { state = "invalid" }
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let milliseconds = ((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000
        let modified = milliseconds.isFinite && abs(milliseconds) < 9_000_000_000_000_000 ? Int64(milliseconds) : 0
        var flags: UInt32?, buildID: UInt64?
        if let bytes, bytes.count <= 1 << 20, var parser = try? SteamKeyValues(bytes), let value = try? parser.read() {
            flags = value["AppState"]?["StateFlags"]?.string.flatMap { UInt32($0) }
            buildID = value["AppState"]?["buildid"]?.string.flatMap { UInt64($0) }
        }
        let directory = (game?.id == appID ? game?.installDir : nil) ?? recordedDirectory
        var folderPresent = false, program = "not-probed"
        if let directory, MadeiraDock.validFolderName(directory) {
            let folder = drive.appendingPathComponent(library).appendingPathComponent("common").appendingPathComponent(directory)
            var isDirectory: ObjCBool = false
            folderPresent = fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
            if appID == 730 {
                var programDirectory: ObjCBool = false
                let exists = fm.fileExists(atPath: folder.appendingPathComponent("game/bin/win64/cs2.exe").path, isDirectory: &programDirectory)
                program = !exists ? "missing" : programDirectory.boolValue ? "directory" : "present"
            }
        }
        let clientListed = listed(library, drive: drive)
        let fingerprint = "\(appID):\(token):\(state):\(size):\(inode):\(modified):\(folderPresent):\(program):\(clientListed):\(visible):\(flags.map(String.init) ?? "unknown"):\(buildID.map(String.init) ?? "unknown")"
        let line = "app=\(appID) scan-visible=\(visible) manifest-now=\(state) library-id=\(token) client-library-listed=\(clientListed) flags=\(flags.map(String.init) ?? "unknown") build=\(buildID.map(String.init) ?? "unknown") bytes=\(size) mtime-ms=\(modified) inode=\(inode) recorded-folder-present=\(folderPresent) expected-program=\(program)"
        return (line, fingerprint)
    }
}
