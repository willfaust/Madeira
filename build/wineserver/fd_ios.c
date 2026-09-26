/*
 * Server-side file descriptor management
 *
 * Copyright (C) 2000, 2003 Alexandre Julliard
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


#include "config.h"
#include <os/log.h>
#include <mach/mach_time.h>
#include <mach/mach_init.h>
#include <mach/semaphore.h>
#include <mach/task.h>
#include <pthread.h>
#include <mach/mach_vm.h>
#include <mach/vm_region.h>
#include "wine_log_ios.h"

/* iOS-Madeira 2026-07-05: in-process request-wake semaphore. The iOS
 * server loop can't block in poll/kqueue (AF_UNIX invisible in the
 * sandbox), so it slept a fixed 1ms tick — meaning every client request
 * waited avg ~0.5ms (worst 1ms+) just to be NOTICED. Thumper does 8
 * zero-timeout WaitForSingleObject polls per frame; each paid ~1.15ms
 * of pure pickup+round-trip latency = the 55-vs-60 FPS gap. Clients
 * (ntdll's server_call_unlocked, same process) signal this semaphore
 * right after writing a request; the loop sleeps in semaphore_timedwait
 * and wakes instantly. Extra signals just cause cheap extra scans. */
semaphore_t ios_srv_wake_sem = 0;
void ios_wineserver_wake(void)
{
    if (ios_srv_wake_sem) semaphore_signal( ios_srv_wake_sem );
}

/* __WINESRC__ must be defined via -D flag so unicode_fix.h can see it */

#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <poll.h>
#ifdef HAVE_LINUX_MAJOR_H
#include <linux/major.h>
#endif
#ifdef HAVE_SYS_STATVFS_H
#include <sys/statvfs.h>
#endif
#ifdef HAVE_SYS_VFS_H
/* Work around a conflict with Solaris' system list defined in sys/list.h. */
#define list SYSLIST
#define list_next SYSLIST_NEXT
#define list_prev SYSLIST_PREV
#define list_head SYSLIST_HEAD
#define list_tail SYSLIST_TAIL
#define list_move_tail SYSLIST_MOVE_TAIL
#define list_remove SYSLIST_REMOVE
#include <sys/vfs.h>
#undef list
#undef list_next
#undef list_prev
#undef list_head
#undef list_tail
#undef list_move_tail
#undef list_remove
#endif
#ifdef HAVE_SYS_PARAM_H
#include <sys/param.h>
#endif
#ifdef HAVE_SYS_MOUNT_H
#include <sys/mount.h>
#endif
#ifdef HAVE_SYS_STATFS_H
#include <sys/statfs.h>
#endif
#ifdef HAVE_SYS_SYSCTL_H
#include <sys/sysctl.h>
#endif
#ifdef HAVE_SYS_EVENT_H
#include <sys/event.h>
#undef LIST_INIT
#undef LIST_ENTRY
#endif
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#ifdef MAJOR_IN_MKDEV
#include <sys/mkdev.h>
#elif defined(MAJOR_IN_SYSMACROS)
#include <sys/sysmacros.h>
#endif
#include <sys/types.h>
#include <unistd.h>
#ifdef HAVE_SYS_SYSCALL_H
#include <sys/syscall.h>
#endif
#ifdef HAVE_SYS_XATTR_H
#include <sys/xattr.h>
#endif
#ifdef HAVE_SYS_EXTATTR_H
#undef XATTR_ADDITIONAL_OPTIONS
#include <sys/extattr.h>
#endif

#include "ntstatus.h"
#include "object.h"
#include "file.h"
#include "handle.h"
#include "process.h"
#include "request.h"

#include "winternl.h"
#include "winioctl.h"
#include "ddk/ntifs.h"
#include "ddk/wdm.h"

#if defined(HAVE_SYS_EPOLL_H) && defined(HAVE_EPOLL_CREATE)
# include <sys/epoll.h>
# define USE_EPOLL
#endif /* HAVE_SYS_EPOLL_H && HAVE_EPOLL_CREATE */

#if defined(HAVE_PORT_H) && defined(HAVE_PORT_CREATE)
# include <port.h>
# define USE_EVENT_PORTS
#endif /* HAVE_PORT_H && HAVE_PORT_CREATE */

/* Because of the stupid Posix locking semantics, we need to keep
 * track of all file descriptors referencing a given file, and not
 * close a single one until all the locks are gone (sigh).
 */

/* file descriptor object */

/* closed_fd is used to keep track of the unix fd belonging to a closed fd object */
struct closed_fd
{
    struct list     entry;      /* entry in inode closed list */
    int             unix_fd;    /* the unix file descriptor */
    unsigned int    disp_flags; /* the disposition flags */
    char           *unix_name;  /* name to unlink on close, points to parent fd unix_name */
};

struct fd
{
    struct object        obj;         /* object header */
    const struct fd_ops *fd_ops;      /* file descriptor operations */
    struct object       *sync;        /* sync object for wait/signal */
    struct inode        *inode;       /* inode that this fd belongs to */
    struct list          inode_entry; /* entry in inode fd list */
    struct closed_fd    *closed;      /* structure to store the unix fd at destroy time */
    struct object       *user;        /* object using this file descriptor */
    struct list          locks;       /* list of locks on this fd */
    client_ptr_t         map_addr;    /* default mapping address for PE files */
    mem_size_t           map_size;    /* mapping size for PE files */
    unsigned int         access;      /* file access (FILE_READ_DATA etc.) */
    unsigned int         options;     /* file options (FILE_DELETE_ON_CLOSE, FILE_SYNCHRONOUS...) */
    unsigned int         sharing;     /* file sharing mode */
    char                *unix_name;   /* unix file name */
    WCHAR               *nt_name;     /* NT file name */
    data_size_t          nt_namelen;  /* length of NT file name */
    int                  unix_fd;     /* unix file descriptor */
    unsigned int         no_fd_status;/* status to return when unix_fd is -1 */
    unsigned int         cacheable :1;/* can the fd be cached on the client side? */
    unsigned int         fs_locks :1; /* can we use filesystem locks for this fd? */
    int                  poll_index;  /* index of fd in poll array */
    struct async_queue   read_q;      /* async readers of this fd */
    struct async_queue   write_q;     /* async writers of this fd */
    struct async_queue   wait_q;      /* other async waiters of this fd */
    struct completion   *completion;  /* completion object attached to this fd */
    apc_param_t          comp_key;    /* completion key to set in completion events */
    unsigned int         comp_flags;  /* completion flags */
    /* ml978: who opened this fd, recorded at allocation.
     *
     * ml960 could name the CONFLICTING holder on a sharing violation but not
     * whose it was, and Astra's review was explicit that a host unix_fd number
     * is not a Wine process owner. Walking the server's handle tables to
     * attribute the holder is not reachable from here (process_list and the
     * handle_table internals are static to process.c / handle.c), so record the
     * provenance at the one moment it is trivially known: fd creation, which
     * always runs on the requesting thread. Attribution then comes from history
     * rather than a table walk, and it separates the two causes that need
     * opposite fixes -- a handle leaked by an exited pseudo-process, versus a
     * second live open in the same one (which Windows would also refuse). */
    unsigned int         open_pid;    /* ml978: process that created this fd */
    unsigned int         open_tid;    /* ml978: thread that created this fd */
};

static void fd_dump( struct object *obj, int verbose );
static struct object *fd_get_sync( struct object *obj );
static void fd_destroy( struct object *obj );

static const struct object_ops fd_ops =
{
    sizeof(struct fd),        /* size */
    &no_type,                 /* type */
    fd_dump,                  /* dump */
    NULL,                     /* add_queue */
    NULL,                     /* remove_queue */
    NULL,                     /* signaled */
    NULL,                     /* satisfied */
    no_signal,                /* signal */
    no_get_fd,                /* get_fd */
    fd_get_sync,              /* get_sync */
    default_map_access,       /* map_access */
    default_get_sd,           /* get_sd */
    default_set_sd,           /* set_sd */
    no_get_full_name,         /* get_full_name */
    no_lookup_name,           /* lookup_name */
    no_link_name,             /* link_name */
    NULL,                     /* unlink_name */
    no_open_file,             /* open_file */
    no_kernel_obj_list,       /* get_kernel_obj_list */
    no_close_handle,          /* close_handle */
    fd_destroy                /* destroy */
};

/* device object */

#define DEVICE_HASH_SIZE 7
#define INODE_HASH_SIZE 17

struct device
{
    struct object       obj;        /* object header */
    struct list         entry;      /* entry in device hash list */
    dev_t               dev;        /* device number */
    int                 removable;  /* removable device? (or -1 if unknown) */
    struct list         inode_hash[INODE_HASH_SIZE];  /* inodes hash table */
};

static void device_dump( struct object *obj, int verbose );
static void device_destroy( struct object *obj );

static const struct object_ops device_ops =
{
    sizeof(struct device),    /* size */
    &no_type,                 /* type */
    device_dump,              /* dump */
    no_add_queue,             /* add_queue */
    NULL,                     /* remove_queue */
    NULL,                     /* signaled */
    NULL,                     /* satisfied */
    no_signal,                /* signal */
    no_get_fd,                /* get_fd */
    default_get_sync,         /* get_sync */
    default_map_access,       /* map_access */
    default_get_sd,           /* get_sd */
    default_set_sd,           /* set_sd */
    no_get_full_name,         /* get_full_name */
    no_lookup_name,           /* lookup_name */
    no_link_name,             /* link_name */
    NULL,                     /* unlink_name */
    no_open_file,             /* open_file */
    no_kernel_obj_list,       /* get_kernel_obj_list */
    no_close_handle,          /* close_handle */
    device_destroy            /* destroy */
};

/* inode object */

struct inode
{
    struct object       obj;        /* object header */
    struct list         entry;      /* inode hash list entry */
    struct device      *device;     /* device containing this inode */
    ino_t               ino;        /* inode number */
    struct list         open;       /* list of open file descriptors */
    struct list         locks;      /* list of file locks */
    struct list         closed;     /* list of file descriptors to close at destroy time */
};

static void inode_dump( struct object *obj, int verbose );
static void inode_destroy( struct object *obj );

static const struct object_ops inode_ops =
{
    sizeof(struct inode),     /* size */
    &no_type,                 /* type */
    inode_dump,               /* dump */
    no_add_queue,             /* add_queue */
    NULL,                     /* remove_queue */
    NULL,                     /* signaled */
    NULL,                     /* satisfied */
    no_signal,                /* signal */
    no_get_fd,                /* get_fd */
    default_get_sync,         /* get_sync */
    default_map_access,       /* map_access */
    default_get_sd,           /* get_sd */
    default_set_sd,           /* set_sd */
    no_get_full_name,         /* get_full_name */
    no_lookup_name,           /* lookup_name */
    no_link_name,             /* link_name */
    NULL,                     /* unlink_name */
    no_open_file,             /* open_file */
    no_kernel_obj_list,       /* get_kernel_obj_list */
    no_close_handle,          /* close_handle */
    inode_destroy             /* destroy */
};

/* file lock object */

struct file_lock
{
    struct object       obj;         /* object header */
    struct object      *sync;        /* sync object for wait/signal */
    struct fd          *fd;          /* fd owning this lock */
    struct list         fd_entry;    /* entry in list of locks on a given fd */
    struct list         inode_entry; /* entry in inode list of locks */
    int                 shared;      /* shared lock? */
    file_pos_t          start;       /* locked region is interval [start;end) */
    file_pos_t          end;
    struct process     *process;     /* process owning this lock */
    struct list         proc_entry;  /* entry in list of locks owned by the process */
};

static void file_lock_dump( struct object *obj, int verbose );
static struct object *file_lock_get_sync( struct object *obj );
static void file_lock_destroy( struct object *obj );

static const struct object_ops file_lock_ops =
{
    sizeof(struct file_lock),   /* size */
    &no_type,                   /* type */
    file_lock_dump,             /* dump */
    NULL,                       /* add_queue */
    NULL,                       /* remove_queue */
    NULL,                       /* signaled */
    NULL,                       /* satisfied */
    no_signal,                  /* signal */
    no_get_fd,                  /* get_fd */
    file_lock_get_sync,         /* get_sync */
    default_map_access,         /* map_access */
    default_get_sd,             /* get_sd */
    default_set_sd,             /* set_sd */
    no_get_full_name,           /* get_full_name */
    no_lookup_name,             /* lookup_name */
    no_link_name,               /* link_name */
    NULL,                       /* unlink_name */
    no_open_file,               /* open_file */
    no_kernel_obj_list,         /* get_kernel_obj_list */
    no_close_handle,            /* close_handle */
    file_lock_destroy,          /* destroy */
};


#define OFF_T_MAX       (~((file_pos_t)1 << (8*sizeof(off_t)-1)))
#define FILE_POS_T_MAX  (~(file_pos_t)0)

static file_pos_t max_unix_offset = OFF_T_MAX;

#define DUMP_LONG_LONG(val) do { \
    if (sizeof(val) > sizeof(unsigned long) && (val) > ~0UL) \
        fprintf( stderr, "%lx%08lx", (unsigned long)((unsigned long long)(val) >> 32), (unsigned long)(val) ); \
    else \
        fprintf( stderr, "%lx", (unsigned long)(val) ); \
  } while (0)



/****************************************************************/
/* timeouts support */

struct timeout_user
{
    struct list           entry;      /* entry in sorted timeout list */
    abstime_t             when;       /* timeout expiry */
    timeout_callback      callback;   /* callback function */
    void                 *private;    /* callback private data */
};

static struct list abs_timeout_list = LIST_INIT(abs_timeout_list); /* sorted absolute timeouts list */
static struct list rel_timeout_list = LIST_INIT(rel_timeout_list); /* sorted relative timeouts list */
timeout_t current_time;
timeout_t monotonic_time;

struct _KUSER_SHARED_DATA *user_shared_data = NULL;
static const timeout_t user_shared_data_timeout = 16 * 10000;

static void atomic_store_ulong(volatile ULONG *ptr, ULONG value)
{
    /* on x86 there should be total store order guarantees, so volatile is
     * enough to ensure the stores aren't reordered by the compiler, and then
     * they will always be seen in-order from other CPUs. On other archs, we
     * need atomic intrinsics to guarantee that. */
#if defined(__i386__) || defined(__x86_64__)
    *ptr = value;
#else
    __atomic_store_n(ptr, value, __ATOMIC_SEQ_CST);
#endif
}

static void atomic_store_long(volatile LONG *ptr, LONG value)
{
#if defined(__i386__) || defined(__x86_64__)
    *ptr = value;
#else
    __atomic_store_n(ptr, value, __ATOMIC_SEQ_CST);
#endif
}

/* ml731c: one place decides whether the shared-data clock is armed, so the
 * mapping and the periodic write can never disagree about it.
 *
 * ml1001: THE DEFAULT IS NOW ON, and the reason is a proven hang rather than a
 * tidiness argument.  While this was opt-in, KUSER_SHARED_DATA.TickCount stayed
 * at its SEC_COMMIT zero for the whole run, so GetTickCount() and
 * GetTickCount64() returned 0 to every guest program, forever.  A 64-bit title
 * whose HTTP stack keys an absolute-deadline timer tree on GetTickCount64
 * therefore gave every timer the SAME key, and its "is this node already in the
 * tree" sentinel is "the stored deadline is {0,0}" -- which a zero clock also
 * produces.  The node was re-inserted while still linked, the equal-key path
 * made it its own child, and a worker thread span in that tree at 100 % of a
 * core for the rest of the run.  Three devices, three runs, byte-identical
 * corruption.  See WOW64_DESIGN.md 2026-09-28.
 *
 * A clock that does not tick is not a missing optimisation, it is a wrong
 * answer from an API, and it can only ever be found by the program that trips
 * over it.  `MADEIRA_USD_TIME=0' is the kill switch and restores the frozen
 * page exactly (mapping included -- see create_user_data_mapping). */
int ios_usd_time_enabled(void)
{
    static int env = -1;
    if (env < 0)
    {
        const char *e = getenv( "MADEIRA_USD_TIME" );
        env = (e && e[0] == '0') ? 0 : 1;
    }
    return env;
}

/* Report what the writable alias actually IS right now, and prove a store to it
 * still lands. The wedge we are chasing is an address that accepts a write at
 * startup and later stops completing one, so protection/tag at creation time
 * alone cannot answer it -- this runs again just before each publication.
 * Every store here is to a scratch field we own (TickCountMultiplier is
 * constant after init and is restored immediately), never to a live clock. */
void ios_usd_report_alias( void *ptr, size_t size, const char *when )
{
    mach_vm_address_t addr = (mach_vm_address_t)ptr;
    mach_vm_size_t    sz   = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    volatile unsigned int *scratch = (volatile unsigned int *)((char *)ptr + 4); /* TickCountMultiplier */
    unsigned int saved, plain_ok = 0, rel_ok = 0;

    if (mach_vm_region( mach_task_self(), &addr, &sz, VM_REGION_BASIC_INFO_64,
                        (vm_region_info_t)&info, &count, &obj ) == KERN_SUCCESS)
        ws_log("[usd-map] ml731c %s alias=%p region=0x%llx+0x%llx prot=%d/%d shared=%d",
               when, ptr, (unsigned long long)addr, (unsigned long long)sz,
               info.protection, info.max_protection, info.shared);
    else
        ws_log("[usd-map] ml731c %s alias=%p region query FAILED", when, ptr);

    /* bounded: one ordinary store, one release store, each read back once */
    saved = *scratch;
    *scratch = 0xA5A5A5A5u;
    plain_ok = (*scratch == 0xA5A5A5A5u);
    __atomic_store_n( (unsigned int *)scratch, 0x5A5A5A5Au, __ATOMIC_SEQ_CST );
    rel_ok = (__atomic_load_n( (unsigned int *)scratch, __ATOMIC_SEQ_CST ) == 0x5A5A5A5Au);
    *scratch = saved;
    ws_log("[usd-map] ml731c %s store test: plain=%s release=%s (size=%zu)",
           when, plain_ok ? "OK" : "LOST", rel_ok ? "OK" : "LOST", size);
}

