// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

/// App metadata parsed from Steam's product info (PICS).
struct SteamAppInfo {
    let appID: UInt32
    var name: String = ""
    var type: AppType = .game
    var installDir: String = ""
    var oslist: String = ""         // "macos", "windows", "macos,windows", etc.
    var depots: [DepotInfo] = []
    var buildID: UInt32 = 0
    var freeToDownload = false
    /// Apps owning depots this app installs through `depotfromapp`, so the
    /// install record names them the way Valve's client does.
    var sharedOwners: [UInt32: SharedOwner] = [:]
    /// Store artwork file names from `common.library_assets_full` and
    /// `common.header_image`. Newer apps publish them under a hashed folder, so
    /// the fixed legacy URL is missing for them. `parentID` names a demo's full game.
    var libraryCapsule: String?
    var libraryHero: String?
    var headerImage: String?
    var parentID: UInt32?
    /// Steam's launch configuration (`config.launch`), in Steam's order.
    /// SteamDirectStart and Madeira Dock select an installed Windows entry;
    /// Dock passes its original key to Valve's client.
    var launches: [SteamLaunchOption] = []
    /// Steam API language names the app supports (`common.supported_languages`
    /// or `common.languages`), lowercased. Empty when PICS lists none.
    var languages: Set<String> = []
    /// Steam Auto-Cloud configuration (`ufs`): which files of the game are its
    /// saves, and where another platform keeps them. Empty for a game that
    /// only uses the Steam Cloud API (its files live in the user's `remote` folder).
    var saveFiles: [SaveFile] = []
    var rootOverrides: [RootOverride] = []
    /// The DLC the app lists (`extended.listofdlc`), in Steam's order. A DLC's
    /// files are the app's depots that name it (`DepotInfo.dlcAppID`).
    var dlcList: [UInt32] = []
    /// The DLC apps an install leaves out although the account owns them: the
    /// ones the player turned off (SteamDLC). Empty by default.
    var dlcOff: Set<UInt32> = []
    /// Steam's branches of the app (`depots.branches`): "public" and its betas,
    /// by name. A password-protected one (`pwdrequired`) needs its beta code
    /// before Steam names its manifests (SteamLibraryFetcher.applyBranch).
    var branches: [Branch] = []
    /// The branch an install takes (SteamBranch, Game details › Steam ›
    /// Version): "public" unless the player picked a beta.
    var branch = SteamAppInfo.publicBranch

    static let publicBranch = "public"

    /// One `depots.branches` entry. Untrusted text, bounded when parsed.
    struct Branch: Codable, Hashable, Sendable {
        var name: String
        var buildID: UInt32
        var description: String
        var passwordRequired: Bool
        /// `timeupdated`, Unix seconds; 0 when PICS states none.
        var updated: Int
    }

    /// The build the chosen branch publishes, as the install record states it.
    /// The public build for "public" and for a branch PICS does not list.
    var branchBuildID: UInt32 {
        guard branch != Self.publicBranch, let entry = branches.first(where: { $0.name == branch }), entry.buildID > 0 else { return buildID }
        return entry.buildID
    }

    /// One `ufs.savefiles` entry: `root` names a folder ("WinAppDataLocalLow",
    /// "GameInstall", ...), `path` a subfolder of it, `pattern` a wildcard.
    struct SaveFile: Equatable {
        var root: String
        var path: String
        var pattern: String
        var recursive: Bool
        /// Lower-cased platform names the entry is limited to; empty = all.
        var platforms: [String]
    }

    /// One `ufs.rootoverrides` entry: on `os`, files the cloud lists under
    /// `root` are kept under `useInstead` + `addPath`.
    struct RootOverride: Equatable {
        var root: String
        var os: String
        var useInstead: String
        var addPath: String
    }

    struct SharedOwner: Equatable {
        var name: String
        var installDir: String
        var buildID: UInt32
    }

    enum AppType: String {
        case game = "Game"
        case dlc = "DLC"
        case tool = "Tool"
        case demo = "Demo"
        case application = "Application"
        case music = "Music"
        case unknown = ""

        var isPlayable: Bool {
            self == .game || self == .demo || self == .application
        }

