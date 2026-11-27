#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Every change this repository carries on top of a patched submodule pin must
ship in that submodule's patch stack (build/dxmt-patches, build/dock-patches):
the working tree (the patches applied) and the stack are the same changes,
nothing in one missing from the other. A __METAL_MEMORY_FLAGS_NONE__ guard once
shipped in the dxmt working tree with no patch, so a fresh checkout built
through apply.sh lost it; this check fails whenever the two drift again.
The stacks must also apply in order on a clean worktree of the pin. Nothing in
this repository is modified: each run builds its own throwaway worktree.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]

CASES = [
    ('dxmt', root / 'build/dxmt-patches'),
    ('madeira-dock', root / 'build/dock-patches'),
]


def git(*args, cwd):
    return subprocess.run(('git',) + args, cwd=cwd, capture_output=True, text=True)


def strip_index(diff):
    # blob ids differ between a patch file and a worktree even for the same
    # change; every other line of the same combined diff is comparable.
    return '\n'.join(l for l in diff.splitlines() if not l.startswith('index '))


def files_of(diff):
    out, cur = {}, None
    for line in diff.splitlines():
        if line.startswith('diff --git '):
            cur = line.split(' b/')[-1]
            out[cur] = []
        elif cur is not None:
            out[cur].append(line)
    return out


ok = True
ran = False
for name, patchdir in CASES:
    sub = root / name
    if git('rev-parse', '--git-dir', cwd=sub).returncode != 0 or not (sub / '.git').exists():
        print(f'SKIP: {name} submodule is not a git checkout')
        continue
    tree = git('diff', cwd=sub).stdout
    patches = sorted(patchdir.glob('*.patch'))
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / name
        if git('worktree', 'add', '--detach', '-q', str(work), 'HEAD', cwd=sub).returncode != 0:
            print(f'FAIL {name}: cannot make a worktree of the pin')
            ok = False
            continue
        try:
            applied = True
            for p in patches:
                r = git('apply', str(p), cwd=work)
                if r.returncode != 0:
                    print(f'FAIL {name}: {p.name} does not apply in order on the pin')
                    print('     ' + r.stderr.strip())
                    applied = False
                    ok = False
                    break
            if not applied:
                continue
            ran = True
            if not tree.strip():
                print(f'ok   {name}: {len(patches)} patch(es) apply in order on the pin '
                      '(working tree is clean here, nothing to compare)')
                continue
            have, want = files_of(strip_index(tree)), files_of(strip_index(git('diff', cwd=work).stdout))
            if have == want:
                print(f'ok   {name}: the working tree is exactly {patchdir.name} ({len(patches)} patch(es))')
            else:
                ok = False
                print(f'FAIL {name}: the working tree and {patchdir.name} are different changes')
                for f in sorted(set(have) | set(want)):
                    if have.get(f) != want.get(f):
                        where = ('in the tree only' if f not in want else
                                 'in a patch only' if f not in have else 'both, different')
                        print(f'     {f}: {where}')
        finally:
            git('worktree', 'remove', '--force', str(work), cwd=sub)
            git('worktree', 'prune', cwd=sub)

if not ran:
    print('SKIP: no patch stack could be applied')
    sys.exit(0)
print('PASS' if ok else 'FAILED')
sys.exit(0 if ok else 1)
