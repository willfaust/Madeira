#!/usr/bin/env python3
"""Refused DXIL shaders: msc-unbounded-retry, msc-fail-memo, pso-placeholder; no Metal.

Horizon Zero Dawn's build 475 run (2026-10-09 16:20) lost ~4,900 DXIL vertex
and pixel shaders to the converter's code 4 although rsig-miss found every
binding in the root signature; every refused shader reads t4-t7 of a table
range "SRV t4-unbounded" (NumDescriptors 0xffffffff, base 4). Each refused
shader was converted again for every pipeline that used it (~30,000
conversions), and the game stopped with an "Error" box when its settings menu
got a refused pipeline. Three opt-in switches in madeira_d3d12.c:

1. msc-unbounded-retry: the helpers are cut out and compiled on the host
   against the real madeira_ir_abi.h:
   - the sized copy gives an unbounded sampler range 2048 descriptors and any
     other unbounded range 1,000,000, keeps every other field and range, and
     is NULL for a root signature without unbounded ranges;
   - a retry is wanted only with the switch on: from the original ranges only
     for code 4 from the DXIL backend while the root signature has not given
     up, from the sized ones always (back to the original);
   - a success with sized ranges makes them the root signature's first choice;
     four sized refusals without one make it give up; nothing changes while
     the switch is off.
   And in mad_convert_stage_opts: the sized ranges replace a.ranges after
   both mad_fill_convert_inputs calls (so the size retry converts the same
   input), the retry restarts at `again:` once, and every return between the
   copy and the end of the conversion frees it.
2. msc-fail-memo: the memo is compiled and run: a refusal stored under its key
   comes back as the same status, code and backend with the memo note, other
   keys miss, the all-zero key is never stored, and the table stops growing at
   three quarters. In mad_ir_convert_cached_impl the lookup follows the cache
   load and only MADEIRA_IR_COMPILE_FAILED is stored; the caller returns a
   remembered refusal without logging it again.
3. pso-placeholder: a graphics pipeline whose vertex or pixel stage did not
   convert is returned through pso_QI (draws without a Metal pipeline are
   skipped) instead of E_FAIL, only with the switch on.
Plus: all three are in the settings catalog, off by default.
"""
from pathlib import Path
import shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
pe = (root / "madeira-d3d12/src/pe/madeira_d3d12.c").read_text()
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


def body(sig):
    start = pe.index(sig)
    while pe.index(";", start) < pe.index("{", start):   # a prototype: the definition comes later
        start = pe.index(sig, start + 1)
    brace = pe.index("{", start)
    depth = 0
    for i in range(brace, len(pe)):
        if pe[i] == "{":
            depth += 1
        elif pe[i] == "}":
            depth -= 1
            if depth == 0:
                return pe[start:i + 1]
    raise AssertionError("unterminated: " + sig)


unb = pe[pe.index("#define MAD_UNB_FAILS_MAX 4"):pe.index("/* madeira-bcd pso-placeholder: see device_CreateGraphicsPipelineState. */")]
memo = pe[pe.index("#define MAD_FAILMEMO_N 16384u"):pe.index("static void mad_ir_convert_cached_impl(struct madeira_ir_convert_args *a);\n")]

harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include "madeira_ir_abi.h"
typedef uint64_t UINT64; typedef uint32_t UINT32; typedef unsigned UINT; typedef long LONG; typedef size_t SIZE_T;
typedef struct { int x; } SRWLOCK;
#define SRWLOCK_INIT { 0 }
static void AcquireSRWLockShared(SRWLOCK *l) { (void)l; }
static void ReleaseSRWLockShared(SRWLOCK *l) { (void)l; }
static void AcquireSRWLockExclusive(SRWLOCK *l) { (void)l; }
static void ReleaseSRWLockExclusive(SRWLOCK *l) { (void)l; }
static LONG InterlockedIncrement(volatile LONG *p) { return ++*p; }
static LONG InterlockedCompareExchange(volatile LONG *p, LONG v, LONG cmp) { LONG o = *p; if (o == cmp) *p = v; return o; }
static int logs;
static void d3d12_log(const char *fmt, ...) { (void)fmt; logs++; }
static long long cfg_unb, cfg_memo;
static long long mad_cfg_int_pe(const char *k, long long d) {
    if (!strcmp(k, "msc-unbounded-retry")) return cfg_unb;
    if (!strcmp(k, "msc-fail-memo")) return cfg_memo;
    return d;
}
struct mad_rootsig { struct madeira_ir_root_range *ranges; UINT nranges; volatile LONG unb_state, unb_fails; };
''' + unb + memo + r'''
static int bad;
#define EXPECT(c, what) do { if (!(c)) { printf("FAIL %s\n", what); bad = 1; } } while (0)
static struct madeira_ir_root_range rg(UINT32 type, UINT32 n, UINT32 base, UINT32 space, UINT32 off) {
    struct madeira_ir_root_range r; memset(&r, 0, sizeof r);
    r.range_type = type; r.num_descriptors = n; r.base_register = base; r.register_space = space; r.table_offset = off;
    return r;
}
int main(void) {
    /* HZD's shape: table{sampler s0-unbounded space 0}; table{CBV b0 space 7, SRV t0-t3 space 7, SRV t4-unbounded space 7} */
    struct madeira_ir_root_range r[4] = {
        rg(MADEIRA_IR_RANGE_SAMPLER, 0xffffffffu, 0, 0, 0),
        rg(MADEIRA_IR_RANGE_CBV, 1, 0, 7, 0),
        rg(MADEIRA_IR_RANGE_SRV, 4, 0, 7, 0xffffffffu),
        rg(MADEIRA_IR_RANGE_SRV, 0xffffffffu, 4, 7, 0xffffffffu) };
    struct madeira_ir_root_range plain[2] = { rg(MADEIRA_IR_RANGE_CBV, 1, 0, 1, 0), rg(MADEIRA_IR_RANGE_SRV, 8, 0, 2, 1) };
    struct mad_rootsig rs = { r, 4, 0, 0 }, rs_plain = { plain, 2, 0, 0 };
    struct madeira_ir_root_range *c;
    struct madeira_ir_convert_args a;
    UINT64 k1[2] = { 0x1111, 0x2222 }, k2[2] = { 0x3333, 0x4444 }, k0[2] = { 0, 0 };
    unsigned i, stored;

    /* the sized copy */
    c = mad_unb_sized_copy(&rs);
    EXPECT(c != NULL, "a copy for a root signature with unbounded ranges");
    if (c) {
        EXPECT(c[0].num_descriptors == 2048u, "unbounded sampler range -> 2048");
        EXPECT(c[3].num_descriptors == 1000000u, "unbounded SRV range -> 1000000");
        EXPECT(c[3].base_register == 4 && c[3].register_space == 7 && c[3].table_offset == 0xffffffffu &&
               c[3].range_type == MADEIRA_IR_RANGE_SRV, "the other fields stay");
        EXPECT(!memcmp(&c[1], &r[1], sizeof r[1]) && !memcmp(&c[2], &r[2], sizeof r[2]), "bounded ranges unchanged");
        EXPECT(r[0].num_descriptors == 0xffffffffu && r[3].num_descriptors == 0xffffffffu, "the runtime's own ranges untouched");
        free(c);
    }
    EXPECT(mad_unb_sized_copy(&rs_plain) == NULL, "no copy without unbounded ranges");
    EXPECT(mad_unb_sized_copy(NULL) == NULL, "no copy without a root signature");

    /* switch off: never */
    memset(&a, 0, sizeof a);
    a.ret_backend = MADEIRA_IR_BACKEND_MSC; a.ret_status = MADEIRA_IR_COMPILE_FAILED; a.ret_error_code = 4;
    cfg_unb = 0;
    EXPECT(!mad_unb_retry_wanted(&rs, &a, 0) && !mad_unb_retry_wanted(&rs, &a, 1) && !mad_unb_sized_first(&rs),
           "switch off: no retry, original ranges first");

    /* switch on (read once, so a fresh process would be needed; reset the cache) */
    g_unb_retry = -1; cfg_unb = 1;
    EXPECT(mad_unb_retry_wanted(&rs, &a, 0), "code 4 from the DXIL backend: retry with sized ranges");
    a.ret_error_code = 8;
    EXPECT(!mad_unb_retry_wanted(&rs, &a, 0), "another converter code: no retry");
    a.ret_error_code = 4; a.ret_backend = MADEIRA_IR_BACKEND_AIRCONV;
    EXPECT(!mad_unb_retry_wanted(&rs, &a, 0), "the DXBC backend: no retry");
    a.ret_backend = MADEIRA_IR_BACKEND_MSC; a.ret_status = MADEIRA_IR_NO_MEMORY;
    EXPECT(!mad_unb_retry_wanted(&rs, &a, 0), "not a compile failure: no retry");
    EXPECT(mad_unb_retry_wanted(&rs, &a, 1), "sized ranges refused: back to the original");
    a.ret_status = MADEIRA_IR_COMPILE_FAILED;
    EXPECT(!mad_unb_retry_wanted(NULL, &a, 0), "no root signature: no retry");

    /* outcomes */
    EXPECT(!mad_unb_sized_first(&rs), "unknown root signature: original ranges first");
    mad_unb_note(&rs, "PS", 1, 1);
    EXPECT(rs.unb_state == 1 && mad_unb_sized_first(&rs), "a sized success makes sized ranges the first choice");
    for (i = 0; i < 6; i++) mad_unb_note(&rs, "PS", 1, 0);
    EXPECT(rs.unb_state == 1, "later sized refusals do not undo a success");
    struct mad_rootsig rs2 = { r, 4, 0, 0 };
    for (i = 0; i < 3; i++) mad_unb_note(&rs2, "VS", 1, 0);
    EXPECT(rs2.unb_state == 0 && mad_unb_retry_wanted(&rs2, &a, 0), "three sized refusals: still retried");
    mad_unb_note(&rs2, "VS", 1, 0);
    EXPECT(rs2.unb_state == 2 && !mad_unb_retry_wanted(&rs2, &a, 0), "the fourth: the root signature gives up");
    mad_unb_note(&rs2, "VS", 0, 1);
    EXPECT(rs2.unb_state == 2, "an original-range success after a sized refusal changes nothing");

    /* the memo */
    g_failmemo_on = -1; cfg_memo = 0;
    EXPECT(!mad_failmemo_on(), "memo off by default");
    g_failmemo_on = -1; cfg_memo = 1;
    EXPECT(mad_failmemo_on(), "memo on with msc-fail-memo = 1");
    memset(&a, 0, sizeof a);
    EXPECT(!mad_failmemo_find(k1, &a) && a.ret_status == 0 && !a.ret_note[0], "an unknown key misses and leaves the args alone");
    a.ret_status = MADEIRA_IR_COMPILE_FAILED; a.ret_error_code = 4; a.ret_backend = MADEIRA_IR_BACKEND_MSC;
    mad_failmemo_add(k1, &a);
    mad_failmemo_add(k1, &a);
    EXPECT(g_failmemo_n == 1, "a key is stored once");
    memset(&a, 0, sizeof a); a.ret_len = 77;
    EXPECT(mad_failmemo_find(k1, &a), "the stored key hits");
    EXPECT(a.ret_status == MADEIRA_IR_COMPILE_FAILED && a.ret_error_code == 4 && a.ret_backend == MADEIRA_IR_BACKEND_MSC &&
           a.ret_len == 0 && !strcmp(a.ret_note, g_failmemo_note), "it comes back as the same refusal with the memo note");
    memset(&a, 0, sizeof a);
    EXPECT(!mad_failmemo_find(k2, &a), "another key misses");
    a.ret_status = MADEIRA_IR_COMPILE_FAILED;
    mad_failmemo_add(k0, &a);
    EXPECT(g_failmemo_n == 1, "the all-zero key is never stored");
    for (i = 0; i < MAD_FAILMEMO_N; i++) { UINT64 k[2] = { 0x9000 + i, 0x51 * (i + 1) }; mad_failmemo_add(k, &a); }
    stored = g_failmemo_n;
    EXPECT(stored == MAD_FAILMEMO_N / 4 * 3, "the table stops growing at three quarters");
    { UINT64 k[2] = { 0x9000 + 5, 0x51 * 6 }; memset(&a, 0, sizeof a); EXPECT(mad_failmemo_find(k, &a), "a key stored before the limit still hits"); }
    { UINT64 k[2] = { 0x9000 + MAD_FAILMEMO_N - 1, 0x51 * MAD_FAILMEMO_N }; memset(&a, 0, sizeof a); EXPECT(!mad_failmemo_find(k, &a), "a key past the limit misses (converted as before)"); }

    printf("%s\n", bad ? "harness FAILED" : "harness ok");
    return bad;
}
'''

cc = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
if not cc:
    check("a host C compiler", False)
else:
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "t.c"
        exe = Path(tmp) / "t"
        src.write_text(harness)
        inc = "-I" + str(root / "madeira-d3d12/src")
        p = subprocess.run([cc, "-std=c11", "-Wall", "-Wno-unused-function", "-fsanitize=address,undefined",
                            inc, "-o", str(exe), str(src)], capture_output=True, text=True)
        if p.returncode != 0:
            p = subprocess.run([cc, "-std=c11", "-Wall", "-Wno-unused-function", inc, "-o", str(exe), str(src)],
                               capture_output=True, text=True)
        check("helpers compile on the host" + ("" if p.returncode == 0 else ":\n" + p.stderr[-2500:]), p.returncode == 0)
        if p.returncode == 0:
            r = subprocess.run([str(exe)], capture_output=True, text=True)
            print(r.stdout.strip())
            check("sized copy, retry decisions, outcomes and the memo behave as described", r.returncode == 0)

# --- msc-unbounded-retry in mad_convert_stage_opts
conv = body("static obj_handle_t mad_convert_stage_opts(")
again = conv.index("\nagain:\n")
fills = [i for i in range(len(conv)) if conv.startswith("mad_fill_convert_inputs(&a, rs, dxil, dxil_len, entry, o);", i)]
check("two fills, the first right after `again:`", len(fills) == 2 and fills[0] > again and fills[0] - again < 20)
check("both fills are followed by the sized ranges when in use",
      all(conv[f:f + 220].count("if (sized) a.ranges = (uint64_t)(uintptr_t)sized_ranges;") == 1 for f in fills))
check("sized ranges first only when the root signature already needed them",
      "if (mad_unb_sized_first(rs) && (sized_ranges = mad_unb_sized_copy(rs))) sized = 1;" in conv
      and conv.index("mad_unb_sized_first(rs)") < again)
retry = conv[conv.index("/* madeira-bcd msc-unbounded-retry: once more with the other set of ranges */"):]
retry = retry[:retry.index("goto again;")]
check("the retry happens once (switched) and flips the ranges",
      "if (!switched && mad_unb_retry_wanted(rs, &a, sized)) {" in retry and "switched = 1;" in retry and "sized = !sized;" in retry)
check("the retry clears the reflection outputs the converter fills",
      "if (o && o->air) memset(o->air, 0, sizeof *o->air);" in retry and "name[0] = 0;" in retry)
done = conv.index("free(sized_ranges);   /* the conversion is done; nothing below reads a.ranges */")
section = conv[conv.index("mad_unb_sized_copy(rs))) sized = 1;"):done]
returns = [i for i in range(len(section)) if section.startswith("return 0;", i)]
fail_at = section.index("if (a.ret_status != MADEIRA_IR_BUFFER_TOO_SMALL && a.ret_status != MADEIRA_IR_OK) {")
fail_end = section.index("\n    }\n", fail_at)
fail_free = section.index("free(sized_ranges);\n        if (memo)", fail_at)


def freed_before(i):
    if "free(sized_ranges)" in section[max(0, i - 160):i]:
        return True
    # the refusal branch frees once, after its last `goto again`, before its log and returns
    return fail_at < i < fail_end and section.rindex("goto again;", fail_at, i) < fail_free < i


check("every return after the copy frees it first (%d returns)" % len(returns),
      len(returns) >= 5 and all(freed_before(i) for i in returns))
check("the outcome is noted (success after a switch; refusal unless remembered)",
      "if (switched) mad_unb_note(rs, tag, sized, 1);" in conv and "if (switched && !memo) mad_unb_note(rs, tag, sized, 0);" in conv)

# --- msc-fail-memo in the cache path and the caller
impl = body("static void mad_ir_convert_cached_impl(struct madeira_ir_convert_args *a) {")
check("the memo is looked up after the cache load, before any conversion",
      impl.index("mad_sc_load(a, key, &fresh)") < impl.index("if (mad_failmemo_on() && mad_failmemo_find(key, a)) return;")
      < impl.rindex("MadeiraIRConvert(a);"))
check("only a compile failure is remembered",
      "} else if (a->ret_status == MADEIRA_IR_COMPILE_FAILED && mad_failmemo_on()) {\n        mad_failmemo_add(key, a);" in impl)
check("the caller recognises a remembered refusal and does not log it again",
      "const int memo = !strcmp(a.ret_note, g_failmemo_note);" in conv
      and conv.index("if (memo) { free(buf); free(buf2); return 0; }") <
      conv.index('d3d12_log("[madeira-d3d12] %s conversion failed: %s (%s backend, code %u); %llu bytes, head "'))

# --- pso-placeholder
gp = pe[pe.index("    if (!p->vs_fn || (desc->PS.pShaderBytecode && !p->ps_fn)) {"):]
gp = gp[:gp.index("pso_Release((ID3D12PipelineState *)p); return E_FAIL;\n    }") + 60]
check("a refused stage gives a placeholder through pso_QI only with the switch on",
      "if (mad_pso_placeholder_on()) {" in gp and "hr = pso_QI((ID3D12PipelineState *)p, riid, out);" in gp
      and gp.index("if (mad_pso_placeholder_on()) {") < gp.index("return E_FAIL;"))
draw = body("static void exec_draw(struct mad_exec *e, const struct mad_cmd *c) {")
check("draws with a pipeline that has no Metal pipeline are skipped",
      "if (!e->pso || (!e->pso->rps && !e->pso->tess)) {" in draw)
check("the switches are read with their defaults off",
      'mad_cfg_int_pe("msc-unbounded-retry", 0)' in pe and 'mad_cfg_int_pe("msc-fail-memo", 0)' in pe
      and 'mad_cfg_int_pe("pso-placeholder", 0)' in pe)

cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
for key in ("msc-unbounded-retry", "msc-fail-memo", "pso-placeholder"):
    check("catalog lists %s, off by default" % key,
          ('key: "%s", ' % key) in cat and 'kind: .bool, defaultValue: "0"' in cat.split('key: "%s", ' % key)[1].split("\n")[0])
# The CI step exists only in the fork's workflow; upstream has no .github.
if (root / ".github/workflows/build-ipa.yml").exists():
    wf = (root / ".github/workflows/build-ipa.yml").read_text()
    check("the workflow runs this check", "python3 tests/host/check-msc-unbounded-retry.py" in wf)

print("PASS" if ok else "FAILED")
sys.exit(0 if ok else 1)
