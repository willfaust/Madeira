#!/usr/bin/env python3
"""Exercise production EC_CODE reuse and page-fit arithmetic; no Wine/game runs.

The C fixture compiles the real allocation prefix, including its best-fit loop,
NOP prefill, region-C bump and one-shot retry after a simulated lost race.
The Swift fixture compiles the actual sizing helper on macOS CI. Linux hosts
without Swift still run the C fixture and source contracts; --require-swift
turns absence of Swift into a failure.
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
swift = (root / 'app/Madeira/StikJITHelper.swift').read_text()


def function(source, signature, closing='\n}'):
    start = source.index(signature)
    return source[start:source.index(closing, start) + len(closing)] + '\n'


ec = native[native.index('size_t alloc_size = (*size_ptr + 0x3FFF) & ~0x3FFFUL;'):]
ec = ec[:ec.index('size_t reserve_offset, tail_added, tail_skipped = 0;')]
assert 'int low_ok = ios_jit_low_size_global && !ios_wow_base();' in ec
assert ec.count('goto retry_code_carve_reuse;') == 2
assert ec.count('ios_tail_carve_ready( &ios_tail_carves[') == 2, 'cap lift and reuse share one readiness rule'
assert 'if (kept_large_carve && !reuse_all_carves)' in ec
assert 'reuse_all_carves = 1;\n                low_fits = 0;' in ec
assert ec.count('(low_ok || !ios_tail_carve_in_low( ios_tail_carves[') == 2
helpers = ''.join(function(native, signature) for signature in (
    'static size_t ios_pool_hole_between(',
    'static size_t ios_pool_code_cap(',
    'int ios_jit_low_contains(',
    'static int ios_pool_low_take(',
    'static int ios_tail_carve_in_low(',
    'static int ios_pool_preserve_code_carve(',
    'static int ios_pool_preserve_big_carve(',
    'static int ios_tail_carve_ready(',
))
carve_start = native.index('#define IOS_TAIL_CARVE_MAX ')
carve_table = native[carve_start:native.index('\n\n', carve_start)]

c_fixture = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
#define MB ((size_t)1 << 20)
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "failed line %d: %s\n", __LINE__, #c); exit(1); } } while (0)
#define STATUS_SUCCESS 0
#define STATUS_NO_MEMORY -1
#define FALLBACK_TAIL 2
#define IOS_POOL_LOW_CARVE_MAX 0x8000000u
#define IOS_POOL_REUSE_GRACE_SEC 3
static void *ios_jit_rx_base_global, *ios_jit_rw_base_global;
static uintptr_t ios_jit_low_rx_global, ios_jit_low_rw_global;
static size_t ios_jit_low_size_global, ios_jit_pool_size_global;
static volatile size_t ios_jit_low_reserved;
static size_t jit_pool_offset, ios_jit_tail_reserved, ios_pool_head_reserve;
static size_t ios_jit_hole_off_eff, ios_jit_hole_end_eff;
static size_t ios_jit_hole2_off, ios_jit_hole2_end;
static int ios_jit_low_full_logged, wow, lose_race;
static unsigned ios_tail_carve_n;
static pthread_mutex_t ios_tail_carve_lock = PTHREAD_MUTEX_INITIALIZER;
''' + carve_table + r'''
static uintptr_t ios_wow_base(void) { return wow; }
static void *ios_jit_current_peb(void) { return (void *)(uintptr_t)1; }
static int ios_tail_carve_scan(const void *base, size_t size, int strict)
{ (void)base; (void)size; (void)strict; return 0; }
''' + helpers + r'''
static int racing_low_take(volatile size_t *used, size_t total, size_t want, size_t *off)
{
    if (lose_race) {
        *used = total;
        if (lose_race == 2) ios_tail_carves[0].free = 0;
        lose_race = 0;
    }
    return ios_pool_low_take(used, total, want, off);
}
static int allocate(size_t *size_ptr, void **ret)
{
''' + ec.replace('ios_pool_low_take(', 'racing_low_take(') + r'''
    (void)kept_big_carve;  /* read by the production tail path after this prefix */
    return FALLBACK_TAIL;  /* The production tail path starts after this prefix. */
}
static const size_t used = 272 * MB + 0x14000;
static void reset(void *memory)
{
    ios_jit_low_rx_global = ios_jit_low_rw_global = (uintptr_t)memory;
    ios_jit_rx_base_global = ios_jit_rw_base_global = (void *)((uintptr_t)memory + 512 * MB);
    ios_jit_low_size_global = 288 * MB;
    ios_jit_low_reserved = used;
    ios_jit_pool_size_global = 864 * MB;
    jit_pool_offset = 600 * MB;
    ios_jit_tail_reserved = ios_jit_hole_off_eff = ios_jit_hole_end_eff = 0;
    ios_jit_hole2_off = ios_jit_hole2_end = 0;
    ios_pool_head_reserve = 128 * MB;
    ios_jit_low_full_logged = wow = lose_race = 0;
    ios_tail_carve_n = 1;
    ios_tail_carves[0].off = (size_t)(ios_jit_low_rx_global + 2 * MB - (uintptr_t)ios_jit_rx_base_global);
    ios_tail_carves[0].size = 16 * MB;
    ios_tail_carves[0].free = 1;
    ios_tail_carves[0].freed_at = 0;
    ios_tail_carves[0].peb = NULL;
    ios_tail_carves[0].retired = 0;
}
int main(void)
{
    void *memory = NULL, *ret = NULL;
    CHECK(!posix_memalign(&memory, 0x4000, 312 * MB));
    reset(memory);
    size_t request = 0x4000;
    CHECK(allocate(&request, &ret) == STATUS_SUCCESS);
    CHECK(request == 0x4000 && (uintptr_t)ret == ios_jit_low_rx_global + used);
    CHECK(ios_tail_carves[0].free && ios_tail_carves[0].size == 16 * MB);
    CHECK(ios_jit_low_reserved == used + 0x4000 && !ios_jit_tail_reserved);
    request = 16 * MB;
    CHECK(allocate(&request, &ret) == STATUS_SUCCESS);
    CHECK((uintptr_t)ret == ios_jit_low_rx_global + 2 * MB);
    CHECK(!ios_tail_carves[0].free && ios_jit_low_reserved == used + 0x4000);
    CHECK(!ios_jit_tail_reserved);
    puts("PASS: a 16KB dispatcher preserves the retired 16MB code buffer; the next code buffer reuses it without a pool-tail allocation");

    reset(memory);
    lose_race = 1;
    request = 0x4000;
    CHECK(allocate(&request, &ret) == STATUS_SUCCESS);
    CHECK(request == 16 * MB && !ios_tail_carves[0].free);
    CHECK(ios_jit_low_reserved == 288 * MB && !ios_jit_tail_reserved);
    reset(memory);
    lose_race = 2;
    request = 0x4000;
    CHECK(allocate(&request, &ret) == FALLBACK_TAIL);
    CHECK(ios_jit_low_reserved == 288 * MB && !ios_jit_tail_reserved);
    puts("PASS: losing region C retries the original reuse policy once; losing both resources reaches the normal tail path");

    reset(memory);
    ios_jit_low_reserved = ios_jit_low_size_global;
    request = 0x4000;
    CHECK(allocate(&request, &ret) == FALLBACK_TAIL && ios_tail_carves[0].free);
    setenv("MADEIRA_POOL_CODE_KEEP_BIG", "0", 1);   /* the old policy: the 16MB carve, whatever the ask */
    CHECK(allocate(&request, &ret) == STATUS_SUCCESS && request == 16 * MB && !ios_tail_carves[0].free);
    unsetenv("MADEIRA_POOL_CODE_KEEP_BIG");
    reset(memory);
    ios_tail_carves[1] = ios_tail_carves[0];
    ios_tail_carves[1].off += 20 * MB;
    ios_tail_carves[1].size = 0x4000;
    ios_tail_carve_n = 2;
    request = 0x4000;
    CHECK(allocate(&request, &ret) == STATUS_SUCCESS && request == 0x4000);
    CHECK(ios_tail_carves[0].free && !ios_tail_carves[1].free && ios_jit_low_reserved == used);
    reset(memory);
    request = MB;
    CHECK(allocate(&request, &ret) == STATUS_SUCCESS && request == MB && ios_tail_carves[0].free);
    CHECK(ios_jit_low_reserved == used + MB);
    reset(memory);
    request = 4 * MB + 0x4000;
    CHECK(allocate(&request, &ret) == STATUS_SUCCESS && request == 16 * MB);
    CHECK(!ios_tail_carves[0].free && ios_jit_low_reserved == used);
    puts("PASS: a request under a quarter of the free 16MB carve leaves it free (fresh tail carve with C full, region C otherwise; MADEIRA_POOL_CODE_KEEP_BIG=0 takes it); an exact-size carve and a larger request still reuse");

    /* A 440MB low run less the unchanged 128MB margin leaves 312MB. With
     * 16MB rounding C has only 304MB: the helper's 32MB request misses by
     * 80KB and falls through to the main tail despite the unused 8MB. */
    for (int page_fit = 0; page_fit < 2; page_fit++)
    {
        reset(memory);
        ios_jit_low_size_global = (page_fit ? 312 : 304) * MB;
        ios_jit_pool_size_global = 896 * MB;
        jit_pool_offset = 0x2dea8000;
        ios_jit_hole_off_eff = 0x15ff4000;
        ios_jit_hole_end_eff = 0x2566c000;
        request = 128 * MB;
        CHECK(allocate(&request, &ret) == STATUS_NO_MEMORY);
        request = 64 * MB;
        CHECK(allocate(&request, &ret) == STATUS_NO_MEMORY);
        request = 32 * MB;
        if (!page_fit)
        {
            CHECK(ios_jit_low_size_global - used == 32 * MB - 0x14000);
            CHECK(allocate(&request, &ret) == FALLBACK_TAIL);
            CHECK(ios_jit_low_reserved == used && ios_tail_carves[0].free);
            continue;
        }
        CHECK(allocate(&request, &ret) == STATUS_SUCCESS);
        CHECK(request == 32 * MB && (uintptr_t)ret == ios_jit_low_rx_global + used);
        CHECK(ios_jit_low_reserved == used + 32 * MB && !ios_jit_tail_reserved);
        request = 0x4000;
        CHECK(allocate(&request, &ret) == STATUS_SUCCESS);
        CHECK(request == 0x4000 && ios_tail_carves[0].free);
        CHECK(ios_jit_low_reserved == used + 32 * MB + 0x4000);
        request = 16 * MB;
        CHECK(allocate(&request, &ret) == STATUS_SUCCESS);
        CHECK(request == 16 * MB && (uintptr_t)ret == ios_jit_low_rx_global + 2 * MB);
        CHECK(!ios_tail_carves[0].free && !ios_jit_tail_reserved);
        CHECK(jit_pool_offset == 0x2dea8000);
    }
    puts("PASS: fitting C to 312MB keeps the helper's 32MB buffer and game startup allocations outside the main pool; 304MB reproduces the fallback");

    reset(memory);
    wow = 1;
    request = 0x4000;
    CHECK(allocate(&request, &ret) == FALLBACK_TAIL);
    CHECK(ios_tail_carves[0].free && ios_jit_low_reserved == used);
    reset(memory);
    ios_jit_low_size_global = 0;
    ios_tail_carve_n = 0;
    request = 0x4000;
    CHECK(allocate(&request, &ret) == FALLBACK_TAIL);
    CHECK(!ios_jit_tail_reserved && ios_jit_low_reserved == used);
    free(memory);
    puts("PASS: WoW64 never receives region-C memory; disabling region C retains the normal tail path");
    return 0;
}
'''

# These contracts cover the callers, placement bounds and byte-length protocol.
page_option = swift[swift.index('let pageFit = '):swift.index('var pairA:')]
assert '.contains(splitValue)' in page_option
assert 'MadeiraConfig.gameValue("pool-page-fit")' in page_option
assert 'MadeiraConfig.get("pool-page-fit")' in page_option
assert swift.count('private static func takeSecondRegion(') == 1
assert swift.count('want: requestedPoolSize - poolSize, pageFit: pageFit,') == 2
take = function(swift, 'private static func takeSecondRegion(', '\n    }')
assert 'let size = poolRunSize(available: best.size, wanted: vm_address_t(want), pageFit: pageFit)' in take
assert 'let ceiling: vm_address_t = 0x180000000' in take
assert 'b + size > ceiling' in take and 'gapHitsWindow' in take
assert 'VM_FLAGS_OVERWRITE' not in take
low = function(swift, 'private static func takeLowRegion(', '\n    }')
assert 'Int(marginText) ?? 128' in low
assert 'let available = r.size > keep ? r.size - keep : 0' in low
assert 'poolRunSize(available: available, wanted: available, pageFit: pageFit)' in low
assert 'runs.contains(where: { $0.base < r.base && $0.size >= margin }) ? 0 : margin' in low
assert 'guard let best = best, size >= 64 << 20' in low
assert 'exeWindow: (exeWinBase, exeWinSize), pageFit: pageFit)' in swift
allocator = (root / 'app/Madeira/JITAllocator.c').read_text()
prepare = function(allocator, 'void *jit26_prepare_region(')
assert 'register size_t x1 __asm__("x1") = len;' in prepare
script = (root / 'app/Madeira/madeira-jit.js').read_text()
assert 'let prepResp = prepare_memory_region(addr, x1);' in script
print('PASS: page-fit requires pool-split, reaches B and C requests and preserves region-C margin and native mapping guards')

size_helper = function(swift, 'private static func poolRunSize(', '\n    }')
swift_fixture = 'typealias vm_address_t = UInt\n' + 'enum Production {\n' + size_helper + r'''
    static func run() {
        let mb: UInt = 1 << 20, budget: UInt = 896 << 20
        let oldA = poolRunSize(available: 571 * mb, wanted: budget, pageFit: false)
        let oldB = poolRunSize(available: 316 * mb, wanted: budget - oldA, pageFit: false)
        let a = poolRunSize(available: 571 * mb, wanted: budget, pageFit: true)
        let b = poolRunSize(available: 316 * mb, wanted: budget - a, pageFit: true)
        precondition(oldA == 560 * mb && oldB == 304 * mb)
        precondition(a == 571 * mb && b == 316 * mb && a + b <= budget)
        precondition(a + b - oldA - oldB == 23 * mb)
        precondition(UInt(0x148000000) + a <= UInt(0x16c3d0000))
        precondition(UInt(0x16c3d0000) + b <= UInt(0x180000000))
        precondition(poolRunSize(available: UInt.max, wanted: UInt.max, pageFit: false) == 0)
        precondition(poolRunSize(available: UInt.max, wanted: UInt.max, pageFit: true) == UInt.max & ~UInt(0x3fff))
        precondition(poolRunSize(available: 0x3fff, wanted: budget, pageFit: true) == 0)
        precondition(poolRunSize(available: budget, wanted: 0x4001, pageFit: true) == 0x4000)
        let lowFree: UInt = 440 * mb, margin: UInt = 128 * mb
        let oldC = poolRunSize(available: lowFree - margin, wanted: lowFree - margin, pageFit: false)
        let c = poolRunSize(available: lowFree - margin, wanted: lowFree - margin, pageFit: true)
        precondition(oldC == 304 * mb && c == 312 * mb)
        precondition(UInt(0x140000000) - c == UInt(0x12c800000))
        precondition(lowFree - oldC == 136 * mb && lowFree - c == margin)
        let used: UInt = 272 * mb + 0x14000
        precondition(oldC - used == 32 * mb - 0x14000 && c - used >= 32 * mb)
        precondition(poolRunSize(available: 64 * mb - 1, wanted: 64 * mb - 1, pageFit: true) < 64 * mb)
        var state: UInt64 = 411
        for _ in 0..<10000 {
            state = state &* 6364136223846793005 &+ 1
            let available = UInt(state % UInt64(900 * mb))
            state = state &* 6364136223846793005 &+ 1
            let wanted = UInt(state % UInt64(budget + 1))
            let old = min(available & ~(16 * mb - 1), (wanted + 16 * mb - 1) & ~(16 * mb - 1))
            precondition(poolRunSize(available: available, wanted: wanted, pageFit: false) == old)
            let fitted = poolRunSize(available: available, wanted: wanted, pageFit: true)
            precondition(fitted <= available && fitted <= wanted && fitted & 0x3fff == 0)
            let second = poolRunSize(available: 316 * mb, wanted: budget - fitted, pageFit: true)
            precondition(fitted + second <= budget)
            let lowMargin = UInt(state % 4097) * mb
            let lowAvailable = available > lowMargin ? available - lowMargin : 0
            let lowDefault = poolRunSize(available: lowAvailable, wanted: lowAvailable, pageFit: false)
            let lowFitted = poolRunSize(available: lowAvailable, wanted: lowAvailable, pageFit: true)
            precondition(lowDefault == lowAvailable & ~(16 * mb - 1))
            precondition(lowFitted <= lowAvailable && lowFitted & 0x3fff == 0)
            if lowFitted >= 64 * mb { precondition(available - lowFitted >= lowMargin) }
        }
        print("PASS: production Swift page fitting recovers 23MB in a 410-shaped layout; 10,000 default/budget comparisons and boundary cases")
        print("PASS: production Swift sizing recovers C's 8MB rounding loss in a 411-shaped layout without reducing its 128MB margin")
    }
}
Production.run()
'''

with tempfile.TemporaryDirectory(prefix='madeira-pool-startup-') as directory:
    temporary = Path(directory)
    cfile, binary = temporary / 'startup.c', temporary / 'startup'
    cfile.write_text(c_fixture)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-D_POSIX_C_SOURCE=200809L',
                    '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                    '-fno-omit-frame-pointer', '-pthread', str(cfile), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True)
    print(result.stdout, end='')
    if result.returncode:
        print(result.stderr, end='')
        result.check_returncode()
    compiler = shutil.which('swiftc')
    if compiler:
        swiftfile, swift_binary = temporary / 'startup.swift', temporary / 'swift-startup'
        swiftfile.write_text(swift_fixture)
        subprocess.run([compiler, str(swiftfile), '-o', str(swift_binary)], check=True)
        subprocess.run([str(swift_binary)], check=True)
    elif args.require_swift:
        raise SystemExit('Swift compiler required for the production sizing fixture')
    else:
        print('SKIP: Swift compiler unavailable locally; macOS CI must run this check with --require-swift')
