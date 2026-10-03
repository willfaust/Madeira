/* ml1990: content-keyed cache for the DXIL (Metal Shader Converter) path.
 *
 * Measured: a D3D12 title's startup was CPU-bound converting ~160 DXIL shaders
 * on every launch, with a black screen for over 30 seconds. The DXBC backend has
 * had a disk cache since ml1020; the DXIL path had none, so every launch paid
 * for every conversion again.
 *
 * This header is plain C with no Objective-C and no converter types, so the key
 * and the entry format can be exercised by a native host test
 * (tests/native/dxil_cache_test.c) without the converter or an Apple SDK.
 *
 * KEY IDENTITY. The key covers exactly what madeira_ir_convert_impl's DXIL
 * branch reads: the bytecode, the D3D entry name, the root signature (params,
 * the ranges each table references, static samplers), the target OS / GPU
 * family / minimum OS version, geometry emulation and -- only when emulation is
 * on, because only then are they read -- the input topology and the input
 * layout the stage-in function is synthesised from. The caller adds the
 * environment: the converter dylib's identity, this build's stamp, the header
 * version and whether the AGS rewrite runs.
 *
 * Deliberately NOT keyed: vs_bytecode (ml1031) and the ps_* fields (ml1023).
 * Only the DXBC backend reads them; the DXIL branch never does. Keying on them
 * would multiply entries for one pixel shader by every vertex shader and blend
 * state it is paired with, which is exactly the duplicate work this removes. If
 * the DXIL branch ever starts reading one of them, it must be added here.
 *
 * Each entry also stores a second, independent 64-bit hash of the same stream,
 * so a collision of the file-name key alone cannot serve the wrong shader. */
#ifndef MADEIRA_DXIL_CACHE_H
#define MADEIRA_DXIL_CACHE_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/time.h>

#include "../madeira_ir_abi.h"

#define MAD_DXC_MAGIC   0x4358444du   /* "MDXC" */
#define MAD_DXC_VERSION 2u   /* 2: DXIL hull/domain reflection */
#define MAD_DXC_EXT     "mdxc"
#define MAD_DXC_MAX_FILE (64u << 20)  /* refuse to trust anything larger */

/* ---- hashing ------------------------------------------------------------- */
struct mad_dxc_hasher { uint64_t h1, h2; };

static inline void mad_dxc_hinit(struct mad_dxc_hasher *s)
{
    s->h1 = 1469598103934665603ull;      /* FNV-1a 64, as the DXBC cache */
    s->h2 = 0x6a09e667f3bcc909ull;       /* multiply-rotate, independent of h1 */
}

static inline void mad_dxc_hadd(struct mad_dxc_hasher *s, const void *p, size_t n)
{
    const unsigned char *b = (const unsigned char *)p;
    uint64_t h1 = s->h1, h2 = s->h2;
    for (size_t i = 0; i < n; i++) {
        h1 ^= b[i]; h1 *= 1099511628211ull;
        h2 ^= b[i]; h2 = (h2 << 23) | (h2 >> 41); h2 *= 0x9e3779b97f4a7c15ull;
    }
    s->h1 = h1; s->h2 = h2;
}

static inline void mad_dxc_hu32(struct mad_dxc_hasher *s, uint32_t v) { mad_dxc_hadd(s, &v, sizeof v); }
static inline void mad_dxc_hu64(struct mad_dxc_hasher *s, uint64_t v) { mad_dxc_hadd(s, &v, sizeof v); }

/* Length-prefixed, so ("ab","c") and ("a","bc") differ. NULL and "" are one
 * value: the converter treats both as "no name". */
static inline void mad_dxc_hstr(struct mad_dxc_hasher *s, const char *str, size_t max)
{
    size_t n = 0;
    if (str) while (n < max && str[n]) n++;
    mad_dxc_hu64(s, (uint64_t)n);
    if (n) mad_dxc_hadd(s, str, n);
}

