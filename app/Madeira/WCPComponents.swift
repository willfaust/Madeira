// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 TimmyTurner51
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// .wcp component packages for Madeira.
//
// A .wcp is a zstd-compressed tar carrying `profile.json` and the component's
// files. DroidDeck and GameNative use it for FEX, DXVK and vkd3d; this file
// teaches Madeira to import the two kinds Madeira can use:
//
//   * FEX  (profile type containing "FEXCore"): libarm64ecfex.dll replaces the
//     ARM64EC module (xtajit64.dll), libwow64fex.dll replaces the WOW64 module
//     (xtajit.dll). Linux-host .so libraries are kept in the package but not
//     linked: Madeira runs the ARM64EC/WOW64 PE modules natively.
//   * Wine (profile type containing "Wine" or "Proton"): DLLs are linked over
//     the matching prefix folder (arm64ec/x86_64 -> system32, aarch64 ->
//     system32 or sysaa64, i386 -> syswow64).
//
// Imported files live in Documents/Components/<id>/, which the app can write.
// WineProcessBridge.m links the enabled packages over the prefix at the start
// of every Windows session, after the bundle's own links, so an imported file
// wins. Nothing in the bundle or the code signature changes.
//
// A FEX module built for Android/Linux cannot run inside Madeira: Madeira's
// FEX is built with the iOS host layer (FEX_IOS_HOST_BUILD). Importing such a
// package is allowed, and it will be reported as a Linux-host package, but the
// module has to be rebuilt from its patches for iOS before it can boot a game.

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers

// MARK: - Errors

enum WCPError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

// MARK: - Component model

/// One imported package. `layout` is what the native bridge reads: a source
/// file inside the package and the prefix folder it replaces.
struct WCPComponent: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case fex
        case wine
        /// A Mach-O half of the runtime that is loaded at launch rather than linked in.
        /// Today that is the Wine unix half (see `UnixHalf`): it stays in the component's
        /// `files/` folder and is `dlopen`ed, so it never enters the prefix's DLL folders,
        /// which only hold PE images.
        case native
        /// PE images that must replace the bundle's own builtins rather than a prefix entry.
        /// `ntdll.dll` is the reason this exists: Wine's loader takes it from `WINEDLLPATH`,
        /// and until now that path was the app bundle, so a changed ntdll meant rebuilding and
        /// reinstalling the app. The package's arch-folder DLLs are staged into the component
        /// folder and that folder is put *in front of* the bundle on `WINEDLLPATH`, so the
        /// import wins and nothing in the bundle or the code signature changes.
        case builtin

        var label: String {
            switch self {
            case .fex: return "FEX"
            case .wine: return "Wine"
            case .native: return "Runtime (Mach-O)"
            case .builtin: return "Wine builtins (PE override)"
            }
        }
    }

    struct LayoutItem: Codable, Equatable {
        /// Path inside the component's folder, e.g. "files/lib/wine/aarch64-windows/libarm64ecfex.dll".
        var source: String
        /// Prefix-relative destination with a folder token, e.g. "${system32}/xtajit64.dll".
        var dest: String
    }

    var id: String
    var name: String
    var kind: Kind
    var type: String
    var versionName: String
    var versionCode: Int?
    var detail: String
    var enabled: Bool
    var installedAt: Double
    var sourceFile: String
    var fileCount: Int
    var layout: [LayoutItem]
    var environment: [String: String]
    var notes: [String]

    var versionLine: String {
        if let versionCode, versionCode > 0 { return "\(versionName) (\(versionCode))" }
        return versionName
    }

    init(
        id: String,
        name: String,
        kind: Kind,
        type: String,
        versionName: String,
        versionCode: Int?,
        detail: String,
        enabled: Bool,
        installedAt: Double,
        sourceFile: String,
        fileCount: Int,
        layout: [LayoutItem],
        environment: [String: String],
        notes: [String]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.type = type
        self.versionName = versionName
        self.versionCode = versionCode
        self.detail = detail
        self.enabled = enabled
        self.installedAt = installedAt
        self.sourceFile = sourceFile
        self.fileCount = fileCount
        self.layout = layout
        self.environment = environment
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        type = try c.decode(String.self, forKey: .type)
        versionName = try c.decode(String.self, forKey: .versionName)
        versionCode = try c.decodeIfPresent(Int.self, forKey: .versionCode)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        installedAt = try c.decodeIfPresent(Double.self, forKey: .installedAt) ?? 0
        sourceFile = try c.decodeIfPresent(String.self, forKey: .sourceFile) ?? ""
        fileCount = try c.decodeIfPresent(Int.self, forKey: .fileCount) ?? 0
        layout = try c.decodeIfPresent([LayoutItem].self, forKey: .layout) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        if let list = try? c.decode([String].self, forKey: .notes) {
            notes = list
        } else if let single = try? c.decode(String.self, forKey: .notes), !single.isEmpty {
            notes = [single]
        } else {
            notes = []
        }
    }
}

// MARK: - Tar reading

/// A streaming reader over the uncompressed tar inside a .wcp. Only regular
/// files are yielded; paths are normalised and checked before the caller uses
/// them. PAX `path`/`size` records and GNU long names are honoured.
struct WCPTarArchive {
    struct Entry {
        let path: String
        let size: UInt64
        let dataOffset: UInt64
    }

    private let handle: FileHandle
    private let fileSize: UInt64

    static func open(_ url: URL) throws -> WCPTarArchive {
        let handle = try FileHandle(forReadingFrom: url)
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        return WCPTarArchive(handle: handle, fileSize: size)
    }

    func close() {
        try? handle.close()
    }