        /// PICS does not capitalize type names consistently (older apps send
        /// "game" rather than "Game"), so names match without case.
        init(pics raw: String) {
            if let exact = AppType(rawValue: raw) { self = exact; return }
            self = [AppType.game, .dlc, .tool, .demo, .application, .music]
                .first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame } ?? .unknown
        }
    }

    struct DepotInfo {
        var depotID: UInt32
        var name: String = ""
        var maxSize: UInt64 = 0
        var oslist: String = ""     // "macos", "windows", etc.
        var osarch: String = ""     // "64", "32"
        var dlcAppID: UInt32? = nil
        var manifests: [String: UInt64] = [:]  // branch -> manifestID ("public" is default)
        /// Compressed download size from the modern manifests-dict format
        /// (`manifests.public.download`). 0 when PICS sent the legacy flat
        /// gid format or omitted it.
        var publicDownloadBytes: UInt64 = 0
        /// On-disk size from `manifests.public.size`. 0 when absent.
        var publicSizeBytes: UInt64 = 0
        /// `sharedinstall "1"` marks redistributable depots (DirectX, VC++
        /// runtimes) that live in Steam's common store, not the game dir;
        /// they are excluded from size math.
        var isSharedInstall: Bool = false
        /// `config.language`: empty for common content, otherwise one
        /// language pack ("english", "german", ...).
        var language: String = ""
        /// `config.lowviolence "1"`: regional alternate content.
        var lowViolence: Bool = false
        /// `depotfromapp`: the depot belongs to another app, and Valve's client
        /// installs it as that app ("required app N").
        var fromApp: UInt32? = nil

        /// Check if depot is for the specified OS
        func supports(os: String) -> Bool {
            oslist.isEmpty || oslist.lowercased().contains(os.lowercased())
        }

        /// Get the public branch manifest ID
        var publicManifestID: UInt64? {
            manifests["public"]
        }

        /// The manifest an install of `branch` takes: the branch's own, else the
        /// public one, as Valve's client keeps a depot a beta does not change.
        func manifestID(_ branch: String) -> UInt64? {
            manifests[branch] ?? publicManifestID
        }

        /// Whether `branch` is a beta with its own manifest of this depot: the
        /// manifest request code then names the branch.
        func hasOwnManifest(_ branch: String) -> Bool {
            branch != SteamAppInfo.publicBranch && manifests[branch] != nil
        }
    }

    // MARK: - Computed Properties

    /// Shared depots often omit manifests in the consuming app's PICS. Copies
    /// content metadata from the exact depot of its owner, keeping the
    /// consumer's own filters. Returns how many depots were completed.
    mutating func inheritDepots(from owners: [UInt32: SteamAppInfo]) -> Int {
        var changed = 0
        for index in depots.indices {
            let local = depots[index]
            guard local.publicManifestID == nil, let owner = local.fromApp,
                  let source = owners[owner]?.depots.first(where: { $0.depotID == local.depotID }),
                  source.publicManifestID != nil else { continue }
            depots[index].manifests = source.manifests
            depots[index].publicDownloadBytes = source.publicDownloadBytes
            depots[index].publicSizeBytes = source.publicSizeBytes
            if local.oslist.isEmpty { depots[index].oslist = source.oslist }
            if local.osarch.isEmpty { depots[index].osarch = source.osarch }
            if local.language.isEmpty { depots[index].language = source.language }
            depots[index].lowViolence = local.lowViolence || source.lowViolence
            changed += 1
        }
        return changed
    }

    var supportsWindows: Bool {
        oslist.lowercased().contains("windows") || oslist.isEmpty
    }

    /// The language-pack depots to install: the chosen download language
    /// (SteamLanguage) when the app has depots for it, else English, as
    /// Valve's client falls back.
    var depotLanguage: String {
        let wanted = SteamLanguage.download(for: appID)
        return depots.contains { $0.language.caseInsensitiveCompare(wanted) == .orderedSame } ? wanted : "english"
    }

    /// The language the install record names, which Valve's client reports to
    /// the game (`GetCurrentGameLanguage`): the chosen download language when
    /// the app supports it, even with no depot of its own (text in the common
    /// content), else the depot language.
    var gameLanguage: String {
        let wanted = SteamLanguage.download(for: appID)
        return languages.contains(wanted) ? wanted : depotLanguage
    }

    /// The depots a Windows install takes: matching OS, architecture-neutral
    /// or matching osarch, common or requested-language content (by default
    /// `depotLanguage`), no low-violence alternates, no shared
    /// redistributables, and only depots that publish a manifest for the chosen
    /// branch (`branch`, else the public one). A
    /// DLC depot (dlcappid) is taken only when the account's licenses include
    /// it (`ownedDLC`, depot IDs), as Valve's client installs owned DLC with
    /// the game: New Vegas's Courier's Stash packs are DLC depots of the game.
    /// A DLC the player turned off (`dlcOff`, SteamDLC) is left out.
    /// A 64-bit selection falls back to 32-bit depots when the app only
    /// publishes those.
    func installDepots(os: String = "windows", arch: String = "64",
                       language: String? = nil, ownedDLC: Set<UInt32> = []) -> [DepotInfo] {
        let language = language ?? depotLanguage
        func select(_ arch: String) -> [DepotInfo] {
            depots.filter { d in
                d.supports(os: os) && !d.isSharedInstall &&
                (d.dlcAppID.map { ownedDLC.contains(d.depotID) && !dlcOff.contains($0) } ?? true) &&
                d.manifestID(branch) != nil && !d.lowViolence &&
                (d.osarch.isEmpty || d.osarch == arch) &&
                (d.language.isEmpty || d.language.caseInsensitiveCompare(language) == .orderedSame)
            }.sorted { $0.depotID < $1.depotID }
        }
        let preferred = select(arch)
        if arch == "64", !preferred.contains(where: { $0.osarch == "64" }),
           depots.contains(where: { $0.osarch == "32" && $0.supports(os: os) }) {
            return select("32")
        }
        return preferred
    }

    /// The `sharedinstall` redistributables (DirectX, VC++ runtimes) another app
    /// owns, usually Steamworks Common Redistributables (228980), that a Windows
    /// install of this app names: matching OS and language, no low-violence
    /// alternates. Valve's client records them under the game's SharedDepots and
    /// refuses to start the game ("required app 228980 not ready") until the
    /// owner app is installed with them, so they are downloaded into the
    /// owner's folder and recorded there.
    func redistDepots(os: String = "windows", language: String? = nil) -> [DepotInfo] {
        let language = language ?? depotLanguage
        return depots.filter { d in
            d.isSharedInstall && d.fromApp != nil && d.fromApp != appID && d.dlcAppID == nil &&
                d.supports(os: os) && !d.lowViolence &&
                (d.language.isEmpty || d.language.caseInsensitiveCompare(language) == .orderedSame)
        }.sorted { $0.depotID < $1.depotID }
    }

    /// Every depot with why it was or was not selected, for the install log
    /// ("sel", or the first failing rule). IDs and flags only.
    func depotSelectionSummary(os: String = "windows", arch: String = "64",
                               language: String? = nil, ownedDLC: Set<UInt32> = [], limit: Int = 24) -> String {
        let language = language ?? depotLanguage
        let chosen = Set(installDepots(os: os, arch: arch, language: language, ownedDLC: ownedDLC).map(\.depotID))
        return depots.sorted { $0.depotID < $1.depotID }.prefix(limit).map { d in
            let why = selectionRule(d, chosen: chosen, os: os, language: language)
            let from = d.fromApp.map { "<\($0)" } ?? ""
            return "\(d.depotID)[\(d.osarch.isEmpty ? "-" : d.osarch)]\(why)\(from)"
        }.joined(separator: ",")
    }

    /// "sel" or the first rule that left the depot out.
    private func selectionRule(_ d: DepotInfo, chosen: Set<UInt32>, os: String, language: String) -> String {
        if chosen.contains(d.depotID) { return "sel" }
        if !d.supports(os: os) { return "os" }
        if d.dlcAppID != nil { return "dlc" }
        if d.isSharedInstall { return "shared" }
        if d.manifestID(branch) == nil { return "nomanifest" }
        if d.lowViolence { return "lowviolence" }
        if !d.language.isEmpty && d.language.caseInsensitiveCompare(language) != .orderedSame { return "lang" }
        return "arch"
    }

    /// Owned apps that can be installed for Windows at all.
    var installableOnWindows: Bool {
        supportsWindows && type.isPlayable && !installDepots().isEmpty
    }

    /// The depots one DLC adds to a Windows install of this app when owned: the
    /// depots that name it and pass the same rules as the app's own (OS,
    /// architecture, language). Empty for a DLC that only unlocks content.
    func dlcDepots(_ dlcID: UInt32, os: String = "windows", arch: String = "64",
                   language: String? = nil) -> [DepotInfo] {
        let own = Set(depots.filter { $0.dlcAppID == dlcID }.map(\.depotID))
        return installDepots(os: os, arch: arch, language: language, ownedDLC: own).filter { $0.dlcAppID == dlcID }
    }

    /// The DLC this app knows: the ones it lists and the ones its depots name,
    /// without itself; at most 1024.
    var knownDLC: [UInt32] {
        var seen = Set<UInt32>(), result: [UInt32] = []
        for id in dlcList + depots.sorted(by: { $0.depotID < $1.depotID }).compactMap(\.dlcAppID)
        where id != appID && seen.insert(id).inserted {
            result.append(id)
            if result.count == 1024 { break }
        }
        return result
    }

    /// Approximate compressed download size for a platform. Per depot it
    /// prefers the modern `manifests.public.download` figure (present for most
    /// apps since Valve's 2023 PICS change) and falls back to the legacy
    /// `maxsize`. DLC depots and `sharedinstall` redistributables are not part
    /// of the base install and are left out. Treat the figure as "about".
    func downloadSize(for os: String) -> UInt64 {
        installDepots(os: os).reduce(0) { total, d in
            let bytes = d.publicDownloadBytes > 0 ? d.publicDownloadBytes : d.maxSize
            guard bytes > 0 else { return total }
            // Sizes are parsed from untrusted PICS VDF strings with no bound:
            // saturate instead of trapping if a malformed depot overflows the sum.
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            return overflow ? UInt64.max : sum
        }
    }

    /// Approximate installed size for a platform: `manifests.public.size` per
    /// selected depot, else its download figure. Same selection and caveats as
    /// downloadSize (shared depots whose owner's product info was not read count 0).
    func installSize(for os: String) -> UInt64 {
        installDepots(os: os).reduce(0) { total, d in
            let bytes = d.publicSizeBytes > 0 ? d.publicSizeBytes : (d.publicDownloadBytes > 0 ? d.publicDownloadBytes : d.maxSize)
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            return overflow ? UInt64.max : sum
        }
    }

    // MARK: - Parsing

    /// Parse app info from a PICS text-VDF buffer.
    static func parse(appID: UInt32, from data: Data) -> SteamAppInfo? {
        let vdf = VDFParser.parseTextVDF(from: data)
        return parse(appID: appID, from: vdf)
    }

    /// Parse app info from a VDF dictionary
    static func parse(appID: UInt32, from vdf: [String: Any]) -> SteamAppInfo? {
        var info = SteamAppInfo(appID: appID)

        // Navigate to appinfo section
        let appInfo: [String: Any]
        if let nested = vdf["\(appID)"] as? [String: Any] {
            appInfo = nested
        } else if let nested = vdf["appinfo"] as? [String: Any] {
            appInfo = nested
        } else {
            appInfo = vdf
        }

        // Common section
        if let common = appInfo["common"] as? [String: Any] {
            info.name = common["name"] as? String ?? ""
            info.type = AppType(pics: common["type"] as? String ?? "")
            info.oslist = common["oslist"] as? String ?? ""
            info.freeToDownload = (common["freetodownload"] as? String) == "1"
            // Artwork names, English first, else any language.
            func asset(_ node: Any?) -> String? {
                guard let languages = node as? [String: Any] else { return nil }
                let value = (languages["english"] as? String) ?? languages.keys.sorted().compactMap { languages[$0] as? String }.first
                guard let value, !value.isEmpty, value.utf8.count <= 256, !value.contains(".."), !value.hasPrefix("/") else { return nil }
                return value
            }
            if let assets = common["library_assets_full"] as? [String: Any] {
                let capsule = assets["library_capsule"] as? [String: Any]
                info.libraryCapsule = asset(capsule?["image2x"]) ?? asset(capsule?["image"])
                info.libraryHero = asset((assets["library_hero"] as? [String: Any])?["image"])
            }
            info.headerImage = asset(common["header_image"])
            if let parent = (common["parent"] as? String).flatMap(UInt32.init), parent != 0, parent != info.appID {
                info.parentID = parent
            }
            // supported_languages: name -> {supported, full_audio, ...};
            // languages: name -> "1" (older apps).
            for key in ["supported_languages", "languages"] {
                guard let table = common[key] as? [String: Any] else { continue }
                for (name, value) in table.prefix(64) where name.utf8.count <= 32 {
                    let flag = ((value as? [String: Any])?["supported"] as? String) ?? (value as? String) ?? ""
                    if !["0", "false"].contains(flag.lowercased()) { info.languages.insert(name.lowercased()) }
                }
            }
        }

        // Extended section: the DLC the app lists, "id,id,...". Untrusted text, bounded.
        if let extended = appInfo["extended"] as? [String: Any],
           let list = extended["listofdlc"] as? String, list.utf8.count <= 64 << 10 {
            info.dlcList = list.split(separator: ",").prefix(1024)
                .compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 != 0 && $0 != appID }
        }

        // Config section
        if let config = appInfo["config"] as? [String: Any] {
            info.installDir = config["installdir"] as? String ?? ""
            if let launch = config["launch"] as? [String: Any] {
                info.launches = SteamLaunchOption.parse(launch)
            }
        }

        // Depots section
        if let depots = appInfo["depots"] as? [String: Any] {
            info.depots = parseDepots(depots, appID: appID)

            // Build ID
            if let branches = depots["branches"] as? [String: Any],
               let publicBranch = branches["public"] as? [String: Any] {
                if let buildIDStr = publicBranch["buildid"] as? String, let buildID = UInt32(buildIDStr) {
                    info.buildID = buildID
                } else if let buildID = publicBranch["buildid"] as? UInt32 {
                    info.buildID = buildID
                }
            }
            info.branches = parseBranches(depots["branches"])
        }


        // Auto-Cloud section. Untrusted text: bounded, and only ever used to
        // form paths below known folders (SteamCloud validates each one).
        if let ufs = appInfo["ufs"] as? [String: Any] {
            func text(_ value: Any?) -> String {
                guard let string = value as? String, string.utf8.count <= 512 else { return "" }
                return string
            }
            func entries(_ node: Any?) -> [[String: Any]] {
                guard let dict = node as? [String: Any] else { return [] }
                return dict.keys.compactMap { key in Int(key).map { ($0, key) } }.sorted { $0.0 < $1.0 }
                    .prefix(64).compactMap { dict[$0.1] as? [String: Any] }
            }
            for entry in entries(ufs["savefiles"]) {
                let platforms = (entry["platforms"] as? [String: Any])?.values.compactMap { ($0 as? String)?.lowercased() } ?? []
                info.saveFiles.append(SaveFile(root: text(entry["root"]), path: text(entry["path"]),
                                               pattern: text(entry["pattern"]),
                                               recursive: (entry["recursive"] as? String) == "1",
                                               platforms: platforms.sorted()))
            }
            for entry in entries(ufs["rootoverrides"]) {
                info.rootOverrides.append(RootOverride(root: text(entry["root"]), os: text(entry["os"]),
                                                       useInstead: text(entry["useinstead"]), addPath: text(entry["addpath"])))
            }
        }

        guard !info.name.isEmpty else { return nil }

        return info
    }

    /// The depot entries of a `depots` section: the app's own, or a private
    /// branch's (PICSPrivateBeta). Keys that are not depot IDs (`branches`,
    /// `baselanguages`) are skipped.
    static func parseDepots(_ depots: [String: Any], appID: UInt32) -> [DepotInfo] {
        var result: [DepotInfo] = []
        for (key, depotData) in depots {
            guard let depotID = UInt32(key),
                  let depot = depotData as? [String: Any] else { continue }

            var di = DepotInfo(depotID: depotID)
            di.name = depot["name"] as? String ?? ""
            if let config = depot["config"] as? [String: Any] {
                di.oslist = config["oslist"] as? String ?? ""
                di.osarch = config["osarch"] as? String ?? ""
                di.language = config["language"] as? String ?? ""
                di.lowViolence = (config["lowviolence"] as? String) == "1"
            }
            if let maxSizeStr = depot["maxsize"] as? String, let maxSize = UInt64(maxSizeStr) {
                di.maxSize = maxSize
            } else if let maxSize = depot["maxsize"] as? UInt32 {
                di.maxSize = UInt64(maxSize)
            }
            // Text VDF leaves every leaf as a String, so that is checked
            // first; the UInt32 branch serves any binary-VDF caller.
            if let dlcStr = depot["dlcappid"] as? String, let dlc = UInt32(dlcStr) {
                di.dlcAppID = dlc
            } else if let dlc = depot["dlcappid"] as? UInt32 {
                di.dlcAppID = dlc
            }
            di.isSharedInstall = (depot["sharedinstall"] as? String) == "1"
            if let from = (depot["depotfromapp"] as? String).flatMap(UInt32.init), from != appID {
                di.fromApp = from
            }
            if let manifests = depot["manifests"] as? [String: Any] {
                for (branch, entry) in manifests {
                    if let gidStr = entry as? String, let gid = UInt64(gidStr) {
                        // Legacy flat format: branch -> gid string.
                        di.manifests[branch] = gid
                    } else if let gid = entry as? UInt64 {
                        di.manifests[branch] = gid
                    } else if let dict = entry as? [String: Any] {
                        // Modern format (2023+): branch -> { gid, size, download }.
                        // Most apps carry their sizes here now.
                        if let gidStr = dict["gid"] as? String, let gid = UInt64(gidStr) {
                            di.manifests[branch] = gid
                        }
                        if branch == "public" {
                            if let dStr = dict["download"] as? String, let d = UInt64(dStr) {
                                di.publicDownloadBytes = d
                            }
                            if let sStr = dict["size"] as? String, let s = UInt64(sStr) {
                                di.publicSizeBytes = s
                            }
                        }
                    }
                }
            }
            result.append(di)
        }
        return result
    }

    /// Whether a branch name is one Madeira keeps and writes to an install
    /// record: 1-64 characters of letters, digits, `.`, `-` and `_`.
    static func validBranchName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64 &&
            name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)) }
    }

    /// `depots.branches`: public first, then the betas by name; at most 64,
    /// names Madeira cannot keep left out.
    static func parseBranches(_ node: Any?) -> [Branch] {
        guard let table = node as? [String: Any] else { return [] }
        func text(_ value: Any?, _ limit: Int) -> String {
            guard let string = value as? String else { return "" }
            return String(string.prefix(limit))
        }
        let names = table.keys.filter(validBranchName).sorted { a, b in
            a == publicBranch ? b != publicBranch : (b == publicBranch ? false : a < b)
        }
        return names.prefix(64).compactMap { name in
            guard let entry = table[name] as? [String: Any] else { return nil }
            return Branch(name: name, buildID: UInt32(text(entry["buildid"], 12)) ?? 0,
                          description: text(entry["description"], 200).trimmingCharacters(in: .whitespacesAndNewlines),
                          passwordRequired: text(entry["pwdrequired"], 4) == "1",
                          updated: Int(text(entry["timeupdated"], 12)) ?? 0)
        }
    }

    /// Adds a private branch's manifests (the depot section Steam returns for
    /// its beta code) to the app's depots: each depot it names gets the
    /// branch's manifest, and a depot only the branch has is added with its
    /// own entry. Returns how many depots got a manifest of the branch.
    mutating func addPrivateBranch(_ name: String, depots section: [String: Any]) -> Int {
        // Steam's binary KeyValues root may wrap the depots in one named section.
        var table = section
        if !table.keys.contains(where: { UInt32($0) != nil }), table.count == 1,
           let inner = table.values.first as? [String: Any] { table = inner }
        var added = 0
        for depot in Self.parseDepots(table, appID: appID).prefix(512) {
            guard let gid = depot.manifests[name] else { continue }
            if let index = depots.firstIndex(where: { $0.depotID == depot.depotID }) {
                depots[index].manifests[name] = gid
            } else {
                depots.append(depot)
            }
            added += 1
        }
        if let branches = table["branches"] {
            for entry in Self.parseBranches(branches) where !self.branches.contains(where: { $0.name == entry.name }) {
                self.branches.append(entry)
            }
        }
        return added
    }
}

