#include "JITAllocator.h"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <sys/mman.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <os/log.h>
#include <os/proc.h>

// csops syscall - used to check CS_DEBUGGED flag
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

/* ml748: <mach/mach_vm.h> is "unsupported" on the iOS SDK, but these are
 * exported by libsystem_kernel and are the only calls that report a region's
 * max_protection -- which the W^X probe needs, since the failure mode is a
 * successful-looking call whose W was silently stripped. */
extern kern_return_t mach_vm_region(vm_map_t, mach_vm_address_t *, mach_vm_size_t *,
                                    vm_region_flavor_t, vm_region_info_t,
                                    mach_msg_type_number_t *, mach_port_t *);
extern kern_return_t mach_vm_protect(vm_map_t, mach_vm_address_t, mach_vm_size_t,
                                     boolean_t, vm_prot_t);

// Page size on iOS is 16KB
#define JIT_PAGE_SIZE 0x4000

// VM_LEDGER_TAG_DEFAULT and VM_LEDGER_FLAG_NO_FOOTPRINT
// These are private Mach APIs used by MeloNX to make JIT memory
// not count against the app's Jetsam memory limit.
#ifndef VM_LEDGER_TAG_DEFAULT
#define VM_LEDGER_TAG_DEFAULT 0
#endif
#ifndef VM_LEDGER_FLAG_NO_FOOTPRINT
#define VM_LEDGER_FLAG_NO_FOOTPRINT (1 << 0)
#endif

// Private Mach API declarations
extern kern_return_t mach_memory_entry_ownership(
    mach_port_t mem_entry,
    mach_port_t owner,
    int ledger_tag,
    int ledger_flags
);

struct JITRegion {
    void *rw_ptr;       // Read-Write view (for writing code)
    void *rx_ptr;       // Read-Execute view (for executing code)
    size_t size;        // Size of the region
    mach_port_t mem_entry;  // Memory entry port for cleanup
};

static jit_log_callback_t g_log_callback = NULL;

void jit_set_log_callback(jit_log_callback_t callback) {
    g_log_callback = callback;
}

static void jit_log(const char *fmt, ...) {
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    if (g_log_callback) {
        g_log_callback(buf);
    }
    // Log to os_log (visible in Console.app) and stderr (Xcode)
    os_log(OS_LOG_DEFAULT, "[JIT] %{public}s", buf);
    fprintf(stderr, "[JIT] %s\n", buf);
}

static size_t align_to_page(size_t size) {
    return (size + JIT_PAGE_SIZE - 1) & ~(JIT_PAGE_SIZE - 1);
}

JITRegion *jit_region_create(size_t size) {
    size = align_to_page(size);

    JITRegion *region = calloc(1, sizeof(JITRegion));
    if (!region) {
        jit_log("Failed to allocate JITRegion struct");
        return NULL;
    }
    region->size = size;
    region->mem_entry = MACH_PORT_NULL;

    kern_return_t kr;
    mach_port_t task = mach_task_self();

    // Strategy: MeloNX dual-mapping approach
    //
    // 1. Create a named memory entry with RWX max protection
    // 2. Mark it as no-footprint (doesn't count against Jetsam limit)
    // 3. Map two views of it:
    //    - RW view for writing generated code
    //    - RX view for executing generated code

    // Step 1: Create a named memory entry
    memory_object_size_t entry_size = (memory_object_size_t)size;
    mach_port_t mem_entry = MACH_PORT_NULL;

    kr = mach_make_memory_entry_64(
        task,
        &entry_size,
        0,  // offset
        MAP_MEM_NAMED_CREATE | VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE,
        &mem_entry,
        MACH_PORT_NULL  // parent entry
    );

    if (kr != KERN_SUCCESS) {
        jit_log("mach_make_memory_entry_64 failed: %s (kr=%d)", mach_error_string(kr), kr);
        free(region);
        return NULL;
    }

    jit_log("Created memory entry: port=%d, size=%zu", mem_entry, (size_t)entry_size);
    region->mem_entry = mem_entry;

    // Step 2: Mark as no-footprint (MeloNX trick)
    // This makes the memory not count against the app's Jetsam memory limit.
    kr = mach_memory_entry_ownership(
        mem_entry,
        TASK_NULL,  // No owner task = system-owned
        VM_LEDGER_TAG_DEFAULT,
        VM_LEDGER_FLAG_NO_FOOTPRINT
    );

    if (kr != KERN_SUCCESS) {
        // Non-fatal: memory will just count against the limit
        jit_log("mach_memory_entry_ownership failed (non-fatal): %s (kr=%d)", mach_error_string(kr), kr);
    } else {
        jit_log("Memory entry marked as no-footprint");
    }

    // Step 3a: Map RW view (for writing code)
    mach_vm_address_t rw_addr = 0;
    kr = vm_map(
        task,
        (vm_address_t *)&rw_addr,
        size,
        0,  // mask
        VM_FLAGS_ANYWHERE,
        mem_entry,
        0,  // offset
        FALSE,  // copy
        VM_PROT_READ | VM_PROT_WRITE,      // current protection
        VM_PROT_READ | VM_PROT_WRITE,      // max protection
        VM_INHERIT_DEFAULT
    );

    if (kr != KERN_SUCCESS) {
        jit_log("vm_map (RW) failed: %s (kr=%d)", mach_error_string(kr), kr);
        mach_port_deallocate(task, mem_entry);
        free(region);
        return NULL;
    }

    region->rw_ptr = (void *)rw_addr;
    jit_log("Mapped RW view at %p", region->rw_ptr);

    // Step 3b: Map RX view (for executing code)
    mach_vm_address_t rx_addr = 0;
    kr = vm_map(
        task,
        (vm_address_t *)&rx_addr,
        size,
        0,  // mask
        VM_FLAGS_ANYWHERE,
        mem_entry,
        0,  // offset
        FALSE,  // copy
        VM_PROT_READ | VM_PROT_EXECUTE,                  // current protection
        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE,  // max protection
        // Wider max so vm_protect can grant temporary W (e.g. FEX
        // PatchCallChecker writes to its __ImageBase + RVA, which lands
        // on the RX alias). vm_protect+VM_PROT_COPY then COW-flips the
        // page R/W. W^X still enforced via the actual current protection.
        VM_INHERIT_DEFAULT
    );

    if (kr != KERN_SUCCESS) {
        jit_log("vm_map (RX) failed: %s (kr=%d)", mach_error_string(kr), kr);
        // Clean up RW mapping
        vm_deallocate(task, (vm_address_t)region->rw_ptr, size);
        mach_port_deallocate(task, mem_entry);
        free(region);
        return NULL;
    }

    region->rx_ptr = (void *)rx_addr;
    jit_log("Mapped RX view at %p", region->rx_ptr);
    jit_log("Dual-mapped JIT region created: size=%zu, RW=%p, RX=%p", size, region->rw_ptr, region->rx_ptr);

    return region;
}

