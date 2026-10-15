#!/usr/bin/env python3
"""fence-poll-backoff (opt-in, default 0) in madeira_d3d12.c: source checks plus
a host build of the real fence code with threads.

Horizon Forbidden West with FSR 3 frame generation (build 531, 2026-10-14)
made 34,000-137,000 GetCompletedValue calls per present, ~2.5 million a second,
almost all from FSR's interpolation and presenter threads polling a fence
until the GPU got there; every call took the fence's critical section and two
process-wide interlocked counters, on an efficiency cluster where 6-8 threads
already waited for a core. With fence-poll-backoff = N a call reads without
the lock and counts in batches, and a thread that sees the same value N times
in a row (each call within 50 us of the last) sleeps on the fence's condition
variable until the value moves, at most fence-poll-backoff-us.

Checks:
  - off by default (0) and 200 us by default; N = 1 is taken as 2, negative as
    off; the sleep is clamped to 20..2000 us;
  - off: the locked read and one ml1109 / ml1142 count per call, as before;
  - fence_set_locked stores the value with release order and still wakes
    every sleeper;
  - on, with a real spinning thread and a signalling thread: every value the
    spinner sees is one the fence had, in order; the spinner backs off, most
    back-offs end because the fence moved, it sees each new value promptly,
    and it makes far fewer calls than the same spin without the switch;
  - a caller that polls an unchanged fence more slowly than every 50 us never
    sleeps;
  - polls are still counted (in batches of 256);
  - the [perf] line, the catalog entries and the CI step.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "madeira-d3d12/src/pe/madeira_d3d12.c").read_text()
catalog = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
CI = root / ".github/workflows/build-ipa.yml"
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


def block(start, end="\n}\n"):
    i = src.index(start)
    return src[i:src.index(end, i) + len(end)]


struct = block("struct mad_fence {", "\n};\n")
setl = block("static void fence_set_locked(struct mad_fence *f, UINT64 v) {")
fpb = src[src.index("static volatile int g_fpb = -1;"):]
fpb = fpb[:fpb.index("\n}\n", fpb.index("static UINT64 STDMETHODCALLTYPE fence_GetCompletedValue(ID3D12Fence *This) {")) + 3]
gcv = block("static UINT64 STDMETHODCALLTYPE fence_GetCompletedValue(ID3D12Fence *This) {")

check("fence_set_locked: release store, then the broadcast",
      "__atomic_store_n(&f->value, v, __ATOMIC_RELEASE);\n    WakeAllConditionVariable(&f->cv);" in setl and "f->value = v;" not in setl)
check("off path unchanged: one count per call and the locked read",
      "    InterlockedIncrement(&g_perf_polls);   /* ml1109 */\n"
      "    if ((InterlockedIncrement(&g_gcv_calls) & 0x3ffff) == 0) mad_gcv_sample(f, f->value);   /* ml1142 */\n"
      "    EnterCriticalSection(&f->lock);\n    UINT64 v = f->value;\n    LeaveCriticalSection(&f->lock);\n    return v;\n}" in gcv)
check("on path: lock-free acquire read, ahead of the off path",
      gcv.index("if (g_fpb > 0) {") < gcv.index("EnterCriticalSection(&f->lock);") and
      "__atomic_load_n(&f->value, __ATOMIC_ACQUIRE)" in gcv)
check("keys: fence-poll-backoff (0) and fence-poll-backoff-us (200)",
      'mad_cfg_int_pe("fence-poll-backoff", 0)' in fpb and 'mad_cfg_int_pe("fence-poll-backoff-us", 200)' in fpb)
check("the [perf] line next to ml1109",
      src.index("[perf] ml1109 sync per frame") < src.index("[perf] fence-poll-backoff per frame"))
for key, dflt in (("fence-poll-backoff", "0"), ("fence-poll-backoff-us", "200")):
    check("settings catalog: %s (default %s)" % (key, dflt),
          'ConfigOption(key: "%s", title: "", kind: .int, defaultValue: "%s", category: "Direct3D 12"' % (key, dflt) in catalog)
# The CI step exists only in the fork's workflow; upstream has no .github.
if CI.exists():
    check("CI runs this check", "python3 tests/host/check-fence-poll-backoff.py" in CI.read_text())

harness = r'''
#define _GNU_SOURCE
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
typedef uint64_t UINT64; typedef int32_t LONG; typedef int64_t LONG64, LONGLONG; typedef uint32_t DWORD, ULONG;
typedef int BOOL; typedef void *HANDLE, *HMODULE; typedef struct { int dummy; } IID, ID3D12FenceVtbl;
typedef union { LONGLONG QuadPart; } LARGE_INTEGER;
typedef struct ID3D12Fence ID3D12Fence;
typedef pthread_mutex_t CRITICAL_SECTION; typedef pthread_cond_t CONDITION_VARIABLE;
#define WINAPI
#define STDMETHODCALLTYPE
#define MAD_FENCE_WAITERS 16
struct mad_queue;
static LONG g_perf_polls, g_gcv_calls, g_samples; static LONG64 g_perf_wait_ticks;
static LONG InterlockedIncrement(volatile LONG *p) { return __atomic_add_fetch(p, 1, __ATOMIC_SEQ_CST); }
static LONG InterlockedExchange(volatile LONG *p, LONG v) { return __atomic_exchange_n(p, v, __ATOMIC_SEQ_CST); }
static LONG InterlockedExchangeAdd(volatile LONG *p, LONG v) { return __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST); }
static LONG64 InterlockedExchangeAdd64(volatile LONG64 *p, LONG64 v) { return __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST); }
static LONG64 InterlockedExchange64(volatile LONG64 *p, LONG64 v) { return __atomic_exchange_n(p, v, __ATOMIC_SEQ_CST); }
static void EnterCriticalSection(CRITICAL_SECTION *c) { pthread_mutex_lock(c); }
static void LeaveCriticalSection(CRITICAL_SECTION *c) { pthread_mutex_unlock(c); }
static void WakeAllConditionVariable(CONDITION_VARIABLE *v) { pthread_cond_broadcast(v); }
static LONG64 now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (LONG64)t.tv_sec * 1000000000 + t.tv_nsec; }
static void timed(CONDITION_VARIABLE *v, CRITICAL_SECTION *c, LONG64 ns) {
    struct timespec t; LONG64 at;
    clock_gettime(CLOCK_REALTIME, &t); at = (LONG64)t.tv_sec * 1000000000 + t.tv_nsec + ns;
    t.tv_sec = at / 1000000000; t.tv_nsec = at % 1000000000;
    pthread_cond_timedwait(v, c, &t);
}
static BOOL SleepConditionVariableCS(CONDITION_VARIABLE *v, CRITICAL_SECTION *c, DWORD ms) { timed(v, c, (LONG64)ms * 1000000); return 1; }
static LONG g_rtl_sleeps;
static LONG WINAPI RtlSleepConditionVariableCS(CONDITION_VARIABLE *v, CRITICAL_SECTION *c, const LARGE_INTEGER *rel) {
    g_rtl_sleeps++; timed(v, c, -rel->QuadPart * 100); return 0;
}
static HMODULE GetModuleHandleA(const char *n) { (void)n; return (HMODULE)1; }
static void *GetProcAddress(HMODULE m, const char *n) { (void)m; return strcmp(n, "RtlSleepConditionVariableCS") ? NULL : (void *)RtlSleepConditionVariableCS; }
static BOOL QueryPerformanceCounter(LARGE_INTEGER *t) { t->QuadPart = now_ns(); return 1; }
static BOOL SetEvent(HANDLE h) { (void)h; return 1; }
static UINT64 mad_tick(void) { return (UINT64)now_ns(); }
static UINT64 mad_tick_freq(void) { return 1000000000ull; }
static int g_logs;
static void d3d12_log(const char *fmt, ...) { va_list ap; va_start(ap, fmt); g_logs++; vfprintf(stderr, fmt, ap); va_end(ap); }
static long long mad_cfg_int_pe(const char *key, long long dflt) {
    const char *e = !strcmp(key, "fence-poll-backoff") ? getenv("T_N") : !strcmp(key, "fence-poll-backoff-us") ? getenv("T_US") : NULL;
    return e ? atoll(e) : dflt;
}
STRUCT
SETL
static void mad_gcv_sample(struct mad_fence *f, UINT64 v) { (void)f; (void)v; g_samples++; }
FPB
static struct mad_fence F;
static UINT64 seen_vals[64]; static int nseen; static LONG64 seen_at[64];
static LONG64 signal_at[8];
static void *signaller(void *a) {
    UINT64 v; (void)a;
    for (v = 1; v <= 5; v++) {
        usleep(3000);
        EnterCriticalSection(&F.lock); signal_at[v] = now_ns(); fence_set_locked(&F, v); LeaveCriticalSection(&F.lock);
    }
    return NULL;
}
int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "spin";
    long calls = 0;
    pthread_mutex_init(&F.lock, NULL); pthread_cond_init(&F.cv, NULL);
    if (!strcmp(mode, "spin")) {   /* a spinner until 5, a signaller every 3 ms */
        pthread_t t; UINT64 last = (UINT64)-1; int bad = 0; LONG64 worst = 0; int i;
        pthread_create(&t, NULL, signaller, NULL);
        for (;;) {
            UINT64 v = fence_GetCompletedValue((ID3D12Fence *)&F); calls++;
            if (v != last) { if (last != (UINT64)-1 && v != last + 1) bad = 1; last = v; seen_vals[nseen] = v; seen_at[nseen++] = now_ns(); }
            if (v >= 5) break;
        }
        pthread_join(t, NULL);
        for (i = 0; i < nseen; i++) if (seen_vals[i] >= 1 && seen_vals[i] <= 5) {
            LONG64 d = seen_at[i] - signal_at[seen_vals[i]]; if (d > worst) worst = d; }
        printf("RESULT calls=%ld order_ok=%d distinct=%d worst_us=%lld backoffs=%d moved=%d polls_counted=%d g=%d rtl=%d logs=%d\n",
               calls, !bad, nseen, (long long)(worst / 1000), (int)g_fpb_n, (int)g_fpb_moved, (int)g_perf_polls, g_fpb, (int)g_rtl_sleeps, g_logs);
    } else if (!strcmp(mode, "slow")) {   /* an unchanged fence, polled every 100 us */
        int i;
        for (i = 0; i < 300; i++) { fence_GetCompletedValue((ID3D12Fence *)&F); usleep(100); }
        printf("RESULT backoffs=%d polls_counted=%d g=%d\n", (int)g_fpb_n, (int)g_perf_polls, g_fpb);
    } else if (!strcmp(mode, "cfg")) {
        fence_GetCompletedValue((ID3D12Fence *)&F);
        printf("RESULT g=%d wait_us=%lld logs=%d\n", g_fpb, (long long)(g_fpb_wait / 10), g_logs);
    } else if (!strcmp(mode, "count")) {   /* 1000 calls on a fence that moves every call */
        int i;
        for (i = 0; i < 1000; i++) {
            EnterCriticalSection(&F.lock); fence_set_locked(&F, (UINT64)i + 1); LeaveCriticalSection(&F.lock);
            if (fence_GetCompletedValue((ID3D12Fence *)&F) != (UINT64)i + 1) return 2;
        }
        printf("RESULT polls_counted=%d backoffs=%d g=%d\n", (int)g_perf_polls, (int)g_fpb_n, g_fpb);
    }
    return 0;
}
'''
code = harness.replace("STRUCT", struct).replace("SETL", setl).replace("FPB", fpb + "\n" + gcv if gcv not in fpb else fpb)
cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
if not cc:
    print("note: no host C compiler; the fence code was not built")
else:
    with tempfile.TemporaryDirectory() as tmp:
        c = os.path.join(tmp, "t.c"); exe = os.path.join(tmp, "t")
        open(c, "w").write(code)
        r = subprocess.run([cc, "-std=gnu11", "-O2", "-Wall", "-Werror", "-Wno-unused-function", "-pthread", "-o", exe, c],
                           capture_output=True, text=True)
        check("the fence code builds on the host", r.returncode == 0)
        if r.returncode:
            print(r.stderr[-3000:])
        else:
            def run(mode, n=None, us=None):
                env = {k: v for k, v in os.environ.items() if k not in ("T_N", "T_US")}
                if n is not None: env["T_N"] = str(n)
                if us is not None: env["T_US"] = str(us)
                out = subprocess.run([exe, mode], capture_output=True, text=True, env=env, timeout=60)
                line = [l for l in out.stdout.splitlines() if l.startswith("RESULT")]
                if out.returncode or not line:
                    return {"rc": out.returncode, "out": out.stdout + out.stderr}
                return dict(kv.split("=") for kv in line[0].split()[1:])
            for n, us, want_g, want_us in ((None, None, "0", "200"), (0, None, "0", "200"), (-5, None, "0", "200"), (1, None, "2", "200"),
                                           (64, 5, "64", "20"), (64, 99999, "64", "2000"), (64, 150, "64", "150")):
                res = run("cfg", n, us)
                check("config %s / %s us -> %s, %s us" % (n, us, want_g, want_us),
                      res.get("g") == want_g and res.get("wait_us") == want_us and res.get("logs") == ("0" if want_g == "0" else "1"))
            res = run("count")
            check("off: every call counted, no back-off", res.get("polls_counted") == "1000" and res.get("backoffs") == "0" and res.get("g") == "0")
            res = run("count", 64)
            check("on: polls counted in batches of 256 (1000 calls -> 768)", res.get("polls_counted") == "768" and res.get("backoffs") == "0")
            off = run("spin")
            on = run("spin", 64)
            check("off: the spinner sees 0..5 in order, never sleeps",
                  off.get("order_ok") == "1" and off.get("backoffs") == "0" and off.get("rtl") == "0")
            check("on: the spinner sees 0..5 in order (values the fence had)", on.get("order_ok") == "1" and on.get("distinct") == "6")
            b, m = int(on.get("backoffs", 0)), int(on.get("moved", 0))
            check("on: the spinner backs off, and the fence moving ends some back-offs (%d back-offs, %d moved)" % (b, m), b > 10 and m >= 1)
            check("on: each new value seen within 5 ms of its signal (worst %s us; the cap is 200 us)" % on.get("worst_us"),
                  int(on.get("worst_us", 10**9)) < 5000)
            co, cn = int(off.get("calls", 0)), int(on.get("calls", 1))
            check("on: far fewer calls than the same spin off (%d vs %d)" % (cn, co), cn * 10 < co)
            res = run("slow", 64)
            check("on: a caller slower than one call per 50 us never sleeps (%s back-offs)" % res.get("backoffs"), res.get("backoffs") == "0")
sys.exit(0 if ok else 1)
