#!/usr/bin/env python3
"""Exercise NtAllocateVirtualMemory's actual allocation/retry tail on the host.

The VM backend is simulated: fixed requests may fail while arbitrary placement
would succeed. The public contract must not turn that failure into relocation.
This does not test Mach mappings or the rest of NtAllocateVirtualMemory; run
tests/x64/fixed-reserve.c in Madeira for end-to-end API coverage.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "build/ntdll-unix/virtual_ios.c").read_text()
start = source.index("            if (!ios_steered)\n")
end = source.index("        if (is_jumbo) ios_jumbo_census", start)
tail = source[start:end]

prefix = r'''
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdarg.h>
typedef uint32_t NTSTATUS;
typedef uint32_t ULONG;
typedef uint64_t ULONG64;
typedef uintptr_t ULONG_PTR;
typedef size_t SIZE_T;
#define MEM_COMMIT 0x1000
#define MEM_RESERVE 0x2000
#define STATUS_SUCCESS 0
#define STATUS_NO_MEMORY 0xc0000017u
#define STATUS_CONFLICTING_ADDRESSES 0xc0000018u
#define IOS_SOFT_MAX 16
static struct { uintptr_t UniqueThread; } cid;
static struct { typeof(cid) ClientId; } teb;
static typeof(teb) *NtCurrentTeb(void) { return &teb; }
static int quiet(int fd, const char *fmt, ...) { return 0; }
#define dprintf quiet
static uintptr_t original;
static NTSTATUS backend_status;
static unsigned calls;
static NTSTATUS allocate_virtual_memory(void **ret, SIZE_T *size, ULONG type,
                                       ULONG protect, ULONG_PTR lo, ULONG_PTR hi,
                                       ULONG_PTR align, ULONG_PTR attrs)
{
    calls++;
    if (*ret) return (uintptr_t)*ret == original ? backend_status : STATUS_NO_MEMORY;
    *ret = (void *)(uintptr_t)0x570000000ull;
    return 0;
}
/* Dependencies of the historical redirect path: no special pools available. */
static uintptr_t ios_furniture_ceiling, ios_steer_slot;
static int ios_sc_layout_mode, ios_cage_holdback_live, ios_soft_n;
static struct { uint64_t base, size, committed, commits, collisions; int cage; } ios_soft[IOS_SOFT_MAX];
static int compatibility_enabled = 1, helper_process;
static int ios_sc_cef_enabled(void) { return compatibility_enabled; }
static int ios_sc_current_is_helper(void) { return helper_process; }
static int ios_sc2_route(void *h, SIZE_T s, ULONG t, ULONG p, void **r, SIZE_T *z, NTSTATUS *st) { return 0; }
static NTSTATUS ios_sc_glued_pools(void **p, SIZE_T *s, ULONG t, ULONG f) { return STATUS_NO_MEMORY; }
static uintptr_t ios_jumbo_holdback_take(SIZE_T size) { return 0; }
static NTSTATUS ios_cage_grant(ULONG t, ULONG p, SIZE_T a, void **r, SIZE_T *s, const char *rev) { return STATUS_NO_MEMORY; }
static int ios_soft_slot_taken(uint64_t slot) { return 0; }
static void ios_va_gap_probe(const char *s) {}
static void ios_window_inventory(const char *s, uintptr_t l, uintptr_t h) {}
static void ios_slot_probe(const char *s) {}
static void ios_bigres_report(const char *s) {}
static uintptr_t ios_usable_va_floor;
static void ios_oversize_commit_failed(const void *addr, SIZE_T size, NTSTATUS status) {}
static int ios_jumbo_aligned_enabled(void) { return 1; }   /* ml2020's aligned walk, on as by default */
static NTSTATUS run(void **ret, SIZE_T *size_ptr, ULONG type, ULONG protect)
{
    NTSTATUS st = STATUS_NO_MEMORY;
    int ios_steered = 0, hint_was_set = *ret != NULL;
    void *jumbo_hint = *ret;
    SIZE_T jumbo_size = *size_ptr;
    ULONG_PTR limit = 0;
    if (1) {
'''
suffix = r'''
    return st;
}
int main(void)
{
    static const struct { uintptr_t base; size_t size; ULONG type; ULONG protect; } cases[] = {
        {0x80000000ull, 0x10000, MEM_RESERVE, 4},
        {0x80000000ull, 0x40000000ull, MEM_RESERVE, 4},
        {0x200000000ull, 0x100000000ull, MEM_RESERVE, 1},
        {0x400000000ull, 0x200000000ull, MEM_RESERVE, 1},
        {0x7bffff0000ull, 0x400010000ull, MEM_RESERVE, 1},
        {0x80000000ull, 0x40000000ull, MEM_RESERVE | MEM_COMMIT, 4},
        {0x80000000ull, 0x20000, MEM_COMMIT, 4},
    };
    unsigned failures = 0, checks = 0;
    /* Strict behavior even with the default-on compatibility switch; a helper
     * with that switch disabled is also an ordinary fixed-address caller. */
    for (unsigned mode = 0; mode < 3; mode++) {
    compatibility_enabled = mode == 0;
    helper_process = mode == 2;
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++)
        for (unsigned j = 0; j < 3; j++) {
            void *p = (void *)cases[i].base;
            size_t size = cases[i].size;
            original = cases[i].base;
            backend_status = j == 0 ? 0 : j == 1 ? STATUS_CONFLICTING_ADDRESSES : STATUS_NO_MEMORY;
            calls = 0; ios_soft_n = 0;
            NTSTATUS got = run(&p, &size, cases[i].type, cases[i].protect);
            checks++;
            if (got != backend_status || (uintptr_t)p != original || size != cases[i].size || calls != 1 || ios_soft_n) {
                fprintf(stderr, "FAIL case=%u status=%08x want=%08x result=%p calls=%u soft=%d\n",
                        i, got, backend_status, p, calls, ios_soft_n);
                failures++;
            }
        }
    }
    /* Keep the existing enabled helper fallback reachable. Its boot-held pool
     * ownership depends on this route; do not retire it in this scoped fix. */
    compatibility_enabled = 1; helper_process = 1;
    void *p = (void *)(uintptr_t)0x80000000ull;
    size_t helper_size = 0x40000000ull;
    original = (uintptr_t)p; backend_status = STATUS_CONFLICTING_ADDRESSES;
    calls = 0; ios_soft_n = 0;
    checks++;
    if (run(&p, &helper_size, MEM_RESERVE, 4) || (uintptr_t)p != 0x570000000ull || calls <= 1) {
        fputs("FAIL: enabled compatibility helper lost its fallback\n", stderr);
        failures++;
    }
    helper_process = 0;
    p = NULL;
    size_t size = 0x10000;
    original = 0; calls = 0; backend_status = 0;
    checks++;
    if (run(&p, &size, MEM_RESERVE, 4) || (uintptr_t)p != 0x570000000ull || calls != 1) failures++;
    printf("%s: %u allocation contract cases (%u failed)\n", failures ? "FAIL" : "PASS", checks, failures);
    return failures != 0;
}
'''
with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / "fixed-reserve.c"
    exe = Path(tmp) / "fixed-reserve"
    src.write_text(prefix + tail + suffix)
    subprocess.run([os.environ.get("CC", "cc"), "-std=gnu11", "-Werror=implicit-function-declaration",
                    str(src), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
