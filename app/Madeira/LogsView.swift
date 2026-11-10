// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Settings › Logs: every log Madeira keeps, in one place, to read or share.
//
//  Players kept asking where their logs are. They are in Documents, which the
//  Files app shows (On My iPhone/iPad › Madeira), but few people find that,
//  and a whole log carries personal details (PrivacyScrub.swift says which).
//  This page lists them: the session summary, the last log with a game in it,
//  this run's and the previous run's log, and each game session's own log
//  (Documents/logs, LogStore.startSessionLog). Tapping one shows its end;
//  Share sends a copy with personal details taken out.
//
//  Share Logs (here and on Game details) makes one plain "<game> log.txt" for a
//  bug report (get-help-auto): Get Help's short scrubbed report, about 30 KB.
//  The Madeira Discord's bot deletes .zip files, and Discord previews a .txt.
//  LogFiles.bundle (the old .zip) is kept but no button uses it.
//  Nothing is sent anywhere by Madeira itself.
//

import Foundation
import SwiftUI
import zlib

enum LogFiles {
    struct Item: Identifiable, Hashable {
        let url: URL
        let title: String
        var id: String { url.path }
    }

    static var documents: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }

    /// The fixed logs in Documents, then Documents/logs newest first.
    static func items() -> (main: [Item], sessions: [Item]) {
        guard let docs = documents else { return ([], []) }
        let fm = FileManager.default
        var main: [Item] = []
        let game = lastGame(in: docs)
        for (name, title) in [(LogSummary.fileName, "Session summary"),
                              (LogSummary.gameLogName, "Last game log" + (game.map { " (\($0))" } ?? "")),
                              ("madeira-log.txt", "This run's log"),
                              ("madeira-log.prev.txt", "Previous run's log")] {
            let url = docs.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { main.append(Item(url: url, title: title)) }
        }
        let folder = docs.appendingPathComponent("logs", isDirectory: true)
        let sessions = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "txt" }
            .sorted { modified($0) > modified($1) }
            .map { Item(url: $0, title: $0.deletingPathExtension().lastPathComponent) }
        return (main, sessions)
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    static func detail(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return size + " · " + modified(url).formatted(date: .abbreviated, time: .shortened)
    }

    /// The "Program:" line of madeira-summary.txt: the game the last game log is from.
    static func lastGame(in docs: URL) -> String? {
        guard let text = try? String(contentsOf: docs.appendingPathComponent(LogSummary.fileName), encoding: .utf8) else { return nil }
        return text.split(separator: "\n").first { $0.hasPrefix("Program: ") }
            .map { String($0.dropFirst("Program: ".count).prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces) }
    }

    static var shareFolder: URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SharedLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A scrubbed copy to share, under the same name.
    static func scrubbedCopy(of url: URL) throws -> URL {
        let out = shareFolder.appendingPathComponent(url.lastPathComponent)
        let changed = try PrivacyScrub.copy(from: url, to: out)
        LogStore.shared.log("[logs] share \(url.lastPathComponent) (\(changed) lines with personal details taken out)")
        return out
    }

    /// The end of a log, scrubbed, for the viewer: at most `lines` lines from its last 512 KB.
    static func tail(of url: URL, lines: Int = 600) -> [String] {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        var ring: [String] = []
        LogLines.forEach(in: url, fromByte: size > 512 * 1024 ? size - 512 * 1024 : 0) { line in
            ring.append(line.count > 400 ? String(line.prefix(400)) + " ..." : line)
            if ring.count > lines { ring.removeFirst(ring.count - lines) }
        }
        return ring.map(PrivacyScrub.line)
    }

    /// One .zip for a bug report: the summary, the last game log, this run's log
    /// and madeira.cfg, each scrubbed.
    static func bundle() throws -> URL {
        guard let docs = documents else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm"
        let zipURL = shareFolder.appendingPathComponent("Madeira-logs-\(stamp.string(from: Date())).zip")
        try? fm.removeItem(at: zipURL)
        let zip = try LogZip(url: zipURL)
        var names: [String] = []
        for name in [LogSummary.fileName, LogSummary.gameLogName, "madeira-log.txt", MadeiraConfig.fileName] {
            let source = docs.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let entry = name.hasSuffix(".cfg") ? name + ".txt" : name
            let copy = shareFolder.appendingPathComponent(entry)
            try PrivacyScrub.copy(from: source, to: copy)
            try zip.add(name: entry, data: Data(contentsOf: copy, options: .alwaysMapped))
            try? fm.removeItem(at: copy)
            names.append(entry)
        }
        try zip.finish()
        LogStore.shared.log("[logs] bundle \(zipURL.lastPathComponent): \(names.joined(separator: ", "))")
        return zipURL
    }
}

