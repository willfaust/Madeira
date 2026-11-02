/*
 * Wine server communication
 *
 * Copyright (C) 1998 Alexandre Julliard
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

#if 0
#pragma makedep unix
#endif

#include "config.h"

#ifdef WINE_IOS
#include <os/log.h>
#include <pthread.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/mach_vm.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/time.h>
#include <time.h>
/* From signal_arm64_ios.c — written by __wine_syscall_dispatcher at entry */
extern volatile uint64_t g_wine_dispatcher_x18;
extern volatile uint64_t g_wine_dispatcher_count;
/* From signal_arm64_ios.c — written by __wine_syscall_dispatcher_return before jumping to PE */
extern volatile uint64_t g_wine_return_x18;
extern volatile uint64_t g_wine_return_pc;
extern volatile uint64_t g_wine_return_count;

/* File-based logging for iOS (os_log not visible via idevicesyslog on iOS 26) */
static FILE *g_wine_log_file = NULL;
static pthread_mutex_t g_wine_log_mutex = PTHREAD_MUTEX_INITIALIZER;

void wine_log_set_file(const char *path)
{
    pthread_mutex_lock(&g_wine_log_mutex);
    if (g_wine_log_file) fclose(g_wine_log_file);
    g_wine_log_file = fopen(path, "a");
    pthread_mutex_unlock(&g_wine_log_mutex);
}

static void wine_log_write(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void wine_log_write(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    /* Direct stderr (which is dup2'd to log file) instead of os_log to avoid
     * potential ObjC dispatch from inside FEX/x18-zero contexts. */
    dprintf(STDERR_FILENO, "%s\n", buf);
    /* Forward to UI log callback */
    extern void wine_ui_log(const char *message);
    wine_ui_log(buf);
    /* Also write to file if set */
    pthread_mutex_lock(&g_wine_log_mutex);
    if (g_wine_log_file) {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        struct tm tm;
        localtime_r(&tv.tv_sec, &tm);
        fprintf(g_wine_log_file, "[%02d:%02d:%02d.%03d] %s\n",
                tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec/1000), buf);
        fflush(g_wine_log_file);
    }
    pthread_mutex_unlock(&g_wine_log_mutex);
}
#endif


#include <assert.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#ifdef HAVE_LWP_H
#include <lwp.h>
#endif
#ifdef HAVE_PTHREAD_NP_H
# include <pthread_np.h>
#endif
#ifdef HAVE_PWD_H
# include <pwd.h>
#endif
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/wait.h>
#ifdef HAVE_SYS_UN_H
#include <sys/un.h>
#endif
#ifdef HAVE_SYS_PRCTL_H
# include <sys/prctl.h>
#endif
#include <sys/stat.h>
#ifdef HAVE_SYS_SYSCALL_H
# include <sys/syscall.h>
#endif
#ifdef HAVE_SYS_UIO_H
#include <sys/uio.h>
#endif
#ifdef HAVE_SYS_THR_H
#include <sys/thr.h>
#endif
#include <unistd.h>
#include <dirent.h>
#ifdef __APPLE__
#include <crt_externs.h>
#include <spawn.h>
#ifndef _POSIX_SPAWN_DISABLE_ASLR
#define _POSIX_SPAWN_DISABLE_ASLR 0x0100
#endif
#endif

#include "ntstatus.h"
#include "windef.h"
#include "winnt.h"
#include "winioctl.h"
#include "wine/server.h"
#include "wine/debug.h"
#include "unix_private.h"
#include "ios_wow.h"
#include "ddk/wdm.h"

WINE_DEFAULT_DEBUG_CHANNEL(server);
WINE_DECLARE_DEBUG_CHANNEL(syscall);

#ifndef MSG_CMSG_CLOEXEC
#define MSG_CMSG_CLOEXEC 0
#endif

#define SOCKETNAME "socket"        /* name of the socket file */
#define LOCKNAME   "lock"          /* name of the lock file */

static const char *server_dir;

unsigned int supported_machines_count = 0;
USHORT supported_machines[8] = { 0 };
USHORT native_machine = 0;
BOOL process_exiting = FALSE;

timeout_t server_start_time = 0;  /* time of server startup */

sigset_t server_block_set;  /* signals to block during server calls */
/* Wineserver socket for fd-passing. Must be shared across threads of the same
 * Wine process — a POSIX fd is process-wide, and in-process CreateThread
 * callers (e.g. DXMT's command-queue encode/finish threads) must reuse it.
 *
 * S1 pseudo-processes: each child "process" has its OWN master socket, and
 * the server detects process death by EOF on it. This global belongs to the
 * PARENT only; children register theirs in ios_proc_sockets below, keyed by
 * PEB (the pseudo-process identity — all the child's threads inherit it via
 * TEB->Peb). The old code overwrote this global with the newest child's
 * socket, so the SECOND process to exit closed an already-closed fd, its own
 * socket stayed open, and wineserver reported it STILL_ACTIVE forever
 * (2026-07-05 3-deep-tree bug). _Thread_local was tried before and broke
 * in-process CreateThread (new threads saw -1). */
static int fd_socket = -1;

#ifdef WINE_IOS
#define IOS_MAX_PROC_SOCKETS 64
static struct ios_proc_socket
{
    void *peb;      /* NULL = free slot */
    int fd;         /* this pseudo-process's master socket to wineserver */
    BOOL exiting;   /* per-process process_exiting flag */
} ios_proc_sockets[IOS_MAX_PROC_SOCKETS];
static int ios_proc_socket_count = 0;
/* madeira-bcd: PEBs of exited child pseudo-processes (ios_peb_is_dead). */
#define IOS_DEAD_PEB_MAX 64
static void * volatile ios_dead_pebs[IOS_DEAD_PEB_MAX];
static unsigned int ios_dead_peb_next;

extern void *ios_jit_current_peb(void);
extern ULONG_PTR ios_highest_user_address( BOOL wow64 );

static int ios_proc_socket_index(void)
{
    void *cur = ios_jit_current_peb();
    int i, n = ios_proc_socket_count;
    if (cur)
        for (i = 0; i < n; i++)
            if (ios_proc_sockets[i].peb == cur) return i;
    return -1;
}

/* Master socket for the CURRENT thread's pseudo-process (parent = global). */
static int ios_current_fd_socket(void)
{
    int i = ios_proc_socket_index();
    return (i >= 0) ? ios_proc_sockets[i].fd : fd_socket;
}

/* Per-process process_exiting flag (used by NtTerminateProcess). A global
 * flag poisons every OTHER pseudo-process's exit path once the first one
 * dies (they skip their self-terminate and the server never hears).
 *
 * The session's initial process has no slot and gets a flag of its own too:
 * the global process_exiting must stay FALSE. Wine's mutex_lock() and
 * mutex_unlock() (unix_private.h) skip the pthread call while it is set, for
 * every thread of every pseudo-process, so once a launcher that started the
 * game had exited, virtual_mutex, fd_cache_mutex and every other lock taken
 * through them stopped excluding anything for the rest of the session. */
static BOOL ios_initial_process_exiting;

BOOL *ios_process_exiting_ptr(void)
{
    int i = ios_proc_socket_index();
    return (i >= 0) ? &ios_proc_sockets[i].exiting : &ios_initial_process_exiting;
}

/* ─── ml586 fd-ownership trace ────────────────────────────────────────────
 * Root-cause instrumentation for the 0060-family kills: some pseudo-process
 * teardown closes wineserver-comm fds it doesn't own (broken runs ml579/580/
 * 584/585 → services.exe's rpcrt4 listener dies → SCM RPC dead → explorer
 * wedges in OpenSCManagerW → no Start menu). Ledger indexed by RAW FD NUMBER:
 * registration tripwires when a live comm fd's number reappears (= someone
 * closed it outside a traced site), teardown closes log owner-vs-closer,
 * and the victim read paths autopsy their fd against the ledger. */
#define IOS_FDT_MAX 4096
enum ios_fdt_kind { FDT_NONE = 0, FDT_MASTER, FDT_REQUEST_RD, FDT_REQUEST_WR,
                    FDT_REPLY_RD, FDT_REPLY_WR, FDT_WAIT_RD, FDT_WAIT_WR, FDT_CLOSED };
static const char * const ios_fdt_names[] = { "none", "master", "request_rd", "request_wr",
                                              "reply_rd", "reply_wr", "wait_rd", "wait_wr", "closed" };
struct ios_fdt_ent
{
    unsigned char kind;       /* live kind, or FDT_CLOSED */
    unsigned char prev_kind;  /* kind before a traced close */
    unsigned int  tid;        /* registrar's wine tid */
    void         *peb;        /* registrar's pseudo-process */
    unsigned int  gen;        /* global registration counter */
};
static struct ios_fdt_ent ios_fdt[IOS_FDT_MAX];
static unsigned int ios_fdt_gen;

/* Madeira: the thread id for the fd ledger's lines, 0 on a thread without a TEB.
 * GetCurrentThreadId() reads the TEB; the storm-end worker (ios_storm_end_thread, a plain host thread) has none, and
 * its first [fdtrace] line would read NULL+0x48 and end the whole app. */
static unsigned int ios_fdt_tid(void)
{
    TEB *teb = NtCurrentTeb();
    return teb ? (unsigned int)HandleToULong( teb->ClientId.UniqueThread ) : 0;
}

static void ios_fdt_reg( int fd, int kind, void *peb )
{
    struct ios_fdt_ent *e;
    if (fd < 0 || fd >= IOS_FDT_MAX) return;
    e = &ios_fdt[fd];
    if (e->kind && e->kind != FDT_CLOSED)
    {
        /* live number re-registered: PROOF something closed it silently */
        static int reuse_cap;
        if (reuse_cap++ < 200)
            wine_log_write("[fdtrace] SILENT-CLOSE fd=%d was %s owner_tid=%04x owner_peb=%p gen=%u; rereg %s tid=%04x peb=%p rev=ml586",
                           fd, ios_fdt_names[e->kind], e->tid, e->peb, e->gen,
                           ios_fdt_names[kind], ios_fdt_tid(), peb);
    }
    e->kind = (unsigned char)kind;
    e->prev_kind = 0;
    e->tid  = ios_fdt_tid();
    e->peb  = peb;
    e->gen  = __sync_add_and_fetch( &ios_fdt_gen, 1 );
}

/* exported for thread_ios.c: register a new thread's request pipe */
void ios_fdt_reg_request_pipe( int rd, int wr, void *peb );
void ios_fdt_reg_request_pipe( int rd, int wr, void *peb )
{
    ios_fdt_reg( rd, FDT_REQUEST_RD, peb );
    ios_fdt_reg( wr, FDT_REQUEST_WR, peb );
}

/* expected close (e.g. reply-pipe handoff): update ledger, no log.
 * NON-static: thread_ios.c marks its request-pipe handoff closes too. */
void ios_fdt_mark_closed( int fd )
{
    if (fd < 0 || fd >= IOS_FDT_MAX) return;
    if (ios_fdt[fd].kind && ios_fdt[fd].kind != FDT_CLOSED)
        ios_fdt[fd].prev_kind = ios_fdt[fd].kind;
    ios_fdt[fd].kind = FDT_CLOSED;
}

/* teardown close: log owner-vs-closer, flag cross-ownership loudly */
static void ios_fdt_note_close( int fd, const char *why, void *dead_peb )
{
    struct ios_fdt_ent *e;
    if (fd < 0 || fd >= IOS_FDT_MAX) return;
    e = &ios_fdt[fd];
    if (e->kind && e->kind != FDT_CLOSED)
    {
        int cross = (e->peb != dead_peb);
        wine_log_write("[fdtrace]%s close fd=%d why=%s kind=%s owner_tid=%04x owner_peb=%p gen=%u closer_tid=%04x dead_peb=%p rev=ml586",
                       cross ? " CROSS!" : "", fd, why, ios_fdt_names[e->kind],
                       e->tid, e->peb, e->gen, ios_fdt_tid(), dead_peb);
        e->prev_kind = e->kind;
        e->kind = FDT_CLOSED;
    }
    else
        wine_log_write("[fdtrace] close fd=%d why=%s untracked%s closer_tid=%04x dead_peb=%p rev=ml586",
                       fd, why, (e->kind == FDT_CLOSED) ? " (prev comm fd)" : "",
                       ios_fdt_tid(), dead_peb);
}

/* victim autopsy: what the ledger knows about a failing comm fd */
static void ios_fdt_autopsy( const char *what, int fd, int ret, int err )
{
    struct ios_fdt_ent *e = (fd >= 0 && fd < IOS_FDT_MAX) ? &ios_fdt[fd] : NULL;
    wine_log_write("[fdtrace] VICTIM %s tid=%04x fd=%d ret=%d errno=%d ledger=%s owner_tid=%04x owner_peb=%p gen=%u prev=%s rev=ml586",
                   what, ios_fdt_tid(), fd, ret, err,
                   e ? ios_fdt_names[e->kind] : "oob", e ? e->tid : 0, e ? e->peb : NULL,
                   e ? e->gen : 0, e ? ios_fdt_names[e->prev_kind] : "oob");
}

static void ios_register_proc_socket(void *peb_id, int fd)
{
    int idx = __sync_fetch_and_add(&ios_proc_socket_count, 1);
    if (idx >= IOS_MAX_PROC_SOCKETS)
    {
        wine_log_write("[Wine child] proc-socket table FULL (%d)!", idx);
        return;
    }
    ios_fdt_reg( fd, FDT_MASTER, peb_id );
    ios_proc_sockets[idx].fd = fd;
    ios_proc_sockets[idx].exiting = FALSE;
    { int d; for (d = 0; d < IOS_DEAD_PEB_MAX; d++) if (ios_dead_pebs[d] == peb_id) ios_dead_pebs[d] = NULL; }
    __sync_synchronize();
    ios_proc_sockets[idx].peb = peb_id;
}

/* madeira-bcd: is this the PEB of a child pseudo-process that has exited? A
 * thread whose TEB->Peb is listed is a zombie: the server's kill cannot signal
 * it on iOS, and its JIT copies are reclaimed. Lock-free (read from the Mach
 * exception thread); a live or re-registered PEB never counts as dead. */
int ios_peb_is_dead( const void *peb )
{
    int i, n = ios_proc_socket_count;
    if (!peb) return 0;
    if (n > IOS_MAX_PROC_SOCKETS) n = IOS_MAX_PROC_SOCKETS;
    for (i = 0; i < n; i++) if (ios_proc_sockets[i].peb == peb) return 0;
    for (i = 0; i < IOS_DEAD_PEB_MAX; i++) if (ios_dead_pebs[i] == peb) return 1;
    return 0;
}

/* Madeira storm-end: is this the PEB of a LIVE child pseudo-process (one that registered a master socket with the wineserver)?
 * The session's first process has no entry here, and neither has a PEB nobody knows: both answer 0. Lock-free, like
 * ios_peb_is_dead (read from the Mach exception thread). */
int ios_peb_is_live_child( const void *peb )
{
    int i, n = ios_proc_socket_count;
    if (!peb) return 0;
    if (n > IOS_MAX_PROC_SOCKETS) n = IOS_MAX_PROC_SOCKETS;
    for (i = 0; i < n; i++) if (ios_proc_sockets[i].peb == peb) return 1;
    return 0;
}

/* Madeira storm-end: END ONE CHILD PSEUDO-PROCESS FROM OUTSIDE ITS THREADS.
 *
 * The redelivery guard (signal_arm64_ios.c, "[redeliv] 2000 identical redeliveries") used to end the whole app, whichever
 * Windows process the storm was in. A storm in a child (a launcher's network-service helper) now ends that process only
 * (the caller's switch and policy are in signal_arm64_ios.c, ios_storm_action). process_exit_wrapper does the bookkeeping on the dying process's own thread; the storming thread cannot be
 * made to run it (its stack is the problem), so the same steps run here, keyed by the PEB, on a short-lived worker thread
 * (the Mach exception thread must never wait on a lock a Windows thread holds):
 *   - the master socket closes: the wineserver sees EOF, wakes the process's waiters and kills its threads server-side;
 *   - the child table (process_ios.c), the dead-PEB list, the fd cache, the sub-floor windows, the JIT pool allocations and the
 *     guest window are released exactly as process_exit_wrapper releases them.
 * Not done here: ios_retire_own_fixed_base_image (it needs the owning thread's server connection); the caller does not use this
 * path for a process that owns the fixed-base image. The process's other threads are left as an ordinary exit leaves them: the
 * ones that wake into reclaimed memory are ended one by one by the [zombie] rule in signal_arm64_ios.c. */
struct ios_storm_end { void *peb; int status; };
static struct ios_storm_end ios_storm_end_args[8];   /* no malloc on the Mach exception thread; a few at a time at most */
static unsigned ios_storm_end_next;

static void *ios_storm_end_thread( void *arg )
{
    struct ios_storm_end a = *(struct ios_storm_end *)arg;
    extern int ios_child_slot_name( void *peb, char *out, size_t len );
    extern void ios_child_slot_exited( void *peb );
    extern int ios_child_slot_note_exit( void *peb, int status );
    extern void ios_jit_reclaim_process( void *peb );
    extern void ios_fd_cache_release( void *peb );
    extern void ios_subfloor_release_owner( void *owner );
    extern void ios_wow_window_release( void *peb_id );
    char name[64];
    int i, n, fd = -1;

    pthread_setname_np( "wine-storm-end" );
    ios_child_slot_name( a.peb, name, sizeof(name) );
    n = ios_proc_socket_count;
    if (n > IOS_MAX_PROC_SOCKETS) n = IOS_MAX_PROC_SOCKETS;
    for (i = 0; i < n; i++)
    {
        /* claim the entry the way an ordinary exit clears it: whoever gets there first does the closing, once */
        if (ios_proc_sockets[i].peb != a.peb) continue;
        fd = ios_proc_sockets[i].fd;
        if (!__sync_bool_compare_and_swap( &ios_proc_sockets[i].peb, a.peb, NULL )) fd = -1;
        break;
    }
    if (fd < 0)
    {
        wine_log_write( "[redeliv] the Windows process %s (peb=%p) had already ended; nothing more to release rev=storm-end", name, a.peb );
        return NULL;
    }
    wine_log_write( "[redeliv] ending only the Windows process %s (peb=%p, master socket %d): the app and the other processes keep running "
                    "rev=storm-end", name, a.peb, fd );
    ios_fdt_note_close( fd, "exit-master-storm", a.peb );
    close( fd );
    ios_child_slot_exited( a.peb );
    ios_child_slot_note_exit( a.peb, a.status );
    ios_dead_pebs[__sync_fetch_and_add( &ios_dead_peb_next, 1 ) % IOS_DEAD_PEB_MAX] = a.peb;
    ios_fd_cache_release( a.peb );
    ios_subfloor_release_owner( a.peb );
    ios_jit_reclaim_process( a.peb );
    ios_wow_window_release( a.peb );
    wine_log_write( "[redeliv] the Windows process %s (peb=%p) is released: socket, child table, JIT allocations, guest window rev=storm-end",
                    name, a.peb );
    return NULL;
}

/* 1: a worker thread was started and will end the process; 0: nothing was done (the caller keeps its old behaviour). */
int ios_end_child_process_async( void *peb, int status )
{
    struct ios_storm_end *a;
    pthread_t t;

    if (!ios_peb_is_live_child( peb )) return 0;
    a = &ios_storm_end_args[__sync_fetch_and_add( &ios_storm_end_next, 1 ) % 8];
    a->peb = peb;
    a->status = status;
    if (pthread_create( &t, NULL, ios_storm_end_thread, a )) return 0;
    pthread_detach( t );
    return 1;
}
#endif
static _Thread_local int initial_cwd = -1;
static pid_t server_pid;
pthread_mutex_t fd_cache_mutex = PTHREAD_MUTEX_INITIALIZER;

/* atomically exchange a 64-bit value */
static inline LONG64 interlocked_xchg64( LONG64 *dest, LONG64 val )
{
#ifdef _WIN64
    return (LONG64)InterlockedExchangePointer( (void **)dest, (void *)val );
#else
    LONG64 tmp = *dest;
    while (InterlockedCompareExchange64( dest, val, tmp ) != tmp) tmp = *dest;
    return tmp;
#endif
}

#ifdef __GNUC__
static void fatal_error( const char *err, ... ) __attribute__((noreturn, format(printf,1,2)));
static void fatal_perror( const char *err, ... ) __attribute__((noreturn, format(printf,1,2)));
static void server_connect_error( const char *serverdir ) __attribute__((noreturn));
#endif

/* die on a fatal error; use only during initialization */
static void fatal_error( const char *err, ... )
{
#ifdef WINE_IOS
    va_list args;
    char buf[1024];
    va_start( args, err ); vsnprintf( buf, sizeof(buf), err, args ); va_end( args );
    os_log_error( OS_LOG_DEFAULT, "[Wine ntdll/server] FATAL: %{public}s", buf );
    pthread_exit( NULL );
#else
    va_list args;

    va_start( args, err );
    fprintf( stderr, "wine: " );
    vfprintf( stderr, err, args );
    va_end( args );
    exit(1);
#endif
}

/* die on a fatal error; use only during initialization */
static void fatal_perror( const char *err, ... )
{
#ifdef WINE_IOS
    va_list args;
    char buf[1024];
    va_start( args, err ); vsnprintf( buf, sizeof(buf), err, args ); va_end( args );
    os_log_error( OS_LOG_DEFAULT, "[Wine ntdll/server] FATAL_PERROR: %{public}s: %{public}s", buf, strerror(errno) );
    pthread_exit( NULL );
#else
    va_list args;

    va_start( args, err );
    fprintf( stderr, "wine: " );
    vfprintf( stderr, err, args );
    perror( " " );
    va_end( args );
    exit(1);
#endif
}

/***********************************************************************
 *           server_protocol_error
 */
static DECLSPEC_NORETURN void server_protocol_error( const char *err, ... )
{
    va_list args;

    va_start( args, err );
    fprintf( stderr, "wine client error:%x: ", GetCurrentThreadId() );
    vfprintf( stderr, err, args );
    va_end( args );
    abort_thread(1);
}


/***********************************************************************
 *           server_protocol_perror
 */
static DECLSPEC_NORETURN void server_protocol_perror( const char *err )
{
    fprintf( stderr, "wine client error:%x: ", GetCurrentThreadId() );
    perror( err );
    abort_thread(1);
}


#ifdef WINE_IOS
/* A thread killed inside an uninterrupted section leaves the section first.
 *
 * When the server kills a thread (TerminateThread, or TerminateProcess ending
 * the other threads of a process) it closes the thread's request and reply
 * pipes and sends SIGQUIT. On Linux SIGQUIT is blocked inside
 * server_enter_uninterrupted_section, so a killed thread always finishes the
 * section and releases its mutex before it dies. On iOS no signal reaches a
 * thread (send_thread_signal fails): the killed thread keeps running until a
 * request finds its pipe closed, and that request is often inside a section:
 * NtClose, NtDuplicateObject and server_get_unix_fd make theirs holding
 * fd_cache_mutex. The thread then exited holding the mutex, and every Windows
 * process here is a thread group in one Mach task sharing that mutex, so every
 * later NtClose in every process blocked for good. Seen on a device: an
 * installer's msiexec failed and ended its other threads, one was in its
 * DLL-detach calls; the program waiting for msiexec then hung in NtClose.
 *
 * So inside a section a dead pipe fails the request with
 * STATUS_THREAD_IS_TERMINATING instead of exiting, later requests fail the same
 * way without touching the pipes, and the thread exits when it leaves its
 * outermost section, which is where Linux delivers the SIGQUIT. Outside a
 * section nothing changes. The depth lives in a pthread key rather than a
 * _Thread_local, whose first touch on a Darwin thread allocates: entering a
 * section must not allocate. */
static pthread_key_t ios_section_key;
static int ios_section_key_ready;

static void __attribute__((constructor)) ios_section_key_init(void)
{
    ios_section_key_ready = !pthread_key_create( &ios_section_key, NULL );
}

#define IOS_SECTION_DEPTH   0x0fffffffu  /* sections this thread is in */
#define IOS_SECTION_EXITING 0x20000000u  /* the deferred exit has started */
#define IOS_SECTION_ABORT   0x40000000u  /* killed: requests fail, exit on leaving */

static inline uintptr_t ios_section_state(void)
{
    return ios_section_key_ready ? (uintptr_t)pthread_getspecific( ios_section_key ) : 0;
}

static inline void ios_section_set_state( uintptr_t state )
{
    if (ios_section_key_ready) pthread_setspecific( ios_section_key, (void *)state );
}

/* A dead pipe on the current thread. TRUE: fail the request, the thread exits when
 * it leaves its sections. FALSE: exit now (not in a section, or switched off). */
static BOOL ios_defer_section_abort(void)
{
    static int enabled = -1;
    static int logged;
    uintptr_t state = ios_section_state();

    if (!(state & IOS_SECTION_DEPTH)) return FALSE;
    if (enabled < 0)
    {
        /* MADEIRA_DEFER_SECTION_ABORT=0: a killed thread exits at once, even inside a section */
        const char *env = getenv( "MADEIRA_DEFER_SECTION_ABORT" );
        enabled = !(env && env[0] == '0');
    }
    if (!enabled) return FALSE;
    if (!(state & IOS_SECTION_ABORT))
    {
        ios_section_set_state( state | IOS_SECTION_ABORT );
        if (__sync_fetch_and_add( &logged, 1 ) < 16)
            dprintf( 2, "[section-abort] tid=%04x killed inside %u uninterrupted section(s); "
                     "the thread exits when it leaves them\n", (unsigned int)GetCurrentThreadId(),
                     (unsigned int)(state & IOS_SECTION_DEPTH) );
    }
    return TRUE;
}
#endif


/***********************************************************************
 *           send_request
 *
 * Send a request to the server.
 */
static unsigned int send_request( const struct __server_request_info *req )
{
    int request_fd = ntdll_get_thread_data()->request_fd;

    if (!req->u.req.request_header.request_size)
    {
        data_size_t to_write = sizeof(req->u.req);
        const char *write_ptr = (const char *)&req->u.req;

        for (;;)
        {
            ssize_t ret = write( request_fd, write_ptr, to_write );
            if (ret == to_write) return STATUS_SUCCESS;
            if (ret < 0) break;
            to_write -= ret;
            write_ptr += ret;
        }
    }
    else
    {
        data_size_t to_write = sizeof(req->u.req) + req->u.req.request_header.request_size;
        struct iovec vec[__SERVER_MAX_DATA+1];
        unsigned int i, j;

        vec[0].iov_base = (void *)&req->u.req;
        vec[0].iov_len = sizeof(req->u.req);
        for (i = 0; i < req->data_count; i++)
        {
            vec[i+1].iov_base = (void *)req->data[i].ptr;
            vec[i+1].iov_len = req->data[i].size;
        }

        for (;;)
        {
            ssize_t ret = writev( request_fd, vec, i + 1 );
            if (ret == to_write) return STATUS_SUCCESS;
            if (ret < 0) break;
            to_write -= ret;
            for (j = 0; j < i + 1; j++)
            {
                if (ret >= vec[j].iov_len)
                {
                    ret -= vec[j].iov_len;
                    vec[j].iov_len = 0;
                }
                else
                {
                    vec[j].iov_base = (char *)vec[j].iov_base + ret;
                    vec[j].iov_len -= ret;
                    break;
                }
            }
        }
    }

    if (errno == EPIPE)
    {
#ifdef WINE_IOS
        if (ios_defer_section_abort()) return STATUS_THREAD_IS_TERMINATING;
#endif
        abort_thread(0);
    }
    if (errno == EFAULT) return STATUS_ACCESS_VIOLATION;
    server_protocol_perror( "write" );
}


/***********************************************************************
 *           read_reply_data
 *
 * Read data from the reply buffer; helper for wait_reply.
 * Returns FALSE only when a killed thread's exit is deferred (iOS).
 */
static BOOL read_reply_data( void *buffer, size_t size )
{
    int ret;

    for (;;)
    {
        if ((ret = read( ntdll_get_thread_data()->reply_fd, buffer, size )) > 0)
        {
            if (!(size -= ret)) return TRUE;
            buffer = (char *)buffer + ret;
            continue;
        }
        if (!ret) break;
        if (errno == EINTR) continue;
        if (errno == EPIPE) break;
#ifdef WINE_IOS
        {
            int bad_fd = ntdll_get_thread_data()->reply_fd;
            void *teb = NtCurrentTeb();
            uint64_t x18_val;
            __asm__ volatile("mov %0, x18" : "=r"(x18_val));
            dprintf(STDERR_FILENO, "[Wine FATAL] read_reply_data: reply_fd=%d teb=%p x18=0x%llx errno=%d fd_socket=%d\n",
                    bad_fd, teb, (unsigned long long)x18_val, errno, fd_socket);
        }
#endif
        server_protocol_perror("read");
    }
#ifdef WINE_IOS
    /* EOF flavor: the server-side write end of our reply pipe vanished */
    ios_fdt_autopsy( "reply-read-eof", ntdll_get_thread_data()->reply_fd, ret, errno );
    if (ios_defer_section_abort()) return FALSE;
#endif
    /* the server closed the connection; time to die... */
    abort_thread(0);
}


#ifdef WINE_IOS
/* Reply data for anonymous RWX memory.
 *
 * VirtualAlloc(PAGE_EXECUTE_READWRITE) memory that takes the JIT-pool path is the pool's RX view at its guest address
 * (W^X); guest stores into it fault and the store emulator (signal_arm64_ios.c) writes them through the pool's RW
 * alias. read() cannot fault its way through: it returns EFAULT, and read_reply_data treated every EFAULT as a fatal
 * protocol error ("wine client error: read: Bad address"), which killed the calling thread. Any request whose reply
 * buffer is such memory hit it (NtQueryValueKey, NtQueryObject, NtReadVirtualMemory of another process, ...);
 * Windows writes the reply.
 *
 * So the data part of a reply whose destination touches JIT-pool RX memory is read page by page through a bounce
 * buffer and stored through the RW alias, as a guest store would be. Every other destination keeps the single read().
 * If such a read still fails with EFAULT, the rest of the reply is read page by page and the call fails with
 * STATUS_ACCESS_VIOLATION (what Windows returns for an output buffer it cannot write) instead of the thread dying.
 * Limit of that fallback: if the failed read() had already consumed a prefix (a pipe-buffer wrap into a destination
 * that is only partly writable), the drain waits for bytes that never come; the alias case never takes this path. */
extern void *ios_jit_rx_base_global, *ios_jit_rw_base_global;
extern size_t ios_jit_pool_size_global;
extern uintptr_t ios_jit_anon_alias_lookup( uintptr_t addr );
extern void ios_jit_anon_alias_note_write( unsigned long long addr );

#define IOS_REPLY_PAGE 0x1000   /* guest page: pool ranges and anonymous-RWX aliases are multiples of it */

static BOOL ios_reply_host_writable( uintptr_t addr, size_t size );

/* ml2230 (device log 111): a page the JIT pool gave up (a poisoned range whose non-executable pages were dropped,
 * no freelist entry and no mapping left) is a hole inside the pool's address range, and the kernel puts other
 * mappings there: a child process's first thread got its pthread stack in one, and its first server reply into a
 * stack buffer went to the RW alias of that hole, which is not mapped (rpcss.exe died at boot, the Steam client's
 * COM call waited for it forever). A pool RX page is never writable at its own address, so a page that is writable
 * there is stored directly. env.MADEIRA_REPLY_OWN_WRITABLE=0: the pool's address range alone decides, as before. */
static int ios_reply_own_writable( void )
{
    static int on = -1;
    if (on < 0)
    {
        const char *e = getenv( "MADEIRA_REPLY_OWN_WRITABLE" );   /* 0: a reply into the JIT pool's address range always goes through its RW alias, as before */
        on = !(e && e[0] == '0');
    }
    return on;
}

/* The RW alias of a guest address that is a JIT-pool RX view (not writable at its own address), or 0. */
static uintptr_t ios_reply_rw_alias( uintptr_t addr )
{
    uintptr_t rx = (uintptr_t)ios_jit_rx_base_global, rw = (uintptr_t)ios_jit_rw_base_global;
    size_t size = ios_jit_pool_size_global;

    if (rx && rw && size && addr >= rx && addr - rx < size)
    {
        uintptr_t page = addr & ~(uintptr_t)(IOS_REPLY_PAGE - 1);
        if (ios_reply_own_writable() && ios_reply_host_writable( page, IOS_REPLY_PAGE )) return 0;   /* ml2230 */
        return rw + (addr - rx);
    }
    return ios_jit_anon_alias_lookup( addr );
}

/* Is all of [addr, addr+size) mapped and writable at its own address? */
static BOOL ios_reply_host_writable( uintptr_t addr, size_t size )
{
    mach_vm_address_t a = addr, end = addr + size;

    while (a < end)
    {
        mach_vm_address_t q = a;
        mach_vm_size_t sz = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;

        if (mach_vm_region( mach_task_self(), &q, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
                            &cnt, &obj ) != KERN_SUCCESS)
            return FALSE;
        if (q > a || !(info.protection & VM_PROT_WRITE)) return FALSE;
        a = q + sz;
    }
    return TRUE;
}

/* Read size reply bytes for guest memory one guest page at a time through a bounce buffer: a JIT-pool RX page is
 * stored through its RW alias, a writable page directly, any other page drops its bytes and sets *fault.
 * Returns FALSE only for a deferred thread exit. */
static BOOL ios_read_reply_paged( uintptr_t dst, size_t size, BOOL *fault )
{
    char bounce[IOS_REPLY_PAGE];

    while (size)
    {
        size_t n = IOS_REPLY_PAGE - (dst & (IOS_REPLY_PAGE - 1));
        uintptr_t rw;

        if (n > size) n = size;
        if (!read_reply_data( bounce, n )) return FALSE;
        if ((rw = ios_reply_rw_alias( dst )))
        {
            memcpy( (void *)rw, bounce, n );
            ios_jit_anon_alias_note_write( dst );
        }
        else if (ios_reply_host_writable( dst, n )) memcpy( (void *)dst, bounce, n );
        else *fault = TRUE;
        dst += n;
        size -= n;
    }
    return TRUE;
}

/* The data part of a reply (wait_reply). Returns FALSE only for a deferred thread exit; *fault is set when part of
 * the destination could not be written. req is the request code, for the log only. */
static BOOL ios_read_reply_guest( void *buffer, size_t size, int req, BOOL *fault )
{
    static unsigned int alias_logs, efault_logs;
    uintptr_t dst = (uintptr_t)buffer, page, end = dst + size;
    ssize_t ret;

    for (page = dst & ~(uintptr_t)(IOS_REPLY_PAGE - 1); page < end; page += IOS_REPLY_PAGE)
    {
        if (!ios_reply_rw_alias( page )) continue;
        if (__sync_fetch_and_add( &alias_logs, 1 ) < 8)
            dprintf( 2, "[reply-alias] tid=%04x req=%d dst=%p size=%#lx: reply data stored through the RW alias "
                     "of anonymous RWX memory\n", (unsigned int)GetCurrentThreadId(), req, buffer,
                     (unsigned long)size );
        return ios_read_reply_paged( dst, size, fault );
    }
    while (size)
    {
        if ((ret = read( ntdll_get_thread_data()->reply_fd, (void *)dst, size )) > 0)
        {
            dst += ret;
            size -= ret;
            continue;
        }
        if (ret < 0 && errno == EINTR) continue;
        if (ret < 0 && errno == EFAULT)
        {
            if (__sync_fetch_and_add( &efault_logs, 1 ) < 8)
                dprintf( 2, "[reply-efault] tid=%04x req=%d dst=%p size=%#lx: destination not writable and not "
                         "aliased; read page by page, STATUS_ACCESS_VIOLATION if a page stays unwritable\n",
                         (unsigned int)GetCurrentThreadId(), req, (void *)dst, (unsigned long)size );
            return ios_read_reply_paged( dst, size, fault );
        }
        return read_reply_data( (void *)dst, size );   /* EOF, EPIPE, anything else: the original handling */
    }
    return TRUE;
}
#endif


/***********************************************************************
 *           wait_reply
 *
 * Wait for a reply from the server.
 */
static inline unsigned int wait_reply( struct __server_request_info *req )
{
#ifdef WINE_IOS
    int code = req->u.req.request_header.req;   /* the reply header overwrites it */
    BOOL fault = FALSE;
#endif

    if (!read_reply_data( &req->u.reply, sizeof(req->u.reply) )) return STATUS_THREAD_IS_TERMINATING;
#ifdef WINE_IOS
    if (req->u.reply.reply_header.reply_size)
    {
        if (!ios_read_reply_guest( req->reply_data, req->u.reply.reply_header.reply_size, code, &fault ))
            return STATUS_THREAD_IS_TERMINATING;
        if (fault) return STATUS_ACCESS_VIOLATION;
    }
#else
    if (req->u.reply.reply_header.reply_size &&
        !read_reply_data( req->reply_data, req->u.reply.reply_header.reply_size ))
        return STATUS_THREAD_IS_TERMINATING;
#endif
    return req->u.reply.reply_header.error;
}


/* ============================================================================
 * ml875 [thread-sample] -- task-wide guest/native thread sampler.
 *
 * Why this shape (review of ml873/ml874):
 *  - every thread gets a record: native pc/lr/sp + dladdr, name, run state,
 *    even when guest resolution fails (a GameThread blocked in native code
 *    carries no valid FEX registers and would otherwise vanish);
 *  - the guest RIP comes from the ml688 block-tail resolver ([x28+0] is
 *    InlineJITBlockHeader); State.rip is NOT maintained while the JIT runs;
 *  - x17 (callret sp) and x23 (SRA guest rsp) are only meaningful when pc is
 *    inside a JIT block, so callret/stack are only decoded on a resolved
 *    sample; stack matches are CANDIDATE return addresses, not an unwind;
 *  - module names come from the sampled thread's OWN PEB (pseudo-processes
 *    share the Mach task but not their loader lists), rebuilt every burst;
 *  - one sampler for the task, bursts of 4 passes 250 ms apart every 20 s,
 *    GameThread and RUNNING threads on every pass, everything else once. */
static int ios_ts_armed;
struct ios_ts_mod { uint64_t base, size; char name[40]; };
struct ios_ts_map { uint64_t peb; int n; struct ios_ts_mod m[160]; };
static struct ios_ts_map ios_ts_maps[6];
static int ios_ts_nmaps;

static int ios_ts_read(uint64_t a, void *o, size_t n)
{
    vm_size_t got = 0;
    return a > 0x10000 && vm_read_overwrite(mach_task_self(), (vm_address_t)a, n, (vm_address_t)o, &got) == KERN_SUCCESS && got == n;
}

/* ml876: thread_get_state returns x18 == 0 for every thread (the kernel does
 * not preserve the platform register), so ml875 never had a TEB and never
 * built a module map. The TEB lives in the pthread TSD slot ios_teb_tls_key;
 * find the TSD array's offset inside struct pthread by SELF-CALIBRATION (set
 * a private key on this thread, scan for the value) rather than trusting the
 * 224 from libpthread's private headers. */
static long ios_ts_tsd_off = -1;
static void ios_ts_calibrate(void)
{
    extern pthread_key_t ios_teb_tls_key;
    pthread_key_t k; long off; char *base = (char *)pthread_self();
    if (pthread_key_create(&k, NULL)) return;
    pthread_setspecific(k, (void *)0x5a5a1234abcdULL);
    for (off = 0; off < 8192; off += 8) {
        uint64_t v = 0;
        if (ios_ts_read((uint64_t)(uintptr_t)base + off + (uint64_t)k * 8, &v, 8) && v == 0x5a5a1234abcdULL) { ios_ts_tsd_off = off; break; }
    }
    pthread_setspecific(k, NULL); pthread_key_delete(k);
    wine_log_write("[thread-sample] ml876 tsd offset calibrated: %ld (teb key %lu)", ios_ts_tsd_off, (unsigned long)ios_teb_tls_key);
}
static uint64_t ios_ts_teb(pthread_t pt)
{
    extern pthread_key_t ios_teb_tls_key;
    uint64_t v = 0;
    if (ios_ts_tsd_off < 0 || !pt || !ios_teb_tls_key) return 0;
    ios_ts_read((uint64_t)(uintptr_t)pt + ios_ts_tsd_off + (uint64_t)ios_teb_tls_key * 8, &v, 8);
    return (v & 0xfff) ? 0 : v;
}

static struct ios_ts_map *ios_ts_map_for_teb(uint64_t teb)
{
    uint64_t peb = 0, ldr = 0, head, cur; int i, guard = 0; struct ios_ts_map *mp;
    if (!teb || (teb & 0xfff) || !ios_ts_read(teb + 0x60, &peb, 8) || !peb) return NULL;
    for (i = 0; i < ios_ts_nmaps; i++) if (ios_ts_maps[i].peb == peb) return &ios_ts_maps[i];
    if (ios_ts_nmaps >= 6 || !ios_ts_read(peb + 0x18, &ldr, 8) || !ldr) return NULL;
    mp = &ios_ts_maps[ios_ts_nmaps]; memset(mp, 0, sizeof(*mp)); mp->peb = peb;
    head = ldr + 0x10;
    if (!ios_ts_read(head, &cur, 8)) return NULL;
    while (cur && cur != head && guard++ < 200 && mp->n < 160) {
        uint64_t base = 0, buf = 0, next = 0; uint32_t size = 0; uint16_t len = 0, w[40]; int k;
        if (!ios_ts_read(cur + 0x30, &base, 8) || !ios_ts_read(cur + 0x40, &size, 4) ||
            !ios_ts_read(cur + 0x58, &len, 2) || !ios_ts_read(cur + 0x60, &buf, 8)) break;
        if (base && size) {
            struct ios_ts_mod *m = &mp->m[mp->n++];
            m->base = base; m->size = size;
            len /= 2; if (len > 39) len = 39;
            if (len && ios_ts_read(buf, w, len * 2)) { for (k = 0; k < len; k++) m->name[k] = w[k] < 128 ? (char)w[k] : '?'; m->name[len] = 0; }
            else strcpy(m->name, "?");
        }
        if (!ios_ts_read(cur, &next, 8)) break;
        cur = next;
    }
    ios_ts_nmaps++;
    wine_log_write("[thread-sample] ml876 modmap peb=0x%llx modules=%d first=%s@0x%llx", (unsigned long long)peb, mp->n,
                   mp->n ? mp->m[0].name : "-", (unsigned long long)(mp->n ? mp->m[0].base : 0));
    return mp;
}

static const char *ios_ts_mod_for(struct ios_ts_map *mp, uint64_t va, uint64_t *rva)
{
    int i;
    if (!mp) return NULL;
    for (i = 0; i < mp->n; i++)
        if (va >= mp->m[i].base && va < mp->m[i].base + mp->m[i].size) { *rva = va - mp->m[i].base; return mp->m[i].name; }
    return NULL;
}

static int ios_ts_sym(uint64_t a, char *out, size_t cap)
{
    Dl_info di; const char *img;
    if (!a || !dladdr((void *)a, &di) || !di.dli_fname) { snprintf(out, cap, "0x%llx", (unsigned long long)a); return 0; }
    img = strrchr(di.dli_fname, '/'); img = img ? img + 1 : di.dli_fname;
    if (di.dli_sname) snprintf(out, cap, "%s`%s+0x%llx", img, di.dli_sname, (unsigned long long)(a - (uint64_t)di.dli_saddr));
    else snprintf(out, cap, "%s+0x%llx", img, (unsigned long long)(a - (uint64_t)di.dli_fbase));
    return 1;
}

static void ios_thread_sampler_pass(int burst)
{
    extern uint64_t ios_native_rip_from_hostpc( uint64_t, uint64_t, const char ** );
    mach_port_t self_port = pthread_mach_thread_np(pthread_self());
    thread_act_array_t tlist; mach_msg_type_number_t tcount; unsigned k, printed = 0;
    if (task_threads(mach_task_self(), &tlist, &tcount) != KERN_SUCCESS) return;
    ios_ts_nmaps = 0;                                   /* fresh maps every pass */
    for (k = 0; k < tcount && printed < 64; k++) {
        thread_basic_info_data_t bi; mach_msg_type_number_t bic = THREAD_BASIC_INFO_COUNT;
        arm_thread_state64_t st; mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
        char tname[40] = ""; pthread_t pt; int running, is_game;
        uint64_t pc, lr, sp, x28, x17, x18, x23, bb = 0, rip = 0, cr[16], stk[64], nstk[64];
        int have_bb, have_cr, have_stk, have_nstk;
        const char *why = "";
        if (tlist[k] == self_port) continue;
        if (thread_info(tlist[k], THREAD_BASIC_INFO, (thread_info_t)&bi, &bic) != KERN_SUCCESS) continue;
        pt = pthread_from_mach_thread_np(tlist[k]);
        if (pt) pthread_getname_np(pt, tname, sizeof(tname));
        running = bi.run_state == TH_STATE_RUNNING;
        is_game = !strcmp(tname, "GameThread") || !strncmp(tname, "RenderThread", 12) || !strncmp(tname, "RHIThread", 9);
        if (burst && !running && !is_game) continue;    /* idle waiters: once per burst */
        if (thread_suspend(tlist[k]) != KERN_SUCCESS) continue;
        if (thread_get_state(tlist[k], ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) != KERN_SUCCESS) { thread_resume(tlist[k]); continue; }
        pc = arm_thread_state64_get_pc(st); lr = arm_thread_state64_get_lr(st); sp = arm_thread_state64_get_sp(st);
        x28 = st.__x[28]; x17 = st.__x[17]; x23 = st.__x[23];
        x18 = ios_ts_teb(pt);                          /* ml876: TEB from TSD, not x18 */
        if (!x18) x18 = st.__x[18];
        have_bb  = ios_ts_read(x28, &bb, 8) && bb > 0x10000;
        have_cr  = ios_ts_read(x17, cr, sizeof(cr));
        have_stk = !(x23 & 7) && ios_ts_read(x23, stk, sizeof(stk));
        have_nstk = !(sp & 7) && ios_ts_read(sp, nstk, sizeof(nstk));
        thread_resume(tlist[k]);
        if (have_bb) rip = ios_native_rip_from_hostpc(bb, pc, &why);
        {
            char line[1400], s1[120], s2[120]; int n; unsigned i, shown; uint64_t rva; const char *mn;
            struct ios_ts_map *mp = ios_ts_map_for_teb(x18);
            ios_ts_sym(pc, s1, sizeof(s1)); ios_ts_sym(lr, s2, sizeof(s2));
            n = snprintf(line, sizeof(line), "[thread-sample] ml876 b%d \"%s\" teb=0x%llx cpu=%d%% %s pc=%s lr=%s sp=0x%llx",
                         burst, tname, (unsigned long long)x18, bi.cpu_usage / 10, running ? "RUN" : "wait",
                         s1, s2, (unsigned long long)sp);
            if (rip) {
                mn = ios_ts_mod_for(mp, rip, &rva);
                n += snprintf(line + n, sizeof(line) - n, " GUEST rip=0x%llx", (unsigned long long)rip);
                if (mn) n += snprintf(line + n, sizeof(line) - n, "(%s+0x%llx)", mn, (unsigned long long)rva);
                n += snprintf(line + n, sizeof(line) - n, " callret=[");
                for (i = 0; have_cr && i < 8 && n < (int)sizeof(line) - 100; i++) {
                    uint64_t g = cr[i * 2]; if (!g) break;
                    mn = ios_ts_mod_for(mp, g, &rva);
                    if (mn) n += snprintf(line + n, sizeof(line) - n, " %s+0x%llx", mn, (unsigned long long)rva);
                    else n += snprintf(line + n, sizeof(line) - n, " 0x%llx", (unsigned long long)g);
                }
                n += snprintf(line + n, sizeof(line) - n, " ] rsp=0x%llx stack-cand=[", (unsigned long long)x23);
                for (i = 0, shown = 0; have_stk && i < 64 && shown < 12 && n < (int)sizeof(line) - 80; i++) {
                    mn = ios_ts_mod_for(mp, stk[i], &rva);
                    if (!mn || rva < 0x1000) continue;
                    n += snprintf(line + n, sizeof(line) - n, " %s+0x%llx", mn, (unsigned long long)rva); shown++;
                }
                n += snprintf(line + n, sizeof(line) - n, " ]");
            } else {
                n += snprintf(line + n, sizeof(line) - n, " NATIVE (%s%s) sp-cand=[", have_bb ? "unresolved: " : "no FEX state", have_bb ? why : "");
                for (i = 0, shown = 0; have_nstk && i < 64 && shown < 12 && n < (int)sizeof(line) - 80; i++) {
                    mn = ios_ts_mod_for(mp, nstk[i], &rva);
                    if (!mn || rva < 0x1000) continue;
                    n += snprintf(line + n, sizeof(line) - n, " %s+0x%llx", mn, (unsigned long long)rva); shown++;
                }
                n += snprintf(line + n, sizeof(line) - n, " ]");
            }
            wine_log_write("%s", line);
            printed++;
        }
    }
    for (k = 0; k < tcount; k++) mach_port_deallocate(mach_task_self(), tlist[k]);
    vm_deallocate(mach_task_self(), (vm_address_t)tlist, tcount * sizeof(*tlist));
}

/* madeira-bcd ml1112b: NAME what a hot IAT call calls.
 *
 * ml1112 printed `call [slot] -> target` as two numbers, and the God of War
 * 1080p log (2026-10-01 15:06:44, build 279) needed the game binary and the
 * shipped kernel32.dll by hand to learn that 0x71fe7074f0 is kernel32!Sleep
 * and 0x71fe7109a0 kernel32!GetCurrentThreadId (an x64 fast-forward thunk in
 * .hexpthk). These two helpers do that on the device:
 *   - ios_rp_export_name: the nearest export at or below an RVA of a PE image
 *     ("kernel32.dll!Sleep", "+0x.." when not exact);
 *   - ios_rp_import_name: which import an IAT slot of the CALLING image holds
 *     ("KERNEL32.dll!Sleep"), from its import directory.
 * Read-only and bounded: every read is ios_ts_read (vm_read_overwrite, which
 * fails instead of faulting on an unmapped page), into fixed buffers on the
 * stack -- no allocation, no lock -- and every loop has a cap. They run on the
 * thread sampler's own thread (ios_thread_sampler_main), never in a signal or
 * exception context, and only for the <= 6 hottest buckets of a profile. */
static int ios_rp_read_str( uint64_t a, char *out, size_t cap )
{
    size_t n;
    if (!cap) return 0;
    out[0] = 0;
    /* a name can end right before an unmapped page: try shorter windows */
    for (n = cap - 1; n >= 8; n /= 2)
        if (ios_ts_read( a, out, n )) { out[n] = 0; return out[0] != 0; }
    return 0;
}

static int ios_rp_pe_dir( uint64_t base, int index, uint32_t dir[2] )
{
    uint32_t lfanew = 0, sig = 0; uint16_t magic = 0;
    dir[0] = dir[1] = 0;
    if (!ios_ts_read( base + 0x3c, &lfanew, 4 ) || lfanew < 0x40 || lfanew > 0x1000) return 0;
    if (!ios_ts_read( base + lfanew, &sig, 4 ) || sig != 0x00004550) return 0;          /* "PE\0\0" */
    if (!ios_ts_read( base + lfanew + 24, &magic, 2 ) || magic != 0x20b) return 0;       /* PE32+ */
    return ios_ts_read( base + lfanew + 24 + 112 + 8 * index, dir, 8 ) && dir[0] && dir[1];
}

static int ios_rp_export_name( uint64_t base, const char *mod, uint32_t rva, char *out, size_t cap )
{
    uint32_t dir[2], ed[10], nfunc, nname, i, j, best = ~0u, bestrva = 0, chunk32[256];
    uint16_t chunk16[256];
    char nm[64];
    if (!ios_rp_pe_dir( base, 0, dir ) || dir[1] < 40) return 0;
    if (!ios_ts_read( base + dir[0], ed, sizeof(ed) )) return 0;
    nfunc = ed[5] > 16384 ? 16384 : ed[5];
    nname = ed[6] > 16384 ? 16384 : ed[6];
    for (i = 0; i < nfunc; i += 256)
    {
        uint32_t n = nfunc - i < 256 ? nfunc - i : 256, k;
        if (!ios_ts_read( base + ed[7] + (uint64_t)i * 4, chunk32, n * 4 )) return 0;
        for (k = 0; k < n; k++)
        {
            uint32_t f = chunk32[k];
            if (!f || f > rva || (f >= dir[0] && f < dir[0] + dir[1])) continue;   /* empty, above, forwarder string */
            if (best == ~0u || f > bestrva) { best = i + k; bestrva = f; }
        }
    }
    if (best == ~0u) return 0;
    for (j = 0; j < nname; j += 256)
    {
        uint32_t n = nname - j < 256 ? nname - j : 256, k, name_rva = 0;
        if (!ios_ts_read( base + ed[9] + (uint64_t)j * 2, chunk16, n * 2 )) break;
        for (k = 0; k < n; k++)
        {
            if (chunk16[k] != best) continue;
            if (!ios_ts_read( base + ed[8] + (uint64_t)(j + k) * 4, &name_rva, 4 ) ||
                !ios_rp_read_str( base + name_rva, nm, sizeof(nm) )) break;
            if (rva == bestrva) snprintf( out, cap, "%s!%s", mod, nm );
            else snprintf( out, cap, "%s!%s+0x%x", mod, nm, rva - bestrva );
            return 1;
        }
    }
    snprintf( out, cap, "%s!#%u+0x%x", mod, ed[4] + best, rva - bestrva );   /* exported by ordinal only */
    return 1;
}

static int ios_rp_import_name( uint64_t base, uint64_t slot, char *out, size_t cap )
{
    uint32_t dir[2], desc[5], srva, best_ft = 0, best_oft = 0, best_name = 0, idx, k;
    uint64_t ents[64], ent;
    char dll[48], fn[64];
    int d;
    if (slot < base || slot - base >= 0x80000000ull || !ios_rp_pe_dir( base, 1, dir )) return 0;
    srva = (uint32_t)(slot - base);
    for (d = 0; d < 512; d++)   /* the descriptor whose IAT starts closest below the slot */
    {
        if (!ios_ts_read( base + dir[0] + (uint64_t)d * 20, desc, sizeof(desc) )) return 0;
        if (!desc[3] && !desc[4]) break;
        if (desc[4] <= srva && desc[4] > best_ft) { best_ft = desc[4]; best_oft = desc[0]; best_name = desc[3]; }
    }
    if (!best_ft || !best_oft || (srva - best_ft) % 8) return 0;
    idx = (srva - best_ft) / 8;
    if (idx > 8192) return 0;
    for (k = 0; k <= idx; k += 64)   /* inside this descriptor's array: no terminator before the slot */
    {
        uint32_t n = idx + 1 - k < 64 ? idx + 1 - k : 64, q;
        if (!ios_ts_read( base + best_oft + (uint64_t)k * 8, ents, n * 8 )) return 0;
        for (q = 0; q < n; q++) if (!ents[q]) return 0;
    }
    ent = ents[(idx % 64)];
    if (!ios_rp_read_str( base + best_name, dll, sizeof(dll) )) strcpy( dll, "?" );
    if (ent >> 63) snprintf( out, cap, "%s!#%u", dll, (unsigned)(ent & 0xffff) );
    else if (ios_rp_read_str( base + (ent & 0x7fffffff) + 2, fn, sizeof(fn) )) snprintf( out, cap, "%s!%s", dll, fn );
    else return 0;
    return 1;
}

/* "kernel32.dll!Sleep" for a call target: a pool-copy address goes back to its
 * PE address first (ARM64EC code runs from the JIT pool), then the module comes
 * from the sampled process's own loader list (ios_ts_map_for_teb). */
static void ios_rp_name_target( uint64_t teb, uint64_t target, char *out, size_t cap )
{
    extern int ios_jit_pool_image_pc( uintptr_t pc, uintptr_t *pe_addr_out );
    struct ios_ts_map *mp = ios_ts_map_for_teb( teb );
    uintptr_t pe = 0;
    uint64_t rva = 0;
    const char *mn;
    out[0] = 0;
    if (ios_jit_pool_image_pc( (uintptr_t)target, &pe ) && pe) target = pe;
    if (!(mn = ios_ts_mod_for( mp, target, &rva ))) return;
    if (!ios_rp_export_name( target - rva, mn, (uint32_t)rva, out, cap ))
        snprintf( out, cap, "%s+0x%llx", mn, (unsigned long long)rva );
}

/* ml979: is the guest looping tightly, or grinding forward slowly?
 *
 * rdr48/rdr49 plateau with four guest threads at ~35% CPU each, all with RIPs
 * inside EMP.dll's obfuscation VM, while every other signal is frozen: the
 * sub-floor counter stops dead, memory is flat, and there is no I/O. That is
 * either a small hot loop waiting for a condition that never becomes true, or
 * a slow sweep that is genuinely progressing. Those need completely different
 * responses, and the existing ml876 sampler cannot tell them apart -- it takes
 * 4 samples 250 ms apart every 20 s, which yielded 3 distinct RIPs across an
 * entire 15-minute run.
 *
 * So take a proper profile: many samples, close together, bucketed. A tight
 * loop concentrates in a handful of buckets; a sweep spreads across many and
 * the SPAN between the lowest and highest RIP grows between profiles.
 *
 * Deliberately does NOT suspend the threads -- we want them running, and a
 * sampling profiler tolerates the occasional torn read. Ports and the thread
 * array are released every pass; at 200 passes a leak here would exhaust the
 * port table. */
#define ML979_PASSES  200
#define ML979_BUCKETS 32
#define ML979_GRAIN   0x40ull        /* 64-byte buckets */
#define ML979_MAXTHREADS 12          /* guest threads tracked per profile */

static void ios_guest_rip_profile( int gen )
{
    extern uint64_t ios_native_rip_from_hostpc( uint64_t, uint64_t, const char ** );
    struct { uint64_t base; unsigned n; } b[ML979_BUCKETS];
    mach_port_t self_port = pthread_mach_thread_np( pthread_self() );
    uint64_t lo = ~0ull, hi = 0;
    unsigned total = 0, distinct = 0, dropped = 0;
    int nb = 0, pass, i;
    thread_act_t tg[ML979_MAXTHREADS];
    int ntg = 0;
    uint64_t rp_teb = 0;   /* ml1112b: a sampled guest thread's TEB, for the module list */

    /* ml980 FIX: the state read MUST be bracketed by thread_suspend/resume.
     *
     * The first cut skipped it on the theory that a sampling profiler tolerates
     * torn reads. On Darwin that is simply wrong -- thread_get_state on a
     * thread that is not suspended does not reliably return its registers, and
     * the sampler immediately above this function has always suspended for
     * exactly that reason. Result: 3 profiles x 200 passes resolved ZERO guest
     * RIPs and printed nothing at all (rdr50: 9 bursts, 0 rip-profile lines).
     *
     * Suspending every thread 200 times would be far too heavy (~40 threads),
     * so identify the guest threads ONCE per profile and then sample only those.
     * A guest thread is one whose x28 points at a readable FEX CpuStateFrame,
     * which is the same test the ml876 sampler uses. */
    {
        thread_act_array_t tl; mach_msg_type_number_t tc; unsigned k;
        if (task_threads( mach_task_self(), &tl, &tc ) != KERN_SUCCESS) return;
        for (k = 0; k < tc && ntg < ML979_MAXTHREADS; k++) {
            arm_thread_state64_t st; mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
            uint64_t bb = 0;
            pthread_t pt;
            if (tl[k] == self_port) continue;
            /* madeira-bcd: look the pthread up BEFORE the suspend, as the ml876
             * sampler does. pthread_from_mach_thread_np takes libpthread's thread
             * list lock; a thread suspended while it held that lock (creating or
             * ending a thread) was never resumed, because this profile blocked on
             * the lock with the thread still suspended. Every later thread start
             * and exit, the [xp] probe and the stack dumps then blocked behind it:
             * RDR2 on build 476 froze at 16:55:52, the moment a profile began.
             * Nothing between thread_suspend and thread_resume may take a lock. */
            pt = pthread_from_mach_thread_np( tl[k] );
            if (thread_suspend( tl[k] ) != KERN_SUCCESS) continue;
            /* ml981: a guest thread is one whose frame yields a plausible RIP at
             * x28+0x18 -- the same test the sampling loop uses, so a thread can
             * never be selected here and then fail to resolve below. */
            uint64_t teb_k = 0;
            if (thread_get_state( tl[k], ARM_THREAD_STATE64, (thread_state_t)&st, &cnt ) == KERN_SUCCESS
                && ios_ts_read( st.__x[28] + 0x18, &bb, 8 )
                && bb > 0x10000 && bb < 0x8000000000ull
                && (teb_k = ios_ts_teb( pt )))   /* ml1116: a Wine thread (has a TEB); native threads passed the x28 test by accident */
            {
                if (!rp_teb) rp_teb = teb_k;
                tg[ntg] = tl[k];
                mach_port_mod_refs( mach_task_self(), tl[k], MACH_PORT_RIGHT_SEND, 1 ); /* keep it */
                ntg++;
            }
            thread_resume( tl[k] );
        }
        for (k = 0; k < tc; k++) mach_port_deallocate( mach_task_self(), tl[k] );
        vm_deallocate( mach_task_self(), (vm_address_t)tl, tc * sizeof(*tl) );
    }
    if (!ntg) {
        wine_log_write( "[rip-profile] ml981 gen=%d: no guest threads found (no plausible RIP at x28+0x18)", gen );
        return;
    }

    /* ml1111: the ml981 histogram counted every guest thread, parked or not, so
     * 40-67 % of it was threads asleep in a wait. Keep a SECOND histogram of
     * RUNNING threads only (thread_basic_info.run_state), and for running
     * threads whose RIP is a native address (the guest is inside an ARM64EC
     * callee: our runtime, ntdll, the pool copies) bucket the HOST pc too, so
     * the native hot spots have names (symbolise offline: [jit-pool] image
     * lines + llvm-objdump --syms on the DLL). */
    struct { uint64_t base; unsigned n; } rb[ML979_BUCKETS], hb[ML979_BUCKETS];
    int nrb = 0, nhb = 0; unsigned rtotal = 0, htotal = 0;
    struct { uint64_t pc, lr, x16; } hcaller[24]; int hcaller_n = 0;   /* ml1115 */
    /* ml1123: CPU split of RUNNING Wine-thread samples by HOST pc:
     * 0 = FEX-compiled x64 (pool, not an image copy), 1 = ARM64EC image copy
     * (keyed by PE address: ntdll/kernelbase/libarm64ecfex/madeira_d3d12 ...),
     * 2 = native (Madeira dylib = Wine unix + madsync + bridge, system libs). */
    extern void *ios_jit_rx_base_global; extern size_t ios_jit_pool_size_global;
    extern int ios_jit_pool_image_pc(uintptr_t pc, uintptr_t *pe_addr_out);
    extern int ios_jit_low_contains( uintptr_t a );   /* madeira-bcd pool-low: region C, FEX code only */
    unsigned cls[3] = {0, 0, 0};
    struct { uint64_t key; unsigned n; } ib[48], xnb[48], jb[64]; int nib = 0, nnb = 0, njb = 0;   /* ml1124: jb = JIT host pc /64 */
    memset( rb, 0, sizeof(rb) ); memset( hb, 0, sizeof(hb) );
    memset( b, 0, sizeof(b) );
    for (pass = 0; pass < ML979_PASSES; pass++) {
        int t;
        for (t = 0; t < ntg; t++) {
            arm_thread_state64_t st; mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
            uint64_t bb = 0, rip; const char *why = "";
            thread_basic_info_data_t bi; mach_msg_type_number_t bic = THREAD_BASIC_INFO_COUNT; int running = 0;
            if (thread_info( tg[t], THREAD_BASIC_INFO, (thread_info_t)&bi, &bic ) == KERN_SUCCESS) running = (bi.run_state == TH_STATE_RUNNING);
            if (thread_suspend( tg[t] ) != KERN_SUCCESS) continue;
            /* ml981: read the guest RIP DIRECTLY out of the FEX frame, not via
             * ios_native_rip_from_hostpc().
             *
             * That helper infers the guest RIP from the HOST pc plus block
             * metadata, which only works when the pc happens to sit inside a
             * block whose tail is intact -- at arbitrary sampling points it is
             * usually in a dispatcher or thunk instead, and it returns 0 with
             * reasons like "hostPC outside block". ml980 measured that directly:
             * 6 profiles found 2-3 guest threads each and resolved ZERO RIPs.
             * The ml876 sampler has the same weakness (2 resolutions in an
             * entire run), which is why the earlier data was so sparse.
             *
             * The SEGV handler does not infer: it reads the frame, whose layout
             * it documents as "+0x18 rip, then gregs[0..15]". Do the same -- one
             * 8-byte read at x28+0x18 is authoritative wherever the host pc is. */
            if (thread_get_state( tg[t], ARM_THREAD_STATE64, (thread_state_t)&st, &cnt ) == KERN_SUCCESS
                && ios_ts_read( st.__x[28] + 0x18, &bb, 8 )
                && (rip = bb) > 0x10000 && rip < 0x8000000000ull)
            {
                total++;
                if (rip < lo) lo = rip;
                if (rip > hi) hi = rip;
                for (i = 0; i < nb; i++) if (b[i].base == (rip & ~(ML979_GRAIN - 1))) { b[i].n++; break; }
                if (i == nb) {
                    if (nb < ML979_BUCKETS) { b[nb].base = rip & ~(ML979_GRAIN - 1); b[nb].n = 1; nb++; distinct++; }
                    else dropped++;
                }
                if (running) {   /* ml1123: host-pc class */
                    uintptr_t rx0 = (uintptr_t)ios_jit_rx_base_global, pe_at = 0; int c;
                    if (st.__pc >= rx0 && st.__pc < rx0 + ios_jit_pool_size_global)
                        c = ios_jit_pool_image_pc( st.__pc, &pe_at ) ? 1 : 0;
                    else if (ios_jit_low_contains( st.__pc )) c = 0;
                    else c = 2;
                    cls[c]++;
                    if (c == 0) {   /* ml1124 */
                        uint64_t key = st.__pc & ~0x3full; int q;
                        for (q = 0; q < njb; q++) if (jb[q].key == key) { jb[q].n++; break; }
                        if (q == njb && njb < 64) { jb[njb].key = key; jb[njb].n = 1; njb++; }
                    }
                    if (c == 1) {
                        uint64_t key = pe_at & ~0xffull; int q;
                        for (q = 0; q < nib; q++) if (ib[q].key == key) { ib[q].n++; break; }
                        if (q == nib && nib < 48) { ib[nib].key = key; ib[nib].n = 1; nib++; }
                    } else if (c == 2) {
                        uint64_t key = st.__pc & ~0x3full; int q;
                        for (q = 0; q < nnb; q++) if (xnb[q].key == key) { xnb[q].n++; break; }
                        if (q == nnb && nnb < 48) { xnb[nnb].key = key; xnb[nnb].n = 1; nnb++; }
                    }
                }
                if (running) {   /* ml1111 */
                    uint64_t k = rip & ~(ML979_GRAIN - 1), hp = st.__pc & ~(ML979_GRAIN - 1);
                    rtotal++;
                    for (i = 0; i < nrb; i++) if (rb[i].base == k) { rb[i].n++; break; }
                    if (i == nrb && nrb < ML979_BUCKETS) { rb[nrb].base = k; rb[nrb].n = 1; nrb++; }
                    if (rip < 0x140000000ull || rip >= 0x148000000ull) {   /* not in the game image: native callee */
                        htotal++;
                        for (i = 0; i < nhb; i++) if (hb[i].base == hp) { hb[i].n++; break; }
                        if (i == nhb && nhb < ML979_BUCKETS) { hb[nhb].base = hp; hb[nhb].n = 1; nhb++; }
                        /* ml1115: a trap stub tells nothing by itself; keep the CALLER (lr)
                         * and the trap number (x16) of the first few samples per bucket. */
                        if (i < nhb && hcaller_n < 24) { hcaller[hcaller_n].pc = hp; hcaller[hcaller_n].lr = st.__lr; hcaller[hcaller_n].x16 = st.__x[16]; hcaller_n++; }
                    }
                }
            }
            thread_resume( tg[t] );
        }
        usleep( 5000 );                       /* 200 x 5ms = ~1s of profiling */
    }
    for (i = 0; i < ntg; i++) mach_port_deallocate( mach_task_self(), tg[i] );
    if (!total) {
        wine_log_write( "[rip-profile] ml981 gen=%d: %d guest thread(s) but no RIP resolved", gen, ntg );
        return;
    }

    /* crude descending sort, tiny N */
    for (i = 0; i < nb; i++) { int j, m = i; for (j = i + 1; j < nb; j++) if (b[j].n > b[m].n) m = j;
        if (m != i) { uint64_t tb = b[i].base; unsigned tn = b[i].n; b[i] = b[m]; b[m].base = tb; b[m].n = tn; } }

    {
        char line[900]; int n;
        n = snprintf( line, sizeof(line),
                      "[rip-profile] ml981 gen=%d threads=%d samples=%u buckets=%u%s span=0x%llx [%#llx..%#llx] top:",
                      gen, ntg, total, distinct, dropped ? "(+overflow)" : "",
                      (unsigned long long)(hi - lo), (unsigned long long)lo, (unsigned long long)hi );
        for (i = 0; i < nb && i < 8 && n < (int)sizeof(line) - 60; i++)
            n += snprintf( line + n, sizeof(line) - n, " %#llx=%u%%",
                           (unsigned long long)b[i].base, (b[i].n * 100) / total );
        wine_log_write( "%s", line );
        /* ml1111: RUNNING-only histograms (CPU profile), guest RIP then host pc */
        for (i = 0; i < nrb; i++) { int j, m = i; for (j = i + 1; j < nrb; j++) if (rb[j].n > rb[m].n) m = j;
            if (m != i) { uint64_t tb = rb[i].base; unsigned tn = rb[i].n; rb[i] = rb[m]; rb[m].base = tb; rb[m].n = tn; } }
        for (i = 0; i < nhb; i++) { int j, m = i; for (j = i + 1; j < nhb; j++) if (hb[j].n > hb[m].n) m = j;
            if (m != i) { uint64_t tb = hb[i].base; unsigned tn = hb[i].n; hb[i] = hb[m]; hb[m].base = tb; hb[m].n = tn; } }
        n = snprintf( line, sizeof(line), "[rip-profile] ml1111 RUNNING samples=%u (%u%% of all) guest top:", rtotal, total ? rtotal * 100 / total : 0 );
        for (i = 0; i < nrb && i < 10 && n < (int)sizeof(line) - 60; i++)
            n += snprintf( line + n, sizeof(line) - n, " %#llx=%u%%", (unsigned long long)rb[i].base, rtotal ? (rb[i].n * 100) / rtotal : 0 );
        wine_log_write( "%s", line );
        n = snprintf( line, sizeof(line), "[rip-profile] ml1111 RUNNING in native callees=%u (%u%% of running) host pc top:", htotal, rtotal ? htotal * 100 / rtotal : 0 );
        for (i = 0; i < nhb && i < 10 && n < (int)sizeof(line) - 60; i++)
            n += snprintf( line + n, sizeof(line) - n, " %#llx=%u%%", (unsigned long long)hb[i].base, htotal ? (hb[i].n * 100) / htotal : 0 );
        wine_log_write( "%s", line );
        /* ml1112: name the native host pcs (dladdr covers the shared cache and our
         * dylib; pool addresses stay numeric, symbolise them from the [jit-pool]
         * image table + llvm-objdump --syms offline). */
        for (i = 0; i < nhb && i < 6; i++) {
            Dl_info di;
            if (dladdr( (void *)(uintptr_t)hb[i].base, &di ) && di.dli_fname) {
                const char *f = strrchr( di.dli_fname, '/' );
                wine_log_write( "[rip-profile] ml1112 host %#llx = %s`%s+0x%llx", (unsigned long long)hb[i].base, f ? f + 1 : di.dli_fname,
                                di.dli_sname ? di.dli_sname : "?", (unsigned long long)(hb[i].base - (uintptr_t)(di.dli_saddr ? di.dli_saddr : di.dli_fbase)) );
            }
        }
        {   /* ml1123: the CPU split */
            unsigned tot = cls[0] + cls[1] + cls[2];
            for (i = 0; i < nib; i++) { int j, m = i; for (j = i + 1; j < nib; j++) if (ib[j].n > ib[m].n) m = j;
                if (m != i) { uint64_t tk = ib[i].key; unsigned tn = ib[i].n; ib[i] = ib[m]; ib[m].key = tk; ib[m].n = tn; } }
            for (i = 0; i < nnb; i++) { int j, m = i; for (j = i + 1; j < nnb; j++) if (xnb[j].n > xnb[m].n) m = j;
                if (m != i) { uint64_t tk = xnb[i].key; unsigned tn = xnb[i].n; xnb[i] = xnb[m]; xnb[m].key = tk; xnb[m].n = tn; } }
            wine_log_write( "[cpu-split] ml1123 gen=%d running samples=%u: x64 JIT %u%%, ARM64EC images %u%%, native %u%%", gen, tot,
                            tot ? cls[0] * 100 / tot : 0, tot ? cls[1] * 100 / tot : 0, tot ? cls[2] * 100 / tot : 0 );
            for (i = 0; i < njb; i++) { int j, m = i; for (j = i + 1; j < njb; j++) if (jb[j].n > jb[m].n) m = j;
                if (m != i) { uint64_t tk = jb[i].key; unsigned tn = jb[i].n; jb[i] = jb[m]; jb[m].key = tk; jb[m].n = tn; } }
            n = snprintf( line, sizeof(line), "[cpu-split] ml1124 JIT host-pc top (/64, %d distinct):", njb );
            for (i = 0; i < njb && i < 16 && n < (int)sizeof(line) - 40; i++)
                n += snprintf( line + n, sizeof(line) - n, " %#llx=%u", (unsigned long long)jb[i].key, jb[i].n );
            wine_log_write( "%s", line );
            for (i = 0; i < njb && i < 6; i++) {   /* the hottest compiled code itself, for offline disassembly */
                uint32_t code[48]; int k2;
                if (jb[i].n < 2 || !ios_ts_read( jb[i].key - 64, code, sizeof(code) )) continue;
                n = snprintf( line, sizeof(line), "[cpu-split] ml1124 JIT code @%#llx-64 (%u):", (unsigned long long)jb[i].key, jb[i].n );
                for (k2 = 0; k2 < 48 && n < (int)sizeof(line) - 12; k2++) n += snprintf( line + n, sizeof(line) - n, " %08x", code[k2] );
                wine_log_write( "%s", line );
            }
            n = snprintf( line, sizeof(line), "[cpu-split] ml1123 image top (PE address/256):" );
            for (i = 0; i < nib && i < 14 && n < (int)sizeof(line) - 40; i++)
                n += snprintf( line + n, sizeof(line) - n, " %#llx=%u", (unsigned long long)ib[i].key, ib[i].n );
            wine_log_write( "%s", line );
            n = snprintf( line, sizeof(line), "[cpu-split] ml1123 native top:" );
            for (i = 0; i < nnb && i < 10 && n < (int)sizeof(line) - 120; i++) {
                Dl_info di; const char *f = "?", *sn = "?"; unsigned long long off = 0;
                if (dladdr( (void *)(uintptr_t)xnb[i].key, &di )) {
                    if (di.dli_fname) { f = strrchr( di.dli_fname, '/' ); f = f ? f + 1 : di.dli_fname; }
                    if (di.dli_sname) { sn = di.dli_sname; off = xnb[i].key - (uintptr_t)di.dli_saddr; }
                }
                n += snprintf( line + n, sizeof(line) - n, " %s`%s+%#llx=%u", f, sn, off, xnb[i].n );
            }
            wine_log_write( "%s", line );
        }
        /* ml1115: callers of the native samples, symbolised */
        for (i = 0; i < hcaller_n; i++) {
            Dl_info dp, dl; const char *pn = "?", *ln = "?";
            if (dladdr( (void *)(uintptr_t)hcaller[i].pc, &dp ) && dp.dli_sname) pn = dp.dli_sname;
            if (dladdr( (void *)(uintptr_t)hcaller[i].lr, &dl ) && dl.dli_sname) ln = dl.dli_sname;
            wine_log_write( "[rip-profile] ml1115 native sample pc=%#llx (%s) x16=%lld lr=%#llx (%s)", (unsigned long long)hcaller[i].pc, pn,
                            (long long)hcaller[i].x16, (unsigned long long)hcaller[i].lr, ln );
        }
        /* ml1112: for the hottest RUNNING guest buckets, resolve every `call [rip+disp]`
         * (ff 15) in the bucket: the IAT slot and the pointer in it name the import
         * the game is inside (the RIP of a thread in an ARM64EC callee stays at the
         * call site). */
        /* ml1112b: once per run, how to read the RUNNING histogram -- the 2026-10-01
         * God of War log was first read as "43 % of the CPU inside Sleep and
         * GetCurrentThreadId"; [cpu-split] of the same profiles put only 1-6 % of
         * the host pcs in ARM64EC images and most of the rest in sched_yield. */
        {
            static int said;
            if (!said++)
                wine_log_write( "[rip-profile] ml1112b note: RUNNING = Mach TH_STATE_RUNNING, i.e. on a core OR queued for one; "
                                "the guest RIP is FEX's last synchronised RIP (it moves at calls into ARM64EC code and dispatcher "
                                "exits, not per x64 instruction), so a bucket at an IAT call means 'last left the JIT there'. "
                                "[cpu-split] gives where the host pc really was." );
        }
        for (i = 0; i < nrb && i < 6; i++) {
            unsigned char code[80]; int k;
            uint64_t img_rva = 0, img_base = 0;
            if (rb[i].base < 0x140000000ull || rb[i].base >= 0x148000000ull) continue;
            if (!ios_ts_read( rb[i].base, code, sizeof(code) )) continue;
            if (ios_ts_mod_for( ios_ts_map_for_teb( rp_teb ), rb[i].base, &img_rva )) img_base = rb[i].base - img_rva;
            for (k = 0; k + 6 <= 64; k++) {
                if (code[k] == 0xff && code[k + 1] == 0x15) {
                    int32_t disp; uint64_t slot, target = 0;
                    char callee[160] = "", imp[120] = "";
                    memcpy( &disp, code + k + 2, 4 );
                    slot = rb[i].base + k + 6 + (int64_t)disp;
                    ios_ts_read( slot, &target, 8 );
                    /* ml1112b: what the slot imports (the caller's import table) and
                     * what the pointer in it is (the callee's export table) */
                    if (target) ios_rp_name_target( rp_teb, target, callee, sizeof(callee) );
                    if (img_base) ios_rp_import_name( img_base, slot, imp, sizeof(imp) );
                    wine_log_write( "[rip-profile] ml1112 bucket %#llx: call [%#llx] -> %#llx%s%s%s%s%s (%u%% of running)",
                                    (unsigned long long)rb[i].base, (unsigned long long)slot, (unsigned long long)target,
                                    callee[0] ? " = " : "", callee, imp[0] ? " (import " : "", imp, imp[0] ? ")" : "",
                                    rtotal ? (rb[i].n * 100) / rtotal : 0 );
                }
            }
        }
        /* ml1110: the guest code at the hottest buckets, so the loop can be read
         * (x86-64 bytes; disassemble offline). Only guest-image addresses. */
        for (i = 0; i < nb && i < 6; i++) {
            unsigned char code[64]; int k;
            if (b[i].base < 0x140000000ull || b[i].base >= 0x7f0000000000ull) continue;
            if (!ios_ts_read( b[i].base, code, sizeof(code) )) continue;
            n = snprintf( line, sizeof(line), "[rip-profile] ml1110 code @%#llx (%u%%):", (unsigned long long)b[i].base, (b[i].n * 100) / total );
            for (k = 0; k < 64 && n < (int)sizeof(line) - 4; k++) n += snprintf( line + n, sizeof(line) - n, " %02x", code[k] );
            wine_log_write( "%s", line );
        }
    }
}

/* ml1128: TRANSITION PROBE (measurement only; changes no behaviour).
 * RDR2 holds 60 fps for 7-10 s after the full scene appears, then drops to
 * 25-35 with GPU time per frame unchanged (ph-rdr79/80/81, HANDOFF §117). The
 * 20 s thread-sample bursts never landed in the fast window. Every 250 ms this
 * records, on one clock:
 *  - process counters (proc_pid_rusage v6): CPU time, P-core time, runnable
 *    time, page-wait time, instructions/cycles (total and P), energy;
 *  - for EVERY thread, PROC_PIDTHREADCOUNTS: time/instructions/cycles per perf
 *    level, so a thread moving from P to E cores, running at a lower clock, or
 *    retiring more instructions per frame is visible directly;
 *  - madeira_d3d12's counters (MadeiraCtl op 5): Present enqueues and
 *    completions, worker time per job kind, and inside Present the flush,
 *    frame-latency GPU wait, nextDrawable and commit times.
 * Roles (MadeiraCtl op 4, registered by the thread itself): W = submission
 * worker, P = Present caller, E = ExecuteCommandLists caller.
 * Units: rusage and thread times are Mach ticks; the [xp] line prints both the
 * rusage CPU time and the per-thread sum so the conversion can be checked. */
#include <sys/resource.h>
#include <sys/sysctl.h>
extern int proc_pid_rusage( int pid, int flavor, void *buffer );
extern int proc_pidinfo( int pid, int flavor, uint64_t arg, void *buffer, int buffersize );
volatile uint64_t ios_xp_pe_block, ios_xp_pe_len;
static struct { uint64_t tid; uint32_t wtid; char role[6]; } ios_xp_roles[32];
static volatile int ios_xp_nroles;
static pthread_mutex_t ios_xp_role_lock = PTHREAD_MUTEX_INITIALIZER;
void ios_xp_set_role( int role, uint64_t wtid )
{
    uint64_t tid = 0; int i, n;
    pthread_threadid_np( NULL, &tid );
    pthread_mutex_lock( &ios_xp_role_lock );
    n = ios_xp_nroles;
    for (i = 0; i < n; i++) if (ios_xp_roles[i].tid == tid) break;
    if (i == n && n < 32) { ios_xp_roles[n].tid = tid; ios_xp_roles[n].wtid = (uint32_t)wtid; ios_xp_roles[n].role[0] = 0; ios_xp_nroles = n + 1; }
    if (i < 32) { size_t l = strlen( ios_xp_roles[i].role ); if (l < 5 && !strchr( ios_xp_roles[i].role, role )) { ios_xp_roles[i].role[l] = (char)role; ios_xp_roles[i].role[l + 1] = 0; } }
    pthread_mutex_unlock( &ios_xp_role_lock );
    wine_log_write( "[xp] ml1128 role %c = thread %llu (win tid %04x)", role, (unsigned long long)tid, (unsigned)wtid );
}
struct ios_xp_pe { int64_t magic, qpf, pres_enq, pres_done, t_thr, n_ecl, t_ecl, n_sig, t_sig, n_wait, t_wait, t_prs,
                   t_flush, n_lat, t_lat, t_draw, t_cmt, t_pool, ecl_calls, t_ecl_caller; };
struct ios_xp_tcd { uint64_t instr, cyc, ut, st, nj; };
struct ios_xp_tc { uint16_t len, r0; uint32_t r1; struct ios_xp_tcd c[4]; };
struct ios_xp_prev { uint64_t tid; uint32_t gen; struct ios_xp_tcd c[2]; };
struct ios_xp_row { uint64_t tid; uint32_t wtid; double p_ms, e_ms, p_ghz, e_ghz, minst; const char *role; };
static struct ios_xp_prev ios_xp_tab[2048];

/* ml1131: [xp-api] REPORTER (measurement only). Once a second, from the xprobe
 * thread: FEX's x64->EC transition counters and sampled call targets (exported
 * IosXpFex in xtajit64.dll), the PE ntdll's contended-lock / wait-on-address /
 * QPC-gap counters (exported ios_xp_nt), and the unix sync syscall counters.
 * Everything is found through the GAME process's own loader list (private map,
 * not the thread sampler's shared cache, which that sampler resets every pass)
 * and read with vm_read_overwrite, so an unloaded module cannot fault us. */
struct ios_xp_nt_view_qpc { uint32_t tid, pad; uint64_t last, calls, hist[5]; };
struct ios_xp_nt_view
{
    uint64_t magic, freq;
    int64_t cs_contended, cs_contended_spin0, cs_spin_acquired, cs_wait_ticks, cs_wait_hist[6], cs_wakes;
    int64_t woa_waits, woa_wake_single, woa_wake_all, cs_ring_idx;
    uint64_t cs_ring[1024];
    struct ios_xp_nt_view_qpc qpc[256];
};
#define IOS_XP_FEX_WORDS 4496
struct ios_xp_mod { uint64_t base, size; char name[40]; };
static struct ios_xp_mod ios_xp_mods[160];
static int ios_xp_nmods;
static uint64_t ios_xp_peb, ios_xp_heap, ios_xp_fex_addr, ios_xp_nt_addr;
static volatile uint64_t ios_xp_game_teb;   /* set by the xprobe loop from a P/E role thread */

/* madeira-bcd ml1131c: the game process for a title with no D3D12 roles.
 *
 * ios_xp_game_teb came only from a thread madeira_d3d12 registered as P or E,
 * so for a D3D11 game (God of War through DXMT) the module map was never built
 * and [xp-api] printed "x64->EC 0/s" with no [xp-api-top] / -qpc / -cs lines:
 * FEX's x64->EC counters and ntdll's QPC / critical-section / WaitOnAddress
 * counters existed but were never found. Without roles, every ~10 s the Wine
 * process (PEB) whose threads used the most CPU in that window supplies the
 * TEB; when that process changes (boot helpers first, then the game), the
 * counter blocks are looked up again in the new one. Measurement only: this
 * runs on the xprobe thread, which is also the only reader of these globals. */
static struct { uint64_t peb, teb; double ms; } ios_xp_fb[8];
static int ios_xp_nfb;
static uint64_t ios_xp_fb_peb;        /* the process the fallback currently follows */
static volatile unsigned ios_xp_rebind;   /* bumped on a switch; the reporter restarts its deltas */
static void ios_xp_fallback_add( uint64_t teb, double ms )
{
    uint64_t peb = 0; int i;
    if (!ios_ts_read( teb + 0x60, &peb, 8 ) || !peb) return;
    for (i = 0; i < ios_xp_nfb; i++) if (ios_xp_fb[i].peb == peb) break;
    if (i == ios_xp_nfb)
    {
        if (ios_xp_nfb >= 8) return;
        ios_xp_fb[i].peb = peb; ios_xp_fb[i].ms = 0; ios_xp_fb[i].teb = teb; ios_xp_nfb++;
    }
    ios_xp_fb[i].ms += ms;
    ios_xp_fb[i].teb = teb;   /* any live thread of that process will do */
}
static void ios_xp_fallback_pick( void )
{
    int i, best = -1;
    for (i = 0; i < ios_xp_nfb; i++) if (best < 0 || ios_xp_fb[i].ms > ios_xp_fb[best].ms) best = i;
    if (best >= 0 && !ios_xp_nroles && ios_xp_fb[best].peb != ios_xp_fb_peb)
    {
        ios_xp_fb_peb = ios_xp_fb[best].peb;
        ios_xp_game_teb = ios_xp_fb[best].teb;
        ios_xp_fex_addr = ios_xp_nt_addr = 0;
        ios_xp_rebind++;
        wine_log_write( "[xp-api] ml1131c no D3D12 role threads: counters follow the busiest Wine process "
                        "(peb 0x%llx via teb 0x%llx, %.0f ms CPU in the last 10 s)",
                        (unsigned long long)ios_xp_fb_peb, (unsigned long long)ios_xp_game_teb, ios_xp_fb[best].ms );
    }
    else if (best >= 0 && !ios_xp_nroles) ios_xp_game_teb = ios_xp_fb[best].teb;   /* same process, a thread that is alive now */
    ios_xp_nfb = 0;
}

struct ios_xp_expc { uint64_t base; uint32_t exp_rva, exp_size, nfunc, nname; uint32_t *funcs, *names; uint16_t *ords; };
static struct ios_xp_expc ios_xp_expcache[32];
static int ios_xp_nexpc;

static void ios_xp_modmap( uint64_t teb )
{
    uint64_t peb = 0, ldr = 0, head, cur; int guard = 0, n = 0;
    if (!teb || !ios_ts_read( teb + 0x60, &peb, 8 ) || !peb || !ios_ts_read( peb + 0x18, &ldr, 8 ) || !ldr) return;
    ios_ts_read( peb + 0x30, &ios_xp_heap, 8 );
    head = ldr + 0x10;
    if (!ios_ts_read( head, &cur, 8 )) return;
    while (cur && cur != head && guard++ < 400 && n < 160)
    {
        uint64_t base = 0, buf = 0, next = 0; uint32_t size = 0; uint16_t len = 0, w[40]; int k;
        if (!ios_ts_read( cur + 0x30, &base, 8 ) || !ios_ts_read( cur + 0x40, &size, 4 ) ||
            !ios_ts_read( cur + 0x58, &len, 2 ) || !ios_ts_read( cur + 0x60, &buf, 8 )) break;
        if (base && size)
        {
            struct ios_xp_mod *m = &ios_xp_mods[n++];
            m->base = base; m->size = size; len /= 2; if (len > 39) len = 39;
            if (len && ios_ts_read( buf, w, len * 2 )) { for (k = 0; k < len; k++) m->name[k] = w[k] < 128 ? (char)tolower( w[k] ) : '?'; m->name[len] = 0; }
            else strcpy( m->name, "?" );
        }
        if (!ios_ts_read( cur, &next, 8 )) break;
        cur = next;
    }
    ios_xp_nmods = n; ios_xp_peb = peb;
}
static struct ios_xp_mod *ios_xp_mod_by_name( const char *name )
{
    int i;
    for (i = 0; i < ios_xp_nmods; i++) if (!strcmp( ios_xp_mods[i].name, name )) return &ios_xp_mods[i];
    return NULL;
}
static struct ios_xp_mod *ios_xp_mod_by_addr( uint64_t a )
{
    int i;
    for (i = 0; i < ios_xp_nmods; i++) if (a >= ios_xp_mods[i].base && a < ios_xp_mods[i].base + ios_xp_mods[i].size) return &ios_xp_mods[i];
    return NULL;
}
static struct ios_xp_expc *ios_xp_exports( uint64_t base )
{
    struct ios_xp_expc *c; uint32_t lfanew = 0, dir[2] = {0}, ed[10];
    int i;
    for (i = 0; i < ios_xp_nexpc; i++) if (ios_xp_expcache[i].base == base) return &ios_xp_expcache[i];
    if (ios_xp_nexpc >= 32) return NULL;
    if (!ios_ts_read( base + 0x3c, &lfanew, 4 ) || lfanew > 0x1000) return NULL;
    if (!ios_ts_read( base + lfanew + 24 + 112, dir, 8 ) || !dir[0] || dir[1] < 40) return NULL;   /* PE32+ export directory */
    if (!ios_ts_read( base + dir[0], ed, sizeof(ed) )) return NULL;
    c = &ios_xp_expcache[ios_xp_nexpc];
    memset( c, 0, sizeof(*c) );
    c->base = base; c->exp_rva = dir[0]; c->exp_size = dir[1];
    c->nfunc = ed[5] > 16384 ? 16384 : ed[5]; c->nname = ed[6] > 16384 ? 16384 : ed[6];
    c->funcs = malloc( (size_t)c->nfunc * 4 + 4 ); c->names = malloc( (size_t)c->nname * 4 + 4 ); c->ords = malloc( (size_t)c->nname * 2 + 2 );
    if (!c->funcs || !c->names || !c->ords ||
        !ios_ts_read( base + ed[7], c->funcs, (size_t)c->nfunc * 4 ) ||
        !ios_ts_read( base + ed[8], c->names, (size_t)c->nname * 4 ) ||
        !ios_ts_read( base + ed[9], c->ords, (size_t)c->nname * 2 ))
    {
        free( c->funcs ); free( c->names ); free( c->ords ); memset( c, 0, sizeof(*c) );
        return NULL;
    }
    ios_xp_nexpc++;
    return c;
}
static uint64_t ios_xp_export_addr( uint64_t base, const char *name )
{
    struct ios_xp_expc *c = ios_xp_exports( base );
    uint32_t j; size_t nl = strlen( name );
    if (!c) return 0;
    for (j = 0; j < c->nname; j++)
    {
        char buf[64];
        if (!ios_ts_read( base + c->names[j], buf, nl + 1 < sizeof(buf) ? nl + 1 : sizeof(buf) )) continue;
        if (!memcmp( buf, name, nl ) && !buf[nl] && c->ords[j] < c->nfunc) return base + c->funcs[c->ords[j]];
    }
    return 0;
}
/* "module!export" (nearest export at or below the address; "+0x.." when not exact) */
static void ios_xp_symbol( uint64_t a, char *out, size_t cap )
{
    extern int ios_jit_pool_image_pc(uintptr_t pc, uintptr_t *pe_addr_out);
    struct ios_xp_mod *m; struct ios_xp_expc *c; uintptr_t pe = 0;
    uint32_t rva, i, best = ~0u, bestrva = 0, j;
    if (ios_jit_pool_image_pc( (uintptr_t)a, &pe )) a = pe;
    if (!(m = ios_xp_mod_by_addr( a ))) { snprintf( out, cap, "0x%llx", (unsigned long long)a ); return; }
    rva = (uint32_t)(a - m->base);
    if (!(c = ios_xp_exports( m->base ))) { snprintf( out, cap, "%s+0x%x", m->name, rva ); return; }
    for (i = 0; i < c->nfunc; i++)
    {
        uint32_t f = c->funcs[i];
        if (!f || f > rva || (f >= c->exp_rva && f < c->exp_rva + c->exp_size)) continue;   /* forwarder strings */
        if (best == ~0u || f > bestrva) { best = i; bestrva = f; }
    }
    if (best == ~0u) { snprintf( out, cap, "%s+0x%x", m->name, rva ); return; }
    for (j = 0; j < c->nname; j++)
        if (c->ords[j] == best)
        {
            char nm[64] = {0};
            ios_ts_read( m->base + c->names[j], nm, sizeof(nm) - 1 );
            nm[sizeof(nm) - 1] = 0;
            if (rva == bestrva) snprintf( out, cap, "%s!%s", m->name, nm );
            else snprintf( out, cap, "%s!%s+0x%x", m->name, nm, rva - bestrva );
            return;
        }
    snprintf( out, cap, "%s!#%u+0x%x", m->name, best, rva - bestrva );
}
static int ios_xp_cmp_u64( const void *a, const void *b )
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

/* Madeira [spin] ml1140 -- a guest thread that makes millions of the same cheap call a second.
 *
 * A .NET game: about 10 s after the process starts, one or two threads of the .NET runtime call GetLastError /
 * SetLastError 12-19 million times a second for as long as the log goes on, with no window and no syscall in between
 * ([xp-api] x64->EC, [xp-api-top] names only the callee). [thread-sample] puts them inside the runtime's own code,
 * but the older [spin] ml677 snapshot (signal_arm64_ios.c, ios_dump_all_thread_stacks)
 * keys on ONE 4 KB host-pc window and a loop that alternates between FEX's code cache and the ARM64EC copy of
 * kernelbase / ntdll never sits in one: it printed nothing. This one keys on what the xprobe already measures: the
 * x64->EC call rate with one target taking nearly all of the sampled calls, for several reports in a row.
 *
 * It runs on the xprobe thread (the only reader of these counters), once a second does nothing but compare two numbers;
 * on the first hit it looks at the one or two Wine threads that used >= 80% of a core: their registers (the ARM64EC
 * register mapping, as [x86_live]), the x86 code around the guest RIP, and the return addresses on the x86 stack that
 * have a CALL right before them, with module and offset. Twice at most for one streak (4 s and 20 s: does the loop
 * move?), three looks a run. With MADEIRA_LEAN_DIAG no thread is touched: one line only. Off the hot path: nothing runs
 * in the game's threads and nothing is recorded per call. env.MADEIRA_SPIN_DIAG=0 turns [spin] off altogether. */
static int ios_lean_diag;   /* defined with the sampler below */

/* [spin] helpers: pure functions, no thread or memory access */
#define IOS_SPIN_RATE   5.0e6     /* x64->EC calls per second, all threads */
#define IOS_SPIN_SHARE  0.80      /* of the sampled call targets, the same one */
#define IOS_SPIN_SECS   4         /* consecutive reports (about 1 s each) */
#define IOS_SPIN_AGAIN  20        /* a second look at the same streak */
#define IOS_SPIN_SHOTS  3         /* looks per run */
struct ios_spin_state { uint64_t callee; int streak, shots; };

/* One report in, 0 (nothing), 1 (first look) or 2 (second look) out. */
static int ios_spin_step( struct ios_spin_state *s, double rate, uint64_t top, double share )
{
    if (rate < IOS_SPIN_RATE || !top || share < IOS_SPIN_SHARE) { s->callee = 0; s->streak = 0; return 0; }
    if (top != s->callee) { s->callee = top; s->streak = 0; }
    s->streak++;
    if (s->shots >= IOS_SPIN_SHOTS) return 0;
    if (s->streak == IOS_SPIN_SECS) { s->shots++; return 1; }
    if (s->streak == IOS_SPIN_AGAIN) { s->shots++; return 2; }
    return 0;
}

/* b: the 8 bytes right before an address v. A return address has a CALL immediately before it: E8 rel32 (5 bytes), or
 * FF /2 (2 to 7 bytes, whose length the ModRM / SIB / displacement say). NULL: not preceded by a call. */
static const char *ios_spin_call_kind( const unsigned char b[8] )
{
    int len;
    if (b[3] == 0xe8) return "call rel32";
    for (len = 2; len <= 7; len++)
    {
        const unsigned char *p = b + 8 - len;
        int mod, rm, want;
        if (p[0] != 0xff || ((p[1] >> 3) & 7) != 2) continue;
        mod = p[1] >> 6; rm = p[1] & 7;
        if (mod == 3) want = 2;
        else if (mod == 0) want = rm == 5 ? 6 : rm == 4 ? ((len >= 3 && (p[2] & 7) == 5) ? 7 : 3) : 2;
        else if (mod == 1) want = rm == 4 ? 4 : 3;
        else want = rm == 4 ? 7 : 6;
        if (want == len) return "call indirect";
    }
    return NULL;
}

static void ios_spin_hex( const unsigned char *b, int n, char *out )
{
    int i;
    for (i = 0; i < n; i++) { out[i * 3] = "0123456789abcdef"[b[i] >> 4]; out[i * 3 + 1] = "0123456789abcdef"[b[i] & 15]; out[i * 3 + 2] = ' '; }
    out[n ? n * 3 - 1 : 0] = 0;
}
/* end of the [spin] helpers */

/* The module list of the process a TEB belongs to, into a caller-owned array (the xprobe's own map follows ONE process and
 * the sampler's is shared with another thread). */
static int ios_spin_modmap( uint64_t teb, struct ios_xp_mod *out, int cap )
{
    uint64_t peb = 0, ldr = 0, head, cur; int guard = 0, n = 0;
    if (!teb || !ios_ts_read( teb + 0x60, &peb, 8 ) || !peb || !ios_ts_read( peb + 0x18, &ldr, 8 ) || !ldr) return 0;
    head = ldr + 0x10;
    if (!ios_ts_read( head, &cur, 8 )) return 0;
    while (cur && cur != head && guard++ < 400 && n < cap)
    {
        uint64_t base = 0, buf = 0, next = 0; uint32_t size = 0; uint16_t len = 0, w[40]; int k;
        if (!ios_ts_read( cur + 0x30, &base, 8 ) || !ios_ts_read( cur + 0x40, &size, 4 ) ||
            !ios_ts_read( cur + 0x58, &len, 2 ) || !ios_ts_read( cur + 0x60, &buf, 8 )) break;
        if (base && size)
        {
            struct ios_xp_mod *m = &out[n++];
            m->base = base; m->size = size; len /= 2; if (len > 39) len = 39;
            if (len && ios_ts_read( buf, w, len * 2 )) { for (k = 0; k < len; k++) m->name[k] = w[k] < 128 ? (char)tolower( w[k] ) : '?'; m->name[len] = 0; }
            else strcpy( m->name, "?" );
        }
        if (!ios_ts_read( cur, &next, 8 )) break;
        cur = next;
    }
    return n;
}
static void ios_spin_where( const struct ios_xp_mod *mods, int n, uint64_t a, char *out, size_t cap )
{
    int i;
    for (i = 0; i < n; i++)
        if (a >= mods[i].base && a < mods[i].base + mods[i].size) { snprintf( out, cap, "%s+0x%llx", mods[i].name, (unsigned long long)(a - mods[i].base) ); return; }
    snprintf( out, cap, "no module" );
}

static void ios_spin_capture( const char *wall, int look, double rate, double share, int streak, uint64_t top, const char *top_sym )
{
    extern int ios_jit_pool_image_pc( uintptr_t pc, uintptr_t *pe_addr_out );
    extern uint64_t ios_native_rip_from_hostpc( uint64_t, uint64_t, const char ** );
    mach_port_t self_port = pthread_mach_thread_np( pthread_self() );
    thread_act_array_t tl; mach_msg_type_number_t tc; unsigned k; int seen = 0;
    static struct ios_xp_mod mods[160];

    wine_log_write( "[spin] ml1140 %s look %d: x64->EC %.0f/s, %.0f%% of the sampled calls for %d s go to %s (0x%llx)%s",
                    wall, look, rate, share * 100.0, streak, top_sym, (unsigned long long)top,
                    ios_lean_diag ? "; MADEIRA_LEAN_DIAG: no thread is looked at" : "" );
    if (ios_lean_diag) return;
    if (task_threads( mach_task_self(), &tl, &tc ) != KERN_SUCCESS) return;
    for (k = 0; k < tc && seen < 2; k++)
    {
        thread_basic_info_data_t bi; mach_msg_type_number_t bic = THREAD_BASIC_INFO_COUNT;
        arm_thread_state64_t st; mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
        uint64_t teb, frame[16], rip_exact = 0, rip_state = 0, rsp = 0, stack_base = 0, stack_limit = 0, bb = 0, stk[96];
        unsigned char code[128], before[8];
        int have_frame, have_code, have_stk, nmods, cand, wtid = 0, ni;
        const char *why = "", *rsp_note = "";
        pthread_t pt;
        uint64_t cands[3];
        char where[96], rwhere[96], hex[128 * 3 + 4], line[1000];
        if (tl[k] == self_port) continue;
        if (thread_info( tl[k], THREAD_BASIC_INFO, (thread_info_t)&bi, &bic ) != KERN_SUCCESS || bi.cpu_usage < 800) continue;
        pt = pthread_from_mach_thread_np( tl[k] );   /* before the suspend: libpthread's list lock must never be taken by a suspended thread's owner */
        if (!(teb = ios_ts_teb( pt ))) continue;
        if (thread_suspend( tl[k] ) != KERN_SUCCESS) continue;
        if (thread_get_state( tl[k], ARM_THREAD_STATE64, (thread_state_t)&st, &cnt ) != KERN_SUCCESS) { thread_resume( tl[k] ); continue; }
        /* Everything read here is a plain read of a few hundred bytes (vm_read_overwrite, no lock): the thread is held for
         * microseconds. */
        have_frame = st.__x[28] > 0x10000 && ios_ts_read( st.__x[28] + 0x18, frame, sizeof(frame) );
        ios_ts_read( st.__x[28], &bb, 8 );
        ios_ts_read( teb + 0x08, &stack_base, 8 );
        ios_ts_read( teb + 0x10, &stack_limit, 8 );
        ios_ts_read( teb + 0x48, &wtid, 4 );
        {   /* the x86 RSP: x23 while the thread runs FEX-translated code, sp while it runs ARM64EC code (the guest stack is the host stack there) */
            uintptr_t pe_probe = 0;
            int in_ec = ios_jit_pool_image_pc( (uintptr_t)arm_thread_state64_get_pc( st ), &pe_probe );
            cands[0] = in_ec ? arm_thread_state64_get_sp( st ) : st.__x[23];
            cands[1] = in_ec ? st.__x[23] : arm_thread_state64_get_sp( st );
            cands[2] = have_frame ? frame[1 + 4] : 0;
        }
        for (cand = 0; cand < 3; cand++)
            if (cands[cand] >= stack_limit && cands[cand] < stack_base && !(cands[cand] & 7)) { rsp = cands[cand]; break; }
        rsp_note = rsp ? "" : " (outside the TEB's stack range: the first readable candidate)";
        for (cand = 0; cand < 3 && !rsp; cand++)   /* the TEB's range need not be the guest stack's (a WoW64 or EC stack): the first readable one, said so */
            if (cands[cand] >= 0x100000000ULL && !(cands[cand] & 7) && ios_ts_read( cands[cand], &bb, 8 )) rsp = cands[cand];
        have_stk = rsp && ios_ts_read( rsp, stk, sizeof(stk) );
        rip_state = have_frame ? frame[0] : 0;
        if (bb > 0x10000) rip_exact = ios_native_rip_from_hostpc( bb, arm_thread_state64_get_pc( st ), &why );
        have_code = 0;
        {
            uint64_t at = rip_exact ? rip_exact : rip_state;
            if (at > 64) have_code = ios_ts_read( at - 32, code, sizeof(code) );
            if (!have_code && at) { memset( code, 0, sizeof(code) ); have_code = ios_ts_read( at, code + 32, 96 ); }
        }
        thread_resume( tl[k] );
        seen++;

        nmods = ios_spin_modmap( teb, mods, 160 );
        {
            uint64_t at = rip_exact ? rip_exact : rip_state; uintptr_t pe = 0; const char *cls;
            uint64_t pc = arm_thread_state64_get_pc( st );
            ios_spin_where( mods, nmods, at, where, sizeof(where) );
            cls = ios_jit_pool_image_pc( (uintptr_t)pc, &pe ) ? "ARM64EC image copy" : "FEX code or native";
            wine_log_write( "[spin] ml1140 thread %04x teb=0x%llx cpu=%d%% host pc=0x%llx (%s) lr=0x%llx sp=0x%llx x23=0x%llx | guest RIP exact=0x%llx (%s) State.rip=0x%llx%s",
                            (unsigned)wtid, (unsigned long long)teb, bi.cpu_usage / 10, (unsigned long long)pc, cls,
                            (unsigned long long)arm_thread_state64_get_lr( st ), (unsigned long long)arm_thread_state64_get_sp( st ),
                            (unsigned long long)st.__x[23], (unsigned long long)rip_exact, rip_exact ? where : why,
                            (unsigned long long)rip_state, have_frame ? "" : " (frame unreadable)" );
        }
        /* The x86 registers by the ARM64EC mapping (as [x86_live]); exact while the thread is in translated or EC code. */
        wine_log_write( "[spin] ml1140   RAX=0x%llx RCX=0x%llx RDX=0x%llx RBX=0x%llx RSP=0x%llx RBP=0x%llx RSI=0x%llx RDI=0x%llx"
                        " R8=0x%llx R9=0x%llx R10=0x%llx R11=0x%llx R12=0x%llx R13=0x%llx R14=0x%llx R15=0x%llx",
                        (unsigned long long)st.__x[8], (unsigned long long)st.__x[0], (unsigned long long)st.__x[1], (unsigned long long)st.__x[27],
                        (unsigned long long)rsp, (unsigned long long)st.__fp, (unsigned long long)st.__x[25], (unsigned long long)st.__x[26],
                        (unsigned long long)st.__x[2], (unsigned long long)st.__x[3], (unsigned long long)st.__x[4], (unsigned long long)st.__x[5],
                        (unsigned long long)st.__x[19], (unsigned long long)st.__x[20], (unsigned long long)st.__x[21], (unsigned long long)st.__x[22] );
        {   /* Madeira [spin]: is this spin tied to a compare-and-swap on an anonymous alias? (signal_arm64_ios.c ios_anon_cas_note) */
            extern volatile unsigned long long ios_anon_cas_last_addr, ios_anon_cas_last_ms;
            extern volatile unsigned ios_anon_cas_emulated, ios_anon_cas_handed;
            if (ios_anon_cas_emulated || ios_anon_cas_handed)
            {
                const struct { const char *name; uint64_t v; } xr[] = {
                    { "RAX", st.__x[8] }, { "RCX", st.__x[0] }, { "RDX", st.__x[1] }, { "RBX", st.__x[27] }, { "RSP", rsp }, { "RBP", st.__fp },
                    { "RSI", st.__x[25] }, { "RDI", st.__x[26] }, { "R8", st.__x[2] }, { "R9", st.__x[3] }, { "R10", st.__x[4] },
                    { "R11", st.__x[5] }, { "R12", st.__x[19] }, { "R13", st.__x[20] }, { "R14", st.__x[21] }, { "R15", st.__x[22] } };
                unsigned long long last = ios_anon_cas_last_addr, page = last >> 14, now_ms;
                struct timespec ts;
                char in[120];
                int n = 0, xi;

                clock_gettime( CLOCK_MONOTONIC, &ts );
                now_ms = (unsigned long long)ts.tv_sec * 1000ull + (unsigned long long)(ts.tv_nsec / 1000000);
                in[0] = 0;
                for (xi = 0; xi < (int)(sizeof(xr) / sizeof(xr[0])); xi++)
                    if ((xr[xi].v >> 14) == page && n < (int)sizeof(in) - 12) n += snprintf( in + n, sizeof(in) - n, " %s", xr[xi].name );
                wine_log_write( "[spin] ml1140   compare-and-swaps on an anonymous RWX alias so far: %u emulated here, %u handed to FEX "
                                "(env.MADEIRA_ANON_CAS_FLUSH); the last at 0x%llx, %llu s before this look; registers inside its 16 KB page:%s",
                                ios_anon_cas_emulated, ios_anon_cas_handed, last, now_ms >= ios_anon_cas_last_ms ? (now_ms - ios_anon_cas_last_ms) / 1000 : 0ull,
                                in[0] ? in : " none" );
            }
        }
        if (have_code)
        {
            ios_spin_hex( code, (int)sizeof(code), hex );
            wine_log_write( "[spin] ml1140   x86 code from RIP-32 (RIP is byte 32): %s", hex );
        }
        else wine_log_write( "[spin] ml1140   x86 code at the guest RIP is unreadable" );
        if (have_stk)
        {
            int n = snprintf( line, sizeof(line), "[spin] ml1140   return addresses on the x86 stack (a CALL right before them) from RSP=0x%llx%s:", (unsigned long long)rsp, rsp_note ), shown = 0;
            for (ni = 0; ni < 96 && shown < 12 && n < (int)sizeof(line) - 120; ni++)
            {
                const char *kind;
                if (stk[ni] < 0x10000 || !ios_ts_read( stk[ni] - 8, before, 8 )) continue;
                if (!(kind = ios_spin_call_kind( before ))) continue;
                ios_spin_where( mods, nmods, stk[ni], rwhere, sizeof(rwhere) );
                n += snprintf( line + n, sizeof(line) - n, " sp+0x%x=%s(%s)", ni * 8, rwhere, kind );
                shown++;
            }
            if (!shown) n += snprintf( line + n, sizeof(line) - n, " none in the first %d qwords", 96 );
            wine_log_write( "%s", line );
            wine_log_write( "[spin] ml1140   first stack qwords: %llx %llx %llx %llx %llx %llx %llx %llx", (unsigned long long)stk[0], (unsigned long long)stk[1],
                            (unsigned long long)stk[2], (unsigned long long)stk[3], (unsigned long long)stk[4], (unsigned long long)stk[5],
                            (unsigned long long)stk[6], (unsigned long long)stk[7] );
        }
        else wine_log_write( "[spin] ml1140   no readable x86 stack (x23, sp and the frame's RSP: none readable; the TEB's stack is 0x%llx..0x%llx)",
                             (unsigned long long)stack_limit, (unsigned long long)stack_base );
    }
    for (k = 0; k < tc; k++) mach_port_deallocate( mach_task_self(), tl[k] );
    vm_deallocate( mach_task_self(), (vm_address_t)tl, tc * sizeof(*tl) );
    if (!seen) wine_log_write( "[spin] ml1140 no Wine thread used 80%% of a core at this moment" );
}

static void ios_xp_api_report( const char *wall, double wall_s )
{
    extern volatile long long ios_xp_set_event, ios_xp_reset_event, ios_xp_pulse_event;
    extern volatile long long ios_xp_wait_single, ios_xp_wait_multi, ios_xp_wait_zero, ios_xp_wait_zero_timeout;
    extern volatile long long ios_xp_yield, ios_xp_yield_slept, ios_xp_delay, ios_xp_delay_hist[6];
    extern volatile long long ios_alert_wakes, ios_alert_waits;
    static uint64_t *fex, *fex_prev; static struct ios_xp_nt_view *nt, *nt_prev;
    static long long u_prev[18]; static int have_fex, have_nt, have_u, map_age = 1000, said_nf;
    static double last_s;
    static uint64_t sorted[4096];
    long long u[18]; double dt; char line[3000]; int n, i;

    if (!fex) { fex = calloc( IOS_XP_FEX_WORDS, 8 ); fex_prev = calloc( IOS_XP_FEX_WORDS, 8 ); nt = calloc( 1, sizeof(*nt) ); nt_prev = calloc( 1, sizeof(*nt) ); }
    if (!fex || !fex_prev || !nt || !nt_prev) return;
    {   /* ml1131c: the fallback moved to another process: its counters start a new series */
        static unsigned seen_rebind;
        if (seen_rebind != ios_xp_rebind) { seen_rebind = ios_xp_rebind; have_fex = have_nt = 0; map_age = 1000; }
    }
    if (++map_age > 10 || !ios_xp_fex_addr || !ios_xp_nt_addr)   /* every ~10 s, or until both are found */
    {
        struct ios_xp_mod *m;
        map_age = 0;
        ios_xp_modmap( ios_xp_game_teb );
        /* ml1131b: code runs from the JIT pool's COPY of each image, and its
         * globals are reached PC-relative, so the LIVE .data is the pool copy's.
         * The PE mapping's .data is a stale snapshot (ph-rdr86 read all zeros
         * there). Translate each export into the game process's pool copy. */
        {
            extern void *ios_jit_translate_addr_for_owner( void *addr, void *owner_peb );
            uint64_t pe_fex = 0, pe_nt = 0, live_fex = 0, live_nt = 0, mg_fex = 0, mg_nt = 0;
            if (!ios_xp_fex_addr && ((m = ios_xp_mod_by_name( "xtajit64.dll" )) || (m = ios_xp_mod_by_name( "libarm64ecfex.dll" )))
                && (pe_fex = ios_xp_export_addr( m->base, "IosXpFex" )))
            {
                live_fex = (uint64_t)(uintptr_t)ios_jit_translate_addr_for_owner( (void *)(uintptr_t)pe_fex, (void *)(uintptr_t)ios_xp_peb );
                ios_ts_read( live_fex, &mg_fex, 8 );
                if (mg_fex == 0x5845465058444d41ull) ios_xp_fex_addr = live_fex;
            }
            if (!ios_xp_nt_addr && (m = ios_xp_mod_by_name( "ntdll.dll" )) && (pe_nt = ios_xp_export_addr( m->base, "ios_xp_nt" )))
            {
                live_nt = (uint64_t)(uintptr_t)ios_jit_translate_addr_for_owner( (void *)(uintptr_t)pe_nt, (void *)(uintptr_t)ios_xp_peb );
                ios_ts_read( live_nt, &mg_nt, 8 );
                if (mg_nt == 0x31544e5058444d41ull) ios_xp_nt_addr = live_nt;
            }
            if ((pe_fex || pe_nt || ios_xp_nmods) && said_nf++ < 6)
                wine_log_write( "[xp-api] ml1131b blocks: IosXpFex pe=0x%llx live=0x%llx magic=0x%llx%s | ios_xp_nt pe=0x%llx live=0x%llx magic=0x%llx%s"
                                " (game teb 0x%llx peb 0x%llx, %d modules)",
                                (unsigned long long)pe_fex, (unsigned long long)live_fex, (unsigned long long)mg_fex, ios_xp_fex_addr ? " OK" : "",
                                (unsigned long long)pe_nt, (unsigned long long)live_nt, (unsigned long long)mg_nt, ios_xp_nt_addr ? " OK" : "",
                                (unsigned long long)ios_xp_game_teb, (unsigned long long)ios_xp_peb, ios_xp_nmods );
        }
    }
    dt = last_s > 0 ? wall_s - last_s : 0;
    last_s = wall_s;
    u[0] = ios_xp_set_event; u[1] = ios_xp_reset_event; u[2] = ios_xp_pulse_event; u[3] = ios_xp_wait_single; u[4] = ios_xp_wait_multi;
    u[5] = ios_xp_wait_zero; u[6] = ios_xp_wait_zero_timeout; u[7] = ios_xp_yield; u[8] = ios_xp_yield_slept; u[9] = ios_xp_delay;
    for (i = 0; i < 6; i++) u[10 + i] = ios_xp_delay_hist[i];
    u[16] = ios_alert_waits; u[17] = ios_alert_wakes;
    {
        int got_fex = ios_xp_fex_addr && ios_ts_read( ios_xp_fex_addr, fex, IOS_XP_FEX_WORDS * 8 ) && fex[0] == 0x5845465058444d41ull;
        int got_nt = ios_xp_nt_addr && ios_ts_read( ios_xp_nt_addr, nt, sizeof(*nt) ) && nt->magic == 0x31544e5058444d41ull;
        if (dt > 0.2)
        {
            double ecc = 0, fp = 0, cb = 0, cfreq = nt->freq ? (double)nt->freq : 24e6;
            #define XPR(x) ((double)(x) / dt)
            if (got_fex && have_fex)
                for (i = 0; i < 16; i++) { ecc += fex[8 + i * 8] - fex_prev[8 + i * 8]; fp += fex[136 + i * 8] - fex_prev[136 + i * 8]; cb += fex[264 + i * 8] - fex_prev[264 + i * 8]; }
            n = snprintf( line, sizeof(line), "[xp-api] %s x64->EC %.0f/s FPCR-writes %.0f/s EC->x64 %.0f/s", wall, ecc / dt, fp / dt, cb / dt );
            if (got_nt && have_nt)
            {
                double waitms = (double)(nt->cs_wait_ticks - nt_prev->cs_wait_ticks) / cfreq * 1000.0;
                n += snprintf( line + n, sizeof(line) - n,
                               " | CS contended %.0f/s (spin0 %.0f%%) spin-won %.0f/s wait %.1f ms/s [<2us %.0f <10 %.0f <50 %.0f <200 %.0f <1ms %.0f >=1ms %.0f]/s wakes %.0f/s"
                               " | WaitOnAddress %.0f/s wake1 %.0f/s wakeAll %.0f/s",
                               XPR(nt->cs_contended - nt_prev->cs_contended),
                               nt->cs_contended > nt_prev->cs_contended ? 100.0 * (nt->cs_contended_spin0 - nt_prev->cs_contended_spin0) / (nt->cs_contended - nt_prev->cs_contended) : 0.0,
                               XPR(nt->cs_spin_acquired - nt_prev->cs_spin_acquired), waitms / dt,
                               XPR(nt->cs_wait_hist[0] - nt_prev->cs_wait_hist[0]), XPR(nt->cs_wait_hist[1] - nt_prev->cs_wait_hist[1]),
                               XPR(nt->cs_wait_hist[2] - nt_prev->cs_wait_hist[2]), XPR(nt->cs_wait_hist[3] - nt_prev->cs_wait_hist[3]),
                               XPR(nt->cs_wait_hist[4] - nt_prev->cs_wait_hist[4]), XPR(nt->cs_wait_hist[5] - nt_prev->cs_wait_hist[5]),
                               XPR(nt->cs_wakes - nt_prev->cs_wakes),
                               XPR(nt->woa_waits - nt_prev->woa_waits), XPR(nt->woa_wake_single - nt_prev->woa_wake_single), XPR(nt->woa_wake_all - nt_prev->woa_wake_all) );
            }
            if (have_u)
                n += snprintf( line + n, sizeof(line) - n,
                               " | SetEvent %.0f/s ResetEvent %.0f/s Pulse %.0f/s | wait1 %.0f/s waitN %.0f/s polls %.0f/s (empty %.0f/s)"
                               " | yield %.0f/s (slept %.0f/s) | delay %.0f/s [0 %.0f <1ms %.0f <5ms %.0f <20ms %.0f >=20ms %.0f inf %.0f] | alert wait %.0f/s wake %.0f/s",
                               XPR(u[0] - u_prev[0]), XPR(u[1] - u_prev[1]), XPR(u[2] - u_prev[2]), XPR(u[3] - u_prev[3]), XPR(u[4] - u_prev[4]),
                               XPR(u[5] - u_prev[5]), XPR(u[6] - u_prev[6]), XPR(u[7] - u_prev[7]), XPR(u[8] - u_prev[8]), XPR(u[9] - u_prev[9]),
                               XPR(u[10] - u_prev[10]), XPR(u[11] - u_prev[11]), XPR(u[12] - u_prev[12]), XPR(u[13] - u_prev[13]), XPR(u[14] - u_prev[14]),
                               XPR(u[15] - u_prev[15]), XPR(u[16] - u_prev[16]), XPR(u[17] - u_prev[17]) );
            wine_log_write( "%s", line );

            /* top x64->EC call targets from the ring entries appended since the last report */
            uint64_t spin_top = 0;          /* [spin]: the one target that takes most of the sampled calls */
            double spin_share = 0;
            if (got_fex && have_fex && ecc > 0)
            {
                uint64_t idx = fex[392], pidx = fex_prev[392], newn = idx - pidx, k, run = 0;
                int shown = 0;
                if (newn > 4096) newn = 4096;
                for (k = 0; k < newn; k++) sorted[k] = fex[400 + ((idx - 1 - k) & 4095)];
                qsort( sorted, (size_t)newn, 8, ios_xp_cmp_u64 );
                n = snprintf( line, sizeof(line), "[xp-api-top] %s %llu samples:", wall, (unsigned long long)newn );
                while (shown < 28 && newn)
                {
                    uint64_t best = 0, bestn = 0, cnt = 0;
                    for (k = 0; k <= newn; k++)
                    {
                        if (k < newn && k > 0 && sorted[k] == sorted[k - 1]) { cnt++; continue; }
                        if (k > 0 && cnt > bestn && sorted[k - 1] != ~0ull) { bestn = cnt; best = sorted[k - 1]; }
                        cnt = 1;
                    }
                    if (!bestn) break;
                    if (!shown) { spin_top = best; spin_share = (double)bestn / (double)newn; }
                    {
                        char sym[160];
                        ios_xp_symbol( best, sym, sizeof(sym) );
                        if (n > (int)sizeof(line) - 200) { wine_log_write( "%s", line ); n = snprintf( line, sizeof(line), "[xp-api-top] %s (cont):", wall ); }
                        n += snprintf( line + n, sizeof(line) - n, " %s=%.0f/s", sym, ecc / dt * (double)bestn / (double)newn );
                    }
                    for (k = 0; k < newn; k++) if (sorted[k] == best) sorted[k] = ~0ull;   /* retire it */
                    shown++;
                }
                (void)run;
                wine_log_write( "%s", line );
            }
            /* Madeira [spin] -- two numbers compared once a second; a look only on a streak (ios_spin_step) */
            {
                static struct ios_spin_state spin_state;
                static int spin_off = -1;   /* env.MADEIRA_SPIN_DIAG=0: no [spin] at all */
                int look;
                if (spin_off < 0)
                {
                    const char *e = getenv( "MADEIRA_SPIN_DIAG" );
                    spin_off = (e && e[0] == '0' && !e[1]) ? 1 : 0;
                }
                look = spin_off ? 0 : ios_spin_step( &spin_state, got_fex && have_fex ? ecc / dt : 0.0, spin_top, spin_share );
                if (look)
                {
                    char sym[160];
                    ios_xp_symbol( spin_top, sym, sizeof(sym) );
                    ios_spin_capture( wall, look, ecc / dt, spin_share, spin_state.streak, spin_top, sym );
                }
            }
            /* QPC: per-thread gap distribution, busiest four slots */
            if (got_nt && have_nt)
            {
                double tot = 0, h[5] = {0};
                int order[256], cnt = 0, j;
                for (i = 0; i < 256; i++)
                {
                    const struct ios_xp_nt_view_qpc *q = &nt->qpc[i], *pq = &nt_prev->qpc[i];
                    double c = (q->tid == pq->tid && q->calls >= pq->calls) ? (double)(q->calls - pq->calls) : (double)q->calls;
                    if (c <= 0) continue;
                    tot += c; order[cnt++] = i;
                    for (j = 0; j < 5; j++) h[j] += (q->tid == pq->tid && q->hist[j] >= pq->hist[j]) ? (double)(q->hist[j] - pq->hist[j]) : (double)q->hist[j];
                }
                if (tot > 0)
                {
                    double ht = h[0] + h[1] + h[2] + h[3] + h[4];
                    n = snprintf( line, sizeof(line), "[xp-api-qpc] %s QPC %.0f/s gaps <1us %.0f%% <10us %.0f%% <100us %.0f%% <1ms %.0f%% >=1ms %.0f%%; top threads:",
                                  wall, tot / dt, ht ? 100 * h[0] / ht : 0, ht ? 100 * h[1] / ht : 0, ht ? 100 * h[2] / ht : 0, ht ? 100 * h[3] / ht : 0, ht ? 100 * h[4] / ht : 0 );
                    for (j = 0; j < 4; j++)
                    {
                        int b = -1, x; double bc = 0;
                        for (x = 0; x < cnt; x++)
                        {
                            const struct ios_xp_nt_view_qpc *q, *pq; double c;
                            if (order[x] < 0) continue;   /* already printed */
                            q = &nt->qpc[order[x]]; pq = &nt_prev->qpc[order[x]];
                            c = (q->tid == pq->tid && q->calls >= pq->calls) ? (double)(q->calls - pq->calls) : (double)q->calls;
                            if (c > bc) { bc = c; b = x; }
                        }
                        if (b < 0) break;
                        {
                            const struct ios_xp_nt_view_qpc *q = &nt->qpc[order[b]], *pq = &nt_prev->qpc[order[b]];
                            double g[5], gt = 0; int z;
                            for (z = 0; z < 5; z++) { g[z] = (q->tid == pq->tid && q->hist[z] >= pq->hist[z]) ? (double)(q->hist[z] - pq->hist[z]) : (double)q->hist[z]; gt += g[z]; }
                            n += snprintf( line + n, sizeof(line) - n, " %04x=%.0f/s(<1us %.0f%% <10us %.0f%%)", q->tid, bc / dt, gt ? 100 * g[0] / gt : 0, gt ? 100 * g[1] / gt : 0 );
                            order[b] = -1;
                        }
                    }
                    wine_log_write( "%s", line );
                }
                /* top contended critical sections (ring entries since the last report) */
                {
                    uint64_t idx = (uint64_t)nt->cs_ring_idx >> 2, pidx = (uint64_t)nt_prev->cs_ring_idx >> 2, newn = idx - pidx, k;
                    int shown = 0;
                    if (newn > 1024) newn = 1024;
                    for (k = 0; k < newn; k++) sorted[k] = nt->cs_ring[(idx - k) & 1023];
                    if (newn)
                    {
                        qsort( sorted, (size_t)newn, 8, ios_xp_cmp_u64 );
                        n = snprintf( line, sizeof(line), "[xp-api-cs] %s %llu sampled contended enters (process heap 0x%llx):",
                                      wall, (unsigned long long)newn, (unsigned long long)ios_xp_heap );
                        while (shown < 8)
                        {
                            uint64_t best = 0, bestn = 0, cnt = 0;
                            for (k = 0; k <= newn; k++)
                            {
                                if (k < newn && k > 0 && sorted[k] == sorted[k - 1]) { cnt++; continue; }
                                if (k > 0 && cnt > bestn && sorted[k - 1] != ~0ull && sorted[k - 1]) { bestn = cnt; best = sorted[k - 1]; }
                                cnt = 1;
                            }
                            if (!bestn) break;
                            {
                                uint64_t cs[5] = {0}, dbg[6] = {0}; char nm[48] = "", where[48] = "";
                                struct ios_xp_mod *m;
                                ios_ts_read( best, cs, sizeof(cs) );   /* DebugInfo, LockCount|Recursion, Owner, Semaphore, SpinCount */
                                if (cs[0] && cs[0] != ~0ull && ios_ts_read( cs[0], dbg, sizeof(dbg) ) && dbg[5] > 0x10000)
                                {
                                    ios_ts_read( dbg[5], nm, sizeof(nm) - 1 ); nm[sizeof(nm) - 1] = 0;
                                    for (i = 0; nm[i]; i++) if ((unsigned char)nm[i] < 32 || (unsigned char)nm[i] > 126) { nm[i] = 0; break; }
                                }
                                uintptr_t pe_of = 0;
                                extern int ios_jit_pool_image_pc(uintptr_t pc, uintptr_t *pe_addr_out);
                                if (ios_jit_pool_image_pc( (uintptr_t)best, &pe_of ) && pe_of) ; else pe_of = (uintptr_t)best;   /* a global in a pool copy */
                                if (ios_xp_heap && best >= ios_xp_heap && best < ios_xp_heap + 0x2000) snprintf( where, sizeof(where), " heap+0x%llx", (unsigned long long)(best - ios_xp_heap) );
                                else if ((m = ios_xp_mod_by_addr( pe_of ))) snprintf( where, sizeof(where), " %s+0x%llx", m->name, (unsigned long long)(pe_of - m->base) );
                                n += snprintf( line + n, sizeof(line) - n, " 0x%llx=%.0f%%(spin %u contention %u%s%s%s)",
                                               (unsigned long long)best, 100.0 * bestn / newn, (unsigned)(cs[4] & 0xffffffff),
                                               (cs[0] && cs[0] != ~0ull) ? (unsigned)(dbg[4] >> 32) : 0u, where, nm[0] ? " " : "", nm );
                            }
                            for (k = 0; k < newn; k++) if (sorted[k] == best) sorted[k] = ~0ull;
                            shown++;
                        }
                        wine_log_write( "%s", line );
                    }
                }
            }
            #undef XPR
        }
        if (got_fex) { memcpy( fex_prev, fex, IOS_XP_FEX_WORDS * 8 ); have_fex = 1; }
        if (got_nt) { memcpy( nt_prev, nt, sizeof(*nt) ); have_nt = 1; }
        memcpy( u_prev, u, sizeof(u) ); have_u = 1;
    }
}

/* madeira-bcd: [bg-qos] the launcher's processes leave the performance cores
 * while the game presents. Every Wine thread runs at USER_INTERACTIVE
 * (start_thread), so in build 442's GTA V gameplay SocialClubHelper.exe,
 * dockhost.exe, RockstarService.exe and Launcher.exe took ~55 ms of P-core time
 * per 320 ms [xp-t] sample next to the game's ~223, while the efficiency cores
 * were ~86 % idle and ~2.7 threads waited for a core ([xp] run=). The [xp]
 * sampler marks the game as presenting whenever its presenting thread (role P)
 * ran in a sample; the threads of the processes named in MADEIRA_BG_QOS_PROCS
 * then drop to QOS_CLASS_UTILITY at their next server call, and return to
 * USER_INTERACTIVE once the game has not presented for IOS_BG_QOS_HOLD_NS.
 * Not before the game has presented for MADEIRA_BG_QOS_DELAY_S (default 60 s):
 * its first minute is when it talks to the launcher and Social Club (sign-in,
 * entitlement), which must not slow down. Never the game's own process.
 * Default list below; an empty value turns it off. Needs the [xp] sampler
 * (MADEIRA_PROBES not 0). */
#include <pthread/qos.h>
#define IOS_BG_QOS_HOLD_NS (2000ull * 1000 * 1000)
static volatile uint64_t ios_bg_game_seen_ns;   /* 0: no game has presented */
static volatile uint64_t ios_bg_game_since_ns;  /* when this run of presents began */
static volatile uint32_t ios_bg_game_pid;
static unsigned long ios_bg_qos_moves;
static uint64_t ios_bg_qos_delay_ns;

static uint64_t ios_bg_now_ns( void )
{
    struct timespec ts;
    clock_gettime( CLOCK_MONOTONIC, &ts );
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static char ios_bg_qos_names[512];   /* lower-case, ';'-separated */
static pthread_key_t ios_bg_qos_key;     /* per thread: 0 unknown, 1 not listed, 3 listed, 7 listed and demoted */
static int ios_bg_qos_key_ok;
static pthread_once_t ios_bg_qos_once = PTHREAD_ONCE_INIT;
static void ios_bg_qos_init( void );

/* the [xp] sampler saw the game's presenting thread run */
static void ios_bg_game_note( uint32_t pid, uint32_t wtid )
{
    uint64_t now = ios_bg_now_ns(), last;

    if (!pid) return;
    last = __atomic_load_n( &ios_bg_game_seen_ns, __ATOMIC_RELAXED );
    if (__atomic_exchange_n( &ios_bg_game_pid, pid, __ATOMIC_RELAXED ) != pid)
    {
        pthread_once( &ios_bg_qos_once, ios_bg_qos_init );
        __atomic_store_n( &ios_bg_game_since_ns, now, __ATOMIC_RELAXED );
        wine_log_write( "[bg-qos] the game is process %04x (presenting thread %04x); %s run at utility QoS once "
                        "it has presented for %llu s (MADEIRA_BG_QOS_PROCS, MADEIRA_BG_QOS_DELAY_S)", (unsigned)pid,
                        (unsigned)wtid, ios_bg_qos_key_ok ? ios_bg_qos_names : "nothing (off)",
                        (unsigned long long)(ios_bg_qos_delay_ns / 1000000000ull) );
    }
    else if (!last || now - last >= IOS_BG_QOS_HOLD_NS)
        __atomic_store_n( &ios_bg_game_since_ns, now, __ATOMIC_RELAXED );   /* presents resumed */
    __atomic_store_n( &ios_bg_game_seen_ns, now, __ATOMIC_RELEASE );   /* publishes since and pid */
}

static void ios_bg_qos_init( void )
{
    /* ';'-separated exe names demoted to utility QoS while the game presents; empty = off */
    const char *e = getenv( "MADEIRA_BG_QOS_PROCS" );
    size_t i;

    if (!e) e = "SocialClubHelper.exe;Launcher.exe;RockstarService.exe;dockhost.exe";
    for (i = 0; e[i] && i < sizeof(ios_bg_qos_names) - 1; i++)
        ios_bg_qos_names[i] = (e[i] >= 'A' && e[i] <= 'Z') ? e[i] + 32 : e[i];
    ios_bg_qos_names[i] = 0;
    {
        /* seconds the game must present before the listed processes are demoted (default 60) */
        const char *d = getenv( "MADEIRA_BG_QOS_DELAY_S" );
        unsigned long s = d && *d ? strtoul( d, NULL, 10 ) : 60;
        ios_bg_qos_delay_ns = (uint64_t)(s > 86400 ? 86400 : s) * 1000000000ull;
    }
    /* a TSD slot, not __thread: its first use allocates nothing */
    ios_bg_qos_key_ok = ios_bg_qos_names[0] && !pthread_key_create( &ios_bg_qos_key, NULL );
}

/* Is the calling thread's process on the list? (its PEB's image name) */
static int ios_bg_qos_listed_self( void )
{
    TEB *teb = NtCurrentTeb();
    RTL_USER_PROCESS_PARAMETERS *pp = teb && teb->Peb ? teb->Peb->ProcessParameters : NULL;
    const WCHAR *path;
    const char *n;
    size_t len, base = 0, k;

    if (!pp || !(path = pp->ImagePathName.Buffer)) return 0;
    len = pp->ImagePathName.Length / sizeof(WCHAR);
    for (k = 0; k < len; k++) if (path[k] == '\\' || path[k] == '/') base = k + 1;
    for (n = ios_bg_qos_names; *n; )
    {
        size_t m = 0;
        while (n[m] && n[m] != ';') m++;
        if (m && m == len - base)
        {
            for (k = 0; k < m; k++)
            {
                WCHAR c = path[base + k];
                if (c >= 'A' && c <= 'Z') c += 32;
                if (c != (WCHAR)(unsigned char)n[k]) break;
            }
            if (k == m) return 1;
        }
        n += m;
        if (*n == ';') n++;
    }
    return 0;
}

/* At each server call: move this thread between utility and user-interactive. */
static inline void ios_bg_qos_check( void )
{
    uint64_t seen = __atomic_load_n( &ios_bg_game_seen_ns, __ATOMIC_ACQUIRE );
    uintptr_t st;
    int want;

    if (!seen) return;   /* no game has presented yet, so nothing was ever demoted */
    pthread_once( &ios_bg_qos_once, ios_bg_qos_init );
    if (!ios_bg_qos_key_ok) return;
    if (!(st = (uintptr_t)pthread_getspecific( ios_bg_qos_key )))
    {
        st = ios_bg_qos_listed_self() ? 3 : 1;
        pthread_setspecific( ios_bg_qos_key, (void *)st );
    }
    if (st == 1) return;
    {
        /* both stamps before the clock: the sampler stores a stamp after reading its
         * clock, so one we loaded can never be later than our own `now` */
        uint64_t since = __atomic_load_n( &ios_bg_game_since_ns, __ATOMIC_RELAXED );
        uint64_t now = ios_bg_now_ns();
        want = now - seen < IOS_BG_QOS_HOLD_NS && now - since >= ios_bg_qos_delay_ns &&
               HandleToULong( NtCurrentTeb()->ClientId.UniqueProcess ) != __atomic_load_n( &ios_bg_game_pid, __ATOMIC_RELAXED );
    }
    if (want == (st == 7)) return;
    if (pthread_set_qos_class_self_np( want ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INTERACTIVE, 0 ))
    {
        pthread_setspecific( ios_bg_qos_key, (void *)(uintptr_t)1 );   /* refused (fixed priority): leave it */
        return;
    }
    pthread_setspecific( ios_bg_qos_key, (void *)(uintptr_t)(want ? 7 : 3) );
    {
        unsigned long n = __atomic_add_fetch( &ios_bg_qos_moves, 1, __ATOMIC_RELAXED );
        if (n <= 24 || !(n % 256))
            wine_log_write( "[bg-qos] #%lu process %04x thread %04x -> %s", n,
                            (unsigned)HandleToULong( NtCurrentTeb()->ClientId.UniqueProcess ),
                            (unsigned)HandleToULong( NtCurrentTeb()->ClientId.UniqueThread ),
                            want ? "utility (the game presents)" : "user-interactive (the game stopped presenting)" );
    }
}

/* madeira-bcd: [xp-t] shows a native thread (no TEB) as m<thread id> only,
 * and in build 442 two of them were 30-50 ms a sample with nothing to say what
 * they were. Name each once, the first time it is busy enough to be listed. */
static void ios_xp_name_native( pthread_t pt, uint64_t tid )
{
    static uint64_t named[128];
    static int n;
    char name[64] = "";
    int i;

    for (i = 0; i < n; i++) if (named[i] == tid) return;
    if (n == (int)(sizeof(named) / sizeof(named[0]))) return;
    named[n++] = tid;
    pthread_getname_np( pt, name, sizeof(name) );
    wine_log_write( "[xp-names] m%llu \"%s\"", (unsigned long long)tid, name[0] ? name : "(unnamed)" );
}

/* madeira-bcd: CPU power governor (opt-in: env.MADEIRA_POWER_GOV_MW = target in mW).
 * The SoC clamps the CPU once a budget of energy spent above ~2.3 W is used up:
 * ml1133 (sync.c, above ios_eco_gen) measured ~250 J in six runs within 3 %, and in
 * builds 442/447 (2026-10-08) GTA V Enhanced was clamped at the start of play to P
 * 1.31 / E 1.70 GHz and 0.5-0.9 W of process CPU power, 404-462 J into the session,
 * after loading screens at 3-5 W. Bursting and then running clamped wastes the budget,
 * so while a game presents this holds the process's CPU power ([xp]'s ri_energy_nj)
 * at the target on average: a running balance of (power - target) x time turns ECO on
 * (guest threads at utility QoS: efficiency cores, lower clocks) when it exceeds
 * +MADEIRA_POWER_GOV_BAND_MJ (default 1000) and off when it falls below -BAND, at most
 * one switch per 500 ms. When no game presents, ECO goes back to what it was before.
 * [power-gov] summarises every 10 s. */
extern void madeira_set_eco( int on );
extern int madeira_get_eco( void );

static void ios_power_gov_step( uint64_t now, double dt_ms, double mj )
{
    static int target_mw = -1, band_mj, base, active;
    static double balance, sum_mj, sum_ms, eco_ms;
    static unsigned switches;
    static uint64_t last_switch, last_report;
    uint64_t seen;
    int eco;

    if (target_mw < 0)
    {
        const char *e = getenv( "MADEIRA_POWER_GOV_MW" );   /* process CPU power target (mW) while a game presents; unset/0 = off */
        const char *b = getenv( "MADEIRA_POWER_GOV_BAND_MJ" );   /* energy (mJ) the running balance may drift before ECO switches (1000) */
        target_mw = e ? atoi( e ) : 0;
        if (target_mw < 0 || target_mw > 20000) target_mw = 0;
        band_mj = b ? atoi( b ) : 1000;
        if (band_mj < 50 || band_mj > 100000) band_mj = 1000;
        if (target_mw)
            wine_log_write( "[power-gov] on: process CPU power held at %d mW while a game presents (band %d mJ; "
                            "MADEIRA_POWER_GOV_MW, MADEIRA_POWER_GOV_BAND_MJ)", target_mw, band_mj );
    }
    if (!target_mw || dt_ms <= 0) return;
    seen = __atomic_load_n( &ios_bg_game_seen_ns, __ATOMIC_ACQUIRE );
    if (!seen || now - seen >= IOS_BG_QOS_HOLD_NS)
    {
        if (active)   /* the game stopped presenting: ECO back to what it was */
        {
            active = 0;
            if (madeira_get_eco() != base) madeira_set_eco( base );
            wine_log_write( "[power-gov] the game stopped presenting: ECO back %s", base ? "on" : "off" );
        }
        return;
    }
    eco = madeira_get_eco();   /* re-read: the ECO pill may have moved it */
    if (!active)
    {
        active = 1;
        base = eco;
        balance = sum_mj = sum_ms = eco_ms = 0;
        switches = 0;
        last_switch = last_report = now;
    }
    balance += mj - target_mw * dt_ms / 1000.0;
    if (balance > 3.0 * band_mj) balance = 3.0 * band_mj;     /* a long burst buys no long ECO stretch */
    if (balance < -3.0 * band_mj) balance = -3.0 * band_mj;   /* nor a long idle stretch a long burst */
    sum_mj += mj;
    sum_ms += dt_ms;
    if (eco) eco_ms += dt_ms;
    if (now - last_switch >= 500000000ull && ((!eco && balance > band_mj) || (eco && balance < -band_mj)))
    {
        madeira_set_eco( !eco );
        last_switch = now;
        switches++;
    }
    if (now - last_report >= 10000000000ull && sum_ms > 0)
    {
        wine_log_write( "[power-gov] last %.0f s: %.2f W average (target %.2f W), ECO on %.0f%% of the time, %u switches",
                        sum_ms / 1000.0, sum_mj / sum_ms, target_mw / 1000.0, 100.0 * eco_ms / sum_ms, switches );
        last_report = now;
        sum_mj = sum_ms = eco_ms = 0;
        switches = 0;
    }
}

/* madeira-bcd fps-gov: a frame-rate cap as the power governor's actuator (opt-in).
 * The governor above switches ECO, and ECO (every guest thread at utility QoS) made
 * GTA V Enhanced crash while loading (a null-pointer write in a timing-sensitive
 * path, build 449). A cap moves no thread and changes no timing inside a frame,
 * only how often frames start. The CPU clamp comes after ~273-330 J of process CPU
 * energy in Horizon Zero Dawn (builds 486-493), most of it spent in menus and
 * loading at 2.75-3.8 W; Red Dead Redemption 2's menus ran at 57-60 fps for two
 * minutes (build 460) and the clamp came before play. Two opt-in modes:
 *   env.MADEIRA_FPS_CAP = N     a fixed cap of N fps (10-120) for the whole session;
 *   env.MADEIRA_FPS_GOV_MW = P  while a game presents, hold the process CPU power
 *       ([xp]'s ri_energy_nj) at P mW by moving the cap between 60/40/30/24/20 fps
 *       (MADEIRA_FPS_GOV_MAX / _MIN bound the steps; 60 and 20 by default): a running
 *       balance of (power - target) x time lowers the cap one step when it passes
 *       +MADEIRA_FPS_GOV_BAND_MJ (1500 by default), skipping caps the game does not
 *       reach anyway, and raises it one step when it passes -BAND while the game runs
 *       at the cap; at most one change per 3 s. With nothing presented for 2 s
 *       (loading) the balance and the cap are held.
 * The cap is published in ios_fps_cap. The xprobe copies it into madeira-d3d12's
 * counter block, which its Present reads to hold the game's thread
 * (NtDelayExecution); DXMT's encode thread waits in winemetal's presentDrawable
 * (winemetal in DXMT -> ios_fps_cap_dxmt_pace) when no D3D12 runtime
 * paces itself. [fps-gov] summarises every 10 s. Unset: nothing is armed,
 * ios_fps_cap stays 0 and neither presenter waits. Needs the [xp] sampler. */
volatile int ios_fps_cap;                     /* fps the presenters pace to; 0 = none */
static volatile int ios_fps_gov_armed;        /* a cap or a target is set (read once by the xprobe) */
static volatile uint64_t ios_fps_presents;    /* presents through winemetal while armed */
static volatile uint64_t ios_fps_paced_ns;    /* time DXMT presents waited for the cap */
static const int ios_fps_steps[] = { 60, 40, 30, 24, 20 };
#define IOS_FPS_NSTEPS ((int)(sizeof(ios_fps_steps) / sizeof(ios_fps_steps[0])))

/* the D3D12 runtime's part of its counter block (madeira-d3d12 struct mad_xp, after
 * the fields struct ios_xp_pe mirrors): fps_cap is ours to write, the rest is its own */
struct ios_xp_pe_cap { int64_t fps_cap, t_cap, n_cap; };

static void ios_fps_gov_step( uint64_t now, double dt_ms, double mj, uint64_t presents, double paced_ms )
{
    static int inited, fixed, target_mw, band_mj, hi, lo, idx, active;
    static double balance, sum_mj, sum_ms, sum_paced, fps_avg;
    static uint64_t last_presents, last_present_ns, last_change, last_report, report_presents;
    static unsigned changes;
    double fps;
    int i, n;

    if (!inited)
    {
        const char *c = getenv( "MADEIRA_FPS_CAP" );          /* fixed frame cap (fps, 10-120); unset/0 = none */
        const char *e = getenv( "MADEIRA_FPS_GOV_MW" );       /* process CPU power (mW) the frame cap holds while a game presents; unset/0 = off */
        const char *b = getenv( "MADEIRA_FPS_GOV_BAND_MJ" );  /* energy (mJ) the balance may drift before the cap moves (1500) */
        const char *mx = getenv( "MADEIRA_FPS_GOV_MAX" );     /* highest cap of the governor (fps, 60) */
        const char *mn = getenv( "MADEIRA_FPS_GOV_MIN" );     /* lowest cap of the governor (fps, 20) */
        int max_fps = mx && *mx ? atoi( mx ) : 60, min_fps = mn && *mn ? atoi( mn ) : 20;
        inited = 1;
        fixed = c ? atoi( c ) : 0;
        if (fixed < 10 || fixed > 120) fixed = 0;
        target_mw = e ? atoi( e ) : 0;
        if (target_mw < 0 || target_mw > 20000) target_mw = 0;
        band_mj = b && *b ? atoi( b ) : 1500;
        if (band_mj < 100 || band_mj > 100000) band_mj = 1500;
        for (hi = 0; hi < IOS_FPS_NSTEPS - 1 && ios_fps_steps[hi] > max_fps; hi++) ;
        for (lo = IOS_FPS_NSTEPS - 1; lo > hi && ios_fps_steps[lo] < min_fps; lo--) ;
        idx = hi;
        last_presents = presents;
        if (fixed)
        {
            ios_fps_cap = fixed;
            ios_fps_gov_armed = 1;
            wine_log_write( "[fps-gov] madeira-bcd fixed frame cap: %d fps (MADEIRA_FPS_CAP)", fixed );
        }
        else if (target_mw)
        {
            ios_fps_gov_armed = 1;
            wine_log_write( "[fps-gov] madeira-bcd on: process CPU power held at %d mW while a game presents, by a frame "
                            "cap of %d..%d fps (band %d mJ; MADEIRA_FPS_GOV_MW, _MIN, _MAX, _BAND_MJ)",
                            target_mw, ios_fps_steps[lo], ios_fps_steps[hi], band_mj );
        }
    }
    if (fixed || !target_mw || dt_ms <= 0) return;
    fps = presents >= last_presents ? (presents - last_presents) * 1000.0 / dt_ms : 0;
    if (presents != last_presents) last_present_ns = now;
    last_presents = presents;
    if (!last_present_ns || now - last_present_ns >= 2000000000ull)
    {
        if (active)
        {
            active = 0;
            wine_log_write( "[fps-gov] nothing presented for 2 s: cap held at %d fps", ios_fps_steps[idx] );
        }
        return;
    }
    if (!active)
    {
        active = 1;
        balance = sum_mj = sum_ms = sum_paced = 0;
        fps_avg = fps;
        changes = 0;
        last_change = last_report = now;
        report_presents = presents;
        ios_fps_cap = ios_fps_steps[idx];
        wine_log_write( "[fps-gov] the game presents: cap %d fps", ios_fps_cap );
    }
    fps_avg += 0.25 * (fps - fps_avg);
    balance += mj - target_mw * dt_ms / 1000.0;
    if (balance > 3.0 * band_mj) balance = 3.0 * band_mj;     /* a long burst buys no long low-cap stretch */
    if (balance < -3.0 * band_mj) balance = -3.0 * band_mj;   /* nor a long cheap stretch a long burst */
    sum_mj += mj;
    sum_ms += dt_ms;
    sum_paced += paced_ms;
    if (now - last_change >= 3000000000ull)
    {
        if (balance > band_mj && idx < lo)
        {
            for (n = idx + 1; n < lo && ios_fps_steps[n] >= fps_avg * 0.95; n++) ;   /* a cap above the game's rate changes nothing */
            idx = n;
            balance = 0;
            last_change = now;
            changes++;
        }
        else if (balance < -band_mj && idx > hi && fps_avg >= 0.85 * ios_fps_steps[idx])
        {
            idx--;
            balance = 0;
            last_change = now;
            changes++;
        }
    }
    ios_fps_cap = ios_fps_steps[idx];
    if (now - last_report >= 10000000000ull && sum_ms > 0)
    {
        i = (int)(presents - report_presents);
        wine_log_write( "[fps-gov] last %.0f s: %.2f W average (target %.2f W), cap %d fps, %.1f fps presented, "
                        "waited %.0f ms/s for the cap, %u change(s)", sum_ms / 1000.0, sum_mj / sum_ms,
                        target_mw / 1000.0, ios_fps_cap, i * 1000.0 / sum_ms, sum_paced * 1000.0 / sum_ms, changes );
        last_report = now;
        report_presents = presents;
        sum_mj = sum_ms = sum_paced = 0;
        changes = 0;
    }
}

/* madeira-bcd fps-gov: DXMT's side of the cap. winemetal (DXMT)
 * calls this at the top of winemetal's presentDrawable (on the presenting thread:
 * DXMT's encode thread, or madeira-d3d12's queue worker). While a cap or governor
 * is armed it counts the present; when a cap is set and no D3D12 runtime paces
 * itself (madeira-d3d12 publishes its counter block, ios_xp_pe_block, and holds the
 * game's thread in Present), it waits for this thread's next deadline with
 * mach_wait_until, a timed kernel wait. The deadline moves one period from the
 * previous one, and is re-based when the thread fell more than a period behind, so
 * a slow frame is not paid twice and a stall banks no credit. Returns the
 * nanoseconds waited (the [frame] limiter time). Not armed: returns at once. */
unsigned long long ios_fps_cap_dxmt_pace( void )
{
    static __thread uint64_t next;
    static mach_timebase_info_data_t tb;
    uint64_t now, period, slept;
    int cap;

    if (!ios_fps_gov_armed) return 0;
    __atomic_add_fetch( &ios_fps_presents, 1, __ATOMIC_RELAXED );
    cap = ios_fps_cap;
    if (cap < 10 || cap > 240 || ios_xp_pe_block) { next = 0; return 0; }
    if (!tb.denom) mach_timebase_info( &tb );
    period = (uint64_t)(1e9 / cap * tb.denom / tb.numer);
    now = mach_absolute_time();
    if (!next || now > next + period) { next = now + period; return 0; }
    if (now >= next) { next += period; return 0; }
    mach_wait_until( next );
    slept = (mach_absolute_time() - now) * tb.numer / tb.denom;
    next += period;
    __atomic_add_fetch( &ios_fps_paced_ns, slept, __ATOMIC_RELAXED );
    return slept;
}

/* madeira-bcd power probe (opt-in: env.MADEIRA_POWER_PROBE = 1). Every 5 s, next
 * to [xp]'s process CPU energy (proc_pid_rusage ri_energy_nj), one [power] line with
 * what else a developer-signed app can read, each source tried once and named
 * "unavailable" once when it gives nothing:
 *  - the process's resource coalition (proc_pidinfo PROC_PIDCOALITIONINFO, then
 *    libsystem_kernel's coalition_info_resource_usage): gpu_energy_nj and gpu_time,
 *    which the GPU driver charges to coalitions (xnu coalition_add_to_gpu_energy,
 *    ml_gpu_stat_update), plus the coalition's CPU energy and the energy others
 *    did on our behalf. task_info(TASK_POWER_INFO_V2)'s gpu field is no use on
 *    arm64: ml_gpu_stat() returns 0 there (osfmk/arm64/machine_routines.c);
 *  - rusage's ri_billed_energy / ri_serviced_energy (work billed across processes);
 *  - IOReport's "Energy Model" group (private /usr/lib/libIOReport.dylib), the SoC's
 *    own CPU/GPU/DRAM energy counters, if the sandbox lets the app subscribe;
 *  - the battery's IORegistry entry (AppleSmartBattery: Voltage, InstantAmperage),
 *    i.e. the whole device's power while unplugged, if the sandbox lets it be read.
 * One [power-t] line names the threads that used the most energy in those 5 s
 * ([xp]'s per-thread PROC_PIDTHREADCOUNTS energy, which [xp-t] does not print), so
 * the wineserver, Metal and app threads can be told apart from the game's; a
 * native thread (m<tid>) carries its base priority, which names its QoS class
 * (47 user-interactive, 37 user-initiated, 31 default, 20 utility, 4 background,
 * 97 real-time). All calls are made on the xprobe thread; nothing is resolved
 * while the switch is off. */
static int ios_power_probe_on;   /* read where the samplers are armed */

struct ios_pp_thr { uint64_t tid; uint32_t wtid; char role[6]; int pri; double p_mj, e_mj; };
static struct ios_pp_thr ios_pp_thr[256];
static int ios_pp_nthr;

/* returns the entry, or NULL when the table is full; a new native entry has pri -2 (not yet asked) */
static struct ios_pp_thr *ios_pp_thread( uint64_t tid, uint32_t wtid, const char *role, double p_mj, double e_mj )
{
    int i;
    for (i = 0; i < ios_pp_nthr; i++) if (ios_pp_thr[i].tid == tid) break;
    if (i == ios_pp_nthr)
    {
        if (ios_pp_nthr >= (int)(sizeof(ios_pp_thr) / sizeof(ios_pp_thr[0]))) return NULL;
        memset( &ios_pp_thr[i], 0, sizeof(ios_pp_thr[i]) );
        ios_pp_thr[i].tid = tid;
        ios_pp_thr[i].pri = wtid ? -1 : -2;
        ios_pp_nthr++;
    }
    ios_pp_thr[i].wtid = wtid;
    if (role) snprintf( ios_pp_thr[i].role, sizeof(ios_pp_thr[i].role), "%s", role );
    ios_pp_thr[i].p_mj += p_mj;
    ios_pp_thr[i].e_mj += e_mj;
    return &ios_pp_thr[i];
}

/* struct coalition_resource_usage (xnu osfmk/mach/coalition.h) up to swapins; the
 * kernel copies min(its size, ours), so fields it lacks stay 0 */
struct ios_pp_cru
{
    uint64_t tasks_started, tasks_exited, time_nonempty, cpu_time, interrupt_wakeups, platform_idle_wakeups,
             bytesread, byteswritten, gpu_time, cpu_time_billed_to_me, cpu_time_billed_to_others, energy,
             lwrites[8], energy_billed_to_me, energy_billed_to_others, cpu_ptime, cpu_time_eqos_len, cpu_time_eqos[7],
             cpu_instructions, cpu_cycles, fs_metadata_writes, pm_writes, cpu_pinstructions, cpu_pcycles, conclave_mem,
             ane_mach_time, ane_energy_nj, phys_footprint, gpu_energy_nj, gpu_energy_nj_billed_to_me,
             gpu_energy_nj_billed_to_others, swapins;
};

typedef const void *ios_cf_t;
static struct
{
    int inited;
    /* coalition */
    uint64_t cid;
    int (*cru_fn)( uint64_t cid, void *cru, size_t size );
    struct ios_pp_cru cru_prev;
    int have_cru, said_coal;
    /* CoreFoundation, IOKit, IOReport (all through dlsym) */
    ios_cf_t (*str)( ios_cf_t alloc, const char *s, uint32_t encoding );
    unsigned char (*num_get)( ios_cf_t num, long type, void *out );
    unsigned long (*type_id)( ios_cf_t obj );
    unsigned long (*num_type)( void );
    void (*release)( ios_cf_t obj );
    ios_cf_t (*dict_get)( ios_cf_t dict, ios_cf_t key );
    ios_cf_t (*dict_mcopy)( ios_cf_t alloc, long capacity, ios_cf_t dict );
    long (*arr_count)( ios_cf_t arr );
    ios_cf_t (*arr_at)( ios_cf_t arr, long i );
    unsigned char (*str_get)( ios_cf_t s, char *buf, long size, uint32_t encoding );
    ios_cf_t (*io_matching)( const char *name );
    mach_port_t (*io_service)( mach_port_t main_port, ios_cf_t matching );
    ios_cf_t (*io_prop)( mach_port_t entry, ios_cf_t key, ios_cf_t alloc, uint32_t options );
    mach_port_t battery;
    ios_cf_t k_volt, k_amp;
    int said_batt;
    ios_cf_t (*ior_channels)( ios_cf_t group, ios_cf_t subgroup, uint64_t a, uint64_t b, uint64_t c );
    ios_cf_t (*ior_subscribe)( ios_cf_t a, ios_cf_t channels, ios_cf_t *subbed, uint64_t b, ios_cf_t c );
    ios_cf_t (*ior_samples)( ios_cf_t sub, ios_cf_t subbed, ios_cf_t a );
    ios_cf_t (*ior_delta)( ios_cf_t prev, ios_cf_t cur, ios_cf_t a );
    ios_cf_t (*ior_name)( ios_cf_t channel );
    ios_cf_t (*ior_unit)( ios_cf_t channel );
    int64_t (*ior_int)( ios_cf_t channel, int32_t index );
    ios_cf_t ior_sub, ior_subbed, ior_prev, k_channels;
    int said_ior, listed_ior;
    /* accumulated between lines */
    uint64_t last_ns;
    double ms, cpu_mj, cpu_p_mj, billed_mj, serviced_mj;
} ios_pp;

#define IOS_CF_UTF8 0x08000100u   /* kCFStringEncodingUTF8 */
#define IOS_CF_SINT64 4           /* kCFNumberSInt64Type */

static void ios_pp_init( void )
{
    struct { uint64_t coalition_id[2]; uint64_t reserved[3]; } pci;
    void *iokit, *ior;

    ios_pp.inited = 1;
    memset( &pci, 0, sizeof(pci) );
    if (proc_pidinfo( getpid(), 20 /* PROC_PIDCOALITIONINFO */, 1, &pci, sizeof(pci) ) == (int)sizeof(pci))
        ios_pp.cid = pci.coalition_id[0];   /* COALITION_TYPE_RESOURCE */
    ios_pp.cru_fn = (int (*)( uint64_t, void *, size_t ))dlsym( RTLD_DEFAULT, "coalition_info_resource_usage" );
    ios_pp.str = (ios_cf_t (*)( ios_cf_t, const char *, uint32_t ))dlsym( RTLD_DEFAULT, "CFStringCreateWithCString" );
    ios_pp.num_get = (unsigned char (*)( ios_cf_t, long, void * ))dlsym( RTLD_DEFAULT, "CFNumberGetValue" );
    ios_pp.type_id = (unsigned long (*)( ios_cf_t ))dlsym( RTLD_DEFAULT, "CFGetTypeID" );
    ios_pp.num_type = (unsigned long (*)( void ))dlsym( RTLD_DEFAULT, "CFNumberGetTypeID" );
    ios_pp.release = (void (*)( ios_cf_t ))dlsym( RTLD_DEFAULT, "CFRelease" );
    ios_pp.dict_get = (ios_cf_t (*)( ios_cf_t, ios_cf_t ))dlsym( RTLD_DEFAULT, "CFDictionaryGetValue" );
    ios_pp.dict_mcopy = (ios_cf_t (*)( ios_cf_t, long, ios_cf_t ))dlsym( RTLD_DEFAULT, "CFDictionaryCreateMutableCopy" );
    ios_pp.arr_count = (long (*)( ios_cf_t ))dlsym( RTLD_DEFAULT, "CFArrayGetCount" );
    ios_pp.arr_at = (ios_cf_t (*)( ios_cf_t, long ))dlsym( RTLD_DEFAULT, "CFArrayGetValueAtIndex" );
    ios_pp.str_get = (unsigned char (*)( ios_cf_t, char *, long, uint32_t ))dlsym( RTLD_DEFAULT, "CFStringGetCString" );
    if (!ios_pp.str || !ios_pp.num_get || !ios_pp.type_id || !ios_pp.num_type || !ios_pp.release || !ios_pp.dict_get ||
        !ios_pp.dict_mcopy || !ios_pp.arr_count || !ios_pp.arr_at || !ios_pp.str_get)
        ios_pp.str = NULL;   /* no CoreFoundation: neither IOKit nor IOReport */
    if (ios_pp.str && (iokit = dlopen( "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY )))
    {
        ios_pp.io_matching = (ios_cf_t (*)( const char * ))dlsym( iokit, "IOServiceMatching" );
        ios_pp.io_service = (mach_port_t (*)( mach_port_t, ios_cf_t ))dlsym( iokit, "IOServiceGetMatchingService" );
        ios_pp.io_prop = (ios_cf_t (*)( mach_port_t, ios_cf_t, ios_cf_t, uint32_t ))dlsym( iokit, "IORegistryEntryCreateCFProperty" );
        if (ios_pp.io_matching && ios_pp.io_service && ios_pp.io_prop)
        {
            ios_cf_t m = ios_pp.io_matching( "AppleSmartBattery" );
            if (m) ios_pp.battery = ios_pp.io_service( MACH_PORT_NULL, m );   /* consumes m */
            ios_pp.k_volt = ios_pp.str( NULL, "Voltage", IOS_CF_UTF8 );
            ios_pp.k_amp = ios_pp.str( NULL, "InstantAmperage", IOS_CF_UTF8 );
        }
    }
    if (ios_pp.str && (ior = dlopen( "/usr/lib/libIOReport.dylib", RTLD_LAZY )))
    {
        ios_pp.ior_channels = (ios_cf_t (*)( ios_cf_t, ios_cf_t, uint64_t, uint64_t, uint64_t ))dlsym( ior, "IOReportCopyChannelsInGroup" );
        ios_pp.ior_subscribe = (ios_cf_t (*)( ios_cf_t, ios_cf_t, ios_cf_t *, uint64_t, ios_cf_t ))dlsym( ior, "IOReportCreateSubscription" );
        ios_pp.ior_samples = (ios_cf_t (*)( ios_cf_t, ios_cf_t, ios_cf_t ))dlsym( ior, "IOReportCreateSamples" );
        ios_pp.ior_delta = (ios_cf_t (*)( ios_cf_t, ios_cf_t, ios_cf_t ))dlsym( ior, "IOReportCreateSamplesDelta" );
        ios_pp.ior_name = (ios_cf_t (*)( ios_cf_t ))dlsym( ior, "IOReportChannelGetChannelName" );
        ios_pp.ior_unit = (ios_cf_t (*)( ios_cf_t ))dlsym( ior, "IOReportChannelGetUnitLabel" );
        ios_pp.ior_int = (int64_t (*)( ios_cf_t, int32_t ))dlsym( ior, "IOReportSimpleGetIntegerValue" );
        if (ios_pp.ior_channels && ios_pp.ior_subscribe && ios_pp.ior_samples && ios_pp.ior_delta &&
            ios_pp.ior_name && ios_pp.ior_unit && ios_pp.ior_int)
        {
            ios_cf_t group = ios_pp.str( NULL, "Energy Model", IOS_CF_UTF8 ), chans, mchans;
            ios_pp.k_channels = ios_pp.str( NULL, "IOReportChannels", IOS_CF_UTF8 );
            if (group && (chans = ios_pp.ior_channels( group, NULL, 0, 0, 0 )))
            {
                if ((mchans = ios_pp.dict_mcopy( NULL, 0, chans )))
                    ios_pp.ior_sub = ios_pp.ior_subscribe( NULL, mchans, &ios_pp.ior_subbed, 0, NULL );
                ios_pp.release( chans );
            }
            if (ios_pp.ior_sub && ios_pp.ior_subbed) ios_pp.ior_prev = ios_pp.ior_samples( ios_pp.ior_sub, ios_pp.ior_subbed, NULL );
        }
    }
}

static int ios_pp_num( ios_cf_t obj, int64_t *out )
{
    if (!obj || ios_pp.type_id( obj ) != ios_pp.num_type()) return 0;
    return ios_pp.num_get( obj, IOS_CF_SINT64, out ) != 0;
}

/* scale an IOReport energy value to mJ by its unit label */
static double ios_pp_ior_mj( int64_t v, const char *unit )
{
    if (!strcmp( unit, "nJ" )) return v / 1e6;
    if (!strcmp( unit, "uJ" ) || !strcmp( unit, "\xc2\xb5J" )) return v / 1e3;
    if (!strcmp( unit, "mJ" )) return (double)v;
    if (!strcmp( unit, "J" )) return v * 1e3;
    return -1;
}

static void ios_power_probe_tick( const char *wall, uint64_t now_ns, double dt_ms, double cpu_mj, double cpu_p_mj,
                                  double billed_mj, double serviced_mj )
{
    char line[1400];
    int n, i;
    double ms;

    if (!ios_pp.inited)
    {
        ios_pp_init();
        ios_pp.last_ns = now_ns;
        wine_log_write( "[power] madeira-bcd probe on (MADEIRA_POWER_PROBE): coalition %#llx (%s), IOReport %s, battery %s",
                        (unsigned long long)ios_pp.cid, ios_pp.cru_fn ? "reader found" : "no reader",
                        ios_pp.ior_sub ? "subscribed" : "not subscribed", ios_pp.battery ? "entry found" : "no entry" );
    }
    ios_pp.ms += dt_ms;
    ios_pp.cpu_mj += cpu_mj;
    ios_pp.cpu_p_mj += cpu_p_mj;
    ios_pp.billed_mj += billed_mj;
    ios_pp.serviced_mj += serviced_mj;
    if (now_ns - ios_pp.last_ns < 5000000000ull || ios_pp.ms <= 0) return;
    ios_pp.last_ns = now_ns;
    ms = ios_pp.ms;
    n = snprintf( line, sizeof(line), "[power] %s %.1f s: cpu %.2f W (P %.2f; rusage), billed %.2f W, serviced %.2f W", wall,
                  ms / 1000.0, ios_pp.cpu_mj / ms, ios_pp.cpu_p_mj / ms, ios_pp.billed_mj / ms, ios_pp.serviced_mj / ms );

    /* the resource coalition: GPU energy and time the driver charged to it */
    {
        struct ios_pp_cru cru;
        int ok = 0, err = 0;
        memset( &cru, 0, sizeof(cru) );
        if (ios_pp.cid && ios_pp.cru_fn) { ok = !ios_pp.cru_fn( ios_pp.cid, &cru, sizeof(cru) ); if (!ok) err = errno; }
        if (ok && ios_pp.have_cru)
            n += snprintf( line + n, sizeof(line) - n, " | coalition: gpu %.2f W, busy %.0f%%, cpu %.2f W, ane %.2f W, "
                           "billed to us: cpu %.2f W gpu %.2f W",
                           (double)(cru.gpu_energy_nj - ios_pp.cru_prev.gpu_energy_nj) / 1e6 / ms,
                           (double)(cru.gpu_time - ios_pp.cru_prev.gpu_time) / 1e4 / ms,
                           (double)(cru.energy - ios_pp.cru_prev.energy) / 1e6 / ms,
                           (double)(cru.ane_energy_nj - ios_pp.cru_prev.ane_energy_nj) / 1e6 / ms,
                           (double)(cru.energy_billed_to_me - ios_pp.cru_prev.energy_billed_to_me) / 1e6 / ms,
                           (double)(cru.gpu_energy_nj_billed_to_me - ios_pp.cru_prev.gpu_energy_nj_billed_to_me) / 1e6 / ms );
        else if (!ok && !ios_pp.said_coal++)
            n += snprintf( line + n, sizeof(line) - n, " | coalition unavailable (%s, errno %d)",
                           !ios_pp.cid ? "no coalition id" : !ios_pp.cru_fn ? "no coalition_info_resource_usage" : "refused", err );
        if (ok) { ios_pp.cru_prev = cru; ios_pp.have_cru = 1; }
    }

    /* IOReport "Energy Model": the SoC's own energy counters */
    if (ios_pp.ior_prev)
    {
        ios_cf_t cur = ios_pp.ior_samples( ios_pp.ior_sub, ios_pp.ior_subbed, NULL ), delta = NULL, arr = NULL;
        double gpu = 0, gpu_parts = 0, cpu = 0, cpu_parts = 0, dram = 0;
        int named = 0, gpu_seen = 0, cpu_seen = 0, nn = 0;
        char names[600];
        names[0] = 0;
        if (cur && (delta = ios_pp.ior_delta( ios_pp.ior_prev, cur, NULL ))) arr = ios_pp.dict_get( delta, ios_pp.k_channels );
        if (arr)
        {
            long c, count = ios_pp.arr_count( arr );
            for (c = 0; c < count; c++)
            {
                ios_cf_t ch = ios_pp.arr_at( arr, c ), nm = ch ? ios_pp.ior_name( ch ) : NULL, un = ch ? ios_pp.ior_unit( ch ) : NULL;
                char name[64] = "", unit[16] = "";
                double mj;
                if (!nm || !ios_pp.str_get( nm, name, sizeof(name), IOS_CF_UTF8 )) continue;
                if (un) ios_pp.str_get( un, unit, sizeof(unit), IOS_CF_UTF8 );
                mj = ios_pp_ior_mj( ios_pp.ior_int( ch, 0 ), unit );
                if (!ios_pp.listed_ior && nn < (int)sizeof(names) - 96)
                    nn += snprintf( names + nn, sizeof(names) - nn, " %s=%.1f%s", name, mj, mj < 0 ? "(unit?)" : "" );
                if (mj < 0) continue;
                named++;
                if (!strcmp( name, "GPU Energy" )) { gpu += mj; gpu_seen = 1; }
                else if (!strncmp( name, "GPU", 3 )) gpu_parts += mj;
                else if (!strcmp( name, "CPU Energy" )) { cpu += mj; cpu_seen = 1; }
                else if (strstr( name, "CPU" )) cpu_parts += mj;
                else if (!strncmp( name, "DRAM", 4 )) dram += mj;
            }
        }
        if (named)
        {
            n += snprintf( line + n, sizeof(line) - n, " | IOReport: gpu %.2f W, cpu %.2f W, dram %.2f W",
                           (gpu_seen ? gpu : gpu_parts) / ms, (cpu_seen ? cpu : cpu_parts) / ms, dram / ms );
            if (!ios_pp.listed_ior++) wine_log_write( "[power] IOReport Energy Model channels (mJ in these %.1f s):%s", ms / 1000.0, names );
        }
        else if (!ios_pp.said_ior++)
            n += snprintf( line + n, sizeof(line) - n, " | IOReport unavailable (no energy channel in the samples)" );
        if (delta) ios_pp.release( delta );
        if (cur) { ios_pp.release( ios_pp.ior_prev ); ios_pp.ior_prev = cur; }
    }
    else if (!ios_pp.said_ior++)
        n += snprintf( line + n, sizeof(line) - n, " | IOReport unavailable (%s)",
                       !ios_pp.ior_channels ? "libIOReport not loaded" : "no Energy Model subscription" );

    /* the battery: the whole device's power while unplugged */
    {
        int64_t mv = 0, ma = 0;
        ios_cf_t v = NULL, a = NULL;
        if (ios_pp.battery)
        {
            v = ios_pp.io_prop( ios_pp.battery, ios_pp.k_volt, NULL, 0 );
            a = ios_pp.io_prop( ios_pp.battery, ios_pp.k_amp, NULL, 0 );
        }
        if (ios_pp_num( v, &mv ) && ios_pp_num( a, &ma ) && mv > 0)
            n += snprintf( line + n, sizeof(line) - n, " | battery %.2f V x %lld mA = %.2f W (%s)", mv / 1000.0, (long long)ma,
                           (ma < 0 ? -ma : ma) * (double)mv / 1e6, ma < 0 ? "discharging: the whole device" : "charging" );
        else if (!ios_pp.said_batt++)
            n += snprintf( line + n, sizeof(line) - n, " | battery unavailable (%s)",
                           !ios_pp.io_prop ? "IOKit not loaded" : !ios_pp.battery ? "no AppleSmartBattery entry" : "properties not readable" );
        if (v) ios_pp.release( v );
        if (a) ios_pp.release( a );
    }
    wine_log_write( "%s", line );

    /* the threads that used the most energy in these 5 s */
    n = snprintf( line, sizeof(line), "[power-t] %s top threads, W (P/E):", wall );
    for (i = 0; i < 10 && n < (int)sizeof(line) - 64; i++)
    {
        int b = -1, k;
        for (k = 0; k < ios_pp_nthr; k++)
            if (ios_pp_thr[k].tid && (b < 0 || ios_pp_thr[k].p_mj + ios_pp_thr[k].e_mj > ios_pp_thr[b].p_mj + ios_pp_thr[b].e_mj)) b = k;
        if (b < 0 || ios_pp_thr[b].p_mj + ios_pp_thr[b].e_mj <= 0) break;
        if (ios_pp_thr[b].wtid)
            n += snprintf( line + n, sizeof(line) - n, " %s%04x:%.3f(%.3f/%.3f)", ios_pp_thr[b].role[0] ? ios_pp_thr[b].role : "-",
                           ios_pp_thr[b].wtid, (ios_pp_thr[b].p_mj + ios_pp_thr[b].e_mj) / ms, ios_pp_thr[b].p_mj / ms,
                           ios_pp_thr[b].e_mj / ms );
        else if (ios_pp_thr[b].pri >= 0)
            n += snprintf( line + n, sizeof(line) - n, " m%llu/%d:%.3f(%.3f/%.3f)", (unsigned long long)ios_pp_thr[b].tid,
                           ios_pp_thr[b].pri, (ios_pp_thr[b].p_mj + ios_pp_thr[b].e_mj) / ms, ios_pp_thr[b].p_mj / ms,
                           ios_pp_thr[b].e_mj / ms );
        else
            n += snprintf( line + n, sizeof(line) - n, " m%llu:%.3f(%.3f/%.3f)", (unsigned long long)ios_pp_thr[b].tid,
                           (ios_pp_thr[b].p_mj + ios_pp_thr[b].e_mj) / ms, ios_pp_thr[b].p_mj / ms, ios_pp_thr[b].e_mj / ms );
        ios_pp_thr[b].tid = 0;   /* printed */
    }
    wine_log_write( "%s", line );
    ios_pp_nthr = 0;
    ios_pp.ms = ios_pp.cpu_mj = ios_pp.cpu_p_mj = ios_pp.billed_mj = ios_pp.serviced_mj = 0;
}

static void ios_xprobe_main( void )
{
    static struct ios_xp_row rows[1024];
    mach_timebase_info_data_t tb;
    struct rusage_info_v6 ru, pru;
    struct ios_xp_pe pe, ppe;
    uint64_t t_start, t_prev;
    uint32_t gen = 0; int have_ru = 0, have_pe = 0, used = 0, ru_rc;
    char n0[32] = "?", n1[32] = "?"; size_t sz; int nlev = 0;

    if (ios_ts_tsd_off < 0) ios_ts_calibrate();
    mach_timebase_info( &tb );
    sz = sizeof(nlev); sysctlbyname( "hw.nperflevels", &nlev, &sz, NULL, 0 );
    sz = sizeof(n0); sysctlbyname( "hw.perflevel0.name", n0, &sz, NULL, 0 );
    sz = sizeof(n1); sysctlbyname( "hw.perflevel1.name", n1, &sz, NULL, 0 );
    memset( &ru, 0, sizeof(ru) );
    ru_rc = proc_pid_rusage( getpid(), 6 /* RUSAGE_INFO_V6 */, &ru );
    wine_log_write( "[xp] ml1128 armed: 250 ms; perf levels %d (0=%s, 1=%s); rusage v6 rc=%d errno=%d; timebase %u/%u",
                    nlev, n0, n1, ru_rc, ru_rc ? errno : 0, tb.numer, tb.denom );
    t_start = t_prev = mach_absolute_time();
    memset( &ppe, 0, sizeof(ppe) );
    for (;;)
    {
        thread_act_array_t th = NULL; mach_msg_type_number_t nth = 0, k;
        uint64_t now; double dt_ms, sum_thr_ms = 0; int nrows = 0, i, j;
#define XP_MS(ticks) ((double)(ticks) * tb.numer / tb.denom / 1e6)
        usleep( 250000 );
        now = mach_absolute_time();
        dt_ms = XP_MS( now - t_prev );
        gen++;
        if (used > 1400) { memset( ios_xp_tab, 0, sizeof(ios_xp_tab) ); used = 0; wine_log_write( "[xp] ml1128 thread table reset (gen %u)", gen ); }

        /* per-thread counters */
        if (task_threads( mach_task_self(), &th, &nth ) == KERN_SUCCESS)
        {
            for (k = 0; k < nth; k++)
            {
                thread_identifier_info_data_t idi; mach_msg_type_number_t cnt = THREAD_IDENTIFIER_INFO_COUNT;
                struct ios_xp_tc tc; int got, h, lv;
                struct ios_xp_prev *pv = NULL;
                if (thread_info( th[k], THREAD_IDENTIFIER_INFO, (thread_info_t)&idi, &cnt ) == KERN_SUCCESS)
                {
                    memset( &tc, 0, sizeof(tc) );
                    got = proc_pidinfo( getpid(), 34 /* PROC_PIDTHREADCOUNTS */, idi.thread_id, &tc, sizeof(tc) );
                    if (got > 0 && tc.len >= 1)
                    {
                        struct ios_xp_tcd cur[2]; int nl = tc.len > 2 ? 2 : tc.len;
                        memset( cur, 0, sizeof(cur) );
                        for (lv = 0; lv < nl; lv++) cur[lv] = tc.c[lv];
                        for (h = (int)(idi.thread_id * 2654435761u) & 2047, j = 0; j < 2048; j++, h = (h + 1) & 2047)
                            if (!ios_xp_tab[h].tid || ios_xp_tab[h].tid == idi.thread_id) { pv = &ios_xp_tab[h]; break; }
                        if (pv && pv->tid == idi.thread_id && pv->gen == gen - 1 && nrows < 1024)
                        {
                            struct ios_xp_row *r = &rows[nrows];
                            double pt = XP_MS( (cur[0].ut + cur[0].st) - (pv->c[0].ut + pv->c[0].st) );
                            double et = XP_MS( (cur[1].ut + cur[1].st) - (pv->c[1].ut + pv->c[1].st) );
                            double pcy = (double)(cur[0].cyc - pv->c[0].cyc), ecy = (double)(cur[1].cyc - pv->c[1].cyc);
                            if (pt + et > 0.05)
                            {
                                pthread_t pt_ = pthread_from_mach_thread_np( th[k] );
                                uint64_t teb = pt_ ? ios_ts_teb( pt_ ) : 0; uint32_t w = 0;
                                if (teb) ios_ts_read( teb + 0x48, &w, 4 );
                                r->tid = idi.thread_id; r->wtid = w; r->p_ms = pt; r->e_ms = et;
                                if (!w && pt_ && pt + et >= 2.0) ios_xp_name_native( pt_, idi.thread_id );
                                r->p_ghz = pt > 0 ? pcy / (pt * 1e6) : 0; r->e_ghz = et > 0 ? ecy / (et * 1e6) : 0;
                                r->minst = (double)((cur[0].instr - pv->c[0].instr) + (cur[1].instr - pv->c[1].instr)) / 1e6;
                                r->role = NULL;
                                for (i = 0; i < ios_xp_nroles; i++) if (ios_xp_roles[i].tid == idi.thread_id) { r->role = ios_xp_roles[i].role; break; }
                                if (ios_power_probe_on)   /* madeira-bcd power probe: this thread's energy on P and E cores */
                                {
                                    struct ios_pp_thr *pp = ios_pp_thread( idi.thread_id, w, r->role, (double)(cur[0].nj - pv->c[0].nj) / 1e6,
                                                                           (double)(cur[1].nj - pv->c[1].nj) / 1e6 );
                                    if (pp && pp->pri == -2)   /* a native thread, first time in this window: its base priority (QoS) */
                                    {
                                        thread_extended_info_data_t xi; mach_msg_type_number_t xc = THREAD_EXTENDED_INFO_COUNT;
                                        pp->pri = thread_info( th[k], THREAD_EXTENDED_INFO, (thread_info_t)&xi, &xc ) == KERN_SUCCESS
                                                  ? xi.pth_priority : -1;
                                    }
                                }
                                if (r->role && strchr( r->role, 'P' ) && teb && pt + et >= 1.0)
                                {
                                    uint32_t gp = 0;
                                    ios_ts_read( teb + 0x40, &gp, 4 );   /* ClientId.UniqueProcess */
                                    ios_bg_game_note( gp, w );
                                }
                                if (r->role && teb && (strchr( r->role, 'P' ) || strchr( r->role, 'E' ))) ios_xp_game_teb = teb;   /* ml1131 */
                                if (teb && !ios_xp_nroles) ios_xp_fallback_add( teb, pt + et );   /* ml1131c */
                                sum_thr_ms += pt + et; nrows++;
                            }
                        }
                        if (pv) { if (!pv->tid) used++; pv->tid = idi.thread_id; pv->gen = gen; pv->c[0] = cur[0]; pv->c[1] = cur[1]; }
                    }
                }
                mach_port_deallocate( mach_task_self(), th[k] );
            }
            vm_deallocate( mach_task_self(), (vm_address_t)th, nth * sizeof(*th) );
        }
        if (!(gen % 40)) ios_xp_fallback_pick();   /* ml1131c: every ~10 s */

        /* process counters + PE counters */
        memset( &ru, 0, sizeof(ru) );
        ru_rc = proc_pid_rusage( getpid(), 6, &ru );
        if (ios_xp_pe_block && ios_xp_pe_len >= sizeof(pe)) { memcpy( &pe, (void *)(uintptr_t)ios_xp_pe_block, sizeof(pe) ); }
        else memset( &pe, 0, sizeof(pe) );
        if (!ru_rc && have_ru)
        {
            char wall[16], line[1400]; int n; struct timeval tv; struct tm tmv;
            double cpu = XP_MS( (ru.ri_user_time + ru.ri_system_time) - (pru.ri_user_time + pru.ri_system_time) );
            double pms = XP_MS( (ru.ri_user_ptime + ru.ri_system_ptime) - (pru.ri_user_ptime + pru.ri_system_ptime) );
            double ems = cpu - pms;
            double pcy = (double)(ru.ri_pcycles - pru.ri_pcycles), cy = (double)(ru.ri_cycles - pru.ri_cycles);
            double ins = (double)(ru.ri_instructions - pru.ri_instructions);
            double qf = (have_pe && pe.magic == 0x3130305058444d4dLL && pe.qpf) ? 1000.0 / (double)pe.qpf : 0;
            double page_wait_ms = -1.0; /* unavailable in the build SDK */
#ifdef MADEIRA_HAVE_RUSAGE_PAGE_WAIT_TIME_MACH
            page_wait_ms = XP_MS( ru.ri_page_wait_time_mach - pru.ri_page_wait_time_mach );
#endif
            ios_power_gov_step( ios_bg_now_ns(), dt_ms, (double)(ru.ri_energy_nj - pru.ri_energy_nj) / 1e6 );
            {   /* madeira-bcd fps-gov (opt-in): the frame cap, and madeira-d3d12's copy of it */
                static int64_t prev_t_cap;
                volatile struct ios_xp_pe_cap *pc = ios_xp_pe_block && ios_xp_pe_len >= sizeof(pe) + sizeof(struct ios_xp_pe_cap)
                                                    ? (volatile struct ios_xp_pe_cap *)(uintptr_t)(ios_xp_pe_block + sizeof(pe)) : NULL;
                double paced_ms = __atomic_exchange_n( &ios_fps_paced_ns, 0, __ATOMIC_RELAXED ) / 1e6;
                if (pc && qf) { int64_t t = pc->t_cap; if (prev_t_cap && t >= prev_t_cap) paced_ms += (t - prev_t_cap) * qf; prev_t_cap = t; }
                ios_fps_gov_step( ios_bg_now_ns(), dt_ms, (double)(ru.ri_energy_nj - pru.ri_energy_nj) / 1e6, ios_fps_presents, paced_ms );
                if (pc && pe.magic == 0x3130305058444d4dLL && ios_fps_gov_armed && pc->fps_cap != ios_fps_cap) pc->fps_cap = ios_fps_cap;
            }
            gettimeofday( &tv, NULL ); localtime_r( &tv.tv_sec, &tmv );
            snprintf( wall, sizeof(wall), "%02d:%02d:%02d.%03d", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000) );
            n = snprintf( line, sizeof(line),
                          "[xp] %s +%.2f dt=%.0f cpu=%.0f (thr %.0f) P=%.0f E=%.0f run=%.0f pgw=%.1f GHz P=%.2f E=%.2f Minst=%.0f IPC=%.2f mJ=%.0f pin=%llu rdKB=%llu fpMB=%llu",
                          wall, XP_MS( now - t_start ) / 1000.0, dt_ms, cpu, sum_thr_ms, pms, ems,
                          XP_MS( ru.ri_runnable_time - pru.ri_runnable_time ), page_wait_ms,
                          pms > 0 ? pcy / (pms * 1e6) : 0, ems > 0 ? (cy - pcy) / (ems * 1e6) : 0, ins / 1e6, cy > 0 ? ins / cy : 0,
                          (double)(ru.ri_energy_nj - pru.ri_energy_nj) / 1e6,
                          (unsigned long long)(ru.ri_pageins - pru.ri_pageins), (unsigned long long)((ru.ri_diskio_bytesread - pru.ri_diskio_bytesread) >> 10),
                          (unsigned long long)(ru.ri_phys_footprint >> 20) );
            if (qf && n < (int)sizeof(line))
                snprintf( line + n, sizeof(line) - n,
                          " | pres %lld/%lld thr=%.1f ecl %lld/%.1f sig %lld/%.1f wait %lld/%.1f prs=%.1f (flush %.1f lat %lld/%.1f draw %.1f cmt %.1f) pool=%.1f caller-ecl %lld/%.1f",
                          (long long)(pe.pres_enq - ppe.pres_enq), (long long)(pe.pres_done - ppe.pres_done), (pe.t_thr - ppe.t_thr) * qf,
                          (long long)(pe.n_ecl - ppe.n_ecl), (pe.t_ecl - ppe.t_ecl) * qf, (long long)(pe.n_sig - ppe.n_sig), (pe.t_sig - ppe.t_sig) * qf,
                          (long long)(pe.n_wait - ppe.n_wait), (pe.t_wait - ppe.t_wait) * qf, (pe.t_prs - ppe.t_prs) * qf,
                          (pe.t_flush - ppe.t_flush) * qf, (long long)(pe.n_lat - ppe.n_lat), (pe.t_lat - ppe.t_lat) * qf,
                          (pe.t_draw - ppe.t_draw) * qf, (pe.t_cmt - ppe.t_cmt) * qf, (pe.t_pool - ppe.t_pool) * qf,
                          (long long)(pe.ecl_calls - ppe.ecl_calls), (pe.t_ecl_caller - ppe.t_ecl_caller) * qf );
            wine_log_write( "%s", line );
            /* threads: roles always, then the busiest; role + Windows TID : P ms / E ms : P GHz / E GHz : M instructions */
            {
                int printed[1024] = {0}, shown = 0;
                n = snprintf( line, sizeof(line), "[xp-t] %s", wall );
                for (i = 0; i < nrows && n < (int)sizeof(line) - 48; i++)
                    if (rows[i].role) { printed[i] = 1; shown++;
                        n += snprintf( line + n, sizeof(line) - n, " %s%04x:%.0f/%.0f:%.1f/%.1f:%.0f", rows[i].role, rows[i].wtid,
                                       rows[i].p_ms, rows[i].e_ms, rows[i].p_ghz, rows[i].e_ghz, rows[i].minst ); }
                while (shown < 14 && n < (int)sizeof(line) - 48)
                {
                    int best = -1;
                    for (i = 0; i < nrows; i++)
                        if (!printed[i] && (best < 0 || rows[i].p_ms + rows[i].e_ms > rows[best].p_ms + rows[best].e_ms)) best = i;
                    if (best < 0 || rows[best].p_ms + rows[best].e_ms < 2.0) break;
                    printed[best] = 1; shown++;
                    if (rows[best].wtid)
                        n += snprintf( line + n, sizeof(line) - n, " -%04x:%.0f/%.0f:%.1f/%.1f:%.0f", rows[best].wtid,
                                       rows[best].p_ms, rows[best].e_ms, rows[best].p_ghz, rows[best].e_ghz, rows[best].minst );
                    else
                        n += snprintf( line + n, sizeof(line) - n, " m%llu:%.0f/%.0f:%.1f/%.1f:%.0f", (unsigned long long)rows[best].tid,
                                       rows[best].p_ms, rows[best].e_ms, rows[best].p_ghz, rows[best].e_ghz, rows[best].minst );
                }
                wine_log_write( "%s", line );
            }
            if (!(gen & 3)) ios_xp_api_report( wall, XP_MS( now - t_start ) / 1000.0 );   /* ml1131: ~1 s */
            if (ios_power_probe_on)   /* madeira-bcd power probe: every 5 s; ri_penergy_nj is the uint64 after ri_energy_nj in v6 */
                ios_power_probe_tick( wall, ios_bg_now_ns(), dt_ms, (double)(ru.ri_energy_nj - pru.ri_energy_nj) / 1e6,
                                      (double)((&ru.ri_energy_nj)[1] - (&pru.ri_energy_nj)[1]) / 1e6,
                                      (double)(ru.ri_billed_energy - pru.ri_billed_energy) / 1e6,
                                      (double)(ru.ri_serviced_energy - pru.ri_serviced_energy) / 1e6 );
        }
        else if (ru_rc && gen < 4) wine_log_write( "[xp] ml1128 proc_pid_rusage v6 failed rc=%d errno=%d", ru_rc, errno );
        if (!ru_rc) { pru = ru; have_ru = 1; }
        if (pe.magic == 0x3130305058444d4dLL) { ppe = pe; have_pe = 1; }
        t_prev = now;
#undef XP_MS
    }
}

/* ml1129: WORKER PROFILER (measurement only). The submission worker (role W)
 * retires ~52 M instructions per frame on P-cores (ph-rdr82): the largest
 * single consumer under the power cap. Every 15 s: a 3 s burst at ~1 kHz over
 * the W threads, sampling only while RUNNING, walking the frame-pointer chain.
 *   leaf    : where the pc is (PE module+rva / dylib`symbol / x64-JIT)
 *   d3d12   : first madeira_d3d12.dll frame on the chain (inclusive, our code)
 *   unix    : first Madeira dylib frame on the chain (which bridge call)
 * Symbolize madeira_d3d12 RVAs offline with llvm-objdump --syms of the same DLL. */
struct ios_wp_b { char key[96]; unsigned n; };
static int ios_wp_add( struct ios_wp_b *b, int *nb, int cap, const char *key )
{
    int i;
    for (i = 0; i < *nb; i++) if (!strcmp( b[i].key, key )) { b[i].n++; return 1; }
    if (*nb >= cap) return 0;
    snprintf( b[*nb].key, sizeof(b[*nb].key), "%s", key ); b[*nb].n = 1; (*nb)++;
    return 1;
}
static void ios_wp_print( const char *title, struct ios_wp_b *b, int nb, unsigned total, int top )
{
    int shown = 0; char line[1600]; int n = snprintf( line, sizeof(line), "[wprof] ml1129 %s:", title );
    while (shown < top)
    {
        int i, best = -1;
        for (i = 0; i < nb; i++) if (b[i].n && (best < 0 || b[i].n > b[best].n)) best = i;
        if (best < 0) break;
        if (n > (int)sizeof(line) - 140) { wine_log_write( "%s", line ); n = snprintf( line, sizeof(line), "[wprof] ml1129 %s (cont):", title ); }
        n += snprintf( line + n, sizeof(line) - n, " %s=%.1f%%", b[best].key, total ? 100.0 * b[best].n / total : 0.0 );
        b[best].n = 0; shown++;
    }
    wine_log_write( "%s", line );
}
/* describe one code address: PE image copy -> "mod+rva", native -> "lib`sym+off", else class */
static int ios_wp_desc( uint64_t a, struct ios_ts_map *mp, char *out, size_t cap, int *kind, uint64_t *rva_out )
{
    extern void *ios_jit_rx_base_global; extern size_t ios_jit_pool_size_global;
    extern int ios_jit_pool_image_pc(uintptr_t pc, uintptr_t *pe_addr_out);
    extern int ios_jit_low_contains( uintptr_t a );
    uintptr_t rx0 = (uintptr_t)ios_jit_rx_base_global, pe = 0; uint64_t rva = 0; const char *mod;
    Dl_info di;
    *kind = 0;
    /* madeira-bcd pool-low: region C holds FEX code buffers only */
    if (ios_jit_low_contains( (uintptr_t)a )) { snprintf( out, cap, "x64-JIT" ); *kind = 3; return 1; }
    if (a >= rx0 && a < rx0 + ios_jit_pool_size_global)
    {
        if (!ios_jit_pool_image_pc( a, &pe )) { snprintf( out, cap, "x64-JIT" ); *kind = 3; return 1; }
        a = pe;
    }
    if ((mod = ios_ts_mod_for( mp, a, &rva )))
    {
        snprintf( out, cap, "%s+%llx", mod, (unsigned long long)(rva & ~0xfull) ); *kind = 1;
        if (rva_out) *rva_out = rva;
        if (!strncasecmp( mod, "madeira_d3d12", 13 ) || !strcasecmp( mod, "d3d12.dll" )) *kind = 2;   /* the game loads us as D3D12.DLL */
        return 1;
    }
    if (dladdr( (void *)a, &di ) && di.dli_fname)
    {
        const char *img = strrchr( di.dli_fname, '/' ); img = img ? img + 1 : di.dli_fname;
        if (di.dli_sname) snprintf( out, cap, "%s`%s", img, di.dli_sname );
        else snprintf( out, cap, "%s+%llx", img, (unsigned long long)((a - (uint64_t)di.dli_fbase) & ~0xffull) );
        *kind = strstr( img, "Madeira" ) ? 4 : 5;
        return 1;
    }
    snprintf( out, cap, "?%llx", (unsigned long long)(a & ~0xfffull) ); *kind = 6;
    return 1;
}
static void ios_wprof_main( void )
{
    static struct ios_wp_b leaf[400], inc[300], unx[200], cls[8];
    if (ios_ts_tsd_off < 0) ios_ts_calibrate();
    for (;;)
    {
        thread_act_array_t th = NULL; mach_msg_type_number_t nth = 0, k;
        mach_port_t tw[4]; uint64_t tw_teb[4]; int ntw = 0, s, i;
        int nleaf = 0, ninc = 0, nunx = 0, ncls = 0; unsigned total = 0, walked = 0;
        sleep( 15 );
        if (task_threads( mach_task_self(), &th, &nth ) != KERN_SUCCESS) continue;
        for (k = 0; k < nth; k++)
        {
            thread_identifier_info_data_t idi; mach_msg_type_number_t cnt = THREAD_IDENTIFIER_INFO_COUNT; int keep = 0;
            if (ntw < 4 && thread_info( th[k], THREAD_IDENTIFIER_INFO, (thread_info_t)&idi, &cnt ) == KERN_SUCCESS)
                for (i = 0; i < ios_xp_nroles; i++)
                    if (ios_xp_roles[i].tid == idi.thread_id && strchr( ios_xp_roles[i].role, 'W' ))
                    {
                        pthread_t pt = pthread_from_mach_thread_np( th[k] );
                        tw[ntw] = th[k]; tw_teb[ntw] = pt ? ios_ts_teb( pt ) : 0; ntw++; keep = 1; break;
                    }
            if (!keep) mach_port_deallocate( mach_task_self(), th[k] );
        }
        vm_deallocate( mach_task_self(), (vm_address_t)th, nth * sizeof(*th) );
        if (!ntw) continue;
        for (s = 0; s < 3000; s++)
        {
            int t;
            for (t = 0; t < ntw; t++)
            {
                arm_thread_state64_t st; mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
                thread_basic_info_data_t bi; mach_msg_type_number_t bic = THREAD_BASIC_INFO_COUNT;
                uint64_t chain[16]; int nch = 0, f, kind, have_inc = 0, have_unx = 0; char key[96];
                struct ios_ts_map *mp = ios_ts_map_for_teb( tw_teb[t] );
                if (thread_info( tw[t], THREAD_BASIC_INFO, (thread_info_t)&bi, &bic ) != KERN_SUCCESS || bi.run_state != TH_STATE_RUNNING) continue;
                if (thread_suspend( tw[t] ) != KERN_SUCCESS) continue;
                if (thread_get_state( tw[t], ARM_THREAD_STATE64, (thread_state_t)&st, &cnt ) == KERN_SUCCESS)
                {
                    uint64_t fp = st.__fp, lr = st.__lr;
                    chain[nch++] = st.__pc;
                    if (lr) chain[nch++] = lr;
                    for (f = 0; f < 14 && fp && !(fp & 7) && nch < 16; f++)
                    {
                        uint64_t rec[2];
                        if (!ios_ts_read( fp, rec, 16 )) break;
                        if (rec[1] && rec[1] != lr) chain[nch++] = rec[1] & 0x0000ffffffffffffull;
                        if (rec[0] <= fp) break;
                        fp = rec[0];
                    }
                }
                thread_resume( tw[t] );
                if (!nch) continue;
                total++;
                ios_wp_desc( chain[0], mp, key, sizeof(key), &kind, NULL );
                ios_wp_add( leaf, &nleaf, 400, key );
                {
                    static const char *cn[7] = { "?", "PE-other", "madeira_d3d12", "x64-JIT", "Madeira-dylib", "system-lib", "unknown" };
                    const char *c = cn[kind < 7 ? kind : 6]; char ck[96];
                    if (kind == 1) { snprintf( ck, sizeof(ck), "PE:%s", key ); { char *plus = strchr( ck, '+' ); if (plus) *plus = 0; } c = ck; }
                    else if (kind == 5) { snprintf( ck, sizeof(ck), "lib:%s", key ); { char *e = strpbrk( ck + 4, "`+" ); if (e) *e = 0; } c = ck; }
                    ios_wp_add( cls, &ncls, 8, c ) || ios_wp_add( cls, &ncls, 8, "other" );
                }
                for (f = 0; f < nch; f++)
                {
                    char k2[96]; int kd;
                    ios_wp_desc( chain[f], mp, k2, sizeof(k2), &kd, NULL );
                    if (!have_inc && kd == 2) { ios_wp_add( inc, &ninc, 300, k2 ); have_inc = 1; }
                    if (!have_unx && kd == 4) { ios_wp_add( unx, &nunx, 200, k2 ); have_unx = 1; }
                }
                if (nch > 2) walked++;
            }
            usleep( 1000 );
        }
        for (i = 0; i < ntw; i++) mach_port_deallocate( mach_task_self(), tw[i] );
        wine_log_write( "[wprof] ml1129 burst: %u running samples over %d W thread(s), %u with a frame chain", total, ntw, walked );
        if (!total) continue;
        ios_wp_print( "class", cls, ncls, total, 8 );
        ios_wp_print( "leaf", leaf, nleaf, total, 45 );
        ios_wp_print( "d3d12-inclusive", inc, ninc, total, 45 );
        ios_wp_print( "unix-inclusive", unx, nunx, total, 30 );
    }
}

/* ============================================================================
 * Madeira [frame]: per-second frame anatomy for DXMT titles, opt-in.
 *
 * Question it answers: is a D3D11 game GPU-bound, CPU-bound or held by the
 * display? Logs had no frame or GPU timing at all (only a Metal HUD
 * screenshot), because DXMT's winemetal_unix.c reports into hooks
 * (ios_frame_*, ml1050) whose instrument was not part of this port: they
 * were empty stubs in virtual_ios.c. They are implemented here, behind
 * MADEIRA_FRAME_STATS (unset or 0: off, exactly as before -- ios_frame_stats_on
 * stays 0 and winemetal makes no hook call and adds no completion handler; any
 * other value: on for every caller, 64-bit included). Once a second:
 *
 *   [frame] 1.00 s: present 30.0/s (skipped 0) game 30.0/s |
 *     GPU busy 948 ms = 95% (31.6 ms/frame) | cmdbufs 124, span sum 1010 ms,
 *     in flight max 3 | nextDrawable wait 12.0 ms (max 4.1) | per frame:
 *     render 41.0 compute 9.0 blit 6.0 passes, attachments load 22.0 store
 *     63.0 clear 19.0 | panel 120 Hz intent 60 mode 1 | limiter 0.0 ms
 *
 * "GPU busy" is the union of the command buffers' GPUStartTime..GPUEndTime
 * (ios_frame_gpu_span, for a winemetal that reports it; ours does not yet,
 * so busy reads 0 until it does); "span sum"
 * adds the spans and over-counts when buffers overlap. Busy near 100 % = the
 * GPU is the limit; a large nextDrawable wait = the display/compositor holds
 * the producer; neither = the CPU side. Accumulators are relaxed atomics, the
 * busy union takes one uncontended mutex per command buffer, and the line is
 * printed by whichever per-frame hook first sees a second elapsed. */
int ios_frame_stats_on = 0;
static uint64_t ios_fr_t0;
static uint64_t ios_fr_ticks, ios_fr_presents, ios_fr_skipped, ios_fr_cmdbufs, ios_fr_span_ns, ios_fr_busy_ns;
static uint64_t ios_fr_dw_ns, ios_fr_dw_max_ns, ios_fr_lim_ns, ios_fr_qmax, ios_fr_pass[3], ios_fr_att[3];
static volatile int ios_fr_panel_hz, ios_fr_intent_hz, ios_fr_mode;
static pthread_mutex_t ios_fr_gpu_lock = PTHREAD_MUTEX_INITIALIZER;
static double ios_fr_gpu_end;   /* GPU timeline high-water mark (s), under ios_fr_gpu_lock */

#define IOS_FR_ADD(v, x) __atomic_fetch_add( &(v), (uint64_t)(x), __ATOMIC_RELAXED )
#define IOS_FR_TAKE(v)   __atomic_exchange_n( &(v), 0, __ATOMIC_RELAXED )

static void ios_fr_max( uint64_t *v, uint64_t x )
{
    uint64_t c = __atomic_load_n( v, __ATOMIC_RELAXED );
    while (x > c && !__atomic_compare_exchange_n( v, &c, x, 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED )) ;
}

static void ios_fr_maybe_report( void )
{
    static mach_timebase_info_data_t tb;
    uint64_t now = mach_absolute_time(), t0 = __atomic_load_n( &ios_fr_t0, __ATOMIC_RELAXED ), one_s;
    double secs, frames, busy, span, dw, dwmax, lim;
    uint64_t ticks, pres, skip, cmdbufs, qmax, pass[3], att[3];
    int i;

    if (!tb.denom) mach_timebase_info( &tb );
    one_s = (uint64_t)(1e9 * tb.denom / tb.numer);
    if (!t0) { __atomic_compare_exchange_n( &ios_fr_t0, &t0, now, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED ); return; }
    if (now - t0 < one_s) return;
    if (!__atomic_compare_exchange_n( &ios_fr_t0, &t0, now, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED )) return;   /* another thread reports */

    secs = (double)(now - t0) * tb.numer / tb.denom / 1e9;
    ticks = IOS_FR_TAKE( ios_fr_ticks ); pres = IOS_FR_TAKE( ios_fr_presents ); skip = IOS_FR_TAKE( ios_fr_skipped );
    cmdbufs = IOS_FR_TAKE( ios_fr_cmdbufs ); qmax = IOS_FR_TAKE( ios_fr_qmax );
    busy = IOS_FR_TAKE( ios_fr_busy_ns ) / 1e6; span = IOS_FR_TAKE( ios_fr_span_ns ) / 1e6;
    dw = IOS_FR_TAKE( ios_fr_dw_ns ) / 1e6; dwmax = IOS_FR_TAKE( ios_fr_dw_max_ns ) / 1e6; lim = IOS_FR_TAKE( ios_fr_lim_ns ) / 1e6;
    for (i = 0; i < 3; i++) { pass[i] = IOS_FR_TAKE( ios_fr_pass[i] ); att[i] = IOS_FR_TAKE( ios_fr_att[i] ); }
    frames = pres ? (double)pres : ticks ? (double)ticks : 1.0;
    wine_log_write( "[frame] %.2f s: present %.1f/s (skipped %llu) game %.1f/s | GPU busy %.0f ms = %.0f%% (%.1f ms/frame) | "
                    "cmdbufs %llu, span sum %.0f ms, in flight max %llu | nextDrawable wait %.1f ms (max %.1f) | per frame: render %.1f "
                    "compute %.1f blit %.1f passes, attachments load %.1f store %.1f clear %.1f | panel %d Hz intent %d mode %d | limiter %.1f ms",
                    secs, pres / secs, (unsigned long long)skip, ticks / secs, busy, secs > 0 ? busy / (secs * 10.0) : 0.0, busy / frames,
                    (unsigned long long)cmdbufs, span, (unsigned long long)qmax, dw, dwmax,
                    pass[0] / frames, pass[2] / frames, pass[1] / frames, att[0] / frames, att[1] / frames, att[2] / frames,
                    ios_fr_panel_hz, ios_fr_intent_hz, ios_fr_mode, lim );
}

/* Called once at process init (the sampler arming site): reads the switch. */
static void ios_frame_stats_arm( void )
{
    const char *e = getenv( "MADEIRA_FRAME_STATS" );   /* [frame] once a second: unset/0 off (default), anything else on */
    if (!e || !*e || !strcmp( e, "0" )) return;
    ios_frame_stats_on = 1;
    wine_log_write( "[frame] instrument on (MADEIRA_FRAME_STATS=%s): one line per second with presents, GPU busy "
                    "and nextDrawable wait; unset it for timing-sensitive runs", e );
}

/* The game's Present: once per Present on the presenting thread (winemetal's
 * QueryDisplaySettingForLayer, ml1050). */
void ios_frame_game_tick( void )
{
    if (!ios_frame_stats_on) return;
    IOS_FR_ADD( ios_fr_ticks, 1 );
    ios_fr_maybe_report();
}

/* presentDrawable on the encode thread (skipped: RAW mode dropped the frame) */
void ios_frame_encode_present( int skipped )
{
    if (!ios_frame_stats_on) return;
    if (skipped) IOS_FR_ADD( ios_fr_skipped, 1 ); else IOS_FR_ADD( ios_fr_presents, 1 );
    ios_fr_maybe_report();
}

void ios_frame_drawable_wait( unsigned long long ns )
{
    if (!ios_frame_stats_on) return;
    IOS_FR_ADD( ios_fr_dw_ns, ns );
    ios_fr_max( &ios_fr_dw_max_ns, ns );
}

/* a command buffer completed: its GPU span and how many were in flight */
void ios_frame_gpu( unsigned long long gpu_ns, unsigned long long inflight )
{
    if (!ios_frame_stats_on) return;
    IOS_FR_ADD( ios_fr_cmdbufs, 1 );
    IOS_FR_ADD( ios_fr_span_ns, gpu_ns );
    ios_fr_max( &ios_fr_qmax, inflight );
}

/* the same buffer on the GPU timeline (seconds, CACurrentMediaTime base):
 * the union of these is the time the GPU had work */
void ios_frame_gpu_span( double start_s, double end_s )
{
    double from, add = 0;
    if (!ios_frame_stats_on || !(start_s > 0.0) || !(end_s > start_s)) return;
    pthread_mutex_lock( &ios_fr_gpu_lock );
    from = start_s > ios_fr_gpu_end ? start_s : ios_fr_gpu_end;
    if (end_s > from) add = end_s - from;
    if (end_s > ios_fr_gpu_end) ios_fr_gpu_end = end_s;
    pthread_mutex_unlock( &ios_fr_gpu_lock );
    if (add > 0) IOS_FR_ADD( ios_fr_busy_ns, add * 1e9 );
}

void ios_frame_note_display( int panel_hz, int intent_hz, int mode )
{
    ios_fr_panel_hz = panel_hz; ios_fr_intent_hz = intent_hz; ios_fr_mode = mode;
}

void ios_frame_limiter( unsigned long long ns )
{
    if (ios_frame_stats_on) IOS_FR_ADD( ios_fr_lim_ns, ns );
}

/* kind 0 render, 1 blit, 2 compute; attachments of a render pass */
void ios_frame_pass( unsigned kind, unsigned loads, unsigned stores, unsigned clears )
{
    if (!ios_frame_stats_on) return;
    IOS_FR_ADD( ios_fr_pass[kind < 3 ? kind : 0], 1 );
    IOS_FR_ADD( ios_fr_att[0], loads ); IOS_FR_ADD( ios_fr_att[1], stores ); IOS_FR_ADD( ios_fr_att[2], clears );
}

/* madeira-bcd lean-diag: env.MADEIRA_LEAN_DIAG = 1 (opt-in, read once where the
 * samplers are armed). The periodic diagnostics that suspend threads stop: the
 * [thread-sample] bursts (every thread suspended 4x every 20 s), the guest RIP
 * profile behind [rip-profile]/[cpu-split] (the game's threads suspended ~2,400
 * times in the second after each burst, by a utility-QoS thread that can be
 * preempted while it holds one) and the [wprof] W-thread profiler. [sync-census]
 * keeps its 20 s line and [xp]/[xp-t]/[xp-api]/[xp-api-top] keep their rates, so
 * abline, bucket, xptphase, energyfit, clampstats and apitop read the same
 * fields; tstime has no [thread-sample] lines to tag. The memory walks of
 * virtual_ios.c's warmer thread run every ~10 min instead of every minute. */
static int ios_lean_diag;

/* ml1288: stuck page-crossing store detector, ml1292: and its fix (Ori and the
 * Will of the Wisps, 2026-10-06/07).
 *
 * A game thread sat for 0.3-18 s at ONE store instruction with identical guest
 * registers, ~100% of its time IN THE KERNEL and the task taking ~22,000 page
 * faults a second, while every other thread was idle. The store is a 16- or
 * 32-byte SIMD&FP store (STR Q, STP Q post-index: FEX's translation of guest
 * memcpy and SSE stores) whose bytes cross a 16 KB page, into memory the swap
 * tier maps from its file (share mode TRUESHARED). Both pages read back present
 * and writable, and touching the second page from another thread did not
 * release the thread: the kernel keeps retrying the access without ever
 * completing it.
 *
 * Every 100 ms this check looks at the threads; only a RUNNING thread that
 * spent at least 60% of the interval in the kernel is suspended and read. If
 * it is a guest thread (x28 points at a FEX frame) at a store that crosses a
 * page, at the same pc and address as at the previous check, it is stuck: the
 * store is completed from here a page at a time (ios_store_split_crossing,
 * signal_arm64_ios.c: each part is a single-page write, which the kernel
 * serves normally), the base register written back for the indexed forms, pc
 * moved past it, and the thread resumed. `[stuck-store]` lines report each
 * episode. MADEIRA_STUCK_CHECK=0 turns the check off. */
#define ML1288_SLOTS 64
static struct { uint64_t tid, pc, ea, seen_ms; uint32_t sys_ms, hits; } ios_stuck[ML1288_SLOTS];
static int ios_stuck_logs;
static unsigned long long ios_stuck_fixed;

/* Effective address and size of the load/store at insn (A64), 0 if not one. */
static int ios_ldst_ea( uint32_t insn, const arm_thread_state64_t *st, uint64_t *ea, unsigned *len )
{
    unsigned rn = (insn >> 5) & 31, size = insn >> 30, v = (insn >> 26) & 1, opc = (insn >> 22) & 3;
    unsigned scale = v ? (size | ((opc & 2) << 1)) : size;
    uint64_t base = rn == 31 ? arm_thread_state64_get_sp( *st ) : st->__x[rn];

    if ((insn & 0x3b000000u) == 0x39000000u)            /* LDR/STR, unsigned immediate */
    {
        *ea = base + ((uint64_t)((insn >> 10) & 0xfff) << scale); *len = 1u << scale; return 1;
    }
    if ((insn & 0x3b200c00u) == 0x38200800u)            /* LDR/STR, register offset */
    {
        unsigned rm = (insn >> 16) & 31, option = (insn >> 13) & 7, s = (insn >> 12) & 1;
        uint64_t m = rm == 31 ? 0 : st->__x[rm];
        if (option == 2) m = (uint32_t)m;
        else if (option == 6) m = (uint64_t)(int64_t)(int32_t)m;
        *ea = base + (m << (s ? scale : 0)); *len = 1u << scale; return 1;
    }
    if ((insn & 0x3b200000u) == 0x38000000u)            /* LDUR/STUR, pre/post-index */
    {
        int64_t imm9 = ((int64_t)((insn >> 12) & 0x1ff) << 55) >> 55;
        *ea = ((insn >> 10) & 3) == 1 ? base : base + imm9; *len = 1u << scale; return 1;
    }
    if ((insn & 0x3a000000u) == 0x28000000u)            /* LDP/STP */
    {
        unsigned psc = v ? 2 + (insn >> 30) : 2 + (insn >> 31);
        int64_t imm7 = ((int64_t)((insn >> 15) & 0x7f) << 57) >> 57;
        *ea = ((insn >> 23) & 3) == 1 ? base : base + (imm7 << psc); *len = 2u << psc; return 1;
    }
    if ((insn & 0x3f200c00u) == 0x19000000u)            /* LDAPUR/STLUR */
    {
        int64_t imm9 = ((int64_t)((insn >> 12) & 0x1ff) << 55) >> 55;
        *ea = base + imm9; *len = 1u << size; return 1;
    }
    if ((insn & 0x3f000000u) == 0x08000000u)            /* LDAR/STLR/LDXR family */
    {
        *ea = base; *len = 1u << size; return 1;
    }
    return 0;
}

int ios_store_split_crossing( uint32_t insn, arm_thread_state64_t *st, const arm_neon_state64_t *neon,
                              uintptr_t rx, uintptr_t rw, size_t sz );   /* ml1289, signal_arm64_ios.c */

static void ios_stuck_store_check( void )
{
    extern void *ios_jit_rx_base_global, *ios_jit_rw_base_global;
    extern size_t ios_jit_pool_size_global;
    mach_port_t self_port = pthread_mach_thread_np( pthread_self() );
    thread_act_array_t tl;
    mach_msg_type_number_t tc;
    struct timespec ts;
    uint64_t now;
    unsigned k;

    clock_gettime( CLOCK_MONOTONIC, &ts );
    now = (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
    if (task_threads( mach_task_self(), &tl, &tc ) != KERN_SUCCESS) return;
    for (k = 0; k < tc; k++)
    {
        thread_basic_info_data_t bi;
        thread_identifier_info_data_t idi;
        arm_thread_state64_t st;
        arm_neon_state64_t neon;
        mach_msg_type_number_t bic = THREAD_BASIC_INFO_COUNT, idc = THREAD_IDENTIFIER_INFO_COUNT,
                               cnt = ARM_THREAD_STATE64_COUNT, nc = ARM_NEON_STATE64_COUNT;
        uint64_t pc, bb = 0, ea = 0, dt;
        uint32_t insn = 0, sys, dsys;
        unsigned len = 0, slot, i;
        int got, have_neon, cross;

        if (tl[k] == self_port) continue;
        if (thread_info( tl[k], THREAD_BASIC_INFO, (thread_info_t)&bi, &bic ) != KERN_SUCCESS) continue;
        if (thread_info( tl[k], THREAD_IDENTIFIER_INFO, (thread_info_t)&idi, &idc ) != KERN_SUCCESS) continue;
        sys = bi.system_time.seconds * 1000 + bi.system_time.microseconds / 1000;

        for (slot = 0; slot < ML1288_SLOTS; slot++) if (ios_stuck[slot].tid == idi.thread_id) break;
        if (slot == ML1288_SLOTS)
        {
            for (slot = 0, i = 1; i < ML1288_SLOTS; i++)   /* a free slot, else the longest unseen */
                if (ios_stuck[i].seen_ms < ios_stuck[slot].seen_ms) slot = i;
            ios_stuck[slot].tid = idi.thread_id; ios_stuck[slot].seen_ms = now;
            ios_stuck[slot].sys_ms = sys;
            ios_stuck[slot].pc = 0; ios_stuck[slot].hits = 0;
            continue;
        }
        dt = now - ios_stuck[slot].seen_ms;
        dsys = sys - ios_stuck[slot].sys_ms;
        ios_stuck[slot].seen_ms = now; ios_stuck[slot].sys_ms = sys;
        if (bi.run_state != TH_STATE_RUNNING || !dt || (uint64_t)dsys * 10 < dt * 6)
        {
            ios_stuck[slot].pc = 0; ios_stuck[slot].hits = 0;
            continue;
        }

        /* kernel-bound: read it */
        if (thread_suspend( tl[k] ) != KERN_SUCCESS) continue;
        got = thread_get_state( tl[k], ARM_THREAD_STATE64, (thread_state_t)&st, &cnt ) == KERN_SUCCESS;
        have_neon = thread_get_state( tl[k], ARM_NEON_STATE64, (thread_state_t)&neon, &nc ) == KERN_SUCCESS;
        if (!got || !ios_ts_read( st.__x[28], &bb, 8 ) || bb <= 0x10000)   /* not in FEX state */
        {
            thread_resume( tl[k] );
            continue;
        }
        pc = arm_thread_state64_get_pc( st );
        cross = ios_ts_read( pc, &insn, 4 ) && ios_ldst_ea( insn, &st, &ea, &len ) &&
                ((ea ^ (ea + len - 1)) & ~(uint64_t)(vm_page_size - 1));
        if (cross && ios_stuck[slot].pc == pc && ios_stuck[slot].ea == ea)
        {
            unsigned hits = ++ios_stuck[slot].hits;
            int r = ios_store_split_crossing( insn, &st, have_neon ? &neon : NULL,
                                              (uintptr_t)ios_jit_rx_base_global, (uintptr_t)ios_jit_rw_base_global,
                                              ios_jit_pool_size_global );
            if (r > 0)
            {
                __darwin_arm_thread_state64_set_pc_fptr( st, (void *)(uintptr_t)(pc + 4) );
                if (thread_set_state( tl[k], ARM_THREAD_STATE64, (thread_state_t)&st, ARM_THREAD_STATE64_COUNT ) != KERN_SUCCESS)
                    r = -2;   /* the store is written, pc not moved: the thread redoes the same bytes */
                else
                    ios_stuck_fixed++;
            }
            thread_resume( tl[k] );
            if (ios_stuck_logs < 400 && (r > 0 || hits <= 3 || hits % 10 == 0))
            {
                ios_stuck_logs++;
                wine_log_write( "[stuck-store] ml1292 tid=%llu hits=%u pc=0x%llx insn=%08x ea=0x%llx len=%u "
                                "sys+%u ms in %llu ms: %s (%llu completed so far)",
                                (unsigned long long)idi.thread_id, hits, (unsigned long long)pc, insn,
                                (unsigned long long)ea, len, dsys, (unsigned long long)dt,
                                r > 0 ? "completed, pc+4" : r == -2 ? "written, set_state FAILED"
                                : r < 0 ? "refused (a page not writable)" : "not a store it decodes", ios_stuck_fixed );
            }
            if (r > 0) { ios_stuck[slot].pc = 0; ios_stuck[slot].hits = 0; }
        }
        else
        {
            thread_resume( tl[k] );
            ios_stuck[slot].pc = cross ? pc : 0;
            ios_stuck[slot].ea = cross ? ea : 0;
        }
    }
    for (k = 0; k < tc; k++) mach_port_deallocate( mach_task_self(), tl[k] );
    vm_deallocate( mach_task_self(), (vm_address_t)tl, tc * sizeof(*tl) );
}

static void ios_thread_sampler_main(void)
{
    int gen = 0;
    /* ml1288: MADEIRA_STUCK_CHECK=0 turns off the check that completes a store stuck across a 16 KB page. */
    const char *sc = getenv( "MADEIRA_STUCK_CHECK" );
    const int stuck_check = !(sc && sc[0] == '0');
    ios_ts_calibrate();
    wine_log_write(ios_lean_diag ? "[thread-sample] ml876 armed for [sync-census] only (MADEIRA_LEAN_DIAG: no bursts, no guest RIP profile)"
                                 : "[thread-sample] ml876 armed (task-wide: burst of 4 passes / 250 ms every 20 s)");
    for (;;) {
        int b;
        unsigned tick;
        for (tick = 0; tick < 200; tick++)   /* ml1288: the stuck-store check every 100 ms between bursts */
        {
            usleep( 100000 );
            if (stuck_check && !ios_lean_diag) ios_stuck_store_check();
        }
        if (!ios_lean_diag) {
        for (b = 0; b < 4; b++) { ios_thread_sampler_pass(b); usleep(250000); }
        wine_log_write("[thread-sample] ml876 burst done");
        }
        {   /* ml1115: alert (futex) traffic since the last burst, per second */
            extern volatile long long ios_alert_wakes, ios_alert_waits, ios_qpc_syscalls, ios_affinity_sets; extern volatile int ios_srv_req_count;
            extern volatile long long ios_alert_lat_n, ios_alert_lat_ticks, ios_alert_lat_hist[6], ios_alert_spin_tries, ios_alert_spin_hits;
            static long long l_n, l_t, l_h[6], l_st, l_sh; long long dn = ios_alert_lat_n - l_n; int hb;
            {
                mach_timebase_info_data_t tb; double tpu; mach_timebase_info( &tb ); tpu = 1000.0 * tb.denom / tb.numer;
                wine_log_write( "[sync-census] ml1122 alert wake latency: %lld samples, avg %.1f us, <5us %lld, <20 %lld, <50 %lld, <100 %lld, <500 %lld, >=500 %lld; spin %lld tries %lld hits",
                                dn, dn ? (ios_alert_lat_ticks - l_t) / tpu / dn : 0.0,
                                ios_alert_lat_hist[0] - l_h[0], ios_alert_lat_hist[1] - l_h[1], ios_alert_lat_hist[2] - l_h[2],
                                ios_alert_lat_hist[3] - l_h[3], ios_alert_lat_hist[4] - l_h[4], ios_alert_lat_hist[5] - l_h[5],
                                ios_alert_spin_tries - l_st, ios_alert_spin_hits - l_sh );
                l_n = ios_alert_lat_n; l_t = ios_alert_lat_ticks; for (hb = 0; hb < 6; hb++) l_h[hb] = ios_alert_lat_hist[hb];
                l_st = ios_alert_spin_tries; l_sh = ios_alert_spin_hits;
            }
            static long long last_wakes, last_waits, last_qpc, last_aff; static int last_req; static struct timespec last_t;
            struct timespec now; double dt;
            clock_gettime( CLOCK_MONOTONIC, &now );
            dt = last_t.tv_sec ? (now.tv_sec - last_t.tv_sec) + (now.tv_nsec - last_t.tv_nsec) / 1e9 : 0;
            if (dt > 0)
                wine_log_write( "[sync-census] ml1115 thread alerts: %.0f wakes/s, %.0f waits/s; ml1117 server requests %.0f/s, "
                                "QPC syscalls %.0f/s, SetThreadAffinityMask %.0f/s (over %.1f s)",
                                (ios_alert_wakes - last_wakes) / dt, (ios_alert_waits - last_waits) / dt,
                                (ios_srv_req_count - last_req) / dt, (ios_qpc_syscalls - last_qpc) / dt,
                                (ios_affinity_sets - last_aff) / dt, dt );
            last_wakes = ios_alert_wakes; last_waits = ios_alert_waits; last_qpc = ios_qpc_syscalls;
            last_aff = ios_affinity_sets; last_req = ios_srv_req_count; last_t = now;
        }
        /* ml979: profile the guest every third burst (~once a minute). Two
         * successive profiles are what distinguish a loop from a sweep: a
         * sweep's span and bucket set move, a loop's do not. */
        if (!ios_lean_diag) { ++gen; ios_guest_rip_profile( gen ); }   /* ml1123: every burst (was every third) */
    }
}


/* iOS-Madeira 2026-07-05: per-present frame-anatomy counters, read by
 * winemetal_unix's Present-cadence log line (same binary). The wait
 * accounting is gated to the GAME thread (main Wine thread, captured in
 * server_init_process_done) so FMOD/worker threads blocking forever in
 * waits don't swamp the signal. Question they answer: is the last
 * ~1.5ms to locked-60 server-request WORK or wait-wake LATENCY? */
volatile long long ios_srv_wait_us = 0;   /* game thread: wall us blocked in server_wait */
volatile long long ios_srv_wait_req_us = 0; /* game thread: REQUESTED timeout us (finite waits) */
volatile int ios_srv_wait_count = 0;      /* game thread: server_wait calls */
volatile int ios_srv_wait_timeouts = 0;   /* ... of which returned STATUS_TIMEOUT */
volatile int ios_srv_req_count = 0;       /* ALL threads: wineserver requests */
uintptr_t ios_srv_game_teb = 0;           /* set once by server_init_process_done */

#ifdef WINE_IOS
/* madeira-bcd: direct requests (env.MADEIRA_SRV_DIRECT, off by default; the server side is
 * build/wineserver/request_ios.c ios_srv_direct_call, set per launch by WineProcessBridge.m).
 * A request the server lists runs on this thread under the server's lock and its reply
 * comes back in req as wait_reply would leave it; anything the server does not take goes
 * through the pipe below as before. A request that ended this thread is not taken either:
 * the server has closed the thread's pipes by then, so the write below fails with EPIPE
 * and that path reports it exactly as it does today. */
extern volatile int g_madeira_srv_direct;
extern int ios_srv_direct_call( unsigned int tid, client_ptr_t teb, const union generic_request *request,
                                const struct iovec *vec, unsigned int count,
                                union generic_reply *reply, void *reply_data );

static BOOL ios_srv_try_direct( struct __server_request_info *req, unsigned int *status )
{
    struct iovec vec[__SERVER_MAX_DATA];
    unsigned int i;
    int ret, err = errno;   /* the handler's own system calls must not change this thread's errno */

    for (i = 0; i < req->data_count; i++)
    {
        vec[i].iov_base = (void *)req->data[i].ptr;
        vec[i].iov_len = req->data[i].size;
    }
    ret = ios_srv_direct_call( HandleToULong( NtCurrentTeb()->ClientId.UniqueThread ),
                               (client_ptr_t)(ULONG_PTR)NtCurrentTeb(), &req->u.req, vec, req->data_count,
                               &req->u.reply, req->reply_data );
    errno = err;
    if (ret <= 0) return FALSE;
    *status = req->u.reply.reply_header.error;
    return TRUE;
}
#endif

/***********************************************************************
 *           server_call_unlocked
 */
unsigned int server_call_unlocked( void *req_ptr )
{
    struct __server_request_info * const req = req_ptr;
    unsigned int ret;

    ios_srv_req_count++;
#ifdef WINE_IOS
    /* killed inside a section (ios_defer_section_abort): no more requests */
    if (ios_section_state() & IOS_SECTION_ABORT) return STATUS_THREAD_IS_TERMINATING;
    ios_bg_qos_check();   /* [bg-qos] */
    if (__atomic_load_n( &g_madeira_srv_direct, __ATOMIC_RELAXED ) > 0 && ios_srv_try_direct( req, &ret ))
        return ret;   /* madeira-bcd: MADEIRA_SRV_DIRECT */
#endif
    if ((ret = send_request( req ))) return ret;
    /* iOS-Madeira 2026-07-05: kick the in-process server loop out of its
     * tick sleep so the request is picked up in ~50us instead of waiting
     * for the next 1ms iteration (fd_ios.c ios_srv_wake_sem). */
    {
        /* madeira-bcd doorbell: name the thread, so the loop reads only its
         * request fd (fd_ios.c ios_srv_bell); a ring also wakes the loop */
        extern void ios_wineserver_ring( unsigned int tid );
        ios_wineserver_ring( HandleToULong( NtCurrentTeb()->ClientId.UniqueThread ) );
    }
    return wait_reply( req );
}


/***********************************************************************
 *           wine_server_call
 *
 * Perform a server call.
 */
unsigned int CDECL wine_server_call( void *req_ptr )
{
    sigset_t old_set;
    unsigned int ret;

    pthread_sigmask( SIG_BLOCK, &server_block_set, &old_set );
    ret = server_call_unlocked( req_ptr );
    pthread_sigmask( SIG_SETMASK, &old_set, NULL );
    return ret;
}


/***********************************************************************
 *           unixcall_wine_server_call
 *
 * Perform a server call.
 */
NTSTATUS unixcall_wine_server_call( void *args )
{
    return wine_server_call( args );
}


/***********************************************************************
 *           server_enter_uninterrupted_section
 */
void server_enter_uninterrupted_section( pthread_mutex_t *mutex, sigset_t *sigset )
{
    pthread_sigmask( SIG_BLOCK, &server_block_set, sigset );
    mutex_lock( mutex );
#ifdef WINE_IOS
    ios_section_set_state( ios_section_state() + 1 );
#endif
}


/***********************************************************************
 *           server_leave_uninterrupted_section
 */
void server_leave_uninterrupted_section( pthread_mutex_t *mutex, sigset_t *sigset )
{
#ifdef WINE_IOS
    uintptr_t state = ios_section_state() - 1;

    ios_section_set_state( state );
#endif
    mutex_unlock( mutex );
    pthread_sigmask( SIG_SETMASK, sigset, NULL );
#ifdef WINE_IOS
    /* a request inside the section found this thread killed: exit now that it is out */
    if (state == IOS_SECTION_ABORT)
    {
        ios_section_set_state( IOS_SECTION_ABORT | IOS_SECTION_EXITING );
        abort_thread( 0 );
    }
#endif
}


/***********************************************************************
 *              wait_select_reply
 *
 * Wait for a reply on the waiting pipe of the current thread.
 */
static int wait_select_reply( void *cookie )
{
    int signaled;
    struct wake_up_reply reply;
    for (;;)
    {
        int ret;
        ret = read( ntdll_get_thread_data()->wait_fd[0], &reply, sizeof(reply) );
        if (ret == sizeof(reply))
        {
            if (!reply.cookie) abort_thread( reply.signaled );  /* thread got killed */
            if (wine_server_get_ptr(reply.cookie) == cookie) return reply.signaled;
            /* we stole another reply, wait for the real one */
            signaled = wait_select_reply( cookie );
            /* and now put the wrong one back in the pipe */
            for (;;)
            {
                ret = write( ntdll_get_thread_data()->wait_fd[1], &reply, sizeof(reply) );
                if (ret == sizeof(reply)) break;
                if (ret >= 0) server_protocol_error( "partial wakeup write %d\n", ret );
                if (errno == EINTR) continue;
                server_protocol_perror("wakeup write");
            }
            return signaled;
        }
        if (ret >= 0)
        {
#ifdef WINE_IOS
            ios_fdt_autopsy( "wakeup-read", ntdll_get_thread_data()->wait_fd[0], ret, 0 );
#endif
            server_protocol_error( "partial wakeup read %d\n", ret );
        }
        if (errno == EINTR) continue;
#ifdef WINE_IOS
        {
            int saved_errno = errno;
            ios_fdt_autopsy( "wakeup-read", ntdll_get_thread_data()->wait_fd[0], ret, saved_errno );
            errno = saved_errno;
        }
#endif
        server_protocol_perror("wakeup read");
    }
}


/***********************************************************************
 *              invoke_user_apc
 */
static NTSTATUS invoke_user_apc( CONTEXT *context, const struct user_apc *apc, NTSTATUS status )
{
    return call_user_apc_dispatcher( context, apc->flags, apc->args[0], apc->args[1], apc->args[2],
                                     wine_server_get_ptr( apc->func ), status );
}


/* Madeira iosb-guard: an async I/O completion in a 32-bit pseudo-process writes an
 * IO_STATUS_BLOCK32 (status + information, 8 bytes) to the address the request carried.
 * ntdll picks the 32-bit layout from the calling pseudo-process, not from the call, so
 * a write issued by 64-bit native code running inside a 32-bit process (the emulator's
 * own console output, with an uninitialised 64-bit status block) hands back a stale
 * stack value as that address. The store then faulted on an unmapped page, the
 * redelivery guard looped on it, and on an unlucky day it could land somewhere mapped.
 *
 * The store is kept when the address is in the process's own 4 GB guest window, when
 * the fault path would serve it below the iOS floor (a sub-floor image window or a low
 * allocation), or when all 8 bytes lie in some task mapping (any protection: the fault
 * path may heal it); a pointer into a hole is dropped with an "[iosb-guard]" line.
 * 64-bit processes are never checked. env.MADEIRA_IOSB_DEAD_TARGET=0 always stores.
 * The two probes live in signal_arm64_ios.c and never dereference the address. */
extern int ios_iosb_probe_mapped( unsigned long long addr, unsigned long long len );
extern int ios_iosb_probe_served_low( unsigned long long addr, unsigned long long len );

#define IOS_IOSB_GUARD_BYTES   8ull             /* IO_STATUS_BLOCK32 */
#define IOS_IOSB_GUARD_WINDOW  0x100000000ull   /* one guest window */
#define IOS_IOSB_GUARD_FLOOR   0x100000000ull   /* iOS maps nothing below 4 GB */

static int ios_iosb_guard_on( void )
{
    static int on = -1;
    if (on < 0)
    {
        const char *e = getenv( "MADEIRA_IOSB_DEAD_TARGET" );
        on = !(e && e[0] == '0' && !e[1]);
    }
    return on;
}

/* 1 when an IO_STATUS_BLOCK32 written at `addr` reaches memory (or might), 0 for a hole. */
static int ios_iosb32_store_lands( unsigned long long addr, unsigned long long window )
{
    if (addr + IOS_IOSB_GUARD_BYTES < addr) return 0;
    if (window && addr >= window && addr - window < IOS_IOSB_GUARD_WINDOW) return 1;
    if (addr < IOS_IOSB_GUARD_FLOOR) return ios_iosb_probe_served_low( addr, IOS_IOSB_GUARD_BYTES );
    return ios_iosb_probe_mapped( addr, IOS_IOSB_GUARD_BYTES );
}

static void ios_set_async_iosb( client_ptr_t iosb, NTSTATUS status, ULONG_PTR info )
{
    if (iosb && in_wow64_call() && ios_iosb_guard_on() && !ios_iosb32_store_lands( iosb, ios_wow_base() ))
    {
        static volatile unsigned dropped;
        unsigned n = __sync_add_and_fetch( &dropped, 1 );

        if (n <= 8 || !(n & (n - 1)))
            dprintf( 2, "[iosb-guard] #%u 32-bit process (window %p): async completion status=%#x info=%#llx not stored, "
                     "%#llx is not memory (env.MADEIRA_IOSB_DEAD_TARGET=0 stores anyway)\n",
                     n, (void *)ios_wow_base(), (unsigned)status, (unsigned long long)info, (unsigned long long)iosb );
        return;
    }
    set_async_iosb( iosb, status, info );
}


/***********************************************************************
 *              invoke_system_apc
 */
static void invoke_system_apc( const union apc_call *call, union apc_result *result, BOOL self )
{
    SIZE_T size, bits;
    void *addr;

    memset( result, 0, sizeof(*result) );

    switch (call->type)
    {
    case APC_NONE:
        break;
    case APC_ASYNC_IO:
    {
        struct async_fileio *user = wine_server_get_ptr( call->async_io.user );
        ULONG_PTR info = call->async_io.result;
        unsigned int status;

        result->type = call->type;
        status = call->async_io.status;
        if (user->callback( user, &info, &status ))
        {
            result->async_io.status = status;
            result->async_io.total = info;
            /* the server will pass us NULL if a call failed synchronously */
            ios_set_async_iosb( call->async_io.sb, result->async_io.status, info );
        }
        else result->async_io.status = STATUS_PENDING; /* restart it */
        break;
    }
    /* in every APC below, `addr` is a
     * client_ptr_t and therefore a HOST address (one namespace per process),
     * while zero_bits / limit_low / limit_high are GUEST-namespace ceilings.
     * Nothing is converted here: these calls execute inside the TARGET
     * process, so NtAllocateVirtualMemory / NtMapViewOfSection / the
     * MEM_ADDRESS_REQUIREMENTS path translate the ceiling into that
     * process's own window.  Do not "fix" this by adding B here. */
    case APC_VIRTUAL_ALLOC:
        result->type = call->type;
        addr = wine_server_get_ptr( call->virtual_alloc.addr );
        size = call->virtual_alloc.size;
        bits = call->virtual_alloc.zero_bits;
        if ((ULONG_PTR)addr == call->virtual_alloc.addr && size == call->virtual_alloc.size &&
            bits == call->virtual_alloc.zero_bits)
        {
            result->virtual_alloc.status = NtAllocateVirtualMemory( NtCurrentProcess(), &addr, bits, &size,
                                                                    call->virtual_alloc.op_type,
                                                                    call->virtual_alloc.prot );
            result->virtual_alloc.addr = wine_server_client_ptr( addr );
            result->virtual_alloc.size = size;
        }
        else result->virtual_alloc.status = STATUS_WORKING_SET_LIMIT_RANGE;
        break;
    case APC_VIRTUAL_ALLOC_EX:
    {
        MEM_ADDRESS_REQUIREMENTS r;
        MEM_EXTENDED_PARAMETER ext[2];
        ULONG count = 0;

        result->type = call->type;
        addr = wine_server_get_ptr( call->virtual_alloc_ex.addr );
        size = call->virtual_alloc_ex.size;
        if ((ULONG_PTR)addr != call->virtual_alloc_ex.addr || size != call->virtual_alloc_ex.size)
        {
            result->virtual_alloc_ex.status = STATUS_WORKING_SET_LIMIT_RANGE;
            break;
        }
        if (call->virtual_alloc_ex.limit_low || call->virtual_alloc_ex.limit_high || call->virtual_alloc_ex.align)
        {
            SIZE_T limit_low, limit_high, align;

            /* madeira-bcd: the real limit, not the reported one (see ios_highest_user_address) */
            limit_low = call->virtual_alloc_ex.limit_low;
            limit_high = min( ios_highest_user_address( is_wow64() ), call->virtual_alloc_ex.limit_high );
            align = call->virtual_alloc_ex.align;
            if (limit_low != call->virtual_alloc_ex.limit_low || align != call->virtual_alloc_ex.align)
            {
                result->virtual_alloc_ex.status = STATUS_WORKING_SET_LIMIT_RANGE;
                break;
            }
            r.LowestStartingAddress = (void *)limit_low;
            r.HighestEndingAddress = (void *)limit_high;
            r.Alignment = align;
            ext[count].Type = MemExtendedParameterAddressRequirements;
            ext[count].Pointer = &r;
            count++;
        }
        if (call->virtual_alloc_ex.attributes)
        {
            ext[count].Type = MemExtendedParameterAttributeFlags;
            ext[count].ULong64 = call->virtual_alloc_ex.attributes;
            count++;
        }
        result->virtual_alloc_ex.status = NtAllocateVirtualMemoryEx( NtCurrentProcess(), &addr, &size,
                                                                     call->virtual_alloc_ex.op_type,
                                                                     call->virtual_alloc_ex.prot,
                                                                     ext, count );
        result->virtual_alloc_ex.addr = wine_server_client_ptr( addr );
        result->virtual_alloc_ex.size = size;
        break;
    }
    case APC_VIRTUAL_FREE:
        result->type = call->type;
        addr = wine_server_get_ptr( call->virtual_free.addr );
        size = call->virtual_free.size;
        if ((ULONG_PTR)addr == call->virtual_free.addr && size == call->virtual_free.size)
        {
            result->virtual_free.status = NtFreeVirtualMemory( NtCurrentProcess(), &addr, &size,
                                                               call->virtual_free.op_type );
            result->virtual_free.addr = wine_server_client_ptr( addr );
            result->virtual_free.size = size;
        }
        else result->virtual_free.status = STATUS_INVALID_PARAMETER;
        break;
    case APC_VIRTUAL_QUERY:
    {
        MEMORY_BASIC_INFORMATION info;
        result->type = call->type;
        addr = wine_server_get_ptr( call->virtual_query.addr );
        if ((ULONG_PTR)addr == call->virtual_query.addr)
            result->virtual_query.status = NtQueryVirtualMemory( NtCurrentProcess(),
                                                                 addr, MemoryBasicInformation, &info,
                                                                 sizeof(info), NULL );
        else
            result->virtual_query.status = STATUS_WORKING_SET_LIMIT_RANGE;

        if (result->virtual_query.status == STATUS_SUCCESS)
        {
            result->virtual_query.base       = wine_server_client_ptr( info.BaseAddress );
            result->virtual_query.alloc_base = wine_server_client_ptr( info.AllocationBase );
            result->virtual_query.size       = info.RegionSize;
            result->virtual_query.prot       = info.Protect;
            result->virtual_query.alloc_prot = info.AllocationProtect;
            result->virtual_query.state      = info.State >> 12;
            result->virtual_query.alloc_type = info.Type >> 16;
        }
        break;
    }
    case APC_VIRTUAL_PROTECT:
        result->type = call->type;
        addr = wine_server_get_ptr( call->virtual_protect.addr );
        size = call->virtual_protect.size;
        if ((ULONG_PTR)addr == call->virtual_protect.addr && size == call->virtual_protect.size)
        {
            ULONG prot;
            result->virtual_protect.status = NtProtectVirtualMemory( NtCurrentProcess(), &addr, &size,
                                                                     call->virtual_protect.prot, &prot );
            result->virtual_protect.addr = wine_server_client_ptr( addr );
            result->virtual_protect.size = size;
            result->virtual_protect.prot = prot;
        }
        else result->virtual_protect.status = STATUS_INVALID_PARAMETER;
        break;
    case APC_VIRTUAL_FLUSH:
        result->type = call->type;
        addr = wine_server_get_ptr( call->virtual_flush.addr );
        size = call->virtual_flush.size;
        if ((ULONG_PTR)addr == call->virtual_flush.addr && size == call->virtual_flush.size)
        {
            result->virtual_flush.status = NtFlushVirtualMemory( NtCurrentProcess(),
                                                                 (const void **)&addr, &size, 0 );
            result->virtual_flush.addr = wine_server_client_ptr( addr );
            result->virtual_flush.size = size;
        }
        else result->virtual_flush.status = STATUS_INVALID_PARAMETER;
        break;
    case APC_VIRTUAL_LOCK:
        result->type = call->type;
        addr = wine_server_get_ptr( call->virtual_lock.addr );
        size = call->virtual_lock.size;
        if ((ULONG_PTR)addr == call->virtual_lock.addr && size == call->virtual_lock.size)
        {
            result->virtual_lock.status = NtLockVirtualMemory( NtCurrentProcess(), &addr, &size, 0 );
            result->virtual_lock.addr = wine_server_client_ptr( addr );
            result->virtual_lock.size = size;
        }
        else result->virtual_lock.status = STATUS_INVALID_PARAMETER;
        break;
    case APC_VIRTUAL_UNLOCK:
        result->type = call->type;
        addr = wine_server_get_ptr( call->virtual_unlock.addr );
        size = call->virtual_unlock.size;
        if ((ULONG_PTR)addr == call->virtual_unlock.addr && size == call->virtual_unlock.size)
        {
            result->virtual_unlock.status = NtUnlockVirtualMemory( NtCurrentProcess(), &addr, &size, 0 );
            result->virtual_unlock.addr = wine_server_client_ptr( addr );
            result->virtual_unlock.size = size;
        }
        else result->virtual_unlock.status = STATUS_INVALID_PARAMETER;
        break;
    case APC_MAP_VIEW:
        result->type = call->type;
        addr = wine_server_get_ptr( call->map_view.addr );
        size = call->map_view.size;
        bits = call->map_view.zero_bits;
        if ((ULONG_PTR)addr == call->map_view.addr && size == call->map_view.size &&
            bits == call->map_view.zero_bits)
        {
            LARGE_INTEGER offset;
            offset.QuadPart = call->map_view.offset;
            result->map_view.status = NtMapViewOfSection( wine_server_ptr_handle(call->map_view.handle),
                                                          NtCurrentProcess(),
                                                          &addr, bits, 0, &offset, &size, 0,
                                                          call->map_view.alloc_type, call->map_view.prot );
            result->map_view.addr = wine_server_client_ptr( addr );
            result->map_view.size = size;
        }
        else result->map_view.status = STATUS_INVALID_PARAMETER;
        if (!self) NtClose( wine_server_ptr_handle(call->map_view.handle) );
        break;
    case APC_MAP_VIEW_EX:
    {
        MEM_ADDRESS_REQUIREMENTS addr_req;
        MEM_EXTENDED_PARAMETER ext[2];
        ULONG count = 0;
        LARGE_INTEGER offset;
        ULONG_PTR limit_low, limit_high;

        result->type = call->type;
        addr = wine_server_get_ptr( call->map_view_ex.addr );
        size = call->map_view_ex.size;
        offset.QuadPart = call->map_view_ex.offset;
        limit_low = call->map_view_ex.limit_low;
        if ((ULONG_PTR)addr != call->map_view_ex.addr || size != call->map_view_ex.size ||
            limit_low != call->map_view_ex.limit_low)
        {
            result->map_view_ex.status = STATUS_WORKING_SET_LIMIT_RANGE;
            break;
        }
        if (call->map_view_ex.limit_low || call->map_view_ex.limit_high)
        {
            /* madeira-bcd: the real limit, not the reported one (see ios_highest_user_address) */
            limit_high = min( ios_highest_user_address( is_wow64() ), call->map_view_ex.limit_high );
            addr_req.LowestStartingAddress = (void *)limit_low;
            addr_req.HighestEndingAddress = (void *)limit_high;
            addr_req.Alignment = 0;
            ext[count].Type = MemExtendedParameterAddressRequirements;
            ext[count].Pointer = &addr_req;
            count++;
        }
        if (call->map_view_ex.machine)
        {
            ext[count].Type = MemExtendedParameterImageMachine;
            ext[count].ULong = call->map_view_ex.machine;
            count++;
        }
        result->map_view_ex.status = NtMapViewOfSectionEx( wine_server_ptr_handle(call->map_view_ex.handle),
                                                           NtCurrentProcess(), &addr, &offset, &size,
                                                           call->map_view_ex.alloc_type,
                                                           call->map_view_ex.prot, ext, count );
        result->map_view_ex.addr = wine_server_client_ptr( addr );
        result->map_view_ex.size = size;
        if (!self) NtClose( wine_server_ptr_handle(call->map_view_ex.handle) );
        break;
    }
    case APC_UNMAP_VIEW:
        result->type = call->type;
        addr = wine_server_get_ptr( call->unmap_view.addr );
        if ((ULONG_PTR)addr == call->unmap_view.addr)
            result->unmap_view.status = NtUnmapViewOfSectionEx( NtCurrentProcess(), addr, call->unmap_view.flags );
        else
            result->unmap_view.status = STATUS_INVALID_PARAMETER;
        break;
    case APC_CREATE_THREAD:
    {
        ULONG_PTR buffer[offsetof( PS_ATTRIBUTE_LIST, Attributes[2] ) / sizeof(ULONG_PTR)];
        PS_ATTRIBUTE_LIST *attr = (PS_ATTRIBUTE_LIST *)buffer;
        CLIENT_ID id;
        HANDLE handle;
        TEB *teb;
        ULONG_PTR zero_bits = call->create_thread.zero_bits;
        SIZE_T reserve = call->create_thread.reserve;
        SIZE_T commit = call->create_thread.commit;
        void *func = wine_server_get_ptr( call->create_thread.func );
        void *arg  = wine_server_get_ptr( call->create_thread.arg );

        result->type = call->type;
        if (reserve == call->create_thread.reserve && commit == call->create_thread.commit &&
            (ULONG_PTR)func == call->create_thread.func && (ULONG_PTR)arg == call->create_thread.arg)
        {
            /* FIXME: hack for debugging 32-bit process without a 64-bit ntdll */
            if (is_old_wow64() && func == (void *)0x7ffe1000) func = pDbgUiRemoteBreakin;
            attr->TotalLength = sizeof(buffer);
            attr->Attributes[0].Attribute    = PS_ATTRIBUTE_CLIENT_ID;
            attr->Attributes[0].Size         = sizeof(id);
            attr->Attributes[0].ValuePtr     = &id;
            attr->Attributes[0].ReturnLength = NULL;
            attr->Attributes[1].Attribute    = PS_ATTRIBUTE_TEB_ADDRESS;
            attr->Attributes[1].Size         = sizeof(teb);
            attr->Attributes[1].ValuePtr     = &teb;
            attr->Attributes[1].ReturnLength = NULL;
            result->create_thread.status = NtCreateThreadEx( &handle, THREAD_ALL_ACCESS, NULL,
                                                             NtCurrentProcess(), func, arg,
                                                             call->create_thread.flags, zero_bits,
                                                             commit, reserve, attr );
            result->create_thread.handle = wine_server_obj_handle( handle );
            result->create_thread.pid = HandleToULong(id.UniqueProcess);
            result->create_thread.tid = HandleToULong(id.UniqueThread);
            result->create_thread.teb = wine_server_client_ptr( teb );
        }
        else result->create_thread.status = STATUS_INVALID_PARAMETER;
        break;
    }
    case APC_DUP_HANDLE:
    {
        HANDLE dst_handle = NULL;

        result->type = call->type;

        result->dup_handle.status = NtDuplicateObject( NtCurrentProcess(),
                                                       wine_server_ptr_handle(call->dup_handle.src_handle),
                                                       wine_server_ptr_handle(call->dup_handle.dst_process),
                                                       &dst_handle, call->dup_handle.access,
                                                       call->dup_handle.attributes, call->dup_handle.options );
        result->dup_handle.handle = wine_server_obj_handle( dst_handle );
        if (!self) NtClose( wine_server_ptr_handle(call->dup_handle.dst_process) );
        break;
    }
    default:
        server_protocol_error( "get_apc_request: bad type %d\n", call->type );
        break;
    }
}


/***********************************************************************
 *              server_select
 */
unsigned int server_select( const union select_op *select_op, data_size_t size, UINT flags,
                            timeout_t abs_timeout, struct context_data *context, struct user_apc *user_apc )
{
#ifdef WINE_IOS
    { extern void ios_tls38_poll( const char * ); ios_tls38_poll( "wait" ); }
#endif
    unsigned int ret;
    int cookie;
    obj_handle_t apc_handle = 0;
    BOOL suspend_context = !!context;
    union apc_result result;
    sigset_t old_set;
    int signaled;
    data_size_t reply_size;
    struct
    {
        union apc_call call;
        struct context_data context[2];
    } reply_data;

    memset( &result, 0, sizeof(result) );

    do
    {
        pthread_sigmask( SIG_BLOCK, &server_block_set, &old_set );
        for (;;)
        {
            SERVER_START_REQ( select )
            {
                req->flags    = flags;
                req->cookie   = wine_server_client_ptr( &cookie );
                req->prev_apc = apc_handle;
                req->timeout  = abs_timeout;
                req->size     = size;
                wine_server_add_data( req, &result, sizeof(result) );
                wine_server_add_data( req, select_op, size );
                if (suspend_context)
                {
                    data_size_t ctx_size = (context[1].machine ? 2 : 1) * sizeof(*context);
                    wine_server_add_data( req, context, ctx_size );
                    suspend_context = FALSE; /* server owns the context now */
                }
                wine_server_set_reply( req, &reply_data,
                                       context ? sizeof(reply_data) : sizeof(reply_data.call) );
                ret = server_call_unlocked( req );
                signaled    = reply->signaled;
                apc_handle  = reply->apc_handle;
                reply_size  = wine_server_reply_size( reply );
            }
            SERVER_END_REQ;

            if (ret != STATUS_KERNEL_APC) break;
            invoke_system_apc( &reply_data.call, &result, FALSE );

            /* don't signal multiple times */
            if (size >= sizeof(select_op->signal_and_wait) && select_op->op == SELECT_SIGNAL_AND_WAIT)
                size = offsetof( union select_op, signal_and_wait.signal );
        }
        pthread_sigmask( SIG_SETMASK, &old_set, NULL );
        if (signaled) break;

        ret = wait_select_reply( &cookie );
    }
    while (ret == STATUS_USER_APC || ret == STATUS_KERNEL_APC);

    if (ret == STATUS_USER_APC) *user_apc = reply_data.call.user;
    if (reply_size > sizeof(reply_data.call))
    {
        memcpy( context, reply_data.context, reply_size - sizeof(reply_data.call) );
        context[0].flags &= ~SERVER_CTX_EXEC_SPACE;
        context[1].flags &= ~SERVER_CTX_EXEC_SPACE;
    }
    return ret;
}


/***********************************************************************
 *              server_wait
 */
/***********************************************************************
 *              ml585: IN-FLIGHT WAIT REGISTRY
 *
 * ml584 caught explorer's shell thread (Wine tid 0024 = Mach port 0xe903)
 * blocked in NtWaitForSingleObject under rpcrt4 -> combase, cpu=0, at an
 * IDENTICAL sp across two samples 20s apart, while its message queue piled
 * up post=56 with QS_PAINT set. That is why the Start button never repaints
 * AND why clicking it does nothing: one wedged thread, both symptoms.
 *
 * A sampler that logs on wait EXIT can never see this — the wait does not
 * end. So publish the wait BEFORE entering it and clear it after. wineserver
 * is a thread in this same Mach task, so it can walk this table directly and
 * resolve the handles against the owning process's handle table (see
 * ios_dump_stuck_waits in queue_ios.c) — no IPC, no extra syscalls.
 *
 * Cost on the healthy path: two stores and a clock read per wait. Bounded
 * table, fixed slots, no allocation, no locks. A slot is only ever written
 * by its owning thread; the reader tolerates torn reads by re-checking seq.
 */
#define IOS_WAITREG_SLOTS 512
struct ios_wait_entry
{
    volatile unsigned int  seq;        /* even = idle, odd = in a wait  */
    void                  *teb;
    unsigned int           wine_tid;
    unsigned long long     t0_ns;      /* CLOCK_MONOTONIC at wait entry */
    unsigned int           flags;      /* SELECT_* (alertable etc.)     */
    long long              timeout;    /* abs_timeout as passed down    */
    int                    op;
    int                    count;
    unsigned int           handles[8];
    void                  *ret_pc;     /* caller of server_wait         */
};
struct ios_wait_entry ios_wait_reg[IOS_WAITREG_SLOTS];

static struct ios_wait_entry *ios_wait_slot(void)
{
    /* Stable per-thread slot: TEB pointer hashed. Collisions only cost
     * fidelity of the report, never correctness — a colliding thread
     * overwrites the entry and the stuck one is simply not reported. */
    uintptr_t t = (uintptr_t)NtCurrentTeb();
    return &ios_wait_reg[(t >> 16) % IOS_WAITREG_SLOTS];
}

static void ios_wait_enter( const union select_op *op, data_size_t size,
                            UINT flags, timeout_t abs_timeout, void *ret_pc )
{
    struct ios_wait_entry *e = ios_wait_slot();
    struct timespec ts;
    int i, n = 0;

    e->seq++;                       /* -> odd: entry is being written  */
    __sync_synchronize();
    e->teb      = NtCurrentTeb();
    e->wine_tid = (unsigned int)(uintptr_t)NtCurrentTeb()->ClientId.UniqueThread;
    e->flags    = flags;
    e->timeout  = abs_timeout;
    e->ret_pc   = ret_pc;
    e->op       = op ? (int)op->op : -1;
    if (op && size >= sizeof(op->wait) - sizeof(op->wait.handles))
    {
        n = (int)((size - offsetof(union select_op, wait.handles)) / sizeof(obj_handle_t));
        if (n > 8) n = 8;
        if (n < 0) n = 0;
        for (i = 0; i < n; i++) e->handles[i] = op->wait.handles[i];
    }
    e->count = n;
    clock_gettime( CLOCK_MONOTONIC, &ts );
    e->t0_ns = (unsigned long long)ts.tv_sec * 1000000000ull + ts.tv_nsec;
    __sync_synchronize();
}

static void ios_wait_leave(void)
{
    struct ios_wait_entry *e = ios_wait_slot();
    __sync_synchronize();
    e->seq++;                       /* -> even: no longer waiting */
}

unsigned int server_wait( const union select_op *select_op, data_size_t size, UINT flags,
                          const LARGE_INTEGER *timeout )
{
    timeout_t abs_timeout = timeout ? timeout->QuadPart : TIMEOUT_INFINITE;
    unsigned int ret;
    struct user_apc apc;

    if (abs_timeout < 0)
    {
        LARGE_INTEGER now;

        NtQueryPerformanceCounter( &now, NULL );
        abs_timeout -= now.QuadPart;
    }

    {
        int is_game = ios_srv_game_teb &&
                      (uintptr_t)NtCurrentTeb() == ios_srv_game_teb;
        struct timespec t0, t1;
        if (is_game) clock_gettime( CLOCK_MONOTONIC, &t0 );
        ios_wait_enter( select_op, size, flags, abs_timeout,
                        __builtin_return_address(0) );
        ret = server_select( select_op, size, flags, abs_timeout, NULL, &apc );
        ios_wait_leave();
        if (is_game)
        {
            clock_gettime( CLOCK_MONOTONIC, &t1 );
            ios_srv_wait_us += (t1.tv_sec - t0.tv_sec) * 1000000LL
                             + (t1.tv_nsec - t0.tv_nsec) / 1000;
            ios_srv_wait_count++;
            if (ret == STATUS_TIMEOUT) ios_srv_wait_timeouts++;
            /* Requested duration: only for RELATIVE timeouts (negative
             * input) — those were converted to QPC-epoch absolutes above,
             * so abs_timeout and QPC share an epoch. Positive inputs are
             * NT-1601-epoch absolutes and would poison the math.
             * overshoot/wait = (w_ms - wreq_ms)/waits per window. */
            if (timeout && timeout->QuadPart < 0)
            {
                LARGE_INTEGER entry_now;
                long long req_us;
                NtQueryPerformanceCounter( &entry_now, NULL );
                /* entry_now is post-wait; reconstruct from measured wall */
                req_us = (abs_timeout - entry_now.QuadPart) / 10
                       + (t1.tv_sec - t0.tv_sec) * 1000000LL
                       + (t1.tv_nsec - t0.tv_nsec) / 1000;
                if (req_us > 0) ios_srv_wait_req_us += req_us;
            }
        }
    }
    if (ret == STATUS_USER_APC) return invoke_user_apc( NULL, &apc, ret );

    /* A test on Windows 2000 shows that Windows always yields during
       a wait, but a wait that is hit by an event gets a priority
       boost as well.  This seems to model that behavior the closest.  */
    if (ret == STATUS_TIMEOUT) NtYieldExecution();
    return ret;
}


/* helper function to perform a server-side wait on an internal handle without
 * using the fast synchronization path */
unsigned int server_wait_for_object( HANDLE handle, BOOL alertable, const LARGE_INTEGER *timeout )
{
    union select_op select_op;
    UINT flags = SELECT_INTERRUPTIBLE;

    if (alertable) flags |= SELECT_ALERTABLE;

    select_op.wait.op = SELECT_WAIT;
    select_op.wait.handles[0] = wine_server_obj_handle( handle );
    return server_wait( &select_op, offsetof( union select_op, wait.handles[1] ), flags, timeout );
}


/***********************************************************************
 *              NtContinue  (NTDLL.@)
 */
NTSTATUS WINAPI NtContinue( CONTEXT *context, BOOLEAN alertable )
{
    return NtContinueEx( context, ULongToPtr(alertable) );
}


/***********************************************************************
 *              NtContinueEx  (NTDLL.@)
 */
NTSTATUS WINAPI NtContinueEx( CONTEXT *context, KCONTINUE_ARGUMENT *args )
{
    struct user_apc apc;
    NTSTATUS status;
    BOOL alertable;
#ifdef WINE_IOS
    { extern void ios_tlswatch_rearm( const char * ); ios_tlswatch_rearm( "NtContinue" ); }
#endif

    if ((UINT_PTR)args > 0xff)
        alertable = args->ContinueFlags & KCONTINUE_FLAG_TEST_ALERT;
    else
        alertable = !!args;

    if (alertable)
    {
        status = server_select( NULL, 0, SELECT_INTERRUPTIBLE | SELECT_ALERTABLE, 0, NULL, &apc );
        if (status == STATUS_USER_APC) return invoke_user_apc( context, &apc, status );
    }
    return signal_set_full_context( context );
}


/***********************************************************************
 *              NtTestAlert  (NTDLL.@)
 */
NTSTATUS WINAPI NtTestAlert(void)
{
    struct user_apc apc;
    NTSTATUS status;

    status = server_select( NULL, 0, SELECT_INTERRUPTIBLE | SELECT_ALERTABLE, 0, NULL, &apc );
    if (status == STATUS_USER_APC) invoke_user_apc( NULL, &apc, STATUS_SUCCESS );
    return STATUS_SUCCESS;
}


/***********************************************************************
 *           server_queue_process_apc
 */
unsigned int server_queue_process_apc( HANDLE process, const union apc_call *call, union apc_result *result )
{
    for (;;)
    {
        unsigned int ret;
        HANDLE handle = 0;
        BOOL self = FALSE;

        SERVER_START_REQ( queue_apc )
        {
            req->handle = wine_server_obj_handle( process );
            wine_server_add_data( req, call, sizeof(*call) );
            if (!(ret = wine_server_call( req )))
            {
                handle = wine_server_ptr_handle( reply->handle );
                self = reply->self;
            }
        }
        SERVER_END_REQ;
        if (ret != STATUS_SUCCESS) return ret;

        if (self)
        {
            invoke_system_apc( call, result, TRUE );
        }
        else
        {
            sigset_t sigset;

            NtWaitForSingleObject( handle, FALSE, NULL );

            server_enter_uninterrupted_section( &fd_cache_mutex, &sigset );

            /* remove the handle from the cache, get_apc_result will close it for us */
            close_inproc_sync( handle );

            SERVER_START_REQ( get_apc_result )
            {
                req->handle = wine_server_obj_handle( handle );
                if (!(ret = server_call_unlocked( req ))) *result = reply->result;
            }
            SERVER_END_REQ;

            server_leave_uninterrupted_section( &fd_cache_mutex, &sigset );

            if (!ret && result->type == APC_NONE) continue;  /* APC didn't run, try again */
        }
        return ret;
    }
}


/***********************************************************************
 *           wine_server_send_fd
 *
 * Send a file descriptor to the server.
 */
void CDECL wine_server_send_fd( int fd )
{
    struct send_fd data;
    struct msghdr msghdr;
    struct iovec vec;
    char cmsg_buffer[256];
    struct cmsghdr *cmsg;
    int ret;

    msghdr.msg_name    = NULL;
    msghdr.msg_namelen = 0;
    msghdr.msg_iov     = &vec;
    msghdr.msg_iovlen  = 1;
    msghdr.msg_control = cmsg_buffer;
    msghdr.msg_controllen = sizeof(cmsg_buffer);
    msghdr.msg_flags   = 0;

    vec.iov_base = (void *)&data;
    vec.iov_len  = sizeof(data);

    data.tid = GetCurrentThreadId();
    data.fd  = fd;

    cmsg = CMSG_FIRSTHDR( &msghdr );
    cmsg->cmsg_len   = CMSG_LEN( sizeof(fd) );
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type  = SCM_RIGHTS;
    *(int *)CMSG_DATA(cmsg) = fd;
    msghdr.msg_controllen = cmsg->cmsg_len;

    for (;;)
    {
#ifdef WINE_IOS
        if ((ret = sendmsg( ios_current_fd_socket(), &msghdr, 0 )) == sizeof(data)) return;
#else
        if ((ret = sendmsg( fd_socket, &msghdr, 0 )) == sizeof(data)) return;
#endif
        if (ret >= 0) server_protocol_error( "partial write %d\n", ret );
        if (errno == EINTR) continue;
        if (errno == EPIPE)
        {
#ifdef WINE_IOS
            /* ml586: silent-death path — master socket dead under us */
            ios_fdt_autopsy( "send_fd-epipe", ios_current_fd_socket(), ret, EPIPE );
#endif
            abort_thread(0);
        }
        server_protocol_perror( "sendmsg" );
    }
}


/***********************************************************************
 *           receive_fd
 *
 * Receive a file descriptor passed from the server.
 */
int wine_server_receive_fd( obj_handle_t *handle )
{
    struct iovec vec;
    struct msghdr msghdr;
    char cmsg_buffer[256];
    int ret, fd = -1;

    msghdr.msg_name    = NULL;
    msghdr.msg_namelen = 0;
    msghdr.msg_iov     = &vec;
    msghdr.msg_iovlen  = 1;
    msghdr.msg_control = cmsg_buffer;
    msghdr.msg_controllen = sizeof(cmsg_buffer);
    msghdr.msg_flags   = 0;

    vec.iov_base = (void *)handle;
    vec.iov_len  = sizeof(*handle);

    for (;;)
    {
#ifdef WINE_IOS
        int recv_sock = ios_current_fd_socket();
        if ((ret = recvmsg( recv_sock, &msghdr, MSG_CMSG_CLOEXEC )) > 0)
#else
        if ((ret = recvmsg( fd_socket, &msghdr, MSG_CMSG_CLOEXEC )) > 0)
#endif
        {
            struct cmsghdr *cmsg;
            for (cmsg = CMSG_FIRSTHDR( &msghdr ); cmsg; cmsg = CMSG_NXTHDR( &msghdr, cmsg ))
            {
                if (cmsg->cmsg_level != SOL_SOCKET) continue;
                if (cmsg->cmsg_type == SCM_RIGHTS) fd = *(int *)CMSG_DATA(cmsg);
#ifdef SCM_CREDENTIALS
                else if (cmsg->cmsg_type == SCM_CREDENTIALS)
                {
                    struct ucred *ucred = (struct ucred *)CMSG_DATA(cmsg);
                    server_pid = ucred->pid;
                }
#endif
            }
#ifdef WINE_IOS
            /* task #24 wedge probe: a client retry-looped get_handle_fd while
             * the server sendmsg'd successfully every time — the fd right is
             * getting lost between the two ends. Log the receive when the fd
             * is missing (MSG_CTRUNC = kernel stripped the right, e.g. fd
             * table exhaustion) and the first few successes for baseline. */
            {
                static volatile int fd_recv_logged = 0;
                int fdl = fd_recv_logged;
                if (fd == -1 || fdl < 8 || (msghdr.msg_flags & MSG_CTRUNC))
                {
                    if (fdl < 40)
                    {
                        __sync_add_and_fetch(&fd_recv_logged, 1);
                        dprintf(2, "[fd-recv] sock=%d peb=%p ret=%d fd=%d handle=%x msg_flags=%x%s\n",
                                recv_sock, ios_jit_current_peb(), ret, fd, *handle,
                                msghdr.msg_flags,
                                (msghdr.msg_flags & MSG_CTRUNC) ? "  <-- CTRUNC: fd right stripped" :
                                (fd == -1) ? "  <-- NO FD in message" : "");
                    }
                }
            }
#endif
            if (fd != -1) fcntl( fd, F_SETFD, FD_CLOEXEC ); /* in case MSG_CMSG_CLOEXEC is not supported */
            return fd;
        }
        if (!ret) break;
        if (errno == EINTR) continue;
        if (errno == EPIPE) break;
#ifdef WINE_IOS
        dprintf(2, "[fd-recv] recvmsg FAILED sock=%d peb=%p ret=%d errno=%d\n",
                recv_sock, ios_jit_current_peb(), ret, errno);
#endif
        server_protocol_perror("recvmsg");
    }
    /* the server closed the connection; time to die... */
#ifdef WINE_IOS
    /* iOS-Madeira ml1183: a killed thread whose fd socket died between get_handle_fd's
     * reply and this read is inside server_get_unix_fd's fd_cache_mutex section: exiting
     * here leaves that mutex, shared by every process of the task, locked (the hang
     * ios_defer_section_abort fixes for the request pipes). Fail the read instead; the
     * caller maps -1 to an error and the thread exits when it leaves the section.
     * Outside a section (process init): unchanged. */
    if (ios_defer_section_abort()) return -1;
#endif
    abort_thread(0);
}


/***********************************************************************/
/* fd cache support */

union fd_cache_entry
{
    LONG64 data;
    struct
    {
        int fd;
        enum server_fd_type type : 5;
        unsigned int        access : 3;
        unsigned int        options : 24;
    } s;
};

C_ASSERT( sizeof(union fd_cache_entry) == sizeof(LONG64) );

#define FD_CACHE_BLOCK_SIZE  (65536 / sizeof(union fd_cache_entry))
#define FD_CACHE_ENTRIES     128

#ifdef WINE_IOS
/* On iOS, Wine "processes" are threads sharing one address space, so handle
 * values from different Wine processes can collide in one cache — the cache
 * must therefore be PER PSEUDO-PROCESS.
 *
 * ml571: it used to be `_Thread_local`, on the reasoning that thread-local IS
 * per-process. It is not. A pseudo-process is MANY threads sharing one PEB, so
 * a thread-local cache is per-THREAD, and Windows handles belong to a process:
 *
 *   thread A maps section H     -> A caches H's unix fd
 *   thread B closes H           -> NtClose clears only B's cache
 *   wineserver recycles H       -> new section, correct size from the server
 *   thread A maps H again       -> A's STALE fd -> maps the OLD inode
 *
 * That produced both of the walls we spent days on. Short backing (a constant
 * 0x10000 behind 4MB and 256KB views) with grow/shrink/truncate probes ALL
 * silent: the file was never short, we were fstat'ing a different file — and
 * past its end lies SIGBUS, reported as KERN_MEMORY_ERROR. And when the stale
 * fd happened to be big enough, no fault at all: two views of one section
 * simply referenced different inodes, so tiles rendered another tile's pixels
 * or zeroes. Disabling caching for anonymous sections (ml570) took [map-eof]
 * from 2-every-run to 0 and the login page rendered correctly for the first
 * time. Diagnosis by Sol.
 *
 * Keying by PEB is the same ownership model `ios_proc_sockets` above already
 * uses, and for the same reason — `fd_socket` had this exact bug and was fixed
 * in 5852209. Do NOT "simplify" this back to one global cache: handles from
 * different pseudo-processes collide, which is what the thread-local was
 * (wrongly) reaching for. */
struct ios_fd_cache {
    union fd_cache_entry *blocks[FD_CACHE_ENTRIES];
    union fd_cache_entry initial_block[FD_CACHE_BLOCK_SIZE];
};

#define IOS_MAX_FD_CACHES 64
static struct ios_fd_cache_slot
{
    void *peb;                    /* pseudo-process identity */
    struct ios_fd_cache *cache;
    int in_use;                   /* separate flag: peb==NULL is a VALID key
                                   * (the initial process), so NULL cannot
                                   * double as "free slot" the way it does in
                                   * ios_proc_sockets. */
} ios_fd_caches[IOS_MAX_FD_CACHES];
static volatile int ios_fd_cache_count = 0;
static pthread_mutex_t ios_fd_cache_alloc_lock = PTHREAD_MUTEX_INITIALIZER;
static struct ios_fd_cache ios_fd_cache_fallback;   /* last resort, see below */

static struct ios_fd_cache *ios_get_fd_cache(void)
{
    void *cur = ios_jit_current_peb();
    int i, n = __sync_fetch_and_add( &ios_fd_cache_count, 0 );

    /* Fast path: lock-free scan. Safe because a slot is only ever published
     * by bumping the count LAST, after peb+cache are visible. */
    for (i = 0; i < n && i < IOS_MAX_FD_CACHES; i++)
        if (ios_fd_caches[i].in_use && ios_fd_caches[i].peb == cur)
            return ios_fd_caches[i].cache;

    pthread_mutex_lock( &ios_fd_cache_alloc_lock );
    n = ios_fd_cache_count;                       /* re-check under the lock */
    for (i = 0; i < n && i < IOS_MAX_FD_CACHES; i++)
        if (ios_fd_caches[i].in_use && ios_fd_caches[i].peb == cur)
        {
            pthread_mutex_unlock( &ios_fd_cache_alloc_lock );
            return ios_fd_caches[i].cache;
        }
    if (n < IOS_MAX_FD_CACHES)
    {
        struct ios_fd_cache *c = calloc( 1, sizeof(*c) );
        if (c)
        {
            ios_fd_caches[n].cache = c;
            ios_fd_caches[n].peb   = cur;
            ios_fd_caches[n].in_use = 1;
            __sync_synchronize();                 /* publish before the count */
            __sync_fetch_and_add( &ios_fd_cache_count, 1 );
            dprintf( 2, "[fd-cache] rev=ml571 new PEB-keyed cache slot=%d peb=%p\n", n, cur );
            pthread_mutex_unlock( &ios_fd_cache_alloc_lock );
            return c;
        }
    }
    else
    {
        static int warned;
        if (!warned++)
            dprintf( 2, "[fd-cache] rev=ml571 SLOTS FULL (%d) — peb=%p falls back to "
                        "UNCACHED fds (correct, just slower)\n", IOS_MAX_FD_CACHES, cur );
    }
    pthread_mutex_unlock( &ios_fd_cache_alloc_lock );
    /* Never return NULL: the fd_cache/fd_cache_initial_block macros dereference
     * this directly, so NULL would be an immediate crash. Falling back to one
     * shared cache reintroduces cross-process handle collisions — the very bug
     * this keying exists to prevent — so it is loudly logged above and only
     * reachable after 64 live pseudo-processes or a calloc failure. A shared
     * cache is wrong; a NULL deref is fatal. */
    return &ios_fd_cache_fallback;
}

/* ml571: drop a dead pseudo-process's cache and close every fd still in it.
 * The thread-local caches had no destructor at all, so each dead thread leaked
 * its cached fds and pinned the unlinked inodes behind them. */
void ios_fd_cache_release( void *peb )
{
    { extern void ios_inproc_cache_release( void *peb ); ios_inproc_cache_release( peb ); }   /* ml1058 */
    int i, j, n, closed = 0;
    struct ios_fd_cache *c = NULL;

    pthread_mutex_lock( &ios_fd_cache_alloc_lock );
    n = ios_fd_cache_count;
    for (i = 0; i < n && i < IOS_MAX_FD_CACHES; i++)
        if (ios_fd_caches[i].in_use && ios_fd_caches[i].peb == peb)
        {
            c = ios_fd_caches[i].cache;
            ios_fd_caches[i].in_use = 0;
            ios_fd_caches[i].cache = NULL;
            break;
        }
    pthread_mutex_unlock( &ios_fd_cache_alloc_lock );
    if (!c) return;

    for (i = 0; i < FD_CACHE_ENTRIES; i++)
    {
        union fd_cache_entry *block = c->blocks[i];
        if (!block) continue;
        for (j = 0; j < FD_CACHE_BLOCK_SIZE; j++)
        {
            /* ml961: `s.fd` holds fd+1, not fd. add_fd_to_cache stores it that
             * way so 0 can mean "unset" ("store fd+1 so that 0 can be used as
             * the unset value"), and both readers decode it: get_cached_fd does
             * `*fd = cache.s.fd - 1` and remove_fd_from_cache does
             * `fd = cache.s.fd - 1`. This loop was the only place that passed
             * the stored word straight to close(), so it closed the descriptor
             * AFTER the one this pseudo-process owned -- leaking the real one
             * and closing an unrelated live fd.
             *
             * Measured in rdr25, three consecutive lines:
             *   CROSS! close fd=30 why=fd-cache-release kind=request_wr
             *          owner_peb=0x6fdff0000 closer_tid=007c dead_peb=0x48ff84000
             *   read_request EOF tid=0024 pid=0020 request_unixfd=27 -> kill_thread
             *   kill_thread tid=0024 pid=0020 violent=0
             * The exiting launcher closed another pseudo-process's request-pipe
             * write end, and wineserver killed that thread on the EOF. The
             * other entries show the same shift (221/225/229 closed for real
             * fds 220/224/228).
             *
             * Decode ONCE and use the same value for the ownership log and the
             * close, so the two can never disagree. Descriptor 0 is a valid
             * descriptor (stored as 1), so the populated test is on the stored
             * word being non-zero, not on the decoded fd being positive.
             *
             * FD_TYPE_INVALID entries do not hold a descriptor at all -- they
             * cache an NTSTATUS ("if fd type is invalid, fd stores an error
             * value"), so closing them closes an arbitrary number. Skip them. */
            int stored = block[j].s.fd;
            int real_fd;

            if (!stored) continue;                              /* unset entry      */
            if (block[j].s.type == FD_TYPE_INVALID) continue;   /* cached NTSTATUS  */
            real_fd = stored - 1;
            ios_fdt_note_close( real_fd, "fd-cache-release", peb );
            close( real_fd );
            closed++;
        }
        /* ml961: secondary blocks come from anon_mmap_alloc (mmap), so they must
         * be released with munmap at the same size -- free() on an mmap'd
         * pointer is undefined and corrupts the malloc heap. Only the enclosing
         * cache object below belongs to free(); initial_block is an inline
         * array inside *c and is released with it. */
        if (block != c->initial_block)
            munmap( block, FD_CACHE_BLOCK_SIZE * sizeof(union fd_cache_entry) );
    }
    free( c );
    dprintf( 2, "[fd-cache] rev=ml961 released peb=%p, closed %d cached fd(s) (decoded fd+1; "
             "skipped FD_TYPE_INVALID; munmap for secondary blocks)\n", peb, closed );
}

#define fd_cache           (ios_get_fd_cache()->blocks)
#define fd_cache_initial_block (ios_get_fd_cache()->initial_block)
#else
static union fd_cache_entry *fd_cache[FD_CACHE_ENTRIES];
static union fd_cache_entry fd_cache_initial_block[FD_CACHE_BLOCK_SIZE];
#endif

static inline unsigned int handle_to_index( HANDLE handle, unsigned int *entry )
{
    unsigned int idx = (wine_server_obj_handle(handle) >> 2) - 1;
    *entry = idx / FD_CACHE_BLOCK_SIZE;
    return idx % FD_CACHE_BLOCK_SIZE;
}


/***********************************************************************
 *           add_fd_to_cache
 *
 * Caller must hold fd_cache_mutex.
 */
static BOOL add_fd_to_cache( HANDLE handle, int fd, enum server_fd_type type,
                            unsigned int access, unsigned int options )
{
    unsigned int entry, idx = handle_to_index( handle, &entry );
    union fd_cache_entry cache;

    if (entry >= FD_CACHE_ENTRIES)
    {
        FIXME( "too many allocated handles, not caching %p\n", handle );
        return FALSE;
    }

    if (!fd_cache[entry])  /* do we need to allocate a new block of entries? */
    {
        if (!entry) fd_cache[0] = fd_cache_initial_block;
        else
        {
            void *ptr = anon_mmap_alloc( FD_CACHE_BLOCK_SIZE * sizeof(union fd_cache_entry),
                                         PROT_READ | PROT_WRITE );
            if (ptr == MAP_FAILED) return FALSE;
            fd_cache[entry] = ptr;
        }
    }

    /* store fd+1 so that 0 can be used as the unset value */
    cache.s.fd = fd + 1;
    cache.s.type = type;
    cache.s.access = access;
    cache.s.options = options;
    cache.data = interlocked_xchg64( &fd_cache[entry][idx].data, cache.data );
    assert( !cache.s.fd );
    return TRUE;
}


/***********************************************************************
 *           get_cached_fd
 */
static inline NTSTATUS get_cached_fd( HANDLE handle, int *fd, enum server_fd_type *type,
                                      unsigned int *access, unsigned int *options )
{
    unsigned int entry, idx = handle_to_index( handle, &entry );
    union fd_cache_entry cache;

    if (entry >= FD_CACHE_ENTRIES || !fd_cache[entry]) return STATUS_INVALID_HANDLE;

    cache.data = InterlockedCompareExchange64( &fd_cache[entry][idx].data, 0, 0 );
    if (!cache.data) return STATUS_INVALID_HANDLE;

    /* if fd type is invalid, fd stores an error value */
    if (cache.s.type == FD_TYPE_INVALID) return cache.s.fd - 1;

    *fd = cache.s.fd - 1;
    if (type) *type = cache.s.type;
    if (access) *access = cache.s.access;
    if (options) *options = cache.s.options;
    return STATUS_SUCCESS;
}


/***********************************************************************
 *           remove_fd_from_cache
 */
static int remove_fd_from_cache( HANDLE handle )
{
    unsigned int entry, idx = handle_to_index( handle, &entry );
    int fd = -1;

    if (entry < FD_CACHE_ENTRIES && fd_cache[entry])
    {
        union fd_cache_entry cache;
        cache.data = interlocked_xchg64( &fd_cache[entry][idx].data, 0 );
        if (cache.s.type != FD_TYPE_INVALID) fd = cache.s.fd - 1;
    }

    return fd;
}


#ifdef WINE_IOS
/* madeira-bcd: get_handle_fd hands the descriptor over in its reply (build/wineserver/
 * fd_ios.c). The server is a thread of this process and shares its descriptor table, so
 * the copy it makes with F_DUPFD_CLOEXEC is what SCM_RIGHTS through the process socket
 * delivered (a new descriptor for the same open file, close-on-exec), without the server's
 * sendmsg and its two log lines and this side's recvmsg and fcntl; it also cannot pick up
 * another thread's descriptor from the shared socket. -1 means the descriptor table is
 * full, reported as before. env.MADEIRA_SRV_FD_SOCKET = 1 (read once) uses the socket. */
static int ios_fd_in_reply(void)
{
    static int on = -1;
    if (on < 0)
    {
        const char *e = getenv( "MADEIRA_SRV_FD_SOCKET" );
        on = !(e && e[0] == '1');
    }
    return on;
}
#endif

/***********************************************************************
 *           server_get_unix_fd
 *
 * The returned unix_fd should be closed iff needs_close is non-zero.
 */
int server_get_unix_fd( HANDLE handle, unsigned int wanted_access, int *unix_fd,
                        int *needs_close, enum server_fd_type *type, unsigned int *options )
{
    sigset_t sigset;
    obj_handle_t fd_handle;
    int ret, fd = -1;
    unsigned int access = 0;

    *unix_fd = -1;
    *needs_close = 0;
    wanted_access &= FILE_READ_DATA | FILE_WRITE_DATA | FILE_APPEND_DATA;

    ret = get_cached_fd( handle, &fd, type, &access, options );
    if (ret != STATUS_INVALID_HANDLE) goto done;

    server_enter_uninterrupted_section( &fd_cache_mutex, &sigset );
    ret = get_cached_fd( handle, &fd, type, &access, options );
    if (ret == STATUS_INVALID_HANDLE)
    {
#ifdef WINE_IOS
        int in_reply = ios_fd_in_reply(), reply_fd = -1;
#endif
        SERVER_START_REQ( get_handle_fd )
        {
            req->handle = wine_server_obj_handle( handle );
#ifdef WINE_IOS
            if (in_reply) wine_server_set_reply( req, &reply_fd, sizeof(reply_fd) );
#endif
            if (!(ret = wine_server_call( req )))
            {
                if (type) *type = reply->type;
                if (options) *options = reply->options;
                access = reply->access;
#ifdef WINE_IOS
                if (in_reply)   /* the descriptor came in the reply (fd_ios.c get_handle_fd) */
                {
                    fd = wine_server_reply_size( reply ) == sizeof(reply_fd) ? reply_fd : -1;
                    fd_handle = wine_server_obj_handle( handle );
                }
                else
#endif
                fd = wine_server_receive_fd( &fd_handle );
                if (fd != -1)
                {
                    /* task #24: the settings-freeze loop showed a handle
                     * whose fd never reaches the requester. If the received
                     * handle doesn't match the requested one, we'd silently
                     * mis-cache (assert is compiled out) — log it. */
                    if (wine_server_ptr_handle(fd_handle) != handle)
                        dprintf(2, "[fd-recv] HANDLE MISMATCH: asked %p got %p (fd=%d peb=%p)\n",
                                handle, wine_server_ptr_handle(fd_handle), fd,
                                ios_jit_current_peb());
                    assert( wine_server_ptr_handle(fd_handle) == handle );
                    *needs_close = (!reply->cacheable ||
                                    !add_fd_to_cache( handle, fd, reply->type,
                                                      reply->access, reply->options ));
                }
                else
                {
                    static volatile int nofd_logged = 0;
                    if (nofd_logged < 20)
                    {
                        __sync_add_and_fetch(&nofd_logged, 1);
                        dprintf(2, "[fd-recv] get_unix_fd: NO FD for handle %p (peb=%p) -> TOO_MANY_OPENED_FILES\n",
                                handle, ios_jit_current_peb());
                    }
                    ret = STATUS_TOO_MANY_OPENED_FILES;
                }
            }
            else if (reply->cacheable)
            {
                add_fd_to_cache( handle, ret, FD_TYPE_INVALID, 0, 0 );
            }
        }
        SERVER_END_REQ;
    }
    server_leave_uninterrupted_section( &fd_cache_mutex, &sigset );

done:
    if (!ret && ((access & wanted_access) != wanted_access))
    {
        ret = STATUS_ACCESS_DENIED;
        if (*needs_close) close( fd );
    }
    if (!ret) *unix_fd = fd;
    return ret;
}


/***********************************************************************
 *           wine_server_fd_to_handle
 */
NTSTATUS CDECL wine_server_fd_to_handle( int fd, unsigned int access, unsigned int attributes, HANDLE *handle )
{
    unsigned int ret;

    *handle = 0;
    wine_server_send_fd( fd );

    SERVER_START_REQ( alloc_file_handle )
    {
        req->access     = access;
        req->attributes = attributes;
        req->fd         = fd;
        if (!(ret = wine_server_call( req ))) *handle = wine_server_ptr_handle( reply->handle );
    }
    SERVER_END_REQ;
    return ret;
}


/***********************************************************************
 *           unixcall_wine_server_fd_to_handle
 */
NTSTATUS unixcall_wine_server_fd_to_handle( void *args )
{
    struct wine_server_fd_to_handle_params *params = args;

    return wine_server_fd_to_handle( params->fd, params->access, params->attributes, params->handle );
}


/***********************************************************************
 *           wine_server_handle_to_fd
 *
 * Retrieve the file descriptor corresponding to a file handle.
 */
NTSTATUS CDECL wine_server_handle_to_fd( HANDLE handle, unsigned int access, int *unix_fd,
                                         unsigned int *options )
{
    int needs_close;
    NTSTATUS ret = server_get_unix_fd( handle, access, unix_fd, &needs_close, NULL, options );

    if (!ret && !needs_close)
    {
        if ((*unix_fd = dup(*unix_fd)) == -1) ret = STATUS_TOO_MANY_OPENED_FILES;
    }
    return ret;
}


/***********************************************************************
 *           unixcall_wine_server_handle_to_fd
 */
NTSTATUS unixcall_wine_server_handle_to_fd( void *args )
{
    struct wine_server_handle_to_fd_params *params = args;

    return wine_server_handle_to_fd( params->handle, params->access, params->unix_fd, params->options );
}


/***********************************************************************
 *           server_pipe
 *
 * Create a pipe for communicating with the server.
 */
int server_pipe( int fd[2] )
{
    int ret;
#ifdef HAVE_PIPE2
    static BOOL have_pipe2 = TRUE;

    if (have_pipe2)
    {
        if (!(ret = pipe2( fd, O_CLOEXEC ))) return ret;
        if (errno == ENOSYS || errno == EINVAL) have_pipe2 = FALSE;  /* don't try again */
    }
#endif
    if (!(ret = pipe( fd )))
    {
        fcntl( fd[0], F_SETFD, FD_CLOEXEC );
        fcntl( fd[1], F_SETFD, FD_CLOEXEC );
    }
    return ret;
}


/***********************************************************************
 *           init_server_dir
 */
static const char *init_server_dir( dev_t dev, ino_t ino )
{
    char *dir = NULL;

#if defined(__ANDROID__) || defined(WINE_IOS)  /* no /tmp on Android/iOS */
    asprintf( &dir, "%s/.wineserver/server-%llx-%llx", config_dir, (unsigned long long)dev, (unsigned long long)ino );
#else
    asprintf( &dir, "/tmp/.wine-%u/server-%llx-%llx", getuid(), (unsigned long long)dev, (unsigned long long)ino );
#endif
    return dir;
}


/***********************************************************************
 *           setup_config_dir
 *
 * Setup the wine configuration dir.
 */
static int setup_config_dir(void)
{
    char *p;
    struct stat st;
    int fd_cwd = open( ".", O_RDONLY );

    if (chdir( config_dir ) == -1)
    {
        if (errno != ENOENT) fatal_perror( "cannot use directory %s", config_dir );
        if ((p = strrchr( config_dir, '/' )) && p != config_dir)
        {
            while (p > config_dir + 1 && p[-1] == '/') p--;
            *p = 0;
            if (!stat( config_dir, &st ) && st.st_uid != getuid())
                fatal_error( "'%s' is not owned by you, refusing to create a configuration directory there\n",
                             config_dir );
            *p = '/';
        }
        mkdir( config_dir, 0777 );
        if (chdir( config_dir ) == -1) fatal_perror( "chdir to %s", config_dir );
        MESSAGE( "wine: created the configuration directory '%s'\n", config_dir );
    }

    if (stat( ".", &st ) == -1) fatal_perror( "stat %s", config_dir );
    if (st.st_uid != getuid()) fatal_error( "'%s' is not owned by you\n", config_dir );

    server_dir = init_server_dir( st.st_dev, st.st_ino );

    if (!mkdir( "dosdevices", 0777 ))
    {
        mkdir( "drive_c", 0777 );
        symlink( "../drive_c", "dosdevices/c:" );
        symlink( "/", "dosdevices/z:" );
    }
    else if (errno != EEXIST) fatal_perror( "cannot create %s/dosdevices", config_dir );

    if (fd_cwd == -1) fd_cwd = open( "dosdevices/c:", O_RDONLY );
    fcntl( fd_cwd, F_SETFD, FD_CLOEXEC );
    return fd_cwd;
}


/***********************************************************************
 *           server_connect_error
 *
 * Try to display a meaningful explanation of why we couldn't connect
 * to the server.
 */
static void server_connect_error( const char *serverdir )
{
    int fd;
    struct flock fl;

    if ((fd = open( LOCKNAME, O_WRONLY )) == -1)
        fatal_error( "for some mysterious reason, the wine server never started.\n" );

    fl.l_type   = F_WRLCK;
    fl.l_whence = SEEK_SET;
    fl.l_start  = 0;
    fl.l_len    = 1;
    if (fcntl( fd, F_GETLK, &fl ) != -1)
    {
        if (fl.l_type == F_WRLCK)  /* the file is locked */
            fatal_error( "a wine server seems to be running, but I cannot connect to it.\n"
                         "   You probably need to kill that process (it might be pid %d).\n",
                         (int)fl.l_pid );
        fatal_error( "for some mysterious reason, the wine server failed to run.\n" );
    }
    fatal_error( "the file system of '%s' doesn't support locks,\n"
          "   and there is a 'socket' file in that directory that prevents wine from starting.\n"
          "   You should make sure no wine server is running, remove that file and try again.\n",
                 serverdir );
}


/***********************************************************************
 *           server_connect
 *
 * Attempt to connect to an existing server socket.
 */
static int server_connect(void)
{
    struct sockaddr_un addr;
    struct stat st;
    int s, slen, retry;

#ifdef WINE_IOS
    wine_log_write("[Wine connect] setup_config_dir...");
#endif
    initial_cwd = setup_config_dir();

#ifdef WINE_IOS
    wine_log_write("[Wine connect] server_dir=%s", server_dir ? server_dir : "(null)");
    {
        char cwd_buf[1024];
        if (getcwd(cwd_buf, sizeof(cwd_buf)))
            wine_log_write("[Wine connect] cwd=%s", cwd_buf);
    }
#endif

    /* chdir to the server directory */
    if (chdir( server_dir ) == -1)
    {
        if (errno != ENOENT) fatal_perror( "chdir to %s", server_dir );
        start_server( TRACE_ON(server) );
        if (chdir( server_dir ) == -1) fatal_perror( "chdir to %s", server_dir );
    }

#ifdef WINE_IOS
    wine_log_write("[Wine connect] chdir OK, checking socket...");
#endif

    /* make sure we are at the right place */
    if (stat( ".", &st ) == -1) fatal_perror( "stat %s", server_dir );
    if (st.st_uid != getuid()) fatal_error( "'%s' is not owned by you\n", server_dir );
    if (st.st_mode & 077) fatal_error( "'%s' must not be accessible by other users\n", server_dir );

    for (retry = 0; retry < 6; retry++)
    {
#ifdef WINE_IOS
        wine_log_write("[Wine connect] retry %d", retry);
#endif
        /* if not the first try, wait a bit to leave the previous server time to exit */
        if (retry)
        {
            usleep( 100000 * retry * retry );
            start_server( TRACE_ON(server) );
            if (lstat( SOCKETNAME, &st ) == -1) continue;  /* still no socket, wait a bit more */
        }
        else if (lstat( SOCKETNAME, &st ) == -1) /* check for an already existing socket */
        {
#ifdef WINE_IOS
            wine_log_write("[Wine connect] socket lstat failed: %{public}s", strerror(errno));
#endif
            if (errno != ENOENT) fatal_perror( "lstat %s/%s", server_dir, SOCKETNAME );
            start_server( TRACE_ON(server) );
            if (lstat( SOCKETNAME, &st ) == -1) continue;  /* still no socket, wait a bit more */
        }

        /* make sure the socket is sane (ISFIFO needed for Solaris) */
        if (!S_ISSOCK(st.st_mode) && !S_ISFIFO(st.st_mode))
            fatal_error( "'%s/%s' is not a socket\n", server_dir, SOCKETNAME );
        if (st.st_uid != getuid())
            fatal_error( "'%s/%s' is not owned by you\n", server_dir, SOCKETNAME );

        /* try to connect to it */
        addr.sun_family = AF_UNIX;
        strcpy( addr.sun_path, SOCKETNAME );
        slen = sizeof(addr) - sizeof(addr.sun_path) + strlen(addr.sun_path) + 1;
#ifdef HAVE_STRUCT_SOCKADDR_UN_SUN_LEN
        addr.sun_len = slen;
#endif
        if ((s = socket( AF_UNIX, SOCK_STREAM, 0 )) == -1) fatal_perror( "socket" );
#ifdef SO_PASSCRED
        else
        {
            int enable = 1;
            setsockopt( s, SOL_SOCKET, SO_PASSCRED, &enable, sizeof(enable) );
        }
#endif
#ifdef WINE_IOS
        wine_log_write("[Wine connect] attempting connect...");
#endif
        if (connect( s, (struct sockaddr *)&addr, slen ) != -1)
        {
#ifdef WINE_IOS
            wine_log_write("[Wine connect] CONNECTED to wineserver!");
#endif
            fchdir( initial_cwd );  /* switch back to the starting directory */
            fcntl( s, F_SETFD, FD_CLOEXEC );
            return s;
        }
#ifdef WINE_IOS
        wine_log_write("[Wine connect] connect failed: %{public}s", strerror(errno));
#endif
        close( s );
    }
    server_connect_error( server_dir );
}


#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <servers/bootstrap.h>

/* send our task port to the server */
static void send_server_task_port(void)
{
    mach_port_t bootstrap_port, wineserver_port;
    kern_return_t kret;

    struct {
        mach_msg_header_t           header;
        mach_msg_body_t             body;
        mach_msg_port_descriptor_t  task_port;
    } msg;

    if (task_get_bootstrap_port(mach_task_self(), &bootstrap_port) != KERN_SUCCESS) return;

    if (!server_dir)
    {
        struct stat st;
        stat( config_dir, &st );
        server_dir = init_server_dir( st.st_dev, st.st_ino );
    }
    kret = bootstrap_look_up(bootstrap_port, server_dir, &wineserver_port);
    if (kret != KERN_SUCCESS)
        fatal_error( "cannot find the server port: 0x%08x\n", kret );

    mach_port_deallocate(mach_task_self(), bootstrap_port);

    msg.header.msgh_bits        = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    msg.header.msgh_size        = sizeof(msg);
    msg.header.msgh_remote_port = wineserver_port;
    msg.header.msgh_local_port  = MACH_PORT_NULL;

    msg.body.msgh_descriptor_count  = 1;
    msg.task_port.name              = mach_task_self();
    msg.task_port.disposition       = MACH_MSG_TYPE_COPY_SEND;
    msg.task_port.type              = MACH_MSG_PORT_DESCRIPTOR;

    kret = mach_msg_send(&msg.header);
    if (kret != KERN_SUCCESS)
        server_protocol_error( "mach_msg_send failed: 0x%08x\n", kret );

    mach_port_deallocate(mach_task_self(), wineserver_port);
}
#endif  /* __APPLE__ */


/***********************************************************************
 *           get_unix_tid
 *
 * Retrieve the Unix tid to use on the server side for the current thread.
 */
static int get_unix_tid(void)
{
    int ret = -1;
#ifdef HAVE_PTHREAD_GETTHREADID_NP
    ret = pthread_getthreadid_np();
#elif defined(linux)
    ret = syscall( __NR_gettid );
#elif defined(__sun)
    ret = pthread_self();
#elif defined(__APPLE__)
    ret = mach_thread_self();
    mach_port_deallocate(mach_task_self(), ret);
#elif defined(__NetBSD__)
    ret = _lwp_self();
#elif defined(__FreeBSD__)
    long lwpid;
    thr_self( &lwpid );
    ret = lwpid;
#elif defined(__DragonFly__)
    ret = lwp_gettid();
#endif
    return ret;
}


/***********************************************************************
 *           init_thread_pipe
 *
 * Create the server->client communication pipe.
 */
static int init_thread_pipe(void)
{
    int reply_pipe[2];
    stack_t ss;

    ss.ss_sp    = get_signal_stack();
    ss.ss_size  = signal_stack_size;
    ss.ss_flags = 0;
    sigaltstack( &ss, NULL );

    if (server_pipe( reply_pipe ) == -1) server_protocol_perror( "pipe" );
    if (server_pipe( ntdll_get_thread_data()->wait_fd ) == -1) server_protocol_perror( "pipe" );
#ifdef WINE_IOS
    {
        void *peb = ios_jit_current_peb();
        ios_fdt_reg( reply_pipe[0], FDT_REPLY_RD, peb );
        ios_fdt_reg( reply_pipe[1], FDT_REPLY_WR, peb );
        ios_fdt_reg( ntdll_get_thread_data()->wait_fd[0], FDT_WAIT_RD, peb );
        ios_fdt_reg( ntdll_get_thread_data()->wait_fd[1], FDT_WAIT_WR, peb );
        wine_log_write("[fdtrace] pipes tid=%04x peb=%p master=%d reply=%d/%d wait=%d/%d rev=ml586",
                       (unsigned int)GetCurrentThreadId(), peb, ios_current_fd_socket(),
                       reply_pipe[0], reply_pipe[1],
                       ntdll_get_thread_data()->wait_fd[0], ntdll_get_thread_data()->wait_fd[1]);
    }
#endif
    wine_server_send_fd( reply_pipe[1] );
    wine_server_send_fd( ntdll_get_thread_data()->wait_fd[1] );
    ntdll_get_thread_data()->reply_fd = reply_pipe[0];
    return reply_pipe[1];
}


/***********************************************************************
 *           process_exit_wrapper
 *
 * Close server socket and exit process normally.
 */
void process_exit_wrapper( int status )
{
#ifdef WINE_IOS
    /* Close THIS pseudo-process's master socket — the EOF is how wineserver
     * learns the process died (signals its process object, wakes waiters).
     * Clear the registry slot so a stray second call can't double-close. */
    int i = ios_proc_socket_index();
    if (i >= 0)
    {
        extern void ios_jit_reclaim_process( void *peb );
        extern void ios_retire_own_fixed_base_image( void *peb );
        void *dead_peb = ios_proc_sockets[i].peb;
        wine_log_write("[Wine ntdll/server] process_exit_wrapper(%d): closing child fd_socket=%d",
                       status, ios_proc_sockets[i].fd);
        /* ml987: hand back the fixed-base main image BEFORE the socket closes.
         * NtUnmapViewOfSection needs a live server connection, and this is the
         * last moment we have one while still on the owning process's thread. */
        ios_retire_own_fixed_base_image( dead_peb );
        ios_fdt_note_close( ios_proc_sockets[i].fd, "exit-master", dead_peb );
        close( ios_proc_sockets[i].fd );
        ios_proc_sockets[i].peb = NULL;
        {   /* Madeira child-exit: this child's process ended; its slot in process_ios.c must not keep a session alive */
            extern void ios_child_slot_exited( void *peb );
            ios_child_slot_exited( dead_peb );
        }
        {   /* child-exit: and the status it ended with stays in the table's ring (for a game-end watch);
             * an error status of a process no slot holds is said once per exit, so a log shows when the watch missed one */
            extern int ios_child_slot_note_exit( void *peb, int status );
            if (!ios_child_slot_note_exit( dead_peb, status ) && ((unsigned)status & 0xC0000000u) == 0xC0000000u)
                wine_log_write("[child-table] a process ended with status 0x%x and the table has no slot for it (peb=%p)",
                               (unsigned)status, dead_peb);
        }
        ios_dead_pebs[__sync_fetch_and_add( &ios_dead_peb_next, 1 ) % IOS_DEAD_PEB_MAX] = dead_peb;
        /* ml571: drop this pseudo-process's fd cache and close what it held.
         * Must happen on the SAME identity used to key it, and before the JIT
         * reclaim below reuses anything. */
        {
            extern void ios_fd_cache_release( void *peb );
            ios_fd_cache_release( dead_peb );
        }
        {   /* ml1205: its ml938 sub-floor windows go with it */
            extern void ios_subfloor_release_owner( void *owner );
            ios_subfloor_release_owner( dead_peb );
        }
        /* Task #25: release this pseudo-process's JIT pool allocations
         * (module copies, trampolines, FEX CodeBuffers). Children only —
         * the session (else-branch) lives as long as the app. Reuse is
         * grace-delayed inside the allocator for laggard exit threads. */
        ios_jit_reclaim_process( dead_peb );
        /* and its guest window, if it had one.  Here rather
         * than only in ios_child_thread_entry because THIS is the chokepoint
         * every pseudo-process exit reaches, on whichever thread called
         * ExitProcess — a guest worker thread that ends the process does not
         * return to the boot thread's setjmp at all.  Keyed by the dying PEB,
         * not by the calling thread.  Nothing is unmapped here; see
         * ios_wow_window_mark_released(). */
        ios_wow_window_release( dead_peb );
        /* ml988 phase 2: only now may the retired fixed base be handed on. Until
         * this point the old generation's pool mappings and FEX translations are
         * still live, so a new claimant taking the same VA would race them. */
        {
            extern void ios_exe_win_mark_ready( void *peb );
            ios_exe_win_mark_ready( dead_peb );
        }
    }
    else
    {
        /* madeira-orphan-exit: "no slot" is not proof of being the session.
         * A thread of a child process that has already exited also has no
         * slot -- its slot was cleared when the process went -- and on iOS
         * such a thread is still running, because a pthread cannot be stopped
         * from outside. Treating it as the session closed the session's
         * master socket and ended every program in it. Compare the caller's
         * PEB with the session's own; anything else exits only itself. */
        extern void *ios_session_peb_get( void );
        void *caller = ios_jit_current_peb();
        void *session = ios_session_peb_get();
        if (caller && session && caller != session)
        {
            wine_log_write( "[Wine ntdll/server] process_exit_wrapper(%d): orphaned thread "
                            "of an exited process (peb=%p); exiting this thread only",
                            status, caller );
            pthread_exit( NULL );
        }
        /* No slot: this is the session's initial process, the program the app
         * itself handed to __wine_main (WineProcessBridge.m). Its exit status
         * is how the app's library tells a crash from a normal quit. A weak
         * hook with one integer argument: no names, no allocation, no logging;
         * helpers and anything the program starts have a slot and never call it. */
        extern void wine_launched_process_did_exit( int status ) __attribute__((weak));
        if (wine_launched_process_did_exit) wine_launched_process_did_exit( status );
        close( fd_socket );
    }
#else
    close( fd_socket );
#endif
    wine_log_write("[Wine ntdll/server] process_exit_wrapper(%d)", status );
    exit( status );  /* on iOS, wine_ios_exit shim longjmps back to wine_process_thread */
}


#ifdef WINE_IOS
/***********************************************************************
 *           ios_unix_fatal_exit   (ml1310)
 *
 * For the bare exit() calls left in ntdll's unix side (failed shared user data
 * or ARM64EC map, failed signal set-up). exit() is already the wine_ios_exit
 * shim, so it never ends the app, but it ends only the calling thread (or
 * longjmps a pseudo-process's boot thread) without closing that pseudo-
 * process's master socket: the server never learns the process died, its
 * waiters hang, and its JIT-pool copies are never reclaimed. A pseudo-process
 * that has its own server socket now ends through process_exit_wrapper, the
 * path exit_process and abort_process take. Without one (the session's own
 * start-up, a child before it registered), plain exit() as before. Idea from
 * the published patch 0032 of another iOS port.
 */
void ios_unix_fatal_exit( int status, const char *why ) __attribute__((noreturn));
void ios_unix_fatal_exit( int status, const char *why )
{
    static int route = -1;
    int i = ios_proc_socket_index();

    /* MADEIRA_UNIX_EXIT_ROUTE=0: a fatal unix-side error calls plain (shimmed) exit() again (ml1310) */
    if (route < 0) { const char *e = getenv( "MADEIRA_UNIX_EXIT_ROUTE" ); route = !(e && e[0] == '0'); }
    dprintf( 2, "[exit-route] ml1310 %s: status %d, %s\n", why, status,
             route && i >= 0 ? "ending this pseudo-process (socket closed, pool reclaimed)"
                             : "plain exit (no own server socket, or MADEIRA_UNIX_EXIT_ROUTE=0)" );
    if (route && i >= 0)
    {
        pthread_sigmask( SIG_BLOCK, &server_block_set, NULL );
        process_exit_wrapper( status );
    }
    exit( status );
}
#endif


#ifdef WINE_IOS
/***********************************************************************
 *           ios_create_drive_symlinks
 *
 * Publish \DosDevices\X: objects for the drives that exist in the prefix.
 *
 * On a normal Wine host mountmgr.sys does this at boot: create_drive_devices()
 * walks $WINEPREFIX/dosdevices and add_dosdev_mount_point() creates the
 * \DosDevices\X: -> \Device\HarddiskVolumeN symlink (mountmgr.sys/mountmgr.c).
 * iOS runs no winedevice.exe and mountmgr.sys is not even shipped, so nothing
 * ever created them and the NT namespace listed ZERO drives. GetLogicalDrives()
 * builds its bitmap by enumerating \DosDevices for two-character "X:" entries
 * (kernelbase/volume.c), so it returned 0 and every drive-enumerating UI came up
 * empty -- shell32's My Computer (CreateMyCompEnumList -> get_drive_map), the
 * common file dialogs, installers checking for a target drive.
 *
 * Path RESOLUTION never depended on this: ntdll maps C:\... directly onto
 * <config_dir>/dosdevices/c: on disk (unix/file.c), which is why launching
 * programs by full path always worked and why adding these objects cannot
 * change how any existing path resolves. This only makes drives LISTABLE.
 *
 * The device objects themselves still do not exist (no driver stack), so the
 * link targets dangle -- same shape mountmgr would produce, minus the volume.
 */
static void ios_create_drive_symlinks(void)
{
    /* Explicit WCHAR arrays, NOT L"...": the unix side is built without
     * -fshort-wchar, so a wide literal here would be 4-byte wchar_t. */
    static const WCHAR link_prefixW[] = {'\\','D','o','s','D','e','v','i','c','e','s','\\'};
    static const WCHAR dev_prefixW[]  = {'\\','D','e','v','i','c','e','\\',
                                         'H','a','r','d','d','i','s','k','V','o','l','u','m','e'};
    const unsigned int link_prefix_len = sizeof(link_prefixW) / sizeof(WCHAR);
    const unsigned int dev_prefix_len  = sizeof(dev_prefixW) / sizeof(WCHAR);
    char *dosdevices;
    DIR *dir;
    struct dirent *de;
    int created = 0, seen = 0;

    if (asprintf( &dosdevices, "%s/dosdevices", config_dir ) == -1) return;
    if (!(dir = opendir( dosdevices )))
    {
        wine_log_write( "[drives] no dosdevices dir at %s (errno=%d) - no drives published",
                        dosdevices, errno );
        free( dosdevices );
        return;
    }
    free( dosdevices );

    while ((de = readdir( dir )))
    {
        WCHAR name[ sizeof(link_prefixW) / sizeof(WCHAR) + 2 ];
        WCHAR target[ sizeof(dev_prefixW) / sizeof(WCHAR) + 2 ];
        OBJECT_ATTRIBUTES attr;
        UNICODE_STRING name_str, target_str;
        unsigned int vol, digits = 0;
        NTSTATUS status;
        HANDLE handle;

        /* mountmgr's own filter: exactly "<letter>:". Skips com1/lpt1 and the
         * "c::" unix-device links that share this directory. */
        if (strlen( de->d_name ) != 2 || de->d_name[1] != ':') continue;
        if (de->d_name[0] < 'a' || de->d_name[0] > 'z') continue;
        seen++;

        memcpy( name, link_prefixW, sizeof(link_prefixW) );
        /* MUST be upper case: GetLogicalDrives() derives the bit index as
         * (ObjectName.Buffer[0] - 'A'), so a lower-case name would shift by 32+. */
        name[link_prefix_len]     = de->d_name[0] - 'a' + 'A';
        name[link_prefix_len + 1] = ':';
        name_str.Buffer        = name;
        name_str.Length        = (link_prefix_len + 2) * sizeof(WCHAR);
        name_str.MaximumLength = name_str.Length;

        vol = de->d_name[0] - 'a' + 1;
        memcpy( target, dev_prefixW, sizeof(dev_prefixW) );
        if (vol >= 10) target[dev_prefix_len + digits++] = '0' + vol / 10;
        target[dev_prefix_len + digits++] = '0' + vol % 10;
        target_str.Buffer        = target;
        target_str.Length        = (dev_prefix_len + digits) * sizeof(WCHAR);
        target_str.MaximumLength = target_str.Length;

        /* Same attributes IoCreateSymbolicLink() uses (ntoskrnl.exe/ntoskrnl.c):
         * PERMANENT so the object outlives this handle, OPENIF so a re-run is
         * idempotent rather than an error. */
        attr.Length                   = sizeof(attr);
        attr.RootDirectory            = 0;
        attr.ObjectName               = &name_str;
        attr.Attributes               = OBJ_CASE_INSENSITIVE | OBJ_OPENIF | OBJ_PERMANENT;
        attr.SecurityDescriptor       = NULL;
        attr.SecurityQualityOfService = NULL;

        status = NtCreateSymbolicLinkObject( &handle, SYMBOLIC_LINK_ALL_ACCESS, &attr, &target_str );
        if (!status)
        {
            NtClose( handle );
            created++;
        }
        else wine_log_write( "[drives] %c: symlink failed status=%08x",
                             de->d_name[0], (unsigned int)status );
    }
    closedir( dir );
    wine_log_write( "[drives] published %d/%d DOS drive(s) in \\DosDevices rev=ml587", created, seen );
}

#include "hw_registry_ios.h"

/* CNTFRQ_EL0, the counter FEX scales the guest's TSC from. */
static uint64_t ios_hw_cntfrq(void)
{
    uint64_t freq = 0;
#ifdef __aarch64__
    __asm__ volatile( "mrs %0, CNTFRQ_EL0" : "=r" (freq) );
#endif
    return freq;
}

/* hw-registry-test:begin (tests/host/check-hw-registry.py compiles from here to the end mark) */
#define IOS_HW_RSMB 0x52534d42   /* 'RSMB', the SMBIOS firmware table provider */

/* One registry key, created level by level below `base` (an existing key),
 * every new level volatile. NtCreateKey makes ONE key: since Wine 11 keys are
 * named objects and a path whose parent is missing fails with
 * STATUS_OBJECT_NAME_NOT_FOUND (server/registry.c key_lookup_name), as on
 * Windows; only kernelbase's RegCreateKeyEx walks the path itself. */
static HANDLE ios_hw_key( const char *base, const char *subpath )
{
    WCHAR nameW[256];
    UNICODE_STRING name;
    OBJECT_ATTRIBUTES attr;
    HANDLE key, parent;
    const char *p = subpath, *end;
    size_t len = strlen( base );

    if (len >= ARRAY_SIZE(nameW)) return 0;
    ascii_to_unicode( nameW, base, len + 1 );
    init_unicode_string( &name, nameW );
    InitializeObjectAttributes( &attr, &name, OBJ_CASE_INSENSITIVE, 0, NULL );
    if (NtOpenKey( &parent, KEY_ALL_ACCESS, &attr )) return 0;
    while (*p)
    {
        if (!(end = strchr( p, '\\' ))) end = p + strlen( p );
        len = end - p;
        if (!len || len >= ARRAY_SIZE(nameW))
        {
            NtClose( parent );
            return 0;
        }
        ascii_to_unicode( nameW, p, len );
        nameW[len] = 0;
        init_unicode_string( &name, nameW );
        InitializeObjectAttributes( &attr, &name, OBJ_CASE_INSENSITIVE, parent, NULL );
        if (NtCreateKey( &key, KEY_ALL_ACCESS, &attr, 0, NULL, REG_OPTION_VOLATILE, NULL )) key = 0;
        NtClose( parent );
        if (!key) return 0;
        parent = key;
        p = *end ? end + 1 : end;
    }
    return parent;
}

/* The SMBIOS table exactly as GetSystemFirmwareTable('RSMB') hands it to the
 * guest (WMI's Win32_BIOS / Win32_BaseBoard read the same bytes); NULL when
 * ntdll has none. */
static unsigned char *ios_hw_smbios( ULONG *len )
{
    const ULONG head = offsetof( SYSTEM_FIRMWARE_TABLE_INFORMATION, TableBuffer );
    SYSTEM_FIRMWARE_TABLE_INFORMATION *sfti;
    ULONG size = head, needed = 0;
    unsigned char *table = NULL;
    NTSTATUS status;
    int tries;

    *len = 0;
    for (tries = 0; tries < 2; tries++)
    {
        if (!(sfti = calloc( 1, size ))) return NULL;
        sfti->ProviderSignature = IOS_HW_RSMB;
        sfti->Action = SystemFirmwareTable_Get;
        sfti->TableID = 0;
        status = NtQuerySystemInformation( SystemFirmwareTableInformation, sfti, size, &needed );
        if (status == STATUS_BUFFER_TOO_SMALL && needed > size)
        {
            free( sfti );
            size = needed;
            continue;
        }
        if (!status && sfti->TableBufferLength && sfti->TableBufferLength <= size - head &&
            (table = malloc( sfti->TableBufferLength )))
        {
            memcpy( table, sfti->TableBuffer, sfti->TableBufferLength );
            *len = sfti->TableBufferLength;
        }
        free( sfti );
        break;
    }
    return table;
}

/* wineboot's fallback when the TSC rate is unknown: the processor's MaxMhz. */
static DWORD ios_hw_power_mhz(void)
{
    ULONG count = peb->NumberOfProcessors ? peb->NumberOfProcessors : 1;
    PROCESSOR_POWER_INFORMATION *info;
    DWORD mhz = 0;

    if ((info = calloc( count, sizeof(*info) )))
    {
        if (!NtPowerInformation( ProcessorInformation, NULL, 0, info, count * sizeof(*info) ))
            mhz = info[0].MaxMhz;
        free( info );
    }
    return mhz;
}

static void ios_hw_sz( HANDLE key, const char *name, const char *value )
{
    WCHAR nameW[64], data[HWREG_STR];
    UNICODE_STRING str;
    size_t n = strnlen( value, HWREG_STR - 1 );

    ascii_to_unicode( nameW, name, strlen( name ) + 1 );
    ascii_to_unicode( data, value, n );
    data[n] = 0;
    init_unicode_string( &str, nameW );
    NtSetValueKey( key, &str, 0, REG_SZ, data, (n + 1) * sizeof(WCHAR) );
}

static void ios_hw_dword( HANDLE key, const char *name, DWORD value )
{
    WCHAR nameW[64];
    UNICODE_STRING str;

    ascii_to_unicode( nameW, name, strlen( name ) + 1 );
    init_unicode_string( &str, nameW );
    NtSetValueKey( key, &str, 0, REG_DWORD, &value, sizeof(value) );
}

/* Session Manager\Environment is saved with the prefix: write a value only
 * when it differs from what the key holds. 1 = written. */
static int ios_hw_env_value( HANDLE key, const char *name, const char *value )
{
    union
    {
        KEY_VALUE_PARTIAL_INFORMATION info;
        char raw[offsetof( KEY_VALUE_PARTIAL_INFORMATION, Data ) + 128 * sizeof(WCHAR)];
    } buf;
    WCHAR nameW[64];
    UNICODE_STRING str;
    ULONG size = 0, n = strlen( value ), i;
    const WCHAR *old;

    ascii_to_unicode( nameW, name, strlen( name ) + 1 );
    init_unicode_string( &str, nameW );
    if (!NtQueryValueKey( key, &str, KeyValuePartialInformation, &buf, sizeof(buf), &size ) &&
        buf.info.Type == REG_SZ && buf.info.DataLength >= n * sizeof(WCHAR))
    {
        old = (const WCHAR *)buf.info.Data;
        for (i = 0; i < n; i++) if (old[i] != (unsigned char)value[i]) break;
        if (i == n && (buf.info.DataLength == n * sizeof(WCHAR) || !old[n])) return 0;
    }
    ios_hw_sz( key, name, value );
    return 1;
}

/***********************************************************************
 *           ios_hw_registry_publish
 *
 * wineboot's create_hardware_registry_keys for this port. Desktop Wine runs
 * wineboot at every boot and it writes the volatile
 * HKLM\HARDWARE\DESCRIPTION\System tree: Identifier and SystemBiosDate, BIOS
 * (from the SMBIOS table), CentralProcessor\N and FloatingPointProcessor\N for
 * every processor. wineboot never runs here, so none of it existed: GTA V
 * Enhanced's hardware-info thread failed to open CentralProcessor\0 and BIOS,
 * and WMI's Win32_Processor had no Caption. Written once per session, by the
 * first process, after init_cpu_info (the processor count) and before the
 * first process builds its environment. The processor values describe what
 * the x86-64 guest sees from FEX's CPUID (hw_registry_ios.h), the count is
 * GetSystemInfo's. Children of the session read the same registry.
 * MADEIRA_HW_REGISTRY=2 also writes wineboot's five processor values in
 * Session Manager\Environment (saved with the prefix, only when they differ).
 */
void ios_hw_registry_publish(void)
{
    static const char machine[] = "\\Registry\\Machine";
    static const char sysdesc[] = "HARDWARE\\DESCRIPTION\\System";
    static const char envkey[] = "\\Registry\\Machine\\System\\CurrentControlSet\\Control\\Session Manager\\Environment";
    /* FEX reads this switch itself (FetchHostFeatures); it is only mirrored here. */
    static const char fex_avx[] = "MADEIRA_FEX_AVX";
    const char *avx = getenv( fex_avx );
    struct hwreg_cpu cpu;
    struct hwreg_bios bios;
    struct hwreg_env env[HWREG_ENV_VALUES];
    unsigned int i, count, cpus = 0, fpus = 0, rewritten = 0;
    unsigned char *smbios;
    ULONG smbios_len = 0;
    char path[96], extra[128] = "";
    WCHAR envW[ARRAY_SIZE(envkey)];
    UNICODE_STRING name;
    OBJECT_ATTRIBUTES attr;
    HANDLE key;
    int mode;

    /* Default 1: wineboot's volatile HKLM\HARDWARE\DESCRIPTION\System keys. 0: none
     * (no session had them before). 2: also the Session Manager\Environment values. */
    mode = hwreg_mode( getenv( "MADEIRA_HW_REGISTRY" ) );
    if (!mode)
    {
        wine_log_write( "[hw-registry] MADEIRA_HW_REGISTRY=0, no HARDWARE\\DESCRIPTION keys written" );
        return;
    }

    count = hwreg_cpu_count( peb->NumberOfProcessors );
    /* AVX exists only in FEX's ARM64EC module; a 32-bit main image runs the WOW64
     * module, which has no AVX. */
    /* as FEX reads it: "1..." AVX and AVX2; exactly "2" AVX without AVX2 */
    hwreg_fex_cpu( &cpu, (!avx || ios_main_image_i386) ? 0 : avx[0] == '1' ? 1 :
                         (avx[0] == '2' && !avx[1]) ? 2 : 0, ios_hw_cntfrq() );
    if (!cpu.mhz) cpu.mhz = ios_hw_power_mhz();
    smbios = ios_hw_smbios( &smbios_len );
    hwreg_bios_values( &bios, smbios, smbios_len, PACKAGE_VERSION );
    free( smbios );

    if (!(key = ios_hw_key( machine, sysdesc )))
    {
        wine_log_write( "[hw-registry] could not create HKLM\\%s, nothing written", sysdesc );
        return;
    }
    ios_hw_sz( key, "Identifier", "AT compatible" );
    ios_hw_sz( key, "SystemBiosDate", "01/01/70" );
    NtClose( key );

    snprintf( path, sizeof(path), "%s\\BIOS", sysdesc );
    if ((key = ios_hw_key( machine, path )))
    {
        ios_hw_sz( key, "BaseBoardManufacturer", bios.board_vendor );
        ios_hw_sz( key, "BaseBoardProduct", bios.board_product );
        ios_hw_sz( key, "BaseBoardVersion", bios.board_version );
        ios_hw_sz( key, "BIOSVendor", bios.bios_vendor );
        ios_hw_sz( key, "BIOSVersion", bios.bios_version );
        ios_hw_sz( key, "BIOSReleaseDate", bios.bios_date );
        ios_hw_dword( key, "BiosMajorRelease", bios.bios_major );
        ios_hw_dword( key, "BiosMinorRelease", bios.bios_minor );
        ios_hw_dword( key, "ECFirmwareMajorVersion", bios.ec_major );
        ios_hw_dword( key, "ECFirmwareMinorVersion", bios.ec_minor );
        ios_hw_sz( key, "SystemManufacturer", bios.sys_vendor );
        ios_hw_sz( key, "SystemProductName", bios.sys_product );
        ios_hw_sz( key, "SystemVersion", bios.sys_version );
        ios_hw_sz( key, "SystemSKU", bios.sys_sku );
        ios_hw_sz( key, "SystemFamily", bios.sys_family );
        NtClose( key );
    }

    for (i = 0; i < count; i++)
    {
        snprintf( path, sizeof(path), "%s\\CentralProcessor\\%u", sysdesc, i );
        if ((key = ios_hw_key( machine, path )))
        {
            ios_hw_dword( key, "FeatureSet", cpu.feature_set );
            ios_hw_sz( key, "Identifier", cpu.identifier );
            ios_hw_sz( key, "VendorIdentifier", cpu.vendor );
            ios_hw_sz( key, "ProcessorNameString", cpu.brand );
            ios_hw_dword( key, "~MHz", cpu.mhz );
            NtClose( key );
            cpus++;
        }
        snprintf( path, sizeof(path), "%s\\FloatingPointProcessor\\%u", sysdesc, i );
        if ((key = ios_hw_key( machine, path )))
        {
            ios_hw_sz( key, "Identifier", cpu.identifier );
            NtClose( key );
            fpus++;
        }
    }

    if (mode == 2)
    {
        ascii_to_unicode( envW, envkey, ARRAY_SIZE(envkey) );
        init_unicode_string( &name, envW );
        InitializeObjectAttributes( &attr, &name, OBJ_CASE_INSENSITIVE, 0, NULL );
        if (!NtOpenKey( &key, KEY_QUERY_VALUE | KEY_SET_VALUE, &attr ))
        {
            hwreg_environment( env, &cpu, peb->NumberOfProcessors );
            for (i = 0; i < HWREG_ENV_VALUES; i++) rewritten += ios_hw_env_value( key, env[i].name, env[i].value );
            NtClose( key );
            snprintf( extra, sizeof(extra), "; Session Manager\\Environment: %u of %u processor values rewritten",
                      rewritten, (unsigned int)HWREG_ENV_VALUES );
        }
        else snprintf( extra, sizeof(extra), "; Session Manager\\Environment missing, not touched" );
    }

    wine_log_write( "[hw-registry] HKLM\\%s (volatile): %u/%u CentralProcessor + %u FloatingPointProcessor "
                    "\"%s\" %s \"%s\" ~MHz %u FeatureSet 0x%08x; BIOS \"%s\" \"%s\" (%s, %u Wine default(s))%s",
                    sysdesc, cpus, count, fpus, cpu.identifier, cpu.vendor, cpu.brand, (unsigned int)cpu.mhz,
                    (unsigned int)cpu.feature_set, bios.sys_vendor, bios.sys_product,
                    smbios_len ? "SMBIOS" : "no SMBIOS table", bios.defaults, extra );
}
/* hw-registry-test:end */

#include "../hidpad/hidpad_ids.h"

/* ml2105: the HID pad's registry keys are made level by level, every new level
 * volatile, by the same helper as the hardware description keys above. */
#define ios_hidpad_key ios_hw_key

static void ios_hidpad_value( HANDLE key, const char *value, ULONG type, const char *const *strings,
                              unsigned int count, DWORD number )
{
    WCHAR nameW[32], data[512];
    UNICODE_STRING name;
    ULONG size = 0;
    unsigned int i;

    ascii_to_unicode( nameW, value, strlen( value ) + 1 );
    init_unicode_string( &name, nameW );
    if (type == REG_DWORD)
    {
        NtSetValueKey( key, &name, 0, type, &number, sizeof(number) );
        return;
    }
    for (i = 0; i < count; i++)
    {
        size_t len = strlen( strings[i] ) + 1;
        if (size + len + 1 > ARRAY_SIZE(data)) break;
        ascii_to_unicode( data + size, strings[i], len );
        size += len;
    }
    if (type == REG_MULTI_SZ) data[size++] = 0;
    NtSetValueKey( key, &name, 0, type, data, size * sizeof(WCHAR) );
}

/* ml2105: the identity whose \??\HID#... link the wineserver created
 * (hidpad_ios.c), or NULL; `link` gets its interface name. The registry must
 * name exactly the device that exists: the wineserver reads MADEIRA_HIDPAD
 * when it starts, but madeira.cfg's env.NAME lines are exported later, just
 * before this process, and could name another identity. */
static const struct hidpad_identity *ios_hidpad_live_identity( char *link, unsigned int size )
{
    unsigned int i;

    for (i = 0; i < ARRAY_SIZE(hidpad_identities); i++)
    {
        WCHAR pathW[256];
        char path[256];
        UNICODE_STRING name;
        OBJECT_ATTRIBUTES attr;
        HANDLE handle;

        hidpad_interface_link( &hidpad_identities[i], link, size );
        snprintf( path, sizeof(path), "\\??\\%s", link );
        ascii_to_unicode( pathW, path, strlen( path ) + 1 );
        init_unicode_string( &name, pathW );
        InitializeObjectAttributes( &attr, &name, OBJ_CASE_INSENSITIVE, 0, NULL );
        if (!NtOpenSymbolicLinkObject( &handle, SYMBOLIC_LINK_QUERY, &attr ))
        {
            NtClose( handle );
            return &hidpad_identities[i];
        }
    }
    return NULL;
}

/***********************************************************************
 *           ios_hidpad_publish
 *
 * ml2102: the registry half of the opt-in HID controller (MADEIRA_HIDPAD,
 * build/hidpad/hidpad_ids.h). setupapi lists GUID_DEVINTERFACE_HID from
 * DeviceClasses\{4d1e55b2-...}: an interface key with DeviceInstance, its "#"
 * subkey with SymbolicLink and Control\Linked = 1 (what DIGCF_PRESENT checks,
 * setupapi devinst.c is_linked), and the Enum key that DeviceInstance names,
 * whose ClassGUID setupapi needs before it lists the device at all. hidclass
 * and setupapi write the same keys for a real device on desktop Wine (the
 * prefix template still holds Wine's virtual HID mouse and keyboard in this
 * shape, minus the volatile Control\Linked); win32u's raw input list reads
 * them too. The \??\HID#... link they point at is the wineserver's
 * (hidpad_ios.c). First process only, like the drive links above, so it is in
 * place before any game enumerates. In XInput mode the app unsets
 * MADEIRA_HIDPAD (GamepadInput.beginPadSession) and this does nothing.
 */
static void ios_hidpad_publish(void)
{
    static const char enumkey[] = "\\Registry\\Machine\\System\\CurrentControlSet\\Enum";
    static const char classes[] = "\\Registry\\Machine\\System\\CurrentControlSet\\Control\\DeviceClasses";
    const struct hidpad_identity *id;
    char link[200], path[400], instance[128], symlink[210];
    const char *class_name = "HIDClass", *class_guid = HIDPAD_HIDCLASS_GUID;
    const char *desc = "HID-compliant game controller";
    unsigned int written = 0;
    HANDLE key;

    if (!getenv( "MADEIRA_HIDPAD" )) return;
    if (!(id = ios_hidpad_live_identity( link, sizeof(link) )))
    {
        wine_log_write( "[hid-pad] ml2105 MADEIRA_HIDPAD=%s but the wineserver made no pad; "
                        "nothing registered rev=ml2105", getenv( "MADEIRA_HIDPAD" ) );
        return;
    }
    snprintf( instance, sizeof(instance), "%s\\%s", id->device_id, id->instance );
    snprintf( symlink, sizeof(symlink), "\\\\?\\%s", link );

    if ((key = ios_hidpad_key( enumkey, instance )))
    {
        ios_hidpad_value( key, "ClassGUID", REG_SZ, &class_guid, 1, 0 );
        ios_hidpad_value( key, "Class", REG_SZ, &class_name, 1, 0 );
        ios_hidpad_value( key, "DeviceDesc", REG_SZ, &desc, 1, 0 );
        ios_hidpad_value( key, "Mfg", REG_SZ, &id->manufacturer, 1, 0 );
        ios_hidpad_value( key, "HardwareID", REG_MULTI_SZ, id->hardware_ids, ARRAY_SIZE(id->hardware_ids), 0 );
        ios_hidpad_value( key, "ContainerID", REG_SZ, &id->container_id, 1, 0 );
        ios_hidpad_value( key, "ConfigFlags", REG_DWORD, NULL, 0, 0 );
        NtClose( key );
        written++;
    }
    snprintf( path, sizeof(path), "%s\\##?#%s", HIDPAD_HID_INTERFACE_GUID, link );
    if ((key = ios_hidpad_key( classes, path )))
    {
        const char *value = instance;
        ios_hidpad_value( key, "DeviceInstance", REG_SZ, &value, 1, 0 );
        NtClose( key );
        written++;
    }
    snprintf( path, sizeof(path), "%s\\##?#%s\\#", HIDPAD_HID_INTERFACE_GUID, link );
    if ((key = ios_hidpad_key( classes, path )))
    {
        const char *value = symlink;
        ios_hidpad_value( key, "SymbolicLink", REG_SZ, &value, 1, 0 );
        NtClose( key );
        written++;
    }
    snprintf( path, sizeof(path), "%s\\##?#%s\\#\\Control", HIDPAD_HID_INTERFACE_GUID, link );
    if ((key = ios_hidpad_key( classes, path )))
    {
        ios_hidpad_value( key, "Linked", REG_DWORD, NULL, 0, 1 );
        NtClose( key );
        written++;
    }
    wine_log_write( "[hid-pad] ml2102 %s %04X:%04X registered (%u/4 keys) as %s rev=ml2105",
                    id->env, id->vid, id->pid, written, symlink );
}

static void ios_vcrt_sz( HANDLE key, const char *name, const char *value )
{
    WCHAR nameW[32], data[48];
    UNICODE_STRING str;
    size_t n = strnlen( value, ARRAY_SIZE(data) - 1 );

    ascii_to_unicode( nameW, name, strlen( name ) + 1 );
    ascii_to_unicode( data, value, n );
    data[n] = 0;
    init_unicode_string( &str, nameW );
    NtSetValueKey( key, &str, 0, REG_SZ, data, (n + 1) * sizeof(WCHAR) );
}

static void ios_vcrt_dword( HANDLE key, const char *name, DWORD value )
{
    WCHAR nameW[32];
    UNICODE_STRING str;

    ascii_to_unicode( nameW, name, strlen( name ) + 1 );
    init_unicode_string( &str, nameW );
    NtSetValueKey( key, &str, 0, REG_DWORD, &value, sizeof(value) );
}

/* "14.42.34433" or "14.42.34433.0": three or four decimal numbers of at most five digits
 * separated by dots, nothing else. 1 = parsed into v[0..3] (the fourth is 0 when absent). */
static int ios_vcrt_version( const char *s, unsigned int v[4] )
{
    unsigned int part, digits;

    for (part = 0; part < 4; part++)
    {
        v[part] = 0;
        for (digits = 0; *s >= '0' && *s <= '9'; s++, digits++) v[part] = v[part] * 10 + (*s - '0');
        if (!digits || digits > 5) return 0;
        if (!*s) return part >= 2;
        if (*s++ != '.') return 0;
    }
    return 0;
}

/***********************************************************************
 *           ios_vcrt_arm64_key_publish
 *
 * Madeira vcrt-arm64: the "Installed" marker of Microsoft's ARM64 Visual C++
 * 2015-2022 redistributable, HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\arm64
 * (and the same key under Wow6432Node, where the prefix template keeps its x64
 * one). Some engine bootstrappers are x64 programs, but the session reports an
 * ARM64 machine, so they stop with "Microsoft Visual C++ 2015-2022
 * Redistributable (arm64) is required" and exit 0x2329; the prefix has the x64
 * and x86 markers only. Off unless env.MADEIRA_VCRT_ARM64_KEY = 1 or a version
 * such as 14.44.35211 (usually in a game's own configuration lines). "1" writes
 * 14.44.35211.0: a bootstrapper compares the marker with the version it was
 * built against, and a higher number only passes more of these checks. The keys
 * are volatile, as wineboot's hardware keys: nothing is saved with the prefix,
 * and a key already there is left alone. Written once per session by the first
 * process (loader_ios.c), before the program starts.
 */
void ios_vcrt_arm64_key_publish(void)
{
    static const char machine[] = "\\Registry\\Machine";
    static const char *const keys[] =
    {
        "Software\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\arm64",
        "Software\\Wow6432Node\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\arm64",
    };
    const char *sw = getenv( "MADEIRA_VCRT_ARM64_KEY" );
    unsigned int v[4] = { 14, 44, 35211, 0 }, i, made = 0, kept = 0, failed = 0;
    char version[32], path[160];
    WCHAR pathW[160];
    UNICODE_STRING name;
    OBJECT_ATTRIBUTES attr;
    HANDLE key;

    if (!sw || !sw[0] || !strcmp( sw, "0" )) return;
    if (strcmp( sw, "1" ) && !ios_vcrt_version( sw, v ))
    {
        wine_log_write( "[vcrt-arm64] MADEIRA_VCRT_ARM64_KEY=\"%.40s\" is neither 1 nor a version "
                        "like 14.42.34433.0, nothing written", sw );
        return;
    }
    snprintf( version, sizeof(version), "%u.%u.%u.%u", v[0], v[1], v[2], v[3] );

    for (i = 0; i < ARRAY_SIZE(keys); i++)
    {
        snprintf( path, sizeof(path), "%s\\%s", machine, keys[i] );
        ascii_to_unicode( pathW, path, strlen( path ) + 1 );
        init_unicode_string( &name, pathW );
        InitializeObjectAttributes( &attr, &name, OBJ_CASE_INSENSITIVE, 0, NULL );
        if (!NtOpenKey( &key, KEY_QUERY_VALUE, &attr ))
        {
            NtClose( key );
            kept++;
            continue;
        }
        if (!(key = ios_hw_key( machine, keys[i] )))
        {
            failed++;
            continue;
        }
        ios_vcrt_dword( key, "Bld", v[2] );
        ios_vcrt_dword( key, "Installed", 1 );
        ios_vcrt_dword( key, "Major", v[0] );
        ios_vcrt_dword( key, "Minor", v[1] );
        ios_vcrt_dword( key, "Rbld", v[3] );
        ios_vcrt_sz( key, "Version", version );
        NtClose( key );
        made++;
    }
    wine_log_write( "[vcrt-arm64] HKLM\\SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\arm64 "
                    "(volatile) Installed=1 Version %s: %u of %u view(s) written, %u already there and left alone, "
                    "%u could not be made; MADEIRA_VCRT_ARM64_KEY unset or 0 turns it off",
                    version, made, (unsigned int)ARRAY_SIZE(keys), kept, failed );
}
#endif


/***********************************************************************
 *           server_init_process
 *
 * Start the server and create the initial socket pair.
 */
size_t server_init_process(void)
{
    const char *arch = getenv( "WINEARCH" );
    const char *env_socket = getenv( "WINESERVERSOCKET" );
    struct ntdll_thread_data *data = ntdll_get_thread_data();
    obj_handle_t version;
    unsigned int i;
    int ret, reply_pipe;
    struct sigaction sig_act;
    size_t info_size;
    DWORD pid, tid;

    server_pid = -1;
    if (env_socket)
    {
        fd_socket = atoi( env_socket );
        if (fcntl( fd_socket, F_SETFD, FD_CLOEXEC ) == -1)
            fatal_perror( "Bad server socket %d", fd_socket );
        unsetenv( "WINESERVERSOCKET" );
        /* Still need config dir for dosdevices, drive_c, registry etc. */
        initial_cwd = setup_config_dir();
    }
    else
    {
        const char *arch = getenv( "WINEARCH" );

        if (is_win64 && arch && !strcmp( arch, "win32" ))
            fatal_error( "WINEARCH is set to 'win32' but this is not supported in wow64 mode.\n" );
        if (arch && strcmp( arch, "win32" ) && strcmp( arch, "win64" ) && strcmp( arch, "wow64" ))
            fatal_error( "WINEARCH set to invalid value '%s', it must be win32, win64, or wow64.\n", arch );

        /* iOS socketpair bypass: check for pre-connected fd from app bridge */
        const char *ios_fd_str = getenv("WINE_IOS_FD_SOCKET");
        if (ios_fd_str)
        {
            fd_socket = atoi(ios_fd_str);
            wine_log_write("[Wine connect] using injected fd_socket=%d (socketpair bypass)", fd_socket);
            /* Still need to set up config dir for registry etc. */
            initial_cwd = setup_config_dir();
        }
        else
        {
            fd_socket = server_connect();
        }
    }

#ifdef WINE_IOS
    wine_log_write("[Wine connect] fd_socket=%d, receiving version fd...", fd_socket);
#endif

    /* setup the signal mask */
    sigemptyset( &server_block_set );
    sigaddset( &server_block_set, SIGALRM );
    sigaddset( &server_block_set, SIGIO );
    sigaddset( &server_block_set, SIGINT );
    sigaddset( &server_block_set, SIGHUP );
    sigaddset( &server_block_set, SIGQUIT );
    sigaddset( &server_block_set, SIGUSR1 );
    sigaddset( &server_block_set, SIGUSR2 );
    sigaddset( &server_block_set, SIGCHLD );
    pthread_sigmask( SIG_BLOCK, &server_block_set, NULL );

    /* receive the first thread request fd on the main socket */
#ifdef WINE_IOS
    wine_log_write("[Wine init_process] waiting for request_fd from wineserver...");
#endif
    data->request_fd = wine_server_receive_fd( &version );
#ifdef WINE_IOS
    wine_log_write("[Wine init_process] got request_fd=%d, version=%d (expected %d)", data->request_fd, version, SERVER_PROTOCOL_VERSION);
    ios_fdt_reg( data->request_fd, FDT_REQUEST_WR, ios_jit_current_peb() );
#endif

#ifdef SO_PASSCRED
    /* now that we hopefully received the server_pid, disable SO_PASSCRED */
    {
        int enable = 0;
        setsockopt( fd_socket, SOL_SOCKET, SO_PASSCRED, &enable, sizeof(enable) );
    }
#endif

    if (version != SERVER_PROTOCOL_VERSION)
        server_protocol_error( "version mismatch %d/%d.\n"
                               "Your %s binary was not upgraded correctly,\n"
                               "or you have an older one somewhere in your PATH.\n"
                               "Or maybe the wrong wineserver is still running?\n",
                               version, SERVER_PROTOCOL_VERSION,
                               (version > SERVER_PROTOCOL_VERSION) ? "wine" : "wineserver" );
#if defined(__linux__) && defined(HAVE_PRCTL)
    /* work around Ubuntu's ptrace breakage */
    if (server_pid != -1) prctl( 0x59616d61 /* PR_SET_PTRACER */, server_pid );
#endif

    /* ignore SIGPIPE so that we get an EPIPE error instead  */
    sig_act.sa_handler = SIG_IGN;
    sig_act.sa_flags   = 0;
    sigemptyset( &sig_act.sa_mask );
    sigaction( SIGPIPE, &sig_act, NULL );

    reply_pipe = init_thread_pipe();
#ifdef WINE_IOS
    wine_log_write("[Wine init_process] reply_pipe=%d, sending init_first_thread...", reply_pipe);
#endif

    SERVER_START_REQ( init_first_thread )
    {
        req->unix_pid    = getpid();
        req->unix_tid    = get_unix_tid();
        req->reply_fd    = reply_pipe;
        req->wait_fd     = data->wait_fd[1];
        req->debug_level = (TRACE_ON(server) != 0);
        wine_server_set_reply( req, supported_machines, sizeof(supported_machines) );
        if (!(ret = wine_server_call( req )))
        {
            obj_handle_t handle;
            pid               = reply->pid;
            tid               = reply->tid;
            peb->SessionId    = reply->session_id;
            info_size         = reply->info_size;
            server_start_time = reply->server_start;
            supported_machines_count = wine_server_reply_size( reply ) / sizeof(*supported_machines);
            if (reply->inproc_device)
            {
                /* ml1058: userspace ntsync (build/madsync). The "device" is a constant
                 * pseudo fd and the server sends nothing for it. */
                inproc_device_fd = 0x6fffffff /* MADSYNC_DEVICE_FD */;
            }
        }
    }
    SERVER_END_REQ;
#ifdef WINE_IOS
    ios_fdt_mark_closed( reply_pipe );   /* expected handoff close (server holds a dup) */
#endif
    close( reply_pipe );

#ifdef WINE_IOS
    wine_log_write("[Wine init_process] init_first_thread ret=%d, pid=%d, tid=%d", ret, pid, tid);
#endif
    if (ret) server_protocol_error( "init_first_thread failed with status %x\n", ret );

    if (!supported_machines_count)
        fatal_error( "'%s' is a 64-bit installation, it cannot be used with a 32-bit wineserver.\n",
                     config_dir );

    native_machine = supported_machines[0];
    if (is_machine_64bit( native_machine ))
    {
        if (arch && !strcmp( arch, "win32" ))
            fatal_error( "WINEARCH set to win32 but '%s' is a 64-bit installation.\n", config_dir );
#ifndef _WIN64
        NtCurrentTeb()->GdiBatchCount = PtrToUlong( (char *)NtCurrentTeb() - teb_offset );
        NtCurrentTeb()->WowTebOffset  = -teb_offset;
        wow_peb = (PEB64 *)((char *)peb - page_size);
#endif
    }
    else
    {
        if (is_win64)
            fatal_error( "'%s' is a 32-bit installation, it cannot support 64-bit applications.\n", config_dir );
        if (arch && (!strcmp( arch, "win64" ) || !strcmp( arch, "wow64" )))
            fatal_error( "WINEARCH set to %s but '%s' is a 32-bit installation.\n", arch, config_dir );
    }

    set_thread_id( NtCurrentTeb(), pid, tid );

#ifdef WINE_IOS
    /* First process only (children use server_init_process_child), so the DOS
     * drive objects are published exactly once, before the shell enumerates. */
    ios_create_drive_symlinks();
    /* ml2102: the opt-in HID controller's registry entries; nothing in XInput mode. */
    ios_hidpad_publish();
#endif

    for (i = 0; i < supported_machines_count; i++)
        if (supported_machines[i] == current_machine) return info_size;

    fatal_error( "wineserver doesn't support the %04x architecture\n", current_machine );
}


#ifdef WINE_IOS
/***********************************************************************
 *           server_init_process_child  (iOS only)
 *
 * Streamlined version of server_init_process for child "processes"
 * that are really threads. Takes the socketfd directly instead of
 * reading WINESERVERSOCKET from the environment.
 */
size_t server_init_process_child( int child_fd_socket )
{
    struct ntdll_thread_data *data = ntdll_get_thread_data();
    obj_handle_t version;
    int ret, reply_pipe;
    size_t info_size;
    DWORD pid, tid;

    /* Register this child's master socket keyed by its PEB (teb->Peb is
     * already the child's — set in wine_ios_child_main before this call).
     * The global fd_socket stays the PARENT's; send_fd/receive_fd/exit
     * resolve per-process via ios_current_fd_socket(). */
    if (fcntl( child_fd_socket, F_SETFD, FD_CLOEXEC ) == -1)
        wine_log_write("[Wine child] WARNING: fcntl FD_CLOEXEC failed on fd %d", child_fd_socket);
    ios_register_proc_socket( ios_jit_current_peb(), child_fd_socket );
    {   /* Madeira child-exit: the child's slot in process_ios.c learns its PEB, so process_exit_wrapper can mark
         * it ended whichever thread ends the process (a child that exits off its boot thread never releases it) */
        extern void ios_child_slot_bind_peb( void *peb );
        ios_child_slot_bind_peb( ios_jit_current_peb() );
    }

    wine_log_write("[Wine child] server_init_process_child: fd_socket=%d (peb=%p)",
                   child_fd_socket, ios_jit_current_peb());

    /* Do NOT set up signal mask — already done by parent (shared process) */
    /* Do NOT call setup_config_dir — already done by parent */

    /* Receive request_fd from wineserver */
    data->request_fd = wine_server_receive_fd( &version );
    wine_log_write("[Wine child] got request_fd=%d, version=%d", data->request_fd, version);
    ios_fdt_reg( data->request_fd, FDT_REQUEST_WR, ios_jit_current_peb() );

    if (version != SERVER_PROTOCOL_VERSION)
        server_protocol_error( "version mismatch %d/%d\n", version, SERVER_PROTOCOL_VERSION );

    reply_pipe = init_thread_pipe();

    SERVER_START_REQ( init_first_thread )
    {
        req->unix_pid    = getpid();
        req->unix_tid    = get_unix_tid();
        req->reply_fd    = reply_pipe;
        req->wait_fd     = data->wait_fd[1];
        req->debug_level = (TRACE_ON(server) != 0);
        wine_server_set_reply( req, supported_machines, sizeof(supported_machines) );
        if (!(ret = wine_server_call( req )))
        {
            obj_handle_t handle;
            pid       = reply->pid;
            tid       = reply->tid;
            info_size = reply->info_size;
            if (reply->inproc_device)
            {
                /* ml1058: nothing was sent, so nothing to receive or close. */
                if (inproc_device_fd < 0) inproc_device_fd = 0x6fffffff /* MADSYNC_DEVICE_FD */;
            }
        }
    }
    SERVER_END_REQ;
#ifdef WINE_IOS
    ios_fdt_mark_closed( reply_pipe );   /* expected handoff close (server holds a dup) */
#endif
    close( reply_pipe );

    wine_log_write("[Wine child] init_first_thread ret=%d, pid=%d, tid=%d, info_size=%zu",
                   ret, pid, tid, info_size);

    if (ret) server_protocol_error( "init_first_thread (child) failed: %x\n", ret );

    set_thread_id( NtCurrentTeb(), pid, tid );

    return info_size;
}
#endif


/***********************************************************************
 *           server_init_process_done
 */
void server_init_process_done(void)
{
    void *teb;
    unsigned int status;
    int suspend;
    FILE_FS_DEVICE_INFORMATION info;
    struct ntdll_thread_data *thread_data = ntdll_get_thread_data();

    /* iOS-Madeira: this runs on the main (game) thread exactly once —
     * capture its TEB for the server_wait frame-anatomy accounting. */
    {
        extern uintptr_t ios_srv_game_teb;
        ios_srv_game_teb = (uintptr_t)NtCurrentTeb();
    }

    /* Opt-in fastsync (wine/dlls/ntdll/unix/sync.c): the handle -> cell cache is
     * shared by every process of this task and keyed by process id, and the server
     * reissues the ids of dead processes, so drop what a dead process with this id
     * left behind. This process owns no handles yet. A no-op while fastsync is off. */
    madeira_fast_flush_pid();

    /* The client half of the directory cache is kept per process id for the same reason
     * (wine/dlls/ntdll/unix/file.c): drop a dead process's listings. */
    {
        extern void madeira_dir_cache_flush_pid(void);
        madeira_dir_cache_flush_pid();
    }

    if (!get_device_info( initial_cwd, &info ) && (info.Characteristics & FILE_REMOVABLE_MEDIA))
        chdir( "/" );
    close( initial_cwd );

#if defined(__APPLE__) && !defined(WINE_IOS)
    send_server_task_port();
#endif

    /* Install signal handlers; this cannot be done earlier, since we cannot
     * send exceptions to the debugger before the create process event that
     * is sent by init_process_done */
    signal_init_process();
    thread_data->syscall_table = KeServiceDescriptorTable;
    thread_data->syscall_trace = TRACE_ON(syscall);

    /* always send the native TEB */
    if (!(teb = NtCurrentTeb64())) teb = NtCurrentTeb();

    /* Signal the parent process to continue */
    SERVER_START_REQ( init_process_done )
    {
        req->teb = wine_server_client_ptr( teb );
        req->peb = NtCurrentTeb64() ? NtCurrentTeb64()->Peb : wine_server_client_ptr( peb );
        status = wine_server_call( req );
        suspend = reply->suspend;
    }
    SERVER_END_REQ;

    assert( !status );
#ifdef WINE_IOS
    /* On iOS, the parent's PE code (CreateProcessInternalW) should call
     * NtResumeThread to unsuspend the child. But since we use thread-based
     * CreateProcess, the resume mechanism may not work correctly.
     * Force suspend=0 so the child proceeds immediately. */
    if (suspend)
    {
        dprintf(STDERR_FILENO, "[Wine init_done] overriding suspend=%d → 0 for iOS\n", suspend);
        suspend = 0;
    }
    {
        extern void *pLdrInitializeThunk;
        extern void *pRtlUserThreadStart;
        extern const SECTION_IMAGE_INFORMATION *ios_cur_image_info(void);
        ERR("signal_start_thread: teb=%p peb=%p TransferAddress=%p suspend=%d\n",
            NtCurrentTeb(), peb, ios_cur_image_info()->TransferAddress, suspend);
        /* Watchdog: suspend thread and sample registers at 2s and 4s */
        {
            pthread_t wine_pthread = pthread_self();
            mach_port_t wine_mach_thread = pthread_mach_thread_np(wine_pthread);
            uint64_t watchdog_teb_addr = (uint64_t)(uintptr_t)NtCurrentTeb();

            void (^sample_thread)(int secs) = ^(int secs) {
                int kill_ret = pthread_kill(wine_pthread, 0);
                wine_log_write("[Wine WATCHDOG %ds] thread alive=%d (0=yes)", secs, kill_ret);

                /* Suspend thread for consistent state reading */
                kern_return_t skr = thread_suspend(wine_mach_thread);
                if (skr != KERN_SUCCESS) {
                    wine_log_write("[Wine WATCHDOG %ds] thread_suspend failed: %d", secs, skr);
                    return;
                }

                arm_thread_state64_t state;
                mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
                kern_return_t kr = thread_get_state(wine_mach_thread, ARM_THREAD_STATE64,
                                                    (thread_state_t)&state, &state_count);
                /* madeira-bcd: resume before logging. wine_log_write allocates and
                 * crosses into Swift (locks); a thread suspended inside malloc or
                 * the log store would never be resumed. The guest-stack reads below
                 * are vm_read_overwrite of memory, which needs no suspend. */
                thread_resume(wine_mach_thread);
                if (kr == KERN_SUCCESS) {
                    wine_log_write("[Wine WATCHDOG %ds] PC=0x%llx LR=0x%llx SP=0x%llx FP=0x%llx",
                        secs,
                        (unsigned long long)arm_thread_state64_get_pc(state),
                        (unsigned long long)arm_thread_state64_get_lr(state),
                        (unsigned long long)arm_thread_state64_get_sp(state),
                        (unsigned long long)arm_thread_state64_get_fp(state));
                    wine_log_write("[Wine WATCHDOG %ds] x0=0x%llx x1=0x%llx x2=0x%llx x3=0x%llx",
                        secs, state.__x[0], state.__x[1], state.__x[2], state.__x[3]);
                    wine_log_write("[Wine WATCHDOG %ds] x8=0x%llx x16=0x%llx x17=0x%llx x18=0x%llx",
                        secs, state.__x[8], state.__x[16], state.__x[17], state.__x[18]);

                    /* Check dispatcher + return-path globals (combined to avoid os_log rate limiting) */
                    wine_log_write("[Wine WATCHDOG %ds] disp: entry_x18=0x%llx dcnt=%llu | ret: x18=0x%llx pc=0x%llx rcnt=%llu",
                        secs, (unsigned long long)g_wine_dispatcher_x18,
                        (unsigned long long)g_wine_dispatcher_count,
                        (unsigned long long)g_wine_return_x18,
                        (unsigned long long)g_wine_return_pc,
                        (unsigned long long)g_wine_return_count);

                    /* Mach handler stats */
                    {
                        extern volatile int64_t ios_exc_x18_fixes;
                        extern volatile int ios_exc_msg_count;
                        wine_log_write("[Wine WATCHDOG %ds] mach: msgs=%d x18_fixes=%lld",
                            secs, ios_exc_msg_count, (long long)ios_exc_x18_fixes);
                    }

                    /* If x18=0, read the syscall frame from memory to check frame->x[18] */
                    if (state.__x[18] == 0) {
                        /* thread_data->syscall_frame is at TEB+0x378.
                         * frame->x[18] is at frame+0x90. */
                        uint64_t teb_addr = watchdog_teb_addr;
                        uint64_t frame_ptr = 0;
                        /* Read syscall_frame pointer from TEB+0x378 */
                        vm_size_t out_size = sizeof(frame_ptr);
                        if (vm_read_overwrite(mach_task_self(), teb_addr + 0x378,
                                              sizeof(frame_ptr), (vm_address_t)&frame_ptr, &out_size) == KERN_SUCCESS) {
                            uint64_t frame_x18 = 0;
                            if (vm_read_overwrite(mach_task_self(), frame_ptr + 0x90,
                                                  sizeof(frame_x18), (vm_address_t)&frame_x18, &out_size) == KERN_SUCCESS) {
                                wine_log_write("[Wine WATCHDOG %ds] x18=0 but frame->x[18]=0x%llx (frame=%p)",
                                    secs, (unsigned long long)frame_x18, (void*)frame_ptr);
                            }
                        }
                    }
                    /* madeira-bcd: WHERE IN THE GUEST it waits. A thread parked in a
                     * syscall (NtWaitForAlertByThreadId under a lock, build 229: God of
                     * War inside LdrLoadDll) has its PE caller in the syscall frame
                     * (TEB+0x378; x29 at +0xe8, lr +0xf0, sp +0xf8, pc +0x100). Walk
                     * that frame chain and scan the guest stack for return addresses,
                     * each mapped from the JIT pool copy back to module+offset. */
                    {
                        extern uint64_t ios_jit_reverse_translate( uint64_t addr, uint64_t *module_base );
                        extern const char *ios_pe_module_name_ext( uint64_t base );
                        uint64_t frame_ptr = 0, regs[4] = { 0, 0, 0, 0 };
                        vm_size_t got = 0;
                        if (vm_read_overwrite(mach_task_self(), watchdog_teb_addr + 0x378, sizeof(frame_ptr),
                                              (vm_address_t)&frame_ptr, &got) == KERN_SUCCESS && frame_ptr &&
                            vm_read_overwrite(mach_task_self(), frame_ptr + 0xe8, sizeof(regs),
                                              (vm_address_t)regs, &got) == KERN_SUCCESS)
                        {
                            uint64_t fp = regs[0], sp = regs[2];
                            int n;
                            const uint64_t pcs[2] = { regs[3], regs[1] };
                            for (n = 0; n < 2; n++)
                            {
                                uint64_t mod = 0, va = ios_jit_reverse_translate( pcs[n], &mod );
                                wine_log_write("[guest-stk] %s 0x%llx = %s+0x%llx", n ? "lr" : "pc",
                                    (unsigned long long)pcs[n], va && mod ? ios_pe_module_name_ext( mod ) : "?",
                                    (unsigned long long)(va && mod ? va - mod : 0));
                            }
                            for (n = 0; n < 24 && fp > 0x10000; n++)
                            {
                                uint64_t rec[2] = { 0, 0 }, mod = 0, va;
                                if (vm_read_overwrite(mach_task_self(), fp, sizeof(rec), (vm_address_t)rec, &got) != KERN_SUCCESS)
                                    break;
                                va = ios_jit_reverse_translate( rec[1], &mod );
                                wine_log_write("[guest-stk] fp#%d 0x%llx = %s+0x%llx", n, (unsigned long long)rec[1],
                                    va && mod ? ios_pe_module_name_ext( mod ) : "?",
                                    (unsigned long long)(va && mod ? va - mod : 0));
                                if (rec[0] <= fp) break;
                                fp = rec[0];
                            }
                            for (n = 0; n < 1024 && sp; n++)
                            {
                                static int hits;
                                uint64_t slot = 0, mod = 0, va;
                                if (vm_read_overwrite(mach_task_self(), sp + 8ull * n, 8, (vm_address_t)&slot, &got) != KERN_SUCCESS)
                                    break;
                                if ((va = ios_jit_reverse_translate( slot, &mod )) && mod && va != slot && hits++ < 48)
                                    wine_log_write("[guest-stk] sp+0x%x 0x%llx = %s+0x%llx", n * 8, (unsigned long long)slot,
                                        ios_pe_module_name_ext( mod ), (unsigned long long)(va - mod));
                            }
                        }
                    }
                } else {
                    wine_log_write("[Wine WATCHDOG %ds] thread_get_state failed: %d", secs, kr);
                }
            };

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ sample_thread(2); });
        }

        /* iOS-Madeira 2026-07-03 sampling profiler for the 30 FPS hunt.
         * Every prior frame-cost theory (L1 misses, drawable stalls, DXMT
         * encode) was eliminated by measurement; this samples the game
         * thread's PC at ~500Hz forever and prints a 256-byte-bucket
         * histogram every 4096 samples (~10s). Buckets land in one of:
         * JIT pool (guest blocks / dispatcher / module copies), app binary
         * (unix side), or elsewhere — mapping the hot buckets tells us
         * where the ~1.4s/frame actually goes. Counts halve at each print
         * so the histogram tracks the current phase. */
        /* ml875 [thread-sample]: ONE task-wide sampler (ml873 armed seven, one
         * per pseudo-process, each suspending the others' threads). Body in
         * ios_thread_sampler_main() above. */
        if (__sync_bool_compare_and_swap(&ios_ts_armed, 0, 1))
        {
            /* Madeira: MADEIRA_PROBES picks which always-on profilers start,
             * for timing runs: unset/1 = all (as before); "light" = only the
             * xprobe ([xp]/[xp-t]/[xp-api], counters read 4x a second, no thread
             * is ever suspended); 0 = none. The thread sampler suspends every
             * thread 4x per 20 s and the guest RIP profile suspends the game's
             * threads 200x in a second after that -- cheap, but not free on a
             * device whose efficiency cores are saturated (a heavy game at 1080p). */
            const char *probes_env = getenv("MADEIRA_PROBES");
            int probes = !probes_env || !*probes_env ? 2 : !strcmp(probes_env, "0") ? 0 : !strcmp(probes_env, "light") ? 1 : 2;
            /* 1: no thread-suspending samplers ([thread-sample], [rip-profile], [cpu-split], [wprof]) and rare memory walks; [xp] unchanged */
            const char *lean_env = getenv("MADEIRA_LEAN_DIAG");
            /* 1: a [power] line every 5 s (coalition GPU energy, IOReport, battery) and [power-t] (energy per thread) */
            const char *probe_env = getenv("MADEIRA_POWER_PROBE");
            ios_lean_diag = lean_env && *lean_env && strcmp(lean_env, "0") != 0;
            ios_power_probe_on = probe_env && *probe_env && strcmp(probe_env, "0") != 0;
            if (probes < 2)
                wine_log_write("[probes] MADEIRA_PROBES=%s: thread sampler, guest RIP profile and W-thread profiler off%s",
                               probes_env, probes ? "; [xp] counters stay" : "; [xp] counters off too");
            if (ios_lean_diag)
                wine_log_write("[lean-diag] madeira-bcd MADEIRA_LEAN_DIAG=%s: [thread-sample] bursts, guest RIP profile ([rip-profile], "
                               "[cpu-split]) and [wprof] off; [sync-census] every 20 s and [xp]/[xp-t]/[xp-api] every 250 ms / 1 s as "
                               "before; the warmer's memory walks every ~10 min", lean_env);
            ios_frame_stats_arm();   /* [frame]: off unless MADEIRA_FRAME_STATS is set */
            if (probes >= 2) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ ios_thread_sampler_main(); });
            if (probes >= 1) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ ios_xprobe_main(); });   /* ml1128 */
            if (probes >= 2 && !ios_lean_diag) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ ios_wprof_main(); });   /* ml1129 */
        }
        if (!getenv("MADEIRA_QUIET"))
        {
            /* iOS-Madeira 2026-07-05 quiet mode: the sampler thread_suspends
             * the game thread ~500x/s (each suspend+get_state+resume steals
             * wall time and adds jitter) — a few %% of frame time plus heat,
             * and heat is what caps ProMotion at 60. MADEIRA_QUIET (set in
             * WineProcessBridge.m) skips the profiler entirely; comment the
             * setenv out for diagnostic sessions. */
            pthread_t prof_pthread = pthread_self();
            mach_port_t prof_thread_initial = pthread_mach_thread_np(prof_pthread);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                /* Follow the game thread: the Mach handler records the last
                 * thread that took a PE-VA exec fault (= made a native call)
                 * in ios_last_exec_fault_thread. The first Wine thread we
                 * originally pinned dies ~33s in, which froze [PROF] before
                 * the menu phase. Re-read every iteration so the profile
                 * tracks whichever thread is actually driving frames. */
                extern volatile mach_port_t ios_last_exec_fault_thread;
                enum { PROF_SLOTS = 512 };
                static uint64_t prof_keys[PROF_SLOTS];
                static uint32_t prof_counts[PROF_SLOTS];
                /* v4: follow the BUSIEST thread (max cpu_usage), re-chosen
                 * every ~2s. The last-exec-faulter heuristic kept landing on
                 * the WAITING main thread; the render worker that actually
                 * burns the 53ms frame barely faults since the USD fix. */
                mach_port_t prof_self = pthread_mach_thread_np(pthread_self());
                mach_port_t prof_held = MACH_PORT_NULL;
                integer_t prof_cpu = 0;
                uint64_t prof_iter = 0;
                /* Secondary histogram: LR of samples whose PC is in the
                 * dyld-shared-cache range. [PROF] showed ~87% of gameplay
                 * time in ONE system-dylib bucket (a wait syscall) — the
                 * LR names the Wine call site, symbolizable with atos
                 * against the app binary. */
                static uint64_t prof_lr_keys[PROF_SLOTS];
                static uint32_t prof_lr_counts[PROF_SLOTS];
                uint64_t total = 0;
                mach_port_t prof_thread = prof_thread_initial;
                /* Task #25 [susp]: whole-task suspension detector. Three
                 * desktop "freezes" showed a ~53.7s stall where even the 2s
                 * watchdog missed ticks — consistent with the DEBUGGER
                 * suspending the task (StikDebug death/timeout), not a wedge.
                 * A 2ms sleep that takes >3s = the task was stopped; log the
                 * exact wall gap so freeze reports self-diagnose. */
                uint64_t susp_last_ns = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
                for (;;) {
                    usleep(2000);
                    {
                        uint64_t now_ns = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
                        if (now_ns - susp_last_ns > 3000000000ull)
                            wine_log_write("[susp] TASK WAS SUSPENDED/STALLED for %.1fs (2ms sleep gap)",
                                           (now_ns - susp_last_ns) / 1e9);
                        susp_last_ns = now_ns;
                    }
                    if ((prof_iter++ & 0x3FF) == 0) {
                        thread_act_array_t tlist;
                        mach_msg_type_number_t tcount;
                        if (task_threads(mach_task_self(), &tlist, &tcount) == KERN_SUCCESS) {
                            integer_t best_cpu = -1;
                            mach_port_t best = MACH_PORT_NULL;
                            unsigned int k;
                            for (k = 0; k < tcount; k++) {
                                thread_basic_info_data_t bi;
                                mach_msg_type_number_t bic = THREAD_BASIC_INFO_COUNT;
                                if (tlist[k] == prof_self) continue;
                                if (thread_info(tlist[k], THREAD_BASIC_INFO,
                                                (thread_info_t)&bi, &bic) != KERN_SUCCESS) continue;
                                if (bi.cpu_usage > best_cpu) { best_cpu = bi.cpu_usage; best = tlist[k]; }
                            }
                            for (k = 0; k < tcount; k++)
                                if (tlist[k] != best) mach_port_deallocate(mach_task_self(), tlist[k]);
                            if (best != MACH_PORT_NULL) {
                                if (prof_held != MACH_PORT_NULL && prof_held != best)
                                    mach_port_deallocate(mach_task_self(), prof_held);
                                prof_held = best;
                                prof_thread = best;
                                prof_cpu = best_cpu;
                            }
                            vm_deallocate(mach_task_self(), (vm_address_t)tlist,
                                          tcount * sizeof(*tlist));
                        }
                    }
                    if (thread_suspend(prof_thread) != KERN_SUCCESS) { usleep(200000); continue; }
                    arm_thread_state64_t st;
                    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
                    kern_return_t kr = thread_get_state(prof_thread, ARM_THREAD_STATE64,
                                                        (thread_state_t)&st, &cnt);
                    thread_resume(prof_thread);
                    if (kr != KERN_SUCCESS) continue;
                    uint64_t pc_full = arm_thread_state64_get_pc(st);
                    uint64_t key = pc_full >> 8;
                    int i, free_i = -1;
                    for (i = 0; i < PROF_SLOTS; i++) {
                        if (prof_counts[i] && prof_keys[i] == key) { prof_counts[i]++; break; }
                        if (!prof_counts[i] && free_i < 0) free_i = i;
                    }
                    if (i == PROF_SLOTS && free_i >= 0) { prof_keys[free_i] = key; prof_counts[free_i] = 1; }
                    /* v4.1: capture LR for ALL samples — pool-resident hot
                     * functions (memset, virtual_unwind in ntdll's copy)
                     * need their CALLERS named to attribute the unwind
                     * storm, not just system-range wait syscalls. */
                    {
                        uint64_t lr_key = arm_thread_state64_get_lr(st) >> 4;
                        for (i = 0; i < PROF_SLOTS; i++) {
                            if (prof_lr_counts[i] && prof_lr_keys[i] == lr_key) { prof_lr_counts[i]++; break; }
                            if (!prof_lr_counts[i]) { prof_lr_keys[i] = lr_key; prof_lr_counts[i] = 1; break; }
                        }
                    }
                    total++;
                    /* v5: coherent fp-chain walk of the profiled thread every
                     * ~2s. pc+lr can't attribute kernel time (lr lands inside
                     * libsystem_kernel wrappers like mach_vm_map+0x6c); the fp
                     * chain, walked while the thread is SUSPENDED, names the
                     * real caller. Guest FEX frames don't keep fp chains —
                     * bounded garbage, validity-checked. */
                    if ((total % 1024) == 0) {
                        arm_thread_state64_t bst;
                        mach_msg_type_number_t bcnt = ARM_THREAD_STATE64_COUNT;
                        if (thread_suspend(prof_thread) == KERN_SUCCESS) {
                            uint64_t pcs[12];
                            int nf = 0;
                            if (thread_get_state(prof_thread, ARM_THREAD_STATE64,
                                                 (thread_state_t)&bst, &bcnt) == KERN_SUCCESS) {
                                uint64_t fp_w = arm_thread_state64_get_fp(bst);
                                pcs[nf++] = arm_thread_state64_get_pc(bst);
                                pcs[nf++] = arm_thread_state64_get_lr(bst);
                                while (nf < 12 && fp_w > 0x1000) {
                                    uint64_t fb[2]; mach_vm_size_t got = 0;
                                    if (mach_vm_read_overwrite(mach_task_self(),
                                            (mach_vm_address_t)fp_w, 16,
                                            (mach_vm_address_t)fb, &got) != KERN_SUCCESS
                                        || got != 16)
                                        break;
                                    if (fb[1] < 0x4000) break;
                                    pcs[nf++] = fb[1];
                                    if (fb[0] <= fp_w) break; /* fp must move up-stack */
                                    fp_w = fb[0];
                                }
                            }
                            thread_resume(prof_thread);
                            if (nf) {
                                char bl[640]; int bln = 0;
                                int f;
                                bln += snprintf(bl+bln, sizeof(bl)-bln,
                                                "[PROF-BT] tid=0x%x:", prof_thread);
                                for (f = 0; f < nf && bln < (int)sizeof(bl)-90; f++) {
                                    Dl_info bi2;
                                    if (dladdr((void*)(uintptr_t)pcs[f], &bi2) && bi2.dli_sname)
                                        bln += snprintf(bl+bln, sizeof(bl)-bln, " %s+0x%llx",
                                                        bi2.dli_sname,
                                                        (unsigned long long)(pcs[f]-(uintptr_t)bi2.dli_saddr));
                                    else
                                        bln += snprintf(bl+bln, sizeof(bl)-bln, " 0x%llx",
                                                        (unsigned long long)pcs[f]);
                                }
                                dprintf(STDERR_FILENO, "%s\n", bl);
                            }
                        }
                    }
                    if ((total % 4096) == 0) {
                        /* top-10 by count (simple selection; 512 slots) */
                        char line[512]; int len = 0;
                        len += snprintf(line + len, sizeof(line) - len, "[PROF] tid=0x%x cpu=%d n=%llu top:",
                                        prof_thread, (int)prof_cpu, (unsigned long long)total);
                        for (int rank = 0; rank < 10 && len < (int)sizeof(line) - 40; rank++) {
                            int best = -1; uint32_t bc = 0;
                            for (i = 0; i < PROF_SLOTS; i++)
                                if (prof_counts[i] > bc) { bc = prof_counts[i]; best = i; }
                            if (best < 0 || bc == 0) break;
                            len += snprintf(line + len, sizeof(line) - len, " 0x%llx00*%u",
                                            (unsigned long long)prof_keys[best], bc);
                            prof_counts[best] = 0; /* consumed; decay below repopulates */
                        }
                        dprintf(STDERR_FILENO, "%s\n", line);
                        for (i = 0; i < PROF_SLOTS; i++) prof_counts[i] >>= 1;

                        /* top-8 wait-callers (LR of system-range samples),
                         * self-symbolized via dladdr (works for dyld-cache
                         * addresses; app-dylib statics resolve to nearest
                         * exported symbol — cross-check offline with atos). */
                        len = 0;
                        len += snprintf(line + len, sizeof(line) - len, "[PROF-LR] top:");
                        for (int rank = 0; rank < 8 && len < (int)sizeof(line) - 100; rank++) {
                            int best = -1; uint32_t bc = 0;
                            Dl_info info;
                            uint64_t addr;
                            for (i = 0; i < PROF_SLOTS; i++)
                                if (prof_lr_counts[i] > bc) { bc = prof_lr_counts[i]; best = i; }
                            if (best < 0 || bc == 0) break;
                            addr = prof_lr_keys[best] << 4;
                            if (rank < 3 && dladdr((void *)(uintptr_t)addr, &info) && info.dli_sname)
                                len += snprintf(line + len, sizeof(line) - len, " 0x%llx(%s+0x%llx)*%u",
                                                (unsigned long long)addr, info.dli_sname,
                                                (unsigned long long)(addr - (uintptr_t)info.dli_saddr), bc);
                            else
                                len += snprintf(line + len, sizeof(line) - len, " 0x%llx*%u",
                                                (unsigned long long)addr, bc);
                            prof_lr_counts[best] = 0;
                        }
                        dprintf(STDERR_FILENO, "%s\n", line);
                        for (i = 0; i < PROF_SLOTS; i++) prof_lr_counts[i] >>= 1;
                    }
                }
            });
        }
    }
#endif
    {
        /* Owner-aware (X3): a child's first thread must start at the CHILD
         * exe's entry — main_image_info is restored to the session's exe
         * right after child startup-info init (see wine_ios_child_main). */
        extern const SECTION_IMAGE_INFORMATION *ios_cur_image_info(void);
        extern void *ios_subfloor_low_entry( void *entry, ULONG image_charact );
        extern void ios_child_boot_unlock( void );
        ios_child_boot_unlock();   /* ml1213: the child's unix boot is done */
        signal_start_thread( ios_subfloor_low_entry( ios_cur_image_info()->TransferAddress,
                                                     ios_cur_image_info()->ImageCharacteristics ),
                             peb, suspend, NtCurrentTeb() );
    }
}


/***********************************************************************
 *           server_init_thread
 *
 * Send an init thread request.
 */
void server_init_thread( void *entry_point, BOOL *suspend )
{
    void *teb;
    int reply_pipe = init_thread_pipe();

    /* always send the native TEB */
    if (!(teb = NtCurrentTeb64())) teb = NtCurrentTeb();

    SERVER_START_REQ( init_thread )
    {
        req->unix_tid  = get_unix_tid();
        req->teb       = wine_server_client_ptr( teb );
        req->entry     = wine_server_client_ptr( entry_point );
        req->reply_fd  = reply_pipe;
        req->wait_fd   = ntdll_get_thread_data()->wait_fd[1];
        wine_server_call( req );
        *suspend = reply->suspend;
    }
    SERVER_END_REQ;
#ifdef WINE_IOS
    ios_fdt_mark_closed( reply_pipe );   /* expected handoff close (server holds a dup) */
#endif
    close( reply_pipe );
}

NTSTATUS WINAPI NtAllocateReserveObject( HANDLE *handle, const OBJECT_ATTRIBUTES *attr,
                                         MEMORY_RESERVE_OBJECT_TYPE type )
{
    struct object_attributes *objattr;
    unsigned int ret;
    data_size_t len;

    TRACE("(%p, %p, %d)\n", handle, attr, type);

    *handle = 0;
    if ((ret = alloc_object_attributes( attr, &objattr, &len ))) return ret;

    SERVER_START_REQ( allocate_reserve_object )
    {
        req->type = type;
        wine_server_add_data( req, objattr, len );
        if (!(ret = wine_server_call( req )))
            *handle = wine_server_ptr_handle( reply->handle );
    }
    SERVER_END_REQ;

    free( objattr );
    return ret;
}


/******************************************************************************
 *           NtDuplicateObject
 */
NTSTATUS WINAPI NtDuplicateObject( HANDLE source_process, HANDLE source, HANDLE dest_process, HANDLE *dest,
                                   ACCESS_MASK access, ULONG attributes, ULONG options )
{
    sigset_t sigset;
    unsigned int ret;
    int fd = -1;

    if (dest) *dest = 0;

    if ((options & DUPLICATE_CLOSE_SOURCE) && source_process != NtCurrentProcess())
    {
        union apc_call call;
        union apc_result result;

        memset( &call, 0, sizeof(call) );

        call.dup_handle.type        = APC_DUP_HANDLE;
        call.dup_handle.src_handle  = wine_server_obj_handle( source );
        call.dup_handle.dst_process = wine_server_obj_handle( dest_process );
        call.dup_handle.access      = access;
        call.dup_handle.attributes  = attributes;
        call.dup_handle.options     = options;
        ret = server_queue_process_apc( source_process, &call, &result );
        if (ret != STATUS_SUCCESS) return ret;

        if (!result.dup_handle.status)
            *dest = wine_server_ptr_handle( result.dup_handle.handle );
        return result.dup_handle.status;
    }

    /* hold fd_cache_mutex to prevent the fd from being added again between the
     * call to remove_fd_from_cache and close_handle */
    server_enter_uninterrupted_section( &fd_cache_mutex, &sigset );

    /* always remove the cached fd; if the server request fails we'll just
     * retrieve it again */
    if (options & DUPLICATE_CLOSE_SOURCE)
    {
        fd = remove_fd_from_cache( source );
        close_inproc_sync( source );
    }

    SERVER_START_REQ( dup_handle )
    {
        req->src_process = wine_server_obj_handle( source_process );
        req->src_handle  = wine_server_obj_handle( source );
        req->dst_process = wine_server_obj_handle( dest_process );
        req->access      = access;
        req->attributes  = attributes;
        req->options     = options;
        if (!(ret = wine_server_call( req )))
        {
            if (dest) *dest = wine_server_ptr_handle( reply->handle );
        }
    }
    SERVER_END_REQ;

    server_leave_uninterrupted_section( &fd_cache_mutex, &sigset );

    if (fd != -1) close( fd );
    return ret;
}


/**************************************************************************
 *           NtCompareObjects   (NTDLL.@)
 */
NTSTATUS WINAPI NtCompareObjects( HANDLE first, HANDLE second )
{
    unsigned int status;

    SERVER_START_REQ( compare_objects )
    {
        req->first = wine_server_obj_handle( first );
        req->second = wine_server_obj_handle( second );
        status = wine_server_call( req );
    }
    SERVER_END_REQ;

    return status;
}


/**************************************************************************
 *           NtCompareTokens   (NTDLL.@)
 */
NTSTATUS WINAPI NtCompareTokens( HANDLE first, HANDLE second, BOOLEAN *equal )
{
    FIXME( "%p,%p,%p: stub\n", first, second, equal );
    return STATUS_NOT_IMPLEMENTED;
}


/**************************************************************************
 *           NtClose
 */
NTSTATUS WINAPI NtClose( HANDLE handle )
{
    sigset_t sigset;
    HANDLE port;
    unsigned int ret;
    int fd;

    if (HandleToLong( handle ) >= ~5 && HandleToLong( handle ) <= ~0)
        return STATUS_SUCCESS;

    /* hold fd_cache_mutex to prevent the fd from being added again between the
     * call to remove_fd_from_cache and close_handle */
    server_enter_uninterrupted_section( &fd_cache_mutex, &sigset );

    /* always remove the cached fd; if the server request fails we'll just
     * retrieve it again */
    fd = remove_fd_from_cache( handle );
    close_inproc_sync( handle );

    SERVER_START_REQ( close_handle )
    {
        req->handle = wine_server_obj_handle( handle );
        ret = wine_server_call( req );
    }
    SERVER_END_REQ;

    server_leave_uninterrupted_section( &fd_cache_mutex, &sigset );

    if (fd != -1) close( fd );

    if (ret != STATUS_INVALID_HANDLE || !handle) return ret;

#ifdef WINE_IOS
    /* iOS-Madeira ml669: [bad-close] — Book of the Dead died on an UNHANDLED
     * c0000008 (STATUS_INVALID_HANDLE) at KiRaiseUserExceptionDispatcher, and
     * this is the only path that reaches that dispatcher.
     *
     * Note what gates it: an invalid NtClose is normally a RETURNED status and
     * nothing more. It only becomes a raised, process-killing exception when the
     * guest believes a debugger is attached (BeingDebugged + a non-zero
     * ProcessDebugPort) -- that is Windows' "let the debugger see the bad close"
     * behaviour. We run under StikDebug, so if we report either of those as true
     * when no WINDOWS debugger is present, we convert every harmless double-close
     * in every app into a fatal exception. That would be our bug, not the game's.
     *
     * Log both halves before deciding: the handle and whether the fd cache ever
     * knew it (double-close vs never-valid), and the debug state that decides
     * whether it is fatal. Deliberately does NOT suppress the raise -- doing that
     * now would hide whichever of the two defects this turns out to be. */
    {
        static int bad_close_n;
        if (bad_close_n < 32)
        {
            ULONG_PTR dbg_port = 0;
            NTSTATUS qs = NtQueryInformationProcess( NtCurrentProcess(), ProcessDebugPort,
                                                     &dbg_port, sizeof(dbg_port), NULL );
            dprintf( 2, "[bad-close] ml669 #%d handle=%p fd_was_cached=%d BeingDebugged=%d "
                     "ProcessDebugPort=%p (q=%08x) => %s\n",
                     ++bad_close_n, handle, fd != -1, (int)peb->BeingDebugged,
                     (void *)dbg_port, (unsigned int)qs,
                     (peb->BeingDebugged && !qs && dbg_port) ? "WILL RAISE (fatal)" : "returns status" );
        }
    }
#endif

    if (!peb->BeingDebugged) return ret;
    if (!NtQueryInformationProcess( NtCurrentProcess(), ProcessDebugPort, &port, sizeof(port), NULL) && port)
    {
        NtCurrentTeb()->ExceptionCode = ret;
        call_raise_user_exception_dispatcher();
    }
    return ret;
}

#ifdef _WIN64

struct __server_request_info32
{
    union
    {
        union generic_request req;
        union generic_reply   reply;
    } u;
    unsigned int            data_count;
    ULONG                   reply_data;
    struct { ULONG ptr; data_size_t size; } data[__SERVER_MAX_DATA];
};

/**********************************************************************
 *		wow64_wine_server_call
 */
NTSTATUS wow64_wine_server_call( void *args )
{
    struct __server_request_info32 *req32 = args;
    unsigned int i;
    NTSTATUS status;
    struct __server_request_info req;

    /* the WoW64 module converted the OUTER args pointer
     * only, so req32 is a host pointer but every pointer INSIDE it is still a
     * guest address — the request's own iov data blocks and the reply buffer
     * live in the 32-bit caller's window.  ios_wow_host_ptr() is +B and
     * NULL-preserving (a NULL iov entry stays NULL). */
    req.u.req = req32->u.req;
    req.data_count = req32->data_count;
    for (i = 0; i < req.data_count; i++)
    {
        req.data[i].ptr = ios_wow_host_ptr( req32->data[i].ptr );
        req.data[i].size = req32->data[i].size;
    }
    req.reply_data = ios_wow_host_ptr( req32->reply_data );
    status = wine_server_call( &req );
    req32->u.reply = req.u.reply;
    /* NOTE: req.u.req is copied verbatim.  client_ptr_t members inside the
     * request union that a 32-bit caller filled in are guest addresses and are
     * NOT converted here.  No request made through this entry point by the
     * 32-bit ntdll (debug output, file I/O, handle/console requests) carries
     * one. */
    return status;
}

/***********************************************************************
 *		wow64_wine_server_fd_to_handle
 */
NTSTATUS wow64_wine_server_fd_to_handle( void *args )
{
    struct
    {
        int          fd;
        unsigned int access;
        unsigned int attributes;
        ULONG        handle;
    } const *params32 = args;

    /* embedded guest pointer: the caller's output slot */
    ULONG *handle32 = ios_wow_host_ptr( params32->handle );
    HANDLE handle;
    NTSTATUS ret;

    ret = wine_server_fd_to_handle( params32->fd, params32->access, params32->attributes, &handle );
    *handle32 = HandleToULong( handle );
    return ret;
}

/**********************************************************************
 *           wow64_wine_server_handle_to_fd
 */
NTSTATUS wow64_wine_server_handle_to_fd( void *args )
{
    struct
    {
        ULONG        handle;
        unsigned int access;
        ULONG        unix_fd;
        ULONG        options;
    } const *params32 = args;

    /* handle stays a handle; unix_fd and options are embedded guest pointers
     * to the caller's output slots */
    return wine_server_handle_to_fd( ULongToHandle( params32->handle ), params32->access,
                                     ios_wow_host_ptr( params32->unix_fd ),
                                     ios_wow_host_ptr( params32->options ));
}

#endif /* _WIN64 */
