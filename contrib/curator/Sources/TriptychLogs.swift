// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

/// Triptych's own log (Documents/Logs/triptych.log) and the process's stderr (Documents/Logs/stderr.log), each with the
/// previous run's copy kept as *-prev.log, because the run that crashed is the one worth reading. Engines that keep their
/// own logs (Henge: henge.log/henge-native.log; Madeira: madeira-log.txt; Windows PC and x86 PC: serial.log) keep them;
/// LogExport gathers all of them into one zip.
enum TriptychLog {
    static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var logURL: URL { dir.appendingPathComponent("triptych.log") }
    static var stderrURL: URL { dir.appendingPathComponent("stderr.log") }

    private static var fd: Int32 = -1
    private static var started = false
    private static let lock = NSLock()
    private static let t0 = Date()

    /// Moves `url` to its -prev name (triptych.log -> triptych-prev.log), replacing the older one.
    static func rotate(_ url: URL) {
        let fm = FileManager.default
        let prev = url.deletingPathExtension().path + "-prev." + url.pathExtension
        try? fm.removeItem(atPath: prev)
        try? fm.moveItem(atPath: url.path, toPath: prev)
    }

    /// Once, at app launch: fresh files, stderr into stderr.log, the banner.
    static func start() {
        guard !started else { return }
        started = true
        signal(SIGPIPE, SIG_IGN)
        rotate(logURL)
        fd = open(logURL.path, O_CREAT | O_WRONLY | O_TRUNC | O_APPEND, 0o644)
        // stderr goes to a file so the output survives a process exit. Linux's console has its own PTY.
        // Henge points stderr at henge-native.log when the macOS page opens.
        if ProcessInfo.processInfo.environment["TRIPTYCH_STDERR_TO_CONSOLE"] == nil {
            rotate(stderrURL)
            let e = open(stderrURL.path, O_CREAT | O_WRONLY | O_TRUNC | O_APPEND, 0o644)
            if e >= 0 { dup2(e, STDERR_FILENO); close(e) }
        }
        log("boot", "================ Triptych starting ================")
        for line in DeviceInfo.lines() { log("boot", line) }
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            log("app", "memory warning")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            log("app", "entered background")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
            log("app", "entering foreground")
        }
    }

    static func log(_ tag: String, _ message: String) {
        let line = String(format: "[%10.2fms][%@] %@\n", Date().timeIntervalSince(t0) * 1000, tag, message)
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { _ = line.withCString { write(fd, $0, strlen($0)) } }
    }
}

/// What a log reader needs to know about the device and the build.
enum DeviceInfo {
    static var model: String {
        var u = utsname(); uname(&u)
        let m = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"].map { "\($0) (Simulator)" } ?? m
    }

    /// Triptych's own Info.plist, read once at first use. Bundle.main is not reliable for this: a Mac app run in-process
    /// (Mac apps) swaps it for the app's bundle, which made log headers say "com.codeweavers.CrossOver".
    static let ownInfo: [String: Any] = {
        var dl = Dl_info()
        if dladdr(#dsohandle, &dl) != 0, let f = dl.dli_fname {
            let plist = URL(fileURLWithPath: String(cString: f)).deletingLastPathComponent().appendingPathComponent("Info.plist")
            if let d = NSDictionary(contentsOf: plist) as? [String: Any], d["CFBundleIdentifier"] != nil { return d }
        }
        return Bundle.main.infoDictionary ?? [:]
    }()

    /// Systems started in this launch, recorded by SessionState.markStarted.
    private static let ranLock = NSLock()
    private static var ran: [EngineKind] = []
    static var systemsRan: [EngineKind] { ranLock.lock(); defer { ranLock.unlock() }; return ran }
    static func recordRan(_ k: EngineKind) {
        ranLock.lock(); defer { ranLock.unlock() }
        if !ran.contains(k) { ran.append(k) }
    }

    static func jitSource(inLiveContainer: Bool, debugged: Bool) -> String {
        guard debugged else { return "none" }
        return inLiveContainer ? "LiveContainer" : "StikDebug"
    }

