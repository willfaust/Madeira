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

extern void *ios_jit_current_peb(void);

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
 * dies (they skip their self-terminate and the server never hears). */
BOOL *ios_process_exiting_ptr(void)
{
    int i = ios_proc_socket_index();
    return (i >= 0) ? &ios_proc_sockets[i].exiting : &process_exiting;
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
                           ios_fdt_names[kind], (unsigned int)GetCurrentThreadId(), peb);
    }
    e->kind = (unsigned char)kind;
    e->prev_kind = 0;
    e->tid  = (unsigned int)GetCurrentThreadId();
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
                       e->tid, e->peb, e->gen, (unsigned int)GetCurrentThreadId(), dead_peb);
        e->prev_kind = e->kind;
        e->kind = FDT_CLOSED;
    }
    else
        wine_log_write("[fdtrace] close fd=%d why=%s untracked%s closer_tid=%04x dead_peb=%p rev=ml586",
                       fd, why, (e->kind == FDT_CLOSED) ? " (prev comm fd)" : "",
                       (unsigned int)GetCurrentThreadId(), dead_peb);
}

/* victim autopsy: what the ledger knows about a failing comm fd */
static void ios_fdt_autopsy( const char *what, int fd, int ret, int err )
{
    struct ios_fdt_ent *e = (fd >= 0 && fd < IOS_FDT_MAX) ? &ios_fdt[fd] : NULL;
    wine_log_write("[fdtrace] VICTIM %s tid=%04x fd=%d ret=%d errno=%d ledger=%s owner_tid=%04x owner_peb=%p gen=%u prev=%s rev=ml586",
                   what, (unsigned int)GetCurrentThreadId(), fd, ret, err,
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
    __sync_synchronize();
    ios_proc_sockets[idx].peb = peb_id;
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

    if (errno == EPIPE) abort_thread(0);
    if (errno == EFAULT) return STATUS_ACCESS_VIOLATION;
    server_protocol_perror( "write" );
}


/***********************************************************************
 *           read_reply_data
 *
 * Read data from the reply buffer; helper for wait_reply.
 */
static void read_reply_data( void *buffer, size_t size )
{
    int ret;

    for (;;)
    {
        if ((ret = read( ntdll_get_thread_data()->reply_fd, buffer, size )) > 0)
        {
            if (!(size -= ret)) return;
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
#endif
    /* the server closed the connection; time to die... */
    abort_thread(0);
}


/***********************************************************************
 *           wait_reply
 *
 * Wait for a reply from the server.
 */
static inline unsigned int wait_reply( struct __server_request_info *req )
{
    read_reply_data( &req->u.reply, sizeof(req->u.reply) );
    if (req->u.reply.reply_header.reply_size)
        read_reply_data( req->reply_data, req->u.reply.reply_header.reply_size );
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
            if (tl[k] == self_port) continue;
            if (thread_suspend( tl[k] ) != KERN_SUCCESS) continue;
            /* ml981: a guest thread is one whose frame yields a plausible RIP at
             * x28+0x18 -- the same test the sampling loop uses, so a thread can
             * never be selected here and then fail to resolve below. */
            if (thread_get_state( tl[k], ARM_THREAD_STATE64, (thread_state_t)&st, &cnt ) == KERN_SUCCESS
                && ios_ts_read( st.__x[28] + 0x18, &bb, 8 )
                && bb > 0x10000 && bb < 0x8000000000ull
                && ios_ts_teb( pthread_from_mach_thread_np( tl[k] ) ))   /* ml1116: a Wine thread (has a TEB); native threads passed the x28 test by accident */
            {
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
        for (i = 0; i < nrb && i < 6; i++) {
            unsigned char code[80]; int k;
            if (rb[i].base < 0x140000000ull || rb[i].base >= 0x148000000ull) continue;
            if (!ios_ts_read( rb[i].base, code, sizeof(code) )) continue;
            for (k = 0; k + 6 <= 64; k++) {
                if (code[k] == 0xff && code[k + 1] == 0x15) {
                    int32_t disp; uint64_t slot, target = 0;
                    memcpy( &disp, code + k + 2, 4 );
                    slot = rb[i].base + k + 6 + (int64_t)disp;
                    ios_ts_read( slot, &target, 8 );
                    wine_log_write( "[rip-profile] ml1112 bucket %#llx: call [%#llx] -> %#llx (%u%% of running)",
                                    (unsigned long long)rb[i].base, (unsigned long long)slot, (unsigned long long)target, rtotal ? (rb[i].n * 100) / rtotal : 0 );
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
                                r->p_ghz = pt > 0 ? pcy / (pt * 1e6) : 0; r->e_ghz = et > 0 ? ecy / (et * 1e6) : 0;
                                r->minst = (double)((cur[0].instr - pv->c[0].instr) + (cur[1].instr - pv->c[1].instr)) / 1e6;
                                r->role = NULL;
                                for (i = 0; i < ios_xp_nroles; i++) if (ios_xp_roles[i].tid == idi.thread_id) { r->role = ios_xp_roles[i].role; break; }
                                if (r->role && teb && (strchr( r->role, 'P' ) || strchr( r->role, 'E' ))) ios_xp_game_teb = teb;   /* ml1131 */
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
            gettimeofday( &tv, NULL ); localtime_r( &tv.tv_sec, &tmv );
            snprintf( wall, sizeof(wall), "%02d:%02d:%02d.%03d", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000) );
            n = snprintf( line, sizeof(line),
                          "[xp] %s +%.2f dt=%.0f cpu=%.0f (thr %.0f) P=%.0f E=%.0f run=%.0f pgw=%.1f GHz P=%.2f E=%.2f Minst=%.0f IPC=%.2f mJ=%.0f pin=%llu rdKB=%llu fpMB=%llu",
                          wall, XP_MS( now - t_start ) / 1000.0, dt_ms, cpu, sum_thr_ms, pms, ems,
                          XP_MS( ru.ri_runnable_time - pru.ri_runnable_time ),
                          0.0 /* pgw: the xtool SDK's rusage_info_v6 has no ri_page_wait_time_mach */,
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
    uintptr_t rx0 = (uintptr_t)ios_jit_rx_base_global, pe = 0; uint64_t rva = 0; const char *mod;
    Dl_info di;
    *kind = 0;
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

static void ios_thread_sampler_main(void)
{
    int gen = 0;
    ios_ts_calibrate();
    wine_log_write("[thread-sample] ml876 armed (task-wide: burst of 4 passes / 250 ms every 20 s)");
    for (;;) {
        int b;
        sleep(20);
        for (b = 0; b < 4; b++) { ios_thread_sampler_pass(b); usleep(250000); }
        wine_log_write("[thread-sample] ml876 burst done");
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
        ++gen; ios_guest_rip_profile( gen );   /* ml1123: every burst (was every third) */
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

/***********************************************************************
 *           [frame]  —  the frame critical-path breakdown (ml1050)
 *
 * Design, cost and the list of things it deliberately cannot see:
 * build/ntdll-unix/shims/ios_frame_stats.h.  This is the storage, the
 * accumulators and the reporter; the producers are winemetal_unix.c (present,
 * drawable, GPU) and wine/dlls/ntdll/unix/sync.c (the waits).
 */
#include "ios_frame_stats.h"
#include <mach/mach_time.h>

int ios_frame_stats_on = 1;               /* MADEIRA_FRAME_STATS=0 */
unsigned long long ios_frame_role_tid[IOS_FRAME_ROLE_MAX];

struct ios_frame_acc
{
    /* presenting thread, closed once per Present */
    unsigned long long frames;
    unsigned long long wall_ns;
    unsigned long long cpu_ns;
    unsigned long long wall_max_ns;
    unsigned long long wait_ns[IOS_FRAME_WAIT_MAX];
    /* encode thread */
    unsigned long long presents, skips;
    unsigned long long enc_cpu_ns, enc_wall_ns;
    unsigned long long drawable_ns;
    /* finish thread / GPU */
    unsigned long long gpu_ns, gpu_bufs, qdepth_sum;
    unsigned long long pass_render, pass_blit, pass_compute, pass_load, pass_store, pass_clear;
    /* distributions, 1 ms per bucket */
    unsigned int wall_hist[IOS_FRAME_HIST_N];
    unsigned int draw_hist[IOS_FRAME_HIST_N];
};

static struct ios_frame_acc ios_frame_acc;
static int ios_frame_panel_hz, ios_frame_intent_hz, ios_frame_mode = -1;

#define IOS_FRAME_ADD(field, v) __atomic_fetch_add( &ios_frame_acc.field, (v), __ATOMIC_RELAXED )

static inline unsigned long long ios_frame_now_ns(void)
{
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info( &tb );
    return mach_absolute_time() * tb.numer / tb.denom;
}

static inline unsigned long long ios_frame_cpu_ns(void)
{
    struct timespec ts;
    /* CLOCK_THREAD_CPUTIME_ID is the calling thread's user+system time and is
     * a vDSO-free but cheap trap on Darwin; two per frame per role thread. */
    if (clock_gettime( CLOCK_THREAD_CPUTIME_ID, &ts )) return 0;
    return (unsigned long long)ts.tv_sec * 1000000000ull + (unsigned long long)ts.tv_nsec;
}

static inline void ios_frame_hist_add( unsigned int *h, unsigned long long ns )
{
    unsigned idx = (unsigned)(ns / 1000000ull);
    if (idx >= IOS_FRAME_HIST_N) idx = IOS_FRAME_HIST_N - 1;
    __atomic_fetch_add( &h[idx], 1, __ATOMIC_RELAXED );
}

/* Percentile out of a 1 ms-bucket histogram.  Returns the bucket's UPPER edge
 * in ms, so a reported p95 of 25 means "95 % of frames finished within 25 ms",
 * which is the direction that cannot mislead. */
static unsigned ios_frame_pct( const unsigned int *h, unsigned pct )
{
    unsigned long long total = 0, seen = 0;
    unsigned i;
    for (i = 0; i < IOS_FRAME_HIST_N; i++) total += h[i];
    if (!total) return 0;
    for (i = 0; i < IOS_FRAME_HIST_N; i++)
    {
        seen += h[i];
        if (seen * 1000 >= total * pct) return i + 1;
    }
    return IOS_FRAME_HIST_N;
}

/* Claim a role for the calling thread.  Written once per role for the life of
 * the process; the CAS makes a double claim (two threads racing through the
 * same hook before either has published) resolve to one winner instead of
 * ping-ponging, which would make the wait attribution flicker. */
void ios_frame_stats_init(void);

static void ios_frame_claim( enum ios_frame_role role )
{
    unsigned long long self = (unsigned long long)(uintptr_t)pthread_self(), expect = 0;
    ios_frame_stats_init();
    if (__atomic_load_n( &ios_frame_role_tid[role], __ATOMIC_RELAXED ) == self) return;
    if (__atomic_load_n( &ios_frame_role_tid[role], __ATOMIC_RELAXED )) return;
    __atomic_compare_exchange_n( &ios_frame_role_tid[role], &expect, self, 0,
                                 __ATOMIC_RELAXED, __ATOMIC_RELAXED );
}

void ios_frame_game_tick(void)
{
    static unsigned long long last_wall, last_cpu;   /* GAME thread only */
    static pthread_mutex_t tick_lock = PTHREAD_MUTEX_INITIALIZER;
    static unsigned switches;
    unsigned long long now, cpu, dw;
    unsigned long long self = (unsigned long long)(uintptr_t)pthread_self(), owner;
    const char *follow;

    if (!ios_frame_stats_on) return;
    ios_frame_claim( IOS_FRAME_ROLE_GAME );
    /* ml1140: a loading thread may hand presentation to the render thread.
     * Pinning the first thread forever produced n=0 beside hundreds of actual
     * presents. Serialize only this two-clock diagnostic, never the renderer;
     * a contended hook drops its sample. Never subtract CPU clocks belonging
     * to different threads. MADEIRA_FRAME_FOLLOW=0 restores the old owner. */
    if (pthread_mutex_trylock( &tick_lock )) return;
    owner = __atomic_load_n( &ios_frame_role_tid[IOS_FRAME_ROLE_GAME], __ATOMIC_RELAXED );
    if (owner != self)
    {
        follow = getenv( "MADEIRA_FRAME_FOLLOW" );
        if (follow && !strcmp( follow, "0" )) { pthread_mutex_unlock( &tick_lock ); return; }
        __atomic_store_n( &ios_frame_role_tid[IOS_FRAME_ROLE_GAME], self, __ATOMIC_RELAXED );
        last_wall = last_cpu = 0;
        if (++switches <= 8)
            wine_log_write( "[frame-owner] ml1140 presenter changed; resetting thread clocks (#%u)", switches );
    }

    now = ios_frame_now_ns();
    cpu = ios_frame_cpu_ns();
    if (last_wall)
    {
        dw = now - last_wall;
        /* A frame longer than four seconds is a load screen, an alt-tab or a
         * breakpoint, not a frame; charging it would move every average by
         * more than the effect being measured. */
        if (dw < 4000000000ull)
        {
            IOS_FRAME_ADD( frames, 1 );
            IOS_FRAME_ADD( wall_ns, dw );
            IOS_FRAME_ADD( cpu_ns, cpu - last_cpu );
            unsigned long long worst = __atomic_load_n( &ios_frame_acc.wall_max_ns, __ATOMIC_RELAXED );
            while (dw > worst && !__atomic_compare_exchange_n( &ios_frame_acc.wall_max_ns, &worst,
                    dw, 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED )) { }
            ios_frame_hist_add( ios_frame_acc.wall_hist, dw );
        }
    }
    last_wall = now; last_cpu = cpu;
    pthread_mutex_unlock( &tick_lock );
}

/* ml1140: actual native encoder creation, aggregated once per heartbeat.
 * Attachment actions are counts (depth/stencil separately), not bytes. */
void ios_frame_pass( unsigned kind, unsigned loads, unsigned stores, unsigned clears )
{
    if (!ios_frame_stats_on) return;
    if (kind == 0) IOS_FRAME_ADD( pass_render, 1 );
    else if (kind == 1) IOS_FRAME_ADD( pass_blit, 1 );
    else if (kind == 2) IOS_FRAME_ADD( pass_compute, 1 );
    if (loads) IOS_FRAME_ADD( pass_load, loads );
    if (stores) IOS_FRAME_ADD( pass_store, stores );
    if (clears) IOS_FRAME_ADD( pass_clear, clears );
}

void ios_frame_encode_present( int skipped )
{
    static unsigned long long last_wall, last_cpu;   /* ENCODE thread only */
    unsigned long long now, cpu;

    if (!ios_frame_stats_on) return;
    ios_frame_claim( IOS_FRAME_ROLE_ENCODE );
    if (!ios_frame_is_role( IOS_FRAME_ROLE_ENCODE )) return;

    IOS_FRAME_ADD( presents, 1 );
    if (skipped) IOS_FRAME_ADD( skips, 1 );

    now = ios_frame_now_ns();
    cpu = ios_frame_cpu_ns();
    if (last_wall && now - last_wall < 4000000000ull)
    {
        IOS_FRAME_ADD( enc_wall_ns, now - last_wall );
        IOS_FRAME_ADD( enc_cpu_ns, cpu - last_cpu );
    }
    last_wall = now; last_cpu = cpu;
}

void ios_frame_drawable_wait( unsigned long long ns )
{
    if (!ios_frame_stats_on) return;
    IOS_FRAME_ADD( drawable_ns, ns );
    ios_frame_hist_add( ios_frame_acc.draw_hist, ns );
}

void ios_frame_gpu( unsigned long long gpu_ns, unsigned long long inflight )
{
    if (!ios_frame_stats_on) return;
    /* GPU completion callbacks need not run on DXMT's finish thread. */
    if (gpu_ns)
    {
        IOS_FRAME_ADD( gpu_ns, gpu_ns );
        IOS_FRAME_ADD( gpu_bufs, 1 );
        IOS_FRAME_ADD( qdepth_sum, inflight );
    }
}

void ios_frame_limiter( unsigned long long ns )
{
    if (!ios_frame_stats_on || !ns) return;
    IOS_FRAME_ADD( wait_ns[IOS_FRAME_WAIT_LIMITER], ns );
}

void ios_frame_wait_add( enum ios_frame_wait kind, unsigned long long ns )
{
    if (kind >= IOS_FRAME_WAIT_MAX) return;
    if (!ios_frame_tracking()) return;
    IOS_FRAME_ADD( wait_ns[kind], ns );
}

/* ml1100 [frame] srv-sites: WHICH server wait costs the presenting thread its frame.
 *
 * The 32-minute session that motivated this puts `srv=' at 20-24 ms of a 40 ms frame
 * and gives no way at all to ask what the thread was waiting FOR. The whole-process
 * [srv-stats] line can only say what every thread did together (`w1 inf=0 fin=4697
 * poll=2900 | wN inf=471 fin=624 ... tmo=4302'), and the presenting thread is one of
 * six. A per-site table on the presenting thread alone answers it, and it is cheap
 * because that thread already reads the clock twice around this exact call.
 *
 * The key is deliberately made of things that are free at the call site: how many
 * objects, whether the timeout is infinite/finite/poll, the first handle (which
 * [wait-census] already prints alongside the object pointer, its type and its
 * fastsync cell, so a later log resolves it without a new probe), and the caller's
 * return address inside ntdll. Object TYPE is not read here on purpose: it would
 * need either a server round trip or a reach into the fastsync cache from the wrong
 * translation unit, and the handle plus [wait-census] gives the same answer offline.
 *
 * The table is per-process, tiny, and raced only by one thread by construction (the
 * GAME role is a single TEB). It is drained and zeroed by the reporter. */
#define IOS_FRAME_SRVSITE_N 12

static struct {
    unsigned long long ns;
    unsigned int n;
    unsigned int tmo;
    const void *pc;
    unsigned int handle;
    unsigned short nobj;
    unsigned char tclass;   /* 0 = infinite, 1 = finite, 2 = poll (zero timeout) */
} ios_frame_srvsite[IOS_FRAME_SRVSITE_N];

void ios_frame_srv_site( const void *pc, unsigned int handle, unsigned int nobj,
                         unsigned char tclass, unsigned long long ns, int timed_out )
{
    int i, worst = 0;

    if (!ios_frame_stats_on) return;
    for (i = 0; i < IOS_FRAME_SRVSITE_N; i++)
    {
        if (ios_frame_srvsite[i].n && ios_frame_srvsite[i].pc == pc &&
            ios_frame_srvsite[i].handle == handle && ios_frame_srvsite[i].nobj == nobj &&
            ios_frame_srvsite[i].tclass == tclass)
        {
            ios_frame_srvsite[i].ns += ns;
            ios_frame_srvsite[i].n++;
            if (timed_out) ios_frame_srvsite[i].tmo++;
            return;
        }
        /* Evict the cheapest slot: the table ranks by TIME, so the site that has
         * cost least is the one whose loss the top-3 cannot notice. */
        if (ios_frame_srvsite[i].ns < ios_frame_srvsite[worst].ns) worst = i;
    }
    ios_frame_srvsite[worst].ns = ns;
    ios_frame_srvsite[worst].n = 1;
    ios_frame_srvsite[worst].tmo = timed_out ? 1 : 0;
    ios_frame_srvsite[worst].pc = pc;
    ios_frame_srvsite[worst].handle = handle;
    ios_frame_srvsite[worst].nobj = (unsigned short)nobj;
    ios_frame_srvsite[worst].tclass = tclass;
}

void ios_frame_note_display( int panel_hz, int intent_hz, int mode )
{
    ios_frame_panel_hz = panel_hz;
    ios_frame_intent_hz = intent_hz;
    ios_frame_mode = mode;
}

/* Parsed once, from the first producer that runs -- which is whichever of the
 * presenting thread or the encode thread reaches its hook first.  There is no
 * init hook shared by both halves of the image early enough to do it anywhere
 * better, and a double parse is harmless. */
void ios_frame_stats_init(void)
{
    static int done;
    const char *e;
    if (done) return;
    done = 1;
    e = getenv( "MADEIRA_FRAME_STATS" );
    ios_frame_stats_on = (e && !strcmp( e, "0" )) ? 0 : 1;
    wine_log_write( "[frame] ml1050 %s - one critical-path line per heartbeat: what BOUNDS a "
                    "frame (presenting-thread CPU vs wait split by cause, encode thread, GPU "
                    "time, drawable acquire, limiter). MADEIRA_FRAME_STATS=0 disables",
                    ios_frame_stats_on ? "ON" : "OFF" );
}

/* ml2000 [spin-probe]: WHERE is a saturated thread spinning while another
 * thread sits in a long server wait?
 *
 * Logs 80/89 froze with one worker at ~99.9% CPU in pure user mode (no server
 * requests, no faults) while the main thread waited INFINITE on an event that
 * worker should set.  [cpu-thread] names the thread but not the loop, and the
 * task-wide samplers were off (they stalled things before, ml1640).  This
 * reads ONE thread's registers 8 times with thread_get_state -- XNU briefly
 * stops only that thread to copy its saved state; no task-wide suspend -- and
 * resolves the host pc (dladdr, 64-bit PE loader list, JIT pool) plus, when
 * the thread is in FEX JIT code, the guest EIP/RIP (block-tail resolver on
 * [x28+0], same as ml876) against the guest loader list (PEB32 for WoW64).
 * Trigger: a thread >= 90% of a core for 2 consecutive 10 s intervals while
 * any registered server wait is >= 10 s old.  Once per thread per continuous
 * hot episode, at most 16 episodes per run.  MADEIRA_SPIN_PROBE=0 disables. */
static unsigned int ios_spin_long_waits( unsigned long long min_ms, unsigned int *oldest_tid,
                                         unsigned long long *oldest_ms );

static void ios_spin_wname( uint64_t buf, unsigned int bytes, char *out, size_t cap )
{
    uint16_t w[48]; unsigned int k, n = bytes / 2;
    if (n > 47) n = 47;
    if (n >= cap) n = (unsigned int)cap - 1;
    out[0] = 0;
    if (!n || !ios_ts_read( buf, w, n * 2 )) { snprintf( out, cap, "?" ); return; }
    for (k = 0; k < n; k++) out[k] = (w[k] >= 32 && w[k] < 127) ? (char)w[k] : '?';
    out[n] = 0;
}

/* Stateless: walks the 64-bit loader list once per lookup (bounded). */
static int ios_spin_mod64( uint64_t teb, uint64_t va, char *name, size_t cap, uint64_t *rva )
{
    uint64_t peb = 0, ldr = 0, head, cur = 0;
    int guard = 0;
    if (!teb || !ios_ts_read( teb + 0x60, &peb, 8 ) || !peb || !ios_ts_read( peb + 0x18, &ldr, 8 ) || !ldr) return 0;
    head = ldr + 0x10;                                 /* InLoadOrderModuleList */
    if (!ios_ts_read( head, &cur, 8 )) return 0;
    while (cur && cur != head && guard++ < 256)
    {
        uint64_t base = 0, buf = 0, next = 0; uint32_t size = 0; uint16_t len = 0;
        if (!ios_ts_read( cur + 0x30, &base, 8 ) || !ios_ts_read( cur + 0x40, &size, 4 )) break;
        if (base && size && va >= base && va < base + size)
        {
            ios_ts_read( cur + 0x58, &len, 2 ); ios_ts_read( cur + 0x60, &buf, 8 );
            ios_spin_wname( buf, len, name, cap );
            *rva = va - base;
            return 1;
        }
        if (!ios_ts_read( cur, &next, 8 )) break;
        cur = next;
    }
    return 0;
}

/* Same for a WoW64 guest: guest address g lives at host B + g (ios_wow.h). */
static int ios_spin_mod32( uint64_t B, uint32_t peb32, uint32_t eip, char *name, size_t cap, uint32_t *rva )
{
    uint32_t ldr = 0, head32, cur32 = 0;
    int guard = 0;
    if (!B || !peb32 || !ios_ts_read( B + peb32 + 0x0c, &ldr, 4 ) || !ldr) return 0;
    head32 = ldr + 0x0c;                               /* PEB_LDR_DATA32.InLoadOrderModuleList */
    if (!ios_ts_read( B + head32, &cur32, 4 )) return 0;
    while (cur32 && cur32 != head32 && guard++ < 256)
    {
        uint32_t base = 0, size = 0, buf = 0, next = 0; uint16_t len = 0;
        if (!ios_ts_read( B + cur32 + 0x18, &base, 4 ) || !ios_ts_read( B + cur32 + 0x20, &size, 4 )) break;
        if (base && size && eip >= base && eip - base < size)
        {
            ios_ts_read( B + cur32 + 0x2c, &len, 2 ); ios_ts_read( B + cur32 + 0x30, &buf, 4 );
            ios_spin_wname( buf ? B + buf : 0, len, name, cap );
            *rva = eip - base;
            return 1;
        }
        if (!ios_ts_read( B + cur32, &next, 4 )) break;
        cur32 = next;
    }
    return 0;
}

static void ios_spin_host_where( uint64_t teb, uint64_t a, char *out, size_t cap )
{
    extern void *ios_jit_rx_base_global;
    extern size_t ios_jit_pool_size_global;
    uint64_t rx = (uint64_t)(uintptr_t)ios_jit_rx_base_global, rva = 0;
    char nm[48];
    if (ios_ts_sym( a, out, cap )) return;
    if (ios_spin_mod64( teb, a, nm, sizeof(nm), &rva )) { snprintf( out, cap, "%s+0x%llx", nm, (unsigned long long)rva ); return; }
    if (rx && ios_jit_pool_size_global && a >= rx && a < rx + ios_jit_pool_size_global)
    { snprintf( out, cap, "jit-pool+0x%llx", (unsigned long long)(a - rx) ); return; }
    snprintf( out, cap, "0x%llx(anon)", (unsigned long long)a );
}

static void ios_spin_probe_thread( thread_act_t port, uint64_t id, double pct,
                                   unsigned int nlong, unsigned int wtid, unsigned long long wms )
{
    extern uint64_t ios_native_rip_from_hostpc( uint64_t, uint64_t, const char ** );
    pthread_t pt = pthread_from_mach_thread_np( port );
    uint64_t teb = ios_ts_teb( pt ), peb = 0, B = 0, tstate = 0, tframe = 0;
    uint32_t tid = 0, peb32 = 0;
    int s;

    if (!teb)
    {
        /* ios_ts_teb needs the TSD offset, calibrated once from a live thread. */
        if (ios_ts_tsd_off < 0) ios_ts_calibrate();
        teb = ios_ts_teb( pt );
    }
    if (teb)
    {
        ios_ts_read( teb + 0x48, &tid, 4 );                          /* ClientId.UniqueThread */
        if (ios_ts_read( teb + 0x60, &peb, 8 ) && peb) B = ios_wow_base_for_peb( (void *)(uintptr_t)peb );
        if (B)
        {
            int32_t wow_off = 0; uint32_t tmp = 0;
            /* FEX WoW64 keeps its ThreadState in TlsSlots[14] ([wow64-tls]);
             * InternalThreadState starts with CurrentFrame. */
            if (ios_ts_read( teb + offsetof(TEB, TlsSlots) + 14 * 8, &tstate, 8 ) && tstate >= 0x10000)
                ios_ts_read( tstate, &tframe, 8 );
            if (ios_ts_read( teb + offsetof(TEB, WowTebOffset), &wow_off, 4 ) && wow_off &&
                ios_ts_read( teb + (int64_t)wow_off + 0x30, &tmp, 4 )) peb32 = tmp;   /* TEB32.Peb */
        }
    }
    wine_log_write( "[spin-probe] ml2000 HOT tid=%04x id=%llu mach=%#x cpu=%.1f%% x2 intervals; long-waits(>=10s)=%u oldest tid=%04x age=%llums "
                    "teb=0x%llx wow=%s B=0x%llx fex-ts=0x%llx frame=0x%llx; 8 register reads, this thread only",
                    tid, (unsigned long long)id, port, pct, nlong, wtid, wms, (unsigned long long)teb, B ? "yes" : "no",
                    (unsigned long long)B, (unsigned long long)tstate, (unsigned long long)tframe );
    for (s = 0; s < 8; s++)
    {
        arm_thread_state64_t st;
        mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
        uint64_t pc, lr, sp, x28, bb = 0, rip = 0, srip = 0;
        const char *why = "no block", *src = "-";
        char wpc[112], wlr[112], gm[48] = "", line[640];
        int n;

        if (s) usleep( 2000 );
        if (thread_get_state( port, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt ) != KERN_SUCCESS)
        {
            wine_log_write( "[spin-probe] ml2000 s%d thread_get_state failed (thread gone?)", s );
            break;
        }
        pc = arm_thread_state64_get_pc( st ); lr = arm_thread_state64_get_lr( st );
        sp = arm_thread_state64_get_sp( st ); x28 = st.__x[28];
        ios_spin_host_where( teb, pc, wpc, sizeof(wpc) );
        ios_spin_host_where( teb, lr, wlr, sizeof(wlr) );
        /* In JIT code x28 is the FEX CpuStateFrame: [+0] InlineJITBlockHeader,
         * [+0x18] State.rip (stale while the JIT runs). */
        if (ios_ts_read( x28, &bb, 8 ) && bb > 0x10000) { rip = ios_native_rip_from_hostpc( bb, pc, &why ); if (rip) src = "jit-pc"; }
        if (!rip && tframe && tframe != x28 && ios_ts_read( tframe, &bb, 8 ) && bb > 0x10000)
        { rip = ios_native_rip_from_hostpc( bb, pc, &why ); if (rip) src = "ts-frame"; }
        if (!ios_ts_read( (tframe ? tframe : x28) + 0x18, &srip, 8 )) srip = 0;
        n = snprintf( line, sizeof(line), "[spin-probe] ml2000 s%d tid=%04x pc=0x%llx(%s) lr=0x%llx(%s) sp=0x%llx x18=0x%llx x28=0x%llx%s",
                      s, tid, (unsigned long long)pc, wpc, (unsigned long long)lr, wlr, (unsigned long long)sp,
                      (unsigned long long)st.__x[18], (unsigned long long)x28, (tframe && x28 == tframe) ? "(=frame)" : "" );
        if (rip)
        {
            if (B && rip < 0x100000000ull)
            {
                uint32_t rva32 = 0;
                if (ios_spin_mod32( B, peb32, (uint32_t)rip, gm, sizeof(gm), &rva32 ))
                    n += snprintf( line + n, sizeof(line) - n, " GUEST eip=0x%08x(%s+0x%x) via %s", (unsigned)rip, gm, rva32, src );
                else
                    n += snprintf( line + n, sizeof(line) - n, " GUEST eip=0x%08x(?) via %s", (unsigned)rip, src );
            }
            else
            {
                uint64_t rva = 0;
                if (ios_spin_mod64( teb, rip, gm, sizeof(gm), &rva ))
                    n += snprintf( line + n, sizeof(line) - n, " GUEST rip=0x%llx(%s+0x%llx) via %s", (unsigned long long)rip, gm, (unsigned long long)rva, src );
                else
                    n += snprintf( line + n, sizeof(line) - n, " GUEST rip=0x%llx(?) via %s", (unsigned long long)rip, src );
            }
        }
        else n += snprintf( line + n, sizeof(line) - n, " GUEST ? (%s)", why );
        if (srip && n < (int)sizeof(line) - 40)
            n += snprintf( line + n, sizeof(line) - n, " state-rip=0x%llx", (unsigned long long)srip );
        wine_log_write( "%s", line );
    }
}

/* Called from ios_cpu_diagnostics with the live port list, BEFORE the ports
 * are released. rows[] carry the per-interval CPU deltas. */
static void ios_spin_probe( const uint64_t *ids, const unsigned int *ports, const uint64_t *deltas,
                            unsigned int n, uint64_t elapsed )
{
    static struct { uint64_t id; unsigned int streak, probed, seen; } hot[16];
    static int enabled = -1;
    static unsigned int epoch, episodes;
    mach_port_t self = pthread_mach_thread_np( pthread_self() );
    unsigned int i, k, probes = 0, nlong = 0, wtid = 0;
    unsigned long long wms = 0;
    int waits_checked = 0;

    if (enabled < 0)
    {
        const char *e = getenv( "MADEIRA_SPIN_PROBE" );
        enabled = !(e && !strcmp( e, "0" ));
        wine_log_write( "[spin-probe] ml2000 %s (>=90%% CPU for 2 intervals + a >=10 s server wait -> 8 single-thread "
                        "register reads; MADEIRA_SPIN_PROBE=0 disables)", enabled ? "armed" : "OFF" );
    }
    if (!enabled || !elapsed) return;
    epoch++;
    for (k = 0; k < n; k++)
    {
        unsigned int slot = 16;
        if (deltas[k] * 10 < elapsed * 9) continue;           /* < 90% of one core */
        for (i = 0; i < 16; i++) if (hot[i].id == ids[k]) { slot = i; break; }
        if (slot == 16)
            for (i = 0; i < 16; i++) if (!hot[i].id || hot[i].seen + 1 < epoch) { slot = i; hot[i].id = ids[k]; hot[i].streak = 0; hot[i].probed = 0; break; }
        if (slot == 16) continue;
        /* A gap of one interval ends the episode. */
        if (hot[slot].seen + 1 != epoch) { hot[slot].streak = 0; hot[slot].probed = 0; }
        hot[slot].seen = epoch;
        hot[slot].streak++;
        if (hot[slot].streak < 2 || hot[slot].probed || probes >= 2 || episodes >= 16 || ports[k] == self) continue;
        if (!waits_checked) { nlong = ios_spin_long_waits( 10000, &wtid, &wms ); waits_checked = 1; }
        if (!nlong) continue;
        hot[slot].probed = 1;
        probes++; episodes++;
        ios_spin_probe_thread( ports[k], ids[k], 100.0 * deltas[k] / elapsed, nlong, wtid, wms );
    }
}

/* ml1950: cumulative thread CPU deltas, without suspending a thread or reading
 * its registers/stack. Ten-second cadence separates a busy worker from a waiting
 * presenter; wall-minus-CPU alone cannot establish CPU saturation. Kernel thread
 * IDs distinguish a new thread from a recycled Mach port name. Dead/new threads
 * are deliberately excluded from deltas, so the sum is not whole-task CPU. */
static void ios_cpu_diagnostics(void)
{
    struct sample { uint64_t id, cpu; unsigned int generation; };
    struct row { uint64_t id, delta; unsigned int port; int state, role; char name[64]; };
    static struct sample previous[256];
    static struct row rows[256];
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static uint64_t last;
    static unsigned int generation;
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    uint64_t now, elapsed, total = 0;
    unsigned int k, n = 0, dropped = 0, matched = 0;
    const char *enabled = getenv( "MADEIRA_CPU_DIAGNOSTICS" );

    if (!enabled || strcmp( enabled, "1" ) || pthread_mutex_trylock( &lock )) return;
    now = ios_frame_now_ns();
    if (last && now - last < 10000000000ull) goto done;
    if (task_threads( mach_task_self(), &threads, &count ) != KERN_SUCCESS) goto done;
    elapsed = last ? now - last : 0;
    generation++;
    for (k = 0; k < count; k++)
    {
        thread_identifier_info_data_t identity;
        thread_basic_info_data_t basic;
        mach_msg_type_number_t ic = THREAD_IDENTIFIER_INFO_COUNT, bc = THREAD_BASIC_INFO_COUNT;
        unsigned int i, slot = 256;
        uint64_t cpu;
        if (thread_info( threads[k], THREAD_IDENTIFIER_INFO, (thread_info_t)&identity, &ic ) != KERN_SUCCESS ||
            thread_info( threads[k], THREAD_BASIC_INFO, (thread_info_t)&basic, &bc ) != KERN_SUCCESS) continue;
        cpu = ((uint64_t)basic.user_time.seconds + basic.system_time.seconds) * 1000000000ull +
              ((uint64_t)basic.user_time.microseconds + basic.system_time.microseconds) * 1000ull;
        for (i = 0; i < 256; i++)
            if (previous[i].id == identity.thread_id) { slot = i; break; }
        if (slot == 256)
            for (i = 0; i < 256; i++)
                if (!previous[i].id || previous[i].generation + 1 < generation) { slot = i; break; }
        if (slot == 256) { dropped++; continue; }
        if (elapsed && previous[slot].id == identity.thread_id &&
            previous[slot].generation + 1 == generation && cpu >= previous[slot].cpu)
        {
            struct row *r = &rows[n++];
            thread_extended_info_data_t extended;
            mach_msg_type_number_t ec = THREAD_EXTENDED_INFO_COUNT;
            pthread_t pt = pthread_from_mach_thread_np( threads[k] );
            r->id = identity.thread_id;
            r->port = threads[k];
            r->delta = cpu - previous[slot].cpu;
            r->state = basic.run_state;
            r->role = -1;
            r->name[0] = 0;
            total += r->delta;
            matched++;
            for (i = 0; i < IOS_FRAME_ROLE_MAX; i++)
                if ((uint64_t)(uintptr_t)pt == __atomic_load_n( &ios_frame_role_tid[i], __ATOMIC_RELAXED )) r->role = i;
            if (thread_info( threads[k], THREAD_EXTENDED_INFO, (thread_info_t)&extended, &ec ) == KERN_SUCCESS)
            {
                memcpy( r->name, extended.pth_name, sizeof(r->name) - 1 );
                r->name[sizeof(r->name) - 1] = 0;
                for (i = 0; r->name[i]; i++) if ((unsigned char)r->name[i] < 32 || (unsigned char)r->name[i] > 126) r->name[i] = '?';
            }
        }
        previous[slot].id = identity.thread_id;
        previous[slot].cpu = cpu;
        previous[slot].generation = generation;
    }
    /* ml2000: probe a saturated thread while its port is still held. */
    if (elapsed && n)
    {
        static uint64_t sp_ids[256], sp_deltas[256];
        static unsigned int sp_ports[256];
        for (k = 0; k < n; k++) { sp_ids[k] = rows[k].id; sp_ports[k] = rows[k].port; sp_deltas[k] = rows[k].delta; }
        ios_spin_probe( sp_ids, sp_ports, sp_deltas, n, elapsed );
    }
    /* Release every port even if metadata queries failed. */
    for (k = 0; k < count; k++) mach_port_deallocate( mach_task_self(), threads[k] );
    vm_deallocate( mach_task_self(), (vm_address_t)threads, count * sizeof(*threads) );
    if (elapsed)
    {
        wine_log_write( "[cpu-budget] ml1950 interval=%.2fs live-threads=%u matched=%u dropped=%u live-core-equivalents=%.2f (no thread suspension)",
                        elapsed * 1e-9, count, matched, dropped, (double)total / elapsed );
        for (k = 0; k < 6 && k < n; k++)
        {
            unsigned int i, best = 0;
            for (i = 1; i < n; i++) if (rows[i].delta > rows[best].delta) best = i;
            if (!rows[best].delta) break;
            wine_log_write( "[cpu-thread] ml1950 id=%llu mach=%#x name=%s role=%d cpu=%.1f%% state=%d",
                            (unsigned long long)rows[best].id, rows[best].port, rows[best].name, rows[best].role,
                            100.0 * rows[best].delta / elapsed, rows[best].state );
            rows[best].delta = 0;
        }
    }
    last = now;
done:
    pthread_mutex_unlock( &lock );
}

/* One line per heartbeat window.  Everything is per-frame except fps, n and
 * the two percentiles, because a per-window total cannot be compared against
 * a refresh interval and the refresh interval is the thing every number here
 * is trying to be measured against. */
void ios_frame_report( unsigned long long win_ns )
{
    struct ios_frame_acc a;
    unsigned int wall_p95, draw_p95, wall_p99, wall_p999, over50 = 0, over100 = 0;
    double f, ef, gf, fps;
    unsigned i;

    if (!ios_frame_stats_on) return;

    ios_cpu_diagnostics();

    /* Exchange the 64-bit prefix to zero: these are per-window rates.  A
     * producer racing this loses at most one frame's contribution.  The bound
     * is derived from the struct rather than written down, so adding a counter
     * cannot silently leave it un-zeroed -- and it stops exactly where the
     * 32-bit histograms begin. */
    memset( &a, 0, sizeof(a) );
    for (i = 0; i < offsetof(struct ios_frame_acc, wall_hist) / sizeof(unsigned long long); i++)
        ((unsigned long long *)&a)[i] =
            __atomic_exchange_n( &((unsigned long long *)&ios_frame_acc)[i], 0, __ATOMIC_RELAXED );
    /* wall_hist/draw_hist are unsigned int and sit past that prefix. */
    {
        unsigned int wh[IOS_FRAME_HIST_N], dh[IOS_FRAME_HIST_N];
        for (i = 0; i < IOS_FRAME_HIST_N; i++)
        {
            wh[i] = __atomic_exchange_n( &ios_frame_acc.wall_hist[i], 0, __ATOMIC_RELAXED );
            dh[i] = __atomic_exchange_n( &ios_frame_acc.draw_hist[i], 0, __ATOMIC_RELAXED );
        }
        wall_p95 = ios_frame_pct( wh, 950 );
        draw_p95 = ios_frame_pct( dh, 950 );
        wall_p99 = ios_frame_pct( wh, 990 );
        wall_p999 = ios_frame_pct( wh, 999 );
        for (i = 50; i < IOS_FRAME_HIST_N; i++) over50 += wh[i];
        for (i = 100; i < IOS_FRAME_HIST_N; i++) over100 += wh[i];
    }

    if (!a.frames)
    {
        /* Silence would be ambiguous: "no frames" and "the instrument is not
         * wired up" are different diagnoses and only one of them is a bug. */
        if (a.presents || ios_frame_mode >= 0)
            wine_log_write( "[frame] ml1050 n=0 (no Present reached the presenter this window) "
                            "presents=%llu mode=%d panel=%dHz intent=%dHz",
                            a.presents, ios_frame_mode, ios_frame_panel_hz, ios_frame_intent_hz );
        return;
    }

    f  = 1e-6 / (double)a.frames;                       /* ns total -> ms/frame */
    ef = a.presents ? 1e-6 / (double)a.presents : 0.0;
    gf = a.gpu_bufs ? 1e-6 / (double)a.gpu_bufs : 0.0;
    fps = win_ns ? (double)a.frames * 1e9 / (double)win_ns : 0.0;
    wine_log_write( "[frame-tail] ml1150 n=%llu p99=%ums p99.9=%ums max=%.2fms >=50ms=%u >=100ms=%u "
                    "(1ms buckets; samples under 4s; MADEIRA_FRAME_STATS=0 disables)",
                    a.frames, wall_p99, wall_p999, a.wall_max_ns * 1e-6, over50, over100 );

    {
        double waitsum = 0.0;
        for (i = 0; i < IOS_FRAME_WAIT_MAX; i++) waitsum += (double)a.wait_ns[i];
        wine_log_write(
            "[frame] ml1050 n=%llu fps=%.1f wall=%.1fms(p95 %u) | game: cpu=%.1f wait=%.1f "
            "(fast=%.1f srv=%.1f sleep=%.1f unix=%.1f present=%.1f other=%.1f) | "
            "encode: n=%llu skip=%llu cpu=%.1f idle=%.1f | gpu=%.2f(n=%llu) qdepth=%.1f | "
            "drawable=%.2f(p95 %u) limiter=%.2f | mode=%d panel=%dHz intent=%dHz",
            a.frames, fps, (double)a.wall_ns * f, wall_p95,
            (double)a.cpu_ns * f,
            ((double)a.wall_ns - (double)a.cpu_ns) * f,
            (double)a.wait_ns[IOS_FRAME_WAIT_FAST] * f,
            (double)a.wait_ns[IOS_FRAME_WAIT_SRV] * f,
            (double)a.wait_ns[IOS_FRAME_WAIT_SLEEP] * f,
            (double)a.wait_ns[IOS_FRAME_WAIT_UNIX] * f,
            (double)a.wait_ns[IOS_FRAME_WAIT_PRESENT] * f,
            ((double)a.wall_ns - (double)a.cpu_ns - waitsum
             + (double)a.wait_ns[IOS_FRAME_WAIT_LIMITER]) * f,
            a.presents, a.skips,
            (double)a.enc_cpu_ns * ef,
            ((double)a.enc_wall_ns - (double)a.enc_cpu_ns) * ef,
            (double)a.gpu_ns * gf, a.gpu_bufs,
            a.gpu_bufs ? (double)a.qdepth_sum / (double)a.gpu_bufs : 0.0,
            (double)a.drawable_ns * ef, draw_p95,
            (double)a.wait_ns[IOS_FRAME_WAIT_LIMITER] * ef,
            ios_frame_mode, ios_frame_panel_hz, ios_frame_intent_hz );
        wine_log_write( "[gpu-work] ml1140 per-present: render=%.1f blit=%.1f compute=%.1f "
                        "load=%.1f store=%.1f clear=%.1f buffers=%.2f gpu-ms=%.2f (MADEIRA_FRAME_STATS=0 disables)",
                        a.pass_render * ef * 1e6, a.pass_blit * ef * 1e6, a.pass_compute * ef * 1e6,
                        a.pass_load * ef * 1e6, a.pass_store * ef * 1e6, a.pass_clear * ef * 1e6,
                        a.gpu_bufs * ef * 1e6, a.gpu_ns * ef );
    }

    /* ml1050: the handoff half, on its own line because it is a distribution
     * and a distribution does not fit in a field.  `spin' is the adaptive
     * spin's payoff rate (hit = a park and a wake that did not happen) and
     * `park us' is the log2 histogram of how long the handoffs that DID park
     * actually took.  Together they say whether MADEIRA_FASTSYNC_SPIN_US is
     * set too low (mass at 1-32 us with a poor hit rate) or is simply not the
     * problem (mass above 256 us, where no spin budget could have helped). */
    {
        extern void madeira_fast_park_hist_snapshot( unsigned int *out, unsigned n,
                                                     unsigned int *spin_hit,
                                                     unsigned int *spin_miss, int *credit,
                                                     unsigned int *spin_probe );
        unsigned int ph[16], i2, total = 0, seen = 0, p50 = 0, p90 = 0;
        unsigned int spin_hit = 0, spin_miss = 0, spin_probe = 0;
        int credit = 0;
        char line[512];
        int len;

        madeira_fast_park_hist_snapshot( ph, 16, &spin_hit, &spin_miss, &credit, &spin_probe );
        for (i2 = 0; i2 < 16; i2++) total += ph[i2];
        if (total || spin_hit || spin_miss)
        {
            for (i2 = 0; i2 < 16; i2++)
            {
                seen += ph[i2];
                if (!p50 && seen * 2 >= total) p50 = i2 ? (1u << (i2 - 1)) : 0;
                if (!p90 && seen * 10 >= total * 9) { p90 = i2 ? (1u << (i2 - 1)) : 0; break; }
            }
            /* ml1100: `probe' is what separates "the controller decided not to spin"
             * from "the controller can no longer decide anything" — see the probe
             * note in sync.c. hit=0 miss=0 probe=0 now means OFF by configuration. */
            len = snprintf( line, sizeof(line),
                            "[frame]   handoff: spin hit=%u miss=%u probe=%u credit=%d | parked=%u "
                            "p50=%uus p90=%uus | us:",
                            spin_hit, spin_miss, spin_probe, credit, total, p50, p90 );
            for (i2 = 0; i2 < 16 && len > 0 && len < (int)sizeof(line); i2++)
                if (ph[i2])
                    len += snprintf( line + len, sizeof(line) - len, " %u=%u",
                                     i2 ? (1u << (i2 - 1)) : 0, ph[i2] );
            wine_log_write( "%s", line );
        }
    }

    /* ml1100: the third [frame] line — where the presenting thread's `srv=' went.
     * Top three sites by TIME, drained and zeroed here. `obj=' is the first handle
     * and resolves against [wait-census], which prints handle, object pointer, type
     * and fastsync cell for every blocked waiter. `n=' with `tmo=' equal to it is a
     * poll loop; `n=' near the frame count with a large mean is a real dependency. */
    {
        unsigned long long tot = 0;
        char line[512];
        int len, i2, k, printed = 0;

        for (i2 = 0; i2 < IOS_FRAME_SRVSITE_N; i2++) tot += ios_frame_srvsite[i2].ns;
        if (tot)
        {
            len = snprintf( line, sizeof(line), "[frame]   srv-sites:" );
            for (k = 0; k < 3; k++)
            {
                int best = -1;

                for (i2 = 0; i2 < IOS_FRAME_SRVSITE_N; i2++)
                    if (ios_frame_srvsite[i2].n &&
                        (best < 0 || ios_frame_srvsite[i2].ns > ios_frame_srvsite[best].ns))
                        best = i2;
                if (best < 0) break;
                if (len > 0 && len < (int)sizeof(line))
                    len += snprintf( line + len, sizeof(line) - len,
                                     " #%d %s %s obj=%08x n=%u tmo=%u %llums(mean %lluus) pc=%p |",
                                     k + 1,
                                     ios_frame_srvsite[best].nobj > 1 ? "waitN" : "wait1",
                                     ios_frame_srvsite[best].tclass == 0 ? "inf" :
                                     ios_frame_srvsite[best].tclass == 1 ? "fin" : "poll",
                                     ios_frame_srvsite[best].handle, ios_frame_srvsite[best].n,
                                     ios_frame_srvsite[best].tmo,
                                     ios_frame_srvsite[best].ns / 1000000ull,
                                     ios_frame_srvsite[best].ns / ios_frame_srvsite[best].n / 1000ull,
                                     ios_frame_srvsite[best].pc );
                ios_frame_srvsite[best].ns = 0;   /* so the next pass finds the next one */
                ios_frame_srvsite[best].n = 0;
                printed = 1;
            }
            if (printed)
                wine_log_write( "%s total=%llums", line, tot / 1000000ull );
            memset( ios_frame_srvsite, 0, sizeof(ios_frame_srvsite) );
        }
    }
}

#ifdef WINE_IOS

/***********************************************************************
 *           [srv-stats]  —  what the wineserver round trip actually costs
 *
 * ml920's [prof] put 15-25 % of ALL CPU inside the round trip itself
 * (read<-read_request, read<-read_reply_data, semaphore_signal_trap<-
 * server_call_unlocked, semaphore_timedwait_trap<-main_loop) but could not
 * say WHICH requests were paying it: the kernel stacks are identical for
 * every request kind.  This is the missing half.
 *
 * Accounting is CLIENT-side and wraps exactly the span the profiler charges
 * us for: send_request() entry to the last byte of the reply, i.e. the whole
 * of server_call_unlocked, which is the single chokepoint every request kind
 * goes through (wine_server_call, server_select and SERVER_START_REQ all end
 * up here).  Cost per request: two mach_absolute_time() reads (a commpage
 * read on arm64, no syscall) and three relaxed atomic adds.
 *
 * Counters are plain arrays written with __ATOMIC_RELAXED.  A lost increment
 * costs fidelity, never correctness, and the alternative — a lock — would
 * become the thing being measured.  The report is PIGGY-BACKED: whichever
 * thread first sees the 10 s deadline at the end of its own call publishes
 * the new deadline with a CAS and prints; every other thread sees the CAS
 * fail and walks away, so the report happens exactly once per window with no
 * timer thread of its own.  Each counter is exchanged to zero as it is read,
 * so the numbers are per-window rates.
 *
 * The request NAMES come from server_req_names.h, generated once from the
 * enum in wine/include/wine/server_protocol.h.  Regenerate it with:
 *   sed -n '/^enum request$/,/REQ_NB_REQUESTS/p' include/wine/server_protocol.h \
 *     | sed -n 's/^ *REQ_\([a-z0-9_]*\),$/    "\1",/p'
 * and keep the C_ASSERT at its foot — it is what turns a Wine update that
 * inserts a request into a build failure instead of a silently shifted table.
 */
#include <mach/mach_time.h>
#include "ios_srv_stats.h"
#include "ios_spin_hist.h"
#include "ios_fastsync.h"     /* ml1110: MADEIRA_CELL_KIND_* for [late-wake] */
#include "ios_late_wake.h"
#include "server_req_names.h"

/* MADEIRA_SRV_STATS=0 turns the accounting off entirely (both timer reads
 * and every atomic add); any other value, or absent, leaves it on. */
static int ios_srv_stats_on = -1;         /* -1 = not yet probed */

/* ml990: the ten-line report and the per-request timing/caller work that only
 * the report consumes. Follows MADEIRA_DIAG; see ios_srv_stats_enabled(). */
static int ios_srv_report_on = 0;

#define IOS_SRV_STATS_PERIOD_S   10
#define IOS_SRV_STATS_TOP_KINDS  12
#define IOS_SRV_STATS_TOP_THR    6
#define IOS_SRV_THR_SLOTS        256

unsigned int ios_srv_nt_counts[IOS_NT_COUNTER_MAX];
unsigned int ios_srv_thrinfo_counts[IOS_TI_COUNTER_MAX];   /* ml951, see ios_srv_stats.h */

static unsigned int        ios_srv_kind_count[REQ_NB_REQUESTS];
static unsigned long long  ios_srv_kind_ticks[REQ_NB_REQUESTS];
static unsigned int        ios_srv_thr_tid[IOS_SRV_THR_SLOTS];
static unsigned int        ios_srv_thr_count[IOS_SRV_THR_SLOTS];
/*
 * ml970  CALLER ATTRIBUTION for the kinds line.
 *
 * `kinds:' answers WHICH request is hot and `threads:' answers WHO issues it,
 * but neither says WHAT CODE asked.  Log 46 had five request kinds locked to
 * each other at ~177/s -- dup_handle=1770 get_object_info=1770
 * close_handle=1772 get_thread_context=1770 and set_thread_context=2950 per
 * 10 s -- with nothing in a D3D9 game that should touch a thread context per
 * frame.  A count cannot distinguish "the game polls a worker" from "our own
 * wow64 plumbing round-trips on the CURRENT thread", and those want opposite
 * fixes.
 *
 * WHAT IS RECORDED.  One return address per request, taken at
 * server_call_unlocked: preferably ONE FRAME ABOVE it -- server_call_unlocked's
 * immediate caller is nearly always the thin wrapper (wine_server_call, or
 * server_select), and the frame above that is the Nt* entry point that is
 * worth naming.  The hop is a guarded read of this thread's own frame-pointer
 * chain (arm64 keeps x29 linked on Darwin); if any guard fails it falls back
 * to the immediate return address, so it can degrade but never fault.
 *
 * WHY NOT THE GUEST RIP.  For a 32-bit caller the interesting address is the
 * i386 EIP, and it is NOT cheaply available on this side: the wow64 CPU area's
 * Eip is only valid once FEX has flushed its JIT state into it, which is
 * itself a server round trip (Context::FlushThreadStateContext), so reading it
 * here would either be stale or cost more than the request being measured.
 * What the host symbol gives instead is the Nt* function, which is the level
 * the fix lives at anyway: NtQueryInformationThread(ThreadWow64Context) and
 * NtQueryObject name their own callers unambiguously.
 *
 * Resolution is dladdr() at report time on at most 8x2 addresses; nothing on
 * the hot path but two loads, a bounds check and one relaxed CAS/add.  PCs are
 * never cleared (they are stable for the life of the process, so the table
 * stays warm across windows); only the counts are exchanged to zero.
 */
#define IOS_SRV_CALLER_SLOTS 4

static uintptr_t    ios_srv_caller_pc[REQ_NB_REQUESTS][IOS_SRV_CALLER_SLOTS];
static unsigned int ios_srv_caller_n[REQ_NB_REQUESTS][IOS_SRV_CALLER_SLOTS];
static unsigned int ios_srv_caller_other[REQ_NB_REQUESTS];

/* One guarded hop up the frame-pointer chain.  `ra' is the caller's own return
 * address and `fp' its frame pointer; on arm64 a frame is { saved x29, saved
 * x30 } at [fp], so the caller's caller is at [[fp]+8].  Every guard below is
 * about never dereferencing a value we did not prove is a live frame link:
 * non-NULL, 16-byte aligned, strictly ascending (stacks grow down, so an outer
 * frame is at a HIGHER address), and within 64 KB -- a single Wine stack frame
 * is never larger, and the bound is what stops a leaf function that reused x29
 * from sending us into unmapped memory. */
static inline uintptr_t ios_srv_caller_hop( uintptr_t ra, uintptr_t fp )
{
    uintptr_t outer;

    if (!fp || (fp & 15) || fp < 0x1000) return ra;
    outer = *(const uintptr_t *)fp;
    if (!outer || (outer & 15) || outer <= fp || outer - fp > 0x10000) return ra;
    return *(const uintptr_t *)(outer + 8);
}

#define IOS_SRV_CALLER_PC() \
    ios_srv_caller_hop( (uintptr_t)__builtin_return_address(0), (uintptr_t)__builtin_frame_address(0) )

static void ios_srv_caller_bump( unsigned int kind, uintptr_t pc )
{
    int i;

    if (kind >= REQ_NB_REQUESTS || !pc) return;
    for (i = 0; i < IOS_SRV_CALLER_SLOTS; i++)
    {
        uintptr_t have = __atomic_load_n( &ios_srv_caller_pc[kind][i], __ATOMIC_RELAXED );

        if (have == pc)
        {
            __atomic_fetch_add( &ios_srv_caller_n[kind][i], 1, __ATOMIC_RELAXED );
            return;
        }
        if (!have)
        {
            uintptr_t expect = 0;
            if (__atomic_compare_exchange_n( &ios_srv_caller_pc[kind][i], &expect, pc, 0,
                                             __ATOMIC_RELAXED, __ATOMIC_RELAXED ))
            {
                __atomic_fetch_add( &ios_srv_caller_n[kind][i], 1, __ATOMIC_RELAXED );
                return;
            }
            i--;   /* someone claimed it under us; re-read this same slot */
        }
    }
    /* A kind with more than IOS_SRV_CALLER_SLOTS distinct call sites: counted
     * but not named, so the printed shares are honest about what they miss. */
    __atomic_fetch_add( &ios_srv_caller_other[kind], 1, __ATOMIC_RELAXED );
}

static unsigned long long  ios_srv_stats_deadline;   /* mach ticks */
static unsigned long long  ios_srv_stats_window_t0;

static inline unsigned long long ios_srv_ticks_to_ns( unsigned long long ticks )
{
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info( &tb );
    return ticks * tb.numer / tb.denom;
}

static inline unsigned long long ios_srv_ns_to_ticks( unsigned long long ns )
{
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info( &tb );
    return ns * tb.denom / tb.numer;
}

/* Open-addressed, fixed, never-grown.  A tid that cannot find a slot in four
 * probes is folded into slot 0 and reported as tid 0000 — the top callers are
 * a handful of threads, and a long tail that lands in the bucket is exactly
 * what "other" should mean. */
static inline void ios_srv_thr_bump( unsigned int tid )
{
    unsigned int i, idx = (tid * 2654435761u) % IOS_SRV_THR_SLOTS;

    for (i = 0; i < 4; i++)
    {
        unsigned int slot = (idx + i) % IOS_SRV_THR_SLOTS;
        unsigned int have = __atomic_load_n( &ios_srv_thr_tid[slot], __ATOMIC_RELAXED );

        if (have == tid)
        {
            __atomic_fetch_add( &ios_srv_thr_count[slot], 1, __ATOMIC_RELAXED );
            return;
        }
        if (!have)
        {
            unsigned int expect = 0;
            if (__atomic_compare_exchange_n( &ios_srv_thr_tid[slot], &expect, tid, 0,
                                             __ATOMIC_RELAXED, __ATOMIC_RELAXED ))
            {
                __atomic_fetch_add( &ios_srv_thr_count[slot], 1, __ATOMIC_RELAXED );
                return;
            }
            i--;   /* someone claimed it under us; re-read this same slot */
        }
    }
    __atomic_fetch_add( &ios_srv_thr_count[0], 1, __ATOMIC_RELAXED );
}

static int ios_srv_stats_busy;   /* ml962: serialises the two callers below */
static int ios_srv_stats_enabled(void);

static void ios_srv_stats_report( unsigned long long now )
{
    unsigned int top_kind[IOS_SRV_STATS_TOP_KINDS], top_thr[IOS_SRV_STATS_TOP_THR];
    /* The snapshot arrays are static, not automatic: ~4.7 KB of stack would
     * otherwise land on whichever thread happened to cross the deadline, and
     * that can be a FEX/CEF-created thread with a small stack.  Only one
     * thread is ever inside this function — the deadline CAS in
     * ios_srv_stats_account() elects exactly one per window and publishes the
     * next deadline before calling, and ios_srv_stats_report_now() takes the
     * ios_srv_stats_busy flag — so one shared set is safe. */
    static unsigned int counts[REQ_NB_REQUESTS], thr_counts[IOS_SRV_THR_SLOTS];
    static unsigned long long ticks[REQ_NB_REQUESTS];
    unsigned long long total_ns = 0, window_ns;
    unsigned int total = 0, nt[IOS_NT_COUNTER_MAX];
    char line[1024];
    int i, j, n, len, expect = 0;

    /* ml962: the window reporter is elected by the deadline CAS, but the
     * process-exit reporter below is not, and both use the static snapshot
     * arrays.  One CAS keeps them from overlapping; a losing caller simply
     * skips its report rather than interleaving lines with the winner's. */
    if (!__atomic_compare_exchange_n( &ios_srv_stats_busy, &expect, 1, 0,
                                      __ATOMIC_ACQUIRE, __ATOMIC_RELAXED )) return;

    window_ns = ios_srv_ticks_to_ns( now - ios_srv_stats_window_t0 );
    ios_srv_stats_window_t0 = now;
    if (!window_ns) window_ns = 1;

    for (i = 0; i < REQ_NB_REQUESTS; i++)
    {
        counts[i] = __atomic_exchange_n( &ios_srv_kind_count[i], 0, __ATOMIC_RELAXED );
        ticks[i]  = __atomic_exchange_n( &ios_srv_kind_ticks[i], 0, __ATOMIC_RELAXED );
        total    += counts[i];
        total_ns += ios_srv_ticks_to_ns( ticks[i] );
    }
    for (i = 0; i < IOS_SRV_THR_SLOTS; i++)
        thr_counts[i] = __atomic_exchange_n( &ios_srv_thr_count[i], 0, __ATOMIC_RELAXED );
    for (i = 0; i < IOS_NT_COUNTER_MAX; i++)
        nt[i] = __atomic_exchange_n( &ios_srv_nt_counts[i], 0, __ATOMIC_RELAXED );

    if (!total && !nt[IOS_NT_DELAY_ZERO] && !nt[IOS_NT_ALERT_WAIT] &&
        !nt[IOS_NT_FAST_HIT] && !nt[IOS_NT_FAST_MISS] && !nt[IOS_FS_LEARN_EVENT] &&
        !nt[IOS_FS_LEARN_NONE] && !nt[IOS_FS_EVICT] && !nt[IOS_FS_POLLPEEK])
    {
        __atomic_store_n( &ios_srv_stats_busy, 0, __ATOMIC_RELEASE );
        return;
    }

    /* selection sort of the top N; N is tiny, the arrays are not sorted */
    for (i = 0; i < IOS_SRV_STATS_TOP_KINDS; i++)
    {
        unsigned int best = 0, best_n = 0;
        for (j = 0; j < REQ_NB_REQUESTS; j++)
        {
            int dup = 0;
            for (n = 0; n < i; n++) if (top_kind[n] == (unsigned int)j) dup = 1;
            if (dup || counts[j] <= best_n) continue;
            best = j; best_n = counts[j];
        }
        top_kind[i] = best_n ? best : REQ_NB_REQUESTS;
    }
    for (i = 0; i < IOS_SRV_STATS_TOP_THR; i++)
    {
        unsigned int best = IOS_SRV_THR_SLOTS, best_n = 0;
        for (j = 0; j < IOS_SRV_THR_SLOTS; j++)
        {
            int dup = 0;
            for (n = 0; n < i; n++) if (top_thr[n] == (unsigned int)j) dup = 1;
            if (dup || thr_counts[j] <= best_n) continue;
            best = j; best_n = thr_counts[j];
        }
        top_thr[i] = best_n ? best : IOS_SRV_THR_SLOTS;
    }

    /* line 1: the headline — how much wall time this task spent inside the
     * round trip, as a fraction of ONE core-second per second. */
    wine_log_write( "[srv-stats] %llums reqs=%u (%llu/s) in-call=%llums (%llu.%02llu core) rev=ml951",
                    window_ns / 1000000ull, total,
                    (unsigned long long)total * 1000000000ull / window_ns,
                    total_ns / 1000000ull,
                    total_ns / window_ns,
                    total_ns * 100ull / window_ns % 100ull );

    /* snprintf returns the length it WOULD have written, so `len` must be
     * clamped back to the buffer before it is used as an offset again — an
     * unclamped len makes `sizeof(line) - len` underflow to a huge size_t on
     * the next iteration, which is a buffer overrun, not a truncation. */
#define IOS_SRV_APPEND(...)                                                        \
    do {                                                                           \
        int _w = snprintf( line + len, sizeof(line) - len, __VA_ARGS__ );           \
        if (_w < 0) break;                                                         \
        len += _w;                                                                 \
        if (len > (int)sizeof(line) - 1) len = (int)sizeof(line) - 1;               \
    } while (0)

    len = snprintf( line, sizeof(line), "[srv-stats]   kinds:" );
    for (i = 0; i < IOS_SRV_STATS_TOP_KINDS && len < (int)sizeof(line) - 1; i++)
    {
        unsigned int k = top_kind[i];
        if (k >= REQ_NB_REQUESTS) break;
        IOS_SRV_APPEND( " %s=%u/%lluus", ios_srv_req_names[k], counts[k],
                        ios_srv_ticks_to_ns( ticks[k] ) / 1000ull / counts[k] );
    }
    wine_log_write( "%s", line );

    /* ml970: and WHAT called each of them.  Two names per kind at most -- the
     * question this answers is "who owns this traffic", and a kind with a
     * genuine long tail of callers says so through `+N more'. */
    len = snprintf( line, sizeof(line), "[srv-stats]   kinds-by-caller:" );
    for (i = 0; i < 8 && len < (int)sizeof(line) - 1; i++)
    {
        unsigned int k = top_kind[i], shown = 0;
        int c;

        if (k >= REQ_NB_REQUESTS) break;
        IOS_SRV_APPEND( " %s:", ios_srv_req_names[k] );
        for (c = 0; c < IOS_SRV_CALLER_SLOTS && shown < 2; c++)
        {
            unsigned int n = __atomic_exchange_n( &ios_srv_caller_n[k][c], 0, __ATOMIC_RELAXED );
            uintptr_t pc = __atomic_load_n( &ios_srv_caller_pc[k][c], __ATOMIC_RELAXED );
            Dl_info di;

            if (!n || !pc) continue;
            shown++;
            if (dladdr( (void *)pc, &di ) && di.dli_sname && di.dli_saddr)
                IOS_SRV_APPEND( " %s+0x%llx=%u", di.dli_sname,
                                (unsigned long long)(pc - (uintptr_t)di.dli_saddr), n );
            else
                IOS_SRV_APPEND( " 0x%llx=%u", (unsigned long long)pc, n );
        }
        /* drain whatever the two-name cap left behind so the next window is
         * not skewed by this one's residue */
        for (; c < IOS_SRV_CALLER_SLOTS; c++)
            __atomic_exchange_n( &ios_srv_caller_n[k][c], 0, __ATOMIC_RELAXED );
        {
            unsigned int other = __atomic_exchange_n( &ios_srv_caller_other[k], 0, __ATOMIC_RELAXED );
            if (other) IOS_SRV_APPEND( " +%u more", other );
        }
        IOS_SRV_APPEND( " |" );
    }
    wine_log_write( "%s", line );

    len = snprintf( line, sizeof(line), "[srv-stats]   threads:" );
    for (i = 0; i < IOS_SRV_STATS_TOP_THR && len < (int)sizeof(line) - 1; i++)
    {
        unsigned int s = top_thr[i];
        if (s >= IOS_SRV_THR_SLOTS) break;
        IOS_SRV_APPEND( " tid=%04x:%u",
                        __atomic_load_n( &ios_srv_thr_tid[s], __ATOMIC_RELAXED ),
                        thr_counts[s] );
    }
    wine_log_write( "%s", line );

    wine_log_write( "[srv-stats]   nt: setev=%u resetev=%u pulse=%u wait1=%u waitN=%u sigwait=%u "
                    "relsem=%u relmut=%u sleep0=%u sleepN=%u yield_sc=%u park=%u",
                    nt[IOS_NT_SET_EVENT], nt[IOS_NT_RESET_EVENT], nt[IOS_NT_PULSE_EVENT],
                    nt[IOS_NT_WAIT_SINGLE], nt[IOS_NT_WAIT_MULTI], nt[IOS_NT_SIGNAL_AND_WAIT],
                    nt[IOS_NT_RELEASE_SEM], nt[IOS_NT_RELEASE_MUTANT],
                    nt[IOS_NT_DELAY_ZERO], nt[IOS_NT_DELAY_NONZERO], nt[IOS_NT_YIELD_SYSCALL],
                    nt[IOS_NT_SLEEP0_PARK] );

    /* ml951: who is calling NtQueryInformationThread 10 k times a second.
     * `cached' are the ones the client-side self cache answered with no
     * server round trip at all; basic_other is the residue that still needs
     * the server (a handle to a DIFFERENT thread — typically an exit-code or
     * priority poll on a worker, which cannot be cached). */
    {
        unsigned int ti[IOS_TI_COUNTER_MAX];
        unsigned int k;

        for (k = 0; k < IOS_TI_COUNTER_MAX; k++)
            ti[k] = __atomic_exchange_n( &ios_srv_thrinfo_counts[k], 0, __ATOMIC_RELAXED );

        if (ti[IOS_TI_BASIC_SELF] || ti[IOS_TI_BASIC_OTHER] || ti[IOS_TI_AFFINITY] ||
            ti[IOS_TI_AMILAST] || ti[IOS_TI_TERMINATED] || ti[IOS_TI_SUSPEND] ||
            ti[IOS_TI_START_ADDR] || ti[IOS_TI_NAME] || ti[IOS_TI_OTHER_CLASS] ||
            ti[IOS_TI_TIMES] || ti[IOS_TI_SET])
            wine_log_write( "[thrinfo] basic self=%u (cached=%u) other=%u | affinity=%u (cached=%u) "
                            "| times=%u amilast=%u terminated=%u suspend=%u startaddr=%u name=%u "
                            "other_class=%u | set=%u",
                            ti[IOS_TI_BASIC_SELF], ti[IOS_TI_BASIC_CACHED], ti[IOS_TI_BASIC_OTHER],
                            ti[IOS_TI_AFFINITY], ti[IOS_TI_AFFINITY_CACHED], ti[IOS_TI_TIMES],
                            ti[IOS_TI_AMILAST], ti[IOS_TI_TERMINATED], ti[IOS_TI_SUSPEND],
                            ti[IOS_TI_START_ADDR], ti[IOS_TI_NAME], ti[IOS_TI_OTHER_CLASS],
                            ti[IOS_TI_SET] );
    }

    /* The alert ping-pong is NOT server-backed on this target: USE_FUTEX is
     * defined for __APPLE__ in sync.c, so NtAlertThreadByThreadId is an
     * InterlockedExchange plus os_sync_wake_by_address_any and
     * NtWaitForAlertByThreadId is os_sync_wait_on_address.  Neither appears
     * in reqs= above; they are reported here so [alert-storm] can be sized
     * against the server traffic rather than confused with it. */
    /* The decisive line for "what is the select traffic actually made of".
     * *_inf is nearly free (one request, then the thread is off the CPU until
     * something signals); *_fin and *_poll are the ones that cost a round trip
     * per iteration, and tmo_fin says how many of the finite ones bought
     * nothing but a STATUS_TIMEOUT. */
    wine_log_write( "[srv-stats]   select: w1 inf=%u fin=%u poll=%u | wN inf=%u fin=%u poll=%u | "
                    "all=%u sigwait=%u keyed=%u delay=%u other=%u | tmo=%u tmo_fin=%u",
                    nt[IOS_SEL_WAIT1_INF], nt[IOS_SEL_WAIT1_FIN], nt[IOS_SEL_WAIT1_POLL],
                    nt[IOS_SEL_WAITN_INF], nt[IOS_SEL_WAITN_FIN], nt[IOS_SEL_WAITN_POLL],
                    nt[IOS_SEL_WAITALL], nt[IOS_SEL_SIGWAIT], nt[IOS_SEL_KEYED],
                    nt[IOS_SEL_DELAY_ALERT], nt[IOS_SEL_OTHER],
                    nt[IOS_SEL_RET_TIMEOUT], nt[IOS_SEL_RET_TIMEOUT_FIN] );

    /* ml970: the spin governor's own distribution (sync.c).  `sleep0'/`yield'
     * are the GOVERNED calls, `sys' the syscalls those calls actually cost --
     * the ratio between them is the whole point of the governor, and p50/p80
     * are the time-to-progress percentiles the park ladder is sized against. */
    {
        struct ios_spin_snapshot sp;
        unsigned int b;

        ios_spin_hist_snapshot( &sp );
        if (sp.streaks || sp.gov_sleep0 || sp.gov_yield)
        {
            wine_log_write( "[sleep0] streaks=%u calls: sleep0=%u yield=%u | syscalls: yield=%u park=%u "
                            "(%llu/s) | per-call=%u.%03u%% | to-progress p50=%uus p80=%uus warm=%u rev=ml970",
                            sp.streaks, sp.gov_sleep0, sp.gov_yield, sp.sys_yield, sp.sys_park,
                            ((unsigned long long)sp.sys_yield + sp.sys_park) * 1000000000ull / window_ns,
                            (sp.gov_sleep0 + sp.gov_yield)
                              ? (sp.sys_yield + sp.sys_park) * 100u / (sp.gov_sleep0 + sp.gov_yield) : 0,
                            (sp.gov_sleep0 + sp.gov_yield)
                              ? (unsigned int)(((unsigned long long)(sp.sys_yield + sp.sys_park) * 100000ull /
                                                (sp.gov_sleep0 + sp.gov_yield)) % 1000ull) : 0,
                            sp.us_p50, sp.us_p80, sp.warm_hits );

            len = snprintf( line, sizeof(line), "[sleep0]   hist calls:" );
            for (b = 0; b < IOS_SPIN_HIST_N; b++)
                if (sp.calls[b]) IOS_SRV_APPEND( " %u=%u", 1u << b, sp.calls[b] );
            wine_log_write( "%s", line );

            len = snprintf( line, sizeof(line), "[sleep0]   hist us:" );
            for (b = 0; b < IOS_SPIN_HIST_N; b++)
                if (sp.us[b]) IOS_SRV_APPEND( " %u=%u", b ? 1u << b : 0u, sp.us[b] );
            wine_log_write( "%s", line );
        }
    }

    wine_log_write( "[srv-stats]   futex(no server): alert_wait=%u alert_wake=%u | "
                    "fast hit=%u miss=%u wake=%u sleep=%u",
                    nt[IOS_NT_ALERT_WAIT], nt[IOS_NT_ALERT_WAKE],
                    nt[IOS_NT_FAST_HIT], nt[IOS_NT_FAST_MISS],
                    nt[IOS_NT_FAST_WAKE], nt[IOS_NT_FAST_SLEEP] );

    /* ml962: the cache's own behaviour.  learn_ev+learn_none must track
     * get_inproc_sync_fd in the kinds line above; if it does and both stay
     * high while relearn is high too, the (handle>>2) slot is being fought
     * over rather than warmed.
     *
     * ml972: ... and each number now comes with the RUNNING TOTAL in
     * parentheses.  The ml962 line printed window deltas only, and a warm
     * cache legitimately learns nothing for minutes at a time -- so "all five
     * zero" could mean either "nothing happened this window" or "this code
     * never runs", and on the device it meant the latter for evict (NtClose is
     * server_ios.c's, and it was missing the call: see NtClose below).  A
     * total that is still zero after the process has been up for a while is
     * now unambiguous evidence that the counter is not wired, which is the
     * only reading that tells you to go and look at the call site. */
    {
        static unsigned int fs_total[10];
        fs_total[0] += nt[IOS_FS_LEARN_EVENT];
        fs_total[1] += nt[IOS_FS_LEARN_NONE];
        fs_total[2] += nt[IOS_FS_RELEARN];
        fs_total[3] += nt[IOS_FS_STALE_GEN];
        fs_total[4] += nt[IOS_FS_EVICT];
        fs_total[5] += nt[IOS_FS_POLLPEEK];
        fs_total[6] += nt[IOS_FS_WATCHDOG];
        fs_total[7] += nt[IOS_FS_DESYNC];
        fs_total[8] += nt[IOS_FS_SEM_REL];
        fs_total[9] += nt[IOS_FS_SEM_WAIT];
        wine_log_write( "[srv-stats]   fastsync cache: learn_ev=%u(%u) learn_none=%u(%u) "
                        "relearn=%u(%u) stale_gen=%u(%u) evict=%u(%u)",
                        nt[IOS_FS_LEARN_EVENT], fs_total[0],
                        nt[IOS_FS_LEARN_NONE],  fs_total[1],
                        nt[IOS_FS_RELEARN],     fs_total[2],
                        nt[IOS_FS_STALE_GEN],   fs_total[3],
                        nt[IOS_FS_EVICT],       fs_total[4] );
        /* ml982: pollpeek is the request kind that is NOT in `reqs=' because it
         * never happened -- so it is printed next to the w1 poll= count it came
         * out of.  desync is the only number here that is ever alarming. */
        wine_log_write( "[srv-stats]   fastsync served: pollpeek=%u(%u) [w1 poll left=%u] "
                        "watchdog=%u(%u) desync=%u(%u) sem_rel=%u(%u) sem_wait=%u(%u) "
                        "[NtReleaseSemaphore=%u]",
                        nt[IOS_FS_POLLPEEK], fs_total[5], nt[IOS_SEL_WAIT1_POLL],
                        nt[IOS_FS_WATCHDOG], fs_total[6],
                        nt[IOS_FS_DESYNC],   fs_total[7],
                        nt[IOS_FS_SEM_REL],  fs_total[8],
                        nt[IOS_FS_SEM_WAIT], fs_total[9],
                        nt[IOS_NT_RELEASE_SEM] );

        /* ml1110: THE LATE-WAKE CENSUS.  See build/ntdll-unix/shims/ios_late_wake.h.
         *
         * `tmo_fin=' above says how many finite waits bought nothing but a
         * STATUS_TIMEOUT; it cannot say whether the object was signalled when
         * the timer fired, and that single bit is the difference between "the
         * program asked for a poll and got one" and "a hand-off is being
         * delivered by a timer".  This block answers it, with the age of the
         * token so an honest race (a few microseconds) is not read as a lost
         * wake (hundreds, or milliseconds). */
        {
            struct ios_late_snapshot lw;
            unsigned int i;

            madeira_late_wake_snapshot( &lw );
            if (lw.tmo_fin || lw.hb || lw.rescued)
            {
                wine_log_write( "[late-wake] ml1110 %llums: tmo_fin=%u late=%u (sem=%u event=%u "
                                "no-stamp=%u) age p50=%uus p90=%uus | heartbeat: expiries=%u "
                                "late=%u rescued=%u",
                                window_ns / 1000000ull, lw.tmo_fin,
                                lw.late_sem + lw.late_event, lw.late_sem, lw.late_event,
                                lw.nostamp, lw.age_p50, lw.age_p90,
                                lw.hb, lw.hb_late, lw.rescued );

                if (lw.late_sem + lw.late_event)
                {
                    len = snprintf( line, sizeof(line), "[late-wake]   age us:" );
                    for (i = 0; i < IOS_LATE_AGE_N; i++)
                        if (lw.age[i])
                            IOS_SRV_APPEND( " %u=%u", i ? (1u << (i - 1)) : 0u, lw.age[i] );
                    wine_log_write( "%s", line );
                }

                for (i = 0; i < IOS_LATE_HOT_N; i++)
                    if (lw.hot[i].cell != 0xffffffffu && lw.hot[i].late)
                        wine_log_write( "[late-wake]   #%u cell=%u obj=%s late=%u", i + 1,
                                        lw.hot[i].cell,
                                        lw.hot[i].kind == MADEIRA_CELL_KIND_SEM ? "sem" : "event",
                                        lw.hot[i].late );
            }
        }

        /* ml982: the "auto" rule.  This reporter is the only thing in the image
         * that already knows the task's request rate, so the rule costs nothing
         * of its own.  A no-op unless MADEIRA_FASTSYNC=auto. */
        {
            extern void madeira_fastsync_auto_arm( unsigned int ops, unsigned long long window_ns );
            /* ml1010: NtReleaseSemaphore joins the traffic estimate.  A title
             * whose handoffs are semaphores rather than events was previously
             * invisible to this rule except through its select half, which on
             * the motivating measurement was still enough -- but the rule is
             * supposed to measure the traffic the fast path can remove, and
             * that now includes the release side. */
            madeira_fastsync_auto_arm( nt[IOS_NT_SET_EVENT] + nt[IOS_NT_RESET_EVENT] +
                                       nt[IOS_NT_RELEASE_SEM] +
                                       nt[IOS_SEL_WAIT1_INF] + nt[IOS_SEL_WAIT1_FIN] +
                                       nt[IOS_SEL_WAIT1_POLL] + nt[IOS_FS_POLLPEEK],
                                       window_ns );
        }
    }

#undef IOS_SRV_APPEND

    __atomic_store_n( &ios_srv_stats_busy, 0, __ATOMIC_RELEASE );
}

/* ml962: print one report immediately, wherever the caller is.  The 10 s
 * window reporter is piggy-backed on server traffic, so a process that dies
 * in its first few seconds -- which is exactly the case the fastsync counters
 * are needed for -- used to produce no [srv-stats] at all.  Called from the
 * MADEIRA-EXIT path in process_ios.c. */
void ios_srv_stats_report_now(void)
{
    if (!ios_srv_stats_enabled()) return;
    wine_log_write( "[srv-stats] final report (process exit)" );
    ios_srv_stats_report( mach_absolute_time() );
}

/* ml990: THE COMPACT QUIET-BUILD SUMMARY.
 *
 * Called once every 10 s from the pool-warmer heartbeat when MADEIRA_DIAG is
 * off, in place of the ~60 lines the full reporters print between them.  It
 * measures nothing of its own: every number here is already being counted for
 * another reason -- the footprint came from the heartbeat's own task_info(),
 * the request counts are the ones ios_srv_stats_account() maintains on the
 * server path regardless, and the fastsync counters are relaxed adds on paths
 * that were going to touch that cache line anyway.  Summing REQ_NB_REQUESTS
 * slots once per ten seconds is free.
 *
 * fps is deliberately absent: the app knows it and prints it, and duplicating
 * it here would mean a frame counter on a path that has none.
 *
 * Deltas, not totals, because the question this line answers is "is the server
 * traffic collapsing the way fastsync says it should" -- which only a rate can
 * answer. */
void ios_perf_line( unsigned long long phys_mb, unsigned long long peak_mb,
                    unsigned long long comp_mb )
{
    static unsigned long long prev_reqs, prev_ns;
    static unsigned int prev_hit, prev_miss, prev_peek, prev_desync, prev_ops;
    static unsigned int prev_srel, prev_swait;
    unsigned long long reqs = 0, now_ns, win_ns;
    unsigned int hit, miss, peek, desync, ops, srel, swait;
    unsigned int i;

    for (i = 0; i < REQ_NB_REQUESTS; i++)
        reqs += __atomic_load_n( &ios_srv_kind_count[i], __ATOMIC_RELAXED );

    hit    = __atomic_load_n( &ios_srv_nt_counts[IOS_NT_FAST_HIT],  __ATOMIC_RELAXED );
    miss   = __atomic_load_n( &ios_srv_nt_counts[IOS_NT_FAST_MISS], __ATOMIC_RELAXED );
    peek   = __atomic_load_n( &ios_srv_nt_counts[IOS_FS_POLLPEEK],  __ATOMIC_RELAXED );
    desync = __atomic_load_n( &ios_srv_nt_counts[IOS_FS_DESYNC],    __ATOMIC_RELAXED );
    srel   = __atomic_load_n( &ios_srv_nt_counts[IOS_FS_SEM_REL],   __ATOMIC_RELAXED );
    swait  = __atomic_load_n( &ios_srv_nt_counts[IOS_FS_SEM_WAIT],  __ATOMIC_RELAXED );

    /* The counters the "auto" rule has always been fed, plus ml1010's
     * NtReleaseSemaphore: see the identical sum in ios_srv_stats_report(). */
    ops = __atomic_load_n( &ios_srv_nt_counts[IOS_NT_SET_EVENT],   __ATOMIC_RELAXED )
        + __atomic_load_n( &ios_srv_nt_counts[IOS_NT_RESET_EVENT], __ATOMIC_RELAXED )
        + __atomic_load_n( &ios_srv_nt_counts[IOS_NT_RELEASE_SEM], __ATOMIC_RELAXED )
        + __atomic_load_n( &ios_srv_nt_counts[IOS_SEL_WAIT1_INF],  __ATOMIC_RELAXED )
        + __atomic_load_n( &ios_srv_nt_counts[IOS_SEL_WAIT1_FIN],  __ATOMIC_RELAXED )
        + __atomic_load_n( &ios_srv_nt_counts[IOS_SEL_WAIT1_POLL], __ATOMIC_RELAXED )
        + peek;

    now_ns = ios_srv_ticks_to_ns( mach_absolute_time() );
    win_ns = now_ns - prev_ns;
    if (prev_ns && win_ns >= 1000000ull)
    {
        /* ml1001: the guest's own clock, in the one line a quiet build prints.
         *
         * GetTickCount64() is three loads from KUSER_SHARED_DATA and nothing
         * else, so this IS what every guest program is being told the time is.
         * It sat at 0 for the whole life of this port and no log could show
         * that, because a clock only reveals itself through the program that
         * trips over it.  One relaxed 64-bit read every ten seconds; a value
         * that does not advance between two [perf] lines is the whole bug. */
        {
            extern struct _KUSER_SHARED_DATA *user_shared_data;
            unsigned long long usd_ms = 0;
            unsigned int late_rescued = 0, late_total;
            /* The pointer starts life as the canonical 0x7ffe0000, which XNU's
             * 4 GB __PAGEZERO makes unreadable, and only becomes a real address
             * once virtual_alloc_first_teb() has run.  This reporter cannot run
             * that early, but a diagnostic must not be the thing that decides
             * that: read only an address that is plainly past __PAGEZERO. */
            if ((unsigned long long)(uintptr_t)user_shared_data > 0x100000000ull)
                usd_ms = ((unsigned long long)user_shared_data->TickCount.High1Time << 32)
                         | user_shared_data->TickCount.LowPart;
            /* ml1060: `lostwake' is the server-side detector in
             * build/wineserver/queue_ios.c (ios_scan_lost_wakeups): the number
             * of times a thread was found queued on a cell-backed object across
             * two consecutive 5 s scans while that object's cell said signalled.
             * Each one was also self-healed with a wake_up(), so a non-zero
             * value here means the run SURVIVED a lost wakeup rather than hung
             * on it -- and the [lost-wake] line names the object.  The counter
             * lives in the wineserver archive, the same cross-archive direction
             * as madeira_sync_cells. */
            extern unsigned int madeira_lostwake_count;
            /* ml1110: `late' and `rescued' are the always-on half of the
             * late-wake census (build/ntdll-unix/shims/ios_late_wake.h).  Both
             * are RUNNING TOTALS here rather than window deltas, because the
             * quiet build has no other reader and a delta that has to be
             * differenced by hand across a log is not a number anybody reads.
             * late>0 says some hand-off was delivered by a timer rather than
             * by a wake; rescued>0 says this port's own heartbeat is what
             * delivered it.  MADEIRA_DIAG=1 turns on [late-wake], which says
             * WHICH object and how old the token was. */
            late_total = madeira_late_wake_peek( &late_rescued );
            wine_log_write( "[perf] rev=ml1110 phys=%lluMB(peak %llu, comp %llu) srv=%llu/s "
                            "fastsync hit=%u miss=%u peek=%u sem_rel=%u sem_wait=%u "
                            "desync=%u lostwake=%u late=%u rescued=%u tick=%llums"
                            " - MADEIRA_DIAG=1 for the full reporters",
                            phys_mb, peak_mb, comp_mb,
                            (reqs - prev_reqs) * 1000000000ull / win_ns,
                            hit - prev_hit, miss - prev_miss, peek - prev_peek,
                            srel - prev_srel, swait - prev_swait,
                            desync - prev_desync,
                            __atomic_load_n( &madeira_lostwake_count, __ATOMIC_RELAXED ),
                            late_total, late_rescued,
                            usd_ms );
        }

        /* ml990: THE "auto" RULE MOVED HERE, AND IT HAD TO.
         *
         * ml982 put it inside ios_srv_stats_report(), on the reasoning that
         * the reporter was "the only thing in the image that already knows the
         * task's request rate".  That was true then.  Now the report is behind
         * MADEIRA_DIAG and the default is MADEIRA_FASTSYNC=auto, so leaving
         * the rule there would have meant the wake path never arming in a
         * shipping build -- the default would have been auto in name only.
         *
         * The two callers are mutually exclusive by construction: this line
         * only runs when MADEIRA_DIAG is off, and the reporter only runs when
         * it is on.  Never both, so never a double count.  (Arming twice would
         * be harmless anyway -- madeira_fastsync_auto_arm latches with an
         * exchange -- but "harmless" is not the same as "correct".) */
        {
            extern void madeira_fastsync_auto_arm( unsigned int ops, unsigned long long window_ns );
            madeira_fastsync_auto_arm( ops - prev_ops, win_ns );
        }

        /* ml1050: the frame critical path, next to the line it belongs with.
         * This runs in the QUIET build too -- what bounds a frame is not a
         * diagnostic, it is the thing the port is being optimised against. */
        ios_frame_report( win_ns );
    }

    prev_reqs = reqs; prev_ns = now_ns; prev_ops = ops;
    prev_hit = hit; prev_miss = miss; prev_peek = peek; prev_desync = desync;
    prev_srel = srel; prev_swait = swait;
}

static inline void ios_srv_stats_account( unsigned int kind, unsigned long long t0, uintptr_t caller )
{
    /* ml990: the SECOND clock read is as gated as the first -- reading it here
     * and discarding it would have left the quiet build paying for exactly the
     * thing the gate exists to remove. */
    unsigned long long now = t0 ? mach_absolute_time() : 0;
    TEB *teb;

    if (kind < REQ_NB_REQUESTS)
    {
        __atomic_fetch_add( &ios_srv_kind_count[kind], 1, __ATOMIC_RELAXED );
        /* ml990: t0 == 0 means the quiet build did not read the clock, so
         * there is no duration to charge and nothing downstream reads the
         * per-kind ticks. The COUNT above is what [perf] differences. */
        if (t0) __atomic_fetch_add( &ios_srv_kind_ticks[kind], now - t0, __ATOMIC_RELAXED );
    }
    if (!__atomic_load_n( &ios_srv_report_on, __ATOMIC_RELAXED )) return;

    teb = NtCurrentTeb();
    ios_srv_caller_bump( kind, caller );
    ios_srv_thr_bump( teb ? (unsigned int)(ULONG_PTR)teb->ClientId.UniqueThread : 0 );

    if (now >= __atomic_load_n( &ios_srv_stats_deadline, __ATOMIC_RELAXED ))
    {
        unsigned long long expect = __atomic_load_n( &ios_srv_stats_deadline, __ATOMIC_RELAXED );
        if (now >= expect &&
            __atomic_compare_exchange_n( &ios_srv_stats_deadline, &expect,
                                         now + ios_srv_ns_to_ticks( IOS_SRV_STATS_PERIOD_S * 1000000000ull ),
                                         0, __ATOMIC_RELAXED, __ATOMIC_RELAXED ))
            ios_srv_stats_report( now );
    }
}

/* Bucket one server_wait by what it is actually waiting on and how long for.
 * Called from server_wait, which is the only place that still has the CALLER's
 * timeout — by the time server_select sees it, a relative timeout has already
 * been folded into a QPC-epoch absolute and a zero-timeout poll is no longer
 * distinguishable from a 1 ms one.  `size` is how NtWaitForMultipleObjects
 * encodes the handle count (offsetof(wait.handles[count])), which is the same
 * arithmetic ios_wait_enter already does above. */
static void ios_srv_classify_select( const union select_op *op, data_size_t size,
                                     const LARGE_INTEGER *timeout )
{
    int inf = !timeout, poll = timeout && !timeout->QuadPart;
    int count = 1;

    if (__atomic_load_n( &ios_srv_stats_on, __ATOMIC_RELAXED ) == 0) return;

    if (!op)   /* alertable NtDelayExecution: server_wait( NULL, 0, ... ) */
    {
        ios_srv_nt_count( IOS_SEL_DELAY_ALERT );
        return;
    }

    if (size >= offsetof( union select_op, wait.handles ))
        count = (int)((size - offsetof( union select_op, wait.handles )) / sizeof(obj_handle_t));
    if (count < 1) count = 1;

    switch (op->op)
    {
    case SELECT_WAIT:
        if (count > 1) ios_srv_nt_count( inf ? IOS_SEL_WAITN_INF : poll ? IOS_SEL_WAITN_POLL : IOS_SEL_WAITN_FIN );
        else           ios_srv_nt_count( inf ? IOS_SEL_WAIT1_INF : poll ? IOS_SEL_WAIT1_POLL : IOS_SEL_WAIT1_FIN );
        break;
    case SELECT_WAIT_ALL:           ios_srv_nt_count( IOS_SEL_WAITALL ); break;
    case SELECT_SIGNAL_AND_WAIT:    ios_srv_nt_count( IOS_SEL_SIGWAIT ); break;
    case SELECT_KEYED_EVENT_WAIT:
    case SELECT_KEYED_EVENT_RELEASE: ios_srv_nt_count( IOS_SEL_KEYED ); break;
    default:                        ios_srv_nt_count( IOS_SEL_OTHER ); break;
    }
}

static int ios_srv_stats_enabled(void)
{
    int on = __atomic_load_n( &ios_srv_stats_on, __ATOMIC_RELAXED );

    if (on < 0)
    {
        /* ml990: TWO gates now, because counting and reporting have very
         * different costs and very different value in a shipping run.
         *
         *   ios_srv_stats_on      the COUNTING.  Stays on unless
         *                         MADEIRA_SRV_STATS=0, because the compact
         *                         [perf] line differences these counters and
         *                         they are a few relaxed adds on a path that
         *                         fastsync has already taken from ~40 k/s to a
         *                         few thousand per second.
         *   ios_srv_report_on     the ten-line REPORT, and with it the two
         *                         mach_absolute_time() calls and the caller-PC
         *                         frame hop that only the report consumes.
         *                         Follows MADEIRA_DIAG, or MADEIRA_SRV_STATS
         *                         set to anything but 0. */
        extern int madeira_diag_on( void );
        const char *e = getenv( "MADEIRA_SRV_STATS" );
        on = (e && !strcmp( e, "0" )) ? 0 : 1;
        __atomic_store_n( &ios_srv_report_on,
                          on && (e || madeira_diag_on()) ? 1 : 0, __ATOMIC_RELAXED );
        if (on)
        {
            /* The window is armed either way: the MADEIRA-EXIT forced report
             * has to be able to divide by a real window even in a quiet run. */
            unsigned long long now = mach_absolute_time();
            ios_srv_stats_window_t0 = now;
            __atomic_store_n( &ios_srv_stats_deadline,
                              now + ios_srv_ns_to_ticks( IOS_SRV_STATS_PERIOD_S * 1000000000ull ),
                              __ATOMIC_RELAXED );
            if (__atomic_load_n( &ios_srv_report_on, __ATOMIC_RELAXED ))
                wine_log_write( "[srv-stats] ON rev=ml990 period=%ds — per-kind wineserver traffic; "
                                "MADEIRA_SRV_STATS=0 to disable", IOS_SRV_STATS_PERIOD_S );
            else
                wine_log_write( "[srv-stats] counting only (rev=ml990) — the per-kind report is "
                                "behind MADEIRA_DIAG=1; the compact [perf] line carries reqs/s" );
        }
        __atomic_store_n( &ios_srv_stats_on, on, __ATOMIC_RELAXED );
    }
    return on;
}

#endif /* WINE_IOS */

/***********************************************************************
 *           server_call_unlocked
 */
unsigned int server_call_unlocked( void *req_ptr )
{
    struct __server_request_info * const req = req_ptr;
    unsigned int ret;
#ifdef WINE_IOS
    const unsigned int stats_kind = req->u.req.request_header.req;
    const int stats_on = ios_srv_stats_enabled();
    /* ml990: the clock read and the caller-PC frame hop exist only to feed the
     * ten-line report, so they follow ios_srv_report_on, not ios_srv_stats_on.
     * The quiet build keeps the per-kind COUNT (which [perf] differences) and
     * pays one relaxed add for it. */
    const int stats_rep = stats_on && __atomic_load_n( &ios_srv_report_on, __ATOMIC_RELAXED );
    const unsigned long long stats_t0 = stats_rep ? mach_absolute_time() : 0;
    /* ml970: taken HERE, not inside ios_srv_stats_account(), because the
     * return address a static inline sees depends on whether it was inlined. */
    const uintptr_t stats_ra = stats_rep ? IOS_SRV_CALLER_PC() : 0;
#endif

    ios_srv_req_count++;
    if ((ret = send_request( req ))) return ret;
    /* iOS-Madeira 2026-07-05: kick the in-process server loop out of its
     * tick sleep so the request is picked up in ~50us instead of waiting
     * for the next 1ms iteration (fd_ios.c ios_srv_wake_sem). */
    {
        extern void ios_wineserver_wake(void);
        ios_wineserver_wake();
    }
    ret = wait_reply( req );
#ifdef WINE_IOS
    if (stats_on) ios_srv_stats_account( stats_kind, stats_t0, stats_ra );
#endif
    return ret;
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
#ifdef WINE_IOS
/* iOS-Madeira ml1650: fd_cache_mutex MUST NOT OUTLIVE ITS OWNER.
 *
 * One ntdll unix side serves every pseudo-process, so this is one lock for the
 * whole session. It is held across server calls (NtClose, NtDuplicateObject,
 * get_unix_fd), and a thread whose process is torn down in the middle of one
 * leaves through abort_thread/exit without ever reaching the leave call. With
 * Steam restarting itself after its update, both test devices ended with
 * steam.exe and the web helper parked in __psynch_mutexwait on this lock and no
 * live owner (the same shape as ml1090's user lock). Record the owner, and let
 * every thread-exit path give the lock back if the exiting thread holds it.
 * MADEIRA_FD_CACHE_LOCK_DROP=0 disables the release (the owner is still logged). */
static pthread_t ios_fd_cache_owner;
static void *ios_fd_cache_owner_at;
static volatile int ios_fd_cache_owned;

void ios_drop_fd_cache_lock( const char *why )
{
    static int enabled = -1;
    if (!ios_fd_cache_owned || !pthread_equal( ios_fd_cache_owner, pthread_self() )) return;
    if (enabled < 0) { const char *e = getenv( "MADEIRA_FD_CACHE_LOCK_DROP" ); enabled = !(e && e[0] == '0'); }
    dprintf( 2, "[fd-cache-lock] ml1650 %s: exiting thread mach=%#x holds fd_cache_mutex (taken at %p) -- %s\n",
             why, (unsigned)pthread_mach_thread_np( pthread_self() ), ios_fd_cache_owner_at,
             enabled ? "released" : "NOT released (MADEIRA_FD_CACHE_LOCK_DROP=0)" );
    if (!enabled) return;
    ios_fd_cache_owned = 0;
    pthread_mutex_unlock( &fd_cache_mutex );
}
#endif

void server_enter_uninterrupted_section( pthread_mutex_t *mutex, sigset_t *sigset )
{
    pthread_sigmask( SIG_BLOCK, &server_block_set, sigset );
    mutex_lock( mutex );
#ifdef WINE_IOS
    if (mutex == &fd_cache_mutex)
    {
        ios_fd_cache_owner = pthread_self();
        ios_fd_cache_owner_at = __builtin_return_address( 0 );
        ios_fd_cache_owned = 1;
    }
#endif
}


/***********************************************************************
 *           server_leave_uninterrupted_section
 */
void server_leave_uninterrupted_section( pthread_mutex_t *mutex, sigset_t *sigset )
{
#ifdef WINE_IOS
    if (mutex == &fd_cache_mutex) ios_fd_cache_owned = 0;
#endif
    mutex_unlock( mutex );
    pthread_sigmask( SIG_SETMASK, sigset, NULL );
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
            set_async_iosb( call->async_io.sb, result->async_io.status, info );
        }
        else result->async_io.status = STATUS_PENDING; /* restart it */
        break;
    }
    /* WOW64_DESIGN.md §2 "Namespace rule": in every APC below, `addr` is a
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
            SYSTEM_BASIC_INFORMATION sbi;
            SIZE_T limit_low, limit_high, align;

            virtual_get_system_info( &sbi, is_wow64() );
            limit_low = call->virtual_alloc_ex.limit_low;
            limit_high = min( (ULONG_PTR)sbi.HighestUserAddress, call->virtual_alloc_ex.limit_high );
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
            SYSTEM_BASIC_INFORMATION sbi;

            virtual_get_system_info( &sbi, is_wow64() );
            limit_high = min( (ULONG_PTR)sbi.HighestUserAddress, call->map_view_ex.limit_high );
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
    extern void ios_qos_refresh( void );   /* ml1510: see signal_arm64_ios.c */
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
    ios_qos_refresh();

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
/* iOS-Madeira ml940: consecutive zero-timeout (polling) waits per thread
 * before one sched_yield is spent on them; see the end of server_wait. */
#define IOS_SRV_YIELD_EVERY 64

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

/* ml2000 [spin-probe] gate: registered waits at least min_ms old (same torn-
 * read discipline as ios_dump_stuck_waits in queue_ios.c). */
static unsigned int ios_spin_long_waits( unsigned long long min_ms, unsigned int *oldest_tid,
                                         unsigned long long *oldest_ms )
{
    struct timespec ts;
    unsigned long long now_ns;
    unsigned int i, n = 0;

    *oldest_tid = 0; *oldest_ms = 0;
    clock_gettime( CLOCK_MONOTONIC, &ts );
    now_ns = (unsigned long long)ts.tv_sec * 1000000000ull + ts.tv_nsec;
    for (i = 0; i < IOS_WAITREG_SLOTS; i++)
    {
        struct ios_wait_entry *e = &ios_wait_reg[i];
        unsigned int s0 = e->seq, tid;
        unsigned long long t0, age;
        if (!(s0 & 1)) continue;
        t0 = e->t0_ns; tid = e->wine_tid;
        __sync_synchronize();
        if (e->seq != s0 || !t0 || now_ns < t0) continue;
        age = (now_ns - t0) / 1000000ull;
        if (age < min_ms) continue;
        n++;
        if (age > *oldest_ms) { *oldest_ms = age; *oldest_tid = tid; }
    }
    return n;
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
        /* ml1050: a SECOND, different notion of "the game thread".
         * ios_srv_game_teb is whichever thread ran server_init_process_done,
         * i.e. the process's initial thread -- which in a job-system title is
         * not the thread that presents. The frame instrument identifies the
         * presenting thread by the fact that it presents, so the two are asked
         * separately and neither is derived from the other. */
        int is_presenter = ios_frame_tracking();
        struct timespec t0, t1;

        /* ml950: a real wait ends any Sleep(0) streak this thread had going
         * (sync.c, ios_spin_governor) — a thread that blocks is not spinning. */
        { extern void ios_spin_reset(void); ios_spin_reset(); }
#ifdef WINE_IOS
        ios_srv_classify_select( select_op, size, timeout );
#endif
        if (is_game || is_presenter) clock_gettime( CLOCK_MONOTONIC, &t0 );
        ios_wait_enter( select_op, size, flags, abs_timeout,
                        __builtin_return_address(0) );
        ret = server_select( select_op, size, flags, abs_timeout, NULL, &apc );
        ios_wait_leave();
        if (is_presenter)
        {
            struct timespec tp;
            unsigned long long ns;
            clock_gettime( CLOCK_MONOTONIC, &tp );
            ns = (unsigned long long)((tp.tv_sec - t0.tv_sec) * 1000000000ll
                                      + (tp.tv_nsec - t0.tv_nsec));
            ios_frame_wait_add( IOS_FRAME_WAIT_SRV, ns );
            /* ml1100: and WHICH wait it was — see ios_frame_srv_site. Everything
             * here is already in registers; nothing is queried. */
            {
                unsigned int nobj = 1, h0 = 0;
                unsigned char tclass = !timeout ? 0 : (timeout->QuadPart ? 1 : 2);

                if (select_op && size >= offsetof( union select_op, wait.handles ))
                {
                    nobj = (unsigned int)((size - offsetof( union select_op, wait.handles ))
                                          / sizeof(obj_handle_t));
                    if (!nobj) nobj = 1;
                    else h0 = (unsigned int)select_op->wait.handles[0];
                }
                ios_frame_srv_site( __builtin_return_address(0), h0, nobj, tclass,
                                    ns, ret == STATUS_TIMEOUT );
            }
        }
#ifdef WINE_IOS
        if (ret == STATUS_TIMEOUT)
        {
            ios_srv_nt_count( IOS_SEL_RET_TIMEOUT );
            if (timeout && timeout->QuadPart) ios_srv_nt_count( IOS_SEL_RET_TIMEOUT_FIN );
        }
#endif
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
    /* iOS-Madeira ml940: that upstream comment (unchanged from
       wine/dlls/ntdll/unix/server.c:815 - this yield is upstream's, not a
       Madeira anti-livelock addition) is about modelling a priority boost,
       and nothing in Wine reads a status back from it.  A wait that timed
       out after a real interval has already been off the CPU for that
       interval, so the swtch_pri(0) was pure overhead on every timed-out
       server_wait.  Only a zero-timeout wait - a poll - can be spun on, so
       yield only for those, and only on every IOS_SRV_YIELD_EVERY'th
       CONSECUTIVE one, which is what tells a spinner from a poll that
       happens once per frame.  Per-thread streak, native TLS.  */
    if (ret == STATUS_TIMEOUT)
    {
        static __thread unsigned int ios_poll_streak;

        if (timeout && !timeout->QuadPart)
        {
            if (!(++ios_poll_streak % IOS_SRV_YIELD_EVERY)) NtYieldExecution();
        }
        else ios_poll_streak = 0;
    }
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
            madeira_fast_close( handle );   /* ml972 fastsync, see NtClose below */

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
    const char *env = getenv( "MADEIRA_FD_CACHE_RELEASE_FIX" );
    const int fixed = !env || strcmp( env, "0" );

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
            if (block[j].s.fd > 0 && (!fixed || block[j].s.type != FD_TYPE_INVALID))
            {
                /* ml1270: add_fd_to_cache stores fd+1 (zero means empty).
                 * Closing that encoded value closes an unrelated descriptor
                 * and leaks the real one. Invalid entries encode NTSTATUS,
                 * not a descriptor. Decode exactly as get_cached_fd does. */
                int fd = block[j].s.fd - (fixed ? 1 : 0);
                ios_fdt_note_close( fd, "fd-cache-release", peb );
                close( fd );
                closed++;
            }
        if (block != c->initial_block)
        {
            /* Additional blocks come from anon_mmap_alloc, not malloc. */
            if (fixed) munmap( block, FD_CACHE_BLOCK_SIZE * sizeof(*block) );
            else free( block );
        }
    }
    free( c );
    dprintf( 2, "[fd-cache-retire] ml1270 decoded=%d closed=%d\n", fixed, closed );
    dprintf( 2, "[fd-cache] rev=ml571 released peb=%p, closed %d cached fd(s)\n", peb, closed );
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
        SERVER_START_REQ( get_handle_fd )
        {
            req->handle = wine_server_obj_handle( handle );
            if (!(ret = wine_server_call( req )))
            {
                if (type) *type = reply->type;
                if (options) *options = reply->options;
                access = reply->access;
                if ((fd = wine_server_receive_fd( &fd_handle )) != -1)
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
/* Notify at the common exit wrapper, before reclaiming the PEB or its image:
 * a normal ExitProcess first marks exiting with a NULL handle, and its later
 * self-termination takes an early fast path in NtTerminateProcess. */
/* ml2000: the app's compositor keys window layers by the PEB of the process
 * that framed them, so the layers of a process that died without destroying
 * its windows (a crash, TerminateProcess) are retired at its exit. */
void *madeira_current_peb( void )
{
    TEB *teb = NtCurrentTeb();
    return teb ? teb->Peb : NULL;
}

static void ios_notify_process_exit( int status )
{
    extern void winios_process_exited( void *peb ) __attribute__((weak));
    PEB *peb = NtCurrentTeb() ? NtCurrentTeb()->Peb : NULL;
    if (winios_process_exited && peb) winios_process_exited( peb );   /* ml2000 */
}

void process_exit_wrapper( int status )
{
#ifdef WINE_IOS
    ios_notify_process_exit( status );
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
        /* ml571: drop this pseudo-process's fd cache and close what it held.
         * Must happen on the SAME identity used to key it, and before the JIT
         * reclaim below reuses anything. */
        {
            extern void ios_fd_cache_release( void *peb );
            ios_fd_cache_release( dead_peb );
        }
        /* Task #25: release this pseudo-process's JIT pool allocations
         * (module copies, trampolines, FEX CodeBuffers). Children only —
         * the session (else-branch) lives as long as the app. Reuse is
         * grace-delayed inside the allocator for laggard exit threads. */
        ios_jit_reclaim_process( dead_peb );
        /* WOW64_DESIGN.md §2: and its guest window, if it had one.  Here rather
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
    else close( fd_socket );
#else
    close( fd_socket );
#endif
    wine_log_write("[Wine ntdll/server] process_exit_wrapper(%d)", status );
    exit( status );  /* on iOS, wine_ios_exit shim longjmps back to wine_process_thread */
}


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

    /* ml982: this process owns no handles yet, so any entry in the shared
     * handle -> cell cache that carries OUR pid is a ghost left behind by a
     * dead pseudo-process whose id the server has since reissued to us.  See
     * madeira_fast_flush_pid() in ntdll/unix/sync.c for why that is a
     * correctness problem and not just a leak. */
    madeira_fast_flush_pid();

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
                } else {
                    wine_log_write("[Wine WATCHDOG %ds] thread_get_state failed: %d", secs, kr);
                }

                thread_resume(wine_mach_thread);
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
        /* ml1640: OPT-IN. These three suspend every thread in the task on a
         * timer. Up to ml1620 this fork never ran them, and with them on the
         * Steam client stalled on both test devices with steam.exe and the web
         * helper parked on fd_cache_mutex that nothing ever released; a Mach
         * suspend taken here can interleave with the server's own Mach
         * suspend/resume bookkeeping for SuspendThread. They are profilers, so
         * the default is off. MADEIRA_THREAD_SAMPLERS=1 turns them on. */
        {
            const char *ts = getenv( "MADEIRA_THREAD_SAMPLERS" );
            static int said;
            if (!(ts && ts[0] == '1'))
            {
                if (!said++) dprintf( 2, "[samplers] ml1640 thread-sample/xprobe/wprof off (MADEIRA_THREAD_SAMPLERS=1 enables)\n" );
                ios_ts_armed = 1;   /* never arm */
            }
        }
        if (__sync_bool_compare_and_swap(&ios_ts_armed, 0, 1))
        {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ ios_thread_sampler_main(); });
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ ios_xprobe_main(); });   /* ml1128 */
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ ios_wprof_main(); });   /* ml1129 */
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
        signal_start_thread( ios_cur_image_info()->TransferAddress, peb, suspend, NtCurrentTeb() );
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
        madeira_fast_close( source );   /* ml972 fastsync, see NtClose below */
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
    /* ml972 fastsync: THE EVICTION THAT WAS NEVER WIRED.
     *
     * dlls/ntdll/unix/server.c has carried this call since ml952, but that file
     * is not the one that gets compiled: build.sh substitutes THIS overlay for
     * server.c, so on the device NtClose never dropped anything from the
     * handle -> cell cache.  `[srv-stats] fastsync cache: ... evict=0' was not
     * a quiet cache, it was a dead call site.
     *
     * The consequence is worse than a stale-entry miss.  A positive entry is
     * validated against the CELL's generation, and a cell stays live as long as
     * its EVENT does -- not as long as this handle does.  So close a handle to
     * an event something else still holds (a duplicate, an inherited handle, a
     * named event opened twice), let the handle VALUE come back out of the
     * handle table for an unrelated object, and the cache still answers with
     * the old event's cell: handle value matches, pid matches, generation
     * matches.  NtSetEvent on the new handle then signals the OLD event, and a
     * wait on the new handle is satisfied by the OLD event's token.  With a
     * loader creating and closing events thousands of times a second that is a
     * handshake signalled to nobody: a worker that never resumes, and the
     * critical section it holds never released. */
    madeira_fast_close( handle );

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

    /* WOW64_DESIGN.md §2: the WoW64 module converted the OUTER args pointer
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
     * NOT converted here — see the gap list in the stage-C report.  No request
     * on the milestone-1 path (dbg output, file I/O, handle/console requests)
     * carries one. */
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
