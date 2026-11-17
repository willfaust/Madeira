#!/usr/bin/env python3
"""Ghost of Tsushima smoke-square diagnostics; no device.

madeira-d3d12/src/pe/madeira_d3d12.c gained three switches, all OFF unless set
in madeira.cfg or the game's file: skip-ps (+ skip-ps-cycle), dxil-dump,
and converter (DXIL) draws in the capture-ps walker.
This test

  * checks statically that every switch is read with a default that changes
    nothing, that the draw hook is behind its "unset" fast path, that both
    shader caches key on the input topology, and
    that capture-cs still logs under its own tag after the walker was shared;
  * cuts the skip-ps / dxil-dump functions out of the source, compiles them on
    the host with small stubs for the Windows calls and runs them: unset means
    nothing matches; a list matches exact pixel OR vertex entry names only;
    skip-ps-cycle rotates "nothing", first, second, ... with the clock; the
    dxil-dump list matches exact names.

The one-frame shapes added five more, also OFF
by default: fence-strict, upload-guard (+ upload-guard-bytes), desc-guard and
cbv-snapshot. The test checks that every hook sits behind g_sd_state, that
the verifications run before a fence advances or Present returns, that
Queue::Wait's fast path is untouched unless fence-strict is set; then it cuts
the whole SYNC DIAGNOSTICS block out of the source and runs it on the host:
option clamps, batch tickets, a rewritten UPLOAD range is reported (and an
unchanged, GPU-only or READBACK one is not), descriptor writes into slots of
an unfinished batch are reported, root-CBV copies land 256-aligned in the
argument slot's own ring chunk and are reused within a replay.

Round 3 (the main menu's flickering grass) added ind-count (+
ind-count-from), capture-cs by name/hash, and sampler-reduction /
sampler-census: the test checks their defaults and hooks, runs the per-frame
sums and the dip detection inside the sync harness, and cuts the sampler
mapping out and runs it: unchanged by default (MIN/MAX filters are logged),
point-sampled without comparison (1), without comparison only (2).

The runtime parts are skipped when no host C compiler is found (cc, gcc or
clang); the static checks still run.
"""
import pathlib, re, shutil, subprocess, sys, tempfile

R = pathlib.Path(__file__).resolve().parents[2]
SRC = (R / "madeira-d3d12/src/pe/madeira_d3d12.c").read_text()
CACHE = (R / "madeira-d3d12/src/unix/madeira_dxil_cache.h").read_text()
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok = ok and bool(cond)


# --- static checks ---------------------------------------------------------
check("skip-ps read as a string (unset = no names)", 'mad_cfg_str_pe("skip-ps", buf, sizeof buf)' in SRC)
check("skip-ps-cycle defaults to 0", 'mad_cfg_int_pe("skip-ps-cycle", 0)' in SRC)
check("dxil-dump read as a string (unset = nothing dumped)", 'mad_cfg_str_pe("dxil-dump", g_dxil_dump, sizeof g_dxil_dump)' in SRC)
check("draw hook behind the skip-ps fast path",
      "if (g_skip_ps_state && mad_skip_ps_match(e->pso)) { MAD_SKIP(e); return; }" in SRC)
check("draw hook after the render pass began (clears still run)",
      SRC.index("if (g_skip_ps_state && mad_skip_ps_match(e->pso))") >
      SRC.index("if (!exec_begin_render(e)) { MAD_SKIP(e); return; }\n    if (g_skip_ps_state"))
check("dxil-dump hooks behind their fast path",
      SRC.count("if (g_dxil_dump_state && ") == 2)
check("the geometry-shader path keeps the plain topology",
      "ov.topology = (UINT)desc->PrimitiveTopologyType; ov.layout = L->n ? L : NULL;" in SRC)
check("PE shader cache keys on input_topology", "mad_sc_feed_u64(&h, ((UINT64)a->gs_emulation << 32) | a->input_topology);" in SRC)
check("unix DXIL cache keys on input_topology", "mad_dxc_hu32(&s, a->input_topology);" in CACHE)
check("capture-cs keeps its log tag through the shared walker",
      'mad_capture_rs_tables(e, benc, seq, rs, e->croot, (const UINT32 (*)[64])e->cconsts, "capture-cs");' in SRC)
check("capture-ps walks a converter pipeline's root signature",
      'mad_capture_rs_tables(e, benc, seq, e->rs, e->root, (const UINT32 (*)[64])e->consts, "capture-draw");' in SRC)
check("GPU fault shaders still logged through the shared base64 writer",
      "mad_log_b64(hash, bc, len);" in SRC and 'GPU fault shader %016llx: end of bytecode' in SRC)
check("capture-ps matches exact names (no substring: ps_SetColor is not ps_SetColor_MultiLight)",
      "mad_name_in_list(g_capture_ps, e->pso->ps_name)" in SRC and "strstr(g_capture_ps" not in SRC)

# --- run the parsers on the host --------------------------------------------
cc = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
if not cc:
    print("SKIP: no host C compiler for the runtime part")


def cut(sig):
    i = SRC.index(sig)
    j = SRC.index("{", i)
    depth = 0
    for k in range(j, len(SRC)):
        if SRC[k] == "{":
            depth += 1
        elif SRC[k] == "}":
            depth -= 1
            if depth == 0:
                return SRC[i:k + 1]
    raise SystemExit("unbalanced " + sig)


def line(prefix):
    m = re.search(r"^" + re.escape(prefix) + r".*$", SRC, re.M)
    if not m:
        raise SystemExit("missing global " + prefix)
    return m.group(0)


STUBS = r'''
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef long LONG; typedef long long LONG64; typedef unsigned long long ULONGLONG, UINT64; typedef unsigned UINT;
typedef size_t SIZE_T;
typedef struct { int unused; } SRWLOCK;
#define SRWLOCK_INIT { 0 }
static void AcquireSRWLockExclusive(SRWLOCK *l) { (void)l; }
static void ReleaseSRWLockExclusive(SRWLOCK *l) { (void)l; }
static ULONGLONG g_now_ms = 1000;
static ULONGLONG GetTickCount64(void) { return g_now_ms; }
static LONG InterlockedExchange(volatile LONG *p, LONG v) { LONG o = *p; *p = v; return o; }
static LONG InterlockedIncrement(volatile LONG *p) { return ++*p; }
#define MemoryBarrier() ((void)0)
static volatile LONG64 g_presents_now;
static char g_cfg_skip[512], g_cfg_dump[512]; static long long g_cfg_cycle;
static int mad_cfg_str_pe(const char *key, char *out, size_t cap) {
    const char *v = !strcmp(key, "skip-ps") ? g_cfg_skip : !strcmp(key, "dxil-dump") ? g_cfg_dump : "";
    snprintf(out, cap, "%s", v); return v[0] != 0;
}
static long long mad_cfg_int_pe(const char *key, long long dflt) { return !strcmp(key, "skip-ps-cycle") && g_cfg_cycle ? g_cfg_cycle : dflt; }
static int g_logs;
static void d3d12_log(const char *fmt, ...) { va_list ap; va_start(ap, fmt); g_logs++; vfprintf(stdout, fmt, ap); va_end(ap); }
struct mad_pso { char vs_name[64]; char ps_name[64]; };
'''

