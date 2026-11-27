#!/usr/bin/env python3
"""The aux-IAT heal (build/ntdll-unix/virtual_ios.c); no Wine runs.

Compiles the production ios_jit_heal_aux_iat and ios_jit_translate_addr_for_owner
against a model of the JIT pool built from the shipped ARM64EC kernel32.dll and
ntdll.dll: both images are laid out by RVA as PE mappings and as pool copies,
the pool is one memfd mapped twice (a read-only RX view and the RW alias, so a
write through the wrong view faults), kernel32's copy holds its linker import
stubs and AuxiliaryIAT, and its main IAT slots hold ntdll's x64 fast-forward
thunks as the loader leaves them (ml943). Every address the model needs (the
calls' RVAs, the stub and continuation slots, ntdll's fast-forward stubs and
their tail targets) is derived from the shipped files the way the heal decodes
them, so a rebuilt runtime is picked up whole. Checks:
  - two of kernel32!timeGetTime's ntdll fast-forward calls (the QPC/QPF pair
    in builds that still route the timer through ntdll, its ntdll debug calls
    in builds that route it via kernelbase) fault at the redirect's target:
    each heal stores exactly the redirect's copy address in the stub's
    AuxiliaryIAT slot, through the RW view only;
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
import re
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


def u16(img, off):
    return struct.unpack_from('<H', img, off)[0]


def sign(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def u32(img, off):
    return struct.unpack_from('<I', img, off)[0]


def s32(img, off):
    return struct.unpack_from('<i', img, off)[0]


def exports(img):
    """name -> RVA, from the mapped image's export directory."""
    lfanew = u32(img, 0x3c)
    exp = u32(img, lfanew + 24 + 112)
    n, funcs, names, ords = u32(img, exp + 24), u32(img, exp + 28), u32(img, exp + 32), u32(img, exp + 36)
    out = {}
    for i in range(n):
        noff = u32(img, names + 4 * i)
        out[img[noff:img.index(b'\0', noff)].decode()] = u32(img, funcs + 4 * u16(img, ords + 2 * i))
    return out


def iat_slots(img):
    """(dll, name) -> the main IAT slot RVA, from the import directory."""
    lfanew = u32(img, 0x3c)
    out, d = {}, u32(img, lfanew + 24 + 112 + 8)
    while u32(img, d):
        dll_off = u32(img, d + 12)
        dll = img[dll_off:img.index(b'\0', dll_off)].decode().lower()
        int_, iat = u32(img, d), u32(img, d + 16)
        i = 0
        while u32(img, int_ + 8 * i):
            thunk = struct.unpack_from('<Q', img, int_ + 8 * i)[0]
            if not thunk >> 63:
                noff = thunk + 2
                out[(dll, img[noff:img.index(b'\0', noff)].decode())] = iat + 8 * i
            i += 1
        d += 20
    return out


def adrp_page(pc, insn):
    imm = (((insn >> 5) & 0x7FFFF) << 2) | ((insn >> 29) & 3)
    if imm & (1 << 20):
        imm -= 1 << 21
    return (pc & ~0xFFF) + (imm << 12)


# what the fixture relies on is DERIVED from the shipped files the way
# ios_jit_heal_aux_iat decodes them, so a rebuilt runtime is picked up whole
# (the shapes are asserted while deriving; a build without them fails here)
ffs = bytes.fromhex('488bc448895820555de9')


def ffs_body(img, rva):
    assert bytes(img[rva:rva + 10]) == ffs, 'x64 fast-forward stub shape'
    return rva + 14 + s32(img, rva + 10)   # its tail jmp target


ntd_exp, k32_exp = exports(ntd_img), exports(k32_img)


def entry_body(img, rva):
    """An export's entry: the x64 fast-forward stub's tail target where there
    is one (ml943's layout), the entry itself otherwise."""
    return ffs_body(img, rva) if bytes(img[rva:rva + 10]) == ffs else rva


tg = entry_body(k32_img, k32_exp['timeGetTime'])
calls = []
for rva in range(tg, tg + 0x400, 4):
    insn = u32(k32_img, rva)
    if insn & 0xFC000000 != 0x94000000:
        continue
    stub = rva + sign(insn & 0x03FFFFFF, 26) * 4
    s0, s1, s2 = u32(k32_img, stub), u32(k32_img, stub + 4), u32(k32_img, stub + 8)
    if (s0 & 0x9F00001F) != 0x90000010 or (s1 & 0xFFC003FF) != 0xF9400210 or s2 != 0xD61F0200:
        continue
    cont = stub + 12
    c0, c1 = u32(k32_img, cont), u32(k32_img, cont + 4)
    if (c0 & 0x9F00001F) != 0x9000000B or (c1 & 0xFFC003FF) != 0xF940016B:
        continue
    calls.append((rva, stub, cont,
                  adrp_page(stub, s0) + ((s1 >> 10) & 0xFFF) * 8,
                  adrp_page(cont, c0) + ((c1 >> 10) & 0xFFF) * 8))
assert len(calls) >= 2, 'timeGetTime: expected its stub calls, found %d' % len(calls)
k32_iat = iat_slots(k32_img)
slot_name = {v: k for k, v in k32_iat.items()}


