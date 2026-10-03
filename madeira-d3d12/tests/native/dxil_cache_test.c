/* ml1990: host test for the DXIL conversion cache (src/unix/madeira_dxil_cache.h).
 *
 * Plain C, no converter and no Apple SDK: it checks what the cache must get
 * right without a device.
 *   - key stability: identical conversions key identically, whatever the
 *     caller's pointers, reserved fields or range-array placement;
 *   - key sensitivity: every input the DXIL branch reads changes the key AND
 *     the independent check hash;
 *   - key insensitivity: inputs the DXIL branch never reads (the DXBC-only
 *     vs_bytecode / ps_* fields, output buffers, layout without emulation) do
 *     not split entries;
 *   - the entry round-trips through memory and disk and is handed over with
 *     the caller's caps and the size-then-fill contract respected;
 *   - torn, truncated and foreign entries are refused;
 *   - the size bound evicts least-recently-used entries and nothing else.
 *
 * Build and run (Linux / WSL / macOS):
 *   cc -std=c11 -D_DEFAULT_SOURCE -Wall -Wextra -Werror -I madeira-d3d12/src \
 *      madeira-d3d12/tests/native/dxil_cache_test.c -o /tmp/dxil_cache_test && /tmp/dxil_cache_test
 */
#include "unix/madeira_dxil_cache.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

static int g_fail, g_pass;
#define CHECK(c, ...) do { if (c) g_pass++; else { g_fail++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* One complete conversion request, owned by the test. */
struct req {
    unsigned char dxil[4096];
    char entry[16], osv[8];
    struct madeira_ir_root_param params[4];
    struct madeira_ir_root_range ranges[4];
    struct madeira_ir_static_sampler samplers[2];
    struct madeira_ir_input_layout layout;
    unsigned char vs[64];
    struct madeira_ir_convert_args a;
};

static void req_init(struct req *r)
{
    memset(r, 0, sizeof *r);
    for (size_t i = 0; i < sizeof r->dxil; i++) r->dxil[i] = (unsigned char)(i * 131u + 7u);
    memcpy(r->dxil, "DXBC", 4);
    snprintf(r->entry, sizeof r->entry, "main");
    snprintf(r->osv, sizeof r->osv, "18.0");
    /* p0 constants b0, p1 CBV b1, p2 table of ranges[1..2], p3 UAV u0.
     * ranges[0] and ranges[3] are NOT referenced by any table. */
    r->params[0].type = MADEIRA_IR_PARAM_CONSTANTS; r->params[0].shader_register = 0; r->params[0].num_constants = 4;
    r->params[1].type = MADEIRA_IR_PARAM_CBV; r->params[1].shader_register = 1; r->params[1].visibility = MADEIRA_IR_VIS_PIXEL;
    r->params[2].type = MADEIRA_IR_PARAM_TABLE; r->params[2].first_range = 1; r->params[2].num_ranges = 2;
    r->params[3].type = MADEIRA_IR_PARAM_UAV; r->params[3].shader_register = 0; r->params[3].register_space = 1;
    r->ranges[0].range_type = MADEIRA_IR_RANGE_SRV; r->ranges[0].num_descriptors = 9;
    r->ranges[1].range_type = MADEIRA_IR_RANGE_SRV; r->ranges[1].num_descriptors = 8; r->ranges[1].base_register = 0;
    r->ranges[2].range_type = MADEIRA_IR_RANGE_SAMPLER; r->ranges[2].num_descriptors = 2; r->ranges[2].table_offset = 8;
    r->ranges[3].range_type = MADEIRA_IR_RANGE_UAV; r->ranges[3].num_descriptors = 1;
    r->samplers[0].filter = 0x15; r->samplers[0].address_u = 1; r->samplers[0].max_lod = 1000.0f; r->samplers[0].shader_register = 3;
    r->samplers[1].filter = 0x55; r->samplers[1].comparison = 2; r->samplers[1].shader_register = 4;
    r->layout.n = 2;
    snprintf(r->layout.el[0].semantic, sizeof r->layout.el[0].semantic, "POSITION");
    r->layout.el[0].format = 6; r->layout.el[0].offset = 0;
    snprintf(r->layout.el[1].semantic, sizeof r->layout.el[1].semantic, "TEXCOORD");
    r->layout.el[1].format = 16; r->layout.el[1].offset = 12;
    memset(r->vs, 0x5a, sizeof r->vs);

    r->a.dxil = (uint64_t)(uintptr_t)r->dxil; r->a.dxil_len = sizeof r->dxil;
    r->a.entry_point = (uint64_t)(uintptr_t)r->entry;
    r->a.params = (uint64_t)(uintptr_t)r->params; r->a.num_params = 4;
    r->a.ranges = (uint64_t)(uintptr_t)r->ranges; r->a.num_ranges = 4;
    r->a.samplers = (uint64_t)(uintptr_t)r->samplers; r->a.num_samplers = 2;
    r->a.target_os = MADEIRA_IR_OS_IOS; r->a.gpu_family = 1009;
    r->a.os_version = (uint64_t)(uintptr_t)r->osv;
    r->a.gs_emulation = 1; r->a.input_topology = 3;
    r->a.layout = (uint64_t)(uintptr_t)&r->layout;
}

