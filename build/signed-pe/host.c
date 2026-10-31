#include "signed_pe_ios.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>

extern uint64_t guest_workload(uint64_t);
static uint16_t get16(const void *p) { uint16_t value; memcpy(&value, p, 2); return value; }
static uint32_t get32(const void *p) { uint32_t value; memcpy(&value, p, 4); return value; }
static uint64_t get64(const void *p) { uint64_t value; memcpy(&value, p, 8); return value; }

static unsigned char *map_source(const char *path, size_t *size, uint32_t *first_fixup)
{
    FILE *file = fopen(path, "rb");
    assert(file && !fseek(file, 0, SEEK_END));
    long length = ftell(file);
    assert(length >= 264 && length <= 128 * 1024 * 1024 && !fseek(file, 0, SEEK_SET));
    unsigned char *raw = malloc(length);
    assert(raw && fread(raw, 1, length, file) == (size_t)length);
    fclose(file);
    size_t nt = get32(raw + 60), optional = nt + 24;
    assert(nt <= (size_t)length - 264 && get32(raw + nt) == 0x4550);
    *size = get32(raw + optional + 56);
    assert(*size >= 264 && *size <= 128 * 1024 * 1024);
    unsigned char *image = calloc(1, *size);
    size_t headers = get32(raw + optional + 60);
    assert(image && headers <= *size && headers <= (size_t)length);
    memcpy(image, raw, headers);
    size_t section = optional + get16(raw + nt + 20);
    for (unsigned i = 0; i < get16(raw + nt + 6); ++i, section += 40) {
        assert(section + 40 <= headers);
        size_t rva = get32(raw + section + 12), count = get32(raw + section + 16), position = get32(raw + section + 20);
        assert(rva <= *size && count <= *size - rva && position <= (size_t)length && count <= (size_t)length - position);
        memcpy(image + rva, raw + position, count);
    }
    uint64_t base = get64(raw + optional + 24);
    size_t offset = get32(image + optional + 152), end = offset + get32(image + optional + 156);
    assert(end <= *size);
    *first_fixup = 0;
    while (offset < end) {
        assert(offset + 8 <= end);
        uint32_t page = get32(image + offset), block = get32(image + offset + 4);
        assert(block >= 8 && !(block % 2) && block <= end - offset);
        for (size_t p = offset + 8; p < offset + block; p += 2) {
            unsigned value = get16(image + p);
            if (!value) continue;
            size_t rva = page + (value & 4095);
            assert(value >> 12 == 10 && rva <= *size - 8);
            uint64_t pointer = get64(image + rva) - base + (uintptr_t)image;
            memcpy(image + rva, &pointer, 8);
            if (!*first_fixup) *first_fixup = (uint32_t)rva;
        }
        offset += block;
    }
    free(raw);
    return image;
}

static void registry_check(const char *source, const char *directory, struct madeira_signed_pe *ntdll)
{
    size_t size;
    uint32_t fixup;
    unsigned char *original = map_source(source, &size, &fixup);
    assert(fixup && !setenv("MADEIRA_SIGNED_PE_DIR", directory, 1));
    assert(!madeira_pe_wine_configure());
    assert(!madeira_pe_wine_attach(original, size));
    unsigned char *native = madeira_pe_image(ntdll);
    assert(madeira_pe_wine_translate(original, 0) == native);
    assert(madeira_pe_wine_translate(native, 1) == original);
    size_t optional = get32(original + 60) + 24, sections = optional + get16(original + optional - 4);
    size_t code = get32(original + sections + 12);
    assert(madeira_pe_wine_code_overlap(original + code, 4));
    assert(!madeira_pe_wine_code_overlap(original + fixup, 8));
    uint64_t saved = get64(original + fixup), pointer = (uintptr_t)original + code;
    memcpy(original + fixup, &pointer, 8);
    assert(madeira_pe_wine_sync(original + fixup, 8) == 1);
    assert(get64(native + fixup) == (uintptr_t)native + code && !madeira_pe_check(ntdll));
    memcpy(original + fixup, &saved, 8);
    assert(madeira_pe_wine_sync(original + fixup, 8) == 1);
    unsigned char *duplicate = map_source(source, &size, &fixup);
    assert(madeira_pe_wine_attach(duplicate, size) == -1);
    free(duplicate);
    madeira_pe_wine_detach(original);
    assert(madeira_pe_wine_translate(original, 0) == original && !madeira_pe_check(ntdll));
    free(original);
    unsetenv("MADEIRA_SIGNED_PE_DIR");
    puts("PASS: Wine map, relocated data update, immutable text, duplicate-instance refusal, and unmap lifecycle.");
}