/// One entry of an app's launch configuration (`config.launch.<n>` in its
/// product info): the program Valve's client would start, relative to the
/// install folder as Steam spells it, its arguments and working folder, the
/// entry's type and the platform, architecture and beta branch it is for.
/// Untrusted text: bounded here, and validated as a path by SteamDirectStart.
struct SteamLaunchOption: Codable, Hashable, Sendable {
    var executable: String
    /// The config.launch key, not the position in the filtered array. Nil in old caches.
    var index: UInt32? = nil
    var requiredDLC: String? = nil
    var arguments = ""
    var workingDir = ""
    /// "default", "none", "option1", "server", "editor", "vr", ... ("" when absent).
    var type = ""
    var oslist = ""
    var osarch = ""
    var betaKey = ""

    /// Entries in Steam's order (numeric keys), without those that name no
    /// program or carry oversized text; at most 32.
    static func parse(_ launch: [String: Any]) -> [SteamLaunchOption] {
        let keys: [(UInt32, String)] = launch.keys.compactMap { key in
            guard let index = UInt32(key), index <= UInt32(Int32.max) else { return nil }
            return (index, key)
        }.sorted { $0.0 < $1.0 }
        var options: [SteamLaunchOption] = []
        for (index, key) in keys.prefix(32) {
            guard let entry = launch[key] as? [String: Any], let executable = entry["executable"] as? String,
                  !executable.isEmpty, executable.utf8.count <= 512 else { continue }
            func text(_ value: Any?, limit: Int = 256) -> String? {
                guard let value else { return "" }
                guard let string = value as? String, string.utf8.count <= limit else { return nil }
                return string
            }
            let config = entry["config"] as? [String: Any] ?? [:]
            guard let arguments = text(entry["arguments"], limit: 2048), let workingDir = text(entry["workingdir"], limit: 512),
                  let type = text(entry["type"]), let oslist = text(config["oslist"]), let osarch = text(config["osarch"]),
                  let betaKey = text(config["betakey"]), let requiredDLC = text(config["ownsdlc"]) else { continue }
            options.append(SteamLaunchOption(executable: executable, index: index, requiredDLC: requiredDLC,
                                             arguments: arguments, workingDir: workingDir,
                                             type: type, oslist: oslist, osarch: osarch, betaKey: betaKey))
        }
        return options
    }
}

