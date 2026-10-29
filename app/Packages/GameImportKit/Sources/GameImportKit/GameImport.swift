// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Playport's local game importer; see app/Packages/PLAYPORT-SOURCE.md.
// Each job stages on its destination volume. Complete files resume in place;
// one directory rename publishes the game after source and destination checks.

import Foundation
import ContentKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum ImportSource: Sendable, Equatable {
    case folder(URL)
    case zip(URL)

    public var url: URL {
        switch self {
        case let .folder(u), let .zip(u): u
        }
    }

    /// `Celeste` for a folder, `Celeste` for `Celeste.zip`.
    public var baseName: String {
        switch self {
        case let .folder(u): u.lastPathComponent
        case let .zip(u): u.deletingPathExtension().lastPathComponent
        }
    }
}

public struct ImportPlan: Sendable {
    public struct File: Sendable, Equatable, Codable {
        /// Relative, `/`-separated, as it will be under the game's folder.
        public var path: String
        public var size: UInt64
        /// Folder: the path under the source; zip: the entry's path in the archive.
        public var from: String
        public var modified: Double? = nil
    }

    public var source: ImportSource
    /// The folder name the game asks for (the zip's single top folder, else the source's name).
    public var name: String
    public var files: [File]
    public var directories: [String]
    public var skippedSymlinks: Int
    public var totalBytes: UInt64 { files.reduce(0) { $0 + $1.size } }
}

public enum ImportError: Error, Equatable, CustomStringConvertible {
    case empty
    case notDownloaded(Int)
    case refused(String)
    case insufficientSpace(needed: UInt64, available: UInt64)

    public var description: String {
        switch self {
        case .empty: "There is nothing to import there."
        case let .notDownloaded(n): "\(n) of its files are still in iCloud. Download the folder in Files first."
        case let .refused(why): "Madeira can't import this: \(why)"
        case let .insufficientSpace(needed, available):
            "Not enough free space: \(ByteCountFormatter.string(fromByteCount: Int64(clamping: needed), countStyle: .file)) needed, \(ByteCountFormatter.string(fromByteCount: Int64(clamping: available), countStyle: .file)) free."
        }
    }
}

public struct GameImporter: Sendable {
    public let layout: InstallLayout
    /// Free space kept beyond what is left to copy: this fraction of it, plus `reserveBytes`.
    public var marginFraction = 0.05
    public var reserveBytes: UInt64 = 256 << 20
    /// The volume query; tests substitute a fixed figure.
    public var freeSpace: @Sendable (URL) throws -> UInt64 = { try InstallFS.availableCapacity($0) }
    /// Whether a folder at the first URL clones into the stage at the second; tests substitute an answer.
    public var clonesInto: @Sendable (URL, URL) -> Bool = { GameImporter.sameVolume($0, $1) }
    /// One file's clone; tests substitute one.
    var cloneFile: @Sendable (URL, URL) -> Bool = { GameImporter.clone($0, $1) }

    public var validateDestination: @Sendable () throws -> Void = {}

    public init(layout: InstallLayout) {
        self.layout = layout
    }

    public struct Progress: Sendable {
        public var bytesDone: UInt64
        public var bytesTotal: UInt64
        public var filesDone: Int
        public var filesTotal: Int
    }

    // MARK: the plan

    public static func plan(_ source: ImportSource) throws -> ImportPlan {
        switch source {
        case let .folder(url): try planFolder(url)
        case let .zip(url): try planZip(url)
        }
    }

