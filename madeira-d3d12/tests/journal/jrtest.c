/* list-journal test: runs madeira_d3d12.dll's x64 journal methods and trampolines
 * natively on an x86-64 Linux host, with the replay code (jrtest_mock.dll, the
 * real madeira_list_journal.inc.c over logging mocks) behind them. The same
 * random call sequence goes once straight to the mocks and once through the
 * journal; the two call logs must be identical. Source arrays are overwritten
 * after every call, so a journal that kept a pointer instead of a copy fails.
 *
 * Build: gcc -O1 -o jrtest jrtest.c
 * Run:   ./jrtest d3d12.dll d3d12.nm jrtest_mock.dll jrtest_mock.nm   (.nm = llvm-nm output) */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#define MS __attribute__((ms_abi))
#define LIST_SLOTS 96

static int failures;
#define CHECK(c, ...) do { if (!(c)) { if (++failures <= 30) { printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } } while (0)

static void load(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *raw = malloc(n);
    if (fread(raw, 1, n, f) != (size_t)n) exit(1);
    fclose(f);
    uint32_t pe = *(uint32_t *)(raw + 0x3c);
    uint16_t nsec = *(uint16_t *)(raw + pe + 6), optsz = *(uint16_t *)(raw + pe + 20);
    uint64_t base = *(uint64_t *)(raw + pe + 24 + 24);
    uint32_t size = *(uint32_t *)(raw + pe + 24 + 56);
    uint8_t *image = mmap((void *)base, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (image != (uint8_t *)base) { fprintf(stderr, "%s: cannot map at %#lx\n", path, (unsigned long)base); exit(1); }
    memcpy(image, raw, *(uint32_t *)(raw + pe + 24 + 60));
    for (int i = 0; i < nsec; i++) {
        uint8_t *h = raw + pe + 24 + optsz + 40 * i;
        uint32_t vsize = *(uint32_t *)(h + 8), va = *(uint32_t *)(h + 12), rsize = *(uint32_t *)(h + 16), rptr = *(uint32_t *)(h + 20);
        memcpy(image + va, raw + rptr, rsize < vsize ? rsize : vsize);
    }
    free(raw);
}

static uint64_t symbol(const char *nm, const char *name)
{
    FILE *f = fopen(nm, "r"); char line[512];
    if (!f) { perror(nm); exit(1); }
    while (fgets(line, sizeof line, f)) {
        char addr[64], type[8], sym[400];
        if (sscanf(line, "%63s %7s %399s", addr, type, sym) == 3 && !strcmp(sym, name)) { fclose(f); return strtoull(addr, NULL, 16); }
    }
    fprintf(stderr, "%s: no %s\n", nm, name); exit(1);
}

/* jrtest_mock.c's shapes */
struct event { uint32_t method, pad; uint64_t a[7]; };
struct mock_api { void (MS *flush)(void *); void *method[LIST_SLOTS]; int *fail_malloc; size_t list_size, jr_offset, seen_offset; uint32_t slots[32]; };
struct journal { uint8_t *buf; uint32_t used, cap; };
struct method_entry { uint32_t slot; void *fn; };
/* struct mad_jr_ctx (madeira_list_journal.h): what the ARM64EC side keeps in its .data */
struct jr_ctx { void *target[LIST_SLOTS]; uint32_t calls[LIST_SLOTS]; void (MS *flush)(void *); uint8_t census; };

/* the order of mock_api's list */
enum { SetPipelineState, SetGraphicsRootSignature, SetComputeRootSignature,
       SetGraphicsRootConstantBufferView, SetGraphicsRootShaderResourceView, SetGraphicsRootUnorderedAccessView,
       SetComputeRootConstantBufferView, SetComputeRootShaderResourceView, SetComputeRootUnorderedAccessView,
       SetGraphicsRootDescriptorTable, SetComputeRootDescriptorTable,
       SetGraphicsRoot32BitConstant, SetComputeRoot32BitConstant, SetGraphicsRoot32BitConstants, SetComputeRoot32BitConstants,
       IASetPrimitiveTopology, IASetIndexBuffer, IASetVertexBuffers, RSSetViewports, RSSetScissorRects,
       OMSetStencilRef, OMSetBlendFactor, SetDescriptorHeaps, DrawInstanced, DrawIndexedInstanced,
       Dispatch, ResourceBarrier, Close, ClearDepthStencilView, CopyBufferRegion, METHOD_COUNT };

static struct mock_api api;
static struct event *events; static uint32_t *nevents;
static void *vtbl_storage[1 + LIST_SLOTS];   /* [0] is the jr_ctx pointer before slot 0 */
static void **fake_vtbl = vtbl_storage + 1;
static struct jr_ctx list_ctx, res_ctx;
static uint8_t *list;          /* the fake list object */
static uint8_t scratch[8192];  /* source arrays, scribbled after each call */
static int closes;

static void MS trap(void) { printf("FAIL: an unmocked slot was called\n"); exit(1); }

typedef void (MS *P1)(void *, uint64_t);
typedef void (MS *P2)(void *, uint32_t, uint64_t);
typedef void (MS *P3)(void *, uint32_t, uint32_t, uint32_t);
typedef void (MS *P4)(void *, uint32_t, uint32_t, const void *, uint32_t);
typedef void (MS *P5)(void *, uint32_t, uint32_t, const void *);
typedef void (MS *P6)(void *, uint32_t, const void *);
typedef void (MS *P7)(void *, uint32_t, uint32_t, uint32_t, uint32_t);
typedef void (MS *P8)(void *, uint32_t, uint32_t, uint32_t, int32_t, uint32_t);
typedef int32_t (MS *PClose)(void *);
typedef void (MS *PClear)(void *, uint64_t, uint32_t, float, uint8_t, uint32_t, const void *);
typedef void (MS *PCopy)(void *, void *, uint64_t, void *, uint64_t, uint64_t);

static uint64_t rng;
static uint32_t rnd(void) { rng = rng * 6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(rng >> 33); }

/* One random call, through `table` (fake_vtbl or the mocks by slot). */
static void one_call(void **table, int allow_big)
{
    int m = rnd() % METHOD_COUNT;
    void *fn = table[api.slots[m]];
    uint32_t n;
    for (unsigned k = 0; k < 1024; k++) scratch[k] = (uint8_t)rnd();
    switch (m) {
    case SetPipelineState: case SetGraphicsRootSignature: case SetComputeRootSignature:
        ((P1)fn)(list, rnd() % 4 ? 0x7000000000ull + (rnd() % 3) * 64 : 0); break;
    case IASetPrimitiveTopology: case OMSetStencilRef: ((P1)fn)(list, rnd() % 5); break;
    case IASetIndexBuffer: ((P1)fn)(list, rnd() % 6 ? (uint64_t)(uintptr_t)scratch : 0); break;
    case OMSetBlendFactor: ((P1)fn)(list, rnd() % 4 ? (uint64_t)(uintptr_t)scratch : 0); break;
    case SetGraphicsRootConstantBufferView: case SetGraphicsRootShaderResourceView: case SetGraphicsRootUnorderedAccessView:
    case SetComputeRootConstantBufferView: case SetComputeRootShaderResourceView: case SetComputeRootUnorderedAccessView:
    case SetGraphicsRootDescriptorTable: case SetComputeRootDescriptorTable:
        ((P2)fn)(list, rnd() % 20, 0x100000000ull + (rnd() % 4) * 256); break;
    case SetGraphicsRoot32BitConstant: case SetComputeRoot32BitConstant: case Dispatch:
        ((P3)fn)(list, rnd() % 20, rnd(), rnd() % 64); break;
    case SetGraphicsRoot32BitConstants: case SetComputeRoot32BitConstants:
        n = allow_big && rnd() % 10 == 0 ? 65 + rnd() % 100 : rnd() % 65;
        ((P4)fn)(list, rnd() % 20, n, n || rnd() % 2 ? scratch : NULL, rnd() % 64); break;
    case IASetVertexBuffers:
        n = allow_big && rnd() % 10 == 0 ? 33 + rnd() % 8 : rnd() % 33;
        ((P5)fn)(list, rnd() % 4, n, rnd() % 8 ? scratch : NULL); break;
    case RSSetViewports: case RSSetScissorRects: case ResourceBarrier: case SetDescriptorHeaps: {
        uint32_t limit = m == ResourceBarrier ? 32 : m == SetDescriptorHeaps ? 4 : 16;
        n = allow_big && rnd() % 10 == 0 ? limit + 1 + rnd() % 4 : rnd() % (limit + 1);
        ((P6)fn)(list, n, n || rnd() % 2 ? scratch : NULL); break;
    }
    case DrawInstanced: ((P7)fn)(list, rnd(), rnd(), rnd(), rnd()); break;
    case DrawIndexedInstanced: ((P8)fn)(list, rnd(), rnd(), rnd(), (int32_t)rnd(), rnd()); break;
    case Close: {
        int32_t hr = ((PClose)fn)(list);
        CHECK(hr == 0x1234, "Close returned %#x", hr);
        closes++;
        break;
    }
    case ClearDepthStencilView: {
        float depth = (float)(rnd() % 1000) / 1000.0f;
        ((PClear)fn)(list, 0x5000 + rnd() % 100, rnd() % 4, depth, (uint8_t)rnd(), rnd() % 3, (void *)(uintptr_t)(0x9000 + rnd() % 7));
        break;
    }
    case CopyBufferRegion:
        ((PCopy)fn)(list, (void *)(uintptr_t)0x111, rnd(), (void *)(uintptr_t)0x222, rnd(), rnd());
        break;
    }
    memset(scratch, 0xa5, 1024);   /* the journal must have copied what it needs */
}

static void run(void **table, uint64_t seed, int calls, int allow_big)
{
    rng = seed;
    for (int i = 0; i < calls; i++) one_call(table, allow_big);
    /* Close at the end flushes whatever the journal still holds. */
    ((PClose)table[api.slots[Close]])(list);
}

static int compare(const char *what, struct event *expected, uint32_t n_expected)
{
    uint32_t n = *nevents;
    if (n != n_expected) { CHECK(0, "%s: %u calls, expected %u", what, n, n_expected); }
    for (uint32_t i = 0; i < n && i < n_expected; i++)
        if (memcmp(&events[i], &expected[i], sizeof expected[i])) {
            CHECK(0, "%s: call %u differs: method %u vs %u, args %#lx %#lx %#lx %#lx vs %#lx %#lx %#lx %#lx", what, i,
                  events[i].method, expected[i].method,
                  (unsigned long)events[i].a[1], (unsigned long)events[i].a[2], (unsigned long)events[i].a[3], (unsigned long)events[i].a[4],
                  (unsigned long)expected[i].a[1], (unsigned long)expected[i].a[2], (unsigned long)expected[i].a[3], (unsigned long)expected[i].a[4]);
            return 0;
        }
    return n == n_expected;
}

int main(int argc, char **argv)
{
    if (argc != 5) { fprintf(stderr, "usage: %s d3d12.dll d3d12.nm jrtest_mock.dll jrtest_mock.nm\n", argv[0]); return 2; }
    load(argv[1]); load(argv[3]);
    ((void (MS *)(struct mock_api *))symbol(argv[4], "mock_api"))(&api);
    events = (struct event *)symbol(argv[4], "events");
    nevents = (uint32_t *)symbol(argv[4], "nevents");
    void (MS *mock_set_census)(int) = (void (MS *)(int))symbol(argv[4], "mock_set_census");

    /* The PE's .data is a stale copy on the device (Madeira runs ARM64EC code from a pool copy):
     * fill it with garbage, so x64 code that reads it fails here too. */
    {
        uint8_t *base = (uint8_t *)0x180000000ull;
        uint32_t pe = *(uint32_t *)(base + 0x3c);
        uint16_t nsec = *(uint16_t *)(base + pe + 6), optsz = *(uint16_t *)(base + pe + 20);
        for (int i = 0; i < nsec; i++) {
            uint8_t *h = base + pe + 24 + optsz + 40 * i;
            if (!memcmp(h, ".data\0", 6)) { memset(base + *(uint32_t *)(h + 12), 0xcc, *(uint32_t *)(h + 8)); printf(".data of the PE scribbled (%#x bytes)\n", *(uint32_t *)(h + 8)); }
        }
    }
    list_ctx.flush = api.flush;
    vtbl_storage[0] = &list_ctx;
    void **tramps = (void **)symbol(argv[2], "mad_jr_list_tramps");
    struct method_entry *x64 = (struct method_entry *)symbol(argv[2], "mad_jr_x64_methods");

    /* mad_jr_install, over a table of mocks */
    for (int s = 0; s < 82; s++) { list_ctx.target[s] = api.method[s] ? api.method[s] : (void *)trap; fake_vtbl[s] = tramps[s]; }
    int journaled = 0;
    for (struct method_entry *e = x64; e->fn; e++) { fake_vtbl[e->slot] = e->fn; journaled++; }
    printf("x64 methods: %d journaled\n", journaled);
    CHECK(journaled == 27, "expected 27 journaled methods");

    list = aligned_alloc(64, (api.list_size + 63) & ~63ul);
    struct journal *jr = (struct journal *)(list + api.jr_offset);
    static struct event expected[1 << 16];
    static uint8_t small_buf[4096] __attribute__((aligned(16)));

    struct { const char *name; uint32_t cap; int preset, fail, big; } cases[] = {
        { "big journal",           65536, 1, 0, 1 },
        { "48-byte journal",          48, 1, 0, 1 },
        { "200-byte journal",        200, 1, 0, 1 },
        { "1100-byte journal",      1100, 1, 0, 1 },
        { "lazy allocation",           0, 0, 0, 1 },
        { "allocation fails",          0, 0, 1, 1 },
    };
    for (unsigned c = 0; c < sizeof cases / sizeof cases[0]; c++)
        for (uint64_t seed = 1; seed <= 40; seed++) {
            memset(list, 0, api.list_size);
            *(void **)list = fake_vtbl;
            *api.fail_malloc = 0;
            *nevents = 0;
            run(api.method, seed, 2000, cases[c].big);
            uint32_t n_expected = *nevents;
            memcpy(expected, events, n_expected * sizeof *events);

            memset(list, 0, api.list_size);
            *(void **)list = fake_vtbl;
            if (cases[c].preset) { jr->buf = cases[c].cap > sizeof small_buf ? malloc(cases[c].cap) : small_buf; jr->cap = cases[c].cap; }
            *api.fail_malloc = cases[c].fail;
            *nevents = 0;
            run(fake_vtbl, seed, 2000, cases[c].big);
            if (!compare(cases[c].name, expected, n_expected)) { printf("  (case %s, seed %lu)\n", cases[c].name, (unsigned long)seed); break; }
            CHECK(jr->used == 0, "%s: journal not empty after Close", cases[c].name);
            if (seed == 40) printf("%-20s 40 sequences of 2000 calls: identical (%u calls in the last)\n", cases[c].name, n_expected);
        }

    /* api-census: trampolines count the calls they pass on */
    memset(list, 0, api.list_size); *(void **)list = fake_vtbl; *nevents = 0;
    memset(list_ctx.calls, 0, sizeof list_ctx.calls);
    list_ctx.census = 1; mock_set_census(1);
    *api.fail_malloc = 0;
    closes = 0;
    run(fake_vtbl, 99, 3000, 0);
    CHECK(list_ctx.calls[api.slots[Close]] == (uint32_t)closes + 1, "Close counted %u, called %d", list_ctx.calls[api.slots[Close]], closes + 1);
    CHECK(list_ctx.calls[api.slots[DrawInstanced]] == 0, "journaled method counted by a trampoline");
    {
        int64_t ops[40], reps[40];
        ((void (MS *)(int64_t *, int64_t *))symbol(argv[4], "mock_census"))(ops, reps);
        int64_t total = 0; for (int k = 0; k < 40 && k < 29; k++) total += ops[k];
        printf("census: Close counted %u times by its trampoline; replay counted %ld journaled calls\n", list_ctx.calls[api.slots[Close]], (long)total);
        CHECK(total > 0, "replay census counted nothing");
    }
    list_ctx.census = 0; mock_set_census(0);

    /* GetGPUVirtualAddress, counted in the resource ctx (slot 11) only while api-census is on */
    {
        static void *res_vtbl_storage[1 + 17];
        uint8_t resource[0x100] = { 0 };
        res_vtbl_storage[0] = &res_ctx;
        *(void **)resource = res_vtbl_storage + 1;
        *(uint64_t *)(resource + 0x70) = 0x123456789abcull;
        uint64_t (MS *gva)(void *) = (uint64_t (MS *)(void *))symbol(argv[2], "mad_res_gva_x64");
        CHECK(gva(resource) == 0x123456789abcull, "GetGPUVirtualAddress");
        CHECK(res_ctx.calls[11] == 0, "counted with api-census off");
        res_ctx.census = 1; gva(resource); gva(resource);
        CHECK(res_ctx.calls[11] == 2, "GetGPUVirtualAddress counted %u", res_ctx.calls[11]);
    }
    /* api-census trampolines for the other interfaces: count, then reach the method */
    {
        static struct jr_ctx dev_ctx; static void *dev_vtbl_storage[1 + 80];
        void **count = (void **)symbol(argv[2], "mad_jr_count_tramps");
        uint8_t device[64] = { 0 };
        dev_vtbl_storage[0] = &dev_ctx;
        for (int i = 0; i < 80; i++) { dev_ctx.target[i] = api.method[api.slots[Close]]; dev_vtbl_storage[1 + i] = count[i]; }
        *(void **)device = dev_vtbl_storage + 1;
        *nevents = 0;
        int32_t hr = ((PClose)dev_vtbl_storage[1 + 41])(device);
        CHECK(hr == 0x1234 && *nevents == 1 && events[0].a[0] == (uintptr_t)device && dev_ctx.calls[41] == 1, "count trampoline");
    }

    printf("%s (%d failures)\n", failures ? "FAILED" : "all passed", failures);
    return failures != 0;
}
