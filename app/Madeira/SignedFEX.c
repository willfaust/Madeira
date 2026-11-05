#include "SignedFEX.h"
#include "SignedCodeProbe.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <setjmp.h>
#include <TargetConditionals.h>
#include <CommonCrypto/CommonDigest.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>

static bool memory_access(const void *pointer, size_t length, int required, int forbidden)
{
    uintptr_t cursor = (uintptr_t)pointer, end = cursor + length;
    if (!length || end < cursor) return false;
    while (cursor < end) {
        vm_address_t address = cursor;
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info = {0};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t status = vm_region_64(mach_task_self(), &address, &size,
            VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
        if (object) mach_port_deallocate(mach_task_self(), object);
        if (status != KERN_SUCCESS || address > cursor || !size || size > UINTPTR_MAX - address ||
            (info.protection & required) != required || (info.protection & forbidden)) return false;
        cursor = address + size;
    }
    return true;
}
static bool executable(const void *pointer, size_t length)
{
    return memory_access(pointer, length, VM_PROT_READ | VM_PROT_EXECUTE, VM_PROT_WRITE);
}

static const void *lookup(const struct MadeiraFEXImage *image, uint64_t base, uint64_t rip)
{
    if (rip < base || rip - base >= image->image_size) return NULL;
    rip = image->base + (rip - base);
    size_t low = 0, high = image->entry_count;
    while (low < high) {
        size_t middle = low + (high - low) / 2;
        if (image->entries[middle].guest < rip) low = middle + 1;
        else high = middle;
    }
    return low < image->entry_count && image->entries[low].guest == rip ?
        image->code + image->entries[low].offset : NULL;
}

static const uint64_t import_base = UINT64_C(0x7ffe00000000);
struct guest_range { uint64_t base, size; };
struct module {
    void *library;
    const struct MadeiraFEXImage *image;
    struct MadeiraFEXNativeImport *native;
    uint64_t *addresses;
    uint64_t base;
};
struct MadeiraFEXRuntime {
    pthread_mutex_t lock;
    uint64_t active, bound;
    uint64_t validated_count;
    _Atomic(uint64_t) count;
    struct module modules[64];
    struct guest_range ranges[64];
};
static int image_valid(const struct MadeiraFEXImage *image)
{
    if (!image || image->version < 1 || image->version > 4 || image->image_size < 64 ||
        image->image_size > 16 * 1024 * 1024 || image->base > UINT64_MAX - image->image_size ||
        image->frame_size < 256 || image->frame_size > 1024 * 1024 ||
        image->gregs_offset > image->frame_size - 128 || image->rip_offset > image->frame_size - 8 ||
        !image->entry_count || image->entry_count > 100000 || !image->section_count || image->section_count > 96 ||
        !image->entries || !image->sections || !image->initialize || !image->enter ||
        (uintptr_t)image->code_end <= (uintptr_t)image->code ||
        (uintptr_t)image->code_end - (uintptr_t)image->code > 32 * 1024 * 1024 ||
        (image->version >= 3 && (image->gs_offset > image->frame_size - 8 ||
                               image->xmm_offset > image->frame_size - 256 ||
                               image->callback_offset > image->frame_size - 16)) ||
        (image->version >= 4 && (!image->load_context || !image->store_context || !image->guest_code_hash ||
                                !image->abi_hash || image->ranges_offset > image->frame_size - 16 ||
                                image->fault_offset > image->frame_size - 8 || !image->cpu || image->cpu_count > 20000 ||
                                image->base_offset > image->frame_size - 8 ||
                                !image->thread_current || !image->thread_exchange))) return 0;
    size_t code_size = (uintptr_t)image->code_end - (uintptr_t)image->code;
    if (!executable(image->code, code_size)) return 0;
    for (uint64_t i = 0; i < image->entry_count; ++i)
        if (image->entries[i].offset >= code_size || image->entries[i].offset % 4 ||
            image->entries[i].guest < image->base || image->entries[i].guest - image->base >= image->image_size ||
            (i && image->entries[i - 1].guest >= image->entries[i].guest)) return 0;
    for (uint64_t i = 0; i < image->section_count; ++i)
        if (image->sections[i].start >= image->sections[i].end || image->sections[i].end > image->image_size ||
            (i && image->sections[i - 1].end > image->sections[i].start)) return 0;
    return 1;
}
struct execution {
    const struct MadeiraFEXImage *image;
    struct MadeiraFEXNativeImport *native;
    MadeiraFEXImportCall call;
    void *context;
    FILE *report;
    uint64_t teb, blocks, imports, callbacks;
    uint64_t stack_low, stack_high, budget, hard_budget;
    uint64_t base;
    struct MadeiraFEXRuntime *runtime;
    struct guest_range local_range;
    _Atomic(uint64_t) local_count;
    void *root;
    size_t import_count;
    unsigned depth;
    void *children[64];
    jmp_buf failure;
};
static void native_callback(void *context, void *saved);
struct thread_binding {
    void *frame;
    void (*call)(void *, void *);
    void *context;
    uintptr_t host_stack;
    const struct guest_range *ranges;
    const _Atomic(uint64_t) *count;
};
_Static_assert(sizeof(struct thread_binding) == 48 && offsetof(struct thread_binding, ranges) == 32,
               "ARM64 thread binding ABI");
static void bind_callback(struct execution *run, void *frame)
{
    struct { void (*call)(void *, void *); void *context; } binding = {native_callback, run};
    _Static_assert(sizeof(binding) == 16, "ARM64 callback binding ABI");
    memcpy((unsigned char *)frame + run->image->callback_offset, &binding, sizeof(binding));
    if (run->image->version >= 4) {
        struct { const struct guest_range *ranges; const _Atomic(uint64_t) *count; } regions = {
            run->runtime ? run->runtime->ranges : &run->local_range,
            run->runtime ? &run->runtime->count : &run->local_count
        };
        memcpy((unsigned char *)frame + run->image->ranges_offset, &regions, sizeof(regions));
    }
}
static int dispatch(struct execution *run, void *frame, uint64_t sentinel)
{
    const struct MadeiraFEXImage *image = run->image;
    uint64_t *gregs = (void *)((unsigned char *)frame + image->gregs_offset);
    uint64_t *rip = (void *)((unsigned char *)frame + image->rip_offset);
    while (*rip != sentinel && (run->blocks < run->budget || (run->depth && run->blocks < run->hard_budget))) {
        const struct MadeiraFEXImage *selected = image;
        uint64_t base = run->base;
        const void *entry = NULL;
        const struct MadeiraFEXNativeImport *native = NULL;
        if (run->runtime) {
            uint64_t count = atomic_load_explicit(&run->runtime->count, memory_order_acquire);
            for (uint64_t i = 0; i < count; ++i) {
                const struct module *module = run->runtime->modules + i;
                entry = lookup(module->image, module->base, *rip);
                if (entry) { selected = module->image; base = module->base; break; }
            }
            if (!entry) for (uint64_t i = 0; i < count && !native; ++i) {
                const struct module *module = run->runtime->modules + i;
                for (uint64_t j = 0; j < module->image->import_count; ++j)
                    if (module->addresses[j] == *rip && module->native[j].target) { native = module->native + j; break; }
            }
        } else entry = lookup(image, base, *rip);
        size_t index = run->import_count;
        struct thread_binding binding = {frame, native_callback, run, 0,
            run->runtime ? run->runtime->ranges : &run->local_range,
            run->runtime ? &run->runtime->count : &run->local_count};
        if (!run->runtime && *rip >= import_base && (*rip - import_base) % 16 == 0 && (*rip - import_base) / 16 < run->import_count)
            index = (*rip - import_base) / 16;
        if (!entry && (native || index < run->import_count)) {
            uint64_t stack = gregs[4];
            if (stack < run->stack_low || stack > run->stack_high - 40 || stack % 8) return 1;
            if (native || run->native) {
                if ((stack + 8) % 16) return 1;
                if (!native) native = run->native + index;
                void *previous = image->version >= 4 ? image->thread_exchange(&binding) : NULL;
                image->enter_ec(frame, native->target, native->thunk);
                if (image->version >= 4) image->thread_exchange(previous);
            } else {
                if (run->call(run->context, image->imports + index, gregs)) return 1;
                memcpy(rip, (void *)(uintptr_t)stack, 8);
                gregs[4] += 8;
            }
            ++run->imports;
        } else {
            if (!entry) {
                fprintf(run->report, "FAIL: missing pretranslated RIP=0x%llx; JIT fallback is disabled.\n",
                        (unsigned long long)*rip);
                return 1;
            }
            if (image->version >= 4) memcpy((unsigned char *)frame + image->base_offset, &base, 8);
            void *previous = image->version >= 4 ? image->thread_exchange(&binding) : NULL;
            selected->enter(frame, entry);
            if (image->version >= 4) image->thread_exchange(previous);
        }
        if (image->version >= 4) {
            uint64_t fault; memcpy(&fault, (unsigned char *)frame + image->fault_offset, 8);
            if (fault) {
                fprintf(run->report, "FAIL: guest trap or unsupported runtime helper: fault=0x%llx rip=0x%llx.\n",
                    (unsigned long long)fault, (unsigned long long)*rip);
                return 1;
            }
        }
        ++run->blocks;
    }
    return *rip == sentinel ? 0 : 2;
}
static const unsigned buddy[16] = {8,0,1,27,31,29,25,26,2,3,4,5,19,20,21,22};
static void read_ec_fp(const unsigned char *copy, struct MadeiraFEXContext *context)
{
    uint64_t fpcr, fpsr;
    memcpy(&fpcr, copy + 512, 8); memcpy(&fpsr, copy + 520, 8);
    uint32_t mode = (fpcr >> 22) & 3;
    mode = ((mode & 1) << 1) | ((mode & 2) >> 1);
    context->mxcsr = (context->mxcsr & ~0xe03fu) | (mode << 13) |
        ((fpcr >> 9) & 0x8000) | (fpsr & 1) | ((fpsr & 0x1e) << 1) | ((fpsr >> 6) & 2);
}
static void write_ec_fp(unsigned char *copy, const struct MadeiraFEXContext *context)
{
    uint64_t fpcr, fpsr;
    memcpy(&fpcr, copy + 512, 8); memcpy(&fpsr, copy + 520, 8);
    uint32_t mode = (context->mxcsr >> 13) & 3;
    mode = ((mode & 1) << 1) | ((mode & 2) >> 1);
    fpcr = (fpcr & ~(UINT64_C(7) << 22)) | ((uint64_t)mode << 22) | ((uint64_t)(context->mxcsr & 0x8000) << 9);
    fpsr = (fpsr & ~UINT64_C(0x9f)) | (context->mxcsr & 1) |
        ((context->mxcsr & 0x3c) >> 1) | ((context->mxcsr & 2) << 6);
    memcpy(copy + 512, &fpcr, 8); memcpy(copy + 520, &fpsr, 8);
}
static void native_callback(void *context, void *saved)
{
    struct execution *run = context;
    const struct MadeiraFEXImage *image = run->image;
    uintptr_t address = (uintptr_t)saved;
    if (run->depth == 64 || address < run->stack_low ||
        address > run->stack_high - 1024) longjmp(run->failure, 1);
    unsigned char copy[1024];
    memcpy(copy, saved, sizeof(copy));
    uint64_t registers[32];
    memcpy(registers, copy, sizeof(registers));
    if (registers[31] != address + 1024 || registers[31] % 16) longjmp(run->failure, 1);
    unsigned level = run->depth++;
    if (posix_memalign(run->children + level, 64, image->frame_size)) longjmp(run->failure, 1);
    void *frame = run->children[level];
    image->initialize(frame);
    if (image->version >= 4) memcpy((unsigned char *)frame + image->base_offset, &run->base, 8);
    bind_callback(run, frame);
    memcpy((unsigned char *)frame + image->gs_offset, &run->teb, 8);
    uint64_t *gregs = (void *)((unsigned char *)frame + image->gregs_offset);
    for (unsigned i = 0; i < 16; ++i) gregs[i] = registers[buddy[i]];
    const uint64_t sentinel = UINT64_C(0xfee1cabb);
    gregs[4] -= 8;
    memcpy((void *)(uintptr_t)gregs[4], &sentinel, 8);
    memcpy((unsigned char *)frame + image->xmm_offset, copy + 256, 256);
    memcpy((unsigned char *)frame + image->rip_offset, registers + 9, 8);
    struct MadeiraFEXContext context_state;
    if (image->version >= 4) {
        void *parent = (void *)(uintptr_t)registers[28];
        int known = parent == run->root;
        for (unsigned i = 0; i < level; ++i) if (parent == run->children[i]) known = 1;
        if (!known) longjmp(run->failure, 1);
        memset(&context_state, 0, sizeof(context_state));
        context_state.flags = 0x10000f;
        image->store_context(parent, &context_state);
        memcpy(context_state.gregs, gregs, 128);
        memcpy(context_state.floating + 160, copy + 256, 256);
        context_state.rip = registers[9];
        read_ec_fp(copy, &context_state);
        context_state.eflags = 0x202;
        if (image->load_context(frame, &context_state, run->teb)) longjmp(run->failure, 1);
    }
    if (dispatch(run, frame, sentinel) || gregs[4] != registers[31]) longjmp(run->failure, 1);
    if (image->version >= 4) {
        image->store_context(frame, &context_state);
        write_ec_fp(copy, &context_state);
    }
    for (unsigned i = 0; i < 16; ++i) if (i != 4) registers[buddy[i]] = gregs[i];
    memcpy(copy, registers, sizeof(registers));
    memcpy(copy + 256, (unsigned char *)frame + image->xmm_offset, 256);
    /* The callback's guest stack can overwrite the saved EC frame below its caller's SP. */
    memcpy(saved, copy, sizeof(copy));
    free(frame); run->children[level] = NULL;
    --run->depth; ++run->callbacks;
}

static int run(const char *framework, const char *guest_image, FILE *report,
               MadeiraFEXImportCall call, MadeiraFEXImportResolve resolve, void *context, uint64_t teb);

int madeira_signed_fex_run(const char *framework, const char *guest_image, FILE *report)
{
    return madeira_signed_fex_run_with_imports(framework, guest_image, report, NULL, NULL);
}

int madeira_signed_fex_run_with_imports(const char *framework, const char *guest_image, FILE *report,
                                      MadeiraFEXImportCall call, void *context)
{
    return run(framework, guest_image, report, call, NULL, context, 0);
}

int madeira_signed_fex_run_native(const char *framework, const char *guest_image, FILE *report,
                                 MadeiraFEXImportResolve resolve, void *context, uint64_t teb)
{
    return run(framework, guest_image, report, NULL, resolve, context, teb);
}

static int run(const char *framework, const char *guest_image, FILE *report,
               MadeiraFEXImportCall call, MadeiraFEXImportResolve resolve, void *context, uint64_t teb)
{
#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
    fprintf(report, "FEX signed-program runner v1 platform=ios-device: pretranslated x86-64 PE, no runtime compiler.\n");
#else
    fprintf(report, "FEX signed-program runner v1 platform=host-only: pretranslated x86-64 PE, no runtime compiler.\n");
#endif
    if (!madeira_signed_execution_eligible(report)) return 2;
    if (!framework || !guest_image) return 1;
    void *library = dlopen(framework, RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(report, "FAIL: dlopen: %s\n", dlerror()); return 1; }
    const struct MadeiraFEXImage *image = dlsym(library, "madeira_fex_image");
    int result = 1;
    void *frame = NULL;
    unsigned char *snapshot = NULL;
    vm_address_t guest = 0;
    vm_size_t allocation = 0;
    struct MadeiraFEXNativeImport *native = NULL;
    struct execution *execution = NULL;
    void *previous_binding = NULL;
    bool has_binding = false;
    if (!image_valid(image) || !image->reference || image->base != UINT64_C(0x130000000)) {
        fprintf(report, "FAIL: invalid signed FEX image descriptor.\n"); goto done;
    }
    has_binding = image->version >= 4;
    if (has_binding) previous_binding = image->thread_current();
    size_t code_size = (uintptr_t)image->code_end - (uintptr_t)image->code;
    size_t import_count = image->version >= 2 ? image->import_count : 0;
    if (import_count > 1024 || (import_count && ((!call && !resolve) || !image->imports)) ||
        (image->version >= 3 && (image->gs_offset > image->frame_size - 8 ||
                                image->callback_offset > image->frame_size - 16)) ||
        (image->version >= 4 && (!image->load_context || !image->store_context || !image->guest_code_hash)) ||
        (resolve && (image->version < 3 || !image->enter_ec || !image->return_ec ||
                     image->xmm_offset > image->frame_size - 256 ||
                     !image->call_ec || !image->check_ec || !image->check_ec_cfg))) {
        fprintf(report, "FAIL: this PE needs an explicit native import bridge.\n"); goto done;
    }
    if (posix_memalign(&frame, 64, image->frame_size)) goto done;
    snapshot = malloc(code_size);
    if (!snapshot) goto done;
    memcpy(snapshot, image->code, code_size);
    if (resolve && import_count) {
        native = calloc(import_count, sizeof(*native));
        if (!native) goto done;
        for (size_t i = 0; i < import_count; ++i)
            if (resolve(context, image->imports + i, image, native + i) ||
                !native[i].target || !native[i].thunk || !executable(native[i].target, 4) ||
                !executable(native[i].thunk, 4)) {
                fprintf(report, "FAIL: ARM64EC import resolution refused.\n"); goto done;
            }
    }
    allocation = ((image->image_size + 16383) & ~UINT64_C(16383)) + 2 * 1024 * 1024;
    guest = image->base;
    if (vm_allocate(mach_task_self(), &guest, allocation, VM_FLAGS_FIXED) != KERN_SUCCESS) {
        guest = 0;
        fprintf(report, "FAIL: guest address is occupied; no mapping was replaced.\n"); goto done;
    }
    FILE *input = fopen(guest_image, "rb");
    if (!input) { fprintf(report, "FAIL: guest image is missing.\n"); goto done; }
    bool read = fread((void *)guest, 1, image->image_size, input) == image->image_size;
    read = read && fgetc(input) == EOF && !ferror(input);
    fclose(input);
    if (!read) { fprintf(report, "FAIL: guest image size differs from its descriptor.\n"); goto done; }
    for (size_t i = 0; i < import_count; ++i) {
        const struct MadeiraFEXImport *binding = image->imports + i;
        if (!binding->dll || !binding->name || binding->iat > image->image_size - 8 || binding->iat % 8) {
            fprintf(report, "FAIL: invalid native import binding.\n"); goto done;
        }
        uint64_t target = import_base + i * 16;
        memcpy((void *)(guest + binding->iat), &target, 8);
    }
    for (uint64_t i = 0; i < image->section_count; ++i) {
        uint64_t start = image->sections[i].start, end = image->sections[i].end;
        if (start >= end || end > image->image_size || start % 16384 ||
            vm_protect(mach_task_self(), guest + start, (end - start + 16383) & ~UINT64_C(16383),
                false, VM_PROT_READ) != KERN_SUCCESS) {
            fprintf(report, "FAIL: cannot protect guest text against writes.\n"); goto done;
        }
    }
    const uint64_t sentinel = UINT64_C(0xfee1dead);
    const uint64_t seeds[] = {1, 17, 12345, UINT64_C(0x12345678), UINT64_C(0xfedcba98), UINT64_C(0x100000001)};
    uint64_t total_blocks = 0;
    execution = calloc(1, sizeof(*execution));
    if (!execution) goto done;
    execution->image = image; execution->native = native; execution->call = call;
    execution->context = context; execution->report = report;
    execution->teb = teb;
    execution->base = guest;
    execution->local_range = (struct guest_range){guest, image->image_size};
    atomic_init(&execution->local_count, 1);
    execution->stack_low = guest + ((image->image_size + 16383) & ~UINT64_C(16383));
    execution->stack_high = guest + allocation; execution->budget = 20000000; execution->root = frame;
    execution->hard_budget = execution->budget;
    execution->import_count = import_count;
    if (setjmp(execution->failure)) {
        fprintf(report, "FAIL: ARM64EC callback dispatch refused.\n"); goto done;
    }
    fprintf(report, "entries=%llu translated-bytes=%zu runs=%zu guest-text=read-only guest-stack=non-executable\n",
        (unsigned long long)image->entry_count, code_size, sizeof(seeds) / sizeof(seeds[0]));
    for (unsigned test = 0; test < sizeof(seeds) / sizeof(seeds[0]); ++test) {
        image->initialize(frame);
        if (image->version >= 3) {
            memcpy((unsigned char *)frame + image->gs_offset, &teb, 8);
            bind_callback(execution, frame);
        }
        uint64_t *gregs = (uint64_t *)((unsigned char *)frame + image->gregs_offset);
        uint64_t *rip = (uint64_t *)((unsigned char *)frame + image->rip_offset);
        gregs[1] = seeds[test];
        gregs[4] = guest + allocation - 72;
        *(uint64_t *)(uintptr_t)gregs[4] = sentinel;
        *rip = image->entry;
        struct timespec start, end;
        clock_gettime(CLOCK_MONOTONIC, &start);
        execution->blocks = 0;
        if (dispatch(execution, frame, sentinel)) {
            fprintf(report, "FAIL: program dispatch refused or exceeded its budget.\n"); goto done;
        }
        uint64_t blocks = execution->blocks;
        clock_gettime(CLOCK_MONOTONIC, &end);
        uint64_t expected = image->reference(seeds[test]);
        double seconds = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) * 1e-9;
        fprintf(report, "seed=%llu result=0x%llx expected=0x%llx blocks=%llu seconds=%.6f\n",
            (unsigned long long)seeds[test], (unsigned long long)gregs[0],
            (unsigned long long)expected, (unsigned long long)blocks, seconds);
        if (gregs[0] != expected || memcmp(snapshot, image->code, code_size)) {
            fprintf(report, "FAIL: program result or immutable code check differs.\n"); goto done;
        }
        total_blocks += blocks;
    }
    if (!madeira_signed_execution_eligible(report)) { result = 2; goto done; }
    fprintf(report, "PASS: six complete x86-64 program runs, %llu block transitions, code unchanged.\n",
        (unsigned long long)total_blocks);
    if (import_count) fprintf(report, "native-imports=%llu distinct-imports=%zu\n",
                             (unsigned long long)execution->imports, import_count);
    if (execution->callbacks) fprintf(report, "native-to-x64-callbacks=%llu\n", (unsigned long long)execution->callbacks);
    result = 0;
done:
    if (has_binding) image->thread_exchange(previous_binding);
    if (guest) vm_deallocate(mach_task_self(), guest, allocation);
    free(frame);
    free(snapshot);
    free(native);
    if (execution) for (unsigned i = 0; i < 64; ++i) free(execution->children[i]);
    free(execution);
    dlclose(library);
    return result;
}


