#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Ported from a community host check; anchors are the merged engine code's.
"""Opt-in feature level 12_1 and shader model 6.7 of the D3D12 runtime
(madeira.cfg d3d12-fl-12-1 and d3d12-sm-6-7).

madeira-d3d12/src/pe/madeira_d3d12.c, mad_fl_ceiling(): 12_0 is the highest
feature level the runtime claims unless the game's file (or madeira.cfg) sets
d3d12-fl-12-1 = 1, which raises it to 12_1. A 64-bit title that creates its
device at 12_1 stops with E_NOTIMPL (0x80004001) when that is refused, and
also requires shader model 6.7: mad_sm_ceiling() caps SHADER_MODEL at 6.6
unless d3d12-sm-6-7 = 1 raises it to 6.7. This test

  * checks statically that the key defaults to 0, that D3D12CreateDevice, its
    NULL-device probe and FEATURE_LEVELS all take the ceiling from
    mad_fl_ceiling(), that OPTIONS still reports no conservative rasterization
    or ROVs (the memset), that SHADER_MODEL takes its cap from
    mad_sm_ceiling(), and that the settings catalog (when present) lists both keys;
  * cuts mad_fl_ceiling() and D3D12CreateDevice out of the source, compiles
    them on the host with stubs and checks the probe's answers with the key
    off and on.

The runtime part is skipped when no host C compiler is found (cc, gcc or
clang); the static checks still run.
"""
import pathlib, shutil, subprocess, sys, tempfile

R = pathlib.Path(__file__).resolve().parents[2]
SRC = (R / "madeira-d3d12/src/pe/madeira_d3d12.c").read_text()
CATALOG = R / "app/Madeira/ConfigCatalog.generated.swift"
CAT = CATALOG.read_text() if CATALOG.exists() else None
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok = ok and bool(cond)


def body(start):
    i = SRC.index(start)
    return SRC[i:SRC.index("\n}\n", i) + 3]


fl = body("static D3D_FEATURE_LEVEL mad_fl_ceiling(void) {")
check("the key defaults to 0 and is read once",
      'v = mad_cfg_int_pe("d3d12-fl-12-1", 0) ? 1 : 0;' in fl and "static int v = -1;" in fl)
check("12_1 with the key, 12_0 without",
      "return v ? D3D_FEATURE_LEVEL_12_1 : D3D_FEATURE_LEVEL_12_0;" in fl)
check("the key is logged when on", '[d3d12-caps] fl-12-1=1 (d3d12-fl-12-1)' in fl)
create = body("__declspec(dllexport) HRESULT WINAPI MadeiraD3D12CreateDevice(")
check("CreateDevice refuses only above the ceiling",
      "if (min_feature_level > mad_fl_ceiling()) {" in create and "return E_NOTIMPL;" in create)
probe = body("HRESULT WINAPI D3D12CreateDevice(IUnknown *adapter, D3D_FEATURE_LEVEL min_level,")
check("the NULL-device probe answers from the ceiling",
      "return (min_level <= mad_fl_ceiling()) ? S_FALSE : E_INVALIDARG;" in probe)
levels = SRC[SRC.index("    case D3D12_FEATURE_FEATURE_LEVELS: {"):]
levels = levels[:levels.index("        return S_OK;")]
check("FEATURE_LEVELS reports the highest listed level up to the ceiling",
      "D3D_FEATURE_LEVEL top = mad_fl_ceiling();" in levels and
      "if (lv <= top && lv > f->MaxSupportedFeatureLevel) f->MaxSupportedFeatureLevel = lv;" in levels and
      "if (!f->MaxSupportedFeatureLevel) f->MaxSupportedFeatureLevel = top;" in levels)
check("no other place caps the level at 12_0 by itself",
      SRC.count("<= D3D_FEATURE_LEVEL_12_0") == 0 and SRC.count("> D3D_FEATURE_LEVEL_12_0") == 0)
options = SRC[SRC.index("    case D3D12_FEATURE_D3D12_OPTIONS: {"):]
options = options[:options.index("        return S_OK;")]
check("OPTIONS still reports no conservative rasterization or ROVs",
      "memset(o, 0, sizeof *o);" in options and "ROVsSupported" not in options and
      "ConservativeRasterizationTier" not in options)
if CAT is not None:
    check("the settings catalog lists d3d12-fl-12-1, default 0",
          any(l.lstrip().startswith('ConfigOption(key: "d3d12-fl-12-1", ') and 'defaultValue: "0", category: "Direct3D 12"' in l for l in CAT.splitlines()))

sm = body("static D3D_SHADER_MODEL mad_sm_ceiling(void) {")
check("d3d12-sm-6-7 defaults to 0 and is read once",
      'v = mad_cfg_int_pe("d3d12-sm-6-7", 0) ? 1 : 0;' in sm and "static int v = -1;" in sm)
