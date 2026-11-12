/* Remote Metal host daemon -- runs on macOS, owns the real MTLDevice.
 *
 * The guest never sees a host pointer. Every Objective-C object it can refer
 * to lives in a generation-tagged table here, and the guest holds only an
 * index. See protocol.h for why that matters.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include <objc/runtime.h>
#include "../protocol.h"
#include "wmt_decode.h"
/* The guest sends WMT*Info structs verbatim, so the host must read them with
 * the SAME declarations. Both sides compile this header. */
#define WINEMETAL_API
#include "../../dxmt/src/winemetal/winemetal.h"

/* ---- handle table ------------------------------------------------------ */

typedef struct {
    __unsafe_unretained id obj;   /* retained manually via CFBridgingRetain */
    uint32_t generation;
    int      in_use;
    uint32_t refs;                /* guest-visible references to this identity */
} rm_slot;

/* Per-class creation census. "No errors logged" is not evidence that objects
 * were created -- a call can return nil with no error, and the guest tolerates
 * nulls. Counting what actually got interned, by class, turns that into a
 * fact the log states outright. */
#define RM_CLASSES 32
static unsigned long g_enc_seq;   /* ml879: encoder index, mirrored by the guest runtime */
static struct { const char *name; unsigned n; } g_census[RM_CLASSES];
static unsigned g_census_n;

static void rm_census_note(id obj) {
    if (!obj) return;
    const char *cls = object_getClassName(obj);
    for (unsigned i = 0; i < g_census_n; i++)
        if (strcmp(g_census[i].name, cls) == 0) { g_census[i].n++; return; }
    if (g_census_n < RM_CLASSES) { g_census[g_census_n].name = cls; g_census[g_census_n].n = 1; g_census_n++; }
}

static void rm_census_report(void) {
    if (!g_census_n) { fprintf(stderr, "[rmetald] census: no objects created\n"); return; }
    fprintf(stderr, "[rmetald] census: objects created this session\n");
    for (unsigned i = 0; i < g_census_n; i++)
        fprintf(stderr, "[rmetald]   %-44s %u\n", g_census[i].name, g_census[i].n);
    memset(g_census, 0, sizeof g_census); g_census_n = 0;
}

static rm_slot  *g_slots;
static uint32_t  g_slot_count;
static uint32_t  g_slot_cap;
static uint32_t  g_live;

static id rm_resolve(uint64_t h, uint32_t *err);   /* defined below */

/* One object == one handle. Interning the same object twice used to mint a
 * second slot, so the guest could hold two identities for one device and any
 * equality test between them would be false. Identity is looked up first and
 * the existing handle returned with its refcount raised. */
static uint32_t rm_find_slot(id obj) {
    for (uint32_t i = 0; i < g_slot_count; i++)
        if (g_slots[i].in_use && g_slots[i].obj == obj) return i;
    return UINT32_MAX;
}

static uint64_t rm_intern(id obj) {
    if (!obj) return RM_NULL_HANDLE;
    uint32_t slot = rm_find_slot(obj);
    if (slot != UINT32_MAX) {
        g_slots[slot].refs++;
        return RM_HANDLE(g_slots[slot].generation, slot);
    }
    slot = UINT32_MAX;
    for (uint32_t i = 0; i < g_slot_count; i++)
        if (!g_slots[i].in_use) { slot = i; break; }
    if (slot == UINT32_MAX) {
        if (g_slot_count == g_slot_cap) {
            g_slot_cap = g_slot_cap ? g_slot_cap * 2 : 256;
            g_slots = realloc(g_slots, g_slot_cap * sizeof(rm_slot));
        }
        slot = g_slot_count++;
        g_slots[slot].generation = 1;
    }
    CFBridgingRetain(obj);              /* +1, balanced when refs reaches 0 */
    rm_census_note(obj);
    g_slots[slot].obj = obj;
    g_slots[slot].in_use = 1;
    g_slots[slot].refs = 1;
    g_live++;
    return RM_HANDLE(g_slots[slot].generation, slot);
}

/* Retain must return the SAME identity. Minting a fresh handle left the guest
 * holding the original while the new one carried the reference, so the next
 * release freed an object the guest still used. */
static uint64_t rm_retain_handle(uint64_t h, uint32_t *err) {
    id obj = rm_resolve(h, err);
    if (*err != RM_OK) return RM_NULL_HANDLE;
    if (!obj) return RM_NULL_HANDLE;
    g_slots[RM_HANDLE_SLOT(h)].refs++;
    return h;
}
/* Returns nil and sets *err when the handle is stale or bogus. Callers must
 * check: silently treating a stale handle as valid is exactly the corruption
 * this table exists to prevent. */
static id rm_resolve(uint64_t h, uint32_t *err) {
    *err = RM_OK;
    if (h == RM_NULL_HANDLE) return nil;
    /* An untagged non-zero value is a LOCAL pointer that reached the wire --
     * a producer that was not switched to remote. Name it: silently treating
     * it as an index would address an arbitrary table slot. */
    if (!RM_IS_REMOTE(h)) {
        fprintf(stderr, "[rmetald] handle %#llx is not tagged remote -- a local "
                "pointer reached the wire from an unswitched producer\n",
                (unsigned long long)h);
        *err = RM_ERR_BAD_HANDLE; return nil;
    }
    uint32_t slot = RM_HANDLE_SLOT(h), gen = RM_HANDLE_GEN(h);
    if (slot >= g_slot_count || !g_slots[slot].in_use) { *err = RM_ERR_BAD_HANDLE; return nil; }
    if (g_slots[slot].generation != gen)                { *err = RM_ERR_STALE_HANDLE; return nil; }
    return g_slots[slot].obj;
}

/* ---- ml898: encoders that are still open ---------------------------------
 * Metal aborts the whole process when a command encoder is deallocated
 * without endEncoding ("Command encoder released without endEncoding", seen
 * on level teardown after Esc). The guest can legitimately drop a list with
 * an open encoder; the host must not die for it. Track open encoders and end
 * them before the final release. */
#define RM_MAX_OPEN_ENC 256
/* ml1010: remember WHICH command buffer each open encoder belongs to.
 *
 * Tracking encoders alone covered release-time teardown, but not commit:
 * RM_OP_COMMIT called [cb commit] unconditionally, and Metal aborts the whole
 * daemon on `commit command buffer with uncommitted encoder`. That is exactly
 * how rmetald died mid-run -- and when the host dies the guest reports "cannot
 * reach" and silently falls back to local, which looks like a successful
 * render. The guest can legitimately abandon a list with an encoder still open
 * (it does so on every failed pipeline), so the host must close it rather than
 * die for it, and to close it we have to know its command buffer. */
static struct { id enc; id cb; } g_open_enc[RM_MAX_OPEN_ENC];
/* ml1016: if the table ever overflows we STOP KNOWING which encoders are open,
 * and the is-open guard below must not then treat every untracked encoder as
 * ended -- that would silently drop all rendering. Once this is set the guard
 * degrades to permissive, i.e. exactly the pre-ml1016 behaviour. */
static int g_enc_table_overflowed;
static void rm_enc_opened(id e, id cb) {
    if (!e) return;
    for (int i = 0; i < RM_MAX_OPEN_ENC; i++)
        if (!g_open_enc[i].enc) { g_open_enc[i].enc = e; g_open_enc[i].cb = cb; return; }
    if (!g_enc_table_overflowed) {
        g_enc_table_overflowed = 1;
        fprintf(stderr, "[rmetald] open-encoder table full -- ml1016 is now permissive "
                        "(cannot distinguish ended encoders any more)\n");
    }
}
static int rm_enc_closed(id e) {
    for (int i = 0; i < RM_MAX_OPEN_ENC; i++)
        if (g_open_enc[i].enc == e) { g_open_enc[i].enc = nil; g_open_enc[i].cb = nil; return 1; }
    return 0;
}
/* ml1016: is this encoder still open? The open-encoder table is the only record
 * of that, and ml1010 removes an encoder from it when it auto-closes one before
 * a commit -- so anything the guest sends to that encoder AFTERWARDS must be
 * refused rather than passed to Metal. Issuing into an ended encoder makes AGX
 * dereference a torn-down context and segfaults the whole daemon
 * (-[AGXG16XFamilyBlitContext copyFromBuffer:...], KERN_INVALID_ADDRESS). */
static int rm_enc_is_open(id e) {
    if (!e) return 0;
    if (g_enc_table_overflowed) return 1;   /* fail permissive, never drop blind */
    for (int i = 0; i < RM_MAX_OPEN_ENC; i++) if (g_open_enc[i].enc == e) return 1;
    return 0;
}

/* ml1010: end every encoder still open on this command buffer. Returns how many
 * it had to close -- non-zero means the guest left one open, which is worth
 * seeing in the log even though the host now survives it. */
static int rm_enc_end_for_cb(id cb) {
    int n = 0;
    if (!cb) return 0;
    for (int i = 0; i < RM_MAX_OPEN_ENC; i++) {
        if (!g_open_enc[i].enc || g_open_enc[i].cb != cb) continue;
        [(id<MTLCommandEncoder>)g_open_enc[i].enc endEncoding];
        g_open_enc[i].enc = nil; g_open_enc[i].cb = nil;
        n++;
    }
    return n;
}

/* ml1019: Metal permits ONE active encoder per command buffer and aborts the
 * process on a second (`A command encoder is already encoding to this command
 * buffer`, -[AGXG16XFamilyCommandBuffer blitCommandEncoderCommon:]). The guest
 * can reach that state -- ml1016 already showed it confused about encoder
 * lifetime -- so end the outstanding one here rather than die for it. */
static void rm_enc_end_open_on_cb(id cb, const char *what) {
    int n;
    if (!cb) return;
    n = rm_enc_end_for_cb(cb);
    if (n) {
        static unsigned said;
        if (said++ < 16)
            fprintf(stderr, "[rmetald] ml1019 ended %d encoder(s) still open on command buffer %p "
                    "before creating a %s encoder\n", n, (__bridge void *)cb, what);
    }
}

/* ---- ml898: frame dump ----------------------------------------------------
 * Every colour/depth attachment bound by a render pass since the last present
 * is remembered; when /tmp/rmetald-dump-now exists at present time, each one
 * is blitted to a shared copy and written as a PNG under /tmp/rmetald-dump/.
 * This is the ground truth for "the screen is black": it shows which pass
 * produced pixels and which did not. */
#define RM_MAX_FRAME_ATT 96
static uint64_t g_frame_att[RM_MAX_FRAME_ATT]; static unsigned g_frame_att_n;
static void rm_frame_att_note(uint64_t h) {
    if (!h) return;
    for (unsigned i = 0; i < g_frame_att_n; i++) if (g_frame_att[i] == h) return;
    if (g_frame_att_n < RM_MAX_FRAME_ATT) g_frame_att[g_frame_att_n++] = h;
}
static void rm_write_png(const char *path, const uint8_t *rgba, unsigned w, unsigned h) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, rgba, (size_t)w * h * 4, NULL);
    CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, cs, kCGImageAlphaNoneSkipLast, dp, NULL, false, kCGRenderingIntentDefault);
    CFStringRef cfp = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, cfp, kCFURLPOSIXPathStyle, false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (dst) { CGImageDestinationAddImage(dst, img, NULL); CGImageDestinationFinalize(dst); CFRelease(dst); }
    CFRelease(url); CFRelease(cfp); CGImageRelease(img); CGDataProviderRelease(dp); CGColorSpaceRelease(cs);
}
static float rm_half(uint16_t h) {
    uint32_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff; float v;
    if (e == 0) v = ldexpf((float)m, -24); else if (e == 31) v = m ? NAN : INFINITY; else v = ldexpf((float)(m | 0x400), (int)e - 25);
    return s ? -v : v;
}
static inline uint8_t rm_tone(float v) { if (!(v == v)) return 255; if (v < 0) v = 0; v = v / (1.0f + v); return (uint8_t)(powf(v, 1.0f/2.2f) * 255.0f + 0.5f); }
/* returns bytes per pixel for the formats we can read back, 0 otherwise */
static unsigned rm_fmt_bpp(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Uint: return 1;
    case MTLPixelFormatRG8Unorm: case MTLPixelFormatR16Float: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Unorm: return 2;
    case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
    case MTLPixelFormatRG11B10Float: case MTLPixelFormatRGB9E5Float: case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatR32Uint:
    case MTLPixelFormatR32Float: case MTLPixelFormatRG16Float: case MTLPixelFormatRG16Uint: case MTLPixelFormatDepth32Float:
    case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRG16Unorm: return 4;
    case MTLPixelFormatRGBA16Float: case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Float: case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRGBA16Uint: return 8;
    case MTLPixelFormatRGBA32Float: case MTLPixelFormatRGBA32Uint: return 16;
    default: return 0;
    }
}
static void rm_pixel_to_rgba(MTLPixelFormat f, const uint8_t *p, uint8_t *o) {
    const uint16_t *h16 = (const uint16_t *)p; const uint32_t *u32 = (const uint32_t *)p; const float *f32 = (const float *)p;
    switch (f) {
    case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Uint: o[0]=o[1]=o[2]=p[0]; break;
    case MTLPixelFormatRG8Unorm: o[0]=p[0]; o[1]=p[1]; o[2]=0; break;
    case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatRGBA8Uint: o[0]=p[0]; o[1]=p[1]; o[2]=p[2]; break;
    case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB: o[0]=p[2]; o[1]=p[1]; o[2]=p[0]; break;
    case MTLPixelFormatRGB10A2Unorm: o[0]=(u32[0]&1023)>>2; o[1]=((u32[0]>>10)&1023)>>2; o[2]=((u32[0]>>20)&1023)>>2; break;
    case MTLPixelFormatRG11B10Float: { uint32_t v=u32[0]; float r=rm_half((uint16_t)(((v&0x7ff)<<4))), g=rm_half((uint16_t)((((v>>11)&0x7ff))<<4)), b=rm_half((uint16_t)((((v>>22)&0x3ff))<<5));
        o[0]=rm_tone(r); o[1]=rm_tone(g); o[2]=rm_tone(b); break; }
    case MTLPixelFormatRGB9E5Float: { uint32_t v=u32[0]; int e=(int)(v>>27)-15-9; float s=ldexpf(1.0f,e); o[0]=rm_tone((v&511)*s); o[1]=rm_tone(((v>>9)&511)*s); o[2]=rm_tone(((v>>18)&511)*s); break; }
    case MTLPixelFormatR16Float: o[0]=o[1]=o[2]=rm_tone(rm_half(h16[0])); break;
    case MTLPixelFormatR16Unorm: o[0]=o[1]=o[2]=h16[0]>>8; break;
    case MTLPixelFormatR16Uint: { uint32_t v=h16[0]*2654435761u; o[0]=v>>24; o[1]=v>>16; o[2]=v>>8; break; }
    case MTLPixelFormatRG16Float: o[0]=rm_tone(rm_half(h16[0])); o[1]=rm_tone(rm_half(h16[1])); o[2]=0; break;
    case MTLPixelFormatRG16Unorm: o[0]=h16[0]>>8; o[1]=h16[1]>>8; o[2]=0; break;
    case MTLPixelFormatRG16Uint: { uint32_t v=(h16[0]|(h16[1]<<16))*2654435761u; o[0]=v>>24; o[1]=v>>16; o[2]=v>>8; break; }
    case MTLPixelFormatRGBA16Float: o[0]=rm_tone(rm_half(h16[0])); o[1]=rm_tone(rm_half(h16[1])); o[2]=rm_tone(rm_half(h16[2])); break;
    case MTLPixelFormatRGBA16Unorm: o[0]=h16[0]>>8; o[1]=h16[1]>>8; o[2]=h16[2]>>8; break;
    case MTLPixelFormatRGBA16Uint: { uint32_t v=(h16[0]^(h16[1]<<11)^(h16[2]<<22))*2654435761u; o[0]=v>>24; o[1]=v>>16; o[2]=v>>8; break; }
    case MTLPixelFormatR32Float: case MTLPixelFormatDepth32Float: o[0]=o[1]=o[2]=rm_tone(f32[0]); break;
    case MTLPixelFormatRG32Float: o[0]=rm_tone(f32[0]); o[1]=rm_tone(f32[1]); o[2]=0; break;
    case MTLPixelFormatRGBA32Float: o[0]=rm_tone(f32[0]); o[1]=rm_tone(f32[1]); o[2]=rm_tone(f32[2]); break;
    case MTLPixelFormatR32Uint: { uint32_t v=u32[0]*2654435761u; if (!u32[0]) v=0; o[0]=v>>24; o[1]=v>>16; o[2]=v>>8; break; }
    case MTLPixelFormatRG32Uint: case MTLPixelFormatRGBA32Uint: { uint32_t v=(u32[0]^(u32[1]*40503u))*2654435761u; if (!u32[0] && !u32[1]) v=0; o[0]=v>>24; o[1]=v>>16; o[2]=v>>8; break; }
    default: o[0]=o[1]=o[2]=0;
    }
    o[3]=255;
}
static id<MTLComputePipelineState> rm_depth_copy_pso(id<MTLDevice> dev, int array) {
    static id<MTLComputePipelineState> pso[2]; static int tried[2];
    if (pso[array] || tried[array]) return pso[array];
    tried[array] = 1;
    NSError *err = nil;
    /* ml933: the D3D12 runtime allocates EVERY 2D texture as a 2D array, so a
     * depth2d binding read nothing and every depth dump came back 100 %
     * uniform -- including the shadow atlas, which looked empty while 1424
     * draws a frame were writing it. Pick the kernel the source type needs. */
    NSString *src = array
        ? @"#include <metal_stdlib>\nusing namespace metal;\n"
           "kernel void depth_copy(depth2d_array<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], constant uint &slice [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {"
           " if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return; dst.write(float4(src.read(gid, slice), 0, 0, 1), gid); }"
        : @"#include <metal_stdlib>\nusing namespace metal;\n"
           "kernel void depth_copy(depth2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {"
           " if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return; dst.write(float4(src.read(gid), 0, 0, 1), gid); }";
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
    id<MTLFunction> fn = [lib newFunctionWithName:@"depth_copy"];
    if (fn) pso[array] = [dev newComputePipelineStateWithFunction:fn error:&err];
    if (!pso[array]) fprintf(stderr, "[rmetald-dump] depth copy kernel (%s) unavailable: %s\n",
                             array ? "array" : "2d", err.localizedDescription.UTF8String);
    return pso[array];
}
static void rm_dump_slice(id<MTLCommandQueue> q, id<MTLTexture> t, const char *path, const char *tag, NSUInteger slice);
/* ml903: depth/stencil formats cannot be blitted to a readable copy; run a
 * compute copy of the depth plane into an R32Float texture and dump that. */