// MARK: - Download language

/// The language Steam downloads install: which language-pack depots are taken
/// and the language the install record names (Valve's client reports it to
/// the game). Settings › Steam › Game language, kept in madeira.cfg as
/// `env.MADEIRA_STEAM_LANGUAGE` (a Steam API language name); unset follows
/// the device's language. A game without the language falls back to English.
enum SteamLanguage {
    static let configKey = "env.MADEIRA_STEAM_LANGUAGE"

    /// Steam API language names with their names in that language, in the
    /// order Steam's own client lists them.
    static let all: [(code: String, name: String)] = [
        ("arabic", "العربية"), ("bulgarian", "Български"), ("schinese", "简体中文"),
        ("tchinese", "繁體中文"), ("czech", "Čeština"), ("danish", "Dansk"),
        ("dutch", "Nederlands"), ("english", "English"), ("finnish", "Suomi"),
        ("french", "Français"), ("german", "Deutsch"), ("greek", "Ελληνικά"),
        ("hungarian", "Magyar"), ("indonesian", "Bahasa Indonesia"), ("italian", "Italiano"),
        ("japanese", "日本語"), ("koreana", "한국어"), ("norwegian", "Norsk"),
        ("polish", "Polski"), ("portuguese", "Português"), ("brazilian", "Português (Brasil)"),
        ("romanian", "Română"), ("russian", "Русский"), ("spanish", "Español (España)"),
        ("latam", "Español (Latinoamérica)"), ("swedish", "Svenska"), ("thai", "ไทย"),
        ("turkish", "Türkçe"), ("ukrainian", "Українська"), ("vietnamese", "Tiếng Việt"),
    ]

