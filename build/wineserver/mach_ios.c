/*
 * Server-side debugger support using Mach primitives
 *
 * Copyright (C) 1999, 2006 Alexandre Julliard
 * Copyright (C) 2006 Ken Thomases for CodeWeavers
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
#include "../madeira_cfg.h"   /* ml1095 */

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <signal.h>
#include <stdarg.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>   /* ml1003: O_RDONLY for the escape-hatch read */
#ifdef HAVE_SYS_SYSCTL_H
#include <sys/sysctl.h>
#endif

#include "ntstatus.h"
#include "winternl.h"

#include "file.h"
#include "process.h"
#include "thread.h"
#include "request.h"

#ifdef USE_MACH

#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach/thread_act.h>
#include <mach/mach_vm.h>
#include <servers/bootstrap.h>

static mach_port_t server_mach_port;

void sigchld_callback(void)
{
    assert(0);  /* should never be called on MacOS */
}

static void mach_set_error(kern_return_t mach_error)
{
    switch (mach_error)
    {
        case KERN_SUCCESS:              break;
        case KERN_INVALID_ARGUMENT:     set_error(STATUS_INVALID_PARAMETER); break;
        case KERN_NO_SPACE:             set_error(STATUS_NO_MEMORY); break;
        case KERN_PROTECTION_FAILURE:   set_error(STATUS_ACCESS_DENIED); break;
        case KERN_INVALID_ADDRESS:      set_error(STATUS_ACCESS_VIOLATION); break;
        default:                        set_error(STATUS_UNSUCCESSFUL); break;
    }
}

static mach_port_t get_process_port( struct process *process )
{
    /* NOTE (task #32): NOT changed to mach_task_self() on iOS. The cross-thread
     * context capture (ios_fill_thread_context) uses mach_task_self() directly,
     * so it doesn't need this. Making this return our task would additionally
     * ACTIVATE read/write_process_memory (they early-out on !process_port),
     * which regressed Steam boot into a guest SEGV + loader-lock deadlock —
     * some caller depends on the old ACCESS_DENIED no-op. Leave as-is. */
    return process->trace_data;
}

static int is_rosetta( void )
{
    static int rosetta_status, did_check = 0;
    if (!did_check)
    {
        /* returns 0 for native process or on error, 1 for translated */
        int ret = 0;
        size_t size = sizeof(ret);
        if (sysctlbyname( "sysctl.proc_translated", &ret, &size, NULL, 0 ) == -1)
            rosetta_status = 0;
        else
            rosetta_status = ret;

        did_check = 1;
    }

    return rosetta_status;
}

extern kern_return_t bootstrap_register2( mach_port_t bp, name_t service_name, mach_port_t sp, uint64_t flags );

/* initialize the process control mechanism */
void init_tracing_mechanism(void)
{
#ifdef WINE_IOS
    /* On iOS, skip bootstrap_register2 - no launchd access */
    mach_port_allocate( mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &server_mach_port );
#else
    mach_port_t bp;

    if (task_get_bootstrap_port( mach_task_self(), &bp ) != KERN_SUCCESS)
        fatal_error( "Can't find bootstrap port\n" );
    if (mach_port_allocate( mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &server_mach_port ) != KERN_SUCCESS)
        fatal_error( "Can't allocate port\n" );
    if  (mach_port_insert_right( mach_task_self(),
                                 server_mach_port,
                                 server_mach_port,
                                 MACH_MSG_TYPE_MAKE_SEND ) != KERN_SUCCESS)
            fatal_error( "Error inserting rights\n" );
    if (bootstrap_register2( bp, server_dir, server_mach_port, 0 ) != KERN_SUCCESS)
        fatal_error( "Can't check in server_mach_port\n" );
    mach_port_deallocate( mach_task_self(), bp );
#endif
}

/* initialize the per-process tracing mechanism */
void init_process_tracing( struct process *process )
{
    int pid, ret;
    struct
    {
        mach_msg_header_t           header;
        mach_msg_body_t             body;
        mach_msg_port_descriptor_t  task_port;
        mach_msg_trailer_t          trailer; /* only present on receive */
    } msg;

    for (;;)
    {
        ret = mach_msg( &msg.header, MACH_RCV_MSG|MACH_RCV_TIMEOUT, 0, sizeof(msg),
                        server_mach_port, 0, 0 );
        if (ret)
        {
            if (ret != MACH_RCV_TIMED_OUT && debug_level)
                fprintf( stderr, "warning: mach port receive failed with %x\n", ret );
            return;
        }

        /* if anything in the message is invalid, ignore it */
        if (msg.header.msgh_size != offsetof(typeof(msg), trailer)) continue;
        if (msg.body.msgh_descriptor_count != 1) continue;
        if (msg.task_port.type != MACH_MSG_PORT_DESCRIPTOR) continue;
        if (msg.task_port.disposition != MACH_MSG_TYPE_PORT_SEND) continue;
        if (msg.task_port.name == MACH_PORT_NULL) continue;
        if (msg.task_port.name == MACH_PORT_DEAD) continue;

        if (!pid_for_task( msg.task_port.name, &pid ))
        {
            struct thread *thread = get_thread_from_pid( pid );

            if (thread && !thread->process->trace_data)
                thread->process->trace_data = msg.task_port.name;
            else
                mach_port_deallocate( mach_task_self(), msg.task_port.name );
        }
    }
    /* On Mach thread priorities depend on having the process port available, so
     * reapply all thread priorities here after process tracing is initialized */
    set_process_base_priority( process, process->base_priority );
}

/* terminate the per-process tracing mechanism */
void finish_process_tracing( struct process *process )
{
    if (process->trace_data)
    {
        mach_port_deallocate( mach_task_self(), process->trace_data );
        process->trace_data = 0;
    }
}

/* initialize registers in new thread if necessary */
void init_thread_context( struct thread *thread )
{
}

/* retrieve the thread x86 registers */
void get_thread_context( struct thread *thread, struct context_data *context, unsigned int flags )
{
#if defined(__i386__) || defined(__x86_64__)
    x86_debug_state_t state;
    mach_msg_type_number_t count = sizeof(state) / sizeof(int);
    mach_msg_type_name_t type;
    mach_port_t port, process_port = get_process_port( thread->process );
    kern_return_t ret;
    unsigned long dr[8];

    /* all other regs are handled on the client side */
    assert( flags == SERVER_CTX_DEBUG_REGISTERS );

    if (is_rosetta())
    {
        /* getting debug registers of a translated process is not supported cross-process, return all zeroes */
        memset( &context->debug, 0, sizeof(context->debug) );
        context->flags |= SERVER_CTX_DEBUG_REGISTERS;
        return;
    }

    if (thread->unix_pid == -1 || !process_port ||
        mach_port_extract_right( process_port, thread->unix_tid,
                                 MACH_MSG_TYPE_COPY_SEND, &port, &type ))
    {
        set_error( STATUS_ACCESS_DENIED );
        return;
    }

    ret = thread_get_state( port, x86_DEBUG_STATE, (thread_state_t)&state, &count );
    if (!ret)
    {
        assert( state.dsh.flavor == x86_DEBUG_STATE32 ||
                state.dsh.flavor == x86_DEBUG_STATE64 );

        if (state.dsh.flavor == x86_DEBUG_STATE64)
        {
            dr[0] = state.uds.ds64.__dr0;
            dr[1] = state.uds.ds64.__dr1;
            dr[2] = state.uds.ds64.__dr2;
            dr[3] = state.uds.ds64.__dr3;
            dr[6] = state.uds.ds64.__dr6;
            dr[7] = state.uds.ds64.__dr7;
        }
        else
        {
            dr[0] = state.uds.ds32.__dr0;
            dr[1] = state.uds.ds32.__dr1;
            dr[2] = state.uds.ds32.__dr2;
            dr[3] = state.uds.ds32.__dr3;
            dr[6] = state.uds.ds32.__dr6;
            dr[7] = state.uds.ds32.__dr7;
        }

        switch (context->machine)
        {
        case IMAGE_FILE_MACHINE_I386:
            context->debug.i386_regs.dr0 = dr[0];
            context->debug.i386_regs.dr1 = dr[1];
            context->debug.i386_regs.dr2 = dr[2];
            context->debug.i386_regs.dr3 = dr[3];
            context->debug.i386_regs.dr6 = dr[6];
            context->debug.i386_regs.dr7 = dr[7];
            break;
        case IMAGE_FILE_MACHINE_AMD64:
            context->debug.x86_64_regs.dr0 = dr[0];
            context->debug.x86_64_regs.dr1 = dr[1];
            context->debug.x86_64_regs.dr2 = dr[2];
            context->debug.x86_64_regs.dr3 = dr[3];
            context->debug.x86_64_regs.dr6 = dr[6];
            context->debug.x86_64_regs.dr7 = dr[7];
            break;
        default:
            set_error( STATUS_INVALID_PARAMETER );
            goto done;
        }
        context->flags |= SERVER_CTX_DEBUG_REGISTERS;
    }
    else
        mach_set_error( ret );
done:
    mach_port_deallocate( mach_task_self(), port );
#endif
}