int madeira_signed_fex_close(struct MadeiraFEXRuntime *runtime)
{
    if (!runtime) return 0;
    pthread_mutex_lock(&runtime->lock);
    if (runtime->active || runtime->bound) { pthread_mutex_unlock(&runtime->lock); return -1; }
    uint64_t count = atomic_load(&runtime->count);
    for (uint64_t i = 0; i < count; ++i) {
        struct module *module = runtime->modules + i;
        free(module->addresses); free(module->native);
        dlclose(module->library);
    }
    pthread_mutex_unlock(&runtime->lock);
    pthread_mutex_destroy(&runtime->lock);
    free(runtime);
    return 0;
}

int madeira_signed_fex_add(struct MadeiraFEXRuntime *runtime, const char *framework, void *mapped_image, size_t size,
    MadeiraFEXImportResolve resolve, void *context, FILE *report)
{
    if (!runtime || !report || !framework || !mapped_image || !madeira_signed_execution_eligible(report)) return -1;
    struct module module = {0};
    int result = -1;
    pthread_mutex_lock(&runtime->lock);
    uint64_t count = atomic_load_explicit(&runtime->count, memory_order_acquire);
    if (count == 64) goto done;
    module.library = dlopen(framework, RTLD_NOW | RTLD_LOCAL);
    if (!module.library) goto done;
    const struct MadeiraFEXImage *image = module.image = dlsym(module.library, "madeira_fex_image");
    if (!image_valid(image) || image->version < 4 || (uintptr_t)mapped_image % 16384 ||
        size != image->image_size || image->import_count > 1024 ||
        !memory_access(mapped_image, size, VM_PROT_READ, VM_PROT_EXECUTE) ||
        (image->import_count && (!resolve || !image->imports || !image->enter_ec || !image->return_ec ||
                                !image->call_ec || !image->check_ec || !image->check_ec_cfg))) goto done;
    if (count && memcmp(image->abi_hash, runtime->modules[0].image->abi_hash, 32)) goto done;
    for (uint64_t i = 0; i < count; ++i) {
        const struct guest_range *range = runtime->ranges + i;
        if ((uintptr_t)mapped_image < range->base + range->size && range->base < (uintptr_t)mapped_image + size) goto done;
    }
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    for (uint64_t i = 0; i < image->section_count; ++i) {
        const struct MadeiraFEXSection *section = image->sections + i;
        const void *bytes = (const unsigned char *)mapped_image + section->start;
        size_t length = section->end - section->start;
        if (!memory_access(bytes, length, VM_PROT_READ, VM_PROT_WRITE | VM_PROT_EXECUTE)) goto done;
        CC_SHA256_Update(&hash, &section->start, 8); CC_SHA256_Update(&hash, &section->end, 8);
        CC_SHA256_Update(&hash, bytes, (CC_LONG)length);
    }
    unsigned char digest[32]; CC_SHA256_Final(digest, &hash);
    if (memcmp(digest, image->guest_code_hash, 32)) goto done;
    module.base = (uintptr_t)mapped_image;
    if (image->import_count) {
        module.native = calloc(image->import_count, sizeof(*module.native));
        module.addresses = calloc(image->import_count, sizeof(*module.addresses));
        if (!module.native || !module.addresses) goto done;
        const struct MadeiraFEXImage *bridge = count ? runtime->modules[0].image : image;
        for (uint64_t i = 0; i < image->import_count; ++i) {
            const struct MadeiraFEXImport *binding = image->imports + i;
            if (!binding->dll || !binding->name || binding->iat > size - 8 || binding->iat % 8) goto done;
            int kind = resolve(context, binding, bridge, module.native + i);
            if (kind != 0 && kind != 1) goto done;
            if (!kind && (!module.native[i].target || !module.native[i].thunk ||
                !executable(module.native[i].target, 4) || !executable(module.native[i].thunk, 4))) goto done;
            if (kind) module.native[i] = (struct MadeiraFEXNativeImport){0};
            memcpy(module.addresses + i, (unsigned char *)mapped_image + binding->iat, 8);
            if (module.addresses[i] < 65536) goto done;
        }
    }
    runtime->modules[count] = module;
    runtime->ranges[count] = (struct guest_range){module.base, size};
    atomic_store_explicit(&runtime->count, count + 1, memory_order_release);
    fprintf(report, "signed-fex: attached existing NX Windows image=%p size=%zu modules=%llu; no image or stack allocated.\n",
        mapped_image, size, (unsigned long long)(count + 1));
    pthread_mutex_unlock(&runtime->lock);
    return 0;
done:
    free(module.addresses); free(module.native);
    if (module.library) dlclose(module.library);
    fprintf(report, "FAIL: signed FEX attach refused; identity, permissions, ABI, range or imports do not match.\n");
    pthread_mutex_unlock(&runtime->lock);
    return result;
}

