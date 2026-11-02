#!/usr/bin/env python3
"""A pseudo-process child's emulator gets the child's own ntdll copy; no Wine runs.

Compiles the production alias-push code from build/ntdll-unix/virtual_ios.c
(ios_jit_add_mapping, unixcall_ios_push_jit_aliases and its helpers, the
callback drop in ios_jit_reclaim_process) against a model of FEX's alias table
(FEX/Source/Windows/ARM64EC/IosJitAlias.cpp: one entry per PE range, an
overlapping add retires the older entry, reverse translation walks
oldest-first) with one table per emulator, as on the device where every x64
pseudo-process loads its own libarm64ecfex.dll.

Replays a GTA V Enhanced child layout: ntdll at PE 0x71ffcd0000, session copy
0x1483e0000, child copy 0x14fba8000. Checks that
  - the main process's emulator gets exactly what it got before (parent copy);
  - a child's emulator maps ntdll to the child's copy, so the child's pool alias
    of invoke_arm64ec_syscall (copy + 0x87050) reverse-translates to the PE VA,
    which is what [pool-rip-fix] needs;
  - a dead (size 0) copy is never taken for the child's own;
  - a dying registrant's callback is dropped before its pool is reclaimed;
  - with per-process pushes (MADEIRA_ALIAS_PER_PROCESS, on by default; 0 is
    the last-registrant rule above) an image goes to the emulator of the
    process that maps it, a process whose emulator has not registered yet
    keeps its images for its own drain, and a registration drains its own
    mappings first and other processes' only while 96 of FEX's 256 entries
    stay free (GTA V Enhanced build 372: RockstarService.exe started with a
    nearly full table and died in its WINTRUST/cryptnet delay-load stubs).
The harness runs once per mode.
Needs python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import re
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


# The callback drop runs before the pool is reclaimed.
reclaim = function(native, 'void ios_jit_reclaim_process( void *peb )')
drop = re.search(r'    ios_alias_cb_drop\( peb \);[^\n]*\n'
                 r'    if \(peb == ios_jit_alias_pushback_peb && ios_jit_alias_pushback_cb\)\n    \{\n.*?\n    \}\n',
                 reclaim, re.S)
assert drop and drop.start() < reclaim.index('pthread_mutex_lock( &ios_pool_lock )'), \
    'the dying registrant must lose the callback before its pool copy is reclaimed'

code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef int NTSTATUS;
#define STATUS_SUCCESS 0
#define STATUS_INVALID_PARAMETER ((NTSTATUS)0xC000000D)
#define ERR(...) do { } while (0)
static void *cur_peb;
void *ios_jit_current_peb(void) { return cur_peb; }
int ios_subfloor_enum( int idx, unsigned long long *low, unsigned long long *real, unsigned long long *size,
                       void **owner )
{ (void)idx; (void)low; (void)real; (void)size; (void)owner; return 0; }
void ios_push_subfloor_window( unsigned long long a, unsigned long long b, unsigned long long c, void *owner )
{ (void)a; (void)b; (void)c; (void)owner; }
static void ios_resolve_fex_exports( void ) { }
/* The modelled images are not mapped here; none of them is FEX's own module. */
static unsigned char ios_image_is_fex( const void *pe_base, size_t size ) { (void)pe_base; (void)size; return 0; }
'''
code += between(native, '#define IOS_JIT_MAX_MAPPINGS', '\n};')
code += 'static struct ios_jit_mapping ios_jit_mappings[IOS_JIT_MAX_MAPPINGS];\n'
code += 'static int ios_jit_mapping_count = 0;\n'
start = native.index('static void (*ios_jit_alias_pushback_cb)')
end = native.index('\n}', native.index('static void ios_alias_cb_drop( void *peb )', start)) + 2
code += native[start:end] + '\n'   # the callback, its owner, the per-process callbacks and their lookups
code += function(native, 'void ios_jit_add_mapping(void *pe_base, void *jit_base, size_t size)')
code += between(native, 'struct ios_push_jit_aliases_args {', '\n};')
code += function(native, 'static int ios_jit_owned_copy( void *pe_base, void *peb )')
code += function(native, 'static int ios_jit_alias_drain_wants( int i, void *own )')
code += function(native, 'NTSTATUS unixcall_ios_push_jit_aliases(void *args)')
code += 'static void reclaim_drop( void *peb )\n{\n' + drop.group(0) + '}\n'
code += r'''
/* ---- model of one emulator's alias table (IosJitAlias.cpp) ---- */
struct fex { struct { uint64_t pe, jit, size; } e[256]; int n; int adds; };
static struct fex fex_main, fex_child;
static void fex_add( struct fex *f, uint64_t pe, uint64_t jit, uint64_t size )
{
    f->adds++;
    if (pe < 0x100000000ull) return;                       /* sub-floor table, not modelled */
    for (int i = 0; i < f->n; i++)
        if (f->e[i].pe == pe && f->e[i].jit == jit && f->e[i].size == size) return;
    for (int i = 0; i < f->n; i++)                          /* retire PE overlaps */
        if (f->e[i].size && f->e[i].pe < pe + size && pe < f->e[i].pe + f->e[i].size) f->e[i].size = 0;
    for (int i = 0; i < f->n; i++)
        if (!f->e[i].size) { f->e[i].pe = pe; f->e[i].jit = jit; f->e[i].size = size; return; }
    f->e[f->n].pe = pe; f->e[f->n].jit = jit; f->e[f->n].size = size; f->n++;
}
static uint64_t fex_rev( struct fex *f, uint64_t a )
{
    for (int i = 0; i < f->n; i++)
        if (a >= f->e[i].jit && a < f->e[i].jit + f->e[i].size) return f->e[i].pe + (a - f->e[i].jit);
    return a;
}
static uint64_t fex_fwd( struct fex *f, uint64_t a )
{
    for (int i = 0; i < f->n; i++)
        if (a >= f->e[i].pe && a < f->e[i].pe + f->e[i].size) return f->e[i].jit + (a - f->e[i].pe);
    return a;
}
static void cb_main( unsigned long long p, unsigned long long j, unsigned long long s ) { fex_add( &fex_main, p, j, s ); }
static void cb_child( unsigned long long p, unsigned long long j, unsigned long long s ) { fex_add( &fex_child, p, j, s ); }
static struct fex fex_svc;
static void cb_svc( unsigned long long p, unsigned long long j, unsigned long long s ) { fex_add( &fex_svc, p, j, s ); }

#define MAIN_PEB  ((void *)0x71ffff0000ull)
#define CHILD_PEB ((void *)0x10999c000ull)
#define NT_PE     0x71ffcd0000ull
#define NT_SIZE   0x130000ull
#define NT_MAIN   0x1483e0000ull
#define NT_CHILD  0x14fba8000ull
#define SYSCALL_HELPER 0x87050ull   /* invoke_arm64ec_syscall */

static void add_child_copy( uint64_t jit, size_t size, void *owner )
{   /* what ios_jit_copy_module_for_child appends */
    int s = ios_jit_mapping_count++;
    ios_jit_mappings[s].jit_base = (void *)jit;
    ios_jit_mappings[s].size = size;
    ios_jit_mappings[s].owner_peb = owner;
    ios_jit_mappings[s].map_peb = owner;
    ios_jit_mappings[s].pe_base = (void *)NT_PE;
}

int main( int argc, char **argv )
{
    const int pp = argc > 1 && !strcmp( argv[1], "pp" );   /* per-process pushes */
    struct ios_push_jit_aliases_args reg;

    /* Session boot: ntdll and an image, then the main emulator registers. */
    cur_peb = MAIN_PEB;
    ios_jit_add_mapping( (void *)NT_PE, (void *)NT_MAIN, NT_SIZE );
    ios_jit_add_mapping( (void *)0x71fe8c0000ull, (void *)0x148518000ull, 0x40f000 );   /* libarm64ecfex */
    assert( ios_jit_mappings[0].map_peb == MAIN_PEB );
    reg.callback = cb_main;
    assert( unixcall_ios_push_jit_aliases( &reg ) == STATUS_SUCCESS );
    assert( ios_jit_alias_pushback_peb == MAIN_PEB );
    assert( fex_main.adds == 2 );
    assert( fex_fwd( &fex_main, NT_PE + 0x6a744 ) == NT_MAIN + 0x6a744 );
    assert( fex_rev( &fex_main, NT_MAIN + SYSCALL_HELPER ) == NT_PE + SYSCALL_HELPER );   /* [pool-rip-fix] in main */
    ios_jit_add_mapping( (void *)0x138210000ull, (void *)0x148a00000ull, 0x10000 );        /* PlayGTAV.exe */
    assert( fex_rev( &fex_main, 0x148a00010ull ) == 0x138210010ull );

    /* Child: private ntdll copy (plus a dead copy left by an earlier child that
     * had the same PEB), then images mapped BEFORE its emulator registers. */
    add_child_copy( 0x160000000ull, NT_SIZE, CHILD_PEB );
    ios_jit_mappings[ios_jit_mapping_count - 1].size = 0;     /* tombstone (size 0 first) */
    add_child_copy( NT_CHILD, NT_SIZE, CHILD_PEB );
    cur_peb = CHILD_PEB;
    ios_jit_add_mapping( (void *)0x140000000ull, (void *)0x14a022000ull, 0x5b81000 );     /* GTA5_Enhanced.exe */
    ios_jit_add_mapping( (void *)0x71fcdb0000ull, (void *)0x14fce0000ull, 0x40f000 );     /* its libarm64ecfex */
    /* per-process: the child keeps them for its own drain; old rule: the main gets them */
    assert( fex_rev( &fex_main, 0x14a022010ull ) == (pp ? 0x14a022010ull : 0x140000010ull) );
    int main_adds = fex_main.adds;

    reg.callback = cb_child;
    assert( unixcall_ios_push_jit_aliases( &reg ) == STATUS_SUCCESS );
    assert( ios_jit_alias_pushback_peb == CHILD_PEB );
    assert( fex_main.adds == main_adds );                       /* the main table is untouched */
    assert( fex_fwd( &fex_main, NT_PE + 0x6a744 ) == NT_MAIN + 0x6a744 );
    assert( fex_child.adds == 5 );                              /* 4 shared images + ntdll once */
    assert( fex_rev( &fex_child, 0x14a022010ull ) == 0x140000010ull );                     /* drained */
    assert( fex_rev( &fex_child, 0x148a00010ull ) == 0x138210010ull );                     /* shared entries too */
    assert( fex_rev( &fex_child, NT_CHILD + SYSCALL_HELPER ) == NT_PE + SYSCALL_HELPER );  /* the fix */
    assert( fex_fwd( &fex_child, NT_PE + 0x6a744 ) == NT_CHILD + 0x6a744 );              /* own copy for EC calls */
    assert( fex_rev( &fex_child, NT_MAIN + SYSCALL_HELPER ) == NT_MAIN + SYSCALL_HELPER );
    assert( fex_rev( &fex_child, 0x160000000ull + SYSCALL_HELPER ) == 0x160000000ull + SYSCALL_HELPER );

    /* After the child registered: the main maps an image, the child maps one.
     * Per-process: each goes to its own emulator. Old rule: both go to the
     * child's, the last registrant. */
    cur_peb = MAIN_PEB;
    ios_jit_add_mapping( (void *)0x71f0000000ull, (void *)0x151000000ull, 0x10000 );
    if (pp)
    {
        assert( fex_rev( &fex_main, 0x151000010ull ) == 0x71f0000010ull );
        assert( fex_rev( &fex_child, 0x151000010ull ) == 0x151000010ull );
        main_adds = fex_main.adds;
    }
    else
        assert( fex_rev( &fex_child, 0x151000010ull ) == 0x71f0000010ull );
    cur_peb = CHILD_PEB;
    ios_jit_add_mapping( (void *)0x71f1000000ull, (void *)0x151100000ull, 0x10000 );
    assert( fex_rev( &fex_child, 0x151100010ull ) == 0x71f1000010ull );

    /* The child dies: its callback is dropped; the next map by the child calls
     * nothing, the main's goes to the main's own emulator (per-process) or
     * nowhere (old rule). */
    int child_adds = fex_child.adds;
    reclaim_drop( MAIN_PEB );                                   /* not the registrant: kept */
    assert( ios_jit_alias_pushback_cb == cb_child );
    if (pp) ios_alias_cb_set( MAIN_PEB, cb_main );              /* the main lives on: its own callback stays */
    reclaim_drop( CHILD_PEB );
    assert( !ios_jit_alias_pushback_cb && !ios_jit_alias_pushback_peb );
    assert( !ios_alias_cb_for( CHILD_PEB ) );
    cur_peb = CHILD_PEB;                                        /* a late thread of the child maps: nowhere */
    ios_jit_add_mapping( (void *)0x71f3000000ull, (void *)0x151300000ull, 0x10000 );
    assert( fex_child.adds == child_adds );
    cur_peb = MAIN_PEB;
    ios_jit_add_mapping( (void *)0x71f2000000ull, (void *)0x151200000ull, 0x10000 );
    assert( fex_child.adds == child_adds );
    if (pp)
        assert( fex_main.adds == main_adds + 1 && fex_rev( &fex_main, 0x151200010ull ) == 0x71f2000010ull );
    else
        assert( fex_main.adds == main_adds );

    /* Build 372: a service registers while 300 images of another process are in
     * the table. Its own come first and all of them land; the others stop at
     * 256 - 96 pushes; a late image it maps (WINTRUST) still finds room. */
    if (pp)
    {
        void *const SVC = (void *)0x10eea8000ull, *const OTHER = (void *)0x107a00000ull;
        int k;
        cur_peb = OTHER;
        for (k = 0; k < 300; k++)
            ios_jit_add_mapping( (void *)(0x7000000000ull + k * 0x100000ull), (void *)(0x160000000ull + k * 0x100000ull), 0x10000 );
        cur_peb = SVC;
        for (k = 0; k < 40; k++)
            ios_jit_add_mapping( (void *)(0x7200000000ull + k * 0x100000ull), (void *)(0x190000000ull + k * 0x100000ull), 0x10000 );
        reg.callback = cb_svc;
        assert( unixcall_ios_push_jit_aliases( &reg ) == STATUS_SUCCESS );
        assert( fex_svc.n <= 256 - 96 );
        for (k = 0; k < 40; k++)
            assert( fex_rev( &fex_svc, 0x190000010ull + k * 0x100000ull ) == 0x7200000010ull + k * 0x100000ull );
        ios_jit_add_mapping( (void *)0x7300000000ull, (void *)0x1a0000000ull, 0x10000 );      /* WINTRUST */
        assert( fex_rev( &fex_svc, 0x1a0000010ull ) == 0x7300000010ull );
        cur_peb = OTHER;                                        /* no emulator yet: kept for its own drain */
        ios_jit_add_mapping( (void *)0x7310000000ull, (void *)0x1a1000000ull, 0x10000 );
        assert( fex_rev( &fex_svc, 0x1a1000010ull ) == 0x1a1000010ull );
        cur_peb = NULL;                                         /* no PEB at all: the last registrant */
        ios_jit_add_mapping( (void *)0x7318000000ull, (void *)0x1a1800000ull, 0x10000 );
        assert( fex_rev( &fex_svc, 0x1a1800010ull ) == 0x7318000010ull );
        cur_peb = OTHER;
        ios_alias_cb_set( OTHER, cb_main );                     /* with one: its own, not the service's */
        ios_jit_add_mapping( (void *)0x7320000000ull, (void *)0x1a2000000ull, 0x10000 );
        assert( fex_rev( &fex_svc, 0x1a2000010ull ) == 0x1a2000010ull );
        assert( fex_rev( &fex_main, 0x1a2000010ull ) == 0x7320000010ull );
    }
    printf( "PASS (%s): child gets its own ntdll copy, main unchanged\n",
            pp ? "per-process pushes" : "the last registrant gets the pushes" );
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-child-ntdll-alias-') as directory:
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
    for value, mode in [(None, 'pp'), ('1', 'pp'), ('', 'pp'), ('0', 'last')]:
        env = dict(os.environ)
        env.pop('MADEIRA_ALIAS_PER_PROCESS', None)
        if value is not None:
            env['MADEIRA_ALIAS_PER_PROCESS'] = value
        result = subprocess.run([str(executable), mode], env=env, capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        print(f'MADEIRA_ALIAS_PER_PROCESS={value!r}: {result.stdout.strip()}')
        err = result.stderr
        assert err.count('[alias-push] peb=0x10999c000 registered its emulator: 1 image(s) mapped to this '
                         'process\'s own copy') == 1, err
        assert '[alias-push] peb=0x71ffff0000 registered' not in err, err
        assert err.count('callback dropped before its pool copy is reclaimed') == 1, err
        left = re.findall(r'\[alias-push\] peb=(0x[0-9a-f]+): (\d+) mapping\(s\) pushed, (\d+) of other processes '
                          r'left out to keep 96 table entries free', err)
        if mode == 'pp':
            assert len(left) == 1 and left[0][0] == '0x10eea8000' and int(left[0][1]) == 256 - 96 \
                and int(left[0][2]) > 0, err
        else:
            assert not left, err
print('PASS: a child emulator maps ntdll to the child copy, the main is unchanged, '
      'a dead registrant loses the callback; per-process pushes (default) route each image to the '
      'emulator of the process that maps it and keep room in a new table for late images')