static void set_user_shared_data_time(void)
{
    timeout_t tick_count = monotonic_time / 10000;
    static timeout_t last_timezone_update;
    timeout_t timezone_bias;
    struct tm *tm, tm1, tm2;
    time_t now;

    if (monotonic_time - last_timezone_update > TICKS_PER_SEC)
    {
        now = time( NULL );
        tm = gmtime( &now );
        timezone_bias = mktime( tm ) - now;
        tm = localtime( &now );
        if (tm->tm_isdst)
        {
            tm1 = tm2 = *tm;
            tm1.tm_isdst = 0;
            tm2.tm_isdst = 1;
            timezone_bias += mktime(&tm1) < mktime(&tm2) ? 3600 : -3600;
        }
        timezone_bias *= TICKS_PER_SEC;

        atomic_store_long(&user_shared_data->TimeZoneBias.High2Time, timezone_bias >> 32);
        atomic_store_ulong(&user_shared_data->TimeZoneBias.LowPart, timezone_bias);
        atomic_store_long(&user_shared_data->TimeZoneBias.High1Time, timezone_bias >> 32);

        last_timezone_update = monotonic_time;
    }

    atomic_store_long(&user_shared_data->SystemTime.High2Time, current_time >> 32);
    atomic_store_ulong(&user_shared_data->SystemTime.LowPart, current_time);
    atomic_store_long(&user_shared_data->SystemTime.High1Time, current_time >> 32);

    atomic_store_long(&user_shared_data->InterruptTime.High2Time, monotonic_time >> 32);
    atomic_store_ulong(&user_shared_data->InterruptTime.LowPart, monotonic_time);
    atomic_store_long(&user_shared_data->InterruptTime.High1Time, monotonic_time >> 32);

    atomic_store_long(&user_shared_data->TickCount.High2Time, tick_count >> 32);
    atomic_store_ulong(&user_shared_data->TickCount.LowPart, tick_count);
    atomic_store_long(&user_shared_data->TickCount.High1Time, tick_count >> 32);
    atomic_store_ulong(&user_shared_data->TickCountLowDeprecated, tick_count);
}

void set_current_time(void)
{
    static const timeout_t ticks_1601_to_1970 = (timeout_t)86400 * (369 * 365 + 89) * TICKS_PER_SEC;
    struct timeval now;
    gettimeofday( &now, NULL );
    current_time = (timeout_t)now.tv_sec * TICKS_PER_SEC + now.tv_usec * 10 + ticks_1601_to_1970;
    monotonic_time = monotonic_counter();
#ifdef WINE_IOS
    /* ml731: KUSER_SHARED_DATA's clock. This write used to be skipped outright,
     * blamed on tmpfile-backed shared mappings being invalidated by Library
     * Validation. That reasoning does not hold up: Library Validation governs
     * EXECUTABLE mappings, and this page is already shared successfully -- the
     * server maps the section PROT_WRITE|MAP_SHARED and the guest remaps the
     * same fd PROT_READ|MAP_SHARED|MAP_FIXED in virtual_map_user_shared_data().
     *
     * The cost of skipping it is that SystemTime, InterruptTime and TickCount
     * are frozen at their init values for the entire run, so GetTickCount(),
     * GetTickCount64(), Environment.TickCount and DateTime.UtcNow's fast path
     * never advance. Native titles that pace frames with QueryPerformanceCounter
     * (which goes to clock_gettime, not this page) never noticed; managed titles
     * see a stopped clock, so every time-gated state transition waits forever
     * while rendering happily continues. A game's own log showed 2,955 lines
     * spanning 15ms of "elapsed" time across a five-minute run, while a
     * middleware SDK's independent timer in those same lines advanced from 31s
     * to 466s -- two clocks in one process, one of them stopped.
     *
     * Opt-in for now (MADEIRA_USD_TIME=1) only because the old comment claimed a
     * fault; a functioning clock should not stay experimental once proven. */
    /* ml731f: the periodic path is now NOTHING but the seven stores.
     *
     * Every logging call has been removed from it. ws_log() does file I/O and
     * the report used fprintf(), and set_current_time() runs on the server's
     * main loop AND inside request handling -- so those were logging from the
     * exact path being measured. Three separate hangs were investigated with
     * that instrumentation still live in the path, which makes the probe a
     * suspect in every result it produced. Creation-time reporting is kept
     * (it runs once, before any client exists); steady state is silent.
     *
     * Only TickCount and InterruptTime are published: clocktest measured that
     * SystemTime and QueryPerformanceCounter already advance without this page. */
    if (ios_usd_time_enabled() && user_shared_data)
    {
        /* ml732: publish on every call, as upstream does. The previous build
         * throttled this to 16ms on the theory that repeated stores meant
         * repeated tmpfile writeback. That was wrong twice over: repeated stores
         * keep ONE 4KB page dirty rather than forcing a filesystem operation
         * each time, and user_shared_data_timeout is the poll timeout in
         * get_next_timeout(), not a write throttle -- upstream deliberately
         * publishes after every event-loop wake. Throttling changed nothing and
         * only added a variable. */
        timeout_t tc = monotonic_time / 10000;

        /* SystemTime is published too. GetSystemTimeAsFileTime() does not read
         * this page on iOS -- it goes to clock_gettime, which is why clocktest
         * saw it advance even while the page was frozen -- but anything reading
         * KUSER_SHARED_DATA.SystemTime directly would still see a stopped clock,
         * and that is not something the four public APIs can prove either way.
         * These are three more plain atomic stores.
         *
         * TimeZoneBias is deliberately NOT published: computing it needs
         * gmtime/localtime/mktime, which take libc's timezone lock and share a
         * static buffer in a process where wineserver and every guest thread
         * share libc. It keeps its initialization value (UTC). */
        atomic_store_long(&user_shared_data->SystemTime.High2Time, current_time >> 32);
        atomic_store_ulong(&user_shared_data->SystemTime.LowPart, current_time);
        atomic_store_long(&user_shared_data->SystemTime.High1Time, current_time >> 32);
        atomic_store_long(&user_shared_data->InterruptTime.High2Time, monotonic_time >> 32);
        atomic_store_ulong(&user_shared_data->InterruptTime.LowPart, monotonic_time);
        atomic_store_long(&user_shared_data->InterruptTime.High1Time, monotonic_time >> 32);

        atomic_store_long(&user_shared_data->TickCount.High2Time, tc >> 32);
        atomic_store_ulong(&user_shared_data->TickCount.LowPart, tc);
        atomic_store_long(&user_shared_data->TickCount.High1Time, tc >> 32);
        atomic_store_ulong(&user_shared_data->TickCountLowDeprecated, tc);
    }
#else
    if (user_shared_data) set_user_shared_data_time();
#endif
}

/* add a timeout user */
struct timeout_user *add_timeout_user( timeout_t when, timeout_callback func, void *private )
{
    struct timeout_user *user;
    struct list *ptr;

    if (!(user = mem_alloc( sizeof(*user) ))) return NULL;
    user->when     = timeout_to_abstime( when );
    user->callback = func;
    user->private  = private;

    /* Now insert it in the linked list */

    if (user->when > 0)
    {
        LIST_FOR_EACH( ptr, &abs_timeout_list )
        {
            struct timeout_user *timeout = LIST_ENTRY( ptr, struct timeout_user, entry );
            if (timeout->when >= user->when) break;
        }
    }
    else
    {
        LIST_FOR_EACH( ptr, &rel_timeout_list )
        {
            struct timeout_user *timeout = LIST_ENTRY( ptr, struct timeout_user, entry );
            if (timeout->when <= user->when) break;
        }
    }
    list_add_before( ptr, &user->entry );
    return user;
}

/* remove a timeout user */
void remove_timeout_user( struct timeout_user *user )
{
    list_remove( &user->entry );
    free( user );
}

/* return a text description of a timeout for debugging purposes */
const char *get_timeout_str( timeout_t timeout )
{
    static char buffer[64];
    long secs, nsecs;

    if (!timeout) return "0";
    if (timeout == TIMEOUT_INFINITE) return "infinite";

    if (timeout < 0)  /* relative */
    {
        secs = -timeout / TICKS_PER_SEC;
        nsecs = -timeout % TICKS_PER_SEC;
        snprintf( buffer, sizeof(buffer), "+%ld.%07ld", secs, nsecs );
    }
    else  /* absolute */
    {
        secs = (timeout - current_time) / TICKS_PER_SEC;
        nsecs = (timeout - current_time) % TICKS_PER_SEC;
        if (nsecs < 0)
        {
            nsecs += TICKS_PER_SEC;
            secs--;
        }
        if (secs >= 0)
            snprintf( buffer, sizeof(buffer), "%x%08x (+%ld.%07ld)",
                      (unsigned int)(timeout >> 32), (unsigned int)timeout, secs, nsecs );
        else
            snprintf( buffer, sizeof(buffer), "%x%08x (-%ld.%07ld)",
                      (unsigned int)(timeout >> 32), (unsigned int)timeout,
                      -(secs + 1), TICKS_PER_SEC - nsecs );
    }
    return buffer;
}


/****************************************************************/
/* poll support */

static struct fd **poll_users;              /* users array */
static struct pollfd *pollfd;               /* poll fd array */
static int nb_users;                        /* count of array entries actually in use */
static int active_users;                    /* current number of active users */
static int allocated_users;                 /* count of allocated entries in the array */
static struct fd **freelist;                /* list of free entries in the array */

static int get_next_timeout( struct timespec *ts );

static inline void fd_poll_event( struct fd *fd, int event )
{
    fd->fd_ops->poll_event( fd, event );
}

#ifdef USE_EPOLL

static int epoll_fd = -1;

static inline void init_epoll(void)
{
    epoll_fd = epoll_create( 128 );
}

/* set the events that epoll waits for on this fd; helper for set_fd_events */
static inline void set_fd_epoll_events( struct fd *fd, int user, int events )
{
    struct epoll_event ev;
    int ctl;

    if (epoll_fd == -1) return;

    if (events == -1)  /* stop waiting on this fd completely */
    {
        if (pollfd[user].fd == -1) return;  /* already removed */
        ctl = EPOLL_CTL_DEL;
    }
    else if (pollfd[user].fd == -1)
    {
        ctl = EPOLL_CTL_ADD;
    }
    else
    {
        if (pollfd[user].events == events) return;  /* nothing to do */
        ctl = EPOLL_CTL_MOD;
    }

    ev.events = events;
    memset(&ev.data, 0, sizeof(ev.data));
    ev.data.u32 = user;

    if (epoll_ctl( epoll_fd, ctl, fd->unix_fd, &ev ) == -1)
    {
        if (errno == ENOMEM)  /* not enough memory, give up on epoll */
        {
            close( epoll_fd );
            epoll_fd = -1;
        }
        else perror( "epoll_ctl" );  /* should not happen */
    }
}

static inline void remove_epoll_user( struct fd *fd, int user )
{
    if (epoll_fd == -1) return;

    if (pollfd[user].fd != -1)
    {
        struct epoll_event dummy;
        epoll_ctl( epoll_fd, EPOLL_CTL_DEL, fd->unix_fd, &dummy );
    }
}

static inline void main_loop_epoll(void)
{
    int i, ret, timeout;
    struct timespec ts;
    struct epoll_event events[128];
#ifdef HAVE_EPOLL_PWAIT2
    static int failed_epoll_pwait2 = 0;
#endif

    assert( POLLIN == EPOLLIN );
    assert( POLLOUT == EPOLLOUT );
    assert( POLLERR == EPOLLERR );
    assert( POLLHUP == EPOLLHUP );

    if (epoll_fd == -1) return;

    while (active_users)
    {
        timeout = get_next_timeout( &ts );

        if (!active_users) break;  /* last user removed by a timeout */
        if (epoll_fd == -1) break;  /* an error occurred with epoll */

#ifdef HAVE_EPOLL_PWAIT2
        if (!failed_epoll_pwait2)
        {
            ret = epoll_pwait2( epoll_fd, events, ARRAY_SIZE( events ), timeout == -1 ? NULL : &ts, NULL );
            if (ret == -1 && errno == ENOSYS)
                failed_epoll_pwait2 = 1;
        }
        if (failed_epoll_pwait2)
#endif
            ret = epoll_wait( epoll_fd, events, ARRAY_SIZE( events ), timeout );

        set_current_time();

        /* put the events into the pollfd array first, like poll does */
        for (i = 0; i < ret; i++)
        {
            int user = events[i].data.u32;
            pollfd[user].revents = events[i].events;
        }

        /* read events from the pollfd array, as set_fd_events may modify them */
        for (i = 0; i < ret; i++)
        {
            int user = events[i].data.u32;
            if (pollfd[user].revents) fd_poll_event( poll_users[user], pollfd[user].revents );
        }
    }
}

#elif defined(HAVE_KQUEUE)

static int kqueue_fd = -1;

static inline void init_epoll(void)
{
#ifdef WINE_IOS
    /* iOS: kqueue doesn't fire events for Unix domain sockets in app sandbox.
     * Force fallback to poll() by leaving kqueue_fd = -1. */
    ws_log("[wineserver-fd] init_epoll: SKIPPING kqueue on iOS, using poll()");
#else
    kqueue_fd = kqueue();
    ws_log("[wineserver-fd] init_epoll: kqueue_fd=%d", kqueue_fd);
#endif
}

static inline void set_fd_epoll_events( struct fd *fd, int user, int events )
{
    struct kevent ev[2];

    /* iOS-Madeira 2026-07-05: log line removed — kqueue is always skipped
     * on iOS (poll fallback) and this fired per fd-event change: 3,234
     * lines of pure noise in one gameplay run. */
    if (kqueue_fd == -1) return;

    EV_SET( &ev[0], fd->unix_fd, EVFILT_READ, 0, NOTE_LOWAT, 1, (void *)(long)user );
    EV_SET( &ev[1], fd->unix_fd, EVFILT_WRITE, 0, NOTE_LOWAT, 1, (void *)(long)user );

    if (events == -1)  /* stop waiting on this fd completely */
    {
        if (pollfd[user].fd == -1) return;  /* already removed */
        ev[0].flags |= EV_DELETE;
        ev[1].flags |= EV_DELETE;
    }
    else if (pollfd[user].fd == -1)
    {
        ev[0].flags |= EV_ADD | ((events & POLLIN) ? EV_ENABLE : EV_DISABLE);
        ev[1].flags |= EV_ADD | ((events & POLLOUT) ? EV_ENABLE : EV_DISABLE);
    }
    else
    {
        if (pollfd[user].events == events) return;  /* nothing to do */
        ev[0].flags |= (events & POLLIN) ? EV_ENABLE : EV_DISABLE;
        ev[1].flags |= (events & POLLOUT) ? EV_ENABLE : EV_DISABLE;
    }

    ws_log("[wineserver-fd] set_fd_epoll_events: unix_fd=%d user=%d events=0x%x flags0=0x%x flags1=0x%x",
           fd->unix_fd, user, events, ev[0].flags, ev[1].flags);
    if (kevent( kqueue_fd, ev, 2, NULL, 0, NULL ) == -1)
    {
        ws_log("[wineserver-fd] kevent register FAILED: %s (errno=%d)", strerror(errno), errno);
        if (errno == ENOMEM)  /* not enough memory, give up on kqueue */
        {
            close( kqueue_fd );
            kqueue_fd = -1;
        }
        else perror( "kevent" );  /* should not happen */
    }
}

static inline void remove_epoll_user( struct fd *fd, int user )
{
    if (kqueue_fd == -1) return;

    if (pollfd[user].fd != -1)
    {
        struct kevent ev[2];

        EV_SET( &ev[0], fd->unix_fd, EVFILT_READ, EV_DELETE, 0, 0, 0 );
        EV_SET( &ev[1], fd->unix_fd, EVFILT_WRITE, EV_DELETE, 0, 0, 0 );
        kevent( kqueue_fd, ev, 2, NULL, 0, NULL );
    }
}

static inline void main_loop_epoll(void)
{
    int i, ret, timeout;
    struct timespec ts;
    struct kevent events[128];

    ws_log("[wineserver-fd] main_loop_epoll: kqueue_fd=%d active_users=%d", kqueue_fd, active_users);
    if (kqueue_fd == -1) { ws_log("[wineserver-fd] main_loop_epoll: kqueue_fd=-1, falling back to poll"); return; }

    while (active_users)
    {
        timeout = get_next_timeout( &ts );

        if (!active_users) break;  /* last user removed by a timeout */
        if (kqueue_fd == -1) break;  /* an error occurred with kqueue */

        ret = kevent( kqueue_fd, NULL, 0, events, ARRAY_SIZE( events ), timeout == -1 ? NULL : &ts );
        if (ret > 0) ws_log("[wineserver-fd] kevent returned %d events", ret);
        if (ret < 0) ws_log("[wineserver-fd] kevent error: %s", strerror(errno));

        set_current_time();

        /* put the events into the pollfd array first, like poll does */
        for (i = 0; i < ret; i++)
        {
            long user = (long)events[i].udata;
            pollfd[user].revents = 0;
        }
        for (i = 0; i < ret; i++)
        {
            long user = (long)events[i].udata;
            if (events[i].filter == EVFILT_READ) pollfd[user].revents |= POLLIN;
            else if (events[i].filter == EVFILT_WRITE) pollfd[user].revents |= POLLOUT;
            if (events[i].flags & EV_EOF) pollfd[user].revents |= POLLHUP;
            if (events[i].flags & EV_ERROR) pollfd[user].revents |= POLLERR;
        }

        /* read events from the pollfd array, as set_fd_events may modify them */
        for (i = 0; i < ret; i++)
        {
            long user = (long)events[i].udata;
            if (pollfd[user].revents) fd_poll_event( poll_users[user], pollfd[user].revents );
            pollfd[user].revents = 0;
        }
    }
}

