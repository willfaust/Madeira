#!/usr/bin/env python3
"""Opt-in tiled resources of the D3D12 runtime; no device.

madeira-d3d12/src/pe/madeira_d3d12.c, block "TILED RESOURCES": with
madeira.cfg d3d12-tiled-resources = 1 the device reports
TiledResourcesTier 2, 40 address bits per resource and R32G32B32 vertex
formats, creates reserved resources fully backed and answers
GetResourceTiling with D3D12's standard tiling. This test

  * checks statically that the key defaults to 0, that every new method falls
    back to its generated stub when the key is off (the default is unchanged),
    that the OPTIONS / FORMAT_SUPPORT answers are behind the key, and that the
    methods are in the vtables;
  * cuts the tiling code (between "tiled-test:begin" and "tiled-test:end") out
    of the source, compiles it on the host and checks it against D3D12's
    tables: the standard 2D / 3D / block-compressed / MSAA tile shapes, Tier 2
    mip packing, per-slice packed mips, tile numbering of array slices,
    buffers, and the formats / dimensions that have no tiling.

The runtime part is skipped when no host C compiler is found (cc, gcc or
clang); the static checks still run.
"""
import pathlib, re, shutil, subprocess, sys, tempfile

R = pathlib.Path(__file__).resolve().parents[2]
SRC = (R / "madeira-d3d12/src/pe/madeira_d3d12.c").read_text()
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok = ok and bool(cond)


def cut(sig):
    i = SRC.index(sig)
    j = SRC.index("{", i)
    depth = 0
    for k in range(j, len(SRC)):
        if SRC[k] == "{":
            depth += 1
        elif SRC[k] == "}":
            depth -= 1
            if depth == 0:
                return SRC[i:k + 1]
    raise SystemExit("unbalanced " + sig)


# --- static checks ---------------------------------------------------------
check("d3d12-tiled-resources defaults to 0", 'int on = mad_cfg_int_pe("d3d12-tiled-resources", 0) ? 1 : 0;' in SRC)
check("d3d12-reserved-max-mb defaults to 1024", 'long long cap = mad_cfg_int_pe("d3d12-reserved-max-mb", 1024);' in SRC)
check("logged once, only when on",
      re.search(r'if \(on\)\s*\n\s*d3d12_log\("\[d3d12-caps\] tiled-resources=1 \(opt-in\)', SRC) is not None)
for fn, stub in (("device_CreateReservedResource(ID3D12Device10", "return stub_ID3D12Device10_CreateReservedResource(This, desc, state, clear, riid, out);"),
                 ("device_CreateReservedResource1(ID3D12Device10", "return stub_ID3D12Device10_CreateReservedResource1(This, desc, state, clear, session, riid, out);"),
                 ("device_CreateReservedResource2(ID3D12Device10", "return stub_ID3D12Device10_CreateReservedResource2(This, desc, layout, clear, session, ncast, cast, riid, out);"),
                 ("device_GetResourceTiling(ID3D12Device10", "stub_ID3D12Device10_GetResourceTiling(This, res, total, pm, shape, nsub, first, tilings); return;"),
                 ("queue_UpdateTileMappings(ID3D12CommandQueue", "stub_ID3D12CommandQueue_UpdateTileMappings(This, res, nreg, starts, sizes, heap, nrange, rflags, heap_offs, counts, flags); return;"),
                 ("queue_CopyTileMappings(ID3D12CommandQueue", "stub_ID3D12CommandQueue_CopyTileMappings(This, dst, dst_start, src, src_start, size, flags); return;")):
    body = cut("STDMETHODCALLTYPE " + fn)
    first = body[body.index("{") + 1:].lstrip().splitlines()
    gate = next(l for l in first if l.strip().startswith("if (!mad_tiled_on())"))
    check(fn.split("(")[0] + ": the stub, unchanged, when the key is off", stub in gate)
