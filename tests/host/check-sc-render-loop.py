#!/usr/bin/env python3
"""Execute the production Win64 adapter against a thread-local IPC loop fixture.

Also compile the actual image guard/patch, test both vtable pointer bases and
reject mismatched images without writes. Exercise the preferred-base case with
DIR64 rebasing of the existing vtable slots, without relocations for the new
task callbacks: those must already name the mapped image. Every analysed
helper build (ios_sch_builds) runs: the first build with its .text tail
layout, 2.4.0.296 and 2.4.0.302 with their task callbacks in int3 padding. No supplied binary.
Requires x86_64 Linux, GNU binutils, Python and a C compiler.
"""
from pathlib import Path
import hashlib
import os
import re
import resource
import subprocess
import tempfile


root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def function(signature):
    start = native.index(signature)
    return native[start:native.index('\n}', start) + 2]


def define(name):
    value = re.search(r'#define ' + name + r'\s+(0x[\da-fA-F]+|\d+)', native)[1]
    return int(value, 0)


def array_bytes(name):
    start = native.index('static const unsigned char ' + name + '[')
    body = native[start:native.index('};', start) + 2]
    return bytes(int(x, 16) for x in re.findall(r'0x([\da-fA-F]{2})', body[body.index('{'):]))


def code_table(name):
    """(rva, len, digest) of each guarded range of one build's table."""
    start = native.index(' ' + name + '[] =')
    body = native[start:native.index('\n};', start)]
    out = []
    for m in re.finditer(r'\{ (IOS_SCH\w+|0x[\da-f]+), (0x[\da-f]+),[^{]*\{([^}]*)\}', body):
        rva = define(m[1]) if m[1].startswith('IOS') else int(m[1], 16)
        out.append((rva, int(m[2], 16), bytes(int(x, 16) for x in re.findall(r'0x([\da-f]{2})', m[3]))))
    return out


def padding_ranges(table):
    """Ranges whose digest is a RET followed by int3 padding (no helper code)."""
    return [(rva, n) for rva, n, d in table if d == hashlib.sha256(b'\xc3' + b'\xcc' * (n - 1)).digest()]


# The patch region: every #define, blob, digest table, build table, guard and patch.
region = native[native.index('#define IOS_SCH_IMAGE_BASE'):
                native.index('\n}', native.index('static void ios_sc_render_handler_patch(')) + 2]

# Per build: what the fixture needs beyond ios_sch_builds (helper routines the
# adapter calls and the regions the zero tails must stay in).
BUILDS = [
    dict(name='first build', prefix='IOS_SCH_', suffix='', table='ios_sch_code', defsym=[],
         helper_new=0x13e708, run_until_idle=0x1728b0, global_drain=0x11be60, global_loop=0x1cea00,
         text_vs=0x17f34c, text_raw=0x17f400, data=define('IOS_SCH_DATA'), data_vs=0x43bc, data_raw=0x1a00,
         loop=['ios_sch_loop_thunk'], diagnostics=True),
    dict(name='2.4.0.296', prefix='IOS_SCH296_', suffix='296', table='ios_sch296_code', defsym=['--defsym', 'SCH296=1'],
         helper_new=0x1622b8, run_until_idle=0x1965d0, global_drain=0x13eec0, global_loop=0x1f6a10,
         text_vs=define('IOS_SCH296_TEXT_VS'), text_raw=define('IOS_SCH296_TEXT_RAW'),
         data=define('IOS_SCH296_DATA'), data_vs=define('IOS_SCH296_DATA_VS'), data_raw=0x1a00,
         loop=['ios_sch296_loop_thunk', 'ios_sch296_task_add', 'ios_sch296_task_release',
               'ios_sch296_task_one', 'ios_sch296_task_any'], diagnostics=False),
    # 2.4.0.302 is 2.4.0.296 with 0x670 bytes inserted into .text: the same compact variant
    # (SCH296 selects it), the routines above the insertion moved by 0x670 and .rdata/.data by 0x1000.
    dict(name='2.4.0.302', prefix='IOS_SCH302_', suffix='302', table='ios_sch302_code', defsym=['--defsym', 'SCH296=1'],
         helper_new=0x162928, run_until_idle=0x196c40, global_drain=0x13f410, global_loop=0x1f7a10,
         text_vs=define('IOS_SCH302_TEXT_VS'), text_raw=define('IOS_SCH302_TEXT_RAW'),
         data=define('IOS_SCH302_DATA'), data_vs=define('IOS_SCH302_DATA_VS'), data_raw=0x1a00,
         loop=['ios_sch302_loop_thunk', 'ios_sch302_task_add', 'ios_sch302_task_release',
               'ios_sch302_task_one', 'ios_sch302_task_any'], diagnostics=False),
]