#elif defined(USE_EVENT_PORTS)

static int port_fd = -1;

static inline void init_epoll(void)
{
    port_fd = port_create();
}

static inline void set_fd_epoll_events( struct fd *fd, int user, int events )
{
    int ret;

    if (port_fd == -1) return;

    if (events == -1)  /* stop waiting on this fd completely */
    {
        if (pollfd[user].fd == -1) return;  /* already removed */
        port_dissociate( port_fd, PORT_SOURCE_FD, fd->unix_fd );
    }
    else if (pollfd[user].fd == -1)
    {
        ret = port_associate( port_fd, PORT_SOURCE_FD, fd->unix_fd, events, (void *)user );
    }
    else
    {
        if (pollfd[user].events == events) return;  /* nothing to do */
        ret = port_associate( port_fd, PORT_SOURCE_FD, fd->unix_fd, events, (void *)user );
    }

    if (ret == -1)
    {
        if (errno == ENOMEM)  /* not enough memory, give up on port_associate */
        {
            close( port_fd );
            port_fd = -1;
        }
        else perror( "port_associate" );  /* should not happen */
    }
}

static inline void remove_epoll_user( struct fd *fd, int user )
{
    if (port_fd == -1) return;

    if (pollfd[user].fd != -1)
    {
        port_dissociate( port_fd, PORT_SOURCE_FD, fd->unix_fd );
    }
}

static inline void main_loop_epoll(void)
{
    int i, nget, ret, timeout;
    struct timespec ts;
    port_event_t events[128];

    if (port_fd == -1) return;

    while (active_users)
    {
        timeout = get_next_timeout( &ts );
        nget = 1;

        if (!active_users) break;  /* last user removed by a timeout */
        if (port_fd == -1) break;  /* an error occurred with event completion */

        ret = port_getn( port_fd, events, ARRAY_SIZE( events ), &nget, timeout == -1 ? NULL : &ts );

	if (ret == -1) break;  /* an error occurred with event completion */

        set_current_time();

        /* put the events into the pollfd array first, like poll does */
        for (i = 0; i < nget; i++)
        {
            long user = (long)events[i].portev_user;
            pollfd[user].revents = events[i].portev_events;
        }

        /* read events from the pollfd array, as set_fd_events may modify them */
        for (i = 0; i < nget; i++)
        {
            long user = (long)events[i].portev_user;
            if (pollfd[user].revents) fd_poll_event( poll_users[user], pollfd[user].revents );
            /* if we are still interested, reassociate the fd */
            if (pollfd[user].fd != -1) {
                port_associate( port_fd, PORT_SOURCE_FD, pollfd[user].fd, pollfd[user].events, (void *)user );
            }
        }
    }
}

#else /* HAVE_KQUEUE */

static inline void init_epoll(void) { }
static inline void set_fd_epoll_events( struct fd *fd, int user, int events ) { }
static inline void remove_epoll_user( struct fd *fd, int user ) { }
static inline void main_loop_epoll(void) { }

#endif /* USE_EPOLL */


/* add a user in the poll array and return its index, or -1 on failure */
static int add_poll_user( struct fd *fd )
{
    int ret;
    if (freelist)
    {
        ret = freelist - poll_users;
        freelist = (struct fd **)poll_users[ret];
    }
    else
    {
        if (nb_users == allocated_users)
        {
            struct fd **newusers;
            struct pollfd *newpoll;
            int new_count = allocated_users ? (allocated_users + allocated_users / 2) : 16;
            if (!(newusers = realloc( poll_users, new_count * sizeof(*poll_users) ))) return -1;
            if (!(newpoll = realloc( pollfd, new_count * sizeof(*pollfd) )))
            {
                if (allocated_users)
                    poll_users = newusers;
                else
                    free( newusers );
                return -1;
            }
            poll_users = newusers;
            pollfd = newpoll;
            if (!allocated_users) init_epoll();
            allocated_users = new_count;
        }
        ret = nb_users++;
    }
    pollfd[ret].fd = -1;
    pollfd[ret].events = 0;
    pollfd[ret].revents = 0;
    poll_users[ret] = fd;
    active_users++;
    {
        static unsigned int ios_apu_calls;   /* capped like send_client_fd */
        if (++ios_apu_calls <= 64 || !(ios_apu_calls & 4095))
            ws_log("[wineserver-fd] add_poll_user: #%u user=%d unix_fd=%d active_users=%d", ios_apu_calls, ret, fd->unix_fd, active_users);
    }
    return ret;
}

/* remove a user from the poll list */
static void remove_poll_user( struct fd *fd, int user )
{
    assert( user >= 0 );
    assert( poll_users[user] == fd );

    remove_epoll_user( fd, user );
    pollfd[user].fd = -1;
    pollfd[user].events = 0;
    pollfd[user].revents = 0;
    poll_users[user] = (struct fd *)freelist;
    freelist = &poll_users[user];
    active_users--;
}

/* process pending timeouts and return the time until the next timeout in milliseconds,
 * and full nanosecond precision in the timespec parameter if given */
static int get_next_timeout( struct timespec *ts )
{
    timeout_t ret = user_shared_data ? user_shared_data_timeout : -1;

    if (!list_empty( &abs_timeout_list ) || !list_empty( &rel_timeout_list ))
    {
        struct list expired_list, *ptr;

        /* first remove all expired timers from the list */

        list_init( &expired_list );
        while ((ptr = list_head( &abs_timeout_list )) != NULL)
        {
            struct timeout_user *timeout = LIST_ENTRY( ptr, struct timeout_user, entry );

            if (timeout->when <= current_time)
            {
                list_remove( &timeout->entry );
                list_add_tail( &expired_list, &timeout->entry );
            }
            else break;
        }
        while ((ptr = list_head( &rel_timeout_list )) != NULL)
        {
            struct timeout_user *timeout = LIST_ENTRY( ptr, struct timeout_user, entry );

            if (-timeout->when <= monotonic_time)
            {
                list_remove( &timeout->entry );
                list_add_tail( &expired_list, &timeout->entry );
            }
            else break;
        }

        /* now call the callback for all the removed timers */

        while ((ptr = list_head( &expired_list )) != NULL)
        {
            struct timeout_user *timeout = LIST_ENTRY( ptr, struct timeout_user, entry );
            list_remove( &timeout->entry );
            timeout->callback( timeout->private );
            free( timeout );
        }

        if ((ptr = list_head( &abs_timeout_list )) != NULL)
        {
            struct timeout_user *timeout = LIST_ENTRY( ptr, struct timeout_user, entry );
            timeout_t diff = timeout->when - current_time;
            if (diff < 0) diff = 0;
            if (ret == -1 || diff < ret) ret = diff;
        }

        if ((ptr = list_head( &rel_timeout_list )) != NULL)
        {
            struct timeout_user *timeout = LIST_ENTRY( ptr, struct timeout_user, entry );
            timeout_t diff = -timeout->when - monotonic_time;
            if (diff < 0) diff = 0;
            if (ret == -1 || diff < ret) ret = diff;
        }
    }

    /* infinite */
    if (ret == -1) return -1;

    if (ts)
    {
        ts->tv_sec = ret / TICKS_PER_SEC;
        ts->tv_nsec = (ret % TICKS_PER_SEC) * 100;
    }

    /* convert to milliseconds, ceil to avoid spinning with 0 timeout */
    ret = (ret + 9999) / 10000;
    if (ret > INT_MAX) ret = INT_MAX;
    return ret;
}

/* server main poll() loop */
/* iOS-Madeira 2026-07-05 (Steam S0): the sandbox poll() limitation is
 * specific to the AF_UNIX master socketpair — real INET sockets (TCP/
 * UDP) are fully kernel-pollable on iOS. wineserver's sock.c depends on
 * true poll semantics (POLLOUT edge = connect completed, POLLERR/HUP =
 * failure); the synthesized events below (unconditional POLLOUT) made
 * every nonblocking connect look complete-but-unwritable → WSAEWOULDBLOCK
 * loops in winhttp. So INET fds get a real zero-timeout poll() each
 * iteration; pipes and the AF_UNIX pair keep the legacy synthesis.
 * Family is cached per (user,fd) — getsockname once per socket. */
static signed char ios_fd_is_inet( int user, int fd )
{
    static int *cache_fd;
    static signed char *cache_val;
    static int cache_size;

    if (user >= cache_size)
    {
        int newsize = (user + 64) & ~63;
        int *nfd = realloc( cache_fd, newsize * sizeof(*nfd) );
        signed char *nval = realloc( cache_val, newsize );
        if (!nfd || !nval) return 0;
        memset( nfd + cache_size, 0xff, (newsize - cache_size) * sizeof(*nfd) );
        cache_fd = nfd; cache_val = nval; cache_size = newsize;
    }
    /* ml579: CACHE RESTORED. The ml576 A/B ran 30.8M classifications across two
     * runs and found the cache would have been wrong TWICE, with ZERO of the
     * harmful direction (real INET misread as pipe). The stale-(user,fd) theory
     * is refuted, so the bypass has done its job — and it was expensive: ~188,000
     * getsockname() calls per second on the server's hot poll path. Steam gives
     * each CM ping exactly 1000 ms, so starving the poll loop that hard can eat
     * the deadline before the encrypted /cmping/ request is even written.
     *
     * The missing invalidation is still a latent correctness bug (nothing clears
     * cache_fd/cache_val when add_poll_user/remove_poll_user recycle a slot); it
     * simply is not the network failure. Fix it on merit, not as a network lead. */
    if (cache_fd[user] != fd)
    {
        struct sockaddr_storage ss;
        socklen_t slen = sizeof(ss);
        cache_fd[user] = fd;
        if (getsockname( fd, (struct sockaddr *)&ss, &slen ) == -1)
            cache_val[user] = 0;
        else
            cache_val[user] = (ss.ss_family == AF_INET || ss.ss_family == AF_INET6);
    }
    return cache_val[user];
}

