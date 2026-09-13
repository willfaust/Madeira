"""Reject incomplete unsigned Madeira bundles; does not prove runtime compatibility."""
import argparse
import io
import plistlib
import struct
import sys
import tarfile
import zipfile
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def macho(data, filetype):
    require(len(data) >= 32, 'missing or truncated Mach-O header')
    magic, cpu, _, kind, commands, command_bytes = struct.unpack_from('<6I', data)
    require(magic == 0xFEEDFACF and cpu == 0x0100000C,
            'expected a thin ARM64 Mach-O binary')
    require(kind == filetype, 'unexpected Mach-O file type')
    require(commands > 0 and 32 + command_bytes <= len(data),
            'missing or truncated Mach-O load commands')


def archive(path):
    data = path.read_bytes()
    require(data[:8] == b'!<arch>\n', f'{path}: not an archive')
    offset, objects = 8, 0
    while offset < len(data):
        header = data[offset:offset + 60]
        require(len(header) == 60 and header[58:] == b'`\n', 'invalid archive member')
        size = int(header[48:58].strip())
        require(size >= 0, 'negative archive member size')
        body = data[offset + 60:offset + 60 + size]
        require(len(body) == size, 'truncated archive member')
        name = header[:16].strip()
        if name.startswith(b'#1/'):
            length = int(name[3:])
            require(length <= size, 'invalid BSD archive name')
            name, body = body[:length].rstrip(b'\x00'), body[length:]
        if name not in (b'/', b'//', b'/SYM64/') and not name.startswith(b'__.SYMDEF'):
            macho(body, 1)
            objects += 1
        offset += 60 + size + size % 2
    require(objects > 0, f'{path}: empty/placeholder archive')


def pe(data, machine):
    require(len(data) >= 64 and data[:2] == b'MZ', 'missing or truncated DOS header')
    offset = struct.unpack_from('<I', data, 60)[0]
    require(offset >= 64 and offset + 24 <= len(data), 'invalid PE header offset')
    require(data[offset:offset + 4] == b'PE\0\0', 'missing PE signature')
    cpu, sections = struct.unpack_from('<HH', data, offset + 4)
    optional_size = struct.unpack_from('<H', data, offset + 20)[0]
    require(cpu == machine and sections > 0, 'wrong PE architecture or no sections')
    table = offset + 24 + optional_size
    require(optional_size >= 112 and table + sections * 40 <= len(data),
            'truncated PE optional header or section table')
    require(struct.unpack_from('<H', data, offset + 24)[0] == 0x20B, 'expected PE32+')
    for index in range(sections):
        size, start = struct.unpack_from('<II', data, table + index * 40 + 16)
        require(size == 0 or start + size <= len(data), 'truncated PE section')


def runtime_resources(read):
    for name in ('concrt140', 'msvcp140', 'msvcp140_1', 'msvcp140_2',
                 'msvcp140_atomic_wait', 'msvcp140_codecvt_ids', 'vcamp140',
                 'vccorlib140', 'vcomp140', 'vcruntime140', 'vcruntime140_1',
                 'vcruntime140_threads'):
        pe(read(f'x86_64-vcruntime/{name}.dll'), 0x8664)
    for directory, machine in (('aarch64-windows', 0xAA64),
                               ('arm64ec-windows', 0x8664)):
        # The four DXMT modules are built once per architecture. Wine loads the
        # arm64ec set for x64 guests -- which is every real game -- so a stale or
        # wrong-arch copy here is a shipping regression even when the other
        # directory validates cleanly.
        for name in ('d3d11', 'dxgi', 'winemetal', 'd3d10core'):
            pe(read(f'{directory}/{name}.dll'), machine)
        for name in ('ntdll', 'kernel32', 'kernelbase', 'user32', 'win32u'):
            pe(read(f'{directory}/{name}.dll'), machine)
    pe(read('arm64ec-windows/xtajit64.dll'), 0x8664)
    pe(read('arm64ec-windows/cube-x64.exe'), 0x8664)
    with tarfile.open(fileobj=io.BytesIO(read('prefix-template.tar.gz')), mode='r:gz') as prefix:
        for name in ('system.reg', 'user.reg', 'userdef.reg'):
            member = prefix.getmember(f'prefix/{name}')
            require(member.isfile() and member.size > 0, f'missing prefix registry: {name}')
            require(len(prefix.extractfile(member).read()) == member.size,
                    f'truncated prefix registry: {name}')
        require(prefix.getmember('prefix/drive_c/windows/system32').isdir(),
                'missing prefix system32 directory')


def bundle(read):
    info = plistlib.loads(read('Info.plist'))
    if not isinstance(info, dict):
        raise ValueError('Info.plist root is not a dictionary')
    executable = info.get('CFBundleExecutable', '')
    require(executable and Path(executable).name == executable,
            'invalid CFBundleExecutable')
    macho(read(executable), 2)
    runtime_resources(read)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--app', type=Path)
    group.add_argument('--ipa', type=Path)
    group.add_argument('--archive', type=Path)
    group.add_argument('--resources', type=Path,
                       help='validate runtime inputs before compiling the app')
    args = parser.parse_args()
    try:
        if args.archive:
            archive(args.archive)
        elif args.resources:
            runtime_resources(lambda name: (args.resources / name).read_bytes())
        elif args.app:
            bundle(lambda name: (args.app / name).read_bytes())
        else:
            with zipfile.ZipFile(args.ipa) as package:
                bundle(lambda name: package.read('Payload/Madeira.app/' + name))
    except (OSError, ValueError, KeyError, AttributeError, RuntimeError, struct.error, zipfile.BadZipFile,
            plistlib.InvalidFileException, tarfile.TarError, EOFError) as error:
        print(f'INVALID: {error}', file=sys.stderr)
        return 1
    print('Structural validation passed; signing and device execution remain untested.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