    /// Regular files in archive order. `body` may throw to stop early.
    func forEachFile(_ body: (Entry) throws -> Void) throws {
        var offset: UInt64 = 0
        var longName: String?
        var pax: [String: String] = [:]

        while offset + 512 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 512), header.count == 512 else { break }
            if header.allSatisfy({ $0 == 0 }) { break }   // end-of-archive blocks

            var raw = [UInt8](header)
            guard let storedChecksum = octalValue(raw, 148, 8) else {
                throw WCPError.message("The package's tar header is malformed.")
            }
            for i in 148..<156 { raw[i] = 0x20 }
            let actualChecksum = raw.reduce(UInt64(0)) { $0 + UInt64($1) }
            guard storedChecksum == actualChecksum else {
                throw WCPError.message("The package's tar header checksum does not match.")
            }

            let type = raw[156] == 0 ? "0" : String(UnicodeScalar(raw[156]))
            let size = numericValue(raw, 124, 12) ?? 0
            let dataOffset = offset + 512
            let padded = (size + 511) / 512 * 512

            switch type {
            case "x", "g":
                let data = try read(dataOffset: dataOffset, count: Int(min(size, UInt64(1 << 20))))
                let records = parsePax(data)
                if type == "x" { pax.merge(records) { _, new in new } }
            case "L":
                let data = try read(dataOffset: dataOffset, count: Int(min(size, UInt64(1 << 20))))
                longName = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            case "K":
                break                                        // long link name: not used
            case "0", "\0", "7":
                let headerName = tarName(raw)
                let name = pax["path"] ?? longName ?? headerName
                let entrySize = pax["size"].flatMap { UInt64($0) } ?? size
                if let path = safePath(name) {
                    try body(Entry(path: path, size: entrySize, dataOffset: dataOffset))
                }
                pax.removeAll()
                longName = nil
            default:
                break                                        // directories, links, devices
            }
            offset = dataOffset + padded
        }
    }

    func read(_ entry: Entry, limit: Int) throws -> Data {
        guard entry.size <= UInt64(limit) else {
            throw WCPError.message("A file in the package is larger than expected (\(entry.path)).")
        }
        return try read(dataOffset: entry.dataOffset, count: Int(entry.size))
    }

    /// Copy a file out without holding it in memory.
    func copy(_ entry: Entry, to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var remaining = entry.size
        var offset = entry.dataOffset
        while remaining > 0 {
            let want = Int(min(remaining, 4 << 20))
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                throw WCPError.message("The package ended in the middle of \(entry.path).")
            }
            try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
            offset += UInt64(chunk.count)
        }
    }

    private func read(dataOffset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: dataOffset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw WCPError.message("The package's tar data is truncated.")
        }
        return data
    }
}

// MARK: - Header helpers

