#import <Foundation/Foundation.h>
#include "SignedWine.h"
#include "../../build/ntdll-unix/signed_pe_ios.h"
#include "SignedCodeProbe.h"
#include "SignedFEX.h"
#include <string.h>
#include <stdlib.h>

struct imports {
    uint32_t (*crc)(uint32_t, const void *, int);
    size_t (*compare)(const void *, const void *, size_t);
    void (*move)(void *, const void *, size_t);
    uint64_t calls;
};

static int call(void *context, const struct MadeiraFEXImport *binding, uint64_t *registers)
{
    struct imports *imports = context;
    if (strcasecmp(binding->dll, "ntdll.dll")) return -1;
    uint64_t a = registers[1], b = registers[2], c = registers[8];
    if (!strcmp(binding->name, "RtlComputeCrc32")) {
        if (c > INT32_MAX) return -1;
        registers[0] = imports->crc((uint32_t)a, (const void *)(uintptr_t)b, (int)c);
    } else if (!strcmp(binding->name, "RtlCompareMemory"))
        registers[0] = imports->compare((const void *)(uintptr_t)a, (const void *)(uintptr_t)b, c);
    else if (!strcmp(binding->name, "RtlMoveMemory"))
        imports->move((void *)(uintptr_t)a, (const void *)(uintptr_t)b, c);
    else return -1;
    ++imports->calls;
    return 0;
}

int madeira_signed_wine_run(const char *fex, const char *image, const char *ntdll, FILE *report)
{
    if (!madeira_signed_execution_eligible(report)) return 2;
    struct madeira_signed_pe *module = madeira_pe_open(ntdll, report);
    if (!module) return 1;
    struct imports imports = {
        madeira_pe_export(module, "RtlComputeCrc32", 0),
        madeira_pe_export(module, "RtlCompareMemory", 0),
        madeira_pe_export(module, "RtlMoveMemory", 0), 0
    };
    int result = 1;
    if (imports.crc && imports.compare && imports.move) {
        fprintf(report, "Wine-backed PE workload: actual ntdll DLL imports; full Wine process startup is not implemented.\n");
        result = madeira_signed_fex_run_with_imports(fex, image, report, call, &imports);
        if (madeira_pe_check(module)) result = 1;
        fprintf(report, "Wine native calls=%llu signed DLL code=%s\n", (unsigned long long)imports.calls,
                result ? "FAIL" : "unchanged");
    }
    madeira_pe_close(module);
    return result;
}

void madeira_signed_wine_if_requested(void)
{
    const char *enabled = getenv("MADEIRA_SIGNED_WINE");
    if (!enabled || strcmp(enabled, "1")) return;
    @autoreleasepool {
        NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                               inDomains:NSUserDomainMask].firstObject;
        NSURL *path = [documents URLByAppendingPathComponent:@"signed-fex.txt"];
        FILE *report = path ? fopen(path.fileSystemRepresentation, "w") : NULL;
        if (!report) return;
        NSString *name = [NSBundle.mainBundle objectForInfoDictionaryKey:@"MadeiraWineFramework"];
        if (!name.length || ![name.lastPathComponent isEqualToString:name])
            fprintf(report, "FAIL: include a prepared Wine framework and its MadeiraWineFramework Info.plist entry.\n");
        else {
            NSString *fex = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"MadeiraSignedFEX.framework"];
            NSString *native = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:name];
            madeira_signed_wine_run([[fex stringByAppendingPathComponent:@"MadeiraSignedFEX"] fileSystemRepresentation],
                [[fex stringByAppendingPathComponent:@"guest-image.bin"] fileSystemRepresentation],
                [[native stringByAppendingPathComponent:name.stringByDeletingPathExtension] fileSystemRepresentation], report);
        }
        bool written = !ferror(report);
        if (fclose(report)) written = false;
        NSLog(@"[signed-wine] report-written=%d path=%@", written, path.path);
    }
}
