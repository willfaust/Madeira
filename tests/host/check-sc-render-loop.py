#!/usr/bin/env python3
"""Execute the production Win64 adapter against a thread-local IPC loop fixture.

Also compile the actual image guard/patch, test both vtable pointer bases and
reject mismatched images without writes. Exercise the preferred-base case with
DIR64 rebasing of the existing vtable slots, without relocations for the new
task callbacks: those must already name the mapped image. No supplied binary.
Requires x86_64 Linux, GNU binutils, Python and a C compiler.
"""
from pathlib import Path
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


def array(name):
    start = native.index('static const unsigned char ' + name + '[')
    return native[start:native.index('};', start) + 2]


blob = bytes(int(x, 16) for x in re.findall(r'0x([\da-fA-F]{2})', array('ios_sch_loop_thunk')))
start = native.index('static const struct { unsigned int rva;')
code_table = native[start:native.index('};', start) + 2]
# The helper's code stays out of the tree: ios_sch_code holds each range's SHA-256.
# The fixture image holds a filler in each range instead, and this stand-in for
# CommonCrypto answers a range's own digest exactly while its filler is intact.
SHA_STANDIN = r'''
static char *sch_fixture_image;
static unsigned char sch_filler(size_t rva, size_t i) { return (unsigned char)((rva + i) * 131u + 7u); }
static void sch_fill(char *image)
{
    sch_fixture_image = image;
    for (size_t k = 0; k < ARRAY_SIZE(ios_sch_code); k++)
        for (size_t i = 0; i < ios_sch_code[k].len; i++)
            image[ios_sch_code[k].rva + i] = (char)sch_filler(ios_sch_code[k].rva, i);
}
static unsigned char *CC_SHA256(const void *data, uint32_t len, unsigned char *md)
{
    memset(md, 0, CC_SHA256_DIGEST_LENGTH);
    for (size_t k = 0; k < ARRAY_SIZE(ios_sch_code); k++)
    {
        const unsigned char *p = (const unsigned char *)sch_fixture_image + ios_sch_code[k].rva;
        size_t i;
        if ((const void *)p != data || len != ios_sch_code[k].len) continue;
        for (i = 0; i < len && p[i] == sch_filler(ios_sch_code[k].rva, i); i++) ;
        if (i == len) memcpy(md, ios_sch_code[k].sha256, CC_SHA256_DIGEST_LENGTH);
    }
    return md;
}
'''

defines = '\n'.join(line for line in native.splitlines() if line.startswith('#define IOS_SCH_'))
symbols = {
    'current_loop': define('IOS_SCH_CURRENT_LOOP'), 'helper_new': 0x13e708,
    'loop_ctor': define('IOS_SCH_LOOP_CTOR'), 'original_webkit': define('IOS_SCH_WEBKIT'),
    'loop_work': define('IOS_SCH_LOOP_WORK'), 'loop_delayed': define('IOS_SCH_LOOP_DELAYED'),
    'loop_idle': define('IOS_SCH_LOOP_IDLE'), 'task': define('IOS_SCH_TASK'),
    'loop_cache': define('IOS_SCH_TASK') + 0x30, 'cef_post_delayed': define('IOS_SCH_POST_TASK'),
}

