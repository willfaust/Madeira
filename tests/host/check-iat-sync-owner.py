#!/usr/bin/env python3
"""The NtProtectVirtualMemory IAT sync writes the WRITING process's pool copy; no Wine runs.

GTA V Enhanced: the GTA5_Enhanced child's boot thread protects ntdll. ntdll has
one PE range and several pool copies (the session copy, owner NULL, and the
child's private copy). The sync took the FIRST copy whose PE range holds the
region, so the child's change landed in the parent's ntdll copy and never in
its own.

Compiles the production ios_iat_sync_pick_mapping (build/ntdll-unix/
virtual_ios.c) against a model of the mapping table. Checks:
  - the child writes its own copy; the parent (no own copy) and an unknown
    process write the NULL-owner session copy; a plain image (one copy) is
    unchanged; a region outside every image picks nothing;
  - a NULL-owner copy registered after a child copy still wins for the parent;
  - the NtProtectVirtualMemory sync loop only syncs the picked copy.
Needs python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


def between(source, first, last):
    start = source.index(first)
    return source[start:source.index(last, start) + len(last)] + '\n'


# The sync loop must use the pick, not the first containing mapping.
sync = native[native.index('int sync_pick = ios_iat_sync_pick_mapping('):][:1200]
assert 'iOS NtProtect-sync: triggered' in sync, sync
assert 'if (idx != sync_pick) continue;' in sync, sync

code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
'''
code += between(native, '#define IOS_JIT_MAX_MAPPINGS', '\n};')
code += 'static struct ios_jit_mapping ios_jit_mappings[IOS_JIT_MAX_MAPPINGS];\n'
code += 'static int ios_jit_mapping_count = 0;\n'
code += function(native, 'static int ios_iat_sync_pick_mapping( uintptr_t rgn_start, uintptr_t rgn_end, void *peb )')
code += r'''
#define NT      0x71ffcd0000ull
#define NT_SZ   0x130000ull
#define PLAIN   0x71e0000000ull
#define MAIN    ((void *)0x71ffff0000ull)
#define CHILD   ((void *)0x10a238000ull)
#define CHILD2  ((void *)0x10b000000ull)
static void map( int i, uint64_t pe, uint64_t jit, size_t sz, void *owner )
{
    ios_jit_mappings[i].pe_base = (void *)pe;
    ios_jit_mappings[i].jit_base = (void *)jit;
    ios_jit_mappings[i].size = sz;
    ios_jit_mappings[i].owner_peb = owner;
    if (i >= ios_jit_mapping_count) ios_jit_mapping_count = i + 1;
}
static int pick( uint64_t a, size_t sz, void *peb ) { return ios_iat_sync_pick_mapping( a, a + sz, peb ); }

int main( void )
{
    const uint64_t hook = NT + 0x90520;
    map( 0, NT,    0x148000000ull, NT_SZ,   NULL );   /* session ntdll copy */
    map( 1, PLAIN, 0x149000000ull, 0x40000, NULL );   /* an image with one copy */
    map( 2, NT,    0x14fba8000ull, NT_SZ,   CHILD );  /* GTA5_Enhanced's ntdll copy */
    map( 3, NT,    0x150000000ull, NT_SZ,   CHILD2 ); /* another child's copy */

    assert( pick( PLAIN + 0x2000, 0x1000, CHILD ) == 1 );    /* one copy: as before */
    assert( pick( PLAIN + 0x2000, 0x1000, MAIN ) == 1 );
    assert( pick( 0x1000, 0x1000, CHILD ) == -1 );           /* outside every image */
    assert( pick( NT + 0x12ff00, 0x1000, CHILD ) == -1 );    /* runs past the image end */
    assert( pick( hook, 7, MAIN ) == 0 );                    /* parent: session copy */
    assert( pick( hook, 7, NULL ) == 0 );                    /* unknown process: session copy */
    assert( pick( hook, 7, CHILD ) == 2 );                   /* the child's own copy */
    assert( pick( hook, 7, CHILD2 ) == 3 );

    /* the NULL-owner copy wins for the parent even when a child copy is listed first */
    ios_jit_mapping_count = 0;
    map( 0, NT, 0x14fba8000ull, NT_SZ, CHILD );
    map( 1, NT, 0x148000000ull, NT_SZ, NULL );
    assert( pick( hook, 7, MAIN ) == 1 );
    assert( pick( hook, 7, CHILD ) == 0 );
    printf( "each process syncs its own copy, main processes as before\n" );
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-iat-sync-owner-') as directory:
    folder = Path(directory)
    source = folder / 'check.c'
    source.write_text(code)
    executable = folder / 'check'
    cc = os.environ.get('CC', 'cc')
    flags = [cc, '-std=gnu11', '-Wall', '-Wextra', '-Wno-unused-function', '-Wno-unused-parameter',
             '-Werror', '-g', str(source), '-o', str(executable)]
    sanitize = ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    if subprocess.run(flags[:1] + sanitize + flags[1:], capture_output=True).returncode == 0:
        print('built with AddressSanitizer/UBSan')
    else:
        r = subprocess.run(flags, capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        print('built without sanitizers')
    result = subprocess.run([str(executable)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
print('PASS: the IAT sync writes the pool copy of the process that made the change')
