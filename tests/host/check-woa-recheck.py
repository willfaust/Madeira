#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Russell Barton
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""env.MADEIRA_WOA_RECHECK = 1 (wine dlls/ntdll/sync.c and unix/sync.c): an infinite RtlWaitOnAddress re-checks its entry every second.

A waker removes the waiter's queue entry and then alerts the thread; an alert that never arrives leaves the waiter asleep for
good, which stalls Ubisoft Connect's 32-bit browser (upc.exe) on SRW locks that are free. With the switch an infinite wait
runs in one-second slices and ends (a spurious wake-up) once it finds its entry removed.

Checks:
  1. the wine pin has every fragment of the change, the PE ones inside RtlWaitOnAddress, the unix ones inside
     NtWaitForAlertByThreadId;
  2. RtlWaitOnAddress cut from the patched wine/dlls/ntdll/sync.c with the helper, the queue code and compare_addr, compiled
     with -Wall -Wextra -Werror and under ASan + UBSan, against a scripted NtWaitForAlertByThreadId: an infinite wait passes
     exactly the slice (-10000001); a wake returns STATUS_SUCCESS silently; a lost alert (entry removed, the slice times out)
     returns STATUS_SUCCESS after one slice and logs "dequeued"; a changed value without a wake, or a genuine wait, keeps
     waiting slice after slice until woken, silently; a timed wait passes the caller's timeout once and returns
     STATUS_TIMEOUT with its entry out of the queue; a value that differs on entry returns at once; at most 32 log lines;
  3. the unix registry lines (patched NtWaitForAlertByThreadId) in a harness: the slices of one park keep its start and count
     as infinite, another address or a non-slice wait starts a new park; only "1" turns the switch on, otherwise a slice is
     waited out as the infinite wait it stands for; read at each slice;
  4. the PE change is only compiled for __i386__; the catalog documents the key (off by default), the session end clears it.
Not covered: why the iOS alert path loses an alert (each rescue logs a [woa-rescue] line).
Needs the wine submodule checked out and `cc` on PATH.
"""
from pathlib import Path
import importlib.util, os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
# The fragments of the change in the pinned wine tree (dlls/ntdll/sync.c, i386 only, and unix/sync.c).
PE_HEAD = """/***********************************************************************
 *           RtlWaitOnAddress   (NTDLL.@)
 */
