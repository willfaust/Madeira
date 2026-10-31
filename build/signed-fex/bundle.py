#!/usr/bin/env python3
"""Package immutable FEX output; remap Apple's reserved x18 before signing."""
from pathlib import Path
import argparse
from bisect import bisect_right
import hashlib
import json
import plistlib
import re
import struct
import subprocess

here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--sdk', choices=['iphoneos', 'macosx'], required=True)
parser.add_argument('--toolchain', type=Path, required=True)
parser.add_argument('--output', type=Path, default=here / 'out')
parser.add_argument('--name', default='MadeiraSignedFEX', help='Unique framework name when preparing several modules')
args = parser.parse_args()
out = args.output.resolve()
tools = args.toolchain.resolve()
sdk = args.sdk
folder = out / sdk
folder.mkdir(exist_ok=True)
assert re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,79}', args.name), 'Invalid framework name'
bundle = folder / (args.name + '.framework')
bundle.mkdir(exist_ok=True)
target = 'arm64-apple-ios17.0' if sdk == 'iphoneos' else 'arm64-apple-macos13.0'


def run(command):
    result = subprocess.run([str(x) for x in command], text=True, capture_output=True)
    if result.returncode: raise RuntimeError(result.stdout[-3000:] + result.stderr[-6000:])
    return result.stdout


def text_section(path):
    data = path.read_bytes()
    assert struct.unpack_from('<I', data)[0] == 0xfeedfacf
    offset = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, offset)
        if command == 0x19:
            for index in range(struct.unpack_from('<I', data, offset + 64)[0]):
                section = offset + 72 + index * 80
                if data[section:section + 16].split(b'\0')[0] == b'__text':
                    length, position = struct.unpack_from('<QI', data, section + 40)
                    return data[position:position + length]
        offset += size
    raise ValueError('No text section')


metadata = json.loads((out / 'metadata.json').read_text())
assert metadata.get('relocatable'), 'Prepare this image with the current relocatable exporter first'
assert metadata.get('memory_model') == 'tso', 'Prepare this image with memory ordering enabled'
guest = json.loads((out / 'guest.json').read_text())
entries = sorted(metadata['entries'])
assert entries and len(entries) == len(set(x[0] for x in entries))
assert all(0 <= offset < metadata['code_size'] and offset % 4 == 0 for _, offset in entries)
image_header = '\n'.join([
    f'#define FEX_IMAGE_BASE UINT64_C({guest["base"]})',
    f'#define FEX_IMAGE_SIZE UINT64_C({guest["size"]})',
    f'#define FEX_IMAGE_ENTRY UINT64_C({guest["entry"]})',
    f'#define FEX_HAS_REFERENCE {int("reference_source" in guest)}',
    'static const struct MadeiraFEXEntry entries[] = {',
    *[f'{{UINT64_C({rip}),UINT64_C({offset})}},' for rip, offset in entries], '};',
    'static const struct MadeiraFEXSection sections[] = {',
    *[f'{{{start},{end}}},' for start, end in guest['code_sections']], '};',
    f'#define FEX_IMPORT_COUNT {len(guest.get("imports", []))}',
    'static const struct MadeiraFEXImport imports[] = {',
    *[f'{{{json.dumps(x["dll"])},{json.dumps(x["name"])},UINT64_C({x["iat"]})}},' for x in guest.get('imports', [])],
    *(['{0},'] if not guest.get('imports') else []), '};', ''])
digest = hashlib.sha256()
guest_bytes = (out / 'guest-image.bin').read_bytes()
for start, end in guest['code_sections']:
    digest.update(struct.pack('<QQ', start, end))
    digest.update(guest_bytes[start:end])
image_header += 'static const unsigned char guest_code_hash[32] = {' + ','.join(map(str, digest.digest())) + '};\n'
abi = '\n'.join(line for line in (out / 'abi.h').read_text().splitlines() if not line.startswith('#define FEX_GUEST_'))
abi += (out / 'runtime.h').read_text()
abi += hashlib.sha256((out / 'indexed.bin').read_bytes()).hexdigest()
for source in [here.parents[1] / 'app/Madeira/SignedFEX.h', here / 'bridge.S', here / 'support.c']:
    abi += hashlib.sha256(source.read_bytes()).hexdigest()
image_header += 'static const unsigned char abi_hash[32] = {' + ','.join(map(str, hashlib.sha256(abi.encode()).digest())) + '};\n'
(out / 'image.h').write_text(image_header)
blob = folder / 'blob.S'
blob.write_text('\n'.join([
    '.text', '.p2align 4', '.globl _madeira_fex_code', '_madeira_fex_code:',
    f'.incbin "{out / "translated.bin"}"', '.globl _madeira_fex_code_end', '_madeira_fex_code_end:',
    '.section __TEXT,__const', '.p2align 6', '.globl _madeira_fex_frame', '_madeira_fex_frame:',
    f'.incbin "{out / "frame.bin"}"', '.p2align 4', '.globl _madeira_fex_indexed', '_madeira_fex_indexed:',
    f'.incbin "{out / "indexed.bin"}"', '']))
sysroot = run(['xcrun', '--sdk', sdk, '--show-sdk-path']).strip()
compiler = ['xcrun', '--sdk', sdk, 'clang', '-target', target, '-isysroot', sysroot,
    '-O2', '-ffp-contract=off', '-I' + str(out), '-I' + str(here.parents[1] / 'app/Madeira')]
sources = [blob, here / 'bridge.S', here / 'support.c']
if 'reference_source' in guest: sources.append(Path(guest['reference_source']))
binary = bundle / args.name