/* Re-point a copied request's pointers at its own storage. */
static void req_fix(struct req *r)
{
    r->a.dxil = (uint64_t)(uintptr_t)r->dxil;
    r->a.entry_point = (uint64_t)(uintptr_t)r->entry;
    r->a.params = (uint64_t)(uintptr_t)r->params;
    r->a.ranges = (uint64_t)(uintptr_t)r->ranges;
    r->a.samplers = (uint64_t)(uintptr_t)r->samplers;
    r->a.os_version = (uint64_t)(uintptr_t)r->osv;
    if (r->a.layout) r->a.layout = (uint64_t)(uintptr_t)&r->layout;
}

static const struct mad_dxc_env g_env = { 0x1234567890abcdefull, "Sep 25 2026 12:00:00", 1, 1 };

static void key_of(const struct req *r, const struct mad_dxc_env *env, uint64_t *k, uint64_t *c)
{
    mad_dxc_key(&r->a, env ? env : &g_env, k, c);
}

static struct req g_base;

static void expect_same(const struct req *r, const char *what)
{
    uint64_t k0, c0, k1, c1;
    key_of(&g_base, NULL, &k0, &c0);
    key_of(r, NULL, &k1, &c1);
    CHECK(k0 == k1 && c0 == c1, "key must NOT change: %s", what);
}

static void expect_diff(const struct req *r, const struct mad_dxc_env *env, const char *what)
{
    uint64_t k0, c0, k1, c1;
    key_of(&g_base, NULL, &k0, &c0);
    key_of(r, env, &k1, &c1);
    CHECK(k0 != k1 && c0 != c1, "key must change: %s", what);
}

#define MUTATE(what, ...) do { struct req *m_ = malloc(sizeof *m_); *m_ = g_base; req_fix(m_); { struct req *r = m_; __VA_ARGS__; } expect_diff(m_, NULL, what); free(m_); } while (0)
#define KEEP(what, ...)   do { struct req *m_ = malloc(sizeof *m_); *m_ = g_base; req_fix(m_); { struct req *r = m_; __VA_ARGS__; } expect_same(m_, what); free(m_); } while (0)

