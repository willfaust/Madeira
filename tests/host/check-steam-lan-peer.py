#!/usr/bin/env python3
"""Steam local network game transfers (docs/STEAM_LIBRARY.md, "From a PC on this network").

Compiles app/Madeira/SwiftSteam/Content/SteamLANPeer.swift with the protobuf
helpers and checks it against a real transfer between two Steam clients
(Windows, 2026-10-29): the chunk request must be byte-for-byte what Valve's
client sent, the status and RequestPeerContentServer answers must parse, and
SteamPeerChunkSource must fetch a chunk from a scripted PC over TCP.
Never contacts Steam. Needs swiftc (macOS or Linux) and python3.
"""
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

root = Path(__file__).resolve().parents[2]
steam = root / 'app/Madeira/SwiftSteam'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(cond, what):
    global failures
    print(('ok   ' if cond else 'FAIL ') + what)
    if not cond:
        failures += 1


def varint(v):
    out = bytearray()
    while v > 0x7F:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return bytes(out)


def field(num, wire, payload):
    tag = varint(num << 3 | wire)
    if wire == 0:
        return tag + varint(payload)
    if wire == 1:
        return tag + struct.pack('<Q', payload)
    return tag + varint(len(payload)) + payload


# From the capture: the first k_EMsgClientPeerChunkRequest the Ally X sent to the PC.
CAPTURED_REQUEST = bytes.fromhex(
    '3000000056543031ae2600800000000008f6d26d10f7d26d1a14d5162b89908a62ce1af865def28c19e6d09208d120e2e3f8b4c88ef0f018')
APP, DEPOT, TOKEN = 1796470, 1796471, 1792925733377421794
SHA = bytes.fromhex('d5162b89908a62ce1af865def28c19e6d09208d1')

# A status answer as a PC's Steam client sends it (ERemoteClientBroadcastMsg 1).
MAGIC = bytes([0xFF, 0xFF, 0xFF, 0xFF, 0x21, 0x4C, 0x5F, 0xA0])  # as steam-pc sends it
status_header = field(1, 0, 0x1234567890ABCDEF) + field(2, 0, 1)
status_body = (field(1, 0, 8) + field(4, 2, b'steam-pc') +
               field(9, 2, field(1, 1, 76561197960287930) + field(2, 0, 7)) + field(16, 0, 1) +
               field(20, 2, b'10.0.0.20') + field(20, 2, b'192.168.1.20'))
STATUS = MAGIC + struct.pack('<I', len(status_header)) + status_header + struct.pack('<I', len(status_body)) + status_body

# RequestPeerContentServer answers: depots unpacked, then packed.
PEER_UNPACKED = field(1, 0, 27040) + field(2, 0, DEPOT) + field(2, 0, 1796472) + field(3, 0, TOKEN)
PEER_PACKED = field(1, 0, 27040) + field(2, 2, varint(DEPOT) + varint(1796472)) + field(3, 0, TOKEN)

main_swift = r'''
import Foundation

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: String) -> Data {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return d
}

@main struct Check {
    static func main() async {
        let args = CommandLine.arguments
        switch args[1] {
        case "request":
            print(hex(SteamLANPeer.chunkRequest(appID: UInt32(args[2])!, depotID: UInt32(args[3])!,
                                                sha: unhex(args[4]), accessToken: UInt64(args[5])!)))
        case "status":
            if let s = SteamLANPeer.parseStatus(unhex(args[2])) {
                print("\(s.clientID) \(s.hostname) \(s.users.map(String.init).joined(separator: ",")) \(s.addresses.joined(separator: ","))")
            } else { print("nil") }
        case "own-status":
            print(hex(SteamLANPeer.statusPacket(clientID: 5, instanceID: 7, steamID: 76561197960287930,
                                                hostname: "Madeira", lanIP: "192.168.1.30")))
        case "type":
            print(SteamLANPeer.packetType([UInt8](unhex(args[2]))).map(String.init) ?? "nil")
        case "relayed":
            if let r = SteamLANPeer.relayedPacket(unhex(args[2])) { print("\(r.clientID) \(hex(r.payload))") } else { print("nil") }
        case "discovery":
            print(hex(SteamLANPeer.discoveryPacket(clientID: UInt64(args[2])!, sequence: 1)))
        case "peer":
            let p = try! SteamLANPeer.parsePeerServerResponse(unhex(args[2]))
            print("\(p.port) \(p.depots.sorted().map(String.init).joined(separator: ",")) \(p.accessToken)")
        case "peer-request":
            print(hex(SteamLANPeer.peerServerRequest(localClientID: 5, steamID: 76561197960287930,
                                                     serverClientID: 0x1234567890ABCDEF, appID: 1796470, buildID: 20000)))
        case "peer-info":
            let r = try! SteamLANPeer.parsePeerContentInfo(unhex(args[2]))
            print("\(r.apps.sorted().map(String.init).joined(separator: ",")) \(r.publicIP)")
        case "fetch":
            let source = SteamPeerChunkSource(host: "127.0.0.1", port: UInt16(args[2])!, appID: UInt32(args[3])!,
                                              depots: [UInt32(args[4])!], accessToken: UInt64(args[6])!)
            do {
                let r = try await source.fetch(depotID: UInt32(args[4])!, sha: unhex(args[5]))
                print("\(r.result) \(r.depotID) \(hex(r.sha)) \(r.encrypted) \(r.compressed) \(hex(r.data))")
            } catch { print("error \(error)") }
            source.close()
        default: print("?")
        }
    }
}
'''