/* Everything outside the arguments that shapes the output. */
struct mad_dxc_env {
    uint64_t converter_ident;   /* the loaded converter dylib (LC_UUID + size) + header version */
    const char *build_stamp;    /* this service's build: its parameter mapping is code */
    uint32_t ags_rewrite;       /* ml1149 rewrite enabled */
    uint32_t compat_flags;      /* compatibility flags handed to the compiler */
};

static inline void mad_dxc_key(const struct madeira_ir_convert_args *a,
                               const struct mad_dxc_env *env,
                               uint64_t *key, uint64_t *check)
{
    struct mad_dxc_hasher s;
    const struct madeira_ir_root_param *ps = (const struct madeira_ir_root_param *)(uintptr_t)a->params;
    const struct madeira_ir_root_range *rs = (const struct madeira_ir_root_range *)(uintptr_t)a->ranges;
    const struct madeira_ir_static_sampler *ss = (const struct madeira_ir_static_sampler *)(uintptr_t)a->samplers;

    mad_dxc_hinit(&s);
    mad_dxc_hadd(&s, "mdxc", 4);
    mad_dxc_hu32(&s, MAD_DXC_VERSION);
    mad_dxc_hu64(&s, env->converter_ident);
    mad_dxc_hstr(&s, env->build_stamp, 64);
    mad_dxc_hu32(&s, env->ags_rewrite);
    mad_dxc_hu32(&s, env->compat_flags);

    mad_dxc_hu64(&s, a->dxil_len);
    if (a->dxil && a->dxil_len) mad_dxc_hadd(&s, (const void *)(uintptr_t)a->dxil, (size_t)a->dxil_len);
    mad_dxc_hstr(&s, (const char *)(uintptr_t)a->entry_point, MADEIRA_IR_ENTRY_MAX);

    /* Root signature: only the fields the conversion reads, never `reserved`,
     * and a table by the CONTENT of the ranges it references (not by where
     * they sit in the caller's array). */
    mad_dxc_hu64(&s, ps ? a->num_params : 0);
    for (uint64_t i = 0; ps && i < a->num_params; i++) {
        const struct madeira_ir_root_param *p = &ps[i];
        mad_dxc_hu32(&s, p->type);
        mad_dxc_hu32(&s, p->visibility);
        switch (p->type) {
        case MADEIRA_IR_PARAM_CONSTANTS:
            mad_dxc_hu32(&s, p->shader_register); mad_dxc_hu32(&s, p->register_space);
            mad_dxc_hu32(&s, p->num_constants);
            break;
        case MADEIRA_IR_PARAM_CBV: case MADEIRA_IR_PARAM_SRV: case MADEIRA_IR_PARAM_UAV:
            mad_dxc_hu32(&s, p->shader_register); mad_dxc_hu32(&s, p->register_space);
            break;
        case MADEIRA_IR_PARAM_TABLE:
            mad_dxc_hu32(&s, p->num_ranges);
            if (!rs || (uint64_t)p->first_range + p->num_ranges > a->num_ranges) {
                mad_dxc_hu32(&s, 0xffffffffu);   /* refused by the converter anyway */
                break;
            }
            for (uint32_t k = 0; k < p->num_ranges; k++) {
                const struct madeira_ir_root_range *r = &rs[p->first_range + k];
                mad_dxc_hu32(&s, r->range_type); mad_dxc_hu32(&s, r->num_descriptors);
                mad_dxc_hu32(&s, r->base_register); mad_dxc_hu32(&s, r->register_space);
                mad_dxc_hu32(&s, r->table_offset);
            }
            break;
        default:
            break;
        }
    }
    mad_dxc_hu32(&s, ss ? a->num_samplers : 0);
    for (uint32_t i = 0; ss && i < a->num_samplers; i++) {
        const struct madeira_ir_static_sampler *m = &ss[i];
        mad_dxc_hu32(&s, m->filter); mad_dxc_hu32(&s, m->address_u);
        mad_dxc_hu32(&s, m->address_v); mad_dxc_hu32(&s, m->address_w);
        mad_dxc_hadd(&s, &m->mip_lod_bias, sizeof m->mip_lod_bias);
        mad_dxc_hu32(&s, m->max_anisotropy); mad_dxc_hu32(&s, m->comparison);
        mad_dxc_hu32(&s, m->border_color);
        mad_dxc_hadd(&s, &m->min_lod, sizeof m->min_lod);
        mad_dxc_hadd(&s, &m->max_lod, sizeof m->max_lod);
        mad_dxc_hu32(&s, m->shader_register); mad_dxc_hu32(&s, m->register_space);
        mad_dxc_hu32(&s, m->visibility);
    }

    mad_dxc_hu32(&s, a->target_os);
    mad_dxc_hu32(&s, a->gpu_family);
    mad_dxc_hstr(&s, (const char *)(uintptr_t)a->os_version, 32);

    mad_dxc_hu32(&s, a->gs_emulation ? 1u : 0u);
    if (a->gs_emulation) {   /* ml927: only read under emulation */
        const struct madeira_ir_input_layout *L = (const struct madeira_ir_input_layout *)(uintptr_t)a->layout;
        uint32_t n = L ? (L->n > 31 ? 31 : L->n) : 0;
        mad_dxc_hu32(&s, a->input_topology);
        mad_dxc_hu32(&s, L ? 1u : 0u);
        mad_dxc_hu32(&s, n);
        for (uint32_t i = 0; i < n; i++) {
            const struct madeira_ir_input_element *e = &L->el[i];
            mad_dxc_hstr(&s, e->semantic, sizeof e->semantic);
            mad_dxc_hu32(&s, e->semantic_index); mad_dxc_hu32(&s, e->format);
            mad_dxc_hu32(&s, e->slot); mad_dxc_hu32(&s, e->offset);
            mad_dxc_hu32(&s, e->per_instance ? 1u : 0u); mad_dxc_hu32(&s, e->step_rate);
        }
    }
    *key = s.h1;
    *check = s.h2;
}