# The helper's code stays out of the tree: each build's table holds each range's
# SHA-256. The fixture image holds a filler in each range instead, and this
# stand-in for CommonCrypto answers a range's own digest exactly while its filler
# is intact. RET + int3 padding ranges hold those bytes themselves (their
# digests are checked against hashlib above, they are not the helper's code).
SHA_STANDIN = r'''
static const struct ios_sch_build *sch_build;
static char *sch_fixture_image;
static int sch_padding(size_t k)
{
    for (size_t i = 0; i < ARRAY_SIZE(sch_padding_ranges); i++)
        if (sch_padding_ranges[i][0] == sch_build->code[k].rva && sch_padding_ranges[i][1] == sch_build->code[k].len)
            return 1;
    return 0;
}
static unsigned char sch_filler(size_t rva, size_t i) { return (unsigned char)((rva + i) * 131u + 7u); }
static void sch_fill(char *image)
{
    sch_fixture_image = image;
    for (size_t k = 0; k < sch_build->code_count; k++)
        for (size_t i = 0; i < sch_build->code[k].len; i++)
            image[sch_build->code[k].rva + i] = sch_padding(k) ? (char)(i ? 0xcc : 0xc3)
                                                               : (char)sch_filler(sch_build->code[k].rva, i);
}
static unsigned char *CC_SHA256(const void *data, uint32_t len, unsigned char *md)
{
    memset(md, 0, CC_SHA256_DIGEST_LENGTH);
    for (size_t k = 0; k < sch_build->code_count; k++)
    {
        const unsigned char *p = (const unsigned char *)sch_fixture_image + sch_build->code[k].rva;
        size_t i;
        if ((const void *)p != data || len != sch_build->code[k].len) continue;
        for (i = 0; i < len; i++)
            if (p[i] != (sch_padding(k) ? (i ? 0xcc : 0xc3) : sch_filler(sch_build->code[k].rva, i))) break;
        if (i == len) memcpy(md, sch_build->code[k].sha256, CC_SHA256_DIGEST_LENGTH);
    }
    return md;
}
'''

PRELUDE = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/mman.h>
#define ABI __attribute__((ms_abi))
typedef uint64_t ULONG64;
typedef uintptr_t ULONG_PTR;
typedef size_t SIZE_T;
typedef uint16_t WCHAR;
typedef struct { WCHAR *Buffer; uint16_t Length; } UNICODE_STRING;
typedef struct {
    struct { uint16_t Machine, NumberOfSections; uint32_t TimeDateStamp; } FileHeader;
    struct { uint16_t Magic; uint32_t SizeOfImage; } OptionalHeader;
} IMAGE_NT_HEADERS;
typedef struct { uint32_t VirtualAddress; union { uint32_t VirtualSize; } Misc;
                 uint32_t SizeOfRawData, Characteristics; } IMAGE_SECTION_HEADER;