static void test_key(void)
{
    req_init(&g_base);

    /* Stability. */
    KEEP("identical copy at other addresses", (void)r);
    KEEP("reserved fields", { r->params[0].reserved = 77; r->ranges[1].reserved = 5; r->samplers[1].reserved = 9; r->layout.reserved = 3; });
    KEEP("unused param fields for the type", { r->params[1].num_constants = 99; r->params[2].shader_register = 12; r->params[0].first_range = 3; });
    KEEP("unreferenced ranges", { r->ranges[0].num_descriptors = 1; r->ranges[3].base_register = 40; });
    KEEP("table ranges relocated in the array", {
        struct madeira_ir_root_range t1 = r->ranges[1], t2 = r->ranges[2];
        r->ranges[0] = r->ranges[3]; r->ranges[2] = t1; r->ranges[3] = t2; r->params[2].first_range = 2; });
    KEEP("garbage after the semantic terminator", { memset(r->layout.el[0].semantic + 9, 0x7f, 20); });
    KEEP("DXBC-only vs_bytecode", { r->a.vs_bytecode = (uint64_t)(uintptr_t)r->vs; r->a.vs_bytecode_len = sizeof r->vs; });
    KEEP("DXBC-only ps fields", { r->a.ps_valid = 1; r->a.ps_flags = 3; r->a.ps_sample_mask = 0xf; r->a.ps_unorm_output_mask = 1; });
    KEEP("output buffers and caps", { r->a.out_buf = 0x1000; r->a.out_cap = 99; r->a.out_locs = 0x2000; r->a.loc_cap = 64; r->a.out_buf2 = 1; r->a.out_cap2 = 7; r->a.out_vs_inputs = 5; r->a.vs_input_cap = 31; });
    KEEP("elements beyond the layout count", { r->layout.el[5].format = 99; });
    {
        struct req *x = malloc(sizeof *x), *y = malloc(sizeof *y);
        uint64_t k1, c1, k2, c2;
        *x = g_base; req_fix(x); *y = g_base; req_fix(y);
        x->entry[0] = 0; y->a.entry_point = 0;
        key_of(x, NULL, &k1, &c1); key_of(y, NULL, &k2, &c2);
        CHECK(k1 == k2 && c1 == c2, "\"\" and NULL entry must key the same");
        free(x); free(y);
    }
    {   /* Without emulation, topology and layout are never read. */
        struct req *x = malloc(sizeof *x), *y = malloc(sizeof *y);
        uint64_t k1, c1, k2, c2;
        *x = g_base; req_fix(x); *y = g_base; req_fix(y);
        x->a.gs_emulation = 0; y->a.gs_emulation = 0;
        y->a.input_topology = 1; y->layout.el[0].format = 2; y->a.layout = 0;
        key_of(x, NULL, &k1, &c1); key_of(y, NULL, &k2, &c2);
        CHECK(k1 == k2 && c1 == c2, "topology/layout must not key a non-emulated stage");
        free(x); free(y);
    }

    /* Sensitivity. */
    MUTATE("one DXIL byte", r->dxil[2000] ^= 1);
    MUTATE("last DXIL byte", r->dxil[sizeof r->dxil - 1] ^= 0x80);
    MUTATE("DXIL length", r->a.dxil_len -= 1);
    MUTATE("entry name", r->entry[0] = 'M');
    MUTATE("param count", r->a.num_params = 3);
    MUTATE("param type", r->params[1].type = MADEIRA_IR_PARAM_SRV);
    MUTATE("param visibility", r->params[1].visibility = MADEIRA_IR_VIS_ALL);
    MUTATE("constants register", r->params[0].shader_register = 2);
    MUTATE("constants space", r->params[0].register_space = 1);
    MUTATE("constants count", r->params[0].num_constants = 5);
    MUTATE("descriptor register", r->params[3].shader_register = 1);
    MUTATE("descriptor space", r->params[3].register_space = 0);
    MUTATE("table range count", r->params[2].num_ranges = 1);
    MUTATE("table first range", r->params[2].first_range = 0);
    MUTATE("range type", r->ranges[1].range_type = MADEIRA_IR_RANGE_UAV);
    MUTATE("range descriptors", r->ranges[1].num_descriptors = 7);
    MUTATE("range base register", r->ranges[2].base_register = 1);
    MUTATE("range space", r->ranges[2].register_space = 2);
    MUTATE("range table offset", r->ranges[2].table_offset = 9);
    MUTATE("sampler count", r->a.num_samplers = 1);
    MUTATE("sampler filter", r->samplers[0].filter = 0x14);
    MUTATE("sampler address", r->samplers[1].address_w = 3);
    MUTATE("sampler lod bias", r->samplers[0].mip_lod_bias = 0.5f);
    MUTATE("sampler anisotropy", r->samplers[0].max_anisotropy = 16);
    MUTATE("sampler comparison", r->samplers[1].comparison = 3);
    MUTATE("sampler border", r->samplers[1].border_color = 1);
    MUTATE("sampler min lod", r->samplers[0].min_lod = 1.0f);
    MUTATE("sampler max lod", r->samplers[0].max_lod = 2.0f);
    MUTATE("sampler register", r->samplers[1].shader_register = 5);
    MUTATE("sampler space", r->samplers[1].register_space = 1);
    MUTATE("sampler visibility", r->samplers[1].visibility = MADEIRA_IR_VIS_PIXEL);
    MUTATE("target OS", r->a.target_os = MADEIRA_IR_OS_MACOS);
    MUTATE("GPU family", r->a.gpu_family = 1008);
    MUTATE("minimum OS version", r->osv[1] = '7');
    MUTATE("geometry emulation", r->a.gs_emulation = 0);
    MUTATE("input topology (emulated)", r->a.input_topology = 1);
    MUTATE("layout present (emulated)", r->a.layout = 0);
    MUTATE("layout count", r->layout.n = 1);
    MUTATE("layout semantic", r->layout.el[1].semantic[0] = 'N');
    MUTATE("layout semantic index", r->layout.el[1].semantic_index = 1);
    MUTATE("layout format", r->layout.el[0].format = 2);
    MUTATE("layout slot", r->layout.el[1].slot = 1);
    MUTATE("layout offset", r->layout.el[1].offset = 16);
    MUTATE("layout per-instance", r->layout.el[1].per_instance = 1);
    MUTATE("layout step rate", r->layout.el[1].step_rate = 1);
    {
        struct mad_dxc_env e = g_env;
        e.converter_ident ^= 1; expect_diff(&g_base, &e, "converter identity");
        e = g_env; e.build_stamp = "Sep 25 2026 12:00:01"; expect_diff(&g_base, &e, "build stamp");
        e = g_env; e.ags_rewrite = 0; expect_diff(&g_base, &e, "AGS rewrite switch");
        e = g_env; e.compat_flags = 0; expect_diff(&g_base, &e, "compatibility flags");
    }
    {   /* A table pointing outside the ranges must not read out of bounds. */
        struct req *x = malloc(sizeof *x);
        uint64_t k, c;
        *x = g_base; req_fix(x);
        x->params[2].first_range = 3; x->params[2].num_ranges = 5;
        key_of(x, NULL, &k, &c);
        CHECK(1, "out-of-range table keyed without faulting");
        free(x);
    }
}

