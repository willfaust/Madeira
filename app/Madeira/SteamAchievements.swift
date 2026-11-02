// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Steam achievements: a list per game (Game details › Achievements) and a
//  banner the moment one unlocks while you play. GameNative made this its
//  headline; Steam's own overlay never runs in Madeira, so an unlock went by
//  unseen.
//
//  Games started through Madeira Dock talk to Valve's real Steam client, which
//  records the unlock on the account and keeps a copy in its appcache:
//    Steam/appcache/stats/UserGameStatsSchema_<app>.bin   names, descriptions,
//                                                          icons (per language)
//    Steam/appcache/stats/UserGameStats_<account>_<app>.bin  unlock bits and times
//  Both are binary KeyValues. Madeira reads them (no network, no sign-in of its
//  own) and, while it runs, looks at the folder every few seconds: a stats file
//  that changed with a newly set bit is an unlock, shown as a banner over the
//  game. Achievement watchers on Windows (xan105's Achievement Watcher) read the
//  same files.
//
//  Everything above "MARK: Views" is Foundation only:
//  tests/host/check-steam-achievements.py compiles it with a test harness.
//

import Foundation
import SwiftUI
import UIKit

/// Binary KeyValues (Valve's appcache format), read into SteamBinaryValue.
indirect enum SteamBinaryValue: Equatable {
    case object([(String, SteamBinaryValue)])
    case string(String)
    case int(Int64)
    case float(Double)

    static func == (a: SteamBinaryValue, b: SteamBinaryValue) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.string(x), .string(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.float(x), .float(y)): return x == y
        default: return false
        }
    }

    subscript(_ key: String) -> SteamBinaryValue? {
        guard case let .object(items) = self else { return nil }
        return items.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
    }
    var children: [(String, SteamBinaryValue)] {
        if case let .object(items) = self { return items }
        return []
    }
    var string: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .float(let f): return String(f)
        case .object: return nil
        }
    }
    var int: Int64? {
        switch self {
        case .int(let i): return i
        case .string(let s): return Int64(s.trimmingCharacters(in: .whitespaces))
        case .float(let f): return Int64(f)
        case .object: return nil
        }
    }

    enum ReadError: Error { case truncated, badType(UInt8), tooDeep }

    /// Reads a whole file: one or more top-level entries, as one object.
    static func read(_ data: Data) throws -> SteamBinaryValue {
        let bytes = [UInt8](data)
        var at = 0
        var items: [(String, SteamBinaryValue)] = []
        while at < bytes.count, bytes[at] != 0x08, bytes[at] != 0x0B {
            guard let item = try entry(bytes, &at, depth: 0) else { break }
            items.append(item)
        }
        return .object(items)
    }

    private static func cString(_ b: [UInt8], _ at: inout Int) throws -> String {
        guard let end = b[at...].firstIndex(of: 0) else { throw ReadError.truncated }
        let s = String(decoding: b[at..<end], as: UTF8.self)
        at = end + 1
        return s
    }
    private static func number(_ b: [UInt8], _ at: inout Int, _ size: Int) throws -> UInt64 {
        guard at + size <= b.count else { throw ReadError.truncated }
        var v: UInt64 = 0
        for i in 0..<size { v |= UInt64(b[at + i]) << (8 * UInt64(i)) }
        at += size
        return v
    }

    /// One "type name value" entry, nil at an end marker.
    private static func entry(_ b: [UInt8], _ at: inout Int, depth: Int) throws -> (String, SteamBinaryValue)? {
        guard depth < 64 else { throw ReadError.tooDeep }
        guard at < b.count else { throw ReadError.truncated }
        let type = b[at]; at += 1
        if type == 0x08 || type == 0x0B { return nil }
        let name = try cString(b, &at)
        switch type {
        case 0x00:
            var items: [(String, SteamBinaryValue)] = []
            while let item = try entry(b, &at, depth: depth + 1) { items.append(item) }
            return (name, .object(items))
        case 0x01: return (name, .string(try cString(b, &at)))
        case 0x02: return (name, .int(Int64(Int32(bitPattern: UInt32(try number(b, &at, 4))))))
        case 0x03: return (name, .float(Double(Float(bitPattern: UInt32(try number(b, &at, 4))))))
        case 0x04, 0x06: return (name, .int(Int64(try number(b, &at, 4))))
        case 0x05:
            // UTF-16, two zero bytes at the end.
            var units: [UInt16] = []
            while true {
                let u = UInt16(try number(b, &at, 2))
                if u == 0 { break }
                units.append(u)
            }
            return (name, .string(String(decoding: units, as: UTF16.self)))
        case 0x07: return (name, .int(Int64(bitPattern: try number(b, &at, 8))))
        case 0x0A: return (name, .int(Int64(bitPattern: try number(b, &at, 8))))
        default: throw ReadError.badType(type)
        }
    }
}

