import Foundation
import SwiftUI

/// The friends list and Invite/Join for a running Madeira Dock session (the
/// in-game menu's Friends page). Dock writes the list to C:\madeira-friends.bin
/// and reads one command at a time from C:\madeira-friends-cmd.bin; both
/// formats are in the madeira-dock README, "Friends". SteamIDs and names stay
/// on the device: logs carry counts and result codes only.
@MainActor final class DockFriends: ObservableObject {
    static let shared = DockFriends()

    enum Action: UInt8 { case invite = 1, join = 2, setStatus = 3 }

    struct Friend: Equatable {
        let steamID: UInt64
        let name: String
        /// Feed flags: 1 in game, 2 this game, 4 joinable, 8 invited this player, 16 you have a lobby or connect string (Invite is offered).
        let dockFlags: UInt8
        /// Steam persona state (0 offline, 1 online, 2 busy, 3 away, ...).
        var state: UInt32 = 0
        var appID: UInt32 = 0
    }

    struct Pending: Equatable {
        let action: Action
        let steamID: UInt64
        let sequence: UInt32
    }

    /// The feed's limits (madeira-dock src/friends_format.h).
    nonisolated static let feedMax = 250
    nonisolated static let nameCap = 64
    nonisolated static let feedCap = 12 + feedMax * (18 + nameCap)
    /// Dock rewrites the feed every 3 s while the game runs. An older feed is
    /// one a host left behind when it did not end cleanly (a killed Wine
    /// process), so it is not shown.
    nonisolated static let feedMaxAge: TimeInterval = 15
    /// A command Dock has not answered in this time ends as "No answer from Steam".
    nonisolated static let commandTimeout: TimeInterval = 10
    /// The most of the report read for a command's answer: only what Dock wrote
    /// after the command was sent.
    nonisolated static let resultReadCap = 1 << 16

