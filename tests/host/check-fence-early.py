#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Ported from a community host check; anchors are the merged engine code's.
"""fence-early (madeira-d3d12, opt-in): a fence advances when the GPU reached its batch.

A 64-bit D3D12 title polls its fences about 25 times a frame. After the GPU
reached a batch's serial, the fence worker waited in waitUntilCompleted for
each command buffer before it advanced the fence. Under iOS's CPU clamp that
took 2-5 ms per job, 85-130 ms a frame, and fps tracked it.
With fence-early = 1, a job without query results advances its fence right
after the event, and its command buffers retire on a second thread.

Checks:
  - the fence-early code (mad_fence_early_on, mad_vis_job_pending,
    mad_retire_worker, mad_retire_defer and the fence worker's retire block),
    cut out of madeira_d3d12.c and run on the host with real threads, where a
    command buffer takes 20 ms to retire:
      - off: every job retires its buffers, then advances its fence (the old
        order), and no thread is created;
      - on: fences advance at once, in order, while the buffers retire on the
        second thread in commit order;
      - a job whose buffer carries query results, upload-guard, or a ring with
        no room takes the old order;
      - teardown drains the ring before the thread exits;
  - the off path is the old code; the worker stops the retire thread after the
    fence thread; the [perf] line; the key in the settings catalog (when present).
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
src = (R / "madeira-d3d12/src/pe/madeira_d3d12.c").read_text()
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok = ok and bool(cond)


def function(signature):
    start = src.index(signature)
    return src[start:src.index('\n}\n', start) + 3] + '\n'


early_on = function("static int mad_fence_early_on(void) {")
vis_pending = function("static int mad_vis_job_pending(struct mad_device *d, const obj_handle_t *cbs, unsigned ncbs) {")
worker = function("static DWORD WINAPI mad_retire_worker(void *arg) {")
defer = function("static int mad_retire_defer(struct mad_device *d, const obj_handle_t *cbs, unsigned ncbs) {")
fw = function("static DWORD WINAPI mad_fence_worker(void *arg) {")
b0 = fw.index("        {   /* ml1109: from \"GPU reached the serial\" to \"fence advanced\" = our retire overhead */")
b1 = fw.index("        ID3D12Fence_Release(job.fence);", b0)
block = fw[b0:b1]

check("the key is read once, default 0",
      'long long v = mad_cfg_int_pe("fence-early", 0);' in early_on and "if (g_fence_early < 0) {" in early_on)
# The upload-guard line may carry a trailing comment; only the code is anchored.
# The old-order branch comes first: its condition is the negation of the fence-early one.
old_cond = re.search(re.escape("            if (!mad_fence_early_on() || g_upload_guard || mad_vis_job_pending(d, job.cbs, job.ncbs) ||\n"
                               "                !mad_retire_defer(d, job.cbs, job.ncbs)) {")
                     + r"[ \t]*(?:/\*[^\n]*?\*/)?[ \t]*\n", block)
check("off: the old order, as before (retire every buffer, upload-guard, then the fence)",
      old_cond is not None and
      re.match(re.escape("                for (k = 0; k < job.ncbs; k++) mad_cb_retire(d, job.cbs[k]);\n"
                         "                if (g_upload_guard) mad_ug_verify(d, job.serial);")
               + r"[ \t]*(?:/\*[^\n]*?\*/)?[ \t]*\n"
               + re.escape("                ID3D12Fence_Signal(job.fence, job.value);\n"), block[old_cond.end():]) is not None)
check("on: only without upload-guard and query results, and only when the ring took the buffers",
      old_cond is not None and
      re.match(r"[^\n]*\n[^\n]*\n[^\n]*\n[^\n]*\n" + re.escape("            } else {")
               + r"[ \t]*(?:/\*[^\n]*?\*/)?[ \t]*\n"
               + re.escape("                ID3D12Fence_Signal(job.fence, job.value);\n"
                           "                InterlockedIncrement(&g_fe_early);\n"), block[old_cond.end():]) is not None)
rel = function("static ULONG STDMETHODCALLTYPE device_Release(ID3D12Device *This) {")
check("teardown stops the retire thread after the fence thread",
      rel.index("if (d->fence_thread) {") < rel.index("if (d->retire_thread) {") and
      "InterlockedExchange(&d->retire_quit, 1);" in rel)
check("the [perf] line counts early and old-order fences", '"[perf] fence-early: %ld fences advanced when the GPU reached them' in src)

cc = shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
if not cc:
    print("SKIP host run: no C compiler")
else:
    harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
typedef long LONG; typedef unsigned long DWORD; typedef uint64_t UINT64; typedef int64_t LONG64;
typedef uint64_t obj_handle_t;
#define WINAPI
#define INFINITE 0xffffffffu
typedef struct { pthread_mutex_t m; } CRITICAL_SECTION;
static void EnterCriticalSection( CRITICAL_SECTION *c ) { pthread_mutex_lock( &c->m ); }
static void LeaveCriticalSection( CRITICAL_SECTION *c ) { pthread_mutex_unlock( &c->m ); }
struct ev { pthread_mutex_t m; pthread_cond_t c; int set; };
typedef struct ev *HANDLE_EV;
typedef void *HANDLE;
static HANDLE CreateEventW( void *a, int manual, int init, void *n )
{
    struct ev *e = calloc( 1, sizeof *e );
    pthread_mutex_init( &e->m, NULL ); pthread_cond_init( &e->c, NULL ); e->set = init;
    return e;
}
static int SetEvent( HANDLE h )
{
    struct ev *e = h;
    pthread_mutex_lock( &e->m ); e->set = 1; pthread_cond_signal( &e->c ); pthread_mutex_unlock( &e->m );
    return 1;
}
struct th { pthread_t t; DWORD (*fn)(void *); void *arg; int done; struct ev *e; };
static int n_threads;
static void *th_main( void *p ) { struct th *t = p; t->fn( t->arg ); t->done = 1; return NULL; }
static HANDLE CreateThread( void *a, size_t s, DWORD (*fn)(void *), void *arg, DWORD f, void *id )
{
    struct th *t = calloc( 1, sizeof *t );
    t->fn = fn; t->arg = arg; n_threads++;
    pthread_create( &t->t, NULL, th_main, t );
    return t;
}
static DWORD WaitForSingleObject( HANDLE h, DWORD ms )
{
    struct ev *e = h;
    pthread_mutex_lock( &e->m );
    while (!e->set) pthread_cond_wait( &e->c, &e->m );
    e->set = 0;
    pthread_mutex_unlock( &e->m );
    return 0;
}
static void join_thread( HANDLE h ) { pthread_join( ((struct th *)h)->t, NULL ); }
static LONG InterlockedIncrement( volatile LONG *p ) { return __atomic_add_fetch( p, 1, __ATOMIC_SEQ_CST ); }
static LONG InterlockedExchange( volatile LONG *p, LONG v ) { return __atomic_exchange_n( p, v, __ATOMIC_SEQ_CST ); }
static LONG64 InterlockedExchangeAdd64( volatile LONG64 *p, LONG64 v ) { return __atomic_fetch_add( p, v, __ATOMIC_SEQ_CST ); }
#define FALSE 0
static volatile LONG64 g_perf_sig_lat_ticks;
static volatile LONG g_perf_sig_lat_n;
typedef struct { int64_t QuadPart; } LARGE_INTEGER;
static void QueryPerformanceCounter( LARGE_INTEGER *t ) { t->QuadPart = 0; }

static double now_ms( void ) { struct timespec ts; clock_gettime( CLOCK_MONOTONIC, &ts ); return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6; }

struct mad_vis_batch { obj_handle_t cb; };
struct mad_device {
    CRITICAL_SECTION fence_lock, vis_lock;
    struct mad_vis_batch **vis_pending; unsigned nvis_pending;
    obj_handle_t retire_q[256]; unsigned retire_head, nretire;
    HANDLE retire_wake, retire_thread;
    volatile LONG retire_quit;
};
typedef struct { UINT64 serial; void *fence; UINT64 value; obj_handle_t cbs[16]; unsigned ncbs; } fjob;

static int g_upload_guard;
static int cfg_fence_early;
static long long mad_cfg_int_pe( const char *k, long long def ) { return strcmp( k, "fence-early" ) ? def : cfg_fence_early; }
static void d3d12_log( const char *fmt, ... ) { }

/* the record of what happened, in order */
static pthread_mutex_t rec_m = PTHREAD_MUTEX_INITIALIZER;
static struct { char kind; UINT64 v; double t; int on_worker; } rec[4096];
static int nrec;
static __thread int on_worker;
static void note( char kind, UINT64 v )
{
    pthread_mutex_lock( &rec_m );
    rec[nrec].kind = kind; rec[nrec].v = v; rec[nrec].t = now_ms(); rec[nrec].on_worker = on_worker; nrec++;
    pthread_mutex_unlock( &rec_m );
}
static int retire_ms = 20;
static void mad_cb_retire( struct mad_device *d, obj_handle_t cb ) { usleep( retire_ms * 1000 ); note( 'r', cb ); }
static void mad_ug_verify( struct mad_device *d, UINT64 serial ) { note( 'u', serial ); }
#define ID3D12Fence_Signal( f, v ) note( 's', (v) )
static volatile LONG g_fe_early, g_fe_inline;
static volatile int g_fence_early = -1;
''' + early_on + vis_pending + worker.replace("    for (;;) {", "    on_worker = 1;\n    for (;;) {", 1) + defer + r'''
static void process_job( struct mad_device *d, fjob job )
{
    unsigned k;
''' + block + r'''
}
static int fails;
static void fail( const char *w ) { printf( "FAIL %s\n", w ); fails++; }
static struct mad_device *new_dev( void )
{
    struct mad_device *d = calloc( 1, sizeof *d );
    pthread_mutex_init( &d->fence_lock.m, NULL ); pthread_mutex_init( &d->vis_lock.m, NULL );
    return d;
}
static void stop( struct mad_device *d )
{
    if (!d->retire_thread) return;
    InterlockedExchange( &d->retire_quit, 1 );
    SetEvent( d->retire_wake );
    join_thread( d->retire_thread );
}
static fjob job_of( UINT64 value, obj_handle_t first, unsigned n )
{
    fjob j; unsigned k;
    memset( &j, 0, sizeof j ); j.serial = value; j.value = value; j.ncbs = n;
    for (k = 0; k < n; k++) j.cbs[k] = first + k;
    return j;
}
static int idx( char kind, UINT64 v ) { int i; for (i = 0; i < nrec; i++) if (rec[i].kind == kind && rec[i].v == v) return i; return -1; }

int main( void )
{
    struct mad_device *d;
    int i;

    /* off: retire, then signal, on the calling thread; no retire thread */
    cfg_fence_early = 0; g_fence_early = -1; nrec = 0; n_threads = 0;
    d = new_dev();
    process_job( d, job_of( 1, 100, 2 ) );
    process_job( d, job_of( 2, 102, 1 ) );
    if (nrec != 5 || rec[0].kind != 'r' || rec[0].v != 100 || rec[1].v != 101 || rec[2].kind != 's' || rec[2].v != 1 ||
        rec[3].v != 102 || rec[4].kind != 's' || rec[4].v != 2) fail( "off: retire every buffer, then the fence, in order" );
    if (n_threads || d->retire_thread) fail( "off: no retire thread" );
    if (g_fe_early || g_fe_inline) fail( "off: no fence-early counts" );

    /* on: three jobs of two buffers; the fences advance at once and in order,
     * the buffers retire on the second thread in commit order */
    cfg_fence_early = 1; g_fence_early = -1; nrec = 0; n_threads = 0;
    d = new_dev();
    {
        double t0 = now_ms();
        process_job( d, job_of( 1, 200, 2 ) );
        process_job( d, job_of( 2, 202, 2 ) );
        process_job( d, job_of( 3, 204, 2 ) );
        if (now_ms() - t0 > 30) fail( "on: the fence worker does not wait for the retires" );
    }
    if (idx( 's', 1 ) != 0 || idx( 's', 2 ) != 1 || idx( 's', 3 ) != 2) fail( "on: fences advance first, in order" );
    stop( d );
    for (i = 0; i < 6; i++)
        if (rec[3 + i].kind != 'r' || rec[3 + i].v != (UINT64)(200 + i) || !rec[3 + i].on_worker)
            fail( "on: buffers retire on the retire thread, in commit order" );
    if (n_threads != 1) fail( "on: one retire thread" );
    if (g_fe_early != 3) fail( "on: three early fences counted" );

    /* on, but a buffer of the job carries query results: the old order */
    nrec = 0; g_fe_early = g_fe_inline = 0;
    d = new_dev();
    {
        struct mad_vis_batch vb = { 301 }, *pv = &vb;
        d->vis_pending = &pv; d->nvis_pending = 1;
        process_job( d, job_of( 7, 300, 2 ) );
        if (nrec != 3 || rec[0].v != 300 || rec[1].v != 301 || rec[2].kind != 's' || rec[0].on_worker)
            fail( "query results: retire inline, then the fence" );
        d->nvis_pending = 0;
        process_job( d, job_of( 8, 302, 1 ) );   /* the next job without queries goes early again */
        stop( d );
        if (idx( 's', 8 ) != 3 || g_fe_inline != 1 || g_fe_early != 1) fail( "query results: only that job takes the old order" );
    }

    /* upload-guard: the old order, with the verify before the fence */
    nrec = 0; g_upload_guard = 1;
    d = new_dev();
    process_job( d, job_of( 9, 400, 1 ) );
    if (nrec != 3 || rec[0].kind != 'r' || rec[1].kind != 'u' || rec[2].kind != 's') fail( "upload-guard: retire, verify, then the fence" );
    if (d->retire_thread) fail( "upload-guard: no retire thread" );
    g_upload_guard = 0;

    /* a ring with no room for the whole job: the old order, nothing lost */
    nrec = 0; retire_ms = 0;
    d = new_dev();
    process_job( d, job_of( 10, 500, 1 ) );   /* creates the thread */
    stop( d );
    nrec = 0;
    d->retire_quit = 0; d->retire_thread = NULL;
    d->nretire = 250; d->retire_head = 0;   /* 250 of 256 taken: a 16-buffer job does not fit */
    for (i = 0; i < 250; i++) d->retire_q[i] = 1000 + i;
    retire_ms = 1;
    {
        HANDLE t = d->retire_thread;
        d->retire_thread = (HANDLE)1;   /* pretend the thread exists, so nothing drains the ring yet */
        process_job( d, job_of( 11, 600, 16 ) );
        d->retire_thread = t;
    }
    if (nrec != 17 || rec[16].kind != 's' || rec[0].v != 600) fail( "a full ring: the job retires inline, then the fence" );

    /* teardown drains the ring */
    cfg_fence_early = 1; nrec = 0; retire_ms = 2;
    d = new_dev();
    for (i = 0; i < 20; i++) process_job( d, job_of( 20 + i, 700 + 4 * i, 4 ) );
    stop( d );
    {
        int r = 0;
        for (i = 0; i < nrec; i++) if (rec[i].kind == 'r') r++;
        if (r != 80) { printf( "  retired %d of 80\n", r ); fail( "teardown: all 80 buffers retired before the thread exits" ); }
    }
    printf( "%s\n", fails ? "HARNESS FAILED" : "harness ok" );
    return fails != 0;
}
'''
    with tempfile.TemporaryDirectory() as tmp:
        c = os.path.join(tmp, "t.c")
        exe = os.path.join(tmp, "t")
        open(c, "w").write(harness)
        b = subprocess.run([cc, "-std=gnu11", "-O1", "-Wall", "-Werror", "-Wno-unused-function", "-Wno-unused-variable",
                            "-Wno-int-conversion", "-Wno-incompatible-pointer-types", "-pthread", "-o", exe, c],
                           capture_output=True, text=True)
        check("the fence-early code builds on the host", b.returncode == 0)
        if b.returncode:
            print(b.stderr[-3000:])
        else:
            r = subprocess.run([exe], capture_output=True, text=True, timeout=120)
            print(r.stdout.strip())
            check("off: the old order; on: fences first, buffers retired in order on the retire thread; "
                  "query results, upload-guard and a full ring keep the old order; teardown drains the ring",
                  r.returncode == 0)

catalog = R / "app/Madeira/ConfigCatalog.generated.swift"
if catalog.exists():
    check("the settings catalog lists fence-early (default 0)", 'ConfigOption(key: "fence-early"' in catalog.read_text())

print("PASS: fence-early" if ok else "FAILED: fence-early")
sys.exit(0 if ok else 1)
