// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Microsoft's Visual C++ runtime for games, taken out of Microsoft's own installers on the
// device (docs/LIBRARY.md). Setup and Settings offer it; nothing is bundled and no Windows
// session runs.
//
// Many games need the Visual C++ 2015-2022 runtime. The app downloads the two installers
// (x64 and x86) from their versioned Microsoft URLs, checks them against pinned sizes and
// SHA-256 sums, and reads the runtime DLLs straight out of them: each installer is a WiX Burn
// bundle whose attached cabinet holds the packages, and the packages' own cabinets hold the
// DLLs as `<name>.dll_amd64` / `<name>.dll_x86` entries (CabinetReader.c, MSZIP). Every DLL is
// checked (PE machine, a signature directory, the pinned version) and kept byte for byte as
// Microsoft shipped it, in Documents/vcruntime (x64; the folder WineProcessBridge already
// consults before the bundled set, so a user-supplied copy keeps winning) and
// Documents/vcruntime32 (x86). At every session start the bridge links them into system32 and
// syswow64 over Wine's builtins; the x64 exemptions (vcruntime140.dll and msvcp140.dll stay
// ARM64EC builtins for the SEH and C++ EH paths) stay in force. Nothing restarts.
// Switches: env.MADEIRA_VCREDIST = 0 hides the feature; env.MADEIRA_VCREDIST_X86 = 0 keeps
// 32-bit programs on Wine's builtins (the bridge). Log tag: [vcredist].

import Foundation
import SwiftUI

// MARK: - Pin

/// The installers, by the versioned URLs the aka.ms links redirect to and their SHA-256
/// sums. The hash in each URL is the file's SHA-256 as Microsoft publishes it. A new
/// runtime version is a new pin, not a moving link.
enum VCRedistPin {
    static let version = "14.44.35211.0"
    static let host = "download.visualstudio.microsoft.com"

    struct Package: Equatable, Sendable {
        let arch: String              // "x64" or "x86"
        let title: String
        let url: URL
        let sha256: String
        let bytes: Int64
        /// The suffix the installer's cabinets give this architecture's DLL entries.
        let entrySuffix: String
        var fileName: String { "VC_redist.\(arch).exe" }
    }

    static let x64 = Package(
        arch: "x64", title: "Visual C++ 2015-2022 x64",
        url: URL(string: "https://download.visualstudio.microsoft.com/download/pr/990c720a-46ce-4dc7-87b9-c2eb615d34b9/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe")!,
        sha256: "cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b", bytes: 25_635_768, entrySuffix: ".dll_amd64")
    static let x86 = Package(
        arch: "x86", title: "Visual C++ 2015-2022 x86",
        url: URL(string: "https://download.visualstudio.microsoft.com/download/pr/990c720a-46ce-4dc7-87b9-c2eb615d34b9/0C09F2611660441084CE0DF425C51C11E147E6447963C3690F97E0B25C55ED64/VC_redist.x86.exe")!,
        sha256: "0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64", bytes: 13_953_392, entrySuffix: ".dll_x86")
    static let packages = [x64, x86]
    static let totalBytes: Int64 = packages.reduce(0) { $0 + $1.bytes }
    static var totalMegabytes: Int { Int((Double(totalBytes) / 1_048_576).rounded()) }

    /// The runtime: the C++ runtime proper and MFC, the set tools/fetch-vcruntime.sh bundles.
    /// MFC's language DLLs and the managed mfcm140 are not taken.
    static let dllNames = ["concrt140.dll", "msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll", "msvcp140_atomic_wait.dll",
                           "msvcp140_codecvt_ids.dll", "vcamp140.dll", "vccorlib140.dll", "vcomp140.dll", "vcruntime140.dll",
                           "vcruntime140_1.dll", "vcruntime140_threads.dll", "mfc140.dll", "mfc140u.dll"]
    /// Microsoft ships no vcruntime140_1.dll for x86 (it exists for x64 and ARM64 only).
    static func expectedNames(_ arch: String) -> [String] {
        arch == "x86" ? dllNames.filter { $0 != "vcruntime140_1.dll" } : dllNames
    }
}

// MARK: - PE facts, the cabinets, the folders

enum VCRedistError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Reading the installers and placing the DLLs. Pure functions over bytes and paths, so the
/// host checks can compile them (CabinetReader.c alongside).
enum VCRedistInstaller {
    /// Documents/vcruntime: the x64 folder the bridge already overlays (madeira-vcruntime-sources:
    /// Documents first, then the bundle). Documents/vcruntime32: the x86 folder it overlays into
    /// syswow64 (madeira_overlay_vcruntime32).
    static func folder(_ arch: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(arch == "x86" ? "vcruntime32" : "vcruntime", isDirectory: true)
    }