HARNESS = r'''
static struct mad_pso P(const char *vs, const char *ps) { struct mad_pso p; memset(&p, 0, sizeof p); snprintf(p.vs_name, 64, "%s", vs); snprintf(p.ps_name, 64, "%s", ps); return p; }
static void reset(const char *skip, long long cycle, const char *dump) {
    snprintf(g_cfg_skip, sizeof g_cfg_skip, "%s", skip); g_cfg_cycle = cycle; snprintf(g_cfg_dump, sizeof g_cfg_dump, "%s", dump);
    g_skip_ps_state = -1; g_skip_ps_n = 0; g_skip_ps_cycle = 0; g_skip_ps_phase = -1; g_skip_ps_dropped = 0; g_now_ms = 1000;
    g_dxil_dump_state = -1;
}
#define T(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); return 1; } } while (0)
int main(void) {
    struct mad_pso ml = P("ls_SetColor", "ps_SetColor_MultiLight"), ca = P("vs_SetColorCombinedAlpha", "ps_SetColorCombinedAlpha"),
                   sc = P("vs_SetColor", "ps_SetColor"), other = P("vs_Main", "ps_Deferred");
    /* unset: nothing matches, nothing logged, state settles to 0 */
    reset("", 0, ""); g_logs = 0;
    T(!mad_skip_ps_match(&ml) && !mad_skip_ps_match(&other)); T(g_skip_ps_state == 0); T(g_logs == 0);
    T(!mad_dxil_dump_wanted("ls_SetColor")); T(g_dxil_dump_state == 0);
    /* static list: exact pixel or vertex names, never a prefix */
    reset(" ps_SetColor_MultiLight, vs_SetColorCombinedAlpha ;", 0, "");
    T(mad_skip_ps_match(&ml)); T(mad_skip_ps_match(&ca)); T(!mad_skip_ps_match(&sc)); T(!mad_skip_ps_match(&other));
    T(g_skip_ps_n == 2);
    /* cycle 8 s over three names: 0-8 nothing, 8-16 first, 16-24 second, 24-32 third, 32 nothing again */
    reset("ps_SetColor_MultiLight,ps_SetColorCombinedAlpha,ps_SetColor", 8, "");
    T(!mad_skip_ps_match(&ml) && !mad_skip_ps_match(&ca) && !mad_skip_ps_match(&sc));
    g_now_ms = 1000 + 8000;  T(mad_skip_ps_match(&ml) && !mad_skip_ps_match(&ca) && !mad_skip_ps_match(&sc)); T(g_skip_ps_phase == 1);
    g_now_ms = 1000 + 16500; T(!mad_skip_ps_match(&ml) && mad_skip_ps_match(&ca) && !mad_skip_ps_match(&sc)); T(g_skip_ps_phase == 2);
    g_now_ms = 1000 + 24000; T(!mad_skip_ps_match(&ml) && !mad_skip_ps_match(&ca) && mad_skip_ps_match(&sc)); T(g_skip_ps_phase == 3);
    g_now_ms = 1000 + 32000; T(!mad_skip_ps_match(&ml) && !mad_skip_ps_match(&ca) && !mad_skip_ps_match(&sc)); T(g_skip_ps_phase == 0);
    T(!mad_skip_ps_match(&other));
    /* dxil-dump: exact names only */
    reset("", 0, "ls_SetColor, ps_SetColorCombinedAlpha");
    T(mad_dxil_dump_wanted("ls_SetColor")); T(mad_dxil_dump_wanted("ps_SetColorCombinedAlpha"));
    T(!mad_dxil_dump_wanted("ls_SetColo")); T(!mad_dxil_dump_wanted("ps_SetColor")); T(!mad_dxil_dump_wanted(""));
    /* the shared list matcher (capture-ps uses it too) */
    T(mad_name_in_list("ps_SetColor_MultiLight,ps_SetColorCombinedAlpha", "ps_SetColorCombinedAlpha"));
    T(!mad_name_in_list("ps_SetColor_MultiLight,ps_SetColorCombinedAlpha", "ps_SetColor"));
    T(mad_name_in_list(" a ;b\tc,", "c")); T(!mad_name_in_list("abc", "")); T(!mad_name_in_list("", "abc"));
    printf("harness ok\n");
    return 0;
}
'''

code = STUBS
for pfx in ("static char g_skip_ps_tok", "static volatile LONG g_skip_ps_phase", "static SRWLOCK g_skip_ps_lock",
            "static char g_dxil_dump[512]"):
    code += line(pfx) + "\n"
code += "\n" + cut("static int mad_name_in_list(const char *list, const char *name)") + "\n"
code += "\n" + cut("static void mad_skip_ps_load(void)") + "\n"
code += cut("static int mad_skip_ps_match(const struct mad_pso *p)") + "\n"
code += cut("static int mad_dxil_dump_wanted(const char *name)") + "\n"
code += HARNESS
with tempfile.TemporaryDirectory() as t:
    if cc:
        c = pathlib.Path(t) / "h.c"
        c.write_text(code)
        exe = pathlib.Path(t) / "h"
        p = subprocess.run([cc, "-std=c99", "-Wall", "-Wno-unused-function", "-Wno-unused-variable", "-o", str(exe), str(c)],
                           capture_output=True, text=True)
        check("harness compiles", p.returncode == 0)
        if p.returncode:
            print(p.stderr[-3000:])
        else:
            r = subprocess.run([str(exe)], capture_output=True, text=True)
            check("skip-ps / skip-ps-cycle / dxil-dump behave (" + r.stdout.strip().splitlines()[-1] + ")",
                  r.returncode == 0 and "harness ok" in r.stdout)
            if r.returncode:
                print(r.stdout[-3000:])

# --- sync diagnostics (section 8: the one-frame shapes) ---------------------
# fence-strict, upload-guard (+ upload-guard-bytes), desc-guard, cbv-snapshot.
check("fence-strict defaults to 0", 'fs = mad_cfg_int_pe("fence-strict", 0);' in SRC)
check("upload-guard defaults to 0", 'ug = mad_cfg_int_pe("upload-guard", 0);' in SRC)
check("upload-guard-bytes defaults to 256", 'ub = mad_cfg_int_pe("upload-guard-bytes", 256);' in SRC)
check("desc-guard defaults to 0", 'dg = mad_cfg_int_pe("desc-guard", 0);' in SRC)
check("cbv-snapshot defaults to 0", 'cs = mad_cfg_int_pe("cbv-snapshot", 0);' in SRC)
check("all off -> g_sd_state 0 and no log line",
      "if (g_fence_strict || g_upload_guard || g_desc_guard || g_cbv_snap || g_qtrace)\n        d3d12_log(\"[sync-diag]" in SRC)
check("every hook outside the helpers is behind g_sd_state",
      all(h in SRC for h in (
          "if (g_sd_state > 0 && rs && root) root = mad_sd_root(e, rs, root, sd_root, pso);",
          "if (g_sd_state > 0 && g_upload_guard) mad_ug_note_draw(e, c);",
          "if (g_sd_state > 0) mad_dg_write((const void *)dst.ptr, n, \"CopyDescriptorsSimple\");",
          "if (g_sd_state > 0) mad_dg_write(e, 1, \"CreateConstantBufferView\");",
          "if (g_sd_state > 0) mad_dg_write(e, 1, \"CreateShaderResourceView\");",
          "if (g_sd_state > 0) mad_dg_write(e, 1, \"CreateUnorderedAccessView\");",
          "if (g_sd_state > 0) mad_dg_write(e, 1, \"CreateSampler\");",
          "if (g_sd_state > 0 && g_desc_guard) mad_dg_register(h);",
          "if (cb && g_sd_state > 0 && g_fence_strict) mad_strict_cb_wait(s->queue->device, cb);",
          "if (g_sd_state > 0 && g_fence_strict >= 2) need = (UINT64)dv->gpu_serial_committed;")))
check("the replay's diagnostics run before the argument slot is taken (copies share its chunk)",
      SRC.index("if (g_sd_state > 0 && rs && root) root = mad_sd_root(") <
      SRC.index("    chunk = l->ring_used / (MAD_ARG_RING_BYTES / MAD_ARG_SLOT_BYTES);"))
check("a batch's ticket gets its serial under fence_lock, at the commit",
      re.search(r"q->last_serial = serial;.*\n\s*if \(q->open_ticket\) \{ mad_ticket_commit\(q->open_ticket, serial\); q->open_ticket = 0; \}.*\n\s*LeaveCriticalSection\(&sd->fence_lock\);", SRC) is not None)
fl = cut("static void mad_queue_flush(struct mad_queue *q) {")
check("upload-guard 2: the GPU copy is encoded into the batch before it is committed",
      fl.index("if (g_sd_state > 0 && g_upload_guard >= 2 && q->open_ticket) mad_ug_gpu_copy(q);") <
      fl.index("MTLCommandBuffer_commit(q->open_cb);"))
check("tickets and the strict GPU wait only on a NEW batch command buffer",
      "NSObject_retain(q->open_cb);\n            if (g_sd_state > 0) {" in SRC)
check("queue-trace defaults to 0", 'qt = mad_cfg_int_pe("queue-trace", 0);' in SRC)
check("queue-trace hooks are behind g_sd_state",
      SRC.count("if (g_sd_state > 0 && g_qtrace) mad_qtrace(") == 3)
check("typed-uav-atomic defaults to 0 and only adds ShaderAtomic to R32 UAV texture buffers",
      'on = mad_cfg_int_pe("typed-uav-atomic", 0) ? 1 : 0;' in SRC and
      "if (uav && (pf == WMTPixelFormatR32Uint || pf == WMTPixelFormatR32Sint) && mad_typed_uav_atomic())" in SRC)
check("typed-uav-atomic: a refusal falls back to the view as before",
      "ti.usage = (enum WMTTextureUsage)(ti.usage & ~WMTTextureUsageShaderAtomic); ti.gpu_resource_id = 0;" in SRC)
check("upload-guard covers CopyBufferRegion / CopyTextureRegion sources",
      SRC.count("if (g_sd_state > 0 && g_upload_guard)   /* madeira-bcd: ") == 2 and "MAD_UG_COPY, 0, 1, \"CopyBufferRegion\");" in SRC)
check("upload-guard walks descriptor tables (CBV / SRV ranges, never UAV)",
      "if (g_upload_guard && type == MADEIRA_IR_PARAM_TABLE)\n            mad_ug_note_table(" in SRC and
      "if (rs->ranges[ri].range_type != MADEIRA_IR_RANGE_CBV && rs->ranges[ri].range_type != MADEIRA_IR_RANGE_SRV) continue;" in SRC)
fw = cut("static DWORD WINAPI mad_fence_worker(void *arg) {")
check("fence worker: upload-guard verifies BEFORE the fence advances",
      fw.index("mad_ug_verify(d, job.serial);") < fw.index("ID3D12Fence_Signal(job.fence, job.value);"))
check("fence worker: a failed batch's serial is signalled on the CPU in strict mode",
      "if (g_fence_strict) MTLSharedEvent_signalValue(d->gpu_event, job.serial);" in fw)
