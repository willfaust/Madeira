#!/usr/bin/env python3
"""Package immutable FEX output; remap Apple's reserved x18 before signing."""
from pathlib import Path
import argparse
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
args = parser.parse_args()
out = args.output.resolve()
tools = args.toolchain.resolve()
sdk = args.sdk
folder = out / sdk
folder.mkdir(exist_ok=True)
bundle = folder / 'MadeiraSignedFEX.framework'
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
guest = json.loads((out / 'guest.json').read_text())
entries = sorted(metadata['entries'])
assert entries and len(entries) == len(set(x[0] for x in entries))
assert all(0 <= offset < metadata['code_size'] and offset % 4 == 0 for _, offset in entries)
image_header = '\n'.join([
    f'#define FEX_IMAGE_BASE UINT64_C({guest["base"]})',
    f'#define FEX_IMAGE_SIZE UINT64_C({guest["size"]})',
    f'#define FEX_IMAGE_ENTRY UINT64_C({guest["entry"]})',
    'static const struct MadeiraFEXEntry entries[] = {',
    *[f'{{UINT64_C({rip}),UINT64_C({offset})}},' for rip, offset in entries], '};',
    'static const struct MadeiraFEXSection sections[] = {',
    *[f'{{{start},{end}}},' for start, end in guest['code_sections']], '};',
    f'#define FEX_IMPORT_COUNT {len(guest.get("imports", []))}',
    'static const struct MadeiraFEXImport imports[] = {',
    *[f'{{{json.dumps(x["dll"])},{json.dumps(x["name"])},UINT64_C({x["iat"]})}},' for x in guest.get('imports', [])],
    *(['{0},'] if not guest.get('imports') else []), '};', ''])
(out / 'image.h').write_text(image_header)
blob = folder / 'blob.S'
blob.write_text('\n'.join([
    '.text', '.p2align 4', '.globl _madeira_fex_code', '_madeira_fex_code:',
    f'.incbin "{out / "translated.bin"}"', '.globl _madeira_fex_code_end', '_madeira_fex_code_end:',
    '.section __TEXT,__const', '.p2align 6', '.globl _madeira_fex_frame', '_madeira_fex_frame:',
    f'.incbin "{out / "frame.bin"}"', '']))
sysroot = run(['xcrun', '--sdk', sdk, '--show-sdk-path']).strip()
compiler = ['xcrun', '--sdk', sdk, 'clang', '-target', target, '-isysroot', sysroot,
    '-O2', '-ffp-contract=off', '-I' + str(out), '-I' + str(here.parents[1] / 'app/Madeira')]
sources = [blob, here / 'bridge.S', here / 'support.c', Path(guest.get('reference_source', here / 'workload.c'))]
binary = bundle / 'MadeiraSignedFEX'


def link():
    run(compiler + ['-dynamiclib', *sources, '-Wl,-install_name,@rpath/MadeiraSignedFEX.framework/MadeiraSignedFEX',
        '-o', binary])


link()
symbols = run([tools / 'llvm-nm', '-g', '--defined-only', binary])
base = int(re.search(r'^([0-9a-fA-F]+) T _madeira_fex_code$', symbols, re.M)[1], 16)
disassembly = run([tools / 'llvm-objdump', '-d', '--no-show-raw-insn', f'--start-address={base}',
    f'--stop-address={base + metadata["code_size"]}', binary])
code = bytearray((out / 'translated.bin').read_bytes())
literals = metadata['literals']
rewrites, direct = [], []
for line in disassembly.splitlines():
    match = re.match(r'\s*([0-9a-fA-F]+):\s+(.*)', line)
    if not match: continue
    offset, instruction = int(match[1], 16) - base, match[2].split(';')[0].strip()
    if not any(start <= offset < end for start, end in metadata['ranges']): continue
    if any(slot <= offset < slot + 8 for slot in literals): continue
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
if rewrites or direct:
    (folder / 'translated.bin').write_bytes(code)
    blob.write_text(blob.read_text().replace(str(out / 'translated.bin'), str(folder / 'translated.bin')))
    link()
info = {'CFBundleIdentifier': 'com.madeira.signed-fex', 'CFBundleExecutable': 'MadeiraSignedFEX',
    'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
    'CFBundleSupportedPlatforms': ['iPhoneOS' if sdk == 'iphoneos' else 'MacOSX']}
(bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
(bundle / 'guest-image.bin').write_bytes((out / 'guest-image.bin').read_bytes())
run(['codesign', '--force', '--sign', '-', '--timestamp=none', bundle])
run(['codesign', '--verify', '--strict', bundle])
summary = {'sdk': sdk, 'entries': len(entries), 'translated_bytes': len(code),
    'immutable_exit_rewrites': metadata['rewritten_exits'], 'reserved_x18_rewrites': len(rewrites) + len(direct),
    'fex_revision': metadata['fex_revision']}
(folder / 'bundle.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary))
print(bundle)