def ntd_target(call):
    """(export name, its fast-forward stub RVA, its body RVA) for a call into
    ntdll's fast-forward imports; None for anything else."""
    key = slot_name.get(call[4])
    if not key or key[0] != 'ntdll.dll':
        return None
    rva = ntd_exp.get(key[1])
    if rva is None or bytes(ntd_img[rva:rva + 10]) != ffs:
        return None
    return key[1], rva, ffs_body(ntd_img, rva)


# the two calls the model pins: the first two distinct ntdll fast-forward
# imports in the body -- the QPC/QPF pair where a build still routes the timer
# through ntdll, its ntdll debug calls where it routes QPC/QPF via kernelbase
picked = []
for c in calls:
    t = ntd_target(c)
    if t and all(t[0] != p[1][0] for p in picked):
        picked.append((c, t))
assert len(picked) >= 2, 'timeGetTime: expected two ntdll fast-forward stub calls'
(call1, t1), (call2, t2) = picked[0], picked[1]
for rva, stub, cont, aux, main in calls:
    assert not (k32_text[0] <= aux < k32_text[0] + k32_text[1]), 'aux slot inside .text'
    assert not (k32_text[0] <= main < k32_text[0] + k32_text[1]), 'main slot inside .text'
assert u32(k32_img, call1[0] - 8) & 0xFC000000 != 0x94000000, 'the not-a-BL slot became a BL'

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
#define IOS_JIT_MAX_CODE_RANGES 96
#define dprintf(fd, ...) fprintf(stderr, __VA_ARGS__)
''' + struct_def + r'''
static struct ios_jit_mapping ios_jit_mappings[8];
static int ios_jit_mapping_count;
static void *ios_jit_rx_base_global, *ios_jit_rw_base_global;
static size_t ios_jit_pool_size_global;
#include <sys/uio.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <fcntl.h>
#include <sys/stat.h>
#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE MAP_FIXED   /* checked by the caller's address compare */
#endif
static int memfd_create( const char *name, unsigned int flags )
{
    char buf[64];
    int fd;
    (void)flags;
    snprintf( buf, sizeof buf, "/%s-%d", name, (int)getpid() );
    fd = shm_open( buf, O_RDWR | O_CREAT | O_EXCL, 0600 );
    if (fd >= 0) shm_unlink( buf );
    return fd;
}
#endif
/* fault-safe like the production mach_vm_read_overwrite reader */
static int ios_safe_read64( uint64_t addr, uint64_t *out )
{
    if (addr < 0x1000 || (addr & 7)) return -1;
#ifdef __APPLE__
    {
        mach_vm_size_t n = 0;
        return mach_vm_read_overwrite( mach_task_self(), addr, 8, (mach_vm_address_t)out, &n ) == 0 && n == 8 ? 0 : -1;
    }
#else
    {
        struct iovec l = { out, 8 }, r = { (void *)(uintptr_t)addr, 8 };
        return process_vm_readv( getpid(), &l, 1, &r, 1, 0 ) == 8 ? 0 : -1;
    }
#endif
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
    if (!fails) puts( "PASS: timeGetTime's ntdll fast-forward stubs healed to the process's ntdll copy through the RW view; "
                      "shared or foreign copies, other targets, other slot values and non-BL calls left alone" );
    return fails != 0;
}
'''

# the driver's fixture constants, named and derived from the shipped files
pins = {
    '0x25750': 'CALL1_LR', '0x25758': 'CALL2_LR', '0x25748': 'NB_LR',
    '0x6d0e0': 'AUX1', '0x6d0e8': 'AUX2',
    '0x2b300': 'CONT1', '0x2b320': 'CONT2',
    '0x510e0': 'MAIN1', '0x510e8': 'MAIN2',
    '0x92090': 'FFS1', '0x920a0': 'FFS2',
    '0x71aac': 'QPC', '0x71ab0': 'QPC + 4', '0x71d04': 'QPF',
}
harness = re.sub(r'0x[0-9a-fA-F]+', lambda m: pins.get(m.group(0), m.group(0)), harness)

def align(x):
    return (x + 0xffff) & ~0xffff


defs = {
    'K32_SIZE': k32_size, 'K32_SIZE_ALIGNED': align(k32_size), 'K32_TEXT': k32_text[0], 'K32_TEXT_SIZE': k32_text[1],
    'NTD_SIZE': ntd_size, 'NTD_SIZE_ALIGNED': align(ntd_size), 'NTD_TEXT': ntd_text[0], 'NTD_TEXT_SIZE': ntd_text[1],
    'PE_K32': 0x7e3c900000, 'PE_NTD': 0x7e42a00000,
    'CALL1_LR': call1[0] + 4, 'CALL2_LR': call2[0] + 4, 'NB_LR': call1[0] - 4,
    'AUX1': call1[3], 'AUX2': call2[3], 'CONT1': call1[2], 'CONT2': call2[2],
    'MAIN1': call1[4], 'MAIN2': call2[4],
    'FFS1': t1[1], 'FFS2': t2[1],
    'QPC': t1[2], 'QPF': t2[2],
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
    r = subprocess.run(cmd, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
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