    /// "14.44.35211.0" -> [14, 44, 35211, 0]; nil for anything else.
    static func versionParts(_ text: String) -> [Int]? {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        let parts = value.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }
    /// Whether a version is at least the pinned one (fields missing count as 0).
    static func atLeastPinned(_ version: String, pin: String = VCRedistPin.version) -> Bool {
        guard let have = versionParts(version), let want = versionParts(pin) else { return false }
        for index in 0..<max(have.count, want.count) {
            let h = index < have.count ? have[index] : 0, w = index < want.count ? want[index] : 0
            if h != w { return h > w }
        }
        return true
    }

    /// What a DLL's bytes say: the PE machine (0x8664 x64, 0x14c x86), whether the optional
    /// header has a security (Authenticode) directory, and the file version from
    /// VS_FIXEDFILEINFO. nil when the bytes are not a PE image.
    struct PEFacts: Equatable { var machine: UInt16; var signed: Bool; var version: String }
    static func peFacts(_ data: Data) -> PEFacts? {
        func u16(_ at: Int) -> UInt16? { at + 2 <= data.count ? UInt16(data[data.startIndex + at]) | UInt16(data[data.startIndex + at + 1]) << 8 : nil }
        func u32(_ at: Int) -> UInt32? {
            guard at + 4 <= data.count else { return nil }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(data[data.startIndex + at + i]) << (8 * UInt32(i)) }
            return v
        }
        guard data.count > 0x40, data[data.startIndex] == 0x4D, data[data.startIndex + 1] == 0x5A,
              let pe = u32(0x3c).map(Int.init), u32(pe) == 0x4550, let machine = u16(pe + 4), let magic = u16(pe + 24) else { return nil }
        let directories = pe + 24 + (magic == 0x20b ? 112 : 96)
        let securitySize = u32(directories + 4 * 8 + 4) ?? 0
        // VS_FIXEDFILEINFO: signature 0xFEEF04BD, then strucVersion, dwFileVersionMS, dwFileVersionLS.
        let signature: [UInt8] = [0xBD, 0x04, 0xEF, 0xFE]
        var version = ""
        if let range = data.range(of: Data(signature)) {
            let at = data.distance(from: data.startIndex, to: range.lowerBound)
            if let ms = u32(at + 8), let ls = u32(at + 12) {
                version = "\(ms >> 16).\(ms & 0xffff).\(ls >> 16).\(ls & 0xffff)"
            }
        }
        return PEFacts(machine: machine, signed: securitySize > 0, version: version)
    }

    /// The DLL a cabinet entry stands for ("msvcp140.dll_amd64" -> "msvcp140.dll") when it is
    /// one of the wanted names of this architecture; nil otherwise.
    static func dllName(entry: String, package: VCRedistPin.Package) -> String? {
        let lower = entry.lowercased()
        guard lower.hasSuffix(package.entrySuffix.lowercased()) else { return nil }
        let name = String(lower.dropLast(package.entrySuffix.count - ".dll".count))
        return VCRedistPin.expectedNames(package.arch).contains(name) ? name : nil
    }

    /// Checks one DLL from the installer against its name and architecture.
    static func check(_ data: Data, name: String, package: VCRedistPin.Package) throws {
        guard let facts = peFacts(data) else { throw VCRedistError.message("\(name) in the installer is not a Windows DLL.") }
        let machine: UInt16 = package.arch == "x86" ? 0x14c : 0x8664
        guard facts.machine == machine else { throw VCRedistError.message("\(name) in the installer is for another architecture.") }
        guard facts.signed else { throw VCRedistError.message("\(name) in the installer carries no signature.") }
        guard atLeastPinned(facts.version) else { throw VCRedistError.message("\(name) in the installer is version \(facts.version), older than the pinned \(VCRedistPin.version).") }
    }

    /// The installer's DLLs for one architecture: every cabinet in the file is opened, every
    /// payload of it that is itself a cabinet is opened, and the wanted entries are taken (the
    /// first copy of each). Throws unless every expected name was found and passed `check`.
    static func extract(installer: URL, package: VCRedistPin.Package, progress: (Double) -> Void = { _ in }) throws -> [String: Data] {
        let exe = try Data(contentsOf: installer, options: .alwaysMapped)
        guard exe.count > 0x40, exe[exe.startIndex] == 0x4D, exe[exe.startIndex + 1] == 0x5A else {
            throw VCRedistError.message("\(package.fileName) is not a Windows program.")
        }
        var found: [String: Data] = [:]
        let wanted = Set(VCRedistPin.expectedNames(package.arch))
        try exe.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let marker = Data("MSCF".utf8)
            var from = 0
            while found.count < wanted.count, from < raw.count {
                guard let hit = exe.range(of: marker, in: exe.startIndex.advanced(by: from)..<exe.endIndex) else { break }
                let at = exe.distance(from: exe.startIndex, to: hit.lowerBound)
                var handle: OpaquePointer?
                guard madeira_cab_open(base + at, raw.count - at, &handle) == Int32(MADEIRA_CAB_OK), let outer = handle else {
                    from = at + 1           // "MSCF" inside some other data
                    continue
                }
                defer { madeira_cab_close(outer) }
                let length = Int(madeira_cab_length(outer))
                for index in 0..<madeira_cab_file_count(outer) where found.count < wanted.count {
                    let size = Int(madeira_cab_file_size(outer, index))
                    guard size >= 36, size <= 256 << 20 else { continue }
                    var payload = Data(count: size)
                    let rc = payload.withUnsafeMutableBytes { madeira_cab_extract(outer, index, $0.baseAddress, $0.count) }
                    guard rc == Int32(MADEIRA_CAB_OK) else {
                        throw VCRedistError.message("\(package.fileName) is damaged (\(String(cString: madeira_cab_strerror(rc)))).")
                    }
                    guard payload.starts(with: marker) else { continue }
                    try payload.withUnsafeBytes { (inner: UnsafeRawBufferPointer) in
                        var innerHandle: OpaquePointer?
                        guard madeira_cab_open(inner.baseAddress, inner.count, &innerHandle) == Int32(MADEIRA_CAB_OK), let cab = innerHandle else { return }
                        defer { madeira_cab_close(cab) }
                        for entry in 0..<madeira_cab_file_count(cab) {
                            guard let stored = madeira_cab_file_name(cab, entry),
                                  let name = dllName(entry: String(cString: stored), package: package), found[name] == nil else { continue }
                            let bytes = Int(madeira_cab_file_size(cab, entry))
                            guard bytes > 0, bytes <= 64 << 20 else { throw VCRedistError.message("\(name) in the installer has an impossible size.") }
                            var dll = Data(count: bytes)
                            let rc = dll.withUnsafeMutableBytes { madeira_cab_extract(cab, entry, $0.baseAddress, $0.count) }
                            guard rc == Int32(MADEIRA_CAB_OK) else {
                                throw VCRedistError.message("\(name) could not be unpacked (\(String(cString: madeira_cab_strerror(rc)))).")
                            }
                            try check(dll, name: name, package: package)
                            found[name] = dll
                            progress(Double(found.count) / Double(wanted.count))
                        }
                    }
                }
                from = at + max(length, 1)
            }
        }
        let missing = wanted.subtracting(found.keys).sorted()
        guard missing.isEmpty else {
            throw VCRedistError.message("\(package.fileName) did not hold \(missing.joined(separator: ", ")). Microsoft may have changed the installer; this build pins \(VCRedistPin.version).")
        }
        return found
    }

    /// Writes the DLLs into a staging folder next to `folder`, then swaps it into place: the
    /// old folder steps aside, the new one moves in, the old one goes. The folder is kept out
    /// of backups.
    static func install(_ files: [String: Data], into folder: URL) throws {
        let fm = FileManager.default
        let parent = folder.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(folder.lastPathComponent + ".new", isDirectory: true)
        let retired = parent.appendingPathComponent(folder.lastPathComponent + ".old", isDirectory: true)
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: retired)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: staging.appendingPathComponent(name), options: .atomic) }
        #if canImport(Darwin)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var marked = staging; try? marked.setResourceValues(values)
        #endif
        let had = fm.fileExists(atPath: folder.path)
        if had { try fm.moveItem(at: folder, to: retired) }
        do {
            try fm.moveItem(at: staging, to: folder)
        } catch {
            if had { try? fm.moveItem(at: retired, to: folder) }   // put the old folder back
            throw error
        }
        try? fm.removeItem(at: retired)
    }

    /// The version installed in a folder: every expected name present as a regular PE file of
    /// the architecture, all of one version; nil otherwise (missing files, a mix, no folder).
    static func installedVersion(in folder: URL, package: VCRedistPin.Package) -> String? {
        var versions = Set<String>()
        for name in VCRedistPin.expectedNames(package.arch) {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name), options: .alwaysMapped),
                  let facts = peFacts(data), facts.machine == (package.arch == "x86" ? 0x14c : 0x8664), !facts.version.isEmpty else { return nil }
            versions.insert(facts.version)
        }
        return versions.count == 1 ? versions.first : nil
    }
}