static void *resolve(void *context, const char *dll, const char *name, uint16_t ordinal)
{
    if (strcasecmp(dll, "ntdll.dll")) return NULL;
    return madeira_pe_export(context, name, ordinal);
}

static uint32_t crc(uint32_t seed, const unsigned char *bytes, size_t size)
{
    uint32_t value = ~seed;
    for (size_t i = 0; i < size; ++i) {
        value ^= bytes[i];
        for (unsigned j = 0; j < 8; ++j) value = (value >> 1) ^ (0xedb88320u & -(value & 1));
    }
    return ~value;
}

int main(int argc, char **argv)
{
    assert(argc >= 2);
    struct madeira_signed_pe *ntdll = madeira_pe_open(argv[1], stdout);
    assert(ntdll);
    uint32_t (*wine_crc)(uint32_t, const void *, int) = madeira_pe_export(ntdll, "RtlComputeCrc32", 0);
    size_t (*wine_compare)(const void *, const void *, size_t) = madeira_pe_export(ntdll, "RtlCompareMemory", 0);
    void (*wine_move)(void *, const void *, size_t) = madeira_pe_export(ntdll, "RtlMoveMemory", 0);
    assert(wine_crc && wine_compare && wine_move);
    unsigned char *original = malloc(1024 * 1024), *copy = malloc(1024 * 1024);
    assert(original && copy);
    for (unsigned test = 0; test < 8; ++test) {
        uint32_t value = 0x12345678u + test;
        for (size_t i = 0; i < 1024 * 1024; ++i) {
            value ^= value << 13; value ^= value >> 17; value ^= value << 5;
            original[i] = value;
        }
        wine_move(copy, original, 1024 * 1024);
        assert(wine_compare(original, copy, 1024 * 1024) == 1024 * 1024);
        uint32_t result = wine_crc(test, copy, 1024 * 1024);
        assert(result == crc(test, original, 1024 * 1024));
        assert(!madeira_pe_check(ntdll));
        printf("Wine ntdll run=%u bytes=1048576 crc=0x%08x code=unchanged\n", test, result);
    }
    for (int i = 2; i < argc; ++i) {
        if (!strcmp(argv[i], "--wine-map")) {
            assert(i + 2 < argc);
            registry_check(argv[i + 1], argv[i + 2], ntdll);
            i += 2;
            continue;
        }
        if (!strcmp(argv[i], "--program")) {
            assert(++i < argc);
            struct madeira_signed_pe *program = madeira_pe_open(argv[i], stdout);
            assert(program && !madeira_pe_bind(program, resolve, ntdll));
            uint64_t (*run)(uint64_t) = madeira_pe_export(program, "guest_workload", 0);
            assert(run);
            for (unsigned seed = 1; seed < 9; ++seed) {
                uint64_t actual = run(seed), expected = guest_workload(seed);
                assert(actual == expected && !madeira_pe_check(program) && !madeira_pe_check(ntdll));
                printf("Native Windows PE run=%u result=0x%llx imports=Wine-ntdll code=unchanged\n",
                       seed, (unsigned long long)actual);
            }
            madeira_pe_close(program);
            continue;
        }
        struct madeira_signed_pe *module = madeira_pe_open(argv[i], stdout);
        assert(module && !madeira_pe_check(module));
        madeira_pe_close(module);
    }
    free(copy); free(original); madeira_pe_close(ntdll);
    puts("PASS: real Wine native DLL code executed from signed RX images; no Wine process was started.");
    return 0;
}
