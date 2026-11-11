#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Russell Barton
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""build/ntdll-unix/process_ios.c: only a WoW64 process sets ProcessExecuteFlags (DEP), as on Windows.

is_wow64() answers for the session once any 32-bit pseudo-process has booted, so testing it would let a
64-bit caller turn DEP off, and virtual_set_force_exec, finding no guest window for it, would re-protect
every view of the session and copy the 32-bit processes' images into the JIT pool (Far Cry 4 loading
bink2w64.dll beside Ubisoft Connect). The calling thread's own TEB decides.

Checks, with the real `case ProcessExecuteFlags:` block of NtSetInformationProcess compiled on the host
(ASan/UBSan) against a model of the calling thread's TEB, the session-wide wow_peb, the per-window DEP
store (ml1354) and virtual_set_force_exec:
  - a 64-bit thread is refused (STATUS_INVALID_PARAMETER) and nothing is re-protected, with or without a
    32-bit process alive;
  - a 32-bit thread turns DEP off for its own process and on again, and is refused once its process made
    DEP permanent;
  - a wrong size is refused;
  - the block on main (8b52c18) lets the 64-bit thread through while a 32-bit process is alive, so the
    model catches the old behaviour.
Needs python3, git and a host C compiler (cc).
"""
from pathlib import Path
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


def set_block(source):
    """NtSetInformationProcess's `case ProcessExecuteFlags:` block, up to its closing `break;`."""
    start = source.index('    case ProcessExecuteFlags:\n', source.index('NTSTATUS WINAPI NtSetInformationProcess('))
    return source[start:source.index('\n        break;\n', start) + len('\n        break;\n')]


HARNESS = r'''
#include <stdio.h>
#include <string.h>

typedef unsigned int ULONG;
typedef int BOOL, NTSTATUS;
typedef unsigned long ULONG_PTR;
#define TRUE 1
#define FALSE 0
#define STATUS_SUCCESS           0
#define STATUS_INVALID_PARAMETER ((NTSTATUS)0xc000000d)
#define STATUS_ACCESS_DENIED     ((NTSTATUS)0xc0000022)
#define MEM_EXECUTE_OPTION_DISABLE   0x01
#define MEM_EXECUTE_OPTION_ENABLE    0x02
#define MEM_EXECUTE_OPTION_PERMANENT 0x08
enum { ProcessExecuteFlags = 34 };

typedef struct { ULONG WowTebOffset; } TEB;
static TEB thread_teb;                 /* the calling thread */
static void *wow_peb;                  /* session-wide: set once any 32-bit process booted */
static const BOOL is_win64 = TRUE;
static TEB *NtCurrentTeb( void ) { return &thread_teb; }
static BOOL is_wow64( void ) { return thread_teb.WowTebOffset || wow_peb; }   /* wine unix_private.h, ios */

/* ml1354: a 32-bit thread's own window holds its process's flags; a 64-bit one has none. */
static ULONG window_flags, execute_flags;
ULONG ios_wow_exec_flags_current( ULONG fallback ) { return thread_teb.WowTebOffset ? window_flags : fallback; }
int ios_wow_exec_flags_store_current( ULONG flags )
{
    if (!thread_teb.WowTebOffset) return 0;
    window_flags = flags;
    return 1;
}
static int sweeps, last_enable = -1;
static void virtual_set_force_exec( BOOL enable ) { sweeps++; last_enable = enable; }

static NTSTATUS set_execute_flags( void *info, ULONG size )
{
    switch (ProcessExecuteFlags)
    {
@BLOCK@
    }
    return STATUS_SUCCESS;
}

static int bad;
static void expect( int ok, const char *what ) { printf( "%s: %s\n", ok ? "PASS" : "FAIL", what ); bad += !ok; }

int main( void )
{
    ULONG off = MEM_EXECUTE_OPTION_ENABLE, on = MEM_EXECUTE_OPTION_DISABLE;
    ULONG permanent = MEM_EXECUTE_OPTION_DISABLE | MEM_EXECUTE_OPTION_PERMANENT;
    NTSTATUS st;

    wow_peb = (void *)0x7800311000;   /* Ubisoft Connect's 32-bit processes are alive */
    thread_teb.WowTebOffset = 0;      /* FarCry4.exe, 64-bit */
    st = set_execute_flags( &off, sizeof(off) );
#ifdef OLD
    expect( st == STATUS_SUCCESS && sweeps == 1 && execute_flags == off,
            "main lets a 64-bit thread turn DEP off session-wide while a 32-bit process is alive (the old behaviour)" );
    return bad;
#else
    expect( st == STATUS_INVALID_PARAMETER && !sweeps && !execute_flags,
            "a 64-bit thread is refused while a 32-bit process is alive, and nothing is re-protected" );
    wow_peb = NULL;
    st = set_execute_flags( &off, sizeof(off) );
    expect( st == STATUS_INVALID_PARAMETER && !sweeps, "and with no 32-bit process at all, as before" );

    wow_peb = (void *)0x7200311000;
    thread_teb.WowTebOffset = 0x2000; /* upc.exe, 32-bit */
    st = set_execute_flags( &off, sizeof(off) );
    expect( st == STATUS_SUCCESS && sweeps == 1 && last_enable == TRUE && window_flags == off && !execute_flags,
            "a 32-bit thread turns DEP off for its own process" );
    st = set_execute_flags( &on, sizeof(on) );
    expect( st == STATUS_SUCCESS && sweeps == 2 && last_enable == FALSE, "and on again" );
    st = set_execute_flags( &permanent, sizeof(permanent) );
    expect( st == STATUS_SUCCESS && sweeps == 3, "and makes it permanent" );
    st = set_execute_flags( &off, sizeof(off) );
    expect( st == STATUS_ACCESS_DENIED && sweeps == 3, "after which it is refused" );
    st = set_execute_flags( &off, 2 );
    expect( st == STATUS_INVALID_PARAMETER && sweeps == 3, "a wrong size is refused" );
    return bad;
#endif
}
'''

