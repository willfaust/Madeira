#!/usr/bin/env python3
"""DXBC register spaces other than 0 (madeira.cfg dxbc-register-spaces = 1); no Metal.

The converter service refused every shader model 5.1 declaration outside
register space 0. Horizon Zero Dawn keeps its constant buffers, samplers and
textures in spaces 6 and 8, so most of its pipelines failed (build 466). The
runtime already resolves each range by (type, space, register), so the
switch only lifts the refusal. This test cuts mad_air_ranges and the switch
out of madeira_ir_unix.mm, compiles them on the host against the real
airconv_public.h and madeira_ir_abi.h with a stand-in SM50GetRangeInfo and
config reader, and checks:
  - off (the default): a declaration in space 6 is refused with the note that
    names the switch; space 0 passes and its records are copied;
  - on: spaces 6 and 8 pass, each record keeps its space and register; a
    range of 4 and a record with no declaration (space and size ~0) are still
    refused;
  - the cache-key tag is added only with the switch on;
and in the source: the plain path's refusal has the same condition and comes
after the singleton check; the tessellation, geometry and plain cache keys
take the tag before they are used; the D3D12 runtime's shader cache identity
gets ", dxbc-spaces 1" only with the switch on; mad_air_resolve matches the
space in descriptor tables, root constants, root descriptors and static
samplers; airconv names its tables by range id and reports each range's
space; the catalog lists the switch, off by default; Horizon Zero Dawn's
recommended list turns it on.
"""
from pathlib import Path
import re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
unix = (root / "madeira-d3d12/src/unix/madeira_ir_unix.mm").read_text()
pe = (root / "madeira-d3d12/src/pe/madeira_d3d12.c").read_text()
airconv = (root / "dxmt/src/airconv/dxbc_converter.cpp").read_text()
catalog = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
recs = (root / "app/Madeira/GameRecommendations.swift").read_text()
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


def cut(src, start, end_marker="\n}\n"):
    i = src.index(start)
    return src[i:src.index(end_marker, i) + len(end_marker)]


hash_add = cut(unix, "static void mad_sc_hash_add(uint64_t *h, const void *p, size_t n)")
switch = unix[unix.index("static int mad_dxbc_spaces(void)"):]
switch = switch[:switch.index("\n}\n", switch.index("static void mad_sc_hash_spaces(")) + 3]
ranges = cut(unix, "static int mad_air_ranges(sm50_shader_t shader,")
check("switch read once with madeira_cfg_bool, off by default",
      'cached = madeira_cfg_bool("dxbc-register-spaces", 0) ? 1 : 0;' in switch and "if (cached < 0)" in switch)
check("mad_air_ranges: singletons first, then the space unless the switch is on",
      ranges.index("if (ranges[i].RangeSize != 1)") < ranges.index("if (ranges[i].RegisterSpace != 0 && !mad_dxbc_spaces())"))

plain = unix[unix.index("static int mad_airconv_convert(struct madeira_ir_convert_args *a,"):]
plain = plain[:plain.index("\ndone:\n")]
check("plain path: the same refusal, after the singleton check",
      plain.index("if (ranges[i].RangeSize != 1)") < plain.index("if (ranges[i].RegisterSpace != 0 && !mad_dxbc_spaces())")
      and plain.count("dxbc-register-spaces = 1 maps the others") == 1)
check("plain path: the key takes the tag before the lookup",
      plain.index("mad_sc_hash_spaces(&key);") < plain.index("sc_key = key;") < plain.index("int hit = mad_sc_load(key, a, out_ranges);"))
for kind in ("tess", "geom"):
    body = unix[unix.index('mad_sc_hash_add(&key, "%s", 4);' % kind):]
    body = body[:body.index("int hit = mad_sc_load(key, a, out_ranges);")]
    check(f"{kind} path: the key takes the tag before the lookup (it looks up before the range check)",
          body.index("mad_sc_hash_spaces(&key);") < body.index("sc_key = key;"))

ident = pe[pe.index("static int mad_sc_init(void) {"):]
ident = ident[:ident.index("n = GetEnvironmentVariableW(L\"LOCALAPPDATA\"")]
check("runtime cache identity: \", dxbc-spaces 1\" only with the switch on, before the identity is hashed",
      'if (mad_cfg_int_pe("dxbc-register-spaces", 0)) {' in ident
      and 'snprintf(g_sc_rt + l, sizeof g_sc_rt - l, ", dxbc-spaces 1");' in ident
      and ident.index('", dxbc-spaces 1"') < ident.index("mad_sc_feed(&hr, g_sc_rt, strlen(g_sc_rt) < 96 ? 96 : sizeof g_sc_rt);"))
resolve = pe[pe.index("static int mad_air_resolve(struct mad_exec *e,", pe.index("/* Resolve one declaration range against the root signature.")):]
resolve = resolve[:resolve.index("\n}\n") + 3]
check("mad_air_resolve matches the space: tables, root constants, root descriptors, static samplers",
      "if (rr->register_space != rg->space) continue;" in resolve
      and resolve.count("pp->register_space != rg->space") == 2
      and "rs->samplers[i].register_space == rg->space" in resolve)
check("the log names the refusal instead of 'unknown'",
      'case MADEIRA_IR_UNSUPPORTED_RANGE: return "a resource declaration this build does not map";' in pe)