struct MadeiraFEXRuntime *madeira_signed_fex_open(const char *framework, void *mapped_image, size_t size,
    MadeiraFEXImportResolve resolve, void *context, FILE *report)
{
    struct MadeiraFEXRuntime *runtime = calloc(1, sizeof(*runtime));
    if (!runtime) return NULL;
    if (pthread_mutex_init(&runtime->lock, NULL)) { free(runtime); return NULL; }
    atomic_init(&runtime->count, 0);
    if (!madeira_signed_fex_add(runtime, framework, mapped_image, size, resolve, context, report)) return runtime;
    madeira_signed_fex_close(runtime);
    return NULL;
}

int madeira_signed_fex_execute(struct MadeiraFEXRuntime *runtime, struct MadeiraFEXContext *context,
    uint64_t teb, void *stack, size_t stack_size, uint64_t stop_rip, uint64_t budget, FILE *report)
{
    if (!runtime || !context || !report || !budget || stack_size < 4096 ||
        (uintptr_t)stack > UINTPTR_MAX - stack_size ||
        context->gregs[4] < (uintptr_t)stack || context->gregs[4] > (uintptr_t)stack + stack_size - 8 ||
        !memory_access(stack, stack_size, VM_PROT_READ | VM_PROT_WRITE, VM_PROT_EXECUTE) ||
        !madeira_signed_execution_eligible(report)) return -1;
    pthread_mutex_lock(&runtime->lock);
    uint64_t count = atomic_load_explicit(&runtime->count, memory_order_acquire);
    if (runtime->validated_count != count) {
        for (uint64_t i = 0; i < count; ++i) {
            const struct module *dependency = runtime->modules + i;
            for (uint64_t j = 0; j < dependency->image->import_count; ++j) if (!dependency->native[j].target) {
                int found = 0;
                for (uint64_t k = 0; k < count; ++k)
                    if (lookup(runtime->modules[k].image, runtime->modules[k].base, dependency->addresses[j])) { found = 1; break; }
                if (!found) {
                    fprintf(report, "FAIL: a guest import has no prepared module entry; execution did not start.\n");
                    pthread_mutex_unlock(&runtime->lock); return -1;
                }
            }
        }
        runtime->validated_count = count;
    }
    ++runtime->active;
    const struct module *module = runtime->modules;
    const struct MadeiraFEXImage *image = module->image;
    pthread_mutex_unlock(&runtime->lock);
    void *previous_binding = image->thread_current();
    struct execution *execution = calloc(1, sizeof(*execution));
    void *frame = NULL;
    int result = -1;
    if (!execution || posix_memalign(&frame, 64, image->frame_size)) goto done;
    image->initialize(frame);
    memcpy((unsigned char *)frame + image->base_offset, &module->base, 8);
    if (image->load_context(frame, context, teb)) {
        fprintf(report, "FAIL: unsupported Windows CPU context.\n"); goto done;
    }
    execution->image = image; execution->runtime = runtime;
    execution->base = module->base;
    execution->stack_low = (uintptr_t)stack; execution->stack_high = (uintptr_t)stack + stack_size;
    execution->teb = teb; execution->budget = budget; execution->report = report; execution->root = frame;
    execution->hard_budget = budget > UINT64_MAX - 20000000 ? UINT64_MAX : budget + 20000000;
    bind_callback(execution, frame);
    if (setjmp(execution->failure)) {
        fprintf(report, "FAIL: Windows-context callback refused.\n"); goto done;
    }
    int status = dispatch(execution, frame, stop_rip);
    if (status == 1 || !madeira_signed_execution_eligible(report)) goto done;
    image->store_context(frame, context);
    fprintf(report, "signed-fex: context %s rip=0x%llx blocks=%llu native-calls=%llu callbacks=%llu\n",
        status == 2 ? "yield" : "stop", (unsigned long long)context->rip,
        (unsigned long long)execution->blocks, (unsigned long long)execution->imports,
        (unsigned long long)execution->callbacks);
    result = status == 2 ? 1 : 0;
done:
    image->thread_exchange(previous_binding);
    if (execution) for (unsigned i = 0; i < 64; ++i) free(execution->children[i]);
    free(frame); free(execution);
    pthread_mutex_lock(&runtime->lock);
    --runtime->active;
    pthread_mutex_unlock(&runtime->lock);
    return result;
}

