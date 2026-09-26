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
#include <stdlib.h>
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
 * pc 100, cpsr 108, restore_flags 10c; sizeof == 0x330. */
#define IOS_SCF_FP    0x0e8
#define IOS_SCF_LR    0x0f0
#define IOS_SCF_SP    0x0f8
#define IOS_SCF_PC    0x100
#define IOS_SCF_CPSR  0x108
#define IOS_SCF_RESTORE_FLAGS 0x10c
#define IOS_SCF_SIZE  0x330
/* CONTEXT_ARM64 | CONTEXT_ARM64_CONTROL. Spelled out rather than taken from
 * winnt.h: this file is built for the host and the value it needs is the one the
 * syscall dispatcher tests, which is fixed by that asm, not by a header. */
#define IOS_CTX_ARM64_CONTROL 0x00400001u
#define IOS_CPUAREA_CTX64_OFF      0x18     /* CHPE_V2_CPU_AREA_INFO.ContextAmd64 */
/* rest of CHPE_V2_CPU_AREA_INFO (winternl.h:351): InSimulation 000,
 * InSyscallCallback 001, EmulatorStackBase 008, EmulatorStackLimit 010,
 * ContextAmd64 018, SuspendDoorbell 020, ..., EmulatorData[0] 030. */
#define IOS_CPUAREA_INSIM          0x00
#define IOS_CPUAREA_EMUSTACK_BASE  0x08
#define IOS_CPUAREA_EMUSTACK_LIMIT 0x10
#define IOS_CPUAREA_EMUDATA0       0x30
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
    static int env = -1;
    if (env < 0)
    {
        const char *e = getenv( "MADEIRA_REAL_SUSPEND" );
        env = (e && e[0] == '1') ? 1 : 0;
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

/* Set by suspend_thread() around its stop_thread() call so the capture below
 * can convert its momentary halt into the persistent hold without ever
 * resuming in between. Snapshot-only callers leave it NULL. */
struct thread *ios_pending_persistent_hold;

/* ================= ml1030 A CONTEXT THAT IS CURRENT =================
 *
 * THE DEFECT THIS FILE'S HALF OF THE FIX ADDRESSES. stop_thread() (server
 * thread.c) returns early whenever thread->context already exists, and on iOS
 * NOTHING ever frees it: the only two release sites are the select
 * suspend-context handback (which needs thread->suspend_cookie, set only from
 * wait_suspend(), which needs the SIGUSR1 suspend that is dead here) and thread
 * death.  So the Mach snapshot taken at a thread's FIRST suspend is what every
 * later GetThreadContext on that thread returns, for the rest of the session.
 *
 * MEASURED, not inferred.  In the tablet log the `[srv-getctx]' probe -- whose
 * cap was 48 -- printed exactly 40 lines, one per thread, all during bring-up
 * and all before file line 5820.  The three ten-second windows at lines 5889,
 * 6272 and 6773 report `suspend_thread=80/120/80 get_thread_context=80/120/80
 * resume_thread=80/120/80' per window.  280 context reads, zero captures.
 * Every one of those 280 replies was the bring-up snapshot, byte for byte.
 *
 * A caller that samples a thread to decide whether it may proceed -- any
 * stop-the-world, any hang watchdog, any profiler -- cannot ever see the
 * thread move, so it retries forever.  That is the whole mechanism.
 *
 * ios_thread_context_stale() is the counterpart: stop_thread() calls it to
 * re-capture into the context it already has instead of returning it as-is.
 * MADEIRA_CTX_REFRESH=0 restores the pre-ml1030 behaviour exactly. */
int ios_ctx_refresh_enabled(void)
{
    static int env = -1;
    if (env < 0)
    {
        const char *e = getenv( "MADEIRA_CTX_REFRESH" );
        env = (e && e[0] == '0') ? 0 : 1;
        fprintf( stderr, "[srv-getctx] ml1030 MADEIRA_CTX_REFRESH=%d (0 = replay the first "
                 "snapshot forever, the pre-ml1030 behaviour)\n", env );
    }
    return env;
}

/* ml1030: WHERE THE TARGET ACTUALLY IS, in the four terms that change the
 * answer.  Every one of these is a same-task read; nothing is inferred from
 * the program counter's numeric band, which has been wrong here before. */
enum ios_ctx_state
{
    IOS_CTX_UNKNOWN,   /* no TEB / no CPU area: a thread wine does not manage */
    IOS_CTX_SYSCALL,   /* inside a wine unix call (sp on the kernel stack)    */
    IOS_CTX_EMUSTACK,  /* on the emulator stack: FEX dispatcher / runtime C++ */
    IOS_CTX_JIT,       /* InSimulation set: executing emitted guest code      */
    IOS_CTX_NATIVE,    /* genuine EC / native code, not in any of the above   */
};

static const char *ios_ctx_state_name( enum ios_ctx_state s )
{
    switch (s)
    {
    case IOS_CTX_SYSCALL:  return "unix-call";
    case IOS_CTX_EMUSTACK: return "fex-runtime";
    case IOS_CTX_JIT:      return "in-JIT";
    case IOS_CTX_NATIVE:   return "native/EC";
    default:               return "unknown";
    }
}

/* frame/kstack are returned so the capture below does not read them twice. */
static enum ios_ctx_state ios_ctx_classify( struct thread *thread, uint64_t sp,
                                            uint64_t *frame_out, uint64_t *kstack_out )
{
    uint64_t frame = 0, kstack = 0, cpuarea = 0, base = 0, limit = 0;
    unsigned char insim = 0;
    enum ios_ctx_state state = IOS_CTX_UNKNOWN;

    if (frame_out) *frame_out = 0;
    if (kstack_out) *kstack_out = 0;
    if (!thread->teb) return IOS_CTX_UNKNOWN;

    if (ios_safe_read( (uint64_t)thread->teb + IOS_TEB_SYSCALL_FRAME_OFF, &frame, 8 ) &&
        ios_safe_read( (uint64_t)thread->teb + IOS_TEB_KERNEL_STACK_OFF, &kstack, 8 ) &&
        frame && kstack && !(frame & 7) && kstack < frame)
    {
        if (frame_out) *frame_out = frame;
        if (kstack_out) *kstack_out = kstack;
        /* exactly is_inside_syscall() (unix_private.h:454) */
        if (sp >= kstack && sp <= frame) return IOS_CTX_SYSCALL;
        state = IOS_CTX_NATIVE;
    }

    if (ios_safe_read( (uint64_t)thread->teb + IOS_TEB_CHPE_CPUAREA_OFF, &cpuarea, 8 ) && cpuarea)
    {
        if (ios_safe_read( cpuarea + IOS_CPUAREA_EMUSTACK_BASE, &base, 8 ) &&
            ios_safe_read( cpuarea + IOS_CPUAREA_EMUSTACK_LIMIT, &limit, 8 ) &&
            base && limit && sp <= base && sp >= limit)
            return IOS_CTX_EMUSTACK;
        if (ios_safe_read( cpuarea + IOS_CPUAREA_INSIM, &insim, 1 ) && insim)
            return IOS_CTX_JIT;
        if (state == IOS_CTX_UNKNOWN) state = IOS_CTX_NATIVE;
    }
    return state;
}

/* ml1030: THE STOP-THE-WORLD LOOP DETECTOR.
 *
 * One line, at most one per target per ten seconds, when a single caller has
 * suspended + read the context of + resumed the same target more than
 * MADEIRA_STW_THRESHOLD (default 50) times inside one ten-second window.  It
 * carries the three most recent {Pc,Sp} pairs, because the decisive question
 * -- is the caller being shown a thread that never moves? -- is answered by
 * whether those three are equal, and by nothing else.
 *
 * The pairs printed are the NATIVE Pc/Sp after any substitution, i.e. exactly
 * what context_arm_to_x64() will hand the caller as Rip/Rsp unless the ml980
 * emulated-view substitution fires on top (which it only does for in-JIT
 * targets, and the state field says when that is).
 *
 * Fixed 8-slot table, no allocation, oldest-wins eviction: this runs inside the
 * server's request path and must never become the thing being measured. */
#define IOS_STW_SLOTS 8
static struct
{
    unsigned int  tid, caller;
    unsigned int  n_get, n_susp, n_res;
    timeout_t     window_start;
    int           reported;
    unsigned int  n_pc;
    uint64_t      pc[3], sp[3];
    enum ios_ctx_state state;
} ios_stw[IOS_STW_SLOTS];
static unsigned int ios_stw_rr;

static unsigned int ios_stw_threshold(void)
{
    static int env = -1;
    if (env < 0)
    {
        const char *e = getenv( "MADEIRA_STW_THRESHOLD" );
        env = e ? atoi( e ) : 50;
        if (env < 0) env = 0;
    }
    return (unsigned int)env;
}

/* window: 10 s in server ticks (100 ns units), matching [srv-stats]. */
#define IOS_STW_WINDOW ((timeout_t)10 * 10000000)

static int ios_stw_slot( unsigned int tid, unsigned int caller )
{
    int i, free_slot = -1;
    for (i = 0; i < IOS_STW_SLOTS; i++)
    {
        if (ios_stw[i].tid == tid && ios_stw[i].caller == caller) return i;
        if (!ios_stw[i].tid && free_slot < 0) free_slot = i;
    }
    if (free_slot < 0)
    {
        free_slot = (int)(ios_stw_rr++ % IOS_STW_SLOTS);
        memset( &ios_stw[free_slot], 0, sizeof(ios_stw[0]) );
    }
    ios_stw[free_slot].tid = tid;
    ios_stw[free_slot].caller = caller;
    ios_stw[free_slot].window_start = current_time;
    return free_slot;
}

/* kind: 0 = context read (carries pc/sp/state), 1 = suspend, 2 = resume. */
void ios_stw_note( struct thread *thread, int kind, uint64_t pc, uint64_t sp,
                   int state )
{
    unsigned int caller = current ? current->id : 0;
    int i;

    if (!thread || !caller || caller == thread->id) return;   /* self is never a loop */
    if (!ios_stw_threshold()) return;

    i = ios_stw_slot( thread->id, caller );
    if (current_time - ios_stw[i].window_start > IOS_STW_WINDOW)
    {
        unsigned int tid = ios_stw[i].tid, c = ios_stw[i].caller;
        memset( &ios_stw[i], 0, sizeof(ios_stw[0]) );
        ios_stw[i].tid = tid;
        ios_stw[i].caller = c;
        ios_stw[i].window_start = current_time;
    }

    switch (kind)
    {
    case 1: ios_stw[i].n_susp++; return;
    case 2: ios_stw[i].n_res++;  return;
    default: break;
    }

    ios_stw[i].n_get++;
    ios_stw[i].state = (enum ios_ctx_state)state;
    ios_stw[i].pc[ios_stw[i].n_pc % 3] = pc;
    ios_stw[i].sp[ios_stw[i].n_pc % 3] = sp;
    ios_stw[i].n_pc++;

    if (ios_stw[i].reported || ios_stw[i].n_get <= ios_stw_threshold() ||
        !ios_stw[i].n_susp || !ios_stw[i].n_res || ios_stw[i].n_pc < 3)
        return;

    {
        unsigned int a = (ios_stw[i].n_pc - 3) % 3;
        unsigned int b = (ios_stw[i].n_pc - 2) % 3;
        unsigned int c = (ios_stw[i].n_pc - 1) % 3;
        int frozen = (ios_stw[i].pc[a] == ios_stw[i].pc[b] && ios_stw[i].pc[b] == ios_stw[i].pc[c] &&
                      ios_stw[i].sp[a] == ios_stw[i].sp[b] && ios_stw[i].sp[b] == ios_stw[i].sp[c]);

        ios_stw[i].reported = 1;
        fprintf( stderr, "[stw-loop] ml1030 tid=%04x sampled by tid=%04x %u times in 10 s "
                 "(susp=%u res=%u) state=%s last3={%p,%p} {%p,%p} {%p,%p} %s\n",
                 ios_stw[i].tid, ios_stw[i].caller, ios_stw[i].n_get,
                 ios_stw[i].n_susp, ios_stw[i].n_res,
                 ios_ctx_state_name( ios_stw[i].state ),
                 (void *)(uintptr_t)ios_stw[i].pc[a], (void *)(uintptr_t)ios_stw[i].sp[a],
                 (void *)(uintptr_t)ios_stw[i].pc[b], (void *)(uintptr_t)ios_stw[i].sp[b],
                 (void *)(uintptr_t)ios_stw[i].pc[c], (void *)(uintptr_t)ios_stw[i].sp[c],
                 frozen ? "-- IDENTICAL: the caller is being shown a thread that never moves"
                        : "-- advancing: the samples differ, this is a slow retry, not a frozen one" );
    }
}

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
    enum ios_ctx_state cap_state = IOS_CTX_UNKNOWN;
    /* ml1030: deferred diagnostics -- nothing prints while the target is halted. */
    unsigned int sub_n = 0;
    uint64_t sub_mach_pc = 0, sub_sp = 0, sub_frame = 0, sub_fpc = 0, sub_fsp = 0;
    uint64_t cap_pc = 0, cap_sp = 0;

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
        /* Classified from the LIVE sp, before any substitution rewrites it. */
        cap_state = ios_ctx_classify( thread, arm.__sp, NULL, NULL );
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
     * ml1030: DEFAULT ON. It was opt-in while unproven, and the consequence is that it has
     * never executed: `[ctx-frame]' appears ZERO times in every device log, including both
     * of the two-device stop-the-world logs, while `[ec-getctx]' reports is_ec=0 with a
     * libsystem_kernel address as the returned Rip in 48 samples out of 48. Those 48 are
     * precisely the case this substitution exists for. MADEIRA_CTX_FRAME=0 restores the
     * raw Mach registers. Every validation failure still falls through to the old
     * behaviour rather than inventing state. */
    if (have_native)
    {
        static int ctx_frame_env = -1;
        if (ctx_frame_env < 0)
        {
            const char *e = getenv( "MADEIRA_CTX_FRAME" );
            ctx_frame_env = (e && e[0] == '0') ? 0 : 1;
            fprintf( stderr, "[ctx-frame] ml1030 MADEIRA_CTX_FRAME=%d (0 = report the raw Mach "
                     "registers of a thread parked inside a unix call)\n", ctx_frame_env );
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
                        static unsigned int n_sub;
                        for (i = 0; i < 29; i++)
                            native->integer.arm64_regs.x[i] = *(uint64_t *)(f + i * 8);
                        native->integer.arm64_regs.x[29] = *(uint64_t *)(f + IOS_SCF_FP);
                        native->integer.arm64_regs.x[30] = *(uint64_t *)(f + IOS_SCF_LR);
                        native->ctl.arm64_regs.sp     = fsp;
                        native->ctl.arm64_regs.pc     = fpc;
                        native->ctl.arm64_regs.pstate = *(uint32_t *)(f + IOS_SCF_CPSR);
                        /* ml1030: SAMPLED, not capped. A hard cap on this line is what made
                         * `[srv-getctx]' unable to answer the only question that mattered --
                         * it went silent 60 lines before the event. First 8, then powers of
                         * two, forever. Deferred past thread_resume() with everything else
                         * that touches stdio -- see the [srv-getctx] block below. */
                        n_sub++;
                        if (n_sub <= 8 || !(n_sub & (n_sub - 1)))
                        {
                            sub_n = n_sub;
                            sub_mach_pc = mach_pc; sub_sp = sp;
                            sub_frame = frame; sub_fpc = fpc; sub_fsp = fsp;
                        }
                    }
                }
            }
        }
    }

    /* --- guest x86-64 context from TEB->ChpeV2CpuAreaInfo->ContextAmd64 --- */
    if (wow)
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
     * counters live in different modules. Log-only.
     *
     * ml1030: SAMPLED (first 8, then powers of two), not capped at 48. The cap is what
     * made the tablet log unable to answer its own question: it printed 40 lines, one per
     * thread, all at bring-up, and the three stop-the-world windows that followed produced
     * 280 get_thread_context replies and not one more line -- which reads identically to
     * "the probe ran out of budget" and is in fact "no capture happened at all". The line
     * now also carries the target's STATE and the running capture count, so "captures ==
     * reads" is checkable from the log instead of inferred.
     *
     * ml1030 also MOVED IT OUT OF THE SUSPENDED WINDOW. fprintf takes the stderr
     * FILE lock and can allocate; doing that while a thread of the same task is
     * Mach-halted is the exact deadlock ml730 keeps real suspension opt-in for.
     * The values are captured here and printed after thread_resume(). */
    cap_pc = have_native ? native->ctl.arm64_regs.pc : 0;
    cap_sp = have_native ? native->ctl.arm64_regs.sp : 0;

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

    /* Target is running again: only now is it safe to touch stdio. */
    if (sub_n)
        fprintf( stderr, "[ctx-frame] ml716 #%u tid=%04x source=syscall-frame "
                 "mach_pc=%p sp=%p inside_syscall=1 frame=%p frame_pc=%p frame_sp=%p\n",
                 sub_n, thread->id, (void *)(uintptr_t)sub_mach_pc,
                 (void *)(uintptr_t)sub_sp, (void *)(uintptr_t)sub_frame,
                 (void *)(uintptr_t)sub_fpc, (void *)(uintptr_t)sub_fsp );
    {
        static unsigned int n_ctx;
        n_ctx++;
        if (n_ctx <= 8 || !(n_ctx & (n_ctx - 1)))
            fprintf( stderr, "[srv-getctx] ml715 #%u tid=%04x teb=%p pc=%p sp=%p state=%s | "
                     "saved_amd64 flags=%08x rip=%p rsp=%p | have_native=%d\n",
                     n_ctx, thread->id, (void *)(uintptr_t)thread->teb,
                     (void *)(uintptr_t)cap_pc, (void *)(uintptr_t)cap_sp,
                     ios_ctx_state_name( cap_state ),
                     wow ? wow->flags : 0,
                     (void *)(uintptr_t)(wow ? wow->ctl.x86_64_regs.rip : 0),
                     (void *)(uintptr_t)(wow ? wow->ctl.x86_64_regs.rsp : 0),
                     have_native );
    }
    ios_stw_note( thread, 0, cap_pc, cap_sp, (int)cap_state );

    return have_native;
}