#define IMAGE_FILE_MACHINE_AMD64 0x8664
#define IMAGE_NT_OPTIONAL_HDR64_MAGIC 0x20b
#define IMAGE_SCN_MEM_EXECUTE 0x20000000
#define IMAGE_SCN_MEM_WRITE 0x80000000
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define CC_SHA256_DIGEST_LENGTH 32
static unsigned char *CC_SHA256(const void *data, uint32_t len, unsigned char *md);
static int ios_sc_cef_enabled(void) { const char *e = getenv("MADEIRA_SC_CEF"); return !(e && e[0] == '0'); }
/* Test output contains no guest payload or addresses. */
#define dprintf(...) ((void)0)
'''


def link(folder, source, sections, symbols, defsym):
    """Assemble `source`, link each (section, address) and return section bytes and symbols."""
    script = 'SECTIONS { %s }\n' % ' '.join('%s 0x%x : { *(%s) }' % (s, a, s) for s, a in sections)
    script += '\n'.join('%s = %d;' % item for item in symbols.items()) + '\n'
    (folder / 'link.ld').write_text(script)
    subprocess.run(['as', '--64', *defsym, str(root / 'tests/host' / source), '-o', str(folder / 'a.o')], check=True)
    subprocess.run(['ld', '-T', str(folder / 'link.ld'), str(folder / 'a.o'), '-o', str(folder / 'a.elf')], check=True)
    out = {}
    for section, _ in sections:
        subprocess.run(['objcopy', '-O', 'binary', '--only-section=' + section,
                        str(folder / 'a.elf'), str(folder / 'a.bin')], check=True)
        out[section] = (folder / 'a.bin').read_bytes()
    table = subprocess.check_output(['nm', str(folder / 'a.elf')], text=True)
    names = {m[2]: int(m[1], 16) for m in re.finditer(r'(?m)^([\da-f]+) [Tt] (\w+)$', table)}
    return out, names


def check_build(index, build, folder):
    P = build['prefix']
    d = lambda name: define(P + name)
    table = code_table(build['table'])
    padding = padding_ranges(table)
    text_end = (0x1000 + build['text_vs'] + 0xfff) & ~0xfff
    data_end = (build['data'] + build['data_vs'] + 0xfff) & ~0xfff

    # --- the adapter and drain assemble to the production bytes at their RVAs ---
    loop_symbols = {
        'current_loop': d('CURRENT_LOOP'), 'helper_new': build['helper_new'],
        'loop_ctor': d('LOOP_CTOR'), 'original_webkit': d('WEBKIT'),
        'loop_work': d('LOOP_WORK'), 'loop_delayed': d('LOOP_DELAYED'),
        'loop_idle': d('LOOP_IDLE'), 'task': d('TASK'),
        'loop_cache': d('TASK') + 0x30, 'cef_post_delayed': d('POST_TASK'),
    }
    if build['diagnostics']:
        sections = [('.text', d('LOOP_INIT'))]
    else:
        sections = [('.text', d('LOOP_INIT')), ('.text.add_ref', d('TASK_ADD')), ('.text.release', d('TASK_RELEASE')),
                    ('.text.one_ref', d('TASK_ONE')), ('.text.any_ref', d('TASK_ANY'))]
    out, names = link(folder, 'sc-render-loop.S', sections, loop_symbols, build['defsym'])
    for (section, _), blob in zip(sections, build['loop']):
        assert out[section] == array_bytes(blob), (build['name'], section, 'assembly differs from production bytes')
    for symbol, macro in (
        ('sc_loop_init', 'LOOP_INIT'), ('sc_loop_pump', 'LOOP_PUMP'),
        ('sc_loop_add_ref', 'TASK_ADD'), ('sc_loop_release', 'TASK_RELEASE'),
        ('sc_loop_one_ref', 'TASK_ONE'), ('sc_loop_any_ref', 'TASK_ANY'),
    ):
        assert names[symbol] == d(macro), (build['name'], symbol)
    out, _ = link(folder, 'sc-render-drain.S', [('.text', d('RENDER_DRAIN'))],
                  {'current_loop': d('CURRENT_LOOP'), 'run_until_idle': build['run_until_idle']}, build['defsym'])
    assert out['.text'] == array_bytes(P.lower().rstrip('_') + '_render_drain')

    # --- every blob sits in its section's zero tail or in guarded RET+int3 padding ---
    blobs = re.search(r'ios_sch%s_blob\[\] =\n\{(.*?)\n\};' % build['suffix'], native, re.S)[1]
    placed = []
    entries = list(re.finditer(r'\{ (IOS_SCH\w+), (ios_sch\w+), sizeof\(\2\),\s*(0x[\da-f]+|0),\s*([01]),', blobs))
    assert len(entries) == blobs.count('{ IOS_SCH'), (build['name'], 'unparsed blob entries')
    for m in entries:
        rva, length, fill = define(m[1]), len(array_bytes(m[2])), int(m[3], 0)
        placed.append((rva, rva + length))
        if fill == 0:
            assert 0x1000 + build['text_vs'] <= rva and rva + length <= text_end, (build['name'], m[2])
        else:
            assert fill == 0xcc and any(p + 1 <= rva and rva + length <= p + n for p, n in padding), (build['name'], m[2])
    data_ranges = [(d('TASK'), 64), (d('IPC_CONTEXT'), 16), (d('CACHE'), 8)]
    if build['diagnostics']:
        data_ranges += [(d('RUN_RING'), d('RUN_RING_SIZE')), (d('IPC_COUNT'), 4), (d('UI_COUNT'), 4)]
    for rva, n in data_ranges:
        assert build['data'] + build['data_vs'] <= rva and rva + n <= data_end, (build['name'], hex(rva))
        placed.append((rva, rva + n))
    placed.sort()
    assert all(a[1] <= b[0] for a, b in zip(placed, placed[1:])), (build['name'], 'overlapping blobs')
    print('PASS: %s: assembly matches production bytes, entry RVAs and disjoint tail/padding ranges'
          % build['name'], flush=True)

    padding_c = 'static const unsigned int sch_padding_ranges[][2] = {%s};\n' % (
        ','.join('{0x%x,%d}' % p for p in padding) if padding else '{0,0}')
    defines = {
        'BUILD': index, 'B_STAMP': d('STAMP'), 'B_SIZE': d('SIZE'), 'B_TEXT_VS': build['text_vs'],
        'B_TEXT_RAW': build['text_raw'], 'B_DATA': build['data'], 'B_DATA_VS': build['data_vs'],
        'B_DATA_RAW': build['data_raw'], 'B_TEXT_END': text_end,
        'B_HELPER_NEW': build['helper_new'], 'B_RUN_UNTIL_IDLE': build['run_until_idle'],
        'B_GLOBAL_DRAIN': build['global_drain'], 'B_GLOBAL_LOOP': build['global_loop'],
    }
    for name in ('VT_BROWSER', 'VT_RENDERER', 'VT_RPH', 'GET_HANDLER', 'GET_NULL', 'WEBKIT', 'THUNK', 'CACHE',
                 'LOOP_INIT', 'LOOP_PUMP', 'TASK', 'TASK_ADD', 'TASK_RELEASE', 'TASK_ONE', 'TASK_ANY',
                 'CURRENT_LOOP', 'LOOP_CTOR', 'LOOP_WORK', 'LOOP_DELAYED', 'LOOP_IDLE', 'POST_TASK',
                 'RENDER_DRAIN', 'RENDER_DRAIN_SITE'):
        defines['B_' + name] = d(name)
    flags = ['-D%s=%d' % item for item in defines.items()]

    code = PRELUDE + function('static int ios_sc_path_is_helper(') + '\n' + region + '\n' + padding_c + \
        SHA_STANDIN + r'''