struct bound_thread {
    struct thread_binding binding;
    struct MadeiraFEXRuntime *runtime;
    uint64_t teb;
    void *stack;
    size_t stack_size;
    vm_address_t emulator_stack;
    void (*fault)(void *, const struct MadeiraFEXContext *);
    void *fault_context;
    FILE *report;
};
static const size_t emulator_stack_size = 1024 * 1024;
static void thread_callback(void *opaque, void *saved)
{
    struct bound_thread *thread = opaque;
    unsigned char copy[1024];
    struct MadeiraFEXContext context = {0};
    uintptr_t address = (uintptr_t)saved;
    if (address < (uintptr_t)thread->stack || address > (uintptr_t)thread->stack + thread->stack_size - sizeof(copy)) goto failed;
    memcpy(copy, saved, sizeof(copy));
    uint64_t registers[32]; memcpy(registers, copy, sizeof(registers));
    if (registers[31] != address + sizeof(copy) || registers[31] % 16) goto failed;
    context.flags = 0x10000f; context.mxcsr = 0x1f80; context.eflags = 0x202;
    context.cs = 0x33; context.ds = context.es = context.fs = context.gs = context.ss = 0x2b;
    uint16_t fcw = 0x37f; memcpy(context.floating, &fcw, 2);
    read_ec_fp(copy, &context);
    memcpy(context.floating + 24, &context.mxcsr, 4);
    memcpy(context.floating + 160, copy + 256, 256);
    for (unsigned i = 0; i < 16; ++i) context.gregs[i] = registers[buddy[i]];
    const uint64_t sentinel = UINT64_C(0xfee1cabb);
    context.rip = registers[9]; context.gregs[4] -= 8;
    memcpy((void *)(uintptr_t)context.gregs[4], &sentinel, 8);
    if (madeira_signed_fex_execute(thread->runtime, &context, thread->teb, thread->stack,
        thread->stack_size, sentinel, UINT64_MAX, thread->report) || context.gregs[4] != registers[31]) goto failed;
    for (unsigned i = 0; i < 16; ++i) if (i != 4) registers[buddy[i]] = context.gregs[i];
    memcpy(copy, registers, sizeof(registers));
    memcpy(copy + 256, context.floating + 160, 256);
    write_ec_fp(copy, &context);
    memcpy(saved, copy, sizeof(copy));
    return;
failed:
    thread->fault(thread->fault_context, &context);
    abort();
}