stub_swift = '''
import Foundation
enum ContentDecryptor { static let maximumChunkBytes = 64 * 1024 * 1024 }
'''

if not Path(SWIFTC).exists() and not shutil.which(SWIFTC):
    print('SKIP: no swiftc (set SWIFTC)')
    sys.exit(0)

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'main.swift').write_text(main_swift)
    (tmp / 'stub.swift').write_text(stub_swift)
    exe = tmp / 'check'
    build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-o', str(exe),
                            str(steam / 'Content/SteamLANPeer.swift'), str(steam / 'Proto/SteamProtoMessages.swift'),
                            str(steam / 'Core/SteamError.swift'), str(tmp / 'stub.swift'), str(tmp / 'main.swift')],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        require(False, 'SteamLANPeer.swift compiles')
        sys.exit(1)

    def run(*args):
        return subprocess.run([str(exe)] + [str(a) for a in args], capture_output=True, text=True, timeout=30).stdout.strip()

    require(run('request', APP, DEPOT, SHA.hex(), TOKEN) == CAPTURED_REQUEST.hex(),
            'the chunk request is byte-for-byte what Valve\'s client sent')
    require(run('status', STATUS.hex()) == f'{0x1234567890ABCDEF} steam-pc 76561197960287930 10.0.0.20,192.168.1.20',
            'a PC\'s status answer gives its client ID, host name, account and addresses')
    own = run('own-status')
    require(own.startswith(MAGIC.hex()) and run('status', own) == '5 Madeira 76561197960287930 192.168.1.30',
            'this device\'s status parses back as a status with its client ID, name, account and address')
    require(run('type', own) == '1' and run('type', (MAGIC + struct.pack('<I', 4) + field(1, 0, 9) + field(2, 0, 0)).hex()) == '0',
            'packet types: status 1, discovery 0')
    relayed_body = field(1, 1, 76561197960287930) + field(2, 1, 0x1234567890ABCDEF) + field(3, 2, STATUS)
    require(run('relayed', relayed_body.hex()) == f'{0x1234567890ABCDEF} {STATUS.hex()}',
            'a relayed broadcast gives the sender\'s client ID and its packet')
    require(run('status', (MAGIC + struct.pack('<I', 4) + field(1, 0, 9) + field(2, 0, 0) + struct.pack('<I', 0)).hex()) == 'nil',
            'a discovery request (not a status) is not taken for a PC')
    disc = bytes.fromhex(run('discovery', 42))
    hl = struct.unpack_from('<I', disc, 8)[0]
    require(disc[:8] == MAGIC and disc[12:12 + hl] == field(1, 0, 42) + bytes([0x10, 0x00]) and
            disc[12 + hl:16 + hl] == struct.pack('<I', 2) and disc[16 + hl:] == field(1, 0, 1),
            'the discovery datagram: magic, header (client ID, type 0), body (seq_num 1)')
    expected_peer = f'27040 {DEPOT},1796472 {TOKEN}'
    require(run('peer', PEER_UNPACKED.hex()) == expected_peer, 'RequestPeerContentServer answer (unpacked depots)')
    require(run('peer', PEER_PACKED.hex()) == expected_peer, 'RequestPeerContentServer answer (packed depots)')
    require(run('peer-request') == (field(1, 0, 5) + field(2, 0, 76561197960287930) + field(3, 0, 0x1234567890ABCDEF) +
                                    field(4, 0, 1796470) + field(5, 0, 20000)).hex(),
            'the RequestPeerContentServer request carries both client IDs, the account, the app and the build')

    require(run('peer-info', (field(1, 2, varint(361420) + varint(1796470)) + field(2, 2, b'73.2.58.169')).hex()) ==
            '361420,1796470 73.2.58.169', 'GetPeerContentInfo answer: the PC\'s apps and public IP')

    # A scripted PC: answers one stale chunk first (another SHA), then the requested one.
    payload = b'PK\x03\x04' + bytes(range(64))
    seen = {}

    def pc(server):
        conn, _ = server.accept()
        with conn:
            data = b''
            while len(data) < len(CAPTURED_REQUEST):
                part = conn.recv(4096)
                if not part:
                    break
                data += part
            seen['request'] = data

            def response(sha):
                body = (field(1, 0, 1) + field(2, 0, APP) + field(3, 0, DEPOT) + field(4, 2, sha) +
                        field(5, 0, 0) + field(6, 0, 1) + field(7, 2, payload))
                msg = struct.pack('<II', 9903 | 0x80000000, 0) + body
                return struct.pack('<I', len(msg)) + b'VT01' + msg
            conn.sendall(response(bytes(20)) + response(SHA))

    server = socket.socket()
    server.bind(('127.0.0.1', 0))
    server.listen(1)
    thread = threading.Thread(target=pc, args=(server,), daemon=True)
    thread.start()
    out = run('fetch', server.getsockname()[1], APP, DEPOT, SHA.hex(), TOKEN)
    thread.join(5)
    server.close()
    require(seen.get('request') == CAPTURED_REQUEST, 'SteamPeerChunkSource sends the captured request over TCP')
    require(out == f'1 {DEPOT} {SHA.hex()} false true {payload.hex()}',
            'SteamPeerChunkSource skips a stale answer and returns the chunk the PC sent')

if failures:
    print(f'check-steam-lan-peer: {failures} FAILED')
    sys.exit(1)
print('PASS: Steam local network transfer messages match a real transfer')
