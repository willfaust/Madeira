#!/usr/bin/env python3
"""Exercise production alias-store decoding and write-recovery policy.

A CoreCLR fixup CAS must reach FEX's SMC handler, even while Wine records
logical RWX. Native STP initializers must still finish without granting W
on the executable view. A store from FEX's own handler code must complete
through the alias, not re-enter the handler. Uses real shared RX/RW mappings
and ASan/UBSan.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()

def function(signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'

start = source.index('                    int aliased = ios_write_alias(')
end = source.index('                    ++wr_seen;', start)
policy = source[start:end]
assert 'ios_alias_store_pair( insn, fault_addr, gpr, &alias_fault, honor_guest_prot )' in source
start = source.index('                int honor_guest_prot = 1;')
end = source.index('                if (rw_addr && honor_guest_prot && ios_alias_write_is_trapped', start)
honor = source[start:end]
code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#define VM_PROT_WRITE PROT_WRITE
void *ios_jit_rx_base_global, *ios_jit_rw_base_global;
size_t ios_jit_pool_size_global;
static uintptr_t anon_rx, anon_rw;
static size_t anon_size;
static uintptr_t second_rx, second_rw;
static uintptr_t trapped_page;
static int logical_prot = PROT_READ | PROT_WRITE | PROT_EXEC;
int ios_page_expected_prot(const void *addr)
{
    if (trapped_page && ((uintptr_t)addr & ~(uintptr_t)0xfff) == trapped_page)
        return PROT_READ | PROT_EXEC;
    return logical_prot;
}
uintptr_t ios_jit_anon_alias_lookup(uintptr_t addr)
{
    if (second_rx && addr >= second_rx && addr - second_rx < 0x4000)
        return second_rw + addr - second_rx;
    return anon_rx && addr >= anon_rx && addr - anon_rx < anon_size
        ? anon_rw + addr - anon_rx : 0;
}
'''
code += function('static uintptr_t ios_write_alias( uintptr_t addr )')
code += function('static int ios_mach_emulate_casp(uint32_t insn, uintptr_t rw_addr, uint64_t gpr[29])')
code += function('static int ios_alias_write_is_trapped( uintptr_t addr )')
code += function('static int ios_alias_write( uintptr_t addr, const void *source, size_t size, uintptr_t *blocked,\n                            int honor_guest_prot )')
code += function('static int ios_alias_store_pair( uint32_t insn, uintptr_t addr, uint64_t gpr[32], uintptr_t *blocked,\n                                 int honor_guest_prot )')
code += r'''
static uintptr_t fex_pool_start, fex_pool_end;
int ios_jit_pool_pc_is_fex(uintptr_t pc) { return pc >= fex_pool_start && pc < fex_pool_end; }
static int honor_for(uintptr_t rw_addr, uintptr_t fault_addr, uintptr_t fault_pc)
{
''' + honor + '    return honor_guest_prot;\n}\n'
code += '''static int may_restore(void *addr, int is_write, int want, int host_prot)
{
    struct { void *si_addr; } info = {addr}, *siginfo = &info;
''' + policy + '    return stripped;\n}\n'
code += r'''
static uint32_t stp(unsigned wide, unsigned mode, int imm, unsigned rt, unsigned rt2, unsigned rn)
{
    return 0x28000000u | (wide << 31) | (mode << 23) |
           (((unsigned)imm & 127) << 15) | (rt2 << 10) | (rn << 5) | rt;
}
int main(void)
{
    uintptr_t blocked = 0;
    size_t n = (size_t)sysconf(_SC_PAGESIZE);
    FILE *f = tmpfile();
    assert(f && !ftruncate(fileno(f), n));
    unsigned char *rw = mmap(0, n, PROT_READ|PROT_WRITE, MAP_SHARED, fileno(f), 0);
    unsigned char *rx = mmap(0, n, PROT_READ, MAP_SHARED, fileno(f), 0);
    assert(rw != MAP_FAILED && rx != MAP_FAILED);
    /* The read-only view models iOS's intentional RX permission, without
       requiring executable temporary files on a hardened host. */
    anon_rx = (uintptr_t)rx; anon_rw = (uintptr_t)rw; anon_size = n;
    /* A normal host RX alias may be writable to the guest, but a guest RX
       page must dispatch its fault before any bytes are patched. Simulate
       FEX restoring logical write permission after invalidation. */
    unsigned char patch = 0xe9;
    logical_prot = PROT_READ | PROT_EXEC;
    assert(ios_alias_write_is_trapped(anon_rx));
    assert(!ios_alias_write(anon_rx, &patch, 1, &blocked, 1) && rw[0] == 0);
    logical_prot |= PROT_WRITE;
    assert(ios_alias_write(anon_rx, &patch, 1, &blocked, 1) && rx[0] == 0xe9);
    logical_prot = 0;
    assert(!ios_alias_write(anon_rx, &patch, 1, &blocked, 1));
    logical_prot = PROT_READ | PROT_WRITE | PROT_EXEC;
    uint64_t r[32] = {0}, before[32], got[2];
    r[9] = 0x1234567887654321ull; r[8] = 0xaabbccddeeff0011ull;
    r[10] = anon_rx;
    assert(ios_alias_store_pair(0xa9882149u, anon_rx + 128, r, &blocked, 1));
    memcpy(got, rx + 128, sizeof(got));
    assert(got[0] == r[9] && got[1] == r[8] && r[10] == anon_rx + 128);
    r[31] = anon_rx + 256;
    assert(ios_alias_store_pair(stp(1, 3, -2, 31, 9, 31), anon_rx + 240, r, &blocked, 1));
    memcpy(got, rx + 240, sizeof(got));
    assert(!got[0] && got[1] == r[9] && r[31] == anon_rx + 240);
    r[10] = anon_rx + 64;
    assert(ios_alias_store_pair(stp(0, 1, -2, 9, 8, 10), anon_rx + 64, r, &blocked, 1));
    uint32_t words[2]; memcpy(words, rx + 64, sizeof(words));
    assert(words[0] == (uint32_t)r[9] && words[1] == (uint32_t)r[8]);
    assert(r[10] == anon_rx + 56);
    r[29] = 0x1122334455667788ull; r[30] = 0x8877665544332211ull;
    r[10] = anon_rx + 16;
    assert(ios_alias_store_pair(stp(1, 2, 0, 29, 30, 10), anon_rx + 16, r, &blocked, 1));
    memcpy(got, rx + 16, sizeof(got)); assert(got[0] == r[29] && got[1] == r[30]);
    /* A fault on the second word still writes both values at the original EA. */
    r[10] = anon_rx + 80;
    assert(ios_alias_store_pair(stp(1, 1, 2, 9, 8, 10), anon_rx + 88, r, &blocked, 1));
    memcpy(got, rx + 80, sizeof(got));
    assert(got[0] == r[9] && got[1] == r[8] && r[10] == anon_rx + 96);
    r[10] = anon_rx + n - 8;
    memcpy(before, r, sizeof(r));
    unsigned char tail[16]; memcpy(tail, rx + n - 16, 16);
    assert(!ios_alias_store_pair(stp(1, 1, 2, 9, 8, 10), anon_rx + n - 8, r, &blocked, 1));
    assert(!memcmp(tail, rx + n - 16, 16) && !memcmp(before, r, sizeof(r)));
    assert(!ios_alias_store_pair(0xa9c82149u, anon_rx + 128, r, &blocked, 1)); /* LDP */
    assert(!ios_alias_store_pair(0xad882149u, anon_rx + 128, r, &blocked, 1)); /* SIMD */
    assert(!ios_alias_store_pair(stp(1, 1, 2, 9, 8, 9), anon_rx + 128, r, &blocked, 1)); /* unpredictable */
    assert(!ios_alias_store_pair(stp(1, 1, 2, 9, 8, 10), UINTPTR_MAX - 3, r, &blocked, 1));
    /* The failing CoreCLR case: logical RWX + host RX is intentional. */
    assert(!may_restore(rx + 128, 1, PROT_READ|PROT_WRITE|PROT_EXEC, PROT_READ|PROT_EXEC));
    /* Preserve recovery for unaliased ordinary data, and decline read faults,
       logical read-only mappings, and failed protection queries. */
    assert(may_restore(r, 1, PROT_READ|PROT_WRITE, PROT_READ));
    assert(!may_restore(r, 0, PROT_READ|PROT_WRITE, PROT_READ));
    assert(!may_restore(r, 1, PROT_READ, PROT_READ));
    assert(!may_restore(r, 1, PROT_READ|PROT_WRITE, -1));
    anon_rx = anon_rw = anon_size = 0; /* retired alias */
    assert(!ios_write_alias((uintptr_t)rx + 128));
    ios_jit_rx_base_global = rx; ios_jit_rw_base_global = rw; ios_jit_pool_size_global = n;
    logical_prot = PROT_READ; /* native pool addresses are not guest mappings */
    assert(!ios_alias_write_is_trapped((uintptr_t)rx));
    assert(!may_restore(rx + 128, 1, PROT_READ|PROT_WRITE|PROT_EXEC, PROT_READ|PROT_EXEC));
    r[10] = (uintptr_t)rx + 128;
    assert(ios_alias_store_pair(stp(1, 0, 0, 9, 8, 10), (uintptr_t)rx + 128, r, &blocked, 1));
    assert(!ios_write_alias((uintptr_t)rx + n));
    /* Reproduce a 2-byte opcode store crossing into a nonadjacent alias.
       The intervening pool slot represents bcrypt.dll's MZ header. */
    ios_jit_rx_base_global = ios_jit_rw_base_global = 0;
    logical_prot = PROT_READ | PROT_WRITE | PROT_EXEC;
    unsigned char *backing = mmap(0, 3 * 0x4000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0);
    assert(backing != MAP_FAILED);
    anon_rx = 0x7193b44000ull; anon_rw = (uintptr_t)backing; anon_size = 0x4000;
    second_rx = anon_rx + 0x4000; second_rw = (uintptr_t)backing + 2 * 0x4000;
    unsigned char data[32]; for(unsigned j=0; j<32; ++j) data[j] = 0x8d + j;
    for(unsigned size=2; size<=32; size*=2)
    for(unsigned split=1; split<size; ++split)
    {
        memset(backing, 0x5a, 3 * 0x4000);
        assert(ios_alias_write(second_rx - split, data, size, &blocked, 1));
        assert(!memcmp(backing + 0x4000 - split, data, split));
        assert(!memcmp(backing + 2 * 0x4000, data + split, size - split));
        for(unsigned j=0; j<0x4000; ++j) assert(backing[0x4000 + j] == 0x5a);
    }
    memset(backing, 0x5a, 3 * 0x4000);
    trapped_page = second_rx;
    assert(!ios_alias_write(second_rx - 1, data, 2, &blocked, 1));
    assert(blocked == second_rx);
    assert(backing[0x3fff] == 0x5a && backing[0x8000] == 0x5a);
    /* The phone's 8-byte write starts six bytes before the page boundary.
       Report the still-protected second page, not the original FAR. */
    assert(!ios_alias_write(second_rx - 6, data, 8, &blocked, 1));
    assert(blocked == second_rx);
    r[10] = second_rx - 8;
    memcpy(before, r, sizeof(r));
    assert(!ios_alias_store_pair(stp(1, 1, 2, 9, 8, 10), r[10], r, &blocked, 1));
    assert(blocked == second_rx && !memcmp(before, r, sizeof(r)));
    trapped_page = 0; /* FEX invalidated the reported page and untrapped it */
    assert(ios_alias_write(second_rx - 6, data, 8, &blocked, 1));
    assert(!blocked && !memcmp(backing + 0x4000 - 6, data, 6));
    assert(!memcmp(backing + 0x8000, data + 6, 2));
    memset(backing, 0x5a, 3 * 0x4000);
    trapped_page = anon_rx + 0x1000;
    assert(!ios_alias_write(trapped_page - 1, data, 2, &blocked, 1));
    assert(blocked == trapped_page);
    assert(backing[0xfff] == 0x5a && backing[0x1000] == 0x5a);
    trapped_page = 0;
    second_rx = second_rw = 0; /* absent/retired second page: no partial write */
    assert(!ios_alias_write(anon_rx + 0x3fff, data, 2, &blocked, 1));
    assert(backing[0x3fff] == 0x5a);
    assert(!ios_alias_write(UINTPTR_MAX, data, 2, &blocked, 1));
    assert(!ios_alias_write(anon_rx, data, 33, &blocked, 1));
    /* Stardew 200111 freeze: FEX's handler had invalidated the page, then
       RunCASPAL wrote it from FEX's own code (pool copy of xtajit64.dll). */
    second_rx = anon_rx + 0x4000; second_rw = (uintptr_t)backing + 2 * 0x4000;
    memset(backing, 0x5a, 3 * 0x4000);
    trapped_page = anon_rx + 0x1000;
    fex_pool_start = 0x151f0b000ull; fex_pool_end = fex_pool_start + 0x410000;
    uintptr_t fex_pc = 0x152020398ull, jit_pc = 0x16119a56cull, at = trapped_page + 0x1c0;
    assert(honor_for(anon_rw + 0x11c0, at, jit_pc));              /* guest store: FEX first */
    assert(!ios_alias_write(at, data, 16, &blocked, honor_for(1, at, jit_pc)));
    assert(blocked == at && backing[0x11c0] == 0x5a);
    assert(!honor_for(anon_rw + 0x11c0, at, fex_pc));             /* FEX handler store */
    assert(ios_alias_write(at, data, 16, &blocked, honor_for(1, at, fex_pc)));
    assert(!blocked && !memcmp(backing + 0x11c0, data, 16));
    assert(honor_for(0, at, fex_pc));                             /* no alias: unchanged */
    trapped_page = 0;
    assert(honor_for(anon_rw + 0x11c0, at, fex_pc));              /* untrapped: unchanged */
    trapped_page = second_rx;                                     /* span into a trapped page */
    assert(!ios_alias_write(second_rx - 6, data, 8, &blocked, 1) && blocked == second_rx);
    assert(ios_alias_write(second_rx - 6, data, 8, &blocked, 0));
    assert(!memcmp(backing + 0x4000 - 6, data, 6) && !memcmp(backing + 0x8000, data + 6, 2));
    trapped_page = 0; second_rx = second_rw = 0;
    /* RunCASPAL: caspal x6, x7, x2, x3, [x0] (0x4866fc02) on the RW alias. */
    uint64_t g[29] = {0}, cell[2] __attribute__((aligned(16))) = {11, 22};
    g[6] = 11; g[7] = 22; g[2] = 33; g[3] = 44;
    assert(ios_mach_emulate_casp(0x4866fc02u, (uintptr_t)cell, g));
    assert(cell[0] == 33 && cell[1] == 44 && g[6] == 11 && g[7] == 22);
    g[6] = 1; g[7] = 2;                                           /* compare fails */
    assert(ios_mach_emulate_casp(0x4866fc02u, (uintptr_t)cell, g));
    assert(cell[0] == 33 && cell[1] == 44 && g[6] == 33 && g[7] == 44);
    uint32_t w[2] __attribute__((aligned(8))) = {5, 6};         /* 32-bit CASPAL */
    g[6] = 5; g[7] = 6; g[2] = 7; g[3] = 8;
    assert(ios_mach_emulate_casp(0x0866fc02u, (uintptr_t)w, g) && w[0] == 7 && w[1] == 8);
    assert(!ios_mach_emulate_casp(0x4866fc02u, (uintptr_t)cell + 8, g)); /* misaligned */
    assert(!ios_mach_emulate_casp(0x4867fc02u, (uintptr_t)cell, g));     /* odd Rs */
    assert(!ios_mach_emulate_casp(0x487cfc02u, (uintptr_t)cell, g));     /* Rs+1 = x29 */
    assert(!ios_mach_emulate_casp(0xc8e9fec8u, (uintptr_t)cell, g));     /* CASAL, not a pair */
    munmap(backing, 3 * 0x4000);
    munmap(rx, n); munmap(rw, n); fclose(f);
    puts("PASS: alias protection preserved; FEX handler stores complete; CASPAL; STP widths, writeback, bounds and registers");
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-alias-write-') as tmp:
    src, exe = Path(tmp)/'check.c', Path(tmp)/'check'
    src.write_text(code)
    subprocess.run([os.environ.get('CC','cc'), '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', '-fno-sanitize-recover=all', str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
