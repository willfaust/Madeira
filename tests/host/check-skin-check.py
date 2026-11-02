#!/usr/bin/env python3
"""skin-check and view-census: opt-in diagnostics for compute-skinned meshes.

Horizon Zero Dawn (builds 480 and 481) skins characters in compute and draws
them from buffers created with ALLOW_UNORDERED_ACCESS; every few frames a face,
hair or a whole body comes out collapsed to the origin, and gpu-sync = 1 did not
change it. skin-check logs, in windows of check frames, the draws that read such
buffers, the dispatches that wrote them (every DXBC range and what it resolved
to), 32 KB GPU-ordered copies of those streams summarised after the queue's
fence wait, and the shaders' bytecode. view-census names typed-buffer views
that fall back to plain descriptors or are cut short, and views past their
resource, without changing how any view is made.

Checks: both off by default and every hook guarded by them; captures force the
synchronous Signal path and are printed only by the queue that recorded them;
the typed-view reason codes leave the old results untouched; settings catalog
entries; Horizon Zero Dawn's list turns both on. The line helper, the capture
summary, the per-queue flush and the typed-view reasons are compiled and run
against stubs.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
pe = (root / 'madeira-d3d12/src/pe/madeira_d3d12.c').read_text()
catalog = (root / 'app/Madeira/ConfigCatalog.generated.swift').read_text()
recs = (root / 'app/Madeira/GameRecommendations.swift').read_text()
ok = True


def check(what, cond):
    global ok
    print(('ok   ' if cond else 'FAIL ') + what)
    ok &= bool(cond)


def body(sig):
    """A function's text, braces matched outside strings, characters and comments."""
    start = pe.index(sig)
    while pe.index(';', start) < pe.index('{', start):
        start = pe.index(sig, start + 1)
    i, depth, quote = pe.index('{', start), 0, None
    while i < len(pe):
        ch = pe[i]
        if quote:
            if ch == '\\':
                i += 2
                continue
            if ch == quote:
                quote = None
        elif pe.startswith('/*', i):
            i = pe.index('*/', i) + 2
            continue
        elif pe.startswith('//', i):
            i = pe.index('\n', i)
            continue
        elif ch in '"\'':
            quote = ch
        elif ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return pe[start:i + 1]
        i += 1
    raise AssertionError('unterminated: ' + sig)


check('skin-check off by default', 'mad_cfg_int_pe("skin-check", 0)' in pe)
check('skin-check-every defaults to 300 presents, at least 30', 'mad_cfg_int_pe("skin-check-every", 300)' in pe and
      'g_skin_every = ev < 30 ? 30 : ev;' in pe)
check('skin-check-capture defaults to on (copies), 0 logs only', 'mad_cfg_int_pe("skin-check-capture", 1)' in pe)
check('view-census off by default', 'mad_cfg_int_pe("view-census", 0)' in pe)

draw = body('static void exec_draw(struct mad_exec *e, const struct mad_cmd *c)')
check('draw: the hook runs only with the switch on, before the render pass begins',
      'if (g_skin_check > 0) mad_skin_draw(e, c);' in draw and
      draw.index('if (g_skin_check > 0) mad_skin_draw(e, c);') < draw.index('if (!exec_begin_render(e)) { MAD_SKIP(e); return; }'))
check('draw: the vertex-stage ranges are logged only for a logged draw, and tab_on is cleared on every path',
      'e->sk->tab_on = e->sk->draw_gpu == 2;' in draw and '{ if (e->sk) e->sk->tab_on = 0; MAD_SKIP(e); return; }' in draw and
      'if (e->sk && e->sk->tab_on) { e->sk->tab_on = 0; mad_skin_vs_line(e); }' in draw)
disp = body('static void exec_dispatch(struct mad_exec *e, const struct mad_cmd *c)')
check('dispatch: tables built with tab_on, cleared whether or not they built',
      disp.count('e->sk->tab_on = e->sk->tab_cs = 0;') == 2 and 'if (e->sk) e->sk->tab_on = e->sk->tab_cs = 1;' in disp)
check('dispatch: logged after it was encoded, last',
      disp.rstrip().endswith('if (e->sk) mad_skin_dispatch(e, c);   /* madeira-bcd skin-check */\n}'))
ex = body('static void mad_exec_list(struct mad_queue *q, struct mad_list *l, obj_handle_t cb)')
check('replay state only in check frames, freed at the end of the list (before ring-share parks its chunks)',
      'if (g_skin_now) mad_skin_begin(&e);' in ex and
      'if (e.sk) mad_skin_end(&e);   /* madeira-bcd skin-check */\n    if (l->nrings && q->device->gpu_event && mad_ring_share_on()) mad_ring_park(q, l);\n}' in ex)
bt = body('static int mad_air_build_tables_ex_body(struct mad_exec *e, const struct mad_rootsig *rs, const UINT64 *root,')
check('bridge: each resolved range is named only while tab_on is set, before it is encoded',
      'if (e->sk && e->sk->tab_on) mad_skin_tok(e, rg, &de, direct);' in bt and
      bt.index('mad_skin_tok(e, rg, &de, direct)') < bt.index('if (rg->type == MADEIRA_IR_AIR_CBV) {'))
sa = body('static int mad_signal_async(struct mad_queue *q, ID3D12Fence *fence, UINT64 value)')
check('pending captures force the synchronous Signal (its fence wait completes them)',
      'if (!d->gpu_event || d->ncap || g_sk_n) return 0;' in sa)
sr = body('static HRESULT mad_signal_run(struct mad_queue *q, ID3D12Fence *fence, UINT64 value)')
check('the signalling queue prints its own captures after the wait',
      sr.index('mad_cb_retire(q->device, q->pending[i])') < sr.index('if (g_sk_n) mad_skin_flush(q);') < sr.index('return ID3D12Fence_Signal(fence, value);'))
check('dispatch, converter (DXIL) path: the root signature as bound is named after its argument slot',
      disp.index('e->cpso->has_root_off ? e->cpso->root_off : NULL, e->cpso)) { MAD_SKIP(e); return; }') <
      disp.index('mad_skin_rs_tok(e, e->crs, e->croot, (const UINT32 (*)[64])e->cconsts, ~0u);'))
sdr = body('static void mad_skin_draw(struct mad_exec *e, const struct mad_cmd *c)')
check('draw, converter (DXIL) path: the vertex stage\'s parameters from the root signature',
      'if (s->draw_gpu == 2 && p->backend != MADEIRA_IR_BACKEND_AIRCONV) {' in sdr and
      '(1u << MADEIRA_IR_VIS_ALL) | (1u << MADEIRA_IR_VIS_VERTEX) | (1u << MADEIRA_IR_VIS_GEOMETRY));' in sdr)
cs = body('static HRESULT device_CreateComputePipelineState_impl(ID3D12Device *This,')
check('compute bytecode kept by its fault-report hash, only with the switch',
      'if (mad_skin_on()) mad_bc_keep(hh, b, p->cs_len);' in cs)
gp = body('static HRESULT device_CreateGraphicsPipelineState_impl(ID3D12Device *This,')
check('vertex bytecode hashed and kept only with the switch',
      'if (mad_skin_on()) {   /* madeira-bcd skin-check' in gp and
      'p->vs_hash = mad_fnv64(desc->VS.pShaderBytecode, desc->VS.BytecodeLength);' in gp)
check('Present drives the windows', 'if (mad_skin_on()) mad_skin_present(s->presents);' in pe)
sd = body('static void mad_skin_draw(struct mad_exec *e, const struct mad_cmd *c)')
check('a GPU-written stream is a bound buffer with ALLOW_UNORDERED_ACCESS that the pipeline fetches',
      '((mask >> sl) & 1) && r && r->buffer && (r->desc.Flags & D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS)' in sd)
