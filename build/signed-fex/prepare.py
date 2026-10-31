#!/usr/bin/env python3
"""Prepare FEX translations on a Mac. No generated code is executed here."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shlex
import struct
import subprocess

here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--fex-source', type=Path, required=True)
parser.add_argument('--fex-build', type=Path, required=True)
parser.add_argument('--toolchain', type=Path, required=True)
input_group = parser.add_mutually_exclusive_group()
input_group.add_argument('--workload', type=Path)
input_group.add_argument('--pe', type=Path, help='Prepare an existing x64 Windows EXE or DLL')
parser.add_argument('--wine-imports', action='store_true')
parser.add_argument('--import-definition', type=Path, action='append', default=[])
parser.add_argument('--output', type=Path, default=here / 'out')
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
fex, build, tools = (p.resolve() for p in (args.fex_source, args.fex_build, args.toolchain))


def run(command, **kwargs):
    result = subprocess.run([str(x) for x in command], text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout[-4000:] + result.stderr[-8000:])
    return result.stdout


# Use the exact compile options of the same, unmodified FEX build.
revision = run(['git', '-C', fex, 'rev-parse', 'HEAD']).strip()
expected = run(['git', '-C', here.parents[1], 'ls-tree', 'HEAD', 'FEX']).split()[2]
assert revision == expected, f'FEX must match Madeira pin {expected}'
run(['git', '-C', fex, 'diff', '--quiet', 'HEAD'])
for notice in ['LICENSE', 'LICENSE-MADEIRA.md']:
    (out / ('FEX-' + notice)).write_bytes((fex / notice).read_bytes())
commands = json.loads((build / 'compile_commands.json').read_text())
sample = next(x for x in commands if x['file'].endswith('/Interface/Context/Context.cpp'))
assert Path(sample['file']).resolve() == fex / 'FEXCore/Source/Interface/Context/Context.cpp', 'FEX build uses another source checkout'
flags = shlex.split(sample['command'])
assert '-DFEX_CALLRET_STACK_UNUSED=1' in flags
assert '-DFEX_DISABLE_TELEMETRY=1' in flags
clean = []
i = 0
while i < len(flags):
    if flags[i] in ['-o', '-c', '-MT', '-MF']:
        i += 2
    elif flags[i] in ['-MD', '-MMD']:
        i += 1
    else:
        clean.append(flags[i]); i += 1
libraries_fex = list(build.rglob('*.a'))
exporter = here / 'out/export'
exporter.parent.mkdir(parents=True, exist_ok=True)
export_inputs = [here / 'export.cpp', fex / 'Source/Tools/CommonTools/DummyHandlers.cpp',
    Path(clean[0]).resolve(), *libraries_fex, *sorted(build.rglob('*.h')), *sorted(build.rglob('*.inl'))]
build_key = hashlib.sha256(json.dumps({'revision': revision, 'command': clean,
    'inputs': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in export_inputs}}, sort_keys=True).encode()).hexdigest()
manifest = exporter.with_suffix('.json')
cached = json.loads(manifest.read_text()) if manifest.exists() else {}
if not (exporter.exists() and cached.get('build_key') == build_key and
        cached.get('binary_sha256') == hashlib.sha256(exporter.read_bytes()).hexdigest()):
    run(clean + ['-I' + str(fex / 'Source/Tools/CommonTools'), str(here / 'export.cpp'),
        str(fex / 'Source/Tools/CommonTools/DummyHandlers.cpp'),
        *libraries_fex, '-L/opt/homebrew/lib', '-lxxhash', '-o', exporter])
    manifest.write_text(json.dumps({'build_key': build_key, 'binary_sha256': hashlib.sha256(exporter.read_bytes()).hexdigest()}) + '\n')
workload = (args.workload or here / 'workload.c').resolve()
libraries = ['-lntdll'] if args.wine_imports else []
if not args.pe:
    for index, definition in enumerate(args.import_definition):
        library = out / f'guest-imports-{index}.lib'
        run([tools / 'llvm-dlltool', '-m', 'i386:x86-64', '-d', definition.resolve(), '-l', library])
        libraries.insert(index, library)
pe_source = args.pe.resolve() if args.pe else out / 'workload.exe'
if not args.pe:
    run([tools / 'x86_64-w64-mingw32-clang', workload, '-O2', '-ffreestanding', '-fno-builtin',
        '-fno-stack-protector', '-mno-stack-arg-probe', '-ffp-contract=off', '-fno-unwind-tables',
        '-fno-asynchronous-unwind-tables', '-nostdlib', '-Wl,--entry,guest_workload',
        '-Wl,--image-base,0x130000000', '-Wl,--section-alignment,16384', '-Wl,--subsystem,console',
        *libraries, '-o', pe_source])

pe = pe_source.read_bytes()
assert pe[:2] == b'MZ'
header = struct.unpack_from('<I', pe, 0x3c)[0]
assert header <= len(pe) - 264, 'Truncated PE headers'
assert pe[header:header + 4] == b'PE\0\0'
machine, sections = struct.unpack_from('<HH', pe, header + 4)
optional_size = struct.unpack_from('<H', pe, header + 20)[0]
optional = header + 24
assert machine == 0x8664 and 0 < sections <= 96 and optional_size >= 240
assert struct.unpack_from('<H', pe, optional)[0] == 0x20b
entry = struct.unpack_from('<I', pe, optional + 16)[0]
preferred_base = struct.unpack_from('<Q', pe, optional + 24)[0]
base = 0x130000000
size, headers_size = struct.unpack_from('<II', pe, optional + 56)
assert 0 < size <= 16 * 1024 * 1024
assert 0 < headers_size <= min(len(pe), size)
assert optional + optional_size + sections * 40 <= headers_size, 'Section table exceeds PE headers'
image = bytearray(size)
image[:headers_size] = pe[:headers_size]
code_sections = []
mapped_sections = []
writable_sections = []
for i in range(sections):
    position = optional + optional_size + 40 * i
    assert position + 40 <= len(pe)
    virtual_size, rva, raw_size, raw = struct.unpack_from('<IIII', pe, position + 8)
    characteristics = struct.unpack_from('<I', pe, position + 36)[0]
    assert not characteristics & 0x20000000 or not characteristics & 0x80000000, 'Writable executable sections are unsupported'
    assert rva <= size and max(virtual_size, raw_size) <= size - rva
    assert raw <= len(pe) and raw_size <= len(pe) - raw
    extent = max(virtual_size, raw_size)
    assert rva >= headers_size and extent, 'Invalid mapped section range'
    assert not any(rva < end and start < rva + extent for start, end in mapped_sections), 'Overlapping PE sections'
    mapped_sections.append([rva, rva + extent])
    image[rva:rva + raw_size] = pe[raw:raw + raw_size]
    if characteristics & 0x20000000:
        code_sections.append([rva, rva + extent])
    if characteristics & 0x80000000: writable_sections.append([rva, rva + extent])
code_sections.sort()
for start, end in code_sections:
    page_start, page_end = start & ~16383, (end + 16383) & ~16383
    assert not any(page_start < high and low < page_end for low, high in writable_sections), \
        'Guest code shares a 16-KiB page with writable data; this layout needs a separate offline rewrite'
assert any(start <= entry < end for start, end in code_sections)
config, config_size = struct.unpack_from('<II', image, optional + 192)
assert config <= size and config_size <= size - config
assert config_size < 208 or not struct.unpack_from('<Q', image, config + 200)[0], 'Use signed-pe preparation for ARM64EC images'
relocations = []
position, length = struct.unpack_from('<II', image, optional + 152)
assert position <= size and length <= size - position
end = position + length
while position < end:
    assert position + 8 <= end
    page, block = struct.unpack_from('<II', image, position)
    assert block >= 8 and not block % 2 and block <= end - position
    for slot in range(position + 8, position + block, 2):
        value = struct.unpack_from('<H', image, slot)[0]
        if not value >> 12: continue
        rva = page + (value & 4095)
        assert value >> 12 == 10 and rva <= size - 8, 'Only data DIR64 relocations are supported'
        assert not any(rva < finish and start < rva + 8 for start, finish in code_sections), 'Guest text relocations need a separate offline rewrite'
        relocations.append(rva)
    position += block
imports = []
import_rva, import_size = struct.unpack_from('<II', image, optional + 120)
assert import_rva <= size and import_size <= size - import_rva
def image_string(rva):
    assert 0 <= rva < size
    end = image.index(0, rva)
    return bytes(image[rva:end]).decode('ascii')
if import_size:
    assert args.wine_imports, 'Use --wine-imports and an explicit runtime import bridge'
    for descriptor in range(import_rva, import_rva + import_size - 19, 20):
        lookup, _, _, dll, iat = struct.unpack_from('<IIIII', image, descriptor)
        if not lookup and not dll and not iat: break
        assert lookup and dll and iat
        name = image_string(dll)
        for index in range(size // 8):
            assert lookup + index * 8 <= size - 8 and iat + index * 8 <= size - 8
            thunk = struct.unpack_from('<Q', image, lookup + index * 8)[0]
            if not thunk: break
            assert not thunk >> 63, 'Ordinal guest imports need an explicit signature'
            imports.append({'dll': name, 'name': image_string(thunk + 2), 'iat': iat + index * 8})
        else: raise ValueError('Unterminated import lookup table')
    else: raise ValueError('Unterminated import descriptors')
(out / 'guest-image.bin').write_bytes(image)
disassembly = run([tools / 'llvm-objdump', '-d', '--no-show-raw-insn', pe_source])
rvas = []
for line in disassembly.splitlines():
    match = re.match(r'\s*([0-9a-fA-F]+):\s+(.*)', line)
    if not match: continue
    address, instruction = int(match[1], 16), match[2]
    if instruction.startswith(('int3', '<unknown>')): continue
    if any(start <= address - preferred_base < end for start, end in code_sections): rvas.append(address - preferred_base)
assert rvas and entry in rvas
(out / 'instruction-rvas.txt').write_text(''.join(f'{x:x}\n' for x in rvas))
guest = {'base': base, 'preferred_base': preferred_base, 'size': size, 'entry': base + entry,
    'code_sections': code_sections, 'instruction_starts': len(rvas), 'imports': imports,
    'data_relocations': relocations, 'pe_source': str(pe_source), 'pe_sha256': hashlib.sha256(pe).hexdigest()}
if not args.pe: guest['reference_source'] = str(workload)
(out / 'guest.json').write_text(json.dumps(guest, indent=2) + '\n')
print(run([exporter, out / 'guest-image.bin', out / 'instruction-rvas.txt', out]), end='')
metadata = json.loads((out / 'metadata.json').read_text())
metadata['fex_revision'] = revision
(out / 'metadata.json').write_text(json.dumps(metadata) + '\n')
print('Prepared PE guest and FEX code:', out)
