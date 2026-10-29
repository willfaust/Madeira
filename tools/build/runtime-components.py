#!/usr/bin/env python3
"""Build, retain, and validate the runtime files used by both local and CI IPAs."""
import argparse
import fnmatch
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = json.loads((ROOT / 'tools/build/runtime-components.json').read_text())
MANIFEST = 'runtime-build.json'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()


def sdk_key():
    if os.environ.get('MADEIRA_RUNTIME_SDK'):
        return os.environ['MADEIRA_RUNTIME_SDK']
    with tempfile.NamedTemporaryFile() as output:
        subprocess.run(['bash', str(ROOT / 'tools/build/ci-input-key.sh')], cwd=ROOT,
                       env=dict(os.environ, GITHUB_OUTPUT=output.name), check=True)
        return dict(line.split('=', 1) for line in Path(output.name).read_text().splitlines())['key']


def input_key(name, sdk):
    spec = CONTRACT[name]
    paths = git('ls-files', '--cached', '--others', '--exclude-standard').splitlines()
    inputs = {p: digest((ROOT / p).read_bytes()) for p in paths
              if p != 'tools/build/runtime-components.json' and (ROOT / p).is_file()
              and any(fnmatch.fnmatchcase(p, pattern) for pattern in spec['inputs'])}
    pins = {p: git('rev-parse', f'HEAD:{p}') for p in spec['pins']}
    if name == 'windows':
        # The inventory selects Wine targets. Diagnostic test programs remain
        # versioned inputs rather than part of the production DLL rebuild.
        for p in spec['prebuilt']:
            inputs[p] = digest((ROOT / 'app/Madeira' / p).read_bytes())
        tracked = git('ls-files').splitlines()
        inputs['farm-inventory'] = digest('\n'.join(p for p in tracked if p.startswith(
            ('app/Madeira/arm64ec-windows/', 'app/Madeira/aarch64-windows/'))).encode())
    return digest(json.dumps([sdk, spec, inputs, pins], sort_keys=True).encode())


def owns(name, path):
    if path.endswith(('/README.md', '/.gitkeep')):
        return False
    if name == 'windows' and path in CONTRACT['dock']['outputs']:
        return False
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in CONTRACT[name]['outputs'])


def safe_path(path):
    p = PurePosixPath(path)
    if not path or p.is_absolute() or '..' in p.parts or str(p) != path or '\\' in path:
        raise ValueError(f'unsafe runtime path: {path}')
    return path


def check_binary(path, data):
    if not data:
        raise ValueError(f'empty runtime file: {path}')
    if path.endswith(('.dll', '.exe', '.drv', '.cpl', '.acm', '.ax', '.ocx')):
        if len(data) < 64 or data[:2] != b'MZ':
            raise ValueError(f'not a PE binary: {path}')
        pe = struct.unpack_from('<I', data, 0x3c)[0]
        if pe + 24 > len(data) or data[pe:pe + 4] != b'PE\0\0':
            raise ValueError(f'invalid PE header: {path}')
        machine = struct.unpack_from('<H', data, pe + 4)[0]
        expected = {0xa641, 0x8664} if path.startswith('arm64ec-windows/') else {0xaa64}
        if path.startswith(('x86_64-opengl/', 'compat/love/')):
            expected = {0x8664}
        elif path.startswith('vulkan/'):
            expected = {0xa641, 0x8664}
        elif path.startswith('i386-windows/'):
            expected = {0x14c}
        if path.endswith('/dockhost.exe'):
            expected = {0x8664}
        if machine not in expected:
            raise ValueError(f'wrong PE architecture 0x{machine:x}: {path}')
    elif path.endswith('.dylib'):
        if len(data) < 32 or struct.unpack_from('<II', data) != (0xfeedfacf, 0x100000c):
            raise ValueError(f'not an arm64 Mach-O dylib: {path}')
        ncmds, size = struct.unpack_from('<II', data, 16)
        if struct.unpack_from('<I', data, 12)[0] != 6:
            raise ValueError(f'not a Mach-O dynamic library: {path}')
        if size > len(data) - 32:
            raise ValueError(f'invalid Mach-O commands: {path}')
        offset, ios = 32, False
        for _ in range(ncmds):
            if offset + 8 > 32 + size:
                raise ValueError(f'truncated Mach-O command: {path}')
            cmd, length = struct.unpack_from('<II', data, offset)
            if length < 8 or offset + length > 32 + size:
                raise ValueError(f'invalid Mach-O command: {path}')
            if cmd in (0xc, 0x80000018, 0x8000001f, 0x80000023):
                if length < 24:
                    raise ValueError(f'truncated dylib dependency: {path}')
                start = struct.unpack_from('<I', data, offset + 8)[0]
                end = data.find(b'\0', offset + start, offset + length)
                if start < 24 or start >= length or end < 0:
                    raise ValueError(f'invalid dylib dependency: {path}')
                dependency = data[offset + start:end].decode('utf-8')
                bundled = {PurePosixPath(p).name for spec in CONTRACT.values() for p in spec['required']}
                if not dependency.startswith(('/usr/lib/', '/System/Library/')) and not (
                    dependency.startswith(('@rpath/', '@loader_path/')) and PurePosixPath(dependency).name in bundled
                ):
                    raise ValueError(f'unbundled dylib dependency {dependency}: {path}')
            if cmd == 0x32 and length >= 24:
                ios = struct.unpack_from('<I', data, offset + 8)[0] == 2
            elif cmd == 0x25:  # LC_VERSION_MIN_IPHONEOS, used by older recipes
                ios = True
            offset += length
        if not ios:
            raise ValueError(f'not built for an iOS device: {path}')