static void rm_dump_depth(id<MTLCommandQueue> q, id<MTLTexture> t, const char *path, const char *tag, NSUInteger slice) {
    int array = (t.textureType == MTLTextureType2DArray);
    id<MTLComputePipelineState> pso = rm_depth_copy_pso(t.device, array);
    if (!pso || t.sampleCount > 1 || (t.textureType != MTLTextureType2D && t.textureType != MTLTextureType2DArray)) return;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:t.width height:t.height mipmapped:NO];
    td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    id<MTLTexture> dst = [t.device newTextureWithDescriptor:td];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:pso]; [ce setTexture:t atIndex:0]; [ce setTexture:dst atIndex:1];
    if (array) { uint32_t s32 = (uint32_t)slice; [ce setBytes:&s32 length:sizeof s32 atIndex:0]; }
    [ce dispatchThreads:MTLSizeMake(t.width, t.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    char tag2[96]; snprintf(tag2, sizeof tag2, "%s DEPTH(fmt%lu)", tag, (unsigned long)t.pixelFormat);
    rm_dump_slice(q, dst, path, tag2, 0);
}
static void rm_dump_slice(id<MTLCommandQueue> q, id<MTLTexture> t, const char *path, const char *tag, NSUInteger slice) {
    unsigned bpp = rm_fmt_bpp(t.pixelFormat);
    if (!bpp && (t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 || t.pixelFormat == MTLPixelFormatDepth24Unorm_Stencil8 || t.pixelFormat == MTLPixelFormatDepth16Unorm)) {
        rm_dump_depth(q, t, path, tag, slice); return;
    }
    if (!bpp || t.sampleCount > 1) {
        fprintf(stderr, "[rmetald-dump] %s: skipped fmt=%lu type=%lu samples=%lu %lux%lu\n", tag,
                (unsigned long)t.pixelFormat, (unsigned long)t.textureType, (unsigned long)t.sampleCount,
                (unsigned long)t.width, (unsigned long)t.height);
        return;
    }
    NSUInteger w = t.width, ht = t.height;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat width:w height:ht mipmapped:NO];
    td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> copy = [t.device newTextureWithDescriptor:td];
    if (!copy) { fprintf(stderr, "[rmetald-dump] %s: no shared copy for fmt %lu\n", tag, (unsigned long)t.pixelFormat); return; }
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    /* ml933: for a 3D texture `slice` is the z plane, not an array slice. The
     * colour-grading LUT is a 32^3 volume and was being skipped entirely. */
    int is3d = (t.textureType == MTLTextureType3D);
    [be copyFromTexture:t sourceSlice:(is3d ? 0 : slice) sourceLevel:0
           sourceOrigin:MTLOriginMake(0,0,is3d ? slice : 0) sourceSize:MTLSizeMake(w,ht,1)
              toTexture:copy destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
    size_t bpr = (size_t)w * bpp; uint8_t *px = malloc(bpr * ht);
    [copy getBytes:px bytesPerRow:bpr fromRegion:MTLRegionMake2D(0,0,w,ht) mipmapLevel:0];
    uint8_t *rgba = malloc((size_t)w * ht * 4);
    unsigned long nonzero = 0, same = 0;
    /* ml906: "non-zero" cannot tell a cleared target from a rendered one (a
     * clear colour with alpha 1, or depth cleared to 1.0, is all non-zero).
     * Count pixels identical to the centre pixel too: a cleared texture is
     * ~100 % uniform, rendered content is not. */
    const uint8_t *ref = px + (ht / 2) * bpr + (w / 2) * bpp;
    for (NSUInteger y = 0; y < ht; y++) for (NSUInteger x = 0; x < w; x++) {
        const uint8_t *p = px + y * bpr + x * bpp; uint8_t *o = rgba + (y * w + x) * 4;
        rm_pixel_to_rgba(t.pixelFormat, p, o);
        for (unsigned k = 0; k < bpp; k++) if (p[k]) { nonzero++; break; }
        if (!memcmp(p, ref, bpp)) same++;
    }
    /* ml933: the PNG preview runs every float through rm_tone, which clamps
     * negatives to 0 and saturates large values at 255 -- and for a tiny
     * control buffer (the local-exposure bilateral grid is 7x4x32 RG32Float)
     * those are exactly the values that matter. Write the raw numbers beside
     * the PNG so a grid cell can be read instead of guessed at. */
    if (w * ht <= 8192) {
        int isf = (t.pixelFormat == MTLPixelFormatR32Float || t.pixelFormat == MTLPixelFormatRG32Float ||
                   t.pixelFormat == MTLPixelFormatRGBA32Float || t.pixelFormat == MTLPixelFormatR16Float ||
                   t.pixelFormat == MTLPixelFormatRG16Float || t.pixelFormat == MTLPixelFormatRGBA16Float);
        unsigned nch = (t.pixelFormat == MTLPixelFormatR32Float || t.pixelFormat == MTLPixelFormatR16Float) ? 1
                     : (t.pixelFormat == MTLPixelFormatRG32Float || t.pixelFormat == MTLPixelFormatRG16Float) ? 2 : 4;
        int half = (t.pixelFormat == MTLPixelFormatR16Float || t.pixelFormat == MTLPixelFormatRG16Float ||
                    t.pixelFormat == MTLPixelFormatRGBA16Float);
        if (isf) {
            char tp[288]; const char *dot = strrchr(path, '.');
            int stem = dot ? (int)(dot - path) : (int)strlen(path);
            snprintf(tp, sizeof tp, "%.*s.txt", stem, path);
            FILE *tf = fopen(tp, "w");
            if (tf) {
                fprintf(tf, "%s %lux%lu fmt=%lu ch=%u\n", tag, (unsigned long)w, (unsigned long)ht,
                        (unsigned long)t.pixelFormat, nch);
                for (NSUInteger y = 0; y < ht; y++) {
                    for (NSUInteger x = 0; x < w; x++) {
                        const uint8_t *px2 = px + y * bpr + x * bpp;
                        fputc('[', tf);
                        for (unsigned k = 0; k < nch; k++) {
                            float v = half ? rm_half(((const uint16_t *)px2)[k]) : ((const float *)px2)[k];
                            fprintf(tf, "%s%.6g", k ? " " : "", v);
                        }
                        fputs("]", tf);
                    }
                    fputc('\n', tf);
                }
                fclose(tf);
            }
        }
    }
    rm_write_png(path, rgba, (unsigned)w, (unsigned)ht);
    fprintf(stderr, "[rmetald-dump] %s: %lux%lu fmt=%lu usage=0x%lx nonzero=%lu/%lu (%.1f%%) uniform=%.1f%% -> %s\n", tag,
            (unsigned long)w, (unsigned long)ht, (unsigned long)t.pixelFormat, (unsigned long)t.usage,
            nonzero, (unsigned long)(w * ht), 100.0 * nonzero / (double)(w * ht), 100.0 * same / (double)(w * ht), path);
    free(px); free(rgba);
}
/* ml933: every 2D texture the guest allocates is a 2D ARRAY now, and some of
 * them carry real content outside slice 0 (the TSR history lives in slice 3).
 * Dumping slice 0 only was showing an empty buffer for a populated texture, so
 * write one PNG per slice and name the extra ones _sN. */
static void rm_dump_texture(id<MTLCommandQueue> q, id<MTLTexture> t, const char *path, const char *tag) {
    NSUInteger planes = (t.textureType == MTLTextureType3D) ? (t.depth ? t.depth : 1)
                      : (t.textureType == MTLTextureType2DArray ? (t.arrayLength ? t.arrayLength : 1) : 1);
    NSUInteger n = planes > 8 ? 8 : planes;
    NSUInteger step = planes > 8 ? planes / 8 : 1;
    for (NSUInteger i = 0; i < n; i++) {
        NSUInteger s = i * step;
        char p2[256], tag2[96];
        if (s == 0) { snprintf(p2, sizeof p2, "%s", path); snprintf(tag2, sizeof tag2, "%s", tag); }
        else {
            const char *dot = strrchr(path, '.');
            int stem = dot ? (int)(dot - path) : (int)strlen(path);
            snprintf(p2, sizeof p2, "%.*s_s%lu.png", stem, path, (unsigned long)s);
            snprintf(tag2, sizeof tag2, "%s s%lu", tag, (unsigned long)s);
        }
        rm_dump_slice(q, t, p2, tag2, s);
    }
}
static void rm_frame_dump(id<MTLCommandQueue> q) {
    static unsigned dumps;
    char dir[128]; snprintf(dir, sizeof dir, "/tmp/rmetald-dump/f%u", ++dumps);
    char mk[256]; snprintf(mk, sizeof mk, "rm -rf %s && mkdir -p %s", dir, dir); system(mk);   /* ml933: stale PNGs from a previous run read as this frame */
    fprintf(stderr, "[rmetald-dump] frame dump #%u: %u attachments -> %s\n", dumps, g_frame_att_n, dir);
    for (unsigned i = 0; i < g_frame_att_n; i++) {
        uint32_t e = RM_OK; id t = rm_resolve(g_frame_att[i], &e);
        if (e != RM_OK || !t) continue;
        char path[256], tag[64]; snprintf(tag, sizeof tag, "att%02u h=0x%llx", i, (unsigned long long)g_frame_att[i]);
        snprintf(path, sizeof path, "%s/att%02u_%lux%lu_fmt%lu.png", dir, i, (unsigned long)[(id<MTLTexture>)t width],
                 (unsigned long)[(id<MTLTexture>)t height], (unsigned long)[(id<MTLTexture>)t pixelFormat]);
        rm_dump_texture(q, (id<MTLTexture>)t, path, tag);
    }
    /* ml902: everything compute writes (Nanite's visibility buffer, compute-
     * shaded GBuffers, HZB) never appears as an attachment. Walk the handle
     * table for every live 2D texture of screen-ish size that was not already
     * dumped above, so the picture is complete. */
    {
        unsigned n = 0;
        for (uint32_t slot = 0; slot < g_slot_count && n < 400; slot++) {
            if (!g_slots[slot].in_use) continue;
            id o = g_slots[slot].obj;
            if (![o respondsToSelector:@selector(pixelFormat)] || ![o respondsToSelector:@selector(textureType)]) continue;
            id<MTLTexture> t = o;
            int vol = (t.textureType == MTLTextureType3D);
            if (t.textureType != MTLTextureType2D && t.textureType != MTLTextureType2DArray && !vol) continue;   /* ml916: arrays too; ml933: volumes */
            if (!vol && (t.width < 200 || t.height < 100)) continue;
            if (!rm_fmt_bpp(t.pixelFormat) && t.pixelFormat != MTLPixelFormatDepth32Float_Stencil8 && t.pixelFormat != MTLPixelFormatDepth24Unorm_Stencil8) continue;   /* ml903: skip BC/ASTC material textures */
            if (!(t.usage & (MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget))) continue;   /* only things the GPU writes */
            uint64_t h = RM_HANDLE(g_slots[slot].generation, slot);
            int seen = 0; for (unsigned i = 0; i < g_frame_att_n; i++) if (g_frame_att[i] == h) { seen = 1; break; }
            if (seen) continue;
            char path[256], tag[64]; snprintf(tag, sizeof tag, "tex%03u h=0x%llx", n, (unsigned long long)h);
            snprintf(path, sizeof path, "%s/tex%03u_%lux%lu_fmt%lu.png", dir, n, (unsigned long)t.width,
                     (unsigned long)t.height, (unsigned long)t.pixelFormat);
            rm_dump_texture(q, t, path, tag);
            n++;
        }
        fprintf(stderr, "[rmetald-dump] frame dump #%u: %u additional live textures\n", dumps, n);
    }
}

static uint32_t rm_release_handle(uint64_t h) {
    uint32_t err; id obj = rm_resolve(h, &err);
    if (err != RM_OK) return err;
    if (!obj) return RM_OK;
    uint32_t slot = RM_HANDLE_SLOT(h);
    if (g_slots[slot].refs > 1) { g_slots[slot].refs--; return RM_OK; }
    if (rm_enc_closed(g_slots[slot].obj)) {          /* ml898: never let Metal abort on a dangling encoder */
        static unsigned said;
        if (said++ < 20) fprintf(stderr, "[rmetald] ml898 encoder released while still open -- ending it first\n");
        [(id<MTLCommandEncoder>)g_slots[slot].obj endEncoding];
    }
    CFRelease((__bridge CFTypeRef)g_slots[slot].obj);
    g_slots[slot].obj = nil;
    g_slots[slot].in_use = 0;
    g_slots[slot].refs = 0;
    g_slots[slot].generation++;      /* invalidates every outstanding handle */
    g_live--;
    return RM_OK;
}

/* ---- drawable pairing --------------------------------------------------
 *
 * NEXT_DRAWABLE interns TWO handles, and both must die together. Deriving the
 * pairing later -- by trusting the caller's color_texture, or by scanning the
 * table for the texture object -- is wrong on exactly the paths that matter:
 * a malformed stream would release whatever texture the caller named, and a
 * drawable/texture mismatch would release the drawable while stranding its
 * real texture handle. Record the truth at acquisition instead, and route
 * every terminal path through one consume helper. */
#define RM_MAX_DRAWABLES 8
static struct { uint64_t drawable, texture; } g_pairs[RM_MAX_DRAWABLES];

static void rm_pair_record(uint64_t d, uint64_t t) {
    for (int i = 0; i < RM_MAX_DRAWABLES; i++)
        if (!g_pairs[i].drawable) { g_pairs[i].drawable = d; g_pairs[i].texture = t; return; }
    fprintf(stderr, "[rmetald] drawable pair table full -- leaking %llu\n",
            (unsigned long long)d);
}

/* Release a drawable and its texture together. Safe to call on any terminal
 * path, including ones where the drawable was never presented. */
static void rm_consume_drawable(uint64_t d) {
    if (!d) return;
    for (int i = 0; i < RM_MAX_DRAWABLES; i++)
        if (g_pairs[i].drawable == d) {
            rm_release_handle(g_pairs[i].texture);
            g_pairs[i].drawable = g_pairs[i].texture = 0;
            break;
        }
    rm_release_handle(d);
}

/* ---- host window ------------------------------------------------------
 *
 * AppKit owns the main thread; RPC runs on a worker. Every window and layer
 * mutation is bounced to the main queue, because touching either from the
 * socket thread is undefined and fails intermittently rather than loudly.
 */
static NSWindow    *g_window;
static CAMetalLayer *g_layer;
/* Drawable size the guest asked for; 0 until it says. */
static double g_guest_w, g_guest_h;
/* Draw records replayed since the last present. A presented frame with zero
 * draws is a blank frame by definition, which turns "it flickers" into a
 * number instead of a theory. */
static unsigned long g_draws_since_present;
/* Threadgroup size arrives with the compute PSO and applies to the dispatches
 * that follow it, so it is carried rather than re-derived. */
static MTLSize g_compute_tg = {1, 1, 1};
/* Presents, for the title-bar FPS readout. Written by the RPC thread and read
 * by a timer on the main thread, so it is atomic. */
static _Atomic unsigned long long g_present_count;
static _Atomic unsigned long g_gpu_errors, g_gpu_completed;   /* ml819 */

static void host_window_build(id<MTLDevice> dev) {
        NSRect r = NSMakeRect(120, 120, 640, 480);
        g_window = [[NSWindow alloc] initWithContentRect:r
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                       NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
            backing:NSBackingStoreBuffered defer:NO];
        [g_window setTitle:@"Madeira remote Metal"];
        g_layer = [CAMetalLayer layer];
        g_layer.device = dev;
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.framebufferOnly = NO;          /* readback allowed for verification */
        /* Bounded acquisition: a drawable that never arrives must become an
         * ANSWER, not a hung RPC thread. */
        /* Time out rather than block.
         *
         * Blocking here DEADLOCKS the whole guest: this daemon serves a client
         * on one thread, and the client serialises its calls behind one mutex,
         * so an acquire that never returns wedges every winemetal call in that
         * process -- observed as a clean hang with all threads parked and no
         * error anywhere. A timeout costs at worst one blank frame, which is
         * counted below.
         *
         * The flicker this was changed for had a different cause entirely: a
         * per-frame display query returning uninitialised memory. */
        g_layer.allowsNextDrawableTimeout = YES;
        NSView *v = [g_window contentView];
        [v setWantsLayer:YES];
        [v setLayer:g_layer];
        g_layer.frame = v.bounds;
        g_layer.drawableSize = CGSizeMake(v.bounds.size.width, v.bounds.size.height);
        [g_window makeKeyAndOrderFront:nil];
}

/* Safe from either thread: build directly when already on main. */
static void host_window_create(id<MTLDevice> dev) {
    if ([NSThread isMainThread]) host_window_build(dev);
    else dispatch_sync(dispatch_get_main_queue(), ^{ host_window_build(dev); });
}

/* ---- framed IO --------------------------------------------------------- */

static int rd(int fd, void *p, size_t n) {
    uint8_t *b = p;
    while (n) { ssize_t r = read(fd, b, n); if (r <= 0) return -1; b += r; n -= (size_t)r; }
    return 0;
}
static int wr(int fd, const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) { ssize_t r = write(fd, b, n); if (r <= 0) return -1; b += r; n -= (size_t)r; }
    return 0;
}

static int reply(int fd, struct rm_hdr *req, uint32_t status, const void *payload, uint32_t len) {
    struct rm_hdr h = { RM_MAGIC, RM_VERSION, req->opcode, req->seq, status, len, 0 };
    if (wr(fd, &h, sizeof h)) return -1;
    return len ? wr(fd, payload, len) : 0;
}

/* Release every handle this connection interned. Without it the table grows
 * for the lifetime of the daemon and GPU memory is never reclaimed -- a
 * long-lived debugging rig would leak every resource of every past session. */
static void rm_reset_table(void) {
    for (uint32_t i = 0; i < g_slot_count; i++)
        if (g_slots[i].in_use) {
            CFRelease((__bridge CFTypeRef)g_slots[i].obj);
            g_slots[i].obj = nil;
            g_slots[i].in_use = 0;
            g_slots[i].generation++;
        }
    g_live = 0;
    memset(g_pairs, 0, sizeof g_pairs);
}

/* Resource uploads are megabytes, not kilobytes. A fixed 64KB payload buffer
 * silently closed the connection on the first 1MB buffer upload, which the
 * guest saw only as SIGPIPE -- grow on demand instead, with a cap so a bogus
 * length field cannot exhaust host memory. */
#define RM_MAX_PAYLOAD (256u << 20)

/* The guest remaps BC formats it cannot sample. The host GPU supports BC, so
 * the only transform needed here is stripping the swizzle bit -- remapping on
 * this side would undo the point of forwarding to a capable GPU. */
static MTLPixelFormat rm_fmt(enum WMTPixelFormat f) {
    return (MTLPixelFormat)ORIGINAL_FORMAT(f);
}

/* Replay a validated packed batch into an EXISTING encoder.
 *
 * Lifted verbatim from the single-shot submit path so both callers run the same
 * code: the frame path needs Metal state to survive across the twelve batches a
 * frame sends, which a build-and-finish-per-RPC path cannot express. Returns the
 * number of records replayed, or -1 if a record referenced a bad handle. */