// ml358: make an ALREADY-MAPPED region jetsam-exempt.
//
// jit_region_create() marks its memory entry NO_FOOTPRINT, but the production
// pool never goes through it — allocatePool() gets its RX pages from StikDebug
// (jit26_prepare_region) and vm_remaps the RW alias, so the 896MB pool has
// been counting against phys_footprint in full this whole time. ml357 died of
// exactly that ("Terminated due to memory issue" with 848MB of pool written
// and PartitionAlloc's reserves at 0% committed).
//
// mach_make_memory_entry_64 over an existing range hands back an entry for the
// SAME vm_object both aliases share, so ownership applied to it should re-account
// resident pages as well as future ones. This is private API on a beta OS: every
// step is logged, failure is non-fatal, and phys_footprint is sampled either
// side so the log says whether it actually WORKED rather than whether it was
// merely attempted.
bool jit_make_region_no_footprint(void *addr, size_t size, const char *label) {
    mach_port_t task = mach_task_self();
    kern_return_t kr;

    uint64_t fp_before = 0, fp_after = 0;
    task_vm_info_data_t vmi;
    mach_msg_type_number_t vmi_cnt = TASK_VM_INFO_COUNT;
    if (task_info(task, TASK_VM_INFO, (task_info_t)&vmi, &vmi_cnt) == KERN_SUCCESS) {
        fp_before = vmi.phys_footprint;
    }

    /* ml458 (#75): the original single attempt used MAP_MEM_VM_SHARE and always
     * came back "ownership failed kr=4" (KERN_INVALID_ARGUMENT) — so the 896MB
     * pool has counted against phys_footprint every run, which is what pins the
     * pool at a size that now exhausts (ml455/ml456 both died there) and what
     * jetsam'd the 1024MB attempt at ml421-422.
     *
     * kr=4 is a REJECTED ENTRY KIND, not a permissions refusal (that would be
     * KERN_NO_ACCESS / KERN_PROTECTION_FAILURE): MAP_MEM_VM_SHARE hands back a
     * copy-style named entry, while the ownership call wants an entry that
     * names the VM object itself — which is exactly the difference from
     * jit_region_create()'s MAP_MEM_NAMED_CREATE entry, where this same
     * ownership call succeeds.
     *
     * This is undocumented private API on a beta OS, so instead of betting the
     * run on one guess, walk a small ladder of (entry-flags, owner) pairs and
     * let the log say which pair the kernel accepts.  Every step prints its kr;
     * the winner prints the phys_footprint delta, which is the only honest
     * proof the exemption took effect (a delta of ≈ the resident pool bytes
     * means real relief; ≈0 means the kernel accepted the call but kept
     * charging us). Non-fatal throughout: worst case we are exactly as
     * jetsam-counted as before. */
    struct { unsigned int flags; int own_self; const char *name; } variants[] = {
        { VM_PROT_READ | VM_PROT_WRITE,                    0, "plain/TASK_NULL" },
        { VM_PROT_READ | VM_PROT_WRITE,                    1, "plain/self" },
        { MAP_MEM_VM_SHARE | VM_PROT_READ | VM_PROT_WRITE, 1, "share/self" },
        { MAP_MEM_VM_SHARE | VM_PROT_READ | VM_PROT_WRITE, 0, "share/TASK_NULL" },
    };

    for (unsigned v = 0; v < sizeof(variants) / sizeof(variants[0]); v++) {
        memory_object_size_t entry_size = (memory_object_size_t)size;
        mach_port_t entry = MACH_PORT_NULL;
        kr = mach_make_memory_entry_64(
            task,
            &entry_size,
            (memory_object_offset_t)(uintptr_t)addr,
            variants[v].flags,
            &entry,
            MACH_PORT_NULL
        );
        if (kr != KERN_SUCCESS || entry == MACH_PORT_NULL) {
            jit_log("[no-footprint] %s: [%s] make_memory_entry failed kr=%d (%s) rev=ml458",
                    label, variants[v].name, kr, mach_error_string(kr));
            continue;
        }
        if ((size_t)entry_size < size) {
            jit_log("[no-footprint] %s: [%s] entry covers only %llu of %zu bytes (partial)",
                    label, variants[v].name, (unsigned long long)entry_size, size);
        }

        kr = mach_memory_entry_ownership(entry,
                                         variants[v].own_self ? task : TASK_NULL,
                                         VM_LEDGER_TAG_DEFAULT,
                                         VM_LEDGER_FLAG_NO_FOOTPRINT);
        mach_port_deallocate(task, entry);
        if (kr != KERN_SUCCESS) {
            jit_log("[no-footprint] %s: [%s] ownership failed kr=%d (%s) rev=ml458",
                    label, variants[v].name, kr, mach_error_string(kr));
            continue;
        }

        vmi_cnt = TASK_VM_INFO_COUNT;
        if (task_info(task, TASK_VM_INFO, (task_info_t)&vmi, &vmi_cnt) == KERN_SUCCESS) {
            fp_after = vmi.phys_footprint;
        }
        jit_log("[no-footprint] %s: [%s] ownership OK for %zu MB | phys_footprint %llu MB -> %llu MB "
                "(delta %lld MB) rev=ml458",
                label, variants[v].name, size >> 20,
                (unsigned long long)(fp_before >> 20), (unsigned long long)(fp_after >> 20),
                ((long long)fp_after - (long long)fp_before) >> 20);
        return true;
    }

    jit_log("[no-footprint] %s: ALL %zu variants refused — pool stays jetsam-counted rev=ml458",
            label, sizeof(variants) / sizeof(variants[0]));
    return false;
}