private func tarName(_ raw: [UInt8]) -> String {
    func field(_ start: Int, _ length: Int) -> String {
        let slice = raw[start..<min(start + length, raw.count)]
        let bytes = slice.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
    let name = field(0, 100)
    let prefix = field(345, 155)
    return prefix.isEmpty ? name : prefix + "/" + name
}

private func octalValue(_ raw: [UInt8], _ start: Int, _ length: Int) -> UInt64? {
    numericValue(raw, start, length)
}

/// Tar numbers are octal text, but GNU writes large values in base-256 with
/// the top bit of the first byte set.
private func numericValue(_ raw: [UInt8], _ start: Int, _ length: Int) -> UInt64? {
    guard start + length <= raw.count else { return nil }
    let field = Array(raw[start..<(start + length)])
    if let first = field.first, first & 0x80 != 0 {
        var value: UInt64 = UInt64(first & 0x7f)
        for byte in field.dropFirst() { value = (value << 8) | UInt64(byte) }
        return value
    }
    var text = ""
    for byte in field {
        if byte == 0 || byte == 0x20 { if !text.isEmpty { break } else { continue } }
        text.append(Character(UnicodeScalar(byte)))
    }
    return text.isEmpty ? 0 : UInt64(text, radix: 8)
}

private func parsePax(_ data: Data) -> [String: String] {
    var result: [String: String] = [:]
    let bytes = [UInt8](data)
    var i = 0
    while i < bytes.count {
        var j = i
        while j < bytes.count, bytes[j] != 0x20 { j += 1 }
        guard j < bytes.count, let length = Int(String(decoding: bytes[i..<j], as: UTF8.self)),
              length > 0, i + length <= bytes.count else { break }
        let record = bytes[j + 1..<(i + length)]
        if let equals = record.firstIndex(of: 0x3d) {
            let key = String(decoding: record[record.startIndex..<equals], as: UTF8.self)
            var value = String(decoding: record[(equals + 1)...], as: UTF8.self)
            if value.last == "\n" { value.removeLast() }
            result[key] = value
        }
        i += length
    }
    return result
}

/// Reject absolute paths, `..`, empty components and control characters.
private func safePath(_ raw: String) -> String? {
    var path = raw.replacingOccurrences(of: "\\", with: "/")
    while path.hasPrefix("./") { path.removeFirst(2) }
    path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !path.isEmpty, !path.contains("\0"), path.utf8.count < 4096 else { return nil }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
    return path
}

// MARK: - Installer

enum WCPInstaller {
    /// Bounds for a package. Wine farms are a few hundred MB; FEX is a few MB.
    static let maxExpandedBytes: UInt64 = 6 << 30
    static let maxEntryBytes: UInt64 = 2 << 30
    static let maxFileCount = 100_000
    static let maxProfileBytes = 1 << 20

    static func kind(type: String, files: [String]) -> WCPComponent.Kind? {
        let lower = type.lowercased()
        // A Mach-O package declares itself: its files are dylibs rather than PE images, so
        // it is checked before the FEX/Wine inference, which would otherwise misfile it.
        if lower.contains("unixhalf") || lower.contains("native") || lower.contains("unix") { return .native }
        if files.contains(where: { ($0 as NSString).pathExtension.lowercased() == "dylib" }) { return .native }
        // Checked before the FEX/Wine inference: a builtin package carries ordinary DLLs, so
        // without an explicit label it would be filed as a prefix Wine package and linked into
        // system32, where ntdll would never be looked for.
        if lower.contains("builtin") { return .builtin }
        if lower.contains("fex") { return .fex }
        if lower.contains("wine") || lower.contains("proton") { return .wine }
        // Unknown label: infer from what the package carries. A FEX package is
        // recognisable by its module's name, anything else with DLLs is Wine.
        if files.contains(where: { ($0 as NSString).lastPathComponent.lowercased() == "libarm64ecfex.dll" }) { return .fex }
        if files.contains(where: { ["dll", "drv"].contains(($0 as NSString).pathExtension.lowercased()) }) { return .wine }
        return nil
    }

    /// Map the package's files onto prefix folders. The bridge resolves the
    /// tokens: ${system32}, ${syswow64}, ${sysx64}, ${sysaa64}, and
    /// ${aarch64} (system32 in an aarch64 session, sysaa64 in an ARM64EC one).
    static func layout(kind: WCPComponent.Kind, files: [String]) throws -> [WCPComponent.LayoutItem] {
        var items: [WCPComponent.LayoutItem] = []
        var seen: Set<String> = []

        func add(_ source: String, _ dest: String) {
            guard !seen.contains(dest) else { return }
            seen.insert(dest)
            // The staging `payload` directory is moved to
            // Documents/Components/<id>, so its children (`files/...`) sit at
            // the top of the component folder. Recording a "payload/" prefix
            // here pointed every link at a path that does not exist, and the
            // bridge reported the component as failed to link.
            items.append(.init(source: source, dest: dest))
        }

        switch kind {
        case .fex:
            for file in files {
                let base = (file as NSString).lastPathComponent.lowercased()
                switch base {
                case "libarm64ecfex.dll", "xtajit64.dll":
                    // Same farm as an arm64ec-windows Wine package. system32 in an
                    // aarch64 session is the launcher's own arch.
                    add(file, "${sysarm64ec}/xtajit64.dll")
                case "libwow64fex.dll", "xtajit.dll":
                    // Native ARM64 PE. ${aarch64} is system32 in an aarch64 session
                    // and sysaa64 in an ARM64EC one.
                    add(file, "${aarch64}/xtajit.dll")
                default:
                    continue
                }
            }
            guard seen.contains("${sysarm64ec}/xtajit64.dll") else {
                throw WCPError.message("This FEX package has no ARM64EC module (libarm64ecfex.dll).")
            }
        case .wine:
            for file in files {
                let lower = file.lowercased()
                let parts = Set(lower.split(separator: "/").map(String.init))
                let ext = (file as NSString).pathExtension.lowercased()
                guard ["dll", "drv", "cpl"].contains(ext) else { continue }
                let base = (file as NSString).lastPathComponent
                guard !base.isEmpty else { continue }
                if parts.contains("i386-windows") || parts.contains("i386-unix") {
                    add(file, "${syswow64}/" + base)
                } else if parts.contains("aarch64-windows") || parts.contains("arm64-windows") {
                    add(file, "${aarch64}/" + base)
                } else if parts.contains("arm64ec-windows") {
                    // An ARM64EC DLL must land in the farm an ARM64EC process actually
                    // resolves, and that is NOT always system32: an aarch64 session links
                    // its own arch into system32 and puts the EC set in sysx64, so a package
                    // that assumed system32 overwrote the launcher's aarch64 kernel32 with an
                    // EC one and every launch died in the loader with c000007b (no spawn).
                    add(file, "${sysarm64ec}/" + base)
                } else {
                    add(file, "${system32}/" + base)
                }
            }
            guard !items.isEmpty else {
                throw WCPError.message("This Wine package has no Windows libraries (.dll) to link.")
            }
        case .native:
            // Nothing is linked into the prefix: these are Mach-O images, and the prefix only
            // holds PE files. The library keeps its own name inside the component folder, which
            // is where `UnixHalf` looks for it, so a later install replaces it by file name and
            // nothing else in the bundle has to move.
            for file in files where (file as NSString).pathExtension.lowercased() == "dylib" {
                add(file, "files/" + (file as NSString).lastPathComponent)
            }
            guard !items.isEmpty else {
                throw WCPError.message("This runtime package carries no .dylib to load.")
            }
        case .builtin:
            // `pe/<arch>-windows/<name>`, mirroring the bundle's layout so the same
            // `WINEDLLPATH` lookup finds it one directory earlier. The arch folder is taken
            // from the package rather than guessed, and a DLL outside one is refused instead
            // of landing in an arch it was not built for.
            for file in files {
                let parts = Set(file.lowercased().split(separator: "/").map(String.init))
                let base = (file as NSString).lastPathComponent
                guard (file as NSString).pathExtension.lowercased() == "dll", !base.isEmpty else { continue }
                guard let face = ["arm64ec-windows", "aarch64-windows", "i386-windows"].first(where: parts.contains) else {
                    continue // e.g. a Linux .so or a license file
                }
                add(file, "pe/" + face + "/" + base)
            }
            guard !items.isEmpty else {
                throw WCPError.message("This builtin package has no DLL inside an arch folder "
                                       + "(arm64ec-windows, aarch64-windows or i386-windows), "
                                       + "so there would be nothing to put in front of the bundle.")
            }
        }
        return items
    }

    static func componentID(fileName: String, kind: WCPComponent.Kind) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = String(stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return (trimmed.isEmpty ? "component" : trimmed) + "-" + kind.rawValue
    }

    static func environment(from profile: [String: Any]) -> [String: String] {
        let raw = (profile["environment"] as? [String: Any]) ?? (profile["env"] as? [String: Any]) ?? [:]
        var result: [String: String] = [:]
        for (key, value) in raw {
            guard isValidEnvironmentName(key) else { continue }
            if let text = value as? String {
                result[key] = text
            } else if let number = value as? NSNumber {
                result[key] = number.stringValue
            }
        }
        return result
    }

    static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= 255 else { return false }
        let start = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_")
        let rest = start.union(CharacterSet(charactersIn: "0123456789"))
        return start.contains(first) && name.unicodeScalars.dropFirst().allSatisfy { rest.contains($0) }
    }

    static func install(_ package: URL, into root: URL) throws -> WCPComponent {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let staging = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let tar = staging.appendingPathComponent("package.tar")
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let status = tar.withUnsafeFileSystemRepresentation { tarPath in
            package.withUnsafeFileSystemRepresentation { packagePath in
                wcp_zstd_decompress_path(packagePath, tarPath, maxExpandedBytes, nil,
                                         &errorBuffer, errorBuffer.count)
            }
        }
        guard status == 0 else {
            let text = String(cString: errorBuffer)
            throw WCPError.message("The .wcp could not be decompressed: \(text.isEmpty ? "not a zstd file" : text)")
        }

        let archive = try WCPTarArchive.open(tar)
        defer { archive.close() }

        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)

        var profileBytes: Data?
        var files: [String] = []
        var total: UInt64 = 0

        try archive.forEachFile { entry in
            if entry.path == "profile.json" {
                guard entry.size <= UInt64(maxProfileBytes) else {
                    throw WCPError.message("The package's profile.json is too large.")
                }
                profileBytes = try archive.read(entry, limit: maxProfileBytes)
                return
            }
            guard entry.size <= maxEntryBytes else {
                throw WCPError.message("\(entry.path) is larger than Madeira imports from a .wcp.")
            }
            total += entry.size
            guard total <= maxExpandedBytes else {
                throw WCPError.message("The package expands past Madeira's size limit for a component.")
            }
            guard files.count < maxFileCount else {
                throw WCPError.message("The package has more files than Madeira imports from a .wcp.")
            }
            let destination = payload.appendingPathComponent(entry.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try archive.copy(entry, to: destination)
            files.append(entry.path)
        }

        guard let profileBytes,
              let profile = try JSONSerialization.jsonObject(with: profileBytes) as? [String: Any] else {
            throw WCPError.message("The .wcp has no profile.json.")
        }
        let type = (profile["type"] as? String) ?? ""
        guard let kind = kind(type: type, files: files) else {
            throw WCPError.message("The .wcp type “\(type)” is not a FEX or Wine component.")
        }
        let layout = try layout(kind: kind, files: files)

        var notes: [String] = []
        if kind == .fex {
            let linux = files.filter { $0.hasSuffix(".so") }
            if !linux.isEmpty {
                notes.append("\(linux.count) Linux-host librar\(linux.count == 1 ? "y was" : "ies were") left out; Madeira runs the PE modules.")
            }
            if type.lowercased() != "fexcore" {
                notes.append("Built for \(type.isEmpty ? "another host" : type). Madeira needs its own iOS build of FEX, so this module may not start a game.")
            }
        }
        if !(profile["files"] as? [Any] ?? []).isEmpty {
            notes.append("The package's target paths were resolved onto Madeira's DLL folders.")
        }

        let id = componentID(fileName: package.lastPathComponent, kind: kind)
        let destination = root.appendingPathComponent(id, isDirectory: true)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: payload, to: destination)
        try profileBytes.write(to: destination.appendingPathComponent("profile.json"))

        // A builtin package has to be materialised where the loader is told to look,
        // `pe/<arch>-windows/<name>`, whatever path the packager used for the source. A prefix
        // package is only linked, so nothing else is moved.
        if kind == .builtin {
            for item in layout {
                let from = destination.appendingPathComponent(item.source)
                let to = destination.appendingPathComponent(item.dest)
                guard fm.fileExists(atPath: from.path) else { continue }
                try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if from.standardizedFileURL != to.standardizedFileURL {
                    try? fm.moveItem(at: from, to: to)
                }
            }
        }

        let versionName = (profile["versionName"] as? String) ?? (package.deletingPathExtension().lastPathComponent)
        let versionCode = (profile["versionCode"] as? NSNumber)?.intValue
        let detail = (profile["description"] as? String) ?? ""

        return WCPComponent(
            id: id,
            name: versionName,
            kind: kind,
            type: type,
            versionName: versionName,
            versionCode: versionCode,
            detail: detail,
            enabled: true,
            installedAt: Date().timeIntervalSince1970,
            sourceFile: package.lastPathComponent,
            fileCount: files.count,
            layout: layout,
            environment: environment(from: profile),
            notes: notes
        )
    }
}