static int rm_replay_into(id<MTLRenderCommandEncoder> enc, struct wmtw_view v) {
    uint32_t err = RM_OK;
            uint32_t off = 0, bad = 0, replayed = 0;
            while (off < v.rec_bytes) {
                const struct wmtw_hdr *r = (const void *)(v.rec + off);
                switch (r->op) {
                case WMTW_OP_Nop: break;
                case WMTW_OP_SetPSO: {
                    const struct wmtw_setpso *c = (const void *)r;
                    id o = rm_resolve(c->pso, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setRenderPipelineState:o]; break;
                }
                case WMTW_OP_SetDSSO: {
                    const struct wmtw_setdsso *c = (const void *)r;
                    id o = rm_resolve(c->dsso, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setDepthStencilState:o];
                    [enc setStencilReferenceValue:c->stencil_ref]; break;
                }
                case WMTW_OP_SetVertexBuffer: {
                    const struct wmtw_setvertexbuffer *c = (const void *)r;
                    id o = rm_resolve(c->buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setVertexBuffer:o offset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetVertexBufferOffset: {
                    const struct wmtw_setvertexbufferoffset *c = (const void *)r;
                    [enc setVertexBufferOffset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetMeshBuffer: {
                    const struct wmtw_setmeshbuffer *c = (const void *)r;
                    id o = rm_resolve(c->buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setMeshBuffer:o offset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetMeshBufferOffset: {
                    const struct wmtw_setmeshbufferoffset *c = (const void *)r;
                    [enc setMeshBufferOffset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetObjectBuffer: {
                    const struct wmtw_setobjectbuffer *c = (const void *)r;
                    id o = rm_resolve(c->buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setObjectBuffer:o offset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_DrawMeshThreadgroups: {
                    const struct wmtw_drawmeshthreadgroups *c = (const void *)r;
                    [enc drawMeshThreadgroups:MTLSizeMake(c->grid_w, c->grid_h, c->grid_d)
                  threadsPerObjectThreadgroup:MTLSizeMake(c->obj_w ?: 1, c->obj_h ?: 1, c->obj_d ?: 1)
                    threadsPerMeshThreadgroup:MTLSizeMake(c->mesh_w ?: 1, c->mesh_h ?: 1, c->mesh_d ?: 1)];
                    break;
                }
                case WMTW_OP_SetObjectBufferOffset: {
                    const struct wmtw_setobjectbufferoffset *c = (const void *)r;
                    [enc setObjectBufferOffset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                /* ml817: the three record types a UE4 title needed beyond the cube set. */
                case WMTW_OP_DrawMeshThreadgroupsIndirect: {
                    const struct wmtw_drawmeshthreadgroupsindirect *c = (const void *)r;
                    id ab = rm_resolve(c->indirect_buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc drawMeshThreadgroupsWithIndirectBuffer:ab
                                       indirectBufferOffset:(NSUInteger)c->indirect_offset
                                threadsPerObjectThreadgroup:MTLSizeMake(c->obj_w ?: 1, c->obj_h ?: 1, c->obj_d ?: 1)
                                  threadsPerMeshThreadgroup:MTLSizeMake(c->mesh_w ?: 1, c->mesh_h ?: 1, c->mesh_d ?: 1)];
                    break;
                }
                case WMTW_OP_MemoryBarrier: {
                    const struct wmtw_memorybarrier *c = (const void *)r;
                    [enc memoryBarrierWithScope:(MTLBarrierScope)c->scope
                                    afterStages:(MTLRenderStages)c->stages_after
                                   beforeStages:(MTLRenderStages)c->stages_before];
                    break;
                }
                case WMTW_OP_DrawIndirect: {
                    const struct wmtw_drawindirect *c = (const void *)r;
                    id ab = rm_resolve(c->indirect_buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc drawPrimitives:(MTLPrimitiveType)c->primitive
                         indirectBuffer:ab
                   indirectBufferOffset:(NSUInteger)c->indirect_offset];
                    break;
                }
                case WMTW_OP_SetVisibilityMode: {
                    const struct wmtw_setvisibilitymode *c = (const void *)r;
                    [enc setVisibilityResultMode:(MTLVisibilityResultMode)c->mode
                                          offset:(NSUInteger)c->offset];
                    break;
                }
                case WMTW_OP_DrawIndexedIndirect: {
                    const struct wmtw_drawindexedindirect *c = (const void *)r;
                    id ib = rm_resolve(c->index_buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    id ab = rm_resolve(c->indirect_args_buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc drawIndexedPrimitives:(MTLPrimitiveType)c->primitive_type
                                     indexType:(MTLIndexType)c->index_type
                                   indexBuffer:ib
                             indexBufferOffset:(NSUInteger)c->index_buffer_offset
                                indirectBuffer:ab
                          indirectBufferOffset:(NSUInteger)c->indirect_args_offset];
                    break;
                }
                case WMTW_OP_SetFragmentBufferOffset: {
                    const struct wmtw_setfragmentbufferoffset *c = (const void *)r;
                    [enc setFragmentBufferOffset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetFragmentBuffer: {
                    const struct wmtw_setfragmentbuffer *c = (const void *)r;
                    id o = rm_resolve(c->buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setFragmentBuffer:o offset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetFragmentTexture: {
                    const struct wmtw_setfragmenttexture *c = (const void *)r;
                    id o = rm_resolve(c->texture, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setFragmentTexture:o atIndex:(NSUInteger)c->index]; break;
                }
                case WMTW_OP_SetFragmentBytes: {
                    const struct wmtw_setfragmentbytes *c = (const void *)r;
                    [enc setFragmentBytes:v.side + c->bytes_offset
                                   length:c->bytes_count atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetViewports: {
                    const struct wmtw_setviewports *c = (const void *)r;
                    /* validator proved the range and 8-byte alignment */
                    [enc setViewports:(const MTLViewport *)(v.side + c->viewports_offset)
                                count:c->viewports_count];
                    break;
                }
                case WMTW_OP_SetScissorRects: {
                    const struct wmtw_setscissorrects *c = (const void *)r;
                    [enc setScissorRects:(const MTLScissorRect *)(v.side + c->scissors_offset)
                                   count:c->scissors_count];
                    break;
                }
                case WMTW_OP_SetRasterizerState: {
                    const struct wmtw_setrasterizerstate *c = (const void *)r;
                    [enc setFrontFacingWinding:(MTLWinding)c->front_facing];
                    [enc setCullMode:(MTLCullMode)c->cull_mode];
                    [enc setTriangleFillMode:(MTLTriangleFillMode)c->fill_mode];
                    [enc setDepthClipMode:(MTLDepthClipMode)c->depth_clip_mode];
                    [enc setDepthBias:c->depth_bias slopeScale:c->slope_scale clamp:c->depth_bias_clamp];
                    break;
                }
                case WMTW_OP_SetBlendFactorAndStencilRef: {
                    const struct wmtw_setblendfactorandstencilref *c = (const void *)r;
                    [enc setBlendColorRed:c->r green:c->g blue:c->b alpha:c->a];
                    [enc setStencilReferenceValue:c->stencil_ref]; break;
                }
                case WMTW_OP_UseResource: {
                    const struct wmtw_useresource *c = (const void *)r;
                    id o = rm_resolve(c->resource, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc useResource:o usage:(MTLResourceUsage)c->usage
                              stages:(MTLRenderStages)c->stages]; break;
                }
                case WMTW_OP_Draw: g_draws_since_present++; {
                    const struct wmtw_draw *c = (const void *)r;
                    [enc drawPrimitives:(MTLPrimitiveType)c->primitive
                            vertexStart:(NSUInteger)c->start vertexCount:(NSUInteger)c->count
                          instanceCount:(NSUInteger)(c->instances ?: 1)
                           baseInstance:(NSUInteger)c->base_instance];
                    break;
                }
                case WMTW_OP_DrawIndexed: g_draws_since_present++; {
                    const struct wmtw_drawindexed *c = (const void *)r;
                    id ib = rm_resolve(c->index_buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc drawIndexedPrimitives:(MTLPrimitiveType)c->primitive
                                    indexCount:(NSUInteger)c->index_count
                                     indexType:(MTLIndexType)c->index_type
                                   indexBuffer:ib
                             indexBufferOffset:(NSUInteger)c->index_offset
                                 instanceCount:(NSUInteger)(c->instances ?: 1)
                                    baseVertex:(NSInteger)c->base_vertex
                                  baseInstance:(NSUInteger)c->base_instance];
                    break;
                }
                default:
                    fprintf(stderr, "[rmetald] replay: opcode %u validated but not "
                            "implemented, at record %u\n", r->op, replayed);
                    bad = 1; break;
                }
                if (bad) break;
                off += r->size; replayed++;
            }
    return bad ? -1 : (int)replayed;
}

/* Title-bar FPS, computed the SAME way as the guest's overlay so the two
 * readouts can be compared directly rather than argued about:
 *
 *   - sample the present counter every 100ms into a 5s ring (50 entries)
 *   - every 250ms, walk back from the newest sample until the window holds
 *     >=3 presents AND spans >=1s, then fps = presents / seconds
 *
 * The >=1s minimum is load bearing. With 100ms sampling a short window
 * quantises the readout to multiples of 5 -- a true ~19 FPS reads as a rock
 * steady "20.0" with dips to 15.0, which looks like a frame lock that is not
 * there. One second gives 1-FPS resolution and is still responsive. */
#define RM_FPS_SAMPLES 50

static void rm_start_fps_title(void) {
    static double t_ring[RM_FPS_SAMPLES];
    static unsigned long long c_ring[RM_FPS_SAMPLES];
    static unsigned n_ring;                 /* total samples ever taken */
    __block double last_shown = -1.0;

    /* STATIC: under ARC a local dispatch_source_t is released when this
     * function returns, which cancels the timer before it ever fires -- the
     * title simply never changed. */
    static dispatch_source_t sampler;
    sampler =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(sampler, DISPATCH_TIME_NOW, 100ull * NSEC_PER_MSEC, 10ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(sampler, ^{
        unsigned idx = n_ring % RM_FPS_SAMPLES;
        t_ring[idx] = CFAbsoluteTimeGetCurrent();
        c_ring[idx] = atomic_load(&g_present_count);
        n_ring++;
    });
    dispatch_resume(sampler);

    static dispatch_source_t shower;
    shower =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(shower, DISPATCH_TIME_NOW, 250ull * NSEC_PER_MSEC, 25ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(shower, ^{
        if (n_ring < 2) return;
        unsigned have = n_ring < RM_FPS_SAMPLES ? n_ring : RM_FPS_SAMPLES;
        unsigned newest = (n_ring - 1) % RM_FPS_SAMPLES;
        double   lt = t_ring[newest];
        unsigned long long lc = c_ring[newest];

        /* Walk backwards to the oldest sample, stopping early once the window
         * is both long enough and busy enough. */
        unsigned chosen = (n_ring - have) % RM_FPS_SAMPLES;
        for (unsigned k = 1; k < have; k++) {
            unsigned i = (n_ring - 1 - k) % RM_FPS_SAMPLES;
            chosen = i;
            if ((lc - c_ring[i]) >= 3 && (lt - t_ring[i]) >= 1.0) break;
        }
        double dt = lt - t_ring[chosen];
        unsigned long long dc = lc - c_ring[chosen];
        double fps = dt > 0.0001 ? (double)dc / dt : 0.0;

        if (last_shown >= 0 && fabs(fps - last_shown) < 0.05) return;   /* avoid needless title churn */
        last_shown = fps;
        [g_window setTitle:[NSString stringWithFormat:@"Madeira remote Metal  -  %.1f FPS  -  %llu frames",
                            fps, (unsigned long long)lc]];
    });
    dispatch_resume(shower);
}

static void serve(int fd) {
    uint8_t *payload = NULL;
    uint32_t payload_cap = 0;
    for (;;) {
        struct rm_hdr h;
        if (rd(fd, &h, sizeof h)) break;
        if (h.magic != RM_MAGIC)   { reply(fd, &h, RM_ERR_BAD_MAGIC, NULL, 0); break; }
        if (h.version != RM_VERSION) { reply(fd, &h, RM_ERR_BAD_VERSION, NULL, 0); break; }
        if (h.payload_len > RM_MAX_PAYLOAD) {
            fprintf(stderr, "[rmetald] payload %u exceeds cap\n", h.payload_len);
            reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
        }
        if (h.payload_len > payload_cap) {
            uint8_t *np = realloc(payload, h.payload_len);
            if (!np) { reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break; }
            payload = np; payload_cap = h.payload_len;
        }
        if (h.payload_len && rd(fd, payload, h.payload_len)) break;

        @autoreleasepool {
        uint32_t err = RM_OK;
        /* A malformed or half-switched guest must not be able to kill the
         * daemon. A wrong-class handle raises an ObjC exception the moment a
         * selector is sent, and an uncaught one terminates the process -- the
         * whole host GPU service, for every client. Sending the wrong selector
         * is still a bug worth seeing, so it is reported and named rather than
         * silently swallowed. */
        @try {
        switch (h.opcode) {
        case RM_OP_PING:
            reply(fd, &h, RM_OK, NULL, 0); break;

        case RM_OP_COPY_ALL_DEVICES: {
            id dev = MTLCreateSystemDefaultDevice();
            NSArray *arr = dev ? @[dev] : @[];
            struct rm_ret_handle r = { rm_intern(arr) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_ARRAY_COUNT: {
            if (h.payload_len < sizeof(struct rm_arg_handle)) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            if (![o isKindOfClass:[NSArray class]]) { reply(fd,&h,RM_ERR_WRONG_CLASS,NULL,0); break; }
            struct rm_ret_u64 r = { [(NSArray *)o count] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_ARRAY_OBJECT: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            if (![o isKindOfClass:[NSArray class]]) { reply(fd,&h,RM_ERR_WRONG_CLASS,NULL,0); break; }
            NSArray *arr = o;
            if (a->arg >= arr.count) { reply(fd,&h,RM_ERR_BAD_HANDLE,NULL,0); break; }
            struct rm_ret_handle r = { rm_intern(arr[(NSUInteger)a->arg]) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_DEVICE_NAME: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const char *n = [[(id<MTLDevice>)o name] UTF8String] ?: "";
            reply(fd, &h, RM_OK, n, (uint32_t)strlen(n)); break;
        }
        case RM_OP_SUPPORTS_FAMILY: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLDevice>)o supportsFamily:(MTLGPUFamily)a->arg] ? 1 : 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_SUPPORTS_BC: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLDevice>)o supportsBCTextureCompression] ? 1 : 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_ALLOCATED_SIZE: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLDevice>)o currentAllocatedSize] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_RETAIN: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            (void)o;
            struct rm_ret_handle r = { rm_retain_handle(((struct rm_arg_handle *)payload)->handle, &err) };
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_RELEASE:
            reply(fd, &h, rm_release_handle(((struct rm_arg_handle *)payload)->handle), NULL, 0); break;

        /* ml821: many releases in one round trip. Same per-handle semantics as
         * RM_OP_RELEASE, applied in order; the first failure is reported and the
         * rest still run, because a stale handle in a pool drain must not strand
         * the objects behind it. */
        case RM_OP_RELEASE_MULTI: {
            const uint64_t *hs; uint32_t st = RM_OK;
            if (!rm_release_multi_ok(payload, h.payload_len, &hs)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            uint32_t n = ((const struct rm_release_multi *)payload)->count;
            for (uint32_t i = 0; i < n; i++) {
                uint32_t e = rm_release_handle(hs[i]);
                if (e != RM_OK && st == RM_OK) st = e;
            }
            reply(fd, &h, st, NULL, 0); break;
        }
        /* ml821: many buffer ranges in one round trip. Every range is resolved
         * and bounds-checked exactly as the single form does, and one bad range
         * fails the message rather than being skipped silently. */
        case RM_OP_BUFFER_UPLOAD_MULTI: {
            const struct rm_buffer_range *r; const uint8_t *data;
            if (!rm_multi_ok(payload, h.payload_len, &r, &data)) {
                fprintf(stderr, "[rmetald] malformed coalesced upload (%u bytes)\n", h.payload_len);
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            uint32_t n = ((const struct rm_buffer_multi *)payload)->count;
            uint32_t st = RM_OK; uint64_t at = 0;
            for (uint32_t i = 0; i < n; i++) {
                id o = rm_resolve(r[i].handle, &err);
                if (err != RM_OK) { st = err; break; }
                id<MTLBuffer> b = o;
                if ((uint64_t)r[i].offset + r[i].length > (uint64_t)b.length) {
                    fprintf(stderr, "[rmetald] coalesced upload out of range: off %llu len %llu "
                                    "into %llu\n", (unsigned long long)r[i].offset,
                            (unsigned long long)r[i].length, (unsigned long long)b.length);
                    st = RM_ERR_SHORT_PAYLOAD; break;
                }
                memcpy((uint8_t *)b.contents + r[i].offset, data + at, (size_t)r[i].length);
                at += r[i].length;
            }
            reply(fd, &h, st, NULL, 0); break;
        }

        case RM_OP_STATS: {
            struct rm_ret_u64 r = { g_live };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_COMMAND_QUEUE: {
            /* The guest's max-command-buffer-count is load bearing: it bounds how
             * many command buffers may be in flight, and silently substituting
             * Metal's default changes when the guest blocks. */
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLCommandQueue> q = a->arg
                ? [(id<MTLDevice>)o newCommandQueueWithMaxCommandBufferCount:(NSUInteger)a->arg]
                : [(id<MTLDevice>)o newCommandQueue];
            struct rm_ret_handle r = { rm_intern(q) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_BUFFER: {
            struct rm_new_buffer *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->device, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            uint32_t inline_len = h.payload_len - (uint32_t)sizeof *a;
            if (inline_len && a->length != inline_len) {   /* declared vs delivered */
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            const void *init = inline_len ? payload + sizeof *a : NULL;
            id<MTLBuffer> b = init
                ? [(id<MTLDevice>)o newBufferWithBytes:init length:a->length options:MTLResourceStorageModeShared]
                : [(id<MTLDevice>)o newBufferWithLength:a->length options:MTLResourceStorageModeShared];
            struct rm_ret_handle r = { rm_intern(b) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_TEXTURE: {
            struct rm_new_texture *a = (void *)payload;
            id o = rm_resolve(a->device, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            MTLTextureDescriptor *d = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:(MTLPixelFormat)a->pixel_format
                width:(NSUInteger)a->width height:(NSUInteger)a->height mipmapped:NO];
            d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            d.storageMode = MTLStorageModeShared;
            struct rm_ret_handle r = { rm_intern([(id<MTLDevice>)o newTextureWithDescriptor:d]) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_LIBRARY: {
            struct rm_arg_handle *a = (void *)payload;
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            NSString *src = [[NSString alloc] initWithBytes:payload + sizeof *a
                             length:h.payload_len - sizeof *a encoding:NSUTF8StringEncoding];
            NSError *e = nil;
            id<MTLLibrary> lib = [(id<MTLDevice>)o newLibraryWithSource:src options:nil error:&e];
            if (!lib) { /* surface the compiler diagnostic; a silent nil is useless */
                const char *m = [[e localizedDescription] UTF8String] ?: "shader compile failed";
                fprintf(stderr, "[rmetald] library: %s\n", m);
                reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break;
            }
            struct rm_ret_handle r = { rm_intern(lib) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_FUNCTION: {
            struct rm_arg_handle *a = (void *)payload;
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            NSString *n = [[NSString alloc] initWithBytes:payload + sizeof *a
                           length:h.payload_len - sizeof *a encoding:NSUTF8StringEncoding];
            struct rm_ret_handle r = { rm_intern([(id<MTLLibrary>)o newFunctionWithName:n]) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_RENDER_PIPELINE: {
            struct rm_new_pipeline *a = (void *)payload;
            id dev = rm_resolve(a->device, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id vfn = rm_resolve(a->vfn, &err);    if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id ffn = rm_resolve(a->ffn, &err);    if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = vfn; d.fragmentFunction = ffn;
            d.colorAttachments[0].pixelFormat = (MTLPixelFormat)a->pixel_format;
            NSError *e = nil;
            id ps = [(id<MTLDevice>)dev newRenderPipelineStateWithDescriptor:d error:&e];
            if (!ps) { fprintf(stderr, "[rmetald] pipeline: %s\n",
                               [[e localizedDescription] UTF8String] ?: "?");
                       reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break; }
            struct rm_ret_handle r = { rm_intern(ps) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_SUBMIT_RENDER_PASS: {
            struct rm_render_pass *a = (void *)payload;
            /* A producer that forgets to zero present_drawable would send
             * stack garbage here, and resolving it silently fails the whole
             * pass with a confusing STALE_HANDLE. Validate it as a handle only
             * when non-zero, and say which field was wrong. */
            /* Two different failures, and only one of them can give the
             * drawable back. If the frame is too short to even contain the
             * struct, present_drawable cannot be READ -- reading it would be
             * an out-of-bounds access on attacker-controlled input -- so the
             * drawable is stranded and the guest must recover it with
             * RM_OP_DISCARD_DRAWABLE. If the struct is present but cmd_bytes
             * is wrong, the handle is readable and must be consumed. */
            if (h.payload_len < sizeof *a) {
                fprintf(stderr, "[rmetald] render pass frame too short (%u < %zu); "
                        "any acquired drawable must be returned with DISCARD_DRAWABLE\n",
                        h.payload_len, sizeof *a);
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break;
            }
            if (a->cmd_bytes > h.payload_len - sizeof *a) {   /* stream must fit the frame */
                rm_consume_drawable(a->present_drawable);
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break;
            }
            /* From here on, any early return must give the drawable back. */
            id q = rm_resolve(a->queue, &err);
            if (err != RM_OK) { rm_consume_drawable(a->present_drawable);
                                reply(fd,&h,err,NULL,0); break; }
            id tex = rm_resolve(a->color_texture, &err);
            if (err != RM_OK) { rm_consume_drawable(a->present_drawable);
                                reply(fd,&h,err,NULL,0); break; }
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = tex;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(a->clear_r, a->clear_g, a->clear_b, a->clear_a);
            id<MTLCommandBuffer> cb = [(id<MTLCommandQueue>)q commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

            /* Walk the CONTIGUOUS stream by size, never by pointer. */
            const uint8_t *p = payload + sizeof *a;
            uint32_t off = 0, bad = 0;
            while (off + sizeof(struct rm_enc_hdr) <= a->cmd_bytes) {
                const struct rm_enc_hdr *rec = (const void *)(p + off);
                if (rec->size < sizeof *rec || off + rec->size > a->cmd_bytes) { bad = 1; break; }
                /* Every record must be at least its own struct size. Without
                 * this a short record would be read past its end -- the
                 * command stream is attacker-controlled input. */
                {
                    uint32_t need = 0;
                    switch (rec->type) {
                    case RM_ENC_SET_PIPELINE:     need = sizeof(struct rm_enc_pipeline); break;
                    case RM_ENC_SET_VERTEX_BUFFER:need = sizeof(struct rm_enc_vbuf);     break;
                    case RM_ENC_SET_VIEWPORT:     need = sizeof(struct rm_enc_viewport); break;
                    case RM_ENC_DRAW:             need = sizeof(struct rm_enc_draw);     break;
                    default: need = 0xffffffff; break;
                    }
                    if (rec->size < need) { bad = 1; break; }
                }
                switch (rec->type) {
                case RM_ENC_SET_PIPELINE: {
                    const struct rm_enc_pipeline *c = (const void *)rec;
                    id ps = rm_resolve(c->pipeline, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setRenderPipelineState:ps]; break;
                }
                case RM_ENC_SET_VERTEX_BUFFER: {
                    const struct rm_enc_vbuf *c = (const void *)rec;
                    id b = rm_resolve(c->buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setVertexBuffer:b offset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index]; break;
                }
                case RM_ENC_SET_VIEWPORT: {
                    const struct rm_enc_viewport *c = (const void *)rec;
                    [enc setViewport:(MTLViewport){c->x, c->y, c->w, c->h_, c->znear, c->zfar}]; break;
                }
                case RM_ENC_DRAW: {
                    const struct rm_enc_draw *c = (const void *)rec;
                    [enc drawPrimitives:(MTLPrimitiveType)c->primitive
                            vertexStart:(NSUInteger)c->start vertexCount:(NSUInteger)c->count]; break;
                }
                default: bad = 1; break;
                }
                if (bad) break;
                off += rec->size;
            }
            [enc endEncoding];
            if (bad) {
                /* A malformed command stream must not strand the drawable: it
                 * is single-use, and leaking one per failed frame exhausts the
                 * pool and then blocks acquisition forever. */
                rm_consume_drawable(a->present_drawable);
                reply(fd, &h, err ? err : RM_ERR_BAD_OPCODE, NULL, 0); break;
            }
            /* Present on THIS command buffer, before commit -- Metal's
             * intended sequencing. Presenting from a separate call after this
             * buffer had committed would race the display. */
            if (a->present_drawable) {
                id d = rm_resolve(a->present_drawable, &err);
                /* The pass must render into THIS drawable's texture. Presenting
                 * a drawable whose texture was never drawn shows a stale or
                 * blank frame, which looks like a renderer bug rather than a
                 * protocol misuse. */
                if (err != RM_OK) { rm_consume_drawable(a->present_drawable);
                                    reply(fd,&h,err,NULL,0); break; }
                if (d && tex != [(id<CAMetalDrawable>)d texture]) {
                    fprintf(stderr, "[rmetald] color_texture is not the drawable's texture\n");
                    rm_consume_drawable(a->present_drawable);
                    reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break;
                }
                if (err != RM_OK) {
                    fprintf(stderr, "[rmetald] present_drawable=%llu invalid (%u) -- "
                            "an uninitialised field in the caller's render pass?\n",
                            (unsigned long long)a->present_drawable, err);
                    reply(fd,&h,err,NULL,0); break;
                }
                [cb presentDrawable:(id<CAMetalDrawable>)d];
            }
            [cb commit];
            [cb waitUntilCompleted];   /* synchronous by design */
            /* Consume the drawable AND its texture. A drawable is single-use,
             * and NEXT_DRAWABLE interns two handles for it -- releasing only
             * the drawable leaked one texture handle per frame, which a 600
             * frame run made obvious (611 live handles). The texture belongs
             * to the drawable, so its handle dies with it. */
            rm_consume_drawable(a->present_drawable);
            struct rm_ret_u64 r = { (uint64_t)[cb status] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_LAYER_SIZE: {
            __block CGSize sz = CGSizeZero;
            dispatch_sync(dispatch_get_main_queue(), ^{ sz = g_layer.drawableSize; });
            struct rm_ret_drawable r = { 0, 0, (uint64_t)sz.width, (uint64_t)sz.height };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEXT_DRAWABLE: {
            __block CGSize sz = CGSizeZero;
            /* Only the window/layer MUTATION belongs on main. nextDrawable can
             * block -- on the drawable pool, or indefinitely while the window
             * is minimised -- and blocking the main queue there would freeze
             * AppKit event processing, so the user could not even restore the
             * window that is causing the block. Acquire on this thread. */
            dispatch_sync(dispatch_get_main_queue(), ^{
                NSView *v = [g_window contentView];
                /* Only on change. Assigning .frame every acquisition commits a
                 * CoreAnimation layout transaction per frame, which can recycle
                 * the drawable pool underneath frames already in flight. */
                if (!CGRectEqualToRect(g_layer.frame, v.bounds))
                    g_layer.frame = v.bounds;
                /* Honour a size the guest asked for. Overwriting it with the window
                 * backing size on every acquisition left the guest drawing into the
                 * top-left corner of a larger drawable -- the black padding. */
                CGSize want;
                if (g_guest_w > 0 && g_guest_h > 0) {
                    want = CGSizeMake(g_guest_w, g_guest_h);
                } else {
                    CGFloat s = g_window.backingScaleFactor ?: 1.0;
                    want = CGSizeMake(v.bounds.size.width * s, v.bounds.size.height * s);
                }
                if (!CGSizeEqualToSize(want, g_layer.drawableSize) && want.width > 0)
                    g_layer.drawableSize = want;
                sz = g_layer.drawableSize;
            });
            id<CAMetalDrawable> d = [g_layer nextDrawable];
            if (!d) {
                static unsigned long missed;
                if (++missed <= 4 || (missed % 256) == 0)
                    fprintf(stderr, "[rmetald] nextDrawable returned nil (%lu times) -- the "
                                    "guest will present an undrawn frame\n", missed);
                reply(fd, &h, RM_ERR_NO_DRAWABLE, NULL, 0); break;
            }
            uint64_t dh = rm_intern(d), th = rm_intern(d.texture);
            rm_pair_record(dh, th);
            struct rm_ret_drawable r = { dh, th, (uint64_t)sz.width, (uint64_t)sz.height };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_DISCARD_DRAWABLE: {
            /* Acquired but never submitted. Without this the guest has no way
             * to give a drawable back, and the single-use pool drains. */
            rm_consume_drawable(((struct rm_arg_handle *)payload)->handle);
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_DISPATCH_DATA: {
            /* The blob arrives inline. dispatch_data_create with
             * DISPATCH_DATA_DESTRUCTOR_DEFAULT copies, so the payload buffer
             * may be reused the moment this returns. */
            if (h.payload_len == 0) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            dispatch_data_t dd = dispatch_data_create(payload, h.payload_len,
                                    dispatch_get_global_queue(0, 0),
                                    DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            struct rm_ret_handle r = { rm_intern((id)dd) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_LIBRARY_DATA: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->handle, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id dat = rm_resolve(a->arg, &err);    if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            NSError *e = nil;
            id<MTLLibrary> lib = [(id<MTLDevice>)dev newLibraryWithData:(dispatch_data_t)dat error:&e];
            if (!lib) {
                fprintf(stderr, "[rmetald] newLibraryWithData: %s\n",
                        [[e localizedDescription] UTF8String] ?: "?");
                reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break;
            }
            struct rm_ret_handle r = { rm_intern(lib) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_COMPUTE_PSO: {
            /* DXMT supplies a full WMTComputePipelineInfo, not just a function:
             * immutable-buffer flags, a serialization archive, and a GUEST
             * POINTER to an array of lookup archives. The pointer cannot cross,
             * so the archives travel as a sidecar of handles. */
            struct rm_compute_pso *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            uint32_t need = (uint32_t)a->num_archives * (uint32_t)sizeof(uint64_t);
            if (a->num_archives > 32 || h.payload_len - sizeof *a < need) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break;
            }
            id dev = rm_resolve(a->device, &err);   if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id fn  = rm_resolve(a->function, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }

            MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];
            d.computeFunction = fn;
            d.threadGroupSizeIsMultipleOfThreadExecutionWidth = a->tgsize_multiple_of_sgwidth != 0;
            for (unsigned i = 0; i < 32; i++)
                if (a->immutable_buffers & (1u << i))
                    d.buffers[i].mutability = MTLMutabilityImmutable;
            /* Lookup archives resolve through the handle table like anything
             * else; a stale one must fail rather than be skipped silently. */
            if (a->num_archives) {
                const uint64_t *hs = (const uint64_t *)(payload + sizeof *a);
                NSMutableArray *arr = [NSMutableArray array];
                for (unsigned i = 0; i < a->num_archives; i++) {
                    id ar = rm_resolve(hs[i], &err);
                    if (err != RM_OK) break;
                    if (ar) [arr addObject:ar];
                }
                if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
                if (arr.count) d.binaryArchives = arr;
            }
            NSError *e = nil;
            MTLComputePipelineReflection *refl = nil;
            id ps = [(id<MTLDevice>)dev newComputePipelineStateWithDescriptor:d
                        options:MTLPipelineOptionNone reflection:&refl error:&e];
            if (!ps) {
                fprintf(stderr, "[rmetald] compute PSO: %s\n",
                        [[e localizedDescription] UTF8String] ?: "?");
                reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break;
            }
            struct rm_ret_handle r = { rm_intern(ps) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_DEPTH_STENCIL: {
            struct rm_dss_desc *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->device, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
            d.depthCompareFunction = (MTLCompareFunction)a->depth_compare_function;
            d.depthWriteEnabled = a->depth_write_enabled != 0;
            #define STENCIL(dst, src) do { \
                if ((src).enabled) { \
                    MTLStencilDescriptor *sd = [MTLStencilDescriptor new]; \
                    sd.depthStencilPassOperation = (MTLStencilOperation)(src).depth_stencil_pass_op; \
                    sd.stencilFailureOperation   = (MTLStencilOperation)(src).stencil_fail_op; \
                    sd.depthFailureOperation     = (MTLStencilOperation)(src).depth_fail_op; \
                    sd.stencilCompareFunction    = (MTLCompareFunction)(src).compare_function; \
                    sd.writeMask = (src).write_mask; sd.readMask = (src).read_mask; \
                    dst = sd; \
                } } while (0)
            STENCIL(d.frontFaceStencil, a->front);
            STENCIL(d.backFaceStencil,  a->back);
            #undef STENCIL
            id dss = [(id<MTLDevice>)dev newDepthStencilStateWithDescriptor:d];
            if (!dss) { reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break; }
            struct rm_ret_resource r = { rm_intern(dss), 0, 0, 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_SAMPLER: {
            struct rm_sampler_desc *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->device, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
            d.minFilter = (MTLSamplerMinMagFilter)a->min_filter;
            d.magFilter = (MTLSamplerMinMagFilter)a->mag_filter;
            d.mipFilter = (MTLSamplerMipFilter)a->mip_filter;
            d.rAddressMode = (MTLSamplerAddressMode)a->r_address;
            d.sAddressMode = (MTLSamplerAddressMode)a->s_address;
            d.tAddressMode = (MTLSamplerAddressMode)a->t_address;
            d.borderColor = (MTLSamplerBorderColor)a->border_color;
            d.compareFunction = (MTLCompareFunction)a->compare_function;
            d.lodMinClamp = a->lod_min_clamp; d.lodMaxClamp = a->lod_max_clamp;
            d.maxAnisotropy = a->max_anisotropy ? a->max_anisotropy : 1;
            d.normalizedCoordinates = a->normalized_coords != 0;
            d.lodAverage = a->lod_average != 0;
            d.supportArgumentBuffers = a->support_argument_buffers != 0;
            id<MTLSamplerState> ss = [(id<MTLDevice>)dev newSamplerStateWithDescriptor:d];
            if (!ss) { reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break; }
            /* gpu_resource_id is an OUT field the caller reads. */
            struct rm_ret_resource r = { rm_intern(ss),
                a->support_argument_buffers ? ss.gpuResourceID._impl : 0, 0, 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_TEXTURE_INFO: {
            struct rm_texture_desc *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->device, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            MTLTextureDescriptor *d = [MTLTextureDescriptor new];
            d.pixelFormat = (MTLPixelFormat)a->pixel_format;
            d.width = a->width; d.height = a->height; d.depth = a->depth;
            d.arrayLength = a->array_length ? a->array_length : 1;
            d.textureType = (MTLTextureType)a->type;
            d.mipmapLevelCount = a->mipmap_level_count ? a->mipmap_level_count : 1;
            d.sampleCount = a->sample_count ? a->sample_count : 1;
            d.usage = (MTLTextureUsage)a->usage;
            d.storageMode = MTLStorageModeShared;
            id<MTLTexture> t = [(id<MTLDevice>)dev newTextureWithDescriptor:d];
            if (!t) { reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break; }
            /* mach_port stays 0: a port name cannot cross machines. */
            struct rm_ret_resource r = { rm_intern(t), t.gpuResourceID._impl, 0, 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_BUFFER_CREATE: {
            struct rm_buffer_create *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->device, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            /* Created empty; contents arrive as ranges. Shared storage so the
             * host can write into it without a staging round trip. */
            id<MTLBuffer> b = [(id<MTLDevice>)dev newBufferWithLength:(NSUInteger)a->length
                                  options:MTLResourceStorageModeShared];
            if (!b) { reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break; }
            struct rm_ret_resource r = { rm_intern(b), b.gpuAddress, 0, 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_BUFFER_WRITE: {
            struct rm_buffer_range *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLBuffer> b = o;
            uint32_t inlined = h.payload_len - (uint32_t)sizeof *a;
            /* Every bound checked in 64-bit against the REAL buffer length.
             * offset+length in 32-bit could wrap and write outside it. */
            if (a->length != inlined ||
                a->length > RM_CHUNK_BYTES ||
                (uint64_t)a->offset + a->length > (uint64_t)b.length) {
                fprintf(stderr, "[rmetald] buffer write out of range: off=%llu len=%llu inline=%u buf=%lu\n",
                        (unsigned long long)a->offset, (unsigned long long)a->length,
                        inlined, (unsigned long)b.length);
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            memcpy((uint8_t *)b.contents + a->offset, payload + sizeof *a, a->length);
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_BUFFER_READ: {
            struct rm_buffer_range *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLBuffer> b = o;
            if (a->length > RM_CHUNK_BYTES ||
                (uint64_t)a->offset + a->length > (uint64_t)b.length) {
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            reply(fd, &h, RM_OK, (const uint8_t *)b.contents + a->offset, (uint32_t)a->length);
            break;
        }
        case RM_OP_SUBMIT_WMT_BATCH: {
            struct rm_wmt_submit *a = (void *)payload;
            if (h.payload_len < sizeof *a ||
                a->batch_bytes > h.payload_len - sizeof *a) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break;
            }
            id q = rm_resolve(a->queue, &err);
            if (err != RM_OK) { rm_consume_drawable(a->present_drawable);
                                reply(fd,&h,err,NULL,0); break; }
            id tex = rm_resolve(a->color_texture, &err);
            if (err != RM_OK) { rm_consume_drawable(a->present_drawable);
                                reply(fd,&h,err,NULL,0); break; }

            /* VALIDATE BEFORE REPLAY. The batch is untrusted input, and the
             * validator is the same function the test suites exercise -- a
             * second walker here would prove nothing about either. */
            struct wmtw_view v; struct wmtw_dec_result dr;
            if (wmtw_validate_batch(payload + sizeof *a, a->batch_bytes, &v, &dr) != WMTW_DEC_OK) {
                fprintf(stderr, "[rmetald] batch rejected: %s at record %u (opcode %u)\n",
                        wmtw_dec_strerror(dr.status), dr.record_index, dr.opcode);
                rm_consume_drawable(a->present_drawable);
                reply(fd, &h, RM_ERR_BAD_OPCODE, NULL, 0); break;
            }

            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = tex;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor =
                MTLClearColorMake(a->clear_r, a->clear_g, a->clear_b, a->clear_a);
            id<MTLCommandBuffer> cb = [(id<MTLCommandQueue>)q commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

            uint32_t off = 0, bad = 0, replayed = 0;
            while (off < v.rec_bytes) {
                const struct wmtw_hdr *r = (const void *)(v.rec + off);
                switch (r->op) {
                case WMTW_OP_Nop: break;
                case WMTW_OP_SetPSO: {
                    const struct wmtw_setpso *c = (const void *)r;
                    id o = rm_resolve(c->pso, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setRenderPipelineState:o]; break;
                }
                case WMTW_OP_SetDSSO: {
                    const struct wmtw_setdsso *c = (const void *)r;
                    id o = rm_resolve(c->dsso, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setDepthStencilState:o];
                    [enc setStencilReferenceValue:c->stencil_ref]; break;
                }
                case WMTW_OP_SetVertexBuffer: {
                    const struct wmtw_setvertexbuffer *c = (const void *)r;
                    id o = rm_resolve(c->buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setVertexBuffer:o offset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetVertexBufferOffset: {
                    const struct wmtw_setvertexbufferoffset *c = (const void *)r;
                    [enc setVertexBufferOffset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetMeshBuffer: {
                    const struct wmtw_setmeshbuffer *c = (const void *)r;
                    id o = rm_resolve(c->buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setMeshBuffer:o offset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetMeshBufferOffset: {
                    const struct wmtw_setmeshbufferoffset *c = (const void *)r;
                    [enc setMeshBufferOffset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetObjectBuffer: {
                    const struct wmtw_setobjectbuffer *c = (const void *)r;
                    id o = rm_resolve(c->buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setObjectBuffer:o offset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_DrawMeshThreadgroups: {
                    const struct wmtw_drawmeshthreadgroups *c = (const void *)r;
                    [enc drawMeshThreadgroups:MTLSizeMake(c->grid_w, c->grid_h, c->grid_d)
                  threadsPerObjectThreadgroup:MTLSizeMake(c->obj_w ?: 1, c->obj_h ?: 1, c->obj_d ?: 1)
                    threadsPerMeshThreadgroup:MTLSizeMake(c->mesh_w ?: 1, c->mesh_h ?: 1, c->mesh_d ?: 1)];
                    break;
                }
                case WMTW_OP_SetObjectBufferOffset: {
                    const struct wmtw_setobjectbufferoffset *c = (const void *)r;
                    [enc setObjectBufferOffset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                /* ml817: the three record types a UE4 title needed beyond the cube set. */
                case WMTW_OP_DrawMeshThreadgroupsIndirect: {
                    const struct wmtw_drawmeshthreadgroupsindirect *c = (const void *)r;
                    id ab = rm_resolve(c->indirect_buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc drawMeshThreadgroupsWithIndirectBuffer:ab
                                       indirectBufferOffset:(NSUInteger)c->indirect_offset
                                threadsPerObjectThreadgroup:MTLSizeMake(c->obj_w ?: 1, c->obj_h ?: 1, c->obj_d ?: 1)
                                  threadsPerMeshThreadgroup:MTLSizeMake(c->mesh_w ?: 1, c->mesh_h ?: 1, c->mesh_d ?: 1)];
                    break;
                }
                case WMTW_OP_MemoryBarrier: {
                    const struct wmtw_memorybarrier *c = (const void *)r;
                    [enc memoryBarrierWithScope:(MTLBarrierScope)c->scope
                                    afterStages:(MTLRenderStages)c->stages_after
                                   beforeStages:(MTLRenderStages)c->stages_before];
                    break;
                }
                case WMTW_OP_DrawIndirect: {
                    const struct wmtw_drawindirect *c = (const void *)r;
                    id ab = rm_resolve(c->indirect_buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc drawPrimitives:(MTLPrimitiveType)c->primitive
                         indirectBuffer:ab
                   indirectBufferOffset:(NSUInteger)c->indirect_offset];
                    break;
                }
                case WMTW_OP_SetVisibilityMode: {
                    const struct wmtw_setvisibilitymode *c = (const void *)r;
                    [enc setVisibilityResultMode:(MTLVisibilityResultMode)c->mode
                                          offset:(NSUInteger)c->offset];
                    break;
                }
                case WMTW_OP_DrawIndexedIndirect: {
                    const struct wmtw_drawindexedindirect *c = (const void *)r;
                    id ib = rm_resolve(c->index_buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    id ab = rm_resolve(c->indirect_args_buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc drawIndexedPrimitives:(MTLPrimitiveType)c->primitive_type
                                     indexType:(MTLIndexType)c->index_type
                                   indexBuffer:ib
                             indexBufferOffset:(NSUInteger)c->index_buffer_offset
                                indirectBuffer:ab
                          indirectBufferOffset:(NSUInteger)c->indirect_args_offset];
                    break;
                }
                case WMTW_OP_SetFragmentBufferOffset: {
                    const struct wmtw_setfragmentbufferoffset *c = (const void *)r;
                    [enc setFragmentBufferOffset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetFragmentBuffer: {
                    const struct wmtw_setfragmentbuffer *c = (const void *)r;
                    id o = rm_resolve(c->buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setFragmentBuffer:o offset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetFragmentTexture: {
                    const struct wmtw_setfragmenttexture *c = (const void *)r;
                    id o = rm_resolve(c->texture, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setFragmentTexture:o atIndex:(NSUInteger)c->index]; break;
                }
                case WMTW_OP_SetFragmentBytes: {
                    const struct wmtw_setfragmentbytes *c = (const void *)r;
                    [enc setFragmentBytes:v.side + c->bytes_offset
                                   length:c->bytes_count atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetViewports: {
                    const struct wmtw_setviewports *c = (const void *)r;
                    /* validator proved the range and 8-byte alignment */
                    [enc setViewports:(const MTLViewport *)(v.side + c->viewports_offset)
                                count:c->viewports_count];
                    break;
                }
                case WMTW_OP_SetScissorRects: {
                    const struct wmtw_setscissorrects *c = (const void *)r;
                    [enc setScissorRects:(const MTLScissorRect *)(v.side + c->scissors_offset)
                                   count:c->scissors_count];
                    break;
                }
                case WMTW_OP_SetRasterizerState: {
                    const struct wmtw_setrasterizerstate *c = (const void *)r;
                    [enc setFrontFacingWinding:(MTLWinding)c->front_facing];
                    [enc setCullMode:(MTLCullMode)c->cull_mode];
                    [enc setTriangleFillMode:(MTLTriangleFillMode)c->fill_mode];
                    [enc setDepthClipMode:(MTLDepthClipMode)c->depth_clip_mode];
                    [enc setDepthBias:c->depth_bias slopeScale:c->slope_scale clamp:c->depth_bias_clamp];
                    break;
                }
                case WMTW_OP_SetBlendFactorAndStencilRef: {
                    const struct wmtw_setblendfactorandstencilref *c = (const void *)r;
                    [enc setBlendColorRed:c->r green:c->g blue:c->b alpha:c->a];
                    [enc setStencilReferenceValue:c->stencil_ref]; break;
                }
                case WMTW_OP_UseResource: {
                    const struct wmtw_useresource *c = (const void *)r;
                    id o = rm_resolve(c->resource, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc useResource:o usage:(MTLResourceUsage)c->usage
                              stages:(MTLRenderStages)c->stages]; break;
                }
                case WMTW_OP_Draw: {
                    const struct wmtw_draw *c = (const void *)r;
                    [enc drawPrimitives:(MTLPrimitiveType)c->primitive
                            vertexStart:(NSUInteger)c->start vertexCount:(NSUInteger)c->count
                          instanceCount:(NSUInteger)(c->instances ?: 1)
                           baseInstance:(NSUInteger)c->base_instance];
                    break;
                }
                case WMTW_OP_DrawIndexed: {
                    const struct wmtw_drawindexed *c = (const void *)r;
                    id ib = rm_resolve(c->index_buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc drawIndexedPrimitives:(MTLPrimitiveType)c->primitive
                                    indexCount:(NSUInteger)c->index_count
                                     indexType:(MTLIndexType)c->index_type
                                   indexBuffer:ib
                             indexBufferOffset:(NSUInteger)c->index_offset
                                 instanceCount:(NSUInteger)(c->instances ?: 1)
                                    baseVertex:(NSInteger)c->base_vertex
                                  baseInstance:(NSUInteger)c->base_instance];
                    break;
                }
                default:
                    fprintf(stderr, "[rmetald] replay: opcode %u validated but not "
                            "implemented, at record %u\n", r->op, replayed);
                    bad = 1; break;
                }
                if (bad) break;
                off += r->size; replayed++;
            }
            [enc endEncoding];
            if (bad) {
                rm_consume_drawable(a->present_drawable);
                reply(fd, &h, err ? err : RM_ERR_BAD_OPCODE, NULL, 0); break;
            }
            if (a->present_drawable) {
                id d = rm_resolve(a->present_drawable, &err);
                if (err == RM_OK && d) [cb presentDrawable:(id<CAMetalDrawable>)d];
            }
            [cb commit];
            [cb waitUntilCompleted];
            rm_consume_drawable(a->present_drawable);
            struct rm_ret_u64 rr2 = { replayed };
            reply(fd, &h, RM_OK, &rr2, sizeof rr2); break;
        }
        case RM_OP_TEXTURE_GETBYTES: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLTexture> t = o;
            NSUInteger w = t.width, ht = t.height, bpr = w * 4, total = bpr * ht;
            uint8_t *px = malloc(total);
            [t getBytes:px bytesPerRow:bpr fromRegion:MTLRegionMake2D(0,0,w,ht) mipmapLevel:0];
            reply(fd, &h, RM_OK, px, (uint32_t)total);
            free(px); break;
        }
        /* ---- descriptor calls: verbatim WMT*Info in, real Metal object out ---- */
        case RM_OP_COMMAND_BUFFER: {
            id q = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            /* ml879: ask Metal to record per-encoder execution status so a GPU
             * fault names the encoder that caused it, not just the buffer. */
            MTLCommandBufferDescriptor *cbd = [MTLCommandBufferDescriptor new];
            cbd.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
            id<MTLCommandBuffer> cb = [(id<MTLCommandQueue>)q commandBufferWithDescriptor:cbd];
            struct rm_ret_handle r = { rm_intern(cb) };
            reply(fd, &h, cb ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_RENDER_ENCODER: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTRenderPassInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id cb = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTRenderPassInfo *i = (void *)(a + 1);
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            /* The REAL pass: eight colour attachments with their own load/store
             * actions, levels, slices and resolve targets, plus depth and
             * stencil. A single hardcoded clear-to-colour attachment is what the
             * throwaway test path used and it cannot draw a cube. */
            for (unsigned c = 0; c < 8; c++) {
                if (!i->colors[c].texture) continue;
                uint32_t e2 = RM_OK;
                id t = rm_resolve((uint64_t)i->colors[c].texture, &e2);
                if (e2 != RM_OK) {
                    /* Silently skipping leaves a pass that disagrees with the
                     * pipeline -- which is how the encoder abort happened. */
                    fprintf(stderr, "[rmetald] render pass: colour attachment %u handle "
                                    "0x%llx did not resolve (status %u)\n", c,
                            (unsigned long long)i->colors[c].texture, e2);
                    continue;
                }
                rp.colorAttachments[c].texture     = t;
                rm_frame_att_note((uint64_t)i->colors[c].texture);   /* ml898 */
                rp.colorAttachments[c].loadAction  = (MTLLoadAction)i->colors[c].load_action;
                rp.colorAttachments[c].storeAction = (MTLStoreAction)i->colors[c].store_action;
                rp.colorAttachments[c].level       = i->colors[c].level;
                rp.colorAttachments[c].slice       = i->colors[c].slice;
                rp.colorAttachments[c].depthPlane  = i->colors[c].depth_plane;
                rp.colorAttachments[c].clearColor  = MTLClearColorMake(
                    i->colors[c].clear_color.r, i->colors[c].clear_color.g,
                    i->colors[c].clear_color.b, i->colors[c].clear_color.a);
                if (i->colors[c].resolve_texture) {
                    uint32_t e3 = RM_OK;
                    id rt = rm_resolve((uint64_t)i->colors[c].resolve_texture, &e3);
                    if (e3 != RM_OK)
                        fprintf(stderr, "[rmetald] render pass: RESOLVE handle 0x%llx for colour %u "
                                        "did not resolve (status %u) -- MSAA resolve will not "
                                        "happen\n", (unsigned long long)i->colors[c].resolve_texture,
                                c, e3);
                    if (e3 == RM_OK) {
                        rp.colorAttachments[c].resolveTexture    = rt;
                        rp.colorAttachments[c].resolveLevel      = i->colors[c].resolve_level;
                        rp.colorAttachments[c].resolveSlice      = i->colors[c].resolve_slice;
                        rp.colorAttachments[c].resolveDepthPlane = i->colors[c].resolve_depth_plane;
                    }
                }
            }
            if (i->depth.texture) {
                uint32_t e2 = RM_OK; id t = rm_resolve((uint64_t)i->depth.texture, &e2);
                if (e2 != RM_OK)
                    fprintf(stderr, "[rmetald] render pass: DEPTH handle 0x%llx did not resolve "
                                    "(status %u) -- the pass will not match its pipeline\n",
                            (unsigned long long)i->depth.texture, e2);
                if (e2 == RM_OK) {
                    rp.depthAttachment.texture     = t;
                    rm_frame_att_note((uint64_t)i->depth.texture);   /* ml898 */
                    rp.depthAttachment.loadAction  = (MTLLoadAction)i->depth.load_action;
                    rp.depthAttachment.storeAction = (MTLStoreAction)i->depth.store_action;
                    rp.depthAttachment.level       = i->depth.level;
                    rp.depthAttachment.slice       = i->depth.slice;
                    rp.depthAttachment.clearDepth  = i->depth.clear_depth;
                    rp.depthAttachment.depthPlane  = i->depth.depth_plane;
                }
            }
            if (i->stencil.texture) {
                uint32_t e2 = RM_OK; id t = rm_resolve((uint64_t)i->stencil.texture, &e2);
                if (e2 != RM_OK)
                    fprintf(stderr, "[rmetald] render pass: STENCIL handle 0x%llx did not resolve "
                                    "(status %u)\n", (unsigned long long)i->stencil.texture, e2);
                if (e2 == RM_OK) {
                    rp.stencilAttachment.texture      = t;
                    rp.stencilAttachment.loadAction   = (MTLLoadAction)i->stencil.load_action;
                    rp.stencilAttachment.storeAction  = (MTLStoreAction)i->stencil.store_action;
                    rp.stencilAttachment.level        = i->stencil.level;
                    rp.stencilAttachment.slice        = i->stencil.slice;
                    rp.stencilAttachment.clearStencil = i->stencil.clear_stencil;
                    rp.stencilAttachment.depthPlane   = i->stencil.depth_plane;
                }
            }
            if (i->render_target_array_length)
                rp.renderTargetArrayLength = i->render_target_array_length;
            if (i->visibility_buffer) {
                uint32_t e4 = RM_OK;
                id vb = rm_resolve((uint64_t)i->visibility_buffer, &e4);
                if (e4 == RM_OK) rp.visibilityResultBuffer = vb;
                else fprintf(stderr, "[rmetald] render pass: VISIBILITY buffer 0x%llx did not "
                                     "resolve (status %u) -- occlusion queries will read nothing\n",
                             (unsigned long long)i->visibility_buffer, e4);
            }
            if (i->render_target_height) rp.renderTargetHeight = i->render_target_height;
            if (i->render_target_width)  rp.renderTargetWidth  = i->render_target_width;
            if (i->default_raster_sample_count) rp.defaultRasterSampleCount = i->default_raster_sample_count;
            id<MTLRenderCommandEncoder> enc =
                (rm_enc_end_open_on_cb((id)cb, "render"),
                 [(id<MTLCommandBuffer>)cb renderCommandEncoderWithDescriptor:rp]);
            if (enc) enc.label = [NSString stringWithFormat:@"enc#%lu render", (unsigned long)++g_enc_seq];
            if (!enc) {
                /* Nil here used to be reported as a bare refusal, and the guest
                 * then used the null encoder and faulted at address 0. Metal
                 * gives no reason, so describe the descriptor we handed it --
                 * the usual cause is a pass with NO attachment at all. */
                unsigned nattach = 0;
                for (unsigned c = 0; c < 8; c++)
                    if (rp.colorAttachments[c].texture) nattach++;
                fprintf(stderr, "[rmetald] render encoder REFUSED: %u colour attachment(s), "
                                "depth=%s stencil=%s target=%lux%lu samples=%lu -- "
                                "an attachmentless pass is legal ONLY with render-target "
                                "dimensions set\n",
                        nattach,
                        rp.depthAttachment.texture ? "yes" : "no",
                        rp.stencilAttachment.texture ? "yes" : "no",
                        (unsigned long)rp.renderTargetWidth, (unsigned long)rp.renderTargetHeight,
                        (unsigned long)rp.defaultRasterSampleCount);
                for (unsigned c = 0; c < 8; c++)
                    if (i->colors[c].texture && !rp.colorAttachments[c].texture)
                        fprintf(stderr, "[rmetald]   colour %u wanted handle 0x%llx but it did not resolve\n",
                                c, (unsigned long long)i->colors[c].texture);
            }
            rm_enc_opened(enc, (id)cb);   /* ml898 + ml1010: remember its command buffer */
            struct rm_ret_handle r = { rm_intern(enc) };
            reply(fd, &h, enc ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_ENCODE_INTO: {
            struct rm_arg_handle *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            if (!a->handle) {   /* ml930: a NULL encoder used to be accepted as nil, do nothing, and count as replayed */
                static unsigned said; if (said++ < 20) fprintf(stderr, "[rmetald] encodeCommands on a NULL encoder REFUSED (%u bytes of commands dropped by the guest's own bug)\n", h.payload_len);
                reply(fd, &h, RM_ERR_BAD_HANDLE, NULL, 0); break;
            }
            id e2 = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            if (!e2) { static unsigned said2; if (said2++ < 20) fprintf(stderr, "[rmetald] encodeCommands: handle %#llx resolves to nil, REFUSED\n", (unsigned long long)a->handle); reply(fd, &h, RM_ERR_BAD_HANDLE, NULL, 0); break; }
            if (!rm_enc_is_open(e2)) {   /* ml1016: same hazard as the blit stream */
                static unsigned said3;
                if (said3++ < 16)
                    fprintf(stderr, "[rmetald] ml1016 dropping a render batch for encoder %p: "
                            "it was already ended\n", (__bridge void *)e2);
                reply(fd, &h, RM_OK, NULL, 0); break;
            }
            struct wmtw_view v; struct wmtw_dec_result dr;
            if (wmtw_validate_batch((const uint8_t *)payload + sizeof *a,
                                    h.payload_len - (uint32_t)sizeof *a, &v, &dr) != WMTW_DEC_OK) {
                fprintf(stderr, "[rmetald] batch rejected: %s at record %u (opcode %u)\n",
                        wmtw_dec_strerror(dr.status), dr.record_index, dr.opcode);
                reply(fd, &h, RM_ERR_BAD_OPCODE, NULL, 0); break;
            }
            int n = rm_replay_into((id<MTLRenderCommandEncoder>)e2, v);
            struct rm_ret_u64 r = { n < 0 ? 0 : (uint64_t)n };
            reply(fd, &h, n < 0 ? RM_ERR_BAD_HANDLE : RM_OK, &r, sizeof r); break;
        }
        case RM_OP_END_ENCODING: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            if (rm_enc_closed(o)) [(id<MTLCommandEncoder>)o endEncoding];   /* ml898: exactly once */
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_PRESENT_DRAWABLE: {
            struct rm_present *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id cb = rm_resolve(a->cmdbuf, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            uint32_t e2 = RM_OK;
            id d = rm_resolve(a->drawable, &e2);
            if (e2 != RM_OK) { reply(fd,&h,e2,NULL,0); break; }
            {
                static unsigned long frames, blank;
                frames++;
                atomic_fetch_add(&g_present_count, 1);
                if (g_draws_since_present == 0) {
                    blank++;
                    if (blank <= 4 || (blank % 64) == 0)
                        fprintf(stderr, "[rmetald] BLANK frame presented: no draw records "
                                        "since the last present (%lu blank of %lu)\n",
                                blank, frames);
                } else if ((frames % 600) == 0) {
                    fprintf(stderr, "[rmetald] frames=%lu blank=%lu (%.2f%%) draws/frame=%lu | cmdbufs completed=%lu gpu-errors=%lu\n",
                              frames, blank, 100.0 * blank / frames, g_draws_since_present,
                              (unsigned long)g_gpu_completed, (unsigned long)g_gpu_errors);
                }
                g_draws_since_present = 0;
            }
            /* ml914: Xcode GPU trace of exactly one frame. Touch
             * /tmp/rmetald-gputrace-now; the capture starts at this present and
             * stops at the next, so the .gputrace holds every command buffer of
             * one frame. Needs MTL_CAPTURE_ENABLED=1 in the environment. */
            {
                static int trace_active; static unsigned trace_n;
                MTLCaptureManager *cm = [MTLCaptureManager sharedCaptureManager];
                if (trace_active) {
                    [cm stopCapture]; trace_active = 0;
                    fprintf(stderr, "[rmetald-trace] stopped at present %lu -> /tmp/rmetald-%u.gputrace\n",
                            (unsigned long)g_present_count, trace_n);
                } else if (access("/tmp/rmetald-gputrace-now", F_OK) == 0) {
                    unlink("/tmp/rmetald-gputrace-now");
                    trace_n++;
                    NSError *terr = nil;
                    MTLCaptureDescriptor *cd = [MTLCaptureDescriptor new];
                    cd.captureObject = [(id<MTLCommandBuffer>)cb commandQueue];
                    cd.destination = MTLCaptureDestinationGPUTraceDocument;
                    cd.outputURL = [NSURL fileURLWithPath:[NSString stringWithFormat:@"/tmp/rmetald-%u.gputrace", trace_n]];
                    if (![cm supportsDestination:MTLCaptureDestinationGPUTraceDocument])
                        fprintf(stderr, "[rmetald-trace] GPU trace documents not supported (MTL_CAPTURE_ENABLED=1 missing?)\n");
                    else if (![cm startCaptureWithDescriptor:cd error:&terr])
                        fprintf(stderr, "[rmetald-trace] start failed: %s\n", terr.localizedDescription.UTF8String ?: "?");
                    else { trace_active = 1; fprintf(stderr, "[rmetald-trace] started at present %lu\n", (unsigned long)g_present_count); }
                }
            }
            if (access("/tmp/rmetald-dump-now", F_OK) == 0) {   /* ml898 */
                unlink("/tmp/rmetald-dump-now");
                rm_frame_dump([(id<MTLCommandBuffer>)cb commandQueue]);
            } else if (g_present_count >= 1500 && g_present_count <= 3200 && (g_present_count % 100) == 0 && access("/tmp/rmetald-no-autodump", F_OK) != 0) {
                /* ml899: the level comes up somewhere past present ~1800 and the
                 * runs die soon after; dump on a schedule so no frame is missed. */
                fprintf(stderr, "[rmetald-dump] auto dump at present %lu\n", (unsigned long)g_present_count);
                rm_frame_dump([(id<MTLCommandBuffer>)cb commandQueue]);
            }
            g_frame_att_n = 0;
            [(id<MTLCommandBuffer>)cb presentDrawable:(id<CAMetalDrawable>)d];
            /* Presented: the drawable is the layer's again, so drop the pairing
             * that was holding it. Without this the pool leaks a drawable a
             * frame and acquisition eventually blocks forever. */
            rm_consume_drawable(a->drawable);
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_COMMIT: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            /* ml1015: refuse a SECOND commit of the same command buffer.
             *
             * Other ops commit internally, so a command buffer can already be
             * committed by the time the guest's own COMMIT arrives. Metal then
             * aborts the whole daemon on the addCompletedHandler below --
             * `Completed handler provided after commit call` -- which is exactly
             * how rmetald died. And when the host dies its calls start returning
             * 0, the guest throws away every command list ("no command buffer"
             * x81), and the GAME then crashes dereferencing those failures. The
             * guest-side crash we chased for four runs was downstream of this.
             *
             * Metal's own status is the discriminator, so there is no side table
             * to keep in sync: NotEnqueued/Enqueued mean "not yet committed". */
            {
                MTLCommandBufferStatus st = [(id<MTLCommandBuffer>)o status];
                if (st != MTLCommandBufferStatusNotEnqueued && st != MTLCommandBufferStatusEnqueued) {
                    static unsigned said;
                    if (said++ < 16)
                        fprintf(stderr, "[rmetald] ml1015 command buffer %p is already committed "
                                "(status %ld); ignoring the duplicate commit\n",
                                (__bridge void *)o, (long)st);
                    reply(fd, &h, RM_OK, NULL, 0); break;
                }
            }
            /* ml819: nothing here ever looked at a command buffer's outcome. A draw the
             * GPU rejected (missing resource, bad binding, fault) completes with an
             * error and simply does not appear -- exactly what 'objects not rendered'
             * looks like. */
            [(id<MTLCommandBuffer>)o addCompletedHandler:^(id<MTLCommandBuffer> cb) {
                atomic_fetch_add(&g_gpu_completed, 1);
                if (cb.status == MTLCommandBufferStatusError) {
                    unsigned long n = atomic_fetch_add(&g_gpu_errors, 1);
                    if (n < 16 || (n % 256) == 0) {
                        fprintf(stderr, "[rmetald] GPU ERROR #%lu: %s\n", n + 1,
                                [[cb.error description] UTF8String]);
                        /* ml879: which encoder faulted (state 4), which were merely
                         * affected (2) or never ran (3). */
                        NSArray *infos = cb.error.userInfo[MTLCommandBufferEncoderInfoErrorKey];
                        for (id<MTLCommandBufferEncoderInfo> ei in infos) {
                            static const char *st[] = { "unknown", "completed", "affected", "pending", "faulted" };
                            unsigned k = (unsigned)ei.errorState;
                            fprintf(stderr, "[rmetald]   encoder '%s' state=%s%s\n",
                                    ei.label ? [ei.label UTF8String] : "?", k < 5 ? st[k] : "?",
                                    ei.debugSignposts.count ? [[ei.debugSignposts componentsJoinedByString:@","] UTF8String] : "");
                        }
                    }
                }
            }];
            {   /* ml1010: never commit with an encoder still open -- Metal aborts. */
                int left = rm_enc_end_for_cb(o);
                if (left) {
                    static unsigned said;
                    if (said++ < 16)
                        fprintf(stderr, "[rmetald] ml1010 closed %d encoder(s) the guest left open "
                                        "before commit\n", left);
                }
            }
            [(id<MTLCommandBuffer>)o commit];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_WAIT_COMPLETED: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            [(id<MTLCommandBuffer>)o waitUntilCompleted];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_COUNTER_NEW_TIMESTAMP: {
            if (h.payload_len != sizeof(struct rm_counter_new)) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            const struct rm_counter_new *a=(const void *)payload;
            id object=rm_resolve(a->device,&err);
            if (err != RM_OK || ![object conformsToProtocol:@protocol(MTLDevice)]) {
                reply(fd,&h,err != RM_OK ? err : RM_ERR_WRONG_CLASS,NULL,0); break;
            }
            id<MTLDevice> device=object; id<MTLCounterSet> timestamp=nil;
            for (id<MTLCounterSet> set in device.counterSets) {
                if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) { timestamp=set; break; }
            }
            if (!timestamp) { reply(fd,&h,RM_ERR_WRONG_CLASS,NULL,0); break; }
            MTLCounterSampleBufferDescriptor *desc=[MTLCounterSampleBufferDescriptor new];
            desc.counterSet=timestamp; desc.sampleCount=a->count;
            desc.storageMode=a->shared ? MTLStorageModeShared : MTLStorageModePrivate;
            NSError *error=nil; id<MTLCounterSampleBuffer> buffer=[device newCounterSampleBufferWithDescriptor:desc error:&error];
            struct rm_ret_handle result={rm_intern(buffer)};
            reply(fd,&h,buffer ? RM_OK : RM_ERR_WRONG_CLASS,&result,sizeof(result)); break;
        }
        case RM_OP_COUNTER_RESOLVE: {
            if (h.payload_len != sizeof(struct rm_counter_resolve)) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            const struct rm_counter_resolve *a=(const void *)payload;
            if (a->data_length > RM_CHUNK_BYTES) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id object=rm_resolve(a->buffer,&err);
            if (err != RM_OK || ![object conformsToProtocol:@protocol(MTLCounterSampleBuffer)]) {
                reply(fd,&h,err != RM_OK ? err : RM_ERR_WRONG_CLASS,NULL,0); break;
            }
            id<MTLCounterSampleBuffer> buffer=object;
            if (a->start > buffer.sampleCount || a->count > buffer.sampleCount - a->start) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break;
            }
            NSData *data=[buffer resolveCounterRange:NSMakeRange(a->start,a->count)];
            if (!data || a->data_length > data.length) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            reply(fd,&h,RM_OK,data.bytes,(uint32_t)a->data_length); break;
        }
        case RM_OP_BLIT_WITH_SAMPLES: {
            if (h.payload_len < sizeof(struct rm_blit_samples)) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            const struct rm_blit_samples *a=(const void *)payload;
            if (a->reserved || a->count > RM_MAX_BLIT_SAMPLES ||
                h.payload_len != sizeof(*a) + (uint64_t)a->count * sizeof(struct rm_sample_attachment)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break;
            }
            id object=rm_resolve(a->cmdbuf,&err);
            if (err != RM_OK || ![object conformsToProtocol:@protocol(MTLCommandBuffer)]) {
                reply(fd,&h,err != RM_OK ? err : RM_ERR_WRONG_CLASS,NULL,0); break;
            }
            const struct rm_sample_attachment *attachments=(const void *)(a+1);
            id<MTLCounterSampleBuffer> buffers[RM_MAX_BLIT_SAMPLES]={0};
            for (uint32_t i=0; i<a->count; ++i) {
                if (!attachments[i].buffer) continue;
                id candidate=rm_resolve(attachments[i].buffer,&err);
                if (err != RM_OK || ![candidate conformsToProtocol:@protocol(MTLCounterSampleBuffer)]) {
                    if (err == RM_OK) err=RM_ERR_WRONG_CLASS; break;
                }
                buffers[i]=candidate;
            }
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            MTLBlitPassDescriptor *desc=[MTLBlitPassDescriptor new];
            for (uint32_t i=0; i<a->count; ++i) {
                desc.sampleBufferAttachments[i].sampleBuffer=buffers[i];
                desc.sampleBufferAttachments[i].startOfEncoderSampleIndex=attachments[i].start;
                desc.sampleBufferAttachments[i].endOfEncoderSampleIndex=attachments[i].end;
            }
            rm_enc_end_open_on_cb(object, "blit");
            id<MTLBlitCommandEncoder> encoder=[(id<MTLCommandBuffer>)object blitCommandEncoderWithDescriptor:desc];
            if (encoder) encoder.label=[NSString stringWithFormat:@"enc#%lu blit",(unsigned long)++g_enc_seq];
            rm_enc_opened(encoder,object);
            struct rm_ret_handle result={rm_intern(encoder)};
            reply(fd,&h,encoder ? RM_OK : RM_ERR_WRONG_CLASS,&result,sizeof(result)); break;
        }
        case RM_OP_HEAP_NEW_TEXTURE: {
            if (h.payload_len != sizeof(struct rm_heap_new_texture) + sizeof(struct WMTTextureInfo)) {
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            const struct rm_heap_new_texture *a = (const void *)payload;
            id object = rm_resolve(a->heap, &err);
            if (err != RM_OK || ![object conformsToProtocol:@protocol(MTLHeap)]) {
                reply(fd, &h, err != RM_OK ? err : RM_ERR_WRONG_CLASS, NULL, 0); break;
            }
            const struct WMTTextureInfo *i = (const void *)(a + 1);
            MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
            d.pixelFormat = rm_fmt(i->pixel_format);
            d.width = i->width; d.height = i->height; d.depth = i->depth;
            d.arrayLength = i->array_length; d.textureType = (MTLTextureType)i->type;
            d.mipmapLevelCount = i->mipmap_level_count; d.sampleCount = i->sample_count;
            d.usage = (MTLTextureUsage)i->usage; d.resourceOptions = (MTLResourceOptions)i->options;
            id<MTLHeap> heap = object;
            id<MTLTexture> texture = a->offset == UINT64_MAX ? [heap newTextureWithDescriptor:d]
                : [heap newTextureWithDescriptor:d offset:a->offset];
            struct rm_ret_handle_u64 result = {rm_intern(texture), texture ? texture.gpuResourceID._impl : 0};
            reply(fd, &h, texture ? RM_OK : RM_ERR_WRONG_CLASS, &result, sizeof(result)); break;
        }
        case RM_OP_HEAP_CREATE: {
            if (h.payload_len != sizeof(struct rm_wmt_info) + sizeof(struct WMTHeapInfo)) {
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            const struct rm_wmt_info *a = (const void *)payload;
            if (a->info_len != sizeof(struct WMTHeapInfo) || a->extra_count) {
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            id device = rm_resolve(a->owner, &err);
            if (err != RM_OK || ![device conformsToProtocol:@protocol(MTLDevice)]) {
                reply(fd, &h, err != RM_OK ? err : RM_ERR_WRONG_CLASS, NULL, 0); break;
            }
            const struct WMTHeapInfo *i = (const void *)(a + 1);
            MTLHeapDescriptor *desc = [[MTLHeapDescriptor alloc] init];
            desc.size = i->size; desc.resourceOptions = (MTLResourceOptions)i->options;
            desc.type = (MTLHeapType)i->type; desc.sparsePageSize = (MTLSparsePageSize)i->sparse_page_size;
            id<MTLHeap> heap = [(id<MTLDevice>)device newHeapWithDescriptor:desc];
            struct rm_ret_handle result = {rm_intern(heap)};
            reply(fd, &h, heap ? RM_OK : RM_ERR_WRONG_CLASS, &result, sizeof(result)); break;
        }
        case RM_OP_HEAP_NEW_PRIVATE_BUFFER: {
            if (h.payload_len != sizeof(struct rm_heap_new_buffer)) {
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            const struct rm_heap_new_buffer *a = (const void *)payload;
            id object = rm_resolve(a->heap, &err);
            if (err != RM_OK || ![object conformsToProtocol:@protocol(MTLHeap)]) {
                reply(fd, &h, err != RM_OK ? err : RM_ERR_WRONG_CLASS, NULL, 0); break;
            }
            id<MTLHeap> heap = object;
            if (heap.storageMode != MTLStorageModePrivate) {
                reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break;
            }
            id<MTLBuffer> buffer = a->offset == UINT64_MAX
                ? [heap newBufferWithLength:a->length options:(MTLResourceOptions)a->options]
                : [heap newBufferWithLength:a->length options:(MTLResourceOptions)a->options offset:a->offset];
            struct rm_ret_handle_u64 result = {rm_intern(buffer), buffer ? buffer.gpuAddress : 0};
            reply(fd, &h, buffer ? RM_OK : RM_ERR_WRONG_CLASS, &result, sizeof(result)); break;
        }
        case RM_OP_HEAP_TEXTURE_SIZE: {
            if (h.payload_len != sizeof(struct rm_wmt_info) + sizeof(struct WMTTextureInfo)) {
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            const struct rm_wmt_info *a = (const void *)payload;
            if (a->info_len != sizeof(struct WMTTextureInfo) || a->extra_count) {
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            id device = rm_resolve(a->owner, &err);
            if (err != RM_OK || ![device conformsToProtocol:@protocol(MTLDevice)]) {
                reply(fd, &h, err != RM_OK ? err : RM_ERR_WRONG_CLASS, NULL, 0); break;
            }
            const struct WMTTextureInfo *i = (const void *)(a + 1);
            MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
            d.pixelFormat = rm_fmt(i->pixel_format);
            d.width = i->width; d.height = i->height; d.depth = i->depth;
            d.arrayLength = i->array_length; d.textureType = (MTLTextureType)i->type;
            d.mipmapLevelCount = i->mipmap_level_count; d.sampleCount = i->sample_count;
            d.usage = (MTLTextureUsage)i->usage; d.resourceOptions = (MTLResourceOptions)i->options;
            MTLSizeAndAlign value = [(id<MTLDevice>)device heapTextureSizeAndAlignWithDescriptor:d];
            struct rm_size_and_align result = {value.size, value.align};
            reply(fd, &h, RM_OK, &result, sizeof(result)); break;
        }
        case RM_OP_HEAP_BUFFER_SIZE: {
            if (h.payload_len != sizeof(struct rm_heap_buffer_size)) {
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            const struct rm_heap_buffer_size *a = (const void *)payload;
            id device = rm_resolve(a->device, &err);
            if (err != RM_OK || ![device conformsToProtocol:@protocol(MTLDevice)]) {
                reply(fd, &h, err != RM_OK ? err : RM_ERR_WRONG_CLASS, NULL, 0); break;
            }
            MTLSizeAndAlign value = [(id<MTLDevice>)device heapBufferSizeAndAlignWithLength:(NSUInteger)a->length
                                                                                  options:(MTLResourceOptions)a->options];
            struct rm_size_and_align result = {value.size, value.align};
            reply(fd, &h, RM_OK, &result, sizeof(result)); break;
        }
        case RM_OP_COMMAND_BUFFER_PROPERTY: {
            if (h.payload_len != sizeof(struct rm_arg_handle_u64)) {
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            const struct rm_arg_handle_u64 *a = (const void *)payload;
            id cb = rm_resolve(a->handle, &err);
            if (err != RM_OK || ![cb conformsToProtocol:@protocol(MTLCommandBuffer)]) {
                reply(fd, &h, err != RM_OK ? err : RM_ERR_WRONG_CLASS, NULL, 0); break;
            }
            double seconds = 0;
            switch (a->arg) {
            case WMTCommandBufferPropertyKernelStartTime: seconds = [(id<MTLCommandBuffer>)cb kernelStartTime]; break;
            case WMTCommandBufferPropertyKernelEndTime: seconds = [(id<MTLCommandBuffer>)cb kernelEndTime]; break;
            case WMTCommandBufferPropertyGPUStartTime: seconds = [(id<MTLCommandBuffer>)cb GPUStartTime]; break;
            case WMTCommandBufferPropertyGPUEndTime: seconds = [(id<MTLCommandBuffer>)cb GPUEndTime]; break;
            }
            struct rm_ret_u64 r = {(uint64_t)(seconds * 1000000000.0)};
            reply(fd, &h, RM_OK, &r, sizeof(r)); break;
        }
        case RM_OP_CMDBUF_STATUS: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { (uint64_t)[(id<MTLCommandBuffer>)o status] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_ENCODE_SIGNAL:
        case RM_OP_ENCODE_WAIT: {
            struct rm_encode_sig *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id cb = rm_resolve(a->cmdbuf, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            uint32_t e2 = RM_OK; id ev = rm_resolve(a->event, &e2);
            if (e2 != RM_OK) { reply(fd,&h,e2,NULL,0); break; }
            if (h.opcode == RM_OP_ENCODE_SIGNAL)
                [(id<MTLCommandBuffer>)cb encodeSignalEvent:(id<MTLEvent>)ev value:a->value];
            else
                [(id<MTLCommandBuffer>)cb encodeWaitForEvent:(id<MTLEvent>)ev value:a->value];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_NEW_TEXTURE_FULL: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTTextureInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTTextureInfo *i = (void *)(a + 1);
            MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
            d.pixelFormat      = rm_fmt(i->pixel_format);
            d.width            = i->width  ? i->width  : 1;
            d.height           = i->height ? i->height : 1;
            d.depth            = i->depth  ? i->depth  : 1;
            d.arrayLength      = i->array_length ? i->array_length : 1;
            d.textureType      = (MTLTextureType)i->type;
            d.mipmapLevelCount = i->mipmap_level_count ? i->mipmap_level_count : 1;
            d.sampleCount      = i->sample_count ? i->sample_count : 1;
            d.usage            = (MTLTextureUsage)i->usage;
            d.resourceOptions  = (MTLResourceOptions)i->options;
            id<MTLTexture> t = [(id<MTLDevice>)dev newTextureWithDescriptor:d];
            if (!t) fprintf(stderr, "[rmetald] newTexture %ux%u fmt %u type %u usage %u FAILED\n",
                            i->width, i->height, (unsigned)i->pixel_format,
                            (unsigned)i->type, (unsigned)i->usage);
            struct rm_ret_handle_u64 r = { rm_intern(t), t ? t.gpuResourceID._impl : 0 };
            reply(fd, &h, t ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_TEXTURE_REPLACE: {
            struct rm_tex_replace *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->texture, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            uint32_t have = h.payload_len - (uint32_t)sizeof *a;
            uint64_t need = (uint64_t)a->bytes_per_row * a->h * (a->d ? a->d : 1);
            if (need > have) {
                fprintf(stderr, "[rmetald] texture upload short: need %llu have %u\n",
                        (unsigned long long)need, have);
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            [(id<MTLTexture>)o replaceRegion:MTLRegionMake3D(a->x, a->y, a->z, a->w, a->h, a->d ? a->d : 1)
                                 mipmapLevel:a->level
                                       slice:a->slice
                                   withBytes:(const uint8_t *)payload + sizeof *a
                                 bytesPerRow:a->bytes_per_row
                               bytesPerImage:a->bytes_per_image];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_NEW_TEXTURE_VIEW: {
            struct rm_tex_view *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->texture, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            /* ml820: apply the guest's effective swizzle (packed r|g<<8|b<<16|a<<24).
             * Identity is 2,3,4,5 in MTLTextureSwizzle terms; a zero word means an
             * older guest that never sent one, so keep the swizzle-less overload. */
            MTLTextureSwizzleChannels sw = MTLTextureSwizzleChannelsMake(
                (MTLTextureSwizzle)(a->swizzle & 0xff), (MTLTextureSwizzle)((a->swizzle >> 8) & 0xff),
                (MTLTextureSwizzle)((a->swizzle >> 16) & 0xff), (MTLTextureSwizzle)((a->swizzle >> 24) & 0xff));
            id<MTLTexture> t = a->swizzle
              ? [(id<MTLTexture>)o
                newTextureViewWithPixelFormat:rm_fmt((enum WMTPixelFormat)a->format)
                                  textureType:(MTLTextureType)a->texture_type
                                       levels:NSMakeRange(a->level_start, a->level_count)
                                       slices:NSMakeRange(a->slice_start, a->slice_count)
                                      swizzle:sw]
              : [(id<MTLTexture>)o
                newTextureViewWithPixelFormat:rm_fmt((enum WMTPixelFormat)a->format)
                                  textureType:(MTLTextureType)a->texture_type
                                       levels:NSMakeRange(a->level_start, a->level_count)
                                       slices:NSMakeRange(a->slice_start, a->slice_count)];
            struct rm_ret_handle_u64 r = { rm_intern(t), t ? t.gpuResourceID._impl : 0 };
            reply(fd, &h, t ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_LAYER_SET_PROPS: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTLayerProps)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            const struct WMTLayerProps *p = (void *)(a + 1);
            double w = p->drawable_width, ht = p->drawable_height;
            unsigned pf = (unsigned)p->pixel_format;
            int opaque = p->opaque, fbonly = p->framebuffer_only;
            /* Assign ONLY on change.
             *
             * Writing drawableSize makes CoreAnimation tear down and rebuild the
             * layer's drawable pool even when the value is identical. The guest
             * re-sends the same 1024x768 about ten times a second, so the pool
             * was being recycled underneath frames in flight -- which presents
             * blank, and reads as a black flash a few times a second. Same care
             * for the other properties: they are all pool-affecting. */
            __block int changed = 0;
            dispatch_sync(dispatch_get_main_queue(), ^{
                if (w > 0 && ht > 0) {
                    CGSize want = CGSizeMake(w, ht);
                    g_guest_w = w; g_guest_h = ht;
                    if (!CGSizeEqualToSize(g_layer.drawableSize, want)) {
                        g_layer.drawableSize = want; changed = 1;
                    }
                }
                if (pf) {
                    MTLPixelFormat f = rm_fmt((enum WMTPixelFormat)pf);
                    if (g_layer.pixelFormat != f) { g_layer.pixelFormat = f; changed = 1; }
                }
                BOOL o = opaque ? YES : NO, fb = fbonly ? YES : NO;
                if (g_layer.opaque != o)          { g_layer.opaque = o; changed = 1; }
                if (g_layer.framebufferOnly != fb) { g_layer.framebufferOnly = fb; changed = 1; }
            });
            {
                static unsigned long calls, applied;
                calls++; if (changed) applied++;
                if (changed || calls <= 2 || (calls % 512) == 0)
                    fprintf(stderr, "[rmetald] layer props %.0fx%.0f fmt %u -- %s "
                                    "(%lu calls, %lu applied)\n", w, ht, pf,
                            changed ? "APPLIED" : "no change, pool preserved", calls, applied);
            }
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_LAYER_GET_PROPS: {
            __block struct WMTLayerProps r;
            memset(&r, 0, sizeof r);
            dispatch_sync(dispatch_get_main_queue(), ^{
                r.contents_scale   = g_layer.contentsScale;
                r.drawable_width   = g_layer.drawableSize.width;
                r.drawable_height  = g_layer.drawableSize.height;
                r.opaque           = g_layer.opaque;
                r.framebuffer_only = g_layer.framebufferOnly;
                r.display_sync_enabled = 1;
                r.pixel_format     = (enum WMTPixelFormat)g_layer.pixelFormat;
            });
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_MIN_LINEAR_ALIGN: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            NSUInteger al = [(id<MTLDevice>)o minimumLinearTextureAlignmentForPixelFormat:
                             rm_fmt((enum WMTPixelFormat)a->arg)];
            /* Never hand back zero: the caller divides by this. */
            struct rm_ret_u64 r = { al ? al : 256 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_SUPPORTS_SAMPLE_COUNT: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLDevice>)o supportsTextureSampleCount:a->arg] ? 1 : 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_BLIT_ENCODER: {
            id cb = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            rm_enc_end_open_on_cb((id)cb, "blit");   /* ml1019 */
            id<MTLBlitCommandEncoder> e2 = [(id<MTLCommandBuffer>)cb blitCommandEncoder];
            if (e2) e2.label = [NSString stringWithFormat:@"enc#%lu blit", (unsigned long)++g_enc_seq];
            rm_enc_opened(e2, (id)cb);   /* ml898 + ml1010 */
            struct rm_ret_handle r = { rm_intern(e2) };
            reply(fd, &h, e2 ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_NEW_RESIDENCY_SET: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id set = nil;
            if (@available(macOS 15.0, *)) {
                MTLResidencySetDescriptor *d = [[MTLResidencySetDescriptor alloc] init];
                d.initialCapacity = (NSUInteger)a->arg;
                NSError *e = nil;
                set = [(id<MTLDevice>)dev newResidencySetWithDescriptor:d error:&e];
                if (!set) fprintf(stderr, "[rmetald] newResidencySet: %s\n", e ? [[e localizedDescription] UTF8String] : "?");
            }
            struct rm_ret_handle r = { rm_intern(set) };
            fprintf(stderr, "[rmetald] newResidencySet(capacity %llu) -> %s\n", (unsigned long long)a->arg, set ? "ok" : "nil");
            reply(fd, &h, set ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_RESIDENCY_BATCH: {
            const struct rm_residency_batch *a = (const void *)payload;
            if (!rm_residency_batch_valid(a, h.payload_len)) {
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            if (@available(macOS 15.0, *)) {
                if (a->action == RM_RESIDENCY_PROBE) { reply(fd, &h, RM_OK, NULL, 0); break; }
                id set = rm_resolve(a->set, &err);
                if (err != RM_OK || ![set conformsToProtocol:@protocol(MTLResidencySet)]) {
                    reply(fd, &h, err != RM_OK ? err : RM_ERR_WRONG_CLASS, NULL, 0); break;
                }
                if (a->action == RM_RESIDENCY_REMOVE_ALL) {
                    [(id<MTLResidencySet>)set removeAllAllocations];
                    reply(fd, &h, RM_OK, NULL, 0); break;
                }
                id<MTLAllocation> __unsafe_unretained *items = a->count ? (id<MTLAllocation> __unsafe_unretained *)calloc(a->count, sizeof(*items)) : NULL;
                if (a->count && !items) { reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break; }
                const uint64_t *handles = (const void *)(a + 1);
                for (uint32_t i = 0; i < a->count; ++i) {
                    id allocation = rm_resolve(handles[i], &err);
                    if (err != RM_OK || ![allocation conformsToProtocol:@protocol(MTLAllocation)]) {
                        if (err == RM_OK) err = RM_ERR_WRONG_CLASS;
                        break;
                    }
                    items[i] = allocation;
                }
                @try {
                    if (err == RM_OK && a->count) {
                        if (a->action == RM_RESIDENCY_ADD)
                            [(id<MTLResidencySet>)set addAllocations:items count:a->count];
                        else
                            [(id<MTLResidencySet>)set removeAllocations:items count:a->count];
                    }
                } @finally { free(items); }
                reply(fd, &h, err, NULL, 0); break;
            }
            reply(fd, &h, RM_ERR_BAD_OPCODE, NULL, 0); break;
        }
        case RM_OP_RESIDENCY_ADD: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id set = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id alloc = rm_resolve(a->arg, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            if (@available(macOS 15.0, *)) [(id<MTLResidencySet>)set addAllocation:(id<MTLAllocation>)alloc];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_RESIDENCY_COMMIT: {
            id set = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            if (@available(macOS 15.0, *)) { [(id<MTLResidencySet>)set commit]; [(id<MTLResidencySet>)set requestResidency]; }
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_QUEUE_ADD_RESIDENCY: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id q = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id set = rm_resolve(a->arg, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            if (@available(macOS 15.0, *)) [(id<MTLCommandQueue>)q addResidencySet:(id<MTLResidencySet>)set];
            fprintf(stderr, "[rmetald] residency set attached to the command queue\n");
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_SET_LABEL: {
            struct rm_arg_handle *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            NSString *l = [[NSString alloc] initWithBytes:(const uint8_t *)payload + sizeof *a
                           length:h.payload_len - sizeof *a encoding:NSUTF8StringEncoding];
            [(id<MTLCommandEncoder>)o setLabel:l];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_BLIT_INTO: {
            /* Blit commands are handles and scalars only -- no inline pointers
             * -- so each command's struct travels verbatim and is translated
             * here, the same discipline the descriptors use. Records are
             * {type, size, bytes}; the guest's `next` pointer is not sent. */
            struct rm_arg_handle *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id eo = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLBlitCommandEncoder> enc = eo;
            /* ml1016: the guest legitimately keeps recording after abandoning a
             * list, and ml1010 may already have ended this encoder to make its
             * command buffer committable. Passing commands to an ended encoder
             * kills the daemon, and a dead host makes every guest Metal call
             * return 0 -- which is what took the GAME down. Refuse instead. */
            if (!rm_enc_is_open(eo)) {
                static unsigned said;
                if (said++ < 16)
                    fprintf(stderr, "[rmetald] ml1016 dropping a blit batch for encoder %p: "
                            "it was already ended\n", (__bridge void *)eo);
                reply(fd, &h, RM_OK, NULL, 0); break;
            }
            const uint8_t *p = (const uint8_t *)payload + sizeof *a;
            const uint8_t *end = (const uint8_t *)payload + h.payload_len;
            uint64_t done = 0, skipped = 0;
            while ((size_t)(end - p) >= 8) {
                uint32_t type = *(const uint32_t *)p, sz = *(const uint32_t *)(p + 4);
                const uint8_t *rec = p + 8;
                if (sz > (size_t)(end - rec)) break;
                p = rec + sz;
                uint32_t e2 = RM_OK;
                #define RES(h_) rm_resolve((uint64_t)(h_), &e2)
                switch (type) {
                case WMTBlitCommandNop: break;
                case WMTBlitCommandCopyFromBufferToBuffer: {
                    const struct wmtcmd_blit_copy_from_buffer_to_buffer *c = (const void *)rec;
                    id sb = RES(c->src), db = RES(c->dst);
                    if (e2 != RM_OK || !sb || !db) { skipped++; break; }
                    /* ml1013: bounds-check the extents before handing them to
                     * Metal. A valid handle is not enough -- an out-of-range
                     * blit walks off the allocation inside AGX and takes the
                     * whole daemon with it (SIGSEGV in
                     * -[AGXG16XFamilyBlitContext copyFromBuffer:...], which is
                     * how rmetald died mid-run). D3D12 validates this; with
                     * Metal validation off in a release build nothing else does,
                     * and when the host dies the guest reports "cannot reach"
                     * and silently falls back to local. */
                    {
                        /* ml1014: the ml1013 extent check PASSED and the daemon
                         * still died in AGX at the same address, so the extents
                         * were never the problem. Validate what the handles
                         * actually ARE -- a slot holds an untyped id, so a
                         * texture or a stale object resolves just as happily as
                         * a buffer -- and describe every copy that looks wrong,
                         * so the offender names itself instead of being guessed
                         * at a second time. */
                        NSUInteger slen = 0, dlen = 0;
                        int sok = [sb conformsToProtocol:@protocol(MTLBuffer)];
                        int dok = [db conformsToProtocol:@protocol(MTLBuffer)];
                        if (sok) slen = [(id<MTLBuffer>)sb length];
                        if (dok) dlen = [(id<MTLBuffer>)db length];
                        int bad = !sok || !dok || !c->copy_length ||
                                  c->copy_length > slen || c->src_offset > slen - c->copy_length ||
                                  c->copy_length > dlen || c->dst_offset > dlen - c->copy_length;
                        static unsigned said, shown;
                        if (bad || shown < 8) {
                            if (bad ? (said++ < 24) : (shown++ < 8))
                                fprintf(stderr, "[rmetald] ml1014 %s buffer copy: %llu bytes "
                                        "src=%s(%p,len=%lu)+%llu dst=%s(%p,len=%lu)+%llu\n",
                                        bad ? "REFUSING" : "ok",
                                        (unsigned long long)c->copy_length,
                                        sok ? "MTLBuffer" : [NSStringFromClass([sb class]) UTF8String],
                                        (__bridge void *)sb, (unsigned long)slen, (unsigned long long)c->src_offset,
                                        dok ? "MTLBuffer" : [NSStringFromClass([db class]) UTF8String],
                                        (__bridge void *)db, (unsigned long)dlen, (unsigned long long)c->dst_offset);
                        }
                        if (bad) { skipped++; break; }
                    }
                    [enc copyFromBuffer:sb sourceOffset:c->src_offset toBuffer:db
              destinationOffset:c->dst_offset size:c->copy_length];
                    done++; break;
                }
                case WMTBlitCommandCopyFromBufferToTexture: {
                    const struct wmtcmd_blit_copy_from_buffer_to_texture *c = (const void *)rec;
                    id sb = RES(c->src), dt = RES(c->dst);
                    if (e2 != RM_OK || !sb || !dt) { skipped++; break; }
                    [enc copyFromBuffer:sb sourceOffset:c->src_offset
                      sourceBytesPerRow:c->bytes_per_row sourceBytesPerImage:c->bytes_per_image
                             sourceSize:MTLSizeMake(c->size.width, c->size.height, c->size.depth)
                              toTexture:dt destinationSlice:c->slice destinationLevel:c->level
                     destinationOrigin:MTLOriginMake(c->origin.x, c->origin.y, c->origin.z)];
                    done++; break;
                }
                case WMTBlitCommandCopyFromTextureToBuffer: {
                    const struct wmtcmd_blit_copy_from_texture_to_buffer *c = (const void *)rec;
                    id st2 = RES(c->src), db = RES(c->dst);
                    if (e2 != RM_OK || !st2 || !db) { skipped++; break; }
                    [enc copyFromTexture:st2 sourceSlice:c->slice sourceLevel:c->level
                            sourceOrigin:MTLOriginMake(c->origin.x, c->origin.y, c->origin.z)
                              sourceSize:MTLSizeMake(c->size.width, c->size.height, c->size.depth)
                                toBuffer:db destinationOffset:c->offset
                   destinationBytesPerRow:c->bytes_per_row
                 destinationBytesPerImage:c->bytes_per_image];
                    done++; break;
                }
                case WMTBlitCommandCopyFromTextureToTexture: {
                    const struct wmtcmd_blit_copy_from_texture_to_texture *c = (const void *)rec;
                    id st2 = RES(c->src), dt = RES(c->dst);
                    if (e2 != RM_OK || !st2 || !dt) { skipped++; break; }
                    [enc copyFromTexture:st2 sourceSlice:c->src_slice sourceLevel:c->src_level
                            sourceOrigin:MTLOriginMake(c->src_origin.x, c->src_origin.y, c->src_origin.z)
                              sourceSize:MTLSizeMake(c->src_size.width, c->src_size.height, c->src_size.depth)
                               toTexture:dt destinationSlice:c->dst_slice
                        destinationLevel:c->dst_level
                       destinationOrigin:MTLOriginMake(c->dst_origin.x, c->dst_origin.y, c->dst_origin.z)];
                    done++; break;
                }
                case WMTBlitCommandGenerateMipmaps: {
                    const struct wmtcmd_blit_generate_mipmaps *c = (const void *)rec;
                    id t = RES(c->texture);
                    if (e2 != RM_OK || !t) { skipped++; break; }
                    [enc generateMipmapsForTexture:t]; done++; break;
                }
                case WMTBlitCommandFillBuffer: {
                    const struct wmtcmd_blit_fillbuffer *c = (const void *)rec;
                    id b = RES(c->buffer);
                    if (e2 != RM_OK || !b) { skipped++; break; }
                    [enc fillBuffer:b range:NSMakeRange(c->offset, c->length) value:c->value];
                    done++; break;
                }
                case WMTBlitCommandWaitForFence:
                case WMTBlitCommandUpdateFence: {
                    const struct wmtcmd_blit_fence_op *c = (const void *)rec;
                    id f = c->fence ? RES(c->fence) : nil;
                    if (e2 != RM_OK || !f) { skipped++; break; }
                    if (type == WMTBlitCommandUpdateFence) [enc updateFence:f];
                    else                                   [enc waitForFence:f];
                    done++; break;
                }
                default: {
                    static unsigned told;
                    if (told++ < 8)
                        fprintf(stderr, "[rmetald] blit: unknown command type %u -- skipped\n", type);
                    skipped++; break;
                }
                }
                #undef RES
            }
            if (skipped) {
                static unsigned told;
                if (told++ < 8)
                    fprintf(stderr, "[rmetald] blit batch: %llu replayed, %llu SKIPPED "
                                    "(a skipped copy leaves its destination stale)\n",
                            (unsigned long long)done, (unsigned long long)skipped);
            }
            struct rm_ret_u64 r = { done };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_BUFFER_NEW_TEXTURE: {
            /* A texture VIEWING a buffer's memory. Streaming creates these, so
             * an unrouted one stalls loading rather than failing visibly. */
            struct rm_buf_texture *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTTextureInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id b = rm_resolve(a->buffer, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTTextureInfo *i = (void *)(a + 1);
            MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
            d.pixelFormat      = rm_fmt(i->pixel_format);
            d.width            = i->width  ? i->width  : 1;
            d.height           = i->height ? i->height : 1;
            d.depth            = i->depth  ? i->depth  : 1;
            d.arrayLength      = i->array_length ? i->array_length : 1;
            d.textureType      = (MTLTextureType)i->type;
            d.mipmapLevelCount = i->mipmap_level_count ? i->mipmap_level_count : 1;
            d.sampleCount      = i->sample_count ? i->sample_count : 1;
            d.usage            = (MTLTextureUsage)i->usage;
            d.resourceOptions  = (MTLResourceOptions)i->options;
            id<MTLTexture> t = [(id<MTLBuffer>)b newTextureWithDescriptor:d
                                                                  offset:a->offset
                                                             bytesPerRow:a->bytes_per_row];
            if (!t) fprintf(stderr, "[rmetald] buffer-backed texture %ux%u fmt %u bpr %llu FAILED\n",
                            i->width, i->height, (unsigned)i->pixel_format,
                            (unsigned long long)a->bytes_per_row);
            struct rm_ret_handle_u64 r = { rm_intern(t), t ? t.gpuResourceID._impl : 0 };
            reply(fd, &h, t ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_COMPUTE_ENCODER: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id cb = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            /* Concurrent vs serial changes how Metal may reorder the work, so
             * it is honoured rather than defaulted. */
            rm_enc_end_open_on_cb((id)cb, "compute");   /* ml1019 */
            id<MTLComputeCommandEncoder> e2 =
                [(id<MTLCommandBuffer>)cb computeCommandEncoderWithDispatchType:
                    a->arg ? MTLDispatchTypeConcurrent : MTLDispatchTypeSerial];
            if (e2) e2.label = [NSString stringWithFormat:@"enc#%lu compute", (unsigned long)++g_enc_seq];
            rm_enc_opened(e2, (id)cb);   /* ml898 + ml1010 */
            struct rm_ret_handle r = { rm_intern(e2) };
            reply(fd, &h, e2 ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_COMPUTE_INTO: {
            /* Records are {type, struct_size, inline_len} + struct + inline
             * bytes. Only SetBytes uses the inline region; everything else
             * carries handles and scalars, as the blit stream does. */
            struct rm_arg_handle *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id eo = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLComputeCommandEncoder> enc = eo;
            if (!rm_enc_is_open(eo)) {   /* ml1016: same hazard as the blit stream */
                static unsigned said;
                if (said++ < 16)
                    fprintf(stderr, "[rmetald] ml1016 dropping a compute batch for encoder %p: "
                            "it was already ended\n", (__bridge void *)eo);
                reply(fd, &h, RM_OK, NULL, 0); break;
            }
            const uint8_t *p = (const uint8_t *)payload + sizeof *a;
            const uint8_t *end = (const uint8_t *)payload + h.payload_len;
            uint64_t done = 0, skipped = 0;
            while ((size_t)(end - p) >= 12) {
                uint32_t type = *(const uint32_t *)p;
                uint32_t sz = *(const uint32_t *)(p + 4);
                uint32_t inl = *(const uint32_t *)(p + 8);
                const uint8_t *rec = p + 12;
                if ((uint64_t)sz + inl > (uint64_t)(end - rec)) break;
                const uint8_t *inline_bytes = rec + sz;
                p = rec + sz + inl;
                uint32_t e2 = RM_OK;
                #define RESC(h_) rm_resolve((uint64_t)(h_), &e2)
                switch (type) {
                case WMTComputeCommandNop: break;
                case WMTComputeCommandSetPSO: {
                    const struct wmtcmd_compute_setpso *c = (const void *)rec;
                    id o = RESC(c->pso); if (e2 != RM_OK || !o) { skipped++; break; }
                    g_compute_tg = MTLSizeMake(c->threadgroup_size.width ?: 1,
                                               c->threadgroup_size.height ?: 1,
                                               c->threadgroup_size.depth ?: 1);
                    [enc setComputePipelineState:o]; done++; break;
                }
                case WMTComputeCommandDispatch: {
                    const struct wmtcmd_compute_dispatch *c = (const void *)rec;
                    [enc dispatchThreadgroups:MTLSizeMake(c->size.width, c->size.height, c->size.depth)
                        threadsPerThreadgroup:g_compute_tg];
                    done++; break;
                }
                case WMTComputeCommandDispatchThreads: {
                    const struct wmtcmd_compute_dispatch *c = (const void *)rec;
                    [enc dispatchThreads:MTLSizeMake(c->size.width, c->size.height, c->size.depth)
                   threadsPerThreadgroup:g_compute_tg];
                    done++; break;
                }
                case WMTComputeCommandDispatchIndirect: {
                    const struct wmtcmd_compute_dispatch_indirect *c = (const void *)rec;
                    id o = RESC(c->indirect_args_buffer); if (e2 != RM_OK || !o) { skipped++; break; }
                    [enc dispatchThreadgroupsWithIndirectBuffer:o
                                           indirectBufferOffset:(NSUInteger)c->indirect_args_offset
                                          threadsPerThreadgroup:g_compute_tg];
                    done++; break;
                }
                case WMTComputeCommandSetBuffer: {
                    const struct wmtcmd_compute_setbuffer *c = (const void *)rec;
                    id o = RESC(c->buffer); if (e2 != RM_OK) { skipped++; break; }
                    [enc setBuffer:o offset:(NSUInteger)c->offset atIndex:c->index]; done++; break;
                }
                case WMTComputeCommandSetBufferOffset: {
                    const struct wmtcmd_compute_setbufferoffset *c = (const void *)rec;
                    [enc setBufferOffset:(NSUInteger)c->offset atIndex:c->index]; done++; break;
                }
                case WMTComputeCommandSetTexture: {
                    const struct wmtcmd_compute_settexture *c = (const void *)rec;
                    id o = RESC(c->texture); if (e2 != RM_OK) { skipped++; break; }
                    [enc setTexture:o atIndex:c->index]; done++; break;
                }
                case WMTComputeCommandSetBytes: {
                    const struct wmtcmd_compute_setbytes *c = (const void *)rec;
                    if (inl < c->length) { skipped++; fprintf(stderr, "[rmetald] compute skip: short inline data, type %u\n", type); break; }
                    [enc setBytes:inline_bytes length:(NSUInteger)c->length atIndex:c->index];
                    done++; break;
                }
                case WMTComputeCommandUseResource: {
                    const struct wmtcmd_compute_useresource *c = (const void *)rec;
                    id o = RESC(c->resource); if (e2 != RM_OK || !o) { skipped++; { static unsigned t2; if (t2++ < 12) fprintf(stderr, "[rmetald] compute skip: resource 0x%llx unresolved (status %u) type %u\n", (unsigned long long)c->resource, e2, type); } break; }
                    [enc useResource:o usage:(MTLResourceUsage)c->usage]; done++; break;
                }
                case WMTComputeCommandWaitForFence:
                case WMTComputeCommandUpdateFence: {
                    const struct wmtcmd_compute_fence_op *c = (const void *)rec;
                    id f = c->fence ? RESC(c->fence) : nil;
                    if (e2 != RM_OK || !f) { skipped++; { static unsigned t3; if (t3++ < 12) fprintf(stderr, "[rmetald] compute skip: fence unresolved (status %u) type %u\n", e2, type); } break; }
                    if (type == WMTComputeCommandUpdateFence) [enc updateFence:f];
                    else                                      [enc waitForFence:f];
                    done++; break;
                }
                default: {
                    static unsigned told;
                    if (told++ < 8)
                        fprintf(stderr, "[rmetald] compute: unknown command type %u -- skipped\n", type);
                    skipped++; break;
                }
                }
                #undef RESC
            }
            if (skipped) {
                static unsigned told;
                if (told++ < 8)
                    fprintf(stderr, "[rmetald] compute batch: %llu replayed, %llu SKIPPED\n",
                            (unsigned long long)done, (unsigned long long)skipped);
            }
            struct rm_ret_u64 r = { done };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_TEXTURE_MIPLEVELS: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLTexture>)o mipmapLevelCount] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_TEXTURE_DIMS: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLTexture> t = o;
            struct rm_ret_handle_u64 r = { t.width, t.height };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_CREATE_VIEW: {
            id dev = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            /* The guest's HWND is deliberately not transported: it names a
             * window in the guest's own windowing system, which has no meaning
             * here. What the guest actually needs back is something it can
             * acquire drawables from -- the host's layer. */
            (void)dev;
            __block id viewObj = nil;
            dispatch_sync(dispatch_get_main_queue(), ^{ viewObj = [g_window contentView]; });
            struct rm_ret_view r = { rm_intern(viewObj), rm_intern(g_layer) };
            fprintf(stderr, "[rmetald] view bound: layer 0x%llx (host window)\n",
                    (unsigned long long)r.layer);
            reply(fd, &h, (r.view && r.layer) ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_RELEASE_VIEW: {
            reply(fd, &h, rm_release_handle(((struct rm_arg_handle *)payload)->handle), NULL, 0); break;
        }
        case RM_OP_NEW_SHARED_EVENT: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLSharedEvent> ev = [(id<MTLDevice>)o newSharedEvent];
            struct rm_ret_handle r = { rm_intern(ev) };
            reply(fd, &h, ev ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_SHARED_EVENT_VALUE: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLSharedEvent>)o signaledValue] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_BUFFER_INFO: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTBufferInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTBufferInfo *i = (void *)(a + 1);
            /* The host ALLOCATES; the guest's memory pointer is a guest address
             * and must never be handed to newBufferWithBytesNoCopy here. */
            id<MTLBuffer> b = [(id<MTLDevice>)dev newBufferWithLength:i->length
                                                              options:(MTLResourceOptions)i->options];
            if (!b) fprintf(stderr, "[rmetald] newBuffer(%llu bytes, options %u) failed\n",
                            (unsigned long long)i->length, (unsigned)i->options);
            struct rm_ret_handle_u64 r = { rm_intern(b), b ? b.gpuAddress : 0 };
            reply(fd, &h, b ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_BUFFER_UPLOAD: {
            struct rm_buffer_range *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) {
                static unsigned told;
                if (told++ < 8)
                    fprintf(stderr, "[rmetald] buffer upload: handle 0x%llx did not resolve "
                                    "(status %u)\n", (unsigned long long)a->handle, err);
                reply(fd,&h,err,NULL,0); break;
            }
            id<MTLBuffer> b = o;
            uint64_t have = h.payload_len - sizeof *a;
            if (a->offset + a->length > b.length || a->length > have) {
                fprintf(stderr, "[rmetald] buffer upload out of range: off %llu len %llu into %llu\n",
                        (unsigned long long)a->offset, (unsigned long long)a->length,
                        (unsigned long long)b.length);
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            if (b.storageMode == MTLStorageModePrivate) {
                /* Silent before: the guest saw a failed upload with no reason
                 * on this side, which is the hardest kind of gap to chase. */
                static unsigned told;
                if (told++ < 8)
                    fprintf(stderr, "[rmetald] buffer 0x%llx is PRIVATE -- upload refused "
                                    "(guest believes it is CPU visible)\n",
                            (unsigned long long)a->handle);
                reply(fd,&h,RM_ERR_WRONG_CLASS,NULL,0); break;
            }
            memcpy((uint8_t *)b.contents + a->offset, (const uint8_t *)payload + sizeof *a, a->length);
            if (b.storageMode == MTLStorageModeManaged)
                [b didModifyRange:NSMakeRange(a->offset, a->length)];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_NEW_MESH_PSO_INFO: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTMeshRenderPipelineInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTMeshRenderPipelineInfo *i = (void *)(a + 1);
            MTLMeshRenderPipelineDescriptor *d = [[MTLMeshRenderPipelineDescriptor alloc] init];
            for (unsigned c = 0; c < 8; c++) {
                d.colorAttachments[c].pixelFormat     = rm_fmt(i->colors[c].pixel_format);
                d.colorAttachments[c].blendingEnabled = i->colors[c].blending_enabled;
                d.colorAttachments[c].writeMask       = (MTLColorWriteMask)i->colors[c].write_mask;
                d.colorAttachments[c].alphaBlendOperation = (MTLBlendOperation)i->colors[c].alpha_blend_operation;
                d.colorAttachments[c].rgbBlendOperation   = (MTLBlendOperation)i->colors[c].rgb_blend_operation;
                d.colorAttachments[c].sourceRGBBlendFactor        = (MTLBlendFactor)i->colors[c].src_rgb_blend_factor;
                d.colorAttachments[c].sourceAlphaBlendFactor      = (MTLBlendFactor)i->colors[c].src_alpha_blend_factor;
                d.colorAttachments[c].destinationRGBBlendFactor   = (MTLBlendFactor)i->colors[c].dst_rgb_blend_factor;
                d.colorAttachments[c].destinationAlphaBlendFactor = (MTLBlendFactor)i->colors[c].dst_alpha_blend_factor;
            }
            d.depthAttachmentPixelFormat   = rm_fmt(i->depth_pixel_format);
            d.stencilAttachmentPixelFormat = rm_fmt(i->stencil_pixel_format);
            d.alphaToCoverageEnabled = i->alpha_to_coverage_enabled;
            d.rasterizationEnabled   = i->rasterization_enabled;
            d.rasterSampleCount      = i->raster_sample_count ? i->raster_sample_count : 1;
            d.payloadMemoryLength    = i->payload_memory_length;
            d.meshThreadgroupSizeIsMultipleOfThreadExecutionWidth   = i->mesh_tgsize_is_multiple_of_sgwidth;
            d.objectThreadgroupSizeIsMultipleOfThreadExecutionWidth = i->object_tgsize_is_multiple_of_sgwidth;
            for (unsigned b = 0; b < 31; b++) {
                if (i->immutable_object_buffers   & (1u << b)) d.objectBuffers[b].mutability   = MTLMutabilityImmutable;
                if (i->immutable_mesh_buffers     & (1u << b)) d.meshBuffers[b].mutability     = MTLMutabilityImmutable;
                if (i->immutable_fragment_buffers & (1u << b)) d.fragmentBuffers[b].mutability = MTLMutabilityImmutable;
            }
            uint32_t e1 = RM_OK, e2b = RM_OK, e3 = RM_OK;
            id of = i->object_function   ? rm_resolve((uint64_t)i->object_function, &e1)   : nil;
            id mf = i->mesh_function     ? rm_resolve((uint64_t)i->mesh_function, &e2b)    : nil;
            id ff = i->fragment_function ? rm_resolve((uint64_t)i->fragment_function, &e3) : nil;
            /* A mesh pipeline REQUIRES a mesh function; handing Metal a nil one
             * aborts the process rather than raising. */
            if (!mf || e1 != RM_OK || e2b != RM_OK || e3 != RM_OK) {
                fprintf(stderr, "[rmetald] mesh pipeline REFUSED: object=%llu mesh=%llu frag=%llu "
                                "(status %u/%u/%u)\n",
                        (unsigned long long)i->object_function, (unsigned long long)i->mesh_function,
                        (unsigned long long)i->fragment_function, e1, e2b, e3);
                struct rm_ret_handle z = { 0 };
                reply(fd, &h, RM_ERR_BAD_HANDLE, &z, sizeof z); break;
            }
            d.objectFunction = of; d.meshFunction = mf; d.fragmentFunction = ff;
            NSError *e = nil;
            id<MTLRenderPipelineState> pso =
                [(id<MTLDevice>)dev newRenderPipelineStateWithMeshDescriptor:d
                                                                     options:MTLPipelineOptionNone
                                                                  reflection:nil error:&e];
            if (!pso) fprintf(stderr, "[rmetald] newMeshRenderPipelineState: %s\n",
                              e ? [[e localizedDescription] UTF8String] : "?");
            struct rm_ret_handle r = { rm_intern(pso) };
            reply(fd, &h, pso ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_NEW_GEOM_PSO_INFO: {   /* ml927: converter geometry emulation */
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTMeshRenderPipelineInfo) + sizeof(struct WMTGeometryEmulationInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTMeshRenderPipelineInfo *i = (void *)(a + 1);
            const struct WMTGeometryEmulationInfo *g = (const void *)((const uint8_t *)(a + 1) + sizeof *i);
            MTLMeshRenderPipelineDescriptor *d = [[MTLMeshRenderPipelineDescriptor alloc] init];
            for (unsigned c = 0; c < 8; c++) {
                d.colorAttachments[c].pixelFormat     = rm_fmt(i->colors[c].pixel_format);
                d.colorAttachments[c].blendingEnabled = i->colors[c].blending_enabled;
                d.colorAttachments[c].writeMask       = (MTLColorWriteMask)i->colors[c].write_mask;
                d.colorAttachments[c].alphaBlendOperation = (MTLBlendOperation)i->colors[c].alpha_blend_operation;
                d.colorAttachments[c].rgbBlendOperation   = (MTLBlendOperation)i->colors[c].rgb_blend_operation;
                d.colorAttachments[c].sourceRGBBlendFactor        = (MTLBlendFactor)i->colors[c].src_rgb_blend_factor;
                d.colorAttachments[c].sourceAlphaBlendFactor      = (MTLBlendFactor)i->colors[c].src_alpha_blend_factor;
                d.colorAttachments[c].destinationRGBBlendFactor   = (MTLBlendFactor)i->colors[c].dst_rgb_blend_factor;
                d.colorAttachments[c].destinationAlphaBlendFactor = (MTLBlendFactor)i->colors[c].dst_alpha_blend_factor;
            }
            d.depthAttachmentPixelFormat   = rm_fmt(i->depth_pixel_format);
            d.stencilAttachmentPixelFormat = rm_fmt(i->stencil_pixel_format);
            d.alphaToCoverageEnabled = i->alpha_to_coverage_enabled;
            d.rasterizationEnabled   = i->rasterization_enabled;
            d.rasterSampleCount      = i->raster_sample_count ? i->raster_sample_count : 1;
            uint32_t es = RM_OK, ev = RM_OK, eg = RM_OK, ef = RM_OK;
            id<MTLLibrary> Ls = rm_resolve((uint64_t)g->stagein_library, &es);
            id<MTLLibrary> Lv = rm_resolve((uint64_t)g->vertex_library, &ev);
            id<MTLLibrary> Lg = rm_resolve((uint64_t)g->geometry_library, &eg);
            id<MTLLibrary> Lf = rm_resolve((uint64_t)g->fragment_library, &ef);
            if (es != RM_OK || ev != RM_OK || eg != RM_OK || ef != RM_OK) {
                fprintf(stderr, "[rmetald] geometry pipeline REFUSED: libraries %u/%u/%u/%u\n", es, ev, eg, ef);
                struct rm_ret_handle z = { 0 }; reply(fd, &h, RM_ERR_BAD_HANDLE, &z, sizeof z); break;
            }
            /* Exactly what IRRuntimeNewGeometryEmulationPipeline does. */
            NSError *e = nil;
            MTLFunctionConstantValues *cv = [[MTLFunctionConstantValues alloc] init];
            id<MTLFunction> fsi = [Ls newFunctionWithName:Ls.functionNames.firstObject];
            BOOL tess = NO;
            [cv setConstantValue:&tess type:MTLDataTypeBool withName:@"tessellationEnabled"];
            NSString *on = [NSString stringWithFormat:@"%s.dxil_irconverter_object_shader", g->vertex_function];
            id<MTLFunction> fo = [Lv newFunctionWithName:on constantValues:cv error:&e];
            if (!fo) fprintf(stderr, "[rmetald] geometry pipeline: object function '%s': %s (library has %s)\n", [on UTF8String],
                             e ? [[e localizedDescription] UTF8String] : "?", [[Lv.functionNames componentsJoinedByString:@","] UTF8String]);
            int vsz = (int)g->gs_vertex_size_bytes;
            [cv setConstantValue:&vsz type:MTLDataTypeInt withName:@"vertex_shader_output_size_fc"];
            e = nil;
            id<MTLFunction> fm = [Lg newFunctionWithName:[NSString stringWithUTF8String:g->geometry_function] constantValues:cv error:&e];
            if (!fm) fprintf(stderr, "[rmetald] geometry pipeline: mesh function '%s': %s\n", g->geometry_function, e ? [[e localizedDescription] UTF8String] : "?");
            id<MTLFunction> ff = g->fragment_function[0] ? [Lf newFunctionWithName:[NSString stringWithUTF8String:g->fragment_function]] : nil;
            if (!fsi || !fo || !fm || (g->fragment_function[0] && !ff)) {
                fprintf(stderr, "[rmetald] geometry pipeline REFUSED: stagein=%d object=%d mesh=%d frag=%d\n", !!fsi, !!fo, !!fm, !!ff);
                struct rm_ret_handle z = { 0 }; reply(fd, &h, RM_ERR_WRONG_CLASS, &z, sizeof z); break;
            }
            d.objectFunction = fo; d.meshFunction = fm; d.fragmentFunction = ff;
            MTLLinkedFunctions *lf = [MTLLinkedFunctions linkedFunctions];
            lf.functions = @[fsi];
            d.objectLinkedFunctions = lf;
            e = nil;
            id<MTLRenderPipelineState> pso =
                [(id<MTLDevice>)dev newRenderPipelineStateWithMeshDescriptor:d options:MTLPipelineOptionNone reflection:nil error:&e];
            if (!pso) fprintf(stderr, "[rmetald] geometry pipeline: %s\n", e ? [[e localizedDescription] UTF8String] : "?");
            else { static unsigned said; if (said++ < 4) fprintf(stderr, "[rmetald] geometry pipeline OK: vs '%s' gs '%s' ps '%s' vertex %u B, %u prims/mesh tg\n",
                                                             g->vertex_function, g->geometry_function, g->fragment_function, g->gs_vertex_size_bytes, g->gs_max_input_primitives); }
            struct rm_ret_handle r = { rm_intern(pso) };
            reply(fd, &h, pso ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_NEW_RENDER_PSO_INFO: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTRenderPipelineInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTRenderPipelineInfo *i = (void *)(a + 1);
            MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
            for (unsigned c = 0; c < 8; c++) {
                d.colorAttachments[c].pixelFormat     = rm_fmt(i->colors[c].pixel_format);
                d.colorAttachments[c].blendingEnabled = i->colors[c].blending_enabled;
                d.colorAttachments[c].writeMask       = (MTLColorWriteMask)i->colors[c].write_mask;
                d.colorAttachments[c].alphaBlendOperation = (MTLBlendOperation)i->colors[c].alpha_blend_operation;
                d.colorAttachments[c].rgbBlendOperation   = (MTLBlendOperation)i->colors[c].rgb_blend_operation;
                d.colorAttachments[c].sourceRGBBlendFactor        = (MTLBlendFactor)i->colors[c].src_rgb_blend_factor;
                d.colorAttachments[c].sourceAlphaBlendFactor      = (MTLBlendFactor)i->colors[c].src_alpha_blend_factor;
                d.colorAttachments[c].destinationRGBBlendFactor   = (MTLBlendFactor)i->colors[c].dst_rgb_blend_factor;
                d.colorAttachments[c].destinationAlphaBlendFactor = (MTLBlendFactor)i->colors[c].dst_alpha_blend_factor;
            }
            for (unsigned b = 0; b < 31; b++) {
                if (i->immutable_fragment_buffers & (1u << b)) d.fragmentBuffers[b].mutability = MTLMutabilityImmutable;
                if (i->immutable_vertex_buffers   & (1u << b)) d.vertexBuffers[b].mutability   = MTLMutabilityImmutable;
            }
            d.depthAttachmentPixelFormat   = rm_fmt(i->depth_pixel_format);
            d.stencilAttachmentPixelFormat = rm_fmt(i->stencil_pixel_format);
            d.alphaToCoverageEnabled = i->alpha_to_coverage_enabled;
            d.rasterizationEnabled   = i->rasterization_enabled;
            d.rasterSampleCount      = i->raster_sample_count ? i->raster_sample_count : 1;
            d.inputPrimitiveTopology = (MTLPrimitiveTopologyClass)i->input_primitive_topology;
            d.tessellationPartitionMode        = (MTLTessellationPartitionMode)i->tessellation_partition_mode;
            d.tessellationFactorStepFunction   = (MTLTessellationFactorStepFunction)i->tessellation_factor_step;
            d.tessellationOutputWindingOrder   = (MTLWinding)i->tessellation_output_winding_order;
            d.maxTessellationFactor            = i->max_tessellation_factor;
            /* ml859: a vertex descriptor may follow the pipeline info; the
             * guest says so through info_len. Shaders from the Metal Shader
             * Converter read vertex input through [[stage_in]] and need it. */
            if (a->info_len >= sizeof(struct WMTRenderPipelineInfo) + sizeof(struct WMTVertexDescriptorInfo) &&
                h.payload_len >= sizeof *a + sizeof(struct WMTRenderPipelineInfo) + sizeof(struct WMTVertexDescriptorInfo)) {
                const struct WMTVertexDescriptorInfo *vdi = (const void *)((const uint8_t *)(i + 1));
                MTLVertexDescriptor *vdesc = [[MTLVertexDescriptor alloc] init];
                for (unsigned k = 0; k < 31; k++) {
                    if (vdi->attribute_mask & (1u << k)) {
                        vdesc.attributes[k].format = (MTLVertexFormat)vdi->attributes[k].format;
                        vdesc.attributes[k].offset = vdi->attributes[k].offset;
                        vdesc.attributes[k].bufferIndex = vdi->attributes[k].buffer_index;
                    }
                    if (vdi->layout_mask & (1u << k)) {
                        vdesc.layouts[k].stride = vdi->layouts[k].stride;
                        vdesc.layouts[k].stepFunction = (MTLVertexStepFunction)vdi->layouts[k].step_function;
                        /* ml905: Metal requires stepRate 0 for a constant-step layout; 1 otherwise when unset. */
                        vdesc.layouts[k].stepRate = vdi->layouts[k].step_function == 0 ? 0 : (vdi->layouts[k].step_rate ? vdi->layouts[k].step_rate : 1);
                    }
                }
                d.vertexDescriptor = vdesc;
            }
            uint32_t bad = RM_OK;
            id vf = i->vertex_function   ? rm_resolve((uint64_t)i->vertex_function, &bad)   : nil;
            uint32_t bad2 = RM_OK;
            id ff = i->fragment_function ? rm_resolve((uint64_t)i->fragment_function, &bad2) : nil;
            /* Metal ABORTS the process for an invalid pipeline descriptor -- it
             * is not an ObjC exception, so the @try around this switch cannot
             * catch it and the whole GPU service dies mid-session. A nil vertex
             * function is the common way to get there, and it happens whenever a
             * function handle fails to resolve. Refuse the call instead. */
            if (!vf || bad != RM_OK) {
                fprintf(stderr, "[rmetald] render pipeline REFUSED: vertex function %llu "
                                "did not resolve (status %u) -- not handing a nil function "
                                "to Metal\n", (unsigned long long)i->vertex_function, bad);
                struct rm_ret_handle z = { 0 };
                reply(fd, &h, RM_ERR_BAD_HANDLE, &z, sizeof z); break;
            }
            if (i->fragment_function && (!ff || bad2 != RM_OK)) {
                fprintf(stderr, "[rmetald] render pipeline REFUSED: fragment function %llu "
                                "did not resolve (status %u)\n",
                        (unsigned long long)i->fragment_function, bad2);
                struct rm_ret_handle z = { 0 };
                reply(fd, &h, RM_ERR_BAD_HANDLE, &z, sizeof z); break;
            }
            d.vertexFunction = (id<MTLFunction>)vf;
            d.fragmentFunction = (id<MTLFunction>)ff;
            NSError *e = nil;
            id<MTLRenderPipelineState> pso =
                [(id<MTLDevice>)dev newRenderPipelineStateWithDescriptor:d error:&e];
            if (!pso) fprintf(stderr, "[rmetald] newRenderPipelineState: %s\n",
                              e ? [[e localizedDescription] UTF8String] : "?");
            struct rm_ret_handle r = { rm_intern(pso) };
            reply(fd, &h, pso ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_NEW_FUNCTION_CONSTS: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + a->info_len) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id lib = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const uint8_t *p = (const uint8_t *)(a + 1);
            NSString *nm = [[NSString alloc] initWithBytes:p length:a->info_len encoding:NSUTF8StringEncoding];
            p += a->info_len;
            const uint8_t *end = (const uint8_t *)payload + h.payload_len;
            MTLFunctionConstantValues *cv = [[MTLFunctionConstantValues alloc] init];
            for (uint32_t c = 0; c < a->extra_count; c++) {
                if ((size_t)(end - p) < sizeof(struct rm_fn_const)) break;
                const struct rm_fn_const *fc = (const void *)p;
                p += sizeof *fc;
                if ((size_t)(end - p) < fc->value_len) break;
                [cv setConstantValue:p type:(MTLDataType)fc->type atIndex:fc->index];
                p += fc->value_len;
            }
            NSError *e = nil;
            id<MTLFunction> fn = [(id<MTLLibrary>)lib newFunctionWithName:nm constantValues:cv error:&e];
            if (!fn) fprintf(stderr, "[rmetald] newFunctionWithConstants(%s): %s\n",
                             [nm UTF8String] ?: "?", e ? [[e localizedDescription] UTF8String] : "?");
            struct rm_ret_handle r = { rm_intern(fn) };
            reply(fd, &h, fn ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_NEW_DSS_INFO: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTDepthStencilInfo) ||
                a->info_len < sizeof(struct WMTDepthStencilInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTDepthStencilInfo *i = (void *)(a + 1);
            MTLDepthStencilDescriptor *d = [[MTLDepthStencilDescriptor alloc] init];
            d.depthCompareFunction = (MTLCompareFunction)i->depth_compare_function;
            d.depthWriteEnabled    = i->depth_write_enabled;
            if (i->front_stencil.enabled) {
                d.frontFaceStencil.depthStencilPassOperation = (MTLStencilOperation)i->front_stencil.depth_stencil_pass_op;
                d.frontFaceStencil.depthFailureOperation     = (MTLStencilOperation)i->front_stencil.depth_fail_op;
                d.frontFaceStencil.stencilFailureOperation   = (MTLStencilOperation)i->front_stencil.stencil_fail_op;
                d.frontFaceStencil.stencilCompareFunction    = (MTLCompareFunction)i->front_stencil.stencil_compare_function;
                d.frontFaceStencil.writeMask                 = i->front_stencil.write_mask;
                d.frontFaceStencil.readMask                  = i->front_stencil.read_mask;
            }
            if (i->back_stencil.enabled) {
                d.backFaceStencil.depthStencilPassOperation = (MTLStencilOperation)i->back_stencil.depth_stencil_pass_op;
                d.backFaceStencil.depthFailureOperation     = (MTLStencilOperation)i->back_stencil.depth_fail_op;
                d.backFaceStencil.stencilFailureOperation   = (MTLStencilOperation)i->back_stencil.stencil_fail_op;
                d.backFaceStencil.stencilCompareFunction    = (MTLCompareFunction)i->back_stencil.stencil_compare_function;
                d.backFaceStencil.writeMask                 = i->back_stencil.write_mask;
                d.backFaceStencil.readMask                  = i->back_stencil.read_mask;
            }
            struct rm_ret_handle r = { rm_intern([(id<MTLDevice>)dev newDepthStencilStateWithDescriptor:d]) };
            reply(fd, &h, r.handle ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_NEW_SAMPLER_INFO: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTSamplerInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTSamplerInfo *i = (void *)(a + 1);
            MTLSamplerDescriptor *d = [[MTLSamplerDescriptor alloc] init];
            d.minFilter = (MTLSamplerMinMagFilter)i->min_filter;
            d.magFilter = (MTLSamplerMinMagFilter)i->mag_filter;
            d.mipFilter = (MTLSamplerMipFilter)i->mip_filter;
            d.rAddressMode = (MTLSamplerAddressMode)i->r_address_mode;
            d.sAddressMode = (MTLSamplerAddressMode)i->s_address_mode;
            d.tAddressMode = (MTLSamplerAddressMode)i->t_address_mode;
            d.borderColor = (MTLSamplerBorderColor)i->border_color;
            d.compareFunction = (MTLCompareFunction)i->compare_function;
            d.lodMinClamp = i->lod_min_clamp;
            d.lodMaxClamp = i->lod_max_clamp;
            d.maxAnisotropy = i->max_anisotroy ? i->max_anisotroy : 1;
            d.normalizedCoordinates = i->normalized_coords;
            d.lodAverage = i->lod_average;
            d.supportArgumentBuffers = i->support_argument_buffers;
            id<MTLSamplerState> ss = [(id<MTLDevice>)dev newSamplerStateWithDescriptor:d];
            /* gpu_resource_id is an OUT field the guest binds with. */
            struct rm_ret_handle_u64 r = { rm_intern(ss),
                ss && i->support_argument_buffers ? ss.gpuResourceID._impl : 0 };
            reply(fd, &h, r.handle ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_NEW_COMPUTE_PSO_INFO: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTComputePipelineInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTComputePipelineInfo *i = (void *)(a + 1);
            id fn = i->compute_function ? rm_resolve((uint64_t)i->compute_function, &err) : nil;
            if (err != RM_OK || !fn) {
                /* Same abort hazard as the render path: a nil compute function
                 * takes the process down rather than returning an error. */
                fprintf(stderr, "[rmetald] compute pipeline REFUSED: function %llu did not "
                                "resolve (status %u)\n",
                        (unsigned long long)i->compute_function, err);
                struct rm_ret_handle z = { 0 };
                reply(fd, &h, RM_ERR_BAD_HANDLE, &z, sizeof z); break;
            }
            MTLComputePipelineDescriptor *d = [[MTLComputePipelineDescriptor alloc] init];
            d.computeFunction = (id<MTLFunction>)fn;
            d.threadGroupSizeIsMultipleOfThreadExecutionWidth = i->tgsize_is_multiple_of_sgwidth;
            for (unsigned b = 0; b < 31; b++)
                if (i->immutable_buffers & (1u << b))
                    d.buffers[b].mutability = MTLMutabilityImmutable;
            NSError *e = nil;
            id<MTLComputePipelineState> pso =
                [(id<MTLDevice>)dev newComputePipelineStateWithDescriptor:d
                                                                  options:MTLPipelineOptionNone
                                                               reflection:nil error:&e];
            if (!pso) fprintf(stderr, "[rmetald] newComputePipelineState: %s\n",
                              e ? [[e localizedDescription] UTF8String] : "?");
            struct rm_ret_handle r = { rm_intern(pso) };
            reply(fd, &h, pso ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_DEVICE_REGISTRY_ID: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLDevice>)o registryID] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_DEVICE_UNIFIED_MEM: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLDevice>)o hasUnifiedMemory] ? 1u : 0u };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_DEVICE_MAX_WORKING_SET: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLDevice>)o recommendedMaxWorkingSetSize] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_OS_VERSION: {
            NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
            struct rm_os_version r = { (uint32_t)v.majorVersion, (uint32_t)v.minorVersion,
                                       (uint32_t)v.patchVersion, 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_DEVICE_SET_MAXCC: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            [(id<MTLDevice>)o setShouldMaximizeConcurrentCompilation:(a->arg != 0)];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        default:
            { static unsigned said; if (said++ < 8) fprintf(stderr, "[rmetald] unknown opcode %u (this daemon knows up to %u)\n", h.opcode, (unsigned)RM_OP_QUEUE_ADD_RESIDENCY); }
            reply(fd, &h, RM_ERR_BAD_OPCODE, NULL, 0); break;
        }
        } @catch (NSException *e) {
            /* Report and name it -- a wrong selector is still a real bug -- but
             * answer the client instead of taking the whole GPU service down. */
            fprintf(stderr, "[rmetald] opcode %u raised %s (%s) -- replying "
                            "WRONG_CLASS rather than terminating\n", h.opcode,
                    e.name ? e.name.UTF8String : "?",
                    e.reason ? e.reason.UTF8String : "?");
            reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0);
        }
        }
    }
    free(payload);
}

/* A shared secret, required as the first frame of every connection. The daemon
 * compiles arbitrary shader source and allocates GPU memory on request, so an
 * unauthenticated listener on a routable interface is a remote code-execution
 * surface for anyone on the network. Bound to an explicit address as well. */
static char g_token[64];

static int authenticate(int fd) {
    struct rm_hdr h;
    if (rd(fd, &h, sizeof h)) return 0;
    if (h.magic != RM_MAGIC || h.opcode != RM_OP_PING) return 0;
    if (h.payload_len != strlen(g_token)) return 0;
    char got[sizeof g_token];
    if (rd(fd, got, h.payload_len)) return 0;
    if (memcmp(got, g_token, h.payload_len) != 0) return 0;
    reply(fd, &h, RM_OK, NULL, 0);
    return 1;
}

static int g_listen_fd;

static void *rpc_thread(void *unused) {
    (void)unused;
    for (;;) {
        int c = accept(g_listen_fd, NULL, NULL);
        if (c < 0) continue;
        int one = 1;
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        struct timeval tv = { .tv_sec = 30 };
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        if (!authenticate(c)) {
            fprintf(stderr, "[rmetald] rejected unauthenticated client\n");
            close(c); continue;
        }
        fprintf(stderr, "[rmetald] client authenticated\n");
        serve(c);
        close(c);
        fprintf(stderr, "[rmetald] client gone; releasing %u session handles\n", g_live);
        rm_census_report();
        rm_reset_table();
    }
    return NULL;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d) { fprintf(stderr, "no Metal device\n"); return 1; }
        fprintf(stderr, "[rmetald] host GPU: %s\n", [[d name] UTF8String]);
        fprintf(stderr, "[rmetald] Apple7=%d Apple8=%d Apple9=%d BC=%d\n",
                [d supportsFamily:MTLGPUFamilyApple7], [d supportsFamily:MTLGPUFamilyApple8],
                [d supportsFamily:MTLGPUFamilyApple9], [d supportsBCTextureCompression]);
    }
    const char *bind_addr = (argc > 1) ? argv[1] : "127.0.0.1";
    const char *tok = getenv("RMETAL_TOKEN");
    if (!tok || !*tok) { fprintf(stderr, "set RMETAL_TOKEN to a shared secret\n"); return 1; }
    snprintf(g_token, sizeof g_token, "%s", tok);

    int s = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(RM_PORT) };
    if (inet_pton(AF_INET, bind_addr, &a.sin_addr) != 1) {
        fprintf(stderr, "bad bind address %s\n", bind_addr); return 1;
    }
    if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 4)) { perror("bind/listen"); return 1; }
    fprintf(stderr, "[rmetald] listening on %s:%d (token required)\n", bind_addr, RM_PORT);
    g_listen_fd = s;

    /* AppKit owns the main thread; RPC runs on a worker. The window is created
     * here, directly -- NOT via dispatch_sync to the main queue, which from the
     * main thread before [NSApp run] is an immediate deadlock. dispatch_sync is
     * only correct from the RPC thread, where it is used. */
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        host_window_create(MTLCreateSystemDefaultDevice());
        [NSApp activateIgnoringOtherApps:YES];
        rm_start_fps_title();   /* timers live on the main queue, so start here */
        pthread_t t;
        pthread_create(&t, NULL, rpc_thread, NULL);
        [NSApp run];
    }
    return 0;
}
