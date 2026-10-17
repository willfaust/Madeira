// AmbientGlow.metal — the library's ambient card light (AmbientGlow in Library.swift).
//
// A SwiftUI [[stitchable]] color shader on the glow layer: a soft knee on its brightest
// parts, so a very bright artwork (a neon green cover) throws light as strong as the rest
// instead of glaring, while dark and mid tones pass almost unchanged. `knee` is how much
// the brightest value comes down (0: off).

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 ambientKnee(float2 position, half4 color, float knee) {
    if (color.a <= 0.0h || knee <= 0.0) { return color; }
    float3 rgb = float3(color.rgb) / float(color.a);
    rgb -= knee * rgb * rgb;
    return half4(half3(rgb * float(color.a)), color.a);
}

// MARK: - The zoomable grid's glow layer (LibraryGridGlow.swift)
//
// The same light as the SwiftUI AmbientGlow (Library.swift), drawn for every visible card into ONE Metal layer behind the page's
// collection view instead of one SwiftUI view per card. Per card: a quad over the glow frame, the card's blurred artwork as a small
// texture (made once per card on the CPU), the rays' profile around the ring as a 1-D texture, and these parameters (a float buffer):
//   0-3 quad (left, top, right, bottom in NDC; already scaled by the press): the glow's frame and `reach` more on each side
//   4 hue (degrees)   5 knee   6 opacity (strength x press fade)   7 rays mix (0 soft, 1 crisp)
//   8 rays turn (radians)   9-10 glow frame size (points)   11 dark appearance (1: alpha 0)   12 reach (points)
//   13-14 the card's artwork size (points; the light is cut out of it)
//   15... turned ring, mirrored ring, light ring (n values each; n = 36)
// Output is premultiplied; in the dark appearance the alpha is 0, which the compositor adds (plusLighter).

struct GlowVertexOut { float4 position [[position]]; float2 uv; };

vertex GlowVertexOut glowVertex(uint vid [[vertex_id]], constant float *p [[buffer(0)]]) {
    float2 uv = float2(float(vid & 1), float(vid >> 1));
    GlowVertexOut out;
    out.uv = uv;
    out.position = float4(mix(p[0], p[2], uv.x), mix(p[1], p[3], uv.y), 0.0, 1.0);
    return out;
}

static float glowRing(constant float *v, int n, float2 position, float2 size) {
    float2 d = position - size * 0.5;
    float a = atan2(d.y, d.x);
    if (a < 0.0) { a += 6.2831853; }
    float f = a / 6.2831853 * float(n);
    int i0 = min(int(floor(f)), n - 1);
    int i1 = (i0 + 1) % n;
    return mix(v[i0], v[i1], f - float(i0));
}

/// The rays' profile at `theta` (radians), smoothed over `sigma` radians (a wider angle nearer the centre).
static float glowRays(texture2d<float> profile, sampler wrap, float theta, float sigma) {
    float x = theta / 6.2831853;
    float sum = 0.0, weight = 0.0;
    for (int k = -3; k <= 3; k++) {
        float o = float(k) * 0.8;
        float w = exp(-0.5 * o * o);
        sum += w * profile.sample(wrap, float2(x + o * sigma / 6.2831853, 0.5)).r;
        weight += w;
    }
    return sum / weight;
}

fragment half4 glowFragment(GlowVertexOut in [[stage_in]], constant float *p [[buffer(0)]],
                            texture2d<half> base [[texture(0)]], texture2d<float> rays [[texture(1)]],
                            sampler clampSampler [[sampler(0)]], sampler wrapSampler [[sampler(1)]]) {
    constexpr int n = 36;
    float2 size = float2(p[9], p[10]);
    // The quad is the glow's frame and `reach` more on each side, and the base texture spans the whole quad; the rings
    // and the rays are laid out on the frame (its centre is the quad's).
    float reach = p[12];
    float2 position = in.uv * (size + 2.0 * reach) - reach;
    constant float *rings = p + 15;
    half4 c = base.sample(clampSampler, in.uv);
    half4 t = base.sample(clampSampler, float2(1.0) - in.uv) * half(glowRing(rings, n, position, size));
    c = t + c * (1.0h - t.a);
    half4 m = base.sample(clampSampler, float2(1.0 - in.uv.x, in.uv.y)) * half(glowRing(rings + n, n, position, size));
    c = m + c * (1.0h - m.a);
    if (c.a < 0.002h) { return half4(0.0h); }
    float hue = p[4], knee = p[5];
    float3 rgb = float3(c.rgb) / float(c.a);
    float ca = cos(hue * 0.0174532925), sa = sin(hue * 0.0174532925);
    float3 h = float3(
        dot(rgb, float3(0.213 + ca * 0.787 - sa * 0.213, 0.715 - ca * 0.715 - sa * 0.715, 0.072 - ca * 0.072 + sa * 0.928)),
        dot(rgb, float3(0.213 - ca * 0.213 + sa * 0.143, 0.715 + ca * 0.285 + sa * 0.140, 0.072 - ca * 0.072 - sa * 0.283)),
        dot(rgb, float3(0.213 - ca * 0.213 - sa * 0.787, 0.715 - ca * 0.715 + sa * 0.715, 0.072 + ca * 0.928 + sa * 0.072)));
    h = clamp(h, 0.0, 1.0);
    if (knee > 0.0) { h -= knee * h * h; }
    float light = glowRing(rings + 2 * n, n, position, size);
    float3 premultiplied = h * float(c.a) * light;
    float alpha = float(c.a) * light;
    // The rays: soft, and crisp while pressed (the two layers of AmbientGlow's mask), turned a little.
    float2 d = position - size * 0.5;
    float r = max(length(d), 1.0);
    float theta = atan2(d.y, d.x) - p[8];
    float u = glowRays(rays, wrapSampler, theta, 3.0 / r);
    float uc = glowRays(rays, wrapSampler, theta, 0.6 / r);
    float press = p[7];
    float soft = (0.72 + 0.28 * u) * (1.0 - press);
    float crisp = (0.1 + 0.9 * uc) * press;
    float mask = crisp + soft * (1.0 - crisp);
    float k = mask * p[6];
    // Never inside the card: cut the artwork's rounded rect out (inset a point, so the cover's own antialiased edge still covers the
    // glow's), so a cover that is not opaque for a moment (a crossfade, the not-downloaded dim, a press) never shows light through it.
    float2 art = float2(p[13], p[14]);
    float2 q = abs(d) - (art * 0.5 - 1.0 - 12.0);
    float inside = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - 12.0;
    k *= smoothstep(-0.5, 0.5, inside);
    return half4(half3(premultiplied * k), half(alpha * k * (p[11] > 0.5 ? 0.0 : 1.0)));
}
