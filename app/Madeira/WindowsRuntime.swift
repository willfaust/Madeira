// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import SwiftUI
import CryptoKit

/// Microsoft .NET Desktop Runtime installers are not redistributed in Madeira.
/// The release metadata and the installer are fetched from Microsoft's official
/// dotnetcli feed, then the installer is added to the library for a normal Wine
/// desktop install.
struct DotNetRuntimeFile: Sendable {
    let version: String
    let name: String
    let url: URL
    let sha512: String?
}

private struct DotNetReleaseMetadata: Decodable {
    struct Release: Decodable {
        let version: String
        let windowsDesktop: WindowsDesktop?
        enum CodingKeys: String, CodingKey {
            case version = "release-version"
            case windowsDesktop = "windowsdesktop"
        }
    }
    struct WindowsDesktop: Decodable { let files: [File] }
    struct File: Decodable {
        let name: String
        let rid: String
        let url: URL
        let hash: String?
    }
    let releases: [Release]
}

enum DotNetRuntimeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

enum DotNetRuntimeCatalog {
    static func metadataURL(channel: String) -> URL {
        URL(string: "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/\(channel)/releases.json")!
    }

    static func latest(channel: String, architecture: String) async throws -> DotNetRuntimeFile {
        let (data, response) = try await URLSession.shared.data(from: metadataURL(channel: channel))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DotNetRuntimeError.message("Microsoft's .NET metadata server returned HTTP \(http.statusCode).")
        }
        let metadata: DotNetReleaseMetadata
        do { metadata = try JSONDecoder().decode(DotNetReleaseMetadata.self, from: data) }
        catch { throw DotNetRuntimeError.message("Microsoft's .NET release metadata could not be read.") }
        let rid = architecture == "x86" ? "win-x86" : "win-x64"
        for release in metadata.releases {
            guard let files = release.windowsDesktop?.files else { continue }
            if let file = files.first(where: { $0.rid == rid && $0.name.lowercased().hasPrefix("windowsdesktop-runtime-") && $0.name.lowercased().hasSuffix(".exe") }) {
                return DotNetRuntimeFile(version: release.version, name: file.name, url: file.url, sha512: file.hash)
            }
        }
        throw DotNetRuntimeError.message("Microsoft does not publish a Windows Desktop Runtime for \(architecture) on the .NET \(channel) channel.")
    }

    static func download(_ file: DotNetRuntimeFile, to destination: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: file.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DotNetRuntimeError.message("Microsoft's .NET server returned HTTP \(http.statusCode).")
        }
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: temporary, to: destination)
        if let expected = file.sha512?.lowercased(), expected.count == 128 {
            let handle = try FileHandle(forReadingFrom: destination)
            defer { try? handle.close() }
            var hash = SHA512()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                try? manager.removeItem(at: destination)
                throw DotNetRuntimeError.message("The .NET Desktop Runtime download failed its SHA-512 check.")
            }
        }
    }
}

@MainActor
final class DotNetRuntimeModel: ObservableObject {
    static let shared = DotNetRuntimeModel()

    enum Phase: Equatable {
        case idle
        case resolving
        case downloading
    }

    @Published var channel = "8.0"
    @Published var architecture = "x64"
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var installed = false
    @Published private(set) var status = ""
    @Published var error: String?

    private init() { refresh() }

    func refresh() {
        let roots = architecture == "x86"
            ? ["Program Files (x86)/dotnet/shared/Microsoft.WindowsDesktop.App"]
            : ["Program Files/dotnet/shared/Microsoft.WindowsDesktop.App"]
        installed = roots.contains { FileManager.default.fileExists(atPath: LibraryModel.drive.appendingPathComponent($0).path) }
    }

    func install() {
        guard phase == .idle else { return }
        if architecture == "x86" && !DockInstallers.bundleHas32Bit {
            error = "The x86 .NET Desktop Runtime needs the optional 32-bit Wine files. Rebuild with MADEIRA_BUILD_I386=1 first."
            return
        }
        phase = .resolving; error = nil; status = "Looking up the latest .NET \(channel) Desktop Runtime…"
        let chosenChannel = channel, chosenArchitecture = architecture
        Task { @MainActor in
            do {
                let file = try await DotNetRuntimeCatalog.latest(channel: chosenChannel, architecture: chosenArchitecture)
                phase = .downloading; status = "Downloading .NET Desktop Runtime \(file.version) (\(chosenArchitecture))…"
                let directory = LibraryModel.drive.appendingPathComponent(LauncherSupport.downloadFolder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(file.name)
                try await DotNetRuntimeCatalog.download(file, to: destination)
                var entry = try LibraryModel.inspect(destination)
                entry.title = ".NET Desktop Runtime \(file.version) (\(chosenArchitecture) installer)"
                entry.launchMode = "desktop"
                entry.workingDirectory = "C:\\" + LauncherSupport.downloadFolder
                entry.startServices = true
                if let old = LibraryModel.shared.entries.first(where: { $0.relativePath.caseInsensitiveCompare(entry.relativePath) == .orderedSame }) { entry.id = old.id }
                LibraryModel.shared.save(entry)
                status = "Downloaded .NET Desktop Runtime \(file.version). Open the installer from the library, then restart Madeira."
                phase = .idle
                LogStore.shared.log("[dotnet] downloaded desktop-runtime channel=\(chosenChannel) arch=\(chosenArchitecture) version=\(file.version)")
            } catch {
                phase = .idle
                self.error = error.localizedDescription
                status = ""
                LogStore.shared.log("[dotnet] download failed: \(error.localizedDescription)", level: .error)
            }
        }
    }
}

struct WindowsRuntimeSettingsSection: View {
    @ObservedObject private var runtime = DotNetRuntimeModel.shared

    var body: some View {
        Section {
            Picker(".NET channel", selection: $runtime.channel) {
                Text(".NET 8 (LTS)").tag("8.0")
                Text(".NET 9").tag("9.0")
                Text(".NET 6 (legacy)").tag("6.0")
            }
            Picker("Architecture", selection: $runtime.architecture) {
                Text("x64").tag("x64")
                Text("x86 (32-bit)").tag("x86")
            }.onChange(of: runtime.architecture) { _, _ in runtime.refresh() }
            LabeledContent("Status", value: runtime.installed ? "Detected in drive_c" : "Not installed")
            if runtime.phase == .resolving || runtime.phase == .downloading {
                HStack { ProgressView(); Text(runtime.status).foregroundStyle(.secondary) }
            } else {
                Button { runtime.install() } label: {
                    Label(runtime.installed ? "Download another installer" : "Download .NET Desktop Runtime", systemImage: "arrow.down.circle")
                }
            }
            if !runtime.status.isEmpty && runtime.phase == .idle { Text(runtime.status).font(.caption).foregroundStyle(.secondary) }
            if let error = runtime.error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: {
            Text(".NET Desktop Runtime")
        } footer: {
            Text("This downloads Microsoft's official Windows Desktop Runtime installer and adds it to the library. Run that installer once in the Wine desktop. .NET Framework applications use Wine Mono above; the Desktop Runtime is for modern WPF/WinForms applications.")
        }
        .onAppear { runtime.refresh() }
    }
}
