#!/usr/bin/env python3
"""lean-diag: env.MADEIRA_LEAN_DIAG = 1 makes the periodic diagnostics cheap; no Wine runs.

Every game session runs, by default, diagnostics that suspend threads or walk
the whole address space (Horizon Zero Dawn, builds 486-493):
  - [thread-sample]: every 20 s, every thread suspended 4 times;
  - the guest RIP profile behind [rip-profile]/[cpu-split]: then ~200 passes
    suspending up to 12 game threads, from a utility-QoS thread;
  - [wprof]: a 3 s, 1 kHz burst over the submission workers every 15 s;
  - the pool warmer's [phys-map] walk (83,000-95,000 regions, 0.12-0.39 s of
    P-core time a minute, 3.2 s once clamped), the slot/window inventory
    (~72,000 regions a minute), the .text max_prot sweep every 10 s, a malloc
    zone check and four vm_allocate probes every 2 s;
  - mprotect_exec's ERR line on every call (~49,000 lines a session, ~400/s
    while the game loads).
MADEIRA_LEAN_DIAG=1 turns the suspending samplers off, runs the walks every
~10 min and the 2 s probes every minute, and logs mprotect_exec's first 200
calls, then every 1000th. The owner's analysis lines keep their rates:
[xp]/[xp-t] every 250 ms, [xp-api]/[xp-api-top] every second, [sync-census]
every 20 s (abline, bucket, xptphase, energyfit, clampstats, apitop).

Checks (unset = byte-identical behaviour):
  - the switch is read once where the samplers are armed, and [wprof] is not
    started with it;
  - ios_thread_sampler_main compiled on this host: without the switch 4 passes
    and one guest profile per 20 s burst, exactly as before; with it no pass,
    no profile, and both [sync-census] lines every 20 s;
  - the [xp] sampler and the [xp-api] reporter do not look at the switch;
  - virtual_ios.c's helpers compiled on this host: the sweep period is 30
    cycles (300 with the switch, MADEIRA_WARMER_SWEEP_CYCLES wins either way);
    every mprotect_exec line is logged without the switch, 200 + 1 in 1000
    with it; the warmer's periodic probes are gated as described;
  - the catalog lists the switch and CI runs this check.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "build/ntdll-unix/server_ios.c"
VIRT = ROOT / "build/ntdll-unix/virtual_ios.c"
CAT = ROOT / "app/Madeira/ConfigCatalog.generated.swift"
GEN = ROOT / "build/tools/gen-config-catalog.py"
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


def compile_run(code, name, env_list):
    with tempfile.TemporaryDirectory(prefix="madeira-lean-") as t:
        c = Path(t) / (name + ".c")
        exe = Path(t) / name
        c.write_text(code)
        cc = os.environ.get("CC", "cc")
        base = [cc, "-std=gnu11", "-O1", "-Wall", "-Wno-unused-function", "-Wno-unused-variable", str(c), "-o", str(exe)]
        r = subprocess.run(base[:1] + ["-fsanitize=address,undefined", "-fno-sanitize-recover=all"] + base[1:],
                           capture_output=True, text=True)
        if r.returncode != 0:
            r = subprocess.run(base, capture_output=True, text=True)
        if r.returncode != 0:
            return None, r.stderr
        outs = []
        clean = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}
        for extra in env_list:
            rr = subprocess.run([str(exe)], capture_output=True, text=True, env=dict(clean, **extra))
            outs.append((rr.returncode, rr.stdout, rr.stderr))
        return outs, ""


server = SERVER.read_text(encoding="utf-8")
virt = VIRT.read_text(encoding="utf-8")

# ---- arming site -----------------------------------------------------------
arm_at = server.find("if (__sync_bool_compare_and_swap(&ios_ts_armed, 0, 1))")
arm = server[arm_at:server.find("ios_wprof_main(); });", arm_at) + 40]
check(arm_at > 0 and 'const char *lean_env = getenv("MADEIRA_LEAN_DIAG");' in arm,
      "MADEIRA_LEAN_DIAG is read where the samplers are armed (once a process)")
check('ios_lean_diag = lean_env && *lean_env && strcmp(lean_env, "0") != 0;' in arm,
      "unset, empty or 0 leaves it off")
# (a build may also gate each sampler on a probes level of its own: "if (probes >= N ...")
check(re.search(r"if \((?:probes >= 2 && )?!ios_lean_diag\) dispatch_async\(dispatch_get_global_queue\(QOS_CLASS_UTILITY, 0\), "
                r"\^\{ ios_wprof_main\(\); \}\);", arm),
      "[wprof] is not started with the switch")
check(re.search(r"(?:if \(probes >= 2\) )?dispatch_async\(dispatch_get_global_queue\(QOS_CLASS_UTILITY, 0\), "
                r"\^\{ ios_thread_sampler_main\(\); \}\);", arm)
      and re.search(r"(?:if \(probes >= 1\) )?dispatch_async\(dispatch_get_global_queue\(QOS_CLASS_UTILITY, 0\), "
                    r"\^\{ ios_xprobe_main\(\); \}\);", arm)
      and "ios_lean_diag" not in arm[arm.find("ios_thread_sampler_main(); });") - 120:arm.find("ios_xprobe_main(); });")],
      "the thread sampler (for [sync-census]) and the [xp] sampler start as before")
check(server.find("static int ios_lean_diag;") < server.find("static void ios_thread_sampler_main(void)"),
      "ios_lean_diag is declared before the sampler")

# ---- the [xp] family does not change -----------------------------------------
xprobe = func_body(server, "static void ios_xprobe_main( void )")
apirep = func_body(server, "static void ios_xp_api_report( const char *wall, double wall_s )")
check(bool(xprobe) and bool(apirep) and "ios_lean_diag" not in xprobe and "ios_lean_diag" not in apirep,
      "[xp]/[xp-t]/[xp-api]/[xp-api-top] do not depend on the switch")
check("usleep( 250000 );" in xprobe and "if (!(gen & 3)) ios_xp_api_report(" in xprobe,
      "[xp] stays at 250 ms and [xp-api] at every 4th sample")

# ---- ios_thread_sampler_main on this host ----------------------------------
sampler = func_body(server, "static void ios_thread_sampler_main(void)")
check(bool(sampler), "ios_thread_sampler_main found")
harness = r'''
#define _GNU_SOURCE
#include <setjmp.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
typedef struct { uint32_t numer, denom; } mach_timebase_info_data_t;
static void mach_timebase_info( mach_timebase_info_data_t *t ) { t->numer = 125; t->denom = 3; }
static jmp_buf done; static int sleeps, passes, profiles, census1115, census1122, bursts, armed_lean, armed_full;
static int ios_lean_diag;
volatile long long ios_alert_wakes, ios_alert_waits, ios_qpc_syscalls, ios_affinity_sets;
volatile int ios_srv_req_count;
volatile long long ios_alert_lat_n, ios_alert_lat_ticks, ios_alert_lat_hist[6], ios_alert_spin_tries, ios_alert_spin_hits;
static void ios_ts_calibrate( void ) {}
static void ios_stuck_store_check( void ) {}   /* ml1288's 100 ms check between bursts (MADEIRA_STUCK_CHECK) */
static void ios_thread_sampler_pass( int b ) { (void)b; passes++; }
static void ios_guest_rip_profile( int gen ) { (void)gen; profiles++; }
static unsigned h_sleep( unsigned s ) { if (s != 20) abort(); if (++sleeps > 5) longjmp( done, 1 ); ios_alert_wakes += 100; return 0; }
/* ml1288 waits the 20 s between bursts as 200 ticks of 100 ms (the stuck-store check runs
 * between them): every 200th such tick is one 20 s period. */
static unsigned ticks;
static int h_usleep( unsigned us ) { if (us == 100000 && ++ticks % 200 == 0) h_sleep( 20 ); return 0; }
static void wine_log_write( const char *fmt, ... ) __attribute__((format(printf, 1, 2)));
static void wine_log_write( const char *fmt, ... )
{
    char b[2048]; va_list ap; va_start( ap, fmt ); vsnprintf( b, sizeof(b), fmt, ap ); va_end( ap );
    if (!strncmp( b, "[sync-census] ml1115", 20 )) census1115++;
    if (!strncmp( b, "[sync-census] ml1122", 20 )) census1122++;
    if (!strcmp( b, "[thread-sample] ml876 burst done" )) bursts++;
    if (!strcmp( b, "[thread-sample] ml876 armed (task-wide: burst of 4 passes / 250 ms every 20 s)" )) armed_full++;
    if (strstr( b, "armed for [sync-census] only" )) armed_lean++;
}
#define sleep(x) h_sleep(x)
#define usleep(x) h_usleep(x)
''' + sampler + r'''
int main( void )
{
    const char *e = getenv( "LEAN" );
    ios_lean_diag = e && *e == '1';
    if (!setjmp( done )) ios_thread_sampler_main();
    printf( "%d %d %d %d %d %d %d %d\n", sleeps - 1, passes, profiles, bursts, census1115, census1122, armed_full, armed_lean );
    return 0;
}
'''
outs, err = compile_run(harness, "sampler", [{}, {"LEAN": "1"}])
if outs is None:
    check(False, "ios_thread_sampler_main compiles on this host: " + err[-800:])
else:
    full = [int(x) for x in outs[0][1].split()]
    lean = [int(x) for x in outs[1][1].split()]
    # 5 completed 20 s iterations each
    check(full[:4] == [5, 20, 5, 5] and full[6] == 1 and full[7] == 0,
          "without the switch: 4 passes and one guest profile every 20 s, as before (%s)" % full)
    check(full[4] >= 4 and full[5] == 5, "without the switch: both [sync-census] lines every 20 s (%s)" % full)
    check(lean[:4] == [5, 0, 0, 0] and lean[6] == 0 and lean[7] == 1,
          "with the switch: no pass, no guest profile, no burst line (%s)" % lean)
    check(lean[4] >= 4 and lean[5] == 5, "with the switch: [sync-census] every 20 s as before (%s)" % lean)

# ---- virtual_ios.c helpers on this host -------------------------------------
lean_v = func_body(virt, "static int ios_lean_diag_virtual( void )")
mlog = func_body(virt, "static int ios_lean_mprotect_log( void )")
sweep = func_body(virt, "static unsigned ios_warmer_sweep_cycles( void )")
check(bool(lean_v) and bool(mlog) and bool(sweep), "virtual_ios.c helpers found")
check("static volatile int ios_lean_mprotect_on;" in virt and "getenv" not in mlog,
      "mprotect_exec's gate reads a flag, never the environment (it can run in a fault path)")
vharness = r'''
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static volatile int ios_lean_mprotect_on;
''' + lean_v + "\n" + mlog + "\n" + sweep + r'''
int main( void )
{
    long i, logged = 0, first_gap = 0;
    ios_lean_mprotect_on = ios_lean_diag_virtual();   /* as the warmer thread does when it starts */
    for (i = 1; i <= 5000; i++)
    {
        if (ios_lean_mprotect_log()) logged++;
        else if (!first_gap) first_gap = i;
    }
    printf( "%d %u %ld %ld\n", ios_lean_diag_virtual(), ios_warmer_sweep_cycles(), logged, first_gap );
    return 0;
}
'''
outs, err = compile_run(vharness, "virt", [{}, {"MADEIRA_LEAN_DIAG": "1"}, {"MADEIRA_LEAN_DIAG": "0"},
                                           {"MADEIRA_LEAN_DIAG": "1", "MADEIRA_WARMER_SWEEP_CYCLES": "5"},
                                           {"MADEIRA_WARMER_SWEEP_CYCLES": "5"}])
if outs is None:
    check(False, "virtual_ios.c helpers compile on this host: " + err[-800:])
else:
    r = [o[1].split() for o in outs]
    check(r[0] == ["0", "30", "5000", "0"], "unset: sweep every 30 cycles, every mprotect_exec line logged (%s)" % r[0])
    check(r[1] == ["1", "300", str(200 + 5), "201"], "MADEIRA_LEAN_DIAG=1: sweep every 300 cycles, 200 lines then 1 in 1000 (%s)" % r[1])
    check(r[2] == ["0", "30", "5000", "0"], "MADEIRA_LEAN_DIAG=0 is off (%s)" % r[2])
    check(r[3][1] == "5" and r[4][1] == "5", "MADEIRA_WARMER_SWEEP_CYCLES still wins (%s %s)" % (r[3], r[4]))
    check(outs[1][2].count("[lean-diag] mprotect_exec: 200 calls logged") == 1 and "[lean-diag]" not in outs[0][2],
          "the 200th call announces the thinning once, and only with the switch")

# ---- the warmer's gates -------------------------------------------------------
warm = func_body(virt, "static void *ios_pool_warmer_thread( void *arg )")
check(bool(warm), "ios_pool_warmer_thread found")
check("if ((cycle % 5) == 0 && rx)\n            if (!ios_lean_diag_virtual() || (cycle % 30) == 0)   /* madeira-bcd lean-diag: every 30 */" in warm,
      ".text max_prot sweep: every 5 cycles, 30 with the switch")
check("if (!ios_lean_diag_virtual() || cycle == 1 || (cycle % 30) == 0)   /* madeira-bcd lean-diag */" in warm,
      "CoreAnimation shmem replay: every cycle, every 30 with the switch")
check("if (!zone_bad && (!ios_lean_diag_virtual() || cycle == 1 || (cycle % 30) == 0))" in warm,
      "malloc zone check: every cycle, every 30 with the switch (cost logged then)")
check("if (cycle == 2 || (cycle % ios_warmer_sweep_cycles()) == 0)" in warm
      and "(cycle % ios_warmer_sweep_cycles()) == 0))" in warm,
      "[phys-map] and the slot/window inventory follow ios_warmer_sweep_cycles")
check(warm.count("ios_lean_diag_virtual()") == 5, "no other warmer step depends on the switch (page warming, [footprint], pump sample)")
check(warm.find("ios_lean_mprotect_on = ios_lean_diag_virtual();") < warm.find("for (;;)"),
      "the warmer sets mprotect_exec's flag before its first cycle")
check("if (!ios_in_mach_exc && ios_lean_mprotect_log())   /* ml374: see ios_in_mach_exc; madeira-bcd lean-diag */" in virt
      and virt.count("ios_lean_mprotect_log()") == 1, "only mprotect_exec's per-call ERR line is thinned")

# ---- catalog and CI -------------------------------------------------------------
gen = GEN.read_text(encoding="utf-8")
cat = CAT.read_text(encoding="utf-8")
check('"env.MADEIRA_LEAN_DIAG"' in gen and "env.MADEIRA_LEAN_DIAG" in cat, "the catalog documents env.MADEIRA_LEAN_DIAG")
# The CI step exists only in the fork's workflow; upstream has no .github.
if CI.exists():
    ci = CI.read_text(encoding="utf-8")
    check("- name: Check lean-diag" in ci and "python3 tests/host/check-lean-diag.py" in ci, "CI runs this check")

if failures:
    print("FAILED: %d" % len(failures))
    sys.exit(1)
print("OK")
