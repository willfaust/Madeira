#include "SignedFEX.h"
#include "SignedCodeProbe.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
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

int madeira_signed_fex_run(const char *framework, const char *guest_image, FILE *report)
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
    if (!image || image->version != 1 || image->base != UINT64_C(0x130000000) ||
        !image->image_size || image->image_size > 16 * 1024 * 1024 ||
        image->frame_size < 256 || image->frame_size > 1024 * 1024 ||
        image->gregs_offset > image->frame_size - 128 || image->rip_offset > image->frame_size - 8 ||
        !image->entry_count || image->entry_count > 100000 || !image->section_count || image->section_count > 96 ||
        !image->initialize || !image->enter || !image->reference ||
        (uintptr_t)image->code_end <= (uintptr_t)image->code ||
        (uintptr_t)image->code_end - (uintptr_t)image->code > 32 * 1024 * 1024) {
        fprintf(report, "FAIL: invalid signed FEX image descriptor.\n"); goto done;
    }
    size_t code_size = (uintptr_t)image->code_end - (uintptr_t)image->code;
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
    fprintf(report, "entries=%llu translated-bytes=%zu runs=%zu guest-text=read-only guest-stack=non-executable\n",
        (unsigned long long)image->entry_count, code_size, sizeof(seeds) / sizeof(seeds[0]));
    for (unsigned test = 0; test < sizeof(seeds) / sizeof(seeds[0]); ++test) {
        image->initialize(frame);
        uint64_t *gregs = (uint64_t *)((unsigned char *)frame + image->gregs_offset);
        uint64_t *rip = (uint64_t *)((unsigned char *)frame + image->rip_offset);
        gregs[1] = seeds[test];
        gregs[4] = guest + allocation - 72;
        *(uint64_t *)(uintptr_t)gregs[4] = sentinel;
        *rip = image->entry;
        struct timespec start, end;
        clock_gettime(CLOCK_MONOTONIC, &start);
        uint64_t blocks = 0;
        while (*rip != sentinel && blocks < 20000000) {
            const void *entry = lookup(image, *rip);
            if (!entry) { fprintf(report, "FAIL: missing pretranslated RIP=0x%llx; JIT fallback is disabled.\n", (unsigned long long)*rip); goto done; }
            image->enter(frame, entry);
            ++blocks;
        }
        clock_gettime(CLOCK_MONOTONIC, &end);
        if (*rip != sentinel) { fprintf(report, "FAIL: dispatch budget exceeded.\n"); goto done; }
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
    result = 0;
done:
    if (guest) vm_deallocate(mach_task_self(), guest, allocation);
    free(frame);
    free(snapshot);
    dlclose(library);
    return result;
}