    static func name(_ code: String) -> String {
        all.first { $0.code == code }?.name ?? code.capitalized
    }

    /// The chosen language, or nil when it follows the device.
    static var chosen: String? {
        guard let value = MadeiraConfig.get(configKey)?.lowercased(), all.contains(where: { $0.code == value }) else { return nil }
        return value
    }

    static func choose(_ code: String?) {
        MadeiraConfig.set(configKey, code)
        SteamLog.event("[steam-language] setting=\(code ?? "device") download=\(download)")
    }

    /// The language downloads use now.
    static var download: String { chosen ?? device }

    /// The language one game's downloads use: its own choice on its page, else
    /// the setting's.
    static func download(for appID: UInt32) -> String { gameChoice(appID) ?? download }

    /// Per-game choices (Game language on the game's page), by App ID, kept in
    /// the app's defaults; a game without one follows the setting.
    private static let gameChoicesKey = "steam-game-languages"

    static func gameChoice(_ appID: UInt32) -> String? {
        let value = (UserDefaults.standard.dictionary(forKey: gameChoicesKey) as? [String: String])?[String(appID)]
        return value.flatMap { code in all.contains { $0.code == code } ? code : nil }
    }

    static func chooseForGame(_ appID: UInt32, _ code: String?) {
        var choices = UserDefaults.standard.dictionary(forKey: gameChoicesKey) as? [String: String] ?? [:]
        choices[String(appID)] = code
        UserDefaults.standard.set(choices, forKey: gameChoicesKey)
        SteamLog.event("[steam-language] app=\(appID) choice=\(code ?? "setting") download=\(download(for: appID))")
    }

