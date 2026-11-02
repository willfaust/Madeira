#!/usr/bin/env python3
"""pso-async: new render pipelines are built off the render thread; the FPS readouts
leave hidden windows' presents out.

GTA V Enhanced (log 2026-10-26 22:40, vk-1026-m1): 252 lazy pipelines were built at
their first draw in under two minutes, 12.3 s of the submitting thread, and the game
fell to 3-15 FPS while pso-warm still had 4,989 pipelines to compile. With the opt-in
madeira.cfg pso-async = 1 the first draw queues the pipeline for two background
threads and its draws are skipped until it is built. In the same session the FPS
readouts showed the cap plus 10: the launcher's hidden layer presents at 10 FPS
(MADEIRA_HIDDEN_LAYER_FPS) and DXMT's present counter counts every window.

Static checks on madeira_d3d12.c, Winios.m, the two overlays, the GTA V lists and the
settings catalog.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
def read(p):
    return (root / p).read_text().replace('\r\n', '\n')
pe = read('madeira-d3d12/src/pe/madeira_d3d12.c')
winios = read('app/Madeira/Winios/Winios.m')
fps = read('app/Madeira/FPSOverlay.swift')
lib = read('app/Madeira/Library.swift')
bridge = read('app/Madeira/Madeira-Bridging-Header.h')
recs = read('app/Madeira/GameRecommendations.swift')
catalog = read('app/Madeira/ConfigCatalog.generated.swift')
ok = True


def check(what, cond):
    global ok
    print(('ok   ' if cond else 'FAIL ') + what)
    ok &= bool(cond)


def body(src, sig):
    start = src.index(sig)
    while src.index(';', start) < src.index('{', start):   # a prototype: the definition comes later
        start = src.index(sig, start + 1)
    brace = src.index('{', start)
    depth = 0
    for i in range(brace, len(src)):
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                return src[start:i + 1]
    raise AssertionError('unterminated: ' + sig)


# --- pso-async ---------------------------------------------------------------
on = body(pe, 'static int mad_pso_async_on(void)')
check('off by default, and only with lazy pipelines', 'mad_pso_lazy_on() && mad_cfg_int_pe("pso-async", 0) > 0' in on)

realize = body(pe, 'static obj_handle_t mad_pso_realize(struct mad_pso *p)')
check('the build publishes rps after a barrier (draws read it without the lock)',
      'if (built) { MemoryBarrier(); p->rps = built; }' in realize and 'p->rps = p->has_vd' not in realize)

q = body(pe, 'static int mad_pso_async_queue(struct mad_pso *p)')
check('a pipeline is queued once (async_q)', 'InterlockedCompareExchange(&p->async_q, 1, 0)' in q)
check('the queue holds a reference', 'InterlockedIncrement(&p->refs);' in q)
check('a full queue or no threads: the caller builds it (returns 0, flag cleared)',
      q.count('InterlockedExchange(&p->async_q, 0);') == 2 and q.count('return 0;') == 2)

w = body(pe, 'static DWORD WINAPI mad_pa_worker(void *arg)')
check('the worker builds through mad_pso_realize and drops the reference',
      'mad_pso_realize(p)' in w and 'pso_Release((ID3D12PipelineState *)p);' in w)
check('the worker runs inside an autorelease pool', 'NSAutoreleasePool_alloc_init()' in w and 'NSObject_release(pool)' in w)

pb = body(pe, 'static void mad_prebuild_lists(UINT count, ID3D12CommandList *const *lists)')
check('the batch prebuild queues render pipelines, never compute ones',
      'if (!p->is_compute && mad_pso_async_on() && mad_pso_async_queue(p)) continue;' in pb)

check('a draw skips (and counts) while its pipeline is being built; tessellation and the off switch build inline',
      '''    if (e->pso && !e->pso->rps && e->pso->lazy) {
        if (!e->pso->tess && mad_pso_async_on() && mad_pso_async_queue(e->pso)) {
            if (!e->pso->rps) { InterlockedIncrement(&g_pa_skips); MAD_SKIP(e); return; }   /* pso-async: still being built */
        } else mad_pso_realize(e->pso);
    }''' in pe)
check('compute stays where it is first used (no async in mad_cpso_realize callers)',
      'mad_pso_async_queue(e->cpso)' not in pe and 'if (e->cpso && !e->cpso->cps && e->cpso->lazy_cs) mad_cpso_realize(e->cpso);' in pe)

check('catalog: pso-async, default 0, Direct3D 12',
      re.search(r'key: "pso-async", title: "", kind: \.int, defaultValue: "0", category: "Direct3D 12"', catalog) is not None)

# The version that took pso-async = 1, and every later one.
for ident, version in (('gta5e-steam', 7), ('gta5e-other', 6)):
    m = re.search(r'id: "%s", title: "[^"]+", version: (\d+),\n\s*config: """\n(.*?)"""' % ident, recs, re.S)
    check('%s version %d or later carries pso-async = 1' % (ident, version),
          m is not None and int(m.group(1)) >= version and '\n        pso-async = 1\n' in m.group(2))

# --- FPS readouts --------------------------------------------------------------
nd = body(winios, '- (nullable id<CAMetalDrawable>)nextDrawable')
check('a hidden window layer counts the drawables it takes',
      'if (drawable && __atomic_load_n(&_windowHidden, __ATOMIC_RELAXED))' in nd and 'g_hidden_layer_frames' in nd)
shown = body(winios, 'uint64_t madeira_shown_frame_count(void)')
check('shown = all frames minus hidden ones, never going back, MADEIRA_FPS_COUNT_HIDDEN=1 restores',
      'madeira_frame_count()' in shown and 'MADEIRA_FPS_COUNT_HIDDEN' in shown and 'atomic_compare_exchange_weak_explicit(&last' in shown)
check('bridging header declares madeira_shown_frame_count', 'uint64_t madeira_shown_frame_count(void);' in bridge)
check('the FPS overlay samples the shown count', fps.count('madeira_shown_frame_count()') == 2 and 'madeira_frame_count()' not in fps)
check('the performance overlay samples the shown count',
      'lastCount = madeira_shown_frame_count()' in lib and 'let count = madeira_shown_frame_count();' in lib)

sys.exit(0 if ok else 1)
