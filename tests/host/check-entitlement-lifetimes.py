#!/usr/bin/env python3
"""Check real Security.framework entitlement reads and CF ownership on macOS.
Executes the production checker against an absent entitlement.
Requires Xcode's Swift compiler and leaks; no certificate or iPad.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

if sys.platform != 'darwin':
    print('SKIP: requires macOS Security.framework and leaks')
    raise SystemExit(0)
root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/EntitlementChecker.swift').read_text()
helper = source[:source.index('struct EntitlementStatus')].replace('import UIKit\n', '')
main = r'''
for _ in 0..<2000 {
    autoreleasepool {
        precondition(!checkAppEntitlement("com.madeira.tests.absent"))
    }
}
print("PASS 2000 absent-entitlement reads through Security.framework")
'''
with tempfile.TemporaryDirectory(prefix='madeira-entitlements-') as directory:
    tmp = Path(directory)
    src, exe = tmp / 'main.swift', tmp / 'madeira-ownership-probe'
    src.write_text(helper + main)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-g', str(src), '-o', str(exe)], check=True)
    log = tmp / 'leaks.log'
    with log.open('w') as output:
        result = subprocess.run(['leaks', '--atExit', '--', str(exe)], stdout=output, stderr=subprocess.STDOUT, timeout=30)
    report = log.read_text()
    for line in report.splitlines():
        if 'absent-entitlement reads' in line or 'total leaked bytes' in line or 'STACK OF' in line:
            print(line)
    assert 'PASS 2000 absent-entitlement reads' in report, f'leaks exit={result.returncode}: {report[-4000:]}'
    assert re.search(r'\b0 leaks for 0 total leaked bytes\.', report), 'FAIL: entitlement reads leaked allocations'
    assert result.returncode == 0, f'leaks exited {result.returncode}'
    print('PASS no leaked task objects with real Create/Copy Security APIs')
