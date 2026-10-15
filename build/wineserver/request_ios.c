/*
 * Server-side request handling
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

#include "config.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#ifdef HAVE_PWD_H
#include <pwd.h>
#endif
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>
#ifdef HAVE_SYS_UIO_H
#include <sys/uio.h>
#endif
#ifdef HAVE_SYS_UN_H
#include <sys/un.h>
#endif
#include <unistd.h>
#include <poll.h>
#ifdef __APPLE__
# include <mach/mach_time.h>
#endif

#include <os/log.h>
#include <os/lock.h>   /* madeira-bcd: ios_srv_lock (MADEIRA_SRV_DIRECT) */
#include "wine_log_ios.h"
#include <pthread.h>

#include "ntstatus.h"
#include "windef.h"
#include "winbase.h"
#include "wincon.h"
#include "winternl.h"

#include "file.h"
#include "process.h"
#include "thread.h"
#include "security.h"
#include "handle.h"
#include "request_handlers.h"

/* Some versions of glibc don't define this */
#ifndef SCM_RIGHTS
#define SCM_RIGHTS 1
#endif

/* path names for server master Unix socket */
static const char * const server_socket_name = "socket";   /* name of the socket file */
static const char * const server_lock_name = "lock";       /* name of the server lock file */

struct master_socket
{
    struct object        obj;        /* object header */
    struct fd           *fd;         /* file descriptor of the master socket */
};

static void master_socket_dump( struct object *obj, int verbose );
static void master_socket_destroy( struct object *obj );
static void master_socket_poll_event( struct fd *fd, int event );

static const struct object_ops master_socket_ops =
{
    sizeof(struct master_socket),  /* size */
    &no_type,                      /* type */
    master_socket_dump,            /* dump */
    no_add_queue,                  /* add_queue */
    NULL,                          /* remove_queue */
    NULL,                          /* signaled */
    NULL,                          /* satisfied */
    no_signal,                     /* signal */
    no_get_fd,                     /* get_fd */
    default_get_sync,              /* get_sync */
    default_map_access,            /* map_access */
    default_get_sd,                /* get_sd */
    default_set_sd,                /* set_sd */
    no_get_full_name,              /* get_full_name */
    no_lookup_name,                /* lookup_name */
    no_link_name,                  /* link_name */
    NULL,                          /* unlink_name */
    no_open_file,                  /* open_file */
    no_kernel_obj_list,            /* get_kernel_obj_list */
    no_close_handle,               /* close_handle */
    master_socket_destroy          /* destroy */
};

static const struct fd_ops master_socket_fd_ops =
{
    NULL,                          /* get_poll_events */
    master_socket_poll_event,      /* poll_event */
    NULL,                          /* flush */
    NULL,                          /* get_fd_type */
    NULL,                          /* ioctl */
    NULL,                          /* queue_async */
    NULL                           /* reselect_async */
};


struct thread *current = NULL;  /* thread handling the current request */
unsigned int global_error = 0;  /* global error code for when no thread is current */
timeout_t server_start_time = 0;  /* server startup time */
char *server_dir = NULL;   /* server directory */
int wineserver_ready;  /* set by main() once start-up is complete, just before the main loop */
int server_dir_fd = -1;    /* file descriptor for the server dir */
int config_dir_fd = -1;    /* file descriptor for the config dir */

static struct master_socket *master_socket;  /* the master socket object */
static struct timeout_user *master_timeout;

#ifdef WINE_IOS
/* iOS socketpair bypass: fd injected by the app bridge for direct client connection.
 * The event loop picks this up instead of waiting for accept(). */
volatile int g_injected_client_fd = -1;

void wineserver_inject_client_fd(int fd)
{
    ws_log("[wineserver] inject_client_fd: fd=%d", fd);
    g_injected_client_fd = fd;
}
#endif

/* complain about a protocol error and terminate the client connection */
void fatal_protocol_error( struct thread *thread, const char *err, ... )
{
    va_list args;

    va_start( args, err );
    fprintf( stderr, "Protocol error:%04x: ", thread->id );
    vfprintf( stderr, err, args );
    va_end( args );
    thread->exit_code = 1;
    kill_thread( thread, 1 );
}

/* die on a fatal error */
/* fatal_error is provided by WineServerBridge.m — uses ws_log + pthread_exit
 * instead of exit(1) which would kill the entire app on iOS */

/* allocate the reply data */
void *set_reply_data_size( data_size_t size )
{
    assert( size <= get_reply_max_size() );
    if (size && !(current->reply_data = mem_alloc( size ))) size = 0;
    current->reply_size = size;
    return current->reply_data;
}

static const struct object_attributes empty_attributes;

/* return object attributes from the current request */
const struct object_attributes *get_req_object_attributes( const struct security_descriptor **sd,
                                                           struct unicode_str *name,
                                                           struct object **root )
{
    const struct object_attributes *attr = get_req_data();
    data_size_t size = get_req_data_size();

    if (root) *root = NULL;

    if (!size)
    {
        *sd = NULL;
        name->len = 0;
        return &empty_attributes;
    }

    if ((size < sizeof(*attr)) || (size - sizeof(*attr) < attr->sd_len) ||
        (size - sizeof(*attr) - attr->sd_len < attr->name_len))
    {
        set_error( STATUS_ACCESS_VIOLATION );
        return NULL;
    }
    if (attr->sd_len && !sd_is_valid( (const struct security_descriptor *)(attr + 1), attr->sd_len ))
    {
        set_error( STATUS_INVALID_SECURITY_DESCR );
        return NULL;
    }
    if ((attr->name_len & (sizeof(WCHAR) - 1)) || attr->name_len >= 65534)
    {
        set_error( STATUS_OBJECT_NAME_INVALID );
        return NULL;
    }
    if (root && attr->rootdir && attr->name_len)
    {
        if (!(*root = get_handle_obj( current->process, attr->rootdir, 0, NULL ))) return NULL;
    }
    *sd = attr->sd_len ? (const struct security_descriptor *)(attr + 1) : NULL;
    name->len = attr->name_len;
    name->str = (const WCHAR *)(attr + 1) + attr->sd_len / sizeof(WCHAR);
    return attr;
}

/* return a pointer to the request data following an object attributes structure */
const void *get_req_data_after_objattr( const struct object_attributes *attr, data_size_t *len )
{
    data_size_t size = (sizeof(*attr) + (attr->sd_len & ~1) + (attr->name_len & ~1) + 3) & ~3;

    if (attr == &empty_attributes || size >= get_req_data_size())
    {
        *len = 0;
        return NULL;
    }
    *len = get_req_data_size() - size;
    return (const char *)get_req_data() + size;
}