void main_loop(void)
{
    int i, ret, timeout;

    set_current_time();
    server_start_time = current_time;

    main_loop_epoll();
    /* fall through to normal poll loop */

#ifdef WINE_IOS
    /* iOS single-process model: ntdll installs signal handlers that access TEB (x18),
     * which doesn't exist on the wineserver thread. Block all signals so we're immune. */
    {
        sigset_t all_sigs;
        sigfillset(&all_sigs);
        pthread_sigmask(SIG_SETMASK, &all_sigs, NULL);
        ws_log("[wineserver-fd] main_loop: blocked all signals on wineserver thread");
    }

    /* iOS: poll/kqueue don't detect events on Unix domain sockets in the app sandbox.
     * Set master socket (user 0) to non-blocking so we can manually try accept() each
     * iteration without blocking the event loop. */
    {
        void *sp = __builtin_frame_address(0);
        ws_log("[wineserver-fd] main_loop: stack=%p (wineserver thread stack location)", sp);
    }
    ws_log("[wineserver-fd] main_loop: iOS poll workaround active. active_users=%d master_fd=%d", active_users, pollfd[0].fd);
    fcntl(pollfd[0].fd, F_SETFL, O_NONBLOCK);
#endif

#ifdef WINE_IOS
    /* iOS: poll() and kqueue don't work for Unix domain sockets in the
     * app sandbox. Use usleep-based polling instead. Process timers and
     * check all fds each iteration. */
    {
        static int ios_iter = 0;
        static int ios_events_fired = 0;
        /* ml585 poll-loop census. AGGREGATE ONLY — emitted at the existing
         * 50k-iteration heartbeat, never per event, so the probe cannot
         * perturb the loop it measures (ml582 ran 2,935 iter/s; a per-event
         * log would dominate the very timing in question). */
        static unsigned long long ios_c_inet = 0;    /* real poll() dispatches      */
        static unsigned long long ios_c_synin = 0;   /* synthetic POLLIN            */
        static unsigned long long ios_c_synout = 0;  /* synthetic POLLOUT           */
        static unsigned long long ios_c_semret = 0;  /* wake-sem returned EARLY     */
        static unsigned long long ios_c_semto = 0;   /* wake-sem timed out (slept)  */
        static unsigned long long ios_late_max_us = 0;  /* worst timer lateness     */
        static int ios_syn_top_user = -1, ios_syn_top_n = 0;  /* noisiest poll user */
        static unsigned ios_syn_per_user[64];        /* rolling, low 6 bits of user */
        static int ios_post_inject = 0;  /* trace first N iters after injection */
        static int ios_client_fd_start = -1;  /* first poll index added by injection */
        int session_processes = -1;
        unsigned int session_notes = 0;
        unsigned long long ios_next_timer_ns = ~0ull;  /* ns until next timer (deadline-aware sleep) */

        /* iOS socketpair bypass: check for injected client fd from app bridge */
        extern volatile int g_injected_client_fd;
        extern void master_socket_handle_client(int client_fd);

        /* Stop flag — set by wineserver_stop() when wine process exits */
        extern volatile int g_wineserver_should_stop;

        ws_log("[wineserver-fd] iOS poll loop: master_fd=%d nb_users=%d active=%d", pollfd[0].fd, nb_users, active_users);
        {
            kern_return_t skr = semaphore_create( mach_task_self(), &ios_srv_wake_sem,
                                                  SYNC_POLICY_FIFO, 0 );
            ws_log("[wineserver-fd] request-wake semaphore: kr=%d sem=0x%x", skr, ios_srv_wake_sem);
            if (skr != KERN_SUCCESS) ios_srv_wake_sem = 0;
        }
        while (active_users)
        {
            extern int g_wineserver_session_stop;
            extern int g_wineserver_root_retired;
            extern int ios_server_user_process_count(void);
            if (__atomic_load_n(&g_wineserver_root_retired, __ATOMIC_ACQUIRE))
            {
                int remaining = ios_server_user_process_count();
                if (remaining != session_processes && session_notes++ < 8)
                    ws_log("[session-handoff] ml1220 root retired; applications remaining=%d", remaining);
                session_processes = remaining;
                if (!remaining)
                {
                    ws_log("[session-handoff] ml1220 application processes drained");
                    break;
                }
            }
            if (__atomic_exchange_n(&g_wineserver_session_stop, 0, __ATOMIC_ACQ_REL))
            {
                ws_log("[session-stop] ml1150 terminating Wine processes on server thread");
                shutdown_master_socket();
            }
            /* Check stop flag */
            if (__atomic_load_n(&g_wineserver_should_stop, __ATOMIC_ACQUIRE))
            {
                ws_log("[wineserver-fd] LOOP EXIT: stop requested at iter=%d", ios_iter);
                break;
            }

            /* Process expired timers (also computes the next deadline) */
            {
                struct timespec next_ts;
                timeout = get_next_timeout( &next_ts );
                ios_next_timer_ns = (timeout >= 0)
                    ? (unsigned long long)next_ts.tv_sec * 1000000000ull + next_ts.tv_nsec
                    : ~0ull;
            }
            if (!active_users) { ws_log("[wineserver-fd] LOOP EXIT: active_users=0 at iter=%d", ios_iter); break; }

            ios_iter++;
            /* Heartbeat via ws_log (file-based, not stderr) */
            if (ios_iter % 50000 == 0)
            {
                ws_log("[wineserver-fd] iter=%d act=%d nb=%d ef=%d", ios_iter, active_users, nb_users, ios_events_fired);
                ws_log("[srv-poll] iter=%d inet=%llu synIN=%llu synOUT=%llu semEarly=%llu semSlept=%llu "
                       "lateMax=%lluus topUser=%d/%d",
                       ios_iter, ios_c_inet, ios_c_synin, ios_c_synout,
                       ios_c_semret, ios_c_semto, ios_late_max_us,
                       ios_syn_top_user, ios_syn_top_n);
                memset( ios_syn_per_user, 0, sizeof(ios_syn_per_user) );
                ios_syn_top_user = -1; ios_syn_top_n = 0;
            }

            /* [srv-queues] desktop-mode diagnostic: dump every thread's
             * message-queue state every ~10s (SendMessage stall triage) */
            {
                static int qdump_on = -1;
                static struct timespec qdump_last;
                if (qdump_on < 0)
                {
                    const char *d = getenv("MADEIRA_DESKTOP");
                    qdump_on = (d && *d == '1');
                }
                if (qdump_on)
                {
                    struct timespec now;
                    clock_gettime(CLOCK_MONOTONIC, &now);
                    if (now.tv_sec - qdump_last.tv_sec >= 10)
                    {
                        extern void ios_dump_msg_queues(void);
                        extern void ios_dump_stuck_waits(void);
                        qdump_last = now;
                        ios_dump_msg_queues();
                        /* ml585: name the object behind any wait that has
                         * been outstanding >5s (see queue_ios.c). Rides the
                         * existing 10s cadence — no new timer, no new thread,
                         * and NOT a synchronous all-thread stack sample,
                         * which would perturb the scheduler we are measuring. */
                        ios_dump_stuck_waits();
                    }
                }
            }

            /* ml1060: [lost-wake] — the lost-wakeup detector and its self-heal,
             * and [wait-census].  UNCONDITIONAL, unlike the block above: the
             * whole point of it is to be running during the event it exists
             * for, and the games path unsets MADEIRA_DESKTOP, which is exactly
             * why ml585's [srv-stuck] has never printed a line in a title log.
             *
             * It runs HERE, immediately after get_next_timeout() above, because
             * that call refreshed current_time/monotonic_time and check_wait()
             * reads both — and because calling wake_up() from this point is the
             * same call from the same place as an expiring wait timeout.
             *
             * Cost when nothing is stuck: one pass over 512 registry slots, two
             * loads each, every 5 s.  MADEIRA_LOSTWAKE=0 disables it entirely;
             * MADEIRA_LOSTWAKE_SECS tunes the age threshold (see queue_ios.c). */
            {
                static int lw_on = -1;
                static struct timespec lw_last, census_last;
                if (lw_on < 0)
                {
                    const char *d = getenv("MADEIRA_LOSTWAKE");
                    lw_on = !(d && (!strcmp(d, "0") || !strcmp(d, "off") || !strcmp(d, "no")));
                }
                if (lw_on)
                {
                    struct timespec now;
                    clock_gettime(CLOCK_MONOTONIC, &now);
                    if (now.tv_sec - lw_last.tv_sec >= 5)
                    {
                        extern void ios_scan_lost_wakeups(void);
                        lw_last = now;
                        ios_scan_lost_wakeups();
                    }
                    /* The census is a full report, so it follows MADEIRA_DIAG
                     * and the 10 s cadence every other reporter uses. */
                    {
                        static int diag_on = -1;
                        if (diag_on < 0)
                        {
                            const char *g = getenv("MADEIRA_DIAG");
                            diag_on = (g && *g == '1');
                        }
                        if (diag_on && now.tv_sec - census_last.tv_sec >= 10)
                        {
                            extern void ios_wait_census(void);
                            census_last = now;
                            ios_wait_census();
                        }
                    }
                }
            }

            /* Check for injected client fd (socketpair bypass) */
            {
                int injected = __atomic_exchange_n(&g_injected_client_fd, -1, __ATOMIC_SEQ_CST);
                if (injected >= 0)
                {
                    ios_client_fd_start = nb_users;  /* remember where init fds end */
                    ws_log("[wineserver-fd] INJECTED client fd=%d at iter=%d client_start=%d — calling master_socket_handle_client", injected, ios_iter, ios_client_fd_start);
                    master_socket_handle_client(injected);
                    ws_log("[wineserver-fd] master_socket_handle_client returned, nb_users=%d", nb_users);
                    /* Dump fds right after injection */
                    for (i = 0; i < nb_users && i < 15; i++)
                    {
                        int ba = -1;
                        if (pollfd[i].fd >= 0) ioctl(pollfd[i].fd, FIONREAD, &ba);
                        ws_log("[wineserver-fd]   POST-INJECT [%d] fd=%d ev=0x%x bytes=%d", i, pollfd[i].fd, pollfd[i].events, ba);
                    }
                    ios_events_fired++;
                    ios_post_inject = 20;  /* trace next 20 iterations */
                }
            }

            /* iOS-Madeira 2026-07-05: deadline-aware, REQUEST-INTERRUPTIBLE
             * sleep (was a fixed usleep(1000)). Duration = min(1ms tick,
             * next timer deadline) so timer wakes are exact (~50us); and
             * the sleep is a semaphore_timedwait so a client signaling
             * ios_srv_wake_sem after writing a request wakes the loop
             * IMMEDIATELY — request pickup drops from avg ~0.5ms to ~50us.
             * Thumper's 8 zero-timeout polls/frame each paid the old
             * pickup latency: the 55-vs-60 FPS gap. */
            {
                unsigned long long sleep_ns = 1000000ull;
                /* ml585: timer lateness = how long past a due timer's deadline
                 * we actually resumed. This is the number that matters for the
                 * 77s Steam stalls — a starved loop shows up here even when the
                 * event counts look ordinary. Measured around the sleep only. */
                static mach_timebase_info_data_t lt_tb;
                unsigned long long lt_t0, lt_slept_ns;
                if (!lt_tb.denom) mach_timebase_info( &lt_tb );
                lt_t0 = mach_absolute_time();
                if (ios_next_timer_ns < sleep_ns) sleep_ns = ios_next_timer_ns;
                if (sleep_ns > 0)
                {
                    /* ml585 A/B, default OFF. MADEIRA_SRV_NOSEM=1 ignores the
                     * wake semaphore and sleeps the computed duration outright.
                     *
                     * Why: semaphore_signal() is a COUNTING operation and
                     * ios_srv_wake_sem_signal() (line ~42) fires on every
                     * client request with no coalescing and no drain. Once the
                     * signal rate exceeds the loop rate the count never reaches
                     * zero, semaphore_timedwait returns instantly forever, and
                     * the loop stops sleeping — ml584 measured 2,935 iter/s
                     * against a 1 ms floor that caps it at ~1,000/s.
                     *
                     * This gate changes ONLY the wait mechanism. sleep_ns is
                     * computed identically above, timers are processed by the
                     * same get_next_timeout() call, and no poll/readiness
                     * semantics change — so a difference between the two runs
                     * is attributable to the wake path alone. We still DRAIN
                     * the pending count so the backlog can't leak into a later
                     * toggle or mask the effect. */
                    static int nosem = -1;
                    if (nosem < 0)
                    {
                        const char *e = getenv("MADEIRA_SRV_NOSEM");
                        nosem = (e && *e == '1');
                        ws_log("[srv-poll] MADEIRA_SRV_NOSEM=%d (%s wake path)",
                               nosem, nosem ? "FIXED-SLEEP A/B" : "default semaphore");
                    }
                    if (ios_srv_wake_sem && !nosem)
                    {
                        mach_timespec_t wts;
                        kern_return_t wkr;
                        wts.tv_sec = (unsigned int)(sleep_ns / 1000000000ull);
                        wts.tv_nsec = (int)(sleep_ns % 1000000000ull);
                        wkr = semaphore_timedwait( ios_srv_wake_sem, wts );
                        if (wkr == KERN_OPERATION_TIMED_OUT) ios_c_semto++;
                        else ios_c_semret++;
                    }
                    else if (ios_srv_wake_sem && nosem)
                    {
                        static mach_timebase_info_data_t tb;
                        mach_timespec_t z = { 0, 0 };
                        unsigned long long dl;
                        /* drain every queued signal, then sleep the full tick */
                        while (semaphore_timedwait( ios_srv_wake_sem, z ) == KERN_SUCCESS)
                            ios_c_semret++;
                        if (!tb.denom) mach_timebase_info( &tb );
                        dl = mach_absolute_time() + sleep_ns * tb.denom / tb.numer;
                        mach_wait_until( dl );
                        ios_c_semto++;
                    }
                    else
                    {
                        static mach_timebase_info_data_t ios_tb;
                        unsigned long long deadline;
                        if (!ios_tb.denom) mach_timebase_info( &ios_tb );
                        deadline = mach_absolute_time()
                                 + sleep_ns * ios_tb.denom / ios_tb.numer;
                        mach_wait_until( deadline );
                    }
                }
                lt_slept_ns = (mach_absolute_time() - lt_t0) * lt_tb.numer / lt_tb.denom;
                if (ios_next_timer_ns != ~0ull && lt_slept_ns > ios_next_timer_ns)
                {
                    unsigned long long late_us = (lt_slept_ns - ios_next_timer_ns) / 1000ull;
                    if (late_us > ios_late_max_us) ios_late_max_us = late_us;
                }
            }
            set_current_time();

            /* Real sockets first: zero-timeout poll() gives true INET
             * event semantics (connect completion, errors, data). See
             * ios_fd_is_inet comment. Dispatch re-checks fd identity —
             * fd_poll_event may remove/reuse later poll users. */
            {
                /* ml160 (#36): this loop used to stop at the FIRST 64 INET
                 * fds (`nrp < 64`), silently dropping every one past that on
                 * every iteration — so those sockets were never polled and
                 * their asyncs never completed. Steam's symptom matched
                 * exactly: the EARLY connect (few fds live) completes after
                 * ~400 polls, while three LATER blocking connects get ZERO
                 * poll_socket calls and Steam quits after the third.
                 *
                 * Now batched: poll ALL INET fds, 64 at a time. The counters
                 * prove whether the old cap was actually being exceeded —
                 * if inet_seen never exceeds 64, the cap was NOT the bug and
                 * this change is merely harmless. */
                struct pollfd rp[64];
                int rp_user[64];
                int nrp = 0, k;
                int inet_seen = 0;
                static unsigned ios_inet_cap_reports;
                static int ios_inet_max_seen;

                for (i = 1; i < nb_users; i++)
                {
                    if (pollfd[i].fd < 0 || !pollfd[i].events) continue;
                    if (!ios_fd_is_inet( i, pollfd[i].fd )) continue;
                    inet_seen++;
                    rp[nrp].fd = pollfd[i].fd;
                    rp[nrp].events = pollfd[i].events;
                    rp[nrp].revents = 0;
                    rp_user[nrp++] = i;

                    if (nrp < 64) continue;
                    if (poll( rp, nrp, 0 ) > 0)
                    {
                        for (k = 0; k < nrp; k++)
                        {
                            int u = rp_user[k];
                            if (!rp[k].revents) continue;
                            if (pollfd[u].fd != rp[k].fd) continue;
                            ios_events_fired++; ios_c_inet++;
                            fd_poll_event( poll_users[u], rp[k].revents );
                        }
                    }
                    nrp = 0;
                }
                if (nrp && poll( rp, nrp, 0 ) > 0)
                {
                    for (k = 0; k < nrp; k++)
                    {
                        int u = rp_user[k];
                        if (!rp[k].revents) continue;
                        if (pollfd[u].fd != rp[k].fd) continue;  /* user removed mid-dispatch */
                        ios_events_fired++; ios_c_inet++;
                        fd_poll_event( poll_users[u], rp[k].revents );
                    }
                }
                if (inet_seen > ios_inet_max_seen)
                {
                    ios_inet_max_seen = inet_seen;
                    if (inet_seen > 48 && ios_inet_cap_reports < 12)
                    {
                        ios_inet_cap_reports++;
                        ws_log("[inet-poll] max INET fds with events = %d (nb_users=%d)%s",
                               inet_seen, nb_users,
                               inet_seen > 64 ? "  <-- OLD 64-CAP WOULD HAVE DROPPED SOME" : "");
                    }
                }
            }

            /* Check non-master fds for events.
             * Init fds (signal pipes, files): use ioctl(FIONREAD) — works for pipes/files.
             * Client fds (socketpair, request pipe): always try non-blocking read —
             * ioctl(FIONREAD) is broken for AF_UNIX sockets on iOS.
             * INET sockets: handled by the real poll() above — skip here. */
            for (i = 1; i < nb_users; i++)
            {
                if (pollfd[i].fd >= 0 && pollfd[i].events)
                {
                    short revents = 0;

                    if (ios_fd_is_inet( i, pollfd[i].fd )) continue;

                    if (pollfd[i].events & POLLIN)
                    {
                        if (ios_client_fd_start >= 0 && i >= ios_client_fd_start)
                        {
                            /* Client fd (socketpair/pipe from injection) —
                             * always try, ioctl broken for AF_UNIX on iOS */
                            revents |= POLLIN;
                            ios_c_synin++;
                        }
                        else
                        {
                            /* Init fd — ioctl works for pipes and files */
                            int bytes_avail = 0;
                            if (ioctl( pollfd[i].fd, FIONREAD, &bytes_avail ) == 0 && bytes_avail > 0)
                                revents |= POLLIN;
                        }
                    }

                    if (pollfd[i].events & POLLOUT)
                    {
                        revents |= POLLOUT;
                        ios_c_synout++;
                    }

                    if (revents)
                    {
                        unsigned slot = (unsigned)i & 63;
                        ios_events_fired++;
                        if (++ios_syn_per_user[slot] > (unsigned)ios_syn_top_n)
                        {
                            ios_syn_top_n = (int)ios_syn_per_user[slot];
                            ios_syn_top_user = i;
                        }
                        fd_poll_event( poll_users[i], revents );
                    }
                }
            }

            /* Post-injection trace: log first 20 iterations after injection */
            if (ios_post_inject > 0)
            {
                ios_post_inject--;
                ws_log("[wineserver-fd] POST iter=%d act=%d nb=%d ef=%d", ios_iter, active_users, nb_users, ios_events_fired);
            }
        }
    }
    ws_log("[wineserver-fd] main_loop EXITED! active_users=%d", active_users);
#else
    while (active_users)
    {
        timeout = get_next_timeout( NULL );

        if (!active_users) break;  /* last user removed by a timeout */

        ret = poll( pollfd, nb_users, timeout );
        set_current_time();

        if (ret > 0)
        {
            for (i = 0; i < nb_users; i++)
            {
                if (pollfd[i].revents)
                {
                    fd_poll_event( poll_users[i], pollfd[i].revents );
                    if (!--ret) break;
                }
            }
        }
    }
#endif
}


/****************************************************************/
/* device functions */

static struct list device_hash[DEVICE_HASH_SIZE];

static int is_device_removable( dev_t dev, int unix_fd )
{
#if defined(linux) && defined(HAVE_FSTATFS)
    struct statfs stfs;

    /* check for floppy disk */
    if (major(dev) == FLOPPY_MAJOR) return 1;

    if (fstatfs( unix_fd, &stfs ) == -1) return 0;
    return (stfs.f_type == 0x9660 ||    /* iso9660 */
            stfs.f_type == 0x9fa1 ||    /* supermount */
            stfs.f_type == 0x15013346); /* udf */
#elif defined(__FreeBSD__) || defined(__FreeBSD_kernel__) || defined(__DragonFly__) || defined(__APPLE__)
    struct statfs stfs;

    if (fstatfs( unix_fd, &stfs ) == -1) return 0;
    return (!strcmp("cd9660", stfs.f_fstypename) || !strcmp("udf", stfs.f_fstypename));
#elif defined(__NetBSD__)
    struct statvfs stfs;

    if (fstatvfs( unix_fd, &stfs ) == -1) return 0;
    return (!strcmp("cd9660", stfs.f_fstypename) || !strcmp("udf", stfs.f_fstypename));
#elif defined(sun)
# include <sys/dkio.h>
# include <sys/vtoc.h>
    struct dk_cinfo dkinf;
    if (ioctl( unix_fd, DKIOCINFO, &dkinf ) == -1) return 0;
    return (dkinf.dki_ctype == DKC_CDROM ||
            dkinf.dki_ctype == DKC_NCRFLOPPY ||
            dkinf.dki_ctype == DKC_SMSFLOPPY ||
            dkinf.dki_ctype == DKC_INTEL82072 ||
            dkinf.dki_ctype == DKC_INTEL82077);
#else
    return 0;
#endif
}

/* retrieve the device object for a given fd, creating it if needed */
static struct device *get_device( dev_t dev, int unix_fd )
{
    struct device *device;
    unsigned int i, hash = dev % DEVICE_HASH_SIZE;

    if (device_hash[hash].next)
    {
        LIST_FOR_EACH_ENTRY( device, &device_hash[hash], struct device, entry )
            if (device->dev == dev) return (struct device *)grab_object( device );
    }
    else list_init( &device_hash[hash] );

    /* not found, create it */

    if (unix_fd == -1) return NULL;
    if ((device = alloc_object( &device_ops )))
    {
        device->dev = dev;
        device->removable = is_device_removable( dev, unix_fd );
        for (i = 0; i < INODE_HASH_SIZE; i++) list_init( &device->inode_hash[i] );
        list_add_head( &device_hash[hash], &device->entry );
    }
    return device;
}

static void device_dump( struct object *obj, int verbose )
{
    struct device *device = (struct device *)obj;
    fprintf( stderr, "Device dev=" );
    DUMP_LONG_LONG( device->dev );
    fprintf( stderr, "\n" );
}

static void device_destroy( struct object *obj )
{
    struct device *device = (struct device *)obj;
    unsigned int i;

    for (i = 0; i < INODE_HASH_SIZE; i++)
        assert( list_empty(&device->inode_hash[i]) );

    list_remove( &device->entry );  /* remove it from the hash table */
}

/****************************************************************/
/* inode functions */

static void unlink_closed_fd( struct inode *inode, struct closed_fd *fd )
{
    /* make sure it is still the same file */
    struct stat st;
    if (!stat( fd->unix_name, &st ) && st.st_dev == inode->device->dev && st.st_ino == inode->ino)
    {
        if (S_ISDIR(st.st_mode)) rmdir( fd->unix_name );
        else unlink( fd->unix_name );
    }
}

/* close all pending file descriptors in the closed list */
static void inode_close_pending( struct inode *inode, int keep_unlinks )
{
    struct list *ptr = list_head( &inode->closed );

    while (ptr)
    {
        struct closed_fd *fd = LIST_ENTRY( ptr, struct closed_fd, entry );
        struct list *next = list_next( &inode->closed, ptr );

        if (fd->unix_fd != -1)
        {
            close( fd->unix_fd );
            fd->unix_fd = -1;
        }

        /* get rid of it unless there's an unlink pending on that file */
        if (!keep_unlinks || !(fd->disp_flags & FILE_DISPOSITION_DELETE))
        {
            list_remove( ptr );
            free( fd->unix_name );
            free( fd );
        }
        ptr = next;
    }
}

static void inode_dump( struct object *obj, int verbose )
{
    struct inode *inode = (struct inode *)obj;
    fprintf( stderr, "Inode device=%p ino=", inode->device );
    DUMP_LONG_LONG( inode->ino );
    fprintf( stderr, "\n" );
}

static void inode_destroy( struct object *obj )
{
    struct inode *inode = (struct inode *)obj;
    struct list *ptr;

    assert( list_empty(&inode->open) );
    assert( list_empty(&inode->locks) );

    list_remove( &inode->entry );

    while ((ptr = list_head( &inode->closed )))
    {
        struct closed_fd *fd = LIST_ENTRY( ptr, struct closed_fd, entry );
        list_remove( ptr );
        if (fd->unix_fd != -1) close( fd->unix_fd );
        if (fd->disp_flags & FILE_DISPOSITION_DELETE)
            unlink_closed_fd( inode, fd );
        free( fd->unix_name );
        free( fd );
    }
    release_object( inode->device );
}

/* retrieve the inode object for a given fd, creating it if needed */
static struct inode *get_inode( dev_t dev, ino_t ino, int unix_fd )
{
    struct device *device;
    struct inode *inode;
    unsigned int hash = ino % INODE_HASH_SIZE;

    if (!(device = get_device( dev, unix_fd ))) return NULL;

    LIST_FOR_EACH_ENTRY( inode, &device->inode_hash[hash], struct inode, entry )
    {
        if (inode->ino == ino)
        {
            release_object( device );
            return (struct inode *)grab_object( inode );
        }
    }

