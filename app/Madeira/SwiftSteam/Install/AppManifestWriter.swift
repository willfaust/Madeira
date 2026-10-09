// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Reduced to
// the install record writer and extended by 125hz (docs/STEAM_LIBRARY.md).

import Foundation

/// Generates Steam appmanifest .acf files, Steam's on-disk install record.
/// A depot download writes one next to `steamapps/common/<installdir>`, in the
/// format Steam's own client writes. Madeira Dock's discovery
/// (`MadeiraDock.games`) and Valve's client, which Dock starts the game
/// through, both read it.
///
/// Steam is strict about the format: an earlier version of this writer
/// produced records that were silently rejected (`Universe` instead of
/// `universe`, missing `LastPlayed`/`StagingSize`/`UpdateResult`/
/// `TargetBuildID`/`ScheduledAutoUpdate`, `BytesDownloaded` set to the
/// install size instead of 0, `AutoUpdateBehavior=1` instead of 0).
///
/// The `installedDepots` block is what Steam checks to decide whether to
/// download again. Without it an app shows as installed, but Steam tries to
/// "update" it on first launch.
struct AppManifestWriter {

    /// Writes `appmanifest_<appid>.acf` into a Steam library folder
    /// (`steamAppsPath`). `installedDepots` is what Steam trusts as a complete
    /// install. `buildID` is the depot build id from PICS (0 if unknown; Steam
    /// may then flag the install for verification on the next launch).
    static func writeManifest(
        appID: UInt32,
        name: String,
        installDir: String,
        buildID: UInt32,
        steamID: UInt64,
        sizeOnDisk: UInt64 = 0,
        steamAppsPath: String,
        installedDepots: [InstalledDepot]? = nil,
        sharedDepots: [(depotID: Int, ownerAppID: Int)] = [],
        customExecutables: [String] = []
    ) throws {
        let manifestPath = try SteamStoragePath.native("appmanifest_\(appID).acf", root: URL(fileURLWithPath: steamAppsPath)).path

        let timestamp = Int(Date().timeIntervalSince1970)

        // Built line by line so optional fields can be interleaved. Field names
        // and order match what Steam's client writes.
        var lines: [String] = []
        lines.append("\"AppState\"")
        lines.append("{")
        lines.append("\t\"appid\"\t\t\"\(appID)\"")
        // Lowercase 'universe', as Steam writes it.
        lines.append("\t\"universe\"\t\t\"1\"")
        lines.append("\t\"name\"\t\t\"\(escapeVDFString(name))\"")
        lines.append("\t\"StateFlags\"\t\t\"4\"")  // 4 = fully installed
        lines.append("\t\"installdir\"\t\t\"\(escapeVDFString(installDir))\"")
        lines.append("\t\"LastUpdated\"\t\t\"\(timestamp)\"")
        lines.append("\t\"LastPlayed\"\t\t\"0\"")
        lines.append("\t\"SizeOnDisk\"\t\t\"\(sizeOnDisk)\"")
        lines.append("\t\"StagingSize\"\t\t\"0\"")
        lines.append("\t\"buildid\"\t\t\"\(buildID)\"")
        lines.append("\t\"LastOwner\"\t\t\"\(steamID)\"")
        // DownloadType=1 means "complete install" (not deferred or partial).
        // Without it Steam may decide files are missing and download again.
        if installedDepots != nil {
            lines.append("\t\"DownloadType\"\t\t\"1\"")
        }
        lines.append("\t\"UpdateResult\"\t\t\"0\"")
        // Bytes-downloaded and bytes-staged are post-install state markers. A
        // completed install has them at 0; anything else tells Steam a download
        // is queued (setting them to the install size put Steam into
        // "verifying download" on the next launch).
        lines.append("\t\"BytesToDownload\"\t\t\"0\"")
        lines.append("\t\"BytesDownloaded\"\t\t\"0\"")
        lines.append("\t\"BytesToStage\"\t\t\"0\"")
        lines.append("\t\"BytesStaged\"\t\t\"0\"")
        lines.append("\t\"TargetBuildID\"\t\t\"\(buildID)\"")
        // AutoUpdateBehavior 0 = "Always keep this game updated", the default
        // option in Steam's UI.
        lines.append("\t\"AutoUpdateBehavior\"\t\t\"0\"")
        lines.append("\t\"AllowOtherDownloadsWhileRunning\"\t\t\"0\"")
        lines.append("\t\"ScheduledAutoUpdate\"\t\t\"0\"")

        if let installedDepots, !installedDepots.isEmpty {
            lines.append("\t\"InstalledDepots\"")
            lines.append("\t{")
            for depot in installedDepots {
                lines.append("\t\t\"\(depot.depotID)\"")
                lines.append("\t\t{")
                if let manifestGID = depot.manifestGID {
                    lines.append("\t\t\t\"manifest\"\t\t\"\(manifestGID)\"")
                }
                if let bytes = depot.size {
                    lines.append("\t\t\t\"size\"\t\t\"\(bytes)\"")
                }
                if let dlcAppID = depot.dlcAppID {
                    lines.append("\t\t\t\"dlcappid\"\t\t\"\(dlcAppID)\"")
                }
                lines.append("\t\t}")
            }
            lines.append("\t}")
        }

        // Valve's client records a depot taken from another app
        // (`depotfromapp`) here, not under InstalledDepots, and requires the
        // owner app's own record before it starts the game.
        if !sharedDepots.isEmpty {
            lines.append("\t\"SharedDepots\"")
            lines.append("\t{")
            for shared in sharedDepots.sorted(by: { $0.depotID < $1.depotID }) {
                lines.append("\t\t\"\(shared.depotID)\"\t\t\"\(shared.ownerAppID)\"")
            }
            lines.append("\t}")
        }

        // Files Valve's client customizes per user before launch.
        if !customExecutables.isEmpty {
            lines.append("\t\"CheckGuid\"")
            lines.append("\t{")
            for (index, path) in customExecutables.prefix(256).enumerated() {
                lines.append("\t\t\"\(index)\"\t\t\"\(escapeVDFString(path))\"")
            }
            lines.append("\t}")
        }

        // UserConfig and MountedConfig are present in every record Steam
        // writes; Steam uses them to select language-pack depots. English is
        // always written (the downloader installs English content).
        lines.append("\t\"UserConfig\"")
        lines.append("\t{")
        lines.append("\t\t\"language\"\t\t\"english\"")
        lines.append("\t}")
        lines.append("\t\"MountedConfig\"")
        lines.append("\t{")
        lines.append("\t\t\"language\"\t\t\"english\"")
        lines.append("\t}")

        lines.append("}")

        let content = lines.joined(separator: "\n")

        // A failed install record fails the install instead of leaving
        // downloaded files that no library scan can identify.
        try content.write(toFile: manifestPath, atomically: true, encoding: .utf8)
    }