void jit_region_destroy(JITRegion *region) {
    if (!region) return;

    mach_port_t task = mach_task_self();

    if (region->rw_ptr) {
        vm_deallocate(task, (vm_address_t)region->rw_ptr, region->size);
        jit_log("Unmapped RW view at %p", region->rw_ptr);
    }
    if (region->rx_ptr) {
        vm_deallocate(task, (vm_address_t)region->rx_ptr, region->size);
        jit_log("Unmapped RX view at %p", region->rx_ptr);
    }
    if (region->mem_entry != MACH_PORT_NULL) {
        mach_port_deallocate(task, region->mem_entry);
    }

    free(region);
}

void *jit_region_rw_ptr(JITRegion *region) {
    return region ? region->rw_ptr : NULL;
}

void *jit_region_rx_ptr(JITRegion *region) {
    return region ? region->rx_ptr : NULL;
}

size_t jit_region_size(JITRegion *region) {
    return region ? region->size : 0;
}

void jit_region_invalidate(JITRegion *region, size_t offset, size_t size) {
    if (!region || !region->rx_ptr) return;
    sys_icache_invalidate((char *)region->rx_ptr + offset, size);
}

void *jit_region_write(JITRegion *region, size_t offset, const void *code, size_t code_size) {
    if (!region) return NULL;
    if (offset + code_size > region->size) {
        jit_log("Write out of bounds: offset=%zu, code_size=%zu, region_size=%zu",
                offset, code_size, region->size);
        return NULL;
    }

    // Write to the RW view
    memcpy((char *)region->rw_ptr + offset, code, code_size);

    // Invalidate icache on the RX view
    sys_icache_invalidate((char *)region->rx_ptr + offset, code_size);

    // Return the RX pointer for execution
    return (char *)region->rx_ptr + offset;
}

// SIGTRAP handler: skips BRK instruction (PC += 4) and zeros x0.
// This prevents crashes when BRK is executed without a debugger attached.
// ml1233: only the JIT protocol's BRK #0xf00d (as Wine's handler does). Any other
// trap is not ours -- a Swift runtime trap (precondition, force unwrap, overflow)
// is BRK #1 -- and was skipped too, running on past it with x0 = 0. The handler
// stays installed for the rest of the app run (from start-up without CS_DEBUGGED,
// or from jit_arm_trap_fallback before a launch that then fails and keeps the app
// up), so put the default action back and return: the instruction traps again and
// the app crashes with a report.
static void sigtrap_handler(int sig, siginfo_t *info, void *context) {
    (void)info;
    ucontext_t *uc = (ucontext_t *)context;
    uint64_t pc = uc->uc_mcontext->__ss.__pc;
    if ((pc & 3) || *(const uint32_t *)(uintptr_t)pc != 0xd43e01a0u /* brk #0xf00d */) {
        struct sigaction dfl;
        memset(&dfl, 0, sizeof(dfl));
        dfl.sa_handler = SIG_DFL;
        sigaction(sig, &dfl, NULL);
        return;
    }
    uc->uc_mcontext->__ss.__pc += 4;
    uc->uc_mcontext->__ss.__x[0] = 0;
}