check('outside check frames the draw hook only notes the first such draw',
      sd.index('if (!s) return;') < sd.index('s->ndraw++;') and 'InterlockedExchange(&g_skin_seen, 1)' in sd)
check('log budgets per window and in all, reset when a window starts',
      'InterlockedExchange(&g_skin_win_lines, 0); InterlockedExchange(&g_skin_win_caps, 0);' in pe and
      'g_skin_win_lines) <= MAD_SKIN_WIN_LINES && InterlockedIncrement(&g_skin_lines) <= MAD_SKIN_LINE_BUDGET' in pe)
check('per-frame limits: 64 draws, 96 copies of at most 32 KB',
      'if (nd > 64)' in sd and 'InterlockedIncrement(&g_skin_caps_frame) > 96' in sd and 'if (len > 32768) len = 32768;' in sd)
check('the writer of a stream is looked up among this frame\'s dispatches only',
      'w->frame == g_skin_frame && w->r == r && w->off <= e->vb[sl].off' in sd)
cap = body('static int mad_skin_capture(struct mad_exec *e, const char *label, struct mad_resource *r, UINT64 off, UINT len, UINT kind, UINT stride, UINT dump)')
check('copies stay inside the resource and the capture buffer (4 MB, 24 with skin-dump), and remember their queue',
      'if (off + len > r->size) len = (UINT)(r->size - off) & ~3u;' in cap and 'g_sk_used + len <= g_sk_bytes' in cap and
      'c->q = e->q;' in cap and 'g_sk_n < MAD_SK_N' in cap and 'bi.length = g_sk_bytes;' in cap and
      'static UINT g_sk_bytes = MAD_SK_BYTES;' in pe and 'if (g_skin_dump) g_sk_bytes = 24u << 20;' in pe)
check('485: a copy of CPU-written memory keeps the CPU\'s bytes at replay and holds its resource until printed',
      'r->cpu && (r->heap == D3D12_HEAP_TYPE_UPLOAD || r->heap == D3D12_HEAP_TYPE_CUSTOM) && (c->snap = malloc(len))' in cap and
      'c->src = r; ID3D12Resource_AddRef((ID3D12Resource *)r);' in cap)
tbv = body('static int mad_typed_buffer_view(struct mad_device *d, struct mad_resource *r, DXGI_FORMAT fmt,')
check('typed views: every refusal names its reason, the cut-short view is still made',
      all(('*why = %d' % k) in tbv for k in (1, 2, 3, 4, 5, 7, 8, 9)) and '*why = width ? 6 : 5;' in tbv)
srv = body('static void STDMETHODCALLTYPE device_CreateShaderResourceView(ID3D12Device *This,')
uav = body('static void STDMETHODCALLTYPE device_CreateUnorderedAccessView(ID3D12Device *This,')
for name, f, u in (('SRV', srv, '0'), ('UAV', uav, '1')):
    check(name + ': a typed view still returns only when it was made',
          'ok = mad_typed_buffer_view((struct mad_device *)This, r, desc->Format, first, num, ' + u + ', e, &vwhy);' in f and
          'if (ok) return;' in f)
    check(name + ': plain views past their resource are counted only with view-census',
          'if (g_view_census && (first + num) * stride > r->size && mad_vc_on()) mad_vc_past(r, ' + u + ', first, num, stride);' in f)
check('UAV counter: still bound only when its view was made', 'if (cok) {' in uav)
cbv = body('static void STDMETHODCALLTYPE device_CreateConstantBufferView(ID3D12Device *This,')
check('CBV: checked only with view-census, before the descriptor is written',
      cbv.index('if (g_view_census && mad_vc_on()) mad_vc_cbv(') < cbv.index('mad_set_buffer_descriptor(e, desc->BufferLocation, desc->SizeInBytes);'))

for key, kind, default in (('skin-check', 'int', '0'), ('skin-check-every', 'int', '300'),
                           ('skin-check-capture', 'bool', '1'), ('view-census', 'bool', '0'),
                           ('skin-check-trace', 'bool', '0'), ('skin-dump', 'bool', '0'), ('typed-view-align', 'int', '0')):
    m = re.search(r'key: "' + re.escape(key) + r'".*?kind: \.(\w+), defaultValue: "([^"]*)"', catalog)
    check('catalog: ' + key + ' (' + kind + ', default ' + default + ')', m is not None and m.group(1) == kind and m.group(2) == default)
hzd = recs[recs.index('static let horizonZeroDawn = GameRecommendation('):]
hzd = hzd[:hzd.index('""",')]
check('Horizon Zero Dawn\'s list (v10): view-census on, the skinning diagnostics off again',
      'view-census = 1' in hzd and 'skin-check' not in hzd and 'skin-dump' not in hzd)
# build 485
check('485: skin-check-trace, skin-dump and typed-view-align off by default',
      'mad_cfg_int_pe("skin-check-trace", 0)' in pe and 'mad_cfg_int_pe("skin-dump", 0)' in pe and
      'mad_cfg_int_pe("typed-view-align", 0)' in pe)
check('typed-view-align: anything but 4, 16 or 256 is 64, and 64 without view-census asks Metal nothing',
      'int a = v == 4 || v == 16 || v == 256 ? (int)v : 64;' in pe and 'if (want == 64 && g_view_census <= 0) return 64;' in pe and
      'if (want == 64) return 64;   /* view-census alone: logged, nothing changes */' in pe and 'if (fl > 256) fl = 256;' in pe)
check('typed-view-align: the element offset is the one the view was made with', 'elem_off = r->tview[k].eoff;' in tbv and
      'r->tview[k].eoff = (UINT8)elem_off;' in tbv and '& ~(UINT64)63; elem_off = (r->tview[k].off' not in tbv)
check('skin-check-trace: every draw of the trace frame, before anything else in the hook',
      'if (s && mad_skin_trace_frame()) mad_skin_trace(e, c);' in sd and
      sd.index('mad_skin_trace(e, c);') < sd.index('if (!gpu) { if (s) s->ncs = s->ndl = 0; return; }') and
      'return g_skin_trace && g_skin_window <= 2 && g_skin_frame == g_skin_win_first;' in pe)
check('skin-dump: the first window\'s first two frames, once per shader or stream a frame',
      'return g_skin_dump && g_skin_window == 1 && g_skin_frame - g_skin_win_first < 2;' in pe and
      'UINT dump = mad_skin_dump_frame() && mad_skin_dump_once(h);' in pe and
      'dump = mad_skin_dump_frame() && mad_skin_dump_once(((UINT64)r->serial << 40) ^ off);' in sd)
check('a window records its first frame',
      'InterlockedIncrement(&g_skin_window); InterlockedExchange(&g_skin_win_first, InterlockedIncrement(&g_skin_frame));' in pe)
check('pipelines: the input layout tag only with skin-check-trace, freed with the pipeline',
      'if (g_skin_trace <= 0 || !il || !il->NumElements || !il->pInputElementDescs) return;' in pe and
      'free(p->il_tag);   /* madeira-bcd skin-check-trace */' in pe and
      'mad_bc_keep_ex(p->vs_hash, desc->VS.pShaderBytecode, desc->VS.BytecodeLength, p->il_int);' in gp)
check('Horizon Zero Dawn\'s list: typed-view-align 16 with typed-view-shadow (487; the probe showed 4 behaves as 16)',
      'typed-view-align = 16' in hzd and 'typed-view-shadow = 1' in hzd and 'typed-view-align = 4' not in hzd)
