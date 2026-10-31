#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
__declspec(dllimport) uint32_t RtlComputeCrc32(uint32_t, const void *, int);
__declspec(dllimport) size_t RtlCompareMemory(const void *, const void *, size_t);
__declspec(dllimport) void RtlMoveMemory(void *, const void *, size_t);
#else
#include <string.h>
static uint32_t RtlComputeCrc32(uint32_t seed, const void *data, int count)
{
    const unsigned char *p = data;
    uint32_t crc = ~seed;
    while (count--) {
        crc ^= *p++;
        for (unsigned i = 0; i < 8; ++i) crc = (crc >> 1) ^ (0xedb88320u & -(crc & 1));
    }
    return ~crc;
}
static size_t RtlCompareMemory(const void *a, const void *b, size_t count)
{
    const unsigned char *x = a, *y = b;
    size_t i = 0;
    while (i < count && x[i] == y[i]) ++i;
    return i;
}
#define RtlMoveMemory memmove
#endif

__attribute__((noinline)) uint64_t guest_workload(uint64_t seed)
{
    unsigned char source[8192], copy[8192];
    uint32_t state = (uint32_t)seed;
    uint64_t result = seed;
    for (unsigned round = 0; round < 128; ++round) {
        for (unsigned i = 0; i < sizeof(source); ++i) {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5;
            source[i] = state;
        }
        RtlMoveMemory(copy, source, sizeof(source));
        if (RtlCompareMemory(source, copy, sizeof(source)) != sizeof(source)) return UINT64_MAX;
        uint32_t crc = RtlComputeCrc32(round, copy, sizeof(copy));
        copy[round * 61 % sizeof(copy)] ^= 0x5a;
        if (RtlCompareMemory(source, copy, sizeof(source)) != round * 61 % sizeof(copy)) return UINT64_MAX - 1;
        result = (result << 9 | result >> 55) ^ crc;
    }
    return result;
}
