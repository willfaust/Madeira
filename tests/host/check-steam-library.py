#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Host checks for the owned Steam library and downloads (docs/STEAM_LIBRARY.md).

Never contacts Steam. It needs swiftc (Linux), cc, python3 with `cryptography`
or the openssl command, and libssl/liblzma/zlib development files.

Part A is static: licence headers, the Xcode project, no program names, the
only token path (SteamSignIn's Keychain item), no account data in a log line, no
engine or pool change, Info.plist permitting only the background download task,
and that the sources do not say they are
ports of another project.

Part B builds the production Swift (protocol messages, message codec, app-info
parsing, library fetcher, depot downloader, content decryptor, install record
writer, playtime) plus the production C decoders (liblzma shim, zstd educational
decoder, zip chunks) into one AddressSanitizer executable, with three small
stand-ins for Apple frameworks (CommonCrypto on OpenSSL, Compression, zlib) and a
scripted Steam connection (`SteamCMSession`), and runs it:

* units: the message and manifest formats, hostile input, the decrypt and
  decompress pipeline on known vectors, PICS parsing through the fetcher, and
  the install record;
* installs: the whole download against a local HTTP content server built here
  (three content-server hosts: one dead, one that corrupts the first answer for
  each chunk, one healthy; every chunk container Steam serves, AES with the depot
  key, encrypted file names, a shared depot, a depot the account does not own): an
  interrupted install resumes without fetching finished chunks, is not listed as
  installed until its record is written, and once written is found by Madeira
  Dock's own scanner (MadeiraDock.games); an update fetches only what changed and
  shrinks files; hostile manifest paths never leave the install folder.
"""
from pathlib import Path
import base64
import hashlib
import http.server
import io
import json
import lzma
import os
import random
import re
import shutil
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import zipfile
import zlib

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
steam = app / 'SwiftSteam'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
CC = os.environ.get('CC') or shutil.which('cc') or 'cc'
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def block(source, start_marker):
    start = source.index(start_marker)
    depth, i = 0, source.index('{', start)
    while True:
        c = source[i]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return source[start:i + 1] + '\n'
        i += 1


# ---------------------------------------------------------------- Part A
library_swift = [
    'SteamInstall.swift', 'SteamOwnedLibrary.swift', 'SteamDownloadBackground.swift', 'SteamGames.swift',
    'SwiftSteam/Core/CMServerList.swift', 'SwiftSteam/Core/LicenseListBox.swift', 'SwiftSteam/Core/SteamCMSession.swift',
    'SwiftSteam/Core/SteamConnection.swift', 'SwiftSteam/Core/SteamMessageCodec.swift', 'SwiftSteam/Core/SteamProtocol.swift',
    'SwiftSteam/Core/SteamSession.swift', 'SwiftSteam/Content/ContentDecryptor.swift', 'SwiftSteam/Content/DepotDownloader.swift',
    'SwiftSteam/Content/DepotManifest.swift', 'SwiftSteam/Content/SteamLANPeer.swift', 'SwiftSteam/Library/SteamAppInfo.swift',
    'SwiftSteam/Library/SteamLibraryFetcher.swift', 'SwiftSteam/Install/AppManifestWriter.swift']
c_files = ['SwiftSteam/chunk_zip.c', 'SwiftSteam/chunk_zip.h', 'SwiftSteam/lzma_shim.c', 'SwiftSteam/lzma_shim.h',
           'SwiftSteam/zstd_edu.c', 'SwiftSteam/zstd_edu.h']
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
sources = {p: (app / p).read_text() for p in library_swift}
for path, text in sources.items():
    head = text.split('\n', 3)
    require(head[0] == '// SPDX-License-Identifier: GPL-3.0-or-later' and head[1].startswith('// Copyright 2026 ')
            and head[2] == '// Madeira Converter Exception: see LICENSE-EXCEPTION.md', f'{path}: licence header')
    require(f'/* {path} in Sources */' in project, f'{path} is built by the Xcode project')
    if 'Jfishin' in head[1]:
        require("Jfishin's Madeira Steam client" in text.split('import ', 1)[0], f'{path} credits Jfishin')
for path in c_files:
    require(f'path = "{path}"' in project, f'{path} is in the Xcode project')
    if path.endswith('.c'):
        require(f'/* {path} in Sources */' in project, f'{path} is built by the Xcode project')
require('liblzma.tbd in Frameworks' in project, 'liblzma is linked (the system library; nothing is bundled)')
bridging = (app / 'Madeira-Bridging-Header.h').read_text()
require('#import "SwiftSteam/lzma_shim.h"' in bridging, 'the bridging header imports the decoders')
zstd = (steam / 'zstd_edu.c').read_text()
require('Copyright (c) Meta Platforms, Inc. and affiliates.' in zstd.split('\n', 3)[1] + zstd.split('\n', 3)[2] and
        'BSD-style license' in zstd[:600], "zstd_edu.c keeps Meta's notice")
require((root / 'LICENSES/ZSTD-BSD.txt').is_file(), 'the BSD licence text of the zstd decoder is in LICENSES/')
notices = (root / 'THIRD-PARTY-NOTICES.md').read_text()
require('zstd_edu.c' in notices and 'ZSTD-BSD.txt' in notices, 'THIRD-PARTY-NOTICES.md lists the zstd decoder and its licence text')

# The token path: SteamSignIn's Keychain item is the only one.
for path in ['SteamOwnedLibrary.swift', 'SteamGames.swift', 'SteamInstall.swift', 'SteamDownloadBackground.swift',
             'SwiftSteam/Core/SteamSession.swift', 'SwiftSteam/Core/SteamConnection.swift',
             'SwiftSteam/Content/DepotDownloader.swift', 'SwiftSteam/Library/SteamLibraryFetcher.swift']:
    text = sources[path]
    for word in ['SteamTokenStore', 'SecItem', 'kSecClass', 'saveTokens', 'clearTokens', 'loadTokens', 'UserDefaults', 'refreshToken']:
        if path == 'SwiftSteam/Core/SteamSession.swift' and word == 'refreshToken':
            continue  # it logs on with the token SteamSignIn hands out
        if path == 'SteamGames.swift' and word == 'UserDefaults':
            continue
        if path == 'SteamOwnedLibrary.swift' and word == 'UserDefaults':
            uses = [line.strip() for line in text.splitlines() if 'UserDefaults' in line]
            require(uses == [
                'private var targets: [Int: String] = (UserDefaults.standard.dictionary(forKey: "steam-install-targets") as? [String: String] ?? [:])',
                'UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: targets.map { (String($0.key), $0.value) }), forKey: Self.targetsKey)'],
                'UserDefaults holds only install destinations, never sign-in tokens')
            continue
        require(word not in text, f'{path}: no {word} (sign-in tokens stay in SteamSignIn)')
require('SteamSignIn.credentialsForDock()' in sources['SwiftSteam/Core/SteamSession.swift'],
        "the connection logs on with SteamSignIn's stored sign-in")
# No program names, no engine or pool code, no Windows client code.
for path in library_swift:
    text = sources[path]
    require(not re.findall(r'"[^"\n]*\.exe"', text), f'{path}: no program names')
    for word in ['helperNames', 'steamwebhelper', 'steam.exe', 'setenv(', 'unsetenv(', 'runWineFullSequence', 'MADEIRA_EXE',
                 'MADEIRA_ARGS', 'jit_', 'JITPool', 'poolSize', 'FEX_', 'DXMT', 'BGTaskScheduler', 'BGContinuedProcessing',
                 'UNUserNotificationCenter', 'SteamKit2', 'JavaSteam', 'DepotDownloader\'s', 'port of the DepotDownloader']:
        # Background downloads and their notifications live in one file (SteamDownloadBackground.swift).
        if path == 'SteamDownloadBackground.swift' and word in ('BGTaskScheduler', 'BGContinuedProcessing', 'UNUserNotificationCenter'):
            continue
        require(word not in text, f'{path}: no {word}')
    require(not re.search(r'\bml\d{3,4}\b', text), f'{path}: no build-round labels')
    for line in text.splitlines():
        if re.search(r'SteamLog\.(event|trace)|LogStore|print\(|NSLog|fputs', line):
            bad = re.search(r'\\\((account|accountName|name|token|password|signIn|refresh|steamID|steamid|path|folder)\b', line)
            require(bad is None, f'{path}: no account data or path in "{line.strip()[:70]}"')
require('MadeiraConfig' not in sources['SteamOwnedLibrary.swift'] and 'SteamSignIn.flag("MADEIRA_STEAM_LIBRARY", default: true)' in sources['SteamOwnedLibrary.swift'],
        'one switch, MADEIRA_STEAM_LIBRARY, on by default')
info = (app / 'Info.plist').read_text()
permitted = re.findall(r'<key>BGTaskSchedulerPermittedIdentifiers</key>\s*<array>(.*?)</array>', info, re.S)
require(len(permitted) == 1 and re.findall(r'<string>([^<]*)</string>', permitted[0])
        == ['$(PRODUCT_BUNDLE_IDENTIFIER).download.*', '$(PRODUCT_BUNDLE_IDENTIFIER).pairing.*'],
        "Info.plist permits only the bundle's own .download.* (background downloads) and .pairing.* (JIT pairing) tasks")
require('UIBackgroundModes' not in info, 'Info.plist asks for no background mode')
background = sources['SteamDownloadBackground.swift']
require('hasSuffix(".download.*")' in background and '+ suffix' in background and 'suffix: String = "queue"' in background and 'BGContinuedProcessingTaskRequest(identifier: identifier' in background,
        'the continued-processing task uses the permitted identifier, made concrete')
require('SteamSignIn.flag("MADEIRA_BACKGROUND_DOWNLOADS", default: true)' in background and
        'SteamSignIn.flag("MADEIRA_DOWNLOAD_NOTIFICATIONS", default: true)' in background,
        'background downloads and notifications each have a switch, on by default')
require('if #available(iOS 26.0, *), Self.continuedEnabled { submitContinued() }' in background and 'beginBackgroundTask(' in background
        and 'pauseForBackground()' in background, 'iOS 26 continues in the background; otherwise the grace period ends in a clean pause')
owned_text = sources['SteamOwnedLibrary.swift']
require('SteamDownloadBackground.shared.downloadStarted(appID: appID' in owned_text and 'SteamDownloadBackground.shared.progress(progress)' in owned_text
        and 'outcome: outcome, queueEmpty: queue.isEmpty)' in owned_text, 'every download reports its start, progress and outcome')
content_view = (app / 'ContentView.swift').read_text()
require(content_view.count('SteamOwnedLibrary.shared.sessionChanged(active: true)') == 1,
        'a session start pauses downloads and closes the Steam connection (one call, in runWineFullSequence)')
# Madeira Dock: the app's own connection is logged off (socket closed) before the one-use sign-in
# is written, and stays off until the Dock session ended (the ordering the gate test above runs).
dock_start = block(content_view, 'private func startDock(')
order = [dock_start.find(s) for s in ('await SteamOwnedLibrary.shared.prepareDock()', 'SteamSignIn.credentialsForDock()',
                                      'try MadeiraDock.writeHandoff(', 'runWineFullSequence(profile: profile)')]
require(-1 not in order and order == sorted(order),
        'Dock start: the app connection closes, then the sign-in is read and handed over, then the session starts')
require(dock_start.count('SteamSignIn.credentialsForDock()') == 1 and dock_start.count('MadeiraDock.writeHandoff(') == 1,
        'the sign-in is read and written once, after the connection closed')
require('SteamOwnedLibrary.shared.dockEnded()' in dock_start[:dock_start.index('Task { @MainActor in')],
        'a failed Dock start gives the connection back')
dock_view = (app / 'MadeiraDockView.swift').read_text()
watch = block(dock_view, 'func watchReport()')
require(watch.index('MadeiraDock.cleanup()') < watch.index('SteamOwnedLibrary.shared.dockEnded()'),
        "the connection may come back only when the Dock host's report or session is over")
owned_model = sources['SteamOwnedLibrary.swift']
prepare = block(owned_model, 'func prepareDock() async')
require(prepare.index('sessionChanged(active: true)') < prepare.index('await running?.value') < prepare.index('await gate.holdForDock()'),
        'prepareDock pauses downloads, waits for the running one, then waits for the connection to close')
changed = block(owned_model, 'func sessionChanged(active running: Bool)')
require('guard gate.reopen(sessionRunning: false) else { return }' in changed and 'gate.close()' in changed
        and 'session.resume()' not in changed and 'session.suspend()' not in changed,
        'a session ending reopens the connection only through the gate (never while Dock holds the account)')
session_source = sources['SwiftSteam/Core/SteamSession.swift']
suspend = block(session_source, 'func suspend() async')
require(suspend.index('isSuspended = true') < suspend.index('await disconnectGracefully()') < suspend.index('await connection.disconnect()'),
        'suspend: no reconnect from here on, log off, then wait for the socket to close')
require('if self.isSuspended {' in session_source and 'eMsg: .clientLogOff' in session_source[session_source.index('if self.isSuspended {'):],
        'a logon that completes after suspend() logs straight off again')
runtime = (app / 'SteamRuntime.swift').read_text()
relative_root = re.search(r'static let relativeRoot = "([^"]+)"', runtime).group(1)
require(sources['SteamInstall.swift'].count(f'"{relative_root}/steamapps"') == 1,
        "downloads go into Madeira Dock's own Steam library folder (SteamRuntimeFiles.relativeRoot + /steamapps)")
downloader = sources['SwiftSteam/Content/DepotDownloader.swift']
require('SteamLog.event("[steam-depot] install begin' in downloader and 'depot-key refused' in downloader, 'the download logs App IDs and depot IDs')
require(not re.search(r'LibraryFlags|MADEIRA_STEAM_[A-Z_]+', downloader), 'the downloader has no switches of its own')
require('app.installDepots(ownedDLC: ownedDLC)' in downloader and 'dlcAppID: dlcApps[plan.depotID]' in downloader,
        "installs take the account's owned DLC depots and record their DLC app")
dock = (app / 'MadeiraDock.swift').read_text()
require('static func validate(_ game: DockGame' in dock and 'game.installed' in dock, "Dock's validation reads the install record (StateFlags)")

if failures:
    print(f'check-steam-library: {failures} FAILED (static)')
    sys.exit(1)

# ---------------------------------------------------------------- fixtures (Python side)
try:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    def aes_ecb(key, data, decrypt=False):
        c = Cipher(algorithms.AES(key), modes.ECB())
        op = c.decryptor() if decrypt else c.encryptor()
        return op.update(data) + op.finalize()
    def aes_cbc_encrypt(key, iv, data):
        e = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
        return e.update(data) + e.finalize()
except ImportError:
    def _openssl(args, data):
        return subprocess.run(['openssl', 'enc'] + args, input=data, capture_output=True, check=True).stdout
    def aes_ecb(key, data, decrypt=False):
        return _openssl(['-aes-256-ecb', '-nopad', '-K', key.hex()] + (['-d'] if decrypt else []), data)
    def aes_cbc_encrypt(key, iv, data):
        return _openssl(['-aes-256-cbc', '-nopad', '-K', key.hex(), '-iv', iv.hex()], data)

rng = random.Random(20260928)


def pkcs7(data):
    n = 16 - len(data) % 16
    return data + bytes([n]) * n


def steam_encrypt(key, data, pad_nul=False):
    """Steam's symmetric scheme: the IV encrypted with the key in ECB mode, then AES-256-CBC (PKCS7) under that IV."""
    iv = rng.randbytes(16)
    return aes_ecb(key, iv) + aes_cbc_encrypt(key, iv, pkcs7(data))


def container(kind, data):
    """One of Steam's chunk containers around already-final bytes."""
    if kind == 'zstd':
        from compression import zstd
        frame = zstd.compress(data)
        # header: magic + crc32; footer (15 bytes): crc32 + decompressed size + 4 bytes + 'zsv'
        return b'VSZa' + struct.pack('<I', zlib.crc32(data)) + frame + struct.pack('<II', zlib.crc32(data), len(data)) + bytes(4) + b'zsv'
    if kind == 'lzma':
        raw = lzma.compress(data, format=lzma.FORMAT_ALONE, filters=[{'id': lzma.FILTER_LZMA1, 'dict_size': 1 << 20, 'lc': 3, 'lp': 0, 'pb': 2}])
        props, stream = raw[:5], raw[13:]
        return b'VZa' + struct.pack('<I', zlib.crc32(data)) + props + stream + struct.pack('<II', zlib.crc32(data), len(data)) + b'zv'
    if kind == 'zip':
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('z', data)
        return buffer.getvalue()
    raise ValueError(kind)


def adler(data):
    return zlib.adler32(data, 0) & 0xffffffff


def varint(v):
    out = bytearray()
    while v > 0x7f:
        out.append((v & 0x7f) | 0x80); v >>= 7
    out.append(v)
    return bytes(out)


def field(number, wire, payload):
    return varint(number << 3 | wire) + payload


def f_varint(n, v): return field(n, 0, varint(v))
def f_bytes(n, b): return field(n, 2, varint(len(b)) + b)
def f_fixed32(n, v): return field(n, 5, struct.pack('<I', v))


class Depot:
    """A synthetic depot: files, chunks (compressed, encrypted, checksummed) and the manifest that lists them."""
    def __init__(self, depot_id, key, entries, encrypt_names=True):
        self.id, self.key, self.entries = depot_id, key, entries
        self.chunks = {}     # sha hex -> served bytes
        self.files = []      # manifest order: dict(name, flags, size, chunks=[(sha, offset, ulen, clen, adler)], data)
        for entry in entries:
            name, flags = entry['name'], entry.get('flags', 0)
            data, pieces = entry.get('data', b''), []
            offset = 0
            for kind, length in entry.get('chunks', []):
                part = data[offset:offset + length]
                served = steam_encrypt(key, container(kind, part))
                sha = hashlib.sha1(part).digest()
                self.chunks[sha.hex()] = served
                pieces.append((sha, offset, len(part), len(served), adler(part)))
                offset += length
            self.files.append(dict(name=name, flags=flags, size=len(data), chunks=pieces, data=data))
        self.encrypt_names = encrypt_names

    def payload(self):
        out = b''
        for f in self.files:
            name = f['name'].encode()
            shown = base64.b64encode(steam_encrypt(self.key, name + b'\0')) if self.encrypt_names else name
            body = f_bytes(1, shown) + f_varint(2, f['size']) + f_varint(3, f['flags'])
            for sha, offset, ulen, clen, crc in f['chunks']:
                body += f_bytes(6, f_bytes(1, sha) + f_fixed32(2, crc) + f_varint(3, offset) + f_varint(4, ulen) + f_varint(5, clen))
            out += f_bytes(1, body)
        return out

    def manifest_zip(self):
        payload = self.payload()
        meta = f_varint(1, self.id)
        binary = (struct.pack('<II', 0x71F617D0, len(payload)) + payload + struct.pack('<II', 0x1F4812BE, len(meta)) + meta +
                  struct.pack('<II', 0x1B81B817, 0) + struct.pack('<I', 0x32C415AB))
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('z', binary)
        return buffer.getvalue(), binary

    def expected(self):
        """Path (as the downloader must fold it) -> content, for accepted regular files."""
        return {f['name'].replace('\\', '/'): f['data'] for f in self.files
                if f['flags'] & 0x40 == 0 and f['flags'] & 0x200 == 0 and f['chunks'] is not None}


def data(n, seed):
    r = random.Random(seed)
    a = n // 3
    return r.randbytes(a) + bytes(a) + (b'ab' * n)[:n - 2 * a]


KEY_MAIN, KEY_SHARED = rng.randbytes(32), rng.randbytes(32)
GAME_BIN = data(153333, 1)
ASSETS = data(82345, 2)
README = data(9000, 3)
NOTES = data(4321, 4)
CUSTOM = data(20000, 5)
EVIL = b'must never be written'


def main_depot(version):
    """Depot 9001. Version 2 changes one chunk of game.bin and shrinks the assets file."""
    game = GAME_BIN if version == 1 else GAME_BIN[:60000] + data(60000, 99) + GAME_BIN[120000:]
    assets = ASSETS if version == 1 else ASSETS[:70000]
    return Depot(9001, KEY_MAIN, [
        dict(name='bin', flags=0x40),
        dict(name='bin/game.bin', data=game, chunks=[('zstd', 60000), ('lzma', 60000), ('zip', 33333)]),
        dict(name='data\\Assets.dat', data=assets, chunks=[('lzma', 70000)] + ([('zstd', 12345)] if version == 1 else [])),
        dict(name='empty.txt', data=b''),
        dict(name='docs/Readme.TXT', data=README, chunks=[('zip', 9000)]),
        dict(name='Docs/notes.txt', data=NOTES, chunks=[('zstd', 4321)]),
        dict(name='..\\evil.txt', data=EVIL, chunks=[('zip', len(EVIL))]),
        dict(name='link', flags=0x200),
        dict(name='tool/custom.bin', flags=0x80, data=CUSTOM, chunks=[('lzma', 20000)]),
    ])


def shared_depot():
    return Depot(9003, KEY_SHARED, [dict(name='shared/lib.dat', data=data(30000, 6), chunks=[('zip', 30000)])])


# Known vectors for the decoders (independent of the depot above).
VEC_PLAIN = data(50000, 7)
VEC = {kind: steam_encrypt(KEY_MAIN, container(kind, VEC_PLAIN)).hex() for kind in ['zstd', 'lzma', 'zip']}
RAW = steam_encrypt(KEY_MAIN, VEC_PLAIN[:1000]).hex()


class ContentServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, mode, state):
        super().__init__(('127.0.0.1', 0), Handler)
        self.mode, self.state = mode, state
        self.corrupted = set()

    @property
    def url(self):
        return f'http://127.0.0.1:{self.server_address[1]}'


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.depots = {}          # depot id -> Depot
        self.manifests = {}       # (depot id, gid) -> zip bytes
        self.request_code = 424242
        self.auth = 'tok'
        self.limit = None         # chunks served OK before every chunk request fails
        self.served_ok = []       # (host mode, sha hex)
        self.chunk_requests = []  # sha hex, every request
        self.manifest_requests = []
        self.denied = 0
        self.refuse_manifests = False       # every manifest request answers 401
        self.refuse_first_manifest = False  # the first manifest request of each depot answers 401
        self.refused_once = set()

    def reset_counters(self):
        with self.lock:
            self.served_ok, self.chunk_requests, self.manifest_requests, self.denied = [], [], [], 0


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'
    def log_message(self, *args): pass

    def reply(self, status, body=b''):
        self.send_response(status); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        server, state = self.server, self.server.state
        path, _, query = self.path.partition('?')
        parts = path.strip('/').split('/')
        if server.mode == 'dead':
            return self.reply(503)
        if query != f'auth={state.auth}':
            with state.lock: state.denied += 1
            return self.reply(403)
        try:
            depot = int(parts[1])
            if parts[2] == 'manifest':
                gid, code = int(parts[3]), parts[5] if len(parts) > 5 else ''
                with state.lock:
                    state.manifest_requests.append((depot, gid))
                    if state.refuse_manifests:
                        return self.reply(401)
                    if state.refuse_first_manifest and depot not in state.refused_once:
                        state.refused_once.add(depot)
                        return self.reply(401)
                if parts[4] != '5' or code != str(state.request_code) or (depot, gid) not in state.manifests:
                    return self.reply(404)
                return self.reply(200, state.manifests[(depot, gid)])
            if parts[2] == 'chunk':
                sha = parts[3]
                with state.lock:
                    state.chunk_requests.append(sha)
                    if state.limit is not None and len(state.served_ok) >= state.limit:
                        return self.reply(404)
                blob = state.depots[depot].chunks.get(sha)
                if blob is None:
                    return self.reply(404)
                if server.mode == 'flaky' and sha not in server.corrupted:
                    server.corrupted.add(sha)
                    blob = blob[:40] + bytes([blob[40] ^ 0xff]) + blob[41:]
                    return self.reply(200, blob)
                with state.lock: state.served_ok.append((server.mode, sha))
                return self.reply(200, blob)
        except (ValueError, IndexError, KeyError):
            pass
        self.reply(404)