/// One achievement of a game, with its state on the account.
struct SteamAchievement: Equatable, Identifiable {
    /// "<stat id>/<bit>": where the unlock is kept.
    let id: String
    let apiName: String
    let name: String
    let detail: String
    let hidden: Bool
    /// File names on Steam's CDN ("<hash>.jpg").
    let icon: String?
    let iconGray: String?
    var unlocked: Date?

    func iconURL(appID: Int) -> URL? {
        guard let file = (unlocked != nil ? icon : iconGray) ?? icon, !file.isEmpty,
              file.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) else { return nil }
        return URL(string: "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/\(appID)/\(file)")
    }
}

enum SteamAchievements {
    /// A localized text from the schema: a language table ("english", "german", ...,
    /// "token") or a plain string.
    static func text(_ value: SteamBinaryValue?, language: String) -> String {
        guard let value else { return "" }
        if let s = value.string { return s }
        return value[language]?.string ?? value["english"]?.string
            ?? value.children.first { $0.0.lowercased() != "token" }?.1.string ?? ""
    }

    /// The schema's achievements, in its order, all locked.
    static func schema(_ root: SteamBinaryValue, language: String) -> (game: String, achievements: [SteamAchievement]) {
        let app = root.children.first?.1 ?? root
        var out: [SteamAchievement] = []
        for (statID, stat) in app["stats"]?.children ?? [] {
            guard let bits = stat["bits"] else { continue }
            for (bitKey, bit) in bits.children {
                let index = bit["bit"]?.int ?? Int64(bitKey) ?? 0
                let display = bit["display"]
                let hidden = display?["hidden"]?.int ?? 0
                out.append(SteamAchievement(
                    id: "\(statID)/\(index)", apiName: bit["name"]?.string ?? "\(statID)/\(index)",
                    name: text(display?["name"], language: language), detail: text(display?["desc"], language: language),
                    hidden: hidden != 0, icon: display?["icon"]?.string, iconGray: display?["icon_gray"]?.string,
                    unlocked: nil))
            }
        }
        return (app["gamename"]?.string ?? "", out)
    }

    /// Which "<stat id>/<bit>" are unlocked, and when (a time of 0: unlocked, time unknown).
    static func unlocks(_ root: SteamBinaryValue) -> [String: Date] {
        let cache = root["cache"] ?? root.children.first?.1 ?? root
        var out: [String: Date] = [:]
        for (statID, stat) in cache.children {
            guard case .object = stat, let data = stat["data"]?.int else { continue }
            let bits = UInt32(truncatingIfNeeded: data)
            let times = stat["AchievementTimes"]
            for bit in 0..<32 where bits & (1 << UInt32(bit)) != 0 {
                let time = times?["\(bit)"]?.int ?? 0
                out["\(statID)/\(bit)"] = Date(timeIntervalSince1970: TimeInterval(max(0, time)))
            }
        }
        return out
    }

    /// The schema's achievements with the account's unlocks filled in.
    static func merge(_ achievements: [SteamAchievement], _ unlocks: [String: Date]) -> [SteamAchievement] {
        achievements.map { var a = $0; a.unlocked = unlocks[a.id]; return a }
    }

    /// Unlocked in `now` and not in `before`.
    static func newlyUnlocked(before: [String: Date], now: [String: Date]) -> [String] {
        now.keys.filter { before[$0] == nil }.sorted()
    }

