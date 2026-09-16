/*
 * Win32 virtual memory functions
 *
 * Copyright 1997, 2002, 2020 Alexandre Julliard
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

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <signal.h>
#include <time.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <limits.h>
#include <pthread.h>
#include <sys/ioctl.h>
#ifdef WINE_IOS
/* Minimal Mach API decls to avoid <mach/mach.h>'s host_page_size symbol
 * clash with our static var of the same name. */
typedef int kern_return_t;
typedef unsigned int mach_port_t;
typedef unsigned long vm_address_t;
typedef unsigned long vm_size_t;
typedef int vm_prot_t;
extern mach_port_t mach_task_self_;
#define mach_task_self() mach_task_self_
#define KERN_SUCCESS 0
#define VM_PROT_READ  ((vm_prot_t) 0x01)
#define VM_PROT_WRITE ((vm_prot_t) 0x02)
#define VM_PROT_COPY  ((vm_prot_t) 0x10)
extern kern_return_t vm_protect(mach_port_t target_task, vm_address_t address,
                                vm_size_t size, int set_maximum,
                                vm_prot_t new_protection);
#endif
#ifdef HAVE_SYS_SYSINFO_H
# include <sys/sysinfo.h>
#endif
#ifdef HAVE_SYS_SYSCALL_H
# include <sys/syscall.h>
#endif
#ifdef HAVE_SYS_SYSCTL_H
# include <sys/sysctl.h>
#endif
#ifdef HAVE_SYS_PARAM_H
# include <sys/param.h>
#endif
#ifdef HAVE_SYS_QUEUE_H
# include <sys/queue.h>
#endif
#ifdef HAVE_SYS_USER_H
# include <sys/user.h>
#endif
#ifdef HAVE_LIBPROCSTAT_H
# include <libprocstat.h>
#endif
#include <unistd.h>
#include <dlfcn.h>
#ifdef WINE_IOS
#include <libkern/OSCacheControl.h>
#endif
#ifdef HAVE_VALGRIND_VALGRIND_H
# include <valgrind/valgrind.h>
#endif
#if defined(__APPLE__)
#define host_page_size mac_host_page_size
# include <mach/mach_init.h>
# include <mach/mach_vm.h>
# include <mach/task.h>
# include <mach/thread_state.h>
# include <mach/vm_map.h>
#undef host_page_size
#endif

#if defined(HAVE_LINUX_USERFAULTFD_H) && defined(HAVE_LINUX_FS_H)
# include <linux/userfaultfd.h>
# include <linux/fs.h>
#if defined(UFFD_FEATURE_WP_ASYNC) && defined(PM_SCAN_WP_MATCHING)
#define USE_UFFD_WRITEWATCH
#endif
#endif

#include "ntstatus.h"
#include "windef.h"
#include "winnt.h"
#include "winternl.h"
#include "ddk/wdm.h"
#include "wine/list.h"
#include "wine/rbtree.h"
#include "unix_private.h"
#include "wine/debug.h"

/* ml648: the Mono-bridge alias table is defined further down, but the anon-alias
 * teardown paths ABOVE it must retire entries too — an unmapped alias left live
 * would resolve a stale guest_rx to memory that no longer backs it. Declared here
 * so those earlier call sites do not create an implicit declaration. */
#include <stdint.h>
void ios_mono_alias_publish( uint64_t guest_rx, uint64_t host_rw, uint64_t size );
void ios_mono_alias_retire( uint64_t guest_rx );


WINE_DEFAULT_DEBUG_CHANNEL(virtual);
WINE_DECLARE_DEBUG_CHANNEL(module);
WINE_DECLARE_DEBUG_CHANNEL(virtual_ranges);

#ifdef WINE_IOS
/* JIT pool address translation table.
 * Maps PE code section addresses → JIT pool RX addresses.
 * Used by signal_arm64_ios.c to redirect entry points.
 * Bumped from 16 → 64 to fit games with many DLLs (Thumper loads 22+ unique
 * images; cube ~12-15). Silent overflow at 16 was costing us hours of
 * debugging — late modules' addresses fell through ios_jit_translate_addr
 * unchanged, leaking unix-mapped (non-executable) addresses to BLR. */
/* 512: desktop mode holds the session's full aarch64 image set PLUS every
 * pseudo-process child's x64/EC set in one table. 64 overflowed at exactly
 * the 65th image (Thumper under desktop, 2026-07-06): concrt140 copied but
 * never registered → raw-VA DllMain call → unfixable exec-fault loop. */
#define IOS_JIT_MAX_MAPPINGS 512
struct ios_jit_mapping {
    void *pe_base;      /* Original PE image base address (unix mapping) */
    void *jit_base;     /* JIT pool RX address */
    size_t size;        /* Size of the mapping */
    size_t text_offset; /* Offset of .text section within image */
    size_t text_size;   /* Size of .text section (0 if unknown) */
    uint64_t pe_image_base; /* PE optional header ImageBase */
    intptr_t reloc_delta;   /* JIT dest - PE ImageBase */
    unsigned int reloc_rva; /* RVA of .reloc section */
    unsigned int reloc_size;/* Size of .reloc data */
    void *owner_peb;    /* NULL = parent/default copy; else the PEB of the
                         * pseudo-process that owns this copy (S1 child
                         * processes get their own ntdll image so module
                         * lists / loader locks don't collide). Multiple
                         * entries may share one pe_base; translation picks
                         * the entry owned by the current thread's process,
                         * falling back to the NULL-owner (parent) entry. */
    unsigned short machine_cached;  /* ml349: PE machine word, read fault-safely once */
    unsigned char  machine_valid;   /* 0 = machine_cached not yet populated */
};
static struct ios_jit_mapping ios_jit_mappings[IOS_JIT_MAX_MAPPINGS];
static int ios_jit_mapping_count = 0;

/* JIT pool head bump allocator. Owned by mprotect_exec's PE-image copy path
 * (was a function-local static there); file-scope so the S1 per-child
 * ntdll copy allocates from the same cursor instead of guessing pool usage.
 * The pool TAIL is carved separately by NtAllocateVirtualMemoryEx for FEX
 * EC_CODE buffers. Static: internal linkage, no wineserver-style symbol
 * collision risk. */
static size_t jit_pool_offset = 0;

/* ---- Pool reclamation (task #25) ----------------------------------------
 * The bump allocator never freed anything: 8 pseudo-processes consumed
 * 368.9/384MB (2026-07-07) and the 9th BUS-loop-locked the session. Every
 * head allocation is now recorded in a ledger tagged with the allocating
 * pseudo-process (ios_jit_current_peb() — module loads run on the owning
 * process's thread, same invariant the owner-aware IAT-sync relies on).
 * process_exit_wrapper releases the dead process's ranges into a free list
 * the allocator consults before bumping.
 *
 * Reuse is gated by a grace period: laggard threads of the dead process
 * (woken by their closing server fds) still run PE exit paths from the
 * process's pool copies for a moment after process_exit_wrapper. Freed
 * bytes stay intact until actually rehanded out, so execution from a
 * freed-but-unreused range stays valid during the grace window. */
static pthread_mutex_t ios_pool_lock = PTHREAD_MUTEX_INITIALIZER;

#define IOS_POOL_LEDGER_MAX 1024
struct ios_pool_alloc
{
    size_t off;         /* pool offset */
    size_t size;        /* bytes (page-aligned) */
    void  *peb;         /* allocating pseudo-process; NULL = session/unknown */
};
static struct ios_pool_alloc ios_pool_ledger[IOS_POOL_LEDGER_MAX];
static int ios_pool_ledger_count;

#define IOS_POOL_FREE_MAX 256
#define IOS_POOL_REUSE_GRACE_SEC 3
/* Darwin madvise: MADV_FREE marks pages volatile; MADV_FREE_REUSE is the
 * documented cancel. Guard for older SDK headers. */
#ifndef MADV_FREE_REUSE
#define MADV_FREE_REUSE 8
#endif
struct ios_pool_free
{
    size_t off;
    size_t size;
    time_t freed_at;
    int    advised;   /* physical pages returned via MADV_FREE (post-grace) */
};
static struct ios_pool_free ios_pool_freelist[IOS_POOL_FREE_MAX];
static int ios_pool_free_count;

/* ml224: describe a faulting address against the JIT-pool ledger.
 *
 * Steam/CEF dies on a 128-bit atomic whose target VirtualQuery reports as MEM_FREE:
 *   [caspal128] addr=0x1526120e0 misalign=0 region base=0x152612000 size=0x2fee000
 *               prot=0x1 type=MEM_PRIVATE state=0x10000   (0x10000 = MEM_FREE)
 * so the instruction and its alignment were never the problem -- the POINTER is dangling.
 * The address sits inside the pool's span yet is unmapped, which points at pool lifetime
 * rather than guest logic. Three candidates need different fixes, and only the ledger can
 * tell them apart:
 *   - it lands in a freelist entry  => reclamation released memory still referenced
 *   - it lands in a live mapping    => the mapping exists; the fault is something else
 *   - it lands in neither           => a hole; the guest pointer is simply stale/garbage
 * Reports all three plus the pool geometry, so "none of the above" is a real answer.
 * Caller supplies the buffer; no allocation, safe from a fault handler. */
void ios_jit_describe_pool_addr( const void *addr, char *buf, size_t buflen )
{
    /* these are defined further down this file; declare locally so the describer can sit
     * next to the freelist it reports on rather than being pushed below its data */
    extern void *ios_jit_rw_base_global;
    extern void *ios_jit_rx_base_global;
    extern size_t ios_jit_pool_size_global;
    extern const char *ios_pe_module_name( const void *image_base, size_t image_size );

    uintptr_t a = (uintptr_t)addr;
    uintptr_t rw = (uintptr_t)ios_jit_rw_base_global;
    uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
    size_t ps = ios_jit_pool_size_global;
    uintptr_t base = 0;
    const char *which = NULL;
    size_t off;
    int i;

    if (!buf || !buflen) return;
    buf[0] = 0;
    if (!ps) { snprintf( buf, buflen, "pool not initialised" ); return; }

    if (rw && a >= rw && a < rw + ps)      { base = rw; which = "RW"; }
    else if (rx && a >= rx && a < rx + ps) { base = rx; which = "RX"; }
    else { snprintf( buf, buflen, "OUTSIDE pool (rw=%p rx=%p size=0x%lx)",
                     (void *)rw, (void *)rx, (unsigned long)ps ); return; }

    off = a - base;

    for (i = 0; i < ios_pool_free_count; i++)
    {
        if (off >= ios_pool_freelist[i].off &&
            off < ios_pool_freelist[i].off + ios_pool_freelist[i].size)
        {
            snprintf( buf, buflen,
                      "%s pool off=0x%lx -> FREELIST[%d] off=0x%lx size=0x%lx advised=%d"
                      "  <== RECLAIMED MEMORY STILL REFERENCED",
                      which, (unsigned long)off, i,
                      (unsigned long)ios_pool_freelist[i].off,
                      (unsigned long)ios_pool_freelist[i].size,
                      ios_pool_freelist[i].advised );
            return;
        }
    }

    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        uintptr_t jb = (uintptr_t)ios_jit_mappings[i].jit_base;
        size_t sz = ios_jit_mappings[i].size;

        if (jb && sz && a >= jb && a < jb + sz)
        {
            snprintf( buf, buflen,
                      "%s pool off=0x%lx -> LIVE mapping[%d] %s pe=%p jit=%p+0x%lx owner=%p",
                      which, (unsigned long)off, i,
                      ios_pe_module_name( ios_jit_mappings[i].pe_base, sz ),
                      ios_jit_mappings[i].pe_base, (void *)jb, (unsigned long)sz,
                      ios_jit_mappings[i].owner_peb );
            return;
        }
    }

    snprintf( buf, buflen, "%s pool off=0x%lx -> HOLE (no freelist entry, no live mapping;"
                           " %d mappings, %d freelist)", which, (unsigned long)off,
              ios_jit_mapping_count, ios_pool_free_count );
}
/* task #34: 1 if the most recent ios_pool_alloc_range served from the freelist,
 * 0 if it came off the virgin bump. Read immediately after the call by the
 * copy-verify probe so a failed copy can be attributed to reuse or not. */
static int ios_pool_last_alloc_reused;

/* Defined next to decommit_pages; declared here so the allocator can check a
 * range against the LIVE ledger before handing it out (task #34 double-handout
 * detector). */
static int ios_pool_live_overlap( uintptr_t rw_start, size_t size,
                                  size_t *off_out, void **peb_out );

void *ios_jit_current_peb(void);
extern void *ios_jit_rw_base_global;  /* defined below */
extern void *ios_jit_rx_base_global;  /* defined below */

/* ml90 (task #35): walk the Mach map and report every free gap >= 1GB, so we
 * size the jumbo-reserve problem against real numbers instead of guesses.
 * CEF asks for ~144GB (4x PartitionAlloc 16GB pools + a 32GB region) and only
 * two land; this says exactly what is left and where. Gaps inside the GPU
 * carveout [64G,448G) are flagged — they are reported free by the map but are
 * CPU-walled (maxprot=0), so they can never satisfy a reserve. */
/* task #34 POOL WARMER — the compressor countermeasure (ml104 finding).
 *
 * The faulting pool page's content is BYTE-IDENTICAL to the on-disk DLL
 * (libarm64ecfex RVA 0xd0820, verified against FEX/build-arm64ec/Bin —
 * the "zeros" in earlier fault dumps were inter-function padding present in
 * the file, misread as corruption). So content is never destroyed; only
 * EXECUTABILITY is lost, deterministically on a COLD page (copied via the RW
 * alias, not yet executed), only under CEF memory pressure. That is the
 * signature of the compressor: a cold dirty anon page is compressed, the
 * first exec touch decompresses it into a FRESH physical page, and TXM's
 * exec blessing does not survive the frame replacement. It also explains the
 * reuse correlation as a time confound: late copies land on freelist ranges
 * AND under peak pressure.
 *
 * Countermeasure: touch every used pool page every ~2s so none ever reaches
 * the inactive queue. ~40k pages at 650MB = a few ms per cycle. Reads via the
 * RW alias keep the shared physical page active for the RX view too. This is
 * both the experiment (faults vanish => theory confirmed) and the mitigation. */
static volatile size_t ios_jit_tail_reserved;   /* defined below (tail EC_CODE carve) */
extern size_t ios_jit_pool_size_global;         /* defined below */
/* task #35 THE MEASUREMENT THAT DECIDES THE WHOLE PLAN.
 *
 * Everything else about the furniture ceiling is instrumentation of a means to
 * an end; this reports the END directly. CEF needs three 16GB-ALIGNED
 * PartitionAlloc pools, and PA's own slot walk tries these three addresses. So
 * the only question that matters is whether they are still free by the time PA
 * asks. The ml119 noise (111 relaxed placements, hundreds of Wine views) is
 * irrelevant if the answer stays "all three CLEAR" -- and if a slot is dirty,
 * this names the exact first occupant instead of leaving us to infer it from a
 * pool count. Called periodically, so we see WHEN a slot goes bad, not just
 * that it did. */
static void ios_bigres_report( const char *why );   /* defined below */

static void ios_slot_probe( const char *why )
{
    /* ml149: probe 0x7000000000 too — it is a genuine 16GB-ALIGNED candidate and
     * the ONLY route to a fourth pool. The GPU carveout [64G,448G) ends at
     * exactly 0x7000000000, and ios_usable_va_floor is 0x7038000000 (ml423), so only
     * the first 896MB of that slot is blocked. If that occupant is ours (or movable)
     * a fourth slot exists and the wall disappears without touching Chromium —
     * whose kPoolMaxSize is compile-time and not ours to change. Report what is
     * actually in there rather than assuming it is the xzone. */
    static const mach_vm_address_t slots[4] = { 0x7000000000ULL, 0x7400000000ULL,
                                                0x7800000000ULL, 0x7C00000000ULL };
    const mach_vm_size_t SLOT = 0x400000000ULL;   /* 16GB */
    int i;

    for (i = 0; i < 4; i++)
    {
        mach_vm_address_t lo = slots[i], hi = slots[i] + SLOT, addr = lo;
        mach_vm_size_t occupied = 0;
        mach_vm_address_t first_occ = 0;
        mach_vm_size_t first_sz = 0;
        int regions = 0;

        while (addr < hi)
        {
            mach_vm_size_t size = 0;
            vm_region_basic_info_data_64_t info;
            mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
            mach_port_t obj = MACH_PORT_NULL;
            mach_vm_address_t q = addr;

            if (mach_vm_region( mach_task_self(), &q, &size, VM_REGION_BASIC_INFO_64,
                                (vm_region_info_t)&info, &cnt, &obj ) != KERN_SUCCESS)
                break;
            if (q >= hi) break;                    /* nothing left inside the slot */
            if (q + size > hi) size = hi - q;
            if (!first_occ) { first_occ = q; first_sz = size; }
            occupied += size;
            regions++;
            addr = q + size;
        }
        if (occupied)
        {
            dprintf(2, "[slot#%d] 0x%llx+16GB DIRTY regions=%d occupied=%llu MB first=0x%llx+0x%llx (%s)\n",
                    i, (unsigned long long)lo, regions, (unsigned long long)(occupied >> 20),
                    (unsigned long long)first_occ, (unsigned long long)first_sz, why);
            /* ml149: for the 448G slot, enumerate the blockers with their
             * protections — that is what decides whether they are ours to move. */
            if (lo == 0x7000000000ULL)
            {
                mach_vm_address_t a2 = lo;
                int shown = 0;
                while (a2 < hi && shown < 8)
                {
                    mach_vm_size_t sz2 = 0;
                    vm_region_basic_info_data_64_t inf2;
                    mach_msg_type_number_t c2 = VM_REGION_BASIC_INFO_COUNT_64;
                    mach_port_t o2 = MACH_PORT_NULL;
                    mach_vm_address_t q2 = a2;
                    if (mach_vm_region( mach_task_self(), &q2, &sz2, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&inf2, &c2, &o2 ) != KERN_SUCCESS) break;
                    if (q2 >= hi) break;
                    dprintf(2, "[slot#0]   blocker 0x%llx+0x%llx (%llu MB) prot=%x/%x shared=%d\n",
                            (unsigned long long)q2, (unsigned long long)sz2,
                            (unsigned long long)(sz2 >> 20), inf2.protection,
                            inf2.max_protection, inf2.shared);
                    shown++;
                    a2 = q2 + sz2;
                }
            }
        }
        else
            dprintf(2, "[slot#%d] 0x%llx+16GB CLEAR (%s)\n",
                    i, (unsigned long long)lo, why);
    }
}

/* task #35 THE LAST UNKNOWN: what is actually IN the furniture window?
 *
 * ml120 proved the window's 15.1GB is fully consumed, which is what makes three
 * pools impossible (48 + 17 > 63). But "consumed" does not distinguish genuine
 * demand from waste, and that distinction decides whether 3 pools are reachable
 * at all: if this is ~480 arenas of 32MB that nobody frees, reclaiming them
 * unlocks the third slot; if it is thread stacks and images, 2 pools is the
 * hard ceiling and CEF has to run on two. The 2GB that poisoned slot#0 was 64
 * regions of ~32MB, so a size histogram should be conclusive. Bucket by size
 * class, then name the biggest tenants. */
static void ios_window_inventory( const char *why, unsigned long long lo_arg, unsigned long long hi_arg )
{
    static const char *names[6] = { "<=64K", "<=1M", "<=8M", "<=64M", "<=512M", ">512M" };
    mach_vm_address_t addr = (mach_vm_address_t)lo_arg;
    const mach_vm_address_t hi = (mach_vm_address_t)hi_arg;
    mach_vm_size_t bytes[6] = { 0 }, big_sz[8] = { 0 };
    unsigned counts[6] = { 0 };
    mach_vm_address_t big_at[8] = { 0 };
    int big_pr[8] = { 0 };
    mach_vm_size_t total = 0;
    unsigned regions = 0;
    /* ml123: the 130 x 128MB regions are NOT one-per-thread (31 threads, 130
     * regions) and they come in CONTIGUOUS runs, so they are almost certainly
     * one large mapping each that mach reports split into 128MB map entries.
     * Individual entries therefore tell us nothing; coalesce adjacent entries
     * into RUNS and report the largest runs, plus Darwin's user_tag, which
     * names the allocator directly instead of leaving us to infer it. */
    mach_vm_address_t run_at = 0;
    mach_vm_size_t run_sz = 0;
    int run_tag = -1, run_pr = 0;
    mach_vm_size_t tagb[8] = { 0 };
    int tagid[8];
    int i, j, ntag = 0;
    /* ml366: free-hole accounting. Image loads need CONTIGUOUS space in this
     * window (map_image_view's limit_high is non-relaxable), so the number
     * that predicts a c0000017 DLL-load failure is the LARGEST FREE HOLE,
     * which nothing measured before. mach_vm_region skips holes, so the gap
     * between the previous region's end and the next region's start is free. */
    mach_vm_size_t free_total = 0, free_max = 0;
    mach_vm_address_t free_max_at = 0;

    for (i = 0; i < 8; i++) tagid[i] = -1;

    while (addr < hi)
    {
        mach_vm_size_t size = 0;
        vm_region_extended_info_data_t einfo;
        mach_msg_type_number_t cnt = VM_REGION_EXTENDED_INFO_COUNT;
        mach_port_t obj = MACH_PORT_NULL;
        mach_vm_address_t q = addr;
        int tag, prot;

        if (mach_vm_region( mach_task_self(), &q, &size, VM_REGION_EXTENDED_INFO,
                            (vm_region_info_t)&einfo, &cnt, &obj ) != KERN_SUCCESS)
            break;
        if (q > addr)   /* hole between previous region end and this one */
        {
            mach_vm_size_t gap = ((q < hi) ? q : hi) - addr;
            free_total += gap;
            if (gap > free_max) { free_max = gap; free_max_at = addr; }
        }
        if (q >= hi) break;
        if (q + size > hi) size = hi - q;
        tag = einfo.user_tag;
        prot = einfo.protection;

        i = size <= 0x10000 ? 0 : size <= 0x100000 ? 1 : size <= 0x800000 ? 2
          : size <= 0x4000000 ? 3 : size <= 0x20000000 ? 4 : 5;
        counts[i]++;
        bytes[i] += size;
        total += size;
        regions++;

        /* bytes-by-tag histogram (first 8 distinct tags seen) */
        for (j = 0; j < ntag; j++) if (tagid[j] == tag) break;
        if (j == ntag && ntag < 8) { tagid[ntag] = tag; ntag++; }
        if (j < 8) tagb[j] += size;

        /* coalesce into runs of same tag+prot */
        if (run_sz && q == run_at + run_sz && tag == run_tag && prot == run_pr)
            run_sz += size;
        else
        {
            if (run_sz)
                for (j = 0; j < 8; j++)
                    if (run_sz > big_sz[j])
                    {
                        int k;
                        for (k = 7; k > j; k--)
                        {
                            big_sz[k] = big_sz[k-1]; big_at[k] = big_at[k-1]; big_pr[k] = big_pr[k-1];
                        }
                        big_sz[j] = run_sz; big_at[j] = run_at;
                        big_pr[j] = (run_pr << 8) | (run_tag & 0xff);
                        break;
                    }
            run_at = q; run_sz = size; run_tag = tag; run_pr = prot;
        }
        addr = q + size;
        /* ml366: the old 4000-region backstop TRUNCATED the census — ml365
         * reported "occupied 12198 of 15232 MB" over exactly 4001 regions
         * while the window was in fact fuller; every occupancy number since
         * the window fragmented past 4000 regions was an undercount. Keep a
         * runaway backstop only. */
        if (regions > 100000) { dprintf(2, "[window] TRUNCATED at %u regions\n", regions); break; }
    }
    if (addr < hi)   /* tail hole after the last region */
    {
        mach_vm_size_t gap = hi - addr;
        free_total += gap;
        if (gap > free_max) { free_max = gap; free_max_at = addr; }
    }
    if (run_sz)
        for (j = 0; j < 8; j++)
            if (run_sz > big_sz[j])
            {
                int k;
                for (k = 7; k > j; k--)
                {
                    big_sz[k] = big_sz[k-1]; big_at[k] = big_at[k-1]; big_pr[k] = big_pr[k-1];
                }
                big_sz[j] = run_sz; big_at[j] = run_at;
                big_pr[j] = (run_pr << 8) | (run_tag & 0xff);
                break;
            }

    dprintf(2, "[window] 0x%llx..0x%llx regions=%u occupied=%llu MB of %llu MB "
            "free=%llu MB maxhole=%llu MB@0x%llx rev=ml366 (%s)\n",
            lo_arg, hi_arg, regions, (unsigned long long)(total >> 20),
            (unsigned long long)((hi_arg - lo_arg) >> 20),
            (unsigned long long)(free_total >> 20),
            (unsigned long long)(free_max >> 20),
            (unsigned long long)free_max_at, why);
    for (i = 0; i < 6; i++)
        if (counts[i])
            dprintf(2, "[window]   %-7s n=%-5u %llu MB\n",
                    names[i], counts[i], (unsigned long long)(bytes[i] >> 20));
    for (i = 0; i < 8 && big_sz[i]; i++)
        dprintf(2, "[window]   run#%d 0x%llx +0x%llx (%llu MB) prot=%x tag=%d\n",
                i, (unsigned long long)big_at[i], (unsigned long long)big_sz[i],
                (unsigned long long)(big_sz[i] >> 20), big_pr[i] >> 8, big_pr[i] & 0xff);
    for (i = 0; i < ntag; i++)
        dprintf(2, "[window]   tag%-4d %llu MB\n", tagid[i], (unsigned long long)(tagb[i] >> 20));
}

/* ml668: published by the footprint sampler below and read by its own cadence
 * logic; defined further down alongside ios_jit_pool_size_global. */
extern unsigned long long ios_last_footprint_mb;
extern int ios_fast_footprint;

static void *ios_pool_warmer_thread( void *arg )
{
    unsigned cycle = 0;
    for (;;)
    {
        volatile const char *rw = (volatile const char *)ios_jit_rw_base_global;
        /* ml121: warm the RX ALIAS TOO. The warmer only ever touched the RW
         * alias, but execution faults on the RX one -- they are two separate
         * mach mappings of the same object, so residency established through RW
         * need not hold for RX. ml121 died exactly this way: [exec-recover]
         * pg=0x1243d8000 lost execute while the warmer was running, mprotect_rx
         * failed EACCES (as it ALWAYS does on blessed pool memory -- never
         * evidence), and the unrecoverable fault killed the CEF child. Reading
         * through an RX mapping is permitted and is the only touch that can
         * establish residency for the alias that actually executes. */
        volatile const char *rx = (volatile const char *)ios_jit_rx_base_global;
        size_t total = ios_jit_pool_size_global;
        if (rw && total)
        {
            size_t head = jit_pool_offset;               /* snapshot; only grows */
            size_t tail = ios_jit_tail_reserved;
            size_t o, touched = 0;
            volatile char sink = 0;
            if (head > total) head = total;
            if (tail > total) tail = total;
            for (o = 0; o < head; o += 0x4000) { sink += rw[o]; touched++; }
            for (o = total - tail; o < total; o += 0x4000) { sink += rw[o]; touched++; }
            if (rx)
            {
                for (o = 0; o < head; o += 0x4000) { sink += rx[o]; touched++; }
                for (o = total - tail; o < total; o += 0x4000) { sink += rx[o]; touched++; }
            }
            (void)sink;
            cycle++;
            if (cycle == 1 || (cycle % 30) == 0)
                dprintf(2, "[pool-warmer] cycle=%u touched=%lu pages (head=0x%lx tail=0x%lx)\n",
                        cycle, (unsigned long)touched, (unsigned long)head, (unsigned long)tail);
            /* task #35: report the three pool slots every ~30s on this existing
             * timer — see ios_slot_probe. Cheap (a few mach queries) and it is
             * the only signal that says whether the ceiling is doing its job. */
            /* ml136 CATCH THE REPLACEMENT WHEN IT HAPPENS, not at the exec fault.
             *
             * ml134 proved a live pool RX page had max_prot=0x3 when a healthy
             * one is 0x7 — max_protection only drops via a fresh mapping, so
             * something REPLACED it. Both Wine paths are now instrumented and
             * report zero ([jit-tripwire] fixed maps, [jit-clobber] kernel
             * picks), so the culprit is outside Wine's allocator and we cannot
             * catch it at the call. Instead sweep the used pool for pages that
             * have lost EXECUTE from max_prot. The warmer already walks exactly
             * this memory every 2s, so the sweep is nearly free, and it turns a
             * rare fatal symptom into an early located observation: we learn
             * WHICH range died and WHEN, and can correlate against whatever the
             * log shows happening in that window. */
            /* ml137 SWEEP ONLY .text — the first cut sampled the pool at 4MB
             * stride and flagged 9-11 pages per pass, but mapping those offsets
             * back to modules showed every one landed deep inside a copy
             * (shell32 +0x604000 of 0xbf0000, steamui +0x10c8000 of 0x123e000,
             * libavutil +0x288000/+0x688000) — .data/.rsrc/.reloc, which are
             * LEGITIMATELY RW in a pool copy. All false positives. The genuine
             * ml134 corruption was at libarm64ecfex+0xd06d0, i.e. in .text.
             * ios_jit_mappings already records text_offset/text_size per module,
             * so walk exactly those ranges: any .text page whose max_prot has
             * lost EXECUTE is real corruption, with no benign explanation. */
            if ((cycle % 5) == 0 && rx)
            {
                unsigned mi;
                size_t bad = 0, checked = 0;
                for (mi = 0; mi < ios_jit_mapping_count; mi++)
                {
                    uintptr_t jb = (uintptr_t)ios_jit_mappings[mi].jit_base;
                    size_t t_off = ios_jit_mappings[mi].text_offset;
                    size_t t_sz  = ios_jit_mappings[mi].text_size;
                    size_t o;

                    if (!jb || !t_sz) continue;
                    for (o = 0; o < t_sz; o += 0x40000)   /* 256KB stride inside .text */
                    {
                        mach_vm_address_t want = (mach_vm_address_t)(jb + t_off + o), a = want;
                        mach_vm_size_t rsz = 0;
                        vm_region_basic_info_data_64_t inf;
                        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
                        mach_port_t obj = MACH_PORT_NULL;

                        if (mach_vm_region( mach_task_self(), &a, &rsz, VM_REGION_BASIC_INFO_64,
                                            (vm_region_info_t)&inf, &cnt, &obj ) != KERN_SUCCESS)
                            break;
                        if (a > want) continue;                  /* hole */
                        checked++;
                        if (!(inf.max_protection & VM_PROT_EXECUTE) && bad++ < 8)
                            dprintf(2, "[pool-rot] TEXT LOST EXEC va=0x%llx mod_pool=0x%llx"
                                       " text+0x%lx prot=%x max=%x region=0x%llx+0x%llx cycle=%u\n",
                                    (unsigned long long)want, (unsigned long long)jb,
                                    (unsigned long)o, inf.protection, inf.max_protection,
                                    (unsigned long long)a, (unsigned long long)rsz, cycle);
                    }
                }
                if (bad)
                    dprintf(2, "[pool-rot] %lu of %lu sampled .text pages LOST EXEC (cycle=%u)\n",
                            (unsigned long)bad, (unsigned long)checked, cycle);
                else if (cycle % 15 == 0)
                    dprintf(2, "[pool-rot] clean: %lu .text pages sampled across %u mappings (cycle=%u)\n",
                            (unsigned long)checked, ios_jit_mapping_count, cycle);
            }
            if (cycle == 1 || (cycle % 15) == 0)
            {
                /* ml469 (wall #79): one-shot proof of whether TCP loopback
                 * works at all under this port — the webhelper's transport
                 * ws://localhost dial loop never completes and steam.exe's own
                 * connectivity test says NoLAN, but nothing on record shows a
                 * loopback connect succeeding here.  Raw BSD sockets, below
                 * wine, so a failure indicts the platform layer directly. */
                if (cycle == 1)
                {
                    extern void ios_loopback_selftest(void);
                    ios_loopback_selftest();
                }
                ios_slot_probe( "periodic" );
                /* ml121 probe-design fix: the inventory was wired ONLY to the
                 * jumbo-failure sites, and ml121 died before any jumbo call, so
                 * the one measurement that decides whether a 3rd pool is
                 * reachable never fired. Put it on the periodic timer too. */
                ios_window_inventory( "periodic", 0x7048000000ULL, 0x7400000000ULL );
                ios_bigres_report( "periodic" );
            }
            /* ml358 FOOTPRINT (every cycle, one line): phys_footprint is the
             * EXACT number jetsam kills on — everything else in this file
             * measures address space, which is not what got us killed (ml357:
             * "Terminated due to memory issue" with pools at 0% committed).
             * The breakdown discriminates who is spending: `internal` = our
             * dirty anonymous pages (JIT pool copies, guest heap), `compressed`
             * = what the compressor already absorbed, `phys_footprint` = the
             * ledger total. Peak is tracked so a pull after death still shows
             * how close the run got. */
            /* ml398 (task #60): sample the beacon-marked chrome_ipc pump
             * thread's Mach state each cycle — see ios_pump_sample() in
             * signal_arm64_ios.c. */
            {
                extern void ios_pump_sample(void);
                ios_pump_sample();
            }
            {
                task_vm_info_data_t vmi;
                mach_msg_type_number_t vmi_cnt = TASK_VM_INFO_COUNT;
                if (task_info( mach_task_self(), TASK_VM_INFO,
                               (task_info_t)&vmi, &vmi_cnt ) == KERN_SUCCESS)
                {
                    static unsigned long long peak_mb;
                    unsigned long long fp_mb = (unsigned long long)vmi.phys_footprint >> 20;
                    if (fp_mb > peak_mb) peak_mb = fp_mb;
                    ios_last_footprint_mb = fp_mb;      /* ml668: drives the sampler cadence */
                    dprintf(2, "[footprint] rev=ml358 phys=%llu MB (peak %llu) internal=%llu MB "
                            "compressed=%llu MB external=%llu MB reusable=%llu MB (cycle=%u)\n",
                            fp_mb, peak_mb,
                            (unsigned long long)vmi.internal >> 20,
                            (unsigned long long)vmi.compressed >> 20,
                            (unsigned long long)vmi.external >> 20,
                            (unsigned long long)vmi.reusable >> 20, cycle);
                }
            }
            /* ml566: WHEN does the host malloc zone become corrupt?
             *
             * ml565 settled the mechanism: at the fatal trap the process had
             * 868 MB of headroom and a 1 MB mach_vm_allocate SUCCEEDED, so the
             * libsystem_malloc BRK is NOT out-of-memory — the zone is genuinely
             * corrupt. wineserver's alloc_object is merely the next caller to
             * walk a damaged free list; it is the victim, not the culprit.
             *
             * Knowing WHO corrupts it starts with knowing WHEN. malloc_zone_check
             * walks and validates every zone, so the first cycle it fails brackets
             * the damage to a 2-second window that can be read straight off the
             * surrounding log. Note this whole app is ONE process: the zone is
             * shared by our Swift/ObjC code, wine, wineserver, FEX, DXMT and any
             * wild guest write, so the bracket is the only cheap way in.
             *
             * Self-calibrating: the first PASS is logged too, with its cost in ms.
             * Without that, silence would be ambiguous between "heap healthy" and
             * "probe never ran". If the cost turns out to be large we will see it
             * immediately and can back the interval off. */
            {
                extern int malloc_zone_check( void *zone );
                static int zone_bad, zone_announced;
                if (!zone_bad)
                {
                    struct timeval t0, t1;
                    int ok;
                    gettimeofday( &t0, NULL );
                    ok = malloc_zone_check( NULL );
                    gettimeofday( &t1, NULL );
                    {
                        long ms = (t1.tv_sec - t0.tv_sec) * 1000
                                + (t1.tv_usec - t0.tv_usec) / 1000;
                        if (!ok)
                        {
                            zone_bad = 1;
                            dprintf(2, "[zone-check] *** HOST MALLOC ZONE FIRST FAILED AT cycle=%u "
                                       "(%ld ms) — corruption happened within the last ~2s; read the "
                                       "log immediately above this line rev=ml566\n", cycle, ms);
                        }
                        else if (!zone_announced)
                        {
                            zone_announced = 1;
                            dprintf(2, "[zone-check] armed and PASSING at cycle=%u (%ld ms per check) "
                                       "rev=ml566\n", cycle, ms);
                        }
                    }
                }
            }

            /* ml359 WHERE does the footprint live? ml359 died at the kernel's
             * 4096MB high watermark (EXC_RESOURCE MEMORY/HWM) with internal at
             * 3043MB, and the totals above cannot attribute that to the pool
             * vs FEX lookup caches vs CEF heap. Walk the address space and
             * charge private-dirty+swapped pages to each region; the base
             * addresses identify the owner offline (pool = RX base, FEX bands,
             * PA pools, guest heap). Every 5th cycle plus cycle 2, because the
             * walk is tens of thousands of kernel calls. */
            if (cycle == 2 || (cycle % 5) == 0)
            {
                struct { unsigned long long base, size, dirty, res, swap; unsigned tag; } top[12];
                unsigned long long dirty_by_tag[256];
                /* ml677: DIRTY IS NOT RESIDENCY. The top[12] rows carry res/swap
                 * but they are only the twelve dirtiest regions of the sweep, so
                 * summing THOSE and comparing against the full dirty_by_tag[]
                 * aggregate mixes a sample with a census -- which is exactly how
                 * I concluded "tag 100 is 1380MB of pinned GPU memory" when the
                 * true residency was never measured. Aggregate all three per tag,
                 * over EVERY region, so the comparison is like-for-like. */
                unsigned long long res_by_tag[256], swap_by_tag[256];
                /* ml360 BAND TOTALS: ml360's walk showed the top-12 misses most
                 * of the spend (2154MB tag-0 spread over 116k regions) and the
                 * JIT pool showed up NOWHERE despite ~460MB written — either
                 * its dirty pages are charged oddly or the region is shredded
                 * into thousands of entries. Aggregate dirty AND resident per
                 * address band so attribution can't hide in fragmentation.
                 * Pool bands must be tested FIRST: the RW alias (0x7000000000)
                 * sits numerically inside the guest range. */
                enum { B_POOL_RX, B_POOL_RW, B_HOST_LOW, B_GUEST, B_PA, B_FEX, B_OTHER, B_MAX };
                static const char *band_name[B_MAX] =
                    { "poolRX", "poolRW", "hostlow", "guest", "pa", "fex", "other" };
                unsigned long long band_dirty[B_MAX], band_res[B_MAX];
                uintptr_t prx = (uintptr_t)ios_jit_rx_base_global;
                uintptr_t prw = (uintptr_t)ios_jit_rw_base_global;
                size_t pps = ios_jit_pool_size_global;
                mach_vm_address_t raddr = 0;
                mach_vm_size_t rsize = 0;
                natural_t rdepth = 0;
                unsigned regions = 0, ti, tj;
                unsigned long long total_dirty = 0;
                memset( top, 0, sizeof(top) );
                memset( dirty_by_tag, 0, sizeof(dirty_by_tag) );
                memset( res_by_tag, 0, sizeof(res_by_tag) );
                memset( swap_by_tag, 0, sizeof(swap_by_tag) );
                memset( band_dirty, 0, sizeof(band_dirty) );
                memset( band_res, 0, sizeof(band_res) );
                for (;;)
                {
                    vm_region_submap_info_data_64_t info;
                    mach_msg_type_number_t icnt = VM_REGION_SUBMAP_INFO_COUNT_64;
                    unsigned long long d;
                    if (mach_vm_region_recurse( mach_task_self(), &raddr, &rsize, &rdepth,
                                                (vm_region_recurse_info_t)&info, &icnt ) != KERN_SUCCESS)
                        break;
                    if (info.is_submap) { rdepth++; continue; }
                    d = ((unsigned long long)info.pages_dirtied +
                         (unsigned long long)info.pages_swapped_out) << 14;
                    {
                        int b;
                        if (prx && raddr >= prx && raddr < prx + pps)      b = B_POOL_RX;
                        else if (prw && raddr >= prw && raddr < prw + pps) b = B_POOL_RW;
                        else if (raddr < 0x1000000000ULL)                  b = B_HOST_LOW;
                        else if (raddr >= 0x7000000000ULL && raddr < 0x7400000000ULL) b = B_GUEST;
                        else if (raddr >= 0x7400000000ULL && raddr < 0x7c00000000ULL) b = B_PA;
                        else if (raddr >= 0x7c00000000ULL && raddr < 0x8000000000ULL) b = B_FEX;
                        else b = B_OTHER;
                        band_dirty[b] += d;
                        band_res[b] += (unsigned long long)info.pages_resident << 14;
                    }
                    if (info.user_tag < 256)
                    {
                        res_by_tag[info.user_tag]  += (unsigned long long)info.pages_resident << 14;
                        swap_by_tag[info.user_tag] += (unsigned long long)info.pages_swapped_out << 14;
                    }
                    /* ml569: does the HOST MALLOC HEAP overlap memory we reserved?
                     *
                     * ml565-568 established the malloc BRK is real corruption, not OOM
                     * (830-950 MB free, vm_allocate succeeds at the trap), and that the
                     * trapping CALLER varies — sometimes alloc_object, sometimes wholly
                     * inside libsystem_malloc — so whoever allocates next is just the
                     * unlucky one, not the culprit. What does correlate, perfectly across
                     * 14 runs, is FOOTPRINT: traps at 3145-3339 MB, never at 3015-3114.
                     *
                     * A wild write to a roughly fixed address explains that: inert while
                     * the malloc heap is too small to reach it, fatal once the heap grows
                     * over it. The cheapest version of that story is that WE map on top of
                     * libmalloc's heap. The log already shows the converse happening
                     * ([pool-va] ... INSIDE RX pool <== foreign map/unmap), so the address
                     * spaces demonstrably interleave.
                     *
                     * Darwin tags malloc's own regions, so overlap is directly checkable.
                     * Prints the first few offenders AND a per-cycle count, so "no overlap"
                     * is a real negative rather than silence. */
                    {
                        unsigned t = info.user_tag;
                        int is_malloc = (t == 1 || t == 2 || t == 3 || t == 4 ||
                                         t == 6 || t == 7 || t == 8 || t == 9 || t == 11);
                        const char *bn = NULL;
                        if (prx && raddr >= prx && raddr < prx + pps)      bn = "JIT-POOL-RX";
                        else if (prw && raddr >= prw && raddr < prw + pps) bn = "JIT-POOL-RW";
                        else if (raddr < 0x1000000000ULL)                  bn = NULL; /* normal host */
                        else if (raddr >= 0x7000000000ULL && raddr < 0x7400000000ULL) bn = "GUEST";
                        else if (raddr >= 0x7400000000ULL && raddr < 0x7c00000000ULL) bn = "CEF-PA-POOL";
                        else if (raddr >= 0x7c00000000ULL && raddr < 0x8000000000ULL) bn = "FEX-HOST";
                        if (is_malloc && bn)
                        {
                            static unsigned long ovl;
                            if (++ovl <= 12)
                                dprintf(2, "[heap-overlap] MALLOC region 0x%llx+0x%llx tag=%u sits in "
                                           "the %s band — we and libmalloc share this VA rev=ml569\n",
                                        (unsigned long long)raddr, (unsigned long long)rsize, t, bn);
                        }
                    }
                    if (d)
                    {
                        total_dirty += d;
                        if (info.user_tag < 256) dirty_by_tag[info.user_tag] += d;
                        /* keep the 12 dirtiest regions (replace current min) */
                        for (ti = 0, tj = 0; ti < 12; ti++)
                            if (top[ti].dirty < top[tj].dirty) tj = ti;
                        if (d > top[tj].dirty)
                        {
                            top[tj].base = raddr; top[tj].size = rsize; top[tj].dirty = d;
                            top[tj].res = (unsigned long long)info.pages_resident << 14;
                            top[tj].swap = (unsigned long long)info.pages_swapped_out << 14;
                            top[tj].tag = info.user_tag;
                        }
                    }
                    raddr += rsize;
                    if (++regions > 200000) { dprintf(2, "[phys-map] TRUNCATED at %u regions\n", regions); break; }
                }
                dprintf(2, "[phys-map] rev=ml359 cycle=%u regions=%u total_dirty=%llu MB\n",
                        cycle, regions, total_dirty >> 20);
                for (ti = 0; ti < 12; ti++)
                {
                    if (!top[ti].dirty) continue;
                    dprintf(2, "[phys-map]   0x%llx+0x%llx dirty=%llu MB res=%llu MB swap=%llu MB tag=%u\n",
                            top[ti].base, top[ti].size, top[ti].dirty >> 20,
                            top[ti].res >> 20, top[ti].swap >> 20, top[ti].tag);
                }
                for (ti = 0; ti < 256; ti++)
                    if ((dirty_by_tag[ti] >> 20) >= 32 || (res_by_tag[ti] >> 20) >= 32 ||
                        (swap_by_tag[ti] >> 20) >= 32)
                        dprintf(2, "[phys-map]   tag %u totals rev=ml677 dirty=%llu MB res=%llu MB swap=%llu MB\n",
                                ti, dirty_by_tag[ti] >> 20, res_by_tag[ti] >> 20, swap_by_tag[ti] >> 20);
                dprintf(2, "[phys-map] bands rev=ml360 (dirty/res MB):");
                for (ti = 0; ti < B_MAX; ti++)
                    dprintf(2, " %s=%llu/%llu", band_name[ti],
                            band_dirty[ti] >> 20, band_res[ti] >> 20);
                dprintf(2, "\n");
            }
        }
        /* ml668: ADAPTIVE CADENCE. At a flat 2s the run kept ending BETWEEN
         * samples during texture upload, so every "peak" we quoted was a stale
         * lower bound -- ml664 reported 2733MB when loading was still climbing.
         * Once the footprint is within ~1.2GB of the 4096MB jetsam limit, drop
         * to 250ms so the terminal burst is actually captured. The expensive
         * region/band accounting above stays on the slow cycle; only the cheap
         * task_info() footprint line runs at the fast rate. */
        {
            extern unsigned long long ios_last_footprint_mb;
            extern int ios_fast_footprint;
            usleep( (ios_fast_footprint || ios_last_footprint_mb >= 2400) ? 250000 : 2000000 );
        }
    }
    return NULL;
}

/* task #34: WAS THE POOL COPY EVER CORRECT?
 *
 * Every diagnosis so far assumed the copy succeeded and something destroyed it
 * afterwards — four hypotheses, none confirmed. The untested alternative is
 * that stores into the pool are silently dropped, so a REUSED range simply
 * keeps whatever it held before (stale bytes, or zeros once the previous owner
 * was swept). That would explain the reuse correlation directly, and it fits
 * what the faults actually show: zeros in the instruction stream and the nls
 * poison 0xdead1 still intact at offsets the copy should have overwritten.
 *
 * Read back through the RX alias immediately after the memcpy and compare
 * against the source. Sampled (64 points) rather than a full compare, because
 * this runs for every module copy of every pseudo-process. A mismatch here
 * means the write path is at fault; a clean result means the content is
 * destroyed later and the writer is still at large. */
static void ios_jit_verify_copy( const char *src, const char *rx, size_t size,
                                 const char *name, size_t offset, int reused )
{
    const int SAMPLES = 64;
    size_t step = size / SAMPLES;
    size_t i, first_bad = 0;
    int bad = 0, zero = 0, checked = 0;

    if (!src || !rx || size < 8) return;
    if (step < 8) step = 8;

    for (i = 0; i + 8 <= size; i += step)
    {
        uint64_t a, b;
        memcpy( &a, src + i, 8 );
        memcpy( &b, rx  + i, 8 );
        checked++;
        if (a != b)
        {
            if (!bad) first_bad = i;
            bad++;
            if (!b) zero++;
        }
    }
    if (bad)
        dprintf(2, "[copy-verify] MISMATCH %s pool_off=0x%lx size=0x%lx: %d/%d samples differ (%d read ZERO), first +0x%lx — THE COPY DID NOT STICK [%s]\n",
                name ? name : "?", (unsigned long)offset, (unsigned long)size,
                bad, checked, zero, (unsigned long)first_bad,
                reused ? "REUSED range" : "virgin bump");
}

/* task #35 demand census — see NtAllocateVirtualMemory. One line per jumbo
 * reserve, carrying enough context to tell a retry from a new reservation. */
static unsigned          ios_jumbo_seq;
static unsigned long long ios_jumbo_last_ms;
static size_t            ios_jumbo_granted;      /* bytes actually handed out */
static unsigned          ios_jumbo_ok, ios_jumbo_fail;

static unsigned long long ios_now_ms( void )
{
    struct timespec ts;
    clock_gettime( CLOCK_MONOTONIC, &ts );
    return (unsigned long long)ts.tv_sec * 1000ull + (unsigned long long)(ts.tv_nsec / 1000000);
}


/* ml144 POOL ATTRIBUTION — which GUEST module is asking?
 *
 * CEF requests FOUR 16GB pools but PartitionAddressSpace::Init() reserves only
 * ONE plain (Regular) + ONE guarded (BRP). Two of each means Init() runs twice,
 * and ml144 ruled out the easy explanations: exactly one libcef.dll copy, one
 * chrome_elf.dll copy, and all eight reserves on the SAME peb and wtid. What is
 * left is that libcef.dll and chrome_elf.dll each statically link PartitionAlloc
 * and each initialise it on the loading thread — in real Chrome chrome_elf
 * exports the allocator and the main module defers to it, and that linkage may
 * not survive our loader.
 *
 * The caller is guest x86-64 running under FEX, so a native stack scan finds
 * thunks and IAT slots, not the requester (that mistake cost a run earlier).
 * Read FEX's live guest RIP instead — TEB+0x1788 -> CPUArea+0x30 -> state,
 * RIP at +0x18, the same chain the fault handler uses for [x86_live]. Print it
 * raw; resolving it against the [jit-pool] image table offline is exact and
 * needs no struct-layout assumptions here. */
static uint64_t ios_guest_rip_now(void)
{
    TEB *teb = NtCurrentTeb();
    void *cpuarea, *st;

    if (!teb) return 0;
    cpuarea = *(void **)((char *)teb + 0x1788);
    if ((uintptr_t)cpuarea < 0x10000) return 0;
    st = *(void **)((char *)cpuarea + 0x30);
    if ((uintptr_t)st < 0x10000) return 0;
    return ((uint64_t *)st)[0x18 / 8];
}

/* ml145: the above returns the NATIVE caller at a syscall boundary — every
 * reserve reported the same value and it resolved to kernelbase.dll+0x40124,
 * i.e. inside VirtualAlloc itself. State.RIP is only the guest RIP when the
 * fault happened inside JIT'd guest code; on an EC transition the guest context
 * is saved instead. init_thread_stack's own log gives the layout:
 *   ChpeV2CpuAreaInfo=0x15c410000 ... ContextAmd64=0x15c410050
 * so the x64 CONTEXT sits at CPUArea+0x50, and CONTEXT_AMD64.Rip is at +0xF8.
 * Read that for the actual guest RIP, and keep the native one too — the pair
 * tells us both WHO called and from WHERE. */
static uint64_t ios_guest_ctx_rip(void)
{
    TEB *teb = NtCurrentTeb();
    void *cpuarea;

    if (!teb) return 0;
    cpuarea = *(void **)((char *)teb + 0x1788);
    if ((uintptr_t)cpuarea < 0x10000) return 0;
    return *(uint64_t *)((char *)cpuarea + 0x50 + 0xF8);
}


/* ml147 POOL OWNERSHIP BY SEARCH — the unambiguous attribution.
 *
 * Two register-based attempts both returned NATIVE addresses rather than the
 * guest RIP (State.RIP gave kernelbase+0x40124, the caller inside VirtualAlloc;
 * CPUArea+0x50+0xF8 gave kernelbase+0x7c050). Interesting but not decisive.
 *
 * PartitionAlloc stores each granted pool base in its OWN globals, so if two PA
 * instances exist their pool bases live in two DIFFERENT modules' .data. Search
 * the module copies for the addresses we actually handed out: whichever module
 * holds them owns that pool. No register layout, no guest/native ambiguity.
 * Runs once, only when a jumbo reserve fails, and skips .text (a pool base can
 * only be stored in data). */
const char *ios_pe_module_name( const void *image_base, size_t image_size );

static void ios_pool_owner_search( const uint64_t *wanted, unsigned nwanted )
{
    /* ml148: the first cut matched 823 times across every module, because the
     * pool bases are "small int followed by zeros" — an 8-byte read at PE
     * offset 0x38 of a header whose e_lfanew is 0x78 IS 0x7800000000. Every
     * module hit at +0x38 for exactly that reason.
     *
     * Require a CLUSTER instead: two DIFFERENT pool values within 512 bytes.
     * PartitionAddressSpace keeps regular_pool_base_address_ and
     * brp_pool_base_address_ adjacent in one struct, so a real owner shows both;
     * a PE header cannot fake two distinct pool-shaped values side by side.
     * Also skip the first page (headers) outright. */
    unsigned mi, w;

    for (mi = 0; mi < ios_jit_mapping_count; mi++)
    {
        uintptr_t jb = (uintptr_t)ios_jit_mappings[mi].jit_base;
        size_t sz = ios_jit_mappings[mi].size;
        size_t t0 = ios_jit_mappings[mi].text_offset, t1 = t0 + ios_jit_mappings[mi].text_size;
        const uint64_t *p = (const uint64_t *)jb;
        size_t off, last_off = 0;
        uint64_t last_val = 0;
        int reported = 0;

        if (!jb || !sz || !ios_jit_mappings[mi].pe_base) continue;
        for (off = 0x1000; off + 8 <= sz && reported < 4; off += 8)
        {
            uint64_t v;
            if (ios_jit_mappings[mi].text_size && off >= t0 && off < t1) continue;
            v = p[off / 8];
            for (w = 0; w < nwanted; w++)
                if (v == wanted[w])
                {
                    if (last_val && v != last_val && off - last_off <= 512)
                    {
                        dprintf(2, "[pool-owner] CLUSTER in %s: 0x%llx at +0x%lx and 0x%llx at +0x%lx\n",
                                ios_pe_module_name( ios_jit_mappings[mi].pe_base,
                                                    ios_jit_mappings[mi].size ),
                                (unsigned long long)last_val, (unsigned long)last_off,
                                (unsigned long long)v, (unsigned long)off);
                        reported++;
                    }
                    last_val = v; last_off = off;
                    break;
                }
        }
    }
}


/* ml151 LAZY POOL RESERVATION (Tier 2, first cut).
 *
 * MEASURED: at the moment PartitionAlloc needs all four 16GB pools reserved, it
 * has committed essentially NOTHING — [bigres-use] showed 0MB in two pools and
 * <1MB in the third across 24 calls. The reservation at Init() is pure
 * address-space bookkeeping, so a pool does not need to be backed to be
 * accepted; it only needs the aligned base PA asked for.
 *
 * That matters because the arithmetic is otherwise unwinnable: four pools want
 * 64GB of RANGE, the usable window is ~64GB, and furniture needs ~14GB of it.
 * Treating a reservation as if it consumed real space is what made this look
 * impossible.
 *
 * FIRST CUT, deliberately minimal: when every real placement for a jumbo
 * reserve fails, hand PA a 16GB-aligned slot that no pool has taken and record
 * the range as SOFT — no backing. Commits land in NtAllocateVirtualMemory,
 * which we own, so there is no fault handling: materialise the sub-range there.
 *
 * KNOWN RISK, accepted for now and instrumented rather than hidden: the only
 * free aligned slot (0x7000000000) spans the furniture window, so a later PA
 * commit can land where furniture already lives. We do NOT fence furniture out
 * of it — that window is the only place furniture can go. Instead every commit
 * into a soft range is checked against the kernel map first and a collision is
 * reported loudly. PA bumps upward from a pool base and committed ~0% at Init,
 * so the margin should be large; if [soft-pool] COLLISION appears, this design
 * needs the full own-and-broker-the-window treatment before it can be trusted. */
#define IOS_SOFT_MAX 8
static struct { uint64_t base, size, committed; unsigned commits, collisions; unsigned cage; } ios_soft[IOS_SOFT_MAX];
static unsigned ios_soft_n;

/* ml433 (#72): the V8/cppgc cage holdback.
 *
 * Single-process CEF means exactly ONE process-wide cppgc/V8 cage: an 8GB
 * reservation the guest requires 8GB-ALIGNED. On Windows' 128TB that is free;
 * in our 64GB usable band the only 8GB-aligned stretch outside the PA pool
 * slots is [0x7200000000, 0x7400000000), and top-down furniture placement
 * fills its tail with DLL image copies long before CEF asks (~85s in). The
 * guest's fallback — reserve size+align-64K = 16383MB and trim — needs a 16GB
 * gap that cannot exist here, so PA retries three times and abort()s the
 * webhelper (ml432, one minute after the first-ever BrowserReady).
 *
 * So reserve the stretch at boot, before any furniture can land in it, and
 * hand it to the first 8GB jumbo ask. It deliberately stops 64KB short of
 * 0x7400000000: that page is the PA guard pool's home base (guard-style base
 * = slot - 64KB, see the jumbo walk), which stays REAL and untouched. The
 * guest is told it got the full 8GB — the top 64KB overlaps only PA's
 * never-committed forbidden zone, and a stray commit there is absorbed by an
 * ios_soft tail entry. */
#define IOS_CAGE_BASE      0x7200000000ULL
#define IOS_CAGE_REAL_SIZE 0x1ffff0000ULL   /* 8GB - 64KB */
static int ios_cage_holdback_live;

static int ios_soft_find( uint64_t addr )
{
    /* ml434: smallest matching range wins — the 4GB soft cages sit INSIDE the
     * 16GB soft pools' claimed ranges, and first-match would shadow them. */
    unsigned i;
    int best = -1;
    for (i = 0; i < ios_soft_n; i++)
        if (addr >= ios_soft[i].base && addr < ios_soft[i].base + ios_soft[i].size
            && (best < 0 || ios_soft[i].size < ios_soft[best].size))
            best = (int)i;
    return best;
}

/* Is this 16GB-aligned slot free of any pool we already handed out? */
static int ios_soft_slot_taken( uint64_t slot )
{
    unsigned i;
    for (i = 0; i < ios_soft_n; i++)
        if (ios_soft[i].base == slot) return 1;
    return 0;
}

static void ios_soft_report( const char *why )
{
    unsigned i;
    for (i = 0; i < ios_soft_n; i++)
        dprintf(2, "[soft-pool] 0x%llx +%lluMB committed=%lluMB in %u calls, %u collisions (%s)\n",
                (unsigned long long)ios_soft[i].base,
                (unsigned long long)(ios_soft[i].size >> 20),
                (unsigned long long)(ios_soft[i].committed >> 20),
                ios_soft[i].commits, ios_soft[i].collisions, why);
}

static void ios_bigres_note( void *base, size_t size );   /* defined below */

static void ios_jumbo_census( void *hint, size_t size, void *result, unsigned st )
{
    /* ml131: report the 512MB-reservation census alongside every jumbo call —
     * the warmer-tick schedule fired only at cycle 1, before Steam had made any
     * of them, so the one number that matters never appeared. */
    ios_bigres_report( st ? "jumbo fail" : "jumbo ok" );
    unsigned long long now = ios_now_ms();
    unsigned long long gap = ios_jumbo_last_ms ? now - ios_jumbo_last_ms : 0;

    ios_jumbo_last_ms = now;
    static uint64_t granted_bases[8];
    static unsigned granted_n;
    static int owner_searched;

    if (st) ios_jumbo_fail++;
    else  { ios_jumbo_ok++; ios_jumbo_granted += size;
            /* ml150: track how much of each GRANTED POOL is ever COMMITTED.
             * This is the number that decides whether lazy reservation can beat
             * the 4-pool wall. PA needs 4 x 16GB of ADDRESS RANGE, but if it
             * commits only a fraction of each, the untouched remainder is dead
             * space we currently pay full price for — and furniture could live
             * there instead. Steam's own reservations came in at 7-8%
             * ([bigres-use]); if the pools are similar, four pools plus ~14GB of
             * furniture fit in the 64GB window and the wall is an accounting
             * artifact rather than a hard limit. Reuse the same commit
             * attribution table. */
            if (result) ios_bigres_note( result, size );
            if (granted_n < 8 && result)
            {
                granted_bases[granted_n++] = (uint64_t)(uintptr_t)result;
                /* a guard-style reserve returns the FORBIDDEN ZONE base; PA
                 * records the pool proper, 64KB higher. Look for both. */
                if (granted_n < 8 && (size & 0xffff) == 0x10000 - 0)
                    granted_bases[granted_n++] = (uint64_t)(uintptr_t)result + 0x10000;
            } }
    if (st && granted_n && !owner_searched)
    {
        owner_searched = 1;
        dprintf(2, "[pool-owner] searching %u module copies for %u granted pool bases...\n",
                ios_jit_mapping_count, granted_n);
        ios_pool_owner_search( granted_bases, granted_n );
        dprintf(2, "[pool-owner] search done\n");
    }

    /* ml135: log the PEB and wine tid too. PA's Init() reserves exactly ONE
     * plain 16GB (Regular) + ONE guarded 16GB+forbidden-zone (BRP); we observe
     * TWO of each, which is the signature of Init() running twice. If the two
     * pairs carry DIFFERENT PEBs it is two libcef copies in our shared address
     * space (a pseudo-process artefact we can fix by properly enforcing
     * single-process); if they share a PEB it is four distinct pool TYPES and
     * the size is a Chromium compile-time constant we cannot change. Those two
     * answers have completely different fixes, so print the discriminator. */
    dprintf(2, "[jumbo#%u] +%llums tid=%lx wtid=%04x peb=%p nrip=0x%llx grip=0x%llx size=0x%lx (%lu MB) hint=%p -> %p st=0x%x | granted=%lu MB ok=%u fail=%u\n",
            ++ios_jumbo_seq, gap, (unsigned long)(uintptr_t)pthread_self(),
            NtCurrentTeb() ? (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread : 0,
            NtCurrentTeb() ? NtCurrentTeb()->Peb : NULL,
            (unsigned long long)ios_guest_rip_now(),
            (unsigned long long)ios_guest_ctx_rip(),
            (unsigned long)size, (unsigned long)(size >> 20), hint, result, st,
            (unsigned long)(ios_jumbo_granted >> 20), ios_jumbo_ok, ios_jumbo_fail);
}


/* ml130 IS THE GUEST'S 12GB ACTUALLY USED?
 *
 * The 512MB reserves are steam.exe's own: type=0x2000 is MEM_RESERVE with no
 * MEM_TOP_DOWN, and FEXCore::Allocator::VirtualAlloc unconditionally ORs in
 * MEM_TOP_DOWN, so these cannot come from FEX. 2 x 512MB per guest thread, 12+
 * threads = 12+GB of pure reservation. On Windows' 128TB that is free; in our
 * 63GB it is the entire third-pool deficit.
 *
 * Whether we can do anything about it hinges on ONE fact: does Steam ever
 * COMMIT inside these ranges, or is it reserve-and-never-touch? If commits are
 * a small fraction, the reservations are slack and a lazy/shrunk reservation
 * becomes thinkable. If Steam commits heavily, the demand is real and two pools
 * is the ceiling until CEF itself is made to want less. Record each range and
 * attribute every MEM_COMMIT that lands inside one. */
#define IOS_BIGRES_MAX 48
static struct { uint64_t base, size, committed; unsigned commits; } ios_bigres_tab[IOS_BIGRES_MAX];
static unsigned ios_bigres_cnt;

static void ios_bigres_note( void *base, size_t size )
{
    if (!base || ios_bigres_cnt >= IOS_BIGRES_MAX) return;
    ios_bigres_tab[ios_bigres_cnt].base = (uint64_t)(uintptr_t)base;
    ios_bigres_tab[ios_bigres_cnt].size = size;
    ios_bigres_cnt++;
}

static void ios_bigres_commit( void *addr, size_t size )
{
    uint64_t a = (uint64_t)(uintptr_t)addr;
    unsigned i;
    for (i = 0; i < ios_bigres_cnt; i++)
        if (a >= ios_bigres_tab[i].base && a < ios_bigres_tab[i].base + ios_bigres_tab[i].size)
        {
            ios_bigres_tab[i].committed += size;
            ios_bigres_tab[i].commits++;
            return;
        }
}

/* ml435 (#73): FEX-band span lifecycle census. ml434 filled the band solid
 * (465 views, 86 failed 64MB scans -> code-buffer mprotect failures -> Crashpad)
 * with only ~52 of 109 created threads still alive — the discriminator between
 * "rpmalloc heaps recycle but demand outgrew 16GB" and "exited threads' spans
 * leak" is the ALLOC vs FREE count for >=16MB band regions. Pairs with the
 * [thr-term] probes in xtajit64 (same rev). */
static unsigned ios_span_alloc_n, ios_span_free_n;
static void ios_span_census( void *base, size_t size, int is_free )
{
    uintptr_t a = (uintptr_t)base;
    unsigned n;
    if (a < 0x7c00000000ULL || a >= 0x8000000000ULL || size < 0x1000000) return;
    n = is_free ? ++ios_span_free_n : ++ios_span_alloc_n;
    if (n <= 40 || !(n & 15))
        dprintf(2, "[span-census] %s #%u %p+0x%lx tid=%04x live=%d rev=ml435\n",
                is_free ? "FREE" : "ALLOC", n, base, (unsigned long)size,
                NtCurrentTeb() ? (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread : 0,
                (int)ios_span_alloc_n - (int)ios_span_free_n);
}

/* iOS-Madeira ml462 (#77): reserve->release CYCLE tracker. The ml461 run died
 * of a guest placement livelock: V8's CodeRange (512MB, must sit within jump
 * distance of libcef's embedded builtins) reserved, got granted, REJECTED the
 * location, released, and retried forever — ping-ponging on the same two
 * kernel-pick addresses while the armed steer valve dutifully spilled the
 * churn into the FEX band until the process starved (2,243 rpmalloc spans,
 * 15.5GB reserved). A same-(tid,size) big reserve that has been GRANTED and
 * immediately RELEASED dozens of times will never converge — after the cap,
 * deny it outright so the guest takes its own named failure path instead of
 * spinning. Keyed on (tid, size to 16MB granularity); 8 slots, evict-on-
 * collision, approximate by design. */
static struct { unsigned tid; uint64_t size16m; unsigned cycles; } ios_rescycle[8];
static void ios_reserve_cycle_note( unsigned tid, uint64_t size )
{
    uint64_t s16 = size >> 24;
    unsigned i, slot = (tid ^ (unsigned)s16) & 7;
    for (i = 0; i < 8; i++)
        if (ios_rescycle[i].tid == tid && ios_rescycle[i].size16m == s16)
        {
            ios_rescycle[i].cycles++;
            return;
        }
    ios_rescycle[slot].tid = tid;
    ios_rescycle[slot].size16m = s16;
    ios_rescycle[slot].cycles = 1;
}
static unsigned ios_reserve_cycle_count( unsigned tid, uint64_t size )
{
    uint64_t s16 = size >> 24;
    unsigned i;
    for (i = 0; i < 8; i++)
        if (ios_rescycle[i].tid == tid && ios_rescycle[i].size16m == s16)
            return ios_rescycle[i].cycles;
    return 0;
}

/* ml433 (#72): drop released ranges so [bigres-use] stops double-counting the
 * guest's reserve/free alignment retries — ml432 reported 163,840MB "reserved"
 * when all but ~72GB had already been freed again (the same base regranted up
 * to 9 times). Exact-base match only: jumbo grants are released whole. */
static void ios_bigres_release( void *base )
{
    uint64_t a = (uint64_t)(uintptr_t)base;
    unsigned i;
    for (i = 0; i < ios_bigres_cnt; i++)
    {
        if (ios_bigres_tab[i].base != a) continue;
        dprintf(2, "[bigres-free] 0x%llx +%lluMB released rev=ml433\n",
                (unsigned long long)a, (unsigned long long)(ios_bigres_tab[i].size >> 20));
        ios_reserve_cycle_note( NtCurrentTeb() ? (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread : 0,
                                ios_bigres_tab[i].size );
        ios_bigres_tab[i] = ios_bigres_tab[--ios_bigres_cnt];
        return;
    }
}

static void ios_bigres_report( const char *why )
{
    unsigned i;
    unsigned long long res = 0, com = 0, touched = 0;
    for (i = 0; i < ios_bigres_cnt; i++)
    {
        res += ios_bigres_tab[i].size;
        com += ios_bigres_tab[i].committed;
        if (ios_bigres_tab[i].committed) touched++;
    }
    dprintf(2, "[bigres-use] ranges=%u reserved=%llu MB committed=%llu MB (%llu%%) touched=%llu/%u (%s)\n",
            ios_bigres_cnt, res >> 20, com >> 20,
            res ? (com * 100) / res : 0, touched, ios_bigres_cnt, why);
    for (i = 0; i < ios_bigres_cnt; i++)
        if (ios_bigres_tab[i].size >= 0x40000000ULL)
            dprintf(2, "[bigres-use]   POOL 0x%llx +%lluMB committed=%lluMB (%llu%%) in %u calls\n",
                    ios_bigres_tab[i].base, ios_bigres_tab[i].size >> 20,
                    ios_bigres_tab[i].committed >> 20,
                    ios_bigres_tab[i].size ? (ios_bigres_tab[i].committed * 100) / ios_bigres_tab[i].size : 0,
                    ios_bigres_tab[i].commits);
    for (i = 0; i < ios_bigres_cnt && i < 8; i++)
        dprintf(2, "[bigres-use]   0x%llx +%lluMB committed=%lluMB in %u calls\n",
                ios_bigres_tab[i].base, ios_bigres_tab[i].size >> 20,
                ios_bigres_tab[i].committed >> 20, ios_bigres_tab[i].commits);
}


/* ml139: verify a freshly-made pool copy's .text is EXECUTABLE, at page
 * granularity. Used by BOTH copy paths — the loader path that builds the first
 * copy of an image and ios_jit_copy_module_for_child that clones it per
 * pseudo-process. ml138 instrumented only the child path and reported nothing,
 * which I could not distinguish from "clean" until the faulting copy turned out
 * to come from the LOADER path (libarm64ecfex pool 0x11f638000). Always print a
 * verdict so silence can never again be mistaken for a pass. */

/* ml153 WINE DEBUG CHANNELS ARE NEVER RESOLVED IN POOL COPIES.
 *
 * struct __wine_debug_channel { unsigned char flags; char name[15]; } ships with
 * flags = 0xff, the "lazy init" sentinel (__WINE_DBCL_INIT = bit 7). The
 * compiled fast path is a bare bit test —
 *     ldrb w8,[x8,#0x40] ; tbz w8,#3,skip     (rpcrt4 NDRCContextUnmarshall)
 * — so an UNRESOLVED channel reads as TRACE-ENABLED, the TRACE block is entered,
 * and all of its arguments are evaluated before anything discovers the channel is
 * actually off. In rpcrt4 that means TRACE("*%p=(%p)...", CContext, *CContext)
 * dereferences the context handle: with a bad handle that is an instant fault,
 * which is exactly the 28x RtlLeaveCriticalSection / NDRCContextUnmarshall
 * cluster that stalls the webhelper's RPC handshake.
 *
 * Wine resolves these lazily per channel, so a module copied before a channel was
 * ever used keeps 0xff forever. Normalise them in the copy: ERR only (0x02),
 * matching WINEDEBUG=err+all. Costs nothing and removes TRACE argument
 * evaluation — and its pointer dereferences — from every copied DLL.
 *
 * Deliberately conservative: only a byte that is EXACTLY 0xff followed by a
 * plausible lowercase channel name and NUL padding to 16 bytes is touched. */
static int ios_jit_init_debug_channels( void *base, size_t image_size,
                                        size_t data_off, size_t data_size )
{
    unsigned char *p = (unsigned char *)base;
    size_t o;
    int fixed = 0;

    if (!base || !data_size || data_off + data_size > image_size) return 0;
    /* ml155: BOUND THE SCAN. The first cut walked every writable section in
     * full, which not only burned iterations but TOUCHED EVERY .data PAGE of
     * every one of ~150 module copies — forcing them all resident instead of
     * faulting lazily. That showed up as a large, user-visible slowdown in
     * desktop and Steam-updater init.
     *
     * Wine builtins keep their __wine_dbch_* table near the start of .data, and
     * the DLLs with multi-megabyte .data (libcef, steamui, shell32) are not Wine
     * builtins and have no channels at all. 256KB is 16 pages per section and
     * caught every channel the unbounded version did (7-44 per module). */
    if (data_size > 0x40000) data_size = 0x40000;
    for (o = data_off; o + 16 <= data_off + data_size; o += 8)
    {
        unsigned char *c = p + o;
        int i, namelen = 0;

        if (c[0] != 0xff) continue;
        for (i = 1; i < 16; i++)
        {
            unsigned char ch = c[i];
            if (ch == 0) break;
            if (!((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_')) { namelen = -1; break; }
            namelen++;
        }
        if (namelen < 2 || namelen > 14) continue;
        for (i = 1 + namelen; i < 16; i++) if (c[i]) { namelen = -1; break; }
        if (namelen < 0) continue;
        c[0] = 0x02;   /* ERR only — see WINEDEBUG=err+all in WineProcessBridge.m */
        fixed++;
    }
    return fixed;
}

/* ml240: WHICH copy step poisons maxprot?
 *
 * The pool range is CLEAN at hand-out (24/24, all reused=0) yet isolated .text pages come
 * out with max=3 -- EXEC gone from maxprot, unraisable, so mprotect(RX) fails forever and
 * execution there faults NOEXEC. Between hand-out and verification the only memory
 * operations are the memcpy through the RW alias and sys_icache_invalidate on the RX
 * alias, so scanning after each pinpoints the culprit instead of guessing. */
static unsigned ios_jit_scan_nonexec( const char *label, const char *who,
                                      const void *rx_dest, size_t size )
{
    static int scans;
    unsigned bad = 0;
    size_t o;

    for (o = 0; o < size; o += 0x4000)
    {
        mach_vm_address_t want = (mach_vm_address_t)(uintptr_t)((const char *)rx_dest + o), a = want;
        mach_vm_size_t rsz = 0;
        vm_region_basic_info_data_64_t inf;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;

        if (mach_vm_region( mach_task_self(), &a, &rsz, VM_REGION_BASIC_INFO_64,
                            (vm_region_info_t)&inf, &cnt, &obj ) != KERN_SUCCESS) break;
        if (a > want) continue;
        if (!(inf.max_protection & VM_PROT_EXECUTE))
        {
            if (bad == 0 && scans < 30)
                dprintf( 2, "[poison-step] %s: FIRST non-exec at +0x%lx va=%p prot=%x max=%x (%s)\n",
                         label, (unsigned long)o, (void *)(uintptr_t)want,
                         inf.protection, inf.max_protection, who ? who : "?" );
            bad++;
        }
    }
    if (bad && scans < 30) { scans++;
        dprintf( 2, "[poison-step] %s: %u non-exec pages (%s)\n", label, bad, who ? who : "?" ); }
    return bad;
}

static void ios_jit_verify_text_exec( const char *who, const void *rx_dest, size_t image_size )
{
    static unsigned verified;
    size_t o, bad = 0, pages = 0, text_offset = 0, text_size = 0;

    if (!rx_dest || image_size < 0x1000) return;
    /* Derive the executable section from the copy's OWN PE headers so this
     * works from either copy path without needing the caller's locals. */
    {
        const IMAGE_DOS_HEADER *dos = rx_dest;
        const IMAGE_NT_HEADERS *nt;
        const IMAGE_SECTION_HEADER *sec;
        unsigned i;

        if (dos->e_magic != IMAGE_DOS_SIGNATURE) return;
        nt = (const IMAGE_NT_HEADERS *)((const char *)rx_dest + dos->e_lfanew);
        if (nt->Signature != IMAGE_NT_SIGNATURE) return;
        sec = IMAGE_FIRST_SECTION( nt );
        for (i = 0; i < nt->FileHeader.NumberOfSections; i++)
            if ((sec[i].Characteristics & IMAGE_SCN_MEM_EXECUTE) &&
                sec[i].Misc.VirtualSize > text_size)
            {
                text_offset = sec[i].VirtualAddress;
                text_size = sec[i].Misc.VirtualSize;
            }
        if (!text_size || text_offset + text_size > image_size) return;

        /* ml156 REVERTED — see ios_jit_init_debug_channels. The normalisation
         * itself worked (7-44 channels per module) but the call site was wrong:
         * it wrote through rx_dest, the EXECUTE alias, instead of the RW alias
         * the copy path uses for content, and any false-positive match corrupts
         * real .data. Result: steam.exe died after 137 unix calls with exec
         * faults back. Re-do it against rw_dest with a stricter pattern before
         * re-enabling. */
    }
    for (o = 0; o < text_size; o += 0x4000)
    {
        mach_vm_address_t want = (mach_vm_address_t)(uintptr_t)((const char *)rx_dest + text_offset + o), a = want;
        mach_vm_size_t rsz = 0;
        vm_region_basic_info_data_64_t inf;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;

        if (mach_vm_region( mach_task_self(), &a, &rsz, VM_REGION_BASIC_INFO_64,
                            (vm_region_info_t)&inf, &cnt, &obj ) != KERN_SUCCESS) break;
        if (a > want) continue;
        pages++;
        if (!(inf.max_protection & VM_PROT_EXECUTE) && bad++ < 6)
            dprintf(2, "[copy-verify] %s BORN NON-EXEC text+0x%lx va=%p prot=%x max=%x\n",
                    who ? who : "?", (unsigned long)o, (void *)(uintptr_t)want,
                    inf.protection, inf.max_protection);
    }
    if (bad)
        dprintf(2, "[copy-verify] %s: %lu of %lu .text pages BORN NON-EXEC (copy @%p)\n",
                who ? who : "?", (unsigned long)bad, (unsigned long)pages, rx_dest);
    else if (verified++ < 25 || (verified % 40) == 0)
        dprintf(2, "[copy-verify] %s: OK, %lu .text pages executable (copy @%p)\n",
                who ? who : "?", (unsigned long)pages, rx_dest);
}


/* ml141 TASK #34 THE REAL FIX — remove the .text/.data page sharing.
 *
 * PE sections are 4KB-aligned but iOS hardware pages are 16KB, so a writable
 * section routinely begins part-way into a page whose earlier bytes are the
 * TAIL OF .text. The RW mprotect that makes .data writable then strips EXECUTE
 * from that page of live code, permanently (mprotect drops it from
 * max_protection on blessed memory). That is task #34: one dead page per
 * module, always 64KB-aligned, fatal only when execution finally reaches it —
 * which is why CEF dies in libarm64ecfex's JIT emitters and Thumper never does.
 *
 * ml141 first tried skipping the shared page (round the RW range UP). That did
 * remove every BORN NON-EXEC page, but a .data STXR into the now-read-only
 * shared page killed steam.exe after 61 unix calls — the SIGBUS store emulator
 * does not cover store-exclusive. Neither side can lose the page.
 *
 * So don't arbitrate: eliminate the overlap. Shift the copy's pool offset so
 * the first writable section lands exactly on a 16KB boundary. Everything below
 * it is RX either way, so .text being page-misaligned costs nothing, and no
 * page is ever both code and data. The shift is a deterministic function of the
 * image, so every copy of a DLL still gets an identical layout — the
 * precondition the .text-sharing/tramp-fold work depends on. */
static size_t ios_jit_data_align_delta( const void *image_base, size_t image_size )
{
    const IMAGE_DOS_HEADER *dos = image_base;
    const IMAGE_NT_HEADERS *nt;
    const IMAGE_SECTION_HEADER *sec;
    unsigned int first_w = 0;
    unsigned i;

    if (!image_base || image_size < 0x1000) return 0;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    nt = (const IMAGE_NT_HEADERS *)((const char *)image_base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return 0;
    sec = IMAGE_FIRST_SECTION( nt );
    for (i = 0; i < nt->FileHeader.NumberOfSections; i++)
        if ((sec[i].Characteristics & IMAGE_SCN_MEM_WRITE) && sec[i].Misc.VirtualSize &&
            (!first_w || sec[i].VirtualAddress < first_w))
            first_w = sec[i].VirtualAddress;
    if (!first_w) return 0;
    return (0x4000 - (first_w & 0x3fff)) & 0x3fff;
}

static void ios_va_gap_probe( const char *why )
{
    const mach_vm_address_t CARVE_LO = 0x1000000000ULL;   /* 64G  */
    const mach_vm_address_t CARVE_HI = 0x7000000000ULL;   /* 448G */
    const mach_vm_address_t VA_TOP   = 0x8000000000ULL;   /* 512G */
    mach_vm_address_t addr = 0, prev_end = 0;
    unsigned long long usable_mb = 0;
    int gaps = 0;

    dprintf(2, "[va-gaps] ==== map walk (%s) ====\n", why);
    while (addr < VA_TOP)
    {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;

        if (mach_vm_region( mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64,
                            (vm_region_info_t)&info, &cnt, &obj ) != KERN_SUCCESS)
            break;
        if (addr > prev_end)
        {
            mach_vm_size_t gap = addr - prev_end;
            if (gap >= 0x40000000ULL)   /* >= 1GB is all we care about */
            {
                int carve = (prev_end >= CARVE_LO && prev_end < CARVE_HI);
                if (!carve) usable_mb += (unsigned long long)(gap >> 20);
                dprintf(2, "[va-gaps] FREE 0x%llx..0x%llx = %llu MB%s\n",
                        (unsigned long long)prev_end, (unsigned long long)addr,
                        (unsigned long long)(gap >> 20),
                        carve ? "  <-- GPU CARVEOUT, unusable" : "");
                if (++gaps >= 24) { dprintf(2, "[va-gaps] (truncated)\n"); break; }
            }
        }
        prev_end = addr + size;
        addr = prev_end;
    }
    if (prev_end < VA_TOP)
    {
        unsigned long long tail = (unsigned long long)((VA_TOP - prev_end) >> 20);
        usable_mb += tail;
        dprintf(2, "[va-gaps] FREE 0x%llx..0x%llx = %llu MB (top tail)\n",
                (unsigned long long)prev_end, (unsigned long long)VA_TOP, tail);
    }
    dprintf(2, "[va-gaps] ==== end: %llu MB (%llu GB) usable outside the carveout ====\n",
            usable_mb, usable_mb >> 10);
}

/* ml89: report the RX alias's protections for a pool range, WITHOUT touching
 * them. The first version of this guard probed with mprotect(RX) and dropped
 * any range that returned EACCES — but 62 of 62 candidates failed and not one
 * succeeded, which is the signature of a probe that can never pass rather than
 * of 62 genuinely dead ranges. mprotect on debugger-blessed pool memory is
 * refused outright (same family as the share-probe's kr=2 on OVERWRITE), so it
 * says nothing about executability. mach_vm_region reads max_protection
 * directly and mutates nothing. Returns 1 if the range still permits exec. */
static int ios_pool_range_execable(size_t off, size_t range_size,
                                   unsigned int *cur_out, unsigned int *max_out)
{
    /* ml242 FIX: scan the WHOLE range, not just its first page.
     *
     * This guard existed and its intent was right, but it queried exactly one address --
     * rx_base + off -- so it only ever saw the START page. Every poisoned page measured
     * sits deeper in (+0x30000, +0x60000, +0x90000, +0xb0000, +0xd0000, +0xe0000), so the
     * start looked clean, the guard passed, and the range was recycled with a permanently
     * non-executable page inside it. That page later lands in a module's .text, mprotect(RX)
     * can never restore EXEC (maxprot only ever lowers), and execution there faults NOEXEC
     * -- killing the process (this run: dbghelp.dll+0x6da14).
     *
     * Measured discriminator: 29 of 29 poisoned ranges had reused=1; virgin bump memory was
     * never poisoned. So recycled VA carrying narrowed maxprot is the whole mechanism.
     *
     * Walks region-by-region (mach_vm_region returns each region's size) rather than page
     * by page, so this is O(regions) and cheap even for multi-MB ranges. */
    mach_vm_address_t base, a, end;

    if (!ios_jit_rx_base_global) return 1;
    base = (mach_vm_address_t)(uintptr_t)((char *)ios_jit_rx_base_global + off);
    end  = base + (range_size ? range_size : 1);

    for (a = base; a < end; )
    {
        mach_vm_address_t q = a;
        mach_vm_size_t sz = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;

        if (mach_vm_region( mach_task_self(), &q, &sz, VM_REGION_BASIC_INFO_64,
                            (vm_region_info_t)&info, &cnt, &obj ) != KERN_SUCCESS)
            return 1;      /* can't tell — don't drop the range on a failed query */
        if (q >= end) break;
        if (q > a) { a = q; continue; }   /* gap: skip to the next real region */
        if (!sz) break;

        if (!(info.max_protection & VM_PROT_EXECUTE))
        {
            if (cur_out) *cur_out = (unsigned int)info.protection;
            if (max_out) *max_out = (unsigned int)info.max_protection;
            return 0;      /* poisoned somewhere in the range — refuse it */
        }
        if (a == base)
        {
            if (cur_out) *cur_out = (unsigned int)info.protection;
            if (max_out) *max_out = (unsigned int)info.max_protection;
        }
        a = q + sz;
    }
    return 1;
}

/* iOS-Madeira: secondary user_VA → JIT pool aliases mapping for anonymous
 * RWX regions (e.g. FEX CodeBuffer). When user_VA is vm_remap'd from JIT pool
 * RX, writes via user_VA fault and the STR fault emulator looks up the RW
 * alias here. Execution faults at user_VA are redirected to the RX alias
 * (which is the only address that's actually executable on iOS TXM).
 * Declared above ios_pool_alloc_range so the allocator can purge stale
 * entries when it recycles a pool range. */
/* iOS-Madeira ml630: 32 -> 4096.
 *
 * ULTRAKILL/Mono ran the table dry: `[jit-pool] anon alias table FULL (32 slots)
 * -- writes to 0x705f9d0000 will NOT route!`. The new Mono code buffer then had NO
 * RW alias, so `stur q1,[x6,#-0x40]` into it could not be routed, became an
 * unhandled 0x80000002, and wine's unwinder then read the half-written unwind
 * metadata out of that same unpatched buffer and looped ~15.8M times until the
 * main thread's 8MB stack was gone. tid 007c exited and every Unity/DXMT worker
 * was orphaned -- all downstream of ONE exhausted 32-entry array.
 *
 * 4096 entries is ~128KB, still a flat array safe for the lock-free reader in the
 * signal handler. 64 would have been far too marginal: Mono keeps many buffers
 * live at once. ⛔ Do NOT "fix" this class by enlarging the guest stack -- that
 * only lets a runaway unwind run longer. */
#define IOS_JIT_MAX_ANON_ALIASES 4096
struct ios_jit_anon_alias {
    uintptr_t user_va;
    uintptr_t user_va_end;
    uintptr_t jit_rw_alias;
    uintptr_t jit_rx_alias;
};
static struct ios_jit_anon_alias ios_jit_anon_aliases[IOS_JIT_MAX_ANON_ALIASES];
static volatile int ios_jit_anon_alias_count = 0;
/* ml630: census — live entries, tombstones (reclaimed slots) and the high-water
 * mark, so "how close are we to the ceiling" is answerable from any run. */
static volatile int ios_jit_anon_alias_live = 0;
static volatile int ios_jit_anon_alias_hiwater = 0;
static volatile int ios_jit_anon_alias_tombstones = 0;
/* iOS-Madeira ml635: per-alias write telemetry.
 *
 * The iOS Mach write path emulates a store through the RW alias and then simply
 * advances PC — it NEVER invalidates FEX's cached translation, unlike the normal
 * ARM64EC path (Module.cpp HandleRWXAccessViolation). So FEX can translate a page
 * while it is still zeros, Mono can then fill it through millions of emulated
 * writes, and execution keeps following the STALE zero translation until it runs
 * off the end of the mapping. These counters decide that outright:
 *   write_gen  — bumped on every emulated write into this alias
 *   written    — bit per 16KB chunk that has EVER been written (first 32 chunks) */
static volatile unsigned int ios_alias_write_gen[IOS_JIT_MAX_ANON_ALIASES];
static volatile unsigned int ios_alias_written[IOS_JIT_MAX_ANON_ALIASES];
static volatile unsigned long long ios_alias_highest[IOS_JIT_MAX_ANON_ALIASES];

void ios_jit_anon_alias_note_write( unsigned long long addr )
{
    int n = ios_jit_anon_alias_count, i;
    for (i = 0; i < n; i++)
    {
        uintptr_t b = ios_jit_anon_aliases[i].user_va;
        if (!b || addr < b || addr >= ios_jit_anon_aliases[i].user_va_end) continue;
        __sync_add_and_fetch( &ios_alias_write_gen[i], 1 );
        {
            unsigned chunk = (unsigned)((addr - b) >> 14);   /* 16KB chunks */
            if (chunk < 32) __sync_or_and_fetch( &ios_alias_written[i], 1u << chunk );
            {   /* ml636: highest byte ever written — the tail question needs finer
                 * resolution than a 16KB bitmap. Monotonic CAS, no lock. */
                unsigned long long off = (addr - b) + 1, cur;
                do { cur = ios_alias_highest[i]; if (off <= cur) break; }
                while (!__sync_bool_compare_and_swap( &ios_alias_highest[i], cur, off ));
            }
        }
        return;
    }
}

/* Allocate a page-aligned range from the pool head: free list first
 * (grace-expired first-fit; remainder returned to the list), bump second.
 * Returns (size_t)-1 on exhaustion WITHOUT consuming any pool space (the
 * old fetch_and_add-then-check burned the offset on every failed retry).
 * `pool_limit` = usable head bytes (pool size minus tail reservation).
 *
 * anchor_off/max_dist (Steam S3 run 11 ROOT CAUSE): the x18 patcher emits
 * B/BL from a module's .text to its trampoline range — ARM64 imm26 reaches
 * only ±128MB, and with the 640MB pool + freelist fragmentation SHELL32's
 * tramps landed 230MB below its image. The encoder silently truncated the
 * offset (mod 256MB) → branches into untouched pool → the entire
 * "poison pointer / zeroed tramp" crash family (runs 7-11, proven by
 * imm26 0x90A311 == truncation of -0xDBD73BC). Pass anchor_off = the
 * image's pool offset and max_dist to force the range within branch
 * reach; (size_t)-1 anchor = unconstrained (old behavior). */
static size_t ios_pool_alloc_range_ex( size_t alloc_size, size_t pool_limit,
                                       size_t anchor_off, size_t max_dist )
{
    size_t off = (size_t)-1;
    time_t now = time( NULL );
    int i;

#define IOS_POOL_IN_REACH(o) \
    (anchor_off == (size_t)-1 || \
     ((o) > anchor_off ? (o) + alloc_size - anchor_off : anchor_off - (o)) <= max_dist)

    pthread_mutex_lock( &ios_pool_lock );

    /* Post-grace, return each freed range's physical pages to the OS.
     * NO_FOOTPRINT exempts the pool from OUR jetsam ledger, but dirty
     * pages still consume device RAM — 300MB of dead copies pressures
     * the rest of the system (prime suspect for StikDebug dying →
     * debugger-suspension freezes + "JIT detached"). Deferred past the
     * grace window so laggard exit threads never execute a purged page. */
    for (i = 0; i < ios_pool_free_count; i++)
    {
        if (ios_pool_freelist[i].advised) continue;
        if (now - ios_pool_freelist[i].freed_at < IOS_POOL_REUSE_GRACE_SEC) continue;
        /* task #34 belt: NEVER volatilize a range that overlaps a LIVE ledger
         * entry. Freelist and ledger are disjoint by design (free removes the
         * ledger entry), so any overlap here is an accounting bug — and
         * MADV_FREE on live pool memory is exactly the "iOS zero-harvests
         * executing code" death seen in ml74 (Steam pressure makes the
         * harvest actually happen; Thumper never pushed hard enough). Skip
         * the range, log loudly, and keep it un-advised so we re-check. */
        {
            int j, live_overlap = 0;
            size_t f_off = ios_pool_freelist[i].off, f_end = f_off + ios_pool_freelist[i].size;
            for (j = 0; j < ios_pool_ledger_count; j++)
            {
                size_t l_off = ios_pool_ledger[j].off, l_end = l_off + ios_pool_ledger[j].size;
                if (l_off < f_end && l_end > f_off) { live_overlap = 1; break; }
            }
            if (live_overlap)
            {
                dprintf(2, "[jit-pool] SWEEP SKIPPED live-overlap: freed off=0x%lx+0x%lx overlaps ledger off=0x%lx+0x%lx peb=%p — accounting bug, NOT volatilizing\n",
                        (unsigned long)f_off, (unsigned long)(f_end - f_off),
                        (unsigned long)ios_pool_ledger[j].off, (unsigned long)ios_pool_ledger[j].size,
                        ios_pool_ledger[j].peb);
                continue;
            }
        }
        /* ml87 (2026-07-27): DO NOT volatilize pool ranges. Ever.
         *
         * History: this was MADV_FREE, then MADV_FREE_REUSABLE on the theory
         * that the handout path's MADV_FREE_REUSE cancel was mispaired. ml87
         * disproved that — all 101 cancels returned 0 and libarm64ecfex STILL
         * died on a reused range (off=0x6844000, mprotect_rx=EACCES), exactly
         * as in ml76 (off=0x6c34000).
         *
         * The flavor was never the issue: BOTH marks let the kernel reclaim
         * the physical pages. The pool's RX alias is debugger-blessed
         * (jit26_prepare_region), and a reclaimed page re-faults as a FRESH,
         * UNBLESSED page — the mapping comes back max_prot=RW and mprotect(RX)
         * is refused forever. MADV_FREE_REUSE only helps if the kernel hasn't
         * taken the page yet; under CEF pressure (653MB pool + 212MB libcef)
         * it already has.
         *
         * Cost of not sweeping: dead copies stay resident, so pool RSS sits at
         * its high-water instead of shrinking. Range REUSE is untouched — the
         * freelist below still recycles pool VA — so this costs no address
         * space, only RAM. Note the sweep was originally added to relieve the
         * RAM pressure blamed for StikDebug dying (the freeze/detach); that
         * symptom may have been this corruption all along. */
        ios_pool_freelist[i].advised = 1;
    }

    for (i = 0; i < ios_pool_free_count; i++)
    {
        if (ios_pool_freelist[i].size < alloc_size) continue;
        if (now - ios_pool_freelist[i].freed_at < IOS_POOL_REUSE_GRACE_SEC) continue;
        if (!IOS_POOL_IN_REACH(ios_pool_freelist[i].off)) continue;
        /* ml87/ml88 belt: never hand out a range that has genuinely lost its
         * exec blessing (in ml88 all 8 [exec-recover] deaths were on freelist
         * ranges, none on virgin bump pages). Now a read-only max_prot query —
         * see ios_pool_range_execable() for why the mprotect version was a
         * false positive that dropped all 62 candidates and disabled reuse
         * entirely (pool then bumped to 762MB of 896MB). */
        {
            unsigned int cur = 0, mx = 0;
            if (!ios_pool_range_execable( ios_pool_freelist[i].off,
                                          ios_pool_freelist[i].size, &cur, &mx ))
            {
                dprintf(2, "[jit-pool] POISONED range off=0x%lx size=0x%lx cur=0x%x max=0x%x — dropped, NOT handed out\n",
                        (unsigned long)ios_pool_freelist[i].off,
                        (unsigned long)ios_pool_freelist[i].size, cur, mx);
                ios_pool_freelist[i] = ios_pool_freelist[--ios_pool_free_count];
                i--;
                continue;
            }
        }
        /* task #34 DOUBLE-HANDOUT DETECTOR. ml99 proved the copy itself is
         * correct (66 reuses, 0 [copy-verify] mismatches), so a pool page that
         * later reads back as zeros was overwritten AFTER it was written. The
         * writer that would correlate exactly with reuse is the allocator
         * handing this range to a second module while the first is still
         * loaded — the second memcpy then lands on top of live code. ml87
         * showed kernelbase and libarm64ecfex both reporting pool
         * 0x122844000; that was explained away as the bump pointer not
         * advancing on a freelist serve, which is true but does not rule this
         * out. Freelist and ledger are disjoint BY DESIGN (free removes the
         * ledger entry), so any overlap here is an accounting bug. Checked
         * BEFORE the entry is split so a refused range stays intact. */
        {
            size_t l_off = 0;
            void  *l_peb = NULL;
            if (ios_jit_rw_base_global &&
                ios_pool_live_overlap( (uintptr_t)ios_jit_rw_base_global + ios_pool_freelist[i].off,
                                       alloc_size, &l_off, &l_peb ))
            {
                dprintf(2, "[pool-dup] DOUBLE HANDOUT REFUSED: freelist off=0x%lx size=0x%lx overlaps LIVE ledger off=0x%lx peb=%p — second copy would have overwritten loaded code\n",
                        (unsigned long)ios_pool_freelist[i].off, (unsigned long)alloc_size,
                        (unsigned long)l_off, l_peb);
                ios_pool_freelist[i] = ios_pool_freelist[--ios_pool_free_count];
                i--;
                continue;
            }
        }
        off = ios_pool_freelist[i].off;
        if (ios_pool_freelist[i].size > alloc_size)
        {
            ios_pool_freelist[i].off  += alloc_size;
            ios_pool_freelist[i].size -= alloc_size;
        }
        else
        {
            ios_pool_freelist[i] = ios_pool_freelist[--ios_pool_free_count];
        }
        /* Task #22 root cause (2026-07-10 Steam): the sweep above marked this
         * range volatile (MADV_FREE) and on Darwin that mark is NOT reliably
         * cleared by rewriting these entry-backed pages — reused ranges kept
         * getting harvested under the Steam download's memory pressure,
         * zeroing LIVE FEX LookupCache/CodeBuffer data (same page reclaimed
         * 4x at the same fault address, then the give-up → 24k-exception BUS
         * storm = the "freeze", which drowned StikDebug = the "detach", then
         * steam.exe died). MADV_FREE_REUSE is the documented cancel — apply
         * it BEFORE handing the range out so the new owner's writes stick. */
        {
            /* ml103: the MADV_FREE_REUSE that used to run here is GONE. It was
             * the documented cancel for MADV_FREE_REUSABLE — but the sweep no
             * longer marks anything reusable, so this call was unpaired. On
             * Darwin an unpaired REUSE is at best a no-op and at worst touches
             * the vm entry's reusable accounting itself. It is the last madvise
             * left in the pool allocation path, and exec faults on recycled
             * ranges persist with every other writer excluded (copy verifies
             * clean, no double-handout, no stale-alias memset, no module
             * zero-fill) — so this is the remaining single variable. */
            dprintf(2, "[jit-pool] reused freed range off=0x%lx size=0x%lx (freelist %d ranges) no-madvise\n",
                    (unsigned long)off, (unsigned long)alloc_size, ios_pool_free_count);
        }
        ios_pool_last_alloc_reused = 1;
        break;
    }

    if (off == (size_t)-1)
    {
        if (jit_pool_offset + alloc_size <= pool_limit
            && IOS_POOL_IN_REACH(jit_pool_offset))
        {
            off = jit_pool_offset;
            jit_pool_offset += alloc_size;
            ios_pool_last_alloc_reused = 0;
            /* ml89 CONTROL for the POISONED check above: report the same
             * max_prot for a range that has NEVER been freed. If virgin ranges
             * read max=0x7 while freed ranges read max=0x3, reuse really does
             * strip exec and the guard is sound. If both read the same, the
             * guard is measuring nothing and the exec faults have another
             * cause. Logged once every 16 bump allocations to stay quiet. */
            {
                static int bump_probe_n;
                if ((bump_probe_n++ & 15) == 0)
                {
                    unsigned int cur = 0, mx = 0;
                    int ok = ios_pool_range_execable( off, alloc_size, &cur, &mx );
                    dprintf(2, "[jit-pool] bump-probe off=0x%lx size=0x%lx cur=0x%x max=0x%x execable=%d (VIRGIN control)\n",
                            (unsigned long)off, (unsigned long)alloc_size, cur, mx, ok);
                }
            }
            /* ml103: the matching unpaired MADV_FREE_REUSE is gone here too —
             * see the freelist path above. Virgin pages were never marked
             * volatile in the first place, so this one had even less reason to
             * exist. No madvise now runs on any pool allocation path. */
        }
    }
#undef IOS_POOL_IN_REACH

    if (off != (size_t)-1)
    {
        /* Steam S3 run 9/10: purge STALE anon-alias entries whose pool range
         * overlaps the handed-out range. Aliases are only cleared on process
         * EXIT — a live process (steam.exe) that guest-frees an anon RWX
         * region leaves its entry behind, and once the pool range is
         * recycled (user32's x18 trampolines in the errorreporter child) any
         * guest MEM_DECOMMIT of the old user VA memsets the NEW occupant to
         * zero via decommit_pages' alias path → blr into zeros → fault storm. */
        {
            uintptr_t new_rw_start = (uintptr_t)ios_jit_rw_base_global + off;
            uintptr_t new_rw_end   = new_rw_start + alloc_size;
            for (i = 0; i < ios_jit_anon_alias_count; i++)
            {
                uintptr_t a_start, a_end;
                if (!ios_jit_anon_aliases[i].user_va) continue;
                a_start = ios_jit_anon_aliases[i].jit_rw_alias;
                a_end   = a_start + (ios_jit_anon_aliases[i].user_va_end
                                     - ios_jit_anon_aliases[i].user_va);
                if (a_start < new_rw_end && a_end > new_rw_start)
                {
                    dprintf(2, "[jit-pool] STALE alias purged on handout: user_va=%p rw=%p+0x%lx overlaps new range off=0x%lx+0x%lx\n",
                            (void *)ios_jit_anon_aliases[i].user_va, (void *)a_start,
                            (unsigned long)(a_end - a_start),
                            (unsigned long)off, (unsigned long)alloc_size);
                    ios_jit_anon_aliases[i].user_va_end = 0;
                    __sync_synchronize();
                    ios_mono_alias_retire( ios_jit_anon_aliases[i].user_va );  /* ml648: unmap/teardown */
                    ios_jit_anon_aliases[i].user_va = 0;
                }
            }
        }
        if (ios_pool_ledger_count < IOS_POOL_LEDGER_MAX)
        {
            ios_pool_ledger[ios_pool_ledger_count].off  = off;
            ios_pool_ledger[ios_pool_ledger_count].size = alloc_size;
            ios_pool_ledger[ios_pool_ledger_count].peb  = ios_jit_current_peb();
            ios_pool_ledger_count++;
        }
        else dprintf(2, "[jit-pool] ledger FULL — range off=0x%lx will never be reclaimed\n",
                     (unsigned long)off);
    }

    pthread_mutex_unlock( &ios_pool_lock );
    return off;
}

/* ml239: is a pool range ALREADY non-executable when handed out?
 *
 * copy-verify reports isolated .text pages BORN NON-EXEC with max=3 -- maxprot lacking
 * EXEC, which can never be raised again, so mprotect(RX) fails forever and execution there
 * faults NOEXEC (this run: dbghelp.dll+0x6da14, unhandled -> process death). Seen across
 * several modules: 1/295 in steamwebhelper, 2/72 in chromehtml, 1/40 in libswresample.
 *
 * Two candidates needing different fixes: the copy path poisons the page, or the pool
 * RECYCLES already-poisoned VA (68 freelist/reclaim events this run) so it arrives poisoned.
 * Checking maxprot at hand-out time -- BEFORE anything is written -- separates them.
 * VM_PROT_COPY was already ruled out (zero RW+COPY events in the failing run). */
static void ios_pool_check_range_exec( size_t off, size_t size, int reused )
{
    extern void *ios_jit_rx_base_global;
    uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
    static int checked;
    size_t o;
    unsigned bad = 0;

    /* ml241: do NOT cap the CHECK -- only the printing. The first version incremented a
     * shared counter on clean ranges too, so it sampled the first 24 allocations (all
     * clean) and never looked at the ones that were actually poisoned (winmm, setupapi,
     * ...). It reported "CLEAN at hand-out 24/24" and I wrongly concluded the copy path was
     * to blame; [poison-step] pre-memcpy then showed the pages already non-exec BEFORE the
     * copy. Check everything, print only what is interesting. */
    if (!rx) return;

    for (o = 0; o < size; o += 0x4000)
    {
        mach_vm_address_t want = (mach_vm_address_t)(rx + off + o), a = want;
        mach_vm_size_t rsz = 0;
        vm_region_basic_info_data_64_t inf;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;

        if (mach_vm_region( mach_task_self(), &a, &rsz, VM_REGION_BASIC_INFO_64,
                            (vm_region_info_t)&inf, &cnt, &obj ) != KERN_SUCCESS) break;
        if (a > want) continue;
        if (!(inf.max_protection & VM_PROT_EXECUTE))
        {
            if (bad++ == 0 && checked++ < 30)
            {
                /* ml248: name the OWNER. mprotect_exec never touches pool VA (0 calls, 20
                 * poisoned ranges), so nothing is narrowing maxprot in place -- the pages
                 * are being REPLACED by a different mapping. Guest PE images live in the
                 * same 0x1xxxxxxxx band as the pool, so the suspect is Wine's own allocator
                 * handing out VA that overlaps the pool and later unmapping/remapping it.
                 * The Mach user_tag identifies the allocator, and share_mode distinguishes
                 * our dual-mapped alias from an ordinary private mapping. */
                vm_region_extended_info_data_t ext;
                mach_msg_type_number_t ecnt = VM_REGION_EXTENDED_INFO_COUNT;
                mach_vm_address_t ea = want;
                mach_vm_size_t esz = 0;
                mach_port_t eobj = MACH_PORT_NULL;
                unsigned tag = 0, share = 0;

                if (mach_vm_region( mach_task_self(), &ea, &esz, VM_REGION_EXTENDED_INFO,
                                    (vm_region_info_t)&ext, &ecnt, &eobj ) == KERN_SUCCESS)
                { tag = ext.user_tag; share = ext.share_mode; }

                dprintf( 2, "[pool-poison] HANDED OUT NON-EXEC off=0x%lx +0x%lx va=%p prot=%x "
                            "max=%x reused=%d user_tag=%u share_mode=%u regionsz=0x%llx\n",
                         (unsigned long)off, (unsigned long)o, (void *)(uintptr_t)want,
                         inf.protection, inf.max_protection, reused, tag, share,
                         (unsigned long long)esz );
            }
        }
    }
    if (bad && checked < 30)
        dprintf( 2, "[pool-poison] off=0x%lx +0x%lx : %u poisoned pages, reused=%d\n",
                 (unsigned long)off, (unsigned long)size, bad, reused );
}

static size_t ios_pool_alloc_range( size_t alloc_size, size_t pool_limit )
{
    size_t off = ios_pool_alloc_range_ex( alloc_size, pool_limit, (size_t)-1, 0 );

    /* ml239: see ios_pool_check_range_exec. ios_pool_last_alloc_reused tells us whether
     * this came off the freelist or the virgin bump, which is exactly the discriminator. */
    if (off != (size_t)-1)
        ios_pool_check_range_exec( off, alloc_size, ios_pool_last_alloc_reused );
    return off;
}

/* Total bytes reserved from the pool TAIL by NtAllocateVirtualMemoryEx for
 * FEX EC_CODE buffers. File-scope so head and tail allocators can refuse to
 * cross each other: on 2026-07-06 (Thumper under desktop) the head cursor
 * grew past the bottom of a live tail-carved FEX CodeBuffer and late DLL
 * image copies memcpy'd over compiled blocks — neither side checked the
 * other. Reads of the opposing cursor are racy-but-monotonic: both only
 * grow, so a stale read can only make the check conservative late, never
 * un-refuse. */
static volatile size_t ios_jit_tail_reserved = 0;

/* ml438 (#74): tail EC-buffer FREE-LIST. tail_resv was monotonic — dead
 * threads' code buffers never returned their tail space, so long runs
 * exhausted the tail (ml436: 10 refusals at head 708MB + tail 188MB; ml437:
 * refusing even 1MB) and post-StikDebug-detach there is NO fallback (band
 * buffers can't be made executable detached). The pool is fully executable
 * from BOOT, so recycling tail carves needs no debugger: record every carve,
 * mark it free when FEXCore releases the buffer (NtFreeVirtualMemory of a
 * pool-tail rx address — no wine view exists for these), and serve future
 * asks first-fit from the free entries. No splitting: sizes are pow2-ish
 * (1..32MB after the ml437 MAX_CODE_SIZE cap), so first-fit-larger waste is
 * bounded and reuse is usually exact. */
#define IOS_TAIL_CARVE_MAX 256
static struct { size_t off; size_t size; int free; } ios_tail_carves[IOS_TAIL_CARVE_MAX];

/* ml557 (#74 REGRESSION): is any thread's PC currently INSIDE this tail carve?
 *
 * ml438 made a MEM_RELEASE of a live tail EC-buffer carve mark it free for reuse,
 * to stop the tail space leaking forever. But it marks the carve free WITHOUT
 * asking whether a thread is still executing JIT code in it, and `tail REUSE`
 * hands the same range straight back out to the next requester, which then
 * compiles different code over it.
 *
 * ml556 caught exactly that: carve rx=0x1543f8000 size=0x1000000 was FREEd and
 * REUSEd eight times, and the fatal fault landed at host pc 0x154d4008c — INSIDE
 * that range — with garbage registers (base reg = 0x40 -> a NULL+0x40 atomic
 * load). A thread was running in code that had been recycled underneath it.
 *
 * That also explains why the fatal site MOVES between runs (frame clear /
 * PartitionAlloc refcount CHECK / NULL-this call): the victim depends on what
 * happened to be compiled into the recycled range.
 *
 * Frees are rare (33-53 per run), so a full thread scan here costs nothing
 * measurable. Refusing to free an occupied carve reinstates a BOUNDED leak —
 * which is what ml438 set out to fix — but a leak is strictly better than
 * executing recycled code, and the carve becomes freeable on the next release
 * once the thread has left. */
static int ios_tail_carve_occupied( const void *base, size_t size )
{
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0, i;
    uintptr_t lo = (uintptr_t)base, hi = lo + size;
    mach_port_t self = mach_thread_self();
    int occupied = 0;

    if (task_threads( mach_task_self(), &threads, &count ) != KERN_SUCCESS)
        return 0;                                  /* cannot tell -> old behaviour */
    for (i = 0; i < count; i++)
    {
        arm_thread_state64_t st;
        mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
        if (threads[i] != self &&
            thread_get_state( threads[i], ARM_THREAD_STATE64,
                              (thread_state_t)&st, &sc ) == KERN_SUCCESS)
        {
            uintptr_t pc = (uintptr_t)arm_thread_state64_get_pc( st );
            if (pc >= lo && pc < hi) { occupied = 1; }
        }
        mach_port_deallocate( mach_task_self(), threads[i] );
    }
    mach_vm_deallocate( mach_task_self(), (mach_vm_address_t)threads,
                        count * sizeof(*threads) );
    mach_port_deallocate( mach_task_self(), self );
    return occupied;
}
static unsigned ios_tail_carve_n;
static pthread_mutex_t ios_tail_carve_lock = PTHREAD_MUTEX_INITIALIZER;

/* iOS-Madeira ml613: WHICH TAIL CARVE DOES THIS HOST PC LIVE IN, AND IS IT FREE?
 *
 * ml612's crash faulted at host pc 0x15361d6d0, which is +0x496d0 into the 16MB
 * carve 0x1535d4000 — a carve that had been FREEd and REUSEd THREE times in the
 * preceding ~400 log lines, the last reuse two lines before the fault. That is
 * the tail-recycling race (#74 family) with a much shorter fuse than a single
 * reuse would suggest, and the existing ios_tail_carve_occupied() guard cannot
 * see it: it samples only threads whose PC is inside the carve at the instant of
 * the free, so dormant return addresses, linked blocks, dispatch-cache entries
 * and threads that enter the old code LATER all slip through.
 *
 * ⚠️ TRYLOCK ONLY. This is called from the Mach exception path; blocking on
 * ios_tail_carve_lock there would deadlock against whichever thread is mid-carve
 * and holding it — exactly the thread most likely to be involved. A busy lock
 * returns -1 and the caller reports "lock busy" rather than lying or hanging.
 *
 * Returns 1 found, 0 not-in-any-carve, -1 lock busy. */
int ios_tail_carve_lookup_trylock( unsigned long long rx_addr, unsigned *idx_out,
                                   unsigned long long *base_out, unsigned long long *size_out,
                                   int *free_out )
{
    uintptr_t rx_base = (uintptr_t)ios_jit_rx_base_global;
    unsigned i;
    int found = 0;

    if (!rx_base || rx_addr < rx_base) return 0;
    if (pthread_mutex_trylock( &ios_tail_carve_lock ) != 0) return -1;
    for (i = 0; i < ios_tail_carve_n; i++)
    {
        uintptr_t lo = rx_base + ios_tail_carves[i].off;
        uintptr_t hi = lo + ios_tail_carves[i].size;
        if (rx_addr >= lo && rx_addr < hi)
        {
            if (idx_out)  *idx_out  = i;
            if (base_out) *base_out = (unsigned long long)lo;
            if (size_out) *size_out = (unsigned long long)ios_tail_carves[i].size;
            if (free_out) *free_out = ios_tail_carves[i].free;
            found = 1;
            break;
        }
    }
    pthread_mutex_unlock( &ios_tail_carve_lock );
    return found;
}

/* Exported JIT pool addresses for use by SIGBUS handler in signal_arm64_ios.c */
/* ml251: does anything MUNMAP/MMAP inside the JIT pool's VA?
 *
 * Two pool symptoms share one explanation and neither goes through mprotect_exec (which
 * logged ZERO pool calls): isolated single-page RW regions (poison, max=3 forever) and
 * MEM_FREE holes inside the pool span -- the latter is what the fatal CASPAL targets
 * (0x1541af700, state=MEM_FREE), i.e. a use-after-free of pool memory that ends runs.
 * Both are what you get if Wine's allocator believes pool VA is free and maps/unmaps
 * there. Guest PE images already share the 0x1xxxxxxxx band with the pool, so this is
 * plausible rather than speculative. Report any such call, with its caller tag. */
void ios_pool_va_warn( const char *who, const void *addr, size_t size )
{
    extern void *ios_jit_rx_base_global;
    extern void *ios_jit_rw_base_global;
    extern size_t ios_jit_pool_size_global;
    uintptr_t a = (uintptr_t)addr, rx = (uintptr_t)ios_jit_rx_base_global;
    uintptr_t rw = (uintptr_t)ios_jit_rw_base_global;
    size_t ps = ios_jit_pool_size_global;
    static int warned;

    if (!ps || warned >= 40) return;
    if (rx && a < rx + ps && a + size > rx)
    {
        warned++;
        dprintf( 2, "[pool-va] %s addr=%p size=0x%lx INSIDE RX pool off=0x%lx  <== foreign map/unmap\n",
                 who, addr, (unsigned long)size, (unsigned long)(a - rx) );
    }
    else if (rw && a < rw + ps && a + size > rw)
    {
        warned++;
        dprintf( 2, "[pool-va] %s addr=%p size=0x%lx INSIDE RW pool off=0x%lx  <== foreign map/unmap\n",
                 who, addr, (unsigned long)size, (unsigned long)(a - rw) );
    }
}

void *ios_jit_rx_base_global = NULL;
void *ios_jit_rw_base_global = NULL;
size_t ios_jit_pool_size_global = 0;
unsigned long long ios_last_footprint_mb = 0;   /* ml668: latest phys_footprint MB (decl above) */
int ios_fast_footprint = 0;                    /* ml670: set when d3d11 loads */

/* TEB restore trampoline in JIT pool.
 * iOS sigreturn does NOT restore x18 from the ucontext — it always zeroes
 * the platform register. So we can't fix x18 via signal handler return.
 * Instead, we write a small trampoline in the JIT pool (executable memory)
 * that loads x18 from a fixed location and jumps to the saved target.
 *
 * Per-thread trampoline slots in the reserved first page (0x4000 bytes):
 *   slot N at offset N*16:
 *     +0:  .quad TEB_address           (8 bytes)
 *     +8:  ldr x18, [pc, #-8]          (4 bytes) — 0x58FFFFD2
 *     +12: br x17                      (4 bytes) — 0xD61F0220
 *
 * Each Wine "process" thread gets its own slot with its own TEB address.
 * Slot 0 is the default (backward compatible with ios_jit_teb_trampoline).
 * Max 256 slots in one 16KB page (256 * 16 = 4096, well within 0x4000).
 *
 * Usage: SEGV/Mach handler sets x17 = target_PC, PC = thread's trampoline.
 * Trampoline runs: loads x18 = thread's TEB, jumps to x17 = target PC.
 */
void *ios_jit_teb_trampoline = NULL;  /* RX address of slot 0 trampoline (offset 8) */
#define IOS_JIT_TRAMPOLINE_SIZE 16    /* Bytes per trampoline slot */
#define IOS_JIT_MAX_SLOTS 256         /* Max threads with trampolines */
static volatile int32_t ios_jit_next_slot = 0;  /* Next slot to allocate */

/* Allocate a per-thread trampoline slot. Returns slot index (0-based). */
int ios_jit_alloc_trampoline_slot(void)
{
    int slot = __sync_fetch_and_add(&ios_jit_next_slot, 1);
    if (slot >= IOS_JIT_MAX_SLOTS) return 0;  /* fallback to slot 0 */

    /* Write trampoline code to this slot's RW view */
    if (ios_jit_rw_base_global)
    {
        char *rw = (char *)ios_jit_rw_base_global + slot * 16;
        uint32_t *code = (uint32_t *)(rw + 8);
        code[0] = 0x58FFFFD2;  /* ldr x18, [pc-8] */
        code[1] = 0xD61F0220;  /* br x17 */
        if (ios_jit_rx_base_global)
            sys_icache_invalidate((char *)ios_jit_rx_base_global + slot * 16 + 8, 8);
    }
    return slot;
}

/* Write TEB address to a specific trampoline slot */
void ios_jit_set_teb_slot(int slot, uintptr_t teb)
{
    if (ios_jit_rw_base_global && slot >= 0 && slot < IOS_JIT_MAX_SLOTS)
    {
        *(volatile uint64_t *)((char *)ios_jit_rw_base_global + slot * 16) = teb;
    }
}

/* Get RX address of a trampoline slot's executable code */
void *ios_jit_get_trampoline(int slot)
{
    if (ios_jit_rx_base_global && slot >= 0 && slot < IOS_JIT_MAX_SLOTS)
        return (char *)ios_jit_rx_base_global + slot * 16 + 8;
    return NULL;
}

/* Reverse of the JIT translation: pool alias → original PE VA. For the
 * thread-stack dumper — a wedged thread executing PE code shows JIT-pool
 * pcs that dladdr can't name; this recovers "PE module base + offset". */
uint64_t ios_jit_reverse_translate( uint64_t addr, uint64_t *module_base )
{
    int i;
    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        uint64_t jb = (uint64_t)(uintptr_t)ios_jit_mappings[i].jit_base;
        if (addr >= jb && addr < jb + ios_jit_mappings[i].size)
        {
            if (module_base) *module_base = (uint64_t)(uintptr_t)ios_jit_mappings[i].pe_base;
            return (uint64_t)(uintptr_t)ios_jit_mappings[i].pe_base + (addr - jb);
        }
    }
    if (module_base) *module_base = 0;
    return 0;
}

/* Callback registered by xtajit64 (via unix_ios_push_jit_aliases unix-call)
 * so future ios_jit_add_mapping calls automatically push aliases to FEX
 * too. Without this, late-loaded DLLs (e.g. dlopen after process init)
 * would have unregistered alias ranges and FEX would emit NoExecOp for
 * code in their copies. */
static void (*ios_jit_alias_pushback_cb)(unsigned long long, unsigned long long, unsigned long long) = NULL;

void ios_jit_add_mapping(void *pe_base, void *jit_base, size_t size)
{
    int i;

    /* Task #33: purge every entry whose PE range OVERLAPS the new image's.
     * A fresh PE image at [pe_base, pe_base+size) proves any overlapping
     * entry is STALE — two live images cannot occupy the same VA in the
     * single shared address space. The old module was unmapped (FreeLibrary
     * or pseudo-proc teardown) without this table hearing about it, and
     * mmap reused its VA. A surviving stale entry shadows the new one on
     * first-match: translate/sync_write of addresses in the overlap target
     * the DEAD pool copy (observed: CEF child's EC-ntdll dispatcher slot
     * synced into a dead copy while execution read the live copy's slot =
     * 0 → blr x16=0 null-exec storm). The old exact-pe_base dedupe was the
     * same disease — a LIVE image never reaches this call twice, because
     * mprotect_exec's already-copied check early-outs; only a stale entry
     * at the exact same VA could match, and returning kept translation on
     * the dead copy. Tombstone write order matches reclaim (size=0 first —
     * a zero-size entry matches no query — barrier, then pe_base=NULL) so
     * the lock-free readers never see a half-dead entry. */
    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        uintptr_t eb = (uintptr_t)ios_jit_mappings[i].pe_base;
        uintptr_t nb = (uintptr_t)pe_base;
        if (!ios_jit_mappings[i].pe_base) continue;
        if (eb < nb + size && nb < eb + ios_jit_mappings[i].size)
        {
            dprintf(2, "[jit-pool] STALE image mapping purged on add: pe=%p+0x%lx jit=%p owner=%p"
                    " (overlaps new image %p+0x%lx)\n",
                    (void *)eb, (unsigned long)ios_jit_mappings[i].size,
                    ios_jit_mappings[i].jit_base, ios_jit_mappings[i].owner_peb,
                    pe_base, (unsigned long)size);
            ios_jit_mappings[i].size = 0;
            __sync_synchronize();
            ios_jit_mappings[i].pe_base = NULL;
        }
    }

    /* Task #25: prefer a tombstoned slot (pe_base==NULL, left by pool
     * reclamation) — long multi-process sessions would otherwise exhaust
     * the table even though reclaim keeps freeing entries. Fields are
     * written before pe_base (the readers' match key), with a barrier. */
    {
        int slot = -1;
        for (i = 0; i < ios_jit_mapping_count; i++)
            if (!ios_jit_mappings[i].pe_base) { slot = i; break; }
        if (slot < 0)
        {
            if (ios_jit_mapping_count >= IOS_JIT_MAX_MAPPINGS)
            {
                /* dprintf, NOT ERR: this file's ERRs are on the `virtual` channel,
                 * which the app's perf-default WINEDEBUG mutes (err-virtual) — the
                 * 64-slot overflow of 2026-07-06 was invisible for exactly that
                 * reason. Overflow leaks raw PE addresses through
                 * ios_jit_translate_addr unchanged → unfixable exec-fault loop. */
                dprintf(2, "[jit-pool] mapping table FULL (%d slots) — image pe_base=%p jit_base=%p "
                        "WILL FAIL TO TRANSLATE (exec-fault loop incoming) — bump IOS_JIT_MAX_MAPPINGS!\n",
                        IOS_JIT_MAX_MAPPINGS, pe_base, jit_base);
                return;
            }
            slot = ios_jit_mapping_count;
        }
        ios_jit_mappings[slot].jit_base = jit_base;
        ios_jit_mappings[slot].size = size;
        ios_jit_mappings[slot].text_offset = 0;
        ios_jit_mappings[slot].text_size = 0;
        ios_jit_mappings[slot].pe_image_base = 0;
        ios_jit_mappings[slot].reloc_delta = 0;
        ios_jit_mappings[slot].reloc_rva = 0;
        ios_jit_mappings[slot].reloc_size = 0;
        ios_jit_mappings[slot].owner_peb = NULL;
        ios_jit_mappings[slot].machine_cached = 0;   /* ml349: slot reuse invalidates memo */
        ios_jit_mappings[slot].machine_valid = 0;
        __sync_synchronize();
        ios_jit_mappings[slot].pe_base = pe_base;
        if (slot == ios_jit_mapping_count) ios_jit_mapping_count++;
    }

    /* If xtajit64 has already registered its alias-mapping push callback
     * (via the unix_ios_push_jit_aliases unix-call), forward this new
     * mapping to it too. Early mappings (added before xtajit64 loads) are
     * picked up by the iteration in unix_ios_push_jit_aliases. */
    if (ios_jit_alias_pushback_cb)
        ios_jit_alias_pushback_cb((unsigned long long)(uintptr_t)pe_base,
                                  (unsigned long long)(uintptr_t)jit_base,
                                  (unsigned long long)size);
}

/* unix_ios_push_jit_aliases handler. Called from PE-side ntdll's
 * arm64ec_process_init_dispatchers after binding xtajit64's
 * BTCpu64IosAddAliasMapping. Stores the callback, then pushes all
 * currently-registered iOS JIT aliases through it. Future ios_jit_add_mapping
 * calls also push through the stored callback (see above). */
/* iOS-Madeira ml613: THIS MUST MATCH struct ios_push_jit_aliases_params IN
 * wine/dlls/ntdll/unixlib.h EXACTLY — ONE FIELD.
 *
 * ml549 added a second `rip_from_hostpc` member here but never added it to the
 * PE-side declaration, so `a->rip_from_hostpc` read a pointer-sized field PAST
 * the end of the caller's one-pointer struct and installed whatever happened to
 * follow it as a function pointer. Live undefined behaviour; it survived only
 * because every consumer is additionally gated on ios_fex_rip_resolved.
 *
 * ⛔ DO NOT "extend and version" this struct in place. An old one-field caller
 * gives the callee no way to discover whether bytes beyond it exist, so any
 * size/version field would itself be read out of bounds. If a richer ABI is
 * ever needed, add a NEW unix-call ordinal carrying its own size/version.
 *
 * Both FEX exports are now resolved by walking the already-mapped emulator
 * module at the end of this call instead of being passed in (see
 * ios_resolve_fex_exports). */
struct ios_push_jit_aliases_args {
    void (*callback)(unsigned long long, unsigned long long, unsigned long long);
};

/* ml549: consumed by the fault probes (srcwatch et al) so they can report the
 * instruction that actually executed instead of the block-granular RIP stored in
 * CpuStateFrame+0x18. NULL until xtajit64 binds, and on non-iOS/native paths. */
unsigned long long (*ios_fex_rip_from_hostpc_cb)(unsigned long long, unsigned long long) = NULL;
/* iOS-Madeira ml612: FEX's thread-exit lock-release hook (BTCpu64IosReleaseThreadHolds).
 * Resolved in ios_resolve_fex_exports alongside the exact-RIP export. */
unsigned int (*ios_fex_release_holds_cb)(unsigned long long *, unsigned int *, unsigned int *) = NULL;
/* ml551: set ONLY by a successful resolve. Never infer "resolved" from the pointer
 * being non-NULL -- ml550 found this global holding 0x6c6c642e65736162, i.e. the
 * ASCII "base.dll", so a non-NULL test both skipped the resolve AND let the fault
 * handler CALL a string as a function. That wild jump inside the Mach handler left
 * the srcwatch page protected, the guest's write never landed, and the window went
 * black -- we caused it. */
volatile int ios_fex_rip_resolved = 0;

/* ml549: resolve xtajit64's exact-RIP lookup WITHOUT touching PE-side ntdll.
 *
 * The obvious route (bind it in arm64ec_process_init_dispatchers and push the pointer
 * down) requires changing the unix-call struct, which changes an ABI shared with a
 * PREBUILT ntdll.dll -- an old ntdll would write one field while this side read two,
 * handing us a garbage pointer to call. Rebuilding that ntdll needs a strip+pad recipe
 * that is not in the tree, so this resolves the export here instead.
 *
 * Exact, no heuristics: ios_jit_mappings[] already records every mapped module's PE base
 * and size, and ios_pe_module_name() names them. Find the emulator module, walk its
 * export directory, done. Returns NULL (and says so) if anything is missing, so a failed
 * resolve can never be mistaken for "the lookup ran and found nothing". */
static void *ios_pe_find_export( const unsigned char *base, const char *want )
{
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)base;
    const IMAGE_NT_HEADERS64 *nt;
    const IMAGE_EXPORT_DIRECTORY *exp;
    const DWORD *names, *funcs;
    const WORD *ords;
    DWORD i, va, sz;

    if (!base || dos->e_magic != IMAGE_DOS_SIGNATURE) return NULL;
    nt = (const IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return NULL;
    va = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
    sz = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].Size;
    if (!va || !sz) return NULL;
    exp = (const IMAGE_EXPORT_DIRECTORY *)(base + va);
    names = (const DWORD *)(base + exp->AddressOfNames);
    ords  = (const WORD  *)(base + exp->AddressOfNameOrdinals);
    funcs = (const DWORD *)(base + exp->AddressOfFunctions);
    for (i = 0; i < exp->NumberOfNames; i++)
        if (!strcmp( (const char *)(base + names[i]), want ))
            return (void *)(base + funcs[ords[i]]);
    return NULL;
}

/* iOS-Madeira ml613: resolve BOTH FEX exports by walking the already-mapped
 * emulator module. Called at the END of unixcall_ios_push_jit_aliases — the
 * guaranteed initialization path — and RETRYABLE until it succeeds.
 *
 * ml612 hung the release-hook resolution off ios_resolve_fex_rip_lookup(), which
 * is only reached from a diagnostic path that did not run: ml612 shipped with
 * ios_fex_release_holds_cb permanently NULL, so its whole containment was inert
 * (verified — the run had zero [exact-rip] lines). Two rules come out of that:
 *
 *  1. Resolve on the path that ALWAYS runs, not on a probe's path.
 *  2. NEVER latch a failure. The old `static int tried` meant one early call
 *     before the module was mapped disabled resolution for the entire process
 *     lifetime. Now only success latches.
 *
 * Callbacks are published only after both lookups complete, and the resolved
 * flag is set LAST, so a concurrent reader either sees the old state or a fully
 * populated one — never a half-installed pair. */
void ios_resolve_fex_exports( void )
{
    int i;

    /* ml614: latch on the POINTERS, not on ios_fex_rip_resolved — that flag is
     * deliberately never set now (see below), so keying the early-out on it would
     * re-parse the PE export table on every call, and one caller is a fault path. */
    if (ios_fex_rip_from_hostpc_cb && ios_fex_release_holds_cb) return;  /* fully done */

    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        void *rip_cb, *rel_cb;
        const char *nm = ios_pe_module_name( ios_jit_mappings[i].pe_base,
                                             ios_jit_mappings[i].size );
        if (!nm) continue;
        if (!strstr( nm, "xtajit64" ) && !strstr( nm, "arm64ecfex" )) continue;

        rip_cb = ios_pe_find_export( ios_jit_mappings[i].pe_base, "BTCpu64IosRipFromHostPC" );
        rel_cb = ios_pe_find_export( ios_jit_mappings[i].pe_base, "BTCpu64IosReleaseThreadHolds" );

        /* Record the addresses for diagnostics. */
        if (rip_cb) ios_fex_rip_from_hostpc_cb = (void *)rip_cb;
        if (rel_cb) ios_fex_release_holds_cb = (void *)rel_cb;
        __sync_synchronize();

        /* ⛔⛔ ml614: DO NOT ARM ios_fex_rip_resolved.
         *
         * These are ARM64EC **PE** exports. They are NOT callable from this
         * (native Mach-O) code — their first bytes are the x64 entry thunk, which
         * a native `blr` fetches as ARM64 instructions. ml613 armed them and
         * crashed every single launch:
         *
         *   [xlate-exec] pc=0x71f99c4040 -> 0x125528040
         *   [av-detail]  hostpc=0x125528040 hinsn=0x48c48b48   (x64 `48 8b c4 48`)
         *   -> c0000005 in pthread_exit_wrapper, then c000001d
         *
         * ios_fex_rip_resolved gates the exact-RIP call in signal_arm64_ios.c.
         * That path had NEVER executed before ml613 (the old resolver was reached
         * only from a diagnostic entry point that never ran, and before that the
         * pointer came from an out-of-bounds struct read), so arming it was a new
         * live call, not a restoration.
         *
         * Re-arming requires EITHER a genuinely native ARM64 C-ABI bridge on FEX's
         * host side, OR making the call from code already running inside the
         * ARM64EC environment. Also PEB-key it first: this resolver latches the
         * FIRST libarm64ecfex.dll mapping globally, and there are several
         * pseudo-process instances in one Mach task. */
        dprintf( 2, "[fex-exports] ml614 module=%s base=%p rip_from_hostpc=%p release_holds=%p "
                    "(%s) -- RECORDED BUT NOT ARMED: EC PE exports are not callable "
                    "from native code (ml613 regression)\n",
                 nm, ios_jit_mappings[i].pe_base, rip_cb, rel_cb,
                 (rip_cb && rel_cb) ? "both found"
                                    : (rel_cb ? "release-only" : (rip_cb ? "rip-only" : "neither — will retry")) );
        return;
    }
    dprintf( 2, "[fex-exports] ml613 emulator module not in ios_jit_mappings (%d entries) "
                "-- will retry on the next alias push\n", ios_jit_mapping_count );
}

/* iOS-Madeira ml618: per-pseudo-process leaked-hold release callback.
 *
 * The pointer stored here MUST have come from the PE side's GET_PTR path
 * (arm64ec_redirect_ptr -> xlate_ios_jit), which yields an executable ARM64
 * alias in the JIT pool. ml613 stored a base+RVA pointer instead — the raw x64
 * entry thunk — and every launch died executing `48 8b c4 48...` as ARM64.
 * The PE side self-tests the pointer before registering it.
 *
 * PEB-keyed: several pseudo-processes share this Mach task, each with its own
 * FEX context and its own CodeInvalidationMutex. Using one global callback
 * would release against the wrong context. */
#define IOS_HOLD_RELEASE_MAX 32
static struct { void *peb; unsigned int (*cb)(void *, unsigned long long *, unsigned int *, unsigned int *); }
    ios_hold_release[IOS_HOLD_RELEASE_MAX];
static int ios_hold_release_n;

unsigned int (*ios_hold_release_lookup(void *peb))(void *, unsigned long long *, unsigned int *, unsigned int *)
{
    int i;
    for (i = 0; i < ios_hold_release_n; i++)
        if (ios_hold_release[i].peb == peb) return ios_hold_release[i].cb;
    return NULL;
}

struct ios_register_hold_release_args
{
    unsigned int size;
    unsigned int version;
    void *peb;
    void *callback;
};

NTSTATUS unixcall_ios_register_hold_release(void *args)
{
    struct ios_register_hold_release_args *p = args;
    int i;

    if (!p || p->size != sizeof(*p) || p->version != 1 || !p->peb || !p->callback)
    {
        dprintf(2, "[hold-release] ml618 REJECTED registration (size=%u want=%u version=%u peb=%p cb=%p)\n",
                p ? p->size : 0, (unsigned)sizeof(*p), p ? p->version : 0,
                p ? p->peb : NULL, p ? p->callback : NULL);
        return STATUS_INVALID_PARAMETER;
    }
    for (i = 0; i < ios_hold_release_n; i++)
        if (ios_hold_release[i].peb == p->peb)
        {
            ios_hold_release[i].cb = p->callback;
            dprintf(2, "[hold-release] ml618 re-registered peb=%p cb=%p slot=%d\n", p->peb, p->callback, i);
            return STATUS_SUCCESS;
        }
    if (ios_hold_release_n >= IOS_HOLD_RELEASE_MAX)
    {
        dprintf(2, "[hold-release] ml618 TABLE FULL (%d) — peb=%p will leak holds\n",
                ios_hold_release_n, p->peb);
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    ios_hold_release[ios_hold_release_n].peb = p->peb;
    ios_hold_release[ios_hold_release_n].cb  = p->callback;
    ios_hold_release_n++;
    dprintf(2, "[hold-release] ml618 registered peb=%p cb=%p (%d live)\n",
            p->peb, p->callback, ios_hold_release_n);
    return STATUS_SUCCESS;
}

NTSTATUS unixcall_ios_push_jit_aliases(void *args)
{
    /* ml613: the ml549 stash that used to live here read a->rip_from_hostpc, a
     * field the PE-side struct never declared — an out-of-bounds read. Deleted;
     * both exports are resolved from the mapped module at the end of this call. */
    struct ios_push_jit_aliases_args *params = args;
    int i;
    if (!params || !params->callback) return STATUS_INVALID_PARAMETER;
    ios_jit_alias_pushback_cb = params->callback;
    /* Drain current table to the callback. Child-owned copies are skipped:
     * they share pe_base with the parent entry and pushing both would
     * double-register the alias range in FEX (x86-64 children under FEX
     * will need per-process alias routing — deferred to S3). */
    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        if (ios_jit_mappings[i].owner_peb) continue;
        params->callback((unsigned long long)(uintptr_t)ios_jit_mappings[i].pe_base,
                         (unsigned long long)(uintptr_t)ios_jit_mappings[i].jit_base,
                         (unsigned long long)ios_jit_mappings[i].size);
    }
    /* ml613: the guaranteed init path — resolve both FEX exports here, where the
     * emulator module is certainly mapped, instead of from a diagnostic probe
     * (ml612's mistake) or from a dying thread inside pthread_exit (needlessly
     * risky: parsing exports while the thread holds FEX locks). */
    ios_resolve_fex_exports();
    ERR("unixcall_ios_push_jit_aliases: registered callback + drained %d mappings\n",
        ios_jit_mapping_count);
    return STATUS_SUCCESS;
}

/* ml630: returns 1 on success, 0 if no slot could be claimed. A caller that maps
 * new executable memory MUST NOT report success when this fails -- writes to that
 * range would then silently not route, which is exactly how the ULTRAKILL main
 * thread died. */
/* ============================ ml648 MONO BRIDGE ============================
 * See ios_mono_bridge.h for why this table is SEPARATE from IosAliasEntries.
 * Short version: Module.S's ios_ffs_xlate_loop rewrites control-flow targets
 * through that table, so a guest-RX -> RW pair in it would send calls into the
 * non-executable mapping. Only MonoBackpatcherWrite reads this one. */
#include "ios_mono_bridge.h"

struct ios_mono_bridge g_ios_mono_bridge = { .abi_version = 2 };  /* ml649: struct grew */

/* ml649: RUNTIME DIAGNOSTIC SWITCH.
 *
 * Default OFF (quiet/fast). The app toggles it live, which beats a separate
 * quiet build for the reason that matters to benchmarking: loud and quiet can
 * be compared inside ONE run, on the same scene at the same thermal state. Two
 * builds cannot give you that.
 *
 * ⚠️ Gate the WORK, not the PRINT. Several probes do an expensive read (Mach
 * calls, dual-map readback, hashing) and only then decide whether to format a
 * line; wrapping just the dprintf would save nothing. */
volatile int madeira_diag_enabled = 0;

void madeira_set_diag_enabled( int on )
{
    __atomic_store_n( &madeira_diag_enabled, on ? 1 : 0, __ATOMIC_RELAXED );
    /* Publish to FEX too — it is a separate PE and cannot see this global. */
    __atomic_store_n( &g_ios_mono_bridge.diag_enabled, on ? 1u : 0u, __ATOMIC_RELAXED );
    dprintf( 2, "[diag] ml649 diagnostics %s\n", on ? "ON" : "OFF (quiet)" );
}

int madeira_get_diag_enabled( void ) { return __atomic_load_n( &madeira_diag_enabled, __ATOMIC_RELAXED ); }

/* Faulting-thread registers are not trusted, and a probe must never fault
 * inside a fault. Every dereference on the capture path goes through here —
 * the same discipline the ml612 Floyd probe used. */
static int ios_safe_read64( uint64_t addr, uint64_t *out )
{
    mach_vm_size_t got = 0;
    if (addr < 0x1000 || (addr & 7)) return -1;
    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)addr,
                                8, (mach_vm_address_t)out, &got ) != KERN_SUCCESS)
        return -1;
    return got == 8 ? 0 : -1;
}

/* Sequence-lock publication. Live entries carry an ODD generation; the writer
 * bumps to EVEN first so any concurrent reader rejects the entry while its
 * fields are in flux, then bumps to ODD once they are settled. A reader that
 * samples the generation, reads, and samples again accepts only when both
 * samples are equal and odd — so a retired-and-reused slot can never be
 * mistaken for a live one, which is the case that would corrupt guest memory. */
void ios_mono_alias_publish( uint64_t guest_rx, uint64_t host_rw, uint64_t size )
{
    struct ios_mono_bridge *b = &g_ios_mono_bridge;
    unsigned int i, count = __atomic_load_n( &b->alias_count, __ATOMIC_ACQUIRE );

    for (i = 0; i < count; i++)
    {
        if (b->aliases[i].guest_rx != guest_rx) continue;
        __atomic_add_fetch( &b->aliases[i].generation, 1, __ATOMIC_RELEASE );   /* -> even, readers miss */
        b->aliases[i].host_rw = host_rw;
        b->aliases[i].size    = size;
        __atomic_add_fetch( &b->aliases[i].generation, 1, __ATOMIC_RELEASE );   /* -> odd, live again */
        return;
    }
    if (count >= IOS_MONO_MAX_ALIASES) return;   /* full: miss, never overwrite */

    b->aliases[count].guest_rx = guest_rx;
    b->aliases[count].host_rw  = host_rw;
    b->aliases[count].size     = size;
    __atomic_store_n( &b->aliases[count].generation, 1, __ATOMIC_RELEASE );     /* odd = live */
    __atomic_store_n( &b->alias_count, count + 1, __ATOMIC_RELEASE );
}

void ios_mono_alias_retire( uint64_t guest_rx )
{
    struct ios_mono_bridge *b = &g_ios_mono_bridge;
    unsigned int i, count = __atomic_load_n( &b->alias_count, __ATOMIC_ACQUIRE );

    for (i = 0; i < count; i++)
    {
        if (b->aliases[i].guest_rx != guest_rx) continue;
        if (b->aliases[i].generation & 1)
            __atomic_add_fetch( &b->aliases[i].generation, 1, __ATOMIC_RELEASE ); /* -> even, dead */
        return;
    }
}

/* Handed to FEX once, PE->unix via WINE_UNIX_CALL — the safe direction. The
 * reverse (native calling an ARM64EC export) is what killed every ml613 launch. */
NTSTATUS unixcall_ios_mono_bridge_ptr( void *args )
{
    /* ml648: publish the FEX code range HERE, not from FEX — this side owns the
     * JIT pool and knows its exact bounds. The Mach handler uses it to reject an
     * implausible BlockBegin BEFORE dereferencing it; if the pool is not up yet
     * the range stays 0, which disables that check rather than inventing one. */
    {
        extern void *ios_jit_rx_base_global;
        extern size_t ios_jit_pool_size_global;
        if (ios_jit_rx_base_global && ios_jit_pool_size_global)
        {
            g_ios_mono_bridge.code_lo = (uint64_t)ios_jit_rx_base_global;
            g_ios_mono_bridge.code_hi = (uint64_t)ios_jit_rx_base_global + ios_jit_pool_size_global;
        }
    }
    *(uint64_t *)args = (uint64_t)&g_ios_mono_bridge;
    /* ml648 LIVENESS, one line, once. Without it a quiet run cannot be told
     * apart from a dead one: "no qualifying SWPAL happened" and "the bridge was
     * never wired up at all" look identical in the log. Absence of a probe
     * string is not absence of the failure. FEX prints the companion lines once
     * it has published the offsets and once it arms Mono. */
    {
        static int once;
        if (!once++)
            dprintf(2, "[mono-bridge] ml648 REGISTERED bridge=%p abi=%u code=[%p,%p) -- awaiting FEX"
                       " offsets (capture stays inert until mono_base is armed)\n",
                    (void *)&g_ios_mono_bridge, g_ios_mono_bridge.abi_version,
                    (void *)g_ios_mono_bridge.code_lo, (void *)g_ios_mono_bridge.code_hi);
    }
    return 0;
}

/* Capture, called from the Mach SWPAL path. Records RAW FACTS ONLY: no guest
 * RIP reconstruction, no opcode decode, no allocation, no formatting, no locks.
 * Every interpretation happens later at the FEX safe point where
 * ios_fex_rip_from_hostpc() already exists. */
void ios_mono_bridge_capture( uint64_t teb, uint64_t frame, uint64_t host_pc, uint64_t fault_addr )
{
    struct ios_mono_bridge *b = &g_ios_mono_bridge;
    uint64_t block_begin, context = 0;
    unsigned int i;

    /* Key by PEB, not by process-globals: pseudo-processes share one address
     * space, so a single slot would let one process's fault mark another's
     * block. TEB->PEB is at +0x60. Safe-read it — x18 came from a faulting
     * thread and is not trusted. */
    if (!teb || ios_safe_read64( teb + 0x60, &context ) || !context) return;

    /* Offsets unpublished => FEX has not initialised => capture disabled. The
     * safe default: never guess a struct layout inside a fault handler. */
    if (!b->off_inline_jit_block_header && !b->off_block_tail && !b->off_tail_rip) return;
    if (!b->mono_base) { __atomic_add_fetch( &b->n_reject_unarmed, 1, __ATOMIC_RELAXED ); return; }
    if (!frame)        { __atomic_add_fetch( &b->n_reject_no_frame, 1, __ATOMIC_RELAXED ); return; }

    /* frame + off = InlineJITBlockHeader. Read defensively; this pointer comes
     * from a register in a faulting thread and is not trusted. */
    if (ios_safe_read64( frame + b->off_inline_jit_block_header, &block_begin ) || !block_begin)
    { __atomic_add_fetch( &b->n_reject_bad_block, 1, __ATOMIC_RELAXED ); return; }
    /* Must look like a JIT block, or we would hand FEX a wild pointer. */
    if (b->code_lo && (block_begin < b->code_lo || block_begin >= b->code_hi))
    { __atomic_add_fetch( &b->n_reject_outside_code, 1, __ATOMIC_RELAXED ); return; }

    for (i = 0; i < IOS_MONO_MAX_CONTEXTS; i++)
    {
        struct ios_mono_pending *p = &b->pending[i];
        uint64_t owner = __atomic_load_n( &p->context, __ATOMIC_ACQUIRE );

        if (owner != context)
        {
            if (owner) continue;
            if (!__atomic_compare_exchange_n( &p->context, &owner, context, 0,
                                              __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE )) continue;
        }
        /* One-shot per context: state 2 means FEX already activated. */
        if (__atomic_load_n( &p->state, __ATOMIC_ACQUIRE )) return;

        p->block_begin = block_begin;
        p->host_pc     = host_pc;
        p->fault_addr  = fault_addr;
        __atomic_store_n( &p->state, 1, __ATOMIC_RELEASE );      /* publish last */
        __atomic_add_fetch( &b->n_captured, 1, __ATOMIC_RELAXED );
        return;
    }
}
/* ========================== end ml648 MONO BRIDGE ========================= */

int ios_jit_anon_alias_add(void *user_va, size_t size, void *jit_rw_alias)
{
    int idx = -1, i;

    /* Task #25: reuse slots cleared by pool reclamation (user_va==0) — FEX
     * children each add aliases and the 32-slot table used to only grow.
     * Serialized by the pool lock (adds are rare: CodeBuffer allocations).
     * Write user_va LAST — it's the match key for the lock-free readers. */
    pthread_mutex_lock( &ios_pool_lock );

    /* iOS-Madeira ml625: AN OVERLAPPING LIVE ENTRY IS STALE BY CONSTRUCTION.
     *
     * Two live mappings cannot own the same guest VA, but this table used to
     * APPEND duplicates and ios_jit_anon_alias_lookup() returns the FIRST match
     * -- i.e. the OLDEST, now-dead backing. In the ml624 ULTRAKILL run Mono's
     * code buffer 0x7040220000 was remapped three times onto fresh 16KB pool
     * slots (0xa574000/0xa578000/0xa57c000) while the live code and its
     * UNWIND_INFO sat in the original 0xa0dc000 slot. The table kept handing out
     * the original while the guest VA had been overwritten with zeroed pages, so
     * RtlVirtualUnwind2 read unwind version 0 and looped ~15.8M times until the
     * 8MB guest stack was gone.
     *
     * Replace the slot in place so the table can never describe two backings for
     * one VA. (The real fix is upstream -- the remap is now idempotent -- but this
     * keeps the invariant true even if some other path ever re-registers.) */
    for (i = 0; i < ios_jit_anon_alias_count; i++)
    {
        if (!ios_jit_anon_aliases[i].user_va) continue;
        if ((uintptr_t)user_va < ios_jit_anon_aliases[i].user_va_end &&
            ios_jit_anon_aliases[i].user_va < (uintptr_t)user_va + size)
        {
            dprintf(2, "[jit-alias] ml625 REPLACE overlapping entry %d: old %p..%p rw=%p -> new %p+0x%lx rw=%p\n",
                    i, (void *)ios_jit_anon_aliases[i].user_va,
                    (void *)ios_jit_anon_aliases[i].user_va_end,
                    (void *)ios_jit_anon_aliases[i].jit_rw_alias,
                    user_va, (unsigned long)size, jit_rw_alias);
            idx = i;
            break;
        }
    }

    if (idx < 0)
        for (i = 0; i < ios_jit_anon_alias_count; i++)
            if (!ios_jit_anon_aliases[i].user_va) { idx = i; break; }
    if (idx < 0)
    {
        if (ios_jit_anon_alias_count >= IOS_JIT_MAX_ANON_ALIASES) {
            pthread_mutex_unlock( &ios_pool_lock );
            ERR("iOS JIT: anon alias table full (%d)\n", ios_jit_anon_alias_count);
            dprintf(2, "[jit-pool] anon alias table FULL (%d slots) — writes to %p will NOT route! "
                       "live=%d tombstones=%d hiwater=%d rev=ml630\n",
                    IOS_JIT_MAX_ANON_ALIASES, user_va, ios_jit_anon_alias_live,
                    ios_jit_anon_alias_tombstones, ios_jit_anon_alias_hiwater);
            return 0;
        }
        idx = ios_jit_anon_alias_count;
    }
    ios_jit_anon_aliases[idx].user_va_end = (uintptr_t)user_va + size;
    ios_jit_anon_aliases[idx].jit_rw_alias = (uintptr_t)jit_rw_alias;
    ios_jit_anon_aliases[idx].jit_rx_alias = 0;  /* set via _set_rx */
    __sync_synchronize();
    /* ml648: retire the slot's previous occupant before it is overwritten, or a
     * stale guest_rx would keep resolving to an RW alias that no longer backs it. */
    if (ios_jit_anon_aliases[idx].user_va && ios_jit_anon_aliases[idx].user_va != (uintptr_t)user_va)
        ios_mono_alias_retire( ios_jit_anon_aliases[idx].user_va );
    ios_jit_anon_aliases[idx].user_va = (uintptr_t)user_va;
    ios_mono_alias_publish( (uintptr_t)user_va, (uintptr_t)jit_rw_alias, size );
    if (idx == ios_jit_anon_alias_count) ios_jit_anon_alias_count = idx + 1;
    else ios_jit_anon_alias_tombstones++;   /* reclaimed a retired slot */
    if (++ios_jit_anon_alias_live > ios_jit_anon_alias_hiwater)
        ios_jit_anon_alias_hiwater = ios_jit_anon_alias_live;
    {
        /* Periodic census so the ceiling is never a surprise again. */
        static int census_n;
        if (ios_jit_anon_alias_live == 1 || (ios_jit_anon_alias_live % 64) == 0 || census_n < 4) {
            census_n++;
            dprintf(2, "[jit-alias] ml630 census live=%d used_slots=%d cap=%d hiwater=%d tombstones=%d\n",
                    ios_jit_anon_alias_live, ios_jit_anon_alias_count,
                    IOS_JIT_MAX_ANON_ALIASES, ios_jit_anon_alias_hiwater,
                    ios_jit_anon_alias_tombstones);
        }
    }
    pthread_mutex_unlock( &ios_pool_lock );
    return 1;
}

/* iOS-Madeira ml625: is [user_va, user_va+size) ALREADY backed by a live anon
 * alias? Used to make the anonymous-RWX remap idempotent -- see the call site in
 * the mprotect(PROT_EXEC) path. Returns 1 and fills the aliases (offset-adjusted
 * for the requested base) when an existing entry fully covers the request. */
/* iOS-Madeira ml631: read-only alias probe for the PE-side fault reporter.
 * Pure lookup — takes no locks, mutates nothing, safe to call from a fault path. */
NTSTATUS unixcall_ios_jit_alias_probe( void *args )
{
    struct ios_jit_alias_probe_params *p = args;
    int n, i;

    if (!p || p->size < sizeof(*p)) return STATUS_INVALID_PARAMETER;
    p->rw = p->base = p->end = 0;

    n = ios_jit_anon_alias_count;
    for (i = 0; i < n; i++)
    {
        uintptr_t b = ios_jit_anon_aliases[i].user_va;
        if (!b) continue;
        if (p->addr < b || p->addr >= ios_jit_anon_aliases[i].user_va_end) continue;
        p->rw   = (unsigned long long)(ios_jit_anon_aliases[i].jit_rw_alias + (p->addr - b));
        p->base = (unsigned long long)b;
        p->end  = (unsigned long long)ios_jit_anon_aliases[i].user_va_end;
        p->write_gen = ios_alias_write_gen[i];
        p->written   = ios_alias_written[i];
        p->highest   = ios_alias_highest[i];
        p->rw_base   = (unsigned long long)ios_jit_anon_aliases[i].jit_rw_alias;
        p->rx_base   = (unsigned long long)ios_jit_anon_aliases[i].jit_rx_alias;
        p->slot      = (unsigned)i;
        break;
    }
    /* ml636: NOTHING CONTAINS addr — try an alias that ENDS exactly there.
     *
     * The ULTRAKILL fatal RIP is one-past a 64KB Mono buffer (twice consecutively,
     * relocated), so "the alias containing RIP" is empty BY CONSTRUCTION and the
     * ml635 telemetry could never fire for it. The interesting alias is the one
     * that ENDS there. */
    if (!p->base)
    {
        n = ios_jit_anon_alias_count;
        for (i = 0; i < n; i++)
        {
            if (!ios_jit_anon_aliases[i].user_va) continue;
            if (ios_jit_anon_aliases[i].user_va_end != p->addr) continue;
            p->base      = (unsigned long long)ios_jit_anon_aliases[i].user_va;
            p->end       = (unsigned long long)ios_jit_anon_aliases[i].user_va_end;
            p->rw        = (unsigned long long)ios_jit_anon_aliases[i].jit_rw_alias;
            p->write_gen = ios_alias_write_gen[i];
            p->written   = ios_alias_written[i];
            p->highest   = ios_alias_highest[i];
            p->rw_base   = (unsigned long long)ios_jit_anon_aliases[i].jit_rw_alias;
            p->rx_base   = (unsigned long long)ios_jit_anon_aliases[i].jit_rx_alias;
            p->slot      = (unsigned)i;
            p->at_end    = 1;
            break;
        }
    }
    /* ml639: how many LIVE entries claim this same end? Retires the "maybe the probe
     * matched a stale duplicate" hypothesis by measurement instead of by argument. */
    if (p->base)
    {
        n = ios_jit_anon_alias_count;
        for (i = 0; i < n; i++)
            if (ios_jit_anon_aliases[i].user_va &&
                ios_jit_anon_aliases[i].user_va_end == p->end) p->dup_end++;
    }
    return STATUS_SUCCESS;
}

/* iOS-Madeira ml632: does [user_va, +size) OVERLAP any live anon-JIT alias?
 * find_cover() asks for full containment; the mixed-mapping bug is precisely a
 * PARTIAL overlap, so it needs its own test. Returns 1 and reports the entry. */
int ios_jit_anon_alias_overlaps(void *user_va, size_t size, uintptr_t *base_out, uintptr_t *end_out)
{
    uintptr_t lo = (uintptr_t)user_va, hi = lo + size;
    int n = ios_jit_anon_alias_count, i;

    for (i = 0; i < n; i++)
    {
        uintptr_t b = ios_jit_anon_aliases[i].user_va, e;
        if (!b) continue;
        e = ios_jit_anon_aliases[i].user_va_end;
        if (lo < e && b < hi)
        {
            if (base_out) *base_out = b;
            if (end_out)  *end_out  = e;
            return 1;
        }
    }
    return 0;
}

int ios_jit_anon_alias_find_cover(void *user_va, size_t size, void **rw_out, void **rx_out)
{
    uintptr_t lo = (uintptr_t)user_va, hi = lo + size;
    int n = ios_jit_anon_alias_count;
    int i;

    for (i = 0; i < n; i++)
    {
        uintptr_t base = ios_jit_anon_aliases[i].user_va;
        if (!base) continue;
        if (lo < base || hi > ios_jit_anon_aliases[i].user_va_end) continue;
        if (!ios_jit_anon_aliases[i].jit_rx_alias) continue; /* incomplete registration */
        if (rw_out) *rw_out = (void *)(ios_jit_anon_aliases[i].jit_rw_alias + (lo - base));
        if (rx_out) *rx_out = (void *)(ios_jit_anon_aliases[i].jit_rx_alias + (lo - base));
        return 1;
    }
    return 0;
}

void ios_jit_anon_alias_set_rx(void *user_va, void *jit_rx_alias)
{
    int n = ios_jit_anon_alias_count;
    int i;
    for (i = 0; i < n; i++) {
        if ((uintptr_t)user_va == ios_jit_anon_aliases[i].user_va) {
            ios_jit_anon_aliases[i].jit_rx_alias = (uintptr_t)jit_rx_alias;
            return;
        }
    }
}

uintptr_t ios_jit_anon_alias_lookup(uintptr_t fault_addr)
{
    int n = ios_jit_anon_alias_count;
    int i;
    for (i = 0; i < n; i++) {
        if (fault_addr >= ios_jit_anon_aliases[i].user_va &&
            fault_addr <  ios_jit_anon_aliases[i].user_va_end) {
            return ios_jit_anon_aliases[i].jit_rw_alias +
                   (fault_addr - ios_jit_anon_aliases[i].user_va);
        }
    }
    return 0;
}

uintptr_t ios_jit_anon_alias_lookup_rx(uintptr_t fault_addr)
{
    int n = ios_jit_anon_alias_count;
    int i;
    for (i = 0; i < n; i++) {
        if (fault_addr >= ios_jit_anon_aliases[i].user_va &&
            fault_addr <  ios_jit_anon_aliases[i].user_va_end) {
            if (!ios_jit_anon_aliases[i].jit_rx_alias) return 0;
            return ios_jit_anon_aliases[i].jit_rx_alias +
                   (fault_addr - ios_jit_anon_aliases[i].user_va);
        }
    }
    return 0;
}

void ios_jit_set_reloc_info(void *pe_base, uint64_t pe_image_base, intptr_t delta,
                            unsigned int reloc_rva, unsigned int reloc_size)
{
    int i;
    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        if (ios_jit_mappings[i].pe_base == pe_base)
        {
            ios_jit_mappings[i].pe_image_base = pe_image_base;
            ios_jit_mappings[i].reloc_delta = delta;
            ios_jit_mappings[i].reloc_rva = reloc_rva;
            ios_jit_mappings[i].reloc_size = reloc_size;
            return;
        }
    }
}

void ios_jit_set_text_section(void *pe_base, size_t text_offset, size_t text_size)
{
    int i;
    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        if (ios_jit_mappings[i].pe_base == pe_base)
        {
            /* Keep the LARGEST executable section. ARM64EC PEs have both
             * .text (large, ARM64 native) and .hexpthk (small, x86_64
             * fast-forward thunks). The x18 patcher needs to walk .text. */
            if (text_size > ios_jit_mappings[i].text_size)
            {
                ios_jit_mappings[i].text_offset = text_offset;
                ios_jit_mappings[i].text_size = text_size;
            }
            return;
        }
    }
}

/* Check if a JIT pool address is within a .text (executable code) section */
int ios_jit_addr_is_text(uintptr_t addr)
{
    int i;
    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        uintptr_t jit_base = (uintptr_t)ios_jit_mappings[i].jit_base;
        size_t t_off = ios_jit_mappings[i].text_offset;
        size_t t_sz  = ios_jit_mappings[i].text_size;
        if (t_sz && addr >= jit_base + t_off && addr < jit_base + t_off + t_sz)
            return 1;
    }
    return 0;
}

/* Set the TEB address in a specific JIT pool trampoline slot (with logging) */
void ios_jit_set_teb(uintptr_t teb)
{
    /* Legacy: writes to slot 0 for backward compatibility */
    ios_jit_set_teb_slot(0, teb);
    if (ios_jit_rw_base_global)
    {
        uint64_t readback = ios_jit_rx_base_global ?
            *(volatile uint64_t *)ios_jit_rx_base_global : 0;
        ERR("ios_jit_set_teb: wrote 0x%lx to RW %p, readback from RX %p = 0x%lx %s\n",
            (unsigned long)teb, ios_jit_rw_base_global,
            ios_jit_rx_base_global, (unsigned long)readback,
            readback == teb ? "OK" : "MISMATCH!");
    }
    else
    {
        ERR("ios_jit_set_teb: rw_base is NULL, cannot write TEB 0x%lx!\n",
            (unsigned long)teb);
    }
}

/* S1 pseudo-processes: identify the current thread's "process" by its
 * TEB->Peb. The TEB is read from the same TSD slot the x18 trampolines
 * use (async-signal-safe — the SEGV redirect runs on the faulting thread),
 * with a pthread-key fallback for early boot before the slot offset is
 * known. NULL = unknown → resolves to parent/default mapping entries. */
void *ios_jit_current_peb(void)
{
    extern pthread_key_t ios_teb_tls_key;
    extern int ios_teb_tls_slot_offset;
    char *cur_teb = NULL;

    if (ios_teb_tls_slot_offset)
    {
        uintptr_t tsd_base;
        __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tsd_base));
        tsd_base &= ~7ULL;
        cur_teb = *(char **)(tsd_base + ios_teb_tls_slot_offset);
    }
    if (!cur_teb && ios_teb_tls_key) cur_teb = pthread_getspecific(ios_teb_tls_key);
    if (!cur_teb) return NULL;
    return ((TEB *)cur_teb)->Peb;
}

/* Owner-aware main-image machine (X3 mixed-mode); registry in loader_ios.c. */
USHORT ios_cur_image_info_machine(void)
{
    extern const SECTION_IMAGE_INFORMATION *ios_cur_image_info(void);
    return ios_cur_image_info()->Machine;
}

/* Translate a PE address to a JIT pool address for a specific process.
 * An entry owned by `owner_peb` wins; otherwise the NULL-owner (parent)
 * entry applies. Child processes only own copies of ntdll — every other
 * module resolves to the shared parent copy via the fallback. */
void *ios_jit_translate_addr_for_owner(void *addr, void *owner_peb)
{
    int i, fallback = -1, any_live = -1;
    uintptr_t a = (uintptr_t)addr;

    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        uintptr_t base = (uintptr_t)ios_jit_mappings[i].pe_base;
        if (a >= base && a < base + ios_jit_mappings[i].size)
        {
            if (ios_jit_mappings[i].owner_peb == owner_peb)
                return (void *)((uintptr_t)ios_jit_mappings[i].jit_base + (a - base));
            if (!ios_jit_mappings[i].owner_peb && fallback < 0) fallback = i;
            if (any_live < 0) any_live = i;
        }
    }
    if (fallback >= 0)
        return (void *)((uintptr_t)ios_jit_mappings[fallback].jit_base
                        + (a - (uintptr_t)ios_jit_mappings[fallback].pe_base));
    /* ml454 (#74): PE image ranges are globally unique in the single shared
     * address space — an entry CONTAINING the address IS the right copy even
     * when the caller's owner_peb doesn't match (observed: the renderer
     * thread's owner resolution missed for webhelper's xtajit64 copy and a
     * live in-range entry was refused → 65k-fault pass-through storm at the
     * GuestToHostMap dtor → the #74 lock re-entry chain).  The cross-copy
     * disease this owner check guards against needs a SAME-VA ambiguity,
     * which cannot exist here. */
    if (any_live >= 0)
    {
        static int xany_n;
        if (xany_n < 20)
        {
            xany_n++;
            dprintf(2, "[xlate-any] addr=%p owner=%p matched live entry pe=%p owner=%p (exact-owner miss) rev=ml454\n",
                    addr, owner_peb, ios_jit_mappings[any_live].pe_base,
                    ios_jit_mappings[any_live].owner_peb);
        }
        return (void *)((uintptr_t)ios_jit_mappings[any_live].jit_base
                        + (a - (uintptr_t)ios_jit_mappings[any_live].pe_base));
    }
    return addr;  /* Not in any mapping */
}

/* Translate a PE address to JIT pool address. Returns original if not mapped.
 * Owner-aware: resolves against the calling thread's process. */
void *ios_jit_translate_addr(void *addr)
{
    return ios_jit_translate_addr_for_owner(addr, ios_jit_current_peb());
}

/* IAT-range collector for the stale-pointer heal. The 2026-07-04 boot
 * breakage came from rewriting EVERY 8-byte slot holding the stale value
 * — that clobbered arm64x metadata slots whose consumers need PE VAs for
 * identity/range comparisons. IAT / delay-IAT slots hold nothing but call
 * targets, so restricting the rewrite to them is semantically safe (it's
 * the same transform the NtProtect-time IAT-sync applies). Headers are
 * read from the pool RW copy; RVAs are relocation-invariant. */
struct ios_iat_range { unsigned int rva, size; };

static int ios_collect_iat_ranges( const unsigned char *img, size_t img_size,
                                   struct ios_iat_range *out, int max_out )
{
    unsigned int e_lfanew, ndirs;
    const unsigned char *opt;
    const unsigned int *dir;
    int n = 0;

    if (img_size < 0x400 || img[0] != 'M' || img[1] != 'Z') return 0;
    e_lfanew = *(const unsigned int *)(img + 0x3c);
    if (e_lfanew < 0x40 || e_lfanew > img_size - 0x200) return 0;
    if (memcmp(img + e_lfanew, "PE\0\0", 4)) return 0;
    opt = img + e_lfanew + 24;
    if (*(const unsigned short *)opt != 0x20b) return 0;      /* PE32+ only */
    ndirs = *(const unsigned int *)(opt + 108);
    dir = (const unsigned int *)(opt + 112);                  /* {rva,size} pairs */

    /* Data directory 12: the IAT proper. */
    if (ndirs > 12 && dir[12*2] && dir[12*2+1] &&
        (size_t)dir[12*2] + dir[12*2+1] <= img_size && n < max_out)
    {
        out[n].rva = dir[12*2]; out[n].size = dir[12*2+1]; n++;
    }
    /* Directory 1: walk each import descriptor's FirstThunk array —
     * covers images whose dir-12 entry is absent or incomplete. */
    if (ndirs > 1 && dir[1*2] && dir[1*2] < img_size)
    {
        const unsigned char *desc = img + dir[1*2];
        while (desc + 20 <= img + img_size && n < max_out)
        {
            unsigned int oft = *(const unsigned int *)(desc + 0);
            unsigned int ft  = *(const unsigned int *)(desc + 16);
            if (!ft && !oft) break;
            if (ft && ft < img_size)
            {
                const uint64_t *t = (const uint64_t *)(img + ft);
                unsigned int cnt = 0;
                while ((const unsigned char *)(t + cnt + 1) <= img + img_size && t[cnt]) cnt++;
                if (cnt) { out[n].rva = ft; out[n].size = cnt * 8; n++; }
            }
            desc += 20;
        }
    }
    /* Directory 13: delay-load descriptors (ImportAddressTableRVA at +12). */
    if (ndirs > 13 && dir[13*2] && dir[13*2] < img_size)
    {
        const unsigned char *dd = img + dir[13*2];
        while (dd + 32 <= img + img_size && n < max_out)
        {
            unsigned int iat_rva = *(const unsigned int *)(dd + 12);
            unsigned int int_rva = *(const unsigned int *)(dd + 16);
            if (!iat_rva && !int_rva) break;
            if (iat_rva && iat_rva < img_size)
            {
                const uint64_t *t = (const uint64_t *)(img + iat_rva);
                unsigned int cnt = 0;
                while ((const unsigned char *)(t + cnt + 1) <= img + img_size && t[cnt]) cnt++;
                if (cnt) { out[n].rva = iat_rva; out[n].size = cnt * 8; n++; }
            }
            dd += 32;
        }
    }
    return n;
}

/* Self-heal one stale PE-VA pointer: rewrite IAT/delay-IAT slots in the
 * module-copy pool ranges that hold `stale_va` to its pool-VA equivalent.
 * Called from the heal scanner thread (signal_arm64_ios.c) for addresses
 * that exec-faulted 256+ times — i.e. values being BRANCHED to through
 * import slots the NtProtect-time IAT-sync missed (the two-cube DXMT
 * storm: child winemetal's pool IAT held the child EC ntdll's map VA for
 * __wine_unix_call → one Mach exception per Metal call). Scans only
 * registered module copies (never the FEX CodeBuffer tail). Writes go to
 * the RW alias; concurrent readers that still load the old value just
 * take one more fault-redirect, which is benign. */
int ios_jit_patch_stale_pointer(unsigned long long stale_va)
{
    int i, patched = 0;
    void *target = ios_jit_translate_addr_for_owner((void *)(uintptr_t)stale_va, NULL);
    if (!ios_jit_rw_base_global || !ios_jit_rx_base_global) return 0;

    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        /* Heal each pool range with ITS OWNER's translation: a stale
         * ntdll PE-VA inside a child-owned copy must point at the child's
         * copy, not the parent's. */
        void *range_target = ios_jit_translate_addr_for_owner(
            (void *)(uintptr_t)stale_va, ios_jit_mappings[i].owner_peb);
        uintptr_t pool_off = (uintptr_t)ios_jit_mappings[i].jit_base
                           - (uintptr_t)ios_jit_rx_base_global;
        unsigned char *rw_img = (unsigned char *)ios_jit_rw_base_global + pool_off;
        struct ios_iat_range ranges[64];
        int nr, r;
        if (range_target == (void *)(uintptr_t)stale_va) continue;
        nr = ios_collect_iat_ranges(rw_img, ios_jit_mappings[i].size, ranges, 64);
        for (r = 0; r < nr; r++)
        {
            uint64_t *p = (uint64_t *)(rw_img + ranges[r].rva);
            uint64_t *end = (uint64_t *)(rw_img + ranges[r].rva + (ranges[r].size & ~7u));
            for (; p < end; p++)
            {
                if (*p == stale_va)
                {
                    *p = (uint64_t)(uintptr_t)range_target;
                    patched++;
                }
            }
        }
    }
    /* Escalation (task #25 follow-through on the parked #23 "rewrote 0"
     * case): the DXMT unix-call storm pointer lives in a winecrt0-style
     * .data GLOBAL, not an IAT — the IAT-restricted pass finds nothing and
     * the same VA keeps costing one Mach exception per Metal call (118K+
     * observed; handler saturation = the desktop "freezes"). When the IAT
     * pass strikes out, scan each copy's data (whole image minus its known
     * .text) for the exact 8-byte value. Exact-match + the 256-fault
     * threshold that gates this function keep it far from the 2026-07-04
     * blind-rewrite failure mode. */
    /* Whole-.data exact-value scan+rewrite. DEFAULT-ON (2026-07-08:
     * confirmed NOT the cause of the Thumper menu→game freeze — that is
     * the pre-existing ~53.7s JIT-compile/debugger block, task #22, which
     * reproduced with this gated OFF). Set MADEIRA_NO_HEAL_ESCALATE=1 to
     * disable if a false-positive rewrite is ever suspected (it rewrites
     * ANY 8-byte word equal to the stale VA, a small coincidental-collision
     * risk on data-heavy x86 guests). */
    if (!patched && !getenv("MADEIRA_NO_HEAL_ESCALATE"))
    {
        for (i = 0; i < ios_jit_mapping_count; i++)
        {
            void *range_target = ios_jit_translate_addr_for_owner(
                (void *)(uintptr_t)stale_va, ios_jit_mappings[i].owner_peb);
            uintptr_t pool_off = (uintptr_t)ios_jit_mappings[i].jit_base
                               - (uintptr_t)ios_jit_rx_base_global;
            unsigned char *rw_img = (unsigned char *)ios_jit_rw_base_global + pool_off;
            size_t tx_start = ios_jit_mappings[i].text_offset;
            size_t tx_end   = tx_start + ios_jit_mappings[i].text_size;
            uint64_t *p   = (uint64_t *)rw_img;
            uint64_t *end = (uint64_t *)(rw_img + (ios_jit_mappings[i].size & ~(size_t)7));
            if (range_target == (void *)(uintptr_t)stale_va) continue;
            for (; p < end; p++)
            {
                size_t off = (size_t)((unsigned char *)p - rw_img);
                if (ios_jit_mappings[i].text_size && off >= tx_start && off < tx_end) continue;
                if (*p == stale_va)
                {
                    *p = (uint64_t)(uintptr_t)range_target;
                    patched++;
                }
            }
        }
        if (patched)
            fprintf(stderr, "[stale-heal] 0x%llx ESCALATED: rewrote %d data slot(s) outside IATs\n",
                    stale_va, patched);
    }
    /* fprintf, not ERR — the perf WINEDEBUG default mutes err+virtual and
     * this MUST stay visible (silent healing hid the 2026-07-04 boot
     * breakage). */
    fprintf(stderr, "[stale-heal] 0x%llx -> %p, rewrote %d slot(s)\n",
            stale_va, target, patched);
    return patched;
}

/* task #24 [term-stack]: map a guest PE VA to its module base + size so
 * the terminate-time stack dump can self-attribute return addresses. */
unsigned long long ios_jit_module_base_for_va(unsigned long long va, unsigned long long *size_out)
{
    int i;
    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        uintptr_t b = (uintptr_t)ios_jit_mappings[i].pe_base;
        if (va >= b && va < b + ios_jit_mappings[i].size)
        {
            if (size_out) *size_out = ios_jit_mappings[i].size;
            return b;
        }
    }
    return 0;
}

/* task #34 [x86-ptr]: is `va` a GUEST INSTRUCTION address — a pointer into the
 * executable section of an x86-64 module?
 *
 * The iat-sync rewrites every image-looking pointer to its pool copy. Three
 * cases hide behind that:
 *   - pointer to DATA (any module)      -> translating is CORRECT, the pool
 *                                          copy is the live one
 *   - pointer to ARM64EC code (0xAA64)  -> translating is CORRECT, EC calls
 *                                          must land in the pool copy
 *   - pointer to x86-64 code (0x8664)   -> translating is POISON. FEX must see
 *                                          the guest PE address; a pool address
 *                                          in guest control flow is the
 *                                          [rip-leak] death (ml95, ml100).
 * A first attempt used peb->EcCodeBitMap as the discriminator and reported
 * 100.0% "non-EC" — useless, because that bitmap reads 0 for plain data too,
 * so it lumped the correct case in with the poison one. Section bounds plus the
 * PE machine word separate them properly. */
static int ios_va_is_x86_code( uint64_t va )
{
    int i;

    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        uintptr_t b  = (uintptr_t)ios_jit_mappings[i].pe_base;
        size_t    sz = ios_jit_mappings[i].size;
        size_t    t_off, t_sz;
        uint64_t  off;
        const unsigned char *img;
        unsigned int e_lfanew;

        if (!b || sz < 0x40 || va < b || va >= b + sz) continue;

        t_off = ios_jit_mappings[i].text_offset;
        t_sz  = ios_jit_mappings[i].text_size;
        off   = va - b;
        if (!t_sz || off < t_off || off >= t_off + t_sz) return 0;   /* data, not code */

        /* ml349: the header read must be FAULT-SAFE — a mapping whose PE
         * header page is unmapped (freed private copy, decommitted image)
         * wedged the [x86-ptr] scan thread forever right here (ml348:
         * `ldr w1,[x0,#0x3c]` at 0x73e4a7003c, 8 identical faults, run
         * killed). Read once per mapping slot via mach_vm_read_overwrite and
         * memoize; ios_jit_add_mapping resets machine_valid on slot reuse.
         * Unreadable header → treat as non-x86 (translation stays on, which
         * is the correct behavior for EC/data and harmless for a dead copy). */
        (void)img; (void)e_lfanew;
        if (!ios_jit_mappings[i].machine_valid)
        {
            unsigned int lfanew = 0;
            unsigned short mach = 0;
            mach_vm_size_t got = 0;
            if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)(b + 0x3c), 4,
                                       (mach_vm_address_t)&lfanew, &got) != KERN_SUCCESS || got != 4
                || (size_t)lfanew + 6 > sz
                || mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)(b + lfanew + 4), 2,
                                          (mach_vm_address_t)&mach, &got) != KERN_SUCCESS || got != 2)
            {
                static int hdr_unreadable_n;
                if (hdr_unreadable_n < 8)
                    dprintf(2, "[x86-ptr] rev=ml349 mapping pe_base=%p+0x%lx header UNREADABLE"
                            " — classifying non-x86 (#%d)\n",
                            (void *)b, (unsigned long)sz, ++hdr_unreadable_n);
                mach = 0;
            }
            ios_jit_mappings[i].machine_cached = mach;
            ios_jit_mappings[i].machine_valid = 1;
        }
        return ios_jit_mappings[i].machine_cached == 0x8664;  /* IMAGE_FILE_MACHINE_AMD64 */
    }
    return 0;
}

/* [xlate-exec] forensics: which mapping's pool range contains `addr`, and
 * who owns it. Names the COPY a thread is executing (session vs child),
 * which reverse_translate alone can't — copies share PE VAs. */
void *ios_jit_pool_copy_owner(const void *addr, void **pe_base_out)
{
    int i;
    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        uintptr_t a = (uintptr_t)addr;
        uintptr_t jit_base = (uintptr_t)ios_jit_mappings[i].jit_base;
        if (a >= jit_base && a < jit_base + ios_jit_mappings[i].size)
        {
            if (pe_base_out) *pe_base_out = ios_jit_mappings[i].pe_base;
            return ios_jit_mappings[i].owner_peb;
        }
    }
    if (pe_base_out) *pe_base_out = NULL;
    return (void *)(uintptr_t)-1;  /* not in any pool mapping */
}

/* Reverse-translate a JIT pool address back to the original PE address.
 * Used when PE code passes ADRP-computed addresses to syscalls. */
void *ios_jit_reverse_translate_addr(const void *addr)
{
    int i;
    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        uintptr_t a = (uintptr_t)addr;
        uintptr_t jit_base = (uintptr_t)ios_jit_mappings[i].jit_base;
        if (a >= jit_base && a < jit_base + ios_jit_mappings[i].size)
        {
            return (void *)((uintptr_t)ios_jit_mappings[i].pe_base + (a - jit_base));
        }
    }
    return (void *)addr;  /* Not in any JIT mapping */
}

/* Sync data written to original PE .data section to JIT pool copy.
 * Called after unix-side code (e.g. load_ntdll_functions) writes to PE data
 * that the JIT pool code needs to read. */
void ios_jit_sync_write(void *addr, size_t size)
{
    int i, fallback = -1;
    uintptr_t a = (uintptr_t)addr;
    void *cur_peb = ios_jit_current_peb();

    /* Owner-aware: sync into the copy the CURRENT process's PE code reads
     * (child init syncs into the child's ntdll copy; parent boot into the
     * parent's). Falls back to the NULL-owner entry like translate does. */
    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        uintptr_t base = (uintptr_t)ios_jit_mappings[i].pe_base;
        if (a >= base && a < base + ios_jit_mappings[i].size)
        {
            if (ios_jit_mappings[i].owner_peb == cur_peb) { fallback = i; break; }
            if (!ios_jit_mappings[i].owner_peb && fallback < 0) fallback = i;
        }
    }
    if (fallback >= 0)
    {
        size_t off = a - (uintptr_t)ios_jit_mappings[fallback].pe_base;
        /* The JIT RW mapping is at ios_jit_rw_base_global + pool_offset.
         * The pool_offset = jit_base - jit_rx_base_global */
        uintptr_t pool_offset = (uintptr_t)ios_jit_mappings[fallback].jit_base
                              - (uintptr_t)ios_jit_rx_base_global;
        char *jit_rw_dest = (char *)ios_jit_rw_base_global + pool_offset + off;
        memcpy(jit_rw_dest, addr, size);
    }
}

/***********************************************************************
 *           ios_jit_patch_x18  (x18 → TPIDR_EL0 binary patcher)
 *
 * Scans a PE .text section for all ARM64 instructions that reference x18
 * and replaces each with a branch to a generated trampoline.
 * The trampoline reads TEB from TPIDR_EL0 (preserved by iOS across context
 * switches, unlike x18) and performs the original operation.
 *
 * This eliminates the "zero-page silent read" problem entirely — patched
 * code never touches x18, so iOS zeroing it has no effect.
 */

/* Check if an ARM64 instruction references x18 as a register operand.
 * Returns the role (which field contains x18) or 0 if no x18 reference. */
#define X18_ROLE_NONE 0
#define X18_ROLE_RN   1  /* bits[9:5] = base register for loads/stores/data-proc */
#define X18_ROLE_RM   2  /* bits[20:16] = second register (MOV, register offset) */
#define X18_ROLE_RT2  3  /* bits[14:10] = second register in LDP/STP */

static int ios_insn_x18_role(uint32_t insn)
{
    /* Quick reject: check if 18 appears in any relevant field */
    int rn = (insn >> 5) & 0x1f;
    int rm = (insn >> 16) & 0x1f;
    int rt2 = (insn >> 10) & 0x1f;
    if (rn != 18 && rm != 18 && rt2 != 18) return X18_ROLE_NONE;

    /* Classify instruction to verify the field is actually a register */
    uint32_t top8 = insn >> 24;
    uint32_t top11 = insn >> 21;

    /* LDR/STR (unsigned immediate) — top2=1x, [27:24]=x111, [29]=1 */
    if ((top8 & 0x3F) == 0x39 || (top8 & 0x3F) == 0x3D ||  /* 0b0011 1001, 0b0011 1101 */
        (top8 & 0x3F) == 0xB9 || (top8 & 0x3F) == 0xBD ||  /* 0b1011 1001, 0b1011 1101 */
        (top8 & 0x3F) == 0xF9 || (top8 & 0x3F) == 0xFD ||  /* 0b1111 1001, 0b1111 1101 */
        (top8 & 0x3F) == 0x79 || (top8 & 0x3F) == 0x7D)    /* 0b0111 1001, 0b0111 1101 */
    {
        if (rn == 18) return X18_ROLE_RN;
    }

    /* LDR/STR (register offset) — [29:27]=111, V=0, [25:24]=00, [21]=1,
     * [11:10]=10; size [31:30] and opc [23:22] are DON'T-CARES.
     * iOS-Madeira 2026-07-04: mask was 0x3E7/0x1C1 which demanded
     * insn[30]==0 AND insn[22]==0 — i.e. only 8/32-bit STORES matched.
     * Every register-offset LOAD off x18 (`ldrb w8,[x18,x8]` — win32u's
     * hottest TEB poll) went unpatched and cost one Mach fault per visit
     * whenever x18 was 0 (~14%% of game-thread samples once
     * UNIXCALL-DIRECT removed the constant x18 refresh). */
    if ((top11 & 0x1F9) == 0x1C1 && ((insn >> 10) & 3) == 2)
    {
        if (rn == 18) return X18_ROLE_RN;
        if (rm == 18) return X18_ROLE_RM;
    }

    /* LDR/STR (pre/post-indexed) — [31:21]=1x111000xx0 */
    if ((top11 & 0x3E7) == 0x1C0)
    {
        if (rn == 18) return X18_ROLE_RN;
    }

    /* LDP/STP (signed offset, pre/post-indexed) — [31:25]=x0101x01 or x0101x00 */
    if ((top8 & 0x3E) == 0x28 || (top8 & 0x3E) == 0x2C ||  /* x010 100x, x010 110x */
        (top8 & 0x3E) == 0xA8 || (top8 & 0x3E) == 0xAC ||  /* 1010 100x, 1010 110x */
        (top8 & 0x3E) == 0x68 || (top8 & 0x3E) == 0x6C)    /* 0110 100x, 0110 110x */
    {
        if (rn == 18) return X18_ROLE_RN;
        if (rt2 == 18) return X18_ROLE_RT2;
    }

    /* MOV (register) = ORR Rd, XZR, Rm — [31:21]=x01 0101 0000 */
    if ((top11 & 0x7FF) == 0x150 || (top11 & 0x7FF) == 0x550)
    {
        if (rm == 18) return X18_ROLE_RM;
    }

    /* ADD/SUB (immediate) — [31:24]=x00 10001 or x10 10001 */
    if ((top8 & 0x5F) == 0x11)
    {
        if (rn == 18) return X18_ROLE_RN;
    }

    /* ADD/SUB (register) — [31:24]=x00 01011 or x10 01011 */
    if ((top8 & 0x5F) == 0x0B)
    {
        if (rn == 18) return X18_ROLE_RN;
        if (rm == 18) return X18_ROLE_RM;
    }

    return X18_ROLE_NONE;
}

/* Replace x18 in an instruction with a different register */
static uint32_t ios_insn_replace_x18(uint32_t insn, int role, int scratch)
{
    switch (role)
    {
    case X18_ROLE_RN:  return (insn & ~(0x1f << 5)) | (scratch << 5);
    case X18_ROLE_RM:  return (insn & ~(0x1f << 16)) | (scratch << 16);
    case X18_ROLE_RT2: return (insn & ~(0x1f << 10)) | (scratch << 10);
    default:           return insn;
    }
}

/* Patch all x18 references in a PE .text section.
 * text_rw/text_rx: RW and RX views of the .text section
 * text_size: size of .text in bytes
 * tramp_rw/tramp_rx: RW and RX views of the trampoline area
 * tramp_size: available space for trampolines
 * Returns number of instructions patched. */
/* Literal-pool data map builder — see the guard comment in
 * ios_jit_patch_x18. Shared by the patcher and the trampoline-need
 * counter. Caller frees. NULL on alloc failure (callers degrade to the
 * unguarded pre-2026-07-07 behavior). */
static unsigned char *ios_x18_build_data_map( const char *text, size_t text_size )
{
    unsigned char *data_map = calloc( 1, text_size / 32 + 1 );
    if (!data_map) return NULL;
    for (size_t i = 0; i < text_size; i += 4)
    {
        uint32_t insn = *(const uint32_t *)(text + i);
        uint32_t top8 = insn >> 24;
        size_t lit_bytes;
        int64_t imm19;
        size_t tgt;
        switch (top8)
        {
        case 0x18: case 0x1C: case 0x98: lit_bytes = 4;  break;  /* LDR Wt/St, LDRSW */
        case 0x58: case 0x5C: case 0xD8: lit_bytes = 8;  break;  /* LDR Xt/Dt, PRFM  */
        case 0x9C:                       lit_bytes = 16; break;  /* LDR Qt           */
        default: continue;
        }
        imm19 = (int64_t)(int32_t)(insn << 8) >> 13;  /* sign-extend bits[23:5] */
        tgt = i + (size_t)(imm19 * 4);
        if (imm19 * 4 + (int64_t)i < 0 || tgt >= text_size) continue;
        for (size_t b = tgt; b < tgt + lit_bytes && b < text_size; b += 4)
            data_map[(b / 4) >> 3] |= 1 << ((b / 4) & 7);
    }
    return data_map;
}

/* Task #25: exact trampoline budget. The old callers reserved 100% of
 * .text for trampolines and used ~1% (894 patches × 28B ≈ 25KB against a
 * 2.2MB reservation for ntdll) — with per-child copies of every DLL that
 * waste was ~HALF the pool (4 apps hit 368/384MB). Count the actual
 * patch sites and size the reservation to fit. */
size_t ios_jit_x18_tramp_need( const char *text, size_t text_size )
{
    unsigned char *data_map = ios_x18_build_data_map( text, text_size );
    size_t need = 0;
    for (size_t i = 0; i < text_size; i += 4)
    {
        uint32_t insn = *(const uint32_t *)(text + i);
        if (data_map && (data_map[(i / 4) >> 3] & (1 << ((i / 4) & 7)))) continue;
        if (ios_insn_x18_role( insn ) != X18_ROLE_NONE) need += 32;
    }
    free( data_map );
    /* Slack: the patcher's per-site max is 32B; pad one page so a
     * count/patch drift (e.g. data_map alloc failing in one of the two
     * passes) can't run the patcher out of space. */
    return need + 0x1000;
}

int ios_jit_patch_x18(char *text_rw, char *text_rx, size_t text_size,
                       char *tramp_rw, char *tramp_rx, size_t tramp_size)
{
    size_t tramp_off = 0;
    int count = 0;
    int skipped = 0;
    int lit_skipped = 0;
    unsigned char *data_map = NULL;
    extern int ios_teb_tls_slot_offset;

    /* B/BL reach guard (Steam S3 run 11 root cause): imm26 spans ±128MB.
     * The patcher used to encode out-of-range tramp offsets silently
     * truncated mod 256MB → branches into untouched pool (the run 7-11
     * "poison pointer" crash family). The allocator now anchors tramp
     * ranges near the image; this guard makes an out-of-reach pair a hard
     * REFUSAL (unpatched x18 insns degrade to recoverable runtime faults,
     * a truncated branch is fatal). */
    {
        intptr_t d1 = (tramp_rx + tramp_size) - text_rx;
        intptr_t d2 = tramp_rx - (text_rx + text_size);
        if (d1 > 0x7C00000 || d1 < -0x7C00000 || d2 > 0x7C00000 || d2 < -0x7C00000)
        {
            dprintf(2, "[x18-tramp] REFUSED: tramp %p+0x%lx out of B/BL reach of text %p+0x%lx\n",
                    tramp_rx, (unsigned long)tramp_size, text_rx, (unsigned long)text_size);
            return 0;
        }
    }

    /* Literal-pool guard (2026-07-07, conhost boot-death): .text embeds
     * DATA — every syscall stub ends `ldr x16, <lit>; ldr x16,[x16]; blr
     * x16; ret; <8-byte slot address>`. The literal's VALUE depends on the
     * copy's pool base (DIR64-rebased), and for bases in 0x128xxxxxxx the
     * low word decoded as LDP with rt2=18 → the patcher stamped a branch
     * over the literal → the stub loaded a garbage dispatcher → BLR to
     * junk on the child's FIRST syscall. Pure address lottery; also
     * latent for session copies (image VAs 0x7fb9.../0x7ff9... make
     * 0xB9/0xF9-topped literals = LDR-class false matches).
     * Fix: pre-scan for LDR (literal) instructions and mark their target
     * words as data; never patch a data word. False LDR-literal decodes
     * (data that happens to look like one) only mark extra words as data
     * — an unpatched real instruction degrades to a recoverable runtime
     * fault, while a patched literal is fatal. Asymmetry favors skipping. */
    data_map = ios_x18_build_data_map( text_rw, text_size );

    /* Pass 0: retarget hand-written TEB-from-TSD reads.
     *
     * FEX's Module.S contains the same three-instruction sequence this
     * patcher emits, written by hand and assembled with a fixed slot:
     *
     *     mrs xN, TPIDRRO_EL0
     *     and xN, xN, #~7
     *     ldr xN, [xN, #<slot*8>]
     *
     * The slot is not knowable at assembly time -- it is whichever raw TSD
     * slot backs our pthread key in this process -- so rewrite the immediate
     * here, where the offset is already discovered and we are already editing
     * .text through its RW alias before it is ever executed.
     *
     * The triplet is matched in full and all three registers must agree, so a
     * stray LDR with a coincidental immediate cannot be hit. Literal-pool
     * words are excluded via data_map for the same reason as the x18 pass. */
    if (ios_teb_tls_slot_offset && text_size >= 12)
    {
        const uint32_t want_imm = (uint32_t)(ios_teb_tls_slot_offset / 8) << 10;
        static int announced;
        int found = 0, retargeted = 0;

        /* Liveness beacon: without it, "no retarget line" is ambiguous between
         * "the pass never ran" and "it ran and matched nothing" -- and the
         * first cut of this probe used ERR(), which is muted in this file, so
         * it could not report at all. */
        if (!announced)
        {
            announced = 1;
            dprintf(2, "[teb-tsd] retarget pass armed, offset=0x%x\n", ios_teb_tls_slot_offset);
        }

        for (size_t i = 0; i + 12 <= text_size; i += 4)
        {
            uint32_t i0, i1, i2;
            unsigned reg;

            if (data_map && (data_map[i / 4] || data_map[(i + 4) / 4] || data_map[(i + 8) / 4]))
                continue;

            i0 = *(uint32_t *)(text_rw + i);
            if ((i0 & 0xffffffe0) != 0xd53bd060) continue;      /* mrs xN, TPIDRRO_EL0 */
            reg = i0 & 0x1f;

            i1 = *(uint32_t *)(text_rw + i + 4);
            /* and xN, xN, #0xfffffffffffffff8 */
            if (i1 != (0x927df000u | (reg << 5) | reg)) continue;

            i2 = *(uint32_t *)(text_rw + i + 8);
            /* ldr xN, [xN, #imm12*8] -- same register throughout */
            if ((i2 & 0xffc003ff) != (0xf9400000u | (reg << 5) | reg)) continue;

            found++;
            if ((i2 & 0x003ffc00) == want_imm) continue;        /* already correct */

            *(uint32_t *)(text_rw + i + 8) = (i2 & ~0x003ffc00u) | want_imm;
            retargeted++;
        }

        /* Report whenever the module HAS such reads, so found>0/retargeted==0
         * (already correct) is distinguishable from found==0 (none present). */
        if (found)
            dprintf(2, "[teb-tsd] .text %p: found %d static TSD read(s), retargeted %d to offset 0x%x\n",
                    text_rx, found, retargeted, ios_teb_tls_slot_offset);
    }

    for (size_t i = 0; i < text_size; i += 4)
    {
        uint32_t insn = *(uint32_t *)(text_rw + i);
        int role;
        if (data_map && (data_map[(i / 4) >> 3] & (1 << ((i / 4) & 7))))
        {
            if (ios_insn_x18_role(insn) != X18_ROLE_NONE) lit_skipped++;
            continue;
        }
        role = ios_insn_x18_role(insn);
        if (role == X18_ROLE_NONE) continue;

        /* Determine scratch register — use x17 normally.
         * Avoid conflicts with instruction's other register operands. */
        int scratch = 17;
        int rt = insn & 0x1f;
        int rn = (insn >> 5) & 0x1f;
        int rm = (insn >> 16) & 0x1f;
        if (rt == 17 || rn == 17 || rm == 17) scratch = 16;
        /* Double-check: if both x16 and x17 are used, skip (extremely rare) */
        if (scratch == 16 && (rt == 16 || rn == 16 || rm == 16))
        {
            skipped++;
            continue;
        }

        /* Check trampoline space (max 6 instructions = 24 bytes per trampoline) */
        if (tramp_off + 24 > tramp_size)
        {
            ERR("x18 patcher: out of trampoline space at %d patches\n", count);
            break;
        }

        uintptr_t insn_rx = (uintptr_t)(text_rx + i);
        uintptr_t tramp_rx_addr = (uintptr_t)(tramp_rx + tramp_off);
        uintptr_t return_rx = insn_rx + 4;

        /* TEB load sequence (3 instructions, uses TPIDRRO_EL0 which iOS preserves):
         *   mrs xSCRATCH, TPIDRRO_EL0
         *   and xSCRATCH, xSCRATCH, #~7   (clear CPU number from low 3 bits)
         *   ldr xSCRATCH, [xSCRATCH, #SLOT_OFFSET]  (load TEB from TLS slot)
         */
        extern int ios_teb_tls_slot_offset;
        int slot_off = ios_teb_tls_slot_offset;

        /* Check if this is MOV xN, x18 (special case — load TEB directly into dest) */
        int is_mov_from_x18 = (role == X18_ROLE_RM) &&
            ((insn & 0xFFE0FFE0) == 0xAA0003E0) && rm == 18;

        if (is_mov_from_x18)
        {
            int rd = insn & 0x1f;
            /* mrs xRd, TPIDRRO_EL0 */
            *(uint32_t *)(tramp_rw + tramp_off) = 0xD53BD060 | rd;
            tramp_off += 4;
            /* and xRd, xRd, #~7 (immediate: 0xFFFFFFFFFFFFFFF8 = immr=0 imms=0x3C) */
            *(uint32_t *)(tramp_rw + tramp_off) = 0x927DF000 | (rd << 5) | rd;
            tramp_off += 4;
            /* ldr xRd, [xRd, #slot_off] */
            *(uint32_t *)(tramp_rw + tramp_off) = 0xF9400000 | ((slot_off / 8) << 10) | (rd << 5) | rd;
            tramp_off += 4;
        }
        else
        {
            /* Check trampoline space (7 instructions = 28 bytes) */
            if (tramp_off + 32 > tramp_size)
            {
                ERR("x18 patcher: out of trampoline space at %d patches\n", count);
                break;
            }
            /* str xSCRATCH, [sp, #-16]! */
            *(uint32_t *)(tramp_rw + tramp_off) = (scratch == 17) ? 0xF81F0FF1 : 0xF81F0FF0;
            tramp_off += 4;
            /* mrs xSCRATCH, TPIDRRO_EL0 */
            *(uint32_t *)(tramp_rw + tramp_off) = 0xD53BD060 | scratch;
            tramp_off += 4;
            /* and xSCRATCH, xSCRATCH, #~7 */
            *(uint32_t *)(tramp_rw + tramp_off) = 0x927DF000 | (scratch << 5) | scratch;
            tramp_off += 4;
            /* ldr xSCRATCH, [xSCRATCH, #slot_off] */
            *(uint32_t *)(tramp_rw + tramp_off) = 0xF9400000 | ((slot_off / 8) << 10) | (scratch << 5) | scratch;
            tramp_off += 4;
            /* Modified instruction with x18 replaced by scratch */
            *(uint32_t *)(tramp_rw + tramp_off) = ios_insn_replace_x18(insn, role, scratch);
            tramp_off += 4;
            /* ldr xSCRATCH, [sp], #16 */
            *(uint32_t *)(tramp_rw + tramp_off) = (scratch == 17) ? 0xF84107F1 : 0xF84107F0;
            tramp_off += 4;
        }

        /* Branch back to return address */
        intptr_t ret_delta = (intptr_t)return_rx - (intptr_t)(tramp_rx + tramp_off);
        *(uint32_t *)(tramp_rw + tramp_off) = 0x14000000 | ((ret_delta >> 2) & 0x3FFFFFF);
        tramp_off += 4;

        /* Patch original instruction: B <trampoline> */
        intptr_t fwd_delta = (intptr_t)tramp_rx_addr - (intptr_t)insn_rx;
        uint32_t b_insn = 0x14000000 | ((fwd_delta >> 2) & 0x3FFFFFF);
        *(uint32_t *)(text_rw + i) = b_insn;

        if (count < 2)
        {
            ERR("  patch[%d]: text+0x%lx orig=0x%08x → B 0x%08x delta=%ld slot_off=0x%x\n",
                count, (unsigned long)i, insn, b_insn, (long)fwd_delta, slot_off);
            /* Dump first trampoline instructions */
            size_t t_start = tramp_off - (is_mov_from_x18 ? 12 : 24) - 4; /* back to start */
            for (int d = 0; d <= (is_mov_from_x18 ? 3 : 6); d++)
                ERR("    tramp[%d]=0x%08x\n", d, *(uint32_t *)(tramp_rw + t_start + d * 4));
        }

        count++;
    }

    if (count > 0 || skipped > 0)
        ERR("x18 patcher: patched %d instructions (%d skipped), trampolines=%lu bytes\n",
            count, skipped, (unsigned long)tramp_off);
    /* dprintf, not ERR (err-virtual muted): literal words the x18 matcher
     * WOULD have clobbered — nonzero = a dodged conhost-class boot death. */
    if (lit_skipped)
        dprintf(2, "[x18-lit] %d literal-pool word(s) matched x18 patterns — skipped (data, not code)\n",
                lit_skipped);
    free( data_map );

    /* Verify: log first patched instruction's encoding */
    if (count > 0)
    {
        for (size_t i = 0; i < text_size; i += 4)
        {
            uint32_t insn = *(uint32_t *)(text_rw + i);
            if ((insn >> 26) == 5)  /* found a B instruction (our patch) */
            {
                int32_t imm26 = (int32_t)(insn & 0x3FFFFFF);
                if (imm26 & 0x2000000) imm26 |= (int32_t)0xFC000000;
                intptr_t delta = (intptr_t)imm26 << 2;
                ERR("  verify: text+0x%lx insn=0x%08x B delta=%ld target=%p tramp_rx=%p\n",
                    (unsigned long)i, insn, (long)delta,
                    (void*)((uintptr_t)(text_rx + i) + delta), (void*)tramp_rx);
                /* Check first trampoline instruction */
                ERR("  tramp[0]=0x%08x tramp[1]=0x%08x\n",
                    *(uint32_t *)tramp_rw, *(uint32_t *)(tramp_rw + 4));
                break;
            }
        }
    }

    return count;
}

#endif

struct preload_info
{
    void  *addr;
    size_t size;
};

struct reserved_area
{
    struct list entry;
    void       *base;
    size_t      size;
};

static struct list reserved_areas = LIST_INIT(reserved_areas);

struct builtin_module
{
    struct list  entry;
    unsigned int refcount;
    void        *handle;
    void        *module;
    char        *unix_path;
    void        *unix_handle;
};

static struct list builtin_modules = LIST_INIT( builtin_modules );

struct file_view
{
    struct wine_rb_entry entry;  /* entry in global view tree */
    void         *base;          /* base address */
    size_t        size;          /* size in bytes */
    unsigned int  protect;       /* protection for all pages at allocation time and SEC_* flags */
};

/* per-page protection flags */
#define VPROT_READ       0x01
#define VPROT_WRITE      0x02
#define VPROT_EXEC       0x04
#define VPROT_WRITECOPY  0x08
#define VPROT_GUARD      0x10
#define VPROT_COMMITTED  0x20
#define VPROT_WRITEWATCH 0x40
/* per-mapping protection flags */
#define VPROT_ARM64EC          0x0100  /* view may contain ARM64EC code */
#define VPROT_SYSTEM           0x0200  /* system view (underlying mmap not under our control) */
#define VPROT_PLACEHOLDER      0x0400
#define VPROT_FREE_PLACEHOLDER 0x0800

/* Conversion from VPROT_* to Win32 flags */
static const BYTE VIRTUAL_Win32Flags[16] =
{
    PAGE_NOACCESS,              /* 0 */
    PAGE_READONLY,              /* READ */
    PAGE_READWRITE,             /* WRITE */
    PAGE_READWRITE,             /* READ | WRITE */
    PAGE_EXECUTE,               /* EXEC */
    PAGE_EXECUTE_READ,          /* READ | EXEC */
    PAGE_EXECUTE_READWRITE,     /* WRITE | EXEC */
    PAGE_EXECUTE_READWRITE,     /* READ | WRITE | EXEC */
    PAGE_WRITECOPY,             /* WRITECOPY */
    PAGE_WRITECOPY,             /* READ | WRITECOPY */
    PAGE_WRITECOPY,             /* WRITE | WRITECOPY */
    PAGE_WRITECOPY,             /* READ | WRITE | WRITECOPY */
    PAGE_EXECUTE_WRITECOPY,     /* EXEC | WRITECOPY */
    PAGE_EXECUTE_WRITECOPY,     /* READ | EXEC | WRITECOPY */
    PAGE_EXECUTE_WRITECOPY,     /* WRITE | EXEC | WRITECOPY */
    PAGE_EXECUTE_WRITECOPY      /* READ | WRITE | EXEC | WRITECOPY */
};

static struct wine_rb_tree views_tree;
static pthread_mutex_t virtual_mutex;

static const UINT page_shift = 12;
static const UINT_PTR page_mask = 0xfff;
static const UINT_PTR granularity_mask = 0xffff;

#ifdef __aarch64__
static UINT_PTR host_page_size;
static UINT_PTR host_page_mask;
#else
static const UINT_PTR host_page_size = 0x1000;
static const UINT_PTR host_page_mask = 0xfff;
#endif

/* Note: these are Windows limits, you cannot change them. */
#if defined(__i386__) || defined(__x86_64__)
static void *address_space_start = (void *)0x110000; /* keep DOS area clear */
#elif defined(WINE_IOS)
static void *address_space_start = (void *)0x100010000; /* above iOS 4GB __PAGEZERO */
#else
static void *address_space_start = (void *)0x10000;
#endif
#ifdef _WIN64
static void *address_space_limit = (void *)0x7fffffff0000;  /* top of the total available address space */
static void *user_space_limit    = (void *)0x7fffffff0000;  /* top of the user address space */

/* task #35 (ml105): FURNITURE CEILING — keep the top 16GB [0x7C00000000,
 * 0x8000000000) free of Wine furniture so PartitionAlloc's third 16GB pool can
 * land there. The ml96/ml105 census is deterministic: pools 1-2 take the 480G
 * and 464G slots (pool 2's guard-before layout also poisons the top 64KB of the
 * 448G slot, so evicting our RW alias would NOT help pool 3), and pool 3's
 * offset-0 slot walk tries 0x7C00000000 FIRST — it fails only because Wine's
 * top-down placement packs images/TEBs/stacks into [0x7e874c0000, top). Total
 * furniture there is ~6GB, and [0x7038000000, 0x73ffff0000) = 15.1GB is free to
 * hold it. Applied ONLY to kernel-pick placements smaller than 1GB with no
 * caller-imposed limits — jumbo reserves and explicit/fixed requests are
 * untouched. NOTE: the [reclaim-recover] data-fault band in signal_arm64_ios.c
 * watches this same [496G,512G) range for FEX arena recovery; if arenas move
 * below the ceiling, that band goes quiet — watch Thumper-under-pressure for a
 * regression and move the band with them if needed.
 *
 * ml106 REVISED: the first ceiling (0x7C00000000, 1GB size gate) backfired two
 * ways. (1) Furniture packed top-down to JUST under the ceiling, so the last
 * 64KB below 0x7C00000000 was always occupied and the 480G slot's top was
 * poisoned. (2) A 4GB guard-style tenant that does NOT go through
 * NtAllocateVirtualMemory (absent from the [jumbo#] census; likely a section
 * view or similar) landed at [0x7effff0000, 0x7fffff0000) and broke the 496G
 * slot. Result: ONE pool instead of two, chrome_elf died earlier. Fix: ceiling
 * at 464G-64KB so the guard pool's under-boundary bite lands on free space, and
 * a 16GB size gate so the 4GB tenant is clamped below too. Leaves
 * [0x73ffff0000, 0x8000000000) = 3 slots + guard margin exclusively for the
 * three PartitionAlloc pools.
 *
 * ml107-ml109 DISABLED (= 0): with the ceiling active, EVERY x64 EC child dies
 * at boot — Steam's children AND Thumper's (ml109: the baseline regressed from
 * 2s-to-splash to ~1min then app death). Mechanism fully identified: some FEX
 * boot-path error fires under the new layout → FEX LogMan::Msg::MFmtImpl
 * formats the message → FEXCore::Allocator::aligned_alloc returns NULL on that
 * thread (rpmalloc not thread-initialized) → unchecked memmove(NULL, msg, len)
 * → c0000005 in ntdll memcpy rva 0x5a4d4 (disassembly-confirmed at FEX rva
 * 0x10bd48). The crash is the LOGGER; the actual FEX complaint is unknown and
 * unknowable until the logger survives allocation failure. PREREQUISITE to
 * re-enabling: patch FEX's MFmtImpl to drop the message on alloc failure (or
 * fix rpmalloc thread-init on wine loader threads), THEN re-enable to read
 * what FEX is actually objecting to. The packing geometry itself (ceiling
 * 464G-64K + direction-aware walk) remains correct on paper.
 *
 * ml110 RE-ENABLED: the prerequisite landed — FEXCore AllocatorHooks now
 * lazily rpmalloc_thread_initialize at every hook (EnsureThreadHeap), so the
 * logger survives on uninitialized threads. Thumper verified clean on the new
 * FEX (ml110: ~10k frames, 0 faults) with the ceiling still off. This build
 * turns the ceiling back on: either the FEX objection was a non-fatal warning
 * and the three pools finally land, or the message prints and names it.
 *
 * ml120 THE ARITHMETIC CAME IN, AND 3 POOLS DO NOT FIT. Measured at the moment
 * PartitionAlloc asked:
 *   FREE 0x747fff0000..0x7800000000 = 14336 MB   (slot#0 poisoned from its base)
 *   FREE 0x7c00000000..0x8000000000 = 16384 MB   (slot#2 pristine)
 * and the 15.1GB furniture window was CONSUMED ENTIRELY -- absent from the free
 * list. The occupied run begins at exactly 0x73ffff0000, this ceiling: once the
 * window filled, the advisory relax valve handed out the next-lowest free
 * addresses, which march straight up into slot#0 (64 regions x ~32MB = 2GB).
 * So the valve that stops us dying is also what poisons the slots, and the
 * furniture demand for Steam is >15GB (~17GB and climbing) rather than the
 * ~6GB the ml105 census suggested. 48GB of pools + 17GB of furniture = 65GB in
 * a 63GB window: THREE POOLS ARE ARITHMETICALLY IMPOSSIBLE unless furniture
 * demand is cut, and whether it can be cut is unknown until we know what is in
 * those 15GB (see ios_window_inventory).
 *
 * Pool #2 additionally failed for a 64KB reason: PA's guard-style pool asks for
 * 0x400010000 = 16GB + 64KB, and slot#2 is EXACTLY 16GB with the top of the
 * address space above it, so the guard cannot overhang. A guard pool can only
 * sit at a slot that has 64KB free BELOW it.
 *
 * ml121 THEREFORE TARGETS TWO POOLS, DETERMINISTICALLY, instead of three
 * accidentally. Raising the ceiling to 0x77ffff0000 gives furniture
 * [0x7038000000, 0x77ffff0000) = 31GB (the 15GB it demonstrably needs plus 16GB
 * of headroom, so the relax valve should never fire and never poison anything),
 * and reserves [0x77ffff0000, 0x8000000000) = 32GB + 64KB, which fits exactly:
 *   guard pool -> 0x7800000000 with its 64KB overhang at 0x77ffff0000
 *   plain pool -> 0x7c00000000, exactly 16GB to the top of VA
 * That is the maximum this address space can hold, and it is 2x what ml120
 * achieved. Whether CEF runs on two pools is the next question; three needs a
 * furniture reduction that ios_window_inventory has to justify first.
 *
 * ml124 THIRD POOL BACK ON THE TABLE. The [window] run/tag probe named the
 * tenants at last: ~30 reservations of ~511MB (one per guest thread, 31 live)
 * = 15.4GB, plus ONE 4.06GB read-only run = the ARM64EC code bitmap, which was
 * sized for Windows' 128TB address space instead of iOS's 512GB. Sizing that
 * bitmap from host_addr_space_limit (see alloc_arm64ec_map) drops it 4.06GB ->
 * 16MB, taking furniture from 17.8GB to ~13.7GB -- under the 15.1GB that fits
 * below 0x7400000000. So the ceiling comes back down to 0x73ffff0000 and slot#0
 * is free again, giving the guard pool [0x73ffff0000, 0x7800000000) (its 64KB
 * overhang landing exactly on the ceiling, which is exclusive for furniture)
 * and the two plain pools 0x7800000000 and 0x7c00000000. Three pools.
 *
 * MARGIN IS THIN AND DOES NOT SCALE: 15.1 - 13.7 = ~1.4GB, and every further
 * guest thread costs ~512MB, so roughly three more threads exhausts it. Watch
 * [slot#0] -- if it goes DIRTY the relax valve has spilled into the pool slot
 * again and the per-thread FEX LookupCache reservation is the next thing that
 * has to shrink. */
/* ml125 REVERTED TO 0x77ffff0000. The 3-pool geometry was tried and FAILED:
 * with the window at 15.1GB, furniture (which the ml124 snapshot underestimated
 * — it keeps growing after the jumbo-failure moment it was measured at) filled
 * it to 99.5% (15403 of 15488 MB), the relax valve spilled into slot#0 AND
 * slot#1, the extra pressure revived the #34 pool exec-fault, and it stormed
 * 7.26 MILLION times. CEF never reached PartitionAlloc at all — strictly worse
 * than the 2-pool runs. The EC-bitmap reclaim is KEPT (it is a real 4GB and
 * gives this 31GB window more headroom than ml123 had), but a third pool needs
 * the ~512MB-per-thread FEXCore LookupCache reservation to shrink first; VA
 * freed elsewhere just gets absorbed by furniture growth. */
static const ULONG_PTR ios_furniture_ceiling = 0x73ffff0000;   /* ml132: 3-pool geometry, now with ios_spill_cap bounding the downside */

/* ml168: running total of 256MB..1GB MEM_RESERVE grants, used ONLY as a pressure
 * signal for the steering valve in NtAllocateVirtualMemory. Steam/CEF makes 2 x
 * 512MB reserve-only allocations per guest thread and commits ~1% of them; by
 * thread 13 that is 13.8GB of the 15.1GB furniture window, maxgap collapses to
 * 28MB, the next 512MB reserve FAILS and the caller stores through the NULL
 * (`stp x8,x20,[x0]`, x0=0 -> c0000005, ml166).
 *
 * Attribution resisted six approaches (four RIP-based -> all landed inside
 * VirtualAlloc itself; the guest x64 CONTEXT is all-zero so there is NO guest
 * context, i.e. the caller is native; and the native stack's frame order is
 * provably inconsistent — LdrInitializeThunk appeared ABOVE the syscall stub —
 * so its libarm64ecfex hits mix live and stale frames). The flags also exclude
 * every FEX site: type=0x2000 lacks MEM_TOP_DOWN which
 * FEXCore::Allocator::VirtualAlloc unconditionally ORs, CallRetStack is
 * MEM_TOP_DOWN|PAGE_NOACCESS, and the iOS LookupCache path passes Commit=true.
 *
 * So stop trying to name the caller and fix the placement instead. */
static unsigned long long ios_bigres_reserved_total;

/* ml207: furniture-window PRESSURE LATCH.
 *
 * The big-reserve steer valve used to arm only at ios_bigres_reserved_total > 8GB, chosen
 * so a Thumper run (which never gets near it) keeps byte-identical placement. But the
 * usable furniture window is only ~16GB, so that gate hands FEX's 512MB per-thread arenas
 * the first 8GB of it before steering starts. ml207 measured 16 of 25 reserves (8GB)
 * landing INSIDE the window; ml206 38 of 50 (19GB). What follows is starvation: a 1MB
 * thread stack cannot be placed, FEX reports "Failed to mprotect last page of code buffer",
 * the thread dies and steam.exe exits(1) — the shallow runs that have been blocking
 * verification, at 22k unix calls instead of 46k.
 *
 * So arm on the SYMPTOM instead of a guessed constant: the [va-scan] probe already knows
 * when the window is tight. A healthy scan costs "a handful of tryfixed calls"; ml207
 * ground 22747 of them. Latching here means a healthy run never arms the valve (Thumper
 * placement is unchanged, which is the property the 8GB gate existed to protect) while a
 * starving one steers every subsequent arena out of the window from the moment it is
 * genuinely tight. */
static int ios_va_pressure;

/* ml116 ROOT CAUSE of the ceiling regressions (disassembly + code-path proof,
 * no device run needed):
 *
 * With the ceiling active, map_view's kernel-pick branch sees
 * end < host_addr_space_limit, which diverts EVERY anonymous placement off
 * anon_mmap_alloc (kernel picks, essentially never fails) and onto Wine's own
 * map_free_area linear scan. That scan starts at address_space_start =
 * 0x100010000 and mmap-tryfixed steps by align_mask+1 until it reaches the
 * first Wine view (~0x72a5000000): ~455GB of address space that the ml108 gap
 * walk PROVED holds no free gap at all (iOS __PAGEZERO + the xzone/GPU
 * reservation). At 64KB steps that is ~7.4 MILLION failing mach_vm_map calls
 * for ONE allocation -- the ml107/ml109 "2s-to-splash became ~1min then death"
 * regression, and the multi-minute Steam stalls. Worse, try_map_free_area
 * bails out returning NULL on any errno that is not EEXIST/ENOMEM, so the
 * grind can end in a silent STATUS_NO_MEMORY: that is the NULL rpmalloc
 * returned to FEXCore::Context::ContextImpl::CreateThread in ml116
 * (libarm64ecfex+0x16178 stp [x0=NULL], x0 = aligned_alloc(0x1000,0x2000)).
 *
 * The ceiling's packing geometry was never the problem -- its scan FLOOR was
 * never raised to match. Nothing below this floor is mappable, so scanning it
 * is pure waste; clamping both ends keeps the search inside the one real
 * window and restores O(1) placement. */
/* ml364: MUST equal 0x7000000000 + the JIT pool size (the pool's RW alias is
 * remapped at exactly 0x7000000000 by StikJITHelper.allocatePool, and the
 * first thing wine allocates — the USD page — lands AT this floor because it
 * is a kernel-pick with this scan clamp). Pool grew 896MB→1152MB after ml363
 * died on pool exhaustion (bump 858/896MB, freelist 0) at MSM depth, so the
 * floor moves 0x7038000000 → 0x7048000000 in lockstep. */
/* ml668: the floor is DERIVED now. It was a hardcoded constant that had to be
 * hand-paired with poolSizeMB (the comment above says so in bold), which makes
 * any pool-size experiment a two-edit change with a silent, ugly failure if you
 * forget the second one. Computing it from the pool the app actually allocated
 * removes that trap entirely. Falls back to the 896MB pairing until the pool
 * size is published, which is before any use site runs. */
static inline ULONG_PTR ios_usable_va_floor_get(void)
{
    size_t sz = ios_jit_pool_size_global;
    return (ULONG_PTR)0x7000000000ULL + (ULONG_PTR)(sz ? sz : (896ULL << 20));
}
#define ios_usable_va_floor (ios_usable_va_floor_get())

/* ml132 SPILL CAP — makes the 3-pool experiment SAFE to run.
 *
 * Measured: real Wine furniture is only 2130 MB; the other 11604 MB of the
 * window is steam.exe reserving 23 x 512MB and committing 8% of it
 * ([bigres-use] reserved=11776 committed=965). Total 13.4GB, which does fit the
 * 15.1GB below 0x7400000000 — but with ~1.7GB of margin, and every further
 * guest thread costs another 1GB. ml125 ran exactly this geometry and failed
 * hard: the advisory relax valve spilled past the ceiling into slot#0 AND
 * slot#1, poisoning the two pools that already worked, and the pressure then
 * revived the #34 exec fault into a 7.26M-fault storm.
 *
 * The valve must stay (it is what stops an allocation failure from killing the
 * process), but it does not need to be allowed to eat the PROVEN slots. Cap the
 * spill at the top of slot#0: overflow may consume [0x7400000000,0x7800000000)
 * — the third-pool slot, which is what we are speculating with — and never
 * touches 0x7800000000 or 0x7c00000000. Worst case we fall back to the known-good
 * two pools instead of losing all three. Bounded downside, so the experiment is
 * worth running. 0 disables. */
static const ULONG_PTR ios_spill_cap = 0x7800000000;

/* ml170: DEDICATED SLOT FOR STEERED RESERVES.
 *
 * The steering valve worked -- 12 x 512MB moved above the ceiling and furniture
 * occupancy fell 13758MB -> 10160MB, taking the run from 18770 to 37175 unix
 * calls (deepest yet). But it steered into ios_spill_cap = 0x7800000000, which is
 * PartitionAlloc's slot 2, so [soft-pool] COLLISION went 12 -> 43 and pools
 * granted dropped 4 -> 3. Give the steered ranges their OWN slot instead.
 *
 * The top slot is the right one to give up: the ml135 census measured real CEF
 * demand at 3 x 16GB, and slots 0-2 (0x7000000000/0x7400000000/0x7800000000)
 * cover exactly that, leaving [0x7C00000000, 0x8000000000) = 16GB for steering --
 * enough for the ~14GB of 512MB reserves this workload makes. */
static const ULONG_PTR ios_steer_slot = 0x7C00000000;

/* ml173 THREAD-AWARE RECLAMATION of steered reserves (task #35/#36).
 *
 * PROVEN LEAK, once the [bigfree] probe was fixed: releases DO happen (32 of them,
 * all type=0x8000 MEM_RELEASE with size=0 as the Windows contract requires) but every
 * one is small — 0x1000..0x200000. NOT ONE 512MB range is ever released. So the owner
 * reserves 2 x 512MB per guest thread at thread start, commits ~1%, and never frees;
 * the count tracks run length (23 -> 27 -> 55) and no fixed slot size can hold it.
 *
 * Reclaiming on THREAD DEATH is the one rule that is airtight: a dead thread can never
 * commit into its reservation again, so releasing it cannot race a live owner. That is
 * why this is preferred over recycling any zero-commit range (which can steal a live
 * thread's untouched reservation) or aliasing (unsound in general).
 *
 * ios_thread_died() is called from the pthread_exit path in thread_ios.c. */
#define IOS_STEER_MAX 256
/* iOS-Madeira ml312 (task #54): `inuse` is set the moment ANY allocation lands inside a steered
 * arena, and blocks reclamation of that arena forever after. See ios_steer_reclaim_dead(). */
static struct { uint64_t base; uint64_t size; unsigned tid; unsigned freed; unsigned inuse; } ios_steer[IOS_STEER_MAX];
static unsigned ios_steer_n;
static unsigned char ios_tid_dead[8192];   /* bitmap, indexed by wine tid */

void ios_thread_died( unsigned tid )
{
    if (tid < sizeof(ios_tid_dead) * 8) ios_tid_dead[tid >> 3] |= (1u << (tid & 7));
}

/* ml181 BUG FIX (mine). Wine thread ids are SMALL AND RECYCLED (0x74, 0x98, 0xbc ...).
 * ios_tid_dead marked a tid dead permanently, so once a tid was reused by a new thread
 * the bitmap still read "dead" and the next exhaustion would release that LIVE thread's
 * 512MB arena. Those arenas hold FEX's CpuStateFrame (it sits at base+0x1140 — ml174/ml181
 * both show CPUArea+0x30 pointing inside a steered range), so freeing one under a running
 * thread produces exactly the STATE==0 faults we are chasing. Clear the bit whenever the
 * tid proves itself alive by making a reservation. */
static void ios_thread_alive( unsigned tid )
{
    if (tid < sizeof(ios_tid_dead) * 8) ios_tid_dead[tid >> 3] &= ~(1u << (tid & 7));
}

static int ios_tid_is_dead( unsigned tid )
{
    if (tid >= sizeof(ios_tid_dead) * 8) return 0;
    return (ios_tid_dead[tid >> 3] >> (tid & 7)) & 1;
}

/* Release every steered range whose owning thread has exited. Returns bytes freed.
 * Called only from the steer path, which does NOT hold the virtual mutex (that is
 * taken inside allocate_virtual_memory), so re-entering the free path is safe here. */
static uint64_t ios_steer_reclaim_dead( void )
{
    uint64_t freed_total = 0;
    unsigned i;

    for (i = 0; i < ios_steer_n; i++)
    {
        void *addr;
        SIZE_T sz = 0;

        if (ios_steer[i].freed || !ios_steer[i].base) continue;
        if (!ios_tid_is_dead( ios_steer[i].tid )) continue;
        /* iOS-Madeira ml312 (task #54) -- THE FIX FOR THE VA DOUBLE-ALLOCATION.
         *
         * These 512MB ranges are FEX's jemalloc HEAP ARENAS, which are process-wide. Tagging one
         * with the thread that happened to trigger it and releasing it when that thread exits is
         * wrong: FEX allocates FEXMem_ThreadState / FEXMem_Lookup / FEXMem_CallRetStacks INSIDE
         * them, and those outlive the triggering thread. ml312 caught the consequence directly --
         * nine arenas came back from this function with freed=1 and were immediately reissued, and
         * the reissued VAs are exactly where the duplicate ThreadStates appear:
         *   0x7d00001000 owned by tids A8, AC and E4   (arena 0x7d00000000, reissued)
         *   0x7d40001000 owned by tids B0 and F0       (arena 0x7d40000000, reissued)
         * Two threads sharing a ThreadState share x28, so one thread's State.rip IS the other's;
         * sharing a CallRetStack means one pops the other's {guest_ret, host_label} pair and
         * branches into a foreign block. That is the #51/#52 signature and the variance source.
         *
         * Refuse to reclaim any arena something has allocated inside. Thread-exit is simply not
         * evidence that a process-wide arena is dead. Arenas never touched are still reclaimable,
         * so the pressure-relief this function exists for survives for the case it is valid in. */
        /* ml313 RETRACTION: the ml312 "KEEPING in-use arenas" guard here was built on a premise
         * ml313 then refuted. Two [vname] records at one address do NOT prove two live owners --
         * [vname] logs allocations but not frees, and the liveness test on ml313's two duplicate
         * ThreadStates showed the first owner went quiet ~20 lines after claiming, long before the
         * second claim: ordinary allocator reuse after thread exit, not a collision. The
         * ThreadState allocations also never appear in the [va-exit] syscall census (they are
         * jemalloc sub-allocations, invisible to VirtualAlloc), and ml313's arenas were each
         * reserved exactly once with zero reissues -- yet duplicates still appeared. So
         * reclaim-reissue was not causing them either.
         *
         * Blocking reclaim outright would risk VA exhaustion (#43) for no demonstrated benefit.
         * Keep the inuse flag as a DETECTOR instead: if reclaim ever releases an arena that has
         * interior allocations, say so loudly, so any later corruption in that range can be tied
         * to this event with evidence rather than theory. */
        /* iOS-Madeira ml330: the ml312 guard WAS right — restored, now with the evidence
         * the ml313 revert was waiting for.
         *
         * ml329 fired this detector 10 times, and cross-referencing [vname] against the
         * released ranges showed 28 live FEX structures sitting INSIDE arenas being
         * released — including FEXMem_ThreadState, FEX's per-thread CPU state. Releasing
         * the arena frees that VA; the next reservation is handed the same range, and two
         * owners write the same memory. That is exactly the corruption we kept crashing
         * on: FEX container nodes holding impossible pointers —
         *   ml326/ml328  IntrusivePooledAllocator::ClaimBufferImpl, list next == NULL
         *   ml329        GuestToHostMap::AddBlockExecutableRange, std::set child == 4
         * and #53 is refuted for these (ml329's [reclaim-census]: 0 pages zero-filled all
         * run), so page reclamation was never the source — VA double-ownership was.
         *
         * The arena belongs to a dead thread, but the allocations inside it OUTLIVE that
         * thread, so "owning thread exited" is not a licence to free the range. Skip it.
         * Note it stays skipped for the life of the process: an arena with live interior
         * allocations can never become safe to release just because more time passed.
         *
         * The ml313 objection was VA exhaustion (#43) for no demonstrated benefit. The
         * benefit is now demonstrated, and this is the narrow case — only arenas with
         * recorded interior allocations are spared; empty ones are still reclaimed. */
        if (ios_steer[i].inuse)
        {
            static int rc_note;
            if (rc_note++ < 12)
                dprintf(2, "[steer-reclaim] rev=ml332 SKIPPING release of arena #%u [0x%llx+0x%llx] "
                        "dead_tid=%04x — %u interior allocations still LIVE (outlive the thread); "
                        "releasing it is what corrupted FEX's containers (ml329)\n",
                        i, (unsigned long long)ios_steer[i].base,
                        (unsigned long long)ios_steer[i].size, ios_steer[i].tid, ios_steer[i].inuse);
            continue;
        }

        addr = (void *)(uintptr_t)ios_steer[i].base;
        if (!NtFreeVirtualMemory( NtCurrentProcess(), &addr, &sz, MEM_RELEASE ))
        {
            ios_steer[i].freed = 1;
            freed_total += ios_steer[i].size;
        }
    }
    if (freed_total)
        dprintf(2, "[steer-reclaim] released %lluMB from exited threads\n",
                (unsigned long long)(freed_total >> 20));
    return freed_total;
}

/* ml255: STORM GATE.
 *
 * ml255 wrote a 510 MB / 4.47-MILLION-line log because a NULL-deref loop ran
 * 524,186 times and three diagnostics fired on EVERY iteration: [va-scan] FAILED
 * (524k), [fault-rgn] (524k + 393k) and the setup_exception/TEB dumps (393k).
 * Device I/O that heavy is destructive on its own and it buried the one line that
 * mattered. These probes are all still worth having -- the FIRST few of each
 * settle the question -- so gate them instead of deleting them.
 *
 * Escalating schedule: every one of the first 20, then 1-in-1000, then
 * 1-in-100000 past 100k. A storm still proves it is a storm and still shows where
 * it ends, at ~1/1000th the bytes. */
static int ios_storm_gate( unsigned long *n )
{
    unsigned long c = ++(*n);
    if (c <= 20) return 1;
    if (c <= 100000) return (c % 1000) == 0;
    return (c % 100000) == 0;
}

/* [va-scan] probe: failing mmap-tryfixed attempts inside the current
 * map_free_area call. virtual_mutex is held throughout, so a plain global is
 * safe. Proves or refutes the grind above in one run. */
static unsigned int ios_va_scan_tries;
/* ml211: how many times the scan JUMPED over a foreign Mach region instead of
 * crawling a granule at a time. Reported next to tries= so the two are directly
 * comparable: before this, placing 1MB cost ~8000 tries and 0 skips. */
static unsigned int ios_va_scan_skips;

/* ml117: the grind is GONE (Thumper splash back to 2s) but a 512KB-aligned
 * 512MB request still FAILED in the 15.1GB window with tries=0 — i.e.
 * map_free_area rejected it on a structural guard without attempting a single
 * mmap, then handed rpmalloc the NULL that killed FEX's CreateThread. tries=0
 * narrows it to "no gap between Wine's own views was large enough", so record
 * the geometry map_free_area actually saw: the base/end AFTER
 * find_view_inside_range moved them, how many views were walked, the largest
 * gap found, and which guard ended the search. */
static void *ios_scan_base, *ios_scan_end;
static unsigned int ios_scan_views;
static size_t ios_scan_maxgap;
static int ios_scan_stop;   /* see ios_scan_stop_name() */

/* ml118 THE DISCRIMINATING QUESTION. The kernel's own walk reported ONE
 * contiguous free hole 0x7038120000..0x73ffdf0000 = 15484 MB, yet Wine's scan
 * reported 343 views with 2MB max gaps, and one failure showed 17 tryfixed
 * calls ALL failing inside a gap Wine believed was free. Those cannot both be
 * about occupancy. Two mutually exclusive explanations:
 *   (a) the window really is full of mappings Wine's view tree cannot see, or
 *   (b) the addresses are genuinely free and iOS is refusing the FIXED mapping
 *       (mach_vm_map returning KERN_INVALID_ADDRESS/KERN_NO_SPACE — a hazard
 *       try_map_free_area already documents for this platform).
 * (a) means the ceiling needs a smaller furniture budget; (b) means Wine's
 * fixed-address placement can never work here and the ceiling is unfixable, so
 * the pools must instead be pre-reserved at startup. Capture the first failing
 * address AND its errno, then ask the kernel what actually lives there. */
static void *ios_scan_fail_addr;
static int   ios_scan_fail_errno;

/* Describe what the kernel believes is at addr: the enclosing region, or the
 * hole it falls in. Non-destructive (query only). */
/* ml210: one-shot census of the furniture window.
 *
 * Every recent run grinds here — a 1MB request costs ~8000 tryfixed attempts and still
 * reports errno=12 — and FEX then dereferences a NULL returned by an 8KB
 * aligned_alloc (libarm64ecfex+0x16298, `stp x8,x20,[x0]` with x0=0, unchecked). That is
 * very likely why each run dies at a DIFFERENT small-offset null address (0x0, 0x8, 0x28,
 * 0x68): one exhaustion cause landing on whichever allocation runs first, not a race.
 *
 * Before guessing who consumes the window, measure it. Walks the real Mach map rather
 * than Wine's view bookkeeping, so it reports the truth even for foreign/FEX mappings,
 * and prints the largest free gap next to the largest regions — if the gap is big the
 * problem is placement, if it is tiny the window is genuinely full. */
static void ios_furniture_census( void )
{
    const mach_vm_address_t LO = 0x7000000000ULL, HI = 0x73ffff0000ULL;
    struct { unsigned long long base, size; unsigned prot; } top[16];
    unsigned ntop = 0, nregions = 0, k;
    unsigned long long mapped = 0, biggest_gap = 0, gap_at = 0, prev_end = LO;
    mach_vm_address_t a = LO;

    for (;;)
    {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        unsigned i, j;

        if (mach_vm_region( mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64,
                            (vm_region_info_t)&info, &cnt, &obj ) != KERN_SUCCESS)
            break;
        if (a >= HI) break;

        if (a > prev_end && a - prev_end > biggest_gap)
        {
            biggest_gap = a - prev_end;
            gap_at = prev_end;
        }
        nregions++;
        mapped += size;

        for (i = 0; i < ntop && top[i].size >= (unsigned long long)size; i++) {}
        if (i < 16)
        {
            for (j = (ntop < 16 ? ntop : 15); j > i; j--) top[j] = top[j - 1];
            top[i].base = (unsigned long long)a;
            top[i].size = (unsigned long long)size;
            top[i].prot = (unsigned)info.protection;
            if (ntop < 16) ntop++;
        }
        prev_end = (unsigned long long)a + size;
        a += size;
    }
    if (HI > prev_end && HI - prev_end > biggest_gap)
    {
        biggest_gap = HI - prev_end;
        gap_at = prev_end;
    }

    dprintf( 2, "[furniture] window 0x%llx..0x%llx = %llu MB | regions=%u mapped=%llu MB "
                "free=%llu MB | biggest free gap=%llu MB at 0x%llx\n",
             (unsigned long long)LO, (unsigned long long)HI,
             (unsigned long long)((HI - LO) >> 20), nregions,
             mapped >> 20, (unsigned long long)(((HI - LO) - mapped) >> 20),
             biggest_gap >> 20, gap_at );
    for (k = 0; k < ntop; k++)
        dprintf( 2, "[furniture]   #%u 0x%llx +0x%llx (%llu MB) prot=%x\n",
                 k + 1, top[k].base, top[k].size, top[k].size >> 20, top[k].prot );
}

static void ios_va_describe( void *addr, char *buf, size_t buflen )
{
    mach_vm_address_t a = (mach_vm_address_t)(uintptr_t)addr;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;

    if (mach_vm_region( mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64,
                        (vm_region_info_t)&info, &cnt, &obj ) != KERN_SUCCESS)
    {
        snprintf( buf, buflen, "no-region-above (free to end of VA)" );
        return;
    }
    if (a > (mach_vm_address_t)(uintptr_t)addr)
        snprintf( buf, buflen, "FREE hole, next region 0x%llx (+0x%llx away) <-- iOS REFUSED A FREE ADDRESS",
                  (unsigned long long)a,
                  (unsigned long long)(a - (mach_vm_address_t)(uintptr_t)addr) );
    else
        snprintf( buf, buflen, "OCCUPIED 0x%llx+0x%llx prot=%x/%x shared=%d",
                  (unsigned long long)a, (unsigned long long)size,
                  info.protection, info.max_protection, info.shared );
}

static const char *ios_scan_stop_name( int stop )
{
    switch (stop)
    {
    case 0: return "walked-all-views";
    case 1: return "window<size@entry(bottom-up)";
    case 2: return "gaps-exhausted(bottom-up)";
    case 3: return "window<size@entry(top-down)";
    case 4: return "gaps-exhausted(top-down)";
    case 9: return "no-views-in-range";
    default: return "?";
    }
}
static void *working_set_limit   = (void *)0x7fffffff0000;  /* top of the current working set */
#else
static void *address_space_limit = (void *)0xc0000000;
static void *user_space_limit    = (void *)0x7fff0000;
static void *working_set_limit   = (void *)0x7fff0000;
#endif

static void *host_addr_space_limit;  /* top of the host virtual address space */

static struct file_view *arm64ec_view;

/* X3c: EC bitmap base for wiring EcCodeBitMap into cross-arch child PEBs
 * (alloc_arm64ec_map only sets it on the PEB current at first allocation). */
void *ios_arm64ec_bitmap_base(void)
{
    return arm64ec_view ? arm64ec_view->base : NULL;
}

ULONG_PTR user_space_wow_limit = 0;
struct _KUSER_SHARED_DATA *user_shared_data = (void *)0x7ffe0000;

/* TEB allocation blocks */
static void *teb_block;
static void **next_free_teb;
static int teb_block_pos;
static struct list teb_list = LIST_INIT( teb_list );

#define ROUND_ADDR(addr,mask) ((void *)((UINT_PTR)(addr) & ~(UINT_PTR)(mask)))
#define ROUND_SIZE(addr,size,mask) (((SIZE_T)(size) + ((UINT_PTR)(addr) & (mask)) + (mask)) & ~(UINT_PTR)(mask))

#define VIRTUAL_DEBUG_DUMP_VIEW(view) do { if (TRACE_ON(virtual)) dump_view(view); } while (0)
#define VIRTUAL_DEBUG_DUMP_RANGES() do { if (TRACE_ON(virtual_ranges)) dump_free_ranges(); } while (0)

#ifndef MAP_NORESERVE
#define MAP_NORESERVE 0
#endif

#ifdef _WIN64  /* on 64-bit the page protection bytes use a 2-level table */
static const size_t pages_vprot_shift = 20;
static const size_t pages_vprot_mask = (1 << 20) - 1;
static size_t pages_vprot_size;
static BYTE **pages_vprot;
#else  /* on 32-bit we use a simple array with one byte per page */
static BYTE *pages_vprot;
#endif

static int use_kernel_writewatch;
#ifdef USE_UFFD_WRITEWATCH
static int uffd_fd, pagemap_fd;
#endif

static struct file_view *view_block_start, *view_block_end, *next_free_view;
static const size_t view_block_size = 0x100000;
static void *preload_reserve_start;
static void *preload_reserve_end;
static BOOL force_exec_prot;  /* whether to force PROT_EXEC on all PROT_READ mmaps */
static BOOL enable_write_exceptions;  /* raise exception on writes to executable memory */

struct range_entry
{
    void *base;
    void *end;
};

static struct range_entry *free_ranges;
static struct range_entry *free_ranges_end;


static inline BOOL is_beyond_limit( const void *addr, size_t size, const void *limit )
{
    return (addr >= limit || (const char *)addr + size > (const char *)limit);
}

static inline BOOL is_vprot_exec_write( BYTE vprot )
{
    return (vprot & VPROT_EXEC) && (vprot & (VPROT_WRITE | VPROT_WRITECOPY));
}

/* task #34 [jit-tripwire]: defined below; forward-declared so the fixed-map
 * helpers above its definition can instrument JIT-pool-range clobbers. */
static void ios_jit_range_tripwire( const char *tag, const void *addr, size_t size,
                                    int prot, void *retaddr );

/* mmap() anonymous memory at a fixed address */
void *anon_mmap_fixed( void *start, size_t size, int prot, int flags )
{
    ios_pool_va_warn( "anon_mmap_fixed", start, size );
    assert( !((UINT_PTR)start & host_page_mask) );
    assert( !(size & host_page_mask) );

    ios_jit_range_tripwire( "anon_mmap_fixed", start, size, prot, __builtin_return_address(0) );
    return mmap( start, size, prot, MAP_PRIVATE | MAP_ANON | MAP_FIXED | flags, -1, 0 );
}

/* allocate anonymous mmap() memory at any address */
/* ml134: does [addr,addr+size) touch either JIT pool alias? */
static int ios_jit_pool_intersects( const void *addr, size_t size )
{
    uint64_t a = (uint64_t)(uintptr_t)addr, e = a + size;
    uint64_t rx = (uint64_t)(uintptr_t)ios_jit_rx_base_global;
    uint64_t rw = (uint64_t)(uintptr_t)ios_jit_rw_base_global;
    uint64_t sz = ios_jit_pool_size_global;

    if (!sz) return 0;
    if (rx && a < rx + sz && e > rx) return 1;
    if (rw && a < rw + sz && e > rw) return 1;
    return 0;
}

void *anon_mmap_alloc( size_t size, int prot )
{
    /* ml134 THE #34 CLOBBER, CAUGHT AT LAST.
     *
     * The faulting pool page reported prot=0x3 max_prot=0x3 — max_protection
     * can only DROP via a fresh mapping, never via mprotect, so the blessed RX
     * page (max_prot=0x7) had been REPLACED by a plain RW anon mapping. Not iOS
     * reclaiming a page: something mapped over our executable alias. That is
     * why mprotect(RX) and the read-touch both failed — there was nothing left
     * to restore.
     *
     * ios_jit_range_tripwire instruments every FIXED map and unmap and fired
     * ZERO times, which leaves exactly the case its own comment predicted: "a
     * munmap whose hole a later kernel-pick refilled". This function is that
     * kernel pick, and it was the one path never checked.
     *
     * Detect and REJECT: hold the offending mapping so the kernel cannot return
     * it again, retry, then release the held ones. Clobbering the pool is fatal
     * and unrecoverable, so paying a few extra mmaps to avoid it is always
     * right. Bounded at 8 tries, then accept-and-scream rather than fail the
     * allocation. */
    void *held[8];
    int nheld = 0, i;
    void *ret;

    assert( !(size & host_page_mask) );

    for (;;)
    {
        ret = mmap( NULL, size, prot, MAP_PRIVATE | MAP_ANON, -1, 0 );
        if (ret == MAP_FAILED || !ios_jit_pool_intersects( ret, size )) break;
        dprintf( 2, "[jit-clobber] kernel-pick %p+0x%lx prot=%x landed INSIDE the JIT pool"
                    " (rx=%p rw=%p size=0x%lx) — rejecting, try %d\n",
                 ret, (unsigned long)size, prot, ios_jit_rx_base_global,
                 ios_jit_rw_base_global, (unsigned long)ios_jit_pool_size_global, nheld + 1 );
        if (nheld == 8)
        {
            dprintf( 2, "[jit-clobber] EXHAUSTED 8 retries — ACCEPTING a pool-overlapping"
                        " mapping at %p; expect an exec fault in this range\n", ret );
            break;
        }
        held[nheld++] = ret;
    }
    for (i = 0; i < nheld; i++) munmap( held[i], size );
    return ret;
}

/* task #34 [jit-tripwire]: ml74's fatal page (0x125114000, inside the JIT
 * pool RX view) faulted on EXECUTE with prot=RW max_prot=RW. max_prot can
 * only DROP via a fresh mapping, never via mprotect — so some path REPLACED
 * a pool code page with a plain RW anon mapping (MAP_FIXED clobber, or a
 * munmap whose hole a later kernel-pick refilled). Every wine unmap and
 * fixed-map flows through unmap_area / remove_reserved_area /
 * anon_mmap_fixed / anon_mmap_tryfixed: log any call intersecting the pool
 * RX view or its RW alias, with the instrumented site's return address, so
 * one device run names the culprit. Legit hits exist (pool tail EC_CODE
 * carves, decommit of pool-backed anon RWX) — the log includes the range so
 * they can be told apart from clobbers of live image-copy code. */
static void ios_jit_range_tripwire( const char *tag, const void *addr, size_t size,
                                    int prot, void *retaddr )
{
    uintptr_t a = (uintptr_t)addr, e = a + size;
    uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
    uintptr_t rw = (uintptr_t)ios_jit_rw_base_global;
    size_t ps = ios_jit_pool_size_global;
    static volatile int n;

    if (!ps || !addr || !size) return;
    if (!((rx && a < rx + ps && e > rx) || (rw && a < rw + ps && e > rw))) return;
    if (__sync_fetch_and_add( &n, 1 ) > 300) return;
    dprintf(2, "[jit-tripwire] %s addr=%p size=0x%lx prot=%d caller=%p (pool rx=%p rw=%p)\n",
            tag, addr, (unsigned long)size, prot, retaddr, (void *)rx, (void *)rw);
}

#ifdef USE_UFFD_WRITEWATCH
static void kernel_writewatch_init(void)
{
    struct uffdio_api uffdio_api;

    uffd_fd = syscall( __NR_userfaultfd, O_CLOEXEC | O_NONBLOCK | UFFD_USER_MODE_ONLY );
    if (uffd_fd == -1) return;

    uffdio_api.api = UFFD_API;
    uffdio_api.features = UFFD_FEATURE_WP_ASYNC | UFFD_FEATURE_WP_UNPOPULATED;
    if (ioctl( uffd_fd, UFFDIO_API, &uffdio_api ) || uffdio_api.api != UFFD_API)
    {
        close( uffd_fd );
        return;
    }
    pagemap_fd = open( "/proc/self/pagemap", O_CLOEXEC | O_RDONLY );
    if (pagemap_fd == -1)
    {
        ERR( "Error opening /proc/self/pagemap.\n" );
        close( uffd_fd );
        return;
    }
    use_kernel_writewatch = 1;
    TRACE( "Using kernel write watches.\n" );
}

static void kernel_writewatch_reset( void *start, SIZE_T len )
{
    struct pm_scan_arg arg = { 0 };

    len = ROUND_SIZE( start, len, host_page_mask );
    start = (char *)ROUND_ADDR( start, host_page_mask );

    arg.size = sizeof(arg);
    arg.start = (UINT_PTR)start;
    arg.end = arg.start + len;
    arg.flags = PM_SCAN_WP_MATCHING;
    arg.category_mask = PAGE_IS_WRITTEN;
    arg.return_mask = PAGE_IS_WRITTEN;
    if (ioctl( pagemap_fd, PAGEMAP_SCAN, &arg ) < 0)
        ERR( "ioctl(PAGEMAP_SCAN) failed, err %s.\n", strerror(errno) );
}

static void kernel_writewatch_register_range( struct file_view *view, void *base, size_t size )
{
    struct uffdio_register uffdio_register;
    struct uffdio_writeprotect wp;

    if (!(view->protect & VPROT_WRITEWATCH) || !use_kernel_writewatch) return;

    size = ROUND_SIZE( base, size, host_page_mask );
    base = (char *)ROUND_ADDR( base, host_page_mask );

    /* Transparent huge pages will result in larger areas reported as dirty. */
    madvise( base, size, MADV_NOHUGEPAGE );

    uffdio_register.range.start = (UINT_PTR)base;
    uffdio_register.range.len = size;
    uffdio_register.mode = UFFDIO_REGISTER_MODE_WP;
    if (ioctl( uffd_fd, UFFDIO_REGISTER, &uffdio_register ) == -1)
    {
        ERR( "ioctl( UFFDIO_REGISTER ) failed, %s.\n", strerror(errno) );
        return;
    }

    if (!(uffdio_register.ioctls & UFFDIO_WRITEPROTECT))
    {
        ERR( "uffdio_register.ioctls %s.\n", wine_dbgstr_longlong(uffdio_register.ioctls) );
        return;
    }
    wp.range.start = (UINT_PTR)base;
    wp.range.len = size;
    wp.mode = UFFDIO_WRITEPROTECT_MODE_WP;

    if (ioctl( uffd_fd, UFFDIO_WRITEPROTECT, &wp ) == -1)
        ERR( "ioctl( UFFDIO_WRITEPROTECT ) failed, %s.\n", strerror(errno) );
}

static void kernel_get_write_watches( void *base, SIZE_T size, void **buffer, ULONG_PTR *count, BOOL reset )
{
    struct pm_scan_arg arg = { 0 };
    struct page_region rgns[256];
    SIZE_T buffer_len = *count;
    char *addr, *next_addr;
    int rgn_count, i;
    size_t end, granularity = host_page_size / page_size;

    assert( !(size & page_mask) );

    end = (size_t)((char *)base + size);
    size = ROUND_SIZE( base, size, host_page_mask );
    addr = (char *)ROUND_ADDR( base, host_page_mask );

    arg.size = sizeof(arg);
    arg.vec = (ULONG_PTR)rgns;
    arg.vec_len = ARRAY_SIZE(rgns);
    if (reset) arg.flags |= PM_SCAN_WP_MATCHING;
    arg.category_mask = PAGE_IS_WRITTEN;
    arg.return_mask = PAGE_IS_WRITTEN;

    *count = 0;
    while (1)
    {
        arg.start = (UINT_PTR)addr;
        arg.end = arg.start + size;
        arg.max_pages = (buffer_len + granularity - 1) / granularity;

        if ((rgn_count = ioctl( pagemap_fd, PAGEMAP_SCAN, &arg )) < 0)
        {
            ERR( "ioctl( PAGEMAP_SCAN ) failed, error %s.\n", strerror(errno) );
            return;
        }
        if (!rgn_count) break;

        assert( rgn_count <= ARRAY_SIZE(rgns) );
        for (i = 0; i < rgn_count; ++i)
        {
            size_t c_addr = max( rgns[i].start, (size_t)base );

            rgns[i].end = min( rgns[i].end, end );
            assert( rgns[i].categories == PAGE_IS_WRITTEN );
            while (buffer_len && c_addr < rgns[i].end)
            {
                buffer[(*count)++] = (void *)c_addr;
                --buffer_len;
                c_addr += page_size;
            }
            if (!buffer_len) break;
        }
        if (!buffer_len || rgn_count < arg.vec_len) break;
        next_addr = (char *)(ULONG_PTR)arg.walk_end;
        assert( size >= next_addr - addr );
        if (!(size -= next_addr - addr)) break;
        addr = next_addr;
    }
}
#else
static void kernel_writewatch_init(void)
{
}

static void kernel_writewatch_reset( void *start, SIZE_T len )
{
}

static void kernel_writewatch_register_range( struct file_view *view, void *base, size_t size )
{
}

static void kernel_get_write_watches( void *base, SIZE_T size, void **buffer, ULONG_PTR *count, BOOL reset )
{
    assert( 0 );
}
#endif

static void mmap_add_reserved_area( void *addr, SIZE_T size )
{
    struct reserved_area *area;
    struct list *ptr, *next;
    void *end, *area_end;

    assert( !((UINT_PTR)addr & host_page_mask) );
    assert( !(size & host_page_mask) );

    if (!((intptr_t)addr + size)) size--;  /* avoid wrap-around */
    end = (char *)addr + size;

    LIST_FOR_EACH( ptr, &reserved_areas )
    {
        area = LIST_ENTRY( ptr, struct reserved_area, entry );
        area_end = (char *)area->base + area->size;

        if (area->base > end) break;
        if (area_end < addr) continue;
        if (area->base > addr)
        {
            area->size += (char *)area->base - (char *)addr;
            area->base = addr;
        }
        if (area_end >= end) return;

        /* try to merge with the following ones */
        while ((next = list_next( &reserved_areas, ptr )))
        {
            struct reserved_area *area_next = LIST_ENTRY( next, struct reserved_area, entry );
            void *next_end = (char *)area_next->base + area_next->size;

            if (area_next->base > end) break;
            list_remove( next );
            free( area_next );
            if (next_end >= end)
            {
                end = next_end;
                break;
            }
        }
        area->size = (char *)end - (char *)area->base;
        return;
    }

    if ((area = malloc( sizeof(*area) )))
    {
        area->base = addr;
        area->size = size;
        list_add_before( ptr, &area->entry );
    }
}

static void mmap_remove_reserved_area( void *addr, SIZE_T size )
{
    struct reserved_area *area;
    struct list *ptr;

    assert( !((UINT_PTR)addr & host_page_mask) );
    assert( !(size & host_page_mask) );

    if (!((intptr_t)addr + size)) size--;  /* avoid wrap-around */

    ptr = list_head( &reserved_areas );
    /* find the first area covering address */
    while (ptr)
    {
        area = LIST_ENTRY( ptr, struct reserved_area, entry );
        if ((char *)area->base >= (char *)addr + size) break;  /* outside the range */
        if ((char *)area->base + area->size > (char *)addr)  /* overlaps range */
        {
            if (area->base >= addr)
            {
                if ((char *)area->base + area->size > (char *)addr + size)
                {
                    /* range overlaps beginning of area only -> shrink area */
                    area->size -= (char *)addr + size - (char *)area->base;
                    area->base = (char *)addr + size;
                    break;
                }
                else
                {
                    /* range contains the whole area -> remove area completely */
                    ptr = list_next( &reserved_areas, ptr );
                    list_remove( &area->entry );
                    free( area );
                    continue;
                }
            }
            else
            {
                if ((char *)area->base + area->size > (char *)addr + size)
                {
                    /* range is in the middle of area -> split area in two */
                    struct reserved_area *new_area = malloc( sizeof(*new_area) );
                    if (new_area)
                    {
                        new_area->base = (char *)addr + size;
                        new_area->size = (char *)area->base + area->size - (char *)new_area->base;
                        list_add_after( ptr, &new_area->entry );
                    }
                    area->size = (char *)addr - (char *)area->base;
                    break;
                }
                else
                {
                    /* range overlaps end of area only -> shrink area */
                    area->size = (char *)addr - (char *)area->base;
                }
            }
        }
        ptr = list_next( &reserved_areas, ptr );
    }
}

static int mmap_is_in_reserved_area( void *addr, SIZE_T size )
{
    struct reserved_area *area;

    LIST_FOR_EACH_ENTRY( area, &reserved_areas, struct reserved_area, entry )
    {
        if (area->base > addr) break;
        if ((char *)area->base + area->size <= (char *)addr) continue;
        /* area must contain block completely */
        if ((char *)area->base + area->size < (char *)addr + size) return -1;
        return 1;
    }
    return 0;
}


/***********************************************************************
 *           unmap_area_above_user_limit
 *
 * Unmap memory that's above the user space limit, by replacing it with an empty mapping,
 * and return the remaining size below the limit. virtual_mutex must be held by caller.
 */
static size_t unmap_area_above_user_limit( void *addr, size_t size )
{
    size_t ret = 0;

    if (addr < user_space_limit)
    {
        ret = (char *)user_space_limit - (char *)addr;
        if (ret >= size) return size;  /* nothing is above limit */
        size -= ret;
        addr = user_space_limit;
    }
    anon_mmap_fixed( addr, size, PROT_NONE, MAP_NORESERVE );
    mmap_add_reserved_area( addr, size );
    return ret;
}


static void *anon_mmap_tryfixed( void *start, size_t size, int prot, int flags )
{
    ios_pool_va_warn( "anon_mmap_tryfixed", start, size );
    void *ptr;

    /* no [jit-tripwire] here: tryfixed is no-clobber by definition (fails on
     * overlap), and ml75 showed it drowns the cap in pool-setup boot noise. */

#ifdef MAP_FIXED_NOREPLACE
    ptr = mmap( start, size, prot, MAP_FIXED_NOREPLACE | MAP_PRIVATE | MAP_ANON | flags, -1, 0 );
#elif defined(MAP_TRYFIXED)
    ptr = mmap( start, size, prot, MAP_TRYFIXED | MAP_PRIVATE | MAP_ANON | flags, -1, 0 );
#elif defined(__FreeBSD__) || defined(__FreeBSD_kernel__)
    ptr = mmap( start, size, prot, MAP_FIXED | MAP_EXCL | MAP_PRIVATE | MAP_ANON | flags, -1, 0 );
    if (ptr == MAP_FAILED && errno == EINVAL) errno = EEXIST;
#elif defined(__APPLE__)
    mach_vm_address_t result = (mach_vm_address_t)start;
    kern_return_t ret = mach_vm_map( mach_task_self(), &result, size, 0, VM_FLAGS_FIXED,
                                     MEMORY_OBJECT_NULL, 0, 0, prot, VM_PROT_ALL, VM_INHERIT_COPY );

    if (!ret)
    {
        if ((ptr = anon_mmap_fixed( start, size, prot, flags )) == MAP_FAILED)
            mach_vm_deallocate( mach_task_self(), result, size );
    }
    else
    {
        errno = (ret == KERN_NO_SPACE ? EEXIST : ENOMEM);
        ptr = MAP_FAILED;
    }
#else
    ptr = mmap( start, size, prot, MAP_PRIVATE | MAP_ANON | flags, -1, 0 );
#endif
    if (ptr != MAP_FAILED && ptr != start)
    {
        size = unmap_area_above_user_limit( ptr, size );
        if (size) munmap( ptr, size );
        ptr = MAP_FAILED;
        errno = EEXIST;
    }
    return ptr;
}

static void reserve_area( void *addr, void *end )
{
#ifdef __APPLE__

#ifdef __i386__
    static const mach_vm_address_t max_address = VM_MAX_ADDRESS;
#else
    static const mach_vm_address_t max_address = MACH_VM_MAX_ADDRESS;
#endif
    mach_vm_address_t address = (mach_vm_address_t)addr;
    mach_vm_address_t end_address = (mach_vm_address_t)end;

    if (!end_address || max_address < end_address)
        end_address = max_address;

    while (address < end_address)
    {
        mach_vm_address_t hole_address = address;
        kern_return_t ret;
        mach_vm_size_t size;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t dummy_object_name = MACH_PORT_NULL;

        /* find the mapped region at or above the current address. */
        ret = mach_vm_region(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
                             (vm_region_info_t)&info, &count, &dummy_object_name);
        if (ret != KERN_SUCCESS)
        {
            address = max_address;
            size = 0;
        }

        if (end_address < address)
            address = end_address;
        if (hole_address < address)
        {
            /* found a hole, attempt to reserve it. */
            size_t hole_size = address - hole_address;
            mach_vm_address_t alloc_address = hole_address;

            ret = mach_vm_map( mach_task_self(), &alloc_address, hole_size, 0, VM_FLAGS_FIXED,
                               MEMORY_OBJECT_NULL, 0, 0, PROT_NONE, VM_PROT_ALL, VM_INHERIT_COPY );
            if (!ret) mmap_add_reserved_area( (void*)hole_address, hole_size );
            else if (ret == KERN_NO_SPACE)
            {
                /* something filled (part of) the hole before we could.
                   go back and look again. */
                address = hole_address;
                continue;
            }
        }
        address += size;
    }
#else
    size_t size = (char *)end - (char *)addr;

    if (!size) return;

    if (anon_mmap_tryfixed( addr, size, PROT_NONE, MAP_NORESERVE ) != MAP_FAILED)
    {
        mmap_add_reserved_area( addr, size );
        return;
    }
    size = (size / 2) & ~granularity_mask;
    if (size)
    {
        reserve_area( addr, (char *)addr + size );
        reserve_area( (char *)addr + size, end );
    }
#endif /* __APPLE__ */
}


static void mmap_init( const struct preload_info *preload_info )
{
#ifndef _WIN64
#ifndef __APPLE__
    char stack;
    char * const stack_ptr = &stack;
#endif
    char *user_space_limit = (char *)0x7ffe0000;
    int i;

    if (preload_info)
    {
        /* check for a reserved area starting at the user space limit */
        /* to avoid wasting time trying to allocate it again */
        for (i = 0; preload_info[i].size; i++)
        {
            if ((char *)preload_info[i].addr > user_space_limit) break;
            if ((char *)preload_info[i].addr + preload_info[i].size > user_space_limit)
            {
                user_space_limit = (char *)preload_info[i].addr + preload_info[i].size;
                break;
            }
        }
    }
    else reserve_area( (void *)0x00010000, (void *)0x40000000 );


#ifndef __APPLE__
    if (stack_ptr >= user_space_limit)
    {
        char *end = 0;
        char *base = stack_ptr - ((unsigned int)stack_ptr & granularity_mask) - (granularity_mask + 1);
        if (base > user_space_limit) reserve_area( user_space_limit, base );
        base = stack_ptr - ((unsigned int)stack_ptr & granularity_mask) + (granularity_mask + 1);
#if defined(linux) || defined(__FreeBSD__) || defined (__FreeBSD_kernel__) || defined(__DragonFly__)
        /* Heuristic: assume the stack is near the end of the address */
        /* space, this avoids a lot of futile allocation attempts */
        end = (char *)(((unsigned long)base + 0x0fffffff) & 0xf0000000);
#endif
        reserve_area( base, end );
    }
    else
#endif
        reserve_area( user_space_limit, 0 );

#else

    if (preload_info) return;
    /* if we don't have a preloader, try to reserve the space now */
    reserve_area( (void *)0x000000010000, (void *)0x000068000000 );
    reserve_area( (void *)0x00007f000000, (void *)0x00007fff0000 );
    reserve_area( (void *)0x7ffffe000000, (void *)0x7fffffff0000 );

#endif
}


/***********************************************************************
 *           get_wow_user_space_limit
 */
static ULONG_PTR get_wow_user_space_limit(void)
{
#ifdef _WIN64
    return user_space_wow_limit & ~granularity_mask;
#endif
    return (ULONG_PTR)user_space_limit;
}


/***********************************************************************
 *           add_builtin_module
 */
static void add_builtin_module( void *module, void *handle )
{
    struct builtin_module *builtin;

    if (!(builtin = malloc( sizeof(*builtin) ))) return;
    builtin->handle      = handle;
    builtin->module      = module;
    builtin->refcount    = 1;
    builtin->unix_path   = NULL;
    builtin->unix_handle = NULL;
    list_add_tail( &builtin_modules, &builtin->entry );
}


/***********************************************************************
 *           get_builtin_module
 */
static struct builtin_module *get_builtin_module( void *module )
{
    struct builtin_module *builtin;

    LIST_FOR_EACH_ENTRY( builtin, &builtin_modules, struct builtin_module, entry )
        if (builtin->module == module) return builtin;

    return NULL;
}


/***********************************************************************
 *           release_builtin_module
 */
static void release_builtin_module( void *module )
{
    struct builtin_module *builtin = get_builtin_module( module );

    if (!builtin) return;
    if (--builtin->refcount) return;
    list_remove( &builtin->entry );
    if (builtin->handle) dlclose( builtin->handle );
    if (builtin->unix_handle) dlclose( builtin->unix_handle );
    free( builtin->unix_path );
    free( builtin );
}


/***********************************************************************
 *           get_builtin_so_handle
 */
void *get_builtin_so_handle( void *module )
{
    sigset_t sigset;
    void *ret = NULL;
    struct builtin_module *builtin;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if ((builtin = get_builtin_module( module )))
    {
        ret = builtin->handle;
        if (ret) builtin->refcount++;
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return ret;
}


/***********************************************************************
 *           get_unixlib_funcs
 */
static NTSTATUS get_unixlib_funcs( void *so_handle, BOOL wow, const void **funcs, NTSTATUS (**entry)(void) )
{
    *funcs = dlsym( so_handle, wow ? "__wine_unix_call_wow64_funcs" : "__wine_unix_call_funcs" );
    *entry = dlsym( so_handle, "__wine_unix_lib_init" );
    return *funcs || *entry ? STATUS_SUCCESS : STATUS_ENTRYPOINT_NOT_FOUND;
}


/***********************************************************************
 *           load_builtin_unixlib
 */
#ifdef WINE_IOS
static NTSTATUS ios_stub_unix_call(void *args) {
    return STATUS_NOT_SUPPORTED;
}

static NTSTATUS ios_stub_unix_call_ok(void *args) {
    return STATUS_SUCCESS;
}

/* iOS-Madeira 2026-07-10: the unixlib "funcs" value handed back to the PE
 * side is a TABLE that __wine_unix_call_dispatcher indexes as
 * funcs[code](args) — storing a bare function there makes UNIX_CALL read
 * the stub's own instruction bytes as a pointer and blr to garbage (the
 * Steam vgui2/opengl32 crash). The no-unix-side fallback must therefore
 * be a table of stubs. 4096 slots covers the largest builtin enum
 * (opengl32 funcs_count = 3107). */
#define IOS_STUB_TABLE_SIZE 4096
static unixlib_entry_t ios_stub_unix_call_table[IOS_STUB_TABLE_SIZE];
/* opengl32 variant: process_attach / thread_attach / process_detach
 * (codes 0-2 in dlls/opengl32/unixlib.h) return SUCCESS so DllMain lets
 * the DLL load; every real wgl/gl call fails with NOT_SUPPORTED (no host
 * GL on iOS — DXMT is D3D-only, callers must treat GL as absent). */
static unixlib_entry_t ios_gl_stub_unix_call_table[IOS_STUB_TABLE_SIZE];

static pthread_once_t ios_stub_tables_once = PTHREAD_ONCE_INIT;
static void ios_init_stub_tables(void)
{
    unsigned int i;
    for (i = 0; i < IOS_STUB_TABLE_SIZE; i++)
        ios_stub_unix_call_table[i] = ios_gl_stub_unix_call_table[i] = ios_stub_unix_call;
    ios_gl_stub_unix_call_table[0] = ios_stub_unix_call_ok;  /* process_attach */
    ios_gl_stub_unix_call_table[1] = ios_stub_unix_call_ok;  /* thread_attach */
    ios_gl_stub_unix_call_table[2] = ios_stub_unix_call_ok;  /* process_detach */
}

/* DXMT's unix call table, statically linked into Madeira.app via
 * libdxmt_combined.a (originally __wine_unix_call_funcs, renamed in
 * winemetal_unix.c to avoid collision with our own ntdll table). */
extern const void *dxmt_winemetal_unix_call_funcs[];

/* iOS-Madeira 2026-05-13: null audio driver unix table. Implements the 37
 * mmdevapi audio funcs to provide a fake "iOS Null" render endpoint with
 * a real-time IAudioClock — enough for FMOD's rhythm-game timing engine
 * to advance past audio-gated splash/intro sequences. See audio_null_ios.c */
extern const void *audio_null_ios_unix_call_funcs[];

/* iOS-Madeira 2026-07-05 (Steam S0): network + crypto unix tables,
 * compiled from wine/dlls/<dll>/ sources into libntdll_unix.a with
 * -D__wine_unix_call_funcs=<dll>_unix_call_funcs (build/ntdll-unix/
 * build.sh compile_unixlib). The GnuTLS-backed ones (bcrypt, secur32,
 * crypt32) resolve libgnutls statically via build/crypto-unix/
 * gnutls_symtab_ios.c instead of dlopen. */
extern const void *ws2_32_unix_call_funcs[];
extern const void *bcrypt_unix_call_funcs[];
extern const void *secur32_unix_call_funcs[];
extern const void *crypt32_unix_call_funcs[];

/* iOS-Madeira 2026-08-03 (#79 transport): in-process NSI TCP connection
 * tables — nsiproxy.sys is not shipped, PE nsi.dll falls back to this
 * when \\.\Nsi can't be opened. See nsi_unixlib_ios.c */
extern const void *nsi_unix_call_funcs[];

/* iOS-Madeira ml494 (#61 text wall): dwrite's unix side (freetype glyph
 * rasterisation). Without it every __wine_unix_call from dwrite.dll failed,
 * so get_glyph_bbox never ran and every glyph run reported an EMPTY bbox —
 * ml494 measured exactly that (12/12 [dwrite-bounds] EMPTY, [dwrite-ink]
 * never called). Chromium drew no text anywhere as a result. */
extern const void *dwrite_unix_call_funcs[];

/* iOS-Madeira: host gamepads (xinput_host_ios.c). No winebus on iOS, so
 * xinput1_3's host mode reads GameController.framework pads from here. */
extern const void *xinput_unix_call_funcs[];

/* win32u's unix init, statically linked via libwin32u_unix.a. Renamed
 * from __wine_unix_lib_init in build/win32u-unix/build.sh so future
 * statically-linked unix libs can keep their own init without colliding.
 * win32u doesn't use the unix_call_funcs dispatch — its PE side uses
 * __wine_syscall_dispatcher and slot 1 of KeServiceDescriptorTable,
 * which win32u_unix_lib_init() populates via KeAddSystemServiceTable. */
extern NTSTATUS win32u_unix_lib_init(void);
#endif
static NTSTATUS load_builtin_unixlib( void *module, BOOL wow, const void **funcs )
{
    NTSTATUS (*entry)(void) = NULL;
    sigset_t sigset;
    NTSTATUS status = STATUS_DLL_NOT_FOUND;
    struct builtin_module *builtin;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if ((builtin = get_builtin_module( module )))
    {
        if (builtin->unix_path && !builtin->unix_handle)
        {
            builtin->unix_handle = dlopen( builtin->unix_path, RTLD_NOW );
            if (!builtin->unix_handle)
                WARN_(module)( "failed to load %s: %s\n", debugstr_a(builtin->unix_path), dlerror() );
        }
        if (builtin->unix_handle) status = get_unixlib_funcs( builtin->unix_handle, wow, funcs, &entry );
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    if (!status && entry) status = entry();
#ifdef WINE_IOS
    /* On iOS, unix .so files aren't available for most DLLs.
     * Detect the special case where the unix_path names a DLL whose unix
     * side is statically linked into Madeira.app, and point funcs at that
     * table instead of the dummy stub. */
    if (status == STATUS_DLL_NOT_FOUND)
    {
        /* unix_path may not be set on iOS (our loader doesn't always call
         * set_builtin_unixlib_name), so fall back to reading the DLL name
         * from the PE export directory. */
        const char *modname = NULL;
        const IMAGE_DOS_HEADER *dos = module;
        if (dos && dos->e_magic == IMAGE_DOS_SIGNATURE) {
            const IMAGE_NT_HEADERS *nt = (const IMAGE_NT_HEADERS *)((char *)module + dos->e_lfanew);
            if (nt->Signature == IMAGE_NT_SIGNATURE) {
                DWORD exp_rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
                if (exp_rva) {
                    const IMAGE_EXPORT_DIRECTORY *exp = (const IMAGE_EXPORT_DIRECTORY *)((char *)module + exp_rva);
                    if (exp->Name) modname = (const char *)module + exp->Name;
                }
            }
        }
        const char *up = NULL;
        if ((builtin = get_builtin_module( module ))) up = builtin->unix_path;
        const char *match = up ? up : modname;
        if (match && strstr(match, "winemetal")) {
            *funcs = (const void *)dxmt_winemetal_unix_call_funcs;
            WARN_(module)("iOS: module %p (%s) -> dxmt_winemetal_unix_call_funcs (%p)\n",
                          module, match, dxmt_winemetal_unix_call_funcs);
            status = STATUS_SUCCESS;
        } else if (match && (strstr(match, "wineios.drv") || strstr(match, "winecoreaudio") || strstr(match, "winealsa") || strstr(match, "winepulse"))) {
            *funcs = (const void *)audio_null_ios_unix_call_funcs;
            ERR("iOS: module %p (%s) -> audio_null_ios_unix_call_funcs (%p)\n",
                module, match, audio_null_ios_unix_call_funcs);
            status = STATUS_SUCCESS;
        } else if (match && strstr(match, "ws2_32")) {
            *funcs = (const void *)ws2_32_unix_call_funcs;
            dprintf(2, "[unixlib] module %p (%s) -> ws2_32_unix_call_funcs (%p)\n",
                module, match, (void *)ws2_32_unix_call_funcs);
            status = STATUS_SUCCESS;
        } else if (match && strstr(match, "bcrypt")) {
            *funcs = (const void *)bcrypt_unix_call_funcs;
            dprintf(2, "[unixlib] module %p (%s) -> bcrypt_unix_call_funcs (%p)\n",
                module, match, (void *)bcrypt_unix_call_funcs);
            status = STATUS_SUCCESS;
        } else if (match && strstr(match, "secur32")) {
            *funcs = (const void *)secur32_unix_call_funcs;
            dprintf(2, "[unixlib] module %p (%s) -> secur32_unix_call_funcs (%p)\n",
                module, match, (void *)secur32_unix_call_funcs);
            status = STATUS_SUCCESS;
        } else if (match && strstr(match, "crypt32")) {
            *funcs = (const void *)crypt32_unix_call_funcs;
            dprintf(2, "[unixlib] module %p (%s) -> crypt32_unix_call_funcs (%p)\n",
                module, match, (void *)crypt32_unix_call_funcs);
            status = STATUS_SUCCESS;
        } else if (match && (strstr(match, "dwrite") || strstr(match, "DWrite"))) {
            /* case-insensitive on purpose: the PE export name is "DWrite.dll"
             * while the unix_path is "dwrite.so" — matching only one spelling
             * would silently leave the text stack dead again. */
            *funcs = (const void *)dwrite_unix_call_funcs;
            dprintf(2, "[unixlib] module %p (%s) -> dwrite_unix_call_funcs (%p) rev=ml494\n",
                module, match, (void *)dwrite_unix_call_funcs);
            status = STATUS_SUCCESS;
        } else if (match && strcasestr(match, "xinput")) {
            /* xinput1_1..1_4 and xinputuap all build from xinput1_3/main.c;
             * the PE export names vary in case (XINPUT1_4.dll etc). */
            *funcs = (const void *)xinput_unix_call_funcs;
            dprintf(2, "[unixlib] module %p (%s) -> xinput_unix_call_funcs (%p)\n",
                module, match, (void *)xinput_unix_call_funcs);
            status = STATUS_SUCCESS;
        } else if (match && strstr(match, "nsi.dll")) {
            *funcs = (const void *)nsi_unix_call_funcs;
            dprintf(2, "[unixlib] module %p (%s) -> nsi_unix_call_funcs (%p) rev=ml472\n",
                module, match, (void *)nsi_unix_call_funcs);
            status = STATUS_SUCCESS;
        } else if (match && strstr(match, "win32u")) {
            /* Register win32u's NtUser / NtGdi syscall table in slot 1.
             * Activating this causes user32 process_attach to crash until
             * wineserver shared-memory bringup is complete; gated on the
             * MADEIRA_WIN32U env var so we can flip it on for debugging. */
            pthread_once( &ios_stub_tables_once, ios_init_stub_tables );
            if (getenv("MADEIRA_WIN32U")) {
                NTSTATUS s = win32u_unix_lib_init();
                *funcs = (const void *)ios_stub_unix_call_table;
                WARN_(module)("iOS: module %p (%s) -> win32u_unix_lib_init() = 0x%x (ACTIVE)\n",
                              module, match, s);
            } else {
                *funcs = (const void *)ios_stub_unix_call_table;
                WARN_(module)("iOS: module %p (%s) -> win32u unix lib linked but dormant\n",
                              module, match);
            }
            status = STATUS_SUCCESS;
        } else if (match && strstr(match, "opengl32")) {
            pthread_once( &ios_stub_tables_once, ios_init_stub_tables );
            *funcs = (const void *)ios_gl_stub_unix_call_table;
            WARN_(module)("iOS: module %p (%s) -> GL-absent stub table (attach ok, wgl/gl NOT_SUPPORTED)\n",
                          module, match);
            status = STATUS_SUCCESS;
        } else {
            pthread_once( &ios_stub_tables_once, ios_init_stub_tables );
            *funcs = (const void *)ios_stub_unix_call_table;
            WARN_(module)("iOS: no unix .so for module %p (unix_path=%s, modname=%s), using stub table\n",
                          module, up ? up : "(null)", modname ? modname : "(null)");
            status = STATUS_SUCCESS;
        }
    }
#endif
    return status;
}


/***********************************************************************
 *           set_builtin_unixlib_name
 */
NTSTATUS set_builtin_unixlib_name( void *module, const char *name )
{
    sigset_t sigset;
    NTSTATUS status = STATUS_SUCCESS;
    struct builtin_module *builtin;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if ((builtin = get_builtin_module( module )))
    {
        if (!builtin->unix_path) builtin->unix_path = strdup( name );
        else status = STATUS_IMAGE_ALREADY_LOADED;
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return status;
}


/***********************************************************************
 *           free_ranges_lower_bound
 *
 * Returns the first range whose end is not less than addr, or end if there's none.
 */
static struct range_entry *free_ranges_lower_bound( void *addr )
{
    struct range_entry *begin = free_ranges;
    struct range_entry *end = free_ranges_end;
    struct range_entry *mid;

    while (begin < end)
    {
        mid = begin + (end - begin) / 2;
        if (mid->end < addr)
            begin = mid + 1;
        else
            end = mid;
    }

    return begin;
}

static void dump_free_ranges(void)
{
    struct range_entry *r;
    for (r = free_ranges; r != free_ranges_end; ++r)
        TRACE_(virtual_ranges)("%p - %p.\n", r->base, r->end);
}

/***********************************************************************
 *           free_ranges_insert_view
 *
 * Updates the free_ranges after a new view has been created.
 */
static void free_ranges_insert_view( struct file_view *view )
{
    void *view_base = ROUND_ADDR( view->base, granularity_mask );
    void *view_end = ROUND_ADDR( (char *)view->base + view->size + granularity_mask, granularity_mask );
    struct range_entry *range = free_ranges_lower_bound( view_base );
    struct range_entry *next = range + 1;

    /* free_ranges initial value is such that the view is either inside range or before another one. */
    assert( range != free_ranges_end );
    assert( range->end > view_base || next != free_ranges_end );

    /* Free ranges addresses are aligned at granularity_mask while the views may be not. */

    if (range->base > view_base)
        view_base = range->base;
    if (range->end < view_end)
        view_end = range->end;
    if (range->end == view_base && next->base >= view_end)
        view_end = view_base;

    TRACE_(virtual_ranges)( "%p - %p, aligned %p - %p.\n",
                            view->base, (char *)view->base + view->size, view_base, view_end );

    if (view_end <= view_base)
    {
        VIRTUAL_DEBUG_DUMP_RANGES();
        return;
    }

    /* this should never happen */
    if (range->base > view_base || range->end < view_end)
        ERR( "range %p - %p is already partially mapped\n", view_base, view_end );
    assert( range->base <= view_base && range->end >= view_end );

    /* need to split the range in two */
    if (range->base < view_base && range->end > view_end)
    {
        memmove( next + 1, next, (free_ranges_end - next) * sizeof(struct range_entry) );
        free_ranges_end += 1;
        if ((char *)free_ranges_end - (char *)free_ranges > view_block_size)
            ERR( "Free range sequence is full, trouble ahead!\n" );
        assert( (char *)free_ranges_end - (char *)free_ranges <= view_block_size );

        next->base = view_end;
        next->end = range->end;
        range->end = view_base;
    }
    else
    {
        /* otherwise we just have to shrink it */
        if (range->base < view_base)
            range->end = view_base;
        else
            range->base = view_end;

        if (range->base < range->end)
        {
            VIRTUAL_DEBUG_DUMP_RANGES();
            return;
        }
        /* and possibly remove it if it's now empty */
        memmove( range, next, (free_ranges_end - next) * sizeof(struct range_entry) );
        free_ranges_end -= 1;
        assert( free_ranges_end - free_ranges > 0 );
    }
    VIRTUAL_DEBUG_DUMP_RANGES();
}

/***********************************************************************
 *           free_ranges_remove_view
 *
 * Updates the free_ranges after a view has been destroyed.
 */
static void free_ranges_remove_view( struct file_view *view )
{
    void *view_base = ROUND_ADDR( view->base, granularity_mask );
    void *view_end = ROUND_ADDR( (char *)view->base + view->size + granularity_mask, granularity_mask );
    struct range_entry *range = free_ranges_lower_bound( view_base );
    struct range_entry *next = range + 1;

    /* Free ranges addresses are aligned at granularity_mask while the views may be not. */
    struct file_view *prev_view = RB_ENTRY_VALUE( rb_prev( &view->entry ), struct file_view, entry );
    struct file_view *next_view = RB_ENTRY_VALUE( rb_next( &view->entry ), struct file_view, entry );
    void *prev_view_base = prev_view ? ROUND_ADDR( prev_view->base, granularity_mask ) : NULL;
    void *prev_view_end = prev_view ? ROUND_ADDR( (char *)prev_view->base + prev_view->size + granularity_mask, granularity_mask ) : NULL;
    void *next_view_base = next_view ? ROUND_ADDR( next_view->base, granularity_mask ) : NULL;
    void *next_view_end = next_view ? ROUND_ADDR( (char *)next_view->base + next_view->size + granularity_mask, granularity_mask ) : NULL;

    if (prev_view_end && prev_view_end > view_base && prev_view_base < view_end)
        view_base = prev_view_end;
    if (next_view_base && next_view_base < view_end && next_view_end > view_base)
        view_end = next_view_base;

    TRACE_(virtual_ranges)( "%p - %p, aligned %p - %p.\n",
                            view->base, (char *)view->base + view->size, view_base, view_end );

    if (view_end <= view_base)
    {
        VIRTUAL_DEBUG_DUMP_RANGES();
        return;
    }
    /* free_ranges initial value is such that the view is either inside range or before another one. */
    assert( range != free_ranges_end );
    assert( range->end > view_base || next != free_ranges_end );

    /* this should never happen, but we can safely ignore it */
    if (range->base <= view_base && range->end >= view_end)
    {
        WARN( "range %p - %p is already unmapped\n", view_base, view_end );
        return;
    }

    /* this should never happen */
    if (range->base < view_end && range->end > view_base)
        ERR( "range %p - %p is already partially unmapped\n", view_base, view_end );
    assert( range->end <= view_base || range->base >= view_end );

    /* merge with next if possible */
    if (range->end == view_base && next->base == view_end)
    {
        range->end = next->end;
        memmove( next, next + 1, (free_ranges_end - next - 1) * sizeof(struct range_entry) );
        free_ranges_end -= 1;
        assert( free_ranges_end - free_ranges > 0 );
    }
    /* or try growing the range */
    else if (range->end == view_base)
        range->end = view_end;
    else if (range->base == view_end)
        range->base = view_base;
    /* otherwise create a new one */
    else
    {
        memmove( range + 1, range, (free_ranges_end - range) * sizeof(struct range_entry) );
        free_ranges_end += 1;
        if ((char *)free_ranges_end - (char *)free_ranges > view_block_size)
            ERR( "Free range sequence is full, trouble ahead!\n" );
        assert( (char *)free_ranges_end - (char *)free_ranges <= view_block_size );

        range->base = view_base;
        range->end = view_end;
    }
    VIRTUAL_DEBUG_DUMP_RANGES();
}


static inline int is_view_valloc( const struct file_view *view )
{
    return !(view->protect & (SEC_FILE | SEC_RESERVE | SEC_COMMIT));
}

/***********************************************************************
 *           get_page_vprot
 *
 * Return the page protection byte.
 */
static BYTE get_page_vprot( const void *addr )
{
    size_t idx = (size_t)addr >> page_shift;

#ifdef _WIN64
    if ((idx >> pages_vprot_shift) >= pages_vprot_size) return 0;
    if (!pages_vprot[idx >> pages_vprot_shift]) return 0;
    return pages_vprot[idx >> pages_vprot_shift][idx & pages_vprot_mask];
#else
    return pages_vprot[idx];
#endif
}

/* iOS-Madeira ml306 (task #53): lock-free vprot peek for the Mach reclaim handler.
 *
 * The [reclaim-recover] path in signal_arm64_ios.c re-mmaps arena-band pages whose host
 * mapping has vanished (mprotect ENOMEM), on the assumption that fresh zeros are correct.
 * That assumption was written for LookupCache pages; the band now holds FEX's entire host
 * heap, and ml305 died on a null+0x90 deref through a pointer that plausibly came from such
 * a zero-filled page. Whether zero-fill is safe hinges on one bit that only Wine knows:
 * VPROT_COMMITTED. Committed-then-vanished means data loss or use-after-free (zeros MASK a
 * real bug); never-committed means lazy-reservation first touch (zeros are the contract).
 *
 * Deliberately no locking: this is called from the Mach exception thread while the faulting
 * thread is suspended possibly holding virtual_mutex, so taking any lock could deadlock.
 * get_page_vprot is a plain two-level array read and the fault paths already use it this
 * way; a stale read only mislabels one diagnostic line. */
unsigned char ios_reclaim_page_vprot( unsigned long long va )
{
    return get_page_vprot( (const void *)(uintptr_t)va );
}


/***********************************************************************
 *           get_host_page_vprot
 *
 * Return the union of the page protection bytes of all the pages making up the host page.
 */
static BYTE get_host_page_vprot( const void *addr )
{
    size_t i, idx = (size_t)ROUND_ADDR( addr, host_page_mask ) >> page_shift;
    const BYTE *vprot_ptr;
    BYTE vprot = 0;

#ifdef _WIN64
    if ((idx >> pages_vprot_shift) >= pages_vprot_size) return 0;
    if (!pages_vprot[idx >> pages_vprot_shift]) return 0;
    assert( host_page_mask >> page_shift <= pages_vprot_mask );
    vprot_ptr = pages_vprot[idx >> pages_vprot_shift] + (idx & pages_vprot_mask);
#else
    vprot_ptr = pages_vprot + idx;
#endif
    for (i = 0; i < host_page_size / page_size; i++) vprot |= vprot_ptr[i];
    return vprot;
}


/***********************************************************************
 *           get_vprot_range_size
 *
 * Return the size of the region with equal masked vprot byte.
 * Also return the protections for the first page.
 * The function assumes that base and size are page aligned,
 * base + size does not wrap around and the range is within view so
 * vprot bytes are allocated for the range. */
static SIZE_T get_vprot_range_size( char *base, SIZE_T size, BYTE mask, BYTE *vprot )
{
    static const UINT_PTR word_from_byte = (UINT_PTR)0x101010101010101;
    static const UINT_PTR index_align_mask = sizeof(UINT_PTR) - 1;
    SIZE_T curr_idx, start_idx, end_idx, aligned_start_idx;
    UINT_PTR vprot_word, mask_word;
    const BYTE *vprot_ptr;

    TRACE("base %p, size %p, mask %#x.\n", base, (void *)size, mask);

    curr_idx = start_idx = (size_t)base >> page_shift;
    end_idx = start_idx + (size >> page_shift);

    aligned_start_idx = ROUND_SIZE( 0, start_idx, index_align_mask );
    if (aligned_start_idx > end_idx) aligned_start_idx = end_idx;

#ifdef _WIN64
    vprot_ptr = pages_vprot[curr_idx >> pages_vprot_shift] + (curr_idx & pages_vprot_mask);
#else
    vprot_ptr = pages_vprot + curr_idx;
#endif
    *vprot = *vprot_ptr;

    /* Page count page table is at least the multiples of sizeof(UINT_PTR)
     * so we don't have to worry about crossing the boundary on unaligned idx values. */

    for (; curr_idx < aligned_start_idx; ++curr_idx, ++vprot_ptr)
        if ((*vprot ^ *vprot_ptr) & mask) return (curr_idx - start_idx) << page_shift;

    vprot_word = word_from_byte * *vprot;
    mask_word = word_from_byte * mask;
    for (; curr_idx < end_idx; curr_idx += sizeof(UINT_PTR), vprot_ptr += sizeof(UINT_PTR))
    {
#ifdef _WIN64
        if (!(curr_idx & pages_vprot_mask)) vprot_ptr = pages_vprot[curr_idx >> pages_vprot_shift];
#endif
        if ((vprot_word ^ *(UINT_PTR *)vprot_ptr) & mask_word)
        {
            for (; curr_idx < end_idx; ++curr_idx, ++vprot_ptr)
                if ((*vprot ^ *vprot_ptr) & mask) break;
            return (curr_idx - start_idx) << page_shift;
        }
    }
    return size;
}

/***********************************************************************
 *           set_page_vprot
 *
 * Set a range of page protection bytes.
 */
static void set_page_vprot( const void *addr, size_t size, BYTE vprot )
{
    size_t idx = (size_t)addr >> page_shift;
    size_t end = ((size_t)addr + size + page_mask) >> page_shift;

#ifdef _WIN64
    while (idx >> pages_vprot_shift != end >> pages_vprot_shift)
    {
        size_t dir_size = pages_vprot_mask + 1 - (idx & pages_vprot_mask);
        memset( pages_vprot[idx >> pages_vprot_shift] + (idx & pages_vprot_mask), vprot, dir_size );
        idx += dir_size;
    }
    memset( pages_vprot[idx >> pages_vprot_shift] + (idx & pages_vprot_mask), vprot, end - idx );
#else
    memset( pages_vprot + idx, vprot, end - idx );
#endif
}


/***********************************************************************
 *           set_page_vprot_bits
 *
 * Set or clear bits in a range of page protection bytes.
 */
static void set_page_vprot_bits( const void *addr, size_t size, BYTE set, BYTE clear )
{
    size_t idx = (size_t)addr >> page_shift;
    size_t end = ((size_t)addr + size + page_mask) >> page_shift;

#ifdef _WIN64
    for ( ; idx < end; idx++)
    {
        BYTE *ptr = pages_vprot[idx >> pages_vprot_shift] + (idx & pages_vprot_mask);
        *ptr = (*ptr & ~clear) | set;
    }
#else
    for ( ; idx < end; idx++) pages_vprot[idx] = (pages_vprot[idx] & ~clear) | set;
#endif
}


/***********************************************************************
 *           set_page_vprot_exec_write_protect
 *
 * Write protect pages that are executable.
 */
static BOOL set_page_vprot_exec_write_protect( const void *addr, size_t size )
{
    BOOL ret = FALSE;
#ifdef _WIN64 /* only supported on 64-bit so assume 2-level table */
    size_t idx = (size_t)addr >> page_shift;
    size_t end = ((size_t)addr + size + page_mask) >> page_shift;

    for ( ; idx < end; idx++)
    {
        BYTE *ptr = pages_vprot[idx >> pages_vprot_shift] + (idx & pages_vprot_mask);
        if (!is_vprot_exec_write( *ptr )) continue;
        *ptr |= VPROT_WRITEWATCH;
        ret = TRUE;
    }
#endif
    return ret;
}


/***********************************************************************
 *           alloc_pages_vprot
 *
 * Allocate the page protection bytes for a given range.
 */
static BOOL alloc_pages_vprot( const void *addr, size_t size )
{
#ifdef _WIN64
    size_t idx = (size_t)addr >> page_shift;
    size_t end = ((size_t)addr + size + page_mask) >> page_shift;
    size_t i;
    void *ptr;

    assert( end <= pages_vprot_size << pages_vprot_shift );
    for (i = idx >> pages_vprot_shift; i < (end + pages_vprot_mask) >> pages_vprot_shift; i++)
    {
        if (pages_vprot[i]) continue;
        if ((ptr = anon_mmap_alloc( pages_vprot_mask + 1, PROT_READ | PROT_WRITE )) == MAP_FAILED)
        {
            ERR( "anon mmap error %s for vprot table, size %08lx\n", strerror(errno), pages_vprot_mask + 1 );
            return FALSE;
        }
        pages_vprot[i] = ptr;
    }
#endif
    return TRUE;
}


static inline UINT64 maskbits( size_t idx )
{
    return ~(UINT64)0 << (idx & 63);
}

/***********************************************************************
 *           set_arm64ec_range
 */
static BOOL set_vprot( struct file_view *view, void *base, size_t size, BYTE vprot );  /* fwd-decl */

static void set_arm64ec_range( const void *addr, size_t size )
{
    UINT64 *map = arm64ec_view->base;
    /* iOS-Madeira: arm64x_check_call hardcodes 4KB-page indexing per the
     * Windows ABI (`lsr x11, #12` and `lsr x11, #18`) regardless of host
     * page size. iOS uses 16KB pages (page_shift=14). Always use a 12-bit
     * shift here so check_call's reads land at the same bitmap byte we
     * write to. */
    const unsigned int ec_page_shift = 12;
    const size_t ec_page_mask = (1ULL << ec_page_shift) - 1;
    size_t idx = (size_t)addr >> ec_page_shift;
    size_t end = ((size_t)addr + size + ec_page_mask) >> ec_page_shift;
    size_t pos = idx / 64;
    size_t end_pos = end / 64;

    if (end_pos > pos)
    {
        map[pos++] |= maskbits( idx );
        while (pos < end_pos) map[pos++] = ~(UINT64)0;
        if (end & 63) map[pos] |= ~maskbits( end );
    }
    else map[pos] |= maskbits( idx ) & ~maskbits( end );
}

/* Exported: mark an arbitrary range (e.g. hand-written stubs in the pool's
 * reserved page) as ARM64EC code, committing the covering bitmap pages
 * first. Without the bit set, arm64x_check_call routes branches to the
 * range into the x86 emulator, which compiles the ARM64 bytes as x86
 * (observed: the unix-call x18-restore stub executed as guest RIP).
 * Returns 1 if marked, 0 if the EC bitmap doesn't exist yet (caller
 * must treat the range as NOT callable via checked indirect calls). */
int ios_jit_mark_ec_range( const void *addr, size_t size )
{
    if (!arm64ec_view) return 0;
    {
        size_t bm_start = ((size_t)addr >> 12) / 8;
        size_t bm_end   = (((size_t)addr + size) >> 12) / 8;
        size_t bm_size  = ROUND_SIZE( bm_start, bm_end + 1 - bm_start, page_mask );
        void *bm_page   = ROUND_ADDR( (char *)arm64ec_view->base + bm_start, page_mask );
        set_vprot( arm64ec_view, bm_page, bm_size, VPROT_READ | VPROT_WRITE | VPROT_COMMITTED );
    }
    set_arm64ec_range( addr, size );
    return 1;
}

/* upstream's clear_arm64ec_range (defined below) is the inverse of
 * set_arm64ec_range; reclamation clears freed ranges so a reused range
 * that later hosts a pure-x64 copy doesn't keep stale EC bits (which
 * would make arm64x_check_call BL into x86-64 bytes as if ARM64). */
static void clear_arm64ec_range( const void *addr, size_t size );

/* Task #25: release everything a dead pseudo-process allocated from the
 * pool head. Called from process_exit_wrapper on the dying process's own
 * thread — its ranges become reusable after IOS_POOL_REUSE_GRACE_SEC (see
 * the ledger comment for why laggard exit threads make immediate reuse
 * unsafe). Mapping entries covering freed ranges are tombstoned
 * (size=0 → matches nothing; pe_base=NULL → slot reusable); anon RWX
 * aliases (FEX CodeBuffers) in freed ranges are cleared; EC bitmap bits
 * are cleared so a reused range starts with a clean call-routing slate. */
void ios_jit_reclaim_process( void *peb )
{
    size_t total = 0;
    int ranges = 0, maps_killed = 0, aliases_killed = 0;
    int i, j;
    char *rx_base = (char *)ios_jit_rx_base_global;

    if (!peb || !rx_base) return;

    pthread_mutex_lock( &ios_pool_lock );

    for (i = 0; i < ios_pool_ledger_count; )
    {
        size_t off, size;
        if (ios_pool_ledger[i].peb != peb) { i++; continue; }
        off  = ios_pool_ledger[i].off;
        size = ios_pool_ledger[i].size;

        /* Tombstone mapping entries whose pool copy lives in this range.
         * Write order matters for the lock-free readers (translate /
         * fault handler): size=0 first — a zero-size entry matches no
         * query — then pe_base=NULL (the free-slot marker). */
        for (j = 0; j < ios_jit_mapping_count; j++)
        {
            char *jb = (char *)ios_jit_mappings[j].jit_base;
            if (!ios_jit_mappings[j].pe_base) continue;
            if (jb >= rx_base + off && jb < rx_base + off + size)
            {
                ios_jit_mappings[j].size = 0;
                __sync_synchronize();
                ios_jit_mappings[j].pe_base = NULL;
                maps_killed++;
            }
        }

        /* Clear anon RWX aliases (FEX CodeBuffers) backed by this range. */
        for (j = 0; j < ios_jit_anon_alias_count; j++)
        {
            uintptr_t rx = ios_jit_anon_aliases[j].jit_rx_alias;
            if (!ios_jit_anon_aliases[j].user_va) continue;
            if (rx >= (uintptr_t)(rx_base + off) && rx < (uintptr_t)(rx_base + off + size))
            {
                ios_jit_anon_aliases[j].user_va_end = 0;
                __sync_synchronize();
                ios_mono_alias_retire( ios_jit_anon_aliases[j].user_va );  /* ml648: unmap/teardown */
                ios_jit_anon_aliases[j].user_va = 0;
                aliases_killed++;
            }
        }

        /* ml244: bracket clear_arm64ec_range. The free-time check below fires on 20 ranges
         * ("narrowed during the module's life"), but it sits AFTER this call -- which
         * operates on the same pool range -- so it could be observing poison this very call
         * creates. Check immediately before to separate "already poisoned when we got here"
         * from "clear_arm64ec_range narrows it". */
        {
            unsigned int bcur = 0, bmax = 0;
            static int prechk;

            if (!ios_pool_range_execable( off, size, &bcur, &bmax ) && prechk++ < 20)
            {
                /* ml249: name the OWNER of the poisoned page here, not at hand-out -- the
                 * guard now rejects poisoned ranges before hand-out, so the probe there can
                 * never fire (0 hits vs 20 here). mprotect_exec is called ZERO times on pool
                 * VA, so nothing narrows maxprot in place; the pages must be REPLACED by a
                 * different mapping. Mach's user_tag identifies the allocator and share_mode
                 * distinguishes our dual-mapped alias from an ordinary private mapping, which
                 * is what tells us whether Wine handed out VA overlapping the pool. */
                extern void *ios_jit_rx_base_global;
                mach_vm_address_t ea = (mach_vm_address_t)(uintptr_t)((char *)ios_jit_rx_base_global + off);
                mach_vm_size_t esz = 0;
                vm_region_extended_info_data_t ext;
                mach_msg_type_number_t ecnt = VM_REGION_EXTENDED_INFO_COUNT;
                mach_port_t eobj = MACH_PORT_NULL;
                unsigned tag = 0, share = 0;
                size_t scan;

                /* walk to the first genuinely poisoned page inside the range */
                for (scan = 0; scan < size; scan += 0x4000)
                {
                    mach_vm_address_t a2 = (mach_vm_address_t)(uintptr_t)((char *)ios_jit_rx_base_global + off + scan), q = a2;
                    mach_vm_size_t s2 = 0;
                    vm_region_basic_info_data_64_t b2;
                    mach_msg_type_number_t c2 = VM_REGION_BASIC_INFO_COUNT_64;
                    mach_port_t o2 = MACH_PORT_NULL;

                    if (mach_vm_region( mach_task_self(), &q, &s2, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&b2, &c2, &o2 ) != KERN_SUCCESS) break;
                    if (q > a2) continue;
                    if (!(b2.max_protection & VM_PROT_EXECUTE)) { ea = a2; break; }
                }
                if (mach_vm_region( mach_task_self(), &ea, &esz, VM_REGION_EXTENDED_INFO,
                                    (vm_region_info_t)&ext, &ecnt, &eobj ) == KERN_SUCCESS)
                { tag = ext.user_tag; share = ext.share_mode; }

                dprintf( 2, "[pool-freechk] PRE-CLEAR poisoned off=0x%lx size=0x%lx cur=0x%x max=0x%x"
                            " | page=%p user_tag=%u share_mode=%u regionsz=0x%llx\n",
                         (unsigned long)off, (unsigned long)size, bcur, bmax,
                         (void *)(uintptr_t)ea, tag, share, (unsigned long long)esz );
            }
        }
        if (arm64ec_view) clear_arm64ec_range( rx_base + off, size );

        /* ml243: is the range ALREADY poisoned when it is freed?
         *
         * The guard now refuses poisoned ranges (correct) but never recovers them -- 62
         * drops = 164MB orphaned from an 896MB pool, which already sits at 86% used. The
         * durable fix is to stop the poison being CREATED, so pin down when maxprot is
         * narrowed: during the module's life (poisoned here at free time) or later while
         * the range sits on the freelist (clean here, poisoned at reuse). Those need
         * completely different fixes. Self-targeting: prints only when poisoned. */
        {
            unsigned int fcur = 0, fmax = 0;
            static int freechk;

            if (!ios_pool_range_execable( off, size, &fcur, &fmax ) && freechk++ < 20)
                dprintf( 2, "[pool-freechk] POISONED AT FREE off=0x%lx size=0x%lx cur=0x%x max=0x%x"
                            "  <== narrowed during the module's life\n",
                         (unsigned long)off, (unsigned long)size, fcur, fmax );
        }

        if (ios_pool_free_count < IOS_POOL_FREE_MAX)
        {
            ios_pool_freelist[ios_pool_free_count].off = off;
            ios_pool_freelist[ios_pool_free_count].size = size;
            ios_pool_freelist[ios_pool_free_count].freed_at = time( NULL );
            /* Physical pages returned post-grace by the allocator's
             * MADV_FREE sweep (not here — laggard exit threads may still
             * execute this range during the grace window, and a purged
             * page reads zero). */
            ios_pool_freelist[ios_pool_free_count].advised = 0;
            ios_pool_free_count++;
            total += size;
            ranges++;
        }
        else dprintf(2, "[jit-pool] freelist FULL — leaking range off=0x%lx size=0x%lx\n",
                     (unsigned long)off, (unsigned long)size);

        /* Remove ledger entry (swap-with-last). */
        ios_pool_ledger[i] = ios_pool_ledger[--ios_pool_ledger_count];
    }

    pthread_mutex_unlock( &ios_pool_lock );

    if (ranges || maps_killed)
        dprintf(2, "[jit-pool] RECLAIM peb=%p: %d ranges 0x%lx bytes freed (grace %ds), "
                "%d mappings tombstoned, %d anon aliases cleared; bump=0x%lx freelist=%d\n",
                peb, ranges, (unsigned long)total, IOS_POOL_REUSE_GRACE_SEC,
                maps_killed, aliases_killed,
                (unsigned long)jit_pool_offset, ios_pool_free_count);
}


/***********************************************************************
 *           clear_arm64ec_range
 */
static void clear_arm64ec_range( const void *addr, size_t size )
{
    UINT64 *map = arm64ec_view->base;
    /* ml113 (task #35 fallout, but a pre-existing bug): commit the covering
     * bitmap pages BEFORE writing, exactly as ios_jit_mark_ec_range does for
     * the set path. This clear runs from ios_jit_reclaim_process for EVERY
     * freed pool range — including copies whose EC bits were never set (pure
     * x86-64 images), whose bitmap coverage is therefore still uncommitted
     * reserve. The blind store then faults. It never crashed before only by
     * accident: the bitmap's old home (0x7ef1dc0000) sat inside the
     * [496G,512G) reclaim-recover band, which silently mprotect-committed
     * such faults; the furniture ceiling moved the bitmap to 0x72f1dc0000,
     * outside the band, and the first uncommitted clear killed a child at
     * exit (ios_jit_reclaim_process+0x1d4, fault 0x72f1de3e68 = qword for
     * pool VA ~0x11F340000). */
    {
        size_t bm_start = ((size_t)addr >> 12) / 8;
        size_t bm_end   = (((size_t)addr + size) >> 12) / 8;
        size_t bm_size  = ROUND_SIZE( bm_start, bm_end + 1 - bm_start, page_mask );
        void *bm_page   = ROUND_ADDR( (char *)arm64ec_view->base + bm_start, page_mask );
        /* set_vprot alone is the whole commit — it mprotects the covering
         * pages RW without zeroing, exactly as the set path proves.
         * (An mmap-over here would ZERO committed pages and wipe other
         * modules' EC bits.) */
        set_vprot( arm64ec_view, bm_page, bm_size, VPROT_READ | VPROT_WRITE | VPROT_COMMITTED );
    }
    const unsigned int ec_page_shift = 12;
    const size_t ec_page_mask = (1ULL << ec_page_shift) - 1;
    size_t idx = (size_t)addr >> ec_page_shift;
    size_t end = ((size_t)addr + size + ec_page_mask) >> ec_page_shift;
    size_t pos = idx / 64;
    size_t end_pos = end / 64;

    if (end_pos > pos)
    {
        map[pos++] &= ~maskbits( idx );
        while (pos < end_pos) map[pos++] = 0;
        if (end & 63) map[pos] &= maskbits( end );
    }
    else map[pos] &= ~maskbits( idx ) | maskbits( end );
}

/***********************************************************************
 *           clear_arm64ec_range_committed
 *
 * ml113 (task #35 fallout): commit-aware clear for the EXIT-TIME reclaim.
 * The EC bitmap is a sparse reservation — the set side commits covering
 * pages before writing (ios_jit_mark_ec_range), but the reclaim cleared
 * blindly and first-touched an uncommitted bitmap page inside
 * process_exit_wrapper's mach-handler context.
 *
 * SUPERSEDED, NO SUCH FUNCTION: the commit was folded into
 * clear_arm64ec_range itself (set_vprot before the clear). This header is all
 * that was left, and it had lost its terminator, so it was swallowing the
 * comment below it (-Wcomment). Kept for the ml113 rationale only.
 */


/***********************************************************************
 *           compare_view
 *
 * View comparison function used for the rb tree.
 */
static int compare_view( const void *addr, const struct wine_rb_entry *entry )
{
    struct file_view *view = WINE_RB_ENTRY_VALUE( entry, struct file_view, entry );

    if (addr < view->base) return -1;
    if (addr > view->base) return 1;
    return 0;
}


/***********************************************************************
 *           get_prot_str
 */
static const char *get_prot_str( BYTE prot )
{
    static char buffer[6];
    buffer[0] = (prot & VPROT_COMMITTED) ? 'c' : '-';
    buffer[1] = (prot & VPROT_GUARD) ? 'g' : ((prot & VPROT_WRITEWATCH) ? 'H' : '-');
    buffer[2] = (prot & VPROT_READ) ? 'r' : '-';
    buffer[3] = (prot & VPROT_WRITECOPY) ? 'W' : ((prot & VPROT_WRITE) ? 'w' : '-');
    buffer[4] = (prot & VPROT_EXEC) ? 'x' : '-';
    buffer[5] = 0;
    return buffer;
}


/***********************************************************************
 *           get_unix_prot
 *
 * Convert page protections to protection for mmap/mprotect.
 */
static int get_unix_prot( BYTE vprot )
{
    int prot = 0;
    if ((vprot & VPROT_COMMITTED) && !(vprot & VPROT_GUARD))
    {
        if (vprot & VPROT_READ) prot |= PROT_READ;
        if (vprot & VPROT_WRITE) prot |= PROT_WRITE | PROT_READ;
        if (vprot & VPROT_WRITECOPY) prot |= PROT_WRITE | PROT_READ;
        if (vprot & VPROT_EXEC) prot |= PROT_EXEC | PROT_READ;
        if (vprot & VPROT_WRITEWATCH) prot &= ~PROT_WRITE;
    }
    if (!prot) prot = PROT_NONE;
    return prot;
}


/***********************************************************************
 *           dump_view
 */
static void dump_view( struct file_view *view )
{
    UINT i, count;
    char *addr = view->base;
    BYTE prot = get_page_vprot( addr );

    TRACE( "View: %p - %p %s", addr, addr + view->size - 1, get_prot_str(view->protect) );
    if (view->protect & VPROT_SYSTEM)
        TRACE( " (builtin image)\n" );
    else if (view->protect & VPROT_FREE_PLACEHOLDER)
        TRACE( " (placeholder)\n" );
    else if (view->protect & SEC_IMAGE)
        TRACE( " (image)\n" );
    else if (view->protect & SEC_FILE)
        TRACE( " (file)\n" );
    else if (view->protect & (SEC_RESERVE | SEC_COMMIT))
        TRACE( " (anonymous)\n" );
    else
        TRACE( " (valloc)\n");

    for (count = i = 1; i < view->size >> page_shift; i++, count++)
    {
        BYTE next = get_page_vprot( addr + (count << page_shift) );
        if (next == prot) continue;
        TRACE( "      %p - %p %s\n",
                 addr, addr + (count << page_shift) - 1, get_prot_str(prot) );
        addr += (count << page_shift);
        prot = next;
        count = 0;
    }
    if (count)
        TRACE( "      %p - %p %s\n",
                 addr, addr + (count << page_shift) - 1, get_prot_str(prot) );
}


/***********************************************************************
 *           VIRTUAL_Dump
 */
#ifdef WINE_VM_DEBUG
static void VIRTUAL_Dump(void)
{
    sigset_t sigset;
    struct file_view *view;

    TRACE( "Dump of all virtual memory views:\n" );
    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    WINE_RB_FOR_EACH_ENTRY( view, &views_tree, struct file_view, entry )
    {
        dump_view( view );
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
}
#endif


/***********************************************************************
 *           find_view
 *
 * Find the view containing a given address. virtual_mutex must be held by caller.
 *
 * PARAMS
 *      addr  [I] Address
 *
 * RETURNS
 *	View: Success
 *	NULL: Failure
 */
static struct file_view *find_view( const void *addr, size_t size )
{
    struct wine_rb_entry *ptr = views_tree.root;

    if ((const char *)addr + size < (const char *)addr) return NULL; /* overflow */

    while (ptr)
    {
        struct file_view *view = WINE_RB_ENTRY_VALUE( ptr, struct file_view, entry );

        if (view->base > addr) ptr = ptr->left;
        else if ((const char *)view->base + view->size <= (const char *)addr) ptr = ptr->right;
        else if ((const char *)view->base + view->size < (const char *)addr + size) break;  /* size too large */
        else return view;
    }
    return NULL;
}


/***********************************************************************
 *           is_write_watch_range
 */
static inline BOOL is_write_watch_range( const void *addr, size_t size )
{
    struct file_view *view = find_view( addr, size );
    return view && (view->protect & VPROT_WRITEWATCH);
}


/***********************************************************************
 *           find_view_range
 *
 * Find the first view overlapping at least part of the specified range.
 * virtual_mutex must be held by caller.
 */
static struct file_view *find_view_range( const void *addr, size_t size )
{
    struct wine_rb_entry *ptr = views_tree.root;

    while (ptr)
    {
        struct file_view *view = WINE_RB_ENTRY_VALUE( ptr, struct file_view, entry );

        if ((const char *)view->base >= (const char *)addr + size) ptr = ptr->left;
        else if ((const char *)view->base + view->size <= (const char *)addr) ptr = ptr->right;
        else return view;
    }
    return NULL;
}


/***********************************************************************
 *           find_view_inside_range
 *
 * Find first (resp. last, if top_down) view inside a range.
 * virtual_mutex must be held by caller.
 */
static struct wine_rb_entry *find_view_inside_range( void **base_ptr, void **end_ptr, int top_down )
{
    struct wine_rb_entry *first = NULL, *ptr = views_tree.root;
    void *base = *base_ptr, *end = *end_ptr;

    /* find the first (resp. last) view inside the range */
    while (ptr)
    {
        struct file_view *view = WINE_RB_ENTRY_VALUE( ptr, struct file_view, entry );
        if ((char *)view->base + view->size >= (char *)end)
        {
            end = min( end, view->base );
            ptr = ptr->left;
        }
        else if (view->base <= base)
        {
            base = max( (char *)base, (char *)view->base + view->size );
            ptr = ptr->right;
        }
        else
        {
            first = ptr;
            ptr = top_down ? ptr->right : ptr->left;
        }
    }

    *base_ptr = base;
    *end_ptr = end;
    return first;
}


/***********************************************************************
 *           try_map_free_area
 *
 * Try mmaping some expected free memory region, eventually stepping and
 * retrying inside it, and return where it actually succeeded, or NULL.
 */
/* ml211: ask Mach where the mapping occupying `addr` ends, so the scan can jump over it.
 *
 * Wine's rb tree only knows Wine's OWN views (53 in a Steam run), but the [furniture]
 * census found 57347 FOREIGN 16KB Mach regions packed solid from 0x7000000000 to
 * 0x7038000000. try_map_free_area steps one align granule at a time, so crossing those
 * costs one failed mmap each -- ~8000 syscalls to place a single 1MB allocation, while the
 * window still had 15.4GB contiguous free the entire time. The address space was never
 * exhausted; the scanner was crawling.
 *
 * Returns 1 and sets *out only when Mach confirms `addr` is inside a mapped region, so
 * this can only ever skip provably-occupied space. Anything else returns 0 and the caller
 * falls back to the plain step, which keeps a wrong answer here free of consequence.
 * Forward progress is guaranteed in both directions: bottom-up resumes past the region
 * end (> addr, since the region contains addr), top-down at region base - size (< addr). */
static int ios_skip_occupied( void *addr, size_t size, size_t align_mask,
                              int top_down, void **out )
{
    mach_vm_address_t a = (mach_vm_address_t)(uintptr_t)addr, rbase = a;
    mach_vm_size_t rsize = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;

    if (mach_vm_region( mach_task_self(), &rbase, &rsize, VM_REGION_BASIC_INFO_64,
                        (vm_region_info_t)&info, &cnt, &obj ) != KERN_SUCCESS)
        return 0;
    if (rbase > a || !rsize)
        return 0;         /* addr is in a free hole: mmap failed for some other reason
                             (iOS refuses certain addresses), so stepping is correct */
    if (top_down)
    {
        if (rbase < (mach_vm_address_t)size) return 0;
        *out = ROUND_ADDR( (char *)(uintptr_t)rbase - size, align_mask );
    }
    else
    {
        mach_vm_address_t nxt = rbase + rsize;

        *out = (void *)(uintptr_t)((nxt + align_mask) & ~(mach_vm_address_t)align_mask);
    }
    return 1;
}

static void* try_map_free_area( void *base, void *end, ptrdiff_t step,
                                void *start, size_t size, int unix_prot )
{
    while (start && base <= start && (char*)start + size <= (char*)end)
    {
        /* ml253 ROOT-CAUSE FIX: never allocate inside the JIT pool.
         *
         * Wine's scanner walks straight through the pool -- measured, marching upward in
         * 0x10000 steps calling anon_mmap_tryfixed at every address:
         *   [pool-va] anon_mmap_tryfixed addr=0x11e800000 size=0x100000 INSIDE RX pool off=0x0
         *   [pool-va] anon_mmap_tryfixed addr=0x11e810000 ... off=0x10000   (etc)
         * Where the pool is mapped these fail (that is the scan grinding). Wherever the pool
         * has a HOLE they SUCCEED, installing a foreign one-page RW mapping -- exactly the
         * poison fingerprint (regionsz=0x4000, user_tag=0, max=RW, unraisable), which then
         * lands in a module's .text as a permanently non-executable page. When Wine later
         * releases such an allocation the hole becomes MEM_FREE inside the pool span, which
         * is what the fatal CASPAL dereferences (0x1541af700, state=MEM_FREE).
         *
         * One cause, three symptoms. The pool is ours; Wine must never hand out its VA.
         * Skipping the whole pool in one jump is also strictly faster than stepping it. */
        {
            extern void *ios_jit_rx_base_global;
            extern void *ios_jit_rw_base_global;
            extern size_t ios_jit_pool_size_global;
            uintptr_t a = (uintptr_t)start;
            uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
            uintptr_t rw = (uintptr_t)ios_jit_rw_base_global;
            size_t ps = ios_jit_pool_size_global;
            uintptr_t pool_end = 0;

            if (ps && rx && a + size > rx && a < rx + ps) pool_end = rx + ps;
            else if (ps && rw && a + size > rw && a < rw + ps) pool_end = rw + ps;
            if (pool_end)
            {
                static int skipped;
                if (skipped++ < 8)
                    dprintf( 2, "[pool-va] SKIP scan over JIT pool at %p -> %p\n",
                             start, (void *)pool_end );
                if (step < 0)
                {
                    uintptr_t pool_base = (pool_end == rx + ps) ? rx : rw;
                    if (pool_base < size) break;
                    start = ROUND_ADDR( (char *)(pool_base - size), (size_t)(-step) - 1 );
                }
                else start = (void *)((pool_end + (size_t)step - 1) & ~((uintptr_t)step - 1));
                continue;
            }
        }
        if (anon_mmap_tryfixed( start, size, unix_prot, 0 ) != MAP_FAILED) return start;
        TRACE( "Found free area is already mapped, start %p.\n", start );
        ios_va_scan_tries++;
        if (!ios_scan_fail_addr) { ios_scan_fail_addr = start; ios_scan_fail_errno = errno; }
#ifdef WINE_IOS
        /* iOS: mach_vm_map can return KERN_INVALID_ADDRESS (→ ENOMEM) at certain
         * addresses due to ASLR/system mappings.  Keep scanning instead of aborting. */
        if (errno != EEXIST && errno != ENOMEM)
#else
        if (errno != EEXIST)
#endif
        {
            ERR( "mmap() error %s, range %p-%p, unix_prot %#x.\n",
                 strerror(errno), start, (char *)start + size, unix_prot );
            return NULL;
        }
        if ((step > 0 && (char *)end - (char *)start < step) ||
            (step < 0 && (char *)start - (char *)base < -step) ||
            step == 0)
            break;
        /* ml211: jump over the whole occupying region instead of crawling one granule
         * at a time -- see ios_skip_occupied. Bounds are re-checked by the loop
         * condition, so an over-long jump simply ends the scan rather than escaping
         * the range. */
        {
            void *next = start;

            if (step && ios_skip_occupied( start, size, (size_t)(step < 0 ? -step : step) - 1,
                                           step < 0, &next )
                && next != start)
            {
                ios_va_scan_skips++;
                start = next;
            }
            else
                start = (char *)start + step;
        }
    }

    return NULL;
}


/***********************************************************************
 *           map_free_area
 *
 * Find a free area between views inside the specified range and map it.
 * virtual_mutex must be held by caller.
 */
static void *map_free_area( void *base, void *end, size_t size, int top_down, int unix_prot, size_t align_mask )
{
    struct wine_rb_entry *first = find_view_inside_range( &base, &end, top_down );
    ptrdiff_t step = top_down ? -(align_mask + 1) : (align_mask + 1);
    void *start;

    /* ml749: AN INVERTED WINDOW IS NOT AN EMPTY SEARCH, IT IS A CONFIGURATION
     * BUG -- SAY SO.
     *
     * When a caller's window starts above its end -- which is what happens to
     * both FEX arena candidates once the host limit is believed to be 32GB,
     * [496GB,32GB) and [48GB,32GB) -- every loop below is skipped, the scan
     * reports tries=0 skips=0, and NULL comes back indistinguishable from
     * "searched hard, genuinely full". The caller then proceeds without an
     * arena and the real failure surfaces hundreds of instructions later as a
     * NULL x28 dereference at x28+0x7f0, in a different subsystem, with none of
     * this context attached. Name it at the point of truth instead. */
    if (base >= end)
        dprintf( 2, "[va-scan] ml749 INVERTED WINDOW base=%p >= end=%p size=%p "
                    "-- nothing will be scanned; caller will see 'no space' that is really 'no window'\n",
                 base, end, (void *)size );

    /* [va-scan] geometry probe — see ios_scan_base. */
    ios_scan_base = base;
    ios_scan_end = end;
    ios_scan_views = 0;
    ios_scan_maxgap = 0;
    ios_scan_stop = first ? 0 : 9;
    ios_scan_fail_addr = NULL;
    ios_scan_fail_errno = 0;

    if (top_down)
    {
        start = ROUND_ADDR( (char *)end - size, align_mask );
        if (start >= end || start < base) { ios_scan_stop = 3; return NULL; }

        while (first)
        {
            struct file_view *view = WINE_RB_ENTRY_VALUE( first, struct file_view, entry );
            char *gap_lo = (char *)view->base + view->size;

            ios_scan_views++;
            if ((char *)start + size > gap_lo && (size_t)((char *)start + size - gap_lo) > ios_scan_maxgap)
                ios_scan_maxgap = (char *)start + size - gap_lo;
            if ((start = try_map_free_area( gap_lo, (char *)start + size, step,
                                            start, size, unix_prot ))) break;
            start = ROUND_ADDR( (char *)view->base - size, align_mask );
            /* stop if remaining space is not large enough */
            if (!start || start >= end || start < base) { ios_scan_stop = 4; return NULL; }
            first = rb_prev( first );
        }
    }
    else
    {
        start = ROUND_ADDR( (char *)base + align_mask, align_mask );
        if (!start || start >= end || (char *)end - (char *)start < size) { ios_scan_stop = 1; return NULL; }

        while (first)
        {
            struct file_view *view = WINE_RB_ENTRY_VALUE( first, struct file_view, entry );

            ios_scan_views++;
            if ((char *)view->base > (char *)start && (size_t)((char *)view->base - (char *)start) > ios_scan_maxgap)
                ios_scan_maxgap = (char *)view->base - (char *)start;
            if ((start = try_map_free_area( start, view->base, step,
                                            start, size, unix_prot ))) break;
            start = ROUND_ADDR( (char *)view->base + view->size + align_mask, align_mask );
            /* stop if remaining space is not large enough */
            if (!start || start >= end || (char *)end - (char *)start < size) { ios_scan_stop = 2; return NULL; }
            first = rb_next( first );
        }
    }

    if (!first)
        start = try_map_free_area( base, end, step, start, size, unix_prot );

    if (!start)
        ERR( "couldn't map free area in range %p-%p, size %p\n", base, end, (void *)size );

    return start;
}


/***********************************************************************
 *           find_reserved_free_area
 *
 * Find a free area between views inside the specified range.
 * virtual_mutex must be held by caller.
 * The range must be inside a reserved area.
 */
static void *find_reserved_free_area( void *base, void *end, size_t size, int top_down, size_t align_mask )
{
    struct range_entry *range;
    void *start;

    base = ROUND_ADDR( (char *)base + align_mask, align_mask );
    end = (char *)ROUND_ADDR( (char *)end - size, align_mask ) + size;

    if (top_down)
    {
        start = (char *)end - size;
        range = free_ranges_lower_bound( start );
        assert(range != free_ranges_end && range->end >= start);

        if ((char *)range->end - (char *)start < size) start = ROUND_ADDR( (char *)range->end - size, align_mask );
        do
        {
            if (start >= end || start < base || (char *)end - (char *)start < size) return NULL;
            if (start < range->end && start >= range->base && (char *)range->end - (char *)start >= size) break;
            if (--range < free_ranges) return NULL;
            start = ROUND_ADDR( (char *)range->end - size, align_mask );
        }
        while (1);
    }
    else
    {
        start = base;
        range = free_ranges_lower_bound( start );
        assert(range != free_ranges_end && range->end >= start);

        if (start < range->base) start = ROUND_ADDR( (char *)range->base + align_mask, align_mask );
        do
        {
            if (start >= end || start < base || (char *)end - (char *)start < size) return NULL;
            if (start < range->end && start >= range->base && (char *)range->end - (char *)start >= size) break;
            if (++range == free_ranges_end) return NULL;
            start = ROUND_ADDR( (char *)range->base + align_mask, align_mask );
        }
        while (1);
    }
    return start;
}


/***********************************************************************
 *           remove_reserved_area
 *
 * Remove a reserved area from the list maintained by libwine.
 * virtual_mutex must be held by caller.
 */
static void remove_reserved_area( void *addr, size_t size )
{
    struct file_view *view;
    size_t view_size;

    TRACE( "removing %p-%p\n", addr, (char *)addr + size );
    mmap_remove_reserved_area( addr, size );

    /* unmap areas not covered by an existing view */
    WINE_RB_FOR_EACH_ENTRY( view, &views_tree, struct file_view, entry )
    {
        if ((char *)view->base >= (char *)addr + size) break;
        if ((char *)view->base + view->size <= (char *)addr) continue;
        if (view->base > addr)
        {
            ios_jit_range_tripwire( "remove_reserved_area", addr,
                                    (char *)view->base - (char *)addr, -1,
                                    __builtin_return_address(0) );
            ios_pool_va_warn( "munmap", addr, (char *)view->base - (char *)addr );
            munmap( addr, (char *)view->base - (char *)addr );
        }
        if ((char *)view->base + view->size > (char *)addr + size) return;
        view_size = ROUND_SIZE( view->base, view->size, host_page_mask );
        size = (char *)addr + size - ((char *)view->base + view_size);
        addr = (char *)view->base + view_size;
    }
    ios_jit_range_tripwire( "remove_reserved_area", addr, size, -1, __builtin_return_address(0) );
    ios_pool_va_warn( "munmap", addr, size );
    munmap( addr, size );
}


/***********************************************************************
 *           unmap_area
 *
 * Unmap an area, or simply replace it by an empty mapping if it is
 * in a reserved area. virtual_mutex must be held by caller.
 */
static void unmap_area( void *start, size_t size )
{
    struct reserved_area *area;
    void *end;

    assert( !((UINT_PTR)start & host_page_mask) );
    size = ROUND_SIZE( 0, size, host_page_mask );

    ios_jit_range_tripwire( "unmap_area", start, size, -1, __builtin_return_address(0) );

    if (!(size = unmap_area_above_user_limit( start, size ))) return;

    end = (char *)start + size;

    LIST_FOR_EACH_ENTRY( area, &reserved_areas, struct reserved_area, entry )
    {
        void *area_start = area->base;
        void *area_end = (char *)area_start + area->size;

        if (area_start >= end) break;
        if (area_end <= start) continue;
        if (area_start > start)
        {
            ios_pool_va_warn( "munmap", start, (char *)area_start - (char *)start );
            munmap( start, (char *)area_start - (char *)start );
            start = area_start;
        }
        if (area_end >= end)
        {
            anon_mmap_fixed( start, (char *)end - (char *)start, PROT_NONE, MAP_NORESERVE );
            return;
        }
        anon_mmap_fixed( start, (char *)area_end - (char *)start, PROT_NONE, MAP_NORESERVE );
        start = area_end;
    }
    ios_pool_va_warn( "munmap", start, (char *)end - (char *)start );
    munmap( start, (char *)end - (char *)start );
}


/***********************************************************************
 *           alloc_view
 *
 * Allocate a new view. virtual_mutex must be held by caller.
 */
static struct file_view *alloc_view(void)
{
    if (next_free_view)
    {
        struct file_view *ret = next_free_view;
        next_free_view = *(struct file_view **)ret;
        return ret;
    }
    if (view_block_start == view_block_end)
    {
        void *ptr = anon_mmap_alloc( view_block_size, PROT_READ | PROT_WRITE );
        if (ptr == MAP_FAILED) return NULL;
        view_block_start = ptr;
        view_block_end = view_block_start + view_block_size / sizeof(*view_block_start);
    }
    return view_block_start++;
}


/***********************************************************************
 *           free_view
 *
 * Free memory for view structure. virtual_mutex must be held by caller.
 */
static void free_view( struct file_view *view )
{
    *(struct file_view **)view = next_free_view;
    next_free_view = view;
}


/***********************************************************************
 *           unregister_view
 *
 * Remove view from the tree and update free ranges. virtual_mutex must be held by caller.
 */
static void unregister_view( struct file_view *view )
{
    if (mmap_is_in_reserved_area( view->base, view->size ))
        free_ranges_remove_view( view );
    wine_rb_remove( &views_tree, &view->entry );
}


/***********************************************************************
 *           delete_view
 *
 * Deletes a view. virtual_mutex must be held by caller.
 */
static void delete_view( struct file_view *view ) /* [in] View */
{
    if (!(view->protect & VPROT_SYSTEM)) unmap_area( view->base, view->size );
    set_page_vprot( view->base, view->size, 0 );
    if (view->protect & VPROT_ARM64EC) clear_arm64ec_range( view->base, view->size );
    unregister_view( view );
    free_view( view );
}


/***********************************************************************
 *           register_view
 *
 * Add view to the tree and update free ranges. virtual_mutex must be held by caller.
 */
static void register_view( struct file_view *view )
{
    wine_rb_put( &views_tree, view->base, &view->entry );
    if (mmap_is_in_reserved_area( view->base, view->size ))
        free_ranges_insert_view( view );
}


/***********************************************************************
 *           create_view
 *
 * Create a view. virtual_mutex must be held by caller.
 */
static NTSTATUS create_view( struct file_view **view_ret, void *base, size_t size, unsigned int vprot )
{
    struct file_view *view;

    assert( !((UINT_PTR)base & host_page_mask) );
    assert( !(size & page_mask) );

    /* Check for overlapping views. This can happen if the previous view
     * was a system view that got unmapped behind our back. In that case
     * we recover by simply deleting it. */

    while ((view = find_view_range( base, size )))
    {
        TRACE( "overlapping view %p-%p for %p-%p\n",
               view->base, (char *)view->base + view->size, base, (char *)base + size );
        assert( view->protect & VPROT_SYSTEM );
        delete_view( view );
    }

    if (!alloc_pages_vprot( base, size )) return STATUS_NO_MEMORY;

    /* Create the view structure */

    if (!(view = alloc_view()))
    {
        FIXME( "out of memory for %p-%p\n", base, (char *)base + size );
        return STATUS_NO_MEMORY;
    }

    view->base    = base;
    view->size    = size;
    view->protect = vprot;
    if (use_kernel_writewatch) vprot &= ~VPROT_WRITEWATCH;
    set_page_vprot( base, size, vprot );

    register_view( view );
    kernel_writewatch_register_range( view, view->base, view->size );

    *view_ret = view;
    return STATUS_SUCCESS;
}


/***********************************************************************
 *           get_win32_prot
 *
 * Convert page protections to Win32 flags.
 */
static DWORD get_win32_prot( BYTE vprot, unsigned int map_prot )
{
    DWORD ret = VIRTUAL_Win32Flags[vprot & 0x0f];
    if (vprot & VPROT_GUARD) ret |= PAGE_GUARD;
    if (map_prot & SEC_NOCACHE) ret |= PAGE_NOCACHE;
    return ret;
}


/***********************************************************************
 *           get_vprot_flags
 *
 * Build page protections from Win32 flags.
 */
static NTSTATUS get_vprot_flags( DWORD protect, unsigned int *vprot, BOOL image )
{
    switch(protect & 0xff)
    {
    case PAGE_READONLY:
        *vprot = VPROT_READ;
        break;
    case PAGE_READWRITE:
        if (image)
            *vprot = VPROT_READ | VPROT_WRITECOPY;
        else
            *vprot = VPROT_READ | VPROT_WRITE;
        break;
    case PAGE_WRITECOPY:
        *vprot = VPROT_READ | VPROT_WRITECOPY;
        break;
    case PAGE_EXECUTE:
        *vprot = VPROT_EXEC;
        break;
    case PAGE_EXECUTE_READ:
        *vprot = VPROT_EXEC | VPROT_READ;
        break;
    case PAGE_EXECUTE_READWRITE:
        if (image)
            *vprot = VPROT_EXEC | VPROT_READ | VPROT_WRITECOPY;
        else
            *vprot = VPROT_EXEC | VPROT_READ | VPROT_WRITE;
        break;
    case PAGE_EXECUTE_WRITECOPY:
        *vprot = VPROT_EXEC | VPROT_READ | VPROT_WRITECOPY;
        break;
    case PAGE_NOACCESS:
        *vprot = 0;
        break;
    default:
        return STATUS_INVALID_PAGE_PROTECTION;
    }
    if (protect & PAGE_GUARD) *vprot |= VPROT_GUARD;
    return STATUS_SUCCESS;
}


/* task #34 [jit-name]: read a mapped PE's own name from its export directory
 * (Name field), so the pool-copy log lines name the DLL instead of a bare
 * base address — needed to identify which module a pseudo-proc wrongly
 * executes across a self-relaunch. Bounds-checked against image_size; returns
 * "?" on any malformed/absent header. `image_base` must be the READABLE
 * mapped PE (RVA==offset). Not thread-safe on the returned pointer's contents,
 * but names live in the image's read-only .rdata so they're stable. */
const char *ios_pe_module_name( const void *image_base, size_t image_size )
{
    const unsigned char *b = image_base;
    uint32_t lfanew, exp_rva, name_rva;
    const unsigned char *pe;

    if (!b || image_size < 0x100) return "?";
    if (b[0] != 'M' || b[1] != 'Z') return "?";
    lfanew = *(const uint32_t *)(b + 0x3c);
    if ((size_t)lfanew + 0x90 > image_size) return "?";
    pe = b + lfanew;
    if (pe[0] != 'P' || pe[1] != 'E') return "?";
    if (*(const uint16_t *)(pe + 0x18) != 0x20b) return "?";   /* PE32+ only */
    exp_rva = *(const uint32_t *)(pe + 0x88);                  /* DataDir[0] Export VA */
    if (!exp_rva || (size_t)exp_rva + 0x10 > image_size) return "?";
    name_rva = *(const uint32_t *)(b + exp_rva + 0x0c);        /* IMAGE_EXPORT_DIRECTORY.Name */
    if (!name_rva || (size_t)name_rva + 1 > image_size) return "?";
    /* Ensure NUL within the image so the %s can't run off the mapping. */
    {
        size_t i, cap = image_size - name_rva;
        if (cap > 64) cap = 64;
        for (i = 0; i < cap; i++) if (b[name_rva + i] == 0) return (const char *)(b + name_rva);
        return "?";
    }
}


/* task #34 .text sharing: pre-scan a SOURCE PE (before the pool memcpy) for
 * the x18 trampoline budget, so the trampoline region can be folded into the
 * image's own pool allocation at a FIXED image-relative offset. Fixed-offset
 * tramps make the patched .text and the trampolines byte-identical across
 * pool copies of the same DLL (both branch directions are PC-relative), which
 * is the precondition for page-sharing copies. Returns the page-aligned tramp
 * bytes to reserve, or 0 when the x18 patcher will skip this image (pure
 * x86_64: Machine!=ARM64 and no .a64xrm section — mirrors the skip logic in
 * the patch stage; scanning x64 bytes would count garbage matches). */
static size_t ios_x18_tramp_prealloc_scan( const char *image, size_t image_size )
{
    extern size_t ios_jit_x18_tramp_need( const char *text, size_t text_size );
    const size_t pg = 0x4000;
    unsigned int pe_off;
    unsigned short machine, num_sec, opt_sz;
    const char *sec;
    size_t text_off = 0, text_sz = 0;
    int s, is_arm64ec = 0;

    if (!image || image_size < 0x400) return 0;
    if (image[0] != 'M' || image[1] != 'Z') return 0;
    pe_off = *(const unsigned int *)(image + 0x3C);
    if ((size_t)pe_off + 0x18 > image_size) return 0;
    machine = *(const unsigned short *)(image + pe_off + 4);
    num_sec = *(const unsigned short *)(image + pe_off + 6);
    opt_sz  = *(const unsigned short *)(image + pe_off + 0x14);
    sec = image + pe_off + 0x18 + opt_sz;
    if ((size_t)(sec - image) + (size_t)num_sec * 40 > image_size) return 0;
    for (s = 0; s < num_sec; s++, sec += 40)
    {
        unsigned int chars = *(const unsigned int *)(sec + 36);
        unsigned int rva   = *(const unsigned int *)(sec + 12);
        unsigned int vsz   = *(const unsigned int *)(sec + 8);
        if (!memcmp(sec, ".a64xrm", 7)) is_arm64ec = 1;
        /* Largest exec section = the .text the patcher walks (same rule as
         * ios_jit_set_text_section). */
        if ((chars & 0x20000000) && vsz > text_sz) { text_off = rva; text_sz = vsz; }
    }
    if (machine != IMAGE_FILE_MACHINE_ARM64 && !is_arm64ec) return 0;
    if (!text_sz || text_off + text_sz > image_size) return 0;
    return (ios_jit_x18_tramp_need(image + text_off, text_sz) + pg - 1) & ~(pg - 1);
}


/* [share-probe] logging: the LogStore periodically REWRITES madeira-log.txt
 * from its own buffer, destroying interleaved raw-stderr lines (ml85: the
 * probe's whole verdict vanished between pulls). Tee every probe line into
 * Documents/share-probe.txt (O_APPEND, own fd) so no rewrite can eat it. */
static void ios_probe_filelog(int fd_unused, const char *fmt, ...)
{
    va_list ap;
    char buf[512];
    int n;
    va_start(ap, fmt);
    n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    if (n > (int)sizeof(buf) - 1) n = (int)sizeof(buf) - 1;
    write(2, buf, n);
    {
        static int pf = -2;
        if (pf == -2)
        {
            const char *wp = getenv("WINEPREFIX");
            pf = -1;
            if (wp && strlen(wp) < 440)
            {
                char path[512];
                snprintf(path, sizeof(path), "%s/../share-probe.txt", wp);
                pf = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
            }
        }
        if (pf >= 0) write(pf, buf, n);
    }
}
#define dprintf ios_probe_filelog

/* Watchdog exec: run the 2-insn probe function on a disposable thread with a
 * timeout, so an instruction-fetch wedge (ml79/ml85 signature) becomes a
 * logged verdict instead of a lost thread holding the whole probe hostage.
 * Returns the function's result, or INT_MIN on timeout. */
static volatile int ios_probe_exec_done;
static volatile int ios_probe_exec_ret;
static void *ios_probe_exec_helper(void *p)
{
    typedef int (*probe_fn)(void);
    int v = ((probe_fn)p)();
    ios_probe_exec_ret = v;
    __sync_synchronize();
    ios_probe_exec_done = 1;
    return NULL;
}
static int ios_probe_exec_timed(void *fn, int deciseconds)
{
    pthread_t t;
    int i;
    ios_probe_exec_done = 0;
    if (pthread_create(&t, NULL, ios_probe_exec_helper, fn)) return INT_MIN;
    pthread_detach(t);
    for (i = 0; i < deciseconds; i++)
    {
        if (ios_probe_exec_done) return ios_probe_exec_ret;
        usleep(100000);
    }
    return INT_MIN;
}

/* task #34 [share-probe] — one-shot go/no-go for one-RX-copy-per-DLL page
 * sharing: does the StikDebug execute blessing survive vm_remap(copy=FALSE)
 * of a blessed pool RX page to a SECOND in-pool VA, and does the dual-map
 * stay coherent through the share? Log-only; leaks 2×16KB pool slots (kept
 * mapped so the remapped pages are never recycled under someone else). */
static void ios_share_probe(void)
{
    extern void *ios_jit_rw_base_global;
    extern void *ios_jit_rx_base_global;
    extern size_t ios_jit_pool_size_global;
    typedef int (*probe_fn)(void);
    const size_t pg = 0x4000;
    size_t off1, off2;
    char *rx1, *rw1, *rx2, *rw2;
    vm_prot_t cur = 0, max = 0;
    kern_return_t kr;
    int r;

    if (!ios_jit_rx_base_global || !ios_jit_rw_base_global) return;
    dprintf(2, "[share-probe] start (rx_base=%p rw_base=%p)\n",
            ios_jit_rx_base_global, ios_jit_rw_base_global);
    off1 = ios_pool_alloc_range(pg, ios_jit_pool_size_global - ios_jit_tail_reserved);
    off2 = ios_pool_alloc_range(pg, ios_jit_pool_size_global - ios_jit_tail_reserved);
    if (off1 == (size_t)-1 || off2 == (size_t)-1)
    {
        dprintf(2, "[share-probe] pool alloc failed — probe skipped\n");
        return;
    }
    rx1 = (char *)ios_jit_rx_base_global + off1;
    rw1 = (char *)ios_jit_rw_base_global + off1;
    rx2 = (char *)ios_jit_rx_base_global + off2;
    rw2 = (char *)ios_jit_rw_base_global + off2;
    dprintf(2, "[share-probe] slots off1=0x%lx off2=0x%lx — writing code via master RW\n",
            (unsigned long)off1, (unsigned long)off2);

    ((uint32_t *)rw1)[0] = 0x52800540;  /* mov w0, #42 */
    ((uint32_t *)rw1)[1] = 0xD65F03C0;  /* ret */
    __asm__ __volatile__("dsb sy" ::: "memory");
    sys_icache_invalidate(rx1, pg);
    /* Read back through the RX alias BEFORE executing — a mismatch means
     * the dual-map is broken for this placement and executing would run
     * garbage (ml78: silent hang was the first pool execution at a toxic
     * pool base; never execute blind). */
    if (*(volatile uint32_t *)rx1 != 0x52800540)
    {
        dprintf(2, "[share-probe] ABORT: RX readback 0x%08x != written code (dual-map broken here)\n",
                *(volatile uint32_t *)rx1);
        return;
    }
    dprintf(2, "[share-probe] readback OK — executing at master %p\n", rx1);
    r = ((probe_fn)rx1)();
    dprintf(2, "[share-probe] exec at master %p -> %d (expect 42)\n", rx1, r);

    /* [purge-probe] THE ml76-wall suspect: is the debugger-allocated pool
     * PURGEABLE memory? (Allocator comment: virgin pool pages read back zero
     * under pressure — anon memory doesn't do that unless volatile/purgeable.)
     * GET_STATE per view; if any view reports purgeable+volatile, SET
     * NONVOLATILE and re-query — that one call would be the whole reclaim fix
     * (no vm_wire, no jetsam cost). KERN_INVALID_ARGUMENT = not purgeable. */
    {
        struct { const char *name; vm_address_t a; } views[3];
        int v;
        views[0].name = "pool-rx-base"; views[0].a = (vm_address_t)ios_jit_rx_base_global;
        views[1].name = "pool-rw-base"; views[1].a = (vm_address_t)ios_jit_rw_base_global;
        views[2].name = "master-slot ";  views[2].a = (vm_address_t)rx1;
        for (v = 0; v < 3; v++)
        {
            int state = -1;
            kern_return_t pk = vm_purgable_control(mach_task_self(), views[v].a,
                                                   VM_PURGABLE_GET_STATE, &state);
            dprintf(2, "[purge-probe] %s %p GET_STATE kr=%d state=%d%s\n",
                    views[v].name, (void *)views[v].a, pk, state,
                    pk == KERN_SUCCESS
                        ? (state == VM_PURGABLE_VOLATILE ? " (PURGEABLE+VOLATILE — the wall!)" :
                           state == VM_PURGABLE_NONVOLATILE ? " (purgeable, nonvolatile)" :
                           state == VM_PURGABLE_EMPTY ? " (purgeable, EMPTY)" : "")
                        : " (not purgeable)");
            if (pk == KERN_SUCCESS && state != VM_PURGABLE_NONVOLATILE)
            {
                int ns = VM_PURGABLE_NONVOLATILE;
                kern_return_t sk = vm_purgable_control(mach_task_self(), views[v].a,
                                                       VM_PURGABLE_SET_STATE, &ns);
                dprintf(2, "[purge-probe] %s SET NONVOLATILE kr=%d (old=%d)\n",
                        views[v].name, sk, ns);
            }
        }
    }

    /* CONTROL (ml85 confound): variant E execs on a fresh watchdog pthread.
     * If a bare pthread can't run blessed pool code AT ALL (no FEX/TEB/signal
     * setup), E's wedge is a thread artifact, not a remap verdict. Run the
     * MASTER page through the same watchdog path first. master-via-watchdog
     * == 42 → thread is fine, any E wedge is the remap. WEDGE here → the
     * whole E result is invalid (thread, not remap). */
    {
        int rc = ios_probe_exec_timed(rx1, 50);
        dprintf(2, "[share-probe] CONTROL master-via-watchdog -> %s\n",
                rc == INT_MIN ? "WEDGED (bare pthread can't exec pool code — E verdict would be INVALID)"
                              : (rc == 42 ? "42 OK (watchdog thread is fine — E wedge = the remap)"
                                          : "WRONG"));
    }

    /* Verdicts so far (ml77/79/85): OVERWRITE into pool RX kr=2; hole
     * dealloc kr=0 but refill remap kr=3; remap ANYWHERE gets kernel R+X but
     * EXEC WEDGES the thread — attached AND detached. Lore (stikdebug-jit):
     * self-created exec mappings don't work; only the debugger-allocated
     * range executes. Yet the PRODUCTION anon-RWX path executes pool pages
     * remapped OVERWRITE onto wine's pre-existing anon mmap regions daily.
     * Variant E = exact replica of that shape: mmap anon RW, OVERWRITE-remap
     * master page onto it, vm_protect RX, exec — on a WATCHDOG thread so a
     * wedge is a logged verdict, not a lost one. */
    {
        void *tgt = mmap(NULL, pg, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANON, -1, 0);
        vm_address_t target;
        if (tgt == MAP_FAILED)
        {
            dprintf(2, "[share-probe] E: mmap anon target failed errno=%d\n", errno);
            return;
        }
        dprintf(2, "[share-probe] E: anon RW target %p — OVERWRITE-remap from master %p\n", tgt, rx1);
        target = (vm_address_t)tgt;
        kr = vm_remap(mach_task_self(), &target, pg, 0,
                      VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                      (vm_address_t)rx1, FALSE, &cur, &max, VM_INHERIT_DEFAULT);
        dprintf(2, "[share-probe] E: vm_remap kr=%d cur=0x%x max=0x%x\n", kr, cur, max);
        if (kr != KERN_SUCCESS) { dprintf(2, "[share-probe] VERDICT: NO-GO (E remap failed)\n"); return; }
        kr = vm_protect(mach_task_self(), target, pg, FALSE,
                        VM_PROT_READ | VM_PROT_EXECUTE);
        dprintf(2, "[share-probe] E: vm_protect(R+X) kr=%d\n", kr);
        {
            mach_vm_address_t qa = (mach_vm_address_t)target;
            mach_vm_size_t qs = 0;
            vm_region_basic_info_data_64_t qi = {0};
            mach_msg_type_number_t qc = VM_REGION_BASIC_INFO_COUNT_64;
            mach_port_t qo = MACH_PORT_NULL;
            if (mach_vm_region(mach_task_self(), &qa, &qs, VM_REGION_BASIC_INFO_64,
                               (vm_region_info_t)&qi, &qc, &qo) == KERN_SUCCESS)
                dprintf(2, "[share-probe] E: region prot=0x%x max_prot=0x%x\n",
                        qi.protection, qi.max_protection);
        }
        sys_icache_invalidate(tgt, pg);
        if (*(volatile uint32_t *)tgt != *(volatile uint32_t *)rx1)
        {
            dprintf(2, "[share-probe] E: read mismatch tgt=0x%08x master=0x%08x\n",
                    *(volatile uint32_t *)tgt, *(volatile uint32_t *)rx1);
        }
        dprintf(2, "[share-probe] E: executing at %p (watchdog 5s)\n", tgt);
        r = ios_probe_exec_timed(tgt, 50);
        if (r == INT_MIN)
        {
            dprintf(2, "[share-probe] E: WEDGED (no return in 5s) — VERDICT: NO-GO (anon-replica exec dead too)\n");
            return;
        }
        dprintf(2, "[share-probe] E: exec -> %d (expect 42)%s\n", r, r == 42 ? " OK" : " WRONG");
        if (r != 42) { dprintf(2, "[share-probe] VERDICT: NO-GO (E wrong bytes)\n"); return; }

        /* Dual-map through the share: rewrite via the MASTER's RW view and
         * re-execute at the E alias — one physical page must serve master-RW
         * writes and alias-RX fetches. */
        ((uint32_t *)rw1)[0] = 0x52800560;  /* mov w0, #43 */
        __asm__ __volatile__("dsb sy" ::: "memory");
        sys_icache_invalidate(tgt, pg);
        r = ios_probe_exec_timed(tgt, 50);
        dprintf(2, "[share-probe] E: rewrite-via-master exec -> %d (expect 43) — VERDICT: %s\n",
                r, r == 43 ? "GO (anon-replica sharing works)" : "NO-GO (dual-map incoherent)");
    }
    (void)rx2; (void)rw2;
}


/* task #34 [share-probe] post-detach runner: the ml79 wedge happened with
 * StikDebug still ATTACHED (exec faults route to the debugger and hang), so
 * the exec-at-alias verdict was inconclusive. Wait for the app's REAL
 * jit26_detach on a scratch thread — worst case is a stuck background
 * thread, never a wedged boot. (ml81 lesson: CS_DEBUGGED is STICKY after
 * detach — that's why blessed JIT keeps working — so csops can't signal
 * detach; StikJITHelper.detachDebugger sets MADEIRA_DETACHED instead.
 * Desktop sessions detach on session exit or the 20-min maxWait cap.) */
static void *ios_share_probe_thread(void *arg)
{
    int i;
    for (i = 0; i < 900; i++)  /* ≤30min at 2s — covers the 20-min cap */
    {
        if (getenv("MADEIRA_DETACHED"))
        {
            dprintf(2, "[share-probe] debugger DETACHED (poll %d) — running post-detach probe\n", i);
            ios_share_probe();
            return NULL;
        }
        usleep(2000000);
    }
    dprintf(2, "[share-probe] no detach within 30min — probe skipped\n");
    return NULL;
}
#undef dprintf

/***********************************************************************
 *           mprotect_exec
 *
 * Wrapper for mprotect, adds PROT_EXEC if forced by force_exec_prot
 */
/* ml374: non-zero while the MACH EXCEPTION-SERVER thread is running wine's
 * page/SEH machinery on behalf of a faulting thread.
 *
 * That thread is a bare pthread with NO wine TEB, and every wine log macro
 * (ERR/WARN/TRACE/FIXME) ends in __wine_dbg_output, which reads thread-local
 * state and faults. It has now killed two runs from two different sites —
 * ml370 (__wine_dbg_header+0x100, my WARN in the cross-thread fault handler)
 * and ml374 (__wine_dbg_output+0x18, mprotect_exec's unconditional ERR reached
 * via mprotect_range). Both looked like guest crashes at a host pc with no log
 * lines, because the thread that logs is the thread that died.
 *
 * RULE: any code reachable from ios_mach_deliver_guest_exception must use
 * dprintf(2,...), never a wine log macro. This flag lets shared helpers that
 * legitimately log on normal threads stay silent on that one. */
volatile int ios_in_mach_exc;

static inline int mprotect_exec( void *base, size_t size, int unix_prot )
{
    /* ml247: catch WHO narrows maxprot on pool pages.
     *
     * Poison is created during a module's life (POISONED AT FREE, and predating
     * clear_arm64ec_range). The freelist guard now refuses poisoned ranges, but that
     * ORPHANS them -- 62 drops = 164MB from an 896MB pool now at 92% used, and FEX has
     * started failing allocations (NULL IREmitter -> str xzr,[x0,#0x378] with x0=0;
     * reclaim-recover ENOMEM). Recovering that VA means stopping the poison at source.
     *
     * mprotect_exec is the one hook every protection change funnels through. Its existing
     * ERR() output is swallowed by MADEIRA_QUIET, so log via dprintf, and only for pool
     * addresses so this cannot flood. */
    {
        extern void *ios_jit_rx_base_global;
        extern void *ios_jit_rw_base_global;
        extern size_t ios_jit_pool_size_global;
        uintptr_t b = (uintptr_t)base;
        uintptr_t rx = (uintptr_t)ios_jit_rx_base_global;
        uintptr_t rw = (uintptr_t)ios_jit_rw_base_global;
        size_t ps = ios_jit_pool_size_global;
        static int prot_n;

        if (ps && prot_n < 40 &&
            ((rx && b >= rx && b < rx + ps) || (rw && b >= rw && b < rw + ps)))
        {
            prot_n++;
            dprintf( 2, "[pool-prot] mprotect_exec base=%p size=0x%lx prot=%c%c%c alias=%s off=0x%lx\n",
                     base, (unsigned long)size,
                     (unix_prot & PROT_READ)  ? 'r' : '-',
                     (unix_prot & PROT_WRITE) ? 'w' : '-',
                     (unix_prot & PROT_EXEC)  ? 'x' : '-',
                     (rx && b >= rx && b < rx + ps) ? "RX" : "RW",
                     (unsigned long)((rx && b >= rx && b < rx + ps) ? b - rx : b - rw) );
        }
    }
    if (force_exec_prot && (unix_prot & PROT_READ) && !(unix_prot & PROT_EXEC))
    {
        if (!ios_in_mach_exc)                   /* ml374: see ios_in_mach_exc */
            TRACE( "forcing exec permission on %p-%p\n", base, (char *)base + size - 1 );
        if (!mprotect( base, size, unix_prot | PROT_EXEC )) return 0;
        /* exec + write may legitimately fail, in that case fall back to write only */
        if (!(unix_prot & PROT_WRITE)) return -1;
    }

#ifdef WINE_IOS
    /* iOS-specific: when asked to make pages writable on a file-backed
     * mapping (e.g. the IAT in xtajit64's .rdata), POSIX mprotect succeeds
     * but the kernel silently keeps pages read-only (writes silently
     * no-op). The Mach vm_protect API succeeds where POSIX silently fails.
     *
     * Apply only on the PROT_WRITE-add path; non-write protect changes go
     * through the regular mprotect below. */
    if (!ios_in_mach_exc)                       /* ml374: see ios_in_mach_exc */
        ERR("mprotect_exec(%p, 0x%lx, %c%c%c)\n", base, (unsigned long)size,
            (unix_prot & PROT_READ)  ? 'r' : '-',
            (unix_prot & PROT_WRITE) ? 'w' : '-',
            (unix_prot & PROT_EXEC)  ? 'x' : '-');
    if ((unix_prot & PROT_WRITE) && !(unix_prot & PROT_EXEC))
    {
        /* ml391 (task #60): try WITHOUT VM_PROT_COPY first.  COPY forcibly
         * privatizes the mapping object — on a MAP_SHARED section view it
         * silently disconnects the view from the section: writes land in a
         * private copy and every other pseudo-process reads the section's
         * original zeros ([sec-test] ZEROS; killed the SteamChrome
         * webhelper-init handshake and every CSharedMemStream).  When maxprot
         * permits WRITE (anon memory, temp-file-backed shared sections, the
         * JIT pool's vm_remap alias) the plain request succeeds and sharing
         * is preserved; it also re-asserts write past the iOS silent
         * mmap-downgrade.  Only when maxprot lacks WRITE (code-signed PE
         * files — the IAT case this path was built for) fall back to +COPY,
         * where privatizing is correct since PE data is per-process anyway. */
        kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)base, size,
                                      FALSE,  /* set_maximum */
                                      VM_PROT_READ | VM_PROT_WRITE);
        if (kr == KERN_SUCCESS) return 0;
        kr = vm_protect(mach_task_self(), (vm_address_t)base, size,
                        FALSE,  /* set_maximum */
                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr == KERN_SUCCESS) {
            if (!ios_in_mach_exc)
                ERR("iOS vm_protect RW+COPY OK at %p+0x%lx (plain RW refused — privatized)\n",
                    base, (unsigned long)size);
            return 0;
        }
        if (!ios_in_mach_exc)
            ERR("iOS vm_protect RW failed kr=%d at %p+0x%lx — falling to mprotect\n",
                kr, base, (unsigned long)size);
    }

    if (unix_prot & PROT_EXEC)
    {
        /* iOS/TXM: mprotect(PROT_EXEC) is blocked. TXM only allows execution
         * from debugger-allocated pages at their ORIGINAL virtual addresses.
         * Remapping those pages elsewhere doesn't preserve execute permission.
         *
         * Strategy: Copy PE code sections into the pre-allocated JIT pool and
         * execute from the JIT pool's original RX addresses. Wine's entry points
         * (pLdrInitializeThunk etc.) are redirected via ios_jit_translate_addr().
         *
         * All relative branches (B/BL) within the code section are preserved
         * because the code is copied contiguously. ADRP/data references need
         * re-relocation which is handled by re-applying PE base relocations.
         */
        static void *jit_rx_base = NULL;
        static void *jit_rw_base = NULL;
        static size_t jit_pool_size = 0;
        /* jit_pool_offset promoted to file scope (S1: shared with the
         * per-child ntdll copy allocator). */
        static int jit_pool_init_done = 0;

        if (!jit_pool_init_done)
        {
            const char *rx_str = getenv("WINE_IOS_JIT_RX");
            const char *rw_str = getenv("WINE_IOS_JIT_RW");
            const char *sz_str = getenv("WINE_IOS_JIT_SIZE");
            if (rx_str && rw_str && sz_str)
            {
                jit_rx_base = (void *)strtoull(rx_str, NULL, 16);
                jit_rw_base = (void *)strtoull(rw_str, NULL, 16);
                jit_pool_size = (size_t)strtoull(sz_str, NULL, 16);
                /* Export for SIGBUS handler */
                ios_jit_rx_base_global = jit_rx_base;
                ios_jit_rw_base_global = jit_rw_base;
                ios_jit_pool_size_global = jit_pool_size;

                /* ml91 (task #35): dump the VA map ONCE here, unconditionally.
                 * The first cut only probed on jumbo-reserve failure, so a
                 * Thumper run (which never issues one) produced no map at all —
                 * exactly when we needed to know why all six sub-64G candidates
                 * for the RW alias were refused. This is the baseline picture
                 * before CEF asks for anything. */
                ios_va_gap_probe( "jit pool init" );

                /* task #34: start the pool warmer (see ios_pool_warmer_thread).
                 * Keeps every used pool page off the inactive queue so the
                 * compressor never gets to replace a blessed page's frame. */
                {
                    pthread_t warm;
                    if (!pthread_create( &warm, NULL, ios_pool_warmer_thread, NULL ))
                        pthread_detach( warm );
                }

                /* Write TEB restore trampoline at start of JIT pool.
                 * TEB value (0 for now, set later by signal code) at offset 0,
                 * executable trampoline at offset 8. */
                {
                    uint32_t *tramp = (uint32_t *)((char *)jit_rw_base + 8);
                    /* offset 0: TEB address (8 bytes, initially 0) */
                    *(uint64_t *)jit_rw_base = 0;
                    /* offset 8: ldr x18, [pc, #-16]  — encoded as 0x58FFFFD2 */
                    tramp[0] = 0x58FFFFD2;
                    /* offset 12: br x17              — encoded as 0xD61F0220 */
                    tramp[1] = 0xD61F0220;
                    sys_icache_invalidate(jit_rx_base, 16);
                    ios_jit_teb_trampoline = (char *)jit_rx_base + 8;
                    /* Page-align the offset so PE images stay page-aligned
                     * (mprotect requires page-aligned addresses). */
                    jit_pool_offset = 0x4000;  /* one 16KB iOS page */
                    ERR("iOS JIT: TEB trampoline at %p (pool+8)\n", ios_jit_teb_trampoline);
                }

                ERR("iOS JIT pool: RX=%p RW=%p size=0x%lx\n",
                    jit_rx_base, jit_rw_base, (unsigned long)jit_pool_size);
            }
            jit_pool_init_done = 1;
        }

        /* iOS-Madeira ml640: AN OWNED ANON-JIT RANGE IS SETTLED — DECIDE IT FIRST.
         *
         * ROOT CAUSE, proven by the ml639 three-view hash:
         *   guest  = 0x706F9B0000  HASH16K aa4f0ea29a4c7f5c
         *   poolRX = 0x1268C8000   HASH16K 7a9fbb551062ff6b
         *   poolRW = 0x7009EEC000  HASH16K 7a9fbb551062ff6b   (slot=71, dup_end=1)
         *   => poolRX == poolRW, the GUEST vm_remap DETACHED.
         * The pool's dual-map is perfect and every emulated write lands in it; the guest
         * VA simply stops sharing those pages, so Mono writes valid code while FEX
         * executes stale bytes and then zeros, running to alias_end and dying with a
         * deterministic c0000005 (identical across four runs: write_gen=792,
         * highest=0x33fd, RIP_off=0x10000).
         *
         * WHY: this function re-enters on every 4KB W<->X transition and, before ever
         * asking whether a JIT already owns the range, it (a) calls plain mprotect()
         * just below and (b) falls into nearest-image classification. A managed
         * assembly Mono mapped as DATA sits immediately below Mono's buffer; its PE
         * header declares SizeOfImage 0x24000 while only 0x1f000 is mapped, so the
         * backward MZ scan claims [image, image+0x24000) — overlapping the first 16KB
         * of the alias. That 16KB is exactly the chunk holding all 792 writes and the
         * divergence. The anon-alias reuse check sits ~250 lines further down, far too
         * late to prevent any of it.
         *
         * So decide ownership FIRST. If a live alias fully covers the request this is an
         * ordinary JIT W<->X transition: the guest VA is already R+X via the pool
         * dual-map, Wine has already recorded the requested LOGICAL protection in
         * set_vprot(), and writes are meant to fault into the alias store emulator.
         * Nothing further is needed — and critically, nothing may re-map or re-classify
         * this range.
         *
         * ⛔ Only ordinary R/W/X transitions take this path. PROT_NONE, decommit,
         * release and teardown must keep their normal behaviour, so they are excluded.
         * ⛔ Do NOT "shrink" any image copy to dodge the overlap: the image path does not
         * remap the guest VA at all (it copies into the pool and registers a logical
         * translation), and truncating a genuine image would break relocations. The real
         * defect is that this object was classified as a native image at all — the
         * durable fix is Wine mapping identity / actual view bounds instead of trusting a
         * nearby MZ header's SizeOfImage. */
        if (unix_prot != PROT_NONE)
        {
            extern int ios_jit_anon_alias_find_cover(void *, size_t, void **, void **);
            void *cov_rw = NULL, *cov_rx = NULL;
            if (ios_jit_anon_alias_find_cover( base, size, &cov_rw, &cov_rx ))
            {
                static int own_n;
                if (own_n < 32)
                    dprintf(2, "[alias-own] ml640 #%d %p+0x%lx prot=%c%c%c OWNED by live anon JIT alias "
                               "(rx=%p rw=%p) — keeping the pool dual-map, no mprotect, no image lookup\n",
                            ++own_n, base, (unsigned long)size,
                            (unix_prot & PROT_READ)  ? 'r' : '-',
                            (unix_prot & PROT_WRITE) ? 'w' : '-',
                            (unix_prot & PROT_EXEC)  ? 'x' : '-',
                            cov_rx, cov_rw);
                return 0;
            }
        }

        /* Try normal mprotect first (works on non-TXM devices). On iOS TXM,
         * mprotect with PROT_EXEC may *appear* to succeed (return 0) without
         * actually granting EXEC — pages stay RW only. Verify by querying the
         * actual page protection via Mach vm_region_64; only return early if
         * EXEC was truly granted. */
        if (!mprotect( base, size, unix_prot ))
        {
            mach_vm_address_t addr = (mach_vm_address_t)base;
            mach_vm_size_t reg_size = 0;
            vm_region_basic_info_data_64_t info;
            mach_msg_type_number_t info_cnt = VM_REGION_BASIC_INFO_COUNT_64;
            mach_port_t obj_name = MACH_PORT_NULL;
            kern_return_t qkr = mach_vm_region(mach_task_self(), &addr, &reg_size,
                                               VM_REGION_BASIC_INFO_64,
                                               (vm_region_info_t)&info,
                                               &info_cnt, &obj_name);
            if (qkr == KERN_SUCCESS && (info.protection & VM_PROT_EXECUTE))
            {
                return 0;  /* genuinely RX/RWX — done */
            }
            ERR("iOS mprotect(rwx) appeared to succeed but EXEC not actually granted "
                "at %p+0x%lx (qkr=%d prot=0x%x); falling through to JIT-pool path\n",
                base, (unsigned long)size, qkr, qkr == KERN_SUCCESS ? info.protection : -1);
        }

        if (!jit_rx_base || !jit_rw_base)
        {
            ERR("iOS JIT: no pool, cannot make %p+0x%lx executable\n",
                base, (unsigned long)size);
            return mprotect( base, size, unix_prot & ~PROT_EXEC );
        }

        /* Find the PE image base by scanning backward for MZ signature.
         * We need to copy the ENTIRE image (code + data) to preserve
         * ADRP-based PC-relative data references. */
        {
            void *image_base = NULL;
            size_t image_size = 0;
            char *scan = (char *)base;
            int i;

            /* Check if this image was already copied to JIT pool */
            for (i = 0; i < ios_jit_mapping_count; i++)
            {
                uintptr_t a = (uintptr_t)base;
                uintptr_t mb = (uintptr_t)ios_jit_mappings[i].pe_base;
                if (a >= mb && a < mb + ios_jit_mappings[i].size)
                {
                    /* ml352: containment alone LIES when the entry is STALE.
                     * rsaenh.dll unloaded, windows.ui.dll later mapped INSIDE
                     * rsaenh's old range; this early-out then skipped
                     * windows.ui's pool copy entirely, and every translate
                     * routed its code into rsaenh's dead copy — whose bytes at
                     * that offset are section padding: ZEROS → udf → dead run
                     * (ml351, and the run-to-run "variance" = VA-recycling
                     * roulette). The add_mapping stale-purge never fires
                     * because this early-out precedes it. Validate the entry:
                     * its pe_base must still hold a PE header whose
                     * SizeOfImage matches the entry. Fault-safe reads — the
                     * stale base may be unmapped. Invalid → skip the entry;
                     * the fresh copy below re-registers and add_mapping's
                     * overlap purge tombstones the stale one. */
                    {
                        unsigned short mz = 0;
                        unsigned int lfanew = 0, imgsz = 0;
                        mach_vm_size_t got = 0;
                        int entry_ok =
                            mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)mb, 2,
                                                   (mach_vm_address_t)&mz, &got) == KERN_SUCCESS &&
                            got == 2 && mz == 0x5A4D &&
                            mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)(mb + 0x3c), 4,
                                                   (mach_vm_address_t)&lfanew, &got) == KERN_SUCCESS &&
                            got == 4 && lfanew && lfanew < 0x1000 &&
                            mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)(mb + lfanew + 0x50), 4,
                                                   (mach_vm_address_t)&imgsz, &got) == KERN_SUCCESS &&
                            got == 4 &&
                            (imgsz == ios_jit_mappings[i].size ||
                             ((imgsz + 0x3fffu) & ~0x3fffu) == ios_jit_mappings[i].size);
                        if (!entry_ok)
                        {
                            dprintf(2, "[jit-pool] STALE containment rev=ml352: entry pe=%p+0x%lx "
                                    "no longer matches what is mapped there (mz=%04x lfanew=0x%x imgsz=0x%x) "
                                    "— ignoring entry, copying fresh image for %p\n",
                                    (void *)mb, (unsigned long)ios_jit_mappings[i].size,
                                    mz, lfanew, imgsz, base);
                            continue;
                        }
                    }
                    ERR("iOS JIT: %p already in mapping %d (%p+0x%lx)\n",
                        base, i, (void*)mb, (unsigned long)ios_jit_mappings[i].size);
                    /* If write was requested (e.g. IAT lives in a section that
                     * the linker also marked EXEC), grant RW on the PE-side
                     * page via Mach vm_protect. The JIT pool already has the
                     * executable copy at the original RX address; we don't
                     * need EXEC here. After writes land, NtProtectVirtualMemory's
                     * IAT-sync handler copies them to the JIT pool. */
                    if (unix_prot & PROT_WRITE)
                    {
                        kern_return_t kr = vm_protect(mach_task_self(),
                            (vm_address_t)base, size, FALSE,
                            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                        if (kr == KERN_SUCCESS) {
                            ERR("iOS vm_protect RW+COPY OK at %p+0x%lx (was rwx)\n",
                                base, (unsigned long)size);
                            return 0;
                        }
                        ERR("iOS vm_protect RW failed kr=%d at %p+0x%lx (was rwx)\n",
                            kr, base, (unsigned long)size);
                    }
                    mprotect( base, size, PROT_READ );
                    return 0;
                }
            }

            /* Scan backward to find MZ header (PE image start). Bound the
             * scan to a reasonable distance (max 64MB) so anonymous RWX
             * regions don't trigger long backward walks into unmapped memory.
             * Also probe each candidate page via mach_vm_region first to
             * confirm it's mapped before dereferencing. */
            char *scan_limit = (char *)((uintptr_t)base - 0x4000000);  /* 64MB */
            if (scan_limit < (char *)0x10000) scan_limit = (char *)0x10000;
            for (scan = (char *)((uintptr_t)base & ~0x3FFFUL); scan > scan_limit; scan -= 0x4000)
            {
                /* Probe page via mach_vm_region to skip unmapped gaps */
                {
                    mach_vm_address_t qa = (mach_vm_address_t)scan;
                    mach_vm_size_t qs = 0;
                    vm_region_basic_info_data_64_t qinfo;
                    mach_msg_type_number_t qcnt = VM_REGION_BASIC_INFO_COUNT_64;
                    mach_port_t qobj = MACH_PORT_NULL;
                    if (mach_vm_region(mach_task_self(), &qa, &qs,
                                       VM_REGION_BASIC_INFO_64,
                                       (vm_region_info_t)&qinfo, &qcnt, &qobj)
                        != KERN_SUCCESS) break;
                    /* If mach_vm_region returned a region above scan,
                     * scan is unmapped — skip ahead to that region's start. */
                    if ((char *)qa > scan) break;
                    /* Mapped but not readable (PROT_NONE reservation, or
                     * exec-only JIT page): dereferencing faults even though
                     * vm_region reports a region. A PE image is contiguously
                     * readable, so a non-readable page means we've walked
                     * below the image — stop the scan. (Seen 2026-07-03:
                     * X64ReturnInstr's anon-RWX VA sat above a PROT_NONE
                     * Wine reservation; the scan deref'd it, the resulting
                     * UNHANDLED faults derailed the whole redirect.) */
                    if (!(qinfo.protection & VM_PROT_READ)) break;
                }
                if (*(unsigned short *)scan == 0x5A4D)  /* MZ */
                {
                    unsigned int pe_off = *(unsigned int *)(scan + 0x3C);
                    if (pe_off < 0x1000 && *(unsigned int *)(scan + pe_off) == 0x00004550)  /* PE\0\0 */
                    {
                        image_base = scan;
                        /* SizeOfImage is at PE + 0x18 (optional header) + 0x38 (PE32+) */
                        image_size = *(unsigned int *)(scan + pe_off + 0x50);
                        break;
                    }
                }
            }

            /* ml348: the backward scan finds the NEAREST MZ below, which is not
             * necessarily the image this page belongs to. A standalone exec
             * allocation placed just above a module (ml347: a 4KB RWX page at
             * 0x73e30b0000, 0x40000 past advapi32's SizeOfImage end) was
             * attributed to that module, so the module got re-copied while the
             * page itself got neither exec nor a pool alias — left read-only
             * with no alias, every guest store to it faulted forever (STLR
             * w0,[x8], 8+ identical faults, thread dead). Range-check the hit;
             * on failure fall through to the anonymous-RWX path, which carves a
             * pool slot AND registers the alias the store emulator needs. */
            if (image_base &&
                ((uintptr_t)base < (uintptr_t)image_base ||
                 (uintptr_t)base + size > (uintptr_t)image_base + image_size))
            {
                dprintf(2, "[jit-pool] exec page %p+0x%lx is OUTSIDE nearest image %p+0x%lx "
                        "(%s) — treating as anonymous RWX rev=ml348\n",
                        base, (unsigned long)size, image_base, (unsigned long)image_size,
                        ios_pe_module_name(image_base, image_size));

                /* iOS-Madeira ml632: MIXED-MAPPING TRIPWIRE.
                 *
                 * This test is ALL-OR-NOTHING: if the request is not wholly inside the
                 * image it is treated as anonymous in its entirety — even the part that
                 * genuinely overlaps the image. Meanwhile ios_jit_sync_write's IAT sync
                 * accepts SUBRANGES by numerical containment alone, so the overlapping
                 * pages end up owned by BOTH registries.
                 *
                 * ULTRAKILL died on exactly that: anon alias [0x706e9b0000,0x706e9c0000)
                 * vs "image" [0x706e990000,0x706e9b4000) — a 16KB overlap — and
                 * `[iat-sync] region 0x706e9b3000+0x1000: translated 2 pointers` rewrote
                 * the page holding the bad block's entry at +0x33e0. Control then ran off
                 * into zero padding and died 0xc06 bytes later.
                 *
                 * Report the collision with both mappings' real Mach identity, so a
                 * genuine PE mapping can be told from a stale/adjacent MZ hit. */
                {
                    uintptr_t o_lo = (uintptr_t)base > (uintptr_t)image_base
                                   ? (uintptr_t)base : (uintptr_t)image_base;
                    uintptr_t o_hi = ((uintptr_t)base + size) < ((uintptr_t)image_base + image_size)
                                   ? ((uintptr_t)base + size) : ((uintptr_t)image_base + image_size);
                    if (o_lo < o_hi)
                    {
                        static int mixed_n;
                        if (mixed_n < 16)
                        {
                            mach_vm_address_t qa; mach_vm_size_t qs; 
                            vm_region_basic_info_data_64_t qi; mach_msg_type_number_t qc;
                            mach_port_t qo; kern_return_t qk;
                            unsigned rp = 0, ip = 0;
                            qa = (mach_vm_address_t)base; qs = 0; qc = VM_REGION_BASIC_INFO_COUNT_64;
                            qk = mach_vm_region( mach_task_self(), &qa, &qs, VM_REGION_BASIC_INFO_64,
                                                 (vm_region_info_t)&qi, &qc, &qo );
                            if (qk == KERN_SUCCESS) rp = qi.protection;
                            qa = (mach_vm_address_t)image_base; qs = 0; qc = VM_REGION_BASIC_INFO_COUNT_64;
                            qk = mach_vm_region( mach_task_self(), &qa, &qs, VM_REGION_BASIC_INFO_64,
                                                 (vm_region_info_t)&qi, &qc, &qo );
                            if (qk == KERN_SUCCESS) ip = qi.protection;
                            ++mixed_n;
                            dprintf(2, "[mixed-map] ml632 #%d COLLISION: request %p+0x%lx (prot=%u) vs image %p+0x%lx "
                                       "(prot=%u, %s) — OVERLAP [%p,%p) %lu KB claimed by BOTH registries\n",
                                    mixed_n, base, (unsigned long)size, rp,
                                    image_base, (unsigned long)image_size, ip,
                                    ios_pe_module_name(image_base, image_size),
                                    (void *)o_lo, (void *)o_hi, (unsigned long)((o_hi - o_lo) / 1024));
                        }
                    }
                }
                image_base = NULL;
                image_size = 0;
            }

            if (!image_base || !image_size)
            {
                /* iOS-Madeira: anonymous RWX request (e.g. FEX's CodeBuffer
                 * allocates a 16MB PAGE_EXECUTE_READWRITE region for runtime
                 * JIT). No PE header to copy. Strategy: take a slot from the
                 * JIT pool, vm_remap from `jit_rx_base + offset` into the
                 * caller's VA (which gives the caller's pages R+X via the
                 * dual-map), and record a `user_VA -> jit_rw_base + offset`
                 * alias so the STR-fault emulator routes writes through the
                 * RW alias. FEX writes via user_VA fault → emulator routes;
                 * FEX executes via user_VA → R+X works. */
                size_t page_size = 0x4000;
                size_t alloc_size = (size + page_size - 1) & ~(page_size - 1);

                /* iOS-Madeira ml625: NEVER RE-BACK A GUEST VA THAT IS ALREADY LIVE.
                 *
                 * vm_remap below uses VM_FLAGS_OVERWRITE and does NOT preserve the
                 * old contents, so re-running this path on a range that already holds
                 * emitted guest code DESTROYS it. That is exactly how the ml624 run
                 * died: Mono emitted x64 code + UNWIND_INFO into 0x7040220000, then
                 * this path ran three more times for the same VA, each taking a fresh
                 * zeroed 16KB pool slot. FEX kept executing its cached translation of
                 * code that no longer existed, wine read unwind version 0 from the
                 * zeroed metadata, and RtlVirtualUnwind2 spun ~15.8M times until the
                 * 8MB guest stack was exhausted.
                 *
                 * A repeat request is a RE-PROTECT, not a new allocation: keep the
                 * existing backing and just (re)assert R+X. */
                {
                    extern int ios_jit_anon_alias_find_cover(void *, size_t, void **, void **);
                    void *ex_rw = NULL, *ex_rx = NULL;
                    if (ios_jit_anon_alias_find_cover(base, alloc_size, &ex_rw, &ex_rx))
                    {
                        kern_return_t pkr = vm_protect(mach_task_self(),
                            (vm_address_t)base, alloc_size, FALSE,
                            VM_PROT_READ | VM_PROT_EXECUTE);
                        TEB *cur_teb = NtCurrentTeb();

                        /* ml626: OBSERVE the protection state, do NOT try to repair it.
                         *
                         * In the ml625 run the FIRST reuse returned kr=0 and every later
                         * one kr=2 (KERN_PROTECTION_FAILURE) for the same VA, with the
                         * 64KB region split and its first 16KB showing max=3 (RW, no
                         * EXEC) -- vm_protect can never grant EXEC once max has been
                         * lowered, so a "repair" via set_maximum=TRUE would not work
                         * anyway. It is also quite possibly FALLOUT from the failed
                         * SWPAL redelivery loop rather than a cause. Log cur/max so the
                         * next run says which, and change nothing yet. */
                        {
                            static int reuse_prot_n;
                            if (pkr != KERN_SUCCESS || reuse_prot_n < 16)
                            {
                                mach_vm_address_t q = (mach_vm_address_t)base;
                                mach_vm_size_t qsz = 0;
                                vm_region_basic_info_data_64_t qi;
                                mach_msg_type_number_t qc = VM_REGION_BASIC_INFO_COUNT_64;
                                mach_port_t qobj = MACH_PORT_NULL;
                                kern_return_t qkr = mach_vm_region( mach_task_self(), &q, &qsz,
                                        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&qi, &qc, &qobj );
                                ++reuse_prot_n;
                                dprintf(2, "[jit-prot] ml626 #%d %p region=%p+0x%llx cur=%d max=%d "
                                        "(region kr=%d) after vm_protect(R+X) kr=%d\n",
                                        reuse_prot_n, base, (void *)(uintptr_t)q,
                                        (unsigned long long)qsz,
                                        qkr == KERN_SUCCESS ? qi.protection : -1,
                                        qkr == KERN_SUCCESS ? qi.max_protection : -1,
                                        (int)qkr, (int)pkr);
                            }
                        }

                        dprintf(2, "[jit-pool] anon RWX %p size=0x%lx REUSE existing alias "
                                "(rx=%p rw=%p) vm_protect kr=%d tid=%04x peb=%p rev=ml625\n",
                                base, (unsigned long)alloc_size, ex_rx, ex_rw, (int)pkr,
                                cur_teb ? (unsigned)(ULONG_PTR)cur_teb->ClientId.UniqueThread : 0u,
                                cur_teb ? (void *)cur_teb->Peb : NULL);
                        return 0;
                    }
                }

                /* ml630: DO NOT BURN A POOL RANGE WE CANNOT REGISTER.
                 *
                 * The ml629 run consumed three further pool ranges while repeatedly
                 * failing to register the SAME buffer, because the table check lived
                 * downstream of the allocation. Check first; an unregisterable mapping
                 * is worse than a refused one, since writes to it silently do not route. */
                if (ios_jit_anon_alias_count >= IOS_JIT_MAX_ANON_ALIASES)
                {
                    int free_slot = 0, ci;
                    for (ci = 0; ci < ios_jit_anon_alias_count; ci++)
                        if (!ios_jit_anon_aliases[ci].user_va) { free_slot = 1; break; }
                    if (!free_slot)
                    {
                        dprintf(2, "[jit-pool] anon RWX %p REFUSED: alias table full (%d, live=%d hiwater=%d) "
                                   "— refusing the mapping rather than shipping one whose writes cannot route "
                                   "rev=ml630\n",
                                base, IOS_JIT_MAX_ANON_ALIASES, ios_jit_anon_alias_live,
                                ios_jit_anon_alias_hiwater);
                        mprotect( base, size, PROT_READ );
                        errno = ENOMEM;
                        return -1;
                    }
                }

                size_t offset = ios_pool_alloc_range(alloc_size, jit_pool_size - ios_jit_tail_reserved);
                if (offset == (size_t)-1)
                {
                    ERR("iOS JIT: pool exhausted for anon RWX %p+0x%lx\n",
                        base, (unsigned long)size);
                    dprintf(2, "[jit-pool] EXHAUSTED (anon RWX): want=0x%lx bump=0x%lx/0x%lx tail_resv=0x%lx freelist=%d — FAILING allocation\n",
                            (unsigned long)alloc_size, (unsigned long)jit_pool_offset, (unsigned long)jit_pool_size,
                            (unsigned long)ios_jit_tail_reserved, ios_pool_free_count);
                    mprotect( base, size, PROT_READ );
                    errno = ENOMEM;
                    return -1;
                }

                /* iOS-Madeira ml634: PRESERVE THE GUEST'S EXISTING BYTES BEFORE REMAPPING.
                 *
                 * The vm_remap below uses VM_FLAGS_OVERWRITE to put a FRESH, ZERO-FILLED
                 * pool slot on top of `base`. The PE-image path a few hundred lines down
                 * memcpy()s the image into the pool first and invalidates the icache; this
                 * anonymous path never copied anything. So the very FIRST RW->RX transition
                 * of a Mono JIT buffer replaced everything Mono had already emitted with
                 * zeros.
                 *
                 * That explains the whole ULTRAKILL signature: RX and RW MATCH afterwards
                 * (both now view the same erased pool storage), FEX starts translating at
                 * base+0x33e0, sees `00 00` = `add byte [rax], al` all the way, and dies at
                 * +0x4006. ml625 only stopped destructive remapping on SUBSEQUENT
                 * re-protects — it never protected the initial transition.
                 *
                 * ⚠️ The +0x4000 overlap with the "nearest image" is an ACCOUNTING ARTIFACT,
                 * not the edge of real code: that image is a managed assembly Mono mapped as
                 * DATA (mapped size 0x1f000) whose PE header declares SizeOfImage 0x24000,
                 * and the backward MZ scan trusts the declared size. Do not read the
                 * boundary as "generated code ends here". */
                uint64_t ml634_pre_hash = 1469598103934665603ull;
                size_t   ml634_nonzero = 0;
                {
                    char *rw_dst = (char *)jit_rw_base + offset;
                    char *rx_dst = (char *)jit_rx_base + offset;
                    const unsigned char *src = (const unsigned char *)base;
                    size_t i;

                    for (i = 0; i < size; i++)
                    {
                        ml634_pre_hash = (ml634_pre_hash ^ src[i]) * 1099511628211ull;
                        if (src[i]) ml634_nonzero++;
                    }

                    memset( rw_dst, 0, alloc_size );
                    memcpy( rw_dst, src, size );
                    sys_icache_invalidate( rx_dst, alloc_size );

                    {
                        static int pre_n;
                        if (ml634_nonzero || pre_n < 24)   /* ml635: nonzero is ALWAYS reported */
                            dprintf(2, "[jit-copy] ml634 #%d PRE-REMAP %p+0x%lx: %lu/%lu bytes nonzero, fnv=%016llx "
                                       "— copied into pool off=0x%lx\n",
                                    ++pre_n, base, (unsigned long)size,
                                    (unsigned long)ml634_nonzero, (unsigned long)size,
                                    (unsigned long long)ml634_pre_hash, (unsigned long)offset);
                    }
                }

                vm_address_t target = (vm_address_t)base;
                vm_prot_t cur_prot = 0, max_prot = 0;
                kern_return_t kr = vm_remap(mach_task_self(),
                    &target, alloc_size, 0,
                    VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                    mach_task_self(),
                    (vm_address_t)((char *)jit_rx_base + offset),
                    FALSE,
                    &cur_prot, &max_prot,
                    VM_INHERIT_DEFAULT);
                if (kr != KERN_SUCCESS)
                {
                    ERR("iOS JIT: anon RWX vm_remap failed kr=%d %p+0x%lx\n",
                        kr, base, (unsigned long)alloc_size);
                    mprotect( base, size, PROT_READ );
                    return 0;
                }

                /* iOS needs an explicit vm_protect to activate EXEC on the
                 * remapped pages — vm_remap reports cur_prot=R+X in its output
                 * but the kernel doesn't actually grant exec permission until
                 * we explicitly request it. */
                {
                    kern_return_t pkr = vm_protect(mach_task_self(),
                        (vm_address_t)base, alloc_size, FALSE,
                        VM_PROT_READ | VM_PROT_EXECUTE);
                    if (pkr != KERN_SUCCESS)
                    {
                        ERR("iOS JIT: anon RWX vm_protect(R+X) failed kr=%d %p+0x%lx\n",
                            pkr, base, (unsigned long)alloc_size);
                    }
                }

                /* Mark the JIT-pool slot as ARM64EC code so arm64x_check_call
                 * routes correctly (FEX-emitted code is treated as EC for
                 * dispatcher purposes). */
                if (arm64ec_view)
                {
                    char *jit_base = (char *)jit_rx_base + offset;
                    /* iOS-Madeira: 4KB-page indexing per arm64x_check_call ABI */
                    size_t bm_start = ((size_t)jit_base >> 12) / 8;
                    size_t bm_end   = (((size_t)jit_base + alloc_size) >> 12) / 8;
                    size_t bm_size  = ROUND_SIZE(bm_start, bm_end + 1 - bm_start, page_mask);
                    void *bm_page   = ROUND_ADDR((char *)arm64ec_view->base + bm_start, page_mask);
                    set_vprot(arm64ec_view, bm_page, bm_size,
                              VPROT_READ | VPROT_WRITE | VPROT_COMMITTED);
                    set_arm64ec_range(jit_base, alloc_size);
                }

                /* ml634: both views must now hash to what the guest had before the remap. */
                {
                    static int post_n;
                    if (post_n < 24)
                    {
                        const unsigned char *rxv = (const unsigned char *)base;
                        const unsigned char *rwv = (const unsigned char *)((char *)jit_rw_base + offset);
                        uint64_t hx = 1469598103934665603ull, hw = 1469598103934665603ull;
                        size_t i;
                        for (i = 0; i < size; i++)
                        {
                            hx = (hx ^ rxv[i]) * 1099511628211ull;
                            hw = (hw ^ rwv[i]) * 1099511628211ull;
                        }
                        ++post_n;
                        dprintf(2, "[jit-copy] ml634 #%d POST-REMAP rx=%016llx rw=%016llx pre=%016llx => %s\n",
                                post_n, (unsigned long long)hx, (unsigned long long)hw,
                                (unsigned long long)ml634_pre_hash,
                                (hx == ml634_pre_hash && hw == ml634_pre_hash)
                                    ? "PRESERVED"
                                    : "**CONTENT LOST** — the remap still erased the guest's bytes");
                    }
                }

                /* Record secondary alias for STR fault emulator and exec PC redirect. */
                extern int ios_jit_anon_alias_add(void *user_va, size_t size,
                                                  void *jit_rw_alias);
                extern void ios_jit_anon_alias_set_rx(void *user_va, void *jit_rx_alias);
                if (!ios_jit_anon_alias_add(base, alloc_size, (char *)jit_rw_base + offset))
                {
                    /* ml630: lost a race for the last slot. The remap already happened,
                     * so the honest move is to fail loudly here rather than return an
                     * executable mapping whose writes will not route. */
                    dprintf(2, "[jit-pool] anon RWX %p FAILED to register alias after remap "
                               "(pool off=0x%lx) — failing the request rev=ml630\n",
                            base, (unsigned long)offset);
                    mprotect( base, size, PROT_READ );
                    errno = ENOMEM;
                    return -1;
                }
                ios_jit_anon_alias_set_rx(base, (char *)jit_rx_base + offset);

                ERR("iOS JIT: anon RWX %p+0x%lx → pool offset 0x%lx (rx=%p rw=%p)"
                    " cur_prot=0x%x max_prot=0x%x\n",
                    base, (unsigned long)alloc_size, (unsigned long)offset,
                    (char *)jit_rx_base + offset, (char *)jit_rw_base + offset,
                    cur_prot, max_prot);
                {
                    TEB *cur_teb = NtCurrentTeb();
                    dprintf(2, "[jit-pool] anon RWX %p size=0x%lx → used=0x%lx/0x%lx NEW off=0x%lx tid=%04x peb=%p rev=ml625\n",
                            base, (unsigned long)alloc_size,
                            (unsigned long)(offset + alloc_size), (unsigned long)jit_pool_size,
                            (unsigned long)offset,
                            cur_teb ? (unsigned)(ULONG_PTR)cur_teb->ClientId.UniqueThread : 0u,
                            cur_teb ? (void *)cur_teb->Peb : NULL);
                }
                return 0;
            }

            /* ml457 REVERTED (ml458) — DO NOT RE-ATTEMPT skipping pool copies
             * for pure-x64 images.  The premise ("x64 runs only through FEX, so
             * its pool copy is never entered") is FALSE: x64 guest RIPs ARE
             * pool-copy aliases.  FEX decodes and dispatches x64 code at POOL
             * addresses — see [pool-rip-fix] (FEXCore Core.cpp), [exc-pool-rip]
             * (ARM64EC Module.cpp), and task #52's CompileBlock reverse-translate.
             * Removing the copy removes the execution substrate: ml457 (db 5840)
             * skipped steamexe.exe 38× and steam.exe died in seconds calling a
             * garbage target (pc=0, guest RIP=0x69) out of vstdlib's .fptable
             * indirection.  The 369MB of x64 copies is REAL cost, not waste.
             * Budget must come from elsewhere (dedup of duplicate EC copies,
             * CodeBuffer generation cap, or making the pool no-footprint so it
             * can grow past the jetsam-bound 896MB). */

            /* Align to 16KB page boundary.
             * task #34 .text sharing: fold the x18 trampoline region into
             * the image's own allocation at a FIXED image-relative offset
             * (right after the aligned image). Every copy of the same DLL
             * then patches identical PC-relative branches → patched .text
             * and tramps are byte-identical across copies (precondition for
             * page sharing). Also kills the 80MB-anchor dance: worst-case
             * text→tramp distance is now ≤ image size, far under ±128MB. */
            size_t page_size = 0x4000;
            size_t image_alloc = (image_size + page_size - 1) & ~(page_size - 1);
            size_t tramp_prealloc = ios_x18_tramp_prealloc_scan(image_base, image_size);
            size_t data_delta = ios_jit_data_align_delta(image_base, image_size);
            size_t alloc_size = image_alloc + tramp_prealloc + (data_delta ? page_size : 0);
            size_t offset = ios_pool_alloc_range(alloc_size, jit_pool_size - ios_jit_tail_reserved);
            if (offset != (size_t)-1 && data_delta)
            {
                offset += data_delta;
                dprintf(2, "[data-align] %s shifted +0x%lx so .data lands on a 16KB page\n",
                        ios_pe_module_name( image_base, image_size ), (unsigned long)data_delta);
            }

            if (offset == (size_t)-1)
            {
                ERR("iOS JIT: pool exhausted\n");
                /* Task #25: FAIL the protect instead of silently leaving the
                 * image R-only — the old path returned success and the first
                 * call into the module BUS-fault-looped, locking the whole
                 * session. -1/ENOMEM propagates up as a failed module load /
                 * failed process start, which the shell reports and survives. */
                dprintf(2, "[jit-pool] EXHAUSTED (image %p+0x%lx): want=0x%lx bump=0x%lx/0x%lx tail_resv=0x%lx freelist=%d — FAILING the load (was: silent BUS loop)\n",
                        image_base, (unsigned long)image_size, (unsigned long)alloc_size,
                        (unsigned long)jit_pool_offset, (unsigned long)jit_pool_size,
                        (unsigned long)ios_jit_tail_reserved, ios_pool_free_count);
                mprotect( base, size, PROT_READ );
                errno = ENOMEM;
                return -1;
            }

            /* Copy ENTIRE PE image to JIT pool (code + data + headers).
             * This preserves ADRP-based PC-relative references between sections. */
            ios_jit_scan_nonexec( "pre-memcpy", ios_pe_module_name( image_base, image_size ),
                                  (char *)jit_rx_base + offset, image_size );
            memcpy((char *)jit_rw_base + offset, image_base, image_size);
            ios_jit_scan_nonexec( "post-memcpy", ios_pe_module_name( image_base, image_size ),
                                  (char *)jit_rx_base + offset, image_size );
            sys_icache_invalidate((char *)jit_rx_base + offset, image_size);
            ios_jit_scan_nonexec( "post-icache", ios_pe_module_name( image_base, image_size ),
                                  (char *)jit_rx_base + offset, image_size );
            ios_jit_verify_copy( (const char *)image_base,
                                 (const char *)jit_rx_base + offset,
                                 image_size, ios_pe_module_name( image_base, image_size ),
                                 offset, ios_pool_last_alloc_reused );

            /* Record mapping for the entire image */
            ios_jit_add_mapping(image_base, (char *)jit_rx_base + offset, image_size);

            ERR("iOS JIT: copied image %p+0x%lx → pool %p (offset 0x%lx, used 0x%lx/0x%lx)\n",
                image_base, (unsigned long)image_size, (char *)jit_rx_base + offset,
                (unsigned long)offset,
                (unsigned long)(offset + alloc_size), (unsigned long)jit_pool_size);
            /* ml670: PHASE trigger for the fast sampler. ml668 only sped up
             * once a sample READ >=2800MB, which is unreachable here -- the last
             * observed value was 2481MB and the burst reached jetsam inside one
             * 2s window, so fast mode never engaged and we still have no real
             * terminal peak. Texture upload begins right after d3d11 loads, so
             * switch on the phase instead of on a level. */
            {
                const char *mn = ios_pe_module_name( image_base, image_size );
                if (mn && (strstr(mn, "d3d11") || strstr(mn, "D3D11")))
                    ios_fast_footprint = 1;
            }
            dprintf(2, "[jit-pool] image %p+0x%lx (%s) → pool %p used=0x%lx/0x%lx tramp+0x%lx\n",
                    image_base, (unsigned long)image_size,
                    ios_pe_module_name( image_base, image_size ), (char *)jit_rx_base + offset,
                    (unsigned long)(offset + alloc_size), (unsigned long)jit_pool_size,
                    (unsigned long)tramp_prealloc);

            ios_jit_verify_text_exec( ios_pe_module_name( image_base, image_size ),
                                      (char *)jit_rx_base + offset, image_size );

            /* task #34 [share-probe]: DEFAULT-OFF (set MADEIRA_SHARE_PROBE=1).
             * ml79: running it inline here (pre-detach, on explorer's boot
             * thread) wedged the session — exec-at-alias hangs while the
             * debugger is attached. Gated + deferred to a scratch thread
             * that waits for CS_DEBUGGED to clear before probing. */
            {
                static int ios_share_probed;
                if (!ios_share_probed && getenv("MADEIRA_SHARE_PROBE"))
                {
                    pthread_t pt;
                    ios_share_probed = 1;
                    if (!pthread_create(&pt, NULL, ios_share_probe_thread, NULL))
                        pthread_detach(pt);
                }
            }

            /* Mark the JIT-pool range as ARM64EC code in the EcCodeBitMap —
             * but ONLY for ARM64EC hybrid PEs. ARM64EC binaries have
             * Machine=0x8664 (per Microsoft's ABI) just like pure x86_64,
             * so we can't distinguish via Machine. Use the presence of a
             * `.hexpthk` section as the discriminator (only ARM64EC PEs
             * have it). Pure x86_64 PEs (e.g. hello-x64.exe) must NOT be
             * marked EC because arm64x_check_call would then dispatch BL
             * directly into the JIT-pool copy of x86_64 instructions
             * (executed as ARM64 → garbage). Pure x86_64 entries fall
             * through to the dispatch_call_no_redirect path → xtajit64. */
            int is_arm64ec_hybrid = 0;
            {
                unsigned int pe_o = *(unsigned int *)((char *)jit_rw_base + offset + 0x3C);
                unsigned short num_s = *(unsigned short *)((char *)jit_rw_base + offset + pe_o + 6);
                unsigned short opt_s = *(unsigned short *)((char *)jit_rw_base + offset + pe_o + 0x14);
                char *sec = (char *)jit_rw_base + offset + pe_o + 0x18 + opt_s;
                int j;
                for (j = 0; j < num_s; j++, sec += 40)
                {
                    if (sec[0] == '.' && sec[1] == 'h' && sec[2] == 'e' && sec[3] == 'x' &&
                        sec[4] == 'p' && sec[5] == 't' && sec[6] == 'h' && sec[7] == 'k')
                    {
                        is_arm64ec_hybrid = 1;
                        break;
                    }
                }
            }
            if (arm64ec_view && is_arm64ec_hybrid)
            {
                char *jit_base = (char *)jit_rx_base + offset;
                char *rw_image = (char *)jit_rw_base + offset;
                /* iOS-Madeira: arm64x_check_call uses 4KB-page indexing always.
                 * Compute bitmap byte offsets with 12-bit shift so committed
                 * pages cover where set_arm64ec_range will write. */
                size_t bm_start = ((size_t)jit_base >> 12) / 8;
                size_t bm_end   = (((size_t)jit_base + image_size) >> 12) / 8;
                size_t bm_size  = ROUND_SIZE(bm_start, bm_end + 1 - bm_start, page_mask);
                void *bm_page   = ROUND_ADDR((char *)arm64ec_view->base + bm_start, page_mask);
                set_vprot(arm64ec_view, bm_page, bm_size,
                          VPROT_READ | VPROT_WRITE | VPROT_COMMITTED);
                /* CRITICAL FIX: ARM64EC PEs (ntdll, kernel32, ucrtbase, etc.)
                 * have INTERMIXED ARM64EC code AND x86_64 syscall stubs in
                 * their .text section. The IMAGE_ARM64EC_METADATA::CodeMap
                 * tells us which RVA ranges are which (StartOffset low 2 bits:
                 * 0=ARM64, 1=ARM64EC, 2=x86_64). Marking the entire image as
                 * EC causes arm64x_check_call to think x86_64 stubs are EC,
                 * which makes hybpatch thunks BR x11 directly into x86_64
                 * bytes (executed as ARM64 → garbage targets). */
                {
                    /* Parse the load config to find CHPEMetadataPointer */
                    unsigned int pe_o = *(unsigned int *)(rw_image + 0x3C);
                    unsigned short opt_s = *(unsigned short *)(rw_image + pe_o + 0x14);
                    char *opt_hdr = rw_image + pe_o + 0x18;
                    /* DataDirectories start at opt_hdr + 0x70 (PE32+) */
                    /* IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG = 10, offset 10*8=0x50 from data dirs */
                    unsigned int load_cfg_rva = *(unsigned int *)(opt_hdr + 0x70 + 10*8);
                    unsigned int load_cfg_size = *(unsigned int *)(opt_hdr + 0x70 + 10*8 + 4);
                    int found_codemap = 0;
                    ERR("iOS JIT: load_cfg rva=0x%x size=0x%x\n", load_cfg_rva, load_cfg_size);
                    if (load_cfg_rva && load_cfg_size > 0xD0)
                    {
                        char *load_cfg = rw_image + load_cfg_rva;
                        /* CHPEMetadataPointer is at offset 0xC8 in IMAGE_LOAD_CONFIG_DIRECTORY64 */
                        uint64_t chpe_meta_va = *(uint64_t *)(load_cfg + 0xC8);
                        ERR("iOS JIT: chpe_meta_va=0x%llx pe_image_base=0x%llx\n",
                            (unsigned long long)chpe_meta_va,
                            (unsigned long long)*(uint64_t *)(opt_hdr + 0x18));
                        uint64_t pe_image_base = *(uint64_t *)(opt_hdr + 0x18);
                        if (chpe_meta_va && chpe_meta_va >= pe_image_base &&
                            chpe_meta_va < pe_image_base + image_size)
                        {
                            uint64_t chpe_meta_rva = chpe_meta_va - pe_image_base;
                            char *meta = rw_image + chpe_meta_rva;
                            /* IMAGE_ARM64EC_METADATA: CodeMap RVA at +0x4, CodeMapCount at +0x8 */
                            unsigned int code_map_rva = *(unsigned int *)(meta + 0x4);
                            unsigned int code_map_count = *(unsigned int *)(meta + 0x8);
                            if (code_map_rva && code_map_count)
                            {
                                /* IMAGE_CHPE_RANGE_ENTRY: 8 bytes each (StartOffset 32-bit, Length 32-bit) */
                                char *code_map = rw_image + code_map_rva;
                                int ec_count = 0, x64_count = 0, arm_count = 0;
                                for (unsigned int i = 0; i < code_map_count; i++)
                                {
                                    unsigned int start = *(unsigned int *)(code_map + i*8);
                                    unsigned int len   = *(unsigned int *)(code_map + i*8 + 4);
                                    int range_type = start & 0x3;
                                    unsigned int rva = start & ~0x3u;
                                    if (range_type == 1) /* ARM64EC */
                                    {
                                        set_arm64ec_range(jit_base + rva, len);
                                        ec_count++;
                                    }
                                    else if (range_type == 2) x64_count++;
                                    else if (range_type == 0) arm_count++;
                                }
                                ERR("iOS JIT: CodeMap parsed: %d ARM64EC ranges, %d x86_64, %d ARM64 entries (total %u)\n",
                                    ec_count, x64_count, arm_count, code_map_count);
                                found_codemap = 1;
                            }
                        }
                    }
                    if (!found_codemap)
                    {
                        /* Fallback: mark whole image as EC (old behavior, may misclassify x64 stubs) */
                        ERR("iOS JIT: no CodeMap found — falling back to coarse-mark whole image\n");
                        set_arm64ec_range(jit_base, image_size);
                    }
                }
                {
                    /* iOS-Madeira dual-map RX-side verification.
                     * Read the first 4 bytes of .text via RX alias and compare
                     * to the same offset via RW alias (which we just memcpy'd
                     * to). If they differ, the dual-map isn't aliased correctly
                     * for this page and FEX/Wine will fetch garbage on BL. */
                    if (image_size > 0x4000)
                    {
                        volatile uint32_t rx_byte0 = *(volatile uint32_t *)((char *)jit_rx_base + offset + 0x4000);
                        uint32_t rw_byte0 = *(uint32_t *)((char *)jit_rw_base + offset + 0x4000);
                        ERR("iOS JIT: dual-map RX[+0x4000]=0x%08x  RW[+0x4000]=0x%08x  match=%d\n",
                            rx_byte0, rw_byte0, rx_byte0 == rw_byte0);
                        /* Also probe a deeper offset (around middle of image) */
                        size_t deep = (image_size / 2) & ~3UL;
                        volatile uint32_t rx_mid = *(volatile uint32_t *)((char *)jit_rx_base + offset + deep);
                        uint32_t rw_mid = *(uint32_t *)((char *)jit_rw_base + offset + deep);
                        ERR("iOS JIT: dual-map RX[+0x%lx]=0x%08x  RW[+0x%lx]=0x%08x  match=%d\n",
                            (unsigned long)deep, rx_mid,
                            (unsigned long)deep, rw_mid, rx_mid == rw_mid);
                    }
                }
                {
                    /* Verify start, middle, and end words */
                    UINT64 *vmap = (UINT64 *)arm64ec_view->base;
                    size_t s_idx = ((size_t)jit_base) >> 12;
                    size_t e_idx = ((size_t)jit_base + image_size - 1) >> 12;
                    size_t m_idx = (s_idx + e_idx) / 2;
                    UINT64 sw = vmap[s_idx / 64], mw = vmap[m_idx / 64], ew = vmap[e_idx / 64];
                    ERR("iOS JIT: set_arm64ec_range(jit %p+0x%lx) hybrid bm=%p+0x%lx | start_pos=0x%lx word=0x%llx bit%d=%d | mid_pos=0x%lx word=0x%llx bit%d=%d | end_pos=0x%lx word=0x%llx bit%d=%d\n",
                        jit_base, (unsigned long)image_size, bm_page, (unsigned long)bm_size,
                        (unsigned long)(s_idx/64), (unsigned long long)sw, (int)(s_idx&63), (int)((sw>>(s_idx&63))&1),
                        (unsigned long)(m_idx/64), (unsigned long long)mw, (int)(m_idx&63), (int)((mw>>(m_idx&63))&1),
                        (unsigned long)(e_idx/64), (unsigned long long)ew, (int)(e_idx&63), (int)((ew>>(e_idx&63))&1));
                }
            }
            else
            {
                ERR("iOS JIT: NOT marking jit %p+0x%lx as EC (no .hexpthk section, pure x86_64)\n",
                    (char *)jit_rx_base + offset, (unsigned long)image_size);
            }

            /* Make data sections in JIT pool writable by remapping from RW view.
             * Parse PE section headers to find non-executable sections. */
            {
                unsigned int pe_off = *(unsigned int *)((char *)jit_rw_base + offset + 0x3C);
                unsigned short num_sections = *(unsigned short *)((char *)jit_rw_base + offset + pe_off + 6);
                unsigned short opt_hdr_size = *(unsigned short *)((char *)jit_rw_base + offset + pe_off + 0x14);
                char *section_hdr = (char *)jit_rw_base + offset + pe_off + 0x18 + opt_hdr_size;

                ERR("iOS JIT:   PE sections: %d, opt_hdr_size=0x%x\n", num_sections, opt_hdr_size);
                for (i = 0; i < num_sections; i++, section_hdr += 40)
                {
                    unsigned int sec_chars = *(unsigned int *)(section_hdr + 36);
                    unsigned int sec_rva = *(unsigned int *)(section_hdr + 12);
                    unsigned int sec_vsize = *(unsigned int *)(section_hdr + 8);

                    ERR("iOS JIT:   [%d] %.8s RVA=0x%x sz=0x%x chars=0x%x\n",
                        i, section_hdr, sec_rva, sec_vsize, sec_chars);

                    /* Track executable (.text) section for IAT sync protection */
                    if (sec_chars & 0x20000000)  /* IMAGE_SCN_MEM_EXECUTE */
                    {
                        ios_jit_set_text_section(image_base, sec_rva, sec_vsize);
                        ERR("iOS JIT:   recorded .text: offset=0x%x size=0x%x\n", sec_rva, sec_vsize);
                        continue;
                    }
                    if (!sec_vsize) continue;

                    /* Only writable sections (.data) need protection changes.
                     * Read-only sections (.rdata, .pdata, etc.) are fine as-is. */
                    if (sec_chars & 0x80000000)  /* IMAGE_SCN_MEM_WRITE */
                    {
                        /* ml140 TASK #34 ROOT CAUSE — THE ONE-PAGE .text KILLER.
                         *
                         * This rounded the writable section's start DOWN to a
                         * page boundary, so when a .data section begins partway
                         * into a page that also holds the TAIL OF .text, the
                         * mprotect below stripped EXECUTE from a page of live
                         * code. [copy-verify] caught it at birth in 7 modules at
                         * once — always exactly one page (two for chromehtml,
                         * where the 64KB round-down spans several 16KB pages),
                         * always at a 64KB-aligned offset, which is precisely
                         * what (sec_rva & ~(page_size-1)) produces.
                         *
                         * That is the whole of #34: the page is not reclaimed
                         * and not overwritten, it is mprotect'ed non-executable
                         * by US at copy time, and it only kills the process when
                         * execution finally reaches that part of .text — which
                         * is why CEF dies at libarm64ecfex+0xd06d0 while Thumper,
                         * which never calls those emitters, runs clean. It also
                         * explains max_prot=0x3: mprotect drops EXECUTE from
                         * max_protection on blessed memory permanently, so no
                         * later mprotect/read-touch could ever restore it.
                         *
                         * Round the writable range UP instead: never touch the
                         * page shared with preceding code. Writes landing in
                         * that shared page fall to the SIGBUS emulation path the
                         * failure branch below already relies on. */
                        /* ml141 REVERTED to the round-DOWN. Skipping the shared
                         * page (round-UP) removed every BORN NON-EXEC page, but
                         * traded an exec fault for an immediate STORE fault:
                         * steam.exe died after 61 unix calls with
                         *   BUS: unhandled store insn=0x880a7d09 (STXR)
                         * A .data write landing in the .text-shared page now hits
                         * a read-only page, and the SIGBUS store emulator does
                         * NOT cover store-exclusive — see
                         * reference_str_emulator_state.md. Losing the write is
                         * far worse than losing the exec: writes there are common
                         * and immediate, executing that .text tail is rare.
                         *
                         * The correct fix is to remove the SHARING, not to pick a
                         * loser: PE sections are 4KB-aligned while iOS pages are
                         * 16KB, so a .data section can always land mid-page on
                         * .text. Choose each image's pool offset so its first
                         * writable section starts on a 16KB boundary — everything
                         * before it is RX, so misaligning .text costs nothing. */
                        /* ml142: round the ABSOLUTE address, not the RVA. The
                         * ml141 data-align shift makes `offset` non-page-aligned
                         * (steamexe +0x2000, libarm64ecfex +0x3000), so
                         * base+offset+(rva & ~mask) is no longer page-aligned and
                         * mprotect rejects it — .data stayed read-only and the
                         * first STXR killed the process at 68 unix calls. With
                         * the shift in place .data IS absolutely page-aligned, so
                         * rounding the absolute address is exact: target lands on
                         * .data's first byte and no .text page is ever included. */
                        uintptr_t sec_abs = (uintptr_t)((char *)jit_rx_base + offset + sec_rva);
                        uintptr_t sec_abs_end = (sec_abs + sec_vsize + page_size - 1) & ~(page_size - 1);
                        void *target = (void *)(sec_abs & ~(uintptr_t)(page_size - 1));
                        size_t sec_page_size = sec_abs_end - (uintptr_t)target;

                        /* Try mprotect to make data section writable (drops execute) */
                        if (mprotect(target, sec_page_size, PROT_READ | PROT_WRITE) == 0)
                        {
                            ERR("iOS JIT:     → mprotect RW at %p (0x%lx bytes) OK\n",
                                target, (unsigned long)sec_page_size);
                        }
                        else
                        {
                            ERR("iOS JIT:     → mprotect RW FAILED errno=%d (%s), writes handled via SIGBUS emulation\n",
                                errno, strerror(errno));
                        }
                    }
                }

                /* Apply DIR64 relocations to JIT pool copy.
                 * The unix-side mapping has UNRELOCATED data (still at PE ImageBase).
                 * Wine only relocates the NT-side (PE) view via map_image_into_view,
                 * but the unix-side view keeps original values.
                 * delta = jit_dest - PE_ImageBase */
                {
                    char *rw_image = (char *)jit_rw_base + offset;
                    uint64_t pe_image_base = *(uint64_t *)(rw_image + pe_off + 0x30);
                    intptr_t delta = (intptr_t)((char *)jit_rx_base + offset) - (intptr_t)pe_image_base;

                    ERR("iOS JIT:   PE ImageBase=0x%llx, unix_base=%p, jit_dest=%p, delta=0x%lx\n",
                        (unsigned long long)pe_image_base, image_base, (char *)jit_rx_base + offset, (long)delta);

                    unsigned int reloc_rva = *(unsigned int *)(rw_image + pe_off + 0xB0);
                    unsigned int reloc_sz  = *(unsigned int *)(rw_image + pe_off + 0xB4);

                    if (reloc_rva && reloc_sz && delta)
                    {
                        char *reloc_data = rw_image + reloc_rva;
                        char *block = reloc_data;
                        int fixup_count = 0;

                        ERR("iOS JIT:   relocations: RVA=0x%x size=0x%x delta=0x%lx\n",
                            reloc_rva, reloc_sz, (long)delta);

                        while (block < reloc_data + reloc_sz)
                        {
                            unsigned int block_rva  = *(unsigned int *)block;
                            unsigned int block_size = *(unsigned int *)(block + 4);
                            int j, num_entries;
                            unsigned short *entries;

                            if (!block_size || block_size < 8) break;

                            num_entries = (block_size - 8) / 2;
                            entries = (unsigned short *)(block + 8);

                            for (j = 0; j < num_entries; j++)
                            {
                                int type = entries[j] >> 12;
                                int off  = entries[j] & 0xFFF;

                                if (type == 0) continue;

                                if (type == 10)  /* IMAGE_REL_BASED_DIR64 */
                                {
                                    uint64_t *fixup = (uint64_t *)(rw_image + block_rva + off);
                                    uint64_t val = *fixup;
                                    if (val >= pe_image_base && val < pe_image_base + image_size)
                                    {
                                        *fixup += delta;
                                        fixup_count++;
                                    }
                                    else
                                    {
                                        /* Log first few skipped entries */
                                        static int skip_log = 0;
                                        if (skip_log < 5)
                                        {
                                            ERR("iOS JIT:   SKIP reloc at RVA 0x%x: val=0x%llx (outside image 0x%llx-0x%llx)\n",
                                                block_rva + off, (unsigned long long)val,
                                                (unsigned long long)pe_image_base,
                                                (unsigned long long)(pe_image_base + image_size));
                                            skip_log++;
                                        }
                                    }
                                }
                            }

                            block += block_size;
                        }

                        __asm__ __volatile__("dsb sy" ::: "memory");
                        sys_icache_invalidate((char *)jit_rx_base + offset, image_size);

                        ERR("iOS JIT:   applied %d DIR64 fixups (delta=0x%lx)\n",
                            fixup_count, (long)delta);
                    }

                    /* Store relocation info for later IAT sync re-application */
                    ios_jit_set_reloc_info(image_base, pe_image_base, delta,
                                          reloc_rva, reloc_sz);

                    /* Debug: show syscall_dispatcher value after relocation */
                    if (image_size > 0x64a70)
                    {
                        uint64_t rw_val = *(uint64_t *)(rw_image + 0x64a68);
                        ERR("iOS JIT:   syscall_dispatcher ptr relocated to 0x%llx\n",
                            (unsigned long long)rw_val);
                    }
                }

                /* Patch x18 references in .text → TPIDR_EL0 trampolines.
                 * Allocate trampoline space right after the PE image in the JIT pool.
                 *
                 * SKIP x18 patching for pure x86_64 PEs only.
                 * ARM64EC PEs report Machine=AMD64 (0x8664) in their header but their
                 * .text holds real ARM64 code that DOES need x18 patching. Detect
                 * ARM64EC by presence of a `.a64xrm` (ARM64EC reloc range map) section. */
                {
                    char *rw_image = (char *)jit_rw_base + offset;
                    USHORT pe_machine = *(USHORT *)(rw_image + pe_off + 4);
                    int is_arm64ec_pe = 0;
                    if (pe_machine != IMAGE_FILE_MACHINE_ARM64)
                    {
                        /* Walk section headers looking for .a64xrm */
                        unsigned short num_sec  = *(unsigned short *)(rw_image + pe_off + 6);
                        unsigned short opt_size = *(unsigned short *)(rw_image + pe_off + 0x14);
                        char *sh = rw_image + pe_off + 0x18 + opt_size;
                        for (int s = 0; s < num_sec; s++, sh += 40)
                        {
                            if (!memcmp(sh, ".a64xrm", 7)) { is_arm64ec_pe = 1; break; }
                        }
                    }
                    if (pe_machine != IMAGE_FILE_MACHINE_ARM64 && !is_arm64ec_pe)
                    {
                        ERR("iOS JIT: skipping x18 patcher for non-ARM64 PE (Machine=0x%x)\n",
                            pe_machine);
                        goto x18_patch_done;
                    }
                    if (is_arm64ec_pe)
                        ERR("iOS JIT: x18-patching ARM64EC PE (Machine=0x%x has .a64xrm)\n",
                            pe_machine);
                }
                {
                    /* Find .text section info from mapping table */
                    int map_idx;
                    size_t text_off = 0, text_sz = 0;
                    for (map_idx = 0; map_idx < ios_jit_mapping_count; map_idx++)
                    {
                        if (ios_jit_mappings[map_idx].pe_base == image_base)
                        {
                            text_off = ios_jit_mappings[map_idx].text_offset;
                            text_sz = ios_jit_mappings[map_idx].text_size;
                            break;
                        }
                    }
                    if (text_sz > 0)
                    {
                        /* Task #25: exact budget (was 100% of .text, ~99% wasted). */
                        extern size_t ios_jit_x18_tramp_need( const char *text, size_t text_size );
                        size_t tramp_budget = ios_jit_x18_tramp_need((char *)jit_rw_base + offset + text_off, text_sz);
                        size_t tramp_alloc = (tramp_budget + page_size - 1) & ~(page_size - 1);
                        /* task #34: fixed image-relative offset — the region
                         * pre-reserved in this image's own allocation. The
                         * pre-scan ran on the SOURCE image (identical bytes),
                         * so the budgets must agree; a mismatch means the
                         * copy diverged from the source and patching it
                         * would emit copy-specific branches — refuse (x18
                         * insns degrade to recoverable runtime faults). */
                        size_t tramp_pool_off = offset + image_alloc;
                        if (tramp_alloc > tramp_prealloc)
                        {
                            dprintf(2, "[x18-tramp] REFUSED: budget 0x%lx > prealloc 0x%lx (source/copy divergence?)\n",
                                    (unsigned long)tramp_alloc, (unsigned long)tramp_prealloc);
                            tramp_pool_off = (size_t)-1;
                        }
                        if (!tramp_alloc) tramp_pool_off = (size_t)-1;  /* no x18 refs — nothing to patch */

                        if (tramp_pool_off != (size_t)-1)
                        {
                            char *tramp_rw = (char *)jit_rw_base + tramp_pool_off;
                            char *tramp_rx = (char *)jit_rx_base + tramp_pool_off;
                            char *text_rw = (char *)jit_rw_base + offset + text_off;
                            char *text_rx = (char *)jit_rx_base + offset + text_off;

                            int patched = ios_jit_patch_x18(text_rw, text_rx, text_sz,
                                                            tramp_rw, tramp_rx, tramp_alloc);

                            if (patched > 0)
                            {
                                sys_icache_invalidate(text_rx, text_sz);
                                sys_icache_invalidate(tramp_rx, tramp_alloc);
                            }
                        }
                        else
                        {
                            ERR("iOS JIT: no space for x18 trampolines (need 0x%lx at 0x%lx)\n",
                                (unsigned long)tramp_alloc, (unsigned long)tramp_pool_off);
                        }
                    }
                }
                x18_patch_done: ;
            }

            /* Leave original code section as read-only */
            mprotect( base, size, PROT_READ );
            return 0;
        }
    }
#endif

    return mprotect( base, size, unix_prot );
}


#ifdef WINE_IOS
/***********************************************************************
 * S1 pseudo-processes: per-child ntdll copy.
 *
 * Child "processes" are thread groups in the same Mach task. All modules
 * except ntdll duplicate naturally (the child's loader maps them at fresh
 * VAs → mprotect_exec makes fresh pool copies). ntdll is special: it is
 * pre-mapped once by the unix side at a shared VA, and its .data holds
 * per-process loader state (module list, loader lock, hash table). A child
 * sharing the parent's ntdll .data corrupts both module lists — so each
 * child gets its own pool copy of the whole ntdll image, registered as an
 * owner_peb-tagged mapping entry. Translation picks the copy owned by the
 * current thread's process (see ios_jit_translate_addr_for_owner).
 *
 * The copy source is the LIVE unix-side view: file-state .data (PE-side
 * runtime writes go to the pool copies, never here) plus the handful of
 * unix-written runtime slots we WANT to inherit (syscall/unix-call
 * dispatchers, unixlib handle, xlate hooks — all unix .text addresses that
 * the reloc range-check leaves untouched). Slots holding PARENT-POOL
 * aliases (e.g. the Round-7 EC unix-call thunk) are rebased to the child
 * copy by the pool-pointer sweep below.
 */

/* Mark ARM64EC CodeMap ranges for a child copy (mirror of the parent path
 * in mprotect_exec, kept separate so the proven parent code is untouched).
 * No-op for non-hybrid images (no .hexpthk section). */
static void ios_jit_mark_ec_ranges_for_copy(char *rw_image, char *jit_base, size_t image_size)
{
    unsigned int pe_off = *(unsigned int *)(rw_image + 0x3C);
    unsigned short num_sec = *(unsigned short *)(rw_image + pe_off + 6);
    unsigned short opt_sz = *(unsigned short *)(rw_image + pe_off + 0x14);
    char *sec = rw_image + pe_off + 0x18 + opt_sz;
    int is_hybrid = 0, s;

    for (s = 0; s < num_sec; s++, sec += 40)
        if (!memcmp(sec, ".hexpthk", 8)) { is_hybrid = 1; break; }
    if (!is_hybrid || !arm64ec_view) return;

    {
        size_t bm_start = ((size_t)jit_base >> 12) / 8;
        size_t bm_end   = (((size_t)jit_base + image_size) >> 12) / 8;
        size_t bm_size  = ROUND_SIZE(bm_start, bm_end + 1 - bm_start, page_mask);
        void *bm_page   = ROUND_ADDR((char *)arm64ec_view->base + bm_start, page_mask);
        set_vprot(arm64ec_view, bm_page, bm_size, VPROT_READ | VPROT_WRITE | VPROT_COMMITTED);
    }
    {
        char *opt_hdr = rw_image + pe_off + 0x18;
        unsigned int load_cfg_rva = *(unsigned int *)(opt_hdr + 0x70 + 10*8);
        unsigned int load_cfg_size = *(unsigned int *)(opt_hdr + 0x70 + 10*8 + 4);
        uint64_t pe_image_base = *(uint64_t *)(opt_hdr + 0x18);
        int found_codemap = 0;

        if (load_cfg_rva && load_cfg_size > 0xD0)
        {
            uint64_t chpe_meta_va = *(uint64_t *)(rw_image + load_cfg_rva + 0xC8);
            uint64_t meta_rva = (uint64_t)-1;
            /* This runs AFTER the child DIR64 pass, which rebases the
             * CHPEMetadataPointer slot from the header ImageBase to the
             * child's pool copy (jit_base). Accept either form — a failed
             * lookup falls back to flat-marking the whole image as EC,
             * which makes arm64x_check_call treat the raw x64 syscall
             * stubs as ARM and BR into them (X1 child ILL storm). */
            if (chpe_meta_va >= pe_image_base && chpe_meta_va < pe_image_base + image_size)
                meta_rva = chpe_meta_va - pe_image_base;
            else if (chpe_meta_va >= (uint64_t)(uintptr_t)jit_base &&
                     chpe_meta_va <  (uint64_t)(uintptr_t)jit_base + image_size)
                meta_rva = chpe_meta_va - (uint64_t)(uintptr_t)jit_base;
            if (meta_rva != (uint64_t)-1)
            {
                char *meta = rw_image + meta_rva;
                unsigned int code_map_rva = *(unsigned int *)(meta + 0x4);
                unsigned int code_map_count = *(unsigned int *)(meta + 0x8);
                if (code_map_rva && code_map_count)
                {
                    char *code_map = rw_image + code_map_rva;
                    unsigned int k, ec_marked = 0;
                    for (k = 0; k < code_map_count; k++)
                    {
                        unsigned int start = *(unsigned int *)(code_map + k*8);
                        unsigned int len   = *(unsigned int *)(code_map + k*8 + 4);
                        if ((start & 0x3) == 1)  /* ARM64EC range */
                        {
                            set_arm64ec_range(jit_base + (start & ~0x3u), len);
                            ec_marked++;
                        }
                    }
                    found_codemap = 1 + (int)ec_marked;
                }
            }
        }
        if (!found_codemap) set_arm64ec_range(jit_base, image_size);
        dprintf(2, "[child-ntdll] EC ranges marked for copy at %p (codemap=%d ec_ranges=%d)\n",
                jit_base, !!found_codemap, found_codemap ? found_codemap - 1 : 0);
    }
}

/* Copy the module containing `module_addr` into a fresh pool slot owned by
 * `child_peb`. Returns 0 on success. Idempotent per (module, child). */
int ios_jit_copy_module_for_child(void *module_addr, void *child_peb)
{
    const size_t pg = 0x4000;
    struct ios_jit_mapping *m = NULL;
    size_t alloc_size, offset;
    size_t child_tramp_prealloc = 0;
    char *rw_dest, *rx_dest, *src;
    uint64_t pe_image_base;
    intptr_t child_delta;
    unsigned int pe_off;
    int i;

    for (i = 0; i < ios_jit_mapping_count; i++)
    {
        uintptr_t base = (uintptr_t)ios_jit_mappings[i].pe_base;
        if ((uintptr_t)module_addr >= base && (uintptr_t)module_addr < base + ios_jit_mappings[i].size)
        {
            if (ios_jit_mappings[i].owner_peb == child_peb) return 0;  /* already copied */
            if (!ios_jit_mappings[i].owner_peb) m = &ios_jit_mappings[i];
        }
    }
    if (!m || !ios_jit_rw_base_global)
    {
        dprintf(2, "[child-ntdll] no parent mapping found for %p\n", module_addr);
        return -1;
    }
    if (ios_jit_mapping_count >= IOS_JIT_MAX_MAPPINGS)
    {
        /* Full count is fine as long as reclamation left a tombstone the
         * append below can reuse. */
        int free_slot = 0;
        for (i = 0; i < ios_jit_mapping_count; i++)
            if (!ios_jit_mappings[i].pe_base) { free_slot = 1; break; }
        if (!free_slot)
        {
            dprintf(2, "[child-ntdll] mapping table FULL — cannot register child copy\n");
            return -1;
        }
    }

    alloc_size = (m->size + pg - 1) & ~(pg - 1);
    /* task #34: reserve the x18 trampoline region inside this allocation at
     * a fixed image-relative offset (mirrors the parent path — see the
     * mprotect_exec copy pipeline). Budget from the SOURCE bytes; identical
     * to what the post-memcpy scan would compute. */
    {
        extern size_t ios_jit_x18_tramp_need( const char *text, size_t text_size );
        child_tramp_prealloc = m->text_size
            ? ((ios_jit_x18_tramp_need((const char *)m->pe_base + m->text_offset, m->text_size) + pg - 1) & ~(pg - 1))
            : 0;
    }
    alloc_size += child_tramp_prealloc;
    {
        size_t data_delta = ios_jit_data_align_delta(m->pe_base, m->size);
        if (data_delta) alloc_size += pg;
        offset = ios_pool_alloc_range(alloc_size, ios_jit_pool_size_global - ios_jit_tail_reserved);
        if (offset != (size_t)-1 && data_delta) offset += data_delta;
    }
    if (offset == (size_t)-1)
    {
        dprintf(2, "[child-ntdll] JIT pool exhausted (need 0x%lx, bump=0x%lx of 0x%lx, tail_resv=0x%lx, freelist=%d)\n",
                (unsigned long)alloc_size, (unsigned long)jit_pool_offset,
                (unsigned long)ios_jit_pool_size_global,
                (unsigned long)ios_jit_tail_reserved, ios_pool_free_count);
        return -1;
    }

    rw_dest = (char *)ios_jit_rw_base_global + offset;
    rx_dest = (char *)ios_jit_rx_base_global + offset;
    src = (char *)m->pe_base;

    memcpy(rw_dest, src, m->size);
    /* task #34: verify HERE, before relocations/x18 patching legitimately
     * diverge the copy from its source. This is the path that produces the
     * per-pseudo-process copies that keep dying (libarm64ecfex, rpcrt4). */
    sys_icache_invalidate(rx_dest, m->size);
    ios_jit_verify_copy( src, rx_dest, m->size,
                         ios_pe_module_name( src, m->size ),
                         offset, ios_pool_last_alloc_reused );

    pe_off = *(unsigned int *)(rw_dest + 0x3C);
    pe_image_base = m->pe_image_base ? m->pe_image_base
                                     : *(uint64_t *)(rw_dest + pe_off + 0x30);
    child_delta = (intptr_t)rx_dest - (intptr_t)pe_image_base;

    /* Writable sections → RW on the RX view (mirrors parent path; a failed
     * mprotect falls back to the STR fault emulator, just slower). */
    {
        unsigned short num_sec = *(unsigned short *)(rw_dest + pe_off + 6);
        unsigned short opt_sz = *(unsigned short *)(rw_dest + pe_off + 0x14);
        char *sec = rw_dest + pe_off + 0x18 + opt_sz;
        int s;
        for (s = 0; s < num_sec; s++, sec += 40)
        {
            unsigned int chars = *(unsigned int *)(sec + 36);
            unsigned int rva = *(unsigned int *)(sec + 12);
            unsigned int vsz = *(unsigned int *)(sec + 8);
            if ((chars & 0x80000000) && vsz)  /* IMAGE_SCN_MEM_WRITE */
            {
                size_t p_off = rva & ~(pg - 1);
                size_t p_sz = ((rva + vsz + pg - 1) & ~(pg - 1)) - p_off;
                if (mprotect(rx_dest + p_off, p_sz, PROT_READ | PROT_WRITE) != 0)
                    dprintf(2, "[child-ntdll] mprotect RW failed for section RVA 0x%x (errno=%d)\n",
                            rva, errno);
            }
        }
    }

    /* DIR64 relocations with the child's delta. The unix view is
     * unrelocated (values at PE ImageBase); the range check preserves
     * runtime-written unix addresses (dispatchers, hooks). */
    if (m->reloc_rva && m->reloc_size)
    {
        char *reloc = rw_dest + m->reloc_rva;
        char *reloc_end = reloc + m->reloc_size;
        int fixups = 0;
        while (reloc < reloc_end)
        {
            unsigned int block_rva = *(unsigned int *)reloc;
            unsigned int block_size = *(unsigned int *)(reloc + 4);
            unsigned short *entries = (unsigned short *)(reloc + 8);
            int j, num;
            if (!block_size || block_size < 8) break;
            num = (block_size - 8) / 2;
            for (j = 0; j < num; j++)
            {
                if ((entries[j] >> 12) == 10)  /* IMAGE_REL_BASED_DIR64 */
                {
                    uint64_t *fixup = (uint64_t *)(rw_dest + block_rva + (entries[j] & 0xFFF));
                    if (*fixup >= pe_image_base && *fixup < pe_image_base + m->size)
                    {
                        *fixup += child_delta;
                        fixups++;
                    }
                }
            }
            reloc += block_size;
        }
        dprintf(2, "[child-ntdll] applied %d DIR64 fixups (delta=0x%lx)\n",
                fixups, (long)child_delta);
    }

    /* Pool-pointer sweep: unix-side code wrote a few slots with PARENT-POOL
     * aliases (e.g. the EC unix-call thunk, Round 7). Those are wrong for
     * the child — rebase any 8-aligned value inside the parent's pool copy
     * of THIS module to the child copy. The unix view only ever receives
     * unix-side writes, so matches are genuine. */
    {
        uintptr_t pj = (uintptr_t)m->jit_base;
        uint64_t *p = (uint64_t *)rw_dest;
        uint64_t *end = (uint64_t *)(rw_dest + (m->size & ~(size_t)7));
        int swept = 0;
        for (; p < end; p++)
        {
            if (*p >= pj && *p < pj + m->size)
            {
                uint64_t nv = (uintptr_t)rx_dest + (*p - pj);
                dprintf(2, "[child-ntdll]   pool-ptr rebase @+0x%lx: 0x%llx -> 0x%llx\n",
                        (unsigned long)((char *)p - rw_dest),
                        (unsigned long long)*p, (unsigned long long)nv);
                *p = nv;
                swept++;
            }
        }
        dprintf(2, "[child-ntdll] pool-pointer sweep: %d slot(s) rebased\n", swept);
    }

    /* x18-patch the child's .text with its own trampolines (fresh from the
     * unix view — the parent's patches live only in the parent's copy). */
    if (m->text_size && child_tramp_prealloc)
    {
        /* task #34: trampolines live in the fixed image-relative region
         * pre-reserved above — same offset in every copy, so patched .text
         * and tramps are byte-identical across copies (page-shareable). */
        size_t tramp_off = offset + (alloc_size - child_tramp_prealloc);
        int patched = ios_jit_patch_x18(
            rw_dest + m->text_offset, rx_dest + m->text_offset, m->text_size,
            (char *)ios_jit_rw_base_global + tramp_off,
            (char *)ios_jit_rx_base_global + tramp_off, child_tramp_prealloc);
        sys_icache_invalidate((char *)ios_jit_rx_base_global + tramp_off, child_tramp_prealloc);
        dprintf(2, "[child-ntdll] x18-patched %d instructions (tramps at image-relative +0x%lx)\n",
                patched, (unsigned long)(alloc_size - child_tramp_prealloc));
    }

    ios_jit_mark_ec_ranges_for_copy(rw_dest, rx_dest, m->size);

    __asm__ __volatile__("dsb sy" ::: "memory");
    sys_icache_invalidate(rx_dest, m->size);

    ios_jit_verify_text_exec( ios_pe_module_name( m->pe_base, m->size ), rx_dest, m->size );

    /* Register: APPEND an owned entry — the parent's entry stays intact.
     * Task #25: reuse a tombstoned slot when one exists; pe_base written
     * last (readers' match key) behind a barrier. */
    {
        int slot = -1, si;
        for (si = 0; si < ios_jit_mapping_count; si++)
            if (!ios_jit_mappings[si].pe_base) { slot = si; break; }
        if (slot < 0) slot = ios_jit_mapping_count;
        ios_jit_mappings[slot].jit_base = rx_dest;
        ios_jit_mappings[slot].size = m->size;
        ios_jit_mappings[slot].text_offset = m->text_offset;
        ios_jit_mappings[slot].text_size = m->text_size;
        ios_jit_mappings[slot].pe_image_base = pe_image_base;
        ios_jit_mappings[slot].reloc_delta = child_delta;
        ios_jit_mappings[slot].reloc_rva = m->reloc_rva;
        ios_jit_mappings[slot].reloc_size = m->reloc_size;
        ios_jit_mappings[slot].owner_peb = child_peb;
        __sync_synchronize();
        ios_jit_mappings[slot].pe_base = m->pe_base;
        if (slot == ios_jit_mapping_count) ios_jit_mapping_count++;
    }

    dprintf(2, "[child-ntdll] copied %p+0x%lx -> %p (pool+0x%lx) owner_peb=%p\n",
            m->pe_base, (unsigned long)m->size, rx_dest, (unsigned long)offset, child_peb);
    return 0;
}
#endif  /* WINE_IOS */


/***********************************************************************
 *           mprotect_range
 *
 * Call mprotect on a page range, applying the protections from the per-page byte.
 */
static int mprotect_range( void *base, size_t size, BYTE set, BYTE clear )
{
    size_t i, count;
    char *addr = ROUND_ADDR( base, host_page_mask );
    int prot, next;
    BYTE vprot;

    size = ROUND_SIZE( base, size, host_page_mask );

    vprot = get_host_page_vprot( addr );
    prot = get_unix_prot( (vprot & ~clear) | set );
    for (count = i = 1; i < size / host_page_size; i++, count++)
    {
        vprot = get_host_page_vprot( addr + count * host_page_size );
        next = get_unix_prot( (vprot & ~clear) | set );
        if (next == prot) continue;
        if (mprotect_exec( addr, count * host_page_size, prot )) return -1;
        addr += count * host_page_size;
        prot = next;
        count = 0;
    }
    return mprotect_exec( addr, count * host_page_size, prot );
}


/***********************************************************************
 *           set_vprot
 *
 * Change the protection of a range of pages.
 */
static BOOL set_vprot( struct file_view *view, void *base, size_t size, BYTE vprot )
{
    if (!use_kernel_writewatch && view->protect & VPROT_WRITEWATCH)
    {
        /* each page may need different protections depending on write watch flag */
        set_page_vprot_bits( base, size, vprot & ~VPROT_WRITEWATCH, ~vprot & ~VPROT_WRITEWATCH );
    }
    else
    {
        if (enable_write_exceptions && is_vprot_exec_write( vprot )) vprot |= VPROT_WRITEWATCH;
        else if (use_kernel_writewatch && view->protect & VPROT_WRITEWATCH) vprot &= ~VPROT_WRITEWATCH;
        set_page_vprot( base, size, vprot );
    }
    return !mprotect_range( base, size, 0, 0 );
}


/* iOS-Madeira ml293 (task #52): the PartitionAlloc-arena band. Steered arenas are placed
 * top-down at/above 0x7c00000000 and no guest PE image is ever mapped >= 0x7400000000
 * (verified across 13 runs: every [jit-pool] image base is 0x71-0x73), so this test is
 * unambiguous and needs no bounds table. */
static inline int ios_is_arena_addr( const void *p )
{
    return (uintptr_t)p >= 0x7400000000ULL;
}

/* Offset of the first non-zero byte in [p, p+n), or -1 if all zero. Exists so the
 * zero-contract probes VERIFY BY READING MEMORY BACK rather than trusting that a
 * memset/mmap-over was issued -- on iOS those can silently not do what was asked
 * (PROT_WRITE downgrade), which is exactly the class of bug being hunted. */
static long ios_first_nonzero( const void *p, size_t n )
{
    const unsigned char *b = (const unsigned char *)p;
    size_t i;
    for (i = 0; i < n; i++) if (b[i]) return (long)i;
    return -1;
}


/***********************************************************************
 *           set_protection
 *
 * Set page protections on a range of pages
 */
static NTSTATUS set_protection( struct file_view *view, void *base, SIZE_T size, ULONG protect )
{
    unsigned int vprot;
    NTSTATUS status;

    if ((status = get_vprot_flags( protect, &vprot, view->protect & SEC_IMAGE ))) return status;
    if (is_view_valloc( view ))
    {
        if (vprot & VPROT_WRITECOPY) return STATUS_INVALID_PAGE_PROTECTION;
    }
    else
    {
        BYTE access = vprot & (VPROT_READ | VPROT_WRITE | VPROT_EXEC);
        if ((view->protect & access) != access) return STATUS_INVALID_PAGE_PROTECTION;
    }

    if (!set_vprot( view, base, size, vprot | VPROT_COMMITTED ))
    {
        dprintf(2, "[vmem-denied] set_vprot failed: base=%p size=%p protect=0x%x\n",
                base, (void *)size, (unsigned)protect);
        return STATUS_ACCESS_DENIED;
    }

    /* iOS-Madeira ml638 A/B: NEVER MAKE AN ANON-JIT-ALIASED PAGE PHYSICALLY WRITABLE.
     *
     * The ULTRAKILL alias [0x705bc80000,0x705bc90000) starts COHERENT — an emulated
     * store at +0x1368 read back identically through RX and RW. By the crash the two
     * views hold DIFFERENT Mono methods around +0x337d, and the only events in between
     * are four NtProtectVirtualMemory transitions over the first 16KB — the same chunk
     * that holds all 792 tracked writes and the divergence.
     *
     * Making the guest VA physically writable lets the kernel privatise / COW-split it
     * from the pool RW alias: later guest writes land in the private copy while FEX
     * translates and executes the ORIGINAL pool pages, which still hold the old bytes
     * and zeros beyond. FEX then runs off the end of the buffer — the deterministic
     * one-past-the-end c0000005 we keep hitting.
     *
     * So: keep Wine's LOGICAL protection exactly as the guest asked (set_vprot above
     * already recorded it, so NtQueryVirtualMemory still answers correctly), but
     * re-assert the PHYSICAL protection as R+X. Every guest write then keeps faulting
     * into the alias store emulator and routing to the RW view, which is the design.
     * Decommit / release / no-access are untouched — this only refuses to hand out
     * physical write permission on memory a JIT alias owns.
     *
     * ⛔ If this fixes it, the durable form is to stop this page from ever being
     * physically writable in the first place, not to re-protect after the fact. */
    if ((vprot & VPROT_WRITE) && !(vprot & VPROT_GUARD))
    {
        uintptr_t ov_b = 0, ov_e = 0;
        extern int ios_jit_anon_alias_overlaps(void *, size_t, uintptr_t *, uintptr_t *);
        if (ios_jit_anon_alias_overlaps( base, size, &ov_b, &ov_e ))
        {
            int keep_exec = (vprot & VPROT_EXEC) || 1;   /* alias pages are executable by construction */
            int pr = PROT_READ | (keep_exec ? PROT_EXEC : 0);
            int rc = mprotect( base, size, pr );
            static int ab_n;
            if (ab_n < 24)
                dprintf(2, "[alias-prot] ml638 #%d %p+0x%lx requested prot=0x%x (vprot=0x%x) — logical kept, "
                           "PHYSICAL forced R%s (mprotect rc=%d) alias=[%p,%p)\n",
                        ++ab_n, base, (unsigned long)size, (unsigned)protect, vprot,
                        keep_exec ? "X" : "", rc, (void *)ov_b, (void *)ov_e);
        }
    }

    return STATUS_SUCCESS;
}


/***********************************************************************
 *           ios_verify_commit_zero      (iOS-Madeira ml293, task #52)
 *
 * The OTHER HALF of the decommit zero contract.
 *
 * [decommit-zero] proves the decommit side zeroed. That alone is not sufficient:
 * PartitionAlloc reads its BackupRefPtr refcount out of freshly RECOMMITTED metadata, so a
 * commit that hands back stale bytes fails identically even when every decommit was perfect.
 * Windows guarantees MEM_COMMIT yields zero-filled pages; verify we do too. Together the two
 * probes localise any break to one side or the other.
 *
 * Deliberately NOT placed inside set_protection: that function serves both MEM_COMMIT and
 * plain NtProtectVirtualMemory, so protect traffic would consume the report cap and starve
 * the commit signal -- a probe whose cap is spent on the case it is not measuring reports
 * nothing useful. Called only from the commit branches instead.
 *
 * Reads memory back rather than echoing intent, and only when the protection actually permits
 * reading, so the probe can never itself fault.
 */
static void ios_verify_commit_zero( const void *base, SIZE_T size, ULONG protect, int was_committed )
{
    /* ml544: PER-BAND budgets, and cover the GUEST band too.
     *
     * As written this probe could not see the memory the render hunt cares about,
     * for two independent reasons:
     *   1. `ios_is_arena_addr` is (p >= 0x7400000000), so the GUEST band is excluded
     *      outright — and CEF's render bitmap lives there (ml538 SRC bits were at
     *      0x7042ba0000).
     *   2. Even inside the covered range, all 40 reports in ml543 were spent on
     *      0x7c... FEX-band commits before any pool commit was sampled. That is
     *      exactly the starvation this probe's own comment warns about, happening
     *      to it anyway.
     * ⇒ its "0 STALE ON COMMIT" said nothing about tile memory.
     *
     * Why it matters: tile (0,1) of the login window holds blurred game-library
     * pixels from the SPLASH screen, surviving into a later page. Stale bytes in
     * RECOMMITTED memory would produce exactly that, and Windows guarantees
     * MEM_COMMIT yields zero-filled pages.
     *
     * Separate counters so a chatty band can never starve a quiet one. */
    /* ml545: CENSUS, not a capped sample.
     *
     * ml544 capped each band at 40 reports and the budget was exhausted during
     * WINE BOOT (last guest sample at log line 2384, all of them 0x7038.. thread
     * stacks) while the webhelper spawned at 4838 and the first CEF render was at
     * 15575 -- the ENTIRE CEF phase went unsampled, so "0 stale" said nothing about
     * tile memory. That is the third time a cap has defeated this probe, once after
     * I had already "fixed" it.
     *
     * Use the pattern that demonstrably works here (the [unaligned-guest] census,
     * whose emu=16 simd=0 other=0 IS trustworthy): counters are UNBOUNDED, every
     * anomaly is logged, only the uninteresting OK lines are rate-limited, and
     * every line carries the running totals -- so a silent log can never be
     * mistaken for a clean one. */
    static unsigned long ck_hi, ck_lo, stale_hi, stale_lo, recommit_n;
    unsigned long seq;
    int hi;

    if (!base || !size) return;
    if (protect & (PAGE_NOACCESS | PAGE_GUARD)) return;
    if (!(protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                     PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return;

    /* ml546 defect #1: only a FRESH commit (reserved/decommitted -> committed) is
     * required to read back as zero. Re-committing memory that is ALREADY committed
     * -- which is what a protection change looks like from here -- correctly PRESERVES
     * contents, so flagging it is a false positive. ml545 reported 3 such events at
     * one base with protect alternating 0x2/0x4/0x2, and I nearly read them as
     * violations. Count them separately instead of reporting them as stale. */
    if (was_committed) { ++recommit_n; return; }

    hi = ios_is_arena_addr( base );
    seq = hi ? ++ck_hi : ++ck_lo;
    {
        size_t chk = size < 64 ? (size_t)size : 64;
        long nz = ios_first_nonzero( base, chk );
        if (nz < 0)
        {
            /* boring: first few, then sparse -- but the totals ride along */
            if (seq <= 8 || (seq % 4096) == 0)
                dprintf( 2, "[commit-zero] #%lu %s OK base=%p size=0x%lx protect=0x%x "
                         "(zero) checked=%lu/%lu stale=%lu/%lu recommit=%lu rev=ml546\n",
                         seq, hi ? "arena/pool" : "GUEST",
                         base, (unsigned long)size, (unsigned)protect,
                         ck_lo, ck_hi, stale_lo, stale_hi, recommit_n );
        }
        else
        {
            /* ml546 defect #2: ml545 printed bytes[0..7] from BASE while reporting
             * first_nonzero=+0x8 -- so it printed eight zeros and told us nothing
             * about the actual stale content. Print from the offending offset. */
            const unsigned char *b = (const unsigned char *)base + nz;
            if (hi) stale_hi++; else stale_lo++;      /* ALWAYS logged: this is the signal */
            dprintf( 2, "[commit-zero] #%lu %s *** STALE ON COMMIT *** base=%p size=0x%lx "
                     "protect=0x%x first_nonzero=+0x%lx checked=%lu/%lu stale=%lu/%lu recommit=%lu "
                     "bytes@nz=%02x %02x %02x %02x %02x %02x %02x %02x rev=ml546\n",
                     seq, hi ? "arena/pool" : "GUEST",
                     base, (unsigned long)size, (unsigned)protect, (unsigned long)nz,
                     ck_lo, ck_hi, stale_lo, stale_hi, recommit_n,
                     b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7] );
        }
    }
}


/***********************************************************************
 *           commit_arm64ec_map
 *
 * Make sure that the pages corresponding to the address range of the view
 * are committed in the ARM64EC code map.
 */
static void commit_arm64ec_map( struct file_view *view )
{
    size_t start = ((size_t)view->base >> page_shift) / 8;
    size_t end = (((size_t)view->base + view->size) >> page_shift) / 8;
    size_t size = ROUND_SIZE( start, end + 1 - start, page_mask );
    void *base = ROUND_ADDR( (char *)arm64ec_view->base + start, page_mask );

    view->protect |= VPROT_ARM64EC;
    set_vprot( arm64ec_view, base, size, VPROT_READ | VPROT_WRITE | VPROT_COMMITTED );
    ERR("commit_arm64ec_map: view@%p+0x%lx → bitmap %p+0x%lx (start_byte=0x%lx)\n",
        view->base, (unsigned long)view->size, base, (unsigned long)size,
        (unsigned long)start);
}


/***********************************************************************
 *           update_write_watches
 */
static void update_write_watches( void *base, size_t size, size_t accessed_size )
{
    TRACE( "updating watch %p-%p-%p\n", base, (char *)base + accessed_size, (char *)base + size );
    /* clear write watch flag on accessed pages */
    set_page_vprot_bits( base, accessed_size, 0, VPROT_WRITEWATCH );
    /* restore page protections on the entire range */
    mprotect_range( base, size, 0, 0 );
}


/***********************************************************************
 *           reset_write_watches
 *
 * Reset write watches in a memory range.
 */
static void reset_write_watches( void *base, SIZE_T size )
{
    if (use_kernel_writewatch)
    {
        kernel_writewatch_reset( base, size );
        if (!enable_write_exceptions) return;
        if (!set_page_vprot_exec_write_protect( base, size )) return;
    }
    else set_page_vprot_bits( base, size, VPROT_WRITEWATCH, 0 );

    mprotect_range( base, size, 0, 0 );
}


/***********************************************************************
 *           unmap_extra_space
 *
 * Release the extra memory while keeping the range starting on the alignment boundary.
 */
static inline void *unmap_extra_space( void *ptr, size_t total_size, size_t wanted_size, size_t align_mask )
{
    if ((ULONG_PTR)ptr & align_mask)
    {
        size_t extra = align_mask + 1 - ((ULONG_PTR)ptr & align_mask);
        ios_pool_va_warn( "munmap", ptr, extra );
        munmap( ptr, extra );
        ptr = (char *)ptr + extra;
        total_size -= extra;
    }
    if (total_size > wanted_size)
        ios_pool_va_warn( "munmap", (char *)ptr + wanted_size, total_size - wanted_size );
        munmap( (char *)ptr + wanted_size, total_size - wanted_size );
    return ptr;
}


/***********************************************************************
 *           find_reserved_free_area_outside_preloader
 *
 * Find a free area inside a reserved area, skipping the preloader reserved range.
 * virtual_mutex must be held by caller.
 */
static void *find_reserved_free_area_outside_preloader( void *start, void *end, size_t size,
                                                        int top_down, size_t align_mask )
{
    void *ret;

    if (preload_reserve_end >= end)
    {
        if (preload_reserve_start <= start) return NULL;  /* no space in that area */
        if (preload_reserve_start < end) end = preload_reserve_start;
    }
    else if (preload_reserve_start <= start)
    {
        if (preload_reserve_end > start) start = preload_reserve_end;
    }
    else /* range is split in two by the preloader reservation, try both parts */
    {
        if (top_down)
        {
            ret = find_reserved_free_area( preload_reserve_end, end, size, top_down, align_mask );
            if (ret) return ret;
            end = preload_reserve_start;
        }
        else
        {
            ret = find_reserved_free_area( start, preload_reserve_start, size, top_down, align_mask );
            if (ret) return ret;
            start = preload_reserve_end;
        }
    }
    return find_reserved_free_area( start, end, size, top_down, align_mask );
}

/***********************************************************************
 *           map_reserved_area
 *
 * Try to map some space inside a reserved area.
 * virtual_mutex must be held by caller.
 */
static void *map_reserved_area_inner( void *limit_low, void *limit_high, size_t size, int top_down,
                                      int unix_prot, size_t align_mask );

/* iOS-Madeira ml520 timing wrapper — see map_reserved_area_inner. */
static void *map_reserved_area( void *limit_low, void *limit_high, size_t size, int top_down,
                                int unix_prot, size_t align_mask )
{
    struct timespec t0, t1;
    void *r;
    double ms;
    static unsigned long slow_n;

    clock_gettime( CLOCK_MONOTONIC, &t0 );
    r = map_reserved_area_inner( limit_low, limit_high, size, top_down, unix_prot, align_mask );
    clock_gettime( CLOCK_MONOTONIC, &t1 );
    ms = (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
    if (ms > 250.0)
    {
        unsigned long n = ++slow_n;
        if (n <= 64 || (n % 256) == 0)
            ERR( "[va-slow] #%lu map_reserved_area took %.0f ms  size=0x%llx align=0x%llx "
                 "top_down=%d -> %p rev=ml520\n", n, ms, (unsigned long long)size,
                 (unsigned long long)align_mask, top_down, r );
    }
    return r;
}

static void *map_reserved_area_inner( void *limit_low, void *limit_high, size_t size, int top_down,
                                      int unix_prot, size_t align_mask )
{
    void *ptr = NULL;
    struct reserved_area *area;
    /* iOS-Madeira ml520: time the aligned VA reservation.
     *
     * ml519's freeze detector measured a 53.9s whole-app stall (t+32.7 →
     * t+86.6, 90 threads) and the FIRST thing to resume was a NEW FEX
     * thread initialising ([TI-IC] decoder/passmanager). Each FEX thread
     * reserves 2x128MB rpmalloc spans, and this function scans for aligned
     * free space with virtual_mutex held, issuing kernel mapping calls as
     * it goes — each of which takes the task's vm_map lock. A long scan
     * therefore stalls EVERY thread that page-faults, which is
     * indistinguishable from "the task was suspended" to any in-process
     * observer (exactly what #67's accuser concluded).
     *
     * If one call here accounts for the tens of seconds, the freeze is
     * OURS and this names it. If every call is fast, the VM path is
     * exonerated and the debugger theory stands. Timing only — no
     * behaviour change. */

    if (top_down)
    {
        LIST_FOR_EACH_ENTRY_REV( area, &reserved_areas, struct reserved_area, entry )
        {
            void *start = area->base;
            void *end = (char *)start + area->size;

            if (start >= limit_high) continue;
            if (end <= limit_low) return NULL;
            if (start < limit_low) start = (void *)ROUND_SIZE( 0, limit_low, host_page_mask );
            if (end > limit_high) end = ROUND_ADDR( limit_high, host_page_mask );
            ptr = find_reserved_free_area_outside_preloader( start, end, size, top_down, align_mask );
            if (ptr) break;
        }
    }
    else
    {
        LIST_FOR_EACH_ENTRY( area, &reserved_areas, struct reserved_area, entry )
        {
            void *start = area->base;
            void *end = (char *)start + area->size;

            if (start >= limit_high) return NULL;
            if (end <= limit_low) continue;
            if (start < limit_low) start = (void *)ROUND_SIZE( 0, limit_low, host_page_mask );
            if (end > limit_high) end = ROUND_ADDR( limit_high, host_page_mask );
            ptr = find_reserved_free_area_outside_preloader( start, end, size, top_down, align_mask );
            if (ptr) break;
        }
    }
    if (ptr && anon_mmap_fixed( ptr, size, unix_prot, 0 ) != ptr) ptr = NULL;
    return ptr;
}

/***********************************************************************
 *           map_fixed_area
 *
 * Map a memory area at a fixed address.
 * virtual_mutex must be held by caller.
 */
static NTSTATUS map_fixed_area( void *base, size_t size, int unix_prot )
{
    struct reserved_area *area;
    NTSTATUS status;
    char *start = base, *end = (char *)base + ROUND_SIZE( 0, size, host_page_mask );

    if ((UINT_PTR)base & host_page_mask) return STATUS_CONFLICTING_ADDRESSES;
    if (find_view_range( base, size )) return STATUS_CONFLICTING_ADDRESSES;

    LIST_FOR_EACH_ENTRY( area, &reserved_areas, struct reserved_area, entry )
    {
        char *area_start = area->base;
        char *area_end = area_start + area->size;

        if (area_start >= end) break;
        if (area_end <= start) continue;
        if (area_start > start)
        {
            if (anon_mmap_tryfixed( start, area_start - start, unix_prot, 0 ) == MAP_FAILED) goto failed;
            start = area_start;
        }
        if (area_end >= end)
        {
            if (anon_mmap_fixed( start, end - start, unix_prot, 0 ) == MAP_FAILED) goto failed;
            return STATUS_SUCCESS;
        }
        if (anon_mmap_fixed( start, area_end - start, unix_prot, 0 ) == MAP_FAILED) goto failed;
        start = area_end;
    }

    if (anon_mmap_tryfixed( start, end - start, unix_prot, 0 ) == MAP_FAILED) goto failed;
    return STATUS_SUCCESS;

failed:
    if (errno == ENOMEM)
    {
        ERR( "out of memory for %p-%p\n", base, (char *)base + size );
        status = STATUS_NO_MEMORY;
    }
    else if (errno == EEXIST) status = STATUS_CONFLICTING_ADDRESSES;
    else
    {
        ERR( "mmap error %s for %p-%p, unix_prot %#x\n",
             strerror(errno), base, (char *)base + size, unix_prot );
        status = STATUS_INVALID_PARAMETER;
    }
    unmap_area( base, start - (char *)base );
    return status;
}

/***********************************************************************
 *           map_view
 *
 * Create a view and mmap the corresponding memory area.
 * virtual_mutex must be held by caller.
 */
static NTSTATUS map_view( struct file_view **view_ret, void *base, size_t size,
                          unsigned int alloc_type, unsigned int vprot,
                          ULONG_PTR limit_low, ULONG_PTR limit_high, size_t align_mask )
{
    int top_down = alloc_type & MEM_TOP_DOWN;
    void *ptr;
    int unix_prot = get_unix_prot( vprot );
    NTSTATUS status;

    if (!align_mask) align_mask = granularity_mask;
    assert( align_mask >= host_page_mask );

    if (alloc_type & MEM_REPLACE_PLACEHOLDER)
    {
        struct file_view *view;

        if (!(view = find_view( base, 0 ))) return STATUS_INVALID_PARAMETER;
        if (view->base != base || view->size != size) return STATUS_CONFLICTING_ADDRESSES;
        if (!(view->protect & VPROT_FREE_PLACEHOLDER)) return STATUS_INVALID_PARAMETER;

        TRACE( "found view %p, size %p, protect %#x.\n", view->base, (void *)view->size, view->protect );

        view->protect = vprot | VPROT_PLACEHOLDER;
        set_vprot( view, base, size, vprot );
        if (vprot & VPROT_WRITEWATCH)
        {
            kernel_writewatch_register_range( view, base, size );
            reset_write_watches( base, size );
        }
        *view_ret = view;
        return STATUS_SUCCESS;
    }

    if (limit_high && limit_low >= limit_high) return STATUS_INVALID_PARAMETER;

    if (use_kernel_writewatch && vprot & VPROT_WRITEWATCH)
        unix_prot = get_unix_prot( vprot & ~VPROT_WRITEWATCH );

    unix_prot &= ~PROT_EXEC;

    if (base)
    {
        if (is_beyond_limit( base, size, address_space_limit )) return STATUS_WORKING_SET_LIMIT_RANGE;
        if (limit_low && base < (void *)limit_low) return STATUS_CONFLICTING_ADDRESSES;
        if (limit_high && is_beyond_limit( base, size, (void *)limit_high )) return STATUS_CONFLICTING_ADDRESSES;
        if (is_beyond_limit( base, size, host_addr_space_limit )) return STATUS_CONFLICTING_ADDRESSES;
        if ((status = map_fixed_area( base, size, unix_prot ))) return status;
        if (is_beyond_limit( base, size, working_set_limit )) working_set_limit = address_space_limit;
        ptr = base;
    }
    else
    {
        void *start = address_space_start;
        void *end = min( user_space_limit, host_addr_space_limit );
        /* task #35 furniture ceiling — see its definition. Kernel-pick views
         * below 16GB (TEBs, stacks, anon views, section views incl. the 4GB
         * top-of-space tenant from ml106) stay below 464G-64K; only the PA
         * 16GB/32GB pool reserves may use the slots above. */
        int ceiling_relaxable = 0;
        if (ios_furniture_ceiling && !limit_high && size < 0x400000000ULL &&
            (void *)ios_furniture_ceiling < end)
        {
            end = (void *)ios_furniture_ceiling;
            /* Relaxable when the only *effective* constraint is ours. ml119
             * BUG: the first cut used !limit_low, so a caller passing a small
             * non-zero limit_low (<= address_space_start, i.e. not actually
             * constraining anything) disabled both the floor raise and the
             * fallback. Those calls kept scanning from 0x100010000 and burned
             * 21,875 failing mach_vm_map calls EACH — 1.42 MILLION across
             * ml119's 65 [va-scan] SLOW lines. A limit_low at or below
             * address_space_start is satisfied by any placement we would make
             * anyway, so treat it as absent: the floor is above it, and
             * relaxing reproduces exactly what a ceiling-disabled build does
             * for the same call. (top_down is a hint, not a contract, and is
             * knowingly dropped on the relax path.) */
            ceiling_relaxable = (limit_low <= (ULONG_PTR)address_space_start);
        }
        size_t host_size = ROUND_SIZE( 0, size, host_page_mask );
        size_t unmap_size, view_size = host_size + align_mask + 1;
        int spill_tries = 0;

        if (limit_low && (void *)limit_low > start) start = (void *)limit_low;
        if (limit_high && (void *)limit_high < end) end = (char *)limit_high + 1;

        /* task #35 (ml116): raise the scan floor to match the ceiling — see
         * ios_usable_va_floor. Gated on end already being at/below the ceiling,
         * which is exactly the set of requests the ceiling put on the scan path
         * (clamped kernel-picks, plus images via map_image_view's limit_high).
         * Jumbo pool reserves keep end == host_addr_space_limit and so keep the
         * kernel-pick placement the ml96/ml105 census measured, and genuinely
         * low-limited callers (zero_bits / 4GB-capped) are far below the floor
         * and untouched. The window must still be able to hold the request. */
        /* ml118 BUG FIX: gate on ceiling_relaxable, not merely on end<=ceiling.
         * The first cut raised the floor for limit_low/limit_high callers too,
         * narrowing their window while giving them NO escape valve — a 1MB
         * request then hit a hard STATUS_NO_MEMORY (ml118 line 2471) and killed
         * Thumper with exit(3) two lines later. Never impose a constraint we
         * cannot also withdraw. */
        if (ceiling_relaxable && start < (void *)ios_usable_va_floor &&
            (char *)end > (char *)ios_usable_va_floor &&
            (size_t)((char *)end - (char *)ios_usable_va_floor) >= view_size)
            start = (void *)ios_usable_va_floor;

        if ((ptr = map_reserved_area( start, end, host_size, top_down, unix_prot, align_mask )))
        {
            TRACE( "got mem in reserved area %p-%p\n", ptr, (char *)ptr + size );
            goto done;
        }

        if (start > address_space_start || end < host_addr_space_limit || top_down)
        {
            unsigned int tries0 = ios_va_scan_tries;
            unsigned int skips0 = ios_va_scan_skips;

            ptr = map_free_area( start, end, host_size, top_down, unix_prot, align_mask );
            /* [va-scan] the ml116/ml117 probe: a healthy scan costs a handful of
             * tryfixed calls. Hundreds means we are grinding unmappable VA;
             * ptr==NULL is the silent STATUS_NO_MEMORY that handed rpmalloc a
             * NULL. Either is the ceiling regression, so say so out loud — with
             * the geometry map_free_area actually saw, since ml117 failed with
             * tries=0 (rejected on a guard, no mmap attempted). */
            if (!ptr || ios_va_scan_tries - tries0 >= 64)
            {
                static int described;
                char what[128];

                /* ml207: latch furniture pressure — see ios_va_pressure. Deliberately a
                 * much stricter test than this probe's own 64-try "SLOW" threshold: an
                 * outright failure, or grinding on the order of a thousand attempts, is
                 * unambiguous exhaustion rather than ordinary fragmentation. */
                if (!ptr || ios_va_scan_tries - tries0 >= 1024)
                {
                    static int censused;

                    ios_va_pressure = 1;
                    if (!censused) { censused = 1; ios_furniture_census(); }
                }

                /* ml118 discriminator — see ios_scan_fail_addr. Rate-limited:
                 * the mach query is cheap but not free, and the first handful
                 * of verdicts settle the question. */
                what[0] = 0;
                if (ios_scan_fail_addr && described++ < 12)
                    ios_va_describe( ios_scan_fail_addr, what, sizeof(what) );

                {
                static unsigned long vs_storm;
                static unsigned vs_fails;
                /* ml366: FAILED must never be storm-gated — ml365's mmdevapi
                 * c0000017 loads left NO [va-scan] evidence because boot-time
                 * SLOW lines had already spent this site's storm budget. A
                 * failure is the one verdict worth a line every time (own
                 * generous cap so a retry loop cannot flood the log). */
                if (ptr ? ios_storm_gate( &vs_storm ) : (vs_fails++ < 256))
                dprintf( 2, "[va-scan] %s window=%p..%p size=%p align=%p %s tries=%u skips=%u"
                            " | seen=%p..%p views=%u maxgap=%p stop=%s"
                            " | firstfail=%p errno=%d(%s) %s%s\n",
                         ptr ? "SLOW" : "FAILED", start, end, (void *)size,
                         (void *)(align_mask + 1), top_down ? "top-down" : "bottom-up",
                         ios_va_scan_tries - tries0, ios_va_scan_skips - skips0,
                         ios_scan_base, ios_scan_end, ios_scan_views,
                         (void *)ios_scan_maxgap, ios_scan_stop_name( ios_scan_stop ),
                         ios_scan_fail_addr, ios_scan_fail_errno,
                         ios_scan_fail_errno ? strerror( ios_scan_fail_errno ) : "-", what,
                         ptr ? "" : (ceiling_relaxable ? "  --> relaxing ceiling, retrying unclamped"
                                                       : "  <-- STATUS_NO_MEMORY (callers see a NULL alloc)") );
                }
            }
            if (ptr)
            {
                TRACE( "got mem with map_free_area %p-%p\n", ptr, (char *)ptr + size );
                goto done;
            }
            /* ml117: THE CEILING IS ADVISORY, NEVER FATAL. It exists only to
             * bias Wine's furniture low so the top 16GB-aligned slots stay free
             * for PartitionAlloc; failing an allocation for it is strictly worse
             * than landing one view in a pool slot (worst case = 2 pools instead
             * of 3, versus a dead process). So when the clamped window cannot
             * satisfy the request, drop our own constraints and fall through to
             * the unclamped kernel pick below. Only constraints WE added are
             * dropped — a caller-supplied limit_high never sets
             * ceiling_relaxable, so its contract still holds. */
            if (!ceiling_relaxable) return STATUS_NO_MEMORY;
            start = address_space_start;
            end = min( user_space_limit, host_addr_space_limit );
            if (limit_low && (void *)limit_low > start) start = (void *)limit_low;
        }

        for (;;)
        {
            if ((ptr = anon_mmap_alloc( view_size, unix_prot )) == MAP_FAILED)
            {
                status = (errno == ENOMEM) ? STATUS_NO_MEMORY : STATUS_INVALID_PARAMETER;
                ERR( "anon mmap error %s, size %p, unix_prot %#x\n",
                     strerror(errno), (void *)view_size, unix_prot );
                return status;
            }
            TRACE( "got mem with anon mmap %p-%p\n", ptr, (char *)ptr + size );
            /* ml132: keep spill out of the proven pool slots — see ios_spill_cap.
             * Bounded retries, then accept: never fail an allocation for this. */
            if (ios_spill_cap && spill_tries < 8 &&
                is_beyond_limit( ptr, view_size, (void *)ios_spill_cap ))
            {
                spill_tries++;
                ios_pool_va_warn( "munmap", ptr, view_size );
                munmap( ptr, view_size );
                continue;
            }
            /* if we got something beyond the user limit, unmap it and retry */
            if (!is_beyond_limit( ptr, view_size, user_space_limit )) break;
            unmap_size = unmap_area_above_user_limit( ptr, view_size );
            if (unmap_size) munmap( ptr, unmap_size );
        }
        ptr = unmap_extra_space( ptr, view_size, host_size, align_mask );
    }
done:
    status = create_view( view_ret, ptr, size, vprot );
    if (status != STATUS_SUCCESS) unmap_area( ptr, size );
    return status;
}


/***********************************************************************
 *           map_file_into_view
 *
 * Wrapper for mmap() to map a file into a view, falling back to read if mmap fails.
 * virtual_mutex must be held by caller.
 */
static NTSTATUS map_file_into_view_ex( struct file_view *view, int fd, size_t start, size_t size,
                                       off_t offset, unsigned int vprot, BOOL removable,
                                       BOOL for_image );

static NTSTATUS map_file_into_view( struct file_view *view, int fd, size_t start, size_t size,
                                    off_t offset, unsigned int vprot, BOOL removable )
{
    return map_file_into_view_ex( view, fd, start, size, offset, vprot, removable, TRUE );
}

/* ml561 (Sol's provenance recorder): remember HOW each file mapping was made.
 *
 * ml554 and ml559 both faulted at EXACTLY view_base+0x10000 — the 64KB Windows
 * allocation granularity — inside an 0x14000 region, with kr=10
 * (KERN_MEMORY_ERROR) on a page that was RW the whole time. Four 16KB pages
 * materialise; the fifth does not. The single most likely cause of "mapped, RW,
 * but cannot be materialised" is a file mapping that extends PAST END OF FILE:
 * POSIX gives SIGBUS for those pages, and Mach reports KERN_MEMORY_ERROR.
 *
 * Note map_size is rounded with the GUEST 4KB page_mask while iOS host pages are
 * 16KB, and nothing here compares offset+host_size against the file's real size.
 * This records the facts so the next fatal fault can say whether the backing
 * actually covered the view, instead of us guessing.
 *
 * Bounded, allocation-free, lock-free — safe to read from a signal handler.
 * Deliberately does NOT dup or retain the fd: doing so could accidentally repair
 * a lifetime bug and hide the very thing we are trying to see. */
#define IOS_MAP_RING 256
static struct {
    const char *base; size_t view_size, start, size, map_size, host_size;
    long long offset, file_size;
    unsigned long long dev, ino;
    int shared, for_image, valid;
} ios_map_ring[IOS_MAP_RING];
static volatile unsigned ios_map_ring_n;

static void ios_map_record( const void *view_base, size_t view_size, size_t start, size_t size,
                            size_t map_size, size_t host_size, int fd, long long offset,
                            int shared, int for_image )
{
    unsigned slot = __sync_fetch_and_add( &ios_map_ring_n, 1 ) % IOS_MAP_RING;
    struct stat st;
    ios_map_ring[slot].valid = 0;
    ios_map_ring[slot].base = (const char *)view_base;
    ios_map_ring[slot].view_size = view_size;
    ios_map_ring[slot].start = start;
    ios_map_ring[slot].size = size;
    ios_map_ring[slot].map_size = map_size;
    ios_map_ring[slot].host_size = host_size;
    ios_map_ring[slot].offset = offset;
    ios_map_ring[slot].shared = shared;
    ios_map_ring[slot].for_image = for_image;
    if (fd >= 0 && !fstat( fd, &st ))
    {
        ios_map_ring[slot].file_size = (long long)st.st_size;
        ios_map_ring[slot].dev = (unsigned long long)st.st_dev;
        ios_map_ring[slot].ino = (unsigned long long)st.st_ino;
    }
    else ios_map_ring[slot].file_size = -1;
    __sync_synchronize();
    ios_map_ring[slot].valid = 1;
}

/* Signal-handler-safe: describe the mapping containing `addr`, or say plainly
 * that no file mapping covers it (which is itself a real answer — it would mean
 * the page is anonymous and the EOF story is wrong). */
void ios_map_describe( const void *addr, char *out, size_t outlen )
{
    unsigned n = __sync_fetch_and_add( &ios_map_ring_n, 0 );
    unsigned lim = n < IOS_MAP_RING ? n : IOS_MAP_RING;
    const char *a = (const char *)addr;
    int best = -1;
    unsigned i;

    for (i = 0; i < lim; i++)
    {
        if (!ios_map_ring[i].valid) continue;
        if (a >= ios_map_ring[i].base + ios_map_ring[i].start &&
            a <  ios_map_ring[i].base + ios_map_ring[i].start + ios_map_ring[i].map_size)
            best = (int)i;                     /* later records win */
    }
    if (best < 0)
    {
        snprintf( out, outlen, "NO file mapping covers this address "
                               "(anonymous — EOF/backing story does NOT apply)" );
        return;
    }
    {
        long long end_needed = ios_map_ring[best].offset + (long long)ios_map_ring[best].host_size;
        snprintf( out, outlen,
                  "view=%p+0x%zx start=0x%zx size=0x%zx map=0x%zx host=0x%zx off=0x%llx "
                  "%s %s file_size=0x%llx dev=%llu ino=%llu need_off_end=0x%llx %s",
                  (void *)ios_map_ring[best].base, ios_map_ring[best].view_size,
                  ios_map_ring[best].start, ios_map_ring[best].size,
                  ios_map_ring[best].map_size, ios_map_ring[best].host_size,
                  ios_map_ring[best].offset,
                  ios_map_ring[best].shared ? "MAP_SHARED" : "MAP_PRIVATE",
                  ios_map_ring[best].for_image ? "image" : "section",
                  ios_map_ring[best].file_size, ios_map_ring[best].dev, ios_map_ring[best].ino,
                  end_needed,
                  ios_map_ring[best].file_size >= 0 && end_needed > ios_map_ring[best].file_size
                    ? "<== MAPPING EXTENDS PAST END OF FILE — unbacked tail, this is the bug"
                    : "<== backing covers the mapping; EOF is NOT the explanation" );
    }
}

static NTSTATUS map_file_into_view_ex( struct file_view *view, int fd, size_t start, size_t size,
                                       off_t offset, unsigned int vprot, BOOL removable,
                                       BOOL for_image )
{
    char *map_addr, *host_addr;
    size_t map_size, host_size;
    int prot = PROT_READ | PROT_WRITE;
    unsigned int flags = MAP_FIXED;

    assert( start < view->size );
    assert( start + size <= view->size );

    if (vprot & VPROT_WRITE) flags |= MAP_SHARED;
    else if (vprot & VPROT_WRITECOPY) flags |= MAP_PRIVATE;
    else
    {
        /* changes to the file are not guaranteed to be visible in read-only MAP_PRIVATE mappings,
         * but they are on Linux so we take advantage of it */
#if defined(__linux__) || defined(WINE_IOS)
        /* iOS: PE-image read-only sections need MAP_PRIVATE so Wine's PE
         * loader can mprotect them writable temporarily for IAT writes
         * (MAP_SHARED rejects mprotect upgrades with EINVAL on iOS). The
         * `for_image` parameter distinguishes those callers from
         * SEC_COMMIT shared sections (e.g. \KernelObjects\__wine_session)
         * which MUST be MAP_SHARED so the client sees server writes. */
        if (for_image)
            flags |= MAP_PRIVATE;  /* PE image — Wine's PE loader needs mprotect-upgrades */
        else
        {
            flags |= MAP_SHARED;   /* shared section — coherent with wineserver */
            prot &= ~PROT_WRITE;
        }
#else
        flags |= MAP_SHARED;
        prot &= ~PROT_WRITE;
#endif
    }

    map_size = ROUND_SIZE( start, size, page_mask );
    map_addr = ROUND_ADDR( (char *)view->base + start, page_mask );
    host_addr = ROUND_ADDR( (char *)view->base + start, host_page_mask );
    /* last page doesn't need to be a full page */
    if (map_addr + map_size >= (char *)view->base + view->size) host_size = map_size;
    else host_size = ROUND_SIZE( 0, map_size, host_page_mask );

    /* only try mmap if media is not removable (or if we require write access),
       and if alignment is correct */
    if ((!removable || (flags & MAP_SHARED)) && host_addr == map_addr && host_size == map_size)
    {
        /* iOS-Madeira ml563: THE DIRECT INVARIANT — check the backing BEFORE mapping.
         *
         * ml561 proved the Steam/CEF killer: a 0x40000 section view mmap'd over a
         * backing file of only 0x10000/0x20000 bytes. Every page past EOF is
         * unbacked, so Skia's 256x256 tile fill SIGBUSes the moment it crosses that
         * offset — fault offset == file size, exactly, 3/3 events, with the guest's
         * geometry provably correct.
         *
         * This check is synchronous and unconditional at the exact mmap: no ring
         * lookup, no address reuse, no wrap, no signal-handler inference, and the
         * file size is read at the moment it matters.
         *
         * REPAIR, carefully: growing a real on-disk file would corrupt user data
         * (a game asset, a save). wineserver unlinks anonymous section temp files
         * immediately after creating them, so `st_nlink == 0` identifies exactly
         * those — a pagefile-backed section, which Windows guarantees is fully
         * backed for its whole size. Growing THAT restores correct semantics rather
         * than papering over anything. Anything with a link count stays untouched
         * and is reported instead. */
        {
            struct stat mst;
            /* ml564: flag only when a WHOLE host page lies past EOF.
             *
             * ml563's predicate (`offset+host_size > st_size`) fired on every file
             * whose size is not page-aligned — 64/64 events were benign tails like
             * file_size=0xc2122 need=0xc3000, and they consumed the entire budget.
             * POSIX makes the final PARTIAL page of a mapping accessible and
             * zero-filled; only pages lying entirely beyond EOF fault. That is the
             * shape ml561 caught (file 0x10000, need 0x40000 — twelve whole pages
             * past the end), and it is the only shape worth a log line. */
            /* ml570: mst was READ BEFORE fstat FILLED IT here — an uninitialized
             * read (the value was recomputed afterwards, so the effect was benign,
             * but it was undefined behaviour and is fixed). */
            off_t eof_pages = 0;
            if (!fstat( fd, &mst ) &&
                (eof_pages = (((off_t)mst.st_size + (off_t)host_page_mask) & ~(off_t)host_page_mask),
                 eof_pages < (off_t)(offset + (off_t)host_size)))
            {
                static unsigned long eofn;
                int anon_section = (mst.st_nlink == 0) && (flags & MAP_SHARED) && !for_image;
                /* ml570: STOP GROWING THE FILE. The ml564 repair assumed the fd
                 * belonged to this section and was merely undersized. It probably
                 * does NOT: the iOS fd cache is `_Thread_local` while Windows
                 * handles are per-PROCESS, so a handle closed by one thread stays
                 * cached in another, and after wineserver recycles the numeric
                 * handle that thread maps the OLD inode. st_nlink==0 proves only
                 * "unlinked", never "the right object" — so ftruncate here extends
                 * an unrelated section and corrupts it, on top of hiding the
                 * identity bug. Report, do not mutate. */
                int repaired = -1;
                if (++eofn <= 64)
                    dprintf(2, "[map-eof] view=%p+0x%zx start=0x%zx size=0x%zx map=0x%zx "
                               "host=0x%zx off=0x%llx file_size=0x%llx need=0x%llx nlink=%u "
                               "dev=%llu ino=%llu %s %s -- %s wholepage rev=ml564\n",
                            view->base, view->size, start, size, map_size, host_size,
                            (unsigned long long)offset, (unsigned long long)mst.st_size,
                            (unsigned long long)(offset + (off_t)host_size),
                            (unsigned)mst.st_nlink,
                            (unsigned long long)mst.st_dev, (unsigned long long)mst.st_ino,
                            (flags & MAP_SHARED) ? "MAP_SHARED" : "MAP_PRIVATE",
                            for_image ? "image" : "section",
                            anon_section ? "SHORT anon section — NOT repairing (fd identity unproven; suspect stale _Thread_local fd cache)"
                            : "SHORT mapping with links — reporting only");
            }
        }
        if (mmap( host_addr, host_size, prot, flags, fd, offset ) != MAP_FAILED)
        {
            ios_map_record( view->base, view->size, start, size, map_size, host_size,
                            fd, (long long)offset, (flags & MAP_SHARED) != 0, for_image );
            return STATUS_SUCCESS;
        }

        switch (errno)
        {
        case EINVAL:  /* file offset is not page-aligned, fall back to read() */
            break;
        case ENOEXEC:
        case ENODEV:  /* filesystem doesn't support mmap(), fall back to read() */
            if (vprot & VPROT_WRITE)
            {
                ERR( "shared writable mmap not supported, broken filesystem?\n" );
                return STATUS_NOT_SUPPORTED;
            }
            break;
        case EACCES:
        case EPERM:  /* access error, fall back to read() */
            if (vprot & VPROT_WRITE)
            {
                dprintf(2, "[vmem-denied] shared-writable mmap EACCES/EPERM: addr=%p size=%p\n",
                        map_addr, (void *)map_size);
                return STATUS_ACCESS_DENIED;
            }
            break;
        default:
            ERR( "mmap error %s, range %p-%p, unix_prot %#x\n",
                 strerror(errno), map_addr, map_addr + map_size, prot );
            return STATUS_NO_MEMORY;
        }
    }

    if (vprot & VPROT_WRITE)
    {
        ERR( "unaligned shared mapping %p-%p not supported\n", map_addr, map_addr + map_size );
        return STATUS_INVALID_PARAMETER;
    }

    mprotect( map_addr, map_size, PROT_READ | PROT_WRITE );
    pread( fd, map_addr, size, offset );
    return STATUS_SUCCESS;
}


/***********************************************************************
 *           get_committed_size
 *
 * Get the size of the committed range with equal masked vprot bytes starting at base.
 * Also return the protections for the first page.
 */
static SIZE_T get_committed_size( struct file_view *view, void *base, size_t max_size, BYTE *vprot, BYTE vprot_mask )
{
    SIZE_T offset, size;

    base = ROUND_ADDR( base, page_mask );
    offset = (char *)base - (char *)view->base;

    if (view->protect & SEC_RESERVE)
    {
        size = 0;

        *vprot = get_page_vprot( base );

        SERVER_START_REQ( get_mapping_committed_range )
        {
            req->base   = wine_server_client_ptr( view->base );
            req->offset = offset;
            if (!wine_server_call( req ))
            {
                size = min( reply->size, max_size );
                if (reply->committed)
                {
                    *vprot |= VPROT_COMMITTED;
                    set_page_vprot_bits( base, size, VPROT_COMMITTED, 0 );
                }
            }
        }
        SERVER_END_REQ;

        if (!size || !(vprot_mask & ~VPROT_COMMITTED)) return size;
    }
    else size = min( view->size - offset, max_size );

    return get_vprot_range_size( base, size, vprot_mask, vprot );
}


/***********************************************************************
 *           decommit_pages
 *
 * Decommit some pages of a given view.
 * virtual_mutex must be held by caller.
 */
/* task #34 tripwire (ml92/ml94): does [rw_start, rw_start+size) intersect a
 * LIVE pool ledger range? The ledger tracks head allocations — loaded DLL
 * copies — while legitimate anon-alias decommits target FEX CodeBuffers carved
 * from the pool TAIL, which are not ledgered. So an overlap here is never
 * legitimate: it means the alias is stale (its range was freed and recycled to
 * a different module) and zeroing through it would blank live code. Returns the
 * offending ledger entry so the log can name the victim. */
static int ios_pool_live_overlap( uintptr_t rw_start, size_t size,
                                  size_t *off_out, void **peb_out )
{
    uintptr_t rw_base = (uintptr_t)ios_jit_rw_base_global;
    size_t s, e;
    int j;

    if (!rw_base || rw_start < rw_base) return 0;
    s = rw_start - rw_base;
    if (s >= ios_jit_pool_size_global) return 0;
    e = s + size;

    for (j = 0; j < ios_pool_ledger_count; j++)
    {
        size_t l_off = ios_pool_ledger[j].off;
        size_t l_end = l_off + ios_pool_ledger[j].size;
        if (l_off < e && l_end > s)
        {
            if (off_out) *off_out = l_off;
            if (peb_out) *peb_out = ios_pool_ledger[j].peb;
            return 1;
        }
    }
    return 0;
}

/* iOS-Madeira ml610 [dc-census]: HOW MUCH DOES A DECOMMIT ACTUALLY RETURN?
 *
 * Three builds have now argued about this from the memory curve instead of
 * measuring it. ml608 assumed the full 16MB callret clear was WASTING memory;
 * ml609 shrank it to 4MB and got ~388MB WORSE; the source then showed the clear
 * is a reclaim (anon_mmap_fixed drops the physical pages), so the shrink had
 * stranded the remainder. None of that is a measurement of bytes returned.
 *
 * This is. It runs at the reclaim site itself, which is also the only place the
 * Mach APIs are reachable — FEX's ResetCallRetStack() lives in an arm64ec PE
 * built by llvm-mingw, where __APPLE__ is undefined and mincore/mach_vm_region/
 * task_info do not exist.
 *
 * Two independent instruments, because they fail differently:
 *   - mincore() is EXACT for the byte range but only reports residency.
 *   - the Mach region walk reports dirty + swapped-out (i.e. compressed, which
 *     STILL counts toward the 4096MB jetsam limit — the thing mincore cannot
 *     see) but is REGION-granular, so it can over-count when a region extends
 *     past the range. `span` is logged so that over-count is visible rather
 *     than silent: span >> size means the counts include a neighbour.
 * phys_footprint is sampled too, and will contain unrelated noise from other
 * threads — it is a sanity check on the other two, not the primary number.
 */
struct ios_dc_census
{
    unsigned long long resident, dirty, swapped, span, mincore_res, footprint;
};

static void ios_dc_census_take( const void *addr, size_t len, struct ios_dc_census *out )
{
    mach_vm_address_t start = (mach_vm_address_t)(uintptr_t)addr;
    mach_vm_address_t end = start + len;
    mach_vm_address_t ra = start;
    natural_t depth = 0;
    int guard = 0;

    memset( out, 0, sizeof(*out) );

    while (ra < end && guard++ < 4096)
    {
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t icnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        mach_vm_size_t rs = 0;
        if (mach_vm_region_recurse( mach_task_self(), &ra, &rs, &depth,
                                    (vm_region_recurse_info_t)&info, &icnt ) != KERN_SUCCESS) break;
        if (ra >= end) break;
        if (info.is_submap) { depth++; continue; }
        out->resident += (unsigned long long)info.pages_resident    << 14;
        out->dirty    += (unsigned long long)info.pages_dirtied     << 14;
        out->swapped  += (unsigned long long)info.pages_swapped_out << 14;
        out->span     += (unsigned long long)rs;
        ra += rs;
        depth = 0;
    }

    {
        /* Stack-local so concurrent samples cannot corrupt each other's count.
         * 1024 entries covers 16MB at 16KB pages — exactly the callret stack. */
        char vec[1024];
        size_t ps = (size_t)host_page_mask + 1;
        size_t npages = ps ? len / ps : 0;
        if (npages && npages <= sizeof(vec) && !mincore( (void *)(uintptr_t)start, len, vec ))
        {
            size_t i;
            for (i = 0; i < npages; i++)
                if (vec[i] & MINCORE_INCORE) out->mincore_res += ps;
        }
    }

    {
        task_vm_info_data_t vmi;
        mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
        if (task_info( mach_task_self(), TASK_VM_INFO, (task_info_t)&vmi, &c ) == KERN_SUCCESS)
            out->footprint = (unsigned long long)vmi.phys_footprint;
    }
}

static NTSTATUS decommit_pages( struct file_view *view, char *base, size_t size )
{
    char *host_end, *host_start = (char *)ROUND_SIZE( 0, base, host_page_mask );
    /* ml293 probe state: which branch honoured the zero contract, and where to read back. */
    const char *dc_branch = "none";
    const void *dc_verify = NULL;
    size_t      dc_vsize  = 0;
    /* ml610 [dc-census] sample state. */
    struct ios_dc_census dc_before, dc_after;
    struct timeval dc_t0, dc_t1, dc_t2, dc_t3;
    int dc_sampled = 0;

    if (!size)
    {
        size = view->size;
        host_end = host_start + view->size;
    }
    else host_end = ROUND_ADDR( base + size, host_page_mask );

    /* ml610 [dc-census] BEFORE sample. Large ranges only (the 16MB callret
     * stacks and the LookupCache clears — the small-decommit flood would drown
     * the signal and cost far more than it measures). Hard-capped: this runs
     * with virtual_mutex held, and for callret resets it runs on the SWEEPER
     * with the code-buffer migration gate active, so an uncapped probe would
     * perturb exactly what it is measuring. The cost is logged per sample so
     * that judgement is checkable rather than asserted. */
    {
        static unsigned long dc_big_seen, dc_samples;
        if (size >= (4u << 20))
        {
            unsigned long n = ++dc_big_seen;
            if (dc_samples < 16 && (n <= 8 || (n % 512) == 0))
            {
                dc_samples++;
                dc_sampled = 1;
                gettimeofday( &dc_t0, NULL );
                ios_dc_census_take( base, size, &dc_before );
                gettimeofday( &dc_t1, NULL );
            }
        }
    }

    /* iOS-Madeira (task #22 real root cause, 2026-07-10): FEX's Windows
     * VirtualDontNeed() = MEM_DECOMMIT (often WITHOUT recommit — LookupCache
     * uses it as a cheap bzero on every cache clear) and then touches the
     * pages again assuming Linux MADV_DONTNEED semantics (still mapped,
     * reads return zero). The upstream PROT_NONE mmap-over therefore turned
     * every Steam module-load cache-clear into a recurring BUS-fault burst
     * on the SAME pages (retry#1..63 in one run), and on anon-RWX ranges it
     * silently DESTROYED the pool vm_remap alias (decoupled user VA from the
     * pool RW/RX views). Give decommit Linux-like semantics instead:
     *  - alias-backed range: memset the RW alias (zero contract), keep the
     *    mapping and the alias intact;
     *  - plain range: mmap-over RW (fresh zero pages, still accessible) and
     *    zero the partial host pages at the edges by hand. */
    {
        extern uintptr_t ios_jit_anon_alias_lookup(uintptr_t fault_addr);
        uintptr_t rw_alias = ios_jit_anon_alias_lookup( (uintptr_t)base );
        if (rw_alias)
        {
            /* ml92/ml94 [alias-tomb]: the exec faults that survived removing the
             * MADV sweep all landed on RECYCLED pool ranges whose instruction
             * stream read back as ZEROS (insn_stream 00000000 00000000, and the
             * nls poison 0xdead1 still intact) — the signature of this memset
             * firing through a stale alias, not of iOS harvesting a page. The
             * allocator's own comment predicted it: "any guest MEM_DECOMMIT of
             * the old user VA memsets the NEW occupant to zero via
             * decommit_pages' alias path -> blr into zeros -> fault storm."
             * Refuse it: zeroing a loaded DLL copy is never the right answer,
             * and the log names the victim so the claim is checkable. */
            size_t l_off = 0;
            void  *l_peb = NULL;
            if (ios_pool_live_overlap( rw_alias, size, &l_off, &l_peb ))
            {
                dprintf(2, "[alias-tomb] STALE alias decommit REFUSED: user_va=%p size=0x%lx rw_alias=0x%lx -> pool off=0x%lx (LIVE, peb=%p) — would have zeroed a loaded module\n",
                        base, (unsigned long)size, (unsigned long)rw_alias,
                        (unsigned long)l_off, l_peb);
                /* ml293: this branch DELIBERATELY skips zeroing. That is right for a loaded
                 * module, but it means the caller's decommit-as-bzero contract is broken for
                 * this range -- name it so, instead of leaving it indistinguishable from a
                 * range that was zeroed. */
                dc_branch = "alias-REFUSED(NOT zeroed)";
            }
            else
            {
                memset( (void *)rw_alias, 0, size );
                dc_branch = "alias-memset";
                dc_verify = (const void *)rw_alias;
                dc_vsize  = size;
            }
        }
        else if (host_start < host_end)
        {
            anon_mmap_fixed( host_start, host_end - host_start, PROT_READ | PROT_WRITE, 0 );
            dc_branch = "mmap-over";
            dc_verify = host_start;
            dc_vsize  = host_end - host_start;
            /* Zero the guest sub-ranges on partial host pages the mmap-over
             * couldn't cover — FEX relies on decommit-as-bzero, and stale
             * LookupCache entries surviving at the edges would run wrong
             * blocks. Edge pages belong to the same committed RW guest heap. */
            if ((char *)base < host_start) memset( base, 0, host_start - (char *)base );
            if (host_end < (char *)base + size) memset( host_end, 0, (char *)base + size - host_end );
        }
        else
        {
            /* Range lies within a single host page — no full page to remap;
             * zero it in place to honour the decommit-as-bzero contract. */
            memset( base, 0, size );
            dc_branch = "subpage-memset";
            dc_verify = base;
            dc_vsize  = size;
        }

        /* iOS-Madeira ml293 (task #52): VERIFY THE DECOMMIT ZERO CONTRACT IN THE PA ARENAS.
         *
         * Chromium's PartitionAlloc decommits slot spans and requires the pages to read
         * back as zero on recommit; its BackupRefPtr refcount lives in that metadata. A
         * stale (non-zero) refcount is exactly the failure chrome_elf reported: a "refcount"
         * PA_CHECK ending in `ud2` at chrome_elf+0xd7d70, with 0xAA poison and the caller
         * passing 0xEF (PA's quarantine byte).
         *
         * Every branch above believes it zeroed the range, so a report that merely echoed
         * the branch would prove nothing -- READ THE MEMORY BACK. Both outcomes are
         * reportable: OK confirms the contract holds and moves the hypothesis elsewhere,
         * while a non-zero offset plus the stale bytes names the bug outright. The
         * alias-REFUSED branch is reported without a read-back precisely because it does
         * not zero.
         *
         * Arena-band only, capped, so this cannot storm a log. */
        /* ml547: same census conversion as [commit-zero]. As written this was
         * arena-band only (excluding the GUEST band where CEF's render bitmap
         * lives) AND capped at 40 -- and in ml546 all 40 reports went to ONE
         * repeated FEX-band address (0x7c012a1000), so guest and pool decommits
         * were never measured at all. Unbounded counters, every anomaly logged,
         * only the OK lines rate-limited, totals on every line. */
        {
            static unsigned long dc_hi, dc_lo, dcbad_hi, dcbad_lo;
            int dc_isarena = ios_is_arena_addr( base );
            unsigned long dc_n = dc_isarena ? ++dc_hi : ++dc_lo;
            {
                if (dc_verify && dc_vsize)
                {
                    size_t chk = dc_vsize < 64 ? dc_vsize : 64;
                    long nz = ios_first_nonzero( dc_verify, chk );
                    if (nz < 0)
                    {
                        if (dc_n <= 8 || (dc_n % 4096) == 0)
                            dprintf( 2, "[decommit-zero] #%lu %s OK base=%p size=0x%lx branch=%s "
                                     "(zero) checked=%lu/%lu notzero=%lu/%lu rev=ml547\n",
                                     dc_n, dc_isarena ? "arena/pool" : "GUEST",
                                     base, (unsigned long)size, dc_branch,
                                     dc_lo, dc_hi, dcbad_lo, dcbad_hi );
                    }
                    else
                    {
                        /* print from the OFFENDING offset, not from base */
                        const unsigned char *b = (const unsigned char *)dc_verify + nz;
                        if (dc_isarena) dcbad_hi++; else dcbad_lo++;
                        dprintf( 2, "[decommit-zero] #%lu %s *** NOT ZEROED *** base=%p size=0x%lx "
                                 "branch=%s first_nonzero=+0x%lx checked=%lu/%lu notzero=%lu/%lu "
                                 "bytes@nz=%02x %02x %02x %02x %02x %02x %02x %02x rev=ml547\n",
                                 dc_n, dc_isarena ? "arena/pool" : "GUEST",
                                 base, (unsigned long)size, dc_branch, (unsigned long)nz,
                                 dc_lo, dc_hi, dcbad_lo, dcbad_hi,
                                 b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7] );
                    }
                }
                else
                    dprintf( 2, "[decommit-zero] #%lu base=%p size=0x%lx branch=%s "
                             "(no read-back: this branch does not zero)\n",
                             dc_n, base, (unsigned long)size, dc_branch );
            }
        }
    }
    /* ml610 [dc-census] AFTER sample + report. `returned` is the number three
     * builds have argued about without ever measuring it: dirty+swapped before
     * minus after, i.e. what this decommit actually handed back to the system.
     * A near-zero `returned` on a 16MB callret clear would mean the clear is
     * NOT a reclaim and ml609's premise was right after all — so this can
     * refute the change it ships with, which is the point. */
    if (dc_sampled)
    {
        long census_us, work_us;
        unsigned long long charged_before, charged_after;

        gettimeofday( &dc_t2, NULL );
        ios_dc_census_take( base, size, &dc_after );
        gettimeofday( &dc_t3, NULL );

        census_us = (long)((dc_t1.tv_sec - dc_t0.tv_sec) * 1000000 + (dc_t1.tv_usec - dc_t0.tv_usec))
                  + (long)((dc_t3.tv_sec - dc_t2.tv_sec) * 1000000 + (dc_t3.tv_usec - dc_t2.tv_usec));
        work_us   = (long)((dc_t2.tv_sec - dc_t1.tv_sec) * 1000000 + (dc_t2.tv_usec - dc_t1.tv_usec));

        charged_before = dc_before.dirty + dc_before.swapped;
        charged_after  = dc_after.dirty + dc_after.swapped;

        dprintf( 2, "[dc-census] ml610 base=%p size=%luKB branch=%s "
                 "dirty %lluKB->%lluKB swapped %lluKB->%lluKB charged %lluKB->%lluKB "
                 "returned=%lldKB | mincore_res %lluKB->%lluKB resident %lluKB->%lluKB "
                 "span=%lluKB(%s) fp %lluMB->%lluMB decommit_us=%ld census_us=%ld\n",
                 base, (unsigned long)(size >> 10), dc_branch,
                 dc_before.dirty >> 10, dc_after.dirty >> 10,
                 dc_before.swapped >> 10, dc_after.swapped >> 10,
                 charged_before >> 10, charged_after >> 10,
                 ((long long)charged_before - (long long)charged_after) >> 10,
                 dc_before.mincore_res >> 10, dc_after.mincore_res >> 10,
                 dc_before.resident >> 10, dc_after.resident >> 10,
                 dc_before.span >> 10,
                 dc_before.span > (unsigned long long)size ? "OVER-COUNTS: region exceeds range" : "clean",
                 dc_before.footprint >> 20, dc_after.footprint >> 20,
                 work_us, census_us );
    }

    set_page_vprot_bits( base, size, 0, VPROT_COMMITTED );
    if (host_start < host_end) kernel_writewatch_register_range( view, host_start, host_end - host_start );
    return STATUS_SUCCESS;
}


/***********************************************************************
 *           remove_pages_from_view
 *
 * Remove some pages of a given view.
 * virtual_mutex must be held by caller.
 */
static NTSTATUS remove_pages_from_view( struct file_view *view, char *base, size_t size )
{
    assert( size < view->size );

    if (view->base != base && base + size != (char *)view->base + view->size)
    {
        struct file_view *new_view = alloc_view();

        if (!new_view)
        {
            ERR( "out of memory for %p-%p\n", base, base + size );
            return STATUS_NO_MEMORY;
        }
        new_view->base    = base + size;
        new_view->size    = (char *)view->base + view->size - (char *)new_view->base;
        new_view->protect = view->protect;

        unregister_view( view );
        view->size = base - (char *)view->base;
        register_view( view );
        register_view( new_view );

        VIRTUAL_DEBUG_DUMP_VIEW( view );
        VIRTUAL_DEBUG_DUMP_VIEW( new_view );
    }
    else
    {
        unregister_view( view );
        if (view->base == base)
        {
            view->base = base + size;
            view->size -= size;
        }
        else view->size = base - (char *)view->base;

        register_view( view );
        VIRTUAL_DEBUG_DUMP_VIEW( view );
    }
    return STATUS_SUCCESS;
}


/***********************************************************************
 *           free_pages_preserve_placeholder
 *
 * Turn pages of a given view into a placeholder.
 * virtual_mutex must be held by caller.
 */
static NTSTATUS free_pages_preserve_placeholder( struct file_view *view, char *base, size_t size )
{
    NTSTATUS status;

    if (!size) return STATUS_INVALID_PARAMETER_3;
    if (!(view->protect & VPROT_PLACEHOLDER)) return STATUS_CONFLICTING_ADDRESSES;
    if (view->protect & VPROT_FREE_PLACEHOLDER && size == view->size) return STATUS_CONFLICTING_ADDRESSES;

    if (size < view->size)
    {
        if ((UINT_PTR)base & host_page_mask ||
            ((size & host_page_mask) && base + size != (char *)view->base + view->size))
        {
            ERR( "unaligned partial free %p-%p\n", base, base + size );
            return STATUS_CONFLICTING_ADDRESSES;
        }

        status = remove_pages_from_view( view, base, size );
        if (status) return status;

        status = create_view( &view, base, size, VPROT_PLACEHOLDER | VPROT_FREE_PLACEHOLDER );
        if (status) return status;
    }

    view->protect = VPROT_PLACEHOLDER | VPROT_FREE_PLACEHOLDER;
    set_page_vprot( view->base, view->size, 0 );
    anon_mmap_fixed( view->base, ROUND_SIZE( 0, view->size, host_page_mask ), PROT_NONE, 0 );
    return STATUS_SUCCESS;
}


/***********************************************************************
 *           free_pages
 *
 * Free some pages of a given view.
 * virtual_mutex must be held by caller.
 */
static NTSTATUS free_pages( struct file_view *view, char *base, size_t size )
{
    char *host_base = (char *)ROUND_SIZE( 0, base, host_page_mask );
    char *host_end = base + size;
    NTSTATUS status;

    if (size == view->size)
    {
        assert( base == view->base );
        delete_view( view );
        return STATUS_SUCCESS;
    }

    /* new view needs to start on page boundary */

    if (view->base == base)  /* shrink from the start */
    {
        if (size & host_page_mask)
        {
            ERR( "unaligned partial free %p-%p\n", base, base + size );
            return STATUS_CONFLICTING_ADDRESSES;
        }
    }
    else if (base + size < (char *)view->base + view->size)  /* create a hole */
    {
        if ((UINT_PTR)(base + size) & host_page_mask)
        {
            ERR( "unaligned partial free %p-%p\n", base, base + size );
            return STATUS_CONFLICTING_ADDRESSES;
        }
    }

    status = remove_pages_from_view( view, base, size );
    if (!status)
    {
        set_page_vprot( base, size, 0 );
        if (view->protect & VPROT_ARM64EC) clear_arm64ec_range( base, size );
        if (host_base < host_end) unmap_area( host_base, host_end - host_base );
    }
    return status;
}


/***********************************************************************
 *           coalesce_placeholders
 *
 * Coalesce placeholder views.
 * virtual_mutex must be held by caller.
 */
static NTSTATUS coalesce_placeholders( struct file_view *view, char *base, size_t size )
{
    struct rb_entry *next;
    struct file_view *curr_view, *next_view;
    unsigned int i, view_count = 0;
    size_t views_size = 0;

    if (!size) return STATUS_INVALID_PARAMETER_3;
    if (base != view->base) return STATUS_CONFLICTING_ADDRESSES;

    curr_view = view;
    while (curr_view->protect & VPROT_FREE_PLACEHOLDER)
    {
        ++view_count;
        views_size += curr_view->size;
        if (views_size >= size) break;
        if (!(next = rb_next( &curr_view->entry ))) break;
        next_view = RB_ENTRY_VALUE( next, struct file_view, entry );
        if ((char *)curr_view->base + curr_view->size != next_view->base) break;
        curr_view = next_view;
    }

    if (view_count < 2 || size != views_size) return STATUS_CONFLICTING_ADDRESSES;

    for (i = 1; i < view_count; ++i)
    {
        curr_view = RB_ENTRY_VALUE( rb_next( &view->entry ), struct file_view, entry );
        unregister_view( curr_view );
        free_view( curr_view );
    }

    unregister_view( view );
    view->size = views_size;
    register_view( view );

    VIRTUAL_DEBUG_DUMP_VIEW( view );

    return STATUS_SUCCESS;
}


/***********************************************************************
 *           allocate_dos_memory
 *
 * Allocate the DOS memory range.
 */
static NTSTATUS allocate_dos_memory( struct file_view **view, unsigned int vprot )
{
    size_t size;
    void *addr = NULL;
    void * const low_64k = (void *)0x10000;
    const size_t dosmem_size = 0x110000;
    int unix_prot = get_unix_prot( vprot ) & ~PROT_EXEC;

    /* check for existing view */

    if (find_view_range( 0, dosmem_size )) return STATUS_CONFLICTING_ADDRESSES;

    /* check without the first 64K */

    if (mmap_is_in_reserved_area( low_64k, dosmem_size - 0x10000 ) != 1)
    {
        addr = anon_mmap_tryfixed( low_64k, dosmem_size - 0x10000, unix_prot, 0 );
        if (addr == MAP_FAILED) return map_view( view, NULL, dosmem_size, 0, vprot, 0, 0, 0 );
    }

    /* now try to allocate the low 64K too */

    if (mmap_is_in_reserved_area( NULL, 0x10000 ) != 1)
    {
        addr = anon_mmap_tryfixed( (void *)host_page_size, 0x10000 - host_page_size, unix_prot, 0 );
        if (addr != MAP_FAILED)
        {
            if (!anon_mmap_fixed( NULL, host_page_size, unix_prot, 0 ))
            {
                addr = NULL;
                TRACE( "successfully mapped low 64K range\n" );
            }
            else TRACE( "failed to map page 0\n" );
        }
        else
        {
            addr = low_64k;
            TRACE( "failed to map low 64K range\n" );
        }
    }

    /* now reserve the whole range */

    size = (char *)dosmem_size - (char *)addr;
    anon_mmap_fixed( addr, size, unix_prot, 0 );
    return create_view( view, addr, size, vprot );
}


/***********************************************************************
 *           map_pe_header
 *
 * Map the header of a PE file into memory.
 */
static NTSTATUS map_pe_header( void *ptr, size_t size, size_t map_size, int fd, BOOL *removable )
{
    if (!size) return STATUS_INVALID_IMAGE_FORMAT;

    map_size &= ~host_page_mask;

    if (!*removable && map_size)
    {
        if (mmap( ptr, map_size, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE, fd, 0 ) != MAP_FAILED)
        {
            if (size > map_size) pread( fd, (char *)ptr + map_size, size - map_size, map_size );
            return STATUS_SUCCESS;
        }
        switch (errno)
        {
        case EPERM:
        case EACCES:
            WARN( "noexec file system, falling back to read\n" );
            break;
        case ENOEXEC:
        case ENODEV:
            WARN( "file system doesn't support mmap, falling back to read\n" );
            break;
        default:
            ERR( "mmap error %s, range %p-%p\n", strerror(errno), ptr, (char *)ptr + size );
            return STATUS_NO_MEMORY;
        }
        *removable = TRUE;
    }
    pread( fd, ptr, size, 0 );
    return STATUS_SUCCESS;  /* page protections will be updated later */
}

#ifdef _WIN64

/***********************************************************************
 *           get_host_addr_space_limit
 */
/***********************************************************************
 *           ios_va_profile   (ml749)
 *
 * Does this task actually have usable VA between 32GB and 63GB?
 *
 * On the jailbroken research VM, FEX never gets an arena: both candidate
 * windows come back FAILED with tries=0, because both START above the ceiling
 * Wine believes it has --
 *     [0x7c00000000,0x800000000)  = 496GB..32GB   inverted
 *     [0x00c00000000,0x800000000) = 48GB..32GB    inverted
 * -- so the scanner never looks, FEXMem_ThreadState is never allocated, x28
 * stays NULL and init dereferences x28+0x7f0. cube dies before its first guest
 * instruction. On the phone the same fallback band works fine, and physical
 * iOS 26 proves a 64GB regime is sufficient, so the extended 448-512GB regime
 * is NOT required.
 *
 * The suspicion is that Wine UNDERESTIMATES the VM rather than the VM being
 * incapable. get_host_addr_space_limit() probes only POWERS OF TWO and, since
 * MAP_FIXED_NOREPLACE does not exist on Darwin, `addr` is a mere HINT the
 * kernel may ignore -- so an unhonoured hint at 32GB silently demotes the
 * conclusion to 16GB and reports a 32GB ceiling. By construction it can never
 * discover that 48-56GB is usable.
 *
 * Settle it by ASKING THE KERNEL DIRECTLY at fixed addresses, which is what the
 * power-of-two hint walk cannot do. mach_vm_allocate with VM_FLAGS_FIXED does
 * not clobber an existing mapping -- it returns KERN_NO_SPACE -- so this is
 * safe to run unconditionally, and every success is released immediately.
 */
static void ios_va_profile( const char *when )
{
    static const struct { unsigned long long addr; const char *band; } probes[] = {
        { 0x0880000000ULL, "32-40GB" }, { 0x0900000000ULL, "32-40GB" },
        { 0x0A00000000ULL, "40-48GB" }, { 0x0B00000000ULL, "40-48GB" },
        { 0x0C00000000ULL, "48-56GB" }, { 0x0D00000000ULL, "48-56GB" },
        { 0x0E00000000ULL, "56-63GB" }, { 0x0F00000000ULL, "56-63GB" },
        { 0x7C00000000ULL, "496GB (preferred FEX)" },
    };
    task_vm_info_data_t vmi;
    mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
    unsigned i;

    if (task_info( mach_task_self(), TASK_VM_INFO, (task_info_t)&vmi, &cnt ) == KERN_SUCCESS)
        dprintf( 2, "[va-profile] ml749 %s TASK_VM_INFO.max_address=%p (%.1f GB)\n",
                 when, (void *)(uintptr_t)vmi.max_address,
                 (double)vmi.max_address / (1024.0*1024.0*1024.0) );
    else
        dprintf( 2, "[va-profile] ml749 %s TASK_VM_INFO UNAVAILABLE\n", when );

    dprintf( 2, "[va-profile] ml749 %s host_addr_space_limit=%p address_space_limit=%p user_space_limit=%p\n",
             when, host_addr_space_limit, address_space_limit, user_space_limit );

    for (i = 0; i < ARRAY_SIZE(probes); i++)
    {
        mach_vm_address_t a = probes[i].addr;
        kern_return_t kr = mach_vm_allocate( mach_task_self(), &a, 0x4000, VM_FLAGS_FIXED );
        dprintf( 2, "[va-profile] ml749 %s fixed 16KB @ 0x%llx (%-22s) -> %s (kr=%d)\n",
                 when, probes[i].addr, probes[i].band,
                 kr == KERN_SUCCESS ? "MAPPABLE" : "refused", (int)kr );
        if (kr == KERN_SUCCESS) mach_vm_deallocate( mach_task_self(), a, 0x4000 );
    }
}

static void *get_host_addr_space_limit(void)
{
    unsigned int flags = MAP_PRIVATE | MAP_ANON;
    UINT_PTR addr = (UINT_PTR)1 << 63;

#ifdef MAP_FIXED_NOREPLACE
    flags |= MAP_FIXED_NOREPLACE;
#endif

    while (addr >> 32)
    {
        void *ret = mmap( (void *)addr, host_page_size, PROT_NONE, flags, -1, 0 );
        if (ret != MAP_FAILED)
        {
            ios_pool_va_warn( "munmap", ret, host_page_size );
            munmap( ret, host_page_size );
            if (ret >= (void *)addr) break;
        }
        else if (errno == EEXIST) break;
        addr >>= 1;
    }
    /* ml122 THE TOP-SLOT UNLOCK. Upstream subtracts one allocation granule
     * here, which makes host_addr_space_limit 0x7fffff0000 on iOS: 64KB below
     * the true 512GB boundary. is_beyond_limit() treats limit as EXCLUSIVE
     * (addr + size > limit rejects), so that granule of conservatism rejects
     * any mapping ending exactly at 0x8000000000 -- which is every possible
     * 16GB reservation in the top slot [0x7c00000000, 0x8000000000). That is
     * why PartitionAlloc's plain pool kept falling through 0x7c00000000 to
     * 0x7800000000 (ml120, ml122), stealing the ONLY slot the guard-style pool
     * can use (a guard pool needs 64KB free below its 16GB boundary, and the
     * top slot has the end of the address space above it, so it can never host
     * one). Net effect: one pool instead of two. (addr << 1) is already the
     * first UNMAPPABLE address, which is exactly the exclusive bound
     * is_beyond_limit wants, so return it unmodified. */
    {
        /* ml749: PREFER THE KERNEL'S OWN ANSWER OVER THE POWER-OF-TWO WALK.
         *
         * The loop above can only ever conclude a POWER OF TWO -- 16GB, 32GB,
         * 64GB, nothing between -- and since MAP_FIXED_NOREPLACE does not exist
         * on Darwin, `addr` is only a HINT the kernel may decline, which is why
         * it has to check `ret >= addr`. One unhonoured hint therefore halves
         * the conclusion. On the jailbroken research VM that lands on 32GB
         * against a real 63GB ceiling, and every FEX arena window inverts:
         * [48GB,32GB) scans nothing, FEXMem_ThreadState is never allocated,
         * x28 stays NULL and cube dies at x28+0x7f0 before its first guest
         * instruction. Fixed 16KB reservations at 52, 55 and 57GB all succeed
         * there, so the range is real and only our estimate was wrong.
         *
         * TASK_VM_INFO.max_address is the map's actual ceiling and needs no
         * hint to be honoured. It is EXCLUSIVE, which is what is_beyond_limit()
         * wants, matching the ml122 note above.
         *
         * Only ever RAISE the walk's answer, never lower it: the walk is proven
         * on hardware, and a device reporting a small or bogus max_address must
         * not shrink a limit that already works. Both values are logged so the
         * two can be compared on any device. */
        void *walked = (void *)(addr << 1);
        task_vm_info_data_t vmi;
        mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;

        if (task_info( mach_task_self(), TASK_VM_INFO, (task_info_t)&vmi, &cnt ) == KERN_SUCCESS)
        {
            void *kern = (void *)(uintptr_t)vmi.max_address;

            dprintf( 2, "[va-limit] ml749 walk=%p kernel_max=%p -> %s\n",
                     walked, kern, kern > walked ? "USING KERNEL (walk underestimated)" : "keeping walk" );
            if (kern > walked && (uintptr_t)kern >= 0x100000000ULL) return kern;
        }
        else dprintf( 2, "[va-limit] ml749 walk=%p kernel_max=UNAVAILABLE -> keeping walk\n", walked );

        return walked;
    }
}

#endif /* _WIN64 */

#ifdef __aarch64__

/***********************************************************************
 *           alloc_arm64ec_map
 */
static void alloc_arm64ec_map(void)
{
    unsigned int status;
    /* ml124: size the EC bitmap from the address space that can actually EXIST,
     * not Windows' theoretical one. Upstream uses address_space_limit =
     * 0x7fffffff0000 (128TB), and at one bit per 4KB page that is a 4.06GB
     * reservation -- measured as [window] run#0, the single largest tenant of
     * the furniture window. Nothing on iOS can be mapped at or above
     * host_addr_space_limit (0x8000000000 = 512GB), so every address that can
     * ever be marked indexes below 0x8000000000 >> 15 = 16MB. That is a 256x
     * cut for 4.06GB back, and unlike the ~512MB-per-thread FEX LookupCache
     * reservations it does not scale with thread count.
     *
     * Safe because every other bitmap user derives its byte index from the
     * ADDRESS being marked ((size_t)addr >> 12 / 8) and commits through
     * set_vprot on this same view -- none of them recompute the size from
     * address_space_limit, so none can index past the smaller view while the
     * VA ceiling holds. */
    ULONG_PTR ec_limit = (ULONG_PTR)address_space_limit;
    if (host_addr_space_limit && (ULONG_PTR)host_addr_space_limit < ec_limit)
        ec_limit = (ULONG_PTR)host_addr_space_limit;
    SIZE_T size = (ec_limit + page_size) >> (page_shift + 3);  /* one bit per page */

    size = ROUND_SIZE( 0, size, host_page_mask );
    status = map_view( &arm64ec_view, NULL, size, MEM_TOP_DOWN, VPROT_READ | VPROT_COMMITTED, 0, 0, 0 );
    if (status)
    {
        ERR( "failed to allocate ARM64EC map: %08x\n", status );
        exit(1);
    }
    peb->EcCodeBitMap = arm64ec_view->base;
    /* ml127: dprintf, not ERR — the `virtual` channel's ERR is suppressed in
     * this build, which is why this line has never once appeared in a log. */
    dprintf(2, "[ec-map] peb->EcCodeBitMap=%p size=0x%lx (%lu MB)\n",
            peb->EcCodeBitMap, (unsigned long)size, (unsigned long)(size >> 20));
}


/***********************************************************************
 *           update_arm64ec_ranges
 */
static void update_arm64ec_ranges( struct file_view *view, IMAGE_NT_HEADERS *nt,
                                   const IMAGE_DATA_DIRECTORY *dir, UINT *entry_point )
{
    const IMAGE_ARM64EC_METADATA *metadata;
    const IMAGE_CHPE_RANGE_ENTRY *map;
    char *base = view->base;
    const IMAGE_LOAD_CONFIG_DIRECTORY *cfg = (void *)(base + dir->VirtualAddress);
    ULONG i, size = min( dir->Size, cfg->Size );

    if (size <= offsetof( IMAGE_LOAD_CONFIG_DIRECTORY, CHPEMetadataPointer )) return;
    if (!cfg->CHPEMetadataPointer) return;
    if (!arm64ec_view) alloc_arm64ec_map();
    commit_arm64ec_map( view );
    metadata = (void *)(base + (cfg->CHPEMetadataPointer - nt->OptionalHeader.ImageBase));
    *entry_point = redirect_arm64ec_rva( base, nt->OptionalHeader.AddressOfEntryPoint, metadata );
    if (!metadata->CodeMap) return;
    map = (void *)(base + metadata->CodeMap);

    for (i = 0; i < metadata->CodeMapCount; i++)
    {
        if ((map[i].StartOffset & 0x3) != 1 /* arm64ec */) continue;
        set_arm64ec_range( base + (map[i].StartOffset & ~3), map[i].Length );
    }
}


/***********************************************************************
 *           apply_arm64x_relocations
 */
static void apply_arm64x_relocations( char *base, const IMAGE_BASE_RELOCATION *reloc, size_t size )
{
    const IMAGE_BASE_RELOCATION *reloc_end = (const IMAGE_BASE_RELOCATION *)((const char *)reloc + size);

    while (reloc < reloc_end - 1 && reloc->SizeOfBlock)
    {
        const USHORT *rel = (const USHORT *)(reloc + 1);
        const USHORT *rel_end = (const USHORT *)reloc + reloc->SizeOfBlock / sizeof(USHORT);
        char *page = base + reloc->VirtualAddress;

        while (rel < rel_end && *rel)
        {
            USHORT offset = *rel & 0xfff;
            USHORT type = (*rel >> 12) & 3;
            USHORT arg = *rel >> 14;
            int val;
            rel++;
            switch (type)
            {
            case IMAGE_DVRT_ARM64X_FIXUP_TYPE_ZEROFILL:
                memset( page + offset, 0, 1 << arg );
                break;
            case IMAGE_DVRT_ARM64X_FIXUP_TYPE_VALUE:
                memcpy( page + offset, rel, 1 << arg );
                rel += (1 << arg) / sizeof(USHORT);
                break;
            case IMAGE_DVRT_ARM64X_FIXUP_TYPE_DELTA:
                val = (unsigned int)*rel++ * ((arg & 2) ? 8 : 4);
                if (arg & 1) val = -val;
                *(int *)(page + offset) += val;
                break;
            }
        }
        reloc = (const IMAGE_BASE_RELOCATION *)rel_end;
    }
}


/***********************************************************************
 *           update_arm64x_mapping
 */
static void update_arm64x_mapping( struct file_view *view, IMAGE_NT_HEADERS *nt,
                                   const IMAGE_DATA_DIRECTORY *dir, IMAGE_SECTION_HEADER *sections )
{
    const IMAGE_DYNAMIC_RELOCATION_TABLE *table;
    const char *ptr, *end;
    char *base = view->base;
    const IMAGE_LOAD_CONFIG_DIRECTORY *cfg = (void *)(base + dir->VirtualAddress);
    ULONG sec, offset, size = min( dir->Size, cfg->Size );

    if (size <= offsetof( IMAGE_LOAD_CONFIG_DIRECTORY, DynamicValueRelocTableSection )) return;
    offset = cfg->DynamicValueRelocTableOffset;
    sec = cfg->DynamicValueRelocTableSection;
    if (!sec || sec > nt->FileHeader.NumberOfSections) return;
    if (offset >= sections[sec - 1].Misc.VirtualSize) return;
    table = (const IMAGE_DYNAMIC_RELOCATION_TABLE *)(base + sections[sec - 1].VirtualAddress + offset);
    ptr = (const char *)(table + 1);
    end = ptr + table->Size;
    switch (table->Version)
    {
    case 1:
        while (ptr < end)
        {
            const IMAGE_DYNAMIC_RELOCATION64 *dyn = (const IMAGE_DYNAMIC_RELOCATION64 *)ptr;
            if (dyn->Symbol == IMAGE_DYNAMIC_RELOCATION_ARM64X)
            {
                apply_arm64x_relocations( base, (const IMAGE_BASE_RELOCATION *)(dyn + 1),
                                          dyn->BaseRelocSize );
                break;
            }
            ptr += sizeof(*dyn) + dyn->BaseRelocSize;
        }
        break;
    case 2:
        while (ptr < end)
        {
            const IMAGE_DYNAMIC_RELOCATION64_V2 *dyn = (const IMAGE_DYNAMIC_RELOCATION64_V2 *)ptr;
            if (dyn->Symbol == IMAGE_DYNAMIC_RELOCATION_ARM64X)
            {
                apply_arm64x_relocations( base, (const IMAGE_BASE_RELOCATION *)(dyn + 1),
                                          dyn->FixupInfoSize );
                break;
            }
            ptr += dyn->HeaderSize + dyn->FixupInfoSize;
        }
        break;
    default:
        FIXME( "unsupported version %u\n", table->Version );
        break;
    }
}

#endif  /* __aarch64__ */

/***********************************************************************
 *           get_data_dir
 */
static IMAGE_DATA_DIRECTORY *get_data_dir( IMAGE_NT_HEADERS *nt, SIZE_T total_size, ULONG dir )
{
    IMAGE_DATA_DIRECTORY *data;

    switch (nt->OptionalHeader.Magic)
    {
    case IMAGE_NT_OPTIONAL_HDR64_MAGIC:
        if (dir >= ((IMAGE_NT_HEADERS64 *)nt)->OptionalHeader.NumberOfRvaAndSizes) return NULL;
        data = &((IMAGE_NT_HEADERS64 *)nt)->OptionalHeader.DataDirectory[dir];
        break;
    case IMAGE_NT_OPTIONAL_HDR32_MAGIC:
        if (dir >= ((IMAGE_NT_HEADERS32 *)nt)->OptionalHeader.NumberOfRvaAndSizes) return NULL;
        data = &((IMAGE_NT_HEADERS32 *)nt)->OptionalHeader.DataDirectory[dir];
        break;
    default:
        return NULL;
    }
    if (!data->Size) return NULL;
    if (!data->VirtualAddress) return NULL;
    if (data->VirtualAddress >= total_size) return NULL;
    if (data->Size > total_size - data->VirtualAddress) return NULL;
    return data;
}


/***********************************************************************
 *           process_relocation_block
 *
 * Reimplementation of LdrProcessRelocationBlock.
 */
static IMAGE_BASE_RELOCATION *process_relocation_block( char *page, IMAGE_BASE_RELOCATION *rel,
                                                        INT_PTR delta )
{
    USHORT *reloc = (USHORT *)(rel + 1);
    unsigned int count;

    for (count = (rel->SizeOfBlock - sizeof(*rel)) / sizeof(USHORT); count; count--, reloc++)
    {
        USHORT offset = *reloc & 0xfff;
        switch (*reloc >> 12)
        {
        case IMAGE_REL_BASED_ABSOLUTE:
            break;
        case IMAGE_REL_BASED_HIGH:
            *(short *)(page + offset) += HIWORD(delta);
            break;
        case IMAGE_REL_BASED_LOW:
            *(short *)(page + offset) += LOWORD(delta);
            break;
        case IMAGE_REL_BASED_HIGHLOW:
            *(int *)(page + offset) += delta;
            break;
        case IMAGE_REL_BASED_DIR64:
            *(INT64 *)(page + offset) += delta;
            break;
        case IMAGE_REL_BASED_THUMB_MOV32:
        {
            DWORD *inst = (DWORD *)(page + offset);
            WORD lo = ((inst[0] << 1) & 0x0800) + ((inst[0] << 12) & 0xf000) +
                      ((inst[0] >> 20) & 0x0700) + ((inst[0] >> 16) & 0x00ff);
            WORD hi = ((inst[1] << 1) & 0x0800) + ((inst[1] << 12) & 0xf000) +
                      ((inst[1] >> 20) & 0x0700) + ((inst[1] >> 16) & 0x00ff);
            DWORD imm = MAKELONG( lo, hi ) + delta;

            lo = LOWORD( imm );
            hi = HIWORD( imm );
            inst[0] = (inst[0] & 0x8f00fbf0) + ((lo >> 1) & 0x0400) + ((lo >> 12) & 0x000f) +
                                               ((lo << 20) & 0x70000000) + ((lo << 16) & 0xff0000);
            inst[1] = (inst[1] & 0x8f00fbf0) + ((hi >> 1) & 0x0400) + ((hi >> 12) & 0x000f) +
                                               ((hi << 20) & 0x70000000) + ((hi << 16) & 0xff0000);
            break;
        }
        default:
            FIXME( "Unknown/unsupported relocation %x\n", *reloc );
            return NULL;
        }
    }
    return (IMAGE_BASE_RELOCATION *)reloc;  /* return address of next block */
}


/***********************************************************************
 *           map_image_into_view
 *
 * Map an executable (PE format) image into an existing view.
 * virtual_mutex must be held by caller.
 */
static NTSTATUS map_image_into_view( struct file_view *view, const UNICODE_STRING *nt_name, int fd,
                                     struct pe_image_info *image_info, USHORT machine,
                                     int shared_fd, BOOL removable )
{
    IMAGE_DOS_HEADER *dos;
    IMAGE_NT_HEADERS *nt;
    IMAGE_SECTION_HEADER *sections = NULL, *sec;
    IMAGE_DATA_DIRECTORY *imports, *dir;
    NTSTATUS status = STATUS_CONFLICTING_ADDRESSES;
    int i;
    off_t pos;
    struct stat st;
    char *header_end;
    char *ptr = view->base;
    SIZE_T header_size, header_map_size, total_size = view->size;
    SIZE_T align_mask = max( image_info->alignment - 1, page_mask );
    INT_PTR delta;

    TRACE_(module)( "mapping PE file %s at %p-%p\n", debugstr_us(nt_name), ptr, ptr + total_size );

    /* Verbose per-section logging removed; error paths still log */

#ifdef WINE_IOS
    /* iOS: server hands us a high ASLR map_addr (e.g. 0x6fffff880000) that the
     * iOS user-space-limit rejects, so map_view falls back to a low address
     * (e.g. 0xebf6a0000). Wine's perform_relocations below uses
     * (image_info->map_addr - image_info->base) for delta — that produces the
     * WRONG delta if map_addr disagrees with ptr. Force them to match so all
     * ARM64 PC-relative relocations (ADRP/ADR/BRANCH26) target real addresses. */
    if (image_info->map_addr && (uintptr_t)ptr != image_info->map_addr)
    {
        ERR("iOS: forcing map_addr 0x%lx -> %p (actual view base) so reloc delta is correct\n",
            (unsigned long)image_info->map_addr, ptr);
        image_info->map_addr = (uintptr_t)ptr;
    }
#endif

    /* map the header */

    fstat( fd, &st );
    header_size = min( image_info->header_size, st.st_size );
    header_map_size = min( image_info->header_map_size, ROUND_SIZE( 0, st.st_size, host_page_mask ));
    if ((status = map_pe_header( view->base, header_size, header_map_size, fd, &removable )))
    {
        ERR("[map_image_into_view] map_pe_header FAILED: 0x%x st_size=0x%llx\n", status, (unsigned long long)st.st_size);
        return status;
    }

    status = STATUS_INVALID_IMAGE_FORMAT;  /* generic error */
    /* ml143 [img-fmt]: steamwebhelper's dbghelp.dll import fails with
     * c000007b AFTER dbghelp already mapped twice in this same run, and the
     * mixed-arch sysx64 fallback is never even attempted for it. This function
     * has seven distinct ways to return INVALID_IMAGE_FORMAT and the log says
     * only "failed (error c000007b)", so name the branch that actually fires
     * instead of inferring a third time. */
#define IOS_IMG_FAIL(n) do { \
        dprintf(2, "[img-fmt] %s: reject #%d (machine=0x%x sections=%u align=0x%x/0x%x flags=0x%x)\n", \
                debugstr_us(nt_name), (n), nt->FileHeader.Machine, \
                nt->FileHeader.NumberOfSections, \
                (unsigned)nt->OptionalHeader.FileAlignment, \
                (unsigned)nt->OptionalHeader.SectionAlignment, \
                (unsigned)image_info->image_flags); \
    } while (0)
    dos = (IMAGE_DOS_HEADER *)ptr;
    nt = (IMAGE_NT_HEADERS *)(ptr + dos->e_lfanew);
    header_end = ptr + ROUND_SIZE( 0, header_size, align_mask );
    memset( ptr + header_size, 0, header_end - (ptr + header_size) );
    if ((char *)(nt + 1) > header_end) do { IOS_IMG_FAIL(1); return status; } while (0);
    sec = IMAGE_FIRST_SECTION( nt );
    if ((char *)(sec + nt->FileHeader.NumberOfSections) > header_end) do { IOS_IMG_FAIL(2); return status; } while (0);
    if ((char *)(sec + nt->FileHeader.NumberOfSections) > ptr + image_info->header_map_size)
    {
        /* copy section data since it will get overwritten by a section mapping */
        if (!(sections = malloc( sizeof(*sections) * nt->FileHeader.NumberOfSections )))
            return STATUS_NO_MEMORY;
        memcpy( sections, sec, sizeof(*sections) * nt->FileHeader.NumberOfSections );
        sec = sections;
    }
    imports = get_data_dir( nt, total_size, IMAGE_DIRECTORY_ENTRY_IMPORT );

    /* check for non page-aligned binary */

    if (image_info->image_flags & IMAGE_FLAGS_ImageMappedFlat)
    {
        /* unaligned sections, this happens for native subsystem binaries */
        /* in that case Windows simply maps in the whole file */

        total_size = min( total_size, ROUND_SIZE( 0, st.st_size, page_mask ));
        if (map_file_into_view( view, fd, 0, total_size, 0, VPROT_COMMITTED | VPROT_READ | VPROT_WRITECOPY,
                                removable ) != STATUS_SUCCESS) do { IOS_IMG_FAIL(3); goto done; } while (0);

        /* check that all sections are loaded at the right offset */
        if (nt->OptionalHeader.FileAlignment != nt->OptionalHeader.SectionAlignment) do { IOS_IMG_FAIL(4); goto done; } while (0);
        for (i = 0; i < nt->FileHeader.NumberOfSections; i++)
        {
            if (sec[i].VirtualAddress != sec[i].PointerToRawData)
                do { IOS_IMG_FAIL(5); goto done; } while (0);  /* Windows refuses to load in that case too */
        }

        /* set the image protections */
        set_vprot( view, ptr, total_size, VPROT_COMMITTED | VPROT_READ | VPROT_WRITECOPY | VPROT_EXEC );

        /* no relocations are performed on non page-aligned binaries */
        status = STATUS_SUCCESS;
        do { IOS_IMG_FAIL(6); goto done; } while (0);
    }


    /* map all the sections */

    for (i = pos = 0; i < nt->FileHeader.NumberOfSections; i++)
    {
        static const SIZE_T sector_align = 0x1ff;
        SIZE_T map_size, file_start, file_size, end;

        if (!sec[i].Misc.VirtualSize)
            map_size = ROUND_SIZE( 0, sec[i].SizeOfRawData, align_mask );
        else
            map_size = ROUND_SIZE( 0, sec[i].Misc.VirtualSize, align_mask );

        /* file positions are rounded to sector boundaries regardless of OptionalHeader.FileAlignment */
        file_start = sec[i].PointerToRawData & ~sector_align;
        file_size = ROUND_SIZE( sec[i].PointerToRawData, sec[i].SizeOfRawData, sector_align );
        if (file_size > map_size) file_size = map_size;

        /* a few sanity checks */
        end = sec[i].VirtualAddress + ROUND_SIZE( sec[i].VirtualAddress, map_size, align_mask );
        if (sec[i].VirtualAddress > total_size || end > total_size || end < sec[i].VirtualAddress)
        {
            WARN_(module)( "%s section %.8s too large (%x+%lx/%lx)\n",
                           debugstr_us(nt_name), sec[i].Name, sec[i].VirtualAddress, map_size, total_size );
            do { IOS_IMG_FAIL(7); goto done; } while (0);
        }

        if ((sec[i].Characteristics & IMAGE_SCN_MEM_SHARED) &&
            (sec[i].Characteristics & IMAGE_SCN_MEM_WRITE))
        {
            TRACE_(module)( "%s mapping shared section %.8s at %p off %x (%x) size %lx (%lx) flags %x\n",
                            debugstr_us(nt_name), sec[i].Name, ptr + sec[i].VirtualAddress,
                            sec[i].PointerToRawData, (int)pos, file_size, map_size,
                            sec[i].Characteristics );
            if (map_file_into_view( view, shared_fd, sec[i].VirtualAddress, map_size, pos,
                                    VPROT_COMMITTED | VPROT_READ | VPROT_WRITE, FALSE ) != STATUS_SUCCESS)
            {
                ERR_(module)( "Could not map %s shared section %.8s\n", debugstr_us(nt_name), sec[i].Name );
                do { IOS_IMG_FAIL(8); goto done; } while (0);
            }

            /* check if the import directory falls inside this section */
            if (imports && imports->VirtualAddress >= sec[i].VirtualAddress &&
                imports->VirtualAddress < sec[i].VirtualAddress + map_size)
            {
                UINT_PTR base = imports->VirtualAddress & ~host_page_mask;
                UINT_PTR end = base + ROUND_SIZE( imports->VirtualAddress, imports->Size, host_page_mask );
                if (end > sec[i].VirtualAddress + map_size) end = sec[i].VirtualAddress + map_size;
                if (end > base)
                    map_file_into_view( view, shared_fd, base, end - base,
                                        pos + (base - sec[i].VirtualAddress),
                                        VPROT_COMMITTED | VPROT_READ | VPROT_WRITECOPY, FALSE );
            }
            pos += map_size;
            continue;
        }

        TRACE_(module)( "mapping %s section %.8s at %p off %x size %x virt %x flags %x\n",
                        debugstr_us(nt_name), sec[i].Name, ptr + sec[i].VirtualAddress,
                        sec[i].PointerToRawData, sec[i].SizeOfRawData,
                        sec[i].Misc.VirtualSize, sec[i].Characteristics );

        if (!sec[i].PointerToRawData || !file_size) continue;

        /* Note: if the section is not aligned properly map_file_into_view will magically
         *       fall back to read(), so we don't need to check anything here.
         */
        end = file_start + file_size;
        if (sec[i].PointerToRawData >= st.st_size ||
            end > ((st.st_size + sector_align) & ~sector_align) ||
            end < file_start ||
            map_file_into_view( view, fd, sec[i].VirtualAddress, file_size, file_start,
                                VPROT_COMMITTED | VPROT_READ | VPROT_WRITECOPY,
                                removable ) != STATUS_SUCCESS)
        {
            ERR_(module)( "Could not map %s section %.8s, file probably truncated\n",
                          debugstr_us(nt_name), sec[i].Name );
            do { IOS_IMG_FAIL(9); goto done; } while (0);
        }

        if (file_size & align_mask)
        {
            end = ROUND_SIZE( 0, file_size, align_mask );
            if (end > map_size) end = map_size;
            TRACE_(module)("clearing %p - %p\n",
                           ptr + sec[i].VirtualAddress + file_size,
                           ptr + sec[i].VirtualAddress + end );
            memset( ptr + sec[i].VirtualAddress + file_size, 0, end - file_size );
        }
    }

#ifdef __aarch64__
    if ((dir = get_data_dir( nt, total_size, IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG )))
    {
        if (image_info->machine == IMAGE_FILE_MACHINE_ARM64 &&
            (machine == IMAGE_FILE_MACHINE_AMD64 ||
             (!machine && ios_cur_image_info_machine() == IMAGE_FILE_MACHINE_AMD64)))
        {
            update_arm64x_mapping( view, nt, dir, sec );
            /* reload changed machine from NT header */
            image_info->machine = nt->FileHeader.Machine;
        }
        if (image_info->machine == IMAGE_FILE_MACHINE_AMD64)
            update_arm64ec_ranges( view, nt, dir, &image_info->entry_point );
    }
#endif
    /* sections mapped OK */
    if (machine && machine != nt->FileHeader.Machine)
    {
        status = STATUS_NOT_SUPPORTED;
        goto done;
    }

    /* relocate to dynamic base */

    if (image_info->map_addr && (delta = image_info->map_addr - image_info->base))
    {
        TRACE_(module)( "relocating %s dynamic base %lx -> %lx mapped at %p\n", debugstr_us(nt_name),
                        (ULONG_PTR)image_info->base, (ULONG_PTR)image_info->map_addr, ptr );

        if (nt->OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC)
            ((IMAGE_NT_HEADERS64 *)nt)->OptionalHeader.ImageBase = image_info->map_addr;
        else
            ((IMAGE_NT_HEADERS32 *)nt)->OptionalHeader.ImageBase = image_info->map_addr;

        if ((dir = get_data_dir( nt, total_size, IMAGE_DIRECTORY_ENTRY_BASERELOC )))
        {
            IMAGE_BASE_RELOCATION *rel = (IMAGE_BASE_RELOCATION *)(ptr + dir->VirtualAddress);
            IMAGE_BASE_RELOCATION *end = (IMAGE_BASE_RELOCATION *)((char *)rel + dir->Size);

            while (rel && rel < end - 1 && rel->SizeOfBlock && rel->VirtualAddress < total_size)
                rel = process_relocation_block( ptr + rel->VirtualAddress, rel, delta );
        }
    }

    /* set the image protections */

    set_vprot( view, ptr, ROUND_SIZE( 0, header_size, align_mask ), VPROT_COMMITTED | VPROT_READ );

    for (i = 0; i < nt->FileHeader.NumberOfSections; i++)
    {
        SIZE_T size;
        BYTE vprot = VPROT_COMMITTED;

        if (sec[i].Misc.VirtualSize)
            size = ROUND_SIZE( sec[i].VirtualAddress, sec[i].Misc.VirtualSize, align_mask );
        else
            size = ROUND_SIZE( sec[i].VirtualAddress, sec[i].SizeOfRawData, align_mask );

        if (sec[i].Characteristics & IMAGE_SCN_MEM_READ)    vprot |= VPROT_READ;
        if (sec[i].Characteristics & IMAGE_SCN_MEM_WRITE)   vprot |= VPROT_WRITECOPY;
        if (sec[i].Characteristics & IMAGE_SCN_MEM_EXECUTE) vprot |= VPROT_EXEC;

        if (!set_vprot( view, ptr + sec[i].VirtualAddress, size, vprot ) && (vprot & VPROT_EXEC))
            ERR( "failed to set %08x protection on %s section %.8s, noexec filesystem?\n",
                 sec[i].Characteristics, debugstr_us(nt_name), sec[i].Name );
    }

#ifdef VALGRIND_LOAD_PDB_DEBUGINFO
    VALGRIND_LOAD_PDB_DEBUGINFO(fd, ptr, total_size, ptr - (char *)wine_server_get_ptr( image_info->base ));
#endif
    status = STATUS_SUCCESS;

#ifdef WINE_IOS
    /* Eagerly JIT-copy all EXEC sections right here — every PE load goes
     * through map_image_into_view, regardless of whether it's via
     * virtual_map_image (builtin flag) or any alternate path. */
    ERR("iOS map_image_into_view: view=%p EXEC fixup\n", ptr);
    for (int si = 0; si < nt->FileHeader.NumberOfSections; si++)
    {
        if (!(sec[si].Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        SIZE_T sec_size = sec[si].Misc.VirtualSize
            ? ROUND_SIZE(sec[si].VirtualAddress, sec[si].Misc.VirtualSize, align_mask)
            : ROUND_SIZE(sec[si].VirtualAddress, sec[si].SizeOfRawData, align_mask);
        void *sec_addr = ptr + sec[si].VirtualAddress;
        int prot = PROT_READ | PROT_EXEC;
        if (sec[si].Characteristics & IMAGE_SCN_MEM_WRITE) prot |= PROT_WRITE;
        ERR("iOS: eager JIT-copy section %.8s (addr=%p size=0x%lx)\n",
            sec[si].Name, sec_addr, (unsigned long)sec_size);
        mprotect_exec(sec_addr, sec_size, prot);
    }
    /* iOS: data sections were mapped MAP_PRIVATE + PROT_READ|PROT_WRITE
     * (see map_file_into_view) so they're already mprotect-able. No
     * post-hoc fixup needed. */
#endif

done:
    free( sections );
    return status;
}


/***********************************************************************
 *             get_mapping_info
 */
static unsigned int get_mapping_info( HANDLE handle, ACCESS_MASK access, unsigned int *sec_flags,
                                      mem_size_t *full_size, HANDLE *shared_file,
                                      struct pe_image_info **info, UNICODE_STRING *nt_name,
                                      ANSI_STRING *exp_name )
{
    struct pe_image_info *image_info;
    SIZE_T namelen, total, size = 1024;
    unsigned int status;

    for (;;)
    {
        if (!(image_info = malloc( size ))) return STATUS_NO_MEMORY;

        SERVER_START_REQ( get_mapping_info )
        {
            req->handle = wine_server_obj_handle( handle );
            req->access = access;
            wine_server_set_reply( req, image_info, size );
            status = wine_server_call( req );
            *sec_flags   = reply->flags;
            *full_size   = reply->size;
            namelen      = reply->name_len;
            total        = reply->total;
            *shared_file = wine_server_ptr_handle( reply->shared_file );
        }
        SERVER_END_REQ;
        if (!status && total <= size) break;
        free( image_info );
        if (status) return status;
        if (*shared_file) NtClose( *shared_file );
        size = total;
    }

    if (total)
    {
        assert( total >= sizeof(*image_info) );
        total -= sizeof(*image_info);
        nt_name->Buffer = (WCHAR *)(image_info + 1);
        nt_name->Length = nt_name->MaximumLength = namelen;
        exp_name->Buffer = (char *)nt_name->Buffer + namelen;
        exp_name->Length = exp_name->MaximumLength = total - namelen;
        *info = image_info;
    }
    else free( image_info );

    return STATUS_SUCCESS;
}


/***********************************************************************
 *             map_image_view
 *
 * Map a view for a PE image at an appropriate address.
 */
static NTSTATUS map_image_view( struct file_view **view_ret, struct pe_image_info *image_info, SIZE_T size,
                                ULONG_PTR limit_low, ULONG_PTR limit_high, ULONG alloc_type )
{
    unsigned int vprot = SEC_IMAGE | SEC_FILE | VPROT_COMMITTED | VPROT_READ | VPROT_EXEC | VPROT_WRITECOPY;
    void *base;
    NTSTATUS status;
    ULONG_PTR start, end;
    BOOL top_down = (image_info->image_charact & IMAGE_FILE_DLL) &&
                    (image_info->image_flags & IMAGE_FLAGS_ImageDynamicallyRelocated);

    limit_low = max( limit_low, (ULONG_PTR)address_space_start );  /* make sure the DOS area remains free */
    /* task #35 furniture ceiling: images pack below it (inclusive limit).
     * Disabled while ios_furniture_ceiling == 0 — see its definition. */
    if (!limit_high)
        limit_high = ios_furniture_ceiling ? min( (ULONG_PTR)user_space_limit, ios_furniture_ceiling - 1 )
                                           : (ULONG_PTR)user_space_limit;

    /* first try the specified base */

    if (image_info->map_addr)
    {
        base = wine_server_get_ptr( image_info->map_addr );
        if ((ULONG_PTR)base != image_info->map_addr) base = NULL;
    }
    else
    {
        base = wine_server_get_ptr( image_info->base );
        if ((ULONG_PTR)base != image_info->base) base = NULL;
    }
    if (base)
    {
        status = map_view( view_ret, base, size, alloc_type, vprot, limit_low, limit_high, 0 );
        if (!status) return status;
    }

    /* then some appropriate address range */

    if (image_info->base >= limit_4g)
    {
        start = max( limit_low, limit_4g );
        end = limit_high;
    }
    else
    {
        start = limit_low;
        end = min( limit_high, get_wow_user_space_limit() );
    }
    if (start < end && (start != limit_low || end != limit_high))
    {
        status = map_view( view_ret, NULL, size, top_down ? MEM_TOP_DOWN : 0, vprot, start, end, 0 );
        if (!status) return status;
    }

    /* then any suitable address */

    return map_view( view_ret, NULL, size, top_down ? MEM_TOP_DOWN : 0, vprot, limit_low, limit_high, 0 );
}


/***********************************************************************
 *             virtual_map_image
 *
 * Map a PE image section into memory.
 */
static NTSTATUS virtual_map_image( HANDLE mapping, void **addr_ptr, SIZE_T *size_ptr, HANDLE shared_file,
                                   ULONG_PTR limit_low, ULONG_PTR limit_high, ULONG alloc_type,
                                   USHORT machine, struct pe_image_info *image_info,
                                   UNICODE_STRING *nt_name, BOOL is_builtin, off_t offset)
{
    int unix_fd = -1, needs_close;
    int shared_fd = -1, shared_needs_close = 0;
    SIZE_T size = image_info->map_size;
    struct file_view *view;
    unsigned int status;
    sigset_t sigset;

    if (offset >= size)
        return STATUS_INVALID_PARAMETER;

    if ((status = server_get_unix_fd( mapping, 0, &unix_fd, &needs_close, NULL, NULL )))
        return status;

    if (shared_file && ((status = server_get_unix_fd( shared_file, FILE_READ_DATA|FILE_WRITE_DATA,
                                                      &shared_fd, &shared_needs_close, NULL, NULL ))))
    {
        if (needs_close) close( unix_fd );
        return status;
    }

    if (!image_info->map_addr &&
        (image_info->image_charact & IMAGE_FILE_DLL) &&
        (image_info->image_flags & IMAGE_FLAGS_ImageDynamicallyRelocated))
    {
        SERVER_START_REQ( get_image_map_address )
        {
            req->handle = wine_server_obj_handle( mapping );
            if (!wine_server_call( req )) image_info->map_addr = reply->addr;
        }
        SERVER_END_REQ;
    }

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );

    status = map_image_view( &view, image_info, size, limit_low, limit_high, alloc_type );
    /* ml366: NAME the image whose placement failed. ml365's mmdevapi load
     * returned c0000017 with zero attributable evidence — the [va-scan]
     * FAILED line was storm-gated and nothing tied a placement failure to a
     * DLL. One line here closes that gap for every future load failure. */
    if (status)
    {
        static unsigned imgfail;
        if (imgfail++ < 64)
            ERR( "[img-map-fail] rev=ml366 %s status=%x size=%zx limits=%lx..%lx\n",
                 nt_name ? debugstr_us(nt_name) : "?", status, (size_t)size,
                 (unsigned long)limit_low, (unsigned long)limit_high );
        goto done;
    }
    status = map_image_into_view( view, nt_name, unix_fd, image_info, machine, shared_fd, needs_close );
    if (status == STATUS_SUCCESS)
    {
        if (offset)
        {
            free_pages( view, view->base, offset );
            size -= offset;
        }

        image_info->base = wine_server_client_ptr( view->base );
        SERVER_START_REQ( map_image_view )
        {
            req->mapping = wine_server_obj_handle( mapping );
            req->base    = image_info->base;
            req->size    = size;
            req->entry   = image_info->entry_point;
            req->machine = image_info->machine;
            req->offset  = offset;
            status = wine_server_call( req );
        }
        SERVER_END_REQ;
    }
    if (NT_SUCCESS(status))
    {
#ifdef WINE_IOS
        ERR("iOS virtual_map_image: view=%p is_builtin=%d offset=%ld\n",
            view->base, is_builtin, (long)offset);
#endif
        if (is_builtin && !offset) add_builtin_module( view->base, NULL );
#ifdef WINE_IOS
        /* For builtin images on iOS: eagerly trigger the JIT copy for each
         * EXEC section. Normally Wine relies on an mprotect(PROT_EXEC) call
         * from somewhere downstream to activate section execution, but for
         * our main .exe that path isn't hit (sections are mapped via
         * PROT_READ|PROT_WRITECOPY and no subsequent protect flips them to
         * EXEC). Without the JIT copy, triangle.exe's .text isn't executable
         * and we bus-fault on its first instruction.
         */
        if (is_builtin && !offset)
        {
            IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)view->base;
            if (dos && dos->e_magic == IMAGE_DOS_SIGNATURE)
            {
                IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)((char *)view->base + dos->e_lfanew);
                if (nt->Signature == IMAGE_NT_SIGNATURE)
                {
                    IMAGE_SECTION_HEADER *s = IMAGE_FIRST_SECTION(nt);
                    SIZE_T align_mask = max(image_info->alignment - 1, page_mask);
                    for (int i = 0; i < nt->FileHeader.NumberOfSections; i++)
                    {
                        if (!(s[i].Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
                        SIZE_T sec_size = s[i].Misc.VirtualSize
                            ? ROUND_SIZE(s[i].VirtualAddress, s[i].Misc.VirtualSize, align_mask)
                            : ROUND_SIZE(s[i].VirtualAddress, s[i].SizeOfRawData, align_mask);
                        void *sec_addr = (char *)view->base + s[i].VirtualAddress;
                        int prot = PROT_READ | PROT_EXEC;
                        if (s[i].Characteristics & IMAGE_SCN_MEM_WRITE) prot |= PROT_WRITE;
                        ERR("iOS: eager JIT-copy for builtin %s section (base=%p size=0x%lx)\n",
                            s[i].Name, sec_addr, (unsigned long)sec_size);
                        mprotect_exec(sec_addr, sec_size, prot);
                    }
                }
            }
        }
#endif
        *addr_ptr = view->base;
        *size_ptr = size;
        VIRTUAL_DEBUG_DUMP_VIEW( view );
    }
    else delete_view( view );

done:
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    if (needs_close) close( unix_fd );
    if (shared_needs_close) close( shared_fd );
    return status;
}


/***********************************************************************
 *             virtual_map_section
 *
 * Map a file section into memory.
 */
static unsigned int virtual_map_section( HANDLE handle, PVOID *addr_ptr, ULONG_PTR limit_low,
                                         ULONG_PTR limit_high, SIZE_T commit_size,
                                         const LARGE_INTEGER *offset_ptr, SIZE_T *size_ptr,
                                         ULONG alloc_type, ULONG protect, USHORT machine )
{
    unsigned int res;
    mem_size_t full_size;
    ACCESS_MASK access;
    SIZE_T size;
    struct pe_image_info *image_info = NULL;
    UNICODE_STRING nt_name;
    ANSI_STRING exp_name;
    void *base;
    int unix_handle = -1, needs_close;
    unsigned int vprot, sec_flags;
    struct file_view *view;
    HANDLE shared_file;
    LARGE_INTEGER offset;
    sigset_t sigset;

    switch(protect)
    {
    case PAGE_NOACCESS:
    case PAGE_READONLY:
    case PAGE_WRITECOPY:
        access = SECTION_MAP_READ;
        break;
    case PAGE_READWRITE:
        access = SECTION_MAP_WRITE;
        break;
    case PAGE_EXECUTE:
    case PAGE_EXECUTE_READ:
    case PAGE_EXECUTE_WRITECOPY:
        access = SECTION_MAP_READ | SECTION_MAP_EXECUTE;
        break;
    case PAGE_EXECUTE_READWRITE:
        access = SECTION_MAP_WRITE | SECTION_MAP_EXECUTE;
        break;
    default:
        return STATUS_INVALID_PAGE_PROTECTION;
    }

    res = get_mapping_info( handle, access, &sec_flags, &full_size, &shared_file,
                            &image_info, &nt_name, &exp_name );
    if (res)
    {
        dprintf(2, "[map-sec] get_mapping_info handle=%p access=0x%x -> 0x%x\n",
                handle, (unsigned)access, res);
        return res;
    }

    offset.QuadPart = offset_ptr ? offset_ptr->QuadPart : 0;

    if (image_info)
    {
        SECTION_IMAGE_INFORMATION info;
        ULONG64 prev = 0;

        if (NtCurrentTeb64())
        {
            prev = NtCurrentTeb64()->Tib.ArbitraryUserPointer;
            NtCurrentTeb64()->Tib.ArbitraryUserPointer = PtrToUlong(NtCurrentTeb()->Tib.ArbitraryUserPointer);
        }
        /* check if we can replace that mapping with the builtin */
        res = load_builtin( image_info, &nt_name, &exp_name, machine, &info,
                            addr_ptr, size_ptr, limit_low, limit_high, offset.QuadPart );
        if (res == STATUS_IMAGE_ALREADY_LOADED)
            res = virtual_map_image( handle, addr_ptr, size_ptr, shared_file, limit_low, limit_high,
                                     alloc_type, machine, image_info, &nt_name, FALSE, offset.QuadPart );
        if (shared_file) NtClose( shared_file );
        free( image_info );
        if (NtCurrentTeb64()) NtCurrentTeb64()->Tib.ArbitraryUserPointer = prev;
        return res;
    }

    base = *addr_ptr;
    if (offset.QuadPart >= full_size) return STATUS_INVALID_PARAMETER;
    if (*size_ptr)
    {
        size = *size_ptr;
        if (size > full_size - offset.QuadPart) return STATUS_INVALID_VIEW_SIZE;
    }
    else
    {
        size = full_size - offset.QuadPart;
        if (size != full_size - offset.QuadPart)  /* truncated */
        {
            WARN( "Files larger than 4Gb (%s) not supported on this platform\n",
                  wine_dbgstr_longlong(full_size) );
            return STATUS_INVALID_PARAMETER;
        }
    }
    if (!(size = ROUND_SIZE( 0, size, page_mask ))) return STATUS_INVALID_PARAMETER;  /* wrap-around */

    get_vprot_flags( protect, &vprot, FALSE );
    vprot |= sec_flags;
    if (!(sec_flags & SEC_RESERVE)) vprot |= VPROT_COMMITTED;

    if ((res = server_get_unix_fd( handle, 0, &unix_handle, &needs_close, NULL, NULL )))
    {
        dprintf(2, "[map-sec] server_get_unix_fd handle=%p -> 0x%x\n", handle, res);
        return res;
    }

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );

    res = map_view( &view, base, size, alloc_type, vprot, limit_low, limit_high, 0 );
    if (res) goto done;

    TRACE( "handle=%p size=%lx offset=%s\n", handle, size, wine_dbgstr_longlong(offset.QuadPart) );
    /* iOS: SEC_COMMIT shared sections (e.g. \KernelObjects\__wine_session) need
     * MAP_SHARED so the client view is coherent with wineserver writes. The
     * for_image=FALSE override tells map_file_into_view_ex to take the shared
     * path (default for_image=TRUE preserves PE-image MAP_PRIVATE behavior). */
    res = map_file_into_view_ex( view, unix_handle, 0, size, offset.QuadPart, vprot, needs_close, FALSE );
    if (res == STATUS_SUCCESS)
    {
        /* file mappings must always be accessible */
        mprotect_range( view->base, view->size, VPROT_COMMITTED, 0 );

        SERVER_START_REQ( map_view )
        {
            req->mapping = wine_server_obj_handle( handle );
            req->access  = access;
            req->base    = wine_server_client_ptr( view->base );
            req->size    = size;
            req->start   = offset.QuadPart;
            res = wine_server_call( req );
        }
        SERVER_END_REQ;
    }
    else ERR( "mapping %p %lx %s failed\n", view->base, size, wine_dbgstr_longlong(offset.QuadPart) );

    if (NT_SUCCESS(res))
    {
        *addr_ptr = view->base;
        *size_ptr = size;
        VIRTUAL_DEBUG_DUMP_VIEW( view );
    }
    else delete_view( view );

done:
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    if (needs_close) close( unix_handle );
    if (res) dprintf(2, "[map-sec] virtual_map_section handle=%p prot=0x%x size=%p -> 0x%x\n",
                     handle, (unsigned)protect, (void *)size, res);
    return res;
}


/* allocate some space for the virtual heap, if possible from a reserved area */
static void *alloc_virtual_heap( SIZE_T size )
{
    struct reserved_area *area;
    void *ret;

    size = ROUND_SIZE( 0, size, host_page_mask );

    LIST_FOR_EACH_ENTRY_REV( area, &reserved_areas, struct reserved_area, entry )
    {
        void *base = area->base;
        void *end = (char *)base + area->size;

        if (is_beyond_limit( base, area->size, address_space_limit ))
            address_space_limit = host_addr_space_limit = end;
        if (is_win64 && base < (void *)0x80000000) break;
        if (preload_reserve_end >= end)
        {
            if (preload_reserve_start <= base) continue;  /* no space in that area */
            if (preload_reserve_start < end) end = preload_reserve_start;
        }
        else if (preload_reserve_end > base)
        {
            if (preload_reserve_start <= base) base = preload_reserve_end;
            else if ((char *)end - (char *)preload_reserve_end >= size) base = preload_reserve_end;
            else end = preload_reserve_start;
        }
        if ((char *)end - (char *)base < size) continue;
        ret = anon_mmap_fixed( (char *)end - size, size, PROT_READ | PROT_WRITE, 0 );
        if (ret == MAP_FAILED) continue;
        mmap_remove_reserved_area( ret, size );
        return ret;
    }
    return anon_mmap_alloc( size, PROT_READ | PROT_WRITE );
}

/***********************************************************************
 *           virtual_init
 */
void virtual_init(void)
{
    const struct preload_info **preload_info = dlsym( RTLD_DEFAULT, "wine_main_preload_info" );
    const char *preload;
    size_t size;
    int i;
    pthread_mutexattr_t attr;

    pthread_mutexattr_init( &attr );
    pthread_mutexattr_settype( &attr, PTHREAD_MUTEX_RECURSIVE );
    pthread_mutex_init( &virtual_mutex, &attr );
    pthread_mutexattr_destroy( &attr );

#ifdef __aarch64__
    host_page_size = sysconf( _SC_PAGESIZE );
    host_page_mask = host_page_size - 1;
    TRACE( "host page size: %uk\n", (UINT)host_page_size / 1024 );
#endif

#ifdef _WIN64
    host_addr_space_limit = get_host_addr_space_limit();
    TRACE( "host addr space limit: %p\n", host_addr_space_limit );
    /* ml749: unconditional -- this must be present in the log of the run that
     * FAILS, and a failing run is exactly when nobody thought to arm a flag. */
    ios_va_profile( "post-limit" );
#else
    host_addr_space_limit = address_space_limit;
#endif

    kernel_writewatch_init();

    if (preload_info && *preload_info)
        for (i = 0; (*preload_info)[i].size; i++)
            mmap_add_reserved_area( (*preload_info)[i].addr, (*preload_info)[i].size );

    mmap_init( preload_info ? *preload_info : NULL );

    if ((preload = getenv("WINEPRELOADRESERVE")))
    {
        unsigned long start, end;
        if (sscanf( preload, "%lx-%lx", &start, &end ) == 2)
        {
            preload_reserve_start = ROUND_ADDR( start, host_page_mask );
            preload_reserve_end = (void *)ROUND_SIZE( 0, end, host_page_mask );
            /* some apps start inside the DOS area */
            if (preload_reserve_start)
                address_space_start = min( address_space_start, preload_reserve_start );
        }
        unsetenv( "WINEPRELOADRESERVE" );
    }

    /* try to find space in a reserved area for the views and pages protection table */
#ifdef _WIN64
    pages_vprot_size = ((size_t)host_addr_space_limit >> page_shift >> pages_vprot_shift) + 1;
    size = 2 * view_block_size + pages_vprot_size * sizeof(*pages_vprot);
#else
    size = 2 * view_block_size + (1U << (32 - page_shift));
#endif
    view_block_start = alloc_virtual_heap( size );
    assert( view_block_start != MAP_FAILED );
    view_block_end = view_block_start + view_block_size / sizeof(*view_block_start);
    free_ranges = (void *)((char *)view_block_start + view_block_size);
    pages_vprot = (void *)((char *)view_block_start + 2 * view_block_size);
    wine_rb_init( &views_tree, compare_view );

    free_ranges[0].base = (void *)0;
    free_ranges[0].end = (void *)~0;
    free_ranges_end = free_ranges + 1;

    /* make the DOS area accessible (except the low 64K) to hide bugs in broken apps like Excel 2003 */
    size = (char *)address_space_start - (char *)0x10000;
    if (size && mmap_is_in_reserved_area( (void*)0x10000, size ) == 1)
        anon_mmap_fixed( (void *)0x10000, size, PROT_READ | PROT_WRITE, 0 );

    /* ml433 (#72): hold back the only 8GB-aligned stretch in the guest band
     * before top-down placement can put furniture in it — see IOS_CAGE_BASE. */
    if (anon_mmap_fixed( (void *)(uintptr_t)IOS_CAGE_BASE, IOS_CAGE_REAL_SIZE, PROT_NONE, 0 ) != MAP_FAILED)
    {
        ios_cage_holdback_live = 1;
        dprintf( 2, "[cage] holdback reserved 0x%llx+0x%llx rev=ml433\n",
                 (unsigned long long)IOS_CAGE_BASE, (unsigned long long)IOS_CAGE_REAL_SIZE );
    }
    else dprintf( 2, "[cage] holdback reserve FAILED (errno %d) rev=ml433\n", errno );
}


/***********************************************************************
 *           get_system_affinity_mask
 */
ULONG_PTR get_system_affinity_mask(void)
{
    ULONG num_cpus = peb->NumberOfProcessors;
    if (num_cpus >= sizeof(ULONG_PTR) * 8) return ~(ULONG_PTR)0;
    return ((ULONG_PTR)1 << num_cpus) - 1;
}

/***********************************************************************
 *           virtual_get_system_info
 */
void virtual_get_system_info( SYSTEM_BASIC_INFORMATION *info, BOOL wow64 )
{
#if defined(HAVE_SYSINFO) \
    && defined(HAVE_STRUCT_SYSINFO_TOTALRAM) && defined(HAVE_STRUCT_SYSINFO_MEM_UNIT)
    struct sysinfo sinfo;

    if (!sysinfo(&sinfo))
    {
        ULONG64 total = (ULONG64)sinfo.totalram * sinfo.mem_unit;
        info->MmHighestPhysicalPage = max(1, total / page_size);
    }
#elif defined(__APPLE__)
    /* sysconf(_SC_PHYS_PAGES) is buggy on macOS: in a 32-bit process, it
     * returns an error on Macs with >4GB of RAM.
     */
    INT64 memsize;
    size_t len = sizeof(memsize);

    if (!sysctlbyname( "hw.memsize", &memsize, &len, NULL, 0 ))
        info->MmHighestPhysicalPage = max(1, memsize / page_size);
#elif defined(_SC_PHYS_PAGES)
    LONG64 phys_pages = sysconf( _SC_PHYS_PAGES );

    info->MmHighestPhysicalPage = max(1, phys_pages);
#else
    info->MmHighestPhysicalPage = 0x7fffffff / page_size;
#endif

    info->unknown                 = 0;
    info->KeMaximumIncrement      = 0;  /* FIXME */
    info->PageSize                = page_size;
    info->MmLowestPhysicalPage    = 1;
    info->MmNumberOfPhysicalPages = info->MmHighestPhysicalPage - info->MmLowestPhysicalPage;
    info->AllocationGranularity   = granularity_mask + 1;
    info->LowestUserAddress       = (void *)0x10000;
    info->ActiveProcessorsAffinityMask = get_system_affinity_mask();
    info->NumberOfProcessors      = peb->NumberOfProcessors;
    if (wow64) info->HighestUserAddress = (char *)get_wow_user_space_limit() - 1;
    else info->HighestUserAddress = (char *)user_space_limit - 1;
}


/***********************************************************************
 *           virtual_map_builtin_module
 */
NTSTATUS virtual_map_builtin_module( HANDLE mapping, void **module, SIZE_T *size,
                                     SECTION_IMAGE_INFORMATION *info, ULONG_PTR limit_low,
                                     ULONG_PTR limit_high, WORD machine, BOOL prefer_native, off_t offset )
{
    mem_size_t full_size;
    unsigned int sec_flags;
    HANDLE shared_file;
    struct pe_image_info *image_info = NULL;
    NTSTATUS status;
    UNICODE_STRING nt_name;
    ANSI_STRING exp_name;

    if ((status = get_mapping_info( mapping, SECTION_MAP_READ, &sec_flags, &full_size, &shared_file,
                                    &image_info, &nt_name, &exp_name )))
        return status;

    if (!image_info) return STATUS_INVALID_PARAMETER;

    *module = NULL;
    *size = 0;

    if (!image_info->wine_builtin) /* ignore non-builtins */
    {
        if (!image_info->wine_fakedll)
            WARN_(module)( "%s found in WINEDLLPATH but not a builtin, ignoring\n", debugstr_us(&nt_name) );
        status = STATUS_DLL_NOT_FOUND;
    }
    else if (prefer_native && (image_info->dll_charact & IMAGE_DLLCHARACTERISTICS_PREFER_NATIVE))
    {
        TRACE_(module)( "%s has prefer-native flag, ignoring builtin\n", debugstr_us(&nt_name) );
        status = STATUS_IMAGE_ALREADY_LOADED;
    }
    else
    {
        status = virtual_map_image( mapping, module, size, shared_file, limit_low, limit_high, 0,
                                    machine, image_info, &nt_name, TRUE, offset );
        virtual_fill_image_information( image_info, info );
    }

    if (shared_file) NtClose( shared_file );
    free( image_info );
    return status;
}


/***********************************************************************
 *           virtual_map_module
 */
NTSTATUS virtual_map_module( HANDLE mapping, void **module, SIZE_T *size, SECTION_IMAGE_INFORMATION *info,
                             ULONG_PTR limit_low, ULONG_PTR limit_high, USHORT machine )
{
    unsigned int status;
    mem_size_t full_size;
    unsigned int sec_flags;
    HANDLE shared_file;
    struct pe_image_info *image_info = NULL;
    UNICODE_STRING nt_name;
    ANSI_STRING exp_name;

    if ((status = get_mapping_info( mapping, SECTION_MAP_READ, &sec_flags, &full_size, &shared_file,
                                    &image_info, &nt_name, &exp_name )))
        return status;

    if (!image_info) return STATUS_INVALID_PARAMETER;

    *module = NULL;
    *size = 0;

    /* check if we can replace that mapping with the builtin */
    status = load_builtin( image_info, &nt_name, &exp_name, machine, info,
                           module, size, limit_low, limit_high, 0 );
    if (status == STATUS_IMAGE_ALREADY_LOADED)
    {
        status = virtual_map_image( mapping, module, size, shared_file, limit_low, limit_high, 0,
                                    machine, image_info, &nt_name, FALSE, 0 );
        virtual_fill_image_information( image_info, info );
    }
    if (shared_file) NtClose( shared_file );
    free( image_info );
    return status;
}


/***********************************************************************
 *           virtual_create_builtin_view
 */
NTSTATUS virtual_create_builtin_view( void *module, const UNICODE_STRING *nt_name,
                                      struct pe_image_info *info, void *so_handle )
{
    NTSTATUS status;
    sigset_t sigset;
    IMAGE_DOS_HEADER *dos = module;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)((char *)dos + dos->e_lfanew);
    SIZE_T size = info->map_size;
    IMAGE_SECTION_HEADER *sec;
    struct file_view *view;
    void *base = wine_server_get_ptr( info->base );
    int i;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    status = create_view( &view, base, size, SEC_IMAGE | SEC_FILE | VPROT_SYSTEM |
                          VPROT_COMMITTED | VPROT_READ | VPROT_WRITECOPY | VPROT_EXEC );
    if (!status)
    {
        TRACE( "created %p-%p for %s\n", base, (char *)base + size, debugstr_us(nt_name) );

        /* The PE header is always read-only, no write, no execute. */
        set_page_vprot( base, page_size, VPROT_COMMITTED | VPROT_READ );

        sec = IMAGE_FIRST_SECTION( nt );
        for (i = 0; i < nt->FileHeader.NumberOfSections; i++)
        {
            BYTE flags = VPROT_COMMITTED;

            if (sec[i].Characteristics & IMAGE_SCN_MEM_EXECUTE) flags |= VPROT_EXEC;
            if (sec[i].Characteristics & IMAGE_SCN_MEM_READ) flags |= VPROT_READ;
            if (sec[i].Characteristics & IMAGE_SCN_MEM_WRITE) flags |= VPROT_WRITE;
            set_page_vprot( (char *)base + sec[i].VirtualAddress, sec[i].Misc.VirtualSize, flags );
        }

        SERVER_START_REQ( map_builtin_view )
        {
            wine_server_add_data( req, info, sizeof(*info) );
            wine_server_add_data( req, nt_name->Buffer, nt_name->Length );
            status = wine_server_call( req );
        }
        SERVER_END_REQ;

        if (!status)
        {
            add_builtin_module( view->base, so_handle );
            VIRTUAL_DEBUG_DUMP_VIEW( view );
            if (is_beyond_limit( base, size, working_set_limit )) working_set_limit = address_space_limit;
        }
        else delete_view( view );
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );

    return status;
}


/***********************************************************************
 *           virtual_relocate_module
 */
NTSTATUS virtual_relocate_module( void *module )
{
    char *ptr = module;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(ptr + ((IMAGE_DOS_HEADER *)module)->e_lfanew);
    IMAGE_DATA_DIRECTORY *relocs;
    IMAGE_BASE_RELOCATION *rel, *end;
    IMAGE_SECTION_HEADER *sec;
    ULONG total_size = ROUND_SIZE( 0, nt->OptionalHeader.SizeOfImage, page_mask );
    ULONG *protect_old, i;
    ULONG_PTR image_base;
    INT_PTR delta;

    if (nt->OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC)
        image_base = ((const IMAGE_NT_HEADERS64 *)nt)->OptionalHeader.ImageBase;
    else
        image_base = ((const IMAGE_NT_HEADERS32 *)nt)->OptionalHeader.ImageBase;


    if (!(delta = (ULONG_PTR)module - image_base)) return STATUS_SUCCESS;

    if (nt->FileHeader.Characteristics & IMAGE_FILE_RELOCS_STRIPPED)
    {
        ERR( "Need to relocate module from %p to %p, but relocation records are stripped\n",
             (void *)image_base, module );
        return STATUS_CONFLICTING_ADDRESSES;
    }

    TRACE( "%p -> %p\n", (void *)image_base, module );

    if (!(relocs = get_data_dir( nt, total_size, IMAGE_DIRECTORY_ENTRY_BASERELOC ))) return STATUS_SUCCESS;

    if (!(protect_old = malloc( nt->FileHeader.NumberOfSections * sizeof(*protect_old ))))
        return STATUS_NO_MEMORY;

    sec = IMAGE_FIRST_SECTION( nt );
    for (i = 0; i < nt->FileHeader.NumberOfSections; i++)
    {
        void *addr = (char *)module + sec[i].VirtualAddress;
        SIZE_T size = sec[i].SizeOfRawData;
        NtProtectVirtualMemory( NtCurrentProcess(), &addr, &size, PAGE_READWRITE, &protect_old[i] );
    }


    rel = (IMAGE_BASE_RELOCATION *)((char *)module + relocs->VirtualAddress);
    end = (IMAGE_BASE_RELOCATION *)((char *)rel + relocs->Size);

    while (rel && rel < end - 1 && rel->SizeOfBlock && rel->VirtualAddress < total_size)
        rel = process_relocation_block( (char *)module + rel->VirtualAddress, rel, delta );

    for (i = 0; i < nt->FileHeader.NumberOfSections; i++)
    {
        void *addr = (char *)module + sec[i].VirtualAddress;
        SIZE_T size = sec[i].SizeOfRawData;
        NtProtectVirtualMemory( NtCurrentProcess(), &addr, &size, protect_old[i], &protect_old[i] );
    }
    free( protect_old );
    return STATUS_SUCCESS;
}


/* set some initial values in a new TEB */
static TEB *init_teb( void *ptr, BOOL is_wow )
{
    struct ntdll_thread_data *thread_data;
    TEB *teb;
    TEB64 *teb64 = ptr;
    TEB32 *teb32 = (TEB32 *)((char *)ptr + teb_offset);

#ifdef _WIN64
    teb = (TEB *)teb64;
    teb32->Peb = PtrToUlong( (char *)peb + page_size );
    teb32->Tib.Self = PtrToUlong( teb32 );
    teb32->Tib.ExceptionList = ~0u;
    teb32->ActivationContextStackPointer = PtrToUlong( &teb32->ActivationContextStack );
    teb32->ActivationContextStack.FrameListCache.Flink =
        teb32->ActivationContextStack.FrameListCache.Blink =
            PtrToUlong( &teb32->ActivationContextStack.FrameListCache );
    teb32->StaticUnicodeString.Buffer = PtrToUlong( teb32->StaticUnicodeBuffer );
    teb32->StaticUnicodeString.MaximumLength = sizeof( teb32->StaticUnicodeBuffer );
    teb32->GdiBatchCount = PtrToUlong( teb64 );
    teb32->WowTebOffset  = -teb_offset;
    if (is_wow) teb64->WowTebOffset = teb_offset;
#else
    teb = (TEB *)teb32;
    teb32->Tib.ExceptionList = ~0u;
    teb64->Peb = PtrToUlong( (char *)peb - page_size );
    teb64->Tib.Self = PtrToUlong( teb64 );
    teb64->Tib.ExceptionList = PtrToUlong( teb32 );
    teb64->ActivationContextStackPointer = PtrToUlong( &teb64->ActivationContextStack );
    teb64->ActivationContextStack.FrameListCache.Flink =
        teb64->ActivationContextStack.FrameListCache.Blink =
            PtrToUlong( &teb64->ActivationContextStack.FrameListCache );
    teb64->StaticUnicodeString.Buffer = PtrToUlong( teb64->StaticUnicodeBuffer );
    teb64->StaticUnicodeString.MaximumLength = sizeof( teb64->StaticUnicodeBuffer );
    teb64->WowTebOffset = teb_offset;
    if (is_wow)
    {
        teb32->GdiBatchCount = PtrToUlong( teb64 );
        teb32->WowTebOffset  = -teb_offset;
    }
#endif
    teb->Peb = peb;
#ifdef WINE_IOS
    /* S1 pseudo-processes: a new thread belongs to its CREATOR's process.
     * The global `peb` is switched (permanently) to the child's PEB during
     * a child spawn, so parent threads created afterwards must not inherit
     * it. ios_jit_current_peb() resolves the creating thread's PEB and is
     * NULL-safe during early boot (falls back to the global). */
    {
        extern void *ios_jit_current_peb(void);
        void *creator_peb = ios_jit_current_peb();
        if (creator_peb) teb->Peb = creator_peb;
    }
#endif
    teb->Tib.Self = &teb->Tib;
    teb->Tib.StackBase = (void *)~0ul;
    teb->ActivationContextStackPointer = &teb->ActivationContextStack;
    InitializeListHead( &teb->ActivationContextStack.FrameListCache );
    teb->StaticUnicodeString.Buffer = teb->StaticUnicodeBuffer;
    teb->StaticUnicodeString.MaximumLength = sizeof(teb->StaticUnicodeBuffer);
    thread_data = (struct ntdll_thread_data *)&teb->GdiTebBatch;
    thread_data->request_fd = -1;
    thread_data->reply_fd   = -1;
    thread_data->wait_fd[0] = -1;
    thread_data->wait_fd[1] = -1;
    thread_data->alert_fd   = -1;
    list_add_head( &teb_list, &thread_data->entry );
    return teb;
}


/***********************************************************************
 *           virtual_alloc_first_teb
 */
TEB *virtual_alloc_first_teb(void)
{
    void *ptr;
    TEB *teb;
    unsigned int status;
    SIZE_T data_size = page_size;
    SIZE_T block_size = signal_stack_mask + 1;
    SIZE_T total = 32 * block_size;

    /* reserve space for shared user data */
#ifdef WINE_IOS
    /* iOS arm64 has mandatory 4GB __PAGEZERO — can't map at 0x7ffe0000 */
    user_shared_data = NULL;
#endif
    status = NtAllocateVirtualMemory( NtCurrentProcess(), (void **)&user_shared_data, 0, &data_size,
                                      MEM_RESERVE | MEM_COMMIT, PAGE_READONLY );
    if (status)
    {
        ERR( "wine: failed to map the shared user data: %08x\n", status );
        exit(1);
    }

#ifdef WINE_IOS
    /* iOS 4GB __PAGEZERO blocks all addresses below 4GB — skip below-2GB constraint */
    NtAllocateVirtualMemory( NtCurrentProcess(), &teb_block, 0, &total,
                             MEM_RESERVE | MEM_TOP_DOWN, PAGE_READWRITE );
#else
    NtAllocateVirtualMemory( NtCurrentProcess(), &teb_block, is_win64 ? limit_2g - 1 : 0, &total,
                             MEM_RESERVE | MEM_TOP_DOWN, PAGE_READWRITE );
#endif
    teb_block_pos = 30;
    ptr = (char *)teb_block + 30 * block_size;
    data_size = 2 * block_size;
    NtAllocateVirtualMemory( NtCurrentProcess(), (void **)&ptr, 0, &data_size, MEM_COMMIT, PAGE_READWRITE );
    peb = (PEB *)((char *)teb_block + 31 * block_size + (is_win64 ? 0 : page_size));
    teb = init_teb( ptr, FALSE );
    pthread_key_create( &teb_key, NULL );
    pthread_setspecific( teb_key, teb );
    return teb;
}


/***********************************************************************
 *           virtual_alloc_teb
 */
NTSTATUS virtual_alloc_teb( TEB **ret_teb )
{
    sigset_t sigset;
    TEB *teb;
    void *ptr = NULL;
    NTSTATUS status = STATUS_SUCCESS;
    SIZE_T block_size = signal_stack_mask + 1;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if (next_free_teb)
    {
        ptr = next_free_teb;
        next_free_teb = *(void **)ptr;
        memset( ptr, 0, teb_size );
    }
    else
    {
        if (!teb_block_pos)
        {
            SIZE_T total = 32 * block_size;

            if ((status = NtAllocateVirtualMemory( NtCurrentProcess(), &ptr, user_space_wow_limit,
                                                   &total, MEM_RESERVE, PAGE_READWRITE )))
            {
                server_leave_uninterrupted_section( &virtual_mutex, &sigset );
                return status;
            }
            teb_block = ptr;
            teb_block_pos = 32;
        }
        ptr = ((char *)teb_block + --teb_block_pos * block_size);
        NtAllocateVirtualMemory( NtCurrentProcess(), (void **)&ptr, 0, &block_size,
                                 MEM_COMMIT, PAGE_READWRITE );
    }
    *ret_teb = teb = init_teb( ptr, is_wow64() );

    if ((status = signal_alloc_thread( teb )))
    {
        *(void **)ptr = next_free_teb;
        next_free_teb = ptr;
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return status;
}


/***********************************************************************
 *           virtual_free_teb
 */
void virtual_free_teb( TEB *teb )
{
    struct ntdll_thread_data *thread_data = (struct ntdll_thread_data *)&teb->GdiTebBatch;
    void *ptr;
    SIZE_T size;
    sigset_t sigset;
    WOW_TEB *wow_teb = get_wow_teb( teb );

    if (teb->DeallocationStack)
    {
        size = 0;
        NtFreeVirtualMemory( GetCurrentProcess(), &teb->DeallocationStack, &size, MEM_RELEASE );
    }
#ifdef __aarch64__
    if (teb->ChpeV2CpuAreaInfo)
    {
        size = 0;
        NtFreeVirtualMemory( GetCurrentProcess(), (void **)&teb->ChpeV2CpuAreaInfo, &size, MEM_RELEASE );
    }
#endif
    if (thread_data->kernel_stack)
    {
        size = 0;
        NtFreeVirtualMemory( GetCurrentProcess(), &thread_data->kernel_stack, &size, MEM_RELEASE );
    }
    if (wow_teb && (ptr = ULongToPtr( wow_teb->DeallocationStack )))
    {
        size = 0;
        NtFreeVirtualMemory( GetCurrentProcess(), &ptr, &size, MEM_RELEASE );
    }

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    signal_free_thread( teb );
    list_remove( &thread_data->entry );
    ptr = teb;
    if (!is_win64) ptr = (char *)ptr - teb_offset;
    *(void **)ptr = next_free_teb;
    next_free_teb = ptr;
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
}


/* LDT support */

#if defined(__i386__) || defined(__x86_64__)

struct ldt_copy
{
    unsigned int    base[LDT_SIZE];
    struct ldt_bits bits[LDT_SIZE];
};
C_ASSERT( sizeof(struct ldt_copy) == 8 * LDT_SIZE );

static struct ldt_copy *ldt_copy;

UINT ldt_bitmap[LDT_SIZE / 32] = { ~0u };

/***********************************************************************
 *           ldt_update_entry
 */
WORD ldt_update_entry( WORD sel, LDT_ENTRY entry )
{
    unsigned int index = sel >> 3;

    if (!ldt_copy)
    {
        struct file_view *view;

#ifdef WINE_IOS
        if (map_view( &view, NULL, sizeof(*ldt_copy), MEM_TOP_DOWN,
                      VPROT_COMMITTED | VPROT_READ | VPROT_WRITE,
                      0, 0, 0 )) return 0;
#else
        if (map_view( &view, NULL, sizeof(*ldt_copy), MEM_TOP_DOWN,
                      VPROT_COMMITTED | VPROT_READ | VPROT_WRITE,
                      is_win64 ? limit_2g : 0, limit_4g, 0 )) return 0;
#endif
        ldt_copy = view->base;
        if (is_win64) wow_peb->SpareUlongs[0] = PtrToUlong( ldt_copy );
        else peb->SpareUlongs[0] = PtrToUlong( ldt_copy );
    }

    ldt_set_entry( sel, entry );
    ldt_copy->base[index]             = ldt_get_base( entry );
    ldt_copy->bits[index].limit       = entry.LimitLow | (entry.HighWord.Bits.LimitHi << 16);
    ldt_copy->bits[index].type        = entry.HighWord.Bits.Type;
    ldt_copy->bits[index].granularity = entry.HighWord.Bits.Granularity;
    ldt_copy->bits[index].default_big = entry.HighWord.Bits.Default_Big;
    ldt_bitmap[index / 32] |= 1u << (index & 31);
    return sel;
}

/***********************************************************************
 *           ldt_get_entry
 */
NTSTATUS ldt_get_entry( WORD sel, CLIENT_ID client_id, LDT_ENTRY *entry )
{
    NTSTATUS status = STATUS_SUCCESS;
    unsigned int base = 0;
    struct ldt_bits bits = { 0 };
    unsigned int idx = sel >> 3;

    if (client_id.UniqueProcess == NtCurrentTeb()->ClientId.UniqueProcess)
    {
        if (ldt_copy)
        {
            base = ldt_copy->base[idx];
            bits = ldt_copy->bits[idx];
        }
    }
    else
    {
        HANDLE process;
        ULONG ptr = 0;
        PEB32 *peb32 = NULL;

        if ((status = NtOpenProcess( &process, PROCESS_ALL_ACCESS, NULL, &client_id ))) return status;

        if (!is_win64)
        {
            PROCESS_BASIC_INFORMATION pbi;

            NtQueryInformationProcess( process, ProcessBasicInformation, &pbi, sizeof(pbi), NULL );
            peb32 = (PEB32 *)pbi.PebBaseAddress;
        }
        else NtQueryInformationProcess( process, ProcessWow64Information, &peb32, sizeof(peb32), NULL );

        if (!NtReadVirtualMemory( process, &peb32->SpareUlongs[0], &ptr, sizeof(ptr), NULL ) && ptr)
        {
            struct ldt_copy *ldt = ULongToPtr( ptr );
            NtReadVirtualMemory( process, &ldt->base[idx], &base, sizeof(base), NULL );
            NtReadVirtualMemory( process, &ldt->bits[idx], &bits, sizeof(bits), NULL );
        }
        NtClose( process );
    }

    if (base || bits.limit || bits.type) *entry = ldt_make_entry( base, bits );
    else status = STATUS_UNSUCCESSFUL;

    return status;
}

/******************************************************************************
 *           NtSetLdtEntries   (NTDLL.@)
 *           ZwSetLdtEntries   (NTDLL.@)
 */
NTSTATUS WINAPI NtSetLdtEntries( ULONG sel1, ULONG entry1_low, ULONG entry1_high, ULONG sel2, ULONG entry2_low, ULONG entry2_high )
{
    sigset_t sigset;
    union { LDT_ENTRY entry; ULONG ul[2]; } entry;

    if (is_win64 && !is_wow64()) return STATUS_NOT_IMPLEMENTED;
    if (sel1 >> 16 || sel2 >> 16) return STATUS_INVALID_LDT_DESCRIPTOR;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if (sel1)
    {
        entry.ul[0] = entry1_low;
        entry.ul[1] = entry1_high;
        ldt_update_entry( sel1, entry.entry );
    }
    if (sel2)
    {
        entry.ul[0] = entry2_low;
        entry.ul[1] = entry2_high;
        ldt_update_entry( sel2, entry.entry );
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return STATUS_SUCCESS;
}

#else /* defined(__i386__) || defined(__x86_64__) */

/******************************************************************************
 *           NtSetLdtEntries   (NTDLL.@)
 *           ZwSetLdtEntries   (NTDLL.@)
 */
NTSTATUS WINAPI NtSetLdtEntries( ULONG sel1, ULONG entry1_low, ULONG entry1_high, ULONG sel2, ULONG entry2_low, ULONG entry2_high )
{
    return STATUS_NOT_IMPLEMENTED;
}

#endif /* defined(__i386__) || defined(__x86_64__) */


/***********************************************************************
 *           virtual_clear_tls_index
 */
NTSTATUS virtual_clear_tls_index( ULONG index )
{
    struct ntdll_thread_data *thread_data;
    sigset_t sigset;

    if (index < TLS_MINIMUM_AVAILABLE)
    {
        server_enter_uninterrupted_section( &virtual_mutex, &sigset );
        LIST_FOR_EACH_ENTRY( thread_data, &teb_list, struct ntdll_thread_data, entry )
        {
            TEB *teb = CONTAINING_RECORD( thread_data, TEB, GdiTebBatch );
#ifdef _WIN64
            WOW_TEB *wow_teb = get_wow_teb( teb );
            if (wow_teb) wow_teb->TlsSlots[index] = 0;
            else
#endif
            teb->TlsSlots[index] = 0;
        }
        server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    }
    else
    {
        index -= TLS_MINIMUM_AVAILABLE;
        if (index >= 8 * sizeof(peb->TlsExpansionBitmapBits)) return STATUS_INVALID_PARAMETER;

        server_enter_uninterrupted_section( &virtual_mutex, &sigset );
        LIST_FOR_EACH_ENTRY( thread_data, &teb_list, struct ntdll_thread_data, entry )
        {
            TEB *teb = CONTAINING_RECORD( thread_data, TEB, GdiTebBatch );
#ifdef _WIN64
            WOW_TEB *wow_teb = get_wow_teb( teb );
            if (wow_teb)
            {
                if (wow_teb->TlsExpansionSlots)
                    ((ULONG *)ULongToPtr( wow_teb->TlsExpansionSlots ))[index] = 0;
            }
            else
#endif
            if (teb->TlsExpansionSlots) teb->TlsExpansionSlots[index] = 0;
        }
        server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    }
    return STATUS_SUCCESS;
}


/***********************************************************************
 *           virtual_alloc_thread_stack
 */
NTSTATUS virtual_alloc_thread_stack( INITIAL_TEB *stack, ULONG_PTR limit_low, ULONG_PTR limit_high,
                                     SIZE_T reserve_size, SIZE_T commit_size, BOOL guard_page )
{
    struct file_view *view;
    NTSTATUS status;
    sigset_t sigset;
    SIZE_T size;

    {
        /* Owner-aware (X3): default stack sizes come from the calling
         * pseudo-process's main exe, not the session's. */
        extern const SECTION_IMAGE_INFORMATION *ios_cur_image_info(void);
        const SECTION_IMAGE_INFORMATION *ios_ii = ios_cur_image_info();
        if (!reserve_size) reserve_size = ios_ii->MaximumStackSize;
        if (!commit_size) commit_size = ios_ii->CommittedStackSize;
    }

    size = max( reserve_size, commit_size );
    if (size < 1024 * 1024) size = 1024 * 1024;  /* Xlib needs a large stack */
#ifdef WINE_IOS
    /* iOS-Madeira ml422 (#70): first CreateBrowser (ml421) died on a genuine
     * STACK_OVERFLOW — 256+ frames of libcef recursion ran a webhelper thread
     * stack dry. Chromium sizes its worker stacks for pure-x64 frames, but
     * under ARM64EC the emulated x64 frames interleave with native ARM64
     * frames (EC thunks, wine internals, our exception rethrows), which
     * consume MORE stack than the same call tree on real x64 Windows.
     * ml423: the 4MB floor was consumed too ([stack-ovf] reserve=0x400000) —
     * Chromium calibrates its renderer main threads for the 8MB Windows
     * default, so match it. Cost is VA only: the mapping is anonymous and
     * lazy, so untouched reserve pages never count against the 4096MB jetsam
     * footprint. If 8MB ALSO overflows, the [stack-ovf] three-window stack
     * fingerprint names the recursion cycle — chase that, not more size. */
    if (guard_page && size < 8 * 1024 * 1024)
    {
        static int floored;
        if (floored < 12 && ++floored <= 12)
            dprintf( 2, "[stack-floor] rev=ml424 #%d thread stack reserve 0x%lx -> 0x800000\n",
                     floored, (unsigned long)size );
        size = 8 * 1024 * 1024;
    }
#endif
    size = ROUND_SIZE( 0, size, granularity_mask );

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );

    status = map_view( &view, NULL, size, 0, VPROT_READ | VPROT_WRITE | VPROT_COMMITTED,
                       limit_low, limit_high, 0 );
    if (status != STATUS_SUCCESS) goto done;

#ifdef VALGRIND_STACK_REGISTER
    VALGRIND_STACK_REGISTER( view->base, (char *)view->base + view->size );
#endif

    /* setup no access guard page */
    if (guard_page)
    {
        set_page_vprot( view->base, host_page_size, 0 );
        set_page_vprot( (char *)view->base + host_page_size, host_page_size,
                        VPROT_READ | VPROT_WRITE | VPROT_COMMITTED | VPROT_GUARD );
        mprotect_range( view->base, 2 * host_page_size , 0, 0 );
    }
    VIRTUAL_DEBUG_DUMP_VIEW( view );

    /* note: limit is lower than base since the stack grows down */
    stack->OldStackBase = 0;
    stack->OldStackLimit = 0;
    stack->DeallocationStack = view->base;
    stack->StackBase = (char *)view->base + view->size;
    stack->StackLimit = (char *)view->base + (guard_page ? 2 * host_page_size : 0);
done:
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return status;
}


static const WCHAR shared_data_nameW[] = {'\\','K','e','r','n','e','l','O','b','j','e','c','t','s',
                                          '\\','_','_','w','i','n','e','_','u','s','e','r','_','s','h','a','r','e','d','_','d','a','t','a',0};

/***********************************************************************
 *           virtual_map_user_shared_data
 */
void virtual_map_user_shared_data(void)
{
    UNICODE_STRING name_str = RTL_CONSTANT_STRING( shared_data_nameW );
    OBJECT_ATTRIBUTES attr = { sizeof(attr), 0, &name_str };
    unsigned int status;
    HANDLE section;
    int res, fd, needs_close;

    if ((status = NtOpenSection( &section, SECTION_ALL_ACCESS, &attr )))
    {
        ERR( "failed to open the USD section: %08x\n", status );
        exit(1);
    }
    if ((res = server_get_unix_fd( section, 0, &fd, &needs_close, NULL, NULL )) ||
        (user_shared_data != mmap( user_shared_data, page_size, PROT_READ, MAP_SHARED|MAP_FIXED, fd, 0 )))
    {
        ERR( "failed to remap the process USD: %d\n", res );
        exit(1);
    }
    if (needs_close) close( fd );
    NtClose( section );
}


/******************************************************************
 *		virtual_init_user_shared_data
 *
 * Initialize user shared data before running wineboot.
 */
void virtual_init_user_shared_data(void)
{
    UNICODE_STRING name_str = RTL_CONSTANT_STRING( shared_data_nameW );
    OBJECT_ATTRIBUTES attr = { sizeof(attr), 0, &name_str };
    SYSTEM_BASIC_INFORMATION info;
    KUSER_SHARED_DATA *data;
    unsigned int status;
    HANDLE section;
    int res, fd, needs_close;

    if ((status = NtOpenSection( &section, SECTION_ALL_ACCESS, &attr )))
    {
        ERR( "failed to open the USD section: %08x\n", status );
        exit(1);
    }
    if ((res = server_get_unix_fd( section, 0, &fd, &needs_close, NULL, NULL )) ||
        (data = mmap( NULL, sizeof(*data), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0 )) == MAP_FAILED)
    {
        ERR( "failed to remap the process USD: %d\n", res );
        exit(1);
    }
    if (needs_close) close( fd );
    NtClose( section );

    virtual_get_system_info( &info, FALSE );

    data->TickCountMultiplier   = 1 << 24;
    data->LargePageMinimum      = 2 * 1024 * 1024;
    data->SystemCall            = 1;
    data->NumberOfPhysicalPages = info.MmNumberOfPhysicalPages;
    data->NXSupportPolicy       = NX_SUPPORT_POLICY_OPTIN;
    data->ActiveProcessorCount  = peb->NumberOfProcessors;
    data->ActiveGroupCount      = 1;

    switch (native_machine)
    {
    case IMAGE_FILE_MACHINE_I386:  data->NativeProcessorArchitecture = PROCESSOR_ARCHITECTURE_INTEL; break;
    case IMAGE_FILE_MACHINE_AMD64: data->NativeProcessorArchitecture = PROCESSOR_ARCHITECTURE_AMD64; break;
    case IMAGE_FILE_MACHINE_ARMNT: data->NativeProcessorArchitecture = PROCESSOR_ARCHITECTURE_ARM; break;
    case IMAGE_FILE_MACHINE_ARM64: data->NativeProcessorArchitecture = PROCESSOR_ARCHITECTURE_ARM64; break;
    }

    init_shared_data_cpuinfo( data );
    ios_pool_va_warn( "munmap", data, sizeof(*data) );
    munmap( data, sizeof(*data) );
}


struct thread_stack_info
{
    char  *start;
    char  *limit;
    char  *end;
    SIZE_T guaranteed;
    BOOL   is_wow;
};

/***********************************************************************
 *           is_inside_thread_stack
 */
static BOOL is_inside_thread_stack( void *ptr, struct thread_stack_info *stack )
{
    TEB *teb = NtCurrentTeb();
    WOW_TEB *wow_teb = get_wow_teb( teb );
    size_t min_guaranteed = max( page_size * (is_win64 ? 2 : 1), host_page_size );

    stack->start = teb->DeallocationStack;
    stack->limit = teb->Tib.StackLimit;
    stack->end   = teb->Tib.StackBase;
    stack->guaranteed = max( teb->GuaranteedStackBytes, min_guaranteed );
    stack->is_wow = FALSE;
    if ((char *)ptr > stack->start && (char *)ptr <= stack->end) return TRUE;

    if (!wow_teb) return FALSE;
    stack->start = ULongToPtr( wow_teb->DeallocationStack );
    stack->limit = ULongToPtr( wow_teb->Tib.StackLimit );
    stack->end   = ULongToPtr( wow_teb->Tib.StackBase );
    stack->guaranteed = max( wow_teb->GuaranteedStackBytes, min_guaranteed );
    stack->is_wow = TRUE;
    return ((char *)ptr > stack->start && (char *)ptr <= stack->end);
}


/***********************************************************************
 *           grow_thread_stack
 */
static NTSTATUS grow_thread_stack( char *page, struct thread_stack_info *stack_info )
{
    NTSTATUS ret = 0;

    set_page_vprot_bits( page, host_page_size, VPROT_COMMITTED, VPROT_GUARD );
    mprotect_range( page, host_page_size, 0, 0 );
    if (page >= stack_info->start + host_page_size + stack_info->guaranteed)
    {
        set_page_vprot_bits( page - host_page_size, host_page_size, VPROT_COMMITTED | VPROT_GUARD, 0 );
        mprotect_range( page - host_page_size, host_page_size, 0, 0 );
    }
    else  /* inside guaranteed space -> overflow exception */
    {
        page = stack_info->start + host_page_size;
        set_page_vprot_bits( page, stack_info->guaranteed, VPROT_COMMITTED, VPROT_GUARD );
        mprotect_range( page, stack_info->guaranteed, 0, 0 );
        ret = STATUS_STACK_OVERFLOW;
    }
    if (stack_info->is_wow)
    {
        WOW_TEB *wow_teb = get_wow_teb( NtCurrentTeb() );
        wow_teb->Tib.StackLimit = PtrToUlong( page );
    }
    else NtCurrentTeb()->Tib.StackLimit = page;
    return ret;
}


/***********************************************************************
 *           virtual_handle_fault
 */
NTSTATUS virtual_handle_fault( EXCEPTION_RECORD *rec, void *stack )
{
    NTSTATUS ret = STATUS_ACCESS_VIOLATION;
    ULONG_PTR err = rec->ExceptionInformation[0];
    void *addr = (void *)rec->ExceptionInformation[1];
    char *page = ROUND_ADDR( addr, host_page_mask );
    BYTE vprot;

    mutex_lock( &virtual_mutex );  /* no need for signal masking inside signal handler */
    vprot = get_host_page_vprot( page );

#ifdef __APPLE__
    /* Rosetta on Apple Silicon misreports certain write faults as read faults. */
    if (err == EXCEPTION_READ_FAULT && (get_unix_prot( vprot ) & PROT_READ))
    {
        WARN( "treating read fault in a readable page as a write fault, addr %p\n", addr );
        err = EXCEPTION_WRITE_FAULT;
    }
#endif

    if (!is_inside_signal_stack( stack ) && (vprot & VPROT_GUARD))
    {
        struct thread_stack_info stack_info;
        if (!is_inside_thread_stack( page, &stack_info ))
        {
            set_page_vprot_bits( page, host_page_size, 0, VPROT_GUARD );
            mprotect_range( page, host_page_size, 0, 0 );
            ret = STATUS_GUARD_PAGE_VIOLATION;
        }
        else ret = grow_thread_stack( page, &stack_info );
    }
    else if (err == EXCEPTION_WRITE_FAULT)
    {
        if (vprot & VPROT_WRITEWATCH)
        {
            if (enable_write_exceptions && is_vprot_exec_write( vprot ) && !ntdll_get_thread_data()->allow_writes)
            {
                rec->NumberParameters = 3;
                rec->ExceptionInformation[2] = STATUS_EXECUTABLE_MEMORY_WRITE;
                ret = STATUS_IN_PAGE_ERROR;
            }
            else
            {
                set_page_vprot_bits( page, host_page_size, 0, VPROT_WRITEWATCH );
                mprotect_range( page, host_page_size, 0, 0 );
            }
        }
        /* ignore fault if page is writable now */
        if (get_unix_prot( get_host_page_vprot( page )) & PROT_WRITE)
        {
            if ((vprot & VPROT_WRITEWATCH) || is_write_watch_range( page, 1 ))
                ret = STATUS_SUCCESS;
        }
    }
    mutex_unlock( &virtual_mutex );
    rec->ExceptionCode = ret;
    return ret;
}

/* iOS-Madeira ml420 (#69): BUS self-heal support. ml419's fatal chain began
 * with a committed, plain-READ libcef .rdata page whose host protection had
 * been stripped BEHIND wine's back (no guest NtProtectVirtualMemory touched
 * the range — the stripper is a raw mprotect/mach_vm call). Report wine's
 * INTENDED unix prot for the page so bus_handler can put it back and resume
 * instead of dying. Returns -1 if wine has no committed view of the page.
 * Lock-free vprot peek (signal context — taking virtual_mutex here could
 * self-deadlock); racy reads are acceptable for a heal heuristic. */
int ios_page_expected_prot( const void *addr )
{
    BYTE vprot = get_page_vprot( addr );
    if (!(vprot & VPROT_COMMITTED)) return -1;
    return get_unix_prot( vprot );
}

/* Steam S3 (task #29): when virtual_handle_fault can't service a fault,
 * dump the target's memory picture — is it in a Wine file_view (Wine should
 * manage it → our commit/vprot has a gap), or is it a FEX/foreign mapping
 * Wine doesn't know about? Plus vprot of the page and its neighbors (a
 * page-crossing write into an uncommitted next-page shows as this/next
 * differing). Decides whether the fix is Wine-side commit-on-fault or a
 * FEX guest-memory issue. */
void ios_dump_fault_region( void *addr )
{
    char *page = ROUND_ADDR( addr, host_page_mask );
    BYTE vp_prev, vp, vp_next;
    struct file_view *view;
    extern void *ios_jit_rx_base_global, *ios_jit_rw_base_global;
    extern size_t ios_jit_pool_size_global;
    uintptr_t a = (uintptr_t)addr, rx = (uintptr_t)ios_jit_rx_base_global,
              rw = (uintptr_t)ios_jit_rw_base_global, sz = ios_jit_pool_size_global;
    const char *region = "unknown/foreign";

    {
        static unsigned long fr_storm;
        if (!ios_storm_gate( &fr_storm )) return;
    }
    mutex_lock( &virtual_mutex );
    vp_prev = get_host_page_vprot( page - host_page_size );
    vp      = get_host_page_vprot( page );
    vp_next = get_host_page_vprot( page + host_page_size );
    view = find_view( addr, 1 );
    if (rx && a >= rx && a < rx + sz) region = "JIT-POOL-RX (exec, RO)";
    else if (rw && a >= rw && a < rw + sz) region = "JIT-POOL-RW (alias)";
    dprintf( 2, "[fault-rgn] addr=%p page=%p vprot prev/this/next=%02x/%02x/%02x region=%s\n",
             addr, page, vp_prev, vp, vp_next, region );
    if (view)
        dprintf( 2, "[fault-rgn]   IN WINE VIEW base=%p size=0x%lx protect=0x%x off=0x%lx end=%p\n",
                 view->base, (unsigned long)view->size, view->protect,
                 (unsigned long)((char *)addr - (char *)view->base),
                 (char *)view->base + view->size );
    else
        dprintf( 2, "[fault-rgn]   NO wine view — Wine doesn't own this addr (FEX/foreign mmap)\n" );
    mutex_unlock( &virtual_mutex );
}


/***********************************************************************
 *           virtual_setup_exception
 */

/* ml262: is every page of [addr, addr+size) mapped AND writable?
 *
 * Needed because virtual_setup_exception's "outside thread stack" branch is routine
 * in this port -- FEX guest stacks are not Wine views -- and it must not hand back
 * memory the caller cannot write. Walks region-by-region so a HOLE (mach_vm_region
 * returning a region that starts above the query address) is detected rather than
 * mistaken for the containing region. */
static int ios_range_writable( const void *addr, size_t size )
{
    mach_vm_address_t a = (mach_vm_address_t)(uintptr_t)addr;
    mach_vm_address_t end = a + (size ? size : 1);

    while (a < end)
    {
        mach_vm_address_t q = a;
        mach_vm_size_t sz = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;

        if (mach_vm_region( mach_task_self(), &q, &sz, VM_REGION_BASIC_INFO_64,
                            (vm_region_info_t)&info, &cnt, &obj ) != KERN_SUCCESS)
            return 0;
        if (q > a) return 0;                             /* hole */
        if (!(info.protection & VM_PROT_WRITE)) return 0;
        a = q + sz;
    }
    return 1;
}

void *virtual_setup_exception( void *stack_ptr, size_t size, EXCEPTION_RECORD *rec )
{
    char *stack = stack_ptr;
    struct thread_stack_info stack_info;

    if (!is_inside_thread_stack( stack, &stack_info ))
    {
        if (is_inside_signal_stack( stack ))
        {
            ERR( "nested exception on signal stack addr %p stack %p\n", rec->ExceptionAddress, stack );
            abort_thread(1);
        }
        WARN( "exception outside of stack limits addr %p stack %p (%p-%p-%p)\n",
              rec->ExceptionAddress, stack, NtCurrentTeb()->DeallocationStack,
              NtCurrentTeb()->Tib.StackLimit, NtCurrentTeb()->Tib.StackBase );
        /* ml262 LIVELOCK FIX: this branch used to return an UNVALIDATED pointer.
         *
         * "Outside a Wine thread stack" is routine in this port -- FEX guest stacks
         * are not Wine views -- so this is a hot path, and the caller immediately
         * copies EXCEPTION_RECORD + CONTEXT to whatever we return. When that landed
         * in an unmapped hole the copy faulted, which raised another exception down
         * this same path, which faulted again: an unbreakable loop. Measured twice --
         * 49,500 faults in ml261 and 53,000 in ml262, each consuming the entire run:
         *   [fault-stuck] page 0x73d16ac000 faulted 2048 times with NO progress
         *   [fault-stuck]   region 0x73d16b0000 +0x40000 prot=3/7   <- first region ABOVE
         *   sym pc=Madeira.debug.dylib`setup_raise_exception+0x104 (stp q1,q0,[x0,#0x1d0])
         * The write target sat 0x170 bytes BELOW the base of the guest stack region,
         * i.e. the guest stack was exhausted and the frame did not fit.
         *
         * An exception that cannot be delivered is unrecoverable, exactly like the two
         * cases above, so abort the thread instead of spinning forever. */
        if (!ios_range_writable( stack - size, size ))
        {
            ERR( "[exc-stack] cannot deliver exception: %p..%p not writable "
                 "(addr %p) -- aborting thread instead of faulting forever\n",
                 stack - size, stack, rec->ExceptionAddress );
            abort_thread(1);
        }
        return stack - size;
    }

    stack -= size;

    if (stack < stack_info.start + host_page_size)
    {
        /* stack overflow on last page, unrecoverable */
        UINT diff = stack_info.start + host_page_size - stack;
        ERR( "stack overflow %u bytes addr %p stack %p (%p-%p-%p)\n",
             diff, rec->ExceptionAddress, stack, stack_info.start, stack_info.limit, stack_info.end );
        abort_thread(1);
    }
    else if (stack < stack_info.limit)
    {
        char *page = ROUND_ADDR( stack, host_page_mask );
        mutex_lock( &virtual_mutex );  /* no need for signal masking inside signal handler */
        if ((get_host_page_vprot( page ) & VPROT_GUARD) && grow_thread_stack( page, &stack_info ))
        {
            rec->ExceptionCode = STATUS_STACK_OVERFLOW;
            rec->NumberParameters = 0;
        }
        mutex_unlock( &virtual_mutex );
    }
#if defined(VALGRIND_MAKE_MEM_UNDEFINED)
    VALGRIND_MAKE_MEM_UNDEFINED( stack, size );
#elif defined(VALGRIND_MAKE_WRITABLE)
    VALGRIND_MAKE_WRITABLE( stack, size );
#endif
    return stack;
}


/* ml369 (#63): cross-thread variants for in-Mach guest exception delivery.
 *
 * ml364-368 contain ZERO segv/ill/bus handler invocations: with StikDebug
 * attached, a fault our Mach handler declines goes to the task port, the
 * script's continue marks it HANDLED kernel-side, and BSD signal conversion
 * never happens (the stub cannot inject signals — no PT_THUPDATE). So wine's
 * whole signal-side delivery path is unreachable and any unfixable fault
 * spins at one pc until the script kills the process at 8 repeats.
 *
 * These helpers let the Mach exception-server thread run the same
 * fault-service + dispatch-frame logic against the FAULTING thread (which
 * the exception message keeps suspended). Current-thread dependencies are
 * parameterized away:
 *   - stack bounds come from the TARGET's TEB (no WOW branch: ARM64EC
 *     guests are 64-bit);
 *   - no abort_thread (that would kill the exception SERVER thread) —
 *     undeliverable returns NULL and the caller declines as before;
 *   - the enable_write_exceptions/allow_writes report branch acts as
 *     allow_writes (clears the watch) since ntdll_get_thread_data() would
 *     read the wrong thread. */
static BOOL is_inside_thread_stack_teb( void *ptr, struct thread_stack_info *stack, TEB *teb )
{
    size_t min_guaranteed = max( page_size * (is_win64 ? 2 : 1), host_page_size );

    stack->start = teb->DeallocationStack;
    stack->limit = teb->Tib.StackLimit;
    stack->end   = teb->Tib.StackBase;
    stack->guaranteed = max( teb->GuaranteedStackBytes, min_guaranteed );
    stack->is_wow = FALSE;
    return ((char *)ptr > stack->start && (char *)ptr <= stack->end);
}

static NTSTATUS grow_thread_stack_teb( char *page, struct thread_stack_info *stack_info, TEB *teb )
{
    NTSTATUS ret = 0;

    set_page_vprot_bits( page, host_page_size, VPROT_COMMITTED, VPROT_GUARD );
    mprotect_range( page, host_page_size, 0, 0 );
    if (page >= stack_info->start + host_page_size + stack_info->guaranteed)
    {
        set_page_vprot_bits( page - host_page_size, host_page_size, VPROT_COMMITTED | VPROT_GUARD, 0 );
        mprotect_range( page - host_page_size, host_page_size, 0, 0 );
    }
    else  /* inside guaranteed space -> overflow exception */
    {
        page = stack_info->start + host_page_size;
        set_page_vprot_bits( page, stack_info->guaranteed, VPROT_COMMITTED, VPROT_GUARD );
        mprotect_range( page, stack_info->guaranteed, 0, 0 );
        ret = STATUS_STACK_OVERFLOW;
    }
    teb->Tib.StackLimit = page;
    return ret;
}

/* ml374: the two entry points below run ON the Mach exception-server thread.
 * They raise ios_in_mach_exc for their whole extent so shared helpers (notably
 * mprotect_exec, reached via mprotect_range) skip wine log macros — see the
 * ios_in_mach_exc comment for why that is fatal rather than merely noisy. */
NTSTATUS ios_virtual_handle_fault_for_thread( EXCEPTION_RECORD *rec, TEB *teb )
{
    NTSTATUS ret = STATUS_ACCESS_VIOLATION;
    ULONG_PTR err = rec->ExceptionInformation[0];
    void *addr = (void *)rec->ExceptionInformation[1];
    char *page = ROUND_ADDR( addr, host_page_mask );
    BYTE vprot;

    mutex_lock( &virtual_mutex );
    vprot = get_host_page_vprot( page );

    if (err == EXCEPTION_READ_FAULT && (get_unix_prot( vprot ) & PROT_READ))
    {
        /* ml370: dprintf, NEVER a wine log macro — this runs on the Mach
         * exception-server thread, which has no TEB, and __wine_dbg_header's
         * per-thread read killed the server on the FIRST fault (fatal pc
         * symbolized to __wine_dbg_header+0x100). No fault service, no
         * delivery, whole app killed by the script. */
        static int reclass_logs;
        if (reclass_logs < 8)
        {
            reclass_logs++;
            dprintf( 2, "[mach-deliver] read fault on readable page -> write fault, addr %p\n", addr );
        }
        err = EXCEPTION_WRITE_FAULT;
    }

    /* the faulting thread was running guest/JIT code, never a signal
     * stack, so the is_inside_signal_stack() exclusion is vacuous here */
    if (vprot & VPROT_GUARD)
    {
        struct thread_stack_info stack_info;
        if (!is_inside_thread_stack_teb( page, &stack_info, teb ))
        {
            set_page_vprot_bits( page, host_page_size, 0, VPROT_GUARD );
            mprotect_range( page, host_page_size, 0, 0 );
            ret = STATUS_GUARD_PAGE_VIOLATION;
        }
        else ret = grow_thread_stack_teb( page, &stack_info, teb );
    }
    else if (err == EXCEPTION_WRITE_FAULT)
    {
        if (vprot & VPROT_WRITEWATCH)
        {
            set_page_vprot_bits( page, host_page_size, 0, VPROT_WRITEWATCH );
            mprotect_range( page, host_page_size, 0, 0 );
        }
        if (get_unix_prot( get_host_page_vprot( page )) & PROT_WRITE)
        {
            if ((vprot & VPROT_WRITEWATCH) || is_write_watch_range( page, 1 ))
                ret = STATUS_SUCCESS;
        }
    }
    mutex_unlock( &virtual_mutex );
    rec->ExceptionCode = ret;
    return ret;
}

void *ios_virtual_setup_exception_for_thread( void *stack_ptr, size_t size, EXCEPTION_RECORD *rec, TEB *teb )
{
    char *stack = stack_ptr;
    struct thread_stack_info stack_info;

    if (!is_inside_thread_stack_teb( stack, &stack_info, teb ))
    {
        /* routine in this port — FEX guest stacks are not Wine views */
        if (!ios_range_writable( stack - size, size )) return NULL;
        return stack - size;
    }

    stack -= size;
    if (stack < stack_info.start + host_page_size) return NULL;  /* overflow on last page */
    if (stack < stack_info.limit)
    {
        char *page = ROUND_ADDR( stack, host_page_mask );
        mutex_lock( &virtual_mutex );
        if ((get_host_page_vprot( page ) & VPROT_GUARD) &&
            grow_thread_stack_teb( page, &stack_info, teb ))
        {
            rec->ExceptionCode = STATUS_STACK_OVERFLOW;
            rec->NumberParameters = 0;
        }
        mutex_unlock( &virtual_mutex );
    }
    if (!ios_range_writable( stack, size )) return NULL;
    return stack;
}


/***********************************************************************
 *           check_write_access
 *
 * Check if the memory range is writable, temporarily disabling write watches if necessary.
 */
static NTSTATUS check_write_access( void *base, size_t size, BOOL *has_write_watch )
{
    size_t i;
    char *addr = ROUND_ADDR( base, host_page_mask );

    size = ROUND_SIZE( base, size, host_page_mask );
    for (i = 0; i < size; i += host_page_size)
    {
        BYTE vprot = get_host_page_vprot( addr + i );
        if (vprot & VPROT_WRITEWATCH) *has_write_watch = TRUE;
        if (!(get_unix_prot( vprot & ~VPROT_WRITEWATCH ) & PROT_WRITE))
            return STATUS_INVALID_USER_BUFFER;
    }
    if (*has_write_watch)
        mprotect_range( addr, size, 0, VPROT_WRITEWATCH );  /* temporarily enable write access */
    return STATUS_SUCCESS;
}


/***********************************************************************
 *           virtual_locked_server_call
 */
unsigned int virtual_locked_server_call( void *req_ptr )
{
    struct __server_request_info * const req = req_ptr;
    sigset_t sigset;
    void *addr = req->reply_data;
    data_size_t size = req->u.req.request_header.reply_size;
    BOOL has_write_watch = FALSE;
    unsigned int ret;

    if (!size) return wine_server_call( req_ptr );

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if (!(ret = check_write_access( addr, size, &has_write_watch )))
    {
        ret = server_call_unlocked( req );
        if (has_write_watch) update_write_watches( addr, size, wine_server_reply_size( req ));
    }
    else memset( &req->u.reply, 0, sizeof(req->u.reply) );
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return ret;
}


/***********************************************************************
 *           virtual_locked_read
 */
ssize_t virtual_locked_read( int fd, void *addr, size_t size )
{
    sigset_t sigset;
    BOOL has_write_watch = FALSE;
    int err = EFAULT;

    ssize_t ret = read( fd, addr, size );
    if (ret != -1 || use_kernel_writewatch || errno != EFAULT) return ret;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if (!check_write_access( addr, size, &has_write_watch ))
    {
        ret = read( fd, addr, size );
        err = errno;
        if (has_write_watch) update_write_watches( addr, size, max( 0, ret ));
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    errno = err;
    return ret;
}


/***********************************************************************
 *           virtual_locked_pread
 */
ssize_t virtual_locked_pread( int fd, void *addr, size_t size, off_t offset )
{
    sigset_t sigset;
    BOOL has_write_watch = FALSE;
    int err = EFAULT;

    ssize_t ret = pread( fd, addr, size, offset );
    if (ret != -1 || use_kernel_writewatch || errno != EFAULT) return ret;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if (!check_write_access( addr, size, &has_write_watch ))
    {
        ret = pread( fd, addr, size, offset );
        err = errno;
        if (has_write_watch) update_write_watches( addr, size, max( 0, ret ));
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    errno = err;
    return ret;
}


/***********************************************************************
 *           virtual_locked_recvmsg
 */
ssize_t virtual_locked_recvmsg( int fd, struct msghdr *hdr, int flags )
{
    sigset_t sigset;
    size_t i;
    BOOL has_write_watch = FALSE;
    int err = EFAULT;

    ssize_t ret = recvmsg( fd, hdr, flags );
    if (ret != -1 || use_kernel_writewatch || errno != EFAULT) return ret;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    for (i = 0; i < hdr->msg_iovlen; i++)
        if (check_write_access( hdr->msg_iov[i].iov_base, hdr->msg_iov[i].iov_len, &has_write_watch ))
            break;
    if (i == hdr->msg_iovlen)
    {
        ret = recvmsg( fd, hdr, flags );
        err = errno;
    }
    if (has_write_watch)
        while (i--) update_write_watches( hdr->msg_iov[i].iov_base, hdr->msg_iov[i].iov_len, 0 );

    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    errno = err;
    return ret;
}


/***********************************************************************
 *           virtual_is_valid_code_address
 */
BOOL virtual_is_valid_code_address( const void *addr, SIZE_T size )
{
    struct file_view *view;
    BOOL ret = FALSE;
    sigset_t sigset;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if ((view = find_view( addr, size )))
        ret = !(view->protect & VPROT_SYSTEM);  /* system views are not visible to the app */
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return ret;
}


/***********************************************************************
 *           virtual_check_buffer_for_read
 *
 * Check if a memory buffer can be read, triggering page faults if needed for DIB section access.
 */
BOOL virtual_check_buffer_for_read( const void *ptr, SIZE_T size )
{
    if (!size) return TRUE;
    if (!ptr) return FALSE;

    __TRY
    {
        volatile const char *p = ptr;
        char dummy __attribute__((unused));
        SIZE_T count = size;

        while (count > host_page_size)
        {
            dummy = *p;
            p += host_page_size;
            count -= host_page_size;
        }
        dummy = p[0];
        dummy = p[count - 1];
    }
    __EXCEPT
    {
        return FALSE;
    }
    __ENDTRY
    return TRUE;
}


/***********************************************************************
 *           virtual_check_buffer_for_write
 *
 * Check if a memory buffer can be written to, triggering page faults if needed for write watches.
 */
BOOL virtual_check_buffer_for_write( void *ptr, SIZE_T size )
{
    if (!size) return TRUE;
    if (!ptr) return FALSE;

    __TRY
    {
        volatile char *p = ptr;
        SIZE_T count = size;

        while (count > host_page_size)
        {
            *p |= 0;
            p += host_page_size;
            count -= host_page_size;
        }
        p[0] |= 0;
        p[count - 1] |= 0;
    }
    __EXCEPT
    {
        return FALSE;
    }
    __ENDTRY
    return TRUE;
}


/***********************************************************************
 *           virtual_uninterrupted_read_memory
 *
 * Similar to NtReadVirtualMemory, but without wineserver calls. Moreover
 * permissions are checked before accessing each page, to ensure that no
 * exceptions can happen.
 */
SIZE_T virtual_uninterrupted_read_memory( const void *addr, void *buffer, SIZE_T size )
{
    struct file_view *view;
    sigset_t sigset;
    SIZE_T bytes_read = 0;

    if (!size) return 0;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if ((view = find_view( addr, size )))
    {
        if (!(view->protect & VPROT_SYSTEM))
        {
            while (bytes_read < size && (get_unix_prot( get_host_page_vprot( addr )) & PROT_READ))
            {
                SIZE_T block_size = min( size - bytes_read, host_page_size - ((UINT_PTR)addr & host_page_mask) );
                memcpy( buffer, addr, block_size );

                addr   = (const void *)((const char *)addr + block_size);
                buffer = (void *)((char *)buffer + block_size);
                bytes_read += block_size;
            }
        }
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return bytes_read;
}


/***********************************************************************
 *           virtual_uninterrupted_write_memory
 *
 * Similar to NtWriteVirtualMemory, but without wineserver calls. Moreover
 * permissions are checked before accessing each page, to ensure that no
 * exceptions can happen.
 */
NTSTATUS virtual_uninterrupted_write_memory( void *addr, const void *buffer, SIZE_T size )
{
    BOOL has_write_watch = FALSE;
    sigset_t sigset;
    NTSTATUS ret;

    if (!size) return STATUS_SUCCESS;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if (!(ret = check_write_access( addr, size, &has_write_watch )))
    {
        memcpy( addr, buffer, size );
        if (has_write_watch) update_write_watches( addr, size, size );
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return ret;
}


/***********************************************************************
 *           virtual_set_force_exec
 *
 * Whether to force exec prot on all views.
 */
void virtual_set_force_exec( BOOL enable )
{
    struct file_view *view;
    sigset_t sigset;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if (!force_exec_prot != !enable)  /* change all existing views */
    {
        force_exec_prot = enable;

        WINE_RB_FOR_EACH_ENTRY( view, &views_tree, struct file_view, entry )
        {
            /* file mappings are always accessible */
            BYTE commit = is_view_valloc( view ) ? 0 : VPROT_COMMITTED;

            mprotect_range( view->base, view->size, commit, 0 );
        }
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
}


/***********************************************************************
 *           virtual_manage_exec_writes
 */
void virtual_enable_write_exceptions( BOOL enable )
{
    struct file_view *view;
    sigset_t sigset;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if (!enable_write_exceptions && enable)  /* change all existing views */
    {
        WINE_RB_FOR_EACH_ENTRY( view, &views_tree, struct file_view, entry )
            if (set_page_vprot_exec_write_protect( view->base, view->size ))
                mprotect_range( view->base, view->size, 0, 0 );
    }
    enable_write_exceptions = enable;
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
}


/* free reserved areas within a given range */
static void free_reserved_memory( char *base, char *limit )
{
    struct reserved_area *area;

    for (;;)
    {
        int removed = 0;

        LIST_FOR_EACH_ENTRY( area, &reserved_areas, struct reserved_area, entry )
        {
            char *area_base = area->base;
            char *area_end = area_base + area->size;

            if (area_end <= base) continue;
            if (area_base >= limit) return;
            if (area_base < base) area_base = base;
            if (area_end > limit) area_end = limit;
            remove_reserved_area( area_base, area_end - area_base );
            removed = 1;
            break;
        }
        if (!removed) return;
    }
}

#ifndef _WIN64

/***********************************************************************
 *           virtual_release_address_space
 *
 * Release some address space once we have loaded and initialized the app.
 */
static void virtual_release_address_space(void)
{
#ifndef __APPLE__  /* On macOS, we still want to free some of low memory, for OpenGL resources */
    if (user_space_limit > (void *)limit_2g) return;
#endif
    free_reserved_memory( (char *)0x20000000, (char *)0x7f000000 );
}

#endif  /* _WIN64 */


/***********************************************************************
 *           virtual_set_large_address_space
 *
 * Enable use of a large address space when allowed by the application.
 */
void virtual_set_large_address_space(void)
{
    if (is_win64)
    {
        if (!is_wow64())
        {
            address_space_start = (void *)0x10000;
#ifndef __APPLE__  /* don't free the zerofill section on macOS */
            if ((main_image_info.DllCharacteristics & IMAGE_DLLCHARACTERISTICS_HIGH_ENTROPY_VA) &&
                (main_image_info.DllCharacteristics & IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE))
                free_reserved_memory( 0, (char *)0x7ffe0000 );
#endif
        }
        else user_space_wow_limit = ((main_image_info.ImageCharacteristics & IMAGE_FILE_LARGE_ADDRESS_AWARE) ? limit_4g : limit_2g) - 1;
    }
    else
    {
        if (!(main_image_info.ImageCharacteristics & IMAGE_FILE_LARGE_ADDRESS_AWARE)) return;
        free_reserved_memory( (char *)0x80000000, address_space_limit );
    }
    user_space_limit = working_set_limit = address_space_limit;
}


/***********************************************************************
 *             allocate_virtual_memory
 *
 * NtAllocateVirtualMemory[Ex] implementation.
 */
static NTSTATUS allocate_virtual_memory( void **ret, SIZE_T *size_ptr, ULONG type, ULONG protect,
                                         ULONG_PTR limit_low, ULONG_PTR limit_high,
                                         ULONG_PTR align, ULONG attributes )
{
    void *base;
    unsigned int vprot;
    BOOL is_dos_memory = FALSE;
    struct file_view *view;
    sigset_t sigset;
    SIZE_T size = *size_ptr;
    NTSTATUS status = STATUS_SUCCESS;

    /* Round parameters to a page boundary */

    if (is_beyond_limit( 0, size, working_set_limit )) return STATUS_WORKING_SET_LIMIT_RANGE;

    if (*ret)
    {
        if (type & MEM_RESERVE && !(type & MEM_REPLACE_PLACEHOLDER)) /* Round down to 64k boundary */
            base = ROUND_ADDR( *ret, granularity_mask );
        else
            base = ROUND_ADDR( *ret, page_mask );
        size = (((UINT_PTR)*ret + size + page_mask) & ~page_mask) - (UINT_PTR)base;

        /* disallow low 64k, wrap-around and kernel space */
        if (((char *)base < (char *)0x10000) ||
            ((char *)base + size < (char *)base) ||
            is_beyond_limit( base, size, address_space_limit ))
        {
            /* address 1 is magic to mean DOS area */
            if (!base && *ret == (void *)1 && size == 0x110000) is_dos_memory = TRUE;
            else return STATUS_INVALID_PARAMETER;
        }
    }
    else
    {
        base = NULL;
        size = ROUND_SIZE( 0, size, page_mask );
    }

    /* Compute the alloc type flags */

    if (!(type & (MEM_COMMIT | MEM_RESERVE | MEM_RESET))
        || (type & MEM_REPLACE_PLACEHOLDER && !(type & MEM_RESERVE)))
    {
        WARN("called with wrong alloc type flags (%08x) !\n", type);
        return STATUS_INVALID_PARAMETER;
    }

    if (type & MEM_RESERVE_PLACEHOLDER && (protect != PAGE_NOACCESS)) return STATUS_INVALID_PARAMETER;
    if (!arm64ec_view && (attributes & MEM_EXTENDED_PARAMETER_EC_CODE)) return STATUS_INVALID_PARAMETER;

    /* Reserve the memory */

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );

    if ((type & MEM_RESERVE) || !base)
    {
        if (!(status = get_vprot_flags( protect, &vprot, FALSE )))
        {
            if (type & MEM_COMMIT) vprot |= VPROT_COMMITTED;
            if (type & MEM_WRITE_WATCH) vprot |= VPROT_WRITEWATCH;
            if (type & MEM_RESERVE_PLACEHOLDER) vprot |= VPROT_PLACEHOLDER | VPROT_FREE_PLACEHOLDER;
            if (protect & PAGE_NOCACHE) vprot |= SEC_NOCACHE;

            if (vprot & VPROT_WRITECOPY) status = STATUS_INVALID_PAGE_PROTECTION;
            else if (is_dos_memory) status = allocate_dos_memory( &view, vprot );
            else status = map_view( &view, base, size, type, vprot, limit_low, limit_high,
                                    align ? align - 1 : granularity_mask );

            if (status == STATUS_SUCCESS)
            {
                base = view->base;
                if (vprot & VPROT_EXEC || force_exec_prot) mprotect_range( base, size, 0, 0 );

                /* iOS-Madeira ml308 (task #54): DETECT VA HANDED OUT TWICE.
                 *
                 * ml308's [vname] map (which only became readable once ml294 turned the iOS
                 * VirtualName no-op into a range log) shows 50 OVERLAPPING FEX allocations,
                 * including EXACT DUPLICATES given to different threads:
                 *   FEXMem_ThreadState  [0x7d00001000..0x7d00004000]  tid A8 AND tid B0
                 *   FEXMem_Lookup       [0x73af1a0000..0x73b41a0000]  tid B4 AND tid C4 (80MB)
                 *   FEXMem_Lookup_L1    [0x73b41a0000..0x73b51a0000]  tid B4 AND tid C4 (16MB)
                 *   FEXMem_CallRetStacks overlapping by up to 16MB in several pairs
                 * Two threads sharing a ThreadState means the SAME x28, so one thread's
                 * State.rip is the other's; sharing a CallRetStack means one thread pops the
                 * other's {guest_ret, host_label} pair and branches to a foreign block's
                 * intra-block label. That is exactly the #51/#52 signature (host PC 0x2c-0x12b4
                 * into "the current" block, present in no guest GPR) and exactly why disabling
                 * the call-ret predictor helped -- it stopped consuming the foreign host half.
                 * It also explains the run-to-run variance, since damage depends on whether the
                 * colliding threads run concurrently.
                 *
                 * A8's ThreadState landed at <steered 512MB reservation base>+0x1000, and B0's
                 * landed on the identical address with no new [bigres] -- so later allocations
                 * are not excluding already-steered ranges. Report any allocation that lands
                 * inside a live ios_steer[] entry, naming both owners. Detection only; no
                 * behaviour change until the log says which path grants the collision. */
                /* ml309: the ml308 version above could only CONFIRM -- it printed nothing when it
                 * found no match, so "0 hits" was indistinguishable from "never reached" and from
                 * "ios_steer[] empty in this process". ml309 hit exactly that: the [vname] map still
                 * showed 3 exact-duplicate FEXMem_ThreadState ranges (tids A8/C0, B4/C4, D0/DC), the
                 * colliding bases 0x7d00000000 / 0x7dc0000000 / 0x7ec0000000 ARE all recorded steer
                 * bases, steer-reclaim never ran, and A8 and C0 are the same process (peb
                 * 0x115bc8000, per [thr-create] + the [tsd275] tid<->TEB mapping) -- yet zero
                 * [va-collide] lines. So log EVERY arena-band allocation with the match RESULT, which
                 * makes the negative readable: "no steer match" with ios_steer_n>0 means the table
                 * lacks the entry, whereas no lines at all means this code path is not on the path
                 * FEX's VirtualAlloc2 takes. */
                if ((uint64_t)(uintptr_t)base >= 0x7C00000000ULL)
                {
                    static int ac;
                    uint64_t nb = (uint64_t)(uintptr_t)base, ne = nb + size;
                    unsigned i, hit = (unsigned)-1;
                    for (i = 0; i < ios_steer_n; i++)
                    {
                        uint64_t sb, se;
                        if (!ios_steer[i].base) continue;
                        sb = ios_steer[i].base; se = sb + ios_steer[i].size;
                        if (ne <= sb || nb >= se) continue;
                        hit = i;
                        break;
                    }
                    if (ac++ < 40)
                    {
                        unsigned me = NtCurrentTeb()
                            ? (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread : 0;
                        if (hit != (unsigned)-1)
                            dprintf( 2, "[va-arena] rev=ml309 alloc %p+0x%lx tid=%04x type=0x%x -> INSIDE "
                                     "steer#%u [0x%llx+0x%llx] owner_tid=%04x freed=%u steer_n=%u\n",
                                     base, (unsigned long)size, me, (unsigned)type, hit,
                                     (unsigned long long)ios_steer[hit].base,
                                     (unsigned long long)ios_steer[hit].size,
                                     ios_steer[hit].tid, ios_steer[hit].freed, ios_steer_n );
                        else
                            dprintf( 2, "[va-arena] rev=ml309 alloc %p+0x%lx tid=%04x type=0x%x -> no steer "
                                     "match (steer_n=%u)\n",
                                     base, (unsigned long)size, me, (unsigned)type, ios_steer_n );
                    }
                }
            }
        }
    }
    else if (type & MEM_RESET)
    {
        if (!(view = find_view( base, size ))) status = STATUS_NOT_MAPPED_VIEW;
        else
        {
            /* iOS-Madeira (task #22): never MADV_DONTNEED an anon-RWX pool
             * alias — discarding the shared entry pages silently zeroes the
             * pool RX view too (live FEX code/data). MEM_RESET is advisory,
             * so skipping it is legal. */
            extern uintptr_t ios_jit_anon_alias_lookup(uintptr_t fault_addr);
            if (!ios_jit_anon_alias_lookup( (uintptr_t)base ))
                madvise( base, size, MADV_DONTNEED );
        }
    }
    else  /* commit the pages */
    {
        int was_committed = (get_page_vprot( base ) & VPROT_COMMITTED) != 0;
        if (!(view = find_view( base, size ))) status = STATUS_NOT_MAPPED_VIEW;
        else if (view->protect & SEC_FILE) status = STATUS_ALREADY_COMMITTED;
        else if (view->protect & VPROT_FREE_PLACEHOLDER) status = STATUS_CONFLICTING_ADDRESSES;
        else if (!(status = set_protection( view, base, size, protect )) && (view->protect & SEC_RESERVE))
        {
            SERVER_START_REQ( add_mapping_committed_range )
            {
                req->base   = wine_server_client_ptr( view->base );
                req->offset = (char *)base - (char *)view->base;
                req->size   = size;
                wine_server_call( req );
            }
            SERVER_END_REQ;
        }
        /* ml293 (task #52): PA-arena recommit must read back as zero. */
        if (!status) ios_verify_commit_zero( base, size, protect, was_committed );
    }

    if (!status && (attributes & MEM_EXTENDED_PARAMETER_EC_CODE))
    {
        commit_arm64ec_map( view );
        set_arm64ec_range( base, size );
    }

    if (!status) VIRTUAL_DEBUG_DUMP_VIEW( view );

    server_leave_uninterrupted_section( &virtual_mutex, &sigset );

    if (status == STATUS_SUCCESS)
    {
        *ret = base;
        *size_ptr = size;
    }
    else if (status == STATUS_NO_MEMORY)
        ERR( "out of memory for allocation, base %p size %08lx\n", base, size );

    return status;
}


/***********************************************************************
 *             NtAllocateVirtualMemory   (NTDLL.@)
 *             ZwAllocateVirtualMemory   (NTDLL.@)
 */
NTSTATUS WINAPI NtAllocateVirtualMemory( HANDLE process, PVOID *ret, ULONG_PTR zero_bits,
                                         SIZE_T *size_ptr, ULONG type, ULONG protect )
{
    static const ULONG type_mask = MEM_COMMIT | MEM_RESERVE | MEM_TOP_DOWN | MEM_WRITE_WATCH | MEM_RESET;
    ULONG_PTR limit;
#ifdef WINE_IOS
    /* ml373: *ret is overwritten with the result, so the [guest-reserve] census
     * below cannot ask afterwards whether the caller supplied a hint — and a
     * hinted reserve is invisible to the steering valve (`!*ret`), which is a
     * different fix. Capture it here. */
    const int hint_was_set = (ret && *ret) ? 1 : 0;
#endif

    TRACE("%p %p %08lx %x %08x\n", process, *ret, *size_ptr, type, protect );
#ifdef WINE_IOS
    /* ml284: does ANYTHING allocate/commit executable memory, and where?
     *
     * There is already an exec-allocation probe here using ERR(), but the `virtual` debug
     * channel is filtered by MADEIRA_QUIET -- err:virtual: appears ZERO times in the logs,
     * including the uncapped first-30 lines it should always emit. So its silence carries
     * no information, and I must not read "no exec allocations happen" from it. (That is
     * the same mistake as the [unexec] probe, whose filters made me wrongly retract the
     * V8-code-space theory.) Working probes on this side all use raw dprintf(2) --
     * [iat-sync], [jit-pool], [steer], [x86-ptr] -- so use that.
     *
     * Covers BOTH allocate entry points: [exec-req] hooks only NtProtectVirtualMemory, but
     * VirtualAlloc(MEM_COMMIT, PAGE_EXECUTE_READWRITE) grants exec through
     * NtAllocateVirtualMemory, and VirtualAlloc2/placeholders through the Ex variant --
     * which V8 commonly uses for its code cage. Unfiltered by address, capped only by
     * count, so silence here really does mean "never requested". */
    /* ml288: narrowed. The first cut logged EVERY exec allocation and fired 52 times in
     * ml287, each a dprintf(2) syscall inside NtAllocateVirtualMemory. CEF's own depth then
     * dropped from 8 verbose lines (pref_proxy_config_tracker, 3 runs running) to 4
     * (VariationsSetupComplete, 2 runs running) exactly when that probe shipped. Two runs is
     * not proof against variance, but a probe that may perturb what it measures has to go on
     * a diet -- and its finding is already banked: exec allocations DO happen, the two 16MB
     * PAGE_EXECUTE_READWRITE ones get no [jit-pool] anon RWX carve, and there is no
     * EXHAUSTED. Only the large ones carry information, so log those. */
    /* ml290: re-widened to ALL sizes (cap 20).
     *
     * [guest-caller] named the caller of the recurring fault: chrome_elf.dll (+0x6c4a2 on
     * two different threads, plus +0xd7d6e and +0x10d4c0). chrome_elf is Chromium's early
     * loader, and its job is installing INTERCEPTION THUNKS -- it patches ntdll entry points
     * to jump into thunk memory it allocates itself. If that memory is not executable, the
     * first call through a hooked function lands on a non-executable page: our fault
     * exactly, at a stable small offset, and unrelated to proxying (ruled out in ml290 --
     * the fault still fired 23x with --no-proxy-server active).
     *
     * The >=1MB narrowing I applied in ml288 hides precisely the evidence needed, because
     * interception allocations are ONE PAGE each -- e.g. the three consecutive
     * req_addr=0x73d172{c,d,e}000 size=0x1000 protect=0x40 requests seen earlier, at
     * explicit addresses in the ntdll band. Cap 20 keeps the syscall cost far below the 52
     * of the first cut while restoring the small-allocation signal, so each request can be
     * matched against the [jit-pool] anon RWX carves that follow. */
    if (protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))
    {
        static int execalloc_n;
        if (execalloc_n < 20)
        {
            execalloc_n++;
            dprintf( 2, "[exec-alloc] %s #%d req_addr=%p size=0x%llx type=0x%x protect=0x%x\n",
                     "NtAllocateVirtualMemory", execalloc_n, ret ? *ret : NULL,
                     (unsigned long long)(size_ptr ? *size_ptr : 0), type, protect );
        }
    }
#endif

#ifdef WINE_IOS
    {
        static int alloc_dbg = 0;
        if (alloc_dbg++ < 30 || (protect & 0xF0))
            ERR("NtAllocateVirtualMemory: size=0x%lx type=0x%x prot=0x%x\n",
                (unsigned long)*size_ptr, type, protect);
    }
#endif

    if (!*size_ptr) return STATUS_INVALID_PARAMETER;
    if (zero_bits > 21 && zero_bits < 32) return STATUS_INVALID_PARAMETER_3;
    if (zero_bits > 32 && zero_bits < granularity_mask) return STATUS_INVALID_PARAMETER_3;
#ifndef _WIN64
    if (!is_old_wow64() && zero_bits >= 32) return STATUS_INVALID_PARAMETER_3;
#endif
    if (type & ~type_mask) return STATUS_INVALID_PARAMETER;

    if (process != NtCurrentProcess())
    {
        union apc_call call;
        union apc_result result;
        unsigned int status;

        memset( &call, 0, sizeof(call) );

        call.virtual_alloc.type         = APC_VIRTUAL_ALLOC;
        call.virtual_alloc.addr         = wine_server_client_ptr( *ret );
        call.virtual_alloc.size         = *size_ptr;
        call.virtual_alloc.zero_bits    = zero_bits;
        call.virtual_alloc.op_type      = type;
        call.virtual_alloc.prot         = protect;
        status = server_queue_process_apc( process, &call, &result );
        if (status != STATUS_SUCCESS) return status;

        if (result.virtual_alloc.status == STATUS_SUCCESS)
        {
            *ret      = wine_server_get_ptr( result.virtual_alloc.addr );
            *size_ptr = result.virtual_alloc.size;
        }
        else
        {
            WARN( "cross-process allocation failed, process=%p base=%p size=%08lx status=%08x",
                  process, *ret, *size_ptr, result.virtual_alloc.status );
        }
        return result.virtual_alloc.status;
    }

    if (!*ret)
        limit = get_zero_bits_limit( zero_bits );
    else
        limit = 0;

#ifdef WINE_IOS
    {
        NTSTATUS st;
        /* task #35 DEMAND CENSUS: is CEF's ~144GB real, or is it retries?
         * The [jumbo] lines are one-per-call, and PartitionAlloc re-rolls a
         * fresh random hint when a reserve fails — so three failed 16GB lines
         * are equally consistent with ONE pool retried three times as with
         * three distinct pools. 144GB is hopeless against a 63GB window; ~80GB
         * (3 pools + one 32GB region) is closeable by freeing slots. Log every
         * jumbo call with a sequence number, inter-call gap and thread so
         * retries (same size, same tid, sub-ms apart) separate from distinct
         * reservations — and so a caller that DEGRADES after failure (asks
         * again smaller) shows up as a descending size run. */
        void  *jumbo_hint = *ret;
        size_t jumbo_size = *size_ptr;
        int    is_jumbo   = (jumbo_size >= 0x40000000 && (type & MEM_RESERVE));
        /* ml125 [bigres]: settle the furniture attribution WITHOUT an FEX build.
         * The [window] probe found ~30 runs of ~511MB and I inferred FEXCore's
         * per-thread LookupCache (TotalCacheSize = VirtualMemSize/4096*8 +
         * CODE_SIZE + MAX_L1_SIZE) — but I have now mis-attributed this twice
         * from size coincidences alone, so measure it instead: every reserve
         * between 256MB and the 1GB jumbo threshold, with a running total and
         * count. If ~31 of these land at exactly 0x1ff10000 the attribution is
         * proven and the page-pointer array is the thing to shrink; if they are
         * a mix of sizes it is something else entirely and the FEX redesign
         * would have been wasted work. */
        if ((type & MEM_COMMIT) && ios_bigres_cnt && *ret)
            ios_bigres_commit( *ret, *size_ptr );
        /* ml151: a commit landing in a SOFT pool range — see ios_soft. The range
         * was never backed, so materialise exactly this sub-range now. Check the
         * kernel map first: if something already owns the VA (furniture, most
         * likely, since the only free aligned slot overlaps the furniture
         * window) that is the collision this design has to be judged on, so say
         * so loudly rather than silently handing PA someone else's memory. */
        if ((type & MEM_COMMIT) && ios_soft_n && *ret)
        {
            int si = ios_soft_find( (uint64_t)(uintptr_t)*ret );
            if (si >= 0)
            {
                uint64_t want = (uint64_t)(uintptr_t)*ret & ~(uint64_t)host_page_mask;
                size_t need = ROUND_SIZE( (uintptr_t)*ret - want, *size_ptr, host_page_mask );
                mach_vm_address_t a = (mach_vm_address_t)want;
                mach_vm_size_t rsz = 0;
                vm_region_basic_info_data_64_t inf;
                mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
                mach_port_t obj = MACH_PORT_NULL;
                int occupied = 0;

                if (mach_vm_region( mach_task_self(), &a, &rsz, VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&inf, &cnt, &obj ) == KERN_SUCCESS && a <= want)
                    occupied = 1;

                /* ml152: ask WINE first, not just the kernel. The soft range
                 * spans the furniture window, so most commits landing in it are
                 * ordinary allocations committing memory they legitimately
                 * reserved — the first cut labelled all 33 of them COLLISION and
                 * buried the real signal. If Wine owns a view here it is not our
                 * business: fall through silently. A genuine collision is VA that
                 * Wine does NOT own yet something else has mapped. */
                if (find_view( (void *)(uintptr_t)want, need ))
                {
                    /* furniture's own commit — normal path, no bookkeeping.
                     * ml434 (#72): EXCEPT the soft cages, which deliberately sit
                     * inside the PA guard pool's real (mostly dead) reservation —
                     * their commits ride the guard view silently, so count them
                     * and log the first few. A commit near the guard pool's
                     * ACTIVE bottom would be the collision to watch for. */
                    if (ios_soft[si].cage)
                    {
                        ios_soft[si].commits++;
                        ios_soft[si].committed += need;
                        if (ios_soft[si].commits <= 8)
                            dprintf(2, "[cage-commit] #%u 0x%llx+0x%lx in soft cage 0x%llx (total %lluMB) rev=ml434\n",
                                    ios_soft[si].commits, (unsigned long long)want, (unsigned long)need,
                                    (unsigned long long)ios_soft[si].base,
                                    (unsigned long long)(ios_soft[si].committed >> 20));
                    }
                }
                else if (occupied)
                {
                    ios_soft[si].commits++;
                    ios_soft[si].collisions++;
                    dprintf(2, "[soft-pool] COLLISION: commit 0x%llx+0x%lx inside soft 0x%llx —"
                               " VA mapped but NOT a wine view (0x%llx+0x%llx prot=%x/%x)."
                               " Foreign mapping in the pool range.\n",
                            (unsigned long long)want, (unsigned long)need,
                            (unsigned long long)ios_soft[si].base,
                            (unsigned long long)a, (unsigned long long)rsz,
                            inf.protection, inf.max_protection);
                }
                else
                {
                    unsigned int svp = 0;
                    void *mp;
                    ios_soft[si].commits++;
                    get_vprot_flags( protect, &svp, FALSE );
                    mp = anon_mmap_fixed( (void *)(uintptr_t)want, need,
                                          get_unix_prot( (BYTE)(svp | VPROT_COMMITTED) ), 0 );
                    ios_soft[si].committed += need;
                    dprintf(2, "[soft-pool] materialised 0x%llx+0x%lx in soft 0x%llx -> %p"
                               " (total %lluMB in %u calls)\n",
                            (unsigned long long)want, (unsigned long)need,
                            (unsigned long long)ios_soft[si].base, mp,
                            (unsigned long long)(ios_soft[si].committed >> 20),
                            ios_soft[si].commits);
                    if (mp != MAP_FAILED) { *ret = (void *)(uintptr_t)want; *size_ptr = need; return STATUS_SUCCESS; }
                }
            }
        }
        if (jumbo_size >= 0x10000000 && jumbo_size < 0x40000000 && (type & MEM_RESERVE))
        {
            static unsigned bigres_n;
            static unsigned long long bigres_tot;
            bigres_n++;
            bigres_tot += jumbo_size;
            ios_bigres_reserved_total += jumbo_size;
            /* ml126: ATTRIBUTE BY PROCESS, not by size. All 23 were exactly
             * 512MB, which rules out FEXCore's LookupCache (a computed sum) and
             * the CallRetStack (16MB), and no FEX VirtualAlloc site asks for
             * 512MB either -- so this may well be the GUEST (V8's x64
             * kMaximalCodeRangeSize is 512MB, which would fit CEF). ERR gives
             * the wine tid prefix for free, and the PEB identifies WHICH
             * pseudo-process: correlate against the [init-peb]/NtCreateUserProcess
             * map. If these are steamwebhelper's PEB it is CEF/V8 and the fix is
             * a command-line flag, not an FEX redesign -- a completely different
             * and far cheaper answer than the one I was about to build. */
            /* ml127: use dprintf, NOT ERR. The `virtual` debug channel's ERR is
             * suppressed in this build (err:virtual: appears 0 times in a log
             * with 526 err:seh: lines), so routing this through ERR to get the
             * tid prefix silenced the probe completely — 23 lines in ml126, 0 in
             * ml127. Same reason alloc_arm64ec_map's ERR has never appeared in
             * any log. Read the tid out of the TEB instead. */
            /* ml129: FEX's own hook ENCODES which structure this is, and I was
             * simply not printing it. AllocatorHooks.h does
             *   VirtualAlloc(Base, Size, Commit ? MEM_RESERVE|MEM_COMMIT : MEM_RESERVE,
             *                Execute ? PAGE_EXECUTE_READWRITE : PAGE_READWRITE)
             * so protect==0x40 (PAGE_EXECUTE_READWRITE) means an Execute
             * allocation -- a JIT code buffer (CPUBackend) or the dispatcher --
             * while 0x04 (PAGE_READWRITE) means data, and the MEM_COMMIT bit
             * separates the commit-upfront LookupCache path from pure reserves.
             * That splits the remaining candidates without an FEX build, and
             * without wiring a unixlib that iOS deliberately no-ops. */
            dprintf( 2, "[bigres] tid=%04x #%u size=0x%lx (%lu MB) type=0x%x prot=0x%x hint=%p peb=%p total=%llu MB\n",
                     NtCurrentTeb() ? (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread : 0,
                     bigres_n, (unsigned long)jumbo_size,
                     (unsigned long)(jumbo_size >> 20), (unsigned)type, (unsigned)protect,
                     jumbo_hint, NtCurrentTeb() ? NtCurrentTeb()->Peb : NULL, bigres_tot >> 20 );
            /* ml128: NAME THE CALLER. Elimination has run out — it is exactly
             * 2 x 512MB per guest thread of steam.exe (peb=0x11da68000, 12 tids),
             * and it is NOT the LookupCache (VirtualMemSize = 1ULL<<33 makes
             * TotalCacheSize ~96MB, below this probe's 256MB floor), NOT the
             * CallRetStack (16MB), NOT the emulator stack (256KB), and no FEX
             * VirtualAlloc site asks for 512MB. So stop reasoning about sizes and
             * read the return addresses off the stack, the same way [exit-stk]
             * does. Module base + offset is enough — names come from the
             * [jit-pool] image lines in the same log. */
            /* ml166: this scan HAS been running every run and I had simply never read its
             * output. Symbolising it settles the owner and REFUTES two earlier claims:
             *   - the 512MB reserves ARE FEX's own: mod 0x73f09d0000 = libarm64ecfex.dll,
             *     +0x125834/+0x125860 -> VirtualAlloc, +0x1e7e08 -> $iexit_thunk$cdecl$i8$i8.
             *     So "type=0x2000 proves the caller is NOT FEX" (the AllocatorHooks
             *     MEM_TOP_DOWN note) does NOT hold here, and the ml128 claim "no FEX
             *     VirtualAlloc site asks for 512MB" is wrong.
             *   - but those are FEX's own ALLOCATOR frames, the nearest ones. The subsystem
             *     that asked is deeper, and the old limits hid it: 6 hits, bigres_n <= 4.
             *
             * Scan deeper, report more, and cover the LATE reservations (#18+) which are the
             * ones that exhaust the window: 27 x 512MB filled 13.8GB of 15.1GB while
             * committing 1%, maxgap fell to 28MB, a 512MB reserve FAILED, and the NULL
             * return was stored through (`stp x8,x20,[x0]` with x0=0). Which FEX subsystem
             * this is decides the fix: smaller per-thread arena vs relocation above the
             * ceiling vs soft reservation. */
            if (bigres_n <= 4 || (bigres_n >= 18 && bigres_n <= 30))
            {
                uint64_t *sp = (uint64_t *)__builtin_frame_address(0);
                int w, hits = 0;
                for (w = 0; w < 1024 && hits < 20; w++)
                {
                    uint64_t mod = 0, va = ios_jit_reverse_translate( sp[w], &mod );
                    if (va && mod && va != sp[w])
                    {
                        dprintf( 2, "[bigres]   caller#%u sp+0x%x: 0x%llx = mod 0x%llx +0x%llx\n",
                                 bigres_n, w * 8, (unsigned long long)sp[w],
                                 (unsigned long long)mod, (unsigned long long)(va - mod) );
                        hits++;
                    }
                }

                /* ml167 GUEST-STACK ATTRIBUTION — the one route not yet tried.
                 *
                 * The native scan above is NOT proof of ownership: it surfaces any
                 * code-like value on the stack, including DEAD frames from earlier FEX
                 * activity on that thread, and I over-trusted its libarm64ecfex hits last
                 * round. The flags actually EXCLUDE every FEX site I can enumerate —
                 * type=0x2000 has no MEM_TOP_DOWN, and FEXCore::Allocator::VirtualAlloc
                 * unconditionally ORs it (AllocatorHooks.h: Flags = (Commit?MEM_COMMIT:0)
                 * | MEM_RESERVE | MEM_TOP_DOWN); CallRetStack is MEM_TOP_DOWN+PAGE_NOACCESS;
                 * the iOS LookupCache path passes Commit=true (FEX_IOS_HOST=1 is global).
                 *
                 * All four earlier attribution attempts were RIP-based and returned NATIVE
                 * addresses inside VirtualAlloc itself. So walk the GUEST stack instead:
                 * the saved x64 CONTEXT is at CPUArea+0x50, Rsp at +0x98 (Rip at +0xF8, as
                 * the ios_guest_ctx_rip comment records). x86-64 return addresses there
                 * point at PE module VAs, which are STABLE all run (unlike pool copies the
                 * freelist recycles), so they resolve offline against [jit-pool] image.
                 *
                 * What this decides: 2 x 512MB per guest thread at 1% commit, with
                 * [bigres] total only ever GROWING, is either a size knob or a per-thread
                 * reservation never released on thread exit — both cheap and safe. Only if
                 * it is neither do we need overcommit/aliasing, which is unsound in general
                 * (an app is entitled to grow into a range it reserved). */
                {
                    TEB *t = NtCurrentTeb();
                    void *ca = t ? *(void **)((char *)t + 0x1788) : NULL;

                    if ((uintptr_t)ca >= 0x10000)
                    {
                        uint64_t grsp = *(uint64_t *)((char *)ca + 0x50 + 0x98);
                        uint64_t grip = *(uint64_t *)((char *)ca + 0x50 + 0xF8);

                        dprintf( 2, "[bigres]   guest#%u rsp=0x%llx rip=0x%llx\n",
                                 bigres_n, (unsigned long long)grsp,
                                 (unsigned long long)grip );
                        /* Only read the guest stack if Wine owns the range. A raw deref
                         * here would fault mid-syscall (this is not a signal handler, so
                         * it would surface as a real AV and cost the run). find_view is
                         * the header-free check already available in this TU. */
                        if (grsp >= 0x10000 && !(grsp & 7)
                            && find_view( (const void *)(uintptr_t)grsp, 0x1000 ))
                        {
                            const uint64_t *gs = (const uint64_t *)(uintptr_t)grsp;
                            int g, gh = 0;
                            for (g = 0; g < 256 && gh < 12; g++)
                            {
                                uint64_t v = gs[g];
                                if (v < 0x7300000000ULL || v >= 0x7400000000ULL) continue;
                                dprintf( 2, "[bigres]   guest#%u rsp+0x%x: 0x%llx\n",
                                         bigres_n, g * 8, (unsigned long long)v );
                                gh++;
                            }
                        }
                    }
                }
            }
        }
        /* task#29 CEF: PartitionAlloc (chrome_elf DllMain) reserves multi-GB
         * pools. iOS caps user VA at 0x8000000000 (39-bit; extended-VA is not
         * available to free personal teams) and wine's furniture (PE images,
         * TEBs, stacks, EC bitmap) clusters at the TOP of that space. */
        if (!*ret && *size_ptr >= 0x40000000 && (type & MEM_RESERVE) && !limit)
        {
            /* ml92 (task #35) MEASURED, replacing two generations of guesses.
             * The original target was [256G,480G) — written before the GPU
             * carveout was known, and 192GB of it is carveout, so it could
             * never be served. The replacement target [8G,64G) is no better:
             * the map walk shows the only free region below 64G is
             * 0..0x102454000 = __PAGEZERO, and 4G-64G is fully reserved
             * (malloc xzone). There is no middle zone. Usable VA is exactly
             * one window, 0x7038000000..0x7fffdf0000 (~63GB), which is what
             * the default search already targets — so skip the pointless
             * pre-attempt and let the hinted-retry slot walk below do the
             * work. Probe the map when we come up short. */
            st = allocate_virtual_memory( ret, size_ptr, type, protect, 0, limit, 0, 0 );
            if (st)
            {
                static int probed;
                dprintf(2, "[jumbo] kernel-pick reserve failed (0x%x) for size=0x%lx — top window is full\n",
                        (unsigned)st, (unsigned long)*size_ptr);
                if (probed++ < 2)
                {
                    ios_va_gap_probe( "jumbo reserve failed" );
                    /* task #35: the gap walk says HOW MUCH is left; this says
                     * WHAT ate the window, which is what decides whether a
                     * third pool is reachable at all. */
                    ios_window_inventory( "jumbo reserve failed",
                                          ios_usable_va_floor, ios_furniture_ceiling );
                    ios_slot_probe( "jumbo reserve failed" );
                    ios_bigres_report( "jumbo reserve failed" );
                    ios_soft_report( "jumbo reserve failed" );
                }
            }
        }
        else
        {
            /* ml168 STEERING VALVE (task #35/#36): under furniture pressure, place
             * large RESERVE-ONLY, unhinted allocations ABOVE the furniture ceiling.
             *
             * Deliberately a PRESSURE VALVE, not a behaviour change: it arms only once
             * >8GB of 256MB..1GB reserves have already been granted, which never happens
             * in a Thumper run, so existing working cases keep their exact placement.
             * MEM_COMMIT requests are excluded — those are backed immediately and belong
             * where the allocator would normally put them; only reserve-only ranges (the
             * 1%-committed kind measured by [bigres-use]) get moved.
             *
             * Above the ceiling the space is the pool slots, which [bigres-use] shows at
             * 0% committed (POOL 0x7400000000/0x7800000000/0x7c00000000 all 0MB), so the
             * range is there to use. It is NOT free of risk: PartitionAlloc owns those
             * slots and could commit into one later, which the [soft-pool] COLLISION
             * detector would then report. That is why this stays pressure-gated and why
             * it always FALLS BACK to normal placement on failure — a steer that cannot
             * be served must never be worse than not steering. */
            int ios_steered = 0;

            /* ml373: floor 256MB -> 32MB.
             *
             * ml373 died with the guest window at 15195 MB of 15232 (free=36 MB,
             * maxhole=3 MB): steamclient64.dll (0x1964000 = 25 MB) could not be
             * mapped, c0000017 x28, webhelper dead — and the run logged ZERO
             * [steer] lines, i.e. the valve never fired once. The [window]
             * histogram says why: the guest band is eaten by n=88 reserves in the
             * <=512M bucket (8438 MB) and n=151 in the <=64M bucket (4993 MB),
             * while the valve only ever considered [256MB, 1GB). FEX is NOT the
             * hog — [vname] totals put 5.4GB of FEXMem_* correctly in [0x7c,0x80)
             * and only 81MB in the guest band — so this is Steam/CEF's own
             * reserve-only memory, exactly the 1%-committed kind this valve was
             * built to move.
             *
             * Same target band as before ([0x7c,0x80), which [vname] shows is
             * ~10GB free), same pressure gate, same fall-back-on-failure rule, so
             * a steer that cannot be served is still never worse than not
             * steering. The 1GB ceiling stays: >=1GB reserves are PartitionAlloc
             * pool business and go through the jumbo path above. */
            /* iOS-Madeira ml462 (#77): V8 CodeRange placement service + livelock
             * breaker. Signature: kernel-pick, reserve-only, PAGE_NOACCESS,
             * 512MB(+slop) — V8's kMaximalCodeRangeSize, wanting to land within
             * jump distance of libcef's embedded builtins in the module band
             * (its own preferred hint 0x71e0000000 collides with loaded DLLs
             * and everything the kernel picks elsewhere gets rejected+released;
             * ml461 looped this forever). Serve it from [0x7100000000,
             * 0x71c0000000) — free space directly below the module band, ~1GB
             * from the builtins. V8 redoes its own alignment two-step inside
             * the zone (the aligned re-reserve arrives hinted and the normal
             * path grants it). If the guest has already cycled 32 grants of
             * this shape, placement cannot satisfy it — deny outright so V8
             * fails NAMED in cef_log instead of eating the FEX band. */
            if (!*ret && !limit && (type & MEM_RESERVE) && !(type & MEM_COMMIT)
                && protect == PAGE_NOACCESS
                && *size_ptr >= 0x20000000 && *size_ptr <= 0x20100000)
            {
                unsigned ctid = NtCurrentTeb() ? (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread : 0;
                unsigned cyc = ios_reserve_cycle_count( ctid, *size_ptr );
                static unsigned cr_logs;
                if (cyc >= 32)
                {
                    if (cr_logs < 16)
                        dprintf(2, "[coderange] DENY tid=%04x size=0x%lx cycles=%u — placement livelock, failing honestly rev=ml462\n",
                                ctid, (unsigned long)*size_ptr, cyc);
                    cr_logs++;
                    return STATUS_NO_MEMORY;
                }
                {
                    SIZE_T cwant = *size_ptr;
                    void *csaved = *ret;
                    /* ml463: floor raised 0x7100000000 -> 0x7180000000. The
                     * ml462 run granted the zone BOTTOM (0x7100000000, ~3.5GB
                     * from the builtins) and V8 cycled 4 more grant/release
                     * rounds before settling — consistent with a ±2GB reach
                     * check (acceptable floor ~0x7162000000). Start inside the
                     * window so the first grant sticks. */
                    NTSTATUS cst = allocate_virtual_memory( ret, size_ptr, type, protect,
                                                            0x7180000000ULL, 0x71c0000000ULL, 0, 0 );
                    if (cr_logs < 16)
                        dprintf(2, "[coderange] #%u tid=%04x size=0x%lx cycles=%u -> %s %p rev=ml462\n",
                                cr_logs, ctid, (unsigned long)cwant, cyc,
                                cst ? "zone FULL, falling through" : "near-builtins zone", *ret);
                    cr_logs++;
                    if (!cst) { st = cst; ios_steered = 1; }
                    else { *ret = csaved; *size_ptr = cwant; }
                }
            }

            if (!ios_steered
                && !*ret && !limit && (type & MEM_RESERVE) && !(type & MEM_COMMIT)
                && *size_ptr >= 0x2000000 && *size_ptr < 0x40000000
                && (ios_bigres_reserved_total > (8ull << 30) || ios_va_pressure))
            {
                SIZE_T want = *size_ptr;
                void *saved = *ret;
                static unsigned steer_n;
                /* ml462 (#77): per-tid intake cap. The valve was sized for the
                 * ~25-55 legitimate leaked-per-thread reserves it was built for
                 * (ml171); ml461's livelock fed it an INFINITE stream from two
                 * tids and it spilled 15.5GB into the FEX band before the
                 * process starved. No sane consumer needs more than 24 steered
                 * arenas; past that, stop feeding it — the ask falls through to
                 * the normal path and fails honestly. */
                static struct { unsigned tid; unsigned n; } steer_tid[16];
                unsigned sti, sslot = 0xffff;
                unsigned stid = NtCurrentTeb() ? (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread : 0;
                for (sti = 0; sti < 16; sti++)
                {
                    if (steer_tid[sti].tid == stid) { sslot = sti; break; }
                    if (sslot == 0xffff && !steer_tid[sti].tid) sslot = sti;
                }
                if (sslot == 0xffff) sslot = stid & 15;
                if (steer_tid[sslot].tid != stid) { steer_tid[sslot].tid = stid; steer_tid[sslot].n = 0; }
                if (steer_tid[sslot].n >= 24)
                {
                    if (steer_tid[sslot].n == 24)
                    {
                        steer_tid[sslot].n++;
                        dprintf(2, "[steer] tid=%04x CAPPED at 24 steered arenas — refusing further FEX-band spill rev=ml462\n", stid);
                    }
                }
                else
                {
                steer_tid[sslot].n++;
                /* ml169: `limit` is 0 here ("unconstrained"), so passing it as limit_high
                 * described the EMPTY range [ios_spill_cap, 0) and every steer failed with
                 * *ret = 0x0. The upper bound has to be a real address: use the host VA
                 * ceiling, which is_beyond_limit treats as EXCLUSIVE. */
                NTSTATUS sst = allocate_virtual_memory( ret, size_ptr, type, protect,
                                                        ios_steer_slot,
                                                        (ULONG_PTR)host_addr_space_limit,
                                                        0, 0 );
                /* ml171: 16GB is not enough. Surviving longer spawns more threads, so
                 * the reserve count went 27 -> 55 (28160MB) and BOTH the steer slot and
                 * furniture reported va-scan FAILED maxgap=0 before the NULL deref.
                 * Fall back to the 0x7400000000 slot, which this run left UNGRANTED —
                 * pools landed on 0x7000000000, 0x73ffff0000 and 0x7800000000, matching
                 * the 3-pool census. That doubles steer capacity to ~32GB. */
                if (sst)
                {
                    *ret = saved; *size_ptr = want;
                    sst = allocate_virtual_memory( ret, size_ptr, type, protect,
                                                   0x7400000000ULL, ios_spill_cap, 0, 0 );
                }
                /* ml173: both steer slots full -> reclaim ranges owned by threads that
                 * have since exited, then retry once. This is what makes the steer
                 * region sustainable: the reserves leak per-thread, so without this any
                 * fixed capacity is exhausted by a long enough run. */
                if (sst && ios_steer_reclaim_dead())
                {
                    *ret = saved; *size_ptr = want;
                    sst = allocate_virtual_memory( ret, size_ptr, type, protect,
                                                   ios_steer_slot,
                                                   (ULONG_PTR)host_addr_space_limit, 0, 0 );
                    if (sst)
                    {
                        *ret = saved; *size_ptr = want;
                        sst = allocate_virtual_memory( ret, size_ptr, type, protect,
                                                       0x7400000000ULL, ios_spill_cap, 0, 0 );
                    }
                }
                if (!sst && ios_steer_n < IOS_STEER_MAX)
                {
                    ios_steer[ios_steer_n].base = (uint64_t)(uintptr_t)*ret;
                    ios_steer[ios_steer_n].size = want;
                    ios_steer[ios_steer_n].tid  =
                        NtCurrentTeb() ? (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread : 0;
                    ios_thread_alive( ios_steer[ios_steer_n].tid );   /* tid recycling: see above */
                    ios_steer[ios_steer_n].freed = 0;
                    ios_steer_n++;
                }
                /* ml210: was 12, which was BELOW the ~25-50 reserves a Steam run makes, so
                 * the log count saturated and could not measure how many arenas actually
                 * got steered. */
                if (steer_n < 64)
                {
                    steer_n++;
                    dprintf(2, "[steer] #%u size=0x%lx reserved_total=%lluMB armed=%s -> %s %p\n",
                            steer_n, (unsigned long)want,
                            (unsigned long long)(ios_bigres_reserved_total >> 20),
                            ios_va_pressure ? "va-pressure" : "8GB-total",
                            sst ? "FAILED, falling back" : "above ceiling", *ret);
                }
                if (!sst) { st = sst; ios_steered = 1; }
                else { *ret = saved; *size_ptr = want; }   /* fall back to normal */
                }   /* ml462 per-tid cap else-block */
            }
            if (!ios_steered)
                st = allocate_virtual_memory( ret, size_ptr, type, protect, 0, limit, 0, 0 );

            /* ml373 census: name what still lands in the guest band once the
             * valve has had its say. The [window] histogram gives sizes but no
             * owner, so a single wrong guess about WHO reserves the 8.4GB costs a
             * run. Reserve-only, >=8MB, guest band only, capped — and it prints
             * whether the request was hinted, since a hinted reserve is invisible
             * to the valve (`!*ret`) and would need a different fix. */
            if (!st && *ret && (type & MEM_RESERVE) && !(type & MEM_COMMIT)
                && *size_ptr >= 0x800000 && (ULONG_PTR)*ret < 0x7400000000ull)
            {
                static unsigned gb_n;
                static ULONG64 gb_total;
                gb_total += *size_ptr;
                if (gb_n++ < 48)
                    dprintf( 2, "[guest-reserve] #%u %p+0x%llx hinted=%d tid=%04x prot=0x%x "
                                "running_total=%lluMB\n",
                             gb_n, *ret, (unsigned long long)*size_ptr, hint_was_set,
                             NtCurrentTeb() ? (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread : 0,
                             protect, (unsigned long long)(gb_total >> 20) );
            }
            /* task#29 CEF plan C: a HINTED jumbo reserve that fails placement
             * is retried as kernel-pick. Windows semantics say fail on
             * conflict, but PartitionAlloc-style callers use the returned
             * pointer (the hint is just ASLR seasoning) and its hints are
             * 47-bit randoms that can never fit under the iOS 512GB VA
             * ceiling. Serving from wherever we have room lets PA take its
             * aligned pool from the top hole instead of dying in the 32GB
             * fallback. Jumbo-only, loudly logged. */
            if (st && *ret && *size_ptr >= 0x40000000 && (type & MEM_RESERVE))
            {
                void *hint = *ret;
                void *pick = NULL;
                SIZE_T sz = *size_ptr;
                NTSTATUS st2 = STATUS_NO_MEMORY;
                /* Preserve the hint's offset within its natural alignment:
                 * PartitionAlloc hints (16GB boundary - 64KB) encode a
                 * guard-before-pool layout and it REJECTS a redirect that is
                 * merely 16GB-aligned (observed ml62: 0x7800000000 handed
                 * back three times, freed each time, then the fatal 32GB
                 * fallback). Walk the aligned slots in the usable top arena
                 * and try hint_offset-preserving fixed placements first. */
                ULONG_PTR align_unit = 0x400000000ULL;              /* 16GB */
                ULONG_PTR off = (ULONG_PTR)hint & (align_unit - 1);
                ULONG_PTR slot;
                /* ml106 packing rule: a guard-style reservation (off != 0,
                 * PartitionAlloc's boundary-minus-64KB layout) overhangs 64KB
                 * BELOW its slot, so placed high it poisons the slot beneath —
                 * that single overhang is why only 2 of 3 pools ever fit. Fill
                 * guard-style requests BOTTOM-UP from the ceiling (first cand
                 * 0x73ffff0000, whose overhang lands on furniture-free space by
                 * construction) and off=0 requests TOP-DOWN from 0x7C00000000.
                 * Perfect packing: [0x73ffff0000,0x78) guard, [0x78,0x7C) and
                 * [0x7C,0x8000000000) off=0 — all three pools fit. */
                /* ml122: start the guard walk at the first slot AT OR ABOVE the
                 * furniture ceiling. The old hardcoded 0x7400000000 base was
                 * written for the 0x73ffff0000 ceiling; with the ceiling now at
                 * 0x77ffff0000 that first candidate lands inside the furniture
                 * window and is guaranteed to fail, wasting an attempt. By
                 * construction ceiling == slot - 64KB, so the first viable
                 * guard candidate is exactly the ceiling itself. */
                ULONG_PTR guard_first = (ios_furniture_ceiling
                                         ? ((ios_furniture_ceiling + align_unit) & ~(align_unit - 1))
                                         : 0x7400000000ULL);
                if (off)
                {
                    for (slot = guard_first; slot <= 0x7C00000000ULL && st2; slot += align_unit)
                    {
                        void *cand = (void *)(slot + off - align_unit);
                        SIZE_T csz = *size_ptr;
                        pick = cand;
                        st2 = allocate_virtual_memory( &pick, &csz, type, protect, 0, 0, 0, 0 );
                        dprintf(2, "[jumbo] cand guard slot=0x%llx -> %p size=0x%lx st=0x%x\n",
                                (unsigned long long)slot, cand, (unsigned long)csz, (unsigned)st2);
                        if (!st2) sz = csz;
                    }
                }
                else for (slot = 0x7C00000000ULL; slot >= 0x6800000000ULL && st2; slot -= align_unit)
                {
                    void *cand = (void *)slot;
                    SIZE_T csz = *size_ptr;
                    if ((ULONG_PTR)cand < 0x6000000000ULL) break;
                    pick = cand;
                    st2 = allocate_virtual_memory( &pick, &csz, type, protect, 0, 0, 0, 0 );
                    dprintf(2, "[jumbo] cand plain slot=0x%llx size=0x%lx st=0x%x\n",
                            (unsigned long long)slot, (unsigned long)csz, (unsigned)st2);
                    if (!st2) sz = csz;
                }
                /* ml433 (#72): an 8GB ask is the process-wide V8/cppgc cage and
                 * must come back 8GB-ALIGNED, or the guest frees it and dies in
                 * a 16GB overreserve retry loop — serve it from the boot
                 * holdback, the only aligned stretch left. See IOS_CAGE_BASE. */
                if (st2 && ios_cage_holdback_live && *size_ptr == 0x200000000ULL)
                {
                    SIZE_T csz = IOS_CAGE_REAL_SIZE;
                    munmap( (void *)(uintptr_t)IOS_CAGE_BASE, IOS_CAGE_REAL_SIZE );
                    ios_cage_holdback_live = 0;
                    pick = (void *)(uintptr_t)IOS_CAGE_BASE;
                    st2 = allocate_virtual_memory( &pick, &csz, type, protect, 0, 0, 0, 0 );
                    if (!st2 && (uintptr_t)pick == IOS_CAGE_BASE)
                    {
                        sz = *size_ptr;   /* report the full 8GB; the real view is 64K short */
                        if (ios_soft_n < IOS_SOFT_MAX)
                        {
                            ios_soft[ios_soft_n].base = IOS_CAGE_BASE + IOS_CAGE_REAL_SIZE;
                            ios_soft[ios_soft_n].size = 0x200000000ULL - IOS_CAGE_REAL_SIZE;
                            ios_soft[ios_soft_n].cage = 1;
                            ios_soft_n++;
                        }
                    }
                    else if (!st2) sz = csz;   /* landed elsewhere: honest grant, no size lie */
                    dprintf(2, "[cage] grant %p real=0x%llx reported=0x%lx st=0x%x rev=ml433\n",
                            pick, (unsigned long long)IOS_CAGE_REAL_SIZE,
                            (unsigned long)(st2 ? 0 : sz), (unsigned)st2);
                }
                /* ml434 (#72 layer 2): the 4GB ask is the cppgc caged heap and
                 * must come back 4GB-ALIGNED. By the time it arrives (~69s) the
                 * furniture window is 89% full (ml433: free=1701MB, maxhole
                 * 1557MB) — no real placement can EVER work, aligned or not. But
                 * the PA guard pool's real 16GB reservation [0x73ffff0000,
                 * 0x77ffff0000) has ~12MB committed at its very bottom and the
                 * two soft pools claiming that band have 0 commits ever, so
                 * SOFT-grant the cage deep inside the dead zone. Commits ride
                 * the guard view (see [cage-commit] in the soft handler); the
                 * collision to watch is BRP growing 8GB up from its bottom. */
                if (st2 && *size_ptr == 0x100000000ULL)
                {
                    static const uint64_t cage4_slots[] = { 0x7600000000ULL, 0x7500000000ULL };
                    unsigned ci;
                    for (ci = 0; ci < 2 && st2; ci++)
                    {
                        if (ios_soft_slot_taken( cage4_slots[ci] )) continue;
                        if (ios_soft_n >= IOS_SOFT_MAX) break;
                        ios_soft[ios_soft_n].base = cage4_slots[ci];
                        ios_soft[ios_soft_n].size = 0x100000000ULL;
                        ios_soft[ios_soft_n].cage = 1;
                        ios_soft_n++;
                        pick = (void *)(uintptr_t)cage4_slots[ci];
                        sz = *size_ptr;
                        st2 = 0;
                        dprintf(2, "[cage] soft-grant %p size=0x%lx (4GB cage in PA guard dead zone) rev=ml434\n",
                                pick, (unsigned long)sz);
                    }
                }
                if (st2)
                {
                    pick = NULL;
                    sz = *size_ptr;
                    st2 = allocate_virtual_memory( &pick, &sz, type, protect, 0, 0, 0, 0 );
                }
                dprintf(2, "[jumbo] hinted reserve %p size=0x%lx failed (0x%x) — offset-preserving retry -> %p (0x%x)\n",
                        hint, (unsigned long)*size_ptr, (unsigned)st, pick, (unsigned)st2);
                if (st2)
                {
                    static int probed2;
                    if (probed2++ < 2)
                    {
                        ios_va_gap_probe( "hinted jumbo retry exhausted" );
                        ios_window_inventory( "hinted jumbo retry exhausted",
                                              ios_usable_va_floor, ios_furniture_ceiling );
                        ios_slot_probe( "hinted jumbo retry exhausted" );
                        ios_bigres_report( "hinted jumbo retry exhausted" );
                    }
                }
                if (!st2)
                {
                    *ret = pick;
                    *size_ptr = sz;
                    st = STATUS_SUCCESS;
                }
                else if (ios_soft_n < IOS_SOFT_MAX && *size_ptr >= 0x400000000ULL)
                {
                    /* ml151: every real placement failed. Hand PA a 16GB-aligned
                     * slot nobody has taken and record it SOFT — see ios_soft.
                     * A guard-style request wants base = slot - 64KB; that guard
                     * page is a deliberate forbidden zone PA never commits, so it
                     * costs nothing that it may be unmappable. */
                    uint64_t slot;
                    for (slot = 0x7000000000ULL; slot < 0x8000000000ULL; slot += align_unit)
                    {
                        void *probe_addr = (void *)(uintptr_t)slot;
                        SIZE_T probe_sz = 0x10000;
                        NTSTATUS pst;

                        if (ios_soft_slot_taken( slot )) continue;
                        /* ml170: reserved for steered 512MB reserves (see
                         * ios_steer_slot) -- granting it as a pool is what caused
                         * the 43 collisions and cost us the 4th pool. */
                        if (slot == ios_steer_slot) continue;
                        /* ml213: never hand PA a slot that OVERLAPS THE FURNITURE WINDOW.
                         *
                         * The window starts at 0x7038000000, which is INSIDE
                         * [0x7000000000,0x7400000000), so every Wine/FEX allocation --
                         * including FEX's kernel-picked RWX JIT buffers -- packs the bottom
                         * of that slot. The [furniture] census measured 57347 foreign 16KB
                         * regions sitting there, and PA duly died on
                         *   [soft-pool] COLLISION: commit 0x7000200000+0x4000 inside soft
                         *   0x7000000000 -- VA mapped but NOT a wine view (prot=3/7)
                         * followed by a Chromium int3 (0x80000003) that aborted libcef
                         * init. A soft pool is only sound where nothing else allocates, and
                         * this is precisely where everything else allocates.
                         *
                         * Expressed as an overlap test rather than a hardcoded address so
                         * it stays correct if the window or the slot stride moves. */
                        if (slot < ios_furniture_ceiling
                            && slot + (uint64_t)*size_ptr > 0x7038000000ULL)
                            continue;
                        /* skip a slot that already holds a REAL pool: a 64KB
                         * probe reserve at its base would succeed only if free */
                        probe_addr = NULL; probe_sz = 0;
                        (void)probe_addr; (void)probe_sz; (void)pst;

                        ios_soft[ios_soft_n].base = slot;
                        ios_soft[ios_soft_n].size = *size_ptr;
                        ios_soft[ios_soft_n].committed = 0;
                        ios_soft[ios_soft_n].commits = 0;
                        ios_soft[ios_soft_n].collisions = 0;
                        ios_soft_n++;
                        *ret = (void *)(uintptr_t)(off ? slot + off - align_unit : slot);
                        st = STATUS_SUCCESS;
                        dprintf(2, "[soft-pool] GRANTED soft 0x%llx (base returned %p, size=0x%lx)"
                                   " — unbacked, commits materialise on demand\n",
                                (unsigned long long)slot, *ret, (unsigned long)*size_ptr);
                        break;
                    }
                }
            }
        }

        if (is_jumbo) ios_jumbo_census( jumbo_hint, jumbo_size, st ? NULL : *ret, (unsigned)st );
        if (!st && *size_ptr >= 0x10000000 && *size_ptr < 0x40000000 && (type & MEM_RESERVE))
            ios_bigres_note( *ret, *size_ptr );
        if (!st) ios_span_census( *ret, *size_ptr, 0 );   /* ml435 (#73) */

        /* iOS-Madeira ml310 (task #54): SYSCALL-BOUNDARY census of arena-band allocations.
         *
         * ml310's [va-arena] probe inside allocate_virtual_memory's reserve branch logged 26 lines,
         * ALL of them size=0x20000000 type=0x2000 (jemalloc's MEM_RESERVE-only arenas) and NOT ONE
         * of the 0x3000 FEXMem_ThreadState allocations -- even though three of those landed on
         * duplicate addresses that run (0x7d00001000, 0x7d80001000, 0x7ea0001000). So the small
         * MEM_COMMIT|MEM_RESERVE|MEM_TOP_DOWN allocations that actually collide are served by some
         * other path and that probe can never see them.
         *
         * Log here instead, at the syscall exit, where *ret is final no matter which internal route
         * produced it (normal allocate_virtual_memory, the steer retry ladder, the soft-pool commit
         * path, or the jumbo hint fallback). Placed in BOTH NtAllocateVirtualMemory and
         * NtAllocateVirtualMemoryEx because FEX's ARM64EC AllocatorHooks calls ::VirtualAlloc2, so
         * the Ex variant is the one FEX actually uses. Reports size/type/tid plus whether the
         * address falls inside a live ios_steer[] reservation. */
        /* ml311: gate on MEM_RESERVE. The ml310 cut logged every arena-band result and the 60-line
         * cap was consumed entirely by tid 006c's MEM_COMMIT-only (type=0x1000) 64KB commits
         * marching through its own jemalloc reservation -- all legitimate, and none of them the
         * FEXMem_ThreadState allocation being hunted, which carries
         * MEM_COMMIT|MEM_RESERVE|MEM_TOP_DOWN (0x103000). Reserving allocations are the only ones
         * that can CHOOSE an address, so they are the only ones that can collide. */
        if (!st && *ret && (uint64_t)(uintptr_t)*ret >= 0x7C00000000ULL)
        {
            static int nc;
            uint64_t nb = (uint64_t)(uintptr_t)*ret;
            unsigned i, hit = (unsigned)-1;
            for (i = 0; i < ios_steer_n; i++)
            {
                if (!ios_steer[i].base) continue;
                if (nb < ios_steer[i].base || nb >= ios_steer[i].base + ios_steer[i].size) continue;
                hit = i; break;
            }
            /* ml312: mark the arena in use for EVERY allocation that lands in it, reserving or
             * committing alike -- a commit is just as much a claim on the memory as a reserve, and
             * the reclaim must not recycle either. Note this runs unconditionally, outside the
             * logging cap, so the flag can never depend on how much has been printed. */
            /* ml331: COUNT interior allocations instead of latching a flag. ml330 made the
             * flag permanent (an arena with any interior allocation was never released), which
             * fixed the corruption but leaked VA: ml330 reached 69 arenas / 35GB reserved in the
             * 64GB window CEF also needs, and FEXCore CreateThread's unchecked aligned_alloc
             * returned NULL and stored through it (#43 again). Refcount instead: bump here,
             * drop on interior MEM_RELEASE, and reclaim only at zero. */
            /* ml331b: bump ONLY on MEM_RESERVE. The ml312 flag deliberately counted commits
             * too, which was right for a latch but wrong for a refcount: a region that is
             * reserved then committed would bump twice and be released once, so the count
             * could never reach zero and the arena would leak exactly as in ml330. The
             * reservation is the claim on the range; MEM_RELEASE is its only counterpart. */
            /* ml332: REVERTED to latch semantics. The ml331 refcount gated bumps on
             * MEM_RESERVE, but jemalloc's interior activity is MEM_COMMIT inside the one
             * big reservation -- so every arena counted as empty, 8 arenas (4GB) were
             * released with live contents, and the GuestToHostMap corruption came straight
             * back (ml331 crash == ml329 crash, minutes after 'released 4096MB'). The
             * ml312 comment said it: a commit is as much a claim as a reserve. Deeper:
             * FEX's jemalloc heap is SHARED across threads, so 'owning thread died' was
             * never a valid release condition at all. VA pressure is solved by smaller
             * arenas (FEX side), not by releasing shared memory. */
            if (hit != (unsigned)-1 && nb != ios_steer[hit].base) ios_steer[hit].inuse = 1;

            if ((type & MEM_RESERVE) && nc++ < 80)
            {
                dprintf( 2, "[va-exit] rev=ml312 %p+0x%lx type=0x%x tid=%04x steer=%s%u freed=%u steer_n=%u\n",
                         *ret, (unsigned long)*size_ptr, (unsigned)type,
                         NtCurrentTeb() ? (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread : 0,
                         hit == (unsigned)-1 ? "NONE#" : "INSIDE#",
                         hit == (unsigned)-1 ? ios_steer_n : hit,
                         hit == (unsigned)-1 ? 0 : ios_steer[hit].freed, ios_steer_n );
            }
        }
        return st;
    }
#else
    return allocate_virtual_memory( ret, size_ptr, type, protect, 0, limit, 0, 0 );
#endif
}


static NTSTATUS get_extended_params( const MEM_EXTENDED_PARAMETER *parameters, ULONG count,
                                     ULONG_PTR *limit_low, ULONG_PTR *limit_high, ULONG_PTR *align,
                                     ULONG *attributes, USHORT *machine )
{
    ULONG i, present = 0;

    if (count && !parameters) return STATUS_INVALID_PARAMETER;

    for (i = 0; i < count; ++i)
    {
        if (parameters[i].Type >= 32) return STATUS_INVALID_PARAMETER;
        if (present & (1u << parameters[i].Type)) return STATUS_INVALID_PARAMETER;
        present |= 1u << parameters[i].Type;

        switch (parameters[i].Type)
        {
        case MemExtendedParameterAddressRequirements:
        {
            MEM_ADDRESS_REQUIREMENTS *r = parameters[i].Pointer;
            ULONG_PTR limit;

            if (is_wow64()) limit = get_wow_user_space_limit();
            else limit = (ULONG_PTR)user_space_limit;

            if (r->Alignment)
            {
                if ((r->Alignment & (r->Alignment - 1)) || r->Alignment - 1 < granularity_mask)
                {
                    WARN( "Invalid alignment %lu.\n", r->Alignment );
                    return STATUS_INVALID_PARAMETER;
                }
                *align = r->Alignment;
            }
            if (r->LowestStartingAddress)
            {
                *limit_low = (ULONG_PTR)r->LowestStartingAddress;
                if (*limit_low >= limit || (*limit_low & granularity_mask))
                {
                    WARN( "Invalid limit %p.\n", r->LowestStartingAddress );
                    return STATUS_INVALID_PARAMETER;
                }
            }
            if (r->HighestEndingAddress)
            {
                *limit_high = (ULONG_PTR)r->HighestEndingAddress;
                if (*limit_high > limit ||
                    *limit_high <= *limit_low ||
                    ((*limit_high + 1) & (page_mask - 1)))
                {
                    WARN( "Invalid limit %p.\n", r->HighestEndingAddress );
                    return STATUS_INVALID_PARAMETER;
                }
            }
            break;
        }

        case MemExtendedParameterAttributeFlags:
            *attributes = parameters[i].ULong;
            break;

        case MemExtendedParameterImageMachine:
            *machine = parameters[i].ULong;
            break;

        case MemExtendedParameterNumaNode:
        case MemExtendedParameterPartitionHandle:
        case MemExtendedParameterUserPhysicalHandle:
            FIXME( "Parameter type %d is not supported.\n", parameters[i].Type );
            break;

        default:
            WARN( "Invalid parameter type %u\n", parameters[i].Type );
            return STATUS_INVALID_PARAMETER;
        }
    }
    return STATUS_SUCCESS;
}


/***********************************************************************
 *             NtAllocateVirtualMemoryEx   (NTDLL.@)
 *             ZwAllocateVirtualMemoryEx   (NTDLL.@)
 */
/***********************************************************************
 *           ios_reserve_fex_arena   (ml756)
 *
 * Reserve FEX's host arena as a PLACEHOLDER, before any PE module loads.
 *
 * FEX used to pick its own band: probe a 16KB address, reserve 256MB, RELEASE
 * it, then declare the surrounding 4-8GB its own and hope later allocations
 * still won it. On the jailbroken research VM that fails two ways, and both
 * were observed. Sometimes no window exists at selection time -- one launch had
 * EVERY 4GB window from 32-63GB refuse even 16KB. Other times a window is found
 * and Wine then fills it: a selected 32-36GB band ended up holding 131 guest
 * images (PhysX, APEX, steam_api64, even libarm64ecfex), **70 of which were
 * already there before FEX chose it**, leaving an 11MB largest gap by the time
 * a 16MB FEX allocation failed. Probing a free hole says nothing about owning
 * the window.
 *
 * So Wine takes the arena first, and the RESERVATION IS THE CAPACITY PROBE --
 * no probe-and-release. Because the placeholder is a real Wine view, guest DLL
 * placement is excluded from it as a CONSEQUENCE rather than by a separate
 * mechanism. FEX later replaces placeholder slices instead of selecting a band.
 *
 * Sizes: hardware's dedicated high band is 16GB; the constrained regime wants
 * 8GB (4GB is demonstrably too tight -- FEX needs ~3.5GB of spans and code for
 * ~74 threads), with 4GB accepted only as an explicitly-logged limited arena.
 *
 * ⚠️ Runs ONCE per Mach task. Pseudo-processes share one address space, so the
 * arena must be reserved and published process-wide -- they must not each pick
 * one. The usual "ntdll-unix globals break pseudo-processes" rule is INVERTED
 * here: sharing is the intent.
 *
 * On failure it publishes nothing and returns quietly, leaving FEX's own
 * selector to behave exactly as before -- a failed reservation must never break
 * a configuration that works today.
 */
void ios_reserve_fex_arena(void)
{
    static int done;
    /* Several windows, largest first.
     *
     * The research VM's usable VA windows MOVE between launches, so a single
     * candidate is a coin flip: roughly half the launches ended with NO ARENA,
     * and every one of those died in FEX before its own logging init. A 4GB
     * reservation has been observed to work, so smaller is worth trying before
     * giving up -- the failure mode that matters is reserving NOTHING.
     * The VM's ceiling is 63GiB, so nothing above that can ever succeed. */
    static const struct { ULONG_PTR lo, hi; SIZE_T size; const char *what; } plan[] = {
        { 0x7c00000000ull, 0x7fffffffffull, 0x400000000ull, "hardware high band 16GB"  },
        { 0x0800000000ull, 0x0fffffffffull, 0x200000000ull, "constrained 8GB"          },
        { 0x0400000000ull, 0x07ffffffffull, 0x200000000ull, "8GB @16-32G"              },
        { 0x0200000000ull, 0x03ffffffffull, 0x200000000ull, "8GB @8-16G"               },
        { 0x0800000000ull, 0x0bffffffffull, 0x100000000ull, "4GB @32-48G"              },
        { 0x0c00000000ull, 0x0fbfffffffull, 0x100000000ull, "4GB @48-63G"              },
        { 0x0400000000ull, 0x07ffffffffull, 0x100000000ull, "4GB @16-32G"              },
        { 0x0200000000ull, 0x03ffffffffull, 0x100000000ull, "4GB @8-16G"               },
        { 0x0200000000ull, 0x0fbfffffffull, 0x080000000ull, "2GB anywhere low"         },
    };
    unsigned i;

    if (done) return;
    done = 1;

    /* ml757: OPT-IN. This reservation is only half the design.
     *
     * FEX still runs ios_fex_band_select() and picks its own band, and on
     * hardware its ONLY candidate is [0x7c00000000,0x8000000000) -- exactly
     * what the 16GB reservation above takes. Reserving it therefore starves
     * FEX of the arena it was about to choose: no SELECTED line, no
     * FEXMem_ThreadState, dead before the first window. Shipping this
     * on-by-default regressed a working phone.
     *
     * The reservation is CORRECT and proven -- on the research VM it held 8GB
     * and kept all 123 guest images out of it, where the previous run had 131
     * inside FEX's band. It simply cannot be enabled until FEX consumes the
     * published range instead of selecting one. Until then: opt in with
     * Documents/madeira-arena.txt = 1, which is how the VM keeps testing it
     * while hardware stays on the proven path. */
    {
        /* ml786: the placeholder path is UNAVAILABLE, not merely off by default.
         *
         * Wine reserves a band; the emulator still runs its own selector and
         * picks a different one. Holding 8GB therefore pushes it into whatever
         * is left, and when that band is exhausted its 16MB requests fail, a
         * thread-creation path dereferences the NULL, the recursive fault
         * exhausts that thread's stack, and the thread dies OWNING
         * loader_section -- so the next module load blocks forever and the
         * process wedges with no error anywhere.
         *
         * An earlier change widened the search from three candidates to nine so
         * it would stop failing. That made an unfinished feature succeed more
         * often, which is the wrong direction: while the emulator selects
         * independently, a FAILED reservation is the safe outcome. The opt-in
         * returns only once it consumes WINE_IOS_FEX_ARENA_BASE/SIZE. */
        const char *opt = getenv( "MADEIRA_FEX_ARENA" );
        if (1 || !opt || opt[0] != '1')
        {
            dprintf( 2, "[fex-arena] ml757 disabled (MADEIRA_FEX_ARENA != 1) -- FEX selects its "
                        "own band, as before. Enable only once FEX consumes the published range.\n" );
            return;
        }
    }

    for (i = 0; i < ARRAY_SIZE(plan); i++)
    {
        MEM_ADDRESS_REQUIREMENTS req;
        MEM_EXTENDED_PARAMETER param;
        NTSTATUS status;
        void *base = NULL;
        SIZE_T size = plan[i].size;

        memset( &req, 0, sizeof(req) );
        memset( &param, 0, sizeof(param) );
        req.LowestStartingAddress = (void *)plan[i].lo;
        req.HighestEndingAddress  = (void *)plan[i].hi;
        req.Alignment             = 0x10000;
        param.Type    = MemExtendedParameterAddressRequirements;
        param.Pointer = &req;

        status = NtAllocateVirtualMemoryEx( NtCurrentProcess(), &base, &size,
                                            MEM_RESERVE | MEM_RESERVE_PLACEHOLDER,
                                            PAGE_NOACCESS, &param, 1 );
        if (status)
        {
            dprintf( 2, "[fex-arena] ml756 %s: reserve FAILED status=%08x\n",
                     plan[i].what, (unsigned)status );
            continue;
        }

        {
            char b[64];
            snprintf( b, sizeof(b), "%llx", (unsigned long long)(ULONG_PTR)base );
            setenv( "WINE_IOS_FEX_ARENA_BASE", b, 1 );
            snprintf( b, sizeof(b), "%llx", (unsigned long long)size );
            setenv( "WINE_IOS_FEX_ARENA_SIZE", b, 1 );
        }
        dprintf( 2, "[fex-arena] ml756 RESERVED %s base=%p size=0x%llx -- placeholder held for "
                    "process lifetime; guest images are excluded from it\n",
                 plan[i].what, base, (unsigned long long)size );
        if (size < 0x200000000ull)
            dprintf( 2, "[fex-arena] ml774 WARNING: only 0x%llx bytes. Sufficient for small "
                        "guests; heavy titles are expected to exhaust it.\n",
                     (unsigned long long)size );
        return;
    }

    /* Every candidate failed. On the VM this reliably means the launch is dead:
     * FEX picks its own band and dies before its first log line. Say so in the
     * terms the operator needs -- relaunch, do not read anything into it. */
    dprintf( 2, "[fex-arena] ml774 NO ARENA RESERVED after %u candidates -- FEX will select "
                "its own band. On the research VM this launch is EXPECTED TO DIE before "
                "FEX initialises; relaunch rather than diagnosing it.\n",
             (unsigned)ARRAY_SIZE(plan) );
}

NTSTATUS WINAPI NtAllocateVirtualMemoryEx( HANDLE process, PVOID *ret, SIZE_T *size_ptr, ULONG type,
                                           ULONG protect, MEM_EXTENDED_PARAMETER *parameters,
                                           ULONG count )
{
    static const ULONG type_mask = MEM_COMMIT | MEM_RESERVE | MEM_TOP_DOWN | MEM_WRITE_WATCH
                                   | MEM_RESET | MEM_RESERVE_PLACEHOLDER | MEM_REPLACE_PLACEHOLDER;
    ULONG_PTR limit_low = 0;
    ULONG_PTR limit_high = 0;
    ULONG_PTR align = 0;
    ULONG attributes = 0;
    USHORT machine = 0;
    unsigned int status;
#ifdef WINE_IOS
    /* ml284: does ANYTHING allocate/commit executable memory, and where?
     *
     * There is already an exec-allocation probe here using ERR(), but the `virtual` debug
     * channel is filtered by MADEIRA_QUIET -- err:virtual: appears ZERO times in the logs,
     * including the uncapped first-30 lines it should always emit. So its silence carries
     * no information, and I must not read "no exec allocations happen" from it. (That is
     * the same mistake as the [unexec] probe, whose filters made me wrongly retract the
     * V8-code-space theory.) Working probes on this side all use raw dprintf(2) --
     * [iat-sync], [jit-pool], [steer], [x86-ptr] -- so use that.
     *
     * Covers BOTH allocate entry points: [exec-req] hooks only NtProtectVirtualMemory, but
     * VirtualAlloc(MEM_COMMIT, PAGE_EXECUTE_READWRITE) grants exec through
     * NtAllocateVirtualMemory, and VirtualAlloc2/placeholders through the Ex variant --
     * which V8 commonly uses for its code cage. Unfiltered by address, capped only by
     * count, so silence here really does mean "never requested". */
    /* ml288: narrowed. The first cut logged EVERY exec allocation and fired 52 times in
     * ml287, each a dprintf(2) syscall inside NtAllocateVirtualMemory. CEF's own depth then
     * dropped from 8 verbose lines (pref_proxy_config_tracker, 3 runs running) to 4
     * (VariationsSetupComplete, 2 runs running) exactly when that probe shipped. Two runs is
     * not proof against variance, but a probe that may perturb what it measures has to go on
     * a diet -- and its finding is already banked: exec allocations DO happen, the two 16MB
     * PAGE_EXECUTE_READWRITE ones get no [jit-pool] anon RWX carve, and there is no
     * EXHAUSTED. Only the large ones carry information, so log those. */
    /* ml290: re-widened to ALL sizes (cap 20).
     *
     * [guest-caller] named the caller of the recurring fault: chrome_elf.dll (+0x6c4a2 on
     * two different threads, plus +0xd7d6e and +0x10d4c0). chrome_elf is Chromium's early
     * loader, and its job is installing INTERCEPTION THUNKS -- it patches ntdll entry points
     * to jump into thunk memory it allocates itself. If that memory is not executable, the
     * first call through a hooked function lands on a non-executable page: our fault
     * exactly, at a stable small offset, and unrelated to proxying (ruled out in ml290 --
     * the fault still fired 23x with --no-proxy-server active).
     *
     * The >=1MB narrowing I applied in ml288 hides precisely the evidence needed, because
     * interception allocations are ONE PAGE each -- e.g. the three consecutive
     * req_addr=0x73d172{c,d,e}000 size=0x1000 protect=0x40 requests seen earlier, at
     * explicit addresses in the ntdll band. Cap 20 keeps the syscall cost far below the 52
     * of the first cut while restoring the small-allocation signal, so each request can be
     * matched against the [jit-pool] anon RWX carves that follow. */
    if (protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))
    {
        static int execalloc_n;
        if (execalloc_n < 20)
        {
            execalloc_n++;
            dprintf( 2, "[exec-alloc] %s #%d req_addr=%p size=0x%llx type=0x%x protect=0x%x\n",
                     "NtAllocateVirtualMemoryEx", execalloc_n, ret ? *ret : NULL,
                     (unsigned long long)(size_ptr ? *size_ptr : 0), type, protect );
        }
    }
#endif

    TRACE( "%p %p %08lx %x %08x %p %u\n",
          process, *ret, *size_ptr, type, protect, parameters, count );

    status = get_extended_params( parameters, count, &limit_low, &limit_high,
                                  &align, &attributes, &machine );
    if (status) return status;

#ifdef WINE_IOS
    {
        static int alloc_ex_dbg = 0;
        if (alloc_ex_dbg++ < 30)
            ERR("NtAllocateVirtualMemoryEx: size=0x%lx type=0x%x prot=0x%x attrs=0x%x machine=0x%x param_count=%u\n",
                (unsigned long)*size_ptr, type, protect, attributes, machine, count);
    }
#endif

    if (type & ~type_mask) return STATUS_INVALID_PARAMETER;
    if (*ret && (align || limit_low || limit_high)) return STATUS_INVALID_PARAMETER;
    if (!*size_ptr) return STATUS_INVALID_PARAMETER;

#ifdef WINE_IOS
    /* iOS-Madeira: For FEX-style EC_CODE RWX allocations, allocate from the
     * JIT pool RX range directly. This avoids the cross-region RIP-relative
     * addressing problem: when emit_VA == execute_VA (both are the JIT pool
     * RX alias), ADRP/ADR/B/BL offsets calculated at emit time work correctly
     * at execution time. iOS won't grant exec on arbitrary user_VA, but the
     * JIT pool RX alias (mapped via mach_make_memory_entry_64+vm_map) is
     * genuinely R+X. Writes via STR fault emulation route through the RW
     * alias at the same offset within the pool.
     *
     * Triggered by: NtAllocateVirtualMemoryEx with attrs containing
     * MEM_EXTENDED_PARAMETER_EC_CODE (0x40) and prot=PAGE_EXECUTE_READWRITE,
     * caller-supplied address NULL (kernel-pick). */
    if (process == NtCurrentProcess() &&
        (attributes & 0x40 /* MEM_EXTENDED_PARAMETER_EC_CODE_FLAG */) &&
        protect == PAGE_EXECUTE_READWRITE &&
        *ret == NULL &&
        ios_jit_rx_base_global && ios_jit_rw_base_global &&
        ios_jit_pool_size_global)
    {
        size_t alloc_size = (*size_ptr + 0x3FFF) & ~0x3FFFUL;
        /* ml459 (#75): cap a single EC code buffer at 16MB. FEX asks for 32MB
         * once its buffers get hot, but an old generation stays pinned by any
         * thread still referencing it (see [pool-tail] PIN) — and a 32MB
         * generation pinned while 10% full wastes 29MB of a pool the head is
         * fighting us for (ml458: tail 214MB, head 682MB, died 1MB short).
         * Refusing the oversized ask is SAFE and already-exercised: FEX's
         * CodeBuffer ctor halves down the ladder on failure, and this run's own
         * log shows "exec alloc degraded 0x2000000 -> 0x400000" followed by
         * normal execution. Smaller generations waste less per pin; the
         * [pool-tail] census says whether pinning or churn dominates. */
        /* iOS-Madeira ml480 (#84): the flat 16MB refusal above made EVERY hot
         * thread rotate its code buffer constantly. ml479's run: 79 tail
         * events, 267k real compiles, and a compile-miss rate PINNED at ~19-20%
         * for the whole run (a warmed-up workload should approach 0). Each
         * rotation discards that thread's compiled code, so the SteamUI frame
         * thread spends its frames recompiling — Steam itself reported "frame
         * stalled for: 32818 ms", which is why its accept() loop only drains
         * the listen backlog every 2-3 minutes and CEF's ~12s websocket
         * handshake ALWAYS times out (the login window can never come up).
         *
         * Budget-aware cap instead of a flat one: grant 32MB while the tail is
         * under the watermark (measured peak tail_resv was 112MB of the 256MB
         * tail; head peaked 682MB of its 896MB budget), and fall back to the
         * proven 16MB refusal once the tail is loaded. Hot threads that rotate
         * early get big buffers; late/idle threads still get real ones, so the
         * ml436 exhaustion (10 refusals, 123 degraded threads) can't return. */
        {
            enum { TAIL_BIG = 0x2000000, TAIL_SMALL = 0x1000000,
                   TAIL_BIG_WATERMARK = 160u * 1024 * 1024 };
            size_t cap = (ios_jit_tail_reserved < TAIL_BIG_WATERMARK) ? TAIL_BIG : TAIL_SMALL;

            if (alloc_size > cap) {
                static int cap_log_n;
                if (cap_log_n < 16) {
                    cap_log_n++;
                    dprintf(2, "[jit-pool] tail CAP: refusing 0x%lx (cap 0x%lx, tail_resv=0x%lx) so FEX halves down rev=ml480\n",
                            (unsigned long)alloc_size, (unsigned long)cap,
                            (unsigned long)ios_jit_tail_reserved);
                }
                return STATUS_NO_MEMORY;
            }
            if (alloc_size > TAIL_SMALL) {
                static int big_log_n;
                if (big_log_n < 16) {
                    big_log_n++;
                    dprintf(2, "[jit-pool] tail BIG: granting 0x%lx (tail_resv=0x%lx) rev=ml480\n",
                            (unsigned long)alloc_size, (unsigned long)ios_jit_tail_reserved);
                }
            }
        }
        /* ml438 (#74): serve from the free-list first — see ios_tail_carves. */
        {
            unsigned i, best = ~0u;
            pthread_mutex_lock( &ios_tail_carve_lock );
            for (i = 0; i < ios_tail_carve_n; i++)
                if (ios_tail_carves[i].free && ios_tail_carves[i].size >= alloc_size &&
                    (best == ~0u || ios_tail_carves[i].size < ios_tail_carves[best].size))
                    best = i;
            if (best != ~0u)
            {
                void *jit_rx = (char *)ios_jit_rx_base_global + ios_tail_carves[best].off;
                void *jit_rw = (char *)ios_jit_rw_base_global + ios_tail_carves[best].off;
                size_t got = ios_tail_carves[best].size;
                ios_tail_carves[best].free = 0;
                pthread_mutex_unlock( &ios_tail_carve_lock );
                {
                    volatile uint32_t *rw_words = (volatile uint32_t *)jit_rw;
                    size_t nwords = got / sizeof(uint32_t);
                    for (size_t i2 = 0; i2 < nwords; i2++) rw_words[i2] = 0xd503201fu;  /* NOP-prefill, same as fresh carves */
                }
                *ret = jit_rx;
                *size_ptr = got;
                dprintf(2, "[jit-pool] tail REUSE rx=%p size=0x%lx (asked 0x%lx) free_left=%u rev=ml438\n",
                        jit_rx, (unsigned long)got, (unsigned long)alloc_size, ios_tail_carve_n);
                return STATUS_SUCCESS;
            }
            pthread_mutex_unlock( &ios_tail_carve_lock );
        }
        /* Reserve from the END of the JIT pool to avoid colliding with
         * mprotect_exec's PE-image copies which take from the start.
         * ios_jit_tail_reserved is the shared file-scope counter so the
         * head allocators can refuse to grow into tail-carved buffers. */
        size_t reserve_offset = __sync_fetch_and_add(&ios_jit_tail_reserved, alloc_size);
        size_t pool_tail_off = ios_jit_pool_size_global - reserve_offset - alloc_size;
        if (reserve_offset + alloc_size > ios_jit_pool_size_global / 2 ||
            pool_tail_off < jit_pool_offset)
        {
            /* iOS-Madeira ml421 (ml420 death): the old "fall through to normal
             * allocation" is ALWAYS fatal for FEX — the normal path hands back
             * guest-band memory whose exec-enable silently fails (ml363), and
             * ClearCache then wild-writes through the unusable buffer
             * (ml361/ml420: Arm64JITCore::ClearCache+0x5c, dest = 2x the
             * guest-band base). Fail the allocation HONESTLY instead: FEX's
             * CodeBuffer ctor (rev=ml364) sees NULL, halves the request down
             * to 1MB (small carves can still fit pool gaps), and if nothing
             * fits forces the diagnosable 0xdead fault. Also roll back the
             * tail reservation — the old path leaked it on every refusal. */
            __sync_fetch_and_sub(&ios_jit_tail_reserved, alloc_size);
            ERR("NtAllocateVirtualMemoryEx iOS: JIT-pool tail exhausted for FEX EC_CODE %zu bytes\n",
                (size_t)*size_ptr);
            /* ml459 (#75): dump the carve table on the FIRST refusal — the
             * question the ml458 log could not answer is whether the 214MB
             * tail is LIVE (generations pinned by threads) or merely churned
             * and never returned. free=0 rows are the pinned set; cross-check
             * against [pool-tail] PIN lines to name their owners. */
            {
                static int census_done;
                if (!census_done)
                {
                    unsigned ci; size_t live = 0, freed = 0;
                    census_done = 1;
                    pthread_mutex_lock( &ios_tail_carve_lock );
                    for (ci = 0; ci < ios_tail_carve_n; ci++)
                    {
                        dprintf(2, "[pool-tail] carve[%u] off=0x%lx size=0x%lx %s rev=ml459\n",
                                ci, (unsigned long)ios_tail_carves[ci].off,
                                (unsigned long)ios_tail_carves[ci].size,
                                ios_tail_carves[ci].free ? "FREE" : "LIVE");
                        if (ios_tail_carves[ci].free) freed += ios_tail_carves[ci].size;
                        else live += ios_tail_carves[ci].size;
                    }
                    pthread_mutex_unlock( &ios_tail_carve_lock );
                    dprintf(2, "[pool-tail] TOTALS carves=%u live=0x%lx (%lu MB) free=0x%lx (%lu MB) rev=ml459\n",
                            ios_tail_carve_n, (unsigned long)live, (unsigned long)(live >> 20),
                            (unsigned long)freed, (unsigned long)(freed >> 20));
                }
            }
            dprintf(2, "[jit-pool] TAIL REFUSED (FEX EC_CODE): want=0x%lx tail_resv=0x%lx head_used=0x%lx/0x%lx — REFUSING honestly rev=ml421 (was: fall to normal alloc = guest-band non-exec buffer = ClearCache wild write)\n",
                    (unsigned long)alloc_size, (unsigned long)reserve_offset,
                    (unsigned long)jit_pool_offset, (unsigned long)ios_jit_pool_size_global);
            return STATUS_NO_MEMORY;
        }
        else
        {
            void *jit_rx = (char *)ios_jit_rx_base_global + pool_tail_off;
            void *jit_rw = (char *)ios_jit_rw_base_global + pool_tail_off;
            *ret = jit_rx;
            *size_ptr = alloc_size;
            /* iOS-Madeira: pre-fill the buffer with NOPs (0xd503201f) via the RW
             * alias. FEX's emitter writes instructions one-at-a-time via
             * memcpy(WritePtr, &Word, 4); on iOS the underlying STR fault is
             * caught by our Mach handler. If the handler ever silently misses
             * a write encoding, the slot retains its prior content — which on
             * a freshly mapped JIT-pool tail is uninitialized memory that may
             * decode as INVALID instructions, causing ILL when execution falls
             * through. NOP-prefilling guarantees fall-through safety:
             * any failed-write slot decodes as a NOP, not garbage.
             *
             * This obsoletes the dispatcher SpillStaticRegs runtime patch in
             * xtajit64.dll (which only patched two known sites with hardcoded
             * encodings). Now the dispatcher emit lands either correctly or
             * as a NOP — either way the CPU doesn't ILL, and SpillStaticRegs
             * just spills fewer regs than expected at worst. */
            {
                volatile uint32_t *rw_words = (volatile uint32_t *)jit_rw;
                size_t nwords = alloc_size / sizeof(uint32_t);
                for (size_t i = 0; i < nwords; i++) rw_words[i] = 0xd503201fu;  /* NOP */
            }

            /* iOS-Madeira: do NOT call set_arm64ec_range here. FEX's CodeBuffer
             * holds compiled-from-x86 host ARM64 blocks, not ARM64EC PE code.
             * Marking it as EC causes the dispatcher's loop-top EC bitmap
             * check (which tests the GUEST RIP) to falsely route into ExitFunctionEC
             * and BR x9 directly into the (uninitialized) CodeBuffer when guest
             * RIP coincidentally lands here, producing UDF #0 faults.
             * Entry into the CodeBuffer is via FEX's own dispatcher BR, not via
             * arm64x_check_call, so EC marking is unneeded. */
            ERR("NtAllocateVirtualMemoryEx iOS: redirected EC_CODE %zu bytes to JIT pool tail rx=%p rw=%p NOP-prefilled\n",
                alloc_size, jit_rx, jit_rw);
            /* ml438 (#74): record the carve so a later free can recycle it. */
            pthread_mutex_lock( &ios_tail_carve_lock );
            if (ios_tail_carve_n < IOS_TAIL_CARVE_MAX)
            {
                ios_tail_carves[ios_tail_carve_n].off = pool_tail_off;
                ios_tail_carves[ios_tail_carve_n].size = alloc_size;
                ios_tail_carves[ios_tail_carve_n].free = 0;
                ios_tail_carve_n++;
            }
            pthread_mutex_unlock( &ios_tail_carve_lock );
            dprintf(2, "[jit-pool] tail EC_CODE rx=%p size=0x%lx tail_resv=0x%lx head_used=0x%lx/0x%lx\n",
                    jit_rx, (unsigned long)alloc_size,
                    (unsigned long)(reserve_offset + alloc_size),
                    (unsigned long)jit_pool_offset, (unsigned long)ios_jit_pool_size_global);
            return STATUS_SUCCESS;
        }
    }
#endif

    if (process != NtCurrentProcess())
    {
        union apc_call call;
        union apc_result result;

        memset( &call, 0, sizeof(call) );

        call.virtual_alloc_ex.type         = APC_VIRTUAL_ALLOC_EX;
        call.virtual_alloc_ex.addr         = wine_server_client_ptr( *ret );
        call.virtual_alloc_ex.size         = *size_ptr;
        call.virtual_alloc_ex.limit_low    = limit_low;
        call.virtual_alloc_ex.limit_high   = limit_high;
        call.virtual_alloc_ex.align        = align;
        call.virtual_alloc_ex.op_type      = type;
        call.virtual_alloc_ex.prot         = protect;
        call.virtual_alloc_ex.attributes   = attributes;
        status = server_queue_process_apc( process, &call, &result );
        if (status != STATUS_SUCCESS) return status;

        if (result.virtual_alloc_ex.status == STATUS_SUCCESS)
        {
            *ret      = wine_server_get_ptr( result.virtual_alloc_ex.addr );
            *size_ptr = result.virtual_alloc_ex.size;
        }
        return result.virtual_alloc_ex.status;
    }

#ifdef WINE_IOS
    {
        NTSTATUS st;
        /* ml92: the middle-zone steering that used to live here targeted
         * [256G,480G), which is 192GB GPU carveout — it could never succeed.
         * There is no middle zone at all (see NtAllocateVirtualMemory), so go
         * straight to the default search, and census jumbo calls the same way
         * so PartitionAlloc's demand is counted no matter which entry point
         * it uses. */
        void  *jumbo_hint = *ret;
        size_t jumbo_size = *size_ptr;
        int    is_jumbo   = (jumbo_size >= 0x40000000 && (type & MEM_RESERVE));
        /* ml125 [bigres]: settle the furniture attribution WITHOUT an FEX build.
         * The [window] probe found ~30 runs of ~511MB and I inferred FEXCore's
         * per-thread LookupCache (TotalCacheSize = VirtualMemSize/4096*8 +
         * CODE_SIZE + MAX_L1_SIZE) — but I have now mis-attributed this twice
         * from size coincidences alone, so measure it instead: every reserve
         * between 256MB and the 1GB jumbo threshold, with a running total and
         * count. If ~31 of these land at exactly 0x1ff10000 the attribution is
         * proven and the page-pointer array is the thing to shrink; if they are
         * a mix of sizes it is something else entirely and the FEX redesign
         * would have been wasted work. */
        if ((type & MEM_COMMIT) && ios_bigres_cnt && *ret)
            ios_bigres_commit( *ret, *size_ptr );
        if (jumbo_size >= 0x10000000 && jumbo_size < 0x40000000 && (type & MEM_RESERVE))
        {
            static unsigned bigres_n;
            static unsigned long long bigres_tot;
            bigres_n++;
            bigres_tot += jumbo_size;
            ios_bigres_reserved_total += jumbo_size;
            /* ml126: ATTRIBUTE BY PROCESS, not by size. All 23 were exactly
             * 512MB, which rules out FEXCore's LookupCache (a computed sum) and
             * the CallRetStack (16MB), and no FEX VirtualAlloc site asks for
             * 512MB either -- so this may well be the GUEST (V8's x64
             * kMaximalCodeRangeSize is 512MB, which would fit CEF). ERR gives
             * the wine tid prefix for free, and the PEB identifies WHICH
             * pseudo-process: correlate against the [init-peb]/NtCreateUserProcess
             * map. If these are steamwebhelper's PEB it is CEF/V8 and the fix is
             * a command-line flag, not an FEX redesign -- a completely different
             * and far cheaper answer than the one I was about to build. */
            /* ml127: use dprintf, NOT ERR. The `virtual` debug channel's ERR is
             * suppressed in this build (err:virtual: appears 0 times in a log
             * with 526 err:seh: lines), so routing this through ERR to get the
             * tid prefix silenced the probe completely — 23 lines in ml126, 0 in
             * ml127. Same reason alloc_arm64ec_map's ERR has never appeared in
             * any log. Read the tid out of the TEB instead. */
            /* ml129: FEX's own hook ENCODES which structure this is, and I was
             * simply not printing it. AllocatorHooks.h does
             *   VirtualAlloc(Base, Size, Commit ? MEM_RESERVE|MEM_COMMIT : MEM_RESERVE,
             *                Execute ? PAGE_EXECUTE_READWRITE : PAGE_READWRITE)
             * so protect==0x40 (PAGE_EXECUTE_READWRITE) means an Execute
             * allocation -- a JIT code buffer (CPUBackend) or the dispatcher --
             * while 0x04 (PAGE_READWRITE) means data, and the MEM_COMMIT bit
             * separates the commit-upfront LookupCache path from pure reserves.
             * That splits the remaining candidates without an FEX build, and
             * without wiring a unixlib that iOS deliberately no-ops. */
            dprintf( 2, "[bigres] tid=%04x #%u size=0x%lx (%lu MB) type=0x%x prot=0x%x hint=%p peb=%p total=%llu MB\n",
                     NtCurrentTeb() ? (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread : 0,
                     bigres_n, (unsigned long)jumbo_size,
                     (unsigned long)(jumbo_size >> 20), (unsigned)type, (unsigned)protect,
                     jumbo_hint, NtCurrentTeb() ? NtCurrentTeb()->Peb : NULL, bigres_tot >> 20 );
            /* ml128: NAME THE CALLER. Elimination has run out — it is exactly
             * 2 x 512MB per guest thread of steam.exe (peb=0x11da68000, 12 tids),
             * and it is NOT the LookupCache (VirtualMemSize = 1ULL<<33 makes
             * TotalCacheSize ~96MB, below this probe's 256MB floor), NOT the
             * CallRetStack (16MB), NOT the emulator stack (256KB), and no FEX
             * VirtualAlloc site asks for 512MB. So stop reasoning about sizes and
             * read the return addresses off the stack, the same way [exit-stk]
             * does. Module base + offset is enough — names come from the
             * [jit-pool] image lines in the same log. */
            /* ml166: this scan HAS been running every run and I had simply never read its
             * output. Symbolising it settles the owner and REFUTES two earlier claims:
             *   - the 512MB reserves ARE FEX's own: mod 0x73f09d0000 = libarm64ecfex.dll,
             *     +0x125834/+0x125860 -> VirtualAlloc, +0x1e7e08 -> $iexit_thunk$cdecl$i8$i8.
             *     So "type=0x2000 proves the caller is NOT FEX" (the AllocatorHooks
             *     MEM_TOP_DOWN note) does NOT hold here, and the ml128 claim "no FEX
             *     VirtualAlloc site asks for 512MB" is wrong.
             *   - but those are FEX's own ALLOCATOR frames, the nearest ones. The subsystem
             *     that asked is deeper, and the old limits hid it: 6 hits, bigres_n <= 4.
             *
             * Scan deeper, report more, and cover the LATE reservations (#18+) which are the
             * ones that exhaust the window: 27 x 512MB filled 13.8GB of 15.1GB while
             * committing 1%, maxgap fell to 28MB, a 512MB reserve FAILED, and the NULL
             * return was stored through (`stp x8,x20,[x0]` with x0=0). Which FEX subsystem
             * this is decides the fix: smaller per-thread arena vs relocation above the
             * ceiling vs soft reservation. */
            if (bigres_n <= 4 || (bigres_n >= 18 && bigres_n <= 30))
            {
                uint64_t *sp = (uint64_t *)__builtin_frame_address(0);
                int w, hits = 0;
                for (w = 0; w < 1024 && hits < 20; w++)
                {
                    uint64_t mod = 0, va = ios_jit_reverse_translate( sp[w], &mod );
                    if (va && mod && va != sp[w])
                    {
                        dprintf( 2, "[bigres]   caller#%u sp+0x%x: 0x%llx = mod 0x%llx +0x%llx\n",
                                 bigres_n, w * 8, (unsigned long long)sp[w],
                                 (unsigned long long)mod, (unsigned long long)(va - mod) );
                        hits++;
                    }
                }

                /* ml167 GUEST-STACK ATTRIBUTION — the one route not yet tried.
                 *
                 * The native scan above is NOT proof of ownership: it surfaces any
                 * code-like value on the stack, including DEAD frames from earlier FEX
                 * activity on that thread, and I over-trusted its libarm64ecfex hits last
                 * round. The flags actually EXCLUDE every FEX site I can enumerate —
                 * type=0x2000 has no MEM_TOP_DOWN, and FEXCore::Allocator::VirtualAlloc
                 * unconditionally ORs it (AllocatorHooks.h: Flags = (Commit?MEM_COMMIT:0)
                 * | MEM_RESERVE | MEM_TOP_DOWN); CallRetStack is MEM_TOP_DOWN+PAGE_NOACCESS;
                 * the iOS LookupCache path passes Commit=true (FEX_IOS_HOST=1 is global).
                 *
                 * All four earlier attribution attempts were RIP-based and returned NATIVE
                 * addresses inside VirtualAlloc itself. So walk the GUEST stack instead:
                 * the saved x64 CONTEXT is at CPUArea+0x50, Rsp at +0x98 (Rip at +0xF8, as
                 * the ios_guest_ctx_rip comment records). x86-64 return addresses there
                 * point at PE module VAs, which are STABLE all run (unlike pool copies the
                 * freelist recycles), so they resolve offline against [jit-pool] image.
                 *
                 * What this decides: 2 x 512MB per guest thread at 1% commit, with
                 * [bigres] total only ever GROWING, is either a size knob or a per-thread
                 * reservation never released on thread exit — both cheap and safe. Only if
                 * it is neither do we need overcommit/aliasing, which is unsound in general
                 * (an app is entitled to grow into a range it reserved). */
                {
                    TEB *t = NtCurrentTeb();
                    void *ca = t ? *(void **)((char *)t + 0x1788) : NULL;

                    if ((uintptr_t)ca >= 0x10000)
                    {
                        uint64_t grsp = *(uint64_t *)((char *)ca + 0x50 + 0x98);
                        uint64_t grip = *(uint64_t *)((char *)ca + 0x50 + 0xF8);

                        dprintf( 2, "[bigres]   guest#%u rsp=0x%llx rip=0x%llx\n",
                                 bigres_n, (unsigned long long)grsp,
                                 (unsigned long long)grip );
                        /* Only read the guest stack if Wine owns the range. A raw deref
                         * here would fault mid-syscall (this is not a signal handler, so
                         * it would surface as a real AV and cost the run). find_view is
                         * the header-free check already available in this TU. */
                        if (grsp >= 0x10000 && !(grsp & 7)
                            && find_view( (const void *)(uintptr_t)grsp, 0x1000 ))
                        {
                            const uint64_t *gs = (const uint64_t *)(uintptr_t)grsp;
                            int g, gh = 0;
                            for (g = 0; g < 256 && gh < 12; g++)
                            {
                                uint64_t v = gs[g];
                                if (v < 0x7300000000ULL || v >= 0x7400000000ULL) continue;
                                dprintf( 2, "[bigres]   guest#%u rsp+0x%x: 0x%llx\n",
                                         bigres_n, g * 8, (unsigned long long)v );
                                gh++;
                            }
                        }
                    }
                }
            }
        }

        st = allocate_virtual_memory( ret, size_ptr, type, protect,
                                      limit_low, limit_high, align, attributes );

        if (is_jumbo) ios_jumbo_census( jumbo_hint, jumbo_size, st ? NULL : *ret, (unsigned)st );
        if (!st && *size_ptr >= 0x10000000 && *size_ptr < 0x40000000 && (type & MEM_RESERVE))
            ios_bigres_note( *ret, *size_ptr );
        if (!st) ios_span_census( *ret, *size_ptr, 0 );   /* ml435 (#73) */

        /* iOS-Madeira ml310 (task #54): SYSCALL-BOUNDARY census of arena-band allocations.
         *
         * ml310's [va-arena] probe inside allocate_virtual_memory's reserve branch logged 26 lines,
         * ALL of them size=0x20000000 type=0x2000 (jemalloc's MEM_RESERVE-only arenas) and NOT ONE
         * of the 0x3000 FEXMem_ThreadState allocations -- even though three of those landed on
         * duplicate addresses that run (0x7d00001000, 0x7d80001000, 0x7ea0001000). So the small
         * MEM_COMMIT|MEM_RESERVE|MEM_TOP_DOWN allocations that actually collide are served by some
         * other path and that probe can never see them.
         *
         * Log here instead, at the syscall exit, where *ret is final no matter which internal route
         * produced it (normal allocate_virtual_memory, the steer retry ladder, the soft-pool commit
         * path, or the jumbo hint fallback). Placed in BOTH NtAllocateVirtualMemory and
         * NtAllocateVirtualMemoryEx because FEX's ARM64EC AllocatorHooks calls ::VirtualAlloc2, so
         * the Ex variant is the one FEX actually uses. Reports size/type/tid plus whether the
         * address falls inside a live ios_steer[] reservation. */
        /* ml311: gate on MEM_RESERVE. The ml310 cut logged every arena-band result and the 60-line
         * cap was consumed entirely by tid 006c's MEM_COMMIT-only (type=0x1000) 64KB commits
         * marching through its own jemalloc reservation -- all legitimate, and none of them the
         * FEXMem_ThreadState allocation being hunted, which carries
         * MEM_COMMIT|MEM_RESERVE|MEM_TOP_DOWN (0x103000). Reserving allocations are the only ones
         * that can CHOOSE an address, so they are the only ones that can collide. */
        if (!st && *ret && (uint64_t)(uintptr_t)*ret >= 0x7C00000000ULL)
        {
            static int nc;
            uint64_t nb = (uint64_t)(uintptr_t)*ret;
            unsigned i, hit = (unsigned)-1;
            for (i = 0; i < ios_steer_n; i++)
            {
                if (!ios_steer[i].base) continue;
                if (nb < ios_steer[i].base || nb >= ios_steer[i].base + ios_steer[i].size) continue;
                hit = i; break;
            }
            /* ml312: mark the arena in use for EVERY allocation that lands in it, reserving or
             * committing alike -- a commit is just as much a claim on the memory as a reserve, and
             * the reclaim must not recycle either. Note this runs unconditionally, outside the
             * logging cap, so the flag can never depend on how much has been printed. */
            /* ml331: COUNT interior allocations instead of latching a flag. ml330 made the
             * flag permanent (an arena with any interior allocation was never released), which
             * fixed the corruption but leaked VA: ml330 reached 69 arenas / 35GB reserved in the
             * 64GB window CEF also needs, and FEXCore CreateThread's unchecked aligned_alloc
             * returned NULL and stored through it (#43 again). Refcount instead: bump here,
             * drop on interior MEM_RELEASE, and reclaim only at zero. */
            /* ml331b: bump ONLY on MEM_RESERVE. The ml312 flag deliberately counted commits
             * too, which was right for a latch but wrong for a refcount: a region that is
             * reserved then committed would bump twice and be released once, so the count
             * could never reach zero and the arena would leak exactly as in ml330. The
             * reservation is the claim on the range; MEM_RELEASE is its only counterpart. */
            /* ml332: REVERTED to latch semantics. The ml331 refcount gated bumps on
             * MEM_RESERVE, but jemalloc's interior activity is MEM_COMMIT inside the one
             * big reservation -- so every arena counted as empty, 8 arenas (4GB) were
             * released with live contents, and the GuestToHostMap corruption came straight
             * back (ml331 crash == ml329 crash, minutes after 'released 4096MB'). The
             * ml312 comment said it: a commit is as much a claim as a reserve. Deeper:
             * FEX's jemalloc heap is SHARED across threads, so 'owning thread died' was
             * never a valid release condition at all. VA pressure is solved by smaller
             * arenas (FEX side), not by releasing shared memory. */
            if (hit != (unsigned)-1 && nb != ios_steer[hit].base) ios_steer[hit].inuse = 1;

            if ((type & MEM_RESERVE) && nc++ < 80)
            {
                dprintf( 2, "[va-exit] rev=ml312 %p+0x%lx type=0x%x tid=%04x steer=%s%u freed=%u steer_n=%u\n",
                         *ret, (unsigned long)*size_ptr, (unsigned)type,
                         NtCurrentTeb() ? (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread : 0,
                         hit == (unsigned)-1 ? "NONE#" : "INSIDE#",
                         hit == (unsigned)-1 ? ios_steer_n : hit,
                         hit == (unsigned)-1 ? 0 : ios_steer[hit].freed, ios_steer_n );
            }
        }
        return st;
    }
#else
    return allocate_virtual_memory( ret, size_ptr, type, protect,
                                    limit_low, limit_high, align, attributes );
#endif
}


/***********************************************************************
 *             NtFreeVirtualMemory   (NTDLL.@)
 *             ZwFreeVirtualMemory   (NTDLL.@)
 */
NTSTATUS WINAPI NtFreeVirtualMemory( HANDLE process, PVOID *addr_ptr, SIZE_T *size_ptr, ULONG type )
{
    struct file_view *view;
    char *base;
    sigset_t sigset;
    unsigned int status = STATUS_SUCCESS;
    LPVOID addr = *addr_ptr;
    SIZE_T size = *size_ptr;

    TRACE("%p %p %08lx %x\n", process, addr, size, type );

    /* ml171 LEAK PROBE: the 512MB reserves grow without bound (27 -> 55 across runs,
     * 28GB) and only ~1%% is ever committed. If the owner never RELEASES them the fix is
     * reclamation, not more address space; if it does release and our accounting still
     * grows, the leak is ours. Log every large free so the next run answers it. */
    /* ml172 FIX: the first cut gated logging on size >= 256MB, but Windows REQUIRES
     * size == 0 for MEM_RELEASE (VirtualFree(addr, 0, MEM_RELEASE)) — so the very calls
     * this probe exists to catch could never be logged, and its "0 frees" result was
     * meaningless. Log any MEM_RELEASE of an address in the steered/pool band, plus any
     * large explicit free, and resolve the real extent from the view. */
    if ((type & MEM_RELEASE) || size >= 0x10000000)
    {
        static unsigned freebig_n;
        uintptr_t fa = (uintptr_t)addr;

        if (freebig_n < 32 && (size >= 0x10000000 || fa >= 0x7000000000ULL))
        {
            struct file_view *fv = find_view( addr, 0 );
            freebig_n++;
            dprintf(2, "[bigfree] #%u addr=%p size=0x%lx type=0x%x view=%p viewsize=0x%lx\n",
                    freebig_n, addr, (unsigned long)size, (unsigned)type,
                    fv ? fv->base : NULL, fv ? (unsigned long)fv->size : 0ul);
        }
    }

    if (process != NtCurrentProcess())
    {
        union apc_call call;
        union apc_result result;

        memset( &call, 0, sizeof(call) );

        call.virtual_free.type      = APC_VIRTUAL_FREE;
        call.virtual_free.addr      = wine_server_client_ptr( addr );
        call.virtual_free.size      = size;
        call.virtual_free.op_type   = type;
        status = server_queue_process_apc( process, &call, &result );
        if (status != STATUS_SUCCESS) return status;

        if (result.virtual_free.status == STATUS_SUCCESS)
        {
            *addr_ptr = wine_server_get_ptr( result.virtual_free.addr );
            *size_ptr = result.virtual_free.size;
        }
        return result.virtual_free.status;
    }

    /* Fix the parameters */

    if (size) size = ROUND_SIZE( addr, size, page_mask );
    base = ROUND_ADDR( addr, page_mask );

    /* ml433 (#72): keep the jumbo ledger honest — see ios_bigres_release. */
    if (type & MEM_RELEASE) ios_bigres_release( base );
    /* ml435 (#73): band span lifecycle census — resolve MEM_RELEASE size=0 from the view. */
    if ((type & MEM_RELEASE) && (uintptr_t)base >= 0x7c00000000ULL)
    {
        struct file_view *sfv = find_view( base, 0 );
        ios_span_census( base, sfv ? sfv->size : size, 1 );
    }
    /* ml438 (#74): a MEM_RELEASE of a live tail EC-buffer carve has no wine
     * view — before this rev it error'd (FEXCore ignored it) and the tail
     * space leaked forever. Mark the carve free for reuse and succeed. */
    if ((type & MEM_RELEASE) && ios_jit_rx_base_global && ios_jit_pool_size_global &&
        (char *)base >= (char *)ios_jit_rx_base_global &&
        (char *)base <  (char *)ios_jit_rx_base_global + ios_jit_pool_size_global)
    {
        unsigned i;
        size_t off = (size_t)((char *)base - (char *)ios_jit_rx_base_global);
        size_t carve_size = 0;
        pthread_mutex_lock( &ios_tail_carve_lock );
        for (i = 0; i < ios_tail_carve_n; i++)
        {
            if (ios_tail_carves[i].off != off || ios_tail_carves[i].free) continue;
            /* ml557: do NOT recycle a carve a thread is still executing in. */
            if (ios_tail_carve_occupied( base, ios_tail_carves[i].size ))
            {
                static unsigned long occ_n;
                if (++occ_n <= 16 || (occ_n % 256) == 0)
                    dprintf(2, "[jit-pool] tail FREE REFUSED rx=%p size=0x%lx — a thread's "
                               "PC is inside it (occupied=%lu) rev=ml557\n",
                            base, (unsigned long)ios_tail_carves[i].size, occ_n);
                carve_size = 0;
                break;
            }
            ios_tail_carves[i].free = 1;
            carve_size = ios_tail_carves[i].size;
            break;
        }
        pthread_mutex_unlock( &ios_tail_carve_lock );
        if (carve_size)
        {
            dprintf(2, "[jit-pool] tail FREE rx=%p size=0x%lx -> free-list rev=ml438\n",
                    (void *)base, (unsigned long)carve_size);
            *addr_ptr = base;
            *size_ptr = carve_size;
            return STATUS_SUCCESS;
        }
        /* pool address but not a live tail carve — fall through unchanged */
    }

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );

    /* avoid freeing the DOS area when a broken app passes a NULL pointer */
    if (!base)
    {
#ifndef _WIN64
        /* address 1 is magic to mean release reserved space */
        if (addr == (void *)1 && !size && type == MEM_RELEASE) virtual_release_address_space();
        else
#endif
        status = STATUS_INVALID_PARAMETER;
    }
    else if (!(view = find_view( base, 0 ))) status = STATUS_MEMORY_NOT_ALLOCATED;
    else if (!is_view_valloc( view )) status = STATUS_INVALID_PARAMETER;
    else if (!size && base != view->base) status = STATUS_FREE_VM_NOT_AT_BASE;
    else if ((char *)view->base + view->size - base < size && !(type & MEM_COALESCE_PLACEHOLDERS))
             status = STATUS_UNABLE_TO_FREE_VM;
    else switch (type)
    {
    case MEM_DECOMMIT:
        status = decommit_pages( view, base, size );
        break;
    case MEM_RELEASE:
        if (!size) size = view->size;
        status = free_pages( view, base, size );
        break;
    case MEM_RELEASE | MEM_PRESERVE_PLACEHOLDER:
        status = free_pages_preserve_placeholder( view, base, size );
        break;
    case MEM_RELEASE | MEM_COALESCE_PLACEHOLDERS:
        status = coalesce_placeholders( view, base, size );
        break;
    case MEM_COALESCE_PLACEHOLDERS:
        status = STATUS_INVALID_PARAMETER_4;
        break;
    default:
        status = STATUS_INVALID_PARAMETER;
        break;
    }

    if (status == STATUS_SUCCESS)
    {
        *addr_ptr = base;
        *size_ptr = size;
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return status;
}


/***********************************************************************
 *             NtProtectVirtualMemory   (NTDLL.@)
 *             ZwProtectVirtualMemory   (NTDLL.@)
 */
NTSTATUS WINAPI NtProtectVirtualMemory( HANDLE process, PVOID *addr_ptr, SIZE_T *size_ptr,
                                        ULONG new_prot, ULONG *old_prot )
{
    struct file_view *view;
    sigset_t sigset;
    unsigned int status = STATUS_SUCCESS;
    char *base;
    BYTE vprot;
    SIZE_T size = *size_ptr;
    LPVOID addr = *addr_ptr;
    DWORD old;

#ifdef WINE_IOS
    LPVOID ios_jit_orig_addr = NULL;  /* JIT pool RX addr if caller passed one */
    {
        LPVOID orig_addr = addr;
        LPVOID reversed = (LPVOID)ios_jit_reverse_translate_addr(addr);
        if (reversed != orig_addr)
        {
            /* Caller passed a JIT-pool RX address. Translate to parent for the
             * Wine-side protection update, but remember the original so we can
             * also flip the JIT-pool RX page's posix prot — otherwise a write
             * via the JIT-pool RX address (e.g. FEX's PatchCallChecker writing
             * to its own __ImageBase + RVA) faults because the RX side stays
             * read-only even after the parent becomes RW. */
            ios_jit_orig_addr = orig_addr;
            addr = reversed;
        }
        ERR("NtProtectVirtualMemory(orig=%p reversed=%p sz=0x%lx prot=0x%x)\n",
            orig_addr, addr, (unsigned long)*size_ptr, new_prot);
    }
#endif

    TRACE("%p %p %08lx %08x\n", process, addr, size, new_prot );

#ifdef WINE_IOS
    /* iOS: relax the NULL-old_prot rejection. Wine PE-side ntdll's arm64ec
     * notify-memory-protect path passes NULL when the caller doesn't care
     * about the old prot. Standard Windows would reject this with AV, but on
     * iOS that breaks our IAT-sync (which needs the protect change to apply)
     * — the JIT-pool slots stay zero, exit thunks BLR to garbage and SEGV.
     * Substitute a local sink so the protection change + IAT sync still run. */
    DWORD ios_old_prot_sink;
    if (!old_prot) old_prot = &ios_old_prot_sink;
#else
    if (!old_prot)
        return STATUS_ACCESS_VIOLATION;
#endif

    if (process != NtCurrentProcess())
    {
        union apc_call call;
        union apc_result result;

        memset( &call, 0, sizeof(call) );

        call.virtual_protect.type = APC_VIRTUAL_PROTECT;
        call.virtual_protect.addr = wine_server_client_ptr( addr );
        call.virtual_protect.size = size;
        call.virtual_protect.prot = new_prot;
        status = server_queue_process_apc( process, &call, &result );
        if (status != STATUS_SUCCESS) return status;

        if (result.virtual_protect.status == STATUS_SUCCESS)
        {
            *addr_ptr = wine_server_get_ptr( result.virtual_protect.addr );
            *size_ptr = result.virtual_protect.size;
            *old_prot = result.virtual_protect.prot;
        }
        else *old_prot = PAGE_NOACCESS;
        return result.virtual_protect.status;
    }

    /* Fix the parameters */

    size = ROUND_SIZE( addr, size, page_mask );
    base = ROUND_ADDR( addr, page_mask );

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );

    if ((view = find_view( base, size )))
    {
        /* Make sure all the pages are committed */
        if (get_committed_size( view, base, size, &vprot, VPROT_COMMITTED ) >= size && (vprot & VPROT_COMMITTED))
        {
            old = get_win32_prot( vprot, view->protect );
            status = set_protection( view, base, size, new_prot );
        }
        else status = STATUS_NOT_COMMITTED;
    }
    else status = STATUS_INVALID_PARAMETER;

    if (!status) VIRTUAL_DEBUG_DUMP_VIEW( view );

    server_leave_uninterrupted_section( &virtual_mutex, &sigset );

    if (status == STATUS_SUCCESS)
    {
        *addr_ptr = base;
        *size_ptr = size;
        *old_prot = old;

#ifdef WINE_IOS
        /* (Previously: also called mprotect_exec on the JIT-pool RX side
         * here, but that uses vm_protect+VM_PROT_COPY which makes the page
         * PRIVATE — breaking the dual-map sharing with the RW alias. We rely
         * on the Mach SEGV handler's STR emulation instead: stores to JIT-RX
         * are detected and redirected to the RW alias. Writes via RW alias
         * remain visible to subsequent reads via the RX alias because the
         * dual-mapping is preserved.) */

        /* After import resolution: PE loader makes IAT writable, fills it, then
         * restores protection. When write access is removed from a JIT-mapped region,
         * sync the data from original PE to JIT pool and translate function pointers.
         * Also fires on PAGE_READWRITE → PAGE_WRITECOPY (the pattern Wine's
         * arm64ec_update_hybrid_metadata uses to restore section protection
         * after writing dispatcher slots — without this the JIT-pool copy of
         * the metadata table never sees the SET_FUNC writes). */
        /* Always sync parent → JIT for any NtProtectVirtualMemory call on a
         * JIT-mapped region. The old/new comparison can't reliably detect
         * writes-then-restore patterns because get_win32_prot() reports the
         * section's allocation prot (PAGE_WRITECOPY for .data) — not the
         * actual per-page state — so RW→WRITECOPY transitions read as 0x8→0x8.
         * Over-syncing is OK: parent is always the source of truth. */
        ERR("iOS NtProtect-sync-check: base=%p sz=0x%lx old=0x%x new=0x%x\n",
            base, (unsigned long)size, old, new_prot);
        /* iOS-Madeira 2026-05-13: bail out if the new protection makes the
         * source region unreadable. The sync below memcpys from `base` into
         * the JIT pool. When the caller is revoking read access (e.g.
         * PAGE_NOACCESS=1, or any prot without READ bit), the source page
         * becomes inaccessible and memcpy faults inside Apple's iOS shared
         * cache (BUS at the SIMD LDP). Each fault is caught by SEH and the
         * memcpy creeps forward 0x20 bytes per fault — 300s of progress for
         * one stuck region. Thumper hit this on FMOD's PAGE_NOACCESS guard
         * pages. No data to copy when the parent is unreadable anyway. */
        {
            unsigned read_bits = PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                                 PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                                 PAGE_EXECUTE_WRITECOPY;
            if (!(new_prot & read_bits))
            {
                ERR("iOS NtProtect-sync: SKIP (new_prot=0x%x has no READ bit)\n", new_prot);
                return status;
            }
        }
        if (1)
        {
            int idx;
            ERR("iOS NtProtect-sync: triggered, scanning %d JIT mappings\n", ios_jit_mapping_count);
            for (idx = 0; idx < ios_jit_mapping_count; idx++)
            {
                uintptr_t pe_start = (uintptr_t)ios_jit_mappings[idx].pe_base;
                uintptr_t pe_end = pe_start + ios_jit_mappings[idx].size;
                uintptr_t rgn_start = (uintptr_t)base;
                uintptr_t rgn_end = rgn_start + size;

                if (rgn_start >= pe_start && rgn_end <= pe_end)
                {
                    /* iOS-Madeira ml632 A/B: DO NOT IAT-SYNC MEMORY OWNED BY AN ANON JIT ALIAS.
                     *
                     * Containment against the PE image is not sufficient ownership: the
                     * anon-RWX classifier above is all-or-nothing, so pages can be inside a
                     * PE image AND inside a live anonymous JIT alias. Writing the pool copy
                     * of the image over them clobbers whatever the guest JIT put there.
                     * The alias table is the stronger claim — it means a JIT actually took
                     * this memory — so it wins. */
                    uintptr_t ov_b = 0, ov_e = 0;
                    extern int ios_jit_anon_alias_overlaps(void *, size_t, uintptr_t *, uintptr_t *);
                    if (ios_jit_anon_alias_overlaps( base, size, &ov_b, &ov_e ))
                    {
                        static int skip_n;
                        if (skip_n < 16)
                            dprintf(2, "[mixed-map] ml632 SKIP iat-sync #%d region %p+0x%lx — owned by anon JIT alias "
                                       "[%p,%p) (image %p+0x%lx)\n",
                                    ++skip_n, base, (unsigned long)size, (void *)ov_b, (void *)ov_e,
                                    (void *)pe_start, (unsigned long)(pe_end - pe_start));
                        break;
                    }

                    /* Region is within this JIT-mapped PE image — sync to JIT pool.
                     * IMPORTANT: skip any overlap with .text (code) section to avoid
                     * overwriting JIT-relocated code with the original unix mapping copy. */
                    size_t off = rgn_start - pe_start;
                    uintptr_t pool_offset = (uintptr_t)ios_jit_mappings[idx].jit_base
                                          - (uintptr_t)ios_jit_rx_base_global;
                    char *jit_rw_dest = (char *)ios_jit_rw_base_global + pool_offset + off;

                    /* Determine .text section bounds within THIS region */
                    size_t text_off = ios_jit_mappings[idx].text_offset;
                    size_t text_sz  = ios_jit_mappings[idx].text_size;

                    /* Absolute range of .text within the PE image address space */
                    uintptr_t text_abs_start = pe_start + text_off;
                    uintptr_t text_abs_end   = text_abs_start + text_sz;

                    if (text_sz == 0 || text_abs_end <= rgn_start || text_abs_start >= rgn_end)
                    {
                        /* No overlap with .text — safe to copy whole region */
                        memcpy(jit_rw_dest, base, size);
                        ERR("iOS JIT IAT sync: full copy %p+0x%lx → JIT (no text overlap)\n",
                            base, (unsigned long)size);
                    }
                    else
                    {
                        /* Copy only the parts OUTSIDE .text */
                        size_t overlap_start = text_abs_start > rgn_start ? text_abs_start - rgn_start : 0;
                        size_t overlap_end   = text_abs_end   < rgn_end   ? text_abs_end   - rgn_start : size;

                        if (overlap_start > 0)
                            memcpy(jit_rw_dest, (char *)base, overlap_start);
                        if (overlap_end < size)
                            memcpy(jit_rw_dest + overlap_end, (char *)base + overlap_end, size - overlap_end);

                        ERR("iOS JIT IAT sync: partial copy %p+0x%lx → JIT (skipping text [0x%lx-0x%lx])\n",
                            base, (unsigned long)size,
                            (unsigned long)overlap_start, (unsigned long)overlap_end);
                    }

                    /* Re-apply DIR64 relocations within the synced region.
                     * The memcpy overwrote DIR64-relocated values with fresh
                     * unrelocated data from the unix mapping. Walk the PE reloc
                     * table and re-apply entries that fall within this region. */
                    if (ios_jit_mappings[idx].reloc_rva && ios_jit_mappings[idx].reloc_size
                        && ios_jit_mappings[idx].reloc_delta)
                    {
                        uintptr_t pe_start_addr = (uintptr_t)ios_jit_mappings[idx].pe_base;
                        uintptr_t pool_base = (uintptr_t)ios_jit_mappings[idx].jit_base
                                             - (uintptr_t)ios_jit_rx_base_global;
                        char *rw_image = (char *)ios_jit_rw_base_global + pool_base;
                        unsigned int r_rva = ios_jit_mappings[idx].reloc_rva;
                        unsigned int r_sz  = ios_jit_mappings[idx].reloc_size;
                        uint64_t img_base  = ios_jit_mappings[idx].pe_image_base;
                        intptr_t r_delta   = ios_jit_mappings[idx].reloc_delta;
                        size_t img_size    = ios_jit_mappings[idx].size;
                        /* Region bounds as offsets within the PE image */
                        size_t rgn_off_start = off;
                        size_t rgn_off_end   = off + size;
                        char *block = rw_image + r_rva;
                        char *block_end = block + r_sz;
                        int dir64_count = 0;

                        while (block < block_end)
                        {
                            unsigned int block_rva  = *(unsigned int *)block;
                            unsigned int block_size = *(unsigned int *)(block + 4);
                            int j2, num_entries;
                            unsigned short *entries;

                            if (!block_size || block_size < 8) break;
                            num_entries = (block_size - 8) / 2;
                            entries = (unsigned short *)(block + 8);

                            for (j2 = 0; j2 < num_entries; j2++)
                            {
                                int type = entries[j2] >> 12;
                                int eoff = entries[j2] & 0xFFF;
                                unsigned int fixup_rva = block_rva + eoff;

                                if (type == 0) continue;
                                if (type != 10) continue; /* IMAGE_REL_BASED_DIR64 */

                                /* Only fix entries within the synced region */
                                if (fixup_rva < rgn_off_start || fixup_rva + 8 > rgn_off_end)
                                    continue;

                                {
                                    uint64_t *fixup = (uint64_t *)(rw_image + fixup_rva);
                                    uint64_t val = *fixup;
                                    if (val >= img_base && val < img_base + img_size)
                                    {
                                        *fixup += r_delta;
                                        dir64_count++;
                                    }
                                }
                            }
                            block += block_size;
                        }
                        if (dir64_count)
                            ERR("iOS JIT IAT sync: re-applied %d DIR64 fixups in region %p+0x%lx\n",
                                dir64_count, base, (unsigned long)size);
                    }

                    /* Translate pointers: scan for 64-bit values that point to
                     * original PE image addresses and translate to JIT pool.
                     * Translates ALL pointers within a PE mapping (not just .text),
                     * since IAT sync copies relocated data from the PE-side view
                     * which has unix_base-relative pointers. These must become
                     * jit_base-relative to match the DIR64-fixuped JIT copy. */
                    {
                        /* OWNER-AWARE (2026-07-07): ntdll's image VA range
                         * matches the session copy AND every same-arch child
                         * copy — the old first-match scan always picked the
                         * session's entry, so child modules' ntdll imports
                         * pointed at the SESSION pool copy. services.exe's
                         * rpcrt4 IAT got session-copy Tp* → threadpool
                         * workers born executing the wrong ntdll → exit
                         * crash in LdrShutdownThread holding the session
                         * loader lock → rpcss never answered explorer's
                         * CoRegisterClassObject. The sync runs on the owning
                         * process's thread, so current-peb is the owner. */
                        void *sync_owner = ios_jit_current_peb();
                        uint64_t *p = (uint64_t *)jit_rw_dest;
                        uint64_t *end_p = (uint64_t *)(jit_rw_dest + (size & ~7));
                        int fixup_count = 0;
                        /* task #34 [ec-poison] PROBE ONLY — changes nothing.
                         *
                         * This loop rewrites EVERY 8-byte word whose value looks
                         * like a PE image address (24608 of them in
                         * steamwebhelper.exe alone, ml100). That is correct for
                         * an ARM64EC function pointer, which must reach the pool
                         * copy — and WRONG for an x86 one, which must stay a
                         * guest PE address so FEX can translate it. A poisoned
                         * x86 pointer sends the guest into the pool, which is
                         * exactly the [rip-leak] signature (ml95, ml100: guest
                         * RIP holding a pool address that reverse-translates to
                         * a real module+rva).
                         *
                         * peb->EcCodeBitMap already distinguishes the two. Count
                         * how many translations target NON-EC (x86) code before
                         * changing any behaviour — the sync fixed real bugs (the
                         * rpcss milestone depends on it), so it does not get
                         * narrowed on a hunch. */
                        /* ml102 FIX: do NOT rewrite pointers into x86-64 code.
                         * The probe measured 74985 of 133709 translations
                         * (56.08%) landing on x86 .text — each one a pool
                         * address planted where the guest expects a PE address,
                         * which is the [rip-leak] death (ml95/ml100: guest RIP
                         * holding a pool address that reverse-translates to a
                         * real module+rva). Data pointers and ARM64EC code
                         * pointers still translate, because for those the pool
                         * copy IS the live one — this only removes the case that
                         * is always wrong. Ratios varied per region (2/2,
                         * 6006/18029, 161/2240), which is what distinguishes
                         * this from the earlier EcCodeBitMap probe that reported
                         * a meaningless 100%. */
                        int x86skip = 0;
                        uint64_t x86_first = 0;
                        while (p < end_p)
                        {
                            uint64_t val = *p;
                            if (val)
                            {
                                void *nv = ios_jit_translate_addr_for_owner(
                                        (void *)(uintptr_t)val, sync_owner);
                                if (nv != (void *)(uintptr_t)val)
                                {
                                    if (ios_va_is_x86_code( val ))
                                    {
                                        if (!x86skip) x86_first = val;
                                        x86skip++;
                                    }
                                    else
                                    {
                                        *p = (uint64_t)(uintptr_t)nv;
                                        fixup_count++;
                                    }
                                }
                            }
                            p++;
                        }
                        if (x86skip)
                            dprintf(2, "[x86-ptr] region %p+0x%lx: KEPT %d guest x86-CODE pointers (first 0x%llx), translated %d others\n",
                                    base, (unsigned long)size, x86skip,
                                    (unsigned long long)x86_first, fixup_count);
                        /* dprintf, not ERR — the perf WINEDEBUG default mutes
                         * err+virtual and this is the owner-routing evidence. */
                        if (fixup_count)
                            dprintf(2, "[iat-sync] region %p+0x%lx: translated %d pointers (owner=%p)\n",
                                    base, (unsigned long)size, fixup_count, sync_owner);
                    }
                    break;
                }
            }
        }
#endif
    }
    else *old_prot = PAGE_NOACCESS;
    return status;
}


static struct file_view *get_memory_region_size( char *base, char **region_start, char **region_end,
                                                 BOOL *fake_reserved )
{
    struct wine_rb_entry *ptr;
    struct file_view *view;

    *fake_reserved = FALSE;
    *region_start = NULL;
    *region_end = working_set_limit;

    ptr = views_tree.root;
    while (ptr)
    {
        view = WINE_RB_ENTRY_VALUE( ptr, struct file_view, entry );
        if ((char *)view->base > base)
        {
            *region_end = view->base;
            ptr = ptr->left;
        }
        else if ((char *)view->base + view->size <= base)
        {
            *region_start = (char *)view->base + view->size;
            ptr = ptr->right;
        }
        else
        {
            *region_start = view->base;
            *region_end = (char *)view->base + view->size;
            return view;
        }
    }
#ifdef __i386__
    {
        struct reserved_area *area;

        /* on i386, pretend that space outside of a reserved area is allocated,
         * so that the app doesn't believe it's fully available */
        LIST_FOR_EACH_ENTRY( area, &reserved_areas, struct reserved_area, entry )
        {
            char *area_start = area->base;
            char *area_end = area_start + area->size;

            if (area_end <= base)
            {
                if (*region_start < area_end) *region_start = area_end;
                continue;
            }
            if (area_start <= base || area_start <= (char *)address_space_start)
            {
                if (area_end < *region_end) *region_end = area_end;
                return NULL;
            }
            /* report the remaining part of the 64K after the view as free */
            if ((UINT_PTR)*region_start & granularity_mask)
            {
                char *next = (char *)ROUND_ADDR( *region_start, granularity_mask ) + granularity_mask + 1;

                if (base < next)
                {
                    *region_end = min( next, *region_end );
                    return NULL;
                }
                else *region_start = base;
            }
            /* pretend it's allocated */
            if (area_start < *region_end) *region_end = area_start;
            break;
        }
        *fake_reserved = TRUE;
    }
#endif
    return NULL;
}


static unsigned int fill_basic_memory_info( const void *addr, MEMORY_BASIC_INFORMATION *info )
{
    char *base, *alloc_base, *alloc_end;
    struct file_view *view;
    BOOL fake_reserved;
    sigset_t sigset;

    base = ROUND_ADDR( addr, page_mask );

    if (is_beyond_limit( base, 1, working_set_limit )) return STATUS_INVALID_PARAMETER;

    /* Find the view containing the address */

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    view = get_memory_region_size( base, &alloc_base, &alloc_end, &fake_reserved );

    /* Fill the info structure */

    info->BaseAddress = base;
    info->RegionSize  = alloc_end - base;

    if (!view)
    {
        if (fake_reserved)
        {
            info->State             = MEM_RESERVE;
            info->Protect           = PAGE_NOACCESS;
            info->AllocationBase    = alloc_base;
            info->AllocationProtect = PAGE_NOACCESS;
            info->Type              = MEM_PRIVATE;
        }
        else
        {
            info->State             = MEM_FREE;
            info->Protect           = PAGE_NOACCESS;
            info->AllocationBase    = 0;
            info->AllocationProtect = 0;
            info->Type              = 0;
        }
    }
    else
    {
        BYTE vprot;

        info->AllocationBase = alloc_base;
        info->RegionSize = get_committed_size( view, base, ~(size_t)0, &vprot, ~VPROT_WRITEWATCH );
        info->State = (vprot & VPROT_COMMITTED) ? MEM_COMMIT : MEM_RESERVE;
        info->Protect = (vprot & VPROT_COMMITTED) ? get_win32_prot( vprot, view->protect ) : 0;
        info->AllocationProtect = get_win32_prot( view->protect, view->protect );
        if (view->protect & SEC_IMAGE) info->Type = MEM_IMAGE;
        else if (view->protect & (SEC_FILE | SEC_RESERVE | SEC_COMMIT)) info->Type = MEM_MAPPED;
        else info->Type = MEM_PRIVATE;
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );

    return STATUS_SUCCESS;
}

/* get basic information about a memory block */
static unsigned int get_basic_memory_info( HANDLE process, LPCVOID addr,
                                           MEMORY_BASIC_INFORMATION *info,
                                           SIZE_T len, SIZE_T *res_len )
{
    unsigned int status;

    if (len < sizeof(*info))
        return STATUS_INFO_LENGTH_MISMATCH;

    if (process != NtCurrentProcess())
    {
        union apc_call call;
        union apc_result result;

        memset( &call, 0, sizeof(call) );

        call.virtual_query.type = APC_VIRTUAL_QUERY;
        call.virtual_query.addr = wine_server_client_ptr( addr );
        status = server_queue_process_apc( process, &call, &result );
        if (status != STATUS_SUCCESS) return status;

        if (result.virtual_query.status == STATUS_SUCCESS)
        {
            info->BaseAddress       = wine_server_get_ptr( result.virtual_query.base );
            info->AllocationBase    = wine_server_get_ptr( result.virtual_query.alloc_base );
            info->RegionSize        = result.virtual_query.size;
            info->Protect           = result.virtual_query.prot;
            info->AllocationProtect = result.virtual_query.alloc_prot;
            info->State             = (DWORD)result.virtual_query.state << 12;
            info->Type              = (DWORD)result.virtual_query.alloc_type << 16;
            if (info->RegionSize != result.virtual_query.size)  /* truncated */
                return STATUS_INVALID_PARAMETER;  /* FIXME */
            if (res_len) *res_len = sizeof(*info);
        }
        return result.virtual_query.status;
    }

    if ((status = fill_basic_memory_info( addr, info ))) return status;

    if (res_len) *res_len = sizeof(*info);
    return STATUS_SUCCESS;
}

static unsigned int get_memory_region_info( HANDLE process, LPCVOID addr, MEMORY_REGION_INFORMATION *info,
                                            SIZE_T len, SIZE_T *res_len )
{
    char *base, *region_start, *region_end;
    struct file_view *view;
    BYTE vprot, vprot_mask;
    BOOL fake_reserved;
    sigset_t sigset;
    SIZE_T size;

    if (len < FIELD_OFFSET(MEMORY_REGION_INFORMATION, CommitSize))
        return STATUS_INFO_LENGTH_MISMATCH;

    if (process != NtCurrentProcess())
    {
        FIXME("Unimplemented for other processes.\n");
        return STATUS_NOT_IMPLEMENTED;
    }

    base = ROUND_ADDR( addr, page_mask );

    if (is_beyond_limit( base, 1, working_set_limit )) return STATUS_INVALID_PARAMETER;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );

    if ((view = get_memory_region_size( base, &region_start, &region_end, &fake_reserved )))
    {
        info->AllocationBase = view->base;
        info->AllocationProtect = get_win32_prot( view->protect, view->protect );
        info->RegionType = 0; /* FIXME */
        if (len >= FIELD_OFFSET(MEMORY_REGION_INFORMATION, CommitSize))
            info->RegionSize = view->size;
        if (len >= FIELD_OFFSET(MEMORY_REGION_INFORMATION, PartitionId))
        {
            base = region_start;
            info->CommitSize = 0;
            vprot_mask = VPROT_COMMITTED;
            if (!is_view_valloc( view )) vprot_mask |= PAGE_WRITECOPY;
            while (base != region_end &&
                   (size = get_committed_size( view, base, ~(size_t)0, &vprot, vprot_mask )))
            {
                if ((vprot & vprot_mask) == vprot_mask) info->CommitSize += size;
                base += size;
            }
        }
    }
    else
    {
        if (!fake_reserved)
        {
            server_leave_uninterrupted_section( &virtual_mutex, &sigset );
            return STATUS_INVALID_ADDRESS;
        }
        info->AllocationBase = region_start;
        info->AllocationProtect = PAGE_NOACCESS;
        info->RegionType = 0; /* FIXME */
        info->RegionSize = region_end - region_start;
        info->CommitSize = 0;
    }

    server_leave_uninterrupted_section( &virtual_mutex, &sigset );

    if (res_len) *res_len = sizeof(*info);
    return STATUS_SUCCESS;
}

struct working_set_info_ref
{
    char *addr;
    SIZE_T orig_index;
};

#if defined(HAVE_LIBPROCSTAT)
struct fill_working_set_info_data
{
    struct procstat *pstat;
    struct kinfo_proc *kip;
    unsigned int vmentry_count;
    struct kinfo_vmentry *vmentries;
};

static void init_fill_working_set_info_data( struct fill_working_set_info_data *d, char *end )
{
    unsigned int proc_count;

    d->kip = NULL;
    d->vmentry_count = 0;
    d->vmentries = NULL;

    if ((d->pstat = procstat_open_sysctl()))
        d->kip = procstat_getprocs( d->pstat, KERN_PROC_PID, getpid(), &proc_count );
    if (d->kip)
        d->vmentries = procstat_getvmmap( d->pstat, d->kip, &d->vmentry_count );
    if (!d->vmentries)
        WARN( "couldn't get process vmmap, errno %d\n", errno );
}

static void free_fill_working_set_info_data( struct fill_working_set_info_data *d )
{
    if (d->vmentries)
        procstat_freevmmap( d->pstat, d->vmentries );
    if (d->kip)
        procstat_freeprocs( d->pstat, d->kip );
    if (d->pstat)
        procstat_close( d->pstat );
}

static void fill_working_set_info( struct fill_working_set_info_data *d, struct file_view *view, BYTE vprot,
                                   struct working_set_info_ref *ref, SIZE_T count,
                                   MEMORY_WORKING_SET_EX_INFORMATION *info )
{
    SIZE_T i;
    int j;

    for (i = 0; i < count; ++i)
    {
        MEMORY_WORKING_SET_EX_INFORMATION *p = &info[ref[i].orig_index];
        struct kinfo_vmentry *entry = NULL;

        for (j = 0; j < d->vmentry_count; j++)
        {
            if (d->vmentries[j].kve_start <= (ULONG_PTR)p->VirtualAddress && (ULONG_PTR)p->VirtualAddress <= d->vmentries[j].kve_end)
            {
                entry = &d->vmentries[j];
                break;
            }
        }

        p->VirtualAttributes.Valid = !(vprot & VPROT_GUARD) && (vprot & 0x0f) && entry && entry->kve_type != KVME_TYPE_SWAP;
        p->VirtualAttributes.Shared = !is_view_valloc( view );
        if (p->VirtualAttributes.Shared && p->VirtualAttributes.Valid)
            p->VirtualAttributes.ShareCount = 1; /* FIXME */
        if (p->VirtualAttributes.Valid)
            p->VirtualAttributes.Win32Protection = get_win32_prot( vprot, view->protect );
    }
}
#else
static int pagemap_fd = -2;

struct fill_working_set_info_data
{
    UINT64 pm_buffer[256];
    SIZE_T buffer_start;
    ssize_t buffer_len;
    SIZE_T end_page;
};

static void init_fill_working_set_info_data( struct fill_working_set_info_data *d, char *end )
{
    d->buffer_start = 0;
    d->buffer_len = 0;
    d->end_page = (UINT_PTR)end / host_page_size;
    memset( d->pm_buffer, 0, sizeof(d->pm_buffer) );

    if (pagemap_fd != -2) return;

#ifdef O_CLOEXEC
    if ((pagemap_fd = open( "/proc/self/pagemap", O_RDONLY | O_CLOEXEC, 0 )) == -1 && errno == EINVAL)
#endif
        pagemap_fd = open( "/proc/self/pagemap", O_RDONLY, 0 );

    if (pagemap_fd == -1) WARN( "unable to open /proc/self/pagemap\n" );
    else fcntl(pagemap_fd, F_SETFD, FD_CLOEXEC);  /* in case O_CLOEXEC isn't supported */
}

static void free_fill_working_set_info_data( struct fill_working_set_info_data *d )
{
}

static void fill_working_set_info( struct fill_working_set_info_data *d, struct file_view *view, BYTE vprot,
                                   struct working_set_info_ref *ref, SIZE_T count,
                                   MEMORY_WORKING_SET_EX_INFORMATION *info )
{
    MEMORY_WORKING_SET_EX_INFORMATION *p;
    UINT64 pagemap;
    SIZE_T i, page;
    ssize_t len;

    for (i = 0; i < count; ++i)
    {
        page = (UINT_PTR)ref[i].addr / host_page_size;
        p = &info[ref[i].orig_index];

        assert(page >= d->buffer_start);
        if (page >= d->buffer_start + d->buffer_len)
        {
            d->buffer_start = page;
            len = min( sizeof(d->pm_buffer), (d->end_page - page) * sizeof(pagemap) );
            if (pagemap_fd != -1)
            {
                d->buffer_len = pread( pagemap_fd, d->pm_buffer, len, page * sizeof(pagemap) );
                if (d->buffer_len != len)
                {
                    d->buffer_len = max( d->buffer_len, 0 );
                    memset( d->pm_buffer + d->buffer_len / sizeof(pagemap), 0, len - d->buffer_len );
                }
            }
            d->buffer_len = len / sizeof(pagemap);
        }
        pagemap = d->pm_buffer[page - d->buffer_start];

        p->VirtualAttributes.Valid = !(vprot & VPROT_GUARD) && (vprot & 0x0f) && (pagemap >> 63);
        p->VirtualAttributes.Shared = !is_view_valloc( view ) && ((pagemap >> 61) & 1);
        if (p->VirtualAttributes.Shared && p->VirtualAttributes.Valid)
            p->VirtualAttributes.ShareCount = 1; /* FIXME */
        if (p->VirtualAttributes.Valid)
            p->VirtualAttributes.Win32Protection = get_win32_prot( vprot, view->protect );
    }
}
#endif

static int compare_working_set_info_ref( const void *a, const void *b )
{
    const struct working_set_info_ref *r1 = a, *r2 = b;

    if (r1->addr < r2->addr) return -1;
    return r1->addr > r2->addr;
}

static NTSTATUS get_working_set_ex( HANDLE process, LPCVOID addr,
                                    MEMORY_WORKING_SET_EX_INFORMATION *info,
                                    SIZE_T len, SIZE_T *res_len )
{
    struct working_set_info_ref ref_buffer[256], *ref = ref_buffer, *r;
    struct fill_working_set_info_data data;
    char *start, *end;
    SIZE_T i, count;
    struct file_view *view, *prev_view;
    sigset_t sigset;
    BYTE vprot;

    if (process != NtCurrentProcess())
    {
        FIXME( "(process=%p,addr=%p) Unimplemented information class: MemoryWorkingSetExInformation\n", process, addr );
        return STATUS_INVALID_INFO_CLASS;
    }

    if (len < sizeof(*info)) return STATUS_INFO_LENGTH_MISMATCH;

    count = len / sizeof(*info);

    if (count > ARRAY_SIZE(ref_buffer)) ref = malloc( count * sizeof(*ref) );
    for (i = 0; i < count; ++i)
    {
        ref[i].orig_index = i;
        ref[i].addr = ROUND_ADDR( info[i].VirtualAddress, page_mask );
        info[i].VirtualAttributes.Flags = 0;
    }
    qsort( ref, count, sizeof(*ref), compare_working_set_info_ref );
    start = ref[0].addr;
    end = ref[count - 1].addr + page_size;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    init_fill_working_set_info_data( &data, end );

    view = find_view_range( start, end - start );
    while (view && (char *)view->base > start)
    {
        prev_view = RB_ENTRY_VALUE( rb_prev( &view->entry ), struct file_view, entry );
        if (!prev_view || (char *)prev_view->base + prev_view->size <= start) break;
        view = prev_view;
    }

    r = ref;
    while (view && (char *)view->base < end)
    {
        if (start < (char *)view->base) start = view->base;
        while (r != ref + count && r->addr < start) ++r;
        while (start != (char *)view->base + view->size && r != ref + count
               && r->addr < (char *)view->base + view->size)
        {
            start += get_committed_size( view, start, end - start, &vprot, ~VPROT_WRITEWATCH );
            i = 0;
            while (r + i != ref + count && r[i].addr < start) ++i;
            if (vprot & VPROT_COMMITTED) fill_working_set_info( &data, view, vprot, r, i, info );
            r += i;
        }
        if (r == ref + count) break;
        view = RB_ENTRY_VALUE( rb_next( &view->entry ), struct file_view, entry );
    }

    free_fill_working_set_info_data( &data );
    if (ref != ref_buffer) free( ref );
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );

    if (res_len)
        *res_len = len;
    return STATUS_SUCCESS;
}

static unsigned int get_memory_section_name( HANDLE process, LPCVOID addr,
                                             MEMORY_SECTION_NAME *info, SIZE_T len, SIZE_T *ret_len )
{
    unsigned int status;

    if (!info) return STATUS_ACCESS_VIOLATION;

    SERVER_START_REQ( get_mapping_filename )
    {
        req->process = wine_server_obj_handle( process );
        req->addr = wine_server_client_ptr( addr );
        if (len > sizeof(*info) + sizeof(WCHAR))
            wine_server_set_reply( req, info + 1, len - sizeof(*info) - sizeof(WCHAR) );
        status = wine_server_call( req );
        if (!status || status == STATUS_BUFFER_OVERFLOW)
        {
            if (ret_len) *ret_len = sizeof(*info) + reply->len + sizeof(WCHAR);
            if (len < sizeof(*info)) status = STATUS_INFO_LENGTH_MISMATCH;
            if (!status)
            {
                info->SectionFileName.Buffer = (WCHAR *)(info + 1);
                info->SectionFileName.Length = reply->len;
                info->SectionFileName.MaximumLength = reply->len + sizeof(WCHAR);
                info->SectionFileName.Buffer[reply->len / sizeof(WCHAR)] = 0;
            }
        }
    }
    SERVER_END_REQ;
    return status;
}

static unsigned int get_memory_image_info( HANDLE process, LPCVOID addr, MEMORY_IMAGE_INFORMATION *info,
                                           SIZE_T len, SIZE_T *res_len )
{
    unsigned int status;

    if (len < sizeof(*info)) return STATUS_INFO_LENGTH_MISMATCH;
    memset( info, 0, sizeof(*info) );

    SERVER_START_REQ( get_image_view_info )
    {
        req->process = wine_server_obj_handle( process );
        req->addr = wine_server_client_ptr( addr );
        status = wine_server_call( req );
        if (!status && reply->base)
        {
            info->ImageBase = wine_server_get_ptr( reply->base );
            info->SizeOfImage = reply->size;
            info->ImageSigningLevel = 12;
        }
    }
    SERVER_END_REQ;

    if (status == STATUS_NOT_MAPPED_VIEW)
    {
        MEMORY_BASIC_INFORMATION basic_info;

        status = get_basic_memory_info( process, addr, &basic_info, sizeof(basic_info), NULL );
        if (status || basic_info.State == MEM_FREE) status = STATUS_INVALID_ADDRESS;
    }

    if (!status && res_len) *res_len = sizeof(*info);
    return status;
}


/***********************************************************************
 *             NtQueryVirtualMemory   (NTDLL.@)
 *             ZwQueryVirtualMemory   (NTDLL.@)
 */
NTSTATUS WINAPI NtQueryVirtualMemory( HANDLE process, LPCVOID addr,
                                      MEMORY_INFORMATION_CLASS info_class,
                                      PVOID buffer, SIZE_T len, SIZE_T *res_len )
{
    NTSTATUS status;

#ifdef WINE_IOS
    /* PE code in JIT pool computes addresses via ADRP relative to JIT PC.
     * Translate JIT addresses back to original PE addresses for VM queries. */
    addr = ios_jit_reverse_translate_addr(addr);
#endif

    TRACE("(%p, %p, info_class=%d, %p, %ld, %p)\n",
          process, addr, info_class, buffer, len, res_len);

    switch(info_class)
    {
        case MemoryBasicInformation:
            return get_basic_memory_info( process, addr, buffer, len, res_len );

        case MemoryWorkingSetExInformation:
            return get_working_set_ex( process, addr, buffer, len, res_len );

        case MemoryMappedFilenameInformation:
            return get_memory_section_name( process, addr, buffer, len, res_len );

        case MemoryRegionInformation:
            return get_memory_region_info( process, addr, buffer, len, res_len );

        case MemoryImageInformation:
            return get_memory_image_info( process, addr, buffer, len, res_len );

        case MemoryWineLoadUnixLib:
        case MemoryWineLoadUnixLibWow64:
            if (len != sizeof(unixlib_handle_t)) return STATUS_INFO_LENGTH_MISMATCH;
            if (process == GetCurrentProcess())
            {
                void *module = (void *)addr;
                const void *funcs = NULL;

                status = load_builtin_unixlib( module, info_class == MemoryWineLoadUnixLibWow64, &funcs );
                if (!status) *(unixlib_handle_t *)buffer = (UINT_PTR)funcs;
                return status;
            }
            return STATUS_INVALID_HANDLE;

        case MemoryWineLoadUnixLibByName:
        case MemoryWineLoadUnixLibByNameWow64:
            if (process == GetCurrentProcess())
            {
                UINT64 res[2];
                const UNICODE_STRING *name = addr;
                NTSTATUS (*entry)(void);
                const void *funcs;
                void *handle;

                if ((status = load_unixlib_by_name( name, &handle )))
                {
#ifdef WINE_IOS
                    /* iOS-Madeira 2026-05-13: no .so files on iOS for audio
                     * drivers; provide static unix tables for wineios.drv
                     * (silent audio backend). Match by name; success path
                     * returns a magic non-NULL handle so subsequent
                     * MemoryWineUnloadUnixLib doesn't crash. */
                    char ascii[64] = {0};
                    unsigned int nlen = name->Length / sizeof(WCHAR);
                    if (nlen > 0 && nlen < sizeof(ascii))
                    {
                        for (unsigned int i = 0; i < nlen; i++)
                            ascii[i] = (char)(name->Buffer[i] & 0x7f);
                        ascii[nlen] = 0;
                        /* lowercase for substr matching */
                        for (char *p = ascii; *p; p++)
                            if (*p >= 'A' && *p <= 'Z') *p += 'a' - 'A';
                        if (strstr(ascii, "wineios") || strstr(ascii, "winecoreaudio") ||
                            strstr(ascii, "winealsa") || strstr(ascii, "winepulse") ||
                            strstr(ascii, "wineoss"))
                        {
                            ERR("iOS: MemoryWineLoadUnixLibByName %s -> audio_null_ios stub table\n", ascii);
                            res[0] = (UINT64)(UINT_PTR)1; /* magic non-NULL handle */
                            res[1] = (UINT64)(UINT_PTR)audio_null_ios_unix_call_funcs;
                            memcpy( buffer, res, min( len, sizeof(res) ));
                            return STATUS_SUCCESS;
                        }
                    }
#endif
                    return status;
                }
                res[0] = (UINT_PTR)handle;
                if (!(status = get_unixlib_funcs( handle, info_class == MemoryWineLoadUnixLibByNameWow64,
                                                  &funcs, &entry )))
                {
                    res[1] = (UINT_PTR)funcs;
                    if (entry) status = entry();
                }
                if (status) dlclose( handle );
                else memcpy( buffer, res, min( len, sizeof(res) ));
                return status;
            }
            return STATUS_INVALID_HANDLE;

        case MemoryWineUnloadUnixLib:
            if (process == GetCurrentProcess())
            {
                const unixlib_module_t *handle = addr;

                if (!dlclose( (void *)(UINT_PTR)*handle )) return STATUS_SUCCESS;
            }
            return STATUS_INVALID_HANDLE;

        default:
            FIXME("(%p,%p,info_class=%d,%p,%ld,%p) Unknown information class\n",
                  process, addr, info_class, buffer, len, res_len);
            return STATUS_INVALID_INFO_CLASS;
    }
}


/***********************************************************************
 *             NtLockVirtualMemory   (NTDLL.@)
 *             ZwLockVirtualMemory   (NTDLL.@)
 */
NTSTATUS WINAPI NtLockVirtualMemory( HANDLE process, PVOID *addr, SIZE_T *size, ULONG unknown )
{
    unsigned int status = STATUS_SUCCESS;

    if (process != NtCurrentProcess())
    {
        union apc_call call;
        union apc_result result;

        memset( &call, 0, sizeof(call) );

        call.virtual_lock.type = APC_VIRTUAL_LOCK;
        call.virtual_lock.addr = wine_server_client_ptr( *addr );
        call.virtual_lock.size = *size;
        status = server_queue_process_apc( process, &call, &result );
        if (status != STATUS_SUCCESS) return status;

        if (result.virtual_lock.status == STATUS_SUCCESS)
        {
            *addr = wine_server_get_ptr( result.virtual_lock.addr );
            *size = result.virtual_lock.size;
        }
        return result.virtual_lock.status;
    }

    *size = ROUND_SIZE( *addr, *size, page_mask );
    *addr = ROUND_ADDR( *addr, page_mask );

    if (mlock( ROUND_ADDR( *addr, host_page_mask ), ROUND_SIZE( *addr, *size, host_page_mask ) ))
    {
        dprintf(2, "[vmem-denied] mlock failed: addr=%p size=%p errno=%d\n",
                *addr, (void *)*size, errno);
        status = STATUS_ACCESS_DENIED;
    }
    return status;
}


/***********************************************************************
 *             NtUnlockVirtualMemory   (NTDLL.@)
 *             ZwUnlockVirtualMemory   (NTDLL.@)
 */
NTSTATUS WINAPI NtUnlockVirtualMemory( HANDLE process, PVOID *addr, SIZE_T *size, ULONG unknown )
{
    unsigned int status = STATUS_SUCCESS;

    if (process != NtCurrentProcess())
    {
        union apc_call call;
        union apc_result result;

        memset( &call, 0, sizeof(call) );

        call.virtual_unlock.type = APC_VIRTUAL_UNLOCK;
        call.virtual_unlock.addr = wine_server_client_ptr( *addr );
        call.virtual_unlock.size = *size;
        status = server_queue_process_apc( process, &call, &result );
        if (status != STATUS_SUCCESS) return status;

        if (result.virtual_unlock.status == STATUS_SUCCESS)
        {
            *addr = wine_server_get_ptr( result.virtual_unlock.addr );
            *size = result.virtual_unlock.size;
        }
        return result.virtual_unlock.status;
    }

    *size = ROUND_SIZE( *addr, *size, page_mask );
    *addr = ROUND_ADDR( *addr, page_mask );

    if (munlock( ROUND_ADDR( *addr, host_page_mask ), ROUND_SIZE( *addr, *size, host_page_mask ) ))
        status = STATUS_ACCESS_DENIED;
    return status;
}


/***********************************************************************
 *             NtMapViewOfSection   (NTDLL.@)
 *             ZwMapViewOfSection   (NTDLL.@)
 */
NTSTATUS WINAPI NtMapViewOfSection( HANDLE handle, HANDLE process, PVOID *addr_ptr, ULONG_PTR zero_bits,
                                    SIZE_T commit_size, const LARGE_INTEGER *offset_ptr, SIZE_T *size_ptr,
                                    SECTION_INHERIT inherit, ULONG alloc_type, ULONG protect )
{
    unsigned int res;
    SIZE_T mask = granularity_mask;
    LARGE_INTEGER offset;

    offset.QuadPart = offset_ptr ? offset_ptr->QuadPart : 0;

    TRACE("handle=%p process=%p addr=%p off=%s size=0x%lx alloc_type=0x%x access=0x%x\n",
          handle, process, *addr_ptr, wine_dbgstr_longlong(offset.QuadPart), *size_ptr, alloc_type, protect );

    /* Check parameters */
    if (zero_bits > 21 && zero_bits < 32)
        return STATUS_INVALID_PARAMETER_4;

    /* If both addr_ptr and zero_bits are passed, they have match */
    if (zero_bits && zero_bits < 32 && ((UINT_PTR)*addr_ptr >> (32 - zero_bits)))
        return STATUS_INVALID_PARAMETER_4;
    if (zero_bits >= 32 && ((UINT_PTR)*addr_ptr & ~zero_bits))
        return STATUS_INVALID_PARAMETER_4;

    if (!is_win64 && !is_wow64())
    {
        if (zero_bits >= 32) return STATUS_INVALID_PARAMETER_4;
        if (alloc_type & AT_ROUND_TO_PAGE)
        {
            *addr_ptr = ROUND_ADDR( *addr_ptr, page_mask );
            mask = page_mask;
        }
    }
    else if (alloc_type & AT_ROUND_TO_PAGE) return STATUS_INVALID_PARAMETER_9;

    if (alloc_type & MEM_REPLACE_PLACEHOLDER) mask = page_mask;
    if (offset.u.LowPart & mask) return STATUS_MAPPED_ALIGNMENT;
    if ((UINT_PTR)*addr_ptr & mask) return STATUS_MAPPED_ALIGNMENT;
    if ((UINT_PTR)*addr_ptr & host_page_mask)
    {
        ERR( "unaligned placeholder at %p\n", *addr_ptr );
        return STATUS_MAPPED_ALIGNMENT;
    }

    if (process != NtCurrentProcess())
    {
        union apc_call call;
        union apc_result result;

        memset( &call, 0, sizeof(call) );

        call.map_view.type         = APC_MAP_VIEW;
        call.map_view.handle       = wine_server_obj_handle( handle );
        call.map_view.addr         = wine_server_client_ptr( *addr_ptr );
        call.map_view.size         = *size_ptr;
        call.map_view.offset       = offset.QuadPart;
        call.map_view.zero_bits    = zero_bits;
        call.map_view.alloc_type   = alloc_type;
        call.map_view.prot         = protect;
        res = server_queue_process_apc( process, &call, &result );
        if (res != STATUS_SUCCESS) return res;

        if (NT_SUCCESS(result.map_view.status))
        {
            *addr_ptr = wine_server_get_ptr( result.map_view.addr );
            *size_ptr = result.map_view.size;
        }
        return result.map_view.status;
    }

    return virtual_map_section( handle, addr_ptr, 0, get_zero_bits_limit( zero_bits ), commit_size,
                                offset_ptr, size_ptr, alloc_type, protect, 0 );
}

/***********************************************************************
 *             NtMapViewOfSectionEx   (NTDLL.@)
 *             ZwMapViewOfSectionEx   (NTDLL.@)
 */
NTSTATUS WINAPI NtMapViewOfSectionEx( HANDLE handle, HANDLE process, PVOID *addr_ptr,
                                      const LARGE_INTEGER *offset_ptr, SIZE_T *size_ptr,
                                      ULONG alloc_type, ULONG protect,
                                      MEM_EXTENDED_PARAMETER *parameters, ULONG count )
{
    ULONG_PTR limit_low = 0, limit_high = 0, align = 0;
    ULONG attributes = 0;
    USHORT machine = 0;
    unsigned int status;
    SIZE_T mask = granularity_mask;
    LARGE_INTEGER offset;

    offset.QuadPart = offset_ptr ? offset_ptr->QuadPart : 0;

    TRACE( "handle=%p process=%p addr=%p off=%s size=0x%lx alloc_type=0x%x access=0x%x\n",
           handle, process, *addr_ptr, wine_dbgstr_longlong(offset.QuadPart), *size_ptr, alloc_type, protect );

    status = get_extended_params( parameters, count, &limit_low, &limit_high,
                                  &align, &attributes, &machine );
    if (status) return status;

    if (align) return STATUS_INVALID_PARAMETER;
    if (*addr_ptr && (limit_low || limit_high)) return STATUS_INVALID_PARAMETER;

    if (alloc_type & AT_ROUND_TO_PAGE)
    {
        if (is_win64 || is_wow64()) return STATUS_INVALID_PARAMETER;
        *addr_ptr = ROUND_ADDR( *addr_ptr, page_mask );
        mask = page_mask;
    }

    if (alloc_type & MEM_REPLACE_PLACEHOLDER) mask = page_mask;
    if (offset.u.LowPart & mask) return STATUS_MAPPED_ALIGNMENT;
    if ((UINT_PTR)*addr_ptr & mask) return STATUS_MAPPED_ALIGNMENT;
    if ((UINT_PTR)*addr_ptr & host_page_mask)
    {
        ERR( "unaligned placeholder at %p\n", *addr_ptr );
        return STATUS_MAPPED_ALIGNMENT;
    }

    if (process != NtCurrentProcess())
    {
        union apc_call call;
        union apc_result result;

        memset( &call, 0, sizeof(call) );

        call.map_view_ex.type         = APC_MAP_VIEW_EX;
        call.map_view_ex.handle       = wine_server_obj_handle( handle );
        call.map_view_ex.addr         = wine_server_client_ptr( *addr_ptr );
        call.map_view_ex.size         = *size_ptr;
        call.map_view_ex.offset       = offset.QuadPart;
        call.map_view_ex.limit_low    = limit_low;
        call.map_view_ex.limit_high   = limit_high;
        call.map_view_ex.alloc_type   = alloc_type;
        call.map_view_ex.prot         = protect;
        call.map_view_ex.machine      = machine;
        status = server_queue_process_apc( process, &call, &result );
        if (status != STATUS_SUCCESS) return status;

        if (NT_SUCCESS(result.map_view_ex.status))
        {
            *addr_ptr = wine_server_get_ptr( result.map_view_ex.addr );
            *size_ptr = result.map_view_ex.size;
        }
        return result.map_view_ex.status;
    }

    return virtual_map_section( handle, addr_ptr, limit_low, limit_high, 0,
                                offset_ptr, size_ptr, alloc_type, protect, machine );
}


/***********************************************************************
 *             unmap_view_of_section
 *
 * NtUnmapViewOfSection[Ex] implementation.
 */
static NTSTATUS unmap_view_of_section( HANDLE process, PVOID addr, ULONG flags )
{
    struct file_view *view;
    unsigned int status = STATUS_NOT_MAPPED_VIEW;
    sigset_t sigset;

    if (process != NtCurrentProcess())
    {
        union apc_call call;
        union apc_result result;

        memset( &call, 0, sizeof(call) );

        call.unmap_view.type = APC_UNMAP_VIEW;
        call.unmap_view.addr = wine_server_client_ptr( addr );
        call.unmap_view.flags = flags;
        status = server_queue_process_apc( process, &call, &result );
        if (status == STATUS_SUCCESS) status = result.unmap_view.status;
        return status;
    }

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if (!(view = find_view( addr, 0 )) || is_view_valloc( view )) goto done;

    if (flags & MEM_PRESERVE_PLACEHOLDER && !(view->protect & VPROT_PLACEHOLDER))
    {
        status = STATUS_CONFLICTING_ADDRESSES;
        goto done;
    }
    if (view->protect & VPROT_SYSTEM)
    {
        struct builtin_module *builtin = get_builtin_module( view->base );

        if (builtin && builtin->refcount > 1)
        {
            TRACE( "not freeing in-use builtin %p\n", view->base );
            builtin->refcount--;
            server_leave_uninterrupted_section( &virtual_mutex, &sigset );
            return STATUS_SUCCESS;
        }
    }

    SERVER_START_REQ( unmap_view )
    {
        req->base = wine_server_client_ptr( view->base );
        status = wine_server_call( req );
    }
    SERVER_END_REQ;
    if (!status)
    {
        if (view->protect & SEC_IMAGE) release_builtin_module( view->base );
        if (flags & MEM_PRESERVE_PLACEHOLDER) free_pages_preserve_placeholder( view, view->base, view->size );
        else delete_view( view );
    }
    else FIXME( "failed to unmap %p %x\n", view->base, status );
done:
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return status;
}


/***********************************************************************
 *             NtUnmapViewOfSection   (NTDLL.@)
 *             ZwUnmapViewOfSection   (NTDLL.@)
 */
NTSTATUS WINAPI NtUnmapViewOfSection( HANDLE process, PVOID addr )
{
    return unmap_view_of_section( process, addr, 0 );
}

/***********************************************************************
 *             NtUnmapViewOfSectionEx   (NTDLL.@)
 *             ZwUnmapViewOfSectionEx   (NTDLL.@)
 */
NTSTATUS WINAPI NtUnmapViewOfSectionEx( HANDLE process, PVOID addr, ULONG flags )
{
    static const ULONG type_mask = MEM_UNMAP_WITH_TRANSIENT_BOOST | MEM_PRESERVE_PLACEHOLDER;

    if (flags & ~type_mask)
    {
        WARN( "Unsupported flags %#x.\n", flags );
        return STATUS_INVALID_PARAMETER;
    }
    if (flags & MEM_UNMAP_WITH_TRANSIENT_BOOST) FIXME( "Ignoring MEM_UNMAP_WITH_TRANSIENT_BOOST.\n" );
    return unmap_view_of_section( process, addr, flags );
}

/******************************************************************************
 *             virtual_fill_image_information
 *
 * Helper for NtQuerySection.
 */
void virtual_fill_image_information( const struct pe_image_info *pe_info, SECTION_IMAGE_INFORMATION *info )
{
    info->TransferAddress             = wine_server_get_ptr( pe_info->base + pe_info->entry_point );
    info->ZeroBits                    = pe_info->zerobits;
    info->MaximumStackSize            = pe_info->stack_size;
    info->CommittedStackSize          = pe_info->stack_commit;
    info->SubSystemType               = pe_info->subsystem;
    info->MinorSubsystemVersion       = pe_info->subsystem_minor;
    info->MajorSubsystemVersion       = pe_info->subsystem_major;
    info->MajorOperatingSystemVersion = pe_info->osversion_major;
    info->MinorOperatingSystemVersion = pe_info->osversion_minor;
    info->ImageCharacteristics        = pe_info->image_charact;
    info->DllCharacteristics          = pe_info->dll_charact;
    info->Machine                     = pe_info->machine;
    info->ImageContainsCode           = pe_info->contains_code;
    info->ImageFlags                  = pe_info->image_flags;
    info->LoaderFlags                 = pe_info->loader_flags;
    info->ImageFileSize               = pe_info->file_size;
    info->CheckSum                    = pe_info->checksum;
#ifndef _WIN64 /* don't return 64-bit values to 32-bit processes */
    if (is_machine_64bit( pe_info->machine ))
    {
        info->TransferAddress = (void *)0x81231234;  /* sic */
        info->MaximumStackSize = 0x100000;
        info->CommittedStackSize = 0x10000;
    }
#endif
}

/******************************************************************************
 *             NtQuerySection   (NTDLL.@)
 *             ZwQuerySection   (NTDLL.@)
 */
NTSTATUS WINAPI NtQuerySection( HANDLE handle, SECTION_INFORMATION_CLASS class, void *ptr,
                                SIZE_T size, SIZE_T *ret_size )
{
    unsigned int status;
    struct pe_image_info image_info;

    switch (class)
    {
    case SectionBasicInformation:
        if (size < sizeof(SECTION_BASIC_INFORMATION)) return STATUS_INFO_LENGTH_MISMATCH;
        break;
    case SectionImageInformation:
        if (size < sizeof(SECTION_IMAGE_INFORMATION)) return STATUS_INFO_LENGTH_MISMATCH;
        break;
    default:
	FIXME( "class %u not implemented\n", class );
	return STATUS_NOT_IMPLEMENTED;
    }
    if (!ptr) return STATUS_ACCESS_VIOLATION;

    SERVER_START_REQ( get_mapping_info )
    {
        req->handle = wine_server_obj_handle( handle );
        req->access = SECTION_QUERY;
        wine_server_set_reply( req, &image_info, sizeof(image_info) );
        if (!(status = wine_server_call( req )))
        {
            if (class == SectionBasicInformation)
            {
                SECTION_BASIC_INFORMATION *info = ptr;
                info->Attributes    = reply->flags;
                info->BaseAddress   = NULL;
                info->Size.QuadPart = reply->size;
                if (ret_size) *ret_size = sizeof(*info);
            }
            else if (reply->flags & SEC_IMAGE)
            {
                SECTION_IMAGE_INFORMATION *info = ptr;
                virtual_fill_image_information( &image_info, info );
                if (ret_size) *ret_size = sizeof(*info);
            }
            else status = STATUS_SECTION_NOT_IMAGE;
        }
    }
    SERVER_END_REQ;

    return status;
}


/***********************************************************************
 *             NtFlushVirtualMemory   (NTDLL.@)
 *             ZwFlushVirtualMemory   (NTDLL.@)
 */
NTSTATUS WINAPI NtFlushVirtualMemory( HANDLE process, LPCVOID *addr_ptr,
                                      SIZE_T *size_ptr, ULONG unknown )
{
    struct file_view *view;
    unsigned int status = STATUS_SUCCESS;
    sigset_t sigset;
    void *addr = ROUND_ADDR( *addr_ptr, page_mask );

    if (process != NtCurrentProcess())
    {
        union apc_call call;
        union apc_result result;

        memset( &call, 0, sizeof(call) );

        call.virtual_flush.type = APC_VIRTUAL_FLUSH;
        call.virtual_flush.addr = wine_server_client_ptr( addr );
        call.virtual_flush.size = *size_ptr;
        status = server_queue_process_apc( process, &call, &result );
        if (status != STATUS_SUCCESS) return status;

        if (result.virtual_flush.status == STATUS_SUCCESS)
        {
            *addr_ptr = wine_server_get_ptr( result.virtual_flush.addr );
            *size_ptr = result.virtual_flush.size;
        }
        return result.virtual_flush.status;
    }

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if (!(view = find_view( addr, *size_ptr ))) status = STATUS_INVALID_PARAMETER;
    else
    {
        if (!*size_ptr) *size_ptr = view->size;
        *addr_ptr = addr;
#ifdef MS_ASYNC
        if (msync( ROUND_ADDR( addr, host_page_mask ), ROUND_SIZE( addr, *size_ptr, host_page_mask ), MS_ASYNC ))
            status = STATUS_NOT_MAPPED_DATA;
#endif
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return status;
}


/***********************************************************************
 *             NtGetWriteWatch   (NTDLL.@)
 *             ZwGetWriteWatch   (NTDLL.@)
 */
NTSTATUS WINAPI NtGetWriteWatch( HANDLE process, ULONG flags, PVOID base, SIZE_T size, PVOID *addresses,
                                 ULONG_PTR *count, ULONG *granularity )
{
    NTSTATUS status = STATUS_SUCCESS;
    sigset_t sigset;

    size = ROUND_SIZE( base, size, page_mask );
    base = ROUND_ADDR( base, page_mask );

    if (!count || !granularity) return STATUS_ACCESS_VIOLATION;
    if (!*count || !size) return STATUS_INVALID_PARAMETER;
    if (flags & ~WRITE_WATCH_FLAG_RESET) return STATUS_INVALID_PARAMETER;

    if (!addresses) return STATUS_ACCESS_VIOLATION;

    TRACE( "%p %x %p-%p %p %lu\n", process, flags, base, (char *)base + size,
           addresses, *count );

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );

    if (is_write_watch_range( base, size ))
    {
        ULONG_PTR pos = 0;
        char *addr = base;
        char *end = addr + size;

        if (use_kernel_writewatch)
            kernel_get_write_watches( base, size, addresses, count, flags & WRITE_WATCH_FLAG_RESET );
        else
        {
            while (pos < *count && addr < end)
            {
                if (!(get_page_vprot( addr ) & VPROT_WRITEWATCH)) addresses[pos++] = addr;
                addr += page_size;
            }
            size = addr - (char *)base;
            *count = pos;
        }
        if (flags & WRITE_WATCH_FLAG_RESET && (enable_write_exceptions || !use_kernel_writewatch))
        {
            if (use_kernel_writewatch)
                set_page_vprot_exec_write_protect( base, size );
            else
                set_page_vprot_bits( base, size, VPROT_WRITEWATCH, 0 );
            mprotect_range( base, size, 0, 0 );
        }
        *granularity = page_size;
    }
    else status = STATUS_INVALID_PARAMETER;

    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return status;
}


/***********************************************************************
 *             NtResetWriteWatch   (NTDLL.@)
 *             ZwResetWriteWatch   (NTDLL.@)
 */
NTSTATUS WINAPI NtResetWriteWatch( HANDLE process, PVOID base, SIZE_T size )
{
    NTSTATUS status = STATUS_SUCCESS;
    sigset_t sigset;

    size = ROUND_SIZE( base, size, page_mask );
    base = ROUND_ADDR( base, page_mask );

    TRACE( "%p %p-%p\n", process, base, (char *)base + size );

    if (!size) return STATUS_INVALID_PARAMETER;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );

    if (is_write_watch_range( base, size ))
        reset_write_watches( base, size );
    else
        status = STATUS_INVALID_PARAMETER;

    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return status;
}


/***********************************************************************
 *             NtReadVirtualMemory   (NTDLL.@)
 *             ZwReadVirtualMemory   (NTDLL.@)
 */
NTSTATUS WINAPI NtReadVirtualMemory( HANDLE process, const void *addr, void *buffer,
                                     SIZE_T size, SIZE_T *bytes_read )
{
    unsigned int status;

    if (!virtual_check_buffer_for_write( buffer, size ))
    {
        status = STATUS_ACCESS_VIOLATION;
        size = 0;
    }
    else if (process == GetCurrentProcess())
    {
        __TRY
        {
            memmove( buffer, addr, size );
            status = STATUS_SUCCESS;
        }
        __EXCEPT
        {
            status = STATUS_PARTIAL_COPY;
            size = 0;
        }
        __ENDTRY
    }
    else
    {
        SERVER_START_REQ( read_process_memory )
        {
            req->handle = wine_server_obj_handle( process );
            req->addr   = wine_server_client_ptr( addr );
            wine_server_set_reply( req, buffer, size );
            if ((status = wine_server_call( req ))) size = 0;
        }
        SERVER_END_REQ;
    }
    if (bytes_read) *bytes_read = size;
    return status;
}


/***********************************************************************
 *             NtWriteVirtualMemory   (NTDLL.@)
 *             ZwWriteVirtualMemory   (NTDLL.@)
 */
NTSTATUS WINAPI NtWriteVirtualMemory( HANDLE process, void *addr, const void *buffer,
                                      SIZE_T size, SIZE_T *bytes_written )
{
    unsigned int status;

    if (virtual_check_buffer_for_read( buffer, size ))
    {
        SERVER_START_REQ( write_process_memory )
        {
            req->handle     = wine_server_obj_handle( process );
            req->addr       = wine_server_client_ptr( addr );
            wine_server_add_data( req, buffer, size );
            status = wine_server_call( req );
            size = reply->written;
        }
        SERVER_END_REQ;
    }
    else
    {
        status = STATUS_PARTIAL_COPY;
        size = 0;
    }
    if (bytes_written) *bytes_written = size;
    return status;
}


/***********************************************************************
 *             NtAreMappedFilesTheSame   (NTDLL.@)
 *             ZwAreMappedFilesTheSame   (NTDLL.@)
 */
NTSTATUS WINAPI NtAreMappedFilesTheSame(PVOID addr1, PVOID addr2)
{
    struct file_view *view1, *view2;
    unsigned int status;
    sigset_t sigset;

    TRACE("%p %p\n", addr1, addr2);

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );

    view1 = find_view( addr1, 0 );
    view2 = find_view( addr2, 0 );

    if (!view1 || !view2)
        status = STATUS_INVALID_ADDRESS;
    else if (is_view_valloc( view1 ) || is_view_valloc( view2 ))
        status = STATUS_CONFLICTING_ADDRESSES;
    else if (view1 == view2)
        status = STATUS_SUCCESS;
    else if ((view1->protect & VPROT_SYSTEM) || (view2->protect & VPROT_SYSTEM))
        status = STATUS_NOT_SAME_DEVICE;
    else
    {
        SERVER_START_REQ( is_same_mapping )
        {
            req->base1 = wine_server_client_ptr( view1->base );
            req->base2 = wine_server_client_ptr( view2->base );
            status = wine_server_call( req );
        }
        SERVER_END_REQ;
    }

    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return status;
}


static NTSTATUS prefetch_memory( HANDLE process, ULONG_PTR count,
                                 PMEMORY_RANGE_ENTRY addresses, ULONG flags )
{
    ULONG_PTR i;
    PVOID base;
    SIZE_T size;
    static unsigned int once;

    if (!once++)
    {
        FIXME( "(process=%p,flags=%u) NtSetInformationVirtualMemory(VmPrefetchInformation) partial stub\n",
                process, flags );
    }

    for (i = 0; i < count; i++)
    {
        if (!addresses[i].NumberOfBytes) return STATUS_INVALID_PARAMETER_4;
    }

    if (process != NtCurrentProcess()) return STATUS_SUCCESS;

    for (i = 0; i < count; i++)
    {
        base = ROUND_ADDR( addresses[i].VirtualAddress, host_page_mask );
        size = ROUND_SIZE( addresses[i].VirtualAddress, addresses[i].NumberOfBytes, host_page_mask );
        madvise( base, size, MADV_WILLNEED );
    }

    return STATUS_SUCCESS;
}

static NTSTATUS set_dirty_state_information( ULONG_PTR count, MEMORY_RANGE_ENTRY *addresses )
{
    ULONG_PTR i;
    sigset_t sigset;
    NTSTATUS ret = STATUS_SUCCESS;

    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    for (i = 0; i < count; i++)
    {
        void *base = ROUND_ADDR( addresses[i].VirtualAddress, page_mask );
        SIZE_T size = ROUND_SIZE( addresses[i].VirtualAddress, addresses[i].NumberOfBytes, page_mask );
        struct file_view *view = find_view( base, size );

        if (!view)
        {
            ret = STATUS_MEMORY_NOT_ALLOCATED;
            break;
        }
        if (use_kernel_writewatch) reset_write_watches( base, size );
        else if (set_page_vprot_exec_write_protect( base, size ))
            mprotect_range( base, size, 0, 0 );
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    return ret;
}

/***********************************************************************
 *           NtSetInformationVirtualMemory   (NTDLL.@)
 *           ZwSetInformationVirtualMemory   (NTDLL.@)
 */
NTSTATUS WINAPI NtSetInformationVirtualMemory( HANDLE process,
                                               VIRTUAL_MEMORY_INFORMATION_CLASS info_class,
                                               ULONG_PTR count, PMEMORY_RANGE_ENTRY addresses,
                                               PVOID ptr, ULONG size )
{
    TRACE("(%p, info_class=%d, %lu, %p, %p, %u)\n",
          process, info_class, count, addresses, ptr, size);

    switch (info_class)
    {
    case VmPrefetchInformation:
        if (!ptr) return STATUS_INVALID_PARAMETER_5;
        if (size != sizeof(ULONG)) return STATUS_INVALID_PARAMETER_6;
        if (!count) return STATUS_INVALID_PARAMETER_3;
        return prefetch_memory( process, count, addresses, *(ULONG *)ptr );

    case VmPageDirtyStateInformation:
        if (process != GetCurrentProcess()) return STATUS_NOT_SUPPORTED;
        if (!enable_write_exceptions) return STATUS_NOT_SUPPORTED;
        if (!ptr) return STATUS_INVALID_PARAMETER_5;
        if (size != sizeof(ULONG)) return STATUS_INVALID_PARAMETER_6;
        if (*(ULONG *)ptr) return STATUS_INVALID_PARAMETER_5;
        if (!count) return STATUS_INVALID_PARAMETER_3;
        return set_dirty_state_information( count, addresses );

    default:
        FIXME("(%p,info_class=%d,%lu,%p,%p,%u) Unknown information class\n",
              process, info_class, count, addresses, ptr, size);
        return STATUS_INVALID_PARAMETER_2;
    }
}


/**********************************************************************
 *           NtFlushInstructionCache  (NTDLL.@)
 */
NTSTATUS WINAPI NtFlushInstructionCache( HANDLE handle, const void *addr, SIZE_T size )
{
#if defined(__x86_64__) || defined(__i386__)
    /* no-op */
#elif defined(HAVE___CLEAR_CACHE)
    if (handle == GetCurrentProcess())
    {
        __clear_cache( (char *)addr, (char *)addr + size );
    }
    else
    {
        static int once;
        if (!once++) FIXME( "%p %p %ld other process not supported\n", handle, addr, size );
    }
#else
    static int once;
    if (!once++) FIXME( "%p %p %ld\n", handle, addr, size );
#endif
    return STATUS_SUCCESS;
}


#ifdef __APPLE__

static kern_return_t (*p_thread_get_register_pointer_values)( thread_t, uintptr_t*, size_t*, uintptr_t* );
static pthread_once_t tgrpvs_init_once = PTHREAD_ONCE_INIT;

static void tgrpvs_init(void)
{
    p_thread_get_register_pointer_values = dlsym( RTLD_DEFAULT, "thread_get_register_pointer_values" );
    if (!p_thread_get_register_pointer_values)
        FIXME( "thread_get_register_pointer_values not supported for NtFlushProcessWriteBuffers\n" );
}

/**********************************************************************
 *           NtFlushProcessWriteBuffers  (NTDLL.@)
 */
NTSTATUS WINAPI NtFlushProcessWriteBuffers(void)
{
    /* Taken from https://github.com/dotnet/runtime/blob/7be37908e5a1cbb83b1062768c1649827eeaceaa/src/coreclr/pal/src/thread/process.cpp#L2799 */
    mach_msg_type_number_t count, i;
    thread_act_array_t threads;

    pthread_once( &tgrpvs_init_once, tgrpvs_init );
    if (!p_thread_get_register_pointer_values) return STATUS_SUCCESS;

    /* Get references to all threads of this process */
    if (task_threads( mach_task_self(), &threads, &count )) return STATUS_SUCCESS;

    for (i = 0; i < count; i++)
    {
        uintptr_t reg_values[128];
        size_t reg_count = ARRAY_SIZE( reg_values );
        uintptr_t sp;

        /* Request the thread's register pointer values to force the thread to go through a memory barrier */
        p_thread_get_register_pointer_values( threads[i], &sp, &reg_count, reg_values );
        mach_port_deallocate( mach_task_self(), threads[i] );
    }
    vm_deallocate( mach_task_self(), (vm_address_t)threads, count * sizeof(threads[0]) );
    return STATUS_SUCCESS;
}

#elif defined(__linux__) && defined(__NR_membarrier)

#define MEMBARRIER_CMD_PRIVATE_EXPEDITED            0x08
#define MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED   0x10

static pthread_once_t membarrier_init_once = PTHREAD_ONCE_INIT;

static int membarrier( int cmd, unsigned int flags, int cpu_id )
{
    return syscall( __NR_membarrier, cmd, flags, cpu_id );
}

static void membarrier_init(void)
{
    if (membarrier( MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED, 0, 0 ))
        FIXME( "membarrier not supported for NtFlushProcessWriteBuffers\n" );
}

/**********************************************************************
 *           NtFlushProcessWriteBuffers  (NTDLL.@)
 */
NTSTATUS WINAPI NtFlushProcessWriteBuffers(void)
{
    pthread_once( &membarrier_init_once, membarrier_init );
    membarrier( MEMBARRIER_CMD_PRIVATE_EXPEDITED, 0, 0 );
    return STATUS_SUCCESS;
}

#else /* __linux__ */

/**********************************************************************
 *           NtFlushProcessWriteBuffers  (NTDLL.@)
 */
NTSTATUS WINAPI NtFlushProcessWriteBuffers(void)
{
    static int once = 0;
    if (!once++) FIXME( "stub\n" );
    return STATUS_SUCCESS;
}

#endif

/**********************************************************************
 *           NtCreatePagingFile  (NTDLL.@)
 */
NTSTATUS WINAPI NtCreatePagingFile( UNICODE_STRING *name, LARGE_INTEGER *min_size,
                                    LARGE_INTEGER *max_size, LARGE_INTEGER *actual_size )
{
    FIXME( "(%s %p %p %p) stub\n", debugstr_us(name), min_size, max_size, actual_size );
    return STATUS_SUCCESS;
}

#ifndef _WIN64

/***********************************************************************
 *             NtWow64AllocateVirtualMemory64   (NTDLL.@)
 *             ZwWow64AllocateVirtualMemory64   (NTDLL.@)
 */
NTSTATUS WINAPI NtWow64AllocateVirtualMemory64( HANDLE process, ULONG64 *ret, ULONG64 zero_bits,
                                                ULONG64 *size_ptr, ULONG type, ULONG protect )
{
    void *base;
    SIZE_T size;
    unsigned int status;

    TRACE("%p %s %s %x %08x\n", process,
          wine_dbgstr_longlong(*ret), wine_dbgstr_longlong(*size_ptr), type, protect );

    if (!*size_ptr) return STATUS_INVALID_PARAMETER_4;
    if (zero_bits > 21 && zero_bits < 32) return STATUS_INVALID_PARAMETER_3;

    if (process != NtCurrentProcess())
    {
        union apc_call call;
        union apc_result result;

        memset( &call, 0, sizeof(call) );

        call.virtual_alloc.type         = APC_VIRTUAL_ALLOC;
        call.virtual_alloc.addr         = *ret;
        call.virtual_alloc.size         = *size_ptr;
        call.virtual_alloc.zero_bits    = zero_bits;
        call.virtual_alloc.op_type      = type;
        call.virtual_alloc.prot         = protect;
        status = server_queue_process_apc( process, &call, &result );
        if (status != STATUS_SUCCESS) return status;

        if (result.virtual_alloc.status == STATUS_SUCCESS)
        {
            *ret      = result.virtual_alloc.addr;
            *size_ptr = result.virtual_alloc.size;
        }
        return result.virtual_alloc.status;
    }

    base = (void *)(ULONG_PTR)*ret;
    size = *size_ptr;
    if ((ULONG_PTR)base != *ret) return STATUS_CONFLICTING_ADDRESSES;
    if (size != *size_ptr) return STATUS_WORKING_SET_LIMIT_RANGE;

    status = NtAllocateVirtualMemory( process, &base, zero_bits, &size, type, protect );
    if (!status)
    {
        *ret = (ULONG_PTR)base;
        *size_ptr = size;
    }
    return status;
}


/***********************************************************************
 *             NtWow64ReadVirtualMemory64   (NTDLL.@)
 *             ZwWow64ReadVirtualMemory64   (NTDLL.@)
 */
NTSTATUS WINAPI NtWow64ReadVirtualMemory64( HANDLE process, ULONG64 addr, void *buffer,
                                            ULONG64 size, ULONG64 *bytes_read )
{
    unsigned int status;

    if (size > MAXLONG) size = MAXLONG;

    if (virtual_check_buffer_for_write( buffer, size ))
    {
        SERVER_START_REQ( read_process_memory )
        {
            req->handle = wine_server_obj_handle( process );
            req->addr   = addr;
            wine_server_set_reply( req, buffer, size );
            if ((status = wine_server_call( req ))) size = 0;
        }
        SERVER_END_REQ;
    }
    else
    {
        status = STATUS_ACCESS_VIOLATION;
        size = 0;
    }
    if (bytes_read) *bytes_read = size;
    return status;
}


/***********************************************************************
 *             NtWow64WriteVirtualMemory64   (NTDLL.@)
 *             ZwWow64WriteVirtualMemory64   (NTDLL.@)
 */
NTSTATUS WINAPI NtWow64WriteVirtualMemory64( HANDLE process, ULONG64 addr, const void *buffer,
                                             ULONG64 size, ULONG64 *bytes_written )
{
    unsigned int status;

    if (size > MAXLONG) size = MAXLONG;

    if (virtual_check_buffer_for_read( buffer, size ))
    {
        SERVER_START_REQ( write_process_memory )
        {
            req->handle     = wine_server_obj_handle( process );
            req->addr       = addr;
            wine_server_add_data( req, buffer, size );
            if ((status = wine_server_call( req ))) size = 0;
        }
        SERVER_END_REQ;
    }
    else
    {
        status = STATUS_PARTIAL_COPY;
        size = 0;
    }
    if (bytes_written) *bytes_written = size;
    return status;
}


/***********************************************************************
 *             NtWow64GetNativeSystemInformation   (NTDLL.@)
 *             ZwWow64GetNativeSystemInformation   (NTDLL.@)
 */
NTSTATUS WINAPI NtWow64GetNativeSystemInformation( SYSTEM_INFORMATION_CLASS class, void *info,
                                                   ULONG len, ULONG *retlen )
{
    NTSTATUS status;

    switch (class)
    {
    case SystemCpuInformation:
        status = NtQuerySystemInformation( class, info, len, retlen );
        if (!status && is_old_wow64())
        {
            SYSTEM_CPU_INFORMATION *cpu = info;

            if (cpu->ProcessorArchitecture == PROCESSOR_ARCHITECTURE_INTEL)
                cpu->ProcessorArchitecture = PROCESSOR_ARCHITECTURE_AMD64;
        }
        return status;
    case SystemBasicInformation:
    case SystemEmulationBasicInformation:
    case SystemEmulationProcessorInformation:
        return NtQuerySystemInformation( class, info, len, retlen );
    case SystemNativeBasicInformation:
        return NtQuerySystemInformation( SystemBasicInformation, info, len, retlen );
    default:
        if (is_old_wow64()) return STATUS_INVALID_INFO_CLASS;
        return NtQuerySystemInformation( class, info, len, retlen );
    }
}

/***********************************************************************
 *             NtWow64IsProcessorFeaturePresent   (NTDLL.@)
 *             ZwWow64IsProcessorFeaturePresent   (NTDLL.@)
 */
NTSTATUS WINAPI NtWow64IsProcessorFeaturePresent( UINT feature )
{
    return feature < PROCESSOR_FEATURE_MAX && user_shared_data->ProcessorFeatures[feature];
}

#endif  /* _WIN64 */
