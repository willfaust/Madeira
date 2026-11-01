#!/usr/bin/env python3
"""Stage or temporarily apply the maintained Wine IOSB overlay, restoring exact inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
FILES = ('dlls/ntdll/unix/unix_private.h', 'dlls/ntdll/unix/file.c',
         'dlls/wow64/wow64_private.h', 'dlls/wow64/file.c', 'dlls/wow64/syscall.c',
         'include/Makefile.in', 'dlls/kernelbase/memory.c', 'dlls/kernelbase/process.c', 'dlls/wow64/virtual.c', 'dlls/wow64/process.c')
HEADER = 'include/wine/ios_io_abi.h'
PATCH = ROOT / 'build/ntdll-unix/io-status-abi.patch'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stage(destination, source):
    for name in FILES:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, target)
    subprocess.run(['git', '-C', str(destination), 'apply', '--check', str(PATCH)], check=True)
    subprocess.run(['git', '-C', str(destination), 'apply', str(PATCH)], check=True)
    thread_patch = ROOT / 'build/ntdll-unix/wow-thread-init.patch'
    subprocess.run(['git', '-C', str(destination), 'apply', '--check', str(thread_patch)], check=True)
    subprocess.run(['git', '-C', str(destination), 'apply', str(thread_patch)], check=True)
    write_patch = ROOT / 'build/ntdll-unix/wow-write-trace.patch'
    subprocess.run(['git', '-C', str(destination), 'apply', '--check', str(write_patch)], check=True)
    subprocess.run(['git', '-C', str(destination), 'apply', str(write_patch)], check=True)
    window_patch = ROOT / 'build/ntdll-unix/wow-handle-window.patch'
    subprocess.run(['git', '-C', str(destination), 'apply', '--check', str(window_patch)], check=True)
    subprocess.run(['git', '-C', str(destination), 'apply', str(window_patch)], check=True)
    memory_patch = ROOT / 'build/ntdll-unix/wow-guest-write.patch'
    subprocess.run(['git', '-C', str(destination), 'apply', '--check', str(memory_patch)], check=True)
    subprocess.run(['git', '-C', str(destination), 'apply', str(memory_patch)], check=True)
    query_patch = ROOT / 'build/ntdll-unix/wow-query-origin.patch'
    subprocess.run(['git', '-C', str(destination), 'apply', '--check', str(query_patch)], check=True)
    subprocess.run(['git', '-C', str(destination), 'apply', str(query_patch)], check=True)
    affinity_patch = ROOT / 'build/ntdll-unix/wow-affinity-attribute.patch'
    subprocess.run(['git', '-C', str(destination), 'apply', '--check', str(affinity_patch)], check=True)
    subprocess.run(['git', '-C', str(destination), 'apply', str(affinity_patch)], check=True)
    arch_patch = ROOT / 'build/ntdll-unix/steam-arch-trace.patch'
    subprocess.run(['git', '-C', str(destination), 'apply', '--check', str(arch_patch)], check=True)
    subprocess.run(['git', '-C', str(destination), 'apply', str(arch_patch)], check=True)
    header = destination / HEADER
    header.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / 'build/ntdll-unix/io_status_abi.h', header)


def apply(state, source):
    if (source / HEADER).exists():
        raise SystemExit('Refusing to overwrite an existing IOSB ABI header')
    for name in FILES:
        subprocess.run(['git', '-C', str(source), 'diff', '--exit-code', 'HEAD', '--', name], check=True)
    staged = state / 'staged'
    stage(staged, source)
    originals = state / 'originals'
    for name in FILES:
        target = originals / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, target)
    manifest = {'source': str(source), 'after': {n: digest(staged / n) for n in (*FILES, HEADER)}}
    (state / 'manifest.json').write_text(json.dumps(manifest))
    try:
        for name in (*FILES, HEADER):
            (source / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(staged / name, source / name)
    except BaseException:
        for name in FILES:
            shutil.copyfile(originals / name, source / name)
        (source / HEADER).unlink(missing_ok=True)
        raise


def restore(state):
    manifest = json.loads((state / 'manifest.json').read_text())
    source = Path(manifest['source'])
    for name, expected in manifest['after'].items():
        if not (source / name).exists() or digest(source / name) != expected:
            raise SystemExit(f'Refusing to overwrite changes made during the build: {name}; backup: {state}')
    for name in FILES:
        shutil.copyfile(state / 'originals' / name, source / name)
    (source / HEADER).unlink()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('stage', 'apply', 'restore'))
    parser.add_argument('directory', type=Path)
    parser.add_argument('--source', type=Path, default=ROOT / 'wine')
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    if args.operation == 'stage': stage(args.directory, args.source)
    elif args.operation == 'apply': apply(args.directory, args.source)
    else: restore(args.directory)