/// A deflated zip, written one entry at a time (no zip64: logs are far below 4 GB).
final class LogZip {
    private let handle: FileHandle
    private var central = Data()
    private var count = 0
    private var offset: UInt32 = 0

    init(url: URL) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    private static func le16(_ v: Int) -> Data { var x = UInt16(truncatingIfNeeded: v).littleEndian; return Data(bytes: &x, count: 2) }
    private static func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }

    /// Raw deflate (no zlib header), as zip's method 8 expects.
    static func deflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { deflateEnd(&stream) }
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        var status = Z_OK
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            repeat {
                status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return zlib.deflate(&stream, Z_FINISH)
                }
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else { throw CocoaError(.fileWriteUnknown) }
                out.append(chunk, count: chunk.count - Int(stream.avail_out))
            } while status != Z_STREAM_END
        }
        return out
    }

    func add(name: String, data: Data) throws {
        let n = Data(name.utf8)
        let crc = data.withUnsafeBytes { raw -> UInt32 in
            UInt32(crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count)))
        }
        let packed = try Self.deflate(data)
        // Version 2.0, UTF-8 names (bit 11), deflate, 1980-01-01 00:00.
        func header(central: Bool) -> Data {
            var h = Data()
            h += Self.le32(central ? 0x0201_4b50 : 0x0403_4b50)
            if central { h += Self.le16(20) }
            h += Self.le16(20); h += Self.le16(0x0800); h += Self.le16(8)
            h += Self.le16(0); h += Self.le16(0x21)
            h += Self.le32(crc); h += Self.le32(UInt32(packed.count)); h += Self.le32(UInt32(data.count))
            h += Self.le16(n.count); h += Self.le16(0)
            if central {
                h += Self.le16(0); h += Self.le16(0); h += Self.le16(0); h += Self.le32(0); h += Self.le32(offset)
            }
            return h + n
        }
        let local = header(central: false)
        central += header(central: true)
        try handle.write(contentsOf: local)
        try handle.write(contentsOf: packed)
        offset += UInt32(local.count + packed.count)
        count += 1
    }

    func finish() throws {
        var end = Data()
        end += Self.le32(0x0605_4b50); end += Self.le16(0); end += Self.le16(0)
        end += Self.le16(count); end += Self.le16(count)
        end += Self.le32(UInt32(central.count)); end += Self.le32(offset); end += Self.le16(0)
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: end)
        try handle.close()
    }
}

private struct SharedLogs: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// "Share Logs": (get-help-auto) one plain "<game> log.txt", the same file as Save copy for Discord
/// (DiscordLog, GetHelpView.swift): Get Help's short scrubbed report plus (discord-full-log) the
/// whole scrubbed log, up to 5 MB, made in the background. Not a .zip any more: the
/// Madeira Discord's bot deletes zips, and Discord shows a .txt. LogFiles.bundle stays for
/// anyone who wants the whole logs (the rows below share each one).
struct ShareLogsButton: View {
    /// Game details › Advanced: that game's config goes in the report and names the file.
    var entry: LibraryEntry? = nil
    @State private var shared: SharedLogs?
    @State private var busy = false
    @State private var failed: String?
    var body: some View {
        Button {
            guard !busy else { return }
            busy = true
            let entry = entry
            let game = entry.map(ClaudeHelp.gameText)
            let device = ClaudeHelp.deviceLine()
            DispatchQueue.global(qos: .userInitiated).async {
                let url = DiscordLog.file(title: entry?.title, report: GetHelp.report(game: game, title: entry?.title, device: device))
                DispatchQueue.main.async {
                    busy = false
                    if let url { shared = SharedLogs(urls: [url]) } else { failed = L("Madeira couldn't write the file. Try again.") }
                }
            }
        } label: {
            HStack {
                Label("Share Logs", systemImage: "doc.text")
                if busy { Spacer(); ProgressView() }
            }
        }
        .disabled(busy)
        .sheet(item: $shared) { ActivitySheet(items: $0.urls) }
        .alert("Could not make the logs file", isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failed ?? "") }
    }
}