// MARK: - Builtin override search path

/// Where the app should look for PE builtins *before* the bundle's own copies.
///
/// `WineProcessBridge.m` sets `WINEDLLPATH` to the app bundle, which is how Wine finds
/// `arm64ec-windows/ntdll.dll`. An imported builtin package is staged under
/// `Documents/Components/<id>/pe/`, and putting those directories in front of the bundle on that
/// path is all it takes for the import to win: no bundle file changes, no re-sign, no reinstall.
///
/// Read from `state.json` for the same reason `UnixHalf` does — "enabled" and "kind" must mean
/// the same thing to the installer, the list, and the loader. Only the newest enabled builtin
/// component contributes, so a replacement release takes effect without the previous one having
/// to be removed by hand.
enum BuiltinOverrides {
    static let kind = "builtin"

    /// Colon-separated directories, newest enabled first. Empty when no package is installed.
    static func searchPath() -> String {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return "" }
        let components = docs.appendingPathComponent("Components", isDirectory: true)
        guard let data = try? Data(contentsOf: components.appendingPathComponent("state.json")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = state["components"] as? [[String: Any]] else { return "" }

        let enabled = entries
            .filter { ($0["kind"] as? String) == kind }
            .filter { ($0["enabled"] as? Bool) == true }
            .sorted { ($0["installedAt"] as? Double ?? 0) > ($1["installedAt"] as? Double ?? 0) }

        var paths: [String] = []
        for entry in enabled {
            guard let id = entry["id"] as? String, !id.isEmpty,
                  !id.contains("/"), !id.contains("..") else { continue }
            let pe = components.appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent("pe", isDirectory: true)
            guard fm.fileExists(atPath: pe.path) else { continue }
            paths.append(pe.path)
        }
        return paths.joined(separator: ":")
    }

