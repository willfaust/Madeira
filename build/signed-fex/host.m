#import <Foundation/Foundation.h>
#include "SignedFEX.h"
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
    if (argc != 3) return 64;
    @autoreleasepool {
        fprintf(stdout, "Host execution check; this is not iPhone proof.\n");
        return madeira_signed_fex_run(argv[1], argv[2], stdout);
    }
}