/* set the thread x86 registers */
void set_thread_context( struct thread *thread, const struct context_data *context, unsigned int flags )
{
#if defined(__i386__) || defined(__x86_64__)
    x86_debug_state_t state;
    mach_msg_type_number_t count = sizeof(state) / sizeof(int);
    mach_msg_type_name_t type;
    mach_port_t port, process_port = get_process_port( thread->process );
    unsigned long dr[8];
    kern_return_t ret;

    /* all other regs are handled on the client side */
    assert( flags == SERVER_CTX_DEBUG_REGISTERS );

    if (is_rosetta())
    {
        /* Setting debug registers of a translated process is not supported cross-process
         * (and even in-process, setting debug registers never has the desired effect).
         */
        set_error( STATUS_UNSUCCESSFUL );
        return;
    }

    if (thread->unix_pid == -1 || !process_port ||
        mach_port_extract_right( process_port, thread->unix_tid,
                                 MACH_MSG_TYPE_COPY_SEND, &port, &type ))
    {
        set_error( STATUS_ACCESS_DENIED );
        return;
    }

    /* get the debug state to determine which flavor to use */
    ret = thread_get_state(port, x86_DEBUG_STATE, (thread_state_t)&state, &count);
    if (ret)
    {
        mach_set_error( ret );
        goto done;
    }
    assert( state.dsh.flavor == x86_DEBUG_STATE32 ||
            state.dsh.flavor == x86_DEBUG_STATE64 );

    switch (context->machine)
    {
        case IMAGE_FILE_MACHINE_I386:
            dr[0] = context->debug.i386_regs.dr0;
            dr[1] = context->debug.i386_regs.dr1;
            dr[2] = context->debug.i386_regs.dr2;
            dr[3] = context->debug.i386_regs.dr3;
            dr[6] = context->debug.i386_regs.dr6;
            dr[7] = context->debug.i386_regs.dr7;
            break;
        case IMAGE_FILE_MACHINE_AMD64:
            dr[0] = context->debug.x86_64_regs.dr0;
            dr[1] = context->debug.x86_64_regs.dr1;
            dr[2] = context->debug.x86_64_regs.dr2;
            dr[3] = context->debug.x86_64_regs.dr3;
            dr[6] = context->debug.x86_64_regs.dr6;
            dr[7] = context->debug.x86_64_regs.dr7;
            break;
        default:
            set_error( STATUS_INVALID_PARAMETER );
            goto done;
    }

    /* Mac OS doesn't allow setting the global breakpoint flags */
    dr[7] = (dr[7] & ~0xaa) | ((dr[7] & 0xaa) >> 1);

    if (state.dsh.flavor == x86_DEBUG_STATE64)
    {
        state.dsh.count = sizeof(state.uds.ds64) / sizeof(int);
        state.uds.ds64.__dr0 = dr[0];
        state.uds.ds64.__dr1 = dr[1];
        state.uds.ds64.__dr2 = dr[2];
        state.uds.ds64.__dr3 = dr[3];
        state.uds.ds64.__dr4 = 0;
        state.uds.ds64.__dr5 = 0;
        state.uds.ds64.__dr6 = dr[6];
        state.uds.ds64.__dr7 = dr[7];
    }
    else
    {
        state.dsh.count = sizeof(state.uds.ds32) / sizeof(int);
        state.uds.ds32.__dr0 = dr[0];
        state.uds.ds32.__dr1 = dr[1];
        state.uds.ds32.__dr2 = dr[2];
        state.uds.ds32.__dr3 = dr[3];
        state.uds.ds32.__dr4 = 0;
        state.uds.ds32.__dr5 = 0;
        state.uds.ds32.__dr6 = dr[6];
        state.uds.ds32.__dr7 = dr[7];
    }
    ret = thread_set_state( port, x86_DEBUG_STATE, (thread_state_t)&state, count );
    if (ret)
        mach_set_error( ret );
done:
    mach_port_deallocate( mach_task_self(), port );
#endif
}

extern int __pthread_kill( mach_port_t, int );

int send_thread_signal( struct thread *thread, int sig )
{
    int ret = -1;
    mach_port_t process_port = get_process_port( thread->process );

    if (thread->unix_pid != -1 && process_port)
    {
        mach_msg_type_name_t type;
        mach_port_t port;

        if (!mach_port_extract_right( process_port, thread->unix_tid,
                                      MACH_MSG_TYPE_COPY_SEND, &port, &type ))
        {
            ret = __pthread_kill( port, sig );
            mach_port_deallocate( mach_task_self(), port );
        }
        else errno = ESRCH;

        if (ret == -1 && errno == ESRCH) /* thread got killed */
        {
            thread->unix_pid = -1;
            thread->unix_tid = -1;
        }
    }
    if (debug_level && ret != -1)
        fprintf( stderr, "%04x: *sent signal* signal=%d\n", thread->id, sig );
    return (ret != -1);
}

#ifdef WINE_IOS
/* iOS cross-thread context capture (task #32).
 *
 * POSIX signal suspend (SIGUSR1 via __pthread_kill) does NOT deliver on iOS —
 * __pthread_kill returns success but usr1_handler never runs, so the upstream
 * "target thread fills its own context in wait_suspend" mechanism is dead and
 * SuspendThread+GetThreadContext hung forever (Steam's watchdog wedged boot).
 *
 * Instead the SERVER captures the target's context via native Mach:
 *   - thread_suspend() halts the target for a coherent snapshot,
 *   - thread_get_state(ARM_THREAD_STATE64) gives the native ARM64 regs,
 *   - the guest x86-64 regs are read from the target's last-synced CPU-area
 *     context (TEB->ChpeV2CpuAreaInfo->ContextAmd64, an AMD64 CONTEXT laid out
 *     binary-compatibly), reachable by a same-task read,
 *   - thread_resume() lets it run again (momentary halt — no lasting suspend,
 *     so no lock-holder deadlock window).
 * Fills both context_data sides; thread.c's stop_thread sets status + signals
 * the context sync so the client's GetThreadContext returns without PENDING.
 *
 * The guest RIP is FEX's last block-boundary sync value — exactly what Steam's
 * hang-detection watchdog samples; a progressing thread shows an advancing RIP.
 * Returns 1 if at least the native context was captured. */