    /// "UserGameStats_<account>_<app>.bin" -> (account, app).
    static func statsFile(_ name: String) -> (account: UInt32, app: Int)? {
        guard name.hasPrefix("UserGameStats_"), name.hasSuffix(".bin") else { return nil }
        let parts = name.dropFirst("UserGameStats_".count).dropLast(4).split(separator: "_")
        guard parts.count == 2, let account = UInt32(parts[0]), let app = Int(parts[1]) else { return nil }
        return (account, app)
    }
}

// MARK: Views

extension SteamAchievements {
    static var folder: URL {
        LibraryModel.drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot, isDirectory: true)
            .appendingPathComponent("appcache/stats", isDirectory: true)
    }

    /// The game's achievements as Steam's client last saved them on this device,
    /// nil when it has no schema for the game yet.
    static func load(appID: Int) -> (game: String, achievements: [SteamAchievement])? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("UserGameStatsSchema_\(appID).bin")),
              let root = try? SteamBinaryValue.read(data) else { return nil }
        let schema = schema(root, language: SteamLanguage.download)
        guard !schema.achievements.isEmpty else { return nil }
        return (schema.game, merge(schema.achievements, unlocks(appID: appID)))
    }

    /// The unlocks of the account that played the game last on this device.
    static func unlocks(appID: Int) -> [String: Date] {
        guard let url = statsURL(appID: appID), let data = try? Data(contentsOf: url),
              let root = try? SteamBinaryValue.read(data) else { return [:] }
        return unlocks(root)
    }

    static func statsURL(appID: Int) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { statsFile($0)?.app == appID }
            .map { folder.appendingPathComponent($0) }
            .max { modified($0) < modified($1) }
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}

/// Looks at Steam's stats folder every few seconds and shows a banner for each
/// achievement that unlocks.
final class AchievementWatcher {
    static let shared = AchievementWatcher()
    private var timer: Timer?
    private var seen: [String: Date] = [:]          // file name -> modified
    private var known: [String: [String: Date]] = [:]  // file name -> unlocks
    private let queue = DispatchQueue(label: "madeira.achievements", qos: .utility)
    private var startedAt = Date()
    private var firstScanDone = false
    private var wasRunning = false

    func start() {
        guard timer == nil else { return }
        startedAt = Date()
        queue.async { self.scan(announce: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Only while a game runs and Madeira is on screen, plus one scan after the game
            // stops (Steam writes the stats file on exit). Unlocks made in the background are
            // announced on return.
            guard MainActor.assumeIsolated({ UIApplication.shared.applicationState == .active }) else { return }
            let running = wine_process_is_running() != 0
            defer { self.wasRunning = running }
            guard running || self.wasRunning else { return }
            self.queue.async { self.scan(announce: true) }
        }
    }

    private func scan(announce: Bool) {
        let folder = SteamAchievements.folder
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            guard let file = SteamAchievements.statsFile(name) else { continue }
            let url = folder.appendingPathComponent(name)
            let modified = SteamAchievements.modified(url)
            guard seen[name] != modified else { continue }
            // A file read while Steam writes it fails to parse: it is read again next time.
            guard let data = try? Data(contentsOf: url), let root = try? SteamBinaryValue.read(data) else { continue }
            seen[name] = modified
            let now = SteamAchievements.unlocks(root)
            let before = known[name]
            known[name] = now
            // A stats file Steam made during this run (a game's first start) counts
            // only unlocks dated after Madeira started, not the account's older ones.
            guard announce, firstScanDone else { continue }
            let fresh = SteamAchievements.newlyUnlocked(before: before ?? [:], now: now)
                .filter { before != nil || (now[$0] ?? .distantPast) > startedAt }
            guard !fresh.isEmpty, let game = SteamAchievements.load(appID: file.app) else { continue }
            for id in fresh {
                guard let achievement = game.achievements.first(where: { $0.id == id }) else { continue }
                LogStore.shared.log("[achievements] \(file.app) unlocked \(achievement.apiName)")
                DispatchQueue.main.async { MainActor.assumeIsolated { AchievementBanner.show(achievement, appID: file.app) } }
            }
        }
        firstScanDone = true
    }
}