def missing_imports(files):
    spec = importlib.util.spec_from_file_location('wine_pe', ROOT / 'tools/check-wine-media-dlls.py')
    reader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reader)
    missing = set()
    for path, data in files.items():
        if data[:2] != b'MZ':
            continue
        pe = reader.PE(data, machines=(0x8664, 0xa641, 0xa64e, 0xaa64), require_dll=False)
        for dep in pe.imports() | pe.imports(delayed=True):
            if dep not in files and not (dep.startswith(('api-ms-', 'ext-ms-')) and 'apisetschema.dll' in files):
                missing.add(dep)
    return missing


def validate_manifest(name, manifest, read, sdk):
    if manifest.get('schema') != 1 or manifest.get('key') != input_key(name, sdk):
        raise ValueError(f'{name}: source or SDK does not match')
    files = manifest.get('files', {})
    required = set(CONTRACT[name]['required'])
    if name == 'windows':
        required |= {p.removeprefix('app/Madeira/') for p in git('ls-files', 'app/Madeira').splitlines()
                     if owns(name, p.removeprefix('app/Madeira/'))}
    if not isinstance(files, dict) or not required <= files.keys():
        raise ValueError(f'{name}: required runtime files are missing')
    farms = {'arm64ec-windows': {}, 'aarch64-windows': {}}
    for path, sha in files.items():
        safe_path(path)
        if not owns(name, path):
            raise ValueError(f'{name}: unexpected runtime file: {path}')
        data = read(path)
        check_binary(path, data)
        if digest(data) != sha:
            raise ValueError(f'{name}: runtime checksum mismatch: {path}')
        folder = str(PurePosixPath(path).parent)
        if name == 'windows' and folder in farms:
            farms[folder][PurePosixPath(path).name.lower()] = data
    if name == 'windows':
        for folder, contents in farms.items():
            missing = missing_imports(contents)
            if missing:
                raise ValueError(f'{folder}: missing imported DLLs: {sorted(missing)}')


def read_regular(base, path):
    p = base / safe_path(path)
    if p.is_symlink() or not p.is_file() or base.resolve() not in p.resolve().parents:
        raise ValueError(f'missing or unsafe runtime file: {p}')
    return p.read_bytes()


def cache_dir(name):
    return ROOT / '.runtime-cache' / name


def stage(name, sdk):
    cache = cache_dir(name)
    manifest = json.loads((cache / 'manifest.json').read_text())
    validate_manifest(name, manifest, lambda p: read_regular(cache / 'files', p), sdk)
    for path in manifest['files']:
        dest = ROOT / 'app/Madeira' / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.is_symlink():
            raise ValueError(f'refusing to replace symlink: {dest}')
        shutil.copyfile(cache / 'files' / path, dest)
    return manifest


