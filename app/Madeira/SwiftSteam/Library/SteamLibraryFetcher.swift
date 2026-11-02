// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

/// Fetches the owned games list via Steam's product info service (PICS).
@MainActor
class SteamLibraryFetcher {
    private let session: SteamCMSession

    init(session: SteamCMSession) {
        self.session = session
    }

    // MARK: - Fetch Owned Games

    /// Fetches the account's package IDs from the license list, resolves them
    /// to app IDs and returns the playable apps' metadata.
    func fetchOwnedApps() async throws -> [SteamAppInfo] {
        try await session.ensureConnected()

        // Step 1: the license list (owned packages).
        SteamLog.trace("Fetching license list...")
        let packageIDs = try await fetchLicenseList()
        SteamLog.trace("Got \(packageIDs.count) owned packages")

        // Step 2: PICS access tokens for the packages.
        let packageTokens = try await fetchPICSAccessTokens(packageIDs: packageIDs)

        // Step 3: package info, to extract the app IDs.
        let appIDs = try await fetchAppIDsFromPackages(packageIDs: packageIDs, tokens: packageTokens)
        SteamLog.trace("Found \(appIDs.count) unique app IDs")

        // Step 4: PICS access tokens for the apps.
        let appTokens = try await fetchPICSAccessTokens(appIDs: Array(appIDs))

        // Step 5: app info (name, depots, platform support, ...).
        let appInfos = try await fetchAppInfo(appIDs: Array(appIDs), tokens: appTokens)
        SteamLog.trace("Got info for \(appInfos.count) apps")

        // Playable types only: games, demos and applications. This leaves out
        // DLC, soundtracks and tools (redistributables, runtimes, SDKs, servers).
        // The owned DLC are kept aside for their games' downloads (SteamDLC).
        let games = appInfos.filter { $0.type.isPlayable }
        ownedDLC = appInfos.filter { $0.type == .dlc }
        SteamLog.trace("\(games.count) of \(appInfos.count) apps are playable (game/demo/application), \(ownedDLC.count) DLC")
        return games
    }

    /// The DLC apps of the account's licenses, from the last fetchOwnedApps.
    private(set) var ownedDLC: [SteamAppInfo] = []

    /// Depot IDs included in the account's licenses, from the same package
    /// info the library uses (`depotids`). The installer consults it only when
    /// Steam refuses a depot key, to leave out a depot the account does not
    /// own (another edition, extra content). Cached per session.
    private var ownedDepotCache: Set<UInt32>?
    func ownedDepotIDs() async throws -> Set<UInt32> {
        if let cached = ownedDepotCache { return cached }
        try await session.ensureConnected()
        let packageIDs = try await fetchLicenseList()
        let tokens = try await fetchPICSAccessTokens(packageIDs: packageIDs)
        var depots = Set<UInt32>()
        for start in stride(from: 0, to: packageIDs.count, by: 50) {
            var request = CMsgClientPICSProductInfoRequest()
            request.packages = packageIDs[start..<min(start + 50, packageIDs.count)].map {
                CMsgClientPICSProductInfoRequest.PackageInfo(packageid: $0, accessToken: tokens[$0] ?? 0)
            }
            let responses = try await session.sendAndWaitPICS(eMsg: .clientPICSProductInfoRequest,
                                                              body: request.serialize(), timeout: 30)
            for response in responses {
                let pics = try CMsgClientPICSProductInfoResponse.deserialize(from: response.body)
                for pkg in pics.packages { depots.formUnion(VDFParser.parsePackageIDs(key: "depotids", from: pkg.buffer)) }
            }
        }
        ownedDepotCache = depots
        return depots
    }

    /// Fetches PICS info for a single app on demand: one token round trip and
    /// one product-info round trip, no license list. Connects the session if it
    /// sits idle-disconnected.
    func fetchAppInfo(appID: UInt32) async throws -> SteamAppInfo? {
        try await session.ensureConnected()
        let tokens = try await fetchPICSAccessTokens(appIDs: [appID])
        return try await fetchAppInfo(appIDs: [appID], tokens: tokens).first
    }

    /// Fetches PICS info for several apps in one token and one product-info
    /// round trip (DLC names for Game details).
    func fetchAppInfos(appIDs: [UInt32]) async throws -> [SteamAppInfo] {
        guard !appIDs.isEmpty else { return [] }
        try await session.ensureConnected()
        let tokens = try await fetchPICSAccessTokens(appIDs: appIDs)
        return try await fetchAppInfo(appIDs: appIDs, tokens: tokens)
    }

    // MARK: - Install metadata

