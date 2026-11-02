// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// A game's licence (docs/EA.md, "Playing"): EA's activation service grants the
// signed-in account a licence for a game on this machine, and the game's
// activation library (its `Core` folder) checks it at start against the machine
// hash. Madeira asks for the licence with the account's own token, exactly as
// the EA app does, and writes it where the game looks:
// C:\ProgramData\Electronic Arts\EA Services\License. Nothing here bypasses the
// check: a game the account does not own gets no licence.

enum EALicense {
    static let relativeFolder = "ProgramData/Electronic Arts/EA Services/License"
    /// A licence is asked for again after this long (the EA app's own habit).
    static let renewAfter: TimeInterval = 14 * 24 * 3600

    static func folder(drive: URL) -> URL { drive.appendingPathComponent(relativeFolder, isDirectory: true) }

    /// A child of `folder` by name, whatever its case on disk.
    static func child(of folder: URL, named name: String) -> URL? {
        let direct = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.first { $0.caseInsensitiveCompare(name) == .orderedSame }.map { folder.appendingPathComponent($0) }
    }

    /// What the game's activation library expects.
    struct Activation: Equatable {
        /// The game has a `Core` folder: it checks a licence at all.
        var required: Bool
        /// With `Core/activation.exe` the signature stays base64 text; otherwise its bytes.
        var decodeSignature: Bool
        /// Which machine hash the library computes (EAPEVersion.hashVersion).
        var hashVersion: Int
        var libraryVersion: EAPEVersion.Version?
    }

    static func activation(gameFolder: URL) -> Activation {
        guard let core = child(of: gameFolder, named: "Core") else {
            return Activation(required: false, decodeSignature: false, hashVersion: 1, libraryVersion: nil)
        }
        let encoded = child(of: core, named: "activation.exe") != nil
        let library = child(of: core, named: "activation.dll") ?? child(of: core, named: "awc.dll")
        var version: EAPEVersion.Version?
        if let library, let data = try? Data(contentsOf: library, options: .mappedIfSafe) { version = EAPEVersion.productVersion(data) }
        // Without a library the oldest hash; with one whose version is unreadable, the EA
        // app's own fallback (version 1).
        let hashVersion = library == nil ? 1 : EAPEVersion.hashVersion(version)
        return Activation(required: true, decodeSignature: !encoded, hashVersion: hashVersion, libraryVersion: version)
    }

    /// The licence on disk for a content id, if readable.
    static func current(contentID: String, drive: URL) -> EALicenseInfo? {
        let url = folder(drive: drive).appendingPathComponent(contentID + ".dlf")
        guard let data = try? Data(contentsOf: url), let xml = EALicenseFile.unpack(data) else { return nil }
        return EALicenseInfo(xml: xml)
    }

    /// Whether to ask EA for a licence: none on disk, one for another machine hash or
    /// user, or one older than two weeks.
    static func needsRenewal(_ info: EALicenseInfo?, machineHash: String, userID: String, now: Date = Date()) -> Bool {
        guard let info else { return true }
        if info.machineHash != machineHash { return true }
        if !userID.isEmpty, !info.userID.isEmpty, info.userID != userID { return true }
        guard let start = info.startTime else { return true }
        return now.timeIntervalSince(start) > renewAfter
    }

    /// Writes the licence as `<content id>.dlf` and its `_cached` twin.
    static func save(xml: String, signature: String, contentID: String, decodeSignature: Bool, drive: URL) throws {
        guard let file = EALicenseFile.pack(xml: xml, signature: signature, decodeSignature: decodeSignature) else {
            throw EAAPIError.license("bad signature")
        }
        let folder = folder(drive: drive)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try file.write(to: folder.appendingPathComponent(contentID + ".dlf"), options: .atomic)
        try file.write(to: folder.appendingPathComponent(contentID + "_cached.dlf"), options: .atomic)
    }

    /// Asks EA for the game's licence for this machine and saves it. Returns what was granted.
    static func renew(api: EAAPI, contentID: String, profile: EAHardwareProfile, activation: Activation, drive: URL) async throws -> EALicenseInfo {
        let (hash, input) = profile.machineHash(version: activation.hashVersion)
        EALog.event("[ea-license] request hash-version=\(activation.hashVersion) input=\"\(input.replacingOccurrences(of: "\0", with: "\\0"))\" hash=\(hash)")
        let (xml, signature) = try await api.license(contentID: contentID, machineHash: hash)
        guard let info = EALicenseInfo(xml: xml) else { throw EAAPIError.license("unreadable licence") }
        try save(xml: xml, signature: signature, contentID: contentID, decodeSignature: activation.decodeSignature, drive: drive)
        EALog.event("[ea-license] saved content=\(contentID) token=\(info.gameToken == nil ? 0 : 1)")
        return info
    }
}