def snapshot(name, sdk):
    bundle = ROOT / 'app/Madeira'
    files = {p.relative_to(bundle).as_posix(): digest(p.read_bytes())
             for p in bundle.rglob('*') if p.is_file() and owns(name, p.relative_to(bundle).as_posix())}
    manifest = {'schema': 1, 'key': input_key(name, sdk), 'files': files}
    validate_manifest(name, manifest, lambda p: read_regular(bundle, p), sdk)
    cache = cache_dir(name)
    cache.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=cache.parent) as tmp:
        tmp = Path(tmp)
        for path in files:
            dest = tmp / 'files' / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(bundle / path, dest)
        (tmp / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
        if cache.exists():
            shutil.rmtree(cache)
        shutil.copytree(tmp, cache)
    return manifest


def build(name, sdk):
    if os.environ.get('MADEIRA_RUNTIME_REUSE') == '1':
        try:
            stage(name, sdk)
            print(f'{name}: verified exact source/SDK cache', flush=True)
            return
        except (OSError, ValueError, KeyError) as error:
            print(f'{name}: rebuild required: {error}', flush=True)
    subprocess.run(['bash', str(ROOT / 'tools/build/build-runtime-component.sh'), name], cwd=ROOT, check=True)
    snapshot(name, sdk)


def bundle_manifest(bundle, sdk):
    components = {}
    for name in CONTRACT:
        cached = json.loads((cache_dir(name) / 'manifest.json').read_text())
        validate_manifest(name, cached, lambda p: read_regular(ROOT / 'app/Madeira', p), sdk)
        # Xcode re-signs dylibs. Retain source keys and record their final hashes.
        final = dict(cached, files={p: digest(read_regular(bundle, p)) for p in cached['files']})
        for path in final['files']:
            data = read_regular(bundle, path)
            check_binary(path, data)
            if not path.endswith('.dylib') and digest(data) != cached['files'][path]:
                raise ValueError(f'Xcode copied different runtime bytes: {path}')
        components[name] = final
    (bundle / MANIFEST).write_text(json.dumps({
        'schema': 1, 'tree': git('rev-parse', 'HEAD^{tree}'), 'components': components,
    }, sort_keys=True, indent=2) + '\n')


def validate_ipa(ipa, sdk):
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('duplicate IPA entries')
        for entry in archive.infolist():
            safe_path(entry.filename.rstrip('/'))
            if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError(f'IPA symlink is not supported: {entry.filename}')
        prefix = 'Payload/Madeira.app/'
        manifest = json.loads(archive.read(prefix + MANIFEST))
        if manifest.get('schema') != 1 or manifest.get('tree') != git('rev-parse', 'HEAD^{tree}'):
            raise ValueError('IPA manifest does not match this source tree')
        if set(manifest.get('components', {})) != set(CONTRACT):
            raise ValueError('IPA is missing runtime components')
        for name in CONTRACT:
            validate_manifest(name, manifest['components'][name], lambda p: archive.read(prefix + p), sdk)
        for path in ['Madeira', 'Madeira.debug.dylib', 'prefix-template.tar.gz',
                     'x86_64-vcruntime/vcruntime140.dll', 'i386-windows/ntdll.dll']:
            if not archive.read(prefix + path):
                raise ValueError(f'empty app resource: {path}')
        if archive.testzip():
            raise ValueError('corrupt IPA archive')
    print(f'Validated complete IPA: {ipa}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['key', 'build', 'stage', 'verify', 'bundle', 'ipa'])
    parser.add_argument('target', nargs='?')
    args = parser.parse_args()
    sdk = sdk_key()
    if args.target not in (None, 'all') and args.action not in ('ipa', 'bundle') and args.target not in CONTRACT:
        parser.error('unknown runtime component: ' + args.target)
    if args.action == 'ipa':
        validate_ipa(Path(args.target), sdk)
    elif args.action == 'bundle':
        bundle_manifest(Path(args.target), sdk)
    else:
        names = list(CONTRACT) if args.target in (None, 'all') else [args.target]
        for name in names:
            if args.action == 'key':
                print(f'key=runtime-v1-{name}-{input_key(name, sdk)}')
            elif args.action == 'build':
                build(name, sdk)
            elif args.action == 'stage':
                stage(name, sdk)
            else:
                manifest = json.loads((cache_dir(name) / 'manifest.json').read_text())
                validate_manifest(name, manifest, lambda p: read_regular(ROOT / 'app/Madeira', p), sdk)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, struct.error, zipfile.BadZipFile) as error:
        raise SystemExit(f'ERROR: {error}')
