#!/usr/bin/env python3
"""Apply Madeira's downstream FEX overlay and restore exact pinned inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
FILES = ('Source/Windows/WOW64/Module.cpp', 'FEXCore/include/FEXCore/Utils/AllocatorHooks.h',
         'Source/Windows/Common/InvalidationTracker.cpp')
PATCH = ROOT / 'build/fex-compat/thread-init.patch'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stage(destination, source):
    for name in FILES:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, target)
    subprocess.run(['git', '-C', str(destination), 'apply', '--check', str(PATCH)], check=True)
    subprocess.run(['git', '-C', str(destination), 'apply', str(PATCH)], check=True)
    memory_patch = ROOT / 'build/fex-compat/guest-write.patch'
    subprocess.run(['git', '-C', str(destination), 'apply', '--check', str(memory_patch)], check=True)
    subprocess.run(['git', '-C', str(destination), 'apply', str(memory_patch)], check=True)


def apply(state, source):
    for name in FILES:
        subprocess.run(['git', '-C', str(source), 'diff', '--exit-code', 'HEAD', '--', name], check=True)
    stage(state / 'staged', source)
    for name in FILES:
        backup = state / 'originals' / name
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, backup)
    manifest = {'source': str(source), 'after': {n: digest(state / 'staged' / n) for n in FILES}}
    (state / 'manifest.json').write_text(json.dumps(manifest))
    try:
        for name in FILES:
            shutil.copyfile(state / 'staged' / name, source / name)
    except BaseException:
        for name in FILES:
            shutil.copyfile(state / 'originals' / name, source / name)
        raise


def restore(state):
    manifest = json.loads((state / 'manifest.json').read_text())
    source = Path(manifest['source'])
    for name, expected in manifest['after'].items():
        if digest(source / name) != expected:
            raise SystemExit(f'Refusing to overwrite build-time edits: {name}; backup: {state}')
    for name in FILES:
        shutil.copyfile(state / 'originals' / name, source / name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('stage', 'apply', 'restore'))
    parser.add_argument('directory', type=Path)
    parser.add_argument('--source', type=Path, default=ROOT / 'FEX')
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    if args.operation == 'stage': stage(args.directory, args.source)
    elif args.operation == 'apply': apply(args.directory, args.source)
    else: restore(args.directory)