# build 486: typed-view-align = 4
kern = (root / 'madeira-d3d12/src/pe/mad_kernels.metal').read_text()
probe = body('static int mad_tv_probe(struct mad_device *d) {')
check('486: the probe kernel reads texel 0 (and 1) of four texture buffers, behind its own guard, before the clear shaders',
      '#ifndef MAD_NO_TEXBUF_PROBE' in kern and 'kernel void mad_texbuf_probe(' in kern and
      kern.index('kernel void mad_texbuf_probe(') < kern.index('#ifndef MAD_NO_CLEAR_RECTS') and
      all(x in kern for x in ('out[0] = t32.read(0u).x;', 'out[1] = t32.read(1u).x;', 'out[2] = t32b.read(0u).x;',
                              'out[3] = t16.read(0u).x;', 'out[4] = t8.read(0u).x;')))
check('486: the probe makes R32 at +4 and +20, R16 at +2, R8 at +1 over bytes 0, 1, 2, ... and wants those bytes back',
      '{ WMTPixelFormatR32Uint, 4, 4 }, { WMTPixelFormatR32Uint, 20, 4 }, { WMTPixelFormatR16Uint, 2, 2 }, { WMTPixelFormatR8Uint, 1, 1 } };' in probe and
      '((unsigned char *)bs.memory.ptr)[i] = (unsigned char)i;' in probe and
      'o[0] == 0x07060504u && o[1] == 0x0b0a0908u && o[2] == 0x17161514u) mask |= 1;' in probe and
      '(made & 4) && o[3] == 0x0302u) mask |= 2;' in probe and '(made & 8) && o[4] == 0x01u) mask |= 4;' in probe)
check('486: a texture Metal refuses off the boundary is bound at 0 so the kernel still runs, and its size fails',
      'tex[i] = MTLBuffer_newTexture(src, &ti, 0, 8 * t[i].bytes);' in probe and 'if (tex[i] && ti.gpu_resource_id) { made |= 1 << i; continue; }' in probe)
check('486: the probe waits for its command buffer, counts an error as not run, and releases what it made',
      'MTLCommandBuffer_waitUntilCompleted(cb);' in probe and 'ran = MTLCommandBuffer_status(cb) != WMTCommandBufferStatusError;' in probe and
      'for (i = 0; i < 4; i++) if (tex[i]) NSObject_release(tex[i]);' in probe and 'if (pool) NSObject_release(pool);' in probe and
      'NSObject_retain(cb);' in probe and 'if (cb) NSObject_release(cb);' in probe)
check('486: no helper kernel (or no probe in it): no exact starts',
      'd3d12_log("[typed-view] probe: no helper kernel in this build; views start at a 16-byte boundary\\n");\n        return 0;' in probe)
check('486: probed once, before the first view and outside the view lock',
      'if (mad_tv_mode() == 4) mad_tv_probe_once(d);' in tbv and
      tbv.index('mad_tv_probe_once(d);') < tbv.index('EnterCriticalSection(&d->view_lock);') and
      'if (g_tv_exact < 0) g_tv_exact = mad_tv_probe(d);' in pe)
check('486: a refused start goes to 16 (from an exact start), else to 64',
      'UINT next = al < 16 ? 16 : 64;' in tbv and 'al = next;' in tbv)
check('486: view-census reports the views made with an element offset, by pixel format, and the exact starts',
      'typed views made with an element offset (texture started before the view)' in pe and
      'if (elem_off) {   /* madeira-bcd: what typed-view-align leaves to the converter (view-census reports it) */' in tbv)

harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <math.h>
typedef uint32_t UINT32; typedef unsigned UINT; typedef long LONG; typedef uint64_t UINT64; typedef uint8_t UINT8; typedef uint16_t UINT16;
typedef int DXGI_FORMAT; typedef void *obj_handle_t;
typedef struct { int x; } SRWLOCK, CRITICAL_SECTION;
#define SRWLOCK_INIT { 0 }
static void AcquireSRWLockExclusive(SRWLOCK *l) { (void)l; }
static void ReleaseSRWLockExclusive(SRWLOCK *l) { (void)l; }
static void EnterCriticalSection(CRITICAL_SECTION *l) { (void)l; }
static void LeaveCriticalSection(CRITICAL_SECTION *l) { (void)l; }
static LONG InterlockedIncrement(volatile LONG *p) { return ++*p; }
static char logbuf[16384]; static size_t loglen;
static void d3d12_log(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    loglen += (size_t)vsnprintf(logbuf + loglen, sizeof logbuf - loglen, fmt, ap);
    va_end(ap);
}
#define MAD_SKIN_CAP_BUDGET 8000
#define MAD_SKIN_WIN_CAPS 1000
#define MAD_SK_N 512u
#define MAD_SK_DUMP_BUDGET (4u << 20)
typedef int64_t LONG64;
static LONG64 InterlockedExchangeAdd64(volatile LONG64 *p, LONG64 v) { LONG64 o = *p; *p += v; return o; }
static LONG InterlockedExchange(volatile LONG *p, LONG v) { LONG o = *p; *p = v; return o; }
struct mad_tvs { LONG64 seen; UINT32 k; };
struct mad_tview { UINT fmt; UINT64 off, num; UINT8 uav, eoff; obj_handle_t tex; UINT64 id, sh_gpu; struct mad_tvs *sh; };
struct mad_resource { obj_handle_t buffer; void *cpu; UINT64 size, gpu_address; struct mad_tview *tview; unsigned ntview, tview_cap; int heap;
                      void *own_mem; };
typedef struct mad_resource ID3D12Resource;
static int released;
static void ID3D12Resource_Release(ID3D12Resource *r) { (void)r; released++; }
static unsigned b64_bytes; static int b64_lines; static UINT64 b64_last;
static void mad_log_b64(UINT64 hash, const void *bc, UINT len) { (void)bc; b64_bytes += len; b64_lines++; b64_last = hash; }
static volatile LONG g_skin_cap_lines, g_skin_win_caps, g_skin_cmp_n, g_skin_dumps;
static volatile LONG64 g_skin_dump_bytes;
static SRWLOCK g_sk_lock = SRWLOCK_INIT;
static unsigned char *g_sk_cpu; static UINT g_sk_used;
static struct mad_skcap { char label[120]; UINT off, len, kind, stride; const void *q;
                          UINT dump; unsigned char *snap; struct mad_resource *src; UINT64 src_off; } g_sk_cap[MAD_SK_N];
static volatile unsigned g_sk_n;
''' + body('static void mad_sk_cat(char *o, size_t cap, int *n, const char *fmt, ...)') + '\n' + \
    body('static void mad_skin_cmp(const struct mad_skcap *c, const unsigned char *gpu)') + '\n' + \
    body('static void mad_skin_dumpcap(const struct mad_skcap *c, const unsigned char *gpu)') + '\n' + \
    body('static void mad_skin_print(const struct mad_skcap *c)') + '\n' + body('static void mad_skin_flush(const void *q)') + r'''
/* typed views */
enum WMTPixelFormat { WMTPixelFormatInvalid = 0, WMTPixelFormatR32Uint = 53, WMTPixelFormatR32Sint = 54, WMTPixelFormatRGBA32Float = 125,
                      WMTPixelFormatR32Float = 55, WMTPixelFormatDepth32Float = 252 };
enum WMTTextureUsage { WMTTextureUsageShaderRead = 1, WMTTextureUsageShaderWrite = 2, WMTTextureUsageShaderAtomic = 32 };
enum { WMTTextureTypeTextureBuffer = 9, WMTResourceStorageModeShared = 0, WMTResourceStorageModePrivate = 2 };
struct WMTTextureInfo { int pixel_format; uint32_t width, height, depth, array_length; int type; uint32_t mipmap_level_count, sample_count;
                        enum WMTTextureUsage usage; int options; UINT64 gpu_resource_id; };