/* ml1030: THE SET SIDE, WHICH HAD NO IMPLEMENTATION AT ALL.
 *
 * A cross-thread NtSetContextThread on this port wrote the incoming registers
 * into the SERVER-SIDE cached `struct context' and stopped there. The only code
 * that ever applies a cached context to a thread is the select suspend handback
 * (thread.c: the `current->suspend_cookie == req->cookie' branch), which needs
 * wait_suspend(), which needs the SIGUSR1 suspend that does not exist here. So
 * every cross-thread SetThreadContext was a silent no-op that RETURNED SUCCESS,
 * and -- before ml1030 refreshed the cache -- a following GetThreadContext read
 * the write back out of the cache and made the no-op look like it had worked.
 * That is the worst possible shape: a caller cannot even detect it.
 *
 * WHAT CAN BE DONE HONESTLY, AND WHAT CANNOT.
 *
 *   target inside a unix call  -> write the SYSCALL FRAME. This is what the
 *       thread's own registers will be restored from when the call returns, it
 *       is exactly the state ml716 reads on the Get side, and it is the same
 *       thing Windows means by setting the context of a thread in a system
 *       call. Done here.
 *   target genuinely Mach-halted (MADEIRA_REAL_SUSPEND) and in user code
 *       -> thread_set_state() is correct and atomic. Done here.
 *   target RUNNING in JIT / EC / native code -> there is no safe answer. The
 *       thread would have to be stopped first, and with real suspend off it is
 *       not. REFUSED with STATUS_UNSUCCESSFUL and reported, rather than
 *       pretending. A caller that checks its return value now learns the truth.
 *
 * The frame write is bracketed by its own thread_suspend()/thread_resume() and
 * re-validates `is_inside_syscall' WHILE HALTED, so the frame cannot be torn by
 * a dispatcher return racing the store. MADEIRA_CTX_SET=0 restores the old
 * write-into-the-cache-and-hope behaviour.
 *
 * Returns 1 when the context was applied to the thread, 0 when it was not
 * (caller decides whether that is an error). */
