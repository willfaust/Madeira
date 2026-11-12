#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Russell Barton
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""env.MADEIRA_SELF_WRITE (on unless exactly 0): a program's NtWriteVirtualMemory into its own memory is done in ntdll (virtual_ios.c).

The server writes with the target's task port, which iOS pseudo-processes do not have, so it refuses a program's
WriteProcessMemory into itself (Ubisoft Connect's and Far Cry 4's hooks). When the range is the program's own
(ios_self_write_in_reach), ios_self_write writes it page by page, as Windows does.

Checks:
  1. the production functions, cut by signature with the Wine helpers they call, compiled with -Wall -Wextra -Werror and run
     under ASan/UBSan over fake memory (4 KB pages in 16 KB host pages, a page aliased into the JIT pool, a pipe standing in
     for mach_vm_write so an unwritable page is an error, not a fault): pages written (writable, write-watched with the watch
     updated, aliased through the pool's RW view, PAGE_EXECUTE_READ once under this thread's last writable protect) and
     refused (read-only, also inside a host page a neighbour makes writable; guard; uncommitted); a partial count; a write
     stopped at its first page goes to the unchanged server request; the switch (only exactly "0" is off, read at each
     call); the reach (a 32-bit program: its window; a 64-bit program: an image view or its own hook zone, not another
     process's zone, other memory, a 32-bit window, a placeholder or a range longer than a window); the log (one line for
     each process's first write, then at most 16 for writes that stopped or used the protect record);
  2. the wiring: the branch precedes the unchanged server request, for the pseudo-handle only; NtProtectVirtualMemory notes a
     successful change of its own process; the server's port and write path; the catalog; the session end clears the switch.
Not covered: mach_vm_write and the real JIT pool, image and code-signing mappings; the emulator re-arming between
WriteProcessMemory's protect and its write, and running the new bytes after the flush; a neighbouring 4 KB page while its
16 KB host page is briefly writable.
Needs python3 and a C compiler.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/virtual_ios.c").read_text()
mach = (root / "build/wineserver/mach_ios.c").read_text()
cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
ok = True


def check(what, cond, detail=""):
    global ok
    print(("PASS: " if cond else "FAIL: ") + what + (("\n      " + str(detail)[-2500:]) if detail and not cond else ""))
    ok = ok and bool(cond)


def cut(text, start, end="\n}\n"):
    at = text.index(start)
    return text[at:text.index(end, at) + len(end)]


# ---------------------------------------------------------------- 1. the cut code, run
alias_a, alias_b = "#define IOS_JIT_MAX_ANON_ALIASES", "static volatile int ios_jit_anon_alias_count = 0;\n"
vprot = re.findall(r"^#define VPROT_(?:READ|WRITE|EXEC|WRITECOPY|GUARD|COMMITTED|WRITEWATCH) +0x[0-9a-fA-F]+$", src, re.M)
CUT = "\n".join(vprot + [
    src[src.index(alias_a):src.index(alias_b) + len(alias_b)],
    cut(src, "static int get_unix_prot( BYTE vprot )"),
    cut(src, "int ios_jit_anon_alias_find_cover(void *user_va, size_t size, void **rw_out, void **rx_out)"),
    cut(src, "uintptr_t ios_jit_anon_alias_lookup(uintptr_t fault_addr)"),
    cut(src, "static int mprotect_range_raw( void *base, size_t size, BYTE set, BYTE clear )"),
    cut(src, "static int mprotect_range( void *base, size_t size, BYTE set, BYTE clear )"),
    cut(src, "static void update_write_watches( void *base, size_t size, size_t accessed_size )"),
    cut(src, "static NTSTATUS check_write_access( void *base, size_t size, BOOL *has_write_watch )"),
    re.search(r"^#define IOS_HOOK_ZONES \d+$", src, re.M).group(0),
    cut(src, "struct ios_hook_zone\n{", "\n};\n"),
    cut(src, "static struct ios_hook_zone *ios_hook_zone_find( struct ios_hook_zone *t, const void *owner, const void *session_peb )"),
    cut(src, "static int ios_hook_zone_add( struct ios_hook_zone *t, const void *owner, ULONG_PTR base, ULONG_PTR size )"),
    "static struct ios_hook_zone ios_hook_zones[IOS_HOOK_ZONES];",
    cut(src, "static int ios_hook_zone_holds( const char *addr, SIZE_T size )"),
    cut(src, "static int ios_wow_addr_in_any_window( const void *addr )"),
    re.search(r"^static (?:__thread )?struct \{ ULONG_PTR begin, end; \} ios_self_write_grant;$", src, re.M).group(0),
    cut(src, "static int ios_self_write_enabled(void)"),
    cut(src, "static void ios_self_write_note_protect( const char *base, SIZE_T size, ULONG prot )"),
    cut(src, "static SIZE_T ios_self_write( char *dst, const char *src, SIZE_T size, unsigned *paths )"),
    cut(src, "static void ios_self_write_log( const char *dst, SIZE_T size, SIZE_T done, unsigned paths )"),
    cut(src, "static int ios_self_write_in_reach( const char *addr, SIZE_T size )"),
    cut(src, "NTSTATUS WINAPI NtWriteVirtualMemory( HANDLE process, void *addr, const void *buffer,"),
])
check("the functions, the protect record, the zone table and the seven VPROT bits are found", len(vprot) == 7)

# The fakes: G is 64 pages of 4 KB in 16 host pages of 16 KB, Wine's protection in vp[]; host page 8 (pages 32-35) is a file
# mapped read-only there and read/write at alias_rw, registered as aliased into the pool. A 32-bit program's window is pages 0-47;
# for a 64-bit program, all of G is one view (an image, or other memory), a 32-bit window lies at 48-63 and a placeholder at 16-31.
HEAD = r'''
#define _GNU_SOURCE
#define WINE_IOS 1
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
typedef unsigned char BYTE; typedef int BOOL; typedef size_t SIZE_T; typedef uint32_t ULONG; typedef uintptr_t ULONG_PTR, UINT_PTR;
typedef int32_t NTSTATUS; typedef void *HANDLE; typedef struct { int unused; } PEB;
typedef int kern_return_t; typedef unsigned mach_port_t; typedef uint64_t mach_vm_address_t, mach_vm_size_t; typedef uintptr_t vm_offset_t;
enum { FALSE, TRUE, PAGE_READONLY = 2, PAGE_READWRITE = 4, PAGE_WRITECOPY = 8, PAGE_EXECUTE_READ = 0x20, PAGE_EXECUTE_READWRITE = 0x40,
       PAGE_EXECUTE_WRITECOPY = 0x80, SEC_IMAGE = 0x1000000, PG = 0x1000, HPG = 0x4000, NPAGES = 64 };
#define WINAPI
#define STATUS_SUCCESS ((NTSTATUS)0)
#define STATUS_PARTIAL_COPY ((NTSTATUS)0x8000000D)
#define STATUS_ACCESS_DENIED ((NTSTATUS)0xC0000022)
#define STATUS_INVALID_USER_BUFFER ((NTSTATUS)0xC00000E8)
#define min(a,b) ((a) < (b) ? (a) : (b))
#define ROUND_ADDR(addr,mask) ((void *)((UINT_PTR)(addr) & ~(UINT_PTR)(mask)))
#define ROUND_SIZE(addr,size,mask) (((SIZE_T)(size) + ((UINT_PTR)(addr) & (mask)) + (mask)) & ~(UINT_PTR)(mask))
#define TRACE(...) do { } while (0)
#define HandleToULong(h) ((ULONG)(ULONG_PTR)(h))
#define NtCurrentProcess() ((HANDLE)~(ULONG_PTR)0)
#define NtCurrentTeb() (&teb)
#define IOS_WOW_WINDOW_SIZE ((ULONG_PTR)16 * PG)
static const UINT_PTR page_mask = PG - 1, host_page_size = HPG, host_page_mask = HPG - 1;
static char *G; static BYTE vp[NPAGES];
static pthread_mutex_t virtual_mutex, ios_pool_lock = PTHREAD_MUTEX_INITIALIZER;
static __thread int depth;
static int n_server; static uint64_t srv_addr; static SIZE_T srv_size;
static struct { struct { HANDLE UniqueProcess; } ClientId; } teb = { { (HANDLE)0x30 } };
static BYTE get_page_vprot( const void *a ) { ULONG_PTR o = (ULONG_PTR)a - (ULONG_PTR)G; return o < NPAGES * PG ? vp[o / PG] : 0; }
static BYTE get_host_page_vprot( const void *a )   /* the union of its four pages */
{
    const char *h = ROUND_ADDR( a, host_page_mask );
    return get_page_vprot( h ) | get_page_vprot( h + PG ) | get_page_vprot( h + 2 * PG ) | get_page_vprot( h + 3 * PG );
}
static void set_page_vprot_bits( void *base, size_t size, BYTE set, BYTE clear )
{
    ULONG_PTR o = (ULONG_PTR)base - (ULONG_PTR)G, e = o + size;
    for (o &= ~(ULONG_PTR)page_mask; o < e; o += PG) vp[o / PG] = (vp[o / PG] & ~clear) | set;
}
/* the pages are only read and written here, never run; a host may refuse write + execute */
static int mprotect_exec( void *base, size_t size, int prot ) { return mprotect( base, size, prot & ~PROT_EXEC ); }
void ios_watch_after_protect( const void *base, size_t size, const char *why ) { (void)base; (void)size; (void)why; }   /* ml1201's re-arm */
static void server_enter_uninterrupted_section( pthread_mutex_t *m, sigset_t *s ) { (void)s; pthread_mutex_lock( m ); depth++; }
static void server_leave_uninterrupted_section( pthread_mutex_t *m, sigset_t *s ) { (void)s; depth--; pthread_mutex_unlock( m ); }
static mach_port_t mach_task_self( void ) { return 1; }
static int kcopy( void *dst, const void *s, size_t len )   /* the kernel copies: an inaccessible page is EFAULT */
{
    int p[2], r = !pipe( p ) && write( p[1], s, len ) == (ssize_t)len && read( p[0], dst, len ) == (ssize_t)len;
    close( p[0] ); close( p[1] );
    return r ? 0 : 2;
}
static kern_return_t mach_vm_read_overwrite( mach_port_t t, mach_vm_address_t a, mach_vm_size_t n, mach_vm_address_t d,
                                             mach_vm_size_t *got )
{ (void)t; if (kcopy( (void *)(uintptr_t)d, (void *)(uintptr_t)a, n )) return 1; *got = n; return 0; }
static kern_return_t mach_vm_write( mach_port_t t, mach_vm_address_t a, vm_offset_t s, unsigned n )
{ (void)t; if (!depth) abort(); /* every store under virtual_mutex */ return kcopy( (void *)(uintptr_t)a, (void *)s, n ); }
static int virtual_check_buffer_for_read( const void *p, SIZE_T n ) { (void)p; (void)n; return 1; }
static int wow32 = 1, view_kind;   /* view_kind: 0 an image view, 1 other memory */
static ULONG_PTR ios_wow_base( void ) { return wow32 ? (ULONG_PTR)G : 0; }
static int ios_wow_in_window( const void *a ) { return wow32 && (const char *)a >= G && (const char *)a < G + 48 * PG; }
static struct { ULONG_PTR base; } ios_wow_windows[2], ios_wow_placeholders[2];
static unsigned ios_wow_window_count, ios_wow_placeholder_count;
struct file_view { void *base; size_t size; unsigned protect; };
static struct file_view *find_view( const void *a, size_t n )
{
    static struct file_view v;
    v.base = G; v.size = NPAGES * PG; v.protect = view_kind ? 0 : SEC_IMAGE;
    return (const char *)a >= G && (const char *)a + n <= G + NPAGES * PG ? &v : NULL;
}
static PEB pebs[2], *ios_session_peb __attribute__((unused)) = &pebs[0]; static void *cur_peb = &pebs[0];
static void *ios_jit_current_peb( void ) { return cur_peb; }
#define wine_server_obj_handle(h) ((unsigned)(ULONG_PTR)(h))
#define wine_server_client_ptr(p) ((uint64_t)(ULONG_PTR)(p))
#define wine_server_add_data(r,b,n) ((void)(b), srv_size = (n))
#define wine_server_call(r) (n_server++, srv_addr = (r)->addr, STATUS_ACCESS_DENIED)
#define SERVER_START_REQ(type) do { struct { unsigned handle; uint64_t addr; } req_s, *req = &req_s; \
                                    struct { SIZE_T written; } reply_s = { 0 }, *reply = &reply_s;
#define SERVER_END_REQ (void)req; } while (0)
'''

TESTS = r'''
static int fails;
#define T(c) do { if (!(c)) { printf( "FAIL line %d: %s\n", __LINE__, #c ); fails++; } } while (0)
#define P(i) (G + (i) * PG)
#define NOTE(page, prot) ios_self_write_note_protect( P(page), PG, prot )
enum { RW = VPROT_COMMITTED | VPROT_READ | VPROT_WRITE, RO = VPROT_COMMITTED | VPROT_READ,
       RX = VPROT_COMMITTED | VPROT_READ | VPROT_EXEC, RWX = RW | VPROT_EXEC };
static char *alias_rw; static unsigned char data[HPG], big[32 * PG];
static SIZE_T n; static unsigned paths;

static void host( int hp ) { mprotect_range( G + hp * HPG, HPG, 0, 0 ); }   /* host protection from vp[] */
static void layout( int first, int count, BYTE v )
{ memset( vp + first, v, count ); for (int i = first / 4; i <= (first + count - 1) / 4; i++) host( i ); }
static int writable( const void *a ) { unsigned char b = *(volatile const unsigned char *)a; return !kcopy( (void *)a, &b, 1 ); }
static SIZE_T sw( void *dst, SIZE_T len ) { return ios_self_write( dst, (char *)data, len, &paths ); }
static NTSTATUS nw( void *dst, SIZE_T len ) { n = 99; return NtWriteVirtualMemory( NtCurrentProcess(), dst, data, len, &n ); }
static void reset( void )   /* nothing recorded, every page 0x11 and inaccessible, no server request, no protect record */
{
    memset( vp, 0, sizeof(vp) ); n_server = 0; srv_addr = 0; srv_size = 0; ios_self_write_grant.begin = ios_self_write_grant.end = 0;
    mprotect( G, NPAGES * PG, PROT_READ | PROT_WRITE ); memset( G, 0x11, NPAGES * PG ); mprotect( G, NPAGES * PG, PROT_NONE );
}

static void test_pages( void )
{
    static const BYTE refused[] = { RO, RW | VPROT_GUARD, VPROT_READ | VPROT_WRITE /* uncommitted */, 0 };
    unsigned i;

    reset(); layout( 0, 4, RW );
    T( sw( P(0) + 0xff0, 0x20 ) == 0x20 && paths == 1 && !memcmp( P(0) + 0xff0, data, 0x20 ) );
    for (i = 0; i < sizeof(refused); i++) { reset(); layout( 0, 4, refused[i] ); T( sw( P(1), 4 ) == 0 && paths == 0 ); }
    reset(); vp[0] = vp[2] = vp[3] = RW; vp[1] = RO; host( 0 );   /* the host page is writable, the 4 KB page is not */
    T( writable( P(1) ) && sw( P(1), 4 ) == 0 && P(1)[0] == 0x11 );
    reset(); layout( 0, 4, RW ); layout( 4, 4, RO );              /* crossing into a refused page: a partial count */
    T( sw( P(3) + 0xffd, 8 ) == 3 && !memcmp( P(3) + 0xffd, data, 3 ) && P(4)[0] == 0x11 );
    reset(); vp[0] = vp[1] = RW | VPROT_WRITEWATCH; vp[2] = vp[3] = RW; host( 0 );
    T( !writable( P(1) ) && sw( P(1) + 8, 8 ) == 8 && paths == 1 && !memcmp( P(1) + 8, data, 8 ) );
    T( vp[1] == RW && vp[0] == (RW | VPROT_WRITEWATCH) && !writable( P(0) ) );   /* its watch reset, the other kept, re-armed */
    reset(); layout( 32, 4, RWX );                                 /* aliased, writable at the guest address: written there */
    T( writable( P(33) ) && sw( P(33) + 0x10, 0x30 ) == 0x30 && paths == 1 && !memcmp( alias_rw + PG + 0x10, data, 0x30 ) );
    reset(); layout( 32, 4, RWX ); mprotect( G + 8 * HPG, HPG, PROT_READ );   /* aliased, read-only at the guest address
                                                                                (a code-change trap): through the RW view */
    T( !writable( P(33) ) && sw( P(33) + 0x10, 0x30 ) == 0x30 && paths == 2 );
    T( !memcmp( alias_rw + PG + 0x10, data, 0x30 ) && !writable( P(33) ) );
    T( !depth && !pthread_mutex_trylock( &ios_pool_lock ) ); pthread_mutex_unlock( &ios_pool_lock );
}

static void *other_thread( void *arg ) { (void)arg; return (void *)(ULONG_PTR)sw( P(9), 5 ); }

static void test_record( void )
{
    pthread_t t; void *r;

    reset(); layout( 8, 4, RX );                                   /* PAGE_EXECUTE_READ: the emulator's re-armed trap */
    T( !writable( P(9) ) && sw( P(9) + 0xff0, 5 ) == 0 );                        /* no record */
    NOTE( 9, PAGE_EXECUTE_WRITECOPY ); NOTE( 9, PAGE_EXECUTE_READ );             /* WriteProcessMemory's protect, the re-arm, */
    NOTE( 8, PAGE_READONLY );                                                    /* another protect that is not writable */
    T( sw( P(9) + 0xff0, 5 ) == 5 && paths == 4 && !memcmp( P(9) + 0xff0, data, 5 ) );
    T( vp[9] == RX && !writable( P(9) ) && !depth );                            /* recorded and host protection back */
    T( sw( P(9) + 0xff0, 5 ) == 0 );                                             /* once per protect */
    NOTE( 9, PAGE_EXECUTE_READWRITE ); NOTE( 10, PAGE_READWRITE );
    T( sw( P(9), 5 ) == 0 );                                                     /* the last writable protect counts */
    NOTE( 9, PAGE_EXECUTE_READWRITE );
    T( sw( P(9) + 0xffe, 4 ) == 2 && P(10)[0] == 0x11 );                        /* its own pages only */
    reset(); layout( 8, 4, RO ); NOTE( 9, PAGE_EXECUTE_READWRITE );
    T( sw( P(9), 5 ) == 0 );                                                     /* never a read-only page */
    reset(); layout( 8, 4, RX ); NOTE( 9, PAGE_EXECUTE_READWRITE );
    pthread_create( &t, NULL, other_thread, NULL ); pthread_join( t, &r );
    T( r == NULL && sw( P(9), 5 ) == 5 );                                        /* this thread's record only */
}

static void test_nt32( void )
{
    reset(); layout( 0, 8, RW ); layout( 8, 4, RO ); layout( 44, 8, RW );
    T( nw( P(1), 16 ) == STATUS_SUCCESS && n == 16 && !n_server && !memcmp( P(1), data, 16 ) );
    T( nw( P(7) + 0xffc, 16 ) == STATUS_PARTIAL_COPY && n == 4 && !n_server );
    T( nw( P(9), 16 ) == STATUS_ACCESS_DENIED && n == 0 && n_server == 1 &&     /* stopped at its first page: the server */
       srv_addr == (uint64_t)(ULONG_PTR)P(9) && srv_size == 16 );
    T( NtWriteVirtualMemory( (HANDLE)0x44, P(2), data, 16, &n ) == STATUS_ACCESS_DENIED && n_server == 2 && P(2)[0] == 0x11 );
    T( nw( P(48), 16 ) == STATUS_ACCESS_DENIED && n_server == 3 && P(48)[0] == 0x11 );            /* outside its window */
    T( nw( P(47) + 0xff8, 16 ) == STATUS_ACCESS_DENIED && n_server == 4 && P(47)[0xff8] == 0x11 ); /* running out of it */
    T( nw( P(46), 16 ) == STATUS_SUCCESS && n_server == 4 );
}

static void test_switch( void )
{
    static const char *on[] = { NULL, "", "1", "yes", "00", "0 " };
    unsigned i;

    for (i = 0; i < sizeof(on) / sizeof(on[0]); i++)
    {
        (void)(on[i] ? setenv( "MADEIRA_SELF_WRITE", on[i], 1 ) : unsetenv( "MADEIRA_SELF_WRITE" ));
        T( ios_self_write_enabled() );
    }
    reset(); layout( 0, 8, RW );
    setenv( "MADEIRA_SELF_WRITE", "0", 1 );
    T( !ios_self_write_enabled() && nw( P(1), 16 ) == STATUS_ACCESS_DENIED && n_server == 1 && P(1)[0] == 0x11 );
    setenv( "MADEIRA_SELF_WRITE", "1", 1 );                       /* read at each call */
    T( nw( P(1), 16 ) == STATUS_SUCCESS && n_server == 1 );
    unsetenv( "MADEIRA_SELF_WRITE" );
}

static void test_reach64( void )
{
    wow32 = 0;
    ios_wow_windows[0].base = (ULONG_PTR)P(48); ios_wow_window_count = 1;
    ios_wow_placeholders[1].base = (ULONG_PTR)P(16); ios_wow_placeholder_count = 2;
    ios_hook_zone_add( ios_hook_zones, &pebs[0], (ULONG_PTR)P(0), 2 * PG );   /* this process's zone */
    ios_hook_zone_add( ios_hook_zones, &pebs[1], (ULONG_PTR)P(4), 2 * PG );   /* another process's */
    reset(); layout( 0, 32, RW ); layout( 36, 28, RW );
    view_kind = 1;                                                               /* other memory */
    T( nw( P(1) + 8, 16 ) == STATUS_SUCCESS && n == 16 && !n_server );         /* its own zone */
    T( nw( P(1) + 0xffc, 8 ) == STATUS_ACCESS_DENIED && n_server == 1 && P(2)[0] == 0x11 );   /* running out of it */
    T( nw( P(5), 16 ) == STATUS_ACCESS_DENIED && n_server == 2 && P(5)[0] == 0x11 );          /* another process's zone */
    T( nw( P(9), 16 ) == STATUS_ACCESS_DENIED && n_server == 3 && P(9)[0] == 0x11 );          /* other memory */
    view_kind = 0;                                                               /* an image view */
    T( nw( P(9), 16 ) == STATUS_SUCCESS && n_server == 3 && !memcmp( P(9), data, 16 ) );
    T( nw( P(49), 16 ) == STATUS_ACCESS_DENIED && n_server == 4 && P(49)[0] == 0x11 );        /* a 32-bit window */
    T( nw( P(17), 16 ) == STATUS_ACCESS_DENIED && n_server == 5 && P(17)[0] == 0x11 );        /* a placeholder */
    T( nw( P(15) + 0xffc, 16 ) == STATUS_ACCESS_DENIED && n_server == 6 );                     /* crossing into it */
    T( NtWriteVirtualMemory( NtCurrentProcess(), P(8), big, 32 * PG, &n ) == STATUS_ACCESS_DENIED && n_server == 7 &&
       P(8)[0] == 0x11 && P(20)[0] == 0x11 );                                    /* longer than a window */
    T( NtWriteVirtualMemory( NtCurrentProcess(), P(0), big, 16 * PG, &n ) == STATUS_SUCCESS && n == 16 * PG );
    cur_peb = &pebs[1]; view_kind = 1;
    T( nw( P(5), 16 ) == STATUS_SUCCESS && n_server == 7 );                     /* that process, in its own zone */
    cur_peb = &pebs[0]; view_kind = 0; wow32 = 1;
}

static void test_log( void )   /* a fresh process: the log's counters start at 0 */
{
    int i;

    reset(); layout( 0, 8, RW ); layout( 8, 4, RX ); layout( 32, 4, RWX );
    mprotect( G + 8 * HPG, HPG, PROT_READ );                                     /* the aliased page under a code-change trap */
    for (i = 0; i < 3; i++) nw( P(1), 4 );                                      /* pid 30: one line */
    teb.ClientId.UniqueProcess = (HANDLE)0x31;
    nw( P(33), 4 ); nw( P(1), 4 );                                               /* pid 31: one line */
    NOTE( 9, PAGE_EXECUTE_READWRITE ); nw( P(9), 4 );                            /* the protect record: noted */
    nw( P(7) + 0xffe, 4 );                                                       /* stopped after 2 bytes: noted */
    for (i = 0; i < 20; i++) nw( P(10), 4 );                                     /* stopped at once: noted while room */
}

int main( int argc, char **argv )
{
    pthread_mutexattr_t attr;
    char pool_path[] = "/tmp/check-self-write-pool-XXXXXX";
    int fd = mkstemp( pool_path ), i;

    if (fd >= 0) unlink( pool_path );
    pthread_mutexattr_init( &attr ); pthread_mutexattr_settype( &attr, PTHREAD_MUTEX_ERRORCHECK );   /* a held lock: an error */
    pthread_mutex_init( &virtual_mutex, &attr );
    G = mmap( NULL, NPAGES * PG + HPG, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0 );
    G = (char *)(((ULONG_PTR)G + HPG - 1) & ~(ULONG_PTR)(HPG - 1));
    if (fd < 0 || ftruncate( fd, HPG ) || mmap( G + 8 * HPG, HPG, PROT_READ, MAP_SHARED | MAP_FIXED, fd, 0 ) == MAP_FAILED ||
        (alias_rw = mmap( NULL, HPG, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0 )) == MAP_FAILED) abort();
    ios_jit_anon_aliases[0] = (struct ios_jit_anon_alias){ .user_va = (ULONG_PTR)G + 8 * HPG, .user_va_end = (ULONG_PTR)G + 9 * HPG,
                                                           .jit_rw_alias = (ULONG_PTR)alias_rw, .jit_rx_alias = (ULONG_PTR)alias_rw };
    ios_jit_anon_alias_count = 1;
    for (i = 0; i < (int)sizeof(data); i++) data[i] = (unsigned char)(i * 7 + 3);
    unsetenv( "MADEIRA_SELF_WRITE" );
    if (argc > 1 && !strcmp( argv[1], "log" )) test_log();
    else { test_pages(); test_record(); test_nt32(); test_switch(); test_reach64(); }
    printf( "%s\n", fails ? "HARNESS FAILED" : "harness ok" );
    return fails != 0;
}
'''

check("a C compiler is found", cc is not None)
if cc:
    with tempfile.TemporaryDirectory() as tmp:
        c, exe = os.path.join(tmp, "self-write.c"), os.path.join(tmp, "self-write")
        Path(c).write_text(HEAD + CUT + TESTS)
        flags = [cc, "-std=gnu11", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", c, "-o", exe, "-lpthread"]
        b = subprocess.run(flags, capture_output=True, text=True)
        check("the cut functions compile with -Wall -Wextra -Werror", b.returncode == 0, b.stderr)
        b = subprocess.run(flags + ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-fno-omit-frame-pointer"],
                           capture_output=True, text=True)
        check("and under AddressSanitizer + UndefinedBehaviorSanitizer", b.returncode == 0, b.stderr)
        env = {k: v for k, v in os.environ.items() if k != "MADEIRA_SELF_WRITE"}
        run = lambda *args: subprocess.run([exe, *args], capture_output=True, text=True, env=env, timeout=120)
        if b.returncode == 0:
            r = run()
            check("pages, the protect record, NtWriteVirtualMemory, the switch and the reach of a 32-bit and a 64-bit program",
                  r.returncode == 0 and r.stdout.strip().endswith("harness ok"), r.stdout + r.stderr)
            r = run("log")
            log = [l for l in r.stderr.splitlines() if l.startswith("[self-write]")]
            check("the log: one line for each process's first write, then at most 16 for writes that stopped or used the record",
                  r.returncode == 0 and len(log) == 18 and log[0].startswith("[self-write] pid 0030: ") and " direct " in log[0]
                  and log[1].startswith("[self-write] pid 0031: ") and " rw-view " in log[1] and " protect-record " in log[2]
                  and "STATUS_PARTIAL_COPY" in log[3] and all(", 0 written ( ), stopped at " in l for l in log[4:]),
                  "\n".join(log) + r.stdout + r.stderr[-1500:])

# ---------------------------------------------------------------- 2. the wiring
nwvm = cut(src, "NTSTATUS WINAPI NtWriteVirtualMemory( HANDLE process, void *addr, const void *buffer,")
request = ("        SERVER_START_REQ( write_process_memory )\n        {\n"
           "            req->handle     = wine_server_obj_handle( process );\n"
           "            req->addr       = wine_server_client_ptr( addr );\n"
           "            wine_server_add_data( req, buffer, size );\n"
           "            status = wine_server_call( req );\n"
           "            size = reply->written;\n        }\n        SERVER_END_REQ;\n")
branch = re.search(r"\n    if \(process == NtCurrentProcess\(\) && size && ios_self_write_enabled\(\) &&[^{]*\)\n    \{", nwvm)
check("NtWriteVirtualMemory: the branch, for the pseudo-handle only, comes before the server request, which is unchanged",
      branch is not None and nwvm.count(request) == 1 and nwvm.count("ios_self_write(") == 1
      and branch.end() < nwvm.index("ios_self_write( addr, buffer, size, &paths )") < nwvm.index(request))
nvp = cut(src, "NTSTATUS WINAPI NtProtectVirtualMemory( HANDLE process, PVOID *addr_ptr, SIZE_T *size_ptr,")
note, ok_block = "ios_self_write_note_protect( base, size, new_prot );", "\n    if (!status)\n    {\n"
check("NtProtectVirtualMemory notes a successful change of its own process, with the rounded range",
      nvp.count(note) == 1 and src.count("ios_self_write_note_protect(") == 2 and ok_block in nvp
      and nvp.index("if (process != NtCurrentProcess())") < nvp.index("base = ROUND_ADDR( addr, page_mask );")
      < nvp.index("status = set_protection( view, base, size, new_prot );") < nvp.index(ok_block) < nvp.index(note)
      and "\n    }\n" not in nvp[nvp.index(ok_block) + len(ok_block):nvp.index(note)])
check("the server has no port for a pseudo-process and refuses its writes",
      "    return process->trace_data;\n}" in cut(mach, "static mach_port_t get_process_port( struct process *process )")
      and "    if (!process_port)\n    {\n        set_error( STATUS_ACCESS_DENIED );\n        return 0;\n    }"
      in cut(mach, "int write_process_memory( struct process *process, client_ptr_t ptr, data_size_t size, const char *src,"))
gen = (root / "build/tools/gen-config-catalog.py").read_text()
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
check("the catalog documents env.MADEIRA_SELF_WRITE, on by default, in the generator and its output",
      re.search(r'"env\.MADEIRA_SELF_WRITE": \{[^}]*"default": "1"', gen) is not None
      and re.search(r'ConfigOption\(key: "env\.MADEIRA_SELF_WRITE", [^\n]*defaultValue: "1", [^\n]*'
                    r'sources: \["build/ntdll-unix/virtual_ios\.c"\]\)', cat) is not None)
bridge = (root / "app/Madeira/WineProcessBridge.m").read_text()
check("the session end clears the switch", 'unsetenv("MADEIRA_SELF_WRITE");' in bridge)

print("PASS: self-write" if ok else "FAILED: self-write")
sys.exit(0 if ok else 1)
