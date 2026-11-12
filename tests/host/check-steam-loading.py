#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Production PICS batches and cache lifecycle with a scripted session, no network."""
from pathlib import Path
import os
import argparse
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
fetcher = (app / 'SwiftSteam/Library/SteamLibraryFetcher.swift').read_text()
source = (app / 'SteamOwnedLibrary.swift').read_text()
parser = argparse.ArgumentParser()
parser.add_argument('--pics-benchmark', action='store_true', help='only time the complete scripted cold fetch')
parser.add_argument('--source-ref', help='local baseline ref, only for --pics-benchmark')
args = parser.parse_args()
if args.source_ref:
    if not args.pics_benchmark: parser.error('--source-ref requires --pics-benchmark')
    fetcher = subprocess.check_output(['git', 'show', f'{args.source_ref}:app/Madeira/SwiftSteam/Library/SteamLibraryFetcher.swift'], cwd=root, text=True)

def block(text, header):
    start = text.index(header)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

owned_types = source[source.index('struct SteamOwnedGame:'):source.index('// MARK: - Playtime')]
writer = source[source.index('final class SteamLibraryCacheWriter:'):]
writer = writer.replace('try? JSONEncoder().encode(cache)', 'precondition(!Thread.isMainThread, "encoding must run off main")\n            try? JSONEncoder().encode(cache)')
cache = block(source, '    struct Cache:')
load = block(source, '    private func loadCaches()').replace('private func', 'func', 1)
lifecycle = '\n'.join(block(source, marker).replace('private func', 'func', 1) for marker in ['    func start()', '    private func refreshIfStale()', '    func refreshAfterForeground()', '    private func signInChanged()', '    func refreshLibrary(interactive:'])
load = load.replace('() -> (Cache?, [Int: SteamPlaytime]) in', '''() -> (Cache?, [Int: SteamPlaytime]) in
            precondition(!Thread.isMainThread, "cache decode must run off the main thread")
            if DecodeGate.enabled { DecodeGate.blockReader() }''')
