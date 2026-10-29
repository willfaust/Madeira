#!/usr/bin/env python3
"""Exercise runtime cache boundaries, package completeness, and source isolation."""
import importlib.util
from itertools import product
import json
import os
from unittest.mock import patch
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('runtime', ROOT / 'tools/build/runtime-components.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def pe(machine, imports=()):
    data = bytearray(1024)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 0x3c, 64)
    data[64:68] = b'PE\0\0'
    struct.pack_into('<HH', data, 68, machine, 1)
    struct.pack_into('<HH', data, 84, 240, 0x2000)
    struct.pack_into('<H', data, 88, 0x20b)
    struct.pack_into('<I', data, 88 + 108, 16)
    struct.pack_into('<IIII', data, 88 + 240 + 8, 512, 0x1000, 512, 512)
    if imports:
        struct.pack_into('<II', data, 88 + 112 + 8, 0x1000, (len(imports) + 1) * 20)
        for index, name in enumerate(imports):
            offset = 256 + index * 64
            struct.pack_into('<I', data, 512 + index * 20 + 12, 0x1000 + offset)
            data[512 + offset:512 + offset + len(name) + 1] = name.encode() + b'\0'
    return bytes(data)


def macho(platform=2):
    return struct.pack('<8I6I', 0xfeedfacf, 0x100000c, 0, 6, 1, 24, 0, 0,
                       0x32, 24, platform, 0, 0, 0)


