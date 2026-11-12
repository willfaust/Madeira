#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Compile the app's production Madeira Dock Friends model; synthetic files only.

Dock writes the friends feed to C:\\madeira-friends.bin and answers commands from
C:\\madeira-friends-cmd.bin with friends-cmd-seq / friends-cmd-result report lines
(madeira-dock README, "Friends"). Checked here, against a temporary drive_c:
feed bounds, the command bytes, matching a command to its own result, the
timeout, reset and session end, and that a missing, invalid or stale feed
leaves no old list behind. No Steam, Wine or device session is used.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


friends = (app / 'DockFriends.swift').read_text()
dock = (app / 'MadeiraDock.swift').read_text()
library = (app / 'Library.swift').read_text()

# ------------------------------------------------------------------ static
cleanup = dock[dock.index('    @MainActor static func cleanup() {'):]
cleanup = cleanup[:cleanup.index('\n    }\n')]
require('DockFriends.shared.endSession()' in cleanup, 'MadeiraDock.cleanup() (session end, app start, sign-out) removes the friends files')
require('dockFriends.available' in library and 'dockFriends.refresh()' in library, 'the Session menu shows Friends only for a current feed')
for line in friends.splitlines():
    if 'SteamLog.' in line:
        require(re.search(r'\\\((?:[^)]*\.)?(name|steamID|id|friend|data|url)\b', line) is None,
                f'DockFriends.swift: no SteamID, name or path logged in "{line.strip()[:60]}"')
require('setenv("MADEIRA_DOCK_PERSONA_STATE", String(SteamOnlineStatus.current.rawValue), 1)' in dock,
        'the launch passes the chosen status to Dock')

