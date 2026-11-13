"""Prepare ARM64EC TEB reads before signing; runtime writes only a data slot."""
import re
import struct
import subprocess


def text_section(path):
    raw = path.read_bytes()
    if struct.unpack_from('<I', raw)[0] != 0xfeedfacf:
        raise ValueError('Expected an ARM64 Mach-O object')
    off = 32
    for _ in range(struct.unpack_from('<I', raw, 16)[0]):
        command, size = struct.unpack_from('<II', raw, off)
        if command == 0x19:
            for i in range(struct.unpack_from('<I', raw, off + 64)[0]):
                s = off + 72 + i * 80
                if raw[s:s + 16].split(b'\0')[0] == b'__text':
                    length, position = struct.unpack_from('<QI', raw, s + 40)
                    return raw[position:position + length]
        off += size
    raise ValueError('Missing assembler text')


def branch(start, end):
    delta = end - start
    if delta % 4 or not -(1 << 27) <= delta < (1 << 27):
        raise ValueError('Thread-state trampoline exceeds branch reach')
    return 0x14000000 | ((delta // 4) & 0x3ffffff)


def rewrite(source, image, optional, base, toolchain, scratch, tramp_start, slot):
    if struct.unpack_from('<H', image, optional - 20)[0] != 0x8664:
        raise ValueError('Thread rewriting requires ARM64EC reserved registers')
    config = struct.unpack_from('<I', image, optional + 192)[0]
    metadata = struct.unpack_from('<Q', image, config + 200)[0] - 16384
    table, count = struct.unpack_from('<II', image, metadata + 4)
    if not 0 < count <= len(image) // 8 or not 0 <= table <= len(image) - count * 8:
        raise ValueError('Invalid ARM64EC code map')
    ranges = []
    for i in range(count):
        start, length = struct.unpack_from('<II', image, table + i * 8)
        if start & 3 == 1:
            if length % 4 or (start & ~3) > len(image) - length:
                raise ValueError('Invalid native ARM64EC code range')
            ranges.append((start & ~3, (start & ~3) + length))
    dump = subprocess.check_output([str(toolchain / 'llvm-objdump'), '-d', '--no-show-raw-insn', str(source)], text=True)
    sites, triplets = [], []
    for line in dump.splitlines():
        match = re.match(r'\s*([0-9a-fA-F]+):\s+(.*)', line)
        if not match:
            continue
        rva = int(match[1], 16) - base
        if not any(a <= rva < b for a, b in ranges):
            continue
        instruction = match[2].split(';')[0].strip()
        if instruction.startswith('.'):
            continue
        if re.search(r'\b[wx](?:13|14)\b', instruction):
            raise ValueError(f'ARM64EC reserved scratch register used at {rva:x}')
        word = struct.unpack_from('<I', image, rva)[0]
        if re.search(r'\b[wx]18\b', instruction):
            mnemonic, operands = instruction.split(None, 1)
            if mnemonic not in ('ldr', 'ldrb', 'ldrh', 'ldrsw', 'ldur', 'ldp', 'str', 'strb', 'strh', 'stur', 'stp', 'add', 'sub', 'mov'):
                raise ValueError(f'Unsupported TEB instruction: {instruction}')
            written = operands.split('[', 1)[0] if mnemonic.startswith('ld') else operands.split(',', 1)[0]
            if not mnemonic.startswith('st') and re.search(r'\b[wx]18\b', written):
                raise ValueError(f'Writing the TEB register is unsupported: {instruction}')
            if '!' in operands or re.search(r'\],\s*#', operands):
                raise ValueError(f'TEB writeback is unsupported: {instruction}')
            sites.append((rva, instruction, re.sub(r'\b([wx])18\b', r'\g<1>13', instruction), word))
        if rva + 12 <= len(image) and word & 0xffffffe0 == 0xd53bd060:
            reg = word & 31
            second, third = struct.unpack_from('<II', image, rva + 4)
            if second == (0x927df000 | reg << 5 | reg) and third & 0xffc003ff == (0xf9400000 | reg << 5 | reg):
                triplets.append((rva + 8, reg))
    scratch.mkdir(parents=True, exist_ok=True)
    assembly, obj = scratch / 'thread-registers.S', scratch / 'thread-registers.o'
    if sites:
        assembly.write_text('.text\n.p2align 2\n' + '\n'.join(x for _, old, new, _ in sites for x in (old, new)) + '\n')
        subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-macos13.0', '-c', str(assembly), '-o', str(obj)], check=True)
        encoded = text_section(obj)
        if len(encoded) != len(sites) * 8:
            raise ValueError('Thread-state assembly size differs')
    else:
        encoded = b''
    trampolines = bytearray()

    def offset_load():
        pc = tramp_start + len(trampolines)
        delta = (slot >> 12) - (pc >> 12)
        if not -(1 << 20) <= delta < (1 << 20) or slot % 4:
            raise ValueError('Thread-state data slot exceeds ADRP reach')
        value = delta & 0x1fffff
        return [0x9000000e | (value & 3) << 29 | (value >> 2) << 5,
                0xb94001ce | ((slot & 4095) // 4) << 10]

    for index, (rva, original, _, word) in enumerate(sites):
        old, new = struct.unpack_from('<II', encoded, index * 8)
        if old != word:
            raise ValueError(f'Assembler round-trip differs at {rva:x}: {original}')
        target = tramp_start + len(trampolines)
        trampolines += struct.pack('<II', 0xd53bd06d, 0x927df1ad)
        words = offset_load() + [0xf86e69ad, new]
        trampolines += struct.pack('<' + 'I' * len(words), *words)
        trampolines += struct.pack('<I', branch(tramp_start + len(trampolines), 16384 + rva + 4))
        struct.pack_into('<I', image, rva, branch(16384 + rva, target))
    for rva, reg in triplets:
        target = tramp_start + len(trampolines)
        words = offset_load() + [0xf86e6800 | reg << 5 | reg]
        trampolines += struct.pack('<III', *words)
        trampolines += struct.pack('<I', branch(tramp_start + len(trampolines), 16384 + rva + 4))
        struct.pack_into('<I', image, rva, branch(16384 + rva, target))
    for path in (assembly, obj):
        if path.exists():
            path.unlink()
    return trampolines, len(sites), len(triplets)
