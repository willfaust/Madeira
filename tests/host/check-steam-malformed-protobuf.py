#!/usr/bin/env python3
"""Malformed Steam protobuf data throws instead of stopping the app.

Compiles app/Madeira/SwiftSteam/Proto/SteamProtoMessages.swift with
SteamLANPeer.swift and DepotManifest.swift and feeds them bytes no Steam
client sends: a tag whose field number does not fit in 32 bits, a 4-7 byte
manifest blob, and uint32 manifest fields above 2^32. Their callers use try?
(LAN discovery datagrams from any sender on UDP 27036, a cached manifest, the
plain-manifest attempt before decryption), so each must throw or parse; a Swift
trap there stops the app. Valid manifests must still parse as before.
Never contacts Steam. Needs swiftc (macOS or Linux) and python3.
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
steam = root / 'app/Madeira/SwiftSteam'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0
trap = ''


def require(cond, what):
    global failures
    print(('ok   ' if cond else 'FAIL ') + what)
    if not cond:
        failures += 1
        if trap:
            print('     ' + trap)


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
    if wire == 5:
        return tag + struct.pack('<I', payload)
    return tag + varint(len(payload)) + payload


MAGIC = bytes([0xFF, 0xFF, 0xFF, 0xFF, 0x21, 0x4C, 0x5F, 0xA0])  # LAN discovery packets
MANIFEST_MAGIC = bytes([0xD0, 0x17, 0xF6, 0x71])                  # 8-byte header before the payload
MAX_FIELD = (1 << 32) - 1                                          # the largest field number readTag returns
HUGE_TAG = varint(((1 << 37) - 1) << 3)                            # field 2^37 - 1, wire type varint


def chunk(original, compressed):
    return field(1, 2, bytes(range(20))) + field(2, 5, 0x01020304) + field(3, 0, 0) + field(4, 0, original) + field(5, 0, compressed)


def mapping(name, size, flags, *chunks):
    return field(1, 2, name) + field(2, 0, size) + field(3, 0, flags) + b''.join(field(6, 2, c) for c in chunks)


def framed(payload):
    return MANIFEST_MAGIC + struct.pack('<I', len(payload)) + payload


main_swift = r'''
import Foundation

func unhex(_ s: String) -> Data {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return d
}

func manifest(_ data: Data) -> String {
    do {
        let m = try DepotManifest.parse(depotID: 1, manifestGID: 1, data: data)
        return "parsed " + m.files.map { f in
            "\(f.filename):\(f.size):\(f.flags):" + f.chunks.map { "\($0.uncompressedSize)/\($0.compressedSize)" }.joined(separator: ";")
        }.joined(separator: ",")
    } catch { return "threw" }
}

@main struct Check {
    static func main() {
        let args = CommandLine.arguments
        let input = args.count > 2 ? unhex(args[2]) : Data()
        switch args[1] {
        case "tag":
            var decoder = ProtobufDecoder(input)
            do {
                if let t = try decoder.readTag() { print("\(t.fieldNumber) \(t.wireType.rawValue)") } else { print("end") }
            } catch { print("threw") }
        case "type":
            print(SteamLANPeer.packetType([UInt8](input)).map(String.init) ?? "nil")
        case "status":
            print(SteamLANPeer.parseStatus(input).map { String($0.clientID) } ?? "nil")
        case "manifest":
            print(manifest(input))
        case "noise":
            // Fixed pseudo-random 4 KiB blobs; a trap ends the process before the summary.
            var s: UInt64 = 1
            var parsed = 0, threw = 0
            for _ in 0..<Int(args[2])! {
                let blob = Data((0..<4096).map { _ -> UInt8 in
                    s = s &* 6364136223846793005 &+ 1442695040888963407
                    return UInt8(truncatingIfNeeded: s >> 33)
                })
                if (try? DepotManifest.parse(depotID: 1, manifestGID: 1, data: blob)) != nil { parsed += 1 } else { threw += 1 }
            }
            print("\(parsed) \(threw)")
        default: print("?")
        }
    }
}
'''

stub_swift = '''
import Foundation
enum SteamLog { static func trace(_ s: String) {} }
enum ContentDecryptor {
    static let maximumChunkBytes = 64 * 1024 * 1024
    static func decryptChunk(encryptedData: Data, depotKey: Data) throws -> Data { throw SteamError.protobufError("no key") }
}
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
                            str(steam / 'Proto/SteamProtoMessages.swift'), str(steam / 'Core/SteamError.swift'),
                            str(steam / 'Content/SteamLANPeer.swift'), str(steam / 'Content/DepotManifest.swift'),
                            str(tmp / 'stub.swift'), str(tmp / 'main.swift')],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        require(False, 'the Steam protobuf sources compile')
        sys.exit(1)

    def run(*args):
        global trap
        r = subprocess.run([str(exe)] + [str(a) for a in args], capture_output=True, text=True, timeout=120)
        trap = ''
        if r.returncode != 0:
            fatal = next((l for l in r.stderr.splitlines() if 'Fatal error' in l), r.stderr.strip()[-200:])
            trap = f'exit {r.returncode}: {fatal}'
            return None
        return r.stdout.strip()

    # The decoder: field numbers up to 2^32 - 1 decode as before, larger ones throw.
    require(run('tag', varint(MAX_FIELD << 3 | 2).hex()) == f'{MAX_FIELD} 2', 'field number 2^32 - 1 decodes')
    require(run('tag', varint((MAX_FIELD + 1) << 3).hex()) == 'threw', 'field number 2^32 throws')
    require(run('tag', HUGE_TAG.hex()) == 'threw', 'field number 2^37 - 1 throws')

    # A LAN datagram whose header holds that tag (22 bytes, from any sender on UDP 27036).
    datagram = MAGIC + struct.pack('<I', len(HUGE_TAG)) + HUGE_TAG + struct.pack('<I', 0)
    require(run('type', datagram.hex()) is not None, 'packetType of a datagram with an oversized tag returns')
    require(run('status', datagram.hex()) == 'nil', 'that datagram is not taken for a PC\'s status')

    # Depot manifests: valid ones parse, bare and behind the 8-byte header.
    good = field(1, 2, mapping(b'game.exe', 5, 0, chunk(5, 5)))
    require(run('manifest', good.hex()) == 'parsed game.exe:5:0:5/5', 'a valid manifest parses')
    require(run('manifest', framed(good).hex()) == 'parsed game.exe:5:0:5/5', 'a valid manifest behind the 8-byte header parses')

    require(run('manifest', b'PK\x03\x04\x00'.hex()) == 'threw', 'a 5-byte blob throws')
    require(run('manifest', framed(HUGE_TAG + b'\x00').hex()) == 'threw', 'a manifest with an oversized tag throws')
    # uint32 fields above 2^32 keep their low 32 bits, as protobuf's uint32 and the other Steam decoders do.
    require(run('manifest', field(1, 2, mapping(b'a', 1, 1 << 32 | 0x40)).hex()) == 'parsed a:1:64:',
            'flags above 2^32 keep their low 32 bits')
    require(run('manifest', field(1, 2, mapping(b'a', 5, 0, chunk(1 << 32 | 5, 1 << 33 | 3))).hex()) == 'parsed a:5:0:5/3',
            'cb_original and cb_compressed above 2^32 keep their low 32 bits')

    noise = run('noise', 1000)
    counts = ' (%s parsed, %s threw)' % tuple(noise.split()) if noise else ''
    require(noise is not None and sum(map(int, noise.split())) == 1000, '1000 random 4 KiB blobs each parse or throw' + counts)

if failures:
    print(f'check-steam-malformed-protobuf: {failures} FAILED')
    sys.exit(1)
print('PASS: malformed Steam protobuf data throws instead of stopping the app')
