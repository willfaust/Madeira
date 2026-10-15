// madeira-bcd: helper kernels for madeira_d3d12.dll, compiled to a metallib by
// build/madeira-d3d12/build-pe.sh and embedded in the DLL.
#include <metal_stdlib>
using namespace metal;

struct mad_tess_ind_params {
    uint count;          // argument records
    uint rec_words;      // record stride in 32-bit words (ExecuteIndirect ByteStride / 4)
    uint verts_per_tg;   // patches per object threadgroup x control points per patch
    uint pad;
};

// One D3D12 DRAW_ARGUMENTS / DRAW_INDEXED_ARGUMENTS record (vertex or index
// count first, instance count second) -> MTLDispatchThreadgroupsIndirectArguments
// for the converter's tessellation emulation: ceil(count / verts_per_tg) object
// threadgroups by the instance count. Output records are 16 bytes apart.
kernel void mad_tess_indirect_args(device const uint *args [[buffer(0)]],
                                   device uint *out [[buffer(1)]],
                                   constant mad_tess_ind_params &p [[buffer(2)]],
                                   uint i [[thread_position_in_grid]])
{
    if (i >= p.count)
        return;
    device const uint *a = args + i * p.rec_words;
    uint n = a[0], inst = a[1];
    device uint *o = out + i * 4;
    o[0] = p.verts_per_tg ? (n + p.verts_per_tg - 1) / p.verts_per_tg : 0;
    o[1] = inst;
    o[2] = 1;
    o[3] = 0;
}

// Diagnostics: copy the first n words of an argument record (indirect draw or
// dispatch arguments the GPU wrote) to a CPU-visible ring, read seconds later.
kernel void mad_probe_words(device const uint *src [[buffer(0)]],
                            device uint *dst [[buffer(1)]],
                            constant uint &n [[buffer(2)]],
                            uint i [[thread_position_in_grid]])
{
    if (i < n)
        dst[i] = src[i];
}

// madeira-bcd typed-view-align = 4: what texture buffers made at offsets that
// are not a multiple of 16 bytes read at their first texels. Metal documents a
// 16-byte minimum, but the converter's typed reads only come out right when a
// view's texture starts exactly at its first element. The runtime fills a
// buffer with bytes 0, 1, 2, ... and compares. Compiled again without it
// (-DMAD_NO_TEXBUF_PROBE) if it does not compile.
#ifndef MAD_NO_TEXBUF_PROBE
kernel void mad_texbuf_probe(texture_buffer<uint, access::read> t32 [[texture(0)]],
                             texture_buffer<uint, access::read> t32b [[texture(1)]],
                             texture_buffer<uint, access::read> t16 [[texture(2)]],
                             texture_buffer<uint, access::read> t8 [[texture(3)]],
                             device uint *out [[buffer(0)]],
                             uint i [[thread_position_in_grid]])
{
    if (i != 0)
        return;
    out[0] = t32.read(0u).x;
    out[1] = t32.read(1u).x;
    out[2] = t32b.read(0u).x;
    out[3] = t16.read(0u).x;
    out[4] = t8.read(0u).x;
}
#endif

// madeira-bcd fi-nan-clean: FSR 3's frame-interpolation vector fields are
// R32Uint textures whose texels keep a half-float vector component in bits
// 0..15 and priority bits above it. A texel whose vector half is a NaN or Inf
// half-float (exponent bits all set) blacks out a 16x16 block of a generated
// frame; the runtime runs this after a FidelityFX dispatch that wrote such a
// field. Zeroes those texels (mode 2: also when bits 16..31 read as one) and
// counts them in cnt[0] (vector half) and cnt[1] (upper half only). Compiled
// again without it (-DMAD_NO_NAN_CLEAN) if it does not compile.
#ifndef MAD_NO_NAN_CLEAN
struct mad_nan_clean_params {
    uint w, h, mode, pad;
};

kernel void mad_fi_nan_clean(texture2d_array<uint, access::read_write> t [[texture(0)]],
                             constant mad_nan_clean_params &p [[buffer(0)]],
                             device atomic_uint *cnt [[buffer(1)]],
                             uint3 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.w || gid.y >= p.h)
        return;
    uint v = t.read(gid.xy, gid.z).x;
    bool lo = (v & 0x7c00u) == 0x7c00u;
    bool hi = p.mode >= 2u && (v & 0x7c000000u) == 0x7c000000u;
    if (!lo && !hi)
        return;
    t.write(uint4(0u), gid.xy, gid.z);
    atomic_fetch_add_explicit(&cnt[lo ? 0 : 1], 1u, memory_order_relaxed);
}
#endif

// madeira-bcd clear-rects: ClearRenderTargetView / ClearDepthStencilView with
// rectangles, as DXMT's D3D11 ClearView does them: one triangle over the whole
// target per rectangle, cut by the scissor, one instance per array layer. The
// value is fragment buffer 0 (x is the depth); a stencil value comes from the
// depth-stencil state's reference. The build compiles the file again
// without them (-DMAD_NO_CLEAR_RECTS) if they do not compile, so the
// kernels above never depend on them.
#ifndef MAD_NO_CLEAR_RECTS
struct mad_clear_out {
    float4 position [[position]];
    uint layer [[render_target_array_index]];
};

vertex mad_clear_out mad_clear_vs(ushort id [[vertex_id]], ushort inst [[instance_id]])
{
    mad_clear_out o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    o.layer = inst;
    return o;
}

fragment float4 mad_clear_fs_float(constant float4 &v [[buffer(0)]]) { return v; }
fragment uint4 mad_clear_fs_uint(constant float4 &v [[buffer(0)]]) { return (uint4)v; }
fragment int4 mad_clear_fs_sint(constant float4 &v [[buffer(0)]]) { return (int4)v; }

struct mad_clear_depth_out {
    float depth [[depth(any)]];
};

fragment mad_clear_depth_out mad_clear_fs_depth(constant float4 &v [[buffer(0)]])
{
    mad_clear_depth_out o;
    o.depth = v.x;
    return o;
}
#endif
