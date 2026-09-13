#!/usr/bin/env python3
"""Extract the complete x64 VC runtime from Microsoft's WiX Burn installer."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile


EXPECTED = (
    'concrt140.dll', 'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll',
    'msvcp140_atomic_wait.dll', 'msvcp140_codecvt_ids.dll', 'vcamp140.dll',
    'vccorlib140.dll', 'vcomp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
    'vcruntime140_threads.dll',
)
COMPOUND = b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_dll(data):
    """Validate x64 PE structure and retained certificate data, not publisher trust."""
    require(len(data) >= 64 and data[:2] == b'MZ', 'missing DOS header')
    pe = struct.unpack_from('<I', data, 60)[0]
    require(64 <= pe <= len(data) - 24, 'invalid PE header offset')
    require(data[pe:pe + 4] == b'PE\0\0', 'missing PE signature')
    machine, count = struct.unpack_from('<HH', data, pe + 4)
    optional_size, flags = struct.unpack_from('<HH', data, pe + 20)
    require(machine == 0x8664, 'expected x64 (AMD64) machine')
    require(flags & 0x2002 == 0x2002, 'expected executable DLL')
    require(0 < count <= 96, 'invalid PE section count')
    opt = pe + 24
    table = opt + optional_size
    require(optional_size >= 152 and table + count * 40 <= len(data),
            'truncated optional header or section table')
    require(struct.unpack_from('<H', data, opt)[0] == 0x20B, 'expected PE32+')
    require(struct.unpack_from('<I', data, opt + 108)[0] >= 5,
            'missing security data directory')
    section_end = table + count * 40
    populated = False
    for index in range(count):
        size, start = struct.unpack_from('<II', data, table + index * 40 + 16)
        if size:
            require(start >= table + count * 40 and start + size <= len(data),
                    'invalid or truncated PE section')
            section_end = max(section_end, start + size)
            populated = True
    require(populated, 'no PE section data')
    cert, size = struct.unpack_from('<II', data, opt + 112 + 4 * 8)
    require(cert >= section_end and cert % 8 == 0 and size > 8
            and cert + size <= len(data), 'missing or truncated certificate table')
    cursor, end = cert, cert + size
    while cursor < end:
        require(cursor + 8 <= end, 'truncated WIN_CERTIFICATE header')
        length, revision, kind = struct.unpack_from('<IHH', data, cursor)
        require(length > 8 and cursor + length <= end, 'truncated WIN_CERTIFICATE')
        require(revision == 0x200 and kind == 2 and data[cursor + 8] == 0x30,
                'expected PKCS#7 certificate payload')
        cursor += (length + 7) & ~7
    require(cursor == end, 'invalid certificate table alignment')


def cabinet_ranges(data):
    """Find complete CABs, including Burn's appended container after its UI CAB."""
    cursor = 0
    while True:
        start = data.find(b'MSCF\0\0\0\0', cursor)
        if start < 0:
            return
        cursor = start + 8
        if start + 36 > len(data):
            continue
        size = struct.unpack_from('<I', data, start + 8)[0]
        file_table = struct.unpack_from('<I', data, start + 16)[0]
        folders, files = struct.unpack_from('<HH', data, start + 26)
        if (size >= 36 and start + size <= len(data)
                and data[start + 24:start + 26] == b'\x03\x01'
                and folders > 0 and files > 0 and 36 <= file_table < size):
            yield start, size
            cursor = start + size


def runtime_name(name):
    # Microsoft minimum-runtime CABs store e.g. msvcp140.dll_amd64.
    normal = re.sub(r'_(amd64|x64)$', '', name.lower())
    return normal if normal in EXPECTED else None


def run_extract(sevenzip, archive, destination):
    destination.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [sevenzip, 'x', str(archive), '-o' + str(destination), '-y'],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    require(result.returncode == 0,
            f'7-Zip failed to extract {archive.name}:\n{result.stdout[-2000:]}')


def collect_runtime(installer, workspace, sevenzip):
    data = installer.read_bytes()
    require(data[:2] == b'MZ', 'input is not a Windows redistributable executable')
    cabinets = list(cabinet_ranges(data))
    require(cabinets, 'no complete CAB payloads found in redistributable')
    queue = []
    for index, (start, size) in enumerate(cabinets):
        cab = workspace / f'embedded-{index}.cab'
        cab.write_bytes(data[start:start + size])
        queue.append((cab, 0))
    found = {}
    processed = 0
    while queue:
        archive, depth = queue.pop(0)
        processed += 1
        require(depth <= 8 and processed <= 256, 'unexpected installer archive nesting')
        extracted = workspace / f'extracted-{processed}'
        run_extract(sevenzip, archive, extracted)
        for path in sorted(extracted.rglob('*')):
            require(not path.is_symlink(), 'unexpected symbolic link in installer')
            if not path.is_file():
                continue
            name = runtime_name(path.name)
            if name:
                content = path.read_bytes()
                # Architecture validation also guards plain filenames in mixed
                # architecture installers; suffixed ARM64 files are ignored.
                try:
                    validate_dll(content)
                except (ValueError, struct.error) as error:
                    raise ValueError(f'{path.name}: {error}') from error
                if name in found:
                    require(found[name].read_bytes() == content,
                            f'conflicting x64 payloads for {name}')
                found[name] = path
                continue
            with path.open('rb') as handle:
                magic = handle.read(8)
            if magic.startswith(b'MSCF') or magic == COMPOUND:
                queue.append((path, depth + 1))
    missing = sorted(set(EXPECTED) - found.keys())
    require(not missing, 'redistributable is missing required x64 DLLs: ' + ', '.join(missing))
    return found


def install_runtime(found, output):
    # Validate everything before touching the destination, then replace each DLL
    # atomically. A failed download/extraction cannot replace an existing set.
    for name in EXPECTED:
        validate_dll(found[name].read_bytes())
    require(not output.is_symlink(), 'output directory must not be a symbolic link')
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.vcruntime-', dir=output) as staging:
        staging = Path(staging)
        for name in EXPECTED:
            shutil.copyfile(found[name], staging / name)
        for name in EXPECTED:
            os.replace(staging / name, output / name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('installer', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--sevenzip', default='7zz')
    args = parser.parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix='madeira-vcruntime-') as temporary:
            found = collect_runtime(args.installer, Path(temporary), args.sevenzip)
            install_runtime(found, args.output)
    except (OSError, ValueError, struct.error) as error:
        print(f'VC runtime extraction failed: {error}', file=sys.stderr)
        return 1
    try:
        print('Installer SHA-256: ' + hashlib.sha256(args.installer.read_bytes()).hexdigest())
        for name in EXPECTED:
            data = (args.output / name).read_bytes()
            print(f'{name}: x64, {len(data)} bytes, SHA-256 {hashlib.sha256(data).hexdigest()}')
    except OSError as error:
        print(f'Warning: installed successfully but reporting failed: {error}', file=sys.stderr)
    else:
        print(f'Extracted and structurally validated all {len(EXPECTED)} DLLs in {args.output}.')
        print('Certificate payloads are intact; cryptographic publisher trust was not verified.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