void jit_install_trap_handler(void) {
    // Only install if no debugger is attached.
    // When StikDebug is attached, it handles BRK/SIGTRAP directly.
    // Our handler would steal signals from the debugger and break the protocol.
    if (jit_check_debugged()) {
        jit_log("Debugger attached — skipping SIGTRAP handler (debugger handles BRK)");
        return;
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_flags = SA_SIGINFO;
    sa.sa_sigaction = sigtrap_handler;
    sigaction(SIGTRAP, &sa, NULL);
    jit_log("SIGTRAP handler installed (no debugger)");
}

void jit_arm_trap_fallback(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_flags = SA_SIGINFO;
    sa.sa_sigaction = sigtrap_handler;
    sigaction(SIGTRAP, &sa, NULL);
    jit_log("SIGTRAP handler installed (CS_DEBUGGED set, no debugger attached)");
}

bool jit_cs_status(uint32_t *flags) {
    uint32_t value = 0;
    if (csops(getpid(), CS_OPS_STATUS, &value, sizeof(value)) != 0) return false;
    *flags = value;
    return true;
}

bool jit_task_map_range(uint64_t *min_address, uint64_t *max_address) {
    task_vm_info_data_t vmi;
    mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmi, &cnt) != KERN_SUCCESS ||
        !vmi.max_address) return false;
    *min_address = vmi.min_address;
    *max_address = vmi.max_address;
    return true;
}

uint64_t jit_available_memory(void) {
    return (uint64_t)os_proc_available_memory();
}

// iOS 26 BRK-based JIT syscalls.
// These use BRK #0xf00d with x16 indicating the command.
// When a debugger (StikDebug) is attached, it intercepts the BRK,
// reads x16/x0/x1, performs the operation, and resumes.
// When no debugger is attached, the SIGTRAP handler skips the BRK.

__attribute__((noinline, optnone))
void *jit26_prepare_region(void *addr, size_t len) {
    register void *x0 __asm__("x0") = addr;
    register size_t x1 __asm__("x1") = len;
    __asm__ volatile(
        "mov x16, #1\n"
        "brk #0xf00d\n"
        : "+r"(x0)
        : "r"(x1)
        : "x16", "memory"
    );
    return x0;
}

__attribute__((noinline, optnone))
void jit26_detach(void) {
    __asm__ volatile(
        "mov x16, #0\n"
        "brk #0xf00d\n"
        ::: "x16", "memory"
    );
}

bool jit_check_debugged(void) {
    uint32_t flags = 0;
    int result = csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags));
    if (result != 0) {
        jit_log("csops failed, assuming not debugged");
        return false;
    }
    bool debugged = (flags & CS_DEBUGGED) != 0;
    jit_log("CS_DEBUGGED flag: %s (flags=0x%x)", debugged ? "SET" : "NOT SET", flags);
    return debugged;
}

bool jit_test_mapping(void) {
    jit_log("=== JIT Mapping Test (non-executing) ===");

    // Test 1: Can we create a dual-mapped region?
    JITRegion *region = jit_region_create(JIT_PAGE_SIZE);
    if (!region) {
        jit_log("FAIL: Could not create dual-mapped region");
        return false;
    }
    jit_log("OK: Dual-mapped region created");

    // Test 2: Are RW and RX at different virtual addresses?
    if (region->rw_ptr == region->rx_ptr) {
        jit_log("FAIL: RW and RX are at the same address");
        jit_region_destroy(region);
        return false;
    }
    jit_log("OK: RW=%p != RX=%p", region->rw_ptr, region->rx_ptr);

    // Test 3: Write to RW, read from RX to verify shared backing
    uint32_t pattern = 0xDEADBEEF;
    memcpy(region->rw_ptr, &pattern, sizeof(pattern));
    uint32_t readback = 0;
    memcpy(&readback, region->rx_ptr, sizeof(readback));

    if (readback != pattern) {
        jit_log("FAIL: Write 0x%x to RW, read 0x%x from RX", pattern, readback);
        jit_region_destroy(region);
        return false;
    }
    jit_log("OK: Dual-map coherent (wrote 0x%x, read 0x%x)", pattern, readback);

    // Test 4: Check RX page has execute permission via vm_region
    vm_address_t addr = (vm_address_t)region->rx_ptr;
    vm_size_t region_size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object_name = MACH_PORT_NULL;

    kern_return_t kr = vm_region_64(
        mach_task_self(), &addr, &region_size,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
        &info_count, &object_name
    );

    if (kr == KERN_SUCCESS && (info.protection & VM_PROT_EXECUTE)) {
        jit_log("OK: RX page has execute permission");
    } else {
        jit_log("WARN: RX page may lack execute permission (prot=0x%x)", info.protection);
    }

    jit_region_destroy(region);
    jit_log("=== Mapping test passed ===");
    return true;
}

