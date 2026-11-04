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

    /// C:\madeira-friends.bin: magic MFRND001, count, then per friend
    /// SteamID(8) state(4) App ID(4) flags(1) name length(1) name.
    nonisolated static func parseFeed(_ data: Data) -> [Friend]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes.count <= 12 + 250 * (18 + 64),
              Array(bytes[0..<8]) == Array("MFRND001".utf8) else { return nil }
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * $1) } }
        func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[at + $1]) << (8 * $1) } }
        let count = Int(u32(8))
        guard count <= 250 else { return nil }
        var at = 12, result: [Friend] = []
        for _ in 0..<count {
            guard at + 18 <= bytes.count else { return nil }
            let length = Int(bytes[at + 17])
            guard length < 64, at + 18 + length <= bytes.count,
                  let name = String(bytes: bytes[(at + 18)..<(at + 18 + length)], encoding: .utf8) else { return nil }
            result.append(Friend(steamID: u64(at), name: name, dockFlags: bytes[at + 16], state: u32(at + 8), appID: u32(at + 12)))
            at += 18 + length
        }
        return at == bytes.count ? result : nil
    }

    struct Pending: Equatable {
        let action: Action
        let steamID: UInt64
        let sequence: UInt32
    }

    @Published private(set) var friends: [DockFriends.Friend] = []
    /// Dock is running with friends available (its feed exists).
    @Published private(set) var available = false
    @Published private(set) var pending: Pending?
    /// The last finished command, for the row that sent it.
    @Published private(set) var outcome: (steamID: UInt64, action: Action, result: Int)?

    private var sequence = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)) | 1
    private var sentAt = Date.distantPast

    private var feedURL: URL { MadeiraDock.drive.appendingPathComponent("madeira-friends.bin") }
    private var commandURL: URL { MadeiraDock.drive.appendingPathComponent("madeira-friends-cmd.bin") }
    private var reportURL: URL { MadeiraDock.drive.appendingPathComponent("madeira-dock.txt") }

    /// Re-reads the feed and the pending command's result.
    func refresh() {
        let data = try? Data(contentsOf: feedURL)
        available = data != nil
        if let data, let parsed = DockFriends.parseFeed(data) {
            friends = parsed.sorted { order($0) != order($1) ? order($0) < order($1)
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        if let pending { checkResult(pending) }
    }

    /// Invites first, then joinable friends in this game, this game, other games, online, offline.
    private func order(_ f: DockFriends.Friend) -> Int {
        if f.dockFlags & 8 != 0 { return -1 }
        if f.dockFlags & 4 != 0 { return 0 }
        if f.dockFlags & 2 != 0 { return 1 }
        if f.dockFlags & 1 != 0 { return 2 }
        return f.state > 0 ? 3 : 4
    }

    /// Changes the status in a running session. Offline is not offered: it is
    /// chosen before launch and turns friends off for the session.
    func setStatus(_ status: SteamOnlineStatus) {
        guard status != .offline else { return }
        send(.setStatus, id: UInt64(status.rawValue))
        SteamOnlineStatus.current = status
    }

    func send(_ action: Action, to friend: DockFriends.Friend) { send(action, id: friend.steamID) }

    private func send(_ action: Action, id: UInt64) {
        guard pending == nil else { return }
        sequence = sequence &+ 1
        if sequence == 0 { sequence = 1 }
        var bytes = [UInt8]("MFCMD001".utf8)
        bytes.append(action.rawValue)
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: id >> (8 * UInt64(i)))) }
        for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: sequence >> (8 * UInt32(i)))) }
        do {
            try Data(bytes).write(to: commandURL, options: .atomic)
        } catch {
            SteamLog.event("[dock-friends] command not written")
            outcome = (id, action, 6)
            return
        }
        pending = Pending(action: action, steamID: id, sequence: sequence)
        sentAt = Date()
        outcome = nil
        SteamLog.event("[dock-friends] \(action) sent")
    }

    /// Dock answers with friends-cmd-seq (this command's sequence), then
    /// friends-cmd-result; without an answer in 10 s the command lapses.
    private func checkResult(_ pending: Pending) {
        if let data = try? Data(contentsOf: reportURL), data.count <= 1 << 20 {
            var seenSequence = false
            // Dock writes CRLF lines; "\r\n" is one Character, so split on newlines.
            for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasSuffix("friends-cmd-seq=\(pending.sequence)") { seenSequence = true }
                else if seenSequence, let range = line.range(of: "friends-cmd-result="),
                        let value = Int(line[range.upperBound...]) {
                    finish(pending, result: value)
                    return
                }
            }
        }
        if Date().timeIntervalSince(sentAt) > 10 { finish(pending, result: 0) }
    }

    private func finish(_ pending: Pending, result: Int) {
        self.pending = nil
        outcome = (pending.steamID, pending.action, result)
        SteamLog.event("[dock-friends] \(pending.action) result=\(result)")
        // The row shows the result for a few seconds, then its status again.
        let sequence = pending.sequence
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if self.pending == nil, self.lastSequence == sequence { self.outcome = nil }
        }
        lastSequence = sequence
    }
    private var lastSequence: UInt32 = 0

    /// Clears the state when a Dock session ends.
    func reset() {
        friends = []
        available = false
        pending = nil
        outcome = nil
    }

    static func message(action: Action, result: Int) -> String {
        switch result {
        // Join hands the lobby to the game; whether the game gets in is up to it.
        case 1: return action == .invite ? "Invite sent" : action == .setStatus ? "Status changed" : "Sent to the game"
        case 2: return action == .invite ? "Nothing to invite to yet: join or create a lobby" : "Not in a joinable lobby"
        case 3: return "Not on your friends list"
        case 4: return "Steam refused the request"
        case 0: return "No answer from Steam"
        default: return "Friends are unavailable"
        }
    }
}

struct DockFriendRow: View {
    let friend: DockFriends.Friend
    @ObservedObject var model: DockFriends

    private var status: String {
        if friend.dockFlags & 8 != 0 { return "Invited you to play" }
        if friend.dockFlags & 4 != 0 { return "In this game · joinable" }
        if friend.dockFlags & 2 != 0 { return "In this game" }
        if friend.dockFlags & 1 != 0 { return "In another game" }
        switch friend.state {
        case 0: return "Offline"
        case 2: return "Busy"
        case 3, 4: return "Away"
        default: return "Online"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(friend.dockFlags & 8 != 0 ? Color.yellow : friend.dockFlags & 3 != 0 ? Color.green : friend.state > 0 ? Color.blue : Color.gray)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.name.isEmpty ? "Unknown" : friend.name).lineLimit(1)
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
                if friend.dockFlags & 12 != 0 {
                    Button(friend.dockFlags & 8 != 0 ? "Accept" : "Join") { model.send(.join, to: friend) }
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

/// The Steam status Dock signs in with (Settings › Steam). The raw value is
/// Steam's persona state, passed to Dock as MADEIRA_DOCK_PERSONA_STATE.
enum SteamOnlineStatus: Int, CaseIterable, Identifiable {
    case online = 1, away = 3, invisible = 7, offline = 0
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .online: return "Online"
        case .away: return "Away"
        case .invisible: return "Invisible"
        case .offline: return "Offline"
        }
    }
    private static let key = "steamOnlineStatus"
    static var current: SteamOnlineStatus {
        get { SteamOnlineStatus(rawValue: UserDefaults.standard.object(forKey: key) as? Int ?? 1) ?? .online }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
