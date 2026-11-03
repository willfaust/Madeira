#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Madeira contributors
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Runs GOGSetup's tests (tests/host/gog-setup) and Playport's Galaxy service tests (tests/host/gog-galaxy) against the app's copy
in app/Madeira/SwiftGOG/Galaxy, as a temporary Swift package. Needs `swift`; without
it the check is skipped (exit 0) unless --require-swift."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
if shutil.which('swift') is None:
    print('check-gog-galaxy: swift unavailable; skipped')
    sys.exit(1 if '--require-swift' in sys.argv else 0)
with tempfile.TemporaryDirectory() as tmp:
    exe = Path(tmp) / 'gog-setup'
    r = subprocess.run(['swiftc', '-static-stdlib', str(root / 'tests/host/gog-setup/Stubs.swift'),
                        str(root / 'app/Madeira/SwiftGOG/GOGSetup.swift'), str(root / 'tests/host/gog-setup/main.swift'),
                        '-o', str(exe)], capture_output=True, text=True)
    run = subprocess.run([str(exe)], capture_output=True, text=True) if r.returncode == 0 else None
    if run is None or 'ALL OK' not in run.stdout:
        print(r.stderr[-2000:] + (run.stdout[-2000:] + run.stderr[-2000:] if run else ''))
        print('check-gog-galaxy: FAIL (GOGSetup)')
        sys.exit(1)
    print('GOGSetup: ok')
with tempfile.TemporaryDirectory() as tmp:
    pkg = Path(tmp)
    (pkg / 'Sources/G').mkdir(parents=True)
    (pkg / 'Tests/GTests').mkdir(parents=True)
    for f in (root / 'app/Madeira/SwiftGOG/Galaxy').glob('*.swift'):
        shutil.copy(f, pkg / 'Sources/G' / f.name)
    shutil.copy(root / 'tests/host/gog-galaxy/Stub.swift', pkg / 'Sources/G/Stub.swift')
    shutil.copy(root / 'tests/host/gog-galaxy/GalaxyTests.swift', pkg / 'Tests/GTests/GalaxyTests.swift')
    (pkg / 'Package.swift').write_text('// swift-tools-version:5.9\nimport PackageDescription\n'
                                       'let package = Package(name: "G", targets: [.target(name: "G"), '
                                       '.testTarget(name: "GTests", dependencies: ["G"])])\n')
    r = subprocess.run(['swift', 'test'], cwd=pkg, capture_output=True, text=True)
    out = r.stdout + r.stderr
    print('\n'.join(l for l in out.splitlines() if 'error' in l or 'Executed' in l or 'failed' in l))
    print('check-gog-galaxy: ' + ('ok' if r.returncode == 0 else 'FAIL'))
    sys.exit(r.returncode)
