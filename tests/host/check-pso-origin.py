#!/usr/bin/env python3
"""madeira-duo pso-origin: the pipelines Metal compiles, counted by origin.

madeira.cfg pso-origin = 1 keys every lazy pipeline at creation, classes it against the
lists as they stood at launch (pso-seen-<exe>.bin: drawn before; pso-created-<exe>.bin:
created before; else new), keeps the keys created in pso-created-<exe>.bin ("MPSC", the
MPSN layout), and counts each build under its class, a build of 150 ms or more as a
compile. Static anchors: the switch is off by default and gates every site, the class is
set before a builder can take the pipeline, the three build paths count, the exit path
takes no lock it could wait on, the line fits d3d12_log's buffer, and no converter
input mentions it.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
failures = 0


def check(cond, what):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + what)
    if not cond:
        failures += 1


def read(rel):
    return (ROOT / rel).read_text(encoding='utf-8', errors='replace')


def body(src, start, end):
    i = src.index(start)
    return src[i:src.index(end, i + len(start))]


pe = read('madeira-d3d12/src/pe/madeira_d3d12.c')

# --- the switch -----------------------------------------------------------------------
on = body(pe, 'static int mad_po_on(void) {', '\n}\n')
check('mad_pso_lazy_on() && mad_cfg_int_pe("pso-origin", 0) > 0' in on, 'pso-origin is read with default 0 and needs lazy pipelines')
check(pe.count('mad_po_on()') == 3 and 'if (on >= 2 && !mad_po_on()) {' in body(pe, 'static int mad_csb_on(void) {', '\n}\n'),
      'two creation sites ask for the switch (render, compute), and cs-create-build = 2 / 3 turns itself off without it')

# --- creation: classed before a builder can take it ------------------------------------
gfx = body(pe, '/* madeira-duo pso-create-build: queued now, so its libraries stay */', 'hr = pso_QI(')
check(gfx.index('p->origin = mad_po_note(mad_seen_key(desc), 0)') < gfx.index('mad_pcb_on_create(p, desc)'),
      'render: classed with the pso-seen key before pso-create-build queues it')
check('p->lazy && !p->rps && !p->tess && !p->gs_emu && mad_po_on()' in gfx, 'render: only the plain lazy pipelines pso-create-build sees')
cs = body(pe, 'static HRESULT device_CreateComputePipelineState_impl(ID3D12Device *This,\n        const D3D12_COMPUTE_PIPELINE_STATE_DESC *desc, REFIID riid, void **out) {\n    struct mad_device',
          'memset(&ci, 0, sizeof ci);\n    ci.compute_function = p->vs_fn;\n    p->cps')
check(cs.index('p->origin = mad_po_note(mad_po_cs_key(desc), 1)') < cs.index('queued = mad_csb_block(p) || mad_csb_queue(p);'),
      'compute: classed before cs-create-build builds or queues it')

# --- cs-create-build = 2 / 3: only the compute pipelines classed as new -----------------
csq = body(pe, 'static int mad_csb_queue(struct mad_pso *p) {', '\n}\n')
check('if (mode >= 2 && p->origin != MAD_PO_NEW) return 0;' in csq
      and 'g_pcs_q[(ULONG)g_pcs_tail % MAD_PCS_MAX] = p; g_pcs_tail++;' in csq
      and 'g_pcb_q[(ULONG)g_pcb_tail % MAD_PCB_MAX] = p; g_pcb_tail++;' in csq,
      'cs-create-build 2 / 3 queue only a new compute pipeline, on a ring of its own; 1 keeps the low-priority queue for all')
csb = body(pe, 'static int mad_csb_block(struct mad_pso *p) {', '\n}\n')
check('if (mad_csb_on() != 3 || p->cps || !p->lazy_cs || p->origin != MAD_PO_NEW) return 0;' in csb
      and csb.index('if (mad_ecl_thread(me)) {') < csb.index('built = mad_cpso_build(p, 1) != 0;'),
      'cs-create-build 3 builds a new compute pipeline inside the create call, never on a thread that submits frames')
wk = body(pe, 'static DWORD WINAPI mad_pa_worker(void *arg) {', 'static int mad_pa_start(void) {')
check(wk.index('if (g_pcs_head != g_pcs_tail)') < wk.index('else if (g_pa_head != g_pa_tail)') < wk.index('else if (g_pcb_head != g_pcb_tail)')
      and 'if (p->is_compute) mad_csb_built(p);' in wk,
      'the builders take a new compute pipeline before a render pipeline a draw waits for, and both before the low-priority queue')
ecl = body(pe, 'static void mad_ecl_thread_note(DWORD me) {', '\n}\n')
check('{ DWORD me = GetCurrentThreadId(); mad_ecl_thread_note(me); g_ecl_tid = me; }' in pe and 'g_ecl_tids[i]' in ecl,
      'every thread that calls ExecuteCommandLists is recorded as one that submits frames')

# --- the three build paths --------------------------------------------------------------
realize = body(pe, 'static obj_handle_t mad_pso_realize(struct mad_pso *p) {', '\n}\n')
check('if (p->origin) mad_po_build(p, 0, mad_qpc() - t0);' in realize, 'render builds count, timed from the realize\'s own t0')
cbuild = body(pe, 'static obj_handle_t mad_cpso_build(struct mad_pso *p, int bg) {', '\n}\n')
check(cbuild.index('p->cps = MTLDevice_newComputePipelineState') < cbuild.index('if (p->origin) mad_po_build(p, 1, mad_qpc() - t0);'),
      'compute builds count, after the Metal call')
strides = body(pe, 'static obj_handle_t mad_pso_for_strides(struct mad_pso *p, const UINT strides[16]) {', '\n}\n')
check('t0 = p->origin ? mad_qpc() : 0;' in strides and 'if (p->origin) mad_po_build(p, 2, mad_qpc() - t0);' in strides,
      'stride variants count under their pipeline\'s class (no clock read when off)')
check(strides.index('if (p->origin) mad_po_build(p, 2,') < strides.index('if (!rps) {\n        if (said++ < 8)'),
      'a variant is counted after its retry, before the failure return')

# --- classes, list files ----------------------------------------------------------------
blk = body(pe, '/* madeira-duo PIPELINE ORIGIN COUNTER', '/* madeira-duo COMPUTE PIPELINES BUILT WHEN THE GAME CREATES THEM')
check('#define MAD_PO_COMPILE_MS 150' in blk and 'dt * 1000 >= (LONG64)MAD_PO_COMPILE_MS * g_po_qpf' in blk, 'a compile is a build of 150 ms or more')
check('L"%ls\\\\Madeira\\\\pso-created-%016llx.bin"' in blk and 'L"%ls\\\\Madeira\\\\pso-seen-%016llx.bin"' in blk,
      'the lists: pso-created-<exe>.bin beside pso-seen-<exe>.bin')
seen_ready = body(pe, 'static int mad_seen_ready(void) {', '\n}\n')
hash_re = r"for \(i = 0; i < n && n < MAX_PATH; i\+\+\) if \(exe\[i\] >= 'A' && exe\[i\] <= 'Z'\) exe\[i\] \+= 'a' - 'A';\s+if \(n && n < MAX_PATH\) h = mad_seen_fnv\(h, exe, n \* sizeof\(WCHAR\)\);"
check(bool(re.search(hash_re, seen_ready)) and bool(re.search(hash_re, blk)), 'the same exe hash as pso-seen')
check(int('4353504d', 16).to_bytes(4, 'little') == b'MPSC' and '0x4353504du /* "MPSC" */' in blk, 'created list magic "MPSC"')
check('mad_po_read(seen, 0x4e53504du /* "MPSN" */' in blk and 'qsort(g_po_seen' in blk,
      'drawn-before is a sorted snapshot of pso-seen at launch (this session\'s draws do not move it)')
note = body(pe, 'static UINT8 mad_po_note(UINT64 key, int kind) {', '\n}\n')
check('if (*slot & MAD_PO_PREV) { if (!cls) cls = MAD_PO_CREATED; }' in note and 'kind == 0 && g_po_seen && bsearch' in note,
      'created-before only for keys on the list at launch; drawn-before only for render pipelines and wins')
check('g_po_n < g_po_cap / 2' in note and 'g_po_cap < 2 * ((ULONG)nprev + 65536)' in blk, 'the table stays at most half full')
cskey = body(pe, 'static UINT64 mad_po_cs_key(const D3D12_COMPUTE_PIPELINE_STATE_DESC *desc) {', '\n}\n')
check('mad_seen_shader(h, &desc->CS)' in cskey and 'reserved' in cskey and 'rs->ranges[i]' in cskey,
      'compute key: CS digest plus the root signature, reserved fields left out')

# --- saving and exit --------------------------------------------------------------------
save = body(pe, 'static void mad_po_save(int exiting) {', '\n}\n')
check('if (exiting) { if (!TryAcquireSRWLockShared(&g_po_lock)) return; }' in save, 'exit save never waits on the lock')
check(save.index('if (!(keys = malloc(') > save.index('else {'), 'exit save does not allocate')
check('MoveFileExW(tmp, g_po_path, MOVEFILE_REPLACE_EXISTING)' in save, 'written to .tmp and moved into place')
ex = body(pe, 'static void mad_po_exit(void) {', '\n}\n')
check('if (g_po_on <= 0 || !g_po_tab) return;' in ex, 'exit returns at once when the switch is off')
check('if (reason == DLL_PROCESS_DETACH) mad_po_exit();' in pe, 'DllMain calls it at process detach')
log = body(pe, 'static void mad_po_log(const char *when, int exiting) {', '\n}\n')
check('else if (g_po_dbg_output) g_po_dbg_output(buf);' in log, 'the exit line goes to Wine\'s debug output only (no stderr lock)')
saver = body(pe, 'static DWORD WINAPI mad_po_saver(void *arg) {', '\n}\n')
check('Sleep(30000);' in saver and 'mad_po_log("30 s", 0)' in saver, 'a line every 30 s when something changed')

# the longest line must fit d3d12_log's 1000-byte buffer with its newline
fmt = ''.join(re.findall(r'"((?:[^"\\]|\\.)*)"', log[log.index('snprintf(buf, sizeof buf,'):log.index('when, (long)')]))
nlong, nfloat = fmt.count('%ld'), fmt.count('%.1f')
worst = len(re.sub(r'%(ld|\.1f|s)', '', fmt)) + nlong * 11 + nfloat * 12 + len('30 s')
check(nlong == 33 and nfloat == 3, f"[pso-origin] line has 33 counts and 3 times ({nlong}, {nfloat})")
check(worst < 999, f'worst-case [pso-origin] line is {worst} bytes (< 999)')
for word in ('drawn-before', 'created-before', 'new', 'stride variants', 'compute compiles', 'render compiles'):
    check(word in fmt, f'the line names "{word}"')

# --- not a converter input ----------------------------------------------------------------
conv = [p for p in (ROOT / 'madeira-d3d12/src/unix').rglob('*') if p.is_file()] + [ROOT / 'madeira-d3d12/src/madeira_ir_abi.h']
check(not any('pso-origin' in p.read_text(errors='replace') or 'mad_po_' in p.read_text(errors='replace') for p in conv),
      'no converter-identity input mentions pso-origin')

print('FAILED' if failures else 'OK')
sys.exit(1 if failures else 0)
