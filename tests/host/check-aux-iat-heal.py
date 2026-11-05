#!/usr/bin/env python3
"""The aux-IAT heal (build/ntdll-unix/virtual_ios.c); no Wine runs.

Compiles the production ios_jit_heal_aux_iat and ios_jit_translate_addr_for_owner
against a model of the JIT pool built from the shipped ARM64EC kernel32.dll and
ntdll.dll: both images are laid out by RVA as PE mappings and as pool copies,
the pool is one memfd mapped twice (a read-only RX view and the RW alias, so a
write through the wrong view faults), kernel32's copy holds its linker import
stubs and AuxiliaryIAT, and its main IAT slots hold ntdll's x64 fast-forward
thunks as the loader leaves them (ml943). Checks:
  - kernel32!timeGetTime's two calls (RVA 0x2574c, 0x25754) fault at
    ntdll!RtlQueryPerformanceCounter / RtlQueryPerformanceFrequency: each
    heal stores exactly the redirect's copy address in the stub's
    AuxiliaryIAT slot (+0x6d0e0, +0x6d0e8), through the RW view only;
  - a slot already healed, or holding anything but the continuation, is left;
  - a copy shared with another process, a thread of another process, a main
    IAT value that does not decode to the faulting pc, a call that is not a
    BL, a redirect target other than the process's own copy: nothing written;
  - MADEIRA_AUX_IAT_HEAL=0 writes nothing;
and textually that the exec-fault handler calls it with lr and the faulting
thread's PEB before it redirects pc.
Needs python3 and a C compiler (CC, default cc).
"""
from pathlib import Path
import os
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
virtual = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
signal = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()
k32 = (root / 'app/Madeira/arm64ec-windows/kernel32.dll').read_bytes()
ntd = (root / 'app/Madeira/arm64ec-windows/ntdll.dll').read_bytes()


def layout(pe):
    """The image as mapped (sections at their RVAs), its size and section table."""
    off = struct.unpack_from('<I', pe, 0x3c)[0]
    opt = off + 24
    nsec = struct.unpack_from('<H', pe, off + 6)[0]
    secs_at = opt + struct.unpack_from('<H', pe, off + 20)[0]
    size = struct.unpack_from('<I', pe, opt + 56)[0]
    hdr = struct.unpack_from('<I', pe, opt + 60)[0]
    image = bytearray(size)
    image[:hdr] = pe[:hdr]
    text = (0, 0)
    for i in range(nsec):
        name = pe[secs_at + i * 40:secs_at + i * 40 + 8].rstrip(b'\0')
        vsize, va, rsize, raw = struct.unpack_from('<IIII', pe, secs_at + i * 40 + 8)
        image[va:va + min(rsize, vsize or rsize)] = pe[raw:raw + min(rsize, vsize or rsize)]
        if name == b'.text':
            text = (va, vsize)
    return image, size, text


k32_img, k32_size, k32_text = layout(k32)
ntd_img, ntd_size, ntd_text = layout(ntd)

# what the fixture relies on, read from the shipped files
assert struct.unpack_from('<I', k32_img, 0x2574c)[0] >> 26 == 0x25, 'timeGetTime: BL'
s0, s1, s2 = struct.unpack_from('<III', k32_img, 0x2b2f4)
assert (s0 & 0x9F00001F) == 0x90000010 and (s1 & 0xFFC003FF) == 0xF9400210 and s2 == 0xD61F0200, 'import stub shape'
c0, c1 = struct.unpack_from('<II', k32_img, 0x2b300)
assert (c0 & 0x9F00001F) == 0x9000000B and (c1 & 0xFFC003FF) == 0xF940016B, 'continuation shape'
assert ntd_img[0x92090:0x9209a] == bytes.fromhex('488bc448895820555de9'), 'RtlQueryPerformanceCounter FFS'
assert ntd_img[0x920a0:0x920aa] == bytes.fromhex('488bc448895820555de9'), 'RtlQueryPerformanceFrequency FFS'