def fixture(path):
    if path.endswith('.dylib'):
        return macho()
    if path.endswith(('.dll', '.exe', '.drv')):
        machine = 0xaa64 if path.startswith('aarch64-windows/') else 0x8664
        return pe(machine)
    return b'notice or version\n'


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='madeira-runtime-')
        self.root = Path(self.tmp.name)
        self.previous = runtime.ROOT
        runtime.ROOT = self.root
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.git('config', 'user.name', 'Runtime fixture')
        self.git('config', 'user.email', 'runtime@example.invalid')
        for name, entry in runtime.CONTRACT.items():
            for path in entry['required'] + entry.get('prebuilt', []):
                self.write('app/Madeira/' + path, fixture(path))
        self.write('tools/build/runtime-components.py', b'coordinator')
        self.write('tools/check-wine-media-dlls.py', (ROOT / 'tools/check-wine-media-dlls.py').read_bytes())
        self.write('build/madeira-dock/build.sh', b'dock recipe')
        self.write('build/windows-runtime/build.sh', b'windows recipe')
        self.write('build/moltenvk-ios/build.sh', b'moltenvk recipe')
        self.write('build/mesa-ios/build.sh', b'zink recipe')
        self.write('build/mesa-d3d12/build.sh', b'mesa d3d12 recipe')
        self.write('build/dxvk/build.sh', b'vulkan recipe')
        self.write('build/mesa-ios/build-kosmickrisp.sh', b'kosmic recipe')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        sha = self.git('rev-parse', 'HEAD')
        for pin in ['wine', 'FEX', 'dxmt', 'madeira-dock']:
            self.git('update-index', '--add', '--cacheinfo', f'160000,{sha},{pin}')
        self.git('commit', '-qm', 'pins')
        self.sdk = 'sdk-fixture'

    def tearDown(self):
        runtime.ROOT = self.previous
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()

    def write(self, path, data):
        dest = self.root / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        return dest

    def snapshots(self):
        return {name: runtime.snapshot(name, self.sdk) for name in runtime.CONTRACT}

    def ipa(self):
        bundle = self.root / 'app/Madeira'
        runtime.bundle_manifest(bundle, self.sdk)
        for path in ['Madeira', 'Madeira.debug.dylib', 'prefix-template.tar.gz',
                     'x86_64-vcruntime/vcruntime140.dll', 'i386-windows/ntdll.dll']:
            self.write('app/Madeira/' + path, b'app fixture')
        ipa = self.root / 'test.ipa'
        with zipfile.ZipFile(ipa, 'w') as archive:
            for path in bundle.rglob('*'):
                if path.is_file():
                    archive.write(path, 'Payload/Madeira.app/' + path.relative_to(bundle).as_posix())
        return ipa

    def test_missing_runtime_imports_are_rejected(self):
        files = {'caller.dll': pe(0x8664, ['needed.dll']), 'apisetschema.dll': pe(0x8664)}
        self.assertEqual(runtime.missing_imports(files), {'needed.dll'})
        files['needed.dll'] = pe(0x8664)
        self.assertEqual(runtime.missing_imports(files), set())
        files['caller.dll'] = pe(0x8664, ['api-ms-win-example.dll'])
        self.assertEqual(runtime.missing_imports(files), set())
        del files['apisetschema.dll']
        self.assertEqual(runtime.missing_imports(files), {'api-ms-win-example.dll'})

    def test_wine_targets_include_required_dlls_absent_from_old_farms(self):
        spec = importlib.util.spec_from_file_location('targets', ROOT / 'build/windows-runtime/targets.py')
        targets = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(targets)
        targets.ROOT = self.root
        self.write('tools/build/runtime-components.json',
                   (ROOT / 'tools/build/runtime-components.json').read_bytes())
        for name in ['ntdll', 'kernelbase', 'explorerframe', 'wow64', 'wow64win']:
            self.write(f'wine/dlls/{name}/Makefile.in', f'MODULE = {name}.dll\n'.encode())
        (self.root / 'app/Madeira/arm64ec-windows/explorerframe.dll').unlink()
        self.assertIn(('dlls/explorerframe/arm64ec-windows/explorerframe.dll',
                       'explorerframe.dll', 'explorerframe'), targets.targets('arm64ec'))
        selected = targets.targets('arm64ec', {'kernelbase.dll'})
        self.assertEqual([name for _, name, _ in selected], ['kernelbase.dll'])
        (self.root / 'wine/dlls/explorerframe/Makefile.in').unlink()
        with self.assertRaises(ValueError):
            targets.targets('arm64ec')

    def test_cache_round_trip_and_dock_ownership(self):
        snapshots = self.snapshots()
        self.assertNotIn('arm64ec-windows/dockhost.exe', snapshots['windows']['files'])
        for name in runtime.CONTRACT:
            runtime.stage(name, self.sdk)
        path = self.root / '.runtime-cache/dock/files/arm64ec-windows/dockhost.exe'
        path.write_bytes(pe(0x8664) + b'corrupt')
        original = (self.root / 'app/Madeira/arm64ec-windows/dockhost.exe').read_bytes()
        with self.assertRaises(ValueError):
            runtime.stage('dock', self.sdk)
        self.assertEqual(original, (self.root / 'app/Madeira/arm64ec-windows/dockhost.exe').read_bytes())

    def test_cache_hit_and_failed_rebuild(self):
        runtime.snapshot('dock', self.sdk)
        with patch.dict(os.environ, MADEIRA_RUNTIME_REUSE='1'):
            with patch.object(runtime, 'stage', return_value={}), patch.object(runtime.subprocess, 'run') as run:
                runtime.build('dock', self.sdk)
                run.assert_not_called()
            cache = self.root / '.runtime-cache/dock/manifest.json'
            previous = cache.read_bytes()
            with patch.object(runtime, 'stage', side_effect=ValueError('changed SDK')), patch.object(runtime.subprocess, 'run', side_effect=subprocess.CalledProcessError(86, 'builder')):
                with self.assertRaises(subprocess.CalledProcessError):
                    runtime.build('dock', 'changed SDK')
            self.assertEqual(previous, cache.read_bytes())

    def test_required_files_architecture_and_platform(self):
        snapshots = self.snapshots()
        bundle = self.root / 'app/Madeira'
        for name, entry in runtime.CONTRACT.items():
            for path in entry['required']:
                file = bundle / path
                data = file.read_bytes()
                file.unlink()
                with self.assertRaises(ValueError, msg=path):
                    runtime.validate_manifest(name, snapshots[name], lambda p: runtime.read_regular(bundle, p), self.sdk)
                file.write_bytes(data)
        for path in ['arm64ec-windows/dockhost.exe', 'aarch64-windows/wow64.dll',
                     'vulkan/arm64ec-windows/d3d12.dll', 'compat/love/lua51.dll']:
            with self.assertRaises(ValueError):
                runtime.check_binary(path, pe(0x14c))
        for platform in [1, 7]:
            with self.assertRaises(ValueError):
                runtime.check_binary('gl/libOSMesa.dylib', macho(platform))
        with self.assertRaises(ValueError):
            runtime.check_binary('gl/libOSMesa.dylib', macho()[:40])

    def test_partial_fex_configure_is_retried(self):
        for arch, target, dll in [('arm64ec', 'arm64ecfex', 'libarm64ecfex.dll'),
                                  ('wow64', 'wow64fex', 'libwow64fex.dll')]:
            relative = f'build/fex-{arch}/build.sh'
            script = self.write(relative, (ROOT / relative).read_bytes())
            self.write(f'FEX/build-{arch}/CMakeCache.txt', b'partial configure')
            binary = self.root / f'FEX/build-{arch}/Bin/{dll}'
            cmake = self.write('bin/cmake', b'#!/bin/sh\nset -eu\n'
                b'if [ "$1" = -S ]; then touch "$CONFIGURED"; '
                b'else test -f "$CONFIGURED"; mkdir -p "$(dirname "$BINARY")"; echo binary > "$BINARY"; fi\n')
            cmake.chmod(0o755)
            (self.root / 'app/Madeira/aarch64-windows').mkdir(parents=True, exist_ok=True)
            subprocess.run(['bash', str(script)], cwd=self.root,
                           env=dict(os.environ, PATH=str(cmake.parent) + os.pathsep + os.environ['PATH'],
                                    CONFIGURED=str(self.root / f'{arch}.configured'), BINARY=str(binary)),
                           check=True, capture_output=True)
            self.assertTrue(binary.is_file())

    def test_wine_temporary_edits_preserve_local_source_on_failure(self):
        script = self.write('build/wine-pe/build-modules.sh',
                            (ROOT / 'build/wine-pe/build-modules.sh').read_bytes())
        source = self.write('wine/dlls/example/Makefile.in',
                            b'MODULE = example.dll\nIMPORTS = kernel32\nDELAYIMPORTS = kernel32\n# local edit\n')
        original = source.read_bytes()
        self.write('wine/build-arm64ec/config.status', b'configured')
        self.write('app/Madeira/arm64ec-windows/kernel32.dll', pe(0x8664))
        strip = self.write('toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/arm64ec-w64-mingw32-strip',
                           b'#!/bin/sh\nexit 0\n')
        strip.chmod(0o755)
        make = self.write('bin/make', b'#!/bin/sh\nexit 86\n')
        make.chmod(0o755)
        result = subprocess.run(['bash', str(script), 'example'], cwd=self.root,
                                env=dict(os.environ, PATH=str(make.parent) + os.pathsep + os.environ['PATH']),
                                capture_output=True)
        self.assertEqual(result.returncode, 86, result.stderr)
        self.assertEqual(original, source.read_bytes())

    def test_rebuilt_outputs_do_not_change_source_key(self):
        before = runtime.input_key('windows', self.sdk)
        self.write('app/Madeira/aarch64-windows/clock.exe', pe(0xaa64) + b'rebuilt')
        self.write('app/Madeira/arm64ec-windows/kernelbase.dll', pe(0x8664) + b'rebuilt')
        self.assertEqual(before, runtime.input_key('windows', self.sdk))
        fixture_path = runtime.CONTRACT['windows']['prebuilt'][0]
        self.write('app/Madeira/' + fixture_path, fixture(fixture_path) + b'changed fixture')
        self.assertNotEqual(before, runtime.input_key('windows', self.sdk))

    def test_native_dependency_and_command_bounds(self):
        for dependency, valid in [('/opt/homebrew/lib/libhost.dylib', False),
                                  ('@rpath/libmissing.dylib', False),
                                  ('/usr/lib/libSystem.B.dylib', True),
                                  ('@rpath/libMoltenVK.dylib', True)]:
            name = dependency.encode() + b'\0'
            length = (24 + len(name) + 7) // 8 * 8
            command = struct.pack('<6I', 0xc, length, 24, 0, 0, 0) + name
            data = bytearray(macho())
            struct.pack_into('<II', data, 16, 2, 24 + length)
            data += command.ljust(length, b'\0')
            if valid:
                runtime.check_binary('gl/libOSMesa.dylib', bytes(data))
            else:
                with self.assertRaises(ValueError):
                    runtime.check_binary('gl/libOSMesa.dylib', bytes(data))
        data = bytearray(macho())
        struct.pack_into('<I', data, 16, 2)
        with self.assertRaises(ValueError):
            runtime.check_binary('gl/libOSMesa.dylib', bytes(data))

    def test_unsafe_paths_unknown_owners_wrong_keys_and_symlinks(self):
        snapshot = runtime.snapshot('dock', self.sdk)
        bundle = self.root / 'app/Madeira'
        for path in ['../escape', '/absolute', 'arm64ec-windows/../escape', 'a\\b', '']:
            with self.assertRaises(ValueError):
                runtime.safe_path(path)
        for key, value in [('key', 'wrong'), ('schema', 99), ('files', {})]:
            broken = dict(snapshot, **{key: value})
            with self.assertRaises(ValueError):
                runtime.validate_manifest('dock', broken, lambda p: runtime.read_regular(bundle, p), self.sdk)
        extra = dict(snapshot, files=dict(snapshot['files'], **{'other/file': 'ignored'}))
        with self.assertRaises(ValueError):
            runtime.validate_manifest('dock', extra, lambda p: b'notice', self.sdk)
        path = bundle / 'arm64ec-windows/dockhost.exe'
        outside = self.write('outside.exe', path.read_bytes())
        path.unlink()
        path.symlink_to(outside)
        with self.assertRaises(ValueError):
            runtime.stage('dock', self.sdk)

    def test_package_completeness_source_and_corruption(self):
        self.snapshots()
        ipa = self.ipa()
        runtime.validate_ipa(ipa, self.sdk)
        with zipfile.ZipFile(ipa) as archive:
            original = {p: archive.read(p) for p in archive.namelist()}
        for name, entry in runtime.CONTRACT.items():
            for path in entry['required']:
                with zipfile.ZipFile(ipa, 'w') as archive:
                    for filename, data in original.items():
                        if filename != 'Payload/Madeira.app/' + path:
                            archive.writestr(filename, data)
                with self.assertRaises(KeyError, msg=path):
                    runtime.validate_ipa(ipa, self.sdk)
        with zipfile.ZipFile(ipa, 'w') as archive:
            for filename, data in original.items():
                archive.writestr(filename, data)
            archive.writestr('../escape', b'bad')
        with self.assertRaises(ValueError):
            runtime.validate_ipa(ipa, self.sdk)
        with zipfile.ZipFile(ipa, 'w') as archive:
            archive.writestr('Payload/Madeira.app/Madeira', b'incomplete old CI IPA')
        with self.assertRaises(KeyError):
            runtime.validate_ipa(ipa, self.sdk)

    def test_all_source_change_permutations(self):
        recipes = [('build/madeira-dock/build.sh', {'dock'}),
                   ('build/windows-runtime/build.sh', {'windows'}),
                   ('build/moltenvk-ios/build.sh', {'moltenvk', 'zink'}),
                   ('build/mesa-ios/build.sh', {'zink'}),
                   ('build/mesa-d3d12/build.sh', {'mesa-d3d12'}),
                   ('build/dxvk/build.sh', {'vulkan-pe'}),
                   ('build/mesa-ios/build-kosmickrisp.sh', {'kosmickrisp'})]
        keys = {n: runtime.input_key(n, self.sdk) for n in runtime.CONTRACT}
        contents = {p: (self.root / p).read_bytes() for p, _ in recipes}
        for selected in product([False, True], repeat=len(recipes)):
            changed = set()
            for enabled, (path, affected) in zip(selected, recipes):
                (self.root / path).write_bytes(contents[path] + (b' changed' if enabled else b''))
                if enabled:
                    changed |= affected
            actual = {n for n in keys if runtime.input_key(n, self.sdk) != keys[n]}
            self.assertEqual(changed, actual, selected)
        for path, data in contents.items():
            (self.root / path).write_bytes(data)
        self.write('tools/build/runtime-components.py', b'validation-only change')
        self.write('app/Madeira/Library.swift', b'app-only change')
        self.assertEqual(keys, {n: runtime.input_key(n, self.sdk) for n in keys})
        for name in keys:
            self.assertNotEqual(keys[name], runtime.input_key(name, 'different-sdk'))


if __name__ == '__main__':
    unittest.main()
