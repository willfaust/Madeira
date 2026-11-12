#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Russell Barton
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""env.MADEIRA_X64_HOOK_ZONE = 1: 16 MB of free address space directly above a 64-bit process's ntdll, for hook code (virtual_ios.c).

A 64-bit hook needs its trampoline within 2 GB of the hooked function, but pseudo-processes share one address space and 64-bit
images pack top-down, so other processes' views lie above a process's DLLs (Far Cry 4's FC64.dll searches upward from
ntdll!NtProtectVirtualMemory for free pages, finds none and quits). With the switch each 64-bit process's ntdll is placed with a
FIXED_ONLY reserved area above it: generic placement never uses it, a fixed request inside it maps, the process's later images
go below it, and it is released when the process ends.

Checks:
  1. the reserved-area kind: a field next to fex_only/thin_only, 0 for every other adder, kept across a split, skipped by the
     merge, by generic placement in both directions, by the virtual heap and by virtual_release_address_space; map_fixed_area
     refuses only thin areas;
  2. the pure region (-Wall -Wextra -Werror, ASan/UBSan): the per-process table (the session's own process recorded before its
     PEB exists; an exact entry wins) and the ceiling;
  3. the production functions against a fake reserved-area list and fake mappings (ASan/UBSan): mmap_add_fixed_only_area (never
     merged, overlap refused, sorted), a generic merge next to a zone, ios_hook_zone_map_image (the zone directly above the
     image at its 64 KB-rounded end, the image part unmapped and mapped fixed, a failed map_view or registration leaves nothing
     behind), the release, the switch (only "1" turns it on), and FC64's upward probe against that model;
  4. the wiring: map_image_view takes the request on entry, lowers limit_high to the zone for the process's images and places
     the ntdll with its zone before its ordinary placement; loader_ios.c requests a zone around both ntdll loads (the
     session's only for a 64-bit main program); ios_jit_reclaim_process releases it; the session end clears the switch and the
     catalog documents it.
Not covered: the kernel's placement, a race with host mappings between the unmap and the fixed map (the code falls back), the
real view tree, and FEX executing a trampoline in the zone.
Needs python3 and a C compiler.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/virtual_ios.c").read_text()
ldr = (root / "build/ntdll-unix/loader_ios.c").read_text()
cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
ok = True


def check(what, cond, detail=""):
    global ok
    print(("PASS: " if cond else "FAIL: ") + what + (("\n      " + str(detail)[:2000]) if detail and not cond else ""))
    ok = ok and bool(cond)


def cut(text, start, end="\n}\n"):
    at = text.index(start)
    return text[at:text.index(end, at) + len(end)]


# ---------------------------------------------------------------- 1. the kind
struct = cut(src, "struct reserved_area\n{", "\n};\n")
check("the kind is a field of the reserved area, next to fex_only and thin_only", "unsigned int fixed_only;" in struct)
check("every adder sets it: 1 for the zone adder only, 0 for generic, FEX and thin areas",
      src.count("area->fixed_only = 0;") == 3 and src.count("area->fixed_only = 1;") == 1)
check("a split keeps the kind", "new_area->fixed_only = area->fixed_only;" in src)
check("the merge, the virtual heap and virtual_release_address_space skip it",
      src.count("if (area->fex_only || area->thin_only || area->fixed_only) continue;") == 3
      and "if (area->fex_only || area->thin_only) continue;" not in src)
check("generic placement in reserved areas skips it in both directions",
      src.count("if (area->fixed_only) continue;   /* x64-hook-zone: fixed requests only */") == 2)
mfa = cut(src, "static NTSTATUS map_fixed_area( void *base, size_t size, int unix_prot )")
check("map_fixed_area refuses only thin arenas: a fixed request inside a zone maps", "fixed_only" not in mfa and "area->thin_only &&" in mfa)

# ---------------------------------------------------------------- 2. the pure region
a, b = "/* x64-hook-zone-test:begin", "/* x64-hook-zone-test:end */"
check("the test region is present once", src.count(a) == 1 and src.count(b) == 1)
region = src[src.index(a):src.index(b)]
HEAD = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
typedef size_t SIZE_T; typedef uintptr_t ULONG_PTR; typedef int32_t NTSTATUS; typedef void *PVOID;
'''
T1 = r'''
static int fails;
#define T(c) do { if (!(c)) { printf( "FAIL line %d: %s\n", __LINE__, #c ); fails++; } } while (0)
int main( void )
{
    static struct ios_hook_zone t[IOS_HOOK_ZONES];
    static char p1, p2, sess;
    unsigned i;
    T( !ios_hook_zone_find( t, &p1, &sess ) );
    T( ios_hook_zone_add( t, &p1, 0x71f0000000, 0x1000000 ) && ios_hook_zone_add( t, NULL, 0x71fe800000, 0x1000000 ) );
    T( ios_hook_zone_find( t, &p1, &sess )->base == 0x71f0000000 );
    T( ios_hook_zone_find( t, &sess, &sess )->base == 0x71fe800000 );   /* the session's own process, once its PEB exists */
    T( !ios_hook_zone_find( t, &p2, &sess ) && !ios_hook_zone_find( t, &sess, NULL ) && !ios_hook_zone_find( t, NULL, &sess ) );
    /* the session's zone registered first; a child that is also named as the session still gets its own zone */
    {
        static struct ios_hook_zone t2[IOS_HOOK_ZONES];
        T( ios_hook_zone_add( t2, NULL, 0x71fee00000, 0x1000000 ) && ios_hook_zone_add( t2, &p1, 0x71f2230000, 0x1000000 ) );
        T( ios_hook_zone_find( t2, &p1, &p1 )->base == 0x71f2230000 && ios_hook_zone_find( t2, &p1, &sess )->base == 0x71f2230000 );
        T( ios_hook_zone_find( t2, &sess, &sess )->base == 0x71fee00000 && !ios_hook_zone_find( t2, &p2, &sess ) );
    }
    /* the ceiling: below the zone; unchanged without a zone, when the zone is above the limit, or when nothing is left */
    T( ios_hook_zone_limit( ios_hook_zone_find( t, &p1, &sess ), 0x100000000, 0x73ffefffff ) == 0x71efffffff );
    T( ios_hook_zone_limit( NULL, 0x100000000, 0x73ffefffff ) == 0x73ffefffff );
    T( ios_hook_zone_limit( ios_hook_zone_find( t, &p1, &sess ), 0x100000000, 0x7000000000 ) == 0x7000000000 );
    T( ios_hook_zone_limit( ios_hook_zone_find( t, &p1, &sess ), 0x71f0000000, 0x73ffefffff ) == 0x73ffefffff );
    for (i = 2; i < IOS_HOOK_ZONES; i++) T( ios_hook_zone_add( t, &p2, 0x1000 * i, 0x1000 ) );
    T( !ios_hook_zone_add( t, &p2, 0x9000, 0x1000 ) );                  /* a full table refuses */
    puts( fails ? "FAILED" : "ok" );
    return fails != 0;
}
'''


def build_and_run(code, tmp, name, args=()):
    c, exe = Path(tmp) / f"{name}.c", Path(tmp) / name
    c.write_text(code)
    flags = [cc, "-std=gnu11", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
             "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-fno-omit-frame-pointer"]
    r = subprocess.run(flags + ["-o", str(exe), str(c)], capture_output=True, text=True)
    if r.returncode:
        return None, r.stderr
    try:
        p = subprocess.run([str(exe), *args], capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(exe, 124, "", "timed out"), "timed out"
    return p, p.stdout + p.stderr


with tempfile.TemporaryDirectory() as tmp:
    r, out = build_and_run(HEAD + region + T1, tmp, "pure")
    check("the per-process table and the ceiling (strict, ASan/UBSan)", r is not None and r.returncode == 0, out)

# ---------------------------------------------------------------- 3. the production functions on a fake map
fns = [cut(src, "static void mmap_add_reserved_area( void *addr, SIZE_T size )"),
       cut(src, "static void mmap_remove_reserved_area( void *addr, SIZE_T size )"),
       cut(src, "static int mmap_add_fixed_only_area( void *addr, SIZE_T size )")]
zone_map = cut(src, "static NTSTATUS ios_hook_zone_map_image(")
zone_died = cut(src, "static void ios_hook_zone_owner_died( void *dead_peb )")
zone_bytes = cut(src, "static SIZE_T ios_hook_zone_bytes(void)")
FAKE = r'''
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
typedef size_t SIZE_T; typedef uintptr_t ULONG_PTR, UINT_PTR; typedef int32_t NTSTATUS; typedef int sigset_t_;
#define STATUS_SUCCESS 0
#define STATUS_NO_MEMORY ((NTSTATUS)0xc0000017)
#define STATUS_NOT_SUPPORTED ((NTSTATUS)0xc00000bb)
#define STATUS_CONFLICTING_ADDRESSES ((NTSTATUS)0xc0000018)
#define max(a,b) ((a) > (b) ? (a) : (b))
#define ROUND_SIZE(addr,size,mask) (((SIZE_T)(size) + ((UINT_PTR)(addr) & (mask)) + (mask)) & ~(UINT_PTR)(mask))
struct list { struct list *next, *prev; };
#define LIST_INIT(l) { &(l), &(l) }
static void list_add_before( struct list *e, struct list *n ) { n->next = e; n->prev = e->prev; e->prev->next = n; e->prev = n; }
static void list_add_after( struct list *e, struct list *n ) { n->prev = e; n->next = e->next; e->next->prev = n; e->next = n; }
static void list_remove( struct list *e ) { e->next->prev = e->prev; e->prev->next = e->next; }
static struct list *list_next( struct list *l, struct list *e ) { return e->next == l ? NULL : e->next; }
static struct list *list_head( struct list *l ) { return l->next == l ? NULL : l->next; }
#define LIST_ENTRY(e, t, f) ((t *)((char *)(e) - offsetof(t, f)))
#define LIST_FOR_EACH(c, l) for ((c) = (l)->next; (c) != (l); (c) = (c)->next)
#define LIST_FOR_EACH_ENTRY(e, l, t, f) for ((e) = LIST_ENTRY((l)->next, t, f); &(e)->f != (l); (e) = LIST_ENTRY((e)->f.next, t, f))
#define TRACE(...) do { } while (0)
#define ERR(...) do { } while (0)
#define dprintf(fd, ...) (n_log++, snprintf( last_log, sizeof(last_log), __VA_ARGS__ ))
static int n_log; static char last_log[512];
''' + struct + r''';
static struct list reserved_areas = LIST_INIT(reserved_areas);
static const UINT_PTR granularity_mask = 0xffff, host_page_mask = 0x3fff;
static void *address_space_start = (void *)0x10000;
static int virtual_mutex;
static void server_enter_uninterrupted_section( int *m, sigset_t_ *s ) { (void)m; (void)s; }
static void server_leave_uninterrupted_section( int *m, sigset_t_ *s ) { (void)m; (void)s; }
#define sigset_t sigset_t_
/* the fake kernel: one free hole; the views a test made */
struct file_view { void *base; size_t size; };
static char *hole_lo, *hole_hi; static int free_fail, view_fail, n_unmap; static char *unmapped[8]; static size_t unmapped_size[8];
static struct file_view the_view; static char *removed_base;
static void *map_free_area( void *base, void *end, size_t size, int top_down, int unix_prot, size_t align_mask )
{
    char *lo = max( (char *)base, hole_lo ), *hi = (char *)end < hole_hi ? (char *)end : hole_hi;
    (void)unix_prot;
    if (free_fail || !top_down || hi - lo < (ptrdiff_t)size) return NULL;
    return (void *)(((uintptr_t)hi - size) & ~(uintptr_t)align_mask);
}
static int munmap_( void *a, size_t s ) { unmapped[n_unmap] = a; unmapped_size[n_unmap++] = s; return 0; }
#define munmap munmap_
static NTSTATUS map_view( struct file_view **v, void *base, size_t size, unsigned a, unsigned p, ULONG_PTR lo, ULONG_PTR hi, size_t m )
{
    (void)a; (void)p; (void)lo; (void)hi; (void)m;
    if (view_fail) return STATUS_NO_MEMORY;
    the_view.base = base; the_view.size = size; *v = &the_view;
    return STATUS_SUCCESS;
}
static void remove_reserved_area( void *addr, size_t size );
'''
ZONES = r'''
''' + region + r'''
static struct ios_hook_zone ios_hook_zones[IOS_HOOK_ZONES];
#define IOS_HOOK_ZONE_SIZE (16u << 20)
'''
T2 = r'''
static void remove_reserved_area( void *addr, size_t size ) { removed_base = addr; mmap_remove_reserved_area( addr, size ); }
static int fails;
#define T(c) do { if (!(c)) { printf( "FAIL line %d: %s\n", __LINE__, #c ); fails++; } } while (0)
static struct reserved_area *area_at( void *base )
{
    struct reserved_area *a;
    LIST_FOR_EACH_ENTRY( a, &reserved_areas, struct reserved_area, entry ) if (a->base == base) return a;
    return NULL;
}
static int n_areas( void ) { struct list *p; int n = 0; LIST_FOR_EACH( p, &reserved_areas ) n++; return n; }
static void clear( void )
{
    while (list_head( &reserved_areas ))
    { struct list *p = list_head( &reserved_areas ); list_remove( p ); free( LIST_ENTRY( p, struct reserved_area, entry ) ); }
    memset( ios_hook_zones, 0, sizeof(ios_hook_zones) ); n_unmap = free_fail = view_fail = 0; removed_base = NULL;
}
/* FC64's probe against this model: a fixed 4 KB request maps when it is not inside a view and lies inside a zone */
static unsigned probe_upward( char *from, char **got )
{
    unsigned n;
    for (n = 1; n < 100000; n++, from += 0x1000)
    {
        char *base = (char *)((uintptr_t)from & ~(uintptr_t)0xffff);
        struct reserved_area *a;
        if (base < (char *)the_view.base + the_view.size && base + 0x1000 > (char *)the_view.base) continue;   /* the image */
        LIST_FOR_EACH_ENTRY( a, &reserved_areas, struct reserved_area, entry )
            if (a->fixed_only && base >= (char *)a->base && base + 0x1000 <= (char *)a->base + a->size) { *got = base; return n; }
    }
    return 0;
}
int main( void )
{
    struct file_view *view = NULL;
    static char child;
    char *got = NULL;
    unsigned n;

    /* the adder: sorted, an overlap refused, nothing merged into it */
    T( mmap_add_fixed_only_area( (void *)0x7100000000, 0x1000000 ) );
    T( !mmap_add_fixed_only_area( (void *)0x7100800000, 0x1000000 ) && !mmap_add_fixed_only_area( (void *)0x70ffff0000, 0x20000 ) );
    mmap_add_reserved_area( (void *)0x7101000000, 0x100000 );            /* adjacent above: its own area, the zone unchanged */
    mmap_add_reserved_area( (void *)0x70fff00000, 0x100000 );            /* adjacent below */
    T( n_areas() == 3 && area_at( (void *)0x7100000000 )->size == 0x1000000 && area_at( (void *)0x7100000000 )->fixed_only );
    T( !area_at( (void *)0x7101000000 )->fixed_only && !area_at( (void *)0x70fff00000 )->fixed_only );
    mmap_remove_reserved_area( (void *)0x7100400000, 0x10000 );          /* a split keeps the kind on both halves */
    T( area_at( (void *)0x7100000000 )->fixed_only && area_at( (void *)0x7100410000 ) && area_at( (void *)0x7100410000 )->fixed_only );
    clear();

    /* a generic range that joins a generic area to a zone does not swallow the zone (the merge stops at it) */
    mmap_add_reserved_area( (void *)0x70f0000000, 0x10000000 );           /* generic, ends 0x7100000000 */
    T( mmap_add_fixed_only_area( (void *)0x7101000000, 0x1000000 ) );    /* the zone */
    mmap_add_reserved_area( (void *)0x7100000000, 0x1000000 );           /* the gap between them */
    T( n_areas() == 2 && area_at( (void *)0x70f0000000 )->size == 0x11000000 && !area_at( (void *)0x70f0000000 )->fixed_only );
    T( area_at( (void *)0x7101000000 ) && area_at( (void *)0x7101000000 )->fixed_only && area_at( (void *)0x7101000000 )->size == 0x1000000 );
    /* a generic range running over the zone: the generic area stops at the zone, the part above is its own area */
    mmap_add_reserved_area( (void *)0x70f8000000, 0x9800000 );            /* to 0x7101800000 ... */
    mmap_add_reserved_area( (void *)0x7100800000, 0x2000000 );            /* ... and on to 0x7102800000 */
    T( area_at( (void *)0x70f0000000 )->size == 0x11000000 && area_at( (void *)0x7101000000 )->size == 0x1000000 &&
       area_at( (void *)0x7101000000 )->fixed_only && area_at( (void *)0x7102000000 ) &&
       area_at( (void *)0x7102000000 )->size == 0x800000 && !area_at( (void *)0x7102000000 )->fixed_only && n_areas() == 3 );
    clear();

    /* the placement: ntdll (0x130000) at the bottom, the zone from its 64 KB-rounded end, the image part unmapped first */
    hole_lo = (char *)0x7050000000; hole_hi = (char *)0x71f5770000;
    setenv( "MADEIRA_X64_HOOK_ZONE", "1", 1 );
    T( ios_hook_zone_map_image( &view, 0x12f400, 0x1, 0x100000000, 0x73ffefffff, &child ) == STATUS_SUCCESS );
    T( view == &the_view && (char *)the_view.base + 0x130000 + (16 << 20) <= hole_hi && !((uintptr_t)the_view.base & 0xffff) );
    T( area_at( (char *)the_view.base + 0x130000 ) && area_at( (char *)the_view.base + 0x130000 )->fixed_only
       && area_at( (char *)the_view.base + 0x130000 )->size == 16 << 20 );
    T( n_unmap == 1 && unmapped[0] == the_view.base && unmapped_size[0] == 0x130000 );
    T( ios_hook_zone_find( ios_hook_zones, &child, NULL )->base == (ULONG_PTR)the_view.base + 0x130000 );
    T( strstr( last_log, "16 MB free above it for hook code" ) && strstr( last_log, "a 64-bit child" ) );
    /* FC64's search from ntdll+0x85a00 meets the rest of ntdll and then the zone */
    n = probe_upward( (char *)the_view.base + 0x85a00, &got );
    T( n && n <= (0x130000 - 0x85a00) / 0x1000 + 2 && got == (char *)the_view.base + 0x130000 );
    /* a zone left by an earlier process with the same PEB (its reclaim was missed) is released first: one record */
    {
        char *old = (char *)the_view.base + 0x130000;
        hole_hi = (char *)the_view.base;
        T( ios_hook_zone_map_image( &view, 0x12f400, 0x1, 0x100000000, 0x73ffefffff, &child ) == STATUS_SUCCESS );
        T( removed_base == old && !area_at( old ) && ios_hook_zone_find( ios_hook_zones, &child, NULL )->base == (ULONG_PTR)the_view.base + 0x130000 );
        for (n = 0; n < IOS_HOOK_ZONES && ios_hook_zones[n].used == (n == 0); n++);
        T( n == IOS_HOOK_ZONES );
        hole_hi = (char *)0x71f5770000;
    }
    /* the process ends: its record and area go */
    ios_hook_zone_owner_died( &child );
    T( removed_base == (char *)the_view.base + 0x130000 && !area_at( removed_base ) && !ios_hook_zone_find( ios_hook_zones, &child, NULL ) );
    clear();

    /* failures leave nothing behind and say so */
    free_fail = 1;
    T( ios_hook_zone_map_image( &view, 0x12f400, 0x1, 0x100000000, 0x73ffefffff, &child ) == STATUS_NO_MEMORY && !n_areas() && !n_unmap );
    T( strstr( last_log, "placed as before, without a hook zone" ) );
    clear(); view_fail = 1;
    T( ios_hook_zone_map_image( &view, 0x12f400, 0x1, 0x100000000, 0x73ffefffff, &child ) == STATUS_NO_MEMORY && !n_areas()
       && n_unmap == 2 && unmapped_size[1] == 16 << 20 && !ios_hook_zone_find( ios_hook_zones, &child, NULL ) );
    clear();
    /* the zone's place is already a reserved area: the view stays, no zone, the zone part unmapped */
    mmap_add_reserved_area( (void *)0x71f4600000, 0x2000000 );
    hole_lo = (char *)0x71f4600000; hole_hi = (char *)0x71f5770000;
    T( ios_hook_zone_map_image( &view, 0x12f400, 0x1, 0x100000000, 0x73ffefffff, &child ) == STATUS_SUCCESS && view == &the_view
       && n_areas() == 1 && !area_at( (void *)0x71f4600000 )->fixed_only && !ios_hook_zone_find( ios_hook_zones, &child, NULL ) );
    T( strstr( last_log, "the zone was not registered" ) );
    clear();
    /* off: only the exact value 1 turns it on */
    {
        static const char *const off[] = { NULL, "0", "", "11", "true", "16" };
        unsigned k;
        for (k = 0; k < sizeof(off) / sizeof(off[0]); k++)
        {
            if (off[k]) setenv( "MADEIRA_X64_HOOK_ZONE", off[k], 1 ); else unsetenv( "MADEIRA_X64_HOOK_ZONE" );
            T( ios_hook_zone_map_image( &view, 0x12f400, 0x1, 0x100000000, 0x73ffefffff, &child ) == STATUS_NOT_SUPPORTED && !n_unmap );
        }
    }
    puts( fails ? "FAILED" : "ok" );
    return fails != 0;
}
'''
peb_decl = ("static const void *ios_session_peb __attribute__((unused));\nstatic const void *cur_peb;\n"
            "static void *ios_jit_current_peb( void ) { return (void *)cur_peb; }\n")
code = FAKE + "\n".join(fns) + peb_decl + ZONES + "static void ios_hook_zone_owner_died( void *peb );\n" + zone_bytes + zone_map + zone_died + T2
with tempfile.TemporaryDirectory() as tmp:
    r, out = build_and_run(code, tmp, "fake")
    check("the adder, the merge, the split, the placement with its failures, FC64's probe, the release, the switch (ASan/UBSan)",
          r is not None and r.returncode == 0, out)

# ---------------------------------------------------------------- 4. the wiring
miv = cut(src, "static NTSTATUS map_image_view( struct file_view **view_ret, struct pe_image_info *image_info, SIZE_T size,")
check("map_image_view uses the request up on entry, only for a 64-bit image in its process",
      "int hook_zone = ios_hook_zone_pending && !wow_image;" in miv and "ios_hook_zone_pending = 0;" in miv
      and miv.index("ios_hook_zone_pending = 0;") < miv.index("if (wow_image)\n    {"))
ceil = "limit_high = ios_hook_zone_ceiling( limit_low, limit_high );"
ceil = "if (!wow_image) limit_high = ios_hook_zone_ceiling( limit_low, limit_high );"
check("the process's 64-bit images go below its zone, after their preferred base is tried unchanged",
      miv.count(ceil) == 1 and miv.index("ios_furniture_ceiling ? min(") < miv.index("/* first try the specified base */")
      < miv.index("    zone_high = limit_high;\n") < miv.index(ceil))
fallback = ("    status = map_view( view_ret, NULL, size, top_down ? MEM_TOP_DOWN : 0, vprot, limit_low, limit_high, 0 );\n"
            "    if (status && limit_high != zone_high)   /* x64-hook-zone: no room below the zone: anywhere, as before */\n"
            "        status = map_view( view_ret, NULL, size, top_down ? MEM_TOP_DOWN : 0, vprot, limit_low, zone_high, 0 );\n")
check("no room below the zone: the image is placed anywhere in the full range", miv.count(fallback) == 1 and
      miv.index(fallback) > miv.index("/* then any suitable address */"))
place = "if (hook_zone && !ios_hook_zone_map_image( view_ret, size, vprot, limit_low, limit_high, hook_zone_owner ))"
check("the ntdll is placed with its zone before its ordinary placement",
      miv.count(place) == 1 and miv.index(place) < miv.index("/* then some appropriate address range */"))
child = cut(ldr, "static int ios_load_child_ec_ntdll( PEB *child_peb )")
check("an x64 child's ntdll asks for a zone around its load, and only that load",
      re.search(r"ios_hook_zone_request\( 1, child_peb \);[^\n]*\n\s+status = open_builtin_pe_file\( name, &attr, &module, &size, &info, 0, 0,\n"
                r"\s+IMAGE_FILE_MACHINE_AMD64, FALSE, 0 \);\n\s+ios_hook_zone_request\( 0, NULL \);", child) is not None)
main = cut(ldr, "static void load_ntdll(void)")
check("the session's ntdll asks only for a 64-bit main program",
      "ios_hook_zone_request( !ios_main_image_i386, NULL );" in main and main.count("ios_hook_zone_request( 0, NULL );") == 1
      and main.index("ios_hook_zone_request( !ios_main_image_i386, NULL );") < main.index("status = open_builtin_pe_file(") < main.index("ios_hook_zone_request( 0, NULL );"))
check("nothing else asks", ldr.count("ios_hook_zone_request(") == 5 and src.count("ios_hook_zone_request(") == 1)
rec = cut(src, "void ios_jit_reclaim_process( void *peb )")
check("a process that ends (or is ended) gives its zone back", "ios_hook_zone_owner_died( peb );" in rec
      and rec.index("ios_hook_zone_owner_died( peb );") < rec.index("if (!peb || !rx_base) return;"))
check("the switch is read at each ntdll mapping, so it is the session's own", src.count('getenv( "MADEIRA_X64_HOOK_ZONE" )') == 1)
check("the calling process's zone is looked up with the session's own PEB, not the global peb (the last child booted)",
      src.count("ios_hook_zone_find( ios_hook_zones, cur, ios_session_peb )") == 1 and "ios_hook_zones, cur, peb )" not in src)
gen = (root / "build/tools/gen-config-catalog.py").read_text()
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
bridge = (root / "app/Madeira/WineProcessBridge.m").read_text()
check("the session end clears the switch; the catalog documents it, off by default",
      'unsetenv("MADEIRA_X64_HOOK_ZONE");' in bridge
      and re.search(r'"env\.MADEIRA_X64_HOOK_ZONE": \{[^}]*"default": "0"', gen, re.S) is not None
      and 'key: "env.MADEIRA_X64_HOOK_ZONE"' in cat)
print("PASS: x64 hook zone" if ok else "FAILED: x64 hook zone")
sys.exit(0 if ok else 1)