    /// The app's metadata for an install, with the content metadata of the
    /// apps it shares depots with resolved. This never supplies depot keys or
    /// grants access: every later content request still goes to Valve.
    func fetchInstallInfo(appID: UInt32) async throws -> SteamAppInfo? {
        try Task.checkCancellation()
        guard var app = try await fetchAppInfo(appID: appID) else { return nil }
        try Task.checkCancellation()
        var owners: [UInt32: SteamAppInfo] = [appID: app]
        var visited: Set<UInt32> = [appID], references = Set<String>()
        func eligible(_ d: SteamAppInfo.DepotInfo) -> Bool {
            !d.isSharedInstall && d.dlcAppID == nil && d.supports(os: "windows") &&
                !d.lowViolence && (d.language.isEmpty || ["english", SteamLanguage.download(for: appID)].contains(d.language.lowercased()))
        }
        var pending = app.depots.filter { eligible($0) && $0.publicManifestID == nil && $0.fromApp != nil }
            .map { ($0.fromApp!, $0.depotID) }
        // Redistributables (sharedinstall) resolve the same way, but a missing one
        // never fails the install: the game's own content does not depend on it.
        pending += app.redistDepots().filter { $0.publicManifestID == nil }.map { ($0.fromApp!, $0.depotID) }
        while let (id, depotID) = pending.popLast() {
            try Task.checkCancellation()
            if !references.insert("\(id):\(depotID)").inserted { continue }
            guard references.count <= 1024 else { throw SteamFileError.invalid("Too many shared content references.") }
            if visited.insert(id).inserted {
                guard visited.count <= 32 else { throw SteamFileError.invalid("Too many shared content dependencies.") }
                owners[id] = try await fetchAppInfo(appID: id)
            }
            if let source = owners[id]?.depots.first(where: { $0.depotID == depotID }),
               source.publicManifestID == nil, let next = source.fromApp {
                pending.append((next, depotID))
            }
        }
        // A bounded fixed point handles nested sharing without recursion or cycles.
        try Task.checkCancellation()
        for _ in 0..<owners.count {
            var changed = 0
            for id in owners.keys.sorted() {
                var owner = owners[id]!
                changed += owner.inheritDepots(from: owners)
                owners[id] = owner
            }
            if changed == 0 { break }
        }
        let resolved = app.inheritDepots(from: owners)
        let missing = app.depots.filter { eligible($0) && $0.fromApp != nil && $0.publicManifestID == nil }
        SteamLog.event("[steam-shared] app=\(appID) owners=\(visited.count - 1) resolved=\(resolved) missing=\(missing.count)")
        guard missing.isEmpty else { throw SteamFileError.invalid("Steam did not provide required shared content metadata. Refresh and retry the download.") }
        // The direct owner of each selected shared depot, for its install
        // record. Metadata only; Valve still decides access and launch readiness.
        let redist = app.redistDepots().filter { $0.publicManifestID != nil }
        if !redist.isEmpty {
            SteamLog.event("[steam-redist] app=\(appID) depots=\(redist.map { "\($0.depotID)<\($0.fromApp!)" }.joined(separator: ","))")
        }
        for id in Set(app.installDepots().compactMap(\.fromApp) + redist.compactMap(\.fromApp)).subtracting([appID]).sorted() {
            try Task.checkCancellation()
            if owners[id] == nil {
                guard owners.count <= 64 else { break }
                owners[id] = try await fetchAppInfo(appID: id)
            }
            if let owner = owners[id] {
                app.sharedOwners[id] = .init(name: owner.name, installDir: owner.installDir, buildID: owner.buildID)
            }
        }
        return app
    }

    // MARK: - Beta branches