int madeira_signed_fex_bind_thread(struct MadeiraFEXRuntime *runtime, uint64_t teb, void *stack, size_t stack_size,
    void (*fault)(void *, const struct MadeiraFEXContext *), void *fault_context, FILE *report)
{
    if (!runtime || !fault || !report || stack_size < 4096 ||
        !memory_access(stack, stack_size, VM_PROT_READ | VM_PROT_WRITE, VM_PROT_EXECUTE)) return -1;
    struct bound_thread *thread = calloc(1, sizeof(*thread));
    if (!thread) return -1;
    pthread_mutex_lock(&runtime->lock);
    const struct MadeiraFEXImage *image = runtime->modules[0].image;
    if (image->thread_current() || vm_allocate(mach_task_self(), &thread->emulator_stack,
        emulator_stack_size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        pthread_mutex_unlock(&runtime->lock); free(thread); return -1;
    }
    ++runtime->bound;
    thread->runtime = runtime; thread->teb = teb; thread->stack = stack; thread->stack_size = stack_size;
    thread->fault = fault; thread->fault_context = fault_context; thread->report = report;
    thread->binding = (struct thread_binding){NULL, thread_callback, thread,
        thread->emulator_stack + emulator_stack_size, runtime->ranges, &runtime->count};
    image->thread_exchange(&thread->binding);
    pthread_mutex_unlock(&runtime->lock);
    return 0;
}

int madeira_signed_fex_unbind_thread(struct MadeiraFEXRuntime *runtime)
{
    if (!runtime) return -1;
    pthread_mutex_lock(&runtime->lock);
    const struct MadeiraFEXImage *image = runtime->modules[0].image;
    struct thread_binding *binding = image->thread_current();
    if (!binding || binding->frame || binding->call != thread_callback) { pthread_mutex_unlock(&runtime->lock); return -1; }
    struct bound_thread *thread = binding->context;
    if (thread->runtime != runtime) { pthread_mutex_unlock(&runtime->lock); return -1; }
    uintptr_t current_stack = (uintptr_t)&thread;
    if (current_stack >= thread->emulator_stack && current_stack - thread->emulator_stack < emulator_stack_size) {
        pthread_mutex_unlock(&runtime->lock); return -1;
    }
    image->thread_exchange(NULL);
    --runtime->bound;
    pthread_mutex_unlock(&runtime->lock);
    vm_deallocate(mach_task_self(), thread->emulator_stack, emulator_stack_size);
    free(thread);
    return 0;
}