/// (debug-logging) Game details › Advanced, test bundle only: this game's last run and its own config as one scrubbed .zip.
struct DebugShareGameLogsButton: View {
    let entry: LibraryEntry
    @State private var shared: SharedLogs?
    @State private var busy = false
    @State private var failed = false
    var body: some View {
        Button {
            guard !busy else { return }
            busy = true
            let title = entry.title, path = entry.windowsPath
            DispatchQueue.global(qos: .userInitiated).async {
                let url = DebugLogging.shareZip(title: title, windowsPath: path)
                DispatchQueue.main.async {
                    busy = false
                    if let url { shared = SharedLogs(urls: [url]) } else { failed = true }
                }
            }
        } label: {
            HStack {
                Label { Text(verbatim: "Share this game's logs") } icon: { Image(systemName: "doc.zipper") }
                if busy { Spacer(); ProgressView() }
            }
        }
        .disabled(busy)
        .sheet(item: $shared) { ActivitySheet(items: $0.urls) }
        .alert(Text(verbatim: "Could not make the logs file"), isPresented: $failed) {
            Button(role: .cancel) {} label: { Text(verbatim: "OK") }
        } message: { Text(verbatim: "Madeira couldn't write the zip. Try again.") }
    }
}

/// (debug-logging) Game details › Advanced, test bundle only: takes the Debug logging lines and the lines Get Help
/// added out of this game's own config (and nothing else), after a confirmation.
struct DebugResetButton: View {
    let entry: LibraryEntry
    var changed: () -> Void
    @State private var ask = false
    @State private var counts = (debug: 0, getHelp: 0)
    var body: some View {
        Button(role: .destructive) {
            counts = DebugLogging.cleanCounts(windowsPath: entry.windowsPath)
            ask = true
        } label: {
            Label { Text(verbatim: "Reset to clean state") } icon: { Image(systemName: "eraser") }
        }
        .confirmationDialog(Text(verbatim: "Reset \(entry.title) to a clean state?"), isPresented: $ask, titleVisibility: .visible) {
            Button(role: .destructive) {
                DebugLogging.resetToClean(windowsPath: entry.windowsPath, title: entry.title)
                changed()
            } label: { Text(verbatim: "Reset") }
            Button(role: .cancel) {} label: { Text(verbatim: "Cancel") }
        } message: {
            Text(verbatim: counts.debug + counts.getHelp == 0
                 ? "This game's config has no Debug logging or Get Help lines. Nothing changes."
                 : "Takes \(counts.debug) Debug logging line(s) and \(counts.getHelp) line(s) Get Help added out of this game's config. Every other line stays. madeira.cfg is not touched.")
        }
    }
}
/// Settings › Logs.
struct LogsSection: View {
    @State private var main: [LogFiles.Item] = []
    @State private var sessions: [LogFiles.Item] = []

    var body: some View {
        Section {
            ShareLogsButton()
        } footer: {
            Text("Share Logs makes one text file (up to 5 MB) with the last game's log and your settings, with personal details taken out. Post it in the Madeira Discord. To send another log, tap it below and share it.")
        }
        .onAppear { reload() }
        Section {
            if main.isEmpty { Text("No logs yet. Play a game once and its log shows here.").foregroundStyle(.secondary) }
            ForEach(main) { row($0) }
        }
        if !sessions.isEmpty {
            Section {
                ForEach(sessions) { row($0) }
            } header: { Text("Game sessions") } footer: {
                Text("Each game session's own log, newest first. Tap one to read its end. The same files are in the Files app: On My iPhone or On My iPad > Madeira.")
            }
        }
    }

    private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = LogFiles.items()
            DispatchQueue.main.async { main = found.main; sessions = found.sessions }
        }
    }

    private func row(_ item: LogFiles.Item) -> some View {
        NavigationLink { LogViewer(item: item) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title).lineLimit(1)
                Text(verbatim: LogFiles.detail(item.url)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The end of one log, scrubbed, with Share for a scrubbed copy of the whole file.
struct LogViewer: View {
    let item: LogFiles.Item
    @State private var lines: [String]?
    @State private var shared: SharedLogs?
    @State private var busy = false

    var body: some View {
        Group {
            if let lines {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Text("Showing the last \(lines.count) lines, with personal details taken out.")
                                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(verbatim: line).font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading).id(index)
                            }
                        }
                        .textSelection(.enabled)
                        .padding()
                    }
                    .onAppear { if !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Text(verbatim: item.title)).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard !busy else { return }
                    busy = true
                    let url = item.url
                    DispatchQueue.global(qos: .userInitiated).async {
                        let copy = try? LogFiles.scrubbedCopy(of: url)
                        DispatchQueue.main.async {
                            busy = false
                            if let copy { shared = SharedLogs(urls: [copy]) }
                        }
                    }
                } label: {
                    if busy { ProgressView() } else { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .sheet(item: $shared) { ActivitySheet(items: $0.urls) }
        .onAppear {
            guard lines == nil else { return }
            let url = item.url
            DispatchQueue.global(qos: .userInitiated).async {
                let tail = LogFiles.tail(of: url)
                DispatchQueue.main.async { lines = tail }
            }
        }
    }
}
