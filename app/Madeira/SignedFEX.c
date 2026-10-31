#include "SignedFEX.h"
#include "SignedCodeProbe.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <setjmp.h>
#include <TargetConditionals.h>

static bool executable(const void *pointer, size_t length)
{
    vm_address_t address = (uintptr_t)pointer;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t status = vm_region_64(mach_task_self(), &address, &size,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (object) mach_port_deallocate(mach_task_self(), object);
    uintptr_t start = (uintptr_t)pointer;
    return status == KERN_SUCCESS && address <= start && start - address <= size &&
        length <= size - (start - address) &&
        (info.protection & (VM_PROT_READ | VM_PROT_EXECUTE | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_EXECUTE);
}

static const void *lookup(const struct MadeiraFEXImage *image, uint64_t rip)
{
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
struct execution {
    const struct MadeiraFEXImage *image;
    struct MadeiraFEXNativeImport *native;
    MadeiraFEXImportCall call;
    void *context;
    FILE *report;
    uint64_t guest, allocation, teb, blocks, imports, callbacks;
    size_t import_count;
    unsigned depth;
    void *children[64];
    jmp_buf failure;
};
static void native_callback(void *context, void *saved);
static void bind_callback(struct execution *run, void *frame)
{
    struct { void (*call)(void *, void *); void *context; } binding = {native_callback, run};
    _Static_assert(sizeof(binding) == 16, "ARM64 callback binding ABI");
    memcpy((unsigned char *)frame + run->image->callback_offset, &binding, sizeof(binding));
}
static int dispatch(struct execution *run, void *frame, uint64_t sentinel)
{
    const struct MadeiraFEXImage *image = run->image;
    uint64_t *gregs = (void *)((unsigned char *)frame + image->gregs_offset);
    uint64_t *rip = (void *)((unsigned char *)frame + image->rip_offset);
    while (*rip != sentinel && run->blocks < 20000000) {
        const void *entry = lookup(image, *rip);
        if (!entry && *rip >= import_base && (*rip - import_base) % 16 == 0 &&
            (*rip - import_base) / 16 < run->import_count) {
            uint64_t stack = gregs[4];
            size_t index = (*rip - import_base) / 16;
            if (stack < run->guest || stack - run->guest > run->allocation - 40 || stack % 8) return 1;
            if (run->native) {
                if ((stack + 8) % 16) return 1;
                image->enter_ec(frame, run->native[index].target, run->native[index].thunk);
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
            image->enter(frame, entry);
        }
        ++run->blocks;
    }
    return *rip != sentinel;
}
static void native_callback(void *context, void *saved)
{
    struct execution *run = context;
    const struct MadeiraFEXImage *image = run->image;
    uintptr_t address = (uintptr_t)saved;
    if (run->depth == 64 || address < run->guest + image->image_size ||
        address - run->guest > run->allocation - 1024) longjmp(run->failure, 1);
    unsigned char copy[1024];
    memcpy(copy, saved, sizeof(copy));
    uint64_t registers[32];
    memcpy(registers, copy, sizeof(registers));
    if (registers[31] != address + 1024 || registers[31] % 16) longjmp(run->failure, 1);
    unsigned level = run->depth++;
    if (posix_memalign(run->children + level, 64, image->frame_size)) longjmp(run->failure, 1);
    void *frame = run->children[level];
    image->initialize(frame);
    bind_callback(run, frame);
    memcpy((unsigned char *)frame + image->gs_offset, &run->teb, 8);
    uint64_t *gregs = (void *)((unsigned char *)frame + image->gregs_offset);
    static const unsigned buddy[16] = {8,0,1,27,31,29,25,26,2,3,4,5,19,20,21,22};
    for (unsigned i = 0; i < 16; ++i) gregs[i] = registers[buddy[i]];
    const uint64_t sentinel = UINT64_C(0xfee1cabb);
    gregs[4] -= 8;
    memcpy((void *)(uintptr_t)gregs[4], &sentinel, 8);
    memcpy((unsigned char *)frame + image->xmm_offset, copy + 256, 256);
    memcpy((unsigned char *)frame + image->rip_offset, registers + 9, 8);
    if (dispatch(run, frame, sentinel) || gregs[4] != registers[31]) longjmp(run->failure, 1);
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
    if (!image || (image->version < 1 || image->version > 3) || image->base != UINT64_C(0x130000000) ||
        image->image_size < 64 || image->image_size > 16 * 1024 * 1024 ||
        image->frame_size < 256 || image->frame_size > 1024 * 1024 ||
        image->gregs_offset > image->frame_size - 128 || image->rip_offset > image->frame_size - 8 ||
        !image->entry_count || image->entry_count > 100000 || !image->section_count || image->section_count > 96 ||
        !image->initialize || !image->enter || !image->reference ||
        (uintptr_t)image->code_end <= (uintptr_t)image->code ||
        (uintptr_t)image->code_end - (uintptr_t)image->code > 32 * 1024 * 1024) {
        fprintf(report, "FAIL: invalid signed FEX image descriptor.\n"); goto done;
    }
    size_t code_size = (uintptr_t)image->code_end - (uintptr_t)image->code;
    size_t import_count = image->version >= 2 ? image->import_count : 0;
    if (import_count > 1024 || (import_count && ((!call && !resolve) || !image->imports)) ||
        (image->version >= 3 && (image->gs_offset > image->frame_size - 8 ||
                                image->callback_offset > image->frame_size - 16)) ||
        (resolve && (image->version < 3 || !image->enter_ec || !image->return_ec ||
                     image->xmm_offset > image->frame_size - 256 ||
                     !image->call_ec || !image->check_ec || !image->check_ec_cfg))) {
        fprintf(report, "FAIL: this PE needs an explicit native import bridge.\n"); goto done;
    }
    if (!executable(image->code, code_size)) { fprintf(report, "FAIL: code is not immutable RX.\n"); goto done; }
    for (uint64_t i = 0; i < image->entry_count; ++i)
        if (image->entries[i].offset >= code_size || image->entries[i].offset % 4 ||
            (i && image->entries[i - 1].guest >= image->entries[i].guest)) {
            fprintf(report, "FAIL: invalid FEX entry table.\n"); goto done;
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
    execution->guest = guest; execution->allocation = allocation; execution->teb = teb;
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
    if (guest) vm_deallocate(mach_task_self(), guest, allocation);
    free(frame);
    free(snapshot);
    free(native);
    if (execution) for (unsigned i = 0; i < 64; ++i) free(execution->children[i]);
    free(execution);
    dlclose(library);
    return result;
}
