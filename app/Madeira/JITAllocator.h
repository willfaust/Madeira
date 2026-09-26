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

/// ml962: is [addr, addr+size) still MAPPED, with at least `need_prot`
/// (VM_PROT_* bits; pass 0 to test mapped-ness only) on every region it spans?
/// A hole anywhere in the range answers false.
///
/// The JIT pool outlives a single Wine session (StikJITHelper caches it for the
/// process lifetime), so the second launch of an app run has to ask whether the
/// pool it is about to hand back still exists rather than assume it. Cheap:
/// mach_vm_region walks whole regions, so a healthy 512MB pool answers in one
/// or two iterations.
bool jit_range_is_mapped(void *addr, size_t size, int need_prot);

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

// ml1330: true while a debugger is attached now (P_TRACED), unlike the sticky
// CS_DEBUGGED flag. Only an attached debugger services BRK #0xf00d.
bool jit_debugger_attached(void);

// Install SIGTRAP handler so BRK instructions don't crash the app
// when no debugger is attached. Must be called before any jit26_* functions.
void jit_install_trap_handler(void);

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

/// WOW64_DESIGN.md §9.2 step 0: address-space probe. Call once at startup,
/// before any Wine/JIT allocation, right after EntitlementStatus is checked
/// (`entitlement_present` is EntitlementStatus.extendedVA). Read-only: walks
/// the task's free/mapped map and tries releasing 4GB-aligned reservations,
/// releasing each immediately. No behaviour change; logs via fprintf(stderr)
/// / the jit log callback under "[va-map]"/"[va-probe]" tags so it lands in
/// madeira-log.txt. Budgeted at < 50ms (a few thousand mach calls).
void mad_va_probe(bool entitlement_present);

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
extern unsigned long madeira_early_intruder_base, madeira_early_intruder_size;   /* ml1135: first mapping above the window when no placeholder fit */
extern unsigned madeira_early_intruder_tag, madeira_early_intruder_prot;
extern unsigned long madeira_early_pool_size;

#endif // JIT_ALLOCATOR_H
