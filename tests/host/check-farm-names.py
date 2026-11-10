#!/usr/bin/env python3
"""Every Wine builtin in the app's DLL farms has a lowercase file name.

Wine's unix loader (find_builtin_dll in build/ntdll-unix/loader_ios.c) lowercases
the name a program imports before it opens <bundle>/<arch>-windows/<name>, and
the iOS file system is case-sensitive. A farm file named WLDAP32.dll is therefore
never found: Factorio (imports WLDAP32.dll) exited with c0000135 on Wave 13.
A macOS checkout (case-insensitive) hides this, so it is checked by name here.

Usage: check-farm-names.py [app/Madeira]   (or a built Madeira.app)
"""
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FARMS = ('arm64ec-windows', 'aarch64-windows', 'i386-windows', 'vulkan/arm64ec-windows')
SIGNATURE = b'Wine builtin DLL'


def main():
    base = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'app/Madeira'
    bad, checked = [], 0
    for farm in FARMS:
        folder = base / farm
        if not folder.is_dir():
            continue
        names = os.listdir(folder)
        lower = {}
        for name in names:
            lower.setdefault(name.lower(), []).append(name)
            path = folder / name
            if not path.is_file():
                continue
            with open(path, 'rb') as f:
                head = f.read(0x50)
            if head[0x40:0x50] != SIGNATURE:
                continue
            checked += 1
            if name != name.lower():
                bad.append(f'{farm}/{name} (Wine looks for {name.lower()})')
        for key, same in lower.items():
            if len(same) > 1:
                bad.append(f'{farm}: {", ".join(sorted(same))} differ only in case')
    if bad:
        print('FAIL: farm file names Wine cannot find on iOS:')
        for line in bad:
            print('  ' + line)
        return 1
    print(f'PASS: {checked} Wine builtins checked, all lowercase')
    return 0


if __name__ == '__main__':
    sys.exit(main())