    /// The device's preferred language as a Steam API name, English when Steam
    /// has none for it.
    static var device: String {
        for identifier in Locale.preferredLanguages {
            if let code = steamName(Locale(identifier: identifier)) { return code }
        }
        return "english"
    }

    static func steamName(_ locale: Locale) -> String? {
        guard let language = locale.language.languageCode?.identifier else { return nil }
        let region = locale.region?.identifier
        switch language {
        case "zh":
            let script = locale.language.script?.identifier
            if script == "Hant" || (script == nil && ["TW", "HK", "MO"].contains(region ?? "")) { return "tchinese" }
            return "schinese"
        case "pt": return region == "BR" ? "brazilian" : "portuguese"
        case "es": return region == nil || region == "ES" ? "spanish" : "latam"
        case "ko": return "koreana"
        case "nb", "nn", "no": return "norwegian"
        default:
            let names = ["ar": "arabic", "bg": "bulgarian", "cs": "czech", "da": "danish", "nl": "dutch",
                         "en": "english", "fi": "finnish", "fr": "french", "de": "german", "el": "greek",
                         "hu": "hungarian", "id": "indonesian", "it": "italian", "ja": "japanese",
                         "pl": "polish", "ro": "romanian", "ru": "russian", "sv": "swedish", "th": "thai",
                         "tr": "turkish", "uk": "ukrainian", "vi": "vietnamese"]
            return names[language]
        }
    }
}

