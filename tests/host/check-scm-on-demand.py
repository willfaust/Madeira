#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml2270, from testers' logs of 2026-10-28: the Epic copy of a game ran a launcher installer on its first start,
which registers the launcher's service. The session had not started services.exe, so OpenSCManager failed
(\\pipe\\svcctl not found, RPC_S_SERVER_UNAVAILABLE), the service helper exited 1 and the installer stopped.

- wine/dlls/sechost/service.c: OpenSCManagerW starts services.exe once per process when the svcctl pipe does
  not exist, waits up to 20 s for it and asks again (env.MADEIRA_SCM_ON_DEMAND=0 restores the old behaviour);
- app/Madeira/arm64ec-windows/sechost.dll is rebuilt from that source.

Static anchors only.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(src, name, stop='\n}\n'):
    i = src.index(name)
    return src[i:src.index(stop, i)]

src = ROOT / 'wine/dlls/sechost/service.c'
if src.exists():
    s = src.read_text(encoding='utf-8', errors='replace')
    start = body(s, 'static BOOL start_scm_on_demand(void)\n{')
    check('L"MADEIRA_SCM_ON_DEMAND"' in start and "env[0] == '0') return FALSE;" in start,
          'env.MADEIRA_SCM_ON_DEMAND=0 restores the old behaviour, default on')
    check('InterlockedExchange( &tried, 1 )' in start, 'at most one start per process')
    check('GetLastError() != ERROR_FILE_NOT_FOUND) return FALSE;' in start,
          'only when the svcctl pipe does not exist (a busy pipe is a running manager)')
    check('!wcsicmp( name, L"services.exe" )' in start, 'never from services.exe itself')
    check('i < 200' in start and 'Sleep( 100 );' in start, 'the wait for the pipe is bounded (20 s)')
    scm = body(s, 'SC_HANDLE WINAPI DECLSPEC_HOTPATCH OpenSCManagerW(')
    check('attempt < 2' in scm and 'err != RPC_S_SERVER_UNAVAILABLE || attempt || (machine && *machine) || !start_scm_on_demand()' in scm,
          'one retry, only for an unavailable local service manager')
else:
    print('SKIP: wine sources not checked out')

dll = ROOT / 'app/Madeira/arm64ec-windows/sechost.dll'
check(dll.exists() and 'MADEIRA_SCM_ON_DEMAND'.encode('utf-16-le') in dll.read_bytes(),
      'the bundled ARM64EC sechost.dll carries the switch')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    check('key: "env.MADEIRA_SCM_ON_DEMAND"' in catalog.read_text(encoding='utf-8'),
          'the config catalog documents env.MADEIRA_SCM_ON_DEMAND')

print(f'check-scm-on-demand: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
