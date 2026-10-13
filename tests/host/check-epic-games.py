#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Akshay CM
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Host checks for the Epic Games library and downloads (docs/EPIC_GAMES.md).

Never contacts Epic. Needs swiftc (macOS: Compression and CryptoKit), python3,
and for the encrypted-build case `cryptography` or `pycryptodomex` (skipped
without either).

Part A is static: licence headers, every Epic source file in the Xcode project,
the Keychain item is device-only, no token or exchange code in a log line, the
bridge redacts -AUTH_PASSWORD, and the library keeps Epic games out of Other games.

Part B compiles the production EpicFormats.swift and EpicDownloader.swift with a
small driver, writes Epic build manifests and chunk files here (feature level 18
plain, and level 24 with an encrypted file list and encrypted chunks), serves
them from a local HTTP server with three base URLs (one dead, one that corrupts
the first answer for each chunk, one healthy) and checks:

* install: every file byte for byte, folders matched without case, empty files;
* resume: a cancelled install keeps its finished files and fetches less again;
* update: changed files rewritten, unchanged ones not fetched, removed ones deleted;
* repair: a damaged file is found by its SHA-1 and fetched again;
* JSON: an older JSON manifest (1 MiB version 2 chunks) parses and installs;
* hostile input: '..' paths, a truncated manifest and a wrong key throw.
"""
from pathlib import Path
import hashlib
import http.server
import json
import os
import random
import shutil
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import zlib

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
epic = app / 'SwiftEpic'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or 'swiftc'
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


# ------------------------------------------------------------------ Part A: static
sources = sorted(epic.glob('*.swift')) + [app / 'EpicLibrary.swift', app / 'EpicGames.swift']
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text()
for path in [p for p in sources if not p.exists()]:
    require(False, f'{path.name}: exists')
sources = [p for p in sources if p.exists()]
for path in sources:
    text = path.read_text()
    require(text.startswith('// SPDX-License-Identifier: GPL-3.0-or-later'), f'{path.name}: licence header')
    require(f'{path.name} in Sources' in project, f'{path.name}: in the Xcode project')
api = (epic / 'EpicAPI.swift').read_text()
require('kSecAttrAccessibleWhenUnlockedThisDeviceOnly' in api and 'kSecAttrSynchronizable' in api,
        'tokens: one device-only Keychain item, not synchronised')
for path in sources:
    for line in path.read_text().splitlines():
        if 'LogStore' in line or 'EpicLog' in line:
            bad = [w for w in ('accessToken', 'refreshToken', 'exchange)', 'code)', 'displayName', 'accountID') if '\\(' + w in line.replace(' ', '')]
            require(not bad, f'{path.name}: no credential in a log line: {line.strip()[:80]}') if bad else None
bridge = (app / 'WineProcessBridge.m').read_text()
require('-AUTH_PASSWORD=' in bridge and 'redacted' in bridge, 'the bridge redacts the exchange code in its argv log')
library = (app / 'Library.swift').read_text()
entries = library[library.index('private var entries: [LibraryEntry] {'):]
entries = entries[:entries.index('var body: some View {')]
require('$0.desktop != true && $0.steamAppID == nil && $0.epicAppName == nil' in entries,
        'Other games: no Epic game (it is listed in the Epic Games section)')
require('static func setTransientArguments(' in library and 'var epicAppName: String?' in library,
        'the sign-in arguments are transient, never part of the saved entry')

# ------------------------------------------------------------------ Part B: formats and downloads
try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    def gcm(key, nonce, plain):
        out = AESGCM(key).encrypt(nonce, plain, None)
        return out[:-16], out[-16:]
except ImportError:
    try:
        from Cryptodome.Cipher import AES

        def gcm(key, nonce, plain):
            return AES.new(key, AES.MODE_GCM, nonce=nonce).encrypt_and_digest(plain)
    except ImportError:
        gcm = None


def fstring(s):
    if not s:
        return struct.pack('<i', 0)
    try:
        return struct.pack('<i', len(s) + 1) + s.encode('ascii') + b'\0'
    except UnicodeEncodeError:
        return struct.pack('<i', -(len(s) + 1)) + s.encode('utf-16le') + b'\0\0'


def sized(payload):
    """A section whose first field is its own size."""
    return struct.pack('<I', len(payload) + 4) + payload


def b64(data):
    import base64
    return base64.urlsafe_b64encode(data).decode().rstrip('=')


WINDOW = 64 * 1024


class Build:
    """A build: files cut into fixed-size chunk windows, as Epic's chunker does."""

    def __init__(self, files, level=18, key=None, rng=None):
        self.files, self.level, self.key = files, level, key
        self.rng = rng or random.Random(1)
        self.chunks = {}     # guid tuple -> dict
        self.parts = {}      # file name -> [(guid, offset, size)]
        self.secret = (0x1111, 0x2222, 0x3333, 0x4444) if key else (0, 0, 0, 0)
        stream = b''.join(files.values())
        cut, by_offset = 0, []
        while cut < len(stream) or not by_offset:
            window = stream[cut:cut + WINDOW]
            guid = tuple(self.rng.getrandbits(32) for _ in range(4))
            group = zlib.crc32(struct.pack('<IIII', *guid)) % 100   # as Epic's CDN lays chunks out
            self.chunks[guid] = dict(data=window, hash=self.rng.getrandbits(64), group=group)
            by_offset.append((cut, guid, len(window)))
            cut += WINDOW
            if not window:
                break
        pos = 0
        for name, data in files.items():
            parts, start, end = [], pos, pos + len(data)
            for (offset, guid, size) in by_offset:
                lo, hi = max(start, offset), min(end, offset + size)
                if lo < hi:
                    parts.append((guid, lo - offset, hi - lo))
            self.parts[name] = parts
            pos = end

    def chunk_path(self, guid):
        c = self.chunks[guid]
        if self.level >= 22:
            secret = b64(struct.pack('<IIII', *self.secret)) if self.key else 'plain'
            return f'ChunksV5/{secret}/{c["group"]:02d}/{b64(struct.pack("<Q", c["hash"]))}_{b64(struct.pack("<IIII", *guid))}.chunk'
        folder = 'ChunksV4' if self.level >= 15 else 'ChunksV3'
        return f'{folder}/{c["group"]:02d}/{c["hash"]:016X}_{"".join(f"{g:08X}" for g in guid)}.chunk'

    def chunk_file(self, guid):
        c = self.chunks[guid]
        data = c['data']
        sha = hashlib.sha1(data).digest()
        payload, stored = zlib.compress(data), 1
        if self.key:
            payload, tag = gcm(self.key, sha[:12], payload)
            stored |= 2
            head = struct.pack('<IIII', 0xB1FE3AA2, 4, 98, len(payload)) + struct.pack('<IIII', *guid) + struct.pack('<QB', c['hash'], stored)
            head += sha + bytes([3]) + struct.pack('<I', len(data)) + struct.pack('<IIII', *self.secret) + tag
        else:
            head = struct.pack('<IIII', 0xB1FE3AA2, 3, 66, len(payload)) + struct.pack('<IIII', *guid) + struct.pack('<QB', c['hash'], stored)
            head += sha + bytes([3]) + struct.pack('<I', len(data))
        return head + payload

    def manifest(self, launch='Binaries/Win64/Game.exe', names=None):
        names = names or {n: n for n in self.files}
        guids = list(self.chunks)
        encrypted = self.key is not None
        meta = bytes([0]) + struct.pack('<I', self.level) + bytes([0]) + struct.pack('<I', 0)
        meta += fstring('TestApp') + fstring('1.0-' + str(len(self.files)))
        meta += fstring('' if encrypted else launch) + fstring('' if encrypted else '-nomovie')
        meta += struct.pack('<I', 0) + fstring('') + fstring('') + fstring('')
        cdl = bytes([0]) + struct.pack('<I', len(guids))
        cdl += b''.join(struct.pack('<IIII', *g) for g in guids)
        cdl += b''.join(struct.pack('<Q', self.chunks[g]['hash']) for g in guids)
        cdl += b''.join(hashlib.sha1(self.chunks[g]['data']).digest() for g in guids)
        cdl += bytes(self.chunks[g]['group'] for g in guids)
        cdl += b''.join(struct.pack('<I', len(self.chunks[g]['data'])) for g in guids)
        cdl += b''.join(struct.pack('<q', len(self.chunk_file(g))) for g in guids)
        if self.level >= 22:
            cdl += b''.join(struct.pack('<IIII', *self.secret) for g in guids)
            cdl += b''.join(struct.pack('<I', 0) for g in guids)
            cdl += b'\0' * 16 * len(guids)
        files = list(self.files)
        fml = bytes([0]) + struct.pack('<I', len(files))
        fml += b''.join(fstring('' if encrypted else names[f]) for f in files)
        fml += b''.join(fstring('') for f in files)
        fml += b''.join(hashlib.sha1(self.files[f]).digest() for f in files)
        fml += bytes(0 for f in files)
        fml += b''.join(struct.pack('<I', 0) for f in files)
        for f in files:
            fml += struct.pack('<I', len(self.parts[f]))
            for (guid, offset, size) in self.parts[f]:
                fml += struct.pack('<I', 28) + struct.pack('<IIII', *guid) + struct.pack('<II', offset, size)
        body = sized(meta) + sized(cdl) + sized(fml) + sized(bytes([0]) + struct.pack('<I', 0))
        tag = b''
        if encrypted:
            plain = fstring(launch) + fstring('-nomovie') + struct.pack('<I', 0) + fstring('') * 5
            plain += b''.join(fstring(names[f]) + fstring('') for f in files)
            iv = b'\x07' * 12
            cipher, tag = gcm(self.key, iv, plain)
            eh = sized(struct.pack('<IB', 1, 0) + struct.pack('<II', len(plain), len(plain)) + struct.pack('<I', len(iv)) + iv)
            block = eh + struct.pack('<I', len(cipher)) + cipher
            body += sized(bytes([0]) + struct.pack('<I', len(block) + 4) + block)
        packed = zlib.compress(body)
        stored = 1 | (2 if encrypted else 0)
        header_size = 41 + (32 if self.level >= 22 else 0)
        head = struct.pack('<IIII', 0x44BEC00C, header_size, len(body), len(packed)) + hashlib.sha1(body).digest()
        head += bytes([stored]) + struct.pack('<I', self.level)
        if self.level >= 22:
            head += struct.pack('<IIII', *self.secret) + (tag if encrypted else b'\0' * 16)
        return head + packed

    def secrets(self):
        return {''.join(f'{g:08X}' for g in self.secret): self.key.hex()} if self.key else {}