begin = virtual.index('/* madeira-bcd: aux-IAT heal (begin).')
heal = virtual[begin:virtual.index('/* madeira-bcd: aux-IAT heal (end) */', begin)]
struct_def = virtual[virtual.index('struct ios_jit_mapping {'):]
struct_def = struct_def[:struct_def.index('};') + 2]
translate = virtual[virtual.index('void *ios_jit_translate_addr_for_owner(void *addr, void *owner_peb)'):]
translate = translate[:translate.index('\n}\n') + 3]

harness = r'''
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
static int madeira_pe_wine_enabled(void) { return 0; }
static void *madeira_pe_wine_translate(const void *address, int reverse) { (void)reverse; return (void *)address; }
#define IOS_JIT_MAX_CODE_RANGES 96
#define dprintf(fd, ...) fprintf(stderr, __VA_ARGS__)
''' + struct_def + r'''
static struct ios_jit_mapping ios_jit_mappings[8];
static int ios_jit_mapping_count;
static void *ios_jit_rx_base_global, *ios_jit_rw_base_global;
static size_t ios_jit_pool_size_global;
#include <sys/uio.h>
/* fault-safe like the production mach_vm_read_overwrite reader */
static int ios_safe_read64( uint64_t addr, uint64_t *out )
{
    struct iovec l = { out, 8 }, r = { (void *)(uintptr_t)addr, 8 };
    if (addr < 0x1000 || (addr & 7)) return -1;
    return process_vm_readv( getpid(), &l, 1, &r, 1, 0 ) == 8 ? 0 : -1;
}
''' + translate + heal + r'''
#define POOL_SIZE 0x400000ul
static unsigned char *rx_view, *rw_view;
#define K32_COPY ((uintptr_t)rx_view + 0x10000)
#define NTD_COPY ((uintptr_t)rx_view + 0x10000 + K32_SIZE_ALIGNED)
#define PEB_A ((void *)0x1000a000)
#define PEB_B ((void *)0x1000b000)
static int fails;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)
static uint64_t rd64( uintptr_t a ) { uint64_t v; memcpy( &v, (void *)a, 8 ); return v; }
static void wr64_rw( uintptr_t rx_addr, uint64_t v ) { memcpy( rw_view + (rx_addr - (uintptr_t)rx_view), &v, 8 ); }

static void reset( unsigned char *k32, unsigned char *ntd, int heal_ok )
{
    /* copies = the images as laid out, slots as the loader and iat-sync leave them */
    memcpy( rw_view + 0x10000, k32, K32_SIZE );
    memcpy( rw_view + 0x10000 + K32_SIZE_ALIGNED, ntd, NTD_SIZE );
    wr64_rw( K32_COPY + 0x6d0e0, K32_COPY + 0x2b300 );     /* aux: the continuation (copy address) */
    wr64_rw( K32_COPY + 0x6d0e8, PE_K32 + 0x2b320 );       /* aux: the continuation (PE address) */
    wr64_rw( K32_COPY + 0x510e0, PE_NTD + 0x92090 );       /* main IAT: x64 FFS of RtlQueryPerformanceCounter */
    wr64_rw( K32_COPY + 0x510e8, PE_NTD + 0x920a0 );       /* main IAT: x64 FFS of RtlQueryPerformanceFrequency */
    ios_jit_mapping_count = 2;
    memset( ios_jit_mappings, 0, sizeof(ios_jit_mappings) );
    ios_jit_mappings[0].pe_base = (void *)PE_K32; ios_jit_mappings[0].jit_base = (void *)K32_COPY;
    ios_jit_mappings[0].size = K32_SIZE; ios_jit_mappings[0].text_offset = K32_TEXT; ios_jit_mappings[0].text_size = K32_TEXT_SIZE;
    ios_jit_mappings[0].map_peb = PEB_A;
    ios_jit_mappings[1].pe_base = (void *)PE_NTD; ios_jit_mappings[1].jit_base = (void *)NTD_COPY;
    ios_jit_mappings[1].size = NTD_SIZE; ios_jit_mappings[1].text_offset = NTD_TEXT; ios_jit_mappings[1].text_size = NTD_TEXT_SIZE;
    ios_jit_mappings[1].map_peb = PEB_A;
    (void)heal_ok;
}

int main( int argc, char **argv )
{
    unsigned char *k32 = malloc( K32_SIZE ), *ntd = malloc( NTD_SIZE );
    FILE *f;
    int fd = memfd_create( "pool", 0 );
    uintptr_t qpc = PE_NTD + 0x71aac, qpf = PE_NTD + 0x71d04;
    if (fd < 0 || ftruncate( fd, POOL_SIZE )) return 2;
    rw_view = mmap( NULL, POOL_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0 );
    rx_view = mmap( NULL, POOL_SIZE, PROT_READ, MAP_SHARED, fd, 0 );   /* writes through it fault */
    if (rw_view == MAP_FAILED || rx_view == MAP_FAILED) return 2;
    ios_jit_rx_base_global = rx_view; ios_jit_rw_base_global = rw_view; ios_jit_pool_size_global = POOL_SIZE;
    f = fopen( argv[1], "rb" ); if (!f || fread( k32, 1, K32_SIZE, f ) != K32_SIZE) return 2; fclose( f );
    f = fopen( argv[2], "rb" ); if (!f || fread( ntd, 1, NTD_SIZE, f ) != NTD_SIZE) return 2; fclose( f );
    /* the PE "mappings": the same bytes at the PE addresses the fixture uses */
    if (mmap( (void *)PE_K32, K32_SIZE_ALIGNED, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0 ) != (void *)PE_K32) return 2;
    if (mmap( (void *)PE_NTD, NTD_SIZE_ALIGNED, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0 ) != (void *)PE_NTD) return 2;
    memcpy( (void *)PE_K32, k32, K32_SIZE ); memcpy( (void *)PE_NTD, ntd, NTD_SIZE );

    if (argc > 3)   /* MADEIRA_AUX_IAT_HEAL=0 run */
    {
        reset( k32, ntd, 0 );
        CHECK( !ios_jit_heal_aux_iat( qpc, K32_COPY + 0x25750, PEB_A, NTD_COPY + 0x71aac ) );
        CHECK( rd64( K32_COPY + 0x6d0e0 ) == K32_COPY + 0x2b300 );
        if (!fails) puts( "PASS: MADEIRA_AUX_IAT_HEAL=0 leaves the slot" );
        return fails != 0;
    }

    reset( k32, ntd, 1 );
    CHECK( (uintptr_t)ios_jit_translate_addr_for_owner( (void *)qpc, PEB_A ) == NTD_COPY + 0x71aac );
    CHECK( ios_jit_heal_aux_iat( qpc, K32_COPY + 0x25750, PEB_A, NTD_COPY + 0x71aac ) == 1 );
    CHECK( rd64( K32_COPY + 0x6d0e0 ) == NTD_COPY + 0x71aac );
    CHECK( ios_jit_heal_aux_iat( qpf, K32_COPY + 0x25758, PEB_A, NTD_COPY + 0x71d04 ) == 1 );
    CHECK( rd64( K32_COPY + 0x6d0e8 ) == NTD_COPY + 0x71d04 );
    CHECK( !ios_jit_heal_aux_iat( qpc, K32_COPY + 0x25750, PEB_A, NTD_COPY + 0x71aac ) );   /* healed already */
    CHECK( rd64( K32_COPY + 0x6d0e0 ) == NTD_COPY + 0x71aac );

    reset( k32, ntd, 1 );                                                                   /* another process's thread */
    CHECK( !ios_jit_heal_aux_iat( qpc, K32_COPY + 0x25750, PEB_B, NTD_COPY + 0x71aac ) );
    reset( k32, ntd, 1 );                                                                   /* the image has a second copy */
    ios_jit_mappings[2] = ios_jit_mappings[0]; ios_jit_mappings[2].owner_peb = PEB_B;
    ios_jit_mappings[2].jit_base = (void *)(NTD_COPY + NTD_SIZE_ALIGNED); ios_jit_mapping_count = 3;
    CHECK( !ios_jit_heal_aux_iat( qpc, K32_COPY + 0x25750, PEB_A, NTD_COPY + 0x71aac ) );
    reset( k32, ntd, 1 );                                                                   /* an owned copy of this process */
    ios_jit_mappings[0].owner_peb = PEB_A; ios_jit_mappings[0].map_peb = NULL;
    CHECK( ios_jit_heal_aux_iat( qpc, K32_COPY + 0x25750, PEB_A, NTD_COPY + 0x71aac ) == 1 );
    reset( k32, ntd, 1 );                                                                   /* main IAT decodes elsewhere */
    CHECK( !ios_jit_heal_aux_iat( qpc + 4, K32_COPY + 0x25750, PEB_A, NTD_COPY + 0x71ab0 ) );
    CHECK( rd64( K32_COPY + 0x6d0e0 ) == K32_COPY + 0x2b300 );
    reset( k32, ntd, 1 );                                                                   /* main IAT holds the target itself */
    wr64_rw( K32_COPY + 0x510e0, qpc );
    CHECK( ios_jit_heal_aux_iat( qpc, K32_COPY + 0x25750, PEB_A, NTD_COPY + 0x71aac ) == 1 );
    reset( k32, ntd, 1 );                                                                   /* slot holds something else */
    wr64_rw( K32_COPY + 0x6d0e0, NTD_COPY + 0x12340 );
    CHECK( !ios_jit_heal_aux_iat( qpc, K32_COPY + 0x25750, PEB_A, NTD_COPY + 0x71aac ) );
    CHECK( rd64( K32_COPY + 0x6d0e0 ) == NTD_COPY + 0x12340 );
    reset( k32, ntd, 1 );                                                                   /* lr - 4 is not a BL */
    CHECK( !ios_jit_heal_aux_iat( qpc, K32_COPY + 0x25748, PEB_A, NTD_COPY + 0x71aac ) );
    reset( k32, ntd, 1 );                                                                   /* redirect target is not the process's copy */
    CHECK( !ios_jit_heal_aux_iat( qpc, K32_COPY + 0x25750, PEB_A, NTD_COPY + 0x71ab0 ) );
    CHECK( rd64( K32_COPY + 0x6d0e0 ) == K32_COPY + 0x2b300 );
    reset( k32, ntd, 1 );                                                                   /* a stale entry still claims the copy range */
    ios_jit_mappings[2] = ios_jit_mappings[0]; ios_jit_mappings[2].pe_base = (void *)(PE_NTD + NTD_SIZE_ALIGNED * 4);
    ios_jit_mapping_count = 3;
    CHECK( !ios_jit_heal_aux_iat( qpc, K32_COPY + 0x25750, PEB_A, NTD_COPY + 0x71aac ) );
    reset( k32, ntd, 1 );                                                                   /* the caller's image is gone (unmapped PE) */
    ios_jit_mappings[0].pe_base = (void *)(PE_NTD + NTD_SIZE_ALIGNED * 4);
    CHECK( !ios_jit_heal_aux_iat( qpc, K32_COPY + 0x25750, PEB_A, NTD_COPY + 0x71aac ) );
    CHECK( rd64( K32_COPY + 0x6d0e0 ) == K32_COPY + 0x2b300 );
    reset( k32, ntd, 1 );                                                                   /* main slot outside the IAT directory */
    {
        unsigned char *pe = (unsigned char *)PE_K32;
        uint32_t lf; memcpy( &lf, pe + 0x3c, 4 );
        uint32_t save; memcpy( &save, pe + lf + 24 + 112 + 8 * 12, 4 );
        uint32_t moved = save + 0x2000; memcpy( pe + lf + 24 + 112 + 8 * 12, &moved, 4 );
        CHECK( !ios_jit_heal_aux_iat( qpc, K32_COPY + 0x25750, PEB_A, NTD_COPY + 0x71aac ) );
        memcpy( pe + lf + 24 + 112 + 8 * 12, &save, 4 );
    }
    reset( k32, ntd, 1 );                                                                   /* lr outside the pool */
    CHECK( !ios_jit_heal_aux_iat( qpc, PE_K32 + 0x25750, PEB_A, NTD_COPY + 0x71aac ) );
    if (!fails) puts( "PASS: timeGetTime's QPC/QPF stubs healed to the process's ntdll copy through the RW view; "
                      "shared or foreign copies, other targets, other slot values and non-BL calls left alone" );
    return fails != 0;
}
'''

