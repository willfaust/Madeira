#!/usr/bin/env python3
"""The opt-in census of the 64 GB band (virtual_ios.c ios_band_census); no Wine runs.

RDR2.exe reserves 8960 MB in one block as it starts; in its first run
(build 457, log 2026-10-08 21:20:59) the band [0x7000000000, 0x8000000000) had
no gap that large. env MADEIRA_BAND_CENSUS=1 logs what each piece of Social
Club's layout 2 uses. Compiles the census code against a fake mach_vm_region
over a scripted map and checks:
  - without the env nothing is printed and the map is never walked;
  - layout 2 splits the band into its pieces, with the RW alias and the room
    above it apart; mapped, used, resident, dirty, top and gap per piece come
    out of the scripted regions, a region crossing a piece boundary counts in
    both and its pages only where it starts;
  - the band's largest gap is aligned to 64 KB and decides "fits" / "does not
    fit" for 8960 MB;
  - the session's highest used offset per piece is kept across censuses;
  - an RW alias elsewhere gives one "RW alias and above" piece, another layout
    four 16 GB slots, a task map ending below the band one line;
  - with MADEIRA_RDR2_VA_HOLD's geometry the pieces follow it and the RDR2
    hold has its own;
  - at most 64 censuses;
and textually that the census runs with the periodic slot probe and at a
failed large reserve after the boot holdback was tried.
Needs python3 and a C compiler (CC, default cc).
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/virtual_ios.c').read_text()

defines = '\n'.join(re.findall(r'^#define IOS_SC(?:2_[A-Z0-9_]+|_ARENA_BASE)\s.*$', src, re.M))
start = src.index('#define IOS_BAND_LO')
func = src.index('static void ios_band_census( const char *why )\n{')
chunk = src[start:src.index('\n}\n', func) + 3]

harness = r'''
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>
#include <pthread.h>
typedef int kern_return_t;
typedef unsigned int mach_msg_type_number_t;
typedef unsigned int mach_port_t;   /* Darwin's pthread.h chain typedefs it as unsigned int; C11 same-type redefinition is legal */
typedef uint64_t mach_vm_address_t, mach_vm_size_t;
typedef int *vm_region_info_t;
typedef int *task_info_t;
typedef struct { int protection; unsigned user_tag, pages_resident, pages_shared_now_private, pages_swapped_out,
                 pages_dirtied, ref_count; unsigned short shadow_depth; unsigned char external_pager, share_mode;
                 unsigned pages_reusable; } vm_region_extended_info_data_t;
typedef struct { unsigned long long max_address; } task_vm_info_data_t;
#define KERN_SUCCESS 0
#define MACH_PORT_NULL 0
#define VM_REGION_EXTENDED_INFO 13
#define VM_REGION_EXTENDED_INFO_COUNT 1
#define TASK_VM_INFO 22
#define TASK_VM_INFO_COUNT 1
static int mach_task_self(void) { return 1; }
static unsigned long long fake_max = 0x8000000000ull;
static kern_return_t task_info(int t, int f, task_info_t out, mach_msg_type_number_t *c)
{ (void)t; (void)f; (void)c; ((task_vm_info_data_t *)out)->max_address = fake_max; return KERN_SUCCESS; }
struct fake_region { uint64_t lo, hi; int prot; unsigned res, dirty, swapped; };
static struct fake_region map[64];
static int map_n, walks;
static kern_return_t mach_vm_region(int t, mach_vm_address_t *a, mach_vm_size_t *s, int f, vm_region_info_t i,
                                    mach_msg_type_number_t *c, mach_port_t *o)
{
    vm_region_extended_info_data_t *x = (vm_region_extended_info_data_t *)i;
    int k;
    (void)t; (void)f; (void)c; (void)o;
    walks++;
    for (k = 0; k < map_n; k++)
        if (map[k].hi > *a)
        {
            memset(x, 0, sizeof(*x));
            *a = map[k].lo; *s = map[k].hi - map[k].lo;
            x->protection = map[k].prot; x->pages_resident = map[k].res;
            x->pages_dirtied = map[k].dirty; x->pages_swapped_out = map[k].swapped;
            return KERN_SUCCESS;
        }
    return 1;
}
static void add(uint64_t lo, uint64_t hi, int prot, unsigned res, unsigned dirty, unsigned swapped)
{ map[map_n].lo = lo; map[map_n].hi = hi; map[map_n].prot = prot; map[map_n].res = res;
  map[map_n].dirty = dirty; map[map_n].swapped = swapped; map_n++; }
static int ios_sc_layout_mode = 2;
static int ios_sc2_rdr2;
static void *ios_jit_rw_base_global = (void *)0x7900000000ull;
static size_t ios_jit_pool_size_global = 0x52848000;
static uintptr_t ios_jit_low_rw_global;
static size_t ios_jit_low_size_global;
static char out[1 << 18]; static size_t outn;
static int fake_dprintf(int fd, const char *fmt, ...)
{
    va_list ap;
    int w;
    (void)fd;
    va_start(ap, fmt);
    w = vsnprintf(out + outn, sizeof out - outn, fmt, ap);
    va_end(ap);
    if (w > 0) outn += w;
    return w;
}
#define dprintf fake_dprintf
''' + defines + '\n' + chunk + r'''
#undef dprintf
#define MB(x) ((uint64_t)(x) << 20)
static int fail(const char *what) { printf("%s\nFAIL: %s\n", out, what); return 1; }
static int count(const char *needle) { int n = 0; const char *p = out; while ((p = strstr(p, needle))) { n++; p++; } return n; }
static int has(const char *needle) { return strstr(out, needle) != NULL; }

/* The band at RDR2.exe's failed reserve in build 457, simplified: 16 KB pages. */
static void map_457(void)
{
    map_n = 0;
    add(0x7000000000ull, 0x7010000000ull, 3, 0x2000, 0x1800, 0x100);   /* libcef pools: 256 MB used */
    add(0x7010000000ull, 0x7100000000ull, 0, 0, 0, 0);
    add(0x7100000000ull, 0x7339e50000ull, 0, 0, 0, 0);                 /* furniture, gap of 1830 MB above */
    add(0x73ac480000ull, 0x73ffff0000ull, 3, 0x100, 0x80, 0);
    add(0x7400000000ull, 0x7415000000ull, 3, 0x40, 0x40, 0);            /* chrome_elf metadata: 336 MB used */
    add(0x7415000000ull, 0x75f0000000ull, 0, 0, 0, 0);
    add(0x75f0000000ull, 0x7610000000ull, 3, 0x400, 0x200, 0);          /* crosses into libcef's metadata */
    add(0x7610000000ull, 0x7800000000ull, 0, 0, 0, 0);
    add(0x7800000000ull, 0x7880000000ull, 3, 0x8000, 0x8000, 0x4000);   /* chrome_elf pools: 2048 MB used */
    add(0x7880000000ull, 0x7900000000ull, 0, 0, 0, 0);
    add(0x7900000000ull, 0x7952848000ull, 3, 0x1000, 0x1000, 0);        /* RW alias */
    add(0x7a00000000ull, 0x7a40000000ull, 3, 0x1000, 0x800, 0);         /* V8 cage */
    add(0x7a40000000ull, 0x7afff00000ull, 0, 0, 0, 0);
    add(0x7afff00000ull, 0x7b00000000ull, 3, 0x10, 0x10, 0);
    add(0x7b00000000ull, 0x7c00000000ull, 0, 0, 0, 0);
    add(0x7c00000000ull, 0x7c08000000ull, 3, 0x200, 0x200, 0);          /* Oilpan: 128 MB used */
    add(0x7c08000000ull, 0x7d00000000ull, 0, 0, 0, 0);
    add(0x7d00000000ull, 0x7e80000000ull, 3, 0x3000, 0x2000, 0);        /* FEX arena: 6144 MB used */
    add(0x7e80000000ull, 0x8000000000ull, 0, 0, 0, 0);
}

static const char *piece(const char *range)
{
    const char *p = strstr(out, range);
    return p ? p : "";
}

int main(int argc, char **argv)
{
    const char *s = argc > 1 ? argv[1] : "";
    int i;

    map_457();
    if (!strcmp(s, "off"))
    {
        ios_band_census("periodic");
        if (outn || walks) return fail("the census ran without MADEIRA_BAND_CENSUS=1");
        printf("PASS: without MADEIRA_BAND_CENSUS=1 the band is not walked and nothing is printed\n");
        return 0;
    }
    if (!strcmp(s, "457"))
    {
        ios_band_census("jumbo reserve failed");
        if (!has("[band] census #1 (jumbo reserve failed)")) return fail("no header line");
        if (!has("largest gap 2775 MB at 0x7952850000 -- RDR2.exe's 8960 MB reserve does not fit")) return fail("band gap or verdict wrong");
        if (count("[band]   [") != 10) return fail("layout 2 does not have ten pieces");
        if (!strstr(piece("[0x7000000000,0x7100000000) libcef.dll's pools:"), "regions=2 mapped=4096 used=256 resident=128 dirty=100 MB, top +256 MB (session +256 MB), gap 0 MB"))
            return fail("libcef pools line wrong");
        if (!strstr(piece("[0x7100000000,0x7400000000) furniture:"), "regions=2 mapped=10457 used=1339 resident=4 dirty=2 MB, top +12287 MB (session +12287 MB), gap 1830 MB"))
            return fail("furniture line wrong");
        if (!strstr(piece("[0x7400000000,0x7600000000) chrome_elf.dll's metadata:"), "regions=3 mapped=8192 used=592 resident=17 dirty=9 MB, top +8192 MB"))
            return fail("a region crossing into the next piece is not split, or its pages count twice");
        if (!strstr(piece("[0x7600000000,0x7800000000) libcef.dll's metadata:"), "regions=2 mapped=8192 used=256 resident=0 dirty=0 MB, top +256 MB"))
            return fail("the crossing region's second part is wrong");
        if (!strstr(piece("[0x7800000000,0x7900000000) chrome_elf.dll's pools:"), "used=2048 resident=512 dirty=768 MB, top +2048 MB"))
            return fail("chrome_elf pools line wrong (dirty = dirtied + compressed)");
        if (!strstr(piece("[0x7900000000,0x7952848000) JIT pool RW alias:"), "regions=1 mapped=1320 used=1320"))
            return fail("RW alias piece wrong");
        if (!strstr(piece("[0x7952848000,0x7a00000000) above the RW alias:"), "regions=0 mapped=0 used=0 resident=0 dirty=0 MB, top +0 MB (session +0 MB), gap 2775 MB"))
            return fail("the room above the alias is wrong");
        if (!strstr(piece("[0x7a00000000,0x7c00000000) V8 cage:"), "used=1025 resident=64 dirty=32 MB, top +4096 MB"))
            return fail("V8 cage line wrong");
        if (!strstr(piece("[0x7c00000000,0x7d00000000) Oilpan's cage:"), "used=128 resident=8 dirty=8 MB, top +128 MB"))
            return fail("Oilpan line wrong");
        if (!strstr(piece("[0x7d00000000,0x8000000000) FEX arena:"), "regions=2 mapped=12288 used=6144 resident=192 dirty=128 MB, top +6144 MB"))
            return fail("FEX arena line wrong");
        printf("PASS: layout 2 at RDR2's failed reserve: ten pieces, a crossing region split, gap 2775 MB at a 64 KB boundary, 8960 MB does not fit\n");
        return 0;
    }
    if (!strcmp(s, "fits"))
    {
        /* libcef's metadata given up: [0x7600000000, 0x7800000000) unmapped (8 GB), plus the gap below it */
        map_n = 0;
        add(0x7000000000ull, 0x75d0000000ull, 0, 0, 0, 0);
        add(0x7800000000ull, 0x8000000000ull, 0, 0, 0, 0);
        ios_band_census("periodic");
        if (!has("largest gap 8960 MB at 0x75d0000000 -- RDR2.exe's 8960 MB reserve fits")) return fail("an exact 8960 MB gap does not fit");
        outn = 0; out[0] = 0;
        map_n = 0;
        add(0x7000000000ull, 0x75d0008000ull, 0, 0, 0, 0);    /* 32 KB short once aligned to 64 KB */
        add(0x7800000000ull, 0x8000000000ull, 0, 0, 0, 0);
        ios_band_census("periodic");
        if (!has("at 0x75d0010000 -- RDR2.exe's 8960 MB reserve does not fit")) return fail("the gap is not aligned to 64 KB");
        printf("PASS: 8960 MB fits an exact gap and not one that is short once aligned to 64 KB\n");
        return 0;
    }
    if (!strcmp(s, "session"))
    {
        ios_band_census("periodic");
        map_n = 0;
        add(0x7000000000ull, 0x7008000000ull, 3, 0, 0, 0);     /* libcef pools shrank to 128 MB */
        add(0x7008000000ull, 0x8000000000ull, 0, 0, 0, 0);
        outn = 0; out[0] = 0;
        ios_band_census("periodic");
        if (!has("[band] census #2 (periodic)")) return fail("no second census");
        if (!strstr(piece("libcef.dll's pools:"), "top +128 MB (session +256 MB)")) return fail("the session's highest offset is not kept");
        if (!has("largest gap 0 MB at 0x0 -- RDR2.exe's 8960 MB reserve does not fit")) return fail("a full band reports a gap");
        printf("PASS: the session's highest used offset per piece survives a later census\n");
        return 0;
    }
    if (!strcmp(s, "alias"))
    {
        ios_jit_rw_base_global = (void *)0x7048000000ull;
        ios_band_census("periodic");
        if (count("[band]   [") != 9) return fail("an alias elsewhere still splits the piece");
        if (!has("[0x7900000000,0x7a00000000) JIT pool RW alias and above:")) return fail("no combined piece");
        printf("PASS: with the RW alias elsewhere, [0x7900000000,0x7a00000000) is one piece\n");
        return 0;
    }
    if (!strcmp(s, "low"))
    {
        /* pool-low: region C's alias starts the RW reservation at 0x7900000000, the pool's alias above it */
        ios_jit_low_rw_global = 0x7900000000ull; ios_jit_low_size_global = 0x10000000;
        ios_jit_rw_base_global = (void *)0x7910000000ull; ios_jit_pool_size_global = 0x42848000;
        ios_band_census("periodic");
        if (!has("[0x7900000000,0x7952848000) JIT pool RW alias:")) return fail("region C's alias is not part of the alias piece");
        printf("PASS: with pool-low the alias piece covers region C's alias and the pool's\n");
        return 0;
    }
    if (!strcmp(s, "rdr2"))
    {
        /* MADEIRA_RDR2_VA_HOLD: libcef's pools 256 MB, furniture from 0x7010000000, chrome_elf metadata
         * 6.25 GB, libcef metadata 1 GB, the hold below chrome_elf's pools */
        ios_sc2_rdr2 = 1;
        ios_band_census("periodic");
        if (!has("layout 2 with MADEIRA_RDR2_VA_HOLD, [0x7000000000,0x8000000000)")) return fail("the header does not name the variant");
        if (count("[band]   [") != 11) return fail("the variant does not have eleven pieces");
        if (!has("[band]   [0x7000000000,0x7010000000) libcef.dll's pools:") ||
            !has("[band]   [0x7010000000,0x7400000000) furniture:") ||
            !has("[band]   [0x7400000000,0x7590000000) chrome_elf.dll's metadata:") ||
            !has("[band]   [0x7590000000,0x75d0000000) libcef.dll's metadata:") ||
            !has("[band]   [0x75d0000000,0x7800000000) RDR2 hold:") ||
            !has("[band]   [0x7800000000,0x7900000000) chrome_elf.dll's pools:") ||
            !has("[band]   [0x7c00000000,0x7c40000000) Oilpan's cage:") ||
            !has("[band]   [0x7c40000000,0x8000000000) FEX arena:"))
            return fail("the variant's pieces are wrong");
        printf("PASS: with MADEIRA_RDR2_VA_HOLD the census follows its geometry and names the hold\n");
        return 0;
    }
    if (!strcmp(s, "layout0"))
    {
        ios_sc_layout_mode = 0;
        ios_band_census("periodic");
        if (count("16 GB slot:") != 4 || count("[band]   [") != 4) return fail("another layout does not get four 16 GB slots");
        if (!has("[0x7c00000000,0x8000000000) 16 GB slot:")) return fail("last slot wrong");
        printf("PASS: another layout gets four 16 GB slots\n");
        return 0;
    }
    if (!strcmp(s, "ceiling"))
    {
        fake_max = 0xfc0000000ull;
        ios_band_census("periodic");
        if (!has("[band] census #1 (periodic): the task map ends at 0xfc0000000, below the band") || walks)
            return fail("a task map below the band is walked or not said");
        printf("PASS: a task map that ends below the band gives one line and no walk\n");
        return 0;
    }
    if (!strcmp(s, "cap"))
    {
        for (i = 0; i < 70; i++) ios_band_census("periodic");
        if (count("[band] census #") != 64 || !has("[band] census #64 ") || has("[band] census #65 "))
            return fail("not capped at 64 censuses");
        printf("PASS: at most 64 censuses\n");
        return 0;
    }
    printf("unknown scenario %s\n", s);
    return 2;
}
'''

cc = os.environ.get('CC', 'cc')
with tempfile.TemporaryDirectory(prefix='madeira-band-census-') as directory:
    c = Path(directory) / 'b.c'
    exe = Path(directory) / 'b'
    c.write_text(harness)
    build = subprocess.run([cc, '-std=gnu11', '-Wall', '-Werror', '-Wno-unused-function', '-Wno-unused-variable',
                            '-fsanitize=address,undefined', '-o', str(exe), str(c), '-lpthread'],
                           capture_output=True, text=True)
    assert build.returncode == 0, build.stdout + build.stderr
    for scenario in ('off', '457', 'fits', 'session', 'alias', 'low', 'rdr2', 'layout0', 'ceiling', 'cap'):
        env = {k: v for k, v in os.environ.items() if not k.startswith('MADEIRA_')}
        if scenario != 'off':
            env['MADEIRA_BAND_CENSUS'] = '1'
        run = subprocess.run([str(exe), scenario], capture_output=True, text=True, env=env)
        print(run.stdout, end='')
        assert run.returncode == 0, (scenario, run.stdout + run.stderr)

sweep = src[src.index('ios_bigres_report( "periodic" );'):]
assert sweep.index('ios_band_census( "periodic" );') < sweep.index('}'), 'the census runs in the periodic sweep block'
jumbo = src[src.index('[jumbo] kernel-pick reserve failed (0x%x) for size=0x%lx'):]
jumbo = jumbo[:jumbo.index('ios_va_gap_probe( "jumbo reserve failed" );')]
assert jumbo.index('ios_jumbo_holdback_take( *size_ptr );') < jumbo.index('ios_band_census( "jumbo reserve failed" );') \
    < jumbo.index('if (probed++ < 2)'), 'the census runs at a failed large reserve, after the holdback was tried'
print('PASS: the census runs with the periodic slot probe and at a failed large reserve after the holdback')
