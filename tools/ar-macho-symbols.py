"""List defined global symbols in a static archive; Python stdlib only.

Replaces `nm -gU` for the GnuTLS symtab generator. Rationale: a bare `nm`
invocation hung a CI job for 4.5 hours with no output, and macOS ships no
`timeout(1)` to bound it. Every read below is capped by header-declared
sizes (with sanity caps), so corrupt input fails fast with a clear error
instead of hanging or spinning.

Scope is deliberately narrow: regular (`!<arch>`) archives of little-endian
Mach-O objects (32- or 64-bit) — the iOS universe. Anything else (thin
archives, other object formats) raises ValueError with a clear message.

Usage: python3 ar-macho-symbols.py <archive.a>  (prints one symbol per line)
"""

import struct
import sys

_AR_MAGIC = b'!<arch>\n'
_THIN_MAGIC = b'!<thin>\n'
_HEADER_LEN = 60

_MH_MAGIC_64_LE = 0xFEEDFACF
_MH_MAGIC_32_LE = 0xFEEDFACE
_LC_SYMTAB = 0x2

_N_STAB_MASK = 0xE0
_N_TYPE_MASK = 0x0E
_N_UNDF = 0x0
_N_EXT = 0x01

_MAX_SYMBOLS_PER_OBJECT = 1000000
_MAX_COMMANDS = 10000


def _error(message):
    raise ValueError(message)


def _parse_ar_members(data):
    """Yield (name, member-bytes) for each data member of the archive."""
    if data[:8] == _THIN_MAGIC:
        _error('thin archives are not supported (members live outside the file)')
    if data[:8] != _AR_MAGIC:
        _error('not a regular archive (bad magic)')
    extended_names = b''
    offset = 8
    while offset < len(data):
        if offset + _HEADER_LEN > len(data):
            _error('truncated archive member header at offset %d' % offset)
        header = data[offset:offset + _HEADER_LEN]
        if header[58:60] != b'`\n':
            _error('bad archive header terminator at offset %d' % offset)
        try:
            size = int(header[48:58].decode('ascii').strip())
        except ValueError:
            _error('bad archive member size at offset %d' % offset)
        if size < 0:
            _error('negative archive member size at offset %d' % offset)
        # Padding aligns the NEXT member: it keys off the full member size,
        # including any BSD long name below, so snapshot it first.
        pad = size & 1
        raw_name = header[:16].decode('ascii')
        content_start = offset + _HEADER_LEN
        if content_start + size > len(data):
            _error('truncated archive member at offset %d' % offset)
        name = raw_name
        if raw_name.startswith('#1/'):
            # BSD long name: length follows, name bytes lead the content.
            try:
                name_len = int(raw_name[3:].strip())
            except ValueError:
                _error('bad BSD long-name length at offset %d' % offset)
            if name_len < 0 or name_len > size:
                _error('bad BSD long-name length at offset %d' % offset)
            name = data[content_start:content_start + name_len].decode('ascii', errors='replace').rstrip('\0')
            content_start += name_len
            size -= name_len
        elif raw_name.startswith('/'):
            # SysV extended name (offset into the // table) or a special
            # member (symbol table / name table), which is skipped.
            short = raw_name.strip()
            if short == '//':
                extended_names = data[content_start:content_start + size]
                offset = content_start + size + pad
                continue
            if short in ('/', '/SYMDEF', '/SYMDEF SORTED'):
                offset = content_start + size + pad
                continue
            stripped = raw_name[1:].strip()
            if not stripped.isdigit():
                # Unknown special member: skip rather than misparse.
                offset = content_start + size + pad
                continue
            pos = int(stripped)
            end = extended_names.find(b'/\n', pos)
            if end < 0:
                _error('bad extended-name offset at offset %d' % offset)
            name = extended_names[pos:end].decode('ascii', errors='replace')
        if content_start + size > len(data):
            _error('truncated archive member %r' % name)
        yield name.strip(), data[content_start:content_start + size]
        offset = content_start + size + pad


def _parse_macho_defined(macho):
    """Defined global symbol names (underscore stripped) in one object file."""
    if len(macho) < 32:
        return None  # too small to be a Mach-O object; not an error
    (magic,) = struct.unpack_from('<I', macho, 0)
    if magic == _MH_MAGIC_64_LE:
        bits, prefix = 64, '<'
        header_size, cmd_off = 32, 32
    elif magic == _MH_MAGIC_32_LE:
        bits, prefix = 32, '<'
        header_size, cmd_off = 28, 28
    else:
        return None  # not a little-endian Mach-O object; skip
    if len(macho) < header_size:
        return None
    ncmds = struct.unpack_from(prefix + 'I', macho, 16)[0]
    if ncmds > _MAX_COMMANDS:
        _error('implausible load-command count %d' % ncmds)
    symoff = strofd = None
    nsyms = strsize = 0
    offset = cmd_off
    for _ in range(ncmds):
        if offset + 8 > len(macho):
            _error('truncated load command')
        cmd, cmdsize = struct.unpack_from(prefix + 'II', macho, offset)
        if cmdsize < 8 or offset + cmdsize > len(macho):
            _error('bad load-command size %d' % cmdsize)
        if cmd == _LC_SYMTAB:
            if cmdsize < 24:
                _error('truncated LC_SYMTAB command')
            symoff, nsyms, strofd, strsize = struct.unpack_from(prefix + 'IIII', macho, offset + 8)
        offset += cmdsize
    if symoff is None:
        return []  # object without a symbol table (e.g. empty TU)
    entry_size = 16 if bits == 64 else 12
    if nsyms > _MAX_SYMBOLS_PER_OBJECT:
        _error('implausible symbol count %d' % nsyms)
    if symoff + nsyms * entry_size > len(macho):
        _error('symbol table runs past end of object')
    if strofd + strsize > len(macho):
        _error('string table runs past end of object')
    names = []
    for i in range(nsyms):
        base = symoff + i * entry_size
        if bits == 64:
            n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from('<IBBHQ', macho, base)
        else:
            n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from('<IBBHI', macho, base)
        if n_type & _N_STAB_MASK:
            continue  # debugging symbol
        if not (n_type & _N_EXT):
            continue  # not global
        kind = n_type & _N_TYPE_MASK
        if kind == _N_UNDF and n_value == 0:
            continue  # undefined reference, not a definition
        if n_strx >= strsize:
            _error('string-table index out of range')
        end = macho.find(b'\0', strofd + n_strx, strofd + strsize)
        if end < 0:
            _error('unterminated string-table entry')
        name = macho[strofd + n_strx:end].decode('ascii', errors='replace')
        names.append(name[1:] if name.startswith('_') else name)
    return names


def defined_symbols(archive_path):
    """Sorted unique defined-global symbol names in the archive."""
    with open(archive_path, 'rb') as stream:
        data = stream.read()
    found = set()
    for _, member in _parse_ar_members(data):
        names = _parse_macho_defined(member)
        if names:
            found.update(names)
    return sorted(found)


def main(argv):
    if len(argv) != 2:
        print('usage: ar-macho-symbols.py <archive.a>', file=sys.stderr)
        return 2
    try:
        for name in defined_symbols(argv[1]):
            print(name)
    except (OSError, ValueError) as error:
        print('ar-macho-symbols failed: %s' % error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