    /// C:\madeira-friends.bin: magic MFRND001, count, then per friend
    /// SteamID(8) state(4) App ID(4) flags(1) name length(1) name.
    nonisolated static func parseFeed(_ data: Data) -> [Friend]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes.count <= feedCap,
              Array(bytes[0..<8]) == Array("MFRND001".utf8) else { return nil }
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * $1) } }
        func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[at + $1]) << (8 * $1) } }
        let count = Int(u32(8))
        guard count <= feedMax else { return nil }
        var at = 12, result: [Friend] = []
        for _ in 0..<count {
            guard at + 18 <= bytes.count else { return nil }
            let length = Int(bytes[at + 17])
            guard length < nameCap, at + 18 + length <= bytes.count,
                  let name = String(bytes: bytes[(at + 18)..<(at + 18 + length)], encoding: .utf8) else { return nil }
            result.append(Friend(steamID: u64(at), name: name, dockFlags: bytes[at + 16], state: u32(at + 8), appID: u32(at + 12)))
            at += 18 + length
        }
        return at == bytes.count ? result : nil
    }

    /// The feed at `url` in display order, or nil when it is missing, older
    /// than feedMaxAge, larger than the format allows or invalid.
    nonisolated static func readFeed(at url: URL, now: Date) -> [Friend]? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(modified) <= feedMaxAge,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: feedCap + 1), data.count <= feedCap,
              let friends = parseFeed(data) else { return nil }
        return ordered(friends)
    }

    /// Invites first, then joinable friends in this game, this game, other games, online, offline; by name within each.
    nonisolated static func ordered(_ friends: [Friend]) -> [Friend] {
        func rank(_ f: Friend) -> Int {
            if f.dockFlags & 8 != 0 { return 0 }
            if f.dockFlags & 4 != 0 { return 1 }
            if f.dockFlags & 2 != 0 { return 2 }
            if f.dockFlags & 1 != 0 { return 3 }
            return f.state > 0 ? 4 : 5
        }
        return friends.sorted { rank($0) != rank($1) ? rank($0) < rank($1)
            : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// C:\madeira-friends-cmd.bin: magic MFCMD001, action(1), SteamID or status(8), sequence(4).
    nonisolated static func command(_ action: Action, id: UInt64, sequence: UInt32) -> Data {
        var bytes = [UInt8]("MFCMD001".utf8)
        bytes.append(action.rawValue)
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: id >> (8 * UInt64(i)))) }
        for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: sequence >> (8 * UInt32(i)))) }
        return Data(bytes)
    }

    /// Sequences stay in 1...2^31-1: Dock reports friends-cmd-seq as a signed
    /// 32-bit number, so a larger one would never match.
    nonisolated static func nextSequence(after sequence: UInt32) -> UInt32 {
        let next = (sequence &+ 1) & 0x7fff_ffff
        return next == 0 ? 1 : next
    }

    /// The friends-cmd-result Dock reported after friends-cmd-seq=`sequence`
    /// in `data` (report lines, CRLF), or nil. A partial final line is ignored
    /// until Dock finishes it.
    nonisolated static func commandResult(in data: Data, sequence: UInt32) -> Int? {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(whereSeparator: \.isNewline)
        if let last = text.last, !last.isNewline, !lines.isEmpty { lines.removeLast() }
        func value(_ line: Substring, _ key: String) -> Int? {
            guard let range = line.range(of: " " + key + "=") else { return nil }
            return Int(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
        }
        var seen = false
        for line in lines {
            if let seq = value(line, "friends-cmd-seq") { seen = seq == Int(sequence) }
            else if seen, let result = value(line, "friends-cmd-result") { return result }
        }
        return nil
    }

    @Published private(set) var friends: [DockFriends.Friend] = []
    /// Dock is running with friends available (a current, valid feed).
    @Published private(set) var available = false
    @Published private(set) var pending: Pending?
    /// The last finished command, for the row that sent it.
    @Published private(set) var outcome: (steamID: UInt64, action: Action, result: Int)?

    private var sequence = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)) & 0x7fff_ffff
    private var sentAt = Date.distantPast
    /// The report's size when the pending command was sent: its answer comes after.
    private var reportOffset: UInt64 = 0
    private var lastSequence: UInt32 = 0

    private var feedURL: URL { MadeiraDock.drive.appendingPathComponent("madeira-friends.bin") }
    private var commandURL: URL { MadeiraDock.drive.appendingPathComponent("madeira-friends-cmd.bin") }
    private var reportURL: URL { MadeiraDock.drive.appendingPathComponent("madeira-dock.txt") }

    /// Re-reads the feed and the pending command's result. A missing, stale or
    /// invalid feed empties the list and makes friends unavailable.
    func refresh(now: Date = Date()) {
        let feed = DockFriends.readFeed(at: feedURL, now: now)
        let list = feed ?? []
        if available != (feed != nil) { available = feed != nil }
        if friends != list { friends = list }
        if let pending { checkResult(pending, now: now) }
    }

    /// Changes the status in a running session. Offline is not offered: it is
    /// chosen before launch and turns friends off for the session.
    func setStatus(_ status: SteamOnlineStatus, now: Date = Date()) {
        guard status != .offline else { return }
        if send(.setStatus, id: UInt64(status.rawValue), now: now) { SteamOnlineStatus.current = status }
    }

    func send(_ action: Action, to friend: DockFriends.Friend, now: Date = Date()) { send(action, id: friend.steamID, now: now) }

    @discardableResult
    private func send(_ action: Action, id: UInt64, now: Date) -> Bool {
        guard pending == nil, available else { return false }
        sequence = DockFriends.nextSequence(after: sequence)
        let offset = (try? FileManager.default.attributesOfItem(atPath: reportURL.path))?[.size] as? UInt64 ?? 0
        do {
            try DockFriends.command(action, id: id, sequence: sequence).write(to: commandURL, options: .atomic)
        } catch {
            SteamLog.event("[dock-friends] command not written")
            outcome = (id, action, 6)
            return false
        }
        pending = Pending(action: action, steamID: id, sequence: sequence)
        sentAt = now
        reportOffset = offset
        outcome = nil
        SteamLog.event("[dock-friends] \(action) sent")
        return true
    }

    /// Dock answers with friends-cmd-seq (this command's sequence), then
    /// friends-cmd-result; without an answer in commandTimeout the command lapses.
    private func checkResult(_ pending: Pending, now: Date) {
        if let file = try? FileHandle(forReadingFrom: reportURL) {
            defer { try? file.close() }
            // A shorter report is a new one (a new session): read it from the start.
            if let end = try? file.seekToEnd(), end < reportOffset { reportOffset = 0 }
            if (try? file.seek(toOffset: reportOffset)) != nil,
               let data = try? file.read(upToCount: DockFriends.resultReadCap),
               let result = DockFriends.commandResult(in: data, sequence: pending.sequence) {
                finish(pending, result: result)
                return
            }
        }
        if now.timeIntervalSince(sentAt) > DockFriends.commandTimeout { finish(pending, result: 0) }
    }

    private func finish(_ pending: Pending, result: Int) {
        self.pending = nil
        outcome = (pending.steamID, pending.action, result)
        SteamLog.event("[dock-friends] \(pending.action) result=\(result)")
        // The row shows the result for a few seconds, then its status again.
        let sequence = pending.sequence
        lastSequence = sequence
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if self.pending == nil, self.lastSequence == sequence { self.outcome = nil }
        }
    }

    /// Clears the state (a new Dock session starts, or one ended).
    func reset() {
        if !friends.isEmpty { friends = [] }
        if available { available = false }
        pending = nil
        outcome = nil
        sentAt = .distantPast
        reportOffset = 0
    }

    /// A Dock session ended (or the app starts, or Steam signed out): removes
    /// the feed and any unread command, so no later session, Dock or not,
    /// shows an old list or answers an old command.
    func endSession() {
        for name in ["madeira-friends.bin", "madeira-friends.tmp", "madeira-friends-cmd.bin", "madeira-friends-cmd.taken"] {
            try? FileManager.default.removeItem(at: MadeiraDock.drive.appendingPathComponent(name))
        }
        reset()
    }

    nonisolated static func message(action: Action, result: Int) -> String {
        switch result {
        // Join hands the lobby to the game; whether the game gets in is up to it.
        case 1: return action == .invite ? L("Invite sent") : action == .setStatus ? L("Status changed") : L("Sent to the game")
        case 2: return action == .invite ? L("Nothing to invite to yet: join or create a lobby") : L("Not in a joinable lobby")
        case 3: return L("Not on your friends list")
        case 4: return L("Steam refused the request")
        case 0: return L("No answer from Steam")
        default: return L("Friends are unavailable")
        }
    }
}