with tempfile.TemporaryDirectory(prefix='madeira-sc-loop-') as name:
    folder = Path(name)
    linker = folder / 'loop.ld'
    linker.write_text('SECTIONS { . = %d; .text : { *(.text) } }\n' % define('IOS_SCH_LOOP_INIT') +
                      '\n'.join('%s = %d;' % item for item in symbols.items()) + '\n')
    subprocess.run(['as', '--64', str(root / 'tests/host/sc-render-loop.S'),
                    '-o', str(folder / 'loop.o')], check=True)
    subprocess.run(['ld', '-T', str(linker), str(folder / 'loop.o'),
                    '-o', str(folder / 'loop.elf')], check=True)
    subprocess.run(['objcopy', '-O', 'binary', '--only-section=.text',
                    str(folder / 'loop.elf'), str(folder / 'loop.bin')], check=True)
    assert (folder / 'loop.bin').read_bytes() == blob, 'assembly differs from production bytes'
    table = subprocess.check_output(['nm', str(folder / 'loop.elf')], text=True)
    for symbol, macro in (
        ('sc_loop_init', 'IOS_SCH_LOOP_INIT'), ('sc_loop_pump', 'IOS_SCH_LOOP_PUMP'),
        ('sc_loop_add_ref', 'IOS_SCH_TASK_ADD'), ('sc_loop_release', 'IOS_SCH_TASK_RELEASE'),
        ('sc_loop_one_ref', 'IOS_SCH_TASK_ONE'), ('sc_loop_any_ref', 'IOS_SCH_TASK_ANY'),
    ):
        assert int(re.search(r'([\da-f]+) T ' + symbol + r'\b', table)[1], 16) == define(macro)
    assert define('IOS_SCH_THUNK') + 112 <= define('IOS_SCH_LOOP_INIT')
    assert 0x180400 <= define('IOS_SCH_LOOP_INIT') < define('IOS_SCH_LOOP_INIT') + len(blob) <= 0x181000
    assert 0x1d03bc <= define('IOS_SCH_TASK') < define('IOS_SCH_TASK') + 64 <= define('IOS_SCH_CACHE')
    print('PASS: assembly matches production bytes, entry RVAs and disjoint zero-tail ranges', flush=True)

    drain_linker = folder / 'drain.ld'
    drain_linker.write_text('SECTIONS { . = %d; .text : { *(.text) } }\n' % define('IOS_SCH_RENDER_DRAIN') +
                           'current_loop = %d; run_until_idle = 0x1728b0;\n' % define('IOS_SCH_CURRENT_LOOP'))
    subprocess.run(['as', '--64', str(root / 'tests/host/sc-render-drain.S'),
                    '-o', str(folder / 'drain.o')], check=True)
    subprocess.run(['ld', '-T', str(drain_linker), str(folder / 'drain.o'),
                    '-o', str(folder / 'drain.elf')], check=True)
    subprocess.run(['objcopy', '-O', 'binary', '--only-section=.text',
                    str(folder / 'drain.elf'), str(folder / 'drain.bin')], check=True)
    drain_blob = bytes(int(x, 16) for x in re.findall(r'0x([\da-fA-F]{2})', array('ios_sch_render_drain')))
    assert (folder / 'drain.bin').read_bytes() == drain_blob
    trace_blob = bytes(int(x, 16) for x in re.findall(r'0x([\da-fA-F]{2})', array('ios_sch_run_trace')))
    assert define('IOS_SCH_RUN_INSTALL') + len(trace_blob) <= define('IOS_SCH_RENDER_DRAIN')
    assert define('IOS_SCH_RENDER_DRAIN') + len(drain_blob) <= 0x181000

    code = r'''
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
''' + defines + '\n' + array('ios_sch_thunk') + '\n' + array('ios_sch_loop_thunk') + '\n' + array('ios_sch_run_trace') + '\n' + array('ios_sch_render_drain') + '\n' + array('ios_sch_ipc_rebind') + '\n' + array('ios_sch_ipc_split') + '\n' + array('ios_sch_ui_trace') + '\n' + array('ios_sch_renderer_channels') + '\n' + code_table + '\n' + SHA_STANDIN + '\n' + function('static int ios_sc_path_is_helper(') + '\n' + function('static const char *ios_sch_mismatch(') + '\n' + function('static void ios_sc_render_handler_patch(') + r'''
static IMAGE_NT_HEADERS nt;
static IMAGE_SECTION_HEADER sections[2];
static WCHAR helper_name[] = {'S','o','c','i','a','l','C','l','u','b','H','e','l','p','e','r','.','e','x','e'};
static UNICODE_STRING name = { helper_name, sizeof(helper_name) };
static void reset_image(char *image, uint64_t base)
{
    memset(image, 0, IOS_SCH_SIZE);
    nt = (IMAGE_NT_HEADERS){{ IMAGE_FILE_MACHINE_AMD64, 2, IOS_SCH_STAMP },
                           { IMAGE_NT_OPTIONAL_HDR64_MAGIC, IOS_SCH_SIZE }};
    sections[0] = (IMAGE_SECTION_HEADER){ IOS_SCH_TEXT, {0x17f34c}, 0x17f400, IMAGE_SCN_MEM_EXECUTE };
    sections[1] = (IMAGE_SECTION_HEADER){ IOS_SCH_DATA, {0x43bc}, 0x1a00, IMAGE_SCN_MEM_WRITE };
    sch_fill(image);
    uint64_t *vb = (void *)(image + IOS_SCH_VT_BROWSER), *vr = (void *)(image + IOS_SCH_VT_RENDERER);
    vb[IOS_SCH_SLOT_BROWSER] = vr[IOS_SCH_SLOT_RENDERER] = base + IOS_SCH_GET_HANDLER;
    vb[IOS_SCH_SLOT_RENDERER] = vr[IOS_SCH_SLOT_BROWSER] = base + IOS_SCH_GET_NULL;
    *(uint64_t *)(image + IOS_SCH_VT_RPH) = base + IOS_SCH_WEBKIT;
}
static void reject_without_writes(char *image)
{
    char *before = malloc(IOS_SCH_SIZE);
    assert(before);
    memcpy(before, image, IOS_SCH_SIZE);
    ios_sc_render_handler_patch(image, IOS_SCH_SIZE, &nt, sections, &name);
    assert(!memcmp(before, image, IOS_SCH_SIZE));
    free(before);
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
    char *image = mmap(NULL, IOS_SCH_SIZE, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(image != MAP_FAILED);
    uint64_t view = (uintptr_t)image, got = 0;
    reset_image(image, view);
    if (argc > 1 && !strcmp(argv[1], "disabled")) {
        reject_without_writes(image);
        assert(!munmap(image, IOS_SCH_SIZE));
        puts("PASS: disabled renderer/CEF adapter leaves the image unchanged");
        return 0;
    }
    assert(!ios_sch_mismatch(image, IOS_SCH_SIZE, &nt, sections, &got) && got == view);
    nt.FileHeader.TimeDateStamp ^= 1; reject_without_writes(image);
    reset_image(image, view); nt.OptionalHeader.SizeOfImage++; reject_without_writes(image);
    reset_image(image, view); sections[0].Misc.VirtualSize++; reject_without_writes(image);
    reset_image(image, view); sections[1].Characteristics = 0; reject_without_writes(image);
    for (size_t i = 0; i < sizeof(ios_sch_code) / sizeof(ios_sch_code[0]); i++) {
        reset_image(image, view); image[ios_sch_code[i].rva] ^= 1; reject_without_writes(image);
    }
    const size_t dirty[] = { IOS_SCH_THUNK, IOS_SCH_LOOP_INIT, IOS_SCH_TASK,
                            IOS_SCH_RENDER_CHANNEL_THUNK,
                            IOS_SCH_RENDER_CHANNEL_THUNK + sizeof(ios_sch_renderer_channels) - 1,
                            IOS_SCH_TASK + 63, IOS_SCH_CACHE, IOS_SCH_VT_RPH, IOS_SCH_RUN_INSTALL,
                            IOS_SCH_RUN_INSTALL + sizeof(ios_sch_run_trace) - 1,
                            IOS_SCH_RUN_RING, IOS_SCH_RUN_RING + IOS_SCH_RUN_RING_SIZE - 1,
                            IOS_SCH_RENDER_DRAIN, IOS_SCH_RENDER_DRAIN + sizeof(ios_sch_render_drain) - 1,
                            IOS_SCH_IPC_TRACE, IOS_SCH_IPC_TRACE + sizeof(ios_sch_ipc_rebind) - 1,
                            IOS_SCH_IPC_COUNT, IOS_SCH_IPC_COUNT + 3,
                            IOS_SCH_IPC_SPLIT, IOS_SCH_IPC_SPLIT + sizeof(ios_sch_ipc_split) - 1,
                            IOS_SCH_IPC_CONTEXT, IOS_SCH_IPC_CONTEXT + 15,
                            IOS_SCH_UI_TRACE, IOS_SCH_UI_TRACE + sizeof(ios_sch_ui_trace) - 1,
                            IOS_SCH_UI_COUNT, IOS_SCH_UI_COUNT + 3 };
    for (size_t i = 0; i < sizeof(dirty) / sizeof(dirty[0]); i++) {
        reset_image(image, view); image[dirty[i]] ^= 1; reject_without_writes(image);
    }
    reset_image(image, view);
    *(uint64_t *)(image + IOS_SCH_VT_BROWSER + IOS_SCH_SLOT_BROWSER * 8) = 0x13370000;
    reject_without_writes(image);
    reset_image(image, view);
    ios_sc_render_handler_patch(image, IOS_SCH_SIZE, &nt, sections, &name);
    int32_t drain_disp = 0;
    assert((unsigned char)image[IOS_SCH_RENDER_DRAIN_SITE] == 0xe8);
    memcpy(&drain_disp, image + IOS_SCH_RENDER_DRAIN_SITE + 1, sizeof(drain_disp));
    assert(IOS_SCH_RENDER_DRAIN_SITE + 5 + drain_disp == IOS_SCH_RENDER_DRAIN);
    assert(!memcmp(image + IOS_SCH_RENDER_DRAIN, ios_sch_render_drain, sizeof(ios_sch_render_drain)));
    int32_t ipc_disp = 0;
    assert((unsigned char)image[IOS_SCH_IPC_CONNECT] == 0xe9);
    memcpy(&ipc_disp, image + IOS_SCH_IPC_CONNECT + 1, sizeof(ipc_disp));
    assert(IOS_SCH_IPC_CONNECT + 5 + ipc_disp == IOS_SCH_IPC_TRACE);
    assert(!memcmp(image + IOS_SCH_IPC_TRACE, ios_sch_ipc_rebind, sizeof(ios_sch_ipc_rebind)));
    assert(!memcmp(image + IOS_SCH_IPC_SPLIT, ios_sch_ipc_split, sizeof(ios_sch_ipc_split)));
    const size_t split_sites[] = {0x4b290, 0x4ba50, 0x4a5c3, 0x4baab, 0x4d255, 0x4d2fb, 0x4a719, 0x4da6c};
    const size_t split_entries[] = {IOS_SCH_IPC_SPLIT, IOS_SCH_IPC_CAPTURE, IOS_SCH_IPC_STORE,
        IOS_SCH_IPC_ROLE, IOS_SCH_IPC_GLOBAL_LOOP, IOS_SCH_IPC_INITIAL_CONNECT, IOS_SCH_IPC_DESTROY,
        IOS_SCH_IPC_DIRECT};
    for (size_t i = 0; i < ARRAY_SIZE(split_sites); i++) {
        int32_t displacement = 0;
        assert((unsigned char)image[split_sites[i]] == ((i == 4 || i == 5) ? 0xe8 : 0xe9));
        memcpy(&displacement, image + split_sites[i] + 1, sizeof(displacement));
        assert(split_sites[i] + 5 + displacement == split_entries[i]);
    }
    const size_t trace_sites[] = {0x174121, 0x17412b};
    const size_t trace_entries[] = {IOS_SCH_RUN_INSTALL, IOS_SCH_RUN_RESTORE};
    const size_t trace_spans[] = {7, 9};
    assert(!memcmp(image + IOS_SCH_RUN_INSTALL, ios_sch_run_trace, sizeof(ios_sch_run_trace)));
    for (size_t i = 0; i < 2; i++) {
        int32_t displacement = 0;
        assert((unsigned char)image[trace_sites[i]] == 0xe9);
        memcpy(&displacement, image + trace_sites[i] + 1, sizeof(displacement));
        assert(trace_sites[i] + 5 + displacement == trace_entries[i]);
        for (size_t j = 5; j < trace_spans[i]; j++)
            assert((unsigned char)image[trace_sites[i] + j] == 0x90);
    }
    task = (void *)(image + IOS_SCH_TASK);
    assert(*(uint64_t *)(image + IOS_SCH_VT_RPH) == view + IOS_SCH_LOOP_INIT);
    assert((uintptr_t)task->execute == view + IOS_SCH_LOOP_PUMP);
    reset_image(image, IOS_SCH_IMAGE_BASE);
    assert(!ios_sch_mismatch(image, IOS_SCH_SIZE, &nt, sections, &got) && got == IOS_SCH_IMAGE_BASE);
    ios_sc_render_handler_patch(image, IOS_SCH_SIZE, &nt, sections, &name);
    assert(*(uint64_t *)(image + IOS_SCH_VT_RPH) == IOS_SCH_IMAGE_BASE + IOS_SCH_LOOP_INIT);
    task = (void *)(image + IOS_SCH_TASK);
    assert((uintptr_t)task->add_ref == view + IOS_SCH_TASK_ADD);
    assert((uintptr_t)task->release == view + IOS_SCH_TASK_RELEASE);
    assert((uintptr_t)task->one_ref == view + IOS_SCH_TASK_ONE);
    assert((uintptr_t)task->any_ref == view + IOS_SCH_TASK_ANY);
    assert((uintptr_t)task->execute == view + IOS_SCH_LOOP_PUMP);
    /* The pool's existing DIR64 entries rebase the vtable slots only. The
     * new data-tail task has no relocation entries, as in the helper image. */
    *(uint64_t *)(image + IOS_SCH_VT_BROWSER + IOS_SCH_SLOT_RENDERER * 8) += view - IOS_SCH_IMAGE_BASE;
    *(uint64_t *)(image + IOS_SCH_VT_RPH) += view - IOS_SCH_IMAGE_BASE;
    assert(!memcmp(image + IOS_SCH_LOOP_INIT, ios_sch_loop_thunk, sizeof(ios_sch_loop_thunk)));
    puts("PASS: production patch accepts view/preferred bases and rejects changed code/layout/tails without writes");

    stub(image, IOS_SCH_CURRENT_LOOP, (uintptr_t)get_loop);
    stub(image, 0x13e708, (uintptr_t)helper_new);
    stub(image, IOS_SCH_LOOP_CTOR, (uintptr_t)construct_loop);
    stub(image, IOS_SCH_WEBKIT, (uintptr_t)original_webkit);
    stub(image, IOS_SCH_LOOP_WORK, (uintptr_t)do_work);
    stub(image, IOS_SCH_LOOP_DELAYED, (uintptr_t)do_delayed);
    stub(image, IOS_SCH_LOOP_IDLE, (uintptr_t)do_idle);
    stub(image, 0x1728b0, (uintptr_t)run_until_idle);
    /* The browser's global drain, as a stand-in (the helper's own bytes stay out
     * of the tree, the image holds the filler): RunUntilIdle on the loop the
     * process-wide slot holds. mov rcx, [rip + slot]; jmp RunUntilIdle */
    unsigned char global_drain[12] = {0x48,0x8b,0x0d,0,0,0,0,0xe9,0,0,0,0};
    int32_t slot_disp = 0x1cea00 - (0x11be60 + 7), run_disp = 0x1728b0 - (0x11be60 + 12);
    memcpy(global_drain + 3, &slot_disp, sizeof(slot_disp));
    memcpy(global_drain + 8, &run_disp, sizeof(run_disp));
    memcpy(image + 0x11be60, global_drain, sizeof(global_drain));
    /* Self-written call-frame fixture around the real patched CALL. */
    const unsigned char enter[] = {0x48,0x83,0xec,0x28};
    const unsigned char leave[] = {0x48,0x83,0xc4,0x28,0xc3};
    memcpy(image + IOS_SCH_RENDER_DRAIN_SITE - sizeof(enter), enter, sizeof(enter));
    memcpy(image + IOS_SCH_RENDER_DRAIN_SITE + 5, leave, sizeof(leave));
    drain_entry = (void *)(image + IOS_SCH_RENDER_DRAIN_SITE - sizeof(enter));
    if (argc > 1 && !strcmp(argv[1], "legacy-drain")) {
        /* Control: the original global drain must fail the TLS ownership
         * check while the browser's state is active on the other thread. */
        int32_t old_disp = 0x11be60 - IOS_SCH_RENDER_DRAIN_SITE - 5;
        memcpy(image + IOS_SCH_RENDER_DRAIN_SITE + 1, &old_disp, sizeof(old_disp));
    }
    *(uintptr_t *)(image + IOS_SCH_POST_TASK) = (uintptr_t)post_delayed;
    assert(!mprotect(image + 0x1000, 0x180000, PROT_READ | PROT_EXEC));
    struct Loop browser = {0};
    struct RunState active_browser = {7, 0, (void *)0x87654321};
    browser.state = &active_browser;
    browser_loop = &browser;
    browser_parent = &active_browser;
    *(struct Loop **)(image + 0x1cea00) = &browser;
    current = &browser;
    pthread_t thread;
    void *initialize = (void *)(uintptr_t)*(uint64_t *)(image + IOS_SCH_VT_RPH);
    assert(initialize == image + IOS_SCH_LOOP_INIT);
    assert(!pthread_create(&thread, NULL, run_renderer, initialize));
    assert(!pthread_join(thread, NULL));
    assert(current == &browser); /* Renderer initialization never borrows browser TLS. */
    assert(browser.state == browser_parent && active_browser.level == 7 &&
           !active_browser.quit && active_browser.dispatcher == (void *)0x87654321);
    allocation_fail = 0;
    int before = posts;
    ((void (ABI *)(void *))(image + IOS_SCH_LOOP_INIT))(expected_handler);
    assert(current == &browser && posts == before && constructions == 1);
    assert(browser.state == browser_parent && drain_calls == 4);
    ((void (ABI *)(void))(image + 0x11be60))(); /* Browser's original global drain still works. */
    assert(browser.state == browser_parent && drain_calls == 5);
    assert(!munmap(image, IOS_SCH_SIZE));
    puts("PASS: preferred vtables + unrelocated task callbacks execute; TLS, IPC work/timers, bounds, refs and shutdown");
    puts("PASS: renderer startup drains its TLS work, nested states restore, active browser state stays intact");
    return 0;
}
'''

    driver = folder / 'test.c'
    driver.write_text(code)
    binary = folder / 'test'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-O2', '-fsanitize=address,undefined', '-g', '-pthread', str(driver),
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    legacy = subprocess.run([str(binary), 'legacy-drain'], capture_output=True, text=True,
                            preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
    assert legacy.returncode != 0 and 'loop == current' in legacy.stderr, legacy.stderr
    print('PASS: original renderer CALL fails the cross-thread TLS ownership control', flush=True)
    for variable in ('MADEIRA_SC_RENDER_HANDLER', 'MADEIRA_SC_CEF'):
        subprocess.run([str(binary), 'disabled'], check=True, env={**os.environ, variable: '0'})