// Check page protection via vm_region
static void jit_check_page_protection(void *addr, const char *label) {
    vm_address_t query_addr = (vm_address_t)addr;
    vm_size_t region_size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object_name = MACH_PORT_NULL;

    kern_return_t kr = vm_region_64(
        mach_task_self(), &query_addr, &region_size,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
        &info_count, &object_name
    );

    if (kr == KERN_SUCCESS) {
        jit_log("%s at %p: prot=0x%x (R%s%s), max_prot=0x%x, size=%zu",
                label, addr,
                info.protection,
                (info.protection & VM_PROT_WRITE) ? "W" : "-",
                (info.protection & VM_PROT_EXECUTE) ? "X" : "-",
                info.max_protection,
                (size_t)region_size);
    } else {
        jit_log("%s at %p: vm_region failed (kr=%d)", label, addr, kr);
    }
}

int64_t jit_test_execute(void) {
    jit_log("=== JIT Execution Test ===");

    // Check CS_DEBUGGED first
    if (!jit_check_debugged()) {
        jit_log("FAIL: CS_DEBUGGED not set. Attach debugger first.");
        return -2;
    }

    // ARM64 machine code for: int64_t test_func(void) { return 42; }
    uint32_t code[] = {
        0xD2800540,  // mov x0, #42
        0xD65F03C0,  // ret
    };

    // Strategy 1: Dual-mapped region, write FIRST then prepare
    // (TXM may authorize page content at preparation time)
    jit_log("--- Strategy 1: Dual-map, write-then-prepare ---");
    {
        JITRegion *region = jit_region_create(JIT_PAGE_SIZE);
        if (!region) {
            jit_log("FAIL: Could not create JIT region");
            return -1;
        }

        // Write code FIRST (before prepare)
        jit_log("Writing ARM64 code (%zu bytes) to RW view BEFORE prepare", sizeof(code));
        void *exec_ptr = jit_region_write(region, 0, code, sizeof(code));
        if (!exec_ptr) {
            jit_log("FAIL: Could not write code to JIT region");
            jit_region_destroy(region);
            return -1;
        }

        jit_check_page_protection(region->rx_ptr, "RX page BEFORE prepare");

        // NOW ask debugger to prepare (authorize) the pages
        jit_log("Requesting debugger to prepare RX region at %p (%zu bytes)...",
                region->rx_ptr, region->size);
        void *prepared = jit26_prepare_region(region->rx_ptr, region->size);
        jit_log("prepare_region returned: %p", prepared);

        jit_check_page_protection(region->rx_ptr, "RX page AFTER prepare");

        jit_log("Executing from RX view at %p...", exec_ptr);

        typedef int64_t (*jit_func_t)(void);
        jit_func_t func = (jit_func_t)exec_ptr;
        int64_t result = func();

        jit_log("Result: %lld (expected 42)", result);

        if (result == -3) {
            jit_log("Strategy 1: FAULT LOOP detected — TXM rejected self-mapped RX pages");
            jit_region_destroy(region);
        } else if (result == 42) {
            jit_log("SUCCESS: Strategy 1 works! JIT is functional.");

            // Run additional tests
            uint32_t add_code[] = {
                0x8B010000,  // add x0, x0, x1
                0xD65F03C0,  // ret
            };
            void *add_ptr = jit_region_write(region, sizeof(code), add_code, sizeof(add_code));
            if (add_ptr) {
                // Re-prepare after writing new code
                jit26_prepare_region(region->rx_ptr, region->size);
                typedef int64_t (*add_func_t)(int64_t, int64_t);
                int64_t add_result = ((add_func_t)add_ptr)(100, 200);
                jit_log("add(100, 200) = %lld (expected 300)", add_result);
            }

            jit_region_destroy(region);
            jit_log("=== JIT tests passed (strategy 1) ===");
            return 42;
        } else {
            jit_log("Strategy 1 failed with result: %lld", result);
            jit_region_destroy(region);
        }
    }

    // If strategy 1 fault-looped, try strategy 2 automatically
    jit_log("Strategy 1 did not succeed, trying strategy 2...");
    return jit_test_execute_strategy2();
}

