#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Ported from a community host check; anchors are the merged engine code's.
"""env.MADEIRA_FEX_BAND_KEEP_MB: the steer valve may not take the lowest N MB of the FEX arena.

A 64-bit title made 24 reservations of 511 MB; the steer valve placed them in [0x7c00000000,
0x8000000000), which is also the emulator's arena (FEX_ONLY: a request is served from it when it
lies inside it), and fragmentation left no 4 MB-aligned gap there: "[va-scan] FAILED", then
"[alloc-fail] FEXAlloc could not allocate", a trap in libarm64ecfex.dll and exit c000001d. With the
key the valve's first attempt starts N MB above the arena's base.

Checks:
  - ios_steer_floor, cut out of virtual_ios.c and run on the host:
    - unset, empty, 0, a non-number, a leading space or a minus sign: the bound is 0x7c00000000
      (ios_steer_slot) and nothing is logged;
    - 6144: the bound is 0x7c00000000 + 6 GB = 0x7d80000000, one log line however often it is asked;
    - a value past the arena's size: the bound is the arena's end (the band is closed to the valve);
    - an arena that is not the one at 0x7c00000000 (SC_PA_POOLS: 0x7d00000000): the bound stays
      ios_steer_slot, one "not applied" line;
    - no arena yet: the bound is ios_steer_slot and nothing is latched, so the next call applies it;
  - the valve's two FEX-band attempts both start at that bound, every other range it uses is
    unchanged, and the call site skips the attempt only when the key moved the bound;
  - the switch is read once; the settings catalog lists it (when the catalog exists).
The host run is skipped when no C compiler is found.
"""
from pathlib import Path
import os
import re
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


start = src.index("static ULONG_PTR ios_steer_floor( void )")
fn = src[start:src.index("\n}\n", start) + 3]
check("the switch is read once", src.count('getenv( "MADEIRA_FEX_BAND_KEEP_MB" )') == 1)
check("the slot is still 0x7C00000000", "static const ULONG_PTR ios_steer_slot = 0x7C00000000;" in src)

# The valve: both attempts in the FEX band start at the bound; the second range and the pool slots are as before.
valve = src[src.index("ULONG_PTR steer_lo = ios_steer_floor();"):src.index("if (!sst && ios_steer_n < IOS_STEER_MAX)")]
# Compare the code only: comments are dropped and whitespace runs folded to one space.
flat = " ".join(re.sub(r"/\*.*?\*/", " ", valve, flags=re.S).split())
# steer_ok is false (the FEX-band attempt is skipped) when the arena guard skips the top slot, or when the key
# moved the bound to the host ceiling or above; the bound itself is never skipped when it is still the slot.
check("the first attempt starts at the bound",
      "int steer_top = ios_steer_top_slot_usable();" in src and
      "ULONG_PTR steer_lo = ios_steer_floor(); "
      "int steer_ok = steer_top && (steer_lo == ios_steer_slot || steer_lo < (ULONG_PTR)host_addr_space_limit); "
      "NTSTATUS sst = !steer_ok ? STATUS_NO_MEMORY "
      ": allocate_virtual_memory( ret, size_ptr, type, protect, steer_lo, "
      "(ULONG_PTR)host_addr_space_limit, 0, 0 );" in flat)
check("the retry after reclaiming starts at the bound",
      "sst = !steer_ok ? STATUS_NO_MEMORY "
      ": allocate_virtual_memory( ret, size_ptr, type, protect, steer_lo, "
      "(ULONG_PTR)host_addr_space_limit, 0, 0 );" in flat)
check("the second range is still [0x7400000000, ios_spill_cap), twice",
      valve.count("0x7400000000ULL, ios_spill_cap, 0, 0 )") == 2)
check("the bound is asked for once per steer, and no other call in the valve names ios_steer_slot",
      valve.count("ios_steer_floor()") == 1 and valve.count("ios_steer_slot,") == 0)
check("the bound is used nowhere else", src.count("ios_steer_floor()") == 1)
check("the pool-slot walk still skips ios_steer_slot", "if (slot == ios_steer_slot) continue;" in src)

cc = shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
if not cc:
    print("SKIP host run: no C compiler")
else:
    harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
