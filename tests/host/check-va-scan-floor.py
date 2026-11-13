#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""env.MADEIRA_VA_SCAN_FLOOR: the free-area scan does not try what lies below the address map.

iOS extends __PAGEZERO by the ASLR slide, so the address map starts at the app
image (address-map=[0x104e60000,0xfc0000000)) and every fixed mapping below is
refused. Mach reports that range as a free hole, so the scan had nothing to
jump over and tried it one granule at a time: 66,845 refused mappings and as
many region queries to place one 4 KB view, under virtual_mutex ("[va-scan]
SLOW window=0x10000..0x400000000 size=0x1000 ... tries=66845"). Madeira Dock's
once-a-second process snapshot does 14 such placements a second (Wine's
toolhelp maps a view per Process32Next); Terraria's frame loop only ran in the
gaps (2026-11-13, iPad14,8: frame times of hundreds of ms, 1.3 ms of GPU).

Checks:
  - try_map_free_area, ios_skip_occupied and ios_va_map_floor, cut out of
    virtual_ios.c and run on the host against a fake address map (a floor, the
    app image at it, regions above):
    - bottom-up and top-down scans, windows that start below, at and above the
      floor or end below it, granules of 16 KB to 1 MB: the address returned,
      the tries counted and the first refusal reported are the same with the
      switch on, with it off, and when the kernel does not report a floor;
    - on, no mapping is attempted below the floor; every attempt saved is
      counted as below-floor;
    - the measured case (floor 0x104e60000, window 0x10000..0x400000000, a
      4 KB view) costs under 100 attempts instead of over 66,000;
    - a fixed-address attempt (step 0) below the floor is still made;
    - the floor is asked for once, and never with the switch off;
  - in the source: the switch is read once, the jump sits before the mapping
    attempt, and the [va-scan] line reports below-floor;
  - the settings catalog lists the switch (when the catalog exists).
The host run is skipped when no C compiler is found.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

R = Path(__file__).resolve().parents[2]
src = (R / "build/ntdll-unix/virtual_ios.c").read_text()
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok = ok and bool(cond)


def function(signature):
    start = src.index(signature)
    return src[start:src.index("\n}\n", start) + 3]


floor_fn = function("static uintptr_t ios_va_map_floor(void)")
skip_fn = function("static int ios_skip_occupied( void *addr, size_t size, size_t align_mask,")
scan_fn = function("static void* try_map_free_area( void *base, void *end, ptrdiff_t step,")

check("the switch is read once", src.count('getenv( "MADEIRA_VA_SCAN_FLOOR" )') == 1 and
      'getenv( "MADEIRA_VA_SCAN_FLOOR" )' in floor_fn)
check("the floor is the kernel's TASK_VM_INFO.min_address", "lo = (uintptr_t)vmi.min_address;" in floor_fn)
check("the jump comes before the mapping attempt and leaves a fixed-address attempt alone",
      "if (step)\n        {\n            uintptr_t floor = ios_va_map_floor(), a = (uintptr_t)start;" in scan_fn and
      scan_fn.index("ios_va_map_floor()") < scan_fn.index("anon_mmap_tryfixed( start, size, unix_prot, 0 )"))
check("the [va-scan] line reports below-floor",
      'tries=%u skips=%u below-floor=%u"' in src and "ios_va_scan_below_floor - below0," in src)

harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#define WINE_IOS 1
typedef uintptr_t UINT_PTR;
#define ROUND_ADDR(addr,mask) ((void *)((UINT_PTR)(addr) & ~(UINT_PTR)(mask)))
#define MAP_FAILED ((void *)-1)
#define TRACE(...) ((void)0)
#define ERR(...) ((void)0)
static int lines;
#define dprintf(fd, ...) (lines++)
typedef int kern_return_t; typedef unsigned int mach_msg_type_number_t; typedef int *task_info_t;
typedef uint64_t mach_vm_address_t, mach_vm_size_t; typedef unsigned int mach_port_t; typedef int *vm_region_info_t;
typedef struct { int protection; } vm_region_basic_info_data_64_t;
typedef struct { uint64_t min_address, max_address; } task_vm_info_data_t;
#define KERN_SUCCESS 0
#define TASK_VM_INFO 22
#define TASK_VM_INFO_COUNT 1
#define VM_REGION_BASIC_INFO_64 9
#define VM_REGION_BASIC_INFO_COUNT_64 1
#define MACH_PORT_NULL 0
#define mach_task_self() 0

/* the fake address map: nothing below kern_floor, the app image at it, regions above */
#define NREG 96
static uint64_t kern_floor, kern_max = 0xfc0000000ull, reg_lo[NREG], reg_hi[NREG];
static unsigned nreg, floor_asks, attempts, attempts_below;
static int floor_known = 1, floor_inverted;
static kern_return_t task_info( int task, int flavor, task_info_t out, mach_msg_type_number_t *cnt )
{
    task_vm_info_data_t *vmi = (task_vm_info_data_t *)out;
    (void)task; (void)flavor; (void)cnt;
    floor_asks++;
    if (!floor_known) return 5;
    vmi->min_address = floor_inverted ? kern_max : kern_floor;
    vmi->max_address = kern_max;
    return KERN_SUCCESS;
}
static kern_return_t mach_vm_region( int task, mach_vm_address_t *addr, mach_vm_size_t *size, int flavor,
                                     vm_region_info_t info, mach_msg_type_number_t *cnt, mach_port_t *obj )
{
    unsigned i;
    (void)task; (void)flavor; (void)info; (void)cnt; (void)obj;
    for (i = 0; i < nreg; i++)
        if (reg_hi[i] > *addr) { *addr = reg_lo[i]; *size = reg_hi[i] - reg_lo[i]; return KERN_SUCCESS; }
    return 1;
}
static void *anon_mmap_tryfixed( void *start, size_t size, int prot, int flags )
{
    uint64_t a = (uintptr_t)start;
    unsigned i;
    (void)prot; (void)flags;
    attempts++;
    if (a < kern_floor) { attempts_below++; errno = ENOMEM; return MAP_FAILED; }
    for (i = 0; i < nreg; i++)
        if (a < reg_hi[i] && a + size > reg_lo[i]) { errno = EEXIST; return MAP_FAILED; }
    return start;
}
void *ios_jit_rx_base_global, *ios_jit_rw_base_global;
size_t ios_jit_pool_size_global, ios_jit_low_size_global;
uintptr_t ios_jit_low_rx_global, ios_jit_low_rw_global;
unsigned long long ios_layerkit_lo, ios_layerkit_hi;
static unsigned long ios_layerkit_skips;
static int ios_in_layerkit( unsigned long long a, size_t size ) { (void)a; (void)size; return 0; }
static unsigned int ios_va_scan_tries, ios_va_scan_skips, ios_va_scan_below_floor;
static void *ios_scan_fail_addr;
static int ios_scan_fail_errno;
''' + skip_fn + floor_fn + scan_fn + r'''
static unsigned long long rng = 7;
static uint64_t rnd( uint64_t n ) { rng = rng * 6364136223846793005ull + 1442695040888963407ull; return (rng >> 24) % n; }

static void scan( uint64_t base, uint64_t end, uint64_t g, uint64_t size, int dir )
{
    uint64_t start = dir > 0 ? (base + g - 1) & ~(g - 1) : dir < 0 ? (end - size) & ~(g - 1) : base;
    void *r;
    if (!start || start < base || start + size > end) return;
    ios_va_scan_tries = ios_va_scan_skips = ios_va_scan_below_floor = 0;
    ios_scan_fail_addr = NULL; ios_scan_fail_errno = 0;
    attempts = attempts_below = 0;
    r = try_map_free_area( (void *)(uintptr_t)base, (void *)(uintptr_t)end, dir > 0 ? (ptrdiff_t)g : dir < 0 ? -(ptrdiff_t)g : 0,
                           (void *)(uintptr_t)start, size, 0 );
    /* what both modes must agree on, then what differs */
    printf( "%d %llx %llx %llx %llx -> %p tries=%u fail=%p/%d | attempts=%u below=%u counted=%u\n",
            dir, (unsigned long long)base, (unsigned long long)end, (unsigned long long)g, (unsigned long long)size,
            r, ios_va_scan_tries, ios_scan_fail_addr, ios_scan_fail_errno,
            attempts, attempts_below, ios_va_scan_below_floor );
}

int main( int argc, char **argv )
{
    static const uint64_t grans[] = { 0x4000, 0x10000, 0x100000 };
    static const uint64_t sizes[] = { 0x1000, 0x4000, 0x10000, 0x11000, 0x100000, 0x800000 };
    uint64_t at;
    unsigned i;

    kern_floor = strtoull( argv[1], NULL, 16 );
    if (argc > 2 && !strcmp( argv[2], "unknown" )) floor_known = 0;
    if (argc > 2 && !strcmp( argv[2], "inverted" )) floor_inverted = 1;
    reg_lo[0] = kern_floor; reg_hi[0] = kern_floor + 0x1000000; nreg = 1;   /* the app image */
    for (at = reg_hi[0]; nreg < NREG; nreg++)
    {
        reg_lo[nreg] = at + (rnd( 6 ) ? 0 : (1 + rnd( 64 )) * 0x4000);       /* mostly packed, some gaps */
        reg_hi[nreg] = reg_lo[nreg] + (1 + rnd( 512 )) * 0x4000;
        at = reg_hi[nreg];
    }
    /* the measured case: one 4 KB view, bottom-up from 0x10000 */
    scan( 0x10000, 0x400000000ull, 0x10000, 0x1000, 1 );
    scan( 0x100010000ull, 0x400000000ull, 0x10000, 0x1000, 1 );
    scan( 0x10000, 0x400000000ull, 0x10000, 0x1000, 0 );                     /* a fixed address below the floor */
    for (i = 0; i < 400; i++)
    {
        uint64_t g = grans[rnd( 3 )], size = sizes[rnd( 6 )], base, end;
        switch (rnd( 5 ))
        {
        case 0: base = 0x10000; break;
        case 1: base = 0x100000000ull; break;
        case 2: base = kern_floor - rnd( 0x400 ) * 0x4000; break;
        case 3: base = kern_floor; break;
        default: base = kern_floor + rnd( 0x4000 ) * 0x4000; break;
        }
        switch (rnd( 4 ))
        {
        case 0: end = 0x400000000ull; break;
        case 1: end = kern_floor - rnd( 0x100 ) * 0x4000; break;             /* a window wholly below the floor */
        case 2: end = kern_floor + rnd( 0x800 ) * 0x4000; break;
        default: end = at + rnd( 0x4000 ) * 0x4000; break;
        }
        scan( base, end, g, size, rnd( 2 ) ? 1 : -1 );
    }
    printf( "floor=%llx asks=%u\n", (unsigned long long)ios_va_map_floor(), floor_asks );
    return 0;
}
'''

cc = shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
if not cc:
    print("SKIP host run: no C compiler")
else:
    with tempfile.TemporaryDirectory() as tmp:
        c = os.path.join(tmp, "t.c")
        exe = os.path.join(tmp, "t")
        open(c, "w").write(harness)
        b = subprocess.run([cc, "-std=gnu99", "-O1", "-Wall", "-Werror", "-Wno-unused-function", "-Wno-unused-variable",
                            "-Wno-unused-value", "-o", exe, c], capture_output=True, text=True)
        check("the scan builds on the host", b.returncode == 0)
        if b.returncode:
            print(b.stderr[-3000:])
        else:
            def run(floor, switch, mode=None):
                env = dict(os.environ)
                env.pop("MADEIRA_VA_SCAN_FLOOR", None)
                env.pop("MADEIRA_MAP_RETRY_ANY", None)
                if switch is not None:
                    env["MADEIRA_VA_SCAN_FLOOR"] = switch
                r = subprocess.run([exe, floor] + ([mode] if mode else []), capture_output=True, text=True, env=env)
                assert r.returncode == 0, r.stderr
                rows = r.stdout.strip().split("\n")
                scans = []
                for row in rows[:-1]:
                    same, differs = row.split(" | ")
                    scans.append((same, dict((k, int(v)) for k, v in (f.split("=") for f in differs.split()))))
                return scans, rows[-1]

            same = fewer = counted = clean = True
            saved = 0
            for floor in ("104e60000", "1026e0000", "104d54000", "100000000"):
                on, on_end = run(floor, None)
                off, off_end = run(floor, "0")
                unknown, unknown_end = run(floor, None, "unknown")
                inverted, inverted_end = run(floor, None, "inverted")
                assert len(on) == len(off) > 300, (len(on), len(off))
                same &= [s for s, _ in on] == [s for s, _ in off] == [s for s, _ in unknown] == [s for s, _ in inverted]
                step0 = [d for s, d in on if s.startswith("0 ")]
                clean &= all(d["below"] == 0 for s, d in on if not s.startswith("0 ")) and \
                    [d["attempts"] for d in step0] == [1] and [d["below"] for d in step0] == [1]
                counted &= all(a["attempts"] + a["counted"] == b["attempts"] and b["counted"] == 0
                               for (_, a), (_, b) in zip(on, off))
                counted &= [d for _, d in unknown] == [d for _, d in off] == [d for _, d in inverted]
                saved += sum(b["attempts"] - a["attempts"] for (_, a), (_, b) in zip(on, off))
                fewer &= on_end == "floor=%s asks=1" % floor and off_end == "floor=0 asks=0" and \
                    unknown_end == "floor=0 asks=1" and inverted_end == "floor=0 asks=1"
                if floor == "104e60000":
                    a, b = on[0][1], off[0][1]
                    print("     the measured case: %d attempts with the switch off, %d on" % (b["attempts"], a["attempts"]))
                    check("the measured case: over 66,000 attempts off, under 100 on", b["attempts"] > 66000 and a["attempts"] < 100)
            check("on, off and with no floor reported: the same address, tries and first refusal for every scan", same)
            check("on: nothing is attempted below the floor, except a fixed-address attempt (once)", clean)
            check("every attempt saved is counted as below-floor; off and unknown attempt them all", counted and saved > 1000000)
            check("the floor is asked for once, never with the switch off, and an unusable answer is ignored", fewer)

catalog = R / "app/Madeira/ConfigCatalog.generated.swift"
if catalog.exists():
    check("the settings catalog lists env.MADEIRA_VA_SCAN_FLOOR",
          'ConfigOption(key: "env.MADEIRA_VA_SCAN_FLOOR"' in catalog.read_text())

print("PASS: va-scan floor" if ok else "FAILED: va-scan floor")
sys.exit(0 if ok else 1)
