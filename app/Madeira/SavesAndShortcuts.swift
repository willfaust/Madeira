//
//  SavesAndShortcuts.swift
//  Madeira
//
//  Two things players of other Windows game launchers expect:
//
//  * Save backups. A game's progress lives in the Wine prefix (C:\users\...),
//    which a prefix reset, an experiment or a reinstall under another bundle
//    id takes with it. Settings › Saves writes every Windows user's Documents,
//    Saved Games and AppData (caches left out) into one zip to keep in Files
//    or iCloud Drive, and puts one back.
//  * Home Screen shortcuts. madeira://play?exe=<Windows path> starts that game
//    from the library (after JIT, like Play on its details page). Game details
//    copies the link; the Shortcuts app turns it into a Home Screen icon.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Compression
import zlib

// MARK: - Shortcut links

final class ShortcutRouter: ObservableObject {
    static let shared = ShortcutRouter()

    /// A Windows path waiting for the library to launch it.
    @Published var pendingExe: String?

    static func link(for windowsPath: String) -> String {
        var c = URLComponents()
        c.scheme = "madeira"
        c.host = "play"
        c.queryItems = [URLQueryItem(name: "exe", value: windowsPath)]
        return c.string ?? "madeira://play"
    }

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "madeira", url.host?.lowercased() == "play",
              let exe = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "exe" })?.value, !exe.isEmpty else { return }
        LogStore.shared.log("[shortcut] asked to start \(exe)")
        pendingExe = exe
    }
}

// MARK: - Zip writing (stored)

/// Uncompressed zip (saves are small, and many are compressed already). No
/// zip64: the backup stops before 3.5 GB or 65,535 files.
final class SaveZipWriter {
    static let maxEntries = 0xFFFF
    private let handle: FileHandle
    private var central = Data()
    private(set) var count = 0
    private(set) var offset: UInt64 = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    private static func le16(_ v: Int) -> Data { var x = UInt16(truncatingIfNeeded: v).littleEndian; return Data(bytes: &x, count: 2) }
    private static func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }

    func add(name: String, data: Data) throws {
        let n = Data(name.utf8)
        let crc = data.withUnsafeBytes { raw -> UInt32 in
            UInt32(crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count)))
        }
        let size = UInt32(data.count)
        // Version 2.0, UTF-8 names (bit 11), stored, 1980-01-01 00:00.
        var local = Data()
        local += Self.le32(0x0403_4b50); local += Self.le16(20); local += Self.le16(0x0800)
        local += Self.le16(0); local += Self.le16(0); local += Self.le16(0x21)
        local += Self.le32(crc); local += Self.le32(size); local += Self.le32(size)
        local += Self.le16(n.count); local += Self.le16(0); local += n
        var cd = Data()
        cd += Self.le32(0x0201_4b50); cd += Self.le16(20); cd += Self.le16(20); cd += Self.le16(0x0800)
        cd += Self.le16(0); cd += Self.le16(0); cd += Self.le16(0x21)
        cd += Self.le32(crc); cd += Self.le32(size); cd += Self.le32(size)
        cd += Self.le16(n.count); cd += Self.le16(0); cd += Self.le16(0)
        cd += Self.le16(0); cd += Self.le16(0); cd += Self.le32(0)
        cd += Self.le32(UInt32(offset)); cd += n
        try handle.write(contentsOf: local)
        try handle.write(contentsOf: data)
        offset += UInt64(local.count + data.count)
        central += cd
        count += 1
    }

    func finish() throws {
        var end = Data()
        end += Self.le32(0x0605_4b50); end += Self.le16(0); end += Self.le16(0)
        end += Self.le16(count); end += Self.le16(count)
        end += Self.le32(UInt32(central.count)); end += Self.le32(UInt32(offset)); end += Self.le16(0)
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: end)
        try handle.close()
    }
}

// MARK: - Zip reading (stored and deflate, zip64 aware)

/// Reads the backup back, or a zip of the same files made elsewhere (the
/// Files app's Compress writes deflate). The file is memory-mapped, not read.
struct SaveZipReader {
    struct Entry { let name: String; let method: Int; let compressedSize: Int; let size: Int; let localOffset: Int }

    private let data: Data
    let entries: [Entry]

