#!/usr/bin/env python3
"""Prepare FEX translations on a Mac. No generated code is executed here."""
from pathlib import Path
import argparse
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
parser.add_argument('--workload', type=Path, default=here / 'workload.c')
parser.add_argument('--wine-imports', action='store_true')
parser.add_argument('--import-definition', type=Path)
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
run(clean + ['-I' + str(fex / 'Source/Tools/CommonTools'), str(here / 'export.cpp'),
    str(fex / 'Source/Tools/CommonTools/DummyHandlers.cpp'),
    *[str(p) for p in build.rglob('*.a')], '-L/opt/homebrew/lib', '-lxxhash', '-o', str(out / 'export')])
workload = args.workload.resolve()
libraries = ['-lntdll'] if args.wine_imports else []
if args.import_definition:
    library = out / 'guest-imports.lib'
    run([tools / 'llvm-dlltool', '-m', 'i386:x86-64', '-d', args.import_definition.resolve(), '-l', library])
    libraries.insert(0, library)
run([tools / 'x86_64-w64-mingw32-clang', workload, '-O2', '-ffreestanding', '-fno-builtin',
    '-fno-stack-protector', '-mno-stack-arg-probe', '-ffp-contract=off', '-fno-unwind-tables',
    '-fno-asynchronous-unwind-tables', '-nostdlib', '-Wl,--entry,guest_workload',
    '-Wl,--image-base,0x130000000', '-Wl,--section-alignment,16384', '-Wl,--subsystem,console',
    *libraries, '-o', out / 'workload.exe'])

# Only import-free PE32+ images are accepted by this runner.
pe = (out / 'workload.exe').read_bytes()
assert pe[:2] == b'MZ'
header = struct.unpack_from('<I', pe, 0x3c)[0]
assert pe[header:header + 4] == b'PE\0\0'
machine, sections = struct.unpack_from('<HH', pe, header + 4)
optional_size = struct.unpack_from('<H', pe, header + 20)[0]
optional = header + 24
assert machine == 0x8664 and 0 < sections <= 96 and optional_size >= 240
assert struct.unpack_from('<H', pe, optional)[0] == 0x20b
entry = struct.unpack_from('<I', pe, optional + 16)[0]
base = struct.unpack_from('<Q', pe, optional + 24)[0]
size, headers_size = struct.unpack_from('<II', pe, optional + 56)
assert base == 0x130000000 and 0 < size <= 16 * 1024 * 1024
assert 0 < headers_size <= min(len(pe), size)
image = bytearray(size)
image[:headers_size] = pe[:headers_size]
code_sections = []
for i in range(sections):
    position = optional + optional_size + 40 * i
    assert position + 40 <= len(pe)
    virtual_size, rva, raw_size, raw = struct.unpack_from('<IIII', pe, position + 8)
    characteristics = struct.unpack_from('<I', pe, position + 36)[0]
    assert rva <= size and max(virtual_size, raw_size) <= size - rva
    assert raw <= len(pe) and raw_size <= len(pe) - raw
    image[rva:rva + raw_size] = pe[raw:raw + raw_size]
    if characteristics & 0x20000000:
        code_sections.append([rva, rva + virtual_size])
assert any(start <= entry < end for start, end in code_sections)
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
disassembly = run([tools / 'llvm-objdump', '-d', '--no-show-raw-insn', out / 'workload.exe'])
rvas = []
for line in disassembly.splitlines():
    match = re.match(r'\s*([0-9a-fA-F]+):\s+(.*)', line)
    if not match: continue
    address, instruction = int(match[1], 16), match[2]
    if instruction.startswith(('int3', '<unknown>')): continue
    if any(start <= address - base < end for start, end in code_sections): rvas.append(address - base)
assert rvas and entry in rvas
(out / 'instruction-rvas.txt').write_text(''.join(f'{x:x}\n' for x in rvas))
(out / 'guest.json').write_text(json.dumps({'base': base, 'size': size, 'entry': base + entry,
    'code_sections': code_sections, 'instruction_starts': len(rvas), 'imports': imports,
    'reference_source': str(workload)}, indent=2) + '\n')
print(run([out / 'export', out / 'guest-image.bin', out / 'instruction-rvas.txt', out]), end='')
metadata = json.loads((out / 'metadata.json').read_text())
metadata['fex_revision'] = revision
(out / 'metadata.json').write_text(json.dumps(metadata) + '\n')
print('Prepared PE guest and FEX code:', out)