NTSTATUS WINAPI RtlWaitOnAddress( const void *addr, const void *cmp, SIZE_T size,
                                  const LARGE_INTEGER *timeout )
{"""

PE_HELPER = """#ifdef __i386__
/* Madeira woa-recheck: an infinite wait on an address waits in one-second slices
 * (MADEIRA_WOA_SLICE, which the unix side recognises: unless env.MADEIRA_WOA_RECHECK is 1 it waits the infinite wait the
 * slice stands for). After each slice the waiter looks at its own entry under the queue's spinlock: removed by a waker
 * whose alert never came ends the wait with STATUS_SUCCESS (a spurious wake-up, which every caller handles); otherwise it
 * waits again. */
#define MADEIRA_WOA_SLICE (-10000001)
static NTSTATUS madeira_woa_wait( struct futex_queue *queue, struct futex_entry *entry, const void *addr, SIZE_T size )
{
    static LONG logged;
    LARGE_INTEGER slice;
    unsigned int seconds = 0;
    BOOL dequeued;
    NTSTATUS ret;

    slice.QuadPart = MADEIRA_WOA_SLICE;
    for (;;)
    {
        ret = NtWaitForAlertByThreadId( addr, &slice );
        if (ret != STATUS_TIMEOUT) return ret;
        seconds++;
        spin_lock( &queue->lock );
        dequeued = !entry->addr;
        spin_unlock( &queue->lock );
        if (dequeued)
        {
            if (InterlockedIncrement( &logged ) <= 32)
                ERR( "[woa-rescue] tid=%04lx addr=%p size=%Iu after %u s: dequeued, no alert within the slice\\n",
                     (unsigned long)GetCurrentThreadId(), addr, size, seconds );
            return STATUS_SUCCESS;
        }
    }
}
#endif

"""

PE_WAIT_NEW = """#ifdef __i386__
    if (!timeout) ret = madeira_woa_wait( queue, &entry, addr, size );   /* woa-recheck */
    else
#endif
    ret = NtWaitForAlertByThreadId( addr, timeout );
"""

# ---------------------------------------------------------------- unix side: wine/dlls/ntdll/unix/sync.c
UX_FIELD_NEW = """    ULONGLONG since;    /* NtQuerySystemTime at park entry */
    int inf;            /* 1 = INFINITE wait */
    const void *slice;  /* woa-recheck: the address whose slice just timed out (the park goes on) */
} ios_alert_waiters[IOS_ALERT_WAITER_MAX];
"""

UX_HEAD = """NTSTATUS WINAPI NtWaitForAlertByThreadId( const void *address, const LARGE_INTEGER *timeout )
{"""

UX_HELPER = """/* Madeira woa-recheck: the 32-bit ntdll's RtlWaitOnAddress waits an infinite
 * wait out in slices of exactly MADEIRA_WOA_SLICE, re-checking its queue entry after each. With
 * env.MADEIRA_WOA_RECHECK = 1 the slices of one park keep its [waiters] start time and count as infinite; otherwise a
 * slice is waited out as the infinite wait it stands for (the old behaviour). Read at each slice. */
#define MADEIRA_WOA_SLICE (-10000001)
static int madeira_woa_recheck(void)
{
    const char *e = getenv( "MADEIRA_WOA_RECHECK" );

    return e && e[0] == '1' && !e[1];
}

"""

UX_NORM_NEW = """        int ios_wslot;
        int ios_woa_slice = timeout && timeout->QuadPart == MADEIRA_WOA_SLICE;   /* woa-recheck */

        if (ios_woa_slice && !madeira_woa_recheck())
        {
            timeout = NULL;   /* woa-recheck not on: the infinite wait the slice stands for */
            ios_woa_slice = 0;
        }
        if (timeout)
        {
            if (timeout->QuadPart == TIMEOUT_INFINITE)
                timeout = NULL;
            else
                end = get_absolute_timeout( timeout );
        }
"""

UX_REG_NEW = """            /* woa-recheck: the next slice of the same park keeps its start and counts as infinite */
            if (!ios_woa_slice || ios_alert_waiters[ios_wslot].slice != (address ? address : (const void *)0x1))
                ios_alert_waiters[ios_wslot].since = ios_wnow.QuadPart;
            ios_alert_waiters[ios_wslot].inf = !timeout || ios_woa_slice;
            ios_alert_waiters[ios_wslot].slice = NULL;
            ios_alert_waiters[ios_wslot].addr = address ? address : (const void *)0x1;
"""

UX_TIMEOUT_NEW = """            if (ret == -1 && errno == ETIMEDOUT)
            {
                if (ios_wslot >= 0)
                {
                    /* woa-recheck: a slice that timed out leaves its park open for the next slice */
                    ios_alert_waiters[ios_wslot].slice = ios_woa_slice ? ios_alert_waiters[ios_wslot].addr : NULL;
                    ios_alert_waiters[ios_wslot].addr = NULL;
                }
"""



pe_path, ux_path = root / "wine/dlls/ntdll/sync.c", root / "wine/dlls/ntdll/unix/sync.c"
for p in (pe_path, ux_path):
    if not p.is_file():
        print(f"FAIL: {p.relative_to(root)} missing (check out the wine submodule)")
        sys.exit(1)
cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
ok = True


def check(what, cond, detail=""):
    global ok
    print(("PASS: " if cond else "FAIL: ") + what + (("\n      " + str(detail)[:2000]) if detail and not cond else ""))
    ok = ok and bool(cond)


pe, ux = pe_path.read_text(), ux_path.read_text()
check("the wine pin has every fragment of the change (PE helper and call, unix helper, registry field and hunks)",
      all(f in pe for f in (PE_HELPER, PE_WAIT_NEW)) and all(f in ux for f in (UX_HELPER, UX_FIELD_NEW, UX_NORM_NEW, UX_REG_NEW, UX_TIMEOUT_NEW)))


def cut(text, start, end="\n}\n"):
    at = text.index(start)
    return text[at:text.index(end, at) + len(end)]


# ---------------------------------------------------------------- 2. the PE side
fn = cut(pe, PE_HEAD)
helper = pe[pe.index(PE_HELPER):pe.index(PE_HELPER) + len(PE_HELPER)]
check("the PE helper and the call are only compiled for __i386__ (the 32-bit ntdll this build compiles)",
      helper.startswith("#ifdef __i386__\n") and helper.rstrip().endswith("#endif") and PE_WAIT_NEW.startswith("#ifdef __i386__\n")
      and PE_WAIT_NEW in fn and fn.count("NtWaitForAlertByThreadId") == 1)
structs = cut(pe, "struct futex_entry\n{", "\n};\n") + cut(pe, "struct futex_queue\n{", "\n};\n")
spin = cut(pe, "static void spin_lock( LONG *lock )") + cut(pe, "static void spin_unlock( LONG *lock )")
cmpf = cut(pe, "static BOOL compare_addr( const void *addr, const void *cmp, SIZE_T size )")
# the harness stands in for the i386 build; the host printf has %zu where Wine's debug printf has %Iu
i386 = lambda t: t.replace("#ifdef __i386__", "#if 1   /* the harness stands in for the i386 build */").replace("%Iu", "%zu")

HEAD = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef int32_t NTSTATUS, LONG; typedef uint32_t DWORD, ULONG; typedef unsigned char UCHAR; typedef unsigned short USHORT;
typedef uint64_t ULONG64; typedef int64_t LONGLONG; typedef size_t SIZE_T; typedef uintptr_t ULONG_PTR; typedef int BOOL;
typedef union { struct { DWORD LowPart; LONG HighPart; } u; LONGLONG QuadPart; } LARGE_INTEGER;
#define WINAPI
#define TRUE 1
#define FALSE 0
#define STATUS_SUCCESS ((NTSTATUS)0)
#define STATUS_TIMEOUT ((NTSTATUS)0x102)
#define STATUS_ALERTED ((NTSTATUS)0x101)
#define STATUS_INVALID_PARAMETER ((NTSTATUS)0xc000000d)
struct list { struct list *next, *prev; };
static void list_init( struct list *l ) { l->next = l->prev = l; }
static void list_add_tail( struct list *l, struct list *e ) { e->next = l; e->prev = l->prev; l->prev->next = e; l->prev = e; }
static void list_remove( struct list *e ) { e->next->prev = e->prev; e->prev->next = e->next; }
#define InterlockedCompareExchange(p, x, c) __sync_val_compare_and_swap( (p), (c), (x) )
#define InterlockedExchange(p, x) __sync_lock_test_and_set( (p), (x) )
#define InterlockedIncrement(p) __sync_add_and_fetch( (p), 1 )
#define InterlockedIncrement64(p) __sync_add_and_fetch( (p), 1 )
#define YieldProcessor() do { } while (0)
#define TRACE(...) do { } while (0)
#include <stdarg.h>
/* Wine's debug printf: not format-checked against host types (Madeira's own diagnostic lines in RtlWaitOnAddress use Wine's
 * LONG sizes; they only run for marked threads, never here) */
static int n_log; static char last_log[256];
static void err_log( const char *fmt, ... ) { va_list a; va_start( a, fmt ); vsnprintf( last_log, sizeof(last_log), fmt, a ); va_end( a ); n_log++; fputs( last_log, stderr ); }
#define ERR(...) err_log( __VA_ARGS__ )
static const char *debugstr_timeout( const LARGE_INTEGER *t ) { return t ? "fin" : "INF"; }
static DWORD GetCurrentThreadId( void ) { return 0x58; }
static struct { void *Instrumentation[16]; struct { void *UniqueThread; } ClientId; } teb;
#define NtCurrentTeb() (&teb)
'''
HEAD += r'''
static struct { long long woa_waits; } ios_xp_nt;
static int ios_sync_lean;   /* Madeira's lean-sync gate for the counters (ml1131): off, the counter is kept */
static const void *ios_pump_wait_addr, *ios_pump_wait_queue;
static void ios_srw_dump_park( const void *a ) { (void)a; }
'''
QUEUE = r'''
static struct futex_queue the_queue, futex_queues[1];
static struct futex_queue *get_futex_queue( const void *addr ) { (void)addr; return &the_queue; }
'''
TESTS = r'''
/* the scripted NtWaitForAlertByThreadId: what the "kernel" does at each call */
enum { WAKE, LOST, CHANGE, SLEEP };
static int script[64], n_calls; static LONGLONG seen[64]; static const LARGE_INTEGER *seen_ptr[64];
static ULONG word;
static void dequeue_all( void )   /* RtlWakeAddressAll's removal, without the alert */
{
    struct list *e = the_queue.queue.next;
    while (e != &the_queue.queue) { struct list *n = e->next; ((struct futex_entry *)e)->addr = NULL; list_remove( e ); e = n; }
}
NTSTATUS NtWaitForAlertByThreadId( const void *addr, const LARGE_INTEGER *timeout )
{
    int i = n_calls++;
    (void)addr;
    seen[i] = timeout ? timeout->QuadPart : 0; seen_ptr[i] = timeout;
    if (i >= 60) abort();   /* a wait that never ends */
    switch (script[i])
    {
    case WAKE: dequeue_all(); return STATUS_ALERTED;
    case LOST: dequeue_all(); return STATUS_TIMEOUT;
    case CHANGE: word++; return STATUS_TIMEOUT;
    default: return STATUS_TIMEOUT;
    }
}
static int fails;
#define T(c) do { if (!(c)) { printf( "FAIL line %d: %s\n", __LINE__, #c ); fails++; } } while (0)
static int queued( void ) { return the_queue.queue.next && the_queue.queue.next != &the_queue.queue; }
static void reset( const int *s, int n ) { int i; for (i = 0; i < 64; i++) script[i] = i < n ? s[i] : WAKE; n_calls = 0; n_log = 0; word = 7; last_log[0] = 0; }

int main( void )
{
    ULONG cmp = 7;
    LARGE_INTEGER t;
    int i;

    { static const int s[] = { WAKE }; reset( s, 1 ); }
    T( RtlWaitOnAddress( &word, &cmp, 4, NULL ) == STATUS_SUCCESS && n_calls == 1 && seen[0] == -10000001 && !n_log && !queued() );
    { static const int s[] = { LOST }; reset( s, 1 ); }
    T( RtlWaitOnAddress( &word, &cmp, 4, NULL ) == STATUS_SUCCESS && n_calls == 1 && n_log == 1 && strstr( last_log, "after 1 s: dequeued" ) && !queued() );
    { static const int s[] = { SLEEP, CHANGE, SLEEP, WAKE }; reset( s, 4 ); }
    T( RtlWaitOnAddress( &word, &cmp, 4, NULL ) == STATUS_SUCCESS && n_calls == 4 && !n_log && !queued() );
    { static const int s[] = { SLEEP, SLEEP, SLEEP, SLEEP, SLEEP, WAKE }; reset( s, 6 ); }
    T( RtlWaitOnAddress( &word, &cmp, 4, NULL ) == STATUS_SUCCESS && n_calls == 6 && !n_log && !queued() );
    for (i = 0; i < 6; i++) T( seen[i] == -10000001 );
    { static const int s[] = { SLEEP }; reset( s, 1 ); }
    t.QuadPart = -500000;
    T( RtlWaitOnAddress( &word, &cmp, 4, &t ) == STATUS_TIMEOUT && n_calls == 1 && seen_ptr[0] == &t && !n_log && !queued() );
    { static const int s[] = { WAKE }; reset( s, 1 ); }
    cmp = 8;
    T( RtlWaitOnAddress( &word, &cmp, 4, NULL ) == STATUS_SUCCESS && n_calls == 0 );
    cmp = 7;
    { static const int s[] = { LOST }; int total = 0; for (i = 0; i < 40; i++) { reset( s, 1 ); RtlWaitOnAddress( &word, &cmp, 4, NULL ); total += n_log; } T( total == 32 - 1 ); }   /* one line above, then 31 more: 32 per process */
    puts( fails ? "FAILED" : "ok" );
    return fails != 0;
}
'''


def build_and_run(src, tmp, name, sanitize):
    c, exe = Path(tmp) / f"{name}.c", Path(tmp) / name
    c.write_text(src)
    flags = [cc, "-std=gnu11", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-Wno-unused-parameter"]
    if sanitize:
        flags += ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-fno-omit-frame-pointer"]
    r = subprocess.run(flags + ["-o", str(exe), str(c)], capture_output=True, text=True)
    if r.returncode:
        return None, r.stderr
    try:
        p = subprocess.run([str(exe)], capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired as e:   # a hang is a failure too (a broken queue can loop forever instead of faulting)
        return subprocess.CompletedProcess(e.cmd, 124, "", "timed out after 20 s"), "timed out after 20 s"
    return p, p.stdout + p.stderr


pe_src = HEAD + structs + spin + cmpf + QUEUE + "NTSTATUS NtWaitForAlertByThreadId( const void *addr, const LARGE_INTEGER *timeout );\n" \
         + i386(helper) + i386(fn) + TESTS
with tempfile.TemporaryDirectory() as tmp:
    for label, san in (("strict (-Wall -Wextra -Werror)", False), ("AddressSanitizer + UndefinedBehaviorSanitizer", True)):
        r, out = build_and_run(pe_src, tmp, "pe_san" if san else "pe", san)
        check(f"RtlWaitOnAddress with the re-check compiles and behaves as documented, {label}", r is not None and r.returncode == 0, out)

# ---------------------------------------------------------------- 3. the unix registry
ux_fn = cut(ux, UX_HEAD)
check("the unix hunks are inside NtWaitForAlertByThreadId, the field in the registry struct",
      all(h in ux_fn for h in (UX_NORM_NEW, UX_REG_NEW, UX_TIMEOUT_NEW)) and UX_FIELD_NEW in ux)
UXH = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef int64_t LONGLONG; typedef uint64_t ULONGLONG;
typedef union { LONGLONG QuadPart; } LARGE_INTEGER;
#define TIMEOUT_INFINITE ((LONGLONG)0x7fffffffffffffff)
static struct { void *tid; const void *addr; ULONGLONG since; int inf; const void *slice; } ios_alert_waiters[4];
static LONGLONG clock_now;
static void NtQuerySystemTime( LARGE_INTEGER *t ) { t->QuadPart = clock_now; }
static ULONGLONG get_absolute_timeout( const LARGE_INTEGER *t ) { return (ULONGLONG)(clock_now - t->QuadPart); }
''' + UX_HELPER + r'''
/* one call of NtWaitForAlertByThreadId's registry part; timed_out: the wait ended by its timeout */
static void park( const void *address, const LARGE_INTEGER *timeout, int timed_out )
{
    ULONGLONG end = 0;
    int ios_wslot = 0;
''' + UX_NORM_NEW.replace("        int ios_wslot;\n", "") + r'''
    (void)end;
    {
        LARGE_INTEGER ios_wnow;
        NtQuerySystemTime( &ios_wnow );
''' + UX_REG_NEW + r'''
    }
    if (timed_out)
    {
        int ret = -1;
        if (ret == -1)
        {
            if (ios_wslot >= 0)
            {
                ios_alert_waiters[ios_wslot].slice = ios_woa_slice ? ios_alert_waiters[ios_wslot].addr : NULL;
                ios_alert_waiters[ios_wslot].addr = NULL;
            }
        }
    }
    else ios_alert_waiters[ios_wslot].addr = NULL;
}
static int fails;
#define T(c) do { if (!(c)) { printf( "FAIL line %d: %s\n", __LINE__, #c ); fails++; } } while (0)
int main( int argc, char **argv )
{
    LARGE_INTEGER slice = { -10000001 }, other = { -10000000 };
    static int a, b;

    if (argc > 1) { printf( "%d\n", madeira_woa_recheck() ); return 0; }
    setenv( "MADEIRA_WOA_RECHECK", "1", 1 );
    clock_now = 1000; park( &a, &slice, 1 );
    T( ios_alert_waiters[0].since == 1000 && ios_alert_waiters[0].inf == 1 && ios_alert_waiters[0].slice == &a );
    clock_now = 2000; park( &a, &slice, 1 );
    T( ios_alert_waiters[0].since == 1000 && ios_alert_waiters[0].inf == 1 );           /* the same park goes on */
    clock_now = 3000; park( &b, &slice, 1 );
    T( ios_alert_waiters[0].since == 3000 );                                             /* another address: a new park */
    clock_now = 4000; park( &b, &other, 1 );
    T( ios_alert_waiters[0].since == 4000 && ios_alert_waiters[0].inf == 0 && ios_alert_waiters[0].slice == NULL );   /* not a slice */
    clock_now = 5000; park( &b, &slice, 0 );
    T( ios_alert_waiters[0].slice == NULL && ios_alert_waiters[0].addr == NULL );      /* woken: nothing carried over */
    clock_now = 6000; park( &b, &slice, 1 );
    T( ios_alert_waiters[0].since == 6000 );
    puts( fails ? "FAILED" : "ok" );
    return fails != 0;
}
'''
with tempfile.TemporaryDirectory() as tmp:
    r, out = build_and_run(UXH, tmp, "ux", True)
    check("the slices of one park keep its start and count as infinite; another address or wait starts a new park", r is not None and r.returncode == 0, out)
    if r is not None and r.returncode == 0:
        exe = Path(tmp) / "ux"
        got = {}
        for val in (None, "", "1", "0", "11", "true"):
            env = dict(os.environ)
            env.pop("MADEIRA_WOA_RECHECK", None)
            if val is not None:
                env["MADEIRA_WOA_RECHECK"] = val
            got[val] = subprocess.run([str(exe), "switch"], capture_output=True, text=True, env=env).stdout.strip()
        check("the switch: only '1' turns it on", got == {None: "0", "": "0", "1": "1", "0": "0", "11": "0", "true": "0"}, got)
    off = UXH.replace('    setenv( "MADEIRA_WOA_RECHECK", "1", 1 );\n', "    (void)b; (void)other;\n    unsetenv( \"MADEIRA_WOA_RECHECK\" );\n")
    off = off.replace("T( ios_alert_waiters[0].since == 1000 && ios_alert_waiters[0].inf == 1 && ios_alert_waiters[0].slice == &a );",
                      "T( ios_alert_waiters[0].inf == 1 && ios_alert_waiters[0].slice == NULL );   /* off: the infinite wait */")
    r, out = build_and_run(off.split("    clock_now = 2000;")[0] + "    puts( fails ? \"FAILED\" : \"ok\" );\n    return fails != 0;\n}\n", tmp, "ux_off", True)
    check("the switch unset: a slice is waited out as an infinite wait (registered as infinite, no slice carried)",
          r is not None and r.returncode == 0, out)

# ---------------------------------------------------------------- 4. the catalog
gen = (root / "build/tools/gen-config-catalog.py").read_text()
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
bridge = (root / "app/Madeira/WineProcessBridge.m").read_text()
check("the catalog documents the key, off by default; the session end clears it",
      re.search(r'"env\.MADEIRA_WOA_RECHECK": \{[^}]*"default": "0"', gen, re.S) is not None and 'key: "env.MADEIRA_WOA_RECHECK"' in cat
      and 'unsetenv("MADEIRA_WOA_RECHECK");' in bridge)
print("PASS: woa-recheck" if ok else "FAILED: woa-recheck")
sys.exit(0 if ok else 1)
