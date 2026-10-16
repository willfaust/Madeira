#!/usr/bin/env python3
"""Compile the real Epic readers on macOS and exercise Legendary's wire layouts.
No account, CDN, iOS build, or third-party Python modules are needed.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import struct
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[2]
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc')


def u32(n):
    return struct.pack('<I', n)


def string(s):
    if not s:
        return u32(0)
    try:
        raw = s.encode('ascii')
        return u32(len(raw) + 1) + raw + b'\0'
    except UnicodeEncodeError:
        raw = s.encode('utf-16le')
        return struct.pack('<i', -(len(raw) // 2 + 1)) + raw + b'\0\0'


def section(data):
    return u32(len(data) + 4) + data


def blob(data):
    return ''.join(f'{b:03d}' for b in data)


def sha(data):
    return hashlib.sha1(data).digest()


guids = [(0x01234567, 0x89ABCDEF, 0x10203040, 0x50607080), (1, 2, 3, 4)]
guid_bytes = [struct.pack('<4I', *g) for g in guids]
guid_text = [''.join(f'{v:08X}' for v in g) for g in guids]
hashes = [0x1234567890ABCDEF, 0xFEDCBA0987654321]
payloads = [b'Epic chunk one' + bytes(1024 * 1024 - 14), b'Another chunk' + bytes(1024 * 1024 - 13)]
# Correct the first payload to exactly one legacy chunk window.
payloads[0] = b'Epic chunk one'.ljust(1024 * 1024, b'\0')


def chunk(index, version=3, compressed=True):
    data = payloads[index]
    wire = zlib.compress(data) if compressed else data
    header_size = {1: 41, 2: 62, 3: 66, 4: 98}[version]
    header = struct.pack('<4I', 0xB1FE3AA2, version, header_size, len(wire))
    header += guid_bytes[index] + struct.pack('<Q', hashes[index]) + bytes([int(compressed)])
    if version >= 2:
        header += sha(data) + b'\3'
    if version >= 3:
        header += u32(len(data))
    if version >= 4:
        header += bytes(32)
    return header + wire


chunks = [chunk(i) for i in range(2)]
file_data = payloads[1][2:9] + payloads[0][1:12]


def manifest(compressed=True, feature=18):
    meta = b'\2' + u32(feature) + b'\0' + u32(42)
    meta += b''.join(map(string, ['TestApp', '1.2.3', 'Bín/Game.exe', '-test']))
    meta += u32(1) + string('prereq-id')
    meta += b''.join(map(string, ['VC Runtime', 'Redist/setup.exe', '/quiet', 'build-id', '', '']))
    cdl = b'\0' + u32(2) + b''.join(guid_bytes)
    cdl += b''.join(struct.pack('<Q', v) for v in hashes)
    cdl += b''.join(map(sha, payloads)) + bytes([7, 42])
    cdl += u32(len(payloads[0])) + u32(len(payloads[1]))
    cdl += b''.join(struct.pack('<q', len(c)) for c in chunks)
    if feature >= 22:
        cdl += bytes(32) + u32(10) + u32(20) + bytes(32)
    fml = b'\2' + u32(2)
    fml += string('Bín/Game.exe') + string('empty.txt')
    fml += string('') + string('') + sha(file_data) + sha(b'') + b'\4\0'
    fml += u32(1) + string('optional-tag') + u32(0)
    fml += u32(2) + section(guid_bytes[1] + u32(2) + u32(7)) + section(guid_bytes[0] + u32(1) + u32(11))
    fml += u32(0) + u32(1) + hashlib.md5(file_data).digest() + u32(0)
    fml += string('application/octet-stream') + string('text/plain') + hashlib.sha256(file_data).digest() + hashlib.sha256(b'').digest()
    fields = b'\0' + u32(2) + string('InstallLocation') + string('hello') + string('Example') + string('world')
    body = section(meta) + section(cdl) + section(fml) + section(fields)
    wire = zlib.compress(body) if compressed else body
    header_size = 73 if feature >= 22 else 41
    header = struct.pack('<4I', 0x44BEC00C, header_size, len(body), len(wire)) + sha(body) + bytes([compressed]) + u32(feature)
    if feature >= 22:
        header += bytes(32)
    return header + wire


legacy = {
    'ManifestFileVersion': blob(u32(13)), 'bIsFileData': False,
    'AppNameString': 'TestApp', 'BuildVersionString': '1.2.3', 'LaunchExeString': 'Bín/Game.exe',
    'LaunchCommand': '-test', 'PrereqIds': ['prereq-id'], 'PrereqName': 'VC Runtime',
    'PrereqPath': 'Redist/setup.exe', 'PrereqArgs': '/quiet',
    'ChunkFilesizeList': {g: blob(struct.pack('<Q', len(c))) for g, c in zip(guid_text, chunks)},
    'ChunkHashList': {g: blob(struct.pack('<Q', h)) for g, h in zip(guid_text, hashes)},
    'ChunkShaList': {g: sha(p).hex() for g, p in zip(guid_text, payloads)},
    'DataGroupList': {g: blob(bytes([n])) for g, n in zip(guid_text, [7, 42])},
    'FileManifestList': [{'Filename': 'Bín/Game.exe', 'FileHash': blob(sha(file_data)),
                          'bIsUnixExecutable': True, 'InstallTags': ['optional-tag'], 'FileChunkParts': [
                              {'Guid': guid_text[1], 'Offset': blob(u32(2)), 'Size': blob(u32(7))},
                              {'Guid': guid_text[0], 'Offset': blob(u32(1)), 'Size': blob(u32(11))}]}],
    'CustomFields': {'InstallLocation': 'Example', 'hello': 'world'},
}

MAIN = r'''
import Foundation
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
func read(_ name: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(name)) }
var failures = 0
func check(_ condition: Bool, _ label: String) {
    print((condition ? "PASS: " : "FAIL: ") + label)
    if !condition { failures += 1 }
}
func rejects(_ label: String, _ operation: () throws -> Void) {
    do { try operation(); check(false, label) } catch { check(true, label) }
}
let expected = try read("file.bin")
let binary = try EpicManifest.parse(read("manifest.bin"))
for name in ["manifest.bin", "raw.bin", "legacy.json", "v5.bin"] {
    let m = try EpicManifest.parse(read(name))
    check(m.meta.appName == "TestApp" && m.meta.buildVersion == "1.2.3" && m.meta.launchExe == "Bín/Game.exe" && m.meta.launchCommand == "-test", name + " metadata / UTF-16")
    check(m.meta.prereqIDs == ["prereq-id"] && m.meta.prereqPath == "Redist/setup.exe" && m.meta.prereqArgs == "/quiet", name + " prerequisites")
    check(m.chunks.count == 2 && m.chunks.first(where: { $0.group == 7 })?.hash == 0x1234567890ABCDEF && m.chunks.first(where: { $0.group == 42 })?.hash == 0xFEDCBA0987654321, name + " columnar chunks")
    check(m.files[0].parts.count == 2 && m.files[0].size == 18 && m.files[0].flags == 4 && m.files[0].tags == ["optional-tag"], name + " file parts / tags")
    check(m.customFields == ["InstallLocation": "Example", "hello": "world"], name + " custom fields / section boundaries")
    var assembled = Data()
    for part in m.files[0].parts {
        let i = binary.chunks.firstIndex { $0.guid == part.guid }!
        let data = try EpicChunk.parse(read("chunk\(i).bin"), expected: m.chunks.first { $0.guid == part.guid }!)
        assembled.append(data.subdata(in: part.offset..<part.offset + part.size))
    }
    check(assembled == expected && EpicSHA1.hash(assembled) == m.files[0].sha, name + " verified chunk assembly")
}
check(try binary.chunks[0].path(featureLevel: 18) == "ChunksV4/07/1234567890ABCDEF_0123456789ABCDEF1020304050607080.chunk", "ChunksV4 URL")
check(try binary.chunks[0].path(featureLevel: 13).hasPrefix("ChunksV3/07/"), "ChunksV3 URL")
check(try binary.chunks[0].path(featureLevel: 22) == "ChunksV5/plain/07/782rkHhWNBI_Z0UjAe_Nq4lAMCAQgHBgUA.chunk", "ChunksV5 plain URL")
for version in 1...4 {
    for compressed in [false, true] {
        var expectedChunk = binary.chunks[0]
        let data = try read("v\(version)-\(compressed).chunk")
        expectedChunk.fileSize = data.count
        check(try EpicChunk.parse(data, expected: expectedChunk) == read("payload.bin"), "chunk header v\(version), compressed=\(compressed)")
    }
}
var hash = EpicSHA1()
for byte in expected { hash.update(Data([byte])) }
check(hash.finish() == EpicSHA1.hash(expected), "incremental SHA-1")
check(try EpicSHA1.file(folder.appendingPathComponent("payload.bin")) == EpicSHA1.hash(read("payload.bin")), "streamed file SHA-1")
check(EpicSHA1.hash(Data()).map { String(format: "%02x", $0) }.joined() == "da39a3ee5e6b4b0d3255bfef95601890afd80709", "SHA-1 empty known vector")
var damaged = try read("manifest.bin"); damaged[16] ^= 1
rejects("manifest hash mismatch") { _ = try EpicManifest.parse(damaged) }
var badChunk = try read("chunk0.bin"); badChunk[41] ^= 1
rejects("chunk hash mismatch") { _ = try EpicChunk.parse(badChunk) }
var encrypted = try read("manifest.bin"); encrypted[36] = 3
rejects("encrypted manifest fails explicitly") { _ = try EpicManifest.parse(encrypted) }
var wrong = binary.chunks[0]; wrong.guid = String(repeating: "0", count: 32)
rejects("chunk GUID mismatch") { _ = try EpicChunk.parse(read("chunk0.bin"), expected: wrong) }
let bytes = try read("raw.bin")
var truncatedAccepted = 0
for size in 0..<bytes.count {
    do { _ = try EpicManifest.parse(Data(bytes.prefix(size))); truncatedAccepted += 1 } catch {}
}
check(truncatedAccepted == 0, "every truncated binary prefix rejected without a crash")
var badJSON = try JSONSerialization.jsonObject(with: read("legacy.json")) as! [String: Any]
badJSON["ChunkHashList"] = [binary.chunks[0].guid: "999"]
rejects("malformed JSON byte blob") { _ = try EpicManifest.parse(JSONSerialization.data(withJSONObject: badJSON)) }
exit(failures == 0 ? 0 : 1)
'''


ASSEMBLY = r'''
import Foundation
struct SteamDownloadProgress: Sendable {
    enum Phase { case preparing, downloading, finishing }
    var phase: Phase = .preparing
    var totalBytes: UInt64 = 0, doneBytes: UInt64 = 0
    var bytesPerSecond: Double = 0
}
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()
    func log(_ line: String) { print(line) }
}
actor FetchCount {
    var count = 0
    func increment() { count += 1 }
    func reset() { count = 0 }
}
'''
ASSEMBLY_MAIN = r'''
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
let drive = fixtures.appendingPathComponent("drive_c")
let support = fixtures.appendingPathComponent("support")
private let worker = EpicInstallWorker(drive: drive, support: support)
let game = EpicGame(appName: "TestApp", title: "Test Game", namespace: "test", catalogItemId: "catalog")
let job = EpicInstaller.Pending(game: game, installDir: "Program Files/Epic Games/Test Game-test")
let manifest = try EpicManifest.parse(Data(contentsOf: fixtures.appendingPathComponent("manifest.bin")))
let root = drive.appendingPathComponent(job.installDir)
let target = root.appendingPathComponent("Bín/Game.exe")
let expected = try Data(contentsOf: fixtures.appendingPathComponent("file.bin"))
let count = FetchCount()
let fetch: @Sendable (URL, EpicManifest.Chunk) async throws -> Data = { url, chunk in
    await count.increment()
    let index = manifest.chunks.firstIndex { $0.guid == chunk.guid }!
    return try Data(contentsOf: fixtures.appendingPathComponent("chunk\(index).bin"))
}
let base = URL(string: "https://example.invalid/game")!
var failures = 0
func check(_ ok: Bool, _ label: String) {
    print((ok ? "PASS: " : "FAIL: ") + label)
    if !ok { failures += 1 }
}
let record = try await worker.assemble(job, manifest: manifest, base: base, fetch: { try await fetch($0, $1) }, progress: { _ in })
check(try Data(contentsOf: target) == expected, "installer assembles a verified file in manifest part order")
check(await count.count == 2, "installer fetches two chunks")
check(record.launchExe == "Bín/Game.exe" && record.launchCommand == "-test" && record.prereqPath == "Redist/setup.exe", "installer preserves launch and prerequisite metadata")
check(try Data(contentsOf: root.appendingPathComponent("empty.txt")).isEmpty, "installer creates verified empty files")
await count.reset()
_ = try await worker.assemble(job, manifest: manifest, base: base, fetch: { try await fetch($0, $1) }, progress: { _ in })
check(await count.count == 0, "resume hashes matching files and fetches nothing")
var corrupt = expected; corrupt[0] ^= 1
try corrupt.write(to: target)
_ = try await worker.assemble(job, manifest: manifest, base: base, fetch: { try await fetch($0, $1) }, progress: { _ in })
check(try await count.count == 2 && Data(contentsOf: target) == expected, "resume repairs same-size hash mismatches")
try await worker.save(EpicInstaller.Store(installed: [game.appName: record], pending: [:]))
check(try await worker.load().installed[game.appName]?.buildVersion == "1.2.3", "installed metadata round-trips through atomic JSON")
var invalid = manifest
invalid.files[0].sha = Data(repeating: 0, count: 20)
do {
    _ = try await worker.assemble(job, manifest: invalid, base: base, fetch: { try await fetch($0, $1) }, progress: { _ in })
    check(false, "file hash mismatch rejected")
} catch { check(true, "file hash mismatch rejected") }
check(try Data(contentsOf: target) == expected, "failed replacement preserves the prior file")
var traversal = manifest
traversal.files.append(EpicManifest.File(filename: "../escape", sha: EpicSHA1.hash(Data())))
do {
    _ = try await worker.assemble(job, manifest: traversal, base: base, fetch: { try await fetch($0, $1) }, progress: { _ in })
    check(false, "path traversal rejected")
} catch { check(true, "path traversal rejected") }
var duplicate = manifest
duplicate.files.append(manifest.files[0])
do {
    _ = try await worker.assemble(job, manifest: duplicate, base: base, fetch: { try await fetch($0, $1) }, progress: { _ in })
    check(false, "duplicate file path rejected")
} catch { check(true, "duplicate file path rejected") }
let outside = fixtures.appendingPathComponent("outside")
try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
var linked = manifest
linked.files.append(EpicManifest.File(filename: "linked/escape", sha: EpicSHA1.hash(Data())))
do {
    _ = try await worker.assemble(job, manifest: linked, base: base, fetch: { try await fetch($0, $1) }, progress: { _ in })
    check(false, "existing symlink rejected")
} catch { check(true, "existing symlink rejected") }
try FileManager.default.removeItem(at: target)
do {
    _ = try await worker.assemble(job, manifest: manifest, base: base,
                                 fetch: { _, _ in throw CancellationError() }, progress: { _ in })
    check(false, "interrupted chunk propagates cancellation")
} catch is CancellationError { check(true, "interrupted chunk propagates cancellation") }
check(!FileManager.default.fileExists(atPath: target.path), "interruption never publishes a partial file")
let staged = try FileManager.default.contentsOfDirectory(at: support.appendingPathComponent("Epic Staging"), includingPropertiesForKeys: nil)
check(staged.isEmpty, "failure and cancellation clean up staging")
_ = try await worker.assemble(job, manifest: manifest, base: base, fetch: { try await fetch($0, $1) }, progress: { _ in })
try await worker.remove(job.installDir)
check(!FileManager.default.fileExists(atPath: root.path) && FileManager.default.fileExists(atPath: outside.path), "uninstall removes only the managed game folder")
exit(failures == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix='madeira-epic-') as directory:
    folder = Path(directory)
    for name, data in [('manifest.bin', manifest()), ('raw.bin', manifest(False)), ('v5.bin', manifest(feature=22)),
                       ('legacy.json', json.dumps(legacy).encode()), ('file.bin', file_data), ('payload.bin', payloads[0])]:
        (folder / name).write_bytes(data)
    for i, data in enumerate(chunks):
        (folder / f'chunk{i}.bin').write_bytes(data)
    for version in range(1, 5):
        for compressed in [False, True]:
            (folder / f'v{version}-{str(compressed).lower()}.chunk').write_bytes(chunk(0, version, compressed))
    (folder / 'main.swift').write_text(MAIN)
    sources = [ROOT / 'app/Madeira/Epic' / f'{name}.swift' for name in ['EpicManifest', 'EpicChunk']]
    subprocess.run([SWIFTC, '-O', '-module-cache-path', str(folder / 'cache'), *map(str, sources),
                    str(folder / 'main.swift'), '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check'), str(folder)], check=True)
    installer = (ROOT / 'app/Madeira/Epic/EpicInstaller.swift').read_text()
    api = (ROOT / 'app/Madeira/Epic/EpicAPI.swift').read_text()
    game = api[api.index('struct EpicGame:'):api.index('private struct EpicLibraryResponse:')]
    record = installer[installer.index('struct EpicInstalledGame:'):installer.index('@MainActor final class EpicInstaller:')]
    store = installer[installer.index('    struct Pending:'):installer.index('    @Published private(set) var installs:')]
    worker = installer[installer.index('private actor EpicInstallWorker {'):]
    (folder / 'main.swift').write_text(ASSEMBLY + game + record + 'enum EpicInstaller {\n' + store + '}\n' + worker + ASSEMBLY_MAIN)
    subprocess.run([SWIFTC, '-O', '-module-cache-path', str(folder / 'cache'), *map(str, sources),
                    str(folder / 'main.swift'), '-o', str(folder / 'assembly')], check=True)
    subprocess.run([str(folder / 'assembly'), str(folder)], check=True)
print('ALL PASS')
