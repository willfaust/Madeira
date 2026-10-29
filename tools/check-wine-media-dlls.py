#!/usr/bin/env python3
"""Require the Wine WMVCORE frontend and its reader dependency in the IPA farm.

Checks actual PE exports and import closure after the optional extra-DLL build.
Does not claim codec support or change the existing 64-bit backend opt-in.
"""
from pathlib import Path
import struct
import sys


class PE:
    def __init__(self, path, *, machines=(0x8664, 0xa641, 0xa64e), require_dll=True):
        self.data = path if isinstance(path, bytes) else Path(path).read_bytes()
        if self.data[:2] != b'MZ':
            raise ValueError('missing DOS header')
        pe = self.unpack('<I', 0x3c)[0]
        if self.data[pe:pe + 4] != b'PE\0\0':
            raise ValueError('missing PE signature')
        machine, sections = self.unpack('<HH', pe + 4)
        optional_size, flags = self.unpack('<HH', pe + 20)
        optional = pe + 24
        if machine not in machines or (require_dll and not flags & 0x2000):
            raise ValueError('expected a 64-bit x64/ARM64EC/ARM64X DLL')
        if optional_size < 224 or self.unpack('<H', optional)[0] != 0x20b:
            raise ValueError('missing PE32+ optional header')
        if self.unpack('<I', optional + 108)[0] < 14:
            raise ValueError('missing data directory entries')
        self.directories = [self.unpack('<II', optional + 112 + i * 8) for i in range(14)]
        self.sections = []
        if not 0 < sections <= 96:
            raise ValueError('invalid section count')
        for i in range(sections):
            virtual_size, rva, raw_size, raw = self.unpack('<IIII', optional + optional_size + i * 40 + 8)
            if raw > len(self.data) or raw_size > len(self.data) - raw:
                raise ValueError('truncated section')
            self.sections.append((rva, raw_size, raw))

    def unpack(self, fmt, offset):
        size = struct.calcsize(fmt)
        if offset < 0 or offset > len(self.data) - size:
            raise ValueError('truncated PE field')
        return struct.unpack_from(fmt, self.data, offset)

    def offset(self, rva, size=1):
        for start, length, raw in self.sections:
            if start <= rva and rva - start + size <= length:
                return raw + rva - start
        raise ValueError('RVA outside file-backed sections')

    def name(self, rva):
        offset = self.offset(rva)
        end = self.data.find(b'\0', offset, offset + 512)
        if end < 0:
            raise ValueError('unterminated PE name')
        self.offset(rva, end - offset + 1)
        return self.data[offset:end].decode('ascii')

    def exports(self):
        rva, size = self.directories[0]
        if not rva or size < 40:
            raise ValueError('missing export directory')
        fields = self.unpack('<IIHHIIIIIII', self.offset(rva, 40))
        funcs, count, addresses, names, ordinals = fields[6:]
        if count > funcs or funcs > 65536:
            raise ValueError('invalid export counts')
        result = {}
        for i in range(count):
            name = self.name(self.unpack('<I', self.offset(names + i * 4, 4))[0])
            ordinal = self.unpack('<H', self.offset(ordinals + i * 2, 2))[0]
            if ordinal >= funcs:
                raise ValueError('invalid export ordinal')
            address = self.unpack('<I', self.offset(addresses + ordinal * 4, 4))[0]
            result[name] = bool(address and not rva <= address < rva + size)
            if result[name]:
                self.offset(address)
        return result

    def imports(self, delayed=False):
        rva, size = self.directories[13 if delayed else 1]
        if not rva:
            return set()
        width, name_offset = (32, 4) if delayed else (20, 12)
        result = set()
        for i in range(min(size // width, 256)):
            descriptor = self.offset(rva + i * width, width)
            fields = self.unpack('<' + 'I' * (width // 4), descriptor)
            if not any(fields):
                return result
            if delayed and not fields[0] & 1:
                raise ValueError('unsupported VA-based delay import')
            result.add(self.name(self.unpack('<I', descriptor + name_offset)[0]).lower())
        raise ValueError('unterminated import directory')


def check(bundle):
    bundle = Path(bundle)
    shipped = {p.name.lower(): p for p in bundle.iterdir() if p.is_file()}
    required = {
        'wmvcore.dll': ('WMCreateReader', 'WMCreateSyncReader', 'WMCreateProfileManager'),
        'winegstreamer.dll': ('winegstreamer_create_wm_sync_reader',),
    }
    for name, functions in required.items():
        if name not in shipped:
            raise ValueError('missing required ' + name)
        module = PE(shipped[name])
        exports = module.exports()
        if any(not exports.get(function) for function in functions):
            raise ValueError(name + ': missing implemented reader exports')
        imports, delayed = module.imports(), module.imports(True)
        if name == 'wmvcore.dll' and 'winegstreamer.dll' not in imports:
            raise ValueError('wmvcore reader must import its real winegstreamer frontend')
        if delayed:
            raise ValueError(name + ': ARM64EC reader dependencies must use regular imports')
        missing = {dep for dep in imports if dep not in shipped and
                   not (dep.startswith(('api-ms-', 'ext-ms-')) and 'apisetschema.dll' in shipped)}
        if missing:
            raise ValueError(name + ': missing imports ' + ', '.join(sorted(missing)))
        print(name + ': implemented reader exports; all regular imports packaged')


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('usage: check-wine-media-dlls.py <arm64ec-windows directory>')
        check(sys.argv[1])
    except (OSError, ValueError, UnicodeError) as error:
        sys.exit('Wine media DLL check failed: ' + str(error))
