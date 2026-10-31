#import <Foundation/Foundation.h>
#include "SignedWine.h"
#include "../../build/ntdll-unix/signed_pe_ios.h"
#include "SignedCodeProbe.h"
#include "SignedFEX.h"
#include <string.h>
#include <stdlib.h>
#include <pthread.h>

#include "../../build/signed-pe/thread_fixture.h"

static int resolve(void *context, const struct MadeiraFEXImport *binding,
                   const struct MadeiraFEXImage *image, struct MadeiraFEXNativeImport *native)
{
    if (strcasecmp(binding->dll, "ntdll.dll")) return -1;
    return madeira_pe_ec_import(context, binding->name, image->return_ec, image->call_ec, image->check_ec, image->check_ec_cfg,
                                &native->target, &native->thunk);
}

int madeira_signed_wine_run(const char *fex, const char *image, const char *ntdll, FILE *report)
{
    if (!madeira_signed_execution_eligible(report)) return 2;
    struct madeira_signed_pe *module = madeira_pe_open(ntdll, report);
    if (!module) return 1;
    uintptr_t teb = 0;
    if (standalone_thread(module, report, &teb)) {
        fprintf(report, "FAIL: prepare offline thread-state rewrites before running this ABI workload.\n");
        madeira_pe_close(module); return 1;
    }
    fprintf(report, "Wine ARM64EC entry-thunk dispatch: no per-function C signature bridge.\n");
    int result = madeira_signed_fex_run_native(fex, image, report, resolve, module, teb);
    int changed = madeira_pe_check(module);
    if (changed) result = 1;
    fprintf(report, "Wine signed DLL code=%s; full Wine process startup is not implemented.\n",
            changed ? "FAIL" : "unchanged");
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
