#!/usr/bin/env python3
"""pso-lazy-libs: a lazy pipeline lets its Metal libraries go until its first use.

Horizon Zero Dawn (build 480, 2026-10-09 20:28) created 52,570 pipelines in its
menu and drew ~1,500 of them in its first gameplay seconds; every one kept its
converted libraries, and the shared-library table one more reference to each
(23,045 libraries, 432 MB of metallib), until iOS killed the game at 8,189 MB.
With the opt-in switch a lazy pipeline (plain vertex/pixel or compute) lets
its libraries go once it is created, and its first draw or dispatch reads them
back from the shader cache by key.

Checks on madeira_d3d12.c: off by default; the conversion returns its cache key
and keeps a new library out of the shared table only when asked; the drop
comes after the pso-warm request and only for a lazy plain pipeline that is
not built yet; both lazy builds read the libraries back before building; the
DXBC draw path tells a pixel stage by a flag set at creation. Then the helpers
are cut out and run against stubs: what is dropped is released, a read-back
stage shares an identical library through the table, a missing or mismatched
cache entry fails without leaking a reference, and names that may have been
cut short are never dropped.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
pe = (root / 'madeira-d3d12/src/pe/madeira_d3d12.c').read_text()
catalog = (root / 'app/Madeira/ConfigCatalog.generated.swift').read_text()
ok = True


def check(what, cond):
    global ok
    print(('ok   ' if cond else 'FAIL ') + what)
    ok &= bool(cond)


def body(sig):
    start = pe.index(sig)
    while pe.index(';', start) < pe.index('{', start):   # a prototype: the definition comes later
        start = pe.index(sig, start + 1)
    brace = pe.index('{', start)
    depth = 0
    for i in range(brace, len(pe)):
        if pe[i] == '{':
            depth += 1
        elif pe[i] == '}':
            depth -= 1
            if depth == 0:
                return pe[start:i + 1]
    raise AssertionError('unterminated: ' + sig)


# --- the wiring --------------------------------------------------------------
check('off by default: mad_cfg_int_pe("pso-lazy-libs", 0)', 'mad_cfg_int_pe("pso-lazy-libs", 0)' in pe)
conv = body('static obj_handle_t mad_convert_stage_opts(struct mad_device *d, struct mad_rootsig *rs,')
check('a new library stays out of the shared table only when the caller asks',
      'if (!(o && o->lz)) mad_libshare_add(share_k0, share_k1, lib, fn);' in conv and conv.count('mad_libshare_add(') == 1)
key_at = conv.find('if (o && o->lz) {')
check('the key is taken after a successful conversion, before the sized ranges are freed',
      0 < key_at < conv.index('free(sized_ranges);   /* the conversion is done') and
      'mad_sc_key(&a, o->lz->key); o->lz->ok = mad_sc_exists(o->lz->key);' in conv)
real = body('static obj_handle_t mad_pso_realize(struct mad_pso *p)')
check('the first draw reads the libraries back before building',
      real.index('if (!p->lz || mad_lzlib_restore(p))') < real.index('MTLDevice_newRenderPipelineStateVD(p->device_handle, &p->rp, &p->vd, &err)'))
# cs-create-build: the build is mad_cpso_build (a first dispatch or a builder); mad_cpso_realize is its dispatch entry
creal = body('static obj_handle_t mad_cpso_build(struct mad_pso *p, int bg)')
check('a first dispatch goes through the same build',
      'static obj_handle_t mad_cpso_realize(struct mad_pso *p) { return mad_cpso_build(p, 0); }' in pe)
check('the first dispatch too, and only then takes the function',
      creal.index('if (!p->lz || mad_lzlib_restore(p))') < creal.index('ci.compute_function = p->vs_fn;'))
gfx = body('static HRESULT device_CreateGraphicsPipelineState_impl(ID3D12Device *This,')
check('graphics: only a plain pipeline that is built at its first draw',
      'lz_on = mad_lzlib_on() && mad_pso_lazy_on() && !desc->GS.pShaderBytecode && !desc->HS.pShaderBytecode &&\n'
      '            !desc->DS.pShaderBytecode;' in gfx)
# pso-create-build / cs-create-build: a pipeline queued for the builders at creation keeps its libraries (the build reads them)
drop = 'if (!queued && lz_on && p->lazy && !p->rps && mad_lzlib_can_drop(p, &lzv, &lzp)) mad_lzlib_drop(p, &lzv, &lzp);'
check('graphics: dropped after the pso-warm request (where pso-warm is built in), before the pipeline is handed out',
      ('mad_pso_warm(' not in gfx or gfx.index('mad_pso_warm(p->device_handle, &p->rp') < gfx.index(drop))
      and gfx.index(drop) < gfx.rindex('hr = pso_QI('))
check('graphics: both stages are converted with the key request',
      'if (lz_on) ov2.lz = &lzv;' in gfx and 'if (lz_on) op.lz = &lzp;' in gfx)
cs = body('static HRESULT device_CreateComputePipelineState_impl(ID3D12Device *This,')
cdrop = 'if (!queued && lz_on && mad_lzlib_can_drop(p, &lzc, NULL)) mad_lzlib_drop(p, &lzc, NULL);'
check('compute: dropped after the pso-warm request of a lazy pipeline (where pso-warm is built in)',
      'if (lz_on) o.lz = &lzc;' in cs and
      ('mad_pso_warm(' not in cs or cs.index('mad_pso_warm(p->device_handle, &ci, NULL, 2);') < cs.index(cdrop)) and
      cs.index(cdrop) < cs.index('p->cps = MTLDevice_newComputePipelineState(d->mtl_device, &ci, &err);'))
check('the DXBC draw path knows a dropped pixel stage by lz_has_ps',
      '(e->pso->ps_fn || e->pso->lz_has_ps) &&' in pe)
check('pso_Release still releases only what is there',
      'if (p->vs_fn) NSObject_release(p->vs_fn);' in body('static ULONG STDMETHODCALLTYPE pso_Release(ID3D12PipelineState *T)'))
check('in the settings catalog, off by default',
      'key: "pso-lazy-libs"' in catalog and 'defaultValue: "0"' in catalog[catalog.index('key: "pso-lazy-libs"'):][:300])

# --- the helpers, against stubs ------------------------------------------------
share = pe[pe.index('struct mad_libshare { UINT64 k0, k1; obj_handle_t lib, fn; };'):pe.index('/* madeira-bcd pso-lazy-libs (madeira.cfg or the game')]
if '/* madeira-bcd rsig-miss: the converter' in share:   # the rsig-miss helpers may sit between the libshare helpers
    rs0 = share.index('/* madeira-bcd rsig-miss: the converter')
    share = share[:rs0] + share[share.index('static int mad_libshare_find(', rs0):]
lz0 = pe.index('static int mad_lzlib_on(void) {')
lz = pe[lz0:pe.index('\n}\n', pe.index('static int mad_lzlib_restore(struct mad_pso *p) {', lz0)) + 3]
hdr = pe[pe.index('#define MAD_SC_MAGIC'):pe.index('static int g_sc_on = -1;')]

harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include "madeira_ir_abi.h"
typedef uint64_t UINT64; typedef uint32_t UINT32; typedef unsigned UINT; typedef long LONG; typedef long long LONG64;
typedef size_t SIZE_T; typedef uint64_t obj_handle_t;
typedef struct { int x; } SRWLOCK;
#define SRWLOCK_INIT { 0 }
static void AcquireSRWLockShared(SRWLOCK *l) { (void)l; }
static void ReleaseSRWLockShared(SRWLOCK *l) { (void)l; }
static void AcquireSRWLockExclusive(SRWLOCK *l) { (void)l; }
static void ReleaseSRWLockExclusive(SRWLOCK *l) { (void)l; }
static LONG InterlockedIncrement(volatile LONG *p) { return ++*p; }
static LONG64 InterlockedExchangeAdd64(volatile LONG64 *p, LONG64 v) { LONG64 o = *p; *p += v; return o; }
static void MemoryBarrier(void) { }
static int logs;
static void d3d12_log(const char *fmt, ...) { (void)fmt; logs++; }
static long long cfg_lz;
static long long mad_cfg_int_pe(const char *k, long long d) { return !strcmp(k, "pso-lazy-libs") ? cfg_lz : d; }

/* objects: libraries keep the bytes they were made from, functions their name */
#define NOBJ 256
static struct { int refs, kind; char data[512]; size_t len; obj_handle_t lib; } objs[NOBJ];
static int nobj, libs_made;
static obj_handle_t new_obj(int kind) { objs[nobj].refs = 1; objs[nobj].kind = kind; return (obj_handle_t)++nobj; }
static void NSObject_retain(obj_handle_t h) { objs[h - 1].refs++; }
static void NSObject_release(obj_handle_t h) { if (objs[h - 1].refs <= 0) { printf("FAIL over-release %llu\n", (unsigned long long)h); exit(1); } objs[h - 1].refs--; }
static int refs(obj_handle_t h) { return h ? objs[h - 1].refs : -1; }
static obj_handle_t DispatchData_alloc_init(uint64_t ptr, uint64_t len) {
    obj_handle_t h = new_obj(1); memcpy(objs[h - 1].data, (const void *)(uintptr_t)ptr, len); objs[h - 1].len = len; return h;
}
static obj_handle_t MTLDevice_newLibrary(obj_handle_t dev, obj_handle_t dd, obj_handle_t *err) {
    obj_handle_t h; (void)dev; (void)err;
    if (objs[dd - 1].len < 4 || memcmp(objs[dd - 1].data, "LIB:", 4)) return 0;
    h = new_obj(2); memcpy(objs[h - 1].data, objs[dd - 1].data, objs[dd - 1].len); objs[h - 1].len = objs[dd - 1].len;
    libs_made++;
    return h;
}
static obj_handle_t MTLLibrary_newFunction(obj_handle_t lib, const char *name) {
    obj_handle_t h; size_t n = strlen(name);
    if (objs[lib - 1].len < 4 + n + 1 || memcmp(objs[lib - 1].data + 4, name, n) || objs[lib - 1].data[4 + n] != ':') return 0;
    h = new_obj(3); objs[h - 1].lib = lib; return h;
}
static void mad_log_nserror(const char *what, obj_handle_t err) { (void)what; (void)err; }
static volatile LONG64 g_lib_bytes; static volatile LONG g_lib_count;
static int g_lzlib = -1;
static volatile LONG g_lzlib_dropped, g_lzlib_kept, g_lzlib_restored, g_lzlib_failed;
''' + hdr + r'''
/* the shader cache: a few files by key */
static struct { UINT64 key[2]; unsigned char *blob; size_t size; } files[8]; static int nfiles;
static void put_file(UINT64 k0, UINT64 k1, UINT64 hk0, const char *metallib) {
    struct mad_sc_hdr h; size_t n = strlen(metallib);
    memset(&h, 0, sizeof h);
    h.magic = MAD_SC_MAGIC; h.hdr_size = sizeof h; h.key[0] = hk0; h.key[1] = k1; h.ret_status = MADEIRA_IR_OK; h.ret_len = n;
    files[nfiles].key[0] = k0; files[nfiles].key[1] = k1;
    files[nfiles].blob = malloc(sizeof h + n + 16); files[nfiles].size = sizeof h + n + 16;
    memcpy(files[nfiles].blob, &h, sizeof h); memcpy(files[nfiles].blob + sizeof h, metallib, n);
    memset(files[nfiles].blob + sizeof h + n, 0, 16);   /* entry name and reflection follow in a real file */
    nfiles++;
}
static int mad_sc_read_file(const UINT64 key[2], unsigned char **blob_out, SIZE_T *size_out) {
    int i;
    for (i = 0; i < nfiles; i++)
        if (files[i].key[0] == key[0] && files[i].key[1] == key[1]) {
            *blob_out = malloc(files[i].size); memcpy(*blob_out, files[i].blob, files[i].size); *size_out = files[i].size; return 1;
        }
    return 0;
}
struct WMTRenderPipelineInfo { obj_handle_t vertex_function, fragment_function; };
struct mad_pso {
    obj_handle_t vs_lib, ps_lib, vs_fn, ps_fn, device_handle;
    struct WMTRenderPipelineInfo rp;
    int lz, lz_has_ps, is_compute; UINT64 lz_vs_key[2], lz_ps_key[2];
    char vs_name[64], ps_name[64];
};
struct mad_lzkey { UINT64 key[2]; int ok; };
''' + share + lz + r'''
static int bad;
#define EXPECT(c, what) do { if (!(c)) { printf("FAIL %s\n", what); bad = 1; } else printf("ok   %s\n", what); } while (0)
static void stage(struct mad_pso *p, int ps) {
    memset(p, 0, sizeof *p);
    p->device_handle = 99;
    p->vs_lib = new_obj(2); p->vs_fn = new_obj(3); strcpy(p->vs_name, "VSMain");
    if (ps) { p->ps_lib = new_obj(2); p->ps_fn = new_obj(3); strcpy(p->ps_name, "PSMain"); }
    p->rp.vertex_function = p->vs_fn; p->rp.fragment_function = p->ps_fn;
}
int main(void) {
    struct mad_pso a, b, c, d, e, cs;
    struct mad_lzkey kv = { { 0x10, 0x11 }, 1 }, kp = { { 0x20, 0x21 }, 1 }, bad_kp = { { 0x20, 0x21 }, 0 };
    struct mad_lzkey miss = { { 0x30, 0x31 }, 1 }, wrong = { { 0x40, 0x41 }, 1 }, kc = { { 0x50, 0x51 }, 1 };
    obj_handle_t vl, vf, pl, pf;
    int made;

    EXPECT(!mad_lzlib_on(), "off unless pso-lazy-libs = 1");
    g_lzlib = -1; cfg_lz = 1;
    EXPECT(mad_lzlib_on(), "on with pso-lazy-libs = 1");

    put_file(0x10, 0x11, 0x10, "LIB:VSMain:vertex bytes");
    put_file(0x20, 0x21, 0x20, "LIB:PSMain:pixel bytes");
    put_file(0x40, 0x41, 0x4f, "LIB:VSMain:a file written under another key");
    put_file(0x50, 0x51, 0x50, "LIB:CSMain:compute bytes");

    stage(&a, 1);
    EXPECT(!mad_lzlib_can_drop(&a, &kv, &bad_kp) && g_lzlib_kept == 1, "a stage without its cache file keeps the libraries");
    strcpy(a.ps_name, "a_pixel_shader_name_that_fills_the_whole_sixty_four_byte_field_");
    EXPECT(!mad_lzlib_can_drop(&a, &kv, &kp), "a name that may have been cut short keeps them");
    strcpy(a.ps_name, "PSMain");
    EXPECT(mad_lzlib_can_drop(&a, &kv, &kp), "both stages in the cache: dropped");
    vl = a.vs_lib; vf = a.vs_fn; pl = a.ps_lib; pf = a.ps_fn;
    mad_lzlib_drop(&a, &kv, &kp);
    EXPECT(refs(vl) == 0 && refs(vf) == 0 && refs(pl) == 0 && refs(pf) == 0, "the dropped libraries and functions are released");
    EXPECT(a.lz == 1 && a.lz_has_ps == 1 && !a.vs_fn && !a.ps_fn && !a.vs_lib && !a.ps_lib &&
           !a.rp.vertex_function && !a.rp.fragment_function, "the pipeline keeps no stage until its first draw");
    EXPECT(a.lz_vs_key[0] == 0x10 && a.lz_vs_key[1] == 0x11 && a.lz_ps_key[0] == 0x20 && a.lz_ps_key[1] == 0x21, "it keeps the keys");

    made = libs_made;
    EXPECT(mad_lzlib_restore(&a), "the first draw reads both stages back");
    EXPECT(libs_made == made + 2 && a.lz == 0 && a.vs_fn && a.ps_fn && a.rp.vertex_function == a.vs_fn &&
           a.rp.fragment_function == a.ps_fn, "two libraries are made and the descriptor names their functions");
    EXPECT(refs(a.vs_lib) == 2 && refs(a.vs_fn) == 2 && refs(a.ps_lib) == 2 && refs(a.ps_fn) == 2,
           "each held by the pipeline and by the shared table");
    EXPECT(g_lib_count == 2, "counted as created libraries");

    stage(&b, 1);
    mad_lzlib_drop(&b, &kv, &kp);
    made = libs_made;
    EXPECT(mad_lzlib_restore(&b) && libs_made == made && b.vs_lib == a.vs_lib && b.ps_fn == a.ps_fn && refs(a.vs_lib) == 3,
           "an identical stage of another pipeline shares the built one");

    stage(&c, 1);
    mad_lzlib_drop(&c, &miss, &kp);
    made = libs_made;
    EXPECT(!mad_lzlib_restore(&c) && !c.vs_fn && !c.ps_fn && c.lz == 1 && g_lzlib_failed == 1, "a vertex stage gone from the cache fails");

    stage(&d, 1);
    strcpy(d.vs_name, "CSMain");   /* its vertex stage is in the cache, its pixel stage is not */
    mad_lzlib_drop(&d, &kc, &miss);
    EXPECT(!mad_lzlib_restore(&d) && !d.vs_fn && !d.vs_lib, "a pixel stage gone from the cache fails the pipeline");
    {   /* the vertex stage it read was released again; the table keeps its own reference */
        int i, held = 0;
        for (i = 0; i < nobj; i++) if (objs[i].kind == 2 && objs[i].len && !memcmp(objs[i].data, "LIB:CSMain", 10)) held = objs[i].refs;
        EXPECT(held == 1, "no reference leaks from the half-read pipeline");
    }

    stage(&e, 0);
    EXPECT(mad_lzlib_can_drop(&e, &wrong, NULL), "a vertex-only pipeline can drop");
    mad_lzlib_drop(&e, &wrong, NULL);
    EXPECT(e.lz_has_ps == 0 && !mad_lzlib_restore(&e), "a file whose header names another key is not used");

    stage(&cs, 0);
    cs.is_compute = 1; strcpy(cs.vs_name, "CSMain"); cs.rp.vertex_function = 0;
    mad_lzlib_drop(&cs, &kc, NULL);
    EXPECT(mad_lzlib_restore(&cs) && cs.vs_fn && !cs.ps_fn && !cs.rp.vertex_function, "a compute stage comes back without a render descriptor");
    EXPECT(g_lzlib_dropped == 6 && g_lzlib_restored == 3, "dropped and read-back pipelines are counted");

    printf("%s\n", bad ? "harness FAILED" : "harness ok");
    return bad;
}
'''

cc = shutil.which('cc') or shutil.which('gcc') or shutil.which('clang')
if not cc:
    check('a host C compiler', False)
else:
    with tempfile.TemporaryDirectory(prefix='madeira-lzlib-') as tmp:
        src = Path(tmp) / 'lzlib.c'
        exe = Path(tmp) / 'lzlib'
        src.write_text(harness)
        build = subprocess.run([cc, '-std=gnu11', '-Wall', '-Wno-unused-function', '-I', str(root / 'madeira-d3d12/src'),
                                str(src), '-o', str(exe)], capture_output=True, text=True)
        check('the helpers compile on the host', build.returncode == 0)
        if build.returncode:
            print(build.stderr[-3000:])
        else:
            run = subprocess.run([str(exe)], capture_output=True, text=True)
            print(run.stdout, end='')
            check('the helpers behave', run.returncode == 0)

if not ok:
    sys.exit(1)
print('PASS: pso-lazy-libs')
