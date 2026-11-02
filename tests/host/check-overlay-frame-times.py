#!/usr/bin/env python3
"""The performance overlay's frame times, graph, 1% figures and style options, and the
in-game menu's blurred panel (owner, 2026-10-28, with log 94).

Frame times come from the present path: DXMT's winemetal marks every present with
its drawable's layer (after any frame cap's wait), the OpenGL present marks its
layer, and Winios.m keeps a ring of the marks, leaving hidden desktop windows out
like madeira_shown_frame_count. The overlay reads the intervals of the layer that
presented last. MADEIRA_FRAME_TIMES=0 makes no marks; MADEIRA_MENU_BLUR=0 keeps the
menu's solid panel.
"""
import sys
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


winios = read('app/Madeira/Winios/Winios.m')
gl = read('app/Madeira/Winios/WiniosGL.m')
bridge = read('app/Madeira/Madeira-Bridging-Header.h')
lib = read('app/Madeira/Library.swift')
catalog = read('app/Madeira/ConfigCatalog.generated.swift')

# --- the ring (Winios.m) ---------------------------------------------------------------
mark = winios[winios.index('void madeira_frame_mark(const void *layer) {'):winios.index('int madeira_frame_times_us(')]
check('getenv("MADEIRA_FRAME_TIMES")' in mark and "on = !(e && e[0] == '0');" in mark,
      'MADEIRA_FRAME_TIMES=0 turns the marks off; on by default')
check('[(MadeiraWindowMetalLayer *)l madeiraWindowHidden]) return;' in mark,
      'a hidden desktop window\'s layer makes no mark (as in madeira_shown_frame_count)')
check('atomic_fetch_add_explicit(&g_frame_claim, 1, memory_order_relaxed);' in mark
      and 'atomic_store_explicit(&g_frame_head, i + 1, memory_order_release);' in mark,
      'a mark claims its slot, writes it, then publishes the head')
reader = winios[winios.index('int madeira_frame_times_us('):]
reader = reader[:reader.index('\n}\n') + 3]
check('if (k != key) continue;' in reader and 'key = k; prev = t;' in reader,
      'the reader keeps the frames of the layer that presented last')
check('if (!t || t > prev || now - t > window) break;' in reader,
      'it stops at an overwritten slot or at the window\'s start')
check('*since_last_us = now > t' in reader and 'out[a] = out[b]; out[b] = s;' in reader,
      'the time since the newest present is reported; the intervals come out oldest first')
check('- (BOOL)madeiraWindowHidden;' in winios and 'return __atomic_load_n(&_windowHidden, __ATOMIC_RELAXED) != 0;' in winios,
      'the window layer reports whether it is hidden')
check('extern void madeira_frame_mark(const void *layer);' in gl
      and 'madeira_frame_mark((__bridge const void *)layer);' in gl,
      'the OpenGL present marks its layer')
check('int madeira_frame_times_us(uint32_t *out, int max, uint32_t window_ms, uint32_t *since_last_us);' in bridge,
      'the bridging header declares the reader')

# --- winemetal (DXMT submodule; present in the build workspace) -------------------------
wm_path = ROOT / 'dxmt/src/winemetal/unix/winemetal_unix.c'
if wm_path.exists():
    wm = wm_path.read_text(encoding='utf-8', errors='replace')
    check('extern void madeira_frame_mark(const void *layer) __attribute__((weak));' in wm,
          'winemetal: the mark is a weak reference (a winemetal linked without the app makes none)')
    pd = wm[wm.index('_MTLCommandBuffer_presentDrawable(void *obj) {'):wm.index('_MTLCommandBuffer_presentDrawableAfterMinimumDuration(void *obj) {')]
    check(pd.index('madeira_frame_mark_drawable((id)params->arg);') > pd.index('ios_frame_limiter(fps_cap_ns);'),
          'winemetal: a present is marked after the frame cap\'s wait')
    check('madeira_frame_mark_drawable((id)params->arg0);' in wm and 'if (madeira_frame_mark) madeira_frame_mark((const void *)params->handle);' in wm,
          'winemetal: presents with a minimum duration and RAW-mode skipped frames are marked too')
else:
    print('SKIP: dxmt submodule not checked out here')