qw = cut("static HRESULT STDMETHODCALLTYPE queue_Wait(ID3D12CommandQueue *This, ID3D12Fence *fence, UINT64 value) {")
check("Queue::Wait: unchanged fast path when fence-strict is off, commit wait when on",
      "if ((UINT64)f->submitted >= value) {" in qw and
      "if (g_fence_strict && (UINT64)f->committed < value && f->value < value) {" in qw and
      qw.index("if (g_fence_strict && (UINT64)f->committed") < qw.index("        return S_OK;\n    }\n    while (waited < 5000)"))
sa = cut("static int mad_signal_async(struct mad_queue *q, ID3D12Fence *fence, UINT64 value) {")
check("fence-strict 2 takes the synchronous Signal", "if (g_fence_strict >= 2) return 0;" in sa)
sr = cut("static HRESULT mad_signal_run(struct mad_queue *q, ID3D12Fence *fence, UINT64 value) {")
check("synchronous Signal: drain (strict 2) and verify before the fence advances",
      sr.index("mad_strict_drain(q->device);") < sr.index("return ID3D12Fence_Signal(fence, value);") and
      sr.index("mad_ug_verify(q->device, mad_gpu_completed(q->device));") < sr.index("return ID3D12Fence_Signal(fence, value);"))
pr = cut("static void mad_present_run(struct mad_swapchain *s, UINT idx) {")
check("Present: upload-guard verifies after the frame-latency wait, before returning",
      pr.index("MTLSharedEvent_waitUntilSignaledValue(dv->gpu_event, need, 1000);") <
      pr.index("if (g_upload_guard) mad_ug_verify(s->queue->device, mad_gpu_completed(s->queue->device));") <
      pr.index("drawable = MetalLayer_nextDrawable(s->layer);"))

SD0 = SRC.index("/* ---- madeira-bcd: SYNC DIAGNOSTICS")
SD1 = SRC.index("static int exec_arg_slot_for(struct mad_exec *e, const struct mad_rootsig *rs, const UINT64 *root,\n"
                "                             const UINT32 (*consts)[64], obj_handle_t *buf, UINT64 *off, const UINT *ovr, const struct mad_pso *pso) {")

SD_STUBS = r'''
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "madeira_ir_abi.h"
typedef long LONG; typedef long long LONG64; typedef unsigned long long UINT64; typedef unsigned UINT; typedef uint32_t UINT32;
typedef uint16_t UINT16; typedef uintptr_t ULONG_PTR; typedef uint64_t obj_handle_t;
typedef struct { int unused; } SRWLOCK;
#define SRWLOCK_INIT { 0 }
static void AcquireSRWLockExclusive(SRWLOCK *l) { (void)l; }
static void ReleaseSRWLockExclusive(SRWLOCK *l) { (void)l; }
static LONG InterlockedIncrement(volatile LONG *p) { return ++*p; }
static LONG64 InterlockedIncrement64(volatile LONG64 *p) { return ++*p; }
static LONG64 InterlockedExchangeAdd64(volatile LONG64 *p, LONG64 v) { LONG64 o = *p; *p += v; return o; }
static LONG InterlockedExchangeAdd(volatile LONG *p, LONG v) { LONG o = *p; *p += v; return o; }
#define MemoryBarrier() ((void)0)
#define MAD_ROOT_PARAM_MAX 32
#define MAD_ARG_RING_BYTES  (64u * 1024u)
#define MAD_ARG_SLOT_BYTES  1088u
enum { D3D12_HEAP_TYPE_DEFAULT = 1, D3D12_HEAP_TYPE_UPLOAD = 2, D3D12_HEAP_TYPE_READBACK = 3, D3D12_HEAP_TYPE_CUSTOM = 4 };
static unsigned g_list_seq = 77;
static int g_logs; static char g_last_log[512], g_logbuf[65536]; static size_t g_logbuf_n;
static void d3d12_log(const char *fmt, ...) {
    va_list ap; size_t n; va_start(ap, fmt); g_logs++; vsnprintf(g_last_log, sizeof g_last_log, fmt, ap); va_end(ap); fputs(g_last_log, stdout);
    n = strlen(g_last_log); if (g_logbuf_n + n < sizeof g_logbuf) { memcpy(g_logbuf + g_logbuf_n, g_last_log, n + 1); g_logbuf_n += n; }
}
static long long g_cfg[11]; /* fence-strict, upload-guard, upload-guard-bytes (0 = unset), desc-guard, cbv-snapshot, queue-trace, ind-count, ind-count-from,
                               gpu-sync, pso-first-use, present-min-ms */
static long long mad_cfg_int_pe(const char *key, long long dflt) {
    static const char *const k[11] = { "fence-strict", "upload-guard", "upload-guard-bytes", "desc-guard", "cbv-snapshot", "queue-trace", "ind-count", "ind-count-from",
                                       "gpu-sync", "pso-first-use", "present-min-ms" };
    int i; for (i = 0; i < 11; i++) if (!strcmp(key, k[i])) return g_cfg[i] ? g_cfg[i] : dflt;
    return dflt;
}
/* rcas-fill (FSR sharpening when PoE2 gives none) reads its strength as text in this region: unset here */
static int mad_cfg_str_pe(const char *key, char *out, size_t cap) { (void)key; (void)out; (void)cap; return 0; }
struct mad_device { obj_handle_t gpu_event, mtl_device; volatile LONG64 gpu_serial_committed, gpu_serial_failed; };
static UINT64 g_completed;
static UINT64 mad_gpu_completed(struct mad_device *d) { (void)d; return g_completed; }
struct mad_resource { LONG refs; void *cpu; UINT64 size, gpu_address; int heap; unsigned serial; void *own_mem; obj_handle_t buffer; };
#define ID3D12Resource_AddRef(r) (++((struct mad_resource *)(r))->refs)
#define ID3D12Resource_Release(r) (--((struct mad_resource *)(r))->refs)
typedef struct mad_resource ID3D12Resource;
static struct mad_resource *g_res[4]; static unsigned g_nres;
static void *mad_res_mem(obj_handle_t h) { unsigned i; for (i = 0; i < g_nres; i++) if (g_res[i]->buffer == h) return g_res[i]->cpu; return NULL; }
static struct mad_resource *mad_resolve_address(struct mad_device *d, UINT64 addr, UINT64 *off) {
    unsigned i; (void)d;
    for (i = 0; i < g_nres; i++) if (addr >= g_res[i]->gpu_address && addr < g_res[i]->gpu_address + g_res[i]->size) { *off = addr - g_res[i]->gpu_address; return g_res[i]; }
    return NULL;
}
struct mad_pso { char vs_name[64], ps_name[64]; };
struct mad_queue { struct mad_device *device; UINT64 open_ticket; obj_handle_t open_cb; unsigned type; };
struct mad_fence { UINT64 value; volatile LONG64 submitted, committed; };
static unsigned long GetCurrentThreadId(void) { return 0x2a; }
/* Metal stand-ins for upload-guard 2: a buffer handle is its index + 1 in g_mbuf; a blit runs at once */
struct WMTMemoryPointer { void *ptr; };
enum WMTResourceOptions { WMTResourceStorageModeShared = 0 };
struct WMTBufferInfo { uint64_t length; enum WMTResourceOptions options; struct WMTMemoryPointer memory; uint64_t gpu_address; };
struct wmtcmd_base { int type; uint16_t reserved[3]; struct WMTMemoryPointer next; };
enum { WMTBlitCommandCopyFromBufferToBuffer = 3 };
struct wmtcmd_blit_copy_from_buffer_to_buffer { int type; uint16_t reserved[3]; struct WMTMemoryPointer next;
    obj_handle_t src; uint64_t src_offset; obj_handle_t dst; uint64_t dst_offset; uint64_t copy_length; };
static void *g_mbuf[64]; static int g_nmbuf, g_mbuf_live, g_blits;
static obj_handle_t MTLDevice_newBuffer(obj_handle_t dev, struct WMTBufferInfo *bi) {
    (void)dev; g_mbuf[g_nmbuf] = calloc(1, bi->length); bi->memory.ptr = g_mbuf[g_nmbuf]; g_mbuf_live++; return (obj_handle_t)++g_nmbuf;
}
static void NSObject_release(obj_handle_t h) { free(g_mbuf[h - 1]); g_mbuf[h - 1] = NULL; g_mbuf_live--; }
static obj_handle_t MTLCommandBuffer_blitCommandEncoder(obj_handle_t cb) { return cb ? 0x8000 : 0; }
static void MTLCommandEncoder_endEncoding(obj_handle_t enc) { (void)enc; }
static void *mad_res_mem(obj_handle_t h);
static void MTLBlitCommandEncoder_encodeCommands(obj_handle_t enc, const struct wmtcmd_base *c) {
    (void)enc;
    for (; c; c = (const struct wmtcmd_base *)c->next.ptr) {
        const struct wmtcmd_blit_copy_from_buffer_to_buffer *k = (const void *)c;
        memcpy((char *)g_mbuf[k->dst - 1] + k->dst_offset, (char *)mad_res_mem(k->src) + k->src_offset, k->copy_length); g_blits++;
    }
}
struct mad_list { unsigned ring_used, nrings; obj_handle_t *rings; void **ring_cpu; UINT64 *ring_gpu; };
enum WMTIndexType { WMTIndexTypeUInt16 = 0, WMTIndexTypeUInt32 = 1 };
enum mad_ck { MC_DRAW = 1, MC_DRAW_INDEXED };
struct mad_cmd { enum mad_ck kind; union { struct { UINT vcount, icount, vstart, istart; } draw; struct { UINT icount, inst, start; int base; UINT istart; } drawi; } u; };
struct mad_heap;
struct mad_exec {
    struct mad_queue *q; struct mad_list *l; struct mad_pso *pso;
    struct { struct mad_resource *res; UINT64 off; UINT stride; } vb[16]; struct mad_resource *ib; UINT64 ib_off; enum WMTIndexType ib_type;
    UINT64 dg_va[MAD_ROOT_PARAM_MAX]; UINT dg_n[MAD_ROOT_PARAM_MAX];
    UINT64 sn_src[8], sn_dst[8]; unsigned sn_chunk[8], sn_n;
    struct mad_heap *srv; UINT64 ug_va[MAD_ROOT_PARAM_MAX];
};
struct mad_rootsig { struct madeira_ir_root_param params[MAD_ROOT_PARAM_MAX]; struct madeira_ir_root_range *ranges; UINT nparams, nranges; };
struct mad_descriptor { UINT64 gpu_va, texture_view_id, metadata; };
struct mad_heap { struct mad_descriptor *cpu; UINT64 gpu_address; UINT count; int type; struct mad_device *owner; };
static int mad_list_ring_grow(struct mad_exec *e) {
    struct mad_list *l = e->l; void *mem = aligned_alloc(4096, MAD_ARG_RING_BYTES);
    if (!mem) return 0;
    l->rings = realloc(l->rings, (l->nrings + 1) * sizeof *l->rings); l->ring_cpu = realloc(l->ring_cpu, (l->nrings + 1) * sizeof *l->ring_cpu);
    l->ring_gpu = realloc(l->ring_gpu, (l->nrings + 1) * sizeof *l->ring_gpu);
    l->rings[l->nrings] = 0x1000 + l->nrings; l->ring_cpu[l->nrings] = mem; l->ring_gpu[l->nrings] = 0x7000000000ull + (UINT64)l->nrings * 0x100000; l->nrings++;
    return 1;
}
static UINT64 g_waited_for; static int g_waits;
static void MTLCommandBuffer_encodeWaitForEvent(obj_handle_t cb, obj_handle_t ev, UINT64 v) { (void)cb; (void)ev; g_waits++; g_waited_for = v; }
static int MTLSharedEvent_waitUntilSignaledValue(obj_handle_t ev, UINT64 v, UINT64 t) { (void)ev; (void)t; return g_completed >= v; }
'''

