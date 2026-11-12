// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 David Brookes
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// Adapted from PR #235 for the multiple-drive model in PR #464.
enum ExternalStorageError: Error, LocalizedError {
    case unsafePath, invalidRecord, mappingConflict, identityMismatch, unavailable
    var errorDescription: String? {
        switch self {
        case .unsafePath: return "The requested path leaves the external folder."
        case .invalidRecord: return "The saved external drive registration is invalid."
        case .mappingConflict: return "The external drive mapping is already in use. Existing files were kept."
        case .identityMismatch: return "This is not the registered folder. Select the original folder."
        case .unavailable: return "The external drive is not available. Reconnect it and try again."
        }
    }
}

enum ExternalStorageMapping {
    static func validate(_ link: URL, root: URL, owned: Bool) throws {
        let fm = FileManager.default
        do {
            let attributes = try fm.attributesOfItem(atPath: link.path)
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                throw ExternalStorageError.mappingConflict
            }
            guard owned else { throw ExternalStorageError.mappingConflict }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { }
    }

    static func replace(_ link: URL, root: URL, owned: Bool) throws {
        let fm = FileManager.default
        try validate(link, root: root, owned: owned)
        let temporary = link.deletingLastPathComponent().appendingPathComponent(".madeira-link-" + UUID().uuidString)
        try fm.createSymbolicLink(at: temporary, withDestinationURL: root)
        defer { try? fm.removeItem(at: temporary) }
        guard rename(temporary.path, link.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

enum ExternalStoragePath {
    static func components(_ relative: String) throws -> [String] {
        let normalized = relative.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, normalized.utf8.count < 4096,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  !$0.contains(":") && !$0.unicodeScalars.contains(where: { $0.value < 32 }) }) else {
            throw ExternalStorageError.unsafePath
        }
        return parts
    }

    static func native(_ relative: String, root: URL) throws -> URL {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let parts = try components(relative)
        var candidate = base
        for part in parts {
            candidate.appendPathComponent(part)
            // Resolving a whole nonexistent leaf can leave an existing symlink
            // ancestor unresolved on Darwin. Check each component, including
            // dangling links, before appending the next one.
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw ExternalStorageError.unsafePath
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { }
        }

        return candidate
    }
}

enum ExternalStorageIdentity {
    static let marker = ".madeira-library-id"

    static func verify(_ id: String, root: URL) throws {
        let url = try ExternalStoragePath.native(marker, root: root)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 1024) <= 128,
              try String(contentsOf: url, encoding: .utf8) == id else {
            throw ExternalStorageError.identityMismatch
        }
    }

    static func register(root: URL) throws -> String {
        let url = try ExternalStoragePath.native(marker, root: root)
        // A registration can adopt an existing valid marker, never overwrite it.
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? 1024) <= 128 else {
                throw ExternalStorageError.invalidRecord
            }
            let id = try String(contentsOf: url, encoding: .utf8)
            guard UUID(uuidString: id) != nil else { throw ExternalStorageError.invalidRecord }
            try verify(id, root: root)
            return id
        }
        let id = UUID().uuidString
        try Data(id.utf8).write(to: url, options: .withoutOverwriting)
        return id
    }
}

/// Preserve parsed Steam metadata and add only paths not already registered.
enum ExternalSteamLibraries {
    /// The external-drive entries (`C:\External\...`) that sit above one of `paths`, such as
    /// `C:\External\steam` when the library is `C:\External\steam\SteamLibrary`. A drive
    /// added from its top folder once and later found to hold its library one level down
    /// leaves such an entry behind. Seen on a tester's device (Nov 7 2026): with it listed,
    /// both of the client's libraryfolders.vdf files lacked the real library, the client
    /// did not know the games were there and Dock stopped with code 41
    /// (launch-install-directory-mismatch); swapping the entry for the real library fixed
    /// every game. Only Madeira's own External folder is touched; a listed path that is
    /// itself a library being added stays.
    /// env.MADEIRA_EXTERNAL_PRUNE_PARENT_LIBRARIES = 0 keeps every entry.
    static func staleParents(of paths: [String], in listed: [String]) -> Set<String> {
        let added = Set(paths.map(key))
        var stale: Set<String> = []
        for entry in listed.map(key) where entry.hasPrefix("c:\\external\\") && !added.contains(entry) {
            if added.contains(where: { $0.hasPrefix(entry + "\\") }) { stale.insert(entry) }
        }
        return stale
    }

    /// A library path compared without case, slash style or trailing separators.
    static func key(_ path: String) -> String {
        var text = path.replacingOccurrences(of: "/", with: "\\").lowercased()
        while text.hasSuffix("\\") { text.removeLast() }
        return text
    }

    static func add(paths: [String], to data: Data?, pruneParents: Bool = true) throws -> Data {
        var root: [String: SteamValue] = [:]
        if let data {
            var parser = try SteamKeyValues(data)
            root = try parser.read().fields
            guard case .object? = root["libraryfolders"] else { throw ExternalStorageError.invalidRecord }
        }
        var folders = root["libraryfolders"]?.fields ?? [:]
        guard folders.count < 4096 else { throw ExternalStorageError.invalidRecord }
        let windowsPaths = try paths.map { "C:\\" + (try ExternalStoragePath.components($0)).joined(separator: "\\") }
        if pruneParents {
            let entryPath: (SteamValue) -> String? = { $0["path"]?.string ?? $0.string }
            let stale = staleParents(of: windowsPaths, in: folders.values.compactMap(entryPath))
            if !stale.isEmpty {
                folders = folders.filter { _, value in entryPath(value).map { !stale.contains(key($0)) } ?? true }
            }
        }
        var listed = Set(folders.values.compactMap { ($0["path"]?.string ?? $0.string)?.lowercased() })
        var next = 0
        for path in windowsPaths {
            guard listed.insert(path.lowercased()).inserted else { continue }
            while folders[String(next)] != nil { next += 1 }
            folders[String(next)] = .object(["path": .text(path), "apps": .object([:])])
        }
        root["libraryfolders"] = .object(folders)
        func quote(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func encode(_ fields: [String: SteamValue], indent: String = "") -> String {
            fields.keys.sorted().map { key in
                switch fields[key]! {
                case .text(let value): return indent + quote(key) + "\t" + quote(value) + "\n"
                case .object(let nested): return indent + quote(key) + "\n" + indent + "{\n" + encode(nested, indent: indent + "\t") + indent + "}\n"
                }
            }.joined()
        }
        return Data(encode(root).utf8)
    }
}

enum ExternalInstallTarget {
    static func select(existing: String?, installed: String?, requested: String?, fallback: String) -> String {
        existing ?? installed ?? requested ?? fallback
    }
}
