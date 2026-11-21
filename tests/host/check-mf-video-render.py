#!/usr/bin/env python3
"""The path a Media Foundation movie takes to the screen on DXMT, from production source; nothing runs.

Senren Banka's WMV movie (krkrz's MFPlayer) played its audio over a black video window, and the
audio ran short every few seconds. These are the checks that the causes stay fixed:
1. DXMT's d3d9 follows native: StretchRect does not stretch into a destination that is not a
   render target, and a D3DLOCK_DISCARD lock of a DEFAULT surface skips the readback that a
   plain lock waits for.
2. Wine's DXVA2 (the wine submodule) creates DXVA2_VideoProcessorRenderTarget surfaces as
   lockable render targets, so the EVR mixer can stretch the picture into its window-sized
   target, and filters a scaled blit.
3. The EVR's and mfplat's sample allocators are what ask for that surface type.
4. mfplat's D3D9 surface buffer overwrites a surface in ContiguousCopyFrom (the sample copier's
   path) with D3DLOCK_DISCARD, and keeps the contents for a plain write-only lock.
5. Wine's media source asks for every stream on one work queue, which has one thread: the
   reason our parser decodes video ahead on a worker (wg_parser_av_ios.c, MADEIRA_WG_VIDEO_AHEAD).
"""
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[2]
wine = root / "wine"
dxmt = root / "dxmt"
need = [wine / "dlls/dxva2/main.c", dxmt / "src/d3d9/d3d9_stretchrect.hpp"]
for n in need:
    if not n.exists():
        sys.exit("SKIP-FAIL: %s is missing (submodules not checked out)" % n)


def function(source, start):
    a = source.index(start)
    b = source.index("{", a)
    depth, c = 1, b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}")
        c += 1
    return source[a:c]


# ---- 1. DXMT ------------------------------------------------------------------
plan = (dxmt / "src/d3d9/d3d9_stretchrect.hpp").read_text()
assert "if (extent_mismatch && !(dst.usage & D3DUSAGE_RENDERTARGET))\n    return fail();" in plan, \
    "DXMT no longer refuses a stretch into a non-render-target: recheck what the DXVA2 change answers"
surface = (dxmt / "src/d3d9/d3d9_surface.cpp").read_text()
lock = function(surface, "MTLD3D9Surface::LockRect(")
assert "!(Flags & D3DLOCK_DISCARD)" in lock and "readbackSurfaceMirror" in lock, "a discard lock skips the readback"
print("PASS: DXMT refuses a stretch into a non-render-target and skips the readback for a discard lock")

# ---- 2. DXVA2 -----------------------------------------------------------------
dxva2 = (wine / "dlls/dxva2/main.c").read_text()
create = function(dxva2, "static HRESULT WINAPI device_manager_processor_service_CreateSurface(")
assert re.search(r"dxvaType == DXVA2_VideoProcessorRenderTarget && pool == D3DPOOL_DEFAULT\)\s*"
                 r"hr = IDirect3DDevice9_CreateRenderTarget\(manager->device, width, height, format,\s*"
                 r"D3DMULTISAMPLE_NONE, 0, TRUE,", create), "processor render targets are lockable render targets"
assert "CreateOffscreenPlainSurface" in create, "other surface types stay offscreen plain"
blit = function(dxva2, "static HRESULT WINAPI video_processor_VideoProcessBlt(")
assert "scaled ? D3DTEXF_LINEAR : D3DTEXF_POINT" in blit, "a scaled blit is filtered"
assert "IDirect3DDevice9_StretchRect(device, samples[i].SrcSurface" in blit
print("PASS: DXVA2 makes video processor render targets render targets (lockable) and filters a scaled blit")

# ---- 3. the allocators ----------------------------------------------------------
for f in ["dlls/evr/sample.c", "dlls/mfplat/sample.c"]:
    text = (wine / f).read_text()
    assert re.search(r"IDirectXVideoProcessorService_CreateSurface\([^;]*DXVA2_VideoProcessorRenderTarget", text, re.S), f
print("PASS: the EVR's and mfplat's sample allocators ask for DXVA2_VideoProcessorRenderTarget surfaces")

# ---- 4. mfplat --------------------------------------------------------------------
buf = (wine / "dlls/mfplat/buffer.c").read_text()
copy = function(buf, "static HRESULT WINAPI d3d9_surface_buffer_ContiguousCopyFrom(")
assert "D3DLOCK_DISCARD" in copy and "memory_2d_buffer_ContiguousCopyFrom(iface" in copy, copy[:200]
vtbl = buf[buf.index("static const IMF2DBuffer2Vtbl d3d9_surface_buffer_vtbl ="):]
vtbl = vtbl[:vtbl.index("};")]
assert "d3d9_surface_buffer_ContiguousCopyFrom," in vtbl and "memory_2d_buffer_ContiguousCopyFrom," not in vtbl
plain = function(buf, "static HRESULT d3d9_surface_buffer_lock(")
assert "IDirect3DSurface9_LockRect(buffer->d3d9_surface.surface, &buffer->d3d9_surface.rect, NULL, 0)" in plain, \
    "a plain write-only lock keeps the contents (native, per mfplat's tests)"
sample = function((wine / "dlls/mfplat/sample.c").read_text(), "static HRESULT WINAPI sample_CopyToBuffer(")
assert "IMF2DBuffer_ContiguousCopyFrom(buffer2d" in sample, "the copier's path is ContiguousCopyFrom"
print("PASS: mfplat overwrites a D3D9 surface in ContiguousCopyFrom with D3DLOCK_DISCARD; plain locks keep the contents")

# ---- 5. why decode-ahead ------------------------------------------------------------
source = (wine / "dlls/winegstreamer/media_source.c").read_text()
assert "MFAllocateWorkQueue(&object->async_commands_queue)" in source
invoke = function(source, "static HRESULT WINAPI source_async_commands_Invoke(")
assert "wait_on_sample(command->u.request_sample.stream" in invoke, "every stream's request goes through one queue"
queue = (wine / "dlls/rtworkq/queue.c").read_text()
assert re.search(r"max_thread = \(desc->queue_type == RTWQ_STANDARD_WORKQUEUE[^;]*\? 1 : 4;", queue), \
    "a standard work queue has one thread"
core = (root / "build/ntdll-unix/wg_parser_av_ios.c").read_text()
glue = (root / "build/ntdll-unix/winegstreamer_unixlib_ios.c").read_text()
assert "static void *mav_ahead_main( void *arg )" in core and "mav_heavy_begin( p, s )" in core
assert 'getenv( "MADEIRA_WG_VIDEO_AHEAD" )' in glue and "mav_allow_video_ahead(" in glue
print("PASS: the media source asks for every stream on one single-thread queue, and the parser decodes video ahead "
      "(MADEIRA_WG_VIDEO_AHEAD)")
