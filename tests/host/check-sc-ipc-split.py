#!/usr/bin/env python3
"""Execute the production manager split against two Win64 IPC endpoints.

Use the actual image guard/patch and assembled production hooks. The fixture
models the helper ABI, consumed CefRefPtr, per-thread manager, initialization
reentry, handlers and ordered destruction; no supplied binary is executed.
Every analysed helper build (ios_sch_builds) runs: the first build's getter
preserves every register, 2.4.0.296's (and 302's) compact getter is a plain Win64
function and its two IPC stubs sit in int3 padding.
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


def define(name):
    return int(re.search(r'#define ' + name + r'\s+(0x[\da-fA-F]+|\d+)', native)[1], 0)


def array_bytes(name):
    start = native.index('static const unsigned char ' + name + '[')
    body = native[start:native.index('};', start) + 2]
    return bytes(int(x, 16) for x in re.findall(r'0x([\da-fA-F]{2})', body[body.index('{'):]))


def function(signature):
    start = native.index(signature)
    return native[start:native.index('\n}', start) + 2]


def code_table(name):
    start = native.index(' ' + name + '[] =')
    body = native[start:native.index('\n};', start)]
    out = []
    for m in re.finditer(r'\{ (IOS_SCH\w+|0x[\da-f]+), (0x[\da-f]+),[^{]*\{([^}]*)\}', body):
        rva = define(m[1]) if m[1].startswith('IOS') else int(m[1], 16)
        out.append((rva, int(m[2], 16), bytes(int(x, 16) for x in re.findall(r'0x([\da-f]{2})', m[3]))))
    return out


def hook_table(name):
    start = native.index(' ' + name + '[] =')
    body = native[start:native.index('\n};', start)]
    value = lambda t: define(t) if t.startswith('IOS') else int(t, 16)
    return {(value(m[1]), value(m[2]), int(m[3]), int(m[4], 16), int(m[5]))
            for m in re.finditer(r'\{ (IOS_SCH\w+|0x[\da-f]+), (IOS_SCH\w+), (\d), (0x[\da-f]+), ([01]) \}', body)}


region = native[native.index('#define IOS_SCH_IMAGE_BASE'):
                native.index('\n}', native.index('static void ios_sc_render_handler_patch(')) + 2]

# Each build's IPC manager routines (beyond ios_sch_builds): sites the fixture
# jumps into, the routines it stands in for and the hooks' resume points.
BUILDS = [
    dict(name='first build', prefix='IOS_SCH_', table='ios_sch_code', hooks='ios_sch_hook', defsym=[],
         currently_on=0x181af8, browser=0x1cdb90, helper_new=0x13e708, helper_delete=0x13e744,
         ctor=0x4a400, init=0x4ba50, ctor_store=0x4a5c3, role_store=0x4baab,
         global_loop=0x11bb70, loop_call=0x4d255, connect_call=0x4d2fb, connect=0x4ac10,
         dtor=0x4a6e0, dtor_store=0x4a719, getter=0x4b290, direct=0x4da6c, log=0x111340,
         text_vs=0x17f34c, text_raw=0x17f400, data=define('IOS_SCH_DATA'), data_vs=0x43bc,
         full_preserve=1, creation_log=1, rebind_trace=1,
         split=[('.text', 'IPC_SPLIT', 'ios_sch_ipc_split')]),
    dict(name='2.4.0.296', prefix='IOS_SCH296_', table='ios_sch296_code', hooks='ios_sch296_hook',
         defsym=['--defsym', 'SCH296=1'],
         currently_on=0x1a4b00, browser=0x1f5ba0, helper_new=0x1622b8, helper_delete=0x1622f4,
         ctor=0x4af20, init=0x4c840, ctor_store=0x4b0e3, role_store=0x4c8a6,
         global_loop=0x13eb40, loop_call=0x4e097, connect_call=0x4e143, connect=0x4ba30,
         dtor=0x4b240, dtor_store=0x4b279, getter=0x4c0d0, direct=0x4e76a, log=0,
         text_vs=define('IOS_SCH296_TEXT_VS'), text_raw=define('IOS_SCH296_TEXT_RAW'),
         data=define('IOS_SCH296_DATA'), data_vs=define('IOS_SCH296_DATA_VS'),
         full_preserve=0, creation_log=0, rebind_trace=0,
         split=[('.text', 'IPC_SPLIT', 'ios_sch296_ipc_split'),
                ('.text.global_loop', 'IPC_GLOBAL_LOOP', 'ios_sch296_ipc_global_loop'),
                ('.text.initial_connect', 'IPC_INITIAL_CONNECT', 'ios_sch296_ipc_initial_connect'),
                ('.text.direct', 'IPC_DIRECT', 'ios_sch296_ipc_direct')]),
    # 2.4.0.302: 296's code with 0x670 bytes inserted into .text. The manager routines below the insertion
    # keep their RVAs; operator new/delete and the global loop routine moved (+0x670, +0x550), the
    # imports and .data globals by 0x1000.
    dict(name='2.4.0.302', prefix='IOS_SCH302_', table='ios_sch302_code', hooks='ios_sch302_hook',
         defsym=['--defsym', 'SCH296=1'],
         currently_on=0x1a5b00, browser=0x1f6ba0, helper_new=0x162928, helper_delete=0x162964,
         ctor=0x4af20, init=0x4c840, ctor_store=0x4b0e3, role_store=0x4c8a6,
         global_loop=0x13f090, loop_call=0x4e097, connect_call=0x4e143, connect=0x4ba30,
         dtor=0x4b240, dtor_store=0x4b279, getter=0x4c0d0, direct=0x4e76a, log=0,
         text_vs=define('IOS_SCH302_TEXT_VS'), text_raw=define('IOS_SCH302_TEXT_RAW'),
         data=define('IOS_SCH302_DATA'), data_vs=define('IOS_SCH302_DATA_VS'),
         full_preserve=0, creation_log=0, rebind_trace=0,
         split=[('.text', 'IPC_SPLIT', 'ios_sch302_ipc_split'),
                ('.text.global_loop', 'IPC_GLOBAL_LOOP', 'ios_sch302_ipc_global_loop'),
                ('.text.initial_connect', 'IPC_INITIAL_CONNECT', 'ios_sch302_ipc_initial_connect'),
                ('.text.direct', 'IPC_DIRECT', 'ios_sch302_ipc_direct')]),
]

# The helper's code stays out of the tree: each build's table holds each range's
# SHA-256. The fixture image holds a filler in each range instead, and this
# stand-in for CommonCrypto answers a range's own digest exactly while its filler
# is intact. RET + int3 padding ranges hold those bytes themselves.
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
'''

FIXTURE = r'''
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
extern struct Manager *ABI probe_abi(void *);
extern void ABI store_ctor(struct Manager *, void *);
extern void ABI store_role(struct Manager *, unsigned int, void *);
extern void ABI call_loop(struct Manager *, void *);
extern void ABI initial_connect(struct Manager *, const uint16_t *, unsigned int, void *);
extern struct Manager *ABI lookup_direct(void *);
extern void ABI receive_channel(struct Manager *, const uint16_t **, unsigned int, void *);
#if FULL_PRESERVE
#define PROBE probe_get   /* every volatile register, the vectors and CF survive */
#else
#define PROBE probe_abi   /* a Win64 function: its nonvolatile registers survive */
#endif
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
static struct Manager **browser_slot(void) { return (void *)(image + R_BROWSER); }
static struct Manager **renderer_slot(void) { return (void *)(image + R_CONTEXT); }
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
    store_ctor(m, image + R_CTOR_STORE);
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
    store_role(m, 0, image + R_ROLE_STORE);
    assert(m->role == (unsigned int)on_renderer);
    if (on_renderer) assert(get_manager() == m); /* original Initialize uses this getter too */
    call_loop(m, image + R_LOOP_CALL);
    initial_connect(m, channel0, 0, image + R_CONNECT_CALL);
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
    memcpy(image + R_DTOR, prologue, sizeof(prologue));
    int32_t disp = R_DTOR_STORE - (R_DTOR + sizeof(prologue));
    memcpy(image + R_DTOR + sizeof(prologue) - 4, &disp, 4);
    /* After the hook only RCX (the owned object), RDI and RSI are read. */
    unsigned char tail[] = {0x48,0x89,0xca,0x48,0x89,0xf9,0x48,0xb8,0,0,0,0,0,0,0,0,
                            0xff,0xd0,0x48,0x83,0xc4,0x28,0x5e,0x5f,0xc3};
    uintptr_t fn = (uintptr_t)finish_destroy;
    memcpy(tail + 8, &fn, 8); memcpy(image + R_DTOR_STORE + 7, tail, sizeof(tail));
}
static void channel_reply_fixture(const char *before)
{
    /* The Channel Response after its patched instruction: load the name from the
     * CefString wrapper (RSI), CALL Connect, and reach the original reply cleanup.
     * The helper's own bytes stay out of the tree, so this stand-in replaces the
     * filler between the hook's end and the cleanup, which the patch leaves alone. */
    const size_t at = R_KEEP + 7, end = R_REPLY + 0x19;
    unsigned char code[] = {0x48,0x8b,0x16,0xe8,0,0,0,0}; /* mov rdx,[rsi]; call Connect */
    int32_t disp = (int32_t)(R_CONNECT - (at + sizeof(code)));
    assert(end >= at + sizeof(code) && !memcmp(image + at, before + at, end - at));
    memcpy(code + 4, &disp, 4);
    memcpy(image + at, code, sizeof(code));
    memset(image + at + sizeof(code), 0x90, end - at - sizeof(code));
}
static void *renderer_thread(void *unused)
{
    (void)unused;
    on_renderer = 1;
    struct Manager *m = PROBE(get_manager);
    assert(m != &browser && m == *renderer_slot() && m->role == 1);
    assert(lookup_direct(image + R_DIRECT) == m);
    m->client.handler = 2; /* renderer handler registration from OnWebKitInitialized */
    assert(config.ref.refs == 1 && m->owned != browser.owned && m->name.heap != browser.name.heap);
    const uint16_t *name = channel1;
    receive_channel(m, &name, 0, image + R_KEEP);
    assert(browser.client.active && browser.name.heap[20] == '0' && browser.client.handler == 1);
    assert(m->client.active && m->name.heap[20] == '1' && m->client.handler == 2);
    name = channel2;
    receive_channel(m, &name, 1, image + R_KEEP);
    /* The old instruction would close channel_1 here and notify its peer.
     * The production patch must leave both frontend connections alive. */
    assert(m->client.channels == ((1u << 1) | (1u << 2)));
    assert(!m->client.disconnects && browser.client.channels == 1 && browser.client.handler == 1);
    receive_channel(m, &name, 1, image + R_KEEP);
    assert(m->client.channels == ((1u << 1) | (1u << 2)) && !m->client.disconnects);
    assert(m->client.count == 2);
    /* Execute both capacity branches against the exact client count offset.
     * Reusing a connection below capacity is allowed; full/invalid counts
     * must not call Connect or touch the connections already owned. */
    unsigned int calls = connect_calls;
    m->client.count = 63;
    receive_channel(m, &name, 1, image + R_KEEP);
    assert(connect_calls == calls + 1 && m->client.count == 63);
    m->client.count = 64;
    receive_channel(m, &name, 1, image + R_KEEP);
    assert(connect_calls == calls + 1 && m->client.count == 64);
    m->client.count = UINT32_MAX;
    receive_channel(m, &name, 1, image + R_KEEP);
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
"probe_return: add $40,%rsp; pop %rdi; pop %rbx; ret\n"
/* Win64 callee contract only: RBX, RBP, RSI, RDI, R12-R15 and XMM6 survive. */
"probe_abi: push %rbx; push %rbp; push %rsi; push %rdi; push %r12; push %r13; push %r14; push %r15;"
"sub $24,%rsp; movdqu %xmm6,(%rsp); mov %rcx,%rax;"
"mov $101,%ebx; mov $102,%ebp; mov $103,%esi; mov $104,%edi; mov $105,%r12d; mov $106,%r13d;"
"mov $107,%r14d; mov $108,%r15d; pcmpeqd %xmm6,%xmm6; sub $32,%rsp; call *%rax; add $32,%rsp;"
"cmp $101,%rbx; jne abi_fail; cmp $102,%rbp; jne abi_fail; cmp $103,%rsi; jne abi_fail; cmp $104,%rdi; jne abi_fail;"
"cmp $105,%r12; jne abi_fail; cmp $106,%r13; jne abi_fail; cmp $107,%r14; jne abi_fail; cmp $108,%r15; jne abi_fail;"
"mov %rax,%rcx; pmovmskb %xmm6,%eax; cmp $65535,%eax; jne abi_fail; mov %rcx,%rax; jmp abi_return;"
"abi_fail: xor %eax,%eax;"
"abi_return: movdqu (%rsp),%xmm6; add $24,%rsp; pop %r15; pop %r14; pop %r13; pop %r12; pop %rdi; pop %rsi;"
"pop %rbp; pop %rbx; ret\n");
int main(int argc, char **argv)
{
    sch_build = &ios_sch_builds[BUILD];
    assert(sch_build->stamp == B_STAMP && sch_build->size == B_SIZE);
    image = mmap(NULL, B_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(image != MAP_FAILED);
    IMAGE_NT_HEADERS nt = {{ IMAGE_FILE_MACHINE_AMD64, 2, B_STAMP },
                           { IMAGE_NT_OPTIONAL_HDR64_MAGIC, B_SIZE }};
    IMAGE_SECTION_HEADER sec[2] = {
        { IOS_SCH_TEXT, {B_TEXT_VS}, B_TEXT_RAW, IMAGE_SCN_MEM_EXECUTE },
        { B_DATA, {B_DATA_VS}, 0x1a00, IMAGE_SCN_MEM_WRITE }};
    WCHAR path[] = {'S','o','c','i','a','l','C','l','u','b','H','e','l','p','e','r','.','e','x','e'};
    UNICODE_STRING name = {path, sizeof(path)};
    sch_fill(image);
    uint64_t base = IOS_SCH_IMAGE_BASE;
    *(uint64_t *)(image + sch_build->vt_browser + IOS_SCH_SLOT_BROWSER * 8) = base + sch_build->get_handler;
    *(uint64_t *)(image + sch_build->vt_browser + IOS_SCH_SLOT_RENDERER * 8) = base + sch_build->get_null;
    *(uint64_t *)(image + sch_build->vt_renderer + IOS_SCH_SLOT_RENDERER * 8) = base + sch_build->get_handler;
    *(uint64_t *)(image + sch_build->vt_renderer + IOS_SCH_SLOT_BROWSER * 8) = base + sch_build->get_null;
    *(uint64_t *)(image + sch_build->vt_rph) = base + sch_build->webkit;
    /* The image holds the filler, not the helper's code: the opt-out is checked
     * against the image as it was before the patch. */
    char *before = malloc(B_SIZE);
    assert(before);
    memcpy(before, image, B_SIZE);
    ios_sc_render_handler_patch(image, B_SIZE, &nt, sec, &name);
    if (argc > 1 && !strcmp(argv[1], "disabled")) {
        assert(!memcmp(image + R_GETTER, before + R_GETTER, 8));
        for (size_t k = 0; k < sch_build->blob_count; k++)
            if (sch_build->blob[k].ipc)
                assert(!memcmp(image + sch_build->blob[k].rva, before + sch_build->blob[k].rva, sch_build->blob[k].len));
        for (size_t k = 0; k < sch_build->hook_count; k++)
            if (sch_build->hook[k].ipc)
                assert(!memcmp(image + sch_build->hook[k].site, before + sch_build->hook[k].site, sch_build->hook[k].span));
#if REBIND_TRACE
        assert((unsigned char)image[R_CONNECT] == 0xe9);
#endif
        assert((unsigned char)image[R_DRAIN_SITE] == 0xe8);
        assert(!memcmp(image + R_KEEP, before + R_KEEP, 7));
        free(before);
        assert(!munmap(image, B_SIZE));
        puts("PASS: IPC split opt-out preserves the earlier renderer, drain and diagnostic patches");
        return 0;
    }
    assert((unsigned char)image[R_GETTER] == 0xe9);
    assert((unsigned char)image[R_KEEP] == 0xe9);
    channel_reply_fixture(before);
    free(before);
    if (argc > 1 && !strcmp(argv[1], "legacy")) {
        /* The original getter: mov rax, [rip + browser singleton]; ret */
        unsigned char getter[8] = {0x48,0x8b,0x05,0,0,0,0,0xc3};
        int32_t disp = (int32_t)(R_BROWSER - (R_GETTER + 7));
        memcpy(getter + 3, &disp, 4);
        memcpy(image + R_GETTER, getter, sizeof(getter));
    }
    if (argc > 1 && !strcmp(argv[1], "old-rebind"))
        memcpy(image + R_KEEP, "\x44\x0f\xb6\xc3\x48\x8b\xc8", 7);
    stub(R_NEW, (uintptr_t)allocate); stub(R_CTOR, (uintptr_t)construct);
    image[R_CTOR_STORE + 7] = image[R_ROLE_STORE + 7] = (char)0xc3;
    stub(R_INIT + 5, (uintptr_t)initialize); stub(R_GLOBAL_LOOP, (uintptr_t)global_loop);
    stub(R_CONNECT + (REBIND_TRACE ? 5 : 0), (uintptr_t)connect_body);
#if CREATION_LOG || REBIND_TRACE
    stub(R_LOG, (uintptr_t)log_rebind);
#else
    (void)log_rebind;
#endif
    stub(R_DELETE, (uintptr_t)delete_manager);
    const unsigned char loop_return[] = {0x48,0x83,0xc4,0x20,0x41,0x5e,0xc3};
    const unsigned char connect_return[] = {0x48,0x83,0xc4,0x28,0xc3};
    const unsigned char direct_return[] = {0x48,0x89,0xd8,0x48,0x83,0xc4,0x20,0x5b,0xc3};
    memcpy(image + R_LOOP_CALL + 5, loop_return, sizeof(loop_return));
    memcpy(image + R_CONNECT_CALL + 5, connect_return, sizeof(connect_return));
    memcpy(image + R_DIRECT + 7, direct_return, sizeof(direct_return));
    const unsigned char reply_return[] = {0x48,0x83,0xc4,0x28,0x5e,0x5b,0xc3};
    memcpy(image + R_REPLY + 0x19, reply_return, sizeof(reply_return));
    destructor_fixture();
    *(uintptr_t *)(image + R_CURRENTLY_ON) = (uintptr_t)currently_on;
    assert(!mprotect(image + 0x1000, B_TEXT_END - 0x1000, PROT_READ | PROT_EXEC));
    static void *ref_vtable[] = {(void *)add_ref};
    config = (struct Config){NULL, vbtable, {ref_vtable, 1}};
    *browser_slot() = &browser; init_members(&browser); browser.client.handler = 1;
    get_manager = (void *)(image + R_GETTER);
    assert(PROBE(get_manager) == &browser && !allocations);
    assert(lookup_direct(image + R_DIRECT) == &browser);
    struct Config *argument = &config;
    config.ref.refs++; /* same ownership as the original WinMain call */
    ((int (ABI *)(struct Manager *, struct Config **))(image + R_INIT))(&browser, &argument);
    assert(config.ref.refs == 1 && browser.client.active && global_loops == 1);
    /* Browser reconnection still closes its old channel when requested; only
     * the renderer's Channel Response instruction changed. */
    ((void (ABI *)(struct Manager *, const uint16_t *, unsigned int))(image + R_CONNECT))(&browser, channel1, 1);
    assert(browser.client.channels == (1u << 1) && browser.client.disconnects == 1);
    ((void (ABI *)(struct Manager *, const uint16_t *, unsigned int))(image + R_CONNECT))(&browser, channel0, 1);
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
    assert(logs == (REBIND_TRACE ? 7 : 0) && creation_logs == CREATION_LOG && config.ref.refs == 1);
    shutdown_complete = 1;
    ((void (ABI *)(struct Manager *))(image + R_DTOR))(&browser);
    assert(destroys == 2 && deletes == 1 && !*renderer_slot() && !*browser_slot());
    assert(destroyed_channels == 3);
    assert(!munmap(image, B_SIZE));
    puts("PASS: browser channel_0 and renderer channels_1/2 retain their managers, handlers and connections");
    puts("PASS: repeated replies retain connections; the 64-slot bound avoids opening another transport");
#if FULL_PRESERVE
    puts("PASS: Win64 scalar/vector/flags state, consumed CefRefPtr, initialization reentry and concurrent browser lookup");
#else
    puts("PASS: Win64 nonvolatile state, consumed CefRefPtr, initialization reentry and concurrent browser lookup");
#endif
    puts("PASS: renderer is destroyed and freed once after CEF shutdown, before clearing the browser singleton");
}
'''


def link(folder, source, sections, symbols, defsym):
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
    return out, {m[2]: int(m[1], 16) for m in re.finditer(r'(?m)^([\da-f]+) [Tt] (\w+)$', table)}


def check_build(index, build, folder):
    P = build['prefix']
    d = lambda name: define(P + name)
    symbols = {
        'cef_currently_on': build['currently_on'], 'renderer_manager': d('IPC_CONTEXT'),
        'command_line': d('IPC_CONTEXT') + 8, 'browser_manager': build['browser'],
        'helper_new': build['helper_new'], 'manager_ctor': build['ctor'], 'manager_init': build['init'],
        'init_continue': build['init'] + 5, 'ctor_continue': build['ctor_store'] + 7,
        'role_continue': build['role_store'] + 7, 'helper_global_loop': build['global_loop'],
        'manager_connect': build['connect'], 'manager_dtor': build['dtor'],
        'helper_delete': build['helper_delete'], 'dtor_continue': build['dtor_store'] + 7,
        'manager_getter': build['getter'], 'direct_continue': build['direct'] + 7,
    }
    if build['log']:
        symbols['helper_log'] = build['log']
    sections = [(section, d(macro)) for section, macro, _ in build['split']]
    out, names = link(folder, 'sc-ipc-split.S', sections, symbols, build['defsym'])
    for section, _, blob in build['split']:
        assert out[section] == array_bytes(blob), (build['name'], section)
    entries = {
        'sc_ipc_get_manager': 'IPC_SPLIT', 'sc_ipc_capture_config': 'IPC_CAPTURE',
        'sc_ipc_ctor_store': 'IPC_STORE', 'sc_ipc_renderer_role': 'IPC_ROLE',
        'sc_ipc_global_loop': 'IPC_GLOBAL_LOOP', 'sc_ipc_initial_connect': 'IPC_INITIAL_CONNECT',
        'sc_ipc_destroy': 'IPC_DESTROY', 'sc_ipc_direct_getter': 'IPC_DIRECT',
    }
    for entry, macro in entries.items():
        assert names[entry] == d(macro), (build['name'], entry)
    keep, reply = d('RENDER_CHANNEL_KEEP'), d('RENDER_CHANNEL_REPLY')
    out, _ = link(folder, 'sc-renderer-channels.S', [('.text', d('RENDER_CHANNEL_THUNK'))],
                  {'reply_continue': keep + 7, 'reply_cleanup': reply + 0x19}, build['defsym'])
    assert out['.text'] == array_bytes(P.lower().rstrip('_') + '_renderer_channels'), build['name']
    assert keep == reply + 5
    # The C hook table installs exactly these hooks for the split, at the sites
    # the fixture drives (each site is inside a guarded digest range).
    expect = {
        (build['getter'], d('IPC_SPLIT'), 7, 0xe9, 1), (build['init'], d('IPC_CAPTURE'), 5, 0xe9, 1),
        (build['ctor_store'], d('IPC_STORE'), 7, 0xe9, 1), (build['role_store'], d('IPC_ROLE'), 7, 0xe9, 1),
        (build['loop_call'], d('IPC_GLOBAL_LOOP'), 5, 0xe8, 1),
        (build['connect_call'], d('IPC_INITIAL_CONNECT'), 5, 0xe8, 1),
        (build['dtor_store'], d('IPC_DESTROY'), 7, 0xe9, 1), (build['direct'], d('IPC_DIRECT'), 7, 0xe9, 1),
        (keep, d('RENDER_CHANNEL_THUNK'), 7, 0xe9, 1),
    }
    hooks = hook_table(build['hooks'])
    assert {h for h in hooks if h[4]} == expect, (build['name'], sorted(expect ^ {h for h in hooks if h[4]}))
    table = code_table(build['table'])
    for site, _, span, _, _ in hooks:
        assert any(rva <= site and site + span <= rva + n for rva, n, _ in table), (build['name'], hex(site))
    padding = [(rva, n) for rva, n, dg in table if dg == hashlib.sha256(b'\xc3' + b'\xcc' * (n - 1)).digest()]
    # Layout: tail blobs between .text's VirtualSize and its page end, padding
    # stubs inside a guarded RET + int3 run past its RET, and the renderer
    # manager slot in .data's zero-filled page slack ahead of the handler cache.
    text_start, text_end = 0x1000 + build['text_vs'], (0x1000 + build['text_vs'] + 0xfff) & ~0xfff
    for section, macro, blob in build['split'] + [('.text', 'RENDER_CHANNEL_THUNK', P.lower().rstrip('_') + '_renderer_channels')]:
        at, n = d(macro), len(array_bytes(blob))
        assert (text_start <= at and at + n <= text_end or
                any(rva < at and at + n <= rva + size for rva, size in padding)), (build['name'], macro)
    assert build['data'] + build['data_vs'] <= d('IPC_CONTEXT') and d('IPC_CONTEXT') + 16 <= d('CACHE')
    assert d('CACHE') + 8 <= (build['data'] + build['data_vs'] + 0xfff) & ~0xfff
    assert build['connect'] == d('IPC_CONNECT')
    if build['rebind_trace']:
        trace = array_bytes('ios_sch_ipc_rebind')
        assert define('IOS_SCH_IPC_TRACE') + len(trace) <= define('IOS_SCH_IPC_SPLIT')
        assert define('IOS_SCH_IPC_COUNT') + 4 <= define('IOS_SCH_IPC_CONTEXT')
    print('PASS: %s: assembled split/channel bytes, entry RVAs and hook table match' % build['name'], flush=True)

    text_end = (0x1000 + build['text_vs'] + 0xfff) & ~0xfff
    defines = {
        'BUILD': index, 'B_STAMP': d('STAMP'), 'B_SIZE': d('SIZE'), 'B_TEXT_VS': build['text_vs'],
        'B_TEXT_RAW': build['text_raw'], 'B_DATA': build['data'], 'B_DATA_VS': build['data_vs'],
        'B_TEXT_END': text_end, 'FULL_PRESERVE': build['full_preserve'],
        'CREATION_LOG': build['creation_log'], 'REBIND_TRACE': build['rebind_trace'],
        'R_BROWSER': build['browser'], 'R_CONTEXT': d('IPC_CONTEXT'), 'R_CURRENTLY_ON': build['currently_on'],
        'R_DRAIN_SITE': d('RENDER_DRAIN_SITE'), 'R_NEW': build['helper_new'], 'R_DELETE': build['helper_delete'], 'R_CTOR': build['ctor'],
        'R_INIT': build['init'], 'R_CTOR_STORE': build['ctor_store'], 'R_ROLE_STORE': build['role_store'],
        'R_GLOBAL_LOOP': build['global_loop'], 'R_LOOP_CALL': build['loop_call'],
        'R_CONNECT_CALL': build['connect_call'], 'R_CONNECT': build['connect'], 'R_DTOR': build['dtor'],
        'R_DTOR_STORE': build['dtor_store'], 'R_GETTER': build['getter'], 'R_DIRECT': build['direct'],
        'R_LOG': build['log'], 'R_KEEP': keep, 'R_REPLY': reply,
    }
    padding_c = 'static const unsigned int sch_padding_ranges[][2] = {%s};\n' % (
        ','.join('{0x%x,%d}' % p for p in padding) if padding else '{0,0}')
    code = PRELUDE + function('static int ios_sc_path_is_helper(') + '\n' + region + '\n' + padding_c + \
        SHA_STANDIN + FIXTURE
    driver = folder / 'test.c'
    driver.write_text(code)
    binary = folder / 'test'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-O2', '-fsanitize=address,undefined', '-g', '-pthread',
                    *('-D%s=%d' % item for item in defines.items()), str(driver),
                    '-o', str(binary)], check=True)
    print('--- %s' % build['name'], flush=True)
    subprocess.run([str(binary)], check=True, timeout=30)
    old = subprocess.run([str(binary), 'legacy'], capture_output=True, text=True, timeout=30,
                         preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
    assert old.returncode and 'm != &browser' in old.stderr, old.stderr
    print('PASS: %s: restoring the legacy getter reproduces the shared manager ownership failure'
          % build['name'], flush=True)
    old_rebind = subprocess.run([str(binary), 'old-rebind'], capture_output=True, text=True, timeout=30,
                               preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
    assert old_rebind.returncode and 'm->client.channels ==' in old_rebind.stderr, old_rebind.stderr
    print('PASS: %s: restoring the old Channel Response instruction closes the first frontend connection'
          % build['name'], flush=True)
    subprocess.run([str(binary), 'disabled'], check=True, env={**os.environ, 'MADEIRA_SC_IPC_SPLIT': '0'})


with tempfile.TemporaryDirectory(prefix='madeira-sc-split-') as name:
    builds = re.search(r'ios_sch_builds\[\] =\n\{(.*?)\n\};', native, re.S)[1]
    assert re.findall(r'\n    \{ (IOS_SCH\w*?)STAMP,', builds) == [b['prefix'] for b in BUILDS], \
        'every analysed build has a fixture, in table order'
    for index, build in enumerate(BUILDS):
        check_build(index, build, Path(name))
