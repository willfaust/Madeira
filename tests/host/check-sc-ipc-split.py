#!/usr/bin/env python3
"""Execute the production manager split against two Win64 IPC endpoints.

Use the actual image guard/patch and assembled production hooks. The fixture
models the helper ABI, consumed CefRefPtr, per-thread manager, initialization
reentry, handlers and ordered destruction; no supplied binary is executed.
"""
from pathlib import Path
import os
import re
import resource
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def define(name):
    return int(re.search(r'#define ' + name + r'\s+(0x[\da-fA-F]+|\d+)', native)[1], 0)


def array(name):
    start = native.index('static const unsigned char ' + name + '[')
    return native[start:native.index('};', start) + 2]


def function(signature):
    start = native.index(signature)
    return native[start:native.index('\n}', start) + 2]


start = native.index('static const struct { unsigned int rva;')
guards = native[start:native.index('};', start) + 2]
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
defines = '\n'.join(x for x in native.splitlines() if x.startswith('#define IOS_SCH_'))
blob = bytes(int(x, 16) for x in re.findall(r'0x([\da-fA-F]{2})', array('ios_sch_ipc_split')))
symbols = {
    'cef_currently_on': 0x181af8, 'renderer_manager': define('IOS_SCH_IPC_CONTEXT'),
    'command_line': define('IOS_SCH_IPC_CONTEXT') + 8, 'browser_manager': 0x1cdb90,
    'helper_new': 0x13e708, 'manager_ctor': 0x4a400, 'manager_init': 0x4ba50,
    'init_continue': 0x4ba55, 'ctor_continue': 0x4a5ca, 'role_continue': 0x4bab2,
    'helper_global_loop': 0x11bb70, 'manager_connect': 0x4ac10,
    'manager_dtor': 0x4a6e0, 'helper_delete': 0x13e744, 'dtor_continue': 0x4a720,
    'helper_log': 0x111340, 'manager_getter': 0x4b290, 'direct_continue': 0x4da73,
}
entries = {
    'sc_ipc_get_manager': 'IOS_SCH_IPC_SPLIT', 'sc_ipc_capture_config': 'IOS_SCH_IPC_CAPTURE',
    'sc_ipc_ctor_store': 'IOS_SCH_IPC_STORE', 'sc_ipc_renderer_role': 'IOS_SCH_IPC_ROLE',
    'sc_ipc_global_loop': 'IOS_SCH_IPC_GLOBAL_LOOP',
    'sc_ipc_initial_connect': 'IOS_SCH_IPC_INITIAL_CONNECT', 'sc_ipc_destroy': 'IOS_SCH_IPC_DESTROY',
    'sc_ipc_direct_getter': 'IOS_SCH_IPC_DIRECT',
}

