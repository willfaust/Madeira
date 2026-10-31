#include <stddef.h>
#include <stdint.h>
__declspec(dllimport) size_t RtlCompareMemory(const void *, const void *, size_t);
__declspec(dllexport) int guest_compare(void *table, const void *a, const void *b)
{
    (void)table;
    if (RtlCompareMemory(a, b, sizeof(uint64_t)) == sizeof(uint64_t)) return 2;
    return *(const uint64_t *)a < *(const uint64_t *)b ? 0 : 1;
}
