#include <stdint.h>
#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif
#define NOINLINE __attribute__((noinline))

EXPORT NOINLINE uint64_t mix_a(uint64_t x) { return (x ^ (x >> 17)) * UINT64_C(0x9e3779b185ebca87); }
EXPORT NOINLINE uint64_t mix_b(uint64_t x) { return (x + UINT64_C(0x517cc1b727220a95)) ^ (x << 13); }
EXPORT NOINLINE uint64_t mix_c(uint64_t x) { return (x >> 7) | (x << 57); }

EXPORT NOINLINE void sort_words(uint32_t *a, int low, int high)
{
    int i = low, j = high;
    uint32_t pivot = a[low + (high - low) / 2];
    while (i <= j) {
        while (a[i] < pivot) ++i;
        while (a[j] > pivot) --j;
        if (i <= j) {
            uint32_t v = a[i]; a[i] = a[j]; a[j] = v;
            ++i; --j;
        }
    }
    if (low < j) sort_words(a, low, j);
    if (i < high) sort_words(a, i, high);
}

EXPORT NOINLINE uint32_t crc_bytes(const unsigned char *data, unsigned size)
{
    uint32_t crc = ~0u;
    for (unsigned i = 0; i < size; ++i) {
        crc ^= data[i];
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1)));
    }
    return ~crc;
}

EXPORT NOINLINE uint64_t matrix_sum(uint64_t seed)
{
    float a[16 * 16], b[16 * 16], c[16 * 16];
    for (unsigned i = 0; i < 256; ++i) {
        a[i] = (float)((i + seed) & 15) * 0.125f;
        b[i] = (float)((i * 7 + seed) & 31) * 0.0625f;
    }
    for (unsigned y = 0; y < 16; ++y)
        for (unsigned x = 0; x < 16; ++x) {
            float sum = 0;
            for (unsigned k = 0; k < 16; ++k) sum += a[y * 16 + k] * b[k * 16 + x];
            c[y * 16 + x] = sum;
        }
    uint64_t sum = 0;
    for (unsigned i = 0; i < 256; ++i) sum += (uint64_t)(c[i] * 1024.0f);
    return sum;
}

EXPORT NOINLINE uint64_t guest_workload(uint64_t seed)
{
    uint32_t words[1024];
    uint64_t x = seed | 1;
    for (unsigned i = 0; i < 1024; ++i) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        words[i] = (uint32_t)x;
    }
    uint64_t before = crc_bytes((const unsigned char *)words, sizeof(words));
    sort_words(words, 0, 1023);
    for (unsigned i = 1; i < 1024; ++i) if (words[i] < words[i - 1]) return 0;
    uint64_t hash = before ^ crc_bytes((const unsigned char *)words, sizeof(words));
    uint64_t (*volatile operations[3])(uint64_t) = {mix_a, mix_b, mix_c};
    for (unsigned i = 0; i < 4096; ++i) hash = operations[i % 3](hash + words[i & 1023]);
    return hash ^ matrix_sum(seed);
}