    /// The private branches a beta code opens for an app (CheckAppBetaPassword),
    /// by name, with the key Steam takes for each one's depot section. Empty
    /// when Steam does not accept the code. The code is sent only to Steam.
    func checkBetaCode(appID: UInt32, code: String) async throws -> [String: Data] {
        try await session.ensureConnected()
        var request = ProtobufEncoder()
        request.writeUInt32(fieldNumber: 1, value: appID)
        request.writeString(fieldNumber: 2, value: code)
        let response = try await session.sendAndWait(eMsg: .clientCheckAppBetaPassword, body: request.data,
                                                     responseEMsg: .clientCheckAppBetaPasswordResponse, timeout: 15)
        var decoder = ProtobufDecoder(response.body)
        var result: UInt64 = 0
        var keys: [String: Data] = [:]
        while let tag = try decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, .varint): result = try decoder.readVarint()
            case (4, .lengthDelimited):
                var entry = ProtobufDecoder(try decoder.readBytes())
                var name = "", hex = ""
                while let field = try entry.readTag() {
                    switch (field.fieldNumber, field.wireType) {
                    case (1, .lengthDelimited): name = try entry.readString()
                    case (2, .lengthDelimited): hex = try entry.readString()
                    default: try entry.skip(wireType: field.wireType)
                    }
                }
                if SteamAppInfo.validBranchName(name), keys.count < 64, let key = Self.hexBytes(hex) { keys[name] = key }
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        SteamLog.event("[steam-branch] code-check app=\(appID) eresult=\(result) private=\(keys.count)")
        return result == 1 ? keys : [:]
    }

    /// The depot section of a private branch (PICSPrivateBeta), parsed; `key`
    /// is the branch's entry from checkBetaCode.
    func privateBranchDepots(appID: UInt32, branch: String, key: Data) async throws -> [String: Any] {
        try await session.ensureConnected()
        let tokens = try await fetchPICSAccessTokens(appIDs: [appID])
        var request = ProtobufEncoder()
        request.writeUInt32(fieldNumber: 1, value: appID)
        request.writeUInt64(fieldNumber: 2, value: tokens[appID] ?? 0)
        request.writeString(fieldNumber: 3, value: branch)
        request.writeBytes(fieldNumber: 4, value: key)
        let response = try await session.sendAndWait(eMsg: .clientPICSPrivateBetaRequest, body: request.data,
                                                     responseEMsg: .clientPICSPrivateBetaResponse, timeout: 30)
        var decoder = ProtobufDecoder(response.body)
        var result: UInt64 = 0
        var section = Data()
        while let tag = try decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, .varint): result = try decoder.readVarint()
            case (2, .lengthDelimited): section = try decoder.readBytes()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        SteamLog.event("[steam-branch] private-depots app=\(appID) eresult=\(result) bytes=\(section.count)")
        guard result == 1, section.count <= 4 << 20 else { return [:] }
        return VDFParser.parseBinaryVDF(from: section)
    }

    /// Points install info at a branch: `branch` when PICS lists it, else public.
    /// A password-protected branch first takes its manifests from Steam with the
    /// beta code (`code`); without a code Steam accepts, the install stops
    /// instead of quietly taking the public build.
    func applyBranch(_ app: inout SteamAppInfo, branch: String, code: String?) async throws {
        guard branch != SteamAppInfo.publicBranch, let entry = app.branches.first(where: { $0.name == branch }) else {
            if branch != SteamAppInfo.publicBranch { SteamLog.event("[steam-branch] app=\(app.appID) branch-gone=1 using=public") }
            app.branch = SteamAppInfo.publicBranch
            return
        }
        if entry.passwordRequired {
            guard let code, let key = try await checkBetaCode(appID: app.appID, code: code)[branch] else {
                throw SteamError.betaCodeNeeded(branch)
            }
            let section = try await privateBranchDepots(appID: app.appID, branch: branch, key: key)
            let added = app.addPrivateBranch(branch, depots: section)
            SteamLog.event("[steam-branch] app=\(app.appID) private-manifests=\(added)")
            guard added > 0 else { throw SteamError.betaCodeNeeded(branch) }
        }
        app.branch = branch
    }

    nonisolated static func hexBytes(_ hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard !digits.isEmpty, digits.count % 2 == 0, digits.count <= 256 else { return nil }
        var bytes = Data(capacity: digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    // MARK: - License List

    private func fetchLicenseList() async throws -> [UInt32] {
        try await session.awaitLicenseList(timeout: 15)
    }

    // MARK: - PICS Access Tokens

    private func fetchPICSAccessTokens(appIDs: [UInt32] = [], packageIDs: [UInt32] = []) async throws -> [UInt32: UInt64] {
        var request = CMsgClientPICSAccessTokenRequest()
        request.appids = appIDs
        request.packageids = packageIDs

        let response = try await session.sendAndWait(
            eMsg: .clientPICSAccessTokenRequest,
            body: request.serialize(),
            responseEMsg: .clientPICSAccessTokenResponse,
            timeout: 30
        )

        let tokenResponse = try CMsgClientPICSAccessTokenResponse.deserialize(from: response.body)

        var tokens: [UInt32: UInt64] = [:]
        for appToken in tokenResponse.appAccessTokens {
            tokens[appToken.appid] = appToken.accessToken
        }
        for pkgToken in tokenResponse.packageAccessTokens {
            tokens[pkgToken.packageid] = pkgToken.accessToken
        }

        return tokens
    }

    // MARK: - Package Info → App IDs

    private func fetchAppIDsFromPackages(packageIDs: [UInt32], tokens: [UInt32: UInt64]) async throws -> Set<UInt32> {
        var allAppIDs = Set<UInt32>()

        // Package info requests in batches of 50.
        let batches = stride(from: 0, to: packageIDs.count, by: 50).map {
            Array(packageIDs[$0..<min($0 + 50, packageIDs.count)])
        }

        for batch in batches {
            var request = CMsgClientPICSProductInfoRequest()
            request.packages = batch.map { pkgID in
                CMsgClientPICSProductInfoRequest.PackageInfo(
                    packageid: pkgID,
                    accessToken: tokens[pkgID] ?? 0
                )
            }

            let responses = try await session.sendAndWaitPICS(
                eMsg: .clientPICSProductInfoRequest,
                body: request.serialize(),
                timeout: 30
            )

            for response in responses {
                let picsResponse = try CMsgClientPICSProductInfoResponse.deserialize(from: response.body)
                for pkg in picsResponse.packages {
                    allAppIDs.formUnion(VDFParser.parsePackageAppIDs(from: pkg.buffer))
                }
            }
        }

        return allAppIDs
    }

    // MARK: - App Info

    private func fetchAppInfo(appIDs: [UInt32], tokens: [UInt32: UInt64]) async throws -> [SteamAppInfo] {
        var allApps: [SteamAppInfo] = []

        // App info requests in batches of 50.
        let batches = stride(from: 0, to: appIDs.count, by: 50).map {
            Array(appIDs[$0..<min($0 + 50, appIDs.count)])
        }

        for batch in batches {
            var request = CMsgClientPICSProductInfoRequest()
            request.apps = batch.map { appID in
                CMsgClientPICSProductInfoRequest.AppInfo(
                    appid: appID,
                    accessToken: tokens[appID] ?? 0
                )
            }

            let responses = try await session.sendAndWaitPICS(
                eMsg: .clientPICSProductInfoRequest,
                body: request.serialize(),
                timeout: 30
            )

            for response in responses {
                let picsResponse = try CMsgClientPICSProductInfoResponse.deserialize(from: response.body)
                for app in picsResponse.apps {
                    if let info = SteamAppInfo.parse(appID: app.appid, from: app.buffer) {
                        allApps.append(info)
                    }
                }
            }
        }

        return allApps
    }
}

// MARK: - Simple VDF Binary Parser

/// Parses Valve Data Format (binary) used in PICS responses
enum VDFParser {
    // VDF binary types
    private static let typeNone: UInt8 = 0x00
    private static let typeString: UInt8 = 0x01
    private static let typeInt32: UInt8 = 0x02
    private static let typeEnd: UInt8 = 0x08

    /// Parse a binary KeyValues blob (a private branch's depot section) into
    /// the nested dictionary `parseTextVDF` returns: numbers become their
    /// decimal text, so the same app-info code reads both. Bounded: 16 levels,
    /// 65536 entries; a malformed blob yields what was read before it.
    static func parseBinaryVDF(from data: Data) -> [String: Any] {
        let bytes = [UInt8](data)
        var i = 0, entries = 0
        func string() -> String? {
            guard let end = bytes[i...].firstIndex(of: 0) else { return nil }
            defer { i = end + 1 }
            return String(decoding: bytes[i..<end], as: UTF8.self)
        }
        func integer(_ size: Int) -> UInt64? {
            guard i + size <= bytes.count else { return nil }
            defer { i += size }
            return bytes[i..<i + size].reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }
        func section(_ depth: Int) -> [String: Any] {
            var result: [String: Any] = [:]
            while i < bytes.count, entries < 65_536 {
                let type = bytes[i]; i += 1
                if type == typeEnd || type == 0x0B { break }
                guard let key = string() else { break }
                entries += 1
                switch type {
                case typeNone:
                    guard depth < 16 else { return result }
                    result[key] = section(depth + 1)
                case typeString:
                    guard let value = string() else { return result }
                    result[key] = value
                case typeInt32:
                    guard let value = integer(4) else { return result }
                    result[key] = String(Int32(truncatingIfNeeded: value))
                case 0x03, 0x04, 0x06:  // float, pointer, color: 4 bytes
                    guard let value = integer(4) else { return result }
                    result[key] = String(value)
                case 0x07:  // uint64
                    guard let value = integer(8) else { return result }
                    result[key] = String(value)
                case 0x0A:  // int64
                    guard let value = integer(8) else { return result }
                    result[key] = String(Int64(bitPattern: value))
                default:
                    return result  // wide strings and unknown types: stop
                }
            }
            return result
        }
        return section(0)
    }

    /// Parse a text-format VDF / KeyValues blob into a nested dictionary.
    /// Steam PICS sends *app* product info in this text format (`"key" "value"`
    /// pairs and `"key" { ... }` sections) — package info uses the binary
    /// format. Leaf values are always `String`. Steam escapes `"` and `\` inside
    /// a quoted string (for example a launch argument `/Name=\"Two Words\"`); read
    /// verbatim, such a string ends early and every later section, the depots
    /// among them, is lost.
    static func parseTextVDF(from data: Data) -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        let scalars = Array(text.unicodeScalars)
        var i = 0
        let n = scalars.count

        func skipWhitespaceAndComments() {
            while i < n {
                let c = scalars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    i += 1
                } else if c == "/" && i + 1 < n && scalars[i + 1] == "/" {
                    while i < n && scalars[i] != "\n" { i += 1 }
                } else {
                    break
                }
            }
        }

        func nextToken() -> String? {
            skipWhitespaceAndComments()
            guard i < n else { return nil }
            let c = scalars[i]
            if c == "{" || c == "}" {
                i += 1
                return String(c)
            }
            var s = ""
            if c == "\"" {
                i += 1
                while i < n && scalars[i] != "\"" {
                    // \" and \\ are escapes; any other backslash is literal (paths).
                    if scalars[i] == "\\", i + 1 < n, scalars[i + 1] == "\"" || scalars[i + 1] == "\\" {
                        s.unicodeScalars.append(scalars[i + 1])
                        i += 2
                        continue
                    }
                    s.unicodeScalars.append(scalars[i])
                    i += 1
                }
                i += 1 // closing quote
                return s
            }
            while i < n {
                let ch = scalars[i]
                if ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
                    || ch == "{" || ch == "}" || ch == "\"" { break }
                s.unicodeScalars.append(ch)
                i += 1
            }
            return s
        }

        func parseSection() -> [String: Any] {
            var dict: [String: Any] = [:]
            while let key = nextToken() {
                if key == "}" { break }
                if key == "{" { continue }
                guard let value = nextToken() else { break }
                if value == "{" {
                    dict[key] = parseSection()
                } else if value == "}" {
                    break
                } else {
                    dict[key] = value
                }
            }
            return dict
        }

        return parseSection()
    }

    /// Extract app IDs from a binary VDF package info buffer
    static func parsePackageAppIDs(from data: Data) -> [UInt32] {
        parsePackageIDs(key: "appids", from: data)
    }

    /// The same scan for any id list in a package ("appids", "depotids").
    static func parsePackageIDs(key searchKey: String, from data: Data) -> [UInt32] {
        var appIDs: [UInt32] = []
        var offset = 0

        // Look for the requested section and extract UInt32 values
        // This is a simplified parser that searches for known patterns
        if let range = findKey(searchKey, in: data) {
            offset = range
            // After "appids" key, we expect sub-keys with numeric names and uint32 values
            while offset < data.count {
                guard offset < data.count else { break }
                let type = data[offset]
                offset += 1

                if type == typeEnd { break }

                // Read key name (null-terminated string)
                guard let (_, newOffset) = readNullTerminatedString(from: data, at: offset) else { break }
                offset = newOffset

                if type == typeInt32 {
                    guard offset + 4 <= data.count else { break }
                    let value = data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                    appIDs.append(UInt32(littleEndian: value))
                    offset += 4
                } else if type == typeString {
                    guard let (_, newOff) = readNullTerminatedString(from: data, at: offset) else { break }
                    offset = newOff
                } else if type == typeNone {
                    // Sub-section - skip or recurse
                    continue
                }
            }
        }

        return appIDs
    }

    private static func findKey(_ key: String, in data: Data) -> Int? {
        let keyBytes = Array(key.utf8) + [0] // null-terminated
        let keyData = Data(keyBytes)
        guard data.count >= keyData.count else { return nil }

        for i in 0..<(data.count - keyData.count) {
            if data[i..<i + keyData.count] == keyData {
                return i + keyData.count
            }
        }
        return nil
    }

    private static func readNullTerminatedString(from data: Data, at offset: Int) -> (String, Int)? {
        var end = offset
        while end < data.count && data[end] != 0 {
            end += 1
        }
        guard end < data.count else { return nil }
        let str = String(data: data[offset..<end], encoding: .utf8) ?? ""
        return (str, end + 1)
    }
}