/// The unlock banner: its own window over the game, gone after a few seconds.
@MainActor enum AchievementBanner {
    private static var window: UIWindow?
    private static var waiting: [(SteamAchievement, Int)] = []

    static func show(_ achievement: SteamAchievement, appID: Int) {
        waiting.append((achievement, appID))
        if window == nil { next() }
    }

    private static func next() {
        guard !waiting.isEmpty else { window?.isHidden = true; window = nil; return }
        let (achievement, appID) = waiting.removeFirst()
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let host = UIHostingController(rootView: AchievementBannerView(achievement: achievement, appID: appID))
        host.view.backgroundColor = .clear
        let banner = PassthroughWindow(windowScene: scene)
        banner.frame = scene.coordinateSpace.bounds
        banner.windowLevel = .alert + 1
        banner.backgroundColor = .clear
        banner.rootViewController = host
        banner.isHidden = false
        window = banner
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { MainActor.assumeIsolated { next() } }
    }

    /// Touches go through to the game except on the banner itself.
    private final class PassthroughWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === rootViewController?.view ? nil : hit
        }
    }
}

private struct AchievementBannerView: View {
    let achievement: SteamAchievement
    let appID: Int
    @State private var shown = false

    var body: some View {
        VStack {
            HStack(spacing: 12) {
                AchievementIcon(achievement: achievement, appID: appID).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Achievement unlocked").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: achievement.name).font(.headline).lineLimit(1)
                    if !achievement.detail.isEmpty {
                        Text(verbatim: achievement.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(radius: 8)
            .offset(y: shown ? 0 : -140)
            .padding(.top, 8).padding(.horizontal, 16)
            Spacer()
        }
        .onAppear {
            withAnimation(.spring(duration: 0.4)) { shown = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) { withAnimation(.easeIn(duration: 0.3)) { shown = false } }
        }
    }
}

private struct AchievementIcon: View {
    let achievement: SteamAchievement
    let appID: Int
    var body: some View {
        AsyncImage(url: achievement.iconURL(appID: appID)) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: achievement.unlocked != nil ? "trophy.fill" : "trophy")
                .font(.title2).foregroundStyle(achievement.unlocked != nil ? .yellow : .secondary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .saturation(achievement.unlocked != nil ? 1 : 0)
    }
}

/// Game details › Achievements.
struct SteamAchievementsSection: View {
    let appID: Int
    /// Read once when the page opens: two small files in Steam's appcache.
    @State private var game: (game: String, achievements: [SteamAchievement])?

    init(appID: Int) {
        self.appID = appID
        _game = State(initialValue: SteamAchievements.load(appID: appID))
    }

    var body: some View {
        if let game {
            let unlocked = game.achievements.filter { $0.unlocked != nil }
            Section {
                ProgressView(value: Double(unlocked.count), total: Double(max(game.achievements.count, 1))) {
                    Text("\(unlocked.count) of \(game.achievements.count) unlocked")
                }
            }
            Section {
                ForEach(unlocked.sorted { ($0.unlocked ?? .distantPast) > ($1.unlocked ?? .distantPast) } +
                        game.achievements.filter { $0.unlocked == nil }) { a in
                    HStack(spacing: 12) {
                        AchievementIcon(achievement: a, appID: appID).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            if a.unlocked == nil && a.hidden {
                                Text("Hidden achievement")
                                Text("Keep playing to reveal it.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(verbatim: a.name)
                                if !a.detail.isEmpty { Text(verbatim: a.detail).font(.caption).foregroundStyle(.secondary) }
                            }
                            if let when = a.unlocked, when.timeIntervalSince1970 > 0 {
                                Text(when, format: .dateTime.day().month().year().hour().minute())
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .opacity(a.unlocked == nil ? 0.6 : 1)
                }
            } footer: {
                Text("As Steam saved them on this device the last time the game ran through Madeira Dock. A banner shows each new one while you play.")
            }
        } else {
            Section {
                Text("No achievements on this device yet.")
            } footer: {
                Text("Play the game once through Madeira Dock: Steam then keeps its achievements here, and a banner shows each one you unlock.")
            }
        }
    }
}