    init(url: URL) throws {
        let b = try Data(contentsOf: url, options: .alwaysMapped)
        data = b
        func fail(_ m: String) -> Error { LibraryError.message(m) }
        func u16(_ o: Int) throws -> Int {
            guard o >= 0, o + 2 <= b.count else { throw fail("The zip is truncated.") }
            return Int(b[b.startIndex + o]) | Int(b[b.startIndex + o + 1]) << 8
        }
        func u32(_ o: Int) throws -> Int { let lo = try u16(o), hi = try u16(o + 2); return lo | hi << 16 }
        func u64(_ o: Int) throws -> Int {
            let lo = try u32(o), hi = try u32(o + 4)
            guard hi < 0x10000 else { throw fail("The zip is too large.") }
            return lo | hi << 32
        }
        guard b.count >= 22 else { throw fail("Not a zip file.") }
        var eocd = -1
        var p = b.count - 22
        let lowest = max(0, b.count - 22 - 65_535)
        while p >= lowest {
            if try u32(p) == 0x0605_4b50 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw fail("Not a zip file.") }
        var count = try u16(eocd + 10)
        var cdOffset = try u32(eocd + 16)
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF {
            let loc = eocd - 20
            guard try u32(loc) == 0x0706_4b50 else { throw fail("Broken zip64 record.") }
            let z = try u64(loc + 8)
            guard try u32(z) == 0x0606_4b50 else { throw fail("Broken zip64 record.") }
            count = try u64(z + 32)
            cdOffset = try u64(z + 48)
        }
        var list: [Entry] = []
        var q = cdOffset
        for _ in 0..<count {
            guard try u32(q) == 0x0201_4b50 else { throw fail("Broken zip directory.") }
            let method = try u16(q + 10)
            var csize = try u32(q + 20)
            var usize = try u32(q + 24)
            let nlen = try u16(q + 28), elen = try u16(q + 30), clen = try u16(q + 32)
            var loff = try u32(q + 42)
            guard q + 46 + nlen <= b.count else { throw fail("The zip is truncated.") }
            let start = b.startIndex + q + 46
            let name = String(decoding: b[start..<(start + nlen)], as: UTF8.self)
            // zip64 extra field: the 0xFFFFFFFF fields, in this order.
            var x = q + 46 + nlen
            let xend = x + elen
            while x + 4 <= xend {
                let id = try u16(x), len = try u16(x + 2)
                if id == 0x0001 {
                    var f = x + 4
                    if usize == 0xFFFF_FFFF { usize = try u64(f); f += 8 }
                    if csize == 0xFFFF_FFFF { csize = try u64(f); f += 8 }
                    if loff == 0xFFFF_FFFF { loff = try u64(f) }
                }
                x += 4 + len
            }
            list.append(Entry(name: name, method: method, compressedSize: csize, size: usize, localOffset: loff))
            q += 46 + nlen + elen + clen
        }
        entries = list
    }