# ------------------------------------------------------------------ compiled
model = friends[friends.index('@MainActor final class DockFriends'):friends.index('struct DockFriendRow')]
status = dock[dock.index('/// The Steam status Dock signs in to Friends with'):]
stubs = r'''
import Foundation
import Combine
enum MadeiraDock { static var drive = URL(fileURLWithPath: "/nonexistent") }
enum SteamLog { static var events: [String] = []; static func event(_ m: String) { events.append(m) } }
func L(_ text: String) -> String { text }
'''
checks = r'''
let drive = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
MadeiraDock.drive = drive
let feed = drive.appendingPathComponent("madeira-friends.bin")
let commandFile = drive.appendingPathComponent("madeira-friends-cmd.bin")
let report = drive.appendingPathComponent("madeira-dock.txt")
let fm = FileManager.default

func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
func entry(_ id: UInt64, _ name: String, state: UInt32 = 1, app: UInt32 = 0, flags: UInt8 = 0) -> [UInt8] {
    le64(id) + le32(state) + le32(app) + [flags, UInt8(name.utf8.count)] + Array(name.utf8)
}
func encode(_ entries: [[UInt8]], count: UInt32? = nil) -> Data {
    Data(Array("MFRND001".utf8) + le32(count ?? UInt32(entries.count)) + entries.flatMap { $0 })
}
let alice: UInt64 = 0x0110000100000001, bob: UInt64 = 0x0110000100000002, carol: UInt64 = 0x0110000100000003

// Feed bounds (parseFeed).
let one = encode([entry(alice, "Alice")])
assert(DockFriends.parseFeed(one)?.first?.name == "Alice")
assert(DockFriends.parseFeed(encode([]))?.isEmpty == true)
assert(DockFriends.parseFeed(Data("MFRND002".utf8) + Data(le32(0))) == nil, "magic")
assert(DockFriends.parseFeed(Data(one.prefix(11))) == nil, "short header")
assert(DockFriends.parseFeed(Data(one.dropLast())) == nil, "truncated name")
assert(DockFriends.parseFeed(one + Data([0])) == nil, "trailing byte")
assert(DockFriends.parseFeed(encode([entry(alice, "Alice")], count: 2)) == nil, "count past the data")
assert(DockFriends.parseFeed(encode([], count: 251)) == nil, "count past 250")
assert(DockFriends.parseFeed(encode([entry(alice, String(repeating: "a", count: 63))])) != nil)
assert(DockFriends.parseFeed(encode([entry(alice, String(repeating: "a", count: 64))])) == nil, "64-byte name")
var badName = entry(alice, "ab"); badName[badName.count - 1] = 0xff
assert(DockFriends.parseFeed(encode([badName])) == nil, "invalid UTF-8")
let full = encode((0..<250).map { entry(alice + UInt64($0), String(repeating: "n", count: 63)) })
assert(full.count <= DockFriends.feedCap && DockFriends.parseFeed(full)?.count == 250, "the largest feed")
let oversized = Data(Array("MFRND001".utf8) + le32(0)) + Data(count: DockFriends.feedCap - 11)
assert(oversized.count == DockFriends.feedCap + 1 && DockFriends.parseFeed(oversized) == nil, "past the cap")

// Display order: invited, joinable, this game, another game, online, offline; by name.
let order = DockFriends.ordered(DockFriends.parseFeed(encode([
    entry(1, "zed", state: 0), entry(2, "Yan"), entry(3, "xia", flags: 1), entry(4, "Wu", flags: 3),
    entry(5, "vic", flags: 7), entry(6, "Uma", state: 0, flags: 8), entry(7, "abe")]))!).map(\.steamID)
assert(order == [6, 5, 4, 3, 7, 2, 1], "\(order)")

// Command bytes: magic, action, SteamID (LE), sequence (LE); sequences stay below 2^31.
assert([UInt8](DockFriends.command(.invite, id: alice, sequence: 0x01020304)) ==
       Array("MFCMD001".utf8) + [1] + le64(alice) + [4, 3, 2, 1])
assert(DockFriends.command(.setStatus, id: 7, sequence: 1).count == 21)
assert(DockFriends.nextSequence(after: 41) == 42)
assert(DockFriends.nextSequence(after: 0x7fff_fffe) == 0x7fff_ffff)
assert(DockFriends.nextSequence(after: 0x7fff_ffff) == 1 && DockFriends.nextSequence(after: 0xffff_ffff) == 1)
assert(DockFriends.nextSequence(after: 0x8000_0005) == 6)

// A command's own result only: after its friends-cmd-seq, complete lines only.
func lines(_ l: [String], end: String = "\r\n") -> Data { Data((l.joined(separator: "\r\n") + end).utf8) }
let r = { (s: String) in "[steam-host] ml2020 " + s }
assert(DockFriends.commandResult(in: lines([r("friends-cmd-seq=9"), r("friends-cmd-result=1")]), sequence: 9) == 1)
assert(DockFriends.commandResult(in: lines([r("friends-cmd-result=4"), r("friends-cmd-seq=9")]), sequence: 9) == nil, "a result before the sequence")
assert(DockFriends.commandResult(in: lines([r("friends-cmd-seq=19"), r("friends-cmd-result=1")]), sequence: 9) == nil, "another sequence")
assert(DockFriends.commandResult(in: lines([r("friends-cmd-seq=9"), r("friends-cmd-seq=10"), r("friends-cmd-result=1")]), sequence: 9) == nil, "a later command's result")
assert(DockFriends.commandResult(in: lines([r("friends-cmd-seq=9"), r("friends-count=3"), r("friends-cmd-result=2")]), sequence: 9) == 2)
assert(DockFriends.commandResult(in: lines([r("friends-cmd-seq=9"), r("friends-cmd-result=1")], end: ""), sequence: 9) == nil, "a partial final line")
assert(DockFriends.commandResult(in: lines([r("friends-cmd-seq=2147483647"), r("friends-cmd-result=3")]), sequence: 0x7fff_ffff) == 3)

MainActor.assumeIsolated {
    let model = DockFriends()
    let now = Date()
    func writeFeed(_ data: Data, age: TimeInterval = 0) {
        try! data.write(to: feed)
        try! fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: feed.path)
    }

    // Valid -> missing, valid -> invalid, valid -> stale: never an old list.
    model.refresh(now: now)
    assert(!model.available && model.friends.isEmpty, "no feed")
    writeFeed(one); model.refresh(now: now)
    assert(model.available && model.friends.map(\.name) == ["Alice"])
    try! fm.removeItem(at: feed); model.refresh(now: now)
    assert(!model.available && model.friends.isEmpty, "valid to missing")
    writeFeed(one); model.refresh(now: now); assert(model.friends.count == 1)
    writeFeed(Data([0])); model.refresh(now: now)
    assert(!model.available && model.friends.isEmpty, "valid to invalid")
    writeFeed(one); model.refresh(now: now); assert(model.friends.count == 1)
    writeFeed(one, age: DockFriends.feedMaxAge + 1); model.refresh(now: now)
    assert(!model.available && model.friends.isEmpty, "valid to stale (a host that did not end cleanly)")
    writeFeed(oversized); model.refresh(now: now)
    assert(!model.available, "oversized feed")

    // No command without a current feed.
    model.send(.invite, to: DockFriends.Friend(steamID: alice, name: "Alice", dockFlags: 16), now: now)
    assert(model.pending == nil && !fm.fileExists(atPath: commandFile.path), "no command while friends are unavailable")

    // A command, its bytes, and its own result in the report written after it.
    writeFeed(encode([entry(alice, "Alice", flags: 16), entry(bob, "Bob", state: 3, app: 70, flags: 7)]))
    model.refresh(now: now)
    try! lines([r("friends-available=1"), r("friends-cmd-seq=1"), r("friends-cmd-result=4")]).write(to: report)
    let bobFriend = model.friends.first { $0.steamID == bob }!
    model.send(.join, to: bobFriend, now: now)
    let sent = model.pending!
    assert(sent.action == .join && sent.steamID == bob && sent.sequence <= 0x7fff_ffff)
    assert(try! Data(contentsOf: commandFile) == DockFriends.command(.join, id: bob, sequence: sent.sequence))
    model.send(.invite, to: bobFriend, now: now)
    assert(model.pending == sent, "one command at a time")
    // An earlier session's answer for the same number, before the command was sent, is not this one's.
    let before = (try! Data(contentsOf: report))
    model.refresh(now: now)
    assert(model.pending == sent)
    let handle = try! FileHandle(forWritingTo: report); handle.seekToEndOfFile()
    handle.write(lines([r("friends-cmd-seq=\(sent.sequence &+ 1)"), r("friends-cmd-result=4"),
                        r("friends-cmd-seq=\(sent.sequence)"), r("friends-cmd-result=1")])); handle.closeFile()
    model.refresh(now: now)
    assert(model.pending == nil && model.outcome?.steamID == bob && model.outcome?.result == 1 && model.outcome?.action == .join)
    assert(DockFriends.message(action: .join, result: 1) == "Sent to the game")

    // The earlier lines are ignored by offset: an answer that only exists there does not count.
    try! (before + lines([r("friends-cmd-seq=\(DockFriends.nextSequence(after: sent.sequence))"), r("friends-cmd-result=1")])).write(to: report)
    let reportSize = (try! fm.attributesOfItem(atPath: report.path))[.size] as! UInt64
    model.send(.invite, to: bobFriend, now: now)
    let second = model.pending!
    assert(second.sequence == DockFriends.nextSequence(after: sent.sequence))
    model.refresh(now: now)
    assert(model.pending == second, "an answer written before the command was sent is not its answer (report \(reportSize) bytes)")

    // No answer in commandTimeout: "No answer from Steam" (result 0).
    model.refresh(now: now.addingTimeInterval(DockFriends.commandTimeout - 1))
    assert(model.pending == second)
    model.refresh(now: now.addingTimeInterval(DockFriends.commandTimeout + 1))
    assert(model.pending == nil && model.outcome?.result == 0 && DockFriends.message(action: .invite, result: 0) == "No answer from Steam")

    // A new, shorter report (a new session) is read from its start.
    model.send(.invite, to: bobFriend, now: now)
    let third = model.pending!
    try! lines([r("friends-cmd-seq=\(third.sequence)"), r("friends-cmd-result=2")]).write(to: report)
    model.refresh(now: now)
    assert(model.pending == nil && model.outcome?.result == 2)

    // Status: Offline is never sent; the others are, with the status in the id field.
    model.setStatus(.offline, now: now)
    assert(model.pending == nil)
    model.setStatus(.away, now: now)
    assert(model.pending?.action == .setStatus && model.pending?.steamID == 3)
    assert(SteamOnlineStatus.current == .away)

    // Reset and session end.
    model.reset()
    assert(model.friends.isEmpty && !model.available && model.pending == nil && model.outcome == nil)
    writeFeed(one); try! Data([1]).write(to: commandFile); model.refresh(now: now)
    assert(model.available)
    model.endSession()
    assert(!fm.fileExists(atPath: feed.path) && !fm.fileExists(atPath: commandFile.path))
    assert(!model.available && model.friends.isEmpty)
    model.refresh(now: now)
    assert(!model.available, "nothing left for the next session")
}
assert(!SteamLog.events.contains { $0.contains("Alice") || $0.contains("Bob") || $0.contains(String(alice)) || $0.contains(String(bob)) },
       "logs carry no names or SteamIDs")

// Friends are opt-in: with nothing chosen the status is Offline (friends off).
UserDefaults.standard.removeObject(forKey: "steamOnlineStatus")
assert(SteamOnlineStatus.current == .offline)
SteamOnlineStatus.current = .invisible
assert(SteamOnlineStatus.current == .invisible && UserDefaults.standard.integer(forKey: "steamOnlineStatus") == 7)
UserDefaults.standard.set(5, forKey: "steamOnlineStatus")
assert(SteamOnlineStatus.current == .offline, "an unknown stored value is Offline")
UserDefaults.standard.removeObject(forKey: "steamOnlineStatus")
print("PASS: Friends feed bounds, display order, command bytes, 31-bit sequences, own-result matching, timeout, reset, session end, valid-to-missing/invalid/stale feeds, opt-in status")
'''
with tempfile.TemporaryDirectory(prefix='madeira-dock-friends-') as directory:
    work = Path(directory)
    source = work / 'main.swift'; binary = work / 'check'; drive = work / 'drive_c'
    drive.mkdir()
    source.write_text(stubs + model + '\n' + status + '\n' + checks)
    built = subprocess.run([SWIFTC, '-Onone', str(source), '-o', str(binary)])
    require(built.returncode == 0, 'production DockFriends model compiles on the host')
    if built.returncode == 0:
        env = dict(os.environ, CFFIXED_USER_HOME=str(work))
        require(subprocess.run([str(binary), str(drive)], env=env).returncode == 0, 'Friends model checks')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