SD_HARNESS = r'''
#define T(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); return 1; } } while (0)
static void load(long long fs, long long ug, long long ub, long long dg, long long cs) {
    g_cfg[0] = fs; g_cfg[1] = ug; g_cfg[2] = ub; g_cfg[3] = dg; g_cfg[4] = cs; g_cfg[5] = 0; g_sd_state = -1; mad_sync_diag_load();
}
int main(void) {
    struct mad_device dev; struct mad_queue q; struct mad_list l; struct mad_exec e; struct mad_pso pso;
    static unsigned char up[8192], def_dummy[16]; struct mad_resource ru, rd, rr;
    unsigned i; UINT64 t1, t2, s = 0;
    memset(&dev, 0, sizeof dev); dev.gpu_event = 0x55;
    memset(&q, 0, sizeof q); q.device = &dev; memset(&l, 0, sizeof l);
    memset(&e, 0, sizeof e); e.q = &q; e.l = &l; e.pso = &pso;
    memset(&pso, 0, sizeof pso); strcpy(pso.vs_name, "vs_HighLod"); strcpy(pso.ps_name, "ps_SetMaterial_techDefault");
    for (i = 0; i < sizeof up; i++) up[i] = (unsigned char)(i * 7 + 1);
    memset(&ru, 0, sizeof ru); ru.cpu = up; ru.size = sizeof up; ru.gpu_address = 0x200000; ru.heap = D3D12_HEAP_TYPE_UPLOAD; ru.serial = 41;
    memset(&rd, 0, sizeof rd); rd.cpu = NULL; rd.size = 4096; rd.gpu_address = 0x400000; rd.heap = D3D12_HEAP_TYPE_DEFAULT;
    memset(&rr, 0, sizeof rr); rr.cpu = def_dummy; rr.size = sizeof def_dummy; rr.gpu_address = 0x600000; rr.heap = D3D12_HEAP_TYPE_READBACK;
    g_res[0] = &ru; g_res[1] = &rd; g_res[2] = &rr; g_nres = 3;

    /* 1. unset: everything off, nothing logged */
    g_logs = 0; load(0, 0, 0, 0, 0);
    T(g_sd_state == 0 && !g_fence_strict && !g_upload_guard && !g_desc_guard && !g_cbv_snap && g_ug_bytes == 256 && g_logs == 0);
    /* clamps */
    load(7, 1, 3, 1, 1);    T(g_fence_strict == 2 && g_upload_guard && g_ug_bytes == 16 && g_desc_guard && g_cbv_snap == 4096 && g_sd_state == 1);
    load(1, 0, 99999, 0, 300);  T(g_fence_strict == 1 && g_ug_bytes == 4096 && g_cbv_snap == 512);
    load(0, 0, 0, 0, 99999);    T(g_cbv_snap == 16384 && g_fence_strict == 0);
    load(0, 0, 0, 0, 100);      T(g_cbv_snap == 256);

    /* 2. tickets */
    t1 = mad_ticket_new(); T(t1 && mad_ticket_state(t1, &s) == 0 && !mad_ticket_done(&dev, t1));
    mad_ticket_commit(t1, 7); T(mad_ticket_state(t1, &s) == 1 && s == 7);
    g_completed = 6; T(!mad_ticket_done(&dev, t1)); g_completed = 7; T(mad_ticket_done(&dev, t1));
    T(mad_ticket_done(&dev, 0));
    g_tk_next += MAD_TK_RING - 1; t2 = mad_ticket_new(); T(t2 % MAD_TK_RING == t1 % MAD_TK_RING);
    mad_ticket_commit(t2, 9); T(mad_ticket_state(t1, &s) == 2 && mad_ticket_done(&dev, t1));

    /* 3. upload-guard */
    load(0, 1, 0, 0, 0); g_completed = 0;
    q.open_ticket = mad_ticket_new();
    mad_ug_note(&e, &ru, 256, 256, MAD_UG_CBV, 1, 1, "ps_X"); mad_ug_note(&e, &ru, 256, 256, MAD_UG_CBV, 1, 1, "ps_X");   /* same range, same batch: one record */
    mad_ug_note(&e, &rd, 0, 256, MAD_UG_CBV, 2, 1, "ps_X");   /* GPU-only: not watched */
    mad_ug_note(&e, &rr, 0, 256, MAD_UG_SRV, 3, 0, "ps_X");   /* READBACK: the GPU writes it, not watched */
    T(g_ug_n == 1 && ru.refs == 1 && g_sd_ug_noted == 1 && g_ug[0].len == 256);
    mad_ug_verify(&dev, 1000); T(g_sd_ug_checked == 0 && g_ug_n == 1);          /* not committed yet: left alone */
    mad_ticket_commit(q.open_ticket, 20); q.open_ticket = 0;
    mad_ug_verify(&dev, 19); T(g_sd_ug_checked == 0 && g_ug_n == 1);            /* GPU not past its serial */
    mad_ug_verify(&dev, 20); T(g_sd_ug_checked == 1 && g_sd_ug_changed == 0 && g_ug_n == 0 && ru.refs == 0);
    q.open_ticket = mad_ticket_new();
    mad_ug_note(&e, &ru, 1024, 256, MAD_UG_CBV, 0, 1, "ps_Y");
    {   /* a non-indexed draw: its vertex buffer as an approximate window; an indexed one: exactly its indices */
        struct mad_cmd c; memset(&c, 0, sizeof c); c.kind = MC_DRAW;
        e.vb[1].res = &ru; e.vb[1].off = 4096; e.ib = &ru; e.ib_off = 6144; e.ib_type = WMTIndexTypeUInt16;
        mad_ug_note_draw(&e, &c); T(g_ug_n == 2 && !g_ug[1].exact && g_ug[1].kind == MAD_UG_VB);
        c.kind = MC_DRAW_INDEXED; c.u.drawi.start = 10; c.u.drawi.icount = 20;
        mad_ug_note_draw(&e, &c); T(g_ug_n == 3 && g_ug[2].exact && g_ug[2].kind == MAD_UG_IB && g_ug[2].off == 6144 + 20 && g_ug[2].len == 40);
        e.vb[1].res = NULL; e.ib = NULL;
    }
    T(g_ug_n == 3 && ru.refs == 3);
    up[1024 + 100] ^= 0x5a;                                                     /* the game rewrites a constant the GPU still reads */
    up[4096 + 200] ^= 0x5a;                                                     /* ... and something inside the vertex window */
    mad_ticket_commit(q.open_ticket, 21); q.open_ticket = 0; g_logs = 0;
    mad_ug_verify(&dev, 21);
    T(g_sd_ug_changed == 1 && g_sd_ug_changed_approx == 1 && g_sd_ug_checked == 4 && g_ug_n == 0 && ru.refs == 0 && g_logs == 2);
    T(strstr(g_last_log, "(approximate window: may be data placed after it): vertex buffer 1 of 'vs_HighLod'") != NULL);
    {   /* the exact one is reported as such */
        static char first[512]; g_logs = 0; up[1024 + 101] ^= 1; q.open_ticket = mad_ticket_new();
        mad_ug_note(&e, &ru, 1024, 256, MAD_UG_CBV, 0, 1, "ps_Y"); up[1024 + 101] ^= 1;
        mad_ticket_commit(q.open_ticket, 21); q.open_ticket = 0; mad_ug_verify(&dev, 21); strcpy(first, g_last_log);
        T(g_logs == 1 && strstr(first, "[upload-guard] CHANGED while the GPU used it: root CBV 0 of 'ps_Y'") && strstr(first, "r#41") && strstr(first, "+1024"));
    }
    T(!mad_ug_cpu_written(&rd) && !mad_ug_cpu_written(&rr) && mad_ug_cpu_written(&ru));
    /* upload-guard 2: the GPU copies the ranges at the batch end; a copy that differs from unchanged CPU bytes is reported */
    load(0, 2, 0, 0, 0); T(g_upload_guard == 2);
    ru.buffer = 0x9001; q.open_cb = 0x4242;
    q.open_ticket = mad_ticket_new();
    mad_ug_note(&e, &ru, 2048, 256, MAD_UG_CBV, 0, 1, "ps_Z"); mad_ug_note(&e, &ru, 3072, 256, MAD_UG_SRV, 1, 0, "ps_Z");
    mad_ug_gpu_copy(&q);
    T(g_blits == 2 && g_sd_ug_gpu_copied == 2 && g_mbuf_live == 1 && g_ug[0].gv && g_ug[0].gv == g_ug[1].gv && g_ug[0].gv->refs == 2);
    T(!memcmp(g_mbuf[g_nmbuf - 1], up + 2048, 256) && !memcmp((char *)g_mbuf[g_nmbuf - 1] + 256, up + 3072, 256));
    ((unsigned char *)g_mbuf[g_nmbuf - 1])[256 + 8] ^= 1;   /* what the GPU read is not what the CPU wrote */
    mad_ticket_commit(q.open_ticket, 22); q.open_ticket = 0; g_logs = 0;
    mad_ug_verify(&dev, 22);
    T(g_sd_ug_gpu_diff == 1 && g_sd_ug_changed == 2 && g_logs == 1 && strstr(g_last_log, "GPU SAW DIFFERENT BYTES"));
    T(strstr(g_last_log, "root SRV 1 of 'ps_Z'") && strstr(g_last_log, "first difference at +8"));
    T(g_ug_n == 0 && g_mbuf_live == 0 && ru.refs == 0);
    ru.buffer = 0;

    /* 4. desc-guard */
    {
        static struct mad_descriptor heapmem[64]; struct mad_heap h; struct mad_rootsig rs; struct madeira_ir_root_range rg[3];
        memset(&h, 0, sizeof h); h.cpu = heapmem; h.gpu_address = 0x900000; h.count = 64; h.type = 0; h.owner = &dev;
        load(0, 0, 0, 1, 0); mad_dg_register(&h); T(g_dg_n == 1 && g_dg[0].tag && g_dg[0].count == 64);
        memset(&rs, 0, sizeof rs); memset(rg, 0, sizeof rg); rs.ranges = rg; rs.nranges = 3; rs.nparams = 2;
        rs.params[0].type = MADEIRA_IR_PARAM_TABLE; rs.params[0].first_range = 0; rs.params[0].num_ranges = 2;
        rg[0].num_descriptors = 4; rg[0].table_offset = 0xffffffffu; rg[1].num_descriptors = 2; rg[1].table_offset = 8;
        rs.params[1].type = MADEIRA_IR_PARAM_TABLE; rs.params[1].first_range = 2; rs.params[1].num_ranges = 1;
        rg[2].num_descriptors = 0xffffffffu; rg[2].table_offset = 0;   /* bindless: not tracked */
        T(mad_dg_extent(&rs, 0) == 10 && mad_dg_extent(&rs, 1) == 0);
        q.open_ticket = t1 = mad_ticket_new(); g_completed = 30;
        mad_dg_mark(&e, &rs, 0, h.gpu_address + 3 * sizeof(struct mad_descriptor));
        T(g_dg[0].tag[2] == 0 && g_dg[0].tag[3] == t1 && g_dg[0].tag[12] == t1 && g_dg[0].tag[13] == 0);
        g_logs = 0;
        mad_dg_write(&heapmem[20], 1, "CreateShaderResourceView"); T(g_sd_dg_inflight == 0);   /* never referenced */
        mad_dg_write(&heapmem[5], 2, "CopyDescriptorsSimple");    T(g_sd_dg_inflight == 2 && g_logs == 2);
        T(strstr(g_last_log, "still being recorded") != NULL);
        mad_ticket_commit(t1, 31); q.open_ticket = 0;
        mad_dg_write(&heapmem[4], 1, "CopyDescriptors");          T(g_sd_dg_inflight == 3 && strstr(g_last_log, "runs (serial 31, GPU at 30)"));
        g_completed = 31;
        mad_dg_write(&heapmem[4], 1, "CopyDescriptors");          T(g_sd_dg_inflight == 3);     /* finished: fine */
        mad_dg_write(def_dummy, 1, "CreateSampler");               T(g_sd_dg_inflight == 3);     /* not a watched heap */
        load(0, 0, 0, 0, 0); mad_dg_write(&heapmem[5], 1, "x");   T(g_sd_dg_inflight == 3);     /* off */
    }

    /* 5. cbv-snapshot */
    {
        struct mad_rootsig rs; UINT64 root[MAD_ROOT_PARAM_MAX], tmp[MAD_ROOT_PARAM_MAX]; const UINT64 *out; unsigned used;
        memset(&rs, 0, sizeof rs); memset(root, 0, sizeof root);
        rs.nparams = 4; rs.params[0].type = MADEIRA_IR_PARAM_CBV; rs.params[1].type = MADEIRA_IR_PARAM_TABLE;
        rs.params[2].type = MADEIRA_IR_PARAM_CBV; rs.params[3].type = MADEIRA_IR_PARAM_CONSTANTS;
        root[0] = ru.gpu_address + 512; root[1] = 0x900000; root[2] = rd.gpu_address; root[3] = 0;
        load(0, 0, 0, 0, 0); T(mad_sd_root(&e, &rs, root, tmp, &pso) == root);   /* off: the caller's values */
        load(0, 0, 0, 0, 1);
        out = mad_sd_root(&e, &rs, root, tmp, &pso);
        T(out == tmp && tmp[1] == root[1] && tmp[2] == root[2] && tmp[0] != root[0] && (tmp[0] & 255) == 0);
        T(tmp[0] >= l.ring_gpu[0] && tmp[0] + 4096 <= l.ring_gpu[0] + MAD_ARG_RING_BYTES);
        T(!memcmp((unsigned char *)l.ring_cpu[0] + (tmp[0] - l.ring_gpu[0]), up + 512, 4096));
        T(g_sd_snaps == 1 && l.ring_used == 4);
        used = l.ring_used;
        out = mad_sd_root(&e, &rs, root, tmp, &pso); T(l.ring_used == used && g_sd_snaps == 1);   /* same range, same chunk: reused */
        /* near the end of a chunk: the copies (4 slots) and the argument slot (1) move to the next chunk together */
        l.ring_used = 58; e.sn_n = 0;
        out = mad_sd_root(&e, &rs, root, tmp, &pso);
        T(l.ring_used == 60 + 4 && tmp[0] >= l.ring_gpu[1] && tmp[0] < l.ring_gpu[1] + MAD_ARG_RING_BYTES && g_sd_snaps == 2);
        /* the tail of a buffer: only what is left of it is copied */
        root[0] = ru.gpu_address + sizeof up - 256; e.sn_n = 0;
        out = mad_sd_root(&e, &rs, root, tmp, &pso);
        T(g_sd_snap_bytes == 4096 + 4096 + 256 && !memcmp((unsigned char *)l.ring_cpu[1] + (tmp[0] - l.ring_gpu[1]), up + sizeof up - 256, 256));
    }

    /* 5b. upload-guard over descriptor tables: the descriptors themselves, and table CBVs into UPLOAD memory */
    {
        static struct mad_descriptor dh[64]; struct mad_heap h; struct mad_rootsig rs; struct madeira_ir_root_range rg[2]; struct mad_cmd c;
        memset(&h, 0, sizeof h); h.cpu = dh; h.gpu_address = 0xa00000; h.count = 64; h.owner = &dev;
        memset(&rs, 0, sizeof rs); memset(rg, 0, sizeof rg); rs.ranges = rg; rs.nranges = 2; rs.nparams = 1;
        rs.params[0].type = MADEIRA_IR_PARAM_TABLE; rs.params[0].first_range = 0; rs.params[0].num_ranges = 2;
        rg[0].range_type = MADEIRA_IR_RANGE_CBV; rg[0].num_descriptors = 2; rg[0].table_offset = 0xffffffffu;
        rg[1].range_type = MADEIRA_IR_RANGE_SRV; rg[1].num_descriptors = 2; rg[1].table_offset = 0xffffffffu;
        dh[10].gpu_va = ru.gpu_address + 4096; dh[10].metadata = 512;    /* table CBV 0 -> UPLOAD +4096, 512 bytes */
        dh[11].gpu_va = rd.gpu_address; dh[11].metadata = 256;           /* table CBV 1 -> GPU-only: not watched */
        dh[12].texture_view_id = 0x77;                                    /* a texture SRV: nothing to hash */
        dh[13].gpu_va = ru.gpu_address + 6144; dh[13].metadata = 64;      /* a buffer SRV of 64 bytes */
        load(0, 1, 0, 0, 0); memset(&c, 0, sizeof c); (void)c;
        e.srv = &h; memset(e.ug_va, 0, sizeof e.ug_va); g_logs = 0;
        q.open_ticket = mad_ticket_new();
        {
            UINT64 root[MAD_ROOT_PARAM_MAX], tmp[MAD_ROOT_PARAM_MAX]; LONG tables0 = g_sd_ug_tables;
            memset(root, 0, sizeof root); root[0] = h.gpu_address + 10 * sizeof(struct mad_descriptor);
            T(mad_sd_root(&e, &rs, root, tmp, &pso) == root);
            T(g_sd_ug_tables == tables0 + 1 && g_ug_n == 3);
            T(g_ug[0].r == NULL && g_ug[0].kind == MAD_UG_TABLE && g_ug[0].slot == 10 && g_ug[0].len == 4 * 24);
            T(g_ug[1].r == &ru && g_ug[1].kind == MAD_UG_TCBV && g_ug[1].off == 4096 && g_ug[1].len == 256 && g_ug[1].exact);
            T(g_ug[2].r == &ru && g_ug[2].kind == MAD_UG_TSRV && g_ug[2].off == 6144 && g_ug[2].len == 64 && g_ug[2].exact);
            mad_sd_root(&e, &rs, root, tmp, &pso); T(g_ug_n == 3);   /* same table in the same replay: once */
        }
        up[4096 + 17] ^= 1; dh[13].metadata = 65;   /* a constant AND a descriptor rewritten while the batch runs */
        mad_ticket_commit(q.open_ticket, 40); q.open_ticket = 0;
        {
            LONG ch0 = g_sd_ug_changed, dc0 = g_sd_ug_desc_changed;
            mad_ug_verify(&dev, 40);
            T(g_sd_ug_changed == ch0 + 1 && g_sd_ug_desc_changed == dc0 + 1 && g_ug_n == 0 && ru.refs == 0 && g_logs == 2);
        }
        e.srv = NULL; up[4096 + 17] ^= 1;
        /* a CopyBufferRegion source in UPLOAD memory, rewritten before the copy ran */
        q.open_ticket = mad_ticket_new(); g_logs = 0;
        mad_ug_note(&e, &ru, 7168, 128, MAD_UG_COPY, 0, 1, "CopyBufferRegion"); up[7168 + 3] ^= 1;
        mad_ticket_commit(q.open_ticket, 41); q.open_ticket = 0; mad_ug_verify(&dev, 41);
        T(g_logs == 1 && strstr(g_last_log, "copy source 0 of 'CopyBufferRegion'") && ru.refs == 0);
        up[7168 + 3] ^= 1;
    }

    /* 5c. queue-trace: the first N calls, then one limit line */
    {
        struct mad_fence f; memset(&f, 0, sizeof f); f.value = 5; f.submitted = 7; f.committed = 6;
        g_cfg[0] = g_cfg[1] = g_cfg[2] = g_cfg[3] = g_cfg[4] = 0; g_cfg[5] = 3; g_sd_state = -1; mad_sync_diag_load();
        T(g_sd_state == 1 && g_qtrace == 3);
        q.type = 2; g_logs = 0;
        mad_qtrace("Signal", &q, &f, 7, 0); T(strstr(g_last_log, "tid 002a") && strstr(g_last_log, "(type 2) Signal") && strstr(g_last_log, "asked 7, committed 6"));
        mad_qtrace("ExecuteCommandLists", &q, NULL, 0, 3); T(strstr(g_last_log, "ExecuteCommandLists 3 list(s)"));
        mad_qtrace("Wait", &q, &f, 7, 0); T(strstr(g_last_log, "limit of 3 lines"));
        mad_qtrace("Wait", &q, &f, 7, 0); T(g_logs == 4);   /* 3 lines + the limit line, then silence */
        g_cfg[5] = 1; g_sd_state = -1; mad_sync_diag_load(); T(g_qtrace == 400);
        g_cfg[5] = 0; g_sd_state = -1; mad_sync_diag_load(); T(g_sd_state == 0 && g_qtrace == 0);
    }

    /* 5d. ind-count: per-frame sums, the frame table, one-frame dips (and the end of the window) */
    {
        static UINT32 rec[64 * 5]; static const unsigned grass_n[7] = { 40, 40, 40, 20, 40, 40, 40 };   /* frame 103: half the grass culled away */
        UINT32 disp[3] = { 8, 4, 1 }; unsigned k, f;
        const void *grass = (const void *)0x1000, *rock = (const void *)0x2000, *cull = (const void *)0x3000;
        g_cfg[0] = g_cfg[1] = g_cfg[2] = g_cfg[3] = g_cfg[4] = g_cfg[5] = g_cfg[6] = g_cfg[7] = 0;
        g_sd_state = -1; g_logs = 0; mad_sync_diag_load(); T(g_sd_state == 0 && g_ic_frames == 0 && g_logs == 0);   /* unset: off, silent */
        g_cfg[6] = 1; g_sd_state = -1; mad_sync_diag_load(); T(g_sd_state == 1 && g_ic_frames == 3000 && g_ic_from == 0);
        g_cfg[6] = 6; g_cfg[7] = 101; g_sd_state = -1; mad_sync_diag_load(); T(g_ic_frames == 6 && g_ic_from == 101);
        for (k = 0; k < 64; k++) { rec[k * 5] = k < 40 ? 36 : 0; rec[k * 5 + 1] = 10; }   /* {index count, instances, ...}; 0 indices draws nothing */
        g_logbuf_n = 0; g_logbuf[0] = 0;
        for (f = 0; f < 7; f++) {   /* frames 100 (before ind-count-from: compared, not logged) .. 106 */
            unsigned skip = 40 - grass_n[f];
            mad_ic_add(100 + f, grass, "vs_Grass|ps_Grass", MAD_IC_DRAW_INDEXED, rec + skip * 5, 64 - skip, 5, 0);
            if (f != 4) mad_ic_add(100 + f, rock, "vs_Rock|ps_Rock", MAD_IC_DRAW_INDEXED, rec, 3, 5, 0);   /* absent in frame 104 */
            mad_ic_add(100 + f, cull, "cs_main/00112233aabbccdd", MAD_IC_DISPATCH, disp, 1, 3, 0);
        }
        mad_ic_add(200, cull, "cs_main/00112233aabbccdd", MAD_IC_DISPATCH, disp, 1, 3, 0);   /* the next frame flushes 106 */
        mad_ic_add(201, cull, "cs_main/00112233aabbccdd", MAD_IC_DISPATCH, disp, 1, 3, 0);   /* past the window: silent */
        T(g_ic_logged == 6 && g_ic_flagged == 2);
        T(!strstr(g_logbuf, "frame #100:") && strstr(g_logbuf, "frame #101:") && strstr(g_logbuf, "frame #106:") && !strstr(g_logbuf, "frame #200:"));
        T(strstr(g_logbuf, "[ind-count] frame #101: 2 indirect draws (67 records, 43 non-empty, 430 instances), 1 indirect dispatches (32 threadgroups); 3 pipelines\n"));
        T(strstr(g_logbuf, "[ind-count] frame #103: 2 indirect draws (47 records, 23 non-empty, 230 instances)"));
        T(strstr(g_logbuf, "[ind-count] DIP at frame #103: draw-indexed 'vs_Grass|ps_Grass' 400 -> 200 -> 400 instances (frames #102..#104)"));
        T(strstr(g_logbuf, "[ind-count] DIP at frame #104: draw-indexed 'vs_Rock|ps_Rock' 30 -> 0 -> 30 instances"));
        T(strstr(g_logbuf, "cs_main/00112233aabbccdd") && strstr(g_logbuf, "threadgroups 32\n"));   /* the table, once, at the first frame */
        T(strstr(g_logbuf, "[ind-count] 6 frames logged; 2 dips/spikes; 0 commands not copied"));
        T(mad_ic_odd(100, 79, 100) == -1 && mad_ic_odd(100, 81, 100) == 0 && mad_ic_odd(10, 3, 10) == 0 && mad_ic_odd(100, 126, 90) == 1 && mad_ic_odd(4, 0, 4) == 0);
        g_cfg[6] = g_cfg[7] = 0; g_sd_state = -1; mad_sync_diag_load(); T(g_sd_state == 0 && g_ic_frames == 0);
    }

    /* 5e. round 4: gpu-sync, pso-first-use, present-min-ms -- each alone turns the family on, clamps, one log line */
    {
        memset(g_cfg, 0, sizeof g_cfg);
        g_sd_state = -1; g_logs = 0; mad_sync_diag_load(); T(g_sd_state == 0 && !g_gpu_sync && !g_pso_first && !g_present_min_ms && g_logs == 0);
        g_cfg[8] = 1; g_sd_state = -1; g_logs = 0; mad_sync_diag_load();
        T(g_sd_state == 1 && g_gpu_sync == 1 && g_logs == 1 && strstr(g_last_log, "gpu-sync=1 pso-first-use=0 present-min-ms=0"));
        g_cfg[8] = 0; g_cfg[9] = 7; g_sd_state = -1; mad_sync_diag_load(); T(g_sd_state == 1 && g_pso_first == 1 && !g_gpu_sync);
        g_cfg[9] = 0; g_cfg[10] = 200; g_sd_state = -1; mad_sync_diag_load(); T(g_sd_state == 1 && g_present_min_ms == 200);
        g_cfg[10] = 99999; g_sd_state = -1; mad_sync_diag_load(); T(g_present_min_ms == 2000);
        g_cfg[10] = -5; g_sd_state = -1; mad_sync_diag_load(); T(g_present_min_ms == 0 && g_sd_state == 0);
        g_cfg[8] = 1; g_sd_state = -1; mad_sync_diag_load(); g_logs = 0; mad_sd_report(300);
        T(g_logs == 2 && strstr(g_last_log, "[sync-diag] present #300: gpu-sync 0 ExecuteCommandLists waited for the GPU"));
        memset(g_cfg, 0, sizeof g_cfg); g_sd_state = -1; mad_sync_diag_load(); g_logs = 0; mad_sd_report(600); T(g_logs == 1);
    }

    /* 6. fence-strict helpers */
    load(1, 0, 0, 0, 0); g_waits = 0;
    dev.gpu_serial_committed = 0; mad_strict_cb_wait(&dev, 0x77); T(g_waits == 0);
    dev.gpu_serial_committed = 44; mad_strict_cb_wait(&dev, 0x77); T(g_waits == 1 && g_waited_for == 44);
    g_completed = 44; mad_strict_drain(&dev); g_completed = 43; dev.gpu_serial_failed = 44; mad_strict_drain(&dev);   /* returns: reached / failed */
    printf("sync harness ok\n");
    return 0;
}
'''