    static func planFolder(_ root: URL) throws -> ImportPlan {
        var files: [ImportPlan.File] = [], dirs: [String] = []
        var symlinks = 0, placeholders = 0
        var seen = Set<String>()
        func walk(_ dir: URL, _ rel: [String]) throws {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            for name in names {
                if name == ".DS_Store" { continue }
                if name.hasPrefix("."), name.hasSuffix(".icloud") { placeholders += 1; continue }
                let url = dir.appendingPathComponent(name)
                var st = stat()
                guard lstat(url.path, &st) == 0 else { throw ImportError.refused("\(name) cannot be read") }
                let kind = st.st_mode & S_IFMT
                if kind == S_IFLNK { symlinks += 1; continue }
                let path = rel + [name]
                do { try WindowsName.check(path: path, seen: &seen) } catch { throw ImportError.refused("\(error)") }
                if kind == S_IFDIR {
                    dirs.append(path.joined(separator: "/"))
                    try walk(url, path)
                } else if kind == S_IFREG {
                    let p = path.joined(separator: "/")
                    files.append(.init(path: p, size: UInt64(st.st_size), from: p, modified: try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970))
                }
            }
        }
        try walk(root, [])
        if placeholders > 0 { throw ImportError.notDownloaded(placeholders) }
        guard !files.isEmpty else { throw ImportError.empty }
        return ImportPlan(source: .folder(root), name: root.lastPathComponent, files: files, directories: dirs,
                          skippedSymlinks: symlinks)
    }

    static func planZip(_ url: URL) throws -> ImportPlan {
        let zip: ZipArchive
        do { zip = try ZipArchive(url: url) } catch { throw ImportError.refused("it is not a zip Madeira can read (\(error))") }
        var entries: [(parts: [String], entry: ZipArchive.Entry)] = []
        var symlinks = 0
        for e in zip.entries {
            if e.isSymlink { symlinks += 1; continue }
            let parts = e.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            guard !parts.isEmpty, !e.path.hasPrefix("/") else { throw ImportError.refused("\(e.path) is not a relative path") }
            if parts.first == "__MACOSX" || parts.last == ".DS_Store" { continue }
            if e.encrypted { throw ImportError.refused("\(e.path) is encrypted") }
            if !e.isDirectory, e.method != 0, e.method != 8 {
                throw ImportError.refused("\(e.path) uses \(ZipArchive.methodName(e.method)) compression; only stored and deflate are supported")
            }
            entries.append((parts, e))
        }
        // One folder at the top holding everything: that is the game's folder.
        var name = url.deletingPathExtension().lastPathComponent
        let tops = Set(entries.map { $0.parts[0] })
        if tops.count == 1, let top = tops.first,
           entries.allSatisfy({ $0.parts.count > 1 || $0.entry.isDirectory }) {
            name = top
            entries = entries.compactMap { $0.parts.count > 1 ? (Array($0.parts.dropFirst()), $0.entry) : nil }
        }
        var files: [ImportPlan.File] = [], dirs = Set<String>()
        var seen = Set<String>()
        for (parts, e) in entries {
            for i in 1..<max(1, parts.count) { dirs.insert(parts[0..<i].joined(separator: "/")) }
            if e.isDirectory {
                dirs.insert(parts.joined(separator: "/"))
                continue
            }
            do { try WindowsName.check(path: parts, seen: &seen) } catch { throw ImportError.refused("\(error)") }
            files.append(.init(path: parts.joined(separator: "/"), size: e.size, from: e.path))
        }
        for d in dirs {
            do { for c in d.split(separator: "/") { try WindowsName.check(String(c)) } } catch { throw ImportError.refused("\(error)") }
            if seen.contains(d.lowercased()) { throw ImportError.refused("\(d) is both a file and a folder") }
        }
        guard !files.isEmpty else { throw ImportError.empty }
        return ImportPlan(source: .zip(url), name: name, files: files.sorted { $0.path < $1.path }, directories: dirs.sorted(),
                          skippedSymlinks: symlinks)
    }

    /// `name`, or `name 2`, `name 3`…: not a folder in C:\Games yet (without case), nor one of `taken`.
    public static func uniqueFolder(_ name: String, existing: [String], taken: [String] = []) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix(".") { base.removeLast() }
        if (try? WindowsName.check(base)) == nil || base.hasPrefix(".") { base = "Game" }
        let used = Set((existing + taken).map { $0.lowercased() })
        if !used.contains(base.lowercased()) { return base }
        var n = 2
        while used.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: the copy

    public func stage(folder: String) -> URL {
        layout.stagingRoot.appendingPathComponent(".stage-import-\(folder)", isDirectory: true)
    }

