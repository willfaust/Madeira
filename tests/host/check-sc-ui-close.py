#!/usr/bin/env python3
"""Exercise the bounded message-constructor observer through the Win64 ABI.

Assemble the production hook, compare its embedded bytes, then execute it with
a logger that clobbers volatile inputs. Check original constructor arguments,
payloads, caller identity, return value, nonvolatile registers and concurrent
log limits. The external Helper binary is never executed.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def sch_table(name):
    start = native.index(' ' + name + '[] =')
    return native[start:native.index('\n};', start)]


def define(name):
    return int(re.search(r'#define ' + name + r'\s+(0x[\da-fA-F]+|\d+)', native)[1], 0)


start = native.index('static const unsigned char ios_sch_ui_trace[')
array = native[start:native.index('};', start) + 2]
blob = bytes(int(x, 16) for x in re.findall(r'0x([\da-fA-F]{2})', array))
symbols = {'close_count': define('IOS_SCH_UI_COUNT'), 'helper_log': 0x111340,
           'ctor_continue': define('IOS_SCH_UI_CTOR') + 5,
           'delegate_caller': define('IOS_SCH_UI_DELEGATE_CALLER')}
assert define('IOS_SCH_IPC_SPLIT') + 661 <= define('IOS_SCH_UI_TRACE')
assert define('IOS_SCH_UI_TRACE') + len(blob) <= 0x181000
assert define('IOS_SCH_IPC_CONTEXT') + 16 <= define('IOS_SCH_UI_COUNT')
assert define('IOS_SCH_UI_COUNT') + 4 <= define('IOS_SCH_CACHE')


# The trace is the first build's alone (ios_sch_builds[0]): its tables install
# the observer and its constructor hook; 2.4.0.296's tables carry neither, so that
# build's message constructor runs unmodified.
first_blob, first_hook = sch_table('ios_sch_blob'), sch_table('ios_sch_hook')
later_blob, later_hook = sch_table('ios_sch296_blob'), sch_table('ios_sch296_hook')
assert '{ IOS_SCH_UI_TRACE, ios_sch_ui_trace, sizeof(ios_sch_ui_trace), 0, 0,' in first_blob
assert '{ IOS_SCH_UI_CTOR, IOS_SCH_UI_TRACE, 5, 0xe9, 0 },' in first_hook
assert 'ui_trace' not in later_blob and 'UI_' not in later_hook and not re.search(r'#define IOS_SCH296_UI', native)

with tempfile.TemporaryDirectory(prefix='madeira-ui-close-') as tmp:
    folder = Path(tmp)
    linker = folder / 'trace.ld'
    linker.write_text('SECTIONS { . = %d; .text : { *(.text) } }\n' % define('IOS_SCH_UI_TRACE') +
                      '\n'.join('%s = %d;' % item for item in symbols.items()) + '\n')
    subprocess.run(['as', '--64', str(root / 'tests/host/sc-ui-close.S'), '-o', str(folder / 'trace.o')], check=True)
    subprocess.run(['ld', '-T', str(linker), str(folder / 'trace.o'), '-o', str(folder / 'trace.elf')], check=True)
    subprocess.run(['objcopy', '-O', 'binary', '--only-section=.text',
                    str(folder / 'trace.elf'), str(folder / 'trace.bin')], check=True)
    assert (folder / 'trace.bin').read_bytes() == blob

    source = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>
#define ABI __attribute__((ms_abi))
struct Message { uint32_t value, canary; };
struct WindowPayload { uint32_t value; unsigned char padding[0x184]; uintptr_t hwnd; };
_Static_assert(__builtin_offsetof(struct WindowPayload, hwnd) == 0x188, "guarded window field");
static struct Message *(ABI *entry)(struct Message *, const uint32_t *);
static struct Message *(ABI *delegate)(struct Message *, const uint32_t *);
extern struct Message *ABI probe(struct Message *, const uint32_t *, void *);
extern struct Message *ABI ctor_tail(struct Message *, const uint32_t *);
extern const unsigned char probe_after_call[];
static _Thread_local const uint32_t *expected_source;
static _Thread_local struct Message *expected_message;
static _Thread_local uintptr_t logged_caller;
static _Thread_local int is_delegate;
static atomic_uint logs, bodies;
static void ABI logger(unsigned int level, const char *format, ...)
{
    __builtin_ms_va_list ap;
    __builtin_ms_va_start(ap, format);
    unsigned int value = __builtin_va_arg(ap, unsigned int);
    const uint32_t *source = __builtin_va_arg(ap, const uint32_t *);
    uintptr_t caller = __builtin_va_arg(ap, uintptr_t);
    uintptr_t origin = __builtin_va_arg(ap, uintptr_t);
    uintptr_t hwnd = __builtin_va_arg(ap, uintptr_t);
    __builtin_ms_va_end(ap);
    assert(!level && !strcmp(format, "[sc-ui] msg20005 value=%u source=%p caller=%p origin=%p hwnd=%p"));
    assert(source == expected_source && value == *source && caller);
    if (is_delegate) {
        assert(caller == (uintptr_t)delegate + DELEGATE_RET - DELEGATE);
        assert(origin == (uintptr_t)probe_after_call);
        assert(hwnd == ((const struct WindowPayload *)source)->hwnd);
    } else assert(!origin && !hwnd);
    logged_caller = caller;
    atomic_fetch_add(&logs, 1);
    __asm__ volatile("xor %%ecx, %%ecx; xor %%edx, %%edx; xor %%r8d, %%r8d; xor %%r9d, %%r9d;"
                     "pxor %%xmm0, %%xmm0; pxor %%xmm1, %%xmm1; pxor %%xmm2, %%xmm2;"
                     "pxor %%xmm3, %%xmm3; pxor %%xmm4, %%xmm4; pxor %%xmm5, %%xmm5"
                     : : : "rcx", "rdx", "r8", "r9", "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5");
}
struct Message *ABI original_ctor(struct Message *m, const uint32_t *source, uintptr_t caller)
{
    assert(m == expected_message && source == expected_source && m->canary == 0xdead1234);
    if (logged_caller) assert(logged_caller == caller);
    m->value = *source;
    atomic_fetch_add(&bodies, 1);
    return m;
}
static void stub(char *image, size_t rva, uintptr_t target)
{
    unsigned char code[12] = {0x48,0xb8,0,0,0,0,0,0,0,0,0xff,0xe0};
    memcpy(code+2, &target, 8);
    memcpy(image+rva, code, sizeof(code));
}
static void invoke(uint32_t value, int via_delegate)
{
    struct WindowPayload payload = {.value = value, .hwnd = 0x200ec ^ (uintptr_t)value};
    struct Message m = {0xcccccccc, 0xdead1234};
    expected_source = &payload.value; expected_message = &m; logged_caller = 0; is_delegate = via_delegate;
    assert(probe(&m, &payload.value, via_delegate ? delegate : entry) == &m);
    assert(m.value == value && payload.value == value && m.canary == 0xdead1234);
}
static void guarded_unknown(void)
{
    size_t page = sysconf(_SC_PAGESIZE);
    char *memory = mmap(NULL, page * 2, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(memory != MAP_FAILED && !mprotect(memory, page, PROT_READ | PROT_WRITE));
    uint32_t *payload = (uint32_t *)(memory + page - sizeof(*payload));
    *payload = 1;
    struct Message m = {0, 0xdead1234};
    expected_source = payload; expected_message = &m; logged_caller = 0; is_delegate = 0;
    /* The new HWND read would fault here if applied to an unknown caller. */
    assert(probe(&m, payload, entry) == &m && m.value == 1);
    assert(!munmap(memory, page * 2));
}
static void *worker(void *unused)
{
    (void)unused;
    for (unsigned i=0; i<24; i++) invoke(i, i & 1);
    return NULL;
}
''' + array + r'''
int main(void)
{
    char *image = mmap(NULL, 0x244000, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(image != MAP_FAILED);
    memcpy(image + TRACE, ios_sch_ui_trace, sizeof(ios_sch_ui_trace));
    image[CTOR] = (char)0xe9;
    int32_t displacement = TRACE - CTOR - 5;
    memcpy(image + CTOR + 1, &displacement, sizeof(displacement));
    stub(image, 0x111340, (uintptr_t)logger);
    stub(image, CTOR + 5, (uintptr_t)ctor_tail);
    /* Reproduce the guarded delegate's PUSH RBX / SUB RSP,0x20 frame and
     * constructor CALL at its exact image offset. No external code runs. */
    const unsigned char frame[] = {0x40,0x53,0x48,0x83,0xec,0x20};
    const unsigned char epilogue[] = {0x48,0x83,0xc4,0x20,0x5b,0xc3};
    memcpy(image + DELEGATE, frame, sizeof(frame));
    memset(image + DELEGATE + sizeof(frame), 0x90, DELEGATE_RET - 5 - DELEGATE - sizeof(frame));
    image[DELEGATE_RET - 5] = (char)0xe8;
    displacement = CTOR - DELEGATE_RET;
    memcpy(image + DELEGATE_RET - 4, &displacement, sizeof(displacement));
    memcpy(image + DELEGATE_RET, epilogue, sizeof(epilogue));
    assert(!mprotect(image + 0x1000, 0x180000, PROT_READ | PROT_EXEC));
    entry = (void *)(image + CTOR);
    delegate = (void *)(image + DELEGATE);
    invoke(0, 0); invoke(1, 0); invoke(UINT32_MAX, 0);
    invoke(0, 1); invoke(1, 1); invoke(UINT32_MAX, 1);
    guarded_unknown();
    assert(logs == 7 && bodies == 7);
    pthread_t threads[6];
    for (unsigned i=0; i<6; i++) assert(!pthread_create(&threads[i], NULL, worker, NULL));
    for (unsigned i=0; i<6; i++) assert(!pthread_join(threads[i], NULL));
    assert(logs == 16 && bodies == 151 && *(unsigned int *)(image + COUNT) >= 16);
    assert(!munmap(image, 0x244000));
    puts("PASS: observer retains delivery/state, identifies delegate parent/HWND, bounds unknown sources; 151 deliveries, 16 concurrent records");
    return 0;
}
'''
    probe = r'''
.intel_syntax noprefix
.text
.global probe
probe:
    push rbx
    push rsi
    push rdi
    sub rsp, 0x20
    mov rbx, 0x1122334455667788
    mov rsi, 0x2233445566778899
    mov rdi, 0x33445566778899aa
    call r8
.global probe_after_call
probe_after_call:
    mov r9, 0x1122334455667788
    cmp rbx, r9
    jne broken
    mov r9, 0x2233445566778899
    cmp rsi, r9
    jne broken
    mov r9, 0x33445566778899aa
    cmp rdi, r9
    jne broken
    add rsp, 0x20
    pop rdi
    pop rsi
    pop rbx
    ret
broken:
    ud2
/* Model the original constructor's stack frame and RBX home-slot restore,
 * rather than letting a fresh C prologue hide a missing displaced store. */
.global ctor_tail
ctor_tail:
    push rdi
    sub rsp, 0x20
    mov rbx, rdx
    mov rdi, rcx
    mov r8, qword ptr [rsp+0x28]
    call original_ctor
    mov rbx, qword ptr [rsp+0x38]
    mov rax, rdi
    add rsp, 0x20
    pop rdi
    ret
.section .note.GNU-stack,"",@progbits
'''
    c, asm = folder / 'test.c', folder / 'probe.S'
    c.write_text(source); asm.write_text(probe)
    binary = folder / 'test'
    subprocess.run(['cc', '-std=gnu11', '-O1', '-Wall', '-fsanitize=address,undefined',
                    '-fno-sanitize-recover=all', '-pthread',
                    '-DTRACE=%d' % define('IOS_SCH_UI_TRACE'), '-DCTOR=%d' % define('IOS_SCH_UI_CTOR'),
                    '-DCOUNT=%d' % define('IOS_SCH_UI_COUNT'), '-DDELEGATE=0x32070',
                    '-DDELEGATE_RET=%d' % define('IOS_SCH_UI_DELEGATE_CALLER'),
                    str(c), str(asm), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    print('PASS: observer assembly matches production bytes and occupies disjoint zero tails')