/* ---- entry ---- */
static void make_parts(struct mad_dxc_parts *p, struct madeira_ir_loc *locs, struct madeira_ir_vs_input *vsin,
                       unsigned char *lib, size_t lib_len, unsigned char *lib2, size_t lib2_len)
{
    memset(p, 0, sizeof *p);
    for (size_t i = 0; i < lib_len; i++) lib[i] = (unsigned char)(i ^ 0xa5);
    for (size_t i = 0; i < lib2_len; i++) lib2[i] = (unsigned char)(i * 3);
    for (uint32_t i = 0; i < 5; i++) { locs[i].type = i; locs[i].slot = i + 10; locs[i].offset = i * 8; locs[i].size = 8; }
    for (uint32_t i = 0; i < 3; i++) { snprintf(vsin[i].name, sizeof vsin[i].name, "in%u", i); vsin[i].attribute = i + 1; }
    p->stage = 1; p->entry = "main_vs_converted"; p->note = "";
    p->locs = locs; p->nlocs = 5; p->vsin = vsin; p->nvsin = 3; p->vs_input_count = 3;
    p->tg[0] = 8; p->tg[1] = 4; p->tg[2] = 1; p->vs_output_size = 64;
    p->gs_max_prims = 2; p->gs_payload = 128; p->gs_passthrough = 1;
    for (uint32_t i = 0; i < 8; i++) p->hs[i] = 100 + i;
    for (uint32_t i = 0; i < 4; i++) p->ds[i] = 200 + i;
    p->lib = lib; p->lib_len = lib_len; p->lib2 = lib2; p->lib2_len = lib2_len;
}