    /* not found, create it */
    if ((inode = alloc_object( &inode_ops )))
    {
        inode->device = device;
        inode->ino    = ino;
        list_init( &inode->open );
        list_init( &inode->locks );
        list_init( &inode->closed );
        list_add_head( &device->inode_hash[hash], &inode->entry );
    }
    else release_object( device );

    return inode;
}

static int inode_has_pending_close( struct inode *inode, const char *path )
{
    struct closed_fd *fd;

    LIST_FOR_EACH_ENTRY( fd, &inode->closed, struct closed_fd, entry )
        if (!strcmp( fd->unix_name, path )) return 1;
    return 0;
}

/* add fd to the inode list of file descriptors to close */
static void inode_add_closed_fd( struct inode *inode, struct closed_fd *fd )
{
    if (!list_empty( &inode->locks ))
    {
        list_add_head( &inode->closed, &fd->entry );
    }
    else if ((fd->disp_flags & FILE_DISPOSITION_DELETE) &&
        (fd->disp_flags & FILE_DISPOSITION_POSIX_SEMANTICS))
    {
        /* close the fd and unlink it at once */
        if (fd->unix_fd != -1) close( fd->unix_fd );
        unlink_closed_fd( inode, fd );
        free( fd->unix_name );
        free( fd );
    }
    else if ((fd->disp_flags & FILE_DISPOSITION_DELETE) && !inode_has_pending_close( inode, fd->unix_name ))
    {
        /* close the fd but keep the structure around for unlink */
        if (fd->unix_fd != -1) close( fd->unix_fd );
        fd->unix_fd = -1;
        list_add_head( &inode->closed, &fd->entry );
    }
    else  /* no locks on this inode and no unlink, get rid of the fd */
    {
        if (fd->unix_fd != -1) close( fd->unix_fd );
        free( fd->unix_name );
        free( fd );
    }
}


/****************************************************************/
/* file lock functions */

static void file_lock_dump( struct object *obj, int verbose )
{
    struct file_lock *lock = (struct file_lock *)obj;
    fprintf( stderr, "Lock %s fd=%p proc=%p start=",
             lock->shared ? "shared" : "excl", lock->fd, lock->process );
    DUMP_LONG_LONG( lock->start );
    fprintf( stderr, " end=" );
    DUMP_LONG_LONG( lock->end );
    fprintf( stderr, "\n" );
}

static struct object *file_lock_get_sync( struct object *obj )
{
    struct file_lock *lock = (struct file_lock *)obj;
    assert( obj->ops == &file_lock_ops );
    return grab_object( lock->sync );
}

static void file_lock_destroy( struct object *obj )
{
    struct file_lock *lock = (struct file_lock *)obj;
    assert( obj->ops == &file_lock_ops );
    if (lock->sync) release_object( lock->sync );
}

/* set (or remove) a Unix lock if possible for the given range */
static int set_unix_lock( struct fd *fd, file_pos_t start, file_pos_t end, int type )
{
    struct flock fl;

    if (!fd->fs_locks) return 1;  /* no fs locks possible for this fd */
    for (;;)
    {
        if (start == end) return 1;  /* can't set zero-byte lock */
        if (start > max_unix_offset) return 1;  /* ignore it */
        fl.l_type   = type;
        fl.l_whence = SEEK_SET;
        fl.l_start  = start;
        if (!end || end > max_unix_offset) fl.l_len = 0;
        else fl.l_len = end - start;
        if (fcntl( fd->unix_fd, F_SETLK, &fl ) != -1) return 1;

        switch(errno)
        {
        case EACCES:
            /* check whether locks work at all on this file system */
            if (fcntl( fd->unix_fd, F_GETLK, &fl ) != -1)
            {
                set_error( STATUS_FILE_LOCK_CONFLICT );
                return 0;
            }
            /* fall through */
        case EIO:
        case ENOLCK:
        case ENOTSUP:
            /* no locking on this fs, just ignore it */
            fd->fs_locks = 0;
            return 1;
        case EAGAIN:
            set_error( STATUS_FILE_LOCK_CONFLICT );
            return 0;
        case EBADF:
            /* this can happen if we try to set a write lock on a read-only file */
            /* try to at least grab a read lock */
            if (fl.l_type == F_WRLCK)
            {
                type = F_RDLCK;
                break; /* retry */
            }
            set_error( STATUS_ACCESS_DENIED );
            return 0;
#ifdef EOVERFLOW
        case EOVERFLOW:
#endif
        case EINVAL:
            /* this can happen if off_t is 64-bit but the kernel only supports 32-bit */
            /* in that case we shrink the limit and retry */
            if (max_unix_offset > INT_MAX)
            {
                max_unix_offset = INT_MAX;
                break;  /* retry */
            }
            /* fall through */
        default:
            file_set_error();
            return 0;
        }
    }
}

/* check if interval [start;end) overlaps the lock */
static inline int lock_overlaps( struct file_lock *lock, file_pos_t start, file_pos_t end )
{
    if (lock->end && start >= lock->end) return 0;
    if (end && lock->start >= end) return 0;
    return 1;
}

/* remove Unix locks for all bytes in the specified area that are no longer locked */
static void remove_unix_locks( struct fd *fd, file_pos_t start, file_pos_t end )
{
    struct hole
    {
        struct hole *next;
        struct hole *prev;
        file_pos_t   start;
        file_pos_t   end;
    } *first, *cur, *next, *buffer;

    struct file_lock *lock;
    int count = 0;

    if (!fd->inode) return;
    if (!fd->fs_locks) return;
    if (start == end || start > max_unix_offset) return;
    if (!end || end > max_unix_offset) end = max_unix_offset + 1;

    /* count the number of locks overlapping the specified area */

    LIST_FOR_EACH_ENTRY( lock, &fd->inode->locks, struct file_lock, inode_entry )
    {
        if (lock->start == lock->end) continue;
        if (lock_overlaps( lock, start, end )) count++;
    }

    if (!count)  /* no locks at all, we can unlock everything */
    {
        set_unix_lock( fd, start, end, F_UNLCK );
        return;
    }

    /* allocate space for the list of holes */
    /* max. number of holes is number of locks + 1 */

    if (!(buffer = malloc( sizeof(*buffer) * (count+1) ))) return;
    first = buffer;
    first->next  = NULL;
    first->prev  = NULL;
    first->start = start;
    first->end   = end;
    next = first + 1;

    /* build a sorted list of unlocked holes in the specified area */

    LIST_FOR_EACH_ENTRY( lock, &fd->inode->locks, struct file_lock, inode_entry )
    {
        if (lock->start == lock->end) continue;
        if (!lock_overlaps( lock, start, end )) continue;

        /* go through all the holes touched by this lock */
        for (cur = first; cur; cur = cur->next)
        {
            if (cur->end <= lock->start) continue; /* hole is before start of lock */
            if (lock->end && cur->start >= lock->end) break;  /* hole is after end of lock */

            /* now we know that lock is overlapping hole */

            if (cur->start >= lock->start)  /* lock starts before hole, shrink from start */
            {
                cur->start = lock->end;
                if (cur->start && cur->start < cur->end) break;  /* done with this lock */
                /* now hole is empty, remove it */
                if (cur->next) cur->next->prev = cur->prev;
                if (cur->prev) cur->prev->next = cur->next;
                else if (!(first = cur->next)) goto done;  /* no more holes at all */
            }
            else if (!lock->end || cur->end <= lock->end)  /* lock larger than hole, shrink from end */
            {
                cur->end = lock->start;
                assert( cur->start < cur->end );
            }
            else  /* lock is in the middle of hole, split hole in two */
            {
                next->prev = cur;
                next->next = cur->next;
                cur->next = next;
                next->start = lock->end;
                next->end = cur->end;
                cur->end = lock->start;
                assert( next->start < next->end );
                assert( cur->end < next->start );
                next++;
                break;  /* done with this lock */
            }
        }
    }

    /* clear Unix locks for all the holes */

    for (cur = first; cur; cur = cur->next)
        set_unix_lock( fd, cur->start, cur->end, F_UNLCK );

 done:
    free( buffer );
}

/* create a new lock on a fd */
static struct file_lock *add_lock( struct fd *fd, int shared, file_pos_t start, file_pos_t end )
{
    struct file_lock *lock;

    if (!(lock = alloc_object( &file_lock_ops ))) return NULL;
    lock->sync    = NULL;
    lock->shared  = shared;
    lock->start   = start;
    lock->end     = end;
    lock->fd      = fd;
    lock->process = current->process;

    if (!(lock->sync = create_internal_sync( 1, 0 ))) goto error;
    /* now try to set a Unix lock */
    if (!set_unix_lock( lock->fd, lock->start, lock->end, lock->shared ? F_RDLCK : F_WRLCK )) goto error;
    list_add_tail( &fd->locks, &lock->fd_entry );
    list_add_tail( &fd->inode->locks, &lock->inode_entry );
    list_add_tail( &lock->process->locks, &lock->proc_entry );
    return lock;

error:
    release_object( lock );
    return NULL;
}

/* remove an existing lock */
static void remove_lock( struct file_lock *lock, int remove_unix )
{
    struct inode *inode = lock->fd->inode;

    list_remove( &lock->fd_entry );
    list_remove( &lock->inode_entry );
    list_remove( &lock->proc_entry );
    if (remove_unix) remove_unix_locks( lock->fd, lock->start, lock->end );
    if (list_empty( &inode->locks )) inode_close_pending( inode, 1 );
    lock->process = NULL;
    signal_sync( lock->sync );
    release_object( lock );
}

/* remove all locks owned by a given process */
void remove_process_locks( struct process *process )
{
    struct list *ptr;

    while ((ptr = list_head( &process->locks )))
    {
        struct file_lock *lock = LIST_ENTRY( ptr, struct file_lock, proc_entry );
        remove_lock( lock, 1 );  /* this removes it from the list */
    }
}

/* remove all locks on a given fd */
static void remove_fd_locks( struct fd *fd )
{
    file_pos_t start = FILE_POS_T_MAX, end = 0;
    struct list *ptr;

    while ((ptr = list_head( &fd->locks )))
    {
        struct file_lock *lock = LIST_ENTRY( ptr, struct file_lock, fd_entry );
        if (lock->start < start) start = lock->start;
        if (!lock->end || lock->end > end) end = lock->end - 1;
        remove_lock( lock, 0 );
    }
    if (start < end) remove_unix_locks( fd, start, end + 1 );
}

/* add a lock on an fd */
/* returns handle to wait on */
obj_handle_t lock_fd( struct fd *fd, file_pos_t start, file_pos_t count, int shared, int wait )
{
    struct file_lock *lock;
    file_pos_t end = start + count;

    if (!fd->inode)  /* not a regular file */
    {
        set_error( STATUS_INVALID_DEVICE_REQUEST );
        return 0;
    }

    /* don't allow wrapping locks */
    if (end && end < start)
    {
        set_error( STATUS_INVALID_PARAMETER );
        return 0;
    }

    /* check if another lock on that file overlaps the area */
    LIST_FOR_EACH_ENTRY( lock, &fd->inode->locks, struct file_lock, inode_entry )
    {
        if (!lock_overlaps( lock, start, end )) continue;
        if (shared && (lock->shared || lock->fd == fd)) continue;
        /* found one */
        if (!wait)
        {
            set_error( STATUS_FILE_LOCK_CONFLICT );
            return 0;
        }
        set_error( STATUS_PENDING );
        return alloc_handle( current->process, lock, SYNCHRONIZE, 0 );
    }

    /* not found, add it */
    if (add_lock( fd, shared, start, end )) return 0;
    if (get_error() == STATUS_FILE_LOCK_CONFLICT)
    {
        /* Unix lock conflict -> tell client to wait and retry */
        if (wait) set_error( STATUS_PENDING );
    }
    return 0;
}

/* remove a lock on an fd */
void unlock_fd( struct fd *fd, file_pos_t start, file_pos_t count )
{
    struct file_lock *lock;
    file_pos_t end = start + count;

    /* find an existing lock with the exact same parameters */
    LIST_FOR_EACH_ENTRY( lock, &fd->locks, struct file_lock, fd_entry )
    {
        if ((lock->start == start) && (lock->end == end))
        {
            remove_lock( lock, 1 );
            return;
        }
    }
    set_error( STATUS_FILE_LOCK_CONFLICT );
}


/****************************************************************/
/* file descriptor functions */

static void fd_dump( struct object *obj, int verbose )
{
    struct fd *fd = (struct fd *)obj;
    fprintf( stderr, "Fd unix_fd=%d user=%p options=%08x", fd->unix_fd, fd->user, fd->options );
    if (fd->inode) fprintf( stderr, " inode=%p disp_flags=%x", fd->inode, fd->closed->disp_flags );
    fprintf( stderr, "\n" );
}

static struct object *fd_get_sync( struct object *obj )
{
    struct fd *fd = (struct fd *)obj;
    return grab_object( fd->sync );
}

static void fd_destroy( struct object *obj )
{
    struct fd *fd = (struct fd *)obj;

    free_async_queue( &fd->read_q );
    free_async_queue( &fd->write_q );
    free_async_queue( &fd->wait_q );

    if (fd->map_addr) free_map_addr( fd->map_addr, fd->map_size );
    if (fd->completion) release_object( fd->completion );
    remove_fd_locks( fd );
    list_remove( &fd->inode_entry );
    if (fd->poll_index != -1) remove_poll_user( fd, fd->poll_index );
    free( fd->nt_name );
    if (fd->inode)
    {
        inode_add_closed_fd( fd->inode, fd->closed );
        release_object( fd->inode );
    }
    else  /* no inode, close it right away */
    {
        if (fd->unix_fd != -1) close( fd->unix_fd );
        free( fd->unix_name );
    }
    if (fd->sync) release_object( fd->sync );
}

/* check if the desired access is possible without violating */
/* the sharing mode of other opens of the same file */
/* ml960: name the CONFLICTING holder on a sharing violation.
 *
 * rdr25's first failure is STATUS_SHARING_VIOLATION on a guest's own state
 * file, opened FILE_OVERWRITE_IF for write with sharing=FILE_SHARE_READ, which
 * is why that file sits at 0 bytes on disk. The violation means another fd on
 * the same inode holds write access (or does not share write), but the
 * client-side probe can only report its own failed request -- it cannot see the
 * holder. This is the one place that can: fd->inode->open is the authoritative
 * list. Attribution matters because the plausible causes need opposite fixes:
 * an fd leaked by an exited pseudo-process (fd ownership at teardown is a known
 * unresolved area here) versus a second live open that Windows would permit.
 *
 * Only on the violation paths, so it cannot flood, and capped regardless. */
static void ml960_report_sharing( struct fd *fd, unsigned int access, unsigned int sharing,
                                  unsigned int options, int which )
{
    static int ml960_n;
    struct fd *o;
    int others = 0;

    if (ml960_n >= 16) return;
    ml960_n++;

    fprintf( stderr, "ml960: SHARING VIOLATION (check %d) on \"%s\": request access=%08x "
             "sharing=%08x options=%08x by pid=%04x tid=%04x\n", which,
             fd->unix_name ? fd->unix_name : "(no unix name)", access, sharing, options,
             current ? current->process->id : 0, current ? current->id : 0 );
    LIST_FOR_EACH_ENTRY( o, &fd->inode->open, struct fd, inode_entry )
    {
        if (o == fd) continue;
        others++;
        /* ml978: name the holder's origin and whether that process still exists.
         * A DEAD owner means a handle outlived its pseudo-process -- our bug, in
         * teardown. A live one means a genuine second open, which Windows would
         * also refuse and which must NOT be "fixed" by relaxing sharing. */
        {
            struct process *op = o->open_pid ? get_process_from_id( o->open_pid ) : NULL;
            const char *alive = !o->open_pid ? "server-internal"
                              : (op ? "ALIVE" : "DEAD -- handle outlived its process");
            fprintf( stderr, "ml960:   holder #%d unix_fd=%d access=%08x sharing=%08x options=%08x "
                     "opened_by pid=%04x tid=%04x [%s] same_process=%d name=\"%s\"\n",
                     others, o->unix_fd, o->access, o->sharing, o->options,
                     o->open_pid, o->open_tid, alive,
                     (current && o->open_pid == current->process->id) ? 1 : 0,
                     o->unix_name ? o->unix_name : "(no unix name)" );
            if (op) release_object( op );
        }
    }
    if (!others)
        fprintf( stderr, "ml960:   NO other fd on this inode -- the verdict came from the "
                 "mapping/access bits, not a second opener\n" );
    fflush( stderr );
}

static unsigned int check_sharing( struct fd *fd, unsigned int access, unsigned int sharing,
                                   unsigned int open_flags, unsigned int options )
{
    /* only a few access bits are meaningful wrt sharing */
    const unsigned int read_access = FILE_READ_DATA | FILE_EXECUTE;
    const unsigned int write_access = FILE_WRITE_DATA | FILE_APPEND_DATA;
    const unsigned int all_access = read_access | write_access | DELETE;

    unsigned int existing_sharing = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
    unsigned int existing_access = 0;
    struct fd *fd_ptr;

    fd->access = access;
    fd->sharing = sharing;

    LIST_FOR_EACH_ENTRY( fd_ptr, &fd->inode->open, struct fd, inode_entry )
    {
        if (fd_ptr == fd) continue;
        /* if access mode is 0, sharing mode is ignored */
        if (fd_ptr->access & all_access) existing_sharing &= fd_ptr->sharing;
        existing_access |= fd_ptr->access;
    }

    if (((access & read_access) && !(existing_sharing & FILE_SHARE_READ)) ||
        ((access & write_access) && !(existing_sharing & FILE_SHARE_WRITE)) ||
        ((access & DELETE) && !(existing_sharing & FILE_SHARE_DELETE)))
    {
        ml960_report_sharing( fd, access, sharing, options, 1 );
        return STATUS_SHARING_VIOLATION;
    }
    if (((existing_access & FILE_MAPPING_WRITE) && !(sharing & FILE_SHARE_WRITE)) ||
        ((existing_access & FILE_MAPPING_IMAGE) && (access & FILE_WRITE_DATA)))
    {
        ml960_report_sharing( fd, access, sharing, options, 2 );
        return STATUS_SHARING_VIOLATION;
    }
    if ((existing_access & FILE_MAPPING_IMAGE) && (options & FILE_DELETE_ON_CLOSE))
        return STATUS_CANNOT_DELETE;
    if ((existing_access & FILE_MAPPING_ACCESS) && (open_flags & O_TRUNC))
        return STATUS_USER_MAPPED_FILE;
    if (!(access & all_access))
        return 0;  /* if access mode is 0, sharing mode is ignored (except for mappings) */
    if (((existing_access & read_access) && !(sharing & FILE_SHARE_READ)) ||
        ((existing_access & write_access) && !(sharing & FILE_SHARE_WRITE)) ||
        ((existing_access & DELETE) && !(sharing & FILE_SHARE_DELETE)))
    {
        ml960_report_sharing( fd, access, sharing, options, 3 );
        return STATUS_SHARING_VIOLATION;
    }
    return 0;
}