/* ---- entry format -------------------------------------------------------- *
 * One contiguous blob, identical in memory and on disk:
 *   header | locs[nlocs] | vs_inputs[nvsin] | metallib | stage-in metallib    */
struct mad_dxc_header {
    uint32_t magic, version;
    uint64_t key, check;
    uint64_t lib_len, lib2_len;
    uint32_t stage, nlocs, nvsin, vs_input_count;
    uint32_t tg[3], vs_output_size;
    uint32_t gs_max_prims, gs_payload, gs_passthrough, reserved;
    char entry[MADEIRA_IR_ENTRY_MAX];
    char note[128];
    uint32_t hs[8], ds[4];   /* ret_hs_* / ret_ds_* in madeira_ir_abi.h order */
};

/* What one successful conversion produced, before it is flattened. */
struct mad_dxc_parts {
    uint32_t stage;
    const char *entry, *note;
    const struct madeira_ir_loc *locs; uint32_t nlocs;
    const struct madeira_ir_vs_input *vsin; uint32_t nvsin;
    uint32_t vs_input_count;
    uint32_t tg[3], vs_output_size, gs_max_prims, gs_payload, gs_passthrough;
    uint32_t hs[8], ds[4];
    const void *lib; uint64_t lib_len;
    const void *lib2; uint64_t lib2_len;
};

