#!/usr/bin/env python3
"""Lazy WoW64 guest windows (virtual_ios.c); no Wine runs.

Compiles the production guest-window registry and placement code against a fake address map
(stubbed task_info / mach_vm_region / fixed mmap) and checks:
  - a 64-bit-only session reserves nothing at virtual_init: no mmap, no TASK_VM_INFO query,
    not armed, and map_view's top-down bias never consults the candidate slot;
  - a 32-bit main image published by the app arms the session and reserves exactly ONE window
    ahead of time, which the main thread then adopts without another mapping;
  - on a 63 GB map each 32-bit process gets exactly one window, at most two are alive at once,
    and a third is refused cleanly with STATUS_NO_MEMORY;
  - an exited process's window is reused by the next 32-bit process without a new mapping;
  - a 40 GB map refuses the first window cleanly;
  - MADEIRA_WOW_PLACEHOLDERS=1 restores ahead-of-time placeholders (bounded on a small map);
  - once armed, the top-down bias keeps furniture below the free candidate slot.
Also checks the call sites: virtual_init only calls ios_wow_session_start, and map_view skips
all window code when the session has no window, no placeholder and is not armed.
"""
from pathlib import Path
import os, re, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/virtual_ios.c").read_text()
a = src.index("/* ==== WoW64 guest windows: registry and placement ==== */")
b = src.index("/* ==== end of WoW64 guest windows ==== */")
block = src[a:b]
# the 32-bit image-ceiling policy lives in the same block but needs Wine's image types
if " *           ios_laa_forced / ios_wow_ceiling_for_charact" in block:
    la = block.index("/***********************************************************************\n *           ios_laa_forced")
    lb = block.index("/* Clamp [*start, *end) off the reserved slot [wb, we).")
    block = block[:la] + block[lb:]

# ---- call-site invariants
init = src[src.index("void virtual_init(void)\n{"):]
init = init[:init.index("\n}\n")]
assert re.findall(r"ios_wow_\w+\(", init) == ["ios_wow_session_start("], "virtual_init reserves nothing itself"
mv = src[src.index("static NTSTATUS map_view( struct file_view **view_ret, void *base, size_t size,"):]
mv = mv[:mv.index("\ndone:\n")]
assert "if ((ios_wow_window_count || ios_wow_placeholder_count) &&\n            !ios_wow_limits_in_window( limit_low, limit_high ))" in mv
assert "if (top_down && ceiling_relaxable) end = ios_wow_bias_end( start, end );" in mv
assert "ios_wow_candidate_slot(" not in mv, "map_view reaches the candidate slot only through ios_wow_bias_end"
bias = block[block.index("static void *ios_wow_bias_end("):]
bias = bias[:bias.index("\n}\n")]
assert bias.index("if (!ios_wow_session_armed()) return end;") < bias.index("ios_wow_candidate_slot()")
print("PASS: virtual_init and map_view only reach the window code through the lazy gates")

harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <pthread.h>
#include <time.h>
#include <sys/mman.h>
typedef int BOOL;   /* this fork: ios_wow_force_exec_set_current */
unsigned long long ios_layerkit_lo, ios_layerkit_hi;   /* this fork: the measured CoreAnimation span */
typedef uintptr_t ULONG_PTR; typedef unsigned int ULONG; typedef int NTSTATUS; typedef struct { int x; } PEB;
#define STATUS_SUCCESS 0
#define STATUS_NO_MEMORY ((NTSTATUS)0xc0000017)
#define PtrToUlong(p) ((ULONG)(ULONG_PTR)(p))
typedef int kern_return_t; typedef unsigned int mach_msg_type_number_t; typedef int task_t; typedef int *task_info_t;
/* Darwin's pthread headers already declare this port as unsigned int. */
typedef uint64_t mach_vm_address_t, mach_vm_size_t; typedef unsigned int mach_port_t; typedef int *vm_region_info_t;
typedef struct { int protection; } vm_region_basic_info_data_64_t;
#define KERN_SUCCESS 0
#define TASK_VM_INFO 22
#define TASK_VM_INFO_COUNT 1
#define VM_REGION_BASIC_INFO_64 9
#define VM_REGION_BASIC_INFO_COUNT_64 1
#define VM_PROT_NONE 0
#define MACH_PORT_NULL 0
typedef struct { unsigned long long max_address; } task_vm_info_data_t;
#define IOS_WOW_WINDOW_SIZE ((ULONG_PTR)1 << 32)
#define IOS_CAGE_BASE      0x7200000000ULL
#define IOS_CAGE_REAL_SIZE 0x1ffff0000ULL
#define ERR(...) fprintf( stderr, __VA_ARGS__ )
#define dprintf(fd, ...) fprintf( stderr, __VA_ARGS__ )