/* set the events that select waits for on this fd */
void set_fd_events( struct fd *fd, int events )
{
    int user = fd->poll_index;
    assert( poll_users[user] == fd );

    set_fd_epoll_events( fd, user, events );

    if (events == -1)  /* stop waiting on this fd completely */
    {
        pollfd[user].fd = -1;
        pollfd[user].events = POLLERR;
        pollfd[user].revents = 0;
    }
    else
    {
        pollfd[user].fd = fd->unix_fd;
        pollfd[user].events = events;
    }
}

/* prepare an fd for unmounting its corresponding device */
static inline void unmount_fd( struct fd *fd )
{
    assert( fd->inode );

    async_wake_up( &fd->read_q, STATUS_VOLUME_DISMOUNTED );
    async_wake_up( &fd->write_q, STATUS_VOLUME_DISMOUNTED );

    if (fd->poll_index != -1) set_fd_events( fd, -1 );

    if (fd->unix_fd != -1) close( fd->unix_fd );

    fd->unix_fd = -1;
    fd->no_fd_status = STATUS_VOLUME_DISMOUNTED;
    fd->closed->unix_fd = -1;
    fd->closed->disp_flags = 0;

    /* stop using Unix locks on this fd (existing locks have been removed by close) */
    fd->fs_locks = 0;
}

/* allocate an fd object, without setting the unix fd yet */
static struct fd *alloc_fd_object(void)
{
    struct fd *fd = alloc_object( &fd_ops );

    if (!fd) return NULL;

    fd->fd_ops     = NULL;
    fd->sync       = NULL;
    fd->user       = NULL;
    fd->inode      = NULL;
    fd->closed     = NULL;
    fd->map_addr   = 0;
    fd->map_size   = 0;
    fd->access     = 0;
    fd->options    = 0;
    fd->sharing    = 0;
    fd->unix_fd    = -1;
    fd->unix_name  = NULL;
    fd->nt_name    = NULL;
    fd->nt_namelen = 0;
    fd->cacheable  = 0;
    fd->fs_locks   = 1;
    fd->poll_index = -1;
    fd->completion = NULL;
    fd->comp_flags = 0;
    /* ml978: `current` is the requesting thread here; it is NULL only for fds
     * the server makes for itself, which is worth showing as 0000 rather than
     * guessing at. */
    fd->open_pid   = current ? current->process->id : 0;
    fd->open_tid   = current ? current->id : 0;
    init_async_queue( &fd->read_q );
    init_async_queue( &fd->write_q );
    init_async_queue( &fd->wait_q );
    list_init( &fd->inode_entry );
    list_init( &fd->locks );

    if (!(fd->sync = create_internal_sync( 1, 1 ))) goto error;
    if ((fd->poll_index = add_poll_user( fd )) == -1) goto error;

    return fd;

error:
    release_object( fd );
    return NULL;
}

/* allocate a pseudo fd object, for objects that need to behave like files but don't have a unix fd */
struct fd *alloc_pseudo_fd( const struct fd_ops *fd_user_ops, struct object *user, unsigned int options )
{
    struct fd *fd = alloc_object( &fd_ops );

    if (!fd) return NULL;

    fd->fd_ops     = fd_user_ops;
    fd->sync       = NULL;
    fd->user       = user;
    fd->inode      = NULL;
    fd->closed     = NULL;
    fd->map_addr   = 0;
    fd->map_size   = 0;
    fd->access     = 0;
    fd->options    = options;
    fd->sharing    = 0;
    fd->unix_name  = NULL;
    fd->nt_name    = NULL;
    fd->nt_namelen = 0;
    fd->unix_fd    = -1;
    fd->cacheable  = 0;
    fd->fs_locks   = 0;
    fd->poll_index = -1;
    fd->completion = NULL;
    fd->comp_flags = 0;
    fd->no_fd_status = STATUS_BAD_DEVICE_TYPE;
    /* ml978: a duplicated fd is attributed to whoever duplicates it, which is
     * the process that will hold it -- not to the original opener. */
    fd->open_pid   = current ? current->process->id : 0;
    fd->open_tid   = current ? current->id : 0;
    init_async_queue( &fd->read_q );
    init_async_queue( &fd->write_q );
    init_async_queue( &fd->wait_q );
    list_init( &fd->inode_entry );
    list_init( &fd->locks );

    if (!(fd->sync = create_internal_sync( 1, 1 )))
    {
        release_object( fd );
        return NULL;
    }
    return fd;
}

/* duplicate an fd object for a different user */
struct fd *dup_fd_object( struct fd *orig, unsigned int access, unsigned int sharing, unsigned int options )
{
    unsigned int err;
    struct fd *fd = alloc_fd_object();

    if (!fd) return NULL;

    fd->options    = options;
    fd->cacheable  = orig->cacheable;

    if (orig->unix_name)
    {
        if (!(fd->unix_name = mem_alloc( strlen(orig->unix_name) + 1 ))) goto failed;
        strcpy( fd->unix_name, orig->unix_name );
    }
    if (orig->nt_namelen)
    {
        if (!(fd->nt_name = memdup( orig->nt_name, orig->nt_namelen ))) goto failed;
        fd->nt_namelen = orig->nt_namelen;
    }

    if (orig->inode)
    {
        struct closed_fd *closed = mem_alloc( sizeof(*closed) );
        if (!closed) goto failed;
        if ((fd->unix_fd = dup( orig->unix_fd )) == -1)
        {
            file_set_error();
            free( closed );
            goto failed;
        }
        closed->unix_fd = fd->unix_fd;
        closed->disp_flags = 0;
        closed->unix_name = fd->unix_name;
        fd->closed = closed;
        fd->inode = (struct inode *)grab_object( orig->inode );
        list_add_head( &fd->inode->open, &fd->inode_entry );
        if ((err = check_sharing( fd, access, sharing, 0, options )))
        {
            set_error( err );
            goto failed;
        }
    }
    else if ((fd->unix_fd = dup( orig->unix_fd )) == -1)
    {
        file_set_error();
        goto failed;
    }
    return fd;

failed:
    release_object( fd );
    return NULL;
}

/* find an existing fd object that can be reused for a mapping */
struct fd *get_fd_object_for_mapping( struct fd *fd, unsigned int access, unsigned int sharing )
{
    struct fd *fd_ptr;

    if (!fd->inode) return NULL;

    LIST_FOR_EACH_ENTRY( fd_ptr, &fd->inode->open, struct fd, inode_entry )
        if (fd_ptr->access == access && fd_ptr->sharing == sharing)
            return (struct fd *)grab_object( fd_ptr );

    return NULL;
}

/* sets the user of an fd that previously had no user */
void set_fd_user( struct fd *fd, const struct fd_ops *user_ops, struct object *user )
{
    assert( fd->fd_ops == NULL );
    fd->fd_ops = user_ops;
    fd->user   = user;
}

char *dup_fd_name( struct fd *root, const char *name )
{
    char *ret;

    if (!root) return strdup( name );
    if (!root->unix_name) return NULL;

    /* skip . prefix */
    if (name[0] == '.' && (!name[1] || name[1] == '/')) name++;

    if ((ret = malloc( strlen(root->unix_name) + strlen(name) + 2 )))
    {
        strcpy( ret, root->unix_name );
        if (name[0] && name[0] != '/') strcat( ret, "/" );
        strcat( ret, name );
    }
    return ret;
}

static WCHAR *dup_nt_name( struct fd *root, struct unicode_str name, data_size_t *len )
{
    WCHAR *ptr, *ret;

    if (!root)
    {
        *len = name.len;
        if (!name.len) return NULL;
        return memdup( name.str, name.len );
    }
    if (!root->nt_namelen) return NULL;

    /* skip . prefix */
    if (name.len && name.str[0] == '.' && (name.len == sizeof(WCHAR) || name.str[1] == '\\'))
    {
        name.str++;
        name.len -= sizeof(WCHAR);
    }
    if ((ret = malloc( root->nt_namelen + name.len + sizeof(WCHAR) )))
    {
        ptr = mem_append( ret, root->nt_name, root->nt_namelen );
        if (name.len && name.str[0] != '\\' && ptr[-1] != '\\') *ptr++ = '\\';
        ptr = mem_append( ptr, name.str, name.len );
        *len = (ptr - ret) * sizeof(WCHAR);
    }
    return ret;
}

void get_nt_name( struct fd *fd, struct unicode_str *name )
{
    name->str = fd->nt_name;
    name->len = fd->nt_namelen;
}

/* open() wrapper that returns a struct fd with no fd user set */
struct fd *open_fd( struct fd *root, const char *name, struct unicode_str nt_name,
                    int flags, mode_t *mode, unsigned int access,
                    unsigned int sharing, unsigned int options )
{
    struct stat st;
    struct closed_fd *closed_fd;
    struct fd *fd;
    int root_fd = -1;
    int rw_mode;
    char *path;

    if (((options & FILE_DELETE_ON_CLOSE) && !(access & DELETE)) ||
        ((options & FILE_DIRECTORY_FILE) && (flags & O_TRUNC)))
    {
        set_error( STATUS_INVALID_PARAMETER );
        return NULL;
    }

    if (!(fd = alloc_fd_object())) return NULL;

    fd->options = options;
    if (!(closed_fd = mem_alloc( sizeof(*closed_fd) )))
    {
        release_object( fd );
        return NULL;
    }

    if (root)
    {
        if ((root_fd = get_unix_fd( root )) == -1) goto error;
        if (fchdir( root_fd ) == -1)
        {
            file_set_error();
            root_fd = -1;
            goto error;
        }
    }

    /* create the directory if needed */
    if ((options & FILE_DIRECTORY_FILE) && (flags & O_CREAT))
    {
        if (mkdir( name, *mode ) == -1)
        {
            if (errno != EEXIST || (flags & O_EXCL))
            {
                file_set_error();
                goto error;
            }
        }
        flags &= ~(O_CREAT | O_EXCL | O_TRUNC);
    }

    if ((access & FILE_UNIX_WRITE_ACCESS) && !(options & FILE_DIRECTORY_FILE))
    {
        if (access & FILE_UNIX_READ_ACCESS) rw_mode = O_RDWR;
        else rw_mode = O_WRONLY;
    }
    else rw_mode = O_RDONLY;

    if ((fd->unix_fd = open( name, rw_mode | (flags & ~O_TRUNC), *mode )) == -1)
    {
        /* if we tried to open a directory for write access, retry read-only */
        if (errno == EISDIR)
        {
            if ((access & FILE_UNIX_WRITE_ACCESS) || (flags & O_CREAT))
                fd->unix_fd = open( name, O_RDONLY | (flags & ~(O_TRUNC | O_CREAT | O_EXCL)), *mode );
        }

        if (fd->unix_fd == -1)
        {
            /* check for trailing slash on file path */
            if ((errno == ENOENT || (errno == ENOTDIR && !(options & FILE_DIRECTORY_FILE))) && name[strlen(name) - 1] == '/')
                set_error( STATUS_OBJECT_NAME_INVALID );
            else
                file_set_error();
            goto error;
        }
    }

    fd->nt_name = dup_nt_name( root, nt_name, &fd->nt_namelen );
    fd->unix_name = NULL;
    fstat( fd->unix_fd, &st );
    *mode = st.st_mode;

    /* only bother with an inode for normal files and directories */
    if (S_ISREG(st.st_mode) || S_ISDIR(st.st_mode))
    {
        unsigned int err;
        struct inode *inode = get_inode( st.st_dev, st.st_ino, fd->unix_fd );

        if (!inode)
        {
            /* we can close the fd because there are no others open on the same file,
             * otherwise we wouldn't have failed to allocate a new inode
             */
            goto error;
        }

        if ((path = dup_fd_name( root, name )))
        {
            fd->unix_name = realpath( path, NULL );
            free( path );
        }

        closed_fd->unix_fd = fd->unix_fd;
        closed_fd->unix_name = fd->unix_name;
        closed_fd->disp_flags = 0;
        fd->inode = inode;
        fd->closed = closed_fd;
        fd->cacheable = !inode->device->removable;
        list_add_head( &inode->open, &fd->inode_entry );
        closed_fd = NULL;

        /* check directory options */
        if ((options & FILE_DIRECTORY_FILE) && !S_ISDIR(st.st_mode))
        {
            set_error( STATUS_NOT_A_DIRECTORY );
            goto error;
        }
        if ((options & FILE_NON_DIRECTORY_FILE) && S_ISDIR(st.st_mode))
        {
            set_error( STATUS_FILE_IS_A_DIRECTORY );
            goto error;
        }
        if ((err = check_sharing( fd, access, sharing, flags, options )))
        {
            set_error( err );
            goto error;
        }

        /* can't unlink files if we don't have permission to access */
        if ((options & FILE_DELETE_ON_CLOSE) && !(flags & O_CREAT) &&
            !(st.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH)))
        {
            set_error( STATUS_CANNOT_DELETE );
            goto error;
        }

        fd->closed->disp_flags = (options & FILE_DELETE_ON_CLOSE) ?
            FILE_DISPOSITION_DELETE : 0;
        if (flags & O_TRUNC)
        {
            if (S_ISDIR(st.st_mode))
            {
                set_error( STATUS_OBJECT_NAME_COLLISION );
                goto error;
            }
            /* ml563: the OTHER shrink path — O_TRUNC. ml562 only covered
             * set_fd_eof(), so "no shrink logged" would have meant "not covered"
             * rather than "did not happen". Log dev+ino so a short section file
             * can be matched to the truncation that shortened it. */
            if (st.st_size > 0)
            {
                static unsigned long trunc0n;
                if (++trunc0n <= 64)
                    ws_log("[srv-trunc0] O_TRUNC fd=%d dev=%llu ino=%llu %lld -> 0 rev=ml563\n",
                           fd->unix_fd, (unsigned long long)st.st_dev,
                           (unsigned long long)st.st_ino, (long long)st.st_size);
            }
            ftruncate( fd->unix_fd, 0 );
        }
    }
    else  /* special file */
    {
        if (options & FILE_DELETE_ON_CLOSE)  /* we can't unlink special files */
        {
            set_error( STATUS_INVALID_PARAMETER );
            goto error;
        }
        free( closed_fd );
        fd->cacheable = 1;
    }

#ifdef HAVE_POSIX_FADVISE
    switch (options & (FILE_SEQUENTIAL_ONLY | FILE_RANDOM_ACCESS))
    {
    case FILE_SEQUENTIAL_ONLY:
        posix_fadvise( fd->unix_fd, 0, 0, POSIX_FADV_SEQUENTIAL );
        break;
    case FILE_RANDOM_ACCESS:
        posix_fadvise( fd->unix_fd, 0, 0, POSIX_FADV_RANDOM );
        break;
    }
#endif

    if (root_fd != -1) fchdir( server_dir_fd ); /* go back to the server dir */
    return fd;

error:
    release_object( fd );
    free( closed_fd );
    if (root_fd != -1) fchdir( server_dir_fd ); /* go back to the server dir */
    return NULL;
}

/* create an fd for an anonymous file */
/* if the function fails the unix fd is closed */
struct fd *create_anonymous_fd( const struct fd_ops *fd_user_ops, int unix_fd, struct object *user,
                                unsigned int options )
{
    struct fd *fd = alloc_fd_object();

    if (fd)
    {
        set_fd_user( fd, fd_user_ops, user );
        fd->unix_fd = unix_fd;
        fd->options = options;
#ifdef WINE_IOS
        /* iOS: all fds must be non-blocking since we use busy-polling
         * instead of epoll/kqueue. Handlers already handle EWOULDBLOCK. */
        fcntl( unix_fd, F_SETFL, O_NONBLOCK );
#endif
        return fd;
    }
    close( unix_fd );
    return NULL;
}

/* retrieve the object that is using an fd */
void *get_fd_user( struct fd *fd )
{
    return fd->user;
}

/* retrieve the opening options for the fd */
unsigned int get_fd_options( struct fd *fd )
{
    return fd->options;
}

/* retrieve the completion flags for the fd */
unsigned int get_fd_comp_flags( struct fd *fd )
{
    return fd->comp_flags;
}

/* check if fd is in overlapped mode */
int is_fd_overlapped( struct fd *fd )
{
    return !(fd->options & (FILE_SYNCHRONOUS_IO_ALERT | FILE_SYNCHRONOUS_IO_NONALERT));
}

/* retrieve the unix fd for an object */
int get_unix_fd( struct fd *fd )
{
    if (fd->unix_fd == -1) set_error( fd->no_fd_status );
    return fd->unix_fd;
}

/* retrieve the suggested mapping address for the fd */
client_ptr_t get_fd_map_address( struct fd *fd )
{
    return fd->map_addr;
}

/* set the suggested mapping address for the fd */
void set_fd_map_address( struct fd *fd, client_ptr_t addr, mem_size_t size )
{
    assert( !fd->map_addr );
    fd->map_addr = addr;
    fd->map_size = size;
}

