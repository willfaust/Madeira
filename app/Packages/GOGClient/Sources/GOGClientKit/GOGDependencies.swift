// SPDX-License-Identifier: GPL-3.0-or-later
// GOG's redistributables ("dependencies"), as GOG Galaxy and Heroic install them (decision 0090):
//
//   build       the build manifest's `dependencies`: ids such as "openAL", "MSVC2017_x64"
//   repository  content-system.gog.com/dependencies/repository?generation=2, a link to the
//               repository manifest (zlib JSON): each id's depot manifest, its installer
//               (`executable.path`, under `__redist/`, and `executable.arguments`) and its name
//   depot       cdn.gog.com/content-system/v2/dependencies/meta/aa/bb/HASH, a depot manifest
//               like a game's; its chunks from the open link (no sign-in, no product)
//
// Playport places a dependency's files in the game's own folder, at the depot's paths (as GOG's
// offline installers put `__redist` there), and runs its installer once per prefix from Play: an
// `.exe` itself, an `.msi` (XNA, PHYSXLEGACY) through Wine's `msiexec /i` (decision 0103).

import Foundation
import ContentKit

/// One redistributable in GOG's dependency repository.
public struct GOGDependency: Codable, Equatable, Sendable {
    /// GOG's id, as a build manifest's `dependencies` names it.
    public var id: String
    /// GOG's readable name ("Open AL (2.0.7.0)").
    public var name: String
    /// The installer, `/`-separated, relative to the depot's root (`__redist/openAL/oalinst.exe`);
    /// empty for a tool GOG places for the game itself (ISI, DOSBox, ScummVM): nothing to run.
    public var executable: String
    /// The installer's command line, as GOG gives it.
    public var arguments: String
    /// The dependency's depot manifest.
    public var manifest: String
    public var size: UInt64

    /// The installer is a program, run itself.
    public var isProgram: Bool { executable.lowercased().hasSuffix(".exe") }
    /// The installer is a Windows Installer package, run through `msiexec /i` (decision 0103).
    public var isWindowsInstallerPackage: Bool { executable.lowercased().hasSuffix(".msi") }
}

public enum GOGDependencies {
    public static let repositoryURL = URL(string: "https://content-system.gog.com/dependencies/repository?generation=2")!
    /// Where the dependencies' chunks are, without a secure link.
    static let openLinkURL = URL(string: "https://content-system.gog.com/open_link?generation=2&_version=2&path=/dependencies/store/")!

    /// GOG's repository, now: the pointer, then its manifest.
    public static func repository(_ session: GOGSession) async throws -> [GOGDependency] {
        let pointer = try parsePointer(try await session.plain(repositoryURL, maxBytes: 1 << 20, label: "GOG dependency repository"))
        return try parseRepository(try Zlib.json(try await session.plain(pointer, maxBytes: 16 << 20, label: "GOG dependency manifest")))
    }

    static func parsePointer(_ body: [UInt8]) throws -> URL {
        struct Raw: Decodable { var repository_manifest: String }
        guard let r = try? JSONDecoder().decode(Raw.self, from: Data(body)), let url = URL(string: r.repository_manifest),
              url.scheme == "https" else {
            throw ClientError.protocolChanged("GOG dependency repository: unexpected reply")
        }
        return url
    }

    static func parseRepository(_ json: [UInt8]) throws -> [GOGDependency] {
        struct Raw: Decodable {
            struct D: Decodable {
                struct E: Decodable {
                    var path: String?
                    var arguments: String?
                }
                var dependencyId: String
                var readableName: String?
                var executable: E?
                var manifest: String
                var size: UInt64?
            }
            var depots: [D]
        }
        guard let r = try? JSONDecoder().decode(Raw.self, from: Data(json)) else {
            throw ClientError.protocolChanged("GOG dependency manifest: unexpected shape")
        }
        return try r.depots.map { d in
            guard GOGContent.isHash(d.manifest) else { throw ClientError.unsafeContent("GOG dependency manifest name \(d.manifest.prefix(40))") }
            let exe = d.executable?.path ?? ""
            return GOGDependency(id: d.dependencyId, name: d.readableName ?? d.dependencyId,
                                 executable: exe.isEmpty ? "" : try SafePath.normalize(exe),
                                 arguments: d.executable?.arguments ?? "", manifest: d.manifest, size: d.size ?? 0)
        }
    }

    /// The dependency's files, as a game depot's are checked.
    public static func depot(_ session: GOGSession, _ d: GOGDependency) async throws -> [GOGDepotFile] {
        let h = d.manifest
        guard GOGContent.isHash(h) else { throw ClientError.unsafeContent("GOG dependency manifest name") }
        let url = URL(string: "https://cdn.gog.com/content-system/v2/dependencies/meta/\(h.prefix(2))/\(h.dropFirst(2).prefix(2))/\(h)")!
        return try GOGContent.parseDepot(try Zlib.json(try await session.plain(url, maxBytes: 16 << 20, label: "GOG dependency depot")))
    }

    /// What a Play does with each id a build names (decision 0090).
    public struct Selection: Equatable, Sendable {
        /// Downloaded into the game's folder when absent and run, in the build's order.
        public var run: [GOGDependency] = []
        /// Not run, recorded as skipped with the reason: Playport's builtins cover what they install.
        public var skipped: [Skipped] = []
        /// Neither run nor recorded, for the log.
        public var notes: [String] = []

        public struct Skipped: Equatable, Sendable {
            public var dependency: GOGDependency
            public var reason: String
        }
    }

    /// DirectX June 2010's DXSETUP, skipped as Steam's is (decision 0086).
    static let directX = "DirectX"
    public static let directXReason = "Playport's built-in DirectX libraries cover it"
    /// The .NET Framework installers: Wine Mono stands in for the Framework, as the prefix's .NET
    /// HasRunKeys make Steam skip its own .NET entries (decision 0081). The .NET Core and .NET
    /// (Desktop Runtime) installers are not the Framework: they run.
    static let dotNetFramework: Set<String> = ["dotNet35", "dotNet35C", "dotNet4", "dotNet4C", "dotNet45", "dotNet46", "dotNet47", "dotNet472"]
    public static let dotNetFrameworkReason = "Wine Mono stands in for the .NET Framework"

    /// The build's `ids` against GOG's repository: each runs, is skipped, or is left out (an id GOG
    /// does not list; a tool with no installer, as Heroic leaves it; an installer that is neither an
    /// `.exe` nor an `.msi`). An id named twice counts once.
    public static func select(_ ids: [String], from repository: [GOGDependency]) -> Selection {
        var s = Selection()
        var seen = Set<String>()
        for id in ids where seen.insert(id).inserted {
            guard let d = repository.first(where: { $0.id == id }) else {
                s.notes.append("\(id): not in GOG's dependency repository; left out")
                continue
            }
            if d.executable.isEmpty {
                s.notes.append("\(id) (\(d.name)): GOG places it for the game, no installer; left out")
            } else if id == directX {
                s.skipped.append(.init(dependency: d, reason: directXReason))
            } else if dotNetFramework.contains(id) {
                s.skipped.append(.init(dependency: d, reason: dotNetFrameworkReason))
            } else if !d.isProgram && !d.isWindowsInstallerPackage {
                s.notes.append("\(id) (\(d.name)): its installer \(d.executable) is not a program; left out")
            } else {
                s.run.append(d)
            }
        }
        return s
    }

    /// The prerequisite record's id for a GOG dependency (decision 0090).
    public static func prerequisiteID(_ id: String) -> String { "gog-redist:\(id)" }
}
