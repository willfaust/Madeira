#!/usr/bin/env python3
"""Wine Mono's first-use download (app/Madeira/WineMono.swift).

1. The pins in WineMono.swift are build/wine-mono/pin.sh's (version, tarball and both
   mscorlib hashes), and the URL is the one fetch.sh downloads.
2. Swift: compiles the installer part of WineMono.swift on the host and unpacks
   synthetic .tar.xz archives (GNU long names, a pax path, a skipped *-api folder, a
   path that tries to leave the folder), then, when build/wine-mono/fetch.sh has run,
   WineHQ's real tarball: every file must match tar's own unpacking byte for byte,
   lib/mono/*-api must be left out, and mscorlib.dll must carry the ml1281 patch.
3. Source checks: the bridge links C:\\windows\\mono\\mono-2.0 to the download when the
   bundle has none; setup, Settings and the Xcode project carry the new parts.

Run from anywhere; needs `swiftc` (Xcode) on PATH. Part 2's real-tarball run is skipped,
with a note, on a checkout without build/wine-mono/wine-mono-<ver>-x86.tar.xz.
"""
from pathlib import Path
import hashlib
import io
import lzma
import os
import re
import subprocess
import sys
import tarfile
import tempfile

root = Path(__file__).resolve().parents[2]
swift = (root / 'app/Madeira/WineMono.swift').read_text()
pin = (root / 'build/wine-mono/pin.sh').read_text()
fetch = (root / 'build/wine-mono/fetch.sh').read_text()
bridge = (root / 'app/Madeira/WineProcessBridge.m').read_text()
onboarding = (root / 'app/Madeira/Onboarding.swift').read_text()
pages = (root / 'app/Madeira/SettingsPages.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
failures = 0


def check(cond, what):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + what)
    if not cond:
        failures += 1


def shell_value(name):
    m = re.search(r'^%s=(\S+)$' % name, pin, re.M)
    return m.group(1) if m else None


def swift_value(name):
    m = re.search(r'static let %s = "([^"]+)"' % name, swift)
    return m.group(1) if m else None


version = shell_value('WINE_MONO_VER')
# ------------------------------------------------------------------ 1. pins
check(version and swift_value('version') == version, 'the version is pin.sh\'s (%s)' % version)
check(swift_value('tarSHA256') == shell_value('WINE_MONO_TAR_SHA256'), 'the tarball hash is pin.sh\'s')
check(swift_value('mscorlibSHA256') == shell_value('WINE_MONO_MSCORLIB_SHA256')
      and swift_value('mscorlibPatchedSHA256') == shell_value('WINE_MONO_MSCORLIB_PATCHED_SHA256'),
      'both mscorlib hashes are pin.sh\'s')
check('URL="https://dl.winehq.org/wine/wine-mono/$VER"' in fetch
      and 'https://dl.winehq.org/wine/wine-mono/%s/wine-mono-%s-x86.tar.xz' % (version, version) in swift,
      'the URL is the one fetch.sh downloads')
bundle_sh = (root / 'build/wine-mono/bundle.sh').read_text()
check('off = 0x53B08' in bundle_sh and 'static let patchOffset = 0x53B08' in swift
      and '"160A03183304061A600A052C04061E600A042C06"' in bundle_sh and 'bytes.fromhex("2A000000")' in bundle_sh,
      'the mscorlib patch is bundle.sh\'s (offset, context, bytes)')

# ------------------------------------------------------------------ 2. the installer, compiled
installer = swift[swift.index('// MARK: - Pin and installer'):swift.index('// MARK: - Model')]
driver = r'''
import Foundation
import Compression
import CryptoKit
''' + installer + r'''
let args = CommandLine.arguments
do {
    switch args[1] {
    case "unpack":
        let n = try WineMonoInstaller.unpack(tarXZ: URL(fileURLWithPath: args[2]), into: URL(fileURLWithPath: args[3]))
        if args.count > 4 { try WineMonoInstaller.patchMscorlib(in: URL(fileURLWithPath: args[3])) }
        print("files \(n)")
    case "paths":
        for p in args.dropFirst(2) { print(WineMonoInstaller.relativePath(p) ?? "<skip>") }
    default: exit(2)
    }
} catch {
    print("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    exit(1)
}
'''