def link():
    run(compiler + ['-dynamiclib', *sources, '-Wl,-install_name,@rpath/' + bundle.name + '/' + args.name,
        '-o', binary])


link()
symbols = run([tools / 'llvm-nm', '-g', '--defined-only', binary])
base = int(re.search(r'^([0-9a-fA-F]+) T _madeira_fex_code$', symbols, re.M)[1], 16)
disassembly = run([tools / 'llvm-objdump', '-d', '--no-show-raw-insn', f'--start-address={base}',
    f'--stop-address={base + metadata["code_size"]}', binary])
code = bytearray((out / 'translated.bin').read_bytes())
literals = sorted(metadata['literals'])
code_ranges = sorted(metadata['ranges'])
assert code_ranges and all(0 <= start < end <= len(code) and start % 4 == end % 4 == 0 for start, end in code_ranges)
assert all(code_ranges[i - 1][1] <= code_ranges[i][0] for i in range(1, len(code_ranges))), 'Overlapping native code ranges'
range_starts = [start for start, end in code_ranges]
def in_code(offset):
    index = bisect_right(range_starts, offset) - 1
    return index >= 0 and offset < code_ranges[index][1]
def in_literal(offset):
    index = bisect_right(literals, offset) - 1
    return index >= 0 and offset < literals[index] + 8
rewrites, direct = [], []
for line in disassembly.splitlines():
    match = re.match(r'\s*([0-9a-fA-F]+):\s+(.*)', line)
    if not match: continue
    offset, instruction = int(match[1], 16) - base, match[2].split(';')[0].strip()
    if not in_code(offset) or in_literal(offset): continue
    assert not re.search(r'\b[wx]25\b', instruction), 'x25 is not free; rebuild FEX with FEX_CALLRET_STACK_UNUSED=1'
    if not re.search(r'\b[wx]18\b', instruction): continue
    word = struct.unpack_from('<I', code, offset)[0]
    # PC-relative instructions keep their displacement and change only the GPR field.
    if (word & 0x7e000000) in [0x34000000, 0x36000000] or (word & 0x1f000000) == 0x10000000 or (word & 0x3b000000) == 0x18000000:
        assert word & 31 == 18
        direct.append((offset, (word & ~31) | 25))
    elif (word & 0xfe000000) == 0xd6000000:
        assert (word >> 5) & 31 == 18
        direct.append((offset, (word & ~(31 << 5)) | (25 << 5)))
    else:
        rewritten = re.sub(r'\b([wx])18\b', r'\g<1>25', instruction)
        rewrites.append((offset, instruction, rewritten, word))
if rewrites:
    source = folder / 'registers.S'
    source.write_text('.text\n.p2align 2\n' + '\n'.join(x for _, original, new, _ in rewrites for x in [original, new]) + '\n')
    obj = folder / 'registers.o'
    run(compiler + ['-c', source, '-o', obj])
    assembled = text_section(obj)
    assert len(assembled) == len(rewrites) * 8
    for index, (offset, original, _, word) in enumerate(rewrites):
        old, new = struct.unpack_from('<II', assembled, index * 8)
        assert old == word, f'Assembler round-trip differs at {offset:x}: {original}'
        struct.pack_into('<I', code, offset, new)
for offset, word in direct: struct.pack_into('<I', code, offset, word)
tso_rewrites = 0
# Use FEX's reserved NOP slots before signing, so ordinary unaligned access needs no runtime patch.
loads = {0x48dffc00: 0x79400000, 0x88dffc00: 0xb9400000, 0xc8dffc00: 0xf9400000}
stores = {0x489ffc00: 0x79000000, 0x889ffc00: 0xb9000000, 0xc89ffc00: 0xf9000000}
for start, end in metadata['ranges']:
    for offset in range(start, end, 4):
        if in_literal(offset): continue
        word = struct.unpack_from('<I', code, offset)[0]
        opcode = word & 0xfffffc00
        if opcode in loads and offset + 8 <= end and struct.unpack_from('<I', code, offset + 4)[0] == 0xd503201f:
            struct.pack_into('<II', code, offset, loads[opcode] | (word & 1023), 0xd5033dbf)
            tso_rewrites += 1
        elif opcode in stores and offset >= start + 4 and struct.unpack_from('<I', code, offset - 4)[0] == 0xd503201f:
            struct.pack_into('<II', code, offset - 4, 0xd5033bbf, stores[opcode] | (word & 1023))
            tso_rewrites += 1
if rewrites or direct or tso_rewrites:
    (folder / 'translated.bin').write_bytes(code)
    blob.write_text(blob.read_text().replace(str(out / 'translated.bin'), str(folder / 'translated.bin')))
    link()
info = {'CFBundleIdentifier': 'com.madeira.signed-fex.' + args.name, 'CFBundleExecutable': args.name,
    'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
    'CFBundleSupportedPlatforms': ['iPhoneOS' if sdk == 'iphoneos' else 'MacOSX']}
(bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
(bundle / 'guest-image.bin').write_bytes((out / 'guest-image.bin').read_bytes())
for notice in ['FEX-LICENSE', 'FEX-LICENSE-MADEIRA.md']:
    (bundle / notice).write_bytes((out / notice).read_bytes())
run(['codesign', '--force', '--sign', '-', '--timestamp=none', bundle])
run(['codesign', '--verify', '--strict', bundle])
summary = {'sdk': sdk, 'entries': len(entries), 'translated_bytes': len(code),
    'immutable_exit_rewrites': metadata['rewritten_exits'], 'reserved_x18_rewrites': len(rewrites) + len(direct),
    'offline_tso_rewrites': tso_rewrites,
    'fex_revision': metadata['fex_revision']}
(folder / 'bundle.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary))
print(bundle)