/* TEB / CPU-area / AMD64 CONTEXT field offsets (see winternl.h / winnt.h). */
#define IOS_TEB_CHPE_CPUAREA_OFF   0x1788   /* TEB.ChpeV2CpuAreaInfo */
/* ml716: ntdll_thread_data lives at TEB+GdiTebBatch (0x2f0). Field offsets are documented
 * in wine/dlls/ntdll/unix/unix_private.h: syscall_table 0x370, syscall_frame 0x378,
 * syscall_trace 0x380. kernel_stack follows request_fd/reply_fd/wait_fd[2]/alert_fd/
 * allow_writes (ending 0x39c), an 8-align pad, then pthread_id 0x3a0 -> 0x3a8. That last
 * one is derived rather than documented, so it is VALIDATED at runtime and any
 * implausible value makes the whole substitution fall through. */
#define IOS_TEB_SYSCALL_FRAME_OFF  0x378
#define IOS_TEB_KERNEL_STACK_OFF   0x3a8
/* struct syscall_frame (unix/signal_arm64.c): x[29] 000, fp 0e8, lr 0f0, sp 0f8,
 * pc 100, cpsr 108; sizeof == 0x330. */
#define IOS_SCF_FP    0x0e8
#define IOS_SCF_LR    0x0f0
#define IOS_SCF_SP    0x0f8
#define IOS_SCF_PC    0x100
#define IOS_SCF_CPSR  0x108
#define IOS_SCF_SIZE  0x330
#define IOS_SCF_RESTORE_FLAGS 0x10c           /* syscall_frame.restore_flags */
#define IOS_CTX_ARM64_CONTROL 0x00400001u     /* CONTEXT_ARM64 | CONTEXT_ARM64_CONTROL */
#define IOS_CPUAREA_CTX64_OFF      0x18     /* CHPE_V2_CPU_AREA_INFO.ContextAmd64 */
#define IOS_A64_SEGCS   0x38
#define IOS_A64_SEGDS   0x3a
#define IOS_A64_SEGES   0x3c
#define IOS_A64_SEGFS   0x3e
#define IOS_A64_SEGGS   0x40
#define IOS_A64_SEGSS   0x42
#define IOS_A64_EFLAGS  0x44
#define IOS_A64_RAX     0x78
#define IOS_A64_RCX     0x80
#define IOS_A64_RDX     0x88
#define IOS_A64_RBX     0x90
#define IOS_A64_RSP     0x98
#define IOS_A64_RBP     0xa0
#define IOS_A64_RSI     0xa8
#define IOS_A64_RDI     0xb0
#define IOS_A64_R8      0xb8
#define IOS_A64_R9      0xc0
#define IOS_A64_R10     0xc8
#define IOS_A64_R11     0xd0
#define IOS_A64_R12     0xd8
#define IOS_A64_R13     0xe0
#define IOS_A64_R14     0xe8
#define IOS_A64_R15     0xf0
#define IOS_A64_RIP     0xf8
#define IOS_A64_FLTSAVE 0x100
#define IOS_A64_CTXLEN  0x4d0            /* full AMD64 CONTEXT */

static int ios_safe_read( uint64_t addr, void *buf, unsigned int size )
{
    mach_vm_size_t got = 0;
    if (!addr) return 0;
    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)addr,
                                (mach_vm_size_t)size, (mach_vm_address_t)buf, &got ))
        return 0;
    return got == size;
}

/* ================= ml730 REAL THREAD SUSPENSION (opt-in) =================
 *
 * Wine's suspend contract is that a suspended thread STOPS. On iOS it never
 * has: POSIX signal suspend is dead (task #32), so stop_thread() takes a Mach
 * snapshot and lets the target keep running while the server's counter goes
 * up. Mono's hybrid suspend depends on the real contract -- it marks a thread
 * STATE_BLOCKING_ASYNC_SUSPENDED once SuspendThread+GetThreadContext report
 * success, and if that thread then keeps running and leaves its blocking
 * region, mono_threads_transition_done_blocking() rejects the transition and
 * g_error()s into an `eb fe` spin. That is the observed wall.
 *
 * PHYSICAL HOLD BOOKKEEPING is explicit, never inferred:
 *   snapshot-only capture  : suspend -> capture -> resume            (as before)
 *   first logical suspend  : suspend -> capture -> KEEP the hold
 *   nested logical suspend : counter only, no second Mach suspend
 *   final logical resume   : release exactly one Mach hold
 * An ordinary context snapshot must never release a persistent hold.
 *
 * OPT-IN (MADEIRA_REAL_SUSPEND=1) and default-off: we are a single Mach process
 * and wineserver is a thread inside it, sharing the allocator with the guest,
 * so genuinely freezing a thread that holds the malloc lock or FEX's
 * CodeInvalidationMutex can deadlock the suspender. Windows apps tolerate this
 * because the suspender does not share their heap; here it does.
 *
 * Counters are AGGREGATE on purpose -- a per-event line would perturb exactly
 * the timing this changes. Failures are always reported (capped). */
int ios_real_suspend_enabled(void)
{
    /* Read on every call: the app sets it per session (a game's "Pause threads
     * fully" switch, BCDLaunch.realSuspend), and this server runs again in the
     * same process for the next session of the app run. Logged when it changes. */
    static int logged = -1;
    const char *e = getenv( "MADEIRA_REAL_SUSPEND" );
    int env = (e && e[0] == '1') ? 1 : 0;
    if (env != __atomic_exchange_n( &logged, env, __ATOMIC_RELAXED ))
    {
        fprintf( stderr, "[real-susp] ml730 MADEIRA_REAL_SUSPEND=%d\n", env );
    }
    return env;
}

static unsigned int rs_holds, rs_releases, rs_hold_fail, rs_release_fail, rs_ops;

void ios_real_suspend_stats( const char *why )
{
    fprintf( stderr, "[real-susp] ml730 %s: ops=%u holds=%u releases=%u "
             "outstanding=%d hold_fail=%u release_fail=%u\n",
             why, rs_ops, rs_holds, rs_releases,
             (int)rs_holds - (int)rs_releases, rs_hold_fail, rs_release_fail );
}

static void rs_tick(void)
{
    if (++rs_ops % 128 == 0) ios_real_suspend_stats( "tick" );
}

/* ml730b: the hold flag must only ever be 0 or 1. It is a plain field in a
 * server object that mem_alloc() poisons with 0x55, so an uninitialized one
 * reads 0x55555555 -- which looks exactly like "already held" and silently
 * turns every hold into a no-op while every release resumes a thread that was
 * never suspended. That is precisely how the first ml730 run measured nothing
 * and still reported success. Refuse to act on a value we do not recognise,
 * and say so loudly rather than guessing. */
static unsigned int rs_flag_bad;
static int rs_flag_ok( struct thread *thread, const char *who )
{
    int v = thread->ios_mach_suspended;
    if (v == 0 || v == 1) return 1;
    if (rs_flag_bad++ < 16)
        fprintf( stderr, "[real-susp] ml730b CORRUPT HOLD FLAG tid=%04x %s value=0x%x "
                 "-- refusing to act (uninitialized?)\n", thread->id, who, (unsigned)v );
    thread->ios_mach_suspended = 0;
    return 0;
}