code = SD_STUBS + "\n" + cut("static int mad_grow(void **arr, unsigned *cap, unsigned need, size_t elem)") + "\n"
code += cut("static int exec_ring_take_z(struct mad_exec *e, unsigned n, size_t zero_bytes, obj_handle_t *buf, UINT64 *off, void **cpu, UINT64 *gpu) {") + "\n"
code += SRC[SD0:SD1] + SD_HARNESS
if not cc:
    print("SKIP: no host C compiler for the sync-diagnostics harness")
else:
    with tempfile.TemporaryDirectory() as t:
        c = pathlib.Path(t) / "sd.c"
        c.write_text(code)
        exe = pathlib.Path(t) / "sd"
        p = subprocess.run([cc, "-std=c11", "-Wall", "-Wno-unused-function", "-Wno-unused-variable",
                            "-I", str(R / "madeira-d3d12/src"), "-o", str(exe), str(c), "-lm"], capture_output=True, text=True)
        check("sync harness compiles", p.returncode == 0)
        if p.returncode:
            print(p.stderr[-4000:])
        else:
            r = subprocess.run([str(exe)], capture_output=True, text=True)
            check("fence-strict / upload-guard / desc-guard / cbv-snapshot behave (" + (r.stdout.strip().splitlines() or ["?"])[-1] + ")",
                  r.returncode == 0 and "sync harness ok" in r.stdout)
            if r.returncode:
                print(r.stdout[-4000:])

