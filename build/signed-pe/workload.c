#include <stddef.h>
#include <stdint.h>
struct unicode_string { uint16_t length, maximum; uint16_t *buffer; };
typedef int (*table_compare)(void *, const void *, const void *);
typedef void *(*table_allocate)(void *, int32_t);
typedef void (*table_release)(void *, void *);

#ifdef _WIN32
__declspec(dllimport) uint32_t RtlComputeCrc32(uint32_t, const void *, int);
__declspec(dllimport) size_t RtlCompareMemory(const void *, const void *, size_t);
__declspec(dllimport) void RtlMoveMemory(void *, const void *, size_t);
__declspec(dllimport) int32_t RtlUTF8ToUnicodeN(uint16_t *, uint32_t, uint32_t *, const char *, uint32_t);
__declspec(dllimport) int32_t RtlUnicodeToUTF8N(char *, uint32_t, uint32_t *, const uint16_t *, uint32_t);
__declspec(dllimport) void RtlInitUnicodeString(struct unicode_string *, const uint16_t *);
__declspec(dllimport) double sqrt(double);
__declspec(dllimport) void RtlInitializeGenericTable(void *, table_compare, table_allocate, table_release, void *);
__declspec(dllimport) void *RtlInsertElementGenericTable(void *, const void *, uint32_t, unsigned char *);
__declspec(dllimport) unsigned char RtlDeleteElementGenericTable(void *, const void *);
__declspec(dllimport) void *RtlEnumerateGenericTableWithoutSplaying(void *, void **);
#if defined(MADEIRA_EXTERNAL_COMPARE)
__declspec(dllimport) int guest_compare(void *, const void *, const void *);
#endif
#else
#include <string.h>
#include <math.h>
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
static const char utf8[] = "Madeira \xcf\x80 \xf0\x9f\x8e\xae";
static const uint16_t utf16[] = {'M','a','d','e','i','r','a',' ',0x3c0,' ',0xd83c,0xdfae,0};
static int32_t RtlUTF8ToUnicodeN(uint16_t *out, uint32_t size, uint32_t *written, const char *in, uint32_t length)
{
    if (length != sizeof(utf8)-1 || memcmp(in, utf8, length) || size < sizeof(utf16)-2) return -1;
    memcpy(out, utf16, sizeof(utf16)-2); *written = sizeof(utf16)-2; return 0;
}
static int32_t RtlUnicodeToUTF8N(char *out, uint32_t size, uint32_t *written, const uint16_t *in, uint32_t length)
{
    if (length != sizeof(utf16)-2 || memcmp(in, utf16, length) || size < sizeof(utf8)-1) return -1;
    memcpy(out, utf8, sizeof(utf8)-1); *written = sizeof(utf8)-1; return 0;
}
static void RtlInitUnicodeString(struct unicode_string *out, const uint16_t *in)
{
    unsigned length = 0; while (in[length]) ++length;
    out->length = length * 2; out->maximum = out->length + 2; out->buffer = (uint16_t *)in;
}
struct portable_table { table_compare compare; table_allocate allocate; table_release release; void *items[32]; unsigned count; };
static void RtlInitializeGenericTable(void *p, table_compare compare, table_allocate allocate, table_release release, void *context)
{
    (void)context;
    struct portable_table *table = p;
    table->compare = compare; table->allocate = allocate; table->release = release; table->count = 0;
}
static void *RtlInsertElementGenericTable(void *p, const void *value, uint32_t size, unsigned char *inserted)
{
    struct portable_table *table = p;
    unsigned i = 0;
    while (i < table->count && table->compare(p, table->items[i], value) == 0) ++i;
    if (i < table->count && table->compare(p, table->items[i], value) == 2) { *inserted = 0; return table->items[i]; }
    if (table->count == 32) return NULL;
    void *item = table->allocate(p, size);
    if (!item) return NULL;
    memcpy(item, value, size);
    memmove(table->items+i+1, table->items+i, (table->count-i)*sizeof(void *));
    table->items[i] = item; ++table->count; *inserted = 1; return item;
}
static unsigned char RtlDeleteElementGenericTable(void *p, const void *value)
{
    struct portable_table *table = p;
    for (unsigned i = 0; i < table->count; ++i) if (table->compare(p, table->items[i], value) == 2) {
        table->release(p, table->items[i]);
        memmove(table->items+i, table->items+i+1, (--table->count-i)*sizeof(void *)); return 1;
    }
    return 0;
}
static void *RtlEnumerateGenericTableWithoutSplaying(void *p, void **restart)
{
    struct portable_table *table = p;
    uintptr_t i = (uintptr_t)*restart;
    if (i == table->count) return NULL;
    *restart = (void *)(i+1); return table->items[i];
}
#endif

