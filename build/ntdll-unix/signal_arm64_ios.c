/*
 * ARM64 signal handling routines
 *
 * Copyright 2010-2013 André Hentschel
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

#ifdef __aarch64__

#include "config.h"

#include <assert.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <errno.h>
#include <unistd.h>
#ifdef WINE_IOS
#include <dlfcn.h>
#include <mach/mach.h>

/* iOS-Madeira ml674: XZR/WZR AS A STORE SOURCE MUST READ ZERO.
 *
 * arm_thread_state64_t is  __uint64_t __x[29]  followed by __fp, __lr, __sp --
 * so state.__x[31] is not out of bounds by accident, it lands EXACTLY on __sp.
 *
 * That makes register 31 behave correctly in one role and catastrophically in
 * the other:
 *   - as a BASE register (Rn), 31 means SP, and __x[31] IS __sp  -> correct
 *   - as a SOURCE register (Rt/Rt2/Rs), 31 means ZR              -> must be 0,
 *     but reads the stack pointer instead
 *
 * Because the base-register half works, the decoder reads as correct and this
 * survived a long time. What it actually did: every fault-emulated `str xzr` /
 * `stur xzr` / `stp xzr,xzr` into an alias-backed page wrote a STACK ADDRESS
 * where the guest asked for zero.
 *
 * Book of the Dead showed it precisely. RtlInitializeCriticalSectionEx emits
 *     stur xzr, [x19,#0x0c]      ; RecursionCount + half of OwningThread
 *     stur xzr, [x19,#0x14]      ; rest of OwningThread + half of LockSemaphore
 *     str  wzr, [x19,#0x1c]      ; rest of LockSemaphore
 * so a section on a Mono anon-RWX page was born holding SP fragments:
 *     RecursionCount = 0x23bbf660, LockSemaphore = 0x23bbf660_00000070
 * and the first NtReleaseSemaphore on it returned STATUS_INVALID_HANDLE.
 *
 * Scope is much wider than one crash: any zero-store into an alias-backed page
 * was corrupting memory this way. */
#define IOS_STORE_SRC(r) ((r) == 31 ? 0ULL : state.__x[r])

#include <mach/mach_vm.h>
#include <mach/thread_act.h>
#include <pthread/pthread.h>
#include <pthread/qos.h>
#include <fcntl.h>
#endif
#ifdef HAVE_SYS_PARAM_H
# include <sys/param.h>
#endif
#ifdef HAVE_SYSCALL_H
# include <syscall.h>
#else
# ifdef HAVE_SYS_SYSCALL_H
#  include <sys/syscall.h>
# endif
#endif
#ifdef HAVE_SYS_SIGNAL_H
# include <sys/signal.h>
#endif
#ifdef HAVE_SYS_UCONTEXT_H
# include <sys/ucontext.h>
#endif

#include "ntstatus.h"
#include "windef.h"
#include "winnt.h"
#include "winternl.h"
#include "wine/asm.h"
#include "unix_private.h"
#include "ios_wow.h"
#include "wine/debug.h"

/* defined at the bottom of this file with the [thread-stacks] dumper */
static const char *ios_pe_module_name( uint64_t base );

WINE_DEFAULT_DEBUG_CHANNEL(seh);

/* X3 mixed-mode: user-mode entry points follow the current pseudo-process's
 * ntdll image (cross-arch children run a private ARM64EC ntdll). Falls back
 * to the session p* globals when the process has no private image. */
#include "ios_mixed.h"
#define IOS_PFUNC(name) __extension__ ({ \
    const struct ios_ntdll_funcs *_iosf = ios_cur_ntdll_funcs(); \
    _iosf ? _iosf->name : (void *)p##name; })

#define NTDLL_DWARF_H_NO_UNWINDER
#include "dwarf.h"

/* ml649: runtime diagnostic switch, defined in virtual_ios.c. Default OFF.
 * Gate the WORK, not the print — several probes do expensive reads first. */
extern volatile int madeira_diag_enabled;


/* ml648: defined in virtual_ios.c, called from the SWPAL emulation path. */
void ios_mono_bridge_capture( unsigned long long teb, unsigned long long frame,
                              unsigned long long host_pc, unsigned long long fault_addr );


/* ml255: storm gate -- see ios_storm_gate in virtual_ios.c for the rationale
 * (510 MB log from a 524k-iteration NULL-deref loop). */
static int ios_sig_storm_gate( unsigned long *n )
{
    unsigned long c = ++(*n);
    if (c <= 20) return 1;
    if (c <= 100000) return (c % 1000) == 0;
    return (c % 100000) == 0;
}

/***********************************************************************
 * signal context platform-specific definitions
 */
#ifdef linux

/* All Registers access - only for local access */
# define REG_sig(reg_name, context) ((context)->uc_mcontext.reg_name)
# define REGn_sig(reg_num, context) ((context)->uc_mcontext.regs[reg_num])

/* Special Registers access  */
# define SP_sig(context)            REG_sig(sp, context)    /* Stack pointer */
# define PC_sig(context)            REG_sig(pc, context)    /* Program counter */
# define PSTATE_sig(context)        REG_sig(pstate, context) /* Current State Register */
# define FP_sig(context)            REGn_sig(29, context)    /* Frame pointer */
# define LR_sig(context)            REGn_sig(30, context)    /* Link Register */

static struct _aarch64_ctx *get_extended_sigcontext( const ucontext_t *sigcontext, unsigned int magic )
{
    struct _aarch64_ctx *ctx = (struct _aarch64_ctx *)sigcontext->uc_mcontext.__reserved;
    while ((char *)ctx < (char *)(&sigcontext->uc_mcontext + 1) && ctx->magic && ctx->size)
    {
        if (ctx->magic == magic) return ctx;
        ctx = (struct _aarch64_ctx *)((char *)ctx + ctx->size);
    }
    return NULL;
}

static struct fpsimd_context *get_fpsimd_context( const ucontext_t *sigcontext )
{
    return (struct fpsimd_context *)get_extended_sigcontext( sigcontext, FPSIMD_MAGIC );
}

static DWORD64 get_fault_esr( ucontext_t *sigcontext )
{
    struct esr_context *esr = (struct esr_context *)get_extended_sigcontext( sigcontext, ESR_MAGIC );
    if (esr) return esr->esr;
    return 0;
}

#elif defined(__APPLE__)

/* All Registers access - only for local access */
# define REG_sig(reg_name, context) ((context)->uc_mcontext->__ss.__ ## reg_name)
# define REGn_sig(reg_num, context) ((context)->uc_mcontext->__ss.__x[reg_num])

/* Special Registers access  */
# define SP_sig(context)            REG_sig(sp, context)    /* Stack pointer */
# define PC_sig(context)            REG_sig(pc, context)    /* Program counter */
# define PSTATE_sig(context)        REG_sig(cpsr, context)  /* Current State Register */
# define FP_sig(context)            REG_sig(fp, context)    /* Frame pointer */
# define LR_sig(context)            REG_sig(lr, context)    /* Link Register */

static DWORD64 get_fault_esr( ucontext_t *sigcontext )
{
    return sigcontext->uc_mcontext->__es.__esr;
}

#endif /* linux */

/* stack layout when calling KiUserExceptionDispatcher */
struct exc_stack_layout
{
    CONTEXT              context;        /* 000 */
    CONTEXT_EX           context_ex;     /* 390 */
    EXCEPTION_RECORD     rec;            /* 3b0 */
    ULONG64              align;          /* 448 */
    ULONG64              redzone[2];     /* 450 */
};
C_ASSERT( offsetof(struct exc_stack_layout, rec) == 0x3b0 );
C_ASSERT( sizeof(struct exc_stack_layout) == 0x460 );

/* stack layout when calling KiUserApcDispatcher */
struct apc_stack_layout
{
    void                *func;           /* 000 APC to call*/
    ULONG64              args[3];        /* 008 function arguments */
    ULONG64              alertable;      /* 020 */
    ULONG64              align;          /* 028 */
    CONTEXT              context;        /* 030 */
    ULONG64              redzone[2];     /* 3c0 */
};
C_ASSERT( offsetof(struct apc_stack_layout, context) == 0x30 );
C_ASSERT( sizeof(struct apc_stack_layout) == 0x3d0 );

/* stack layout when calling KiUserCallbackDispatcher */
struct callback_stack_layout
{
    void                *args;           /* 000 arguments */
    ULONG                len;            /* 008 arguments len */
    ULONG                id;             /* 00c function id */
    ULONG64              unknown;        /* 010 */
    ULONG64              lr;             /* 018 */
    ULONG64              sp;             /* 020 sp+pc (machine frame) */
    ULONG64              pc;             /* 028 */
    BYTE                 args_data[0];   /* 030 copied argument data*/
};
C_ASSERT( offsetof(struct callback_stack_layout, sp) == 0x20 );
C_ASSERT( sizeof(struct callback_stack_layout) == 0x30 );

struct syscall_frame
{
    ULONG64               x[29];          /* 000 */
    ULONG64               fp;             /* 0e8 */
    ULONG64               lr;             /* 0f0 */
    ULONG64               sp;             /* 0f8 */
    ULONG64               pc;             /* 100 */
    ULONG                 cpsr;           /* 108 */
    ULONG                 restore_flags;  /* 10c */
    struct syscall_frame *prev_frame;     /* 110 */
    void                 *syscall_cfa;    /* 118 */
    ULONG                 syscall_id;     /* 120 */
    ULONG                 align;          /* 124 */
    ULONG                 fpcr;           /* 128 */
    ULONG                 fpsr;           /* 12c */
    NEON128               v[32];          /* 130 */
};

C_ASSERT( sizeof( struct syscall_frame ) == 0x330 );

#ifdef WINE_IOS
/* Written by __wine_syscall_dispatcher at entry to capture the actual x18 value.
 * Read by the watchdog to verify whether x18 is TEB or 0. */
volatile uint64_t g_wine_dispatcher_x18 = 0xDEADDEAD;
volatile int ios_signal_total = 0;
volatile int ios_signal_last = 0;
volatile int ios_signal_in_pe = 0;  /* signals while PC was in JIT pool */
/* Counter of how many times the dispatcher has been called */
volatile uint64_t g_wine_dispatcher_count = 0;
/* g_wine_unix_call_count is now in loader_ios.c (wrapper table) */
/* Written by __wine_syscall_dispatcher_return to capture frame->x[18] and frame->pc
 * BEFORE they are loaded into registers and we jump to PE code */
volatile uint64_t g_wine_return_x18 = 0xDEADDEAD;
volatile uint64_t g_wine_return_pc = 0xDEADDEAD;
volatile uint64_t g_wine_return_count = 0;
/* Saved right before ret/br to PE code */
volatile uint64_t g_wine_x18_before_ret = 0xDEADDEAD;
volatile uint64_t g_wine_x16_at_ret = 0xDEADDEAD;
/* Ring buffer of last 8 dispatcher_return PCs for crash diagnosis */
#define WINE_RET_RING_SIZE 8
volatile uint64_t g_wine_return_ring[WINE_RET_RING_SIZE];
volatile uint32_t g_wine_return_ring_idx = 0;
/* Counters accessible from BUS handler for crash diagnosis */
volatile int ios_total_segv_count = 0;
/* TEB backup for signal handler x18 restoration */
static __thread uintptr_t ios_teb_for_signals = 0;

/* TLS key for storing TEB, accessible via TPIDRRO_EL0 in patched PE code */
pthread_key_t ios_teb_tls_key = 0;
int ios_teb_tls_slot_offset = 0;  /* byte offset from TPIDRRO_EL0 base to TEB slot */
int ios_teb_tls_key_created = 0;

/*
 * Per-thread Mach exception handler for EXC_BAD_ACCESS.
 * ONE handler thread serves ALL Wine "process" threads.
 * Each Wine thread registers its Mach thread port, TEB, and trampoline
 * in a shared registry. The handler looks up the correct TEB/trampoline
 * for the faulting thread.
 *
 * Handles: x18=0 (TEB corruption), user_shared_data (0x7FFE0000) redirects,
 * and PE→JIT pool execution redirects.
 * Unhandled exceptions fall through to the POSIX SIGSEGV handler.
 */
/* ml515: forward decl — the Mach handler uses this ~4600 lines before the
 * definition, and with -Wno-implicit-function-declaration the call would
 * otherwise create an implicit NON-static declaration and collide with the
 * static definition. (Same trap as the ml488 file.c probe.) */
struct __darwin_arm_thread_state64;
static int ios_srcwatch_handle( const arm_thread_state64_t *st, uintptr_t addr );

static mach_port_t ios_exc_port = MACH_PORT_NULL;
static int ios_exc_handler_started = 0;
/* Whether the Mach delivery path classifies ESR alignment faults (see the
 * [unaligned-atomic] block in ios_mach_deliver_guest_exception_inner). Set
 * once before the exception server thread starts; MADEIRA_MACH_ALIGN_FAULT=0
 * turns it off. */
static int ios_mach_align_fault_enabled = 1;
static uintptr_t ios_exc_usd = 0;
volatile int64_t ios_exc_x18_fixes = 0;
volatile int64_t ios_exc_usd_fixes = 0;
volatile int ios_exc_thread_alive = 0;
volatile int ios_exc_msg_count = 0;
/* ml680: cost of a fault, measured rather than assumed. A 2026-07-03 note in
 * the receive loop already put the round trip at ~33us; this makes it a live
 * number for THIS workload so the W^X change has a before/after to beat.
 * t0 is stamped at message receipt and consumed by the store emulator. */
volatile unsigned long long ios_store_fault_t0 = 0;
volatile unsigned long long ios_store_fault_ticks = 0;
volatile unsigned long long ios_store_fault_n = 0;
volatile unsigned long long ios_store_fault_dropped = 0;   /* ml685 */
/* ml690: which thread is currently faulting. Set once per received exception on
 * the single handler thread, so no locking is needed. Attribution answers the
 * question the aggregate cannot: is the 34k faults/sec stalling the MAIN thread
 * (in which case W^X should move the frame rate) or only the tree worker (in
 * which case it buys a core but may not move FPS at all)? */
volatile unsigned int ios_cur_fault_port = 0;

/* ml691: pages demoted to RW by the W^X path, so an execute fault on one can be
 * recovered. Kept OUTSIDE the store handler's static so the exec path can reach
 * it. Restoring RX is synchronous -- the faulting thread does not resume until
 * the page is executable again -- and a page that reaches here is marked sticky
 * so it is never demoted a second time. */
/* ml694: RESTORED to the ml691 structure, which is the only W^X configuration
 * proven to work (192 demotions, 0 re-promotions, faults 45,464 -> 33,733/sec,
 * 1-2 -> 4-5 FPS over a full session).
 *
 * ml692 enlarged this to a 32,768-entry hash AND dropped the threshold 32 -> 8
 * in one build; it crashed. ml693 reverted only the threshold and crashed
 * IDENTICALLY -- same guest RIP, same wild read, after demoting the SAME FOUR
 * pages ml691 demoted safely. So neither "too many pages" nor "too early"
 * explains it, and the table change is the remaining difference. Enlarging it
 * again is off the table until execution/SMC correctness is enforced.
 *
 * KNOWN LIMITS of this mechanism, recorded so nobody reads it as production-safe:
 *   - Keyed by guest page address ONLY -- no PEB, alias generation, or mapping
 *     lifetime, so a reused address can inherit stale state.
 *   - An NX guest page does NOT guarantee an execution fault: FEX can keep
 *     running an already-cached host translation without ever touching the guest
 *     page. "0 re-promotions" therefore does NOT prove no demoted page was
 *     executed -- it only proves no fault was taken. That is the leading
 *     explanation for ml692/ml693's deterministic wild-pointer crash.
 *   - The durable fix is metadata owned by each live alias mapping (with
 *     generation/lifetime) wired into FEX's translation invalidation, not a
 *     second page-only registry. */
#define IOS_WX_MAX 256
struct ios_wx_page { unsigned long long page; volatile int demoted, sticky; };
struct ios_wx_page ios_wx_pages[IOS_WX_MAX];
static volatile unsigned ios_wx_repromotes;

/* ml694: one switch, resolved once, logged once. The ml691-693 gate read two
 * paths that can never exist (a container path with no UUID, and a CWD-relative
 * name), so it silently forced ENABLED on every run and the "disable it and
 * retest" A/B I offered was not actually possible. An env var reaches this
 * native side -- proven by MADEIRA_NO_DFE in ml597/598. */
int ios_wx_enabled( void )
{
    static int v = -1;
    if (v < 0)
    {
        /* ml695: OFF BY DEFAULT. This optimization has known stale-translation
         * and address-reuse hazards and has already produced deterministic
         * crashes in two builds; silent corruption on a fresh install would be
         * worse than a clean crash, and a kill switch a user must discover
         * afterward is not a substitute for a safe default. Opt in with
         * Documents/madeira-wx.txt containing 1.
         *
         * Native code reads ONLY this env value -- Swift owns the sandbox path
         * so that knowledge is not duplicated in two places. */
        const char *e = getenv( "MADEIRA_WX" );
        v = (e && e[0] == '1') ? 1 : 0;
        dprintf( STDERR_FILENO, "[wx] ml695 MADEIRA_WX=%s -> W^X %s (experimental, opt-in; threshold 32, %d slots)\n",
                 e ? e : "(unset)", v ? "ENABLED" : "DISABLED", IOS_WX_MAX );
    }
    return v;
}

int ios_wx_repromote( unsigned long long pc )
{
    unsigned long long pg = pc & ~0x3fffull;
    int i;
    for (i = 0; i < IOS_WX_MAX; i++)
    {
        if (ios_wx_pages[i].page != pg || !ios_wx_pages[i].demoted) continue;
        if (mprotect( (void *)(uintptr_t)pg, 0x4000, PROT_READ | PROT_EXEC ) == 0)
        {
            unsigned n = __sync_add_and_fetch( &ios_wx_repromotes, 1 );
            ios_wx_pages[i].demoted = 0;
            ios_wx_pages[i].sticky = 1;       /* never demote this page again */
            dprintf(STDERR_FILENO,
                "[wx] ml694 RE-PROMOTED 0x%llx to RX after an EXEC fault at 0x%llx "
                "(total=%u) -- this page holds CODE, not data\n", pg, pc, n);
            return 1;
        }
        dprintf(STDERR_FILENO, "[wx] ml694 re-promote mprotect FAILED 0x%llx errno=%d\n", pg, errno);
        return 0;
    }
    return 0;
}

/* Last thread that took an exec fault at a PE VA (i.e. made a native call
 * through the redirect path) — the game thread in practice. The [PROF]
 * sampler in server_ios.c follows this so it profiles the presenting
 * thread instead of whatever thread first hit signal_start_thread (which
 * died ~33s in and left [PROF] sampling a corpse). */
volatile mach_port_t ios_last_exec_fault_thread = MACH_PORT_NULL;

/* Real unix-side KUSER_SHARED_DATA address, for unix code (e.g. win32u's
 * get_tick_count) that would otherwise read the canonical 0x7ffe0000 and
 * eat a Mach fault per load. */
unsigned long long ios_get_real_usd(void)
{
    return (unsigned long long)ios_exc_usd;
}

/* ---- Self-healing stale-pointer patcher ----------------------------------
 * Mechanism-#2 exec faults: pool-resident module copies hold function
 * pointers that still carry PE VAs (lazily-written ARM64EC aux-IAT slots,
 * runtime GetProcAddress results — writes that happen pool-side AFTER the
 * NtProtect sync/translate pass ran). Each call through such a pointer
 * faults (~8K/s in gameplay, each suspending the calling thread for a full
 * handler round trip). The Mach handler enqueues every distinct faulted
 * PE VA here; a low-priority scanner thread rewrites EVERY 8-byte slot in
 * the module-copy pool ranges holding that value to its pool equivalent.
 * Each stale pointer faults once, then never again. FEX CodeBuffer ranges
 * are NOT scanned (guest-RIP constants live there). */
/* 64 → 256 (2026-07-07): with a desktop + several pseudo-processes the
 * boot one-shot VAs alone overflowed 64 slots, and the two-cube DXMT
 * fault storm's VA (child winemetal IAT → child EC ntdll map VA,
 * 315K faults) arrived late and was silently dropped — never tracked,
 * never healed. */
#define IOS_STALE_VA_MAX 256
/* Only heal a VA once it has exec-faulted this many times. Boot-time
 * one-shot redirects (thread entry points, DLL entry calls) fault a
 * handful of times and must NOT be healed — pool slots legitimately hold
 * some of those PE VAs (CONTEXT records, pending thread params), and
 * rewriting them broke boot (2026-07-04 freeze, pre-splash NULL-deref
 * livelock). The pathological stale pointers fault thousands of times per
 * second; a threshold cleanly separates the two populations. */
#define IOS_STALE_VA_HEAL_THRESHOLD 256
static uint64_t ios_stale_va_seen[IOS_STALE_VA_MAX];
static uint32_t ios_stale_va_hits[IOS_STALE_VA_MAX];
static volatile int ios_stale_va_seen_count = 0;
static uint64_t ios_stale_va_queue[IOS_STALE_VA_MAX];
static volatile int ios_stale_va_head = 0;   /* written by scanner */
static volatile int ios_stale_va_tail = 0;   /* written by exc handler */

static void ios_stale_va_enqueue( uint64_t va )
{
    int i, n = ios_stale_va_seen_count;
    for (i = 0; i < n; i++)
    {
        if (ios_stale_va_seen[i] == va)
        {
            if (++ios_stale_va_hits[i] == IOS_STALE_VA_HEAL_THRESHOLD)
            {
                ios_stale_va_queue[ios_stale_va_tail % IOS_STALE_VA_MAX] = va;
                ios_stale_va_tail++;
                fprintf( stderr, "[stale-heal] 0x%llx crossed %d faults — queued for heal\n",
                         (unsigned long long)va, IOS_STALE_VA_HEAL_THRESHOLD );
            }
            return;
        }
    }
    if (n >= IOS_STALE_VA_MAX)
    {
        /* Table full: evict the coldest entry (boot one-shots sit at a
         * handful of hits) so pathological late-comers — a new child's
         * DXMT IAT — still get tracked. Only the single mach-handler
         * thread calls this, so the read-modify-write is safe. */
        int min_i = 0;
        uint32_t min_h = ios_stale_va_hits[0];
        for (i = 1; i < n; i++)
            if (ios_stale_va_hits[i] < min_h) { min_h = ios_stale_va_hits[i]; min_i = i; }
        if (min_h >= IOS_STALE_VA_HEAL_THRESHOLD) return;  /* everything hot — drop */
        ios_stale_va_seen[min_i] = va;
        ios_stale_va_hits[min_i] = 1;
        return;
    }
    ios_stale_va_seen[n] = va;
    ios_stale_va_hits[n] = 1;
    ios_stale_va_seen_count = n + 1;
}

static void *ios_stale_va_scanner( void *arg )
{
    extern int ios_jit_patch_stale_pointer( unsigned long long stale_va );
    /* Healing default-ON since 2026-07-07: the patcher now rewrites ONLY
     * IAT/delay-IAT slots (parsed from each pool copy's PE headers), so
     * the 2026-07-04 breakage class — arm64x metadata slots whose
     * consumers need PE VAs for identity/range comparisons — can't be
     * touched. Import slots hold nothing but call targets; rewriting
     * them is the same transform the NtProtect-time IAT-sync applies.
     * MADEIRA_NO_HEAL=1 reverts to dry-run reporting. */
    int do_heal = getenv( "MADEIRA_NO_HEAL" ) == NULL;
    pthread_setname_np( "wine-stale-heal" );
    for (;;)
    {
        usleep( 100000 );
        while (ios_stale_va_head != ios_stale_va_tail)
        {
            uint64_t va = ios_stale_va_queue[ios_stale_va_head % IOS_STALE_VA_MAX];
            ios_stale_va_head++;
            if (do_heal)
                ios_jit_patch_stale_pointer( va );
            else
                fprintf( stderr, "[stale-heal] (dry-run) hot stale VA 0x%llx — heal skipped (MADEIRA_NO_HEAL set)\n",
                         (unsigned long long)va );
        }
    }
    return NULL;
}

/* Per-thread trampoline for signal handlers (runs on faulting thread) */
static __thread void *ios_my_trampoline = NULL;
static __thread int ios_my_slot = -1;

/* Thread registry: maps Mach thread port → TEB + trampoline.
 *
 * ml384: was 64. Steam runs register 90+ threads; entries past the cap were
 * silently DROPPED while the success ERR still printed, so every late-born
 * thread resolved to the slot-0 fallback = the INITIAL process's TEB. A
 * wrong-process TEB means the wrong per-PEB dispatcher, which walks the wrong
 * ntdll pool copy — services.exe died in LdrShutdownThread with wm=NULL that
 * way (ml383). The lookup also iterated to ios_thread_count (92+), reading
 * past the 64-entry array. */
#define IOS_MAX_WINE_THREADS 512

struct ios_thread_entry {
    thread_t mach_thread;
    uintptr_t teb;
    void *trampoline;
};
static struct ios_thread_entry ios_thread_registry[IOS_MAX_WINE_THREADS];
static volatile int32_t ios_thread_count = 0;

/* Exact-match registry probe — NO slot-0 fallback.
 *
 * ml540: ios_lookup_thread() returns 1 even when it fell back to slot 0, so no
 * caller can use it to answer "is this a guest thread at all?". Fault handling
 * needs exactly that: since #67 we hold the TASK-level exception port, so this
 * handler now sees faults from EVERY thread in the process — including the
 * SwiftUI UI thread, which has no TEB and must never be handed guest exception
 * delivery. */
/* ml559: read-only accessors so other TUs can walk the registry without the
 * array itself leaving this file (ntdll-unix globals crossing TUs have broken
 * pseudo-processes before — see the S1 CreateProcess rule). Lock-free, same
 * snapshot discipline as ios_thread_is_registered. */
int ios_thread_registry_count(void)
{
    int count = __sync_fetch_and_add(&ios_thread_count, 0);
    return count > IOS_MAX_WINE_THREADS ? IOS_MAX_WINE_THREADS : count;
}

uintptr_t ios_thread_registry_teb(int i)
{
    if (i < 0 || i >= IOS_MAX_WINE_THREADS) return 0;
    return ios_thread_registry[i].teb;
}

thread_t ios_thread_registry_mach(int i)
{
    if (i < 0 || i >= IOS_MAX_WINE_THREADS) return 0;
    return ios_thread_registry[i].mach_thread;
}

static int ios_thread_is_registered(thread_t mach_thread)
{
    int count = __sync_fetch_and_add(&ios_thread_count, 0);
    if (count > IOS_MAX_WINE_THREADS) count = IOS_MAX_WINE_THREADS;
    for (int i = 0; i < count; i++)
        if (ios_thread_registry[i].mach_thread == mach_thread) return 1;
    return 0;
}

/* ml558: is this pointer a TEB we actually installed?
 *
 * TSD slot 275 is NOT ours (see pthread_exit_wrapper) -- on a native thread it
 * holds whatever framework legitimately owns that key. Signal handlers that read
 * slot 275 must validate the value before dereferencing it, and must do so
 * WITHOUT locks or Mach traps. Scanning the registry for a matching TEB is both:
 * lock-free (same pattern as ios_thread_is_registered) and it answers the exact
 * question -- not "is this thread ours" but "is this VALUE one of ours". */
static int ios_teb_is_registered(uintptr_t teb)
{
    int count = __sync_fetch_and_add(&ios_thread_count, 0);
    if (!teb) return 0;
    if (count > IOS_MAX_WINE_THREADS) count = IOS_MAX_WINE_THREADS;
    for (int i = 0; i < count; i++)
        if (ios_thread_registry[i].teb == teb) return 1;
    return 0;
}

/* A released guest window is about to become PROT_NONE, and every TEB inside
 * it with it.  Entries naming those TEBs must go first: the registry is keyed
 * by Mach port, ports are recycled, and the exception path's port lookup would
 * otherwise hand the fault handler a pointer into the replaced range.  Only
 * called from the guest-window teardown (virtual_ios.c). */
int ios_thread_registry_purge_range( uintptr_t base, uintptr_t size )
{
    int count = ios_thread_registry_count(), purged = 0, i;

    for (i = 0; i < count; i++)
    {
        uintptr_t teb = ios_thread_registry[i].teb;

        if (!teb || teb < base || teb - base >= size) continue;
        ios_thread_registry[i].mach_thread = 0;
        __sync_synchronize();
        ios_thread_registry[i].teb = 0;
        ios_thread_registry[i].trampoline = NULL;
        purged++;
    }
    return purged;
}

/* Is a thread whose TEB lies in [base, base+size) still alive?  An exited
 * process's workers can stay asleep long after its main thread is gone.  Only
 * the Mach thread's existence is asked, its TEB is never dereferenced; an
 * unexpected query failure counts as alive (keep the memory). */
int ios_thread_registry_range_busy( uintptr_t base, uintptr_t size )
{
    int count = ios_thread_registry_count(), i;

    for (i = 0; i < count; i++)
    {
        uintptr_t teb = ios_thread_registry[i].teb;
        thread_t port = ios_thread_registry[i].mach_thread;
        struct thread_basic_info info;
        mach_msg_type_number_t length = THREAD_BASIC_INFO_COUNT;
        kern_return_t kr;

        if (!port || !teb || teb < base || teb - base >= size) continue;
        kr = thread_info( port, THREAD_BASIC_INFO, (thread_info_t)&info, &length );
        if (kr != KERN_INVALID_ARGUMENT && kr != MACH_SEND_INVALID_DEST && kr != KERN_TERMINATED) return 1;
    }
    return 0;
}

static int ios_lookup_thread(thread_t mach_thread, uintptr_t *teb_out, void **tramp_out)
{
    int count = __sync_fetch_and_add(&ios_thread_count, 0);
    if (count > IOS_MAX_WINE_THREADS) count = IOS_MAX_WINE_THREADS;
    for (int i = 0; i < count; i++)
    {
        if (ios_thread_registry[i].mach_thread == mach_thread)
        {
            *teb_out = ios_thread_registry[i].teb;
            *tramp_out = ios_thread_registry[i].trampoline;
            return 1;
        }
    }
    /* Fallback: use first registered thread */
    /* ml390 (task #66): a thread that registered CORRECTLY (0184: idx=75 port
     * 0x4493 teb ok) later resolved to the slot-0 TEB here — either the
     * exception message named the thread differently than mach_thread_self()
     * did at registration (name drift), or the entry was clobbered.  Print the
     * sought name so it can be diffed against the registration line offline. */
    {
        static int miss_n;
        if (miss_n < 32)
        {
            miss_n++;
            ERR( "[reg-miss] #%d port=0x%x not in registry (count=%d) -> slot-0 fallback teb=%p\n",
                 miss_n, mach_thread, count, count > 0 ? (void *)ios_thread_registry[0].teb : NULL );
        }
    }
    if (count > 0)
    {
        *teb_out = ios_thread_registry[0].teb;
        *tramp_out = ios_thread_registry[0].trampoline;
        return 1;
    }
    *teb_out = 0;
    *tramp_out = NULL;
    return 0;
}

/* ml398 (task #60): the webhelper chrome_ipc pump thread wakes ONCE on
 * MasterStream_Event, reads a perfectly valid hello ([chrome-mem] proved the
 * bytes cross), then goes silent — no reply, no re-wait, no further wrapped
 * syscall.  The EC wrapper stamps TEB->Instrumentation[10] = 'PUMP' at that
 * wake; the census thread calls this every cycle to sample the thread's Mach
 * state.  RUNNING with a moving pc = userspace spin (pc locates it);
 * WAITING = blocked in a syscall the wrappers don't cover (pc/lr name it);
 * dead port = the thread died silently.  Candidate-TEB reads go through
 * mach_vm_read_overwrite so a stale registry entry cannot fault the census
 * thread.  Called from the virtual_ios.c census loop. */
/* ml405 (task #60): the wanderer often parks PRE-chorus, where no beacon
 * exists.  Census sweep, no beacon needed: every call, walk registry entries
 * (newest-first per TEB so corpses lose), and report every thread parked in
 * the ml404 __ulock_wait signature (WAITING + x0==0x1000001) — lock address
 * (x1), lock word (owner name for os_unfair_lock), and an 8-frame fp walk.
 * Each thread reported once (dedupe by port), 60 reports max. */
static void ios_lock_census(void)
{
    static int total_logged;
    static thread_t seen[64];
    static int nseen;
    int count = __sync_fetch_and_add(&ios_thread_count, 0);
    int i, s;
    if (count > IOS_MAX_WINE_THREADS) count = IOS_MAX_WINE_THREADS;

    /* iOS-Madeira ml414 (#60): the CodeInvalidationMutex read-holder is alive
     * somewhere — xtajit64 stamps TEB+0x16f8 (Instrumentation[8]) with the
     * mutex address while the shared lock is held (CompileCode).  ml414 proved
     * the leaker neither pthread_exits ([exit-hold] 0) nor gets a guest
     * redirect ([deliver-hold] 0) — it is parked/frozen in place.  Sweep every
     * registry thread for the stamp each census pass: names the holder AND
     * shows where it sits (pc/lr/bt) and whether the debugger froze it
     * (suspend_count).  A transient hit (mid-compile) is normal noise; the
     * same teb repeating with the same pc across passes = the leaker. */
    {
        static int hold_logged;
        for (i = count - 1; i >= 0 && hold_logged < 40; i--)
        {
            thread_t cand = ios_thread_registry[i].mach_thread;
            uintptr_t cteb = (uintptr_t)ios_thread_registry[i].teb;
            uint64_t held = 0;
            unsigned int ctid = 0;
            mach_vm_size_t mgot = 0;
            arm_thread_state64_t st;
            mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
            struct thread_basic_info bi;
            mach_msg_type_number_t bcnt = THREAD_BASIC_INFO_COUNT;
            uint64_t fp, frames[8] = { 0 };
            int fi;
            uint64_t srw_held = 0;
            if (!cand || !cteb) continue;
            if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(cteb + 0x16f8), 8,
                                        (mach_vm_address_t)&held, &mgot ) != KERN_SUCCESS
                || mgot != 8)
                continue;
            /* ml446: slot 6 = CodeBufferWriteMutex ownership — a dead thread
             * holding ONLY that must not be skipped by the !held early-out */
            mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(cteb + 0x16e8), 8,
                                    (mach_vm_address_t)&srw_held, &mgot );
            if (!held && !srw_held)
            {
                /* ml416: a converged rpmalloc-ownership repair leaves its
                 * breadcrumb (Instrumentation[4]) with the lock long released
                 * — report it once so the repair is visible even when the
                 * livelock never got to wedge anything. */
                static int crumb_logged;
                uint64_t crumb_owner = 0, crumb_heap = 0;
                if (crumb_logged >= 12) continue;
                mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(cteb + 0x16d8), 8,
                                        (mach_vm_address_t)&crumb_owner, &mgot );
                mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(cteb + 0x16e0), 8,
                                        (mach_vm_address_t)&crumb_heap, &mgot );
                if (!crumb_owner && !crumb_heap) continue;
                crumb_logged++;
                mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(cteb + 0x48), 4,
                                        (mach_vm_address_t)&ctid, &mgot );
                dprintf(2, "[census-hold] RPMALLOC-REPAIR (converged) teb=0x%llx tid=%04x old_owner=0x%llx heap=0x%llx\n",
                        (unsigned long long)cteb, ctid, (unsigned long long)crumb_owner,
                        (unsigned long long)crumb_heap);
                continue;
            }
            mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(cteb + 0x48), 4,
                                    (mach_vm_address_t)&ctid, &mgot );
            memset( &bi, 0, sizeof(bi) );
            {
                kern_return_t ti_kr = thread_info( cand, THREAD_BASIC_INFO, (thread_info_t)&bi, &bcnt );
                /* ml445 (#74): DEAD port + live TEB stamp = a cross-terminated
                 * thread ([thr-term] CROSS-TERM) died holding the FEX shared
                 * lock — the leak that stalls the world.  Recycling guard: if
                 * ANY live registry row uses this TEB, the stamp belongs to
                 * the live generation — do NOT touch it. */
                if (ti_kr != KERN_SUCCESS && held)
                {
                    static uint64_t reaped_tebs[16];
                    static int reaped_n;
                    int r, live = 0, already = 0;
                    for (r = 0; r < reaped_n; r++) if (reaped_tebs[r] == (uint64_t)cteb) already = 1;
                    for (r = 0; r < count && !live; r++)
                    {
                        struct thread_basic_info lbi;
                        mach_msg_type_number_t lcnt = THREAD_BASIC_INFO_COUNT;
                        if (r == i || (uintptr_t)ios_thread_registry[r].teb != cteb) continue;
                        if (ios_thread_registry[r].mach_thread &&
                            thread_info( ios_thread_registry[r].mach_thread, THREAD_BASIC_INFO,
                                         (thread_info_t)&lbi, &lcnt ) == KERN_SUCCESS)
                            live = 1;
                    }
                    if (!already && !live && reaped_n < 16)
                    {
                        extern void ios_wpm_reap_shared( unsigned long long mutex_addr, unsigned int depth,
                                                         unsigned long long dead_teb );
                        extern void ios_srw_reap_exclusive( unsigned long long lock_addr, unsigned long long dead_teb );
                        uint32_t depth = 1;
                        uint64_t srw_stamp = 0;
                        mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(cteb + 0x16f0), 4,
                                                (mach_vm_address_t)&depth, &mgot );
                        if (!depth) depth = 1;
                        /* ml446: slot 6 = &CodeBufferWriteMutex while the JIT
                         * emission section holds it (JIT.cpp stamp) */
                        mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(cteb + 0x16e8), 8,
                                                (mach_vm_address_t)&srw_stamp, &mgot );
                        reaped_tebs[reaped_n++] = (uint64_t)cteb;
                        dprintf(2, "[lock-reap] dead port=0x%x tid=%04x teb=0x%llx stamp=0x%llx depth=%u srw=0x%llx — reaping rev=ml446\n",
                                cand, ctid, (unsigned long long)cteb, (unsigned long long)held, depth,
                                (unsigned long long)srw_stamp);
                        ios_wpm_reap_shared( held, depth, (unsigned long long)cteb );
                        if (srw_stamp) ios_srw_reap_exclusive( srw_stamp, (unsigned long long)cteb );
                    }
                    else if (!already && live)
                        dprintf(2, "[lock-reap] dead port=0x%x teb=0x%llx stamp=0x%llx SKIPPED (teb recycled to live thread) rev=ml445\n",
                                cand, (unsigned long long)cteb, (unsigned long long)held);
                }
            }
            if (thread_get_state( cand, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt ) != KERN_SUCCESS)
                memset( &st, 0, sizeof(st) );
            fp = st.__fp;
            for (fi = 0; fi < 8 && fp > 0x1000; fi++)
            {
                uint64_t rec[2] = { 0, 0 };
                mgot = 0;
                if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)fp, sizeof(rec),
                                            (mach_vm_address_t)rec, &mgot ) != KERN_SUCCESS) break;
                frames[fi] = rec[1];
                fp = rec[0];
            }
            hold_logged++;
            /* ml416: Instrumentation[4]/[5] are the rpmalloc ownership-repair
             * breadcrumbs (old owner_thread TEB / heap ptr) stamped by the
             * FEX-side drain fix — nonzero means the livelock repair FIRED. */
            {
                uint64_t crumb_owner = 0, crumb_heap = 0;
                mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(cteb + 0x16d8), 8,
                                        (mach_vm_address_t)&crumb_owner, &mgot );
                mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(cteb + 0x16e0), 8,
                                        (mach_vm_address_t)&crumb_heap, &mgot );
                if (crumb_owner || crumb_heap)
                    dprintf(2, "[census-hold]   RPMALLOC-REPAIR breadcrumb teb=0x%llx: old_owner=0x%llx heap=0x%llx\n",
                            (unsigned long long)cteb, (unsigned long long)crumb_owner,
                            (unsigned long long)crumb_heap);
            }
            dprintf(2, "[census-hold] idx=%d port=0x%x teb=0x%llx tid=%04x HOLDS fexlock @0x%llx "
                    "run_state=%d susp=%d pc=0x%llx lr=0x%llx sp=0x%llx bt: %llx %llx %llx %llx %llx %llx %llx %llx\n",
                    i, cand, (unsigned long long)cteb, ctid, (unsigned long long)held,
                    bi.run_state, bi.suspend_count,
                    (unsigned long long)arm_thread_state64_get_pc( st ),
                    (unsigned long long)st.__lr,
                    (unsigned long long)arm_thread_state64_get_sp( st ),
                    (unsigned long long)frames[0], (unsigned long long)frames[1],
                    (unsigned long long)frames[2], (unsigned long long)frames[3],
                    (unsigned long long)frames[4], (unsigned long long)frames[5],
                    (unsigned long long)frames[6], (unsigned long long)frames[7]);
            /* ml443: what is the HOLDER itself waiting on?  ml442 showed
             * CrBrowserMain parked in an alert-wait while holding the
             * CodeInvalidationMutex write-locked, but its park never crossed
             * [waiters]' 60s bar (wakes keep resetting the age) — x-ref the
             * live registration and print its address + lock word NOW. */
            {
                extern int ios_alert_waiter_lookup( unsigned int tid, const void **addr, int *age_s, int *inf );
                const void *waddr = 0;
                int wage = 0, winf = 0;
                if (ios_alert_waiter_lookup( (unsigned int)ctid, &waddr, &wage, &winf ))
                {
                    unsigned int w = 0xdeaddead;
                    if (!((uintptr_t)waddr & 1) && (uintptr_t)waddr > 0x10000 && (uintptr_t)waddr < 0x8000000000ULL)
                    {
                        uint64_t al = (uintptr_t)waddr & ~3ULL;
                        uint32_t val = 0;
                        mach_vm_size_t wgot = 0;
                        if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)al, 4,
                                                    (mach_vm_address_t)&val, &wgot ) == KERN_SUCCESS && wgot == 4)
                            w = val;
                    }
                    dprintf(2, "[census-hold]   WAITING-ON addr=%p age=%ds %s w=%08x rev=ml443\n",
                            waddr, wage, winf ? "INF" : "TMO", w);
                }
            }
        }
    }

    if (total_logged >= 60) return;
    for (i = count - 1; i >= 0; i--)
    {
        thread_t cand = ios_thread_registry[i].mach_thread;
        arm_thread_state64_t st;
        mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
        struct thread_basic_info bi;
        mach_msg_type_number_t bcnt = THREAD_BASIC_INFO_COUNT;
        uint64_t fp, frames[8] = { 0 };
        uint32_t lockval = 0;
        vm_size_t got;
        int fi, dup = 0;
        if (!cand) continue;
        for (s = 0; s < nseen; s++) if (seen[s] == cand) dup = 1;
        if (dup) continue;
        if (thread_info( cand, THREAD_BASIC_INFO, (thread_info_t)&bi, &bcnt ) != KERN_SUCCESS)
            continue;
        if (bi.run_state != TH_STATE_WAITING) continue;
        if (thread_get_state( cand, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt ) != KERN_SUCCESS)
            continue;
        if (st.__x[0] != 0x1000001) continue;   /* UL_COMPARE_AND_WAIT|ULF_NO_ERRNO */
        fp = st.__fp;
        for (fi = 0; fi < 8 && fp > 0x1000; fi++)
        {
            uint64_t rec[2] = { 0, 0 };
            got = 0;
            if (vm_read_overwrite( mach_task_self(), (vm_address_t)fp, sizeof(rec),
                                   (vm_address_t)rec, &got ) != KERN_SUCCESS) break;
            frames[fi] = rec[1];
            fp = rec[0];
        }
        if (st.__x[1] > 0x1000)
            vm_read_overwrite( mach_task_self(), (vm_address_t)st.__x[1], sizeof(lockval),
                               (vm_address_t)&lockval, &got );
        total_logged++;
        if (nseen < 64) seen[nseen++] = cand;
        dprintf(2, "[lock-census] idx=%d port=0x%x teb=%p pc=0x%llx lr=0x%llx x1=0x%llx "
                "x2=0x%llx lockval=0x%x bt: %llx %llx %llx %llx %llx %llx %llx %llx\n",
                i, cand, (void *)ios_thread_registry[i].teb,
                (unsigned long long)arm_thread_state64_get_pc( st ),
                (unsigned long long)st.__lr,
                (unsigned long long)st.__x[1],
                (unsigned long long)st.__x[2], lockval,
                (unsigned long long)frames[0], (unsigned long long)frames[1],
                (unsigned long long)frames[2], (unsigned long long)frames[3],
                (unsigned long long)frames[4], (unsigned long long)frames[5],
                (unsigned long long)frames[6], (unsigned long long)frames[7]);
        if (total_logged >= 60) return;
    }
}

/* ml406: beacon TEB list shared with sync.c's [alert-unix] tap.  The pump
 * entered an alert-wait post-wake WITHOUT passing the EC-side [pump-op]
 * wrapper (native-aarch64-ntdll routes bypass it); unix-side
 * NtWaitForAlertByThreadId is the choke point for ALL PE routes. */
uintptr_t ios_beacon_teb_list[4];
int ios_beacon_teb_count;

#define IOS_PUMP_MAX 4
extern void ios_alert_ring_dump(void);   /* ml439 (#74): unix/sync.c alert-flow probe */
extern void ios_alert_waiter_dump(void); /* ml440 (#74): >60s parkers + their lock words */
void ios_pump_sample(void)
{
    static int samples;
    static int nbeacons;
    static thread_t pump_port[IOS_PUMP_MAX];   /* 0 = needs (re-)resolve */
    static uintptr_t pump_teb[IOS_PUMP_MAX];
    int i, b;
    int count = __sync_fetch_and_add(&ios_thread_count, 0);
    if (count > IOS_MAX_WINE_THREADS) count = IOS_MAX_WINE_THREADS;

    ios_alert_ring_dump();   /* ml439: static ring during a parked-stall = wakes dying PE-side */
    ios_alert_waiter_dump(); /* ml440: name the lock the parked crowd is starving on */
    /* ml447: orphan-lock detector — collect live threads' TEB Instr[6]
     * CodeBufferWriteMutex stamps; a held-exclusive SRW with >=3 waiters that
     * NO live thread stamps (3 cycles running) has a vanished dead owner. */
    {
        extern void ios_orphan_check( const unsigned long long *live_stamps, int nstamps );
        unsigned long long stamps[64];
        int ns = 0, si;
        for (si = 0; si < count && ns < 64; si++)
        {
            struct thread_basic_info sbi;
            mach_msg_type_number_t scnt = THREAD_BASIC_INFO_COUNT;
            uint64_t stamp = 0;
            mach_vm_size_t sgot = 0;
            uintptr_t steb = ios_thread_registry[si].teb;
            if (!ios_thread_registry[si].mach_thread || !steb) continue;
            if (thread_info( ios_thread_registry[si].mach_thread, THREAD_BASIC_INFO,
                             (thread_info_t)&sbi, &scnt ) != KERN_SUCCESS) continue;
            if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(steb + 0x16e8), 8,
                                        (mach_vm_address_t)&stamp, &sgot ) != KERN_SUCCESS || sgot != 8) continue;
            if (stamp)
            {
                /* ml448: NAME the live S-holder — ml447 run showed the orphan
                 * detector correctly silent (holder alive+stamped) while the
                 * whole world queued behind S; this line is the only view of
                 * who owns it and pairs with its thread-stacks/census rows. */
                uint32_t stid = 0;
                mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(steb + 0x48), 4,
                                        (mach_vm_address_t)&stid, &sgot );
                dprintf(2, "[stamp-set] LIVE S-holder tid=%04x teb=0x%llx mutex=0x%llx rev=ml448\n",
                        stid, (unsigned long long)steb, (unsigned long long)stamp);
                stamps[ns++] = stamp;
            }
            /* ml468: the ml467 false orphan was a FEX lock whose LIVE holder
             * stamps Instrumentation[8] (fexlock, TEB+0x16f8), not [6] — feed
             * those stamps into the same live set so ios_orphan_check never
             * strikes a lock a running thread admits to holding. */
            if (ns < 64)
            {
                uint64_t fstamp = 0;
                if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(steb + 0x16f8), 8,
                                            (mach_vm_address_t)&fstamp, &sgot ) == KERN_SUCCESS
                    && sgot == 8 && fstamp)
                    stamps[ns++] = fstamp;
            }
        }
        ios_orphan_check( stamps, ns );
    }
    ios_lock_census();
    if (samples >= 120) return;
    /* discover beacon TEBs (ml399: server thread and pump can differ) */
    if (nbeacons < IOS_PUMP_MAX)
    {
        for (i = 0; i < count && nbeacons < IOS_PUMP_MAX; i++)
        {
            uintptr_t teb = ios_thread_registry[i].teb;
            uint64_t val = 0;
            vm_size_t got = 0;
            int known = 0;
            if (!teb) continue;
            for (b = 0; b < nbeacons; b++) if (pump_teb[b] == teb) known = 1;
            if (known) continue;
            if (vm_read_overwrite( mach_task_self(),
                    (vm_address_t)(teb + offsetof(TEB, Instrumentation) + 10 * sizeof(void *)),
                    sizeof(val), (vm_address_t)&val, &got ) != KERN_SUCCESS) continue;
            if (val == 0x504d5550)
            {
                pump_teb[nbeacons] = teb;
                pump_port[nbeacons] = 0;
                ios_beacon_teb_list[nbeacons] = teb;
                dprintf(2, "[pump-sample] beacon %d teb=%p (idx=%d)\n", nbeacons, (void *)teb, i);
                nbeacons++;
                ios_beacon_teb_count = nbeacons;
            }
        }
        if (!nbeacons) return;
    }
    /* resolve each beacon TEB to the NEWEST registry entry with a LIVE port.
     * ml402: TEB VAs recycle; forward first-match picked DEAD threads' stale
     * entries (dead names -> MACH_SEND_INVALID_DEST forever).  Scan backwards
     * and validate with thread_info before accepting; a beacon whose port
     * dies gets re-resolved next cycle, and "no live entry" is itself the
     * thread-death verdict. */
    for (b = 0; b < nbeacons; b++)
    {
        if (pump_port[b]) continue;
        for (i = count - 1; i >= 0; i--)
        {
            thread_t cand = ios_thread_registry[i].mach_thread;
            struct thread_basic_info bi;
            mach_msg_type_number_t bcnt = THREAD_BASIC_INFO_COUNT;
            if (ios_thread_registry[i].teb != pump_teb[b] || !cand) continue;
            if (thread_info( cand, THREAD_BASIC_INFO, (thread_info_t)&bi, &bcnt ) != KERN_SUCCESS)
                continue;
            pump_port[b] = cand;
            dprintf(2, "[pump-sample] beacon %d RESOLVED idx=%d port=0x%x teb=%p\n",
                    b, i, cand, (void *)pump_teb[b]);
            break;
        }
        if (!pump_port[b])
            dprintf(2, "[pump-sample] beacon %d teb=%p NO LIVE ENTRY (thread dead?)\n",
                    b, (void *)pump_teb[b]);
    }
    for (b = 0; b < nbeacons; b++)
    {
        arm_thread_state64_t st;
        mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
        struct thread_basic_info bi;
        mach_msg_type_number_t bcnt = THREAD_BASIC_INFO_COUNT;
        kern_return_t kr1, kr2;
        if (!pump_port[b]) continue;
        kr1 = thread_get_state( pump_port[b], ARM_THREAD_STATE64, (thread_state_t)&st, &cnt );
        kr2 = thread_info( pump_port[b], THREAD_BASIC_INFO, (thread_info_t)&bi, &bcnt );
        samples++;
        if (kr1 == KERN_SUCCESS)
        {
            /* ml404: both IPC threads park at the same shared-cache pc with
             * x0=0x1000001 (UL_COMPARE_AND_WAIT|ULF_NO_ERRNO = __ulock_wait).
             * Add the discriminators: x16 = trap number, x1 = ulock ADDRESS
             * (an os_unfair_lock word stores its OWNER's thread name), the
             * lock word's current value, and an 8-frame fp walk so the
             * non-shared-cache frames name the calling subsystem. All reads
             * fault-safe. */
            uint64_t fp = st.__fp;
            uint64_t frames[8] = { 0 };
            uint32_t lockval = 0;
            int fi;
            vm_size_t got;
            for (fi = 0; fi < 8 && fp > 0x1000; fi++)
            {
                uint64_t rec[2] = { 0, 0 };
                got = 0;
                if (vm_read_overwrite( mach_task_self(), (vm_address_t)fp, sizeof(rec),
                                       (vm_address_t)rec, &got ) != KERN_SUCCESS) break;
                frames[fi] = rec[1];
                fp = rec[0];
            }
            if (st.__x[1] > 0x1000)
                vm_read_overwrite( mach_task_self(), (vm_address_t)st.__x[1], sizeof(lockval),
                                   (vm_address_t)&lockval, &got );
            dprintf(2, "[pump-sample] b%d #%d pc=0x%llx lr=0x%llx sp=0x%llx x0=0x%llx "
                    "x1=0x%llx x2=0x%llx x16=0x%llx lockval=0x%x run_state=%d flags=%d "
                    "bt: %llx %llx %llx %llx %llx %llx %llx %llx\n",
                    b, samples,
                    (unsigned long long)arm_thread_state64_get_pc( st ),
                    (unsigned long long)st.__lr,
                    (unsigned long long)arm_thread_state64_get_sp( st ),
                    (unsigned long long)st.__x[0],
                    (unsigned long long)st.__x[1],
                    (unsigned long long)st.__x[2],
                    (unsigned long long)st.__x[16], lockval,
                    kr2 == KERN_SUCCESS ? bi.run_state : -1,
                    kr2 == KERN_SUCCESS ? bi.flags : -1,
                    (unsigned long long)frames[0], (unsigned long long)frames[1],
                    (unsigned long long)frames[2], (unsigned long long)frames[3],
                    (unsigned long long)frames[4], (unsigned long long)frames[5],
                    (unsigned long long)frames[6], (unsigned long long)frames[7]);
        }
        else
        {
            dprintf(2, "[pump-sample] b%d #%d port=0x%x DEAD kr1=%d -> re-resolving\n",
                    b, samples, pump_port[b], kr1);
            pump_port[b] = 0;
        }
    }
}

/* Diagnostic: first .data fault captured by Mach handler */
volatile uint64_t ios_exc_data_fault_pc = 0;
volatile uint64_t ios_exc_data_fault_lr = 0;
volatile uint64_t ios_exc_data_fault_sp = 0;
volatile uint64_t ios_exc_data_fault_frame_ptr = 0;
volatile uint64_t ios_exc_data_fault_frame_pc = 0;
volatile int ios_exc_data_fault_count = 0;
/* Additional register capture for first .data fault */
volatile uint64_t ios_exc_data_x0 = 0;
volatile uint64_t ios_exc_data_x1 = 0;
volatile uint64_t ios_exc_data_x2 = 0;
volatile uint64_t ios_exc_data_x3 = 0;
volatile uint64_t ios_exc_data_x16 = 0;
volatile uint64_t ios_exc_data_x17 = 0;
volatile uint64_t ios_exc_data_x18 = 0;
volatile uint64_t ios_exc_data_x29 = 0;
volatile uint32_t ios_exc_data_insn_at_lr = 0; /* instruction at LR (caller) */

/* Raw Mach exception message structures (64-bit codes) */
#pragma pack(4)
typedef struct {
    mach_msg_header_t head;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    NDR_record_t ndr;
    exception_type_t exception;
    mach_msg_type_number_t code_count;
    int64_t code[2];
} ios_exc_request_t;

typedef struct {
    mach_msg_header_t head;
    NDR_record_t ndr;
    kern_return_t ret_code;
} ios_exc_reply_t;
#pragma pack()

/* iOS-Madeira ml329 (#53 discriminator): ring of pages the reclaim-recovery path
 * zero-filled. Written by the recovery site, dumped by ios_reclaim_pages_report()
 * from the fatal-SEGV path so "did iOS eat this allocator's memory?" is answered
 * from recorded fact rather than inferred from Wine's vprot (which reads 0 for
 * pages FEX allocated through its own VirtualAlloc2 path, so the existing verdict
 * string says "zeros OK" regardless and cannot settle the question). */
#define IOS_RRPAGE_MAX 128
static volatile unsigned long long ios_rr_pages[IOS_RRPAGE_MAX];
static volatile unsigned ios_rr_pages_n;

void ios_reclaim_note_page( unsigned long long pg );
void ios_reclaim_note_page( unsigned long long pg )
{
    unsigned slot = __sync_fetch_and_add( &ios_rr_pages_n, 1 );
    ios_rr_pages[slot % IOS_RRPAGE_MAX] = pg;
}

void ios_reclaim_pages_report( const char *when, unsigned long long fault_addr );
void ios_reclaim_pages_report( const char *when, unsigned long long fault_addr )
{
    unsigned total = ios_rr_pages_n;
    unsigned shown = total < IOS_RRPAGE_MAX ? total : IOS_RRPAGE_MAX;
    unsigned i, in_fex_band = 0;

    for (i = 0; i < shown; i++)
    {
        unsigned long long pg = ios_rr_pages[i];
        if (pg >= 0x7C00000000ULL && pg < 0x8000000000ULL) in_fex_band++;
    }
    dprintf( STDERR_FILENO,
             "[reclaim-census] rev=ml329 at=%s fault=0x%llx : %u pages zero-filled this run, "
             "%u of the last %u are in FEX's host heap band [0x7c,0x80) -- %s\n",
             when, fault_addr, total, in_fex_band, shown,
             in_fex_band ? "FEX HEAP WAS ZEROED, #53 is live for this crash"
                         : "none in FEX's heap; #53 does NOT explain this crash" );
    for (i = 0; i < shown && i < 16; i++)
        dprintf( STDERR_FILENO, "[reclaim-census]   pg[%u]=0x%llx%s\n", i,
                 (unsigned long long)ios_rr_pages[i],
                 (ios_rr_pages[i] >= 0x7C00000000ULL && ios_rr_pages[i] < 0x8000000000ULL) ? "  <== FEX heap" : "" );
}

/* ml369 (#63): defined after setup_exception (needs save_context and
 * struct exc_stack_layout); used by the exception loop below. */
static int ios_mach_deliver_guest_exception( thread_t thread, arm_thread_state64_t *state,
                                             arm_neon_state64_t *neon, int have_neon,
                                             int exception, uintptr_t fault_addr,
                                             uintptr_t thread_teb );

#ifdef WINE_IOS
/***********************************************************************
 *           ios_dump_guest_callers                              (ml1002)
 *
 * Who, in guest code, is calling us right now?
 *
 * rdr71 eliminated the three cheap explanations for the launcher failure:
 * export coverage is complete, the sub-floor emulator serviced 987,137
 * accesses with 0 misservice, and the self-modifying writes verifiably land
 * (ciphertext in, valid x86-64 out). What remains is the one structural
 * divergence from Windows/CrossOver: EMP.dll wants base 0x13000000, has its
 * relocations STRIPPED, and iOS's mandatory 4 GB __PAGEZERO makes that address
 * unmappable, so we map it high and service every access through the ml938
 * window.
 *
 * So the question worth answering is which module is running the API-resolution
 * loop that produces the failing LoadLibrary names -- the sub-floor EMP.dll at
 * 0x13xxxxxx, or the main image at 0x140xxxxxx. That is a fact about the guest,
 * and FEX's callret stack already records it; the fault path prints it as
 * [x86_callret]. This makes the same walk callable from ordinary Wine code.
 *
 * x28 is only a FEX frame on a guest thread, so this declines on any other
 * thread rather than inventing a chain. Frame layout per the fault path:
 * x28+0x18 = guest rip, gregs[0..15] follow.
 */
void ios_dump_guest_callers( const char *tag, unsigned long long x28 )
{
    uint64_t cret = 0;
    uint64_t cr[12];
    mach_vm_size_t got = 0;
    unsigned i;

    /* x28 comes from the SAVED context, never from the live register: inside a
     * signal handler the live x28 is whatever the handler's own code left
     * there, not the guest's FEX frame. */
    if (x28 < 0x10000 || x28 >= 0xfffffff000000000ULL) return;

    /* callret_sp lives in the FEX frame; read it the same way the fault path
     * does, through a failure-returning copy so a stale x28 cannot fault here. */
    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(x28 + 0xb0),
                                8, (mach_vm_address_t)&cret, &got ) != KERN_SUCCESS || got != 8)
        return;
    if (cret < 0x10000 || cret >= 0xfffffff000000000ULL) return;
    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)cret,
                                sizeof(cr), (mach_vm_address_t)cr, &got ) != KERN_SUCCESS ||
        got != sizeof(cr))
        return;

    /* ml1051: 16,753 of these (x7 lines) filled a quarter of a 46 MB log and the
     * log pipeline was ~12% of all running CPU samples. First 24, then 1 in 2000. */
    { static unsigned long ml1051_n; unsigned long k = __sync_add_and_fetch( &ml1051_n, 1 );
      if (k > 24 && (k % 2000)) return; }
    dprintf( 2, "ml1002: [%s] guest callers (most recent first), x28=%#llx callret=%#llx:\n",
             tag, (unsigned long long)x28, (unsigned long long)cret );
    for (i = 0; i < 6; i++)
    {
        uint64_t rip = cr[i * 2];
        const char *where = "?";
        if (rip >= 0x13000000ULL && rip < 0x1320f000ULL) where = "SUB-FLOOR EMP.dll (emulated window)";
        else if (rip >= 0x140000000ULL && rip < 0x147528000ULL) where = "main image";
        else if (rip >= 0x100000000ULL) where = "high module";
        dprintf( 2, "ml1002:   [%u] retRIP=%#llx  %s\n", i, (unsigned long long)rip, where );
    }
}


/* Signal-safe 32/64-bit CAS core, shared semantics with the BSD alias path.
 * Caller establishes full alias coverage. FP/LR encodings deliberately
 * decline: Darwin's __x array contains only x0..x28. No Wine logging here. */
static int ios_mach_emulate_cas(uint32_t insn, uintptr_t rw_addr, uint64_t gpr[29])
{
    unsigned rs, rt, width;
    uint64_t expected, desired;
    if ((insn & 0xbfa07c00u) != 0x88a07c00u) return 0;
    rs = (insn >> 16) & 31;
    rt = insn & 31;
    width = (insn & 0x40000000u) ? 8 : 4;
    if ((rs >= 29 && rs != 31) || (rt >= 29 && rt != 31)) return 0;
    if (!rw_addr || (rw_addr & (width - 1))) return 0;
    expected = rs == 31 ? 0 : gpr[rs];
    desired = rt == 31 ? 0 : gpr[rt];
    if (width == 8)
    {
        __atomic_compare_exchange_n((uint64_t *)rw_addr, &expected, desired,
                                    0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    }
    else
    {
        uint32_t expected32 = (uint32_t)expected;
        __atomic_compare_exchange_n((uint32_t *)rw_addr, &expected32, (uint32_t)desired,
                                    0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
        expected = expected32;
    }
    if (rs != 31) gpr[rs] = expected;
    return 1;
}

/* ml938/ml939: defined far below, next to the store emulator they reuse.
 * Declared here because the Mach exception thread is the primary caller and
 * sits earlier in the file. */
static uintptr_t ios_subfloor_translate( uint64_t addr, void *peb );
extern void *ios_jit_current_peb(void);   /* virtual_ios.c */
static int ios_subfloor_service( ucontext_t *ctx, void *fault_addr, const char *via, void *peb );

/* ml974: is the ucontext's NEON state real?
 *
 * The Mach path builds a synthetic ucontext, memsets it to zero and fills
 * __ns ONLY `if (have_neon)` -- i.e. only when
 * thread_get_state(ARM_NEON_STATE64) succeeded. Every SIMD emulation path
 * reads or writes __ns.__v[], so when that fetch fails the zeroed block is
 * indistinguishable from genuinely zero vectors: a SIMD store would write
 * zeros over guest data, and a SIMD load would write into a block that is
 * never handed back. Both are silent corruption.
 *
 * Thread-local, defaulting to 1, so the signal/BUS callers -- which pass a
 * real ucontext from the kernel -- are unaffected and cannot race the Mach
 * thread's value. */
static __thread int ios_neon_valid = 1;
#endif

/* ml982: fetch the faulting instruction without dereferencing it.
 *
 * Three sites in the Mach handler did `*(uint32_t *)fault_pc` behind nothing
 * stronger than `fault_pc >= 0x100000000`, which only says the address is above
 * the iOS floor -- not that the page is mapped or readable. This is the handler
 * for faults that are routinely unmapped or non-executable PCs, and the shared
 * exception port is installed at task level, so a fault taken HERE waits on
 * this same handler and the process stops dead. That is the failure Astra
 * traced in rdr44-52, via a different unsafe read in the same function.
 *
 * Returns 0 and leaves *out at 0 when the word cannot be read. 0 matches none
 * of the encoding masks at any caller, so control flow is unchanged -- an
 * unreadable PC now behaves exactly like an unrecognised instruction instead of
 * wedging the handler. */
static int ios_fault_read_insn( uint64_t fault_pc, uint32_t *out )
{
    mach_vm_size_t got = 0;

    *out = 0;
    if (fault_pc < 0x100000000ULL) return 0;
    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)fault_pc, 4,
                                (mach_vm_address_t)out, &got ) != KERN_SUCCESS || got != 4)
    {
        static int unread_n;
        *out = 0;
        if (unread_n++ < 8)
            dprintf( 2, "[mach_exc] ml982 instruction at pc=%#llx UNREADABLE -- treating as an "
                     "unrecognised encoding rather than faulting inside the handler\n",
                     (unsigned long long)fault_pc );
        return 0;
    }
    return 1;
}

/* x18-derived base register.
 *
 * Wine's EC kernelbase TlsGetValue is `add x8, x18, w0, uxtw #3;
 * ldr x0, [x8, #0x1480]`: the TEB address is copied into another register one
 * instruction before the access, so when iOS has zeroed x18 the fault's base
 * register is x8, not x18, and the x18 emulation in the Mach handler declines
 * (Crysis Remastered worker thread: fault at 0x1570 = TLS slot 30, then the
 * process died). When the instruction right before the fault is an ADD/MOV
 * that wrote exactly this base register from x18, the base holds
 * (0 + offset) and fault_addr is the TEB offset, so the same TEB-relative
 * emulation is correct. Only ADD (extended/shifted register or immediate) and
 * MOV Xd,X18; the other operand must not be the destination (it still holds
 * the value the ADD used). */
static int ios_x18_derived_base( uint64_t fault_pc, int rn )
{
    uint32_t p;
    int rd, pn, pm;

    if (rn == 18 || rn >= 29 || !ios_fault_read_insn( fault_pc - 4, &p )) return 0;
    rd = p & 31; pn = (p >> 5) & 31; pm = (p >> 16) & 31;
    if (rd != rn) return 0;
    if ((p & 0xffe00000u) == 0x8b200000u) return pn == 18 && pm != rd;           /* ADD Xd, X18, Wm/Xm, ext */
    if ((p & 0xff200000u) == 0x8b000000u) return (pn == 18 && pm != rd) ||       /* ADD Xd, X18, Xm, shift */
                                                 (pm == 18 && pn != rd && !((p >> 10) & 0x3f));
    if ((p & 0xff800000u) == 0x91000000u) return pn == 18;                       /* ADD Xd, X18, #imm */
    if ((p & 0xffffffe0u) == (0xaa0003e0u | (18u << 16))) return 1;              /* MOV Xd, X18 */
    return 0;
}

/* ml1242: the JIT-pool dump is sparse, and MADEIRA_JIT_DUMP=0 turns it off.
 *
 * Both one-shot dumps used to write the whole 896MB RW alias. The production
 * pool is not NO_FOOTPRINT (see jit_make_region_no_footprint), and a read fault
 * on an untouched page of it materialises a real zero page, so the dump alone
 * charged ~600MB to phys_footprint: Hollow Knight went 2169 -> 2755MB while it
 * ran and hit the 4096MB jetsam limit four seconds later. Pages mincore()
 * reports neither resident nor paged out were never written; they stay holes,
 * so file offsets still equal pool offsets (head copies and tail CodeBuffers). */
static void ios_dump_jit_pool( const char *why )
{
    extern void *ios_jit_rw_base_global;
    extern size_t ios_jit_pool_size_global;
    const size_t chunk = 0x100000;
    size_t ps = vm_page_size, total = ios_jit_pool_size_global, written = 0, off, i;
    const char *docs;
    char path[512], vec[256];   /* one byte per page of a 1MB chunk, down to 4KB pages */
    int fd;

    const char *jd = getenv( "MADEIRA_JIT_DUMP" );
    /* 0: no Documents/fex-jit-dump.bin; by default the JIT pool is written (sparse) on the
     * first mach UNHANDLED / SIGILL, and pulled with the log (ml1242) */
    if ((jd && jd[0] == '0') || !ios_jit_rw_base_global || !total) return;
    docs = getenv( "MADEIRA_DOCS_DIR" );
    snprintf( path, sizeof(path), "%s/fex-jit-dump.bin", docs ? docs : "/tmp" );
    if ((fd = open( path, O_WRONLY | O_CREAT | O_TRUNC, 0644 )) < 0)
    {
        dprintf( 2, "[jit-dump] ml1242 %s: open failed errno=%d path=%s\n", why, errno, path );
        return;
    }
    for (off = 0; off < total; off += chunk)
    {
        size_t len = total - off < chunk ? total - off : chunk;
        char *base = (char *)ios_jit_rw_base_global + off;
        int have_vec = len / ps <= sizeof(vec) && !mincore( base, len, vec );

        for (i = 0; i < len; i += ps)
        {
            size_t n = len - i < ps ? len - i : ps;
            if (have_vec && !(vec[i / ps] & (MINCORE_INCORE | MINCORE_PAGED_OUT))) continue;
            if (pwrite( fd, base + i, n, off + i ) != (ssize_t)n) goto done;
            written += n;
        }
    }
done:
    ftruncate( fd, total );
    close( fd );
    dprintf( 2, "[jit-dump] ml1242 %s: wrote %zu of %zu pool bytes to %s (untouched pages left as holes)\n",
             why, written, total, path );
}

/* The [fault-stuck] loop breaker in ios_mach_exception_thread keeps its state per thread, in
 * 16 slots chosen by thread as the Mach-path delivery's redelivery guard does, and every
 * exception delivered to the guest starts that thread's count again. It was one app-wide
 * (page, pc, address) count, so faults of many threads at one instruction, or one thread's
 * handled int3 or single-step exceptions there, read as a livelock: the thread was diverted
 * to abort_thread and no exception reached the program. Windows delivers every one. A
 * livelock is one thread re-faulting with no delivery in between; that is still broken. */
static volatile unsigned ios_guest_deliv_seq[16];

static inline int ios_fault_slot( uint64_t thread )
{
    return (int)((thread * 0x9E3779B97F4A7C15ull) >> 60);
}

static inline void ios_note_guest_delivery( uint64_t thread )
{
    __atomic_add_fetch( &ios_guest_deliv_seq[ios_fault_slot( thread )], 1, __ATOMIC_RELEASE );
}

static void *ios_mach_exception_thread( void *arg )
{
    mach_port_t port = (mach_port_t)(uintptr_t)arg;

    /* Name this thread for debugging */
    pthread_setname_np("wine-x18-exc");

    /* 2026-07-04 perf: this thread is effectively an interrupt handler —
     * every STR emulation, exec-fault redirect, and USD read (~2,600 per
     * present-group in gameplay) suspends the faulting thread until THIS
     * thread services the message. At default QoS it is E-core-eligible
     * and can be preempted by every USER_INTERACTIVE game thread — each
     * fault then pays scheduling latency on top of handling cost. Run it
     * as hot as its clients. */
    pthread_set_qos_class_self_np( QOS_CLASS_USER_INTERACTIVE, 0 );

    ios_exc_thread_alive = 1;

    for (;;)
    {
        /* Use a large buffer to handle any message variant */
        union {
            ios_exc_request_t typed;
            char buf[1024];
        } msg;
        kern_return_t kr = mach_msg( &msg.typed.head, MACH_RCV_MSG, 0,
                                      sizeof(msg), port,
                                      MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL );
        if (kr != KERN_SUCCESS) continue;

        ios_exc_request_t *req = &msg.typed;
        ios_exc_msg_count++;
        ios_cur_fault_port = req->thread.name;              /* ml690 */
        ios_store_fault_t0 = mach_absolute_time();          /* ml680 */

        thread_t thread = req->thread.name;
        int handled = 0;

        /* 2026-07-03 storm probe: ~40K Mach exceptions PER PRESENT measured
         * in the menu phase (~all of the 1.4s frame time at ~33us each).
         * Sample every 4096th message: exception type + faulting PC + insn
         * so the trap source is nameable from one run. */
        /* ml649: gate the WORK. This costs two Mach round-trips (thread_get_state
         * + vm_read_overwrite) per sample, so checking the flag before them is the
         * point — checking it before the dprintf would save nothing. */
        if ((ios_exc_msg_count % 200000) == 0 && ios_store_fault_n)
        {   /* ml680: mach_timebase converts ticks to ns once. ONE handler thread
             * serves every Wine thread, so this total is a hard serialised
             * ceiling on the whole app, not a per-thread cost. */
            /* mach_timebase_info_data_t is not visible in this TU's header set;
             * the struct is two uint32s and the call takes it by pointer. */
            struct { unsigned int numer, denom; } tb = {0, 0};
            extern int mach_timebase_info(void *);
            unsigned long long n = ios_store_fault_n, tk = ios_store_fault_ticks;
            mach_timebase_info(&tb);
            {
                unsigned long long ns = tb.denom ? (tk * tb.numer) / tb.denom : tk;
                dprintf(STDERR_FILENO,
                    "[fault-cost] ml685 emulated-store faults=%llu total=%llu ms avg=%llu ns "
                    "dropped=%llu (one handler thread serves all threads)\n",
                    n, ns / 1000000ull, ns / n, ios_store_fault_dropped);
            }
        }
        if (madeira_diag_enabled && (ios_exc_msg_count & 0xFFF) == 0)
        {
            arm_thread_state64_t pstate;
            mach_msg_type_number_t pcount = ARM_THREAD_STATE64_COUNT;
            if (thread_get_state( thread, ARM_THREAD_STATE64,
                                  (thread_state_t)&pstate, &pcount ) == KERN_SUCCESS)
            {
                uint64_t ppc = arm_thread_state64_get_pc( pstate );
                uint32_t pinsn = 0;
                vm_size_t psz = sizeof(pinsn);
                vm_read_overwrite( mach_task_self(), ppc, sizeof(pinsn),
                                   (vm_address_t)&pinsn, &psz );
                dprintf(STDERR_FILENO,
                        "[EXC_SAMPLE] #%d exc=%d code0=0x%llx pc=0x%llx insn=0x%08x lr=0x%llx\n",
                        ios_exc_msg_count, req->exception,
                        (unsigned long long)(req->code_count > 1 ? req->code[1] : req->code[0]),
                        (unsigned long long)ppc, pinsn,
                        (unsigned long long)pstate.__lr);
            }
        }

        /* ml523 (#67): count EXC_BREAKPOINT arrivals and name the BRK immediate.
         *
         * These used to go to StikDebug's task port. FEX's JIT emits
         * `brk #0xCAFE` (0xd4395fc0) inline for Arm64JITCore::EmitSuspendInterruptCheck,
         * so every thread-pause check is a trap the debugger had to service —
         * and a debugger pegged at 97% in its own busy-wait takes ~54s to reply
         * while the WHOLE TASK is stopped waiting. That is #67.
         *
         * We now own the mask and decline (handled stays 0 => KERN_FAILURE),
         * which escalates to the host default => BSD SIGTRAP => trap_handler,
         * where the 0xf00d and generic-trap cases already live. That is the
         * same end state madeira-jit.js produced with forwardSignal(), minus the
         * round-trip to a starved debugger.
         *
         * Bounded so a suspend-check storm cannot flood the log, but the FIRST
         * ones always print — they are what must line up against a [freeze] GAP. */
        if (req->exception == EXC_BREAKPOINT)
        {
            static volatile int bp_count;
            int n = __sync_add_and_fetch( &bp_count, 1 );
            if (n <= 12 || (n % 500) == 0)
            {
                arm_thread_state64_t bs;
                mach_msg_type_number_t bc = ARM_THREAD_STATE64_COUNT;
                uint64_t bpc = 0; uint32_t binsn = 0;
                if (thread_get_state( thread, ARM_THREAD_STATE64,
                                      (thread_state_t)&bs, &bc ) == KERN_SUCCESS)
                {
                    vm_size_t bsz = sizeof(binsn);
                    bpc = arm_thread_state64_get_pc( bs );
                    vm_read_overwrite( mach_task_self(), bpc, sizeof(binsn),
                                       (vm_address_t)&binsn, &bsz );
                }
                dprintf(STDERR_FILENO,
                        "[task-exc] BREAKPOINT #%d pc=0x%llx insn=0x%08x imm=0x%x %s rev=ml523\n",
                        n, (unsigned long long)bpc, binsn, (binsn >> 5) & 0xffff,
                        binsn == 0xd4395fc0 ? "FEX-SuspendCheck(0xCAFE)"
                        : binsn == 0xd43e01a0 ? "StikDebug-protocol(0xf00d)" : "other");

                /* ml559: NAME the trapping image.
                 *
                 * ml558 died on `BRK #1` (== __builtin_trap) at 0x191d52284 on a
                 * thread that is not ours — i.e. inside a SYSTEM library — and the
                 * whole task went with it, so no in-process probe could report why.
                 * A bare hex pc left me guessing which library it was, and guessing
                 * is exactly what has been wrong repeatedly here. dladdr costs
                 * nothing and turns the address into an answer. LR names the caller,
                 * which is the part that actually identifies the failing operation. */
                if (bpc && ((binsn & 0xffe0001fu) == 0xd4200000u))
                {
                    Dl_info di_pc, di_lr;
                    uint64_t blr = arm_thread_state64_get_lr( bs );
                    int okp = dladdr( (void *)(uintptr_t)bpc, &di_pc );
                    int okl = dladdr( (void *)(uintptr_t)blr, &di_lr );
                    dprintf(STDERR_FILENO,
                            "[task-exc]   TRAP-SYM pc=%s`%s+0x%llx  lr=0x%llx %s`%s+0x%llx rev=ml559\n",
                            okp && di_pc.dli_fname ? di_pc.dli_fname : "?",
                            okp && di_pc.dli_sname ? di_pc.dli_sname : "?",
                            okp && di_pc.dli_saddr ? (unsigned long long)(bpc - (uintptr_t)di_pc.dli_saddr) : 0ull,
                            (unsigned long long)blr,
                            okl && di_lr.dli_fname ? di_lr.dli_fname : "?",
                            okl && di_lr.dli_sname ? di_lr.dli_sname : "?",
                            okl && di_lr.dli_saddr ? (unsigned long long)(blr - (uintptr_t)di_lr.dli_saddr) : 0ull);

                    /* ml565: is this malloc trap OUT OF MEMORY, or real corruption?
                     *
                     * The trap is libsystem_malloc called from wineserver's
                     * alloc_object. Across 11 runs it separates PERFECTLY by memory
                     * footprint — traps at 3197-3339 MB, never at 3015-3114 MB — while
                     * run LENGTH does not predict it (ml560b ran 95 cycles, 5x longer
                     * than most, at the lowest footprint of all, and never trapped).
                     * So the mechanism is likelier pressure than accumulated damage,
                     * but that is unproven and these are the numbers that settle it.
                     *
                     * DO NOT call malloc here. The trapping thread is INSIDE malloc
                     * holding its lock; allocating from this handler thread could block
                     * on that lock and wedge the whole app — a probe that destroys what
                     * it measures. mach_vm_allocate goes straight to the VM and touches
                     * no malloc state. task_vm_info.limit_bytes_remaining is the kernel's
                     * own answer for how much headroom the process has left. */
                    if (okp && di_pc.dli_fname && strstr( di_pc.dli_fname, "libsystem_malloc" ))
                    {
                        task_vm_info_data_t vmi;
                        mach_msg_type_number_t vcnt = TASK_VM_INFO_COUNT;
                        mach_vm_address_t probe = 0;
                        kern_return_t ak = mach_vm_allocate( mach_task_self(), &probe,
                                                             1024 * 1024, VM_FLAGS_ANYWHERE );
                        if (ak == KERN_SUCCESS) mach_vm_deallocate( mach_task_self(), probe, 1024 * 1024 );
                        if (task_info( mach_task_self(), TASK_VM_INFO,
                                       (task_info_t)&vmi, &vcnt ) == KERN_SUCCESS)
                            dprintf(STDERR_FILENO,
                                    "[malloc-trap] phys_footprint=%llu MB limit_remaining=%lld MB "
                                    "compressed=%llu MB 1MB-vm_allocate=%s -- %s rev=ml573\n",
                                    (unsigned long long)(vmi.phys_footprint >> 20),
                                    (long long)((long long)vmi.limit_bytes_remaining >> 20),
                                    (unsigned long long)(vmi.compressed >> 20),
                                    ak == KERN_SUCCESS ? "OK" : "FAILED",
                                    ak != KERN_SUCCESS
                                      ? "<== allocation FAILED here too — consistent with exhaustion"
                                      : "<== allocation SUCCEEDS here, so this trap is not simple "
                                        "exhaustion (the libmalloc branch below is the actual proof)");
                        else
                            dprintf(STDERR_FILENO,
                                    "[malloc-trap] task_info(TASK_VM_INFO) FAILED; "
                                    "1MB-vm_allocate=%s rev=ml565\n",
                                    ak == KERN_SUCCESS ? "OK" : "FAILED");

                        /* ml567: WHAT did malloc choke on, and what is written there?
                         *
                         * ml565/566 proved this is real corruption, not OOM. Across 13
                         * runs it separates perfectly by FOOTPRINT (traps 3197-3339 MB,
                         * never 3015-3114 MB) while duration does not predict it at all
                         * (23 cycles traps at 3268 MB; 24 cycles is clean at 3114 MB).
                         * Not-exhaustion + footprint-predicts fits a WILD WRITE TO A
                         * ROUGHLY FIXED ADDRESS: harmless while the malloc zone is small
                         * enough not to cover it, fatal once the zone grows past it.
                         *
                         * libsystem_malloc traps with the offending block in hand, so its
                         * registers carry that pointer. Dump them, and hexdump around any
                         * that look like heap pointers. This project already has a known
                         * corrupter that writes ASCII where it does not own (#78/#88/#89;
                         * ml491 identified the payload as our own SwiftUI logStore text).
                         * If that text shows up here, the two are the same bug — and if
                         * the bytes are poison or guest data instead, that says so too. */
                        {
                            int r;
                            char line[160];
                            int n = snprintf( line, sizeof(line), "[malloc-trap] regs:" );
                            for (r = 0; r <= 8 && n < (int)sizeof(line) - 24; r++)
                                n += snprintf( line + n, sizeof(line) - n, " x%d=0x%llx",
                                               r, (unsigned long long)bs.__x[r] );
                            dprintf(STDERR_FILENO, "%s rev=ml567\n", line);

                            /* ml573 (Sol's plan): the allocator's own view of the damage.
                             *
                             * At this trap libmalloc has the offending block in hand. The
                             * literal it is about to print is "BUG IN CLIENT OF LIBMALLOC:
                             * memory corruption of free block" — that branch, not our
                             * vm_allocate probe, is what proves corruption. Decode what it
                             * saw:
                             *   x19 = object_ops*      (alloc_object's argument)
                             *   x20 = requested size   (mem_alloc's argument)
                             *   x0  = zone, x1 = xzone, x4 = bad block
                             * A freed block's first word is the freelist pointer XORed with
                             * a per-zone cookie, so `cookie ^ block` is what SHOULD be there.
                             *   actual0 != expected0            -> first word overwritten
                             *   actual0 == expected0, integrity -> second/PAC word overwritten
                             * ml572 showed two bad blocks sharing the high half 59 4f d0 5e
                             * with differing low bytes — exactly a cookie signature — so this
                             * should decode cleanly. */
                            {
                                uint64_t zone = bs.__x[0], xzone = bs.__x[1], bad = bs.__x[4];
                                uint64_t cookie = 0, class_size = 0, a0 = 0, a1 = 0;
                                unsigned char integrity = 0;
                                mach_vm_size_t g = 0;
                                int have_cookie, have_a0;

                                dprintf(STDERR_FILENO,
                                        "[malloc-trap] x19(ops)=0x%llx x20(req_size)=%llu "
                                        "fp=0x%llx sp=0x%llx lr=0x%llx rev=ml573\n",
                                        (unsigned long long)bs.__x[19], (unsigned long long)bs.__x[20],
                                        (unsigned long long)arm_thread_state64_get_fp( bs ),
                                        (unsigned long long)arm_thread_state64_get_sp( bs ),
                                        (unsigned long long)arm_thread_state64_get_lr( bs ));

#define IOS_RD64(addr, out) (mach_vm_read_overwrite( mach_task_self(), \
            (mach_vm_address_t)(addr), 8, (mach_vm_address_t)(uintptr_t)&(out), &g ) \
            == KERN_SUCCESS && g == 8)
                                have_cookie = IOS_RD64( zone + 0x150, cookie );
                                (void)IOS_RD64( xzone + 0x30, class_size );
                                have_a0 = IOS_RD64( bad, a0 );
                                (void)IOS_RD64( bad + 8, a1 );
                                (void)mach_vm_read_overwrite( mach_task_self(),
                                        (mach_vm_address_t)(zone + 0x10b), 1,
                                        (mach_vm_address_t)(uintptr_t)&integrity, &g );
                                if (have_cookie && have_a0)
                                {
                                    uint64_t expected0 = cookie ^ bad;
                                    dprintf(STDERR_FILENO,
                                            "[malloc-trap] zone=0x%llx xzone=0x%llx bad_block=0x%llx "
                                            "class_size=%llu integrity=0x%02x\n"
                                            "[malloc-trap]   cookie=0x%llx expected0=0x%llx "
                                            "actual0=0x%llx actual1=0x%llx -- %s rev=ml573\n",
                                            (unsigned long long)zone, (unsigned long long)xzone,
                                            (unsigned long long)bad, (unsigned long long)class_size,
                                            integrity, (unsigned long long)cookie,
                                            (unsigned long long)expected0, (unsigned long long)a0,
                                            (unsigned long long)a1,
                                            a0 != expected0
                                              ? "<== FIRST freelist word overwritten after free"
                                              : (integrity
                                                   ? "<== first word intact; SECOND/PAC word is the "
                                                     "damaged one"
                                                   : "<== first word matches the cookie — the damage "
                                                     "is elsewhere in the block"));
                                }
                                else
                                    dprintf(STDERR_FILENO,
                                            "[malloc-trap] could not read zone/block fields "
                                            "(zone=0x%llx bad=0x%llx) rev=ml573\n",
                                            (unsigned long long)zone, (unsigned long long)bad);

                                /* Whole freed block, raw. Stale pointer-like fields can name
                                 * its previous owner; a body of 0xaa would implicate a Wine
                                 * DEBUG_OBJECTS object. 32 bytes was too little. */
                                if (bad && class_size && class_size <= 0x400)
                                {
                                    unsigned char blk[0x400];
                                    mach_vm_size_t bg = 0;
                                    if (mach_vm_read_overwrite( mach_task_self(),
                                            (mach_vm_address_t)bad, class_size,
                                            (mach_vm_address_t)(uintptr_t)blk, &bg ) == KERN_SUCCESS)
                                    {
                                        unsigned o;
                                        for (o = 0; o < bg; o += 32)
                                        {
                                            char hx[3 * 32 + 1]; unsigned k, lim = (bg - o) < 32 ? (unsigned)(bg - o) : 32;
                                            for (k = 0; k < lim; k++) snprintf( hx + k * 3, 4, "%02x ", blk[o + k] );
                                            hx[lim * 3] = 0;
                                            dprintf(STDERR_FILENO, "[malloc-trap]   blk+%03x: %s rev=ml573\n", o, hx);
                                        }
                                    }
                                }

                                /* Frame-pointer chain, raw PCs only. Deliberately NOT
                                 * backtrace()/malloc_size()/Swift logging — all of those are
                                 * allocator-backed and libmalloc is mid-trap. */
                                {
                                    uint64_t fp = arm_thread_state64_get_fp( bs );
                                    char fr[320]; int fn = snprintf( fr, sizeof(fr), "[malloc-trap] fpchain:" );
                                    int d;
                                    for (d = 0; d < 12 && fp && !(fp & 15) && fn < (int)sizeof(fr) - 20; d++)
                                    {
                                        uint64_t nextfp = 0, pc = 0;
                                        if (!IOS_RD64( fp, nextfp ) || !IOS_RD64( fp + 8, pc )) break;
                                        fn += snprintf( fr + fn, sizeof(fr) - fn, " 0x%llx", (unsigned long long)pc );
                                        if (nextfp <= fp) break;
                                        fp = nextfp;
                                    }
                                    dprintf(STDERR_FILENO, "%s rev=ml573\n", fr);
                                }
#undef IOS_RD64
                            }

                            for (r = 0; r <= 8; r++)
                            {
                                uint64_t v = bs.__x[r];
                                unsigned char buf[32];
                                mach_vm_size_t got = 0;
                                int i, printable = 0;
                                char hex[3 * sizeof(buf) + 1], asc[sizeof(buf) + 1];
                                /* only plausible host-heap pointers, 16-byte aligned */
                                if (v < 0x100000000ull || v >= 0x740000000000ull || (v & 15)) continue;
                                if (mach_vm_read_overwrite( mach_task_self(),
                                        (mach_vm_address_t)(v & ~15ull), sizeof(buf),
                                        (mach_vm_address_t)(uintptr_t)buf, &got ) != KERN_SUCCESS
                                    || got != sizeof(buf))
                                    continue;
                                for (i = 0; i < (int)sizeof(buf); i++)
                                {
                                    snprintf( hex + i * 3, 4, "%02x ", buf[i] );
                                    asc[i] = (buf[i] >= 0x20 && buf[i] < 0x7f) ? buf[i] : '.';
                                    if (asc[i] != '.') printable++;
                                }
                                asc[sizeof(buf)] = 0;
                                dprintf(STDERR_FILENO,
                                        "[malloc-trap]   x%d=0x%llx: %s |%s|%s rev=ml567\n",
                                        r, (unsigned long long)v, hex, asc,
                                        printable >= 24 ? "  <== ASCII TEXT — matches the "
                                                          "#78/#88/#89 wild-write payload" : "");
                            }
                        }
                    }
                }

                /* ml554: an "other" BRK is a GUEST int3 — and on this port that has
                 * turned out to be PartitionAlloc's BackupRefPtr `refcount` CHECK
                 * deliberately aborting (chrome_elf+0xD7D6E; the helper at +0xD7D30
                 * sets Crashpad annotation "refcount" then crashes at line 452).
                 *
                 * The CHECK names the VICTIM, never the writer -- but it is handed the
                 * OFFENDING VALUE in edx, and the helper's first act is
                 * `movl %edx,%r8d`, so r8 still holds it at the int3. That value is the
                 * fingerprint: ASCII means the #78/#88 text-corrupter family, a poison
                 * pattern (0xEF/0xAB) means freed-memory reuse, a pointer-looking value
                 * means something else entirely.
                 *
                 * Dump the guest register file plus an ASCII decode of r8 and of the
                 * whole set. Cheap: only for non-FEX, non-StikDebug breakpoints, which
                 * are rare by construction. */
                if (binsn != 0xd4395fc0 && binsn != 0xd43e01a0)
                {
                    uint64_t x28v = bs.__x[28], grip = 0, gregs[16];
                    mach_vm_size_t got = 0;
                    int gi, ok = 0;
                    if (x28v &&
                        mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(x28v + 0x18),
                                                sizeof(grip), (mach_vm_address_t)&grip, &got ) == KERN_SUCCESS
                        && got == sizeof(grip) &&
                        /* ml578: gregs live at x28+0x20, NOT x28+0. Our own ml272
                         * note in this file already had it right ("rip=0x18
                         * gregs=0x20 gregs[RSP]=0x40") — reading from +0 grabbed
                         * the frame header and only part of the array, so every
                         * [int3-guest] register we have read was garbage. */
                        mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(x28v + 0x20),
                                                sizeof(gregs), (mach_vm_address_t)gregs, &got ) == KERN_SUCCESS
                        && got == sizeof(gregs))
                        ok = 1;

                    dprintf(STDERR_FILENO,
                            "[int3-guest] guest_rip=0x%llx x28=0x%llx read=%d rev=ml554\n",
                            (unsigned long long)grip, (unsigned long long)x28v, ok);
                    if (ok)
                    {
                        /* ml578: the GUEST register file — 16 entries, FEX order.
                         * Printed separately and explicitly labelled; the host ARM
                         * dump below is a different thing and was previously being
                         * mislabelled as guest state. Naively swapping bs.__x for
                         * gregs would also have run off the end: 31 vs 16. */
                        static const char *gn[16] = { "RAX","RCX","RDX","RBX","RSP","RBP","RSI","RDI",
                                                      "R8","R9","R10","R11","R12","R13","R14","R15" };
                        for (gi = 0; gi < 16; gi += 4)
                            dprintf(STDERR_FILENO,
                                    "[int3-guest]   GUEST %s=0x%016llx %s=0x%016llx "
                                    "%s=0x%016llx %s=0x%016llx rev=ml578\n",
                                    gn[gi],     (unsigned long long)gregs[gi],
                                    gn[gi + 1], (unsigned long long)gregs[gi + 1],
                                    gn[gi + 2], (unsigned long long)gregs[gi + 2],
                                    gn[gi + 3], (unsigned long long)gregs[gi + 3]);
                        /* Host x0..x30 too: FEX's SRA mapping is not assumed anywhere
                         * here, so print both and identify the value offline. */
                        for (gi = 0; gi < 31; gi += 4)
                            dprintf(STDERR_FILENO,
                                    "[int3-guest]   HOST x%-2d=0x%016llx x%-2d=0x%016llx "
                                    "x%-2d=0x%016llx x%-2d=0x%016llx\n",
                                    gi, (unsigned long long)bs.__x[gi],
                                    gi + 1, (unsigned long long)(gi + 1 < 31 ? bs.__x[gi + 1] : 0),
                                    gi + 2, (unsigned long long)(gi + 2 < 31 ? bs.__x[gi + 2] : 0),
                                    gi + 3, (unsigned long long)(gi + 3 < 31 ? bs.__x[gi + 3] : 0));
                        for (gi = 0; gi < 31; gi++)
                        {
                            unsigned long long v = bs.__x[gi];
                            char a[9]; int k;
                            for (k = 0; k < 8; k++)
                            { unsigned char c = (unsigned char)(v >> (8 * k)); a[k] = (c >= 32 && c < 127) ? c : '.'; }
                            a[8] = 0;
                            if (a[0] != '.' && a[1] != '.' && a[2] != '.')
                                dprintf(STDERR_FILENO,
                                        "[int3-guest]   ASCII x%d = \"%s\"  <== text in a register\n", gi, a);
                        }

                        /* iOS-Madeira ml616 [brp-contain]: WHICH PartitionAlloc callsite
                         * asserted, and on WHAT value.
                         *
                         * Chromium's BackupRefPtr refcount assertion is `int3; int3; ud2`
                         * preceded by a "refcount" diagnostic. It has killed ml602, ml603,
                         * ml607 and ml615 with a byte-identical signature: after the int3,
                         * Chrome's OWN handler runs with State.rip = 0xEFEFEFEFEFEFEFEF
                         * (freed poison), producing the read fault at 0x1e051d9c8dfd8.
                         *
                         * The registers here cannot name the offender: the assertion
                         * routine makes two calls before executing int3, so guest/host R8
                         * is already clobbered. The values survive on the STACK:
                         *   [guest RSP+0x38] = the offending refcount value
                         *   [guest RSP+0x48] = the direct caller's return address
                         * Five PartitionAlloc callsites can reach this; the return address
                         * is what distinguishes them.
                         *
                         * Self-identifying match, no module base needed: the guest bytes at
                         * rip-1 are the literal `CC CC 0F 0B` fatal pattern. That is why
                         * this cannot fire on an ordinary debugger breakpoint.
                         *
                         * ⚠️ Probe only — this does NOT contain the crash. Containment is
                         * deliberately NOT in this build: it must terminate the whole
                         * steamwebhelper pseudo-process, release FEX holds, and be proven
                         * to respawn and reach BrowserReady, or it merely renames the
                         * failure (webhelper owns the entire single-process CEF UI).
                         *
                         * ⛔ Do not try to suppress this with --disable-features: we already
                         * pass PartitionAllocBackupRefPtr and the assertion still runs. */
                        {
                            unsigned char pat[4] = {0, 0, 0, 0};
                            unsigned long long guest_rsp = gregs[4];   /* RAX,RCX,RDX,RBX,RSP,... */
                            mach_vm_size_t pg = 0;
                            int pat_ok = (grip > 1) &&
                                mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(grip - 1),
                                                        sizeof(pat), (mach_vm_address_t)pat, &pg ) == KERN_SUCCESS;
                            if (pat_ok && pat[0] == 0xCC && pat[1] == 0xCC && pat[2] == 0x0F && pat[3] == 0x0B)
                            {
                                unsigned long long offender = 0, caller = 0;
                                int o_ok, c_ok;
                                o_ok = mach_vm_read_overwrite( mach_task_self(),
                                          (mach_vm_address_t)(guest_rsp + 0x38), sizeof(offender),
                                          (mach_vm_address_t)&offender, &pg ) == KERN_SUCCESS;
                                c_ok = mach_vm_read_overwrite( mach_task_self(),
                                          (mach_vm_address_t)(guest_rsp + 0x48), sizeof(caller),
                                          (mach_vm_address_t)&caller, &pg ) == KERN_SUCCESS;
                                dprintf(STDERR_FILENO,
                                        "[brp-contain] ml616 BackupRefPtr refcount assertion: int3 at guest 0x%llx "
                                        "rsp=0x%llx offender=%s0x%llx caller=%s0x%llx pid=%04x tid=%04x "
                                        "-- caller names WHICH of the 5 PA callsites; NOT contained in this build\n",
                                        (unsigned long long)(grip - 1), guest_rsp,
                                        o_ok ? "" : "<unreadable>", offender,
                                        c_ok ? "" : "<unreadable>", caller,
                                        NtCurrentTeb() ? (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueProcess : 0,
                                        NtCurrentTeb() ? (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread : 0);
                            }
                        }
                    }
                }
            }
        }

        /* Look up per-thread TEB and trampoline for the faulting thread */
        uintptr_t thread_teb = 0;
        void *thread_trampoline = NULL;
        ios_lookup_thread( thread, &thread_teb, &thread_trampoline );

        /* Get faulting thread's register state */
        arm_thread_state64_t state;
        mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
        kr = thread_get_state( thread, ARM_THREAD_STATE64,
                               (thread_state_t)&state, &count );
        /* Also fetch NEON (SIMD/FP) state for STR/STP-q emulation */
        arm_neon_state64_t neon_state;
        mach_msg_type_number_t neon_count = ARM_NEON_STATE64_COUNT;
        int have_neon = (thread_get_state(thread, ARM_NEON_STATE64,
                                          (thread_state_t)&neon_state, &neon_count) == KERN_SUCCESS);
        if (kr == KERN_SUCCESS)
        {
            uintptr_t fault_addr = (uintptr_t)req->code[1];
#ifdef WINE_IOS
            /* ml939: THE SUB-FLOOR SERVICE BELONGS HERE, NOT IN segv_handler.
             *
             * ml938 put it in segv_handler and the emulation itself was correct --
             * both accesses were serviced and the guest ran on past them -- but
             * every resume corrupted FEX: "[CALLRET_OOB] UNDERFLOW callret_sp="
             * reporting exactly <pc+4>, then a rip-leak (guest RIP holding a pool
             * address), then c000001d.
             *
             * Cause: iOS sigreturn always zeroes x18, so a signal that resumes at a
             * JIT-pool PC must go through ios_fixup_x18_for_return(), which diverts
             * to the per-thread trampoline and carries the resume address in x17
             * (`ldr x18,[pc,#-8]; br x17`). It never restores x17 -- and x17 is
             * FEX's callret stack pointer. The SIGNAL path therefore CANNOT resume
             * into JIT code without destroying FEX state, for any fault, not just
             * ours. That is precisely why this handler already carries its own
             * unaligned-atomic emulator instead of leaving it to ios_emulate_store:
             * thread_set_state restores x18 directly, so there is no trampoline and
             * no x17 clobber. The same reasoning puts us here.
             *
             * ml953: MOVED TO THE FRONT OF THE EXC_BAD_ACCESS PATH.
             *
             * It used to sit after every other path had declined, which sounded
             * conservative and was wrong. Measured: once the guest started
             * reading KUSER_SHARED_DATA at 0x7ffe02e8 -- a registered window,
             * LDAPR, an encoding the emulator covers -- the serviced counter
             * froze at 598,017 and the app took 1.3M identical exceptions at one
             * pc. No UNHANDLED line either, so this code was never reached: an
             * earlier handler claimed the fault, resumed without fixing
             * anything, and looped. Its own diagnostics are capped, so after the
             * cap it did that silently.
             *
             * Going first is safe BY CONSTRUCTION, which is the same argument
             * the segv-side gate uses: the address is below iOS's 4GB floor, so
             * nothing in this task -- Wine view, FEX arena, JIT pool, W^X alias
             * or foreign mmap -- can be mapped there, and no other handler can
             * legitimately own it. An address outside every registered window
             * falls through untouched, so non-sub-floor faults keep their exact
             * current ordering. */
            if (!handled && req->exception == EXC_BAD_ACCESS)
            {
                /* ml1205: the faulting thread's own process decides the window */
                void *sf_peb = thread_teb ? ((TEB *)thread_teb)->Peb : NULL;
                uintptr_t sf_real = ios_subfloor_translate( (uint64_t)fault_addr, sf_peb );
                /* ml970: the gate has to admit low ALIASES too, not just image
                 * windows. ml969 registered the alias correctly (rdr34: 12
                 * registered, 0 refused, 2 retired) and the fault address
                 * 0x6aae0010 was inside alias 0x6aae0000 -- but the registry
                 * lookup lives inside ios_subfloor_service, and this gate
                 * skipped the whole block because the IMAGE translate returned
                 * 0. So the alias was never consulted: `serviced` and `REFUSED`
                 * were both zero while the guest still faulted.
                 *
                 * A 1-byte probe is enough to decide ENTRY; the authoritative
                 * whole-span bounds check stays inside the service function, so
                 * an access that starts inside an allocation but runs off its
                 * end is still refused there rather than resolved. */
                int sf_low = 0;
                /* literal because IOS_SUBFLOOR_FLOOR is defined further down
                 * this file; same value (0x100000000). */
                if (!sf_real && (uint64_t)fault_addr < 0x100000000ull)
                {
                    extern int ios_lowalloc_translate( unsigned long long addr,
                                                       unsigned long long len,
                                                       unsigned long long *real_out,
                                                       void **owner_out );
                    sf_low = ios_lowalloc_translate( (uint64_t)fault_addr, 1, NULL, NULL );
                }

                if (sf_real || sf_low)
                {
                    /* The emulators take a ucontext. arm_thread_state64_t IS the
                     * struct a ucontext's mcontext embeds as __ss, and
                     * arm_neon_state64_t is __ns, so a stack mcontext aliases the
                     * Mach state field-for-field -- no accessor refactor needed, and
                     * copying __ss back is what the thread_set_state below ships.
                     * __typeof__ rather than naming _STRUCT_MCONTEXT so this cannot
                     * drift from whatever ucontext_t actually holds. */
                    __typeof__( *(((ucontext_t *)0)->uc_mcontext) ) sf_mc;
                    ucontext_t sf_uc;

                    memset( &sf_mc, 0, sizeof(sf_mc) );
                    memset( &sf_uc, 0, sizeof(sf_uc) );
                    sf_mc.__ss = state;
                    if (have_neon) sf_mc.__ns = neon_state;
                    sf_uc.uc_mcontext = &sf_mc;
                    /* ml974: tell the emulators whether __ns is real. */
                    ios_neon_valid = have_neon;
                    if (!have_neon)
                    {
                        static int nn;
                        if (nn++ < 8)
                            dprintf( 2, "[neon] ml974 ARM_NEON_STATE64 unavailable for this fault "
                                     "(addr=%#llx) -- SIMD emulation will DECLINE rather than "
                                     "read/write a zeroed vector block\n",
                                     (unsigned long long)fault_addr );
                    }

                    if (ios_subfloor_service( &sf_uc, (void *)fault_addr, "mach", sf_peb ))
                    {
                        uint64_t sf_pc;

                        state = sf_mc.__ss;
                        sf_pc = (uint64_t)__darwin_arm_thread_state64_get_pc( state );
                        __darwin_arm_thread_state64_set_pc_fptr( state,
                                                                 (void *)(uintptr_t)(sf_pc + 4) );
                        if (have_neon)
                        {
                            neon_state = sf_mc.__ns;
                            thread_set_state( thread, ARM_NEON_STATE64,
                                              (thread_state_t)&neon_state, neon_count );
                        }
                        handled = 1;
                    }
                }
            }
#endif

            /* ml555: snapshot the protection AT HANDLER ENTRY, and keep the kernel's
             * own verdict from code[0].
             *
             * ml554 reported the fatal clear-routine fault as landing on an address that
             * was MAPPED and READ|WRITE -- which would mean a store to a perfectly
             * writable page faulted. But that reading is unsafe: the region query in
             * [fault_rip] happens ~1500 lines later, AFTER srcwatch and the page
             * machinery have run and possibly re-protected the page. So the "hostprot=3"
             * may simply be the state after we healed it, not the state that faulted.
             *
             * Capture it here, before anything can touch it, and report BOTH. If entry
             * and log-time disagree, something healed the page mid-handler and the fault
             * is a RACE; if they agree at RW, the store really did fault on writable
             * memory and it is something else entirely.
             *
             * code[0] is the kernel's classification: KERN_INVALID_ADDRESS(1) = nothing
             * mapped, KERN_PROTECTION_FAILURE(2) = mapped but access denied. That alone
             * separates "wild pointer" from "protection" without any inference. */
            int entry_prot = -1;
            unsigned long long entry_rbase = 0, entry_rsize = 0;
            const unsigned long long fault_kr = (unsigned long long)req->code[0];
            {
                mach_vm_address_t ea = (mach_vm_address_t)fault_addr;
                mach_vm_size_t es = 0;
                vm_region_basic_info_data_64_t ebi;
                mach_msg_type_number_t ec2 = VM_REGION_BASIC_INFO_COUNT_64;
                mach_port_t eo = MACH_PORT_NULL;
                if (fault_addr &&
                    mach_vm_region( mach_task_self(), &ea, &es, VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&ebi, &ec2, &eo ) == KERN_SUCCESS)
                { entry_prot = ebi.protection; entry_rbase = (unsigned long long)ea;
                  entry_rsize = (unsigned long long)es; }
            }

            /* 0. ml515: source-bitmap watch. MUST run before every other
             * classification — these are deliberate protection faults we
             * armed ourselves, and any later stage would mistake them for a
             * guest AV (which is exactly what killed ml514's runs). On a hit
             * we log the writer, unprotect that one page, and resume the
             * thread with its state untouched. */
            int srcwatch_hit = ios_srcwatch_handle( &state, fault_addr );
            if (srcwatch_hit) handled = 1;

            /* 1. Redirect user_shared_data accesses (0x7FFE0000) */
            if (!srcwatch_hit && fault_addr >= 0x7FFE0000 && fault_addr < 0x7FFF0000 && ios_exc_usd)
            {
                for (int reg = 0; reg <= 28; reg++)
                {
                    if (state.__x[reg] >= 0x7FFE0000 && state.__x[reg] < 0x7FFF0000)
                        state.__x[reg] = ios_exc_usd + (state.__x[reg] - 0x7FFE0000);
                }
                ios_exc_usd_fixes++;
                handled = 1;
            }

            /* 2. Redirect execution faults at original PE mappings to JIT pool.
             * The PE-side loader calls DLL entry points at original mapping
             * addresses which aren't executable on iOS. Translate to JIT. */
            if (!srcwatch_hit)
            {
                extern void *ios_jit_rx_base_global;
                extern size_t ios_jit_pool_size_global;
                extern int ios_jit_addr_is_text(uintptr_t addr);
                extern void *ios_jit_translate_addr_for_owner(void *addr, void *owner_peb);

                uint64_t fault_pc = (uint64_t)__darwin_arm_thread_state64_get_pc(state);
                int is_exec_fault = (fault_addr == (uintptr_t)fault_pc);

                /* ml454 (#74): the trampoline requirement gated the WHOLE
                 * redirect block, but only the in-pool x18-fix branch uses
                 * it — the outside-pool image→pool translate applies a plain
                 * PC rewrite (+ x18 via state) and needs no trampoline.  A
                 * thread with no registered trampoline (the ml452 renderer)
                 * lost ALL redirects and its image-VA exec fault stormed
                 * 65k× through guest SEH, re-entering the emission locks. */
                if (is_exec_fault)
                {
                    uintptr_t jit_rx = (uintptr_t)ios_jit_rx_base_global;
                    size_t jit_sz = ios_jit_pool_size_global;

                    if (fault_pc >= jit_rx && fault_pc < jit_rx + jit_sz)
                    {
                        /* Exec fault IN JIT pool — only fixable if in .text (x18 issue) */
                        if (ios_jit_addr_is_text(fault_pc) && state.__x[18] == 0 && thread_teb && thread_trampoline)
                        {
                            state.__x[17] = fault_pc;
                            __darwin_arm_thread_state64_set_pc_fptr(state, thread_trampoline);
                            ios_exc_x18_fixes++;
                            handled = 1;
                        }
                    }
                    else
                    {
                        /* Exec fault OUTSIDE JIT pool RX — try translations.
                         * IMPORTANT: this handler runs on its own thread, so
                         * translation must use the FAULTING thread's process
                         * (its registered TEB->Peb), not ours — a child
                         * thread's ntdll fault must redirect to the child's
                         * copy (S1 pseudo-processes). */
                        void *jit_pc;
                        void *fault_owner_peb = thread_teb ? ((TEB *)thread_teb)->Peb : NULL;
                        ios_last_exec_fault_thread = thread;

                        /* ml691 W^X RE-PROMOTE. If a page we demoted to RW is
                         * ever executed, restore RX here -- synchronously, before
                         * the faulting thread resumes. This is the recovery hook
                         * a NOEXEC fault could not otherwise provide, because FEX
                         * normally executes its own translated host code and never
                         * touches the guest page. Reaching this path at all means
                         * the "data page" assumption was wrong for that page, so
                         * it is put back and never demoted again. */
                        {
                            extern int ios_wx_repromote( unsigned long long );
                            if (ios_wx_repromote( (unsigned long long)fault_pc ))
                            {
                                /* RX restored: mark handled and skip the
                                 * translate/heal path below. Resuming re-runs the
                                 * faulting instruction against the restored page. */
                                handled = 1;
                            }
                        }
                        if (!handled)
                        {
                        }
                        jit_pc = ios_jit_translate_addr_for_owner((void *)(uintptr_t)fault_pc,
                                                                  fault_owner_peb);
                        /* Module-mapping hit = a stale PE-VA pointer somewhere
                         * in the pool — queue it for the heal scanner so this
                         * address only ever faults once. */
                        if (jit_pc != (void *)(uintptr_t)fault_pc)
                            ios_stale_va_enqueue((uint64_t)fault_pc);
                        /* [xlate-exec] pseudo-process forensics: every
                         * image-VA exec fault is an ownership decision —
                         * log which copy the thread was routed to. A child
                         * thread landing in a session-owned copy (owner=0
                         * while its teb->peb is a child peb) is the
                         * cross-copy migration that kills thread exit. */
                        {
                            extern void *ios_jit_pool_copy_owner(const void *addr, void **pe_base_out);
                            /* Child threads only — the session's own boot
                             * takes thousands of these and drowned the
                             * budget (2026-07-07 run: all 128 entries spent
                             * before services.exe even spawned). */
                            if (fault_owner_peb && peb && fault_owner_peb != (void *)peb)
                            {
                                static volatile int xe_count = 0;
                                int xe = __sync_add_and_fetch(&xe_count, 1);
                                if (xe <= 256 || (xe % 1024) == 0)
                                {
                                    void *copy_pe = NULL;
                                    void *copy_owner = ios_jit_pool_copy_owner(jit_pc, &copy_pe);
                                    dprintf(STDERR_FILENO,
                                        "[xlate-exec] #%d teb=%p owner=%p pc=%p -> %p (copy pe=%p copy_owner=%p)\n",
                                        xe, (void *)thread_teb, fault_owner_peb,
                                        (void *)(uintptr_t)fault_pc, jit_pc, copy_pe, copy_owner);
                                }
                            }
                        }
                        if (jit_pc == (void *)(uintptr_t)fault_pc)
                        {
                            /* iOS-Madeira: if PC is in JIT pool RW alias range,
                             * redirect to RX alias (= PC - pool_size). FEX's
                             * emitted code lives at RX alias addresses, but
                             * sometimes a BR/BLR computes the RW alias via
                             * emitter math when our redirect interacts with
                             * vm_remap. */
                            extern void *ios_jit_rw_base_global;
                            extern size_t ios_jit_pool_size_global;
                            uintptr_t rw_base = (uintptr_t)ios_jit_rw_base_global;
                            uintptr_t rx_base2 = (uintptr_t)ios_jit_rx_base_global;
                            if (rw_base && rx_base2 && ios_jit_pool_size_global &&
                                fault_pc >= rw_base &&
                                fault_pc < rw_base + ios_jit_pool_size_global)
                            {
                                uintptr_t rx_pc = (uintptr_t)fault_pc - rw_base + rx_base2;
                                jit_pc = (void *)rx_pc;
                            }
                        }
                        if (jit_pc == (void *)(uintptr_t)fault_pc)
                        {
                            /* Not a known PE-image translation. Try the anon-alias
                             * table (FEX CodeBuffer / runtime JIT regions vm_remap'd
                             * from the JIT pool) — those have a separate RX alias
                             * that's actually executable. */
                            extern uintptr_t ios_jit_anon_alias_lookup_rx(uintptr_t);
                            uintptr_t rx_pc = ios_jit_anon_alias_lookup_rx((uintptr_t)fault_pc);
                            if (rx_pc) jit_pc = (void *)rx_pc;
                        }
                        if (jit_pc != (void *)(uintptr_t)fault_pc)
                        {
                            /* Plain pc redirect — even with x18==0. The old
                             * x18-restore trampoline clobbered x17, which is
                             * LIVE in FEX-emitted code (callret scratch) and
                             * in ARM64EC thunks. If the redirect target's
                             * code needs the TEB, its [x18,#imm] access
                             * faults and case 3 emulates it clobber-free. */
                            if (thread_teb && state.__x[18] == 0)
                            {
                                static volatile int redir2_count = 0;
                                int t2 = __sync_add_and_fetch(&redir2_count, 1);
                                if (t2 <= 10 || (t2 % 4096) == 0)
                                    dprintf(STDERR_FILENO,
                                        "[x18-redir2] #%d pc=%p -> jit=%p (x18 set via state)\n",
                                        t2, (void*)(uintptr_t)fault_pc, jit_pc);
                                /* Same set_state x18 experiment as case 3. */
                                state.__x[18] = thread_teb;
                            }
                            /* ml1059: WHICH addresses get executed through their non-executable
                             * backing. Each is a whole Mach exception per CALL (a pointer from
                             * GetProcAddress, a vtable, a callback). One such pointer inside FEX's
                             * block lookup was costing the exception thread half a core; count the
                             * rest so they can be fixed at the source rather than discovered one
                             * profile at a time. Single writer (this handler thread). */
                            {
                                static struct { uintptr_t pc; uintptr_t lr; unsigned long n; } top[64];
                                static unsigned long total;
                                int h, slot = -1;
                                for (h = 0; h < 64; h++)
                                {
                                    if (top[h].pc == (uintptr_t)fault_pc) { top[h].n++; slot = h; break; }
                                    if (!top[h].pc && slot < 0) slot = h;
                                }
                                /* ml1106: the CALLER too (lr at the fault = who jumped here), so a hot
                                 * target can be traced to the thunk or table that holds its address. */
                                if (h == 64 && slot >= 0) { top[slot].pc = (uintptr_t)fault_pc; top[slot].lr = (uintptr_t)__darwin_arm_thread_state64_get_lr(state); top[slot].n = 1; }
                                if (!(++total % 100000))
                                {
                                    char line[900]; int n = 0, k;
                                    for (k = 0; k < 8; k++)
                                    {
                                        int best = -1;
                                        for (h = 0; h < 64; h++) if (top[h].n && (best < 0 || top[h].n > top[best].n)) best = h;
                                        if (best < 0 || top[best].n < 50) break;
                                        n += snprintf( line + n, sizeof(line) - n, " %p(lr %p)=%lu", (void *)top[best].pc, (void *)top[best].lr, top[best].n );
                                        top[best].n = 0; top[best].pc = 0; top[best].lr = 0;
                                    }
                                    dprintf( STDERR_FILENO, "[exec-redir] ml1059 %lu executions through non-executable backing so far; "
                                             "hottest in the last 100000:%s\n", total, n ? line : " (none above 50)" );
                                    memset( top, 0, sizeof(top) );
                                }
                            }
                            __darwin_arm_thread_state64_set_pc_fptr(state, jit_pc);
                            ios_exc_x18_fixes++;
                            handled = 1;
                        }
                    }
                }
            }

            /* 3. Emulate [x18, #imm] accesses when x18 == 0.
             * iOS zeros x18 on context switch. EC/FEX code reads the TEB
             * through x18; with x18==0 the effective address IS the TEB
             * offset, so we can complete the access in-handler against the
             * real TEB (teb + fault_addr) and advance pc. Rn==18 in the
             * faulting instruction is the exact discriminator — a fault
             * with any other base register is NOT x18-caused and falls
             * through to real fault handling.
             *
             * This REPLACES the old x18-restore trampoline for data faults.
             * The trampoline clobbered x17 (its jump register) — fatal when
             * the interrupted code held a live value there. Two confirmed
             * kills (2026-07-04, after UNIXCALL-DIRECT widened the x18==0
             * windows): (a) FEX emitter loop `str w16,[x15,x17]` re-executed
             * with x17=pc → garbage address → eternal UNHANDLED; (b) ntdll
             * EC TEB-read sites trampolined with live x17 (pool pointers,
             * FP constants observed) → silent state corruption → heap
             * damage → libsystem_malloc died inside Metal texture creation.
             * Emulation clobbers NOTHING. x18 stays 0 afterwards; each
             * subsequent TEB access costs one fault until the next context
             * switch restores nothing — acceptable, bounded, correct. */
            if (!handled && state.__x[18] == 0 && thread_teb)
            {
                uint64_t fault_pc = (uint64_t)__darwin_arm_thread_state64_get_pc(state);
                int is_exec_fault = (fault_addr == (uintptr_t)fault_pc);

                if (!is_exec_fault && fault_addr < 0x10000 &&
                    fault_pc >= 0x100000000ULL)
                {
                    uint32_t insn; ios_fault_read_insn( (uint64_t)(uintptr_t)fault_pc, &insn );  /* ml982 */
                    int rn = (insn >> 5) & 0x1f;

                    /* ml157 PROBE (#36): the webhelper dies here. FEX emitted
                     * `movz w1,#0; ldr x1,[x1]` — the page-0 address was
                     * materialised into a SCRATCH register, so rn!=18 and the
                     * emulator above declines, making the fault fatal (5
                     * recursive repeats -> thread exit -> steam exit(1)).
                     *
                     * The open question is whether address 0 here is a TEB
                     * offset FEX spilled to a scratch reg, or a genuine guest
                     * NULL deref. Emulating the wrong one silently corrupts,
                     * so DO NOT widen the discriminator until this says which.
                     *
                     * Discriminators printed:
                     *  - the 16 insns before pc: an x18 SPILL (`mov xN,x18` /
                     *    `mrs`+TEB math) means TEB access; a guest-address
                     *    computation (adds/shifts from FEX guest regs) means a
                     *    real NULL deref.
                     *  - base reg VALUE vs fault_addr: equal => the register
                     *    literally held the small offset.
                     * Capped at 4 reports so a fault storm can't flood. */
                    /* A base register computed from x18 one instruction earlier */
                    int x18_derived = ios_x18_derived_base( fault_pc, rn );
                    if (x18_derived)
                    {
                        static int ios_x18_derived_reports;
                        if (ios_x18_derived_reports++ < 8)
                            ERR( "[x18-derived] #%d pc=%p insn=%08x base x%d from x18 -> "
                                 "TEB+0x%lx emulated\n", ios_x18_derived_reports, (void *)(uintptr_t)fault_pc,
                                 insn, rn, (unsigned long)fault_addr );
                    }

                    if (rn != 18 && !x18_derived)
                    {
                        static int ios_x18_decline_reports;
                        if (ios_x18_decline_reports < 4)
                        {
                            const uint32_t *w = (const uint32_t *)(uintptr_t)fault_pc;
                            char buf[512];
                            int n = 0, k;
                            /* __x[] is x0..x28 only; fp/lr/sp are separate
                             * members and rn==31 is xzr/sp. Never index past 28. */
                            uint64_t rn_val = (rn < 29) ? state.__x[rn] :
                                              (rn == 29) ? state.__fp :
                                              (rn == 30) ? state.__lr : state.__sp;
                            ios_x18_decline_reports++;
                            for (k = -16; k <= 4 && n < (int)sizeof(buf) - 16; k++)
                                n += snprintf( buf + n, sizeof(buf) - n, "%s%08x",
                                               k ? " " : " [", w[k] ) + (k ? 0 : 0);
                            snprintf( buf + n, sizeof(buf) - n, "]" );
                            ERR( "[x18-decline] #%d pc=%p fault_addr=0x%lx insn=%08x rn=%d "
                                 "xRn=0x%llx (rn_val==fault_addr? %d) x18=0 teb=%p\n",
                                 ios_x18_decline_reports, (void *)(uintptr_t)fault_pc,
                                 (unsigned long)fault_addr, insn, rn,
                                 (unsigned long long)rn_val,
                                 rn_val == fault_addr, (void *)thread_teb );
                            ERR( "[x18-decline] #%d insns pc-64..pc+16:%s\n",
                                 ios_x18_decline_reports, buf );
                        }
                    }

                    if (rn == 18 || x18_derived)
                    {
                        uintptr_t ea = thread_teb + fault_addr;
                        int rt = insn & 0x1f;
                        int emulated = 0;

                        switch (insn & 0xffc00000)
                        {
                        /* unsigned-offset immediate loads, base x18 */
                        case 0xf9400000: /* LDR Xt */
                            if (rt != 31) state.__x[rt] = *(uint64_t *)ea;
                            emulated = 1; break;
                        case 0xb9400000: /* LDR Wt (zero-extend) */
                            if (rt != 31) state.__x[rt] = *(uint32_t *)ea;
                            emulated = 1; break;
                        case 0x39400000: /* LDRB Wt */
                            if (rt != 31) state.__x[rt] = *(uint8_t *)ea;
                            emulated = 1; break;
                        case 0x79400000: /* LDRH Wt */
                            if (rt != 31) state.__x[rt] = *(uint16_t *)ea;
                            emulated = 1; break;
                        /* unsigned-offset immediate stores, base x18 */
                        case 0xf9000000: /* STR Xt */
                            *(uint64_t *)ea = (rt == 31) ? 0 : state.__x[rt];
                            emulated = 1; break;
                        case 0xb9000000: /* STR Wt */
                            *(uint32_t *)ea = (rt == 31) ? 0 : (uint32_t)state.__x[rt];
                            emulated = 1; break;
                        case 0x39000000: /* STRB Wt */
                            *(uint8_t *)ea = (rt == 31) ? 0 : (uint8_t)state.__x[rt];
                            emulated = 1; break;
                        case 0x79000000: /* STRH Wt */
                            *(uint16_t *)ea = (rt == 31) ? 0 : (uint16_t)state.__x[rt];
                            emulated = 1; break;
                        default: break;
                        }

                        /* LDP/STP Xt,Xt2,[x18,#imm] signed-offset (no writeback) */
                        if (!emulated && (insn & 0xffc00000) == 0xa9400000)
                        {
                            int rt2 = (insn >> 10) & 0x1f;
                            if (rt != 31)  state.__x[rt]  = *(uint64_t *)ea;
                            if (rt2 != 31) state.__x[rt2] = *(uint64_t *)(ea + 8);
                            emulated = 1;
                        }
                        else if (!emulated && (insn & 0xffc00000) == 0xa9000000)
                        {
                            int rt2 = (insn >> 10) & 0x1f;
                            *(uint64_t *)ea       = (rt == 31)  ? 0 : state.__x[rt];
                            *(uint64_t *)(ea + 8) = (rt2 == 31) ? 0 : state.__x[rt2];
                            emulated = 1;
                        }

                        /* GPR register-offset (`ldrb w8,[x18,x8]` killed boot
                         * 2026-07-04 19:39) and unscaled-immediate (LDUR/STUR)
                         * families, any size, loads+stores+signed loads. The
                         * hardware already computed the offset into fault_addr,
                         * so only size/opc/Rt semantics matter here. */
                        if (!emulated &&
                            ((insn & 0x3f200c00) == 0x38200800 ||   /* register offset */
                             (insn & 0x3f200c00) == 0x38000000))    /* unscaled imm9 */
                        {
                            int size = (insn >> 30) & 3;   /* 0=B 1=H 2=W 3=X */
                            int opc  = (insn >> 22) & 3;   /* 0=ST 1=LD 2/3=LDS */
                            uint64_t val = 0;
                            emulated = 1;
                            if (opc == 0)               /* store */
                            {
                                val = (rt == 31) ? 0 : state.__x[rt];
                                switch (size)
                                {
                                case 0: *(uint8_t  *)ea = (uint8_t)val;  break;
                                case 1: *(uint16_t *)ea = (uint16_t)val; break;
                                case 2: *(uint32_t *)ea = (uint32_t)val; break;
                                case 3: *(uint64_t *)ea = val;           break;
                                }
                            }
                            else if (opc == 1)          /* zero-extending load */
                            {
                                switch (size)
                                {
                                case 0: val = *(uint8_t  *)ea; break;
                                case 1: val = *(uint16_t *)ea; break;
                                case 2: val = *(uint32_t *)ea; break;
                                case 3: val = *(uint64_t *)ea; break;
                                }
                                if (rt != 31) state.__x[rt] = val;
                            }
                            else if (size == 3 && opc == 2)
                            {
                                /* PRFM (register/unscaled) — prefetch, no-op */
                            }
                            else                        /* sign-extending load */
                            {
                                int64_t sval = 0;
                                switch (size)
                                {
                                case 0: sval = *(int8_t  *)ea; break;
                                case 1: sval = *(int16_t *)ea; break;
                                case 2: sval = *(int32_t *)ea; break; /* LDRSW */
                                }
                                if (opc == 3) /* 32-bit target: Wt, zero upper */
                                    sval = (int64_t)(uint32_t)(int32_t)sval;
                                if (rt != 31) state.__x[rt] = (uint64_t)sval;
                            }
                        }

                        /* SIMD/FP register-offset + unsigned-offset loads/
                         * stores, base x18 (V=1, bit 26). `LDR Q0,[x18,x8]`
                         * (insn 3ce86a40) crashed the crypt32 cert-verify
                         * SIMD memcpy 2026-07-05. ea = thread_teb+fault_addr
                         * (hw already added the offset). Access width from
                         * {size, opc<1>}: size0+opc<1> = 128-bit Q, else
                         * 1<<size bytes (B/H/S/D). opc<0> (bit22): 1=load,
                         * 0=store. Loads write neon_state.__v[rt] (zeroing
                         * the upper lanes) and push it back immediately;
                         * stores read from it. */
                        if (!emulated && have_neon &&
                            ((insn & 0x3f200c00) == 0x3c200800 ||   /* SIMD register offset */
                             (insn & 0x3f000000) == 0x3d000000))    /* SIMD unsigned-offset imm */
                        {
                            int size = (insn >> 30) & 3;
                            int opc  = (insn >> 22) & 3;
                            int bytes = (size == 0 && (opc & 2)) ? 16 : (1 << size);
                            if (opc & 1)   /* load */
                            {
                                memset(&neon_state.__v[rt], 0, 16);
                                memcpy(&neon_state.__v[rt], (void *)ea, bytes);
                                thread_set_state(thread, ARM_NEON_STATE64,
                                                 (thread_state_t)&neon_state, neon_count);
                            }
                            else           /* store */
                            {
                                memcpy((void *)ea, &neon_state.__v[rt], bytes);
                            }
                            emulated = 1;
                        }

                        if (emulated)
                        {
                            static volatile int emul3_count = 0;
                            int e3 = __sync_add_and_fetch(&emul3_count, 1);
                            if (e3 <= 20 || (e3 % 4096) == 0)
                                dprintf(STDERR_FILENO,
                                    "[x18-emul3] #%d pc=%p insn=%08x teb+0x%llx rt=%d\n",
                                    e3, (void*)(uintptr_t)fault_pc, insn,
                                    (unsigned long long)fault_addr, rt);
                            /* EXPERIMENT: also set x18 in the written-back
                             * state. Project lore says thread_set_state
                             * doesn't preserve x18 — from early testing that
                             * may have been confounded. If it DOES stick,
                             * the silent-copy hole (NtCurrentTeb = mov
                             * x0,x18 propagating 0 without faulting) closes
                             * and emul3 should fire ~once per context
                             * switch instead of once per TEB access. Free
                             * either way — verify via emul3 rate + next-
                             * fault x18 values in the log. */
                            state.__x[18] = thread_teb;
                            __darwin_arm_thread_state64_set_pc_fptr(
                                state, (void *)(uintptr_t)(fault_pc + 4));
                            ios_exc_x18_fixes++;
                            handled = 1;
                        }
                        else
                        {
                            /* x18-based but unrecognized encoding (writeback,
                             * register-offset, SIMD...). Log it — needs a new
                             * case above, NOT the old x17-clobbering
                             * trampoline. Falls through to real handling. */
                            dprintf(STDERR_FILENO,
                                "[x18-emul3] UNRECOGNIZED insn=%08x pc=%p teb+0x%llx\n",
                                insn, (void*)(uintptr_t)fault_pc,
                                (unsigned long long)fault_addr);
                        }
                    }
                }
            }

            /* 3.5. FEX unaligned LDAR/LDAPR/STLR backpatch.
             *
             * x86 has TSO ordering. FEX's MemoryOps lowers x86 TSO loads/stores
             * to ARM64 LDAPR/STLR (alignment-strict). Some x86 binaries do
             * legal *unaligned* loads (e.g. steamclient64.dll's packed
             * unpacker: `movl (%rsi),%ebx` with rsi unaligned) — those fault
             * on the LDAPR. FEX's HandleUnalignedAccess (Arm64.cpp:2072)
             * already knows how to recover by atomically rewriting the
             * instruction to LDR+DMB_LD (or DMB+STR for STLR). It only fires
             * on Windows EXCEPTION_DATATYPE_MISALIGNMENT — on iOS the Mach
             * handler sees EXC_BAD_ACCESS first.
             *
             * Replicate the FEX backpatch here so iOS gets the same recovery.
             * Encoding constants from FEX/FEXCore/Source/Utils/ArchHelpers/Arm64.cpp. */
            if (!handled)
            {
                extern void *ios_jit_rx_base_global;
                extern void *ios_jit_rw_base_global;
                extern size_t ios_jit_pool_size_global;
                uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
                uintptr_t rw = (uintptr_t)ios_jit_rw_base_global;
                size_t sz = ios_jit_pool_size_global;
                uint64_t fault_pc = (uint64_t)__darwin_arm_thread_state64_get_pc(state);

                if (rx && rw && sz && fault_pc >= rx && fault_pc < rx + sz)
                {
                    uintptr_t rw_pc = rw + (fault_pc - rx);
                    uint32_t insn; ios_fault_read_insn( (uint64_t)(uintptr_t)fault_pc, &insn );  /* ml982 */

                    /* ml431 (#71): per-thread LL/SC monitor for the misaligned
                     * exclusive emulation below. Only ever touched on the single
                     * Mach exception-server thread — no locking. */
                    enum { IOS_EXCL_MON_SLOTS = 64 };
                    static struct {
                        mach_port_t thr;
                        uint64_t addr;
                        uint64_t val;
                        uint8_t size;
                        uint8_t valid;
                    } ios_excl_mon[IOS_EXCL_MON_SLOTS];

                    static const uint32_t LDAXR_MASK  = 0x3FFFFC00u;
                    static const uint32_t LDAR_INST   = 0x08DFFC00u;
                    static const uint32_t LDAPR_INST  = 0x38BFC000u;
                    static const uint32_t STLR_INST   = 0x089FFC00u;
                    static const uint32_t RCPC2_MASK  = 0x3FE00C00u;
                    static const uint32_t LDAPUR_INST = 0x19400000u;
                    static const uint32_t STLUR_INST  = 0x19000000u;
                    static const uint32_t LDR_INST    = 0x387F6800u; /* LDR (imm), unsigned-offset 0 */
                    static const uint32_t STR_INST    = 0x383F6800u;
                    static const uint32_t LDUR_INST   = 0x38400000u;
                    static const uint32_t STUR_INST   = 0x38000000u;
                    static const uint32_t DMB         = 0xD5033BBFu; /* dmb ish */
                    static const uint32_t DMB_LD      = 0xD5033DBFu; /* dmb ishld */

                    int patched = 0;
                    int adjust_pc = 0;
                    uint32_t prev_slot = 0;   /* ml962: slot contents before the barrier overwrites it */

                    /* iOS-Madeira: gate the LDAR/STLR rewrite on the access
                     * being ACTUALLY unaligned for its size. The Mach
                     * EXC_BAD_ACCESS we catch here also covers plain guest
                     * NULL-derefs (addr=0x0, 0x8, ...). Those are aligned and
                     * must be raised as a normal SEGV — rewriting an LDAR/
                     * STLR there only delays the same fault and corrupts the
                     * exception path. Size encoded in insn[31:30]:
                     *   00=byte (always aligned), 01=halfword, 10=word, 11=dword. */
                    {
                        uint32_t access_size_lg2 = (insn >> 30) & 0x3;
                        uint64_t align_mask = (access_size_lg2 == 0) ? 0
                                            : ((1ULL << access_size_lg2) - 1);
                        /* iOS-Madeira ml624 — BYTE ACCESSES MUST *ALWAYS* SKIP.
                         *
                         * The comment above is correct: an 8-bit access can never be
                         * misaligned. But `if (align_mask && ...)` made byte the ONE size
                         * that NEVER took the skip, because align_mask is 0 for it. Every
                         * faulting STLRB therefore fell into the STLR -> DMB+STR backpatch
                         * below, which writes the half-barrier to rw_pc-4.
                         *
                         * For 16/32/64-bit that slot is a nop FEX reserves for exactly this
                         * purpose ("Half-barrier once back-patched", MemoryOps.cpp). For
                         * 8-bit FEX deliberately emits NO nop ("8bit load is always aligned
                         * to natural alignment") -- so rw_pc-4 is a LIVE INSTRUCTION and the
                         * backpatch DESTROYS it.
                         *
                         * That is the ULTRAKILL wall, byte for byte. Mono's emitter store
                         *     91000806  add   x6, x0, #2      <- computes the ADDRESS
                         *     089ffcc8  stlrb w8, [x6]
                         * was rewritten in place to
                         *     d5033bbf  dmb   ish             <- ate the add
                         *     383f68c8  strb  w8, [x6, xzr]
                         * so x6 still held the stale 0x44 from the preceding `or al,0x44`
                         * and the store went to address 0x44. The ml623 capture proved the
                         * IR, the RA and the emitted bytes were all CORRECT at compile time;
                         * this handler is what changed them afterwards.
                         *
                         * A faulting STLRB is never an unaligned atomic -- it is a write to
                         * a page we map RX (here Mono's freshly allocated RWX code buffer),
                         * and the JIT-alias store emulator further down already performs
                         * that store correctly through the RW alias and advances the PC.
                         * Skip, and let it. 16/32/64-bit recovery is unchanged. */
                        if (!align_mask || ((uint64_t)fault_addr & align_mask) == 0) {
                            if (!align_mask) {
                                static int ios_byte_skip_count = 0;
                                if (ios_byte_skip_count < 16) {
                                    ios_byte_skip_count++;
                                    fprintf(stderr, "[unalign-byte] ml624 #%d SKIP backpatch: byte access cannot be "
                                                    "unaligned; insn=%08x pc=%p addr=%p -> alias emulator "
                                                    "(pc-4 preserved)\n",
                                            ios_byte_skip_count, insn, (void *)fault_pc,
                                            (void *)fault_addr);
                                }
                            }
                            /* Aligned — this is a genuine SEGV/BUS, not an
                             * unaligned-atomic-needs-backpatch case. Skip. */
                            goto skip_unaligned_backpatch;
                        }
                    }

                    if ((insn & LDAXR_MASK) == LDAR_INST ||
                        (insn & LDAXR_MASK) == LDAPR_INST)
                    {
                        /* LDAR/LDAPR → LDR + DMB_LD. Replace instruction in
                         * place with the regular LDR; FEX reserves the next
                         * slot for the half-barrier. */
                        uint32_t Size = (insn >> 30) & 0x3;
                        uint32_t Rn = (insn >> 5) & 0x1F;
                        uint32_t Rt = insn & 0x1F;
                        uint32_t new_ldr = LDR_INST | (Size << 30) | (Rn << 5) | Rt;
                        prev_slot = __atomic_load_n((volatile uint32_t *)(rw_pc + 4), __ATOMIC_ACQUIRE);
                        __atomic_store_n((volatile uint32_t *)(rw_pc + 4), DMB_LD, __ATOMIC_RELEASE);
                        __atomic_store_n((volatile uint32_t *)rw_pc,         new_ldr, __ATOMIC_RELEASE);
                        sys_icache_invalidate((void *)fault_pc, 8);
                        patched = 1;
                    }
                    else if ((insn & LDAXR_MASK) == STLR_INST)
                    {
                        /* STLR → DMB + STR. Half-barrier overwrites the slot
                         * before the STLR; PC backs up by 4. */
                        uint32_t Size = (insn >> 30) & 0x3;
                        uint32_t Rn = (insn >> 5) & 0x1F;
                        uint32_t Rt = insn & 0x1F;
                        uint32_t new_str = STR_INST | (Size << 30) | (Rn << 5) | Rt;
                        prev_slot = __atomic_load_n((volatile uint32_t *)(rw_pc - 4), __ATOMIC_ACQUIRE);
                        __atomic_store_n((volatile uint32_t *)(rw_pc - 4), DMB, __ATOMIC_RELEASE);
                        __atomic_store_n((volatile uint32_t *)rw_pc,       new_str, __ATOMIC_RELEASE);
                        sys_icache_invalidate((void *)(fault_pc - 4), 8);
                        adjust_pc = -4;
                        patched = 1;
                    }
                    else if ((insn & RCPC2_MASK) == LDAPUR_INST)
                    {
                        uint32_t Size = (insn >> 30) & 0x3;
                        uint32_t Rn = (insn >> 5) & 0x1F;
                        uint32_t Rt = insn & 0x1F;
                        uint32_t new_ldur = LDUR_INST | (Size << 30) | (Rn << 5) | Rt
                                           | (insn & (0x1FFu << 12));
                        prev_slot = __atomic_load_n((volatile uint32_t *)(rw_pc + 4), __ATOMIC_ACQUIRE);
                        __atomic_store_n((volatile uint32_t *)(rw_pc + 4), DMB_LD,   __ATOMIC_RELEASE);
                        __atomic_store_n((volatile uint32_t *)rw_pc,         new_ldur, __ATOMIC_RELEASE);
                        sys_icache_invalidate((void *)fault_pc, 8);
                        patched = 1;
                    }
                    else if ((insn & RCPC2_MASK) == STLUR_INST)
                    {
                        uint32_t Size = (insn >> 30) & 0x3;
                        uint32_t Rn = (insn >> 5) & 0x1F;
                        uint32_t Rt = insn & 0x1F;
                        uint32_t new_stur = STUR_INST | (Size << 30) | (Rn << 5) | Rt
                                           | (insn & (0x1FFu << 12));
                        prev_slot = __atomic_load_n((volatile uint32_t *)(rw_pc - 4), __ATOMIC_ACQUIRE);
                        __atomic_store_n((volatile uint32_t *)(rw_pc - 4), DMB,      __ATOMIC_RELEASE);
                        __atomic_store_n((volatile uint32_t *)rw_pc,         new_stur, __ATOMIC_RELEASE);
                        sys_icache_invalidate((void *)(fault_pc - 4), 8);
                        adjust_pc = -4;
                        patched = 1;
                    }
                    /* iOS-Madeira ml431 (#71): misaligned EXCLUSIVE / CAS family.
                     *
                     * ml430: Valve's IPCWrapper embeds a CRITICAL_SECTION at an
                     * odd offset inside a packed shm struct (legal on x86 —
                     * misaligned LOCK ops are architectural there). wine's EC
                     * ntdll TryEnterCriticalSection CAS (ldaxr/stlxr on
                     * LockCount at crit+8) alignment-faults on it. Routing the
                     * fault through the guest-exception path costs ~ms per
                     * instruction (FEX emulates one insn per round-trip), which
                     * stretched an instantaneous acquire until the IPC partner
                     * retired the shm view mid-acquire -> use-after-free AV ->
                     * Crashpad terminate, in the CreateResponse->BrowserReady
                     * gap.
                     *
                     * These cases MUST NOT patch the code: the pool-copied
                     * ntdll .text is shared by every aligned CS in the process;
                     * rewriting ldaxr/stlxr would destroy their atomicity.
                     * Instead emulate the single faulting instruction here with
                     * an LL/SC monitor. This entire block runs on the single
                     * Mach exception-server thread, so all emulated accesses
                     * are naturally serialized (no lock needed); the only
                     * unserialized racers are plain stores from other threads,
                     * which x86 split-lock semantics don't protect against
                     * either. mach_vm_read/write keep a freed view from
                     * faulting the server thread — on failure fall through to
                     * the honest-AV delivery. */
                    else if ((insn & LDAXR_MASK) == 0x085FFC00u ||  /* LDAXR* */
                             (insn & LDAXR_MASK) == 0x085F7C00u)    /* LDXR* */
                    {
                        uint32_t Size = (insn >> 30) & 0x3;
                        uint32_t Rn = (insn >> 5) & 0x1F;
                        uint32_t Rt = insn & 0x1F;
                        uint64_t addr = (Rn == 31) ? __darwin_arm_thread_state64_get_sp(state)
                                                   : state.__x[Rn];
                        uint64_t val = 0;
                        mach_vm_size_t got = 0;
                        if (mach_vm_read_overwrite( mach_task_self(), addr, 1u << Size,
                                                    (mach_vm_address_t)&val, &got ) == KERN_SUCCESS
                            && got == (1u << Size))
                        {
                            int mi, free_mi = -1;
                            if (Rt != 31) state.__x[Rt] = val;
                            for (mi = 0; mi < IOS_EXCL_MON_SLOTS; mi++)
                            {
                                if (ios_excl_mon[mi].valid && ios_excl_mon[mi].thr == thread) break;
                                if (!ios_excl_mon[mi].valid && free_mi < 0) free_mi = mi;
                            }
                            if (mi == IOS_EXCL_MON_SLOTS) mi = (free_mi >= 0) ? free_mi : 0;
                            ios_excl_mon[mi].thr = thread;
                            ios_excl_mon[mi].addr = addr;
                            ios_excl_mon[mi].val = val;
                            ios_excl_mon[mi].size = (uint8_t)Size;
                            ios_excl_mon[mi].valid = 1;
                            __darwin_arm_thread_state64_set_pc_fptr(
                                state, (void *)(uintptr_t)(fault_pc + 4));
                            static volatile int ex_count;
                            int n = __sync_add_and_fetch(&ex_count, 1);
                            if (n <= 8 || (n % 256) == 0)
                                dprintf(STDERR_FILENO,
                                        "[mach_exc] UNALIGNED-EXCL rev=ml431 #%d LDAXR pc=0x%llx addr=0x%llx "
                                        "size=%u val=0x%llx\n",
                                        n, (unsigned long long)fault_pc,
                                        (unsigned long long)addr, 1u << Size,
                                        (unsigned long long)val);
                            handled = 1;
                        }
                    }
                    else if ((insn & 0x3FE0FC00u) == 0x0800FC00u ||  /* STLXR* */
                             (insn & 0x3FE0FC00u) == 0x08007C00u)    /* STXR* */
                    {
                        uint32_t Size = (insn >> 30) & 0x3;
                        uint32_t Rs = (insn >> 16) & 0x1F;
                        uint32_t Rn = (insn >> 5) & 0x1F;
                        uint32_t Rt = insn & 0x1F;
                        uint64_t addr = (Rn == 31) ? __darwin_arm_thread_state64_get_sp(state)
                                                   : state.__x[Rn];
                        uint64_t szmask = (Size == 3) ? ~0ULL : ((1ULL << (8u << Size)) - 1);
                        uint64_t stval = (Rt == 31) ? 0 : (state.__x[Rt] & szmask);
                        uint64_t status = 1;   /* fail-by-default -> loop retries the LDAXR */
                        int mi;
                        for (mi = 0; mi < IOS_EXCL_MON_SLOTS; mi++)
                            if (ios_excl_mon[mi].valid && ios_excl_mon[mi].thr == thread) break;
                        if (mi < IOS_EXCL_MON_SLOTS && ios_excl_mon[mi].addr == addr
                            && ios_excl_mon[mi].size == (uint8_t)Size)
                        {
                            uint64_t cur = 0;
                            mach_vm_size_t got = 0;
                            ios_excl_mon[mi].valid = 0;
                            if (mach_vm_read_overwrite( mach_task_self(), addr, 1u << Size,
                                                        (mach_vm_address_t)&cur, &got ) == KERN_SUCCESS
                                && got == (1u << Size)
                                && (cur & szmask) == (ios_excl_mon[mi].val & szmask)
                                && mach_vm_write( mach_task_self(), addr,
                                                  (vm_offset_t)(uintptr_t)&stval,
                                                  1u << Size ) == KERN_SUCCESS)
                                status = 0;
                        }
                        else if (mi < IOS_EXCL_MON_SLOTS)
                            ios_excl_mon[mi].valid = 0;
                        if (Rs != 31) state.__x[Rs] = status;
                        __darwin_arm_thread_state64_set_pc_fptr(
                            state, (void *)(uintptr_t)(fault_pc + 4));
                        static volatile int sx_count;
                        int n = __sync_add_and_fetch(&sx_count, 1);
                        if (n <= 8 || (n % 256) == 0)
                            dprintf(STDERR_FILENO,
                                    "[mach_exc] UNALIGNED-EXCL rev=ml431 #%d STLXR pc=0x%llx addr=0x%llx "
                                    "size=%u status=%llu\n",
                                    n, (unsigned long long)fault_pc,
                                    (unsigned long long)addr, 1u << Size,
                                    (unsigned long long)status);
                        handled = 1;
                    }
                    else if ((insn & 0x3FA07C00u) == 0x08A07C00u)    /* CAS/CASA/CASL/CASAL */
                    {
                        uint32_t Size = (insn >> 30) & 0x3;
                        uint32_t Rs = (insn >> 16) & 0x1F;
                        uint32_t Rn = (insn >> 5) & 0x1F;
                        uint32_t Rt = insn & 0x1F;
                        uint64_t addr = (Rn == 31) ? __darwin_arm_thread_state64_get_sp(state)
                                                   : state.__x[Rn];
                        uint64_t szmask = (Size == 3) ? ~0ULL : ((1ULL << (8u << Size)) - 1);
                        uint64_t cmp = ((Rs == 31) ? 0 : state.__x[Rs]) & szmask;
                        uint64_t stval = ((Rt == 31) ? 0 : state.__x[Rt]) & szmask;
                        uint64_t cur = 0;
                        mach_vm_size_t got = 0;
                        if (mach_vm_read_overwrite( mach_task_self(), addr, 1u << Size,
                                                    (mach_vm_address_t)&cur, &got ) == KERN_SUCCESS
                            && got == (1u << Size))
                        {
                            int stored = 0;
                            if ((cur & szmask) == cmp)
                                stored = (mach_vm_write( mach_task_self(), addr,
                                                         (vm_offset_t)(uintptr_t)&stval,
                                                         1u << Size ) == KERN_SUCCESS);
                            if ((cur & szmask) == cmp && !stored)
                                goto skip_unaligned_backpatch;  /* write failed: honest AV path */
                            if (Rs != 31) state.__x[Rs] = cur & szmask;  /* CAS returns old value in Rs */
                            __darwin_arm_thread_state64_set_pc_fptr(
                                state, (void *)(uintptr_t)(fault_pc + 4));
                            static volatile int cas_count;
                            int n = __sync_add_and_fetch(&cas_count, 1);
                            if (n <= 8 || (n % 256) == 0)
                                dprintf(STDERR_FILENO,
                                        "[mach_exc] UNALIGNED-EXCL rev=ml431 #%d CAS pc=0x%llx addr=0x%llx "
                                        "size=%u old=0x%llx swapped=%d\n",
                                        n, (unsigned long long)fault_pc,
                                        (unsigned long long)addr, 1u << Size,
                                        (unsigned long long)cur, (cur & szmask) == cmp);
                            handled = 1;
                        }
                    }

                    if (patched)
                    {
                        if (adjust_pc)
                            __darwin_arm_thread_state64_set_pc_fptr(state, (void *)(fault_pc + adjust_pc));
                        static volatile int ub_count = 0;
                        int n = __sync_add_and_fetch(&ub_count, 1);
                        if (n <= 5 || (n % 100) == 0)
                            dprintf(STDERR_FILENO,
                                    "[mach_exc] UNALIGNED-BACKPATCH #%d pc=0x%llx insn=0x%08x addr=0x%llx kind=%s\n",
                                    n, (unsigned long long)fault_pc, insn,
                                    (unsigned long long)fault_addr,
                                    adjust_pc ? "STLR/STLUR" : "LDAR/LDAPR/LDAPUR");
                        /* ml962: this transform writes its half-barrier into a
                         * NEIGHBOURING slot -- rw_pc+4 for the load forms, rw_pc-4
                         * for the store forms -- on the assumption that FEX reserved
                         * that slot. If it did not, the barrier DESTROYS a real
                         * instruction, permanently, in JIT code that will be
                         * re-executed. A destroyed instruction that contributed the
                         * high half of a 64-bit value would produce exactly the
                         * truncation we are chasing, and rdr27 shows 200+ of these
                         * landing on the same guest stack page as R10 (0x...19e,
                         * 0x...20e, 0x...34e vs R10 0x...1b6, all mod 8 == 6).
                         *
                         * So report what was in the slot. `prev_slot` was captured
                         * BEFORE the overwrite. 0xd503201f is NOP = reserved and the
                         * assumption holds; anything else means we are clobbering
                         * real code. Diagnostic only -- no behaviour change yet,
                         * because declining to patch here has no proven fallback. */
                        /* ml963: NAME THE WRITER of the truncated operand.
                         *
                         * ml962 settled that [R10] is already truncated in memory
                         * (0x000000005d450010, high half zero) while the SAME
                         * structure holds a 33-bit pointer full width a few bytes
                         * away -- so this is not a blanket storage failure, it is one
                         * field. The writer was invisible because this report is
                         * capped every-100th; the logged addresses (0x...34e,
                         * 0x...20e, 0x...19e) simply were not it.
                         *
                         * R10's low 12 bits are 0x1b6 in all four runs
                         * (0x16b7ff1b6 / 0x16a1cf1b6 / 0x16977f1b6 / 0x16bccf1b6):
                         * ASLR moves the page, not the offset within it. So filter on
                         * the offset and catch every access to that neighbourhood
                         * regardless of the count.
                         *
                         * The ACCESS SIZE decides who is at fault, and the register
                         * value decides it beyond doubt, because the backpatch runs
                         * BEFORE the store re-executes -- so state.__x[Rt] is exactly
                         * the value about to be written:
                         *   size=4 (32-bit store) and Rt holds the full 64-bit
                         *     pointer  => the GUEST is storing only 32 bits by
                         *     design; the allocation genuinely must be low.
                         *   size=8 (64-bit store) and Rt holds the full pointer, yet
                         *     memory ends up truncated => OUR emulation dropped the
                         *     high word.
                         *   Rt itself already truncated => the truncation happened
                         *     even earlier, in the value's computation. */
                        if ((fault_addr & 0xFFFu) >= 0x190u && (fault_addr & 0xFFFu) <= 0x1d0u)
                        {
                            static volatile int w_count;
                            int wn = __sync_add_and_fetch(&w_count, 1);
                            /* ml964: WATCH THE FIELD, not the instruction.
                             *
                             * ml963 settled that the guest stores FULL-WIDTH
                             * pointers here with 64-bit STLR (0x15ced0011 at
                             * off=0x1ae, high32=1) and that **nothing** faults at
                             * off=0x1b6 -- the field that reads back truncated. So
                             * the corrupting write does not go through this path at
                             * all, and no caught store even covers byte 0x1ba, the
                             * one byte that differs from the correct pointer.
                             *
                             * Chasing the writer instruction has now failed twice.
                             * Watch the memory instead: sample the 8 bytes at the
                             * field on every neighbouring fault and shout on the
                             * transition from full-width to truncated. That bounds
                             * the corruption between two known events, which is what
                             * the search needs -- an ordinary (non-atomic) store, a
                             * bulk copy, or a producer further upstream all look
                             * identical from the instruction side but differ in WHEN.
                             *
                             * The offset is stable across ASLR (0x1b6 in five runs),
                             * so derive the field from the faulting page. */
                            {
                                const mach_vm_address_t fld =
                                    (mach_vm_address_t)((fault_addr & ~0xFFFull) | 0x1b6ull);
                                static volatile uint64_t last_val;
                                static volatile int shouted;
                                uint64_t cur = 0;
                                mach_vm_size_t fg = 0;

                                if (mach_vm_read_overwrite( mach_task_self(), fld, 8,
                                                            (mach_vm_address_t)&cur, &fg ) == KERN_SUCCESS
                                    && fg == 8)
                                {
                                    uint64_t prev = last_val;
                                    last_val = cur;
                                    /* full-width -> truncated, i.e. the high word was
                                     * dropped while the low word kept its shape */
                                    if (prev && (prev >> 32) && !(cur >> 32)
                                        && (uint32_t)prev == (uint32_t)cur && shouted < 4)
                                    {
                                        shouted++;
                                        dprintf(STDERR_FILENO,
                                                "[field] ml964 *** TRUNCATION HAPPENED HERE *** addr=0x%llx "
                                                "was=0x%016llx now=0x%016llx | immediately after event #%d "
                                                "%s off=0x%03x insn=0x%08x pc=0x%llx\n",
                                                (unsigned long long)fld,
                                                (unsigned long long)prev, (unsigned long long)cur, wn,
                                                adjust_pc ? "STORE" : "load",
                                                (unsigned)(fault_addr & 0xFFFu), insn,
                                                (unsigned long long)fault_pc);
                                    }
                                    if (wn <= 96)
                                        dprintf(STDERR_FILENO,
                                                "[field] ml964 #%d after %s off=0x%03x: [0x%llx]=0x%016llx (high32=0x%08llx)\n",
                                                wn, adjust_pc ? "STORE" : "load",
                                                (unsigned)(fault_addr & 0xFFFu),
                                                (unsigned long long)fld, (unsigned long long)cur,
                                                (unsigned long long)(cur >> 32));
                                }
                            }
                            if (wn <= 96)
                            {
                                uint32_t wSize = (insn >> 30) & 0x3u;
                                uint32_t wRt   = insn & 0x1Fu;
                                uint32_t wRn   = (insn >> 5) & 0x1Fu;
                                uint64_t wval  = (wRt == 31) ? 0 : state.__x[wRt];
                                dprintf(STDERR_FILENO,
                                        "[writer] ml963 #%d %s addr=0x%llx (off=0x%03x) insn=0x%08x "
                                        "bytes=%u Rt=x%u Rn=x%u Rt_val=0x%016llx high32=0x%08llx pc=0x%llx -- %s\n",
                                        wn, adjust_pc ? "STORE" : "load",
                                        (unsigned long long)fault_addr,
                                        (unsigned)(fault_addr & 0xFFFu), insn,
                                        1u << wSize, wRt, wRn,
                                        (unsigned long long)wval,
                                        (unsigned long long)(wval >> 32),
                                        (unsigned long long)fault_pc,
                                        !adjust_pc ? "(load, not the writer)"
                                          : (wSize != 3) ? "32-bit-or-narrower STORE => guest truncates by design"
                                          : (wval >> 32) ? "64-bit STORE of a FULL-WIDTH value"
                                          : (wval >= 0x80000000ull) ? "64-bit STORE, Rt looks like a TRUNCATED pointer"
                                                         : "64-bit STORE of a small value (flags/count, not a pointer)");
                            }
                        }
                        if (n <= 24)
                            dprintf(STDERR_FILENO,
                                    "[mach_exc] ml962 backpatch slot %s pc%+d held 0x%08x -- %s\n",
                                    adjust_pc ? "BEFORE" : "AFTER",
                                    adjust_pc ? -4 : 4, prev_slot,
                                    (prev_slot == 0xd503201fu) ? "NOP (reserved, assumption holds)"
                                                               : "NOT A NOP -- REAL INSTRUCTION CLOBBERED");
                        handled = 1;
                    }
                skip_unaligned_backpatch: ;
                }
            }

            /* 4. Emulate stores to JIT-pool RX aliases by redirecting them
             * to the corresponding JIT-pool RW alias address. iOS dual-map
             * blocks W on the RX side even with vm_protect+VM_PROT_COPY,
             * so STR/STP instructions whose target lands in JIT-pool RX
             * have to be emulated. The instruction's other side-effects
             * (Rt unchanged, no flag updates) are nil for STR/STP/STRB/STRH. */
            if (!handled)
            {
                extern void *ios_jit_rx_base_global;
                extern void *ios_jit_rw_base_global;
                extern size_t ios_jit_pool_size_global;
                extern uintptr_t ios_jit_anon_alias_lookup(uintptr_t fault_addr);
                uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
                uintptr_t rw = (uintptr_t)ios_jit_rw_base_global;
                size_t sz = ios_jit_pool_size_global;
                uint64_t fault_pc = (uint64_t)__darwin_arm_thread_state64_get_pc(state);
                /* Two cases: (a) fault on JIT pool RX directly, route via the
                 * RW alias by offset translation. (b) fault on a user-VA that
                 * was vm_remap'd from JIT pool RX (e.g. FEX CodeBuffer): use
                 * the secondary alias table to find the user_VA → RW alias
                 * mapping. */
                uintptr_t rw_addr = 0;
                int in_jit = (rx && rw && sz &&
                              fault_addr >= rx && fault_addr < rx + sz);
                if (in_jit) {
                    rw_addr = rw + (fault_addr - rx);
                } else {
                    rw_addr = ios_jit_anon_alias_lookup(fault_addr);
                }
                /* ml348 DISCRIMINATOR: a write fault with NO alias is a
                 * different bug from a write fault whose instruction we can't
                 * decode, and the two need opposite fixes. Without this the
                 * handler just declines and the thread spins on one address
                 * (ml347). Report which case it is, plus the page's ACTUAL
                 * protection — "r-x, no alias" names an exec-downgraded page
                 * that never got dual-mapped. Capped. */
                if (!rw_addr && (uintptr_t)fault_pc >= 0x100000000ULL)
                {
                    static int noalias_n;
                    if (noalias_n < 8)
                    {
                        mach_vm_address_t na = (mach_vm_address_t)fault_addr;
                        mach_vm_size_t ns = 0;
                        vm_region_basic_info_data_64_t ni;
                        mach_msg_type_number_t nc = VM_REGION_BASIC_INFO_COUNT_64;
                        mach_port_t no = MACH_PORT_NULL;
                        uint32_t ninsn = 0;
                        mach_vm_size_t ngot = 0;
                        noalias_n++;
                        mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)fault_pc, 4,
                                               (mach_vm_address_t)&ninsn, &ngot);
                        if (mach_vm_region(mach_task_self(), &na, &ns, VM_REGION_BASIC_INFO_64,
                                           (vm_region_info_t)&ni, &nc, &no) == KERN_SUCCESS)
                            dprintf(STDERR_FILENO,
                                "[store-noalias] #%d rev=ml348 addr=0x%llx insn=0x%08x pc=0x%llx "
                                "NO pool/anon alias | region 0x%llx+0x%llx prot=%d max=%d "
                                "(prot without W = exec-downgraded page that never got dual-mapped)\n",
                                noalias_n, (unsigned long long)fault_addr, ninsn,
                                (unsigned long long)fault_pc,
                                (unsigned long long)na, (unsigned long long)ns,
                                ni.protection, ni.max_protection);
                        else
                            dprintf(STDERR_FILENO,
                                "[store-noalias] #%d rev=ml348 addr=0x%llx insn=0x%08x pc=0x%llx "
                                "NO alias and NO region (unmapped) — genuine bad pointer\n",
                                noalias_n, (unsigned long long)fault_addr, ninsn,
                                (unsigned long long)fault_pc);
                    }
                }
                if (rw_addr && (uintptr_t)fault_pc >= 0x100000000ULL)
                {
                    uint32_t insn; ios_fault_read_insn( (uint64_t)(uintptr_t)fault_pc, &insn );  /* ml982 */
                    int emulated = 0;
                    /* STP (SIMD&FP, signed offset, 128-bit Q): 10 101 1 1 0 0 0 imm7 Rt2 Rn Rt
                     *   pattern bits 31-22: 10 1011 1000  → top10 = 0x2B8 (= bits 31..22)
                     *   So mask 0xFFC00000 = top10. Match 0x2B8 << 22 = 0xAE000000? Hmm.
                     * Actually: STP q0,q1,[xn,#imm] is `1010 1101 0010 ... `
                     * STP q,q (signed offset): 0xAD0 (top 12), so mask 0xFFE00000 == 0xAD000000.
                     * STP q,q (pre/post-index variants): 0xAD8, 0xACC, etc.
                     * For now, emulate the family: top 7 bits = 0b1010110, bit 31:25 = 0x56,
                     * mask 0xFE000000 matches 0xAC000000 — covers 64/128-bit SIMD STP variants. */
                    /* iOS-Madeira ml629: Q-PAIR STORES — ALL FOUR ADDRESSING MODES.
                     *
                     * The previous test pinned bit23 to 0:
                     *     (insn & 0xFEC00000) == 0xAC000000 || == 0xAD000000
                     * which covers only the two NON-WRITEBACK forms (non-temporal STNP,
                     * bits25:23=000, and signed-offset STP, 010). ULTRAKILL/Mono copies into
                     * its JIT buffer with a 32-byte NEON loop whose store is POST-INDEXED:
                     *     0xac814570 = STP Q16, Q17, [X11], #32     (bits25:23 = 001)
                     * so it fell through to [store-undecoded], the write never completed, and
                     * the process exited 0x80000002. The neighbouring loads in the stream
                     * (0xacc14590 = LDP Q16,Q17,[X12],#32) confirm the memcpy shape.
                     *
                     * Encoding: opc=10 101 V=1 mode(bits25:23) L(bit22) imm7 Rt2 Rn Rt
                     *   000 non-temporal   no writeback
                     *   001 post-index     writeback; store at the OLD base
                     *   010 signed offset  no writeback
                     *   011 pre-index      writeback; store at the NEW base
                     * Mask 0xFE400000 == 0xAC000000 fixes opc/101/V and L=0, leaving the mode
                     * free. L=1 (loads) is deliberately excluded: this is the WRITE-fault
                     * alias path, and reads from the RX view are already permitted.
                     *
                     * 🔑 fault_addr is ALWAYS the effective address the CPU actually used, so
                     * rw_addr is already right in every mode. Only Rn's writeback must be
                     * synthesised, and it derives from fault_addr without trusting the
                     * register: post -> base_new = fault_addr + off; pre -> base_new =
                     * fault_addr (which already includes off).
                     * ⚠️ Omitting that writeback would leave the copy loop on one address
                     * forever — trading a crash for a spin, which is strictly worse.
                     *
                     * STP Q is not architecturally one atomic 32-byte transaction, so two
                     * 16-byte copies are correct. Rn==31 is SP, never __x[31]. */
                    if (have_neon && (insn & 0xFE400000) == 0xAC000000)
                    {
                        const int mode = (insn >> 23) & 0x3; /* 0 stnp, 1 post, 2 offset, 3 pre */
                        const int rt   = insn & 0x1f;
                        const int rt2  = (insn >> 10) & 0x1f;
                        const int rn   = (insn >> 5) & 0x1f;
                        int64_t imm7   = (int64_t)((insn >> 15) & 0x7f);
                        if (imm7 & 0x40) imm7 -= 0x80;          /* sign-extend 7 bits */
                        const int64_t off = imm7 * 16;          /* Q registers scale by 16 */

                        /* The WHOLE 32-byte destination must live in the SAME alias, or the
                         * second copy would land outside it. */
                        uintptr_t rw_end = in_jit ? (uintptr_t)(rw + ((fault_addr + 31) - rx))
                                                  : (uintptr_t)ios_jit_anon_alias_lookup( fault_addr + 31 );
                        if (!rw_end || rw_end != (uintptr_t)rw_addr + 31)
                        {
                            static int stp_span_n;
                            if (stp_span_n < 4)
                                dprintf(STDERR_FILENO,
                                    "[stp-emul] ml629 #%d REFUSING: 32B span leaves the alias "
                                    "(insn=0x%08x addr=0x%llx rw=0x%llx rw_end=0x%llx)\n",
                                    ++stp_span_n, insn, (unsigned long long)fault_addr,
                                    (unsigned long long)rw_addr, (unsigned long long)rw_end);
                        }
                        else
                        {
                            uint64_t base_old = (mode == 3) ? (uint64_t)fault_addr - (uint64_t)off
                                                            : (uint64_t)fault_addr;
                            uint64_t base_new = base_old;
                            int wb = (mode == 1 || mode == 3);

                            memcpy((void *)rw_addr, &neon_state.__v[rt], 16);
                            memcpy((void *)(rw_addr + 16), &neon_state.__v[rt2], 16);

                            if (wb)
                            {
                                base_new = base_old + (uint64_t)off;
                                if (rn == 31) state.__sp = base_new;
                                else          state.__x[rn] = base_new;
                            }
                            emulated = 1;
                            {
                                static int stp_n;
                                if (stp_n < 8)
                                    dprintf(STDERR_FILENO,
                                        "[stp-emul] ml629 #%d insn=0x%08x mode=%s off=%+lld Rt=q%d Rt2=q%d "
                                        "Rn=%s%d addr=0x%llx rw=0x%llx base 0x%llx -> 0x%llx%s\n",
                                        ++stp_n, insn,
                                        mode == 0 ? "stnp" : mode == 1 ? "post" : mode == 2 ? "offset" : "pre",
                                        (long long)off, rt, rt2, rn == 31 ? "s" : "x", rn,
                                        (unsigned long long)fault_addr, (unsigned long long)rw_addr,
                                        (unsigned long long)base_old, (unsigned long long)base_new,
                                        wb ? " (writeback)" : " (no writeback)");
                            }
                        }
                    }
                    /* STR (immediate, unsigned offset, 64-bit): 1111 1001 00 imm12 Rn Rt */
                    else if ((insn & 0xffc00000) == 0xf9000000)
                    {
                        int rt = insn & 0x1f;
                        *(uint64_t *)rw_addr = IOS_STORE_SRC(rt);
                        emulated = 1;
                    }
                    /* STR (immediate, unsigned offset, 32-bit): 1011 1001 00 imm12 Rn Rt */
                    else if ((insn & 0xffc00000) == 0xb9000000)
                    {
                        int rt = insn & 0x1f;
                        *(uint32_t *)rw_addr = (uint32_t)IOS_STORE_SRC(rt);
                        emulated = 1;
                    }
                    /* STRB (immediate, unsigned offset, 8-bit): 0011 1001 00 imm12 Rn Rt */
                    else if ((insn & 0xffc00000) == 0x39000000)
                    {
                        int rt = insn & 0x1f;
                        *(uint8_t *)rw_addr = (uint8_t)IOS_STORE_SRC(rt);
                        emulated = 1;
                    }
                    /* STRH (immediate, unsigned offset, 16-bit): 0111 1001 00 imm12 Rn Rt */
                    else if ((insn & 0xffc00000) == 0x79000000)
                    {
                        int rt = insn & 0x1f;
                        *(uint16_t *)rw_addr = (uint16_t)IOS_STORE_SRC(rt);
                        emulated = 1;
                    }
                    /* STP (signed offset, 64-bit): 10101001 00 imm7 Rt2 Rn Rt */
                    else if ((insn & 0xffc00000) == 0xa9000000)
                    {
                        int rt = insn & 0x1f;
                        int rt2 = (insn >> 10) & 0x1f;
                        *(uint64_t *)rw_addr = IOS_STORE_SRC(rt);
                        *(uint64_t *)(rw_addr + 8) = IOS_STORE_SRC(rt2);
                        emulated = 1;
                    }
                    /* STP (signed offset, 32-bit): 00101001 00 imm7 Rt2 Rn Rt */
                    else if ((insn & 0xffc00000) == 0x29000000)
                    {
                        int rt = insn & 0x1f;
                        int rt2 = (insn >> 10) & 0x1f;
                        *(uint32_t *)rw_addr = (uint32_t)IOS_STORE_SRC(rt);
                        *(uint32_t *)(rw_addr + 4) = (uint32_t)IOS_STORE_SRC(rt2);
                        emulated = 1;
                    }
                    /* STR (register, 64-bit): 1111 1000 001 Rm option S 10 Rn Rt */
                    else if ((insn & 0xffe00c00) == 0xf8200800)
                    {
                        int rt = insn & 0x1f;
                        *(uint64_t *)rw_addr = IOS_STORE_SRC(rt);
                        emulated = 1;
                    }
                    /* STLR (Store-Release Register, 64-bit):
                     *   1100 1000 1001 1111 1111 11nn nnnt tttt   (mask 0xfffffc00, val 0xc89ffc00)
                     * Used by FEX's HandleUnalignedAccess backpatch
                     * (`std::atomic_ref<uint32_t>(PC).store(..., release)` → STLR).
                     * Without this we infinite-loop on unaligned atomic faults
                     * because FEX can't patch its own JIT block on iOS RX-only memory. */
                    else if ((insn & 0xfffffc00) == 0xc89ffc00)
                    {
                        int rt = insn & 0x1f;
                        __atomic_store_n((uint64_t *)rw_addr, IOS_STORE_SRC(rt), __ATOMIC_RELEASE);
                        emulated = 1;
                    }
                    /* STLR (Store-Release Register, 32-bit):
                     *   1000 1000 1001 1111 1111 11nn nnnt tttt   (mask 0xfffffc00, val 0x889ffc00)
                     * Same use case — FEX's backpatch is a 32-bit instruction store. */
                    else if ((insn & 0xfffffc00) == 0x889ffc00)
                    {
                        int rt = insn & 0x1f;
                        __atomic_store_n((uint32_t *)rw_addr, (uint32_t)IOS_STORE_SRC(rt), __ATOMIC_RELEASE);
                        emulated = 1;
                    }
                    /* STLRH (Store-Release 16-bit):
                     *   0100 1000 1001 1111 1111 11nn nnnt tttt   (mask 0xfffffc00, val 0x489ffc00) */
                    else if ((insn & 0xfffffc00) == 0x489ffc00)
                    {
                        int rt = insn & 0x1f;
                        __atomic_store_n((uint16_t *)rw_addr, (uint16_t)IOS_STORE_SRC(rt), __ATOMIC_RELEASE);
                        emulated = 1;
                    }
                    /* STLRB (Store-Release 8-bit):
                     *   0000 1000 1001 1111 1111 11nn nnnt tttt   (mask 0xfffffc00, val 0x089ffc00) */
                    else if ((insn & 0xfffffc00) == 0x089ffc00)
                    {
                        int rt = insn & 0x1f;
                        __atomic_store_n((uint8_t *)rw_addr, (uint8_t)IOS_STORE_SRC(rt), __ATOMIC_RELEASE);
                        emulated = 1;
                    }
                    /* ml1231: STLURB/STLURH/STLUR (FEAT_LRCPC2, store-release with an
                     * unscaled 9-bit offset), what FEX emits for guest stores once the
                     * host reports LRCPC2:
                     *   ss01 1001 000i iiii iiii 00nn nnnt tttt   (mask 0x3fe00c00, val 0x19000000)
                     * fault_addr already includes the offset. A guest store can be
                     * misaligned, so the bytes are copied after a release fence rather
                     * than with an atomic store that could itself alignment-fault. */
                    else if ((insn & 0x3fe00c00) == 0x19000000)
                    {
                        int rt = insn & 0x1f;
                        uint64_t v = IOS_STORE_SRC(rt);
                        __atomic_thread_fence(__ATOMIC_RELEASE);
                        memcpy((void *)rw_addr, &v, 1u << (insn >> 30));
                        emulated = 1;
                    }
                    /* STR (register, 32-bit): 1011 1000 001 Rm option S 10 Rn Rt */
                    else if ((insn & 0xffe00c00) == 0xb8200800)
                    {
                        int rt = insn & 0x1f;
                        *(uint32_t *)rw_addr = (uint32_t)IOS_STORE_SRC(rt);
                        emulated = 1;
                    }
                    /* STR (immediate, post/pre-index, 64-bit): 1111 1000 00 0imm9 0[10]1 Rn Rt */
                    else if ((insn & 0xffe00000) == 0xf8000000 && (insn & 0x800) == 0)
                    {
                        int rt = insn & 0x1f;
                        *(uint64_t *)rw_addr = IOS_STORE_SRC(rt);
                        emulated = 1;
                        /* Post-index (bits 11:10 = 01) / pre-index (bits 11:10 = 11):
                         * MUST update Rn += signed imm9. Without this, memcpy-style
                         * loops would write the same address forever. */
                        int idx_mode = (insn >> 10) & 3;  // bits 11:10
                        if (idx_mode == 1 || idx_mode == 3)
                        {
                            int rn = (insn >> 5) & 0x1f;
                            int imm9 = (insn >> 12) & 0x1ff;
                            if (imm9 & 0x100) imm9 |= ~0x1ff;  // sign-extend 9-bit
                            state.__x[rn] = (uint64_t)((int64_t)state.__x[rn] + imm9);
                        }
                    }
                    /* STR (immediate, post/pre-index, 32-bit): 1011 1000 00 0imm9 0[10]1 Rn Rt */
                    else if ((insn & 0xffe00000) == 0xb8000000 && (insn & 0x800) == 0)
                    {
                        int rt = insn & 0x1f;
                        *(uint32_t *)rw_addr = (uint32_t)IOS_STORE_SRC(rt);
                        emulated = 1;
                        int idx_mode = (insn >> 10) & 3;
                        if (idx_mode == 1 || idx_mode == 3)
                        {
                            int rn = (insn >> 5) & 0x1f;
                            int imm9 = (insn >> 12) & 0x1ff;
                            if (imm9 & 0x100) imm9 |= ~0x1ff;
                            state.__x[rn] = (uint64_t)((int64_t)state.__x[rn] + imm9);
                        }
                    }
                    /* STRB (immediate, post/pre-index, 8-bit): 0011 1000 00 0imm9 0[10]1 Rn Rt
                     * Hits when iOS memcpy handles the trailing bytes after the
                     * 8-byte D-store loop completes (660 bytes = 82*8 + 4 bytes
                     * tail; the tail is byte-by-byte). */
                    else if ((insn & 0xffe00000) == 0x38000000 && (insn & 0x800) == 0)
                    {
                        int rt = insn & 0x1f;
                        *(uint8_t *)rw_addr = (uint8_t)IOS_STORE_SRC(rt);
                        emulated = 1;
                        int idx_mode = (insn >> 10) & 3;
                        if (idx_mode == 1 || idx_mode == 3)
                        {
                            int rn = (insn >> 5) & 0x1f;
                            int imm9 = (insn >> 12) & 0x1ff;
                            if (imm9 & 0x100) imm9 |= ~0x1ff;
                            state.__x[rn] = (uint64_t)((int64_t)state.__x[rn] + imm9);
                        }
                    }
                    /* STRH (immediate, post/pre-index, 16-bit): 0111 1000 00 0imm9 0[10]1 Rn Rt */
                    else if ((insn & 0xffe00000) == 0x78000000 && (insn & 0x800) == 0)
                    {
                        int rt = insn & 0x1f;
                        *(uint16_t *)rw_addr = (uint16_t)IOS_STORE_SRC(rt);
                        emulated = 1;
                        int idx_mode = (insn >> 10) & 3;
                        if (idx_mode == 1 || idx_mode == 3)
                        {
                            int rn = (insn >> 5) & 0x1f;
                            int imm9 = (insn >> 12) & 0x1ff;
                            if (imm9 & 0x100) imm9 |= ~0x1ff;
                            state.__x[rn] = (uint64_t)((int64_t)state.__x[rn] + imm9);
                        }
                    }
                    /* SIMD/FP STR (immediate, post/pre-index, D-reg = 64-bit):
                     * 11 111 1 00 00 0 imm9 idx Rn Rt   — encoding 0xfc000400 base.
                     * The fc008600 = `str d0, [x16], #8` from iOS memcpy hits
                     * this when copying compiled FEX blocks to RX-only memory. */
                    else if ((insn & 0xffe00000) == 0xfc000000 && (insn & 0xc00) != 0)
                    {
                        int rt = insn & 0x1f;
                        if (have_neon)
                        {
                            /* Low 64 bits of the 128-bit Q-reg = D-reg. */
                            memcpy((void *)rw_addr, &neon_state.__v[rt], 8);
                            emulated = 1;
                            int idx_mode = (insn >> 10) & 3;
                            if (idx_mode == 1 || idx_mode == 3)
                            {
                                int rn = (insn >> 5) & 0x1f;
                                int imm9 = (insn >> 12) & 0x1ff;
                                if (imm9 & 0x100) imm9 |= ~0x1ff;
                                state.__x[rn] = (uint64_t)((int64_t)state.__x[rn] + imm9);
                            }
                        }
                    }
                    /* SIMD/FP STR (immediate, post/pre-index, S-reg = 32-bit):
                     * 10 111 1 00 00 0 imm9 idx Rn Rt   — base 0xbc000400. */
                    else if ((insn & 0xffe00000) == 0xbc000000 && (insn & 0xc00) != 0)
                    {
                        int rt = insn & 0x1f;
                        if (have_neon)
                        {
                            memcpy((void *)rw_addr, &neon_state.__v[rt], 4);
                            emulated = 1;
                            int idx_mode = (insn >> 10) & 3;
                            if (idx_mode == 1 || idx_mode == 3)
                            {
                                int rn = (insn >> 5) & 0x1f;
                                int imm9 = (insn >> 12) & 0x1ff;
                                if (imm9 & 0x100) imm9 |= ~0x1ff;
                                state.__x[rn] = (uint64_t)((int64_t)state.__x[rn] + imm9);
                            }
                        }
                    }
                    /* SIMD/FP STR (immediate, post/pre-index, Q-reg = 128-bit):
                     * 00 111 1 00 10 0 imm9 idx Rn Rt   — base 0x3c800400. */
                    else if ((insn & 0xffe00000) == 0x3c800000 && (insn & 0xc00) != 0)
                    {
                        int rt = insn & 0x1f;
                        if (have_neon)
                        {
                            memcpy((void *)rw_addr, &neon_state.__v[rt], 16);
                            emulated = 1;
                            int idx_mode = (insn >> 10) & 3;
                            if (idx_mode == 1 || idx_mode == 3)
                            {
                                int rn = (insn >> 5) & 0x1f;
                                int imm9 = (insn >> 12) & 0x1ff;
                                if (imm9 & 0x100) imm9 |= ~0x1ff;
                                state.__x[rn] = (uint64_t)((int64_t)state.__x[rn] + imm9);
                            }
                        }
                    }
                    /* SIMD/FP STUR (immediate, UNSCALED, Q-reg = 128-bit):
                     * 00 111 1 00 10 0 imm9 00 Rn Rt   — 0x3c800000, bits[11:10]==00.
                     * The pre/post-index branch above requires (insn & 0xc00) != 0,
                     * so the unscaled form fell straight through to "undecoded" —
                     * the [store-undecoded] "ADD THIS ENCODING" line in ml592.
                     * NO writeback: unscaled STUR does not modify Rn (the
                     * post-indexed encoding is 0x3c9f04c0, not 0x3c9f00c0). */
                    else if ((insn & 0xffe00c00) == 0x3c800000)
                    {
                        int rt = insn & 0x1f;
                        if (have_neon)
                        {
                            memcpy((void *)rw_addr, &neon_state.__v[rt], 16);
                            emulated = 1;
                        }
                    }
                    /* GPR STR (immediate, unsigned offset, 64-bit X-reg):
                     *   1111 1001 00 imm12 Rn Rt   (base 0xf9000000, mask 0xffc00000)
                     * Hits for `str xN, [xM, #imm]` and `str xN, [xM]` —
                     * what the C compiler emits for `*ptr = uint64_value`.
                     * Wine's PE loader / ARM64EC compiler-generated code triggers this
                     * when initializing data in a page that's been mprotect'd RX-only
                     * on iOS. fault_addr already includes the imm12 offset. */
                    else if ((insn & 0xffc00000) == 0xf9000000)
                    {
                        int rt = insn & 0x1f;
                        *(uint64_t *)rw_addr = IOS_STORE_SRC(rt);
                        emulated = 1;
                    }
                    /* GPR STR (immediate, unsigned offset, 32-bit W-reg):
                     *   1011 1001 00 imm12 Rn Rt   (base 0xb9000000, mask 0xffc00000)
                     * `*ptr32 = uint32_value` analogue. */
                    else if ((insn & 0xffc00000) == 0xb9000000)
                    {
                        int rt = insn & 0x1f;
                        *(uint32_t *)rw_addr = (uint32_t)IOS_STORE_SRC(rt);
                        emulated = 1;
                    }
                    /* SIMD/FP STR (immediate, unsigned offset, D-reg): 11 111 1 01 00 imm12 Rn Rt */
                    else if ((insn & 0xffc00000) == 0xfd000000)
                    {
                        int rt = insn & 0x1f;
                        if (have_neon)
                        {
                            memcpy((void *)rw_addr, &neon_state.__v[rt], 8);
                            emulated = 1;
                        }
                    }
                    /* SIMD/FP STR (immediate, unsigned offset, S-reg): 10 111 1 01 00 imm12 Rn Rt */
                    else if ((insn & 0xffc00000) == 0xbd000000)
                    {
                        int rt = insn & 0x1f;
                        if (have_neon)
                        {
                            memcpy((void *)rw_addr, &neon_state.__v[rt], 4);
                            emulated = 1;
                        }
                    }
                    /* SIMD/FP STR (immediate, unsigned offset, Q-reg): 00 111 1 01 10 imm12 Rn Rt */
                    else if ((insn & 0xffc00000) == 0x3d800000)
                    {
                        int rt = insn & 0x1f;
                        if (have_neon)
                        {
                            memcpy((void *)rw_addr, &neon_state.__v[rt], 16);
                            emulated = 1;
                        }
                    }
                    /* ml350: STRB (register offset): 0011 1000 001 Rm opt S 10 Rn Rt
                     * (mask 0xffe00c00, val 0x38200800). FEX's own STLRB backpatch
                     * rewrites to DMB+`strb wN,[xM,xzr]` — chrome_elf writing its
                     * interception thunk bytes to an anon-RWX page hit this and
                     * looped (ml349: insn 0x383f68c8). fault_addr is already the
                     * final address; no base/offset math needed. */
                    else if ((insn & 0xffe00c00) == 0x38200800)
                    {
                        int rt = insn & 0x1f;
                        *(uint8_t *)rw_addr = (uint8_t)IOS_STORE_SRC(rt);
                        emulated = 1;
                    }
                    /* ml350: STRH (register offset): 0111 1000 001 ... (val 0x78200800) */
                    else if ((insn & 0xffe00c00) == 0x78200800)
                    {
                        int rt = insn & 0x1f;
                        *(uint16_t *)rw_addr = (uint16_t)IOS_STORE_SRC(rt);
                        emulated = 1;
                    }
                    /* ml1276: SIMD&FP STR (register offset), B/H/S/D/Q:
                     *   size 111 1 00 opc(1)0 1 Rm option S 10 Rn Rt
                     *   mask 0x3f600c00, value 0x3c200800; opc<1> picks Q (size 00 only).
                     * FEX addresses 32-bit guest memory as [x19, wN, uxtw] (x19 = the
                     * guest window), so a guest SSE store becomes STR qN, [x19, wM, uxtw].
                     * Terraria's Mono x86 JIT copied into its RWX code buffer with one
                     * (0x3cab4a70) and, undecoded, looped through FEX's SMC handler 2000
                     * times: FEX re-granted RWX, the alias page stays physically RX.
                     * The address is taken from the registers rather than fault_addr,
                     * which need not be the start of an access that crosses into the
                     * faulting page; each 16 KB page of the destination takes its own
                     * alias, and the store is refused unless all of it has one. */
                    else if ((insn & 0x3f600c00) == 0x3c200800)
                    {
                        const unsigned size = insn >> 30;
                        const unsigned bytes = ((insn >> 23) & 1) ? (size == 0 ? 16u : 0u) : (1u << size);
                        const unsigned option = (insn >> 13) & 7;
                        const int rt = insn & 0x1f, rn = (insn >> 5) & 0x1f, rm = (insn >> 16) & 0x1f;

                        if (have_neon && bytes && (option & 2))  /* option<1> = 0 is unallocated */
                        {
                            uint64_t off = IOS_STORE_SRC(rm), ea, a;
                            uintptr_t part_rw[2];
                            unsigned part_len[2], parts = 0, done = 0, i;

                            if (option == 2) off = (uint32_t)off;                        /* UXTW */
                            else if (option == 6) off = (uint64_t)(int64_t)(int32_t)off; /* SXTW */
                            if (insn & 0x1000) off <<= __builtin_ctz(bytes);
                            ea = (rn == 31 ? state.__sp : state.__x[rn]) + off;
                            while (done < bytes && parts < 2)
                            {
                                unsigned len = bytes - done;
                                a = ea + done;
                                if (len > 0x4000 - (a & 0x3fff)) len = 0x4000 - (unsigned)(a & 0x3fff);
                                part_rw[parts] = (rx && rw && sz && a >= rx && a - rx <= sz - len)
                                                 ? rw + (a - rx) : ios_jit_anon_alias_lookup( (uintptr_t)a );
                                if (!part_rw[parts]) break;
                                part_len[parts++] = len;
                                done += len;
                            }
                            if (done == bytes)
                            {
                                const uint8_t *src = (const uint8_t *)&neon_state.__v[rt];
                                for (i = 0, done = 0; i < parts; done += part_len[i], i++)
                                    memcpy( (void *)part_rw[i], src + done, part_len[i] );
                                emulated = 1;
                            }
                            {
                                static int simd_reg_n;
                                if (simd_reg_n < 4)
                                    dprintf(STDERR_FILENO,
                                        "[simd-str-reg] ml1276 #%d insn=0x%08x bytes=%u ea=0x%llx fault=0x%llx parts=%u %s\n",
                                        ++simd_reg_n, insn, bytes, (unsigned long long)ea,
                                        (unsigned long long)fault_addr, parts,
                                        emulated ? "emulated" : "REFUSED: a page of the store has no alias");
                            }
                        }
                    }
                    /* ml1283: the immediate-offset pair and SIMD&FP stores the cases above
                     * miss, with the base writeback the indexed forms need:
                     *   STP/STNP Wt|Xt, post-index, pre-index, non-temporal:
                     *     sf 0 101 0 0 mode(2) 0 imm7 Rt2 Rn Rt, mask 0x7e400000 val 0x28000000
                     *     (mode 10, signed offset, is matched earlier);
                     *   SIMD&FP STUR and STR post-/pre-index, B/H/S/D/Q:
                     *     size 111 1 00 opc(1)0 0 imm9 mode(2) Rn Rt, mask 0x3f600000 val 0x3c000000
                     *     (mode 00 unscaled, 01 post, 11 pre; 10 is unallocated).
                     * A 64-bit .NET program reached both, each an access violation while
                     * undecoded: ntdll's own STP X9, X8, [X10, #0x80]! (0xa9882149)
                     * initialising a critical section mscoree had placed in RWX memory,
                     * and Mono's x86 JIT writing a float into its code buffer, translated
                     * as STUR S0, [X19, #41] (0xbc029260). As ml1276: the address comes from
                     * the registers, each 16 KB page takes its own alias, the store is
                     * refused unless all of it has one, and Rn is written back only after
                     * the whole store. Rn == 31 is SP. */
                    else if (((insn & 0x7e400000) == 0x28000000 && ((insn >> 23) & 3) != 2)
                             || ((insn & 0x3f600000) == 0x3c000000 && ((insn >> 10) & 3) != 2))
                    {
                        const int pair = (insn & 0x3c000000) == 0x28000000;
                        const int rt = insn & 0x1f, rn = (insn >> 5) & 0x1f;
                        uint8_t src[16];
                        unsigned bytes = 0;
                        int64_t imm = 0;
                        int post = 0, wb = 0;

                        if (pair)
                        {
                            const unsigned mode = (insn >> 23) & 3;   /* 0 stnp, 1 post, 3 pre */
                            const unsigned elem = (insn >> 31) ? 8u : 4u;
                            int64_t imm7 = (int64_t)((insn >> 15) & 0x7f);
                            uint64_t a = IOS_STORE_SRC(rt), b = IOS_STORE_SRC((insn >> 10) & 0x1f);
                            if (imm7 & 0x40) imm7 -= 0x80;
                            imm = imm7 * (int64_t)elem;
                            post = mode == 1;
                            wb = mode == 1 || mode == 3;
                            bytes = 2 * elem;
                            memcpy( src, &a, elem );
                            memcpy( src + elem, &b, elem );
                        }
                        else if (have_neon)
                        {
                            const unsigned size = insn >> 30, mode = (insn >> 10) & 3;
                            int64_t imm9 = (int64_t)((insn >> 12) & 0x1ff);
                            if (imm9 & 0x100) imm9 -= 0x200;
                            imm = imm9;
                            post = mode == 1;
                            wb = mode != 0;
                            bytes = ((insn >> 23) & 1) ? (size == 0 ? 16u : 0u) : (1u << size);
                            memcpy( src, &neon_state.__v[rt], 16 );
                        }
                        if (bytes)
                        {
                            const uint64_t base = rn == 31 ? state.__sp : state.__x[rn];
                            const uint64_t ea = post ? base : base + (uint64_t)imm;
                            uint64_t a;
                            uintptr_t part_rw[2];
                            unsigned part_len[2], parts = 0, done = 0, i;

                            while (done < bytes && parts < 2)
                            {
                                unsigned len = bytes - done;
                                a = ea + done;
                                if (len > 0x4000 - (a & 0x3fff)) len = 0x4000 - (unsigned)(a & 0x3fff);
                                part_rw[parts] = (rx && rw && sz && a >= rx && a - rx <= sz - len)
                                                 ? rw + (a - rx) : ios_jit_anon_alias_lookup( (uintptr_t)a );
                                if (!part_rw[parts]) break;
                                part_len[parts++] = len;
                                done += len;
                            }
                            if (done == bytes)
                            {
                                for (i = 0, done = 0; i < parts; done += part_len[i], i++)
                                    memcpy( (void *)part_rw[i], src + done, part_len[i] );
                                if (wb)
                                {
                                    if (rn == 31) state.__sp = base + (uint64_t)imm;
                                    else          state.__x[rn] = base + (uint64_t)imm;
                                }
                                emulated = 1;
                            }
                            {
                                static int imm_store_n;
                                if (imm_store_n < 4)
                                    dprintf(STDERR_FILENO,
                                        "[imm-store] ml1283 #%d insn=0x%08x %s bytes=%u ea=0x%llx fault=0x%llx%s %s\n",
                                        ++imm_store_n, insn, pair ? "stp" : "simd", bytes,
                                        (unsigned long long)ea, (unsigned long long)fault_addr,
                                        wb ? " (writeback)" : "",
                                        emulated ? "emulated" : "REFUSED: a page of the store has no alias");
                            }
                        }
                    }
                    /* ml1284: STXR / STLXR Ws, Wt|Xt, [Xn] into an aliased page.
                     *   size 001000 0 0 0 Rs o0 11111 Rn Rt, mask 0x3fe07c00 val 0x08007c00
                     * The paired LDXR/LDAXR read the RX view and succeeded; only the store
                     * faults, so the exclusive monitor never sees it and replaying it as a
                     * plain store would lose a racing update. ntdll's RtlEnterCriticalSection
                     * (LDAXR W9, [X8]; ADD W10, W9, #1; STLXR W11, W10, [X8]) reached this on
                     * a critical section a 64-bit .NET runtime keeps in its RWX memory.
                     * The LL/SC pair becomes a compare-and-swap on the RW alias: the expected
                     * value is the register the matching load filled, found by scanning back
                     * at most 8 instructions for an LDXR/LDAXR of the same Rn and size. An
                     * ADD/SUB(S) immediate between that updates that register in place (the
                     * InterlockedDecrement shape LDAXR W9; SUBS W9, W9, #1; STLXR W10, W9 of
                     * RtlLeaveCriticalSection) is undone to recover the loaded value; any
                     * other instruction that may write it (anything but a branch on it)
                     * refuses the emulation. Ws = 0 when the swap succeeds and
                     * 1 when the value changed, so the guest's loop retries as on hardware.
                     * Every write to such a page traps and is handled on the one Mach
                     * exception thread, and the CAS is a real atomic on the shared pages. */
                    else if ((insn & 0x3fe07c00) == 0x08007c00)
                    {
                        const unsigned size = insn >> 30;
                        const int rs = (insn >> 16) & 0x1f, rn = (insn >> 5) & 0x1f, rt = insn & 0x1f;
                        const uint64_t mask = size == 3 ? ~0ull : ((1ull << (8u << size)) - 1);
                        const uint64_t ea = rn == 31 ? state.__sp : state.__x[rn];
                        int ld_rt = -1, k, clobbered = 0;
                        uint64_t delta = 0;   /* what in-place ADD/SUB immediates added to it */
                        uint32_t prev;

                        for (k = 1; k <= 8 && ld_rt < 0 && !clobbered; k++)
                        {
                            if (!ios_fault_read_insn( (uint64_t)(uintptr_t)fault_pc - 4u * k, &prev )) break;
                            if ((prev & 0x3fff7c00) == 0x085f7c00 && (prev >> 30) == size
                                && (int)((prev >> 5) & 0x1f) == rn)
                                ld_rt = prev & 0x1f;                       /* LDXR / LDAXR */
                        }
                        if (ld_rt >= 0 && ld_rt != 31)
                        {
                            for (k = k - 2; k >= 1 && !clobbered; k--)  /* the instructions between */
                            {
                                if (!ios_fault_read_insn( (uint64_t)(uintptr_t)fault_pc - 4u * k, &prev )) { clobbered = 1; break; }
                                if ((int)(prev & 0x1f) != ld_rt) continue;
                                if ((prev & 0x7e000000) == 0x34000000          /* CBZ / CBNZ */
                                    || (prev & 0x7e000000) == 0x36000000       /* TBZ / TBNZ */
                                    || (prev & 0xff000010) == 0x54000000)      /* B.cond */
                                    continue;
                                /* ADD/SUB(S) immediate, Rd == Rn == the loaded register, at the
                                 * load's width: sf op S 100010 sh imm12 Rn Rd */
                                if ((prev & 0x1f800000) == 0x11000000 && (int)((prev >> 5) & 0x1f) == ld_rt
                                    && (prev >> 31) == (size == 3))
                                {
                                    uint64_t imm = (prev >> 10) & 0xfff;
                                    if (prev & 0x400000) imm <<= 12;
                                    delta += (prev & 0x40000000) ? (uint64_t)0 - imm : imm;
                                    continue;
                                }
                                clobbered = 1;
                            }
                        }
                        if (ld_rt >= 0 && ld_rt != 31 && !clobbered && rw_addr && !(ea & ((1u << size) - 1))
                            && (uint64_t)fault_addr == ea)
                        {
                            const uint64_t expect = (state.__x[ld_rt] - delta) & mask, val = IOS_STORE_SRC(rt) & mask;
                            int ok = 0;
                            switch (size)
                            {
                            case 0: { uint8_t  e = (uint8_t)expect;  ok = __atomic_compare_exchange_n( (uint8_t  *)rw_addr, &e, (uint8_t)val,  0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST ); break; }
                            case 1: { uint16_t e = (uint16_t)expect; ok = __atomic_compare_exchange_n( (uint16_t *)rw_addr, &e, (uint16_t)val, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST ); break; }
                            case 2: { uint32_t e = (uint32_t)expect; ok = __atomic_compare_exchange_n( (uint32_t *)rw_addr, &e, (uint32_t)val, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST ); break; }
                            default:{ uint64_t e = expect;           ok = __atomic_compare_exchange_n( (uint64_t *)rw_addr, &e, val,           0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST ); break; }
                            }
                            if (rs != 31) state.__x[rs] = ok ? 0 : 1;
                            emulated = 1;
                        }
                        {
                            static int excl_n;
                            if (excl_n < 8)
                                dprintf(STDERR_FILENO,
                                    "[excl-store] ml1284 #%d insn=0x%08x size=%u ea=0x%llx load-reg=%d delta=%lld%s %s\n",
                                    ++excl_n, insn, 1u << size, (unsigned long long)ea, ld_rt,
                                    (long long)delta, clobbered ? " (overwritten)" : "",
                                    emulated ? (rs != 31 && state.__x[rs] ? "emulated: value changed, retry" : "emulated")
                                             : "REFUSED: no matching LDXR/LDAXR");
                        }
                    }


                    /* iOS-Madeira ml626: SWP{A}{L}{B,H} — ATOMIC SWAP.
                     *
                     * Encoding (atomic memory operation, o3=1 opc=000):
                     *   size(2) 111 V=0 00 A R 1 Rs(5) o3=1 opc(3)=000 00 Rn(5) Rt(5)
                     *   mask 0x3F20FC00, value 0x38208000
                     * Semantics: old = mem[Rn]; mem[Rn] = Rs; Rt = old.
                     *
                     * ULTRAKILL/Mono reached this as `SWPAL X26, X26, [X6]`
                     * (insn 0xf8fa80da) writing into its own JIT code buffer. The alias
                     * resolved correctly (the ml350 discriminator said so) but there was
                     * no decode, so the write never completed and the ml461 guard counted
                     * 2,000 identical redeliveries before terminating the process.
                     *
                     * ⚠️ THIS MUST BE GENUINELY ATOMIC. FEX emits SWPAL precisely to
                     * preserve an x86 LOCK XCHG; a read-then-write here would silently
                     * drop that guarantee — the same defect already on record against the
                     * #71 unaligned-atomic emulator. __ATOMIC_SEQ_CST is STRONGER than
                     * SWPAL's acquire-release, which is safe rather than wrong. The RW
                     * alias maps the SAME physical pages as the faulting RX view, so the
                     * atomic applies to the memory the guest actually shares.
                     *
                     * ⛔ Deliberately NOT extended to LDADD/LDCLR/LDSET/CAS here. Those
                     * encodings appear in this run only AFTER the SWPAL was mishandled,
                     * inside FEX's exception path, so they are probably fallout. A wide
                     * speculative decoder carries more correctness surface than this
                     * blocker justifies — add families when they actually appear. */
                    else if ((insn & 0x3F20FC00) == 0x38208000)
                    {
                        int size_lg2 = (insn >> 30) & 0x3;
                        int rs = (insn >> 16) & 0x1f;   /* value to store  */
                        int rt = insn & 0x1f;           /* old value lands here */
                        uint64_t align_mask = (1ULL << size_lg2) - 1;

                        /* An unaligned atomic cannot be emulated atomically. Fall through
                         * to the discriminator rather than quietly doing something weaker. */
                        if (rw_addr & align_mask)
                        {
                            static int swp_unalign_n;
                            if (swp_unalign_n < 4)
                                dprintf(STDERR_FILENO,
                                    "[swp-emul] ml626 #%d REFUSING unaligned atomic: insn=0x%08x size=%d "
                                    "addr=0x%llx rw=0x%llx\n",
                                    ++swp_unalign_n, insn, 1 << size_lg2,
                                    (unsigned long long)fault_addr, (unsigned long long)rw_addr);
                        }
                        else
                        {
                            uint64_t in = (rs == 31) ? 0 : state.__x[rs];
                            uint64_t old;
                            switch (size_lg2)
                            {
                            case 0:  old = __atomic_exchange_n((uint8_t  *)rw_addr, (uint8_t )in, __ATOMIC_SEQ_CST); break;
                            case 1:  old = __atomic_exchange_n((uint16_t *)rw_addr, (uint16_t)in, __ATOMIC_SEQ_CST); break;
                            case 2:  old = __atomic_exchange_n((uint32_t *)rw_addr, (uint32_t)in, __ATOMIC_SEQ_CST); break;
                            default: old = __atomic_exchange_n((uint64_t *)rw_addr,           in, __ATOMIC_SEQ_CST); break;
                            }
                            if (rt != 31) state.__x[rt] = old;  /* XZR discards the result */
                            emulated = 1;

                            /* ml648: THIS is Mono's backpatcher, and this is the fault
                             * FEX has never been allowed to see.
                             *
                             * On Windows the write traps, HandleRWXAccessViolation runs,
                             * DetectMonoBackpatcherBlock recognises the XCHG and recompiles
                             * the block so the store becomes a direct MonoBackpatcherWrite
                             * call — no fault at all. On iOS we emulate here first, so that
                             * optimisation has never once fired: [mono-cfg] says HOOKS
                             * ARMED yet "Detected mono backpatcher" appears zero times,
                             * and the bill is 40,639 exceptions/sec mean, 88,064 peak.
                             *
                             * Record RAW FACTS ONLY. No guest-RIP reconstruction, no opcode
                             * decode, no allocation, no formatting, no locks, and above all
                             * no call into ARM64EC code (ml613 crashed every launch doing
                             * that). x28 is FEX's state frame, x18 the TEB; both are just
                             * numbers here and are treated as untrusted. Everything is
                             * interpreted later at the FEX safe point. */
                            if (size_lg2 == 3)
                                ios_mono_bridge_capture( state.__x[18], state.__x[28],
                                                         (uint64_t)state.__pc,
                                                         (uint64_t)fault_addr );
                            {
                                static int swp_n;
                                if (swp_n < 8)
                                    dprintf(STDERR_FILENO,
                                        "[swp-emul] ml626 #%d insn=0x%08x size=%d Rs=x%d Rt=x%d addr=0x%llx "
                                        "rw=0x%llx in=0x%llx old=0x%llx\n",
                                        ++swp_n, insn, 1 << size_lg2, rs, rt,
                                        (unsigned long long)fault_addr, (unsigned long long)rw_addr,
                                        (unsigned long long)in, (unsigned long long)old);
                            }
                        }
                    }
                    /* FEX's native backpatch lock uses CASAL on the pool RX
                     * view. Handle it before Mach-to-guest delivery; otherwise
                     * a host-runtime fault escapes into the guest's VEH.
                     * Deliberately limited to full-width accesses within the
                     * existing pool alias; no new mapping or permission grant. */
                    if (!emulated && in_jit &&
                        (insn & 0xbfa07c00u) == 0x88a07c00u)
                    {
                        unsigned cas_width = (insn & 0x40000000u) ? 8 : 4;
                        if (sz >= cas_width && fault_addr - rx <= sz - cas_width &&
                            ios_mach_emulate_cas(insn, rw_addr, state.__x))
                        {
                            static unsigned cas_mach_logs;
                            emulated = 1;
                            if (cas_mach_logs++ < 16)
                                dprintf(STDERR_FILENO,
                                        "[mach-cas] insn=%08x pc=%llx addr=%llx rw=%llx width=%u\n",
                                        insn, (unsigned long long)fault_pc,
                                        (unsigned long long)fault_addr,
                                        (unsigned long long)rw_addr, cas_width);
                        }
                    }
                    /* ml350 DISCRIMINATOR: alias EXISTS but the instruction is not
                     * in this decode list — every such miss previously cost a full
                     * run to name (ml349's STRB-reg took one). Print the insn so
                     * the next gap is a one-line diagnosis. Capped. */
                    if (!emulated)
                    {
                        static int undecoded_n;
                        if (undecoded_n < 8)
                            dprintf(STDERR_FILENO,
                                "[store-undecoded] #%d rev=ml350 insn=0x%08x pc=0x%llx addr=0x%llx "
                                "rw_addr=0x%llx — alias OK, ADD THIS ENCODING to the case-4 emulator\n",
                                ++undecoded_n, insn, (unsigned long long)fault_pc,
                                (unsigned long long)fault_addr, (unsigned long long)rw_addr);
                    }
                    if (emulated)
                    {
                        /* ml635: record that this alias page was written. FEX's cached
                         * translation is NOT invalidated here (the ARM64EC path would call
                         * HandleRWXAccessViolation); this counter is what proves whether a
                         * page was filled AFTER its translation was compiled. */
                        {
                            extern void ios_jit_anon_alias_note_write( unsigned long long );
                            ios_jit_anon_alias_note_write( (unsigned long long)fault_addr );

                            /* ================ ml691 PAGE-GRANULAR W^X ==========
                             *
                             * ml690 attributed 98% of ~8.7M emulated stores to
                             * ONE thread -- port 0x8d5b == wine tid 007c == the
                             * Book of the Dead MAIN thread, which also holds
                             * fexlock while it runs. Every one of those faults is
                             * a Mach round trip that suspends the frame-critical
                             * thread, serviced by a single handler running at 86%
                             * duty. That is the largest measured cost in the app.
                             *
                             * WHY THIS IS SAFER THAN IT LOOKS: the ml635 comment
                             * in this file records that this path "NEVER
                             * invalidates FEX's cached translation". So the fault
                             * buys no coherence TODAY -- it is pure cost. Letting
                             * the store land directly loses nothing we currently
                             * have.
                             *
                             * Mechanism: drop PROT_EXEC and add PROT_WRITE on the
                             * guest page. FEX never executes the guest page (it
                             * executes its own translated host code), so removing
                             * exec is inert for normal operation -- and if
                             * anything ever DOES execute there we take an exec
                             * fault and can promote back, which is the re-promote
                             * hook a NOEXEC fault could not otherwise give us.
                             *
                             * Demote only after a page has faulted repeatedly, so
                             * one-off writes never change page state. Disable at
                             * runtime with Documents/madeira-wx.txt containing 0. */
                            {
                                /* ml693: BACK TO 32. ml691 proved threshold 32 safe over
                                 * 192 demotions with zero re-promotions; ml692 changed the
                                 * table size AND dropped the threshold to 8 in one build and
                                 * crashed the main thread early (c0000005 reading
                                 * 0x7049f04be820, far outside the 512GB user VA). Because two
                                 * variables moved together the run cannot say which caused it,
                                 * so revert to the proven value and keep ONLY the table fix --
                                 * the table was the measured limiter, the threshold was not. */
                                /* ml694: EXACT ml691 shape -- 256-entry linear table,
                                 * threshold 32. This is the configuration that ran a full
                                 * session cleanly; the 32K hash is reverted, not resized. */
                                enum { WX_SLOTS = 256, WX_THRESHOLD = 32 };
                                static struct { unsigned long long page; unsigned n, done; } wx[WX_SLOTS];
                                static volatile unsigned wx_demoted, wx_failed, wx_full;
                                unsigned long long pg = (unsigned long long)fault_addr & ~0x3fffull;
                                extern int ios_wx_enabled( void );
                                int wi, victim = -1;

                                if (ios_wx_enabled())
                                {
                                    for (wi = 0; wi < WX_SLOTS; wi++)
                                    {
                                        if (wx[wi].page == pg) break;
                                        if (!wx[wi].page && victim < 0) victim = wi;
                                    }
                                    if (wi == WX_SLOTS)
                                    {
                                        if (victim < 0) { __sync_add_and_fetch( &wx_full, 1 ); goto wx_done; }
                                        wi = victim; wx[wi].page = pg; wx[wi].n = 0; wx[wi].done = 0;
                                    }
                                    if (!wx[wi].done && ++wx[wi].n >= WX_THRESHOLD)
                                    {
                                        int q, sticky = 0, slot = -1;
                                        wx[wi].done = 1;
                                        for (q = 0; q < IOS_WX_MAX; q++)
                                        {
                                            if (ios_wx_pages[q].page == pg)
                                            { sticky = ios_wx_pages[q].sticky; slot = q; break; }
                                            if (!ios_wx_pages[q].page && slot < 0) slot = q;
                                        }
                                        if (sticky) goto wx_done;      /* proven to hold code */
                                        if (mprotect( (void *)(uintptr_t)pg, 0x4000,
                                                      PROT_READ | PROT_WRITE ) == 0)
                                        {
                                            unsigned d = __sync_add_and_fetch( &wx_demoted, 1 );
                                            if (slot >= 0)
                                            { ios_wx_pages[slot].page = pg; ios_wx_pages[slot].demoted = 1; }
                                            if (d <= 4 || (d & 0x3f) == 0)
                                                dprintf(STDERR_FILENO,
                                                    "[wx] ml694 demoted=%u failed=%u table-full=%u "
                                                    "(latest 0x%llx)\n", d, wx_failed, wx_full, pg);
                                        }
                                        else
                                        {
                                            unsigned f = __sync_add_and_fetch( &wx_failed, 1 );
                                            if (f <= 4)
                                                dprintf(STDERR_FILENO,
                                                    "[wx] ml694 mprotect FAILED 0x%llx errno=%d\n", pg, errno);
                                        }
                                    }
                                }
wx_done: ;
                            }
                        }
                        /* Advance PC past the emulated instruction */
                        __darwin_arm_thread_state64_set_pc_fptr(state,
                            (void *)(uintptr_t)(fault_pc + 4));
                        handled = 1;
                        static volatile int emul_count = 0;
                        int ec = __sync_add_and_fetch(&emul_count, 1);

                        /* ============ ml680 WHAT DOES A FAULT ACTUALLY COST? ==
                         *
                         * I have twice asserted "37,000 Mach round trips/sec at
                         * ~20us each = most of a core" without ever measuring
                         * the round trip. If it is really 20us the storm is the
                         * frame rate; if it is 2us it costs ~7% of one core and
                         * the W^X rebuild would be aimed at the wrong target.
                         *
                         * ios_store_fault_t0 is stamped at handler ENTRY (see
                         * the exception entry point), so this covers the whole
                         * kernel->handler->emulate path, not just the store. */
                        {
                            extern volatile unsigned long long ios_store_fault_t0;
                            extern volatile unsigned long long ios_store_fault_ticks;
                            extern volatile unsigned long long ios_store_fault_n;
                            extern volatile unsigned long long ios_store_fault_dropped;
                            /* ml685: the ml680 version was WRONG and its late totals
                             * (6.1e12 ms) must not be used. t0 is a single plain
                             * global; when the store is emulated on a different
                             * thread than the one that stamped it, `now - t0` can
                             * UNDERFLOW an unsigned 64-bit and add ~2^64 ticks. One
                             * race poisons the accumulator permanently, which is why
                             * the early samples (~3.3us) were sane and everything
                             * after was garbage.
                             *
                             * Take the sample only when it is self-evidently valid,
                             * and drop implausible ones into a separate counter so a
                             * discarded sample is visible rather than silent. */
                            {
                                unsigned long long t0 = ios_store_fault_t0;
                                unsigned long long now = mach_absolute_time();
                                ios_store_fault_t0 = 0;
                                if (t0 && now > t0)
                                {
                                    unsigned long long dt = now - t0;
                                    /* 24M ticks ~= 1s at the 24MHz timebase: any
                                     * store taking longer than that is a stale
                                     * pairing, not a measurement. */
                                    if (dt < 24000000ull)
                                    {
                                        __sync_add_and_fetch(&ios_store_fault_ticks, dt);
                                        __sync_add_and_fetch(&ios_store_fault_n, 1);
                                    }
                                    else
                                        __sync_add_and_fetch(&ios_store_fault_dropped, 1);
                                }
                                else if (t0)
                                    __sync_add_and_fetch(&ios_store_fault_dropped, 1);
                            }
                        }

                        /* ============ ml678 FAULT CLASSIFIER ==================
                         *
                         * ml677 sampled 13,299 of 13.3M faults as LOG LINES and
                         * I then matched their instruction ENCODING against the
                         * spinning worker's block and declared them the same
                         * code. They are not: 0 of 13,299 fault pcs and 0 of
                         * 3,248 EXC_SAMPLE pcs fall inside that block. c89ffcc1
                         * is FEX's TSO lowering of an ordinary store and occurs
                         * all over translated code, so encoding proves nothing.
                         *
                         * Aggregate IN-PROBE by host pc instead -- real event
                         * counts, not sampled lines -- and carry the facts that
                         * identify the emitter: the block-granular guest RIP
                         * from FEX's ThreadState (x28+0x18, a plain load: NEVER
                         * call an EC export from a fault path, ml613), the
                         * target page, and how many distinct pages that pc hits
                         * (one page = a hot data structure, many = a memcpy-like
                         * sweep). */
                        {
                            enum { FC_SLOTS = 24 };
                            enum { FC_PAGESET = 64, FC_SAMPLES = 12 };
                            static struct {
                                unsigned long long pc, rip, page, page2;
                                unsigned long long hits; unsigned pages_seen;
                                unsigned long long lo, hi, prev, stride;
                                unsigned restarts, nset;
                                unsigned long long pset[FC_PAGESET];
                                unsigned nsmp;
                                struct { unsigned long long hits, rsp, rcx, rdx, r8, addr; } smp[FC_SAMPLES];
                            } fc[FC_SLOTS];
                            static volatile int fc_lock;
                            unsigned long long fpage = (unsigned long long)fault_addr & ~0x3fffull;
                            unsigned long long grip = 0;
                            /* x28 = FEX ThreadState; +0x18 = State.rip for this block */
                            if (state.__x[28] > 0x10000)
                            {
                                mach_vm_size_t g = 0;
                                if (mach_vm_read_overwrite(mach_task_self(),
                                        (mach_vm_address_t)(state.__x[28] + 0x18), 8,
                                        (mach_vm_address_t)&grip, &g) != KERN_SUCCESS || g != 8)
                                    grip = 0;
                            }
                            if (!__sync_lock_test_and_set(&fc_lock, 1))
                            {
                                int fi, victim = 0;
                                for (fi = 0; fi < FC_SLOTS; fi++)
                                {
                                    if (fc[fi].pc == (unsigned long long)fault_pc) break;
                                    if (!fc[fi].pc) { victim = fi; break; }
                                    if (fc[fi].hits < fc[victim].hits) victim = fi;
                                }
                                if (fi == FC_SLOTS) fi = victim;
                                if (fc[fi].pc != (unsigned long long)fault_pc)
                                {
                                    fc[fi].pc = (unsigned long long)fault_pc;
                                    fc[fi].rip = grip; fc[fi].page = fpage;
                                    fc[fi].page2 = 0; fc[fi].hits = 0; fc[fi].pages_seen = 1;
                                }
                                fc[fi].hits++;
                                if (fpage != fc[fi].page && fpage != fc[fi].page2)
                                { fc[fi].page2 = fpage; fc[fi].pages_seen++; }

                                /* ml725: IS THE DOMINANT SITE ONE BULK COPY, OR THE SAME
                                 * COPY RESTARTING FOREVER?
                                 *
                                 * One site produced ~43M of ~44M emulated stores. Whether
                                 * removing the per-store Mach fault is worth anything
                                 * depends entirely on which of those it is: a genuine
                                 * copy gets ~1000x faster, a retry livelock just spins
                                 * faster and the game still never renders.
                                 *
                                 * Two prior readings from this very probe were wrong and
                                 * must not be repeated. `rip` here is FEX's block-level
                                 * State.rip, NOT the faulting instruction -- it names the
                                 * surrounding block/call site only. And `pages_seen`
                                 * remembers just TWO pages, so alternating over three or
                                 * more inflates it without bound; the 7.6M it reported is
                                 * not a cardinality. The exact guest RIP is NOT
                                 * obtainable here: BTCpu64IosRipFromHostPC is an ARM64EC
                                 * PE export and calling it from this native handler is
                                 * what crashed every launch in ml613.
                                 *
                                 * So measure what IS available natively: the fault-address
                                 * sequence. Ascending with a fixed stride and a
                                 * monotonically rising span = a bulk copy. Addresses that
                                 * jump backwards to a previous low-water mark = restarts,
                                 * and the count says how many. A small saturating page set
                                 * gives a cardinality that is honest about its own limit.
                                 */
                                if (fc[fi].hits == 1) {
                                    fc[fi].lo = fc[fi].hi = (unsigned long long)fault_addr;
                                    fc[fi].prev = (unsigned long long)fault_addr;
                                    fc[fi].restarts = 0; fc[fi].stride = 0; fc[fi].nset = 0;
                                } else {
                                    unsigned long long a = (unsigned long long)fault_addr;
                                    if (a < fc[fi].lo) fc[fi].lo = a;
                                    if (a > fc[fi].hi) fc[fi].hi = a;
                                    if (a > fc[fi].prev) {
                                        unsigned long long d = a - fc[fi].prev;
                                        if (d <= 64 && (!fc[fi].stride || d == fc[fi].stride))
                                            fc[fi].stride = d;
                                    } else if (a + 0x10000 < fc[fi].prev) {
                                        fc[fi].restarts++;   /* big backward jump */
                                    }
                                    fc[fi].prev = a;
                                }
                                /* ml726: SAMPLE THE CALL FRAME AND ARGUMENTS.
                                 *
                                 * ml725's `restarts` counter cannot answer the question it
                                 * was built for: it increments on ANY backward destination
                                 * jump over 64KiB, so sequential memcpys to unrelated
                                 * destinations inflate it exactly like a retry would. Its
                                 * value must NOT be divided by hits to infer a copy length
                                 * -- that denominator is backward jumps, not invocations.
                                 *
                                 * What separates "one slow copy", "the same copy retried"
                                 * and "many legitimate copies" is the call frame and the
                                 * arguments over time. Windows x64 puts memcpy's dst/src/len
                                 * in RCX/RDX/R8, and FEX's SRA keeps those in x0/x1/x2 with
                                 * RSP in x23 -- all readable here without touching FEX.
                                 *
                                 * A constant RSP with dst/len resetting to the same values
                                 * is a retry. A marching dst with RSP constant is one long
                                 * copy. Changing RSP with changing args is ordinary work
                                 * made slow by the fault cost -- and only in that last case
                                 * is optimising the store path the thing that reaches a
                                 * frame. Sampled sparsely so the fault path stays cheap. */
                                if ((fc[fi].hits % 250000ull) == 1 && fc[fi].nsmp < FC_SAMPLES) {
                                    unsigned si2 = fc[fi].nsmp++;
                                    fc[fi].smp[si2].hits = fc[fi].hits;
                                    fc[fi].smp[si2].rsp  = (unsigned long long)state.__x[23];
                                    fc[fi].smp[si2].rcx  = (unsigned long long)state.__x[0];
                                    fc[fi].smp[si2].rdx  = (unsigned long long)state.__x[1];
                                    fc[fi].smp[si2].r8   = (unsigned long long)state.__x[2];
                                    fc[fi].smp[si2].addr = (unsigned long long)fault_addr;
                                }

                                {   /* saturating distinct-page set, honest about its cap */
                                    unsigned pi; int seen = 0;
                                    for (pi = 0; pi < fc[fi].nset; pi++)
                                        if (fc[fi].pset[pi] == fpage) { seen = 1; break; }
                                    if (!seen && fc[fi].nset < FC_PAGESET) fc[fi].pset[fc[fi].nset++] = fpage;
                                }

                                /* ml690: attribute faults to the ORIGINATING thread.
                                 * The aggregate rate cannot say whether the main
                                 * thread is the one being stalled -- and that is
                                 * exactly what decides whether W^X moves the frame
                                 * rate or merely frees a core. */
                                {
                                    enum { FP_SLOTS = 24 };
                                    static struct { unsigned port; unsigned long long n; } fp[FP_SLOTS];
                                    unsigned pi;
                                    extern volatile unsigned int ios_cur_fault_port;
                                    for (pi = 0; pi < FP_SLOTS; pi++)
                                    {
                                        if (fp[pi].port == ios_cur_fault_port) { fp[pi].n++; break; }
                                        if (!fp[pi].port) { fp[pi].port = ios_cur_fault_port; fp[pi].n = 1; break; }
                                    }
                                    if ((ec % 400000) == 0)
                                    {
                                        unsigned q;
                                        dprintf(STDERR_FILENO, "[fault-by-thread] ml690 after %d stores:\n", ec);
                                        for (q = 0; q < FP_SLOTS; q++)
                                            if (fp[q].port)
                                                dprintf(STDERR_FILENO,
                                                    "[fault-by-thread]   port=0x%x faults=%llu (%llu%%)\n",
                                                    fp[q].port, fp[q].n,
                                                    (fp[q].n * 100ull) / (unsigned long long)ec);
                                    }
                                }
                                if ((ec % 200000) == 0)
                                {
                                    int k;
                                    dprintf(STDERR_FILENO,
                                        "[fault-class] ml678 ==== %d emulated stores so far ====\n", ec);
                                    for (k = 0; k < FC_SLOTS; k++)
                                    {
                                        if (!fc[k].hits) continue;
                                        dprintf(STDERR_FILENO,
                                                "[fault-class]   pc=0x%llx blockRIP=0x%llx hits=%llu "
                                                "page=0x%llx pages2slot=%u | ml725 span=[0x%llx..0x%llx] "
                                                "=%lluKB stride=%llu restarts=%u pages%s%u\n",
                                                fc[k].pc, fc[k].rip, fc[k].hits,
                                                fc[k].page, fc[k].pages_seen,
                                                fc[k].lo, fc[k].hi,
                                                (fc[k].hi >= fc[k].lo) ? (fc[k].hi - fc[k].lo) / 1024 : 0,
                                                fc[k].stride, fc[k].restarts,
                                                (fc[k].nset >= FC_PAGESET) ? ">=" : "=", fc[k].nset);
                                        if (fc[k].hits > 1000000ull) {
                                            unsigned sj;
                                            for (sj = 0; sj < fc[k].nsmp; sj++)
                                                dprintf(STDERR_FILENO,
                                                    "[fault-args] ml726 pc=0x%llx @%lluk rsp=0x%llx "
                                                    "rcx/dst=0x%llx rdx/src=0x%llx r8/len=0x%llx addr=0x%llx\n",
                                                    fc[k].pc, fc[k].smp[sj].hits / 1000ull,
                                                    fc[k].smp[sj].rsp, fc[k].smp[sj].rcx,
                                                    fc[k].smp[sj].rdx, fc[k].smp[sj].r8,
                                                    fc[k].smp[sj].addr);
                                        }
                                    }
                                }
                                __sync_lock_release(&fc_lock);
                            }
                        }
                        if (madeira_diag_enabled && (ec <= 5 || (ec % 1000) == 0))
                        {   /* ml649: the readback below touches both aliases */
                            /* Verify dual-map sharing: read back via the RX
                             * (original) address and compare to what we wrote
                             * via RW. If they match, the dual-map is working
                             * end-to-end. */
                            uint64_t rw_val = *(uint64_t *)rw_addr;
                            uint64_t rx_val = *(uint64_t *)fault_addr;
                            dprintf(STDERR_FILENO,
                                "[mach_exc] EMULATED STR #%d pc=%p insn=%08x rx=%p→rw=%p"
                                " | dual-map readback rx=%llx rw=%llx %s\n",
                                ec, (void*)(uintptr_t)fault_pc, insn,
                                (void*)fault_addr, (void*)rw_addr,
                                (unsigned long long)rx_val,
                                (unsigned long long)rw_val,
                                (rx_val == rw_val) ? "OK" : "MISMATCH");
                        }
                    }
                }
            }

            /* iOS-Madeira RECLAIM RECOVERY (FEX-2607 Thumper): a page that Wine/FEX
             * consider committed can be reclaimed by iOS under memory pressure —
             * 2607's per-thread 96MB LookupCaches push the app over the jetsam
             * limit, so committed L1/L2/code pages get dropped and the re-access
             * faults with no other handler -> terminate. Force the page back with
             * mprotect(RW); it returns zero-filled, which is functionally correct
             * for FEX's caches (a zero L1/L2 slot reads as "empty" -> FEX
             * recompiles). Gated to the FEX host-arena band (~0x7Cxx..0x80xx) so
             * it can't mask guest/dyld/null-deref faults, with a 16-slot per-page
             * repeat guard so an ineffective mprotect can't spin forever. */
            {
                uint64_t fa = (uint64_t)fault_addr;
                uint64_t fault_pc = (uint64_t)__darwin_arm_thread_state64_get_pc(state);

                /* task #34 (ml74): EXECUTE fault on a code page — the RW grant
                 * below can never fix it (observed: retry#1..51 on
                 * 0x7ecaf00000, RW mprotect "succeeds", same fault forever;
                 * and the fatal walk in the pool RX view at 0x125115ce0 whose
                 * page had become prot=RW max_prot=RW). Handle code ranges
                 * FIRST: try to restore R|X — works when the pool/copy
                 * mapping is intact and only lost its protection. If mprotect
                 * RX fails, max_prot lost X = the mapping was REPLACED (see
                 * [jit-tripwire] in virtual_ios.c) — nothing in-handler can
                 * fix that; log the vm_region ground truth and fall through
                 * so the fault surfaces instead of spinning. */
                /* ml578: an EXC_BREAKPOINT must NEVER enter execute-recovery.
                 * The EXC_BREAKPOINT branch far above has no `continue`, so a
                 * guest int3 falls through to here — and a breakpoint's fault
                 * address EQUALS its pc, making `fa == fault_pc` trivially true.
                 * We then "recover" a page that was never faulting, resume, hit
                 * the same int3 and repeat: ONE deliberate Chromium abort
                 * (chrome_elf+0xD7D30, the BackupRefPtr refcount CHECK) became
                 * NINE identical breakpoints in ml577. The store-emulation path
                 * above is harmless only by luck — BRK (0xd4200020) matches no
                 * store pattern so it merely logs — but this one acts.
                 * Diagnosis by Sol. */
                if (!handled && fa == (uint64_t)fault_pc && req->exception != EXC_BREAKPOINT)
                {
                    extern void *ios_jit_rx_base_global;
                    extern size_t ios_jit_pool_size_global;
                    uint64_t rx = (uint64_t)(uintptr_t)ios_jit_rx_base_global;
                    int in_pool_rx = rx && fa >= rx && fa < rx + ios_jit_pool_size_global;
                    int in_band    = (fa >= 0x7C00000000ULL && fa < 0x8000000000ULL);

                    if (in_pool_rx || in_band)
                    {
                        enum { XR_PAGE = 0x4000 };
                        uint64_t pg = fa & ~(uint64_t)(XR_PAGE - 1);
                        static volatile uint64_t xr_pg[16] = {0};
                        static volatile uint32_t xr_n[16]  = {0};
                        int s = (int)((pg >> 14) & 15);
                        int giveup = 0;
                        if (xr_pg[s] == pg) { if (++xr_n[s] > 8) giveup = 1; }
                        else { xr_pg[s] = pg; xr_n[s] = 1; }
#ifndef MADV_FREE_REUSE
#define MADV_FREE_REUSE 8
#endif
                        if (!giveup)
                        {
                            /* Restore R|X. Works when the pool RX view / arm64ec
                             * pool-copy mapping is intact and only lost protection
                             * under reclaim. MADV_FREE_REUSE cancels any residual
                             * volatility so the page isn't immediately re-harvested. */
                            int mpr = mprotect( (void *)(uintptr_t)pg, XR_PAGE, PROT_READ | PROT_EXEC );
                            int errno_save = errno;
                            int reuse = madvise( (void *)(uintptr_t)pg, XR_PAGE, MADV_FREE_REUSE );
                            static volatile int xrc = 0;
                            int xrcn = __sync_fetch_and_add(&xrc, 1);
                            if (xrcn < 40 || (xrcn % 50) == 0)
                                dprintf(STDERR_FILENO,
                                    "[exec-recover] pg=0x%llx fault=0x%llx mprotect_rx=%d(errno=%d) reuse-cancel=%d retry#%u %s\n",
                                    (unsigned long long)pg, (unsigned long long)fa, mpr, errno_save,
                                    reuse, xr_n[s], in_pool_rx ? "pool-rx" : "band");
                            if (mpr == 0) handled = 1;
                            /* ml133: mprotect(RX) on debugger-blessed pool memory
                             * returns EACCES *unconditionally* — it is a platform
                             * rule (only StikDebug's original blessed mapping may
                             * be executable), NOT evidence that the mapping was
                             * replaced, and the comment below has been reading it
                             * that way for months. So recovery has never actually
                             * been attempted here.
                             *
                             * What we DO know (ml104 byte-compare): the faulting
                             * page is READABLE and its content is byte-identical
                             * to the on-disk DLL. So the mapping is intact and the
                             * page merely needs faulting back in. Force that from
                             * the kernel side with mach_vm_read_overwrite — a
                             * syscall, so it cannot itself fault this handler
                             * thread the way a user-space load could — then retry
                             * the instruction. If exec really is gone the retry
                             * re-faults and the giveup counter above (8 tries per
                             * page slot) surfaces it instead of spinning. */
                            else if (in_pool_rx)
                            {
                                uint64_t probe[2] = { 0, 0 };
                                mach_vm_size_t got = 0;
                                kern_return_t kr = mach_vm_read_overwrite(
                                        mach_task_self(), (mach_vm_address_t)pg, sizeof(probe),
                                        (mach_vm_address_t)&probe, &got );
                                if (kr == KERN_SUCCESS && got == sizeof(probe))
                                {
                                    sys_icache_invalidate( (void *)(uintptr_t)pg, XR_PAGE );
                                    handled = 1;
                                }
                                if (xrcn < 40 || (xrcn % 50) == 0)
                                    dprintf(STDERR_FILENO,
                                        "[exec-recover] pg=0x%llx read-touch kr=%d got=%llu word0=0x%llx -> %s\n",
                                        (unsigned long long)pg, (int)kr,
                                        (unsigned long long)got, (unsigned long long)probe[0],
                                        handled ? "RETRY" : "surface");
                            }
                            /* else: mprotect RX failed => max_prot lost EXECUTE =>
                             * the code page was REPLACED by a plain RW mapping
                             * ([jit-tripwire] names the culprit). Nothing here can
                             * re-add X; leave handled=0 and fall through to the
                             * unhandled path, which dumps vm_region ground truth
                             * and surfaces the fault instead of spinning forever. */
                        }
                    }
                }

                /* DATA fault reclaim recovery in the FEX host-arena band
                 * (FEX-2607 Thumper path): a page Wine/FEX consider committed
                 * gets reclaimed under memory pressure — 2607's per-thread 96MB
                 * LookupCaches push over the jetsam limit, so L1/L2/cache pages
                 * are dropped and the re-access faults with no other handler.
                 * Force the page back with mprotect(RW); zero-filled is correct
                 * for FEX's caches (a zero L1/L2 slot reads "empty" -> recompile).
                 * Gated to the host-arena band AND to non-execute faults so it
                 * can't shadow the R|X path above or mask guest/null-deref faults.
                 * Task #22: cap was >4 — Steam's download pressure re-harvested
                 * the same still-volatile page 5+ times; MADV_FREE_REUSE makes
                 * recovery permanent, the higher cap is a belt for residual
                 * volatility. */
                /* Correctness guard, NOT a fix for anything observed: this band
                 * ([496G,512G)) must never claim the JIT pool's own RW alias,
                 * because pool writes have their own STR-emulation path and this
                 * one "recovers" by mapping fresh ZERO pages. It is a no-op at
                 * the default alias placement (0x7000000000 is outside the
                 * band) and exists so a future relocation can't silently couple
                 * to this handler.
                 * HONEST NOTE: this was added on the theory that the band was
                 * why relocating the alias into it caused exec faults. It was
                 * NOT — ml98 kept the exclusion, kept the alias at
                 * 0x7c00000000, and still took 16 faults (ml97 also 16). The
                 * real coupling is still unidentified; do not cite this as the
                 * explanation. */
                {
                    extern void *ios_jit_rw_base_global;
                    extern size_t ios_jit_pool_size_global;
                    uintptr_t rwb = (uintptr_t)ios_jit_rw_base_global;
                    if (rwb && ios_jit_pool_size_global &&
                        fa >= rwb && fa < rwb + ios_jit_pool_size_global)
                        goto skip_reclaim_band;
                }
                if (!handled && fa != (uint64_t)fault_pc &&
                    fa >= 0x7C00000000ULL && fa < 0x8000000000ULL)
                {
                    static volatile uint64_t rr_pg[16] = {0};
                    static volatile uint32_t rr_n[16]  = {0};
                    /* iOS uses 16KB host pages. NOTE: `host_page_size` in this
                     * file resolves to the Mach *function*, not a size — using
                     * it as a value gave a garbage mask (mprotect EINVAL). */
                    enum { RR_PAGE = 0x4000 };
                    uint64_t pg = fa & ~(uint64_t)(RR_PAGE - 1);
                    int s = (int)((pg >> 14) & 15);
                    int giveup = 0;
                    if (rr_pg[s] == pg) { if (++rr_n[s] > 64) giveup = 1; }
                    else { rr_pg[s] = pg; rr_n[s] = 1; }
                    if (!giveup)
                    {
                        /* ml95 (task #34): the "FEX host-arena band" assumption
                         * behind the zero-fill below is STALE. Wine's PE images
                         * now cluster in this same [496G,512G) band — ml95 took
                         * a fault on pg=0x7ed1be0000 (507.1G) which is a loaded
                         * MODULE BASE, and images were measured at 505.8G. For a
                         * FEX cache page a fresh zero page is correct (reads
                         * "empty" -> recompile); for a module it silently
                         * DESTROYS the code, and the thread then executes zeros
                         * or leaks a pool address into the guest RIP
                         * ([rip-leak] named exactly that module, rva 0x109835).
                         * Never zero-fill a page that belongs to a loaded image:
                         * restore protection if the mapping survives, otherwise
                         * surface the fault instead of corrupting it away. */
                        extern unsigned long long ios_jit_module_base_for_va( unsigned long long va,
                                                                              unsigned long long *size_out );
                        /* ml306 (task #53): capture Wine's committed-state BEFORE recovery mutates
                         * anything. This is THE discriminator for whether zero-fill is safe here:
                         *   VPROT_COMMITTED (0x20) set  -> page held live data; zeros = DATA LOSS or
                         *                                  a masked use-after-free. ml305's fatal
                         *                                  (null+0x90 through a pointer read from
                         *                                  this band, [reclaim-recover] firing
                         *                                  mid-exception) is the suspected result.
                         *   clear                       -> lazy-reservation first touch; zeros are
                         *                                  the contract and recovery is benign.
                         * Measurement only for now -- behaviour unchanged until at least one run
                         * says how the 2-4 events per run split. */
                        extern unsigned char ios_reclaim_page_vprot( unsigned long long va );
                        unsigned char pg_vprot = ios_reclaim_page_vprot( pg );
                        unsigned long long mod_size = 0;
                        unsigned long long mod_base = ios_jit_module_base_for_va( pg, &mod_size );
                        int mpr = mprotect( (void *)(uintptr_t)pg, RR_PAGE, PROT_READ | PROT_WRITE );
                        int errno_save = errno;
                        int used_mmap = 0;
                        if (mpr != 0 && !mod_base)  /* scratch page: fresh zeros ARE the contract */
                        {
                            void *r = mmap( (void *)(uintptr_t)pg, RR_PAGE, PROT_READ | PROT_WRITE,
                                            MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0 );
                            used_mmap = (r == (void *)(uintptr_t)pg);
                        }
                        else if (mpr != 0)
                        {
                            static volatile int mrc = 0;
                            if (__sync_fetch_and_add(&mrc, 1) < 24)
                                dprintf(STDERR_FILENO,
                                    "[reclaim-recover] REFUSED zero-fill of LOADED MODULE page pg=0x%llx module=0x%llx+0x%llx rva=0x%llx errno=%d — zeros would destroy code, surfacing fault\n",
                                    (unsigned long long)pg, mod_base, mod_size,
                                    (unsigned long long)(pg - mod_base), errno_save);
                        }
                        int reuse = madvise( (void *)(uintptr_t)pg, RR_PAGE, MADV_FREE_REUSE );
                        /* iOS-Madeira ml329 (#53 DISCRIMINATOR): remember every page we
                         * zero-fill, so a later crash can be tested against them instead
                         * of inferred.
                         *
                         * ml326+ml328 both died in FEXCore's IntrusivePooledAllocator
                         * (ClaimBufferImpl) reading a NULL `next` at offset 8 of a
                         * fextl::list node -- i.e. a list node full of zeros. Those nodes
                         * are aligned_alloc'd into FEX's jemalloc heap, which lives in the
                         * same [0x7c,0x80) band this recovery path re-mmaps. That makes
                         * "iOS reclaimed the page and we handed the allocator zeros" the
                         * leading hypothesis -- but the existing verdict string reads
                         * WINE's vprot, which is 0 for memory FEX allocated through its own
                         * VirtualAlloc2 path, so it prints "zeros OK" either way and cannot
                         * settle it. Record the pages; ios_reclaim_pages_report() prints
                         * them at the fatal SEGV so the two can be correlated directly. */
                        ios_reclaim_note_page( pg );
                        static volatile int rc = 0;
                        int rcn = __sync_fetch_and_add(&rc, 1);
                        if (rcn < 40 || (rcn % 50) == 0)
                            dprintf(STDERR_FILENO,
                                "[reclaim-recover] pg=0x%llx fault=0x%llx mprotect=%d(errno=%d) mmap=%d reuse-cancel=%d retry#%u vprot=0x%02x %s\n",
                                (unsigned long long)pg, (unsigned long long)fa, mpr, errno_save,
                                used_mmap, reuse, rr_n[s], pg_vprot,
                                (pg_vprot & 0x20) ? "WAS-COMMITTED(zeros=DATA-LOSS/UAF!)"
                                                  : "not-committed(lazy first touch, zeros OK)");
                        if (mpr == 0 || used_mmap) handled = 1;
                    }
                }
skip_reclaim_band: ;
            }

            /* ml369 (#63): last-resort in-process guest exception delivery.
             * Nothing above claimed the fault; declining it is a death
             * sentence under StikDebug (the stub cannot inject signals, so
             * wine's segv/bus/ill handlers are unreachable and the fault
             * spins at one pc until the script kills the app at 8 stops).
             * Deliver to the guest from here instead. d==2 means the page
             * machinery fixed it (guard/watch): resume with state as-is. */
            if (!handled && (req->exception == EXC_BAD_ACCESS ||
                             req->exception == EXC_BAD_INSTRUCTION))
            {
                if (ios_mach_deliver_guest_exception( thread, &state,
                        &neon_state, have_neon, req->exception,
                        fault_addr, thread_teb ))
                    handled = 1;
            }

            if (handled)
                thread_set_state( thread, ARM_THREAD_STATE64,
                                  (thread_state_t)&state, count );
            else
            {
                /* Rate-limit: log first 5 unhandled faults then every 100th */
                static volatile int unhandled_count = 0;
                int cnt = __sync_add_and_fetch(&unhandled_count, 1);
                /* iOS-Madeira: ALWAYS dump for "terminal-looking" faults
                 * — fault PC outside any plausible mapped region (low addr
                 * < 0x100000000 OR in dyld_shared_cache range 0x3xxxx00000+).
                 * Path-init memcpy faults happen at JIT-pool PCs and burn
                 * the cnt<=5 budget; without this terminal crashes were
                 * never dumped. */
                uint64_t fault_pc_check = (uint64_t)__darwin_arm_thread_state64_get_pc(state);
                int terminal_pc = (fault_pc_check < 0x100000000ULL ||
                                   (fault_pc_check >> 32) >= 0x300);
                /* iOS-Madeira 2026-05-15: compact per-fault line + first-seen
                 * guest RIP tracker. The Thumper fault loop has 13K+ UNHANDLED
                 * exceptions at JIT-pool PCs; the current cnt<=5 gate hides
                 * which guest function(s) the loop runs over. Capture State.RIP
                 * for every fault (cheap, ~80 bytes/line) so we can correlate
                 * fault PC ranges with guest RIPs offline. */
                {
                    uintptr_t teb_q = 0; void *tramp_q = NULL;
                    ios_lookup_thread(thread, &teb_q, &tramp_q);
                    void *fex_state_q = NULL;
                    if (teb_q)
                    {
                        void *cpuarea = *(void**)(teb_q + 0x1788);
                        if (cpuarea) fex_state_q = *(void**)((char*)cpuarea + 0x30);
                    }
                    uint64_t state_rip_q = fex_state_q ?
                        ((uint64_t*)fex_state_q)[0x18 / 8] : 0;
                    /* First-seen tracker: 32-slot hash by RIP. */
                    static volatile uint64_t seen_rip[32] = {0};
                    static volatile uint32_t seen_count[32] = {0};
                    int slot = (int)((state_rip_q >> 4) & 31);
                    int first_seen = 0;
                    if (seen_rip[slot] != state_rip_q)
                    {
                        /* Linear probe to find empty / matching slot */
                        int s;
                        for (s = 0; s < 32; s++)
                        {
                            int k = (slot + s) & 31;
                            if (seen_rip[k] == state_rip_q) { slot = k; break; }
                            if (seen_rip[k] == 0 &&
                                __sync_bool_compare_and_swap(&seen_rip[k], 0, state_rip_q))
                            { slot = k; first_seen = 1; break; }
                        }
                    }
                    __sync_add_and_fetch(&seen_count[slot], 1);

                    /* ml261 LIVELOCK BREAKER, keyed on the faulting PAGE.
                     *
                     * ml261 burned its whole run on 49,500+ faults at ONE address --
                     * previous runs peaked near 4,000. Signature:
                     *   insn f81f0ff3 = str x19,[sp,#-16]!   (a prologue push)
                     *   sp=0x73d16aff40, fault addr=0x73d16aff30  (16 bytes below sp)
                     *   [fault-rgn] page=0x73d16ac000 vprot prev/this/next=00/00/23
                     *   [fault-rgn] NO wine view -- Wine doesn't own this addr
                     * i.e. a stack growing into an UNCOMMITTED page (the page above IS
                     * committed) on a stack Wine does not own, so virtual_handle_fault
                     * declines, nothing commits it, and the access retries forever.
                     *
                     * The existing SEGV LOOP FATAL guard cannot catch this: it keys on
                     * the PC, and here two PCs alternate (0x13b5f2004 prologue and
                     * 0x1026b3188 memcpy) over the SAME page. Key on the page instead.
                     *
                     * This does NOT fix the missing commit -- it stops one page from
                     * eating an entire run, and dumps the region layout around it so the
                     * owner can be identified and the real fix aimed correctly. */
                    {
                        static struct { uint64_t thread, page, pc, addr; uint32_t n, page_n; unsigned seq; } stk[16];
                        const int ss = ios_fault_slot( (uint64_t)thread );
                        const unsigned dseq = __atomic_load_n( &ios_guest_deliv_seq[ss], __ATOMIC_ACQUIRE );
                        /* ml876: exact faulting ADDRESS, and a page-level storm
                         * counter. ml871-875 killed a UE 5.4 game thread here on
                         * every run: an SDK dll walked its import table with the
                         * classic VirtualProtect(entry,RW) / write / VirtualProtect
                         * (page,RO) pattern; on 16 KB host pages the RO of one 4 KB
                         * guest page strips W from the neighbour the guest had just
                         * made RW, [wr-strip] heals it and the thread advances to
                         * the NEXT entry -- a different address every time. Same
                         * (page,pc) 50x is therefore NOT "zero progress". Livelock
                         * = the SAME address re-faulting (ml261 sp-16 push, ml385
                         * NULL write, ml557 un-stuck heal); key on it. Keep a much
                         * larger page-level ceiling as the storm safety net. */
                        uint64_t fpage = (uint64_t)fault_addr & ~0x3fffull;
                        /* ml385: NULL-page faults keyed as 1, not 0 — `if (fpage &&`
                         * excluded them entirely and a NULL-write loop in
                         * server_ioctl_file ran 3.3M times with no breaker
                         * (StikDebug's 8-stop kill was the only breaker, and it
                         * had detached). */
                        if (!fpage) fpage = 1;

                        /* Another thread in this slot, or an exception delivered to this
                         * one since its last fault, starts a new run (page 0 never
                         * matches, so the run is keyed again below). */
                        if (stk[ss].thread != (uint64_t)thread || stk[ss].seq != dseq)
                        {
                            stk[ss].thread = (uint64_t)thread;
                            stk[ss].seq = dseq;
                            stk[ss].page = 0;
                        }

                        if (fpage == stk[ss].page && fault_pc_check == stk[ss].pc &&
                            (uint64_t)fault_addr != stk[ss].addr)
                        {
                            /* ml876: same page+pc but a NEW address = progress.
                             * Restart the exact-address count; keep the page
                             * storm count (ceiling 20000, logged every 1000). */
                            uint32_t pn = __sync_add_and_fetch(&stk[ss].page_n, 1);
                            stk[ss].addr = (uint64_t)fault_addr;
                            stk[ss].n = 0;
                            if ((pn % 1000) == 0)
                                dprintf(STDERR_FILENO,
                                    "[fault-stuck] ml876 page 0x%llx pc 0x%llx: %u faults, addresses advancing (last 0x%llx)\n",
                                    (unsigned long long)fpage, (unsigned long long)fault_pc_check, pn,
                                    (unsigned long long)fault_addr);
                            if (pn >= 20000) stk[ss].n = 49;   /* storm ceiling: next fault breaks */
                        }
                        if (fpage == stk[ss].page && fault_pc_check == stk[ss].pc)
                        {
                            uint32_t n = __sync_add_and_fetch(&stk[ss].n, 1);
                            /* ml385 LOOP BREAKER: same page AND same pc 50 times
                             * with zero progress is a livelock, not a recoverable
                             * fault (guard/watch pages resolve in 1-3). Divert the
                             * thread to wine's abort_thread so the pseudo-process
                             * dies cleanly instead of eating the whole run. Native
                             * unix-code faults (dylib pc) can never be delivered
                             * to guest SEH anyway. */
                            if (n >= 50)
                            {
                                extern void abort_thread( int status );
                                uint64_t cur_sp = __darwin_arm_thread_state64_get_sp(state);
                                dprintf(STDERR_FILENO,
                                    "[fault-stuck] BREAKING LOOP: page 0x%llx pc 0x%llx repeated %u times "
                                    "-> diverting thread to abort_thread\n",
                                    (unsigned long long)fpage, (unsigned long long)fault_pc_check, n);
                                state.__x[0] = 1;
                                __darwin_arm_thread_state64_set_sp(state, cur_sp & ~0xfull);
                                __darwin_arm_thread_state64_set_pc_fptr(state, (void *)abort_thread);
                                thread_set_state( thread, ARM_THREAD_STATE64,
                                                  (thread_state_t)&state, count );
                                handled = 1;
                                stk[ss].n = 0;
                            }
                            /* ml369: was 2048, which NEVER fired — the
                             * debugger script kills the app after 8
                             * identical stops, so the region map has to
                             * print by the 6th fault to exist at all. */
                            /* ml1090: this map printed 426,000 times in one run (a
                             * thread re-faulting on a page the breaker below kept
                             * diverting), 3 million lines that were most of the
                             * run's memory growth. The first few say everything. */
                            static volatile uint32_t stuck_dumps;
                            if (n == 5 && __sync_add_and_fetch(&stuck_dumps, 1) <= 6)
                            {
                                mach_vm_address_t ra = (mach_vm_address_t)(fpage - 0x8000);
                                int i;
                                dprintf(STDERR_FILENO,
                                    "[fault-stuck] page 0x%llx faulted %u times with NO progress "
                                    "(pc=0x%llx sp=0x%llx) -- region map around it:\n",
                                    (unsigned long long)fpage, n,
                                    (unsigned long long)fault_pc_check,
                                    (unsigned long long)__darwin_arm_thread_state64_get_sp(state));
                                for (i = 0; i < 6; i++)
                                {
                                    mach_vm_size_t rs = 0;
                                    vm_region_basic_info_data_64_t rbi;
                                    mach_msg_type_number_t rc = VM_REGION_BASIC_INFO_COUNT_64;
                                    mach_port_t ro = MACH_PORT_NULL;
                                    mach_vm_address_t q = ra;
                                    if (mach_vm_region( mach_task_self(), &q, &rs,
                                                        VM_REGION_BASIC_INFO_64,
                                                        (vm_region_info_t)&rbi, &rc, &ro ) != KERN_SUCCESS)
                                    {
                                        dprintf(STDERR_FILENO,
                                            "[fault-stuck]   probe 0x%llx -> no region above\n",
                                            (unsigned long long)ra);
                                        break;
                                    }
                                    dprintf(STDERR_FILENO,
                                        "[fault-stuck]   region 0x%llx +0x%llx prot=%d/%d %s\n",
                                        (unsigned long long)q, (unsigned long long)rs,
                                        rbi.protection, rbi.max_protection,
                                        (q <= fpage && fpage < q + rs) ? "  <== FAULTING PAGE" : "");
                                    ra = q + rs;
                                }
                            }
                        }
                        else
                        {
                            stk[ss].page = fpage;
                            stk[ss].pc = fault_pc_check;
                            stk[ss].addr = (uint64_t)fault_addr;
                            stk[ss].n = 0;
                            stk[ss].page_n = 0;
                        }
                    }

                    if (cnt <= 50 || first_seen || (cnt % 500) == 0)
                    {
                        /* ml553: also report the FAULTING DATA ADDRESS and whether it is
                         * mapped at all. The login-window crash reconstructs to
                         * libcef+0x41258FB — the loop head of Chromium's frame clear
                         * (`movl %edx,(%r10)`) — so the question is whether that store's
                         * destination pointer is wild. This path DELIVERS the exception to
                         * the guest, so it never produces a [mach_exc] UNHANDLED record and
                         * the data address was the one thing never logged.
                         *
                         * Reads the region rather than trusting a flag: "unmapped" vs "mapped
                         * but wrong protection" point at completely different bugs (a bad
                         * pointer computation vs a protection race). */
                        {
                            mach_vm_address_t ra = (mach_vm_address_t)fault_addr;
                            mach_vm_size_t rs = 0;
                            vm_region_basic_info_data_64_t rbi;
                            mach_msg_type_number_t rc = VM_REGION_BASIC_INFO_COUNT_64;
                            mach_port_t ro = MACH_PORT_NULL;
                            int hp = -1;
                            unsigned long long rbase = 0, rsize = 0;
                            if (fault_addr &&
                                mach_vm_region( mach_task_self(), &ra, &rs, VM_REGION_BASIC_INFO_64,
                                                (vm_region_info_t)&rbi, &rc, &ro ) == KERN_SUCCESS)
                            { hp = rbi.protection; rbase = (unsigned long long)ra; rsize = (unsigned long long)rs; }
                            dprintf(STDERR_FILENO,
                                "[fault_rip] cnt=%d rip=0x%llx pc=0x%llx addr=0x%llx "
                                "kr=%llu(%s) entryprot=%d nowprot=%d region=0x%llx+0x%llx%s%s%s rev=ml555\n",
                                cnt, (unsigned long long)state_rip_q,
                                (unsigned long long)fault_pc_check,
                                (unsigned long long)fault_addr,
                                fault_kr,
                                fault_kr == 1 ? "INVALID_ADDRESS" :
                                fault_kr == 2 ? "PROTECTION_FAILURE" : "other",
                                entry_prot, hp, rbase, rsize,
                                entry_prot < 0 ? "  <== UNMAPPED AT ENTRY (wild pointer)" : "",
                                (entry_prot >= 0 && hp >= 0 && entry_prot != hp)
                                    ? "  <== PROT CHANGED MID-HANDLER (race)" : "",
                                first_seen ? " [first]" : "");
                        }
                    }
                    /* TEMP [rip-leak] task#34 ml64-class: guest RIP inside a
                     * JIT-POOL mapping means a pool-translated pointer leaked
                     * into guest control flow (guest must only ever see PE
                     * VAs; ml64 ran away executing dbghelp's pool ARM64 .text
                     * as x86). Name the module+RVA and dump the guest return
                     * stack so the SOURCE of the poisoned pointer is
                     * identifiable. Capped. STRIP BEFORE COMMIT. */
                    if (first_seen && state_rip_q)
                    {
                        extern uint64_t ios_jit_reverse_translate( uint64_t addr, uint64_t *module_base );
                        uint64_t mod_base = 0;
                        uint64_t pe = ios_jit_reverse_translate( state_rip_q, &mod_base );
                        static int leak_n;
                        if (pe && leak_n < 12)
                        {
                            uint64_t rsp = state.__x[23];  /* ARM64EC SRA: RSP=x23 */
                            uint64_t stk[8] = { 0 };
                            vm_size_t outsz = sizeof(stk);
                            leak_n++;
                            vm_read_overwrite( mach_task_self(), rsp, sizeof(stk),
                                               (vm_address_t)stk, &outsz );
                            dprintf(STDERR_FILENO,
                                "[rip-leak] guest RIP 0x%llx IS POOL addr = PE 0x%llx (module base 0x%llx rva 0x%llx)\n"
                                "[rip-leak] guest RSP=0x%llx stack: %llx %llx %llx %llx %llx %llx %llx %llx\n",
                                (unsigned long long)state_rip_q, (unsigned long long)pe,
                                (unsigned long long)mod_base,
                                (unsigned long long)(pe - mod_base),
                                (unsigned long long)rsp,
                                (unsigned long long)stk[0], (unsigned long long)stk[1],
                                (unsigned long long)stk[2], (unsigned long long)stk[3],
                                (unsigned long long)stk[4], (unsigned long long)stk[5],
                                (unsigned long long)stk[6], (unsigned long long)stk[7]);
                        }
                        /* task #34: reverse_translate returns 0 for a TOMBSTONED
                         * pool copy (owner cleared on unload/reclaim). That's the
                         * jsproxy-wall signature — the child pseudo-proc executing
                         * a pool copy its parent created and that's since been
                         * tombstoned. Name the owner directly so the parent/child
                         * ownership bug is unambiguous. */
                        if (!pe)
                        {
                            extern void *ios_jit_rx_base_global;
                            extern size_t ios_jit_pool_size_global;
                            extern void *ios_jit_pool_copy_owner(const void *addr, void **pe_base_out);
                            uint64_t rx = (uint64_t)(uintptr_t)ios_jit_rx_base_global;
                            if (rx && state_rip_q >= rx && state_rip_q < rx + ios_jit_pool_size_global)
                            {
                                void *tpe = NULL;
                                void *towner = ios_jit_pool_copy_owner( (void *)(uintptr_t)state_rip_q, &tpe );
                                dprintf(STDERR_FILENO,
                                    "[rip-tomb] guest RIP 0x%llx in POOL (off 0x%llx) but NO live mapping — copy_owner=%p pe=%p (tombstoned/foreign pool copy; cross-ref [jit-pool] image name)\n",
                                    (unsigned long long)state_rip_q,
                                    (unsigned long long)(state_rip_q - rx),
                                    towner, tpe);
                            }
                        }
                    }
                }
                /* ml125: a runaway exec-fault storm hit 7.26 MILLION faults;
                 * at one line per 100 that alone wrote 72k lines and a 314k-line
                 * log, which costs device I/O and buries everything useful.
                 * After the first 200 reports the rate drops to 1-in-100000 —
                 * still enough to prove a storm is running and show where it
                 * ends, without the flood. terminal_pc always reports. */
                if (cnt <= 5 || terminal_pc ||
                    (cnt <= 20000 ? (cnt % 100) == 0 : (cnt % 100000) == 0))
                {
                    uint64_t fault_pc = fault_pc_check;
                    dprintf(STDERR_FILENO, "[mach_exc] UNHANDLED #%d pc=%p addr=%p x18=%p type=%d lr=%p sp=%p x16=%p x17=%p\n",
                        cnt, (void*)(uintptr_t)fault_pc, (void*)fault_addr,
                        (void*)(uintptr_t)state.__x[18], req->exception,
                        (void*)(uintptr_t)state.__lr,
                        (void*)(uintptr_t)__darwin_arm_thread_state64_get_sp(state),
                        (void*)(uintptr_t)state.__x[16],
                        (void*)(uintptr_t)state.__x[17]);
                    /* ml254: 4797 of 4832 faults share ONE call site
                     * (libarm64ecfex+0x1e8060: adrp/ldr x8,[x8,#0x38]/ldr x16,[x8]/blr x16
                     * -- an indirect call through a pointer-to-pointer, i.e. an import
                     * slot) and ONE target, x16=0x155ffc138: pool offset 0x37ffc138, the
                     * LAST page of the pool, in the trampoline region above the `used`
                     * cursor. Control reaches tiny, ODD-aligned PCs (0x22d1, 0x22d5) --
                     * odd is why bus_handler reports exec=1 -- so the tramp RAN and then
                     * branched to garbage. The same high band held the earlier CASPAL
                     * use-after-free (0x1541af700, MEM_FREE).
                     *
                     * Three candidate causes need different fixes: (a) tramp bytes are
                     * zero/garbage -- it was never written or was overwritten; (b) tramp
                     * is intact but its embedded target is stale -- a lifetime bug;
                     * (c) the page is gone (MEM_FREE / reclaimed / non-exec) -- a mapping
                     * bug. Only the bytes plus the region info discriminate, so dump both.
                     * Self-targeting (tiny pc + x16 in pool) so a storm cannot flood it. */
                    {
                        extern void *ios_jit_rx_base_global;
                        extern size_t ios_jit_pool_size_global;
                        uint64_t x16v = (uint64_t)state.__x[16];
                        uint64_t rxb  = (uint64_t)(uintptr_t)ios_jit_rx_base_global;
                        static int tramp_dumps;
                        /* ml255/ml256: the ORIGINAL condition also required x16 to be a
                         * pool address, which was fitted to ml254's signature
                         * (x16=0x155ffc138) rather than to the invariant. Two runs later
                         * x16 was 0x0 / 0x4000 / 0x1fffffff and the probe correctly but
                         * uselessly declined. The invariant is the tiny bogus pc; x16 is
                         * the thing we are trying to LEARN about, so it must not gate. */
                        if (fault_pc < 0x10000 && tramp_dumps < 6)
                        {
                            mach_vm_address_t qa = (mach_vm_address_t)(x16v & ~0x3fffull);
                            mach_vm_size_t qs = 0;
                            vm_region_extended_info_data_t qi;
                            mach_msg_type_number_t qc = VM_REGION_EXTENDED_INFO_COUNT;
                            mach_port_t qo = MACH_PORT_NULL;
                            kern_return_t qkr;
                            /* extended info carries share_mode/user_tag but NOT
                             * max_protection; basic_64 carries max. Need both, and
                             * max is the one that says "can never be exec again". */
                            mach_vm_address_t ba = qa;
                            mach_vm_size_t bs = 0;
                            vm_region_basic_info_data_64_t bi;
                            mach_msg_type_number_t bc = VM_REGION_BASIC_INFO_COUNT_64;
                            mach_port_t bo = MACH_PORT_NULL;
                            int bmax = -1;

                            tramp_dumps++;
                            if (mach_vm_region( mach_task_self(), &ba, &bs,
                                                VM_REGION_BASIC_INFO_64,
                                                (vm_region_info_t)&bi, &bc, &bo ) == KERN_SUCCESS
                                && ba <= (x16v & ~0x3fffull))
                                bmax = bi.max_protection;
                            qkr = mach_vm_region( mach_task_self(), &qa, &qs,
                                                  VM_REGION_EXTENDED_INFO,
                                                  (vm_region_info_t)&qi, &qc, &qo );
                            if (qkr == KERN_SUCCESS && qa <= (x16v & ~0x3fffull))
                                dprintf(STDERR_FILENO,
                                    "[tramp-dump] x16=0x%llx pooloff=0x%llx REGION base=0x%llx size=0x%llx "
                                    "prot=0x%x max=0x%x share=%d tag=%d\n",
                                    (unsigned long long)x16v,
                                    (unsigned long long)(rxb ? x16v - rxb : 0),
                                    (unsigned long long)qa, (unsigned long long)qs,
                                    qi.protection, bmax,
                                    qi.share_mode, qi.user_tag);
                            else
                                dprintf(STDERR_FILENO,
                                    "[tramp-dump] x16=0x%llx pooloff=0x%llx REGION **NONE** (kr=%d, first region above = 0x%llx) "
                                    "-- page is NOT MAPPED\n",
                                    (unsigned long long)x16v,
                                    (unsigned long long)(rxb ? x16v - rxb : 0),
                                    qkr, (unsigned long long)qa);

                            /* the tramp's own words -- only if the page is readable */
                            if (qkr == KERN_SUCCESS && qa <= (x16v & ~0x3fffull) &&
                                (qi.protection & VM_PROT_READ))
                            {
                                const uint32_t *w = (const uint32_t *)(uintptr_t)x16v;
                                dprintf(STDERR_FILENO,
                                    "[tramp-dump]   words: %08x %08x %08x %08x %08x %08x\n",
                                    w[0], w[1], w[2], w[3], w[4], w[5]);
                            }
                        }
                    }
                    /* ml224: name the faulting address against the JIT-pool ledger.
                     *
                     * Steam/CEF dies on a 128-bit atomic whose target VirtualQuery
                     * reports MEM_FREE while sitting INSIDE the pool's span -- so the
                     * pointer is dangling, not misaligned, and pool lifetime is the
                     * suspect. Whether the range is on the reclaim freelist, still a live
                     * mapping, or neither picks between three different fixes, and this
                     * is the only place that can tell. Rate-limited with the dump it
                     * rides on, so a fault storm cannot flood the log. */
                    {
                        extern void ios_jit_describe_pool_addr( const void *addr, char *buf,
                                                                size_t buflen );
                        static int ledger_n;
                        char pooldesc[192];

                        /* ml225: riding the mach_exc limiter alone still produced 3790
                         * lines in one run, because a null-deref storm (addr=0x10/0xc/0x2)
                         * asks the ledger a question it can only answer "OUTSIDE pool".
                         * Only sub-pool-band addresses are interesting here, and cap the
                         * rest, so the interesting verdict cannot be buried. */
                        if (ledger_n < 40 && fault_addr >= 0x10000)
                        {
                            ledger_n++;
                            ios_jit_describe_pool_addr( (const void *)fault_addr, pooldesc,
                                                        sizeof(pooldesc) );
                            dprintf( STDERR_FILENO, "[mach_exc]   [pool-ledger] addr=%p : %s\n",
                                     (void *)fault_addr, pooldesc );
                        }
                    }
                    /* ml226: is the guest RSP TRUNCATED TO 32 BITS, or already garbage?
                     *
                     * The recurring fatal address family is 0x40001141 / 0x80001141 /
                     * 0xe0001141 -- all 32-bit values with identical low halves, reached
                     * through a guest PUSH (ldr x2,[x28,#0x40]; sub x2,x2,#0x10; str x0,[x2]).
                     * A 64-bit RSP does not look like that. One reading is an instruction
                     * writing RSP with 32-bit operand size (mov esp,eax semantics), which
                     * would be a FEX decode bug; the other is that RSP arrived corrupt from
                     * somewhere upstream, which is a different bug entirely.
                     *
                     * Decide it by dumping the guest state and the x86 bytes AT the guest
                     * RIP. If those bytes decode to a 32-bit write to RSP the first reading
                     * is confirmed; if they are an ordinary push/call then RSP was already
                     * wrong on entry and the truncation idea is dead. Prints the raw bytes
                     * rather than a verdict so it can say "neither". */
                    {
                        static int rsp_n;
                        uint64_t st28 = state.__x[28];
                        uint64_t cs[5];            /* +0x18 rip .. +0x38 */
                        uint64_t rsp = 0;
                        unsigned char code[16];
                        mach_vm_size_t g = 0;

                        if (rsp_n < 12 && st28 > 0x100000 &&
                            mach_vm_read_overwrite( mach_task_self(),
                                (mach_vm_address_t)(st28 + 0x18), sizeof(cs),
                                (mach_vm_address_t)cs, &g ) == KERN_SUCCESS && g == sizeof(cs) &&
                            mach_vm_read_overwrite( mach_task_self(),
                                (mach_vm_address_t)(st28 + 0x40), 8,
                                (mach_vm_address_t)&rsp, &g ) == KERN_SUCCESS)
                        {
                            rsp_n++;
                            dprintf( STDERR_FILENO,
                                     "[rsp-trunc] x28=%p guest_rip=%p rsp=%p rsp_hi32=%s\n",
                                     (void *)st28, (void *)cs[0], (void *)rsp,
                                     (rsp >> 32) ? "set (64-bit)" : "ZERO (looks truncated)" );
                            g = 0;
                            if (cs[0] && mach_vm_read_overwrite( mach_task_self(),
                                    (mach_vm_address_t)cs[0], sizeof(code),
                                    (mach_vm_address_t)code, &g ) == KERN_SUCCESS &&
                                g == sizeof(code))
                                dprintf( STDERR_FILENO,
                                         "[rsp-trunc]   x86 @rip: %02x %02x %02x %02x %02x %02x %02x %02x"
                                         " %02x %02x %02x %02x %02x %02x %02x %02x\n",
                                         code[0],code[1],code[2],code[3],code[4],code[5],code[6],code[7],
                                         code[8],code[9],code[10],code[11],code[12],code[13],code[14],code[15] );
                            else
                                dprintf( STDERR_FILENO, "[rsp-trunc]   x86 @rip UNREADABLE\n" );

                            /* iOS-Madeira ml333: is the guest code we EXECUTE the guest code that was
                             * LOADED?
                             *
                             * ml332's fatal was c000001d with the bytes at guest RIP reading
                             * `cc 0f 0b` = int3; ud2 -- Chromium's IMMEDIATE_CRASH(). But the device's
                             * own libcef.dll has completely different bytes at that RVA (verified
                             * offline against the file pulled from the container; single libcef load,
                             * base confirmed). So in-memory guest code != on-disk guest code, and the
                             * three explanations need separating rather than guessing:
                             *   (a) the PE mapping is fine and only the POOL COPY we execute is wrong
                             *       -- a mapping/copy bug on our side,
                             *   (b) both differ from the file -- something overwrote guest code,
                             *   (c) the RIP is bogus and neither is meaningful.
                             * Print the same 16 bytes from the pool copy next to the PE mapping. If
                             * they differ, it is (a); if they agree but both differ from the file,
                             * it is (b). Either answer names the bug; silence is impossible because
                             * the translate result is printed even when it is an identity. */
                            {
                                extern void *ios_jit_translate_addr( void *addr );
                                unsigned char pcode[16];
                                void *pool_rip = ios_jit_translate_addr( (void *)cs[0] );

                                g = 0;
                                if (pool_rip && pool_rip != (void *)cs[0] &&
                                    mach_vm_read_overwrite( mach_task_self(),
                                        (mach_vm_address_t)pool_rip, sizeof(pcode),
                                        (mach_vm_address_t)pcode, &g ) == KERN_SUCCESS &&
                                    g == sizeof(pcode))
                                    dprintf( STDERR_FILENO,
                                             "[guest-code] rev=ml333 pool_rip=%p (PE %p): "
                                             "%02x %02x %02x %02x %02x %02x %02x %02x"
                                             " %02x %02x %02x %02x %02x %02x %02x %02x\n",
                                             pool_rip, (void *)cs[0],
                                             pcode[0],pcode[1],pcode[2],pcode[3],pcode[4],pcode[5],pcode[6],pcode[7],
                                             pcode[8],pcode[9],pcode[10],pcode[11],pcode[12],pcode[13],pcode[14],pcode[15] );
                                else
                                    dprintf( STDERR_FILENO,
                                             "[guest-code] rev=ml333 pool_rip=%p (PE %p) -- %s\n",
                                             pool_rip, (void *)cs[0],
                                             (!pool_rip || pool_rip == (void *)cs[0])
                                                 ? "NO pool copy for this address (identity translate)"
                                                 : "pool copy UNREADABLE" );
                            }
                        }
                    }
                    /* [ec-fault-regs] the faulting insn f8686928 = ldr x8,[x9,x8]:
                     * addr = x9(base) + x8(index). Dump x8..x11 so we can name the
                     * table (EC bitmap? syscall-frame? LookupCache?) and why it's bad. */
                    if (cnt <= 3)
                    {
                        void *peb_ecbm = NULL; void *peb_p = NULL;
                        if (thread_teb) {
                            peb_p = ((TEB *)thread_teb)->Peb;
                            /* PEB->EcCodeBitMap read DIRECTLY (same struct is_ec_code
                             * uses). If this != 0 but x9==0, is_ec_code read a wrong
                             * offset / wrong peb; if this == 0, the field is really null
                             * for this thread's peb (timing / peb not wired). */
                            if (peb_p) peb_ecbm = ((PEB *)peb_p)->EcCodeBitMap;
                        }
                        dprintf(STDERR_FILENO, "[ec-fault-regs] x8=%p x9=%p x10=%p x11=%p x0=%p x2=%p | teb=%p peb=%p peb->EcCodeBitMap=%p\n",
                            (void*)(uintptr_t)state.__x[8], (void*)(uintptr_t)state.__x[9],
                            (void*)(uintptr_t)state.__x[10], (void*)(uintptr_t)state.__x[11],
                            (void*)(uintptr_t)state.__x[0], (void*)(uintptr_t)state.__x[2],
                            (void *)thread_teb, peb_p, peb_ecbm);
                    }
                    /* Read instruction at LR-4 to identify the BL/BLR */
                    if (cnt <= 3 && (uintptr_t)state.__lr >= 0x100000000ULL)
                    {
                        uint32_t *lr_p = (uint32_t*)(uintptr_t)(state.__lr - 4);
                        dprintf(STDERR_FILENO, "[mach_exc] caller_insn @lr-4=0x%p: 0x%08x\n",
                            (void*)lr_p, *lr_p);
                    }
                    /* Which pool COPY is pc in, and who owns it? Names the
                     * session-vs-child copy — the PE attribution below can't
                     * (all copies share PE VAs). owner=-1 = not pool. */
                    {
                        extern void *ios_jit_pool_copy_owner(const void *addr, void **pe_base_out);
                        void *copy_pe = NULL;
                        void *copy_owner = ios_jit_pool_copy_owner((void *)(uintptr_t)fault_pc, &copy_pe);
                        void *cur_teb_peb = thread_teb ? ((TEB *)thread_teb)->Peb : NULL;
                        dprintf(STDERR_FILENO,
                            "[mach_exc] pc pool-copy pe=%p owner=%p; thread teb=%p peb=%p\n",
                            copy_pe, copy_owner, (void *)thread_teb, cur_teb_peb);
                        /* [nls-probe] The first fault is upcase_unicode_to_utf8 (ntdll RVA
                         * 0x38aa8) reading the NLS upcase-table pointer at ntdll .data RVA
                         * 0xc04e0 via `adrp x16,0xc0000; ldr x7,[x16,#0x4e0]` — and getting
                         * NULL. Compare the value the POOL copy read (x16+0x4e0) against the
                         * PE mapping's own .data (copy_pe+0xc04e0). If PE!=0 && pool==0 the
                         * pool copy's .data is stale (fix = sync/share ntdll .data); if both
                         * 0 the PE global was never populated (fix is upstream NLS init). */
                        if (cnt <= 2 && copy_pe && (uintptr_t)copy_pe >= 0x100000000ULL)
                        {
                            uint64_t x16v = (uint64_t)state.__x[16];
                            uint64_t pool_v = (x16v >= 0x100000000ULL)
                                ? *(volatile uint64_t *)(uintptr_t)(x16v + 0x4e0) : 0xdead1;
                            uint64_t pe_v = *(volatile uint64_t *)((uintptr_t)copy_pe + 0xc04e0);
                            dprintf(STDERR_FILENO,
                                "[nls-probe] upcase ptr: pool[x16+0x4e0]=0x%llx  PE[pe+0xc04e0]=0x%llx  (x16=0x%llx pe=%p rva_pc=0x%llx)\n",
                                (unsigned long long)pool_v, (unsigned long long)pe_v,
                                (unsigned long long)x16v, copy_pe,
                                (unsigned long long)((uintptr_t)fault_pc - ((uintptr_t)fault_pc & ~0xfffffULL)));
                        }
                    }
                    /* ml982: `fault_pc >= 0x100000000` only says the address is
                     * above the iOS floor -- it says nothing about whether the
                     * page is mapped or readable, and this is the reporter for a
                     * fault that is frequently an unmapped or non-executable PC.
                     * Copy through a checked read instead of dereferencing. */
                    if ((uintptr_t)fault_pc >= 0x100000000ULL + 12)
                    {
                        uint32_t ins[7];
                        mach_vm_size_t got = 0;
                        if (mach_vm_read_overwrite( mach_task_self(),
                                                    (mach_vm_address_t)((uintptr_t)fault_pc - 12),
                                                    sizeof(ins), (mach_vm_address_t)ins,
                                                    &got ) == KERN_SUCCESS && got == sizeof(ins))
                            dprintf(STDERR_FILENO, "[mach_exc] insn_stream PC-12..PC+8: %08x %08x %08x [%08x] %08x %08x %08x\n",
                                ins[0], ins[1], ins[2], ins[3], ins[4], ins[5], ins[6]);
                        else
                            dprintf(STDERR_FILENO, "[mach_exc] ml982 insn_stream at pc=%#llx <unreadable> (got=%llu)\n",
                                (unsigned long long)fault_pc, (unsigned long long)got);
                    }
                    /* iOS-Madeira: symbolize pc/lr via dladdr — works for
                     * dyld-cache addresses in-process. Names the native
                     * subsystem when a fault lands in system frameworks
                     * (e.g. the 2026-07-04 post-UNIXCALL-DIRECT crash at
                     * 0x18521c0d0 was unattributable offline: DeviceSupport
                     * symbol tree only has lazily-extracted dylibs). */
                    {
                        /* ml982: initialise these and KEEP the lookup result.
                         *
                         * They were uninitialised locals whose dladdr() return was
                         * used to guard immediate use but then discarded. The
                         * one-shot prologue dump further down then tested
                         * `di_pc.dli_saddr` on its own and dereferenced it raw --
                         * so a FAILED lookup left stack garbage in dli_saddr and the
                         * dump read through it.
                         *
                         * That is the wedge in rdr44-52. The fault is at
                         * 0x9a4c0829c, the bootstrap kernelbase VirtualAlloc entry
                         * thunk, which is not a dyld image, so dladdr fails and the
                         * log prints `pc=?`. The handler then faulted on its own
                         * diagnostic load -- sampled at
                         * ios_mach_exception_thread+0x6660, which disassembles to
                         * `ldp w8,w9,[x25]` with x25 loaded from Dl_info+0x18
                         * (dli_saddr). Because the shared exception port is
                         * installed at TASK level as well as per-thread, the only
                         * handler faulted while servicing a fault and waited on
                         * itself: both it and the faulting game thread then sit at
                         * unchanged PCs with zero CPU forever, and not one
                         * `[mach_exc] fn+` row is ever printed. */
                        Dl_info di_pc, di_lr;
                        int pc_named = 0, lr_named = 0;
                        const char *pc_img = "?", *pc_sym = "?"; uint64_t pc_off = 0;
                        const char *lr_img = "?", *lr_sym = "?"; uint64_t lr_off = 0;
                        memset( &di_pc, 0, sizeof(di_pc) );
                        memset( &di_lr, 0, sizeof(di_lr) );
                        if ((pc_named = (dladdr((void*)(uintptr_t)fault_pc, &di_pc) != 0)))
                        {
                            if (di_pc.dli_fname) pc_img = di_pc.dli_fname;
                            if (di_pc.dli_sname) { pc_sym = di_pc.dli_sname;
                                pc_off = fault_pc - (uint64_t)(uintptr_t)di_pc.dli_saddr; }
                        }
                        if ((lr_named = (dladdr((void*)(uintptr_t)state.__lr, &di_lr) != 0)))
                        {
                            if (di_lr.dli_fname) lr_img = di_lr.dli_fname;
                            if (di_lr.dli_sname) { lr_sym = di_lr.dli_sname;
                                lr_off = state.__lr - (uint64_t)(uintptr_t)di_lr.dli_saddr; }
                        }
                        dprintf(STDERR_FILENO,
                            "[mach_exc] sym pc=%s`%s+0x%llx lr=%s`%s+0x%llx\n",
                            pc_img, pc_sym, (unsigned long long)pc_off,
                            lr_img, lr_sym, (unsigned long long)lr_off);
                        /* JIT-pool addresses: name the PE module + offset
                         * (same machinery as [thread-stacks]) so faults in
                         * copied PE code self-symbolize. */
                        {
                            extern uint64_t ios_jit_reverse_translate( uint64_t addr, uint64_t *module_base );
                            uint64_t mod, va;
                            if ((va = ios_jit_reverse_translate( fault_pc, &mod )))
                                dprintf(STDERR_FILENO, "[mach_exc] pc PE: %s+0x%llx (va=0x%llx)\n",
                                        ios_pe_module_name(mod), (unsigned long long)(va - mod),
                                        (unsigned long long)va);
                            /* [bucketscan-probe] Thumper dies in FEXCore GuestToHostMap::BlockList
                             * (ankerl unordered_dense) do_find (libarm64ecfex ~RVA 0x1d140-0x1d280,
                             * caller LookupCache::FindBlock) scanning its bucket array OFF THE END:
                             * loop `add x17,x11,w12,uxtw#3; ldr w1,[x17]` => x11=buckets base,
                             * w12=index, x17=x11+w12*8 walks unmapped guest mem. Dump base/index/
                             * scan-distance/key (NO deref — stay signal-safe) to tell UNINITIALIZED
                             * (x11 garbage/tiny, no valid array) from TORN-READ (x11 a valid heap
                             * ptr but distance huge => bounds/mask stale from a concurrent swap). */
                            {
                                uint64_t bs_mod, bs_va;
                                if ((bs_va = ios_jit_reverse_translate( fault_pc, &bs_mod )))
                                {
                                    uint64_t bs_rva = bs_va - bs_mod;
                                    /* [findblock-probe] LookupCache::FindBlock(x0=this=LookupCache*, x1=Thread,
                                     * x2=Address). Its L1 lookup faults at ~0x18c90: ldp x8,x9,[x0,#0x30] (x0[0x30]=
                                     * L1 base, x0[0x38]=L1 mask), x25=x8+(x9&x2)<<4, ldr [x25]. Capture x0 (the LIVE
                                     * LookupCache ptr — dead by do_find) + L1 fields to tell a BOGUS x0 (garbage/
                                     * guest ptr from the dispatcher/StateFrame) from a valid-but-corrupted cache. */
                                    if (bs_rva >= 0x18c70 && bs_rva < 0x18e20)
                                    {
                                        static volatile int fb_seen = 0;
                                        if (__sync_fetch_and_add(&fb_seen, 1) < 6)
                                        {
                                            uint64_t x0v = (uint64_t)state.__x[0];
                                            uint64_t l1base = 0xdead, l1mask = 0xdead;
                                            int host = (x0v >= 0x100000000ULL && x0v < 0x800000000000ULL);
                                            if (host) {
                                                l1base = *(volatile uint64_t *)(uintptr_t)(x0v + 0x30);
                                                l1mask = *(volatile uint64_t *)(uintptr_t)(x0v + 0x38);
                                            }
                                            dprintf(STDERR_FILENO,
                                                "[findblock-probe] rva=0x%llx x0(LookupCache)=0x%llx host=%d x1(Thread)=0x%llx x2(rip)=0x%llx L1base[0x30]=0x%llx L1mask[0x38]=0x%llx\n",
                                                (unsigned long long)bs_rva, (unsigned long long)x0v, host,
                                                (unsigned long long)state.__x[1], (unsigned long long)state.__x[2],
                                                (unsigned long long)l1base, (unsigned long long)l1mask);
                                        }
                                    }
                                    if (bs_rva >= 0x1d100 && bs_rva < 0x1d300)
                                    {
                                        static volatile int bs_seen = 0;
                                        if (__sync_fetch_and_add(&bs_seen, 1) < 6)
                                        {
                                            uint64_t x8v  = (uint64_t)state.__x[8];
                                            uint64_t x11v = (uint64_t)state.__x[11];
                                            uint64_t x12v = (uint64_t)state.__x[12];
                                            uint64_t x15v = (uint64_t)state.__x[15];
                                            uint64_t x17v = (uint64_t)state.__x[17];
                                            dprintf(STDERR_FILENO,
                                                "[bucketscan-probe] do_find rva=0x%llx x11(base)=0x%llx x17(cur)=0x%llx scan_dist=0x%llx(%llu buckets) x8=0x%llx x12(idx)=0x%llx x15(key)=0x%llx\n",
                                                (unsigned long long)bs_rva, (unsigned long long)x11v,
                                                (unsigned long long)x17v, (unsigned long long)(x17v - x11v),
                                                (unsigned long long)((x17v - x11v) / 8), (unsigned long long)x8v,
                                                (unsigned long long)x12v, (unsigned long long)x15v);
                                            /* Dump the actual bucket CONTENTS at x11 (m_buckets). This range is
                                             * mapped (the scan reads it up to x17). Each ankerl bucket = 8 bytes
                                             * {u32 dist_and_fingerprint, u32 value_idx}. All-zero => empty (do_find
                                             * would have stopped); small ascending d_a_f => a real map; random
                                             * huge values => uninitialized/torn/UAF backing store. Also dump
                                             * callee-saved regs so we can recover `this` (do_find: this[0x18]==
                                             * m_buckets, this[0x3e]=m_shifts) offline. */
                                            {
                                                uint64_t bk[6] = {0,0,0,0,0,0};
                                                if (x11v >= 0x100000000ULL && x11v < 0x800000000000ULL)
                                                    for (int bi = 0; bi < 6; bi++)
                                                        bk[bi] = *(volatile uint64_t *)(uintptr_t)(x11v + (uint64_t)bi * 8);
                                                dprintf(STDERR_FILENO,
                                                    "[bucketscan-probe] buckets@x11: %016llx %016llx %016llx %016llx %016llx %016llx | x0=%llx x9=%llx x10=%llx x19=%llx x20=%llx x21=%llx x22=%llx\n",
                                                    (unsigned long long)bk[0], (unsigned long long)bk[1],
                                                    (unsigned long long)bk[2], (unsigned long long)bk[3],
                                                    (unsigned long long)bk[4], (unsigned long long)bk[5],
                                                    (unsigned long long)state.__x[0], (unsigned long long)state.__x[9],
                                                    (unsigned long long)state.__x[10], (unsigned long long)state.__x[19],
                                                    (unsigned long long)state.__x[20], (unsigned long long)state.__x[21],
                                                    (unsigned long long)state.__x[22]);
                                                /* Recover the map `this`: do_find has this[0x18]==m_buckets(x11v).
                                                 * Whichever candidate reg, at +0x18, holds x11v is `this`. Then dump
                                                 * its ankerl fields to tell a real-but-corrupted map (sane values
                                                 * ptrs, only m_buckets bad) from a wrong/guest `this`. Guarded reads. */
                                                {
                                                    uint64_t cands[4] = { (uint64_t)state.__x[10], (uint64_t)state.__x[19],
                                                                          (uint64_t)state.__x[21], (uint64_t)state.__x[0] };
                                                    int found = 0;
                                                    for (int ci = 0; ci < 4 && !found; ci++) {
                                                        uint64_t th = cands[ci];
                                                        if (th < 0x100000000ULL || th >= 0x800000000000ULL) continue;
                                                        uint64_t mb = *(volatile uint64_t *)(uintptr_t)(th + 0x18);
                                                        if (mb != x11v) continue;
                                                        found = 1;
                                                        uint64_t vb  = *(volatile uint64_t *)(uintptr_t)(th + 0x0);
                                                        uint64_t ve  = *(volatile uint64_t *)(uintptr_t)(th + 0x8);
                                                        uint64_t f20 = *(volatile uint64_t *)(uintptr_t)(th + 0x20);
                                                        uint64_t f28 = *(volatile uint64_t *)(uintptr_t)(th + 0x28);
                                                        uint8_t  sh  = *(volatile uint8_t  *)(uintptr_t)(th + 0x3e);
                                                        dprintf(STDERR_FILENO,
                                                            "[bucketscan-probe] THIS=0x%llx(reg%d) values.begin=0x%llx end=0x%llx [0x20]=0x%llx [0x28]=0x%llx m_shifts=0x%x\n",
                                                            (unsigned long long)th, ci, (unsigned long long)vb,
                                                            (unsigned long long)ve, (unsigned long long)f20,
                                                            (unsigned long long)f28, sh);
                                                    }
                                                    if (!found)
                                                        dprintf(STDERR_FILENO,
                                                            "[bucketscan-probe] THIS not found in x0/x10/x19/x21 (map ptr not in loop regs)\n");
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            if ((va = ios_jit_reverse_translate( state.__lr, &mod )))
                                dprintf(STDERR_FILENO, "[mach_exc] lr PE: %s+0x%llx (va=0x%llx)\n",
                                        ios_pe_module_name(mod), (unsigned long long)(va - mod),
                                        (unsigned long long)va);
                            /* [nullfp-probe] When the fault is #arm64x_check_call with x11=0,
                             * the EC indirect-call TARGET is null. The caller pattern is
                             *   lr-0x1c: adrp xN, PAGE ;  lr-0xc: ldr x11,[xN,#OFF] ;  lr-4: blr x8
                             * Decode adrp+ldr to recover the target-global address, then read it
                             * from BOTH the pool COPY and the PE mapping. pool==0 && PE!=0 => the
                             * pool copy's .data was never relocated/synced (same class as the NLS
                             * casemap bug); both==0 => the static-init that populates it never ran. */
                            if (cnt <= 3 && va && (uintptr_t)state.__x[11] == 0 &&
                                (uintptr_t)state.__lr >= 0x100000000ULL)
                            {
                                uint64_t lr_rva = va - mod;
                                uint64_t pool_base = (uint64_t)state.__lr - lr_rva;
                                uint32_t *cp = (uint32_t *)(uintptr_t)state.__lr;
                                uint32_t adrp_i = cp[-7];   /* lr-0x1c */
                                uint32_t ldr_i  = cp[-3];   /* lr-0xc  */
                                int is_adrp = ((adrp_i >> 24) & 0x9f) == 0x90;
                                int is_ldr  = ((ldr_i  >> 22) & 0x3ff) == 0x3e5; /* LDR imm,64 unsigned */
                                if (is_adrp && is_ldr)
                                {
                                    int64_t immlo = (adrp_i >> 29) & 0x3;
                                    int64_t immhi = (adrp_i >> 5) & 0x7ffff;
                                    int64_t imm = (immhi << 2) | immlo;
                                    if (imm & (1LL << 20)) imm |= ~((1LL << 21) - 1);
                                    uint64_t adrp_pc = (uint64_t)state.__lr - 0x1c;
                                    uint64_t page = (adrp_pc & ~0xfffULL) + ((uint64_t)imm << 12);
                                    uint64_t off  = (uint64_t)((ldr_i >> 10) & 0xfff) << 3;
                                    uint64_t g_pool = page + off;
                                    uint64_t g_rva  = g_pool - pool_base;
                                    uint64_t gv_pool = *(volatile uint64_t *)(uintptr_t)g_pool;
                                    uint64_t gv_pe   = *(volatile uint64_t *)(uintptr_t)(mod + g_rva);
                                    dprintf(STDERR_FILENO,
                                        "[nullfp-probe] tgt-global rva=0x%llx pool[0x%llx]=0x%llx PE[0x%llx]=0x%llx mod=%s lr_rva=0x%llx\n",
                                        (unsigned long long)g_rva,
                                        (unsigned long long)g_pool, (unsigned long long)gv_pool,
                                        (unsigned long long)(mod + g_rva), (unsigned long long)gv_pe,
                                        ios_pe_module_name(mod), (unsigned long long)lr_rva);
                                }
                                else
                                    dprintf(STDERR_FILENO,
                                        "[nullfp-probe] caller not adrp+ldr: adrp_i=0x%08x ldr_i=0x%08x lr_rva=0x%llx mod=%s\n",
                                        adrp_i, ldr_i, (unsigned long long)(va - mod), ios_pe_module_name(mod));
                            }
                        }
                        /* fp-chain backtrace of the faulting thread — names
                         * the exact native call path (which Metal call fed
                         * free() a garbage pointer). Native code has honest
                         * x29 chains; stop on invalid fp. */
                        if (cnt <= 3)
                        {
                            uint64_t fp_walk = state.__fp;
                            int fr;
                            for (fr = 0; fr < 10 && fp_walk; fr++)
                            {
                                uint64_t frame_buf[2];
                                mach_vm_size_t got_fw = 0;
                                if (mach_vm_read_overwrite(mach_task_self(),
                                        (mach_vm_address_t)fp_walk, 16,
                                        (mach_vm_address_t)frame_buf, &got_fw)
                                        != KERN_SUCCESS || got_fw != 16)
                                    break;
                                {
                                    uint64_t ret_pc = frame_buf[1];
                                    Dl_info di_f;
                                    const char *f_img = "?", *f_sym = "?";
                                    uint64_t f_off = ret_pc;
                                    if (ret_pc > 0x4000 &&
                                        dladdr((void*)(uintptr_t)ret_pc, &di_f))
                                    {
                                        if (di_f.dli_fname) f_img = di_f.dli_fname;
                                        if (di_f.dli_sname) { f_sym = di_f.dli_sname;
                                            f_off = ret_pc - (uint64_t)(uintptr_t)di_f.dli_saddr; }
                                    }
                                    dprintf(STDERR_FILENO,
                                        "[mach_exc] bt[%d] 0x%llx %s`%s+0x%llx\n",
                                        fr, (unsigned long long)ret_pc,
                                        f_img, f_sym, (unsigned long long)f_off);
                                    if (ret_pc <= 0x4000) break;
                                }
                                fp_walk = frame_buf[0];
                            }
                        }
                        /* Stack scan ([term-stack] pattern): the exit-path
                         * crashers have no walkable fp chain, so reconstruct
                         * call history from return addresses left on the
                         * stack. Copy attribution per hit — the frame where
                         * copy_owner flips from a child peb to 0 (session)
                         * is where the thread crossed ntdll copies. */
                        if (cnt <= 3)
                        {
                            extern uint64_t ios_jit_reverse_translate( uint64_t addr, uint64_t *module_base );
                            extern void *ios_jit_pool_copy_owner(const void *addr, void **pe_base_out);
                            uint64_t sp_scan = __darwin_arm_thread_state64_get_sp(state);
                            int w2, hits = 0;
                            for (w2 = 0; w2 < 512 && hits < 24; w2++)
                            {
                                uint64_t slot_val;
                                mach_vm_size_t got_sv = 0;
                                if (mach_vm_read_overwrite(mach_task_self(),
                                        (mach_vm_address_t)(sp_scan + 8ull * w2), 8,
                                        (mach_vm_address_t)&slot_val, &got_sv)
                                        != KERN_SUCCESS || got_sv != 8)
                                    break;
                                {
                                    uint64_t mod3, va3;
                                    if ((va3 = ios_jit_reverse_translate( slot_val, &mod3 )) && va3 != slot_val)
                                    {
                                        void *cp3 = NULL;
                                        void *co3 = ios_jit_pool_copy_owner((void *)(uintptr_t)slot_val, &cp3);
                                        dprintf(STDERR_FILENO,
                                            "[exit-stk] sp+0x%x: 0x%llx = %s+0x%llx copy_owner=%p\n",
                                            w2 * 8, (unsigned long long)slot_val,
                                            ios_pe_module_name(mod3),
                                            (unsigned long long)(va3 - mod3), co3);
                                        hits++;
                                    }
                                }
                            }
                        }
                        /* One-shot: dump the faulting native function's
                         * prologue so we can see what per-thread/global
                         * state it reads (libsystem_malloc keeps dying on
                         * corrupt zone state — need its actual fastpath). */
                        static volatile int proto_dumped = 0;
                        /* ml982: a failed dladdr does NOT establish a usable
                         * dli_saddr, so require pc_named; and copy through a
                         * failure-returning read rather than dereferencing, so an
                         * address that is nameable but unreadable cannot park the
                         * exception server on its own load. Status AND length are
                         * both checked -- a short read crossing a page boundary
                         * must not be treated as success. */
                        if (pc_named && di_pc.dli_saddr && fault_pc >= 0x180000000ULL &&
                            __sync_bool_compare_and_swap(&proto_dumped, 0, 1))
                        {
                            uint32_t fp[40];
                            mach_vm_size_t got = 0;
                            if (mach_vm_read_overwrite( mach_task_self(),
                                                        (mach_vm_address_t)(uintptr_t)di_pc.dli_saddr,
                                                        sizeof(fp), (mach_vm_address_t)fp,
                                                        &got ) == KERN_SUCCESS && got == sizeof(fp))
                            {
                                int w;
                                for (w = 0; w < 40; w += 8)
                                    dprintf(STDERR_FILENO,
                                        "[mach_exc] fn+%03x: %08x %08x %08x %08x %08x %08x %08x %08x\n",
                                        w * 4, fp[w], fp[w+1], fp[w+2], fp[w+3],
                                        fp[w+4], fp[w+5], fp[w+6], fp[w+7]);
                            }
                            else
                                dprintf(STDERR_FILENO,
                                        "[mach_exc] ml982 fn prologue at %p <unreadable> (got=%llu) "
                                        "-- continuing the normal exception path\n",
                                        di_pc.dli_saddr, (unsigned long long)got);
                        }
                    }
                    /* Thing B one-shot: a zero-page pc crawl means a thread
                     * took `blr x16` with x16==1 from an EC exit thunk
                     * ($iexit_thunk$ at EC ntdll+0x73040: adrp x8,+0x51
                     * pages; ldr x16,[x8,#0x480]; blr x16). Dump (a) the
                     * ARM64X dispatch slots of every private EC ntdll copy,
                     * (b) the qword the adrp ACTUALLY dereferenced computed
                     * from the execution-address lr (catches link-vs-exec
                     * address skew in pool copies), (c) x9 — exit-thunk
                     * convention: x9 = the x64 target being called — and
                     * (d) an fp-chain backtrace with PE attribution so the
                     * call path INTO the thunk names itself. */
                    static volatile int thunk_probe_shots = 0;
                    if (fault_pc < 0x1000 && thunk_probe_shots < 3)
                    {
                        extern void ios_dump_ec_dispatch_slots( unsigned long long lr_va, unsigned long long x9 );
                        extern uint64_t ios_jit_reverse_translate( uint64_t addr, uint64_t *module_base );
                        uint64_t lr_exec = state.__lr & 0x0000007fffffffffull;
                        uint64_t lr_mod = 0, lr_va = ios_jit_reverse_translate( lr_exec, &lr_mod );
                        uint64_t fp_walk;
                        int fr;
                        __sync_add_and_fetch(&thunk_probe_shots, 1);
                        dprintf(STDERR_FILENO,
                            "[thunk-slot] WEDGE pc=0x%llx lr_exec=0x%llx lr_va=0x%llx (%.32s) "
                            "x0=0x%llx x1=0x%llx x2=0x%llx x3=0x%llx x4=0x%llx "
                            "x8=0x%llx x9=0x%llx x10=0x%llx x11=0x%llx fp=0x%llx\n",
                            (unsigned long long)fault_pc,
                            (unsigned long long)lr_exec, (unsigned long long)lr_va,
                            lr_mod ? ios_pe_module_name(lr_mod) : "?",
                            (unsigned long long)state.__x[0], (unsigned long long)state.__x[1],
                            (unsigned long long)state.__x[2], (unsigned long long)state.__x[3],
                            (unsigned long long)state.__x[4], (unsigned long long)state.__x[8],
                            (unsigned long long)state.__x[9], (unsigned long long)state.__x[10],
                            (unsigned long long)state.__x[11], (unsigned long long)state.__fp);
                        ios_dump_ec_dispatch_slots( lr_va ? lr_va : lr_exec,
                                                    state.__x[9] );
                        /* Exec-relative adrp target: adrp sits at lr-0xc;
                         * its immediate is +0x51 pages, ldr offset 0x480
                         * (fixed by the thunk's encoding — see disasm of
                         * arm64ec-windows/ntdll.dll +0x73048). */
                        {
                            uint64_t adrp_tgt = ((lr_exec - 0xc) & ~0xFFFULL) + 0x51000 + 0x480;
                            uint64_t slot_val = 0;
                            mach_vm_size_t got_sv = 0;
                            if (mach_vm_read_overwrite(mach_task_self(),
                                    (mach_vm_address_t)adrp_tgt, 8,
                                    (mach_vm_address_t)&slot_val, &got_sv) == KERN_SUCCESS && got_sv == 8)
                                dprintf(STDERR_FILENO,
                                    "[thunk-slot] exec-relative slot @0x%llx = 0x%llx\n",
                                    (unsigned long long)adrp_tgt, (unsigned long long)slot_val);
                            else
                                dprintf(STDERR_FILENO,
                                    "[thunk-slot] exec-relative slot @0x%llx UNREADABLE\n",
                                    (unsigned long long)adrp_tgt);
                        }
                        fp_walk = state.__fp;
                        for (fr = 0; fr < 16 && fp_walk; fr++)
                        {
                            uint64_t frame_buf[2];
                            mach_vm_size_t got_fw = 0;
                            uint64_t ret_pc, bt_mod, bt_va;
                            if (mach_vm_read_overwrite(mach_task_self(),
                                    (mach_vm_address_t)fp_walk, 16,
                                    (mach_vm_address_t)frame_buf, &got_fw) != KERN_SUCCESS || got_fw != 16)
                                break;
                            ret_pc = frame_buf[1] & 0x0000007fffffffffull;
                            if (ret_pc <= 0x4000) break;
                            bt_mod = 0;
                            bt_va = ios_jit_reverse_translate( ret_pc, &bt_mod );
                            if (bt_va)
                                dprintf(STDERR_FILENO,
                                    "[thunk-slot] bt[%d] 0x%llx PE %.32s+0x%llx (base=0x%llx)\n",
                                    fr, (unsigned long long)ret_pc,
                                    ios_pe_module_name(bt_mod),
                                    (unsigned long long)(bt_va - bt_mod),
                                    (unsigned long long)bt_mod);
                            else
                            {
                                Dl_info di_t;
                                const char *t_img = "?", *t_sym = "?";
                                uint64_t t_off = ret_pc;
                                if (dladdr((void*)(uintptr_t)ret_pc, &di_t))
                                {
                                    if (di_t.dli_fname) { t_img = strrchr(di_t.dli_fname, '/'); t_img = t_img ? t_img + 1 : di_t.dli_fname; }
                                    if (di_t.dli_sname) { t_sym = di_t.dli_sname; t_off = ret_pc - (uint64_t)(uintptr_t)di_t.dli_saddr; }
                                }
                                dprintf(STDERR_FILENO,
                                    "[thunk-slot] bt[%d] 0x%llx %s`%s+0x%llx\n",
                                    fr, (unsigned long long)ret_pc, t_img, t_sym,
                                    (unsigned long long)t_off);
                            }
                            fp_walk = frame_buf[0];
                        }
                    }
                    /* One-shot dump: on the first UNHANDLED exec fault, dump the
                     * JIT-pool RW alias contents around the relevant FEX CodeBuffer
                     * slots to a file. Lets us disassemble FEX-emitted ARM64 offline
                     * to verify codegen correctness independently. */
                    static volatile int dumped = 0;
                    if (cnt == 1 && __sync_bool_compare_and_swap(&dumped, 0, 1))
                        ios_dump_jit_pool( "mach UNHANDLED" );
                    /* Diagnostic: query the kernel for what VM region the fault PC lives in.
                     * Helps identify mystery regions (e.g. JIT pool guard zone, wineserver heap). */
                    if (cnt <= 3)
                    {
                        mach_vm_address_t qa = (mach_vm_address_t)fault_pc;
                        mach_vm_size_t qs = 0;
                        vm_region_basic_info_data_64_t qinfo;
                        mach_msg_type_number_t qcnt = VM_REGION_BASIC_INFO_COUNT_64;
                        mach_port_t qobj = MACH_PORT_NULL;
                        if (mach_vm_region(mach_task_self(), &qa, &qs,
                                           VM_REGION_BASIC_INFO_64,
                                           (vm_region_info_t)&qinfo, &qcnt, &qobj)
                            == KERN_SUCCESS)
                        {
                            dprintf(STDERR_FILENO,
                                "[mach_exc] vm_region: addr=0x%llx size=0x%llx prot=0x%x max_prot=0x%x inherit=%d shared=%d offset=0x%llx\n",
                                (unsigned long long)qa, (unsigned long long)qs,
                                qinfo.protection, qinfo.max_protection,
                                qinfo.inheritance, qinfo.shared,
                                (unsigned long long)qinfo.offset);
                        }
                    }

                    /* iOS-Madeira: dump x86 STATE on the first few faults. FEX rarely
                     * spills RSP/RSI/RDI etc to State.gregs[] (they live in static
                     * ARM regs x23/x25/x26 and only get spilled at SpillStaticRegs
                     * call sites — which most of __dyn_tls_init's path never hits).
                     * So the LIVE x86 register values are in state.__x[] of the
                     * faulted thread. ARM64EC SRA:
                     *   RAX=x8, RCX=x0 (pair0); RDX=x1, RBX=x27 (pair1);
                     *   RSP=x23, RBP=x29 (pair2); RSI=x25, RDI=x26 (pair3);
                     *   R8=x2, R9=x3, R10=x4, R11=x5; R12=x19, R13=x20, R14=x21, R15=x22.
                     * State pointer is reachable via TEB+0x1788 -> CPUArea+0x30.   */
                    /* Read State.RIP unconditionally so we can decide whether
                     * this fault is "interesting" (i.e., in known Thumper DXGI
                     * dispatch range 0x140079xxx-0x14007axxx). Dump full state
                     * for first 3 faults OR any interesting RIP. */
                    uintptr_t teb_out_pre = 0;
                    void *tramp_out_pre = NULL;
                    ios_lookup_thread(thread, &teb_out_pre, &tramp_out_pre);
                    void *fex_state_pre = NULL;
                    if (teb_out_pre)
                    {
                        void *cpuarea = *(void**)(teb_out_pre + 0x1788);
                        if (cpuarea) fex_state_pre = *(void**)((char*)cpuarea + 0x30);
                    }
                    uint64_t state_rip_pre = fex_state_pre ?
                        ((uint64_t*)fex_state_pre)[0x18 / 8] : 0;
                    int interesting_rip = (state_rip_pre >= 0x140079000 &&
                                           state_rip_pre <  0x14007b000) ||
                                          (state_rip_pre >= 0x1400e0000 &&
                                           state_rip_pre <  0x1400e1000);
                    if (cnt <= 3 || interesting_rip)
                    {
                        uintptr_t teb_out = teb_out_pre;
                        void *tramp_out = tramp_out_pre;
                        (void)tramp_out;
                        void *fex_state = fex_state_pre;
                        uint64_t state_rip = state_rip_pre;
                        uint64_t state_cret = fex_state ? ((uint64_t*)fex_state)[0xb0 / 8] : 0;
                        /* gs_cached is at CPUState offset 0x3e0 (after gregs,
                         * L1*, callret_sp, avx_high, xmm union, segment idxes,
                         * mxcsr, es/cs/ss/ds_cached). */
                        uint64_t state_gs = fex_state ? ((uint64_t*)fex_state)[0x3e0 / 8] : 0;
                        uint64_t teb_tls = teb_out ? *(uint64_t*)(teb_out + 0x58) : 0;
                        uint64_t gs_plus_58 = 0;
                        if (state_gs >= 0x10000 && state_gs < 0xfffffff000000000ULL)
                            gs_plus_58 = *(uint64_t*)(state_gs + 0x58);
                        dprintf(STDERR_FILENO,
                            "[x86_seg] State.gs_cached=0x%llx TEB=0x%llx TEB[0x58]=0x%llx *(gs_cached+0x58)=0x%llx\n",
                            (unsigned long long)state_gs,
                            (unsigned long long)teb_out,
                            (unsigned long long)teb_tls,
                            (unsigned long long)gs_plus_58);

                        /* LIVE x86 regs from host ARM thread state (ARM64EC SRA). */
                        uint64_t live_rax = state.__x[8];
                        uint64_t live_rcx = state.__x[0];
                        uint64_t live_rdx = state.__x[1];
                        uint64_t live_rbx = state.__x[27];
                        uint64_t live_rsp = state.__x[23];
                        /* x29 is __fp, NOT __x[29]: Darwin's __x holds only x0..x28,
                         * so the old form read one past the array. It happened to
                         * land on __fp and print the right value, but it was UB and
                         * the compiler flags it (-Warray-bounds). Same bits, legally. */
                        uint64_t live_rbp = state.__fp;
                        uint64_t live_rsi = state.__x[25];
                        uint64_t live_rdi = state.__x[26];
                        uint64_t live_r8  = state.__x[2];
                        uint64_t live_r9  = state.__x[3];
                        uint64_t live_r10 = state.__x[4];
                        uint64_t live_r11 = state.__x[5];
                        uint64_t live_r12 = state.__x[19];
                        uint64_t live_r13 = state.__x[20];
                        uint64_t live_r14 = state.__x[21];
                        uint64_t live_r15 = state.__x[22];
                        dprintf(STDERR_FILENO,
                            "[x86_live] RAX=0x%llx RCX=0x%llx RDX=0x%llx RBX=0x%llx RSP=0x%llx RBP=0x%llx RSI=0x%llx RDI=0x%llx\n"
                            "[x86_live]  R8=0x%llx  R9=0x%llx R10=0x%llx R11=0x%llx R12=0x%llx R13=0x%llx R14=0x%llx R15=0x%llx\n"
                            "[x86_live] State.RIP=0x%llx callret_sp=0x%llx\n",
                            (unsigned long long)live_rax, (unsigned long long)live_rcx,
                            (unsigned long long)live_rdx, (unsigned long long)live_rbx,
                            (unsigned long long)live_rsp, (unsigned long long)live_rbp,
                            (unsigned long long)live_rsi, (unsigned long long)live_rdi,
                            (unsigned long long)live_r8,  (unsigned long long)live_r9,
                            (unsigned long long)live_r10, (unsigned long long)live_r11,
                            (unsigned long long)live_r12, (unsigned long long)live_r13,
                            (unsigned long long)live_r14, (unsigned long long)live_r15,
                            (unsigned long long)state_rip, (unsigned long long)state_cret);

                        if (live_rsp >= 0x10000 && live_rsp < 0xfffffff000000000ULL)
                        {
                            uint64_t buf[16];
                            mach_vm_size_t got = 0;
                            kern_return_t kr = mach_vm_read_overwrite(
                                mach_task_self(),
                                (mach_vm_address_t)(live_rsp - 32),
                                sizeof(buf),
                                (mach_vm_address_t)buf, &got);
                            if (kr == KERN_SUCCESS && got >= 64)
                            {
                                dprintf(STDERR_FILENO,
                                    "[x86_stk] @RSP-32..-8: %016llx %016llx %016llx %016llx  (last = popped slot)\n",
                                    (unsigned long long)buf[0],
                                    (unsigned long long)buf[1],
                                    (unsigned long long)buf[2],
                                    (unsigned long long)buf[3]);
                                dprintf(STDERR_FILENO,
                                    "[x86_stk] @RSP+0..+24:  %016llx %016llx %016llx %016llx\n",
                                    (unsigned long long)buf[4],
                                    (unsigned long long)buf[5],
                                    (unsigned long long)buf[6],
                                    (unsigned long long)buf[7]);
                                dprintf(STDERR_FILENO,
                                    "[x86_stk] @RSP+32..+56: %016llx %016llx %016llx %016llx\n",
                                    (unsigned long long)buf[8],
                                    (unsigned long long)buf[9],
                                    (unsigned long long)buf[10],
                                    (unsigned long long)buf[11]);

                                /* ml382 CALLER HUNT for the "-1 pointer" family.
                                 *
                                 * Three runs (ml372/378/381) died identically:
                                 * fault addr 0xffffffffffe01000, insn f8bfc0da.
                                 * Decoded from the REAL chrome_elf.dll pulled off
                                 * the phone, the faulting function is
                                 * chrome_elf+0x65750 = PartitionRoot::Free(root,
                                 * ptr):
                                 *   test rdx,rdx / je end        <- handles NULL
                                 *   and r14, ~(2MB-1)            <- super-page base
                                 *   mov rdi,[r14+0x1000]         <- FAULTS
                                 * and the live regs had RDX = RSI = -1, R14 =
                                 * -1 & ~(2MB-1). So Chromium is freeing (void*)-1.
                                 * PA handles NULL but not -1, so SOMETHING handed
                                 * it -1 where NULL (or a real pointer) was due.
                                 *
                                 * The existing 12-qword window did not reach the
                                 * return address, so the caller is still unknown —
                                 * and guessing it is exactly what burned two
                                 * theories today. Dump a wide window ONLY for this
                                 * signature so the caller can be identified offline
                                 * (a stack qword whose preceding bytes decode as a
                                 * CALL is a real return address; a function START
                                 * preceded by ret+padding is just a callback
                                 * pointer, which is how 0x...9c110 was excluded). */
                                if (((uint64_t)fault_addr & 0xffffffff00000000ULL) == 0xffffffff00000000ULL)
                                {
                                    uint64_t wide[64];
                                    mach_vm_size_t wgot = 0;
                                    static int minus1_dumps;
                                    if (minus1_dumps < 2 &&
                                        mach_vm_read_overwrite( mach_task_self(),
                                            (mach_vm_address_t)live_rsp, sizeof(wide),
                                            (mach_vm_address_t)wide, &wgot ) == KERN_SUCCESS
                                        && wgot == sizeof(wide))
                                    {
                                        unsigned wi;
                                        minus1_dumps++;
                                        dprintf(STDERR_FILENO,
                                            "[minus1-stack] rev=ml382 fault=0x%llx rsp=0x%llx — 64 qwords "
                                            "(find the CALLER offline: qword whose preceding bytes are E8/FF15)\n",
                                            (unsigned long long)fault_addr,
                                            (unsigned long long)live_rsp);
                                        for (wi = 0; wi < 64; wi += 4)
                                            dprintf(STDERR_FILENO,
                                                "[minus1-stack]   +%03x: %016llx %016llx %016llx %016llx\n",
                                                wi * 8,
                                                (unsigned long long)wide[wi],
                                                (unsigned long long)wide[wi+1],
                                                (unsigned long long)wide[wi+2],
                                                (unsigned long long)wide[wi+3]);
                                    }
                                }
                            }
                            else
                            {
                                dprintf(STDERR_FILENO,
                                    "[x86_stk] vm_read RSP=0x%llx kr=%d got=%llu\n",
                                    (unsigned long long)live_rsp, kr,
                                    (unsigned long long)got);
                            }
                        }
                        else
                        {
                            dprintf(STDERR_FILENO,
                                "[x86_stk] live_rsp=0x%llx out of range — RSP not yet established\n",
                                (unsigned long long)live_rsp);
                        }

                        /* Dump [RBX..RBX+0x30] for stack-local objects: lets us
                         * see the full vector/struct state when the fault is on
                         * a `mov rax, [rcx]` chained from `mov rcx, [rbx]`. */
                        if (live_rbx >= 0x10000 && live_rbx < 0xfffffff000000000ULL)
                        {
                            uint64_t obj[7];
                            mach_vm_size_t got2 = 0;
                            kern_return_t kr2 = mach_vm_read_overwrite(
                                mach_task_self(),
                                (mach_vm_address_t)live_rbx,
                                sizeof(obj),
                                (mach_vm_address_t)obj, &got2);
                            if (kr2 == KERN_SUCCESS && got2 >= sizeof(obj))
                                dprintf(STDERR_FILENO,
                                    "[x86_obj] @RBX+0..+0x30: %016llx %016llx %016llx %016llx %016llx %016llx %016llx\n",
                                    (unsigned long long)obj[0],
                                    (unsigned long long)obj[1],
                                    (unsigned long long)obj[2],
                                    (unsigned long long)obj[3],
                                    (unsigned long long)obj[4],
                                    (unsigned long long)obj[5],
                                    (unsigned long long)obj[6]);
                        }

                        /* Also dump [RCX..RCX+0x30] — when the fault is in a
                         * helper that took (rcx=this, ...) and `this` got
                         * clobbered by intermediate moves, the original `this`
                         * lives in RBX. But RCX itself often points to a
                         * destination buffer or an object whose state we want
                         * to inspect. */
                        if (live_rcx >= 0x10000 && live_rcx < 0xfffffff000000000ULL)
                        {
                            uint64_t obj[7];
                            mach_vm_size_t got_c = 0;
                            kern_return_t kr_c = mach_vm_read_overwrite(
                                mach_task_self(),
                                (mach_vm_address_t)live_rcx,
                                sizeof(obj),
                                (mach_vm_address_t)obj, &got_c);
                            if (kr_c == KERN_SUCCESS && got_c >= sizeof(obj))
                                dprintf(STDERR_FILENO,
                                    "[x86_dst] @RCX+0..+0x30: %016llx %016llx %016llx %016llx %016llx %016llx %016llx\n",
                                    (unsigned long long)obj[0],
                                    (unsigned long long)obj[1],
                                    (unsigned long long)obj[2],
                                    (unsigned long long)obj[3],
                                    (unsigned long long)obj[4],
                                    (unsigned long long)obj[5],
                                    (unsigned long long)obj[6]);
                        }

                        /* Thumper-debug: also dump the static singleton slot
                         * at 0x140290a60+0x428. This is the "0x1400793d0
                         * caller" that the DXGI dispatch wrapper reads from.
                         * If it's the static placeholder 0x1401825a8, Thumper
                         * never initialized the real renderer wrapper at this
                         * slot. If it's something else, we need to see what. */
                        {
                            uint64_t static_slot = 0;
                            mach_vm_size_t got_ss = 0;
                            if (mach_vm_read_overwrite(mach_task_self(),
                                    (mach_vm_address_t)0x140290e88ULL, /* 0x140290a60+0x428 */
                                    sizeof(static_slot),
                                    (mach_vm_address_t)&static_slot, &got_ss)
                                == KERN_SUCCESS && got_ss == sizeof(static_slot))
                            {
                                dprintf(STDERR_FILENO,
                                    "[x86_thumper] [0x140290a60+0x428]=0x%llx",
                                    (unsigned long long)static_slot);
                                /* Walk the chain: renderer object → vtable → vtable[30] */
                                if (static_slot >= 0x10000 && static_slot < 0xfffffff000000000ULL)
                                {
                                    uint64_t vtable_ptr = 0;
                                    mach_vm_size_t got_v = 0;
                                    if (mach_vm_read_overwrite(mach_task_self(),
                                            (mach_vm_address_t)static_slot,
                                            sizeof(vtable_ptr),
                                            (mach_vm_address_t)&vtable_ptr, &got_v)
                                        == KERN_SUCCESS && got_v == sizeof(vtable_ptr))
                                    {
                                        dprintf(STDERR_FILENO, "  vtable=*[slot]=0x%llx",
                                            (unsigned long long)vtable_ptr);
                                        if (vtable_ptr >= 0x10000 && vtable_ptr < 0xfffffff000000000ULL)
                                        {
                                            /* Read full vtable slots [0..7] and [30] */
                                            uint64_t vt_entries[32];
                                            mach_vm_size_t got_ve = 0;
                                            if (mach_vm_read_overwrite(mach_task_self(),
                                                    (mach_vm_address_t)vtable_ptr,
                                                    sizeof(vt_entries),
                                                    (mach_vm_address_t)vt_entries, &got_ve)
                                                == KERN_SUCCESS && got_ve == sizeof(vt_entries))
                                            {
                                                dprintf(STDERR_FILENO,
                                                    "\n[x86_thumper]   vtable[0..3]: %016llx %016llx %016llx %016llx",
                                                    (unsigned long long)vt_entries[0],
                                                    (unsigned long long)vt_entries[1],
                                                    (unsigned long long)vt_entries[2],
                                                    (unsigned long long)vt_entries[3]);
                                                dprintf(STDERR_FILENO,
                                                    "\n[x86_thumper]   vtable[28..31] (target=[30]): %016llx %016llx ★%016llx %016llx",
                                                    (unsigned long long)vt_entries[28],
                                                    (unsigned long long)vt_entries[29],
                                                    (unsigned long long)vt_entries[30],
                                                    (unsigned long long)vt_entries[31]);
                                            }
                                        }
                                    }
                                }
                                dprintf(STDERR_FILENO, "\n");
                            }
                        }

                        /* Thumper-debug: when fault chain involves the renderer
                         * wrapper at guest RIP 0x140079390 (vtable[30] dispatch),
                         * dump the indirection chain [rcx+0x428] → [rax] → [r10+0xf0].
                         * Helps identify when [rcx+0x428] is the wrong type
                         * (vtable instead of object, etc.) per GPT diagnosis. */
                        if (live_rcx >= 0x10000 && live_rcx < 0xfffffff000000000ULL)
                        {
                            mach_vm_address_t f1_addr = (mach_vm_address_t)(live_rcx + 0x428);
                            uint64_t f1 = 0;
                            mach_vm_size_t got_f1 = 0;
                            if (mach_vm_read_overwrite(mach_task_self(), f1_addr,
                                    sizeof(f1), (mach_vm_address_t)&f1, &got_f1)
                                == KERN_SUCCESS && got_f1 == sizeof(f1))
                            {
                                dprintf(STDERR_FILENO, "[x86_dispatch] [RCX+0x428]=0x%llx",
                                    (unsigned long long)f1);
                                if (f1 >= 0x10000 && f1 < 0xfffffff000000000ULL)
                                {
                                    uint64_t f2 = 0;
                                    mach_vm_size_t got_f2 = 0;
                                    if (mach_vm_read_overwrite(mach_task_self(),
                                            (mach_vm_address_t)f1, sizeof(f2),
                                            (mach_vm_address_t)&f2, &got_f2)
                                        == KERN_SUCCESS && got_f2 == sizeof(f2))
                                    {
                                        dprintf(STDERR_FILENO, " [[+0x428]]=0x%llx",
                                            (unsigned long long)f2);
                                        if (f2 >= 0x10000 && f2 < 0xfffffff000000000ULL)
                                        {
                                            uint64_t slot30 = 0;
                                            mach_vm_size_t got_s = 0;
                                            if (mach_vm_read_overwrite(mach_task_self(),
                                                    (mach_vm_address_t)(f2 + 0xf0),
                                                    sizeof(slot30),
                                                    (mach_vm_address_t)&slot30, &got_s)
                                                == KERN_SUCCESS && got_s == sizeof(slot30))
                                            {
                                                dprintf(STDERR_FILENO,
                                                    " [+0xf0]=0x%llx (would-be vtable[30])",
                                                    (unsigned long long)slot30);
                                            }
                                        }
                                    }
                                }
                                dprintf(STDERR_FILENO, "\n");
                            }
                        }

                        /* Walk FEX's callret stack to recover the guest call chain.
                         * Each entry is 16 bytes: [0..7]=guest return RIP, [8..15]=host
                         * return PC. callret_sp points at the most-recently-pushed
                         * entry; entries grow DOWN (push pre-decrements by 0x10). */
                        if (state_cret >= 0x10000 && state_cret < 0xfffffff000000000ULL)
                        {
                            uint64_t cr[16]; /* up to 8 entries */
                            mach_vm_size_t got3 = 0;
                            kern_return_t kr3 = mach_vm_read_overwrite(
                                mach_task_self(),
                                (mach_vm_address_t)state_cret,
                                sizeof(cr),
                                (mach_vm_address_t)cr, &got3);
                            if (kr3 == KERN_SUCCESS && got3 >= sizeof(cr))
                            {
                                dprintf(STDERR_FILENO,
                                    "[x86_callret] guest call chain (most recent first):\n"
                                    "  [0] retRIP=0x%llx hostPC=0x%llx\n"
                                    "  [1] retRIP=0x%llx hostPC=0x%llx\n"
                                    "  [2] retRIP=0x%llx hostPC=0x%llx\n"
                                    "  [3] retRIP=0x%llx hostPC=0x%llx\n"
                                    "  [4] retRIP=0x%llx hostPC=0x%llx\n"
                                    "  [5] retRIP=0x%llx hostPC=0x%llx\n"
                                    "  [6] retRIP=0x%llx hostPC=0x%llx\n"
                                    "  [7] retRIP=0x%llx hostPC=0x%llx\n",
                                    (unsigned long long)cr[0],  (unsigned long long)cr[1],
                                    (unsigned long long)cr[2],  (unsigned long long)cr[3],
                                    (unsigned long long)cr[4],  (unsigned long long)cr[5],
                                    (unsigned long long)cr[6],  (unsigned long long)cr[7],
                                    (unsigned long long)cr[8],  (unsigned long long)cr[9],
                                    (unsigned long long)cr[10], (unsigned long long)cr[11],
                                    (unsigned long long)cr[12], (unsigned long long)cr[13],
                                    (unsigned long long)cr[14], (unsigned long long)cr[15]);
                            }
                        }
                    }
                }
            }
        }

        /* Build reply */
        ios_exc_reply_t reply;
        reply.head.msgh_bits = MACH_MSGH_BITS( MACH_MSGH_BITS_REMOTE(req->head.msgh_bits), 0 );
        reply.head.msgh_size = sizeof(reply);
        reply.head.msgh_remote_port = req->head.msgh_remote_port;
        reply.head.msgh_local_port = MACH_PORT_NULL;
        reply.head.msgh_id = req->head.msgh_id + 100;
        reply.ndr = NDR_record;
        reply.ret_code = handled ? KERN_SUCCESS : KERN_FAILURE;

        mach_msg( &reply.head, MACH_SEND_MSG, sizeof(reply), 0,
                  MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL );

        /* Deallocate the send rights we received */
        mach_port_deallocate( mach_task_self(), thread );
        mach_port_deallocate( mach_task_self(), req->task.name );
    }
    return NULL;
}

/* ml522 (#67): claim the TASK-level exception port for the fault masks we
 * already own per-thread.
 *
 * Until now the only registration we ever did was thread_set_exception_ports(),
 * so the TASK-level port belonged entirely to StikDebug. That is fine while the
 * debugger lives and fatal once it does not: when StikDebug goes away — jetsam
 * for its 48s-CPU-per-60s limit, or the user swiping it out of the app switcher
 * — the task port is left REGISTERED BUT UNSERVICED, and the first exception
 * that escalates past a thread port blocks the WHOLE TASK until the kernel
 * gives up on the dead name.
 *
 * That is #67. Measured at 53.9s / 53.7s / 54.2s across three unrelated runs
 * (Steam and Thumper, jetsam-kill and swipe-kill alike), and in the swipe run
 * bracketed by a single fault: [mach_exc] UNALIGNED-BACKPATCH #1 -> 53.9s of
 * whole-task silence -> #2. The cost is paid exactly ONCE — backpatches
 * #4..#200 afterwards were free — which is the signature of a one-shot dead
 * port teardown rather than per-fault work.
 *
 * Owning the task port ourselves removes the dead-name dependency outright,
 * and is also the precondition that makes a deliberate early detach safe.
 *
 * NOT claimed here: EXC_MASK_BREAKPOINT. BRK #0xf00d is the StikDebug JIT
 * protocol and must keep reaching the debugger while it is alive; after detach
 * a stray protocol BRK falls through to the BSD SIGTRAP path, which already
 * recognises it. Same reasoning as the per-thread mask (see ml353 note below).
 *
 * A fault we DECLINE at thread level now escalates to this same port and is
 * declined again, after which the kernel falls through to the host default and
 * delivers a BSD signal so wine's sigaction handlers run — the same end state
 * madeira-jit.js was hand-rolling with forwardSignal(). */
static void ios_install_task_exception_port(void)
{
    static int done = 0;
    exception_mask_t      old_masks[EXC_TYPES_COUNT];
    mach_port_t           old_ports[EXC_TYPES_COUNT];
    exception_behavior_t  old_behav[EXC_TYPES_COUNT];
    thread_state_flavor_t old_flav[EXC_TYPES_COUNT];
    mach_msg_type_number_t old_count = EXC_TYPES_COUNT, i;
    const char *gate;
    kern_return_t kr;

    if (done || ios_exc_port == MACH_PORT_NULL) return;
    done = 1;

    /* Opt-out only: this strictly removes a dependency on a port we do not own,
     * so it defaults ON. MADEIRA_TASK_EXC=0 restores the pre-ml522 behaviour for
     * a same-build A/B against the ~54s stall. */
    if ((gate = getenv( "MADEIRA_TASK_EXC" )) && gate[0] == '0')
    {
        ERR("[task-exc] DISABLED by MADEIRA_TASK_EXC=0 — task port stays with the debugger, "
            "#67's ~54s dead-port stall is expected rev=ml522\n");
        return;
    }

    /* ml523: EXC_MASK_BREAKPOINT is now claimed too. ml522 left it with the
     * debugger to keep BRK #0xf00d working, but the device log proved that was
     * the whole bug: both ~54s stalls in the 11:56/12:01 runs happened ~21s
     * after a FRESH StikDebug attach, i.e. with the debugger fully ALIVE. The
     * task is stopped waiting for a debugger that is starved by its own
     * busy-wait. FEX emits `brk #0xCAFE` inline for every suspend-interrupt
     * check, so trap traffic is continuous and unavoidable.
     * jit26_prepare_region already ran (Swift side, pre-wine) so the pool is
     * unaffected; jit26_detach()'s BRK now lands in trap_handler's 0xf00d case
     * instead of the debugger, which is harmless. */
    kr = task_swap_exception_ports( mach_task_self(),
                                    EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION |
                                    EXC_MASK_BREAKPOINT,
                                    ios_exc_port,
                                    (exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES),
                                    ARM_THREAD_STATE64,
                                    old_masks, &old_count, old_ports, old_behav, old_flav );
    if (kr != KERN_SUCCESS)
    {
        ERR("[task-exc] task_swap_exception_ports FAILED kr=%d — the ~54s dead-port stall "
            "is STILL POSSIBLE rev=ml522\n", kr);
        return;
    }

    /* Log what we displaced. A non-null previous port is the debugger's, and is
     * precisely the name that would have gone dead underneath us. Release the
     * send rights the swap handed us — we never send to them. */
    ERR("[task-exc] INSTALLED ours=0x%x mask=ba+bi+brk displaced=%u rev=ml523\n",
        ios_exc_port, (unsigned)old_count);
    for (i = 0; i < old_count; i++)
    {
        ERR("[task-exc]   prev[%u] mask=0x%x port=0x%x behavior=0x%x flavor=%d%s\n",
            (unsigned)i, (unsigned)old_masks[i], (unsigned)old_ports[i],
            (unsigned)old_behav[i], (int)old_flav[i],
            old_ports[i] == MACH_PORT_NULL ? " (none — no debugger held it)" : " (debugger)");
        if (old_ports[i] != MACH_PORT_NULL)
            mach_port_deallocate( mach_task_self(), old_ports[i] );
    }
}

/* Register a Wine "process" thread with the shared Mach exception handler.
 * First call creates the shared port and handler thread.
 * Every call registers the thread and sets its exception ports. */
static void ios_setup_mach_exception_handler( thread_t pe_thread, uintptr_t teb,
                                               void *trampoline )
{
    /* One-time initialization: create shared port and handler thread */
    if (!ios_exc_handler_started)
    {
        extern struct _KUSER_SHARED_DATA *user_shared_data;
        ios_exc_usd = (uintptr_t)user_shared_data;

        kern_return_t kr = mach_port_allocate( mach_task_self(),
                                                MACH_PORT_RIGHT_RECEIVE, &ios_exc_port );
        if (kr != KERN_SUCCESS) { ERR("mach exc port allocate: kr=%d\n", kr); return; }

        kr = mach_port_insert_right( mach_task_self(), ios_exc_port, ios_exc_port,
                                      MACH_MSG_TYPE_MAKE_SEND );
        if (kr != KERN_SUCCESS) { ERR("mach exc port insert: kr=%d\n", kr); return; }

        {
            const char *e = getenv( "MADEIRA_MACH_ALIGN_FAULT" );
            ios_mach_align_fault_enabled = !(e && e[0] == '0');
            if (!ios_mach_align_fault_enabled)
                ERR("[unaligned-atomic] Mach-path alignment classification DISABLED by "
                    "MADEIRA_MACH_ALIGN_FAULT=0: alignment faults are delivered as c0000005 there\n");
        }

        pthread_t handler;
        pthread_create( &handler, NULL, ios_mach_exception_thread,
                        (void *)(uintptr_t)ios_exc_port );
        pthread_detach( handler );

        /* Stale-pointer heal scanner (see ios_stale_va_scanner above). */
        {
            pthread_t healer;
            pthread_create( &healer, NULL, ios_stale_va_scanner, NULL );
            pthread_detach( healer );
        }

        /* ml522 (#67): take the task-level port for our masks now that the
         * receive port and handler thread exist. Done here rather than at
         * detach time so there is never a window in which a fault can reach
         * a port whose owner has already died. */
        ios_install_task_exception_port();

        ios_exc_handler_started = 1;
    }

    /* Register this thread in the registry.
     * ml384: replace an existing entry for the same port first — the kernel
     * recycles thread port names, and a stale entry earlier in the array would
     * shadow the new registration in ios_lookup_thread (first match wins). */
    int idx, reg_count = __sync_fetch_and_add(&ios_thread_count, 0);
    if (reg_count > IOS_MAX_WINE_THREADS) reg_count = IOS_MAX_WINE_THREADS;
    for (idx = 0; idx < reg_count; idx++)
        if (ios_thread_registry[idx].mach_thread == pe_thread) break;
    if (idx == reg_count)
    {
        idx = __sync_fetch_and_add(&ios_thread_count, 1);
        if (idx >= IOS_MAX_WINE_THREADS)
        {
            ERR("[thread-registry] FULL (%d slots) — thread 0x%x teb=%p NOT registered; "
                "Mach events on it will resolve to the slot-0 TEB (wrong process!)\n",
                IOS_MAX_WINE_THREADS, pe_thread, (void *)teb);
            idx = -1;
        }
    }
    if (idx >= 0)
    {
        /* ml390 (task #66): make the replace path LOUD.  If a name gets
         * recycled while its previous owner still has live guest state, this
         * overwrite silently redirects that thread's TEB resolution — and a
         * thread_set_state aimed at the new owner could land on the old one
         * (zeroed-state suspect).  old_teb!=0 && old_teb!=new_teb = the case
         * to correlate offline against [reg-miss] and fault dumps. */
        if (idx < reg_count && ios_thread_registry[idx].teb &&
            ios_thread_registry[idx].teb != teb)
            ERR( "[thread-registry] REPLACE idx=%d port=0x%x old_teb=%p new_teb=%p\n",
                 idx, pe_thread, (void *)ios_thread_registry[idx].teb, (void *)teb );
        ios_thread_registry[idx].teb = teb;
        ios_thread_registry[idx].trampoline = trampoline;
        __sync_synchronize();
        ios_thread_registry[idx].mach_thread = pe_thread;
        /* ml401 (tasks #60/#66): EVERY registry port name proved
         * MACH_SEND_INVALID_DEST when the census sampler tried to use it —
         * something deallocates the mach_thread_self() ref after we store the
         * name, leaving the registry full of dead keys ([pump-sample] blind,
         * and dead names are exactly what the kernel recycles = the #66
         * wrong-thread hazard).  Pin extra send refs so the name outlives any
         * stray deallocate; dead-name lingering after thread exit is harmless
         * and prevents recycling. */
        {
            kern_return_t krr = mach_port_mod_refs( mach_task_self(), pe_thread,
                                                    MACH_PORT_RIGHT_SEND, 4 );
            if (krr != KERN_SUCCESS)
                ERR( "[thread-registry] mod_refs(+4) port=0x%x FAILED kr=%d\n", pe_thread, krr );
        }
    }

    /* Set exception port for this thread (shared port).
     * ml353: also claim EXC_BAD_INSTRUCTION. udf-class faults (executing
     * zeroed/garbage memory) previously bypassed us entirely and went
     * straight to StikDebug's task port — the app log was BLIND to the
     * instant-vanish deaths (ml351/ml354); only a hand-captured StikDebug
     * console named the pc. With the mask widened, the UNHANDLED dump
     * (pool-ledger, owner, insn stream, backtrace) self-documents them
     * before the decline escalates. EXC_BREAKPOINT (BRK JIT protocol) is a
     * DIFFERENT mask bit and still flows to StikDebug untouched. */
    kern_return_t kr = thread_set_exception_ports( pe_thread,
                                      EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION,
                                      ios_exc_port,
                                      (exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES),
                                      ARM_THREAD_STATE64 );
    if (kr != KERN_SUCCESS) { ERR("mach exc set ports: kr=%d thread=0x%x\n", kr, pe_thread); return; }

    ERR("Mach exception handler registered thread 0x%x (idx=%d), teb=%p tramp=%p usd=%p mask=ba+bi rev=ml353\n",
        pe_thread, idx, (void*)teb, trampoline, (void*)ios_exc_usd);
}
#endif


/***********************************************************************
 *           context_init_empty_xstate
 *
 * Initializes a context's CONTEXT_EX structure to point to an empty xstate buffer
 */
static inline void context_init_empty_xstate( CONTEXT *context, void *xstate_buffer )
{
    CONTEXT_EX *xctx;

    xctx = (CONTEXT_EX *)(context + 1);
    xctx->Legacy.Length = sizeof(CONTEXT);
    xctx->Legacy.Offset = -(LONG)sizeof(CONTEXT);
    xctx->XState.Length = 0;
    xctx->XState.Offset = (BYTE *)xstate_buffer - (BYTE *)xctx;
    xctx->All.Length = sizeof(CONTEXT) + xctx->XState.Offset + xctx->XState.Length;
    xctx->All.Offset = -(LONG)sizeof(CONTEXT);
}

void set_process_instrumentation_callback( void *callback )
{
    if (callback) FIXME( "Not supported.\n" );
}


/***********************************************************************
 *           syscall_frame_fixup_for_fastpath
 *
 * Fixes up the given syscall frame such that the syscall dispatcher
 * can return via the fast path if CONTEXT_INTEGER is set in
 * restore_flags.
 *
 * Clobbers the frame's X16 and X17 register values.
 */
static void syscall_frame_fixup_for_fastpath( struct syscall_frame *frame )
{
    frame->x[16] = frame->pc;
    frame->x[17] = frame->sp;
}

/***********************************************************************
 *           save_fpu
 *
 * Set the FPU context from a sigcontext.
 */
static void save_fpu( CONTEXT *context, const ucontext_t *sigcontext )
{
#ifdef linux
    struct fpsimd_context *fp = get_fpsimd_context( sigcontext );

    if (!fp) return;
    context->ContextFlags |= CONTEXT_FLOATING_POINT;
    context->Fpcr = fp->fpcr;
    context->Fpsr = fp->fpsr;
    memcpy( context->V, fp->vregs, sizeof(context->V) );
#elif defined(__APPLE__)
    context->ContextFlags |= CONTEXT_FLOATING_POINT;
    context->Fpcr = sigcontext->uc_mcontext->__ns.__fpcr;
    context->Fpsr = sigcontext->uc_mcontext->__ns.__fpsr;
    memcpy( context->V, sigcontext->uc_mcontext->__ns.__v, sizeof(context->V) );
#endif
}


/***********************************************************************
 *           restore_fpu
 *
 * Restore the FPU context to a sigcontext.
 */
static void restore_fpu( const CONTEXT *context, ucontext_t *sigcontext )
{
#ifdef linux
    struct fpsimd_context *fp = get_fpsimd_context( sigcontext );

    if (!fp) return;
    fp->fpcr = context->Fpcr;
    fp->fpsr = context->Fpsr;
    memcpy( fp->vregs, context->V, sizeof(fp->vregs) );
#elif defined(__APPLE__)
    sigcontext->uc_mcontext->__ns.__fpcr = context->Fpcr;
    sigcontext->uc_mcontext->__ns.__fpsr = context->Fpsr;
    memcpy( sigcontext->uc_mcontext->__ns.__v, context->V, sizeof(context->V) );
#endif
}


/***********************************************************************
 *           save_context
 *
 * Set the register values from a sigcontext.
 */
static void save_context( CONTEXT *context, const ucontext_t *sigcontext )
{
    DWORD i;

    context->ContextFlags = CONTEXT_FULL;
    context->Fp   = FP_sig(sigcontext);     /* Frame pointer */
    context->Lr   = LR_sig(sigcontext);     /* Link register */
    context->Sp   = SP_sig(sigcontext);     /* Stack pointer */
    context->Pc   = PC_sig(sigcontext);     /* Program Counter */
    context->Cpsr = PSTATE_sig(sigcontext); /* Current State Register */
    for (i = 0; i <= 28; i++) context->X[i] = REGn_sig( i, sigcontext );
    save_fpu( context, sigcontext );
}


/***********************************************************************
 *           restore_context
 *
 * Build a sigcontext from the register values.
 */
static void restore_context( const CONTEXT *context, ucontext_t *sigcontext )
{
    DWORD i;

    FP_sig(sigcontext)     = context->Fp;   /* Frame pointer */
    LR_sig(sigcontext)     = context->Lr;   /* Link register */
    SP_sig(sigcontext)     = context->Sp;   /* Stack pointer */
    PC_sig(sigcontext)     = context->Pc;   /* Program Counter */
    PSTATE_sig(sigcontext) = context->Cpsr; /* Current State Register */
    for (i = 0; i <= 28; i++) REGn_sig( i, sigcontext ) = context->X[i];
    restore_fpu( context, sigcontext );
}


/***********************************************************************
 *           signal_set_full_context
 */
NTSTATUS signal_set_full_context( CONTEXT *context )
{
    extern int ios_is_arm64ec_cur(void);
    struct syscall_frame *frame = get_syscall_frame();
    ULONG_PTR ml944_req_pc = context->Pc, ml944_req_sp = context->Sp;
    DWORD ml944_req_flags = context->ContextFlags;
    NTSTATUS status = NtSetContextThread( GetCurrentThread(), context );

    if (!status && (context->ContextFlags & CONTEXT_INTEGER) == CONTEXT_INTEGER)
        frame->restore_flags |= CONTEXT_INTEGER;

    /* iOS-Madeira diag (Thumper desktop ILL): the crash pc is entered with no
     * branch/register/immediate trail = a context restore. Log every resume
     * targeting the FEX tail-carve region (top 128MB of the pool) whose
     * first word is a data-word/NOP — plus the is_ec_code verdict, since
     * non-EC resumes get bounced through KiUserEmulationDispatcher. */
    {
        extern void *ios_jit_rx_base_global;
        extern size_t ios_jit_pool_size_global;
        uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
        size_t psz = ios_jit_pool_size_global;
        if (rx && psz && frame->pc >= rx + psz / 2 && frame->pc < rx + psz)
        {
            uint32_t w = *(uint32_t *)frame->pc;
            if ((w >> 16) == 0 || w == 0xd503201fu)
                dprintf(2, "[set-ctx] SUSPICIOUS resume: pc=%p first_insn=0x%08x is_ec=%d lr=%p sp=%p (Pc from context=%p)\n",
                        (void *)frame->pc, w, is_ec_code( frame->pc ),
                        (void *)frame->lr, (void *)frame->sp, (void *)context->Pc);
        }
    }

    /* ml945: PROBE THE DECISION, NOT THE BRANCH.
     *
     * ml944 put this inside the KiUserEmulationDispatcher bounce below. The
     * bounce was taken 0 times out of 60 VEH continues, so the probe was
     * silent and the run produced nothing -- I had gated the instrument on the
     * hypothesis it was meant to test. Log the inputs to the decision instead,
     * unconditionally, so a wrong hypothesis still yields data.
     *
     * Context: an anti-tamper VEH returns EXCEPTION_CONTINUE_EXECUTION with
     * Rip = <its own dll>+0x37ce0 (a valid address) and the guest resumes with
     * RIP 0, which CompileBlock then refuses 2001 times while the VEH
     * re-enters, until the [redeliv] guard kills the pseudo-process.
     *
     * What each field settles:
     *   req_*      -- did the modified Rip survive the PE-side conversion?
     *   frame pc   -- did NtSetContextThread(self) actually apply it? If this
     *                 is native EC code rather than the requested guest Rip,
     *                 CONTEXT_CONTROL was missing or self-set does not write pc.
     *   is_ec/cur  -- which way the branch below goes, and why.
     * Capped; every resume passes here, so this must stay cheap. */
    {
        /* ml946: DEDUPE BY THE VALUE THIS IS ABOUT, not a flat shot cap.
         *
         * ml945's 24-shot budget was spent by log line 1547; the resume I need
         * is at line 5571. 22 of the 24 were the SAME req pc (0xf93d763f0 —
         * thread-start resumes on ARM64 pseudo-processes, where ec_cur=0 is
         * correct and uninteresting). A flat cap samples whatever happens
         * first, which for a hot path is never the rare event. Keyed on req pc
         * instead: each distinct resume target gets exactly one line, so a
         * thousand identical thread starts cost one slot and the VEH's
         * continue target is guaranteed a slot.
         *
         * ⛔ Do not "fix" this by raising a flat cap -- that is what failed. */
        static ULONG_PTR ml946_seen[48];
        static int ml946_n;
        int ml946_i, ml946_dup = 0;

        for (ml946_i = 0; ml946_i < ml946_n; ml946_i++)
            if (ml946_seen[ml946_i] == ml944_req_pc) { ml946_dup = 1; break; }
        if (!ml946_dup && ml946_n < (int)(sizeof(ml946_seen)/sizeof(ml946_seen[0])))
        {
            ml946_seen[ml946_n++] = ml944_req_pc;
            dprintf( 2, "[set-ctx] ml946 distinct#%d tid=%04x req pc=%p sp=%p flags=%08x status=%08x | "
                     "frame pc=%p sp=%p | is_ec(frame.pc)=%d ec_cur=%d\n",
                     ml946_n,
                     (unsigned int)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread,
                     (void *)ml944_req_pc, (void *)ml944_req_sp,
                     (unsigned int)ml944_req_flags, (unsigned int)status,
                     (void *)frame->pc, (void *)frame->sp,
                     is_ec_code( frame->pc ), ios_is_arm64ec_cur() );
        }
    }

    if (ios_is_arm64ec_cur() && !is_ec_code( frame->pc ))   /* owner-aware (X3) */
    {
        /* iOS-Madeira ml420 (#69, ml419 root cause): the EcCodeBitMap only covers
         * PE space (#52), so a resume targeting the JIT pool — FEX's
         * NtContinueNative after handling a fault host-side ("Handled unaligned
         * atomic"), with Pc = the faulting host instruction — fails is_ec_code
         * and gets bounced through KiUserEmulationDispatcher, which installs the
         * HOST pc as the guest Rip (context_arm_to_x64 maps Pc→Rip verbatim).
         * The guest then "executes" FEX's own emitted code: xquery MISS → NoExec
         * trap → c0000005 (ml419 tid 0110, rip=0x155340848). Pool addresses only
         * ever hold ARM64 code (image copies + FEX emission) — a guest x64 RIP
         * is never a pool address — so any pool-pc resume is a NATIVE resume. */
        extern void *ios_jit_rx_base_global;
        extern size_t ios_jit_pool_size_global;
        uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
        size_t psz = ios_jit_pool_size_global;

        if (rx && psz && frame->pc >= rx && frame->pc < rx + psz)
        {
            static int bounce_saved;
            if (bounce_saved < 16 && ++bounce_saved <= 16)
                ERR( "[ec-bounce-pool] native resume kept for pool pc=%p (off=0x%lx) lr=%p — "
                     "was: KiUserEmulationDispatcher bounce = guest executes host code\n",
                     (void *)frame->pc, (unsigned long)(frame->pc - rx), (void *)frame->lr );
        }
        else
        {
            CONTEXT *user_context = (CONTEXT *)((frame->sp - sizeof(CONTEXT)) & ~15);

            user_context->ContextFlags = CONTEXT_FULL;
            NtGetContextThread( GetCurrentThread(), user_context );
            /* ml944: WHERE DOES A GUEST-RIP RESUME LOSE ITS RIP?
             *
             * A VEH that returns EXCEPTION_CONTINUE_EXECUTION with a modified
             * Rip reaches here: the requested Pc is x64 guest code, so
             * is_ec_code() is correctly false and we bounce through
             * KiUserEmulationDispatcher, which reads the context from SP,
             * maps Pc->Rip and calls BeginSimulation. Measured once: an
             * anti-tamper VEH asked to continue at EMP.dll+0x37ce0 -- a valid
             * address -- and the guest resumed with RIP 0, which our
             * CompileBlock guard then refused 2001 times while the VEH
             * re-entered, until the [redeliv] guard killed the process.
             *
             * Reading the path statically did not settle it: the requested Pc
             * is written into the frame by NtSetContextThread and read back by
             * NtGetContextThread, and context_arm_to_x64 maps Pc->Rip
             * verbatim, so every hop looks correct. So measure each hop
             * instead of reasoning about it. If the Pc is still right at
             * `handoff` below, the loss is inside dispatch_emulation /
             * BeginSimulation; if it is already wrong, this names which hop.
             *
             * Gated to the bounce path and capped, so it costs a normal resume
             * nothing. */
            {
                static int ml944_shots;
                if (ml944_shots < 12)
                {
                    ml944_shots++;
                    /* ml947: the handoff Pc is CORRECT (measured, 12/12), so the
                     * RIP is lost downstream in dispatch_emulation ->
                     * context_arm_to_x64 -> pBeginSimulation. dispatch_emulation
                     * writes into get_arm64ec_cpu_area()->ContextAmd64 and then
                     * starts simulation from it, so a wrong TEB at this moment
                     * means the context lands in the wrong CPU area and
                     * simulation begins from a stale Rip -- which would be 0.
                     * This thread has repeatedly shown x18=0 and "no TEB owns
                     * sp", so check it. TEB+0x1788 = ChpeV2CpuAreaInfo,
                     * CpuArea+0x18 = ContextAmd64, +0xf8 = its Rip (the field
                     * BeginSimulation resumes from). Cross-check cpuarea
                     * against the [cpu-area] line logged for this tid. */
                    {
                        TEB *t = NtCurrentTeb();
                        void *cpuarea = t ? *(void **)((char *)t + 0x1788) : NULL;
                        void *ctx64 = cpuarea ? *(void **)((char *)cpuarea + 0x18) : NULL;
                        unsigned long long ctx64_rip = 0;
                        int ctx64_ok = 0;

                        if (ctx64)
                        {
                            mach_vm_size_t got = 0;
                            ctx64_ok = (mach_vm_read_overwrite( mach_task_self(),
                                            (mach_vm_address_t)((char *)ctx64 + 0xf8), 8,
                                            (mach_vm_address_t)&ctx64_rip, &got ) == KERN_SUCCESS
                                        && got == 8);
                        }
                        dprintf( 2, "[ec-bounce] ml947 #%d teb=%p cpuarea=%p ContextAmd64=%p "
                                 "its_Rip=%s%llx\n",
                                 ml944_shots, (void *)t, cpuarea, ctx64,
                                 ctx64_ok ? "0x" : "UNREADABLE 0x",
                                 (unsigned long long)ctx64_rip );
                    }
                    dprintf( 2, "[ec-bounce] ml944 #%d requested pc=%p sp=%p flags=%08x | "
                             "frame pc=%p sp=%p | handoff ctx=%p pc=%p sp=%p flags=%08x | is_ec=%d\n",
                             ml944_shots, (void *)ml944_req_pc, (void *)ml944_req_sp,
                             (unsigned int)ml944_req_flags,
                             (void *)frame->pc, (void *)frame->sp,
                             (void *)user_context, (void *)user_context->Pc,
                             (void *)user_context->Sp,
                             (unsigned int)user_context->ContextFlags,
                             is_ec_code( frame->pc ) );
                }
            }
            frame->sp = (ULONG_PTR)user_context;
            frame->pc = (ULONG_PTR)IOS_PFUNC(KiUserEmulationDispatcher);
        }
    }
    return status;
}


/***********************************************************************
 *              get_native_context
 */
void *get_native_context( CONTEXT *context )
{
    return context;
}


/***********************************************************************
 *              get_wow_context
 */
void *get_wow_context( CONTEXT *context )
{
    /* Owner-aware (X3): the CPU area machine follows the current thread's
     * pseudo-process, not the session's main exe. */
    extern const SECTION_IMAGE_INFORMATION *ios_cur_image_info(void);
    return get_cpu_area( ios_cur_image_info()->Machine );
}


/***********************************************************************
 *              NtSetContextThread  (NTDLL.@)
 *              ZwSetContextThread  (NTDLL.@)
 */
NTSTATUS WINAPI NtSetContextThread( HANDLE handle, const CONTEXT *context )
{
    struct syscall_frame *frame = get_syscall_frame();
    NTSTATUS ret = STATUS_SUCCESS;
    BOOL self = (handle == GetCurrentThread());
    DWORD flags = context->ContextFlags & ~CONTEXT_ARM64;

    if (self && (flags & CONTEXT_DEBUG_REGISTERS)) self = FALSE;

    /* iOS-Madeira diag: companion to [set-ctx] in signal_set_full_context —
     * catch cross-thread PC rewrites into the FEX tail carve that land on
     * data words (suspend/invalidate machinery redirecting threads). */
    if (flags & CONTEXT_CONTROL)
    {
        extern void *ios_jit_rx_base_global;
        extern size_t ios_jit_pool_size_global;
        uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
        size_t psz = ios_jit_pool_size_global;
        if (rx && psz && context->Pc >= rx + psz / 2 && context->Pc < rx + psz)
        {
            uint32_t w = *(uint32_t *)context->Pc;
            if ((w >> 16) == 0 || w == 0xd503201fu)
                dprintf(2, "[set-ctx] SUSPICIOUS NtSetContextThread: self=%d pc=%p first_insn=0x%08x lr=%p\n",
                        self, (void *)context->Pc, w, (void *)context->Lr);
        }
    }

    if (!self)
    {
        ret = set_thread_context( handle, context, &self, IMAGE_FILE_MACHINE_ARM64 );
        if (ret || !self) return ret;
    }

    if (flags & CONTEXT_INTEGER)
    {
        memcpy( frame->x, context->X, sizeof(context->X[0]) * 18 );
        /* skip x18 */
        memcpy( frame->x + 19, context->X + 19, sizeof(context->X[0]) * 10 );
    }
    if (flags & CONTEXT_CONTROL)
    {
        frame->fp    = context->Fp;
        frame->lr    = context->Lr;
        frame->sp    = context->Sp;
        frame->pc    = context->Pc;
        frame->cpsr  = context->Cpsr;
    }
    if (flags & CONTEXT_FLOATING_POINT)
    {
        frame->fpcr = context->Fpcr;
        frame->fpsr = context->Fpsr;
        memcpy( frame->v, context->V, sizeof(frame->v) );
    }
    if (flags & CONTEXT_ARM64_X18)
    {
        frame->x[18] = context->X[18];
    }
    if (flags & CONTEXT_DEBUG_REGISTERS) FIXME( "debug registers not supported\n" );
    frame->restore_flags |= flags & ~CONTEXT_INTEGER;
    return STATUS_SUCCESS;
}


/* A CROSS-THREAD CONTEXT WITHOUT ITS CONTROL REGISTERS.
 *
 * When the server has no native capture of the target it answers with the
 * integer registers only, and the ARM64EC wrapper hands an x64 caller
 * Rip = Rsp = 0 with no CONTEXT_CONTROL. Ghost of Tsushima's loading screen
 * froze on exactly that: one thread called GetThreadContext on another
 * thousands of times, getting rip 0 each time, while holding a critical
 * section the main thread waited on.
 *
 * The target's last x64 state is in its CPU area (ChpeV2CpuAreaInfo->
 * ContextAmd64, saved whenever it left emulated code). Its control registers
 * (Pc, Sp, Fp, Lr) are returned in the ARM64EC register mapping, which the
 * wrapper's context_arm_to_x64() turns back into x64 registers; X23/X28 are
 * cleared so the wrapper does not replace Pc/Sp with an emulator frame's. The
 * integer registers stay the server's. Threads of this process only: the TEB
 * pointer is read in this address space, through mach_vm_read_overwrite, so a
 * target that exits meanwhile cannot fault this thread.
 *
 * Opt-in, MADEIRA_CTX_CPU_AREA=1 (madeira.cfg env., or a game's own config):
 * the snapshot is the thread's last exit from emulated code, not where it is
 * now, so a caller that writes the context back (SetThreadContext, as a .NET
 * runtime redirecting a thread does) would move the thread back there. */
static int ctx_peek( void *dst, const void *src, size_t size )
{
    mach_vm_size_t got = 0;
    return src && mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(uintptr_t)src, size,
                                          (mach_vm_address_t)(uintptr_t)dst, &got ) == KERN_SUCCESS && got == size;
}

static int get_context_from_amd64_area( HANDLE handle, CONTEXT *context, DWORD needed )
{
    static int on = -1;
    THREAD_BASIC_INFORMATION tbi;
    const TEB *teb;
    const CHPE_V2_CPU_AREA_INFO *cpu = NULL;
    const ARM64EC_NT_CONTEXT *ecp = NULL;
    ARM64EC_NT_CONTEXT ec;
    static LONG said;

    if (on < 0)
    {
        /* 1: a cross-thread GetThreadContext without control registers gets the target's
         * saved x64 Pc/Sp/Fp/Lr (default off; a context written back would rewind it). */
        const char *env = getenv( "MADEIRA_CTX_CPU_AREA" );
        on = env && env[0] == '1';
    }
    if (!on) return 0;
    if (NtQueryInformationThread( handle, ThreadBasicInformation, &tbi, sizeof(tbi), NULL )) return 0;
    if (tbi.ClientId.UniqueProcess != NtCurrentTeb()->ClientId.UniqueProcess) return 0;
    if (!(teb = tbi.TebBaseAddress)) return 0;
    if (!ctx_peek( &cpu, &teb->ChpeV2CpuAreaInfo, sizeof(cpu) ) || !cpu) return 0;
    if (!ctx_peek( &ecp, &cpu->ContextAmd64, sizeof(ecp) ) || !ecp) return 0;
    if (!ctx_peek( &ec, ecp, sizeof(ec) )) return 0;
    if (!ec.Pc || !ec.Sp) return 0;
    context->X[23] = context->X[28] = 0;
    context->Fp = ec.Fp;
    context->Lr = ec.Lr;
    context->Sp = ec.Sp;
    context->Pc = ec.Pc;
    context->ContextFlags |= CONTEXT_CONTROL;
    if (InterlockedIncrement( &said ) <= 8)
        ERR( "[ctx] get handle=%p: no control registers from the server; "
             "returning the target's saved x64 Pc/Sp/Fp/Lr rip=%p rsp=%p (MADEIRA_CTX_CPU_AREA)\n",
             handle, (void *)ec.Pc, (void *)ec.Sp );
    return 1;
}

/***********************************************************************
 *              NtGetContextThread  (NTDLL.@)
 *              ZwGetContextThread  (NTDLL.@)
 */
NTSTATUS WINAPI NtGetContextThread( HANDLE handle, CONTEXT *context )
{
    struct syscall_frame *frame = get_syscall_frame();
    DWORD needed_flags = context->ContextFlags & ~CONTEXT_ARM64;
    BOOL self = (handle == GetCurrentThread());

    if (!self)
    {
        NTSTATUS ret = get_thread_context( handle, context, &self, IMAGE_FILE_MACHINE_ARM64 );
        if (!ret && !self && (needed_flags & CONTEXT_CONTROL & ~CONTEXT_ARM64) &&
            (!(context->ContextFlags & CONTEXT_CONTROL & ~CONTEXT_ARM64) || !context->Pc))
            get_context_from_amd64_area( handle, context, needed_flags );
        if (ret || !self) return ret;
    }

    if (needed_flags & CONTEXT_INTEGER)
    {
        memcpy( context->X, frame->x, sizeof(context->X[0]) * 29 );
        context->ContextFlags |= CONTEXT_INTEGER;
    }
    if (needed_flags & CONTEXT_CONTROL)
    {
        context->Fp   = frame->fp;
        context->Lr   = frame->lr;
        context->Sp   = frame->sp;
        context->Pc   = frame->pc;
        context->Cpsr = frame->cpsr;
        context->ContextFlags |= CONTEXT_CONTROL;
    }
    if (needed_flags & CONTEXT_FLOATING_POINT)
    {
        context->Fpcr = frame->fpcr;
        context->Fpsr = frame->fpsr;
        memcpy( context->V, frame->v, sizeof(context->V) );
        context->ContextFlags |= CONTEXT_FLOATING_POINT;
    }
    if (needed_flags & CONTEXT_DEBUG_REGISTERS) FIXME( "debug registers not supported\n" );
    set_context_exception_reporting_flags( &context->ContextFlags, CONTEXT_SERVICE_ACTIVE );
    return STATUS_SUCCESS;
}


/***********************************************************************
 *              set_thread_wow64_context
 */
NTSTATUS set_thread_wow64_context( HANDLE handle, const void *ctx, ULONG size )
{
    BOOL self = (handle == GetCurrentThread());
    USHORT machine;
    void *frame;

    switch (size)
    {
    case sizeof(I386_CONTEXT): machine = IMAGE_FILE_MACHINE_I386; break;
    case sizeof(ARM_CONTEXT): machine = IMAGE_FILE_MACHINE_ARMNT; break;
    default: return STATUS_INFO_LENGTH_MISMATCH;
    }

    if (!self)
    {
        NTSTATUS ret = set_thread_context( handle, ctx, &self, machine );
        if (ret || !self) return ret;
    }

    if (!(frame = get_cpu_area( machine ))) return STATUS_INVALID_PARAMETER;

    switch (machine)
    {
    case IMAGE_FILE_MACHINE_I386:
    {
        I386_CONTEXT *wow_frame = frame;
        const I386_CONTEXT *context = ctx;
        DWORD flags = context->ContextFlags & ~CONTEXT_i386;

        if (flags & CONTEXT_I386_INTEGER)
        {
            wow_frame->Eax = context->Eax;
            wow_frame->Ebx = context->Ebx;
            wow_frame->Ecx = context->Ecx;
            wow_frame->Edx = context->Edx;
            wow_frame->Esi = context->Esi;
            wow_frame->Edi = context->Edi;
        }
        if (flags & CONTEXT_I386_CONTROL)
        {
            WOW64_CPURESERVED *cpu = NtCurrentTeb()->TlsSlots[WOW64_TLS_CPURESERVED];

            wow_frame->Esp    = context->Esp;
            wow_frame->Ebp    = context->Ebp;
            wow_frame->Eip    = context->Eip;
            wow_frame->EFlags = context->EFlags;
            wow_frame->SegCs  = context->SegCs;
            wow_frame->SegSs  = context->SegSs;
            cpu->Flags |= WOW64_CPURESERVED_FLAG_RESET_STATE;
        }
        if (flags & CONTEXT_I386_SEGMENTS)
        {
            wow_frame->SegDs = context->SegDs;
            wow_frame->SegEs = context->SegEs;
            wow_frame->SegFs = context->SegFs;
            wow_frame->SegGs = context->SegGs;
        }
        if (flags & CONTEXT_I386_DEBUG_REGISTERS)
        {
            wow_frame->Dr0 = context->Dr0;
            wow_frame->Dr1 = context->Dr1;
            wow_frame->Dr2 = context->Dr2;
            wow_frame->Dr3 = context->Dr3;
            wow_frame->Dr6 = context->Dr6;
            wow_frame->Dr7 = context->Dr7;
        }
        if (flags & CONTEXT_I386_EXTENDED_REGISTERS)
        {
            memcpy( &wow_frame->ExtendedRegisters, context->ExtendedRegisters, sizeof(context->ExtendedRegisters) );
        }
        if (flags & CONTEXT_I386_FLOATING_POINT)
        {
            memcpy( &wow_frame->FloatSave, &context->FloatSave, sizeof(context->FloatSave) );
        }
        /* FIXME: CONTEXT_I386_XSTATE */
        break;
    }

    case IMAGE_FILE_MACHINE_ARMNT:
    {
        ARM_CONTEXT *wow_frame = frame;
        const ARM_CONTEXT *context = ctx;
        DWORD flags = context->ContextFlags & ~CONTEXT_ARM;

        if (flags & CONTEXT_INTEGER)
        {
            wow_frame->R0  = context->R0;
            wow_frame->R1  = context->R1;
            wow_frame->R2  = context->R2;
            wow_frame->R3  = context->R3;
            wow_frame->R4  = context->R4;
            wow_frame->R5  = context->R5;
            wow_frame->R6  = context->R6;
            wow_frame->R7  = context->R7;
            wow_frame->R8  = context->R8;
            wow_frame->R9  = context->R9;
            wow_frame->R10 = context->R10;
            wow_frame->R11 = context->R11;
            wow_frame->R12 = context->R12;
        }
        if (flags & CONTEXT_CONTROL)
        {
            wow_frame->Sp = context->Sp;
            wow_frame->Lr = context->Lr;
            wow_frame->Pc = context->Pc & ~1;
            wow_frame->Cpsr = context->Cpsr;
            if (context->Cpsr & 0x20) wow_frame->Pc |= 1; /* thumb */
        }
        if (flags & CONTEXT_FLOATING_POINT)
        {
            wow_frame->Fpscr = context->Fpscr;
            memcpy( wow_frame->D, context->D, sizeof(context->D) );
        }
        break;
    }

    }
    return STATUS_SUCCESS;
}


/***********************************************************************
 *              get_thread_wow64_context
 */
NTSTATUS get_thread_wow64_context( HANDLE handle, void *ctx, ULONG size )
{
    BOOL self = (handle == GetCurrentThread());
    USHORT machine;
    void *frame;

    switch (size)
    {
    case sizeof(I386_CONTEXT): machine = IMAGE_FILE_MACHINE_I386; break;
    case sizeof(ARM_CONTEXT): machine = IMAGE_FILE_MACHINE_ARMNT; break;
    default: return STATUS_INFO_LENGTH_MISMATCH;
    }

    if (!self)
    {
        NTSTATUS ret = get_thread_context( handle, ctx, &self, machine );
        if (ret || !self) return ret;
    }

    if (!(frame = get_cpu_area( machine ))) return STATUS_INVALID_PARAMETER;

    switch (machine)
    {
    case IMAGE_FILE_MACHINE_I386:
    {
        I386_CONTEXT *wow_frame = frame, *context = ctx;
        DWORD needed_flags = context->ContextFlags & ~CONTEXT_i386;

        if (needed_flags & CONTEXT_I386_INTEGER)
        {
            context->Eax = wow_frame->Eax;
            context->Ebx = wow_frame->Ebx;
            context->Ecx = wow_frame->Ecx;
            context->Edx = wow_frame->Edx;
            context->Esi = wow_frame->Esi;
            context->Edi = wow_frame->Edi;
            context->ContextFlags |= CONTEXT_I386_INTEGER;
        }
        if (needed_flags & CONTEXT_I386_CONTROL)
        {
            context->Esp    = wow_frame->Esp;
            context->Ebp    = wow_frame->Ebp;
            context->Eip    = wow_frame->Eip;
            context->EFlags = wow_frame->EFlags;
            context->SegCs  = wow_frame->SegCs;
            context->SegSs  = wow_frame->SegSs;
            context->ContextFlags |= CONTEXT_I386_CONTROL;
        }
        if (needed_flags & CONTEXT_I386_SEGMENTS)
        {
            context->SegDs = wow_frame->SegDs;
            context->SegEs = wow_frame->SegEs;
            context->SegFs = wow_frame->SegFs;
            context->SegGs = wow_frame->SegGs;
            context->ContextFlags |= CONTEXT_I386_SEGMENTS;
        }
        if (needed_flags & CONTEXT_I386_EXTENDED_REGISTERS)
        {
            memcpy( context->ExtendedRegisters, &wow_frame->ExtendedRegisters, sizeof(context->ExtendedRegisters) );
            context->ContextFlags |= CONTEXT_I386_EXTENDED_REGISTERS;
        }
        if (needed_flags & CONTEXT_I386_FLOATING_POINT)
        {
            memcpy( &context->FloatSave, &wow_frame->FloatSave, sizeof(context->FloatSave) );
            context->ContextFlags |= CONTEXT_I386_FLOATING_POINT;
        }
        if (needed_flags & CONTEXT_I386_DEBUG_REGISTERS)
        {
            context->Dr0 = wow_frame->Dr0;
            context->Dr1 = wow_frame->Dr1;
            context->Dr2 = wow_frame->Dr2;
            context->Dr3 = wow_frame->Dr3;
            context->Dr6 = wow_frame->Dr6;
            context->Dr7 = wow_frame->Dr7;
        }
        /* FIXME: CONTEXT_I386_XSTATE */
        set_context_exception_reporting_flags( &context->ContextFlags, CONTEXT_SERVICE_ACTIVE );
        break;
    }

    case IMAGE_FILE_MACHINE_ARMNT:
    {
        ARM_CONTEXT *wow_frame = frame, *context = ctx;
        DWORD needed_flags = context->ContextFlags & ~CONTEXT_ARM;

        if (needed_flags & CONTEXT_INTEGER)
        {
            context->R0  = wow_frame->R0;
            context->R1  = wow_frame->R1;
            context->R2  = wow_frame->R2;
            context->R3  = wow_frame->R3;
            context->R4  = wow_frame->R4;
            context->R5  = wow_frame->R5;
            context->R6  = wow_frame->R6;
            context->R7  = wow_frame->R7;
            context->R8  = wow_frame->R8;
            context->R9  = wow_frame->R9;
            context->R10 = wow_frame->R10;
            context->R11 = wow_frame->R11;
            context->R12 = wow_frame->R12;
            context->ContextFlags |= CONTEXT_INTEGER;
        }
        if (needed_flags & CONTEXT_CONTROL)
        {
            context->Sp   = wow_frame->Sp;
            context->Lr   = wow_frame->Lr;
            context->Pc   = wow_frame->Pc;
            context->Cpsr = wow_frame->Cpsr;
            context->ContextFlags |= CONTEXT_CONTROL;
        }
        if (needed_flags & CONTEXT_FLOATING_POINT)
        {
            context->Fpscr = wow_frame->Fpscr;
            memcpy( context->D, wow_frame->D, sizeof(wow_frame->D) );
            context->ContextFlags |= CONTEXT_FLOATING_POINT;
        }
        set_context_exception_reporting_flags( &context->ContextFlags, CONTEXT_SERVICE_ACTIVE );
        break;
    }

    }
    return STATUS_SUCCESS;
}


#ifdef WINE_IOS
static inline void ios_fixup_x18_for_return( ucontext_t *context );
#endif

/***********************************************************************
 *           setup_raise_exception
 */
/* task #24 probe: Thumper's settings page dies via its own ExitProcess(-1)
 * with the actual failure invisible (handled guest exception / C++ throw /
 * OutputDebugString we never see). Log every exception dispatched to the
 * guest: code+address+params. DBG_PRINTEXCEPTION carries the game's own
 * debug string — print it. 0xE06D7363 = MSVC C++ throw. */
static void ios_log_guest_exception( const char *via, const EXCEPTION_RECORD *rec, ULONG64 pc )
{
    static volatile int exc_logged = 0;
    int n = __sync_add_and_fetch(&exc_logged, 1);
    if (n > 80) return;
    dprintf(2, "[exc-disp] %s tid=%04x code=%08x flags=%x addr=%p pc=%llx nparams=%u p0=%llx p1=%llx\n",
            via, (unsigned int)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread,
            (unsigned int)rec->ExceptionCode, (unsigned int)rec->ExceptionFlags,
            rec->ExceptionAddress, (unsigned long long)pc, (unsigned int)rec->NumberParameters,
            rec->NumberParameters > 0 ? (unsigned long long)rec->ExceptionInformation[0] : 0,
            rec->NumberParameters > 1 ? (unsigned long long)rec->ExceptionInformation[1] : 0);
    if (rec->ExceptionCode == 0x40010006 && rec->NumberParameters >= 2 &&
        rec->ExceptionInformation[1])   /* DBG_PRINTEXCEPTION_C: [0]=len [1]=char* */
        dprintf(2, "[exc-disp]   OutputDebugStringA: \"%.*s\"\n",
                (int)(rec->ExceptionInformation[0] > 512 ? 512 : rec->ExceptionInformation[0]),
                (const char *)rec->ExceptionInformation[1]);
    if (rec->ExceptionCode == 0x4001000a && rec->NumberParameters >= 2 &&
        rec->ExceptionInformation[1])   /* DBG_PRINTEXCEPTION_WIDE_C */
    {
        const WCHAR *ws = (const WCHAR *)rec->ExceptionInformation[1];
        char buf[256];
        int i;
        for (i = 0; i < 255 && ws[i]; i++) buf[i] = (ws[i] < 128) ? (char)ws[i] : '?';
        buf[i] = 0;
        dprintf(2, "[exc-disp]   OutputDebugStringW: \"%s\"\n", buf);
    }
}

static void setup_raise_exception( ucontext_t *sigcontext, EXCEPTION_RECORD *rec, CONTEXT *context )
{
    struct exc_stack_layout *stack;
    void *stack_ptr = (void *)(SP_sig(sigcontext) & ~15);
    NTSTATUS status;

    ios_log_guest_exception( "raise", rec, context->Pc );
    ios_note_guest_delivery( (uint64_t)pthread_mach_thread_np( pthread_self() ) );   /* restarts [fault-stuck] */

    status = send_debug_event( rec, context, TRUE, TRUE );
    if (status == DBG_CONTINUE || status == DBG_EXCEPTION_HANDLED)
    {
        restore_context( context, sigcontext );
#ifdef WINE_IOS
        ios_fixup_x18_for_return( sigcontext );
#endif
        return;
    }

    /* fix up instruction pointer in context for EXCEPTION_BREAKPOINT */
    if (rec->ExceptionCode == EXCEPTION_BREAKPOINT) context->Pc -= 4;

    stack = virtual_setup_exception( stack_ptr, sizeof(*stack), rec );
    stack->rec = *rec;
    stack->context = *context;
    context_init_empty_xstate( &stack->context, stack->redzone );

    SP_sig(sigcontext) = (ULONG_PTR)stack;
    PC_sig(sigcontext) = (ULONG_PTR)IOS_PFUNC(KiUserExceptionDispatcher);
    REGn_sig(18, sigcontext) = (ULONG_PTR)NtCurrentTeb();
#ifdef WINE_IOS
    /* iOS sigreturn zeroes x18 — route through trampoline */
    ios_fixup_x18_for_return( sigcontext );
#endif
}


/***********************************************************************
 *           setup_exception
 *
 * Modify the signal context to call the exception raise function.
 */
static void setup_exception( ucontext_t *sigcontext, EXCEPTION_RECORD *rec )
{
    CONTEXT context;

    rec->ExceptionAddress = (void *)PC_sig(sigcontext);
#ifdef WINE_IOS
    /* task#34 guest-exception-DISPATCH: when the faulting pc is inside a
     * JIT-pool IMAGE COPY, the guest-visible record must carry the PE VA —
     * handlers compare ExceptionAddress against module bounds and the SEH
     * machinery resolves unwind info by module. (pcs inside FEX-emitted
     * code translate to nothing here and are left alone — reconstructing
     * the guest RIP for those is ResetToConsistentState's job on the PE
     * side.) The resume context keeps the real host pc. */
    {
        extern uint64_t ios_jit_reverse_translate( uint64_t addr, uint64_t *module_base );
        uint64_t pe = ios_jit_reverse_translate( (uint64_t)PC_sig(sigcontext), NULL );
        if (pe)
        {
            rec->ExceptionAddress = (void *)(uintptr_t)pe;
            { static unsigned long pe_storm; if (ios_sig_storm_gate( &pe_storm ))
            ERR( "setup_exception: pool pc %p -> PE ExceptionAddress %p\n",
                 (void *)PC_sig(sigcontext), rec->ExceptionAddress ); }
        }
    }
#endif
    save_context( &context, sigcontext );
    setup_raise_exception( sigcontext, rec, &context );
}


#ifdef WINE_IOS
/***********************************************************************
 *           ios_mach_deliver_guest_exception  (ml369, #63)
 *
 * In-process guest exception delivery from the Mach exception-server
 * thread. ml364-368 contain ZERO segv/ill/bus handler invocations: with
 * StikDebug attached, a fault this handler declines (KERN_FAILURE) goes to
 * the task port; the script's continue marks the exception HANDLED
 * kernel-side and its C<signo> is not honored (the stub cannot inject
 * signals), so BSD conversion never happens — the instruction re-executes
 * unmoved until the script kills the whole app at 8 identical stops. That
 * is the entire "LDAPR undeliverable" family (ml362/366/367/368).
 *
 * So deliver here instead: run wine's fault service + dispatch-frame setup
 * against the FAULTING thread (kept suspended by the exception message),
 * write the new sp/pc/x18 back via the caller's thread_set_state, and reply
 * KERN_SUCCESS. thread_set_state restores x18 directly — no sigreturn
 * zeroing on this path, so no trampoline needed.
 *
 * Returns 0 = cannot deliver (caller declines exactly as before),
 *         1 = state rewritten to enter KiUserExceptionDispatcher,
 *         2 = fault serviced by page machinery (guard/watch): plain retry.
 */
/* Defined further down next to bus_handler (the signal path's user); forward
 * declared here because the Mach path must run the SAME emulator — see the
 * [unaligned-atomic] block below for why the two paths may not disagree. */
static int ios_emulate_unaligned_guest_access(ucontext_t *ctx, uint32_t insn, uintptr_t addr);

static int ios_mach_deliver_guest_exception_inner( thread_t thread, arm_thread_state64_t *state,
                                                   arm_neon_state64_t *neon, int have_neon,
                                                   int exception, uintptr_t fault_addr,
                                                   uintptr_t thread_teb )
{
    extern void *ios_jit_rx_base_global;
    extern size_t ios_jit_pool_size_global;
    extern NTSTATUS ios_virtual_handle_fault_for_thread( EXCEPTION_RECORD *rec, TEB *teb );
    extern void *ios_virtual_setup_exception_for_thread( void *stack_ptr, size_t size,
                                                         EXCEPTION_RECORD *rec, TEB *teb );
    extern const struct ios_ntdll_funcs *ios_ntdll_funcs_for_peb( void *peb_id );
    extern uint64_t ios_jit_reverse_translate( uint64_t addr, uint64_t *module_base );

    uint64_t pc = arm_thread_state64_get_pc( *state );
    uintptr_t rxb = (uintptr_t)ios_jit_rx_base_global;
    TEB *teb = NULL;
    void *dispatcher;
    EXCEPTION_RECORD rec = { 0 };
    struct exc_stack_layout frame;
    void *frame_addr;
    ucontext_t uc;
    struct __darwin_mcontext64 mc;
    static int deliver_logs;
    /* 2026-09-19: set when the ESR says this data abort is an ALIGNMENT fault
     * (DFSC 0b100001). Such a fault is serviceable — it is neither an access
     * violation nor a transient — so it skips wine's page machinery, the
     * transient-retry debounce and the redelivery terminal below. */
    int is_align = 0;

    /* Pick the faulting thread's TEB by STACK CONTAINMENT, not by
     * self-consistency alone.
     *
     * ml372: both candidates self-verified and pointed at teb
     * 0x73fffd0000, whose stack is [0x731E7C8000,0x731E8C0000) — but the
     * faulting sp was 0x73da05fba0, in a completely different region. The
     * frame was therefore written outside that TEB's stack, and wine's
     * own dispatcher rejected it downstream:
     *   call_seh_handlers invalid frame 73da060000 (731E7C8000-731E8C0000)
     *   NtRaiseException Exception frame is not in stack limits
     * => NtTerminateProcess(c0000005). A TEB that merely EXISTS is not
     * this thread's TEB; Tib.Self proves the struct is a TEB, nothing
     * more. The sp must lie in (DeallocationStack, Tib.StackBase], the
     * same test is_inside_thread_stack applies, or the exception cannot
     * be dispatched no matter how correct the frame is.
     *
     * All reads go through mach_vm_read_overwrite so a bad candidate
     * cannot fault this thread (it has no handler of its own). */
    {
        uint64_t cand[2] = { state->__x[18], (uint64_t)thread_teb };
        uint64_t sp = arm_thread_state64_get_sp( *state );
        int i;

        for (i = 0; i < 2; i++)
        {
            uint64_t self = 0, base = 0, dealloc = 0;
            mach_vm_size_t got = 0;

            if (cand[i] < 0x10000 || (cand[i] & 0xfff)) continue;
            if (mach_vm_read_overwrite( mach_task_self(),
                    (mach_vm_address_t)(cand[i] + 0x30), 8,
                    (mach_vm_address_t)&self, &got ) != KERN_SUCCESS
                || got != 8 || self != cand[i])
                continue;
            if (mach_vm_read_overwrite( mach_task_self(),
                    (mach_vm_address_t)(cand[i] + 0x08), 8,
                    (mach_vm_address_t)&base, &got ) != KERN_SUCCESS || got != 8)
                continue;
            if (mach_vm_read_overwrite( mach_task_self(),
                    (mach_vm_address_t)(cand[i] + 0x1478), 8,
                    (mach_vm_address_t)&dealloc, &got ) != KERN_SUCCESS || got != 8)
                continue;
            if (sp > dealloc && sp <= base)
            {
                teb = (TEB *)(uintptr_t)cand[i];
                break;
            }
            if (deliver_logs < 24)
                dprintf( 2, "[mach-deliver] rev=ml372 teb cand%d=0x%llx stack=(0x%llx,0x%llx] does NOT contain sp=0x%llx\n",
                         i, (unsigned long long)cand[i], (unsigned long long)dealloc,
                         (unsigned long long)base, (unsigned long long)sp );
        }
        if (!teb)
        {
            /* ml540: NATIVE (non-guest) THREAD -> DECLINE, before best-effort.
             *
             * ml539 was the first run of a guest exe that EXITS. After Wine's
             * clean teardown the SwiftUI UI thread faulted inside ICU
             * (ContentView.timeString -> udat_open -> SimpleDateFormat::
             * initialize -> _platform_strcmp) on a pointer into the dead Wine
             * thread's stack. Nothing to do with the guest — but the TASK-level
             * port we claimed for #67 routes it here anyway, and the ml378 path
             * below then pushed a guest exception frame onto a NATIVE stack.
             * One native crash became a 50-deep fault loop (footprint climbed
             * 1271->1800MB) that [fault-stuck] had to break with abort_thread.
             *
             * ml378's reason for never declining is also gone: it declined into
             * an ATTACHED StikDebug, which could not turn the fault into a
             * signal and re-stopped until the script killed the app at 8 stops.
             * We now detach early (#67), so a decline is KERN_FAILURE -> the
             * kernel's default handler -> an honest iOS crash report naming the
             * real faulting frame, which is strictly better than a fabricated
             * guest delivery that cannot work.
             *
             * All three conditions are required, so a genuine guest thread whose
             * stack we merely failed to attribute still gets best-effort:
             *   - not in the thread registry (exact match, no slot-0 fallback)
             *   - x18 == 0 (carries no guest TEB)
             *   - pc is inside a Mach-O image and OUTSIDE the JIT pool, i.e.
             *     host/system code (guest code runs from the pool, and PE
             *     modules are not Mach-O images so dladdr cannot name them) */
            {
                int in_pool = rxb && pc >= rxb && pc < rxb + ios_jit_pool_size_global;
                Dl_info dli;

                if (!ios_thread_is_registered( thread ) && state->__x[18] == 0 && !in_pool
                    && dladdr( (const void *)(uintptr_t)pc, &dli ) != 0)
                {
                    static int native_declines;
                    if (native_declines < 16)
                    {
                        native_declines++;
                        dprintf( 2, "[mach-deliver] rev=ml540 NATIVE-THREAD DECLINE pc=0x%llx (%s`%s) "
                                    "sp=0x%llx addr=0x%llx -> kernel default handler\n",
                                 (unsigned long long)pc,
                                 dli.dli_fname ? dli.dli_fname : "?",
                                 dli.dli_sname ? dli.dli_sname : "?",
                                 (unsigned long long)sp, (unsigned long long)fault_addr );
                        /* ml1054: WHO called it. A native crash in objc_retain names the
                         * victim, never the culprit; the frame chain does. Read through
                         * mach_vm_read_overwrite so a bad fp cannot fault this thread. */
                        if (native_declines <= 3)
                        {
                            uint64_t fp = state->__fp, pair[2]; int f;
                            dprintf( 2, "[native-bt] ml1054 x0=%llx x1=%llx x8=%llx x16=%llx x17=%llx lr=%llx\n",
                                     (unsigned long long)state->__x[0], (unsigned long long)state->__x[1],
                                     (unsigned long long)state->__x[8], (unsigned long long)state->__x[16],
                                     (unsigned long long)state->__x[17], (unsigned long long)state->__lr );
                            {
                                Dl_info li;
                                uint64_t a = state->__lr & 0x0000007fffffffffULL;
                                if (dladdr( (const void *)(uintptr_t)a, &li ))
                                    dprintf( 2, "[native-bt] ml1054   lr  %llx %s`%s+0x%llx\n", (unsigned long long)a,
                                             li.dli_fname ? strrchr( li.dli_fname, '/' ) ? strrchr( li.dli_fname, '/' ) + 1 : li.dli_fname : "?",
                                             li.dli_sname ? li.dli_sname : "?",
                                             (unsigned long long)(a - (uint64_t)(uintptr_t)li.dli_saddr) );
                            }
                            for (f = 0; f < 24 && fp > 0x10000; f++)
                            {
                                mach_vm_size_t got = 0; Dl_info fi; uint64_t ra;
                                if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)fp, 16,
                                                            (mach_vm_address_t)pair, &got ) != KERN_SUCCESS || got != 16) break;
                                ra = pair[1] & 0x0000007fffffffffULL;   /* strip PAC */
                                if (!ra) break;
                                if (dladdr( (const void *)(uintptr_t)ra, &fi ))
                                    dprintf( 2, "[native-bt] ml1054   #%d %llx %s`%s+0x%llx\n", f, (unsigned long long)ra,
                                             fi.dli_fname ? strrchr( fi.dli_fname, '/' ) ? strrchr( fi.dli_fname, '/' ) + 1 : fi.dli_fname : "?",
                                             fi.dli_sname ? fi.dli_sname : "?",
                                             (unsigned long long)(ra - (uint64_t)(uintptr_t)fi.dli_saddr) );
                                else
                                    dprintf( 2, "[native-bt] ml1054   #%d %llx (no image)\n", f, (unsigned long long)ra );
                                if (pair[0] <= fp) break;
                                fp = pair[0];
                            }
                            {   /* ml1155: did WE free the object this thread is touching? (winemetal records
                                 * every release that dropped the last reference) */
                                extern const char *madeira_wmt_released_class( uintptr_t addr, uint64_t *ago ) __attribute__((weak_import));
                                int r;
                                if (madeira_wmt_released_class)
                                    for (r = 0; r < 2; r++)
                                    {
                                        uint64_t v = r ? state->__x[8] : state->__x[0], ago = 0;
                                        const char *cls = madeira_wmt_released_class( (uintptr_t)v, &ago );
                                        if (cls) dprintf( 2, "[native-bt] ml1155 x%d=%llx was FREED by our NSObject_release: class %s, %llu releases ago\n",
                                                          r ? 8 : 0, (unsigned long long)v, cls, (unsigned long long)ago );
                                        else dprintf( 2, "[native-bt] ml1155 x%d=%llx is not among the last 16384 objects our NSObject_release freed\n",
                                                      r ? 8 : 0, (unsigned long long)v );
                                    }
                            }
                        }
                    }
                    return 0;
                }
            }

            /* ml378: BEST-EFFORT DELIVERY instead of declining.
             *
             * ml372 declined here because a frame outside the TEB's stack made
             * call_seh_handlers reject it and NtRaiseException kill the process.
             * But declining is not the safe option it looked like: while
             * StikDebug is attached the declined fault cannot be converted to a
             * BSD signal at all, so it repeats until the script kills the WHOLE
             * app after 8 stops — which is exactly how ml378 died
             * (`DECLINE pc=0x14f5e36cc … no TEB owns this stack`, 8 repeats).
             *
             * The reason for declining is also gone: the ml377 ntdll fix makes a
             * first-step bad frame an ordinary UNHANDLED exception rather than
             * EXCEPTION_STACK_INVALID + immediate terminate. So delivering on the
             * guest's own stack now degrades to "the guest sees an unhandled
             * exception" (its filter runs, its pseudo-process dies) instead of
             * taking everything down.
             *
             * Use any SELF-CONSISTENT TEB (Tib.Self check already done above);
             * virtual_setup_exception's "outside thread stack" branch handles the
             * frame placement and verifies writability. */
            uint64_t cand2[2] = { state->__x[18], (uint64_t)thread_teb };
            int j;
            for (j = 0; j < 2 && !teb; j++)
            {
                uint64_t self = 0;
                mach_vm_size_t got = 0;
                if (cand2[j] < 0x10000 || (cand2[j] & 0xfff)) continue;
                if (mach_vm_read_overwrite( mach_task_self(),
                        (mach_vm_address_t)(cand2[j] + 0x30), 8,
                        (mach_vm_address_t)&self, &got ) == KERN_SUCCESS
                    && got == 8 && self == cand2[j])
                    teb = (TEB *)(uintptr_t)cand2[j];
            }
            if (deliver_logs < 24)
            {
                deliver_logs++;
                dprintf( 2, "[mach-deliver] rev=ml378 no TEB owns sp=0x%llx (pc=0x%llx x18=0x%llx "
                            "registry=0x%llx) -> %s\n",
                         (unsigned long long)sp, (unsigned long long)pc,
                         (unsigned long long)state->__x[18], (unsigned long long)thread_teb,
                         teb ? "BEST-EFFORT delivery on guest stack" : "DECLINE (no usable TEB at all)" );
            }
            if (!teb) return 0;
        }
        thread_teb = (uintptr_t)teb;
    }

    /* iOS-Madeira ml413 (#60/#66): xtajit64 stamps TEB->Instrumentation[8]
     * (+0x16f8) with the mutex address while a thread holds a FEX shared lock
     * (CodeInvalidationMutex read hold during CompileCode). Redirecting such a
     * thread to KiUserExceptionDispatcher abandons the compile without
     * unwinding — the read hold leaks and every later writer/reader parks
     * forever (the ml413 wedge: word=0x40010001). Log-only for now: prove or
     * refute this path before changing delivery behavior. */
    {
        static int deliver_hold_logs;
        uint64_t held_lock = 0;
        if (thread_teb)
            held_lock = *(volatile uint64_t *)((char *)(uintptr_t)thread_teb + 0x16f8);
        if (held_lock && deliver_hold_logs < 16)
        {
            deliver_hold_logs++;
            dprintf( 2, "[deliver-hold] teb=0x%llx tid=%04x HOLDS FEX shared lock @0x%llx at guest redirect "
                        "(pc=0x%llx addr=0x%llx) — this delivery leaks the read hold\n",
                     (unsigned long long)thread_teb,
                     *(volatile unsigned int *)((char *)(uintptr_t)thread_teb + 0x48),
                     (unsigned long long)held_lock,
                     (unsigned long long)pc, (unsigned long long)fault_addr );
        }
    }

    /* fabricate a ucontext over the fetched thread state so the existing
     * conversion helpers (save_context, sig macros) apply unchanged */
    memset( &uc, 0, sizeof(uc) );
    memset( &mc, 0, sizeof(mc) );
    mc.__ss = *state;
    if (have_neon) mc.__ns = *neon;
    {
        arm_exception_state64_t es;
        mach_msg_type_number_t ecount = ARM_EXCEPTION_STATE64_COUNT;
        if (thread_get_state( thread, ARM_EXCEPTION_STATE64,
                              (thread_state_t)&es, &ecount ) == KERN_SUCCESS)
            mc.__es = es;
        else
            mc.__es.__far = fault_addr;
    }
    uc.uc_mcontext = &mc;

    if (exception == EXC_BAD_INSTRUCTION)
        rec.ExceptionCode = EXCEPTION_ILLEGAL_INSTRUCTION;
    else
    {
        uint32_t esr = (uint32_t)mc.__es.__esr, esr_ec = esr >> 26;
        NTSTATUS st;
        rec.ExceptionCode = EXCEPTION_ACCESS_VIOLATION;
        rec.NumberParameters = 2;
        if (esr_ec == 0x20 || esr_ec == 0x21) rec.ExceptionInformation[0] = EXCEPTION_EXECUTE_FAULT;
        else if (esr & 0x40) rec.ExceptionInformation[0] = EXCEPTION_WRITE_FAULT;
        else rec.ExceptionInformation[0] = EXCEPTION_READ_FAULT;
        rec.ExceptionInformation[1] = fault_addr;

        /* iOS-Madeira 2026-09-19 [unaligned-atomic]: AN ALIGNMENT FAULT IS NOT
         * AN ACCESS VIOLATION, ON EITHER DELIVERY PATH.
         *
         * A 32-bit title froze after its D3D9 device came up with 13 parked
         * waiters behind one guest critical section. The trigger was a JIT'd
         * x86 `xchg [mem],reg` — host `swpal w26,w4,[x24]` (0xb8fa8304) at
         * pool pc 0x138181c94 on guest address ...e32e, i.e. 2 mod 4. x86
         * permits unaligned atomics; ARM64 LSE atomics fault, and FEX exists
         * to fix exactly that. The log shows the two paths DISAGREEING about
         * the same fault, four lines apart:
         *
         *   bus_handler  -> esr=0x92000021 -> 80000002 -> FEX: "Handled
         *                   unaligned atomic: new pc: 138181C98"   (correct)
         *   this handler -> c0000005 READ 0x710553e32e -> FEX: "Reconstructing
         *                   context ... eip: 2E3733C0"             (fatal)
         *
         * FEX only emulates unaligned LSE atomics, it never back-patches them
         * (HandleAtomicMemOp returns 4 = skip, no code rewrite), so a guest
         * spin-acquire re-faults at the SAME host pc on every iteration. Under
         * the transient-retry debounce below the 1st and 2nd faults declined to
         * the BSD signal path and were fixed, and the 3rd was dispatched from
         * here as a bogus access violation — which is not raised at any guest
         * instruction that can handle it, so the thread unwound out of the
         * locked region and every later waiter parked forever.
         *
         * The ESR already says which it is and nothing else has to be guessed:
         * EC 0x24/0x25 is a data abort and DFSC (ISS[5:0]) 0b100001 is
         * "Alignment fault" — the same bits `bus_handler` reads. Plain
         * loads/stores are emulated in place here exactly as the signal path
         * does; anything else (LSE atomics, CAS/CASP, exclusives, LDAPR/STLR)
         * is dispatched as STATUS_DATATYPE_MISALIGNMENT so FEX's unaligned
         * machinery gets the same shot it gets from bus_handler.
         *
         * Safe on this thread: the emulator touches only GPRs of the fabricated
         * context (it refuses SIMD) and copies bytes through pointers in the
         * one shared Mach task, and it uses no wine log macros — both required
         * of anything running on the exception-server thread.
         *
         * MADEIRA_MACH_ALIGN_FAULT=0 restores the old classification (every
         * data abort here is c0000005) for a same-build A/B; it is read once
         * when the exception server starts, never from this thread. */
        is_align = ios_mach_align_fault_enabled &&
                   (esr_ec == 0x24 || esr_ec == 0x25) && (esr & 0x3F) == 0x21;
        if (is_align)
        {
            uint32_t a_insn = 0;
            mach_vm_size_t got = 0;
            static unsigned long ua_emu, ua_fex;

            if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)pc,
                                        sizeof(a_insn), (mach_vm_address_t)&a_insn,
                                        &got ) == KERN_SUCCESS && got == sizeof(a_insn) &&
                ios_emulate_unaligned_guest_access( &uc, a_insn, fault_addr ))
            {
                PC_sig(&uc) += 4;
                *state = mc.__ss;
                if (++ua_emu <= 16 || (ua_emu % 4096) == 0)
                    dprintf( 2, "[unaligned-atomic] mach-path pc=0x%llx insn=0x%08x addr=0x%llx "
                                "handled by emulation (plain ld/st) emu=%lu to-fex=%lu rev=2026-09-19\n",
                             (unsigned long long)pc, a_insn, (unsigned long long)fault_addr,
                             ua_emu, ua_fex );
                return 1;
            }

            rec.ExceptionCode = EXCEPTION_DATATYPE_MISALIGNMENT;
            rec.NumberParameters = 0;
            if (++ua_fex <= 32 || (ua_fex % 4096) == 0)
                dprintf( 2, "[unaligned-atomic] mach-path pc=0x%llx insn=0x%08x addr=0x%llx "
                            "handed to FEX as 80000002 (was c0000005 before 2026-09-19) "
                            "emu=%lu to-fex=%lu\n",
                         (unsigned long long)pc, a_insn, (unsigned long long)fault_addr,
                         ua_emu, ua_fex );
        }

        /* iOS-Madeira ml613 [av-detail]: THE THREE-WAY DISCRIMINATOR.
         *
         * ml612's fatal AV printed only ExceptionAddress, so read-vs-execute and
         * the actual faulting DATA address were both invisible — and a FEX
         * miscompile, a corrupted reconstructed register and a genuine Chromium
         * heap bug all produce an identical line. Everything needed is already
         * computed above; it just was not logged.
         *
         * ⚠️ These readings NARROW, they do not convict:
         *   p0=EXECUTE, p1==host pc      -> the JIT-carve lifecycle/protection
         *                                   path (tail recycling is the leading
         *                                   member of that family, not the only one)
         *   p0=READ, p1==RCX+8, wild RCX -> the guest really was dereferencing
         *                                   RCX; the wild value could still come
         *                                   from FEX, CEF, or a third writer
         *   p0=READ, p1!=RCX+8           -> suspect the context RECONSTRUCTION
         *                                   itself before blaming either side
         *
         * Original (pre-reconstruction) exception info is logged here; RCX/R8 are
         * read from the FEX guest state as it stands now. All memory reads go
         * through mach_vm_read_overwrite, and the carve lookup is TRYLOCK-only —
         * never block on ios_tail_carve_lock from a fault handler. */
        {
            static unsigned long av_n;
            unsigned long n = is_align ? 0 : ++av_n;   /* alignment faults are not AVs — see above */
            if (n && (n <= 24 || (n % 4096) == 0))
            {
                uint64_t hpc = (uint64_t)arm_thread_state64_get_pc( mc.__ss );
                unsigned int hinsn = 0;
                uint64_t rcx = 0, r8 = 0, rcx8 = 0;
                int have_regs = 0, rcx8_ok = 0;
                unsigned cidx = 0; unsigned long long cbase = 0, csize = 0; int cfree = 0, crc;
                mach_vm_size_t g = 0;

                mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)hpc,
                                        sizeof(hinsn), (mach_vm_address_t)&hinsn, &g );
                {
                    TEB *t = NtCurrentTeb();
                    CHPE_V2_CPU_AREA_INFO *ca = t ? t->ChpeV2CpuAreaInfo : NULL;
                    void *fx = ca ? *(void **)((char *)ca + 0x30) : NULL;
                    if (fx)
                    {
                        const uint64_t *gr = &((const uint64_t *)fx)[0x20 / 8];
                        rcx = gr[1];   /* RAX,RCX,RDX,RBX,RSP,RBP,RSI,RDI,R8.. */
                        r8  = gr[8];
                        have_regs = 1;
                        rcx8_ok = (mach_vm_read_overwrite( mach_task_self(),
                                       (mach_vm_address_t)(rcx + 8), sizeof(rcx8),
                                       (mach_vm_address_t)&rcx8, &g ) == KERN_SUCCESS);
                    }
                }
                crc = ios_tail_carve_lookup_trylock( hpc, &cidx, &cbase, &csize, &cfree );

                dprintf( 2, "[av-detail] ml613 #%lu p0=%s p1=0x%llx hostpc=0x%llx hinsn=0x%08x "
                            "rcx=0x%llx r8=0x%llx [rcx+8]=%s0x%llx p1_is_rcx8=%d | carve=%s",
                         n,
                         rec.ExceptionInformation[0] == EXCEPTION_EXECUTE_FAULT ? "EXECUTE" :
                         rec.ExceptionInformation[0] == EXCEPTION_WRITE_FAULT   ? "WRITE" : "READ",
                         (unsigned long long)fault_addr, (unsigned long long)hpc, hinsn,
                         (unsigned long long)rcx, (unsigned long long)r8,
                         rcx8_ok ? "" : "<unreadable>", (unsigned long long)rcx8,
                         (have_regs && fault_addr == rcx + 8) ? 1 : 0,
                         crc < 0 ? "lock-busy" : (crc == 0 ? "none" : "") );
                if (crc > 0)
                    dprintf( 2, "idx=%u base=0x%llx size=0x%llx state=%s p1_in_carve=%d",
                             cidx, cbase, csize, cfree ? "FREE(recycled!)" : "live",
                             (fault_addr >= cbase && fault_addr < cbase + csize) ? 1 : 0 );
                dprintf( 2, " regs=%d rev=ml613\n", have_regs );

                /* iOS-Madeira ml619 [tree-caller]: NAME THE CORRUPTED CONTAINER.
                 *
                 * ml616/ml618 both died inside libc++'s recursive tree deleter for
                 * fextl::set<uint64_t> (libarm64ecfex+0x12fa0 and +0x12c10 — two
                 * instantiations of the same shape), following a corrupted left-child
                 * pointer. The registers cannot say WHICH set: the helper is shared,
                 * and Decoder::DecodeInstructionsAtEntry alone manipulates five
                 * (VisitedBlocks, BlocksToDecode, CurrentBlockTargets,
                 * BlockInfo.EntryPoints, BlockInfo.CodePages).
                 *
                 * The stack does say. Every recursive frame is exactly 32 bytes with
                 * the saved LR at frame+0x18, and every recursive frame stores the SAME
                 * LR (the instruction after the recursive `bl`). Walk up while it
                 * repeats; the FIRST DIFFERENT LR is the original callsite, which names
                 * the container.
                 *
                 * Self-calibrating and RVA-free: the gate is simply "the saved LR in two
                 * consecutive 32-byte frames is identical and non-zero", which no
                 * ordinary frame satisfies. Nothing is hardcoded, so it keeps working
                 * when FEX is rebuilt and the deleter moves. */
                {
                    uint64_t hsp = (uint64_t)arm_thread_state64_get_sp( mc.__ss );
                    uint64_t lr0 = 0, lr1 = 0;
                    mach_vm_size_t rg = 0;
                    int ok0 = mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(hsp + 0x18),
                                                      sizeof(lr0), (mach_vm_address_t)&lr0, &rg ) == KERN_SUCCESS;
                    int ok1 = mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(hsp + 0x38),
                                                      sizeof(lr1), (mach_vm_address_t)&lr1, &rg ) == KERN_SUCCESS;
                    if (ok0 && ok1 && lr0 && lr0 == lr1)
                    {
                        uint64_t f = hsp, caller = 0, prev_f = 0;
                        unsigned depth = 0;
                        for (; depth < 65536; depth++, f += 0x20)
                        {
                            uint64_t lr = 0;
                            if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(f + 0x18),
                                                        sizeof(lr), (mach_vm_address_t)&lr, &rg ) != KERN_SUCCESS)
                                break;
                            if (lr != lr0) { caller = lr; prev_f = f; break; }
                        }
                        dprintf( 2, "[tree-caller] ml619 recursive 32B frames: recursive_lr=0x%llx depth=%u "
                                    "ORIGINAL CALLER=%s0x%llx frame=0x%llx node=0x%llx sp=0x%llx%s\n",
                                 (unsigned long long)lr0, depth,
                                 caller ? "" : "<not reached> ", (unsigned long long)caller,
                                 (unsigned long long)prev_f, (unsigned long long)rcx,
                                 (unsigned long long)hsp,
                                 (depth >= 65536) ? "  (hit 65536-frame cap — caller NOT found, not absent)" : "" );
                    }
                }
            }
        }

        /* wine's page machinery gets first shot, on the FIRST occurrence —
         * the ml369 run showed the 0x712bXX..ed5c faults are guest-STACK
         * pages (guest rsp just below the address, one fault each across 4
         * sibling threads), exactly what virtual_handle_fault services; in
         * the Mach-only regime it had never run at all. Guard growth /
         * write-watch clears resume with no guest exception;
         * GUARD_PAGE_VIOLATION / STACK_OVERFLOW must be dispatched
         * immediately (wine semantics — state is consistent, no repeat
         * gating). */
        /* An alignment fault has no page to service, and this helper ENDS with
         * `rec->ExceptionCode = ret` — letting it run would overwrite the
         * 80000002 chosen above with c0000005 again. It still has to pass the
         * guest-pc gate below, so no `goto dispatch` here. */
        if (!is_align)
        {
            st = ios_virtual_handle_fault_for_thread( &rec, teb );
            if (!st)
            {
                if (deliver_logs < 24)
                {
                    deliver_logs++;
                    dprintf( 2, "[mach-deliver] rev=ml369 page-serviced pc=0x%llx addr=0x%llx (guard/watch), retrying\n",
                             (unsigned long long)pc, (unsigned long long)fault_addr );
                }
                return 2;
            }
            if (st != STATUS_ACCESS_VIOLATION) goto dispatch;
        }
    }

    /* only claim faults in plausibly GUEST-side execution:
     *   - the JIT pool (translated guest + FEX-emitted + pool-copied code),
     *   - pc < 4GB: nothing legitimate executes there (pool base is
     *     >= 0x119000000, dyld cache >= 0x180000000) — covers the pc=0
     *     zeroed-EC-dispatch family that killed the ml369 run,
     *   - the guest VA band (PE VAs / guest pointers as branch targets).
     * Host dylib and unix-side pcs keep the old decline path —
     * dispatching a guest exception on those contexts would be wrong. */
    if (!((rxb && pc >= rxb && pc < rxb + ios_jit_pool_size_global) ||
          pc < 0x100000000ULL ||
          (pc >= 0x7000000000ULL && pc < 0x7400000000ULL)))
        return 0;

    /* transient-retry absorption: races with concurrent mprotect / FEX
     * invalidation are fixed by re-execution and were free retries under
     * the decline regime. Dispatch only on the 3rd identical
     * (thread,pc,addr) fault — still well before the script's 8-stop kill.
     * Single server thread services all messages: no atomics needed. */
    if (!is_align)
    {
        static struct { uint64_t key; uint32_t n; } rep[16];
        uint64_t key = ((uint64_t)thread << 48) ^ pc ^ ((uint64_t)fault_addr << 1);
        int slot = (int)((key >> 4) & 15);
        if (rep[slot].key != key) { rep[slot].key = key; rep[slot].n = 1; return 0; }
        if (++rep[slot].n < 3) return 0;
    }

dispatch:
    /* resolve the dispatcher for the TARGET's pseudo-process (this thread
     * has no pseudo-process identity, so IOS_PFUNC would always fall back
     * to the session ntdll) */
    {
        void *peb_id = *(void **)(thread_teb + 0x60);
        const struct ios_ntdll_funcs *f = ios_ntdll_funcs_for_peb( peb_id );
        dispatcher = f ? f->KiUserExceptionDispatcher : (void *)pKiUserExceptionDispatcher;
    }
    if (!dispatcher) return 0;

    rec.ExceptionAddress = (void *)(uintptr_t)pc;
    {
        uint64_t pe = ios_jit_reverse_translate( pc, NULL );
        if (pe) rec.ExceptionAddress = (void *)(uintptr_t)pe;
    }

    frame_addr = ios_virtual_setup_exception_for_thread(
        (void *)(SP_sig(&uc) & ~15), sizeof(frame), &rec, teb );
    if (!frame_addr)
    {
        if (deliver_logs < 24)
        {
            deliver_logs++;
            dprintf( 2, "[mach-deliver] rev=ml369 CANNOT deliver pc=0x%llx addr=0x%llx sp=0x%llx (frame unwritable)\n",
                     (unsigned long long)pc, (unsigned long long)fault_addr,
                     (unsigned long long)SP_sig(&uc) );
        }
        return 0;
    }

    /* build the dispatch frame locally, then place it with mach_vm_write —
     * a raw store through a bad target sp would fault THIS thread, which
     * has no handler of its own and would wedge the whole app.
     * context_init_empty_xstate stores struct-relative offsets only, so
     * computing it in the local copy is exact. */
    memset( &frame, 0, sizeof(frame) );
    save_context( &frame.context, &uc );
    frame.rec = rec;
    context_init_empty_xstate( &frame.context, frame.redzone );

    if (mach_vm_write( mach_task_self(), (mach_vm_address_t)(uintptr_t)frame_addr,
                       (vm_offset_t)(uintptr_t)&frame, sizeof(frame) ) != KERN_SUCCESS)
    {
        if (deliver_logs < 24)
        {
            deliver_logs++;
            dprintf( 2, "[mach-deliver] rev=ml369 mach_vm_write FAILED frame=%p pc=0x%llx\n",
                     frame_addr, (unsigned long long)pc );
        }
        return 0;
    }

    SP_sig(&uc) = (ULONG_PTR)frame_addr;
    PC_sig(&uc) = (ULONG_PTR)dispatcher;
    REGn_sig(18, &uc) = thread_teb;

    *state = mc.__ss;
    ios_note_guest_delivery( (uint64_t)thread );   /* restarts [fault-stuck] */

    if (deliver_logs < 24 || (deliver_logs % 100) == 0)
        dprintf( 2, "[mach-deliver] rev=ml369 #%d code=%08x pc=0x%llx excaddr=%p addr=0x%llx frame=%p teb=%p disp=%p\n",
                 deliver_logs, (unsigned int)rec.ExceptionCode,
                 (unsigned long long)pc, rec.ExceptionAddress,
                 (unsigned long long)fault_addr, frame_addr, (void *)thread_teb, dispatcher );
    deliver_logs++;

    /* iOS-Madeira ml461 (#76): identical-fault redelivery TERMINAL. A host-C++
     * fault misdelivered down the guest SEH path can never be handled — the
     * guest restores the context and refaults, forever. ml452 stormed 65k×,
     * ml459 70k×, ml460 326,500× (rpmalloc free-list bucket holding x86 code
     * bytes; the wedged thread was the chrome-ipc pump and the run died of
     * log/CPU burn instead of saying anything). No legitimate guest pattern
     * redelivers the SAME (thread,pc,addr) thousands of times — handled
     * retries (redirects, USD, unaligned) never reach this point. This sits
     * at delivery-complete so every route counts, including the goto-dispatch
     * one that bypasses the rep[] debounce above. Single server thread: no
     * atomics needed. At the threshold: dump raw memory near the faulting
     * thread's pointer registers (the ml460 corruption lived at [x10+x9*8]
     * and register dumps were capped away long before the storm settled),
     * then terminate honestly. */
    /* 2026-09-19: EXEMPT ALIGNMENT FAULTS. The premise of this terminal is "no
     * legitimate guest pattern redelivers the SAME (thread,pc,addr) thousands
     * of times" — and the comment above already lists "unaligned" among the
     * handled retries that "never reach this point". That was true only while
     * this path mislabelled them c0000005; now that 80000002 is delivered from
     * here, an unaligned atomic in a guest spin-acquire legitimately redelivers
     * once per loop iteration (FEX emulates, it cannot back-patch an LSE
     * atomic), and counting those would kill the pseudo-process for making
     * progress. */
    if (!is_align)
    {
        /* Count CONSECUTIVE identical deliveries per thread, not lifetime hits
         * of a (thread,pc,addr) key. Slots used to be chosen by the key itself,
         * so a fault that recurs once per frame with real progress in between
         * kept its count for as long as no other key landed in its slot. Dark
         * Souls Remastered's Settings menu re-writes Arxan-guarded .text every
         * frame; each write is a self-modifying-code fault FEX handles, the
         * game keeps running, yet 7 keys cycling once per frame reached 2000 in
         * ~35 s and this guard killed a healthy game. A real storm refaults the
         * same instruction back to back on one thread, so the slot is chosen by
         * thread and any other fault on that thread restarts the run. */
        static struct { uint64_t thread, key; uint32_t n; } redeliv[16];
        static volatile int ios_redeliv_terminating;
        uint64_t rkey = ((uint64_t)thread << 48) ^ pc ^ ((uint64_t)fault_addr << 1);
        int rslot = (int)(((uint64_t)thread * 0x9E3779B97F4A7C15ull) >> 60);
        if (redeliv[rslot].thread != (uint64_t)thread || redeliv[rslot].key != rkey)
        {
            redeliv[rslot].thread = (uint64_t)thread;
            redeliv[rslot].key = rkey;
            redeliv[rslot].n = 1;
        }
        else if (++redeliv[rslot].n == 256)
            dprintf( 2, "[redeliv] 256 identical redeliveries pc=0x%llx addr=0x%llx — storm forming rev=ml461\n",
                     (unsigned long long)pc, (unsigned long long)fault_addr );
        else if (redeliv[rslot].n >= 2000 && !ios_redeliv_terminating)
        {
            /* ml463: was `== 2000` + exit(76) — one shot, and exit() on iOS is
             * the wine_ios_exit shim which LONGJMPS instead of terminating (the
             * ml462 run sailed straight past its own death sentence and kept
             * storming with a fexlock held, 11 threads parked behind it).
             *
             * ml465: `>=` without a latch was worse — EVERY delivery past 2000
             * re-dumped the forensics, and the ml464 run wrote 4 MILLION lines
             * (22k dumps) because the kill did not stop delivery instantly.
             * Latch it: dump exactly once, then kill and keep killing. Mach
             * task_terminate first (unshimmable), then the raw _exit syscall,
             * then park this thread forever so it can never deliver again —
             * whichever lands first, no second dump is possible. */
            ios_redeliv_terminating = 1;
            static const int fregs[] = { 0, 8, 9, 10, 16, 19, 20 };
            unsigned fi;
            dprintf( 2, "[redeliv] 2000 identical redeliveries pc=0x%llx addr=0x%llx — unrecoverable host fault misdelivered to guest rev=ml461\n",
                     (unsigned long long)pc, (unsigned long long)fault_addr );
            for (fi = 0; fi < sizeof(fregs) / sizeof(fregs[0]); fi++)
            {
                uint64_t rv = state->__x[fregs[fi]];
                uint64_t words[8];
                mach_vm_size_t got = 0;
                if (rv < 0x1000 || rv >= 0x800000000000ull) continue;
                if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(rv & ~7ull), 64,
                                            (mach_vm_address_t)(uintptr_t)words, &got ) != KERN_SUCCESS || got != 64)
                {
                    dprintf( 2, "[redeliv-mem] x%d=0x%llx: <unmapped>\n", fregs[fi], (unsigned long long)rv );
                    continue;
                }
                dprintf( 2, "[redeliv-mem] x%d=0x%llx: %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx\n",
                         fregs[fi], (unsigned long long)rv,
                         (unsigned long long)words[0], (unsigned long long)words[1],
                         (unsigned long long)words[2], (unsigned long long)words[3],
                         (unsigned long long)words[4], (unsigned long long)words[5],
                         (unsigned long long)words[6], (unsigned long long)words[7] );
            }
            dprintf( 2, "[redeliv] terminating process rev=ml465\n" );
            task_terminate( mach_task_self() );
            _exit( 76 );
            for (;;) pause();
        }
    }

    /* iOS-Madeira ml422 (#70): a webhelper thread died STATUS_STACK_OVERFLOW
     * right after the first CreateBrowser (ml421). Name the dying thread's
     * stack RESERVE so the verdict is direct: a Windows-sized (512KB/1MB)
     * stack overflowing = EC native-frame inflation → the ml422 4MB floor is
     * the fix; a 4MB stack STILL overflowing = pathological unbounded
     * recursion → chase the recursion instead. TEB Tib: StackBase +0x8,
     * StackLimit +0x10, DeallocationStack +0x1478. */
    if (rec.ExceptionCode == 0xC00000FD && thread_teb > 0x10000)
    {
        static int ovf_logs;
        if (ovf_logs < 8 && ++ovf_logs <= 8)
        {
            unsigned long long sb = *(unsigned long long *)(thread_teb + 0x8);
            unsigned long long sl = *(unsigned long long *)(thread_teb + 0x10);
            unsigned long long da = *(unsigned long long *)(thread_teb + 0x1478);
            dprintf( 2, "[stack-ovf] rev=ml424 teb=%p StackBase=0x%llx StackLimit=0x%llx "
                     "DeallocationStack=0x%llx reserve=0x%llx (floor now 0x800000)\n",
                     (void *)thread_teb, sb, sl, da, sb - da );

            /* ml424 (#70 round 2): a 4MB stack STILL overflowed and the SEH
             * unwinder's pcs went mid-instruction after ~4k frames (walking a
             * garbage chain), so the unwind cannot name the consumer. Sample
             * the RAW stack at three depths instead — real frames litter
             * return addresses, and a recursion cycle repeats at every depth.
             * Windows: just above the fault (freshest), mid-stack, and just
             * below StackBase (the recursion's entry). mach reads only. */
            if (sb > da && sb - da <= 0x4000000 && fault_addr > da && fault_addr < sb)
            {
                extern unsigned long long ios_jit_module_base_for_va(unsigned long long va, unsigned long long *size_out);
                static uint64_t ovf_buf[512];
                unsigned long long lo = (fault_addr + 0x3fffULL) & ~0x3fffULL;
                int w;
                for (w = 0; w < 3; w++)
                {
                    unsigned long long wbase = (w == 0) ? lo
                                             : (w == 1) ? lo + (sb - lo) / 2
                                             : sb - sizeof(ovf_buf);
                    mach_vm_size_t got = 0;
                    int wi, nw, whits = 0;
                    /* ml425 cycle-density: the ml424 fingerprint proved a repeating
                     * cycle but capped at 8 prints — COUNT every distinct code-like
                     * value across the whole window so frames-per-cycle is measured,
                     * not guessed (the logged cef cascade was only ~45 lines and
                     * cannot explain 8MB; the counts arbitrate). */
                    uint64_t uq[24]; int uqn[24]; int nuq = 0, total_code = 0;
                    if (wbase < lo) wbase = lo;
                    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)wbase,
                            sizeof(ovf_buf), (mach_vm_address_t)(uintptr_t)ovf_buf, &got ) != KERN_SUCCESS)
                        continue;
                    nw = (int)(got / 8);
                    for (wi = 0; wi < nw; wi++)
                    {
                        uint64_t v = ovf_buf[wi];
                        unsigned long long msz = 0;
                        unsigned long long mbase = ios_jit_module_base_for_va( v, &msz );
                        const unsigned char *mb;
                        const char *mname = "?";
                        unsigned int e_lf, exp_rva, name_rva;
                        int k;
                        if (!mbase) continue;
                        total_code++;
                        for (k = 0; k < nuq; k++) if (uq[k] == v) { uqn[k]++; break; }
                        if (k == nuq && nuq < 24) { uq[nuq] = v; uqn[nuq] = 1; nuq++; }
                        if (whits >= 8) continue;
                        mb = (const unsigned char *)(uintptr_t)mbase;
                        if (mb[0] == 'M' && mb[1] == 'Z' &&
                            (e_lf = *(const unsigned int *)(mb + 0x3c)) < 0x1000 &&
                            (exp_rva = *(const unsigned int *)(mb + e_lf + 0x88)) &&
                            exp_rva < msz &&
                            (name_rva = *(const unsigned int *)(mb + exp_rva + 0x0c)) &&
                            name_rva < msz)
                            mname = (const char *)(mb + name_rva);
                        else if (mb[0] == 'M' && mb[1] == 'Z')
                            mname = "(exe)";
                        dprintf( 2, "[stack-ovf]   w%d +%03x: %llx  %.32s+0x%llx\n",
                                 w, wi * 8, (unsigned long long)v, mname,
                                 (unsigned long long)(v - mbase) );
                        whits++;
                    }
                    dprintf( 2, "[stack-ovf]   w%d base=0x%llx scanned=%d code-like=%d distinct=%d\n",
                             w, wbase, nw, total_code, nuq );
                    {
                        int k;
                        for (k = 0; k < nuq; k++)
                            if (uqn[k] >= 4)
                                dprintf( 2, "[stack-ovf]   w%d density: %llx x%d\n",
                                         w, (unsigned long long)uq[k], uqn[k] );
                    }
                }
            }
        }
    }
    return 1;
}

/* ml374: the Mach exception-server thread has NO wine TEB, so every wine log
 * macro reachable from the delivery path dies inside __wine_dbg_output. Two
 * runs were lost to exactly that — ml370 (my WARN in the cross-thread fault
 * handler) and ml374 (mprotect_exec's unconditional ERR, reached via
 * mprotect_range while servicing a guard page) — and both presented as an
 * unexplained crash at a host pc with NO log lines, because the thread that
 * does the logging is the thread that died.
 *
 * Raising ios_in_mach_exc across the whole call lets shared helpers that
 * legitimately log on normal threads stay silent here, without every one of
 * them needing its own iOS special case. Wrapper rather than inline flag
 * management so no early return can leak the flag set — that would silence
 * wine's logging process-wide and destroy the next run's diagnostics. */
static int ios_mach_deliver_guest_exception( thread_t thread, arm_thread_state64_t *state,
                                             arm_neon_state64_t *neon, int have_neon,
                                             int exception, uintptr_t fault_addr,
                                             uintptr_t thread_teb )
{
    extern volatile int ios_in_mach_exc;
    int r;

    ios_in_mach_exc = 1;
    r = ios_mach_deliver_guest_exception_inner( thread, state, neon, have_neon,
                                                exception, fault_addr, thread_teb );
    ios_in_mach_exc = 0;
    return r;
}
#endif  /* WINE_IOS */


/***********************************************************************
 *           call_user_apc_dispatcher
 */
NTSTATUS call_user_apc_dispatcher( CONTEXT *context, unsigned int flags, ULONG_PTR arg1, ULONG_PTR arg2, ULONG_PTR arg3,
                                   PNTAPCFUNC func, NTSTATUS status )
{
    struct syscall_frame *frame = get_syscall_frame();
    ULONG64 sp = context ? context->Sp : frame->sp;
    struct apc_stack_layout *stack;

    if (flags) FIXME( "flags %#x are not supported.\n", flags );

    sp &= ~15;
    stack = (struct apc_stack_layout *)sp - 1;
    if (context)
    {
        memmove( &stack->context, context, sizeof(stack->context) );
        NtSetContextThread( GetCurrentThread(), &stack->context );
    }
    else
    {
        stack->context.ContextFlags = CONTEXT_FULL;
        NtGetContextThread( GetCurrentThread(), &stack->context );
        stack->context.X0 = status;
    }
    stack->func      = func;
    stack->args[0]   = arg1;
    stack->args[1]   = arg2;
    stack->args[2]   = arg3;
    stack->alertable = TRUE;

    frame->sp = (ULONG64)stack;
    frame->pc = (ULONG64)IOS_PFUNC(KiUserApcDispatcher);
    frame->restore_flags |= CONTEXT_CONTROL;
    syscall_frame_fixup_for_fastpath( frame );
    return status;
}


/***********************************************************************
 *           call_raise_user_exception_dispatcher
 */
void call_raise_user_exception_dispatcher(void)
{
    get_syscall_frame()->pc = (UINT64)pKiRaiseUserExceptionDispatcher;
}


/***********************************************************************
 *           call_user_exception_dispatcher
 */
NTSTATUS call_user_exception_dispatcher( EXCEPTION_RECORD *rec, CONTEXT *context )
{
    struct syscall_frame *frame = get_syscall_frame();
    struct exc_stack_layout *stack;
    NTSTATUS status;

    ios_log_guest_exception( "dispatch", rec, context->Pc );

    status = NtSetContextThread( GetCurrentThread(), context );

    if (status) return status;
    stack = (struct exc_stack_layout *)(context->Sp & ~15) - 1;
    memmove( &stack->context, context, sizeof(*context) );
    memmove( &stack->rec, rec, sizeof(*rec) );
    context_init_empty_xstate( &stack->context, stack->redzone );

    frame->pc = (ULONG64)IOS_PFUNC(KiUserExceptionDispatcher);
    frame->sp = (ULONG64)stack;
    frame->restore_flags |= CONTEXT_CONTROL;
    syscall_frame_fixup_for_fastpath( frame );
    return status;
}


/***********************************************************************
 *           call_user_mode_callback
 */
extern NTSTATUS call_user_mode_callback( ULONG64 user_sp, void **ret_ptr, ULONG *ret_len,
                                         void *func, TEB *teb );
__ASM_GLOBAL_FUNC( call_user_mode_callback,
                   "stp x29, x30, [sp,#-0xd0]!\n\t"
                   __ASM_CFI(".cfi_def_cfa_offset 0xd0\n\t")
                   __ASM_CFI(".cfi_offset 29,-0xd0\n\t")
                   __ASM_CFI(".cfi_offset 30,-0xc8\n\t")
                   "mov x29, sp\n\t"
                   __ASM_CFI(".cfi_def_cfa_register 29\n\t")
                   "stp x19, x20, [x29, #0x10]\n\t"
                   __ASM_CFI(".cfi_rel_offset 19,0x10\n\t")
                   __ASM_CFI(".cfi_rel_offset 20,0x18\n\t")
                   "stp x21, x22, [x29, #0x20]\n\t"
                   __ASM_CFI(".cfi_rel_offset 21,0x20\n\t")
                   __ASM_CFI(".cfi_rel_offset 22,0x28\n\t")
                   "stp x23, x24, [x29, #0x30]\n\t"
                   __ASM_CFI(".cfi_rel_offset 23,0x30\n\t")
                   __ASM_CFI(".cfi_rel_offset 24,0x38\n\t")
                   "stp x25, x26, [x29, #0x40]\n\t"
                   __ASM_CFI(".cfi_rel_offset 25,0x40\n\t")
                   __ASM_CFI(".cfi_rel_offset 26,0x48\n\t")
                   "stp x27, x28, [x29, #0x50]\n\t"
                   __ASM_CFI(".cfi_rel_offset 27,0x50\n\t")
                   __ASM_CFI(".cfi_rel_offset 28,0x58\n\t")
                   "stp d8,  d9,  [x29, #0x60]\n\t"
                   "stp d10, d11, [x29, #0x70]\n\t"
                   "stp d12, d13, [x29, #0x80]\n\t"
                   "stp d14, d15, [x29, #0x90]\n\t"
                   "stp x1, x2, [x29, #0xa0]\n\t" /* ret_ptr, ret_len */
                   "mov x18, x4\n\t"              /* teb */
                   "mrs x1, fpcr\n\t"
                   "mrs x2, fpsr\n\t"
                   "bfi x1, x2, #0, #32\n\t"
                   "ldr x2, [x18]\n\t"            /* teb->Tib.ExceptionList */
                   "stp x1, x2, [x29, #0xb0]\n\t"

                   "ldr x7, [x18, #0x378]\n\t"    /* thread_data->syscall_frame */
                   "sub x1, sp, #0x330\n\t"       /* sizeof(struct syscall_frame) */
                   "str x1, [x18, #0x378]\n\t"    /* thread_data->syscall_frame */
                   "add x8, x29, #0xd0\n\t"
                   "stp x7, x8, [x1, #0x110]\n\t" /* frame->prev_frame,syscall_cfa */
                   "ldr w11, [x18, #0x380]\n\t"   /* thread_data->syscall_trace */
                   "cbnz x11, 1f\n\t"
                   /* switch to user stack */
                   "mov sp, x0\n\t"               /* user_sp */
                   "br x3\n"
                   "1:\tmov x19, x18\n\t"         /* teb */
                   "mov x20, x0\n\t"              /* user_sp */
                   "mov x21, x3\n\t"              /* func */
                   "mov sp, x1\n\t"
                   "ldr x1, [x20]\n\t"            /* args */
                   "ldp w2, w0, [x20, #8]\n\t"    /* len, id */
                   "str x0, [x29, #0xc0]\n\t"     /* id */
                   "bl " __ASM_NAME("trace_usercall") "\n\t"
                   "mov x18, x19\n\t"             /* teb */
                   "mov sp, x20\n\t"              /* user_sp */
                   "br x21" )


/***********************************************************************
 *           user_mode_callback_return
 */
extern void DECLSPEC_NORETURN user_mode_callback_return( void *ret_ptr, ULONG ret_len,
                                                         NTSTATUS status, TEB *teb );
__ASM_GLOBAL_FUNC( user_mode_callback_return,
                   "ldr x4, [x3, #0x378]\n\t"     /* thread_data->syscall_frame */
                   "ldp x5, x29, [x4,#0x110]\n\t" /* prev_frame,syscall_cfa */
                   "str x5, [x3, #0x378]\n\t"     /* thread_data->syscall_frame */
                   "sub x29, x29, #0xd0\n\t"
                   __ASM_CFI(".cfi_def_cfa_register 29\n\t")
                   __ASM_CFI(".cfi_rel_offset 29,0x00\n\t")
                   __ASM_CFI(".cfi_rel_offset 30,0x08\n\t")
                   __ASM_CFI(".cfi_rel_offset 19,0x10\n\t")
                   __ASM_CFI(".cfi_rel_offset 20,0x18\n\t")
                   __ASM_CFI(".cfi_rel_offset 21,0x20\n\t")
                   __ASM_CFI(".cfi_rel_offset 22,0x28\n\t")
                   __ASM_CFI(".cfi_rel_offset 23,0x30\n\t")
                   __ASM_CFI(".cfi_rel_offset 24,0x38\n\t")
                   __ASM_CFI(".cfi_rel_offset 25,0x40\n\t")
                   __ASM_CFI(".cfi_rel_offset 26,0x48\n\t")
                   __ASM_CFI(".cfi_rel_offset 27,0x50\n\t")
                   __ASM_CFI(".cfi_rel_offset 28,0x58\n\t")
                   "ldp x5, x6, [x29, #0xb0]\n\t"
                   "str x6, [x3]\n\t"             /* teb->Tib.ExceptionList */
                   "msr fpcr, x5\n\t"
                   "lsr x5, x5, #32\n\t"
                   "msr fpsr, x5\n\t"
                   "ldp x5, x6, [x29, #0xa0]\n\t" /* ret_ptr, ret_len */
                   "str x0, [x5]\n\t"             /* ret_ptr */
                   "str w1, [x6]\n\t"             /* ret_len */
                   "ldr w11, [x3, #0x380]\n\t"    /* thread_data->syscall_trace */
                   "cbz x11, 1f\n\t"
                   "ldr w3, [x29, #0xc0]\n\t"     /* id */
                   "mov x19, x2\n\t"
                   "bl " __ASM_NAME("trace_userret") "\n\t"
                   "mov x2, x19\n"                /* status */
                   "1:\tldp x19, x20, [x29, #0x10]\n\t"
                   __ASM_CFI(".cfi_same_value 19\n\t")
                   __ASM_CFI(".cfi_same_value 20\n\t")
                   "ldp x21, x22, [x29, #0x20]\n\t"
                   __ASM_CFI(".cfi_same_value 21\n\t")
                   __ASM_CFI(".cfi_same_value 22\n\t")
                   "ldp x23, x24, [x29, #0x30]\n\t"
                   __ASM_CFI(".cfi_same_value 23\n\t")
                   __ASM_CFI(".cfi_same_value 24\n\t")
                   "ldp x25, x26, [x29, #0x40]\n\t"
                   __ASM_CFI(".cfi_same_value 25\n\t")
                   __ASM_CFI(".cfi_same_value 26\n\t")
                   "ldp x27, x28, [x29, #0x50]\n\t"
                   __ASM_CFI(".cfi_same_value 27\n\t")
                   __ASM_CFI(".cfi_same_value 28\n\t")
                   "ldp d8,  d9,  [x29, #0x60]\n\t"
                   "ldp d10, d11, [x29, #0x70]\n\t"
                   "ldp d12, d13, [x29, #0x80]\n\t"
                   "ldp d14, d15, [x29, #0x90]\n\t"
                   "mov x0, x2\n\t"               /* status */
                   "mov sp, x29\n\t"
                   "ldp x29, x30, [sp], #0xd0\n\t"
                   "ret" )


/***********************************************************************
 *           user_mode_abort_thread
 */
extern void DECLSPEC_NORETURN user_mode_abort_thread( NTSTATUS status, struct syscall_frame *frame );
__ASM_GLOBAL_FUNC( user_mode_abort_thread,
                   "ldr x1, [x1, #0x118]\n\t"    /* frame->syscall_cfa */
                   "sub x29, x1, #0xc0\n\t"
                   /* switch to kernel stack */
                   "mov sp, x29\n\t"
                   __ASM_CFI(".cfi_def_cfa 29,0xc0\n\t")
                   __ASM_CFI(".cfi_offset 29,-0xc0\n\t")
                   __ASM_CFI(".cfi_offset 30,-0xb8\n\t")
                   __ASM_CFI(".cfi_offset 19,-0xb0\n\t")
                   __ASM_CFI(".cfi_offset 20,-0xa8\n\t")
                   __ASM_CFI(".cfi_offset 21,-0xa0\n\t")
                   __ASM_CFI(".cfi_offset 22,-0x98\n\t")
                   __ASM_CFI(".cfi_offset 23,-0x90\n\t")
                   __ASM_CFI(".cfi_offset 24,-0x88\n\t")
                   __ASM_CFI(".cfi_offset 25,-0x80\n\t")
                   __ASM_CFI(".cfi_offset 26,-0x78\n\t")
                   __ASM_CFI(".cfi_offset 27,-0x70\n\t")
                   __ASM_CFI(".cfi_offset 28,-0x68\n\t")
                   "bl " __ASM_NAME("abort_thread") )


/***********************************************************************
 *           KeUserModeCallback
 */
NTSTATUS KeUserModeCallback( ULONG id, const void *args, ULONG len, void **ret_ptr, ULONG *ret_len )
{
    struct syscall_frame *frame = get_syscall_frame();
    ULONG64 sp = (frame->sp - offsetof( struct callback_stack_layout, args_data[len] ) - 16) & ~15;
    struct callback_stack_layout *stack = (struct callback_stack_layout *)sp;

    if ((char *)ntdll_get_thread_data()->kernel_stack + min_kernel_stack > (char *)&frame)
        return STATUS_STACK_OVERFLOW;

    stack->args = stack->args_data;
    stack->len  = len;
    stack->id   = id;
    stack->lr   = frame->lr;
    stack->sp   = frame->sp;
    stack->pc   = frame->pc;
    memcpy( stack->args_data, args, len );
    {
        /* Thing B (#16) diag: which dispatcher does this thread's callback
         * resolve to? A SESSION-peb thread resolving to a child's EC
         * dispatcher is the wedge precursor (explorer executing the child
         * EC ntdll's exit thunks → blr x16=1). Log the first few callbacks
         * per boot for context plus EVERY session-thread/child-dispatcher
         * cross-resolution (should never happen). */
        extern PEB *peb;
        void *disp = IOS_PFUNC(KiUserCallbackDispatcher);
        int cross = (disp != pKiUserCallbackDispatcher) && (NtCurrentTeb()->Peb == peb);
        static volatile int kcb_logged = 0;
        if ((kcb_logged < 5 || cross) && kcb_logged < 40)
        {
            __sync_add_and_fetch(&kcb_logged, 1);
            dprintf(2, "[kcb] tid=%04x teb=%p peb=%p id=%u disp=%p session_disp=%p%s\n",
                    (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread,
                    (void *)NtCurrentTeb(), (void *)NtCurrentTeb()->Peb, id,
                    disp, pKiUserCallbackDispatcher,
                    cross ? "  <-- SESSION THREAD, CHILD DISPATCHER (BUG)" : "");
        }
        return call_user_mode_callback( sp, ret_ptr, ret_len, disp, NtCurrentTeb() );
    }
}


/***********************************************************************
 *           NtCallbackReturn  (NTDLL.@)
 */
NTSTATUS WINAPI NtCallbackReturn( void *ret_ptr, ULONG ret_len, NTSTATUS status )
{
    if (!get_syscall_frame()->prev_frame) return STATUS_NO_CALLBACK_ACTIVE;
    user_mode_callback_return( ret_ptr, ret_len, status, NtCurrentTeb() );
}


/***********************************************************************
 *           handle_syscall_fault
 *
 * Handle a page fault happening during a system call.
 */
static BOOL handle_syscall_fault( ucontext_t *context, EXCEPTION_RECORD *rec )
{
    struct syscall_frame *frame = get_syscall_frame();
    DWORD i;

    if (!is_inside_syscall( SP_sig(context) )) return FALSE;

    TRACE( "code=%x flags=%x addr=%p pc=%p tid=%04x\n",
           rec->ExceptionCode, rec->ExceptionFlags, rec->ExceptionAddress,
           (void *)PC_sig(context), GetCurrentThreadId() );
    for (i = 0; i < rec->NumberParameters; i++)
        TRACE( " info[%d]=%016lx\n", i, rec->ExceptionInformation[i] );

    TRACE("  x0=%016lx  x1=%016lx  x2=%016lx  x3=%016lx\n",
          (DWORD64)REGn_sig(0, context), (DWORD64)REGn_sig(1, context),
          (DWORD64)REGn_sig(2, context), (DWORD64)REGn_sig(3, context) );
    TRACE("  x4=%016lx  x5=%016lx  x6=%016lx  x7=%016lx\n",
          (DWORD64)REGn_sig(4, context), (DWORD64)REGn_sig(5, context),
          (DWORD64)REGn_sig(6, context), (DWORD64)REGn_sig(7, context) );
    TRACE("  x8=%016lx  x9=%016lx x10=%016lx x11=%016lx\n",
          (DWORD64)REGn_sig(8, context), (DWORD64)REGn_sig(9, context),
          (DWORD64)REGn_sig(10, context), (DWORD64)REGn_sig(11, context) );
    TRACE(" x12=%016lx x13=%016lx x14=%016lx x15=%016lx\n",
          (DWORD64)REGn_sig(12, context), (DWORD64)REGn_sig(13, context),
          (DWORD64)REGn_sig(14, context), (DWORD64)REGn_sig(15, context) );
    TRACE(" x16=%016lx x17=%016lx x18=%016lx x19=%016lx\n",
          (DWORD64)REGn_sig(16, context), (DWORD64)REGn_sig(17, context),
          (DWORD64)REGn_sig(18, context), (DWORD64)REGn_sig(19, context) );
    TRACE(" x20=%016lx x21=%016lx x22=%016lx x23=%016lx\n",
          (DWORD64)REGn_sig(20, context), (DWORD64)REGn_sig(21, context),
          (DWORD64)REGn_sig(22, context), (DWORD64)REGn_sig(23, context) );
    TRACE(" x24=%016lx x25=%016lx x26=%016lx x27=%016lx\n",
          (DWORD64)REGn_sig(24, context), (DWORD64)REGn_sig(25, context),
          (DWORD64)REGn_sig(26, context), (DWORD64)REGn_sig(27, context) );
    TRACE(" x28=%016lx  fp=%016lx  lr=%016lx  sp=%016lx\n",
          (DWORD64)REGn_sig(28, context), (DWORD64)FP_sig(context),
          (DWORD64)LR_sig(context), (DWORD64)SP_sig(context) );

    if (ntdll_get_thread_data()->jmp_buf)
    {
        TRACE( "returning to handler\n" );
        REGn_sig(0, context) = (ULONG_PTR)ntdll_get_thread_data()->jmp_buf;
        REGn_sig(1, context) = 1;
        PC_sig(context)      = (ULONG_PTR)longjmp;
        ntdll_get_thread_data()->jmp_buf = NULL;
    }
    else
    {
        TRACE( "returning to user mode ip=%p ret=%08x\n", (void *)frame->pc, rec->ExceptionCode );
        REGn_sig(0, context)  = rec->ExceptionCode;
        REGn_sig(18, context) = (ULONG_PTR)NtCurrentTeb();
        SP_sig(context)       = (ULONG_PTR)frame;
        PC_sig(context)       = (ULONG_PTR)__wine_syscall_dispatcher_return;
    }
    return TRUE;
}


/**********************************************************************
 *		ios_fixup_x18_for_return
 *
 * Called before returning from a signal handler on iOS.
 * iOS sigreturn zeroes x18 (the TEB/platform register).  If the
 * interrupted code was in the JIT pool, redirect through the TEB
 * trampoline so x18 is restored before the code resumes.
 */
#ifdef WINE_IOS
static inline void ios_fixup_x18_for_return( ucontext_t *context )
{
    extern void *ios_jit_rx_base_global;
    extern size_t ios_jit_pool_size_global;

    if (!ios_my_trampoline || !ios_teb_for_signals) return;

    uintptr_t pc = PC_sig(context);
    uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
    size_t sz = ios_jit_pool_size_global;

    if (rx && pc >= rx && pc < rx + sz)
    {
        REGn_sig(17, context) = pc;
        PC_sig(context) = (uintptr_t)ios_my_trampoline;
    }
}

static inline void ios_track_signal( int sig, ucontext_t *context )
{
    extern void *ios_jit_rx_base_global;
    extern size_t ios_jit_pool_size_global;
    ios_signal_total++;
    ios_signal_last = sig;
    uintptr_t pc = PC_sig(context);
    uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
    size_t sz = ios_jit_pool_size_global;
    if (rx && pc >= rx && pc < rx + sz)
        ios_signal_in_pe++;
}

#endif


/**********************************************************************
 *		segv_handler
 *
 * Handler for SIGSEGV.
 */
static int dumped_page0;   /* ml180: one wide dump, for the page-0 fault only */

/* ml174: is a candidate FEX CpuStateFrame initialised? See the call site. */
static int probe_ptr_ok( uint64_t frame )
{
    uint64_t v = 0;
    mach_vm_size_t g = 0;

    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(frame + 0x40), 8,
                                (mach_vm_address_t)&v, &g ) != KERN_SUCCESS || g != 8)
        return 0;
    return v >= 0x100000000ull && v < 0x8000000000ull;
}

#ifdef WINE_IOS
/* ml375: make wine's own logging survivable in a signal handler.
 *
 * THREE runs (ml370/374/375) died at the identical instruction —
 * `__wine_dbg_header+0x100: ldr w8,[x25,#4]` — and I misread it twice because
 * my slide arithmetic anchored on the wrong symbol. Deriving the slide from
 * the FAULTING INSTRUCTION (search the dylib for the reported insn word, match
 * the delta to a symbol) instead of a guessed anchor is what finally pinned it.
 *
 * Cause: wine's ERR/WARN/TRACE reach __wine_dbg_header -> get_info() ->
 * ntdll_get_thread_data() -> NtCurrentTeb(), and on this port NtCurrentTeb()
 * resolves through TSD slot 275. A thread that never registered a TEB (threads
 * CEF/FEX create directly, and anything faulting before its [tsd275] SET) has
 * slot 275 == NULL, so the very first ERR in a handler dereferences NULL, which
 * raises another SIGSEGV at the SAME pc, forever — the debugger script then
 * kills the app after 8 identical stops. The handler dies reporting the fault
 * it was called to report, which is why the log ends with no explanation.
 *
 * This only became fatal once faults started reaching the BSD handlers again
 * (the ml372 DECLINE path), so it reads like a new bug but is long-latent.
 *
 * Fix: before ANY logging, guarantee slot 275 is non-NULL, falling back to the
 * process-wide signal TEB. Returns 0 when no TEB could be established, and
 * callers must then use dprintf(2,...) rather than a wine macro. */
static int ios_make_wine_logging_safe( void )
{
    extern pthread_key_t ios_teb_tls_key;
    extern int ios_teb_tls_key_created;
    uintptr_t tsd_base;
    void *teb;

    /* ml376 CORRECTION — ml375's version tested the WRONG SLOT and changed
     * nothing (zero [dbg-teb] lines, identical crash). Disassembling
     * __wine_dbg_header settled it instead of another guess:
     *   1f8628: bl _NtCurrentTeb
     *   1f862c: add x25, x0, #0x3000        <- x25 = TEB + 0x3000
     *   1f86ec: ldr w8, [x25, #4]           <- FAULTS
     * and _NtCurrentTeb is `ldr x0,[page+0xcf8]; b <stub>` =
     * pthread_getspecific(ios_teb_tls_key) — the PTHREAD KEY, not TSD slot
     * 275 (slot 275 is only the x18-patcher trampolines' copy; the two are
     * independent, and the [tsd275] dump prints them side by side for exactly
     * this reason). With no value for that key NtCurrentTeb() returns NULL,
     * x25 becomes 0x3000, and the read faults at 0x3004.
     *
     * ml376 log confirms such threads exist: `[mach_exc] UNHANDLED #4 …
     * x18=0x0`.
     *
     * Populate the key (and slot 275) from the best TEB available so every
     * wine log macro in the handler — not just the first — is safe. Returns 0
     * only when no TEB exists at all, in which case callers must dprintf. */
    if (ios_teb_tls_key_created && (teb = pthread_getspecific( ios_teb_tls_key )))
        return 1;

    teb = NULL;
    __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tsd_base));
    tsd_base &= ~7ULL;
    if (tsd_base && ios_teb_tls_slot_offset)
        teb = *(void **)(tsd_base + ios_teb_tls_slot_offset);
    if (!teb) teb = (void *)ios_teb_for_signals;
    if (!teb) return 0;

    /* Republish through the key that owns the slot; never poke a raw slot. */
    if (ios_teb_tls_key_created) pthread_setspecific( ios_teb_tls_key, teb );
    {
        static int borrow_n;
        if (borrow_n < 8)
        {
            borrow_n++;
            dprintf( 2, "[dbg-teb] rev=ml376 NtCurrentTeb() was NULL in a signal handler — "
                        "installed teb=%p (every wine ERR/WARN here would have faulted at 0x3004)\n",
                     teb );
        }
    }
    return 1;
}

/* iOS-Madeira ml481 (#85): is this fault FOREIGN — i.e. raised by a host
 * (Apple/SwiftUI/Metal) thread executing host code on host memory?
 *
 * ml480's freeze: the app's UI thread (port 0x103) was inside
 * swift_allocObject -> libsystem_malloc when a trap fired INSIDE malloc (so
 * the thread already held the malloc zone lock). trap_handler adopted it as a
 * guest exception, ios_log_guest_exception then faulted (no TEB on that
 * thread), segv_handler ran, and ios_make_wine_logging_safe called through a
 * not-yet-bound lazy stub -> dyld -> malloc -> the SAME zone lock. Deadlock:
 * sampled 22x at cpu=1000 with an unchanging sp. The UI froze for the rest of
 * the run while every other thread kept going, which is exactly what the user
 * sees as "a big freeze".
 *
 * Our handlers must only adopt faults that belong to the emulated world. A
 * thread qualifies as ours if it has a TEB (pthread key or TSD slot 275) or is
 * executing from the JIT pool / guest bands; a fault also stays ours when the
 * TARGET address is emulator-managed memory (wine guard pages, pool aliases),
 * since host threads legitimately touch those. Everything else is foreign.
 *
 * pthread_getspecific and the raw TSD read are async-signal-safe; nothing here
 * allocates, so this predicate can run before any logging. */
/***********************************************************************
 *		ios_srcwatch — catch the guest code that writes Chromium's bitmap
 *
 * iOS-Madeira ml514. The render corruption is a per-draw-op DESTINATION
 * error with a CONSTANT offset (~-550,-97): a panel written where it does
 * not belong with its true location left black, the QR halo displaced
 * independently of the QR it surrounds. Everything WE own is exonerated —
 * compositor, flush, GDI transport ([put-image] shows clean 1:1 700x440),
 * and the VGUI dialog renders perfectly through the SAME surface. And
 * every memory-ordering hypothesis is spent (scalar TSO correct, vector /
 * memcpy TSO no effect, all three Chromium concurrency switches inert).
 * What is left is Chromium computing wrong values under FEX — and since
 * upstream FEX runs Chromium correctly on Linux, the defect is in an
 * iOS-specific deviation of ours.
 *
 * To work backwards from pixels to code we need to know WHICH GUEST CODE
 * writes which region. mprotect the source bitmap read-only, then let the
 * faults name the writers: on each fault log the guest RIP (CpuStateFrame
 * at x28+0x18, same as the [guest-state] dump) plus the byte offset it
 * touched, unprotect that ONE page, and continue. The buffer is ~1.5MB =
 * ~96 pages, so a whole frame costs ~96 faults, not one per pixel.
 *
 * The offset is the payload: pages carrying the DISPLACED region will be
 * written by a different RIP (or the same RIP with different inputs) than
 * the pages that land correctly, and that RIP resolves to libcef+RVA via
 * the [jit-pool] image map — which is where FEX's translation of that
 * block can be dumped and audited.
 *
 * Safety: one-shot and env-gated. Arms once, self-disarms after
 * IOS_SRCWATCH_MAX faults or on any failure, and every page is unprotected
 * the first time it faults, so a page can never fault twice and no writer
 * can be starved. If arming fails the feature silently stays off — a
 * diagnostic must never break the path it measures.
 */
/* ml516: the cap counts DISTINCT pages, not faults. In ml516 two writers
 * burned 361 of 480 faults on THREE pages — the per-page unprotect did not
 * stick there (aliased mapping is the likely reason), so coverage starved
 * at ~113 pages instead of a full frame. A seen-bitmap makes each page
 * count once, and a repeat storm now self-limits instead of eating the
 * budget. */
#define IOS_SRCWATCH_MAX   400      /* total attributions */
#define IOS_SRCWATCH_PAGES 512      /* covers 8MB at 16K pages */
#define IOS_SRCWATCH_REPEAT_LIMIT 48
/* ml517: attributions to capture PER PAGE before leaving it open. The
 * ml517 run exposed a design flaw: libcef+0x41258f0 is a SOLID-COLOUR FILL
 * (movl %edx,(%r10) x4 / addq $0x10 / dest += stride) — Chromium clearing
 * the frame. It runs FIRST and touches EVERY page, so a one-shot
 * seen-bitmap attributed all 76 pages to the clear and left the content
 * painters — the writers that would name the displaced band — structurally
 * invisible. Re-protecting a page after each attribution makes its NEXT
 * writer fault too, at a cost of only ~N faults per page. */
#define IOS_SRCWATCH_PER_PAGE 3
#define IOS_SRCWATCH_RIPS 24        /* distinct writers tracked in the census */
#define IOS_SRCWATCH_TILE 254       /* Chromium tile pitch (256 less 1px border each side) */

static struct {
    volatile uintptr_t base;      /* page-aligned watch start, 0 = disarmed */
    volatile uintptr_t end;
    volatile int       pages;     /* distinct pages attributed */
    volatile int       repeats;   /* faults on already-unprotected pages */
    volatile int       armed;
    unsigned char      seen[IOS_SRCWATCH_PAGES];
    /* ml548: image geometry, so a fault offset can be reported as (x,y) and a
     * TILE COLUMN instead of a raw byte offset. Without this the log needs
     * offline arithmetic to mean anything, and the whole question is "which
     * tile column did this writer touch". */
    volatile unsigned   img_w, img_h, img_stride;
    volatile unsigned long row_lo, row_hi;   /* watched row band */
    /* per-writer tile-column census: which columns did each guest RIP write? */
    volatile uint64_t   rip_id[IOS_SRCWATCH_RIPS];
    volatile unsigned   rip_colmask[IOS_SRCWATCH_RIPS];
    volatile unsigned   rip_hits[IOS_SRCWATCH_RIPS];
    volatile int        rip_n;
} ios_srcwatch;

/* ml530: the watch arms ONCE (the ios_srcwatch.armed guard), so two call sites
 * competing for it means whichever runs first silently wins and the other is
 * never armed at all — a probe that reports nothing while looking healthy.
 * There are now two subjects:
 *
 *   "render" — win32u's dibdrv_PutImage, Chromium's SOURCE bitmap (the original
 *              use; hit a hard ceiling, see project_render_corruption_hunt)
 *   "js"     — the assembled steamui JS buffer in NtReadFile (#78: V8 reports
 *              `SyntaxError: Invalid or unexpected token` on source our file
 *              reads deliver 73/73 byte-perfect, so something writes to it
 *              afterwards)
 *
 * MADEIRA_SRCWATCH names which one to arm. "1" keeps the legacy render meaning. */
void ios_srcwatch_arm_for( const void *bits, unsigned long len, const char *tag )
{
    const char *want = getenv( "MADEIRA_SRCWATCH" );
    uintptr_t b, e;

    /* ml531: the floor and the once-only guard were both tuned for the render
     * subject and both silently killed the js subject.
     *
     *  - len < 0x10000 rejected EVERY contiguous JS buffer: the ones Steam reads
     *    in a single shot are 1-25KB (sp.js 2178, 716.js 5217, 9108.js 8426,
     *    2294.js 22495), so the ml530 control run logged seven "arming srcwatch"
     *    lines and produced ZERO [srcwatch] ARMED. A floor that rejects the whole
     *    population is a probe that cannot fire.
     *  - armed-once meant the FIRST small file (sp.js) would have taken the slot
     *    for the run even if the floor had allowed it, and the file that actually
     *    fails is loaded later. Re-arm instead, unprotecting the previous region
     *    first so no page is left write-protected without a handler tracking it —
     *    that would surface as a stray AV in whatever touched it next. */
    unsigned long floor = !strcmp( tag, "js" ) ? 0x400 : 0x10000;

    if (!want || !tag) return;
    if (strcmp( want, tag ) && !(!strcmp( want, "1" ) && !strcmp( tag, "render" ))) return;
    if (!bits || len < floor) return;

    if (ios_srcwatch.armed)
    {
        /* Release the previous subject before taking a new one. */
        uintptr_t ob = ios_srcwatch.base, oe = ios_srcwatch.end;
        ios_srcwatch.armed = 0;
        if (ob && oe > ob) mprotect( (void *)ob, oe - ob, PROT_READ | PROT_WRITE );
    }

    b = (uintptr_t)bits & ~(uintptr_t)0x3FFF;             /* 16K pages on iOS */
    e = ((uintptr_t)bits + len + 0x3FFF) & ~(uintptr_t)0x3FFF;

    if (mprotect( (void *)b, e - b, PROT_READ ) != 0)
    {
        ERR("[srcwatch] arm FAILED subject=%s bits=%p len=%lu errno=%d — staying off rev=ml530\n",
            tag, bits, len, errno);
        return;
    }
    ios_srcwatch.base = b;
    ios_srcwatch.end = e;
    ios_srcwatch.pages = 0;
    ios_srcwatch.repeats = 0;
    memset( (void *)ios_srcwatch.seen, 0, sizeof(ios_srcwatch.seen) );
    ios_srcwatch.armed = 1;
    /* ml549: resolve the exact-RIP export now — arming happens long after the
     * emulator module is mapped, and the resolver is one-shot. */
    { extern void ios_resolve_fex_exports( void ); ios_resolve_fex_exports(); }  /* ml613: retryable, resolves both */
    ERR("[srcwatch] ARMED subject=%s base=%p end=%p (%lu bytes, %lu pages) rev=ml530\n",
        tag, (void *)b, (void *)e, (unsigned long)(e - b), (unsigned long)((e - b) >> 14));
}

/* Legacy entry point: win32u's dibdrv_PutImage. */
void ios_srcwatch_arm( const void *bits, unsigned long len )
{
    ios_srcwatch_arm_for( bits, len, "render" );
}

/* ml548: geometry-aware arm.
 *
 * Two reasons this exists rather than reusing the plain entry point:
 *
 *  1. TARGETING. Arming the whole 1.2MB bitmap spreads a 400-attribution budget
 *     across ~76 pages, so the clear (which touches EVERY page first) dominates
 *     and the content painters — the writers that would name a displaced band —
 *     stay invisible. MADEIRA_SRCWATCH_ROWS=lo,hi restricts the watch to one
 *     horizontal band so the budget lands where displacement was measured.
 *  2. READABILITY. Storing stride lets a fault offset be reported as (x,y) and a
 *     tile column directly, instead of needing offline arithmetic to interpret.
 *
 * The band is chosen from the consensus-median analysis: pick rows where an
 * element is known to land in the wrong tile column. */
void ios_srcwatch_arm_geom( const void *bits, unsigned long len,
                            unsigned w, unsigned h, unsigned stride )
{
    const char *rows = getenv( "MADEIRA_SRCWATCH_ROWS" );
    unsigned long lo = 0, hi = h;
    const void *abits = bits;
    unsigned long alen = len;

    if (rows && stride)
    {
        char *endp = NULL;
        unsigned long a = strtoul( rows, &endp, 0 );
        unsigned long b = (endp && *endp == ',') ? strtoul( endp + 1, NULL, 0 ) : 0;
        if (b > a && b <= h)
        {
            lo = a; hi = b;
            abits = (const char *)bits + (size_t)lo * stride;
            alen  = (size_t)(hi - lo) * stride;
        }
    }
    ios_srcwatch.img_w = w;
    ios_srcwatch.img_h = h;
    ios_srcwatch.img_stride = stride;
    ios_srcwatch.row_lo = lo;
    ios_srcwatch.row_hi = hi;
    ios_srcwatch.rip_n = 0;
    memset( (void *)ios_srcwatch.rip_id, 0, sizeof(ios_srcwatch.rip_id) );
    memset( (void *)ios_srcwatch.rip_colmask, 0, sizeof(ios_srcwatch.rip_colmask) );
    memset( (void *)ios_srcwatch.rip_hits, 0, sizeof(ios_srcwatch.rip_hits) );
    ios_srcwatch_arm_for( abits, alen, "render" );
    if (ios_srcwatch.armed)
        ERR("[srcwatch] GEOM %ux%u stride=%u rows=[%lu,%lu) tile=%d rev=ml548\n",
            w, h, stride, lo, hi, IOS_SRCWATCH_TILE);
}

/* Census dump: which TILE COLUMNS did each writer touch? A painter that should
 * only ever touch one column but shows bits for two is the finding. */
void ios_srcwatch_census( void )
{
    int i;
    if (ios_srcwatch.rip_n <= 0) return;
    for (i = 0; i < ios_srcwatch.rip_n && i < IOS_SRCWATCH_RIPS; i++)
        ERR("[srcwatch-census] writer=%d guest_rip=%p hits=%u tile_cols=0x%x%s rev=ml548\n",
            i, (void *)(uintptr_t)ios_srcwatch.rip_id[i], ios_srcwatch.rip_hits[i],
            ios_srcwatch.rip_colmask[i],
            (ios_srcwatch.rip_colmask[i] & (ios_srcwatch.rip_colmask[i] - 1))
                ? "  <== MULTI-COLUMN" : "");
}

/* Returns 1 if the fault belonged to the watch and was consumed.
 *
 * ml515: called from the MACH exception handler, not segv_handler. ml514
 * hooked the BSD path and caught ZERO faults while turning the window
 * black on 2/2 runs — guest faults in this port are delivered in-Mach, so
 * the protection fault went to the guest as an AV and killed the paint.
 * Takes the Mach thread state directly for the same reason. */
static int ios_srcwatch_handle( const arm_thread_state64_t *st, uintptr_t addr )
{
    uintptr_t page;
    uint64_t x28, rip = 0, exact_rip = 0;
    mach_vm_size_t got = 0;
    int n;

    if (!ios_srcwatch.armed) return 0;
    if (addr < ios_srcwatch.base || addr >= ios_srcwatch.end) return 0;

    page = addr & ~(uintptr_t)0x3FFF;
    {
        unsigned long pidx = (page - ios_srcwatch.base) >> 14;

        /* Already attributed? Then the unprotect did not stick for this page.
         * Log the first few, then kill the whole protection rather than let a
         * repeat storm starve the pages we have not attributed yet. */
        if (pidx < IOS_SRCWATCH_PAGES && ios_srcwatch.seen[pidx] >= IOS_SRCWATCH_PER_PAGE)
        {
            /* Budget for this page spent — leave it open so it stops costing
             * faults, and count it only as a repeat for storm detection. */
            int r = ++ios_srcwatch.repeats;
            if (r >= IOS_SRCWATCH_REPEAT_LIMIT)
            {
                dprintf(STDERR_FILENO, "[srcwatch] repeat storm (%d) — unprotecting ALL and "
                        "disarming; %d attributions rev=ml517\n", r, ios_srcwatch.pages);
                { extern void ios_srcwatch_census( void ); ios_srcwatch_census(); }
                mprotect( (void *)ios_srcwatch.base, ios_srcwatch.end - ios_srcwatch.base,
                          PROT_READ | PROT_WRITE );
                ios_srcwatch.armed = 0;
            }
            else
                mprotect( (void *)page, 0x4000, PROT_READ | PROT_WRITE );
            return 1;
        }
        if (pidx < IOS_SRCWATCH_PAGES) ios_srcwatch.seen[pidx]++;
    }

    /* Guest RIP lives at CpuStateFrame+0x18 off x28 — same source the
     * [guest-state] dump uses. Read it defensively: a NULL or unreadable
     * x28 means a HOST thread wrote this page, which is itself a finding. */
    x28 = st->__x[28];
    if (x28) mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(x28 + 0x18),
                                     sizeof(rip), (mach_vm_address_t)&rip, &got );

    /* ml549: the RIP above is BLOCK-GRANULAR — FEX only syncs CpuStateFrame+0x18 at
     * block boundaries, so it names the calling block, not the instruction that
     * executed. ml548 disassembled one and got `movq %rbp,%rcx; callq` (call setup)
     * instead of a store, which is why the writer could never be identified.
     *
     * FEX keeps a host-PC -> guest-RIP table in every block tail and walks it for
     * exception reconstruction. ios_fex_rip_from_hostpc() is that same walk exported
     * as C. The block header pointer is CPUState offset 0 == x28+0, and the host PC
     * is right here in the fault state. Log BOTH so the difference is visible: if
     * exact == block on every fault, the lookup is not working and nothing below it
     * can be trusted. */
    {
        /* The lookup lives in xtajit64.dll (an ARM64EC PE), not in this Mach-O, so a
         * weak extern would silently resolve to NULL. Use the pointer xtajit64 pushes
         * down at init on the same unix-call that carries the JIT alias callback. */
        extern unsigned long long (*ios_fex_rip_from_hostpc_cb)( unsigned long long, unsigned long long );
        uint64_t blockhdr = 0;
        mach_vm_size_t bgot = 0;
        if (x28)
            mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)x28,
                                    sizeof(blockhdr), (mach_vm_address_t)&blockhdr, &bgot );
        /* ml551: gate on the RESOLVED FLAG, never on the pointer. Calling this
         * pointer while it held ASCII was what blacked out the window. */
        extern volatile int ios_fex_rip_resolved;
        if (ios_fex_rip_resolved && ios_fex_rip_from_hostpc_cb
            && bgot == sizeof(blockhdr) && blockhdr)
            exact_rip = ios_fex_rip_from_hostpc_cb(
                blockhdr, (uint64_t)__darwin_arm_thread_state64_get_pc(*st) );
    }

    n = ++ios_srcwatch.pages;
    {
        /* ml548: report the destination in IMAGE terms and record which tile
         * column this writer touched. A raw byte offset needs offline arithmetic
         * to interpret, and "which tile column" is the entire question. */
        unsigned long off = (unsigned long)(addr - ios_srcwatch.base);
        unsigned stride = ios_srcwatch.img_stride;
        unsigned long yy = 0, xx = 0; int col = -1;
        if (stride)
        {
            yy = ios_srcwatch.row_lo + off / stride;
            xx = (off % stride) / 4;
            col = (int)(xx / IOS_SRCWATCH_TILE);
        }
        dprintf(STDERR_FILENO,
            "[srcwatch] #%d off=+0x%lx -> x=%lu y=%lu tile_col=%d EXACT_rip=%p block_rip=%p host_pc=%p x28=%p%s rev=ml549\n",
            n, off, xx, yy, col,
            (void *)(uintptr_t)exact_rip,
            (void *)(uintptr_t)rip,
            (void *)(uintptr_t)__darwin_arm_thread_state64_get_pc(*st),
            (void *)(uintptr_t)x28,
            (got == sizeof(rip)) ? "" : "  (rip UNREADABLE => host writer)");

        if (col >= 0 && col < 32)
        {
            int i, slot = -1;
            for (i = 0; i < ios_srcwatch.rip_n && i < IOS_SRCWATCH_RIPS; i++)
                if (ios_srcwatch.rip_id[i] == rip) { slot = i; break; }
            if (slot < 0 && ios_srcwatch.rip_n < IOS_SRCWATCH_RIPS)
            {
                slot = ios_srcwatch.rip_n++;
                ios_srcwatch.rip_id[slot] = rip;
            }
            if (slot >= 0)
            {
                ios_srcwatch.rip_colmask[slot] |= (1u << col);
                ios_srcwatch.rip_hits[slot]++;
            }
        }
    }

    /* ml534: DUMP THE WHOLE REGISTER FILE — do not guess the mapping.
     *
     * ml533 assumed the Windows ARM64EC ABI (RAX=x8, RDX=x1, RSP=x23) and the
     * data immediately refuted it: "RAX" read 0x1b8,0x1b3,0x1ad,0x1a7 — i.e.
     * 440,435,429,423, a ROW COUNTER counting down from the buffer height (440),
     * and "[RSP]" yielded another stack address 0x2b8 away rather than a return
     * address. FEX uses its own `x64::SRA` span, not the EC ABI table.
     *
     * So stop guessing. Dump x0..x30 for the first few faults and identify the
     * registers OFFLINE by what they contain — the destination register must equal
     * the faulting address, a caller/return value lands in libcef's code range
     * (device base 0x71e1910000 + .text), and a stack pointer sits in the guest
     * stack band. That is self-calibrating: it cannot be wrong about the mapping
     * because it assumes none.
     *
     * Bounded to the first 8 faults — 2052 fired in ml533, and 31 registers each
     * would bury the log. */
    {
        /* ml535: budget the dumps PER DISTINCT WRITER, not globally.
         *
         * ml534 used one global budget of 8 and the CLEAR consumed every slot —
         * it runs first and marches page by page (faults at ...f0000, ...f4000,
         * ...f8000 with x0 advancing in step), exactly the starvation that capped
         * ml517. Meanwhile the writer we actually want is the CONTENT PAINTER:
         * this run it was the TOP writer at 1293 faults (guest_rip +0x582c89)
         * versus 1086 for the clear (+0x41258f0), and it got zero register dumps.
         *
         * A per-rip budget guarantees every distinct writer is sampled regardless
         * of who runs first or faults most. Same lesson as the ml516 cap that
         * counted EVENTS instead of DISTINCT SUBJECTS. */
        enum { SW_RIPS = 8, SW_PER_RIP = 2 };
        static volatile uint64_t seen_rip[SW_RIPS];
        static volatile int      seen_cnt[SW_RIPS];
        int slot = -1, i2, d = 0;

        for (i2 = 0; i2 < SW_RIPS; i2++)
        {
            if (seen_rip[i2] == rip) { slot = i2; break; }
            if (seen_rip[i2] == 0)   { seen_rip[i2] = rip; slot = i2; break; }
        }
        if (slot >= 0 && seen_cnt[slot] < SW_PER_RIP) d = ++seen_cnt[slot];

        if (d)
        {
            char buf[560];
            int off = 0, i;
            for (i = 0; i <= 30 && off < (int)sizeof(buf) - 24; i++)
                off += snprintf( buf + off, sizeof(buf) - off, "%s%d=%llx",
                                 i ? " x" : "x", i, (unsigned long long)st->__x[i] );
            dprintf(STDERR_FILENO,
                "[srcwatch]   #%d REGS writer=%d/%d guest_rip=%p fault=%p sp=%p lr=%p | %s rev=ml535\n",
                n, slot, d, (void *)(uintptr_t)rip, (void *)addr,
                (void *)(uintptr_t)__darwin_arm_thread_state64_get_sp(*st),
                (void *)(uintptr_t)__darwin_arm_thread_state64_get_lr(*st), buf);
        }
    }

    /* ml517: unprotect just long enough for THIS write to land, then the
     * page is re-armed on the next fault path below if its per-page budget
     * remains — that is what exposes the content painters behind the clear. */
    if (mprotect( (void *)page, 0x4000, PROT_READ | PROT_WRITE ) != 0)
    {
        dprintf(STDERR_FILENO, "[srcwatch] unprotect FAILED at %p errno=%d — DISARMING rev=ml515\n",
            (void *)page, errno);
        mprotect( (void *)ios_srcwatch.base, ios_srcwatch.end - ios_srcwatch.base,
                  PROT_READ | PROT_WRITE );
        ios_srcwatch.armed = 0;
        return 1;
    }

    {
        unsigned long pidx2 = (page - ios_srcwatch.base) >> 14;
        if (ios_srcwatch.armed && pidx2 < IOS_SRCWATCH_PAGES
            && ios_srcwatch.seen[pidx2] < IOS_SRCWATCH_PER_PAGE)
            mprotect( (void *)page, 0x4000, PROT_READ );   /* catch the next writer */
    }

    if (n >= IOS_SRCWATCH_MAX)
    {
        dprintf(STDERR_FILENO, "[srcwatch] cap %d DISTINCT pages reached — disarming "
                "(%d repeats) rev=ml516\n", IOS_SRCWATCH_MAX, ios_srcwatch.repeats);
        mprotect( (void *)ios_srcwatch.base, ios_srcwatch.end - ios_srcwatch.base,
                  PROT_READ | PROT_WRITE );
        ios_srcwatch.armed = 0;
    }
    return 1;
}

static int ios_fault_is_foreign( const void *pc, const void *addr )
{
    extern pthread_key_t ios_teb_tls_key;
    extern int ios_teb_tls_key_created;
    extern void *ios_jit_rx_base_global;
    extern void *ios_jit_rw_base_global;
    extern size_t ios_jit_pool_size_global;
    uintptr_t p = (uintptr_t)pc, a = (uintptr_t)addr, tsd_base = 0;
    uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
    uintptr_t rw = (uintptr_t)ios_jit_rw_base_global;
    size_t sz = ios_jit_pool_size_global;

    /* a registered wine/guest thread is always ours */
    if (ios_teb_tls_key_created && pthread_getspecific( ios_teb_tls_key )) return 0;
    __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tsd_base));
    tsd_base &= ~7ULL;
    if (tsd_base && ios_teb_tls_slot_offset &&
        *(void **)(tsd_base + ios_teb_tls_slot_offset)) return 0;

    /* TEB-less but running emulated code (threads CEF/FEX create directly) */
    if (sz && rx && p >= rx && p < rx + sz) return 0;
    if (sz && rw && p >= rw && p < rw + sz) return 0;
    if (p >= 0x7000000000ull && p < 0x8000000000ull) return 0;  /* guest | PA | FEX bands */

    /* host code, but touching emulator-managed memory (guard page, pool alias,
     * guest buffer handed to Metal): the repair paths below are still correct */
    if (a)
    {
        if (sz && rx && a >= rx && a < rx + sz) return 0;
        if (sz && rw && a >= rw && a < rw + sz) return 0;
        if (a >= 0x7000000000ull && a < 0x8000000000ull) return 0;
    }
    return 1;
}

/* Decline a foreign fault: report it with write(2)-only logging (the
 * interrupted thread may hold the malloc lock, so NOTHING here may allocate or
 * hit an unbound lazy stub), then restore the default disposition so the OS
 * reports honestly instead of us spinning forever inside our own handler. */
static void ios_decline_foreign_fault( int sig, const void *pc, const void *addr )
{
    static int declined_n;
    if (declined_n < 8)
    {
        declined_n++;
        dprintf( 2, "[host-fault] sig=%d pc=%p addr=%p on a NON-guest thread — declining to adopt "
                    "(would have deadlocked in our own handler) rev=ml481\n", sig, pc, addr );
    }
    signal( sig, SIG_DFL );
}
#endif

/* ---------------------------------------------------------------------------
 * ml845 [tlswatch]: catch the writer of the UE5 exe's thread-local at
 * static TLS block 0 +0x38 IN THE ACT.
 *
 * Established so far: the value is the thread's own FEX emulator stack top,
 * it appears during dispatch of the engine's thread-naming exception
 * (RaiseException 0x406D1388), and NOTHING in the executable writes that slot
 * -- every static form has been exhausted. So the writer is either a guest DLL
 * or our own dispatch code, and only a runtime trap can name it.
 *
 * Arm: in NtRaiseException for that code, make the block's host page(s)
 * read-only. Re-arm: from NtContinue on the same thread while the target word
 * is still untouched (dispatch continues through several NtContinue calls, so
 * an off-target write that steals the watch costs one interval, not the run).
 * Catch: in bus_handler, before the [wr-strip] heal that would otherwise
 * silently restore access, log the faulting PC (dladdr for native, raw for JIT
 * pool), the target offset, restore access and resume in place. Capped. */
#include <dlfcn.h>
static uintptr_t ios_tlswatch_block, ios_tlswatch_page, ios_tlswatch_len;
static DWORD ios_tlswatch_tid;
static int ios_tlswatch_armed, ios_tlswatch_hit, ios_tlswatch_faults;

void ios_tlswatch_arm_block( void *blockp, const char *why )
{
    TEB *teb = NtCurrentTeb();
    uintptr_t block, target;

    /* ml881: OPT-IN. The ml845 diagnosis is closed (ml848 fixed the TLS-slot
     * aliasing), but this stayed armed on every new thread, write-protecting
     * its 16 KB TLS page. A UE 5.4 worker's plain TLS-slot store compiles to
     * a store-release (stlr), which the bus-handler emulator refuses, and the
     * refusal became a DATATYPE_MISALIGNMENT exception delivered to the game
     * -- which then crashed inside its own crash reporter. */
    { static int enabled = -1; if (enabled < 0) enabled = getenv("MADEIRA_TLSWATCH") != NULL; if (!enabled) return; }
    if (ios_tlswatch_hit || ios_tlswatch_armed || !teb || !blockp) return;
    block = (uintptr_t)blockp;
    if (*(uint64_t *)(block + 0x38)) return;   /* nothing left to catch on this thread */
    target = block + 0x38;
    ios_tlswatch_page = target & ~(uintptr_t)0x3fff;
    ios_tlswatch_len = ((target + 0x20) > ios_tlswatch_page + 0x4000) ? 0x8000 : 0x4000;
    if (mprotect( (void *)ios_tlswatch_page, ios_tlswatch_len, PROT_READ ))
    {
        dprintf( 2, "[tlswatch] ml845 arm(%s) FAILED errno=%d page=%p\n", why, errno, (void *)ios_tlswatch_page );
        return;
    }
    ios_tlswatch_block = block;
    ios_tlswatch_tid = (DWORD)(ULONG_PTR)teb->ClientId.UniqueThread;
    ios_tlswatch_armed = 1;
    dprintf( 2, "[tlswatch] ml845 ARMED (%s) tid=%04x block=%p target=%p page=%p len=0x%zx value-now=0x%llx\n",
             why, (unsigned)ios_tlswatch_tid, (void *)block, (void *)target, (void *)ios_tlswatch_page,
             (size_t)ios_tlswatch_len, (unsigned long long)*(uint64_t *)target );
}

void ios_tlswatch_arm( const char *why )
{
    void **blocks = NtCurrentTeb() ? NtCurrentTeb()->ThreadLocalStoragePointer : NULL;
    if (blocks && blocks[0]) ios_tlswatch_arm_block( blocks[0], why );
}

void ios_tlswatch_rearm( const char *why )
{
    TEB *teb = NtCurrentTeb();
    if (ios_tlswatch_armed || ios_tlswatch_hit || !ios_tlswatch_block || !teb) return;
    if ((DWORD)(ULONG_PTR)teb->ClientId.UniqueThread != ios_tlswatch_tid) return;
    if (ios_tlswatch_faults >= 24) return;
    if (*(uint64_t *)(ios_tlswatch_block + 0x38))
    {
        /* Already written between faults: name that fact instead of watching a
         * slot that has nothing left to tell us. */
        dprintf( 2, "[tlswatch] ml845 target already set at rearm(%s): 0x%llx -- the write fell between "
                    "a heal and this rearm, or came from a thread the watch does not follow\n",
                 why, (unsigned long long)*(uint64_t *)(ios_tlswatch_block + 0x38) );
        ios_tlswatch_hit = 1;
        return;
    }
    if (!mprotect( (void *)ios_tlswatch_page, ios_tlswatch_len, PROT_READ )) ios_tlswatch_armed = 1;
}

/* Returns 1 when the fault was the watch and has been healed (caller resumes). */
static int ios_tlswatch_fault( const void *addr, const void *pc, const char *which )
{
    uintptr_t a = (uintptr_t)addr;
    Dl_info di;
    int in_target;
    long off;

    if (!ios_tlswatch_armed) return 0;
    if (a < ios_tlswatch_page || a >= ios_tlswatch_page + ios_tlswatch_len) return 0;
    ios_tlswatch_faults++;
    off = (long)(a - ios_tlswatch_block);
    in_target = (off >= 0x38 && off < 0x50);
    memset( &di, 0, sizeof di );
    dladdr( pc, &di );
    dprintf( 2, "[tlswatch] ml845 WRITE #%d via %s: addr=%p = block%+ld %s | pc=%p %s`%s+0x%llx tid=%04x\n",
             ios_tlswatch_faults, which, addr, off, in_target ? "<== TARGET WORD" : "(other data on the page)",
             pc, di.dli_fname ? strrchr( di.dli_fname, '/' ) ? strrchr( di.dli_fname, '/' ) + 1 : di.dli_fname : "(no image: JIT pool or guest)",
             di.dli_sname ? di.dli_sname : "?",
             di.dli_saddr ? (unsigned long long)((uintptr_t)pc - (uintptr_t)di.dli_saddr) : 0ull,
             (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread );
    mprotect( (void *)ios_tlswatch_page, ios_tlswatch_len, PROT_READ | PROT_WRITE );
    ios_tlswatch_armed = 0;
    if (in_target) ios_tlswatch_hit = 1;
    return 1;
}

#ifdef WINE_IOS
/* ml938: defined below next to the store emulator it reuses. */
static int ios_subfloor_service( ucontext_t *ctx, void *fault_addr, const char *via, void *peb );
#endif

static void segv_handler( int signal, siginfo_t *siginfo, void *sigcontext )
{
    EXCEPTION_RECORD rec = { 0 };
    ucontext_t *context = sigcontext;
    DWORD64 esr = get_fault_esr( context );
#ifdef WINE_IOS
    int dbg_ok;

    /* ml481 (#85): decide FOREIGN-ness before anything that could allocate —
     * ios_make_wine_logging_safe() itself is the call that deadlocked in ml480. */
    if (ios_fault_is_foreign( (void *)PC_sig( context ), siginfo->si_addr ))
    {
        ios_decline_foreign_fault( signal, (void *)PC_sig( context ), siginfo->si_addr );
        return;
    }
    dbg_ok = ios_make_wine_logging_safe();
#endif

#ifdef WINE_IOS
    ios_track_signal( signal, context );
    {
        static int segv_dump_count = 0;
        static int total_segv_count = 0;
        total_segv_count++;
        ios_total_segv_count = total_segv_count;
        void *pc = (void*)PC_sig(context);

        /* Read the NATIVE x18 (iOS platform register value in handler context) */
        uint64_t native_x18;
        __asm__ volatile("mov %0, x18" : "=r"(native_x18));

        /* Log first few SEGVs with both native and ucontext x18.
         * ml375: dprintf when no TEB could be established — a wine macro here
         * faults inside __wine_dbg_header and loops the handler forever. */
        if (total_segv_count <= 5 && !dbg_ok)
            dprintf( 2, "SEGV #%d: pc=%p addr=%p (no TEB — wine logging unsafe)\n",
                     total_segv_count, pc, siginfo->si_addr );
        else if (total_segv_count <= 5)
            ERR("SEGV #%d: pc=%p addr=%p uctx_x18=%p disp=%llu mach_exc=%d\n",
                total_segv_count, pc, siginfo->si_addr,
                (void*)REGn_sig(18, context),
                (unsigned long long)g_wine_dispatcher_count,
                ios_exc_msg_count);

        /* Execution fault at PE address → redirect to JIT pool */
        if (pc == siginfo->si_addr)
        {
            extern void *ios_jit_translate_addr(void *addr);
            void *jit_pc = ios_jit_translate_addr(pc);
            if (jit_pc != pc)
            {
                /* Use trampoline to set x18 (sigreturn zeroes it on iOS) */
                if (ios_my_trampoline && ios_teb_for_signals)
                {
                    REGn_sig(17, context) = (uintptr_t)jit_pc;
                    PC_sig(context) = (uintptr_t)ios_my_trampoline;
                }
                else
                {
                    PC_sig(context) = (uintptr_t)jit_pc;
                }
                return;
            }
        }

        /* Redirect user_shared_data accesses (0x7FFE0000) to our real allocation.
         * iOS __PAGEZERO prevents mapping at the standard Windows address.
         * Find the register holding 0x7FFE* and replace with real address. */
        {
            uintptr_t fault_addr = (uintptr_t)siginfo->si_addr;
            if (fault_addr >= 0x7FFE0000 && fault_addr < 0x7FFF0000)
            {
                extern struct _KUSER_SHARED_DATA *user_shared_data;
                uintptr_t real_usd = (uintptr_t)user_shared_data;
                if (real_usd && real_usd != 0x7FFE0000)
                {
                    int fixed = 0;
                    for (int reg = 0; reg <= 28; reg++)
                    {
                        uint64_t rval = REGn_sig(reg, context);
                        if (rval >= 0x7FFE0000 && rval < 0x7FFF0000)
                        {
                            REGn_sig(reg, context) = real_usd + (rval - 0x7FFE0000);
                            fixed = 1;
                        }
                    }
                    if (fixed)
                    {
                        static int usd_fix_count = 0;
                        if (usd_fix_count < 10)
                            ERR("USD redirect: addr=%p → real_usd=%p (fix #%d)\n",
                                (void*)fault_addr, (void*)real_usd, usd_fix_count);
                        usd_fix_count++;

                        /* Also fix x18 if zeroed, and route through trampoline */
                        extern void *ios_jit_rw_base_global;
                        if (REGn_sig(18, context) == 0 && ios_teb_for_signals && ios_my_trampoline)
                        {
                            if (ios_jit_rw_base_global && ios_my_slot >= 0)
                                *(uint64_t *)((char *)ios_jit_rw_base_global + ios_my_slot * 16) = ios_teb_for_signals;
                            REGn_sig(17, context) = PC_sig(context);
                            PC_sig(context) = (uintptr_t)ios_my_trampoline;
                        }
                        return;
                    }
                }
            }
        }

        /* If x18 is 0 and we have TEB backup, restore it directly.
         * iOS kernel zeroes x18 (platform register) on signal delivery.
         * The binary patcher is the real fix (rewrites x18 refs to use
         * a safe TEB load sequence). This is just a simple fallback.
         *
         * BUT: if the faulting PC is itself in low/unmapped memory (i.e. we
         * jumped to an unrelocated RVA), restoring x18 doesn't help — the
         * next SEGV will fire at the same PC. Fall through to the diagnostic
         * dump so the real cause is visible.
         *
         * AND (2026-07-06): only retry when the faulting instruction's base
         * register IS x18 (Rn==18, the same discriminator the Mach handler's
         * [x18,#imm] emulation uses). A fault with any other base register is
         * NOT x18-caused — retrying it swallows genuine guest access
         * violations in an infinite loop (Thumper desktop: `ldrh w7,[x7,...]`
         * on guest pointer 0x3f800018 = float 1.0 bits spun 6.8M times here
         * instead of being delivered to the game as an AV). */
        /* ml158 PROBE (#36): the webhelper dies on a fault this discriminator
         * declines. ml157 showed FEX emitted `movz w1,#0; ldr x1,[x1]` — the
         * page-0 address was materialised into a SCRATCH register, so Rn!=18
         * and we fall through to a fatal SEGV (5 repeats -> thread exit ->
         * steam exit(1)).
         *
         * ml158 note: the first cut of this probe went into the MACH handler,
         * but these faults arrive via segv_handler (this function), so it
         * never fired. Same probe, correct handler.
         *
         * Open question this answers: is address 0 here a TEB offset FEX
         * spilled to a scratch reg, or a genuine guest NULL deref? Emulating
         * the wrong one silently corrupts, so DO NOT widen the discriminator
         * until this says which. An x18 spill (`mov xN,x18`) in the preceding
         * instructions => TEB access; a guest-address computation => real NULL
         * deref (cf. the Thumper 0x3f800018 case that motivated Rn==18). */
        /* ml165 (#36): RECOVER A NULL FEX STATE REGISTER (x28).
         *
         * Report #1 caught `ldr w2,[x28,#0x5d0]` faulting with x28 == 0, inside a
         * function whose prologue is `... mov x28, x0` — so FEX was ENTERED with a NULL
         * CpuStateFrame in arg0 and propagated it into STATE. Surrounding registers place
         * it mid-PartitionAlloc-reservation (x27 == 0x400010000, exactly our jumbo pool
         * size; x21/x22 look like PA hints).
         *
         * The authoritative frame pointer is available and provably correct: the CPU area
         * at TEB+0x1788 holds it at +0x30 (FEX sets CPUArea->SuspendDoorbell from the same
         * frame at Module.cpp:1443), and in the SAME process/TEB of ml165 reports #3/#4
         * carried x28 == 0x7310001140 == CPUArea+0x30. So restoring x28 from CPUArea+0x30
         * and retrying restores exactly the value FEX itself would have used.
         *
         * This mirrors the accepted x18-restore-from-TSD-275 approach. Gated hard, because
         * x28 is an ordinary callee-saved register in non-FEX code and ALL our modules run
         * from the JIT pool:
         *   - x28 must be EXACTLY 0 (not merely small),
         *   - the faulting instruction's base register must BE x28,
         *   - the fault offset must be a plausible CpuStateFrame field (< 64KB),
         *   - CPUArea+0x30 must read back non-NULL, and the target field must be readable.
         * Reads go through mach_vm_read_overwrite so a bad CPU area cannot recurse the
         * handler. pc is NOT advanced: we fix the register and re-execute.
         *
         * If this restores the wrong thing we will see it immediately — the fault was
         * fatal anyway, so recovery is strictly better than dying, and every restore is
         * logged. */
        if (REGn_sig(28, context) == 0 && (uintptr_t)pc >= 0x100000000ULL
            && ios_teb_for_signals != 0)
        {
            uintptr_t fa = (uintptr_t)siginfo->si_addr;
            uint32_t insn = *(uint32_t *)pc;

            if (((insn >> 5) & 31) == 28 && fa < 0x10000)
            {
                uint64_t cpu_area = 0, frame = 0, probe = 0;
                mach_vm_size_t got = 0;

                if (mach_vm_read_overwrite( mach_task_self(),
                        (mach_vm_address_t)(ios_teb_for_signals + 0x1788), 8,
                        (mach_vm_address_t)&cpu_area, &got ) == KERN_SUCCESS && got == 8
                    && cpu_area
                    && mach_vm_read_overwrite( mach_task_self(),
                        (mach_vm_address_t)(cpu_area + 0x30), 8,
                        (mach_vm_address_t)&frame, &got ) == KERN_SUCCESS && got == 8
                    && frame
                    && mach_vm_read_overwrite( mach_task_self(),
                        (mach_vm_address_t)(frame + fa), 8,
                        (mach_vm_address_t)&probe, &got ) == KERN_SUCCESS && got == 8
                    /* ml174: the frame must also be INITIALISED, not merely readable.
                     * Restoring a readable-but-uninitialised frame is worse than not
                     * restoring at all: in ml174 x28 was set to 0x7c80001140 and the very
                     * next instruction did `ldr x2,[x28,#0x40]` -> garbage -> `str x0,[x2]`
                     * faulted at 0x80001131, and the bogus exception frame turned a
                     * contained thread-kill into "frame not in stack limits" and killed
                     * the whole process. FEX keeps a pointer at frame+0x40 (the sequence
                     * ldr/sub #0x10/str/store-through is a stack-style push), so require
                     * it to look like a real userspace pointer before trusting the frame. */
                    && probe_ptr_ok( frame ))
                {
                    static int ios_state_restores;

                    if (ios_state_restores < 12)
                    {
                        ios_state_restores++;
                        ERR( "[state-restore] #%d pc=%p insn=%08x off=0x%lx x28=0 -> %p "
                             "(CPUArea=%p) retrying\n", ios_state_restores, pc, insn,
                             (unsigned long)fa, (void *)(uintptr_t)frame,
                             (void *)(uintptr_t)cpu_area );
                    }
                    REGn_sig(28, context) = frame;
                    return;
                }
            }
        }

        {
            uintptr_t f_addr = (uintptr_t)siginfo->si_addr;
            uint32_t f_insn = ((uintptr_t)pc >= 0x100000000ULL) ? *(uint32_t *)pc : 0;
            int f_rn = (f_insn >> 5) & 31;
            static int ios_x18_decline_reports;

            if (REGn_sig(18, context) == 0 && ios_teb_for_signals != 0
                && (uintptr_t)pc >= 0x100000000ULL && f_addr < 0x10000
                && f_rn != 18 && ios_x18_decline_reports < 4)
            {
                const uint32_t *w = (const uint32_t *)pc;
                char buf[512];
                int n = 0, k;
                ios_x18_decline_reports++;
                for (k = -16; k <= 4 && n < (int)sizeof(buf) - 16; k++)
                    n += snprintf( buf + n, sizeof(buf) - n, "%s%08x",
                                   (k == -16) ? " [" : " ", w[k] );
                snprintf( buf + n, sizeof(buf) - n, "]" );
                ERR("[x18-decline] #%d pc=%p fault_addr=0x%lx insn=%08x rn=%d "
                    "xRn=%p (rn_val==fault_addr? %d) x18=0 teb=%p\n",
                    ios_x18_decline_reports, pc, (unsigned long)f_addr, f_insn, f_rn,
                    (void *)REGn_sig(f_rn, context),
                    (uintptr_t)REGn_sig(f_rn, context) == f_addr,
                    (void *)ios_teb_for_signals);
                ERR("[x18-decline] #%d insns pc-64..pc+16:%s\n",
                    ios_x18_decline_reports, buf);

                /* ml164 follow-up: 21 instruction words were not enough to NAME the
                 * emitted stub, and source archaeology has not pinned it either. Scan a
                 * wide window for STRUCTURAL markers whose encodings are unambiguous, so
                 * the stub identifies itself:
                 *
                 *   brk #0xCAFE = 0xd4395fc0  -> Arm64JITCore::EmitSuspendInterruptCheck
                 *                                (SuspendMagic; ARCHITECTURE_arm64ec only)
                 *   brk #0x0    = 0xd4200000  -> generic trap
                 *   mrs xN, TPIDRRO_EL0 (0xd53bd060 mask) -> IOS_LOAD_TEB / x18 patcher
                 *                                trampoline, i.e. a TEB-load site
                 *   msr TPIDR_EL0 (0xd51bd040 mask) -> MUST NEVER appear (corrupts Apple
                 *                                malloc); flag loudly if it does.
                 *
                 * Read through mach_vm_read_overwrite, never a raw deref: pc may sit near
                 * the start of its mapping and a fault inside this handler would recurse. */
                {
                    static uint32_t win[320];   /* pc-1024 .. pc+256 */
                    mach_vm_size_t got = 0;
                    uintptr_t base = (uintptr_t)pc - 1024;

                    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)base,
                                                sizeof(win), (mach_vm_address_t)win,
                                                &got ) == KERN_SUCCESS && got >= 4)
                    {
                        unsigned words = (unsigned)(got / 4), j;
                        int cafe = -1, brk0 = -1, tpidrro = -1, tpidrw = -1;

                        for (j = 0; j < words; j++)
                        {
                            uint32_t v = win[j];
                            int off = (int)(j * 4) - 1024;
                            if (v == 0xd4395fc0 && cafe < 0) cafe = off;
                            else if (v == 0xd4200000 && brk0 < 0) brk0 = off;
                            if ((v & 0xffffffe0) == 0xd53bd060 && tpidrro < 0) tpidrro = off;
                            if ((v & 0xffffffe0) == 0xd51bd040 && tpidrw < 0) tpidrw = off;
                        }
                        ERR("[x18-decline] #%d markers(words=%u): brk#CAFE@%d brk#0@%d "
                            "mrs_TPIDRRO@%d msr_TPIDR_EL0@%d%s\n",
                            ios_x18_decline_reports, words, cafe, brk0, tpidrro, tpidrw,
                            tpidrw >= 0 ? "  <-- ILLEGAL TPIDR_EL0 WRITE IN THIS BLOCK" : "");

                        /* ml179: the fault is ALWAYS at offset 0x650 of a 16KB-aligned
                         * block, and FEX's whole generated dispatcher is exactly
                         * MAX_DISPATCHER_CODE_SIZE = FEX_PAGE_SIZE*4 = 16KB
                         * (Dispatcher.cpp:48). So this pc is a FIXED location in the
                         * dispatcher, and 21 instruction words were never going to name
                         * it. Dump a wide raw window instead so it can be disassembled
                         * offline against Dispatcher.cpp's emission order — that is what
                         * finally identifies the stub, with no FEX rebuild.
                         * Emitted as 8 lines of 16 words to stay readable. */
                        /* ml180: gate on the PAGE-0 fault, not on report #1. The
                         * first qualifying fault in a run is often the NULL-CS one
                         * (RtlLeaveCriticalSection, addr=0x8), which consumed the single
                         * dump last run and told us nothing about the FEX site. Also drop
                         * the "dispatcher is 16KB" wording: 16KB-alignment of the pc is
                         * arithmetic, not evidence that the block IS FEX's dispatcher. */
                        /* ml191 CALLRET PROBE. The two guest RIPs that reach this
                         * trampoline are libcef+0x1900733 and +0x3b508f0. Decoding libcef
                         * forward from 0x1900733-16 gives a clean x86 stream
                         * (mov/mov/test/je/mov/call) in which the `call` STARTS ONE BYTE
                         * BEFORE that RIP — i.e. the guest arrived MID-INSTRUCTION. FEX
                         * then decodes garbage and raises NoExecOp (PARTIAL_DECODE_INST
                         * routes to the same handler as NOEXEC_INST), which is why this
                         * looked like a permissions bug when it is really a bad control
                         * flow target.
                         *
                         * So log where the target came from: FEX's call-return prediction
                         * stack. The ml174 dump showed the push sequence
                         *   ldr x2,[x28,#0x40]; sub x2,#0x10; str x2,[x28,#0x40]; str x0,[x2]
                         * ml193: the first cut guessed frame+0x40/+0x48 from that push and
                         * was WRONG — the probe self-reported it (in_range=0, and the
                         * "entries" decoded as ASCII text), which is exactly why it was
                         * built to validate. Offsets now COMPUTED from CPUState in
                         * CoreState.h rather than inferred:
                         *   +0x00 InlineJITBlockHeader, +0x08 DeferredSignalRefCount,
                         *   +0x10 pf_raw, +0x14 af_raw, +0x18 rip,
                         *   +0x20 gregs[16] (128B, ..0x9F), +0xA0 L1Pointer, +0xA8 L1Mask,
                         *   +0xB0 callret_sp, +0xB8 callret_sp_base
                         * CPUState is the first member of CpuStateFrame, so these are
                         * frame-relative. (+0x18 rip also matches the known state[0x18]
                         * native-PC note.) */
                        if (f_addr == 0 && REGn_sig(28, context) >= 0x100000000ULL)
                        {
                            uint64_t frame = REGn_sig(28, context);
                            uint64_t sp = 0, base = 0, ent[8] = {0};
                            mach_vm_size_t g = 0;
                            int ok_sp, ok_base, ok_ent = 0;

                            ok_sp = (mach_vm_read_overwrite( mach_task_self(),
                                        (mach_vm_address_t)(frame + 0xB0), 8,
                                        (mach_vm_address_t)&sp, &g ) == KERN_SUCCESS && g == 8);
                            ok_base = (mach_vm_read_overwrite( mach_task_self(),
                                        (mach_vm_address_t)(frame + 0xB8), 8,
                                        (mach_vm_address_t)&base, &g ) == KERN_SUCCESS && g == 8);
                            if (ok_sp && sp >= 0x10000)
                                ok_ent = (mach_vm_read_overwrite( mach_task_self(),
                                            (mach_vm_address_t)sp, sizeof(ent),
                                            (mach_vm_address_t)ent, &g ) == KERN_SUCCESS);
                            {
                                uint64_t grip = 0; mach_vm_size_t g2 = 0;
                                if (mach_vm_read_overwrite( mach_task_self(),
                                        (mach_vm_address_t)(frame + 0x18), 8,
                                        (mach_vm_address_t)&grip, &g2 ) == KERN_SUCCESS)
                                    ERR("[callret] State.rip=%p\n", (void *)(uintptr_t)grip);
                            }
                            ERR("[callret] frame=%p sp=%p(ok=%d) base=%p(ok=%d) in_range=%d\n",
                                (void *)(uintptr_t)frame, (void *)(uintptr_t)sp, ok_sp,
                                (void *)(uintptr_t)base, ok_base,
                                (ok_sp && ok_base && base && sp >= base && sp < base + 0x1000000));
                            if (ok_ent)
                                ERR("[callret] top (PREDICTION HISTORY — stale/completed frames expected, NOT an unwind): %llx %llx %llx %llx %llx %llx %llx %llx\n",
                                    (unsigned long long)ent[0], (unsigned long long)ent[1],
                                    (unsigned long long)ent[2], (unsigned long long)ent[3],
                                    (unsigned long long)ent[4], (unsigned long long)ent[5],
                                    (unsigned long long)ent[6], (unsigned long long)ent[7]);
                        }

                        if (f_addr == 0 && !dumped_page0 && (dumped_page0 = 1))
                        {
                            uintptr_t blk = (uintptr_t)pc & ~0x3fffULL;
                            unsigned row;

                            ERR("[disp-dump] block=%p pc=%p offset=0x%lx (16KB-aligned window)\n",
                                (void *)blk, pc, (unsigned long)((uintptr_t)pc - blk));
                            for (row = 0; row < 8; row++)
                            {
                                /* window: pc-0x200 .. pc+0x0 , 16 words per row */
                                const uint32_t *w2 = (const uint32_t *)((uintptr_t)pc - 0x200 + row * 64);
                                int off = -0x200 + (int)(row * 64);
                                char lb[256];
                                int ln = 0, q;
                                for (q = 0; q < 16 && ln < (int)sizeof(lb) - 12; q++)
                                    ln += snprintf( lb + ln, sizeof(lb) - ln, "%08x ",
                                                    win[(0x400 + off + q * 4) / 4] );
                                (void)w2;
                                ERR("[disp-dump] +%04x: %s\n",
                                    (unsigned)((uintptr_t)pc - blk + off), lb);
                            }
                        }
                    }
                    else
                        ERR("[x18-decline] #%d marker scan unreadable at %p\n",
                            ios_x18_decline_reports, (void *)base);
                }

                /* ml159 follow-up: the fatal webhelper fault is FEX's own
                 * `movz w1,#0; ldr x1,[x1]` sitting between two
                 * SpillStaticRegs (verified against Arm64Emitter.cpp: the
                 * trailing mrs FPCR / bic NEP|AH|FIZ / msr FPCR is literally
                 * SpillStaticRegs' first emission). Probe #2 showed FEX's
                 * STATE register x28 == 0 in this process. The segv dump
                 * prints x0-x3/x8-x10/x16-x20 but NOT x21-x28, so we cannot
                 * yet tell whether the fatal site ALSO has a null STATE.
                 *
                 * FEX spills guest regs to [x28,#N] and FPRs via x10=x28+0x1c0
                 * — so if x28 is sane here, the null pointer is a separate
                 * FEX constant; if x28 is 0, the whole FEX instance is
                 * uninitialised and the fix belongs in FEX per-process init.
                 * Also walk TEB -> CPUArea (TEB+0x1788) -> +0x30, the chain
                 * the EC dispatcher uses, since that is what FEX_IOS_HOST
                 * reads via TPIDRRO_EL0 + TSD slot 275. */
                ERR("[x18-decline] #%d x21=%p x22=%p x23=%p x24=%p\n",
                    ios_x18_decline_reports,
                    (void *)REGn_sig(21, context), (void *)REGn_sig(22, context),
                    (void *)REGn_sig(23, context), (void *)REGn_sig(24, context));
                ERR("[x18-decline] #%d x25=%p x26=%p x27=%p x28(STATE)=%p lr=%p sp=%p\n",
                    ios_x18_decline_reports,
                    (void *)REGn_sig(25, context), (void *)REGn_sig(26, context),
                    (void *)REGn_sig(27, context), (void *)REGn_sig(28, context),
                    (void *)REGn_sig(30, context), (void *)SP_sig(context));
                {
                    /* Read via mach_vm_read_overwrite, never a raw deref: a
                     * fault INSIDE the segv handler would recurse and hang
                     * the app instead of dying cleanly. */
                    uintptr_t teb = ios_teb_for_signals;
                    uint64_t cpu_area = 0, ca30 = 0;
                    mach_vm_size_t got = 0;
                    int ok1 = 0, ok2 = 0;

                    if (teb)
                        ok1 = (mach_vm_read_overwrite( mach_task_self(),
                                   (mach_vm_address_t)(teb + 0x1788), 8,
                                   (mach_vm_address_t)&cpu_area, &got ) == KERN_SUCCESS
                               && got == 8);
                    if (ok1 && cpu_area)
                        ok2 = (mach_vm_read_overwrite( mach_task_self(),
                                   (mach_vm_address_t)(cpu_area + 0x30), 8,
                                   (mach_vm_address_t)&ca30, &got ) == KERN_SUCCESS
                               && got == 8);
                    ERR("[x18-decline] #%d teb=%p CPUArea(teb+0x1788)=%p(ok=%d) "
                        "CPUArea+0x30=%p(ok=%d)\n",
                        ios_x18_decline_reports, (void *)teb,
                        (void *)(uintptr_t)cpu_area, ok1,
                        (void *)(uintptr_t)ca30, ok2);
                }
            }
        }

        if (REGn_sig(18, context) == 0 && ios_teb_for_signals != 0
            && (uintptr_t)pc >= 0x100000000ULL
            && ((*(uint32_t *)pc >> 5) & 31) == 18)
        {
            REGn_sig(18, context) = ios_teb_for_signals;
            return;
        }

        /* ml1047: BUDGET PER DISTINCT PC, not per run.
         *
         * The flat "first 20" was spent before it could matter: on the iPhone 18
         * Pro 16 of the 20 detailed dumps went to ONE pc (0x16cff4660, a routine
         * null read on the dispatcher path that is handled every time), so the
         * fault that actually killed the run -- a guest store through a bad
         * pointer -- printed no registers at all and could not be attributed. Two
         * dumps per pc keeps the routine site quiet and leaves room for the
         * fault nobody has seen yet. */
        int ml1047_dump = 0;
        {
            static struct { void *pc; int n; } seen[48];
            static int nseen;
            int si;
            for (si = 0; si < nseen; si++) if (seen[si].pc == pc) break;
            if (si == nseen && nseen < 48) { seen[nseen].pc = pc; seen[nseen].n = 0; nseen++; }
            if (si < 48 && seen[si].n < 2 && segv_dump_count < 40) { seen[si].n++; ml1047_dump = 1; }
        }
        if (ml1047_dump)
        {
            segv_dump_count++;
            /* Check TPIDR_EL0 — should hold TEB if binary patcher is working */
            uint64_t tpidr_el0;
            __asm__ volatile("mrs %0, TPIDR_EL0" : "=r"(tpidr_el0));
            /* ml209: TPIDR_EL0 is INFORMATIONAL ONLY. iOS owns and zeroes it, we removed
             * our `msr TPIDR_EL0, x18` on 2026-07-04, and nothing of ours reads it — TEB
             * recovery runs off TPIDRRO_EL0 + TSD slot 275, printed below. The old
             * "(expected ...)" wording cost a debugging detour by making a garbage value
             * here look like a root cause; it is not one. */
            ERR("SEGV at pc=%p addr=%p esr=0x%llx TPIDR_EL0=%p (informational only — TEB is tsd275 below)\n",
                pc, siginfo->si_addr, (unsigned long long)esr, (void*)tpidr_el0);
            ERR("  x0=%p x1=%p x2=%p x3=%p\n",
                (void*)REGn_sig(0, context), (void*)REGn_sig(1, context),
                (void*)REGn_sig(2, context), (void*)REGn_sig(3, context));
            ERR("  x8=%p x9=%p x10=%p x16=%p x17=%p x18=%p x19=%p x20=%p\n",
                (void*)REGn_sig(8, context),
                (void*)REGn_sig(9, context), (void*)REGn_sig(10, context),
                (void*)REGn_sig(16, context), (void*)REGn_sig(17, context),
                (void*)REGn_sig(18, context), (void*)REGn_sig(19, context),
                (void*)REGn_sig(20, context));
            ERR("  fp=%p lr=%p sp=%p\n",
                (void*)FP_sig(context), (void*)REGn_sig(30, context),
                (void*)SP_sig(context));
            /* task #24: settings threads fault in the TSD-275 thunk with a
             * NULL slot despite start_thread's write. Dump the live slot +
             * base at fault time, and dladdr any dyld-cache pc/lr so Apple
             * frames name themselves. */
            {
                extern pthread_key_t ios_teb_tls_key;
                uintptr_t tsd_base_now;
                __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tsd_base_now));
                tsd_base_now &= ~7ULL;
                extern int ios_teb_tls_slot_offset;
                ERR("  [teb-tsd] base=%p offset=0x%x raw=%p teb_key_val=%p\n",
                    (void*)tsd_base_now, ios_teb_tls_slot_offset,
                    ios_teb_tls_slot_offset
                        ? *(void **)(tsd_base_now + ios_teb_tls_slot_offset) : NULL,
                    pthread_getspecific(ios_teb_tls_key));
            }
            /* ml209: the libcef-init wall. A guest PUSH faulted writing to an address
             * Wine does not own, because the guest RSP held 0x40001141 while the thread's
             * real stack was [73d2130000..73d2170000]. The faulting block was
             *   ldr x2,[x28,#0x40] / sub x2,x2,#0x10 / str x2,[x28,#0x40] / str x0,[x2]
             * so x28 is FEX's live STATE pointer and +0x40 is gregs[4] = RSP.
             *
             * Dump the whole CPUState to split the two candidates, which need opposite
             * fixes: if only RSP is implausible the guest clobbered its own stack pointer;
             * if most gregs are garbage we are executing on an uninitialised or wrong
             * CpuStateFrame. The plausible-pointer count is the discriminator, and it is
             * printed alongside the raw values so a wrong assumption here is visible
             * rather than silently believed. */
            {
                uint64_t state = REGn_sig(28, context);
                uint64_t cs[17];              /* +0x18 rip, then gregs[0..15] */
                mach_vm_size_t got = 0;

                if (state && mach_vm_read_overwrite( mach_task_self(),
                        (mach_vm_address_t)(state + 0x18), sizeof(cs),
                        (mach_vm_address_t)cs, &got ) == KERN_SUCCESS && got == sizeof(cs))
                {
                    static const char * const gn[16] = {
                        "rax","rcx","rdx","rbx","rsp","rbp","rsi","rdi",
                        "r8 ","r9 ","r10","r11","r12","r13","r14","r15" };
                    int i, plausible = 0;

                    ERR("  [guest-state] x28=%p rip=%p\n", (void*)state, (void*)cs[0]);
                    /* ml885: State.rip is only the block ENTRY. Resolve the exact
                     * guest instruction from the block tail, and show its bytes,
                     * so a fault names the x86 instruction rather than the block.
                     * A resolved RIP that does not belong to the block the return
                     * address implies means the `ret` landed in the wrong block
                     * (callret / invalidation), not that the guest read garbage. */
                    {
                        extern uint64_t ios_native_rip_from_hostpc( uint64_t, uint64_t, const char ** );
                        uint64_t bb = 0, xrip = 0; const char *why = "";
                        mach_vm_size_t g2 = 0;
                        if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)state, 8,
                                                    (mach_vm_address_t)&bb, &g2 ) == KERN_SUCCESS && g2 == 8 && bb)
                            xrip = ios_native_rip_from_hostpc( bb, (uint64_t)(uintptr_t)pc, &why );
                        if (xrip)
                        {
                            uint8_t xb[16]; mach_vm_size_t g3 = 0;
                            if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)xrip, sizeof(xb),
                                                        (mach_vm_address_t)xb, &g3 ) == KERN_SUCCESS && g3 == sizeof(xb))
                                ERR("  [guest-exact] ml885 block=%p rip=%p x86=%02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x\n",
                                    (void*)bb, (void*)xrip, xb[0],xb[1],xb[2],xb[3],xb[4],xb[5],xb[6],xb[7],xb[8],xb[9],xb[10],xb[11],xb[12],xb[13],xb[14],xb[15]);
                            else
                                ERR("  [guest-exact] ml885 block=%p rip=%p (bytes unreadable)\n", (void*)bb, (void*)xrip);
                        }
                        else ERR("  [guest-exact] ml885 block=%p unresolved: %s\n", (void*)bb, why);
                    }
                    for (i = 0; i < 16; i += 4)
                        ERR("  [guest-state]   %s=%p %s=%p %s=%p %s=%p\n",
                            gn[i],   (void*)cs[1+i], gn[i+1], (void*)cs[2+i],
                            gn[i+2], (void*)cs[3+i], gn[i+3], (void*)cs[4+i]);
                    for (i = 0; i < 16; i++)
                        if (cs[1+i] >= 0x100000000ull && cs[1+i] < 0x8000000000ull) plausible++;
                    ERR("  [guest-state] plausible-ptr gregs=%d/16 (low => uninitialised frame, "
                        "high => only rsp clobbered)\n", plausible);

                    /* ml962 (Astra step 3): capture the OPERAND, not the innocent
                     * final load.
                     *
                     * The faulting block is EMP.dll rva 0x13bd8b:
                     *   mov   rdx, [r10]          <- loads the pointer
                     *   ...
                     *   movzx r11w, byte ptr [rdx] <- faults
                     * so RDX/x1 is the faulting pointer and it was LOADED from
                     * [R10]; this block does not create it. Four runs show the
                     * fault address equals (latest allocation + 0x10) truncated to
                     * 32 bits, so something upstream discards the high half -- but
                     * NOT this block (verified: the host lowering is a 64-bit
                     * `ldapr x1,[x4]`).
                     *
                     * Printing the eight bytes actually in memory at [R10] splits
                     * the two remaining possibilities:
                     *   - operand already low in memory  => trace its WRITER;
                     *   - operand full width in memory   => the load returned low,
                     *     i.e. our own emulation/aliasing path is at fault.
                     * Failure-returning read, so an unmapped R10 cannot fault the
                     * handler. R10 has been 0x...1b6 in every run: mod 8 == 6, i.e.
                     * an UNALIGNED 8-byte access, which is why FEX's lowering is an
                     * acquire form at all and why this goes through our unaligned
                     * backpatch path. Surrounding bytes included per Astra. */
                    {
                        const uint64_t r10v = cs[1+10], rdxv = cs[1+2];
                        uint64_t at_r10 = 0;
                        unsigned char around[40];
                        mach_vm_size_t g4 = 0, g5 = 0;
                        int ok8, okA;

                        ok8 = (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)r10v, 8,
                                                       (mach_vm_address_t)&at_r10, &g4 ) == KERN_SUCCESS
                               && g4 == 8);
                        okA = (r10v >= 16) &&
                              (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(r10v - 16),
                                                       sizeof(around), (mach_vm_address_t)around,
                                                       &g5 ) == KERN_SUCCESS && g5 == sizeof(around));
                        if (ok8)
                            ERR("  [operand] ml962 R10=0x%llx (mod8=%u) [R10]=0x%016llx  RDX=0x%llx"
                                " | high32([R10])=0x%08llx %s\n",
                                (unsigned long long)r10v, (unsigned)(r10v & 7u),
                                (unsigned long long)at_r10, (unsigned long long)rdxv,
                                (unsigned long long)(at_r10 >> 32),
                                (at_r10 >> 32) ? "OPERAND IS FULL WIDTH -> the LOAD lost the high half"
                                               : "OPERAND ALREADY TRUNCATED IN MEMORY -> trace its WRITER");
                        else
                            ERR("  [operand] ml962 R10=0x%llx (mod8=%u) [R10] UNREADABLE got=%llu RDX=0x%llx\n",
                                (unsigned long long)r10v, (unsigned)(r10v & 7u),
                                (unsigned long long)g4, (unsigned long long)rdxv);
                        if (okA)
                        {
                            int bi;
                            char hex[40*3+1];
                            for (bi = 0; bi < (int)sizeof(around); bi++)
                                snprintf( hex + bi*3, 4, "%02x ", around[bi] );
                            ERR("  [operand] ml962 [R10-16 .. R10+23]: %s\n", hex);
                        }

                        /* ml965: prove the mixed-width round-trip.
                         *
                         * Offline disassembly of EMP.dll .emp1 at the verified file
                         * offset (anchored on the known bytes 49 8b 12) shows this is
                         * an OBFUSCATION VM, not a structure access:
                         *   mov rdx,[r10] / movzx r11w,[rdx] / add r10,6 /
                         *   mov word [r10],r11w / mov ebp,[r9] / add r9,4 / jmp ...
                         * r10 is a byte-stream cursor into a stack-resident VM
                         * context, advancing by 6, read 8 wide, written 2 wide. A
                         * capstone scan of 256 KB of .emp1 finds stores through that
                         * same cursor at THREE widths: 100 x 16-bit, 57 x 32-bit,
                         * 74 x 64-bit. So a value written narrow and read wide picks
                         * up whatever adjoins it -- which is exactly the observed
                         * (alloc + 0x10) with a zero high half, 5 runs running.
                         *
                         * What is still unproven is that THIS pointer went in through
                         * a narrow slot. Scan a wider window of the stream for the
                         * low 32 bits and report, for each occurrence, what follows:
                         * 0x00000001 means a full-width copy also exists in the
                         * stream (so the wide write happened and something else is
                         * wrong), zeros mean the only copy is narrow (round-trip
                         * confirmed). Bounded window, failure-returning read. */
                        {
                            unsigned char win[256];
                            mach_vm_size_t g6 = 0;
                            const uint64_t lo32 = (uint64_t)(uint32_t)at_r10;

                            if (ok8 && lo32 && r10v >= 128 &&
                                mach_vm_read_overwrite( mach_task_self(),
                                                        (mach_vm_address_t)(r10v - 128),
                                                        sizeof(win), (mach_vm_address_t)win,
                                                        &g6 ) == KERN_SUCCESS && g6 == sizeof(win))
                            {
                                int wi, found = 0;
                                for (wi = 0; wi + 8 <= (int)sizeof(win); wi++)
                                {
                                    uint32_t v32;
                                    uint32_t nxt;
                                    memcpy( &v32, win + wi, 4 );
                                    if (v32 != (uint32_t)lo32) continue;
                                    memcpy( &nxt, win + wi + 4, 4 );
                                    found++;
                                    ERR("  [stream] ml965 low32=0x%08x found at R10%+d, next 4 bytes = 0x%08x -- %s\n",
                                        (unsigned)v32, wi - 128, (unsigned)nxt,
                                        (nxt == 1u) ? "FULL-WIDTH copy present (wide write DID happen)"
                                        : (nxt == 0u) ? "adjoined by zeros (consistent with a narrow slot; "
                                                        "does NOT identify the writing instruction)"
                                                      : "adjoined by unrelated stream bytes");
                                    if (found >= 6) break;
                                }
                                if (!found)
                                    ERR("  [stream] ml965 low32=0x%08x not found anywhere in [R10-128,R10+128)\n",
                                        (unsigned)lo32);
                            }
                        }
                    }

                    /* ml212: NAME THE CALLER.
                     *
                     * The guest RIP is <arena>+0xe0080 — an address with no code — so FEX
                     * raised SIGSEGV through its deliberate `mov w1,#0; ldr x1,[x1]`
                     * trampoline (visible in insn_stream above). Nothing is corrupt: the
                     * CpuStateFrame is valid and the fault is FEX correctly reporting a
                     * bogus branch target. The open question is who branched there, and
                     * that offset has been byte-identical across runs and across three
                     * different arena bases, so it is computed, not random.
                     *
                     * FEX keeps guest return addresses on its callret stack
                     * (CPUState+0xB0 = sp, +0xB8 = base). Dump the top entries; resolving
                     * them offline against the [iOS-xins]/[jit-pool] bases names the
                     * function that jumped. Depth is printed too, so an empty or absurd
                     * stack is visible rather than silently mistaken for evidence. */
                    {
                        uint64_t cr[2] = { 0, 0 };
                        uint64_t ents[8];
                        mach_vm_size_t g2 = 0;

                        if (mach_vm_read_overwrite( mach_task_self(),
                                (mach_vm_address_t)(state + 0xB0), sizeof(cr),
                                (mach_vm_address_t)cr, &g2 ) == KERN_SUCCESS && g2 == sizeof(cr))
                        {
                            /* ml381 UNITS FIX. This printed (sp - base) / 8 and
                             * called it "depth", which is wrong twice over: the
                             * stack starts at base + 4MB (DefaultLocation) and
                             * grows DOWN, and entries are 16 bytes, not 8. An
                             * EMPTY stack therefore printed depth=524288 — and I
                             * read ml377's 500262 and ml380's 522626 as a
                             * half-million-entry LEAK and proposed chasing task
                             * #42, when the true occupancies were 12,013 and 831
                             * entries (4.6% and 0.3% of the window). Print what
                             * is actually being asked — entries USED — so it
                             * cannot be misread again. */
                            unsigned long long dflt = cr[1] + 0x400000;
                            unsigned long long used_b = (dflt > cr[0]) ? dflt - cr[0] : 0;

                            ERR("  [callret] sp=%p base=%p default=%p used=%llu entries (%llu bytes, %llu%% of 4MB)\n",
                                (void *)cr[0], (void *)cr[1], (void *)(uintptr_t)dflt,
                                used_b / 16, used_b, (used_b * 100) / 0x400000 );

                            /* ml213: the cap was 0x100000, but a real run had depth=168218
                             * (1.28MB of stack) and the dump was skipped for no good
                             * reason — only the TOP n*8 bytes are ever read, so the total
                             * size never mattered. Bound it generously, purely as a
                             * sanity check against a garbage sp/base pair. */
                            if (used_b && cr[0] - cr[1] <= 0x10000000)
                            {
                                /* ml381: qwords to dump from the top of the
                                 * stack — 2 qwords per 16-byte entry. */
                                unsigned long long qw = (used_b / 8);
                                unsigned n = qw > 8 ? 8 : (unsigned)qw;

                                if (mach_vm_read_overwrite( mach_task_self(),
                                        (mach_vm_address_t)(cr[0] - (uint64_t)n * 8),
                                        n * 8, (mach_vm_address_t)ents, &g2 ) == KERN_SUCCESS
                                    && g2 == n * 8)
                                {
                                    unsigned k;

                                    for (k = n; k-- > 0; )
                                        ERR("  [callret]   [-%u] %p\n", n - k, (void *)ents[k]);
                                }
                            }
                        }
                    }
                }
                else
                    ERR("  [guest-state] x28=%p UNREADABLE got=%llu\n",
                        (void*)state, (unsigned long long)got);
            }
            {
                uintptr_t sym_addrs[2] = { (uintptr_t)PC_sig(context), (uintptr_t)REGn_sig(30, context) };
                int si;
                for (si = 0; si < 2; si++)
                {
                    Dl_info di_s;
                    const char *img_s;
                    if (sym_addrs[si] >= 0x180000000ULL && (sym_addrs[si] >> 32) < 0x300 &&
                        dladdr((void *)sym_addrs[si], &di_s) && di_s.dli_sname)
                    {
                        img_s = di_s.dli_fname ? strrchr(di_s.dli_fname, '/') : NULL;
                        img_s = img_s ? img_s + 1 : (di_s.dli_fname ? di_s.dli_fname : "?");
                        ERR("  [sym] %s=%s`%s+0x%llx\n", si ? "lr" : "pc", img_s,
                            di_s.dli_sname,
                            (unsigned long long)(sym_addrs[si] - (uintptr_t)di_s.dli_saddr));
                    }
                }
            }
            if ((uintptr_t)PC_sig(context) >= 0x100000000ULL)
            {
                uint32_t *p = (uint32_t*)(uintptr_t)PC_sig(context);
                /* ml265 (#46): WIDE window when the fault PC is FEX-emitted code.
                 *
                 * The ml265 fatal is a DELIBERATE null deref in the dispatcher:
                 *   52800001  movz w1, #0        <- x1 set to 0 literally
                 *   f9400021  ldr  x1, [x1]      <- FAULTS
                 *   d53b440a  mrs  x10, fpcr     (FP-control setup)
                 * preceded by two `st1` SIMD stores -- the dispatcher's FP-save
                 * sequence. pc sits at pool offset 0x36ff8650, the tail EC_CODE area,
                 * i.e. code FEX EMITTED, not translated guest code.
                 *
                 * That matters because this port already patches "FEX's emitter on iOS
                 * produces garbage words in the dispatcher" (Module.cpp SpillStaticRegs
                 * scanner), whose own comment notes mis-patching "causes st1 faults
                 * later". 7 words is too narrow to tell a genuine emit from a corrupted
                 * one, and the offset relative to the dispatcher decides which documented
                 * site (+0x160 / +0x184 / +0x264) this is. Dump 24 words with the pool
                 * offset so the emitted sequence can be read offline against the
                 * expected layout. Capped; only for pool PCs. */
                {
                    extern void *ios_jit_rx_base_global;
                    extern size_t ios_jit_pool_size_global;
                    uintptr_t rxb = (uintptr_t)ios_jit_rx_base_global;
                    uintptr_t fpc = (uintptr_t)PC_sig(context);
                    static int wide_dumps;

                    if (rxb && fpc >= rxb && fpc < rxb + ios_jit_pool_size_global &&
                        wide_dumps < 4)
                    {
                        const uint32_t *w = (const uint32_t *)(fpc - 48);
                        int i;
                        wide_dumps++;
                        ERR("  [emit-dump] pc=0x%llx pooloff=0x%llx  PC-48..PC+44:\n",
                            (unsigned long long)fpc, (unsigned long long)(fpc - rxb));
                        for (i = 0; i < 24; i += 6)
                            ERR("  [emit-dump]   +%-4d %08x %08x %08x %08x %08x %08x\n",
                                (i - 12) * 4, w[i], w[i+1], w[i+2], w[i+3], w[i+4], w[i+5]);
                    }
                }
                /* ml270 (#48): WHERE does the corrupt guest RSP come from?
                 *
                 * Signature across runs: RSP alone is garbage while the other guest
                 * registers stay valid -- "plausible-ptr gregs=11/16", and the probe's own
                 * legend reads "high => only rsp clobbered". The bad value is structured,
                 * not random:
                 *   ml260 rsp=0x40001131  addr=0x40001131  addr=0xe0001131
                 *   ml270 rsp=0x80001131  addr=0x80001131
                 * low 28 bits constant at 0x0001131, only the TOP NIBBLE varies (4/8/e) --
                 * which is where ARM64 NZCV lives (4=Z, 8=N, e=NZC).
                 *
                 * In ARM64EC guest RSP is SRA register x23, spilled/filled via
                 * State.gregs[RSP]. Three outcomes need different fixes:
                 *   x23 garbage but gregs[RSP] VALID  -> a fill/spill bug clobbered the reg
                 *   both garbage                       -> corruption happened earlier
                 *   top nibble == flags[24] (NZCV)     -> a FLAGS word is being used as RSP
                 * Print all three rather than pattern-matching hex, which has misled before. */
                {
                    static int rspq;
                    /* Get the TEB the same way the [tsd275] dump above does — a POSIX
                     * signal handler has no mach thread_t to hand, and x18 is zero here. */
                    uintptr_t tsd_r;
                    uintptr_t teb_r;
                    __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tsd_r));
                    tsd_r &= ~7ULL;
                    teb_r = ios_teb_tls_slot_offset
                        ? (uintptr_t)*(void **)(tsd_r + ios_teb_tls_slot_offset) : 0;

                    /* ml558: this probe KILLED ml557.
                     *
                     * TSD slot 275 is not ours -- pthread_exit_wrapper's own comment
                     * says so. On a NATIVE (non-wine) thread some Apple framework's
                     * value sits there, we read it as a TEB, and TEB+0x1788 came back
                     * 0x40; *(0x40+0x30) faulted at 0x70 inside the signal handler.
                     *
                     * Worse, the `rspq < 6` cap could never engage: rspq++ was BELOW
                     * the faulting load, so the counter never advanced and the probe
                     * re-faulted forever (5,000+ times in ml557) until the fault-stuck
                     * breaker diverted the thread into abort_thread.
                     *
                     * Two rules restored: (1) only look at TSD 275 on a thread we
                     * actually registered, (2) SPEND THE BUDGET FIRST -- increment
                     * before the risky deref, so a fault can cost at most 6 tries. */
                    if (rspq < 6 && ios_teb_is_registered(teb_r))
                    {
                        void *cpuarea_r;
                        rspq++;                       /* spend it BEFORE we can fault */
                        cpuarea_r = *(void**)(teb_r + 0x1788);
                        if ((uintptr_t)cpuarea_r < 0x10000)
                        {
                            ERR("  [rsp-trunc] cpuarea=%p implausible (TSD275 not a wine TEB) "
                                "-- skipping deref rev=ml558\n", cpuarea_r);
                            cpuarea_r = NULL;
                        }
                        if (cpuarea_r)
                        {
                            uint64_t *frame_r = *(uint64_t**)((char*)cpuarea_r + 0x30);
                            if (frame_r)
                            {
                                /* ml272: offsets CONFIRMED from FEX's own [state-offsets]
                                 * line -- rip=0x18 gregs=0x20 gregs[RSP]=0x40
                                 * callret_sp=0xb0 callret_sp_base=0xb8 flags=0x3f0.
                                 * The first cut of this probe read gregs[RSP] at 0x28,
                                 * which is gregs[1] = RCX, so every "gregs[RSP]=0" it
                                 * printed was meaningless. Also print callret_sp, since
                                 * the dispatcher's `ldr x17,[x28,#176]` reads exactly
                                 * that field and x17==0 is the #42 storm's trigger. */
                                ERR("  [rsp-forensics] x23(SRA RSP)=%p  gregs[RSP]=%p  "
                                    "NZCV/flags[24]=0x%08x  callret_sp=%p base=%p  x28=%p%s\n",
                                    (void*)(uintptr_t)REGn_sig(23, context),
                                    (void*)(uintptr_t)frame_r[0x40/8],
                                    (unsigned)((uint32_t*)frame_r)[0x408/4],
                                    (void*)(uintptr_t)frame_r[0xb0/8],
                                    (void*)(uintptr_t)frame_r[0xb8/8],
                                    (void*)frame_r,
                                    frame_r[0xb0/8] ? "" : "  <== callret_sp is ZERO (#42 trigger)");
                            }
                        }
                    }
                }
                /* iOS-Madeira ml329 (#53 discriminator): on a NULL-ish deref -- the exact
                 * shape of the IntrusivePooledAllocator crash (a list node read at
                 * offset 8 of a NULL `next`) -- state whether iOS zero-filled any page of
                 * FEX's host heap this run. Prints the verdict either way, so a run with
                 * no FEX-band recovery is a real negative that REFUTES #53 for this crash
                 * rather than silence. */
                if (siginfo->si_addr && (uintptr_t)siginfo->si_addr < 0x1000)
                {
                    extern void ios_reclaim_pages_report( const char *when, unsigned long long fault_addr );
                    ios_reclaim_pages_report( "fatal-segv", (unsigned long long)(uintptr_t)siginfo->si_addr );
                }
                ERR("  insn_stream PC-12..PC+8: %08x %08x %08x [%08x] %08x %08x %08x\n",
                    p[-3], p[-2], p[-1], p[0], p[1], p[2], p[3]);
            }
            else
                ERR("  insn=<unmappable PC, skipping read>\n");
            /* For tiny PC SEGVs through arm64x_check_call: probe LR-4 to
             * find the BLR that set up x11, and dump EC bitmap bit for x11
             * so we can see whether the bitmap fast-path should have taken
             * us out of arm64x_check_call. */
            if ((uintptr_t)PC_sig(context) < 0x100000000ULL)
            {
                extern PEB *peb;
                uintptr_t lr_val = (uintptr_t)REGn_sig(30, context);
                uintptr_t x11_at_seg = (uintptr_t)REGn_sig(11, context);
                ERR("  x11=%p lr=%p\n", (void*)x11_at_seg, (void*)lr_val);
                /* Decode the branch instruction at lr-4 to identify which
                 * register held the BR target at the time of the branch. */
                if (lr_val >= 0x100000004ULL)
                {
                    uint32_t branch_insn = *(uint32_t*)(lr_val - 4);
                    ERR("  branch@(lr-4)=%08x", branch_insn);
                    /* BR/BLR encoding: D61F0xxx (BR) or D63F0xxx (BLR) where
                     * bits 9:5 = Rn. */
                    if ((branch_insn & 0xFFFE0FFF) == 0xD61F0000) {
                        int rn = (branch_insn >> 5) & 0x1f;
                        ERR("    → BR x%d", rn);
                    } else if ((branch_insn & 0xFFFE0FFF) == 0xD63F0000) {
                        int rn = (branch_insn >> 5) & 0x1f;
                        ERR("    → BLR x%d", rn);
                    }
                    ERR("\n");
                    /* Dump 4 insns before the BLR — usually ADRP/ADRPL+LDR
                     * loading x16 from a dispatcher slot. Decode the slot
                     * address and the pointer it currently contains. */
                    if (lr_val >= 0x100000010ULL)
                    {
                        uint32_t i0 = *(uint32_t*)(lr_val - 16);
                        uint32_t i1 = *(uint32_t*)(lr_val - 12);
                        uint32_t i2 = *(uint32_t*)(lr_val - 8);
                        ERR("  call_site@(lr-16): %08x %08x %08x %08x\n",
                            i0, i1, i2, branch_insn);
                        /* Scan i0..i2 for an ADRP and following LDR loading
                         * x16, the BLR target. */
                        uint32_t insns[4] = { i0, i1, i2, branch_insn };
                        uintptr_t insn_pcs[4] = {
                            lr_val - 16, lr_val - 12, lr_val - 8, lr_val - 4 };
                        for (int k = 0; k < 3; k++)
                        {
                            uint32_t adrp = insns[k];
                            /* ADRP encoding: 1 | immlo[2] | 10000 | immhi[19] | Rd[5] */
                            if ((adrp & 0x9f000000) != 0x90000000) continue;
                            int rd = adrp & 0x1f;
                            int64_t immhi = (int64_t)((adrp >> 5) & 0x7ffff);
                            int64_t immlo = (int64_t)((adrp >> 29) & 3);
                            int64_t imm21 = (immhi << 2) | immlo;
                            if (imm21 & (1LL << 20)) imm21 |= (int64_t)0xffffffffffe00000;
                            uintptr_t adrp_pc = insn_pcs[k] & ~0xfffULL;
                            uintptr_t adrp_target = adrp_pc + (imm21 << 12);
                            ERR("    ADRP x%d → page %p (insn[%d]=%08x)\n",
                                rd, (void*)adrp_target, k, adrp);
                            /* Look for matching LDR in following insns. */
                            for (int m = k + 1; m < 4; m++)
                            {
                                uint32_t ldr = insns[m];
                                if ((ldr & 0xffc00000) != 0xf9400000) continue;
                                int rn_ldr = (ldr >> 5) & 0x1f;
                                int rt_ldr = ldr & 0x1f;
                                if (rn_ldr != rd) continue;
                                uint32_t imm12 = (ldr >> 10) & 0xfff;
                                uintptr_t slot_addr = adrp_target + (imm12 * 8);
                                ERR("    LDR x%d, [x%d, #0x%x] → slot=%p\n",
                                    rt_ldr, rn_ldr, imm12 * 8, (void*)slot_addr);
                                if (slot_addr >= 0x100000000ULL)
                                {
                                    void *slot_val = *(void**)slot_addr;
                                    extern uintptr_t ios_jit_reverse_translate_addr(void *addr);
                                    uintptr_t parent_slot = ios_jit_reverse_translate_addr((void*)slot_addr);
                                    void *parent_val = (parent_slot && parent_slot != slot_addr)
                                        ? *(void**)parent_slot : NULL;
                                    ERR("    JIT *slot = %p   parent@%p *slot = %p (expected %p)\n",
                                        slot_val, (void*)parent_slot, parent_val,
                                        peb ? peb->WerRegistrationData : NULL);
                                }
                                break;
                            }
                            break;
                        }
                    }
                }
                if (peb && peb->EcCodeBitMap && x11_at_seg >= 0x100000000ULL)
                {
                    uint64_t *bm = (uint64_t *)peb->EcCodeBitMap;
                    size_t page = x11_at_seg >> 12;
                    size_t blk  = page / 64;
                    int bit_in_blk = page & 63;
                    uint64_t blk_val = bm[blk];
                    int bit_set = (blk_val >> bit_in_blk) & 1;
                    ERR("  EcBitMap@%p: x11_page=0x%lx blk[%lx]=%llx bit=%d %s\n",
                        bm, (unsigned long)page, (unsigned long)blk,
                        (unsigned long long)blk_val, bit_set,
                        bit_set ? "(EC: fast-path SHOULD have taken)" : "(NOT EC: dispatch path taken)");
                }
                /* Dump the first 12 bytes at x11 (the called function's prologue)
                 * and at JIT-pool ntdll's __wine_dbg_header offset 0x5ed5c (the
                 * `ldr x11, [x18, #0x60]` instruction) to see whether our x18
                 * patcher replaced it with a B to a trampoline. */
                if (x11_at_seg >= 0x100000000ULL)
                {
                    uint32_t *p = (uint32_t *)x11_at_seg;
                    ERR("  callee prologue: %08x %08x %08x %08x\n",
                        p[0], p[1], p[2], p[3]);
                    /* If x11 is in __wine_dbg_header (0x5ed24), the LDR at
                     * +0x38 = +0xe (instr 14) is the patched one. Show it. */
                    uint32_t patched = p[14];
                    ERR("  callee[+0x38]=%08x (LDR x11,[x18,#0x60] should be B-tramp if patched)\n",
                        patched);
                    /* If patched is a B (top 6 bits = 0x05 = 0b000101), decode
                     * the target and dump trampoline bytes there. */
                    if ((patched >> 26) == 5)
                    {
                        int32_t imm26 = (int32_t)(patched & 0x3FFFFFF);
                        if (imm26 & 0x2000000) imm26 |= (int32_t)0xFC000000; /* sign-ext */
                        intptr_t b_target = (intptr_t)(&p[14]) + ((intptr_t)imm26 << 2);
                        if (b_target >= 0x100000000LL)
                        {
                            uint32_t *t = (uint32_t *)b_target;
                            ERR("  tramp@%p: %08x %08x %08x %08x %08x %08x %08x\n",
                                (void*)b_target, t[0], t[1], t[2], t[3], t[4], t[5], t[6]);
                        }
                        else
                        {
                            ERR("  tramp_target=%p (out of range, B-encoding bad)\n",
                                (void*)b_target);
                        }
                    }
                    /* Search the whole prologue for any instructions where bits
                     * encode 0x39cc-style tiny RVA — could the prologue itself
                     * contain a corrupted instruction whose immediate field is
                     * the target we ended up at? */
                    {
                        uintptr_t bad_pc = (uintptr_t)PC_sig(context);
                        for (int s = 0; s < 32; s++)
                        {
                            if ((p[s] & 0xfffff) == (bad_pc & 0xfffff))
                            {
                                ERR("  callee[+0x%02x]=%08x has imm matching bad PC low20\n",
                                    s*4, p[s]);
                                break;
                            }
                        }
                    }
                }
                /* Dump arm64x_check_call's first 8 instructions in JIT pool. We
                 * are crashing INSIDE that function (BLR x16 at lr-4). Its first
                 * instruction is `ldr x16, [x18, #0x60]` — the ONE x18-using
                 * insn in its body. The x18 patcher should have replaced it with
                 * a B to a trampoline. If the B's target decodes outside the JIT
                 * pool's trampoline area, that's the bug.
                 * Address is stashed in peb->WerRegistrationData by Wine's
                 * arm64ec_process_init. */
                {
                    uint32_t *cc = peb ? (uint32_t *)peb->WerRegistrationData : NULL;
                    if ((uintptr_t)cc >= 0x100000000ULL)
                    {
                        ERR("  arm64x_check_call@%p: %08x %08x %08x %08x %08x %08x %08x %08x\n",
                            cc, cc[0], cc[1], cc[2], cc[3], cc[4], cc[5], cc[6], cc[7]);
                        /* If cc[0] is a B (top 6 bits = 0x05 = 0b000101), decode
                         * its target and dump the trampoline contents there. */
                        if ((cc[0] >> 26) == 5)
                        {
                            int32_t imm26 = (int32_t)(cc[0] & 0x3FFFFFF);
                            if (imm26 & 0x2000000) imm26 |= (int32_t)0xFC000000;
                            intptr_t b_target = (intptr_t)cc + ((intptr_t)imm26 << 2);
                            ERR("    cc[0] is B → target=%p (delta=%d insns)\n",
                                (void*)b_target, (int)imm26);
                            if (b_target >= 0x100000000LL)
                            {
                                uint32_t *t = (uint32_t *)b_target;
                                ERR("    cc-tramp@%p: %08x %08x %08x %08x %08x %08x %08x\n",
                                    (void*)b_target, t[0], t[1], t[2], t[3], t[4], t[5], t[6]);
                            }
                            else
                            {
                                ERR("    cc-tramp out of range — B encoding bad\n");
                            }
                        }
                        else
                        {
                            ERR("    cc[0] is NOT a B (opcode top6=%d) — patcher missed it\n",
                                (cc[0] >> 26));
                        }
                    }
                    else
                    {
                        ERR("  __os_arm64x_check_call=%p (not set or bad)\n", cc);
                    }
                }
            }
            /* Dump cpu_area (TEB.ChpeV2CpuAreaInfo) when PC is unmappable.
             * x17 typically holds cpu_area after enter_jit's chained loads,
             * so when we hit a tiny PC right after BR x16, x17 should still
             * have it. Bound-check x17 looks like a ~0x1xxxxxxxx pointer. */
            if ((uintptr_t)PC_sig(context) < 0x100000000ULL)
            {
                uintptr_t cpu_area_p = (uintptr_t)REGn_sig(17, context);
                if (cpu_area_p >= 0x100000000ULL && cpu_area_p < 0x800000000000ULL)
                {
                    uint64_t *ca = (uint64_t *)cpu_area_p;
                    ERR("  cpu_area@%p: [0x00]=%llx [0x08]=%llx [0x10]=%llx [0x18]=%llx\n",
                        (void*)cpu_area_p,
                        (unsigned long long)ca[0], (unsigned long long)ca[1],
                        (unsigned long long)ca[2], (unsigned long long)ca[3]);
                    ERR("              [0x20]=%llx [0x28]=%llx [0x30]=%llx [0x38]=%llx\n",
                        (unsigned long long)ca[4], (unsigned long long)ca[5],
                        (unsigned long long)ca[6], (unsigned long long)ca[7]);
                    ERR("              [0x40]=%llx [0x48]=%llx [0x50]=%llx [0x58]=%llx\n",
                        (unsigned long long)ca[8], (unsigned long long)ca[9],
                        (unsigned long long)ca[10], (unsigned long long)ca[11]);
                }
            }
        }
    }
#endif
    rec.NumberParameters = 2;
    if ((esr & 0xf0000000) == 0x80000000) rec.ExceptionInformation[0] = EXCEPTION_EXECUTE_FAULT;
    else if (esr & 0x40) rec.ExceptionInformation[0] = EXCEPTION_WRITE_FAULT;
    else rec.ExceptionInformation[0] = EXCEPTION_READ_FAULT;
    rec.ExceptionInformation[1] = (ULONG_PTR)siginfo->si_addr;
#ifdef WINE_IOS
    {
        static uintptr_t last_fault_pc = 0;
        static int fault_repeat_count = 0;
        uintptr_t this_pc = PC_sig(context);
        if (this_pc == last_fault_pc)
        {
            fault_repeat_count++;
            static unsigned long loop_storm;
            if (fault_repeat_count == 3 && ios_sig_storm_gate( &loop_storm ))
            {
                ERR("SEGV LOOP DETECTED: pc=%p addr=%p repeated %d times, dumping TEB+PEB\n",
                    (void*)this_pc, siginfo->si_addr, fault_repeat_count);
                /* Dump TEB */
                if (ios_teb_for_signals)
                {
                    uint64_t *teb = (uint64_t *)ios_teb_for_signals;
                    ERR("  TEB[0x00]=%p TEB[0x08]=%p TEB[0x10]=%p TEB[0x18]=%p\n",
                        (void*)teb[0], (void*)teb[1], (void*)teb[2], (void*)teb[3]);
                    ERR("  TEB[0x20]=%p TEB[0x28]=%p TEB[0x30]=%p TEB[0x38]=%p\n",
                        (void*)teb[4], (void*)teb[5], (void*)teb[6], (void*)teb[7]);
                    ERR("  TEB[0x40]=%p TEB[0x48]=%p TEB[0x50]=%p TEB[0x58]=%p\n",
                        (void*)teb[8], (void*)teb[9], (void*)teb[10], (void*)teb[11]);
                    ERR("  TEB[0x60]=%p TEB[0x68]=%p TEB[0x70]=%p TEB[0x78]=%p\n",
                        (void*)teb[12], (void*)teb[13], (void*)teb[14], (void*)teb[15]);
                    /* Dump PEB (TEB+0x60 is PEB pointer) */
                    uint64_t peb_addr = teb[12]; /* TEB[0x60] */
                    if (peb_addr > 0x10000)
                    {
                        uint64_t *peb = (uint64_t *)peb_addr;
                        ERR("  PEB @ %p:\n", (void*)peb_addr);
                        ERR("  PEB[0x00]=%p PEB[0x08]=%p PEB[0x10]=%p PEB[0x18]=%p\n",
                            (void*)peb[0], (void*)peb[1], (void*)peb[2], (void*)peb[3]);
                        ERR("  PEB[0x20]=%p PEB[0x28]=%p PEB[0x30]=%p PEB[0x38]=%p\n",
                            (void*)peb[4], (void*)peb[5], (void*)peb[6], (void*)peb[7]);
                        ERR("  PEB[0x40]=%p PEB[0x48]=%p PEB[0x50]=%p PEB[0x58]=%p\n",
                            (void*)peb[8], (void*)peb[9], (void*)peb[10], (void*)peb[11]);
                        ERR("  PEB[0x60]=%p PEB[0x68]=%p PEB[0x70]=%p PEB[0x78]=%p\n",
                            (void*)peb[12], (void*)peb[13], (void*)peb[14], (void*)peb[15]);
                        /* Dump PEB->Ldr (PEB+0x18) if it looks valid */
                        uint64_t ldr_addr = peb[3]; /* PEB[0x18] */
                        ERR("  PEB->Ldr = %p\n", (void*)ldr_addr);
                        if (ldr_addr > 0x10000)
                        {
                            uint64_t *ldr = (uint64_t *)ldr_addr;
                            ERR("  LDR[0x00]=%p LDR[0x08]=%p LDR[0x10]=%p LDR[0x18]=%p\n",
                                (void*)ldr[0], (void*)ldr[1], (void*)ldr[2], (void*)ldr[3]);
                            ERR("  LDR[0x20]=%p LDR[0x28]=%p LDR[0x30]=%p LDR[0x38]=%p\n",
                                (void*)ldr[4], (void*)ldr[5], (void*)ldr[6], (void*)ldr[7]);
                        }
                        else
                        {
                            ERR("  PEB->Ldr is INVALID (0x%lx)!\n", (unsigned long)ldr_addr);
                        }
                    }
                }
            }
            if (fault_repeat_count >= 5)
            {
                ERR("SEGV LOOP FATAL: pc=%p addr=%p after %d repeats, forcing thread exit\n",
                    (void*)this_pc, siginfo->si_addr, fault_repeat_count);
                /* Skip the faulting instruction and set return value to indicate failure */
                PC_sig(context) = PC_sig(context) + 4;
                REGn_sig(0, context) = 0xDEAD0001;
                ios_fixup_x18_for_return( context );
                last_fault_pc = 0;
                fault_repeat_count = 0;
                return;
            }
        }
        else
        {
            last_fault_pc = this_pc;
            fault_repeat_count = 1;
        }
    }
#endif
#ifdef WINE_IOS
    /* ml938: an access to a sub-floor image window -- a mapping iOS refuses to
     * let us create, emulated instead. Checked BEFORE virtual_handle_fault
     * because the gate cannot collide with anything: the address is below 4GB,
     * and nothing in this task -- Wine view, FEX arena, JIT pool or foreign
     * mmap -- can be mapped there at all. An encoding we do not recognise
     * falls straight through to the path below, unchanged. */
    {
        extern void *ios_jit_rx_base_global;
        extern size_t ios_jit_pool_size_global;
        uintptr_t sg_pc = (uintptr_t)PC_sig(context);
        uintptr_t sg_rx = (uintptr_t)ios_jit_rx_base_global;
        size_t sg_sz = ios_jit_pool_size_global;

        /* ml939: only for a NON-pool PC. A pool PC has to resume through the
         * x18 trampoline, which clobbers x17 = FEX's callret stack pointer, so
         * servicing it here would trade a clean fault for silent FEX-state
         * corruption -- measured in ml938. Those come through the Mach handler
         * instead, which sets thread state directly. */
        if (!(sg_rx && sg_pc >= sg_rx && sg_pc < sg_rx + sg_sz) &&
            ios_subfloor_service( context, siginfo->si_addr, "segv", ios_jit_current_peb() ))
        {
            PC_sig(context) = PC_sig(context) + 4;
            ios_fixup_x18_for_return( context );
            return;
        }
    }
#endif
    if (!virtual_handle_fault( &rec, (void *)SP_sig(context) ))
    {
#ifdef WINE_IOS
        ERR("virtual_handle_fault HANDLED addr=%p\n", siginfo->si_addr);
        ios_fixup_x18_for_return( context );
#endif
        return;
    }
    if (handle_syscall_fault( context, &rec ))
    {
#ifdef WINE_IOS
        ios_fixup_x18_for_return( context );
#endif
        return;
    }
#ifdef WINE_IOS
    ERR("setup_exception for SEGV at pc=%p addr=%p (virtual_handle_fault failed)\n",
        (void*)PC_sig(context), siginfo->si_addr);
    /* Steam S3 (task #29): name the native faulting code + the target
     * memory region so the unhandled-write fault is diagnosable. */
    {
        extern void ios_dump_fault_region( void *addr );
        Dl_info di;
        uint64_t pcv = (uint64_t)PC_sig(context);
        if (dladdr( (void *)(uintptr_t)pcv, &di ) && di.dli_fname)
            dprintf( 2, "[fault-pc] pc=%p = %s`%s+0x%llx (img base %p, slide-relative)\n",
                     (void *)(uintptr_t)pcv, di.dli_fname,
                     di.dli_sname ? di.dli_sname : "?",
                     (unsigned long long)(pcv - (uint64_t)(uintptr_t)(di.dli_saddr ? di.dli_saddr : di.dli_fbase)),
                     di.dli_fbase );
        ios_dump_fault_region( siginfo->si_addr );
    }
#endif
    setup_exception( context, &rec );
}


/**********************************************************************
 *		ill_handler
 *
 * Handler for SIGILL.
 */
static void ill_handler( int signal, siginfo_t *siginfo, void *sigcontext )
{
    EXCEPTION_RECORD rec = { EXCEPTION_ILLEGAL_INSTRUCTION };
    ucontext_t *context = sigcontext;
#ifdef WINE_IOS
    const int ill_dbg_ok = ios_make_wine_logging_safe();  /* ml375: before any ERR */
    ios_track_signal( signal, context );
    if (ill_dbg_ok) ERR("ILL at pc=%p\n", (void*)PC_sig(context));
    else dprintf( 2, "ILL at pc=%p (no TEB — wine logging unsafe)\n", (void*)PC_sig(context) );
    {
        /* iOS-Madeira diagnostic: when we ILL on a zero/empty page, dump full
         * register state + walk back FP chain to find who BR'd here. */
        uint64_t pc  = (uint64_t)PC_sig(context);
        uint64_t lr  = (uint64_t)REGn_sig(30, context);
        uint64_t fp  = (uint64_t)REGn_sig(29, context);
        uint64_t sp  = (uint64_t)arm_thread_state64_get_sp(context->uc_mcontext->__ss);
        uint64_t x0  = (uint64_t)REGn_sig(0,  context);
        uint64_t x9  = (uint64_t)REGn_sig(9,  context);
        uint64_t x16 = (uint64_t)REGn_sig(16, context);
        uint64_t x17 = (uint64_t)REGn_sig(17, context);
        uint64_t x18 = (uint64_t)REGn_sig(18, context);
        uint64_t x19 = (uint64_t)REGn_sig(19, context);
        ERR("ILL diag: pc=0x%llx lr=0x%llx fp=0x%llx sp=0x%llx\n",
            (unsigned long long)pc, (unsigned long long)lr,
            (unsigned long long)fp, (unsigned long long)sp);
        ERR("ILL diag: x0=0x%llx x9=0x%llx x16=0x%llx x17=0x%llx x18=0x%llx x19=0x%llx\n",
            (unsigned long long)x0, (unsigned long long)x9,
            (unsigned long long)x16, (unsigned long long)x17,
            (unsigned long long)x18, (unsigned long long)x19);
        /* Decode caller_insn at LR-4 (the BL/BLR that brought us here) */
        if (lr >= 0x100000000ULL && lr < 0x800000000ULL) {
            vm_size_t outsz = 4;
            uint32_t caller_insn = 0;
            if (vm_read_overwrite(mach_task_self(), lr - 4, 4,
                                  (vm_address_t)&caller_insn, &outsz) == KERN_SUCCESS)
                ERR("ILL diag: caller_insn @lr-4 = 0x%08x\n", caller_insn);
        }
        /* Walk back FP chain (each frame: fp[0]=prev_fp, fp[1]=saved_lr) */
        for (int frame = 0; frame < 8 && fp >= 0x100000000ULL && fp < 0x800000000ULL; frame++) {
            vm_size_t outsz = 8;
            uint64_t prev_fp = 0, saved_lr = 0;
            if (vm_read_overwrite(mach_task_self(), fp,     8, (vm_address_t)&prev_fp,  &outsz) != KERN_SUCCESS) break;
            outsz = 8;
            if (vm_read_overwrite(mach_task_self(), fp + 8, 8, (vm_address_t)&saved_lr, &outsz) != KERN_SUCCESS) break;
            ERR("ILL diag: frame[%d] fp=0x%llx saved_lr=0x%llx\n",
                frame, (unsigned long long)fp, (unsigned long long)saved_lr);
            if (prev_fp <= fp) break;
            fp = prev_fp;
        }
        /* iOS-Madeira 2026-07-06 (Thumper desktop ILL): both crashes were the
         * FEX dispatcher's ExitFunctionLinker thunk doing `ldr x2,[x28,#0x630];
         * blr x2` with a corrupted Pointers.ExitFunctionLink (pointed into a
         * mid-emission block tail instead of the C++ resolver). Dump the
         * evidence at crash time: x28 (STATE), x1 (link Record ptr), x2 (the
         * loaded target), the CpuStateFrame Pointers region around +0x630,
         * and the Record bytes — distinguishes single-field corruption vs
         * wild-store span vs corrupt Record. */
        {
            uint64_t x1  = (uint64_t)REGn_sig(1,  context);
            uint64_t x2  = (uint64_t)REGn_sig(2,  context);
            uint64_t x28 = (uint64_t)REGn_sig(28, context);
            uint64_t x6  = (uint64_t)REGn_sig(6,  context);
            uint64_t x10 = (uint64_t)REGn_sig(10, context);
            uint64_t x11 = (uint64_t)REGn_sig(11, context);
            ERR("ILL diag: x1=0x%llx x2=0x%llx x28=0x%llx\n",
                (unsigned long long)x1, (unsigned long long)x2, (unsigned long long)x28);
            /* x6 = guest RIP and x11 = branch target in FEX's inline exit
             * dispatch (`ret x11`); x10 = dispatcher's CompileBlock-return
             * target (`br x10`). Whichever equals pc names the faulting
             * branch. */
            ERR("ILL diag: x6=0x%llx x10=0x%llx x11=0x%llx (pc==x11? %d pc==x10? %d)\n",
                (unsigned long long)x6, (unsigned long long)x10, (unsigned long long)x11,
                x11 == pc, x10 == pc);
            /* FEX inline L1 exit-dispatch reads {L1Ptr, L1Mask} at STATE+0xa0
             * and the entry pair {host, guest} at L1Ptr + (rip & mask)<<?.
             * Dump the entry for x6 so a torn pair is visible at crash time.
             * Windows-heap frames live at 0x70xxxxxxxx — include them. */
            if (x28 >= 0x100000000ULL && x28 < 0x8000000000ULL)
            {
                uint64_t l1pair[2] = {0, 0}, entry[2] = {0, 0};
                vm_size_t osz = sizeof(l1pair);
                if (vm_read_overwrite(mach_task_self(), x28 + 0xa0, sizeof(l1pair),
                                      (vm_address_t)l1pair, &osz) == KERN_SUCCESS)
                {
                    /* mask is pre-shifted per dispatcher code: and x11, mask, rip<<4 */
                    uint64_t eaddr = l1pair[0] + ((x6 << 4) & l1pair[1]);
                    ERR("ILL diag: L1ptr=0x%llx L1mask=0x%llx entry@0x%llx\n",
                        (unsigned long long)l1pair[0], (unsigned long long)l1pair[1],
                        (unsigned long long)eaddr);
                    osz = sizeof(entry);
                    if (l1pair[0] &&
                        vm_read_overwrite(mach_task_self(), eaddr, sizeof(entry),
                                          (vm_address_t)entry, &osz) == KERN_SUCCESS)
                        ERR("ILL diag: L1 entry: host=0x%llx guest=0x%llx (guest==x6? %d host==pc? %d)\n",
                            (unsigned long long)entry[0], (unsigned long long)entry[1],
                            entry[1] == x6, entry[0] == pc);
                }
            }
            if (x28 >= 0x100000000ULL && x28 < 0x800000000ULL)
            {
                uint64_t words[32];
                vm_size_t outsz = sizeof(words);
                if (vm_read_overwrite(mach_task_self(), x28 + 0x5c0, sizeof(words),
                                      (vm_address_t)words, &outsz) == KERN_SUCCESS)
                {
                    for (int w = 0; w < 32; w += 4)
                        ERR("ILL diag: STATE+0x%03x: %016llx %016llx %016llx %016llx\n",
                            0x5c0 + w * 8,
                            (unsigned long long)words[w],   (unsigned long long)words[w+1],
                            (unsigned long long)words[w+2], (unsigned long long)words[w+3]);
                }
                /* State.rip lives in the first 0x100 of the frame */
                outsz = sizeof(words);
                if (vm_read_overwrite(mach_task_self(), x28, 0x40,
                                      (vm_address_t)words, &outsz) == KERN_SUCCESS)
                    ERR("ILL diag: STATE+0: %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx\n",
                        (unsigned long long)words[0], (unsigned long long)words[1],
                        (unsigned long long)words[2], (unsigned long long)words[3],
                        (unsigned long long)words[4], (unsigned long long)words[5],
                        (unsigned long long)words[6], (unsigned long long)words[7]);
            }
            if (x1 >= 0x100000000ULL && x1 < 0x800000000ULL)
            {
                uint64_t rec[6];
                vm_size_t outsz = sizeof(rec);
                if (vm_read_overwrite(mach_task_self(), x1, sizeof(rec),
                                      (vm_address_t)rec, &outsz) == KERN_SUCCESS)
                    ERR("ILL diag: Record@x1: %016llx %016llx %016llx %016llx %016llx %016llx\n",
                        (unsigned long long)rec[0], (unsigned long long)rec[1],
                        (unsigned long long)rec[2], (unsigned long long)rec[3],
                        (unsigned long long)rec[4], (unsigned long long)rec[5]);
            }
        }
        /* iOS-Madeira: also dump JIT pool here (the Mach UNHANDLED path may not
         * fire for ILL since we deliver via setup_exception). One-shot. */
        {
            static volatile int ill_dumped = 0;
            if (__sync_bool_compare_and_swap(&ill_dumped, 0, 1))
                ios_dump_jit_pool( "ILL diag" );
        }
    }
#endif

    if (!(PSTATE_sig( context ) & 0x10) && /* AArch64 (not WoW) */
        !(PC_sig( context ) & 3))
    {
        ULONG instr = *(ULONG *)PC_sig( context );
        /* emulate mrs xN, CurrentEL */
        if ((instr & ~0x1f) == 0xd5384240) {
            ULONG reg = instr & 0x1f;
            /* ignore writes to xzr */
            if (reg != 31) REGn_sig(reg, context) = 0;
            PC_sig(context) += 4;
#ifdef WINE_IOS
            ios_fixup_x18_for_return( context );
#endif
            return;
        }
    }

    setup_exception( sigcontext, &rec );
}


/**********************************************************************
 *		ios_emulate_store
 *
 * Emulate an ARM64 store instruction, writing through the JIT pool's
 * RW view instead of the RX view. Returns 1 on success, 0 if the
 * instruction isn't a recognized store.
 */
#ifdef WINE_IOS
static inline uint64_t ios_get_reg(ucontext_t *ctx, int r)
{
    if (r == 31) return 0;  /* XZR */
    /* REGn_sig(0..30) works because __x[29]=__fp, __x[30]=__lr in memory layout */
    return REGn_sig(r, ctx);
}

static int ios_emulate_store(ucontext_t *ctx, uint32_t insn, uintptr_t rw_addr)
{
    int rt = insn & 0x1F;
    uint64_t rt_val = ios_get_reg(ctx, rt);

    /* STR/STRB/STRH (unsigned offset):
     * size[31:30] 111 0 01 00 imm12 Rn Rt
     * Matching bits [29:22] = 11100100 */
    if ((insn & 0x3FC00000) == 0x39000000)
    {
        int size = (insn >> 30) & 3;
        switch (size) {
            case 0: *(uint8_t *)rw_addr = (uint8_t)rt_val; return 1;
            case 1: *(uint16_t *)rw_addr = (uint16_t)rt_val; return 1;
            case 2: *(uint32_t *)rw_addr = (uint32_t)rt_val; return 1;
            case 3: *(uint64_t *)rw_addr = rt_val; return 1;
        }
    }

    /* STUR / STR pre-index / STR post-index (9-bit immediate):
     * size[31:30] 111 0 00 00 0 imm9 type Rn Rt
     * Matching bits [29:21] = 111000000 */
    if ((insn & 0x3FE00000) == 0x38000000)
    {
        int size = (insn >> 30) & 3;
        switch (size) {
            case 0: *(uint8_t *)rw_addr = (uint8_t)rt_val; return 1;
            case 1: *(uint16_t *)rw_addr = (uint16_t)rt_val; return 1;
            case 2: *(uint32_t *)rw_addr = (uint32_t)rt_val; return 1;
            case 3: *(uint64_t *)rw_addr = rt_val; return 1;
        }
    }

    /* STP (signed offset / pre-index / post-index):
     * opc[31:30] 101 0 0xx 0 imm7 Rt2 Rn Rt
     * Matching bits [29:25,22] = 10100_0, various x bits for variant */
    if ((insn & 0x3E400000) == 0x28000000)
    {
        int opc = (insn >> 30) & 3;
        int rt2 = (insn >> 10) & 0x1F;
        uint64_t rt2_val = ios_get_reg(ctx, rt2);

        if (opc & 2) {  /* 64-bit */
            *(uint64_t *)rw_addr = rt_val;
            *(uint64_t *)(rw_addr + 8) = rt2_val;
        } else {  /* 32-bit */
            *(uint32_t *)rw_addr = (uint32_t)rt_val;
            *(uint32_t *)(rw_addr + 4) = (uint32_t)rt2_val;
        }
        return 1;
    }

    /* STR (register offset):
     * size[31:30] 111 0 00 01 Rm option S 10 Rn Rt */
    if ((insn & 0x3FE00C00) == 0x38200800)
    {
        int size = (insn >> 30) & 3;
        switch (size) {
            case 0: *(uint8_t *)rw_addr = (uint8_t)rt_val; return 1;
            case 1: *(uint16_t *)rw_addr = (uint16_t)rt_val; return 1;
            case 2: *(uint32_t *)rw_addr = (uint32_t)rt_val; return 1;
            case 3: *(uint64_t *)rw_addr = rt_val; return 1;
        }
    }

    /* ml408 (#66→#60): CAS/CASA/CASL/CASAL Ws/Xs, Wt/Xt, [Xn] — LSE
     * compare-and-swap on the pool RX alias. The [atomic-mem] probe settled
     * ml264's open question: the page is R-X (prot=5), so ANY write faults —
     * reading (b) was right, and the fix is the same RW-alias redirect the
     * plain stores above use. Acquire/release collapse to SEQ_CST (stronger).
     * Rs receives the observed old value (zero-extended for W forms).
     * 1x00 1000 1L1 Rs o0 11111 Rn Rt — ml408 killer: 0x88eafe89
     * CASAL W10, W9, [X20]; ml264 also saw 0xc8f1fd60 CASAL X17, X0, [X11]. */
    if ((insn & 0xBFA07C00) == 0x88A07C00)
    {
        int rs = (insn >> 16) & 0x1F;
        int sz64 = (insn >> 30) & 1;
        static int cas_log;
        if (sz64)
        {
            uint64_t exp = ios_get_reg(ctx, rs);
            __atomic_compare_exchange_n((uint64_t *)rw_addr, &exp, rt_val,
                                        0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
            if (rs != 31) REGn_sig(rs, ctx) = exp;
        }
        else
        {
            uint32_t exp = (uint32_t)ios_get_reg(ctx, rs);
            __atomic_compare_exchange_n((uint32_t *)rw_addr, &exp, (uint32_t)rt_val,
                                        0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
            if (rs != 31) REGn_sig(rs, ctx) = exp;
        }
        if (cas_log++ < 8)
            ERR("[cas-emu] CAS%s insn=0x%08x rw=%p rs=%d rt=%d -> emulated on RW alias\n",
                sz64 ? "64" : "32", insn, (void *)rw_addr, rs, rt);
        return 1;
    }

    /* ml1208: CASB/CASH and their A/L/AL forms (0x08A07C00 / 0x48A07C00), which
     * FEX emits for `lock cmpxchg byte/word`. A 64-bit program with a fixed base
     * below 4 GB did one on its .bss at 0x741310 (`ml939 UNHANDLED encoding
     * 0x08ebff66` = casalb w11, w6, [x27]): SEGV, c0000005. Same contract as the
     * CAS branch above. An unaligned halfword cannot go through the hardware CAS,
     * so it is done non-atomically. */
    if ((insn & 0xBFA07C00) == 0x08A07C00)
    {
        int rs = (insn >> 16) & 0x1F;
        static int casbh_log;
        if (insn & 0x40000000)
        {
            uint16_t exp = (uint16_t)ios_get_reg(ctx, rs);
            if (rw_addr & 1)
            {
                uint16_t cur;
                memcpy( &cur, (void *)rw_addr, 2 );
                if (cur == exp) { uint16_t v = (uint16_t)rt_val; memcpy( (void *)rw_addr, &v, 2 ); }
                exp = cur;
            }
            else
                __atomic_compare_exchange_n((uint16_t *)rw_addr, &exp, (uint16_t)rt_val,
                                            0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
            if (rs != 31) REGn_sig(rs, ctx) = exp;
        }
        else
        {
            uint8_t exp = (uint8_t)ios_get_reg(ctx, rs);
            __atomic_compare_exchange_n((uint8_t *)rw_addr, &exp, (uint8_t)rt_val,
                                        0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
            if (rs != 31) REGn_sig(rs, ctx) = exp;
        }
        if (casbh_log++ < 8)
            ERR("[cas-emu] ml1208 CAS%s insn=0x%08x rw=%p rs=%d rt=%d -> emulated\n",
                (insn & 0x40000000) ? "H" : "B", insn, (void *)rw_addr, rs, rt);
        return 1;
    }

    /* CASP/CASPA/CASPL/CASPAL pair forms (ml264: 0x4866fd64/0x4866fe6a):
     * 0sz0 1000 0L1 Rs o0 11111 Rn Rt, Rs/Rt even. Hardware caspal on the RW
     * alias so we stay atomic against FEX's own native RW-alias atomics. */
    if ((insn & 0xBFA07C00) == 0x08207C00)
    {
        int rs = (insn >> 16) & 0x1F;
        int sz64 = (insn >> 30) & 1;
        static int casp_log;
        uint64_t v0 = ios_get_reg(ctx, rs), v1 = ios_get_reg(ctx, rs + 1);
        uint64_t v2 = ios_get_reg(ctx, rt), v3 = ios_get_reg(ctx, rt + 1);
        register uint64_t c0 asm("x0") = v0;
        register uint64_t c1 asm("x1") = v1;
        register uint64_t c2 asm("x2") = v2;
        register uint64_t c3 asm("x3") = v3;
        if (sz64)
            asm volatile(".arch_extension lse\n\tcaspal x0, x1, x2, x3, [%4]"
                         : "+r"(c0), "+r"(c1)
                         : "r"(c2), "r"(c3), "r"(rw_addr)
                         : "memory");
        else
            asm volatile(".arch_extension lse\n\tcaspal w0, w1, w2, w3, [%4]"
                         : "+r"(c0), "+r"(c1)
                         : "r"(c2), "r"(c3), "r"(rw_addr)
                         : "memory");
        if (rs != 31)
        {
            REGn_sig(rs, ctx) = c0;
            REGn_sig(rs + 1, ctx) = c1;
        }
        if (casp_log++ < 8)
            ERR("[cas-emu] CASP%s insn=0x%08x rw=%p rs=%d rt=%d -> emulated on RW alias\n",
                sz64 ? "64" : "32", insn, (void *)rw_addr, rs, rt);
        return 1;
    }

    /* ml973: FP/SIMD stores -- every width, all three addressing forms.
     *
     * rdr36 ended on `ml939 UNHANDLED encoding 0x3d800000` = `str q0, [x0]`,
     * a 128-bit SIMD store in its UNSIGNED-OFFSET form, writing EMP.dll's
     * .data at rva 0x15290. ios_emulate_load matches that encoding and
     * correctly declines it as a store, ios_emulate_store_rel does not cover
     * SIMD singles, and THIS function had no SIMD branch at all -- so the
     * sub-floor service path had nothing to hand it to.
     *
     * (ml972 put this in ios_emulate_unaligned_guest_access by mistake, which
     * is a different function on a different path -- the Steam-era unaligned
     * emulator -- so it never ran. The sub-floor path is
     * ios_subfloor_service -> load, then store_rel, then THIS function.)
     *
     * Width follows the architectural size:opc[1] pairing, the same formula
     * ios_emulate_load and ios_subfloor_classify already use: size 00/01/10/11
     * with opc[1]==0 give 1/2/4/8 bytes, and size==00 with opc[1]==1 is the
     * 128-bit Q form. Any other size with opc[1] set is unallocated and is
     * declined rather than guessed at.
     *
     * No base-register writeback here, deliberately: ios_subfloor_writeback()
     * applies the pre/post index once, for loads and stores alike, after a
     * successful emulation. `rw_addr` already carries the computed offset. */
    if ((insn & 0x3F000000) == 0x3D000000 ||        /* unsigned offset */
        (insn & 0x3F200000) == 0x3C000000 ||        /* 9-bit immediate */
        (insn & 0x3F200C00) == 0x3C200800)          /* register offset */
    {
        const int v_size = (insn >> 30) & 3;
        const int v_opc  = (insn >> 22) & 3;
        int w;

        if (v_opc & 1) return 0;                    /* load -- not ours */
        if ((v_opc & 2) && v_size != 0) return 0;   /* unallocated */
        if (!ios_neon_valid) return 0;              /* ml974: __ns is not real */
        w = (v_size == 0 && (v_opc & 2)) ? 16 : (1 << v_size);
        {
            static unsigned long long simd_n;
            unsigned long long n = __sync_add_and_fetch( &simd_n, 1 );
            if (n <= 4 || (n & 0xFFFF) == 1)
                dprintf( 2, "[simd-str] ml973 #%llu emulated FP/SIMD store insn=%#010x "
                         "size=%d opc=%d width=%d addr=%#llx\n",
                         n, insn, v_size, v_opc, w, (unsigned long long)rw_addr );
        }
        memcpy( (void *)rw_addr, &ctx->uc_mcontext->__ns.__v[rt], w );
        return 1;
    }

    return 0;  /* unhandled instruction */
}

/**********************************************************************
 *		ios_emulate_unaligned_guest_access
 *
 * iOS-Madeira ml479 (#83): emulate a PLAIN (non-atomic) misaligned
 * load/store IN PLACE via memcpy and return 1, or 0 if the form isn't
 * safely emulatable. Guest x86 MOVs may be arbitrarily misaligned and
 * MUST succeed; some guest regions (PA-band SM_COW pages, hit by the
 * 2026-08-04 Steam client) alignment-fault them at the hardware level
 * (SIGBUS/BUS_ADRALN on a readable+writable page). memcpy is byte-wise
 * so it cannot re-raise the alignment fault inside the handler. Only
 * no-writeback addressing forms are accepted (unsigned offset, register
 * offset, unscaled LDUR/STUR, signed-offset LDP/STP) — pre/post-index
 * would need a base-register update and FEX doesn't emit them for guest
 * memory ops. Atomic/exclusive/SIMD forms return 0 so the caller keeps
 * the existing 80000002 path for FEX's unaligned-atomic machinery.
 */
static int ios_emulate_unaligned_guest_access(ucontext_t *ctx, uint32_t insn, uintptr_t addr)
{
    int rt = insn & 0x1F;

    if ((insn >> 26) & 1) return 0;  /* SIMD/FP: not handled here */

    /* Load/store register — three no-writeback addressing forms, common
     * size/opc decode:
     *   unsigned offset:  size 111 0 01 opc imm12       Rn Rt
     *   register offset:  size 111 0 00 opc 1 Rm opt S 10 Rn Rt
     *   unscaled (LDUR/STUR): size 111 0 00 opc 0 imm9 00 Rn Rt */
    if ((insn & 0x3F000000) == 0x39000000 ||        /* unsigned offset */
        (insn & 0x3F200C00) == 0x38200800 ||        /* register offset */
        (insn & 0x3F200C00) == 0x38000000)          /* unscaled */
    {
        int size = (insn >> 30) & 3;
        int opc  = (insn >> 22) & 3;
        unsigned nbytes = 1u << size;

        if (size == 3 && opc >= 2) return 0;        /* PRFM / undefined */
        if (size == 2 && opc == 3) return 0;        /* undefined */

        if (opc == 0)                               /* store */
        {
            uint64_t v = ios_get_reg(ctx, rt);
            memcpy((void *)addr, &v, nbytes);
        }
        else                                        /* load */
        {
            uint64_t v = 0;
            memcpy(&v, (const void *)addr, nbytes);
            if (opc >= 2)                           /* sign-extending */
            {
                int shift = 64 - 8 * (int)nbytes;
                int64_t sv = (int64_t)(v << shift) >> shift;
                v = (opc == 3) ? (uint64_t)(uint32_t)sv : (uint64_t)sv;
            }
            if (rt != 31) REGn_sig(rt, ctx) = v;
        }
        return 1;
    }

    /* LDP/STP signed offset (no writeback): opc 101 0 010 L imm7 Rt2 Rn Rt */
    if ((insn & 0x3F800000) == 0x29000000)
    {
        int opc2 = (insn >> 30) & 3;
        int L = (insn >> 22) & 1;
        int rt2 = (insn >> 10) & 0x1F;
        unsigned nb = (opc2 & 2) ? 8 : 4;

        if (opc2 == 3) return 0;                    /* undefined */
        if (opc2 == 1 && !L) return 0;              /* STGP/undefined */

        if (!L)
        {
            uint64_t v1 = ios_get_reg(ctx, rt), v2 = ios_get_reg(ctx, rt2);
            memcpy((void *)addr, &v1, nb);
            memcpy((void *)(addr + nb), &v2, nb);
        }
        else
        {
            uint64_t v1 = 0, v2 = 0;
            memcpy(&v1, (const void *)addr, nb);
            memcpy(&v2, (const void *)(addr + nb), nb);
            if (opc2 == 1)                          /* LDPSW */
            {
                v1 = (uint64_t)(int64_t)(int32_t)v1;
                v2 = (uint64_t)(int64_t)(int32_t)v2;
            }
            if (rt != 31) REGn_sig(rt, ctx) = v1;
            if (rt2 != 31) REGn_sig(rt2, ctx) = v2;
        }
        return 1;
    }

    /* iOS-Madeira ml593: STUR/LDUR Qt (128-bit SIMD, UNSCALED immediate)
     *   00 111 1 00 1x 0 imm9 00 Rn Rt   — 0x3c800000 (store) / 0x3cc00000 (load),
     *                                       bits[11:10] == 00 marks unscaled.
     *
     * THIS IS THE INSTRUCTION THAT KILLED THE FIRST SUCCESSFUL STEAM LOGIN
     * (ml592, db 7164). insn=0x3c9f00c0 = `stur q0,[x6,#-16]` to 0x7075e00fc6
     * (6 mod 16) on steamwebhelper's main thread while libcef brought up the
     * post-login UI. This decoder emulated 140 unaligned accesses that run and
     * refused exactly one — the first SIMD-width store it ever saw — which
     * became an unhandled SIGBUS and, since every Windows process here is a
     * thread in ONE Mach task, took the whole app down seconds after
     * `[Logged On]`.
     *
     * ⚠️ NO BASE-REGISTER WRITEBACK. 0x3c9f00c0 is the UNSCALED form; the
     * post-indexed `str q0,[x6],#-16` is 0x3c9f04c0 (bits[11:10] == 01). I first
     * decoded this as post-indexed, which would have added a bogus -16 to x6 on
     * every emulated store — silent translated-state corruption, far worse than
     * the crash it "fixed". Sol caught it; both encodings were then assembled to
     * confirm. addr already carries the imm9 offset, so the access needs nothing
     * but the copy. */
    if ((insn & 0xffa00c00) == 0x3c800000)
    {
        int is_load = (insn >> 22) & 1;
        void *v = &((ucontext_t *)ctx)->uc_mcontext->__ns.__v[rt];

        /* ml974: same hazard as the store path -- a zeroed __ns would be
         * written over guest memory, or a load would land in a block that is
         * never handed back. Pre-existing here; guarded for consistency,
         * because silent corruption is worse than an unhandled fault. */
        if (!ios_neon_valid) return 0;
        if (is_load) memcpy( v, (const void *)addr, 16 );
        else         memcpy( (void *)addr, v, 16 );
        return 1;
    }

    return 0;
}


/***********************************************************************
 *		ml938: SUB-FLOOR IMAGE WINDOWS  (emulate a mapping iOS denies us)
 *
 * iOS reserves the low 4GB of every task. __PAGEZERO sets the map's minimum
 * at exec and the kernel refuses any smaller value -- measured four ways, see
 * reference_ios_va_budget: a 128MB and a 16KB __PAGEZERO are both SIGKILLed at
 * exec, and that stays true with every real segment forced above 4GB, so it is
 * the pagezero SIZE, not segment placement. In a live process the floor reads
 * back as 0x104638000 and a FIXED map anywhere below it returns
 * KERN_INVALID_ADDRESS -- the range is outside the map, not merely occupied.
 * No process on this OS can have a lower floor, so a helper task would not
 * help either.
 *
 * That collides with a real and legal PE shape: an image whose preferred base
 * is below 4GB. Windows maps it there, so it is entitled to hold absolute
 * preferred-base addresses, and packed/obfuscated DLLs do exactly that -- one
 * measured here has 729 aligned 64-bit pointers into its own image in .rdata
 * against a relocation directory of 20 fixups. Relocating it is impossible
 * (the fixups do not cover them) and placing it is impossible (the address
 * does not exist). Both ends are closed.
 *
 * So stop trying to satisfy the address and SERVICE it instead. We cannot make
 * the page exist, but we do not have to: every access to it traps to our Mach
 * handler, which already sees the fault and already classifies the address
 * ("[fault_rip] ... addr=0x1301ad00 kr=1(INVALID_ADDRESS)"). Translate the
 * faulting address into the image's real mapping, emulate the instruction
 * against it, and step over. The guest's view is then exactly what Windows
 * would have given it, byte for byte, with no modification to the image: the
 * low window and the real mapping are the SAME memory, so reads and writes
 * cannot diverge.
 *
 * This is general, not per-image: the window is registered by the PE loader
 * for any image it maps whose preferred base is sub-floor. It also makes the
 * ml936 sub-floor relocation sound -- fixups that WERE applied point high and
 * resolve normally, the ones the directory never covered point low and land
 * here.
 *
 * COST, stated honestly: one Mach exception per access, and the page can never
 * be mapped so there is no amortisation -- this is ~25k/sec territory (the
 * ml648 SWPAL storm measured that rate). Fine for a startup-time unpacker,
 * not fine for a hot loop. The counters below exist to measure which one we
 * have; if the volume is bad the next step is a compile-time fixup in FEX for
 * blocks whose guest RIP lies inside a registered window (a 3-instruction
 * low-address redirect on the ~25 GenerateMemOperand/GetReg(Op->Addr) sites),
 * which costs nothing outside those blocks. Measure before building that.
 */
/* ml1205: windows belong to the pseudo-process that mapped the image. All
 * pseudo-processes share one address space, so a session-wide table could hold
 * only one image per low base: a program with a fixed base of 0x400000 started
 * another one with the same base, the child's window replaced the parent's and
 * the parent ran the child's bytes. A lookup now takes the PEB of the faulting
 * or calling thread; an owner of NULL (KUSER_SHARED_DATA) serves every process,
 * and a lookup without a known PEB falls back to any matching window (the old
 * behaviour). A process's windows are released when it exits
 * (ios_subfloor_release_owner). */
#define IOS_SUBFLOOR_MAX 32
#define IOS_SUBFLOOR_FLOOR 0x100000000ull

struct ios_subfloor_window
{
    uint64_t pref_base;   /* preferred base, below the floor: what the guest uses */
    uint64_t size;        /* SizeOfImage; 0 = free slot */
    uint64_t real_base;   /* where the loader actually mapped it */
    void    *owner_peb;   /* ml1205: the pseudo-process that mapped it, NULL = all */
};
static struct ios_subfloor_window ios_subfloor[IOS_SUBFLOOR_MAX];
static int ios_subfloor_count;
static pthread_mutex_t ios_subfloor_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned long long ios_subfloor_hits;
static unsigned long long ios_subfloor_unknown;
static unsigned long long ios_subfloor_refused;   /* ml956: backing inaccessible */

void ios_register_subfloor_image( unsigned long long pref_base, unsigned long long size,
                                  unsigned long long real_base, void *owner );
void ios_register_subfloor_image( unsigned long long pref_base, unsigned long long size,
                                  unsigned long long real_base, void *owner )
{
    extern void ios_push_subfloor_window( unsigned long long, unsigned long long,
                                          unsigned long long, void * );
    int i, slot = -1;

    if (!pref_base || !size || pref_base >= IOS_SUBFLOOR_FLOOR) return;
    pthread_mutex_lock( &ios_subfloor_lock );
    for (i = 0; i < ios_subfloor_count; i++)
    {
        if (!ios_subfloor[i].size)
        {
            if (slot < 0) slot = i;
            continue;
        }
        if (ios_subfloor[i].pref_base == pref_base && ios_subfloor[i].owner_peb == owner)
        {
            /* Re-registration within one process (the ml1204 check keeps a
             * relocatable image from getting here over a stripped one). */
            if (ios_subfloor[i].real_base != real_base)
                dprintf( 2, "[subfloor] ml938 window %#llx RE-POINTED %#llx -> %#llx "
                         "(owner %p)\n",
                         pref_base, (unsigned long long)ios_subfloor[i].real_base, real_base, owner );
            ios_subfloor[i].size = 0;
            __sync_synchronize();
            ios_subfloor[i].real_base = real_base;
            __sync_synchronize();
            ios_subfloor[i].size = size;
            pthread_mutex_unlock( &ios_subfloor_lock );
            /* ml951: FEX's copy must follow the re-point. */
            ios_push_subfloor_window( pref_base, real_base, size, owner );
            return;
        }
    }
    if (slot < 0)
    {
        if (ios_subfloor_count >= IOS_SUBFLOOR_MAX)
        {
            pthread_mutex_unlock( &ios_subfloor_lock );
            dprintf( 2, "[subfloor] ml938 window table FULL, dropping %#llx\n", pref_base );
            return;
        }
        slot = ios_subfloor_count;
    }
    i = slot;
    ios_subfloor[i].size      = 0;
    __sync_synchronize();
    ios_subfloor[i].pref_base = pref_base;
    ios_subfloor[i].real_base = real_base;
    ios_subfloor[i].owner_peb = owner;
    __sync_synchronize();
    ios_subfloor[i].size      = size;
    if (i == ios_subfloor_count)
    {
        __sync_synchronize();
        ios_subfloor_count = i + 1;
    }
    pthread_mutex_unlock( &ios_subfloor_lock );
    dprintf( 2, "[subfloor] ml938 window #%d: guest [%#llx,%#llx) -> real %#llx (%llu KB) owner %p\n",
             i, pref_base, pref_base + size, real_base, size / 1024, owner );
    /* ml951: FEX needs this too, so its executable-range query can answer for
     * the low window instead of refusing the entry block. */
    ios_push_subfloor_window( pref_base, real_base, size, owner );
}

/* ml1205: the pseudo-process is gone; free its windows. */
void ios_subfloor_release_owner( void *owner );
void ios_subfloor_release_owner( void *owner )
{
    int i;

    if (!owner) return;
    pthread_mutex_lock( &ios_subfloor_lock );
    for (i = 0; i < ios_subfloor_count; i++)
    {
        if (!ios_subfloor[i].size || ios_subfloor[i].owner_peb != owner) continue;
        dprintf( 2, "[subfloor] ml1205 window #%d %#llx -> %#llx released with its process %p\n",
                 i, (unsigned long long)ios_subfloor[i].pref_base,
                 (unsigned long long)ios_subfloor[i].real_base, owner );
        ios_subfloor[i].size = 0;
        __sync_synchronize();
    }
    pthread_mutex_unlock( &ios_subfloor_lock );
}

/* ml951: enumerate registered windows so virtual_ios.c can push any that were
 * registered before xtajit64's callback existed. Returns 0 when idx is past
 * the end. */
int ios_subfloor_enum( int idx, unsigned long long *low, unsigned long long *real,
                       unsigned long long *size, void **owner );
int ios_subfloor_enum( int idx, unsigned long long *low, unsigned long long *real,
                       unsigned long long *size, void **owner )
{
    uint64_t sz;

    if (idx < 0 || idx >= ios_subfloor_count) return 0;
    sz = ios_subfloor[idx].size;       /* 0 = free slot; read first, see register */
    __sync_synchronize();
    if (low)   *low   = ios_subfloor[idx].pref_base;
    if (real)  *real  = ios_subfloor[idx].real_base;
    if (owner) *owner = ios_subfloor[idx].owner_peb;
    if (size)  *size  = sz;
    return 1;
}

/* ml1205: the window `peb` sees at addr. Exact owner or a shared (NULL-owner)
 * window wins; with no known peb, the last matching window answers. */
static uintptr_t ios_subfloor_translate( uint64_t addr, void *peb )
{
    int i, n = ios_subfloor_count;
    uintptr_t any = 0;

    if (addr >= IOS_SUBFLOOR_FLOOR) return 0;   /* fast reject: the common case */
    for (i = 0; i < n; i++)
    {
        uint64_t sz = ios_subfloor[i].size, lo, re;
        void *own;

        if (!sz) continue;
        __sync_synchronize();
        lo = ios_subfloor[i].pref_base;
        re = ios_subfloor[i].real_base;
        own = ios_subfloor[i].owner_peb;
        if (addr < lo || addr >= lo + sz) continue;
        if (!own || own == peb) return (uintptr_t)(re + (addr - lo));
        if (!peb) any = (uintptr_t)(re + (addr - lo));
    }
    return any;
}

/* Read `size` bytes at `a` with the opc-implied extension. memcpy, not a cast
 * deref: the faulting address can be unaligned (the case that found this was a
 * 64-bit load from ...2ce) and a typed deref lets the compiler assume it is
 * not. opc 01 = zero-extend, 10 = sign-extend to 64, 11 = sign-extend to 32. */
static uint64_t ios_ld_extend( uintptr_t a, int size, int opc )
{
    uint64_t v = 0;

    switch (size)
    {
    case 0: { uint8_t  t; memcpy( &t, (const void *)a, 1 ); v = opc >= 2 ? (uint64_t)(int64_t)(int8_t)t  : t; break; }
    case 1: { uint16_t t; memcpy( &t, (const void *)a, 2 ); v = opc >= 2 ? (uint64_t)(int64_t)(int16_t)t : t; break; }
    case 2: { uint32_t t; memcpy( &t, (const void *)a, 4 ); v = opc >= 2 ? (uint64_t)(int64_t)(int32_t)t : t; break; }
    default: memcpy( &v, (const void *)a, 8 ); break;
    }
    if (opc == 3) v = (uint32_t)v;   /* 32-bit destination: W-write zeroes the top */
    return v;
}

static void ios_ld_setreg( ucontext_t *ctx, int rt, uint64_t v )
{
    if (rt != 31) REGn_sig(rt, ctx) = v;   /* XZR discards */
}

/* ml974: returns 0 when the vector block is not real, so callers decline
 * instead of loading into a context the handler will never write back. */
static int ios_ld_setvec( ucontext_t *ctx, int rt, uintptr_t a, int bytes )
{
    unsigned char *v = (unsigned char *)&ctx->uc_mcontext->__ns.__v[rt];

    if (!ios_neon_valid) return 0;
    memset( v, 0, 16 );
    memcpy( v, (const void *)a, bytes );
    return 1;
}

/*
 * Emulate an ARM64 LOAD against `rd_addr`. Returns 1 if the encoding was
 * recognised. Covers exactly the gap reference_str_emulator_state.md records
 * as open ("All loads ... LDAR / LDAXR / LDAPR -- no emulator path"); LDAPRB
 * is what the sub-floor fault arrives on, because FEX's TSO emulation lowers
 * every guest x86 load to a load-acquire.
 *
 * Base-register writeback is NOT done here -- ios_subfloor_writeback() does it
 * once, for loads and stores alike, so the two paths cannot double-apply it.
 */
static int ios_emulate_load( ucontext_t *ctx, uint32_t insn, uintptr_t rd_addr )
{
    const int rt   = insn & 0x1F;
    const int size = (insn >> 30) & 3;
    const int opc  = (insn >> 22) & 3;

    /* LDAPR/LDAPRB/LDAPRH -- size 111 0 00 1 0 1 11111 1 1 00 00 Rn Rt */
    if ((insn & 0x3FFFFC00) == 0x38BFC000)
    {
        ios_ld_setreg( ctx, rt, ios_ld_extend( rd_addr, size, 1 ) );
        return 1;
    }

    /* ml1231: LDAPUR / LDAPURB / LDAPURH / LDAPURS* (FEAT_LRCPC2) --
     * size 011001 opc 0 imm9 00 Rn Rt. FEX emits these for guest loads once
     * the host reports LRCPC2. opc 01 zero-extends, 10 sign-extends to 64 and
     * 11 to 32, the same convention ios_ld_extend takes; opc 00 is STLUR. */
    if ((insn & 0x3F200C00) == 0x19000000)
    {
        if (opc == 0) return 0;                        /* STLUR* -- not ours */
        if ((size == 3 && opc >= 2) || (size == 2 && opc == 3)) return 0;   /* unallocated */
        ios_ld_setreg( ctx, rt, ios_ld_extend( rd_addr, size, opc ) );
        return 1;
    }

    /* LDAR / LDAXR / LDXR -- Rs and Rt2 both 11111 */
    if ((insn & 0x3FFFFC00) == 0x08DFFC00 ||    /* LDAR  */
        (insn & 0x3FFFFC00) == 0x085FFC00 ||    /* LDAXR */
        (insn & 0x3FFFFC00) == 0x085F7C00)      /* LDXR  */
    {
        ios_ld_setreg( ctx, rt, ios_ld_extend( rd_addr, size, 1 ) );
        return 1;
    }

    /* GPR unsigned offset -- size 111 0 01 opc imm12 Rn Rt. opc 00 is a store,
     * and size=11/opc=10 is PRFM (no register result, but stepping over it is
     * the correct effect). */
    if ((insn & 0x3F000000) == 0x39000000)
    {
        if (opc == 0) return 0;                        /* STR* -- not ours */
        if (size == 3 && opc == 2) return 1;           /* PRFM: nothing to do */
        ios_ld_setreg( ctx, rt, ios_ld_extend( rd_addr, size, opc ) );
        return 1;
    }

    /* GPR 9-bit immediate: LDUR / post-index / pre-index / LDTR */
    if ((insn & 0x3F200000) == 0x38000000)
    {
        if (opc == 0) return 0;                        /* STUR* -- not ours */
        if (size == 3 && opc == 2) return 1;           /* PRFUM */
        ios_ld_setreg( ctx, rt, ios_ld_extend( rd_addr, size, opc ) );
        return 1;
    }

    /* GPR register offset -- size 111 0 00 opc 1 Rm option S 10 Rn Rt */
    if ((insn & 0x3F200C00) == 0x38200800)
    {
        if (opc == 0) return 0;
        if (size == 3 && opc == 2) return 1;           /* PRFM (register) */
        ios_ld_setreg( ctx, rt, ios_ld_extend( rd_addr, size, opc ) );
        return 1;
    }

    /* LDP / LDPSW -- opc 101 0 0xx 1 imm7 Rt2 Rn Rt  (L=1 => bit22 set) */
    if ((insn & 0x3E400000) == 0x28400000)
    {
        const int rt2 = (insn >> 10) & 0x1F;
        const int pair_opc = (insn >> 30) & 3;

        if (pair_opc == 1)          /* LDPSW: two sign-extended 32-bit words */
        {
            ios_ld_setreg( ctx, rt,  ios_ld_extend( rd_addr,     2, 2 ) );
            ios_ld_setreg( ctx, rt2, ios_ld_extend( rd_addr + 4, 2, 2 ) );
        }
        else if (pair_opc & 2)      /* 64-bit pair */
        {
            ios_ld_setreg( ctx, rt,  ios_ld_extend( rd_addr,     3, 1 ) );
            ios_ld_setreg( ctx, rt2, ios_ld_extend( rd_addr + 8, 3, 1 ) );
        }
        else                        /* 32-bit pair */
        {
            ios_ld_setreg( ctx, rt,  ios_ld_extend( rd_addr,     2, 1 ) );
            ios_ld_setreg( ctx, rt2, ios_ld_extend( rd_addr + 4, 2, 1 ) );
        }
        return 1;
    }

    /* FP/SIMD. Width comes from size plus opc bit 23: size=00 with that bit
     * set is the 128-bit (Q) form, otherwise 1<<size. opc bit 22 is L. */
    if ((insn & 0x3F000000) == 0x3D000000 ||           /* unsigned offset */
        (insn & 0x3F200000) == 0x3C000000 ||           /* 9-bit immediate  */
        (insn & 0x3F200C00) == 0x3C200800)             /* register offset  */
    {
        int bytes;

        if (!(opc & 1)) return 0;                      /* store -- not ours */
        bytes = (size == 0 && (opc & 2)) ? 16 : (1 << size);
        /* ml974: decline if the vector block is not real -- a load into a
         * context the handler will not write back is silently wrong. */
        if (!ios_ld_setvec( ctx, rt, rd_addr, bytes )) return 0;
        return 1;
    }

    return 0;
}

/*
 * ml938: the RELEASE / EXCLUSIVE / LSE store surface, which ios_emulate_store
 * does not cover -- it has plain stores, STP and CAS, and the store-release
 * family is handled only in the unaligned-atomic path of the Mach handler,
 * which this route does not go through. Kept as its own function rather than
 * extending ios_emulate_store, so the BUS-handler caller of that helper keeps
 * exactly its current behaviour.
 *
 * Needed because FEX's TSO emulation lowers guest x86 accesses to acquire/
 * release forms: the first sub-floor fault arrived as LDAPRB, and the very
 * next access to the same byte was STLRB (guest `mov byte [rcx], r11b`).
 * Emulating a release store as a plain store is correct here -- we are single-
 * stepping one access inside a fault handler, so the barrier it implies has
 * already been satisfied by the trap and the return.
 *
 * Returns 1 if the encoding was recognised.
 */
static int ios_emulate_store_rel( ucontext_t *ctx, uint32_t insn, uintptr_t addr )
{
    const int rt   = insn & 0x1F;
    const int size = (insn >> 30) & 3;
    const int nbytes = 1 << size;

    /* STLR / STLRB / STLRH / STLR(64), and the STLLR (no-ordering) variants.
     * Rs and Rt2 are both 11111 here, which is what separates these from the
     * store-exclusive encodings below. */
    if ((insn & 0x3FFFFC00) == 0x089FFC00 ||     /* STLR*  (o0=1) */
        (insn & 0x3FFFFC00) == 0x089F7C00 ||     /* STLLR* (o0=0) */
        (insn & 0x3FE00C00) == 0x19000000)       /* ml1231: STLUR* (LRCPC2, imm9) */
    {
        uint64_t v = ios_get_reg( ctx, rt );
        memcpy( (void *)addr, &v, nbytes );
        return 1;
    }

    /* STXR / STLXR: emulate as a store that always succeeds and report that in
     * the status register. A monitor-based retry loop would otherwise spin for
     * ever, because our emulated store never sets the exclusive monitor. */
    if ((insn & 0x3FE0FC00) == 0x0800FC00 ||     /* STLXR */
        (insn & 0x3FE0FC00) == 0x08007C00)       /* STXR  */
    {
        const int rs = (insn >> 16) & 0x1F;
        uint64_t v = ios_get_reg( ctx, rt );

        memcpy( (void *)addr, &v, nbytes );
        if (rs != 31) REGn_sig(rs, ctx) = 0;     /* 0 == store succeeded */
        return 1;
    }

    /* LSE read-modify-write: SWP / LDADD / LDCLR / LDEOR / LDSET, any size and
     * any acquire/release combination. The old value goes to Rt (Rt==31 is the
     * ST<op> alias, which discards it). */
    if ((insn & 0x3F20FC00) == 0x38200000 ||     /* LDADD */
        (insn & 0x3F20FC00) == 0x38201000 ||     /* LDCLR */
        (insn & 0x3F20FC00) == 0x38202000 ||     /* LDEOR */
        (insn & 0x3F20FC00) == 0x38203000 ||     /* LDSET */
        (insn & 0x3F20FC00) == 0x38208000)       /* SWP   */
    {
        const int rs = (insn >> 16) & 0x1F;
        const int op = (insn >> 12) & 7;
        const int is_swp = (insn >> 15) & 1;
        uint64_t old = 0, src = ios_get_reg( ctx, rs ), nv;

        memcpy( &old, (const void *)addr, nbytes );
        if (is_swp)           nv = src;
        else switch (op)
        {
        case 0:  nv = old + src;  break;         /* LDADD */
        case 1:  nv = old & ~src; break;         /* LDCLR */
        case 2:  nv = old ^ src;  break;         /* LDEOR */
        default: nv = old | src;  break;         /* LDSET */
        }
        memcpy( (void *)addr, &nv, nbytes );
        if (rt != 31) REGn_sig(rt, ctx) = (size == 3) ? old : (uint32_t)old;
        return 1;
    }

    /* SIMD pair load/store (LDP/STP q,d,s) -- V=1, which the GPR pair paths in
     * ios_emulate_store and ios_emulate_load both decline.
     *
     * ml950: the mask was 0x3A000000, which omits bit 26 (V) while the compare
     * value 0x2C000000 sets it -- so the test was unsatisfiable and this whole
     * branch was dead code. It surfaced when FEX read guest code out of a
     * sub-floor window through the shared-cache memmove, whose `LDP q,q,[Xn],#imm`
     * (0xac400c22) was reported UNHANDLED. 0x3E000000 pins [29:27]=101, V=1 and
     * [25]=0, and stays disjoint from the GPR pair test (0x3E400000/0x28400000,
     * which requires V=0). */
    if ((insn & 0x3E000000) == 0x2C000000)
    {
        const int rt2   = (insn >> 10) & 0x1F;
        const int p_opc = (insn >> 30) & 3;
        const int is_ld = (insn >> 22) & 1;
        int w;

        if (p_opc == 3) return 0;                /* reserved */
        w = 4 << p_opc;                          /* 4 = S, 8 = D, 16 = Q */
        if (is_ld)
        {
            /* ml974: both halves or neither -- check before either write so a
             * refusal cannot leave one register updated. */
            if (!ios_neon_valid) return 0;
            ios_ld_setvec( ctx, rt,  addr,     w );
            ios_ld_setvec( ctx, rt2, addr + w, w );
        }
        else
        {
            /* ml974: never write a zeroed vector block over guest memory. */
            if (!ios_neon_valid) return 0;
            memcpy( (void *)addr,       &ctx->uc_mcontext->__ns.__v[rt],  w );
            memcpy( (void *)(addr + w), &ctx->uc_mcontext->__ns.__v[rt2], w );
        }
        return 1;
    }

    return 0;
}

/*
 * Apply base-register writeback for the pre/post-index forms, in the GUEST
 * (sub-floor) domain -- Rn holds a low address and must keep holding one.
 * Both cases are expressible from the faulting address alone: for post-index
 * the effective address IS Rn, for pre-index it is Rn plus the immediate.
 */
static void ios_subfloor_writeback( ucontext_t *ctx, uint32_t insn, uint64_t orig_addr )
{
    const int rn = (insn >> 5) & 0x1F;

    if (rn == 31) return;

    /* Single, 9-bit immediate: type[11:10] 01 = post-index, 11 = pre-index. */
    if ((insn & 0x3B200000) == 0x38000000)
    {
        const int type = (insn >> 10) & 3;
        int64_t imm9;

        if (type != 1 && type != 3) return;            /* LDUR/STUR/LDTR: none */
        imm9 = (int64_t)((insn >> 12) & 0x1FF);
        if (imm9 & 0x100) imm9 -= 0x200;
        REGn_sig(rn, ctx) = (type == 1) ? orig_addr + imm9 : orig_addr;
        return;
    }

    /* Pair: [25:23] 001 = post-index, 011 = pre-index, 010 = signed offset. */
    if ((insn & 0x3A000000) == 0x28000000)
    {
        const int kind  = (insn >> 23) & 3;
        const int is_v  = (insn >> 26) & 1;
        const int p_opc = (insn >> 30) & 3;
        int scale;
        int64_t imm7;

        if (kind != 1 && kind != 3) return;
        scale = is_v ? (4 << p_opc) : ((p_opc & 2) ? 8 : 4);
        imm7  = (int64_t)((insn >> 15) & 0x7F);
        if (imm7 & 0x40) imm7 -= 0x80;
        imm7 *= scale;
        REGn_sig(rn, ctx) = (kind == 1) ? orig_addr + imm7 : orig_addr;
    }
}

/*
 * Service one fault against a registered sub-floor window. Returns 1 if the
 * access was emulated and the caller should step the PC and resume.
 */
/*
 * ml956: what the faulting instruction would do to the backing, decided
 * WITHOUT touching it. The order and the masks mirror ios_emulate_load /
 * ios_emulate_store_rel / ios_emulate_store exactly -- including the
 * `opc == 0 -> return 0` guards that keep stores out of the load emulator --
 * so a classification can never disagree with the emulator that will actually
 * run. Returns 1 when the encoding is one of those three cover; *bytes is the
 * full access span and *is_write is set for stores AND for read-modify-write
 * atomics (which both read and write).
 *
 * Why this exists: ios_emulate_load/_store/_store_rel dereference their
 * address argument naked. That contract was written for the W^X pool path,
 * where the caller had already resolved a known-writable RW anon alias.
 * ios_subfloor_service passes a raw PE backing address instead, which can be
 * read-only (.text / .rdata), or stale, or gone. When that dereference faults,
 * the faulting thread IS the Mach exception thread: its own exception is sent
 * to the port that only it services, so it waits on itself for ever, and every
 * guest thread waiting for a fault reply parks behind it. rdr20 caught exactly
 * that -- "wine-x18-exc" stopped in ios_emulate_store+0x70 (str w9,[x2]) under
 * ios_subfloor_service, while a guest thread sat at ReadFile+0xac (str w8,[x26],
 * the STATUS_PENDING store that precedes NtReadFile) waiting for a reply that
 * could never come. Nothing logged, because a handler that faults inside
 * itself never reaches its own error path.
 */
static int ios_subfloor_classify( uint32_t insn, unsigned *bytes, int *is_write )
{
    const int size = (insn >> 30) & 3;
    const int opc  = (insn >> 22) & 3;

    *bytes    = 1u << size;
    *is_write = 0;

    /* ---- ios_emulate_load: pure loads (tried first, so it wins ties) ---- */
    if ((insn & 0x3FFFFC00) == 0x38BFC000) return 1;                /* LDAPR*  */
    if ((insn & 0x3F200C00) == 0x19000000 && opc != 0)              /* ml1231: LDAPUR* */
        return !((size == 3 && opc >= 2) || (size == 2 && opc == 3));
    if ((insn & 0x3FFFFC00) == 0x08DFFC00 ||                        /* LDAR    */
        (insn & 0x3FFFFC00) == 0x085FFC00 ||                        /* LDAXR   */
        (insn & 0x3FFFFC00) == 0x085F7C00) return 1;                /* LDXR    */
    if ((insn & 0x3F000000) == 0x39000000 && opc != 0) return 1;    /* LDR uimm */
    if ((insn & 0x3F200000) == 0x38000000 && opc != 0) return 1;    /* LDUR 9b  */
    if ((insn & 0x3F200C00) == 0x38200800 && opc != 0) return 1;    /* LDR reg  */
    if ((insn & 0x3E400000) == 0x28400000)                          /* LDP/LDPSW */
    {
        const int p = (insn >> 30) & 3;
        if (p == 3) return 0;
        *bytes = (p == 2) ? 16 : 8;   /* 64-bit pair, else two 32-bit halves */
        return 1;
    }
    if ((insn & 0x3F000000) == 0x3D000000 ||                        /* FP/SIMD  */
        (insn & 0x3F200000) == 0x3C000000 ||
        (insn & 0x3F200C00) == 0x3C200800)
    {
        /* width is size plus opc bit 23; opc bit 22 is L. */
        *bytes    = (size == 0 && (opc & 2)) ? 16u : (1u << size);
        *is_write = !(opc & 1);
        return 1;
    }

    /* ---- ios_emulate_store_rel: release / exclusive / LSE ---- */
    if ((insn & 0x3FFFFC00) == 0x089FFC00 ||                        /* STLR*   */
        (insn & 0x3FFFFC00) == 0x089F7C00 ||                        /* STLLR*  */
        (insn & 0x3FE00C00) == 0x19000000 ||                        /* ml1231: STLUR* */
        (insn & 0x3FE0FC00) == 0x0800FC00 ||                        /* STLXR   */
        (insn & 0x3FE0FC00) == 0x08007C00)                          /* STXR    */
    {
        *is_write = 1;
        return 1;
    }
    if ((insn & 0x3F20FC00) == 0x38200000 ||                        /* LDADD   */
        (insn & 0x3F20FC00) == 0x38201000 ||                        /* LDCLR   */
        (insn & 0x3F20FC00) == 0x38202000 ||                        /* LDEOR   */
        (insn & 0x3F20FC00) == 0x38203000 ||                        /* LDSET   */
        (insn & 0x3F20FC00) == 0x38208000)                          /* SWP     */
    {
        *is_write = 1;   /* RMW: needs read AND write */
        return 1;
    }
    if ((insn & 0x3E000000) == 0x2C000000)                          /* SIMD pair */
    {
        const int p = (insn >> 30) & 3;
        if (p == 3) return 0;                                       /* reserved */
        *bytes    = 2u * (4u << p);                                 /* S/D/Q pair */
        *is_write = !((insn >> 22) & 1);
        return 1;
    }

    /* ---- ios_emulate_store: plain stores, STP, CAS ---- */
    if ((insn & 0x3FC00000) == 0x39000000 ||                        /* STR uimm */
        (insn & 0x3FE00000) == 0x38000000 ||                        /* STUR 9b  */
        (insn & 0x3FE00C00) == 0x38200800)                          /* STR reg  */
    {
        *is_write = 1;
        return 1;
    }
    if ((insn & 0x3E400000) == 0x28000000)                          /* STP      */
    {
        const int p = (insn >> 30) & 3;
        if (p == 3) return 0;
        *bytes    = (p == 2) ? 16 : 8;
        *is_write = 1;
        return 1;
    }
    if ((insn & 0xBFA07C00) == 0x88A07C00 ||                        /* CAS*     */
        (insn & 0xBFA07C00) == 0x08207C00)
    {
        *bytes    = ((insn >> 30) & 1) ? 8u : 4u;
        *is_write = 1;                                              /* RMW      */
        return 1;
    }
    if ((insn & 0xBFA07C00) == 0x08A07C00)                          /* CASB/CASH (ml1208) */
    {
        *bytes    = ((insn >> 30) & 1) ? 2u : 1u;
        *is_write = 1;
        return 1;
    }
    if ((insn & 0xFFA00C00) == 0x3C800000)                          /* SIMD st  */
    {
        *bytes    = 16;
        *is_write = 1;
        return 1;
    }

    return 0;   /* not ours -- caller takes the existing UNHANDLED path */
}

/*
 * ml956: is [real, real + bytes) mapped, with the permission this access
 * needs? Answered with Mach region queries only -- never a dereference -- so
 * the exception thread cannot fault while deciding. Walks every region the
 * span touches, because a span can straddle a section boundary (R-X .text into
 * R-- .rdata) or run off the end of the mapping into a hole.
 *
 * mach_vm_region_recurse, not mach_vm_region: the latter hands back an
 * object-name port on every call. The existing mach_vm_region sites in this
 * file sit on rare diagnostic paths and leak it harmlessly, but this gate runs
 * once per serviced fault -- 462,849 times in rdr20 -- and would exhaust the
 * task's port table. The recurse form returns no port.
 */
static int ios_subfloor_backing_probe( uintptr_t real, unsigned bytes, int need_write,
                                       unsigned long long *rb_out, unsigned long long *rs_out,
                                       unsigned *cur_out, unsigned *max_out, int *kr_out )
{
    const uintptr_t end = real + bytes;
    uintptr_t p = real;

    *rb_out = 0; *rs_out = 0; *cur_out = 0; *max_out = 0; *kr_out = KERN_SUCCESS;

    if (end < real) return 0;                       /* span overflowed */

    while (p < end)
    {
        mach_vm_address_t rb = (mach_vm_address_t)p;
        mach_vm_size_t    rs = 0;
        natural_t         depth = 0;
        vm_region_submap_short_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
        kern_return_t kr;

        memset( &info, 0, sizeof(info) );
        kr = mach_vm_region_recurse( mach_task_self(), &rb, &rs, &depth,
                                     (vm_region_recurse_info_t)&info, &cnt );
        if (kr != KERN_SUCCESS) { *kr_out = (int)kr; return 0; }

        /* Record whatever region we are judging, so a refusal names it. */
        *rb_out  = (unsigned long long)rb;
        *rs_out  = (unsigned long long)rs;
        *cur_out = (unsigned)info.protection;
        *max_out = (unsigned)info.max_protection;

        /* The query returns the first region at or ABOVE rb. If it starts past
         * p, then p itself is in a hole -- unmapped. */
        if (rb > (mach_vm_address_t)p) return 0;
        if (!(info.protection & VM_PROT_READ)) return 0;
        if (need_write && !(info.protection & VM_PROT_WRITE)) return 0;
        if (!rs) return 0;                          /* no forward progress */

        p = (uintptr_t)(rb + rs);
    }
    return 1;
}

static int ios_subfloor_service( ucontext_t *ctx, void *fault_addr, const char *via, void *peb )
{
    uint64_t addr = (uint64_t)(uintptr_t)fault_addr;
    uintptr_t real = ios_subfloor_translate( addr, peb );
    uint32_t insn = 0;
    unsigned bytes = 0, span = 8;
    int is_write = 0, ok, cls = 0;
    unsigned long long rb = 0, rs = 0;
    unsigned cur = 0, mx = 0;
    int kr = 0;
    mach_vm_size_t got = 0;

    /* ml966: a translate miss is no longer fatal on its own -- a low guest
     * allocation is resolved further down, once the access span is known. But
     * reject anything that cannot possibly be one BEFORE doing the instruction
     * read and classification below: that work used to be skipped entirely for
     * a miss, and this is the general fault path, so paying for it on every
     * unrelated fault would be a real regression. The literals mirror
     * IOS_LOWALLOC_BASE/LIMIT in virtual_ios.c. */
    /* ml969 widens this: an alias can sit anywhere in the low 4 GB, not just in
     * the ml966 arena, so any SUB-FLOOR address has to be offered to the
     * registry. Addresses at or above the floor still reject immediately,
     * which is the common case and keeps the general fault path cheap. */
    if (!real && addr >= IOS_SUBFLOOR_FLOOR) return 0;

    /* ml956: read the faulting instruction through a failure-returning copy.
     * A naked deref of PC_sig here is the same self-fault hazard as the
     * backing access below -- an unmapped or stale PC would stop the exception
     * thread inside its own handler instead of reporting anything. */
    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(uintptr_t)PC_sig(ctx),
                                4, (mach_vm_address_t)&insn, &got ) != KERN_SUCCESS || got != 4)
    {
        static int pc_unreadable;
        if (pc_unreadable++ < 8)
            dprintf( 2, "[subfloor] ml956 via=%s DECLINING: pc=%#llx unreadable, guest %#llx -> real %#llx\n",
                     via, (unsigned long long)PC_sig(ctx), (unsigned long long)addr,
                     (unsigned long long)real );
        return 0;
    }

    /* ml956: decide what the access needs, then prove the backing can take it,
     * BEFORE handing the address to an emulator that dereferences it naked.
     * An address-translation hit is not permission to dereference its result. */
    cls = ios_subfloor_classify( insn, &bytes, &is_write );
    /* classify writes *bytes before it decides, so on a miss the value is a
     * guess -- use a conservative 8-byte span for bounds checks in that case
     * and keep the accessibility probe gated on the result, as before. */
    span = cls ? bytes : 8u;

    /* ml966: a low guest ALLOCATION resolves through its own registry, not the
     * ml938 image-window table. Checked here rather than in
     * ios_subfloor_translate on purpose: this is the first point where the
     * classified access SPAN is known, and the whole span has to be inside the
     * allocation's bounds. The image table translates on the start address
     * alone, which is safe enough for a fixed image but not for dynamic
     * allocations -- an access straddling the end must be refused, not
     * silently resolved into whatever follows the backing.
     *
     * Ownership is recorded and logged but not enforced here: this handler runs
     * on the Mach exception thread, not the faulting guest thread, so the
     * current peb is the handler's and cannot be compared. Ownership IS
     * enforced on the allocate/free paths, which run on the guest's own thread.
     * Sound for a single-owner experiment; a general mechanism would need the
     * faulting thread's identity plumbed through. */
    if (!real)
    {
        extern int ios_lowalloc_translate( unsigned long long addr, unsigned long long len,
                                           unsigned long long *real_out, void **owner_out );
        unsigned long long lo_real = 0;
        void *lo_owner = NULL;
        if (ios_lowalloc_translate( addr, span, &lo_real, &lo_owner ))
        {
            static unsigned long long la_hits;
            real = (uintptr_t)lo_real;
            if ((++la_hits & 0xFFF) == 1)
                dprintf( 2, "[lowalloc] ml966 serviced %llu access(es); latest guest %#llx (%u byte span, %s)"
                         " -> backing %#llx owner=%p\n",
                         la_hits, (unsigned long long)addr, span,
                         is_write ? "write" : "read", lo_real, lo_owner );
        }
        else
        {
            static int la_miss;
            /* A low address in the experiment's range that no live allocation
             * covers: either a span running off the end, or an access after
             * the translation was retired. Both must be refused, and both are
             * worth naming -- a retired-translation access is a use-after-free
             * in the guest, not something to paper over. */
            if (la_miss < 16)
            {
                la_miss++;
                dprintf( 2, "[lowalloc] ml966 REFUSED guest %#llx (%u byte span%s): no live allocation "
                         "covers it (off-the-end, or translation already retired)\n",
                         (unsigned long long)addr, span, cls ? "" : ", encoding unknown so span assumed" );
            }
            return 0;
        }
    }

    if (cls &&
        !ios_subfloor_backing_probe( real, bytes, is_write, &rb, &rs, &cur, &mx, &kr ))
    {
        /* Capture, then decline. Declining lands on exactly the path an
         * unknown encoding already takes, so it cannot regress anything --
         * and unlike a dereference it cannot wedge the handler. The guest
         * thread gets the normal fault disposition instead of a reply that
         * never arrives. Keyed on the distinct guest page so a hot loop
         * cannot flood the log (ml945's lesson). */
        static uint64_t seen_pg[16];
        static int nseen_pg;
        int i, fresh = 1;
        uint64_t pg = addr & ~0xFFFULL;

        ios_subfloor_refused++;
        for (i = 0; i < nseen_pg; i++) if (seen_pg[i] == pg) { fresh = 0; break; }
        if (fresh && nseen_pg < 16) seen_pg[nseen_pg++] = pg;
        if (fresh)
        {
            extern uintptr_t ios_jit_anon_alias_lookup(uintptr_t fault_addr);
            extern void *ios_jit_translate_addr(void *addr);
            uintptr_t rw_alias = ios_jit_anon_alias_lookup( real );
            void *pool_copy = ios_jit_translate_addr( (void *)real );

            dprintf( 2, "[subfloor] ml956 via=%s REFUSED %s of %u byte(s): guest %#llx -> real %#llx "
                     "insn=%#010x pc=%#llx | backing region %#llx+%#llx cur_prot=%#x max_prot=%#x kr=%d "
                     "| anon_rw_alias=%#llx pool_copy=%#llx\n",
                     via, is_write ? "WRITE" : "read", bytes,
                     (unsigned long long)addr, (unsigned long long)real, insn,
                     (unsigned long long)PC_sig(ctx), rb, rs, cur, mx, kr,
                     (unsigned long long)rw_alias,
                     (unsigned long long)(pool_copy == (void *)real ? 0 : (uintptr_t)pool_copy) );
        }
        return 0;
    }

    /* ml1000: the emulator chain tries LOAD first and never consults is_write,
     * which ios_subfloor_classify has already decided from the encoding. If the
     * emulator that claims the instruction disagrees with that decision, the
     * access was serviced INCORRECTLY and silently: a store claimed by the load
     * emulator is DROPPED (stale bytes survive), and a load claimed by a store
     * emulator WRITES over guest data. Either one corrupts the guest invisibly,
     * and this path serviced 20,481 accesses in rdr69 with "0 unhandled".
     *
     * rdr69's motivation: the DRM's launcher-check code resolves its imports
     * (GetModuleFileNameW, PathFileExistsW, SHGetFolderPathA, CreateFileA,
     * ReadFile, GetFileSize, CreateProcessA, MessageBoxA, MessageBoxTimeoutA,
     * ExitProcess, _itoa, memcpy) by name, and two of those names arrive
     * TRUNCATED to a single character ("a", "k" -- the latter consistent with
     * "kernel32"). Single-byte truncation is what a misplaced byte store does,
     * and the subfloor traffic is full of size=00 byte accesses
     * (insn=0x38bfc041 family). This does not yet prove that link -- it makes
     * the misservice observable instead of silent. */
    {
        char claimed = 0;

        ok = ios_emulate_load( ctx, insn, real );
        if (ok) claimed = 'L';
        if (!ok) { ok = ios_emulate_store_rel( ctx, insn, real ); if (ok) claimed = 'R'; }
        if (!ok) { ok = ios_emulate_store( ctx, insn, real );     if (ok) claimed = 'S'; }

        if (ok && cls && ((is_write && claimed == 'L') || (!is_write && claimed != 'L')))
        {
            static unsigned miss_n;
            if (miss_n++ < 32)
                dprintf( 2, "ml1000: SUBFLOOR MISSERVICE insn=%08x classify=%s(%u bytes) but "
                         "emulated as %s -- guest %#llx real %#llx pc %#llx via=%s\n",
                         insn, is_write ? "WRITE" : "read", bytes,
                         claimed == 'L' ? "LOAD" : (claimed == 'R' ? "STORE_REL" : "STORE"),
                         (unsigned long long)addr, (unsigned long long)real,
                         (unsigned long long)PC_sig(ctx), via );
        }
        /* Byte-width writes of NUL are the specific truncation candidate: one of
         * these landing mid-string turns "kernel32" into "k". Log the value and
         * the four bytes that follow so a truncated table entry is visible in
         * the log rather than inferred from a failed LoadLibrary later. */
        if (ok && cls && is_write && bytes == 1)
        {
            unsigned char v = *(volatile unsigned char *)real;
            if (!v)
            {
                static unsigned nul_n;
                if (nul_n++ < 24)
                {
                    unsigned char nb[5] = { 0 };
                    mach_vm_size_t ngot = 0;
                    mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(real + 1), 4,
                                            (mach_vm_address_t)nb, &ngot );
                    dprintf( 2, "ml1000: subfloor wrote NUL at guest %#llx (real %#llx) insn=%08x;"
                             " next4=%02x %02x %02x %02x (%c%c%c%c)\n",
                             (unsigned long long)addr, (unsigned long long)real, insn,
                             nb[0], nb[1], nb[2], nb[3],
                             nb[0] > 31 && nb[0] < 127 ? nb[0] : '.',
                             nb[1] > 31 && nb[1] < 127 ? nb[1] : '.',
                             nb[2] > 31 && nb[2] < 127 ? nb[2] : '.',
                             nb[3] > 31 && nb[3] < 127 ? nb[3] : '.' );
                }
            }
        }
    }
    if (!ok)
    {
        /* An encoding we do not cover. Say so once per distinct encoding and
         * let the normal fault path take it -- identical to today's behaviour,
         * so an unknown instruction cannot regress anything, and the log names
         * the exact word to add. */
        static uint32_t seen[16];
        static int nseen;
        int i;

        ios_subfloor_unknown++;
        for (i = 0; i < nseen; i++) if (seen[i] == insn) return 0;
        if (nseen < 16) seen[nseen++] = insn;
        dprintf( 2, "[subfloor] ml939 via=%s UNHANDLED encoding %#010x at pc=%#llx for guest addr %#llx "
                 "(real %#llx) -- add it to ios_emulate_load/store\n",
                 via, insn, (unsigned long long)PC_sig(ctx), (unsigned long long)addr,
                 (unsigned long long)real );
        return 0;
    }

    ios_subfloor_writeback( ctx, insn, addr );
    /* ml1055: WHO is touching the window. One run serviced 12,029,953 of these
     * through the Mach exception path (~18,000 a second, a fifth of all running
     * CPU samples were in mach_msg). Whether the accessor is the sub-floor
     * image's own code or the main image decides the fix (translate at JIT time
     * for blocks that live in the window, vs backpatching arbitrary sites), so
     * attribute each hit to the page of the guest RIP in the FEX frame. */
    {
        static struct { uint64_t page; unsigned long long n; } hist[48];
        static unsigned long long no_frame;
        uint64_t x28 = REGn_sig( 28, ctx ), grip = 0;
        mach_vm_size_t got = 0;
        int h;
        if (x28 >= 0x100000000ULL && x28 < 0xfffffff000000000ULL &&
            mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(x28 + 0x18), 8,
                                    (mach_vm_address_t)&grip, &got ) == KERN_SUCCESS && got == 8 && grip)
        {
            uint64_t page = grip >> 12;
            for (h = 0; h < 48; h++)
            {
                if (hist[h].page == page) { hist[h].n++; break; }
                if (!hist[h].page) { hist[h].page = page; hist[h].n = 1; break; }
            }
        }
        else no_frame++;
        if ((ios_subfloor_hits & 0xFFFFF) == 0xFFFFF)
        {
            char line[1500]; int n = 0;
            for (h = 0; h < 48 && hist[h].page; h++)
                if (hist[h].n > 2000)
                    n += snprintf( line + n, sizeof(line) - n, " %llx:%llu", (unsigned long long)hist[h].page << 12, hist[h].n );
            dprintf( 2, "[subfloor] ml1055 accessor guest-RIP pages after %llu hits (no FEX frame: %llu):%s\n",
                     ios_subfloor_hits + 1, no_frame, n ? line : " (none above 2000)" );
        }
    }
    if ((++ios_subfloor_hits & 0xFFF) == 1)
        dprintf( 2, "[subfloor] ml956 serviced %llu access(es) (%llu unhandled, %llu refused) via=%s; "
                 "latest guest %#llx -> real %#llx insn=%#010x\n",
                 ios_subfloor_hits, ios_subfloor_unknown, ios_subfloor_refused, via,
                 (unsigned long long)addr, (unsigned long long)real, insn );
    return 1;
}
#endif


/**********************************************************************
 *		bus_handler
 *
 * Handler for SIGBUS.
 */
static void bus_handler( int signal, siginfo_t *siginfo, void *sigcontext )
{
    EXCEPTION_RECORD rec = { EXCEPTION_DATATYPE_MISALIGNMENT };
#ifdef WINE_IOS
    /* ml481 (#85): foreign-thread faults must not reach wine logging — see
     * ios_fault_is_foreign(). Must precede ios_make_wine_logging_safe(). */
    if (ios_fault_is_foreign( (void *)PC_sig( (ucontext_t *)sigcontext ), siginfo->si_addr ))
    {
        ios_decline_foreign_fault( signal, (void *)PC_sig( (ucontext_t *)sigcontext ), siginfo->si_addr );
        return;
    }
    ios_make_wine_logging_safe();   /* ml375: before any ERR/WARN — see helper */
    ios_track_signal( signal, sigcontext );
    static int bus_count = 0;
    bus_count++;
    if (bus_count <= 5)
    {
        uintptr_t bus_pc_val = (uintptr_t)PC_sig((ucontext_t*)sigcontext);
        uintptr_t bus_lr_val = (uintptr_t)LR_sig((ucontext_t*)sigcontext);
        /* iOS user space starts ~0x100000000; anything below is unmapped. */
        int bus_pc_ok = (bus_pc_val >= 0x100000000ULL);
        int bus_lr_ok = (bus_lr_val >= 0x100000000ULL + 4);
        uint32_t bus_insn = bus_pc_ok ? *(uint32_t*)bus_pc_val : 0;
        uint32_t bus_branch_insn = bus_lr_ok ? *(uint32_t*)(bus_lr_val - 4) : 0;
        ERR("BUS #%d: pc=%p addr=%p x16=%p x17=%p x18=%p lr=%p insn=0x%08x branch@lr-4=0x%08x%s\n",
            bus_count, (void*)bus_pc_val, siginfo->si_addr,
            (void*)REGn_sig(16, (ucontext_t*)sigcontext),
            (void*)REGn_sig(17, (ucontext_t*)sigcontext),
            (void*)REGn_sig(18, (ucontext_t*)sigcontext),
            (void*)bus_lr_val, bus_insn, bus_branch_insn,
            bus_pc_ok ? "" : " <unmappable PC>");
        /* Dump Mach handler .data fault diagnostic (first fault only) */
        if (bus_count == 1 && ios_exc_data_fault_count > 0)
        {
            ERR("  Mach 1st .data: pc=0x%llx lr=0x%llx sp=0x%llx cnt=%d\n",
                (unsigned long long)ios_exc_data_fault_pc,
                (unsigned long long)ios_exc_data_fault_lr,
                (unsigned long long)ios_exc_data_fault_sp,
                ios_exc_data_fault_count);
            ERR("  Mach regs: x0=%llx x1=%llx x2=%llx x3=%llx\n",
                (unsigned long long)ios_exc_data_x0,
                (unsigned long long)ios_exc_data_x1,
                (unsigned long long)ios_exc_data_x2,
                (unsigned long long)ios_exc_data_x3);
            ERR("  Mach regs: x16=%llx x17=%llx x18=%llx x29=%llx\n",
                (unsigned long long)ios_exc_data_x16,
                (unsigned long long)ios_exc_data_x17,
                (unsigned long long)ios_exc_data_x18,
                (unsigned long long)ios_exc_data_x29);
            ERR("  insn@LR=0x%08x frame_ptr=0x%llx frame->pc=0x%llx\n",
                ios_exc_data_insn_at_lr,
                (unsigned long long)ios_exc_data_fault_frame_ptr,
                (unsigned long long)ios_exc_data_fault_frame_pc);
        }
    }
    ucontext_t *bus_ctx = sigcontext;
    void *pc = (void *)PC_sig(bus_ctx);
    int is_exec_fault = (pc == siginfo->si_addr);

    /* 1. Execution fault (pc == fault_addr): redirect to JIT pool copy.
     * This handles indirect calls through function pointers, import tables, etc. */
    if (is_exec_fault)
    {
        extern void *ios_jit_translate_addr(void *addr);
        extern int ios_jit_addr_is_text(uintptr_t addr);
        extern void *ios_jit_rx_base_global;
        extern size_t ios_jit_pool_size_global;
        extern uintptr_t ios_jit_anon_alias_lookup_rx(uintptr_t fault_addr);

        void *jit_pc = ios_jit_translate_addr(pc);
        if (jit_pc == pc) {
            /* Try the anon-alias table (FEX CodeBuffer / runtime JIT) */
            uintptr_t rx_pc = ios_jit_anon_alias_lookup_rx((uintptr_t)pc);
            if (rx_pc) jit_pc = (void *)rx_pc;
        }
        if (jit_pc != pc)
        {
            /* Use trampoline to set x18 (sigreturn zeroes it on iOS) */
            if (ios_my_trampoline && ios_teb_for_signals)
            {
                REGn_sig(17, bus_ctx) = (uintptr_t)jit_pc;
                PC_sig(bus_ctx) = (uintptr_t)ios_my_trampoline;
            }
            else
            {
                PC_sig(bus_ctx) = (uintptr_t)jit_pc;
            }
            return;  /* Resume from JIT pool address */
        }

        /* Execution fault at address already in JIT pool (can't redirect).
         * This means code jumped into a non-executable section (.data, .rdata).
         * Do NOT fall through to store emulation — that would walk PC through
         * data bytes for thousands of faults. Log diagnostics and crash. */
        {
            uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
            size_t pool_sz = ios_jit_pool_size_global;
            if (rx && (uintptr_t)pc >= rx && (uintptr_t)pc < rx + pool_sz)
            {
                extern volatile uint64_t g_wine_return_pc;
                extern volatile uint64_t g_wine_return_x18;
                extern volatile uint64_t g_wine_return_count;
                ERR("BUS EXEC in JIT .data: pc=%p (pool+0x%lx) lr=%p sp=%p\n",
                    pc, (unsigned long)((uintptr_t)pc - rx),
                    (void*)LR_sig(bus_ctx), (void*)SP_sig(bus_ctx));
                ERR("  x0=%p x1=%p x2=%p x3=%p\n",
                    (void*)REGn_sig(0, bus_ctx), (void*)REGn_sig(1, bus_ctx),
                    (void*)REGn_sig(2, bus_ctx), (void*)REGn_sig(3, bus_ctx));
                ERR("  x16=%p x17=%p x18=%p x29=%p\n",
                    (void*)REGn_sig(16, bus_ctx), (void*)REGn_sig(17, bus_ctx),
                    (void*)REGn_sig(18, bus_ctx), (void*)REGn_sig(29, bus_ctx));
                ERR("  last dispatcher_return: pc=%p x18=%p count=%llu\n",
                    (void*)(uintptr_t)g_wine_return_pc,
                    (void*)(uintptr_t)g_wine_return_x18,
                    (unsigned long long)g_wine_return_count);
                {
                    extern volatile uint64_t g_wine_dispatcher_count;
                    extern volatile int ios_total_segv_count;
                    /* Read instruction at LR-4 (the BL/BLR that set LR) */
                    uint32_t insn_lr_m4 = 0;
                    uintptr_t lr_val = (uintptr_t)LR_sig(bus_ctx);
                    if (lr_val >= 4) insn_lr_m4 = *(uint32_t *)(lr_val - 4);
                    ERR("  disp_entry=%llu segv_count=%d insn@LR-4=0x%08x\n",
                        (unsigned long long)g_wine_dispatcher_count,
                        ios_total_segv_count, insn_lr_m4);
                }
                ERR("  is_text=%d mach_data_faults=%d mach_x18_fixes=%lld\n",
                    ios_jit_addr_is_text((uintptr_t)pc),
                    ios_exc_data_fault_count, (long long)ios_exc_x18_fixes);
                /* Dump ring buffer of last 8 dispatcher_return PCs */
                {
                    extern volatile uint64_t g_wine_return_ring[8];
                    extern volatile uint32_t g_wine_return_ring_idx;
                    uint32_t ri = g_wine_return_ring_idx;
                    ERR("  ret ring (newest→oldest): %p %p %p %p %p %p %p %p\n",
                        (void*)(uintptr_t)g_wine_return_ring[(ri-1)&7],
                        (void*)(uintptr_t)g_wine_return_ring[(ri-2)&7],
                        (void*)(uintptr_t)g_wine_return_ring[(ri-3)&7],
                        (void*)(uintptr_t)g_wine_return_ring[(ri-4)&7],
                        (void*)(uintptr_t)g_wine_return_ring[(ri-5)&7],
                        (void*)(uintptr_t)g_wine_return_ring[(ri-6)&7],
                        (void*)(uintptr_t)g_wine_return_ring[(ri-7)&7],
                        (void*)(uintptr_t)g_wine_return_ring[(ri-8)&7]);
                }
                /* Don't try store emulation, go straight to exception */
                goto bus_fatal;
            }
        }
    }

    /* 2. Data write fault (pc != fault_addr): code in JIT pool tries to write
     * to a data section in the JIT pool RX view. Emulate the store by
     * writing through the RW view instead. */
    {
        extern void *ios_jit_rx_base_global;
        extern void *ios_jit_rw_base_global;
        extern size_t ios_jit_pool_size_global;

        uintptr_t fault = (uintptr_t)siginfo->si_addr;
        uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
        uintptr_t rw = (uintptr_t)ios_jit_rw_base_global;
        size_t pool_sz = ios_jit_pool_size_global;

        if (rx && fault >= rx && fault < rx + pool_sz)
        {
            uintptr_t rw_addr = fault - rx + rw;
            uint32_t insn = *(uint32_t *)(uintptr_t)PC_sig(bus_ctx);

            if (ios_emulate_store(bus_ctx, insn, rw_addr))
            {
                PC_sig(bus_ctx) += 4;
                ios_fixup_x18_for_return( bus_ctx );
                return;  /* Resume after the emulated store */
            }
            /* ml264 (#45): NAME THE MEMORY, not the instruction.
             *
             * All four failing instructions in ml264 target the SAME address
             * 0x156a097b0 (pool offset 0x361b57b0, tail/JIT-code area) and all four
             * are ATOMICS of different widths:
             *   0x88eafe89  CAS   32-bit   x1
             *   0xc8f1fd60  CAS   64-bit   x1
             *   0x4866fd64  CASPAL 128-bit x1
             *   0x4866fe6a  CASPAL 128-bit x59
             * A location that rejects atomics at EVERY width is not an instruction
             * problem -- the Size==1 CASPAL implementation is in and working, and
             * [caspal128] is silent. On Apple silicon LSE atomics require normal
             * cacheable memory, and this pool is mach_vm_remap dual-mapped (RW alias
             * + RX alias), which is exactly the kind of mapping where they fault.
             *
             * Two readings need opposite fixes: (a) the whole dual-mapped pool
             * rejects atomics -- then FEX's own atomics on pool-resident structures
             * can never work there and the data must move; (b) only THIS page is bad
             * (reclaimed, or the single-page RW poison of task #41) -- a page-level
             * problem with a page-level fix. protection/max_protection/share_mode/
             * user_tag distinguish them. Capped; fires only on an already-fatal path. */
            {
                static int busrgn;
                if (busrgn++ < 10)
                {
                    mach_vm_address_t ba = (mach_vm_address_t)(uintptr_t)siginfo->si_addr;
                    mach_vm_size_t bs = 0;
                    vm_region_basic_info_data_64_t bbi;
                    mach_msg_type_number_t bbc = VM_REGION_BASIC_INFO_COUNT_64;
                    mach_port_t bbo = MACH_PORT_NULL;
                    mach_vm_address_t xa = (mach_vm_address_t)(uintptr_t)siginfo->si_addr;
                    mach_vm_size_t xs = 0;
                    vm_region_extended_info_data_t xi;
                    mach_msg_type_number_t xc = VM_REGION_EXTENDED_INFO_COUNT;
                    mach_port_t xo = MACH_PORT_NULL;
                    extern void *ios_jit_rx_base_global, *ios_jit_rw_base_global;
                    extern size_t ios_jit_pool_size_global;
                    uintptr_t rxb = (uintptr_t)ios_jit_rx_base_global;
                    uintptr_t rwb = (uintptr_t)ios_jit_rw_base_global;
                    size_t psz = ios_jit_pool_size_global;
                    uintptr_t fa = (uintptr_t)siginfo->si_addr;
                    const char *where = "outside pool";

                    if (rxb && fa >= rxb && fa < rxb + psz) where = "JIT-POOL-RX (dual-mapped)";
                    else if (rwb && fa >= rwb && fa < rwb + psz) where = "JIT-POOL-RW (alias)";

                    if (mach_vm_region( mach_task_self(), &ba, &bs, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&bbi, &bbc, &bbo ) == KERN_SUCCESS &&
                        mach_vm_region( mach_task_self(), &xa, &xs, VM_REGION_EXTENDED_INFO,
                                        (vm_region_info_t)&xi, &xc, &xo ) == KERN_SUCCESS)
                        ERR("[atomic-mem] addr=%p %s pooloff=0x%llx | region=0x%llx+0x%llx "
                            "prot=%d max=%d share_mode=%d user_tag=%d\n",
                            siginfo->si_addr, where,
                            (unsigned long long)(rxb && fa >= rxb ? fa - rxb : 0),
                            (unsigned long long)ba, (unsigned long long)bs,
                            bbi.protection, bbi.max_protection, xi.share_mode, xi.user_tag);
                    else
                        ERR("[atomic-mem] addr=%p %s -- mach_vm_region FAILED (unmapped?)\n",
                            siginfo->si_addr, where);
                }
            }
            ERR("BUS: unhandled store insn=0x%08x at pc=%p addr=%p\n",
                insn, pc, siginfo->si_addr);
        }

        /* 3. iOS-Madeira ml420 (#69, ml419 fatal chain): data fault with the
         * TARGET outside the pool. Two previously-unhandled sub-cases died
         * insanely here:
         *
         *   (a) Darwin delivers PROTECTION faults as SIGBUS (KERN_PROTECTION_
         *       FAILURE), not SIGSEGV — so every wine-legitimate PROT_NONE
         *       state (guard page, write-watch, commit-on-fault) that
         *       segv_handler repairs via virtual_handle_fault was unreachable
         *       from this handler and fell through to a bogus 80000002.
         *   (b) pc in the JIT pool + an UNREADABLE target page (ml419: emitted
         *       libcef sqlite code reading a stripped .rdata page): raising
         *       80000002 sent FEX down HandleUnalignedAccess (useless — the
         *       PAGE is the problem, not alignment) and the exception record
         *       carried the raw host pc into guest dispatch.
         *
         * Order: wine repair first; then a safe readability probe decides
         * honest-AV (unreadable) vs genuine-alignment 80000002 (readable). */
        if (!is_exec_fault && !(rx && fault >= rx && fault < rx + pool_sz))
        {
            EXCEPTION_RECORD vrec = { EXCEPTION_ACCESS_VIOLATION };
            mach_vm_size_t rd_out = 0;
            uint64_t rd_buf = 0;
            kern_return_t rd_kr;

            vrec.NumberParameters = 2;
            vrec.ExceptionInformation[0] = EXCEPTION_READ_FAULT;  /* refined below if the insn is a store */
            vrec.ExceptionInformation[1] = (ULONG_PTR)siginfo->si_addr;
            vrec.ExceptionAddress = (void *)PC_sig(bus_ctx);
            {
                uint32_t f_insn = *(uint32_t *)(uintptr_t)PC_sig(bus_ctx);
                /* loads have bit22 set in the ld/st register/immediate classes;
                 * good enough to label the fault direction for wine's repair */
                if ((f_insn & 0x0a000000) == 0x08000000 && !(f_insn & 0x00400000))
                    vrec.ExceptionInformation[0] = EXCEPTION_WRITE_FAULT;
            }

            if (!virtual_handle_fault( &vrec, (void *)SP_sig(bus_ctx) ))
            {
                static int bus_healed;
                if (bus_healed < 16 && ++bus_healed <= 16)
                    ERR("[bus-heal] virtual_handle_fault repaired addr=%p (pc=%p) — "
                        "guard/watch/commit state, was fatal before ml420\n",
                        siginfo->si_addr, pc);
                ios_fixup_x18_for_return( bus_ctx );
                return;
            }

            rd_kr = mach_vm_read_overwrite( mach_task_self(),
                                            (mach_vm_address_t)(uintptr_t)siginfo->si_addr & ~7ULL,
                                            8, (mach_vm_address_t)(uintptr_t)&rd_buf, &rd_out );

            /* name the memory once per class — this is the probe that finally
             * identifies WHAT state the page is in (ml419 had no region info) */
            {
                /* ml560: SEPARATE BUDGETS PER CLASS.
                 *
                 * ml559 lost the run that mattered to this cap. The single
                 * `busrgn2 < 10` counter was drained by ten early ALIGNMENT
                 * faults (69 of them that run), so when the fatal UNREADABLE
                 * fault arrived at cnt=127 there was no budget left and the
                 * region was never described. The noise class starved the
                 * subject class — an event cap where a per-subject cap was
                 * needed. Unreadable faults now have their own budget that
                 * alignment faults cannot touch. */
                static int busrgn2, busrgn_unread;
                int bus_is_unread = (rd_kr != KERN_SUCCESS);
                if (bus_is_unread ? (busrgn_unread++ < 8) : (busrgn2++ < 10))
                {
                    mach_vm_address_t ba = (mach_vm_address_t)(uintptr_t)siginfo->si_addr;
                    mach_vm_size_t bs = 0;
                    vm_region_basic_info_data_64_t bbi;
                    mach_msg_type_number_t bbc = VM_REGION_BASIC_INFO_COUNT_64;
                    mach_port_t bbo = MACH_PORT_NULL;
                    mach_vm_address_t xa = ba;
                    mach_vm_size_t xs = 0;
                    vm_region_extended_info_data_t xi;
                    mach_msg_type_number_t xc = VM_REGION_EXTENDED_INFO_COUNT;
                    mach_port_t xo = MACH_PORT_NULL;

                    ERR("[bus-rgn] si_code=%d addr=%p pc=%p pc_in_pool=%d readable=%d\n",
                        siginfo->si_code, siginfo->si_addr, pc,
                        (rx && (uintptr_t)pc >= rx && (uintptr_t)pc < rx + pool_sz) ? 1 : 0,
                        rd_kr == KERN_SUCCESS);
                    if (mach_vm_region( mach_task_self(), &ba, &bs, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&bbi, &bbc, &bbo ) == KERN_SUCCESS &&
                        mach_vm_region( mach_task_self(), &xa, &xs, VM_REGION_EXTENDED_INFO,
                                        (vm_region_info_t)&xi, &xc, &xo ) == KERN_SUCCESS)
                    {
                        ERR("[bus-rgn]   region=0x%llx+0x%llx prot=%d max=%d share_mode=%d user_tag=%d\n",
                            (unsigned long long)ba, (unsigned long long)bs,
                            bbi.protection, bbi.max_protection, xi.share_mode, xi.user_tag);

                        /* ml560: WHO OWNS THIS PAGE, and why can't it be materialised?
                         *
                         * ml559's fatal fault reported kr=10 (KERN_MEMORY_ERROR) on an
                         * address that was mapped, page-aligned, and RW both at handler
                         * entry and during the handler — yet a read probe of it FAILED.
                         * That is neither an absence fault nor a protection fault, so
                         * "protection was stripped" cannot be the explanation and the
                         * reheal below is a no-op for it.
                         *
                         * These fields separate the live hypotheses outright:
                         *   external_pager=1   -> section/file backed (a Valve or CEF
                         *                         shared-memory object) — suspect the
                         *                         backing object died or was truncated
                         *   external_pager=0   -> anonymous; then swapped_out>0 points at
                         *                         a compressor/decompression failure
                         *   purgeable VOLATILE/EMPTY -> the region was PURGED; the fix is
                         *                         ownership/lifetime, not protection
                         *   resident=0 + dirtied=0   -> never materialised at all
                         * user_tag names the allocator; shadow_depth/ref_count expose a
                         * broken COW chain. */
                        {
                            int purge_state = -1;
                            kern_return_t pk = mach_vm_purgable_control(
                                mach_task_self(), ba, VM_PURGABLE_GET_STATE,
                                (int *)&purge_state );
                            ERR("[bus-rgn]   OWNER extpager=%u resident=%u swapped=%u "
                                "dirtied=%u reusable=%u refcnt=%u shadow=%u  purgeable=%s(0x%x) "
                                "rev=ml560\n",
                                (unsigned)xi.external_pager, xi.pages_resident,
                                xi.pages_swapped_out, xi.pages_dirtied, xi.pages_reusable,
                                xi.ref_count, (unsigned)xi.shadow_depth,
                                pk != KERN_SUCCESS ? "not-purgeable" :
                                  ((purge_state & VM_PURGABLE_STATE_MASK) == VM_PURGABLE_EMPTY ? "EMPTY(PURGED)" :
                                   (purge_state & VM_PURGABLE_STATE_MASK) == VM_PURGABLE_VOLATILE ? "VOLATILE(can be purged)" :
                                   (purge_state & VM_PURGABLE_STATE_MASK) == VM_PURGABLE_NONVOLATILE ? "nonvolatile" : "other"),
                                pk == KERN_SUCCESS ? (unsigned)purge_state : 0u);
                            ERR("[bus-rgn]   VERDICT %s rev=ml560\n",
                                xi.external_pager
                                  ? "<== SECTION/FILE-BACKED — backing object is the suspect"
                                  : (xi.pages_swapped_out
                                       ? "<== ANONYMOUS + SWAPPED OUT — compressor/decompress suspect"
                                       : (xi.pages_resident == 0
                                            ? "<== ANONYMOUS, NEVER RESIDENT — never materialised"
                                            : "<== ANONYMOUS AND RESIDENT — none of the standard stories fit")));

                        /* ml561: WHO MADE THIS MAPPING, and which pages materialise?
                         *
                         * Two facts settle the "unbacked tail" story. First the
                         * provenance: if offset+host_size runs past the file's real
                         * size, the tail pages have no backing and touching them gives
                         * exactly this kr=10. Second the page census: probe every host
                         * page of the region and print which ones read — the prediction
                         * is that pages below +0x10000 succeed and the rest fail. If
                         * instead ALL pages read, the fault was transient and the whole
                         * EOF theory is wrong; the census says so either way. */
                        {
                            extern void ios_map_describe( const void *addr, char *out, size_t outlen );
                            char prov[420];
                            char census[96];
                            unsigned ci = 0;
                            mach_vm_address_t pa;
                            ios_map_describe( (const void *)(uintptr_t)ba, prov, sizeof(prov) );
                            ERR("[bus-rgn]   PROVENANCE %s rev=ml561\n", prov);
                            for (pa = ba; pa < ba + bs && ci < sizeof(census) - 2; pa += 0x4000)
                            {
                                unsigned char t; mach_vm_size_t got = 0;
                                census[ci++] = (mach_vm_read_overwrite( mach_task_self(), pa, 1,
                                                  (mach_vm_address_t)(uintptr_t)&t, &got )
                                                == KERN_SUCCESS && got == 1) ? '.' : 'X';
                            }
                            census[ci] = 0;
                            ERR("[bus-rgn]   PAGE-CENSUS 16KB pages from 0x%llx: [%s]  "
                                "('.'=materialises 'X'=fails; fault is at +0x%llx) rev=ml561\n",
                                (unsigned long long)ba, census,
                                (unsigned long long)((uintptr_t)siginfo->si_addr - (uintptr_t)ba));
                        }

                        /* ml561 (Sol's discriminator): DUMP THE GUEST FILL ARGUMENTS.
                         *
                         * The recurring victim is Skia's 2D 32-bit rect fill at
                         * libcef+0x41258F0, verified by disassembling the PHONE's
                         * libcef.dll:
                         *     fill32(dest=rcx, value=edx, width_dwords=r8d,
                         *            row_stride=r9, height=[rsp+0x30])
                         * ml554 and ml559 both faulted at EXACTLY region_base+0x10000
                         * (the 64KB Windows allocation granularity) in an 0x14000 region
                         * — i.e. four 16KB pages materialise and the fifth does not.
                         *
                         * Two stories fit, and these numbers separate them outright:
                         *   fill extent <= region end  -> the VIEW is right and the
                         *                                 BACKING is short (section
                         *                                 sizing/lifetime bug: mapping
                         *                                 past EOF gives exactly this)
                         *   fill extent >  region end  -> the guest OVERRAN; then the
                         *                                 width/stride/height tuple is
                         *                                 itself suspect, which would be
                         *                                 the first real bridge to the
                         *                                 tile-displacement bug
                         *
                         * No FEX reconstruction needed: under ARM64EC the guest regs ARE
                         * fixed ARM regs (rcx=x0, rdx=x1, r8=x2, r9=x3, r10=x4, rax=x8,
                         * rsp=x23) — confirmed by disassembling FEX's own output for this
                         * exact function. Reading the signal context cannot perturb FEX. */
                        /* ml562 CORRECTION: only interpret registers as fill arguments
                         * when the fault is actually the unreadable class. On ml561's
                         * ALIGNMENT faults this block printed "FILL OVERRUNS THE REGION —
                         * guest geometry is wrong" from registers that were not fill
                         * arguments at all — a confident verdict with no precondition.
                         * A probe that always renders a verdict is worse than silent. */
                        if (!bus_is_unread)
                            ERR("[fill-args] (skipped — not an unreadable-page fault; "
                                "registers are not fill arguments here) rev=ml562\n");
                        else
                        {
                            uint64_t g_rcx = REGn_sig(0,  bus_ctx);
                            uint64_t g_rdx = REGn_sig(1,  bus_ctx);
                            uint64_t g_r8  = REGn_sig(2,  bus_ctx);
                            uint64_t g_r9  = REGn_sig(3,  bus_ctx);
                            uint64_t g_r10 = REGn_sig(4,  bus_ctx);
                            uint64_t g_rax = REGn_sig(8,  bus_ctx);
                            uint64_t g_rsp = REGn_sig(23, bus_ctx);
                            uint32_t height = 0;
                            mach_vm_size_t hgot = 0;
                            int have_h = (mach_vm_read_overwrite( mach_task_self(),
                                            (mach_vm_address_t)(g_rsp + 0x30), 4,
                                            (mach_vm_address_t)(uintptr_t)&height,
                                            &hgot ) == KERN_SUCCESS && hgot == 4);
                            uint64_t w  = (uint32_t)g_r8, str = (uint32_t)g_r9;
                            uint64_t rows_left = (uint32_t)g_rax;
                            /* extent still to be written from the CURRENT row base */
                            uint64_t last = g_rcx + (rows_left ? (rows_left - 1) * str : 0)
                                                  + (w ? w * 4 : 0);
                            /* ml563 (Sol was right): gating on bus_is_unread is NOT a
                             * fill32 gate — any unreadable fault would still be decoded
                             * under the fill ABI. A RIP check needs the module base,
                             * which we do not have in a signal handler, so verify the
                             * REGISTER FILE is consistent with fill32 instead:
                             *   cursor r10 must BE the faulting address,
                             *   width/stride/height positive, row bytes <= stride,
                             *   row base <= cursor.
                             * All four held in ml561's three real events (r10 == addr,
                             * 256*4 == stride 1024, height 256). When they do not hold,
                             * say so and print NO verdict. */
                            int fill_ok = (g_r10 == (uint64_t)(uintptr_t)siginfo->si_addr) &&
                                          w > 0 && str > 0 && have_h && height > 0 &&
                                          (w * 4) <= str && g_rcx <= g_r10;
                            if (!fill_ok)
                            {
                                ERR("[fill-args] registers are NOT consistent with the fill32 ABI "
                                    "(r10=0x%llx vs addr=%p, width=%llu stride=%llu height=%u) "
                                    "— NOT interpreting, no verdict rev=ml563\n",
                                    (unsigned long long)g_r10, siginfo->si_addr,
                                    (unsigned long long)w, (unsigned long long)str, height);
                            }
                            else
                            ERR("[fill-args] rcx(dest_row)=0x%llx edx(val)=0x%08x "
                                "r8d(width_dw)=%llu r9(stride)=%llu r10(cursor)=0x%llx "
                                "eax(rows_left)=%llu rsp=0x%llx height@rsp+0x30=%s%u rev=ml561\n",
                                (unsigned long long)g_rcx, (unsigned)(uint32_t)g_rdx,
                                (unsigned long long)w, (unsigned long long)str,
                                (unsigned long long)g_r10, (unsigned long long)rows_left,
                                (unsigned long long)g_rsp, have_h ? "" : "UNREADABLE:", height);
                            if (fill_ok)
                            ERR("[fill-args]   region=[0x%llx,0x%llx)  cursor_off=0x%llx  "
                                "projected_last=0x%llx  %s rev=ml561\n",
                                (unsigned long long)ba, (unsigned long long)(ba + bs),
                                (unsigned long long)(g_r10 - ba),
                                (unsigned long long)last,
                                last <= (uint64_t)(ba + bs)
                                  ? "<== FILL FITS THE REGION — backing is short, NOT an overrun"
                                  : "<== FILL OVERRUNS THE REGION — guest geometry is wrong");
                        }
                        }
                    }
                    else
                        ERR("[bus-rgn]   mach_vm_region FAILED (address unmapped)\n");
                    {
                        extern void ios_dump_fault_region( void *addr );
                        ios_dump_fault_region( siginfo->si_addr );
                    }
                }
            }

            /* ml552: THE WRITE-SIDE TWIN of the reheal below.
             *
             * The existing reheal only fires when the page is UNREADABLE
             * (rd_kr != KERN_SUCCESS). But iOS strips PROT_WRITE while leaving
             * PROT_READ intact, and then the read probe SUCCEEDS, this whole
             * branch is skipped, and a plain guest store dies as a fatal
             * c0000005 -- with no reheal ever attempted.
             *
             * That is exactly the login-window crash: the faulting instruction
             * reconstructs to libcef+0x41258FB, the loop head of Chromium's
             * frame CLEAR (`movl %edx,(%r10)`), i.e. a STORE into the render
             * bitmap. Across 5 runs, every run that logged [bus-reheal] also
             * crashed and every run without it did not -- protection stripping
             * and the crash travel together.
             *
             * So: readable page + WRITE fault + wine expects PROT_WRITE + host
             * protection lacks it  =>  restore and resume, same as the read side.
             * Always logs the wine-vs-host comparison for the first few, so if
             * this case never actually occurs we find out instead of assuming.
             */
            if (ios_tlswatch_fault( siginfo->si_addr, pc, "bus" ))
            {
                ios_fixup_x18_for_return( bus_ctx );
                return;
            }
            if (rd_kr == KERN_SUCCESS)
            {
                DWORD64 esr = get_fault_esr( bus_ctx );
                int is_write = (int)((esr >> 6) & 1);          /* ISS.WnR */
                extern int ios_page_expected_prot( const void *addr );
                int want = ios_page_expected_prot( siginfo->si_addr );
                mach_vm_address_t ra = (mach_vm_address_t)(uintptr_t)siginfo->si_addr;
                mach_vm_size_t rs = 0;
                vm_region_basic_info_data_64_t rbi;
                mach_msg_type_number_t rc = VM_REGION_BASIC_INFO_COUNT_64;
                mach_port_t ro = MACH_PORT_NULL;
                int host_prot = -1;

                if (mach_vm_region( mach_task_self(), &ra, &rs, VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&rbi, &rc, &ro ) == KERN_SUCCESS)
                    host_prot = rbi.protection;

                {
                    static unsigned long wr_seen, wr_healed;
                    int stripped = (is_write && (want & PROT_WRITE) &&
                                    host_prot >= 0 && !(host_prot & VM_PROT_WRITE));
                    ++wr_seen;
                    if (wr_seen <= 12 || (wr_seen % 4096) == 0)
                        ERR("[wr-strip] #%lu addr=%p pc=%p esr=0x%llx write=%d "
                            "wine_want=%d host_prot=%d %s (seen=%lu healed=%lu) rev=ml552\n",
                            wr_seen, siginfo->si_addr, pc, (unsigned long long)esr,
                            is_write, want, host_prot,
                            stripped ? "<== HOST STRIPPED WRITE" : "(not a strip)",
                            wr_seen, wr_healed);

                    if (stripped)
                    {
                        enum { WR_HPAGE = 0x4000 };
                        char *hp = (char *)((uintptr_t)siginfo->si_addr & ~(uintptr_t)(WR_HPAGE - 1));
                        if (!mprotect( hp, WR_HPAGE, want ))
                        {
                            ++wr_healed;
                            ERR("[wr-strip] restored prot=%d on %p — resuming "
                                "(healed=%lu) rev=ml552\n", want, hp, wr_healed);
                            ios_fixup_x18_for_return( bus_ctx );
                            return;
                        }
                        ERR("[wr-strip] mprotect(%p, %d) FAILED errno=%d — falling to AV rev=ml552\n",
                            (void *)hp, want, errno);
                    }
                    else if (is_write)
                    {
                        /* ml998: not a strip -- Wine itself reports the page
                         * non-writable. Say WHY, with the raw vprot byte, before
                         * anyone is tempted to demote W^X on a guess. */
                        extern void ios_page_vprot_explain( const void *addr, const char *why );
                        ios_page_vprot_explain( siginfo->si_addr, "wr-strip-declined" );
                    }
                }
            }

            if (rd_kr != KERN_SUCCESS)
            {
                /* ml419's exact scenario: wine's bookkeeping says the page is
                 * committed+readable, but the HOST protection lost READ (a raw
                 * mprotect/mach call behind wine's back — no guest protect
                 * call touched the range all run). Put wine's intended prot
                 * back and resume; the [bus-rgn] dump above names the culprit
                 * region state for the real fix. Capped: a storm means the
                 * stripper is active and re-stripping — then die honestly. */
                extern int ios_page_expected_prot( const void *addr );
                int want = ios_page_expected_prot( siginfo->si_addr );
                if (want > 0 && (want & PROT_READ))
                {
                    static int rehealed;
                    if (rehealed < 8 && ++rehealed <= 8)
                    {
                        /* 16KB host pages; `host_page_size` in this file is the
                         * Mach FUNCTION, not a size (see the ml-era note above) */
                        enum { BUS_HPAGE = 0x4000 };
                        char *hpage = (char *)((uintptr_t)siginfo->si_addr & ~(uintptr_t)(BUS_HPAGE - 1));
                        if (!mprotect( hpage, BUS_HPAGE, want ))
                        {
                            /* ml560: the old text asserted "host had stripped it".
                             * ml559 disproved that for the fatal case: the same fault
                             * reported entryprot=3 nowprot=3 — protection was never
                             * stripped, the page simply could not be materialised
                             * (kr=10). Say what is actually known: the read probe
                             * failed and we re-applied wine's intended protection. */
                            ERR("[bus-reheal] #%d re-applied prot=%d on %p (read probe FAILED; "
                                "wine says committed+readable — NOT verified as a protection "
                                "strip, see [bus-rgn] OWNER/VERDICT) — resuming rev=ml560\n",
                                rehealed, want, hpage);
                            ios_fixup_x18_for_return( bus_ctx );
                            return;
                        }
                        ERR("[bus-reheal] #%d mprotect(%p, want=%d) FAILED errno=%d — falling to AV\n",
                            rehealed, (void *)hpage, want, errno);
                    }
                }
                /* unreadable target = an access violation, NOT misalignment.
                 * Deliver the honest AV; FEX's ResetToConsistentState takes the
                 * reconstruction path for c0000005 and rewrites the record to
                 * the true guest RIP (proven in ml419's fault #27 flow). */
                rec = vrec;
                ERR("BUS->AV: unreadable target addr=%p pc=%p rw=%d rev=ml420\n",
                    siginfo->si_addr, pc, (int)vrec.ExceptionInformation[0]);
                /* ml1043: this path printed neither registers nor a caller. A fault
                 * at FEX's rpfree+0x38 -- page->heap holding garbage -- could not be
                 * attributed: the pointer being freed (x0) and who freed it (lr and
                 * the frame chain) are exactly what decide between "metadata
                 * corruption" and "freed something rpmalloc never allocated". Frame
                 * records are read through mach_vm_read_overwrite, so a broken chain
                 * ends the walk instead of faulting inside the fault handler. */
                {
                    static int said;
                    if (said++ < 6)
                    {
                        ucontext_t *uc = sigcontext;
                        uint64_t fp = uc->uc_mcontext->__ss.__fp, i;
                        dprintf( 2, "[bus-regs] ml1043 x0=%llx x1=%llx x2=%llx x3=%llx x8=%llx x9=%llx x18=%llx lr=%llx sp=%llx\n",
                                 (unsigned long long)uc->uc_mcontext->__ss.__x[0], (unsigned long long)uc->uc_mcontext->__ss.__x[1],
                                 (unsigned long long)uc->uc_mcontext->__ss.__x[2], (unsigned long long)uc->uc_mcontext->__ss.__x[3],
                                 (unsigned long long)uc->uc_mcontext->__ss.__x[8], (unsigned long long)uc->uc_mcontext->__ss.__x[9],
                                 (unsigned long long)uc->uc_mcontext->__ss.__x[18], (unsigned long long)uc->uc_mcontext->__ss.__lr,
                                 (unsigned long long)uc->uc_mcontext->__ss.__sp );
                        for (i = 0; i < 12 && fp; i++)
                        {
                            uint64_t rec2[2] = {0, 0};
                            mach_vm_size_t got = 0;
                            if (mach_vm_read_overwrite( mach_task_self(), fp, sizeof rec2,
                                                        (mach_vm_address_t)(uintptr_t)rec2, &got ) != KERN_SUCCESS ||
                                got != sizeof rec2) break;
                            dprintf( 2, "[bus-regs] ml1043   frame[%llu] fp=%llx ret=%llx\n",
                                     (unsigned long long)i, (unsigned long long)fp, (unsigned long long)rec2[1] );
                            if (rec2[0] <= fp) break;
                            fp = rec2[0];
                        }
                    }
                }
                goto bus_fatal;
            }
            /* Darwin also reports data-abort permission faults as SIGBUS with
             * si_code == BUS_ADRALN. Readability does not authorize a store.
             * Keep the original context and dispatch an AV, allowing FEX's
             * SMC recovery or a guest exception handler to service it. Never
             * recursively fault inside the plain-access memcpy below.
             * Verified rdr67 ESR: 0x9200004f, write permission fault, not
             * the data-alignment fault status 0x21. */
            {
                unsigned esr = (unsigned)get_fault_esr( bus_ctx );
                unsigned ec = esr >> 26;
                if ((ec == 0x24 || ec == 0x25) && (esr & 0x3f) != 0x21)
                {
                    static unsigned protection_av_logs;
                    if (protection_av_logs++ < 16)
                        dprintf( 2, "[bus-data-av] pc=%p addr=%p esr=%08x rw=%lu\n",
                                 pc, siginfo->si_addr, esr,
                                 (unsigned long)vrec.ExceptionInformation[0] );
                    /* ml1048: NAME THE PAGE when the target is NOT the main image.
                     *
                     * The 16-line budget above is spent within seconds on the
                     * self-modifying writes into [0x140000000,0x148000000), which FEX
                     * services. The fault that kills the title is a different animal:
                     * a plain 8-byte store into ordinary anonymous DATA (0x17e3e908c,
                     * an arena that takes tens of thousands of successful stores per
                     * run) that arrives here as a write-PERMISSION fault, is declined
                     * by virtual_handle_fault, is not an SMC interval, and therefore
                     * reaches the guest as an AV it cannot survive. Deterministic: same
                     * guest RIP two runs running. What decides the fix is who made that
                     * page unwritable -- so record the ESR, the kernel's protection and
                     * max protection, the tag and the sharing mode. prot lacking W with
                     * max carrying it = someone mprotect()ed it; max lacking W = it was
                     * mapped that way; share_mode names COW/aliasing. */
                    {
                        uintptr_t fa = (uintptr_t)siginfo->si_addr;
                        static unsigned named;
                        if (!(fa >= 0x140000000ull && fa < 0x148000000ull) && named < 12)
                        {
                            mach_vm_address_t ra = (mach_vm_address_t)fa;
                            mach_vm_size_t rs = 0;
                            natural_t depth = 0;
                            vm_region_submap_info_data_64_t ri;
                            mach_msg_type_number_t rc = VM_REGION_SUBMAP_INFO_COUNT_64;
                            kern_return_t kr;
                            named++;
                            for (;;)
                            {
                                kr = mach_vm_region_recurse( mach_task_self(), &ra, &rs, &depth,
                                                             (vm_region_recurse_info_t)&ri, &rc );
                                if (kr != KERN_SUCCESS || !ri.is_submap) break;
                                depth++;
                            }
                            if (kr == KERN_SUCCESS)
                                dprintf( 2, "[bus-data-av] ml1048 NON-IMAGE target addr=%p pc=%p esr=%08x (fsc=%02x wnr=%u) | "
                                            "region=0x%llx+0x%llx prot=%d max=%d share_mode=%d user_tag=%u "
                                            "resident=%u dirtied=%u ref=%u shadow_depth=%u ext_pager=%u\n",
                                         siginfo->si_addr, pc, esr, esr & 0x3f, (esr >> 6) & 1,
                                         (unsigned long long)ra, (unsigned long long)rs, ri.protection,
                                         ri.max_protection, ri.share_mode, ri.user_tag,
                                         ri.pages_resident, ri.pages_dirtied, ri.ref_count,
                                         ri.shadow_depth, ri.external_pager );
                            else
                                dprintf( 2, "[bus-data-av] ml1048 NON-IMAGE target addr=%p pc=%p esr=%08x -- "
                                            "region lookup failed kr=%d\n", siginfo->si_addr, pc, esr, kr );
                            /* ...and Wine's own record of the same page, so the two views
                             * can be compared line against line. */
                            {
                                extern void ios_page_vprot_explain( const void *addr, const char *why );
                                extern int ios_page_expected_prot( const void *addr );
                                dprintf( 2, "[bus-data-av] ml1048 wine expects unix_prot=%d for %p\n",
                                         ios_page_expected_prot( siginfo->si_addr ), siginfo->si_addr );
                                ios_page_vprot_explain( siginfo->si_addr, "ml1048-non-image" );
                            }
                        }
                    }
                    /* ml1002: which guest module is decrypting? EMP.dll runs out
                     * of the emulated sub-floor window; the main image does not. */
                    ios_dump_guest_callers( "smc-write",
                                            (unsigned long long)bus_ctx->uc_mcontext->__ss.__x[28] );
                    /* ml1001: VERIFY THE SELF-MODIFYING WRITE ACTUALLY LANDS.
                     *
                     * This is the acceptance item Astra recorded as still owed:
                     * "actual backing writable, correct four bytes stored" was
                     * only ever satisfied indirectly, by the game reaching a
                     * second SMC address. All five rdr70 writes are MISALIGNED
                     * (0x1467df915 is odd-byte), which is precisely where our
                     * emulation can diverge from Windows/Wine -- and a dropped
                     * decryption store leaves stale ciphertext behind with no
                     * error anywhere.
                     *
                     * No instruction decoding and no register reads: snapshot
                     * the 16 bytes around the destination now, and on the NEXT
                     * entry re-read them and report whether they changed. A
                     * store that was supposed to land and left the bytes
                     * identical was dropped. That cannot be wrong about which
                     * register sourced the value. */
                    {
                        static mach_vm_address_t pend_addr;
                        static unsigned char pend_pre[16];
                        static uint32_t pend_insn;
                        static unsigned verify_n;
                        mach_vm_address_t base = (mach_vm_address_t)(uintptr_t)siginfo->si_addr & ~(mach_vm_address_t)7;
                        unsigned char now[16];
                        mach_vm_size_t vgot = 0;

                        if (pend_addr && verify_n < 16 &&
                            mach_vm_read_overwrite( mach_task_self(), pend_addr, sizeof(now),
                                                    (mach_vm_address_t)now, &vgot ) == KERN_SUCCESS &&
                            vgot == sizeof(now))
                        {
                            int same = !memcmp( now, pend_pre, sizeof(now) );
                            verify_n++;
                            dprintf( 2, "ml1001: previous SMC store at %#llx (insn=%08x) %s\n",
                                     (unsigned long long)pend_addr, pend_insn,
                                     same ? "LEFT THE BYTES UNCHANGED -- the store was DROPPED"
                                          : "changed the bytes (store landed)" );
                            if (!same)
                            {
                                unsigned i;
                                char b1[64], b2[64];
                                for (i = 0; i < 16; i++)
                                {
                                    sprintf( b1 + i * 3, "%02x ", pend_pre[i] );
                                    sprintf( b2 + i * 3, "%02x ", now[i] );
                                }
                                dprintf( 2, "ml1001:   before %s\nml1001:   after  %s\n", b1, b2 );
                            }
                        }
                        pend_insn = 0;
                        ios_fault_read_insn( (uint64_t)(uintptr_t)pc, &pend_insn );
                        if (mach_vm_read_overwrite( mach_task_self(), base, sizeof(pend_pre),
                                                    (mach_vm_address_t)pend_pre, &vgot ) == KERN_SUCCESS &&
                            vgot == sizeof(pend_pre))
                            pend_addr = base;
                        else
                            pend_addr = 0;
                    }
                    rec = vrec;
                    goto bus_fatal;
                }
            }
            /* iOS-Madeira ml479 (#83): readable target + BUS_ADRALN — emulate
             * PLAIN loads/stores in place before concluding "alignment fault →
             * 80000002". The 80000002 path only helps ATOMICS (FEX's unaligned
             * backpatcher); the 2026-08-04 Steam client does misaligned plain
             * 8-byte MOVs into a PA-band SM_COW region that alignment-faults
             * at the hardware level (prot=3, readable=1, si_code=1), and the
             * plain STR fell through FEX's handler into a fatal mislabeled
             * misalignment (webhelper death loop, ml478). x86 MOVs must simply
             * succeed. Atomic/exclusive/SIMD forms fail the decode below and
             * keep the existing 80000002 path unchanged. */
            if (siginfo->si_code == BUS_ADRALN)
            {
                uint32_t a_insn = *(uint32_t *)(uintptr_t)PC_sig(bus_ctx);
                /* ml498 census. The old counters CAPPED at 32/16 with no
                 * running total, so "32 emulated, 0 UNSUPPORTED" said nothing
                 * about how many faults actually happened or how many were
                 * refused — and this decode REFUSES SIMD (insn>>26&1). That
                 * matters now: the login window paints its glyphs correctly
                 * but leaves large background fills pure black, and a big
                 * solid fill is exactly where Skia uses wide vector stores
                 * while glyph blits stay byte-wise. If SIMD stores are being
                 * dropped, that asymmetry is explained. Counts are unbounded;
                 * only the log lines are rate-limited, and every line carries
                 * the totals so silence can never be mistaken for zero. */
                static unsigned long ua_emu_n, ua_simd_n, ua_other_n;
                if (ios_emulate_unaligned_guest_access(bus_ctx, a_insn, (uintptr_t)siginfo->si_addr))
                {
                    if (++ua_emu_n <= 16 || (ua_emu_n % 4096) == 0)
                        ERR("[unaligned-guest] emulated insn=0x%08x addr=%p pc=%p "
                            "(emu=%lu simd=%lu other=%lu) rev=ml498\n",
                            a_insn, siginfo->si_addr, pc, ua_emu_n, ua_simd_n, ua_other_n);
                    PC_sig(bus_ctx) += 4;
                    ios_fixup_x18_for_return( bus_ctx );
                    return;
                }
                {
                    /* Split the refusals: a SIMD load/store is the suspect,
                     * anything else is a different animal and must not hide
                     * inside one undifferentiated "UNSUPPORTED" bucket. */
                    int is_simd = (a_insn >> 26) & 1;
                    unsigned long n = is_simd ? ++ua_simd_n : ++ua_other_n;
                    if (n <= 16 || (n % 4096) == 0)
                        ERR("[unaligned-guest] REFUSED-%s insn=0x%08x addr=%p pc=%p "
                            "(emu=%lu simd=%lu other=%lu) -- keeping 80000002 rev=ml498\n",
                            is_simd ? "SIMD" : "OTHER", a_insn, siginfo->si_addr, pc,
                            ua_emu_n, ua_simd_n, ua_other_n);
                }
            }
            /* readable target: genuine alignment fault — keep 80000002 so FEX's
             * unaligned-access backpatcher handles it; its NtContinueNative
             * resume is now honored natively (signal_set_full_context ml420) */
        }
    }

bus_fatal:
    /* iOS-Madeira ml612: IS THIS A FEX EMULATOR-STACK OVERFLOW? (items 2-4)
     *
     * ml611 froze the whole app for 11 minutes because this exact fault was
     * classified as STATUS_DATATYPE_MISALIGNMENT. CrBrowserMain ran off the
     * bottom of its 256KB emulator stack inside a recursive fextl::set tree
     * deleter (libarm64ecfex.dll+0x12c10, `stp x19,x20,[sp,#-0x20]!` — a 32-byte
     * frame, so ~8,000 levels), the bogus 80000002 was dispatched, nothing
     * handled it, and the thread exited owning a CodeInvalidationMutex reader.
     *
     * A red-black tree cannot be 8,000 deep, so the left-spine is cyclic or
     * corrupt. Two diagnostics run here, both bounded and both using
     * mach_vm_read_overwrite so a probe can never fault inside the fault:
     *
     *  (2) SAVED-LR SCAN. Every recursive frame stores x30 at frame+0x18. Learn
     *      the recursive LR from the innermost frame and walk up in 0x20 steps
     *      while it repeats; the FIRST DIFFERENT LR is the original call site,
     *      which names the corrupted container without guessing. (Frontend's
     *      per-thread sets are only a hypothesis — this is what settles it.)
     *
     *  (3) FLOYD CYCLE CHECK over node->left (offset 0), tortoise/hare rather
     *      than a visited set: allocation-free by construction, which matters
     *      when the thing under investigation is allocator corruption.
     *
     * ⛔ Do NOT "fix" this by enlarging the emulator stack — that only postpones
     * a traversal that does not terminate. */
    /* iOS-Madeira ml620 [tree-caller]: RUN THE RECURSIVE-CALLER SCAN ON THE *BUS* PATH.
     *
     * ml619 put this scan in segv_handler and it never fired. The failure arrives
     * as SIGBUS, not SIGSEGV: ml619's thread death was
     *   BUS pc=0x129caafa0 addr=0x71da87fff0 insn=0xa9be53f3
     * and 0x129caafa0 reverse-translates to libarm64ecfex+0x12fa0 — the ENTRY of
     * the recursive fextl::set<uint64_t> tree deleter, i.e. its own prologue push
     * running off the bottom of a stack.
     *
     * ml612's [stack-ovf] block below also missed it, because that one is gated on
     * [EmulatorStackLimit, EmulatorStackBase) and this is a GUEST stack. So this
     * scan is deliberately ungated by stack identity — the only gate is the
     * self-identifying frame shape.
     *
     * Every recursive frame is 32 bytes with the saved LR at frame+0x18, and each
     * stores the same LR (the instruction after the recursive `bl`, RVA 0x12fc0 /
     * 0x12c30 for the two instantiations). Walk while it repeats; the FIRST
     * DIFFERENT LR is the original callsite, which names WHICH of the five sets in
     * DecodeInstructionsAtEntry is corrupt. */
    {
        uint64_t bsp = (uint64_t)SP_sig(bus_ctx);
        uint64_t lr0 = 0, lr1 = 0;
        mach_vm_size_t rg = 0;
        int k0 = mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(bsp + 0x18),
                                         sizeof(lr0), (mach_vm_address_t)&lr0, &rg ) == KERN_SUCCESS;
        int k1 = mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(bsp + 0x38),
                                         sizeof(lr1), (mach_vm_address_t)&lr1, &rg ) == KERN_SUCCESS;
        if (k0 && k1 && lr0 && lr0 == lr1)
        {
            static unsigned long tc_n;
            unsigned long n = ++tc_n;
            if (n <= 8)
            {
                uint64_t f = bsp, caller = 0, cframe = 0;
                unsigned depth = 0;
                for (; depth < 65536; depth++, f += 0x20)
                {
                    uint64_t lr = 0;
                    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(f + 0x18),
                                                sizeof(lr), (mach_vm_address_t)&lr, &rg ) != KERN_SUCCESS)
                        break;
                    if (lr != lr0) { caller = lr; cframe = f; break; }
                }
                dprintf( 2, "[tree-caller] ml620 #%lu BUS-path recursive 32B frames: recursive_lr=0x%llx "
                            "depth=%u ORIGINAL CALLER=%s0x%llx frame=0x%llx fault=%p pc=%p sp=0x%llx%s\n",
                         n, (unsigned long long)lr0, depth,
                         caller ? "" : "<not reached> ", (unsigned long long)caller,
                         (unsigned long long)cframe, siginfo->si_addr, pc, (unsigned long long)bsp,
                         (depth >= 65536) ? "  (hit cap — caller NOT found, not absent)" : "" );
            }
        }
    }

    if (!is_exec_fault)
    {
        TEB *so_teb = NtCurrentTeb();
        CHPE_V2_CPU_AREA_INFO *so_area = so_teb ? so_teb->ChpeV2CpuAreaInfo : NULL;
        uint64_t slimit = so_area ? (uint64_t)so_area->EmulatorStackLimit : 0;
        uint64_t sbase  = so_area ? (uint64_t)so_area->EmulatorStackBase : 0;
        uint64_t fault  = (uint64_t)(uintptr_t)siginfo->si_addr;

        /* Just below the limit = ran off the bottom. One page of slack covers a
         * multi-register push that straddles the boundary. */
        if (slimit && fault < slimit && fault + 0x4000 >= slimit)
        {
            static unsigned long so_n;
            unsigned long n = ++so_n;
            uint64_t sp = SP_sig(bus_ctx);
            uint64_t node = REGn_sig(1, bus_ctx);   /* x1 = node argument at entry */
            /* Re-read the faulting instruction here: a_insn is scoped to the
             * alignment-emulation block above and is not live at bus_fatal. */
            unsigned int so_insn = 0;
            {
                mach_vm_size_t g = 0;
                mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(uintptr_t)pc,
                                        sizeof(so_insn), (mach_vm_address_t)&so_insn, &g );
            }

            dprintf( 2, "[stack-ovf] ml612 #%lu EMULATOR STACK EXHAUSTED tid=%04x pc=%p addr=0x%llx "
                        "sp=0x%llx stack=[0x%llx..0x%llx] used=%lluKB insn=0x%08x -- reclassifying "
                        "80000002 -> c00000fd (STATUS_STACK_OVERFLOW)\n",
                     n, so_teb ? (unsigned int)(ULONG_PTR)so_teb->ClientId.UniqueThread : 0,
                     pc, (unsigned long long)fault, (unsigned long long)sp,
                     (unsigned long long)slimit, (unsigned long long)sbase,
                     (unsigned long long)((sbase > sp ? sbase - sp : 0) >> 10), so_insn );

            if (n <= 4)
            {
                /* (2) saved-LR scan */
                uint64_t f = sp, recur_lr = 0;
                unsigned depth = 0;
                for (; depth < 4096 && f + 0x20 <= sbase; depth++, f += 0x20)
                {
                    uint64_t lr = 0;
                    mach_vm_size_t got = 0;
                    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(f + 0x18),
                                                sizeof(lr), (mach_vm_address_t)&lr, &got ) != KERN_SUCCESS
                        || got != sizeof(lr))
                        break;
                    if (!depth) { recur_lr = lr; continue; }
                    if (lr != recur_lr)
                    {
                        dprintf( 2, "[stack-ovf] ml612   ORIGINAL CALLER after %u recursive frames: "
                                    "lr=0x%llx (recursive lr=0x%llx, frame=0x%llx) — this names the "
                                    "container being destroyed\n",
                                 depth, (unsigned long long)lr,
                                 (unsigned long long)recur_lr, (unsigned long long)f );
                        break;
                    }
                }
                if (depth >= 4096)
                    dprintf( 2, "[stack-ovf] ml612   scan hit the 4096-frame cap with lr still "
                                "0x%llx — caller not reached (cap, not absence)\n",
                             (unsigned long long)recur_lr );

                /* (3) Floyd cycle detection over node->left */
                {
                    uint64_t slow = node, fast = node;
                    unsigned steps = 0;
                    int cyclic = 0, readfail = 0;
                    while (steps < 100000 && slow && fast)
                    {
                        uint64_t a = 0, b = 0, c = 0;
                        mach_vm_size_t g = 0;
                        if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)slow,
                                                    sizeof(a), (mach_vm_address_t)&a, &g ) != KERN_SUCCESS)
                        { readfail = 1; break; }
                        if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)fast,
                                                    sizeof(b), (mach_vm_address_t)&b, &g ) != KERN_SUCCESS || !b)
                        { break; }
                        if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)b,
                                                    sizeof(c), (mach_vm_address_t)&c, &g ) != KERN_SUCCESS || !c)
                        { break; }
                        slow = a; fast = c; steps++;
                        if (slow && slow == fast) { cyclic = 1; break; }
                    }
                    dprintf( 2, "[stack-ovf] ml612   left-spine: node=0x%llx %s after %u steps%s\n",
                             (unsigned long long)node,
                             cyclic ? "*** CYCLE CONFIRMED ***" : (readfail ? "unreadable link" : "no cycle found"),
                             steps, (steps >= 100000) ? " (hit 100k cap — inconclusive, not clean)" : "" );
                }

                /* Fixed-size preview of the first links, no container involved. */
                {
                    uint64_t links[4] = {0, 0, 0, 0};
                    mach_vm_size_t g = 0;
                    if (node && mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)node,
                                                        sizeof(links), (mach_vm_address_t)links, &g ) == KERN_SUCCESS)
                        dprintf( 2, "[stack-ovf] ml612   node[0..3] left=0x%llx right=0x%llx "
                                    "parent=0x%llx +0x18=0x%llx\n",
                                 (unsigned long long)links[0], (unsigned long long)links[1],
                                 (unsigned long long)links[2], (unsigned long long)links[3] );
                }
            }

            rec.ExceptionCode = 0xC00000FDu; /* STATUS_STACK_OVERFLOW */
            rec.NumberParameters = 2;
            rec.ExceptionInformation[0] = 1; /* write */
            rec.ExceptionInformation[1] = (ULONG_PTR)siginfo->si_addr;
            /* Falls through to setup_exception below; the is_exec_fault branch
             * cannot fire here because this whole block is !is_exec_fault. */
        }
    }

    if (is_exec_fault)
    {
        /* ml345: an instruction-fetch abort on a readable-but-NX page arrives
         * as SIGBUS (KERN_PROTECTION_FAILURE), but it is an EXECUTE access
         * violation, not a data-alignment fault. Raising 80000002 here sent
         * FEX's unaligned-atomic handler decoding DATA bytes at the bogus pc
         * as atomics (ml344 "Unhandled non-JIT atomic" death). */
        rec.ExceptionCode = EXCEPTION_ACCESS_VIOLATION;
        rec.NumberParameters = 2;
        rec.ExceptionInformation[0] = EXCEPTION_EXECUTE_FAULT;
        rec.ExceptionInformation[1] = (ULONG_PTR)siginfo->si_addr;
    }
    { static unsigned long ml1055_bus; unsigned long k = __sync_add_and_fetch( &ml1055_bus, 1 );   /* 20,764 lines a run */
      if (k <= 40 || !(k % 1000)) ERR("BUS at pc=%p addr=%p exec=%d (#%lu, sampled) rev=ml345\n", pc, siginfo->si_addr, is_exec_fault, k); }
#endif
    setup_exception( sigcontext, &rec );
}


/**********************************************************************
 *		trap_handler
 *
 * Handler for SIGTRAP.
 */
static void trap_handler( int signal, siginfo_t *siginfo, void *sigcontext )
{
    EXCEPTION_RECORD rec = { 0 };
    ucontext_t *context = sigcontext;
    CONTEXT ctx;
#ifdef WINE_IOS
    /* StikDebug protocol BRK #0xf00d with no debugger left to catch it —
     * e.g. the detach BRK re-executing after StikDebug lets go, on a
     * TEB-less app thread. Check at ENTRY, before any si_code dispatch:
     * iOS delivers BRK-derived SIGTRAPs with varying si_code, and letting
     * this fall into the wine exception path wedges the thread inside
     * nested fault logging (2026-07-06). Skip the insn, x0=0 (failure). */
    if (!(PC_sig( context ) & 3) && *(ULONG *)PC_sig( context ) == 0xd43e01a0)
    {
        dprintf(2, "[brk-f00d] skipped stray StikDebug BRK at pc=%p (si_code=%d)\n",
                (void *)PC_sig( context ), siginfo->si_code);
        REGn_sig( 0, context ) = 0;
        PC_sig( context ) += 4;
        return;
    }
    /* ml481 (#85): a BRK/trap raised by HOST code on a host thread (ml480: the
     * UI thread trapping inside libsystem_malloc) is never a guest exception —
     * adopting it wedged the app. Check before any logging or save_context. */
    if (ios_fault_is_foreign( (void *)PC_sig( context ), siginfo->si_addr ))
    {
        ios_decline_foreign_fault( signal, (void *)PC_sig( context ), siginfo->si_addr );
        return;
    }
    ios_track_signal( signal, context );
#endif

    rec.ExceptionAddress = (void *)PC_sig(context);
    save_context( &ctx, sigcontext );

    switch (siginfo->si_code)
    {
    case TRAP_TRACE:
        rec.ExceptionCode = EXCEPTION_SINGLE_STEP;
        break;
    case TRAP_BRKPT:
        /* debug exceptions do not update ESR on Linux, so we fetch the instruction directly. */
        if (!(PSTATE_sig( context ) & 0x10) && /* AArch64 (not WoW) */
            !(PC_sig( context ) & 3))
        {
            ULONG imm = (*(ULONG *)PC_sig( context ) >> 5) & 0xffff;
            switch (imm)
            {
            case 0xf00d:
                /* StikDebug JIT-protocol BRK (detach/prepare_region) with no
                 * debugger left to catch it — e.g. the detach BRK re-executes
                 * after StikDebug lets go, on a TEB-less app thread. This is
                 * an app-side handshake, never a guest exception: skip the
                 * insn, report failure in x0, and get out before any wine
                 * exception machinery (which wedged the detach thread inside
                 * dbg logging, 2026-07-06). */
                REGn_sig( 0, context ) = 0;
                PC_sig( context ) += 4;
                return;
            case 0xf000:
                ctx.Pc += 4;  /* skip the brk instruction */
                rec.ExceptionCode = EXCEPTION_BREAKPOINT;
                rec.NumberParameters = 1;
                break;
            case 0xf001:
                rec.ExceptionCode = STATUS_ASSERTION_FAILURE;
                break;
            case 0xf003:
                rec.ExceptionCode = STATUS_STACK_BUFFER_OVERRUN;
                rec.ExceptionFlags = EXCEPTION_NONCONTINUABLE;
                rec.NumberParameters = 1;
                rec.ExceptionInformation[0] = ctx.X[0];
                NtRaiseException( &rec, &ctx, FALSE );
                break;
            case 0xf004:
                rec.ExceptionCode = EXCEPTION_INT_DIVIDE_BY_ZERO;
                break;
            default:
                rec.ExceptionCode = EXCEPTION_ILLEGAL_INSTRUCTION;
                break;
            }
        }
        break;
    default:
        rec.ExceptionCode = EXCEPTION_ILLEGAL_INSTRUCTION;
        break;
    }

    setup_raise_exception( sigcontext, &rec, &ctx );
}

/**********************************************************************
 *		fpe_handler
 *
 * Handler for SIGFPE.
 */
static void fpe_handler( int signal, siginfo_t *siginfo, void *sigcontext )
{
    EXCEPTION_RECORD rec = { 0 };
#ifdef WINE_IOS
    ios_track_signal( signal, sigcontext );
#endif

    switch (siginfo->si_code & 0xffff )
    {
#ifdef FPE_FLTSUB
    case FPE_FLTSUB:
        rec.ExceptionCode = EXCEPTION_ARRAY_BOUNDS_EXCEEDED;
        break;
#endif
#ifdef FPE_INTDIV
    case FPE_INTDIV:
        rec.ExceptionCode = EXCEPTION_INT_DIVIDE_BY_ZERO;
        break;
#endif
#ifdef FPE_INTOVF
    case FPE_INTOVF:
        rec.ExceptionCode = EXCEPTION_INT_OVERFLOW;
        break;
#endif
#ifdef FPE_FLTDIV
    case FPE_FLTDIV:
        rec.ExceptionCode = EXCEPTION_FLT_DIVIDE_BY_ZERO;
        break;
#endif
#ifdef FPE_FLTOVF
    case FPE_FLTOVF:
        rec.ExceptionCode = EXCEPTION_FLT_OVERFLOW;
        break;
#endif
#ifdef FPE_FLTUND
    case FPE_FLTUND:
        rec.ExceptionCode = EXCEPTION_FLT_UNDERFLOW;
        break;
#endif
#ifdef FPE_FLTRES
    case FPE_FLTRES:
        rec.ExceptionCode = EXCEPTION_FLT_INEXACT_RESULT;
        break;
#endif
#ifdef FPE_FLTINV
    case FPE_FLTINV:
#endif
    default:
        rec.ExceptionCode = EXCEPTION_FLT_INVALID_OPERATION;
        break;
    }
    setup_exception( sigcontext, &rec );
}


/**********************************************************************
 *		int_handler
 *
 * Handler for SIGINT.
 */
static void int_handler( int signal, siginfo_t *siginfo, void *sigcontext )
{
    HANDLE handle;
#ifdef WINE_IOS
    ios_track_signal( signal, sigcontext );
#endif

    if (!p__wine_ctrl_routine)
    {
#ifdef WINE_IOS
        ios_fixup_x18_for_return( sigcontext );
#endif
        return;
    }
    if (!NtCreateThreadEx( &handle, THREAD_ALL_ACCESS, NULL, NtCurrentProcess(),
                           p__wine_ctrl_routine, 0 /* CTRL_C_EVENT */, 0, 0, 0, 0, NULL ))
        NtClose( handle );
#ifdef WINE_IOS
    ios_fixup_x18_for_return( sigcontext );
#endif
}


/**********************************************************************
 *		abrt_handler
 *
 * Handler for SIGABRT.
 */
static void abrt_handler( int signal, siginfo_t *siginfo, void *sigcontext )
{
    EXCEPTION_RECORD rec = { EXCEPTION_WINE_ASSERTION, EXCEPTION_NONCONTINUABLE };
#ifdef WINE_IOS
    /* ml784 (#85 again): SIGABRT is raised by HOST code too, and this handler
     * adopted it unconditionally.
     *
     * A SwiftUI AttributeGraph precondition failure called abort() on the UI
     * thread; abrt_handler treated it as a guest exception, and
     * ios_log_guest_exception then faulted on a thread with no TEB -- so the
     * crash report blamed our handler and the framework's own reason was never
     * printed. Same rule the other handlers already follow: only adopt faults
     * that belong to the emulated world.
     *
     * si_addr is meaningless for SIGABRT, so foreign-ness is judged on the PC
     * alone; a guest abort still comes from the pool or a guest band. */
    if (ios_fault_is_foreign( (void *)PC_sig( (ucontext_t *)sigcontext ), NULL ))
    {
        ios_decline_foreign_fault( signal, (void *)PC_sig( (ucontext_t *)sigcontext ), NULL );
        return;
    }
    ios_track_signal( signal, sigcontext );
#endif
    setup_exception( sigcontext, &rec );
}


#ifdef WINE_IOS
/* iOS-Madeira ml483 (#87): the thread-control handlers (SIGQUIT/USR1/USR2) all
 * reach ntdll_get_thread_data() — get_syscall_frame() reads TEB+0x378 and
 * is_inside_syscall() reads TEB+kernel_stack — on their FIRST statement, before
 * any check. Threads created directly by CEF/FEX have no TEB (NtCurrentTeb()
 * unix-side is the pthread key `ios_teb_tls_key`), so a signal landing on one
 * dereferences NULL. ml482's run died exactly there: SEGV #1 pc=usr2_handler+0x20
 * addr=0x378, insn `ldr x21,[x0,#0x378]` with x0=0 straight after the
 * NtCurrentTeb() call. These signals mean "suspend / set your context / quit" —
 * all no-ops for a thread wine does not manage — so bail out instead.
 * Async-signal-safe: pthread_getspecific only, no allocation. */
static int ios_thread_ctl_has_teb( void )
{
    return NtCurrentTeb() != NULL;
}
#endif

/**********************************************************************
 *		quit_handler
 *
 * Handler for SIGQUIT.
 */
static void quit_handler( int signal, siginfo_t *siginfo, void *sigcontext )
{
    ucontext_t *context = sigcontext;
#ifdef WINE_IOS
    ios_track_signal( signal, context );
    if (!ios_thread_ctl_has_teb())
    {
        static int noteb_quit;
        if (noteb_quit < 4) { noteb_quit++;
            dprintf( 2, "[sig-noteb] SIGQUIT on a TEB-less thread — ignoring rev=ml483\n" ); }
        return;
    }
#endif
    if (!is_inside_syscall( SP_sig(context) )) user_mode_abort_thread( 0, get_syscall_frame() );
    abort_thread(0);
}


/**********************************************************************
 *		usr1_handler
 *
 * Handler for SIGUSR1, used to signal a thread that it got suspended.
 */
static void usr1_handler( int signal, siginfo_t *siginfo, void *sigcontext )
{
    ucontext_t *ucontext = sigcontext;
    CONTEXT context;
#ifdef WINE_IOS
    ios_track_signal( signal, ucontext );
    if (!ios_thread_ctl_has_teb())      /* ml483 (#87) — see ios_thread_ctl_has_teb */
    {
        static int noteb_usr1;
        if (noteb_usr1 < 4) { noteb_usr1++;
            dprintf( 2, "[sig-noteb] SIGUSR1 (suspend) on a TEB-less thread — ignoring rev=ml483\n" ); }
        return;
    }
#endif
    if (is_inside_syscall( SP_sig(ucontext) ))
    {
        context.ContextFlags = CONTEXT_FULL | CONTEXT_EXCEPTION_REQUEST;
        NtGetContextThread( GetCurrentThread(), &context );
        wait_suspend( &context );
        NtSetContextThread( GetCurrentThread(), &context );
    }
    else
    {
        save_context( &context, ucontext );
        context.ContextFlags |= CONTEXT_EXCEPTION_REPORTING;
        wait_suspend( &context );
        restore_context( &context, ucontext );
#ifdef WINE_IOS
        ios_fixup_x18_for_return( ucontext );
#endif
    }
}


/**********************************************************************
 *		usr2_handler
 *
 * Handler for SIGUSR2, used to set a thread context.
 */
static void usr2_handler( int signal, siginfo_t *siginfo, void *sigcontext )
{
#ifdef WINE_IOS
    struct syscall_frame *frame;     /* ml483 (#87): fetched only after the TEB
                                      * check below — reading TEB+0x378 here is
                                      * what killed the ml482 run. */
#else
    struct syscall_frame *frame = get_syscall_frame();
#endif
    ucontext_t *context = sigcontext;
    DWORD i;
#ifdef WINE_IOS
    ios_track_signal( signal, context );
    if (!ios_thread_ctl_has_teb())
    {
        static int noteb_usr2;
        if (noteb_usr2 < 4) { noteb_usr2++;
            dprintf( 2, "[sig-noteb] SIGUSR2 (set-context) on a TEB-less thread — ignoring rev=ml483\n" ); }
        return;
    }
    frame = get_syscall_frame();
#endif

    if (!is_inside_syscall( SP_sig(context) ))
    {
#ifdef WINE_IOS
        ios_fixup_x18_for_return( context );
#endif
        return;
    }

    FP_sig(context)     = frame->fp;
    LR_sig(context)     = frame->lr;
    SP_sig(context)     = frame->sp;
    PC_sig(context)     = frame->pc;
    PSTATE_sig(context) = frame->cpsr;
    for (i = 0; i <= 28; i++) REGn_sig( i, context ) = frame->x[i];

#ifdef linux
    {
        struct fpsimd_context *fp = get_fpsimd_context( sigcontext );
        if (fp)
        {
            fp->fpcr = frame->fpcr;
            fp->fpsr = frame->fpsr;
            memcpy( fp->vregs, frame->v, sizeof(fp->vregs) );
        }
    }
#elif defined(__APPLE__)
    context->uc_mcontext->__ns.__fpcr = frame->fpcr;
    context->uc_mcontext->__ns.__fpsr = frame->fpsr;
    memcpy( context->uc_mcontext->__ns.__v, frame->v, sizeof(frame->v) );
#endif
}


/**********************************************************************
 *           get_thread_ldt_entry
 */
NTSTATUS get_thread_ldt_entry( HANDLE handle, THREAD_DESCRIPTOR_INFORMATION *info, ULONG len )
{
    return STATUS_NOT_IMPLEMENTED;
}


/**********************************************************************
 *             signal_init_threading
 */
void signal_init_threading(void)
{
}


/**********************************************************************
 *             signal_alloc_thread
 */
NTSTATUS signal_alloc_thread( TEB *teb )
{
    return STATUS_SUCCESS;
}


/**********************************************************************
 *             signal_free_thread
 */
void signal_free_thread( TEB *teb )
{
}


/**********************************************************************
 *		signal_init_process
 */
void signal_init_process(void)
{
    struct sigaction sig_act;
    struct ntdll_thread_data *thread_data = ntdll_get_thread_data();
    void *kernel_stack = (char *)thread_data->kernel_stack + kernel_stack_size;

    thread_data->syscall_frame = (struct syscall_frame *)kernel_stack - 1;

    signal_alloc_thread( NtCurrentTeb() );

#ifdef WINE_IOS
    /* Create TLS key for TEB storage (used by x18 binary patcher trampolines) */
    if (!ios_teb_tls_key_created)
    {
        pthread_key_create(&ios_teb_tls_key, NULL);
        ios_teb_tls_key_created = 1;
    }
#endif

    sig_act.sa_mask = server_block_set;
    sig_act.sa_flags = SA_SIGINFO | SA_RESTART | SA_ONSTACK;

    sig_act.sa_sigaction = int_handler;
    if (sigaction( SIGINT, &sig_act, NULL ) == -1) goto error;
    sig_act.sa_sigaction = fpe_handler;
    if (sigaction( SIGFPE, &sig_act, NULL ) == -1) goto error;
    sig_act.sa_sigaction = abrt_handler;
    if (sigaction( SIGABRT, &sig_act, NULL ) == -1) goto error;
    sig_act.sa_sigaction = quit_handler;
    if (sigaction( SIGQUIT, &sig_act, NULL ) == -1) goto error;
    sig_act.sa_sigaction = usr1_handler;
    if (sigaction( SIGUSR1, &sig_act, NULL ) == -1) goto error;
    sig_act.sa_sigaction = usr2_handler;
    if (sigaction( SIGUSR2, &sig_act, NULL ) == -1) goto error;
    sig_act.sa_sigaction = trap_handler;
    if (sigaction( SIGTRAP, &sig_act, NULL ) == -1) goto error;
    sig_act.sa_sigaction = segv_handler;
    if (sigaction( SIGSEGV, &sig_act, NULL ) == -1) goto error;
    sig_act.sa_sigaction = ill_handler;
    if (sigaction( SIGILL, &sig_act, NULL ) == -1) goto error;
    sig_act.sa_sigaction = bus_handler;
    if (sigaction( SIGBUS, &sig_act, NULL ) == -1) goto error;
    return;

 error:
    perror("sigaction");
    exit(1);
}


/***********************************************************************
 *           syscall_dispatcher_return_slowpath
 */
void syscall_dispatcher_return_slowpath(void)
{
    raise( SIGUSR2 );
}

/***********************************************************************
 *           init_syscall_frame
 */
/* host -> guest for a known window base, NULL-preserving */
static inline ULONG ios_wow_guest_in( const void *host, ULONG_PTR wow_base )
{
    return host ? (ULONG)((ULONG_PTR)host - wow_base) : 0;
}

void init_syscall_frame( LPTHREAD_START_ROUTINE entry, void *arg, BOOL suspend, TEB *teb )
{
    struct syscall_frame *frame = ((struct ntdll_thread_data *)&teb->GdiTebBatch)->syscall_frame;
    CONTEXT *ctx, context = { CONTEXT_ALL };
    I386_CONTEXT *i386_context;
    ARM_CONTEXT *arm_context;

    context.X0  = (DWORD64)entry;
    context.X1  = (DWORD64)arg;
    context.X18 = (DWORD64)teb;
    context.Sp  = (DWORD64)teb->Tib.StackBase;
    context.Pc  = (DWORD64)IOS_PFUNC(RtlUserThreadStart);

    /* Every register of the initial 32-bit context is a GUEST value.  `entry`
     * and `arg` arrive as host pointers, wow_peb is the host PEB32, and
     * pLdrSystemDllInitBlock->pRtlUserThreadStart is already published guest.
     * Without a guest window wow_base is 0 and this is the upstream code. */
    ULONG_PTR wow_base = ios_wow_base_for_peb( teb->Peb );
#define IOS_WOW_GUEST_IN(ptr) ios_wow_guest_in( (ptr), wow_base )

    if ((i386_context = get_cpu_area( IMAGE_FILE_MACHINE_I386 )))
    {
        XMM_SAVE_AREA32 *fpu = (XMM_SAVE_AREA32 *)i386_context->ExtendedRegisters;
        i386_context->ContextFlags = CONTEXT_I386_ALL;
        i386_context->Eax = IOS_WOW_GUEST_IN( entry );
        i386_context->Ebx = IOS_WOW_GUEST_IN( arg == peb ? (void *)wow_peb : arg );
        i386_context->Esp = get_wow_teb( teb )->Tib.StackBase - 16;
        i386_context->Eip = pLdrSystemDllInitBlock->pRtlUserThreadStart;
        i386_context->SegCs = 0x23;
        i386_context->SegDs = 0x2b;
        i386_context->SegEs = 0x2b;
        i386_context->SegFs = 0x53;
        i386_context->SegGs = 0x2b;
        i386_context->SegSs = 0x2b;
        i386_context->EFlags = 0x202;
        fpu->ControlWord = 0x27f;
        fpu->MxCsr = 0x1f80;
        fpux_to_fpu( &i386_context->FloatSave, fpu );
    }
    else if ((arm_context = get_cpu_area( IMAGE_FILE_MACHINE_ARMNT )))
    {
        arm_context->ContextFlags = CONTEXT_ARM_ALL;
        arm_context->R0 = IOS_WOW_GUEST_IN( entry );
        arm_context->R1 = IOS_WOW_GUEST_IN( arg == peb ? (void *)wow_peb : arg );
        arm_context->Sp = get_wow_teb( teb )->Tib.StackBase;
        arm_context->Pc = pLdrSystemDllInitBlock->pRtlUserThreadStart;
        if (arm_context->Pc & 1) arm_context->Cpsr |= 0x20; /* thumb mode */
    }
#undef IOS_WOW_GUEST_IN

    if (suspend)
    {
        context.ContextFlags |= CONTEXT_EXCEPTION_REPORTING | CONTEXT_EXCEPTION_ACTIVE;
        wait_suspend( &context );
    }

    ctx = (CONTEXT *)((ULONG_PTR)context.Sp & ~15) - 1;
    *ctx = context;
    ctx->ContextFlags = CONTEXT_FULL;
    signal_set_full_context( ctx );

    frame->sp    = (ULONG64)ctx;
    frame->pc    = (ULONG64)IOS_PFUNC(LdrInitializeThunk);
    frame->x[0]  = (ULONG64)ctx;
    frame->x[18] = (ULONG64)teb;

#ifdef WINE_IOS
    /* Translate PE code addresses to JIT pool addresses.
     * On iOS/TXM, PE code pages can't be made executable. The code was
     * copied to the JIT pool by mprotect_exec. Redirect PC to execute
     * from the JIT pool's original RX address.
     *
     * IMPORTANT: fixup_for_fastpath must be called AFTER this redirect,
     * so frame->x[16] == frame->pc (JIT pool address). Otherwise the
     * fastpath check fails and the slowpath (SIGUSR2) is taken, which
     * relies on iOS kernel restoring X18 from ucontext — but iOS
     * overrides X18 (platform register) on signal return. */
    {
        extern void *ios_jit_translate_addr(void *addr);
        void *orig_pc = (void *)(uintptr_t)frame->pc;
        void *jit_pc = ios_jit_translate_addr(orig_pc);
        if (jit_pc != orig_pc)
        {
            frame->pc = (ULONG64)(uintptr_t)jit_pc;
            ERR("init_syscall_frame: redirected PC %p → %p (JIT pool)\n", orig_pc, jit_pc);
        }
    }
#endif

    syscall_frame_fixup_for_fastpath( frame );

#ifdef WINE_IOS
    /* Save TEB for signal handler recovery */
    ios_teb_for_signals = (uintptr_t)teb;

    /* Store TEB in pthread TLS slot — accessible via TPIDRRO_EL0 which
     * iOS preserves across context switches. TPIDR_EL0 is NOT safe (iOS zeros it).
     * The x18 binary patcher rewrites PE code to read TEB from this TLS slot. */
    {
        extern pthread_key_t ios_teb_tls_key;
        extern int ios_teb_tls_slot_offset;
        pthread_setspecific(ios_teb_tls_key, teb);
        /* Also compute the raw TSD slot offset for the patcher's trampolines */
        if (ios_teb_tls_slot_offset == 0)
        {
            uintptr_t tsd_base;
            __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tsd_base));
            tsd_base &= ~7ULL;
            /* Find our TEB in the TSD array */
            for (int s = 0; s < 512; s++)
            {
                if (*(void **)(tsd_base + s * 8) == teb)
                {
                    ios_teb_tls_slot_offset = s * 8;
                    ERR("init_syscall_frame: TEB at TSD slot %d (offset 0x%x from TPIDRRO_EL0)\n",
                        s, ios_teb_tls_slot_offset);
                    break;
                }
            }
        }
    }

    /* Allocate per-thread trampoline slot in JIT pool */
    {
        extern int ios_jit_alloc_trampoline_slot(void);
        extern void ios_jit_set_teb_slot(int slot, uintptr_t teb);
        extern void *ios_jit_get_trampoline(int slot);

        ios_my_slot = ios_jit_alloc_trampoline_slot();
        ios_jit_set_teb_slot(ios_my_slot, (uintptr_t)teb);
        ios_my_trampoline = ios_jit_get_trampoline(ios_my_slot);
        ERR("init_syscall_frame: allocated trampoline slot %d, tramp=%p, teb=%p\n",
            ios_my_slot, ios_my_trampoline, teb);
    }

    /* iOS x18 workaround: The kernel zeroes x18 on context switches.
     * Pages 0-0x1FFF are readable on this device (return 0) but are NOT
     * a VM mapping (mach_vm_region shows first region at ~0x104000000).
     * The readable pages are hardware/firmware behavior that can't be
     * modified via mach_vm_protect/deallocate.
     *
     * When x18=0, [x18+0x60] silently returns PEB=0 instead of faulting.
     * Derived registers get corrupted before SEGV fires, making the
     * trampoline retry useless.
     *
     * Solution: CREATE a VM mapping at address 0 containing TEB data.
     * This overrides the hardware zero-page behavior. When x18=0,
     * [x18+offset] reads real TEB data from our mapping.
     * If all mapping approaches fail, the Mach exception handler
     * is the last resort for x18 restoration. */
    /* 2026-07-03: attempt the page0 chain ONCE PER PROCESS, not per thread.
     * Page 0 is process-global (and can only hold one thread's TEB anyway),
     * so re-running M1-M8 on every new thread only re-fails. Worse, the M8
     * debugger BRK is FATAL on threads created after the debugger detaches:
     * with no debugger, the BRK trap unwinds through a handler chain that
     * (with x18=0 on a fresh thread) calls a raw non-executable ntdll PE
     * address → undispatchable BUS → NtTerminateProcess. Observed killing
     * Thumper's worker-thread spawn at ~2:30 (thread 0054, splash wall). */
    static int ios_page0_attempted = 0;
    if (ios_page0_attempted) {
        ERR("page0: already attempted by first thread — skipping (Mach handler covers x18=0)\n");
    } else {
        ios_page0_attempted = 1;
        kern_return_t kr;
        int mapped = 0;
        uintptr_t teb_page = (uintptr_t)teb & ~0x3FFFULL;
        uintptr_t teb_off = (uintptr_t)teb - teb_page;

        /* Diagnostic: what's at address 0 */
        mach_vm_address_t region_addr = 0;
        mach_vm_size_t region_size = 0;
        vm_region_basic_info_data_64_t rinfo = {0};
        mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj_name = MACH_PORT_NULL;
        kr = mach_vm_region(mach_task_self(), &region_addr, &region_size,
                            VM_REGION_BASIC_INFO_64, (vm_region_info_t)&rinfo,
                            &info_count, &obj_name);
        ERR("page0: first_region=%p size=0x%llx prot=%d/%d kr=%d teb=%p teb_page=%p off=0x%lx\n",
            (void*)region_addr, (unsigned long long)region_size,
            rinfo.protection, rinfo.max_protection, kr,
            teb, (void*)teb_page, (unsigned long)teb_off);

        /* M1: mach_vm_allocate at 0 with VM_FLAGS_FIXED */
        if (!mapped) {
            mach_vm_address_t target = 0;
            kr = mach_vm_allocate(mach_task_self(), &target, 0x4000, VM_FLAGS_FIXED);
            ERR("page0 M1 allocate(FIXED): kr=%d target=%p\n", kr, (void*)target);
            if (kr == KERN_SUCCESS && target == 0) {
                memcpy((void*)teb_off, (void*)teb_page, 0x4000 - teb_off);
                mach_vm_protect(mach_task_self(), 0, 0x4000, FALSE, VM_PROT_READ);
                mapped = 1;
            }
        }

        /* M2: mach_vm_map anonymous RW at 0, FIXED|OVERWRITE */
        if (!mapped) {
            mach_vm_address_t target = 0;
            kr = mach_vm_map(mach_task_self(), &target, 0x4000, 0,
                             VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                             MACH_PORT_NULL, 0, FALSE,
                             VM_PROT_READ | VM_PROT_WRITE,
                             VM_PROT_READ | VM_PROT_WRITE,
                             VM_INHERIT_NONE);
            ERR("page0 M2 map(RW,FIXED|OVERWRITE): kr=%d target=%p\n", kr, (void*)target);
            if (kr == KERN_SUCCESS && target == 0) {
                memcpy((void*)teb_off, (void*)teb_page, 0x4000 - teb_off);
                mach_vm_protect(mach_task_self(), 0, 0x4000, FALSE, VM_PROT_READ);
                mapped = 2;
            }
        }

        /* M3: mach_vm_map anonymous RW at 0, FIXED only (no OVERWRITE) */
        if (!mapped) {
            mach_vm_address_t target = 0;
            kr = mach_vm_map(mach_task_self(), &target, 0x4000, 0,
                             VM_FLAGS_FIXED,
                             MACH_PORT_NULL, 0, FALSE,
                             VM_PROT_READ | VM_PROT_WRITE,
                             VM_PROT_READ | VM_PROT_WRITE,
                             VM_INHERIT_NONE);
            ERR("page0 M3 map(RW,FIXED): kr=%d target=%p\n", kr, (void*)target);
            if (kr == KERN_SUCCESS && target == 0) {
                memcpy((void*)teb_off, (void*)teb_page, 0x4000 - teb_off);
                mach_vm_protect(mach_task_self(), 0, 0x4000, FALSE, VM_PROT_READ);
                mapped = 3;
            }
        }

        /* M4: mach_vm_remap TEB page at 0 (shared mirror) */
        if (!mapped) {
            mach_vm_address_t target = 0;
            vm_prot_t cur_prot, max_prot;
            kr = mach_vm_remap(mach_task_self(), &target, 0x4000, 0,
                               VM_FLAGS_FIXED, mach_task_self(),
                               (mach_vm_address_t)teb_page, FALSE,
                               &cur_prot, &max_prot, VM_INHERIT_NONE);
            ERR("page0 M4 remap(FIXED): kr=%d target=%p\n", kr, (void*)target);
            if (kr == KERN_SUCCESS && target == 0) mapped = 4;
        }

        /* M5: memory entry + mach_vm_map */
        if (!mapped) {
            memory_object_size_t entry_size = 0x4000;
            mach_port_t mem_entry = MACH_PORT_NULL;
            kr = mach_make_memory_entry_64(mach_task_self(), &entry_size,
                (mach_vm_address_t)teb_page,
                VM_PROT_READ | VM_PROT_WRITE | MAP_MEM_VM_SHARE,
                &mem_entry, MACH_PORT_NULL);
            ERR("page0 M5 mem_entry: kr=%d\n", kr);
            if (kr == KERN_SUCCESS) {
                mach_vm_address_t target = 0;
                kr = mach_vm_map(mach_task_self(), &target, 0x4000, 0,
                    VM_FLAGS_FIXED,
                    mem_entry, 0, FALSE,
                    VM_PROT_READ, VM_PROT_READ | VM_PROT_WRITE,
                    VM_INHERIT_NONE);
                ERR("page0 M5 map: kr=%d target=%p\n", kr, (void*)target);
                if (kr == KERN_SUCCESS && target == 0) mapped = 5;
                mach_port_deallocate(mach_task_self(), mem_entry);
            }
        }

        /* M6: mmap MAP_FIXED at 0 */
        if (!mapped) {
            void *p = mmap(0, 0x4000, PROT_READ | PROT_WRITE,
                           MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0);
            ERR("page0 M6 mmap(RW,FIXED): p=%p errno=%d\n", p, p == MAP_FAILED ? errno : 0);
            if (p == (void*)0) {
                memcpy((void*)teb_off, (void*)teb_page, 0x4000 - teb_off);
                mprotect(0, 0x4000, PROT_READ);
                mapped = 6;
            }
        }

        /* M7: vm_allocate (32-bit API) at 0 */
        if (!mapped) {
            vm_address_t target = 0;
            kr = vm_allocate(mach_task_self(), &target, 0x4000, VM_FLAGS_FIXED);
            ERR("page0 M7 vm_allocate: kr=%d target=%p\n", kr, (void*)(uintptr_t)target);
            if (kr == KERN_SUCCESS && target == 0) {
                memcpy((void*)teb_off, (void*)teb_page, 0x4000 - teb_off);
                vm_protect(mach_task_self(), 0, 0x4000, FALSE, VM_PROT_READ);
                mapped = 7;
            }
        }

        if (mapped) {
            /* Verify: compare PEB pointer from addr 0 vs real TEB */
            uint64_t peb0 = *(volatile uint64_t *)(teb_off + 0x60);
            uint64_t peb_real = *(volatile uint64_t *)((uintptr_t)teb + 0x60);
            ERR("TEB MAPPED at addr 0 (M%d)! peb@0x60=%p real=%p %s\n",
                mapped, (void*)peb0, (void*)peb_real,
                peb0 == peb_real ? "MATCH" : "MISMATCH");

            /* Check region again to confirm real mapping exists */
            region_addr = 0;
            info_count = VM_REGION_BASIC_INFO_COUNT_64;
            kr = mach_vm_region(mach_task_self(), &region_addr, &region_size,
                                VM_REGION_BASIC_INFO_64, (vm_region_info_t)&rinfo,
                                &info_count, &obj_name);
            ERR("page0 post-map: region=%p size=0x%llx prot=%d/%d\n",
                (void*)region_addr, (unsigned long long)region_size,
                rinfo.protection, rinfo.max_protection);
        }

        /* M8: Ask the debugger to write TEB data to page 0 via BRK #0xf00d cmd 3.
         * The debugger may have kernel privileges that the app doesn't.
         * Uses GDB M (memory write) command to write TEB data at address 0. */
        if (!mapped) {
            ERR("page0: trying debugger (BRK #0xf00d, x16=3)...\n");
            register uintptr_t x0_val __asm__("x0") = (uintptr_t)teb;
            register size_t x1_val __asm__("x1") = 0x4000;
            register uintptr_t x0_result __asm__("x0");
            __asm__ volatile(
                "mov x16, #3\n"
                "brk #0xf00d\n"
                : "=r"(x0_result)
                : "r"(x0_val), "r"(x1_val)
                : "x16", "memory"
            );
            ERR("page0 M8 debugger: result=%lu\n", (unsigned long)x0_result);
            if (x0_result == 1) {
                /* Verify: read PEB from address 0+offset */
                uintptr_t teb_off = (uintptr_t)teb - ((uintptr_t)teb & ~0x3FFFULL);
                uint64_t peb0 = *(volatile uint64_t *)(teb_off + 0x60);
                uint64_t peb_real = *(volatile uint64_t *)((uintptr_t)teb + 0x60);
                ERR("page0 M8 verify: peb@0x%lx=%p real=%p %s\n",
                    (unsigned long)(teb_off + 0x60), (void*)peb0, (void*)peb_real,
                    peb0 == peb_real ? "MATCH" : "MISMATCH");
                if (peb0 == peb_real) mapped = 8;
            }
        }

        if (!mapped) {
            ERR("ALL page0 mapping approaches FAILED (including debugger) — relying on Mach handler only\n");
        }
    }
    /* Register this thread with the shared Mach exception handler.
     * First call creates the handler thread; all calls register the thread. */
    ios_setup_mach_exception_handler( pthread_mach_thread_np(pthread_self()),
                                       (uintptr_t)teb, ios_my_trampoline );
    /* Give the handler thread a moment to start (only needed for first thread) */
    if (!ios_exc_thread_alive) usleep(10000);
    ERR("init_syscall_frame: mach exc thread alive=%d, slot=%d\n",
        ios_exc_thread_alive, ios_my_slot);

    ERR("init_syscall_frame: signals_total=%d before PE entry\n", ios_signal_total);
    ERR("init_syscall_frame: frame=%p pc=%p x0=%p sp=%p x18=%p restore_flags=0x%x\n",
        frame, (void*)(uintptr_t)frame->pc, (void*)(uintptr_t)frame->x[0],
        (void*)(uintptr_t)frame->sp, (void*)(uintptr_t)frame->x[18], frame->restore_flags);

    /* Note: SIGALRM x18 watchdog was tried but abandoned — too disruptive
     * for PE code execution. The zero-page silent read issue remains:
     * when x18=0, [x18+0x60] returns PEB=0 from the hardware zero page
     * without faulting, so the Mach handler can't intervene. */
#endif

    pthread_sigmask( SIG_UNBLOCK, &server_block_set, NULL );
}


/***********************************************************************
 *           signal_start_thread
 */
__ASM_GLOBAL_FUNC( signal_start_thread,
                   "stp x29, x30, [sp,#-0xc0]!\n\t"
                   __ASM_CFI(".cfi_def_cfa_offset 0xc0\n\t")
                   __ASM_CFI(".cfi_offset 29,-0xc0\n\t")
                   __ASM_CFI(".cfi_offset 30,-0xb8\n\t")
                   "mov x29, sp\n\t"
                   __ASM_CFI(".cfi_def_cfa_register 29\n\t")
                   "stp x19, x20, [x29, #0x10]\n\t"
                   __ASM_CFI(".cfi_rel_offset 19,0x10\n\t")
                   __ASM_CFI(".cfi_rel_offset 20,0x18\n\t")
                   "stp x21, x22, [x29, #0x20]\n\t"
                   __ASM_CFI(".cfi_rel_offset 21,0x20\n\t")
                   __ASM_CFI(".cfi_rel_offset 22,0x28\n\t")
                   "stp x23, x24, [x29, #0x30]\n\t"
                   __ASM_CFI(".cfi_rel_offset 23,0x30\n\t")
                   __ASM_CFI(".cfi_rel_offset 24,0x38\n\t")
                   "stp x25, x26, [x29, #0x40]\n\t"
                   __ASM_CFI(".cfi_rel_offset 25,0x40\n\t")
                   __ASM_CFI(".cfi_rel_offset 26,0x48\n\t")
                   "stp x27, x28, [x29, #0x50]\n\t"
                   __ASM_CFI(".cfi_rel_offset 27,0x50\n\t")
                   __ASM_CFI(".cfi_rel_offset 28,0x58\n\t")
                   "add x5, x29, #0xc0\n\t"     /* syscall_cfa */
                   /* set syscall frame */
                   "ldr x4, [x3, #0x378]\n\t"   /* thread_data->syscall_frame */
                   "cbnz x4, 1f\n\t"
                   "sub x4, sp, #0x330\n\t"     /* sizeof(struct syscall_frame) */
                   "str x4, [x3, #0x378]\n\t"   /* thread_data->syscall_frame */
                   "1:\tstr wzr, [x4, #0x10c]\n\t" /* frame->restore_flags */
                   "stp xzr, x5, [x4, #0x110]\n\t" /* frame->prev_frame,syscall_cfa */
                   /* switch to kernel stack */
                   "mov sp, x4\n\t"
                   "bl " __ASM_NAME("init_syscall_frame") "\n\t"
#if 0 /* WINE_IOS: use standard dispatcher_return which loads ALL registers
       * and routes through the TEB trampoline on iOS */
#else
                   "b " __ASM_LOCAL_LABEL("__wine_syscall_dispatcher_return")
#endif
                   )


/***********************************************************************
 *           __wine_syscall_dispatcher
 */
__ASM_GLOBAL_FUNC( __wine_syscall_dispatcher,
                   "hint 34\n\t" /* bti c */
#ifdef WINE_IOS
                   /* iOS zeros x18 on context switches. Load TEB from TPIDRRO_EL0
                    * (pthread TLS) which iOS preserves. Fix x18 for frame saves. */
                   "mrs x10, TPIDRRO_EL0\n\t"
                   "and x10, x10, #~7\n\t"       /* clear CPU number bits */
                   "adrp x11, " __ASM_NAME("ios_teb_tls_slot_offset") "@PAGE\n\t"
                   "ldr w11, [x11, " __ASM_NAME("ios_teb_tls_slot_offset") "@PAGEOFF]\n\t"
                   "ldr x18, [x10, x11]\n\t"     /* x18 = TEB from TLS slot */
#endif
                   "ldr x10, [x18, #0x378]\n\t" /* thread_data->syscall_frame */
                   "stp x18, x19, [x10, #0x90]\n\t"
                   "stp x20, x21, [x10, #0xa0]\n\t"
                   "stp x22, x23, [x10, #0xb0]\n\t"
                   "stp x24, x25, [x10, #0xc0]\n\t"
                   "stp x26, x27, [x10, #0xd0]\n\t"
                   "stp x28, x29, [x10, #0xe0]\n\t"
                   "mov x19, sp\n\t"
                   "stp x9, x19, [x10, #0xf0]\n\t"
                   "mrs x9, NZCV\n\t"
                   "stp x30, x9, [x10, #0x100]\n\t"
                   "str w8, [x10, #0x120]\n\t"
                   "mrs x9, FPCR\n\t"
                   "str w9, [x10, #0x128]\n\t"
                   "mrs x9, FPSR\n\t"
                   "str w9, [x10, #0x12c]\n\t"
                   "stp q0,  q1,  [x10, #0x130]\n\t"
                   "stp q2,  q3,  [x10, #0x150]\n\t"
                   "stp q4,  q5,  [x10, #0x170]\n\t"
                   "stp q6,  q7,  [x10, #0x190]\n\t"
                   "stp q8,  q9,  [x10, #0x1b0]\n\t"
                   "stp q10, q11, [x10, #0x1d0]\n\t"
                   "stp q12, q13, [x10, #0x1f0]\n\t"
                   "stp q14, q15, [x10, #0x210]\n\t"
                   "stp q16, q17, [x10, #0x230]\n\t"
                   "stp q18, q19, [x10, #0x250]\n\t"
                   "stp q20, q21, [x10, #0x270]\n\t"
                   "stp q22, q23, [x10, #0x290]\n\t"
                   "stp q24, q25, [x10, #0x2b0]\n\t"
                   "stp q26, q27, [x10, #0x2d0]\n\t"
                   "stp q28, q29, [x10, #0x2f0]\n\t"
                   "stp q30, q31, [x10, #0x310]\n\t"
                   "mov x22, x10\n\t"
                   /* switch to kernel stack */
                   "mov sp, x10\n\t"
                   /* we're now on the kernel stack, stitch unwind info with previous frame */
                   __ASM_CFI_CFA_IS_AT2(x22, 0x98, 0x02) /* frame->syscall_cfa */
                   __ASM_CFI(".cfi_offset 29, -0xc0\n\t")
                   __ASM_CFI(".cfi_offset 30, -0xb8\n\t")
                   __ASM_CFI(".cfi_offset 19, -0xb0\n\t")
                   __ASM_CFI(".cfi_offset 20, -0xa8\n\t")
                   __ASM_CFI(".cfi_offset 21, -0xa0\n\t")
                   __ASM_CFI(".cfi_offset 22, -0x98\n\t")
                   __ASM_CFI(".cfi_offset 23, -0x90\n\t")
                   __ASM_CFI(".cfi_offset 24, -0x88\n\t")
                   __ASM_CFI(".cfi_offset 25, -0x80\n\t")
                   __ASM_CFI(".cfi_offset 26, -0x78\n\t")
                   __ASM_CFI(".cfi_offset 27, -0x70\n\t")
                   __ASM_CFI(".cfi_offset 28, -0x68\n\t")
                   "and x20, x8, #0xfff\n\t"    /* syscall number */
                   "ubfx x21, x8, #12, #2\n\t"  /* syscall table number */
                   "ldr x16, [x18, #0x370]\n\t" /* thread_data->syscall_table */
                   "add x21, x16, x21, lsl #5\n\t"
                   "ldr x16, [x21, #16]\n\t"    /* table->ServiceLimit */
                   "cmp x20, x16\n\t"
                   "bcs " __ASM_LOCAL_LABEL("bad_syscall") "\n\t"
                   "ldr x16, [x21, #24]\n\t"    /* table->ArgumentTable */
                   "ldrb w9, [x16, x20]\n\t"
                   "subs x9, x9, #64\n\t"
                   "bls 2f\n\t"
                   "sub sp, sp, x9\n\t"
                   "tbz x9, #3, 1f\n\t"
                   "sub sp, sp, #8\n"
                   "1:\tsub x9, x9, #8\n\t"
                   "ldr x10, [x19, x9]\n\t"
                   "str x10, [sp, x9]\n\t"
                   "cbnz x9, 1b\n"
                   "2:\tldr x16, [x21]\n\t"     /* table->ServiceTable */
                   "ldr x23, [x16, x20, lsl 3]\n\t"
                   "ldr w11, [x18, #0x380]\n\t" /* thread_data->syscall_trace */
                   "cbnz x11, " __ASM_LOCAL_LABEL("trace_syscall") "\n\t"
                   "blr x23\n\t"
                   "mov sp, x22\n"
                   __ASM_CFI_CFA_IS_AT2(sp, 0x98, 0x02) /* frame->syscall_cfa */
                   __ASM_LOCAL_LABEL("__wine_syscall_dispatcher_return") ":\n\t"
#ifdef WINE_IOS
                   /* Trace: capture frame->x[18] and frame->pc before they are loaded */
                   "ldr x10, [sp, #0x90]\n\t"   /* frame->x[18] - will become x18 */
                   "adrp x11, " __ASM_NAME("g_wine_return_x18") "@PAGE\n\t"
                   "str x10, [x11, " __ASM_NAME("g_wine_return_x18") "@PAGEOFF]\n\t"
                   "ldr x10, [sp, #0x100]\n\t"  /* frame->pc - will become ret target */
                   "adrp x11, " __ASM_NAME("g_wine_return_pc") "@PAGE\n\t"
                   "str x10, [x11, " __ASM_NAME("g_wine_return_pc") "@PAGEOFF]\n\t"
                   "adrp x11, " __ASM_NAME("g_wine_return_count") "@PAGE\n\t"
                   "ldr x10, [x11, " __ASM_NAME("g_wine_return_count") "@PAGEOFF]\n\t"
                   "add x10, x10, #1\n\t"
                   "str x10, [x11, " __ASM_NAME("g_wine_return_count") "@PAGEOFF]\n\t"
                   /* ring buffer: store frame->pc (at sp+0x100) into ring[idx & 7] */
                   "ldr x10, [sp, #0x100]\n\t"          /* frame->pc */
                   "adrp x11, " __ASM_NAME("g_wine_return_ring_idx") "@PAGE\n\t"
                   "ldr w12, [x11, " __ASM_NAME("g_wine_return_ring_idx") "@PAGEOFF]\n\t"
                   "and w13, w12, #7\n\t"                /* idx & 7 */
                   "add w12, w12, #1\n\t"
                   "str w12, [x11, " __ASM_NAME("g_wine_return_ring_idx") "@PAGEOFF]\n\t"
                   "adrp x11, " __ASM_NAME("g_wine_return_ring") "@PAGE\n\t"
                   "add x11, x11, " __ASM_NAME("g_wine_return_ring") "@PAGEOFF\n\t"
                   "str x10, [x11, x13, lsl #3]\n\t"    /* ring[idx&7] = frame->pc */
#endif
                   "ldr w16, [sp, #0x10c]\n\t"  /* frame->restore_flags */
                   "tbz x16, #1, 2f\n\t"        /* CONTEXT_INTEGER */
                   "ldp x12, x13, [sp, #0x80]\n\t" /* frame->x[16..17] */
                   "ldp x14, x15, [sp, #0xf8]\n\t" /* frame->sp, frame->pc */
                   "cmp x12, x15\n\t"              /* frame->x16 == frame->pc? */
                   "ccmp x13, x14, #0, eq\n\t"     /* frame->x17 == frame->sp? */
                   "beq 1f\n\t"                    /* take slowpath if unequal */
                   "bl " __ASM_NAME("syscall_dispatcher_return_slowpath") "\n"
                   "1:\tldp x0, x1, [sp, #0x00]\n\t"
                   "ldp x2, x3, [sp, #0x10]\n\t"
                   "ldp x4, x5, [sp, #0x20]\n\t"
                   "ldp x6, x7, [sp, #0x30]\n\t"
                   "ldp x8, x9, [sp, #0x40]\n\t"
                   "ldp x10, x11, [sp, #0x50]\n\t"
                   "ldp x12, x13, [sp, #0x60]\n\t"
                   "ldp x14, x15, [sp, #0x70]\n"
                   "2:\tldp x18, x19, [sp, #0x90]\n\t"
#ifdef WINE_IOS
                   /* TPIDR_EL0 not used — iOS zeros it. TEB stored via pthread TLS (TPIDRRO_EL0). */
#endif
                   "ldp x20, x21, [sp, #0xa0]\n\t"
                   "ldp x22, x23, [sp, #0xb0]\n\t"
                   "ldp x24, x25, [sp, #0xc0]\n\t"
                   "ldp x26, x27, [sp, #0xd0]\n\t"
                   "ldp x28, x29, [sp, #0xe0]\n\t"
                   "tbz x16, #2, 1f\n\t"        /* CONTEXT_FLOATING_POINT */
                   "ldp q0,  q1,  [sp, #0x130]\n\t"
                   "ldp q2,  q3,  [sp, #0x150]\n\t"
                   "ldp q4,  q5,  [sp, #0x170]\n\t"
                   "ldp q6,  q7,  [sp, #0x190]\n\t"
                   "ldp q8,  q9,  [sp, #0x1b0]\n\t"
                   "ldp q10, q11, [sp, #0x1d0]\n\t"
                   "ldp q12, q13, [sp, #0x1f0]\n\t"
                   "ldp q14, q15, [sp, #0x210]\n\t"
                   "ldp q16, q17, [sp, #0x230]\n\t"
                   "ldp q18, q19, [sp, #0x250]\n\t"
                   "ldp q20, q21, [sp, #0x270]\n\t"
                   "ldp q22, q23, [sp, #0x290]\n\t"
                   "ldp q24, q25, [sp, #0x2b0]\n\t"
                   "ldp q26, q27, [sp, #0x2d0]\n\t"
                   "ldp q28, q29, [sp, #0x2f0]\n\t"
                   "ldp q30, q31, [sp, #0x310]\n\t"
                   "ldr w17, [sp, #0x128]\n\t"
                   "msr FPCR, x17\n\t"
                   "ldr w17, [sp, #0x12c]\n\t"
                   "msr FPSR, x17\n"
                   "1:\tldp x16, x17, [sp, #0x100]\n\t"
                   "msr NZCV, x17\n\t"
                   /* x18 was restored from frame->x[18] at label 2 above.
                    * This path does NOT go through sigreturn, so x18 survives.
                    * If a context switch zeroes x18 before PE code runs,
                    * the Mach exception handler fixes it via per-thread trampoline. */
                   "ldp x30, x17, [sp, #0xf0]\n\t"
                   /* switch to user stack */
                   "mov sp, x17\n\t"
                   "ret x16\n"

                   __ASM_LOCAL_LABEL("trace_syscall") ":\n\t"
                   "stp x0, x1, [sp, #-0x40]!\n\t"
                   "stp x2, x3, [sp, #0x10]\n\t"
                   "stp x4, x5, [sp, #0x20]\n\t"
                   "stp x6, x7, [sp, #0x30]\n\t"
                   "mov x0, x8\n\t"             /* id */
                   "mov x1, sp\n\t"             /* args */
                   "ldr x16, [x21, #24]\n\t"    /* table->ArgumentTable */
                   "ldrb w2, [x16, x20]\n\t"    /* len */
                   "bl " __ASM_NAME("trace_syscall") "\n\t"
                   "ldp x2, x3, [sp, #0x10]\n\t"
                   "ldp x4, x5, [sp, #0x20]\n\t"
                   "ldp x6, x7, [sp, #0x30]\n\t"
                   "ldp x0, x1, [sp], #0x40\n\t"
                   "blr x23\n"
                   "mov sp, x22\n"

                   __ASM_LOCAL_LABEL("trace_syscall_ret") ":\n\t"
                   "mov x21, x0\n\t"            /* retval */
                   "ldr w0, [sp, #0x120]\n\t"   /* frame->syscall_id */
                   "mov x1, x21\n\t"            /* retval */
                   "bl " __ASM_NAME("trace_sysret") "\n\t"
                   "mov x0, x21\n\t"            /* retval */
                   "b " __ASM_LOCAL_LABEL("__wine_syscall_dispatcher_return") "\n"

                   __ASM_LOCAL_LABEL("bad_syscall") ":\n\t"
                   "mov x0, #0xc0000000\n\t"    /* STATUS_INVALID_SYSTEM_SERVICE */
                   "movk x0, #0x001c\n\t"
                   "b " __ASM_LOCAL_LABEL("__wine_syscall_dispatcher_return") )

__ASM_GLOBAL_FUNC( __wine_syscall_dispatcher_return,
                   "ldr w11, [x18, #0x380]\n\t" /* thread_data->syscall_trace */
                   "cbnz x11, " __ASM_LOCAL_LABEL("trace_syscall_ret") "\n\t"
                   "b " __ASM_LOCAL_LABEL("__wine_syscall_dispatcher_return") )


/***********************************************************************
 *           __wine_unix_call_dispatcher
 */
/***********************************************************************
 *           ios_unixlib_null_call
 *
 * Where __wine_unix_call_dispatcher sends a call it cannot make: a NULL
 * table (a DLL whose __wine_init_unix_call() failed and that called
 * WINE_UNIX_CALL anyway -- on this port a 32-bit module with no unix side,
 * which the loader refuses with STATUS_NOT_SUPPORTED), a code past any
 * builtin's funcs_count, or a NULL entry inside a real table.  Upstream
 * dereferences the table and the whole pseudo-process dies in the
 * dispatcher, on a host-side fault no guest handler can see.  Report the
 * caller once per module and answer STATUS_NOT_IMPLEMENTED, which is what
 * the caller's own error path already expects from a missing unix side.
 */
#define IOS_UNIXLIB_MAX_CODE     0x1000
#define IOS_UNIXLIB_MAX_CODE_STR "0x1000"

#define IOS_UNIXLIB_NULL_SEEN 32
static uint64_t ios_unixlib_null_seen[IOS_UNIXLIB_NULL_SEEN];
static unsigned int ios_unixlib_null_seen_count;

NTSTATUS __attribute__((used)) ios_unixlib_null_call( UINT64 handle, unsigned int code,
                                                      const void *ret_addr )
{
    uint64_t lr = (uint64_t)(uintptr_t)ret_addr, key = 0, rva = 0;
    const char *name = "?";
    unsigned int i;
    Dl_info di;
    extern uint64_t ios_jit_reverse_translate( uint64_t addr, uint64_t *module_base );
    uint64_t mod = 0, va;

    if (lr && (va = ios_jit_reverse_translate( lr, &mod )) && mod)
    {
        name = ios_pe_module_name( mod );
        rva  = va - mod;
        key  = mod;
    }
    else if (lr && dladdr( (void *)(uintptr_t)lr, &di ) && di.dli_fbase)
    {
        if (di.dli_fname) name = di.dli_fname;
        rva = lr - (uint64_t)(uintptr_t)di.dli_fbase;
        key = (uint64_t)(uintptr_t)di.dli_fbase;
    }
    else key = lr & ~0xfffull;

    for (i = 0; i < ios_unixlib_null_seen_count && i < IOS_UNIXLIB_NULL_SEEN; i++)
        if (ios_unixlib_null_seen[i] == key) return STATUS_NOT_IMPLEMENTED;
    if (ios_unixlib_null_seen_count < IOS_UNIXLIB_NULL_SEEN)
        ios_unixlib_null_seen[ios_unixlib_null_seen_count++] = key;

    dprintf( STDERR_FILENO,
             "[unixlib] call with %s from %s+0x%llx code=%u handle=0x%llx -> "
             "STATUS_NOT_IMPLEMENTED (this module has no unix side on this port; "
             "further calls from it are silent)\n",
             !handle ? "NULL handle" :
             code >= IOS_UNIXLIB_MAX_CODE ? "out-of-range code" : "NULL table entry",
             name, (unsigned long long)rva, code, (unsigned long long)handle );
    return STATUS_NOT_IMPLEMENTED;
}


__ASM_GLOBAL_FUNC( __wine_unix_call_dispatcher,
                   "hint 34\n\t" /* bti c */
#ifdef WINE_IOS
                   "mrs x10, TPIDRRO_EL0\n\t"
                   "and x10, x10, #~7\n\t"
                   "adrp x11, " __ASM_NAME("ios_teb_tls_slot_offset") "@PAGE\n\t"
                   "ldr w11, [x11, " __ASM_NAME("ios_teb_tls_slot_offset") "@PAGEOFF]\n\t"
                   "ldr x18, [x10, x11]\n\t"     /* x18 = TEB from TLS */
#endif
                   "ldr x10, [x18, #0x378]\n\t" /* thread_data->syscall_frame */
                   "stp x18, x19, [x10, #0x90]\n\t"
                   "stp x20, x21, [x10, #0xa0]\n\t"
                   "stp x22, x23, [x10, #0xb0]\n\t"
                   "stp x24, x25, [x10, #0xc0]\n\t"
                   "stp x26, x27, [x10, #0xd0]\n\t"
                   "stp x28, x29, [x10, #0xe0]\n\t"
                   "stp q8,  q9,  [x10, #0x1b0]\n\t"
                   "stp q10, q11, [x10, #0x1d0]\n\t"
                   "stp q12, q13, [x10, #0x1f0]\n\t"
                   "stp q14, q15, [x10, #0x210]\n\t"
                   "mov x9, sp\n\t"
                   "stp x30, x9, [x10, #0xf0]\n\t"
                   "mrs x9, NZCV\n\t"
                   "stp x30, x9, [x10, #0x100]\n\t"
                   "mov x19, x10\n\t"
                   /* switch to kernel stack */
                   "mov sp, x10\n\t"
                   /* we're now on the kernel stack, stitch unwind info with previous frame */
                   __ASM_CFI_CFA_IS_AT2(x19, 0x98, 0x02) /* frame->syscall_cfa */
                   __ASM_CFI(".cfi_offset 29, -0xc0\n\t")
                   __ASM_CFI(".cfi_offset 30, -0xb8\n\t")
                   __ASM_CFI(".cfi_offset 19, -0xb0\n\t")
                   __ASM_CFI(".cfi_offset 20, -0xa8\n\t")
                   __ASM_CFI(".cfi_offset 21, -0xa0\n\t")
                   __ASM_CFI(".cfi_offset 22, -0x98\n\t")
                   __ASM_CFI(".cfi_offset 23, -0x90\n\t")
                   __ASM_CFI(".cfi_offset 24, -0x88\n\t")
                   __ASM_CFI(".cfi_offset 25, -0x80\n\t")
                   __ASM_CFI(".cfi_offset 26, -0x78\n\t")
                   __ASM_CFI(".cfi_offset 27, -0x70\n\t")
                   __ASM_CFI(".cfi_offset 28, -0x68\n\t")
                   /* Never dereference a unixlib table the PE side never got.
                    * x0 is the table, x1 the code; a NULL table, a code past
                    * any builtin's funcs_count, or a NULL entry inside a real
                    * table all divert to ios_unixlib_null_call(), which logs
                    * once per caller module and returns STATUS_NOT_IMPLEMENTED.
                    * Three instructions on the hot path, against a host-side
                    * fault that killed the whole pseudo-process. */
                   "cbz x0, " __ASM_LOCAL_LABEL("unixcall_no_table") "\n\t"
                   "cmp x1, #" IOS_UNIXLIB_MAX_CODE_STR "\n\t"
                   "b.hs " __ASM_LOCAL_LABEL("unixcall_no_table") "\n\t"
                   "ldr x16, [x0, x1, lsl 3]\n\t"
                   "cbz x16, " __ASM_LOCAL_LABEL("unixcall_no_table") "\n\t"
                   "mov x0, x2\n\t"             /* args */
                   "blr x16\n"
                   __ASM_LOCAL_LABEL("unixcall_return") ":\n\t"
                   "ldr w16, [sp, #0x10c]\n\t"  /* frame->restore_flags */
                   "cbnz w16, " __ASM_LOCAL_LABEL("__wine_syscall_dispatcher_return") "\n\t"
                   __ASM_CFI_CFA_IS_AT2(sp, 0x98, 0x02) /* frame->syscall_cfa */
                   "ldp x18, x19, [sp, #0x90]\n\t"
                   /* iOS-Madeira 2026-07-04: REMOVED `msr TPIDR_EL0, x18`
                    * ("keep TPIDR_EL0 in sync"). Nothing of ours reads
                    * TPIDR_EL0 — every TEB recovery path (dispatchers, x18
                    * patcher trampolines, Mach handler) uses TPIDRRO_EL0 +
                    * TSD slot; the patcher header comment claiming
                    * TPIDR_EL0 was stale. Writing an OS-owned per-thread
                    * register on every unix-call return is pure risk:
                    * libsystem_malloc died with corrupted per-thread zone
                    * state (Metal texture allocs, 3 runs) right after
                    * UNIXCALL-DIRECT multiplied direct returns. */
                   "ldp x16, x17, [sp, #0xf8]\n\t"
                   /* switch to user stack */
                   "mov sp, x16\n\t"
                   "ret x17\n"

                   /* No table, no entry, or a code out of range: report it and
                    * return STATUS_NOT_IMPLEMENTED through the normal epilogue.
                    * x0/x1 still hold the handle and the code; x30 still holds
                    * the caller's return address (it was only SAVED to the
                    * frame above, never overwritten), and clobbering it with
                    * the `bl` is safe because the return uses x17 loaded from
                    * the frame, not x30. */
                   __ASM_LOCAL_LABEL("unixcall_no_table") ":\n\t"
                   "mov x2, x30\n\t"            /* ret_addr */
                   "bl " __ASM_NAME("ios_unixlib_null_call") "\n\t"
                   "b " __ASM_LOCAL_LABEL("unixcall_return") )

#endif  /* __aarch64__ */

/* ============================================================ *
 * [thread-stacks] all-thread stack sampler — diagnoses wedged wine
 * threads (S2: explorer main leaves its message pump and blocks
 * forever; [srv-queues] showed wake_mask=0 with 20 posted messages
 * pending). Called from an app-side GCD timer (Winios.m) so it keeps
 * firing even when every wine thread is stuck. Samples WITHOUT
 * suspending — racy pc/fp reads are acceptable for stuck-thread
 * triage; a blocked thread's state is stable anyway.
 * ============================================================ */
/* Best-effort PE module name from the export directory at pe_base (the
 * original unix-view image stays mapped). Returns "(exe)" for images
 * without exports, "?" when headers look wrong. */
/* ml347: FAULT-SAFE. This runs on the Mach exception handler thread while a
 * module may be mid-load (PE pages unreadable). The old raw derefs nested-
 * faulted the handler thread inside its own dump loop — no reply ever sent,
 * original faulting thread parked (ml345) or the debugger killed the app
 * (ml346). Every read goes through mach_vm_read_overwrite. */
static const char *ios_pe_module_name( uint64_t base )
{
    static char namebuf[64];   /* single exception-handler thread only */
    unsigned char hdr[2];
    uint32_t e_lfanew = 0, pe_sig = 0, exp_rva = 0, name_rva = 0;
    mach_vm_size_t got = 0;
    uint64_t name_addr, page_left, want;

    if (!base) return "?";
    if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)base, 2,
                               (mach_vm_address_t)hdr, &got) != KERN_SUCCESS || got != 2)
        return "?";
    if (hdr[0] != 'M' || hdr[1] != 'Z') return "?";
    if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)(base + 0x3c), 4,
                               (mach_vm_address_t)&e_lfanew, &got) != KERN_SUCCESS || got != 4)
        return "?";
    if (e_lfanew == 0 || e_lfanew > 0x1000) return "?";
    if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)(base + e_lfanew), 4,
                               (mach_vm_address_t)&pe_sig, &got) != KERN_SUCCESS || got != 4)
        return "?";
    if (pe_sig != 0x00004550) return "?";
    /* ml998: THE EXPORT DIRECTORY IS NOT AT THE SAME OFFSET IN PE32 AND PE32+.
     *
     * This read was hardcoded to e_lfanew+0x88, which is IMAGE_NT_HEADERS64's
     * DataDirectory[0] (OptionalHeader at +0x18, DataDirectory at +0x70).  In a
     * 32-bit image OptionalHeader32 puts DataDirectory at +0x60, so the export
     * directory is at e_lfanew+0x78 and +0x88 is DataDirectory[2] -- RESOURCE.
     * `exp_rva' was therefore the resource RVA, `name_rva' was read from offset
     * 0x0c of IMAGE_RESOURCE_DIRECTORY (NumberOfNamedEntries | NumberOfIdEntries
     * << 16, a small plausible-looking number that passes the range check), and
     * the "name" was 63 arbitrary bytes from that address.
     *
     * That is where the profiler's `Zx' and `PnQ' modules came from: r76 line
     * 6858 reports `jit by module: Zx=42.4% ... Zx=0.2%' -- the same two-letter
     * garbage twice, for two different images, at 21-44 % of all CPU.  Both are
     * 32-bit guest DLLs that the MZ probe had to name because they loaded after
     * the one-shot loader walk (see ios_gmod32_build).  SizeOfImage happens to
     * sit at +0x50 in BOTH layouts, which is why ios_gmod32_probe's own reads
     * were right and only the name was wrong.
     *
     * Pick the layout from OptionalHeader.Magic, the field that exists to say
     * which one it is. */
    {
        unsigned short magic = 0;
        uint32_t ddir_off;
        if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)(base + e_lfanew + 0x18), 2,
                                   (mach_vm_address_t)&magic, &got) != KERN_SUCCESS || got != 2)
            return "?";
        if (magic == 0x010b) ddir_off = 0x78;        /* PE32  */
        else if (magic == 0x020b) ddir_off = 0x88;   /* PE32+ */
        else return "?";
        if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)(base + e_lfanew + ddir_off), 4,
                                   (mach_vm_address_t)&exp_rva, &got) != KERN_SUCCESS || got != 4)
            return "?";
    }
    if (!exp_rva || exp_rva > 0x10000000) return "(exe)";
    if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)(base + exp_rva + 0x0c), 4,
                               (mach_vm_address_t)&name_rva, &got) != KERN_SUCCESS || got != 4)
        return "(exe)";
    if (!name_rva || name_rva > 0x10000000) return "(exe)";
    /* Clamp the name read to the containing page so a mapped name page next
     * to an unmapped one doesn't fail the whole read. */
    name_addr = base + name_rva;
    page_left = 0x4000 - (name_addr & 0x3fff);
    want = sizeof(namebuf) - 1;
    if (want > page_left) want = page_left;
    if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)name_addr, want,
                               (mach_vm_address_t)namebuf, &got) != KERN_SUCCESS || got == 0)
        return "(exe)";
    namebuf[got < sizeof(namebuf) ? got : sizeof(namebuf) - 1] = 0;
    namebuf[sizeof(namebuf) - 1] = 0;
    return namebuf;
}

/* ============================================================================
 * ml686 WAIT-CHAIN SNAPSHOT
 *
 * ml685 established that ONE Unity job worker sits at 100% CPU in a ~256-byte
 * loop for an entire run (34 of 35 samples, run_state=1 every time), polling a
 * word that holds its own address, while the render thread and DXMT's encoder
 * both wait. Memory, GPU sequence lag, the fault storm and compressor thrash
 * were each measured and eliminated as the cause of the ~1s frame gap.
 *
 * A spinning consumer is most likely a SYMPTOM: the interesting thread is
 * whichever producer should be filling that queue and isn't. A list of PCs
 * cannot show that -- an EDGE can ("render thread waits on object A, whose
 * owner is worker B"). So capture every thread at three points spanning a
 * frame period and record what each one is waiting ON, not just where it is.
 *
 * Runs from the sampler thread, never from a Mach exception handler, and never
 * suspends anything: reads are racy-but-stable for blocked threads, which is
 * exactly the population of interest. */
/* ============================================================================
 * ml688 NATIVE JIT RIP RESOLVER
 *
 * ml686 named the failure honestly: "callback NOT INSTALLED". The obvious move
 * -- arm ios_fex_rip_resolved -- is a TRAP. virtual_ios.c records that pointer
 * for DIAGNOSTICS ONLY and carries an explicit ml614 warning against arming it:
 * BTCpu64IosRipFromHostPC is an ARM64EC **PE** export, so a native `blr` fetches
 * its x64 entry thunk as ARM64 instructions. ml613 armed it and crashed every
 * launch. Arming it now would simply reproduce that.
 *
 * So resolve the RIP natively instead. FEX appends a host-PC -> guest-RIP table
 * to every JIT block (vl64pair entries in the block tail); this walks the same
 * table with our own decoder, reading everything through mach_vm_read_overwrite
 * so a corrupt header cannot fault the sampler.
 *
 * The decoder was validated OFFLINE against FEXCore's own Encode/Decode over
 * 18,919 cases spanning all four encodings -- 0 mismatches -- before shipping.
 * Returns 0 for "no answer"; *why gets the specific reason. */
struct ios_vlpair { uint64_t arm, rip; unsigned size; };

static struct ios_vlpair ios_vl64pair_decode( const uint8_t *d )
{
    struct ios_vlpair o;
    if ((d[0] >> 7) == 0)                        /* vl8 */
    {
        o.arm = ((uint64_t)(d[0] & 0xF) + 1) << 2;
        o.rip = (uint64_t)((d[0] >> 4) & 0x7) + 1;
        o.size = 1;
    }
    else if ((d[0] >> 6) == 0x2)                 /* vl16 */
    {
        int64_t rip6 = (int64_t)(int8_t)((d[0] & 0x3F) << 2) >> 2;   /* sign-extend 6 */
        o.arm = (uint64_t)(((int64_t)(int8_t)d[1]) << 2);
        o.rip = (uint64_t)rip6;
        o.size = 2;
    }
    else if (d[0] == 0xC0)                       /* vl32 */
    {
        int32_t a, r;
        memcpy( &a, d + 1, 4 ); memcpy( &r, d + 5, 4 );
        o.arm = (uint64_t)(int64_t)a; o.rip = (uint64_t)(int64_t)r; o.size = 9;
    }
    else                                          /* vl64 */
    {
        memcpy( &o.arm, d + 1, 8 ); memcpy( &o.rip, d + 9, 8 );
        o.size = 17;
    }
    return o;
}

uint64_t ios_native_rip_from_hostpc( uint64_t block_begin, uint64_t host_pc, const char **why )
{
    uint32_t off_tail = 0;
    struct { uint64_t size; uint64_t rip; uint64_t guest_size;
             uint32_t n_entries; uint32_t off_entries; } tail;
    mach_vm_size_t got = 0;
    uint8_t tab[512];
    uint64_t cur_host, cur_rip, tab_addr;
    uint32_t i, pos = 0;

    if (why) *why = "ok";
    if (!block_begin) { if (why) *why = "BlockBegin==0"; return 0; }

    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)block_begin,
            sizeof(off_tail), (mach_vm_address_t)&off_tail, &got ) != KERN_SUCCESS ||
        got != sizeof(off_tail))
    { if (why) *why = "header unreadable"; return 0; }

    if (off_tail < 4 || off_tail > (64u << 20))
    { if (why) *why = "OffsetToBlockTail implausible"; return 0; }

    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(block_begin + off_tail),
            sizeof(tail), (mach_vm_address_t)&tail, &got ) != KERN_SUCCESS || got != sizeof(tail))
    { if (why) *why = "tail unreadable"; return 0; }

    if (!tail.size || tail.size > (64u << 20))
    { if (why) *why = "block Size implausible"; return 0; }
    if (host_pc < block_begin || host_pc >= block_begin + tail.size)
    { if (why) *why = "hostPC outside block"; return 0; }
    if (tail.n_entries > 65536)
    { if (why) *why = "NumberOfRIPEntries implausible"; return 0; }

    tab_addr = block_begin + off_tail + tail.off_entries;
    cur_host = block_begin;
    cur_rip  = tail.rip;
    if (!tail.n_entries) { if (why) *why = "no RIP entries (block entry RIP)"; return cur_rip; }

    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)tab_addr,
            sizeof(tab), (mach_vm_address_t)tab, &got ) != KERN_SUCCESS || got < 32)
    { if (why) *why = "RIP table unreadable"; return 0; }

    for (i = 0; i < tail.n_entries; i++)
    {
        struct ios_vlpair e;
        if (pos + 17 > (uint32_t)got)
        {
            /* ml875: the table can exceed one 512-byte window; ml688 silently
             * stopped here and returned a PARTIAL RIP. Slide the window. */
            tab_addr += pos; pos = 0; got = 0;
            if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)tab_addr,
                    sizeof(tab), (mach_vm_address_t)tab, &got ) != KERN_SUCCESS || got < 17)
            { if (why) *why = "RIP table truncated"; return 0; }
        }
        e = ios_vl64pair_decode( tab + pos );
        pos += e.size;
        if (host_pc >= cur_host + e.arm) { cur_host += e.arm; cur_rip += e.rip; }
        else break;
    }
    return cur_rip;
}

static const char *ios_wait_api_name( uint64_t pc, const char *sym )
{
    if (!sym) return "?";
    /* the handful of primitives every Wine/Unity wait bottoms out in */
    if (strstr(sym, "__ulock_wait"))        return "ulock_wait(futex)";
    if (strstr(sym, "semaphore_wait"))      return "semaphore_wait";
    if (strstr(sym, "semaphore_timedwait")) return "semaphore_timedwait";
    if (strstr(sym, "__psynch_cvwait"))     return "cond_wait";
    if (strstr(sym, "__psynch_mutexwait"))  return "mutex_wait";
    if (strstr(sym, "read"))                return "read(wineserver)";
    if (strstr(sym, "select") || strstr(sym, "poll")) return "select/poll";
    if (strstr(sym, "mach_msg"))            return "mach_msg";
    if (strstr(sym, "kevent"))              return "kevent";
    return sym;
}

/* ============================================================================
 * ml689 GUEST MODULE MAP
 *
 * ml688's native resolver produced real guest RIPs (0x71fbdfef51 and friends)
 * but nothing could NAME them: the ios_jit_mappings table holds the ARM64EC PE
 * copies FEX made, not the x64 guest modules. So the hottest guest code in the
 * app stayed an anonymous address.
 *
 * Walk the guest loader list instead -- TEB->PEB->Ldr->InLoadOrderModuleList --
 * so every guest RIP resolves to Module+RVA and can be disassembled offline
 * against the file on the phone prefix. All reads bounded and fault-safe. */
#define IOS_GMOD_MAX 192
static struct { uint64_t base, size; char name[52]; } ios_gmods[IOS_GMOD_MAX];
static int ios_gmod_count = 0;

static void ios_guest_modmap_build( uint64_t teb )
{
    uint64_t peb = 0, ldr = 0, head, cur;
    mach_vm_size_t g = 0;
    int guard = 0;

    if (ios_gmod_count || !teb) return;
    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(teb + 0x60), 8,
                                (mach_vm_address_t)&peb, &g ) != KERN_SUCCESS || g != 8 || !peb) return;
    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(peb + 0x18), 8,
                                (mach_vm_address_t)&ldr, &g ) != KERN_SUCCESS || g != 8 || !ldr) return;

    head = ldr + 0x10;                       /* InLoadOrderModuleList */
    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)head, 8,
                                (mach_vm_address_t)&cur, &g ) != KERN_SUCCESS || g != 8) return;

    while (cur && cur != head && guard++ < IOS_GMOD_MAX && ios_gmod_count < IOS_GMOD_MAX)
    {
        uint64_t dllbase = 0, next = 0;
        uint32_t imgsize = 0;
        uint16_t nlen = 0;
        uint64_t nbuf = 0;

        /* LDR_DATA_TABLE_ENTRY (x64): DllBase +0x30, SizeOfImage +0x40,
         * BaseDllName UNICODE_STRING +0x58 (Length +0x58, Buffer +0x60) */
        if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(cur + 0x30), 8,
                                    (mach_vm_address_t)&dllbase, &g ) != KERN_SUCCESS || g != 8) break;
        if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(cur + 0x40), 4,
                                    (mach_vm_address_t)&imgsize, &g ) != KERN_SUCCESS || g != 4) break;
        mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(cur + 0x58), 2,
                                (mach_vm_address_t)&nlen, &g );
        mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(cur + 0x60), 8,
                                (mach_vm_address_t)&nbuf, &g );

        if (dllbase && imgsize && imgsize < (512u << 20))
        {
            char nm[52]; unsigned k, n = nlen / 2;
            memset( nm, 0, sizeof(nm) );
            if (n > sizeof(nm) - 1) n = sizeof(nm) - 1;
            for (k = 0; k < n && nbuf; k++)
            {
                uint16_t wc = 0;
                if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)(nbuf + k * 2), 2,
                                            (mach_vm_address_t)&wc, &g ) != KERN_SUCCESS) break;
                nm[k] = (wc < 0x80) ? (char)wc : '?';
            }
            ios_gmods[ios_gmod_count].base = dllbase;
            ios_gmods[ios_gmod_count].size = imgsize;
            memcpy( ios_gmods[ios_gmod_count].name, nm, sizeof(nm) - 1 );
            ios_gmod_count++;
        }
        if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)cur, 8,
                                    (mach_vm_address_t)&next, &g ) != KERN_SUCCESS || g != 8) break;
        cur = next;
    }

    if (ios_gmod_count)
    {
        int i;
        fprintf(stderr, "[modmap] ml689 %d guest modules\n", ios_gmod_count);
        for (i = 0; i < ios_gmod_count; i++)
            fprintf(stderr, "[modmap]   0x%llx +0x%llx  %s\n",
                    (unsigned long long)ios_gmods[i].base,
                    (unsigned long long)ios_gmods[i].size, ios_gmods[i].name);
    }
}

static const char *ios_guest_module_for( uint64_t rip, uint64_t *rva )
{
    int i;
    for (i = 0; i < ios_gmod_count; i++)
        if (rip >= ios_gmods[i].base && rip < ios_gmods[i].base + ios_gmods[i].size)
        {
            if (rva) *rva = rip - ios_gmods[i].base;
            return ios_gmods[i].name;
        }
    if (rva) *rva = rip;
    return NULL;
}

/* ============================================================================
 * ml688 BOUNDED ALL-THREAD PROFILE
 *
 * Every FPS theory so far was chosen by picking a suspicious thread and arguing
 * from it; each was refuted by measurement (fault storm 24% of a core, GPU lag
 * 1-2, compressor thrash predated by the spin, buffer retention fixed with no
 * FPS change, lost wakeups 550/550 healthy). DXMT accounts for ~10-12ms and
 * Present is nearly free, so 900-1500ms per frame is unaccounted for.
 *
 * Stop selecting suspects and measure the remainder: sample EVERY thread for a
 * bounded window, resolve JIT PCs to exact guest RIPs natively, and aggregate.
 * Waiting threads are counted separately by wait API so "asleep" is never
 * confused with "busy". */
#define IOS_PROF_BUCKETS 96
#define IOS_PROF_SAMPLES 400

void ios_cpu_profile( const char *why, int ms_total )
{
    struct { char name[40]; uint64_t rip; uint64_t hostpc; unsigned port;
             unsigned running; unsigned waiting; } b[IOS_PROF_BUCKETS];
    unsigned nb = 0, iter, total_run = 0, total_wait = 0, resolved = 0, unresolved = 0;
    const int period_us = 2000;                      /* 500 Hz */
    int iters = ms_total * 1000 / period_us;
    if (iters > IOS_PROF_SAMPLES) iters = IOS_PROF_SAMPLES;
    memset( b, 0, sizeof(b) );

    for (iter = 0; iter < (unsigned)iters; iter++)
    {
        thread_act_array_t th;
        mach_msg_type_number_t cnt = 0, i;
        thread_t self = mach_thread_self();

        if (task_threads( mach_task_self(), &th, &cnt ) != KERN_SUCCESS) break;
        for (i = 0; i < cnt; i++)
        {
            arm_thread_state64_t st;
            mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
            struct thread_basic_info bi;
            mach_msg_type_number_t bc = THREAD_BASIC_INFO_COUNT;
            char tname[40] = "";
            pthread_t pt;
            uint64_t rip = 0, bb = 0;
            unsigned k;

            if (th[i] == self) continue;
            if (thread_get_state( th[i], ARM_THREAD_STATE64, (thread_state_t)&st, &sc ) != KERN_SUCCESS)
                goto next_thread;
            memset( &bi, 0, sizeof(bi) );
            if (thread_info( th[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &bc ) != KERN_SUCCESS)
                goto next_thread;

            pt = pthread_from_mach_thread_np( th[i] );
            if (pt) pthread_getname_np( pt, tname, sizeof(tname) );

            if (st.__x[18] > 0x10000 && !(st.__x[18] & 0xfff))
                ios_guest_modmap_build( st.__x[18] );          /* ml689: once */

            if (bi.run_state != TH_STATE_RUNNING) { total_wait++; }
            else
            {
                mach_vm_size_t g = 0;
                total_run++;
                if (st.__x[28] > 0x10000 &&
                    mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)st.__x[28], 8,
                                            (mach_vm_address_t)&bb, &g ) == KERN_SUCCESS && g == 8 && bb)
                {
                    extern uint64_t ios_native_rip_from_hostpc( uint64_t, uint64_t, const char ** );
                    rip = ios_native_rip_from_hostpc( bb, st.__pc, NULL );
                    if (rip) resolved++; else unresolved++;
                }
            }

            /* bucket by (thread name, guest RIP) so the report names a function,
             * not just a thread */
            /* ml690 PROFILER BUG: the key was (name, rip). Every UNNAMED native
             * thread has name=="" and rip==0, so they all collapsed into ONE
             * bucket -- ml689's "duty 171/400 port=0x103" was an aggregate of
             * several threads wearing the port of whichever created the bucket,
             * not one thread at 43%. Key by MACH PORT, which is unique. */
            for (k = 0; k < nb; k++)
                if (b[k].port == (unsigned)th[i] && b[k].rip == rip) break;
            if (k == nb && nb < IOS_PROF_BUCKETS)
            {
                memcpy( b[nb].name, tname, sizeof(b[nb].name) - 1 );
                b[nb].port = th[i];   /* wine poisons strncpy */
                b[nb].name[sizeof(b[nb].name) - 1] = 0;
                b[nb].rip = rip; b[nb].hostpc = st.__pc; b[nb].port = th[i]; nb++;
            }
            if (k < IOS_PROF_BUCKETS)
            {
                if (bi.run_state == TH_STATE_RUNNING) b[k].running++;
                else b[k].waiting++;
            }
next_thread:
            mach_port_deallocate( mach_task_self(), th[i] );
        }
        vm_deallocate( mach_task_self(), (vm_address_t)th, cnt * sizeof(thread_t) );
        usleep( period_us );
    }

    fprintf(stderr, "[cpu-prof] ml688 why=%s window=%dms iters=%u  running-samples=%u waiting-samples=%u "
                    "| guestRIP resolved=%u unresolved=%u\n",
            why, ms_total, iter, total_run, total_wait, resolved, unresolved);
    {   /* top buckets by RUNNING samples -- where CPU time actually went */
        unsigned rank, shown[16], ns = 0;
        for (rank = 0; rank < 16; rank++)
        {
            unsigned best = ~0u, bestv = 0, k, q; int dup;
            for (k = 0; k < nb; k++)
            {
                for (dup = 0, q = 0; q < ns; q++) if (shown[q] == k) dup = 1;
                if (dup) continue;
                if (b[k].running > bestv) { bestv = b[k].running; best = k; }
            }
            if (best == ~0u || !bestv) break;
            shown[ns++] = best;
            {
                uint64_t rva = 0;
                const char *mod = b[best].rip ? ios_guest_module_for( b[best].rip, &rva ) : NULL;
                /* ml689: percentages are shares of RUNNING SAMPLES. Also print
                 * running/iters, which is the thread's runnable duty over the
                 * window -- the number that converts to "about N cores". */
                fprintf(stderr, "[cpu-prof]   %5.1f%% of running (duty %u/%u) \"%s\" port=0x%x "
                                "guest=%s+0x%llx rip=0x%llx hostPC=0x%llx\n",
                        total_run ? (100.0 * b[best].running / total_run) : 0.0,
                        b[best].running, (unsigned)iter, b[best].name, b[best].port,
                        mod ? mod : "?", (unsigned long long)rva,
                        (unsigned long long)b[best].rip, (unsigned long long)b[best].hostpc);
                if (rank < 3 && b[best].rip)
                {   /* the guest x86 at the hottest sites -- disassemble offline */
                    uint8_t gb[48]; mach_vm_size_t gg = 0;
                    if (mach_vm_read_overwrite( mach_task_self(),
                            (mach_vm_address_t)(b[best].rip & ~0xfULL), sizeof(gb),
                            (mach_vm_address_t)gb, &gg ) == KERN_SUCCESS && gg == sizeof(gb))
                    {
                        char hx[160]; int q;
                        for (q = 0; q < 48; q++) snprintf( hx + q * 3, 4, "%02x ", gb[q] );
                        fprintf(stderr, "[cpu-prof]     x86 @0x%llx: %s\n",
                                (unsigned long long)(b[best].rip & ~0xfULL), hx);
                    }
                }
            }
        }
    }
}

void ios_wait_chain_snapshot( const char *why )
{
    int round;
    for (round = 0; round < 3; round++)
    {
        thread_act_array_t th;
        mach_msg_type_number_t cnt = 0, i;
        thread_t self = mach_thread_self();
        const int delay_ms = (round == 0) ? 0 : (round == 1 ? 100 : 900);

        if (delay_ms) usleep( delay_ms * 1000 );
        if (task_threads( mach_task_self(), &th, &cnt ) != KERN_SUCCESS) return;

        fprintf(stderr, "[wait-chain] ml686 ==== round %d (t=+%dms) why=%s threads=%u ====\n",
                round, round == 0 ? 0 : (round == 1 ? 100 : 1000), why, cnt);

        for (i = 0; i < cnt; i++)
        {
            arm_thread_state64_t st;
            mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
            struct thread_basic_info bi;
            mach_msg_type_number_t bc = THREAD_BASIC_INFO_COUNT;
            char tname[64] = "";
            pthread_t pt;
            Dl_info di;
            const char *img = "?", *sym = NULL;
            uint64_t off = 0;

            if (th[i] == self) continue;
            if (thread_get_state( th[i], ARM_THREAD_STATE64, (thread_state_t)&st, &sc ) != KERN_SUCCESS)
                continue;
            memset( &bi, 0, sizeof(bi) );
            if (thread_info( th[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &bc ) != KERN_SUCCESS)
            { bi.run_state = -1; bi.cpu_usage = -1; }

            pt = pthread_from_mach_thread_np( th[i] );
            if (pt) pthread_getname_np( pt, tname, sizeof(tname) );

            off = st.__pc;
            if (dladdr( (void *)(uintptr_t)st.__pc, &di ))
            {
                if (di.dli_fname) { img = strrchr(di.dli_fname, '/'); img = img ? img + 1 : di.dli_fname; }
                if (di.dli_sname) { sym = di.dli_sname; off = st.__pc - (uint64_t)(uintptr_t)di.dli_saddr; }
            }

            /* Only blocked threads carry a meaningful wait target; a RUNNING
             * thread's x0/x1 are just whatever it is computing. */
            if (bi.run_state == TH_STATE_RUNNING)
            {
                uint64_t bb = 0; mach_vm_size_t g = 0;
                if (st.__x[28] > 0x10000)
                    mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)st.__x[28], 8,
                                            (mach_vm_address_t)&bb, &g );
                fprintf(stderr, "[wait-chain]   RUNNING  \"%s\" cpu=%d pc=%s`%s+0x%llx BlockBegin=0x%llx\n",
                        tname, bi.cpu_usage, img, sym ? sym : "?",
                        (unsigned long long)off, (unsigned long long)bb);
            }
            else
            {
                /* x0..x3 are the wait arguments at the syscall boundary: for
                 * ulock_wait x1 is the address contended, for read x0 is the fd,
                 * for semaphore_wait x0 is the port. Print the object AND a
                 * peek at it, so an owner word is visible where one exists. */
                uint64_t obj = st.__x[1], peek = 0; mach_vm_size_t g = 0;
                int havepeek = (obj > 0x10000 && !(obj & 7) &&
                                mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)obj, 8,
                                                        (mach_vm_address_t)&peek, &g ) == KERN_SUCCESS && g == 8);
                fprintf(stderr, "[wait-chain]   WAIT     \"%s\" cpu=%d run=%d api=%s "
                                "x0=0x%llx obj/x1=0x%llx%s%016llx x2=0x%llx x3=0x%llx pc=%s`%s+0x%llx\n",
                        tname, bi.cpu_usage, bi.run_state, ios_wait_api_name( st.__pc, sym ),
                        (unsigned long long)st.__x[0], (unsigned long long)obj,
                        havepeek ? " val=" : " val=?", (unsigned long long)peek,
                        (unsigned long long)st.__x[2], (unsigned long long)st.__x[3],
                        img, sym ? sym : "?", (unsigned long long)off);
            }
            mach_port_deallocate( mach_task_self(), th[i] );
        }
        vm_deallocate( mach_task_self(), (vm_address_t)th, cnt * sizeof(thread_t) );
    }
}

void ios_dump_all_thread_stacks(void)
{
    thread_act_array_t threads;
    mach_msg_type_number_t count = 0, i;
    thread_t self = mach_thread_self();

    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return;
    fprintf(stderr, "[thread-stacks] ---- %u threads ----\n", count);
    for (i = 0; i < count; i++)
    {
        arm_thread_state64_t st;
        mach_msg_type_number_t st_count = ARM_THREAD_STATE64_COUNT;
        char tname[64] = "";
        pthread_t pt;
        Dl_info di;
        const char *img = "?", *sym = "?";
        uint64_t off, fp_walk;
        int fr;

        if (threads[i] == self) goto next;
        if (thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&st, &st_count) != KERN_SUCCESS)
            goto next;

        pt = pthread_from_mach_thread_np(threads[i]);
        if (pt) pthread_getname_np(pt, tname, sizeof(tname));

        off = st.__pc;
        if (dladdr((void*)(uintptr_t)st.__pc, &di))
        {
            if (di.dli_fname) { img = strrchr(di.dli_fname, '/'); img = img ? img + 1 : di.dli_fname; }
            if (di.dli_sname) { sym = di.dli_sname; off = st.__pc - (uint64_t)(uintptr_t)di.dli_saddr; }
        }
        /* iOS-Madeira ml417 (#68): a pc alone can't tell "blocked in a wait"
         * from "stopped dead" from "spinning in a fault-retry loop".  ml417
         * showed FOUR threads (steam.exe's main among them, mid-DllMain of
         * steamclient64) sampled 37x at __wine_syscall_dispatcher+0xa8 —
         * `ldr x16,[x18,#0x370]`, which BLOCKS ON NOTHING.  run_state +
         * suspend_count separate the three cases outright, and at that exact
         * pc x8 still holds the wine syscall id and x18 the TEB, so the
         * blocked/looping syscall names itself. */
        {
            struct thread_basic_info bi;
            mach_msg_type_number_t bcnt = THREAD_BASIC_INFO_COUNT;
            memset(&bi, 0, sizeof(bi));
            if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &bcnt) != KERN_SUCCESS)
            {
                bi.run_state = -1;
                bi.suspend_count = -1;
            }
            /* Is the TEB word this pc dereferences (syscall table at TEB+0x370)
             * actually readable?  If not, the thread is fault-looping/parked on
             * an unmapped TEB rather than waiting on anything. */
            char tebstate[40] = "";
            if (st.__x[18] > 0x10000 && !(st.__x[18] & 0xfff))
            {
                uint64_t w = 0;
                mach_vm_size_t g = 0;
                /* ml585: also resolve the WINE TID from TEB->ClientId
                 * .UniqueThread (TEB+0x48). Without it every stack is keyed
                 * only by Mach port, and correlating a sample with
                 * [srv-queues]/[srv-stuck] means hunting for an unrelated
                 * line that happens to print both — which is exactly the
                 * detour that cost time on ml584. */
                uint64_t wtid = 0;
                mach_vm_size_t g2 = 0;
                int have_wtid = (mach_vm_read_overwrite(mach_task_self(),
                        (mach_vm_address_t)(st.__x[18] + 0x48), 8,
                        (mach_vm_address_t)&wtid, &g2) == KERN_SUCCESS && g2 == 8);
                if (mach_vm_read_overwrite(mach_task_self(),
                        (mach_vm_address_t)(st.__x[18] + 0x370), 8,
                        (mach_vm_address_t)&w, &g) == KERN_SUCCESS && g == 8)
                    snprintf(tebstate, sizeof(tebstate), " teb=0x%llx wtid=%04llx teb+370=0x%llx",
                             (unsigned long long)st.__x[18],
                             have_wtid ? (unsigned long long)wtid : 0ull,
                             (unsigned long long)w);
                else
                    snprintf(tebstate, sizeof(tebstate), " teb=0x%llx wtid=%04llx teb+370=UNREADABLE",
                             (unsigned long long)st.__x[18],
                             have_wtid ? (unsigned long long)wtid : 0ull);
            }
            fprintf(stderr, "[thread-stacks] port=0x%x \"%s\" pc=%s`%s+0x%llx run=%d susp=%d "
                    "cpu=%d x8=0x%llx x18=0x%llx sp=0x%llx%s\n",
                    threads[i], tname, img, sym, (unsigned long long)off,
                    bi.run_state, bi.suspend_count, bi.cpu_usage,
                    (unsigned long long)st.__x[8], (unsigned long long)st.__x[18],
                    (unsigned long long)arm_thread_state64_get_sp(st), tebstate);

            /* ================= ml677 SPIN SNAPSHOT =========================
             *
             * ml676 sampled "Background Job.Worker 1" 43 times out of 44 at
             * cpu 989-1000 with its pc confined to a 256-byte window
             * (0x133a9c7b4-0x133a9c8b4) and x8 invariant at 0x70340c2ce8 --
             * from cycle 104 (phys 1350MB) right through to cycle 2577
             * (4026MB). It spins the ENTIRE run and starts long before memory
             * gets tight, so memory pressure cannot be the cause. A pc alone
             * cannot say what the loop is; the instructions can.
             *
             * Fires once per thread, only after the SAME 4KB pc window has
             * been seen at high cpu MIN_HITS times, so a merely busy thread
             * never trips it and the cost is paid once.
             *
             * DISCIPLINE (ml613 died on exactly this): do NOT call any
             * ARM64EC PE export from here -- no RIP-reconstruction helper, no
             * FEX entry point. Capture NATIVE facts only, every read through
             * mach_vm_read_overwrite so a bad pointer cannot nest-fault this
             * handler thread. FEX keeps the guest CPU state pointer in x28,
             * so BlockBegin (x28+0) and State.rip (x28+0x18) are plain loads
             * we can validate before trusting. */
            if (bi.cpu_usage >= 900 && bi.run_state == TH_STATE_RUNNING)
            {
                /* ml728: MIN_HITS 4 -> 2. The spinner we are chasing was sampled only
                 * THREE times in a ten-minute run -- always at the same pc and cpu>=993,
                 * but never enough to satisfy a 4-hit threshold, so the snapshot that
                 * exists precisely for this case never fired. It also alternates with
                 * __ulock_wait2, so it is not continuously runnable and consecutive hits
                 * cannot be relied on. Two hits in one 4KB window at cpu>=900 is still
                 * far beyond anything a merely busy thread reaches, and the capture is
                 * one-shot per thread. */
                enum { SPIN_SLOTS = 8, MIN_HITS = 2 };
                static struct { unsigned port; uint64_t page; unsigned hits; unsigned done; } spin[SPIN_SLOTS];
                uint64_t page = st.__pc & ~0xfffull;
                int si, slot = -1, free_slot = -1;
                for (si = 0; si < SPIN_SLOTS; si++)
                {
                    if (spin[si].port == threads[i]) { slot = si; break; }
                    if (!spin[si].port && free_slot < 0) free_slot = si;
                }
                if (slot < 0 && free_slot >= 0)
                {
                    slot = free_slot;
                    spin[slot].port = threads[i];
                    spin[slot].page = page;
                    spin[slot].hits = 0;
                }
                if (slot >= 0)
                {
                    if (spin[slot].page != page) { spin[slot].page = page; spin[slot].hits = 1; }
                    else spin[slot].hits++;

                    if (spin[slot].hits >= MIN_HITS && !spin[slot].done)
                    {
                        uint32_t insn[128];          /* pc-256 .. pc+256 */
                        mach_vm_size_t got = 0;
                        uint64_t lo = st.__pc - 256;
                        int k;
                        spin[slot].done = 1;

                        /* ml686: the spinner is probably the victim. Capture what
                         * EVERY thread is waiting on, at the same moment, so the
                         * producer that should be feeding it is visible too. */
                        {
                            extern void ios_wait_chain_snapshot( const char * );
                            ios_wait_chain_snapshot( "spin-detected" );
                            {
                                extern void ios_cpu_profile( const char *, int );
                                ios_cpu_profile( "spin-detected", 800 );
                            }
                        }

                        fprintf(stderr, "[spin] ml677 THREAD \"%s\" port=0x%x SPINNING cpu=%d "
                                        "pc=0x%llx sp=0x%llx lr=0x%llx fp=0x%llx (hits=%u in one 4KB window)\n",
                                tname, threads[i], bi.cpu_usage,
                                (unsigned long long)st.__pc,
                                (unsigned long long)arm_thread_state64_get_sp(st),
                                (unsigned long long)st.__lr, (unsigned long long)st.__fp,
                                spin[slot].hits);

                        /* every GP register -- x8/x28 matter most, but an
                         * invariant register anywhere names the loop's input */
                        for (k = 0; k < 29; k += 4)
                            fprintf(stderr, "[spin]   x%-2d=0x%016llx x%-2d=0x%016llx x%-2d=0x%016llx x%-2d=0x%016llx\n",
                                    k,   (unsigned long long)st.__x[k],
                                    k+1, (unsigned long long)(k+1 < 29 ? st.__x[k+1] : 0),
                                    k+2, (unsigned long long)(k+2 < 29 ? st.__x[k+2] : 0),
                                    k+3, (unsigned long long)(k+3 < 29 ? st.__x[k+3] : 0));

                        /* FEX guest state via x28 -- validated, never trusted raw */
                        if (st.__x[28] > 0x10000)
                        {
                            uint64_t blockbegin = 0, griprip = 0;
                            mach_vm_size_t g1 = 0, g2 = 0;
                            int ok1 = (mach_vm_read_overwrite(mach_task_self(),
                                        (mach_vm_address_t)st.__x[28], 8,
                                        (mach_vm_address_t)&blockbegin, &g1) == KERN_SUCCESS && g1 == 8);
                            int ok2 = (mach_vm_read_overwrite(mach_task_self(),
                                        (mach_vm_address_t)(st.__x[28] + 0x18), 8,
                                        (mach_vm_address_t)&griprip, &g2) == KERN_SUCCESS && g2 == 8);
                            /* ml684: State.rip is only synced at BLOCK boundaries, so
                             * it names the calling block, not the spinning
                             * instruction -- ml683's value disassembled to the
                             * instruction after a GetTickCount64 call, nowhere near
                             * the captured atomic loop. Reconstruct the EXACT RIP
                             * from (BlockBegin, host PC) through the pointer
                             * xtajit64 pushes down; gate on the RESOLVED FLAG, never
                             * on the pointer (ml551 blacked out the window by calling
                             * it while it still held ASCII), and never link the EC
                             * export directly (ml613). */
                            {
                                /* ml686: ml684/685 printed a single "UNRESOLVED:0x0" for
                                 * every failure mode, so "the callback was never pushed
                                 * down" and "the walk ran and found nothing" looked
                                 * identical -- a probe that cannot distinguish a missing
                                 * mechanism from a real answer. Split every precondition
                                 * and name the one that failed. */
                                /* ml688: NATIVE walk. Never call the EC export
                                 * (ml613/ml614) -- this decodes the same table. */
                                extern uint64_t ios_native_rip_from_hostpc( uint64_t, uint64_t, const char ** );
                                const char *why = "ok";
                                uint64_t exact = ok1 ? ios_native_rip_from_hostpc( blockbegin, st.__pc, &why ) : 0;
                                if (!ok1) why = "CPUState+0 unreadable (no BlockBegin)";
                                fprintf(stderr, "[spin]   EXACT guest RIP=0x%llx why=%s\n"
                                                "[spin]     BlockBegin=0x%llx hostPC=0x%llx delta=+0x%llx "
                                                "State.rip=0x%llx (block-granular) resolved=%d cb=%p\n",
                                        (unsigned long long)exact, why,
                                        (unsigned long long)blockbegin, (unsigned long long)st.__pc,
                                        (unsigned long long)(st.__pc - blockbegin),
                                        (unsigned long long)griprip, 0, (void *)0);
                                {   /* the JIT block header itself -- extent/entry live here */
                                    uint64_t bh[6]; mach_vm_size_t bg = 0;
                                    if (blockbegin && mach_vm_read_overwrite(mach_task_self(),
                                            (mach_vm_address_t)blockbegin, sizeof(bh),
                                            (mach_vm_address_t)bh, &bg) == KERN_SUCCESS && bg == sizeof(bh))
                                        fprintf(stderr, "[spin]     block hdr: %016llx %016llx %016llx %016llx %016llx %016llx\n",
                                                (unsigned long long)bh[0], (unsigned long long)bh[1],
                                                (unsigned long long)bh[2], (unsigned long long)bh[3],
                                                (unsigned long long)bh[4], (unsigned long long)bh[5]);
                                }
                                if (exact)
                                {   /* the guest bytes at the real RIP name the loop */
                                    uint8_t gb[32];
                                    mach_vm_size_t gg = 0;
                                    if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)exact,
                                            sizeof(gb), (mach_vm_address_t)gb, &gg) == KERN_SUCCESS &&
                                        gg == sizeof(gb))
                                    {
                                        char hex[100]; int q;
                                        for (q = 0; q < 32; q++)
                                            snprintf(hex + q * 3, 4, "%02x ", gb[q]);
                                        fprintf(stderr, "[spin]   guest bytes @0x%llx: %s\n",
                                                (unsigned long long)exact, hex);
                                    }
                                }
                            }
                            fprintf(stderr, "[spin]   x28=0x%llx BlockBegin=%s0x%llx State.rip=%s0x%llx\n",
                                    (unsigned long long)st.__x[28],
                                    ok1 ? "" : "UNREADABLE:", (unsigned long long)blockbegin,
                                    ok2 ? "" : "UNREADABLE:", (unsigned long long)griprip);
                            /* ml678: dump the ThreadState head rather than guess where
                             * the guest register file starts. RSP/RBP/the caller chain
                             * are all in here; decoding is free offline, and a wrong
                             * layout guess made on-device costs a whole run. */
                            {
                                uint64_t ts[64];
                                mach_vm_size_t g3 = 0;
                                if (mach_vm_read_overwrite(mach_task_self(),
                                        (mach_vm_address_t)st.__x[28], sizeof(ts),
                                        (mach_vm_address_t)ts, &g3) == KERN_SUCCESS && g3 == sizeof(ts))
                                {
                                    int q;
                                    for (q = 0; q < 64; q += 4)
                                        fprintf(stderr, "[spin]   TS+0x%03x: %016llx %016llx %016llx %016llx\n",
                                                q * 8,
                                                (unsigned long long)ts[q],   (unsigned long long)ts[q+1],
                                                (unsigned long long)ts[q+2], (unsigned long long)ts[q+3]);

                                    /* ======= ml729 [mono-state] NAME THE FATAL TRANSITION =======
                                     *
                                     * Two threads spin forever at libmono+0x2bf5d0 (`eb fe`)
                                     * immediately after Mono logs
                                     *   "Cannot transition thread %p from %s with DONE_BLOCKING"
                                     * Offline disassembly of the call site settles the ABI:
                                     *   1802bf5af  lea  r8, [rip+0xee975]   ; the format string
                                     *   1802bf5b8  mov  edx, 4              ; level
                                     *   1802bf5bd  call monoeg_g_log
                                     * so %p == r9 (thread info) and %s == [rsp+0x20] (the SOURCE
                                     * state name). Naming that state says whether the thread was
                                     * already BLOCKING, in a self-suspend, or in a state our
                                     * suspend machinery invented -- which is the difference
                                     * between a Mono bug and an emulation bug.
                                     *
                                     * WHICH RSP? gregs[REG_RSP] is only SPILLED at block
                                     * boundaries (same limitation that made State.rip name the
                                     * wrong instruction in ml684), while x23 is the SRA RSP and
                                     * is only meaningful where SRA is actually loaded. Neither
                                     * can be trusted blind, so dump BOTH, labelled. The
                                     * disassembly gives a free validator: whichever candidate
                                     * has a printable C string at +0x20 is the live one. */
                                    {
                                        uint64_t cands[2] = { ts[8], st.__x[23] };   /* gregs[4]=RSP, SRA RSP */
                                        const char *cname[2] = { "gregs[RSP]", "x23(SRA)" };
                                        int ci;

                                        fprintf(stderr, "[mono-state] guest args: rcx=0x%llx rdx=0x%llx "
                                                        "r8=0x%llx r9=0x%llx  (rip=0x%llx)\n",
                                                (unsigned long long)ts[5],  (unsigned long long)ts[6],
                                                (unsigned long long)ts[12], (unsigned long long)ts[13],
                                                (unsigned long long)ts[3]);

                                        for (ci = 0; ci < 2; ci++)
                                        {
                                            uint64_t rsp = cands[ci], sv[16];
                                            mach_vm_size_t g4 = 0;
                                            int w;
                                            if (rsp < 0x10000 || (rsp & 7))
                                            {
                                                fprintf(stderr, "[mono-state] %s=0x%llx -- implausible, skipped\n",
                                                        cname[ci], (unsigned long long)rsp);
                                                continue;
                                            }
                                            if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)rsp,
                                                    sizeof(sv), (mach_vm_address_t)sv, &g4) != KERN_SUCCESS ||
                                                g4 != sizeof(sv))
                                            {
                                                fprintf(stderr, "[mono-state] %s=0x%llx -- UNREADABLE\n",
                                                        cname[ci], (unsigned long long)rsp);
                                                continue;
                                            }
                                            for (w = 0; w < 16; w++)
                                            {
                                                char txt[65];
                                                int printable = 0;
                                                /* resolve the slot as a C string when it can be one --
                                                 * this is what names the state, and it is also the
                                                 * validator that says which RSP candidate was live */
                                                if (sv[w] > 0x10000)
                                                {
                                                    mach_vm_size_t g5 = 0;
                                                    if (mach_vm_read_overwrite(mach_task_self(),
                                                            (mach_vm_address_t)sv[w], 64,
                                                            (mach_vm_address_t)txt, &g5) == KERN_SUCCESS && g5 == 64)
                                                    {
                                                        int t;
                                                        txt[64] = 0;
                                                        for (t = 0; t < 64; t++)
                                                        {
                                                            if (txt[t] == 0) break;
                                                            if (txt[t] < 0x20 || txt[t] > 0x7e) { t = -1; break; }
                                                        }
                                                        /* demand a real terminated string of >=3 chars,
                                                         * so random pointer bytes do not read as text */
                                                        if (t >= 3) { txt[t] = 0; printable = 1; }
                                                    }
                                                }
                                                fprintf(stderr, "[mono-state] %s+0x%02x = %016llx%s%s%s\n",
                                                        cname[ci], w * 8, (unsigned long long)sv[w],
                                                        printable ? "  \"" : "",
                                                        printable ? txt : "",
                                                        printable ? "\"" : "");
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        else
                            fprintf(stderr, "[spin]   x28=0x%llx -- not a plausible CPU-state pointer\n",
                                    (unsigned long long)st.__x[28]);

                        /* ============ ml681 IS THE LOOP MAKING PROGRESS? =====
                         *
                         * ml677 showed six registers all holding one address
                         * (0x70330c40f8-family). Whether that word CHANGES is
                         * the difference between "contended lock, someone is
                         * winning" and "nobody owns it and this thread will
                         * spin forever". Sample it twice with a gap and diff.
                         * Also dump the 64 bytes around it -- a lock word's
                         * neighbours usually name the object. */
                        {
                            uint64_t cand[4] = { st.__x[8], st.__x[1], st.__x[2], st.__x[27] };
                            for (int c = 0; c < 4; c++)
                            {
                                uint64_t a = cand[c], v0 = 0, v1 = 0;
                                mach_vm_size_t g = 0;
                                if (a < 0x10000 || (a & 7)) continue;
                                if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)a,
                                        8, (mach_vm_address_t)&v0, &g) != KERN_SUCCESS || g != 8)
                                    continue;
                                /* ml686: sample densely over a full frame period and
                                 * report a BOUNDED SUMMARY. 50ms was too short to cover
                                 * a ~1s frame, and one line per sample would drown the
                                 * log; a value that changes and returns to the same
                                 * self-pointer would also read as "unchanged" if only
                                 * the endpoints were compared. Count transitions. */
                                {
                                    uint64_t prev = v0, distinct = 1, changes = 0, seen[4];
                                    int k, ns = 1;
                                    seen[0] = v0;
                                    for (k = 0; k < 120; k++)   /* 120 x 10ms = 1.2s */
                                    {
                                        uint64_t vn = 0;
                                        usleep(10000);
                                        if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)a,
                                                8, (mach_vm_address_t)&vn, &g) != KERN_SUCCESS || g != 8)
                                            break;
                                        if (vn != prev) { changes++; prev = vn; }
                                        {
                                            int dup = 0, q;
                                            for (q = 0; q < ns; q++) if (seen[q] == vn) dup = 1;
                                            if (!dup && ns < 4) { seen[ns++] = vn; distinct++; }
                                        }
                                        v1 = vn;
                                    }
                                    fprintf(stderr, "[spin]   watch addr=0x%llx over 1.2s: samples=120 "
                                                    "transitions=%llu distinct=%llu first=%016llx last=%016llx %s\n",
                                            (unsigned long long)a, (unsigned long long)changes,
                                            (unsigned long long)distinct,
                                            (unsigned long long)v0, (unsigned long long)v1,
                                            changes ? "CHANGES -- queue does turn over"
                                                    : "NEVER CHANGES across a full frame period");
                                }
                                {
                                    uint64_t nb[8];
                                    mach_vm_size_t g2 = 0;
                                    uint64_t base = a & ~63ull;
                                    if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)base,
                                            sizeof(nb), (mach_vm_address_t)nb, &g2) == KERN_SUCCESS &&
                                        g2 == sizeof(nb))
                                        fprintf(stderr, "[spin]     0x%llx: %016llx %016llx %016llx %016llx "
                                                        "%016llx %016llx %016llx %016llx\n",
                                                (unsigned long long)base,
                                                (unsigned long long)nb[0], (unsigned long long)nb[1],
                                                (unsigned long long)nb[2], (unsigned long long)nb[3],
                                                (unsigned long long)nb[4], (unsigned long long)nb[5],
                                                (unsigned long long)nb[6], (unsigned long long)nb[7]);
                                }
                                break;   /* one candidate is enough */
                            }
                        }

                        /* ============ ml690 IS THE TREE CYCLIC? ==============
                         *
                         * The guest x86 at UnityPlayer+0x112ef.. is an ordered
                         * walk that also REWIRES links (stores into [r10]/[r8]/
                         * [rbx+8]) -- a deletion/rebalance, which must terminate.
                         * One worker living there for whole runs, with the
                         * watched word self-referential, is equally consistent
                         * with a CYCLIC tree as with heavy work, and those have
                         * opposite fixes: a cycle means our stores corrupted the
                         * structure, and making the loop faster would do nothing.
                         *
                         * Walk the child pointer at +0x08 from every plausible
                         * guest pointer in the host registers (the SRA mapping is
                         * not something to guess at) and report the first repeat.
                         * Bounded to 64 hops, all reads fault-safe. */
                        {
                            int ci;
                            for (ci = 0; ci < 29; ci++)
                            {
                                uint64_t root = st.__x[ci], seen[64];
                                int hops = 0, cyc = -1;
                                if (root < 0x7000000000ULL || root >= 0x7400000000ULL || (root & 7))
                                    continue;                     /* guest heap only */
                                for (hops = 0; hops < 64; hops++)
                                {
                                    uint64_t nxt = 0; mach_vm_size_t g2 = 0; int q;
                                    seen[hops] = root;
                                    if (mach_vm_read_overwrite(mach_task_self(),
                                            (mach_vm_address_t)(root + 8), 8,
                                            (mach_vm_address_t)&nxt, &g2) != KERN_SUCCESS || g2 != 8)
                                        break;
                                    if (!nxt || nxt < 0x7000000000ULL || nxt >= 0x7400000000ULL) break;
                                    for (q = 0; q <= hops; q++)
                                        if (seen[q] == nxt) { cyc = q; break; }
                                    if (cyc >= 0) break;
                                    root = nxt;
                                }
                                if (cyc >= 0)
                                    fprintf(stderr, "[tree] ml690 CYCLE from x%d: node 0x%llx repeats at hop %d "
                                                    "(walked %d) -- structure is circular\n",
                                            ci, (unsigned long long)seen[cyc], cyc, hops);
                                else if (hops >= 8)
                                    fprintf(stderr, "[tree] ml690 x%d chain depth %d, terminated cleanly "
                                                    "(no cycle in %d hops)\n", ci, hops, hops);
                            }
                        }

                        /* the loop body itself: 512 bytes centred on pc */
                        if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)lo,
                                                   sizeof(insn), (mach_vm_address_t)insn,
                                                   &got) == KERN_SUCCESS && got == sizeof(insn))
                        {
                            for (k = 0; k < 128; k += 8)
                            {
                                fprintf(stderr, "[spin]   %c0x%llx: %08x %08x %08x %08x %08x %08x %08x %08x\n",
                                        (lo + k*4 <= st.__pc && st.__pc < lo + k*4 + 32) ? '>' : ' ',
                                        (unsigned long long)(lo + (uint64_t)k*4),
                                        insn[k], insn[k+1], insn[k+2], insn[k+3],
                                        insn[k+4], insn[k+5], insn[k+6], insn[k+7]);
                            }
                        }
                        else
                            fprintf(stderr, "[spin]   instruction window at 0x%llx UNREADABLE\n",
                                    (unsigned long long)lo);
                    }
                }
            }
        }
        {
            extern uint64_t ios_jit_reverse_translate( uint64_t addr, uint64_t *module_base );
            uint64_t mod = 0, pe_va = ios_jit_reverse_translate(st.__pc, &mod);
            if (pe_va)
                fprintf(stderr, "[thread-stacks]   pc is PE code: %.32s+0x%llx (base=0x%llx va=0x%llx)\n",
                        ios_pe_module_name(mod), (unsigned long long)(pe_va - mod),
                        (unsigned long long)mod, (unsigned long long)pe_va);
        }

        fp_walk = st.__fp;
        for (fr = 0; fr < 14 && fp_walk; fr++)
        {
            uint64_t frame_buf[2];
            mach_vm_size_t got_fw = 0;
            uint64_t ret_pc;

            if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)fp_walk, 16,
                                       (mach_vm_address_t)frame_buf, &got_fw) != KERN_SUCCESS || got_fw != 16)
                break;
            ret_pc = frame_buf[1] & 0x0000007fffffffffull;   /* strip PAC bits */
            if (ret_pc <= 0x4000) break;
            img = "?"; sym = "?"; off = ret_pc;
            if (dladdr((void*)(uintptr_t)ret_pc, &di))
            {
                if (di.dli_fname) { img = strrchr(di.dli_fname, '/'); img = img ? img + 1 : di.dli_fname; }
                if (di.dli_sname) { sym = di.dli_sname; off = ret_pc - (uint64_t)(uintptr_t)di.dli_saddr; }
            }
            {
                extern uint64_t ios_jit_reverse_translate( uint64_t addr, uint64_t *module_base );
                uint64_t mod = 0, pe_va = ios_jit_reverse_translate(ret_pc, &mod);
                if (pe_va)
                    fprintf(stderr, "[thread-stacks]   bt[%d] PE %.32s+0x%llx (va=0x%llx)\n",
                            fr, ios_pe_module_name(mod), (unsigned long long)(pe_va - mod),
                            (unsigned long long)pe_va);
                else
                    fprintf(stderr, "[thread-stacks]   bt[%d] %s`%s+0x%llx\n", fr, img, sym, (unsigned long long)off);
            }
            fp_walk = frame_buf[0];
        }
next:
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(*threads));
    mach_port_deallocate(mach_task_self(), self);
    fflush(stderr);
}