    /// Copies `plan` into the stage, then into `Games/<folder>`, and writes the receipt.
    /// Throws `CancellationError` when the task is cancelled; the stage is kept for a resume.
    public func run(_ plan: ImportPlan, folder: String, now: Date = Date(),
                    progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> StoreReceipt {
        try WindowsName.check(folder)
        guard !folder.hasPrefix(".") else { throw ImportError.refused("invalid destination folder") }
        let fm = FileManager.default
        try validateDestination()
        try InstallFS.makeDirectory(layout.gamesRoot)
        try InstallFS.makeDirectory(layout.stateRoot)
        let manifest = layout.stateRoot.appendingPathComponent("import-" + folder + ".json")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let values = try plan.source.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let sourceID = plan.source.url.standardizedFileURL.absoluteString + "|" + String(values.contentModificationDate?.timeIntervalSince1970 ?? 0) + "|" + String(values.fileSize ?? 0)
        let identity = Data(sourceID.utf8) + (try encoder.encode(plan.files))
        if fm.fileExists(atPath: manifest.path), try Data(contentsOf: manifest) != identity {
            throw ImportError.refused("the source changed; choose a new import instead of resuming")
        }
        try identity.write(to: manifest, options: .atomic)
        let final = layout.gamesRoot.appendingPathComponent(folder, isDirectory: true)
        guard !fm.fileExists(atPath: final.path) else { throw ImportError.refused("C:\\Games\\\(folder) already exists") }
        let stage = self.stage(folder: folder)
        try InstallFS.makeDirectory(stage)
        for d in plan.directories { try InstallFS.makeDirectory(try InstallFS.resolveInside(stage, d, createParents: true)) }
        // What is in place already (a resumed import) is not copied again.
        var done: UInt64 = 0, filesDone = 0
        var todo: [ImportPlan.File] = []
        for f in plan.files {
            let at = try InstallFS.resolveInside(stage, f.path, createParents: true)
            if InstallFS.fileSize(at) == f.size { done += f.size; filesDone += 1 } else { todo.append(f) }
        }
        let left = plan.totalBytes - done
        var clones = false
        if case let .folder(root) = plan.source { clones = clonesInto(root, stage) }
        try checkSpace(toCopy: clones ? 0 : left)
        let total = plan.totalBytes, count = plan.files.count
        progress(Progress(bytesDone: done, bytesTotal: total, filesDone: filesDone, filesTotal: count))
        var zip: ZipArchive?
        if case let .zip(u) = plan.source { zip = try ZipArchive(url: u) }
        let byPath = Dictionary((zip?.entries ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var lastReport = Date()
        for f in todo {
            try validateDestination()
            try Task.checkCancellation()
            let dst = try InstallFS.resolveInside(stage, f.path, createParents: true)
            let part = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).part")
            try? fm.removeItem(at: part)
            var copied: UInt64 = 0
            let tick: (UInt64) throws -> Void = { n in
                copied += n
                if Date().timeIntervalSince(lastReport) >= 0.5 {
                    lastReport = Date()
                    progress(Progress(bytesDone: done + copied, bytesTotal: total, filesDone: filesDone, filesTotal: count))
                }
                if Task.isCancelled { throw CancellationError() }
            }
            switch plan.source {
            case let .folder(root):
                let src = root.appendingPathComponent(f.from)
                if !cloneFile(src, part) {
                    // The check above counted no copy for a clone: this file needs its own.
                    if clones { try checkSpace(toCopy: f.size) }
                    try Self.copy(src, part, tick)
                }
            case .zip:
                guard let zip, let e = byPath[f.from] else { throw ImportError.refused("\(f.from) is no longer in the archive") }
                try Self.write(part) { sink in try zip.extract(e) { buf in try sink(buf); try tick(UInt64(buf.count)) } }
            }
            guard InstallFS.fileSize(part) == f.size else {
                throw ClientError.verificationFailed("\(f.path) copied as \(InstallFS.fileSize(part) ?? 0) bytes, not \(f.size)")
            }
            try validateDestination()
            guard rename(part.path, dst.path) == 0 else { throw ClientError.transport("rename \(f.path) errno \(errno)") }
            done += f.size
            filesDone += 1
        }
        progress(Progress(bytesDone: total, bytesTotal: total, filesDone: count, filesTotal: count))
        try validateDestination()
        guard try encoder.encode(Self.plan(plan.source).files) == encoder.encode(plan.files) else {
            throw ImportError.refused("the source changed while it was being copied")
        }
        guard rename(stage.path, final.path) == 0 else { throw ClientError.transport("rename into C:\\Games errno \(errno)") }
        let receipt = StoreReceipt(store: .local, storeID: folder, name: folder, installDir: folder,
                                   files: plan.files.count, bytes: total, installedAt: now,
                                   importedFrom: plan.source.url.lastPathComponent)
        try layout.saveReceipt(receipt)
        return receipt
    }

    /// Free space for `toCopy` bytes: those, plus `marginFraction` of them, plus `reserveBytes`.
    public func spaceNeeded(toCopy: UInt64) -> UInt64 {
        toCopy + UInt64(Double(toCopy) * marginFraction) + reserveBytes
    }

    func checkSpace(toCopy: UInt64) throws {
        let needed = spaceNeeded(toCopy: toCopy)
        let available = try freeSpace(layout.gamesRoot)
        guard available >= needed else { throw ImportError.insufficientSpace(needed: needed, available: available) }
    }

    /// Cancel: the stage goes.
    public func discard(folder: String) {
        try? FileManager.default.removeItem(at: stage(folder: folder))
    }

    /// Whether a stopped import of `folder` left files to resume from.
    public func hasStage(folder: String) -> Bool {
        FileManager.default.fileExists(atPath: stage(folder: folder).path)
    }

    // MARK: files

    /// Whether `src` and `stage` sit on one volume, where `clone` can work (Apple platforms only;
    /// elsewhere `clone` never does).
    static func sameVolume(_ src: URL, _ stage: URL) -> Bool {
        #if canImport(Darwin)
        var a = stat(), b = stat()
        guard stat(src.path, &a) == 0, stat(stage.path, &b) == 0 else { return false }
        return a.st_dev == b.st_dev
        #else
        return false
        #endif
    }

    /// A clone, where the volume makes one (APFS, the same volume): no space, no time.
    static func clone(_ src: URL, _ dst: URL) -> Bool {
        #if canImport(Darwin)
        return copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0
        #else
        return false
        #endif
    }

    static func copy(_ src: URL, _ dst: URL, _ tick: (UInt64) throws -> Void) throws {
        let fd = sysOpen(src.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
        guard fd >= 0 else { throw ImportError.refused("\(src.lastPathComponent) cannot be read (errno \(errno))") }
        defer { _ = sysClose(fd) }
        try write(dst) { sink in
            let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
            defer { buf.deallocate() }
            while true {
                let n = read(fd, buf.baseAddress, buf.count)
                if n < 0, errno == EINTR { continue }
                guard n >= 0 else { throw ClientError.transport("read \(src.lastPathComponent) errno \(errno)") }
                if n == 0 { return }
                let chunk = UnsafeRawBufferPointer(rebasing: buf[0..<n])
                try sink(chunk)
                try tick(UInt64(n))
            }
        }
    }

    /// Opens `dst` for writing (never through a link), lets `body` fill it, then syncs it.
    static func write(_ dst: URL, _ body: (@escaping (UnsafeRawBufferPointer) throws -> Void) throws -> Void) throws {
        let fd = sysOpen(dst.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ClientError.unsafeContent("cannot create \(dst.lastPathComponent) (errno \(errno))") }
        defer { _ = sysClose(fd) }
        try body { buf in
            var off = 0
            while off < buf.count {
                let n = Glibc_or_Darwin_write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else {
                    if errno == ENOSPC { throw ImportError.insufficientSpace(needed: UInt64(buf.count - off), available: 0) }
                    throw ClientError.transport("write \(dst.lastPathComponent) errno \(errno)")
                }
                off += n
            }
        }
        guard fsync(fd) == 0 else { throw ClientError.transport("fsync \(dst.lastPathComponent) errno \(errno)") }
    }
}

@inline(__always) private func Glibc_or_Darwin_write(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.write(fd, p, n)
    #else
    return Darwin.write(fd, p, n)
    #endif
}

/// The launch record a store left in a game's folder: GOG's `goggame-<id>.info`
/// (its name and primary play task), Epic's `.egstore/*.mancpn`. It says how to
/// start the game, never whose copy it is: a folder Madeira did not install from
/// a store is a Local game (decision 0057, owner 2026-10-06).