static _Alignas(16) unsigned char arena[8192];
static unsigned arena_used, released;
static int thread_context_valid(void)
{
#if defined(_WIN32) && defined(__x86_64__)
    uintptr_t self, peb;
    __asm__ volatile("movq %%gs:0x30, %0" : "=r"(self));
    __asm__ volatile("movq %%gs:0x60, %0" : "=r"(peb));
    return self && peb && *(const uintptr_t *)(self + 0x60) == peb;
#else
    return 1;
#endif
}
static int compare_key(void *table, const void *a, const void *b)
{
    (void)table;
    if (!thread_context_valid()) return 2;
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? 0 : x > y ? 1 : 2;
}
static void *allocate_key(void *table, int32_t size)
{
    (void)table;
    static const unsigned char zero[256];
    if (size <= 0 || size > 256 || arena_used + (unsigned)size > sizeof(arena)) return NULL;
    void *result = arena + arena_used;
    arena_used += ((unsigned)size + 15) & ~15u;
    RtlMoveMemory(result, zero, size);
    return result;
}
static void release_key(void *table, void *value) { (void)table; (void)value; ++released; }

__attribute__((noinline)) uint64_t guest_workload(uint64_t seed)
{
    if (!thread_context_valid()) return UINT64_MAX - 12;
    unsigned char source[8192], copy[8192];
    uint32_t state = (uint32_t)seed;
    uint64_t result = seed;
    for (unsigned round = 0; round < 128; ++round) {
        uint64_t table[80];
        arena_used = released = 0;
        table_compare comparator = compare_key;
#if defined(_WIN32) && defined(MADEIRA_EXTERNAL_COMPARE)
        comparator = guest_compare;
#endif
#if defined(_WIN32) && defined(MADEIRA_REJECT_CALLBACK)
#ifndef MADEIRA_REJECT_ADDRESS
#define MADEIRA_REJECT_ADDRESS UINT64_C(0x130010000)
#endif
        comparator = (table_compare)(uintptr_t)MADEIRA_REJECT_ADDRESS;
#endif
        RtlInitializeGenericTable(table, comparator, allocate_key, release_key, &arena_used);
        for (unsigned i = 0; i < 32; ++i) {
            uint64_t key = (i * 13 + round) % 32;
            unsigned char inserted = 0;
            uint64_t *item = RtlInsertElementGenericTable(table, &key, sizeof(key), &inserted);
            if (!item || *item != key || !inserted) return UINT64_MAX - 7;
        }
        void *restart = NULL;
        for (unsigned i = 0; i < 32; ++i) {
            uint64_t *item = RtlEnumerateGenericTableWithoutSplaying(table, &restart);
            if (!item || *item != i) return UINT64_MAX - 8;
        }
        if (RtlEnumerateGenericTableWithoutSplaying(table, &restart)) return UINT64_MAX - 9;
        for (uint64_t key = 0; key < 32; ++key)
            if (!RtlDeleteElementGenericTable(table, &key)) return UINT64_MAX - 10;
        if (released != 32) return UINT64_MAX - 11;
        double value = (double)(round + 1);
        if (sqrt(value * value) != value) return UINT64_MAX - 6;
        static const char text[] = "Madeira \xcf\x80 \xf0\x9f\x8e\xae";
        uint16_t wide[32] = {0}; char back[64] = {0};
        uint32_t wide_bytes = 0, back_bytes = 0;
        if (RtlUTF8ToUnicodeN(wide, sizeof(wide)-2, &wide_bytes, text, sizeof(text)-1) || wide_bytes != 24)
            return UINT64_MAX - 2;
        struct unicode_string string;
        RtlInitUnicodeString(&string, wide);
        if (string.length != wide_bytes || string.maximum != wide_bytes + 2 || string.buffer != wide)
            return UINT64_MAX - 3;
        if (RtlUnicodeToUTF8N(back, sizeof(back), &back_bytes, string.buffer, string.length) || back_bytes != sizeof(text)-1)
            return UINT64_MAX - 4;
        if (RtlCompareMemory(text, back, sizeof(text)-1) != sizeof(text)-1) return UINT64_MAX - 5;
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