    /// Records depots installed for another app's shared use under
    /// their owner app, as Valve's client does ("required app N not ready" otherwise).
    /// Depots already in an existing owner record are kept; the depots installed
    /// now replace their older entries. Nothing is recorded that was not installed.
    static func mergeOwnerManifest(ownerAppID: UInt32, ownerName: String, ownerBuildID: UInt32, installDir: String,
                                   steamID: UInt64, steamAppsPath: String,
                                   depots: [InstalledDepot]) throws {
        let path = try SteamStoragePath.native("appmanifest_\(ownerAppID).acf", root: URL(fileURLWithPath: steamAppsPath)).path
        var merged: [Int: InstalledDepot] = [:]
        if let data = FileManager.default.contents(atPath: path), data.count <= 1 << 20,
           var parser = try? SteamKeyValues(data), let root = try? parser.read(),
           let record = root["AppState"], record["appid"]?.string == String(ownerAppID) {
            for (key, value) in record["InstalledDepots"]?.fields ?? [:] {
                guard let id = Int(key), id > 0 else { continue }
                merged[id] = InstalledDepot(depotID: id, manifestGID: value["manifest"]?.string.flatMap { UInt64($0) },
                                            size: value["size"]?.string.flatMap { Int64($0) },
                                            dlcAppID: value["dlcappid"]?.string.flatMap { Int($0) })
            }
        }
        for depot in depots { merged[depot.depotID] = depot }
        let all = merged.values.sorted { $0.depotID < $1.depotID }
        let size = all.reduce(UInt64(0)) { $0 &+ UInt64(max(0, $1.size ?? 0)) }
        try writeManifest(appID: ownerAppID, name: ownerName.isEmpty ? "App \(ownerAppID)" : ownerName,
                          installDir: installDir, buildID: ownerBuildID, steamID: steamID,
                          sizeOnDisk: size, steamAppsPath: steamAppsPath, installedDepots: all)
    }

    /// One depot entry inside `InstalledDepots`. The manifest and size are
    /// optional (Steam tolerates their absence); `dlcAppID` is set only for DLC
    /// depots.
    struct InstalledDepot {
        let depotID: Int
        let manifestGID: UInt64?
        let size: Int64?
        let dlcAppID: Int?

        init(depotID: Int, manifestGID: UInt64? = nil, size: Int64? = nil, dlcAppID: Int? = nil) {
            self.depotID = depotID
            self.manifestGID = manifestGID
            self.size = size
            self.dlcAppID = dlcAppID
        }
    }

    // MARK: - Helpers

    /// Escape special characters for VDF format
    private static func escapeVDFString(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