static IMAGE_NT_HEADERS nt;
static IMAGE_SECTION_HEADER sections[2];
static WCHAR helper_name[] = {'S','o','c','i','a','l','C','l','u','b','H','e','l','p','e','r','.','e','x','e'};
static UNICODE_STRING name = { helper_name, sizeof(helper_name) };
static void reset_image(char *image, uint64_t base)
{
    memset(image, 0, B_SIZE);
    nt = (IMAGE_NT_HEADERS){{ IMAGE_FILE_MACHINE_AMD64, 2, B_STAMP },
                           { IMAGE_NT_OPTIONAL_HDR64_MAGIC, B_SIZE }};
    sections[0] = (IMAGE_SECTION_HEADER){ IOS_SCH_TEXT, {B_TEXT_VS}, B_TEXT_RAW, IMAGE_SCN_MEM_EXECUTE };
    sections[1] = (IMAGE_SECTION_HEADER){ B_DATA, {B_DATA_VS}, B_DATA_RAW, IMAGE_SCN_MEM_WRITE };
    sch_fill(image);
    uint64_t *vb = (void *)(image + B_VT_BROWSER), *vr = (void *)(image + B_VT_RENDERER);
    vb[IOS_SCH_SLOT_BROWSER] = vr[IOS_SCH_SLOT_RENDERER] = base + B_GET_HANDLER;
    vb[IOS_SCH_SLOT_RENDERER] = vr[IOS_SCH_SLOT_BROWSER] = base + B_GET_NULL;
    *(uint64_t *)(image + B_VT_RPH) = base + B_WEBKIT;
}
static void reject_without_writes(char *image)
{
    char *before = malloc(B_SIZE);
    assert(before);
    memcpy(before, image, B_SIZE);
    ios_sc_render_handler_patch(image, B_SIZE, &nt, sections, &name);
    assert(!memcmp(before, image, B_SIZE));
    free(before);
}
/* A byte the patch may change: a blob, a hook span, a .data range or one of
 * the two vtable slots. Anything else differing is an undeclared write. */
static int declared(size_t rva, int ipc)
{
    const struct ios_sch_build *b = sch_build;
    for (size_t k = 0; k < b->blob_count; k++)
        if ((ipc || !b->blob[k].ipc) && rva >= b->blob[k].rva && rva < b->blob[k].rva + b->blob[k].len) return 1;
    for (size_t k = 0; k < b->hook_count; k++)
        if ((ipc || !b->hook[k].ipc) && rva >= b->hook[k].site && rva < b->hook[k].site + b->hook[k].span) return 1;
    if (rva >= b->task && rva < b->task + 64) return 1;
    if (rva >= b->vt_browser + 8 * IOS_SCH_SLOT_RENDERER && rva < b->vt_browser + 8 * IOS_SCH_SLOT_RENDERER + 8) return 1;
    if (rva >= b->vt_rph && rva < b->vt_rph + 8) return 1;
    return 0;
}
static void check_declared(const char *before, const char *image, int ipc)
{
    for (size_t rva = 0; rva < B_SIZE; rva++)
        if (before[rva] != image[rva]) assert(declared(rva, ipc));
}
struct Task;
struct RunState { uint32_t level, quit; void *dispatcher; };
struct Loop { unsigned char pad[0x128]; struct RunState *state; unsigned char tail[0x30]; };
struct Task {
    uint64_t size;
    void (ABI *add_ref)(struct Task *);
    int (ABI *release)(struct Task *), (ABI *one_ref)(struct Task *), (ABI *any_ref)(struct Task *);
    void (ABI *execute)(struct Task *);
    struct Loop *loop;
    uint32_t refs, padding;
};
_Static_assert(sizeof(struct Loop) == 0x160, "loop size");
_Static_assert(sizeof(struct Task) == 64 && offsetof(struct Task, loop) == 0x30 &&
               offsetof(struct Task, refs) == 0x38, "task layout");