check("OPTIONS: Tier 2 and 40 VA bits only behind the key",
      "if (mad_tiled_on()) {   /* opt-in, see TILED RESOURCES; 12_0 requires Tier 2 */\n"
      "            o->TiledResourcesTier = D3D12_TILED_RESOURCES_TIER_2;\n"
      "            o->MaxGPUVirtualAddressBitsPerResource = 40;" in SRC)
check("OPTIONS: the default answer still leaves both at zero (memset)",
      "D3D12_FEATURE_DATA_D3D12_OPTIONS *o = data;\n        if (size < sizeof *o) return E_INVALIDARG;\n        memset(o, 0, sizeof *o);" in SRC)
check("FORMAT_SUPPORT: R32G32B32 vertex formats only behind the key, nothing but IA_VERTEX_BUFFER",
      re.search(r"DXGI_FORMAT_R32G32B32_SINT\) &&\s*\n\s*mad_tiled_on\(\)\) \{(?:.|\n)*?f->Support1 = D3D12_FORMAT_SUPPORT1_IA_VERTEX_BUFFER;\n\s*return S_OK;", SRC) is not None)
for slot in ("g_device_vtbl.CreateReservedResource             = device_CreateReservedResource;   /* d3d12-tiled-resources",
             "g_device_vtbl.CreateReservedResource1            = device_CreateReservedResource1;",
             "g_device_vtbl.CreateReservedResource2            = device_CreateReservedResource2;",
             "g_device_vtbl.GetResourceTiling                  = device_GetResourceTiling;",
             "g_queue_vtbl.UpdateTileMappings     = queue_UpdateTileMappings;",
             "g_queue_vtbl.CopyTileMappings       = queue_CopyTileMappings;"):
    check("vtable: " + slot.split("=")[0].strip(), slot in SRC)
mk = cut("static HRESULT mad_create_reserved(struct mad_device *d, const D3D12_RESOURCE_DESC *desc, REFIID riid, void **out, const char *api) {")
check("reserved resources: refused above the cap with E_OUTOFMEMORY, before anything is allocated",
      mk.index("if (bytes > g_tiled_cap)") < mk.index("mad_create_resource(d, D3D12_HEAP_TYPE_DEFAULT, desc, riid, out)") and "return E_OUTOFMEMORY;" in mk)
check("reserved resources: a NULL out is the documented capability test (S_FALSE)", "if (!out) return S_FALSE;" in mk)
check("reserved resources: backed as a committed resource in a DEFAULT heap",
      "hr = mad_create_resource(d, D3D12_HEAP_TYPE_DEFAULT, desc, riid, out);" in mk)
check("reserved resources: marked as reserved (GetResourceTiling answers only for them)",
      "((struct mad_resource *)*out)->reserved_bytes = bytes;" in mk)
gt = cut("static void STDMETHODCALLTYPE device_GetResourceTiling(ID3D12Device10 *This, ID3D12Resource *res, UINT *total,")
check("GetResourceTiling: packed subresources are D3D12_PACKED_TILE with zero size",
      "tilings[n].StartTileIndexInOverallResource = D3D12_PACKED_TILE;" in gt and "tilings[n].WidthInTiles = 0;" in gt)
check("GetResourceTiling: slice s starts at s x tiles-per-slice",
      "tilings[n].StartTileIndexInOverallResource = slice * t.per_slice + t.mstart[mip];" in gt)
check("GetResourceTiling: packed mips start after slice 0's standard mips",
      "pm->StartTileIndexInOverallResource = t.npacked ? t.per_slice - t.packed_tiles : 0;" in gt)
check("GetResourceTiling: a buffer has no mip information", "if (ok && r->desc.Dimension != D3D12_RESOURCE_DIMENSION_BUFFER) {" in gt)