/* check if two file descriptors point to the same file */
int is_same_file_fd( struct fd *fd1, struct fd *fd2 )
{
    return fd1->inode == fd2->inode;
}

/* allow the fd to be cached (can't be reset once set) */
void allow_fd_caching( struct fd *fd )
{
    fd->cacheable = 1;
}

/* check if fd is on a removable device */
int is_fd_removable( struct fd *fd )
{
    return (fd->inode && fd->inode->device->removable);
}

/* set or clear the fd signaled state */
void set_fd_signaled( struct fd *fd, int signaled )
{
    if (fd->comp_flags & FILE_SKIP_SET_EVENT_ON_HANDLE) return;
    if (signaled) signal_sync( fd->sync );
    else reset_sync( fd->sync );
}

/* check if events are pending and if yes return which one(s) */
int check_fd_events( struct fd *fd, int events )
{
    struct pollfd pfd;

    if (fd->unix_fd == -1) return POLLERR;
    if (fd->inode) return events;  /* regular files are always signaled */

    pfd.fd     = fd->unix_fd;
    pfd.events = events;
    if (poll( &pfd, 1, 0 ) <= 0) return 0;
    return pfd.revents;
}

/* default get_sync() routine for objects that poll() on an fd */
struct object *default_fd_get_sync( struct object *obj )
{
    struct fd *fd = get_obj_fd( obj );
    struct object *sync = get_obj_sync( &fd->obj );
    release_object( fd );
    return sync;
}

/* default get_full_name() routine for objects with an fd */
WCHAR *default_fd_get_full_name( struct object *obj, data_size_t max, data_size_t *ret_len )
{
    struct fd *fd = get_obj_fd( obj );
    WCHAR *ret = NULL;

    if (fd->nt_name)
    {
        *ret_len = fd->nt_namelen;
        ret = memdup( fd->nt_name, fd->nt_namelen );
    }
    release_object( fd );
    if (*ret_len > max) set_error( STATUS_BUFFER_OVERFLOW );
    return ret;
}

int default_fd_get_poll_events( struct fd *fd )
{
    int events = 0;

    if (async_waiting( &fd->read_q )) events |= POLLIN;
    if (async_waiting( &fd->write_q )) events |= POLLOUT;
    return events;
}

/* default handler for poll() events */
void default_poll_event( struct fd *fd, int event )
{
    if (event & (POLLIN | POLLERR | POLLHUP)) async_wake_up( &fd->read_q, STATUS_ALERTED );
    if (event & (POLLOUT | POLLERR | POLLHUP)) async_wake_up( &fd->write_q, STATUS_ALERTED );

    /* if an error occurred, stop polling this fd to avoid busy-looping */
    if (event & (POLLERR | POLLHUP)) set_fd_events( fd, -1 );
    else if (!fd->inode) set_fd_events( fd, fd->fd_ops->get_poll_events( fd ) );
}

void fd_queue_async( struct fd *fd, struct async *async, int type )
{
    struct async_queue *queue;

    switch (type)
    {
    case ASYNC_TYPE_READ:
        queue = &fd->read_q;
        break;
    case ASYNC_TYPE_WRITE:
        queue = &fd->write_q;
        break;
    case ASYNC_TYPE_WAIT:
        queue = &fd->wait_q;
        break;
    default:
        queue = NULL;
        assert(0);
    }

    queue_async( queue, async );

    if (type != ASYNC_TYPE_WAIT)
    {
        if (!fd->inode)
            set_fd_events( fd, fd->fd_ops->get_poll_events( fd ) );
        else  /* regular files are always ready for read and write */
            async_wake_up( queue, STATUS_ALERTED );
    }
}

void fd_async_wake_up( struct fd *fd, int type, unsigned int status )
{
    switch (type)
    {
    case ASYNC_TYPE_READ:
        async_wake_up( &fd->read_q, status );
        break;
    case ASYNC_TYPE_WRITE:
        async_wake_up( &fd->write_q, status );
        break;
    case ASYNC_TYPE_WAIT:
        async_wake_up( &fd->wait_q, status );
        break;
    default:
        assert(0);
    }
}

void fd_cancel_async( struct fd *fd, struct async *async )
{
    fd->fd_ops->cancel_async( fd, async );
}

void fd_reselect_async( struct fd *fd, struct async_queue *queue )
{
    fd->fd_ops->reselect_async( fd, queue );
}

void no_fd_queue_async( struct fd *fd, struct async *async, int type, int count )
{
    set_error( STATUS_OBJECT_TYPE_MISMATCH );
}

void default_fd_cancel_async( struct fd *fd, struct async *async )
{
    async_terminate( async, STATUS_CANCELLED );
}

void default_fd_queue_async( struct fd *fd, struct async *async, int type, int count )
{
    fd_queue_async( fd, async, type );
    set_error( STATUS_PENDING );
}

/* default reselect_async() fd routine */
void default_fd_reselect_async( struct fd *fd, struct async_queue *queue )
{
    if (queue == &fd->read_q || queue == &fd->write_q)
    {
        int poll_events = fd->fd_ops->get_poll_events( fd );
        int events = check_fd_events( fd, poll_events );
        if (events) fd->fd_ops->poll_event( fd, events );
        else set_fd_events( fd, poll_events );
    }
}

static int is_dir_empty( int fd )
{
    DIR *dir;
    int empty;
    struct dirent *de;

    if ((fd = dup( fd )) == -1)
        return -1;

    if (!(dir = fdopendir( fd )))
    {
        close( fd );
        return -1;
    }

    empty = 1;
    while (empty && (de = readdir( dir )))
    {
        if (!strcmp( de->d_name, "." ) || !strcmp( de->d_name, ".." )) continue;
        empty = 0;
    }
    closedir( dir );
    return empty;
}

static inline int is_valid_mounted_device( struct stat *st )
{
#if defined(linux) || defined(__sun__)
    return S_ISBLK( st->st_mode );
#else
    /* disks are char devices on *BSD */
    return S_ISCHR( st->st_mode );
#endif
}

/* close all Unix file descriptors on a device to allow unmounting it */
static void unmount_device( struct fd *device_fd )
{
    unsigned int i;
    struct stat st;
    struct device *device;
    struct inode *inode;
    struct fd *fd;
    int unix_fd = get_unix_fd( device_fd );

    if (unix_fd == -1) return;

    if (fstat( unix_fd, &st ) == -1 || !is_valid_mounted_device( &st ))
    {
        set_error( STATUS_INVALID_PARAMETER );
        return;
    }

    if (!(device = get_device( st.st_rdev, -1 ))) return;

    for (i = 0; i < INODE_HASH_SIZE; i++)
    {
        LIST_FOR_EACH_ENTRY( inode, &device->inode_hash[i], struct inode, entry )
        {
            LIST_FOR_EACH_ENTRY( fd, &inode->open, struct fd, inode_entry )
            {
                unmount_fd( fd );
            }
            inode_close_pending( inode, 0 );
        }
    }
    /* remove it from the hash table */
    list_remove( &device->entry );
    list_init( &device->entry );
    release_object( device );
}

#ifndef XATTR_USER_PREFIX
# define XATTR_USER_PREFIX "user."
#endif
#ifndef XATTR_USER_PREFIX_LEN
# define XATTR_USER_PREFIX_LEN (sizeof(XATTR_USER_PREFIX) - 1)
#endif

#define XATTR_REPARSE XATTR_USER_PREFIX "WINEREPARSE"

static int xattr_fset( int filedes, const char *name, const void *value, size_t size )
{
#ifdef HAVE_SYS_XATTR_H
# ifdef XATTR_ADDITIONAL_OPTIONS
    return fsetxattr( filedes, name, value, size, 0, 0 );
# else
    return fsetxattr( filedes, name, value, size, 0 );
# endif
#elif defined(HAVE_SYS_EXTATTR_H)
    return extattr_set_fd( filedes, EXTATTR_NAMESPACE_USER, &name[XATTR_USER_PREFIX_LEN],
                           value, size );
#else
    errno = ENOSYS;
    return -1;
#endif
}

static int xattr_fget( int filedes, const char *name, void *value, size_t size )
{
#ifdef HAVE_SYS_XATTR_H
# ifdef XATTR_ADDITIONAL_OPTIONS
    return fgetxattr( filedes, name, value, size, 0, 0 );
# else
    return fgetxattr( filedes, name, value, size );
# endif
#elif defined(HAVE_SYS_EXTATTR_H)
    return extattr_get_fd( filedes, EXTATTR_NAMESPACE_USER, &name[XATTR_USER_PREFIX_LEN],
                           value, size );
#else
    errno = ENOSYS;
    return -1;
#endif
}

static int xattr_fremove( int filedes, const char *name )
{
#ifdef HAVE_SYS_XATTR_H
# ifdef XATTR_ADDITIONAL_OPTIONS
    return fremovexattr( filedes, name, 0 );
# else
    return fremovexattr( filedes, name );
# endif
#elif defined(HAVE_SYS_EXTATTR_H)
    return extattr_delete_fd( filedes, EXTATTR_NAMESPACE_USER, &name[XATTR_USER_PREFIX_LEN] );
#else
    errno = ENOSYS;
    return -1;
#endif
}

static void set_reparse_point( struct fd *fd, struct async *async )
{
    char *reparse_name;
    struct stat st;
    size_t len;

    if (!fd->unix_name)
    {
        set_error( STATUS_OBJECT_TYPE_MISMATCH );
        return;
    }

    if (fstat( fd->unix_fd, &st ) == -1)
    {
        file_set_error();
        return;
    }

    if (S_ISDIR(st.st_mode) && !is_dir_empty( fd->unix_fd ))
    {
        set_error( STATUS_DIRECTORY_NOT_EMPTY );
        return;
    }

    if (xattr_fset( fd->unix_fd, XATTR_REPARSE, get_req_data(), get_req_data_size() ) < 0)
    {
        file_set_error();
        return;
    }

    len = strlen( fd->unix_name );
    if (fd->unix_name[len - 1] != '?')
    {
        /* we are adding a reparse point where there previously was not one;
         * move the file out of the way so open attempts will fail */

        if (!(reparse_name = mem_alloc( len + 2 ))) return;
        memcpy( reparse_name, fd->unix_name, len );
        strcpy( reparse_name + len, "?" );

        if (rename( fd->unix_name, reparse_name ))
        {
            free( reparse_name );
            return;
        }
        free( fd->unix_name );
        fd->closed->unix_name = fd->unix_name = reparse_name;
    }
}

static void get_reparse_point( struct fd *fd, struct async *async )
{
    /* we can't just allocate get_reply_max_size() here;
     * Linux won't return any data if the size is too small */
    char buffer[MAXIMUM_REPARSE_DATA_BUFFER_SIZE];
    int ret;

    if (!fd->unix_name)
    {
        set_error( STATUS_OBJECT_TYPE_MISMATCH );
        return;
    }

    if (!get_reply_max_size())
    {
        set_error( STATUS_INVALID_USER_BUFFER );
        return;
    }

    if (fd->unix_name[strlen( fd->unix_name ) - 1] != '?')
    {
        set_error( STATUS_NOT_A_REPARSE_POINT );
        return;
    }

    if (get_reply_max_size() < sizeof(REPARSE_GUID_DATA_BUFFER))
    {
        set_error( STATUS_BUFFER_TOO_SMALL );
        return;
    }

    ret = xattr_fget( fd->unix_fd, XATTR_REPARSE, buffer, sizeof(buffer) );
    if (ret >= 0)
    {
        if (ret > get_reply_max_size())
        {
            set_error( STATUS_BUFFER_OVERFLOW );
            ret = get_reply_max_size();
        }
        set_reply_data( buffer, ret );
    }
    else file_set_error();
}

static void delete_reparse_point( struct fd *fd, struct async *async )
{
    const REPARSE_DATA_BUFFER *data = get_req_data();
    char *base_name;
    size_t len;

    if (!fd->unix_name)
    {
        set_error( STATUS_OBJECT_TYPE_MISMATCH );
        return;
    }

    if (!get_req_data_size())
    {
        set_error( STATUS_INVALID_BUFFER_SIZE );
        return;
    }

    len = strlen( fd->unix_name );
    if (fd->unix_name[len - 1] != '?')
    {
        set_error( STATUS_NOT_A_REPARSE_POINT );
        return;
    }

    if (get_req_data_size() != sizeof(REPARSE_DATA_BUFFER) || data->ReparseDataLength)
    {
        set_error( STATUS_IO_REPARSE_DATA_INVALID );
        return;
    }

    if (!data->ReparseTag)
    {
        set_error( STATUS_IO_REPARSE_TAG_INVALID );
        return;
    }

    if (!(base_name = mem_alloc( len )))
        return;
    memcpy( base_name, fd->unix_name, len - 1 );
    base_name[len - 1] = 0;

    if (rename( fd->unix_name, base_name ) < 0)
    {
        file_set_error();
        free( base_name );
        return;
    }

    free( fd->unix_name );
    fd->closed->unix_name = fd->unix_name = base_name;

    xattr_fremove( fd->unix_fd, XATTR_REPARSE );
}

/* default read() routine */
void no_fd_read( struct fd *fd, struct async *async, file_pos_t pos )
{
    set_error( STATUS_OBJECT_TYPE_MISMATCH );
}

/* default write() routine */
void no_fd_write( struct fd *fd, struct async *async, file_pos_t pos )
{
    set_error( STATUS_OBJECT_TYPE_MISMATCH );
}

/* default flush() routine */
void no_fd_flush( struct fd *fd, struct async *async )
{
    set_error( STATUS_OBJECT_TYPE_MISMATCH );
}

/* default get_file_info() routine */
void no_fd_get_file_info( struct fd *fd, obj_handle_t handle, unsigned int info_class )
{
    set_error( STATUS_OBJECT_TYPE_MISMATCH );
}

/* default get_file_info() routine */
void default_fd_get_file_info( struct fd *fd, obj_handle_t handle, unsigned int info_class )
{
    switch (info_class)
    {
    case FileAccessInformation:
        {
            FILE_ACCESS_INFORMATION info;
            if (get_reply_max_size() < sizeof(info))
            {
                set_error( STATUS_INFO_LENGTH_MISMATCH );
                return;
            }
            info.AccessFlags = get_handle_access( current->process, handle );
            set_reply_data( &info, sizeof(info) );
            break;
        }
    case FileModeInformation:
        {
            FILE_MODE_INFORMATION info;
            if (get_reply_max_size() < sizeof(info))
            {
                set_error( STATUS_INFO_LENGTH_MISMATCH );
                return;
            }
            info.Mode = fd->options & ( FILE_WRITE_THROUGH
                                      | FILE_SEQUENTIAL_ONLY
                                      | FILE_NO_INTERMEDIATE_BUFFERING
                                      | FILE_SYNCHRONOUS_IO_ALERT
                                      | FILE_SYNCHRONOUS_IO_NONALERT );
            set_reply_data( &info, sizeof(info) );
            break;
        }
    case FileIoCompletionNotificationInformation:
        {
            FILE_IO_COMPLETION_NOTIFICATION_INFORMATION info;
            if (get_reply_max_size() < sizeof(info))
            {
                set_error( STATUS_INFO_LENGTH_MISMATCH );
                return;
            }
            info.Flags = fd->comp_flags;
            set_reply_data( &info, sizeof(info) );
            break;
        }
    case WineFileUnixNameInformation:
        if (fd->unix_name)
        {
            data_size_t len = strlen( fd->unix_name );
            data_size_t data_len = offsetof( WINE_FILE_UNIX_NAME_INFORMATION, Name[len] );
            WINE_FILE_UNIX_NAME_INFORMATION *info;

            if (get_reply_max_size() < sizeof(*info))
            {
                set_error( STATUS_INFO_LENGTH_MISMATCH );
                return;
            }
            if (get_reply_max_size() < data_len)
            {
                set_error( STATUS_BUFFER_OVERFLOW );
                data_len = sizeof(*info);
            }
            if (!(info = set_reply_data_size( data_len ))) break;
            info->Length = len;
            memcpy( info->Name, fd->unix_name, data_len - sizeof(*info) );
        }
        else set_error( STATUS_OBJECT_TYPE_MISMATCH );
        break;
    default:
        set_error( STATUS_NOT_IMPLEMENTED );
    }
}

/* default get_volume_info() routine */
void no_fd_get_volume_info( struct fd *fd, struct async *async, unsigned int info_class )
{
    set_error( STATUS_OBJECT_TYPE_MISMATCH );
}

/* default ioctl() routine */
void no_fd_ioctl( struct fd *fd, ioctl_code_t code, struct async *async )
{
    set_error( STATUS_OBJECT_TYPE_MISMATCH );
}

/* default ioctl() routine */
void default_fd_ioctl( struct fd *fd, ioctl_code_t code, struct async *async )
{
    switch(code)
    {
    case FSCTL_DISMOUNT_VOLUME:
        unmount_device( fd );
        break;

    case FSCTL_SET_REPARSE_POINT:
        set_reparse_point( fd, async );
        break;

    case FSCTL_GET_REPARSE_POINT:
        get_reparse_point( fd, async );
        break;

    case FSCTL_DELETE_REPARSE_POINT:
        delete_reparse_point( fd, async );
        break;

    default:
        set_error( STATUS_NOT_SUPPORTED );
    }
}

/* same as get_handle_obj but retrieve the struct fd associated to the object */
static struct fd *get_handle_fd_obj( struct process *process, obj_handle_t handle,
                                     unsigned int access )
{
    struct fd *fd = NULL;
    struct object *obj;

    if ((obj = get_handle_obj( process, handle, access, NULL )))
    {
        fd = get_obj_fd( obj );
        release_object( obj );
    }
    return fd;
}