# --- the overlay ----------------------------------------------------------------------
check('static let fields = ["FPS", "Frame time", "1% lows", "0.1% lows", "Frame graph", "CPU", "GPU", "RAM", "JIT memory", "Swap & donor", "Battery", "Thermal"]' in lib
      and 'ForEach(OverlayStyle.fields, id: \\.self) { field in' in lib,
      'the menu offers 1% lows and the frame graph among the overlay\'s figures')
one = lib[lib.index('static func onePercent(_ ms: [Double]) -> (low: Double, high: Double)? {'):lib.index('struct FrameTimeGraph: View {')]
check('let sorted = ms.sorted(), k = max(1, sorted.count / 100)' in one
      and 'sorted.suffix(k).reduce(0, +)' in one and 'sorted.prefix(k).reduce(0, +)' in one,
      '1% low: the mean of the slowest 1% of frame times as a frame rate; 1% high: the fastest 1%')
check('FrameTimes.onePercent(FrameTimes.read(windowMs: 10_000).intervals)' in lib,
      'the 1% figures cover the last ten seconds')
# The MS cell showed 1000 / FPS, which disagreed with the graph (owner, Discord 2026-10-28).
check('frameMs = FrameTimes.current(windowMs: UInt32(max(0.5, refresh) * 1000))' in lib
      and 'let value = max(mean, since > mean ? since : 0)' in lib and '1000 / fps' not in lib,
      'the frame time is the measured mean (or the stall still going on), not 1000 / FPS')
check('pointOneLow = FrameTimes.pointOnePercentLow(FrameTimes.read(windowMs: 30_000).intervals)' in lib
      and 'let k = max(1, ms.count / 1000)' in lib,
      'the 0.1% low covers thirty seconds')
graph = lib[lib.index('struct FrameTimeGraph: View {'):lib.index('struct LibraryMetrics: View {')]
check('TimelineView(.periodic(from: .now, by: 0.1))' in graph and 'let pending = since > max(50, median * 2) ? since : 0' in graph,
      'the graph redraws ten times a second and grows a late frame at its right edge')
check('for guide in [16.7, 33.3] where guide < top {' in graph, 'guide lines at 60 and 30 FPS')
for key, default in (('layout', '"grid"'), ('scale', '1.0'), ('background', '"glass"'), ('opacity', '1.0'),
                     ('labels', 'true'), ('colours', 'false'), ('refresh', '1.0'), ('graphSeconds', '4.0')):
    check(lib.count('private var %s = %s' % (key, default)) == 2, 'style %s defaults to %s in the overlay and its settings' % (key, default))
check('case "row":' in lib and 'case "column":' in lib and 'let split = all.count > 5 ? (all.count + 1) / 2 : all.count' in lib,
      'layouts: one row, a column, and the grid of up to five cells a row as before')
check('guard tick % max(1, Int((refresh / 0.5).rounded())) == 0 else { return }' in lib,
      'the figures change every 0.5, 1 or 2 s')
check('.frame(maxWidth: isMenu ? 48 : max(48, viewport.width - insets.leading - insets.trailing - 16))' in lib,
      'the floating overlay may be as wide as the screen (one long row)')
check('OverlayStyleSettings()' in lib and 'Button("Reset overlay style")' in lib,
      'the style settings sit under the figures in the in-game menu, with a reset')

# --- the menu's panel -----------------------------------------------------------------
menu = lib[lib.index('struct SessionMenuBackground: ViewModifier {'):lib.index('struct OverlayStyleSettings: View {')]
check('static let blur = MadeiraConfig.flag("MADEIRA_MENU_BLUR")' in menu
      and 'if Self.blur && !reduceTransparency { content.background(.regularMaterial, in: shape) }' in menu
      and 'else { content.background(Color(uiColor: .secondarySystemBackground), in: shape) }' in menu,
      'the in-game menu: the system material; the solid panel with Reduce Transparency or MADEIRA_MENU_BLUR=0')
check('.modifier(SessionMenuBackground())' in lib and 'Color.black.opacity(SessionMenuBackground.blur ? 0.3 : 0.5)' in lib,
      'the panel uses it, over a lighter dim so the blur shows the game')

for key in ('env.MADEIRA_FRAME_TIMES', 'env.MADEIRA_MENU_BLUR'):
    check('key: "%s"' % key in catalog, 'the config catalog documents %s' % key)

print('check-overlay-frame-times: ' + ('OK' if not failures else '%d FAILED' % failures))
sys.exit(1 if failures else 0)
