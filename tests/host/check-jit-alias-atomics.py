#!/usr/bin/env python3
"""LSE atomics on aliased pages: the Mach store emulator's LD<OP> and CAS case.

FEX lowers a guest LOCK ADD/SUB/XADD/INC/DEC, AND, OR, XOR and CMPXCHG to
LDADDAL, LDCLRAL, LDSETAL, LDEORAL and CASAL. On anonymous RWX memory the page
is RX on the host, so the access faults and the Mach exception thread has to
complete it through the RW alias. It had no case for these, and sent the fault
back to the guest (issue #123: LDADDAL W6, W0, [X1], 0xb8e60020).

Compiles the production ios_mach_emulate_rmw and the decoder case that calls it
(build/ntdll-unix/signal_arm64_ios.c) against real shared mappings: a writable
view stands for the RW alias, a read-only view of the same pages for the view
that faulted. Checks:
  - LDADD/LDCLR/LDEOR/LDSET, every size and A/R form, against a model: the new
    value lands through the alias, neighbouring bytes are untouched, Rt gets the
    zero-extended old value, Rt = 31 (ST<OP>) discards it, Rs = 31 reads zero,
    Rs = Rt works;
  - CAS/CASA/CASL/CASAL, B/H/W/X: success and failure compare only the low
    bits, Rs gets the zero-extended old value, Rt = 31 stores zero;
  - the decoder case: x29/x30 as Rs/Rt go through FP/LR, SP is never written,
    CAS is taken only off the pool, SWP/LDSMAX/LDAPR/CASP/LDAXR/STLXR/STP are
    not taken, and a misaligned access is refused with nothing changed;
  - atomicity: threads doing emulated LDADDAL, CASAL, LDSETAL and LDCLRAL on the
    alias race threads doing host atomics through another writable view of the
    same pages, and no update is lost.
Needs python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()


def between(first, last):
    start = source.index(first)
    return source[start:source.index(last, start) + len(last)] + '\n'


helper = between('#define IOS_MACH_RMW(type)', '#undef IOS_MACH_RMW')
case_start = source.index('                    else if ((insn & 0x3f20cc00u) == 0x38200000u ||')
case_end = source.index("                    /* FEX's native backpatch lock uses CASAL on the pool RX", case_start)
case = source[case_start:case_end]
assert 'ios_mach_emulate_rmw( insn, rw_addr, gpr )' in case
# It continues the decoder's else-if chain after SWP, ahead of the [store-undecoded] report.
assert source.index('else if ((insn & 0x3F20FC00) == 0x38208000)') < case_start
assert source.index('[store-undecoded] #%d', case_start) > case_end

code = r'''
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>
'''
code += helper
code += r'''
/* The general-purpose part of Darwin's arm_thread_state64_t. */
struct thread_state { uint64_t __x[29], __fp, __lr, __sp; };

static int route( uint32_t insn, uintptr_t rw_addr, int in_jit, struct thread_state *st )
{
    struct thread_state state = *st;
    uintptr_t fault_addr = rw_addr;
    uint64_t fault_pc = 0x16d2312e0ull;
    int emulated = 0;

    (void)in_jit;
    if (0) {}
''' + case + r'''
    *st = state;
    return emulated;
}

static unsigned char *rw, *rx, *rw2;   /* RW alias, the view that faulted, another writable view */

static uint32_t ldop( unsigned size, unsigned a, unsigned r, unsigned rs, unsigned op, unsigned rn, unsigned rt )
{
    return 0x38200000u | size << 30 | a << 23 | r << 22 | rs << 16 | op << 12 | rn << 5 | rt;
}
static uint32_t cas( unsigned size, unsigned l, unsigned rs, unsigned o0, unsigned rn, unsigned rt )
{
    return 0x08a07c00u | size << 30 | l << 22 | rs << 16 | o0 << 15 | rn << 5 | rt;
}
static uint64_t width_mask( unsigned size ) { return size == 3 ? ~0ull : (1ull << (8u << size)) - 1; }
static uint64_t model( unsigned op, uint64_t old, uint64_t s )
{
    switch (op)
    {
    case 0:  return old + s;
    case 1:  return old & ~s;
    case 2:  return old ^ s;
    default: return old | s;
    }
}
static uint64_t load( const unsigned char *p, unsigned size )
{
    uint64_t v = 0;
    memcpy( &v, p, 1u << size );   /* little-endian host, checked in main */
    return v;
}
static void fill( unsigned off, unsigned size, uint64_t v )
{
    memset( rw, 0xa5, 64 );
    memcpy( rw + off, &v, 1u << size );
}
static int others_intact( unsigned off, unsigned size )
{
    for (unsigned j = 0; j < 64; j++)
        if ((j < off || j >= off + (1u << size)) && rx[j] != 0xa5) return 0;
    return 1;
}
static void garbage( uint64_t g[32] )
{
    for (unsigned i = 0; i < 32; i++) g[i] = 0xdead0000beef0000ull | i;
}

enum { ROUNDS = 20000, PAIRS = 4 };
static volatile int lost;

static void *emulated_add( void *arg )     /* LDADDAL X6, X0, [X1] through the RW alias */
{
    uint64_t g[32] = { 0 };
    (void)arg;
    for (int i = 0; i < ROUNDS; i++)
    {
        g[6] = 1;
        if (!ios_mach_emulate_rmw( ldop( 3, 1, 1, 6, 0, 1, 0 ), (uintptr_t)rw, g )) __atomic_add_fetch( &lost, 1, __ATOMIC_RELAXED );
    }
    return NULL;
}
static void *host_add( void *arg )         /* the same counter, natively, through another view */
{
    (void)arg;
    for (int i = 0; i < ROUNDS; i++) __atomic_fetch_add( (uint64_t *)rw2, 1, __ATOMIC_SEQ_CST );
    return NULL;
}
static void *emulated_cas_add( void *arg ) /* InterlockedIncrement as a CASAL X11, X6, [X1] loop */
{
    uint64_t g[32] = { 0 };
    (void)arg;
    for (int i = 0; i < ROUNDS; i++)
        for (;;)
        {
            uint64_t seen = __atomic_load_n( (const uint64_t *)(rx + 8), __ATOMIC_SEQ_CST );
            g[11] = seen;
            g[6] = seen + 1;
            if (!ios_mach_emulate_rmw( cas( 3, 1, 11, 1, 1, 6 ), (uintptr_t)(rw + 8), g )) { __atomic_add_fetch( &lost, 1, __ATOMIC_RELAXED ); break; }
            if (g[11] == seen) break;
        }
    return NULL;
}
static void *host_cas_add( void *arg )
{
    (void)arg;
    for (int i = 0; i < ROUNDS; i++)
    {
        uint64_t seen = __atomic_load_n( (uint64_t *)(rw2 + 8), __ATOMIC_SEQ_CST );
        while (!__atomic_compare_exchange_n( (uint64_t *)(rw2 + 8), &seen, seen + 1, 0,
                                             __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST )) {}
    }
    return NULL;
}
/* Each thread owns one bit of a word: set it, then clear it. The old value must
 * show the bit clear before the set and set before the clear; a lost update by
 * another thread would break that. Even bits are emulated LDSETAL/LDCLRAL W,
 * odd bits are host atomics through the other view. */
static void *bit_owner( void *arg )
{
    const unsigned bit = (unsigned)(uintptr_t)arg;
    const uint32_t mine = 1u << bit;
    uint64_t g[32] = { 0 };
    for (int i = 0; i < ROUNDS; i++)
    {
        uint32_t before_set, before_clear;
        if (bit & 1)
        {
            before_set = __atomic_fetch_or( (uint32_t *)(rw2 + 16), mine, __ATOMIC_SEQ_CST );
            before_clear = __atomic_fetch_and( (uint32_t *)(rw2 + 16), ~mine, __ATOMIC_SEQ_CST );
        }
        else
        {
            g[6] = mine;
            ios_mach_emulate_rmw( ldop( 2, 1, 1, 6, 3, 1, 0 ), (uintptr_t)(rw + 16), g );  /* LDSETAL */
            before_set = (uint32_t)g[0];
            g[6] = mine;
            ios_mach_emulate_rmw( ldop( 2, 1, 1, 6, 1, 1, 0 ), (uintptr_t)(rw + 16), g );  /* LDCLRAL */
            before_clear = (uint32_t)g[0];
        }
        if ((before_set & mine) || !(before_clear & mine)) __atomic_add_fetch( &lost, 1, __ATOMIC_RELAXED );
    }
    return NULL;
}

int main( void )
{
    static const uint64_t seeds[] = { 0, 1, 0x7f, 0x80, 0xff, 0x8000, 0xffff, 0x80000000ull, 0xffffffffull,
                                      0x8877665544332211ull, 0xffffffffffffffffull, 0x0123456789abcdefull };
    const unsigned nseeds = sizeof(seeds) / sizeof(seeds[0]);
    const uint16_t one = 1;
    uint64_t g[32], before[32];
    struct thread_state st, st0;
    size_t n = (size_t)sysconf( _SC_PAGESIZE );
    FILE *f = tmpfile();

    assert( *(const unsigned char *)&one == 1 );
    assert( f && !ftruncate( fileno( f ), (off_t)n ) );
    /* The read-only view models the page's RX permission on the host. */
    rw = mmap( NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fileno( f ), 0 );
    rx = mmap( NULL, n, PROT_READ, MAP_SHARED, fileno( f ), 0 );
    rw2 = mmap( NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fileno( f ), 0 );
    assert( rw != MAP_FAILED && rx != MAP_FAILED && rw2 != MAP_FAILED );

    /* The encodings on record, built by the helpers below. */
    assert( ldop( 2, 1, 1, 6, 0, 1, 0 ) == 0xb8e60020u );     /* LDADDAL W6, W0, [X1] */
    assert( ldop( 2, 1, 1, 5, 0, 24, 5 ) == 0xb8e50305u );    /* LDADDAL W5, W5, [X24] */
    assert( cas( 2, 1, 11, 1, 1, 6 ) == 0x88ebfc26u );        /* CASAL W11, W6, [X1] */

    /* LD<OP>: every size, op, A/R form and seed pair, at two aligned offsets. */
    for (unsigned size = 0; size < 4; size++)
    for (unsigned op = 0; op < 4; op++)
    for (unsigned ar = 0; ar < 4; ar++)
    for (unsigned i = 0; i < nseeds; i++)
    for (unsigned j = 0; j < nseeds; j++)
    {
        const uint64_t mask = width_mask( size ), old = seeds[i] & mask;
        const uint64_t want = model( op, old, seeds[j] & mask ) & mask;
        const unsigned off = (i & 1) ? 16 : 40;
        const uint32_t insn = ldop( size, ar >> 1, ar & 1, 6, op, 1, 0 );

        fill( off, size, old );
        garbage( g );
        g[6] = (seeds[j] & mask) | (~mask & 0x5a5a5a5a5a5a5a5aull);   /* bits above the width are ignored */
        memcpy( before, g, sizeof(g) );
        assert( ios_mach_emulate_rmw( insn, (uintptr_t)(rw + off), g ) );
        assert( load( rx + off, size ) == want && others_intact( off, size ) );
        assert( g[0] == old );                                        /* zero-extended */
        for (unsigned k = 1; k < 32; k++) assert( g[k] == before[k] );

        fill( off, size, old );                                       /* ST<OP>: Rt = 31 */
        memcpy( g, before, sizeof(g) );
        assert( ios_mach_emulate_rmw( insn | 31, (uintptr_t)(rw + off), g ) );
        assert( load( rx + off, size ) == want && others_intact( off, size ) );
        assert( !memcmp( g, before, sizeof(g) ) );

        fill( off, size, old );                                       /* Rs = 31 reads zero */
        assert( ios_mach_emulate_rmw( (insn & ~(31u << 16)) | 31u << 16, (uintptr_t)(rw + off), g ) );
        assert( load( rx + off, size ) == old && g[0] == old );
    }
    fill( 8, 2, 10 );                                                 /* Rs = Rt: W5 is read before it is written */
    garbage( g );
    g[5] = 3;
    assert( ios_mach_emulate_rmw( 0xb8e50305u, (uintptr_t)(rw + 8), g ) && load( rx + 8, 2 ) == 13 && g[5] == 10 );

    /* CAS: every size and L/o0 form; the compare uses only the low bits. */
    for (unsigned size = 0; size < 4; size++)
    for (unsigned lo = 0; lo < 4; lo++)
    {
        const uint64_t mask = width_mask( size );
        const uint64_t old = 0x8877665544332211ull & mask, desired = 0x0123456789abcdefull & mask;
        const uint32_t insn = cas( size, lo >> 1, 11, lo & 1, 1, 6 );

        fill( 16, size, old );                                        /* compare succeeds */
        garbage( g );
        g[11] = old | (~mask & 0x5a5a5a5a5a5a5a5aull);
        g[6] = desired | (~mask & 0x3c3c3c3c3c3c3c3cull);
        memcpy( before, g, sizeof(g) );
        assert( ios_mach_emulate_rmw( insn, (uintptr_t)(rw + 16), g ) );
        assert( load( rx + 16, size ) == desired && others_intact( 16, size ) && g[11] == old );
        for (unsigned k = 0; k < 32; k++) assert( k == 11 || g[k] == before[k] );

        fill( 16, size, old );                                        /* compare fails */
        g[11] = old ^ 1;
        assert( ios_mach_emulate_rmw( insn, (uintptr_t)(rw + 16), g ) );
        assert( load( rx + 16, size ) == old && others_intact( 16, size ) && g[11] == old );

        fill( 16, size, old );                                        /* Rt = 31 stores zero */
        g[11] = old;
        assert( ios_mach_emulate_rmw( (insn & ~31u) | 31, (uintptr_t)(rw + 16), g ) );
        assert( load( rx + 16, size ) == 0 && others_intact( 16, size ) && g[11] == old );

        assert( ios_mach_emulate_rmw( (insn & ~(31u << 16)) | 31u << 16, (uintptr_t)(rw + 16), g ) );
        assert( load( rx + 16, size ) == (desired & mask) );         /* Rs = 31 compares with zero */
    }

    /* Not this helper's: SWPAL, LDSMAXAL, LDAPR, CASPAL, LDAXR, STLXR, STP, an FP LD<OP>. */
    {
        static const uint32_t other[] = { 0xf8fa80dau, 0xb8e64020u, 0xb8bfc020u, 0x4866fc02u,
                                          0x885ffd0bu, 0x880cfd0bu, 0xa9882149u, 0xbce60020u };
        for (unsigned i = 0; i < sizeof(other) / sizeof(other[0]); i++)
        {
            fill( 16, 3, 0x1122334455667788ull );
            garbage( g );
            memcpy( before, g, sizeof(g) );
            assert( !ios_mach_emulate_rmw( other[i], (uintptr_t)(rw + 16), g ) );
            assert( load( rx + 16, 3 ) == 0x1122334455667788ull && !memcmp( g, before, sizeof(g) ) );
        }
    }
    assert( !ios_mach_emulate_rmw( 0xb8e60020u, 0, g ) );

    /* The decoder case. The issue's LDADDAL W6, W0, [X1] on an anonymous alias: */
    for (unsigned k = 0; k < 29; k++) st.__x[k] = 0xfeed000000000000ull | k;
    st.__fp = 0xf9f9f9f9f9f9f9f9ull; st.__lr = 0x1e1e1e1e1e1e1e1eull; st.__sp = 0x5959595959595959ull;
    fill( 8, 2, 37 );
    st.__x[6] = 5;
    st0 = st;
    assert( route( 0xb8e60020u, (uintptr_t)(rw + 8), 0, &st ) == 1 );
    assert( load( rx + 8, 2 ) == 42 && st.__x[0] == 37 );
    st.__x[0] = st0.__x[0];
    assert( !memcmp( &st, &st0, sizeof(st) ) );
    /* LDADDAL X29, X30, [X1] in the pool: Rs is FP, Rt is LR, SP untouched. */
    fill( 16, 3, 100 );
    st.__fp = 7;
    st0 = st;
    assert( route( ldop( 3, 1, 1, 29, 0, 1, 30 ), (uintptr_t)(rw + 16), 1, &st ) == 1 );
    assert( load( rx + 16, 3 ) == 107 && st.__lr == 100 && st.__fp == 7 && st.__sp == st0.__sp );
    assert( !memcmp( st.__x, st0.__x, sizeof(st.__x) ) );
    /* CASAL W30, W29, [X1] off the pool: compare value in LR, new value in FP. */
    fill( 16, 2, 100 );
    st.__lr = 0xabcd000000000064ull;
    st0 = st;
    assert( route( cas( 2, 1, 30, 1, 1, 29 ), (uintptr_t)(rw + 16), 0, &st ) == 1 );
    assert( load( rx + 16, 2 ) == 7 && st.__lr == 100 && st.__fp == 7 && st.__sp == st0.__sp );
    /* The same CASAL in the pool is not this case's: FEX's pool CAS keeps its block. */
    fill( 16, 2, 100 );
    st.__lr = 100;
    st0 = st;
    assert( route( cas( 2, 1, 30, 1, 1, 29 ), (uintptr_t)(rw + 16), 1, &st ) == 0 );
    assert( load( rx + 16, 2 ) == 100 && !memcmp( &st, &st0, sizeof(st) ) );
    /* Other encodings fall through to their own cases. */
    {
        static const uint32_t other[] = { 0xf8fa80dau, 0xb8e64020u, 0xb8bfc020u, 0x4866fc02u,
                                          0x885ffd0bu, 0x880cfd0bu, 0xa9882149u, 0xbce60020u };
        for (unsigned i = 0; i < sizeof(other) / sizeof(other[0]); i++)
            for (int in_jit = 0; in_jit < 2; in_jit++)
            {
                fill( 16, 3, 0x1122334455667788ull );
                st0 = st;
                assert( route( other[i], (uintptr_t)(rw + 16), in_jit, &st ) == 0 );
                assert( load( rx + 16, 3 ) == 0x1122334455667788ull && !memcmp( &st, &st0, sizeof(st) ) );
            }
    }
    /* Misaligned: refused, nothing written. */
    {
        static const struct { uint32_t insn; unsigned off; } bad[] = {
            { 0x78e60020u, 9 },    /* LDADDALH W6, W0, [X1] */
            { 0xb8e60020u, 10 },   /* LDADDAL W6, W0, [X1] */
            { 0xf8e60020u, 12 },   /* LDADDAL X6, X0, [X1] */
            { 0xc8ebfc26u, 20 },   /* CASAL X11, X6, [X1] */
        };
        for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++)
        {
            memset( rw, 0xa5, 64 );
            st0 = st;
            assert( route( bad[i].insn, (uintptr_t)(rw + bad[i].off), 0, &st ) == 0 );
            assert( others_intact( 64, 0 ) && !memcmp( &st, &st0, sizeof(st) ) );
        }
    }

    /* Atomicity against the guest's other threads. */
    {
        pthread_t t[4 * PAIRS + 8];
        unsigned nt = 0;
        memset( rw, 0, 64 );
        for (int i = 0; i < PAIRS; i++)
        {
            assert( !pthread_create( &t[nt++], NULL, emulated_add, NULL ) );
            assert( !pthread_create( &t[nt++], NULL, host_add, NULL ) );
            assert( !pthread_create( &t[nt++], NULL, emulated_cas_add, NULL ) );
            assert( !pthread_create( &t[nt++], NULL, host_cas_add, NULL ) );
        }
        for (uintptr_t bit = 0; bit < 8; bit++) assert( !pthread_create( &t[nt++], NULL, bit_owner, (void *)bit ) );
        for (unsigned i = 0; i < nt; i++) pthread_join( t[i], NULL );
        printf( "counters: add %llu (want %llu), cas %llu (want %llu), bits %#x, lost %d\n",
                (unsigned long long)load( rx, 3 ), 2ull * PAIRS * ROUNDS,
                (unsigned long long)load( rx + 8, 3 ), 2ull * PAIRS * ROUNDS,
                (unsigned)load( rx + 16, 2 ), lost );
        assert( load( rx, 3 ) == 2ull * PAIRS * ROUNDS );
        assert( load( rx + 8, 3 ) == 2ull * PAIRS * ROUNDS );
        assert( load( rx + 16, 2 ) == 0 && !lost );
    }

    munmap( rw, n ); munmap( rx, n ); munmap( rw2, n ); fclose( f );
    puts( "PASS: LD<OP> and CAS on the RW alias: sizes, orderings, registers, routing, alignment, atomicity" );
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-alias-atomics-') as directory:
    folder = Path(directory)
    src = folder / 'check.c'
    src.write_text(code)
    exe = folder / 'check'
    cc = os.environ.get('CC', 'cc')
    flags = [cc, '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-g', '-pthread', str(src), '-o', str(exe)]
    sanitize = ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    if subprocess.run(flags[:1] + sanitize + flags[1:], capture_output=True).returncode == 0:
        print('built with AddressSanitizer/UBSan')
    else:
        r = subprocess.run(flags, capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        print('built without sanitizers')
    result = subprocess.run([str(exe)], capture_output=True, text=True)
    print(result.stdout, end='')
    assert result.returncode == 0, result.stdout + result.stderr
    err = result.stderr
    assert '[mach-rmw] #1 insn=0xb8e60020' in err and 'emulated' in err, err
    assert 'REFUSED: misaligned' in err, err
print('PASS: LSE atomics on aliased pages are emulated atomically through the RW alias')