    /// C entry point for `WineProcessBridge.m`. The string is allocated once and stays valid for
    /// the process; an empty string (not NULL) means "use the bundle alone".
    private static var cached: UnsafePointer<CChar>?

    static func cSearchPath() -> UnsafePointer<CChar> {
        if let cached { return cached }
        let copy = strdup(searchPath()) ?? strdup("")
        cached = UnsafePointer(copy)
        return cached!
    }
}

/// C entry point for `WineProcessBridge.m`; see `BuiltinOverrides`.
@_cdecl("madeira_builtin_override_path")
public func madeiraBuiltinOverridePath() -> UnsafePointer<CChar> {
    BuiltinOverrides.cSearchPath()
}

// MARK: - Model

@MainActor
final class WCPComponentsModel: ObservableObject {
    static let shared = WCPComponentsModel()

    struct State: Codable {
        var version = 1
        var components: [WCPComponent] = []
    }

    @Published private(set) var components: [WCPComponent] = []
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var status: String?

    /// Packages waiting behind the one being installed, in the order the picker
    /// handed them over.
    private var pending: [URL] = []

    /// Documents/Components. WineProcessBridge.m reads state.json here.
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Components", isDirectory: true)
    }

    static var stateFile: URL { root.appendingPathComponent("state.json") }

    static var contentType: UTType {
        UTType(importedAs: "app.madeira.wcp", conformingTo: .data)
    }

    private init() { reload() }

    func reload() {
        guard let data = try? Data(contentsOf: Self.stateFile) else {
            components = []
            return
        }
        do {
            let state = try JSONDecoder().decode(State.self, from: data)
            components = state.components.sorted { $0.installedAt > $1.installedAt }
        } catch {
            // Never silently wipe a corrupt state.json on the next save: preserve a backup
            // and surface the decode error in the log.
            let backup = Self.root.appendingPathComponent("state.corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? data.write(to: backup, options: .atomic)
            LogStore.shared.log("[wcp] state.json decode failed (backed up to state.corrupt.json): \(error.localizedDescription)")
            components = []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            let state = State(components: components)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: Self.stateFile, options: .atomic)
        } catch {
            self.error = "Could not save the component list: \(error.localizedDescription)"
        }
    }

    func report(_ error: Error) {
        self.error = error.localizedDescription
    }

    /// Queues packages the picker returned. Installing is serial, so a second
    /// selection waits for the first to finish instead of being dropped by the
    /// `busy` guard.
    func install(from sources: [URL]) {
        guard !sources.isEmpty else { return }
        pending.append(contentsOf: sources)
        drainPending()
    }

    private func drainPending() {
        guard !busy, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        if !pending.isEmpty {
            status = "Installing \(next.lastPathComponent) — \(pending.count) more queued."
        }
        install(from: next)
    }

    func install(from source: URL) {
        guard !busy else { return }
        error = nil
        status = nil
        busy = true

        let accessed = source.startAccessingSecurityScopedResource()
        // The picker now asks for plain `data`, so the user can pick any file.
        // A zstd frame starts with 28 B5 2F FD; say so plainly instead of
        // letting the tar reader report a malformed header later.
        var head = Data()
        if let handle = try? FileHandle(forReadingFrom: source) {
            head = (try? handle.read(upToCount: 4)) ?? Data()
            try? handle.close()
        }
        if [UInt8](head) != [0x28, 0xB5, 0x2F, 0xFD] {
            if accessed { source.stopAccessingSecurityScopedResource() }
            busy = false
            error = "\(source.lastPathComponent) is not a .wcp package (no zstd header). Pick the .wcp itself, or use Import DLL or folder."
            drainPending()
            return
        }
        // Keep the original file name: the component id is derived from it, so a
        // package imported twice replaces itself instead of stacking up copies.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wcp-" + UUID().uuidString, isDirectory: true)
        let name = source.lastPathComponent.isEmpty ? "package.wcp" : source.lastPathComponent
        let temporary = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: temporary)
        } catch {
            if accessed { source.stopAccessingSecurityScopedResource() }
            try? FileManager.default.removeItem(at: folder)
            busy = false
            report(WCPError.message("Could not read the .wcp: \(error.localizedDescription)"))
            drainPending()
            return
        }
        if accessed { source.stopAccessingSecurityScopedResource() }

        let root = Self.root
        let fileName = name
        Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                var component = try WCPInstaller.install(temporary, into: root)
                component.sourceFile = fileName
                let finished = component
                await MainActor.run { WCPComponentsModel.shared.installed(finished) }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { WCPComponentsModel.shared.failed(message) }
            }
        }
    }

    // MARK: - Import paths that avoid the document picker
    //
    // iOS 26/27's Files sheet intermittently stops delivering taps: the .wcp
    // cell highlights but never opens, and the sheet's Open button does nothing.
    // The picker is the OS's, not ours, so the only fix on our side is to offer
    // ways in that never present it. Both below end in the same installer.

    /// Folder scanned by "Scan Import folder". It sits in the app's Documents,
    /// so it appears as "On My iPhone › Madeira › Import" in Files wherever the
    /// app is installed normally (LiveContainer keeps it inside its own
    /// container, where the link or a share-sheet hand-off is the way in).
    static var inbox: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Import", isDirectory: true)
    }

    /// `.wcp` files waiting in `inbox`, newest first.
    static func waitingPackages() -> [URL] {
        let fm = FileManager.default
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
        }
        return items
            .filter { $0.pathExtension.lowercased() == "wcp" }
            .sorted { modified($0) > modified($1) }
    }

    /// Installs the newest package in `inbox`.
    func importWaitingPackages() {
        guard !busy else { return }
        let waiting = Self.waitingPackages()
        guard let newest = waiting.first else {
            error = "No .wcp in Madeira's Import folder. Copy one there from Files (On My iPhone › Madeira › Import), then scan again."
            return
        }
        status = waiting.count > 1
            ? "Installing \(newest.lastPathComponent) — \(waiting.count - 1) more waiting."
            : "Installing \(newest.lastPathComponent)…"
        install(from: newest)
    }

    /// Installs everything waiting in the Import folder, then moves each package aside.
    ///
    /// This is the launch-time entry point, and it exists so a component release needs no
    /// UI interaction: push a `.wcp` into `Documents/Import`, launch, and it is installed.
    /// Packages are moved into `Import/installed/` before installing rather than deleted, so
    /// a failed install can be retried by moving one back, and a successful one is never
    /// scanned twice.
    func installInboxAtLaunch() {
        let fm = FileManager.default
        let waiters = Self.waitingPackages()
        guard !waiters.isEmpty else { return }
        let done = Self.inbox.appendingPathComponent("installed", isDirectory: true)
        try? fm.createDirectory(at: done, withIntermediateDirectories: true)
        var consumed: [URL] = []
        for url in waiters {
            let destination = done.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: destination)
            if (try? fm.moveItem(at: url, to: destination)) != nil { consumed.append(destination) }
        }
        LogStore.shared.log("[wcp] \(consumed.count) package(s) waiting in Import; installing")
        guard !consumed.isEmpty else { return }
        install(from: consumed)
    }

    /// Downloads a `.wcp` over http(s) and installs it. Needs no file access at
    /// all, which makes it the reliable path when the Files sheet is stuck.
    func install(remote link: String) {
        guard !busy else { return }
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            error = "Enter an http:// or https:// link to a .wcp file."
            return
        }
        error = nil
        busy = true
        status = "Downloading \(url.lastPathComponent.isEmpty ? "package" : url.lastPathComponent)…"
        LogStore.shared.log("[wcp] download start \(trimmed)")

        let root = Self.root
        Task.detached(priority: .userInitiated) {            let fm = FileManager.default
            let folder = fm.temporaryDirectory.appendingPathComponent("wcp-" + UUID().uuidString, isDirectory: true)
            defer { try? fm.removeItem(at: folder) }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let (downloaded, response) = try await URLSession.shared.download(from: url)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw WCPError.message("The server answered \(http.statusCode). Check the link.")
                }
                let name = url.lastPathComponent.isEmpty ? "package.wcp" : url.lastPathComponent
                let package = folder.appendingPathComponent(name)
                try fm.moveItem(at: downloaded, to: package)

                // A zstd frame starts with 28 B5 2F FD. Catching a wrong link
                // here reads better than "the tar header is malformed" later.
                let handle = try FileHandle(forReadingFrom: package)
                defer { try? handle.close() }
                let head = try handle.read(upToCount: 4) ?? Data()
                guard [UInt8](head) == [0x28, 0xB5, 0x2F, 0xFD] else {
                    throw WCPError.message("That link did not return a .wcp package (no zstd header).")
                }

                var component = try WCPInstaller.install(package, into: root)
                component.sourceFile = name
                let finished = component
                await MainActor.run { WCPComponentsModel.shared.installed(finished) }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { WCPComponentsModel.shared.failed(message) }
            }
        }
    }

    /// Reads a link from the pasteboard, so a URL copied on a PC only needs one
    /// tap on the phone.
    func pasteRemoteLink() -> String? {
        #if canImport(UIKit)
        let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.lowercased().hasPrefix("http") ? text : nil
        #else
        return nil
        #endif
    }

    /// Import DLLs or a folder straight from Files, without a `.wcp` wrapper.    /// The files go into the same `payload` layout the package importer uses,
    /// so the bridge does not need a second format.
    func installManual(from sources: [URL], kind: WCPComponent.Kind) {
        guard !busy, !sources.isEmpty else { return }
        error = nil
        status = nil
        busy = true

        let root = Self.root
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let staging = fm.temporaryDirectory
                .appendingPathComponent("manual-" + UUID().uuidString, isDirectory: true)
            let payload = staging.appendingPathComponent("payload", isDirectory: true)
            var scoped: [URL] = []
            defer {
                for url in scoped { url.stopAccessingSecurityScopedResource() }
                try? fm.removeItem(at: staging)
            }
            do {
                try fm.createDirectory(at: payload, withIntermediateDirectories: true)
                var files: [String] = []
                var total: UInt64 = 0

                for source in sources {
                    if source.startAccessingSecurityScopedResource() { scoped.append(source) }
                    let name = source.lastPathComponent
                    guard !name.isEmpty else { continue }
                    let directory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if directory {
                        guard let walker = fm.enumerator(at: source,
                                                         includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
                        else { continue }
                        for case let file as URL in walker {
                            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                            guard values.isRegularFile == true else { continue }
                            let relative = file.path.replacingOccurrences(of: source.path + "/", with: "")
                            guard !relative.isEmpty, !relative.hasPrefix("..") else { continue }
                            let entry = name + "/" + relative
                            total += UInt64(values.fileSize ?? 0)
                            guard total <= WCPInstaller.maxExpandedBytes,
                                  files.count < WCPInstaller.maxFileCount else {
                                throw WCPError.message("The selected files are larger than Madeira imports for a component.")
                            }
                            let destination = payload.appendingPathComponent(entry)
                            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
                            try fm.copyItem(at: file, to: destination)
                            files.append(entry)
                        }
                    } else {
                        let values = try source.resourceValues(forKeys: [.fileSizeKey])
                        total += UInt64(values.fileSize ?? 0)
                        guard total <= WCPInstaller.maxExpandedBytes,
                              files.count < WCPInstaller.maxFileCount else {
                            throw WCPError.message("The selected files are larger than Madeira imports for a component.")
                        }
                        try fm.copyItem(at: source, to: payload.appendingPathComponent(name))
                        files.append(name)
                    }
                }
                guard !files.isEmpty else { throw WCPError.message("No files were selected.") }

                let layout = try WCPInstaller.layout(kind: kind, files: files)
                let title = sources.count == 1
                    ? sources[0].deletingPathExtension().lastPathComponent
                    : "\(kind.label) component (\(files.count) files)"
                let version = title.isEmpty ? kind.label : title
                let type = kind == .fex ? "FEXCore" : "Wine"
                let profile: [String: Any] = [
                    "type": type,
                    "versionName": version,
                    "versionCode": 0,
                    "description": "Imported directly from Files.",
                    "files": []
                ]
                let profileData = try JSONSerialization.data(withJSONObject: profile,
                                                             options: [.prettyPrinted, .sortedKeys])
                let id = "manual-" + kind.rawValue + "-" + UUID().uuidString.prefix(8).lowercased()
                let destination = root.appendingPathComponent(id, isDirectory: true)
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                try fm.moveItem(at: payload, to: destination)
                try profileData.write(to: destination.appendingPathComponent("profile.json"))

                var notes: [String] = []
                if kind == .fex {
                    notes.append("Imported directly. This must be a FEX module built for Madeira's iOS host; an Android or Linux DLL will not boot a game.")
                } else {
                    notes.append("Libraries outside an architecture folder go to system32. Select a folder such as aarch64-windows or i386-windows to map another architecture.")
                }

                let component = WCPComponent(
                    id: id,
                    name: version,
                    kind: kind,
                    type: type,
                    versionName: version,
                    versionCode: 0,
                    detail: "Imported directly from Files.",
                    enabled: true,
                    installedAt: Date().timeIntervalSince1970,
                    sourceFile: sources.map(\.lastPathComponent).joined(separator: ", "),
                    fileCount: files.count,
                    layout: layout,
                    environment: [:],
                    notes: notes)
                let finished = component
                await MainActor.run { WCPComponentsModel.shared.manualInstalled(finished) }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { WCPComponentsModel.shared.failed(message) }
            }
        }
    }

    private func manualInstalled(_ component: WCPComponent) {
        components.insert(component, at: 0)
        save()
        busy = false
        error = nil
        status = "Imported \(component.versionLine). It applies the next time a game starts."
        LogStore.shared.log("[wcp] imported \(component.id) type=\(component.type) files=\(component.fileCount) links=\(component.layout.count)")
    }

    private func installed(_ component: WCPComponent) {
        // A re-import keeps the previous enabled choice.
        if let old = components.first(where: { $0.id == component.id }) {
            var merged = component
            merged.enabled = old.enabled
            components.removeAll { $0.id == component.id }
            components.insert(merged, at: 0)
        } else {
            components.insert(component, at: 0)
        }
        save()
        if component.kind == .native, component.enabled, !UnixHalf.componentLoaded {
            UnixHalf.install()
        }
        busy = false
        error = nil
        status = "Imported \(component.versionLine). It applies the next time a game starts."
        LogStore.shared.log("[wcp] imported \(component.id) type=\(component.type) files=\(component.fileCount) links=\(component.layout.count)")
        drainPending()
    }

    private func failed(_ message: String) {
        busy = false
        error = message
        LogStore.shared.log("[wcp] import failed: \(message)")
        drainPending()
    }

    func setEnabled(_ component: WCPComponent, _ enabled: Bool) {
        guard let index = components.firstIndex(where: { $0.id == component.id }) else { return }
        components[index].enabled = enabled
        save()
        LogStore.shared.log("[wcp] \(component.id) \(enabled ? "enabled" : "disabled")")
    }

    func remove(_ component: WCPComponent) {
        components.removeAll { $0.id == component.id }
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(component.id, isDirectory: true))
        save()
        status = "Removed \(component.versionLine)."
        LogStore.shared.log("[wcp] removed \(component.id)")
    }

    /// Whether a component's environment lines will be exported.
    var environmentCount: Int {
        components.filter(\.enabled).reduce(0) { $0 + $1.environment.count }
    }
}