    func extract(_ e: Entry) throws -> Data {
        let b = data
        let o = e.localOffset
        guard o >= 0, o + 30 <= b.count,
              b[b.startIndex + o] == 0x50, b[b.startIndex + o + 1] == 0x4b,
              b[b.startIndex + o + 2] == 0x03, b[b.startIndex + o + 3] == 0x04 else {
            throw LibraryError.message("Broken zip entry \(e.name).")
        }
        let nlen = Int(b[b.startIndex + o + 26]) | Int(b[b.startIndex + o + 27]) << 8
        let elen = Int(b[b.startIndex + o + 28]) | Int(b[b.startIndex + o + 29]) << 8
        let start = o + 30 + nlen + elen
        guard e.compressedSize >= 0, start + e.compressedSize <= b.count else { throw LibraryError.message("The zip is truncated.") }
        let src = b.subdata(in: (b.startIndex + start)..<(b.startIndex + start + e.compressedSize))
        switch e.method {
        case 0:
            return src
        case 8:
            if e.size == 0 { return Data() }
            var out = Data(count: e.size)
            let written: Int = out.withUnsafeMutableBytes { dst in
                src.withUnsafeBytes { s in
                    guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                          let sp = s.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, e.size, sp, s.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == e.size else { throw LibraryError.message("\(e.name) could not be decompressed.") }
            return out
        default:
            throw LibraryError.message("\(e.name) uses zip method \(e.method), which is not supported.")
        }
    }
}

// MARK: - Save backups

enum SaveBackup {
    /// Folders under each C:\users\<name> that hold saves and settings.
    static let roots = ["Documents", "Saved Games", "AppData/Roaming", "AppData/LocalLow", "AppData/Local"]
    /// Folder names that are caches or Windows' own files, never saves.
    static let skipped: Set<String> = ["madeira", "temp", "shadercache", "d3dscache", "nvidia", "microsoft",
                                       "cache", "caches", "crashdumps", "logs", "webcache"]
    static let maxFile = 256 << 20
    static let maxTotal: UInt64 = 3_500 << 20

    struct BackupResult { let url: URL; let files: Int; let bytes: UInt64; let leftOut: Int }

    /// Writes the zip into the temporary directory; entries are named from
    /// drive_c ("users/<name>/Documents/..."), which is where restore puts them.
    static func backup() throws -> BackupResult {
        let fm = FileManager.default
        let drive = LibraryModel.drive
        let users = drive.appendingPathComponent("users", isDirectory: true)
        guard fm.fileExists(atPath: users.path) else { throw LibraryError.message("There is no Windows drive yet.") }
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd_HH-mm"
        let out = fm.temporaryDirectory.appendingPathComponent("Madeira-saves-\(stamp.string(from: Date())).zip")
        try? fm.removeItem(at: out)
        let zip = try SaveZipWriter(url: out)
        var leftOut = 0
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            for root in roots {
                let base = "users/\(user)/\(root)"
                let dir = drive.appendingPathComponent(base, isDirectory: true)
                // Relative paths, so entry names never depend on how the
                // container path is spelled (/var or /private/var).
                guard let e = fm.enumerator(atPath: dir.path) else { continue }
                while let rel = e.nextObject() as? String {
                    let type = e.fileAttributes?[.type] as? FileAttributeType
                    if type == .typeDirectory {
                        if skipped.contains((rel as NSString).lastPathComponent.lowercased()) { e.skipDescendants() }
                        continue
                    }
                    guard type == .typeRegular else { continue }   // links are not followed
                    let size = (e.fileAttributes?[.size] as? NSNumber)?.intValue ?? 0
                    if size > maxFile || zip.offset + UInt64(size) > maxTotal || zip.count >= SaveZipWriter.maxEntries { leftOut += 1; continue }
                    guard let data = try? Data(contentsOf: dir.appendingPathComponent(rel)) else { continue }
                    try zip.add(name: base + "/" + rel, data: data)
                }
            }
        }
        try zip.finish()
        LogStore.shared.log("[saves] backup: \(zip.count) files, \(zip.offset) bytes, \(leftOut) left out")
        return BackupResult(url: out, files: zip.count, bytes: zip.offset, leftOut: leftOut)
    }

    /// Puts a backup's files back (overwriting). Only entries under users/.
    static func restore(from url: URL) throws -> Int {
        let drive = LibraryModel.drive
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let zip = try SaveZipReader(url: url)
        let fm = FileManager.default
        var n = 0
        for e in zip.entries where !e.name.hasSuffix("/") {
            let parts = e.name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, parts[0].lowercased() == "users",
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { continue }
            let dst = parts.reduce(drive) { $0.appendingPathComponent($1) }
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try zip.extract(e).write(to: dst, options: .atomic)
            n += 1
        }
        if n == 0 { throw LibraryError.message("That zip holds no saves (nothing under users/).") }
        LogStore.shared.log("[saves] restored \(n) files from \(url.lastPathComponent)")
        return n
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Settings › Saves.
struct SavesSection: View {
    @State private var busy = false
    @State private var message: String?
    @State private var shareURL: URL?
    @State private var importing = false
    @State private var pendingRestore: URL?

    var body: some View {
        Section {
            Button {
                busy = true
                message = nil
                DispatchQueue.global(qos: .userInitiated).async {
                    let r = Swift.Result { try SaveBackup.backup() }
                    DispatchQueue.main.async {
                        busy = false
                        switch r {
                        case .success(let b):
                            message = "\(b.files) files, \(ByteCountFormatter.string(fromByteCount: Int64(b.bytes), countStyle: .file))"
                                + (b.leftOut > 0 ? "; \(b.leftOut) very large files left out" : "")
                            shareURL = b.url
                        case .failure(let e):
                            message = e.localizedDescription
                        }
                    }
                }
            } label: {
                HStack {
                    Label("Back up saves", systemImage: "externaldrive.badge.icloud")
                    if busy { Spacer(); ProgressView() }
                }
            }
            .disabled(busy)
            Button { importing = true } label: {
                Label("Restore saves from a backup…", systemImage: "arrow.uturn.backward.circle")
            }
            .disabled(busy)
            if let m = message { Text(m).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Saves")
        } footer: {
            Text("A backup is one zip of every Windows user's Documents, Saved Games and AppData (caches left out), "
                 + "to keep in Files or iCloud Drive. Restoring puts those files back and overwrites saves with "
                 + "the same names.")
        }
        .sheet(item: Binding(get: { shareURL.map { SharedFile(url: $0) } }, set: { if $0 == nil { shareURL = nil } })) { f in
            ActivitySheet(items: [f.url])
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { r in
            if case .success(let url) = r { pendingRestore = url }
        }
        .confirmationDialog("Restore saves from \(pendingRestore?.lastPathComponent ?? "the backup")?",
                            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                guard let url = pendingRestore else { return }
                pendingRestore = nil
                busy = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let r = Swift.Result { try SaveBackup.restore(from: url) }
                    DispatchQueue.main.async {
                        busy = false
                        switch r {
                        case .success(let n): message = "\(n) files restored."
                        case .failure(let e): message = e.localizedDescription
                        }
                    }
                }
            }
        } message: {
            Text("Files with the same names in C:\\users are overwritten.")
        }
    }
}