/* ---- fake address map: sorted, non-overlapping regions */
struct region { ULONG_PTR lo, hi; int prot; };
static struct region map[256]; static int nmap;
static unsigned long long fake_max;
static int mmap_calls, task_info_calls;
static int ios_cage_holdback_live, ios_cage_window_tail_live;
static const ULONG_PTR host_page_size = 0x4000;
static ULONG_PTR ios_usable_va_floor = 0x7038000000ULL, ios_furniture_ceiling = 0x73ffff0000ULL;
static void *user_space_limit = (void *)0x7fffffff0000ULL;
static void add_region( ULONG_PTR lo, ULONG_PTR hi, int prot ) {
    int i = 0, j;
    while (i < nmap && map[i].lo < lo) i++;
    for (j = nmap; j > i; j--) map[j] = map[j - 1];
    map[i].lo = lo; map[i].hi = hi; map[i].prot = prot; nmap++;
}
static int overlaps( ULONG_PTR lo, ULONG_PTR hi ) {
    int i; for (i = 0; i < nmap; i++) if (map[i].lo < hi && lo < map[i].hi) return 1; return 0; }
static task_t mach_task_self( void ) { return 1; }
static kern_return_t task_info( task_t t, int flavor, task_info_t out, mach_msg_type_number_t *cnt ) {
    (void)t; (void)flavor; (void)cnt; task_info_calls++;
    ((task_vm_info_data_t *)out)->max_address = fake_max; return KERN_SUCCESS; }
static kern_return_t mach_vm_region( task_t t, mach_vm_address_t *a, mach_vm_size_t *s, int f, vm_region_info_t info,
                                     mach_msg_type_number_t *c, mach_port_t *o ) {
    int i; (void)t; (void)f; (void)c; (void)o;
    for (i = 0; i < nmap; i++) if (map[i].hi > *a) {
        if (*a < map[i].lo) *a = map[i].lo;
        *s = map[i].hi - *a; ((vm_region_basic_info_data_64_t *)info)->protection = map[i].prot; return KERN_SUCCESS; }
    return 1; }
static void *anon_mmap_tryfixed( void *start, size_t size, int prot, int flags ) {
    ULONG_PTR lo = (ULONG_PTR)start, hi = lo + size; (void)flags;
    if (hi > fake_max || overlaps( lo, hi )) { errno = EEXIST; return MAP_FAILED; }
    mmap_calls++; add_region( lo, hi, prot ); return start; }
static void *anon_mmap_fixed( void *start, size_t size, int prot, int flags ) {
    ULONG_PTR lo = (ULONG_PTR)start; (void)flags; mmap_calls++;
    if (!overlaps( lo, lo + size )) add_region( lo, lo + size, prot );
    return start; }
/* The split guard fallback may acquire and release a temporary page. Model
 * that release instead of calling the real host munmap on a fake address;
 * new_mappings counts reservations left standing after each attempt. */
