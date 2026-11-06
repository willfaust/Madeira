#!/usr/bin/env python3
"""Vector registers in a cross-thread context (build/wineserver/mach_ios.c); no Wine runs.

The server's Mach capture read only ARM_THREAD_STATE64, so every cross-thread GetThreadContext
returned zeroed XMM registers. Persona 5 Royal reads another thread's floating-point context into
a CONTEXT inside its image and jumps to the XMM13 slot, and executed zeros. Checks that the syscall
frame offsets the capture reads match struct syscall_frame, that the syscall dispatcher saves every
vector register there, that the capture is gated by MADEIRA_CTX_FP and runs while the thread is
halted, and the switch itself: unset or 1 captures, 0 restores the zeroed registers, and the
madeira.cfg line wins over the environment.
"""
from pathlib import Path
import re, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/wineserver/mach_ios.c").read_text()
sig = (root / "build/ntdll-unix/signal_arm64_ios.c").read_text()

def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]

offs = dict(re.findall(r"#define (IOS_SCF_\w+)\s+(0x[0-9a-f]+)\b", src))
frame = sig[sig.index("struct syscall_frame\n{"):]
frame = frame[:frame.index("};") + 2]
harness = r"""
#include <stddef.h>
#include <stdint.h>
typedef uint64_t ULONG64; typedef uint32_t ULONG;
typedef struct { uint64_t Low; int64_t High; } NEON128;
""" + frame + "\n"
for name, field in (("FP", "fp"), ("LR", "lr"), ("SP", "sp"), ("PC", "pc"), ("CPSR", "cpsr"),
                    ("FPCR", "fpcr"), ("FPSR", "fpsr"), ("V", "v")):
    harness += f"_Static_assert(offsetof(struct syscall_frame, {field}) == {offs['IOS_SCF_' + name]}, \"{name}\");\n"
harness += f"_Static_assert(sizeof(struct syscall_frame) == {offs['IOS_SCF_SIZE']}, \"SIZE\");\n"
harness += "int main(void) { return 0; }\n"
with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "layout.c"; c.write_text(harness)
    subprocess.run(["cc", "-std=gnu11", "-Wall", str(c), "-o", str(Path(t) / "layout")], check=True)
print("PASS: the IOS_SCF offsets match struct syscall_frame, including fpcr, fpsr and v[32]")

dispatcher = sig[sig.index("__ASM_GLOBAL_FUNC( __wine_syscall_dispatcher,"):]
dispatcher = dispatcher[:dispatcher.index("__ASM_GLOBAL_FUNC(", 10)]
for q in range(0, 32, 2):
    assert re.search(rf'"stp q{q},\s+q{q + 1},\s+\[x10, #0x{0x130 + q * 16:x}\]', dispatcher), q
assert '"str w9, [x10, #0x128]' in dispatcher and '"str w9, [x10, #0x12c]' in dispatcher
print("PASS: the syscall dispatcher saves q0-q31, fpcr and fpsr where the capture reads them")

fill = function(src, "int ios_fill_thread_context(")
neon = fill.index("thread_get_state( port, ARM_NEON_STATE64")
assert fill.index("thread_suspend( port )") < fill.index("thread_get_state( port, ARM_THREAD_STATE64") < neon
assert neon < fill.index("f + IOS_SCF_V") < fill.rindex("thread_resume( port );")
assert "if (have_native && ios_ctx_fp_enabled())" in fill[:neon]
assert "(native->flags & SERVER_CTX_FLOATING_POINT)" in fill[neon:fill.index("f + IOS_SCF_V")]
assert "native->flags |= SERVER_CTX_FLOATING_POINT;" in fill
print("PASS: the vector capture is gated by MADEIRA_CTX_FP, runs while the thread is halted, and the "
      "frame override only replaces a capture that happened")

switch = function(src, "static int ios_ctx_fp_enabled(void)")
harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char *cfg_value;
static int madeira_cfg_get(const char *key, char *buf, size_t cap)
{
    if (strcmp(key, "env.MADEIRA_CTX_FP") || !cfg_value) return 0;
    snprintf(buf, cap, "%s", cfg_value);
    return 1;
}
/* the server's clock: the answer is kept for a second, so the checks step it */
typedef long long timeout_t;
#define TICKS_PER_SEC 10000000
static timeout_t monotonic_time;
""" + switch + r"""
#define CHECK(x) do { if (!(x)) { printf("failed line %d: %s\n", __LINE__, #x); return 1; } } while (0)
#define LATER (monotonic_time += TICKS_PER_SEC)
int main(void)
{
    unsetenv("MADEIRA_CTX_FP");
    CHECK(ios_ctx_fp_enabled());
    LATER; setenv("MADEIRA_CTX_FP", "1", 1); CHECK(ios_ctx_fp_enabled());
    LATER; setenv("MADEIRA_CTX_FP", "0", 1); CHECK(!ios_ctx_fp_enabled());
    /* within the second the kept answer stands: no file read for a program that captures often */
    setenv("MADEIRA_CTX_FP", "1", 1); CHECK(!ios_ctx_fp_enabled());
    LATER; CHECK(ios_ctx_fp_enabled());
    LATER; cfg_value = "0"; CHECK(!ios_ctx_fp_enabled());
    LATER; cfg_value = "1"; setenv("MADEIRA_CTX_FP", "0", 1); CHECK(ios_ctx_fp_enabled());
    LATER; unsetenv("MADEIRA_CTX_FP"); cfg_value = "0"; CHECK(!ios_ctx_fp_enabled());
    return 0;
}
"""
with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "switch.c"; c.write_text(harness)
    exe = Path(t) / "switch"
    subprocess.run(["cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror",
                    str(c), "-o", str(exe)], check=True)
    run = subprocess.run([str(exe)], capture_output=True, text=True)
    print(run.stdout, end="")
    run.check_returncode()
print("PASS: MADEIRA_CTX_FP unset or 1 captures, 0 restores zeroed registers, madeira.cfg wins over the environment")
