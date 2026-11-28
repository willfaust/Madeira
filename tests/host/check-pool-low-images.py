#!/usr/bin/env python3
"""Exercise the production image overflow allocators and shared C cursor.

Checks opt-in behavior, normal-pool preference, owner bookkeeping, executable
page guards, WoW64 exclusion (including reclaimed C ranges), failure atomicity,
retired-code reuse, fail-closed thread scans, and concurrent image/code allocations.
Mach queries use synthetic pages and thread states;
this is an allocator test, not a device rendering test.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def function(signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


helpers = ''.join(function(signature) for signature in (
    'static size_t ios_pool_hole_head_place(',
    'static size_t ios_pool_holes_head_place(',
    'static int ios_pool_skip_pieces(',
    'static int ios_pool_low_take(',
    'static int ios_pool_best_fit(',
    'static int ios_pool_keep_big(',
    'static int ios_pool_free_put(',
    'static size_t ios_pool_alloc_range_ex(',
    'static size_t ios_pool_alloc_range_tagged(',
    'static size_t ios_pool_low_image_range(',
    'static int ios_pool_ledger_holds(',
    'static int ios_tail_carve_scan(',
    'static int ios_tail_carve_occupied(',
    'static int ios_pool_recycle_range_ready(',
    'static int ios_pool_recycle_code_range(',
    'static size_t ios_pool_take_freed_for_tail(',
))
image_copy = source[source.index('size_t image_alloc = (image_size + page_size - 1)'):]
image_copy = image_copy[:image_copy.index('/* Copy ENTIRE PE image')]
assert image_copy.count('ios_pool_low_image_range( alloc_size )') == 1
first = 'offset = ios_pool_alloc_range_tagged(alloc_size, jit_pool_size - ios_jit_tail_reserved, image_tag);\n'
overflow = ('                if (offset == (size_t)-1) offset = ios_pool_low_image_range( alloc_size );\n'
            '                if (offset == (size_t)-1 && ios_pool_recycle_code_range( alloc_size ))\n'
            '                    offset = ios_pool_alloc_range_tagged(alloc_size, jit_pool_size - ios_jit_tail_reserved, image_tag);')
assert first in image_copy and overflow in image_copy and image_copy.index(first) < image_copy.index(overflow), \
    'the overflow runs only after normal image allocation fails'
# MADEIRA_POOL_TRIM's bookkeeping (was the range virgin?) sits between the two; it must not allocate.
between = image_copy[image_copy.index(first) + len(first):image_copy.index(overflow)]
assert 'ios_pool_alloc' not in between and 'ios_pool_low_image_range' not in between and 'ios_pool_recycle' not in between, \
    'nothing else allocates between the normal image allocation and its overflow'
allocation = first + overflow   # the sequence the harness below runs
assert source.count('ios_pool_low_image_range( alloc_size )') == 1, 'anonymous RWX must retain its old path'
assert source.count('ios_pool_recycle_code_range( alloc_size )') == 1, 'only the image failure path may transfer code ranges'
assert 'ios_tail_carves[i].freed_at = time( NULL );' in source
assert source.count('ios_tail_carves[ios_tail_carve_n].freed_at = 0;') == 4
assert 'size_t image_used = image_in_low ? ios_jit_low_reserved : offset + alloc_size;' in source

carve_start = source.index('#define IOS_TAIL_CARVE_MAX ')
carve_table = source[carve_start:source.index('\n\n', carve_start)]

fixture = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <unistd.h>
#define MB ((size_t)1 << 20)
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "failed line %d: %s\n", __LINE__, #c); exit(1); } } while (0)
#define IOS_POOL_BIG_MIN (64u * 1024 * 1024)
#define IOS_POOL_LEDGER_MAX 1024
#define IOS_POOL_FREE_MAX 256
#define IOS_POOL_REUSE_GRACE_SEC 3
struct ios_pool_free { size_t off, size; time_t freed_at; int advised; uint64_t tag; };
struct ios_pool_alloc { size_t off, size; void *peb; uint64_t tag; };
static struct ios_pool_free ios_pool_freelist[IOS_POOL_FREE_MAX];
static struct ios_pool_alloc ios_pool_ledger[IOS_POOL_LEDGER_MAX];
static int ios_pool_free_count, ios_pool_ledger_count, ios_pool_last_alloc_reused;
static __thread int ios_pool_last_same_image;
static size_t jit_pool_offset, ios_jit_hole_off_eff, ios_jit_hole_end_eff;
static size_t ios_jit_hole2_off, ios_jit_hole2_end;   /* pool-mid: no second hole here */
static size_t ios_pool_big_off, ios_pool_big_size, ios_jit_pool_size_global;
static int ios_pool_big_taken, wow, poisoned;
static time_t ios_pool_big_freed_at;
static pthread_mutex_t ios_pool_lock = PTHREAD_MUTEX_INITIALIZER;
static void *ios_jit_rx_base_global = (void *)(uintptr_t)0x148000000ULL;
static void *ios_jit_rw_base_global = (void *)(uintptr_t)0x791dc00000ULL;
static uintptr_t ios_jit_low_rx_global = 0x12a400000ULL;
static uintptr_t ios_jit_low_rw_global = 0x7900000000ULL;
static size_t ios_jit_low_size_global, ios_jit_tail_reserved;
static volatile size_t ios_jit_low_reserved;
static struct { uintptr_t user_va, user_va_end, jit_rw_alias; } ios_jit_anon_aliases[16];
static int ios_jit_anon_alias_count;
static _Thread_local uintptr_t owner = 1;
static void *ios_jit_current_peb(void) { return (void *)owner; }
static uintptr_t ios_wow_base(void) { return wow; }
static void ios_mono_alias_retire(uintptr_t va) { (void)va; }
static int ios_pool_range_execable(size_t off, size_t size, unsigned *cur, unsigned *max)
{ (void)off; (void)size; if (cur) *cur = 5; if (max) *max = poisoned ? 3 : 7; return !poisoned; }
/* MADEIRA_POOL_TRIM is off here: no cold-page bitmap to clear. */
static void ios_pool_cold_clear(size_t off, size_t size) { (void)off; (void)size; }
static int ios_pool_range_clean(size_t off, size_t size)
{ return ios_pool_range_execable(off, size, NULL, NULL); }
typedef int (*ios_pool_clean_fn)(size_t, size_t);
static unsigned ios_pool_check_range_exec(size_t off, size_t size, int reused)
{ (void)off; (void)size; (void)reused; return poisoned; }
static int ios_pool_live_overlap(uintptr_t start, size_t size, size_t *off_out, void **peb_out)
{
    size_t off = start - (uintptr_t)ios_jit_rw_base_global;
    for (int i = 0; i < ios_pool_ledger_count; i++)
        if (ios_pool_ledger[i].off < off + size && ios_pool_ledger[i].off + ios_pool_ledger[i].size > off)
        { *off_out = ios_pool_ledger[i].off; *peb_out = ios_pool_ledger[i].peb; return 1; }
    return 0;
}
typedef int (*ios_pool_region_fn)(uint64_t *, uint64_t *, unsigned *);
static int ios_pool_mach_region(uint64_t *addr, uint64_t *size, unsigned *prot)
{ (void)addr; (void)size; (void)prot; return -1; }
static int ios_pool_execable_runs(uint64_t rx, size_t off, size_t size, ios_pool_region_fn fn,
                                 size_t *ro, size_t *rs, int max)
{ (void)rx; (void)off; (void)size; (void)fn; (void)ro; (void)rs; (void)max; return 0; }
''' + carve_table + r'''
static unsigned ios_tail_carve_n;
static pthread_mutex_t ios_tail_carve_lock = PTHREAD_MUTEX_INITIALIZER;
typedef unsigned mach_port_t, mach_msg_type_number_t, thread_act_t;
typedef thread_act_t *thread_act_array_t;
typedef uintptr_t mach_vm_address_t;
typedef size_t mach_vm_size_t;
typedef int kern_return_t;
typedef void *thread_state_t;
typedef void *vm_region_info_t;
typedef struct { uintptr_t pc; } arm_thread_state64_t;
typedef struct { unsigned protection, max_protection; } vm_region_basic_info_data_64_t;
#define ARM_THREAD_STATE64 1
#define ARM_THREAD_STATE64_COUNT 1
#define KERN_SUCCESS 0
#define MACH_PORT_NULL 0
#define VM_REGION_BASIC_INFO_COUNT_64 2
#define VM_REGION_BASIC_INFO_64 1
#define VM_PROT_READ 1
#define VM_PROT_EXECUTE 4
#define arm_thread_state64_get_pc(st) ((st).pc)
static int task_query_fail, state_query_fail;
static int region_query_fail, region_gap, region_empty, region_nonexec;
static uintptr_t scanned_pc;
static unsigned ports_released, arrays_released;
static mach_port_t mach_task_self(void) { return 0; }
static mach_port_t mach_thread_self(void) { return 1; }
static int task_threads(mach_port_t task, thread_act_array_t *out, mach_msg_type_number_t *count)
{
    (void)task;
    if (task_query_fail) return -1;
    *out = malloc(3 * sizeof **out); CHECK(*out);
    (*out)[0] = 1; (*out)[1] = 2; (*out)[2] = 3; *count = 3;
    return KERN_SUCCESS;
}
static int thread_get_state(thread_act_t thread, int flavor, thread_state_t state, mach_msg_type_number_t *count)
{
    (void)thread; (void)flavor; (void)count;
    if (state_query_fail) return -1;
    ((arm_thread_state64_t *)state)->pc = scanned_pc;
    return KERN_SUCCESS;
}
static int mach_port_deallocate(mach_port_t task, mach_port_t port)
{ (void)task; (void)port; __sync_add_and_fetch(&ports_released, 1); return 0; }
static int mach_vm_deallocate(mach_port_t task, mach_vm_address_t address, mach_vm_size_t size)
{ (void)task; (void)size; free((void *)address); __sync_add_and_fetch(&arrays_released, 1); return 0; }
static int mach_vm_region(mach_port_t task, mach_vm_address_t *address, mach_vm_size_t *size,
                          int flavor, vm_region_info_t raw, mach_msg_type_number_t *count, mach_port_t *object)
{
    (void)task; (void)flavor; (void)count; *object = MACH_PORT_NULL;
    if (region_query_fail) return -1;
    if (region_gap) *address += 0x4000; else *address = ios_jit_low_rx_global;
    *size = region_empty ? 0 : ios_jit_low_size_global;
    vm_region_basic_info_data_64_t *info = raw;
    info->protection = region_nonexec ? 0 : 5;
    info->max_protection = poisoned ? 3 : 7;
    return KERN_SUCCESS;
}
''' + helpers + r'''
static size_t image(size_t alloc_size)
{
    size_t jit_pool_size = ios_jit_pool_size_global, offset;
''' + 'uint64_t image_tag = 0;\n' + allocation + r'''
    return offset;
}

static void reset(void)
{
    ios_jit_pool_size_global = 896 * MB;
    jit_pool_offset = ios_jit_pool_size_global;
    ios_jit_low_size_global = 348 * MB;
    ios_jit_low_reserved = 336 * MB + 0x18000;
    ios_pool_free_count = ios_pool_ledger_count = ios_jit_anon_alias_count = 0;
    ios_pool_big_size = ios_jit_hole_off_eff = ios_jit_hole_end_eff = ios_jit_tail_reserved = 0;
    wow = poisoned = 0;
    ios_tail_carve_n = 0;
    task_query_fail = state_query_fail = 0; scanned_pc = 0;
    region_query_fail = region_gap = region_empty = region_nonexec = 0;
    owner = 1;
}

static void no_allocation(size_t request)
{
    size_t head = jit_pool_offset, used = ios_jit_low_reserved;
    int entries = ios_pool_ledger_count;
    CHECK(image(request) == (size_t)-1);
    CHECK(jit_pool_offset == head && ios_jit_low_reserved == used);
    CHECK(ios_pool_ledger_count == entries);
}

static void retired(size_t low_offset, size_t size, int age)
{
    unsigned i = ios_tail_carve_n++;
    CHECK(i < IOS_TAIL_CARVE_MAX);
    ios_tail_carves[i].off = ios_jit_low_rx_global + low_offset - (uintptr_t)ios_jit_rx_base_global;
    ios_tail_carves[i].size = size;
    ios_tail_carves[i].free = 1;
    ios_tail_carves[i].freed_at = time(NULL) - age;
}

static int code_won;
static size_t image_won;
static void *competing_code(void *arg)
{
    (void)arg;
    pthread_mutex_lock(&ios_tail_carve_lock);
    /* The code allocator owns a free entry by clearing its free flag under
     * this same lock. No write to the buffer may precede that claim. */
    if (ios_tail_carve_n && ios_tail_carves[0].free)
    { ios_tail_carves[0].free = 0; code_won = 1; }
    pthread_mutex_unlock(&ios_tail_carve_lock);
    return NULL;
}
static void *competing_image(void *arg)
{
    (void)arg;
    image_won = image(8 * MB);
    return NULL;
}
static size_t recycled_code_won;
static void *competing_recycled_code(void *arg)
{
    (void)arg;
    recycled_code_won = ios_pool_take_freed_for_tail(32 * MB);
    return NULL;
}
static void *competing_whole_image(void *arg)
{
    (void)arg;
    image_won = image(32 * MB);
    return NULL;
}

static void check_recycled(void)
{
    const size_t request = 0x18c0000; /* A 24.75 MB late DLL copy. */
    setenv("MADEIRA_POOL_LOW_IMAGES", "1", 1);
    unsetenv("MADEIRA_POOL_RECYCLE_IMAGES");
    reset(); retired(272 * MB, 32 * MB, 30);
    no_allocation(request); CHECK(ios_tail_carve_n == 1);
    setenv("MADEIRA_POOL_RECYCLE_IMAGES", "0", 1); no_allocation(request);
    setenv("MADEIRA_POOL_RECYCLE_IMAGES", "true", 1); no_allocation(request);
    setenv("MADEIRA_POOL_RECYCLE_IMAGES", "1", 1);
    size_t expected = ios_tail_carves[0].off;
    size_t head = jit_pool_offset, low_used = ios_jit_low_reserved;
    ios_jit_anon_aliases[0].user_va = 0x7200000000ULL;
    ios_jit_anon_aliases[0].user_va_end = 0x7202000000ULL;
    ios_jit_anon_aliases[0].jit_rw_alias = (uintptr_t)ios_jit_rw_base_global + expected;
    ios_jit_anon_alias_count = 1;
    CHECK(image(request) == expected);
    CHECK(!ios_tail_carve_n && ios_pool_free_count == 1);
    CHECK(ios_pool_freelist[0].off == expected + request);
    CHECK(ios_pool_freelist[0].size == 32 * MB - request);
    CHECK(!ios_jit_anon_aliases[0].user_va);
    CHECK(ios_pool_ledger_holds(expected, request, (void *)1));
    CHECK(!ios_pool_ledger_holds(expected, request, (void *)2));
    CHECK(jit_pool_offset == head && ios_jit_low_reserved == low_used && !ios_jit_tail_reserved);

    /* A process reclaim can merge the image with its unused remainder;
     * the existing head-to-code reuse path can take it back without a ledger. */
    ios_pool_ledger_count = 0;
    CHECK(ios_pool_free_put(ios_pool_freelist, &ios_pool_free_count, IOS_POOL_FREE_MAX,
                            expected, request, time(NULL) - 4, ios_pool_range_clean));
    CHECK(ios_pool_take_freed_for_tail(32 * MB) == expected);
    CHECK(!ios_pool_ledger_count && !ios_pool_free_count);

    reset(); retired(272 * MB, 32 * MB, 30);
    jit_pool_offset -= 32 * MB;
    CHECK(image(request) < ios_jit_pool_size_global);
    CHECK(ios_tail_carve_n == 1); /* Normal image space wins. */
    reset(); retired(272 * MB, 32 * MB, 30);
    CHECK(image(0x378000) != (size_t)-1 && ios_tail_carve_n == 1); /* Virgin C wins. */
    reset(); retired(272 * MB, 32 * MB, 0);
    CHECK(!ios_pool_recycle_code_range(request) && ios_tail_carve_n == 1);
    reset(); retired(272 * MB, 32 * MB, -30);
    no_allocation(request); CHECK(ios_tail_carve_n == 1);
    reset(); retired(272 * MB, 32 * MB, 3);
    CHECK(ios_pool_recycle_code_range(request) && !ios_tail_carve_n); /* Grace boundary. */
    reset(); retired(272 * MB, 32 * MB, 30);
    ios_tail_carves[0].freed_at = 0;
    no_allocation(request);
    reset(); retired(272 * MB, 32 * MB, 30);
    ios_tail_carves[0].free = 0;
    no_allocation(request);
    reset(); retired(272 * MB, 32 * MB, 30); wow = 1;
    no_allocation(request);
    reset(); retired(272 * MB, 32 * MB, 30); poisoned = 1;
    no_allocation(request); CHECK(ios_tail_carve_n == 1);
    reset(); retired(272 * MB, 32 * MB, 30); region_query_fail = 1;
    no_allocation(request); CHECK(ios_tail_carve_n == 1);
    reset(); retired(272 * MB, 32 * MB, 30); region_gap = 1;
    no_allocation(request); CHECK(ios_tail_carve_n == 1);
    reset(); retired(272 * MB, 32 * MB, 30); region_empty = 1;
    no_allocation(request); CHECK(ios_tail_carve_n == 1);
    reset(); retired(272 * MB, 32 * MB, 30); region_nonexec = 1;
    no_allocation(request); CHECK(ios_tail_carve_n == 1);
    reset(); retired(272 * MB, 32 * MB, 30); task_query_fail = 1;
    unsigned ports = ports_released;
    no_allocation(request); CHECK(ios_tail_carve_n == 1 && ports_released == ports + 1);
    CHECK(!ios_tail_carve_occupied((void *)ios_jit_low_rx_global, MB)); /* Legacy free policy. */
    reset(); retired(272 * MB, 32 * MB, 30); state_query_fail = 1;
    ports = ports_released; unsigned arrays = arrays_released;
    no_allocation(request); CHECK(ios_tail_carve_n == 1);
    CHECK(ports_released == ports + 4 && arrays_released == arrays + 1);
    CHECK(!ios_tail_carve_occupied((void *)ios_jit_low_rx_global, MB));
    reset(); retired(272 * MB, 32 * MB, 30);
    scanned_pc = ios_jit_low_rx_global + 273 * MB;
    no_allocation(request);
    reset(); retired(272 * MB, 32 * MB, 30);
    ios_tail_carves[0].off = 16 * MB; /* Outside C. */
    no_allocation(request);
    reset(); retired(272 * MB, 32 * MB, 30);
    ios_tail_carves[0].off += 1;
    no_allocation(request);
    reset(); retired(340 * MB, 32 * MB, 30); /* Extends beyond C. */
    no_allocation(request);
    reset(); retired(0, 128 * MB, 30); /* Keep large code-cache buffers intact. */
    no_allocation(request);
    reset(); retired(0, 64 * MB, 30);
    CHECK(!ios_pool_recycle_code_range(65 * MB));
    CHECK(!ios_pool_recycle_code_range(0) && !ios_pool_recycle_code_range(1));
    reset(); retired(272 * MB, 32 * MB, 30); ios_pool_free_count = IOS_POOL_FREE_MAX;
    CHECK(!ios_pool_recycle_code_range(request) && ios_tail_carve_n == 1);
    reset(); retired(272 * MB, 32 * MB, 30); ios_pool_ledger_count = IOS_POOL_LEDGER_MAX;
    CHECK(!ios_pool_recycle_code_range(request) && ios_tail_carve_n == 1);
    reset(); retired(272 * MB, 32 * MB, 30);
    ios_pool_ledger[0] = (struct ios_pool_alloc){ios_tail_carves[0].off + MB, MB, (void *)3, 0};
    ios_pool_ledger_count = 1;
    CHECK(!ios_pool_recycle_code_range(request) && ios_tail_carve_n == 1);

    reset(); retired(208 * MB, 64 * MB, 30); retired(272 * MB, 32 * MB, 30);
    expected = ios_tail_carves[1].off;
    CHECK(image(request) == expected); /* Smallest safe buffer, larger one untouched. */
    CHECK(ios_tail_carve_n == 1 && ios_tail_carves[0].size == 64 * MB);

    for (int i = 0; i < 100; i++)
    {
        reset(); ios_jit_low_reserved = ios_jit_low_size_global;
        retired(272 * MB, 32 * MB, 30); code_won = 0; image_won = (size_t)-1;
        pthread_t code, copier;
        CHECK(!pthread_create(&code, NULL, competing_code, NULL));
        CHECK(!pthread_create(&copier, NULL, competing_image, NULL));
        CHECK(!pthread_join(code, NULL) && !pthread_join(copier, NULL));
        CHECK(code_won != (image_won != (size_t)-1));
        CHECK(ios_pool_ledger_count == !code_won);
        CHECK(ios_tail_carve_n == (unsigned)code_won);
    }
    /* Once a retired carve is on the common freelist, exercise the real
     * head-to-code helper racing with the actual image allocation chain. */
    for (int i = 0; i < 100; i++)
    {
        reset(); ios_jit_low_reserved = ios_jit_low_size_global;
        retired(272 * MB, 32 * MB, 30);
        CHECK(ios_pool_recycle_code_range(32 * MB));
        recycled_code_won = image_won = (size_t)-1;
        pthread_t code, copier;
        if (i & 1)
        {
            CHECK(!pthread_create(&copier, NULL, competing_whole_image, NULL));
            CHECK(!pthread_create(&code, NULL, competing_recycled_code, NULL));
        }
        else
        {
            CHECK(!pthread_create(&code, NULL, competing_recycled_code, NULL));
            CHECK(!pthread_create(&copier, NULL, competing_whole_image, NULL));
        }
        CHECK(!pthread_join(code, NULL) && !pthread_join(copier, NULL));
        CHECK((recycled_code_won != (size_t)-1) != (image_won != (size_t)-1));
        CHECK(ios_pool_ledger_count == (image_won != (size_t)-1));
        CHECK(!ios_pool_free_count && !ios_tail_carve_n);
    }
    unsetenv("MADEIRA_POOL_RECYCLE_IMAGES");
    puts("retired-code image reuse: capacity, grace, PC/poison guards, owners, aliases, return-to-code and races passed");
}

static size_t allocations[768];
static size_t allocation_count;
static pthread_mutex_t result_lock = PTHREAD_MUTEX_INITIALIZER;
static void remember(size_t rx)
{
    pthread_mutex_lock(&result_lock);
    CHECK(allocation_count < sizeof allocations / sizeof allocations[0]);
    allocations[allocation_count++] = rx;
    pthread_mutex_unlock(&result_lock);
}
static void *allocate_images(void *arg)
{
    owner = (uintptr_t)arg;
    for (int i = 0; i < 128; i++)
    {
        size_t off = ios_pool_low_image_range(0x4000);
        if (off == (size_t)-1) continue;
        remember((uintptr_t)ios_jit_rx_base_global + off);
    }
    return NULL;
}
static void *allocate_code(void *arg)
{
    (void)arg;
    for (int i = 0; i < 256; i++)
    {
        size_t off;
        if (!ios_pool_low_take(&ios_jit_low_reserved, ios_jit_low_size_global, 0x4000, &off)) continue;
        remember(ios_jit_low_rx_global + off);
    }
    return NULL;
}

int main(void)
{
    check_recycled();
    reset();
    unsetenv("MADEIRA_POOL_LOW_IMAGES");
    no_allocation(0x378000);
    setenv("MADEIRA_POOL_LOW_IMAGES", "0", 1);
    no_allocation(0x378000);
    setenv("MADEIRA_POOL_LOW_IMAGES", "true", 1);
    no_allocation(0x378000);
    setenv("MADEIRA_POOL_LOW_IMAGES", "1", 1);
    jit_pool_offset -= 4 * MB;
    size_t used = ios_jit_low_reserved;
    CHECK(image(0x378000) < ios_jit_pool_size_global);
    CHECK(ios_jit_low_reserved == used && ios_pool_ledger_count == 1);

    reset();
    const size_t sizes[] = {0x378000, 0x13c000, 0xb4000, 0xe4000, 0x94000};
    for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; i++)
    {
        size_t previous = ios_jit_low_reserved;
        size_t off = image(sizes[i]);
        CHECK(off != (size_t)-1);
        uintptr_t rx = (uintptr_t)ios_jit_rx_base_global + off;
        CHECK(rx == ios_jit_low_rx_global + previous);
        CHECK((uintptr_t)ios_jit_rw_base_global + off == ios_jit_low_rw_global + previous);
        CHECK(ios_pool_ledger_holds(off + 0x4000, sizes[i] - 0x4000, (void *)1));
        CHECK(!ios_pool_ledger_holds(off, sizes[i], (void *)2));
        CHECK(!ios_pool_ledger_holds(off, sizes[i] + 0x4000, (void *)1));
        CHECK(jit_pool_offset == ios_jit_pool_size_global && !ios_jit_tail_reserved);
    }
    CHECK(ios_jit_low_size_global - ios_jit_low_reserved == 0x508000);
    no_allocation(2 * MB);  /* Preserve the 4 MB code-buffer reserve. */
    no_allocation(17 * MB);
    no_allocation(1);
    CHECK(ios_pool_low_image_range(0) == (size_t)-1);

    reset(); wow = 1; no_allocation(0x94000);
    reset(); ios_jit_low_size_global = 0; no_allocation(0x94000);
    reset(); ios_pool_ledger_count = IOS_POOL_LEDGER_MAX; no_allocation(0x94000);
    reset(); poisoned = 1; no_allocation(0x94000);
    reset(); ios_jit_low_reserved = ios_jit_low_size_global + MB; no_allocation(0x94000);

    /* Reclaimed C ranges obey the existing grace and never enter WoW64,
     * even when the image-overflow switch has subsequently been disabled. */
    reset();
    size_t coff = (size_t)(ios_jit_low_rx_global - (uintptr_t)ios_jit_rx_base_global);
    ios_pool_freelist[0] = (struct ios_pool_free){coff, MB, time(NULL), 1, 0};
    ios_pool_free_count = 1;
    CHECK(ios_pool_best_fit(ios_pool_freelist, 1, 0x4000,
                           ios_pool_freelist[0].freed_at, (size_t)-1, 0) == -1);
    CHECK(ios_pool_best_fit(ios_pool_freelist, 1, 0x4000,
                           ios_pool_freelist[0].freed_at + 3, (size_t)-1, 0) == 0);
    wow = 1;
    CHECK(ios_pool_alloc_range_ex(0x4000, 0, (size_t)-1, 0, 0) == (size_t)-1);
    CHECK(ios_pool_free_count == 1 && !ios_pool_ledger_count);
    ios_pool_freelist[0].freed_at -= 4;
    CHECK(ios_pool_alloc_range_ex(0x4000, 0, (size_t)-1, 0, 0) == (size_t)-1);
    wow = 0;
    CHECK(ios_pool_alloc_range_ex(0x4000, 0, (size_t)-1, 0, 0) == coff);
    CHECK(ios_pool_ledger[0].peb == (void *)1);

    reset();
    ios_pool_freelist[0] = (struct ios_pool_free){coff, MB, 0, 1, 0};
    ios_pool_freelist[1] = (struct ios_pool_free){MB, MB, 0, 1, 0};
    ios_pool_free_count = 2; wow = 1;
    CHECK(ios_pool_alloc_range_ex(0x4000, 0, (size_t)-1, 0, 0) == MB);

    reset();
    ios_jit_low_reserved = 0; ios_jit_low_size_global = 12 * MB;
    allocation_count = 0;
    pthread_t workers[5];
    for (uintptr_t i = 0; i < 4; i++)
        CHECK(!pthread_create(&workers[i], NULL, allocate_images, (void *)(i + 1)));
    CHECK(!pthread_create(&workers[4], NULL, allocate_code, NULL));
    for (int i = 0; i < 5; i++) CHECK(!pthread_join(workers[i], NULL));
    CHECK(allocation_count >= 512 && allocation_count <= 768);
    CHECK(ios_jit_low_reserved == allocation_count * 0x4000);
    CHECK(ios_jit_low_reserved <= ios_jit_low_size_global);
    for (size_t i = 0; i < allocation_count; i++)
    {
        CHECK(allocations[i] >= ios_jit_low_rx_global);
        CHECK(allocations[i] + 0x4000 <= ios_jit_low_rx_global + ios_jit_low_size_global);
        for (size_t j = 0; j < i; j++) CHECK(allocations[i] != allocations[j]);
    }
    for (int i = 0; i < ios_pool_ledger_count; i++)
    {
        uintptr_t rx = (uintptr_t)ios_jit_rx_base_global + ios_pool_ledger[i].off;
        CHECK(rx + ios_pool_ledger[i].size <= ios_jit_low_rx_global + 8 * MB);
        CHECK((uintptr_t)ios_pool_ledger[i].peb >= 1 && (uintptr_t)ios_pool_ledger[i].peb <= 4);
    }
    puts("small-image overflow: opt-in, capacity, owners, WoW64 and concurrent code/image guards passed");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'check.c').write_text(fixture)
    command = [os.environ.get('CC', 'cc'), '-std=c11', '-D_POSIX_C_SOURCE=200809L',
               '-Wall', '-Wextra', '-Werror', '-pthread', str(path / 'check.c'), '-o', str(path / 'check')]
    if os.environ.get('SANITIZE') == '1':
        command[1:1] = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-g']
    subprocess.run(command, check=True)
    result = subprocess.run([str(path / 'check')], capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise SystemExit(result.stderr)
    print(result.stdout.strip())