with tempfile.TemporaryDirectory(prefix='madeira-sc-split-') as name:
    folder = Path(name)
    linker = folder / 'split.ld'
    linker.write_text('SECTIONS { . = %d; .text : { *(.text) } }\n' % define('IOS_SCH_IPC_SPLIT') +
                      '\n'.join('%s = %d;' % x for x in symbols.items()) + '\n')
    subprocess.run(['as', '--64', str(root / 'tests/host/sc-ipc-split.S'),
                    '-o', str(folder / 'split.o')], check=True)
    subprocess.run(['ld', '-T', str(linker), str(folder / 'split.o'),
                    '-o', str(folder / 'split.elf')], check=True)
    subprocess.run(['objcopy', '-O', 'binary', '--only-section=.text',
                    str(folder / 'split.elf'), str(folder / 'split.bin')], check=True)
    assert (folder / 'split.bin').read_bytes() == blob
    table = subprocess.check_output(['nm', str(folder / 'split.elf')], text=True)
    for entry, macro in entries.items():
        assert int(re.search(r'([\da-f]+) T ' + entry + r'\b', table)[1], 16) == define(macro)
    trace = bytes(int(x, 16) for x in re.findall(r'0x([\da-fA-F]{2})', array('ios_sch_ipc_rebind')))
    assert define('IOS_SCH_IPC_TRACE') + len(trace) <= define('IOS_SCH_IPC_SPLIT')
    assert define('IOS_SCH_IPC_SPLIT') + len(blob) <= 0x181000
    assert define('IOS_SCH_IPC_COUNT') + 4 <= define('IOS_SCH_IPC_CONTEXT')
    assert define('IOS_SCH_IPC_CONTEXT') + 16 <= define('IOS_SCH_CACHE')
    channel_symbols = {'reply_continue': define('IOS_SCH_RENDER_CHANNEL_KEEP') + 7,
                       'reply_cleanup': define('IOS_SCH_RENDER_CHANNEL_REPLY') + 0x19}
    channel_linker = folder / 'channels.ld'
    channel_linker.write_text('SECTIONS { . = %d; .text : { *(.text) } }\n' % define('IOS_SCH_RENDER_CHANNEL_THUNK') +
                             '\n'.join('%s = %d;' % x for x in channel_symbols.items()) + '\n')
    subprocess.run(['as', '--64', str(root / 'tests/host/sc-renderer-channels.S'),
                    '-o', str(folder / 'channels.o')], check=True)
    subprocess.run(['ld', '-T', str(channel_linker), str(folder / 'channels.o'),
                    '-o', str(folder / 'channels.elf')], check=True)
    subprocess.run(['objcopy', '-O', 'binary', '--only-section=.text',
                    str(folder / 'channels.elf'), str(folder / 'channels.bin')], check=True)
    channel_blob = bytes(int(x, 16) for x in re.findall(r'0x([\da-fA-F]{2})', array('ios_sch_renderer_channels')))
    assert (folder / 'channels.bin').read_bytes() == channel_blob
    assert 0x180400 <= define('IOS_SCH_RENDER_CHANNEL_THUNK')
    assert define('IOS_SCH_RENDER_CHANNEL_THUNK') + len(channel_blob) <= define('IOS_SCH_THUNK')

    code = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
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
static int ios_sc_cef_enabled(void) { const char *e = getenv("MADEIRA_SC_CEF"); return !(e && *e == '0'); }
#define dprintf(...) ((void)0)
''' + defines + '\n' + '\n'.join(array(x) for x in (
        'ios_sch_thunk', 'ios_sch_loop_thunk', 'ios_sch_run_trace', 'ios_sch_render_drain',
        'ios_sch_ipc_rebind', 'ios_sch_ipc_split', 'ios_sch_ui_trace', 'ios_sch_renderer_channels')) + '\n' + guards + '\n' + SHA_STANDIN + '\n' + '\n'.join(function(x) for x in (
            'static int ios_sc_path_is_helper(', 'static const char *ios_sch_mismatch(',
            'static void ios_sc_render_handler_patch(')) + r'''
struct Client {
    uint16_t *channel;
    unsigned int active, handler, channels, disconnects;
    unsigned char count_pad[0x88 - 24];
    unsigned int count;
};
_Static_assert(offsetof(struct Client, count) == 0x88, "embedded client count");
struct Manager {
    unsigned char prefix[0x50];
    union { uint16_t inline_name[8]; uint16_t *heap; } name;
    uint64_t size, capacity;
    unsigned char role_pad[0xf0 - 0x70];
    uint32_t role;
    unsigned char client_pad[0x198 - 0xf4];
    struct Client client;
    unsigned char tail[0x1a28 - 0x198 - sizeof(struct Client)];
    void *owned;
};
_Static_assert(sizeof(struct Manager) == 0x1a30 && offsetof(struct Manager, role) == 0xf0 &&
               offsetof(struct Manager, name) == 0x50 && offsetof(struct Manager, owned) == 0x1a28,
               "helper manager ABI");