// MARK: - Model

/// Setup's page and Settings › Visual C++ runtimes: download, unpack, check, place, report.
/// One install at a time, and none while a session runs (the bridge links the files at
/// session start; a running game may have them open).
@MainActor final class VCRedistModel: ObservableObject {
    static let shared = VCRedistModel()

    enum Phase: Equatable {
        case idle
        case downloading(Double)          // fraction of all bytes
        case installing(Double)           // fraction of the DLLs taken out and checked
    }

    @Published private(set) var phase: Phase = .idle
    /// Architecture -> installed version (VCRedistInstaller.installedVersion).
    @Published private(set) var installed: [String: String] = [:]
    @Published var error: String?

    /// `env.MADEIRA_VCREDIST = 0` (madeira.cfg or the environment) leaves the Visual C++ runtime
    /// installer out of setup and Settings. On by default.
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_VCREDIST") }
    static let packages = VCRedistPin.packages

    /// The running download's progress observation (kept while it runs).
    private var observations: [NSKeyValueObservation] = []

    private init() {}

    var busy: Bool { phase != .idle }
    /// Every architecture's folder holds the whole set, at the pinned version or newer.
    var complete: Bool { Self.packages.allSatisfy { installed[$0.arch].map { VCRedistInstaller.atLeastPinned($0) } ?? false } }
    var status: String {
        switch phase {
        case .downloading(let f): return "Downloading… \(Int((f * 100).rounded()))%"
        case .installing(let f): return "Unpacking and checking… \(Int((f * 100).rounded()))%"
        case .idle:
            if complete {
                let versions = Set(installed.values)
                return "Installed" + (versions.count == 1 ? " (\(versions.first!))" : "")
            }
            if installed.isEmpty { return "Not installed" }
            return "Installed for " + installed.keys.sorted().joined(separator: ", ") + " only"
        }
    }