// MARK: - DLC choice

/// Which owned DLC a Steam download takes along. Like Valve's client, every
/// owned DLC is on unless the player turned it off on the game's page; the
/// turned-off DLC are kept per game in the app's defaults (`steam-dlc-off`).
/// Steam still decides ownership: it gives a depot key only for owned content.
enum SteamDLC {
    private static let offKey = "steam-dlc-off"

    /// The DLC the player turned off for a game.
    static func off(_ appID: Int) -> Set<Int> {
        let value = (UserDefaults.standard.dictionary(forKey: offKey) as? [String: [Int]])?[String(appID)] ?? []
        return Set(value.prefix(1024))
    }

    static func setOn(_ dlcID: Int, _ on: Bool, for appID: Int) {
        var all = UserDefaults.standard.dictionary(forKey: offKey) as? [String: [Int]] ?? [:]
        var set = Set(all[String(appID)] ?? [])
        if on { set.remove(dlcID) } else { set.insert(dlcID) }
        all[String(appID)] = set.isEmpty ? nil : set.sorted()
        UserDefaults.standard.set(all, forKey: offKey)
        SteamLog.event("[steam-dlc] app=\(appID) dlc=\(dlcID) on=\(on ? 1 : 0)")
    }

    /// The turned-off DLC as App IDs for SteamAppInfo.dlcOff.
    static func offApps(_ appID: Int) -> Set<UInt32> {
        Set(off(appID).filter { $0 > 0 && $0 <= Int(UInt32.max) }.map { UInt32($0) })
    }
}

