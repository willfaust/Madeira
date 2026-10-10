#!/usr/bin/env python3
"""TlsFree clears a TLS slot only in the calling process (build/ntdll-unix/virtual_ios.c); no Wine runs.

TlsAlloc takes an index from the calling process's own PEB bitmap, and TlsFree
asks ntdll (ThreadZeroTlsCell) to zero that slot in the process's threads. Every
pseudo-process here is a thread group in one Mach task, so teb_list holds all of
their TEBs, and virtual_clear_tls_index zeroed the index in every one of them. A
short-lived child that freed index N (a Chromium GPU-info process unloading
wined3d) wiped another process's live value at N (the browser's V8 isolate slot),
which then crashed on a null pointer.

Compiles the production virtual_clear_tls_index with a model of teb_list (64-bit
TEBs, and WoW64 TEBs whose expansion slots sit in a guest window) and checks:
  - a slot below 64 freed in one process is cleared in every thread of that
    process and in no other process, and no other slot changes;
  - the same for expansion slots (index 64 and up), WoW64 and native; a thread
    without expansion slots is skipped;
  - an index past the expansion bitmap is refused without touching anything;
  - every call enters and leaves the virtual_mutex section once.
Needs python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
virtual = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
thread = (root / 'build/ntdll-unix/thread_ios.c').read_text()
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]


clear = function(virtual, 'NTSTATUS virtual_clear_tls_index( ULONG index )')
require('case ThreadZeroTlsCell:\n        if (handle == GetCurrentThread())' in thread,
        'ThreadZeroTlsCell only runs for the calling thread, so NtCurrentTeb() names the process')

harness = r'''
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#define WINE_IOS 1
#define _WIN64 1
typedef unsigned int ULONG;
typedef uintptr_t ULONG_PTR;
typedef int NTSTATUS;
#define STATUS_SUCCESS           ((NTSTATUS)0)
#define STATUS_INVALID_PARAMETER ((NTSTATUS)0xC000000D)
#define TLS_MINIMUM_AVAILABLE 64
#define CONTAINING_RECORD(address, type, field) ((type *)((char *)(address) - offsetof(type, field)))

struct list { struct list *next, *prev; };
#define LIST_FOR_EACH_ENTRY(elem, list, type, field) \
    for ((elem) = CONTAINING_RECORD((list)->next, type, field); &(elem)->field != (list); \
         (elem) = CONTAINING_RECORD((elem)->field.next, type, field))

struct ntdll_thread_data { struct list entry; };   /* kept in TEB.GdiTebBatch */
typedef struct { ULONG TlsExpansionBitmapBits[32]; } PEB;
typedef struct
{
    PEB *Peb;
    void *TlsSlots[64];
    void **TlsExpansionSlots;
    long WowTebOffset;
    union { struct ntdll_thread_data data; char pad[64]; } GdiTebBatch;
} TEB;
typedef struct { ULONG TlsSlots[64]; ULONG TlsExpansionSlots; } WOW_TEB;

#define IOS_WOW_WINDOW_SIZE 0x100000000ull
struct ios_wow_window { ULONG_PTR base; };

PEB *peb;
static struct list teb_list = { &teb_list, &teb_list };
static pthread_mutex_t virtual_mutex = PTHREAD_MUTEX_INITIALIZER;
static TEB *current_teb;
static int section_depth, section_entries;
static struct ios_wow_window window;

static TEB *NtCurrentTeb(void) { return current_teb; }
static WOW_TEB *get_wow_teb( TEB *teb )
{
    return teb->WowTebOffset ? (WOW_TEB *)((char *)teb + teb->WowTebOffset) : NULL;
}
static struct ios_wow_window *ios_wow_slot_at_base( ULONG_PTR base ) { (void)base; return &window; }
static void server_enter_uninterrupted_section( pthread_mutex_t *mutex, sigset_t *sigset )
{
    (void)sigset;
    pthread_mutex_lock( mutex );
    section_depth++;
    section_entries++;
}
static void server_leave_uninterrupted_section( pthread_mutex_t *mutex, sigset_t *sigset )
{
    (void)sigset;
    section_depth--;
    pthread_mutex_unlock( mutex );
}
'''

harness_main = r'''
struct thread { TEB teb; WOW_TEB wow; void *expansion[1024]; };
static struct thread threads[8];
static ULONG guest[8][1024];   /* WoW64 expansion slots, inside the guest window */
static int nthreads, bad;

static void check( int ok, const char *label ) { printf( "%s: %s\n", ok ? "PASS" : "FAIL", label ); bad |= !ok; }

static TEB *add_thread( PEB *owner, int wow )
{
    struct thread *t = &threads[nthreads];
    int i;

    t->teb.Peb = owner;
    for (i = 0; i < 64; i++)
    {
        t->teb.TlsSlots[i] = (void *)(ULONG_PTR)(0x1000 + i);
        t->wow.TlsSlots[i] = 0x2000 + i;
    }
    if (wow)
    {
        t->teb.WowTebOffset = offsetof(struct thread, wow) - offsetof(struct thread, teb);
        t->wow.TlsExpansionSlots = (ULONG)((ULONG_PTR)guest[nthreads] - window.base);
        for (i = 0; i < 1024; i++) guest[nthreads][i] = 0x3000 + i;
    }
    else
    {
        t->teb.TlsExpansionSlots = t->expansion;
        for (i = 0; i < 1024; i++) t->expansion[i] = (void *)(ULONG_PTR)(0x4000 + i);
    }
    t->teb.GdiTebBatch.data.entry.next = teb_list.next;
    t->teb.GdiTebBatch.data.entry.prev = &teb_list;
    teb_list.next->prev = &t->teb.GdiTebBatch.data.entry;
    teb_list.next = &t->teb.GdiTebBatch.data.entry;
    nthreads++;
    return &t->teb;
}

static ULONG wow_slot( TEB *teb, int i ) { return get_wow_teb( teb )->TlsSlots[i]; }
static ULONG wow_exp( TEB *teb, int i ) { return ((ULONG *)(window.base + get_wow_teb( teb )->TlsExpansionSlots))[i]; }
static ULONG_PTR slot64( TEB *teb, int i ) { return (ULONG_PTR)teb->TlsSlots[i]; }
static ULONG_PTR exp64( TEB *teb, int i ) { return (ULONG_PTR)teb->TlsExpansionSlots[i]; }
static NTSTATUS tls_free_from( TEB *caller, ULONG index )
{
    current_teb = caller;
    return virtual_clear_tls_index( index );
}

int main( void )
{
    PEB browser, gpu_child, app64;
    TEB *a1, *a2, *b1, *c1, *c2;
    int entries;

    window.base = (ULONG_PTR)guest - 0x10000;
    a1 = add_thread( &browser, 1 );     /* 32-bit browser, two threads */
    a2 = add_thread( &browser, 1 );
    b1 = add_thread( &gpu_child, 1 );   /* its short-lived 32-bit child */
    c1 = add_thread( &app64, 0 );       /* a 64-bit process */
    c2 = add_thread( &app64, 0 );
    c2->TlsExpansionSlots = NULL;

    check( tls_free_from( b1, 5 ) == STATUS_SUCCESS && wow_slot( b1, 5 ) == 0, "the child frees slot 5: its own slot is cleared" );
    check( wow_slot( a1, 5 ) == 0x2005 && wow_slot( a2, 5 ) == 0x2005, "the child frees slot 5: the browser keeps its value" );
    check( slot64( c1, 5 ) == 0x1005 && slot64( c2, 5 ) == 0x1005, "the child frees slot 5: the 64-bit process keeps its value" );
    check( wow_slot( b1, 4 ) == 0x2004 && wow_slot( b1, 6 ) == 0x2006, "the child frees slot 5: its other slots are kept" );

    check( tls_free_from( a2, 9 ) == STATUS_SUCCESS && wow_slot( a1, 9 ) == 0 && wow_slot( a2, 9 ) == 0,
           "the browser frees slot 9 from one thread: cleared in all of its threads" );
    check( wow_slot( b1, 9 ) == 0x2009 && slot64( c1, 9 ) == 0x1009, "the browser frees slot 9: no other process changes" );

    check( tls_free_from( c2, 7 ) == STATUS_SUCCESS && slot64( c1, 7 ) == 0 && slot64( c2, 7 ) == 0,
           "a 64-bit process frees slot 7: cleared in all of its threads" );
    check( wow_slot( a1, 7 ) == 0x2007 && wow_slot( b1, 7 ) == 0x2007, "a 64-bit process frees slot 7: the 32-bit processes keep theirs" );

    check( tls_free_from( a1, 64 + 3 ) == STATUS_SUCCESS && wow_exp( a1, 3 ) == 0 && wow_exp( a2, 3 ) == 0,
           "the browser frees expansion slot 3: cleared in its threads, through the guest window" );
    check( wow_exp( b1, 3 ) == 0x3003 && exp64( c1, 3 ) == 0x4003, "expansion slot 3: no other process changes" );

    check( tls_free_from( c1, 64 + 1023 ) == STATUS_SUCCESS && exp64( c1, 1023 ) == 0,
           "a 64-bit process frees the last expansion slot; its thread without expansion slots is skipped" );
    check( wow_exp( a1, 1023 ) == 0x3000 + 1023 && wow_exp( b1, 1023 ) == 0x3000 + 1023,
           "the last expansion slot: the 32-bit processes keep theirs" );

    entries = section_entries;
    check( tls_free_from( b1, 64 + 1024 ) == STATUS_INVALID_PARAMETER && section_entries == entries &&
           wow_exp( b1, 0 ) == 0x3000 && wow_slot( b1, 0 ) == 0x2000,
           "an index past the expansion bitmap is refused and nothing is touched" );
    check( section_entries == 5 && section_depth == 0, "every call enters and leaves the virtual_mutex section once" );
    return bad;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-tls-clear-') as directory:
    folder = Path(directory)
    source = folder / 'check.c'
    source.write_text(harness + clear + harness_main)
    executable = folder / 'check'
    cc = os.environ.get('CC', 'cc')
    flags = [cc, '-std=gnu11', '-Wall', '-Wextra', '-Wno-unused-function', '-Werror', '-g', '-pthread',
             str(source), '-o', str(executable)]
    sanitize = ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    build = subprocess.run(flags[:1] + sanitize + flags[1:], capture_output=True, text=True)
    if build.returncode == 0:
        print('built with AddressSanitizer/UBSan')
    else:
        build = subprocess.run(flags, capture_output=True, text=True)
        print('built without sanitizers' if build.returncode == 0 else build.stderr[-4000:])
    require(build.returncode == 0, 'harness compiles')
    if build.returncode == 0:
        run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=60)
        print(run.stdout, end='')
        require(run.returncode == 0, 'every runtime check passed, no sanitizer report')
        if run.returncode:
            print(run.stderr[-4000:])

print('PASS' if not failures else f'FAILED ({failures})')
sys.exit(1 if failures else 0)
