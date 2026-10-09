#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 David Brookes
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Production storage helpers on disposable macOS APFS and exFAT images.

Creates two bounded 128 MiB sparse images, tests real ENOSPC and read-only mounts,
and detaches them before deleting its own scratch directory. No physical disk or
app data is touched. Pass --with-downloads to run the production downloader's
external install/interruption/resume/update/uninstall fixtures on each image.
This is not an iPad security-scope or USB-removal test.
"""
from pathlib import Path
import argparse
import plistlib
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PROBE = r'''
import Foundation

@main struct Probe {
    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let args = CommandLine.arguments
        let volume = URL(fileURLWithPath: args[2], isDirectory: true)
        let root = volume.appendingPathComponent("MadeiraHostLibrary", isDirectory: true)
        let fm = FileManager.default
        func require(_ value: Bool, _ label: String) {
            guard value else { fatalError(label) }
            print("PASS: " + label)
        }
        let values = try volume.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeIsReadOnlyKey])
        require(values.volumeName?.hasPrefix("MdrSSDTest") == true &&
                (values.volumeTotalCapacity ?? Int.max) <= 128 * 1024 * 1024,
                "bounded disposable volume verified")
        if args[1] == "readonly" {
            require(values.volumeIsReadOnly == true, "volume is actually mounted read-only")
            let identity = try String(contentsOf: root.appendingPathComponent(SteamStorageIdentity.marker), encoding: .utf8)
            try SteamStorageIdentity.verify(identity, root: root)
            do {
                try Data([1]).write(to: root.appendingPathComponent("must-not-write"))
                require(false, "read-only volume rejected a write")
            } catch {
                require(SteamExternalAccess.availability(for: error) == .readOnly,
                        "real read-only failure retains its storage classification")
            }
            require(!fm.fileExists(atPath: root.appendingPathComponent("must-not-write").path),
                    "read-only failure creates no file")
            return
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = try SteamStorageIdentity.register(root: root)
        let before = try SteamStorageCapacity.availableBytes(at: root)
        require(before > 0 && before <= 128 * 1024 * 1024, "capacity belongs to the selected test volume")
        let original = try SteamStoragePath.native("payload.bin", root: root)
        try Data(repeating: 0x71, count: 8192).write(to: original)
        let renamed = try SteamStoragePath.native("renamed.bin", root: root)
        try fm.moveItem(at: original, to: renamed)
        let actual = try Data(contentsOf: renamed)
        require(actual == Data(repeating: 0x71, count: 8192), "payload survives write rename and reopen")
        let fill = try SteamStoragePath.native("bounded-fill.bin", root: root)
        require(fm.createFile(atPath: fill.path, contents: nil), "bounded fill file created")
        let handle = try FileHandle(forWritingTo: fill)
        let chunk = Data(repeating: 0x5a, count: 1024 * 1024)
        var full = false
        for _ in 0..<160 {
            do {
                try handle.write(contentsOf: chunk)
                try handle.synchronize()
            } catch {
                var cause: NSError? = error as NSError
                for _ in 0..<8 {
                    guard let e = cause else { break }
                    if (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC)) ||
                       (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError) { full = true; break }
                    cause = e.userInfo[NSUnderlyingErrorKey] as? NSError
                }
                break
            }
        }
        try? handle.close()
        require(full, "bounded payload write reports actual out-of-space")
        let after = try SteamStorageCapacity.availableBytes(at: root)
        print("CAPACITY before=\(before) after-full=\(after)")
        let raw = try root.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let attrs = try fm.attributesOfFileSystem(forPath: root.path)
        print("CAPACITY raw ordinary=\(raw.volumeAvailableCapacity ?? -1) important=\(raw.volumeAvailableCapacityForImportantUsage ?? -1) filesystem=\((attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? -1)")
        // APFS may report reserved free blocks even after ENOSPC (the 128 MiB
        // fixture reports about 4 MiB). Capacity is an estimate, not a write guarantee.
        require(after < before / 4, "free-space query reflects low capacity on the full destination")
        try SteamStorageIdentity.verify(identity, root: root)
        require(try Data(contentsOf: renamed) == actual, "low-space failure preserves existing payload and identity")
        try fm.removeItem(at: fill)
        require(try SteamStorageCapacity.availableBytes(at: root) > after, "removing only test fill restores capacity")
    }
}
'''


def run(args, timeout=120, env=None):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}): {result.stderr[-2000:]} {result.stdout[-2000:]}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--with-downloads', action='store_true')
    parser.add_argument('--filesystem', action='append', choices=['APFS', 'ExFAT'])
    options = parser.parse_args()
    if sys.platform != 'darwin':
        print('SKIP: disposable APFS/exFAT images require macOS')
        return 0
    work = Path(tempfile.mkdtemp(prefix='madeira-storage-volumes-'))
    mounted = set()
    try:
        source, executable = work / 'probe.swift', work / 'probe'
        source.write_text(PROBE)
        run(['xcrun', 'swiftc', '-parse-as-library', str(ROOT / 'app/Madeira/SteamStorage.swift'), str(source), '-o', str(executable)])
        for fs in options.filesystem or ['APFS', 'ExFAT']:
            image, mount = work / (fs + '.sparseimage'), work / (fs + '-mount')
            mount.mkdir()
            # A 128 MiB exFAT image needs MBR; the default partition layout
            # reserves more space than this deliberately small image provides.
            layout = ['-layout', 'MBRSPUD'] if fs == 'ExFAT' else []
            run(['hdiutil', 'create', '-size', '128m', '-type', 'SPARSE', '-fs', fs,
                 '-volname', 'MdrSSDTest', '-nospotlight', *layout, str(image)])
            for readonly in [False, True]:
                args = ['hdiutil', 'attach', str(image), '-mountpoint', str(mount), '-nobrowse', '-plist']
                if readonly:
                    args += ['-readonly']
                attached = plistlib.loads(run(args).encode())
                # macOS may report /private/var for an equivalent /var mount path.
                # Track attachment before path matching so cleanup also covers errors.
                mounted.update(e['dev-entry'] for e in attached['system-entities'] if e.get('mount-point'))
                device = next(e['dev-entry'] for e in attached['system-entities']
                              if e.get('mount-point') and Path(e['mount-point']).resolve() == mount.resolve())
                print(f'--- {fs} {"read-only" if readonly else "write/low-space"}', flush=True)
                print(run([str(executable), 'readonly' if readonly else 'writable', str(mount)]), end='', flush=True)
                if not readonly and options.with_downloads:
                    environment = dict(os.environ, MADEIRA_TEST_EXTERNAL_PARENT=str(mount))
                    environment.pop('MADEIRA_KEEP_WORK', None)
                    output = run([sys.executable, str(ROOT / 'tests/host/check-steam-library.py')], timeout=600, env=environment)
                    print(output, end='', flush=True)
                    print(f'PASS: production external downloader lifecycle on {fs}', flush=True)
                run(['hdiutil', 'detach', device])
                mounted.remove(device)
        print('PASS: production storage helpers on bounded ' + ', '.join(options.filesystem or ['APFS', 'ExFAT']) + ' images')
        return 0
    except Exception as error:
        print('FAIL:', error)
        return 1
    finally:
        for device in list(mounted):
            try:
                run(['hdiutil', 'detach', device])
                mounted.remove(device)
            except Exception:
                print('Cleanup: could not detach test device', device)
        mount_exists = any(p.is_mount() for p in work.glob('*-mount'))
        if not mounted and not mount_exists:
            shutil.rmtree(work)
        else:
            print('Retained test scratch:', work)


if __name__ == '__main__':
    sys.exit(main())
