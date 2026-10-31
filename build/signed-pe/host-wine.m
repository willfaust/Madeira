#import <Foundation/Foundation.h>
#include "SignedWine.h"
#include "JITAllocator.h"
#include <unistd.h>

extern int csops(pid_t, unsigned int, void *, size_t);
bool jit_cs_status(uint32_t *flags)
{
    uint32_t value = 0;
    if (csops(getpid(), 0, &value, sizeof(value))) return false;
    *flags = value;
    return true;
}
int main(int argc, char **argv)
{
    if (argc != 4) return 64;
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        puts("Host Wine-backed program check; no iPhone access or device proof.");
        return madeira_signed_wine_run(argv[1], argv[2], argv[3], stdout);
    }
}
