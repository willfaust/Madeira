#include "SignedFEX.h"
#include "signed_pe_ios.h"
#include "thread_fixture.h"
#include "JITAllocator.h"
#include <assert.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <unistd.h>
#include <setjmp.h>

extern int csops(pid_t, unsigned int, void *, size_t);
bool jit_cs_status(uint32_t *flags) { return !csops(getpid(), 0, flags, sizeof(*flags)); }
struct program {
    void *library;
    const struct MadeiraFEXImage *image;
    vm_address_t mapping;
    vm_size_t size;
    struct MadeiraFEXRuntime *runtime;
    unsigned char *snapshot;
};
static const struct program *guest_dependency;
static int resolve(void *module, const struct MadeiraFEXImport *binding,
                   const struct MadeiraFEXImage *image, struct MadeiraFEXNativeImport *native)
{
    if (!strcasecmp(binding->dll, "cross.dll") && guest_dependency && !strcmp(binding->name, "guest_compare")) {
        *native = (struct MadeiraFEXNativeImport){0}; return 1;
    }
    if (strcasecmp(binding->dll, "ntdll.dll")) return -1;
    return madeira_pe_ec_import(module, binding->name, image->return_ec, image->call_ec,
        image->check_ec, image->check_ec_cfg, &native->target, &native->thunk);
}
static uint16_t u16(const void *p) { uint16_t value; memcpy(&value, p, 2); return value; }
static uint32_t u32(const void *p) { uint32_t value; memcpy(&value, p, 4); return value; }
static uint64_t entry(const struct program *p, const char *name)
{
    const unsigned char *image = (const void *)p->mapping;
    size_t optional = u32(image + 60) + 24, exports = u32(image + optional + 112);
    assert(exports && exports + 40 < p->size);
    const unsigned char *table = image + exports;
    uint32_t count = u32(table + 24), names = u32(table + 32), ordinals = u32(table + 36), functions = u32(table + 28);
    assert(names + count * 4 <= p->size && ordinals + count * 2 <= p->size);
    for (uint32_t i = 0; i < count; ++i) {
        size_t rva = u32(image + names + i * 4);
        assert(rva < p->size && memchr(image + rva, 0, p->size - rva));
        if (strcmp((const char *)image + rva, name)) continue;
        size_t index = u16(image + ordinals + i * 2), slot = functions + index * 4;
        assert(index < u32(table + 20) && slot + 4 <= p->size);
        return p->mapping + u32(image + slot);
    }
    assert(!"Missing context fixture export"); return 0;
}
static struct program load(const char *framework, const char *source, struct madeira_signed_pe *module, uint64_t base, int attach)
{
    struct program p = {0};
    p.library = dlopen(framework, RTLD_NOW | RTLD_LOCAL); assert(p.library);
    p.image = dlsym(p.library, "madeira_fex_image"); assert(p.image && p.image->version == 4);
    p.mapping = base; p.size = p.image->image_size;
    assert(!vm_allocate(mach_task_self(), &p.mapping, p.size, base ? VM_FLAGS_FIXED : VM_FLAGS_ANYWHERE));
    FILE *file = fopen(source, "rb"); assert(file);
    assert(fread((void *)p.mapping, 1, p.size, file) == p.size && fgetc(file) == EOF); fclose(file);
    unsigned char *image = (void *)p.mapping;
    size_t optional = u32(image + 60) + 24;
    size_t position = u32(image + optional + 152), end = position + u32(image + optional + 156);
    assert(end <= p.size);
    while (position < end) {
        assert(position + 8 <= end);
        uint32_t page = u32(image + position), block = u32(image + position + 4);
        assert(block >= 8 && !(block % 2) && block <= end - position);
        for (size_t slot = position + 8; slot < position + block; slot += 2) {
            unsigned relocation = u16(image + slot);
            if (!relocation) continue;
            size_t rva = page + (relocation & 4095);
            assert(relocation >> 12 == 10 && rva <= p.size - 8);
            uint64_t value; memcpy(&value, image + rva, 8);
            uint64_t preferred; memcpy(&preferred, image + optional + 24, 8);
            value += p.mapping - preferred; memcpy(image + rva, &value, 8);
        }
        position += block;
    }
    for (uint64_t i = 0; i < p.image->import_count; ++i) {
        const struct MadeiraFEXImport *binding = p.image->imports + i;
        const void *target = NULL;
        if (!strcasecmp(binding->dll, "ntdll.dll")) target = madeira_pe_export(module, binding->name, 0);
        else if (!strcasecmp(binding->dll, "cross.dll") && guest_dependency) target = (void *)(uintptr_t)entry(guest_dependency, binding->name);
        assert(target);
        memcpy((void *)(p.mapping + binding->iat), &target, 8);
    }
    for (uint64_t i = 0; i < p.image->section_count; ++i) {
        uint64_t start = p.image->sections[i].start, end = p.image->sections[i].end;
        assert(!vm_protect(mach_task_self(), p.mapping + start, end - start, false, VM_PROT_READ));
    }
    if (attach) {
        p.runtime = madeira_signed_fex_open(framework, (void *)p.mapping, p.size, module ? resolve : NULL, module, stdout);
        assert(p.runtime);
    }
    size_t length = p.image->code_end - p.image->code;
    p.snapshot = malloc(length); assert(p.snapshot); memcpy(p.snapshot, p.image->code, length);
    return p;
}
static void unload(struct program *p)
{
    assert(!memcmp(p->snapshot, p->image->code, p->image->code_end - p->image->code));
    free(p->snapshot); assert(!madeira_signed_fex_close(p->runtime));
    assert(!vm_deallocate(mach_task_self(), p->mapping, p->size)); dlclose(p->library);
}
static const uint64_t stop = UINT64_C(0xfee1dead);
static void initial(struct MadeiraFEXContext *context, const struct program *program, unsigned char *stack, size_t size)
{
    memset(context, 0xa5, sizeof(*context));
    context->flags = 0x10000f; context->mxcsr = 0x1f80; context->eflags = 0x202;
    context->cs = 0x33; context->ds = context->es = context->fs = context->gs = context->ss = 0x2b;
    context->gregs[4] = (uintptr_t)stack + size - 72;
    memcpy((void *)(uintptr_t)context->gregs[4], &stop, 8);
    context->rip = program->mapping + program->image->entry - program->image->base;
    uint16_t fcw = 0x37f, fsw = 0x4500;
    memcpy(context->floating, &fcw, 2); memcpy(context->floating + 2, &fsw, 2);
    context->floating[4] = 0xff;
    memcpy(context->floating + 24, &context->mxcsr, 4);
}
static void native_program(const char **argv, FILE *quiet)
{
    struct madeira_signed_pe *module = madeira_pe_open(argv[3], stdout); assert(module);
    uintptr_t teb; assert(!standalone_thread(module, stdout, &teb));
    struct program p = load(argv[1], argv[2], module, 0, 1);
    const size_t size = 2 * 1024 * 1024;
    unsigned char *stack = malloc(size); assert(stack);
    const uint64_t seeds[] = {1, 17, 12345, 0x12345678, 0xfedcba98, UINT64_C(0x100000001)};
    unsigned yields = 0;
    for (unsigned i = 0; i < 6; ++i) {
        struct MadeiraFEXContext context; initial(&context, &p, stack, size);
        context.gregs[1] = seeds[i];
        struct MadeiraFEXContext original = context;
        int result;
        do {
            result = madeira_signed_fex_execute(p.runtime, &context, teb, stack, size, stop, i == 1 ? 10007 : 20000000, quiet);
            if (result == 1) ++yields;
        } while (result == 1 && yields < 100);
        assert(result == 0 && context.rip == stop && context.gregs[4] == original.gregs[4] + 8);
        assert(context.gregs[0] == p.image->reference(seeds[i]));
        const unsigned saved[] = {3, 5, 6, 7, 12, 13, 14, 15};
        for (unsigned j = 0; j < sizeof(saved) / sizeof(saved[0]); ++j) assert(context.gregs[saved[j]] == original.gregs[saved[j]]);
        assert(!memcmp(context.floating + 160 + 6 * 16, original.floating + 160 + 6 * 16, 10 * 16));
        assert(!memcmp(context.home, original.home, sizeof(context.home)) && !memcmp(context.extended, original.extended, sizeof(context.extended)));
    }
    assert(yields > 10 && !madeira_pe_check(module));
    printf("PASS: six real-Wine workloads from caller-owned Windows contexts and stacks; %u resume points, native calls and callbacks.\n", yields);
    free(stack); unload(&p); madeira_pe_close(module);
}
struct worker { const struct program *program; unsigned id; FILE *quiet; };
struct waiter { const struct program *program; FILE *quiet; _Atomic(uint64_t) gate[2]; };
struct message_worker { const struct program *program; FILE *quiet; uint64_t *message; unsigned receive; };
static void *message_run(void *opaque)
{
    struct message_worker *worker = opaque;
    const size_t size = 65536;
    unsigned char *stack = malloc(size); assert(stack);
    struct MadeiraFEXContext context; initial(&context, worker->program, stack, size);
    context.rip = entry(worker->program, worker->receive ? "context_receive" : "context_publish");
    context.gregs[1] = (uintptr_t)worker->message; context.gregs[2] = 10000;
    assert(!madeira_signed_fex_execute(worker->program->runtime, &context, 0, stack, size, stop, UINT64_MAX, worker->quiet));
    assert(!context.gregs[0]); free(stack); return NULL;
}
static void *wait_run(void *argument)
{
    struct waiter *waiter = argument;
    const size_t size = 65536;
    unsigned char *stack = malloc(size); assert(stack);
    struct MadeiraFEXContext context; initial(&context, waiter->program, stack, size);
    context.rip = entry(waiter->program, "context_wait"); context.gregs[1] = (uintptr_t)waiter->gate;
    assert(!madeira_signed_fex_execute(waiter->program->runtime, &context, 0, stack, size, stop, UINT64_MAX, waiter->quiet));
    free(stack); return NULL;
}
static void *thread_run(void *argument)
{
    const struct worker *w = argument;
    const size_t size = 65536;
    unsigned char *stack = malloc(size); assert(stack);
    uintptr_t teb[16] = {0}; teb[6] = (uintptr_t)teb; teb[12] = w->id;
    for (unsigned i = 0; i < 100; ++i) {
        struct MadeiraFEXContext context; initial(&context, w->program, stack, size);
        context.rip = entry(w->program, "context_thread");
        assert(!madeira_signed_fex_execute(w->program->runtime, &context, (uintptr_t)teb, stack, size, stop, 100, w->quiet));
        assert(context.gregs[0] == (uintptr_t)teb && context.gregs[2] == w->id);
    }
    free(stack); return NULL;
}
static void context_program(const char **argv, FILE *quiet)
{
    struct program p = load(argv[4], argv[5], NULL, UINT64_C(0x150000000), 1);
    assert(!madeira_signed_fex_open(argv[4], (void *)p.mapping, p.size - 1, NULL, NULL, quiet));
    uint64_t code = p.mapping + p.image->sections[0].start;
    assert(!vm_protect(mach_task_self(), code, 1, false, VM_PROT_READ | VM_PROT_WRITE));
    assert(!madeira_signed_fex_open(argv[4], (void *)p.mapping, p.size, NULL, NULL, quiet));
    *(unsigned char *)(uintptr_t)code ^= 1;
    assert(!vm_protect(mach_task_self(), code, 1, false, VM_PROT_READ));
    assert(!madeira_signed_fex_open(argv[4], (void *)p.mapping, p.size, NULL, NULL, quiet));
    assert(!vm_protect(mach_task_self(), code, 1, false, VM_PROT_READ | VM_PROT_WRITE));
    *(unsigned char *)(uintptr_t)code ^= 1;
    assert(!vm_protect(mach_task_self(), code, 1, false, VM_PROT_READ));
    const size_t size = 65536;
    unsigned char *stack = malloc(size); assert(stack);
    const unsigned bits[] = {0, 2, 4, 6, 7, 10, 11, 21};
    for (unsigned mask = 0; mask < 256; ++mask) {
        struct MadeiraFEXContext context; initial(&context, &p, stack, size);
        for (unsigned i = 0; i < 8; ++i) if (mask & (1u << i)) context.eflags |= 1u << bits[i];
        struct MadeiraFEXContext original = context;
        assert(!madeira_signed_fex_execute(p.runtime, &context, 0, stack, size, stop, 100, quiet));
        assert(context.gregs[0] == original.eflags && context.eflags == original.eflags);
        assert(!memcmp(context.floating + 32, original.floating + 32, 128));
        assert(!memcmp(context.floating, original.floating, 24));
    }
    {
        struct MadeiraFEXContext context; initial(&context, &p, stack, size); context.flags = 0x10000b;
        context.ds = 0xa1a1; context.es = 0xb2b2; context.fs = 0xc3c3; context.gs = 0xd4d4;
        assert(!madeira_signed_fex_execute(p.runtime, &context, 0, stack, size, stop, 100, quiet));
        assert(context.cs == 0x33 && context.ss == 0x2b && context.ds == 0xa1a1 && context.es == 0xb2b2 &&
               context.fs == 0xc3c3 && context.gs == 0xd4d4);
    }
    for (unsigned mode = 0; mode < 4; ++mode) for (unsigned negative = 0; negative < 2; ++negative) {
        struct MadeiraFEXContext context; initial(&context, &p, stack, size);
        context.rip = entry(&p, "context_round"); context.mxcsr |= mode << 13;
        double value = negative ? -2.5 : 2.5; memcpy(context.floating + 160, &value, 8);
        uint64_t before, after; __asm__ volatile("mrs %0, FPCR" : "=r"(before));
        uint64_t hostile = (before & ~(UINT64_C(3) << 22)) | ((uint64_t)((mode + 1) % 4) << 22) | (UINT64_C(1) << 25);
        __asm__ volatile("msr FPCR, %0" :: "r"(hostile));
        assert(!madeira_signed_fex_execute(p.runtime, &context, 0, stack, size, stop, 100, quiet));
        __asm__ volatile("mrs %0, FPCR\n msr FPCR, %1" : "=r"(after) : "r"(before)); assert(hostile == after);
        int64_t expected = negative ? (mode == 1 ? -3 : -2) : (mode == 2 ? 3 : 2);
        assert((int64_t)context.gregs[0] == expected && (context.mxcsr & 0x6000) == mode << 13);
    }
    {
        struct MadeiraFEXContext context; initial(&context, &p, stack, size);
        context.rip = entry(&p, "context_add");
        uint64_t nan = UINT64_C(0x7ff8000012345678), zero = 0;
        memcpy(context.floating + 160, &nan, 8); memcpy(context.floating + 176, &zero, 8);
        uint64_t before, after; __asm__ volatile("mrs %0, FPCR" : "=r"(before));
        uint64_t changed = before | (UINT64_C(1) << 25); __asm__ volatile("msr FPCR, %0" :: "r"(changed));
        assert(!madeira_signed_fex_execute(p.runtime, &context, 0, stack, size, stop, 100, quiet));
        __asm__ volatile("mrs %0, FPCR\n msr FPCR, %1" : "=r"(after) : "r"(before));
        assert(after == changed && context.gregs[0] == nan);
        initial(&context, &p, stack, size); context.rip = entry(&p, "context_divide");
        double one = 1.0; memcpy(context.floating + 160, &one, 8); memcpy(context.floating + 176, &zero, 8);
        assert(!madeira_signed_fex_execute(p.runtime, &context, 0, stack, size, stop, 100, quiet));
        assert(context.gregs[0] == UINT64_C(0x7ff0000000000000) && (context.mxcsr & 63) == 4);
    }
    for (uint64_t i = 0; i < p.image->cpu_count; ++i) {
        struct MadeiraFEXContext query; initial(&query, &p, stack, size);
        const struct MadeiraFEXCPUID *row = p.image->cpu + i;
        query.rip = entry(&p, "context_cpuid"); query.gregs[0] = row->function;
        query.gregs[1] = row->leaf == UINT32_MAX ? 123456 : row->leaf;
        assert(!madeira_signed_fex_execute(p.runtime, &query, 0, stack, size, stop, 100, quiet));
        assert(query.gregs[0] == row->eax && query.gregs[3] == row->ebx && query.gregs[1] == row->ecx && query.gregs[2] == row->edx);
    }
    for (unsigned index = 0; index < 2; ++index) {
        struct MadeiraFEXContext query; initial(&query, &p, stack, size);
        query.rip = entry(&p, "context_xcr"); query.gregs[1] = index;
        assert(!madeira_signed_fex_execute(p.runtime, &query, 0, stack, size, stop, 100, quiet));
        uint64_t result = query.gregs[0] | query.gregs[2] << 32;
        assert(result == (index ? 0 : p.image->xcr0));
    }
    for (unsigned backward = 0; backward < 2; ++backward) {
        struct MadeiraFEXContext copy; initial(&copy, &p, stack, size);
        for (unsigned i = 0; i < 64; ++i) stack[128 + i] = i * 13;
        memset(stack + 512, 0, 64);
        copy.rip = entry(&p, "context_copy"); copy.gregs[1] = 64;
        copy.gregs[6] = (uintptr_t)stack + 128 + (backward ? 63 : 0);
        copy.gregs[7] = (uintptr_t)stack + 512 + (backward ? 63 : 0);
        if (backward) copy.eflags |= 0x400;
        assert(!madeira_signed_fex_execute(p.runtime, &copy, 0, stack, size, stop, 1000, quiet));
        assert(!memcmp(stack + 128, stack + 512, 64) && !copy.gregs[1] && !!(copy.eflags & 0x400) == backward);
    }
    for (unsigned skew = 0; skew < 16; ++skew) {
        uintptr_t aligned = ((uintptr_t)stack + 16383) & ~(uintptr_t)16383;
        void *source = (void *)(aligned + 16384 - 8 + skew), *destination = (void *)(aligned + 32768 - 8 + skew);
        uint64_t value = UINT64_C(0x1827364554637281) + skew; memcpy(source, &value, 8); memset(destination, 0, 16);
        struct MadeiraFEXContext access; initial(&access, &p, stack, size);
        access.rip = entry(&p, "context_unaligned"); access.gregs[1] = (uintptr_t)source; access.gregs[2] = (uintptr_t)destination;
        assert(!madeira_signed_fex_execute(p.runtime, &access, 0, stack, size, stop, 100, quiet));
        assert(access.gregs[0] == value && !memcmp(source, destination, 2) &&
            !memcmp(source, (char *)destination + 4, 4) && !memcmp(source, (char *)destination + 8, 8));
    }
    uint64_t message[2] = {0}; pthread_t message_threads[2];
    struct message_worker messages[] = {{&p, quiet, message, 0}, {&p, quiet, message, 1}};
    for (unsigned i = 0; i < 2; ++i) assert(!pthread_create(message_threads + i, NULL, message_run, messages + i));
    for (unsigned i = 0; i < 2; ++i) assert(!pthread_join(message_threads[i], NULL));
    assert(message[0] == 10000 && !message[1]);
    puts("PASS: ordinary 16/32/64-bit unaligned accesses across page boundaries and 10000 guest-to-guest message exchanges with prepared memory barriers; code stayed unchanged.");
    struct MadeiraFEXContext context; initial(&context, &p, stack, size);
    context.rip = entry(&p, "context_pause"); context.gregs[0] = 100;
    assert(!madeira_signed_fex_execute(p.runtime, &context, 0, stack, size, entry(&p, "context_resume"), 100, quiet));
    assert(context.gregs[0] == 107);
    assert(!madeira_signed_fex_execute(p.runtime, &context, 0, stack, size, stop, 100, quiet) && context.gregs[0] == 118);
    initial(&context, &p, stack, size); context.rip = entry(&p, "context_loop"); context.gregs[1] = 10000;
    context.eflags = 0x203;
    int result;
    do { result = madeira_signed_fex_execute(p.runtime, &context, 0, stack, size, stop, 127, quiet); } while (result == 1);
    assert(!result && context.gregs[1] == 0 && context.eflags == 0x247);
    initial(&context, &p, stack, size); context.rip = entry(&p, "context_flags_pause");
    context.gregs[1] = 1; context.eflags = 0x203;
    assert(!madeira_signed_fex_execute(p.runtime, &context, 0, stack, size, entry(&p, "context_flags_resume"), 100, quiet));
    assert(context.eflags == 0x247);
    assert(!madeira_signed_fex_execute(p.runtime, &context, 0, stack, size, stop, 100, quiet));
    assert(context.gregs[0] == 0x247 && context.eflags == 0x247);
    const uint32_t rejected[] = {0x10001f, 0x10004f, 0};
    for (unsigned i = 0; i < 3; ++i) {
        initial(&context, &p, stack, size); context.flags = rejected[i];
        struct MadeiraFEXContext original = context;
        assert(madeira_signed_fex_execute(p.runtime, &context, 0, stack, size, stop, 100, quiet) == -1);
        assert(!memcmp(&context, &original, sizeof(context)));
    }
    const uint32_t rejected_mxcsr[] = {0, 0x1fc0, 0x11f80};
    for (unsigned i = 0; i < 3; ++i) {
        initial(&context, &p, stack, size); context.mxcsr = rejected_mxcsr[i];
        struct MadeiraFEXContext original = context;
        assert(madeira_signed_fex_execute(p.runtime, &context, 0, stack, size, stop, 100, quiet) == -1);
        assert(!memcmp(&context, &original, sizeof(context)));
    }
    const char *faults[] = {"context_illegal", "context_unbound", "context_syscall"};
    for (unsigned i = 0; i < 3; ++i) {
        initial(&context, &p, stack, size); context.rip = entry(&p, faults[i]);
        struct MadeiraFEXContext original = context;
        assert(madeira_signed_fex_execute(p.runtime, &context, 0, stack, size, stop, 100, quiet) == -1);
        assert(!memcmp(&context, &original, sizeof(context)));
    }
    struct worker workers[4]; pthread_t threads[4];
    for (unsigned i = 0; i < 4; ++i) { workers[i] = (struct worker){&p, i + 1, quiet}; assert(!pthread_create(threads + i, NULL, thread_run, workers + i)); }
    for (unsigned i = 0; i < 4; ++i) assert(!pthread_join(threads[i], NULL));
    struct waiter waiter = {.program = &p, .quiet = quiet};
    atomic_init(waiter.gate, 0); atomic_init(waiter.gate + 1, 0);
    pthread_t waiting; assert(!pthread_create(&waiting, NULL, wait_run, &waiter));
    for (unsigned i = 0; i < 2000 && !atomic_load(waiter.gate + 1); ++i) usleep(1000);
    assert(atomic_load(waiter.gate + 1));
    struct program second = load(argv[4], argv[5], NULL, UINT64_C(0x160000000), 0);
    assert(!madeira_signed_fex_add(p.runtime, argv[4], (void *)second.mapping, second.size, NULL, NULL, quiet));
    assert(madeira_signed_fex_close(p.runtime) == -1);
    atomic_store(waiter.gate, 1); assert(!pthread_join(waiting, NULL));
    printf("PASS: 256 incoming flag combinations, x87/XMM retention, SSE rounding, %llu CPU queries, direction flags, stop/resume, explicit traps, four host threads, live module publication and active-close refusal.\n", (unsigned long long)p.image->cpu_count);
    free(stack); unload(&p); unload(&second);
}
static void cross_program(const char **argv, FILE *quiet)
{
    struct madeira_signed_pe *module = madeira_pe_open(argv[3], stdout); assert(module);
    uintptr_t teb; assert(!standalone_thread(module, stdout, &teb));
    struct program dependency = load(argv[8], argv[9], module, 0, 0);
    guest_dependency = &dependency;
    struct program p = load(argv[6], argv[7], module, 0, 1);
    const size_t size = 2 * 1024 * 1024;
    unsigned char *stack = malloc(size); assert(stack);
    struct MadeiraFEXContext context; initial(&context, &p, stack, size);
    context.gregs[1] = 17;
    struct MadeiraFEXContext original = context;
    assert(madeira_signed_fex_execute(p.runtime, &context, teb, stack, size, stop, 20000000, quiet) == -1);
    assert(!memcmp(&context, &original, sizeof(context)));
    assert(!madeira_signed_fex_add(p.runtime, argv[8], (void *)dependency.mapping, dependency.size, resolve, module, stdout));
    assert(madeira_signed_fex_add(p.runtime, argv[8], (void *)dependency.mapping, dependency.size, resolve, module, quiet) == -1);
    for (unsigned seed = 1; seed <= 6; ++seed) {
        initial(&context, &p, stack, size); context.gregs[1] = seed;
        int result;
        do { result = madeira_signed_fex_execute(p.runtime, &context, teb, stack, size, stop, 10007, quiet); } while (result == 1);
        assert(!result && context.gregs[0] == p.image->reference(seed));
    }
    assert(!madeira_pe_check(module));
    puts("PASS: separately mapped EXE and DLL, deferred dependency binding, cross-module native callbacks, nested Wine calls and resumed execution; signed bytes unchanged.");
    free(stack); unload(&p); unload(&dependency); madeira_pe_close(module); guest_dependency = NULL;
}
struct native_worker { struct program *program; struct madeira_signed_pe *module; FILE *quiet; unsigned id, refusal; };
static _Thread_local void *last_allocation;
struct native_failure { jmp_buf destination; struct MadeiraFEXRuntime *runtime; };
static void *native_allocate(void *table, int32_t size) { (void)table; return last_allocation = size > 0 ? malloc(size) : NULL; }
static void native_release(void *table, void *value) { (void)table; if (last_allocation == value) last_allocation = NULL; free(value); }
static void callback_failed(void *context, const struct MadeiraFEXContext *cpu)
{
    if (context && cpu->rip == UINT64_C(0x12345678)) {
        struct native_failure *failure = context;
        assert(madeira_signed_fex_unbind_thread(failure->runtime) == -1);
        fputs("PASS: native-first missing callback reached the caller's fatal-error handler without executing guest bytes.\n", stderr);
        longjmp(failure->destination, 1);
    }
    fprintf(stderr, "Unexpected native-first callback failure: rip=0x%llx\n", (unsigned long long)cpu->rip); abort();
}
static void *native_first_run(void *opaque)
{
    struct native_worker *worker = opaque;
    struct program *p = worker->program;
    uintptr_t teb; assert(!standalone_thread(worker->module, worker->quiet, &teb));
    size_t size = pthread_get_stacksize_np(pthread_self());
    void *stack = (unsigned char *)pthread_get_stackaddr_np(pthread_self()) - size;
    struct native_failure failure = {.runtime = p->runtime};
    assert(!madeira_signed_fex_bind_thread(p->runtime, teb, stack, size, callback_failed, worker->refusal ? &failure : NULL, worker->quiet));
    void *binding = p->image->thread_current(); assert(binding);
    assert(madeira_signed_fex_bind_thread(p->runtime, teb, stack, size, callback_failed, NULL, worker->quiet) == -1);
    assert(madeira_signed_fex_close(p->runtime) == -1);
    if (worker->refusal && setjmp(failure.destination)) {
        assert(p->image->thread_current() == binding && !madeira_signed_fex_unbind_thread(p->runtime));
        assert(!p->image->thread_current()); free(last_allocation); last_allocation = NULL; return NULL;
    }
    typedef int (*compare)(void *, const void *, const void *);
    void (*initialize)(void *, compare, void *(*)(void *, int32_t), void (*)(void *, void *), void *) =
        madeira_pe_export(worker->module, "RtlInitializeGenericTable", 0);
    void *(*insert)(void *, const void *, uint32_t, unsigned char *) = madeira_pe_export(worker->module, "RtlInsertElementGenericTable", 0);
    void *(*enumerate)(void *, void **) = madeira_pe_export(worker->module, "RtlEnumerateGenericTableWithoutSplaying", 0);
    unsigned char (*remove)(void *, const void *) = madeira_pe_export(worker->module, "RtlDeleteElementGenericTable", 0);
    assert(initialize && insert && enumerate && remove);
    if (worker->refusal) {
        uint64_t table[80] = {0}, key = 1; unsigned char added;
        initialize(table, (compare)(uintptr_t)0x12345678, native_allocate, native_release, NULL);
        assert(insert(table, &key, sizeof(key), &added));
        ++key; insert(table, &key, sizeof(key), &added);
        assert(!"A missing callback must not return to native Wine");
    }
    for (unsigned round = 0; round < 16; ++round) {
        uint64_t table[80] = {0};
        initialize(table, (compare)(uintptr_t)entry(p, "guest_compare"), native_allocate, native_release, NULL);
        uint64_t base = worker->id * 100000 + round * 32;
        for (unsigned i = 0; i < 32; ++i) {
            uint64_t key = base + (i * 13) % 32;
            unsigned char added = 0;
            uint64_t *value = insert(table, &key, sizeof(key), &added);
            assert(value && *value == key && added);
            value = insert(table, &key, sizeof(key), &added); assert(value && *value == key && !added);
        }
        void *restart = NULL;
        for (unsigned i = 0; i < 32; ++i) { uint64_t *value = enumerate(table, &restart); assert(value && *value == base + i); }
        assert(!enumerate(table, &restart));
        for (unsigned i = 0; i < 32; ++i) { uint64_t key = base + (i * 19) % 32; assert(remove(table, &key)); }
        restart = NULL; assert(!enumerate(table, &restart));
        assert(p->image->thread_current() == binding);
    }
    assert(!madeira_signed_fex_unbind_thread(p->runtime) && !p->image->thread_current());
    assert(madeira_signed_fex_unbind_thread(p->runtime) == -1);
    return NULL;
}
static void native_first_program(const char **argv, FILE *quiet, int refusal)
{
    struct madeira_signed_pe *module = madeira_pe_open(argv[3], stdout); assert(module);
    uintptr_t teb; assert(!standalone_thread(module, stdout, &teb));
    struct program p = load(argv[8], argv[9], module, 0, 1);
    struct native_worker workers[4]; pthread_t threads[4];
    for (unsigned i = 0; i < (refusal ? 1u : 4u); ++i) {
        workers[i] = (struct native_worker){&p, module, quiet, i + 1, refusal};
        assert(!pthread_create(threads + i, NULL, native_first_run, workers + i));
    }
    for (unsigned i = 0; i < (refusal ? 1u : 4u); ++i) assert(!pthread_join(threads[i], NULL));
    assert(!madeira_pe_check(module));
    if (refusal) puts("PASS: the caller stopped a failed native-first operation and unbound on its original stack; active emulator-stack removal was refused.");
    else puts("PASS: native Wine initiated x64 DLL callbacks with no active FEX frame; four bound host threads completed 2048 inserts, duplicate lookups, ordered enumeration and deletes, with nested Wine calls and no code writes.");
    unload(&p); madeira_pe_close(module);
}
static void vector_program(const char **argv, FILE *quiet)
{
    struct program p = load(argv[10], argv[11], NULL, 0, 1);
    const size_t size = 65536;
    unsigned char *stack = malloc(size); assert(stack);
    const char *families[] = {"pshuflw", "pshufhw", "pshufd", "shufps", "pblendw", "dpps", "dppd"};
    for (unsigned family = 0; family < 7; ++family) for (unsigned mask = 0; mask < 256; ++mask) {
        struct MadeiraFEXContext context; initial(&context, &p, stack, size);
        char name[64]; snprintf(name, sizeof(name), "vector_%s_%u_%u", families[family], mask / 16, mask % 16);
        context.rip = entry(&p, name);
        uint16_t a[8] = {1,2,3,4,5,6,7,8}, b[8] = {11,12,13,14,15,16,17,18};
        unsigned char expected[16]; memcpy(expected, a, 16);
        memcpy(context.floating + 160, a, 16); memcpy(context.floating + 176, b, 16);
        if (family < 2) {
            unsigned start = family ? 4 : 0;
            for (unsigned i = 0; i < 4; ++i) memcpy(expected + (start + i) * 2, a + start + ((mask >> (i * 2)) & 3), 2);
        } else if (family < 4) {
            for (unsigned i = 0; i < 4; ++i) {
                const unsigned char *source = (family == 3 && i >= 2) ? (const void *)b : (const void *)a;
                memcpy(expected + i * 4, source + ((mask >> (i * 2)) & 3) * 4, 4);
            }
        } else if (family == 4) {
            for (unsigned i = 0; i < 8; ++i) if (mask & (1u << i)) memcpy(expected + i * 2, b + i, 2);
        } else if (family == 5) {
            float x[4] = {1,2,3,4}, y[4] = {5,6,7,8}, result[4], sum = 0;
            for (unsigned i = 0; i < 4; ++i) if (mask & (16u << i)) sum += x[i] * y[i];
            for (unsigned i = 0; i < 4; ++i) result[i] = mask & (1u << i) ? sum : 0;
            memcpy(context.floating + 160, x, 16); memcpy(context.floating + 176, y, 16); memcpy(expected, result, 16);
        } else {
            double x[2] = {2,3}, y[2] = {5,7}, result[2], sum = 0;
            for (unsigned i = 0; i < 2; ++i) if (mask & (16u << i)) sum += x[i] * y[i];
            for (unsigned i = 0; i < 2; ++i) result[i] = mask & (1u << i) ? sum : 0;
            memcpy(context.floating + 160, x, 16); memcpy(context.floating + 176, y, 16); memcpy(expected, result, 16);
        }
        assert(!madeira_signed_fex_execute(p.runtime, &context, 0, stack, size, stop, 100, quiet));
        if (memcmp(context.floating + 160, expected, 16)) { fprintf(stderr, "Vector result differs: %s mask=%u\n", families[family], mask); abort(); }
    }
    puts("PASS: all 256 immediate controls for PSHUFLW, PSHUFHW, PSHUFD, SHUFPS, PBLENDW, DPPS and DPPD; 1792 vector results matched and signed code stayed unchanged.");
    free(stack); unload(&p);
}
int main(int argc, const char **argv)
{
    assert(argc == 12 || (argc == 13 && !strcmp(argv[12], "--native-refusal")));
    FILE *quiet = fopen("/dev/null", "w"); assert(quiet);
    if (argc == 13) native_first_program(argv, quiet, 1);
    else { native_program(argv, quiet); context_program(argv, quiet); cross_program(argv, quiet); native_first_program(argv, quiet, 0); vector_program(argv, quiet); }
    fclose(quiet);
    return 0;
}
