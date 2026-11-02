#!/usr/bin/env python3
"""Compile the production WoW reservation paths against a non-replacing VM model.

Fault injection checks split guard/body reservations, cleanup and collisions;
the existing combined, borrowed-guard and placeholder paths remain covered.
This is a host contract check, not an iOS kernel or guest integration test.
"""
from pathlib import Path
import os
import subprocess
import tempfile


root = Path(__file__).resolve().parents[2]
source = (root / "build/ntdll-unix/virtual_ios.c").read_text()


def function(signature):
    start = source.index(signature)
    return source[start:source.index("\n}", start) + 2]


production = "\n\n".join(function(signature) for signature in (
    "static ULONG_PTR ios_wow_guard_size(",
    "static ULONG_PTR ios_wow_slot_reservation(",
    "static int ios_wow_band_ok(",
    "static void ios_va_describe_range(",
    "static int ios_wow_guard_neighbour_blocked(",
    "static int ios_wow_window_try_separate_guard(",
    "static int ios_wow_window_try(",
))

harness = r"""
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

typedef uintptr_t ULONG_PTR;
typedef uint64_t mach_vm_address_t, mach_vm_size_t;
typedef unsigned mach_msg_type_number_t;
typedef int mach_port_t;
typedef void *vm_region_info_t;
typedef struct { int protection, max_protection, shared; } vm_region_basic_info_data_64_t;
#define KERN_SUCCESS 0
#define VM_REGION_BASIC_INFO_64 1
#define VM_REGION_BASIC_INFO_COUNT_64 1
#define VM_PROT_NONE 0
#define MACH_PORT_NULL 0
#define IOS_WOW_WINDOW_SIZE ((ULONG_PTR)1 << 32)
#define IOS_WOW_CEF_POOLS_START ((ULONG_PTR)0x7400000000)
#define IOS_WOW_FEX_BAND_END ((ULONG_PTR)0x8000000000)
#define IOS_WOW_SPILL_TOP ((ULONG_PTR)0x7b00000000)
static int ios_wow_spill_walk;
static const ULONG_PTR host_page_size = 0x4000;
struct ios_wow_window { ULONG_PTR base; unsigned dead, leaked, guard_owned; };
struct ios_wow_placeholder { unsigned adopted, guard_owned; };
static struct ios_wow_window slot;
static struct ios_wow_placeholder placeholder;
static int have_slot, have_placeholder;
static ULONG_PTR base;
static char trace[64], logs[4096];
static size_t trace_len, log_len;
static int refuse_combined, refuse_guard, refuse_body, refuse_unmap;
static int reserved_count;
static ULONG_PTR reserved_size;
struct region { ULONG_PTR lo, size; int prot, owned; };
static struct region regions[8];
static unsigned region_count;

static void event(char name)
{
    assert(trace_len + 1 < sizeof(trace));
    trace[trace_len++] = name; trace[trace_len] = 0;
}

static void seed(ULONG_PTR lo, ULONG_PTR size, int prot, int owned)
{
    assert(region_count < sizeof(regions) / sizeof(regions[0]));
    regions[region_count++] = (struct region){ lo, size, prot, owned };
}

static void *anon_mmap_tryfixed(void *addr, size_t size, int prot, int flags)
{
    ULONG_PTR lo = (ULONG_PTR)addr;
    char name = size == IOS_WOW_WINDOW_SIZE + host_page_size ? 'C' :
                size == IOS_WOW_WINDOW_SIZE ? 'B' : 'G';
    assert(prot == PROT_NONE && flags == MAP_NORESERVE);
    assert(size == IOS_WOW_WINDOW_SIZE + host_page_size ||
           size == IOS_WOW_WINDOW_SIZE || size == host_page_size);
    assert(lo == base + (name == 'G' ? IOS_WOW_WINDOW_SIZE : 0));
    event(name);
    if ((name == 'C' && refuse_combined) || (name == 'G' && refuse_guard) ||
        (name == 'B' && refuse_body)) return MAP_FAILED;
    for (unsigned i = 0; i < region_count; ++i)
        if (lo < regions[i].lo + regions[i].size && regions[i].lo < lo + size)
            return MAP_FAILED;
    seed(lo, size, prot, 1);
    return addr;
}

static int test_unmap(void *addr, size_t size)
{
    event('U');
    assert((ULONG_PTR)addr == base + IOS_WOW_WINDOW_SIZE && size == host_page_size);
    for (unsigned i = 0; i < region_count; ++i)
        if (regions[i].lo == (ULONG_PTR)addr && regions[i].size == size)
        {
            assert(regions[i].owned && regions[i].prot == PROT_NONE);
            if (refuse_unmap) { errno = EINVAL; return -1; }
            regions[i] = regions[--region_count];
            return 0;
        }
    assert(!"unmapping a page the attempt does not own");
    return -1;
}
#define munmap test_unmap

static void mmap_add_reserved_area(void *addr, size_t size)
{
    event('R');
    assert((ULONG_PTR)addr == base &&
           (size == IOS_WOW_WINDOW_SIZE || size == IOS_WOW_WINDOW_SIZE + host_page_size));
    reserved_count++; reserved_size = size;
}

static int mach_task_self(void) { return 1; }
static int mach_vm_region(int task, mach_vm_address_t *addr, mach_vm_size_t *size,
                          int flavor, vm_region_info_t out,
                          mach_msg_type_number_t *count, mach_port_t *object)
{
    int found = -1;
    (void)task; (void)flavor; (void)count; (void)object;
    for (unsigned i = 0; i < region_count; ++i)
        if (regions[i].lo + regions[i].size > *addr &&
            (found < 0 || regions[i].lo < regions[found].lo)) found = (int)i;
    if (found < 0) return 1;
    *addr = regions[found].lo; *size = regions[found].size;
    *(vm_region_basic_info_data_64_t *)out =
        (vm_region_basic_info_data_64_t){ regions[found].prot, regions[found].prot, 0 };
    return KERN_SUCCESS;
}

static int test_dprintf(int fd, const char *fmt, ...)
{
    va_list args;
    (void)fd;
    va_start(args, fmt);
    int n = vsnprintf(logs + log_len, sizeof(logs) - log_len, fmt, args);
    va_end(args);
    assert(n >= 0 && (size_t)n < sizeof(logs) - log_len);
    log_len += (size_t)n;
    return n;
}
#define dprintf test_dprintf

static struct ios_wow_window *ios_wow_slot_at_base(ULONG_PTR addr)
{ assert(addr == base); return have_slot ? &slot : NULL; }
static struct ios_wow_placeholder *ios_wow_placeholder_find(ULONG_PTR addr)
{ assert(addr == base); return have_placeholder ? &placeholder : NULL; }
/* ml2020 MADEIRA_WOW_GUARD_INSIDE (default 1 in production): the guard is the window's own top
 * page. The cases below cover its =0 form (a guard page above the window) and then it on. */
static int guard_inside;
static int ios_wow_guard_inside(void) { return guard_inside; }
""" + production + r"""

static void reset(void)
{
    base = 0x7200000000;
    region_count = 0; trace_len = 0; log_len = 0;
    trace[0] = logs[0] = 0;
    refuse_combined = refuse_guard = refuse_body = refuse_unmap = 0;
    reserved_count = 0; reserved_size = 0;
    have_slot = have_placeholder = ios_wow_spill_walk = guard_inside = 0;
    memset(&slot, 0, sizeof(slot)); memset(&placeholder, 0, sizeof(placeholder));
}

int main(void)
{
    unsigned owned;
    reset();
    assert(ios_wow_window_try(base, &owned) && owned == 1);
    assert(!strcmp(trace, "CR") && region_count == 1 && reserved_count == 1);
    assert(reserved_size == IOS_WOW_WINDOW_SIZE + host_page_size);

    reset(); refuse_combined = 1;
    assert(ios_wow_window_try(base, &owned) && owned == 1);
    assert(!strcmp(trace, "CGBR") && region_count == 2 && reserved_count == 1);
    assert(regions[0].lo == base + IOS_WOW_WINDOW_SIZE && regions[0].size == host_page_size);
    assert(regions[1].lo == base && regions[1].size == IOS_WOW_WINDOW_SIZE);
    assert(reserved_size == IOS_WOW_WINDOW_SIZE + host_page_size);

    reset(); refuse_combined = refuse_body = 1;
    assert(!ios_wow_window_try(base, &owned) && owned == 0);
    assert(!strcmp(trace, "CGBU") && !region_count && !reserved_count);
    assert(strstr(logs, "window body after failed reservations") &&
           strstr(logs, "free to end of VA"));

    reset(); seed(base + IOS_WOW_WINDOW_SIZE / 2, host_page_size, PROT_READ, 0);
    assert(!ios_wow_window_try(base, &owned) && owned == 0);
    assert(!strcmp(trace, "CGBU") && region_count == 1 && !reserved_count);
    assert(!regions[0].owned && regions[0].prot == PROT_READ);
    assert(strstr(logs, "PARTIALLY OCCUPIED"));

    reset(); seed(base, 0x800000, PROT_READ | PROT_WRITE, 0);
    assert(!ios_wow_window_try(base, &owned) && owned == 0);
    assert(!strcmp(trace, "CGBU") && region_count == 1 && !reserved_count);
    assert(regions[0].lo == base && regions[0].size == 0x800000 && !regions[0].owned);
    assert(strstr(logs, "OCCUPIED"));

    reset(); seed(base + IOS_WOW_WINDOW_SIZE, host_page_size, PROT_NONE, 0);
    assert(ios_wow_window_try(base, &owned) && owned == 0);
    assert(!strcmp(trace, "CGBR") && region_count == 2 && reserved_count == 1);
    assert(!regions[0].owned && reserved_size == IOS_WOW_WINDOW_SIZE);

    reset(); seed(base + IOS_WOW_WINDOW_SIZE, host_page_size, PROT_READ, 0);
    assert(!ios_wow_window_try(base, &owned) && owned == 0);
    assert(!strcmp(trace, "CG") && region_count == 1 && !reserved_count);
    assert(regions[0].prot == PROT_READ && !regions[0].owned);

    reset(); seed(base + IOS_WOW_WINDOW_SIZE, host_page_size / 2, PROT_NONE, 0);
    assert(!ios_wow_window_try(base, &owned) && owned == 0);
    assert(!strcmp(trace, "CG") && region_count == 1 && !reserved_count);

    reset(); refuse_combined = refuse_guard = 1;
    assert(!ios_wow_window_try(base, &owned) && owned == 0);
    assert(!strcmp(trace, "CG") && !region_count && !reserved_count);

    reset(); seed(base + IOS_WOW_WINDOW_SIZE, host_page_size, PROT_NONE, 0);
    seed(base + 0x10000, host_page_size, PROT_READ, 0);
    assert(!ios_wow_window_try(base, &owned) && owned == 0);
    assert(!strcmp(trace, "CGB") && region_count == 2 && !reserved_count);
    assert(strstr(logs, "PARTIALLY OCCUPIED"));

    reset(); refuse_combined = refuse_body = refuse_unmap = 1;
    assert(!ios_wow_window_try(base, &owned) && owned == 0);
    assert(!strcmp(trace, "CGBU") && region_count == 1 && !reserved_count);
    assert(regions[0].owned && strstr(logs, "failed to release own guard page"));

    for (unsigned state = 0; state < 3; ++state)
    {
        reset(); have_slot = 1; slot.dead = state == 1; slot.leaked = state == 2;
        assert(!ios_wow_window_try(base, &owned) && !owned);
        assert(!trace_len && !region_count && !reserved_count);
    }
    for (unsigned guard_owned = 0; guard_owned < 2; ++guard_owned)
    {
        reset(); have_placeholder = 1; placeholder.guard_owned = guard_owned;
        assert(ios_wow_window_try(base, &owned) && owned == guard_owned && placeholder.adopted);
        assert(!trace_len && !region_count && !reserved_count);
        assert(!ios_wow_window_try(base, &owned) && !owned && !trace_len);
        slot.guard_owned = guard_owned;
        assert(ios_wow_slot_reservation(&slot) == IOS_WOW_WINDOW_SIZE +
               (guard_owned ? host_page_size : 0));
    }

    reset(); base = IOS_WOW_CEF_POOLS_START;
    assert(!ios_wow_window_try(base, &owned) && !owned && !trace_len);
    reset(); base = IOS_WOW_CEF_POOLS_START - IOS_WOW_WINDOW_SIZE;
    assert(!ios_wow_window_try(base, &owned) && !owned && !trace_len);
    seed(base + IOS_WOW_WINDOW_SIZE, host_page_size, PROT_NONE, 0);
    assert(ios_wow_window_try(base, &owned) && !owned && !strcmp(trace, "BR"));
    reset(); ios_wow_spill_walk = 1; base = IOS_WOW_SPILL_TOP - IOS_WOW_WINDOW_SIZE;
    assert(!ios_wow_window_try(base, &owned) && !owned && !trace_len);
    reset(); base = UINTPTR_MAX - IOS_WOW_WINDOW_SIZE;
    assert(!ios_wow_window_try(base, &owned) && !owned && !trace_len);
    assert(!ios_wow_window_try_separate_guard(base, UINTPTR_MAX) && !trace_len);

    /* guard inside: exactly 4 GB is reserved and no page above it; a taken top page refuses */
    reset(); guard_inside = 1;
    assert(ios_wow_window_try(base, &owned) && !owned && !strcmp(trace, "BR"));
    assert(region_count == 1 && reserved_count == 1 && reserved_size == IOS_WOW_WINDOW_SIZE);
    reset(); guard_inside = 1;
    seed(base + IOS_WOW_WINDOW_SIZE - host_page_size, host_page_size, PROT_NONE, 0);
    assert(!ios_wow_window_try(base, &owned) && !owned && !strcmp(trace, "B") && !reserved_count);
    reset(); guard_inside = 1; have_placeholder = 1; placeholder.guard_owned = 1;
    assert(ios_wow_window_try(base, &owned) && owned == 1 && placeholder.adopted && !trace_len);

    puts("PASS: combined/split/borrowed guards, collision cleanup, ownership, placeholders and band bounds; "
         "the guard inside the window (MADEIRA_WOW_GUARD_INSIDE)");
    return 0;
}
"""

with tempfile.TemporaryDirectory(prefix="madeira-wow-guard-") as tmp:
    c = Path(tmp) / "check.c"
    executable = Path(tmp) / "check"
    c.write_text(harness)
    command = [os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra", "-Werror",
               "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    # Linux PIE/ASan address placement can collide on this cloud host.
    if os.uname().sysname == "Linux":
        command.append("-no-pie")
    subprocess.run(command + [str(c), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