# --- round 3: ind-count, capture-cs by hash, sampler reduction ----
check("ind-count / ind-count-from default to 0",
      'ic = mad_cfg_int_pe("ind-count", 0);' in SRC and 'icf = mad_cfg_int_pe("ind-count-from", 0);' in SRC)
check("ind-count: the replay hook is behind g_sd_state and the key",
      "if (g_sd_state > 0 && g_ic_frames) mad_ic_note(&e, c);   /* madeira-bcd: ind-count */" in SRC)
check("ind-count: the copies are made when an encoder ends, after it is ended",
      "if (e->nic) mad_ic_encode(e);" in cut("static void exec_end(struct mad_exec *e) {") and
      cut("static void exec_end(struct mad_exec *e) {").index("if (e->cenc) { MTLCommandEncoder_endEncoding(e->cenc); e->cenc = 0; }") <
      cut("static void exec_end(struct mad_exec *e) {").index("if (e->nic) mad_ic_encode(e);"))
check("ind-count: batches get a ticket, Present collects",
      "if (g_upload_guard || g_desc_guard || g_ic_frames) q->open_ticket = mad_ticket_new();" in SRC and
      "if (g_ic_frames) mad_ic_collect(s->queue->device);" in pr)
ie = cut("static void mad_ic_encode(struct mad_exec *e) {")
check("ind-count: the blit waits and updates the encoder fence like every other encoder",
      ie.index("exec_fence_blit(e, benc, 0);") < ie.index("MTLBlitCommandEncoder_encodeCommands(benc") < ie.index("exec_fence_blit(e, benc, 1);"))
