#!/usr/bin/env python3
"""An unaligned ordered/exclusive/LSE access in the app's own code is emulated
in place instead of being handed to FEX; no Wine runs.

GTA V Enhanced's Rockstar Games Launcher died on build 454 twice (logs
2026-10-08 15:41:42 and 15:44:14): a launcher thread ran `stlr w21, [x19]`
(0x889ffe75) at Madeira+0xb5310c on an address crossing a 16-byte boundary,
both fault paths handed it to FEX as 80000002, FEX took the pc for guest code,
and the Launcher exited with c0000005. build/ntdll-unix/signal_arm64_ios.c's
ios_native_unaligned_emulate now does such an access byte-wise when the pc is
in the executable's __TEXT. Compiles it (with ios_emulate_store_rel and
ios_emulate_load_acq, from the source) against a fake ucontext and a fake
Mach-O header, and checks with encodings from the AArch64 assembler:
  - the crash's own `stlr w21, [x19]` on ...b3f stores w21's 4 bytes there,
    byte-exact, and nothing around them;
  - LDAR / LDAPR / LDAPUR / LDXR / LDAXR load zero-extended into Rt (WZR/XZR
    stays unwritten); STLUR, STXR (status 0), STLXR and LDADDAL / SWPAL work;
  - a pc outside __TEXT (FEX's code) is refused and touches nothing, as are
    CASAL, a SIMD pair with writeback and a plain LDR (which the existing
    emulator already handles);
and textually that both the Mach path and bus_handler call it, after the
plain emulator and before the 80000002 hand-off.
Needs python3 and a C compiler.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()


def function(signature):
    start = src.index(signature + '\n{')   # the definition, not a forward declaration
    return src[start:src.index('\n}\n', start) + 3]


code = (function('static int ios_emulate_store_rel( ucontext_t *ctx, uint32_t insn, uintptr_t addr )') +
        function('static int ios_pc_in_app_text( uint64_t pc )') +
        function('static int ios_emulate_load_acq( ucontext_t *ctx, uint32_t insn, uintptr_t addr )') +
        function('static int ios_native_unaligned_emulate( ucontext_t *ctx, uint32_t insn, uintptr_t addr, uint64_t pc )'))

harness = r'''
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef __APPLE__
/* <stdlib.h> pulls in the system ucontext_t; the fixture's own ARM-shaped one
 * below is what the extracted code is compiled against on every host. */
#define ucontext_t darwin_ucontext_t
#endif
#include <stdlib.h>
#ifdef __APPLE__
#undef ucontext_t
#endif
typedef struct { uint64_t __x[29], __fp, __lr, __sp, __pc; } ss_t;
typedef struct { __uint128_t __v[32]; } ns_t;
typedef struct { ss_t __ss; ns_t __ns; } mctx_t;
typedef struct { mctx_t *uc_mcontext; } ucontext_t;
#define REGn_sig(reg_num, context) ((context)->uc_mcontext->__ss.__x[reg_num])
static int ios_neon_valid = 1;
static inline uint64_t ios_get_reg(ucontext_t *ctx, int r) { return r == 31 ? 0 : REGn_sig(r, ctx); }
static int ios_ld_setvec(ucontext_t *ctx, int rt, uintptr_t a, int bytes) { memcpy(&ctx->uc_mcontext->__ns.__v[rt], (void *)a, bytes); return 1; }
struct mach_header_64 { uint32_t magic; };
static struct mach_header_64 fake_header;
static const void *_dyld_get_image_header(unsigned i) { (void)i; return &fake_header; }
static uint8_t *getsegmentdata(const struct mach_header_64 *mh, const char *name, unsigned long *size)
{ (void)name; *size = 0x1000000; return (uint8_t *)mh; }
static uint64_t ios_app_text_lo, ios_app_text_hi;
''' + code + r'''
static mctx_t mc;
static ucontext_t uc = { &mc };
static unsigned char mem[64];
static int fails;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL: " __VA_ARGS__); printf("\n"); fails++; } } while (0)
static uint64_t app_pc(void) { return (uint64_t)(uintptr_t)&fake_header + 0xb5310c; }
static uint64_t fex_pc = 0x128b08590ull;

int main(void)
{
    unsigned char *odd = mem + 15;            /* ...f: a 4-byte access crosses mem+16 */

    /* 1: the crash: stlr w21, [x19] on an address crossing 16 bytes */
    memset(mem, 0xAA, sizeof mem); memset(&mc, 0, sizeof mc);
    mc.__ss.__x[21] = 0x1122334455667788ull; mc.__ss.__x[19] = (uint64_t)(uintptr_t)odd;
    CHECK(ios_native_unaligned_emulate(&uc, 0x889ffe75, (uintptr_t)odd, app_pc()), "stlr w21,[x19] not emulated");
    CHECK(!memcmp(odd, "\x88\x77\x66\x55", 4) && mem[14] == 0xAA && mem[19] == 0xAA, "stlr stored the wrong bytes");

    /* 2: a pc outside __TEXT (FEX's dispatcher of the crash) keeps FEX's path */
    memset(mem, 0xAA, sizeof mem);
    CHECK(!ios_native_unaligned_emulate(&uc, 0x889ffe75, (uintptr_t)odd, fex_pc), "a FEX pc was emulated");
    CHECK(mem[15] == 0xAA, "a refused access wrote memory");

    /* 3: acquire / exclusive loads, zero-extended */
    memcpy(mem + 13, "\x01\x02\x03\x04\x05\x06\x07\x08", 8);
    mc.__ss.__x[1] = ~0ull;
    CHECK(ios_native_unaligned_emulate(&uc, 0x88dffc41, (uintptr_t)(mem + 13), app_pc()) && mc.__ss.__x[1] == 0x04030201ull, "ldar w1");
    CHECK(ios_native_unaligned_emulate(&uc, 0xc8dffc83, (uintptr_t)(mem + 13), app_pc()) && mc.__ss.__x[3] == 0x0807060504030201ull, "ldar x3");
    CHECK(ios_native_unaligned_emulate(&uc, 0xb8bfc107, (uintptr_t)(mem + 13), app_pc()) && mc.__ss.__x[7] == 0x04030201ull, "ldapr w7");
    CHECK(ios_native_unaligned_emulate(&uc, 0x9940318b, (uintptr_t)(mem + 13), app_pc()) && mc.__ss.__x[11] == 0x04030201ull, "ldapur w11");
    CHECK(ios_native_unaligned_emulate(&uc, 0xd95fb1cd, (uintptr_t)(mem + 13), app_pc()) && mc.__ss.__x[13] == 0x0807060504030201ull, "ldapur x13");
    CHECK(ios_native_unaligned_emulate(&uc, 0x885f7e51, (uintptr_t)(mem + 13), app_pc()) && mc.__ss.__x[17] == 0x04030201ull, "ldxr w17");
    CHECK(ios_native_unaligned_emulate(&uc, 0xc85ffe93, (uintptr_t)(mem + 13), app_pc()) && mc.__ss.__x[19] == 0x0807060504030201ull, "ldaxr x19");
    CHECK(ios_native_unaligned_emulate(&uc, 0xb8bfc11f, (uintptr_t)(mem + 13), app_pc()), "ldapr wzr");

    /* 4: release / exclusive stores and LSE read-modify-write */
    memset(mem, 0, sizeof mem);
    mc.__ss.__x[15] = 0xCAFEBABEu;
    CHECK(ios_native_unaligned_emulate(&uc, 0x9900720f, (uintptr_t)odd, app_pc()) && !memcmp(odd, "\xBE\xBA\xFE\xCA", 4), "stlur w15");
    mc.__ss.__x[1] = 7; mc.__ss.__x[2] = 0x01020304u;
    CHECK(ios_native_unaligned_emulate(&uc, 0x88017c62, (uintptr_t)odd, app_pc()) && mc.__ss.__x[1] == 0 &&
          !memcmp(odd, "\x04\x03\x02\x01", 4), "stxr w1,w2 (status 0, stored)");
    mc.__ss.__x[4] = 9; mc.__ss.__x[5] = 0x1122334455667788ull;
    CHECK(ios_native_unaligned_emulate(&uc, 0xc804fcc5, (uintptr_t)odd, app_pc()) && mc.__ss.__x[4] == 0 &&
          !memcmp(odd, "\x88\x77\x66\x55\x44\x33\x22\x11", 8), "stlxr w4,x5");
    memcpy(odd, "\x05\x00\x00\x00", 4); mc.__ss.__x[7] = 3;
    CHECK(ios_native_unaligned_emulate(&uc, 0xb8e70128, (uintptr_t)odd, app_pc()) && mc.__ss.__x[8] == 5 &&
          !memcmp(odd, "\x08\x00\x00\x00", 4), "ldaddal w7,w8 (old 5, new 8)");
    mc.__ss.__x[10] = 0xdeadull;
    CHECK(ios_native_unaligned_emulate(&uc, 0xf8ea818b, (uintptr_t)odd, app_pc()) && mc.__ss.__x[11] == 0x1122334400000008ull &&
          !memcmp(odd, "\xad\xde\x00\x00\x00\x00\x00\x00", 8), "swpal x10,x11");

    /* 5: not ours */
    memset(mem, 0xAA, sizeof mem);
    CHECK(!ios_native_unaligned_emulate(&uc, 0x88e1fc62, (uintptr_t)odd, app_pc()), "casal was emulated");
    CHECK(!ios_native_unaligned_emulate(&uc, 0xacc10400, (uintptr_t)odd, app_pc()), "ldp q0,q1,[x0],#32 was emulated");
    CHECK(!ios_native_unaligned_emulate(&uc, 0xb9400041, (uintptr_t)odd, app_pc()), "plain ldr was emulated here");
    CHECK(!ios_native_unaligned_emulate(&uc, 0, (uintptr_t)odd, app_pc()), "an unread instruction was emulated");
    CHECK(mem[15] == 0xAA, "a refused access wrote memory");

    if (fails) return 1;
    printf("PASS: the Launcher's stlr and the acquire/release/exclusive/LSE family are emulated byte-exact for app pcs; FEX pcs, CAS, SIMD pairs and plain accesses are refused untouched\n");
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-native-unaligned-') as directory:
    c = Path(directory) / 'native.c'
    exe = Path(directory) / 'native'
    c.write_text(harness)
    build = subprocess.run(['cc', '-std=gnu11', '-Wall', '-Werror', '-Wno-unused-function',
                            '-fsanitize=address,undefined', '-o', str(exe), str(c)],
                           capture_output=True, text=True)
    assert build.returncode == 0, build.stdout + build.stderr
    run = subprocess.run([str(exe)], capture_output=True, text=True)
    print(run.stdout, end='')
    assert run.returncode == 0, run.stdout + run.stderr

# --- both fault paths call it, after the plain emulator, before 80000002 ---------
mach = src[src.index('        if (is_align)\n        {\n            uint32_t a_insn = 0;'):]
mach = mach[:mach.index('rec.ExceptionCode = EXCEPTION_DATATYPE_MISALIGNMENT;')]
assert mach.index('ios_emulate_unaligned_guest_access( &uc, a_insn, fault_addr )') < \
    mach.index('ios_native_unaligned_emulate( &uc, a_insn, fault_addr, (uint64_t)pc )'), \
    'the Mach path must try the native emulator after the plain one and before the 80000002 hand-off'
assert re.search(r'ios_native_unaligned_emulate\( &uc, a_insn, fault_addr, \(uint64_t\)pc \)\)\s*\{\s*'
                 r'static unsigned long ua_native;\s*PC_sig\(&uc\) \+= 4;\s*\*state = mc.__ss;', mach), \
    'the Mach path must step past the instruction and write the registers back'
bus = src[src.index('                if (ios_emulate_unaligned_guest_access(bus_ctx, a_insn, (uintptr_t)siginfo->si_addr))'):]
bus = bus[:bus.index('-- keeping 80000002 rev=ml498')]
assert 'ios_native_unaligned_emulate( bus_ctx, a_insn, (uintptr_t)siginfo->si_addr,' in bus and \
    bus.count('PC_sig(bus_ctx) += 4;') == 2, 'bus_handler must try the native emulator before keeping 80000002'
print('PASS: the Mach path and bus_handler try it after the plain emulator and before handing 80000002 to FEX')