int64_t jit_test_execute_strategy2(void) {
    jit_log("--- Strategy 2: Debugger-allocated RX + vm_remap RW (MeloNX approach) ---");

    if (!jit_check_debugged()) {
        jit_log("FAIL: CS_DEBUGGED not set. Attach debugger first.");
        return -2;
    }

    uint32_t code[] = {
        0xD2800540,  // mov x0, #42
        0xD65F03C0,  // ret
    };

    size_t size = JIT_PAGE_SIZE;
    mach_port_t task = mach_task_self();

    // Step 1: Let StikDebug allocate RX pages via _M command (x0=0)
    jit_log("Requesting debugger to allocate %zu bytes of RX memory (x0=0)...", size);
    void *rx_ptr = jit26_prepare_region(NULL, size);
    jit_log("Debugger allocated RX at: %p", rx_ptr);

    if (!rx_ptr) {
        jit_log("FAIL: Debugger allocation returned NULL");
        return -1;
    }

    jit_check_page_protection(rx_ptr, "Debugger-allocated RX page");

    // Step 2: Use vm_remap to create a second view of the same pages (MeloNX approach)
    vm_address_t rw_addr = 0;
    vm_prot_t cur_prot = 0;
    vm_prot_t max_prot = 0;

    kern_return_t kr = vm_remap(
        task,
        &rw_addr,
        size,
        0,                              // mask
        VM_FLAGS_ANYWHERE,
        task,
        (vm_address_t)rx_ptr,           // source = debugger-allocated RX pages
        FALSE,                          // copy = false (share the pages)
        &cur_prot,
        &max_prot,
        VM_INHERIT_NONE
    );

    if (kr != KERN_SUCCESS) {
        jit_log("FAIL: vm_remap failed: %s (kr=%d)", mach_error_string(kr), kr);
        return -1;
    }

    jit_log("vm_remap succeeded: RW at %p (cur_prot=0x%x, max_prot=0x%x)",
            (void *)rw_addr, cur_prot, max_prot);

    // Step 3: Set the remapped view to RW (MeloNX does this)
    kr = vm_protect(task, rw_addr, size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        jit_log("FAIL: vm_protect(RW) failed: %s (kr=%d)", mach_error_string(kr), kr);
        vm_deallocate(task, rw_addr, size);
        return -1;
    }

    jit_log("Set remapped view to RW");
    jit_check_page_protection((void *)rw_addr, "Remapped RW view");
    jit_check_page_protection(rx_ptr, "Original RX view after remap");

    // Step 4: Write code to RW view
    jit_log("Writing ARM64 code (%zu bytes) to RW view at %p", sizeof(code), (void *)rw_addr);
    memcpy((void *)rw_addr, code, sizeof(code));
    sys_icache_invalidate(rx_ptr, sizeof(code));

    // Verify coherence: read from RX should show what we wrote to RW
    uint32_t readback = *(uint32_t *)rx_ptr;
    jit_log("Coherence check: wrote 0x%x to RW, read 0x%x from RX %s",
            code[0], readback, readback == code[0] ? "(OK)" : "(MISMATCH!)");

    // Step 5: Execute from debugger-allocated RX
    jit_log("Executing from debugger RX at %p...", rx_ptr);
    typedef int64_t (*jit_func_t)(void);
    int64_t result = ((jit_func_t)rx_ptr)();
    jit_log("Result: %lld (expected 42)", result);

    if (result == 42) {
        jit_log("SUCCESS: Strategy 2 (debugger alloc + vm_remap) works!");

        // Additional test: add function
        uint32_t add_code[] = {
            0x8B010000,  // add x0, x0, x1
            0xD65F03C0,  // ret
        };
        memcpy((void *)(rw_addr + sizeof(code)), add_code, sizeof(add_code));
        sys_icache_invalidate((char *)rx_ptr + sizeof(code), sizeof(add_code));

        typedef int64_t (*add_func_t)(int64_t, int64_t);
        int64_t add_result = ((add_func_t)((char *)rx_ptr + sizeof(code)))(100, 200);
        jit_log("add(100, 200) = %lld (expected 300)", add_result);
    }

    // Cleanup
    vm_deallocate(task, rw_addr, size);

    if (result == 42) {
        jit_log("=== JIT tests passed (strategy 2) ===");
        return 42;
    }

    jit_log("=== All JIT strategies failed ===");
    return result;
}

/* ============================================================================
 * ml748 -- W^X A/B PROBE: does PROT_WRITE survive on FILE-BACKED image pages?
 *
 * Loading xtajit64.dll on the jailbroken research VM faults writing its .rdata
 * (off=0x207000, kr=2 PROTECTION_FAILURE, prot=1 max=7) during the ARM64EC
 * hybrid-metadata / TLS-index fixups. The identical build loads it fine on the
 * iPhone 13 Pro. The fault reproduced with the debugger FULLY ATTACHED, so
 * CS_DEBUGGED being live is not the variable.
 *
 * Two explanations remain and reasoning cannot separate them:
 *   (a) the VM is STRICTER than a real CS_DEBUGGED device, because its
 *       patchVmMapProtect() was removed and that patch is what forced W to
 *       stick on file-backed pages. Then hardware keeps W, the VM strips it,
 *       and this is a false failure local to the VM.
 *   (b) hardware masks a GENUINE portability bug some other way, both strip W,
 *       and the loader's reliance on holding RWX over image pages is wrong.
 *
 * Run the SAME binary in BOTH places and compare. This must live inside
 * Madeira, not in a standalone tool: the 13 Pro has no root, so an arbitrary
 * CLI cannot run there at all, and a platform binary over SSH already gave a
 * misleading answer once (it reported mprotect(RWX) succeeding while Madeira in
 * its real container saw the opposite). Same process, same sandbox, same
 * cs_wx_enabled map, or it proves nothing.
 *
 * THE READBACK IS THE ANSWER, NOT THE RETURN CODE. The failure signature is a
 * call that reports success while W is silently stripped, so every case reads
 * protection AND max_protection back via mach_vm_region.
 * ==========================================================================*/

