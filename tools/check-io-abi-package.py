#!/usr/bin/env python3
"""Require the matching native IOSB consumer and rebuilt ARM64 WoW64 producer."""
import argparse
from pathlib import Path
import struct
import zipfile

PRODUCER = b'madeira-io-abi-v1'
CONSUMER = b'[io-abi] v1 per-request IOSB layout active'


def producer(data):
    assert data[:2] == b'MZ', 'WoW64 producer is not a PE image'
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    assert data[pe:pe + 4] == b'PE\0\0', 'invalid WoW64 PE signature'
    assert struct.unpack_from('<H', data, pe + 4)[0] == 0xaa64, 'WoW64 producer must be native ARM64'
    assert PRODUCER in data, 'stale WoW64 IOSB producer'


def check(staged, app, ipa):
    expected = staged.read_bytes()
    producer(expected)
    assert (app / 'aarch64-windows/wow64.dll').read_bytes() == expected, 'Xcode packaged a stale WoW64 producer'
    native = (app / 'Madeira.debug.dylib').read_bytes()
    assert CONSUMER in native, 'native IOSB consumer missing from linked image'
    assert b'[wow-thread-init-v1]' in expected, 'stale Wine CPU initialization consumer'
    assert b'[wow-break-deliver-v1]' in expected, 'stale Wine breakpoint diagnostics'
    assert b'MadeiraBTCpuWriteMemory' in expected, 'stale Wine native-write consumer'
    assert b'[wow-query-zero-v1]' in expected, 'stale Wine guest memory-enumeration consumer'
    assert b'[wow-group-attribute-v1]' in expected, 'stale Wine thread-affinity attribute consumer'
    assert b'[guest32-cxx-first-v1]' in native, 'native first C++ exception diagnostics missing'
    assert b'[cef-atexit-v1]' in native, 'native CEF registration diagnostics missing'
    assert b'[wow-write]' in native and b'[guest32-symbols]' in native, 'native guest memory diagnostics missing'
    cpu = staged.parent / 'xtajit.dll'
    cpu_data = cpu.read_bytes()
    assert struct.unpack_from('<H', cpu_data, struct.unpack_from('<I', cpu_data, 0x3c)[0] + 4)[0] == 0xaa64
    assert b'MadeiraBTCpuThreadInit' in cpu_data and b'[fex-thread-init-v1]' in cpu_data, 'stale FEX CPU producer'
    assert b'MadeiraBTCpuWriteMemory' in cpu_data and b'[fex-guest-write-v1]' in cpu_data, 'stale FEX native-write producer'
    assert (app / 'aarch64-windows/xtajit.dll').read_bytes() == cpu_data, 'Xcode packaged stale FEX'
    guest = (staged.parent.parent / 'i386-windows/kernelbase.dll').read_bytes()
    assert struct.unpack_from('<H', guest, struct.unpack_from('<I', guest, 0x3c)[0] + 4)[0] == 0x14c
    assert b'[wpm-call-v1]' in guest, 'stale guest32 memory API producer'
    assert (app / 'i386-windows/kernelbase.dll').read_bytes() == guest, 'Xcode packaged stale guest32 caller'
    with zipfile.ZipFile(ipa) as archive:
        assert archive.read('Payload/Madeira.app/aarch64-windows/wow64.dll') == expected, 'ZIP producer differs'
        assert archive.read('Payload/Madeira.app/Madeira.debug.dylib') == native, 'ZIP native consumer differs'
        assert archive.read('Payload/Madeira.app/aarch64-windows/xtajit.dll') == cpu_data, 'ZIP FEX producer differs'
        assert archive.read('Payload/Madeira.app/i386-windows/kernelbase.dll') == guest, 'ZIP guest32 caller differs'
    print('PASS final IPA contains matching native IOSB consumer and byte-identical rebuilt ARM64 WoW64 producer')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staged', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--ipa', type=Path, required=True)
    args = parser.parse_args()
    check(args.staged, args.app, args.ipa)
