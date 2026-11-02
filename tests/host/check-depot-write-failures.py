#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Exercise production chunk retries, host health and POSIX writes on macOS.
Network/decryption are deterministic fixtures; real file errors must not retry
content downloads. No Steam account, CDN requests or installed game is used.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/SwiftSteam/Content/DepotDownloader.swift').read_text()

def block(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

helpers = '\n'.join(block(s) for s in (
    'private nonisolated static func fetchChunk(',
    'private nonisolated static func failureReason(',
    'private nonisolated static func write('))
health = block('final class ContentHostHealth:')
plan = block('struct DepotPlan:')
fixture = r'''
import Foundation
import Darwin

enum SteamError: Error { case chunkDownloadFailed(String), chunkDecodeFailed(String), checksumMismatch }
enum SteamLog { static func trace(_ text: String) {}; static func event(_ text: String) {} }
struct DepotManifest {
    struct ChunkEntry {
        var shaHex = "fixture"; var crc: UInt32 = 0
        var uncompressedSize: UInt32 = 16; var offset: UInt64 = 7
    }
}
enum ContentDecryptor {
    static func processChunk(encryptedData: Data, depotKey: Data, expectedCRC: UInt32, expectedSize: Int) throws -> Data {
        if encryptedData == Data([0xff]) { throw SteamError.chunkDecodeFailed("fixture") }
        return encryptedData
    }
}
'''
fixture += health + '\nenum Harness {\n' + plan + '\n' + helpers + r'''
    static var mode = "ok", downloads = 0
    static let payload = Data(repeating: 0x73, count: 16)
    private static func download(_ url: String) async throws -> Data {
        downloads += 1
        if mode == "cancel" { throw CancellationError() }
        if mode == "network-exhausted" { throw URLError(.timedOut) }
        if downloads == 1 {
            if mode == "network" { throw URLError(.timedOut) }
            if mode == "size" { return Data([1]) }
            if mode == "decode" { return Data([0xff]) }
        }
        return payload
    }
    static func fetch(_ path: String, _ health: ContentHostHealth) async throws {
        let plan = DepotPlan(depotID: 1, manifestGID: 1, key: Data(), manifest: DepotManifest(),
                             hosts: ["https://a", "https://b"], auth: [:], declaredSize: 16, health: health)
        try await fetchChunk(DepotManifest.ChunkEntry(), plan: plan, path: path, attempts: 3, seed: 0)
    }
}
@main struct Main {
    static func main() async throws {
        var failures = 0
        func check(_ ok: Bool, _ text: String) {
            print((ok ? "PASS " : "FAIL ") + text)
            if !ok { failures += 1 }
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        // The FIFO opens because its reader exists; pwrite then fails with ESPIPE.
        let fifo = tmp.appendingPathComponent("not-seekable")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        let reader = open(fifo.path, O_RDONLY | O_NONBLOCK)
        precondition(reader >= 0)
        defer { close(reader) }
        let badPaths = [(tmp.appendingPathComponent("missing/file").path, "Cannot open a game file (errno \(ENOENT))."),
                        (fifo.path, "Cannot write a game file (errno \(ESPIPE)).")]
        for (path, expectedError) in badPaths {
            Harness.mode = "ok"; Harness.downloads = 0
            let health = ContentHostHealth()
            var errorText = ""
            do { try await Harness.fetch(path, health) }
            catch SteamError.chunkDownloadFailed(let text) { errorText = text }
            check(errorText == expectedError, "original local-file error is returned")
            check(Harness.downloads == 1, "local file failure downloads the chunk once")
            check(health.order(["https://a", "https://b"], seed: 0) == ["https://a", "https://b"],
                  "local file failure does not demote a healthy CDN")
        }
        let file = tmp.appendingPathComponent("game.dat")
        for mode in ["ok", "network", "size", "decode", "cancel"] {
            try Data(repeating: 0, count: 32).write(to: file)
            Harness.mode = mode; Harness.downloads = 0
            let health = ContentHostHealth()
            var cancelled = false
            do { try await Harness.fetch(file.path, health) }
            catch is CancellationError { cancelled = true }
            let bytes = try Data(contentsOf: file)
            if mode == "cancel" {
                check(cancelled && Harness.downloads == 1 && bytes == Data(repeating: 0, count: 32),
                      "cancellation stops retries and leaves the file unchanged")
                check(health.order(["https://a", "https://b"], seed: 0).first == "https://a", "cancellation does not demote CDN")
            } else {
                var expected = Data(repeating: 0, count: 32)
                expected.replaceSubrange(7..<23, with: Harness.payload)
                check(!cancelled && bytes == expected, "\(mode): verified payload written at correct offset")
                check(Harness.downloads == (mode == "ok" ? 1 : 2), "\(mode): expected retry count")
            }
        }
        try Data(repeating: 0, count: 32).write(to: file)
        Harness.mode = "network-exhausted"; Harness.downloads = 0
        var failedNetwork = false
        do { try await Harness.fetch(file.path, ContentHostHealth()) }
        catch let error as URLError { failedNetwork = error.code == .timedOut }
        let unchanged = try Data(contentsOf: file)
        check(failedNetwork && Harness.downloads == 3 && unchanged == Data(repeating: 0, count: 32),
              "persistent network failure exhausts exactly three attempts without writing")
        if failures > 0 { exit(1) }
        print("ALL PASS: local I/O, network/decode/size retry, host health and cancellation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-depot-io-') as directory:
    src = Path(directory) / 'main.swift'
    exe = Path(directory) / 'test'
    src.write_text(fixture)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-swift-version', '5', '-parse-as-library', '-sanitize=address',
                    str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True, timeout=30)