if not shutil.which('cc'):
    print('SKIP: no host C compiler (cc)')
    sys.exit(0)

current = (root / 'build/ntdll-unix/process_ios.c').read_text(encoding='utf-8')
old = subprocess.run(['git', 'show', '8b52c18:build/ntdll-unix/process_ios.c'], cwd=root,
                     capture_output=True, text=True)
work = Path(tempfile.mkdtemp(prefix='check-dep-caller-'))
try:
    cases = [('this tree', set_block(current), [])]
    if old.returncode == 0:
        cases.append(('main 8b52c18', set_block(old.stdout), ['-DOLD']))
    else:
        print('SKIP: main 8b52c18 not in this repository; the old behaviour was not tried')
    for name, block, defs in cases:
        c, exe = work / 'model.c', work / 'model'
        c.write_text(HARNESS.replace('@BLOCK@', block), encoding='utf-8')
        cc = subprocess.run(['cc', '-std=gnu11', '-g', '-O1', '-Wall', '-Wno-unused-function', *defs,
                             '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined',
                             str(c), '-o', str(exe)], capture_output=True, text=True)
        require(cc.returncode == 0, f'the model builds ({name})')
        if cc.returncode:
            print(cc.stderr[-3000:])
            continue
        result = subprocess.run([str(exe)], capture_output=True, text=True)
        print(result.stdout, end='')
        if result.stderr.strip():
            print(result.stderr[-2000:])
        require(result.returncode == 0, f'the model passes ({name})')
finally:
    shutil.rmtree(work, ignore_errors=True)

print('PASS: all ProcessExecuteFlags caller checks' if not failures else f'FAILED: {failures} check(s)')
sys.exit(1 if failures else 0)