static void test_entry(void)
{
    static unsigned char lib[3000], lib2[500], out[4096], out2[1024];
    struct madeira_ir_loc locs[5], got_locs[8];
    struct madeira_ir_vs_input vsin[3], got_vs[2];
    struct mad_dxc_parts p;
    struct madeira_ir_convert_args a;
    char name[MADEIRA_IR_ENTRY_MAX];
    size_t len = 0;
    void *blob;
    const uint64_t K = 0x1111222233334444ull, C = 0x5555666677778888ull;

    make_parts(&p, locs, vsin, lib, sizeof lib, lib2, sizeof lib2);
    blob = mad_dxc_blob_build(K, C, &p, &len);
    CHECK(blob && len == sizeof(struct mad_dxc_header) + sizeof locs + sizeof vsin + sizeof lib + sizeof lib2, "blob size %zu", len);
    CHECK(mad_dxc_blob_valid(blob, len, K, C), "valid blob accepted");
    CHECK(!mad_dxc_blob_valid(blob, len, K ^ 1, C), "foreign key refused");
    CHECK(!mad_dxc_blob_valid(blob, len, K, C ^ 1), "check-hash collision refused");
    CHECK(!mad_dxc_blob_valid(blob, len - 1, K, C), "truncated blob refused");
    CHECK(!mad_dxc_blob_valid(blob, sizeof(struct mad_dxc_header) - 1, K, C), "header-only fragment refused");
    {
        unsigned char *bad = malloc(len);
        memcpy(bad, blob, len);
        ((struct mad_dxc_header *)bad)->nlocs += 1;
        CHECK(!mad_dxc_blob_valid(bad, len, K, C), "inconsistent counts refused");
        memcpy(bad, blob, len);
        ((struct mad_dxc_header *)bad)->version += 1;
        CHECK(!mad_dxc_blob_valid(bad, len, K, C), "other format version refused");
        free(bad);
    }

    /* Sizing call: no buffer -> TOO_SMALL with the size, nothing written. */
    memset(&a, 0, sizeof a);
    CHECK(mad_dxc_deliver(blob, &a) == MADEIRA_IR_BUFFER_TOO_SMALL && a.ret_len == sizeof lib &&
          a.ret_status == MADEIRA_IR_BUFFER_TOO_SMALL, "sizing call reports %llu", (unsigned long long)a.ret_len);
    memset(&a, 0, sizeof a);
    a.out_buf = (uint64_t)(uintptr_t)out; a.out_cap = sizeof lib - 1;
    CHECK(mad_dxc_deliver(blob, &a) == MADEIRA_IR_BUFFER_TOO_SMALL, "one byte short is too small");

    /* Fill call with small caps. */
    memset(&a, 0, sizeof a); memset(out, 0, sizeof out); memset(got_locs, 0xee, sizeof got_locs); memset(name, 0, sizeof name);
    a.out_buf = (uint64_t)(uintptr_t)out; a.out_cap = sizeof out;
    a.out_entry = (uint64_t)(uintptr_t)name;
    a.out_locs = (uint64_t)(uintptr_t)got_locs; a.loc_cap = 8;
    a.out_vs_inputs = (uint64_t)(uintptr_t)got_vs; a.vs_input_cap = 2;
    a.out_buf2 = (uint64_t)(uintptr_t)out2; a.out_cap2 = sizeof out2;
    CHECK(mad_dxc_deliver(blob, &a) == MADEIRA_IR_OK && a.ret_status == MADEIRA_IR_OK, "fill call ok");
    CHECK(a.ret_len == sizeof lib && !memcmp(out, lib, sizeof lib), "metallib bytes");
    CHECK(!strcmp(name, "main_vs_converted"), "entry name '%s'", name);
    CHECK(a.ret_loc_count == 5 && !memcmp(got_locs, locs, sizeof locs) && got_locs[5].type == 0xeeeeeeeeu, "locations and cap");
    CHECK(a.ret_vs_input_count == 3 && !strcmp(got_vs[1].name, "in1") && got_vs[1].attribute == 2, "vertex inputs clamp to cap, count stays 3");
    CHECK(a.ret_tg_size[0] == 8 && a.ret_tg_size[1] == 4 && a.ret_tg_size[2] == 1, "threadgroup");
    CHECK(a.ret_stage == 1 && a.ret_vs_output_size == 64 && a.ret_gs_max_prims == 2 && a.ret_gs_payload == 128 && a.ret_gs_passthrough == 1, "scalars");
    CHECK(a.ret_len2 == sizeof lib2 && !memcmp(out2, lib2, sizeof lib2) && !a.ret_note[0], "stage-in library");
    CHECK(a.ret_hs_patches_per_tg == 100 && a.ret_hs_threads_per_patch == 101 && a.ret_hs_input_cps == 102 &&
          a.ret_hs_output_cps == 103 && a.ret_hs_output_cp_size == 104 && a.ret_hs_patch_const_size == 105 &&
          a.ret_hs_out_prim == 106 && a.ret_hs_max_factor_bits == 107, "hull reflection");
    CHECK(a.ret_ds_prims_per_mesh_tg == 200 && a.ret_ds_input_cps == 201 && a.ret_ds_input_cp_size == 202 &&
          a.ret_ds_patch_const_size == 203, "domain reflection");

    /* No location buffer: the count is reported as 0, as a fresh conversion does. */
    memset(&a, 0, sizeof a);
    a.out_buf = (uint64_t)(uintptr_t)out; a.out_cap = sizeof out; a.out_entry = (uint64_t)(uintptr_t)name;
    CHECK(mad_dxc_deliver(blob, &a) == MADEIRA_IR_OK && a.ret_loc_count == 0 && a.ret_len2 == sizeof lib2 && a.ret_note[0],
          "no loc buffer -> count 0; no stage-in buffer -> note '%s'", a.ret_note);
    /* No entry buffer: same status as a fresh conversion. */
    memset(&a, 0, sizeof a);
    a.out_buf = (uint64_t)(uintptr_t)out; a.out_cap = sizeof out;
    CHECK(mad_dxc_deliver(blob, &a) == MADEIRA_IR_EMPTY_ENTRY, "no entry buffer -> EMPTY_ENTRY");

    /* No metallib / empty entry are never built. */
    {
        struct mad_dxc_parts q = p; size_t l2;
        q.lib_len = 0;
        CHECK(!mad_dxc_blob_build(K, C, &q, &l2), "empty metallib not cached");
        q = p; q.entry = "";
        void *b2 = mad_dxc_blob_build(K, C, &q, &l2);
        CHECK(b2 && !mad_dxc_blob_valid(b2, l2, K, C), "empty entry never validates");
        free(b2);
    }

    /* Disk round trip. */
    {
        char dir[] = "/tmp/ml1990-dxc-XXXXXX", path[256];
        void *got = NULL; size_t glen = 0;
        CHECK(mkdtemp(dir) != NULL, "mkdtemp");
        snprintf(path, sizeof path, "%s/%016llx.%s", dir, (unsigned long long)K, MAD_DXC_EXT);
        CHECK(mad_dxc_file_store(path, blob, len), "store");
        CHECK(mad_dxc_file_load(path, K, C, &got, &glen) && glen == len && !memcmp(got, blob, len), "load returns the same bytes");
        free(got); got = NULL;
        CHECK(!mad_dxc_file_load(path, K, C ^ 2, &got, &glen) && !got, "load refuses a check mismatch");
        {   /* torn file */
            FILE *f = fopen(path, "r+b");
            if (f) { if (ftruncate(fileno(f), (off_t)(len - 10)) != 0) perror("ftruncate"); fclose(f); }
            CHECK(!mad_dxc_file_load(path, K, C, &got, &glen) && !got, "torn file refused");
        }
        unlink(path);
        CHECK(!mad_dxc_file_load(path, K, C, &got, &glen), "missing file is a miss");
        rmdir(dir);
    }
    free(blob);
}