struct mad_descriptor { UINT64 gpu_va, texture_view_id, metadata; };
struct mad_device { CRITICAL_SECTION view_lock; };
static LONG g_tview_live, g_tview_made, g_typed_atomic_views;
static int metal_refuses, grow_fails, refuse_unaligned64, refuse_unaligned16;
static UINT tv_align = 64; static volatile LONG g_tv_fallback, g_tv_eoff_views, g_tv_exact_views, g_tv_eoff_pf[1024];
static int tv_mode = 64, probes;
static int mad_tv_mode(void) { return tv_mode; }
static void mad_tv_probe_once(struct mad_device *d) { (void)d; probes++; }
/* tv_align 4 stands for the exact start: the element size */
static UINT mad_tv_align(struct mad_device *d, enum WMTPixelFormat pf, UINT bytes) { (void)d; (void)pf; return tv_align == 4 ? (bytes < 16 ? bytes : 16) : tv_align; }
static UINT64 next_id = 100;
static int mad_map_texture_format(DXGI_FORMAT f, int flags, enum WMTPixelFormat *out, int *is_depth) {
    (void)flags; *is_depth = 0;
    switch (f) { case 2: *out = WMTPixelFormatRGBA32Float; return 1; case 41: *out = WMTPixelFormatR32Float; return 1;
                 case 42: *out = WMTPixelFormatR32Uint; return 1; case 71: *out = WMTPixelFormatRGBA32Float; return 1; case 40: *out = WMTPixelFormatDepth32Float; *is_depth = 1; return 1;
                 default: return 0; }
}
static void mad_format_info(DXGI_FORMAT f, UINT *bytes, UINT *block) {
    *block = 1; *bytes = f == 2 ? 16 : f == 6 ? 12 : f == 71 ? 0 : 4;
    if (f == 71) *block = 4;
}
static int mad_typed_uav_atomic(void) { return 0; }
static obj_handle_t MTLBuffer_newTexture(obj_handle_t b, struct WMTTextureInfo *ti, UINT64 off, UINT64 bpr) {
    (void)b; (void)bpr;
    if (metal_refuses || (refuse_unaligned64 && (off & 63)) || (refuse_unaligned16 && (off & 15))) return NULL;
    ti->gpu_resource_id = next_id++;
    return (obj_handle_t)(uintptr_t)ti->gpu_resource_id;
}
static void NSObject_release(obj_handle_t h) { (void)h; }
static int mad_view_grow(struct mad_resource *r, void **arr, unsigned *cap, unsigned need, size_t elem) {
    (void)r;
    if (grow_fails) return 0;
    if (need > *cap) { *arr = realloc(*arr, need * elem); *cap = need; }
    return *arr != NULL;
}
static UINT64 last_vmap_id; static UINT32 last_vmap_a, last_vmap_b;
static void mad_vmap_put_locked(struct mad_device *d, UINT64 id, UINT32 a, UINT32 b) { (void)d; last_vmap_id = id; last_vmap_a = a; last_vmap_b = b; }
static void mad_view_census(const char *kind, struct mad_resource *r, unsigned n) { (void)kind; (void)r; (void)n; }
#define D3D12_HEAP_TYPE_UPLOAD 2
static volatile LONG g_tvs_other; static int tvs_on, tvs_made; static LONG64 g_presents_now;
static struct mad_tvs tvs_rec[8];
static int mad_tvs_on(void) { return tvs_on; }
static obj_handle_t mad_tvs_view(struct mad_device *d, struct mad_resource *r, struct WMTTextureInfo *ti,
                                 UINT64 byte_off, UINT64 num, UINT bytes, UINT64 *gpu, struct mad_tvs **rec) {
    (void)d; (void)r; (void)byte_off; (void)bytes;
    ti->width = (uint32_t)num; ti->gpu_resource_id = next_id++; *gpu = 0x70000000ull + 16u * (unsigned)tvs_made;
    *rec = &tvs_rec[tvs_made++ & 7]; (*rec)->seen = g_presents_now;
    return (obj_handle_t)(uintptr_t)ti->gpu_resource_id;
}
/* typed-view-rgb32 (R32G32B32 read through a 16-byte-element copy of UPLOAD memory): format 6 is the
 * harness's RGB32; every view of it here is of a non-UPLOAD buffer, which keeps reason 2 */