static _Thread_local struct Loop *current;
static struct Task *task, *pending;
static pthread_t renderer;
static int allocations, constructions, originals, posts, allocation_fail, accept_post = 1;
static int queue, due, completed, delayed_completed, work_calls, delayed_calls, idle_calls;
static uint32_t expected_level = 1;
static void *expected_handler = (void *)0x12345678;
static struct Loop *browser_loop;
static struct RunState *browser_parent;
static void (ABI *drain_entry)(void);
static int startup_queue, startup_completed, drain_calls, nest_drain, nested_drains;
static struct Loop *ABI get_loop(void) { return current; }
static void *ABI helper_new(size_t size)
{
    assert(size == 0x160);
    allocations++;
    return allocation_fail ? NULL : calloc(1, size);
}
static struct Loop *ABI construct_loop(struct Loop *loop, int type)
{
    assert(type == 0 && !current && !loop->state);
    constructions++;
    return current = loop;
}
static void ABI run_until_idle(struct Loop *loop)
{
    assert(loop == current);
    if (pthread_equal(pthread_self(), renderer)) {
        /* The browser's pump is active while the renderer starts. The old
         * renderer call targets that global loop and fails this assertion. */
        assert(loop != browser_loop && browser_loop->state == browser_parent);
    }
    struct RunState *parent = loop->state;
    struct RunState scoped = {parent ? parent->level + 1 : 1, 1, NULL};
    loop->state = &scoped;
    drain_calls++;
    while (startup_queue) {
        startup_queue--;
        startup_completed++;
    }
    if (nest_drain) {
        nest_drain = 0;
        drain_entry();
        assert(loop->state == &scoped);
        nested_drains++;
    }
    assert(loop->state == &scoped);
    loop->state = parent;
}
static void ABI original_webkit(void *handler)
{
    assert(handler == expected_handler);
    assert(current || allocation_fail);
    originals++;
    drain_entry(); /* Execute the production-patched renderer CALL site. */
}
static void verify_loop(struct Loop *loop)
{
    assert(pthread_equal(pthread_self(), renderer));
    assert(loop == current && loop == task->loop);
    assert(loop->state && loop->state->level == expected_level);
    assert(!loop->state->quit && !loop->state->dispatcher);
}
static unsigned char ABI do_work(struct Loop *loop)
{
    verify_loop(loop);
    work_calls++;
    if (!queue) return 0;
    queue--; completed++;
    return 1;
}
static unsigned char ABI do_delayed(struct Loop *loop, uint64_t *next_due)
{
    verify_loop(loop);
    delayed_calls++;
    *next_due = 0;
    if (!due) return 0;
    due--; delayed_completed++;
    return 1;
}
static unsigned char ABI do_idle(struct Loop *loop)
{
    verify_loop(loop);
    idle_calls++;
    return 0;
}
static int ABI post_delayed(int thread, struct Task *posted, int64_t delay)
{
    assert(thread == 6 && delay == 10 && posted == task && task->size == 0x30);
    assert(pthread_equal(pthread_self(), renderer) && task->loop == current);
    posts++;
    if (!accept_post) return 0;
    assert(!pending);
    posted->add_ref(posted);
    pending = posted;
    return 1;
}
static void execute_pending(void)
{
    struct Task *running = pending;
    assert(running);
    pending = NULL;
    running->execute(running);
    assert(!running->release(running));
}
static void stub(char *image, size_t rva, uintptr_t target)
{
    unsigned char code[12] = {0x48, 0xb8, 0,0,0,0,0,0,0,0, 0xff,0xe0};
    memcpy(code + 2, &target, sizeof(target));
    memcpy(image + rva, code, sizeof(code));
}
static void *run_renderer(void *entry)
{
    void (ABI *initialize)(void *) = entry;
    renderer = pthread_self();
    assert(!current);
    startup_queue = 3;
    nest_drain = 1;
    initialize(expected_handler);
    assert(allocations == 1 && constructions == 1 && originals == 1 && posts == 1);
    assert(current && current == task->loop && task->refs == 2);
    assert(!current->state && !startup_queue && startup_completed == 3 &&
           drain_calls == 2 && nested_drains == 1 && browser_loop->state == browser_parent);
    struct Loop *owned = current;
    initialize(expected_handler);
    assert(allocations == 1 && constructions == 1 && originals == 2 && posts == 1);
    assert(drain_calls == 3);

    /* Tasks posted after IPC connects must run, including delayed callbacks. */
    queue = 3; due = 2;
    execute_pending();
    assert(completed == 3 && delayed_completed == 2 && !queue && !due && idle_calls == 1);
    assert(!current->state && pending == task && task->refs == 2);

    /* An IPC burst yields after 32 iterations instead of starving Chromium. */
    queue = 65;
    int before = work_calls;
    execute_pending();
    assert(queue == 33 && work_calls - before == 32 && !current->state);
    execute_pending();
    assert(queue == 1);
    execute_pending();
    assert(!queue && completed == 68 && idle_calls == 2);

    struct RunState parent = {4, 0, NULL};
    current->state = &parent;
    expected_level = 5;
    execute_pending();
    assert(current->state == &parent);
    current->state = NULL;
    expected_level = 1;

    /* CEF rejects posts during shutdown: no spin and no lost owner reference. */
    accept_post = 0;
    execute_pending();
    assert(!pending && !current->state && task->refs == 1);
    assert(task->one_ref(task) && task->any_ref(task));
    task->add_ref(task);
    assert(!task->one_ref(task) && task->any_ref(task) && task->refs == 2);
    assert(!task->release(task) && task->one_ref(task));

    allocation_fail = 1;
    current = NULL;
    before = posts;
    initialize(expected_handler);
    assert(allocations == 2 && constructions == 1 && originals == 3 && posts == before);
    assert(drain_calls == 3); /* No TLS loop: never borrow the browser's loop. */
    assert(task->loop == owned && !current);
    free(owned);
    task->loop = NULL;
    return NULL;
}
int main(int argc, char **argv)
{
    (void)argv;
    sch_build = &ios_sch_builds[BUILD];
    assert(sch_build->stamp == B_STAMP && sch_build->size == B_SIZE);
    for (size_t k = 0; k < ARRAY_SIZE(ios_sch_builds); k++)
        assert(k == BUILD || ios_sch_builds[k].stamp != B_STAMP);
    char *image = mmap(NULL, B_SIZE, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(image != MAP_FAILED);
    uint64_t view = (uintptr_t)image, got = 0;
    const struct ios_sch_build *found = NULL;
    reset_image(image, view);
    if (argc > 1 && !strcmp(argv[1], "disabled")) {
        reject_without_writes(image);
        assert(!munmap(image, B_SIZE));
        puts("PASS: disabled renderer/CEF adapter leaves the image unchanged");
        return 0;
    }
    assert(!ios_sch_mismatch(image, B_SIZE, &nt, sections, &found, &got) && got == view && found == sch_build);
    nt.FileHeader.TimeDateStamp ^= 1; reject_without_writes(image);
    reset_image(image, view); nt.OptionalHeader.SizeOfImage++; reject_without_writes(image);
    reset_image(image, view); sections[0].Misc.VirtualSize++; reject_without_writes(image);
    reset_image(image, view); sections[0].SizeOfRawData += 0x200; reject_without_writes(image);
    reset_image(image, view); sections[1].Characteristics = 0; reject_without_writes(image);
    reset_image(image, view); sections[1].Misc.VirtualSize++; reject_without_writes(image);
    for (size_t i = 0; i < sch_build->code_count; i++) {
        reset_image(image, view); image[sch_build->code[i].rva] ^= 1; reject_without_writes(image);
        reset_image(image, view); image[sch_build->code[i].rva + sch_build->code[i].len - 1] ^= 1;
        reject_without_writes(image);
    }
    /* Every blob destination (zero tail or int3 padding) and .data range,
     * first and last byte. */
    for (size_t i = 0; i < sch_build->blob_count; i++) {
        reset_image(image, view); image[sch_build->blob[i].rva] ^= 1; reject_without_writes(image);
        reset_image(image, view); image[sch_build->blob[i].rva + sch_build->blob[i].len - 1] ^= 1;
        reject_without_writes(image);
    }
    for (size_t i = 0; i < sch_build->zero_count; i++) {
        reset_image(image, view); image[sch_build->zero[i].rva] ^= 1; reject_without_writes(image);
        reset_image(image, view); image[sch_build->zero[i].rva + sch_build->zero[i].len - 1] ^= 1;
        reject_without_writes(image);
    }
    reset_image(image, view); image[B_THUNK] ^= 1; reject_without_writes(image);
    reset_image(image, view); image[B_TASK + 63] ^= 1; reject_without_writes(image);
    reset_image(image, view); image[B_CACHE] ^= 1; reject_without_writes(image);
    reset_image(image, view); image[B_VT_RPH] ^= 1; reject_without_writes(image);
    reset_image(image, view);
    *(uint64_t *)(image + B_VT_BROWSER + IOS_SCH_SLOT_BROWSER * 8) = 0x13370000;
    reject_without_writes(image);
    reset_image(image, view);
    *(uint64_t *)(image + B_VT_RENDERER + IOS_SCH_SLOT_RENDERER * 8) += 0x10;
    reject_without_writes(image);
    reset_image(image, view);
    char *before = malloc(B_SIZE);
    assert(before);
    memcpy(before, image, B_SIZE);
    ios_sc_render_handler_patch(image, B_SIZE, &nt, sections, &name);
    check_declared(before, image, 1);
    for (size_t i = 0; i < sch_build->blob_count; i++)
        assert(!memcmp(image + sch_build->blob[i].rva, sch_build->blob[i].code, sch_build->blob[i].len));
    for (size_t i = 0; i < sch_build->hook_count; i++) {
        const struct ios_sch_hook *h = &sch_build->hook[i];
        int32_t displacement = 0;
        assert((unsigned char)image[h->site] == h->opcode && (h->opcode == 0xe8 || h->opcode == 0xe9));
        memcpy(&displacement, image + h->site + 1, sizeof(displacement));
        assert(h->site + 5 + displacement == h->dest);
        for (size_t j = 5; j < h->span; j++) assert((unsigned char)image[h->site + j] == 0x90);
        /* the destination is the entry of one of this build's blobs */
        int entry = 0;
        for (size_t k = 0; k < sch_build->blob_count; k++)
            if (h->dest >= sch_build->blob[k].rva && h->dest < sch_build->blob[k].rva + sch_build->blob[k].len) entry = 1;
        assert(entry);
    }
    int32_t drain_disp = 0;
    assert((unsigned char)image[B_RENDER_DRAIN_SITE] == 0xe8);
    memcpy(&drain_disp, image + B_RENDER_DRAIN_SITE + 1, sizeof(drain_disp));
    assert(B_RENDER_DRAIN_SITE + 5 + drain_disp == B_RENDER_DRAIN);
    task = (void *)(image + B_TASK);
    assert(*(uint64_t *)(image + B_VT_RPH) == view + B_LOOP_INIT);
    assert(*(uint64_t *)(image + B_VT_BROWSER + IOS_SCH_SLOT_RENDERER * 8) == view + B_THUNK);
    assert((uintptr_t)task->execute == view + B_LOOP_PUMP);
    reset_image(image, view);
    setenv("MADEIRA_SC_IPC_SPLIT", "0", 1);
    memcpy(before, image, B_SIZE);
    ios_sc_render_handler_patch(image, B_SIZE, &nt, sections, &name);
    unsetenv("MADEIRA_SC_IPC_SPLIT");
    check_declared(before, image, 0);
    for (size_t i = 0; i < sch_build->blob_count; i++)
        if (sch_build->blob[i].ipc)
            assert(!memcmp(image + sch_build->blob[i].rva, before + sch_build->blob[i].rva, sch_build->blob[i].len));
    assert(*(uint64_t *)(image + B_VT_RPH) == view + B_LOOP_INIT);
    free(before);
    reset_image(image, IOS_SCH_IMAGE_BASE);
    assert(!ios_sch_mismatch(image, B_SIZE, &nt, sections, &found, &got) && got == IOS_SCH_IMAGE_BASE);
    ios_sc_render_handler_patch(image, B_SIZE, &nt, sections, &name);
    assert(*(uint64_t *)(image + B_VT_RPH) == IOS_SCH_IMAGE_BASE + B_LOOP_INIT);
    task = (void *)(image + B_TASK);
    assert((uintptr_t)task->add_ref == view + B_TASK_ADD);
    assert((uintptr_t)task->release == view + B_TASK_RELEASE);
    assert((uintptr_t)task->one_ref == view + B_TASK_ONE);
    assert((uintptr_t)task->any_ref == view + B_TASK_ANY);
    assert((uintptr_t)task->execute == view + B_LOOP_PUMP);
    /* The pool's existing DIR64 entries rebase the vtable slots only. The
     * new data-tail task has no relocation entries, as in the helper image. */
    *(uint64_t *)(image + B_VT_BROWSER + IOS_SCH_SLOT_RENDERER * 8) += view - IOS_SCH_IMAGE_BASE;
    *(uint64_t *)(image + B_VT_RPH) += view - IOS_SCH_IMAGE_BASE;
    puts("PASS: production patch accepts view/preferred bases, writes only its declared ranges and rejects changed code/layout/tails without writes");

    stub(image, B_CURRENT_LOOP, (uintptr_t)get_loop);
    stub(image, B_HELPER_NEW, (uintptr_t)helper_new);
    stub(image, B_LOOP_CTOR, (uintptr_t)construct_loop);
    stub(image, B_WEBKIT, (uintptr_t)original_webkit);
    stub(image, B_LOOP_WORK, (uintptr_t)do_work);
    stub(image, B_LOOP_DELAYED, (uintptr_t)do_delayed);
    stub(image, B_LOOP_IDLE, (uintptr_t)do_idle);
    stub(image, B_RUN_UNTIL_IDLE, (uintptr_t)run_until_idle);
    /* The browser's global drain, as a stand-in (the helper's own bytes stay out
     * of the tree, the image holds the filler): RunUntilIdle on the loop the
     * process-wide slot holds. mov rcx, [rip + slot]; jmp RunUntilIdle */
    unsigned char global_drain[12] = {0x48,0x8b,0x0d,0,0,0,0,0xe9,0,0,0,0};
    int32_t slot_disp = B_GLOBAL_LOOP - (B_GLOBAL_DRAIN + 7), run_disp = B_RUN_UNTIL_IDLE - (B_GLOBAL_DRAIN + 12);
    memcpy(global_drain + 3, &slot_disp, sizeof(slot_disp));
    memcpy(global_drain + 8, &run_disp, sizeof(run_disp));
    memcpy(image + B_GLOBAL_DRAIN, global_drain, sizeof(global_drain));
    /* Self-written call-frame fixture around the real patched CALL. */
    const unsigned char enter[] = {0x48,0x83,0xec,0x28};
    const unsigned char leave[] = {0x48,0x83,0xc4,0x28,0xc3};
    memcpy(image + B_RENDER_DRAIN_SITE - sizeof(enter), enter, sizeof(enter));
    memcpy(image + B_RENDER_DRAIN_SITE + 5, leave, sizeof(leave));
    drain_entry = (void *)(image + B_RENDER_DRAIN_SITE - sizeof(enter));
    if (argc > 1 && !strcmp(argv[1], "legacy-drain")) {
        /* Control: the original global drain must fail the TLS ownership
         * check while the browser's state is active on the other thread. */
        int32_t old_disp = B_GLOBAL_DRAIN - B_RENDER_DRAIN_SITE - 5;
        memcpy(image + B_RENDER_DRAIN_SITE + 1, &old_disp, sizeof(old_disp));
    }
    *(uintptr_t *)(image + B_POST_TASK) = (uintptr_t)post_delayed;
    assert(!mprotect(image + 0x1000, B_TEXT_END - 0x1000, PROT_READ | PROT_EXEC));
    struct Loop browser = {0};
    struct RunState active_browser = {7, 0, (void *)0x87654321};
    browser.state = &active_browser;
    browser_loop = &browser;
    browser_parent = &active_browser;
    *(struct Loop **)(image + B_GLOBAL_LOOP) = &browser;
    current = &browser;
    pthread_t thread;
    void *initialize = (void *)(uintptr_t)*(uint64_t *)(image + B_VT_RPH);
    assert(initialize == image + B_LOOP_INIT);
    assert(!pthread_create(&thread, NULL, run_renderer, initialize));
    assert(!pthread_join(thread, NULL));
    assert(current == &browser); /* Renderer initialization never borrows browser TLS. */
    assert(browser.state == browser_parent && active_browser.level == 7 &&
           !active_browser.quit && active_browser.dispatcher == (void *)0x87654321);
    allocation_fail = 0;
    int before_posts = posts;
    ((void (ABI *)(void *))(image + B_LOOP_INIT))(expected_handler);
    assert(current == &browser && posts == before_posts && constructions == 1);
    assert(browser.state == browser_parent && drain_calls == 4);
    ((void (ABI *)(void))(image + B_GLOBAL_DRAIN))(); /* Browser's original global drain still works. */
    assert(browser.state == browser_parent && drain_calls == 5);
    assert(!munmap(image, B_SIZE));
    puts("PASS: preferred vtables + unrelocated task callbacks execute; TLS, IPC work/timers, bounds, refs and shutdown");
    puts("PASS: renderer startup drains its TLS work, nested states restore, active browser state stays intact");
    return 0;
}
'''

    driver = folder / 'test.c'
    driver.write_text(code)
    binary = folder / 'test'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-O2', '-fsanitize=address,undefined', '-g', '-pthread', *flags, str(driver),
                    '-o', str(binary)], check=True)
    print('--- %s' % build['name'], flush=True)
    subprocess.run([str(binary)], check=True)
    legacy = subprocess.run([str(binary), 'legacy-drain'], capture_output=True, text=True,
                            preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
    assert legacy.returncode != 0 and 'loop == current' in legacy.stderr, legacy.stderr
    print('PASS: %s: original renderer CALL fails the cross-thread TLS ownership control' % build['name'], flush=True)
    for variable in ('MADEIRA_SC_RENDER_HANDLER', 'MADEIRA_SC_CEF'):
        subprocess.run([str(binary), 'disabled'], check=True, env={**os.environ, variable: '0'})


with tempfile.TemporaryDirectory(prefix='madeira-sc-loop-') as name:
    builds = re.search(r'ios_sch_builds\[\] =\n\{(.*?)\n\};', native, re.S)[1]
    assert re.findall(r'\n    \{ (IOS_SCH\w*?)STAMP,', builds) == [b['prefix'] for b in BUILDS], \
        'every analysed build has a fixture, in table order'
    for index, build in enumerate(BUILDS):
        check_build(index, build, Path(name))
