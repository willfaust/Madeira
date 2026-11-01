#!/usr/bin/env python3
"""Exercise the production I/O pointer probes against real protected mappings."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root/'build/ntdll-unix/virtual_ios.c').read_text()
start = source.index('static BOOL ios_io_trace_read(')
end = source.index('\nvoid ios_trace_io_scope(', start)
helpers = source[start:end]
assert 'mach_vm_read_overwrite' in helpers
assert not any(word in helpers for word in ['mmap(', 'mprotect(', 'virtual_map(', 'virtual_alloc('])

code = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "io_status_abi.h"
typedef int BOOL;
typedef unsigned char BYTE;
typedef uintptr_t ULONG_PTR;
typedef size_t SIZE_T;
#define TRUE 1
#define FALSE 0
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_vm.h>
static int os_safe_copy(const void *from, void *to, size_t size, uint64_t *got)
{
    mach_vm_size_t copied = 0;
    int result = mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)from,
            size, (mach_vm_address_t)to, &copied);
    *got = copied; return result;
}
#else
#include <setjmp.h>
typedef uint64_t mach_vm_address_t, mach_vm_size_t;
typedef unsigned int mach_port_t, mach_msg_type_number_t, natural_t;
typedef int kern_return_t;
typedef struct { int protection, is_submap; } vm_region_submap_short_info_data_64_t;
typedef void *vm_region_recurse_info_t;
#define KERN_SUCCESS 0
#define VM_PROT_WRITE 2
#define VM_REGION_SUBMAP_SHORT_INFO_COUNT_64 1
static mach_port_t mach_task_self(void) { return 1; }
/* The managed Linux executor disables process_vm_readv (ENOSYS). This
 * test-only signal boundary models Mach's safe-copy failure using real page
 * protections; the production helper never directly reads these addresses. */
static sigjmp_buf copy_fault;
static void copy_signal(int signal) { (void)signal; siglongjmp(copy_fault, 1); }
__attribute__((no_sanitize("address", "undefined")))
static int os_safe_copy(const void *from, void *to, size_t size, uint64_t *got)
{
    struct sigaction action = {0}, old_segv, old_bus;
    action.sa_handler = copy_signal; sigemptyset(&action.sa_mask);
    assert(!sigaction(SIGSEGV, &action, &old_segv)); assert(!sigaction(SIGBUS, &action, &old_bus));
    *got = 0;
    if (sigsetjmp(copy_fault, 1))
    {
        assert(!sigaction(SIGSEGV, &old_segv, NULL)); assert(!sigaction(SIGBUS, &old_bus, NULL)); return 1;
    }
    for (size_t i = 0; i < size; i++) ((volatile unsigned char *)to)[i] = ((const volatile unsigned char *)from)[i];
    *got = size;
    assert(!sigaction(SIGSEGV, &old_segv, NULL)); assert(!sigaction(SIGBUS, &old_bus, NULL)); return KERN_SUCCESS;
}

#endif
#define IOS_VIEW_QUARANTINED 4
#define VPROT_READ 1
#define VPROT_WRITE 2
#define VPROT_WRITECOPY 8
#define VPROT_GUARD 16
#define VPROT_COMMITTED 32
#define IOS_WOW_WINDOW_SIZE ((ULONG_PTR)0x100000000ULL)
static const ULONG_PTR page_mask = 4095, page_size = 4096;
static pthread_mutex_t ios_wow_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t virtual_mutex = PTHREAD_MUTEX_INITIALIZER;
static int process_a, process_b;
static void *current_peb = &process_a;
static void *ios_jit_current_peb(void) { return current_peb; }
struct ios_wow_window { void *peb; ULONG_PTR base; unsigned dead, leaked, generation; };
static struct ios_wow_window ios_wow_windows[4];
static unsigned ios_wow_window_count;
struct file_view { void *base; size_t size; unsigned ios_flags; BYTE protection[16]; };
static struct file_view views[8];
static unsigned view_count, enters, leaves, queries, copies;
static ULONG_PTR last_copy_source;
struct native_region { ULONG_PTR base; size_t size; int prot, submap; };
static struct native_region regions[8];
static unsigned region_count;
static struct file_view *find_view(const void *address, size_t size)
{
    ULONG_PTR value = (ULONG_PTR)address;
    if (size > UINTPTR_MAX - value) return NULL;
    for (unsigned i = 0; i < view_count; i++)
        if (value >= (ULONG_PTR)views[i].base && value - (ULONG_PTR)views[i].base < views[i].size &&
            size <= views[i].size - (value - (ULONG_PTR)views[i].base)) return &views[i];
    return NULL;
}
static struct file_view *find_view_range(const void *address, size_t size)
{
    ULONG_PTR value = (ULONG_PTR)address, best = UINTPTR_MAX;
    struct file_view *found = NULL;
    for (unsigned i = 0; i < view_count; i++)
        if ((ULONG_PTR)views[i].base < value + size &&
            views[i].size > value - ((ULONG_PTR)views[i].base < value ? (ULONG_PTR)views[i].base : value) &&
            (ULONG_PTR)views[i].base < best) { best = (ULONG_PTR)views[i].base; found = &views[i]; }
    return found;
}
static BYTE get_page_vprot(const void *address)
{
    struct file_view *view = find_view(address, 1);
    assert(view); size_t page = ((ULONG_PTR)address - (ULONG_PTR)view->base) / 4096;
    assert(page < 16); return view->protection[page];
}
static void server_enter_uninterrupted_section(pthread_mutex_t *lock, sigset_t *set)
{ enters++; sigemptyset(set); assert(!pthread_mutex_lock(lock)); }
static void server_leave_uninterrupted_section(pthread_mutex_t *lock, sigset_t *set)
{ (void)set; leaves++; assert(!pthread_mutex_unlock(lock)); }
static kern_return_t fixture_copy(mach_port_t task, mach_vm_address_t from,
        mach_vm_size_t size, mach_vm_address_t to, mach_vm_size_t *got)
{
    (void)task; uint64_t copied = 0; copies++; last_copy_source = from;
    int result = os_safe_copy((void *)(uintptr_t)from, (void *)(uintptr_t)to, size, &copied);
    *got = copied; return result;
}
static kern_return_t fixture_region(mach_port_t task, mach_vm_address_t *address,
        mach_vm_size_t *size, natural_t *depth, vm_region_recurse_info_t output,
        mach_msg_type_number_t *count)
{
    (void)task; (void)depth; (void)count; queries++;
    ULONG_PTR best = UINTPTR_MAX; struct native_region *found = NULL;
    for (unsigned i = 0; i < region_count; i++)
    {
        struct native_region *r = &regions[i];
        if (*address >= r->base && *address - r->base < r->size) { found = r; break; }
        if (r->base > *address && r->base < best) { best = r->base; found = r; }
    }
    if (!found) return 1;
    vm_region_submap_short_info_data_64_t *info = (void *)output;
    *address = found->base; *size = found->size;
    info->protection = found->prot; info->is_submap = found->submap; return KERN_SUCCESS;
}
#define mach_vm_read_overwrite fixture_copy
#define mach_vm_region_recurse fixture_region
''' + helpers + r'''
static void reset_metadata(unsigned char *base)
{
    memset(views, 0, sizeof(views)); memset(regions, 0, sizeof(regions));
    memset(ios_wow_windows, 0, sizeof(ios_wow_windows));
    view_count = ios_wow_window_count = enters = leaves = queries = 0;
    current_peb = &process_a; region_count = 1;
    regions[0] = (struct native_region){(ULONG_PTR)base, 16384, VM_PROT_WRITE, 0};
}
static void set_view(unsigned index, unsigned char *base, size_t size, BYTE protection)
{
    views[index].base = base; views[index].size = size;
    memset(views[index].protection, protection, sizeof(views[index].protection));
    if (view_count <= index) view_count = index + 1;
}
static void writable(const void *address, size_t size, int expected)
{
    unsigned before = copies;
    assert(ios_io_buffer_writable(address, size) == expected);
    assert(copies == before && enters == leaves);
    assert(!pthread_mutex_trylock(&ios_wow_mutex)); pthread_mutex_unlock(&ios_wow_mutex);
    assert(!pthread_mutex_trylock(&virtual_mutex)); pthread_mutex_unlock(&virtual_mutex);
}
int main(void)
{
    const BYTE rw = VPROT_COMMITTED | VPROT_WRITE, ro = VPROT_COMMITTED | VPROT_READ;
    size_t allocation = 3 * 16384;
    unsigned char *mapping = mmap(NULL, allocation, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0);
    assert(mapping != MAP_FAILED);
    unsigned char *base = (void *)(((ULONG_PTR)mapping + 16383) & ~(ULONG_PTR)16383);
    assert(base >= mapping && base + 16384 <= mapping + allocation);
    memset(base, 0xa5, 16384); reset_metadata(base);
    struct madeira_io_control input = {MADEIRA_IO_ABI_VERSION, MADEIRA_IO_ENTER_OPERATION(8),
        (void *)(base + 256), (void *)(base + 512), (void *)(base + 768)}, output = {0};
    memcpy(base + 128, &input, sizeof(input));
    assert(sizeof(input) == 32);
    assert(ios_io_read_control(base + 128, &output) && !memcmp(&input, &output, sizeof(input)));
    assert(!mprotect(base, 16384, PROT_READ)); regions[0].prot = 1;
    assert(ios_io_read_control(base + 128, &output)); // A control request is input-only.
    writable(base + 512, 8, FALSE); writable(base + 512, 16, FALSE);
    assert(!mprotect(base, 16384, PROT_NONE)); regions[0].prot = 0;
    assert(!ios_io_read_control(base + 128, &output));
    writable(base + 512, 8, FALSE);
    assert(!mprotect(base, 16384, PROT_READ|PROT_WRITE)); reset_metadata(base);
    assert(!mprotect(base + 16384, 16384, PROT_NONE));
    assert(!ios_io_read_control(base + 16384 - 16, &output)); // partial native control must reject
    writable(base + 16384 - 8, 16, FALSE);
    // The raw guest value remains invalid. Neither probe adds any window base.
    ios_wow_window_count = 1;
    ios_wow_windows[0] = (struct ios_wow_window){&process_a, 0x400000000ULL, 0, 0, 1};
    assert(!ios_io_read_control((void *)(uintptr_t)0x19efef30, &output));
    assert(last_copy_source == 0x19efef30);
    writable((void *)(uintptr_t)0x19efef30, 8, FALSE);
    writable((void *)(uintptr_t)0x419efef30ULL, 8, FALSE);
    writable(base + 512, 16, TRUE); // Native/FEX bootstrap I/O stays valid in a WoW64 process.
    // A pretranslated host pointer is accepted only inside its actual owner's VAD.
    ios_wow_windows[0].base = (ULONG_PTR)base & ~(IOS_WOW_WINDOW_SIZE - 1);
    set_view(0, base, 16384, rw);
    ULONG_PTR guest = (ULONG_PTR)(base + 768) - ios_wow_windows[0].base;
    assert(guest < IOS_WOW_WINDOW_SIZE && ios_wow_windows[0].base + guest == (ULONG_PTR)(base + 768));
    writable(base + 768, 8, TRUE); writable(base + 768, 16, TRUE);
    writable((void *)guest, 8, FALSE);
    // Foreign, unbound, retired or leaked reservations cannot become native buffers.
    ios_wow_windows[0].peb = &process_b; writable(base + 768, 8, FALSE);
    ios_wow_windows[0].peb = NULL; writable(base + 768, 16, FALSE);
    ios_wow_windows[0].peb = &process_a; ios_wow_windows[0].dead = 1; writable(base + 768, 8, FALSE);
    ios_wow_windows[0].dead = 0; ios_wow_windows[0].leaked = 1; writable(base + 768, 16, FALSE);
    ios_wow_windows[0].leaked = 0; ios_wow_windows[0].generation++;
    view_count = 0; writable(base + 768, 8, FALSE); set_view(0, base, 16384, rw);
    views[0].ios_flags = IOS_VIEW_QUARANTINED; writable(base + 768, 8, FALSE);
    views[0].ios_flags = 0;
    views[0].protection[0] = ro; writable(base + 768, 8, FALSE);
    views[0].protection[0] = VPROT_WRITE; writable(base + 768, 16, FALSE); // not committed
    views[0].protection[0] = rw | VPROT_GUARD; writable(base + 768, 8, FALSE);
    views[0].protection[0] = rw;
    // 8-byte guest IOSB fits; 16-byte native IOSB crosses a logical 4KB boundary
    // inside the same real 16KB physical mapping, whose Mach rights remain RW.
    views[0].protection[1] = ro;
    writable(base + 4096 - 8, 8, TRUE); writable(base + 4096 - 8, 16, FALSE);
    writable(base + 4096 - 4, 8, FALSE);
    // Native Wine buffers obey VAD boundaries too, not just the host-page rights.
    ios_wow_window_count = 0; view_count = 0;
    set_view(0, base, 4096, rw); set_view(1, base + 4096, 4096, ro);
    writable(base + 4096 - 8, 16, FALSE);
    views[1].protection[0] = rw; writable(base + 4096 - 8, 16, TRUE);
    // A native gap must stop at the next Wine VAD and apply its own protection.
    view_count = 0; set_view(0, base + 4096, 4096, ro);
    writable(base + 4096 - 8, 16, FALSE);
    views[0].protection[0] = rw; writable(base + 4096 - 8, 16, TRUE);
    // Check the whole range for foreign ownership, including a start outside B.
    ios_wow_window_count = 1;
    ios_wow_windows[0] = (struct ios_wow_window){&process_b, 0x400000000ULL, 0, 0, 4};
    unsigned before_query = queries;
    writable((void *)(uintptr_t)0x3fffffff8ULL, 16, FALSE);
    assert(queries == before_query); // Reject ownership before any Mach/native fallback.
    // Wine COW remains valid even though the real host mapping is read-only;
    // the rights check must not dirty it, fault it in or invoke a Mach copy.
    reset_metadata(base); set_view(0, base, 16384, VPROT_COMMITTED | VPROT_WRITECOPY);
    assert(!mprotect(base, 16384, PROT_READ)); regions[0].prot = 1;
    writable(base + 768, 8, TRUE); writable(base + 768, 16, TRUE);
    assert(base[0] == 0xa5 && base[8192] == 0xa5);
    assert(!mprotect(base, 16384, PROT_NONE)); regions[0].prot = 0;
    writable(base + 768, 16, TRUE); // No direct touch or write-probe.
    // Native buffers not represented by a Wine VAD require exact Mach coverage.
    reset_metadata(base); assert(!mprotect(base, 16384, PROT_READ|PROT_WRITE));
    writable(base + 768, 8, TRUE); writable(base + 768, 16, TRUE);
    regions[0].submap = 1; writable(base + 768, 8, FALSE); regions[0].submap = 0;
    regions[0].size = 4096;
    regions[1] = (struct native_region){(ULONG_PTR)base + 4096, 4096, VM_PROT_WRITE, 0}; region_count = 2;
    writable(base + 4096 - 8, 16, TRUE);
    regions[1].prot = 1; writable(base + 4096 - 8, 16, FALSE);
    regions[1].base += 4096; writable(base + 4096 - 8, 16, FALSE); // unmapped gap
    writable(NULL, 8, FALSE); writable(base, 0, FALSE);
    writable((void *)(UINTPTR_MAX - 7), 16, FALSE);
    unsigned before = copies;
    assert(!ios_io_read_control((void *)(UINTPTR_MAX - 7), &output) && copies == before);
    assert(!ios_io_read_control(NULL, &output) && copies == before);
    // An allocation that was really unmapped cannot be copied or accepted later.
    assert(!munmap(mapping, allocation)); region_count = view_count = 0;
    assert(!ios_io_read_control(base + 128, &output)); writable(base + 768, 16, FALSE);
    puts("PASS actual I/O pointer probes: safe control copy, raw versus host pointers, ownership/lifetime, 8/16-byte widths, 4KB VAD boundaries on a 16KB mapping, native gaps and untouched COW rights");
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-io-pointer-probe-') as directory:
    src, exe = Path(directory)/'check.c', Path(directory)/'check'
    src.write_text(code)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-pthread',
                    '-I'+str(root/'build/ntdll-unix'), str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