static inline void *mad_dxc_blob_build(uint64_t key, uint64_t check,
                                       const struct mad_dxc_parts *p, size_t *len_out)
{
    size_t locs_sz = (size_t)p->nlocs * sizeof(struct madeira_ir_loc);
    size_t vs_sz = (size_t)p->nvsin * sizeof(struct madeira_ir_vs_input);
    size_t len = sizeof(struct mad_dxc_header) + locs_sz + vs_sz + (size_t)p->lib_len + (size_t)p->lib2_len;
    unsigned char *b;
    struct mad_dxc_header h;

    *len_out = 0;
    if (!p->lib || !p->lib_len || len > MAD_DXC_MAX_FILE) return NULL;
    b = (unsigned char *)malloc(len);
    if (!b) return NULL;
    memset(&h, 0, sizeof h);
    h.magic = MAD_DXC_MAGIC; h.version = MAD_DXC_VERSION;
    h.key = key; h.check = check;
    h.lib_len = p->lib_len; h.lib2_len = p->lib2 ? p->lib2_len : 0;
    h.stage = p->stage; h.nlocs = p->nlocs; h.nvsin = p->nvsin; h.vs_input_count = p->vs_input_count;
    h.tg[0] = p->tg[0]; h.tg[1] = p->tg[1]; h.tg[2] = p->tg[2];
    h.vs_output_size = p->vs_output_size;
    h.gs_max_prims = p->gs_max_prims; h.gs_payload = p->gs_payload; h.gs_passthrough = p->gs_passthrough;
    memcpy(h.hs, p->hs, sizeof h.hs); memcpy(h.ds, p->ds, sizeof h.ds);
    snprintf(h.entry, sizeof h.entry, "%s", p->entry ? p->entry : "");
    snprintf(h.note, sizeof h.note, "%s", p->note ? p->note : "");
    memcpy(b, &h, sizeof h);
    {
        unsigned char *w = b + sizeof h;
        if (locs_sz) { memcpy(w, p->locs, locs_sz); w += locs_sz; }
        if (vs_sz) { memcpy(w, p->vsin, vs_sz); w += vs_sz; }
        memcpy(w, p->lib, (size_t)p->lib_len); w += p->lib_len;
        if (h.lib2_len) memcpy(w, p->lib2, (size_t)h.lib2_len);
    }
    *len_out = len;
    return b;
}

/* 1 if the blob is a complete, self-consistent entry for exactly this key. */
static inline int mad_dxc_blob_valid(const void *blob, size_t len, uint64_t key, uint64_t check)
{
    struct mad_dxc_header h;
    uint64_t want;
    if (!blob || len < sizeof h) return 0;
    memcpy(&h, blob, sizeof h);
    if (h.magic != MAD_DXC_MAGIC || h.version != MAD_DXC_VERSION) return 0;
    if (h.key != key || h.check != check) return 0;
    if (!h.lib_len || h.lib_len > MAD_DXC_MAX_FILE || h.lib2_len > MAD_DXC_MAX_FILE) return 0;
    if (h.nlocs > 65536 || h.nvsin > 65536) return 0;
    if (!h.entry[0] || !memchr(h.entry, 0, sizeof h.entry) || !memchr(h.note, 0, sizeof h.note)) return 0;
    want = sizeof h + (uint64_t)h.nlocs * sizeof(struct madeira_ir_loc)
         + (uint64_t)h.nvsin * sizeof(struct madeira_ir_vs_input) + h.lib_len + h.lib2_len;
    return want == (uint64_t)len;
}

/* Hands a validated entry to the caller exactly as a fresh conversion would:
 * the same ret_* fields, the same caps, the same size-then-fill contract.
 * Returns the status it stored in a->ret_status. */
