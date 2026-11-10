// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Game details › Mods: getting a mod into its own folder. A .zip or .7z unpacks with
//  ItchArchive (the itch.io unpacker: every name checked, a .7z a folder at a time),
//  archives inside it too (unpackInner). A .rar unpacks with the libarchive iOS has
//  in /usr/lib, opened at run time: Madeira links nothing for it, and when the
//  library or its .rar reader is missing the person is told plainly to use a .zip or
//  .7z. A folder is copied as it is; a lone plugin or .dll becomes a mod of one file.
//
//  Then ModLayout (ModsCore.swift) finds the mod's own top folder, and a FOMOD
//  installer's choices are turned into the files to install (<mod>/content).
//

import Foundation
import Darwin

// MARK: .rar through the system's libarchive

enum ModRar {
    private typealias New = @convention(c) () -> OpaquePointer?
    private typealias Call = @convention(c) (OpaquePointer?) -> Int32
    private typealias Open = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    private typealias Next = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    private typealias Name = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    private typealias FileType = @convention(c) (OpaquePointer?) -> mode_t
    private typealias Read = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int

    private static let ok: Int32 = 0, eof: Int32 = 1, warn: Int32 = -20
    private static let library = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL)

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let library, let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    /// Whether a file starts like a .rar (RAR 4 or 5).
    static func isRar(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 6)) == Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])
    }

    /// Unpacks a .rar into `destination` (replaced only once every file is in).
    /// `progress` gets the bytes written and the archive's own size, a rough total.
    static func unpack(_ archive: URL, to destination: URL, progress: @escaping (UInt64, UInt64) -> Void = { _, _ in }) throws {
        guard library != nil else { throw ModError.rar("no archive library") }
        guard let new = symbol("archive_read_new", New.self), let free = symbol("archive_read_free", Call.self),
              let open = symbol("archive_read_open_filename", Open.self), let next = symbol("archive_read_next_header", Next.self),
              let pathname = symbol("archive_entry_pathname", Name.self), let filetype = symbol("archive_entry_filetype", FileType.self),
              let read = symbol("archive_read_data", Read.self), let errorString = symbol("archive_error_string", Name.self) else {
            throw ModError.rar("the archive library is missing a part")
        }
        let formats = ["archive_read_support_format_rar", "archive_read_support_format_rar5"].compactMap { symbol($0, Call.self) }
        guard !formats.isEmpty, let reader = new() else { throw ModError.rar("no .rar reader") }
        defer { _ = free(reader) }
        for format in formats { _ = format(reader) }
        func failure(_ fallback: String) -> ModError {
            ModError.rar(errorString(reader).map { String(cString: $0) } ?? fallback)
        }
        guard open(reader, archive.path, 1 << 16) == ok else { throw failure("it could not be opened") }
        let encrypted = symbol("archive_entry_is_encrypted", Call.self)
        let total = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? UInt64) ?? 0
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + ".unpacking", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var done: UInt64 = 0, reported: UInt64 = 0
        var seen = Set<String>()
        do {
            while true {
                try Task.checkCancellation()
                var entry: OpaquePointer?
                let status = next(reader, &entry)
                if status == eof { break }
                guard status >= warn, let entry else { throw failure("it is damaged") }
                if let encrypted, encrypted(entry) > 0 { throw ModError.encrypted }
                let raw = pathname(entry).map { String(cString: $0) } ?? ""
                let type = UInt32(filetype(entry)) & 0o170000
                guard type != 0o120000, let name = ItchArchive.safeName(raw) else { throw ItchArchiveError.unsafeName(raw) }
                let target = staging.appendingPathComponent(name)
                if type == 0o040000 { try fm.createDirectory(at: target, withIntermediateDirectories: true); continue }
                guard type == 0o100000 else { continue }
                guard seen.insert(name.lowercased()).inserted else { throw ItchArchiveError.unsafeName(name) }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: target.path, contents: nil) else { throw ItchArchiveError.damaged("write") }
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(reader, $0.baseAddress, $0.count) }
                    if count == 0 { break }
                    guard count > 0 else { throw failure("it is damaged") }
                    try output.write(contentsOf: Data(buffer[0..<count]))
                    done += UInt64(count)
                    if done - reported >= 4 << 20 { reported = done; progress(done, max(total, done)) }
                }
            }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }
}

// MARK: From a chosen file or folder to an installed mod

/// A mod unpacked into its folder, before it is installed.
struct ModPrepared {
    var id: String
    var name: String
    var files: URL
    var root: URL
    var kind: ModKind
    var config: FomodConfig?
}

enum ModInstaller {
    enum Phase {
        case copying, unpacking(UInt64, UInt64), reading, installing(Int, Int)
    }

    /// <Application Support>/Mods/<game>.
    static func store(_ gameID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mods", isDirectory: true).appendingPathComponent(gameID, isDirectory: true)
    }

