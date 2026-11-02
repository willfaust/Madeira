#!/usr/bin/env python3
"""Swapchain mode-switch diagnostics ([swap-diag], [swap-win], [main-stall]); no Wine, no Metal.

Red Dead Redemption 2 hangs when its Screen Type is switched to Windowed
Borderless (owner, 2026-10-08), and the logs of it named no swapchain call.
The lines added to find where it stops must only log. This test checks:
  - madeira_d3d12.c: SetFullscreenState, ResizeTarget, ResizeBuffers and
    ResizeBuffers1 (one body), GetContainingOutput, the swapchain's creation
    and final Release log their entry and exit, the layer setup on the iOS main
    thread is bracketed, Present marks its steps, GetFullscreenState and
    GetFrameStatistics name their first calls; the methods still do what they
    did (fullscreen is only recorded, ResizeTarget is a no-op, GetFullscreenState
    names no output); the rate rule (first 32, then every 100th) and the queue
    drain and Present throttle are cut out and run against pthread-backed
    critical sections: 2 s slices end exactly when the worker is done, a
    slice that times out names the worker's job and Present step, and the
    caller's LastError survives;
  - Winios.m's table of swapchain windows and driver_ios.c's hooks, cut out and
    compiled together (so their declarations must agree) and run with stub
    win32u calls, under ThreadSanitizer when the compiler has it: one slot per
    window, a budget per window and kind of line, forget and session reset,
    WindowPosChanging still answers TRUE, lines only for swapchain windows,
    pos-begin/pos timed on one thread, activation to and from such a window;
    the hooks are installed only when both Winios.m symbols exist;
  - Winios.m's [main-stall] heartbeat, its blocks turned into functions: no
    report while the main thread runs, reports at 2, 5, 10 s of a stall, one
    stack dump (off the watcher thread) per stall and at most 4 per run, a
    line when the main thread runs again, no report in the background or after
    the watcher itself was stopped;
  - sysparams_ios.c times exactly the WM_DISPLAYCHANGE broadcast, and
    IOSDisplayShim reports a swapchain's HWND in both kinds of session.
The runtime parts need a host C compiler (CC, cc, gcc or clang).
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
d3d12 = (ROOT / 'madeira-d3d12/src/pe/madeira_d3d12.c').read_text()
winios = (ROOT / 'app/Madeira/Winios/Winios.m').read_text()
driver = (ROOT / 'build/win32u-unix/driver_ios.c').read_text()
sysparams = (ROOT / 'build/win32u-unix/sysparams_ios.c').read_text()
shim = (ROOT / 'app/Madeira/IOSDisplayShim.m').read_text()
failures = 0


def check(label, condition):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def function(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


# ------------------------------------------------------------ madeira_d3d12.c
setfs = function(d3d12, 'static HRESULT STDMETHODCALLTYPE swap_SetFullscreenState(')
getfs = function(d3d12, 'static HRESULT STDMETHODCALLTYPE swap_GetFullscreenState(')
target = function(d3d12, 'static HRESULT STDMETHODCALLTYPE swap_ResizeTarget(')
resize = function(d3d12, 'static HRESULT mad_swap_resize(')
rb = function(d3d12, 'static HRESULT STDMETHODCALLTYPE swap_ResizeBuffers(')
rb1 = function(d3d12, 'static HRESULT STDMETHODCALLTYPE swap_ResizeBuffers1(')
output = function(d3d12, 'static HRESULT STDMETHODCALLTYPE swap_GetContainingOutput(')
create = function(d3d12, 'static HRESULT mad_swapchain_create(')
release = function(d3d12, 'static ULONG STDMETHODCALLTYPE swap_Release(')
layer = function(d3d12, 'static void mad_swap_apply_layer(')
present = function(d3d12, 'static void mad_present_run(struct mad_swapchain *s, UINT idx) {')
worker = function(d3d12, 'static DWORD WINAPI mad_sub_worker(void *arg) {')
drain = function(d3d12, 'static void mad_queue_drain(struct mad_queue *q) {')
throttle = function(d3d12, 'static void mad_present_throttle(struct mad_queue *q) {')

check('SetFullscreenState logs entry and exit and still only records the state',
      '[swap-diag] #%ld SetFullscreenState(%d, output %p) enter' in setfs and
      '[swap-diag] #%ld SetFullscreenState -> S_OK' in setfs and
      [m.strip() for m in re.findall(r'\bs->[\w.]+\s*=[^=]', setfs)] == ['s->fs.Windowed ='] and
      's->fs.Windowed = !fs;' in setfs and setfs.count('return ') == 1 and 'return S_OK;' in setfs)
check('GetFullscreenState still names no output, and says so in its line',
      'if (target) *target = NULL;' in getfs and 'mad_swd_getfs(s, !s->fs.Windowed, target != NULL);' in getfs and
      'output NULL although fullscreen' in d3d12)
check('ResizeTarget logs and stays a no-op that answers S_OK',
      '[swap-diag] #%ld ResizeTarget(' in target and re.findall(r'return [^;]+;', target) == ['return S_OK;'] and
      not re.search(r'\bs->[\w.]+\s*=[^=]', target))
check('ResizeBuffers and ResizeBuffers1 share one body, which logs entry, layer setup and exit',
      'return mad_swap_resize((struct mad_swapchain *)T, count, w, h, fmt, flags, "ResizeBuffers");' in rb and
      'return mad_swap_resize(s, count, w, h, fmt, flags, api);' in rb1 and
      resize.index('enter: swapchain') < resize.index('mad_queue_drain(s->queue)') <
      resize.index('mad_swap_release_buffers(s);') < resize.index('s->diag_seq = say ? seq : 0;') <
      resize.index('hr = mad_swap_make_buffers(s);') < resize.index('s->diag_seq = 0;') < resize.index('%s -> %#lx in'))
check('the resize keeps the old size for a 0 argument, as before',
      all(x in resize for x in ('if (count) s->desc.BufferCount = count;', 'if (w) s->desc.Width = w;',
                                 'if (h) s->desc.Height = h;', 'if (fmt != DXGI_FORMAT_UNKNOWN) s->desc.Format = fmt;',
                                 's->desc.Flags = flags;')))
check('the x64 graphics entries still forward to the same methods',
      'return swap_ResizeBuffers(T, count, w, h, fmt, flags);' in d3d12 and
      'return swap_ResizeBuffers1(T, count, w, h, fmt, flags, node_masks, queues);' in d3d12)
stats = function(d3d12, 'static HRESULT STDMETHODCALLTYPE swap_GetFrameStatistics(')
check('GetFrameStatistics answers as before and names its first calls',
      'st->PresentCount = (UINT)s->presents;' in stats and 'st->PresentRefreshCount = (UINT)s->presents;' in stats and
      'memset(st, 0, sizeof *st);' in stats and 'n <= 8 || (n % 3600) == 0' in stats and
      re.findall(r'return [^;]+;', stats) == ['return E_INVALIDARG;', 'return S_OK;'])
check('GetContainingOutput keeps its answers (no factory: DXGI_ERROR_UNSUPPORTED) and logs them',
      'if (!s->factory) hr = DXGI_ERROR_UNSUPPORTED;' in output and 'IDXGIAdapter1_EnumOutputs(adapter, 0, out);' in output and
      '[swap-diag] #%ld GetContainingOutput' in output)
check('creation logs entry, the Metal view (main-thread layer in a desktop session) and exit',
      create.index('swapchain creation enter') < create.index('CreateMetalViewFromHWND') <
      create.index('hr = mad_swap_make_buffers(s);') < create.index('creation -> %#lx'))
check('the final Release logs entry, the drain and the end, before free',
      release.index('final Release enter') < release.index('mad_queue_drain(s->queue)') <
      release.index('released in %.1f ms') < release.index('free(s);'))
check('the layer setup on the iOS main thread is bracketed for a logged resize or creation, else named when slow',
      layer.index('set on the iOS main thread (dispatch_sync) ...') < layer.index('MetalLayer_setProps(s->layer, &props);') <
      layer.index('set in %.1f ms') and 'ms >= 100.0 && mad_swd_take(&g_swd_layer_n, &seq)' in layer)
steps = [present.index(x) for x in ("mad_swd_step(s->queue, 'F');", "mad_swd_step(s->queue, 'L');",
                                    "mad_swd_step(s->queue, 'A');", "mad_swd_step(s->queue, 'D');",
                                    "mad_swd_step(s->queue, 'C');")]
check('Present marks its steps in order: flush, GPU wait, layer, nextDrawable, commit',
      steps == sorted(steps) and present.count('mad_swd_step(s->queue, 0);') == 2 and
      'waited %.0f ms for the GPU to finish frame N-%u' in present)
check('the worker names its job while it runs it',
      worker.index('q->diag_job = j->kind;') < worker.index('switch (j->kind) {') <
      worker.index('q->diag_job = 0; q->diag_step = 0;'))
check('drain and throttle wait in 2 s slices on the same condition, never INFINITE',
      'INFINITE)' not in drain and 'INFINITE)' not in throttle and
      'while (q->sub_head || q->sub_busy) {' in drain and 'while (q->sub_presents > g_present_ahead) {' in throttle and
      'SleepConditionVariableCS(&q->sub_idle, &q->sub_lock, 2000)' in drain and
      'SleepConditionVariableCS(&q->sub_presented, &q->sub_lock, 2000)' in throttle)

shared = d3d12[d3d12.index('/* madeira-bcd: SWAPCHAIN MODE-SWITCH DIAGNOSTICS ([swap-diag]), the shared part;'):
               d3d12.index('static DWORD WINAPI mad_sub_worker(void *arg) {')]
d3d12_harness = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
typedef int32_t LONG; typedef int64_t LONG64; typedef uint64_t UINT64; typedef uint32_t DWORD;
typedef int BOOL; typedef unsigned UINT;
typedef union { int64_t QuadPart; } LARGE_INTEGER;
#define WINAPI
#define ERROR_TIMEOUT 1460u
typedef struct { pthread_mutex_t m; } CRITICAL_SECTION;
typedef struct { pthread_cond_t c; } CONDITION_VARIABLE;
static __thread DWORD last_error;
static DWORD GetLastError(void) { return last_error; }
static void SetLastError(DWORD e) { last_error = e; }
static DWORD GetCurrentThreadId(void) { return 0x42; }
static void EnterCriticalSection(CRITICAL_SECTION *cs) { pthread_mutex_lock(&cs->m); }
static void LeaveCriticalSection(CRITICAL_SECTION *cs) { pthread_mutex_unlock(&cs->m); }
static int timeouts;
/* The 2000 ms slices run 40 times faster here. */
static BOOL SleepConditionVariableCS(CONDITION_VARIABLE *cv, CRITICAL_SECTION *cs, DWORD ms) {
    struct timespec ts;
    long scaled = (long)ms / 40;
    assert(ms == 2000);
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_nsec += scaled * 1000000L;
    ts.tv_sec += ts.tv_nsec / 1000000000L; ts.tv_nsec %= 1000000000L;
    if (pthread_cond_timedwait(&cv->c, &cs->m, &ts) == ETIMEDOUT) { timeouts++; last_error = ERROR_TIMEOUT; return 0; }
    return 1;
}
static void WakeAllConditionVariable(CONDITION_VARIABLE *cv) { pthread_cond_broadcast(&cv->c); }
static void QueryPerformanceCounter(LARGE_INTEGER *t) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); t->QuadPart = ts.tv_sec * 1000000000LL + ts.tv_nsec;
}
static LONG64 InterlockedExchangeAdd64(volatile LONG64 *p, LONG64 v) { return __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST); }
static LONG InterlockedIncrement(volatile LONG *p) { return __atomic_add_fetch(p, 1, __ATOMIC_SEQ_CST); }
static UINT64 mad_tick(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec * 1000000000ull + ts.tv_nsec; }
static UINT64 mad_tick_freq(void) { return 1000000000ull; }
static char logbuf[1 << 16]; static size_t loglen;
static void d3d12_log(const char *fmt, ...) {   /* the real one may change LastError */
    va_list ap; va_start(ap, fmt);
    loglen += vsnprintf(logbuf + loglen, sizeof logbuf - loglen, fmt, ap);
    va_end(ap); last_error = 0xdead;
}
static long mad_cfg_int_pe(const char *k, long d) { (void)k; return d; }
enum { MAD_SUB_ECL = 1, MAD_SUB_SIGNAL, MAD_SUB_WAIT, MAD_SUB_PRESENT };
struct mad_subjob;
struct mad_queue {
    void *sub_thread;
    CRITICAL_SECTION sub_lock;
    CONDITION_VARIABLE sub_work, sub_idle, sub_presented;
    struct mad_subjob *sub_head;
    int sub_busy;
    LONG sub_presents;
    volatile LONG diag_job, diag_step; volatile UINT64 diag_since;
};
static volatile LONG64 g_perf_drain_ticks;
static struct { volatile LONG64 t_thr; } g_xp;
''' + shared + drain + '\nstatic int g_present_ahead = -1;\n' + throttle + r'''
static struct mad_queue q = { (void *)1, { PTHREAD_MUTEX_INITIALIZER }, { PTHREAD_COND_INITIALIZER },
                              { PTHREAD_COND_INITIALIZER }, { PTHREAD_COND_INITIALIZER } };
static volatile int worker_done;
static void *finish_job(void *arg) {
    usleep((useconds_t)(uintptr_t)arg * 1000);
    pthread_mutex_lock(&q.sub_lock.m);
    worker_done = 1; q.sub_busy = 0;
    pthread_cond_broadcast(&q.sub_idle.c);
    pthread_mutex_unlock(&q.sub_lock.m);
    return NULL;
}
static void *finish_present(void *arg) {
    usleep((useconds_t)(uintptr_t)arg * 1000);
    pthread_mutex_lock(&q.sub_lock.m);
    worker_done = 1; q.sub_presents--;
    pthread_cond_broadcast(&q.sub_presented.c);
    pthread_mutex_unlock(&q.sub_lock.m);
    return NULL;
}
int main(void) {
    pthread_t t;
    unsigned i;
    LONG n = 0, seq = 0;
    /* the rate rule */
    for (i = 1; i <= 1000; i++) {
        int take = mad_swd_take(&n, &seq);
        assert(seq == (LONG)i && take == (i <= 32 || i % 100 == 0));
    }
    /* an idle queue: no wait, no line, LastError untouched */
    last_error = 0x1234; mad_queue_drain(&q);
    assert(last_error == 0x1234 && loglen == 0 && timeouts == 0);
    /* a Present the worker is stuck in for ~3.5 slices: the drain ends when it does */
    q.sub_busy = 1; q.diag_job = MAD_SUB_PRESENT; mad_swd_step(&q, 'D'); worker_done = 0;
    pthread_create(&t, NULL, finish_job, (void *)(uintptr_t)175);
    last_error = 0x1234; mad_queue_drain(&q);
    assert(worker_done && !q.sub_busy && last_error == 0x1234);
    pthread_join(t, NULL);
    assert(timeouts >= 2 && strstr(logbuf, "queue drain on queue") && strstr(logbuf, "still waiting after 2 s") &&
           strstr(logbuf, "the worker is in Present (nextDrawable) for"));
    printf("drain: %d slices, %zu bytes logged\n", timeouts, loglen);
    /* a job that finishes inside the first slice: no line */
    loglen = 0; logbuf[0] = 0; timeouts = 0;
    q.sub_busy = 1; q.diag_job = MAD_SUB_ECL; worker_done = 0;
    pthread_create(&t, NULL, finish_job, (void *)(uintptr_t)10);
    mad_queue_drain(&q);
    pthread_join(t, NULL);
    assert(worker_done && timeouts == 0 && loglen == 0);
    /* the Present throttle: two queued presents, run-ahead 1 (read from the
     * config once, whose line may change LastError, as before) */
    g_present_ahead = 1;
    q.sub_presents = 2; q.diag_job = MAD_SUB_WAIT; worker_done = 0;
    pthread_create(&t, NULL, finish_present, (void *)(uintptr_t)120);
    last_error = 0x77; mad_present_throttle(&q);
    pthread_join(t, NULL);
    assert(worker_done && q.sub_presents == 1 && last_error == 0x77);
    assert(timeouts >= 1 && strstr(logbuf, "Present throttle on queue") && strstr(logbuf, "the worker is in a queue Wait"));
    printf("throttle: %d slices\n", timeouts);
    return 0;
}
'''

wanted = [os.environ.get('CC'), shutil.which('cc'), shutil.which('gcc'), shutil.which('clang')]
compiler = next((c for c in wanted if c), None)


def build_and_run(name, code, sanitizers):
    """Compile with the first sanitizer set the compiler can link (the last is
    usually none) and run; returns (ok, stdout)."""
    with tempfile.TemporaryDirectory(prefix='madeira-swap-diag-') as tmp:
        src, exe = Path(tmp) / (name + '.c'), Path(tmp) / name
        src.write_text(code)
        flags = ['-std=gnu11', '-Wall', '-Wextra', '-Wno-unused-parameter', '-Wno-unused-function', '-g', '-pthread']
        for sanitize in sanitizers:
            r = subprocess.run([compiler, *flags, *sanitize, str(src), '-o', str(exe)], capture_output=True, text=True)
            if r.returncode == 0:
                break
        if r.returncode:
            print(r.stderr[-4000:])
            return False, ''
        print(f'note: {name} built with {" ".join(sanitize) or "no sanitizer"}')
        run = subprocess.run([str(exe)], capture_output=True, text=True,
                             env=dict(os.environ, TSAN_OPTIONS='halt_on_error=1'))
        if run.returncode:
            print(run.stdout[-3000:] + run.stderr[-3000:])
        return run.returncode == 0, run.stdout


TSAN = [['-fsanitize=thread'], ['-fsanitize=address,undefined'], []]
ASAN = [['-fsanitize=address,undefined'], []]


if compiler:
    # The stall line reads the worker's fields without the lock by design (a log
    # line), so this one runs under ASan/UBSan rather than ThreadSanitizer.
    ok, out = build_and_run('drain', d3d12_harness, ASAN)
    check('the rate rule, the drain and the throttle run on the host: they end when the worker does, '
          'name its job and step, keep LastError', ok)
else:
    print('note: no host C compiler; the runtime checks are skipped')

# ------------------------------------------------- Winios.m table + driver hooks
table = winios[winios.index('#define WINIOS_SWAP_HWNDS 32'):winios.index('static void winios_remove_layer(HWND hwnd);')]
hooks_at = driver.index("/* iOS-Madeira: [swap-win] WHAT HAPPENS TO A SWAPCHAIN'S WINDOW.")
hooks = driver[hooks_at:driver.index('\n}\n', driver.index('static void winios_swap_win_pos(', hooks_at)) + 3]
callback = function(driver, 'static void winios_drv_window_pos_changed(')
frame_part = callback[:callback.index('    /* ml505: z-order')]
check('the window-position callback logs a swapchain window at its end, after the chained hook, '
      'and leaves the frame part alone',
      'winios_swap' not in frame_part and
      callback.index('winios_pWindowPosChanged( hwnd, insert_after, owner_hint, swp_flags, new_rects, surface );') <
      callback.index('if (slot) winios_swap_win_pos( slot, hwnd, insert_after, swp_flags, new_rects );'))
loader = driver[driver.index('if (winios_swapchain_hwnd && winios_swapchain_take)'):]
loader = loader[:loader.index('}') + 1]
check('the three new driver hooks are installed only when Winios.m provides both symbols',
      all(x in loader for x in ('winios_user_driver.pSetWindowStyle = winios_drv_set_window_style;',
                                 'winios_user_driver.pWindowPosChanging = winios_drv_window_pos_changing;',
                                 'winios_user_driver.pActivateWindow = winios_drv_activate_window;')))
destroy = function(winios, 'void winios_pDestroyWindow(HWND hwnd) {')
reset = function(winios, 'void winios_session_reset(void) {')
show = function(winios, 'UINT winios_pShowWindow(HWND hwnd, INT cmd, RECT *rect, UINT swp) {')
check('Winios.m forgets a destroyed window, empties the table per session, logs shows on the window budget',
      'winios_forget_swapchain_hwnd(hwnd)' in destroy and 'winios_swapchain_hwnds_reset();' in reset and
      'winios_swapchain_take(slot, WINIOS_SWAP_SHOW, &seq)' in show and show.rstrip().endswith('return ~0u;\n}'))
check('the layer lines are fed by creation, frames, inherited frames and inherited visibility',
      winios.count('winios_swap_layer_note(') == 5)
creator = function(shim, 'static macdrv_metal_view my_view_create_metal_view(')
check('IOSDisplayShim reports the HWND before choosing the session kind',
      creator.index('winios_note_swapchain_hwnd((void *)v);') < creator.index('if (madeira_desktop_mode()) {'))

win_harness = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
typedef void *HWND; typedef int INT, BOOL; typedef unsigned int UINT; typedef unsigned int DWORD;
typedef struct { int left, top, right, bottom; } RECT;
struct window_rects { RECT window, client, visible; };
typedef struct { DWORD styleOld, styleNew; } STYLESTRUCT;
#define TRUE 1
#define GWL_STYLE (-16)
#define GWL_EXSTYLE (-20)
static char out[1 << 20]; static size_t outlen; static pthread_mutex_t outlock = PTHREAD_MUTEX_INITIALIZER;
static void capture(int fd, const char *fmt, ...) {
    va_list ap; (void)fd;
    pthread_mutex_lock(&outlock);
    va_start(ap, fmt); outlen += vsnprintf(out + outlen, sizeof out - outlen, fmt, ap); va_end(ap);
    pthread_mutex_unlock(&outlock);
}
#define dprintf capture
#define fprintf(f, ...) capture(2, __VA_ARGS__)
#define fflush(f) ((void)0)
static HWND foreground;
static HWND NtUserGetForegroundWindow(void) { return foreground; }
static BOOL is_window_visible(HWND h) { (void)h; return 1; }
static UINT get_window_long(HWND h, INT off) { (void)h; return off == GWL_STYLE ? 0x96000000u : 0x8u; }
static DWORD GetCurrentThreadId(void) { return 0x123; }
/* driver_ios.c's weak declarations first, then Winios.m's definitions: one
 * translation unit, so the two sides must agree */
''' + hooks + table + r'''
static void reset_out(void) { outlen = 0; out[0] = 0; }
static int count(const char *needle) { int n = 0; for (const char *p = out; (p = strstr(p, needle)); p++) n++; return n; }
#define A ((HWND)0x40070)
#define B ((HWND)0x40092)
#define C ((HWND)0x500a4)
static void *note_many(void *arg) {
    uintptr_t base = (uintptr_t)arg;
    for (int r = 0; r < 200; r++)
        for (uintptr_t i = 0; i < 6; i++) {
            winios_note_swapchain_hwnd((void *)(base + i * 4));
            unsigned seq; int slot = winios_swapchain_hwnd((void *)(base + i * 4));
            assert(slot >= 1 && slot <= WINIOS_SWAP_HWNDS);
            winios_swapchain_take(slot, 6, &seq);
        }
    return NULL;
}
int main(void) {
    struct window_rects r = { {0, 0, 1408, 648}, {0, 0, 1408, 648}, {0, 0, 1408, 648} };
    STYLESTRUCT st = { 0x16cf0000u, 0x96000000u };
    unsigned seq;
    int a, b, k;
    /* no window is a swapchain window yet: the hooks answer as the null driver and say nothing */
    assert(winios_drv_window_pos_changing(A, 0, 0, &r) == TRUE);
    winios_drv_set_window_style(A, GWL_STYLE, &st);
    winios_drv_activate_window(A, B);
    assert(outlen == 0 && winios_swap_pos_hwnd == 0);
    /* one slot per window, one announcement */
    winios_note_swapchain_hwnd(A); winios_note_swapchain_hwnd(A); winios_note_swapchain_hwnd(B);
    a = winios_swapchain_hwnd(A); b = winios_swapchain_hwnd(B);
    assert(a == 1 && b == 2 && winios_swapchain_hwnd(C) == 0 && winios_swapchain_hwnd(NULL) == 0);
    assert(count("presents through a swapchain") == 2);
    reset_out();
    /* style: set and cleared bits, the foreground named */
    foreground = A;
    winios_drv_set_window_style(A, GWL_STYLE, &st);
    assert(strstr(out, "style hwnd=0x40070 GWL_STYLE 16cf0000 -> 96000000 (set 80000000, cleared 00cf0000) shown=1") &&
           strstr(out, "(this window)"));
    /* pos-begin and pos on one thread */
    reset_out();
    assert(winios_drv_window_pos_changing(A, 0x20, 0, &r) == TRUE && winios_swap_pos_hwnd == A);
    winios_swap_win_pos(a, A, NULL, 0x20, &r);
    assert(count("pos-begin hwnd=0x40070 flags=00000020") == 1 && count("ms after pos-begin\n") == 1 &&
           winios_swap_pos_hwnd == 0);
    winios_swap_win_pos(a, A, NULL, 0x20, &r);
    assert(count("(no pos-begin on this thread)") == 1);
    assert(strstr(out, "window={0,0,1408,648} client={0,0,1408,648} visible={0,0,1408,648} style=96000000 exstyle=00000008"));
    /* activation to and from a swapchain window, not between two other windows */
    reset_out();
    winios_drv_activate_window(A, C); winios_drv_activate_window(C, B); winios_drv_activate_window(C, (HWND)0x9);
    assert(count("activate hwnd=0x40070 (swapchain window) (now foreground) previous=0x500a4 tid") == 1 &&
           count("activate hwnd=0x500a4 (now foreground) previous=0x40092 (swapchain window)") == 1 &&
           count("activate") == 2);
    /* each window has its own budget per kind: the first 32, then every 100th
     * (two pos lines of A came above: these are its 3rd to 252nd) */
    reset_out();
    for (k = 0; k < 250; k++) winios_swap_win_pos(a, A, NULL, 0, &r);
    assert(count("pos hwnd=0x40070") == 32 && strstr(out, "[swap-win] #200 pos hwnd=0x40070") &&
           !strstr(out, "[swap-win] #33 pos"));
    winios_swap_win_pos(b, B, NULL, 0, &r);
    assert(count("pos hwnd=0x40092") == 1 && strstr(out, "[swap-win] #1 pos hwnd=0x40092"));
    /* a forgotten window's slot starts over for the next window */
    assert(winios_forget_swapchain_hwnd(A) && winios_swapchain_hwnd(A) == 0 && !winios_forget_swapchain_hwnd(A));
    winios_note_swapchain_hwnd(C);
    assert(winios_swapchain_hwnd(C) == 1 && winios_swapchain_take(1, 2, &seq) && seq == 1);
    /* a new session: nothing is a swapchain window */
    winios_swapchain_hwnds_reset();
    assert(winios_swapchain_hwnd(B) == 0 && winios_swapchain_hwnd(C) == 0);
    /* concurrent notes, queries and takes from four threads */
    pthread_t t[4];
    for (k = 0; k < 4; k++) pthread_create(&t[k], NULL, note_many, (void *)(uintptr_t)(0x10000 + k * 0x1000));
    for (k = 0; k < 4; k++) pthread_join(t[k], NULL);
    for (k = 0; k < 4; k++)
        for (uintptr_t i = 0; i < 6; i++) {
            void *h = (void *)(uintptr_t)(0x10000 + k * 0x1000 + i * 4);
            assert(winios_swapchain_hwnd(h));
            winios_forget_swapchain_hwnd(h);
            assert(!winios_swapchain_hwnd(h));
        }
    puts("table and hooks ok");
    return 0;
}
'''
if compiler:
    ok, out = build_and_run('swapwin', win_harness, TSAN)
    check('Winios.m table + driver_ios.c hooks: null-driver answers, swapchain windows only, pos timing, '
          'activation, per-window budgets, forget, reset, threads', ok)

# ------------------------------------------------------------- [main-stall]
heartbeat = winios[winios.index('extern void ios_dump_all_thread_stacks(void);'):
                   winios.index('static void *winios_freeze_watch(void *arg) {')]
watch = function(winios, 'static void *winios_freeze_watch(void *arg) {')
check('the freeze watcher drives the heartbeat once per loop, after measuring its own sleep',
      watch.count('winios_main_heartbeat(now, slept, t0);') == 1 and
      watch.index('double slept = now - last;') < watch.index('winios_main_heartbeat(now, slept, t0);'))
main_body = heartbeat[heartbeat.index('dispatch_async(dispatch_get_main_queue(), ^{') + len('dispatch_async(dispatch_get_main_queue(), ^{'):]
main_body = main_body[:main_body.index('        });')]
c_heartbeat = heartbeat.replace(main_body, '').replace('dispatch_async(dispatch_get_main_queue(), ^{        });',
                                                       'fake_main_push();')
c_heartbeat = c_heartbeat.replace(
    'dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ ios_dump_all_thread_stacks(); });',
    'fake_global_dump();')
check('the heartbeat code turns into plain C for the host (two blocks, nothing else)',
      '^{' not in c_heartbeat and 'dispatch_async(' not in c_heartbeat and
      c_heartbeat.count('fake_main_push();') == 1 and c_heartbeat.count('fake_global_dump();') == 1)
hb_harness = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static char out[1 << 16]; static size_t outlen;
static void capture(int fd, const char *fmt, ...) {
    va_list ap; (void)fd; va_start(ap, fmt); outlen += vsnprintf(out + outlen, sizeof out - outlen, fmt, ap); va_end(ap);
}
#define dprintf capture
static double clock_now;
static double winios_now_mono(void) { return clock_now; }
static volatile int wfz_bg_now;
static int pushed, dumps_run;
static void fake_main_push(void) { pushed++; }
static void fake_global_dump(void) { dumps_run++; }
static void ios_dump_all_thread_stacks(void) {}
''' + c_heartbeat.replace('extern void ios_dump_all_thread_stacks(void);', '') + r'''
static void run_main_block(void) {
''' + main_body + r'''
}
static int count(const char *needle) { int n = 0; for (const char *p = out; (p = strstr(p, needle)); p++) n++; return n; }
static void tick(double dt) { clock_now += dt; winios_main_heartbeat(clock_now, dt, 0.0); }
int main(void) {
    int i;
    clock_now = 100.0;
    /* a main thread that runs every block: one heartbeat a second, no report */
    for (i = 0; i < 40; i++) { tick(0.25); if (pushed) { run_main_block(); pushed = 0; } }
    assert(outlen == 0);
    /* a stall of 12 s: reports at 2, 5 and 10 s, one dump, then the main thread runs again */
    tick(0.25);
    while (!pushed) tick(0.25);
    pushed = 0;
    for (i = 0; i < 48; i++) tick(0.25);
    assert(count("has not run a queued block for") == 3 && dumps_run == 1 && count("(dump 1 of at most 4 per run)") == 1);
    run_main_block();
    assert(count("the iOS main thread ran again after 12.") == 1);
    /* the app in the background, or the watcher stopped too: no report */
    outlen = 0; out[0] = 0;
    for (i = 0; i < 8; i++) tick(0.25);
    pushed = 0;
    wfz_bg_now = 1;
    for (i = 0; i < 80; i++) tick(0.25);
    wfz_bg_now = 0;
    tick(30.0);
    tick(0.25);
    assert(count("has not run") == 0);
    /* more stalls: one dump each, four per run at most */
    for (int s = 0; s < 5; s++) {
        for (i = 0; i < 30; i++) tick(0.25);
        run_main_block(); pushed = 0;
        for (i = 0; i < 8; i++) { tick(0.25); if (pushed) { run_main_block(); pushed = 0; } }
    }
    assert(dumps_run == 4);
    puts("heartbeat ok");
    return 0;
}
'''
if compiler:
    ok, out = build_and_run('heartbeat', hb_harness, ASAN)
    check('[main-stall]: quiet while the main thread runs, 2/5/10 s reports, one dump per stall and 4 per run, '
          'a line when it runs again, nothing in the background or after a watcher stop', ok)

# ------------------------------------------------------------ sysparams_ios.c
publish = function(sysparams, 'static void ios_publish_screen_size( BOOL broadcast )')
check('sysparams_ios.c times exactly the WM_DISPLAYCHANGE broadcast',
      publish.index('if (!broadcast) return;') < publish.index('clock_gettime( CLOCK_MONOTONIC, &t0 );') <
      publish.index('send_notify_message( get_desktop_window(), WM_DISPLAYCHANGE') <
      publish.index('send_message_timeout( HWND_BROADCAST, WM_DISPLAYCHANGE') <
      publish.index('clock_gettime( CLOCK_MONOTONIC, &t1 );') < publish.index('[display] WM_DISPLAYCHANGE %dx%d sent'))

print('FAILED' if failures else 'PASS')
raise SystemExit(1 if failures else 0)
