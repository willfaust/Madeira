#ifndef JIT_ALLOCATOR_H
#define JIT_ALLOCATOR_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to a dual-mapped JIT region
typedef struct JITRegion JITRegion;

// Create a dual-mapped JIT region of the given size.
// Returns NULL on failure. Size is rounded up to page boundary.
// The region has two views of the same physical memory:
//   - RW view: for writing generated code
//   - RX view: for executing generated code
JITRegion *jit_region_create(size_t size);

// Destroy a JIT region and unmap both views.
void jit_region_destroy(JITRegion *region);

/// Mark an already-mapped range jetsam-exempt (VM_LEDGER_FLAG_NO_FOOTPRINT).
/// For the production pool, whose pages come from the debugger rather than
/// jit_region_create(). Logs phys_footprint either side; returns false and
/// changes nothing if the private ownership API refuses.
bool jit_make_region_no_footprint(void *addr, size_t size, const char *label);

// Get the RW (writable) pointer. Write generated code here.
void *jit_region_rw_ptr(JITRegion *region);

// Get the RX (executable) pointer. Execute code from here.
void *jit_region_rx_ptr(JITRegion *region);

// Get the total size of the region.
size_t jit_region_size(JITRegion *region);

// Write code to the region at the given offset.
// Handles cache invalidation automatically.
// Returns the RX pointer to the written code (for execution).
void *jit_region_write(JITRegion *region, size_t offset, const void *code, size_t code_size);

// Invalidate instruction cache for a range in the RX view.
void jit_region_invalidate(JITRegion *region, size_t offset, size_t size);

// Check if CS_DEBUGGED flag is set (JIT execution is allowed).
// Returns true if the debugger has attached and set the flag.
bool jit_check_debugged(void);

// Install SIGTRAP handler so BRK instructions don't crash the app
// when no debugger is attached. Must be called before any jit26_* functions.
void jit_install_trap_handler(void);

// Install the same SIGTRAP handler although CS_DEBUGGED is set. The flag stays
// set after a debugger detaches, so it does not say that anything will answer a
// BRK; with the handler armed an unanswered jit26_* request returns 0 instead of
// killing the app. A debugger that is attached still receives the BRK first.
void jit_arm_trap_fallback(void);

// The process's code-signing status flags (csops CS_OPS_STATUS), without logging.
// Returns false when the kernel does not report them.
bool jit_cs_status(uint32_t *flags);

// The user address map [min, max) from TASK_VM_INFO: max is 0xfc0000000 (63 GB)
// on a standard map and 0x8000000000 (512 GB) on an extended one. Returns false
// when the kernel does not report it.
bool jit_task_map_range(uint64_t *min_address, uint64_t *max_address);

// Memory this process may still allocate before the system's limit.
uint64_t jit_available_memory(void);

// iOS 26 BRK-based protocol: Ask attached debugger (StikDebug) to
// prepare a memory region for JIT execution.
// Returns the prepared address (may differ from input on allocation).
void *jit26_prepare_region(void *addr, size_t len);

// iOS 26 BRK-based protocol: Tell the debugger to detach.
void jit26_detach(void);

// Test if dual-mapped regions can be created and RX pages are viable,
// WITHOUT actually executing generated code (safe to call without JIT).
// Returns true if dual mapping works and RX pages have execute permission.
bool jit_test_mapping(void);

// Full JIT test: tries Strategy 1 (write-then-prepare) then Strategy 2 (debugger alloc).
// Returns 42 on success, -1 on failure, -2 if no debugger attached, -3 if fault loop.
int64_t jit_test_execute(void);

// Strategy 2 only: Let debugger allocate RX via _M, dual-map RW on top.
// Returns 42 on success, -1 on failure, -2 if no debugger, -3 if fault loop.
int64_t jit_test_execute_strategy2(void);

/// ml748: W^X A/B probe. Reports whether PROT_WRITE survives on FILE-BACKED
/// mappings, which is what the ARM64EC loader needs when it patches an image's
/// .rdata. Run the same build on the research VM and on hardware and compare:
/// if hardware keeps W and the VM strips it, the VM is stricter and the failure
/// is local to it; if both strip it, the loader's reliance on RWX over image
/// pages is a real portability bug. Call after JIT is enabled.
void jit_wx_probe(void);

// Log callback type
typedef void (*jit_log_callback_t)(const char *message);

// Set a log callback for JIT operations
void jit_set_log_callback(jit_log_callback_t callback);

#ifdef __cplusplus
}
#endif


/* ml1040: address space claimed by a constructor at image load, before the app's
 * own runtime allocations can fragment the scarce low gap. See JITAllocator.m. */
extern unsigned long madeira_early_window_base;   /* 0x140000000 if held, else 0 */
extern unsigned long madeira_early_window_size;
extern unsigned long madeira_early_pool_base;     /* placeholder directly above the window, else 0 */
extern unsigned long madeira_early_intruder_base, madeira_early_intruder_size;   /* ml1135: first mapping above the window (above the placeholder when one was taken) */
extern unsigned madeira_early_intruder_tag, madeira_early_intruder_prot;
extern unsigned long madeira_early_pool_size;

/* The same two facts, as functions. A C global `var` is shared mutable state
 * under Swift 6 strict concurrency and cannot be read at all from Swift; these
 * can. Both are written once by the constructor before main and are constant
 * thereafter, so no synchronisation is implied or needed. */
void madeira_early_pool_placeholder(unsigned long *base, unsigned long *size);
void madeira_early_pool_intruder(unsigned long *base, unsigned long *size, unsigned *tag);

#endif // JIT_ALLOCATOR_H