    private func log(_ line: String) { LogStore.shared.log("[vcredist] " + line) }

    func refresh() {
        var result: [String: String] = [:]
        for package in Self.packages {
            if let version = VCRedistInstaller.installedVersion(in: VCRedistInstaller.folder(package.arch), package: package) {
                result[package.arch] = version
            }
        }
        installed = result
    }

    /// Download both installers, take the DLLs out, check them, put them in place. Refused
    /// while a session runs.
    func install() {
        guard !busy else { return }
        guard wine_process_is_running() == 0, wineserver_is_running() == 0, LibraryModel.shared.current == nil else {
            error = "A session is running. Try again when it has ended."; return
        }
        error = nil
        phase = .downloading(0)
        log("install: \(Self.packages.map(\.title).joined(separator: ", ")) \(VCRedistPin.version), \(VCRedistPin.totalMegabytes) MB from Microsoft")
        Task { [weak self] in
            guard let self else { return }
            do {
                var downloaded: [(VCRedistPin.Package, URL)] = []
                var done: Int64 = 0
                for package in Self.packages {
                    let base = done
                    let file = try await self.download(package) { received in
                        self.phase = .downloading(Double(base + received) / Double(VCRedistPin.totalBytes))
                    }
                    downloaded.append((package, file))
                    done += package.bytes
                }
                self.phase = .installing(0)
                var placed: [String: Int] = [:]
                let count = Double(downloaded.count)
                for (offset, (package, file)) in downloaded.enumerated() {
                    let part = Double(offset) / count
                    let files = try await Task.detached(priority: .userInitiated) {
                        try VCRedistInstaller.extract(installer: file, package: package) { fraction in
                            Task { @MainActor in self.phase = .installing(part + fraction / count) }
                        }
                    }.value
                    try VCRedistInstaller.install(files, into: VCRedistInstaller.folder(package.arch))
                    placed[package.arch] = files.count
                    self.log("\(package.title): \(files.count) DLLs placed in \(VCRedistInstaller.folder(package.arch).lastPathComponent)")
                    try? FileManager.default.removeItem(at: file)
                }
                self.refresh()
                if self.complete {
                    self.phase = .idle
                    self.log("installed: \(self.installed.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")); the next session links them")
                } else {
                    self.fail("The DLLs were placed, but reading them back failed. Export the log.")
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    /// One installer, to the temporary folder: checked by size and SHA-256.
    private func download(_ package: VCRedistPin.Package, progress: @escaping @MainActor (Int64) -> Void) async throws -> URL {
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("madeira-" + package.fileName)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: kept.path), (attrs[.size] as? Int64) == package.bytes,
           (try? WineMonoInstaller.sha256(of: kept)) == package.sha256 {
            log("\(package.fileName): already downloaded and verified")
            return kept
        }
        let temp: URL = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: package.url) { temp, response, failure in
                if let failure { continuation.resume(throwing: failure); return }
                guard let temp, let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: VCRedistError.message("No response from Microsoft's download server.")); return
                }
                guard http.statusCode == 200 else {
                    continuation.resume(throwing: VCRedistError.message("Microsoft's download server answered \(http.statusCode) for \(package.fileName).")); return
                }
                guard response?.url?.host == VCRedistPin.host, response?.url?.scheme == "https" else {
                    continuation.resume(throwing: VCRedistError.message("\(package.fileName) was served from an unexpected address.")); return
                }
                // The temporary file is removed when this closure returns: keep it.
                try? FileManager.default.removeItem(at: kept)
                do { try FileManager.default.moveItem(at: temp, to: kept); continuation.resume(returning: kept) }
                catch { continuation.resume(throwing: error) }
            }
            observations.append(task.observe(\.countOfBytesReceived) { task, _ in
                let received = task.countOfBytesReceived
                Task { @MainActor in progress(min(received, package.bytes)) }
            })
            task.resume()
        }
        observations.removeAll()
        let attrs = try FileManager.default.attributesOfItem(atPath: temp.path)
        guard (attrs[.size] as? Int64) == package.bytes else {
            try? FileManager.default.removeItem(at: temp)
            throw VCRedistError.message("\(package.fileName) has an unexpected size (\(attrs[.size] ?? 0) bytes). Microsoft may have published a new version; this build pins \(VCRedistPin.version).")
        }
        guard try WineMonoInstaller.sha256(of: temp) == package.sha256 else {
            try? FileManager.default.removeItem(at: temp)
            throw VCRedistError.message("\(package.fileName) does not match its pinned SHA-256. Nothing was installed.")
        }
        log("\(package.fileName): \(package.bytes) bytes, SHA-256 verified")
        return temp
    }

    /// Removes both folders. The next session links Wine's builtins (and the bundled set) again.
    func remove() {
        guard !busy, wine_process_is_running() == 0, wineserver_is_running() == 0 else { return }
        for package in Self.packages { try? FileManager.default.removeItem(at: VCRedistInstaller.folder(package.arch)) }
        refresh()
        error = nil
        log("removed")
    }

    private func fail(_ message: String) {
        phase = .idle
        error = message
        log("failed: " + message)
    }
}