// MARK: - Branch choice

/// Which Steam branch ("version") a game's downloads take: "public" unless the
/// player picked a beta on the game's page (Game details › Steam › Version).
/// Kept per game in the app's defaults (`steam-branches`), with the beta code
/// the player typed for a password-protected branch (`steam-beta-codes`) and
/// the private branches that code opened. A beta code opens a game's test
/// builds, not the account; Steam still decides ownership and checks the code
/// again on every download.
enum SteamBranch {
    private static let chosenKey = "steam-branches"
    private static let codesKey = "steam-beta-codes"
    private static let unlockedKey = "steam-beta-unlocked"

    /// The branch the game's downloads take.
    static func chosen(_ appID: Int) -> String {
        let value = (UserDefaults.standard.dictionary(forKey: chosenKey) as? [String: String])?[String(appID)]
        return value.flatMap { SteamAppInfo.validBranchName($0) ? $0 : nil } ?? SteamAppInfo.publicBranch
    }

    static func choose(_ branch: String, for appID: Int) {
        guard SteamAppInfo.validBranchName(branch) else { return }
        var all = UserDefaults.standard.dictionary(forKey: chosenKey) as? [String: String] ?? [:]
        all[String(appID)] = branch == SteamAppInfo.publicBranch ? nil : branch
        UserDefaults.standard.set(all, forKey: chosenKey)
        SteamLog.event("[steam-branch] app=\(appID) choice=\(branch)")
    }

    /// The beta code kept for the game, nil without one.
    static func code(_ appID: Int) -> String? {
        let value = (UserDefaults.standard.dictionary(forKey: codesKey) as? [String: String])?[String(appID)]
        return value.flatMap { $0.isEmpty || $0.utf8.count > 256 ? nil : $0 }
    }

    /// The private branches the kept code opened (CheckAppBetaPassword), by name.
    static func unlocked(_ appID: Int) -> [String] {
        let value = (UserDefaults.standard.dictionary(forKey: unlockedKey) as? [String: [String]])?[String(appID)] ?? []
        return value.filter(SteamAppInfo.validBranchName).prefix(64).map { $0 }
    }

    /// Keeps a code that opened `branches`, or with nil forgets the code (a
    /// chosen private branch goes back to public).
    static func setCode(_ code: String?, branches: [String], for appID: Int) {
        var codes = UserDefaults.standard.dictionary(forKey: codesKey) as? [String: String] ?? [:]
        var unlocked = UserDefaults.standard.dictionary(forKey: unlockedKey) as? [String: [String]] ?? [:]
        let previous = Self.unlocked(appID)
        let kept = branches.filter(SteamAppInfo.validBranchName).prefix(64).map { $0 }
        codes[String(appID)] = code == nil || kept.isEmpty ? nil : code
        unlocked[String(appID)] = code == nil || kept.isEmpty ? nil : kept
        UserDefaults.standard.set(codes, forKey: codesKey)
        UserDefaults.standard.set(unlocked, forKey: unlockedKey)
        if code == nil, previous.contains(chosen(appID)) { choose(SteamAppInfo.publicBranch, for: appID) }
        SteamLog.event("[steam-branch] app=\(appID) code=\(code == nil ? "removed" : "kept") private=\(kept.count)")
    }
}
