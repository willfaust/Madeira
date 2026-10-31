#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Verify complete historical sources and opt-in source preparation, offline.
Optional --moltenvk-source uses its Git objects to create a disposable worktree;
it never resets the supplied checkout or downloads dependencies.
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / 'build/vulkan-ios/experimental'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--moltenvk-source', type=Path)
args = parser.parse_args()
spec = importlib.util.spec_from_file_location('experimental_sources', HERE / 'prepare-sources.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
helper.check_manifest()
print('PASS patch/config/manifest SHA-256 inputs')
for relative, digest in [('manifest.json', '0' * 64), ('../../README.md', '0' * 64)]:
    try:
        helper.checked_file(relative, digest)
    except SystemExit:
        pass
    else:
        raise AssertionError('Invalid source input accepted')
print('PASS input hash/path rejection')
old = helper.MANIFEST['historical_source']
patch = HERE / old['patch']
assert b'GIT binary patch' not in patch.read_bytes()
changed = subprocess.check_output(['git', 'apply', '--numstat', str(patch)], text=True)
paths = [line.split('\t', 2)[2] for line in changed.splitlines()]
assert len(paths) == old['changed_files'] == 91
assert all(not p.startswith(('FEX/', 'dxmt/')) and not p.endswith(('.ipa', '.p12', '.mobileprovision', '.dll', '.exe')) for p in paths)
with tempfile.TemporaryDirectory(prefix='madeira-complete-source-') as temp:
    env = dict(os.environ, GIT_INDEX_FILE=str(Path(temp) / 'index'))
    def git(*commands):
        return subprocess.check_output(['git', '-C', str(ROOT), *commands], env=env).strip()
    git('read-tree', old['base'])
    git('apply', '--cached', '--whitespace=nowarn', str(patch))
    assert git('write-tree').decode() == old['tree']
    record = json.loads((HERE / old['manifest']).read_text())
    for path, expected in record['source_files'].items():
        data = subprocess.check_output(['git', '-C', str(ROOT), 'show', ':' + path], env=env)
        assert hashlib.sha256(data).hexdigest() == expected
    overlay = subprocess.check_output(['git', '-C', str(ROOT), 'show', ':build/experimental/wine-vulkan-diagnostics.patch'], env=env)
    assert hashlib.sha256(overlay).hexdigest() == record['wine_overlay_sha256']
print('PASS all 91 historical changes reconstruct the exact snapshot tree; 77 file and Wine-overlay hashes match')
for path in ['tools/build-ipa.sh', 'build/vulkan-ios/build.sh']:
    assert 'experimental/build-moltenvk.sh' not in (ROOT / path).read_text()
print('PASS ordinary build entry points do not enable this profile')
if args.moltenvk_source:
    source = args.moltenvk_source.resolve()
    with tempfile.TemporaryDirectory(prefix='madeira-full-mvk-') as temp:
        target = Path(temp) / 'source'
        subprocess.run(['git', '-C', str(source), 'worktree', 'add', '--detach', str(target), helper.MANIFEST['moltenvk_revision']], check=True, capture_output=True)
        try:
            cmd = ['python3', str(HERE / 'prepare-sources.py'), 'moltenvk', '--directory', str(target)]
            subprocess.run(cmd, check=True)
            before = subprocess.check_output(['git', '-C', str(target), 'diff', 'HEAD'])
            subprocess.run(cmd, check=True)
            assert subprocess.check_output(['git', '-C', str(target), 'diff', 'HEAD']) == before
            file = target / 'MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm'
            expected = file.read_bytes()
            file.write_bytes(expected + b'\n// unrelated test modification\n')
            result = subprocess.run(cmd, capture_output=True, text=True)
            assert result.returncode != 0 and 'Refusing' in result.stderr + result.stdout
            assert file.read_bytes() == expected + b'\n// unrelated test modification\n'
        finally:
            subprocess.run(['git', '-C', str(source), 'worktree', 'remove', '--force', str(target)], check=True)
    print('PASS complete ten-patch application, idempotence and unrelated-edit rejection without resetting files')
else:
    print('SKIP full MoltenVK preparation: supply --moltenvk-source for an existing pinned Git source')
print('ALL PASS complete experimental sources; no device/game result implied')