static void wxprobe_readback(const char *tag, void *addr, int rc, int err) {
    mach_vm_address_t a = (mach_vm_address_t)(uintptr_t)addr;
    mach_vm_size_t sz = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    kern_return_t kr = mach_vm_region(mach_task_self(), &a, &sz,
                                      VM_REGION_BASIC_INFO_64,
                                      (vm_region_info_t)&info, &cnt, &obj);
    if (kr != KERN_SUCCESS) {
        jit_log("[wx-probe] ml748 %-22s rc=%d errno=%d  region=UNREADABLE kr=%d",
                tag, rc, err, kr);
        return;
    }
    /* W_KEPT is the whole verdict: the call may have returned 0 and still lost W. */
    jit_log("[wx-probe] ml748 %-22s rc=%d errno=%-3d prot=%d max=%d  [R=%d W=%d X=%d]  W_KEPT=%s",
            tag, rc, err, info.protection, info.max_protection,
            !!(info.protection & VM_PROT_READ),
            !!(info.protection & VM_PROT_WRITE),
            !!(info.protection & VM_PROT_EXECUTE),
            (info.protection & VM_PROT_WRITE) ? "YES" : "NO");
}

void jit_wx_probe(void) {
    const size_t len = JIT_PAGE_SIZE * 4;

    jit_log("[wx-probe] ml748 BEGIN  CS_DEBUGGED=%d pagesize=%d",
            (int)jit_check_debugged(), (int)JIT_PAGE_SIZE);

    /* A file-backed PRIVATE mapping is the shape that actually fails: PE images
     * are mapped from the container, not allocated anonymously. Map our own
     * executable -- guaranteed present and readable in both environments. */
    const char *self = "/proc/self/exe";
    int fd = open(self, O_RDONLY);
    if (fd < 0) {
        /* No procfs on iOS; any readable file in the bundle serves the purpose. */
        extern int _NSGetExecutablePath(char *, uint32_t *);
        char path[4096]; uint32_t psz = sizeof(path);
        if (_NSGetExecutablePath(path, &psz) == 0)
            fd = open(path, O_RDONLY);
    }
    if (fd < 0) {
        jit_log("[wx-probe] ml748 ABORT: no file to map (errno=%d)", errno);
        return;
    }

    /* --- Cases 1-3: FILE-BACKED. This is the shape that faults. --- */
    for (int c = 1; c <= 3; c++) {
        void *p = mmap(NULL, len, PROT_READ, MAP_PRIVATE | MAP_FILE, fd, 0);
        if (p == MAP_FAILED) {
            jit_log("[wx-probe] ml748 case%d mmap FAILED errno=%d", c, errno);
            continue;
        }
        int rc, err;
        if (c == 1) {
            rc = mprotect(p, len, PROT_READ | PROT_WRITE); err = errno;
            wxprobe_readback("1 file mprotect RW", p, rc, err);
        } else if (c == 2) {
            /* Exactly what the loader does today. */
            rc = mprotect(p, len, PROT_READ | PROT_WRITE | PROT_EXEC); err = errno;
            wxprobe_readback("2 file mprotect RWX", p, rc, err);
        } else {
            /* VM_PROT_COPY forces a private writable copy of a file-backed page
             * instead of asking to write through the shared mapping -- the
             * mechanism the RW-window fix would rely on, and the one that should
             * remain legal under an ENFORCING W^X. */
            kern_return_t kr = mach_vm_protect(mach_task_self(),
                                               (mach_vm_address_t)(uintptr_t)p, len, FALSE,
                                               VM_PROT_COPY | VM_PROT_READ | VM_PROT_WRITE);
            wxprobe_readback("3 file vm_protect COPY", p, (int)kr, 0);
        }
        munmap(p, len);
    }
    close(fd);

    /* --- Case 4: ANONYMOUS control. If anon keeps W|X and file-backed does not,
     * the constraint is file backing, not W^X in general. --- */
    void *a = mmap(NULL, len, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON, -1, 0);
    if (a != MAP_FAILED) {
        int rc = mprotect(a, len, PROT_READ | PROT_WRITE | PROT_EXEC);
        wxprobe_readback("4 anon mprotect RWX", a, rc, errno);
        munmap(a, len);
    } else {
        jit_log("[wx-probe] ml748 case4 anon mmap FAILED errno=%d", errno);
    }

    jit_log("[wx-probe] ml748 END");
}