static inline int mad_dxc_deliver(const void *blob, struct madeira_ir_convert_args *a)
{
    struct mad_dxc_header h;
    const unsigned char *r = (const unsigned char *)blob;
    const struct madeira_ir_loc *locs;
    const struct madeira_ir_vs_input *vsin;
    const unsigned char *lib, *lib2;

    memcpy(&h, blob, sizeof h);
    locs = (const struct madeira_ir_loc *)(r + sizeof h);
    vsin = (const struct madeira_ir_vs_input *)(r + sizeof h + (size_t)h.nlocs * sizeof *locs);
    lib = (const unsigned char *)(vsin + h.nvsin);
    lib2 = lib + h.lib_len;

    a->ret_error_code = 0;
    a->ret_stage = h.stage;
    a->ret_len = h.lib_len;
    if (!a->out_buf || a->out_cap < h.lib_len) {
        a->ret_status = MADEIRA_IR_BUFFER_TOO_SMALL;
        return MADEIRA_IR_BUFFER_TOO_SMALL;
    }
    memcpy((void *)(uintptr_t)a->out_buf, lib, (size_t)h.lib_len);
    if (a->out_entry) snprintf((char *)(uintptr_t)a->out_entry, MADEIRA_IR_ENTRY_MAX, "%s", h.entry);
    if (h.note[0]) snprintf(a->ret_note, sizeof a->ret_note, "%s", h.note);

    a->ret_loc_count = 0;
    if (a->out_locs) {
        struct madeira_ir_loc *out = (struct madeira_ir_loc *)(uintptr_t)a->out_locs;
        a->ret_loc_count = h.nlocs;
        for (uint32_t i = 0; i < h.nlocs && i < a->loc_cap; i++) out[i] = locs[i];
    }
    a->ret_vs_input_count = h.vs_input_count;
    if (a->out_vs_inputs) {
        struct madeira_ir_vs_input *out = (struct madeira_ir_vs_input *)(uintptr_t)a->out_vs_inputs;
        for (uint32_t i = 0; i < h.nvsin && i < a->vs_input_cap; i++) out[i] = vsin[i];
    }
    a->ret_tg_size[0] = h.tg[0]; a->ret_tg_size[1] = h.tg[1]; a->ret_tg_size[2] = h.tg[2];
    a->ret_vs_output_size = h.vs_output_size;
    a->ret_gs_max_prims = h.gs_max_prims;
    a->ret_gs_payload = h.gs_payload;
    a->ret_gs_passthrough = h.gs_passthrough;
    a->ret_hs_patches_per_tg = h.hs[0]; a->ret_hs_threads_per_patch = h.hs[1];
    a->ret_hs_input_cps = h.hs[2]; a->ret_hs_output_cps = h.hs[3];
    a->ret_hs_output_cp_size = h.hs[4]; a->ret_hs_patch_const_size = h.hs[5];
    a->ret_hs_out_prim = h.hs[6]; a->ret_hs_max_factor_bits = h.hs[7];
    a->ret_ds_prims_per_mesh_tg = h.ds[0]; a->ret_ds_input_cps = h.ds[1];
    a->ret_ds_input_cp_size = h.ds[2]; a->ret_ds_patch_const_size = h.ds[3];
    a->ret_len2 = h.lib2_len;
    if (h.lib2_len) {
        if (a->out_buf2 && a->out_cap2 >= h.lib2_len)
            memcpy((void *)(uintptr_t)a->out_buf2, lib2, (size_t)h.lib2_len);
        else
            snprintf(a->ret_note, sizeof a->ret_note, "stage-in metallib needs %llu bytes",
                     (unsigned long long)h.lib2_len);
    }
    if (!a->out_entry || !*(const char *)(uintptr_t)a->out_entry) {
        a->ret_status = MADEIRA_IR_EMPTY_ENTRY;
        return MADEIRA_IR_EMPTY_ENTRY;
    }
    a->ret_status = MADEIRA_IR_OK;
    return MADEIRA_IR_OK;
}

/* ---- disk ---------------------------------------------------------------- */

/* Reads a whole entry; the caller frees *blob. Bumps the file's mtime on a hit
 * so the size bound evicts the least recently USED entries, not the oldest. */
static inline int mad_dxc_file_load(const char *path, uint64_t key, uint64_t check,
                                    void **blob, size_t *len)
{
    struct stat st;
    void *b;
    int fd = open(path, O_RDONLY);
    *blob = NULL; *len = 0;
    if (fd < 0) return 0;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(struct mad_dxc_header) ||
        st.st_size > (off_t)MAD_DXC_MAX_FILE) { close(fd); return 0; }
    b = malloc((size_t)st.st_size);
    if (!b) { close(fd); return 0; }
    if (read(fd, b, (size_t)st.st_size) != (ssize_t)st.st_size ||
        !mad_dxc_blob_valid(b, (size_t)st.st_size, key, check)) { close(fd); free(b); return 0; }
    close(fd);
    utimes(path, NULL);
    *blob = b; *len = (size_t)st.st_size;
    return 1;
}