/* Apply ONE persistent Mach hold. Idempotent per thread. */
int ios_thread_mach_hold( struct thread *thread )
{
    mach_msg_type_name_t type;
    mach_port_t port;
    kern_return_t kr;

    rs_tick();
    if (!ios_real_suspend_enabled()) return 0;
    if (!rs_flag_ok( thread, "hold" )) return 0;
    if (thread->ios_mach_suspended) return 1;          /* nested: counter only */
    if (thread->unix_pid == -1 || thread->unix_tid == (unsigned int)-1) return 0;
    if (mach_port_extract_right( mach_task_self(), thread->unix_tid,
                                 MACH_MSG_TYPE_COPY_SEND, &port, &type ))
        return 0;
    kr = thread_suspend( port );
    mach_port_deallocate( mach_task_self(), port );
    if (kr)
    {
        if (rs_hold_fail++ < 16)
            fprintf( stderr, "[real-susp] ml730 HOLD FAILED tid=%04x kr=%d\n", thread->id, kr );
        return 0;
    }
    thread->ios_mach_suspended = 1;
    rs_holds++;
    return 1;
}

/* Release the one persistent Mach hold, if we hold it. */
int ios_thread_mach_release( struct thread *thread )
{
    mach_msg_type_name_t type;
    mach_port_t port;
    kern_return_t kr;

    rs_tick();
    if (!rs_flag_ok( thread, "release" )) return 0;
    if (!thread->ios_mach_suspended) return 0;
    thread->ios_mach_suspended = 0;                    /* clear first: never double-release */
    if (thread->unix_pid == -1 || thread->unix_tid == (unsigned int)-1) return 0;
    if (mach_port_extract_right( mach_task_self(), thread->unix_tid,
                                 MACH_MSG_TYPE_COPY_SEND, &port, &type ))
        return 0;
    kr = thread_resume( port );
    mach_port_deallocate( mach_task_self(), port );
    if (kr)
    {
        if (rs_release_fail++ < 16)
            fprintf( stderr, "[real-susp] ml730 RELEASE FAILED tid=%04x kr=%d\n", thread->id, kr );
        return 0;
    }
    rs_releases++;
    return 1;
}

/* ================= WoW64 (i386) thread contexts =================
 *
 * The server side of "Thread contexts of WoW64 processes" in wine's
 * server/thread.c.  Only ever used for threads of i386 processes
 * (ios_process_is_wow64); 64-bit processes keep the capture above unchanged
 * and never reach ios_apply_resume_context().
 *
 * GET: the 32-bit register state of a WoW64 thread that is inside a system
 * call lives in its WoW64 CPU area (TEB64->TlsSlots[WOW64_TLS_CPURESERVED]:
 * a WOW64_CPURESERVED header followed by an I386_CONTEXT), exactly where
 * wine's own get_cpu_area() finds it.  ios_wow_capture() reads it into the WOW
 * side and records, in thread->ios_ctx_frame / ios_ctx_seq, which syscall
 * frame the capture came from and a fingerprint of that frame (the return
 * point: pc, sp, fp, lr).
 *
 * SET: a SetThreadContext on a suspended thread is applied by resume_thread()
 * through ios_apply_resume_context().  The thread is halted for the write and
 * the write happens only while it is still inside the SAME syscall frame with
 * the SAME return point it had at capture; the native registers go into the
 * syscall frame (as NtSetContextThread's own in-syscall path does, x18
 * excluded) and the 32-bit registers into the CPU area, with
 * WOW64_CPURESERVED_FLAG_RESET_STATE set so the CPU module reloads them on the
 * way back to 32-bit code (wine's set_thread_wow64_context does the same).
 * Anything else -- the thread left the call, or is running JIT code -- is
 * dropped and reported by the caller: writing registers captured in one
 * syscall into another is the corruption this design exists to avoid. */
#define IOS_TEB_TLS_SLOTS_OFF   0x1480   /* TEB.TlsSlots (64-bit TEB) */
#define IOS_WOW_CPURESERVED_SZ  4        /* WOW64_CPURESERVED: USHORT Flags, USHORT Machine */
#define IOS_WOW_RESET_STATE     1        /* WOW64_CPURESERVED_FLAG_RESET_STATE */
/* I386_CONTEXT field offsets (winnt.h) */
#define IOS_X86_FLAGS   0x00
#define IOS_X86_DR0     0x04
#define IOS_X86_FLOAT   0x1c
#define IOS_X86_CR0NPX  0x88
#define IOS_X86_SEGGS   0x8c
#define IOS_X86_SEGFS   0x90
#define IOS_X86_SEGES   0x94
#define IOS_X86_SEGDS   0x98
#define IOS_X86_EDI     0x9c
#define IOS_X86_ESI     0xa0
#define IOS_X86_EBX     0xa4
#define IOS_X86_EDX     0xa8
#define IOS_X86_ECX     0xac
#define IOS_X86_EAX     0xb0
#define IOS_X86_EBP     0xb4
#define IOS_X86_EIP     0xb8
#define IOS_X86_SEGCS   0xbc
#define IOS_X86_EFLAGS  0xc0
#define IOS_X86_ESP     0xc4
#define IOS_X86_SEGSS   0xc8
#define IOS_X86_EXT     0xcc
#define IOS_X86_CTXLEN  0x2cc
#define IOS_X86_CONTROL   0x00010001
#define IOS_X86_INTEGER   0x00010002
#define IOS_X86_SEGMENTS  0x00010004
#define IOS_X86_FLOATING  0x00010008
#define IOS_X86_DEBUG     0x00010010
#define IOS_X86_EXTENDED  0x00010020

#define IOS_X86_U32(c, off) (*(unsigned int *)((c) + (off)))

/* The syscall frame the thread is inside, or 0 (kernel_stack <= sp <= frame,
 * the same selector as is_inside_syscall()). */
static uint64_t ios_wow_syscall_frame( struct thread *thread, uint64_t sp )
{
    uint64_t frame = 0, kstack = 0;

    if (!thread->teb) return 0;
    if (!ios_safe_read( (uint64_t)thread->teb + IOS_TEB_SYSCALL_FRAME_OFF, &frame, 8 ) ||
        !ios_safe_read( (uint64_t)thread->teb + IOS_TEB_KERNEL_STACK_OFF, &kstack, 8 ))
        return 0;
    if (!frame || !kstack || (frame & 7) || kstack >= frame || sp < kstack || sp > frame) return 0;
    return frame;
}

/* Fingerprint of a syscall frame's return point. */
static unsigned int ios_wow_frame_seq( uint64_t frame )
{
    unsigned char f[IOS_SCF_SIZE];
    uint64_t h = 0xcbf29ce484222325ull, v[4];
    unsigned int i;

    if (!frame || !ios_safe_read( frame, f, sizeof(f) )) return 0;
    v[0] = *(uint64_t *)(f + IOS_SCF_PC);
    v[1] = *(uint64_t *)(f + IOS_SCF_SP);
    v[2] = *(uint64_t *)(f + IOS_SCF_FP);
    v[3] = *(uint64_t *)(f + IOS_SCF_LR);
    for (i = 0; i < 4; i++) h = (h ^ v[i]) * 0x100000001b3ull;
    return (unsigned int)(h ^ (h >> 32)) | 1;   /* never 0: 0 means "no capture" */
}

/* Address of the thread's WoW64 I386_CONTEXT, or 0. */
static uint64_t ios_wow_cpu_context( struct thread *thread, uint64_t *cpu_out )
{
    uint64_t cpu = 0;
    unsigned short hdr[2];

    if (!thread->teb) return 0;
    if (!ios_safe_read( (uint64_t)thread->teb + IOS_TEB_TLS_SLOTS_OFF + 8, &cpu, 8 ) || !cpu) return 0;
    if (!ios_safe_read( cpu, hdr, sizeof(hdr) ) || hdr[1] != IMAGE_FILE_MACHINE_I386) return 0;
    if (cpu_out) *cpu_out = cpu;
    return (cpu + IOS_WOW_CPURESERVED_SZ + 3) & ~(uint64_t)3;   /* TYPE_ALIGNMENT(I386_CONTEXT) */
}

