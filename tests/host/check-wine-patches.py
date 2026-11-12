#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Russell Barton
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""patches/apply.sh: this repository's Wine changes are built into the runtime.

patches/apply.sh applies patches/wine-*.patch to the wine working tree before
the runtime builds opengl32; without patches/wine-opengl-winios.patch the
ARM64EC opengl32.dll keeps Wine's 0x7a800000 image base and the 32-bit thunks
dereference guest addresses without the window base.

Checks, without building Wine:
  - build/windows-runtime/build.sh runs patches/apply.sh before it builds Wine,
    and build/ntdll-unix/build.sh before it compiles opengl32's unix side;
  - the Windows runtime's cache key covers patches/;
  - apply.sh against a scratch git repository: applies, skips an applied
    patch, reverts, and fails on a patch that does not apply;
  - with the wine submodule checked out: the patch applies to the pinned
    tree (or is already applied), and it carries the guest-pointer
    conversion for get_teb64 and the ARM64EC image base.
Needs python3, git and bash.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


apply_sh = root / 'patches/apply.sh'
windows = (root / 'build/windows-runtime/build.sh').read_text(encoding='utf-8')
unix = (root / 'build/ntdll-unix/build.sh').read_text(encoding='utf-8')
patch = (root / 'patches/wine-opengl-winios.patch').read_text(encoding='utf-8')
components = json.loads((root / 'tools/build/runtime-components.json').read_text(encoding='utf-8'))

require(apply_sh.is_file() and os.access(apply_sh, os.X_OK), 'patches/apply.sh is there and executable')
call = 'bash "$R/patches/apply.sh"\n'
require(windows.count(call) == 1 and windows.index(call) < windows.index('bash "$R/tools/build/build-wine.sh"'),
        'the Windows runtime applies the Wine patches before it builds Wine')
call = 'bash "$REPO_ROOT/patches/apply.sh"\n'
require(unix.count(call) == 1 and
        unix.index(call) < unix.index('compile_unixlib "$WINE_SRC/dlls/opengl32/unix_wgl.c"') and
        unix.index(call) < unix.index('compile_unixlib "$WINE_SRC/dlls/opengl32/unix_thunks.c"'),
        'the iOS unix side applies them before it compiles opengl32')
require('patches/**' in components['windows']['inputs'], "the Windows runtime's cache key covers patches/")
require('-static inline TEB *get_teb64( ULONG teb32 )' in patch and
        '+    TEB32 *teb32_ptr = ios_wow_host_ptr( teb32 );' in patch and
        '-EXTRADLLFLAGS = -Wl,--image-base,0x7a800000' in patch,
        'the OpenGL patch converts the guest TEB address and limits the low image base to x86 builds')


def run(*args, cwd=None, check=True):
    return subprocess.run(list(args), cwd=cwd, capture_output=True, text=True, check=check)


# ---- apply.sh against a scratch repository laid out like this one
with tempfile.TemporaryDirectory(prefix='madeira-wine-patches-') as tmp:
    tmp = Path(tmp)
    (tmp / 'patches').mkdir()
    shutil.copy(apply_sh, tmp / 'patches/apply.sh')
    wine = tmp / 'wine'
    wine.mkdir()
    env = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')
    subprocess.run(['git', 'init', '-q'], cwd=wine, check=True)
    (wine / 'a.c').write_text('one\ntwo\n')
    subprocess.run(['git', 'add', 'a.c'], cwd=wine, check=True)
    subprocess.run(['git', 'commit', '-q', '-m', 'base'], cwd=wine, check=True, env=env)
    (wine / 'a.c').write_text('one\nTWO\n')
    diff = run('git', 'diff', cwd=wine).stdout
    run('git', 'checkout', '--', 'a.c', cwd=wine)
    (tmp / 'patches/wine-one.patch').write_text(diff)
    first = run('bash', str(tmp / 'patches/apply.sh'), check=False)
    require(first.returncode == 0 and 'applied wine-one.patch' in first.stdout and
            (wine / 'a.c').read_text() == 'one\nTWO\n', 'applies a patch to the working tree')
    again = run('bash', str(tmp / 'patches/apply.sh'), check=False)
    require(again.returncode == 0 and 'already applied' in again.stdout and (wine / 'a.c').read_text() == 'one\nTWO\n',
            'skips a patch already applied')
    back = run('bash', str(tmp / 'patches/apply.sh'), '--revert', check=False)
    require(back.returncode == 0 and (wine / 'a.c').read_text() == 'one\ntwo\n' and
            run('git', 'status', '--porcelain', cwd=wine).stdout == '', '--revert leaves the tree as committed')
    (wine / 'a.c').write_text('changed\n')
    bad = run('bash', str(tmp / 'patches/apply.sh'), check=False)
    require(bad.returncode != 0 and 'does not apply' in bad.stderr, 'a patch that does not apply fails the build')

# ---- the pinned wine tree
wine = root / 'wine'
if (wine / 'dlls/opengl32/unix_private.h').is_file():
    p = str(root / 'patches/wine-opengl-winios.patch')
    forward = run('git', '-C', str(wine), 'apply', '--check', p, check=False).returncode == 0
    applied = run('git', '-C', str(wine), 'apply', '--reverse', '--check', p, check=False).returncode == 0
    require(forward or applied, 'the OpenGL patch applies to the checked-out wine (or is applied)')
else:
    print('SKIP: wine not checked out; the patch was not tried against the pin')

if failures:
    print('FAILURES: %d' % failures)
    sys.exit(1)
print('PASS: all Wine patch checks')