int ios_ctx_set_enabled(void)
{
    static int env = -1;
    if (env < 0)
    {
        const char *e = getenv( "MADEIRA_CTX_SET" );
        env = (e && e[0] == '0') ? 0 : 1;
        fprintf( stderr, "[srv-setctx] ml1030 MADEIRA_CTX_SET=%d (0 = cross-thread "
                 "SetThreadContext stays the silent no-op it has always been)\n", env );
    }
    return env;
}

/* ml1330: a thread created suspended reports its own start context (see
 * stop_thread() in thread.c). MADEIRA_CTX_START_WAIT=0 restores the immediate
 * Mach snapshot of a thread that has not finished starting. */
int ios_ctx_start_wait_enabled(void)
{
    static int env = -1;
    if (env < 0)
    {
        const char *e = getenv( "MADEIRA_CTX_START_WAIT" );
        env = (e && e[0] == '0') ? 0 : 1;
        fprintf( stderr, "[ctx-start] ml1330 MADEIRA_CTX_START_WAIT=%d (0 = snapshot a thread "
                 "that is still starting)\n", env );
    }
    return env;
}

int ios_apply_thread_context( struct thread *thread, const struct context_data *native )
{
    mach_msg_type_name_t type;
    mach_port_t port;
    arm_thread_state64_t arm;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    uint64_t frame = 0, kstack = 0;
    enum ios_ctx_state state = IOS_CTX_UNKNOWN;
    static unsigned int n_set, n_refuse;
    int applied = 0;

    if (!ios_ctx_set_enabled()) return 0;
    if (!native || !(native->flags & SERVER_CTX_CONTROL)) return 0;
    if (thread->unix_pid == -1 || thread->unix_tid == (unsigned int)-1) return 0;
    if (mach_port_extract_right( mach_task_self(), thread->unix_tid,
                                 MACH_MSG_TYPE_COPY_SEND, &port, &type ))
        return 0;

    /* Momentary halt: nests with any persistent ml730 hold. */
    if (thread_suspend( port )) { mach_port_deallocate( mach_task_self(), port ); return 0; }

    if (thread_get_state( port, ARM_THREAD_STATE64, (thread_state_t)&arm, &count ))
        goto done;

    state = ios_ctx_classify( thread, arm.__sp, &frame, &kstack );

    if (state == IOS_CTX_SYSCALL && frame)
    {
        unsigned char f[IOS_SCF_SIZE];
        if (ios_safe_read( frame, f, sizeof(f) ))
        {
            unsigned int i;

            /* MIRRORS NtSetContextThread's OWN in-syscall write, byte for byte
             * (build/ntdll-unix/signal_arm64_ios.c, the `self' path). Two details
             * of that write are load-bearing and neither is obvious:
             *
             *  - x18 IS SKIPPED. It is the TEB pointer, the dispatcher's return
             *    path reloads it from frame->x[18] UNCONDITIONALLY ("ldp x18, x19,
             *    [sp, #0x90]"), and an x64 CONTEXT has no field for it -- so
             *    context_x64_to_arm() puts a ZERO there. Copying the whole array
             *    would hand the thread a null TEB on its way out of the syscall.
             *  - restore_flags must be set, because that word is what tells the
             *    return path to take the slow restore at all. CONTEXT_INTEGER is
             *    deliberately NOT set, exactly as the self path does it. */
            if (native->flags & SERVER_CTX_INTEGER)
            {
                for (i = 0; i < 18; i++)
                    *(uint64_t *)(f + i * 8) = native->integer.arm64_regs.x[i];
                for (i = 19; i < 29; i++)
                    *(uint64_t *)(f + i * 8) = native->integer.arm64_regs.x[i];
                *(uint64_t *)(f + IOS_SCF_FP) = native->integer.arm64_regs.x[29];
                *(uint64_t *)(f + IOS_SCF_LR) = native->integer.arm64_regs.x[30];
            }
            *(uint64_t *)(f + IOS_SCF_SP)   = native->ctl.arm64_regs.sp;
            *(uint64_t *)(f + IOS_SCF_PC)   = native->ctl.arm64_regs.pc;
            *(uint32_t *)(f + IOS_SCF_CPSR) = native->ctl.arm64_regs.pstate;
            *(uint32_t *)(f + IOS_SCF_RESTORE_FLAGS) |= IOS_CTX_ARM64_CONTROL;

            /* One write of the whole frame, and the target cannot be returning
             * from its syscall while it happens: `state' was established from the
             * sp of a thread that is Mach-halted and stays halted until `done:'.
             * That is the entire reason for the halt -- without it the dispatcher
             * could be restoring from this frame mid-store. */
            if (!mach_vm_write( mach_task_self(), (mach_vm_address_t)frame,
                                (vm_offset_t)f, (mach_msg_type_number_t)sizeof(f) ))
                applied = 1;
        }
    }
    else if (thread->ios_mach_suspended && ios_real_suspend_enabled())
    {
        unsigned int i;
        if (native->flags & SERVER_CTX_INTEGER)
        {
            /* x18 skipped for the same reason as the frame path above: an x64
             * CONTEXT cannot carry it, so the zero that arrives in one is the
             * mapping's hole, never the caller's intent. */
            for (i = 0; i < 29; i++)
                if (i != 18) arm.__x[i] = native->integer.arm64_regs.x[i];
            arm.__fp = native->integer.arm64_regs.x[29];
            arm.__lr = native->integer.arm64_regs.x[30];
        }
        arm.__sp   = native->ctl.arm64_regs.sp;
        arm.__pc   = native->ctl.arm64_regs.pc;
        arm.__cpsr = native->ctl.arm64_regs.pstate;
        if (!thread_set_state( port, ARM_THREAD_STATE64, (thread_state_t)&arm,
                               ARM_THREAD_STATE64_COUNT ))
            applied = 2;                       /* 2 = via the live Mach state */
    }

done:
    thread_resume( port );
    mach_port_deallocate( mach_task_self(), port );

    /* Target is running again: nothing above this line touches stdio. */
    if (applied)
    {
        n_set++;
        if (n_set <= 8 || !(n_set & (n_set - 1)))
            fprintf( stderr, "[srv-setctx] ml1030 #%u tid=%04x by=%04x target=%s state=%s "
                     "frame=%p pc=%p sp=%p\n", n_set, thread->id,
                     current ? current->id : 0,
                     applied == 2 ? "mach-state" : "syscall-frame",
                     ios_ctx_state_name( state ), (void *)(uintptr_t)frame,
                     (void *)(uintptr_t)native->ctl.arm64_regs.pc,
                     (void *)(uintptr_t)native->ctl.arm64_regs.sp );
    }
    else
    {
        n_refuse++;
        if (n_refuse <= 8 || !(n_refuse & (n_refuse - 1)))
            fprintf( stderr, "[srv-setctx] ml1030 REFUSED #%u tid=%04x by=%04x state=%s "
                     "held=%d -- the target is running and not inside a unix call, so there "
                     "is no frame to write and no halt to write through "
                     "(MADEIRA_REAL_SUSPEND=1 makes this case reachable)\n",
                     n_refuse, thread->id, current ? current->id : 0,
                     ios_ctx_state_name( state ), thread->ios_mach_suspended );
    }
    return applied;
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

#ifdef WINE_IOS
/* ml972: WriteProcessMemory ON A TARGET THAT IS IN OUR OWN MACH TASK.
 *
 * NtWriteVirtualMemory has no current-process shortcut: every write, including
 * WriteProcessMemory(GetCurrentProcess(), ...), becomes a write_process_memory
 * request.  And write_process_memory needs get_process_port(), which on this
 * port returns process->trace_data -- always 0, because there is no per-guest
 * Mach task to hold a port for.  So EVERY WriteProcessMemory on this target
 * failed at the first `if (!process_port)' with STATUS_ACCESS_DENIED, which is
 * the `err=5 put=0' readvm-x86.exe reports for its PAGE_EXECUTE_READ case (and
 * would report for a plain PAGE_READWRITE one, which nothing covered).
 *
 * get_process_port() cannot simply return mach_task_self(): its own comment
 * records that doing so ALSO activates read_process_memory and regressed a
 * guest into a SEGV plus a loader-lock deadlock.  It does not need to be
 * changed.  The wineserver is a thread in the same task as every guest thread,
 * so for a target in the CALLER's own process the addresses in the request are
 * already valid pointers here, and the write is a store, not an IPC.
 *
 * Only the caller's own process is handled: a 32-bit guest's address was
 * translated into a host pointer by the WOW64 thunk using the CALLING
 * process's 4 GB window, so the same number means a different byte in another
 * pseudo-process.  Cross-process writes therefore keep exactly the behaviour
 * they have today (the port-based path below, i.e. STATUS_ACCESS_DENIED) --
 * this change can only turn a failure into a success, never the reverse.
 *
 * THE PROTECTION LADDER, AND WHY IT IS IN THIS ORDER.
 *
 * kernelbase's WriteProcessMemory already asks NtProtectVirtualMemory for
 * PAGE_EXECUTE_READWRITE before it gets here (dlls/kernelbase/memory.c:644),
 * but on iOS that does not mean the page is writable: TXM refuses to grant
 * execute through mprotect at all, so virtual_ios.c's mprotect_exec() either
 * left the page R-X from an earlier grant, or owns it through the dual-mapped
 * JIT pool where the executable view is RX and a separate RW alias maps the
 * same physical pages.  Hence:
 *
 *   1. region already writable          -> plain store.  This is the ONLY
 *      correct answer for a MAP_SHARED section view: vm_protect(...COPY)
 *      would privatise it and every other pseudo-process would keep reading
 *      the old bytes.
 *   2. a live dual-map RW alias covers it -> store through the alias.  No
 *      protection change at all, so the executable view never loses execute --
 *      which matters because on iOS taking VM_PROT_EXECUTE away can be a
 *      one-way trip.  This is the same mechanism the SIGBUS store emulator in
 *      signal_arm64_ios.c uses for guest stores into an execute-only alias;
 *      the lookup is weak so this file still links if that unit is absent.
 *   3. vm_protect( current | WRITE )    -> keeps EXECUTE in the request, so on
 *      a device that grants RWX nothing is ever dropped.
 *   4. vm_protect( READ | WRITE ), then  5. ( READ | WRITE | COPY ) -- the same
 *      ladder, for the same reasons, as mprotect_exec()'s RW path
 *      (virtual_ios.c:9636): plain first so shared mappings stay shared, COPY
 *      only for a mapping whose maxprot has no WRITE (a code-signed file).
 *      Both restore the region's original protection afterwards, and a failure
 *      to restore EXECUTE is logged rather than swallowed: the bytes did land,
 *      but the page is no longer executable and the next call through it will
 *      fault somewhere far away from here.
 *   6. nothing worked -> KERN_PROTECTION_FAILURE, i.e. STATUS_ACCESS_DENIED,
 *      which is what a page that genuinely cannot be written should give.
 *
 * PAGE_READONLY is NOT special-cased here and does not need to be: Wine
 * refuses it one level up, in WriteProcessMemory's `default:' arm, and never
 * sends the request.  A debugger-style NtWriteVirtualMemory straight to a
 * read-only page is the case upstream's Mach path also lets through once the
 * mapping permits it.
 */
extern uintptr_t ios_jit_anon_alias_lookup( uintptr_t addr ) __attribute__((weak));

static int ios_write_own_task( client_ptr_t ptr, data_size_t size, const char *src,
                               data_size_t *written )
{
    mach_vm_address_t addr = (mach_vm_address_t)ptr;
    mach_vm_size_t    page = (mach_vm_size_t)get_page_size();
    data_size_t       remaining = size;
    kern_return_t     ret = KERN_SUCCESS;

    while (remaining)
    {
        mach_vm_address_t region = addr, prot_base = 0;
        mach_vm_size_t    region_size = 0, chunk, prot_size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object_name = MACH_PORT_NULL;
        char *dst = NULL;
        int reprotect = 0;

        ret = mach_vm_region( mach_task_self(), &region, &region_size, VM_REGION_BASIC_INFO_64,
                              (vm_region_info_t)&info, &count, &object_name );
        if (ret != KERN_SUCCESS) break;
        /* mach_vm_region returns the next region at or ABOVE the address, so a
         * hole is "the region I got back starts past me". */
        if (region > addr || region + region_size <= addr)
        {
            ret = KERN_INVALID_ADDRESS;
            break;
        }

        chunk = region + region_size - addr;
        if (chunk > remaining) chunk = remaining;

        /* A region with no access at all is a guard page or a reservation, not
         * something a protection change should quietly open up.  Windows says
         * ACCESS_VIOLATION for PAGE_NOACCESS and so do we. */
        if (info.protection == VM_PROT_NONE)
        {
            ret = KERN_PROTECTION_FAILURE;
            break;
        }

        if (info.protection & VM_PROT_WRITE) dst = (char *)(uintptr_t)addr;        /* 1 */
        else if (ios_jit_anon_alias_lookup)                                        /* 2 */
        {
            uintptr_t rw = ios_jit_anon_alias_lookup( (uintptr_t)addr );
            /* the alias must cover the whole chunk linearly, or the tail would
             * land in another mapping: check the last byte resolves to the
             * matching offset of the same alias. */
            if (rw && ios_jit_anon_alias_lookup( (uintptr_t)(addr + chunk - 1) ) == rw + chunk - 1)
                dst = (char *)rw;
        }

        if (!dst)
        {
            prot_base = addr & ~(page - 1);
            prot_size = ((addr + chunk + page - 1) & ~(page - 1)) - prot_base;

            ret = mach_vm_protect( mach_task_self(), prot_base, prot_size, FALSE,   /* 3 */
                                   info.protection | VM_PROT_WRITE );
            if (ret != KERN_SUCCESS)
                ret = mach_vm_protect( mach_task_self(), prot_base, prot_size, FALSE,  /* 4 */
                                       VM_PROT_READ | VM_PROT_WRITE );
            if (ret != KERN_SUCCESS)
                ret = mach_vm_protect( mach_task_self(), prot_base, prot_size, FALSE,  /* 5 */
                                       VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY );
            if (ret != KERN_SUCCESS)                                                   /* 6 */
            {
                ret = KERN_PROTECTION_FAILURE;
                break;
            }
            reprotect = 1;
            dst = (char *)(uintptr_t)addr;
        }

        memcpy( dst, src, (size_t)chunk );

        if (reprotect)
        {
            kern_return_t back = mach_vm_protect( mach_task_self(), prot_base, prot_size,
                                                  FALSE, info.protection );
            if (back != KERN_SUCCESS)
                fprintf( stderr, "[srv-wpm] ml972 could NOT restore prot 0x%x on 0x%llx+0x%llx "
                         "(kr=%d) -- the write landed, the page did not go back%s\n",
                         info.protection, (unsigned long long)prot_base,
                         (unsigned long long)prot_size, back,
                         (info.protection & VM_PROT_EXECUTE) ? " AND IT WAS EXECUTABLE" : "" );
        }

        if (written) *written += (data_size_t)chunk;
        addr      += chunk;
        src       += chunk;
        remaining -= (data_size_t)chunk;
    }

    mach_set_error( ret );
    return (ret == KERN_SUCCESS);
}
#endif  /* WINE_IOS */

/* write data to a process memory space */
int write_process_memory( struct process *process, client_ptr_t ptr, data_size_t size, const char *src,
                          data_size_t *written )
{
    kern_return_t ret;
    mach_port_t process_port = get_process_port( process );
    mach_vm_offset_t data;

    if (written) *written = 0;

#ifdef WINE_IOS
    if ((mach_vm_address_t)ptr == ptr && size && current && current->process == process)
        return ios_write_own_task( ptr, size, src, written );
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