# A local CDN: /dead is never answered (connection refused on another port), /flaky
# corrupts the first answer for each chunk, /good serves every chunk.
served, hits, flaky_seen = {}, {}, set()
delay = [0.0]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        import time
        base, _, path = self.path.lstrip('/').partition('/')
        data = served.get(path)
        if data is None:
            self.send_response(404); self.end_headers(); return
        hits[path] = hits.get(path, 0) + 1
        if base == 'flaky' and path not in flaky_seen:
            flaky_seen.add(path)
            data = data[:40] + bytes(b ^ 0x5A for b in data[40:80]) + data[80:]
        if delay[0]:
            time.sleep(delay[0])
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


server = Server(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]
dead = socket_port = None
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1', 0)); dead = s.getsockname()[1]
BASES = f'http://127.0.0.1:{dead}/x,http://127.0.0.1:{port}/flaky,http://127.0.0.1:{port}/good'

DRIVER = r'''
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
func value(_ name: String) -> String? { args.firstIndex(of: name).map { args[$0 + 1] } }
let manifestData = try! Data(contentsOf: URL(fileURLWithPath: value("--manifest")!))
let secrets = (try? JSONDecoder().decode([String: String].self, from: Data((value("--secrets") ?? "{}").utf8))) ?? [:]
let mode = args[1]
func out(_ object: [String: Any]) { print(String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!) }
if mode == "parse" {
    do {
        let m = try EpicManifest.parse(manifestData, secrets: secrets)
        out(["ok": true, "level": m.featureLevel, "build": m.buildVersion, "exe": m.launchExe, "command": m.launchCommand,
             "files": m.files.map { $0.name }, "sizes": m.files.map { $0.size }, "chunks": m.chunks.count,
             "paths": m.chunks.values.map { $0.path }.sorted()])
    } catch { out(["ok": false, "error": "\(error)"]) }
    exit(0)
}
let previous = value("--previous").map { try! EpicManifest.parse(Data(contentsOf: URL(fileURLWithPath: $0)), secrets: secrets) }
let cancelAt = value("--cancel-at").flatMap(Double.init)
let done = DispatchSemaphore(value: 0)
final class Box: @unchecked Sendable { var task: Task<Void, Never>?; var firstFraction: Double? }
let box = Box()
box.task = Task {
    do {
        let manifest = try EpicManifest.parse(manifestData, secrets: secrets)
        let downloader = EpicDownloader()
        downloader.retryDelay = 0
        downloader.memoryBudget = Int(value("--budget") ?? "") ?? downloader.memoryBudget
        downloader.window = 4
        let result = try await downloader.install(manifest: manifest, baseURLs: value("--bases")!.split(separator: ",").map { URL(string: String($0))! },
            secrets: secrets, folder: URL(fileURLWithPath: value("--folder")!), previous: previous, verifyAll: args.contains("--verify"),
            journal: URL(fileURLWithPath: value("--journal")!)) { p in
                if p.phase == .downloading, box.firstFraction == nil { box.firstFraction = p.fraction }
                if let cancelAt, p.phase == .downloading, p.fraction >= cancelAt { box.task?.cancel() }
            }
        out(["ok": true, "written": result.filesWritten, "kept": result.filesKept, "fetched": result.bytesFetched, "size": result.installBytes,
             "first": box.firstFraction ?? -1])
    } catch is CancellationError {
        out(["ok": false, "cancelled": true])
    } catch {
        out(["ok": false, "error": "\(error)"])
    }
    done.signal()
}
done.wait()
'''