struct RefBase { void **vtable; unsigned int refs; };
struct Config { void *vtable; const int32_t *vbtable; struct RefBase ref; };
static struct Config config;
static const int32_t vbtable[] = {0, 8}; /* object+8+8 = CefBaseRefCounted */
static char *image;
static struct Manager browser;
static struct Manager *(ABI *get_manager)(void);
extern struct Manager *ABI probe_get(void *);
extern void ABI store_ctor(struct Manager *, void *);
extern void ABI store_role(struct Manager *, unsigned int, void *);
extern void ABI call_loop(struct Manager *, void *);
extern void ABI initial_connect(struct Manager *, const uint16_t *, unsigned int, void *);
extern struct Manager *ABI lookup_direct(void *);
extern void ABI receive_channel(struct Manager *, const uint16_t **, unsigned int, void *);
static _Thread_local int on_renderer;
static unsigned int allocations, constructions, initializations, global_loops, deletes, logs, creation_logs, destroys;
static int shutdown_complete;
static unsigned int destroyed_channels;
static unsigned int connect_calls;
static atomic_int initializing, proceed;
static int pause_init;
static uint16_t channel0[] = {'r','g','s','c','_','i','p','c','_','c','4','_','c','h','a','n','n','e','l','_','0',0};
static uint16_t channel1[] = {'r','g','s','c','_','i','p','c','_','c','4','_','c','h','a','n','n','e','l','_','1',0};
static uint16_t channel2[] = {'r','g','s','c','_','i','p','c','_','c','4','_','c','h','a','n','n','e','l','_','2',0};
static struct Manager **browser_slot(void) { return (void *)(image + 0x1cdb90); }
static struct Manager **renderer_slot(void) { return (void *)(image + IOS_SCH_IPC_CONTEXT); }
static int ABI currently_on(int thread)
{
    assert(thread == 6);
    __asm__ volatile("pxor %%xmm0,%%xmm0; pxor %%xmm1,%%xmm1; pxor %%xmm2,%%xmm2;"
                     "pxor %%xmm3,%%xmm3; pxor %%xmm4,%%xmm4; pxor %%xmm5,%%xmm5"
                     : : : "xmm0","xmm1","xmm2","xmm3","xmm4","xmm5");
    return on_renderer;
}
static void ABI add_ref(struct RefBase *r) { assert(r == &config.ref); r->refs++; }
static void *ABI allocate(uint64_t size)
{
    assert(on_renderer && size == sizeof(struct Manager));
    allocations++;
    return calloc(1, size);
}
static void init_members(struct Manager *m)
{
    m->name.heap = calloc(32, sizeof(uint16_t)); assert(m->name.heap);
    m->capacity = 31; m->size = 21;
    memcpy(m->name.heap, channel0, sizeof(channel0));
    m->owned = malloc(8); assert(m->owned);
}
static struct Manager *ABI construct(struct Manager *m)
{
    assert(on_renderer && *renderer_slot() == m && *browser_slot() == &browser);
    constructions++; init_members(m);
    store_ctor(m, image + 0x4a5c3);
    assert(*browser_slot() == &browser);
    return m;
}
static void ABI global_loop(void) { assert(!on_renderer); global_loops++; }
static void ABI connect_body(struct Manager *m, const uint16_t *name, unsigned int flag)
{
    assert(name == channel0 || name == channel1 || name == channel2 || name == m->name.heap);
    /* Connect(name, replace_old) owns a set of named connections. The last
     * channel string changes in both modes; only replacement closes its old
     * connection. Preserve that observable distinction in this fixture. */
    unsigned int old = m->name.heap[20] - '0', next = name[20] - '0';
    assert(old < 3 && next < 3);
    connect_calls++;
    if (flag && old != next && (m->client.channels & (1u << old))) {
        m->client.channels &= ~(1u << old);
        m->client.disconnects++;
        m->client.count--;
    }
    if (!(m->client.channels & (1u << next))) m->client.count++;
    m->client.channels |= 1u << next;
    memcpy(m->name.heap, name, sizeof(channel0));
    m->client.channel = m->name.heap; m->client.active = 1;
}
static int ABI initialize(struct Manager *m, struct Config **cfg)
{
    assert(*cfg == &config);
    assert(config.ref.refs == 2); /* caller retained the consumed by-value reference */
    initializations++;
    if (pause_init && on_renderer) {
        atomic_store(&initializing, 1);
        while (!atomic_load(&proceed)) { }
    }
    store_role(m, 0, image + 0x4baab);
    assert(m->role == (unsigned int)on_renderer);
    if (on_renderer) assert(get_manager() == m); /* original Initialize uses this getter too */
    call_loop(m, image + 0x4d255);
    initial_connect(m, channel0, 0, image + 0x4d2fb);
    if (on_renderer) assert(!m->client.active); /* browser's channel must never be opened here */
    else assert(m->client.active);
    config.ref.refs--;
    return 1;
}
static void ABI log_rebind(unsigned int level, const char *format, ...)
{
    __builtin_ms_va_list args;
    __builtin_ms_va_start(args, format);
    if (!strcmp(format, "[sc-ipc] renderer manager=%p browser=%p init=%u")) {
        struct Manager *m = __builtin_va_arg(args, struct Manager *);
        struct Manager *b = __builtin_va_arg(args, struct Manager *);
        unsigned int result = __builtin_va_arg(args, unsigned int);
        assert(!level && m == *renderer_slot() && m != b && b == &browser && result == 1);
        creation_logs++;
        __builtin_ms_va_end(args);
        return;
    }
    struct Manager *m = __builtin_va_arg(args, struct Manager *);
    uint16_t *old = __builtin_va_arg(args, uint16_t *);
    const uint16_t *name = __builtin_va_arg(args, const uint16_t *);
    uintptr_t caller = __builtin_va_arg(args, uintptr_t);
    __builtin_ms_va_end(args);
    assert(!level && old == m->name.heap && name && caller);
    logs++;
}
static void ABI finish_destroy(struct Manager *m, void *owned)
{
    assert(shutdown_complete && owned == m->owned);
    destroys++;
    if (m == &browser) assert(destroys == 2 && !*browser_slot());
    else assert(destroys == 1 && !*renderer_slot() && *browser_slot() == &browser);
    free(m->name.heap); free(m->owned);
    destroyed_channels += __builtin_popcount(m->client.channels);
    m->client.channels = 0;
    m->client.count = 0;
    m->name.heap = NULL; m->owned = NULL; m->client.active = 0;
}
static void ABI delete_manager(struct Manager *m, uint64_t size)
{
    assert(shutdown_complete && destroys == 1 && !*renderer_slot() &&
           *browser_slot() == &browser && size == sizeof(*m) && !m->owned);
    deletes++; free(m);
}
static void stub(size_t rva, uintptr_t fn)
{
    unsigned char b[] = {0x48,0xb8,0,0,0,0,0,0,0,0,0xff,0xe0};
    memcpy(b + 2, &fn, 8); memcpy(image + rva, b, sizeof(b));
}
static void destructor_fixture(void)
{
    /* Same aligned frame and live values as the original destructor at its hook. */
    const unsigned char prologue[] = {0x57,0x56,0x48,0x83,0xec,0x28,0x48,0x89,0xcf,0x31,0xf6,
                                      0x48,0x8b,0x8f,0x28,0x1a,0,0,0xe9,0,0,0,0};
    memcpy(image + 0x4a6e0, prologue, sizeof(prologue));
    int32_t disp = 0x4a719 - (0x4a6e0 + sizeof(prologue));
    memcpy(image + 0x4a6e0 + sizeof(prologue) - 4, &disp, 4);
    unsigned char tail[] = {0x48,0x89,0xca,0x48,0x89,0xf9,0x48,0xb8,0,0,0,0,0,0,0,0,
                            0xff,0xd0,0x48,0x83,0xc4,0x28,0x5e,0x5f,0xc3};
    uintptr_t fn = (uintptr_t)finish_destroy;
    memcpy(tail + 8, &fn, 8); memcpy(image + 0x4a720, tail, sizeof(tail));
}
static void channel_reply_fixture(const char *before)
{
    /* The Channel Response after its patched instruction: load the name from the
     * CefString wrapper (RSI), CALL Connect, and reach the original reply cleanup.
     * The helper's own bytes stay out of the tree, so this stand-in replaces the
     * filler between the hook's end and the cleanup, which the patch leaves alone. */
    const size_t at = IOS_SCH_RENDER_CHANNEL_KEEP + 7, end = IOS_SCH_RENDER_CHANNEL_REPLY + 0x19;
    unsigned char code[] = {0x48,0x8b,0x16,0xe8,0,0,0,0}; /* mov rdx,[rsi]; call Connect */
    int32_t disp = (int32_t)(IOS_SCH_IPC_CONNECT - (at + sizeof(code)));
    assert(end >= at + sizeof(code) && !memcmp(image + at, before + at, end - at));
    memcpy(code + 4, &disp, 4);
    memcpy(image + at, code, sizeof(code));
    memset(image + at + sizeof(code), 0x90, end - at - sizeof(code));
}
static void *renderer_thread(void *unused)
{
    (void)unused;
    on_renderer = 1;
    struct Manager *m = probe_get(get_manager);
    assert(m != &browser && m == *renderer_slot() && m->role == 1);
    assert(lookup_direct(image + 0x4da6c) == m);
    m->client.handler = 2; /* renderer handler registration from OnWebKitInitialized */
    assert(config.ref.refs == 1 && m->owned != browser.owned && m->name.heap != browser.name.heap);
    const uint16_t *name = channel1;
    receive_channel(m, &name, 0, image + IOS_SCH_RENDER_CHANNEL_KEEP);
    assert(browser.client.active && browser.name.heap[20] == '0' && browser.client.handler == 1);
    assert(m->client.active && m->name.heap[20] == '1' && m->client.handler == 2);
    name = channel2;
    receive_channel(m, &name, 1, image + IOS_SCH_RENDER_CHANNEL_KEEP);
    /* The old instruction would close channel_1 here and notify its peer.
     * The production patch must leave both frontend connections alive. */
    assert(m->client.channels == ((1u << 1) | (1u << 2)));
    assert(!m->client.disconnects && browser.client.channels == 1 && browser.client.handler == 1);
    receive_channel(m, &name, 1, image + IOS_SCH_RENDER_CHANNEL_KEEP);
    assert(m->client.channels == ((1u << 1) | (1u << 2)) && !m->client.disconnects);
    assert(m->client.count == 2);
    /* Execute both capacity branches against the exact client count offset.
     * Reusing a connection below capacity is allowed; full/invalid counts
     * must not call Connect or touch the connections already owned. */
    unsigned int calls = connect_calls;
    m->client.count = 63;
    receive_channel(m, &name, 1, image + IOS_SCH_RENDER_CHANNEL_KEEP);
    assert(connect_calls == calls + 1 && m->client.count == 63);
    m->client.count = 64;
    receive_channel(m, &name, 1, image + IOS_SCH_RENDER_CHANNEL_KEEP);
    assert(connect_calls == calls + 1 && m->client.count == 64);
    m->client.count = UINT32_MAX;
    receive_channel(m, &name, 1, image + IOS_SCH_RENDER_CHANNEL_KEEP);
    assert(connect_calls == calls + 1 && m->client.count == UINT32_MAX);
    assert(m->client.channels == ((1u << 1) | (1u << 2)) && !m->client.disconnects);
    m->client.count = 2;
    for (unsigned int i = 0; i < 1000; i++) assert(get_manager() == m);
    assert(allocations == 1 && constructions == 1 && initializations == 2 && global_loops == 1);
    return NULL;
}
/* Register fixtures preserve the helper's nonvolatile registers and jump into
 * the actual patched instruction sites with the original stack alignment. */