/* Called with the target halted, from ios_fill_thread_context(). */
static void ios_wow_capture( struct thread *thread, uint64_t sp, struct context_data *wow )
{
    unsigned char c[IOS_X86_CTXLEN];
    uint64_t frame = ios_wow_syscall_frame( thread, sp ), ctx;

    thread->ios_ctx_frame = frame;
    thread->ios_ctx_seq   = ios_wow_frame_seq( frame );
    if (!wow) return;
    wow->machine = IMAGE_FILE_MACHINE_I386;
    if (!frame || !(ctx = ios_wow_cpu_context( thread, NULL )) || !ios_safe_read( ctx, c, sizeof(c) ))
        return;   /* running 32-bit code: the CPU area is not current, report nothing */

    wow->flags |= SERVER_CTX_CONTROL | SERVER_CTX_INTEGER | SERVER_CTX_SEGMENTS |
                  SERVER_CTX_FLOATING_POINT | SERVER_CTX_DEBUG_REGISTERS | SERVER_CTX_EXTENDED_REGISTERS;
    wow->ctl.i386_regs.ebp    = IOS_X86_U32( c, IOS_X86_EBP );
    wow->ctl.i386_regs.esp    = IOS_X86_U32( c, IOS_X86_ESP );
    wow->ctl.i386_regs.eip    = IOS_X86_U32( c, IOS_X86_EIP );
    wow->ctl.i386_regs.cs     = IOS_X86_U32( c, IOS_X86_SEGCS );
    wow->ctl.i386_regs.ss     = IOS_X86_U32( c, IOS_X86_SEGSS );
    wow->ctl.i386_regs.eflags = IOS_X86_U32( c, IOS_X86_EFLAGS );
    wow->integer.i386_regs.eax = IOS_X86_U32( c, IOS_X86_EAX );
    wow->integer.i386_regs.ebx = IOS_X86_U32( c, IOS_X86_EBX );
    wow->integer.i386_regs.ecx = IOS_X86_U32( c, IOS_X86_ECX );
    wow->integer.i386_regs.edx = IOS_X86_U32( c, IOS_X86_EDX );
    wow->integer.i386_regs.esi = IOS_X86_U32( c, IOS_X86_ESI );
    wow->integer.i386_regs.edi = IOS_X86_U32( c, IOS_X86_EDI );
    wow->seg.i386_regs.ds = IOS_X86_U32( c, IOS_X86_SEGDS );
    wow->seg.i386_regs.es = IOS_X86_U32( c, IOS_X86_SEGES );
    wow->seg.i386_regs.fs = IOS_X86_U32( c, IOS_X86_SEGFS );
    wow->seg.i386_regs.gs = IOS_X86_U32( c, IOS_X86_SEGGS );
    memcpy( &wow->fp.i386_regs, c + IOS_X86_FLOAT, 7 * 4 );                 /* ctrl .. data_sel */
    memcpy( wow->fp.i386_regs.regs, c + IOS_X86_FLOAT + 7 * 4, sizeof(wow->fp.i386_regs.regs) );
    wow->fp.i386_regs.cr0npx = IOS_X86_U32( c, IOS_X86_CR0NPX );
    memcpy( &wow->debug.i386_regs, c + IOS_X86_DR0, sizeof(wow->debug.i386_regs) );
    memcpy( wow->ext.i386_regs, c + IOS_X86_EXT, sizeof(wow->ext.i386_regs) );
}

/* Apply a SetThreadContext made while the thread was suspended (resume_thread()
 * in wine's server/thread.c).  Returns 1 when applied, 0 when dropped. */
int ios_apply_resume_context( struct thread *thread, const struct context_data *native,
                              const struct context_data *wow )
{
    mach_msg_type_name_t type;
    mach_port_t port;
    arm_thread_state64_t arm;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    uint64_t frame, ctx, cpu = 0;
    int applied = 0;

    if (!ios_process_is_wow64( thread->process )) return 0;
    if (!thread->ios_ctx_frame || !thread->ios_ctx_seq) return 0;
    if (thread->unix_pid == -1 || thread->unix_tid == (unsigned int)-1) return 0;
    if (mach_port_extract_right( mach_task_self(), thread->unix_tid,
                                 MACH_MSG_TYPE_COPY_SEND, &port, &type ))
        return 0;
    if (thread_suspend( port )) { mach_port_deallocate( mach_task_self(), port ); return 0; }

    if (thread_get_state( port, ARM_THREAD_STATE64, (thread_state_t)&arm, &count )) goto done;
    frame = ios_wow_syscall_frame( thread, arm.__sp );
    if (!frame || frame != thread->ios_ctx_frame || ios_wow_frame_seq( frame ) != thread->ios_ctx_seq)
        goto done;   /* the thread left the syscall the capture came from */

    /* native side: into the syscall frame, x18 (the TEB) never overwritten */
    if (native && (native->flags & SERVER_CTX_CONTROL) && native->machine == native_machine)
    {
        unsigned char f[IOS_SCF_SIZE];
        unsigned int i;

        if (!ios_safe_read( frame, f, sizeof(f) )) goto done;
        if (native->flags & SERVER_CTX_INTEGER)
        {
            for (i = 0; i < 29; i++)
                if (i != 18) *(uint64_t *)(f + i * 8) = native->integer.arm64_regs.x[i];
            *(uint64_t *)(f + IOS_SCF_FP) = native->integer.arm64_regs.x[29];
            *(uint64_t *)(f + IOS_SCF_LR) = native->integer.arm64_regs.x[30];
        }
        *(uint64_t *)(f + IOS_SCF_SP)   = native->ctl.arm64_regs.sp;
        *(uint64_t *)(f + IOS_SCF_PC)   = native->ctl.arm64_regs.pc;
        *(uint32_t *)(f + IOS_SCF_CPSR) = native->ctl.arm64_regs.pstate;
        *(uint32_t *)(f + IOS_SCF_RESTORE_FLAGS) |= IOS_CTX_ARM64_CONTROL;
        if (mach_vm_write( mach_task_self(), (mach_vm_address_t)frame, (vm_offset_t)f,
                           (mach_msg_type_number_t)sizeof(f) ))
            goto done;
    }

    /* 32-bit side: into the CPU area, and tell the CPU module to reload it */
    if (wow && wow->machine == IMAGE_FILE_MACHINE_I386 && wow->flags &&
        (ctx = ios_wow_cpu_context( thread, &cpu )))
    {
        unsigned char c[IOS_X86_CTXLEN];
        unsigned short cpu_flags;

        if (!ios_safe_read( ctx, c, sizeof(c) ) || !ios_safe_read( cpu, &cpu_flags, 2 )) goto done;
        if (wow->flags & SERVER_CTX_CONTROL)
        {
            IOS_X86_U32( c, IOS_X86_EBP )    = wow->ctl.i386_regs.ebp;
            IOS_X86_U32( c, IOS_X86_ESP )    = wow->ctl.i386_regs.esp;
            IOS_X86_U32( c, IOS_X86_EIP )    = wow->ctl.i386_regs.eip;
            IOS_X86_U32( c, IOS_X86_SEGCS )  = wow->ctl.i386_regs.cs;
            IOS_X86_U32( c, IOS_X86_SEGSS )  = wow->ctl.i386_regs.ss;
            IOS_X86_U32( c, IOS_X86_EFLAGS ) = wow->ctl.i386_regs.eflags;
            IOS_X86_U32( c, IOS_X86_FLAGS ) |= IOS_X86_CONTROL;
        }
        if (wow->flags & SERVER_CTX_INTEGER)
        {
            IOS_X86_U32( c, IOS_X86_EAX ) = wow->integer.i386_regs.eax;
            IOS_X86_U32( c, IOS_X86_EBX ) = wow->integer.i386_regs.ebx;
            IOS_X86_U32( c, IOS_X86_ECX ) = wow->integer.i386_regs.ecx;
            IOS_X86_U32( c, IOS_X86_EDX ) = wow->integer.i386_regs.edx;
            IOS_X86_U32( c, IOS_X86_ESI ) = wow->integer.i386_regs.esi;
            IOS_X86_U32( c, IOS_X86_EDI ) = wow->integer.i386_regs.edi;
            IOS_X86_U32( c, IOS_X86_FLAGS ) |= IOS_X86_INTEGER;
        }
        if (wow->flags & SERVER_CTX_SEGMENTS)
        {
            IOS_X86_U32( c, IOS_X86_SEGDS ) = wow->seg.i386_regs.ds;
            IOS_X86_U32( c, IOS_X86_SEGES ) = wow->seg.i386_regs.es;
            IOS_X86_U32( c, IOS_X86_SEGFS ) = wow->seg.i386_regs.fs;
            IOS_X86_U32( c, IOS_X86_SEGGS ) = wow->seg.i386_regs.gs;
            IOS_X86_U32( c, IOS_X86_FLAGS ) |= IOS_X86_SEGMENTS;
        }
        if (wow->flags & SERVER_CTX_FLOATING_POINT)
        {
            memcpy( c + IOS_X86_FLOAT, &wow->fp.i386_regs, 7 * 4 );
            memcpy( c + IOS_X86_FLOAT + 7 * 4, wow->fp.i386_regs.regs, sizeof(wow->fp.i386_regs.regs) );
            IOS_X86_U32( c, IOS_X86_CR0NPX ) = wow->fp.i386_regs.cr0npx;
            IOS_X86_U32( c, IOS_X86_FLAGS ) |= IOS_X86_FLOATING;
        }
        if (wow->flags & SERVER_CTX_DEBUG_REGISTERS)
        {
            memcpy( c + IOS_X86_DR0, &wow->debug.i386_regs, sizeof(wow->debug.i386_regs) );
            IOS_X86_U32( c, IOS_X86_FLAGS ) |= IOS_X86_DEBUG;
        }
        if (wow->flags & SERVER_CTX_EXTENDED_REGISTERS)
        {
            memcpy( c + IOS_X86_EXT, wow->ext.i386_regs, sizeof(wow->ext.i386_regs) );
            IOS_X86_U32( c, IOS_X86_FLAGS ) |= IOS_X86_EXTENDED;
        }
        cpu_flags |= IOS_WOW_RESET_STATE;
        if (mach_vm_write( mach_task_self(), (mach_vm_address_t)ctx, (vm_offset_t)c,
                           (mach_msg_type_number_t)sizeof(c) ) ||
            mach_vm_write( mach_task_self(), (mach_vm_address_t)cpu, (vm_offset_t)&cpu_flags, 2 ))
            goto done;
    }
    applied = 1;

done:
    thread_resume( port );
    mach_port_deallocate( mach_task_self(), port );
    return applied;
}