/* ml1040: CLAIM THE LOW GAP AT IMAGE LOAD.
 *
 * On the iPhone 18 Pro everything that must live low -- the 0x140000000 window
 * for a non-relocatable main image, and the RX JIT pool, which the debugger
 * places first-fit with no address hint -- competes for one gap of roughly
 * 1.4GB between the app image and the malloc zones. By the time the user taps
 * launch, our own process has allocated into that gap, differently every time:
 *
 *   launch A:  505MB | window | 628MB | 261MB            -> 608MB pool
 *   launch B:  476MB | window | 604MB | 286MB            -> 592MB pool
 *   launch C:  463MB | window | 349MB | 181MB | 329MB    -> 448MB pool, and the
 *              image head alone filled it (397MB) before the game started:
 *              "[jit-pool] EXHAUSTED ... FAILING the load" x4, shell32 then ran
 *              from its un-pooled address (AV EXEC) and the process died.
 *
 * In launch C a 31MB runtime allocation had landed at 0x15dd00000, in the
 * middle of the hole the pool needs. We cannot stop the runtime allocating, but
 * we can get there first: a constructor runs before main, before SwiftUI, Metal
 * or the log store exist. Hold the window, then hold the largest contiguous run
 * directly above it. Both are PROT_NONE reservations and cost no memory.
 * StikJITHelper releases the pool placeholder immediately before asking the
 * debugger for RX, and plugs any lower hole that would win first-fit. */
#include <mach/mach.h>
unsigned long madeira_early_window_base, madeira_early_window_size;
unsigned long madeira_early_pool_base, madeira_early_pool_size;
unsigned long madeira_early_intruder_base, madeira_early_intruder_size;   /* ml1135 */
unsigned madeira_early_intruder_tag, madeira_early_intruder_prot;

__attribute__((constructor(101), used)) static void madeira_early_va_claim(void)
{
    const vm_address_t win = 0x140000000ul, winsz = 0x8000000ul;       /* 128MB, see ml1037 */
    vm_address_t a = win;
    vm_size_t sz;

    if (vm_allocate(mach_task_self(), &a, winsz, VM_FLAGS_FIXED) == KERN_SUCCESS && a == win) {
        vm_protect(mach_task_self(), a, winsz, 0, VM_PROT_NONE);
        madeira_early_window_base = win; madeira_early_window_size = winsz;
    }
    /* Largest no-overwrite run starting at the window's end, 16MB granularity. */
    for (sz = 1024ul << 20; sz >= (256ul << 20); sz -= (16ul << 20)) {
        a = win + winsz;
        if (vm_allocate(mach_task_self(), &a, sz, VM_FLAGS_FIXED) == KERN_SUCCESS && a == win + winsz) {
            vm_protect(mach_task_self(), a, sz, 0, VM_PROT_NONE);
            madeira_early_pool_base = a; madeira_early_pool_size = sz;
            break;
        }
    }
    /* ml1135: NAME what blocked it. ph-rdr90 got no placeholder because a ~31MB
     * mapping already sat at ~0x157d00000 before this constructor ran, leaving
     * 253MB above the window; the pool fell back to a 432MB hole below it and FEX
     * rolled its code cache over 52 times (a ~1 s freeze each). Record the first
     * mapped region above the window so the log can say what it is. */
    if (!madeira_early_pool_size) {
        vm_address_t ra = win + winsz;
        vm_size_t rs = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &ra, &rs, &depth, (vm_region_recurse_info_t)&info, &cnt) == KERN_SUCCESS
            && ra < 0x190000000ul) {
            madeira_early_intruder_base = ra; madeira_early_intruder_size = rs;
            madeira_early_intruder_tag = info.user_tag; madeira_early_intruder_prot = (unsigned)info.protection;
        }
    }
}

/* ml1249: METAL API VALIDATION ON DEMAND.
 *
 * `metal-validation = 1` in Documents/madeira.cfg turns on Metal's own debug
 * layer for this launch, reporting instead of aborting, and routes NSLog to
 * stderr so the reports land in the Madeira log. It has to be in the
 * environment before the first MTLDevice exists, and the app makes one for its
 * CAMetalLayer long before madeira.cfg is otherwise read -- hence a
 * constructor. Expensive: diagnostic runs only. */
__attribute__((constructor(102), used)) static void madeira_metal_validation_opt_in(void)
{
    const char *home = getenv("HOME");
    char path[1024], line[256];
    FILE *f;
    int on = 0;

    if (!home) return;
    snprintf(path, sizeof(path), "%s/Documents/madeira.cfg", home);
    if (!(f = fopen(path, "r"))) return;
    while (fgets(line, sizeof(line), f)) {
        char *p = line, *k, *v;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#') continue;
        if (strncmp(p, "metal-validation", 16) != 0) continue;
        k = p + 16;
        while (*k == ' ' || *k == '\t') k++;
        if (*k != '=') continue;
        v = k + 1;
        while (*v == ' ' || *v == '\t') v++;
        on = (*v == '1');          /* last line wins, like the rest of the file */
    }
    fclose(f);
    if (!on) return;
    setenv("MTL_DEBUG_LAYER", "1", 1);
    setenv("MTL_DEBUG_LAYER_ERROR_MODE", "nslog", 1);
    setenv("MTL_DEBUG_LAYER_WARNING_MODE", "nslog", 1);
    setenv("CFLOG_FORCE_STDERR", "1", 1);
}