/* Write-then-rename, as the DXBC cache does: a crash mid-write can never leave
 * a torn entry that a later run would trust. */
static inline int mad_dxc_file_store(const char *path, const void *blob, size_t len)
{
    char tmp[1300];
    int fd, ok;
    if (snprintf(tmp, sizeof tmp, "%s.tmp%u", path, (unsigned)getpid()) >= (int)sizeof tmp) return 0;
    fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return 0;
    ok = write(fd, blob, len) == (ssize_t)len;
    close(fd);
    if (ok && rename(tmp, path) == 0) return 1;
    unlink(tmp);
    return 0;
}

/* Size bound: when the entries with this extension exceed `cap` bytes, delete
 * the least recently used until they fit in `target`. Only files named
 * "<16 hex>.<ext>" are considered; nothing else in the directory is touched.
 * Returns the bytes left; *nfiles_out gets the count left. */
struct mad_dxc_prune_ent { time_t mtime; uint64_t size; char name[32]; };

static inline int mad_dxc_prune_cmp(const void *x, const void *y)
{
    const struct mad_dxc_prune_ent *a = (const struct mad_dxc_prune_ent *)x;
    const struct mad_dxc_prune_ent *b = (const struct mad_dxc_prune_ent *)y;
    if (a->mtime != b->mtime) return a->mtime < b->mtime ? -1 : 1;
    return strcmp(a->name, b->name);
}

static inline uint64_t mad_dxc_prune(const char *dir, const char *ext, uint64_t cap, uint64_t target,
                                     unsigned *nfiles_out, unsigned *removed_out)
{
    DIR *d = opendir(dir);
    struct dirent *de;
    struct mad_dxc_prune_ent *v = NULL;
    size_t n = 0, capn = 0, extlen = strlen(ext);
    uint64_t total = 0;
    unsigned removed = 0;
    char path[1300];

    if (nfiles_out) *nfiles_out = 0;
    if (removed_out) *removed_out = 0;
    if (!d) return 0;
    while ((de = readdir(d)) != NULL) {
        size_t nl = strlen(de->d_name);
        struct stat st;
        if (nl != 16 + 1 + extlen || nl >= sizeof v->name ||
            de->d_name[16] != '.' || strcmp(de->d_name + 17, ext)) continue;
        if (strspn(de->d_name, "0123456789abcdef") != 16) continue;
        if (snprintf(path, sizeof path, "%s/%s", dir, de->d_name) >= (int)sizeof path) continue;
        if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) continue;
        if (n == capn) {
            size_t nc = capn ? capn * 2 : 256;
            struct mad_dxc_prune_ent *nv = (struct mad_dxc_prune_ent *)realloc(v, nc * sizeof *v);
            if (!nv) break;
            v = nv; capn = nc;
        }
        v[n].mtime = st.st_mtime; v[n].size = (uint64_t)st.st_size;
        memcpy(v[n].name, de->d_name, nl + 1);   /* nl < sizeof name, checked above */
        total += (uint64_t)st.st_size;
        n++;
    }
    closedir(d);
    if (total > cap && n) {
        qsort(v, n, sizeof *v, mad_dxc_prune_cmp);
        for (size_t i = 0; i < n && total > target; i++) {
            if (snprintf(path, sizeof path, "%s/%s", dir, v[i].name) >= (int)sizeof path) continue;
            if (unlink(path) == 0) { total -= v[i].size; removed++; }
        }
    }
    free(v);
    if (nfiles_out) *nfiles_out = (unsigned)(n - removed);
    if (removed_out) *removed_out = removed;
    return total;
}

#endif /* MADEIRA_DXIL_CACHE_H */