__asm__(
".text\n"
"store_ctor: push %rbx; sub $32,%rsp; mov %rcx,%rbx; mov %rcx,%rax; call *%rdx; add $32,%rsp; pop %rbx; ret\n"
"store_role: push %r14; sub $32,%rsp; mov %rcx,%r14; mov %edx,%eax; call *%r8; add $32,%rsp; pop %r14; ret\n"
"call_loop: push %r14; sub $32,%rsp; mov %rcx,%r14; jmp *%rdx\n"
"initial_connect: sub $40,%rsp; jmp *%r9\n"
"lookup_direct: push %rbx; sub $32,%rsp; jmp *%rcx\n"
/* Execute the patched Channel Response instruction, then the stand-in's argument
 * load and relative CALL to Connect. RSI is its CefString pointer wrapper. */
"receive_channel: push %rbx; push %rsi; sub $40,%rsp; mov %rcx,%rax; mov %rdx,%rsi;"
"mov %r8b,%bl; jmp *%r9\n"
"probe_get: push %rbx; push %rdi; sub $40,%rsp; mov %rcx,%rbx;"
"mov $11,%ecx; mov $22,%edx; mov $33,%r8d; mov $44,%r9d; mov $55,%r10d; mov $66,%r11d;"
"pcmpeqd %xmm0,%xmm0; pcmpeqd %xmm1,%xmm1; pcmpeqd %xmm2,%xmm2;"
"pcmpeqd %xmm3,%xmm3; pcmpeqd %xmm4,%xmm4; pcmpeqd %xmm5,%xmm5; stc; call *%rbx; jnc probe_fail;"
"mov %rax,%rdi; cmp $11,%rcx; jne probe_fail; cmp $22,%rdx; jne probe_fail;"
"cmp $33,%r8; jne probe_fail; cmp $44,%r9; jne probe_fail; cmp $55,%r10; jne probe_fail; cmp $66,%r11; jne probe_fail;"
"pmovmskb %xmm0,%eax; cmp $65535,%eax; jne probe_fail; pmovmskb %xmm1,%eax; cmp $65535,%eax; jne probe_fail;"
"pmovmskb %xmm2,%eax; cmp $65535,%eax; jne probe_fail; pmovmskb %xmm3,%eax; cmp $65535,%eax; jne probe_fail;"
"pmovmskb %xmm4,%eax; cmp $65535,%eax; jne probe_fail; pmovmskb %xmm5,%eax; cmp $65535,%eax; jne probe_fail;"
"mov %rdi,%rax; jmp probe_return; probe_fail: xor %eax,%eax;"
"probe_return: add $40,%rsp; pop %rdi; pop %rbx; ret\n");
int main(int argc, char **argv)
{
    image = mmap(NULL, IOS_SCH_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(image != MAP_FAILED);
    IMAGE_NT_HEADERS nt = {{ IMAGE_FILE_MACHINE_AMD64, 2, IOS_SCH_STAMP },
                           { IMAGE_NT_OPTIONAL_HDR64_MAGIC, IOS_SCH_SIZE }};
    IMAGE_SECTION_HEADER sec[2] = {
        { IOS_SCH_TEXT, {0x17f34c}, 0x17f400, IMAGE_SCN_MEM_EXECUTE },
        { IOS_SCH_DATA, {0x43bc}, 0x1a00, IMAGE_SCN_MEM_WRITE }};
    WCHAR path[] = {'S','o','c','i','a','l','C','l','u','b','H','e','l','p','e','r','.','e','x','e'};
    UNICODE_STRING name = {path, sizeof(path)};
    sch_fill(image);
    uint64_t base = IOS_SCH_IMAGE_BASE;
    *(uint64_t *)(image + IOS_SCH_VT_BROWSER + IOS_SCH_SLOT_BROWSER * 8) = base + IOS_SCH_GET_HANDLER;
    *(uint64_t *)(image + IOS_SCH_VT_BROWSER + IOS_SCH_SLOT_RENDERER * 8) = base + IOS_SCH_GET_NULL;
    *(uint64_t *)(image + IOS_SCH_VT_RENDERER + IOS_SCH_SLOT_RENDERER * 8) = base + IOS_SCH_GET_HANDLER;
    *(uint64_t *)(image + IOS_SCH_VT_RENDERER + IOS_SCH_SLOT_BROWSER * 8) = base + IOS_SCH_GET_NULL;
    *(uint64_t *)(image + IOS_SCH_VT_RPH) = base + IOS_SCH_WEBKIT;
    /* The image holds the filler, not the helper's code: the opt-out is checked
     * against the image as it was before the patch. */
    char *before = malloc(IOS_SCH_SIZE);
    assert(before);
    memcpy(before, image, IOS_SCH_SIZE);
    ios_sc_render_handler_patch(image, IOS_SCH_SIZE, &nt, sec, &name);
    if (argc > 1 && !strcmp(argv[1], "disabled")) {
        assert(!memcmp(image + 0x4b290, before + 0x4b290, 8));
        for (size_t i = 0; i < sizeof(ios_sch_ipc_split); i++) assert(!image[IOS_SCH_IPC_SPLIT+i]);
        assert((unsigned char)image[IOS_SCH_IPC_CONNECT] == 0xe9);
        assert((unsigned char)image[IOS_SCH_RENDER_DRAIN_SITE] == 0xe8);
        assert(!memcmp(image + IOS_SCH_RENDER_CHANNEL_KEEP, before + IOS_SCH_RENDER_CHANNEL_KEEP, 7));
        for (size_t i = 0; i < sizeof(ios_sch_renderer_channels); i++)
            assert(!image[IOS_SCH_RENDER_CHANNEL_THUNK+i]);
        free(before);
        assert(!munmap(image, IOS_SCH_SIZE));
        puts("PASS: IPC split opt-out preserves the earlier renderer, drain and diagnostic patches");
        return 0;
    }
    assert((unsigned char)image[0x4b290] == 0xe9);
    assert((unsigned char)image[IOS_SCH_RENDER_CHANNEL_KEEP] == 0xe9);
    channel_reply_fixture(before);
    free(before);
    if (argc > 1 && !strcmp(argv[1], "legacy"))
        memcpy(image + 0x4b290, "\x48\x8b\x05\xf9\x28\x18\x00\xc3", 8);
    if (argc > 1 && !strcmp(argv[1], "old-rebind"))
        memcpy(image + IOS_SCH_RENDER_CHANNEL_KEEP, "\x44\x0f\xb6\xc3\x48\x8b\xc8", 7);
    stub(0x13e708, (uintptr_t)allocate); stub(0x4a400, (uintptr_t)construct);
    image[0x4a5ca] = image[0x4bab2] = (char)0xc3;
    stub(0x4ba55, (uintptr_t)initialize); stub(0x11bb70, (uintptr_t)global_loop);
    stub(IOS_SCH_IPC_CONNECT + 5, (uintptr_t)connect_body);
    stub(0x111340, (uintptr_t)log_rebind); stub(0x13e744, (uintptr_t)delete_manager);
    const unsigned char loop_return[] = {0x48,0x83,0xc4,0x20,0x41,0x5e,0xc3};
    const unsigned char connect_return[] = {0x48,0x83,0xc4,0x28,0xc3};
    const unsigned char direct_return[] = {0x48,0x89,0xd8,0x48,0x83,0xc4,0x20,0x5b,0xc3};
    memcpy(image + 0x4d25a, loop_return, sizeof(loop_return));
    memcpy(image + 0x4d300, connect_return, sizeof(connect_return));
    memcpy(image + 0x4da73, direct_return, sizeof(direct_return));
    const unsigned char reply_return[] = {0x48,0x83,0xc4,0x28,0x5e,0x5b,0xc3};
    memcpy(image + IOS_SCH_RENDER_CHANNEL_REPLY + 0x19, reply_return, sizeof(reply_return));
    destructor_fixture();
    *(uintptr_t *)(image + 0x181af8) = (uintptr_t)currently_on;
    assert(!mprotect(image + 0x1000, 0x180000, PROT_READ | PROT_EXEC));
    static void *ref_vtable[] = {(void *)add_ref};
    config = (struct Config){NULL, vbtable, {ref_vtable, 1}};
    *browser_slot() = &browser; init_members(&browser); browser.client.handler = 1;
    get_manager = (void *)(image + 0x4b290);
    assert(probe_get(get_manager) == &browser && !allocations);
    assert(lookup_direct(image + 0x4da6c) == &browser);
    struct Config *argument = &config;
    config.ref.refs++; /* same ownership as the original WinMain call */
    ((int (ABI *)(struct Manager *, struct Config **))(image + 0x4ba50))(&browser, &argument);
    assert(config.ref.refs == 1 && browser.client.active && global_loops == 1);
    /* Browser reconnection still closes its old channel when requested; only
     * the renderer's Channel Response instruction changed. */
    ((void (ABI *)(struct Manager *, const uint16_t *, unsigned int))(image + IOS_SCH_IPC_CONNECT))(&browser, channel1, 1);
    assert(browser.client.channels == (1u << 1) && browser.client.disconnects == 1);
    ((void (ABI *)(struct Manager *, const uint16_t *, unsigned int))(image + IOS_SCH_IPC_CONNECT))(&browser, channel0, 1);
    assert(browser.client.channels == 1 && browser.client.disconnects == 2);
    pause_init = argc == 1;
    pthread_t thread;
    assert(!pthread_create(&thread, NULL, renderer_thread, NULL));
    if (argc == 1) {
        while (!atomic_load(&initializing)) { }
        for (unsigned int i = 0; i < 1000; i++) assert(get_manager() == &browser);
        assert(browser.client.active && browser.client.handler == 1);
        atomic_store(&proceed, 1);
    }
    assert(!pthread_join(thread, NULL));
    assert(get_manager() == &browser && browser.client.active && *renderer_slot());
    assert(logs == 7 && creation_logs == 1 && config.ref.refs == 1);
    shutdown_complete = 1;
    ((void (ABI *)(struct Manager *))(image + 0x4a6e0))(&browser);
    assert(destroys == 2 && deletes == 1 && !*renderer_slot() && !*browser_slot());
    assert(destroyed_channels == 3);
    assert(!munmap(image, IOS_SCH_SIZE));
    puts("PASS: browser channel_0 and renderer channels_1/2 retain their managers, handlers and connections");
    puts("PASS: repeated replies retain connections; the 64-slot bound avoids opening another transport");
    puts("PASS: Win64 scalar/vector/flags state, consumed CefRefPtr, initialization reentry and concurrent browser lookup");
    puts("PASS: renderer is destroyed and freed once after CEF shutdown, before clearing the browser singleton");
}
'''
    driver = folder / 'test.c'
    driver.write_text(code)
    binary = folder / 'test'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-O2', '-fsanitize=address,undefined', '-g', '-pthread', str(driver),
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
    old = subprocess.run([str(binary), 'legacy'], capture_output=True, text=True, timeout=30,
                         preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
    assert old.returncode and 'm != &browser' in old.stderr, old.stderr
    print('PASS: restoring the legacy getter reproduces the shared manager ownership failure', flush=True)
    old_rebind = subprocess.run([str(binary), 'old-rebind'], capture_output=True, text=True, timeout=30,
                               preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
    assert old_rebind.returncode and 'm->client.channels ==' in old_rebind.stderr, old_rebind.stderr
    print('PASS: restoring the old Channel Response instruction closes the first frontend connection', flush=True)
    subprocess.run([str(binary), 'disabled'], check=True, env={**os.environ, 'MADEIRA_SC_IPC_SPLIT': '0'})