extension SteamOnlineStatus {
    var title: String {
        switch self {
        case .online: return L("Online")
        case .away: return L("Away")
        case .invisible: return L("Invisible")
        case .offline: return L("Offline")
        }
    }
}

struct DockFriendRow: View {
    let friend: DockFriends.Friend
    @ObservedObject var model: DockFriends

    private var status: String {
        if friend.dockFlags & 8 != 0 { return L("Invited you to play") }
        if friend.dockFlags & 4 != 0 { return L("In this game · joinable") }
        if friend.dockFlags & 2 != 0 { return L("In this game") }
        if friend.dockFlags & 1 != 0 { return L("In another game") }
        switch friend.state {
        case 0: return L("Offline")
        case 2: return L("Busy")
        case 3, 4: return L("Away")
        default: return L("Online")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(friend.dockFlags & 8 != 0 ? Color.yellow : friend.dockFlags & 3 != 0 ? Color.green : friend.state > 0 ? Color.blue : Color.gray)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.name.isEmpty ? L("Unknown") : friend.name).lineLimit(1)
                if let outcome = model.outcome, outcome.steamID == friend.steamID {
                    Text(DockFriends.message(action: outcome.action, result: outcome.result))
                        .font(.caption).foregroundStyle(outcome.result == 1 ? .green : .orange)
                } else {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.pending?.steamID == friend.steamID {
                ProgressView()
            } else {
                if friend.dockFlags & 8 != 0 {
                    Button("Accept") { model.send(.join, to: friend) }
                        .buttonStyle(.borderedProminent).disabled(model.pending != nil)
                } else if friend.dockFlags & 4 != 0 {
                    Button("Join") { model.send(.join, to: friend) }
                        .buttonStyle(.borderedProminent).disabled(model.pending != nil)
                }
                // Like desktop Steam: Invite only while you have a lobby or connect string to invite with (feed flag 16).
                if friend.state > 0, friend.dockFlags & 16 != 0 {
                    Button("Invite") { model.send(.invite, to: friend) }.buttonStyle(.bordered)
                        .disabled(model.pending != nil)
                }
            }
        }
        .frame(minHeight: 44)
    }
}
