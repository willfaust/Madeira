#!/usr/bin/env python3
"""Wrap native Wine PE sections in a signed Mach-O image without changing code."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import struct
import subprocess
from thread_state import rewrite

PAGE = 16384
PE_OFFSET = PAGE


def align(value):
    return (value + PAGE - 1) & -PAGE


def uleb(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def need(condition, message):
    if not condition:
        raise ValueError(message)


def read_pe(path):
    raw = path.read_bytes()
    need(64 <= len(raw) <= 128 * 1024 * 1024 and raw[:2] == b'MZ', 'Invalid PE input')
    nt = struct.unpack_from('<I', raw, 60)[0]
    need(nt <= len(raw) - 264 and raw[nt:nt + 4] == b'PE\0\0', 'Invalid PE header')
    machine, count = struct.unpack_from('<HH', raw, nt + 4)
    optional_size = struct.unpack_from('<H', raw, nt + 20)[0]
    optional = nt + 24
    need(machine in (0xaa64, 0x8664) and 0 < count <= 96 and optional_size >= 240,
         'Only native ARM64 or ARM64EC PE32+ images are supported')
    need(struct.unpack_from('<H', raw, optional)[0] == 0x20b, 'Not PE32+')
    base = struct.unpack_from('<Q', raw, optional + 24)[0]
    size, headers = struct.unpack_from('<II', raw, optional + 56)
    need(0 < headers <= len(raw) and headers <= size <= 128 * 1024 * 1024, 'Invalid image size')
    image = bytearray(size)
    image[:headers] = raw[:headers]
    sections = []
    for i in range(count):
        off = optional + optional_size + 40 * i
        need(off + 40 <= headers, 'Section table exceeds headers')
        name = raw[off:off + 8].split(b'\0')[0].decode('ascii')
        virtual, rva, length, position = struct.unpack_from('<IIII', raw, off + 8)
        flags = struct.unpack_from('<I', raw, off + 36)[0]
        span = max(virtual, length)
        need(rva >= headers and span <= size - rva and position <= len(raw) - length, 'Invalid section')
        need(not any(rva < end and start < rva + span for _, start, end, _ in sections), 'Overlapping sections')
        image[rva:rva + length] = raw[position:position + length]
        sections.append((name, rva, rva + span, flags))
    executable = [s for s in sections if s[3] & 0x20000000]
    need(executable and not any(s[3] & 0x80000000 for s in executable), 'Writable native code is unsupported')
    data_start = min(s[1] for s in sections if not s[3] & 0x20000000)
    need(data_start % PAGE == 0 and all(s[2] <= data_start for s in executable),
         'Rebuild this PE with 16 KiB section alignment and executable sections before data')
    digest = hashlib.sha256()
    digest.update(struct.pack('<II', machine, size))
    for _, start, end, flags in executable:
        digest.update(struct.pack('<III', start, end, flags))
        digest.update(image[start:end])
    code_hash = digest.digest()
    relocations = []
    rva, length = struct.unpack_from('<II', image, optional + 112 + 5 * 8)
    need(rva <= size and length <= size - rva, 'Relocation directory exceeds image')
    off, end = rva, rva + length
    while off < end:
        need(off + 8 <= end, 'Truncated relocation block')
        page, block = struct.unpack_from('<II', image, off)
        need(block >= 8 and block % 2 == 0 and block <= end - off, 'Invalid relocation block')
        for index in range(off + 8, off + block, 2):
            value = struct.unpack_from('<H', image, index)[0]
            if not value >> 12:
                continue
            target = page + (value & 4095)
            need(value >> 12 == 10 and target % 8 == 0 and data_start <= target <= size - 8,
                 'Native text relocations and non-DIR64 relocations need an offline code rewrite')
            pointer = struct.unpack_from('<Q', image, target)[0]
            need(base <= pointer < base + size, 'External absolute pointer in PE relocation')
            struct.pack_into('<Q', image, target, PE_OFFSET + pointer - base)
            relocations.append(target)
        off += block
    need(len(relocations) == len(set(relocations)), 'Duplicate relocation')
    if machine == 0x8664:
        config, length = struct.unpack_from('<II', image, optional + 112 + 10 * 8)
        need(length >= 208 and config <= size - length and config + 208 <= size,
             'An x86-64 PE without ARM64EC metadata cannot run natively')
        metadata = struct.unpack_from('<Q', image, config + 200)[0] - PE_OFFSET
        need(0 <= metadata <= size - 80, 'Missing ARM64EC metadata')
    return raw, image, sections, data_start, base, machine, code_hash, sorted(relocations)


def segment(name, start, size, protection, sections):
    result = struct.pack('<II16sQQQQiiII', 0x19, 72 + 80 * len(sections), name.encode(),
                         start, size, start, size, protection, protection, len(sections), 0)
    for section, address, length, flags in sections:
        result += struct.pack('<16s16sQQIIIIIIII', section.encode(), name.encode(), address, length,
                              address, 2, 0, 0, flags, 0, 0, 0)
    return result


def dylib(command, name):
    data = name.encode() + b'\0'
    length = (24 + len(data) + 7) & -8
    return struct.pack('<IIIIII', command, length, 24, 0, 0x10000, 0x10000) + data + bytes(length - 24 - len(data))


def exports(symbols):
    leaves = []
    for _, address in symbols:
        terminal = b'\0' + uleb(address)
        leaves.append(uleb(len(terminal)) + terminal + b'\0')
    offsets = [0] * len(symbols)
    while True:
        root = b'\0' + bytes([len(symbols)])
        for (name, _), offset in zip(symbols, offsets):
            root += name.encode() + b'\0' + uleb(offset)
        new, cursor = [], len(root)
        for leaf in leaves:
            new.append(cursor)
            cursor += len(leaf)
        if new == offsets:
            return root + b''.join(leaves)
        offsets = new


def prepare(source, output, sdk, thread_state=False, toolchain=None):
    raw, image, sections, data_rva, base, machine, code_hash, fixups = read_pe(source)
    name = 'WinePE_' + code_hash.hex()
    bundle = output / (name + '.framework')
    bundle.mkdir(parents=True, exist_ok=True)
    identity = align(PE_OFFSET + len(image))
    descriptor = struct.pack('<IIIIQII32s32sII', 0x4550504d, 1, len(image), len(sections), base,
                             data_rva, machine, hashlib.sha256(raw).digest(), code_hash, len(fixups), 0)
    descriptor += b''.join(struct.pack('<I', rva) for rva in fixups)
    thread_offset = identity + ((len(descriptor) + 7) & -8)
    tramp_start = align(thread_offset + 88) if thread_state else 0
    trampolines, teb_sites, tsd_sites = bytearray(), 0, 0
    if thread_state:
        need(toolchain is not None, 'Pass --toolchain for offline thread-state preparation')
        optional = struct.unpack_from('<I', image, 60)[0] + 24
        trampolines, teb_sites, tsd_sites = rewrite(source, image, optional, base, toolchain,
            output / 'thread-state-scratch', tramp_start, thread_offset + 4)
        digest = hashlib.sha256(struct.pack('<II', machine, len(image)))
        for _, start, end, flags in sections:
            if flags & 0x20000000:
                digest.update(struct.pack('<III', start, end, flags))
                digest.update(image[start:end])
        descriptor = bytearray(descriptor)
        struct.pack_into('<I', descriptor, 4, 2)
        descriptor += bytes(thread_offset - identity - len(descriptor))
        descriptor += struct.pack('<IIQII32s32s', 1, 0, len(trampolines), teb_sites, tsd_sites,
                                  digest.digest(), hashlib.sha256(trampolines).digest())
    linkedit = align(tramp_start + len(trampolines)) if thread_state else align(identity + len(descriptor))
    data_start = PE_OFFSET + data_rva
    # One contiguous code region preserves all original PC-relative addresses.
    text_sections = [('__pe_header', PE_OFFSET, min(s[1] for s in sections), 0),
                     ('__pe_text', PE_OFFSET + min(s[1] for s in sections),
                      data_rva - min(s[1] for s in sections), 0x80000400)]
    data_sections = [('__pe_data', data_start, len(image) - data_rva, 0),
                     ('__pe_identity', identity, len(descriptor), 0)]
    rebase = bytearray(b'\x11')
    for rva in fixups:
        rebase += b'\x21' + uleb(PE_OFFSET + rva - data_start) + b'\x51'
    rebase += b'\0'
    symbols = [('_madeira_pe_image', PE_OFFSET), ('_madeira_pe_identity', identity)]
    if thread_state:
        symbols += [('_madeira_pe_thread_state', thread_offset), ('_madeira_pe_trampolines', tramp_start),
                    ('_madeira_pe_trampolines_end', tramp_start + len(trampolines))]
    trie = exports(symbols)
    rebase_off, export_off = linkedit, (linkedit + len(rebase) + 7) & -8
    symoff = (export_off + len(trie) + 7) & -8
    strings, nlists = bytearray(b'\0'), bytearray()
    for name_symbol, address in symbols:
        section = 1 if address == PE_OFFSET else 5 if thread_state and address >= tramp_start else 4
        nlists += struct.pack('<IBBHQ', len(strings), 0x0f, section, 0, address)
        strings += name_symbol.encode() + b'\0'
    stroff = symoff + len(nlists)
    total = stroff + len(strings)
    commands = [segment('__TEXT', 0, data_start, 5, text_sections),
                segment('__DATA', data_start, (tramp_start if thread_state else linkedit) - data_start, 3, data_sections)]
    if thread_state:
        commands.append(segment('__THREAD', tramp_start, linkedit - tramp_start, 5,
                                [('__teb', tramp_start, len(trampolines), 0x80000400)]))
    commands.append(segment('__LINKEDIT', linkedit, align(total - linkedit), 1, []))
    # LINKEDIT has a virtual page-rounded extent but only its actual file bytes.
    link_segment = bytearray(commands[-1])
    struct.pack_into('<Q', link_segment, 48, total - linkedit)
    commands[-1] = bytes(link_segment)
    commands += [dylib(0x0d, '@rpath/' + name + '.framework/' + name),
                 dylib(0x0c, '/usr/lib/libSystem.B.dylib'),
                 struct.pack('<IIIIII', 0x32, 24, 2 if sdk == 'iphoneos' else 1,
                             0x110000 if sdk == 'iphoneos' else 0x0d0000,
                             0x110000 if sdk == 'iphoneos' else 0x0d0000, 0),
                 struct.pack('<II16s', 0x1b, 24, hashlib.sha256(raw + sdk.encode()).digest()[:16]),
                 struct.pack('<IIIIIIIIIIII', 0x80000022, 48, rebase_off, len(rebase), 0, 0, 0, 0, 0, 0, export_off, len(trie)),
                 struct.pack('<IIIIII', 0x02, 24, symoff, len(symbols), stroff, len(strings)),
                 struct.pack('<' + 'I' * 20, 0x0b, 80, 0, 0, 0, len(symbols), len(symbols), 0, *([0] * 12))]
    header = struct.pack('<IIIIIIII', 0xfeedfacf, 0x100000c, 0, 6, len(commands),
                         sum(map(len, commands)), 0x100085, 0)
    need(len(header) + sum(map(len, commands)) < PE_OFFSET, 'Mach-O commands exceed header reservation')
    binary = bytearray(total)
    binary[:len(header)] = header
    cursor = len(header)
    for command in commands:
        binary[cursor:cursor + len(command)] = command
        cursor += len(command)
    binary[PE_OFFSET:PE_OFFSET + len(image)] = image
    binary[identity:identity + len(descriptor)] = descriptor
    if thread_state:
        binary[tramp_start:tramp_start + len(trampolines)] = trampolines
    binary[rebase_off:rebase_off + len(rebase)] = rebase
    binary[export_off:export_off + len(trie)] = trie
    binary[symoff:symoff + len(nlists)] = nlists
    binary[stroff:stroff + len(strings)] = strings
    executable = bundle / name
    executable.write_bytes(binary)
    executable.chmod(0o755)
    (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.madeira.signed-pe.' + code_hash.hex(),
        'CFBundleExecutable': name, 'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1',
        'CFBundleShortVersionString': '1.0', 'CFBundleSupportedPlatforms': ['iPhoneOS' if sdk == 'iphoneos' else 'MacOSX']}))
    result = {'source': str(source.resolve()), 'source_sha256': hashlib.sha256(raw).hexdigest(),
              'code_sha256': code_hash.hex(), 'image_size': len(image), 'machine': hex(machine),
              'data_relocations': len(fixups), 'code_bytes_changed': 4 * (teb_sites + tsd_sites),
              'offline_teb_rewrites': teb_sites, 'offline_tsd_rewrites': tsd_sites,
              'sdk': sdk, 'framework': str(bundle.resolve())}
    (bundle / 'preparation.json').write_text(json.dumps(result, indent=2) + '\n')
    # Bundle resources must be final before signing.
    subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(bundle)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--sdk', choices=['macosx', 'iphoneos'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--thread-state', action='store_true')
    parser.add_argument('--toolchain', type=Path)
    parser.add_argument('pe', type=Path, nargs='+')
    args = parser.parse_args()
    for path in args.pe:
        print(json.dumps(prepare(path, args.output, args.sdk, args.thread_state, args.toolchain)))