def tar_xz(entries, fmt):
    """entries: list of (name, bytes or None for a directory)"""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode='w', format=fmt) as t:
        for name, data in entries:
            info = tarfile.TarInfo(name)
            if data is None:
                info.type = tarfile.DIRTYPE
                t.addfile(info)
            else:
                info.size = len(data)
                t.addfile(info, io.BytesIO(data))
    return lzma.compress(raw.getvalue(), format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC64)


with tempfile.TemporaryDirectory(prefix='madeira-wine-mono-') as tmp:
    tmp = Path(tmp)
    (tmp / 'driver.swift').write_text(driver)
    built = subprocess.run(['xcrun', 'swiftc', '-O', str(tmp / 'driver.swift'), '-o', str(tmp / 'driver')],
                           capture_output=True, text=True)
    check(built.returncode == 0, 'the installer part of WineMono.swift compiles on the host (Foundation, Compression, CryptoKit only)'
          + ('' if built.returncode == 0 else '\n' + built.stderr[-2000:]))
    if built.returncode == 0:
        run = lambda *a: subprocess.run([str(tmp / 'driver'), *a], capture_output=True, text=True)

        paths = run('paths', 'wine-mono-%s/bin/x.dll' % version, 'wine-mono-%s/' % version, '/etc/passwd',
                    'wine-mono-%s/../escape' % version, 'wine-mono-%s/lib/mono/4.5-api/a.dll' % version,
                    'wine-mono-%s/lib/mono/4.5/a.dll' % version, 'wine-mono-%s/support/x.msi' % version).stdout.split('\n')
        check(paths[:7] == ['bin/x.dll', '<skip>', '<skip>', '<skip>', '<skip>', 'lib/mono/4.5/a.dll', 'support/x.msi'],
              'paths: the top folder is dropped, *-api, absolute and .. paths are skipped (%s)' % paths[:7])

        long_name = 'wine-mono-%s/lib/mono/gac/' % version + 'A' * 90 + '/' + 'B' * 60 + '.dll'
        entries = [('wine-mono-%s/' % version, None), ('wine-mono-%s/bin/' % version, None),
                   ('wine-mono-%s/bin/one.dll' % version, b'one' * 1000),
                   ('wine-mono-%s/lib/mono/4.5-api/ref.dll' % version, b'ref' * 700),
                   (long_name, b'long' * 333), ('wine-mono-%s/empty.txt' % version, b''),
                   ('wine-mono-%s/../escape.txt' % version, b'no')]
        for fmt, label in ((tarfile.GNU_FORMAT, 'GNU long names'), (tarfile.PAX_FORMAT, 'pax paths')):
            (tmp / 'a.tar.xz').write_bytes(tar_xz(entries, fmt))
            out = tmp / ('out-' + label.split()[0])
            r = run('unpack', str(tmp / 'a.tar.xz'), str(out))
            got = sorted(str(p.relative_to(out)) for p in out.rglob('*') if p.is_file())
            want = sorted(['bin/one.dll', long_name.split('/', 1)[1], 'empty.txt'])
            check(r.returncode == 0 and got == want
                  and (out / 'bin/one.dll').read_bytes() == b'one' * 1000
                  and (out / long_name.split('/', 1)[1]).read_bytes() == b'long' * 333
                  and not (tmp / 'escape.txt').exists(),
                  'synthetic archive (%s): files, a %d-character name, -api skipped, nothing escapes %s'
                  % (label, len(long_name), '' if r.returncode == 0 else r.stdout))
        whole = tar_xz(entries, tarfile.GNU_FORMAT)
        (tmp / 'bad.tar.xz').write_bytes(whole[:len(whole) // 2])
        r = run('unpack', str(tmp / 'bad.tar.xz'), str(tmp / 'out-bad'))
        check(r.returncode != 0 and 'error:' in r.stdout, 'a cut-off download fails with a message (%s)' % r.stdout.strip())

        tarball = root / ('build/wine-mono/wine-mono-%s-x86.tar.xz' % version)
        if not tarball.exists():
            print('NOTE: %s is absent (run build/wine-mono/fetch.sh); the real-tarball run is skipped' % tarball.relative_to(root))
        else:
            out = tmp / 'real'
            r = run('unpack', str(tarball), str(out), 'patch')
            check(r.returncode == 0, 'WineHQ\'s tarball unpacks and mscorlib is patched (%s)' % r.stdout.strip())
            ref = tmp / 'ref'
            ref.mkdir()
            subprocess.run(['tar', '-xJf', str(tarball), '-C', str(ref)], check=True)
            ref = ref / ('wine-mono-%s' % version)
            want = {str(p.relative_to(ref)) for p in ref.rglob('*') if p.is_file()
                    and not re.match(r'lib/mono/[^/]*-api/', str(p.relative_to(ref)))}
            got = {str(p.relative_to(out)) for p in out.rglob('*') if p.is_file()}
            check(got == want, 'every file but lib/mono/*-api, and nothing else (%d files; missing %s, extra %s)'
                  % (len(got), sorted(want - got)[:3], sorted(got - want)[:3]))
            mscorlib = 'lib/mono/4.5/mscorlib.dll'
            same = all((out / f).read_bytes() == (ref / f).read_bytes() for f in want if f != mscorlib and f in got)
            check(same, 'every file is byte-identical to tar\'s unpacking')
            patched = hashlib.sha256((out / mscorlib).read_bytes()).hexdigest() if (out / mscorlib).exists() else ''
            check(patched == shell_value('WINE_MONO_MSCORLIB_PATCHED_SHA256'), 'mscorlib.dll carries the ml1281 patch')
            size = sum((out / f).stat().st_size for f in got)
            print('NOTE: installed size %.0f MB' % (size / 1e6))

# ------------------------------------------------------------------ 3. wiring
link = bridge[bridge.index('static void madeira_link_wine_mono'):]
link = link[:link.index('\n}\n')]
check('stringByAppendingPathComponent:@"WineMono/wine-mono"' in link and 'NSApplicationSupportDirectory' in link
      and link.index('@"wine-mono"]') < link.index('WineMono/wine-mono'),
      'the bridge links the bundled Wine Mono, else the downloaded one')
check('static var runtime: URL { root.appendingPathComponent("wine-mono", isDirectory: true) }' in swift
      and '.appendingPathComponent("WineMono", isDirectory: true)' in swift and 'isExcludedFromBackup = true' in swift,
      'the download lives in Library/Application Support/WineMono/wine-mono, out of backups')
check('guard try WineMonoInstaller.sha256(of: archive) == WineMonoPin.tarSHA256' in swift
      and swift.index('WineMonoInstaller.sha256(of: archive)') < swift.index('WineMonoInstaller.unpack(tarXZ: archive')
      and 'try fm.moveItem(at: staging, to: runtime)' in swift,
      'the download is checked before it is unpacked, and installed by one rename')
check('case .wineMono: wineMonoPage' in onboarding and 'mono.install()' in onboarding,
      'setup: the Wine Mono page downloads it')
check('case .runtimes:\n            WineMonoSettingsSection()' in pages, 'Settings: .NET Framework (the Runtimes page)')
check('A1000711 /* WineMono.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2000711' in project
      and 'path = "WineMono.swift"' in project and project.count('A2000711 /* WineMono.swift */,') == 1
      and project.count('A1000711 /* WineMono.swift in Sources */,') == 1,
      'Xcode: WineMono.swift is in the app target')

print('check-wine-mono:', 'FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