typedef uintptr_t ULONG_PTR;
static int lines;
#define dprintf(fd, ...) (lines++)
static const ULONG_PTR ios_steer_slot = 0x7C00000000;
static ULONG_PTR ios_fex_arena_base_unix, ios_fex_arena_end_unix;
''' + fn + r'''
static int fails;
static void expect( const char *what, ULONG_PTR got, ULONG_PTR want, int want_lines )
{
    if (got != want || lines != want_lines)
    {
        printf( "FAIL %s: bound 0x%llx (want 0x%llx), %d log lines (want %d)\n", what,
                (unsigned long long)got, (unsigned long long)want, lines, want_lines );
        fails++;
    }
}
int main( int argc, char **argv )
{
    int i;
    ULONG_PTR r;
    const char *mode = argc > 1 ? argv[1] : "";
    if (!strcmp( mode, "off" ))
    {
        ios_fex_arena_base_unix = 0x7c00000000ull; ios_fex_arena_end_unix = 0x8000000000ull;
        for (i = 0; i < 3; i++) r = ios_steer_floor();
        expect( "off", r, 0x7c00000000ull, 0 );
    }
    else if (!strcmp( mode, "on" ))
    {
        ios_fex_arena_base_unix = 0x7c00000000ull; ios_fex_arena_end_unix = 0x8000000000ull;
        for (i = 0; i < 5; i++) r = ios_steer_floor();
        expect( "on 6144", r, 0x7d80000000ull, 1 );
    }
    else if (!strcmp( mode, "huge" ))
    {
        ios_fex_arena_base_unix = 0x7c00000000ull; ios_fex_arena_end_unix = 0x8000000000ull;
        r = ios_steer_floor();
        expect( "past the arena", r, 0x8000000000ull, 1 );
    }
    else if (!strcmp( mode, "otherarena" ))
    {
        ios_fex_arena_base_unix = 0x7d00000000ull; ios_fex_arena_end_unix = 0x8000000000ull;
        for (i = 0; i < 4; i++) r = ios_steer_floor();
        expect( "arena at 0x7d00000000", r, 0x7c00000000ull, 1 );
    }
    else if (!strcmp( mode, "noarena" ))
    {
        r = ios_steer_floor();
        expect( "no arena yet", r, 0x7c00000000ull, 0 );
        ios_fex_arena_base_unix = 0x7c00000000ull; ios_fex_arena_end_unix = 0x8000000000ull;
        r = ios_steer_floor();
        expect( "arena arrives", r, 0x7d80000000ull, 1 );
    }
    if (!fails) printf( "harness ok\n" );
    return fails != 0;
}
'''
    with tempfile.TemporaryDirectory() as tmp:
        c = os.path.join(tmp, "t.c")
        exe = os.path.join(tmp, "t")
        open(c, "w").write(harness)
        b = subprocess.run([cc, "-std=gnu99", "-Wall", "-Werror", "-Wno-unused-function", "-o", exe, c],
                           capture_output=True, text=True)
        check("the function builds on the host", b.returncode == 0)
        if b.returncode:
            print(b.stderr[-2000:])
        else:
            def run(mode, value):
                env = dict(os.environ)
                env.pop("MADEIRA_FEX_BAND_KEEP_MB", None)
                if value is not None:
                    env["MADEIRA_FEX_BAND_KEEP_MB"] = value
                r = subprocess.run([exe, mode], capture_output=True, text=True, env=env)
                return r.returncode == 0, (r.stdout + r.stderr).strip()

            res = {v: run("off", v) for v in (None, "", "0", "abc", " 6144", "-5", "0x1800")}
            check("off (unset, '', '0', 'abc', ' 6144', '-5', '0x1800'): the bound is 0x7c00000000 and nothing is logged",
                  all(good for good, _ in res.values()))
            for v, (good, out) in res.items():
                if not good:
                    print("   ", repr(v), out)
            good, out = run("on", "6144")
            check("6144: the bound is 0x7d80000000 and one line is logged however often it is asked", good)
            if not good:
                print(out)
            good, out = run("huge", "99999999999999999999")
            check("a value past the arena closes the band to the valve (bound = the arena's end)", good)
            if not good:
                print(out)
            good, out = run("otherarena", "6144")
            check("an arena at 0x7d00000000: not applied, the bound stays 0x7c00000000, one line", good)
            if not good:
                print(out)
            good, out = run("noarena", "6144")
            check("no arena yet: the bound is the slot and nothing is latched; it applies once the arena exists", good)
            if not good:
                print(out)

catalog = R / "app/Madeira/ConfigCatalog.generated.swift"
if catalog.exists():
    check("the settings catalog lists env.MADEIRA_FEX_BAND_KEEP_MB",
          "env.MADEIRA_FEX_BAND_KEEP_MB" in catalog.read_text(encoding="utf-8", errors="replace"))

print("PASS: FEX band keep" if ok else "FAILED: FEX band keep")
sys.exit(0 if ok else 1)