    /// The facts a maintainer needs first: build, device, OS, JIT source and which systems ran this launch.
    static func contextLines(info: [String: Any] = ownInfo, model: String = DeviceInfo.model, os: String = UIDevice.current.systemVersion,
                             jit: String = jitSource(inLiveContainer: JIT.isInLiveContainer, debugged: JIT.isEnabled),
                             systems: [EngineKind] = systemsRan) -> [String] {
        [
            "Triptych build: \(info["TriptychCommit"] as? String ?? "unstamped")",
            "Device: \(model)",
            "iPadOS: \(os)",
            "JIT source: \(jit)",
            "Systems run this launch: \(systems.isEmpty ? "none" : systems.map(\.title).joined(separator: ", "))",
        ]
    }

    static func lines() -> [String] {
        let info = ownInfo
        let pi = ProcessInfo.processInfo
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return [
            "app         : Triptych \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")), commit \(info["TriptychCommit"] ?? "unstamped")",
            "bundle      : \(info["CFBundleIdentifier"] ?? "?")",
            "device      : \(model), \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")",
            "system      : \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "memory      : \(pi.physicalMemory >> 20) MiB, \(pi.activeProcessorCount) cores, free disk \(free >> 20) MiB",
            "LiveContainer: \(JIT.isInLiveContainer ? "yes (\(getenv("LC_HOME_PATH").map { String(cString: $0) } ?? ""))" : "no")",
            "debugged    : \(JIT.isEnabled ? "yes (CS_DEBUGGED)" : "no")",
            "pid         : \(getpid())",
            "date        : \(ISO8601DateFormatter().string(from: Date()))",
        ]
    }
}

/// One zip of every log, current and previous run, with the device and build details, for the share sheet.
enum LogExport {
    /// Directories never worth walking into: guest disks, Wine prefixes, root filesystems.
    static let skipDirs: Set<String> = ["drive_c", "dosdevices", "rootfs", "rootfs.img", "Machines", "Inbox", "tmp-download"]
    static let maxFileBytes = 16 << 20
    static let maxTotalBytes = 160 << 20

    /// Whether a file name is a log (or the engine settings next to one, which explain it).
    static func isLog(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.hasSuffix(".log") || n.hasSuffix(".ips") { return true }
        guard n.hasSuffix(".txt") else { return false }
        return n.contains("log") || n.contains("summary") || n.hasSuffix("-env.txt") || n == "tl-out.txt"
    }