/* Set by suspend_thread() around its stop_thread() call so the capture below
 * can convert its momentary halt into the persistent hold without ever
 * resuming in between. Snapshot-only callers leave it NULL. */
struct thread *ios_pending_persistent_hold;

int ios_fill_thread_context( struct thread *thread,
                             struct context_data *native,
                             struct context_data *wow )
{
    mach_msg_type_name_t type;
    mach_port_t port;
    arm_thread_state64_t arm;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr;
    int have_native = 0;

    if (thread->unix_pid == -1 || thread->unix_tid == (unsigned int)-1) return 0;
    if (mach_port_extract_right( mach_task_self(), thread->unix_tid,
                                 MACH_MSG_TYPE_COPY_SEND, &port, &type ))
        return 0;

    if (thread_suspend( port )) { mach_port_deallocate( mach_task_self(), port ); return 0; }

    /* --- native ARM64 context --- */
    kr = thread_get_state( port, ARM_THREAD_STATE64, (thread_state_t)&arm, &count );
    if (!kr)
    {
        unsigned int i;
        native->flags |= SERVER_CTX_CONTROL | SERVER_CTX_INTEGER;
        native->ctl.arm64_regs.sp     = arm.__sp;
        native->ctl.arm64_regs.pc     = arm.__pc;
        native->ctl.arm64_regs.pstate = arm.__cpsr;
        for (i = 0; i < 29; i++) native->integer.arm64_regs.x[i] = arm.__x[i];
        native->integer.arm64_regs.x[29] = arm.__fp;
        native->integer.arm64_regs.x[30] = arm.__lr;
        have_native = 1;
    }

    /* ml716: A THREAD PARKED INSIDE A SYSCALL MUST REPORT ITS SYSCALL FRAME.
     *
     * Wine's own suspend path already does this: usr1_handler checks
     * is_inside_syscall(SP) and, when true, builds the context from the saved syscall
     * frame rather than from the interrupted registers. Our iOS Mach path bypassed that
     * and converted whatever the thread was executing -- which for a thread blocked in
     * libsystem_kernel __ulock_wait2 is ordinary Mach-O ARM64 code. The ARM64EC
     * NtGetContextThread wrapper then ran it through context_arm_to_x64(), which maps Pc
     * straight into Rip, handing the caller a Mach-O address as an x64 RIP with ARM ABI
     * registers reinterpreted as x64 ones.
     *
     * Measured on Marvel Cosmic Invasion: every retry returned rip=0x23ddd1ae8 with
     * is_ec=0, while Mono suspended/inspected/resumed the same thread forever holding the
     * critical section that thread needed. The CPU-area ContextAmd64 is NOT a usable
     * fallback -- it is initialised with flags and zero registers and never maintained as
     * a live mirror, which is why four of five stalled threads reported rip=0.
     *
     * Selector mirrors is_inside_syscall() exactly: kernel_stack <= sp <= syscall_frame.
     * NOT "native pc is not EC" -- FEX JIT code is also non-EC but its frame may be stale.
     * RtlIsEcCode() is deliberately not called here: that is a PE-side export and this is
     * native Unix code (ml613). The frame PC is classified later, in the EC wrapper.
     *
     * Opt-in via MADEIRA_CTX_FRAME=1 while it is unproven. Every validation failure falls
     * through to the old behaviour rather than inventing state. */
    if (have_native)
    {
        static int ctx_frame_env = -1;
        if (ctx_frame_env < 0)
        {
            const char *e = getenv( "MADEIRA_CTX_FRAME" );
            ctx_frame_env = (e && e[0] == '1') ? 1 : 0;
        }
        if (ctx_frame_env && thread->teb)
        {
            uint64_t frame = 0, kstack = 0;
            uint64_t sp = native->ctl.arm64_regs.sp;
            uint64_t mach_pc = native->ctl.arm64_regs.pc;   /* before substitution */
            if (ios_safe_read( (uint64_t)thread->teb + IOS_TEB_SYSCALL_FRAME_OFF, &frame, 8 ) &&
                ios_safe_read( (uint64_t)thread->teb + IOS_TEB_KERNEL_STACK_OFF, &kstack, 8 ) &&
                frame && kstack && !(frame & 7) && kstack < frame &&
                sp >= kstack && sp <= frame)
            {
                unsigned char f[IOS_SCF_SIZE];
                if (ios_safe_read( frame, f, sizeof(f) ))
                {
                    uint64_t fpc = *(uint64_t *)(f + IOS_SCF_PC);
                    uint64_t fsp = *(uint64_t *)(f + IOS_SCF_SP);
                    if (fpc && fsp)
                    {
                        unsigned int i;
                        static int n_sub;
                        for (i = 0; i < 29; i++)
                            native->integer.arm64_regs.x[i] = *(uint64_t *)(f + i * 8);
                        native->integer.arm64_regs.x[29] = *(uint64_t *)(f + IOS_SCF_FP);
                        native->integer.arm64_regs.x[30] = *(uint64_t *)(f + IOS_SCF_LR);
                        native->ctl.arm64_regs.sp     = fsp;
                        native->ctl.arm64_regs.pc     = fpc;
                        native->ctl.arm64_regs.pstate = *(uint32_t *)(f + IOS_SCF_CPSR);
                        if (n_sub++ < 48)
                            fprintf( stderr, "[ctx-frame] ml716 #%d tid=%04x source=syscall-frame "
                                     "mach_pc=%p sp=%p inside_syscall=1 frame=%p frame_pc=%p frame_sp=%p\n",
                                     n_sub, thread->id, (void *)(uintptr_t)mach_pc,
                                     (void *)(uintptr_t)sp, (void *)(uintptr_t)frame,
                                     (void *)(uintptr_t)fpc, (void *)(uintptr_t)fsp );
                    }
                }
            }
        }
    }

