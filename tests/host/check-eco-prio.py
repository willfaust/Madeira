#!/usr/bin/env python3
"""eco-prio: env.MADEIRA_ECO_PRIO (opt-in) keeps a guest thread that raises
ITS OWN priority on the user-interactive QoS while eco is on; no Wine runs.

With eco = 1 every guest thread runs at the eco QoS class (efficiency cores).
Horizon Forbidden West on build 531 had 6-8 threads waiting for a core there
while the performance cores were mostly idle, and madeira-d3d12's fence worker
(it advances a fence once the GPU is done) and async-submit's submission
workers waited for the same cores. With the switch those threads, and any game
thread that sets itself to TIME_CRITICAL (1) or HIGHEST and above (2), keep the
user-interactive QoS.

Checks:
  - ios_eco_prio_level / ios_eco_prio_note (thread_ios.c) compiled on this
    host with stand-ins: unset or 0 = no QoS call, no line, no thread query;
    1 = TIME_CRITICAL on itself with eco on -> one user-interactive call and
    one [eco-prio] line, HIGHEST -> nothing; 2 = HIGHEST too; eco off ->
    nothing; another thread's handle -> never touched; raising twice -> one
    call; lowering afterwards -> back to the eco class once; a refused QoS
    call is not remembered as raised; the env is read once;
  - NtSetInformationThread(ThreadBasePriority) calls it only after the server
    accepted the priority;
  - madeira-d3d12's fence worker and submission workers ask for TIME_CRITICAL
    only when the switch is set (mad_eco_prio_self), the fence worker with
    [xp-t] role F;
  - the catalog lists the switch and CI runs this check.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
THREAD = ROOT / "build/ntdll-unix/thread_ios.c"
D3D12 = ROOT / "madeira-d3d12/src/pe/madeira_d3d12.c"
CAT = ROOT / "app/Madeira/ConfigCatalog.generated.swift"
CI = ROOT / ".github/workflows/build-ipa.yml"

failures = []


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


def func_body(src, signature):
    i = src.find(signature)
    if i < 0:
        return ""
    j = src.find("{", i)
    depth = 0
    for k in range(j, len(src)):
        if src[k] == "{":
            depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0:
                return src[i:k + 1]
    return ""


thread = THREAD.read_text(encoding="utf-8")
d3d12 = D3D12.read_text(encoding="utf-8")

lvl = func_body(thread, "static int ios_eco_prio_level( void )")
note = func_body(thread, "static void ios_eco_prio_note( HANDLE handle, LONG priority )")
check(bool(lvl) and bool(note), "ios_eco_prio_level and ios_eco_prio_note found in thread_ios.c")
check("static __thread int ios_eco_prio_raised;" in thread, "per-thread raised flag")

harness = r'''
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
typedef void *HANDLE; typedef long LONG; typedef unsigned long ULONG; typedef int NTSTATUS;
typedef struct { HANDLE UniqueProcess, UniqueThread; } CLIENT_ID;
typedef struct { NTSTATUS ExitStatus; void *TebBaseAddress; CLIENT_ID ClientId; } THREAD_BASIC_INFORMATION;
enum { ThreadBasicInformation = 0 };
#define THREAD_PRIORITY_HIGHEST 2
#define THREAD_PRIORITY_TIME_CRITICAL 15
#define GetCurrentThread() ((HANDLE)~(size_t)1)
#define GetCurrentThreadId() 0x40u
#define HandleToULong(h) ((ULONG)(size_t)(h))
#include <pthread/qos.h>   /* qos_class_t, QOS_CLASS_USER_INTERACTIVE = 0x21 */
static int qos_calls, qos_last = -1, qos_refuse, apply_calls, queries, getenvs, eco_on, lines;
static int h_qos( qos_class_t c, int rel ) { (void)rel; qos_calls++; qos_last = c; return qos_refuse; }
#define pthread_set_qos_class_self_np h_qos
int madeira_get_eco( void ) { return eco_on; }
void ios_eco_apply_self( void ) { apply_calls++; }
static NTSTATUS NtQueryInformationThread( HANDLE h, int cls, void *info, ULONG len, ULONG *ret )
{
    THREAD_BASIC_INFORMATION *t = info; (void)cls; (void)len; (void)ret; queries++;
    memset( t, 0, sizeof(*t) ); t->ClientId.UniqueThread = h; return 0;   /* the handle value is the thread id */
}
static char *h_getenv( const char *n ) { getenvs++; return getenv( n ); }
#define getenv h_getenv
static int h_dprintf( int fd, const char *fmt, ... ) { va_list ap; (void)fd; lines++; va_start( ap, fmt ); vfprintf( stderr, fmt, ap ); va_end( ap ); return 0; }
#define dprintf h_dprintf
''' + lvl + "\n" + "static __thread int ios_eco_prio_raised;\n" + note + r'''
int main( int argc, char **argv )
{
    const char *s = argc > 1 ? argv[1] : "";
    eco_on = 1;
    if (!strcmp( s, "self15" )) ios_eco_prio_note( GetCurrentThread(), 15 );
    else if (!strcmp( s, "self2" )) ios_eco_prio_note( GetCurrentThread(), 2 );
    else if (!strcmp( s, "own-handle" )) ios_eco_prio_note( (HANDLE)0x40, 15 );
    else if (!strcmp( s, "other" )) ios_eco_prio_note( (HANDLE)0x44, 15 );
    else if (!strcmp( s, "eco-off" )) { eco_on = 0; ios_eco_prio_note( GetCurrentThread(), 15 ); }
    else if (!strcmp( s, "twice-lower" )) { ios_eco_prio_note( GetCurrentThread(), 15 ); ios_eco_prio_note( GetCurrentThread(), 15 );
                                            ios_eco_prio_note( GetCurrentThread(), 0 ); ios_eco_prio_note( GetCurrentThread(), 0 ); }
    else if (!strcmp( s, "refused" )) { qos_refuse = 1; ios_eco_prio_note( GetCurrentThread(), 15 ); qos_refuse = 0; ios_eco_prio_note( GetCurrentThread(), 15 ); }
    else if (!strcmp( s, "normal" )) { ios_eco_prio_note( GetCurrentThread(), 0 ); ios_eco_prio_note( (HANDLE)0x44, 1 ); }
    printf( "%d %d %d %d %d %d\n", qos_calls, qos_last, apply_calls, queries, lines, getenvs );
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix="madeira-eco-prio-") as t:
    c = Path(t) / "eco.c"
    exe = Path(t) / "eco"
    c.write_text(harness)
    cc = os.environ.get("CC", "cc")
    r = subprocess.run([cc, "-std=gnu11", "-Wall", "-Werror", "-Wno-unused-function", str(c), "-o", str(exe)],
                       capture_output=True, text=True)
    check(r.returncode == 0, "ios_eco_prio_note compiles on this host" + ("" if r.returncode == 0 else ": " + r.stderr[-800:]))
    if r.returncode == 0:
        clean = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}

        def run(val, scen):
            env = dict(clean, **({"MADEIRA_ECO_PRIO": val} if val is not None else {}))
            o = subprocess.run([str(exe), scen], capture_output=True, text=True, env=env)
            return o.stdout.split(), o.stderr

        UI = str(0x21)
        for val in (None, "", "0"):
            out, err = run(val, "self15")
            check(out == ["0", "-1", "0", "0", "0", "1"] and err == "", "MADEIRA_ECO_PRIO=%r: nothing happens, env read once (%s)" % (val, out))
        out, err = run("1", "self15")
        check(out == ["1", UI, "0", "0", "1", "1"] and "set itself to priority 15: user-interactive QoS while eco is on (MADEIRA_ECO_PRIO=1)" in err,
              "1: TIME_CRITICAL on itself -> user-interactive, one line (%s)" % out)
        out, _ = run("1", "self2")
        check(out[:4] == ["0", "-1", "0", "0"], "1: HIGHEST is not enough (%s)" % out)
        out, _ = run("2", "self2")
        check(out[:2] == ["1", UI], "2: HIGHEST raises (%s)" % out)
        out, _ = run("1", "own-handle")
        check(out[:4] == ["1", UI, "0", "1"], "its own real handle: one thread query, raised (%s)" % out)
        out, _ = run("1", "other")
        check(out[:4] == ["0", "-1", "0", "1"], "another thread's handle: queried, never touched (%s)" % out)
        out, _ = run("1", "eco-off")
        check(out[:4] == ["0", "-1", "0", "0"], "eco off: nothing to do (%s)" % out)
        out, err = run("1", "twice-lower")
        check(out[:3] == ["1", UI, "1"] and err.count("back to the eco QoS class") == 1,
              "raised twice -> one call; lowered twice -> back to the eco class once (%s)" % out)
        out, err = run("1", "refused")
        check(out[:2] == ["2", UI] and "REFUSED" in err, "a refused QoS call is not remembered: the next raise tries again (%s)" % out)
        out, _ = run("2", "normal")
        check(out[:5] == ["0", "-1", "0", "0", "0"], "normal priorities, own or another thread's: no query, no call (%s)" % out)

setp = func_body(thread, "NTSTATUS WINAPI NtSetInformationThread( HANDLE handle, THREADINFOCLASS class,")
base = setp[setp.index("    case ThreadBasePriority:"):]
base = base[:base.index("    case ThreadAffinityMask:")]
check("SERVER_END_REQ;\n        if (!status) ios_eco_prio_note( handle, (LONG)*base_priority );   /* madeira-bcd eco-prio (opt-in) */\n        return status;" in base,
      "ThreadBasePriority: noted only after the server accepted it")
callers = [p.name for p in (ROOT / "build/ntdll-unix").glob("*.c") if "ios_eco_prio_note(" in p.read_text(errors="ignore")]
check(callers == ["thread_ios.c"] and thread.count("ios_eco_prio_note(") == 2, "no other caller (%s)" % callers)

self_fn = func_body(d3d12, "static void mad_eco_prio_self(char role) {")
check('GetEnvironmentVariableA("MADEIRA_ECO_PRIO", v, sizeof v)' in self_fn and
      "if (!n || n >= sizeof v || v[0] == '0') return;" in self_fn and
      self_fn.index("return;") < self_fn.index("SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);"),
      "mad_eco_prio_self: TIME_CRITICAL only with the switch set")
fw = func_body(d3d12, "static DWORD WINAPI mad_fence_worker(void *arg) {")
sw = func_body(d3d12, "static DWORD WINAPI mad_sub_worker(void *arg) {")
check("mad_eco_prio_self('F');" in fw.split("for (;;)")[0], "the fence worker asks first thing, with role F")
check("mad_eco_prio_self(0);" in sw.split("for (;;)")[0], "the submission worker asks first thing")
check(d3d12.count("mad_eco_prio_self(") == 3, "no other d3d12 thread asks")

cat = CAT.read_text(encoding="utf-8")
check('ConfigOption(key: "env.MADEIRA_ECO_PRIO"' in cat, "the catalog documents env.MADEIRA_ECO_PRIO")
# The CI step exists only in the fork's workflow; upstream has no .github.
if CI.exists():
    check("python3 tests/host/check-eco-prio.py" in CI.read_text(encoding="utf-8"), "CI runs this check")

if failures:
    print("FAILED: %d" % len(failures))
    sys.exit(1)
print("OK")