lifecycle = lifecycle.replace('func refreshLibrary(interactive: Bool = true) async {', 'func refreshLibrary(interactive: Bool = true) async {\n        refreshInvocations.append(interactive)')
stubs = r'''
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
enum SteamLog { static func event(_ message: String) {}; static func trace(_ message: @autoclosure () -> String) {} }
enum MadeiraConfig {
    static func get(_ key: String) -> String? { nil }
    static func set(_ key: String, _ value: String?) {}
    static func gameValue(_ key: String) -> String? { nil }
}
enum SteamInstallFiles { static func safeFolderName(_ value: String) -> String { value } }
enum UIApplication { static let didEnterBackgroundNotification = Notification.Name("test.background") }
struct SteamPlaytime: Codable, Sendable { var minutes: Int }
enum DecodeGate {
    static var enabled = false
    static let arrived = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    static func blockReader() { arrived.signal(); release.wait() }
    static func blockUntilRead() { arrived.wait() }
    static func waitForRead() async { await Task.detached { blockUntilRead() }.value }
}
struct SteamMessageCodec { struct IncomingMessage { var body: Data } }
@MainActor final class SteamCMSession {
    var active = 0, maximum = 0, calls = 0
    var fail = false
    var completed: [UInt32] = []
    func ensureConnected() async throws {}
    func awaitLicenseList(timeout: TimeInterval) async throws -> [UInt32] { (1...3600).map(UInt32.init) }
    func sendAndWait(eMsg: EMsg, body: Data, responseEMsg: EMsg, timeout: TimeInterval) async throws -> SteamMessageCodec.IncomingMessage {
        precondition(eMsg == .clientPICSAccessTokenRequest)
        var request = ProtobufDecoder(body), response = ProtobufEncoder()
        while let tag = try request.readTag() {
            let id = UInt32(try request.readVarint())
            var entry = ProtobufEncoder()
            entry.writeUInt32(fieldNumber: 1, value: id)
            entry.writeUInt64(fieldNumber: 2, value: UInt64(id) + 100)
            response.writeSubmessage(fieldNumber: tag.fieldNumber == 1 ? 1 : 3, value: entry.data)
        }
        return .init(body: response.data)
    }
    func sendAndWaitPICS(eMsg: EMsg, body: Data, timeout: TimeInterval) async throws -> [SteamMessageCodec.IncomingMessage] {
        var decoder = ProtobufDecoder(body)
        var ids: [UInt32] = [], packages = false
        while let tag = try decoder.readTag() {
            guard tag.fieldNumber == 1 || tag.fieldNumber == 2 else { try decoder.skip(wireType: tag.wireType); continue }
            packages = tag.fieldNumber == 1
            var sub = ProtobufDecoder(try decoder.readBytes())
            var id: UInt32 = 0, token: UInt64 = 0
            while let field = try sub.readTag() {
                if field.fieldNumber == 1 { id = UInt32(try sub.readVarint()) }
                else if field.fieldNumber == 2 { token = try sub.readVarint() }
                else { try sub.skip(wireType: field.wireType) }
            }
            precondition(token == UInt64(id) + 100, "each request must retain its own token")
            ids.append(id)
        }
        precondition(!ids.isEmpty && ids.count <= 50)
        calls += 1; active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        // Reverse completion within each window, without using real Steam latency.
        try await Task.sleep(nanoseconds: UInt64(4 - ((ids[0] - 1) / 50) % 4) * 2_000_000)
        if fail && ids[0] == 51 { throw SteamError.connectionTimeout }
        completed.append(ids[0])
        var parts: [SteamMessageCodec.IncomingMessage] = []
        // A session returns all messages for a job; exercise a split reply.
        for half in [Array(ids.prefix(25)), Array(ids.dropFirst(25))] where !half.isEmpty {
            var response = ProtobufEncoder()
            for id in half {
                var item = ProtobufEncoder()
                item.writeUInt32(fieldNumber: 1, value: id)
                if packages {
                    // Binary package VDF: appids { "0" = app id }, after the package header.
                    var data = Data(repeating: 0, count: 4)
                    data.append(contentsOf: [0]); data.append(Data("appids\0".utf8))
                    data.append(contentsOf: [2, 48, 0])
                    var little = id.littleEndian
                    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
                    data.append(contentsOf: [8, 8])
                    item.writeBytes(fieldNumber: 5, value: data)
                } else {
                    item.writeBytes(fieldNumber: 5, value: Data("\"appinfo\" { \"common\" { \"name\" \"Game \(id)\" \"type\" \"game\" } }".utf8))
                }
                response.writeSubmessage(fieldNumber: packages ? 3 : 1, value: item.data)
            }
            parts.append(.init(body: response.data))
        }
        return parts
    }
}
'''
harness = r'''
@MainActor final class LifecycleFetcher {
    var pending: CheckedContinuation<[SteamAppInfo], Error>?
    var ownedDLC: [SteamAppInfo] = []
    var calls = 0
    func fetchOwnedApps() async throws -> [SteamAppInfo] {
        calls += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func fail() { let request = pending; pending = nil; request?.resume(throwing: SteamError.disconnected) }
}
@MainActor final class LifecycleSession { func logoff() {} }
@MainActor final class SteamDownloadBackground {
    static let shared = SteamDownloadBackground()
    func attach(_ library: SteamOwnedLibrary) {}
}
@MainActor final class SteamOwnedLibrary {
    static var enabled = true, dlcEnabled = true
    var loadingCache = false, started = false, refreshing = false, inSession = false
    var lastLibraryRefreshAttempt: Date?
    var cachedAccount: String?
    var downloads: [Int: Int] = [:]
    let session = LifecycleSession(), fetcher = LifecycleFetcher(), cacheWriter = SteamLibraryCacheWriter()
    var reports: [Bool] = [], refreshInvocations: [Bool] = [], playtimeRequests = 0
    func handleSessionError(_ error: Error, context: String, report: Bool) { reports.append(report) }
    func writeCache() {}
    func refreshPlaytime() async { playtimeRequests += 1 }
    func pause(_ id: Int) {}
    func clearCaches() { cachedAccount = nil }
    static var cacheURL: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("cache.json") }
    static var playtimeURL: URL { cacheURL.deletingLastPathComponent().appendingPathComponent("playtime.json") }
    static var account = "account-a"
    static func accountKey(_ name: String?) -> String? { name }
    var signedIn = true, accountGeneration = 0, ownedRevision = 0
    var owned: [SteamOwnedGame] = []
    var libraryUpdated: Date?
    var playtime: [Int: SteamPlaytime] = [:]
    CACHE
    LOAD
    LIFECYCLE
}
@MainActor enum SteamSignIn {
    static var accountName: String? { SteamOwnedLibrary.account }
    static let didChange = Notification.Name("test.signInChanged")
    static var isSignedIn = true
}
@main struct Checks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let session = SteamCMSession()
        let ids = (1...3600).map(UInt32.init)
        let tokens = Dictionary(uniqueKeysWithValues: ids.map { ($0, UInt64($0) + 100) })
        let real = SteamLibraryFetcher(session: session)
        let start = DispatchTime.now().uptimeNanoseconds
        let apps = try await real.fetchAppInfo(appIDs: ids, tokens: tokens)
        precondition(apps.map(\.appID) == ids, "all apps, stable batch order despite reordered and split replies")
        precondition(session.maximum == 4 && session.active == 0 && session.calls == 72)
        print("PASS: 3600 apps, 72 requests, max 4 concurrent, reordered/split replies, token preservation; scripted milliseconds=\(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)")
        let packages = try await real.fetchAppIDsFromPackages(packageIDs: ids, tokens: tokens)
        precondition(packages == Set(ids), "all package IDs decoded")
        precondition(session.calls == 144)
        session.fail = true
        do { _ = try await real.fetchAppInfo(appIDs: ids, tokens: tokens); fatalError("failure must propagate") }
        catch SteamError.connectionTimeout { precondition(session.active == 0) }
        session.fail = false
        let cancelled = Task { try await real.fetchAppInfo(appIDs: ids, tokens: tokens) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("cancellation must propagate") } catch is CancellationError {}
        print("PASS: packages, errors, cancellation and no remaining in-flight work")

        let writer = SteamLibraryCacheWriter()
        let file = SteamOwnedLibrary.cacheURL, playtime = SteamOwnedLibrary.playtimeURL
        let cache = SteamOwnedLibrary.Cache(version: 2, updated: Date(), account: "account-a", games: apps.map { SteamOwnedGame($0) })
        for _ in 0..<40 { writer.write(cache, to: file) }
        writer.clear(cacheURL: file, playtimeURL: playtime)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        precondition(!FileManager.default.fileExists(atPath: file.path), "sign-out cannot restore an old queued snapshot")
        for _ in 0..<40 {
            writer.write(cache, to: file)
            writer.clear(cacheURL: file, playtimeURL: playtime)
        }
        let newer = SteamOwnedLibrary.Cache(version: 2, updated: Date(), account: "account-b", games: Array(cache.games.prefix(1)))
        writer.write(newer, to: file)
        writer.writePlaytime([1: SteamPlaytime(minutes: 42)], to: playtime)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let written = try JSONDecoder().decode(SteamOwnedLibrary.Cache.self, from: Data(contentsOf: file))
        precondition(written.account == "account-b" && written.games.count == 1, "new account wins after old queued jobs and clears")
        let minutes = try JSONDecoder().decode([Int: SteamPlaytime].self, from: Data(contentsOf: playtime))
        precondition(minutes[1]?.minutes == 42, "new playtime must be ordered after old clears")
        print("PASS: coalesced writes, ordered clear/new-account/playtime writes, background drain")

        writer.write(cache, to: file)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let library = SteamOwnedLibrary()
        await library.loadCaches()
        precondition(library.owned.count == 3600)
        let switching = SteamOwnedLibrary()
        DecodeGate.enabled = true
        let loading = Task { await switching.loadCaches() }
        await DecodeGate.waitForRead()
        switching.accountGeneration += 1
        switching.signedIn = false
        DecodeGate.release.signal()
        await loading.value
        precondition(switching.owned.isEmpty, "cache must not land after sign-out")
        let updated = SteamOwnedLibrary()
        let older = Task { await updated.loadCaches() }
        await DecodeGate.waitForRead()
        updated.ownedRevision += 1
        DecodeGate.release.signal()
        await older.value
        DecodeGate.enabled = false
        precondition(updated.owned.isEmpty, "a newer list supersedes a cache read")
        SteamOwnedLibrary.account = "account-b"
        let different = SteamOwnedLibrary()
        await different.loadCaches()
        precondition(different.owned.isEmpty, "another account cannot load the previous cache")
        print("PASS: off-main cache read/encode, sign-out, account mismatch and newer-publication guards")
        SteamOwnedLibrary.account = "account-a"
        DecodeGate.enabled = true
        let warm = SteamOwnedLibrary()
        warm.start()
        precondition(warm.loadingCache, "start sets the cache gate before scheduling the task")
        await DecodeGate.waitForRead()
        warm.refreshAfterForeground()
        precondition(warm.fetcher.calls == 0 && warm.lastLibraryRefreshAttempt == nil,
                     "activation while cache decode is suspended cannot start a network refresh")
        DecodeGate.release.signal()
        while warm.loadingCache { await Task.yield() }
        precondition(warm.owned.count == 3600 && warm.fetcher.calls == 0)
        DecodeGate.enabled = false
        let switchingRefresh = SteamOwnedLibrary()
        let original = Task { await switchingRefresh.refreshLibrary(interactive: false) }
        while switchingRefresh.fetcher.pending == nil { await Task.yield() }
        SteamOwnedLibrary.account = "account-b"
        switchingRefresh.signInChanged()
        // The new-account request encounters the old refresh's busy guard.
        while !switchingRefresh.refreshInvocations.contains(true) { await Task.yield() }
        switchingRefresh.fetcher.fail()
        await original.value
        while switchingRefresh.fetcher.pending == nil { await Task.yield() }
        switchingRefresh.fetcher.fail()
        while switchingRefresh.refreshing { await Task.yield() }
        precondition(switchingRefresh.fetcher.calls == 2 && switchingRefresh.reports == [true],
                     "old-account errors are discarded; the new account retry preserves interactive failure reporting")
        print("PASS: production startup/foreground cache race and account-switch interactive retry")
    }
}
'''
# Compile the whole production fetcher, exposing only two methods for focused checks.
full_fetcher = fetcher.replace('private func fetchAppIDsFromPackages', 'func fetchAppIDsFromPackages').replace('private func fetchAppInfo(appIDs:', 'func fetchAppInfo(appIDs:')
program = stubs + owned_types + full_fetcher + harness.replace('    CACHE', cache).replace('    LOAD', load).replace('    LIFECYCLE', lifecycle) + writer
if args.pics_benchmark:
    program = stubs + full_fetcher + r'''
@main struct Benchmark {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        for _ in 0..<5 {
            let session = SteamCMSession(), fetcher = SteamLibraryFetcher(session: SteamCMSession())
            let real = SteamLibraryFetcher(session: session)
            let start = DispatchTime.now().uptimeNanoseconds
            let apps = try await real.fetchOwnedApps()
            precondition(Set(apps.map(\.appID)) == Set((1...3600).map(UInt32.init)))
            precondition(session.calls == 144 && session.active == 0)
            _ = fetcher
            print("TIME full-owned-fetch-scripted \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) ms")
            print("COUNT requests=\(session.calls) max-concurrent=\(session.maximum) apps=\(apps.count)")
        }
    }
}
'''
private_root = Path.home() / 'tmp'
private_root.mkdir(mode=0o700, exist_ok=True)
private_root.chmod(0o700)
with tempfile.TemporaryDirectory(prefix='pi-steam-loading.', dir=private_root) as tmp:
    folder = Path(tmp)
    env = dict(os.environ, TMPDIR=tmp, TMP=tmp, TEMP=tmp)
    swift = folder / 'checks.swift'
    swift.write_text(program)
    exe = folder / 'checks'
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-swift-version', '5', str(swift),
                    str(app / 'SwiftSteam/Core/SteamProtocol.swift'), str(app / 'SwiftSteam/Core/SteamError.swift'), str(app / 'SteamKeyValues.swift'), str(app / 'SwiftSteam/Proto/SteamProtoMessages.swift'),
                    str(app / 'SwiftSteam/Library/SteamAppInfo.swift'), '-o', str(exe)], check=True, env=env)
    subprocess.run([str(exe)], check=True, env=env)