    /* --- WoW64 (i386) process: 32-bit context from its CPU area --- */
    if (have_native && ios_process_is_wow64( thread->process ))
        ios_wow_capture( thread, arm.__sp, wow );
    /* --- guest x86-64 context from TEB->ChpeV2CpuAreaInfo->ContextAmd64 --- */
    else if (wow)
    {
        uint64_t cpuarea = 0, ctx64 = 0;
        unsigned char ctx[IOS_A64_CTXLEN];
        /* Tag the WOW side with the guest machine unconditionally so the
         * get_thread_context handler's native/WOW split always routes an
         * AMD64 request correctly, even if the CPU-area read fails for an
         * early / pure-native thread (then flags stay 0 → empty x64 ctx). */
        wow->machine = thread->process->machine;   /* IMAGE_FILE_MACHINE_AMD64 */
        if (thread->teb &&
            ios_safe_read( (uint64_t)thread->teb + IOS_TEB_CHPE_CPUAREA_OFF, &cpuarea, 8 ) && cpuarea &&
            ios_safe_read( cpuarea + IOS_CPUAREA_CTX64_OFF, &ctx64, 8 ) && ctx64 &&
            ios_safe_read( ctx64, ctx, sizeof(ctx) ))
        {
            wow->flags |= SERVER_CTX_CONTROL | SERVER_CTX_INTEGER | SERVER_CTX_SEGMENTS |
                          SERVER_CTX_FLOATING_POINT;
            wow->ctl.x86_64_regs.rip   = *(uint64_t *)(ctx + IOS_A64_RIP);
            wow->ctl.x86_64_regs.rsp   = *(uint64_t *)(ctx + IOS_A64_RSP);
            wow->ctl.x86_64_regs.cs    = *(uint16_t *)(ctx + IOS_A64_SEGCS);
            wow->ctl.x86_64_regs.ss    = *(uint16_t *)(ctx + IOS_A64_SEGSS);
            wow->ctl.x86_64_regs.flags = *(uint32_t *)(ctx + IOS_A64_EFLAGS);
            /* AMD64 CONTEXT memory order (Rax,Rcx,Rdx,Rbx,Rsp,Rbp,Rsi,Rdi,R8..)
             * differs from context_data.integer field order (rax,rbx,rcx,rdx,
             * rbp,rsi,rdi,r8..; no rsp) — map each register explicitly. */
            wow->integer.x86_64_regs.rax = *(uint64_t *)(ctx + IOS_A64_RAX);
            wow->integer.x86_64_regs.rbx = *(uint64_t *)(ctx + IOS_A64_RBX);
            wow->integer.x86_64_regs.rcx = *(uint64_t *)(ctx + IOS_A64_RCX);
            wow->integer.x86_64_regs.rdx = *(uint64_t *)(ctx + IOS_A64_RDX);
            wow->integer.x86_64_regs.rbp = *(uint64_t *)(ctx + IOS_A64_RBP);
            wow->integer.x86_64_regs.rsi = *(uint64_t *)(ctx + IOS_A64_RSI);
            wow->integer.x86_64_regs.rdi = *(uint64_t *)(ctx + IOS_A64_RDI);
            wow->integer.x86_64_regs.r8  = *(uint64_t *)(ctx + IOS_A64_R8);
            wow->integer.x86_64_regs.r9  = *(uint64_t *)(ctx + IOS_A64_R9);
            wow->integer.x86_64_regs.r10 = *(uint64_t *)(ctx + IOS_A64_R10);
            wow->integer.x86_64_regs.r11 = *(uint64_t *)(ctx + IOS_A64_R11);
            wow->integer.x86_64_regs.r12 = *(uint64_t *)(ctx + IOS_A64_R12);
            wow->integer.x86_64_regs.r13 = *(uint64_t *)(ctx + IOS_A64_R13);
            wow->integer.x86_64_regs.r14 = *(uint64_t *)(ctx + IOS_A64_R14);
            wow->integer.x86_64_regs.r15 = *(uint64_t *)(ctx + IOS_A64_R15);
            wow->seg.x86_64_regs.ds = *(uint16_t *)(ctx + IOS_A64_SEGDS);
            wow->seg.x86_64_regs.es = *(uint16_t *)(ctx + IOS_A64_SEGES);
            wow->seg.x86_64_regs.fs = *(uint16_t *)(ctx + IOS_A64_SEGFS);
            wow->seg.x86_64_regs.gs = *(uint16_t *)(ctx + IOS_A64_SEGGS);
            memcpy( wow->fp.x86_64_regs.fpregs, ctx + IOS_A64_FLTSAVE,
                    sizeof(wow->fp.x86_64_regs.fpregs) );
        }
    }

    /* ml715: BOTH VIEWS OF THE SAME THREAD, SIDE BY SIDE.
     *
     * We capture a native ARM64 context AND the guest x86-64 context out of
     * TEB->ChpeV2CpuAreaInfo->ContextAmd64 -- but the ARM64EC NtGetContextThread wrapper
     * always asks for the NATIVE one and runs it through context_arm_to_x64(), which maps
     * Pc straight into Rip. For a translated thread parked in ordinary Mach-O code (e.g.
     * libsystem_kernel __ulock_wait2) that hands the caller a "RIP" that is a Mach-O
     * address and ARM ABI registers reinterpreted as x64 ones -- while the saved AMD64
     * view sitting right here holds the real guest RIP.
     *
     * That is the suspected Marvel Cosmic Invasion window blocker: Mono suspends a thread,
     * cannot classify the context it gets back, resumes, and retries forever while holding
     * the critical section its target needs. Pair this with the [ec-getctx] record on the
     * ntdll side; correlate on tid/teb + native pc, NOT on line order, because the two
     * counters live in different modules. Log-only, capped. */
    {
        static int n_ctx;
        if (n_ctx++ < 48)
            fprintf( stderr, "[srv-getctx] ml715 #%d tid=%04x teb=%p native_pc=%p native_sp=%p | "
                     "saved_amd64 flags=%08x rip=%p rsp=%p | have_native=%d\n",
                     n_ctx, thread->id, (void *)(uintptr_t)thread->teb,
                     (void *)(uintptr_t)(have_native ? native->ctl.arm64_regs.pc : 0),
                     (void *)(uintptr_t)(have_native ? native->ctl.arm64_regs.sp : 0),
                     wow ? wow->flags : 0,
                     (void *)(uintptr_t)(wow ? wow->ctl.x86_64_regs.rip : 0),
                     (void *)(uintptr_t)(wow ? wow->ctl.x86_64_regs.rsp : 0),
                     have_native );
    }