static int fake_munmap( void *addr, size_t size ) {
    int i;
    for (i = 0; i < nmap; i++)
        if (map[i].lo == (ULONG_PTR)addr && map[i].hi == (ULONG_PTR)addr + size) {
            memmove( &map[i], &map[i + 1], (nmap - i - 1) * sizeof(map[0]) );
            nmap--; mmap_calls--; return 0;
        }
    errno = EINVAL; return -1;
}
#define munmap fake_munmap
static int reserved_areas;
static void mmap_add_reserved_area( void *addr, size_t size ) { (void)addr; (void)size; reserved_areas++; }
static void ios_va_describe_range( void *addr, ULONG_PTR len, char *buf, size_t n ) { (void)addr; (void)len; snprintf( buf, n, "-" ); }
static void *ios_jit_current_peb( void ) { return NULL; }
""" + block + r"""
static int teardowns;
int ios_thread_registry_range_busy( uintptr_t base, uintptr_t size ) { (void)base; (void)size; return 0; }
/* [wow-reap] (signal_arm64_ios.c): no leftover threads here, so a refused reservation is not retried */
int ios_thread_registry_end_dead_range( uintptr_t base, uintptr_t size, void *dead_peb, int *kept )
{ (void)base; (void)size; (void)dead_peb; *kept = 0; return 0; }
static int ios_wow_window_teardown( ULONG_PTR base, void *dead_peb, unsigned guard_owned )
{ (void)base; (void)dead_peb; (void)guard_owned; teardowns++; return 1; }

static NTSTATUS last_status; static ULONG_PTR last_base;
static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static int done, quit;
static void *proc( void *arg ) {                /* one 32-bit pseudo-process boot thread */
    int release = arg != NULL; ULONG_PTR b;
    last_status = ios_wow_window_reserve();
    b = ios_wow_base();
    if (!last_status) {
        int before = mmap_calls;
        if (ios_wow_window_reserve() || ios_wow_base() != b || mmap_calls != before) { puts( "not idempotent" ); exit( 3 ); }
    }
    last_base = b;
    if (release) ios_wow_window_release_current();
    pthread_mutex_lock( &gate ); done = 1; pthread_cond_broadcast( &cond );
    while (!quit) pthread_cond_wait( &cond, &gate );          /* the process lives on: its */
    pthread_mutex_unlock( &gate );                            /* pthread_t is never reused */
    return NULL; }
static void run_proc( int release ) {
    pthread_t t;
    done = 0;
    pthread_create( &t, NULL, proc, release ? (void *)1 : NULL );
    pthread_mutex_lock( &gate ); while (!done) pthread_cond_wait( &cond, &gate ); pthread_mutex_unlock( &gate ); }