check("capture-cs: a plain name matches as before, name/hash picks one kernel",
      "mad_cs_match(e->cpso, g_capture_cs)" in SRC and "if (!slash) return !strcmp(p->vs_name, want);" in SRC)
check("sampler-reduction / sampler-census default to 0",
      'v = mad_cfg_int_pe("sampler-reduction", 0);' in SRC and 'g_smp_census = mad_cfg_int_pe("sampler-census", 0) ? 1 : 0;' in SRC)
check("gpu-sync / pso-first-use / present-min-ms default to 0",
      'gs = mad_cfg_int_pe("gpu-sync", 0);' in SRC and 'pf = mad_cfg_int_pe("pso-first-use", 0);' in SRC and
      'pm = mad_cfg_int_pe("present-min-ms", 0);' in SRC)
ecl = cut("static void mad_ecl_run(ID3D12CommandQueue *This, UINT count, ID3D12CommandList *const *lists) {")
check("gpu-sync: after the replay leaves the queue lock, commit and wait for the GPU",
      ecl.index("if (ml1021_q) LeaveCriticalSection(&ml1021_q->submit_lock);") <
      ecl.index("if (g_sd_state > 0 && g_gpu_sync && q) {") < ecl.index("mad_strict_drain(q->device);"))
check("pso-first-use: the replay hook is behind g_sd_state and the key, once per pipeline",
      "if (g_sd_state > 0 && g_pso_first && c->u.pso && !c->u.pso->first_used) mad_pso_first(c->u.pso);" in SRC and
      "if (InterlockedExchange(&p->first_used, 1)) return;" in SRC and
      SRC.count("p->born_present = g_presents_now; p->born_tick = GetTickCount();") == 2)
check("present-min-ms: the sleep is inside Present's sync-diagnostics block",
      pr.index("if (g_sd_state > 0) {   /* madeira-bcd: sync diagnostics") < pr.index("if (g_present_min_ms) {") <
      pr.index("drawable = MetalLayer_nextDrawable(s->layer);"))
check("both sampler paths (static and CreateSampler) go through mad_sampler_info",
      SRC.count("mad_sampler_info(&si, ") == 3)