/* write the remaining part of the reply */
void write_reply( struct thread *thread )
{
    int ret;

    if ((ret = write( get_unix_fd( thread->reply_fd ),
                      (char *)thread->reply_data + thread->reply_size - thread->reply_towrite,
                      thread->reply_towrite )) >= 0)
    {
        if (!(thread->reply_towrite -= ret))
        {
            free( thread->reply_data );
            thread->reply_data = NULL;
            /* sent everything, can go back to waiting for requests */
            set_fd_events( thread->request_fd, POLLIN );
            set_fd_events( thread->reply_fd, 0 );
        }
        return;
    }
    if (errno == EPIPE)
        kill_thread( thread, 0 );  /* normal death */
    else if (errno != EWOULDBLOCK && (EWOULDBLOCK == EAGAIN || errno != EAGAIN))
        fatal_protocol_error( thread, "reply write: %s\n", strerror( errno ));
}

/* send a reply to the current thread */
static void send_reply( union generic_reply *reply )
{
    int ret;

    if (!current->reply_size)
    {
        if ((ret = write( get_unix_fd( current->reply_fd ),
                          reply, sizeof(*reply) )) != sizeof(*reply)) goto error;
    }
    else
    {
        struct iovec vec[2];

        vec[0].iov_base = (void *)reply;
        vec[0].iov_len  = sizeof(*reply);
        vec[1].iov_base = current->reply_data;
        vec[1].iov_len  = current->reply_size;

        if ((ret = writev( get_unix_fd( current->reply_fd ), vec, 2 )) < sizeof(*reply)) goto error;

        if ((current->reply_towrite = current->reply_size - (ret - sizeof(*reply))))
        {
            /* couldn't write it all, wait for POLLOUT */
            set_fd_events( current->reply_fd, POLLOUT );
            set_fd_events( current->request_fd, 0 );
            return;
        }
    }
    free( current->reply_data );
    current->reply_data = NULL;
    return;

 error:
    if (ret >= 0)
        fatal_protocol_error( current, "partial write %d\n", ret );
    else if (errno == EPIPE)
        kill_thread( current, 0 );  /* normal death */
    else
        fatal_protocol_error( current, "reply write: %s\n", strerror( errno ));
}

/* ml1310: RegFlushKey writes the registry to disk, as on Windows. Wine's flush_key
 * handler does nothing and leaves it to the periodic save and the server's exit,
 * but iOS kills the app without a clean server exit (and Madeira's server lives as
 * long as the app), so a setting a program flushed could be lost. Saves of
 * unchanged branches cost nothing (save_branch skips clean keys); a burst of
 * flushes is folded into one save a second later. Idea from the published patch
 * 0015 of another iOS port. */
static struct timeout_user *ios_regflush_timer;
static timeout_t ios_regflush_last;

static void ios_regflush_save( const char *how )
{
    static unsigned int saves;

    ios_regflush_last = monotonic_time;
    flush_registry();
    if (++saves <= 8 || !(saves % 64))
        fprintf( stderr, "[reg-flush] ml1310 RegFlushKey: registry saved %s (#%u; "
                 "MADEIRA_REGFLUSH_SAVE=0 leaves it to the periodic save)\n", how, saves );
}

static void ios_regflush_deferred( void *arg )
{
    ios_regflush_timer = NULL;
    ios_regflush_save( "after a burst" );
}

static void ios_regflush_request(void)
{
    static int enabled = -1;

    /* MADEIRA_REGFLUSH_SAVE=0: RegFlushKey does nothing again; the registry is saved periodically and at exit (ml1310) */
    if (enabled < 0) { const char *e = getenv( "MADEIRA_REGFLUSH_SAVE" ); enabled = !(e && e[0] == '0'); }
    if (!enabled) return;
    if (ios_regflush_last && monotonic_time - ios_regflush_last < TICKS_PER_SEC)
    {
        if (!ios_regflush_timer)
            ios_regflush_timer = add_timeout_user( -(ios_regflush_last + TICKS_PER_SEC - monotonic_time),
                                                   ios_regflush_deferred, NULL );
        return;
    }
    ios_regflush_save( "now" );
}

/* madeira-bcd: the ml1055 request census, moved out of call_req_handler unchanged so a
 * direct request (ios_srv_direct_call) is counted the same way. current is thread. */