def align(x):
    return (x + 0xffff) & ~0xffff


defs = {
    'K32_SIZE': k32_size, 'K32_SIZE_ALIGNED': align(k32_size), 'K32_TEXT': k32_text[0], 'K32_TEXT_SIZE': k32_text[1],
    'NTD_SIZE': ntd_size, 'NTD_SIZE_ALIGNED': align(ntd_size), 'NTD_TEXT': ntd_text[0], 'NTD_TEXT_SIZE': ntd_text[1],
    'PE_K32': 0x7e3c900000, 'PE_NTD': 0x7e42a00000,
}
assert 0x10000 + defs['K32_SIZE_ALIGNED'] + 2 * defs['NTD_SIZE_ALIGNED'] <= 0x400000

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'k32.img').write_bytes(bytes(k32_img))
    (tmp / 'ntd.img').write_bytes(bytes(ntd_img))
    c = tmp / 'aux.c'
    c.write_text(harness)
    exe = tmp / 'aux'
    cmd = [os.environ.get('CC', 'cc'), '-O1', '-g', '-std=gnu11', '-Wall', '-Werror', '-Wno-unused-function',
           '-fsanitize=undefined', str(c), '-o', str(exe)]
    cmd[1:1] = ['-D%s=0x%xul' % (k, v) for k, v in defs.items()]
    subprocess.run(cmd, check=True)
    out = subprocess.run([str(exe), str(tmp / 'k32.img'), str(tmp / 'ntd.img')], capture_output=True, text=True)
    print(out.stdout.strip()); print(out.stderr.strip()) if out.returncode else None
    assert out.returncode == 0, 'heal model failed'
    env = dict(os.environ, MADEIRA_AUX_IAT_HEAL='0')
    out = subprocess.run([str(exe), str(tmp / 'k32.img'), str(tmp / 'ntd.img'), 'off'], capture_output=True, text=True, env=env)
    print(out.stdout.strip()); print(out.stderr.strip()) if out.returncode else None
    assert out.returncode == 0, 'switch-off run failed'

block = signal[signal.index('/* madeira-bcd: an EC import stub that reached this'):]
block = block[:block.index('handled = 1;')]
assert 'ios_jit_heal_aux_iat( (uintptr_t)fault_pc,' in block
assert '(uintptr_t)__darwin_arm_thread_state64_get_lr(state),' in block
assert 'fault_owner_peb, (uintptr_t)jit_pc );' in block
assert block.index('ios_jit_heal_aux_iat(') < block.index('__darwin_arm_thread_state64_set_pc_fptr(state, jit_pc);'), \
    'healed before pc is redirected (lr is still the caller)'
print('PASS: the exec-fault redirect heals with the caller lr and the faulting thread\'s PEB before it moves pc')