# --- the tiling code on the host --------------------------------------------
cc = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
b = SRC.index("/* tiled-test:begin")
e = SRC.index("/* tiled-test:end */")
HARNESS = r'''
#include <stdio.h>
#include <string.h>
#define T(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); return 1; } } while (0)
static int shape(int is3d, unsigned bytes, unsigned block, unsigned s, unsigned w, unsigned h, unsigned d) {
    unsigned tw = 0, th = 0, td = 0;
    if (!mad_tile_shape(is3d, bytes, block, s, &tw, &th, &td)) return w == 0;
    if (tw != w || th != h || td != d) { printf("shape(%d,%u,%u,%u) = %ux%ux%u, want %ux%ux%u\n", is3d, bytes, block, s, tw, th, td, w, h, d); return 0; }
    if ((unsigned long long)(tw / block) * (th / block) * td * bytes * s != 65536ull) { printf("not 64 KB\n"); return 0; }
    return 1;
}
int main(void) {
    struct mad_tiling t;
    /* 2D, one sample: 8/16/32/64/128 bits per texel, then BC1/BC4 and BC2/3/5/6H/7 (texels) */
    T(shape(0, 1, 1, 1, 256, 256, 1)); T(shape(0, 2, 1, 1, 256, 128, 1)); T(shape(0, 4, 1, 1, 128, 128, 1));
    T(shape(0, 8, 1, 1, 128, 64, 1));  T(shape(0, 16, 1, 1, 64, 64, 1));
    T(shape(0, 8, 4, 1, 512, 256, 1)); T(shape(0, 16, 4, 1, 256, 256, 1));
    /* 3D */
    T(shape(1, 1, 1, 1, 64, 32, 32)); T(shape(1, 2, 1, 1, 32, 32, 32)); T(shape(1, 4, 1, 1, 32, 32, 16));
    T(shape(1, 8, 1, 1, 32, 16, 16)); T(shape(1, 16, 1, 1, 16, 16, 16));
    T(shape(1, 8, 4, 1, 128, 64, 16)); T(shape(1, 16, 4, 1, 64, 64, 16));
    /* MSAA (Vulkan's standard sparse block shapes, which follow D3D's standard swizzle) */
    T(shape(0, 1, 1, 2, 128, 256, 1)); T(shape(0, 1, 1, 4, 128, 128, 1)); T(shape(0, 1, 1, 8, 64, 128, 1)); T(shape(0, 1, 1, 16, 64, 64, 1));
    T(shape(0, 4, 1, 2, 64, 128, 1));  T(shape(0, 4, 1, 4, 64, 64, 1));   T(shape(0, 16, 1, 16, 16, 16, 1));
    /* no standard shape */
    T(shape(0, 12, 1, 1, 0, 0, 0)); T(shape(0, 8, 4, 4, 0, 0, 0)); T(shape(1, 4, 1, 4, 0, 0, 0)); T(shape(0, 4, 1, 3, 0, 0, 0));

    /* RGBA8 1024x1024, full chain (11 mips): 128x128 tiles; 1024..128 standard (64+16+4+1), 64..1 packed (21844 bytes -> 1 tile) */
    T(mad_tiling_compute(3, 1024, 1024, 1, 0, 4, 1, 1, &t));
    T(t.tw == 128 && t.th == 128 && t.td == 1 && t.mips == 11 && t.slices == 1);
    T(t.nstd == 4 && t.npacked == 7 && t.packed_tiles == 1 && t.per_slice == 86 && t.total == 86);
    T(t.mw[0] == 8 && t.mh[0] == 8 && t.mw[3] == 1 && t.mh[3] == 1 && t.mstart[0] == 0 && t.mstart[1] == 64 && t.mstart[2] == 80 && t.mstart[3] == 84);
    /* the same as a 6-slice array: each slice has its own packed tail */
    T(mad_tiling_compute(3, 1024, 1024, 6, 0, 4, 1, 1, &t) && t.slices == 6 && t.total == 516 && t.per_slice == 86);
    /* BC1 4096x4096, 13 mips: 512x256 tiles; 128+32+8+2 standard, 256..1 packed (43704 bytes -> 1 tile) */
    T(mad_tiling_compute(3, 4096, 4096, 1, 13, 8, 4, 1, &t));
    T(t.tw == 512 && t.th == 256 && t.nstd == 4 && t.npacked == 9 && t.packed_tiles == 1 && t.total == 171);
    T(t.mw[0] == 8 && t.mh[0] == 16 && t.mw[3] == 1 && t.mh[3] == 2);
    /* a mip is standard only while it fills a whole tile in EVERY dimension: 2048x64 RGBA8 -> all packed */
    T(mad_tiling_compute(3, 2048, 64, 1, 1, 4, 1, 1, &t) && t.nstd == 0 && t.npacked == 1 && t.packed_tiles == 8 && t.total == 8);
    /* small: 64x64 RGBA8, 7 mips, everything packed into one tile */
    T(mad_tiling_compute(3, 64, 64, 1, 7, 4, 1, 1, &t) && t.nstd == 0 && t.npacked == 7 && t.packed_tiles == 1 && t.total == 1);
    /* partial tiles round up: 1000x700 RGBA8 -> 8 x 6 */
    T(mad_tiling_compute(3, 1000, 700, 1, 1, 4, 1, 1, &t) && t.nstd == 1 && t.mw[0] == 8 && t.mh[0] == 6 && t.total == 48);
    /* R16F 4096x4096 x 2 slices, 2 mips: 256x128 tiles -> 16x32 + 8x16 per slice */
    T(mad_tiling_compute(3, 4096, 4096, 2, 2, 2, 1, 1, &t) && t.per_slice == 512 + 128 && t.total == 1280 && t.mstart[1] == 512);
    /* 3D RGBA8 256x256x64, 1 mip: 32x32x16 tiles -> 8x8x4 */
    T(mad_tiling_compute(4, 256, 256, 64, 1, 4, 1, 1, &t) && t.slices == 1 && t.mw[0] == 8 && t.mh[0] == 8 && t.md[0] == 4 && t.total == 256);
    /* 4x MSAA RGBA8 1920x1080: 64x64 tiles -> 30 x 17 */
    T(mad_tiling_compute(3, 1920, 1080, 1, 1, 4, 1, 4, &t) && t.tw == 64 && t.th == 64 && t.total == 30 * 17);
    /* buffers: 64 KB tiles of bytes, one subresource */
    T(mad_tiling_compute(1, (1u << 20) + 1, 1, 1, 1, 0, 1, 1, &t) && t.tw == 65536 && t.th == 1 && t.total == 17 && t.mw[0] == 17 && t.nstd == 1 && t.mips == 1);
    T(mad_tiling_compute(1, 65536, 1, 1, 1, 0, 1, 1, &t) && t.total == 1);
    /* no tiling: 1D, 96-bit, empty */
    T(!mad_tiling_compute(2, 4096, 1, 1, 1, 4, 1, 1, &t));
    T(!mad_tiling_compute(3, 256, 256, 1, 1, 12, 1, 1, &t));
    T(!mad_tiling_compute(3, 0, 256, 1, 1, 4, 1, 1, &t));
    T(!mad_tiling_compute(1, 0, 1, 1, 1, 0, 1, 1, &t));
    printf("tiling harness ok\n");
    return 0;
}
'''
if not cc:
    print("SKIP: no host C compiler for the tiling harness")
else:
    code = "#include <string.h>\n" + SRC[b:e] + HARNESS
    with tempfile.TemporaryDirectory() as tdir:
        c = pathlib.Path(tdir) / "t.c"
        c.write_text(code)
        exe = pathlib.Path(tdir) / "t"
        p = subprocess.run([cc, "-std=c99", "-Wall", "-Wno-unused-function", "-o", str(exe), str(c)], capture_output=True, text=True)
        check("tiling harness compiles", p.returncode == 0)
        if p.returncode:
            print(p.stderr[-3000:])
        else:
            r = subprocess.run([str(exe)], capture_output=True, text=True)
            check("standard tile shapes, Tier 2 packing, slices, buffers (" + (r.stdout.strip().splitlines() or ["?"])[-1] + ")",
                  r.returncode == 0 and "tiling harness ok" in r.stdout)
            if r.returncode:
                print(r.stdout[-3000:])

print("PASS" if ok else "FAILED")
sys.exit(0 if ok else 1)