static volatile LONG g_tv_rgb32_other, g_tv_rgb32_views;
static int mad_tv_rgb32_format(DXGI_FORMAT f, enum WMTPixelFormat *pf) { if (f != 6) return 0; *pf = WMTPixelFormatRGBA32Float; return 1; }
static obj_handle_t mad_tvs_view_x(struct mad_device *d, struct mad_resource *r, struct WMTTextureInfo *ti,
                                   UINT64 byte_off, UINT64 num, UINT bytes, UINT dbytes, UINT64 *gpu, struct mad_tvs **rec) {
    (void)dbytes;
    return mad_tvs_view(d, r, ti, byte_off, num, bytes, gpu, rec);
}
static void mad_tvs_drop(struct mad_tvs *t) { (void)t; }
static void mad_tvs_touch(struct mad_tvs *t) { t->seen = g_presents_now; }
/* tv-hash: no table below 32 views; the lookup is then the scan it replaced */
static unsigned mad_tvh_find(const struct mad_resource *r, UINT fmt, UINT64 off, UINT64 num, UINT uav) {
    unsigned k;
    for (k = 0; k < r->ntview; k++)
        if (r->tview[k].fmt == fmt && r->tview[k].off == off && r->tview[k].num == num && r->tview[k].uav == (UINT8)uav) return k;
    return r->ntview;
}
static void mad_tvh_add(struct mad_resource *r, unsigned k) { (void)r; (void)k; }
''' + body('static int mad_typed_buffer_view(struct mad_device *d, struct mad_resource *r, DXGI_FORMAT fmt,') + r'''
static int bad;
#define EXPECT(c, what) do { if (!(c)) { printf("FAIL %s\n", what); bad = 1; } else printf("ok   %s\n", what); } while (0)
static int qa, qb;
int main(void) {
    char t[24]; int n = 0;
    float v[4][4] = { { 0, 0, 0, 1 }, { 1, -2, 3, 1 }, { NAN, 0, 0, 1 }, { 2e5f, 0, 0, 1 } };
    unsigned char *buf = calloc(1, 4096);
    mad_sk_cat(t, sizeof t, &n, "%s", "0123456789");
    mad_sk_cat(t, sizeof t, &n, "%s", "0123456789abcdefghij");
    mad_sk_cat(t, sizeof t, &n, "%s", "more");
    EXPECT(n == (int)sizeof t - 1 && strlen(t) == sizeof t - 1 && !memcmp(t, "0123456789", 10), "line helper: stops at the end, never past it");

    g_sk_cpu = buf;
    memcpy(buf, v, sizeof v);
    memset(buf + 256, 0, 256);
    g_sk_cap[0] = (struct mad_skcap){ "A s1", 0, 64, 20, 16, &qa };
    g_sk_cap[1] = (struct mad_skcap){ "B in", 256, 256, 21, 0, &qb };
    g_sk_cap[2] = (struct mad_skcap){ "C s2", 512, 40, 20, 20, &qa };
    g_sk_n = 3; g_sk_used = 560;
    mad_skin_flush(&qa);
    EXPECT(strstr(logbuf, "[skin-cap] A s1: 4 vertices, position 0: 1, NaN/Inf: 1, over 1e5: 1, max |x| 2e+05") != NULL,
           "stream summary: zero, NaN and huge vertices counted, largest magnitude");
    EXPECT(strstr(logbuf, "v0 (0 0 0 1) v1 (1 -2 3 1)") != NULL, "stream summary: the first two vertices");
    EXPECT(strstr(logbuf, "[skin-cap] C s2: 2 vertices, position 0: 2") != NULL, "a 20-byte stream of zeros: both vertices at 0");
    EXPECT(strstr(logbuf, "B in") == NULL && g_sk_n == 1 && !strcmp(g_sk_cap[0].label, "B in") && g_sk_used == 512,
           "flush: only the signalling queue's captures, the rest kept and the buffer end recomputed");
    loglen = 0; logbuf[0] = 0;
    mad_skin_flush(&qb);
    EXPECT(strstr(logbuf, "[skin-cap] B in: 64 words, zero 64, NaN/Inf 0") != NULL && g_sk_n == 0 && g_sk_used == 0,
           "input summary, then the buffer is empty");
    g_sk_cap[0] = (struct mad_skcap){ "D", 0, 16, 20, 16, &qa }; g_sk_n = 1; g_sk_used = 16; loglen = 0; logbuf[0] = 0;
    mad_skin_flush(NULL);
    EXPECT(g_sk_n == 0 && strstr(logbuf, "1 captures dropped") != NULL && strstr(logbuf, "[skin-cap] D") == NULL,
           "flush(NULL): a queue that never waited loses its captures, with a line");

    {
        struct mad_device d = { { 0 } };
        struct mad_resource buf32 = { (obj_handle_t)1, NULL, 32u << 20, 0x100000000ull, NULL, 0, 0 };
        struct mad_resource tiny = { (obj_handle_t)2, NULL, 4, 0x200000000ull, NULL, 0, 0 };
        struct mad_resource tex = { NULL, NULL, 0, 0, NULL, 0, 0 };
        struct mad_descriptor e;
        int why;
        why = -1; EXPECT(mad_typed_buffer_view(&d, &buf32, 2, 0, 65536, 1, &e, &why) == 1 && why == -1 &&
                         e.texture_view_id && (e.metadata >> 63), "a normal view: made, no reason");
        why = -1; EXPECT(mad_typed_buffer_view(&d, &buf32, 2, 0, 65536, 1, &e, &why) == 1 && why == -1 && buf32.ntview == 1,
                         "the same view again: the cached one");
        why = 0; EXPECT(mad_typed_buffer_view(&d, &tex, 2, 0, 16, 0, &e, &why) == 0 && why == 1, "a texture: reason 1");
        why = 0; EXPECT(mad_typed_buffer_view(&d, &buf32, 6, 0, 16, 0, &e, &why) == 0 && why == 2, "RGB32 (no Metal format): reason 2");
        why = 0; EXPECT(mad_typed_buffer_view(&d, &buf32, 40, 0, 16, 0, &e, &why) == 0 && why == 3, "a depth format: reason 3");
        why = 0; EXPECT(mad_typed_buffer_view(&d, &buf32, 71, 0, 16, 0, &e, &why) == 0 && why == 4, "a block format: reason 4");
        why = 0; EXPECT(mad_typed_buffer_view(&d, &tiny, 2, 65536, 16, 1, &e, &why) == 0 && why == 5,
                        "a view far past a 4-byte buffer: reason 5 (and no wrap-around width)");
        why = 0; EXPECT(mad_typed_buffer_view(&d, &tiny, 41, 0, 16, 0, &e, &why) == 1 && why == 9 && last_vmap_a == 16,
                        "a view longer than its buffer: made, cut short (reason 9), the descriptor keeps its count");
        why = 0; EXPECT(mad_typed_buffer_view(&d, &tiny, 2, 0, 16, 0, &e, &why) == 0 && why == 5,
                        "an element wider than the buffer: no width, reason 5");
        metal_refuses = 1;
        why = 0; EXPECT(mad_typed_buffer_view(&d, &buf32, 41, 8, 8, 0, &e, &why) == 0 && why == 7, "Metal refuses: reason 7");
        metal_refuses = 0; grow_fails = 1;
        why = 0; EXPECT(mad_typed_buffer_view(&d, &buf32, 41, 16, 8, 0, &e, &why) == 0 && why == 8, "the view list cannot grow: reason 8");
        grow_fails = 0;
        EXPECT(mad_typed_buffer_view(&d, &buf32, 41, 24, 8, 0, &e, NULL) == 1, "no reason pointer: still works");
        tv_align = 64;
        why = -1; EXPECT(mad_typed_buffer_view(&d, &buf32, 2, 2, 4, 0, &e, &why) == 1 && ((e.metadata >> 32) & 0xff) == 2 &&
                         e.gpu_va == buf32.gpu_address + 32 && last_vmap_b == 2,
                         "64 (the default): element 2 of a float4 view sits 2 elements past the texture's start");
        tv_align = 16;
        why = -1; EXPECT(mad_typed_buffer_view(&d, &buf32, 2, 1, 4, 0, &e, &why) == 1 && ((e.metadata >> 32) & 0xff) == 0 &&
                         e.gpu_va == buf32.gpu_address + 16 && last_vmap_b == 0,
                         "typed-view-align 16: a float4 view at element 1 starts there, no padding elements");
        why = -1; EXPECT(mad_typed_buffer_view(&d, &buf32, 42, 5, 4, 0, &e, &why) == 1 && ((e.metadata >> 32) & 0xff) == 1,
                         "typed-view-align 16: an R32 view at element 5 starts at byte 16, one element in");
        refuse_unaligned64 = 1;
        why = -1; EXPECT(mad_typed_buffer_view(&d, &buf32, 2, 3, 4, 0, &e, &why) == 1 && ((e.metadata >> 32) & 0xff) == 3 &&
                         g_tv_fallback == 1 && why == -1,
                         "Metal refuses the 16-byte start: the view is made at 64 as before, and counted");
        refuse_unaligned64 = 0; tv_align = 64;
        why = -1; EXPECT(mad_typed_buffer_view(&d, &buf32, 2, 1, 4, 0, &e, &why) == 1 && ((e.metadata >> 32) & 0xff) == 0,
                         "a cached view keeps the element offset it was made with");
        /* 486: typed-view-align = 4 */
        EXPECT(probes == 0 && g_tv_eoff_views == 4 && g_tv_exact_views == 0,
               "without typed-view-align 4 nothing is probed; the views made with an element offset are counted");
        tv_mode = 4; tv_align = 4;
        why = -1; EXPECT(mad_typed_buffer_view(&d, &buf32, 42, 7, 4, 0, &e, &why) == 1 && ((e.metadata >> 32) & 0xff) == 0 &&
                         e.gpu_va == buf32.gpu_address + 28 && last_vmap_b == 0 && probes == 1 && g_tv_exact_views == 1 &&
                         g_tv_eoff_views == 4, "typed-view-align 4: an R32 view at element 7 starts exactly at byte 28, after the probe");
        why = -1; EXPECT(mad_typed_buffer_view(&d, &buf32, 2, 5, 4, 0, &e, &why) == 1 && ((e.metadata >> 32) & 0xff) == 0 &&
                         g_tv_exact_views == 1, "typed-view-align 4: a float4 view starts at its 16-byte element, not counted as below 16");
        refuse_unaligned16 = 1; loglen = 0; logbuf[0] = 0;
        why = -1; EXPECT(mad_typed_buffer_view(&d, &buf32, 42, 9, 4, 0, &e, &why) == 1 && ((e.metadata >> 32) & 0xff) == 1 &&
                         g_tv_fallback == 2 && strstr(logbuf, "at a 4-byte boundary (offset 36); made at 16") != NULL && g_tv_eoff_views == 5,
                         "Metal refuses the exact start: made at 16, one element in, and counted");
        refuse_unaligned16 = 0; tv_mode = 64; tv_align = 64;
        EXPECT(probes == 3, "the probe hook runs for every view made while the switch is 4 (it probes once itself)");
        {   /* 487: typed-view-shadow */
            static unsigned char upmem[4096];
            struct mad_resource up = { (obj_handle_t)5, upmem, 4096, 0x5000, NULL, 0, 0, D3D12_HEAP_TYPE_UPLOAD };
            struct mad_resource gm = { (obj_handle_t)6, NULL, 4096, 0x6000, NULL, 0, 0, 1 };
            LONG eoff0 = g_tv_eoff_views;
            tv_mode = 16; tv_align = 16;
            why = -1; EXPECT(mad_typed_buffer_view(&d, &up, 42, 5, 4, 0, &e, &why) == 1 && ((e.metadata >> 32) & 0xff) == 1 &&
                             e.gpu_va == 0x5000 + 20 && tvs_made == 0 && g_tvs_other == 0 && g_tv_eoff_views == eoff0 + 1,
                             "487: typed-view-shadow off: an R32 view one element past 16 keeps its offset, nothing copied");
            tvs_on = 1;
            why = -1; EXPECT(mad_typed_buffer_view(&d, &up, 42, 6, 4, 0, &e, &why) == 1 && ((e.metadata >> 32) & 0xff) == 0 &&
                             e.gpu_va == 0x70000000ull && tvs_made == 1 && up.tview[up.ntview - 1].sh_gpu == 0x70000000ull &&
                             g_tv_eoff_views == eoff0 + 1, "487: on: an R32 view of UPLOAD memory off 16 bytes reads its aligned copy, no offset");
            g_presents_now = 40;
            why = -1; EXPECT(mad_typed_buffer_view(&d, &up, 42, 6, 4, 0, &e, &why) == 1 && e.gpu_va == 0x70000000ull && tvs_made == 1 &&
                             tvs_rec[0].seen == 40, "487: the cached view keeps pointing at its copy, which is marked as in use");
            why = -1; EXPECT(mad_typed_buffer_view(&d, &up, 42, 8, 4, 0, &e, &why) == 1 && e.gpu_va == 0x5000 + 32 && tvs_made == 1 &&
                             ((e.metadata >> 32) & 0xff) == 0, "487: a view on a 16-byte boundary needs no copy");
            why = -1; EXPECT(mad_typed_buffer_view(&d, &up, 42, 9, 4, 1, &e, &why) == 1 && ((e.metadata >> 32) & 0xff) == 1 &&
                             tvs_made == 1 && g_tvs_other == 1, "487: a UAV keeps its offset and is counted");
            why = -1; EXPECT(mad_typed_buffer_view(&d, &gm, 42, 7, 4, 0, &e, &why) == 1 && ((e.metadata >> 32) & 0xff) == 3 &&
                             e.gpu_va == 0x6000 + 28 && tvs_made == 1 && g_tvs_other == 2,
                             "487: a view of GPU memory keeps its offset and is counted");
            tvs_on = 0; tv_mode = 64; tv_align = 64;
        }
    }
    {   /* 485: copies of CPU-written memory against the CPU's bytes; skin-dump */
        unsigned char nowb[64];
        struct mad_resource src = { (obj_handle_t)9, nowb, 64, 0, NULL, 0, 0 };
        g_sk_cpu = buf;
        memset(buf + 1024, 1, 64); memset(nowb, 1, 64);
        g_sk_cap[0] = (struct mad_skcap){ "E pal", 1024, 64, 21, 0, &qa, 0, malloc(64), &src, 0 };
        memset(g_sk_cap[0].snap, 1, 64);
        g_sk_n = 1; g_sk_used = 1088; loglen = 0; logbuf[0] = 0; released = 0;
        mad_skin_flush(&qa);
        EXPECT(strstr(logbuf, "[skin-cmp] E pal: 64 bytes; the GPU read what the CPU had written at submission, unchanged since") != NULL &&
               released == 1 && g_sk_n == 0, "the GPU read the CPU's bytes: one line, the resource released after printing");
        g_sk_cap[0] = (struct mad_skcap){ "F pal", 1024, 64, 21, 0, &qa, 0, malloc(64), &src, 0 };
        memset(g_sk_cap[0].snap, 1, 64); buf[1024 + 8] = 7; nowb[8] = 7;
        g_sk_n = 1; g_sk_used = 1088; loglen = 0; logbuf[0] = 0;
        mad_skin_flush(&qa);
        EXPECT(strstr(logbuf, "the GPU read the CPU's LATER bytes (rewritten after submission) (1 of 16 words differ, the first at +8); "
                              "the CPU rewrote them since (1 words, the first at +8)") != NULL,
               "bytes rewritten while the work was in flight: the GPU read the later ones");
        g_sk_cap[0] = (struct mad_skcap){ "G pal", 1024, 64, 21, 0, &qa, 0, malloc(64), &src, 0 };
        memset(g_sk_cap[0].snap, 1, 64); memset(nowb, 1, 64); memset(buf + 1024, 1, 64); buf[1024 + 12] = 9;
        g_sk_n = 1; g_sk_used = 1088; loglen = 0; logbuf[0] = 0;
        mad_skin_flush(&qa);
        EXPECT(strstr(logbuf, "the GPU read BYTES THE CPU DID NOT HAVE THERE at submission or now (1 of 16 words differ, the first at +12); "
                              "the CPU left them since (0 words") != NULL,
               "the GPU's view differs from what the CPU wrote and still has");
        g_sk_cap[0] = (struct mad_skcap){ "H dump", 1024, 64, 21, 0, &qa, 1, NULL, NULL, 0 };
        g_sk_n = 1; g_sk_used = 1088; loglen = 0; logbuf[0] = 0; b64_lines = 0;
        mad_skin_flush(&qa);
        EXPECT(strstr(logbuf, "[skin-dump] 5d00000000000001: H dump, 64 bytes as the GPU read them (kind 21, stride 0); base64 follows") != NULL &&
               strstr(logbuf, "[skin-dump] 5d00000000000001: end") != NULL && b64_lines == 1 && b64_last == 0x5d00000000000001ull &&
               strstr(logbuf, "[skin-cmp] H dump") == NULL, "skin-dump: header, the bytes, end; no comparison without the CPU's copy");
        g_sk_cap[0] = (struct mad_skcap){ "I dump", 1024, 64, 21, 0, &qa, 1, malloc(64), &src, 0 };
        memset(g_sk_cap[0].snap, 2, 64);
        g_sk_n = 1; g_sk_used = 1088; loglen = 0; logbuf[0] = 0; b64_lines = 0;
        mad_skin_flush(&qa);
        EXPECT(b64_lines == 2 && b64_last == 0x5d80000000000002ull && strstr(logbuf, "as the CPU had written them at submission") != NULL,
               "skin-dump: the CPU's bytes too when the GPU read others");
        g_skin_dump_bytes = MAD_SK_DUMP_BUDGET;
        g_sk_cap[0] = (struct mad_skcap){ "J dump", 1024, 64, 21, 0, &qa, 1, NULL, NULL, 0 };
        g_sk_n = 1; g_sk_used = 1088; loglen = 0; logbuf[0] = 0; b64_lines = 0;
        mad_skin_flush(&qa);
        EXPECT(b64_lines == 0 && strstr(logbuf, "dump budget is spent; J dump") != NULL && strstr(logbuf, "[skin-cap] J dump") != NULL,
               "skin-dump: past the 4 MB budget only the summary");
    }
    printf("%s\n", bad ? "harness FAILED" : "harness ok");
    return bad;
}
'''


def src_block(start, end_marker='};'):
    a = pe.index(start)
    return pe[a:pe.index(end_marker, a) + len(end_marker)]


harness2 = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
typedef uint32_t UINT32; typedef unsigned UINT; typedef long LONG; typedef uint64_t UINT64;
typedef struct { int x; } SRWLOCK;
#define SRWLOCK_INIT { 0 }
static void AcquireSRWLockExclusive(SRWLOCK *l) { (void)l; }
static void ReleaseSRWLockExclusive(SRWLOCK *l) { (void)l; }
#define MAD_DESC_TYPEDBUF (1ull << 63)
#define MAD_ROOT_PARAM_MAX 64
enum { MADEIRA_IR_PARAM_TABLE = 0, MADEIRA_IR_PARAM_CONSTANTS = 1, MADEIRA_IR_PARAM_CBV = 2, MADEIRA_IR_PARAM_SRV = 3, MADEIRA_IR_PARAM_UAV = 4 };
enum { MADEIRA_IR_RANGE_SRV = 0, MADEIRA_IR_RANGE_UAV = 1, MADEIRA_IR_RANGE_CBV = 2, MADEIRA_IR_RANGE_SAMPLER = 3 };
enum { MADEIRA_IR_VIS_ALL = 0, MADEIRA_IR_VIS_VERTEX = 1, MADEIRA_IR_VIS_PIXEL = 5 };
struct madeira_ir_root_param { uint32_t type, shader_register, register_space, num_constants, visibility, num_ranges, first_range, reserved; };
struct madeira_ir_root_range { uint32_t range_type, num_descriptors, base_register, register_space, table_offset, reserved; };
struct mad_rootsig { unsigned nparams, nranges; struct madeira_ir_root_param params[8]; struct madeira_ir_root_range ranges[8]; };
struct mad_descriptor { UINT64 gpu_va, texture_view_id, metadata; };
struct mad_heap { struct mad_descriptor *cpu; UINT64 gpu_address; unsigned count; };
struct mad_resource { unsigned serial; UINT64 gpu_address, size; };
struct mad_device { int x; };
struct mad_queue { struct mad_device *device; };
struct mad_pso { UINT64 cs_hash; };
#define MAD_SK_IN 12u
""" + src_block('struct mad_skinx {') + r"""
struct mad_exec { struct mad_queue *q; struct mad_heap *srv; struct mad_pso *cpso; struct mad_skinx *sk; };
static volatile LONG g_skin_frame = 7;
static SRWLOCK g_sk_lock = SRWLOCK_INIT;
""" + src_block('static struct mad_skw {', ';\n') + r"""
static unsigned g_skin_wn;
static struct mad_resource res[2] = { { 41, 0x100000000ull, 16u << 20 }, { 42, 0x200000000ull, 4 } };
static struct mad_resource *mad_resolve_address(struct mad_device *d, UINT64 va, UINT64 *off) {
    int i; (void)d;
    for (i = 0; i < 2; i++) if (va >= res[i].gpu_address && va < res[i].gpu_address + res[i].size) { *off = va - res[i].gpu_address; return &res[i]; }
    return NULL;
}
""" + body('static void mad_sk_cat(char *o, size_t cap, int *n, const char *fmt, ...)') + '\n' + \
    body('static void mad_skin_where(struct mad_device *d, UINT64 va, char *o, size_t cap, int *n, struct mad_resource **out, UINT64 *out_off)') + '\n' + \
    body('static void mad_skin_in(struct mad_skinx *s, struct mad_resource *r, UINT64 off, UINT64 size)') + '\n' + \
    body('static void mad_skin_note_write(struct mad_exec *e, const struct mad_resource *r, UINT64 off)') + '\n' + \
    body('static void mad_skin_desc(struct mad_exec *e, const struct mad_descriptor *de, UINT range_type, char *t, size_t cap, int *n)') + '\n' + \
    body('static void mad_skin_rs_tok(struct mad_exec *e, const struct mad_rootsig *rs, const UINT64 *root, const UINT32 (*consts)[64], unsigned vis_mask)') + r"""
static int bad;
#define EXPECT(c, what) do { if (!(c)) { printf("FAIL %s\n", what); bad = 1; } else printf("ok   %s\n", what); } while (0)
int main(void) {
    static struct mad_descriptor heap[64];
    struct mad_heap h = { heap, 0x900000000ull, 64 };
    struct mad_device dev; struct mad_queue q = { &dev }; struct mad_pso pso = { 0xabcdef };
    struct mad_skinx *s = calloc(1, sizeof *s);
    struct mad_exec e = { &q, &h, &pso, s };
    struct mad_rootsig rs; UINT64 root[8] = { 0 }; static UINT32 consts[64][64];
    memset(&rs, 0, sizeof rs);
    /* p0: table at heap[10]: t0..t1 (offset 0), u0 (appended), CBV b3 at offset 5; p1: constants b1; p2: root UAV u4; p3: pixel only */
    rs.nparams = 4; rs.nranges = 3;
    rs.params[0] = (struct madeira_ir_root_param){ MADEIRA_IR_PARAM_TABLE, 0, 0, 0, MADEIRA_IR_VIS_ALL, 3, 0, 0 };
    rs.ranges[0] = (struct madeira_ir_root_range){ MADEIRA_IR_RANGE_SRV, 2, 0, 0, 0, 0 };
    rs.ranges[1] = (struct madeira_ir_root_range){ MADEIRA_IR_RANGE_UAV, 1, 0, 0, 0xffffffffu, 0 };
    rs.ranges[2] = (struct madeira_ir_root_range){ MADEIRA_IR_RANGE_CBV, 1, 3, 0, 5, 0 };
    rs.params[1] = (struct madeira_ir_root_param){ MADEIRA_IR_PARAM_CONSTANTS, 1, 0, 4, MADEIRA_IR_VIS_ALL, 0, 0, 0 };
    rs.params[2] = (struct madeira_ir_root_param){ MADEIRA_IR_PARAM_UAV, 4, 0, 0, MADEIRA_IR_VIS_ALL, 0, 0, 0 };
    rs.params[3] = (struct madeira_ir_root_param){ MADEIRA_IR_PARAM_CBV, 0, 0, 0, MADEIRA_IR_VIS_PIXEL, 0, 0, 0 };
    root[0] = h.gpu_address + 10 * sizeof(struct mad_descriptor);
    root[2] = res[0].gpu_address + 4096; root[3] = res[0].gpu_address;
    consts[1][0] = 0x11; consts[1][1] = 0x22; consts[1][2] = 0x33; consts[1][3] = 0x44;
    heap[10] = (struct mad_descriptor){ res[0].gpu_address + 256, 77, (1ull << 63) | (2ull << 32) | 1048576 };   /* typed SRV t0 */
    heap[11] = (struct mad_descriptor){ res[0].gpu_address + 512, 0, 4096 };                                     /* raw SRV t1 */
    heap[12] = (struct mad_descriptor){ res[1].gpu_address + 65536, 0, (1ull << 63) | 1048576 };                /* typed UAV u0, no texture, past r#42 */
    heap[15] = (struct mad_descriptor){ res[0].gpu_address + 8192, 0, 256 };                                     /* CBV b3 at offset 5 */
    s->tab_cs = 1;
    mad_skin_rs_tok(&e, &rs, root, (const UINT32 (*)[64])consts, ~0u);
    printf("%s\n", s->tok);
    EXPECT(strstr(s->tok, " p0:{@10 t0x2=T{r#41+256/1048576 e2},r#41+512/4096 u0=T{va:200010000?/1048576 e0 NO-TEXTURE} b3=r#41+8192/256}") != NULL,
           "a table: ranges at their offsets (appended after the previous one), typed and plain views, a view with no texture");
    EXPECT(strstr(s->tok, " p1:b1=11,22,33,44") != NULL, "root constants");
    EXPECT(strstr(s->tok, " p2:root-u4=r#41+4096") != NULL, "a root UAV");
    EXPECT(strstr(s->tok, "p3:") != NULL, "compute sees pixel-only parameters too (all visibilities)");
    EXPECT(s->nin == 4 && s->in[0].off == 256 && s->in[1].off == 512 && s->in[2].off == 8192 && s->in[3].off == 0,
           "inputs: the SRVs and the CBVs (table and root)");
    EXPECT(s->in[0].len == 1048576 && s->in[1].len == 4096 && s->in[2].len == 256 && s->in[3].len == 256,
           "inputs: each view's size from its descriptor (a root descriptor's is unknown: 256)");
    EXPECT(g_skin_wn == 1 && g_skin_w[0].r == &res[0] && g_skin_w[0].off == 4096 && g_skin_w[0].cs == 0xabcdef && g_skin_w[0].frame == 7,
           "writes: the root UAV (the unresolved table UAV cannot be)");
    s->ntok = 0; s->tok[0] = 0; s->nin = 0; s->tab_cs = 0;
    mad_skin_rs_tok(&e, &rs, root, (const UINT32 (*)[64])consts, (1u << MADEIRA_IR_VIS_ALL) | (1u << MADEIRA_IR_VIS_VERTEX));
    EXPECT(strstr(s->tok, "p3:") == NULL && g_skin_wn == 1, "a draw: pixel-only parameters left out, no writes noted");
    root[0] = h.gpu_address + 70 * sizeof(struct mad_descriptor); s->ntok = 0; s->tok[0] = 0;
    mad_skin_rs_tok(&e, &rs, root, (const UINT32 (*)[64])consts, ~0u);
    EXPECT(strstr(s->tok, " p0:{not in the bound heap}") != NULL, "a table outside the heap is named, not read");
    root[0] = h.gpu_address + 62 * sizeof(struct mad_descriptor); s->ntok = 0; s->tok[0] = 0;
    mad_skin_rs_tok(&e, &rs, root, (const UINT32 (*)[64])consts, ~0u);
    EXPECT(strstr(s->tok, "past-heap") != NULL, "a range running past the heap stops there");
    root[0] = 0; s->ntok = 0; s->tok[0] = 0;
    mad_skin_rs_tok(&e, &rs, root, (const UINT32 (*)[64])consts, ~0u);
    EXPECT(strstr(s->tok, " p0:{unset}") != NULL, "an unset table");
    printf("%s\n", bad ? "harness FAILED" : "harness ok");
    return bad;
}
"""

# build 486: the typed-view-align policy itself (the real mad_tv_mode and mad_tv_align)
harness3 = r"""
#include <stdio.h>
#include <stdarg.h>
typedef unsigned UINT; typedef unsigned long long UINT64; typedef long LONG; typedef unsigned short UINT16;
enum WMTPixelFormat { WMTPixelFormatR32Uint = 53 };
struct mad_device { void *mtl_device; };
static long long cfg; static long long mad_cfg_int_pe(const char *k, long long d) { (void)k; (void)d; return cfg; }
static int logged;
static void d3d12_log(const char *fmt, ...) { (void)fmt; logged++; }
static int g_view_census;
static LONG InterlockedIncrement(volatile LONG *p) { return ++*p; }
static UINT64 metal_min = 16; static int asked;
static UINT64 MTLDevice_minimumLinearTextureAlignmentForPixelFormat(void *d, enum WMTPixelFormat pf) { (void)d; (void)pf; asked++; return metal_min; }
static int g_tv_align = -1, g_tv_exact = -1; static UINT16 g_tv_floor[1024]; static volatile LONG g_tv_said;
""" + body('static int mad_tv_mode(void) {') + '\n' + body('static UINT mad_tv_align(struct mad_device *d, enum WMTPixelFormat pf, UINT bytes) {') + r"""
static int bad;
#define EXPECT(c, what) do { if (!(c)) { printf("FAIL %s\n", what); bad = 1; } else printf("ok   %s\n", what); } while (0)
int main(void) {
    struct mad_device d = { 0 };
    cfg = 4; g_tv_exact = 7;
    EXPECT(mad_tv_mode() == 4 && logged == 1, "4 is a value, logged once");
    EXPECT(mad_tv_align(&d, WMTPixelFormatR32Uint, 4) == 4 && mad_tv_align(&d, WMTPixelFormatR32Uint, 2) == 2 &&
           mad_tv_align(&d, WMTPixelFormatR32Uint, 1) == 1 && mad_tv_align(&d, WMTPixelFormatR32Uint, 8) == 8 &&
           mad_tv_align(&d, WMTPixelFormatR32Uint, 16) == 16 && asked == 0,
           "4, every size probed right: each view starts at its element size, Metal's linear minimum not asked");
    g_tv_exact = 1;
    EXPECT(mad_tv_align(&d, WMTPixelFormatR32Uint, 4) == 4 && mad_tv_align(&d, WMTPixelFormatR32Uint, 8) == 8 &&
           mad_tv_align(&d, WMTPixelFormatR32Uint, 2) == 16 && mad_tv_align(&d, WMTPixelFormatR32Uint, 1) == 16,
           "4, only 4-byte reads right: 4-byte and wider exact, 2- and 1-byte elements at 16");
    g_tv_exact = 0;
    EXPECT(mad_tv_align(&d, WMTPixelFormatR32Uint, 4) == 16, "4, the probe failed: 16 as with typed-view-align 16");
    g_tv_exact = -1;
    EXPECT(mad_tv_align(&d, WMTPixelFormatR32Uint, 4) == 16, "4, not probed (yet): 16");
    metal_min = 64; g_tv_floor[53] = 0; g_tv_exact = 0;
    EXPECT(mad_tv_align(&d, WMTPixelFormatR32Uint, 4) == 64, "4, probe failed, Metal asks 64 for the format: 64");
    metal_min = 16; g_tv_floor[53] = 0;
    g_tv_align = -1; cfg = 16; g_tv_exact = 7;
    EXPECT(mad_tv_align(&d, WMTPixelFormatR32Uint, 4) == 16, "16 ignores the probe");
    g_tv_align = -1; cfg = 0; asked = 0;
    EXPECT(mad_tv_align(&d, WMTPixelFormatR32Uint, 4) == 64 && asked == 0, "unset: 64, Metal not asked");
    g_tv_align = -1; cfg = 8;
    EXPECT(mad_tv_mode() == 64, "8 is not a value: 64");
    printf("%s\n", bad ? "harness FAILED" : "harness ok");
    return bad;
}
"""

cc = shutil.which('cc') or shutil.which('gcc') or shutil.which('clang')
if not cc:
    check('a host C compiler', False)
else:
    with tempfile.TemporaryDirectory(prefix='madeira-skin-') as tmp:
        src = Path(tmp) / 'skin.c'
        exe = Path(tmp) / 'skin'
        src.write_text(harness)
        b = subprocess.run([cc, '-std=gnu11', '-Wall', '-Wno-unused-function', '-Wno-unused-variable', str(src), '-o', str(exe), '-lm'],
                           capture_output=True, text=True)
        check('the helpers compile on the host', b.returncode == 0)
        if b.returncode:
            print(b.stderr[-3000:])
        else:
            run = subprocess.run([str(exe)], capture_output=True, text=True)
            print(run.stdout, end='')
            check('the helpers behave', run.returncode == 0)
        src2 = Path(tmp) / 'skin2.c'
        exe2 = Path(tmp) / 'skin2'
        src2.write_text(harness2)
        b = subprocess.run([cc, '-std=gnu11', '-Wall', '-Wno-unused-function', '-Wno-unused-variable', str(src2), '-o', str(exe2)],
                           capture_output=True, text=True)
        check('the root-signature walk compiles on the host', b.returncode == 0)
        if b.returncode:
            print(b.stderr[-3000:])
        else:
            run = subprocess.run([str(exe2)], capture_output=True, text=True)
            print(run.stdout, end='')
            check('the root-signature walk behaves', run.returncode == 0)
        src3 = Path(tmp) / 'skin3.c'
        exe3 = Path(tmp) / 'skin3'
        src3.write_text(harness3)
        b = subprocess.run([cc, '-std=gnu11', '-Wall', '-Wno-unused-function', '-Wno-unused-variable', str(src3), '-o', str(exe3)],
                           capture_output=True, text=True)
        check('the typed-view-align policy compiles on the host', b.returncode == 0)
        if b.returncode:
            print(b.stderr[-3000:])
        else:
            run = subprocess.run([str(exe3)], capture_output=True, text=True)
            print(run.stdout, end='')
            check('the typed-view-align policy behaves', run.returncode == 0)

if not ok:
    sys.exit(1)
print('PASS: skin-check')
