#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Ported from a community host check; anchors are the merged engine code's.
"""env.MADEIRA_VA_PRESSURE_GAP_OK: a slow scan through iOS's refused hole is not pressure.

A 64-bit title: the app image landed high (address-map=[0x104d54000,...), 4 of 11 launches). A
bottom-up scan then ground 1398 tries through the hole iOS refuses below the
image (firstfail=0x100000000 errno=12, "iOS REFUSED A FREE ADDRESS") before it
succeeded, and latched ios_va_pressure 0.4 s after start, with 7645 MB free.
The steer valve then sent every 32 MB-1 GB reservation into the FEX band, which
the swap tier never backs: 2.9 GB more anonymous memory.

Checks:
  - ios_va_pressure_low_hole, cut out of virtual_ios.c and run on the host:
    - unset, 0 or yes: never skips the latch;
    - on: it skips only a scan that succeeded and whose first refusal was
      ENOMEM below the guest band (0x7000000000);
    - a failed scan, EEXIST inside the band, or a refusal at or above
      0x7000000000 still latch;
    - at most 8 log lines;
  - the latch site calls it only after the old condition held, so with the
    switch off the latch is the old one;
  - the settings catalog lists the switch (when the catalog exists).
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


start = src.index("static int ios_va_pressure_low_hole( const void *ptr, const void *fail_addr, int fail_errno )")
fn = src[start:src.index("\n}\n", start) + 3]
check("the switch is read once", src.count('getenv( "MADEIRA_VA_PRESSURE_GAP_OK" )') == 1)
# the second line may carry a trailing comment; only the code is anchored
site = re.compile(re.escape("                if ((!ptr || ios_va_scan_tries - tries0 >= 1024) &&\n"
                            "                    !ios_va_pressure_low_hole( ptr, ios_scan_fail_addr, ios_scan_fail_errno ))")
                  + r"[^\n]*\n" +
                  re.escape("                {\n"
                            "                    static int censused;\n\n"
                            "                    ios_va_pressure = 1;\n"))
check("the latch: the old condition first, then the switch's exception", site.search(src) is not None)
check("it is the only place that latches", src.count("ios_va_pressure = 1;") == 1)

cc = shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
if not cc:
    print("SKIP host run: no C compiler")
else:
    harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
typedef uintptr_t ULONG_PTR;
static int lines;
#define dprintf(fd, ...) (lines++)
''' + fn + r'''
int main( int argc, char **argv )
{
    void *ok_ptr = (void *)0x7040000000ull;
    void *hole = (void *)0x100000000ull, *band = (void *)0x73ffdf0000ull, *edge = (void *)0x7000000000ull;
    int i, r = 0;
    if (argc > 1 && !strcmp( argv[1], "off" ))
    {
        r |= ios_va_pressure_low_hole( ok_ptr, hole, ENOMEM );
        printf( "%d\n", r );
        return 0;
    }
    if (!ios_va_pressure_low_hole( ok_ptr, hole, ENOMEM )) { printf( "FAIL the refused hole is skipped\n" ); return 1; }
    if (ios_va_pressure_low_hole( NULL, hole, ENOMEM )) { printf( "FAIL a failed scan latches\n" ); return 1; }
    if (ios_va_pressure_low_hole( ok_ptr, NULL, ENOMEM )) { printf( "FAIL no refusal address latches\n" ); return 1; }
    if (ios_va_pressure_low_hole( ok_ptr, band, EEXIST )) { printf( "FAIL grinding in the band latches\n" ); return 1; }
    if (ios_va_pressure_low_hole( ok_ptr, band, ENOMEM )) { printf( "FAIL ENOMEM in the band latches\n" ); return 1; }
    if (ios_va_pressure_low_hole( ok_ptr, edge, ENOMEM )) { printf( "FAIL the band's first byte latches\n" ); return 1; }
    if (ios_va_pressure_low_hole( ok_ptr, hole, EEXIST )) { printf( "FAIL EEXIST below the band latches\n" ); return 1; }
    for (i = 0; i < 20; i++) ios_va_pressure_low_hole( ok_ptr, hole, ENOMEM );
    if (lines != 8) { printf( "FAIL %d log lines, not 8\n", lines ); return 1; }
    printf( "harness ok\n" );
    return 0;
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
            env = dict(os.environ, MADEIRA_VA_PRESSURE_GAP_OK="1")
            r = subprocess.run([exe], capture_output=True, text=True, env=env)
            print(r.stdout.strip())
            check("on: only a successful scan whose first refusal was ENOMEM below 0x7000000000 is skipped; 8 lines at most",
                  r.returncode == 0)
            seen = {}
            for value in (None, "", "0", "yes"):
                env = dict(os.environ)
                env.pop("MADEIRA_VA_PRESSURE_GAP_OK", None)
                if value is not None:
                    env["MADEIRA_VA_PRESSURE_GAP_OK"] = value
                seen[value] = subprocess.run([exe, "off"], capture_output=True, text=True, env=env).stdout.strip()
            check("off (unset, '', '0', 'yes'): never skips the latch", set(seen.values()) == {"0"})

catalog = R / "app/Madeira/ConfigCatalog.generated.swift"
if catalog.exists():
    cat = catalog.read_text()
    check("the settings catalog lists env.MADEIRA_VA_PRESSURE_GAP_OK", 'ConfigOption(key: "env.MADEIRA_VA_PRESSURE_GAP_OK"' in cat)

print("PASS: va-pressure gap" if ok else "FAILED: va-pressure gap")
sys.exit(0 if ok else 1)