static void ios_req_census( struct thread *thread, enum request req )
{
    /* ml1055: which requests. With the JIT no longer thrashing, ~16% of running
     * CPU samples sit in the client/server pipe read; the mix decides whether an
     * in-process fast path for waits is worth building. Request numbers map to
     * names through wine/server/request_trace.h req_names[]. */
    static unsigned long counts[REQ_NB_REQUESTS], total;
    static struct timespec t0;
    /* madeira-bcd: and from whom. Four heavy-hitter slots per request
     * (space-saving: a newcomer replaces the smallest and inherits its
     * count), so a storm (set_cursor 2,400/s in build 437) names its
     * thread and process; a slot's count can overstate by at most the
     * count it inherited. */
    static struct { unsigned int tid, pid; unsigned long n; } hh[REQ_NB_REQUESTS][4];
    static unsigned long cursor_flags[6];   /* set_cursor by flag: handle count pos clip noclip fsclip */
    /* madeira-bcd: the shape of each wait. Fastsync answers a single,
     * non-alertable wait on an event (or, with MADEIRA_FASTSYNC_SEM=1, on a
     * semaphore) in the client; every other shape stays a server round
     * trip. GTA V sent ~15,000 selects a second in build 442 (sem=off), and
     * these counts say how many of them the switch could take away.
     * Shapes: single, single alertable, any of many, all of many,
     * signal-and-wait, keyed event, other; objects by the first handle. */
    static unsigned long sel_shape[7], sel_obj[8], sel_multi_sem;
    if (req == REQ_select &&
        get_req_data_size() >= sizeof(union apc_result) + sizeof(enum select_opcode))
    {
        const union apc_result *res = get_req_data();
        data_size_t size = min( thread->req.select_request.size, get_req_data_size() - sizeof(*res) );
        union select_op op;
        unsigned int nh = 0, i, shape;
        int has_sem = 0;

        memset( &op, 0, sizeof(op) );
        memcpy( &op, res + 1, min( size, sizeof(op) ) );
        if ((op.op == SELECT_WAIT || op.op == SELECT_WAIT_ALL) && size > offsetof( union select_op, wait.handles ))
            nh = min( (size - offsetof( union select_op, wait.handles )) / sizeof(obj_handle_t),
                      MAXIMUM_WAIT_OBJECTS );
        if (op.op == SELECT_WAIT && nh == 1)
            shape = (thread->req.select_request.flags & SELECT_ALERTABLE) ? 1 : 0;
        else if (op.op == SELECT_WAIT) shape = 2;
        else if (op.op == SELECT_WAIT_ALL) shape = 3;
        else if (op.op == SELECT_SIGNAL_AND_WAIT) shape = 4;
        else if (op.op == SELECT_KEYED_EVENT_WAIT || op.op == SELECT_KEYED_EVENT_RELEASE) shape = 5;
        else shape = 6;
        sel_shape[shape]++;
        for (i = 0; i < nh; i++)
        {
            struct object *obj = get_handle_obj( thread->process, op.wait.handles[i], 0, NULL );
            const struct type_descr *type;
            int k = 7;

            if (!obj) clear_error();   /* the handler reports a bad handle itself */
            else
            {
                type = obj->ops->type;
                k = type == &semaphore_type ? 0 : type == &event_type ? 1 : type == &mutex_type ? 2 :
                    type == &thread_type ? 3 : type == &process_type ? 4 : type == &timer_type ? 5 :
                    type == &completion_type ? 6 : 7;
                release_object( obj );
            }
            if (!i) sel_obj[k]++;
            if (!k) has_sem = 1;
        }
        if (nh > 1 && has_sem) sel_multi_sem++;
    }
    if (req == REQ_set_cursor)
    {
        unsigned int f = thread->req.set_cursor_request.flags, b;
        for (b = 0; b < 6; b++) if (f & (1u << b)) cursor_flags[b]++;
    }
    if (req < REQ_NB_REQUESTS)
    {
        unsigned int tid = thread->id, pid = thread->process ? thread->process->id : 0;
        int s, low = 0;
        counts[req]++;
        for (s = 0; s < 4; s++)
        {
            if (hh[req][s].n && hh[req][s].tid == tid) { hh[req][s].n++; break; }
            if (hh[req][s].n < hh[req][low].n) low = s;
        }
        if (s == 4)
        {
            hh[req][low].tid = tid; hh[req][low].pid = pid; hh[req][low].n++;
        }
    }
    if (!total) clock_gettime( CLOCK_MONOTONIC, &t0 );
    if (++total % 200000 == 0)
    {
        struct timespec t1; char line[1400]; int n = 0, k, s; unsigned r;
        clock_gettime( CLOCK_MONOTONIC, &t1 );
        for (k = 0; k < 10; k++)
        {
            unsigned best = 0, top = 0; unsigned long bn = 0;
            for (r = 0; r < REQ_NB_REQUESTS; r++) if (counts[r] > bn) { bn = counts[r]; best = r; }
            if (!bn) break;
            for (s = 1; s < 4; s++) if (hh[best][s].n > hh[best][top].n) top = s;
            n += snprintf( line + n, sizeof(line) - n, " req%u=%lu(tid %04x pid %04x ~%lu)", best, bn,
                           hh[best][top].tid, hh[best][top].pid, hh[best][top].n );
            counts[best] = 0;
        }
        for (r = 0; r < REQ_NB_REQUESTS; r++) counts[r] = 0;
        memset( hh, 0, sizeof(hh) );
        fprintf( stderr, "[srv-req] ml1055 last 200000 requests in %.1f s:%s\n",
                 (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9, line );
        if (cursor_flags[0] + cursor_flags[1] + cursor_flags[2] + cursor_flags[3] + cursor_flags[4])
        {
            extern unsigned long ios_clip_repeats_skipped;
            fprintf( stderr, "[srv-req] set_cursor by flag: handle=%lu count=%lu pos=%lu clip=%lu noclip=%lu "
                     "fsclip=%lu; unchanged ClipCursor notifications skipped so far: %lu\n",
                     cursor_flags[0], cursor_flags[1], cursor_flags[2], cursor_flags[3], cursor_flags[4],
                     cursor_flags[5], ios_clip_repeats_skipped );
            memset( cursor_flags, 0, sizeof(cursor_flags) );
        }
        if (sel_shape[0] + sel_shape[1] + sel_shape[2] + sel_shape[3] + sel_shape[4] + sel_shape[5] + sel_shape[6])
        {
            fprintf( stderr, "[srv-req] select by shape: single %lu, single alertable %lu, any of many %lu "
                     "(%lu with a semaphore), all of many %lu, signal-and-wait %lu, keyed event %lu, other %lu; "
                     "first object: semaphore %lu, event %lu, mutex %lu, thread %lu, process %lu, timer %lu, "
                     "completion %lu, other %lu\n",
                     sel_shape[0], sel_shape[1], sel_shape[2], sel_multi_sem, sel_shape[3], sel_shape[4],
                     sel_shape[5], sel_shape[6], sel_obj[0], sel_obj[1], sel_obj[2], sel_obj[3], sel_obj[4],
                     sel_obj[5], sel_obj[6], sel_obj[7] );
            memset( sel_shape, 0, sizeof(sel_shape) );
            memset( sel_obj, 0, sizeof(sel_obj) );
            sel_multi_sem = 0;
        }
        t0 = t1;
    }
}

/* call a request handler */
static void call_req_handler( struct thread *thread )
{
    union generic_reply reply;
    enum request req = thread->req.request_header.req;

    current = thread;
    current->reply_size = 0;
    clear_error();
    memset( &reply, 0, sizeof(reply) );

    if (debug_level) trace_request();

    ios_req_census( thread, req );
    if (req < REQ_NB_REQUESTS)
        req_handlers[req]( &current->req, &reply );
    else
        set_error( STATUS_NOT_IMPLEMENTED );
    if (req == REQ_flush_key && current && !current->error) ios_regflush_request();   /* ml1310 */

    if (current)
    {
        if (current->reply_fd)
        {
            reply.reply_header.error = current->error;
            reply.reply_header.reply_size = current->reply_size;
            if (debug_level) trace_reply( req, &reply );
            send_reply( &reply );
        }
        else
        {
            current->exit_code = 1;
            kill_thread( current, 1 );  /* no way to continue without reply fd */
        }
    }
    current = NULL;
}

#ifdef WINE_IOS
/* madeira-bcd: direct requests (env.MADEIRA_SRV_DIRECT = 1 or 2; off by default).
 *
 * A request normally costs two thread switches and five or more system calls: the client
 * writes it to its request pipe and rings (fd_ios.c ios_srv_bell), the server thread wakes,
 * reads it, runs the handler and writes the reply, and the client wakes from its read.
 * Here the server is a thread of the same process, so with the switch a listed request runs
 * on the calling thread itself: under ios_srv_lock, which the server loop holds for
 * everything it does except its sleep (fd_ios.c ios_srv_loop_enter), the request is copied
 * into the thread's server state exactly as read_request leaves it, the same handler runs
 * (call_req_handler's steps, census included), and the reply is copied back instead of
 * written. No pipe, ring or wake-up, and the handler's work runs on the caller's core (an
 * efficiency core under ECO) instead of the server's performance core. Horizon Zero Dawn's
 * menu sent ~6,900 requests a second (493, 2026-10-11), GTA V Enhanced up to ~35,000.
 *
 * Listed are requests that finish inside their handler. Level 1: handles, files and their
 * descriptors, mappings looked up, registry keys and values, events, semaphores, mutexes and
 * completion ports. Level 2 adds select (a wait that cannot finish at once returns
 * STATUS_PENDING as before, and its wake-up still arrives on the thread's wait pipe from
 * whoever satisfies it), the timer requests and set_cursor (GTA V Enhanced sent up to
 * ~10,000 a second); a timer due before the sleeping loop wakes has the request wake it
 * (fd_ios.c add_timeout_user). Thread and process lifetime,
 * suspension, contexts, APC queuing, asynchronous I/O and window messages keep the pipe.
 * A request that cannot run here (the switch went off, the loop is not running, the thread
 * is not fully connected or is not the caller) goes through the pipe as before; one that
 * ends its own thread is sent through the pipe as well, which the server has closed by
 * then, so the client's EPIPE path reports it exactly as it does today. */
os_unfair_lock ios_srv_lock = OS_UNFAIR_LOCK_INIT;
volatile int ios_srv_direct_live;          /* fd_ios.c: set and cleared by the loop under the lock */
volatile int ios_srv_timer_added;          /* fd_ios.c add_timeout_user: the sleeping loop must wake */
unsigned long long ios_srv_loop_wake_at;   /* fd_ios.c: monotonic tick the sleeping loop wakes at */
unsigned long long ios_srv_direct_n, ios_srv_direct_fallback, ios_srv_direct_timer_wakes;   /* [srv-direct] */
extern volatile int g_madeira_srv_direct;  /* WineProcessBridge.m */

/* 0: never direct; 1: with MADEIRA_SRV_DIRECT = 1 or 2; 2: only with MADEIRA_SRV_DIRECT = 2 */
static int ios_srv_direct_level( enum request req )
{
    switch (req)
    {
    case REQ_close_handle:
    case REQ_create_file:
    case REQ_open_file_object:
    case REQ_get_handle_fd:
    case REQ_open_mapping:
    case REQ_get_mapping_info:
    case REQ_create_key:
    case REQ_open_key:
    case REQ_get_key_value:
    case REQ_set_key_value:
    case REQ_enum_key:
    case REQ_enum_key_value:
    case REQ_create_event:
    case REQ_open_event:
    case REQ_event_op:
    case REQ_query_event:
    case REQ_create_semaphore:
    case REQ_open_semaphore:
    case REQ_release_semaphore:
    case REQ_query_semaphore:
    case REQ_create_mutex:
    case REQ_open_mutex:
    case REQ_release_mutex:
    case REQ_query_mutex:
    case REQ_create_completion:
    case REQ_open_completion:
    case REQ_add_completion:
    case REQ_remove_completion:
    case REQ_query_completion:
    case REQ_get_thread_completion:
        return 1;
    case REQ_select:
    case REQ_create_timer:
    case REQ_open_timer:
    case REQ_set_timer:
    case REQ_cancel_timer:
    case REQ_get_timer_info:
    case REQ_set_cursor:
        return 2;
    default:
        return 0;
    }
}

/* call_req_handler's steps with the reply copied out: 1 done, -1 the request ended the thread */
static int ios_srv_run_direct( struct thread *thread, union generic_reply *reply, void *reply_data )
{
    enum request req = thread->req.request_header.req;
    int ret = -1;

    current = thread;
    current->reply_size = 0;
    clear_error();
    memset( reply, 0, sizeof(*reply) );

    if (debug_level) trace_request();

    ios_req_census( thread, req );
    req_handlers[req]( &current->req, reply );

    if (current)
    {
        if (current->reply_fd)
        {
            reply->reply_header.error = current->error;
            reply->reply_header.reply_size = current->reply_size;
            if (debug_level) trace_reply( req, reply );
            if (current->reply_size) memcpy( reply_data, current->reply_data, current->reply_size );
            free( current->reply_data );
            current->reply_data = NULL;
            ret = 1;
        }
        else
        {
            current->exit_code = 1;
            kill_thread( current, 1 );  /* no way to continue without reply fd */
        }
    }
    current = NULL;
    return ret;
}

/* Run a request of thread `tid' (TEB `teb') on the calling thread. 1: it ran, the reply and
 * its data are in reply_out and reply_data; 0: not taken; -1: it ended the thread. */
int ios_srv_direct_call( unsigned int tid, client_ptr_t teb, const union generic_request *request,
                         const struct iovec *vec, unsigned int count,
                         union generic_reply *reply_out, void *reply_data )
{
    extern void ios_wineserver_wake(void);
    enum request req = request->request_header.req;
    data_size_t size = request->request_header.request_size, done = 0;
    int level = __atomic_load_n( &g_madeira_srv_direct, __ATOMIC_ACQUIRE ), need, ret, wake = 0;
    union generic_reply reply;
    struct thread *thread;
    void *data = NULL;
    unsigned int i;

    if (level <= 0 || (unsigned int)req >= REQ_NB_REQUESTS) return 0;
    if (!(need = ios_srv_direct_level( req )) || need > level) return 0;
    if (size)   /* contiguous and malloc'd, as read_request leaves it (cleanup_thread frees it) */
    {
        if (!(data = malloc( size ))) return 0;
        for (i = 0; i < count; i++)
        {
            if (vec[i].iov_len > size - done) break;
            if (vec[i].iov_len) memcpy( (char *)data + done, vec[i].iov_base, vec[i].iov_len );
            done += vec[i].iov_len;
        }
        if (i < count || done != size)
        {
            free( data );
            return 0;
        }
    }

    os_unfair_lock_lock( &ios_srv_lock );
    if (!__atomic_load_n( &ios_srv_direct_live, __ATOMIC_ACQUIRE )) goto pipe;
    if (!(thread = get_thread_from_id( tid )))
    {
        clear_error();
        goto pipe;
    }
    if (thread->teb != teb || thread->state == TERMINATED || !thread->request_fd || !thread->reply_fd ||
        thread->req_toread || thread->req_data || thread->reply_data || thread->reply_towrite)
    {
        release_object( thread );
        goto pipe;
    }
    set_current_time();
    memcpy( &thread->req, request, sizeof(thread->req) );
    thread->req_data = data;
    ret = ios_srv_run_direct( thread, &reply, reply_data );
    free( thread->req_data );   /* NULL when kill_thread has freed it */
    thread->req_data = NULL;
    release_object( thread );
    __atomic_fetch_add( &ios_srv_direct_n, 1, __ATOMIC_RELAXED );
    if (ios_srv_timer_added)
    {
        ios_srv_timer_added = 0;
        wake = 1;
        __atomic_fetch_add( &ios_srv_direct_timer_wakes, 1, __ATOMIC_RELAXED );
    }
    os_unfair_lock_unlock( &ios_srv_lock );
    if (wake) ios_wineserver_wake();
    if (ret > 0) memcpy( reply_out, &reply, sizeof(reply) );
    return ret;

pipe:
    __atomic_fetch_add( &ios_srv_direct_fallback, 1, __ATOMIC_RELAXED );
    os_unfair_lock_unlock( &ios_srv_lock );
    free( data );
    return 0;
}
#endif

/* madeira-bcd doorbell (fd_ios.c ios_srv_bell): read the request fd of thread
 * `tid` the way a POLLIN on it would; 1 when a request is still partly unread */
int ios_doorbell_poll_thread( unsigned int tid )
{
    extern void ios_fd_poll_in( struct fd *fd );
    struct thread *thread = get_thread_from_id( tid );
    int again = 0;

    if (!thread)
    {
        clear_error();
        return 0;
    }
    if (thread->request_fd)
    {
        ios_fd_poll_in( thread->request_fd );
        again = thread->request_fd && thread->req_toread;
    }
    release_object( thread );
    return again;
}

/* read a request from a thread */
void read_request( struct thread *thread )
{
    int ret;

    if (!thread->req_toread)  /* no pending request */
    {
        if ((ret = read( get_unix_fd( thread->request_fd ), &thread->req,
                         sizeof(thread->req) )) != sizeof(thread->req)) goto error;
        if (!(thread->req_toread = thread->req.request_header.request_size))
        {
            /* no data, handle request at once */
            call_req_handler( thread );
            return;
        }
        if (!(thread->req_data = malloc( thread->req_toread )))
        {
            fatal_protocol_error( thread, "no memory for %u bytes request %d\n",
                                  thread->req_toread, thread->req.request_header.req );
            return;
        }
    }

    /* read the variable sized data */
    for (;;)
    {
        ret = read( get_unix_fd( thread->request_fd ),
                    (char *)thread->req_data + thread->req.request_header.request_size
                      - thread->req_toread,
                    thread->req_toread );
        if (ret <= 0) break;
        if (!(thread->req_toread -= ret))
        {
            call_req_handler( thread );
            free( thread->req_data );
            thread->req_data = NULL;
            return;
        }
    }

error:
    if (!ret)  /* closed pipe */
    {
        /* ml586: this kill was previously SILENT — the 0060-family autopsy
         * needs the fd number and tid on every request-channel death */
        fprintf( stderr, "[srv-own] read_request EOF tid=%04x pid=%04x request_unixfd=%d -> kill_thread rev=ml586\n",
                 thread->id, thread->process->id, get_unix_fd( thread->request_fd ) );
        kill_thread( thread, 0 );
    }
    else if (ret > 0)
        fatal_protocol_error( thread, "partial read %d\n", ret );
    else if (errno != EWOULDBLOCK && (EWOULDBLOCK == EAGAIN || errno != EAGAIN))
    {
        fprintf( stderr, "[srv-own] read_request ERR tid=%04x pid=%04x request_unixfd=%d errno=%d rev=ml586\n",
                 thread->id, thread->process->id, get_unix_fd( thread->request_fd ), errno );
        fatal_protocol_error( thread, "read: %s\n", strerror( errno ));
    }
}

/* receive a file descriptor on the process socket */
int receive_fd( struct process *process )
{
    struct iovec vec;
    struct send_fd data;
    struct msghdr msghdr;
    char cmsg_buffer[256];
    int fd = -1, ret;

    msghdr.msg_name    = NULL;
    msghdr.msg_namelen = 0;
    msghdr.msg_iov     = &vec;
    msghdr.msg_iovlen  = 1;
    msghdr.msg_control = cmsg_buffer;
    msghdr.msg_controllen = sizeof(cmsg_buffer);
    msghdr.msg_flags   = 0;

    vec.iov_base = (void *)&data;
    vec.iov_len  = sizeof(data);

    ret = recvmsg( get_unix_fd( process->msg_fd ), &msghdr, 0 );

    if (ret > 0)
    {
        struct cmsghdr *cmsg;
        for (cmsg = CMSG_FIRSTHDR( &msghdr ); cmsg; cmsg = CMSG_NXTHDR( &msghdr, cmsg ))
        {
            if (cmsg->cmsg_level != SOL_SOCKET) continue;
            if (cmsg->cmsg_type == SCM_RIGHTS) fd = *(int *)CMSG_DATA(cmsg);
        }
    }

    if (ret == sizeof(data))
    {
        struct thread *thread;

        if (data.tid) thread = get_thread_from_id( data.tid );
        else thread = (struct thread *)grab_object( get_process_first_thread( process ));

        if (!thread || thread->process != process || thread->state == TERMINATED)
        {
            /* ml586: previously silent (debug_level off) — a misrouted send_fd
             * (client picked the wrong master socket) dies exactly here */
            fprintf( stderr, "[srv-own] receive_fd BAD tid=%04x on pid=%04x client_fd=%d server_dup=%d cause=%s rev=ml586\n",
                     data.tid, process->id, data.fd, fd,
                     !thread ? "no-thread" : (thread->state == TERMINATED ? "terminated" : "WRONG-PROCESS") );
            close( fd );
        }
        else
        {
            struct stat fdt_st;
            if (debug_level)
                fprintf( stderr, "%04x: *fd* %d <- %d\n",
                         thread->id, data.fd, fd );
            /* ml586: log pipe/socket receipts — these are thread comm fds; the
             * pid field catches deliveries arriving on the wrong master socket */
            if (fd != -1 && !fstat( fd, &fdt_st ) && (S_ISFIFO(fdt_st.st_mode) || S_ISSOCK(fdt_st.st_mode)))
                fprintf( stderr, "[srv-own] receive_fd tid=%04x pid=%04x client_fd=%d server_dup=%d kind=%s rev=ml586\n",
                         thread->id, process->id, data.fd, fd,
                         S_ISFIFO(fdt_st.st_mode) ? "fifo" : "sock" );
            thread_add_inflight_fd( thread, data.fd, fd );
        }
        if (thread) release_object( thread );
        return 0;
    }

    if (!ret)
    {
        kill_process( process, 0 );
    }
    else if (ret > 0)
    {
        fprintf( stderr, "Protocol error: process %04x: partial recvmsg %d for fd\n",
                 process->id, ret );
        if (fd != -1) close( fd );
        kill_process( process, 1 );
    }
    else
    {
        if (errno != EWOULDBLOCK && (EWOULDBLOCK == EAGAIN || errno != EAGAIN))
        {
            fprintf( stderr, "Protocol error: process %04x: ", process->id );
            perror( "recvmsg" );
            kill_process( process, 1 );
        }
    }
    return -1;
}

/* send an fd to a client */
int send_client_fd( struct process *process, int fd, obj_handle_t handle )
{
    struct iovec vec;
    struct msghdr msghdr;
    char cmsg_buffer[256];
    struct cmsghdr *cmsg;
    int ret;

    static unsigned long logged;   /* madeira-bcd: fd_ios.c ios_srv_log_sample */
    extern int ios_srv_log_sample( unsigned long *count );
    int log_this = ios_srv_log_sample( &logged );

    /* task #24: include requester identity — the settings-freeze loop
     * resends the same handle forever; tid names the retrying thread and
     * process id disambiguates which pseudo-process's msg socket this is. */
    if (log_this)
        ws_log("[wineserver] send_client_fd: fd=%d handle=0x%x msg_fd_unix=%d proc=%04x tid=%04x",
               fd, handle, get_unix_fd( process->msg_fd ), process->id,
               current ? current->id : 0);

    msghdr.msg_name    = NULL;
    msghdr.msg_namelen = 0;
    msghdr.msg_iov     = &vec;
    msghdr.msg_iovlen  = 1;
    msghdr.msg_control = cmsg_buffer;
    msghdr.msg_controllen = sizeof(cmsg_buffer);
    msghdr.msg_flags   = 0;

    vec.iov_base = (void *)&handle;
    vec.iov_len  = sizeof(handle);

    cmsg = CMSG_FIRSTHDR( &msghdr );
    cmsg->cmsg_len   = CMSG_LEN( sizeof(fd) );
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type  = SCM_RIGHTS;
    *(int *)CMSG_DATA(cmsg) = fd;
    msghdr.msg_controllen = cmsg->cmsg_len;

    if (debug_level)
        fprintf( stderr, "%04x: *fd* %04x -> %d\n", current ? current->id : process->id, handle, fd );

    ret = sendmsg( get_unix_fd( process->msg_fd ), &msghdr, 0 );

    if (log_this || ret != sizeof(handle))
        ws_log("[wineserver] send_client_fd: sendmsg returned %d (expected %lu) errno=%d",
               ret, (unsigned long)sizeof(handle), errno);

    if (ret == sizeof(handle)) return 0;

    if (ret >= 0)
    {
        fprintf( stderr, "Protocol error: process %04x: partial sendmsg %d\n", process->id, ret );
        ws_log("[wineserver] send_client_fd: partial sendmsg %d", ret);
        kill_process( process, 1 );
    }
    else if (errno == EPIPE)
    {
        ws_log("[wineserver] send_client_fd: EPIPE");
        kill_process( process, 0 );
    }
    else
    {
        ws_log("[wineserver] send_client_fd: error %s", strerror(errno));
        fprintf( stderr, "Protocol error: process %04x: ", process->id );
        perror( "sendmsg" );
        kill_process( process, 1 );
    }
    return -1;
}

/* return a monotonic time counter */
timeout_t monotonic_counter(void)
{
#ifdef __APPLE__
    static mach_timebase_info_data_t timebase;

    if (!timebase.denom) mach_timebase_info( &timebase );
    return mach_continuous_time() * timebase.numer / timebase.denom / 100;
#elif defined(HAVE_CLOCK_GETTIME)
    struct timespec ts;
#ifdef CLOCK_BOOTTIME
    if (!clock_gettime( CLOCK_BOOTTIME, &ts ))
        return (timeout_t)ts.tv_sec * TICKS_PER_SEC + ts.tv_nsec / 100;
#endif
    if (!clock_gettime( CLOCK_MONOTONIC, &ts ))
        return (timeout_t)ts.tv_sec * TICKS_PER_SEC + ts.tv_nsec / 100;
#endif
    return current_time - server_start_time;
}

static void master_socket_dump( struct object *obj, int verbose )
{
    struct master_socket *sock = (struct master_socket *)obj;
    assert( obj->ops == &master_socket_ops );
    fprintf( stderr, "Master socket fd=%p\n", sock->fd );
}

static void master_socket_destroy( struct object *obj )
{
    struct master_socket *sock = (struct master_socket *)obj;
    assert( obj->ops == &master_socket_ops );
    release_object( sock->fd );
}

/* handle a socket event */
static void master_socket_poll_event( struct fd *fd, int event )
{
    struct master_socket *sock = get_fd_user( fd );
    assert( master_socket->obj.ops == &master_socket_ops );

    assert( sock == master_socket );  /* there is only one master socket */

    if (event & (POLLERR | POLLHUP))
    {
        /* this is not supposed to happen */
        fprintf( stderr, "wineserver: Error on master socket\n" );
        ws_log("[wineserver] Error on master socket");
        set_fd_events( sock->fd, -1 );
    }
    else if (event & POLLIN)
    {
        struct process *process;
        struct sockaddr_un dummy;
        socklen_t len = sizeof(dummy);
        int master_fd = get_unix_fd( master_socket->fd );
        int client = accept( master_fd, (struct sockaddr *) &dummy, &len );
        if (client == -1) {
            static int accept_fail_count = 0;
            accept_fail_count++;
            if (accept_fail_count <= 3 || accept_fail_count % 2000 == 0)
                ws_log("[wineserver] accept(%d) failed: errno=%d (%s) count=%d",
                       master_fd, errno, strerror(errno), accept_fail_count);
            return;
        }
        /* Raw write to stderr — bypasses ws_log mutex in case of deadlock */
        {
            char abuf[128];
            int alen = snprintf(abuf, sizeof(abuf), "[wineserver] RAW: ACCEPTED fd=%d\n", client);
            write(STDERR_FILENO, abuf, alen);
        }
        ws_log("[wineserver] ACCEPTED client fd=%d (master_fd=%d)", client, master_fd);
        fcntl( client, F_SETFL, O_NONBLOCK );
        ws_log("[wineserver] calling create_process...");
        process = create_process( client, NULL, 0, NULL, NULL, NULL, 0, NULL );
        ws_log("[wineserver] create_process returned %p", (void*)process);
        if (process)
        {
            ws_log("[wineserver] calling create_thread...");
            create_thread( -1, process, NULL );
            ws_log("[wineserver] create_thread done, releasing...");
            release_object( process );
            ws_log("[wineserver] client fully connected!");
        }
        else
        {
            ws_log("[wineserver] create_process FAILED");
        }
    }
}

#ifdef WINE_IOS
/* iOS: handle a pre-connected client fd (from socketpair bypass) */
void master_socket_handle_client(int client_fd)
{
    struct process *process;

    ws_log("[wineserver] master_socket_handle_client: fd=%d", client_fd);
    fcntl( client_fd, F_SETFL, O_NONBLOCK );

    ws_log("[wineserver] calling create_process...");
    process = create_process( client_fd, NULL, 0, NULL, NULL, NULL, 0, NULL );
    ws_log("[wineserver] create_process returned %p", (void*)process);

    if (process)
    {
        ws_log("[wineserver] calling create_thread...");
        create_thread( -1, process, NULL );
        ws_log("[wineserver] create_thread done, releasing...");
        release_object( process );
        ws_log("[wineserver] client fully connected!");
    }
    else
    {
        ws_log("[wineserver] create_process FAILED for injected fd=%d", client_fd);
    }
}
#endif

/* remove the socket upon exit */
static void socket_cleanup(void)
{
    static int do_it_once;
    if (!do_it_once++) unlink( server_socket_name );
}

/* create a directory and check its permissions */
static void create_dir( const char *name, struct stat *st )
{
    if (lstat( name, st ) == -1)
    {
        if (errno != ENOENT)
            fatal_error( "lstat %s: %s\n", name, strerror( errno ));
        if (mkdir( name, 0700 ) == -1 && errno != EEXIST)
            fatal_error( "mkdir %s: %s\n", name, strerror( errno ));
        if (lstat( name, st ) == -1)
            fatal_error( "lstat %s: %s\n", name, strerror( errno ));
    }
    if (!S_ISDIR(st->st_mode)) fatal_error( "%s is not a directory\n", name );
    if (st->st_uid != getuid()) fatal_error( "%s is not owned by you\n", name );
    if (st->st_mode & 077) fatal_error( "%s must not be accessible by other users\n", name );
}

/* create the server directory and chdir to it */
static char *create_server_dir( int force )
{
    const char *prefix = getenv( "WINEPREFIX" );
    char *p, *config_dir, *base_dir;
    struct stat st, st2;

    /* open the configuration directory */

    if (prefix)
    {
        if (!(config_dir = strdup( prefix ))) fatal_error( "out of memory\n" );
        for (p = config_dir + strlen(config_dir); p > config_dir; p--) if (p[-1] != '/') break;
        if (p > config_dir) *p = 0;
        if (config_dir[0] != '/')
            fatal_error( "invalid directory %s in WINEPREFIX: not an absolute path\n", prefix );
    }
    else
    {
        const char *home = getenv( "HOME" );
        if (!home)
        {
            struct passwd *pwd = getpwuid( getuid() );
            if (pwd) home = pwd->pw_dir;
        }
        if (!home) fatal_error( "could not determine your home directory\n" );
        if (home[0] != '/') fatal_error( "your home directory %s is not an absolute path\n", home );
        if (!(config_dir = malloc( strlen(home) + sizeof("/.wine") ))) fatal_error( "out of memory\n" );
        strcpy( config_dir, home );
        for (p = config_dir + strlen(config_dir); p > config_dir; p--) if (p[-1] != '/') break;
        strcpy( p, "/.wine" );
    }

    if (chdir( config_dir ) == -1)
    {
        if (errno != ENOENT || force) fatal_error( "chdir to %s: %s\n", config_dir, strerror( errno ));
        return NULL;
    }
    if ((config_dir_fd = open( ".", O_RDONLY )) == -1)
        fatal_error( "open %s: %s\n", config_dir, strerror( errno ));
    if (fstat( config_dir_fd, &st ) == -1)
        fatal_error( "stat %s: %s\n", config_dir, strerror( errno ));
    if (st.st_uid != getuid())
        fatal_error( "%s is not owned by you\n", config_dir );

    /* create the base directory if needed */

#if defined(__ANDROID__) || defined(WINE_IOS)  /* no /tmp access on Android/iOS */
    if (asprintf( &base_dir, "%s/.wineserver", config_dir ) == -1)
        fatal_error( "out of memory\n" );
#else
    if (asprintf( &base_dir, "/tmp/.wine-%u", getuid() ) == -1)
        fatal_error( "out of memory\n" );
#endif
    create_dir( base_dir, &st2 );

    /* now create the server directory */

    if (asprintf( &server_dir, "%s/server-%llx-%llx", base_dir,
                  (unsigned long long)st.st_dev, (unsigned long long)st.st_ino ) == -1)
        fatal_error( "out of memory\n" );

    create_dir( server_dir, &st );

    if (chdir( server_dir ) == -1)
        fatal_error( "chdir %s: %s\n", server_dir, strerror( errno ));
    if ((server_dir_fd = open( ".", O_RDONLY )) == -1)
        fatal_error( "open %s: %s\n", server_dir, strerror( errno ));
    if (fstat( server_dir_fd, &st2 ) == -1)
        fatal_error( "stat %s: %s\n", server_dir, strerror( errno ));
    if (st.st_dev != st2.st_dev || st.st_ino != st2.st_ino)
        fatal_error( "chdir did not end up in %s\n", server_dir );

    free( base_dir );
    free( config_dir );
    return server_dir;
}

/* create the lock file and return its file descriptor */
static int create_server_lock(void)
{
    struct stat st;
    int fd;

    if (lstat( server_lock_name, &st ) == -1)
    {
        if (errno != ENOENT)
            fatal_error( "lstat %s/%s: %s\n", server_dir, server_lock_name, strerror( errno ));
    }
    else
    {
        if (!S_ISREG(st.st_mode))
            fatal_error( "%s/%s is not a regular file\n", server_dir, server_lock_name );
    }

    if ((fd = open( server_lock_name, O_CREAT|O_TRUNC|O_WRONLY, 0600 )) == -1)
        fatal_error( "error creating %s/%s: %s\n", server_dir, server_lock_name, strerror( errno ));
    return fd;
}

/* wait for the server lock */
int wait_for_lock(void)
{
    int fd, r;
    struct flock fl;

    server_dir = create_server_dir( 0 );
    if (!server_dir) return 0;  /* no server dir, so no lock to wait on */

    fd = create_server_lock();

    fl.l_type   = F_WRLCK;
    fl.l_whence = SEEK_SET;
    fl.l_start  = 0;
    fl.l_len    = 1;
    r = fcntl( fd, F_SETLKW, &fl );
    close(fd);

    return r;
}

/* kill the wine server holding the lock */
int kill_lock_owner( int sig )
{
    int fd, i, ret = 0;
    pid_t pid = 0;
    struct flock fl;

    server_dir = create_server_dir( 0 );
    if (!server_dir) return 0;  /* no server dir, nothing to do */

    fd = create_server_lock();

    for (i = 1; i <= 20; i++)
    {
        fl.l_type   = F_WRLCK;
        fl.l_whence = SEEK_SET;
        fl.l_start  = 0;
        fl.l_len    = 1;
        if (fcntl( fd, F_GETLK, &fl ) == -1) goto done;
        if (fl.l_type != F_WRLCK) goto done;  /* the file is not locked */
        if (!pid)  /* first time around */
        {
            if (!(pid = fl.l_pid)) goto done;  /* shouldn't happen */
            if (sig == -1)
            {
                if (kill( pid, SIGINT ) == -1) goto done;
                kill( pid, SIGCONT );
                ret = 1;
            }
            else  /* just send the specified signal and return */
            {
                ret = (kill( pid, sig ) != -1);
                goto done;
            }
        }
        else if (fl.l_pid != pid) goto done;  /* no longer the same process */
        usleep( 50000 * i );
    }
    /* waited long enough, now kill it */
    kill( pid, SIGKILL );

 done:
    close( fd );
    return ret;
}

/* acquire the main server lock */
static void acquire_lock(void)
{
    struct sockaddr_un addr;
    struct stat st;
    struct flock fl;
    int fd, slen, got_lock = 0;

    fd = create_server_lock();

    fl.l_type   = F_WRLCK;
    fl.l_whence = SEEK_SET;
    fl.l_start  = 0;
    fl.l_len    = 1;
    if (fcntl( fd, F_SETLK, &fl ) != -1)
    {
        /* check for crashed server */
        if (stat( server_socket_name, &st ) != -1 &&   /* there is a leftover socket */
            stat( "core", &st ) != -1 && st.st_size)   /* and there is a non-empty core file */
        {
            fprintf( stderr,
                     "Warning: a previous instance of the wine server seems to have crashed.\n"
                     "Please run 'gdb %s %s/core',\n"
                     "type 'backtrace' at the gdb prompt and report the results. Thanks.\n\n",
                     server_argv0, server_dir );
        }
        unlink( server_socket_name ); /* we got the lock, we can safely remove the socket */
        got_lock = 1;
        /* in that case we reuse fd without closing it, this ensures
         * that we hold the lock until the process exits */
    }
    else
    {
        switch(errno)
        {
        case ENOLCK:
            break;
        case EACCES:
            /* check whether locks work at all on this file system */
            if (fcntl( fd, F_GETLK, &fl ) == -1) break;
            /* fall through */
        case EAGAIN:
#ifdef WINE_IOS
            fatal_error( "another wineserver is already running\n" );
#else
            exit(2); /* we didn't get the lock, exit with special status */
#endif
        default:
            fatal_error( "fcntl %s/%s: %s\n", server_dir, server_lock_name, strerror( errno ));
        }
        /* it seems we can't use locks on this fs, so we will use the socket existence as lock */
        close( fd );
    }

    if ((fd = socket( AF_UNIX, SOCK_STREAM, 0 )) == -1) fatal_error( "socket: %s\n", strerror( errno ));
    addr.sun_family = AF_UNIX;
    strcpy( addr.sun_path, server_socket_name );
    slen = sizeof(addr) - sizeof(addr.sun_path) + strlen(addr.sun_path) + 1;
#ifdef HAVE_STRUCT_SOCKADDR_UN_SUN_LEN
    addr.sun_len = slen;
#endif
    if (bind( fd, (struct sockaddr *)&addr, slen ) == -1)
    {
        if ((errno == EEXIST) || (errno == EADDRINUSE))
        {
            if (got_lock)
                fatal_error( "couldn't bind to the socket even though we hold the lock\n" );
#ifdef WINE_IOS
            fatal_error( "bind: address already in use (another wineserver?)\n" );
#else
            exit(2); /* we didn't get the lock, exit with special status */
#endif
        }
        fatal_error( "bind: %s\n", strerror( errno ));
    }
    atexit( socket_cleanup );
    chmod( server_socket_name, 0600 );  /* make sure no other user can connect */
    if (listen( fd, 5 ) == -1) fatal_error( "listen: %s\n", strerror( errno ));
    /* iOS: make master socket non-blocking so accept() never blocks */
    fcntl( fd, F_SETFL, O_NONBLOCK );
    ws_log("[wineserver] acquire_lock: listening on fd=%d (NONBLOCK), server_dir=%s", fd, server_dir);

    if (!(master_socket = alloc_object( &master_socket_ops )) ||
        !(master_socket->fd = create_anonymous_fd( &master_socket_fd_ops, fd, &master_socket->obj, 0 )))
        fatal_error( "out of memory\n" );
    ws_log("[wineserver] acquire_lock: master_socket->fd unix_fd=%d", get_unix_fd(master_socket->fd));
    set_fd_events( master_socket->fd, POLLIN );
    make_object_permanent( &master_socket->obj );
}

/* open the master server socket and start waiting for new clients */
void open_master_socket(void)
{
    int fd, pid, status, sync_pipe[2];
    char dummy;

    /* make sure no request is larger than the maximum size */
    assert( sizeof(union generic_request) == sizeof(struct request_max_size) );
    assert( sizeof(union generic_reply) == sizeof(struct request_max_size) );

    /* make sure the stdio fds are open */
    fd = open( "/dev/null", O_RDWR );
    while (fd >= 0 && fd <= 2) fd = dup( fd );

    server_dir = create_server_dir( 1 );

    if (!foreground)
    {
        if (pipe( sync_pipe ) == -1) fatal_error( "pipe: %s\n", strerror( errno ));
        pid = fork();
        switch( pid )
        {
        case 0:  /* child */
            setsid();
            close( sync_pipe[0] );

            acquire_lock();

            /* close stdin and stdout */
            dup2( fd, 0 );
            dup2( fd, 1 );

            /* signal parent */
            dummy = 0;
            write( sync_pipe[1], &dummy, 1 );
            close( sync_pipe[1] );
            break;

        case -1:
            fatal_error( "fork: %s\n", strerror( errno ));
            break;

        default:  /* parent */
            close( sync_pipe[1] );

            /* wait for child to signal us and then exit */
            if (read( sync_pipe[0], &dummy, 1 ) == 1) _exit(0);

            /* child terminated, propagate exit status */
            waitpid( pid, &status, 0 );
            if (WIFEXITED(status)) _exit( WEXITSTATUS(status) );
            _exit(1);
        }
    }
    else  /* remain in the foreground */
    {
        acquire_lock();
    }

    /* init the process tracing mechanism */
    init_tracing_mechanism();
    close( fd );
}

/* master socket timer expiration handler */
static void close_socket_timeout( void *arg )
{
    /* RAW write — this is our prime suspect for thread death */
    {
        char buf[128];
        int len = snprintf(buf, sizeof(buf), "[wineserver] RAW: close_socket_timeout FIRED! pthread_exit coming\n");
        write(STDERR_FILENO, buf, len);
    }
    master_timeout = NULL;
    flush_registry();
    ws_log("[wineserver] close_socket_timeout fired — calling pthread_exit");

#ifdef DEBUG_OBJECTS
    close_objects();  /* shut down everything properly */
#endif
#ifdef WINE_IOS
    /* iOS: exit() would kill the entire app. Use pthread_exit instead. */
    pthread_exit(NULL);
#else
    exit( 0 );
#endif
}

/* close the master socket and stop waiting for new clients */
void close_master_socket( timeout_t timeout )
{
    if (master_socket)
    {
        release_object( master_socket );
        master_socket = NULL;
    }
    if (master_timeout)  /* cancel previous timeout */
        remove_timeout_user( master_timeout );

    master_timeout = add_timeout_user( timeout, close_socket_timeout, NULL );
}
