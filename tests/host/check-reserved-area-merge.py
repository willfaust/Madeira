#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Russell Barton
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""A generic reserved area never swallows a FEX or thin area that follows it (virtual_ios.c mmap_add_reserved_area).

When an added range extends a generic area, the merge loop joins it with the following areas only up to the first FEX or thin
area: the generic area ends there and the part of the range above it is added on its own, so generic placement never gets a
special area. (ml799 handles a range that lands on the FEX arena itself.)

Checks, with the production mmap_add_reserved_area compiled (ASan/UBSan, -Werror) against a model of Wine's list:
  - a range bridging a generic area and a following FEX area keeps the FEX area whole, with the generic area below it and the
    rest of the range above it;
  - the same for a following thin area that ends where the range ends;
  - generic areas the range bridges merge into one.
Placement in the areas (map_reserved_area_once) is left to the special kinds' own checks.
Needs python3 and a C compiler.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/virtual_ios.c").read_text()
cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")


def cut(text, start, end="\n}\n"):
    at = text.index(start)
    return text[at:text.index(end, at) + len(end)]


struct = cut(src, "struct reserved_area\n{", "\n};\n")
add = cut(src, "static void mmap_add_reserved_area( void *addr, SIZE_T size )")
harness = r'''
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef size_t SIZE_T; typedef uintptr_t UINT_PTR;
struct list { struct list *next, *prev; };
#define LIST_INIT(l) { &(l), &(l) }
static void list_add_before( struct list *e, struct list *n ) { n->next = e; n->prev = e->prev; e->prev->next = n; e->prev = n; }
static void list_remove( struct list *e ) { e->next->prev = e->prev; e->prev->next = e->next; }
static struct list *list_next( struct list *l, struct list *e ) { return e->next == l ? NULL : e->next; }
#define LIST_ENTRY(e, t, f) ((t *)((char *)(e) - offsetof(t, f)))
#define LIST_FOR_EACH(c, l) for ((c) = (l)->next; (c) != (l); (c) = (c)->next)
''' + struct + r''';
static struct list reserved_areas = LIST_INIT(reserved_areas);
static const UINT_PTR host_page_mask = 0x3fff;
''' + add + r'''
static int fails;
#define T(c) do { if (!(c)) { printf( "FAIL line %d: %s\n", __LINE__, #c ); fails++; } } while (0)
#define MB(x) ((SIZE_T)(x) << 20)
static void put( UINT_PTR base, SIZE_T size, int fex, int thin )
{
    struct reserved_area *a = calloc( 1, sizeof(*a) );
    struct list *ptr;
    a->base = (void *)base; a->size = size; a->fex_only = fex; a->thin_only = thin;
    LIST_FOR_EACH( ptr, &reserved_areas ) if (LIST_ENTRY( ptr, struct reserved_area, entry )->base > a->base) break;
    list_add_before( ptr, &a->entry );
}
static void clear( void )
{
    struct list *e;
    while ((e = list_next( &reserved_areas, &reserved_areas ))) { list_remove( e ); free( LIST_ENTRY( e, struct reserved_area, entry ) ); }
}
/* "base:size:kind ..." of the list, in MB */
static const char *dump( void )
{
    static char buf[512];
    size_t n = 0;
    struct list *ptr;
    buf[0] = 0;
    LIST_FOR_EACH( ptr, &reserved_areas )
    {
        struct reserved_area *a = LIST_ENTRY( ptr, struct reserved_area, entry );
        n += snprintf( buf + n, sizeof(buf) - n, "%s%lu:%lu:%c", n ? " " : "", (unsigned long)((UINT_PTR)a->base >> 20),
                       (unsigned long)(a->size >> 20), a->fex_only ? 'F' : a->thin_only ? 'T' : 'g' );
    }
    return buf;
}
int main( void )
{
    const UINT_PTR B = MB(0x10000);   /* 64 GB, in a region nothing else uses */
    /* a range that bridges a generic area and the FEX area after it, and runs past its end */
    put( B, MB(16), 0, 0 ); put( B + MB(32), MB(64), 1, 0 );
    mmap_add_reserved_area( (void *)(B + MB(8)), MB(128) );
    printf( "fex: %s\n", dump() );
    T( !strcmp( dump(), "65536:32:g 65568:64:F 65632:40:g" ) );
    clear();
    /* the same with a thin area that ends exactly where the range ends */
    put( B, MB(16), 0, 0 ); put( B + MB(32), MB(16), 0, 1 );
    mmap_add_reserved_area( (void *)(B + MB(8)), MB(40) );
    T( !strcmp( dump(), "65536:32:g 65568:16:T" ) );
    clear();
    /* generic areas merge into one area from the first base to the range's end */
    put( B, MB(16), 0, 0 ); put( B + MB(32), MB(16), 0, 0 ); put( B + MB(64), MB(16), 0, 0 );
    mmap_add_reserved_area( (void *)(B + MB(8)), MB(64) );
    T( !strcmp( dump(), "65536:80:g" ) );
    clear();
    puts( fails ? "FAILED" : "ok" );
    return fails != 0;
}
'''
harness = harness.replace("#include <stdlib.h>\n", "#include <stdlib.h>\n#include <string.h>\n", 1)

ok = True
if not cc:
    print("FAIL: a C compiler for the host test (no cc/clang/gcc)")
    sys.exit(1)
with tempfile.TemporaryDirectory() as tmp:
    c, exe = Path(tmp) / "m.c", Path(tmp) / "m"
    c.write_text(harness)
    flags = ["-std=gnu11", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
             "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined"]
    r = subprocess.run([cc, *flags, "-o", str(exe), str(c)], capture_output=True, text=True)
    if r.returncode:
        print("FAIL: mmap_add_reserved_area compiles against the list model\n" + r.stderr[-2000:])
        sys.exit(1)
    p = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
    good = p.returncode == 0 and p.stdout.strip().endswith("ok")
    print(("PASS: " if good else "FAIL: ") + "a bridging range keeps a following FEX or thin area whole; generic merges unchanged"
          + ("" if good else "\n" + p.stdout + p.stderr))
    ok = good
sys.exit(0 if ok else 1)