work = Path(tempfile.mkdtemp(prefix='epic-check-'))
try:
    (work / 'main.swift').write_text(DRIVER)
    exe = work / 'driver'
    build = subprocess.run([SWIFTC, '-swift-version', '5', '-O', '-o', str(exe), str(epic / 'EpicFormats.swift'),
                            str(epic / 'EpicDownloader.swift'), str(work / 'main.swift')], capture_output=True, text=True)
    require(build.returncode == 0, 'production EpicFormats.swift and EpicDownloader.swift compile' + ('' if build.returncode == 0 else ':\n' + build.stderr[-3000:]))
    if build.returncode != 0:
        sys.exit(1)

    def run(*extra, manifest, secrets=None):
        (work / 'm.bin').write_bytes(manifest)
        cmd = [str(exe), *extra, '--manifest', str(work / 'm.bin'), '--secrets', json.dumps(secrets or {})]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        try:
            return json.loads(proc.stdout.strip().splitlines()[-1])
        except Exception:
            return {'ok': False, 'error': proc.stdout + proc.stderr}

    def serve(b):
        served.clear(); flaky_seen.clear()
        for guid in b.chunks:
            served[b.chunk_path(guid)] = b.chunk_file(guid)

    def tree(folder):
        import unicodedata
        return {unicodedata.normalize('NFC', str(p.relative_to(folder))): p.read_bytes() for p in folder.rglob('*') if p.is_file()}

    rng = random.Random(7)

    def blob(n):
        return bytes(rng.getrandbits(8) for _ in range(n))

    files = {
        'Binaries/Win64/Game.exe': blob(150_000),
        'binaries/win64/engine.dll': blob(70_000),        # another spelling of the same folder
        'Content/Paks/data.pak': blob(300_000),
        'Content/empty.txt': b'',
        'Content/Movies/intro ü.bk2': blob(5_000),         # a UTF-16 name
        'readme.txt': b'hello epic\n' * 50,
    }

    for level, key in ((18, None), (24, bytes(range(32)))):
        if key and gcm is None:
            print('SKIP: encrypted build (no cryptography or pycryptodomex)')
            continue
        label = f'level {level}' + (' encrypted' if key else '')
        b = Build(files, level=level, key=key, rng=random.Random(level))
        manifest = b.manifest()
        parsed = run('parse', manifest=manifest, secrets=b.secrets())
        require(parsed.get('ok') and parsed['files'] == list(files) and parsed['exe'] == 'Binaries/Win64/Game.exe'
                and parsed['command'] == '-nomovie' and parsed['sizes'] == [len(v) for v in files.values()]
                and parsed['paths'] == sorted(b.chunk_path(g) for g in b.chunks), f'{label}: manifest parses ({parsed.get("error", "")[:200]})')
        serve(b)
        folder, journal = work / f'install{level}', work / f'j{level}/app.journal'
        res = run('install', '--bases', BASES, '--folder', str(folder), '--journal', str(journal), manifest=manifest, secrets=b.secrets())
        got = tree(folder)
        want = {'Binaries/Win64/Game.exe': files['Binaries/Win64/Game.exe'], 'Binaries/Win64/engine.dll': files['binaries/win64/engine.dll'],
                'Content/Paks/data.pak': files['Content/Paks/data.pak'], 'Content/empty.txt': b'',
                'Content/Movies/intro ü.bk2': files['Content/Movies/intro ü.bk2'], 'readme.txt': files['readme.txt']}
        require(res.get('ok') and got == want, f'{label}: install writes every file, folders matched without case ({res.get("error", "")[:300]}{"" if got == want else sorted(got)})')
        require(not journal.exists() and not any(p.name.endswith('.madeira-part') for p in folder.rglob('*')),
                f'{label}: no journal or temporary file after a complete install')
        if key:
            bad = run('parse', manifest=manifest, secrets={})
            require(not bad.get('ok') and 'missingKey' in bad.get('error', ''), f'{label}: no key, no manifest')
            wrong = run('parse', manifest=manifest, secrets={list(b.secrets())[0]: (b'\x01' * 32).hex()})
            require(not wrong.get('ok') and 'decrypt' in wrong.get('error', ''), f'{label}: a wrong key throws')

    # A JSON manifest (older builds; ported from willfaust/Madeira#207 by iediot, after
    # Legendary's json_manifest.py): blobs of three decimal digits per byte, little-endian,
    # GUID keys as four big-endian words, and 1 MiB chunk windows (the last one padded)
    # in version 2 chunk files, which do not store their window size.
    def jblob(data):
        return ''.join(f'{b:03d}' for b in data)

    def jnum(n, width):
        return jblob(n.to_bytes(width, 'little'))

    json_files = {
        'Engine/Binaries/Win64/Old.exe': blob(700_000),
        'Old/Content/data.pak': blob(900_000),
        'Old/empty.ini': b'',
    }
    jrng = random.Random(13)
    stream, jwindow = b''.join(json_files.values()), 1 << 20
    jchunks, jlist = {}, []
    for cut in range(0, len(stream), jwindow):
        guid = tuple(jrng.getrandbits(32) for _ in range(4))
        window = stream[cut:cut + jwindow].ljust(jwindow, b'\0')
        payload = zlib.compress(window)
        head = struct.pack('<IIII', 0xB1FE3AA2, 2, 62, len(payload)) + struct.pack('<IIII', *guid)
        head += struct.pack('<QB', jrng.getrandbits(64), 1) + hashlib.sha1(window).digest() + bytes([1])
        jchunks[guid] = dict(file=head + payload, window=window, hash=struct.unpack('<Q', head[36:44])[0],
                             group=zlib.crc32(struct.pack('<IIII', *guid)) % 100)
        jlist.append((cut, guid))
    jhex = lambda g: ''.join(f'{w:08X}' for w in g)
    jfml, pos = [], 0
    for name, data in json_files.items():
        parts = []
        for (cut, guid) in jlist:
            lo, hi = max(pos, cut), min(pos + len(data), cut + jwindow)
            if lo < hi:
                parts.append({'Guid': jhex(guid), 'Offset': jnum(lo - cut, 4), 'Size': jnum(hi - lo, 4)})
        jfml.append({'Filename': name, 'FileHash': jblob(hashlib.sha1(data).digest()), 'FileChunkParts': parts})
        pos += len(data)
    jmanifest = json.dumps({
        'ManifestFileVersion': jnum(13, 4), 'bIsFileData': False, 'AppID': jnum(0, 4), 'AppNameString': 'OldApp',
        'BuildVersionString': '1.0-json', 'LaunchExeString': 'Engine\\Binaries\\Win64\\Old.exe', 'LaunchCommand': '-old',
        'PrereqIds': [], 'PrereqName': '', 'PrereqPath': '', 'PrereqArgs': '', 'FileManifestList': jfml,
        'ChunkHashList': {jhex(g): jnum(c['hash'], 8) for g, c in jchunks.items()},
        'ChunkShaList': {jhex(g): hashlib.sha1(c['window']).hexdigest().upper() for g, c in jchunks.items()},
        'DataGroupList': {jhex(g): jnum(c['group'], 1) for g, c in jchunks.items()},
        'ChunkFilesizeList': {jhex(g): jnum(len(c['file']), 8) for g, c in jchunks.items()},
        'CustomFields': {},
    }, indent=1).encode()
    jpaths = {g: f'ChunksV3/{c["group"]:02d}/{c["hash"]:016X}_{jhex(g)}.chunk' for g, c in jchunks.items()}
    parsed = run('parse', manifest=b'\n ' + jmanifest)
    require(parsed.get('ok') and parsed['level'] == 13 and parsed['files'] == list(json_files) and parsed['build'] == '1.0-json'
            and parsed['exe'] == 'Engine\\Binaries\\Win64\\Old.exe' and parsed['command'] == '-old'
            and parsed['sizes'] == [len(v) for v in json_files.values()] and parsed['paths'] == sorted(jpaths.values()),
            f'JSON manifest parses ({parsed.get("error", "")[:200]})')
    served.clear(); flaky_seen.clear()
    for g, c in jchunks.items():
        served[jpaths[g]] = c['file']
    folder, journal = work / 'install-json', work / 'jjson/app.journal'
    res = run('install', '--bases', BASES, '--folder', str(folder), '--journal', str(journal), manifest=jmanifest)
    require(res.get('ok') and tree(folder) == json_files, f'JSON manifest: install writes every file ({res.get("error", "")[:300]})')
    bad_json = run('parse', manifest=jmanifest.replace(b'"FileHash": "', b'"FileHash": "9'))
    require(not bad_json.get('ok'), 'JSON manifest: a malformed blob throws')

    # Resume: cancel half-way, then continue.
    big = {f'Content/Paks/p{i}.pak': blob(200_000) for i in range(8)}
    b = Build(big, rng=random.Random(3))
    manifest = b.manifest(launch='p0.pak')
    serve(b)
    folder, journal = work / 'resume', work / 'jr/app.journal'
    delay[0] = 0.15
    first = run('install', '--bases', f'http://127.0.0.1:{port}/good', '--folder', str(folder), '--journal', str(journal), '--cancel-at', '0.3', manifest=manifest)
    delay[0] = 0
    require(first.get('cancelled') is True, 'resume: the install was cancelled')
    total_hits_before = sum(hits.get(b.chunk_path(g), 0) for g in b.chunks)
    second = run('install', '--bases', f'http://127.0.0.1:{port}/good', '--folder', str(folder), '--journal', str(journal), manifest=manifest)
    refetched = sum(hits.get(b.chunk_path(g), 0) for g in b.chunks) - total_hits_before
    require(second.get('ok') and second['kept'] > 0 and refetched < len(b.chunks) and tree(folder) == big,
            f'resume: finished files kept ({second.get("kept")}), {refetched} of {len(b.chunks)} chunks fetched again')
    require(second.get('first', -1) > 0.2, f'resume: progress continues where it stopped (first report {second.get("first")}), not from 0%')

    # Update: one file changed, one removed, one added; unchanged files are not fetched.
    old_build, old_manifest = b, manifest
    (work / 'old.bin').write_bytes(old_manifest)
    new_files = dict(big)
    new_files['Content/Paks/p1.pak'] = blob(120_000)
    del new_files['Content/Paks/p7.pak']
    new_files['Content/Paks/new.pak'] = blob(10_000)
    nb = Build(new_files, rng=random.Random(4))
    serve(nb)
    hits.clear()
    upd = run('install', '--bases', f'http://127.0.0.1:{port}/good', '--folder', str(folder), '--journal', str(journal),
              '--previous', str(work / 'old.bin'), manifest=nb.manifest(launch='p0.pak'))
    require(upd.get('ok') and tree(folder) == new_files, f'update: changed, removed and added files ({upd.get("error", "")[:200]})')
    # Every file's chunks differ between the two builds here (new GUIDs), so "kept" files fetch nothing:
    unchanged = [n for n in new_files if n in big and big[n] == new_files[n]]
    require(upd.get('kept') == len(unchanged) and upd.get('written') == len(new_files) - len(unchanged),
            f'update: {len(unchanged)} unchanged files kept without a download')

    # Repair: a damaged file is fetched again; budget 0 makes shared chunks spill to disk.
    target = folder / 'Content/Paks/p3.pak'
    damaged = bytearray(target.read_bytes()); damaged[1000] ^= 0xFF; target.write_bytes(bytes(damaged))
    rep = run('install', '--bases', f'http://127.0.0.1:{port}/good', '--folder', str(folder), '--journal', str(journal), '--verify',
              '--budget', '0', manifest=nb.manifest(launch='p0.pak'))
    require(rep.get('ok') and rep.get('written') == 1 and tree(folder) == new_files, 'repair: only the damaged file is written again')

    # Hostile input.
    evil = Build({'../escape.txt': b'x' * 10}, rng=random.Random(5))
    serve(evil)
    res = run('install', '--bases', f'http://127.0.0.1:{port}/good', '--folder', str(work / 'evil'), '--journal', str(work / 'je/j'), manifest=evil.manifest())
    require(not res.get('ok') and 'unsafePath' in res.get('error', '') and not (work / 'escape.txt').exists(), "a '..' path throws and writes nothing")
    trunc = run('parse', manifest=b.manifest()[:60])
    require(not trunc.get('ok'), 'a truncated manifest throws')
    garbage = run('parse', manifest=b'\x0c\xc0\xbeD' + bytes(rng.getrandbits(8) for _ in range(500)))
    require(not garbage.get('ok'), 'random bytes after the magic throw')
finally:
    server.shutdown()
    shutil.rmtree(work, ignore_errors=True)

print('FAILURES:', failures)
sys.exit(1 if failures else 0)