    /// Whether `url` is the picker's copy (asCopy puts it in the app's temporary folder or
    /// Documents/Inbox), which may go once the mod is in. Anything else is the person's own.
    static func isPickerCopy(_ url: URL) -> Bool {
        let fm = FileManager.default
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let places = [fm.temporaryDirectory, fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Inbox")]
        return places.contains { path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") }
    }

    private static let looseFiles: Set<String> = ["esp", "esm", "esl", "dll", "asi", "pak", "ini", "bsa", "ba2"]

    /// Copies or unpacks `source` into a new mod folder and reads it. On failure the
    /// mod folder goes again.
    static func prepare(_ source: URL, store: URL, progress: @escaping (Phase) -> Void) throws -> ModPrepared {
        let fm = FileManager.default
        let id = UUID().uuidString
        let modFolder = store.appendingPathComponent(id, isDirectory: true)
        let files = modFolder.appendingPathComponent("files", isDirectory: true)
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        var name = source.deletingPathExtension().lastPathComponent
        do {
            try fm.createDirectory(at: modFolder, withIntermediateDirectories: true)
            if ModPath.isDirectory(source) {
                progress(.copying)
                name = source.lastPathComponent
                try fm.createDirectory(at: files, withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: files.appendingPathComponent(source.lastPathComponent))
            } else if ItchArchive.isZip(source) || ItchArchive.is7z(source) {
                progress(.unpacking(0, 0))
                _ = try ItchArchive.unpackAny(source, to: files) { done, total in progress(.unpacking(done, total)) }
            } else if ModRar.isRar(source) {
                progress(.unpacking(0, 0))
                try ModRar.unpack(source, to: files) { done, total in progress(.unpacking(done, total)) }
            } else if looseFiles.contains(source.pathExtension.lowercased()) {
                progress(.copying)
                try fm.createDirectory(at: files, withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: files.appendingPathComponent(source.lastPathComponent))
            } else {
                throw ModError.unknownFile(source.lastPathComponent)
            }
            // Archives inside the archive: .zip and .7z with ItchArchive, .rar here.
            progress(.reading)
            _ = try ItchArchive.unpackInner(in: files) { done, total in progress(.unpacking(done, total)) }
            try unpackInnerRar(in: files, progress: progress)
            let layout = ModLayout.find(in: files)
            let config = try layout.fomod.map { try FomodConfig.parse(Data(contentsOf: $0)) }
            if let moduleName = config?.moduleName, !moduleName.isEmpty { name = moduleName }
            guard !(try ModPath.files(in: layout.root)).isEmpty else { throw ModError.noFiles }
            return ModPrepared(id: id, name: name, files: files, root: layout.root, kind: layout.kind, config: config)
        } catch {
            try? fm.removeItem(at: modFolder)
            throw error
        }
    }

    /// A .rar within two levels of `folder` unpacks beside itself (into a folder of its
    /// name) and then goes.
    private static func unpackInnerRar(in folder: URL, progress: @escaping (Phase) -> Void) throws {
        let fm = FileManager.default
        var found: [URL] = []
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        if let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                let relative = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(base.count + 1))
                if relative.split(separator: "/").count > 2 { walker.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "rar", isRarFirstPart(url), ModRar.isRar(url) { found.append(url) }
            }
        }
        for archive in found {
            let target = archive.deletingPathExtension()
            let into = fm.fileExists(atPath: target.path) ? target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + " (rar)") : target
            try ModRar.unpack(archive, to: into) { done, total in progress(.unpacking(done, total)) }
            try? fm.removeItem(at: archive)
        }
    }

    /// "x.part2.rar" and the like are read through the first part.
    private static func isRarFirstPart(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        guard let range = stem.range(of: ".part", options: .backwards) else { return true }
        return Int(stem[range.upperBound...]) == 1
    }

    /// Where the mod will go, relative to the game's folder ("" or "Data").
    static func target(_ prepared: ModPrepared, game: ModGame) -> String {
        ModLayout.target(gameFolder: game.gameFolder, content: prepared.root, kind: prepared.kind)
    }

    /// Adds the mod to the game's store (a FOMOD's chosen files copied into <mod>/content)
    /// and turns it on.
    static func install(_ prepared: ModPrepared, choices: FomodChoices?, game: ModGame, store folder: URL,
                        progress: @escaping (Phase) -> Void) throws -> (ModRecord, [String]) {
        let fm = FileManager.default
        let store = ModStore(folder: folder, game: game)
        let modFolder = folder.appendingPathComponent(prepared.id, isDirectory: true)
        let content: String
        do {
            if let choices {
                let plan = try choices.plan(root: prepared.root)
                guard !plan.isEmpty else { throw ModError.noFiles }
                let out = modFolder.appendingPathComponent("content", isDirectory: true)
                try? fm.removeItem(at: out)
                for (n, item) in plan.enumerated() {
                    let file = out.appendingPathComponent(item.destination)
                    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: item.source, to: file)
                    if n % 50 == 0 { progress(.installing(n, plan.count * 2)) }
                }
                // The installer's own files are not needed once its choices are made.
                try? fm.removeItem(at: prepared.files)
                content = prepared.id + "/content"
            } else {
                let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
                let root = prepared.root.resolvingSymlinksInPath().standardizedFileURL.path
                content = root.hasPrefix(base + "/") ? String(root.dropFirst(base.count + 1)) : prepared.id + "/files"
            }
            let into = Self.target(prepared, game: game)
            let record = try store.add(id: prepared.id, name: prepared.name, content: content, target: into,
                                       kind: choices == nil ? prepared.kind : .fomod)
            let offset = choices == nil ? 0 : 1
            try store.enable(record.id) { done, total in progress(.installing(done + offset * total, total * (1 + offset))) }
            return (record, store.notes)
        } catch {
            try? store.remove(prepared.id)
            try? fm.removeItem(at: modFolder)
            throw error
        }
    }

    /// A mod that was unpacked but not installed (Cancel, or a failure).
    static func discard(_ prepared: ModPrepared, store: URL) {
        try? FileManager.default.removeItem(at: store.appendingPathComponent(prepared.id, isDirectory: true))
    }
}
