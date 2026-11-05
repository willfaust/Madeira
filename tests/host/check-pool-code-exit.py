#!/usr/bin/env python3
"""An exited pseudo-process's FEX code buffers go back to the pool (production code).

FEX releases a code buffer when it rotates to a new one, never when its process
exits, so every exited program's last buffer stayed live for the rest of the
session. GTA V Enhanced's first start after the Dock installs (build 514, log
2026-10-12 13:08-13:13) lost 96 MB of region C and a 128 MB tail buffer that
way, and every code buffer the game asked for was then capped at 16 MB.

The C fixture compiles the real retire, readiness, foreign-release and exit
hook functions, the real EC_CODE allocation prefix (budget cap, reuse, region
C) and the real MEM_RELEASE carve block. Fresh tail carves are placed with the
production hole helpers (the ml1039 head-range fallback is not modelled). It
replays that log's code-buffer requests, releases, exits, head cursor and
times: with MADEIRA_POOL_CODE_EXIT_RECLAIM=0 it must reproduce the log (the same
offsets, tail_resv=0x18f38000, the game held to 16 MB); by default the game
gets its 128 MB buffer. Thread scans are stubs: an allocator check, not a
device run.
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
    'static size_t ios_pool_hole_tail_start(',
    'static size_t ios_pool_hole_between(',
    'static size_t ios_pool_code_cap(',
    'static size_t ios_pool_holes_tail_start(',
    'static int ios_pool_skip_pieces(',
    'int ios_jit_low_contains(',
    'static int ios_pool_low_take(',
    'static int ios_tail_carve_in_low(',
    'static int ios_pool_preserve_code_carve(',
    'static int ios_pool_preserve_big_carve(',
    'static int ios_tail_carve_ready(',
    'static unsigned ios_tail_carves_retire_owner(',
    'static int ios_tail_carve_foreign_release(',
    'static void ios_tail_carves_owner_died(',
))
carve_start = source.index('#define IOS_TAIL_CARVE_MAX ')
carve_table = source[carve_start:source.index('\n\n', carve_start)]
ec = source[source.index('size_t alloc_size = (*size_ptr + 0x3FFF) & ~0x3FFFUL;'):]
ec = ec[:ec.index('size_t reserve_offset, tail_added, tail_skipped = 0;')]
free_start = source.index('    if ((type & MEM_RELEASE) && ios_jit_rx_base_global && ios_jit_pool_size_global &&')
free_end = source.index('\n    }\n', source.index('/* pool address but not a live tail carve', free_start)) + 7
release_block = source[free_start:free_end]

# Where the new rules hook in.
reclaim = function('void ios_jit_reclaim_process( void *peb )')
assert reclaim.count('ios_tail_carves_owner_died( peb );') == 1
assert reclaim.index('ios_tail_carves_owner_died( peb );') > reclaim.rindex('pthread_mutex_unlock( &ios_pool_lock );'), \
    'the carve lock is never taken under the pool lock'
assert source.count('.retired = 1;') == 2, 'an exit, or a release while a thread still runs in the carve, retires it'
assert source.count('ios_tail_carves[ios_tail_carve_n].retired = 0;') == 4, 'every new carve starts unretired'
assert source.count('ios_tail_carves[ios_tail_carve_n].peb = carve_peb;') == 3, 'region C, ml1039 and tail carves'
assert source.count('ios_tail_carves[ios_tail_carve_n].peb = NULL;') == 1, 'a skipped piece has no owner'
assert 'ios_tail_carves[best].peb = carve_peb;' in ec and 'ios_tail_carves[best].retired = 0;' in ec
assert ec.count('ios_tail_carve_ready( &ios_tail_carves[') == 2, 'the cap lift and the reuse share one rule'
assert ('ios_tail_carve_scan( (char *)ios_jit_rx_base_global + ios_tail_carves[best].off,\n'
        '                                     ios_tail_carves[best].size, 1 )') in ec, 'a strict thread scan'
assert release_block.index('ios_tail_carve_foreign_release(') < release_block.index('ios_tail_carves[i].free = 1;')

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
#define STATUS_SUCCESS 0
#define STATUS_NO_MEMORY -1
#define FALLBACK_TAIL 2
#define FALL_THROUGH 3
#define MEM_RELEASE 0x8000
#define IOS_POOL_LOW_CARVE_MAX 0x8000000u
#define IOS_POOL_REUSE_GRACE_SEC 3
static time_t fake_now;
static time_t fake_time(time_t *t) { if (t) *t = fake_now; return fake_now; }
#define time(t) fake_time(t)
static void *ios_jit_rx_base_global, *ios_jit_rw_base_global;
uintptr_t ios_jit_low_rx_global, ios_jit_low_rw_global;
size_t ios_jit_low_size_global;
static size_t ios_jit_pool_size_global, jit_pool_offset, ios_pool_head_reserve;
static volatile size_t ios_jit_low_reserved, ios_jit_tail_reserved;
static size_t ios_jit_hole_off_eff, ios_jit_hole_end_eff, ios_jit_hole2_off, ios_jit_hole2_end;
static int ios_jit_low_full_logged;
static unsigned ios_tail_carve_n;
static pthread_mutex_t ios_tail_carve_lock = PTHREAD_MUTEX_INITIALIZER;
''' + carve_table + r'''
static uintptr_t owner;
static int scan_busy, scans, occupied;
static void *ios_jit_current_peb(void) { return (void *)owner; }
static uintptr_t ios_wow_base(void) { return 0; }
static int ios_tail_carve_scan(const void *base, size_t size, int strict)
{ (void)base; (void)size; CHECK(strict == 1); CHECK(++scans < 64); return scan_busy; }   /* < 64: no retry loop */
static int ios_tail_carve_occupied(const void *base, size_t size)
{ (void)base; (void)size; return occupied; }
''' + helpers + r'''
static int allocate(size_t *size_ptr, void **ret)
{
''' + ec + r'''
    (void)kept_big_carve;  /* read by the production tail path after this prefix */
    return FALLBACK_TAIL;  /* the production tail path starts after this prefix */
}
static int release(void *base, unsigned type, void **addr_ptr, size_t *size_ptr)
{
''' + release_block + r'''
    return FALL_THROUGH;
}

/* The production tail placement (holes, skipped pieces, collision limits). */
static int tail_carve(size_t *size_ptr, void **ret)
{
    size_t total = ios_jit_pool_size_global, size = (*size_ptr + 0x3fff) & ~(size_t)0x3fff;
    size_t cur = ios_jit_tail_reserved, po[3], ps[3];
    size_t start = ios_pool_holes_tail_start(total, cur, size, ios_jit_hole_off_eff, ios_jit_hole_end_eff,
                                             ios_jit_hole2_off, ios_jit_hole2_end);
    int n = 0, k;

    if (start + size > total / 4 * 3 || total - start - size < jit_pool_offset) return STATUS_NO_MEMORY;
    if (start != cur)
        n = ios_pool_skip_pieces(total - start, total - cur, ios_jit_hole_off_eff, ios_jit_hole_end_eff,
                                 ios_jit_hole2_off, ios_jit_hole2_end, po, ps);
    ios_jit_tail_reserved = start + size;
    CHECK(ios_tail_carve_n + 1 + n <= IOS_TAIL_CARVE_MAX);
    ios_tail_carves[ios_tail_carve_n++] = (struct ios_tail_carve){ .off = total - start - size, .size = size,
                                                                   .peb = (void *)owner };
    for (k = 0; k < n; k++)
        if (ps[k] >= MB)
            ios_tail_carves[ios_tail_carve_n++] = (struct ios_tail_carve){ .off = po[k], .size = ps[k], .free = 1 };
    *ret = (char *)ios_jit_rx_base_global + total - start - size;
    *size_ptr = size;
    return STATUS_SUCCESS;
}

/* FEX's CodeBuffer: ask, halve on refusal. */
static size_t fex_ask(uintptr_t peb, size_t want, void **rx)
{
    owner = peb;
    for (size_t ask = want; ask >= 0x4000; ask >>= 1)
    {
        size_t size = ask;
        int status = allocate(&size, rx);
        if (status == FALLBACK_TAIL) status = tail_carve(&size, rx);
        if (status == STATUS_SUCCESS) return size;
    }
    return 0;
}

static void fex_release(uintptr_t peb, void *rx)
{
    void *addr = NULL;
    size_t size = 0;
    owner = peb;
    CHECK(release(rx, MEM_RELEASE, &addr, &size) == STATUS_SUCCESS && addr == rx && size);
}

struct proc { uintptr_t peb; void *misc, *code; size_t code_size; };
static char *pool, *low;

static size_t off_of(const void *rx) { return (size_t)((const char *)rx - pool); }
static size_t c_off(const void *rx) { return (size_t)((const char *)rx - low); }

static void start(struct proc *p, uintptr_t peb, time_t t, size_t head)
{
    fake_now = t;
    jit_pool_offset = head;
    p->peb = peb;
    CHECK(fex_ask(peb, 0x4000, &p->misc) == 0x4000);
    p->code_size = fex_ask(peb, 16 * MB, &p->code);
    CHECK(p->code_size >= 16 * MB);
}

/* A full buffer: the next generation first, the old one released after. */
static size_t rotate(struct proc *p, time_t t, size_t head)
{
    void *old = p->code;
    fake_now = t;
    jit_pool_offset = head;
    p->code_size = fex_ask(p->peb, 128 * MB, &p->code);
    CHECK(p->code_size);
    fex_release(p->peb, old);
    return p->code_size;
}

/* FEX frees its dispatcher at exit, never its code buffer; then the reclaim. */
static void quit(struct proc *p, time_t t)
{
    fake_now = t;
    fex_release(p->peb, p->misc);
    owner = p->peb;
    ios_tail_carves_owner_died((void *)p->peb);
}

static void reset(void)
{
    ios_jit_rx_base_global = ios_jit_rw_base_global = pool;
    ios_jit_pool_size_global = 0x38000000;
    ios_jit_low_rx_global = ios_jit_low_rw_global = (uintptr_t)low;   /* above the pool: no wrapping offsets */
    ios_jit_low_size_global = 0x71d0000;
    ios_jit_low_reserved = ios_jit_tail_reserved = 0;
    ios_jit_hole_off_eff = 0x270c8000;
    ios_jit_hole_end_eff = 0x277cc000;
    ios_jit_hole2_off = ios_jit_hole2_end = 0;
    ios_pool_head_reserve = 128 * MB;
    ios_jit_low_full_logged = scan_busy = scans = occupied = 0;
    memset(ios_tail_carves, 0, sizeof(ios_tail_carves));
    ios_tail_carve_n = 0;
}

static unsigned retired_count(void)
{
    unsigned i, n = 0;
    for (i = 0; i < ios_tail_carve_n; i++) n += ios_tail_carves[i].free && ios_tail_carves[i].retired;
    return n;
}

/* GTA5_Enhanced.exe, build 514, 2026-10-12: seconds after 13:09:00, the head
 * cursor at each request, peb names the process. Returns the game's second
 * buffer. With the switch off every grant is checked against the log. */
static size_t replay(int fix)
{
    struct proc dock, play, l1, rs1, rs2, rs3, l2, rs4, rs5, sch, gta;
    size_t got;

    reset();
    if (fix) unsetenv("MADEIRA_POOL_CODE_EXIT_RECLAIM");
    else setenv("MADEIRA_POOL_CODE_EXIT_RECLAIM", "0", 1);
    start(&dock, 0x106914000, 20, 0x2ed8000);
    start(&play, 0x106980000, 24, 0x7540000);
    start(&l1, 0x1069ac000, 25, 0x9994000);
    start(&rs1, 0x1069c4000, 27, 0xc524000);
    start(&rs2, 0x1069c8000, 27, 0xe7e0000);
    CHECK(c_off(dock.code) == 0x4000 && c_off(rs2.code) == 0x4014000 && ios_jit_low_reserved == 0x5014000);
    quit(&rs1, 28);
    CHECK(rotate(&rs2, 41, 0x11fb8000) == 128 * MB && off_of(rs2.code) == 0x30000000);
    start(&rs3, 0x106778000, 74, 0x11fb8000);
    CHECK(ios_tail_carve_n == 11);                               /* "free_left=11" */
    if (fix) CHECK(c_off(rs3.code) == 0x3010000 && scans == 1);  /* rs1's buffer, 46 s after its exit */
    else CHECK(c_off(rs3.code) == 0x4014000 && !scans);
    quit(&rs3, 75);
    quit(&l1, 75);
    quit(&play, 75);
    start(&l2, 0x10697c000, 75, 0x132c4000);
    quit(&rs2, 75);
    if (fix) CHECK(retired_count() == 4 && c_off(l2.code) == 0x4014000);   /* rs3 l1 play: 16 MB; rs2: 128 MB */
    else CHECK(!retired_count() && c_off(l2.code) == 0x5014000);
    start(&rs4, 0x1069a8000, 77, 0x15378000);                    /* 2 s after the exits: nothing retired is ready */
    if (fix) CHECK(c_off(rs4.code) == 0x5014000 && scans == 1);
    else CHECK(c_off(rs4.code) == 0x6014000);
    start(&rs5, 0x1069b0000, 78, 0x15cfc000);
    if (fix) CHECK(c_off(rs5.code) == 0x1008000 && scans == 2 && ios_jit_tail_reserved == 128 * MB);
    else CHECK(off_of(rs5.code) == 0x2f000000 && ios_jit_tail_reserved == 0x9000000);
    quit(&rs4, 78);
    start(&sch, 0x1069bc000, 82, 0x16680000);
    if (fix) CHECK(c_off(sch.code) == 0x200c000 && scans == 3);
    else CHECK(off_of(sch.code) == 0x2e000000 && ios_jit_tail_reserved == 0xa000000);
    CHECK(rotate(&sch, 83, 0x17004000) == 128 * MB);
    if (fix) CHECK(off_of(sch.code) == 0x30000000 && scans == 4 && ios_jit_tail_reserved == 128 * MB);  /* rs2's */
    else CHECK(off_of(sch.code) == 0x1f0c8000 && ios_jit_tail_reserved == 0x18f38000);
    got = rotate(&l2, 89, 0x17004000);
    if (fix) CHECK(got == 128 * MB && off_of(l2.code) == 0x28000000 && ios_jit_tail_reserved == 256 * MB);
    else CHECK(got == 0x6834000 && off_of(l2.code) == 0x277cc000);   /* "tail REUSE rx=0x16f7cc000 size=0x6834000" */
    got = rotate(&sch, 95, 0x17004000);
    if (fix) CHECK(got == 128 * MB && off_of(sch.code) == 0x1f0c8000 && ios_jit_tail_reserved == 0x18f38000);
    else
    {   /* the log: a 16 MB generation, full at once, then its old 128 MB one again */
        CHECK(got == 16 * MB && c_off(sch.code) == 0x5014000);
        CHECK(rotate(&sch, 95, 0x17004000) == 128 * MB && off_of(sch.code) == 0x1f0c8000);
    }
    start(&gta, 0x106760000, 128, 0x17304000);
    CHECK(c_off(gta.misc) == 0x4010000);
    CHECK(c_off(gta.code) == (fix ? 0x200c000 : 0x5014000));
    got = rotate(&gta, 142, 0x1b240000);
    if (fix) CHECK(off_of(gta.code) == 0x30000000 && scans == 4);
    else CHECK(got == 16 * MB && off_of(gta.code) == 0x2e000000);
    CHECK(ios_jit_tail_reserved == 0x18f38000);
    return got;
}

static void unit(void)
{
    struct ios_tail_carve c = { .off = 0, .size = 16 * MB, .free = 0 };
    size_t bytes = 1;
    void *addr = NULL, *rx;
    size_t size = 0;

    reset();
    CHECK(!ios_tail_carve_ready(&c, 100));
    c.free = 1; c.freed_at = 100;
    CHECK(ios_tail_carve_ready(&c, 100));                         /* FEX's own release: at once, as before */
    c.retired = 1;
    CHECK(!ios_tail_carve_ready(&c, 102) && ios_tail_carve_ready(&c, 103));
    CHECK(!ios_tail_carve_ready(&c, 99));                         /* a clock step back keeps it waiting */

    ios_tail_carves[0] = (struct ios_tail_carve){ .off = 0x1000000, .size = 16 * MB, .peb = (void *)7 };
    ios_tail_carves[1] = (struct ios_tail_carve){ .off = 0x2000000, .size = 32 * MB, .free = 1, .peb = (void *)7 };
    ios_tail_carves[2] = (struct ios_tail_carve){ .off = 0x4000000, .size = 64 * MB, .peb = (void *)8 };
    ios_tail_carves[3] = (struct ios_tail_carve){ .off = 0x8000000, .size = 0x4000 };
    ios_tail_carves[4] = (struct ios_tail_carve){ .off = 0x8004000, .size = 0x4000, .peb = (void *)7 };
    ios_tail_carve_n = 5;
    CHECK(ios_tail_carves_retire_owner(ios_tail_carves, 5, NULL, 50, &bytes) == 0 && !bytes);
    CHECK(ios_tail_carves_retire_owner(ios_tail_carves, 5, (void *)7, 50, &bytes) == 2 && bytes == 16 * MB + 0x4000);
    CHECK(ios_tail_carves[0].free && ios_tail_carves[0].retired && ios_tail_carves[0].freed_at == 50 && !ios_tail_carves[0].peb);
    CHECK(ios_tail_carves[1].free && !ios_tail_carves[1].retired && ios_tail_carves[1].peb == (void *)7);
    CHECK(!ios_tail_carves[2].free && !ios_tail_carves[3].free && ios_tail_carves[4].retired);
    puts("PASS: an exit retires only its own live buffers; a retired one waits out the 3 s grace, FEX's own releases do not");

    CHECK(ios_tail_carve_foreign_release(&ios_tail_carves[2], (void *)7));
    CHECK(!ios_tail_carve_foreign_release(&ios_tail_carves[2], (void *)8));
    CHECK(!ios_tail_carve_foreign_release(&ios_tail_carves[2], NULL));
    CHECK(!ios_tail_carve_foreign_release(&ios_tail_carves[3], (void *)7));
    setenv("MADEIRA_POOL_CODE_EXIT_RECLAIM", "0", 1);
    ios_tail_carves_owner_died((void *)8);
    CHECK(!ios_tail_carves[2].free);
    setenv("MADEIRA_POOL_CODE_EXIT_RECLAIM", "1", 1);
    fake_now = 60;
    ios_tail_carves_owner_died((void *)8);
    CHECK(ios_tail_carves[2].free && ios_tail_carves[2].retired && ios_tail_carves[2].freed_at == 60);
    unsetenv("MADEIRA_POOL_CODE_EXIT_RECLAIM");
    puts("PASS: MADEIRA_POOL_CODE_EXIT_RECLAIM=0 keeps them live; 1 and unset retire them");

    /* A retired 64 MB buffer, a small budget (the tail and head leave 16 MB). */
    reset();
    ios_jit_low_reserved = ios_jit_low_size_global;               /* region C full */
    ios_jit_tail_reserved = 0x18f38000;
    jit_pool_offset = 0x1b240000;
    ios_tail_carves[0] = (struct ios_tail_carve){ .off = 0x8000000, .size = 64 * MB, .free = 1, .retired = 1, .freed_at = 200 };
    ios_tail_carve_n = 1;
    owner = 9;
    fake_now = 202;
    size = 64 * MB;
    CHECK(allocate(&size, &rx) == STATUS_NO_MEMORY && !scans);   /* in its grace: no cap lift, no reuse */
    fake_now = 203;
    scan_busy = 1;
    size = 64 * MB;
    CHECK(allocate(&size, &rx) == STATUS_NO_MEMORY && scans == 1);
    CHECK(ios_tail_carves[0].free && ios_tail_carves[0].retired && ios_tail_carves[0].freed_at == 203);
    size = 16 * MB;
    CHECK(allocate(&size, &rx) == FALLBACK_TAIL && scans == 1);   /* within budget the normal path goes on */
    scan_busy = 0;
    fake_now = 206;
    size = 32 * MB;
    CHECK(allocate(&size, &rx) == STATUS_SUCCESS && scans == 2 && size == 64 * MB && off_of(rx) == 0x8000000);
    CHECK(!ios_tail_carves[0].free && !ios_tail_carves[0].retired && ios_tail_carves[0].peb == (void *)9);
    CHECK(((volatile uint32_t *)rx)[0] == 0xd503201fu && ((volatile uint32_t *)rx)[16 * MB - 1] == 0xd503201fu);
    puts("PASS: a busy dead buffer restarts its grace and the budget applies; a clean one is NOP-filled and handed on");

    /* Its dead owner's late release must not free the new owner's buffer. */
    owner = 8;
    CHECK(release(rx, MEM_RELEASE, &addr, &size) == FALL_THROUGH && !ios_tail_carves[0].free);
    owner = 0;                                                    /* a thread without a TEB: as before */
    /* MADEIRA_POOL_CODE_DEFER_FREE=0: refused and left live, as before. */
    occupied = 1;
    setenv("MADEIRA_POOL_CODE_DEFER_FREE", "0", 1);
    CHECK(release(rx, MEM_RELEASE, &addr, &size) == FALL_THROUGH && !ios_tail_carves[0].free);
    unsetenv("MADEIRA_POOL_CODE_DEFER_FREE");
    /* A release while a thread still runs in the buffer frees it as retired: no
     * owner, and reuse waits out the grace and a strict scan, as for an exit. */
    CHECK(release(rx, MEM_RELEASE, &addr, &size) == STATUS_SUCCESS && addr == rx && size == 64 * MB);
    CHECK(ios_tail_carves[0].free && ios_tail_carves[0].retired && !ios_tail_carves[0].peb);
    CHECK(ios_tail_carves[0].freed_at == fake_now && !ios_tail_carve_ready( &ios_tail_carves[0], fake_now ));
    CHECK(ios_tail_carve_ready( &ios_tail_carves[0], fake_now + 3 ));
    occupied = 0;
    ios_tail_carves[0].free = ios_tail_carves[0].retired = 0;   /* live again, owned by 9 */
    ios_tail_carves[0].peb = (void *)9;
    owner = 9;
    CHECK(release(rx, MEM_RELEASE, &addr, &size) == STATUS_SUCCESS && addr == rx && size == 64 * MB);
    CHECK(ios_tail_carves[0].free && !ios_tail_carves[0].retired);
    owner = 8;
    CHECK(release(rx, MEM_RELEASE, &addr, &size) == FALL_THROUGH);  /* already free */
    puts("PASS: a release from another process is refused; an occupied one is retired until its thread leaves (refused with MADEIRA_POOL_CODE_DEFER_FREE=0); the owner's (or a TEB-less thread's) works as before");
}

int main(void)
{
    void *p = NULL;
    size_t off, on;

    CHECK(!posix_memalign(&p, 0x4000, 0x38000000 + 0x71d0000));
    pool = p;
    low = pool + 0x38000000;
    unit();
    off = replay(0);
    printf("PASS: MADEIRA_POOL_CODE_EXIT_RECLAIM=0 replays the 13:11 log: tail_resv 0x18f38000, the game's buffer 0x%zx (16 MB)\n", off);
    on = replay(1);
    CHECK(on == 128 * MB);
    printf("PASS: by default the dead helpers' buffers are reused and the game gets 0x%zx (128 MB)\n", on);
    free(p);
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-pool-code-exit-') as directory:
    cfile = Path(directory) / 'pool-code-exit.c'
    binary = Path(directory) / 'pool-code-exit'
    cfile.write_text(fixture)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-D_POSIX_C_SOURCE=200809L',
                    '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined',
                    '-fno-omit-frame-pointer', '-pthread', str(cfile), '-o', str(binary)], check=True)
    # The allocator's own log lines go to stderr; show them only on failure.
    completed = subprocess.run([str(binary)], capture_output=True, text=True)
    print(completed.stdout, end='')
    if completed.returncode:
        print(completed.stderr, end='')
        completed.check_returncode()