    /// Every log under Documents, Application Support and tmp, three levels deep, newest first.
    static func collect() -> [(url: URL, name: String)] {
        let fm = FileManager.default
        let roots: [(String, URL, Int)] = [
            ("Documents", fm.urls(for: .documentDirectory, in: .userDomainMask)[0], 3),
            ("AppSupport", fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], 3),
            ("tmp", fm.temporaryDirectory, 1),
        ]
        var out: [(URL, String, Date)] = []
        for (label, root, depth) in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                if v?.isDirectory == true {
                    if e.level >= depth || skipDirs.contains(url.lastPathComponent) || url.lastPathComponent.hasPrefix("Triptych-logs") { e.skipDescendants() }
                    continue
                }
                guard isLog(url.lastPathComponent) else { continue }
                // The enumerator reports /private/var/... for a root given as /var/... (LiveContainer's nested Documents
                // made names like "Documents__ocuments__..."): compare both without the /private prefix.
                func plain(_ p: String) -> String { p.hasPrefix("/private/") ? String(p.dropFirst(8)) : p }
                let full = plain(url.path), base = plain(root.path)
                let rel = (full.hasPrefix(base) ? String(full.dropFirst(base.count)) : url.lastPathComponent)
                    .split(separator: "/").joined(separator: "__")
                out.append((url, "\(label)__\(rel)", v?.contentModificationDate ?? .distantPast))
            }
        }
        return out.sorted { $0.2 > $1.2 }.map { ($0.0, $0.1) }
    }

    struct Result { let zip: URL; let files: Int; let bytes: Int }

    /// Writes tmp/Triptych-logs-<time>.zip.
    static func makeArchive() throws -> Result {
        let fm = FileManager.default
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
        let base = fm.temporaryDirectory.appendingPathComponent("LogExport", isDirectory: true)
        try? fm.removeItem(at: base)
        let folder = base.appendingPathComponent("Triptych-logs-\(stamp)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var total = 0, count = 0, listing: [String] = []
        for (url, name) in collect() {
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            let size = Int((try? h.seekToEnd()) ?? 0)
            let take = min(size, maxFileBytes, max(0, maxTotalBytes - total))
            guard take > 0 || size == 0 else { listing.append("\(name): \(size) bytes, left out (export size limit)"); continue }
            try? h.seek(toOffset: UInt64(size - take))
            let data = (try? h.readToEnd()) ?? Data()
            try data.write(to: folder.appendingPathComponent(name))
            total += data.count; count += 1
            listing.append("\(name): \(size) bytes" + (take < size ? ", last \(take) bytes kept" : ""))
        }
        TriptychLog.log("logs", "export: \(count) files, \(total) bytes")
        var info = DeviceInfo.contextLines() + [""] + DeviceInfo.lines()
        info.append("")
        info.append("Engines:")
        for k in EngineKind.allCases { info.append("  \(k.title): \(EngineRegistry.availability(k))") }
        info.append("")
        info.append("Files (\(count)):")
        info += listing.map { "  " + $0 }
        try Data((info.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("00-device-and-app.txt"))

        let dest = base.appendingPathComponent("Triptych-logs-\(stamp).zip")
        try zipDirectory(folder, to: dest)
        try? fm.removeItem(at: folder)
        return Result(zip: dest, files: count + 1, bytes: total)
    }

    static func zipDirectory(_ folder: URL, to dest: URL) throws {
        // NSFileCoordinator zips a directory when asked to read it "for uploading".
        var coordError: NSError?, copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordError) { tmp in
            do { try FileManager.default.copyItem(at: tmp, to: dest) } catch { copyError = error }
        }
        if let e = coordError ?? (copyError as NSError?) { throw e }
        guard FileManager.default.fileExists(atPath: dest.path) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// "Export logs": the zip, then the share sheet. On every system page, the home screen and About.
struct ExportLogsButton: View {
    /// Icon only, for toolbars.
    var compact = false
    @State private var working = false
    @State private var summary: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { export() } label: {
                if compact && !working {
                    Image(systemName: "doc.text.magnifyingglass").accessibilityLabel("Provenance · Export logs")
                } else {
                    Label(working ? "Preparing logs…" : "Provenance · Export logs", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(working)
            .accessibilityIdentifier("export-logs")
            if let summary, !compact {
                Text(summary).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("export-logs-result")
            }
        }
        .alert("Provenance · Export logs", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    private func export() {
        working = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Swift.Result { try LogExport.makeArchive() }
            DispatchQueue.main.async {
                working = false
                switch r {
                case .success(let res):
                    summary = "\(res.zip.lastPathComponent) · \(res.files) files · \(ByteCountFormatter.string(fromByteCount: Int64(res.bytes), countStyle: .file))"
                    ShareSheet.present([res.zip])
                case .failure(let e):
                    failure = "The logs could not be packed: \(e.localizedDescription)"
                }
            }
        }
    }
}

/// The system share sheet, presented by UIKit from the topmost controller. Not a SwiftUI .sheet: one wrapping
/// UIActivityViewController left SwiftUI believing a sheet was still up after Close, so the next full-screen page
/// (the macOS page) could not be presented.
enum ShareSheet {
    static func present(_ items: [Any]) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow),
              var top = window.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = vc.popoverPresentationController { // iPad: a centred popover with no arrow
            pop.sourceView = window
            pop.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }
}

extension View {
    /// Diagnostic actions in the page's toolbar.
    func exportLogsToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) { CuratorButton(compact: true) }
            ToolbarItem(placement: .topBarTrailing) { ExportLogsButton(compact: true) }
        }
    }
}