def serve(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return thread


# ---------------------------------------------------------------- Swift harness
CRYPTO_H = r'''
#ifndef cc_shim_h
#define cc_shim_h
#include <stddef.h>
#include <stdint.h>
typedef uint32_t CCOperation;
typedef uint32_t CCAlgorithm;
typedef uint32_t CCOptions;
typedef int32_t CCCryptorStatus;
typedef uint32_t CC_LONG;
enum { kCCEncrypt = 0, kCCDecrypt = 1 };
enum { kCCAlgorithmAES = 0 };
enum { kCCOptionPKCS7Padding = 1, kCCOptionECBMode = 2 };
enum { kCCSuccess = 0, kCCParamError = -4300, kCCBufferTooSmall = -4301, kCCDecodeError = -4304 };
enum { kCCBlockSizeAES128 = 16 };
#define CC_SHA1_DIGEST_LENGTH 20
CCCryptorStatus CCCrypt(CCOperation op, CCAlgorithm alg, CCOptions options, const void *key, size_t keyLength,
                        const void *iv, const void *dataIn, size_t dataInLength, void *dataOut,
                        size_t dataOutAvailable, size_t *dataOutMoved);
unsigned char *CC_SHA1(const void *data, CC_LONG len, unsigned char *md);
#endif
'''
CRYPTO_C = r'''
#include "cc_shim.h"
#include <openssl/evp.h>
#include <openssl/sha.h>
#include <string.h>
#include <stdlib.h>
CCCryptorStatus CCCrypt(CCOperation op, CCAlgorithm alg, CCOptions options, const void *key, size_t keyLength,
                        const void *iv, const void *dataIn, size_t dataInLength, void *dataOut,
                        size_t dataOutAvailable, size_t *dataOutMoved) {
    if (alg != kCCAlgorithmAES || keyLength != 32) return kCCParamError;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    const EVP_CIPHER *cipher = (options & kCCOptionECBMode) ? EVP_aes_256_ecb() : EVP_aes_256_cbc();
    if (!EVP_CipherInit_ex(ctx, cipher, NULL, key, (options & kCCOptionECBMode) ? NULL : iv, op == kCCEncrypt)) { EVP_CIPHER_CTX_free(ctx); return kCCParamError; }
    EVP_CIPHER_CTX_set_padding(ctx, (options & kCCOptionPKCS7Padding) ? 1 : 0);
    unsigned char *tmp = malloc(dataInLength + 32);
    int n1 = 0, n2 = 0;
    int ok = EVP_CipherUpdate(ctx, tmp, &n1, dataIn, (int)dataInLength) && EVP_CipherFinal_ex(ctx, tmp + n1, &n2);
    EVP_CIPHER_CTX_free(ctx);
    if (!ok) { free(tmp); return kCCDecodeError; }
    if ((size_t)(n1 + n2) > dataOutAvailable) { free(tmp); return kCCBufferTooSmall; }
    memcpy(dataOut, tmp, n1 + n2); *dataOutMoved = n1 + n2; free(tmp);
    return kCCSuccess;
}
unsigned char *CC_SHA1(const void *data, CC_LONG len, unsigned char *md) { return SHA1(data, len, md); }
'''
COMPRESSION_H = r'''
#ifndef compression_shim_h
#define compression_shim_h
#include <stddef.h>
#include <stdint.h>
typedef enum : uint32_t { COMPRESSION_LZMA = 0x306, COMPRESSION_ZLIB = 0x205 } compression_algorithm;
size_t compression_decode_buffer(uint8_t *dst, size_t dst_size, const uint8_t *src, size_t src_size, void *scratch, compression_algorithm algorithm);
#endif
'''
COMPRESSION_C = r'''
#include "compression_shim.h"
/* Not needed on the host: the bare-LZMA fallback is reported as not decoded. */
size_t compression_decode_buffer(uint8_t *dst, size_t dst_size, const uint8_t *src, size_t src_size, void *scratch, compression_algorithm algorithm) { return 0; }
'''
DECODERS_H = '#include "{app}/SwiftSteam/lzma_shim.h"\n'

STUBS = r'''
enum ExternalDrives { static var steamLibraries: [String] { [] } }
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

nonisolated(unsafe) var loggedEvents: [String] = []
enum SteamLog {
    static func trace(_ m: @autoclosure () -> String) {}
    static func event(_ m: String) { loggedEvents.append(m) }
}
enum SteamSignIn {
    static func flag(_ name: String, default fallback: Bool) -> Bool { getenv(name).map { String(cString: $0) != "0" } ?? fallback }
}
// madeira.cfg for SteamLanguage: the setting starts at English, whatever the host's locale.
nonisolated(unsafe) var configValues: [String: String] = ["env.MADEIRA_STEAM_LANGUAGE": "english"]
enum MadeiraConfig {
    static func get(_ key: String) -> String? { configValues[key] }
    @discardableResult static func set(_ key: String, _ value: String?) -> Bool { configValues[key] = value; return true }
}
enum SteamRuntimeFiles {
    static let relativeRoot = "RELATIVE_ROOT"
    static let windowsRoot = "C:\\Program Files (x86)\\Steam"
}
enum SteamOwnedLibrary {
    REASON
}
'''

CHECKS = r'''
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CommonCrypto
import zlib

nonisolated(unsafe) var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}
func hexData(_ s: String) -> Data {
    var data = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); data.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return data
}
func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)] }

/// A logged-on connection whose answers are scripted from the fixture.
@MainActor final class ScriptedSession: SteamCMSession {
    var cellID: UInt32 = 7
    var steamID: UInt64 = 76561197960265728 + 4242
    var licenses: [UInt32] = []
    var packageBuffers: [UInt32: Data] = [:]
    var appInfo: [UInt32: String] = [:]
    var keys: [UInt32: Data] = [:]
    var refused: Set<UInt32> = []
    var requestCode: UInt64 = 0
    var authToken = ""
    var keyRequests: [(depot: UInt32, app: UInt32)] = []
    var codeRequests: [(app: UInt32, depot: UInt32, gid: UInt64)] = []
    var authRequests: [(depot: UInt32, host: String, app: UInt32)] = []
    var picsAppRequests: [[UInt32]] = []
    var connects = 0
    /// Beta codes Steam accepts: code -> (branch, hex key) entries; private
    /// depot sections by "branch hexkey"; the branch each request code named.
    var betaCodes: [String: [(String, String)]] = [:]
    var privateSections: [String: Data] = [:]
    var branchRequests: [String] = []

    func ensureConnected() async throws { connects += 1 }
    func awaitLicenseList(timeout: TimeInterval) async throws -> [UInt32] { licenses }

    private func message(_ body: Data) -> SteamMessageCodec.IncomingMessage {
        SteamMessageCodec.IncomingMessage(eMsg: .multi, rawEMsg: 0, isProtobuf: true, header: CMsgProtoBufHeader(), body: body)
    }
    private func ids(_ data: Data, field: UInt32, sub: UInt32) throws -> [UInt32] {
        var d = ProtobufDecoder(data); var out: [UInt32] = []
        while let tag = try d.readTag() {
            if tag.fieldNumber == field, tag.wireType == .lengthDelimited {
                var s = ProtobufDecoder(try d.readBytes())
                while let t = try s.readTag() {
                    if t.fieldNumber == sub, t.wireType == .varint { out.append(UInt32(truncatingIfNeeded: try s.readVarint())) } else { try s.skip(wireType: t.wireType) }
                }
            } else { try d.skip(wireType: tag.wireType) }
        }
        return out
    }
    func sendAndWait(eMsg: EMsg, body: Data, responseEMsg: EMsg, timeout: TimeInterval) async throws -> SteamMessageCodec.IncomingMessage {
        var out = ProtobufEncoder()
        switch eMsg {
        case .clientPICSAccessTokenRequest:
            var d = ProtobufDecoder(body)
            var packages: [UInt32] = [], apps: [UInt32] = []
            while let tag = try d.readTag() {
                if tag.fieldNumber == 1 { packages.append(UInt32(truncatingIfNeeded: try d.readVarint())) }
                else if tag.fieldNumber == 2 { apps.append(UInt32(truncatingIfNeeded: try d.readVarint())) }
                else { try d.skip(wireType: tag.wireType) }
            }
            for p in packages { var t = ProtobufEncoder(); t.writeUInt32(fieldNumber: 1, value: p); t.writeUInt64(fieldNumber: 2, value: 1000 + UInt64(p)); out.writeSubmessage(fieldNumber: 1, value: t.data) }
            for a in apps { var t = ProtobufEncoder(); t.writeUInt32(fieldNumber: 1, value: a); t.writeUInt64(fieldNumber: 2, value: 2000 + UInt64(a)); out.writeSubmessage(fieldNumber: 3, value: t.data) }
        case .clientGetDepotDecryptionKey:
            var d = ProtobufDecoder(body); var depot: UInt32 = 0, app: UInt32 = 0
            while let tag = try d.readTag() {
                if tag.fieldNumber == 1 { depot = UInt32(truncatingIfNeeded: try d.readVarint()) }
                else if tag.fieldNumber == 2 { app = UInt32(truncatingIfNeeded: try d.readVarint()) }
                else { try d.skip(wireType: tag.wireType) }
            }
            keyRequests.append((depot, app))
            if let key = keys[depot], !refused.contains(depot) {
                out.writeInt32(fieldNumber: 1, value: 1); out.writeUInt32(fieldNumber: 2, value: depot); out.writeBytes(fieldNumber: 3, value: key)
            } else {
                out.writeInt32(fieldNumber: 1, value: 15); out.writeUInt32(fieldNumber: 2, value: depot)
            }
        case .clientCheckAppBetaPassword:
            var d = ProtobufDecoder(body); var code = ""
            while let tag = try d.readTag() {
                if tag.fieldNumber == 2 { code = try d.readString() } else { try d.skip(wireType: tag.wireType) }
            }
            out.writeInt32(fieldNumber: 1, value: 1)
            for (name, hex) in betaCodes[code] ?? [] {
                var entry = ProtobufEncoder(); entry.writeString(fieldNumber: 1, value: name); entry.writeString(fieldNumber: 2, value: hex)
                out.writeSubmessage(fieldNumber: 4, value: entry.data)
            }
        case .clientPICSPrivateBetaRequest:
            var d = ProtobufDecoder(body); var name = "", key = Data(), token: UInt64 = 0
            while let tag = try d.readTag() {
                if tag.fieldNumber == 2 { token = try d.readVarint() }
                else if tag.fieldNumber == 3 { name = try d.readString() }
                else if tag.fieldNumber == 4 { key = try d.readBytes() }
                else { try d.skip(wireType: tag.wireType) }
            }
            if token > 0, let section = privateSections[name + " " + key.map { String(format: "%02x", $0) }.joined()] {
                out.writeInt32(fieldNumber: 1, value: 1); out.writeBytes(fieldNumber: 2, value: section)
            } else {
                out.writeInt32(fieldNumber: 1, value: 15)
            }
        default: throw SteamError.invalidMessage
        }
        return message(out.data)
    }
    func sendAndWaitPICS(eMsg: EMsg, body: Data, timeout: TimeInterval) async throws -> [SteamMessageCodec.IncomingMessage] {
        var out = ProtobufEncoder()
        let packages = try ids(body, field: 1, sub: 1), apps = try ids(body, field: 2, sub: 1)
        if !apps.isEmpty { picsAppRequests.append(apps) }
        for p in packages {
            var t = ProtobufEncoder(); t.writeUInt32(fieldNumber: 1, value: p); t.writeBytes(fieldNumber: 5, value: packageBuffers[p] ?? Data())
            out.writeSubmessage(fieldNumber: 3, value: t.data)
        }
        for a in apps {
            if let text = appInfo[a] {
                var t = ProtobufEncoder(); t.writeUInt32(fieldNumber: 1, value: a); t.writeBytes(fieldNumber: 5, value: Data(text.utf8))
                out.writeSubmessage(fieldNumber: 1, value: t.data)
            } else { out.writeUInt32(fieldNumber: 2, value: a) }
        }
        return [message(out.data)]
    }
    func callServiceMethod(method: SteamServiceMethod, body: Data, timeout: TimeInterval) async throws -> Data {
        var d = ProtobufDecoder(body); var out = ProtobufEncoder()
        switch method {
        case .getManifestRequestCode:
            var app: UInt32 = 0, depot: UInt32 = 0, gid: UInt64 = 0
            while let tag = try d.readTag() {
                if tag.fieldNumber == 1 { app = UInt32(truncatingIfNeeded: try d.readVarint()) }
                else if tag.fieldNumber == 2 { depot = UInt32(truncatingIfNeeded: try d.readVarint()) }
                else if tag.fieldNumber == 3 { gid = try d.readVarint() }
                else if tag.fieldNumber == 4 { branchRequests.append(try d.readString()) }
                else { try d.skip(wireType: tag.wireType) }
            }
            codeRequests.append((app, depot, gid))
            // The code is a fixed64 on the wire.
            out.writeFixed64(fieldNumber: 1, value: requestCode)
        case .getCDNAuthToken:
            var depot: UInt32 = 0, host = "", app: UInt32 = 0
            while let tag = try d.readTag() {
                if tag.fieldNumber == 1 { depot = UInt32(truncatingIfNeeded: try d.readVarint()) }
                else if tag.fieldNumber == 2 { host = try d.readString() }
                else if tag.fieldNumber == 3 { app = UInt32(truncatingIfNeeded: try d.readVarint()) }
                else { try d.skip(wireType: tag.wireType) }
            }
            authRequests.append((depot, host, app))
            out.writeString(fieldNumber: 1, value: authToken)
        default: throw SteamError.invalidMessage
        }
        return out.data
    }
}

func appVDF(_ body: String) -> Data { Data(("\"appinfo\" { " + body + " }").utf8) }
func packageBuffer(apps: [UInt32], depots: [UInt32]) -> Data {
    var pkg: [UInt8] = [0x00] + Array("appids".utf8) + [0]
    for (i, a) in apps.enumerated() { pkg += [0x02] + Array(String(i).utf8) + [0] + le(a) }
    pkg += [0x08, 0x00] + Array("depotids".utf8) + [0]
    for (i, d) in depots.enumerated() { pkg += [0x02] + Array(String(i).utf8) + [0] + le(d) }
    pkg += [0x08]
    return Data(pkg)
}

@MainActor func units(_ fx: [String: Any]) async throws {
    // ---- protobuf: hostile input throws instead of trapping
    var big = ProtobufDecoder(Data([0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]))
    _ = try? big.readTag()
    do { _ = try big.readBytes(); require(false, "an oversized length is rejected") } catch { require(error is SteamError, "an oversized length is rejected") }
    do { _ = try CMsgClientPICSProductInfoResponse.deserialize(from: Data([0x0a, 0x7f, 0x01])); require(false, "a truncated PICS response is rejected") }
    catch { require(error is SteamError, "a truncated PICS response is rejected") }

    // ---- message header and codec
    var header = CMsgProtoBufHeader()
    header.steamid = 0; header.clientSessionid = 0
    require(header.serialize() == Data([0x09, 0, 0, 0, 0, 0, 0, 0, 0, 0x10, 0]), "the header always carries steamid and session id, even when both are 0")
    header.steamid = 76561197960265729; header.clientSessionid = 33; header.jobidSource = 5; header.targetJobName = "Player.GetOwnedGames#1"
    let decodedHeader = try CMsgProtoBufHeader.deserialize(from: header.serialize())
    require(decodedHeader.steamid == header.steamid && decodedHeader.clientSessionid == 33 && decodedHeader.jobidSource == 5 &&
            decodedHeader.jobidTarget == UInt64.max && decodedHeader.targetJobName == "Player.GetOwnedGames#1", "header round trip")
    let wire = SteamMessageCodec.encodeClientMessage(eMsg: .clientHeartBeat, body: Data([1, 2, 3]), steamID: 9, sessionID: 4, jobID: 77)
    let back = try SteamMessageCodec.decode(wire)
    require(back.isProtobuf && back.eMsg == .clientHeartBeat && back.header.jobidSource == 77 && back.body == Data([1, 2, 3]), "protobuf message round trip")
    require(UInt32(littleEndian: wire.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) == EMsg.clientHeartBeat.masked, "the protobuf flag is set on the message type")
    var oldStyle = Data(le(EMsg.multi.rawValue)); oldStyle += Data(repeating: 0x11, count: 16); oldStyle += Data([9, 9])
    let old = try SteamMessageCodec.decode(oldStyle)
    require(!old.isProtobuf && old.header.jobidTarget == 0x1111111111111111 && old.body == Data([9, 9]), "old-style message with the simple header")
    for bad in [Data(), Data([1, 2]), Data(le(EMsg.multi.masked) + le(0xffffffff) + [1])] {
        do { _ = try SteamMessageCodec.decode(bad); require(false, "a truncated or hostile message is rejected (\(bad.count) bytes)") }
        catch { require(error as? SteamError == .invalidMessage, "a truncated or hostile message is rejected (\(bad.count) bytes)") }
    }

    // ---- logon and response messages
    var logon = CMsgClientLogon(); logon.accountName = "user"; logon.accessToken = "tok"; logon.machineName = "Device"
    var d = ProtobufDecoder(logon.serialize()); var seen: [UInt32: Int] = [:]
    while let tag = try d.readTag() { seen[tag.fieldNumber, default: 0] += 1; try d.skip(wireType: tag.wireType) }
    require(Set(seen.keys) == [1, 5, 6, 7, 8, 11, 50, 96, 102, 108], "the logon carries Valve's field numbers: \(seen.keys.sorted())")
    var resp = ProtobufEncoder(); resp.writeInt32(fieldNumber: 1, value: 1); resp.writeInt32(fieldNumber: 3, value: 45); resp.writeUInt32(fieldNumber: 7, value: 12)
    let logonResponse = try CMsgClientLogonResponse.deserialize(from: resp.data)
    require(logonResponse.eresult == 1 && logonResponse.heartbeatSeconds == 45 && logonResponse.cellID == 12, "logon response")
    var lic = ProtobufEncoder(); lic.writeInt32(fieldNumber: 1, value: 1)
    for p in [100, 200, 300] as [UInt32] { var l = ProtobufEncoder(); l.writeUInt32(fieldNumber: 1, value: p); lic.writeSubmessage(fieldNumber: 2, value: l.data) }
    let licenseList = try CMsgClientLicenseList.deserialize(from: lic.data)
    require(licenseList.licenses.map(\.packageID) == [100, 200, 300], "license list")
    var multi = ProtobufEncoder(); multi.writeUInt32(fieldNumber: 1, value: 7); multi.writeBytes(fieldNumber: 2, value: Data([1, 2]))
    let parsedMulti = try CMsgMulti.deserialize(from: multi.data)
    require(parsedMulti.sizeUnzipped == 7 && parsedMulti.messageBody == Data([1, 2]), "multi message")

    // ---- Steam's playtime record
    var games = ProtobufEncoder()
    for (app, minutes, last) in [(4242, 90, 1_700_000_000), (5000, 0, 0), (5001, 0, 1_600_000_000), (5002, 30, 0)] as [(UInt64, UInt64, UInt64)] {
        var g = ProtobufEncoder(); g.writeUInt64(fieldNumber: 1, value: app); g.writeUInt64(fieldNumber: 4, value: minutes); g.writeUInt64(fieldNumber: 11, value: last)
        games.writeSubmessage(fieldNumber: 2, value: g.data)
    }
    games.writeUInt32(fieldNumber: 1, value: 4)
    let playtime = try SteamPlaytime.parse(games.data)
    require(playtime.keys.sorted() == [4242, 5001, 5002], "playtime lists played or last-played apps only")
    require(playtime[4242]?.minutes == 90 && playtime[4242]?.lastPlayed == 1_700_000_000, "playtime and last played")
    require(playtime[4242]?.played == "1.5 hrs played" && playtime[5002]?.played == "30 min played" && SteamPlaytime(minutes: 1200, lastPlayed: 0).played == "20 hrs played",
            "playtime text")
    require(playtime[5001]?.played == nil && playtime[5001]?.lastPlayedText() != nil, "a game only last played has no playtime text")
    do { _ = try SteamPlaytime.parse(Data([0x12, 0x7f, 0x01])); require(false, "a truncated playtime record is rejected") }
    catch { require(error is SteamError, "a truncated playtime record is rejected") }

    // ---- the account between the app's connection and a game session (SteamConnectionGate)
    var events: [String] = []
    let gate = SteamConnectionGate(close: {
        events.append("logoff-sent")
        try? await Task.sleep(nanoseconds: 60_000_000)       // the socket takes a while to close
        events.append("socket-closed")
    }, reopen: { events.append("reopened") })
    require(gate.open && !gate.heldForDock, "the app's connection is open without a session")
    // Madeira Dock: the sign-in transfer is written only after holdForDock() returns.
    await gate.holdForDock()
    events.append("sign-in-transfer-written")
    require(events == ["logoff-sent", "socket-closed", "sign-in-transfer-written"],
            "Dock: the app's connection logs off and its socket closes before the sign-in is handed over: \(events)")
    // runWineFullSequence's own sessionChanged(true) after that closes nothing again.
    gate.close()
    await Task.yield()
    require(events.filter { $0 == "logoff-sent" }.count == 1, "closing again is a no-op")
    // Nothing reopens the connection while Dock holds the account, even with no session detected yet.
    require(!gate.reopen(sessionRunning: false) && !events.contains("reopened"),
            "while Dock holds the account the connection stays closed (no session seen yet)")
    gate.releaseDock()
    require(!gate.reopen(sessionRunning: true) && !events.contains("reopened"), "the Dock session still runs: still closed")
    require(gate.reopen(sessionRunning: false) && events.last == "reopened" && gate.open, "the session ended: the connection may come back")
    require(!gate.reopen(sessionRunning: false) && events.filter { $0 == "reopened" }.count == 1, "reopening is idempotent")
    // A session that starts while a close is under way: Dock waits for that same close.
    events.removeAll()
    let first = gate.close()
    await gate.holdForDock()
    events.append("sign-in-transfer-written")
    await first.value
    require(events == ["logoff-sent", "socket-closed", "sign-in-transfer-written"],
            "a Dock start during a session's close waits for that close: \(events)")
    gate.releaseDock(); gate.reopen(sessionRunning: false)

    // ---- app info: depot selection
    let full = appVDF(#"""
    "common" { "name" "Fixture" "type" "game" "oslist" "windows,macos" "library_assets_full" { "library_capsule" { "image" { "english" "cap/1.jpg" } } } "parent" "10" }
    "config" { "installdir" "Fixture Game" }
    "depots" {
      "101" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "1001" "size" "500" "download" "300" } } }
      "102" { "config" { "oslist" "windows" "language" "english" } "manifests" { "public" { "gid" "1002" "download" "40" } } }
      "103" { "config" { "oslist" "windows" "language" "german" } "manifests" { "public" { "gid" "1003" "download" "40" } } }
      "104" { "config" { "oslist" "windows" "osarch" "32" } "manifests" { "public" { "gid" "1004" "download" "70" } } }
      "105" { "config" { "oslist" "windows" "osarch" "64" } "manifests" { "public" { "gid" "1005" "download" "80" } } }
      "106" { "config" { "oslist" "windows" "lowviolence" "1" } "manifests" { "public" { "gid" "1006" } } }
      "107" { "dlcappid" "999" "manifests" { "public" { "gid" "1007" } } }
      "108" { "sharedinstall" "1" "manifests" { "public" { "gid" "1008" } } }
      "109" { "config" { "oslist" "windows" } }
      "110" { "config" { "oslist" "macos" } "manifests" { "public" { "gid" "1010" } } }
      "branches" { "public" { "buildid" "4242" } }
    }
    """#)
    let info = SteamAppInfo.parse(appID: 10, from: full)!
    require(info.type == .game, "PICS type names match without case")
    require(info.installDepots().map(\.depotID) == [101, 102, 105], "install depots: common, English, 64-bit only")
    require(info.downloadSize(for: "windows") == 420, "the download size counts only the selected depots")
    require(info.installSize(for: "windows") == 620, "the installed size: manifests.public.size, else the download figure")
    require(info.buildID == 4242 && info.installableOnWindows && info.installDir == "Fixture Game", "build id, install folder and Windows installability")
    require(info.libraryCapsule == "cap/1.jpg" && info.parentID == nil, "artwork name; a parent equal to itself is not kept")
    require(info.depotSelectionSummary().contains("103[-]lang") && info.depotSelectionSummary().contains("107[-]dlc"), "the selection log names the rule that left a depot out")
    require(info.installDepots(ownedDLC: [107]).map(\.depotID) == [101, 102, 105, 107] && info.installDepots(ownedDLC: [999]).map(\.depotID) == [101, 102, 105],
            "owned DLC depots are installed with the game (New Vegas's Courier's Stash); DLC the account lacks is not")
    require(info.depotSelectionSummary(ownedDLC: [107]).contains("107[-]sel"), "the selection log shows owned DLC as selected")

    // ---- download language (SteamLanguage): the setting, a game's own choice, the English fallback
    let languaged = SteamAppInfo.parse(appID: 11, from: appVDF(#"""
    "common" { "name" "Lang" "type" "game" "oslist" "windows" "supported_languages" { "english" { "supported" "true" } "german" { "supported" "true" "full_audio" "true" } "japanese" { "supported" "true" } "french" { "supported" "false" } } }
    "depots" {
      "301" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "3001" } } }
      "302" { "config" { "oslist" "windows" "language" "english" } "manifests" { "public" { "gid" "3002" } } }
      "303" { "config" { "oslist" "windows" "language" "german" } "manifests" { "public" { "gid" "3003" } } }
    }
    """#))!
    require(languaged.languages == ["english", "german", "japanese"], "supported languages from common.supported_languages, without unsupported ones")
    require(languaged.installDepots().map(\.depotID) == [301, 302] && languaged.gameLanguage == "english", "English by default")
    MadeiraConfig.set(SteamLanguage.configKey, "german")
    require(languaged.installDepots().map(\.depotID) == [301, 303] && languaged.gameLanguage == "german",
            "the setting picks the language-pack depots and the record's language")
    MadeiraConfig.set(SteamLanguage.configKey, "japanese")
    require(languaged.installDepots().map(\.depotID) == [301, 302] && languaged.depotLanguage == "english" && languaged.gameLanguage == "japanese",
            "a supported language without depots: English depots, and the record names the language")
    MadeiraConfig.set(SteamLanguage.configKey, "french")
    require(languaged.installDepots().map(\.depotID) == [301, 302] && languaged.gameLanguage == "english", "a language the game lacks falls back to English")
    SteamLanguage.chooseForGame(11, "german")
    require(languaged.installDepots().map(\.depotID) == [301, 303] && info.installDepots().map(\.depotID) == [101, 102, 105],
            "a game's own choice wins over the setting, for that game only")
    SteamLanguage.chooseForGame(11, nil)
    MadeiraConfig.set(SteamLanguage.configKey, "english")
    require(SteamLanguage.steamName(Locale(identifier: "ja_JP")) == "japanese" && SteamLanguage.steamName(Locale(identifier: "zh-Hant-TW")) == "tchinese"
            && SteamLanguage.steamName(Locale(identifier: "pt_BR")) == "brazilian" && SteamLanguage.steamName(Locale(identifier: "es_MX")) == "latam"
            && SteamLanguage.steamName(Locale(identifier: "ko_KR")) == "koreana", "device languages map to Steam API language names")
    let legacy = SteamAppInfo.parse(appID: 10, from: appVDF(#"""
    "common" { "name" "Old" "type" "Game" "oslist" "windows" } "config" { "installdir" "Old" }
    "depots" { "201" { "config" { "oslist" "windows" "osarch" "32" } "manifests" { "public" "2001" } } "202" { "manifests" { "public" "2002" } } }
    """#))!
    require(legacy.installDepots().map(\.depotID) == [201, 202], "32-bit-only apps fall back to 32-bit depots")
    let mac = SteamAppInfo.parse(appID: 10, from: appVDF(#""common" { "name" "Mac" "type" "Game" "oslist" "macos" } "depots" { "301" { "config" { "oslist" "macos" } "manifests" { "public" "3001" } } }"#))!
    require(!mac.installableOnWindows, "apps without a Windows build are not offered")
    let tool = SteamAppInfo.parse(appID: 10, from: appVDF(#""common" { "name" "Tool" "type" "Tool" } "depots" { "401" { "manifests" { "public" "4001" } } }"#))!
    require(!tool.installableOnWindows, "tools and redistributables are not offered")
    let huge = SteamAppInfo.parse(appID: 10, from: appVDF(#"""
    "common" { "name" "Huge" "type" "Game" "oslist" "windows" }
    "depots" { "501" { "manifests" { "public" { "gid" "1" "download" "18446744073709551615" } } } "502" { "manifests" { "public" { "gid" "2" "download" "5" } } } }
    """#))!
    require(huge.downloadSize(for: "windows") == UInt64.max, "size sums saturate")
    require(SteamAppInfo.parse(appID: 10, from: appVDF(#""common" { "type" "Game" }"#)) == nil, "app info without a name is dropped")
    let pkg = packageBuffer(apps: [7000], depots: [7001, 7002])
    require(VDFParser.parsePackageIDs(key: "depotids", from: pkg) == [7001, 7002] && VDFParser.parsePackageAppIDs(from: pkg) == [7000], "package app and depot ids")
    var owners: [UInt32: SteamAppInfo] = [:]
    owners[7100] = SteamAppInfo.parse(appID: 7100, from: appVDF(#""common" { "name" "Owner" "type" "Game" "oslist" "windows" } "depots" { "7109" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "5" "download" "9" } } } }"#))!
    var sharing = SteamAppInfo.parse(appID: 7200, from: appVDF(#""common" { "name" "User" "type" "Game" "oslist" "windows" } "depots" { "7109" { "depotfromapp" "7100" } "7201" { "manifests" { "public" "71" } } }"#))!
    require(sharing.depots.first { $0.depotID == 7109 }?.fromApp == 7100 && sharing.installDepots().map(\.depotID) == [7201], "a depot from another app has no manifest of its own")
    require(sharing.inheritDepots(from: owners) == 1 && sharing.installDepots().map(\.depotID) == [7109, 7201], "it inherits the owner's manifest")

    // ---- beta branches (SteamBranch): the list, a public beta, a password-protected one, the record
    var beta = SteamAppInfo.parse(appID: 9200, from: appVDF(#"""
    "common" { "name" "Beta" "type" "Game" "oslist" "windows" }
    "depots" {
      "9201" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "11" } "preview" { "gid" "12" } } }
      "9202" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "21" } } }
      "branches" { "public" { "buildid" "100" } "preview" { "buildid" "105" "description" "Next update" "timeupdated" "1700000000" }
                   "secret" { "buildid" "107" "pwdrequired" "1" } "bad name" { "buildid" "1" } }
    }
    """#))!
    let branchNames: [String] = beta.branches.map(\.name)
    let previewEntry: SteamAppInfo.Branch = beta.branches[1]
    require(branchNames == ["public", "preview", "secret"] && previewEntry.description == "Next update" && previewEntry.updated == 1_700_000_000,
            "branches: public first, the betas by name, a name Madeira cannot keep left out")
    require(beta.branches[2].passwordRequired && !previewEntry.passwordRequired, "a password-protected branch is marked")
    func gids(_ app: SteamAppInfo) -> [UInt64] { app.installDepots().compactMap { $0.manifestID(app.branch) } }
    require(beta.branch == "public" && gids(beta) == [11, 21] && beta.branchBuildID == 100, "public by default")
    beta.branch = "preview"
    require(gids(beta) == [12, 21] && beta.branchBuildID == 105, "a beta takes its own manifests, and the public one of a depot it does not change")
    require(beta.depots.first { $0.depotID == 9201 }!.hasOwnManifest("preview") && !beta.depots.first { $0.depotID == 9202 }!.hasOwnManifest("preview")
            && !beta.depots.first { $0.depotID == 9201 }!.hasOwnManifest("public"), "only a beta's own manifest is requested under its branch")
    // depots { 9201 { manifests { secret { gid "77" } } } 9203 { config { oslist "windows" } manifests { secret { gid <uint64 88> } } } }
    func kvKey(_ type: UInt8, _ name: String) -> [UInt8] { [type] + Array(name.utf8) + [0] }
    var section: [UInt8] = kvKey(0, "depots")
    for part: [UInt8] in [kvKey(0, "9201"), kvKey(0, "manifests"), kvKey(0, "secret"), kvKey(1, "gid"), Array("77".utf8), [0, 8, 8, 8],
                          kvKey(0, "9203"), kvKey(0, "config"), kvKey(1, "oslist"), Array("windows".utf8), [0, 8],
                          kvKey(0, "manifests"), kvKey(0, "secret"), kvKey(7, "gid"), [88, 0, 0, 0, 0, 0, 0, 0], [8, 8, 8], [8, 8]] {
        section += part
    }
    let parsed = VDFParser.parseBinaryVDF(from: Data(section))
    require(((((parsed["depots"] as? [String: Any])?["9203"] as? [String: Any])?["manifests"] as? [String: Any])?["secret"] as? [String: Any])?["gid"] as? String == "88",
            "binary KeyValues: sections, strings and 64-bit numbers as decimal text")
    for cut in [1, 5, 9, 20, section.count - 3] { _ = VDFParser.parseBinaryVDF(from: Data(section.prefix(cut))) }
    _ = VDFParser.parseBinaryVDF(from: Data(repeating: 0, count: 4096))
    require(true, "a cut or hostile binary KeyValues blob is read without trapping")
    let betaSession = ScriptedSession()
    betaSession.betaCodes["letmein"] = [("secret", "00ff10"), ("bad name", "01")]
    betaSession.privateSections["secret 00ff10"] = Data(section)
    let betaFetcher = SteamLibraryFetcher(session: betaSession)
    let opened = try await betaFetcher.checkBetaCode(appID: 9200, code: "letmein")
    let refusedCode = try await betaFetcher.checkBetaCode(appID: 9200, code: "nope")
    require(opened == ["secret": Data([0, 0xff, 0x10])] && refusedCode.isEmpty, "a beta code opens its private branches; a wrong one opens none")
    var locked = beta
    for code in [nil, "nope"] as [String?] {
        do {
            try await betaFetcher.applyBranch(&locked, branch: "secret", code: code)
            require(false, "a password-protected branch without an accepted code stops the install")
        } catch {
            require((error as? SteamError) == .betaCodeNeeded("secret"), "a password-protected branch without an accepted code stops the install")
        }
    }
    try await betaFetcher.applyBranch(&locked, branch: "secret", code: "letmein")
    require(locked.branch == "secret" && gids(locked) == [77, 21, 88] && locked.branchBuildID == 107,
            "the code's private depot section gives the branch's manifests, a depot only the branch has included")
    var gone = beta
    try await betaFetcher.applyBranch(&gone, branch: "removed", code: nil)
    require(gone.branch == "public" && gids(gone) == [11, 21], "a branch Steam no longer lists falls back to public")
    var preview = beta
    preview.branch = "public"
    try await betaFetcher.applyBranch(&preview, branch: "preview", code: nil)
    require(preview.branch == "preview" && gids(preview) == [12, 21], "a beta without a password needs no code")
    SteamBranch.choose("preview", for: 9200)
    require(SteamBranch.chosen(9200) == "preview" && SteamBranch.chosen(9201) == "public", "the choice is kept per game")
    SteamBranch.choose("bad name", for: 9200)
    require(SteamBranch.chosen(9200) == "preview", "a branch name Madeira cannot keep is not taken")
    SteamBranch.setCode("letmein", branches: ["secret"], for: 9200)
    SteamBranch.choose("secret", for: 9200)
    require(SteamBranch.code(9200) == "letmein" && SteamBranch.unlocked(9200) == ["secret"], "the code and the branches it opened are kept")
    SteamBranch.setCode(nil, branches: [], for: 9200)
    require(SteamBranch.code(9200) == nil && SteamBranch.unlocked(9200).isEmpty && SteamBranch.chosen(9200) == "public",
            "removing the code forgets it, and a chosen private branch goes back to public")
    let recordDir = FileManager.default.temporaryDirectory.appendingPathComponent("madeira-beta-record-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: recordDir) }
    try AppManifestWriter.writeManifest(appID: 9200, name: "Beta", installDir: "Beta", buildID: 107, steamID: 1,
                                        steamAppsPath: recordDir.path, installedDepots: [], betaKey: "secret")
    let betaRecord = try String(contentsOf: recordDir.appendingPathComponent("appmanifest_9200.acf"), encoding: .utf8)
    require(betaRecord.components(separatedBy: "\"BetaKey\"\t\t\"secret\"").count == 3 && SteamInstallFiles.betaKey(appID: 9200, steamApps: recordDir) == "secret",
            "a beta install names its branch in UserConfig and MountedConfig")
    try AppManifestWriter.writeManifest(appID: 9200, name: "Beta", installDir: "Beta", buildID: 100, steamID: 1,
                                        steamAppsPath: recordDir.path, installedDepots: [])
    let publicRecord = try String(contentsOf: recordDir.appendingPathComponent("appmanifest_9200.acf"), encoding: .utf8)
    require(!publicRecord.contains("BetaKey") && SteamInstallFiles.betaKey(appID: 9200, steamApps: recordDir) == nil, "a public install names no branch")

    // ---- decrypt and decompress the known vectors
    let key = hexData(fx["key"] as! String)
    let plainVector = hexData(fx["vectorPlain"] as! String)
    let vectors = fx["vectors"] as! [String: String]
    for kind in ["zstd", "lzma", "zip"] {
        let encrypted = hexData(vectors[kind]!)
        let out = try ContentDecryptor.processChunk(encryptedData: encrypted, depotKey: key, expectedCRC: ContentDecryptor.adler32(plainVector), expectedSize: plainVector.count)
        require(out == plainVector, "the \(kind) container decodes to the original bytes")
        do { _ = try ContentDecryptor.processChunk(encryptedData: encrypted, depotKey: key, expectedCRC: ContentDecryptor.adler32(plainVector) ^ 1, expectedSize: plainVector.count); require(false, "\(kind): a wrong checksum is rejected") }
        catch { require(error as? SteamError == .checksumMismatch, "\(kind): a wrong checksum is rejected") }
        // The decoded length is what the downloader compares with the manifest's size (it rejects a chunk that disagrees).
        do { let o = try ContentDecryptor.processChunk(encryptedData: encrypted, depotKey: key, expectedCRC: 0, expectedSize: plainVector.count + 1); require(o.count != plainVector.count + 1, "\(kind): a size that disagrees is visible in the decoded length") }
        catch { require(error is SteamError, "\(kind): a size that disagrees is rejected (\(error))") }
        var wrong = key; wrong[0] ^= 1
        do { let o = try ContentDecryptor.processChunk(encryptedData: encrypted, depotKey: wrong, expectedCRC: ContentDecryptor.adler32(plainVector), expectedSize: plainVector.count); require(o != plainVector, "\(kind): a wrong key does not decode") }
        catch { require(error is SteamError, "\(kind): a wrong key is rejected") }
        var cut = encrypted; cut.removeLast(40)
        do { let o = try ContentDecryptor.processChunk(encryptedData: cut, depotKey: key, expectedCRC: 0, expectedSize: plainVector.count); require(o != plainVector, "\(kind): a truncated chunk does not decode") }
        catch { require(error is SteamError, "\(kind): a truncated chunk is rejected") }
    }
    // Steam seeds Adler-32 with 0: for one byte b that is b | (b << 16).
    require(ContentDecryptor.adler32(Data([0x41])) == 0x00410041 && ContentDecryptor.adler32(Data()) == 0, "Steam's Adler-32 is seeded with 0")
    let raw = hexData(fx["rawEncrypted"] as! String)
    let decrypted = try ContentDecryptor.decryptChunk(encryptedData: raw, depotKey: key)
    require(decrypted == plainVector.prefix(1000), "AES: the IV is ECB-decrypted, the rest CBC with PKCS7")
    for count in [0, 16, 17, raw.count - 1] {
        do { _ = try ContentDecryptor.decryptChunk(encryptedData: Data(raw.prefix(count)), depotKey: key); require(false, "truncated AES payload rejected") }
        catch { require(true, "truncated AES payload rejected") }
    }
    do { _ = try ContentDecryptor.decryptChunk(encryptedData: raw, depotKey: Data(count: 16)); require(false, "a short depot key is rejected") }
    catch { require(error is SteamError, "a short depot key is rejected") }
    do { _ = try ContentDecryptor.decompressChunk(compressedData: Data("ZZZZ-not-a-container".utf8), expectedSize: 999); require(false, "an unknown container is rejected") }
    catch { require(error as? SteamError == .chunkDecodeFailed("ZZZZ"), "an unknown container is rejected and named by its tag (\(error))") }
    // A hostile footer size may not ask for a huge buffer; malformed zstd may not exit the process.
    var hostile = Data("VZa".utf8) + Data(count: 4) + Data([0x5d, 0, 0, 0, 1]) + Data(count: 30) + Data(le(0)) + Data(le(0xffffffff)) + Data("zv".utf8)
    do { _ = try ContentDecryptor.decompressChunk(compressedData: hostile, expectedSize: 0); require(false, "a hostile VZip size is rejected") }
    catch { require(error as? SteamError == .chunkDecodeFailed("vzip"), "a hostile VZip size is rejected") }
    hostile = Data("VSZa".utf8) + Data(count: 4) + Data([0x28, 0xb5, 0x2f, 0xfd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]) + Data(count: 30) + Data(count: 15)
    do { _ = try ContentDecryptor.decompressChunk(compressedData: hostile, expectedSize: 4096); require(false, "a malformed zstd frame is rejected") }
    catch { require(error as? SteamError == .chunkDecodeFailed("vzstd"), "a malformed zstd frame is rejected without ending the process") }
    let noSize = try? ContentDecryptor.decompressChunk(compressedData: Data("VSZa".utf8) + Data(count: 30), expectedSize: 0)
    require(noSize == nil, "zstd without a manifest size is rejected")

    // ---- manifest names and paths
    var folded: [String: String] = [:]
    require(SteamInstallFiles.safeRelativePath("Docs\\Readme.txt", folded: &folded) == "Docs/Readme.txt", "backslashes become separators")
    require(SteamInstallFiles.safeRelativePath("docs/notes.txt", folded: &folded) == "Docs/notes.txt", "a directory keeps the first spelling seen (Windows semantics)")
    for bad in ["../x", "a/../../x", "..\\x", "/abs", "a//b/../c", "C:\\x", "a/b:c", "", "a\u{01}b", String(repeating: "a/", count: 70) + "b"] {
        var f: [String: String] = [:]
        let result = SteamInstallFiles.safeRelativePath(bad, folded: &f)
        require(result == nil || !(result!.contains("..") || result!.hasPrefix("/") || result!.contains(":")), "a hostile manifest path stays inside the folder: \(bad.prefix(20).debugDescription) -> \(String(describing: result))")
    }
    require(SteamInstallFiles.safeFolderName("Fixture Game") == "Fixture Game" && SteamInstallFiles.safeFolderName("../../etc") == "etc" &&
            SteamInstallFiles.safeFolderName("a\\b\\Last") == "Last" && SteamInstallFiles.safeFolderName("..") == "app" && SteamInstallFiles.safeFolderName("") == "app" &&
            SteamInstallFiles.safeFolderName("c:") == "app", "install folders are one safe component")
    require(DepotDownloader.usableContentHost("cache1.steamcontent.com") && DepotDownloader.usableContentHost("a.b.akamaized.net") &&
            !DepotDownloader.usableContentHost("evil.example.com") && !DepotDownloader.usableContentHost("x.steamcontent.com:8080") &&
            !DepotDownloader.usableContentHost("a b.steamcontent.com") && !DepotDownloader.usableContentHost("lancache.steamcontent.com"), "content hosts are Valve's, on the standard port")
    let server: [String: Any] = ["https_support": "unavailable"]
    require(DepotDownloader.serverEligibility(server, appID: 1) == .noHTTPS &&
            DepotDownloader.serverEligibility(["use_as_proxy": true], appID: 1) == .other &&
            DepotDownloader.serverEligibility(["allowed_app_ids": [5]], appID: 1) == .other &&
            DepotDownloader.serverEligibility(["allowed_app_ids": [1], "https_support": "mandatory"], appID: 1) == .usable &&
            DepotDownloader.serverEligibility([:], appID: 1) == .usable, "content server eligibility")
    let health = ContentHostHealth()
    for _ in 0..<3 { health.recordFailure("https://bad", reason: "x") }
    require(health.order(["https://bad", "https://good"], seed: 0).first == "https://good", "a server that keeps failing moves to the back of the rotation")

    // ---- the library fetcher, through a scripted connection
    let session = ScriptedSession()
    session.licenses = [11, 12]
    session.packageBuffers = [11: packageBuffer(apps: [9500, 9501], depots: [9502]), 12: packageBuffer(apps: [9503], depots: [9504])]
    let gameVDF = { (name: String, type: String, os: String) in "\"appinfo\" { \"common\" { \"name\" \"\(name)\" \"type\" \"\(type)\" \"oslist\" \"\(os)\" } \"config\" { \"installdir\" \"\(name)\" } " +
        "\"depots\" { \"9999\" { \"config\" { \"oslist\" \"windows\" } \"manifests\" { \"public\" { \"gid\" \"1\" \"download\" \"5\" } } } } }" }
    session.appInfo = [9500: gameVDF("Alpha", "Game", "windows"), 9501: gameVDF("Soundtrack", "Music", "windows"), 9503: gameVDF("Mac Only", "Game", "macos")]
    let fetcher = SteamLibraryFetcher(session: session)
    let ownedApps = try await fetcher.fetchOwnedApps()
    require(ownedApps.map(\.appID).sorted() == [9500, 9503], "the owned library: games only, from the license list's packages (\(ownedApps.map(\.appID)))")
    require(ownedApps.filter(\.installableOnWindows).map(\.appID) == [9500], "and only what installs for Windows")
    require(session.picsAppRequests.flatMap { $0 }.sorted() == [9500, 9501, 9503], "product info was asked for every app of the packages")
    let licensedDepots = try await fetcher.ownedDepotIDs()
    require(licensedDepots == [9502, 9504], "depot ids of the licenses")
}

@MainActor func install(_ fx: [String: Any], phase: String) async throws {
    let tmp = URL(fileURLWithPath: fx["tmp"] as! String)
    let drive = tmp.appendingPathComponent("drive_c")
    let steamApps = SteamInstallPaths.steamApps(drive: drive)
    let hosts = fx["hosts"] as! [String]
    let session = ScriptedSession()
    session.keys = [9001: hexData(fx["key"] as! String), 9003: hexData(fx["keyShared"] as! String)]
    session.requestCode = UInt64(fx["requestCode"] as! Int)
    session.authToken = fx["auth"] as! String
    session.licenses = [21]
    session.packageBuffers = [21: packageBuffer(apps: [9000, 9100], depots: [9001, 9003])]
    let version = phase == "update" ? 2 : 1
    let gid = (fx["gid\(version)"] as! Int)
    let gidShared = fx["gidShared"] as! Int
    let build = version == 1 ? 1000 : 1001
    session.appInfo = [
        9000: "\"appinfo\" { \"common\" { \"name\" \"Fixture Game\" \"type\" \"Game\" \"oslist\" \"windows\" } \"config\" { \"installdir\" \"Fixture Game\" } " +
            "\"depots\" { " +
            "\"9001\" { \"config\" { \"oslist\" \"windows\" } \"manifests\" { \"public\" { \"gid\" \"\(gid)\" \"size\" \"1\" \"download\" \"1\" } } } " +
            "\"9002\" { \"config\" { \"oslist\" \"windows\" \"language\" \"german\" } \"manifests\" { \"public\" { \"gid\" \"222\" } } } " +
            "\"9003\" { \"config\" { \"oslist\" \"windows\" } \"depotfromapp\" \"9100\" } " +
            "\"9004\" { \"config\" { \"oslist\" \"windows\" } \"manifests\" { \"public\" { \"gid\" \"444\" } } } " +
            "\"branches\" { \"public\" { \"buildid\" \"\(build)\" } } } }",
        9100: "\"appinfo\" { \"common\" { \"name\" \"Fixture Base\" \"type\" \"Game\" \"oslist\" \"windows\" } \"config\" { \"installdir\" \"Fixture Game\" } " +
            "\"depots\" { \"9003\" { \"config\" { \"oslist\" \"windows\" } \"manifests\" { \"public\" { \"gid\" \"\(gidShared)\" \"download\" \"1\" } } } " +
            "\"branches\" { \"public\" { \"buildid\" \"7\" } } } }"]
    let fetcher = SteamLibraryFetcher(session: session)
    guard let app = try await fetcher.fetchInstallInfo(appID: 9000) else { require(false, "app info"); return }
    require(app.depots.first { $0.depotID == 9003 }?.publicManifestID == UInt64(gidShared), "the shared depot got its manifest from the owning app")
    require(app.sharedOwners[9100]?.installDir == "Fixture Game", "the owner of the shared depot is known for the record")
    let downloader = DepotDownloader(session: session)
    downloader.contentHosts = { _ in hosts }
    downloader.manifestCacheFolder = tmp.appendingPathComponent("manifest-cache")
    var lastProgress = SteamDownloadProgress()
    let licensed: Set<UInt32> = phase == "refused-licensed" ? [9001, 9003, 9004] : [9001, 9003]
    do {
        _ = try await downloader.install(app, steamApps: steamApps, ownedDepots: { licensed }) { lastProgress = $0 }
        print("RESULT install=ok")
    } catch {
        print("RESULT install=failed reason=\(SteamOwnedLibrary.reason(error))")
        require(phase == "interrupt" || phase == "refused-licensed" || phase == "refused", "install failed only where the phase expects it (\(error))")
        if phase == "refused-licensed" { require(error as? SteamError == .depotKeyNotFound(9004), "a refusal for a depot the account is licensed for fails the install") }
        if phase == "refused" {
            require(error as? SteamError == .contentRefused(401), "every server refusing the file list is reported as a refusal, not a broken download (\(error))")
            require(session.codeRequests.filter { $0.depot == 9001 }.count == 2, "a refused file list is asked for again with a fresh request code, once")
            require(loggedEvents.contains { $0.contains("[steam-depot] manifest refused app=9000 depot=9001 ") && $0.contains("retry=fresh-code") }
                    && loggedEvents.contains { $0.contains("[steam-depot] manifest refused app=9000 depot=9001 ") && $0.contains("retry=none") && $0.contains(":401") },
                    "the log says which depot every server refused, with what")
            require(!loggedEvents.contains { $0.contains("auth=") }, "no authorization token in the log")
        }
    }
    if phase == "token-refresh" {
        // dead, flaky (refused, asked again with new authorization), good (for the chunks).
        require(session.authRequests.filter { $0.depot == 9001 }.count >= 4, "a server that refuses the file list is asked again with fresh authorization: \(session.authRequests.filter { $0.depot == 9001 }.count)")
    }
    let found = MadeiraDock.games(drive: drive)
    print("RESULT listed=\(found.filter { $0.id == 9000 && $0.installed }.count)")
    if phase != "interrupt" && phase != "refused-licensed" && phase != "refused" {
        require(lastProgress.phase == .finishing && lastProgress.doneBytes == lastProgress.totalBytes && lastProgress.totalBytes > 0, "progress ends complete: \(lastProgress.doneBytes)/\(lastProgress.totalBytes)")
        // Keys are asked for with the app being installed; manifest codes and tokens with the app that owns the content.
        require(session.keyRequests.contains { $0.depot == 9001 && $0.app == 9000 } && session.keyRequests.contains { $0.depot == 9003 && $0.app == 9000 }, "depot keys are requested for the installed app")
        // A manifest fetched by an earlier phase comes from the cache, with no code request.
        let prepared = loggedEvents.first { $0.contains("[steam-depot] prepared app=9000 ") } ?? ""
        require(prepared.contains("manifests-ms=") && prepared.contains("files-ms=") && prepared.contains("files="), "the wait before the download is timed in the log")
        let fetchedShared = session.codeRequests.contains { $0.depot == 9003 }, fetchedMain = session.codeRequests.contains { $0.depot == 9001 }
        require((!fetchedShared || session.codeRequests.contains { $0.depot == 9003 && $0.app == 9100 }) && (!fetchedMain || session.codeRequests.contains { $0.depot == 9001 && $0.app == 9000 }),
                "manifest codes are requested for the app that owns the depot")
        require(prepared.contains("manifest-cached=\((fetchedShared ? 0 : 1) + (fetchedMain ? 0 : 1))/2"), "every manifest not asked for came from the cache: \(prepared)")
        if phase == "resume" { require(session.codeRequests.isEmpty, "a resumed install reads both file lists from the cache the interrupted one left") }
        if phase == "update" { require(fetchedMain && !fetchedShared, "an update fetches only the new build's file list; the unchanged depot's comes from the cache") }
        require(session.authRequests.contains { $0.depot == 9003 && $0.app == 9100 && $0.host == "127.0.0.1" }, "content authorization names the bare host name")
        require(!session.keyRequests.contains { $0.depot == 9002 }, "a depot for another language is never asked for")
        guard let game = found.first(where: { $0.id == 9000 }) else { require(false, "Madeira Dock's discovery finds the downloaded game"); return }
        require(game.installed && game.installDir == "Fixture Game" && game.library == "Program Files (x86)/Steam/steamapps" && game.name == "Fixture Game",
                "Madeira Dock's discovery finds the downloaded game as fully installed")
        require(game.customExecutables, "the record lists the per-user executables Valve's client prepares (CheckGuid)")
        require(SteamInstallPaths.isManaged(library: game.library), "it is in the library Madeira manages")
        do { try MadeiraDock.validate(game, drive: drive, bundled: true) ; require(false, "validate needs the client files") }
        catch { require(error.localizedDescription.contains("client"), "Dock's launch check passes the record and stops at the missing client files only") }
        require(SteamInstallFiles.buildID(appID: 9000, steamApps: steamApps) == build, "the record's build id")
        require(SteamInstallFiles.depots(appID: 9100, steamApps: steamApps).contains(9003)
                && SteamInstallFiles.buildID(appID: 9100, steamApps: steamApps) == 7,
                "the owning app has its own record for the shared depot, as Valve's client requires")
        let events = loggedEvents.joined(separator: "\n")
        require(!events.contains("Fixture") && !events.contains("7656119") && !events.contains("tok"), "no name, account or token in the log")
        require(events.contains("[steam-depot] license app=9000 skipped=9004"), "a depot the account neither has a key for nor a license for is left out")
    }
    if phase == "update" {
        require(SteamInstallFiles.buildID(appID: 9000, steamApps: steamApps) == 1001, "the update changed the recorded build")
        require(SteamInstallFiles.buildID(appID: 4242, steamApps: steamApps) == nil, "no record, no build")
        let ownedNow = SteamOwnedGame(app)
        require(ownedNow.buildID == 1001 && ownedNow.folderName == "Fixture Game", "the owned game carries the build")
    }
    if phase == "uninstall" {
        try SteamInstallFiles.delete(appID: 9000, folderName: "Fixture Game", steamApps: steamApps)
        require(MadeiraDock.games(drive: drive).isEmpty, "an uninstalled game is no longer found (its shared owner record went with it)")
        require(!FileManager.default.fileExists(atPath: steamApps.appendingPathComponent("appmanifest_9100.acf").path), "the shared owner record was removed")
        require(!FileManager.default.fileExists(atPath: steamApps.appendingPathComponent("common/Fixture Game").path), "its folder is gone")
        require(FileManager.default.fileExists(atPath: steamApps.appendingPathComponent("common").path) , "the common folder stays")
    }
}

@main struct Harness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        let args = CommandLine.arguments
        guard args.count >= 3, let raw = FileManager.default.contents(atPath: args[2]),
              let fx = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { print("FAIL: fixture"); exit(2) }
        do {
            if args[1] == "units" { try await units(fx) } else { try await install(fx, phase: args[1]) }
        } catch {
            print("FAIL: \(args[1]) threw \(error)"); failures += 1
        }
        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: \(args[1]) phase")
    }
}
'''



# ---------------------------------------------------------------- Part B driver
owned_source = sources['SteamOwnedLibrary.swift']
owned_game = owned_source[owned_source.index('struct SteamOwnedGame:'):owned_source.index('// MARK: - Playtime')]
playtime_source = owned_source[owned_source.index('// MARK: - Playtime'):owned_source.index('// MARK: - Model')]
reason = block(owned_source, 'static func reason(_ error: Error) -> String')
dock_head = dock[dock.index('enum DockPerformancePolicy {'):dock.index('enum MadeiraDock {')]
dock_body = (dock[dock.index('enum MadeiraDock {'):dock.index('    @MainActor private static var lastReport =')] +
             dock[dock.index("    /// The host's environment for one launch."):])
# URLSession lives in FoundationNetworking on Linux; the production file imports Foundation only.
downloader_host = downloader.replace('import Foundation\n', 'import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n', 1)
# Linux has no Darwin volume keys or statfs layout. Unknown capacity remains allowed.
if sys.platform != 'darwin':
    space = block(downloader_host, 'public var freeSpace: Int64?')
    downloader_host = downloader_host.replace(space, 'public var freeSpace: Int64? { nil }\n')
    # F_NOCACHE and F_RDAHEAD are Darwin's fcntl read hints; Linux reads the same bytes without them.
    for hint in ('        _ = fcntl(fd, F_NOCACHE, 1)\n', '        _ = fcntl(fd, F_RDAHEAD, 1)\n'):
        downloader_host = downloader_host.replace(hint, '')
    # swift-corelibs-foundation's URLSession.data(from:) sometimes never returns once its task
    # is cancelled (the interrupt phase hung about one run in four), where Apple's throws
    # URLError.cancelled. Fetch outside the group's cancellation; the sibling chunks still
    # stop at their next cancellation check.
    downloader_host = downloader_host.replace(
        '        let (data, response) = try await http.data(from: url)\n',
        '        let (data, response) = try await Task.detached { try await http.data(from: url) }.value\n', 1)
fetcher_source = sources['SwiftSteam/Library/SteamLibraryFetcher.swift']
require('encoder.writeString(fieldNumber: 4, value: branch)' in downloader and 'branch: depot.hasOwnManifest(app.branch) ? app.branch : nil' in downloader
        and 'buildID: app.branchBuildID' in downloader and 'betaKey: app.branch' in downloader,
        "a beta download asks for its manifests under the branch and records the branch's build and BetaKey")
require('try await fetcher.applyBranch(&info, branch: SteamBranch.chosen(appID), code: SteamBranch.code(appID))' in owned_source,
        "every download takes the version chosen on the game's page")

work = Path(tempfile.mkdtemp(prefix='madeira-steam-library-'))
servers = []
try:
    shim = work / 'shim'
    shim.mkdir()
    native = sys.platform == 'darwin'
    modules = []
    for name, header, csource in ([] if native else [('CommonCrypto', CRYPTO_H, CRYPTO_C), ('Compression', COMPRESSION_H, COMPRESSION_C)]):
        directory = shim / name
        directory.mkdir(parents=True)
        stem = 'cc_shim' if name == 'CommonCrypto' else 'compression_shim'
        (directory / f'{stem}.h').write_text(header)
        (directory / f'{stem}.c').write_text(csource)
        (directory / 'module.modulemap').write_text(f'module {name} [system] {{ header "{stem}.h" export * }}\n')
        modules += ['-I', str(directory)]
    if not native:
        (shim / 'zlib').mkdir()
        (shim / 'zlib/module.modulemap').write_text('module zlib [system] { header "/usr/include/zlib.h" link "z" export * }\n')
        modules += ['-I', str(shim / 'zlib')]
    (work / 'decoders.h').write_text(DECODERS_H.format(app=app))

    objects = []
    def compile_c(source, extra=()):
        obj = work / (Path(source).stem + '.o')
        result = subprocess.run([CC, '-c', '-g', '-fsanitize=address', '-w', str(source), '-o', str(obj)] + list(extra), capture_output=True, text=True)
        require(result.returncode == 0, f'{Path(source).name} compiles on the host')
        if result.returncode: sys.stdout.write(result.stderr[-3000:])
        objects.append(str(obj))
    if not native:
        compile_c(shim / 'CommonCrypto/cc_shim.c', ['-I', str(shim / 'CommonCrypto')])
        compile_c(shim / 'Compression/compression_shim.c', ['-I', str(shim / 'Compression')])
    for name in ['zstd_edu.c', 'lzma_shim.c', 'chunk_zip.c']:
        compile_c(steam / name)

    (work / 'stubs.swift').write_text(STUBS.replace('RELATIVE_ROOT', relative_root).replace('REASON', reason))
    (work / 'checks.swift').write_text(CHECKS)
    (work / 'dock.swift').write_text(('import Foundation\n#if canImport(Glibc)\nimport Glibc\n#else\nimport Darwin\n#endif\n'
        '#if canImport(Network)\nimport Network\n#else\n'
        '/* Linux: no Network framework; DockOffline only needs these names. */\n'
        'final class NWPathMonitor { struct Path { enum Status { case satisfied, unsatisfied, requiresConnection }; '
        'var status = Status.satisfied }; var currentPath = Path(); func start(queue: DispatchQueue) {} }\n#endif\n') + dock_head + dock_body)
    (work / 'owned.swift').write_text('import Foundation\n' + owned_game + playtime_source)
    (work / 'downloader.swift').write_text(downloader_host)
    production = [steam / 'Proto/SteamProtoMessages.swift', steam / 'Core/SteamError.swift', steam / 'Core/SteamProtocol.swift',
                  steam / 'Core/SteamMessageCodec.swift', steam / 'Core/SteamCMSession.swift',
                  steam / 'Content/ContentDecryptor.swift', steam / 'Content/DepotManifest.swift', steam / 'Content/SteamLANPeer.swift',
                  steam / 'Library/SteamAppInfo.swift', steam / 'Library/SteamLibraryFetcher.swift',
                  steam / 'Install/AppManifestWriter.swift', app / 'SteamInstall.swift', app / 'SteamKeyValues.swift', app / 'ExternalStorage.swift']
    exe = work / 'check'
    build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-g', '-o', str(exe),
                            '-import-objc-header', str(work / 'decoders.h'),
                            str(work / 'stubs.swift'), str(work / 'checks.swift'), str(work / 'dock.swift'), str(work / 'owned.swift'),
                            str(work / 'downloader.swift')] + modules + [str(x) for x in production] + objects +
                           ([] if native else ['-Xlinker', '-lcrypto']) + ['-Xlinker', '-llzma', '-Xlinker', '-lz'], capture_output=True, text=True)
    require(build.returncode == 0, 'the production Steam library, download and decoder code compile on the host')
    if build.returncode:
        sys.stdout.write(build.stderr[-6000:])
        print(f'check-steam-library: {failures} FAILED')
        sys.exit(1)

    # The Swift crash handler would sit on the pipes for 30 s after a trap; AddressSanitizer reports on its own.
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0', SWIFT_BACKTRACE='enable=no')
    output = {}
    def run(phase, fixture, timeout=300):
        path = work / f'fixture-{phase}.json'
        path.write_text(json.dumps(fixture))
        result = subprocess.run([str(exe), phase, str(path)], env=env, capture_output=True, text=True, timeout=timeout)
        sys.stdout.write(result.stdout)
        if result.returncode:
            sys.stdout.write(result.stderr[-3000:])
        require(result.returncode == 0, f'Swift phase "{phase}" ran clean under AddressSanitizer')
        results = {}
        for line in result.stdout.splitlines():
            if line.startswith('RESULT '):
                for kv in line[len('RESULT '):].split():
                    k, _, v = kv.partition('=')
                    results[k] = v
        output[phase] = results
        return results

    # ---- the content network, as a local HTTP server
    state = State()
    version1, version2, shared = main_depot(1), main_depot(2), shared_depot()
    class Merged: pass
    merged = Merged(); merged.chunks = {**version1.chunks, **version2.chunks}
    state.depots = {9001: merged, 9003: shared}
    gid1, gid2, gid_shared = 111111, 222222, 333333
    m1, binary1 = version1.manifest_zip()
    m2, binary2 = version2.manifest_zip()
    ms, _ = shared.manifest_zip()
    state.manifests = {(9001, gid1): m1, (9001, gid2): m2, (9003, gid_shared): ms}
    dead, flaky, good = ContentServer('dead', state), ContentServer('flaky', state), ContentServer('good', state)
    servers = [dead, flaky, good]
    for server in servers: serve(server)
    fixture = dict(key=KEY_MAIN.hex(), keyShared=KEY_SHARED.hex(), vectorPlain=VEC_PLAIN.hex(), vectors=VEC, rawEncrypted=RAW,
                   hosts=[dead.url, flaky.url, good.url], requestCode=state.request_code, auth=state.auth,
                   gid1=gid1, gid2=gid2, gidShared=gid_shared, tmp=str(work / 'root'))

    run('units', fixture)

    # ---- an install that is interrupted: chunks were finished, no install record yet
    root_dir = work / 'root'
    drive = root_dir / 'drive_c'
    steam_apps = drive / 'Program Files (x86)/Steam/steamapps'
    folder = steam_apps / 'common/Fixture Game'
    state.limit = 4
    result = run('interrupt', fixture)
    require(result.get('install') == 'failed' and result.get('listed') == '0',
            'an interrupted install fails, and a game without an install record is not listed as installed')
    require(not (steam_apps / 'appmanifest_9000.acf').exists(), 'no install record before the install finishes')
    journals = list((steam_apps / 'downloading/9000').glob('*.journal'))
    require(journals, 'finished chunks are journaled')
    done = set()
    for journal in journals:
        m = re.match(r'depot_(\d+)_(\d+)\.journal', journal.name)
        depot = {9001: version1, 9003: shared}[int(m.group(1))]
        for line in journal.read_text().split():
            key = int(line, 16)
            done.add(depot.files[key >> 32]['chunks'][key & 0xffffffff][0].hex())
    require(len(done) >= 1 and len(state.served_ok) >= 1, f'{len(done)} chunks journaled after {len(state.served_ok)} served')

    # ---- resume: the journaled chunks are not fetched again; the install finishes
    state.limit = None
    state.reset_counters()
    result = run('resume', fixture)
    require(result.get('install') == 'ok' and result.get('listed') == '1', "the install finishes and Madeira Dock's own scanner lists the game as installed")
    require(not (set(state.chunk_requests) & done), 'chunks finished before the interruption are not fetched again')
    evil_sha = hashlib.sha1(EVIL).hexdigest()
    require(evil_sha not in state.chunk_requests, 'a manifest path that escapes the install folder is never downloaded')
    expected1 = {'bin/game.bin': GAME_BIN, 'data/Assets.dat': ASSETS, 'empty.txt': b'', 'docs/Readme.TXT': README, 'docs/notes.txt': NOTES,
                 'tool/custom.bin': CUSTOM, 'shared/lib.dat': data(30000, 6)}
    def tree_matches(expected):
        ok = True
        for name, content in expected.items():
            file = folder / name
            if not file.is_file() or file.read_bytes() != content:
                print('  mismatch:', name); ok = False
        return ok
    require(tree_matches(expected1), 'every downloaded file has exactly the bytes of its depot (chunks in five encodings, encrypted names, empty file)')
    found = sorted(str(p.relative_to(folder)) for p in folder.rglob('*') if p.is_file())
    require(found == sorted(expected1), f'and nothing else is in the install folder: {found}')
    outside = [str(p.relative_to(work)) for p in work.rglob('*') if p.is_file() and p.name in ('evil.txt', 'link')]
    require(not outside, f'no file named by a hostile or symlink manifest entry exists anywhere: {outside}')
    require(not (steam_apps / 'downloading/9000').exists(), 'the resume journal is removed when the install is complete')
    record = (steam_apps / 'appmanifest_9000.acf').read_text()
    require('"StateFlags"\t\t"4"' in record and '"appid"\t\t"9000"' in record and '"installdir"\t\t"Fixture Game"' in record and '"buildid"\t\t"1000"' in record,
            'the install record: fully installed, folder, build')
    require(f'"9001"\n\t\t{{\n\t\t\t"manifest"\t\t"{gid1}"\n\t\t\t"size"\t\t"{sum(f["size"] for f in version1.files)}"' in record, 'InstalledDepots names the depot, manifest and size')
    require('"SharedDepots"\n\t{\n\t\t"9003"\t\t"9100"' in record, 'SharedDepots names the depot taken from another app')
    require('"CheckGuid"\n\t{\n\t\t"0"\t\t"tool\\\\custom.bin"' in record, 'CheckGuid lists the per-user executable, Windows style')
    require('"SizeOnDisk"\t\t"%d"' % sum(len(c) for c in expected1.values()) in record, 'SizeOnDisk is the size of the files written')
    owner = (steam_apps / 'appmanifest_9100.acf').read_text()
    require('"appid"\t\t"9100"' in owner and '"9003"' in owner and '"installdir"\t\t"Fixture Game"' in owner, "the depot's owning app has its own record")
    require((steam_apps / f'depotcache/9001_{gid1}.manifest').read_bytes() == binary1, "the manifest of a depot with per-user executables is kept in depotcache for Valve's client")
    require(not (steam_apps / f'depotcache/9003_{gid_shared}.manifest').exists(), 'other depots leave depotcache alone')
    require(state.denied == 0, 'every request the downloader made carried the content authorization')
    import urllib.request, urllib.error
    try:
        urllib.request.urlopen(good.url + '/depot/9001/chunk/' + evil_sha)
        refused = False
    except urllib.error.HTTPError as error:
        refused = error.code == 403
    require(refused, 'the server itself refuses a request without the authorization (so the check above means something)')

    # ---- update: only what changed is fetched, files shrink
    state.reset_counters()
    result = run('update', fixture)
    new_sha = hashlib.sha1(data(60000, 99)).hexdigest()
    require(result.get('install') == 'ok' and set(state.chunk_requests) == {new_sha},
            f'an update fetches only the chunk that changed ({len(set(state.chunk_requests))} chunk(s))')
    expected2 = dict(expected1); expected2['bin/game.bin'] = GAME_BIN[:60000] + data(60000, 99) + GAME_BIN[120000:]; expected2['data/Assets.dat'] = ASSETS[:70000]
    require(tree_matches(expected2), 'the updated files have the new bytes, and the file that shrank has no stale tail')
    require('"buildid"\t\t"1001"' in (steam_apps / 'appmanifest_9000.acf').read_text(), 'the record has the new build')

    # ---- uninstall: everything the install wrote goes; the scanner no longer finds the game
    run('uninstall', fixture)
    require(not folder.exists() and not (steam_apps / 'appmanifest_9000.acf').exists() and not (steam_apps / 'appmanifest_9100.acf').exists()
            and not (steam_apps / 'downloading/9000').exists(), 'uninstall removes the folder, both records and the journal')

    # ---- a depot the account is licensed for but Steam refuses fails the install and writes no record
    other = dict(fixture, tmp=str(work / 'root2'))
    state.reset_counters()
    result = run('refused-licensed', other)
    require(result.get('install') == 'failed' and result.get('listed') == '0' and
            not list((work / 'root2').rglob('appmanifest_*.acf')), 'a refused licensed depot fails the install without a record')

    # ---- a content server refuses a file list once (an expired authorization): asked again, the install finishes
    state.reset_counters()
    state.refuse_first_manifest = True
    result = run('token-refresh', dict(fixture, tmp=str(work / 'root3')))
    state.refuse_first_manifest = False
    require(result.get('install') == 'ok' and result.get('listed') == '1', 'a file list refused once is fetched with fresh authorization and the install finishes')

    # ---- every content server refuses the file list: one more round with a fresh request code, then a clear failure
    state.reset_counters()
    state.refuse_manifests = True
    result = run('refused', dict(fixture, tmp=str(work / 'root4')))
    state.refuse_manifests = False
    require(result.get('install') == 'failed' and result.get('reason') == 'refused-401' and result.get('listed') == '0',
            f'a file list every server refuses fails the install as a refusal: {result}')
finally:
    for server in servers:
        server.shutdown(); server.server_close()
    if os.environ.get('MADEIRA_KEEP_WORK'):
        print('kept:', work)
    else:
        shutil.rmtree(work, ignore_errors=True)

if failures:
    print(f'check-steam-library: {failures} FAILED')
    sys.exit(1)
print('check-steam-library: PASS')