// MARK: - Settings › Windows components

struct ComponentsSettingsSection: View {
    @ObservedObject private var model = WCPComponentsModel.shared
    /// What the one shared file importer is currently collecting.
    ///
    /// SwiftUI drives a single presentation per view node, so two stacked
    /// `.fileImporter` modifiers on the same view fight over that slot: the
    /// `isPresented` flag flips but the picker's completion never fires. Both
    /// buttons below therefore share one importer and switch behavior here.
    private enum ImportTarget {
        case package
        case payload

        var contentTypes: [UTType] {
            switch self {
            case .package: return [.data]
            case .payload: return [.data, .folder]
            }
        }
    }

    @State private var importTarget: ImportTarget?
    @State private var pendingFiles: [URL] = []
    @State private var choosingKind = false
    @State private var removing: WCPComponent?
    @State private var remoteLink = ""

    var body: some View {
        Section {
            if model.components.isEmpty {
                LabeledContent("Imported components", value: "None")
            }
            ForEach(model.components) { component in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(component.versionLine).font(.body)
                        Spacer()
                        Text(component.kind.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if !component.detail.isEmpty {
                        Text(component.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Text("\(component.layout.count) file\(component.layout.count == 1 ? "" : "s") linked"
                         + (component.environment.isEmpty ? "" : " · \(component.environment.count) environment variables"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Toggle("Enabled", isOn: Binding(
                        get: { component.enabled },
                        set: { model.setEnabled(component, $0) }))
                    if !component.notes.isEmpty {
                        ForEach(component.notes, id: \.self) { note in
                            Text(note).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Button("Remove", role: .destructive) { removing = component }
                        .font(.caption)
                }
                .padding(.vertical, 2)
            }
            Button {
                importTarget = .package
            } label: {
                Label("Import .wcp", systemImage: "square.and.arrow.down")
            }
            .disabled(model.busy)
            DisclosureGroup("Files sheet not responding?") {
                TextField("https://example.com/component.wcp", text: $remoteLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                HStack {
                    Button {
                        model.install(remote: remoteLink)
                    } label: {
                        Label("Install from link", systemImage: "link")
                    }
                    .disabled(model.busy || remoteLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("Paste") {
                        if let link = model.pasteRemoteLink() { remoteLink = link }
                    }
                    .disabled(model.busy)
                }
                Button {
                    model.importWaitingPackages()
                } label: {
                    Label("Scan Import folder", systemImage: "folder")
                }
                .disabled(model.busy)
                Text("Madeira can install a package without the Files sheet: paste a download link, or copy the .wcp into Madeira's Import folder and scan it. Both avoid the picker, which iOS 26/27 sometimes stops delivering taps to.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                importTarget = .payload
            } label: {
                Label("Import DLL or folder", systemImage: "doc.badge.plus")
            }
            .disabled(model.busy)
            if model.busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Importing…").font(.caption)
                }
            }
            if let status = model.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Windows components (.wcp)")
        } footer: {
            Text("Imports FEX and Wine packages in the DroidDeck and GameNative .wcp format, or individual DLLs and folders from Files. An enabled component replaces the matching runtime files at the start of the next Windows session; the app itself is not modified. FEX must be built with Madeira's iOS host layer; a module built for Android or Linux cannot boot a game.")
        }
        // Exactly one importer for both buttons. Stacking two `.fileImporter`
        // modifiers on one view node makes SwiftUI arbitrate a single
        // presentation slot between them: the flag flips, the sheet appears,
        // and the completion never fires. That is what made Import .wcp look
        // dead while Import DLL or folder worked — they were competing.
        .fileImporter(
            isPresented: Binding(
                get: { importTarget != nil },
                set: { if !$0 { importTarget = nil } }
            ),
            allowedContentTypes: (importTarget ?? .package).contentTypes,
            allowsMultipleSelection: true
        ) { result in
            let target = importTarget
            importTarget = nil
            switch result {
            case .success(let urls):
                LogStore.shared.log("[wcp] picker returned \(urls.count) item(s) for \(target == .payload ? "payload" : "package")")
                switch target {
                case .payload:
                    pendingFiles = urls
                    choosingKind = !urls.isEmpty
                default:
                    model.install(from: urls)
                }
            case .failure(let error):
                model.report(error)
            }
        }
        .confirmationDialog("Import as a component", isPresented: $choosingKind, titleVisibility: .visible) {
            Button("FEX module") {
                model.installManual(from: pendingFiles, kind: .fex)
                pendingFiles = []
            }
            Button("Wine libraries") {
                model.installManual(from: pendingFiles, kind: .wine)
                pendingFiles = []
            }
            Button("Cancel", role: .cancel) { pendingFiles = [] }
        } message: {
            Text("FEX takes libarm64ecfex.dll or xtajit64.dll. Wine takes .dll, .drv and .cpl files; a selected folder keeps its architecture names.")
        }
        .confirmationDialog("Remove this component?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            if let removing {
                Button("Remove \(removing.versionLine)", role: .destructive) {
                    model.remove(removing)
                    self.removing = nil
                }
            }
        } message: {
            Text("Its files are deleted from Madeira. Games use the bundled runtime again at the next launch.")
        }
    }
}
