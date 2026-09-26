#!/usr/bin/env python3
"""Production-source regression for the identical-redelivery storm run; no Wine or guest runs."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/signal_arm64_ios.c").read_text()
def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]
helper = function(src, "static int ios_redeliv_run_continues(")
gap = [l for l in src.splitlines() if l.startswith("#define IOS_REDELIV_GAP_MS")][0]
a = src.index("        int run;\n", src.index("static unsigned int progress_logs;"))
b = src.index("redeliv[rslot].n = 1; }", a) + len("redeliv[rslot].n = 1; }")
counting = src[a:b]
code = r"""
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <unistd.h>
static unsigned long long clock_ticks;
static unsigned long long mach_absolute_time(void) { return clock_ticks; }
static unsigned long long ios_sb_ticks_per_ms(void) { return 24000; }   /* 24 MHz timebase */
""" + gap + "\n" + helper + r"""
static struct { uint64_t key; uint32_t n; unsigned long long last; } redeliv[16];
static unsigned int progress_logs;
static unsigned deliver(unsigned thread, uint64_t pc, uint64_t fault_addr) {
    uint64_t rkey = ((uint64_t)thread << 48) ^ pc ^ ((uint64_t)fault_addr << 1);
    int rslot = (int)((rkey >> 4) & 15);
""" + counting + r"""
    else ++redeliv[rslot].n;
    return redeliv[rslot].n;
}
static void reset(void) { memset(redeliv, 0, sizeof(redeliv)); clock_ticks = 1000000; }
int main(int argc, char **argv) {
    unsigned n = 0, i, s, best = 0;
    uint64_t sites[8] = {0x135dc7c7c, 0x70354f6c8d, 0x134a34a84, 0x160ba08d6,
                         0x1359fe85c, 0x176f52e2c, 0x135e61090, 0x70354f770e};
    if (argc > 1) {                           /* rollback: cumulative counting */
        setenv("MADEIRA_REDELIV_PROGRESS", "0", 1); reset();
        for (i = 0; i < 2000; ++i) { clock_ticks += 28 * 24000; n = deliver(0x2403, sites[0], 0); }
        assert(n == 2000); puts("PASS: rollback counts one site per frame to the terminal"); return 0;
    }
    reset();                                  /* real storm: refault at once, 0.5 ms apart */
    for (i = 0; i < 2500; ++i) { clock_ticks += 12000; n = deliver(0x2403, 0x137389368, 0); }
    assert(n == 2500);
    reset();                                  /* storm as slow as the gap still counts */
    for (i = 0; i < 2100; ++i) { clock_ticks += 8 * 24000; n = deliver(0x2403, 0x137389368, 0); }
    assert(n == 2100);
    reset();                                  /* device log 161: 8 sites per frame, 28 ms frames */
    for (i = 0; i < 5000; ++i)
        for (s = 0; s < 8; ++s) { clock_ticks += 3 * 24000 + (s == 7 ? 7 * 24000 : 0);
                                  n = deliver(0x2403, sites[s], 0); if (n > best) best = n; }
    assert(best == 1);
    reset(); best = 0;                        /* one site per frame at 144 FPS */
    for (i = 0; i < 5000; ++i) { clock_ticks += 7 * 24000 / 1 + 24000 * 2; n = deliver(0x2403, sites[0], 0); if (n > best) best = n; }
    assert(best == 1);
    reset(); best = 0;                        /* two threads storming separately still count */
    for (i = 0; i < 2100; ++i) { clock_ticks += 12000; deliver(0x2403, 0x137389368, 0); n = deliver(0x5507, 0x1359fe85c, 0); }
    assert(n == 2100);
    reset();                                  /* a storm that resumes after a pause restarts */
    for (i = 0; i < 300; ++i) { clock_ticks += 12000; n = deliver(0x2403, 0x137389368, 0); }
    clock_ticks += 50 * 24000; n = deliver(0x2403, 0x137389368, 0); assert(n == 1);
    assert(progress_logs == 1);
    printf("PASS: storms reach the terminal (fast, at the gap, two threads); interleaved sites, per-frame faults and pauses reset\n");
    return 0;
}
"""
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/"check.c"; exe = Path(tmp)/"check"; c.write_text(code)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-no-pie", str(c), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
    subprocess.run([str(exe), "rollback"], check=True)
