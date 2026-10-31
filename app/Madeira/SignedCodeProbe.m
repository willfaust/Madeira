#import <Foundation/Foundation.h>
#include "JITAllocator.h"
#include "SignedCodeProbe.h"
#include <TargetConditionals.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <string.h>
#include <sys/sysctl.h>

static bool eligible(FILE *report)
{
    uint32_t flags = 0;
    struct kinfo_proc info = {0};
    size_t size = sizeof(info);
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    bool known = jit_cs_status(&flags);
    bool traced_known = sysctl(mib, 4, &info, &size, NULL, 0) == 0 && size == sizeof(info);
    bool traced = (info.kp_proc.p_flag & P_TRACED) != 0;
    fprintf(report, "cs-known=%d cs-flags=0x%x traced-known=%d traced=%d\n",
            known, flags, traced_known, traced);
    if (!known || !traced_known || traced || (flags & 0x10000000u)) {
        fprintf(report, "INCONCLUSIVE: unknown signing state or debugger use; restart without JIT/debugging.\n");
        return false;
    }
    return true;
}

static bool permissions(const void *pointer, size_t length, vm_prot_t required, vm_prot_t forbidden)
{
    vm_address_t address = (uintptr_t)pointer;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(mach_task_self(), &address, &size,
            VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    uintptr_t start = (uintptr_t)pointer;
    return result == KERN_SUCCESS && address <= start && start - address <= size &&
           length <= size - (start - address) && (info.protection & required) == required &&
           !(info.protection & forbidden);
}

static uint64_t triple(uint64_t value) { return value * 3; }
static uint64_t add_five(uint64_t value) { return value + 5; }

int madeira_signed_code_probe_run(const char *path, FILE *report)
{
#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
    const char *platform = "ios-device";
#else
    const char *platform = "host-only";
#endif
    fprintf(report, "Signed-code probe v1 platform=%s os=%s\n", platform,
            NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
    if (!eligible(report)) return 2;
    if (!path || !*path) {
        fprintf(report, "FAIL: missing fixture path.\n");
        return 1;
    }
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        fprintf(report, "FAIL: dlopen: %s\n", dlerror());
        return 1;
    }
    int result = 1;
    uint64_t (*entry)(uint64_t) = dlsym(handle, "madeira_signed_probe_entry");
    const void *end = dlsym(handle, "madeira_signed_probe_entry_end");
    struct MadeiraSignedProbeSlots *slots = dlsym(handle, "madeira_signed_probe_slots");
    uintptr_t start = (uintptr_t)entry, stop = (uintptr_t)end;
    unsigned char saved[1024];
    if (!entry || !end || !slots || stop <= start || stop - start > sizeof(saved)) {
        fprintf(report, "FAIL: missing or invalid fixture symbols.\n");
        goto done;
    }
    size_t length = stop - start;
    if (!permissions((const void *)start, length, VM_PROT_READ | VM_PROT_EXECUTE, VM_PROT_WRITE) ||
        !permissions(slots, sizeof(*slots), VM_PROT_READ | VM_PROT_WRITE, VM_PROT_EXECUTE)) {
        fprintf(report, "FAIL: expected read/execute code and read/write, non-executable data.\n");
        goto done;
    }
    memcpy(saved, (const void *)start, length);
    struct MadeiraSignedProbeSlots previous = *slots;
    slots->bias = 7;
    slots->callback = triple;
    uint64_t first = entry(5);
    slots->bias = 11;
    slots->callback = add_five;
    uint64_t second = entry(5);
    *slots = previous;
    fprintf(report, "first=%llu expected=36 second=%llu expected=21 code-bytes=%zu\n",
            (unsigned long long)first, (unsigned long long)second, length);
    if (first != 36 || second != 21 || memcmp(saved, (const void *)start, length)) {
        fprintf(report, "FAIL: callback/data update or immutable code check failed.\n");
        goto done;
    }
    if (!eligible(report)) {
        result = 2;
        goto done;
    }
    fprintf(report, "PASS: signed library loader contract (%s); no FEX/Wine/game claim.\n", platform);
    result = 0;
done:
    dlclose(handle);
    return result;
}

void madeira_signed_code_probe_if_requested(void)
{
    const char *enabled = getenv("MADEIRA_SIGNED_CODE_PROBE");
    if (!enabled || strcmp(enabled, "1")) return;
    @autoreleasepool {
        NSString *path = [NSBundle.mainBundle.privateFrameworksPath
            stringByAppendingPathComponent:@"MadeiraSignedProbe.framework/MadeiraSignedProbe"];
        NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                               inDomains:NSUserDomainMask].firstObject;
        NSURL *output = [documents URLByAppendingPathComponent:@"signed-code-probe.txt"];
        FILE *report = output ? fopen(output.fileSystemRepresentation, "w") : NULL;
        if (!report) {
            NSLog(@"[signed-code-probe] FAIL: cannot open report.");
            return;
        }
        int result = madeira_signed_code_probe_run(path.fileSystemRepresentation, report);
        bool written = !ferror(report);
        if (fclose(report)) written = false;
        NSLog(@"[signed-code-probe] result=%d report-written=%d path=%@", result, written, output.path);
    }
}