check("6.7 (0x67) with the key, 6.6 without",
      "return v ? (D3D_SHADER_MODEL)0x67 : D3D_SHADER_MODEL_6_6;" in sm)
check("the key is logged when on", "[d3d12-caps] sm-6-7=1 (d3d12-sm-6-7)" in sm)
shader = SRC[SRC.index("    case D3D12_FEATURE_SHADER_MODEL: {"):]
shader = shader[:shader.index("        return S_OK;")]
check("SHADER_MODEL caps the caller's model at the ceiling",
      "if (m->HighestShaderModel > mad_sm_ceiling()) m->HighestShaderModel = mad_sm_ceiling();" in shader and
      SRC.count("> D3D_SHADER_MODEL_6_6") == 0)
if CAT is not None:
    check("the settings catalog lists d3d12-sm-6-7, default 0",
          any(l.lstrip().startswith('ConfigOption(key: "d3d12-sm-6-7", ') and 'defaultValue: "0", category: "Direct3D 12"' in l for l in CAT.splitlines()))

cc = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
if not cc:
    print("SKIP host compile (no C compiler)")
else:
    harness = r'''
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
typedef long HRESULT; typedef void IUnknown; typedef const void *REFIID;
#define WINAPI
#define S_FALSE 1
#define E_INVALIDARG ((HRESULT)0x80070057)
#define E_NOTIMPL ((HRESULT)0x80004001)
typedef enum { D3D_FEATURE_LEVEL_11_0 = 0xb000, D3D_FEATURE_LEVEL_12_0 = 0xc000,
               D3D_FEATURE_LEVEL_12_1 = 0xc100, D3D_FEATURE_LEVEL_12_2 = 0xc200 } D3D_FEATURE_LEVEL;
typedef enum { D3D_SHADER_MODEL_6_0 = 0x60, D3D_SHADER_MODEL_6_6 = 0x66 } D3D_SHADER_MODEL;
static long long cfg_on;
static long long mad_cfg_int_pe(const char *key, long long dflt) {
    return (strcmp(key, "d3d12-fl-12-1") && strcmp(key, "d3d12-sm-6-7")) ? dflt : cfg_on;
}
static void d3d12_log(const char *fmt, ...) { (void)fmt; }
static void mad_pin_graphics_dlls(void) {}
static void mad_preload_dlls(void) {}
static HRESULT MadeiraD3D12CreateDevice(IUnknown *a, D3D_FEATURE_LEVEL l, REFIID r, void **d) {
    (void)a; (void)l; (void)r; (void)d; return 0;
}
''' + fl + "\n" + sm + "\n" + probe + r'''
int main(int argc, char **argv) {
    (void)argv;
    cfg_on = argc > 1;
    printf("%x %ld %ld %ld %ld %x\n", (unsigned)mad_fl_ceiling(),
           D3D12CreateDevice(0, D3D_FEATURE_LEVEL_11_0, 0, 0), D3D12CreateDevice(0, D3D_FEATURE_LEVEL_12_0, 0, 0),
           D3D12CreateDevice(0, D3D_FEATURE_LEVEL_12_1, 0, 0), D3D12CreateDevice(0, D3D_FEATURE_LEVEL_12_2, 0, 0),
           (unsigned)mad_sm_ceiling());
    return 0;
}
'''
    with tempfile.TemporaryDirectory() as td:
        c = pathlib.Path(td) / "fl.c"
        exe = pathlib.Path(td) / "fl"
        c.write_text(harness)
        built = subprocess.run([cc, "-std=c11", "-Wall", "-Werror", "-Wno-unused-function", "-o", str(exe), str(c)],
                               capture_output=True, text=True)
        check("the ceiling and the probe compile on the host", built.returncode == 0)
        if built.returncode != 0:
            print(built.stderr)
        else:
            off = subprocess.run([str(exe)], capture_output=True, text=True).stdout.split()
            on = subprocess.run([str(exe), "on"], capture_output=True, text=True).stdout.split()
            inval = str(0x80070057)
            check("keys off: ceiling 12_0; the probe accepts 11_0 and 12_0, refuses 12_1 and 12_2; shader model 6.6",
                  off == ["c000", "1", "1", inval, inval, "66"])
            check("keys on: ceiling 12_1; the probe accepts up to 12_1, still refuses 12_2; shader model 6.7",
                  on == ["c100", "1", "1", "1", inval, "67"])

print("PASS: d3d12-fl-12-1, d3d12-sm-6-7" if ok else "FAIL: d3d12-fl-12-1, d3d12-sm-6-7")
sys.exit(0 if ok else 1)