SMP_STUBS = r"""
#include <stdarg.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef unsigned UINT; typedef long LONG;
enum WMTSamplerBorderColor { WMTSamplerBorderColorTransparentBlack = 0, WMTSamplerBorderColorOpaqueBlack = 1, WMTSamplerBorderColorOpaqueWhite = 2 };
enum WMTSamplerAddressMode { WMTSamplerAddressModeClampToEdge = 0, WMTSamplerAddressModeMirrorClampToEdge = 1, WMTSamplerAddressModeRepeat = 2,
                             WMTSamplerAddressModeMirrorRepeat = 3, WMTSamplerAddressModeClampToZero = 4, WMTSamplerAddressModeClampToBorderColor = 5 };
enum WMTSamplerMipFilter { WMTSamplerMipFilterNotMipmapped = 0, WMTSamplerMipFilterNearest = 1, WMTSamplerMipFilterLinear = 2 };
enum WMTSamplerMinMagFilter { WMTSamplerMinMagFilterNearest = 0, WMTSamplerMinMagFilterLinear = 1 };
enum WMTCompareFunction { WMTCompareFunctionNever = 0, WMTCompareFunctionLess, WMTCompareFunctionEqual, WMTCompareFunctionLessEqual,
                          WMTCompareFunctionGreater, WMTCompareFunctionNotEqual, WMTCompareFunctionGreaterEqual, WMTCompareFunctionAlways };
struct WMTSamplerInfo { enum WMTSamplerMinMagFilter min_filter, mag_filter; enum WMTSamplerMipFilter mip_filter;
    enum WMTSamplerAddressMode r_address_mode, s_address_mode, t_address_mode; enum WMTSamplerBorderColor border_color;
    enum WMTCompareFunction compare_function; float lod_min_clamp, lod_max_clamp; uint32_t max_anisotroy;
    bool normalized_coords, lod_average, support_argument_buffers; uint64_t gpu_resource_id; };
typedef enum { D3D12_COMPARISON_FUNC_NEVER = 1, D3D12_COMPARISON_FUNC_LESS, D3D12_COMPARISON_FUNC_EQUAL, D3D12_COMPARISON_FUNC_LESS_EQUAL,
               D3D12_COMPARISON_FUNC_GREATER, D3D12_COMPARISON_FUNC_NOT_EQUAL, D3D12_COMPARISON_FUNC_GREATER_EQUAL, D3D12_COMPARISON_FUNC_ALWAYS } D3D12_COMPARISON_FUNC;
static int g_logs; static char g_last_log[1024];
static void d3d12_log(const char *fmt, ...) { va_list ap; va_start(ap, fmt); g_logs++; vsnprintf(g_last_log, sizeof g_last_log, fmt, ap); va_end(ap); fputs(g_last_log, stdout); }
static long long g_red_cfg, g_census_cfg;
static long long mad_cfg_int_pe(const char *key, long long dflt) {
    if (!strcmp(key, "sampler-reduction")) return g_red_cfg; if (!strcmp(key, "sampler-census")) return g_census_cfg; return dflt;
}
"""
SMP_HARNESS = r"""
#define T(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); return 1; } } while (0)
static struct WMTSamplerInfo S(UINT filter, UINT cmp) { struct WMTSamplerInfo si; mad_sampler_info(&si, filter, 1, 1, 1, 8, cmp, 0, 0.0f, 3.4e38f, "test"); return si; }
static void reload(long long red, long long census) { g_red_cfg = red; g_census_cfg = census; g_smp_red = -1; memset((void *)g_smp_seen, 0, sizeof g_smp_seen); }
int main(void) {
    struct WMTSamplerInfo a, b;
    /* unset: every mapping exactly as before, MIN/MAX logged once each, nothing else */
    reload(0, 0); g_logs = 0;
    a = S(0x15, 0); T(a.min_filter == WMTSamplerMinMagFilterLinear && a.mip_filter == WMTSamplerMipFilterLinear && a.compare_function == WMTCompareFunctionNever && g_logs == 0);
    a = S(0x95, D3D12_COMPARISON_FUNC_LESS_EQUAL); T(a.compare_function == WMTCompareFunctionLessEqual && a.min_filter == WMTSamplerMinMagFilterLinear && g_logs == 0);
    a = S(0xd5, D3D12_COMPARISON_FUNC_GREATER); T(a.compare_function == WMTCompareFunctionGreater && a.max_anisotroy == 8 && g_logs == 0);
    a = S(0x115, 0); T(a.min_filter == WMTSamplerMinMagFilterLinear && a.compare_function == WMTCompareFunctionNever && g_logs == 1);   /* MINIMUM: an average */
    T(strstr(g_last_log, "filter 0x115 (MINIMUM reduction") && strstr(g_last_log, "an averaging filter (as before"));
    a = S(0x195, 0); T(a.compare_function == WMTCompareFunctionAlways && a.min_filter == WMTSamplerMinMagFilterLinear && g_logs == 2);   /* MAXIMUM: the old bug, kept */
    T(strstr(g_last_log, "MAXIMUM taken for a COMPARISON sampler") && strstr(g_last_log, "compare Always"));
    a = S(0x195, 0); a = S(0x115, 0); T(g_logs == 2);   /* once per filter value */
    T(a.lod_max_clamp == 1000.0f && a.s_address_mode == WMTSamplerAddressModeRepeat);
    /* 1: point filtering and no comparison for MIN/MAX only */
    reload(1, 0); g_logs = 0;
    a = S(0x195, 0); T(a.compare_function == WMTCompareFunctionNever && a.min_filter == WMTSamplerMinMagFilterNearest && a.mag_filter == WMTSamplerMinMagFilterNearest &&
                       a.mip_filter == WMTSamplerMipFilterNearest && a.max_anisotroy == 1);
    T(g_logs == 2 && strstr(g_last_log, "point-sampled, comparison dropped (sampler-reduction = 1)"));   /* the key line + the sampler */
    a = S(0x155, 0); T(a.min_filter == WMTSamplerMinMagFilterNearest && a.max_anisotroy == 1);   /* MINIMUM_ANISOTROPIC */
    b = S(0x95, D3D12_COMPARISON_FUNC_LESS); T(b.compare_function == WMTCompareFunctionLess && b.min_filter == WMTSamplerMinMagFilterLinear);   /* comparison untouched */
    b = S(0x15, 0); T(b.min_filter == WMTSamplerMinMagFilterLinear && b.mip_filter == WMTSamplerMipFilterLinear);
    /* 2: only the comparison goes */
    reload(2, 0);
    a = S(0x195, 0); T(a.compare_function == WMTCompareFunctionNever && a.min_filter == WMTSamplerMinMagFilterLinear && a.mip_filter == WMTSamplerMipFilterLinear);
    a = S(0x1d5, 0); T(a.compare_function == WMTCompareFunctionNever && a.max_anisotroy == 8);
    /* 3: Metal reductionMode -- tag in the padding byte, no comparison, nearest mip -> linear */
    reload(3, 0);
    a = S(0x114, D3D12_COMPARISON_FUNC_NEVER); T(((unsigned char *)&a)[offsetof(struct WMTSamplerInfo, support_argument_buffers) + 1] == 0xA1 &&
                       a.compare_function == WMTCompareFunctionNever && a.mip_filter == WMTSamplerMipFilterLinear && a.min_filter == WMTSamplerMinMagFilterLinear);
    T(strstr(g_last_log, "Metal reductionMode (sampler-reduction = 3"));
    a = S(0x195, 0); T(((unsigned char *)&a)[offsetof(struct WMTSamplerInfo, support_argument_buffers) + 1] == 0xA2 && a.compare_function == WMTCompareFunctionNever);
    a = S(0x100, 0); T(((unsigned char *)&a)[offsetof(struct WMTSamplerInfo, support_argument_buffers) + 1] == 0xA1 && a.mip_filter == WMTSamplerMipFilterNearest);   /* all point: Metal ignores it anyway */
    b = S(0x95, D3D12_COMPARISON_FUNC_LESS); T(((unsigned char *)&b)[offsetof(struct WMTSamplerInfo, support_argument_buffers) + 1] == 0 && b.compare_function == WMTCompareFunctionLess);
    b = S(0x14, 0); T(((unsigned char *)&b)[offsetof(struct WMTSamplerInfo, support_argument_buffers) + 1] == 0 && b.mip_filter == WMTSamplerMipFilterNearest);
    reload(9, 0); a = S(0x195, 0); T(g_smp_red == 0 && a.compare_function == WMTCompareFunctionAlways);   /* out of range: off */
    /* census: every distinct filter once */
    reload(0, 1); g_logs = 0;
    S(0x15, 0); S(0x15, 0); S(0x95, D3D12_COMPARISON_FUNC_LESS); S(0x00, 0);
    T(g_logs == 4 && strstr(g_last_log, "filter 0x000 (standard reduction, D3D min point mag point mip point"));
    printf("sampler harness ok\n");
    return 0;
}
"""
smp_code = SMP_STUBS + cut("static enum WMTCompareFunction mad_compare(D3D12_COMPARISON_FUNC f) {") + "\n"
i0 = SRC.index("static int g_smp_red = -1, g_smp_census;")
i1 = SRC.index("static void mad_sampler_info(struct WMTSamplerInfo *si, UINT filter, UINT au, UINT av, UINT aw, UINT aniso, UINT cmp, UINT border, float minlod, float maxlod, const char *who) {")
smp_code += SRC[i0:i1] + cut(SRC[i1:SRC.index("{", i1) + 1]) + "\n" + SMP_HARNESS
if cc:
    with tempfile.TemporaryDirectory() as t:
        c = pathlib.Path(t) / "smp.c"
        c.write_text(smp_code)
        exe = pathlib.Path(t) / "smp"
        p = subprocess.run([cc, "-std=c11", "-Wall", "-Wno-unused-function", "-o", str(exe), str(c)], capture_output=True, text=True)
        check("sampler harness compiles", p.returncode == 0)
        if p.returncode:
            print(p.stderr[-4000:])
        else:
            r = subprocess.run([str(exe)], capture_output=True, text=True)
            check("sampler mapping: unchanged by default, MIN/MAX logged; sampler-reduction 1 / 2; census (" +
                  (r.stdout.strip().splitlines() or ["?"])[-1] + ")", r.returncode == 0 and "sampler harness ok" in r.stdout)
            if r.returncode:
                print(r.stdout[-4000:])

print("PASS" if ok else "FAILED")
sys.exit(0 if ok else 1)