    /* ml730: if this capture IS the first logical suspend, keep the halt we
     * already have instead of resuming and re-suspending -- that window is
     * exactly where the target would leave its blocking region. A snapshot-only
     * capture (ios_pending_persistent_hold == NULL) resumes as it always did,
     * and never releases a hold established by an earlier suspend. */
    if (ios_pending_persistent_hold == thread && ios_real_suspend_enabled() &&
        rs_flag_ok( thread, "capture" ) && !thread->ios_mach_suspended)
    {
        thread->ios_mach_suspended = 1;   /* inherit THIS thread_suspend(): do not resume */
        rs_holds++;
    }
    else
    {
        /* Drop only the momentary halt taken at entry. If a persistent hold was
         * established earlier its own thread_suspend() is still outstanding, so
         * the target stays stopped -- Mach suspend counts nest. */
        thread_resume( port );
    }
    mach_port_deallocate( mach_task_self(), port );

    return have_native;
}
#endif  /* WINE_IOS */

/* read data from a process memory space */
int read_process_memory( struct process *process, client_ptr_t ptr, data_size_t size, char *dest )
{
    kern_return_t ret;
    mach_vm_size_t bytes_read;
    mach_port_t process_port = get_process_port( process );
#ifdef WINE_IOS
    /* iOS pseudo-processes share this task, but do not send task ports through
     * launchd. The request handler already checked PROCESS_VM_READ on the
     * target handle. Use our task only for a target registered in this Unix
     * process. Keep get_process_port() and write_process_memory() unchanged:
     * enabling writes as well previously regressed other applications. */
    if (!process_port && process->unix_pid == getpid())
    {
        /* ml1003: escape hatch. get_process_port()'s own comment records that a
         * previous, WIDER version of this change (returning mach_task_self()
         * there, activating reads AND writes) regressed Steam into a guest SEGV
         * plus loader-lock deadlock, with "some caller depends on the old
         * ACCESS_DENIED no-op". This change is reads-only and therefore not
         * that change -- but the warning touches this path too, and the file
         * knob makes a regression recoverable without a rebuild, on a device
         * where env vars are not reachable. Checked once. */
        static int local_read_off = -1;
        if (local_read_off < 0)
        {
            local_read_off = madeira_cfg_bool( "no-local-read", 0 );   /* ml1095: madeira.cfg no-local-read = 1 */
            fprintf( stderr, "ml1003: local pseudo-process reads %s\n",
                     local_read_off ? "DISABLED by no-local-read"
                                    : "ENABLED (reads only; writes still denied)" );
        }
        if (!local_read_off) process_port = mach_task_self();
    }
#endif

    if (!process_port)
    {
        set_error( STATUS_ACCESS_DENIED );
        return 0;
    }
    if ((mach_vm_address_t)ptr != ptr)
    {
        set_error( STATUS_ACCESS_DENIED );
        return 0;
    }

    ret = mach_vm_read_overwrite( process_port, (mach_vm_address_t)ptr, (mach_vm_size_t)size, (mach_vm_address_t)dest, &bytes_read );
    mach_set_error( ret );
    return (ret == KERN_SUCCESS);
}

/* write data to a process memory space */
int write_process_memory( struct process *process, client_ptr_t ptr, data_size_t size, const char *src,
                          data_size_t *written )
{
    kern_return_t ret;
    mach_port_t process_port = get_process_port( process );
    mach_vm_offset_t data;

#ifdef WINE_IOS
    /* Keep local writes disabled by default: enabling them globally regressed
     * Steam. Explicitly opt in only for pseudo-processes in this Unix task.
     * The request handler has already checked PROCESS_VM_WRITE rights. */
    const char *local_write = getenv( "MADEIRA_LOCAL_PROCESS_WRITE" );
    if (!process_port && process->unix_pid == getpid() && local_write &&
        !strcmp( local_write, "1" ))
        process_port = mach_task_self();
#endif

    if (written) *written = 0;

    if (!process_port)
    {
        set_error( STATUS_ACCESS_DENIED );
        return 0;
    }
    if ((mach_vm_address_t)ptr != ptr)
    {
        set_error( STATUS_ACCESS_DENIED );
        return 0;
    }
    if (posix_memalign( (void **)&data, get_page_size(), size ))
    {
        set_error( STATUS_NO_MEMORY );
        return 0;
    }

    memcpy( (void *)data, src, size );

    ret = mach_vm_write( process_port, (mach_vm_address_t)ptr, data, (mach_msg_type_number_t)size );

    /*
     * On arm64 macOS, enabling execute permission for a memory region automatically disables write
     * permission for that region. This can also happen under Rosetta sometimes.
     * In that case mach_vm_write returns KERN_INVALID_ADDRESS.
     */

    if (ret == KERN_INVALID_ADDRESS)
    {
        mach_vm_address_t current_address = (mach_vm_address_t)ptr;
        mach_vm_address_t region_address = current_address;
        mach_vm_size_t region_size, write_size;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object_name;
        data_size_t remaining_size = size;

        ret = mach_vm_region( process_port, &region_address, &region_size, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &info_count, &object_name );
        if (ret != KERN_SUCCESS)
            goto out;

        /*
         * Actually check that everything is sane before suspending.
         * KERN_INVALID_ADDRESS can also be returned when address is illegal or
         * specifies a non-allocated region.
         */
        if (region_address > current_address ||
            region_address + region_size <= current_address)
        {
            ret = KERN_INVALID_ADDRESS;
            goto out;
        }

        /*
         * FIXME: Rosetta can turn RWX pages into R-X pages during execution.
         * For now we will just have to ignore failures due to the wrong
         * protection here.
         */
        if (!is_rosetta() && !(info.protection & VM_PROT_WRITE))
        {
            ret = KERN_PROTECTION_FAILURE;
            goto out;
        }

        /* The following operations should seem atomic from the perspective of the
         * target process. */
        if ((ret = task_suspend( process_port )) != KERN_SUCCESS)
            goto out;

        /* Iterate over all applicable memory regions until the write is completed. */
        while (remaining_size)
        {
            region_address = current_address;
            info_count = VM_REGION_BASIC_INFO_COUNT_64;
            ret = mach_vm_region( process_port, &region_address, &region_size, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &info_count, &object_name );
            if (ret != KERN_SUCCESS) break;

            if (region_address > current_address ||
                region_address + region_size <= current_address)
            {
                ret = KERN_INVALID_ADDRESS;
                break;
            }

            /* FIXME: See the above Rosetta remark. */
            if (!is_rosetta() && !(info.protection & VM_PROT_WRITE))
            {
                ret = KERN_PROTECTION_FAILURE;
                break;
            }

            write_size = region_size - (current_address - region_address);
            if (write_size > remaining_size) write_size = remaining_size;

            ret = mach_vm_protect( process_port, current_address, write_size, 0,
                    VM_PROT_READ | VM_PROT_WRITE );
            if (ret != KERN_SUCCESS) break;

            ret = mach_vm_write( process_port, current_address,
                    data + (current_address - (mach_vm_address_t)ptr), write_size );
            if (ret != KERN_SUCCESS) break;

            ret = mach_vm_protect( process_port, current_address, write_size, 0,
                    info.protection );
            if (ret != KERN_SUCCESS) break;

            if (written) *written += write_size;
            current_address       += write_size;
            remaining_size        -= write_size;
        }

        task_resume( process_port );
    }

out:
    free( (void *)data );
    mach_set_error( ret );
    if (ret == KERN_SUCCESS && written) *written = size;
    return (ret == KERN_SUCCESS);
}

#endif  /* USE_MACH */