int main( int argc, char **argv ) {
    const char *mode = argv[1];
    fake_max = strtoull( argv[2], NULL, 0 );
    add_region( 0x100000000ULL, 0x300000000ULL, 1 );          /* image, malloc zones, shared cache */
    add_region( 0x7000000000ULL, 0x7038000000ULL, 1 );        /* JIT pool RW alias */
    if (fake_max > IOS_CAGE_BASE + IOS_CAGE_REAL_SIZE && strcmp( mode, "bias" )) { add_region( IOS_CAGE_BASE, IOS_CAGE_BASE + IOS_CAGE_REAL_SIZE, 0 ); ios_cage_holdback_live = 1; }
    if (!strcmp( mode, "main-i386" )) ios_main_image_i386 = 1;
    ios_wow_session_start();                                   /* the virtual_init hook */
    printf( "start armed=%d mmap=%d taskinfo=%d windows=%u placeholders=%u\n", ios_wow_session_armed(),
            mmap_calls, task_info_calls, ios_wow_window_count, ios_wow_placeholder_count );
    if (!strcmp( mode, "64bit" )) {
        void *end = ios_wow_bias_end( (void *)0x7038000000ULL, (void *)0x73ffff0000ULL );
        printf( "bias end=%llx taskinfo=%d base=%llx\n", (unsigned long long)(ULONG_PTR)end, task_info_calls,
                (unsigned long long)ios_wow_base() );
        return 0;
    }
    if (!strcmp( mode, "procs" )) {
        int i, n = atoi( argv[3] );
        for (i = 0; i < n; i++) {
            int before = mmap_calls;
            run_proc( argc > 4 && atoi( argv[4] ) == i );
            printf( "proc%d status=%x base=%llx new_mappings=%d\n", i, (unsigned)last_status,
                    (unsigned long long)last_base, mmap_calls - before );
        }
        printf( "teardowns=%d\n", teardowns );
        return 0;
    }
    if (!strcmp( mode, "main-i386" )) {
        int before = mmap_calls;
        run_proc( 0 );
        printf( "main status=%x base=%llx new_mappings=%d\n", (unsigned)last_status, (unsigned long long)last_base,
                mmap_calls - before );
        return 0;
    }
    if (!strcmp( mode, "bias" )) {
        void *end;
        run_proc( 0 );                                          /* arms, takes the lowest slot */
        end = ios_wow_bias_end( (void *)0x7038000000ULL, (void *)0x73ffff0000ULL );
        printf( "bias end=%llx\n", (unsigned long long)(ULONG_PTR)end );
        return 0;
    }
    return 2;
}
"""

def run(exe, *args, env=None):
    e = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}
    e.update(env or {})
    out = subprocess.run([str(exe), *args], env=e, capture_output=True, text=True, timeout=120)
    assert out.returncode == 0, out.stdout + out.stderr
    return out.stdout, out.stderr

BIG, TABLET, SMALL = "0x8000000000", "0xfc0000000", "0xa00000000"
with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "lazy.c"; c.write_text(harness)
    exe = Path(t) / "lazy"
    subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wno-unused-function", "-Wno-unused-variable",
                    "-Wno-unused-but-set-variable", "-pthread", "-fsanitize=address,undefined",
                    str(c), "-o", str(exe)], check=True)

    for m in (BIG, TABLET):
        out, err = run(exe, "64bit", m)
        assert "start armed=0 mmap=0 taskinfo=0 windows=0 placeholders=0" in out, out + err
        assert "bias end=73ffff0000 taskinfo=0 base=0" in out, out
        assert "[wow-window]" not in err, err
    print("PASS: a 64-bit-only session reserves nothing, asks nothing and biases nothing (512 GB and 63 GB maps)")

    out, err = run(exe, "main-i386", BIG)
    assert "start armed=1 mmap=1 taskinfo=1 windows=0 placeholders=1" in out, out + err
    assert re.search(r"main status=0 base=7100000000 new_mappings=0", out), out + err
    print("PASS: a published 32-bit main image reserves exactly one window at virtual_init, then adopts it")

    out, err = run(exe, "procs", TABLET, "3")
    assert re.search(r"proc0 status=0 base=[4-9a]00000000 new_mappings=1\n", out), out + err
    assert re.search(r"proc1 status=0 base=[4-9a]00000000 new_mappings=1\n", out), out + err
    assert "proc2 status=c0000017 base=0 new_mappings=0" in out, out + err
    assert "refused: map too small" in err, err
    print("PASS: 63 GB map: one window per 32-bit process, at most two alive, the third refused cleanly")

    out, err = run(exe, "procs", TABLET, "3", "0")
    b0 = re.search(r"proc0 status=0 base=(\w+) new_mappings=1\n", out)
    b1 = re.search(r"proc1 status=0 base=(\w+) new_mappings=0\n", out)
    assert b0 and b1 and b0.group(1) == b1.group(1), out + err
    assert re.search(r"proc2 status=0 base=[4-9a]00000000 new_mappings=1\n", out), out + err
    assert "teardowns=1" in out, out
    print("PASS: an exited process's window is torn down and reused by the next one without a new mapping")

    out, err = run(exe, "procs", SMALL, "1")
    assert "proc0 status=c0000017 base=0 new_mappings=0" in out and "refused: map too small" in err, out + err
    print("PASS: 40 GB map: the first window is refused cleanly")

    out, err = run(exe, "64bit", TABLET, env={"MADEIRA_WOW_PLACEHOLDERS": "1"})
    assert "start armed=1 mmap=2 taskinfo=1 windows=0 placeholders=2" in out, out + err
    out, err = run(exe, "64bit", BIG, env={"MADEIRA_WOW_PLACEHOLDERS": "1"})
    assert "start armed=1" in out and "placeholders=1" in out, out + err   # 0x72 is the holdback
    print("PASS: MADEIRA_WOW_PLACEHOLDERS=1 restores ahead-of-time placeholders, bounded on a small map")

    out, err = run(exe, "bias", BIG)      # no holdback: 0x71 is taken by the first process, 0x72 is the candidate
    assert "bias end=7200000000" in out, out + err
    print("PASS: once armed, top-down furniture is kept below the free candidate slot")