/* set disposition for the fd */
static void set_fd_disposition( struct fd *fd, unsigned int flags )
{
    struct stat st;

    if (!fd->inode)
    {
        set_error( STATUS_OBJECT_TYPE_MISMATCH );
        return;
    }

    if (fd->unix_fd == -1)
    {
        set_error( fd->no_fd_status );
        return;
    }

    if (flags & FILE_DISPOSITION_DELETE)
    {
        struct fd *fd_ptr;

        LIST_FOR_EACH_ENTRY( fd_ptr, &fd->inode->open, struct fd, inode_entry )
        {
            if (fd_ptr->access & FILE_MAPPING_ACCESS)
            {
                set_error( STATUS_CANNOT_DELETE );
                return;
            }
        }

        if (fstat( fd->unix_fd, &st ) == -1)
        {
            file_set_error();
            return;
        }
        if (S_ISREG( st.st_mode ))  /* can't unlink files we don't have permission to write */
        {
            if (!(flags & FILE_DISPOSITION_IGNORE_READONLY_ATTRIBUTE) &&
                !(st.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH)))
            {
                set_error( STATUS_CANNOT_DELETE );
                return;
            }
        }
        else if (S_ISDIR( st.st_mode ))  /* can't remove non-empty directories */
        {
            switch (is_dir_empty( fd->unix_fd ))
            {
            case -1:
                file_set_error();
                return;
            case 0:
                set_error( STATUS_DIRECTORY_NOT_EMPTY );
                return;
            }
        }
        else  /* can't unlink special files */
        {
            set_error( STATUS_INVALID_PARAMETER );
            return;
        }
    }

    if (flags & FILE_DISPOSITION_ON_CLOSE)
        fd->options &= ~FILE_DELETE_ON_CLOSE;

    fd->closed->disp_flags =
        (flags & (FILE_DISPOSITION_DELETE | FILE_DISPOSITION_POSIX_SEMANTICS)) |
        ((fd->options & FILE_DELETE_ON_CLOSE) ? FILE_DISPOSITION_DELETE : 0);
}

/* set new name for the fd */
static void set_fd_name( struct fd *fd, struct fd *root, const char *nameptr, data_size_t len,
                         struct unicode_str nt_name, int create_link, unsigned int flags )
{
    struct inode *inode;
    struct stat st, st2;
    char *name;
    const unsigned int replace = flags & FILE_RENAME_REPLACE_IF_EXISTS;

    if (!fd->inode || !fd->unix_name)
    {
        set_error( STATUS_OBJECT_TYPE_MISMATCH );
        return;
    }
    if (fd->unix_fd == -1)
    {
        set_error( fd->no_fd_status );
        return;
    }

    if (!len || ((nameptr[0] == '/') ^ !root))
    {
        set_error( STATUS_OBJECT_PATH_SYNTAX_BAD );
        return;
    }
    if (!(name = mem_alloc( len + 2 ))) return;
    memcpy( name, nameptr, len );
    if (fd->unix_name[strlen( fd->unix_name ) - 1] == '?' && name[len - 1] != '?')
        name[len++] = '?';
    name[len] = 0;

    if (root)
    {
        char *combined_name = dup_fd_name( root, name );
        if (!combined_name)
        {
            set_error( STATUS_NO_MEMORY );
            goto failed;
        }
        free( name );
        name = combined_name;
    }

    /* when creating a hard link, source cannot be a dir */
    if (create_link && !fstat( fd->unix_fd, &st ) && S_ISDIR( st.st_mode ))
    {
        set_error( STATUS_FILE_IS_A_DIRECTORY );
        goto failed;
    }

    if (!stat( name, &st ))
    {
        if (!fstat( fd->unix_fd, &st2 ) && st.st_ino == st2.st_ino && st.st_dev == st2.st_dev)
        {
            if (create_link && !replace) set_error( STATUS_OBJECT_NAME_COLLISION );
            free( name );
            return;
        }

        if (!replace)
        {
            set_error( STATUS_OBJECT_NAME_COLLISION );
            goto failed;
        }

        /* can't replace directories or special files */
        if (!S_ISREG( st.st_mode ))
        {
            set_error( STATUS_ACCESS_DENIED );
            goto failed;
        }

        /* read-only files cannot be replaced */
        if (!(st.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH)) &&
            !(flags & FILE_RENAME_IGNORE_READONLY_ATTRIBUTE))
        {
            set_error( STATUS_ACCESS_DENIED );
            goto failed;
        }

        /* can't replace an opened file */
        if ((inode = get_inode( st.st_dev, st.st_ino, -1 )))
        {
            int is_empty = list_empty( &inode->open );
            release_object( inode );
            if (!is_empty)
            {
                set_error( STATUS_ACCESS_DENIED );
                goto failed;
            }
        }

        /* link() expects that the target doesn't exist */
        /* rename() cannot replace files with directories */
        if (create_link || S_ISDIR( st2.st_mode ))
        {
            if (unlink( name ))
            {
                file_set_error();
                goto failed;
            }
        }
    }

    if (create_link)
    {
        if (link( fd->unix_name, name ))
            file_set_error();
        free( name );
        return;
    }

    if (rename( fd->unix_name, name ))
    {
        file_set_error();
        goto failed;
    }

    if (is_file_executable( fd->unix_name ) != is_file_executable( name ) && !fstat( fd->unix_fd, &st ))
    {
        if (is_file_executable( name ))
            /* set executable bit where read bit is set */
            st.st_mode |= (st.st_mode & 0444) >> 2;
        else
            st.st_mode &= ~0111;
        fchmod( fd->unix_fd, st.st_mode );
    }

    free( fd->nt_name );
    fd->nt_name = dup_nt_name( root, nt_name, &fd->nt_namelen );
    free( fd->unix_name );
    fd->closed->unix_name = fd->unix_name = realpath( name, NULL );
    free( name );
    if (!fd->unix_name)
        set_error( STATUS_NO_MEMORY );
    return;

failed:
    free( name );
}

static void set_fd_eof( struct fd *fd, file_pos_t eof )
{
    struct stat st;

    if (!fd->inode)
    {
        set_error( STATUS_OBJECT_TYPE_MISMATCH );
        return;
    }

    if (fd->unix_fd == -1)
    {
        set_error( fd->no_fd_status );
        return;
    }
    if (fstat( fd->unix_fd, &st) == -1)
    {
        file_set_error();
        return;
    }
    if (eof < st.st_size)
    {
        struct fd *fd_ptr;
        LIST_FOR_EACH_ENTRY( fd_ptr, &fd->inode->open, struct fd, inode_entry )
        {
            if (fd_ptr->access & FILE_MAPPING_ACCESS)
            {
                set_error( STATUS_USER_MAPPED_FILE );
                return;
            }
        }
        {
            /* ml562: name every SHRINK of a file we may be backing a section with.
             * ml561 showed section files that are short at map time; this says
             * whether they were born short or truncated afterwards. */
            struct stat bst;
            if (!fstat( fd->unix_fd, &bst ) && (off_t)eof < bst.st_size)
            {
                static unsigned long shrinkn;
                if (++shrinkn <= 64)
                    ws_log("[srv-eof] SHRINK fd=%d dev=%llu ino=%llu %lld -> %lld rev=ml563\n",
                           fd->unix_fd, (unsigned long long)bst.st_dev,
                           (unsigned long long)bst.st_ino,
                           (long long)bst.st_size, (long long)eof);
            }
        }
        if (ftruncate( fd->unix_fd, eof ) == -1) file_set_error();
    }
    else grow_file( fd->unix_fd, eof );
}

struct completion *fd_get_completion( struct fd *fd, apc_param_t *p_key )
{
    *p_key = fd->comp_key;
    return fd->completion ? (struct completion *)grab_object( fd->completion ) : NULL;
}

void fd_copy_completion( struct fd *src, struct fd *dst )
{
    assert( !dst->completion );
    dst->completion = fd_get_completion( src, &dst->comp_key );
    dst->comp_flags = src->comp_flags;
}

/* flush a file buffers */
DECL_HANDLER(flush)
{
    struct fd *fd = get_handle_fd_obj( current->process, req->async.handle, 0 );
    struct async *async;

    if (!fd) return;

    if ((async = create_request_async( fd, fd->comp_flags, &req->async, 0 )))
    {
        fd->fd_ops->flush( fd, async );
        reply->event = async_handoff( async, NULL, 1 );
        release_object( async );
    }
    release_object( fd );
}

/* query file info */
DECL_HANDLER(get_file_info)
{
    struct fd *fd = get_handle_fd_obj( current->process, req->handle, 0 );

    if (fd)
    {
        fd->fd_ops->get_file_info( fd, req->handle, req->info_class );
        release_object( fd );
    }
}

/* query volume info */
DECL_HANDLER(get_volume_info)
{
    struct fd *fd = get_handle_fd_obj( current->process, req->handle, 0 );
    struct async *async;

    if (!fd) return;

    if ((async = create_request_async( fd, fd->comp_flags, &req->async, 0 )))
    {
        fd->fd_ops->get_volume_info( fd, async, req->info_class );
        reply->wait = async_handoff( async, NULL, 1 );
        release_object( async );
    }
    release_object( fd );
}

/* ml1490: which device paths a program opens through the server, sampled.
 * Device log 193: with a game running, the Steam client's engine thread made
 * about 1,600 of these opens per second (open_file_object from NtCreateFile,
 * i.e. a pipe or other device path), with the server at 0.4 of a core. This
 * names them: the first 24, then every 4096th, with the result and the
 * running count. MADEIRA_OPEN_OBJECT_TRACE=0 disables it. */
static void ios_open_object_trace( const struct unicode_str *name, int has_root )
{
    static int enabled = -1;
    static unsigned int count;
    char text[160];
    data_size_t i, n;

    if (enabled < 0)
    {
        const char *e = getenv( "MADEIRA_OPEN_OBJECT_TRACE" );
        enabled = !(e && e[0] == '0');
    }
    if (!enabled) return;
    count++;
    if (count > 24 && (count & 4095)) return;
    n = name->len / sizeof(WCHAR);
    if (n > sizeof(text) - 1) n = sizeof(text) - 1;
    for (i = 0; i < n; i++)
    {
        WCHAR c = name->str[i];
        text[i] = (c >= 0x20 && c < 0x7f) ? (char)c : '?';
    }
    text[n] = 0;
    fprintf( stderr, "[open-obj] ml1490 #%u tid=%04x pid=%04x status=%08x root=%d name=%s\n",
             count, current->id, current->process->id, get_error(), has_root, text );
}

/* open a file object */
DECL_HANDLER(open_file_object)
{
    struct unicode_str name = get_req_unicode_str();
    struct object *obj, *result, *root = NULL;

    if (req->rootdir && !(root = get_handle_obj( current->process, req->rootdir, 0, NULL ))) return;

    obj = open_named_object( root, NULL, &name, req->attributes );
    if (root) release_object( root );
    if (!obj)
    {
        ios_open_object_trace( &name, req->rootdir != 0 );
        return;
    }

    if ((result = obj->ops->open_file( obj, req->access, req->sharing, req->options )))
    {
        reply->handle = alloc_handle( current->process, result, req->access, req->attributes );
        release_object( result );
    }
    release_object( obj );
    ios_open_object_trace( &name, req->rootdir != 0 );
}

/* get the Unix name from a file handle */
DECL_HANDLER(get_handle_unix_name)
{
    struct fd *fd;

    if ((fd = get_handle_fd_obj( current->process, req->handle, 0 )))
    {
        if (fd->unix_name)
        {
            data_size_t name_len = strlen( fd->unix_name );
            reply->name_len = name_len;
            if (name_len <= get_reply_max_size()) set_reply_data( fd->unix_name, name_len );
            else set_error( STATUS_BUFFER_OVERFLOW );
        }
        else set_error( STATUS_OBJECT_TYPE_MISMATCH );
        release_object( fd );
    }
}

/* get a Unix fd to access a file */
DECL_HANDLER(get_handle_fd)
{
    struct fd *fd;

    if ((fd = get_handle_fd_obj( current->process, req->handle, 0 )))
    {
        int unix_fd = get_unix_fd( fd );
        reply->cacheable = fd->cacheable;
        if (unix_fd != -1)
        {
            reply->type = fd->fd_ops->get_fd_type( fd );
            reply->options = fd->options;
            reply->access = get_handle_access( current->process, req->handle );
            send_client_fd( current->process, unix_fd, req->handle );
        }
        release_object( fd );
    }
}

/* perform a read on a file object */
DECL_HANDLER(read)
{
    struct fd *fd = get_handle_fd_obj( current->process, req->async.handle, FILE_READ_DATA );
    struct async *async;

    if (!fd) return;

    if ((async = create_request_async( fd, fd->comp_flags, &req->async, 0 )))
    {
        fd->fd_ops->read( fd, async, req->pos );
        reply->wait = async_handoff( async, NULL, 0 );
        reply->options = fd->options;
        release_object( async );
    }
    release_object( fd );
}

/* perform a write on a file object */
DECL_HANDLER(write)
{
    struct fd *fd = get_handle_fd_obj( current->process, req->async.handle, FILE_WRITE_DATA );
    struct async *async;

    if (!fd) return;

    if ((async = create_request_async( fd, fd->comp_flags, &req->async, 0 )))
    {
        fd->fd_ops->write( fd, async, req->pos );
        reply->wait = async_handoff( async, &reply->size, 0 );
        reply->options = fd->options;
        release_object( async );
    }
    release_object( fd );
}

/* perform an ioctl on a file */
DECL_HANDLER(ioctl)
{
    unsigned int access = (req->code >> 14) & (FILE_READ_DATA|FILE_WRITE_DATA);
    struct fd *fd = get_handle_fd_obj( current->process, req->async.handle, access );
    struct async *async;

    if (!fd) return;

    if ((async = create_request_async( fd, fd->comp_flags, &req->async, 0 )))
    {
        fd->fd_ops->ioctl( fd, req->code, async );
        reply->wait = async_handoff( async, NULL, 0 );
        reply->options = fd->options;
        release_object( async );
    }
    release_object( fd );
}

/* create / reschedule an async I/O */
DECL_HANDLER(register_async)
{
    unsigned int access;
    struct async *async;
    struct fd *fd;

    switch(req->type)
    {
    case ASYNC_TYPE_READ:
        access = FILE_READ_DATA;
        break;
    case ASYNC_TYPE_WRITE:
        access = FILE_WRITE_DATA;
        break;
    default:
        set_error( STATUS_INVALID_PARAMETER );
        return;
    }

    if ((fd = get_handle_fd_obj( current->process, req->async.handle, access )))
    {
        if (get_unix_fd( fd ) != -1 && (async = create_async( fd, current, &req->async, NULL )))
        {
            fd->fd_ops->queue_async( fd, async, req->type, req->count );
            release_object( async );
        }
        release_object( fd );
    }
}

/* attach completion object to a fd */
DECL_HANDLER(set_completion_info)
{
    struct fd *fd = get_handle_fd_obj( current->process, req->handle, 0 );

    if (fd)
    {
        if (is_fd_overlapped( fd ) && !fd->completion)
        {
            fd->completion = get_completion_obj( current->process, req->chandle, IO_COMPLETION_MODIFY_STATE );
            fd->comp_key = req->ckey;
            set_fd_signaled( fd, 1 );
        }
        else set_error( STATUS_INVALID_PARAMETER );
        release_object( fd );
    }
}

/* push new completion msg into a completion queue attached to the fd */
DECL_HANDLER(add_fd_completion)
{
    struct fd *fd = get_handle_fd_obj( current->process, req->handle, 0 );
    if (fd)
    {
        if (fd->completion && (req->async || !(fd->comp_flags & FILE_SKIP_COMPLETION_PORT_ON_SUCCESS)))
            add_completion( fd->completion, fd->comp_key, req->cvalue, req->status, req->information );
        release_object( fd );
    }
}

/* set fd completion information */
DECL_HANDLER(set_fd_completion_mode)
{
    struct fd *fd = get_handle_fd_obj( current->process, req->handle, 0 );
    if (fd)
    {
        if (is_fd_overlapped( fd ))
        {
            if (req->flags & FILE_SKIP_SET_EVENT_ON_HANDLE)
                set_fd_signaled( fd, 0 );
            /* removing flags is not allowed */
            fd->comp_flags |= req->flags & ( FILE_SKIP_COMPLETION_PORT_ON_SUCCESS
                                           | FILE_SKIP_SET_EVENT_ON_HANDLE
                                           | FILE_SKIP_SET_USER_EVENT_ON_FAST_IO );
        }
        else
            set_error( STATUS_INVALID_PARAMETER );
        release_object( fd );
    }
}

/* set fd disposition information */
DECL_HANDLER(set_fd_disp_info)
{
    struct fd *fd = get_handle_fd_obj( current->process, req->handle, DELETE );
    if (fd)
    {
        set_fd_disposition( fd, req->flags );
        release_object( fd );
    }
}

/* set fd name information */
DECL_HANDLER(set_fd_name_info)
{
    struct fd *fd, *root_fd = NULL;
    struct unicode_str nt_name;

    if (req->namelen > get_req_data_size())
    {
        set_error( STATUS_INVALID_PARAMETER );
        return;
    }
    nt_name.str = get_req_data();
    nt_name.len = (req->namelen / sizeof(WCHAR)) * sizeof(WCHAR);

    if (req->rootdir)
    {
        struct dir *root;

        if (!(root = get_dir_obj( current->process, req->rootdir, 0 ))) return;
        root_fd = get_obj_fd( (struct object *)root );
        release_object( root );
        if (!root_fd) return;
    }

    if ((fd = get_handle_fd_obj( current->process, req->handle, 0 )))
    {
        set_fd_name( fd, root_fd, (const char *)get_req_data() + req->namelen,
                     get_req_data_size() - req->namelen, nt_name, req->link, req->flags );
        release_object( fd );
    }
    if (root_fd) release_object( root_fd );
}

/* set fd eof information */
DECL_HANDLER(set_fd_eof_info)
{
    struct fd *fd = get_handle_fd_obj( current->process, req->handle, 0 );
    if (fd)
    {
        set_fd_eof( fd, req->eof );
        release_object( fd );
    }
}