check("airconv names its tables by range id and reports each range's space",
      'binding_table_cbuffer.DefineBuffer(\n      "cb" + std::to_string(range_id)' in airconv
      and 'o.RegisterSpace = r ? r->space : ~0u;' in airconv)
check("catalog lists dxbc-register-spaces, off by default",
      re.search(r'key: "dxbc-register-spaces".*kind: \.bool, defaultValue: "0"', catalog) is not None)
hzd = recs[recs.index("static let horizonZeroDawn = GameRecommendation("):]
check("Horizon Zero Dawn's list turns it on", "dxbc-register-spaces = 1" in hzd[:hzd.index('""",')])

harness = r'''
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include "airconv_public.h"
#include "madeira_ir_abi.h"

static int g_cfg;
static int madeira_cfg_bool(const char *key, int dflt) { return strcmp(key, "dxbc-register-spaces") ? dflt : g_cfg; }
static MTL_SM50_RANGE_INFO g_in[8];
static uint32_t g_n;
extern "C" uint32_t SM50GetRangeInfo(sm50_shader_t, struct MTL_SM50_RANGE_INFO *out, uint32_t cap) {
    for (uint32_t i = 0; i < g_n && i < cap; i++) out[i] = g_in[i];
    return g_n;
}
''' + hash_add + switch + ranges + r'''
static MTL_SM50_RANGE_INFO R(uint32_t type, uint32_t id, uint32_t space, uint32_t lb, uint32_t size) {
    MTL_SM50_RANGE_INFO r; memset(&r, 0, sizeof r);
    r.Type = (SM50BindingType)type; r.RangeID = id; r.RegisterSpace = space; r.LowerBound = lb; r.RangeSize = size;
    r.StructurePtrOffset = 3 * id; r.Flags = 1; return r;
}
static int run(const char *what, uint32_t n, struct madeira_ir_air_range *out, char *note) {
    uint32_t got = 0;
    sm50_shader_t sh = {};
    g_n = n; note[0] = 0;
    int st = mad_air_ranges(sh, out, 8, &got, note, 128);
    printf("%s: status %d, %u ranges, note '%s'\n", what, st, got, note);
    return st;
}
int main(int argc, char **argv) {
    struct madeira_ir_air_range out[8]; char note[128];
    g_cfg = atoi(argv[1]);
    int bad = 0;
    g_in[0] = R(0, 0, 6, 0, 1);
    int st = run("b0 space 6", 1, out, note);
    if (g_cfg) bad |= st != MADEIRA_IR_OK || out[0].space != 6 || out[0].lower_bound != 0 || out[0].range_id != 0;
    else bad |= st != MADEIRA_IR_UNSUPPORTED_RANGE ||
                !strstr(note, "b0 is in register space 6 (only space 0 is mapped; dxbc-register-spaces = 1 maps the others)");
    g_in[0] = R(0, 0, 0, 17, 1); g_in[1] = R(2, 1, 0, 104, 1);
    st = run("b17, t104 space 0", 2, out, note);
    bad |= st != MADEIRA_IR_OK || out[0].lower_bound != 17 || out[1].lower_bound != 104 || out[1].space != 0 || out[1].type != 2;
    g_in[0] = R(0, 0, 6, 0, 1); g_in[1] = R(1, 0, 8, 0, 1); g_in[2] = R(2, 0, 8, 16, 1);
    st = run("b0 space 6, s0 space 8, t16 space 8", 3, out, note);
    if (g_cfg) bad |= st != MADEIRA_IR_OK || out[1].space != 8 || out[1].type != 1 || out[2].space != 8 ||
                      out[2].lower_bound != 16 || out[2].ptr_offset != 0;
    else bad |= st != MADEIRA_IR_UNSUPPORTED_RANGE;
    g_in[0] = R(2, 0, 8, 0, 4);
    st = run("t0 space 8, a range of 4", 1, out, note);
    bad |= st != MADEIRA_IR_UNSUPPORTED_RANGE || !strstr(note, "is a range of 4");
    g_in[0] = R(2, 0, ~0u, ~0u, ~0u);
    st = run("a record with no declaration", 1, out, note);
    bad |= st != MADEIRA_IR_UNSUPPORTED_RANGE;
    uint64_t key = 1469598103934665603ull, before = key;
    mad_sc_hash_spaces(&key);
    printf("key %s\n", key == before ? "unchanged" : "tagged");
    bad |= g_cfg ? key == before : key != before;
    printf("%s\n", bad ? "HARNESS FAILED" : "harness ok");
    return bad;
}
'''

cxx = shutil.which("clang++") or shutil.which("g++")
if not cxx:
    print("SKIP: no C++ compiler for the harness")
else:
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "spaces.cpp"
        src.write_text(harness)
        exe = Path(tmp) / "spaces"
        build = subprocess.run([cxx, "-std=c++17", "-w", "-I", str(root / "dxmt/src/airconv"),
                                "-I", str(root / "madeira-d3d12/src"), str(src), "-o", str(exe)],
                               capture_output=True, text=True)
        check("harness compiles", build.returncode == 0)
        if build.returncode:
            print(build.stderr[-3000:])
        else:
            for value, label in (("0", "off"), ("1", "on")):
                res = subprocess.run([str(exe), value], capture_output=True, text=True)
                print(res.stdout.rstrip())
                check(f"switch {label}: refusals, records and the cache-key tag as expected", res.returncode == 0)

print("PASS" if ok else "FAILED")
sys.exit(0 if ok else 1)