// MARK: - Settings › Visual C++ runtimes

struct VCRedistSettingsSection: View {
    @ObservedObject private var redist = VCRedistModel.shared
    @State private var confirmRemove = false

    var body: some View {
        Section {
            LabeledContent("Visual C++ 2015-2022", value: redist.status)
            if case .downloading(let f) = redist.phase { ProgressView(value: f) }
            if case .installing(let f) = redist.phase { ProgressView(value: f) }
            if let error = redist.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if !redist.busy {
                Button { redist.install() } label: {
                    Label(redist.complete ? "Install again" : (redist.error == nil ? "Download and install" : "Try again"),
                          systemImage: "arrow.down.circle")
                }
                if !redist.installed.isEmpty {
                    Button("Remove the runtime", role: .destructive) { confirmRemove = true }
                }
            }
        } header: {
            Text("Visual C++ runtimes")
        } footer: {
            Text("Many Windows games need Microsoft's Visual C++ 2015-2022 runtime. Madeira downloads Microsoft's installers (about \(VCRedistPin.totalMegabytes) MB, version \(VCRedistPin.version)) and takes the runtime DLLs out of them on this device, as Microsoft shipped them, for 64-bit and 32-bit games. No Windows session runs and nothing restarts: the next game start uses them. Microsoft's licence terms for the redistributable apply to the files.")
        }
        .confirmationDialog("Remove the Visual C++ runtime?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { redist.remove() }
        } message: {
            Text("Games go back to Wine's own C++ runtime (and the copy bundled with this build, if any) at their next start.")
        }
        .onAppear { redist.refresh() }
    }
}
