#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Prepare explicitly requested experimental sources without replacing main."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
MANIFEST = json.loads((HERE / 'manifest.json').read_text())

def git(directory, *args):
    return subprocess.check_output(['git', '-C', str(directory), *args], text=True).strip()

def run(*args, cwd=None):
    subprocess.run([str(arg) for arg in args], cwd=cwd, check=True)

def checked_file(relative, expected):
    path = (HERE / relative).resolve()
    if HERE not in path.parents or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit('Source input hash/path mismatch: ' + relative)
    return path

def check_manifest():
    patches = [checked_file(p['path'], p['sha256']) for p in MANIFEST['moltenvk_patches']]
    for config in MANIFEST['current_main_configs']:
        checked_file(config['path'], config['sha256'])
    old = MANIFEST['historical_source']
    checked_file(old['patch'], old['patch_sha256'])
    checked_file(old['manifest'], old['manifest_sha256'])
    return patches

def prepare_moltenvk(source, patches):
    revision = MANIFEST['moltenvk_revision']
    if not source.exists():
        source.parent.mkdir(parents=True, exist_ok=True)
        run('git', 'clone', '--depth', '1', '--branch', 'v1.4.2',
            'https://github.com/KhronosGroup/MoltenVK.git', source)
    if git(source, 'rev-parse', 'HEAD') != revision:
        raise SystemExit('Use a dedicated MoltenVK checkout at ' + revision)
    if git(source, 'diff', '--cached', '--name-only'):
        raise SystemExit('Refusing staged changes in MoltenVK checkout')
    paths = set()
    new_paths = set()
    for patch in patches:
        for line in subprocess.check_output(['git', 'apply', '--numstat', str(patch)], text=True).splitlines():
            path = line.split('\t', 2)[2]
            if Path(path).is_absolute() or '..' in Path(path).parts:
                raise SystemExit('Unsafe patch path')
            paths.add(path)
    # Compute the complete expected series before changing the caller's checkout.
    with tempfile.TemporaryDirectory(prefix='madeira-mvk-series-') as temp:
        temp = Path(temp)
        run('git', 'init', '-q', temp)
        for relative in paths:
            dest = temp / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            exists = subprocess.run(['git', '-C', str(source), 'cat-file', '-e', revision + ':' + relative],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            if exists:
                dest.write_bytes(subprocess.check_output(['git', '-C', str(source), 'show', revision + ':' + relative]))
            else:
                new_paths.add(relative)
        for patch in patches:
            run('git', 'apply', '--whitespace=nowarn', patch, cwd=temp)
        changed = set(git(source, 'diff', '--name-only', 'HEAD').splitlines())
        if changed or any((source / p).exists() for p in new_paths):
            if not changed.issubset(paths) or any((source / p).read_bytes() != (temp / p).read_bytes() for p in paths):
                raise SystemExit('Refusing unrelated or partial source changes; use a clean dedicated checkout')
        else:
            for patch in patches:
                run('git', 'apply', '--whitespace=nowarn', patch, cwd=source)
        for relative in paths:
            if (source / relative).read_bytes() != (temp / relative).read_bytes():
                raise SystemExit('Prepared source differs from the verified patch series')
    print('Prepared exact ten-patch MoltenVK source:', source)

def prepare_snapshot(directory):
    old = MANIFEST['historical_source']
    patch = HERE / old['patch']
    if not directory.exists():
        directory.parent.mkdir(parents=True, exist_ok=True)
        run('git', 'worktree', 'add', '--detach', directory, old['base'], cwd=ROOT)
        run('git', 'apply', '--index', '--whitespace=nowarn', patch, cwd=directory)
    if (Path(git(directory, 'rev-parse', '--show-toplevel')).resolve() != directory or
            git(directory, 'rev-parse', 'HEAD') != old['base'] or
            git(directory, 'write-tree') != old['tree'] or
            git(directory, 'diff', '--name-only')):
        raise SystemExit('Snapshot differs from the recorded tree; existing files were not reset')
    record = json.loads((HERE / old['manifest']).read_text())
    for relative, expected in record['source_files'].items():
        if hashlib.sha256((directory / relative).read_bytes()).hexdigest() != expected:
            raise SystemExit('Historical source hash mismatch: ' + relative)
    overlay = directory / 'build/experimental/wine-vulkan-diagnostics.patch'
    if hashlib.sha256(overlay.read_bytes()).hexdigest() != record['wine_overlay_sha256']:
        raise SystemExit('Wine overlay hash mismatch')
    print('Prepared complete historical source tree:', directory)
    print('Tree:', old['tree'], '(base HEAD plus staged source patch; no automatic commit)')
    print('Submodules and build prerequisites must be initialized separately. Main was not replaced.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['check', 'moltenvk', 'snapshot'])
    parser.add_argument('--directory', type=Path)
    args = parser.parse_args()
    patches = check_manifest()
    if args.mode == 'moltenvk':
        prepare_moltenvk((args.directory or ROOT / 'toolchains/moltenvk-detroit-source').resolve(), patches)
    elif args.mode == 'snapshot':
        prepare_snapshot((args.directory or ROOT / 'toolchains/detroit-historical-source').resolve())
    else:
        print('PASS complete-source input hashes')