static void write_file(const char *dir, const char *name, size_t size, time_t mtime)
{
    char path[512];
    struct timeval tv[2];
    FILE *f;
    snprintf(path, sizeof path, "%s/%s", dir, name);
    f = fopen(path, "wb");
    if (!f) return;
    for (size_t i = 0; i < size; i++) fputc(0, f);
    fclose(f);
    tv[0].tv_sec = tv[1].tv_sec = mtime; tv[0].tv_usec = tv[1].tv_usec = 0;
    utimes(path, tv);
}

static int exists(const char *dir, const char *name)
{
    char path[512];
    struct stat st;
    snprintf(path, sizeof path, "%s/%s", dir, name);
    return stat(path, &st) == 0;
}

static void test_prune(void)
{
    char dir[] = "/tmp/ml1990-prune-XXXXXX";
    unsigned nf = 0, rm = 0;
    uint64_t left;
    CHECK(mkdtemp(dir) != NULL, "mkdtemp");
    write_file(dir, "000000000000000a.mdxc", 1000, 1000);   /* oldest */
    write_file(dir, "000000000000000b.mdxc", 1000, 2000);
    write_file(dir, "000000000000000c.mdxc", 1000, 3000);
    write_file(dir, "000000000000000d.mdxc", 1000, 4000);
    write_file(dir, "000000000000000e.mdxc", 1000, 5000);   /* newest */
    write_file(dir, "00000000000000aa.mdsc", 9000, 10);     /* DXBC cache: never touched */
    write_file(dir, "notakey.mdxc", 9000, 10);              /* not ours */
    write_file(dir, "000000000000000f.mdxc.tmp123", 9000, 10);

    left = mad_dxc_prune(dir, MAD_DXC_EXT, 10000, 7500, &nf, &rm);
    CHECK(left == 5000 && nf == 5 && rm == 0, "under the bound nothing is evicted (left %llu nf %u rm %u)", (unsigned long long)left, nf, rm);

    left = mad_dxc_prune(dir, MAD_DXC_EXT, 4000, 3000, &nf, &rm);
    CHECK(left == 3000 && nf == 3 && rm == 2, "over the bound: evict to target (left %llu nf %u rm %u)", (unsigned long long)left, nf, rm);
    CHECK(!exists(dir, "000000000000000a.mdxc") && !exists(dir, "000000000000000b.mdxc"), "least recently used went first");
    CHECK(exists(dir, "000000000000000c.mdxc") && exists(dir, "000000000000000e.mdxc"), "recent entries kept");
    CHECK(exists(dir, "00000000000000aa.mdsc") && exists(dir, "notakey.mdxc") && exists(dir, "000000000000000f.mdxc.tmp123"),
          "foreign files untouched");

    /* A load bumps recency: c becomes the newest, so d goes next. */
    {
        char path[512];
        snprintf(path, sizeof path, "%s/000000000000000c.mdxc", dir);
        utimes(path, NULL);
        left = mad_dxc_prune(dir, MAD_DXC_EXT, 2500, 2000, &nf, &rm);
        CHECK(rm == 1 && !exists(dir, "000000000000000d.mdxc") && exists(dir, "000000000000000c.mdxc"), "LRU honours a recent use");
    }
    {
        const char *names[] = { "000000000000000c.mdxc", "000000000000000e.mdxc", "00000000000000aa.mdsc", "notakey.mdxc", "000000000000000f.mdxc.tmp123" };
        char path[512];
        for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) { snprintf(path, sizeof path, "%s/%s", dir, names[i]); unlink(path); }
        rmdir(dir);
    }
    CHECK(mad_dxc_prune("/nonexistent/ml1990", MAD_DXC_EXT, 1, 1, &nf, &rm) == 0 && nf == 0, "missing directory");
}

int main(void)
{
    test_key();
    test_entry();
    test_prune();
    printf("[dxil-cache-test] ml1990 %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
